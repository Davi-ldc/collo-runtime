//! The module domain of the worker runtime. `Modules` is its state: the
//! routes of the worker's definition, registered packs and route module
//! state (`modules/state.zig`). `Methods` holds the runtime's module
//! operations, which `Runtime` declares as its own (`root.zig`): the modules
//! context, the settlements and expiries of route module evaluations, and
//! the worker's stop, once drained, when no route can serve or after a
//! deadline fire. It belongs to the worker's VM thread.
//!
//! `collo_runtime_module_eval_settled` only parks a settlement, in the
//! middle of a JavaScript drain; the settlement runs from the scheduler loop
//! (`collectModuleSettlements`), never inside a drain.

const std = @import("std");
const route_table = @import("collo_ipc").route_table;
const request_context = @import("collo_worker_request").context;
const modules_context = @import("../modules/context.zig");
const modules_routes = @import("../modules/routes.zig");
const modules_state = @import("../modules/state.zig");
const scheduler_resources = @import("../scheduler/resources.zig");

pub const Modules = struct {
    state: modules_state.State,

    /// Adds every route of `table`, the definition's route table, after
    /// checking it whole (`route_table.decode`), so a malformed table or
    /// bindings section fails the runtime's start instead of a request.
    /// `table` stays borrowed for the runtime's life, since every route's
    /// bindings point into it. Fails with `error.InvalidRouteTable` or
    /// `error.OutOfMemory`.
    pub fn init(allocator: std.mem.Allocator, table: []const u8, isolate_realm: bool) !Modules {
        var decoded: route_table.Routes = undefined;
        const routes = try route_table.decode(table, &decoded);
        var state: modules_state.State = .{ .isolate_realm = isolate_realm };
        errdefer state.deinit(allocator);
        try state.routes.ensureTotalCapacityPrecise(allocator, routes.len);
        for (routes) |route|
            _ = try state.addRoute(allocator, route.entry_specifier, route.bindings);
        return .{ .state = state };
    }

    pub fn deinit(self: *Modules, allocator: std.mem.Allocator) void {
        self.state.deinit(allocator);
        self.* = undefined;
    }
};

pub fn Methods(comptime Runtime: type) type {
    return struct {
        /// Drains the settlements `collo_runtime_module_eval_settled` parked. It
        /// runs on every scheduler pass: the callback fires on this thread in the
        /// middle of a drain, so the loop is awake when it does and the list
        /// never outlives one pass. A settlement appended while another settles
        /// is picked up by the same loop.
        pub fn collectModuleSettlements(self: *Runtime) void {
            // Stalled waiters go first: their settlement already happened and
            // their module record no longer lists them, so this retry is the only
            // path left that runs them.
            while (self.modules.state.stalled_waiters.items.len > 0) {
                const request_id = self.modules.state.stalled_waiters.items[self.modules.state.stalled_waiters.items.len - 1];
                if (!self.tryQueueReadyWork(.{ .request = request_id }))
                    break;
                _ = self.modules.state.stalled_waiters.pop();
            }
            if (self.modules.state.pending_settlements.items.len != 0) {
                // The settlement's JavaScript (the export read and the drains
                // around it) runs outside any turn, so the boot identity is
                // published for the deadline arbiter. Only when work is pending,
                // so a pass with none stores nothing.
                scheduler_resources.publishTurnOwner(self, request_context.boot_request_id);
                defer scheduler_resources.clearTurnOwner(self);
                while (self.modules.state.pending_settlements.pop()) |entry| {
                    self.handleModuleEvaluationSettled(entry.realm_index, entry.specifier, entry.resolved);
                    self.core.allocator.free(entry.specifier);
                }
            }
        }

        /// Moves every route that evaluates `specifier` in the realm
        /// `realm_index` to its settled state and queues every request that
        /// waited on it. Once no route's evaluation is left in flight, the
        /// boot context closes. Only `collectModuleSettlements` calls it, from
        /// the scheduler loop, never from inside a JavaScript drain.
        pub fn handleModuleEvaluationSettled(
            self: *Runtime,
            realm_index: u32,
            specifier: []const u8,
            resolved: bool,
        ) void {
            var ctx = self.modulesContext();
            var settled_any = false;
            while (modules_routes.settleEvaluation(&ctx, realm_index, specifier, resolved)) |settled| {
                settled_any = true;
                var settlement = settled;
                defer settlement.waiters.deinit(self.core.allocator);
                queueSettledWaiters(self, settlement.waiters.items);
            }
            if (settled_any)
                closeBootContextOnceSettled(self);
        }

        /// Pins failed every route whose top-level await outlived its budget
        /// (`expireEvaluation` in `worker/modules/routes.zig`) and queues the
        /// requests parked on each, which then get the 500 of a failed route.
        /// Once no route's evaluation is left in flight, the boot context
        /// closes and ends the timers and fetches the expired evaluations
        /// left behind; until then they run under the boot context, whose
        /// deadline is the latest route's budget. Runs no JavaScript.
        pub fn expireRouteEvaluations(self: *Runtime) void {
            var ctx = self.modulesContext();
            var expired_any = false;
            while (modules_routes.expireEvaluation(&ctx)) |expired| {
                expired_any = true;
                var settlement = expired;
                defer settlement.waiters.deinit(self.core.allocator);
                queueSettledWaiters(self, settlement.waiters.items);
            }
            if (expired_any)
                closeBootContextOnceSettled(self);
        }

        /// The boot context is the owner of every route's top-level code, so
        /// it closes only once no route evaluates any more. The close disarms
        /// its budget too, so a deadline entry already queued for the boot id
        /// does nothing and no stale deadline reaches later work.
        fn closeBootContextOnceSettled(self: *Runtime) void {
            if (self.bootContext() == null)
                return;
            var ctx = self.modulesContext();
            if (modules_routes.anyEvaluating(&ctx))
                return;
            self.closeBootContext();
        }

        fn queueSettledWaiters(self: *Runtime, waiters: []const u64) void {
            for (waiters) |request_id| {
                if (self.tryQueueReadyWork(.{ .request = request_id }))
                    continue;
                // The queue and its backlog are both full. The settled route
                // record no longer lists the waiter, so it is parked where the
                // stalled retry in `collectModuleSettlements` finds it. If even
                // that allocation fails, the request ends at its deadline, and
                // the drop is logged at err.
                self.modules.state.stalled_waiters.append(self.core.allocator, request_id) catch {
                    std.log.err("module settlement re-queue dropped request_id={d}", .{request_id});
                };
            }
        }

        /// Stops the loop once no route can serve (`recycle_after_drain`), or
        /// after a sentinel deadline fire whose request already has its response
        /// (`stop_after_deadline_fire`), once everything drained: the ready
        /// queue, its backlog, the stalled waiters and the pending settlements
        /// are empty, and no request but the boot context is active. The drain
        /// gives every waiting request its own 500, since each turn on the
        /// terminated VM fails through the response path, before the worker
        /// stops. The scheduler loop calls it when its ready queue runs dry.
        pub fn maybeRecycleAfterFailedEvaluation(self: *Runtime) void {
            if (!self.modules.state.recycle_after_drain and !self.stop_after_deadline_fire)
                return;
            if (!self.scheduler.ready_queue.isEmpty())
                return;
            // The loop normally drains the backlog before calling this, but the
            // guarantee must not depend on where the call sits: a waiter in the
            // backlog still gets its own 500.
            if (!self.scheduler.ready_backlog.isEmpty())
                return;
            if (self.modules.state.stalled_waiters.items.len != 0)
                return;
            if (self.modules.state.pending_settlements.items.len != 0)
                return;
            const active_count = self.requests.active.count();
            const only_boot = active_count == 0 or
                (active_count == 1 and self.requests.active.contains(request_context.boot_request_id));
            if (!only_boot)
                return;
            if (self.modules.state.recycle_after_drain)
                std.log.warn("no route of the worker can serve; recycling worker after drain", .{})
            else
                std.log.warn("deadline termination poisoned the VM; stopping worker after drain", .{});
            self.core.running = false;
        }

        pub fn modulesContext(self: *Runtime) modules_context.Context {
            return .{
                .allocator = self.core.allocator,
                .vm = self.core.vm,
                .modules = &self.modules.state,
                .clock = self.core.clock,
            };
        }
    };
}

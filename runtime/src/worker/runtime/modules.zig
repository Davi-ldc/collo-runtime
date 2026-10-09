//! The module domain of the worker runtime. `Modules` is its state:
//! registered packs and route module state (`modules/state.zig`) beside the
//! route's bindings blob and the entry specifier it belongs to. `Methods`
//! holds the runtime's module operations, which `Runtime` declares as its
//! own (`root.zig`): the modules context, the settlements of route module
//! evaluations, and the worker's stop once a failed evaluation or a deadline
//! fire has drained. It belongs to the worker's VM thread.
//!
//! `collo_runtime_module_eval_settled` only parks a settlement, in the
//! middle of a JavaScript drain; the settlement runs from the scheduler loop
//! (`collectModuleSettlements`), never inside a drain.

const std = @import("std");
const request_context = @import("collo_worker_request").context;
const modules_context = @import("../modules/context.zig");
const modules_routes = @import("../modules/routes.zig");
const modules_state = @import("../modules/state.zig");
const scheduler_resources = @import("../scheduler/resources.zig");

pub const Modules = struct {
    state: modules_state.State = .{},
    /// The route's bindings blob, already validated
    /// (`worker/modules/route_env.zig`). Borrowed: the boot that built the
    /// runtime keeps it mapped until the runtime is gone.
    route_bindings_blob: []const u8,
    /// Entry specifier of the route the blob belongs to, borrowed like the
    /// blob (`RuntimeOptions.route_bindings_route`).
    route_bindings_route: []const u8,

    pub fn init(route_bindings_blob: []const u8, route_bindings_route: []const u8) Modules {
        return .{
            .route_bindings_blob = route_bindings_blob,
            .route_bindings_route = route_bindings_route,
        };
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
                    self.handleModuleEvaluationSettled(entry.specifier, entry.resolved);
                    self.core.allocator.free(entry.specifier);
                }
            }
        }

        /// Moves a route module to its settled state and queues every request
        /// that waited on the evaluation. Only `collectModuleSettlements` calls
        /// it, from the scheduler loop, never from inside a JavaScript drain.
        pub fn handleModuleEvaluationSettled(self: *Runtime, specifier: []const u8, resolved: bool) void {
            var ctx = self.modulesContext();
            var settlement = modules_routes.settleEvaluation(&ctx, specifier, resolved);
            defer settlement.waiters.deinit(self.core.allocator);
            if (settlement.transition != .none) {
                // The route entry settled, either way, so the boot context
                // closes. The close disarms its budget too, so a deadline entry
                // already queued for the boot id does nothing and no stale
                // deadline reaches later work.
                if (self.bootContext()) |boot_ctx| {
                    if (std.mem.eql(u8, boot_ctx.dispatch_work.route_entry_specifier, specifier))
                        self.closeBootContext();
                }
                // A failed evaluation recycles the worker, but only after the
                // waiters drain with their own 500s; stopping now would turn
                // them into errors the host synthesizes before any of them ran.
                if (settlement.transition == .failed)
                    self.modules.state.recycle_after_drain = true;
            }
            const waiters = &settlement.waiters;
            for (waiters.items) |request_id| {
                if (self.tryQueueReadyWork(.{ .request = request_id }))
                    continue;
                // The queue and its backlog are both full. The settled module
                // record no longer lists the waiter, so it is parked where the
                // stalled retry in `collectModuleSettlements` finds it. If even
                // that allocation fails, the request ends at its deadline, and
                // the drop is logged at err.
                self.modules.state.stalled_waiters.append(self.core.allocator, request_id) catch {
                    std.log.err("module settlement re-queue dropped request_id={d}", .{request_id});
                };
            }
        }

        /// Stops the loop after a failed evaluation, or after a sentinel deadline
        /// fire whose request already has its response
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
                std.log.warn("route module evaluation failed; recycling worker after drain", .{})
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
                .route_bindings_blob = self.modules.route_bindings_blob,
                .route_bindings_route = self.modules.route_bindings_route,
            };
        }
    };
}

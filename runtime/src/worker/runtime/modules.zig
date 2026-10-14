//! The module domain of the worker runtime. `Modules` is its state: the
//! routes of the worker's definition and their module state
//! (`modules/state.zig`). `Methods` holds the runtime's module operations,
//! which `Runtime` declares as its own (`root.zig`): the modules context, the
//! lookup of a request's route handler, the realm of a route, and the
//! settlements and expiries of route module evaluations with the close of
//! the evaluations they end (`evaluations.zig`). A worker none of whose routes can serve asks to
//! retire (`retirement.zig`). It belongs to the worker's VM thread.
//!
//! `collo_runtime_module_eval_settled` only parks a settlement, in the
//! middle of a JavaScript drain; the settlement runs from the scheduler loop
//! (`collectModuleSettlements`), never inside a drain, under the evaluation
//! of its module instance, or under the worker owner once that evaluation
//! closed.

const std = @import("std");
const bindings = @import("collo_bindings");
const request_context = @import("collo_worker_request").context;
const modules_context = @import("../modules/context.zig");
const modules_routes = @import("../modules/routes.zig");
const modules_state = @import("../modules/state.zig");

pub const Modules = struct {
    state: modules_state.State,

    /// Starts with no route: the boot takes the routes from the definition's
    /// artifact (`Runtime.evaluateBootRoutes`).
    pub fn init(isolate_realm: bool) Modules {
        return .{ .state = .{ .isolate_realm = isolate_realm } };
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
                const waiter = self.modules.state.stalled_waiters.items[self.modules.state.stalled_waiters.items.len - 1];
                if (!self.tryQueueReadyWorkReadySince(.{ .request = waiter.request_id }, waiter.ready_since_ns))
                    break;
                _ = self.modules.state.stalled_waiters.pop();
            }
            while (self.modules.state.pending_settlements.pop()) |entry| {
                defer self.core.allocator.free(entry.specifier);
                settleUnderOwner(self, entry);
            }
        }

        /// Runs one parked settlement. Its JavaScript, the export read and
        /// the drains around it, runs outside any turn, so the evaluation of
        /// its module instance is installed as the turnless context and its
        /// owner window is open around it; once that evaluation closed, as
        /// for a settlement that came late or twice, the worker owner takes
        /// its place.
        fn settleUnderOwner(self: *Runtime, entry: modules_state.PendingSettlement) void {
            var ctx = self.modulesContext();
            const evaluation = if (modules_routes.instanceEvaluation(&ctx, entry.realm_index, entry.specifier)) |evaluation_id|
                self.requests.active.get(evaluation_id)
            else
                null;
            const exec_ctx: *bindings.ExecCtx = if (evaluation) |context| &context.exec else &self.owners.worker_exec;
            const previous_owner_id = self.enterTurnless(exec_ctx) catch |err| {
                // The settlement still runs: its JavaScript then finds no
                // owner for host calls, which refuse it.
                std.log.warn("module settlement runs without its owner: {s}", .{@errorName(err)});
                self.handleModuleEvaluationSettled(entry.realm_index, entry.specifier, entry.resolved);
                return;
            };
            defer self.leaveTurnless(previous_owner_id);
            self.handleModuleEvaluationSettled(entry.realm_index, entry.specifier, entry.resolved);
        }

        /// Moves every route that evaluates `specifier` in the realm
        /// `realm_index` to its settled state, queues every request that
        /// waited on it, and closes the instance's evaluation once its last
        /// route settled. `collectModuleSettlements` calls it from the
        /// scheduler loop, never from inside a JavaScript drain.
        pub fn handleModuleEvaluationSettled(
            self: *Runtime,
            realm_index: u32,
            specifier: []const u8,
            resolved: bool,
        ) void {
            var ctx = self.modulesContext();
            while (modules_routes.settleEvaluation(&ctx, realm_index, specifier, resolved)) |settled| {
                var settlement = settled;
                defer settlement.waiters.deinit(self.core.allocator);
                queueSettledWaiters(self, settlement.waiters.items);
                self.closeEvaluationOnceSettled(settlement.evaluation_id);
            }
        }

        /// Pins failed every route whose top-level await outlived its budget
        /// (`expireEvaluation` in `worker/modules/routes.zig`), queues the
        /// requests parked on each, which then get the 500 of a failed route,
        /// and closes each expired instance's evaluation, which ends the
        /// timers and fetches its top-level code left behind. Routes that
        /// share an instance share its deadline, so they expire in the same
        /// call. Runs no JavaScript.
        pub fn expireRouteEvaluations(self: *Runtime) void {
            var ctx = self.modulesContext();
            while (modules_routes.expireEvaluation(&ctx)) |expired| {
                var settlement = expired;
                defer settlement.waiters.deinit(self.core.allocator);
                queueSettledWaiters(self, settlement.waiters.items);
                self.closeEvaluationOnceSettled(settlement.evaluation_id);
            }
        }

        fn queueSettledWaiters(self: *Runtime, waiters: []const u64) void {
            // Every waiter became ready at the settlement, whenever the
            // queue takes it.
            const ready_since_ns = self.nowMonoNs();
            for (waiters) |request_id| {
                if (self.tryQueueReadyWorkReadySince(.{ .request = request_id }, ready_since_ns))
                    continue;
                // The queue and its backlog are both full. The settled route
                // record no longer lists the waiter, so it is parked where the
                // stalled retry in `collectModuleSettlements` finds it, with
                // its readiness. If even that allocation fails, the request
                // ends at its deadline, and the drop is logged at err.
                self.modules.state.stalled_waiters.append(self.core.allocator, .{
                    .request_id = request_id,
                    .ready_since_ns = ready_since_ns,
                }) catch {
                    std.log.err("module settlement re-queue dropped request_id={d}", .{request_id});
                };
            }
        }

        /// The handler and `env` of the route `request_ctx` dispatches to, or
        /// `.pending` once the request waits on its route's evaluation
        /// (`modules_routes.lookupRouteHandler`, which says how it fails).
        pub fn lookupRouteHandler(self: *Runtime, request_ctx: *request_context.RequestContext) !modules_routes.RouteLookup {
            var ctx = self.modulesContext();
            return modules_routes.lookupRouteHandler(&ctx, request_ctx);
        }

        pub fn modulesContext(self: *Runtime) modules_context.Context {
            return .{
                .allocator = self.core.allocator,
                .vm = self.core.vm,
                .modules = &self.modules.state,
                .clock = self.core.clock,
            };
        }

        /// The realm the route at `route_index` runs in, for JavaScript the
        /// worker calls on behalf of one of the route's contexts: a request's
        /// handler, extraction and thenable check, a timer or immediate
        /// callback, a request's or an evaluation's. The VM's main realm for
        /// a route without a realm yet or an index past the table; the realm
        /// serves only an input that has none of its own, a primitive
        /// (`collo_invoke` in `abi.h`).
        pub fn realmOfRoute(self: *Runtime, route_index: u16) bindings.Realm {
            const routes = self.modules.state.routes.items;
            if (route_index < routes.len) {
                if (routes[route_index].realm) |realm|
                    return realm;
            }
            return self.core.vm.mainRealm();
        }
    };
}

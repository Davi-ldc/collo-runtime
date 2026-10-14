//! The worker's module bookkeeping, held by `Runtime` and used only on its VM
//! thread: the routes of the worker's definition with the realm and module
//! state of each, and the evaluation settlements waiting for the scheduler
//! loop. `routes.zig` adds the routes at the boot and changes their records.
//! `collo_runtime_module_eval_settled` in `worker/host/module_settlement.zig`
//! appends to the settlement list, and `Runtime` in
//! `worker/runtime/modules.zig` drains it and keeps the stalled waiters.
//! `routes.zig` alone sets `fresh_worker_may_serve`, and the runtime acts on
//! it (`worker/runtime/retirement.zig`).

const std = @import("std");
const bindings = @import("collo_bindings");
const route_table = @import("collo_ipc").route_table;
const runtime_types = @import("../runtime/types.zig");

pub const RouteModule = runtime_types.RouteModule;
pub const RouteHandler = runtime_types.RouteHandler;

/// A route's module state. After the boot a route is ready, evaluating or
/// failed. `failed` lasts for the worker's life, so a request for the route
/// fails at once and never imports the module again. Hoisted
/// `export default function` bindings are initialized before the body runs,
/// so a module whose init threw still exports a callable handler; the pin
/// keeps that handler from being served whatever JSC returns for a re-import
/// of a module whose evaluation failed. A failure ends only its own route:
/// the worker gives way to a fresh one only once no route can serve
/// (`State.fresh_worker_may_serve`).
pub const RouteModuleState = union(enum) {
    /// The entry has not been evaluated yet: a route's state from the boot's
    /// registration until its boot evaluation (`bootEvaluateRoute` in
    /// `routes.zig`). No request finds a route here.
    idle,
    ready: RouteModule,
    /// A top-level await is in flight. Requests for the route park in
    /// `waiters` and are queued again when it settles or expires.
    /// `deadline_mono_ns` bounds an await that never settles: past it the
    /// route is pinned failed (`expireEvaluation` in `routes.zig`).
    evaluating: Evaluating,
    /// The evaluation failed, for the reason the payload names.
    failed: Failure,

    pub const Evaluating = struct {
        waiters: std.ArrayListUnmanaged(u64) = .{},
        /// Routes that share a module instance share its deadline, so they
        /// expire together, as they settle together.
        deadline_mono_ns: u64,
        /// The evaluation that owns the instance's top-level code
        /// (`worker/runtime/evaluations.zig`), the same for every route that
        /// shares the instance. It stays open while any route evaluates under
        /// it.
        evaluation_id: u64,
    };

    /// Why a route failed, which decides whether a fresh worker could do
    /// better. A synchronous throw or an unusable default export depends on
    /// nothing but the module, so a new evaluation would fail the same way; a
    /// top-level await usually waits on I/O, which may succeed the next time,
    /// and an error of this worker's own may not happen in another.
    pub const Failure = enum {
        /// The synchronous part of the evaluation threw, the default export
        /// offers no handler, or reading it or its `fetch` raised.
        threw,
        /// The top-level await rejected.
        rejected,
        /// The top-level await was still pending past
        /// `module_eval_budget_ns` (`routes.zig`). Its later settlement finds
        /// no route evaluating and is ignored.
        exceeded_budget,
        /// The await resolved, but reading the handler or building the
        /// route's `env` failed for a cause of this worker, such as an
        /// allocation failure, rather than of the module. At boot the same
        /// error fails the init instead (`bootEvaluateRoute`).
        internal_error,
    };

    pub fn deinit(self: *RouteModuleState, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .idle, .failed => {},
            .ready => |*module| module.deinit(),
            .evaluating => |*evaluating| evaluating.waiters.deinit(allocator),
        }
        self.* = undefined;
    }
};

/// One route of the worker's definition, at its index in the artifact's
/// routes section (`common/ipc/route_table.zig`), which is the index a
/// dispatch names.
pub const Route = struct {
    /// The route's entry specifier and its bindings section
    /// (`common/ipc/route_bindings.zig`), both borrowed from the definition's
    /// artifact. A worker never unregisters its pack, so the VM holds that
    /// mapping from the boot's registration until it is destroyed
    /// (`Vm.registerModulePackMapping`), and the runtime is always torn down
    /// before its VM: the worker's child never destroys the zygote's VM, and
    /// an in-process owner deinitializes the runtime before the VM it was
    /// built on.
    entry_specifier: []const u8,
    bindings: []const u8,
    /// The realm the route runs in, set the first time the route needs one
    /// (`routeRealm` in `routes.zig`); a realm lives as long as the VM.
    realm: ?bindings.Realm = null,
    module: RouteModuleState = .idle,
};

/// An evaluation settlement that `collo_runtime_module_eval_settled`
/// reported from inside a microtask drain, parked until the scheduler loop
/// handles it in `Runtime.collectModuleSettlements`. It names the module by
/// the realm that evaluated it and its specifier, and owns `specifier`.
pub const PendingSettlement = struct {
    realm_index: u32,
    specifier: []u8,
    resolved: bool,
};

/// A request a module settlement made ready while the ready queue and its
/// backlog were full, with the instant it became ready, which every retry
/// keeps so the wait for room counts as the request's waiting.
pub const StalledWaiter = struct {
    request_id: u64,
    ready_since_ns: u64,
};

pub const State = struct {
    /// The routes of the worker's definition, in the artifact's order. The
    /// boot adds every route of the artifact (`bootRegisterPack` in
    /// `routes.zig`) and none after.
    routes: std.ArrayListUnmanaged(Route) = .empty,
    /// Each route but the first runs in a realm of its own
    /// (`WorkerInit.flag_isolate_realm`); otherwise every route runs in the
    /// VM's main realm. Fixed for the runtime's life.
    isolate_realm: bool = false,
    pending_settlements: std.ArrayListUnmanaged(PendingSettlement) = .empty,
    /// Waiters that found the ready queue and its backlog full when their
    /// module settled. The settled record no longer lists them, so
    /// `Runtime.collectModuleSettlements` retries them until the queue takes
    /// them; a waiter dropped here would wait until its deadline.
    stalled_waiters: std.ArrayListUnmanaged(StalledWaiter) = .empty,
    /// Set once no route can serve and a fresh worker might
    /// (`pinFailed` in `routes.zig` owns the rule), and never cleared, since
    /// a failed route stays failed. The loop then asks the server to retire
    /// the worker and goes on answering what reaches it
    /// (`runtime/retirement.zig`), so every parked waiter and in-flight
    /// request still gets its own 500 from the worker.
    fresh_worker_may_serve: bool = false,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        for (self.pending_settlements.items) |entry|
            allocator.free(entry.specifier);
        self.pending_settlements.deinit(allocator);
        self.stalled_waiters.deinit(allocator);
        for (self.routes.items) |*route|
            route.module.deinit(allocator);
        self.routes.deinit(allocator);
    }
};

comptime {
    // A dispatch names a route by a u16 index.
    std.debug.assert(route_table.routes_max <= std.math.maxInt(u16) + 1);
}

//! The worker's module bookkeeping, held by `Runtime` and used only on its VM
//! thread: the specifiers of every pack the worker registered, the routes of
//! the worker's definition with the realm and module state of each, and the
//! evaluation settlements waiting for the scheduler loop. `routes.zig`
//! changes the route records. `collo_runtime_module_eval_settled` in
//! `worker/host/module_settlement.zig` appends to the settlement list, and
//! `Runtime` in `worker/runtime/modules.zig` drains it and keeps the stalled
//! waiters and `recycle_after_drain`.

const std = @import("std");
const bindings = @import("collo_bindings");
const route_table = @import("collo_ipc").route_table;
const runtime_types = @import("../runtime/types.zig");

pub const RouteModule = runtime_types.RouteModule;

/// A route's module state. `failed` lasts for the worker's life, so a request
/// for the route fails at once and never imports the module again. Hoisted
/// `export default function` bindings are initialized before the body runs,
/// so a module whose init threw still exports a callable handler; the pin
/// keeps that handler from being served whatever JSC returns for a re-import
/// of a module whose evaluation failed.
pub const RouteModuleState = union(enum) {
    /// The entry has not been evaluated in the route's realm, or its
    /// default export was not callable the last time it was read. A worker's
    /// boot evaluates every route before it reports ready
    /// (`Runtime.evaluateBootRoutes`), so otherwise only a runtime that
    /// skipped the boot, as in-process tests do, finds a route here, and the
    /// route's next request evaluates the entry.
    idle,
    ready: RouteModule,
    /// A top-level await is in flight. Requests for the route park in
    /// `waiters` and are queued again when it settles. `deadline_mono_ns`
    /// bounds an await that never settles; a parked request's deadline path
    /// checks it (`evaluationZombie` in `routes.zig`).
    evaluating: Evaluating,
    /// The evaluation threw or its top-level await rejected. A rejected
    /// await also recycles the worker once its waiters drain
    /// (`recycle_after_drain`), which ends every route of the worker, so a
    /// fresh worker evaluates them all again; after a synchronous throw the
    /// worker keeps serving and fails every request for this route.
    failed,

    pub const Evaluating = struct {
        waiters: std.ArrayListUnmanaged(u64) = .{},
        deadline_mono_ns: u64,
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

/// One route of the worker's definition, at its index in the route table
/// (`common/ipc/route_table.zig`), which is the index a dispatch names.
pub const Route = struct {
    /// Owned copy of the route's entry specifier.
    entry_specifier: []u8,
    /// The route's bindings section (`common/ipc/route_bindings.zig`),
    /// borrowed for the runtime's whole life: the boot keeps the route table
    /// mapped until the runtime is gone.
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

pub const State = struct {
    /// Every specifier of the packs the worker registered, each registered
    /// permanent, so a specifier never leaves. The set owns its keys.
    loaded_sources: std.StringHashMapUnmanaged(void) = .empty,
    /// The routes of the worker's definition, in route table order. The
    /// runtime adds every route of the table when it starts
    /// (`Modules.init` in `worker/runtime/modules.zig`) and none after.
    routes: std.ArrayListUnmanaged(Route) = .empty,
    /// Each route but the first runs in a realm of its own
    /// (`WorkerInit.flag_isolate_realm`); otherwise every route runs in the
    /// VM's main realm. Fixed for the runtime's life.
    isolate_realm: bool = false,
    pending_settlements: std.ArrayListUnmanaged(PendingSettlement) = .empty,
    /// Request ids of waiters that found the ready queue and its backlog
    /// full when their module settled. The settled record no longer lists
    /// them, so `Runtime.collectModuleSettlements` retries them until the
    /// queue takes them; a waiter dropped here would wait until its
    /// deadline.
    stalled_waiters: std.ArrayListUnmanaged(u64) = .empty,
    /// Set when a top-level await rejects. The scheduler loop stops the
    /// worker only after every parked waiter and in-flight request has
    /// drained with its own 500 from the worker
    /// (`Runtime.maybeRecycleAfterFailedEvaluation`). Stopping at once would
    /// leave the loop before any waiter ran, and the server would answer
    /// them with errors of its own.
    recycle_after_drain: bool = false,

    /// Appends a route with no realm and an `idle` module, and returns its
    /// index. `entry_specifier` is copied; `bindings_section` must be a
    /// section `route_bindings.decode` accepts and stays borrowed for the
    /// runtime's life. Fails with `error.TooManyRoutes` past
    /// `route_table.routes_max` routes.
    pub fn addRoute(
        self: *State,
        allocator: std.mem.Allocator,
        entry_specifier: []const u8,
        bindings_section: []const u8,
    ) !u16 {
        if (self.routes.items.len >= route_table.routes_max)
            return error.TooManyRoutes;
        const owned_specifier = try allocator.dupe(u8, entry_specifier);
        errdefer allocator.free(owned_specifier);
        try self.routes.append(allocator, .{
            .entry_specifier = owned_specifier,
            .bindings = bindings_section,
        });
        return @intCast(self.routes.items.len - 1);
    }

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        for (self.pending_settlements.items) |entry|
            allocator.free(entry.specifier);
        self.pending_settlements.deinit(allocator);
        self.stalled_waiters.deinit(allocator);

        var source_it = self.loaded_sources.keyIterator();
        while (source_it.next()) |specifier|
            allocator.free(specifier.*);
        self.loaded_sources.deinit(allocator);

        for (self.routes.items) |*route| {
            route.module.deinit(allocator);
            allocator.free(route.entry_specifier);
        }
        self.routes.deinit(allocator);
    }
};

comptime {
    // A dispatch names a route by a u16 index.
    std.debug.assert(route_table.routes_max <= std.math.maxInt(u16) + 1);
}

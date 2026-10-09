//! The worker's module bookkeeping, held by `Runtime` and used only on its VM
//! thread: the specifiers of every pack the worker registered, the state of
//! each route module, and the evaluation settlements waiting for the
//! scheduler loop. `routes.zig` changes both tables.
//! `collo_runtime_module_eval_settled` in `worker/host/module_settlement.zig`
//! appends to the settlement list, and `Runtime` in
//! `worker/runtime/modules.zig` drains it and keeps the stalled waiters and
//! `recycle_after_drain`.

const std = @import("std");
const runtime_types = @import("../runtime/types.zig");

pub const RouteModule = runtime_types.RouteModule;

/// A route module's state, keyed by its entry specifier. `failed` lasts for
/// the worker's life, so a request for the route fails at once and never
/// imports the module again. Hoisted `export default function` bindings are
/// initialized before the body runs, so a module whose init threw still
/// exports a callable handler; the pin keeps that handler from being served
/// whatever JSC returns for a re-import of a module whose evaluation failed.
pub const RouteModuleState = union(enum) {
    ready: RouteModule,
    /// A top-level await is in flight. Requests for the route park in
    /// `waiters` and are queued again when it settles. `deadline_mono_ns`
    /// bounds an await that never settles; a parked request's deadline path
    /// checks it (`evaluationZombie` in `routes.zig`).
    evaluating: Evaluating,
    /// The evaluation threw or its top-level await rejected. A rejected
    /// await also recycles the worker once its waiters drain
    /// (`recycle_after_drain`); after a synchronous throw the worker keeps
    /// serving and fails every request for this route.
    failed,

    pub const Evaluating = struct {
        waiters: std.ArrayListUnmanaged(u64) = .{},
        deadline_mono_ns: u64,
    };

    pub fn deinit(self: *RouteModuleState, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ready => |*module| module.deinit(),
            .evaluating => |*evaluating| evaluating.waiters.deinit(allocator),
            .failed => {},
        }
        self.* = undefined;
    }
};

/// An evaluation settlement that `collo_runtime_module_eval_settled`
/// reported from inside a microtask drain, parked until the scheduler loop
/// handles it in `Runtime.collectModuleSettlements`. The entry owns
/// `specifier`.
pub const PendingSettlement = struct {
    specifier: []u8,
    resolved: bool,
};

pub const State = struct {
    /// Every specifier of the packs the worker registered. Each is a route's
    /// pack, registered permanent, so a specifier never leaves. The set owns
    /// its keys.
    loaded_sources: std.StringHashMapUnmanaged(void) = .empty,
    route_modules: std.StringHashMapUnmanaged(RouteModuleState) = .empty,
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

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        for (self.pending_settlements.items) |entry|
            allocator.free(entry.specifier);
        self.pending_settlements.deinit(allocator);
        self.stalled_waiters.deinit(allocator);

        var source_it = self.loaded_sources.keyIterator();
        while (source_it.next()) |specifier|
            allocator.free(specifier.*);
        self.loaded_sources.deinit(allocator);

        var module_it = self.route_modules.iterator();
        while (module_it.next()) |entry| {
            entry.value_ptr.deinit(allocator);
            allocator.free(entry.key_ptr.*);
        }
        self.route_modules.deinit(allocator);
    }
};

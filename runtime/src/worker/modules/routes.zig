//! The routes of the worker's definition: the registration of the
//! definition's module pack, and the evaluation of each route's entry in the
//! route's realm, with the route records (`State.routes`) that cache each
//! ready route's handler and `env` (`RouteModule`). Runs on the worker's VM
//! thread.
//!
//! The worker's boot registers the pack WorkerInit delivered, as permanent
//! (`bootRegisterPack`), and evaluates every route's entry before the worker
//! reports ready (`bootEvaluateRoute`, which `Runtime.evaluateBootRoutes`
//! calls in route order); the pack's specifiers are recorded in
//! `State.loaded_sources`. A dispatch names its route by its index in the
//! route table and carries no pack, so a request for a route whose entry no
//! registered pack holds fails. The pack holds every module the routes' code
//! names with a string literal, so a handler's `import()` loads from the
//! registered packs alone, in the engine's loader (`moduleLoaderFetch` in
//! `bindings/jsc/runtime/module_loader.cpp`), with no message to the server.
//!
//! In a worker that isolates realms (`State.isolate_realm`), every route but
//! the first evaluates its entry in a realm of its own, with its own globals,
//! intrinsics and module registry, so two routes never share a module
//! instance. Otherwise every route runs in the VM's main realm, and routes
//! with the same entry share its instance and receive the same handler, each
//! with its own `env`. Realms separate state, not trust: every realm runs in
//! the same process under the same limits.
//!
//! Exports are read only after the evaluation settles, and a failed
//! evaluation stays failed for the worker's life (`RouteModuleState` in
//! `state.zig` says why). A synchronous throw, a rejected top-level await and
//! an await still pending past `module_eval_budget_ns` each pin only their
//! own route failed, and the route's requests get the same 500 in all three
//! cases while the other routes keep serving. The worker gives way to a fresh
//! one only once no route can serve (`pinFailed` owns the rule).

const std = @import("std");
const bindings = @import("collo_bindings");
const ipc = @import("collo_ipc");
const module_context = @import("context.zig");
const modules_state = @import("state.zig");
const route_env = @import("route_env.zig");
const js_value = @import("collo_worker_js").value;
const request_context = @import("collo_worker_request").context;
const tracing = @import("../serve/trace.zig");
const module_pack_io = @import("pack_io.zig");
const process = @import("collo_os").process;

const module_pack = ipc.module_pack;

pub const RouteModule = modules_state.RouteModule;
pub const RouteModuleState = modules_state.RouteModuleState;

/// A route ready to serve: its handler and `env`, and the realm the request's
/// `Request` is built in.
pub const ReadyRoute = struct {
    /// Points into the route list, which the runtime never changes after it
    /// starts, and stays valid until the route's record next changes, which
    /// happens only when its evaluation starts or settles.
    module: *const RouteModule,
    realm: bindings.Realm,
};

pub const RouteHandlerResult = union(enum) {
    ready: ReadyRoute,
    /// Owned by the caller.
    exception: bindings.Value,
    /// The entry's top-level await is in flight: the request joined the
    /// route's waiter list and runs again when the settlement queues it.
    pending,
};

/// How long a route module's top-level await may stay pending, from the
/// moment its evaluation goes pending; it matches the cap AWS Lambda puts on
/// a function's init phase. A hung await outlives every request that waits
/// on it, so past this budget its route is pinned failed (`expireEvaluation`)
/// and the requests parked on it get their 500.
pub const module_eval_budget_ns: u64 = 10 * std.time.ns_per_s;

/// The handler and `env` of the route `request_ctx` dispatches to. A route
/// still `idle` has its entry evaluated from the packs the worker
/// registered. Returns `.pending` after parking the request on an evaluation
/// in flight, and `.exception` when the evaluation or the export read threw,
/// after pinning the route failed. Fails with `error.UnknownRoute` for an
/// index past the route table, `error.RouteModuleEvaluationFailed` for a
/// route already failed, `error.RoutePackNotRegistered` when no registered
/// pack holds the route's entry, and otherwise with the error of the step
/// that failed: creating the route's realm, reading the handler or building
/// `env`.
pub fn ensureRouteHandler(
    ctx: *module_context.Context,
    request_ctx: *request_context.RequestContext,
) !RouteHandlerResult {
    const index = request_ctx.dispatch_work.route_index;
    if (index >= ctx.modules.routes.items.len)
        return error.UnknownRoute;
    const route = &ctx.modules.routes.items[index];
    switch (route.module) {
        .idle => {},
        .ready => |*module| return .{ .ready = .{ .module = module, .realm = route.realm.? } },
        .evaluating => |*evaluating| {
            try evaluating.waiters.append(ctx.allocator, request_ctx.exec.request_id);
            return .pending;
        },
        .failed => return error.RouteModuleEvaluationFailed,
    }

    if (!sourceLoaded(ctx, route.entry_specifier))
        return error.RoutePackNotRegistered;

    switch (try evaluateRoute(ctx, index, request_ctx.exec.request_id)) {
        .ready => {},
        .pending => return .pending,
        .exception => |exception| {
            // The route is pinned failed before the exception is served, so
            // later requests fail with `error.RouteModuleEvaluationFailed`
            // instead of importing the module again (`RouteModuleState` in
            // `state.zig`).
            markRouteThrew(ctx, index);
            return .{ .exception = exception };
        },
    }
    tracing.mark(ctx, request_ctx, "evaluate_module_done_ns");

    const ready = &ctx.modules.routes.items[index];
    return .{ .ready = .{ .module = &ready.module.ready, .realm = ready.realm.? } };
}

const EvaluateOutcome = union(enum) {
    ready,
    pending,
    exception: bindings.Value,
};

/// The one place a route's entry is evaluated, in the route's realm. A
/// synchronous success reads the handler at once through `finishReadyRoute`;
/// a top-level await moves the route to `evaluating`, which
/// `settleEvaluation` finishes later. `waiter_request_id` is the request to
/// park on that record, null on the boot path, which has no request. Fails
/// with `error.HandlerNotCallable` when the default export is not a function,
/// leaving the route `idle`.
fn evaluateRoute(
    ctx: *module_context.Context,
    index: usize,
    waiter_request_id: ?u64,
) !EvaluateOutcome {
    const realm = try routeRealm(ctx, index);
    const route = &ctx.modules.routes.items[index];
    std.debug.assert(route.module == .idle);
    switch (try realm.evaluateModule(route.entry_specifier)) {
        .success => switch (try finishReadyRoute(ctx, index)) {
            .ready => return .ready,
            .exception => |exception| return .{ .exception = exception },
        },
        .pending => {
            var evaluating = modules_state.RouteModuleState.Evaluating{
                .deadline_mono_ns = instanceDeadline(ctx, realm, route.entry_specifier) orelse
                    ctx.nowMonoNs() +| module_eval_budget_ns,
            };
            errdefer evaluating.waiters.deinit(ctx.allocator);
            if (waiter_request_id) |request_id|
                try evaluating.waiters.append(ctx.allocator, request_id);
            route.module = .{ .evaluating = evaluating };
            return .pending;
        },
        .exception => |exception| return .{ .exception = exception },
        .unsupported => |exception| return .{ .exception = exception },
    }
}

/// The deadline of the evaluation in flight for the module instance that
/// `specifier` names in `realm`, when another route already waits on it.
/// Routes that share an instance get one outcome from its one evaluation, so
/// they also share its deadline instead of each counting from its own start.
fn instanceDeadline(ctx: *module_context.Context, realm: bindings.Realm, specifier: []const u8) ?u64 {
    for (ctx.modules.routes.items) |*candidate| {
        const evaluating = switch (candidate.module) {
            .evaluating => |*evaluating| evaluating,
            .idle, .ready, .failed => continue,
        };
        if (sameInstance(candidate, realm.index(), specifier))
            return evaluating.deadline_mono_ns;
    }
    return null;
}

/// Whether `route` evaluates the module `specifier` names in the realm with
/// index `realm_index`, which is how a settlement names an instance.
fn sameInstance(route: *const modules_state.Route, realm_index: u32, specifier: []const u8) bool {
    const realm = route.realm orelse return false;
    if (realm.index() != realm_index)
        return false;
    return std.mem.eql(u8, route.entry_specifier, specifier);
}

/// The realm the route at `index` runs in, created on its first use: in a
/// worker that isolates realms every route but the first gets a new realm,
/// and every other route runs in the VM's main realm. Creating a realm runs
/// no JavaScript.
fn routeRealm(ctx: *module_context.Context, index: usize) !bindings.Realm {
    const route = &ctx.modules.routes.items[index];
    if (route.realm) |realm|
        return realm;
    const realm = if (ctx.modules.isolate_realm and index != 0)
        try ctx.vm.createRealm()
    else
        ctx.vm.mainRealm();
    route.realm = realm;
    return realm;
}

const ReadyOutcome = union(enum) {
    ready,
    exception: bindings.Value,
};

/// The only reader of a route's exports. Exports are live bindings, still in
/// their temporal dead zone or undefined until the evaluation promise
/// settles, so this runs only after settlement: a synchronous success or
/// `settleEvaluation`. The route's `env` is built here as well, from the
/// route's own bindings in the route's realm, so it exists once per ready
/// route; building it runs no JavaScript, which keeps this safe outside a
/// turn. Leaves the route `idle` on every path but `.ready`.
fn finishReadyRoute(ctx: *module_context.Context, index: usize) !ReadyOutcome {
    const route = &ctx.modules.routes.items[index];
    const realm = route.realm.?;
    const handler_value = switch (try realm.moduleGetExport(route.entry_specifier, "default")) {
        .success => |value| value,
        .exception => |exception| return .{ .exception = exception },
    };
    var handler = try js_value.JsFunctionOwned.fromOwnedValueChecked(ctx.vm, handler_value);
    errdefer handler.deinit();
    const env = try route_env.build(realm, route.bindings);
    route.module = .{ .ready = .{ .handler = handler, .env = env } };
    return .ready;
}

/// The end of one route's evaluation, settled or expired: the requests parked
/// on it, which the caller queues again so each runs against the route's new
/// state.
pub const Settlement = struct {
    /// Owned by the caller.
    waiters: std.ArrayListUnmanaged(u64),
};

/// Finishes the evaluation of the next route whose entry is `specifier` and
/// whose realm has index `realm_index`, among the routes still evaluating,
/// when `Runtime.collectModuleSettlements` handles the settlement that
/// `collo_runtime_module_eval_settled` reported. Routes that share a realm and
/// an entry share one module instance, so one settlement finishes each of
/// them, one call at a time. A resolved await makes the route ready through
/// `finishReadyRoute`; a rejected one pins it failed (`pinFailed`). Returns
/// the route's parked request ids for the caller to queue again, or null
/// once no route matches, as for a settlement that came late or twice, or
/// after its routes expired (`expireEvaluation`).
pub fn settleEvaluation(
    ctx: *module_context.Context,
    realm_index: u32,
    specifier: []const u8,
    resolved: bool,
) ?Settlement {
    const index = for (ctx.modules.routes.items, 0..) |*candidate, candidate_index| {
        if (candidate.module != .evaluating)
            continue;
        if (sameInstance(candidate, realm_index, specifier))
            break candidate_index;
    } else return null;
    if (!resolved) {
        std.log.warn("route module evaluation rejected; route pinned failed route={d} specifier={s}", .{
            index,
            specifier,
        });
        return .{ .waiters = pinFailed(ctx, index, .rejected) };
    }
    const route = &ctx.modules.routes.items[index];
    const waiters = route.module.evaluating.waiters;
    // The waiters move to the caller; the evaluating record owns nothing
    // else, so the tag flips in place.
    route.module = .idle;

    const outcome = finishReadyRoute(ctx, index) catch |err| blk: {
        std.log.warn("route module settlement finish failed route={d} specifier={s}: {s}", .{
            index,
            specifier,
            @errorName(err),
        });
        break :blk null;
    };
    if (outcome) |settled| switch (settled) {
        .ready => {},
        .exception => |exception| {
            var owned = exception;
            owned.deinit();
            std.log.warn("route module default export raised at settlement route={d} specifier={s}", .{ index, specifier });
        },
    };
    // The waiters run even when reading the handler failed: the route is
    // then `idle` again, and each evaluates the entry on its own.
    return .{ .waiters = waiters };
}

/// Pins failed the next route whose top-level await is still pending past
/// its deadline (`RouteModuleState.Evaluating.deadline_mono_ns`), as a
/// rejection would, and returns its parked request ids for the caller to
/// queue again, or null once no route has expired. The module's code may
/// still run and settle later; that settlement finds no route evaluating it
/// and is ignored, so the route stays failed. The caller decides when to
/// look (`deadlineTimeout` in `worker/serve/dispatch.zig`).
pub fn expireEvaluation(ctx: *module_context.Context) ?Settlement {
    const now = ctx.nowMonoNs();
    const index = for (ctx.modules.routes.items, 0..) |*candidate, candidate_index| {
        const evaluating = switch (candidate.module) {
            .evaluating => |*evaluating| evaluating,
            .idle, .ready, .failed => continue,
        };
        if (now >= evaluating.deadline_mono_ns)
            break candidate_index;
    } else return null;
    std.log.warn("route module evaluation exceeded its budget; route pinned failed route={d} specifier={s}", .{
        index,
        ctx.modules.routes.items[index].entry_specifier,
    });
    return .{ .waiters = pinFailed(ctx, index, .exceeded_budget) };
}

/// Whether any route's top-level await is still in flight. The boot context
/// closes once none is, after a settlement or an expiry
/// (`worker/runtime/modules.zig`).
pub fn anyEvaluating(ctx: *module_context.Context) bool {
    for (ctx.modules.routes.items) |route| {
        if (route.module == .evaluating)
            return true;
    }
    return false;
}

/// Monotonic stamps of the steps of the boot's pack registration
/// (`bootRegisterPack`), which its caller records as boot phases of their
/// own. A zero stamp means the clock could not be read.
pub const BootEvalMarks = struct {
    pack_mapped_ns: u64 = 0,
    pack_parsed_ns: u64 = 0,
    pack_registered_ns: u64 = 0,
};

/// Registers the definition's pack in `pack_fd`, a sealed memfd that stays
/// the caller's (`registerPack`), before the boot evaluates the routes. The
/// worker must hold at least one route, and the pack every route's entry. A
/// failure fails the init: no dispatch carries a pack, so a worker without
/// its routes' pack could serve none of their requests. A non-null `marks`
/// receives the registration's stamps.
pub fn bootRegisterPack(
    ctx: *module_context.Context,
    pack_fd: std.posix.fd_t,
    marks: ?*BootEvalMarks,
) !void {
    const routes = ctx.modules.routes.items;
    if (routes.len == 0)
        return error.NoRoutes;
    try registerPack(ctx, pack_fd, routes[0].entry_specifier, routes, marks);
}

/// What the boot left a route in (`bootEvaluateRoute`).
pub const BootRouteOutcome = enum {
    /// Nothing of the route is in flight: it is ready, failed or `idle`.
    settled,
    /// Its top-level await is in flight with the route `evaluating`; the
    /// caller arms `module_eval_budget_ns` on the boot context.
    pending,
};

/// Evaluates the entry of the route at `index` in the route's realm, after
/// `bootRegisterPack`, so a cold-started worker serves its first request
/// without module work. The caller evaluates every route in route order.
///
/// A failure to create the route's realm fails the init. A synchronous throw
/// pins the route failed, as a rejected top-level await does, and the worker
/// still reports ready but never serves that handler; the other routes are
/// unaffected. A default export that is not callable is logged and left
/// uncached, so each request for the route evaluates the entry again and
/// fails on its own. A route the boot already moved out of `idle` is left as
/// it is.
pub fn bootEvaluateRoute(ctx: *module_context.Context, index: usize) !BootRouteOutcome {
    if (ctx.modules.routes.items[index].module != .idle)
        return .settled;
    switch (evaluateRoute(ctx, index, null) catch |err| switch (err) {
        // An uncallable default export is the tenant's mistake and is left
        // to each request; every other error fails the init.
        error.HandlerNotCallable => {
            std.log.warn("boot route handler not callable route={d} specifier={s}", .{
                index,
                ctx.modules.routes.items[index].entry_specifier,
            });
            return .settled;
        },
        else => return err,
    }) {
        .ready => return .settled,
        // The event loop settles the top-level await after ready; a request
        // that arrives first parks as a waiter.
        .pending => return .pending,
        .exception => |exception| {
            var owned = exception;
            owned.deinit();
            // A synchronous throw pins the same failed record a rejected
            // top-level await does (`RouteModuleState` in `state.zig`), so the
            // route's requests fail at once with
            // `error.RouteModuleEvaluationFailed` and the worker answers each
            // with a 500.
            markRouteThrew(ctx, index);
            std.log.warn("boot route evaluation raised; route pinned failed route={d} specifier={s}", .{
                index,
                ctx.modules.routes.items[index].entry_specifier,
            });
            return .settled;
        },
    }
}

/// Registers the one-entry pack in `pack_fd`, which stays the caller's, as
/// `registerPack` does, for a runtime whose route list names `specifier`
/// without a boot: the pack must hold `specifier` and share its deploy
/// scope. Does nothing when a registered pack already holds `specifier`.
pub fn registerRoutePack(
    ctx: *module_context.Context,
    pack_fd: std.posix.fd_t,
    specifier: []const u8,
) !void {
    if (sourceLoaded(ctx, specifier))
        return;
    try registerPack(ctx, pack_fd, specifier, &.{}, null);
}

/// Registers the pack in `pack_fd`, a sealed memfd that stays the caller's,
/// with the VM as permanent, and records its specifiers in `loaded_sources`.
/// Every module of the pack must share the deploy scope of `scope_specifier`,
/// and the pack must hold `scope_specifier` and the entry of every route in
/// `routes`. A non-null `marks` receives the step stamps. Fails with the
/// error of the step that failed: mapping, parsing or checking the pack, or
/// registering it.
fn registerPack(
    ctx: *module_context.Context,
    pack_fd: std.posix.fd_t,
    scope_specifier: []const u8,
    routes: []const modules_state.Route,
    marks: ?*BootEvalMarks,
) !void {
    var pack = try module_pack_io.mapFdReadOnly(pack_fd, module_pack.max_pack_bytes);
    defer pack.deinit();
    if (marks) |m| m.pack_mapped_ns = process.monotonicNowNsOrZero();

    const parsed_pack = try module_pack.parse(pack.bytes());
    try module_pack.validateSameDeployScopedPack(parsed_pack, scope_specifier);
    if (!module_pack.containsSpecifier(parsed_pack, scope_specifier))
        return error.ModulePackEntryMismatch;
    for (routes) |route| {
        if (!module_pack.containsSpecifier(parsed_pack, route.entry_specifier))
            return error.ModulePackEntryMismatch;
    }
    if (marks) |m| m.pack_parsed_ns = process.monotonicNowNsOrZero();

    var staged = try stageLoadedSources(ctx, parsed_pack);
    defer staged.deinit(ctx.allocator);
    // Registration consumes the mapping that parsed_pack points into.
    try ctx.vm.registerModulePackMapping(pack.take(), .{
        .lifetime = @intFromEnum(bindings.ModuleLifetime.permanent),
    });
    staged.commit(ctx);
    if (marks) |m| m.pack_registered_ns = process.monotonicNowNsOrZero();
}

/// Pins the `idle` route at `index` failed after a synchronous throw, when
/// no `evaluating` record exists for `settleEvaluation` to flip.
fn markRouteThrew(ctx: *module_context.Context, index: usize) void {
    std.debug.assert(ctx.modules.routes.items[index].module == .idle);
    var waiters = pinFailed(ctx, index, .threw);
    // Only an evaluating record parks requests.
    std.debug.assert(waiters.items.len == 0);
    waiters.deinit(ctx.allocator);
}

/// The one place a route becomes failed, for the worker's life. Returns the
/// requests parked on the route's evaluation, which the caller owns and
/// queues again so each gets its 500, empty for an `idle` route. Changes the
/// tag in place and allocates nothing.
///
/// It also owns the rule that sets `State.recycle_after_drain`: the worker
/// gives way to a fresh one only once none of its routes can serve, and only
/// when one failed on an await (`RouteModuleState.Failure`), which a fresh
/// evaluation may get past. While any route is ready, still evaluating or
/// `idle`, the worker keeps serving, so one broken route never takes the
/// healthy ones down with it, and a worker whose routes all threw
/// synchronously keeps answering 500s instead of booting replacements that
/// would throw again.
fn pinFailed(
    ctx: *module_context.Context,
    index: usize,
    failure: modules_state.RouteModuleState.Failure,
) std.ArrayListUnmanaged(u64) {
    const route = &ctx.modules.routes.items[index];
    const waiters: std.ArrayListUnmanaged(u64) = switch (route.module) {
        .idle => .empty,
        // The waiters move to the caller; the evaluating record owns nothing
        // else.
        .evaluating => |evaluating| evaluating.waiters,
        .ready, .failed => unreachable,
    };
    route.module = .{ .failed = failure };
    if (freshWorkerMayServe(ctx.modules.routes.items))
        ctx.modules.recycle_after_drain = true;
    return waiters;
}

/// Whether every route is failed and at least one on an await.
fn freshWorkerMayServe(routes: []const modules_state.Route) bool {
    var await_failed = false;
    for (routes) |route| {
        switch (route.module) {
            .idle, .ready, .evaluating => return false,
            .failed => |failure| switch (failure) {
                .threw => {},
                .rejected, .exceeded_budget => await_failed = true,
            },
        }
    }
    return await_failed;
}

/// Whether a pack the worker registered holds `specifier`.
fn sourceLoaded(ctx: *module_context.Context, specifier: []const u8) bool {
    return ctx.modules.loaded_sources.contains(specifier);
}

/// A pack's specifiers copied out of its mapping, so they survive the
/// registration that consumes the mapping, with room for all of them already
/// reserved in `loaded_sources`. Built before registration, committed only
/// after it succeeds.
const StagedSources = struct {
    /// Owned copies; `commit` moves into the set the ones it inserts and
    /// leaves the rest for `deinit`.
    specifiers: [][]u8,

    fn deinit(self: *StagedSources, allocator: std.mem.Allocator) void {
        for (self.specifiers) |specifier|
            allocator.free(specifier);
        allocator.free(self.specifiers);
        self.* = undefined;
    }

    /// Records every staged specifier in `loaded_sources`. Cannot fail:
    /// `stageLoadedSources` reserved the capacity, and nothing else touches
    /// the set on the VM thread in between.
    fn commit(self: *StagedSources, ctx: *module_context.Context) void {
        for (self.specifiers) |*specifier| {
            const entry = ctx.modules.loaded_sources.getOrPutAssumeCapacity(specifier.*);
            if (entry.found_existing)
                continue;
            specifier.* = specifier.*[0..0];
        }
    }
};

/// The caller owns the result and frees it with `deinit`. Fails with
/// `error.OutOfMemory`, or with `error.ModulePackTooLarge` for a pack with
/// more records than the set can reserve at once.
fn stageLoadedSources(ctx: *module_context.Context, parsed_pack: module_pack.Parsed) !StagedSources {
    const count = parsed_pack.records.len;
    const specifiers = try ctx.allocator.alloc([]u8, count);
    var copied: usize = 0;
    errdefer {
        for (specifiers[0..copied]) |specifier|
            ctx.allocator.free(specifier);
        ctx.allocator.free(specifiers);
    }
    for (specifiers, 0..) |*specifier, index| {
        specifier.* = try ctx.allocator.dupe(u8, parsed_pack.moduleAt(index).specifier);
        copied += 1;
    }
    try ctx.modules.loaded_sources.ensureUnusedCapacity(
        ctx.allocator,
        std.math.cast(u32, count) orelse return error.ModulePackTooLarge,
    );
    return .{ .specifiers = specifiers };
}

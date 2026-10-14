//! The routes of the worker's definition: the boot that registers the
//! definition's artifact and takes its routes from it, the evaluation of each
//! route's entry in the route's realm, and the route records
//! (`State.routes`) that cache each ready route's handler and `env`
//! (`RouteModule`). Runs on the worker's VM thread.
//!
//! The worker boots once (`bootRegisterPack`, then `bootEvaluateRoute` for
//! every route in route order, which `Runtime.evaluateBootRoutes` drives)
//! before it reports ready. The artifact WorkerInit delivered
//! (`common/ipc/module_pack.zig`) holds every module the routes' code names
//! with a string literal and the routes themselves, so after the boot a
//! handler's `import()` loads from the registered pack alone, in the engine's
//! loader (`moduleLoaderFetch` in `bindings/jsc/runtime/module_loader.cpp`),
//! with no message to the server, and no request ever evaluates a module.
//! After the boot every route is ready, evaluating its top-level await, or
//! failed, and a dispatch names its route by its index in the artifact.
//!
//! In a worker that isolates realms (`State.isolate_realm`), every route but
//! the first evaluates its entry in a realm of its own, with its own globals,
//! intrinsics and module registry, so two routes never share a module
//! instance. Otherwise every route runs in the VM's main realm, and routes
//! with the same entry share its instance and receive the same handler, each
//! with its own `env`. Realms separate state, not trust: every realm runs in
//! the same process under the same limits.
//!
//! Exports are read only after the evaluation settles, and a failed route
//! stays failed for the worker's life (`RouteModuleState` in `state.zig` says
//! why). A route's handler is its default export when that is callable, and
//! otherwise the `fetch` of an object default export, called with the object
//! as `this`, the shape Cloudflare Workers and Hono's `export default app`
//! use. The handler is read once, when the route becomes ready, so a later
//! change to the default export never changes it (`resolveHandler`). A
//! synchronous throw, a default export that offers no handler, a read of the
//! default export or of its `fetch` that raises, a rejected top-level await,
//! an await still pending past `module_eval_budget_ns`, and an error of the
//! worker's own when an await settles each pin only their own route failed,
//! and the route's requests get the same 500 in every case while the other
//! routes keep serving. The worker gives way to a fresh one only once no
//! route can serve (`pinFailed` owns the rule).
//!
//! A route's entry runs under the evaluation of its module instance, which
//! the caller holds open and passes by id (`worker/runtime/evaluations.zig`
//! opens and closes it); the route's `evaluating` record keeps that id, and
//! routes that share an instance share it. This file decides which routes
//! evaluate under an evaluation and nothing about its context.

const std = @import("std");
const bindings = @import("collo_bindings");
const ipc = @import("collo_ipc");
const module_context = @import("context.zig");
const modules_state = @import("state.zig");
const route_env = @import("route_env.zig");
const js_value = @import("collo_worker_js").value;
const request_context = @import("collo_worker_request").context;
const module_pack_io = @import("pack_io.zig");
const process = @import("collo_os").process;

const module_pack = ipc.module_pack;

pub const RouteModule = modules_state.RouteModule;
pub const RouteModuleState = modules_state.RouteModuleState;

/// A route ready to serve: its handler and `env`, and the realm the request's
/// `Request` is built in.
pub const ReadyRoute = struct {
    /// Points into the route list, which the runtime never changes after its
    /// boot, at a ready record, which never changes again.
    module: *const RouteModule,
    realm: bindings.Realm,
};

/// What a route offers a request (`lookupRouteHandler`).
pub const RouteLookup = union(enum) {
    ready: ReadyRoute,
    /// The entry's top-level await is in flight: the request joined the
    /// route's waiter list and runs again when the settlement queues it.
    pending,
};

pub const module_eval_budget_ns: u64 = @import("collo_limits").process.MODULE_EVAL_BUDGET_NS;

/// The handler and `env` of the route `request_ctx` dispatches to. Returns
/// `.pending` after parking the request on the evaluation in flight. Fails
/// with `error.UnknownRoute` for an index past the routes,
/// `error.RouteModuleEvaluationFailed` for a failed route,
/// `error.RouteNotEvaluated` for a route still `idle`, which the boot leaves
/// only while it runs or when it failed partway, so a worker that reported
/// ready never answers it, and with OutOfMemory when the request cannot be
/// parked.
pub fn lookupRouteHandler(
    ctx: *module_context.Context,
    request_ctx: *request_context.RequestContext,
) !RouteLookup {
    const index = request_ctx.dispatch_work.route_index;
    if (index >= ctx.modules.routes.items.len)
        return error.UnknownRoute;
    const route = &ctx.modules.routes.items[index];
    switch (route.module) {
        .ready => |*module| return .{ .ready = .{ .module = module, .realm = route.realm.? } },
        .evaluating => |*evaluating| {
            try evaluating.waiters.append(ctx.allocator, request_ctx.exec.request_id);
            return .pending;
        },
        .failed => return error.RouteModuleEvaluationFailed,
        .idle => return error.RouteNotEvaluated,
    }
}

const EvaluateOutcome = union(enum) {
    ready,
    pending,
    exception: bindings.Value,
    no_handler: NoHandler,
};

/// What a route's default export held when it offered no handler: neither a
/// callable value nor an object whose `fetch` is callable. The line that
/// pins the route failed names it, as `default_export=<kind>` and, for an
/// object, `fetch=<kind>`.
pub const NoHandler = struct {
    default_export: bindings.ValueKind,
    /// The kind of the object's `fetch`; null when the default export is
    /// not an object, so no `fetch` was read.
    fetch: ?bindings.ValueKind,

    pub fn format(self: NoHandler, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("default_export={s}", .{@tagName(self.default_export)});
        if (self.fetch) |fetch|
            try writer.print(" fetch={s}", .{@tagName(fetch)});
    }
};

/// The one place a route's entry is evaluated, in the route's realm, for the
/// boot. A synchronous success reads the handler at once through
/// `finishReadyRoute`; a top-level await moves the route to `evaluating`,
/// which `settleEvaluation` finishes later. `evaluation_id` is the evaluation
/// the caller holds open and installed for the entry's code: the one in
/// flight for the route's module instance when there is one
/// (`evaluationInFlight`), else a new one. Every outcome but `.ready` and
/// `.pending` leaves the route `idle` for the caller to pin.
fn evaluateRoute(ctx: *module_context.Context, index: usize, evaluation_id: u64) !EvaluateOutcome {
    const realm = try routeRealm(ctx, index);
    const route = &ctx.modules.routes.items[index];
    std.debug.assert(route.module == .idle);
    switch (try realm.evaluateModule(route.entry_specifier)) {
        .success => switch (try finishReadyRoute(ctx, index)) {
            .ready => return .ready,
            .exception => |exception| return .{ .exception = exception },
            .no_handler => |no_handler| return .{ .no_handler = no_handler },
        },
        .pending => {
            // Routes that share an instance get one outcome from its one
            // evaluation, so they also share its deadline and its owner
            // instead of each counting from its own start.
            const shared = instanceEvaluating(ctx, realm.index(), route.entry_specifier);
            if (shared) |instance|
                std.debug.assert(instance.evaluation_id == evaluation_id);
            route.module = .{ .evaluating = .{
                .deadline_mono_ns = if (shared) |instance|
                    instance.deadline_mono_ns
                else
                    ctx.nowMonoNs() +| module_eval_budget_ns,
                .evaluation_id = evaluation_id,
            } };
            return .pending;
        },
        .exception => |exception| return .{ .exception = exception },
        .unsupported => |exception| return .{ .exception = exception },
    }
}

/// The `evaluating` record of a route that evaluates the module instance
/// `specifier` names in the realm with index `realm_index`; every route of
/// the instance holds the same deadline and evaluation. Null once none does.
fn instanceEvaluating(
    ctx: *module_context.Context,
    realm_index: u32,
    specifier: []const u8,
) ?*const modules_state.RouteModuleState.Evaluating {
    for (ctx.modules.routes.items) |*candidate| {
        const evaluating = switch (candidate.module) {
            .evaluating => |*evaluating| evaluating,
            .idle, .ready, .failed => continue,
        };
        if (sameInstance(candidate, realm_index, specifier))
            return evaluating;
    }
    return null;
}

/// The evaluation of the module instance `specifier` names in the realm with
/// index `realm_index`, while a route still evaluates it; null once none
/// does, as for a settlement that came late or twice.
pub fn instanceEvaluation(ctx: *module_context.Context, realm_index: u32, specifier: []const u8) ?u64 {
    const evaluating = instanceEvaluating(ctx, realm_index, specifier) orelse return null;
    return evaluating.evaluation_id;
}

/// The evaluation in flight for the module instance the `idle` route at
/// `index` would evaluate, which the route then joins; null when its
/// evaluation would start the instance. A route without a realm yet would
/// run in the main realm, index 0, unless the worker isolates realms and it
/// is not route 0, in which case its realm, and so its instance, will be new.
pub fn evaluationInFlight(ctx: *module_context.Context, index: usize) ?u64 {
    const route = &ctx.modules.routes.items[index];
    const realm_index: u32 = if (route.realm) |realm|
        realm.index()
    else if (ctx.modules.isolate_realm and index != 0)
        return null
    else
        0;
    return instanceEvaluation(ctx, realm_index, route.entry_specifier);
}

/// Whether any route still evaluates under evaluation `evaluation_id`.
pub fn evaluationOpen(ctx: *module_context.Context, evaluation_id: u64) bool {
    return evaluationDeadline(ctx, evaluation_id) != null;
}

/// The deadline of the routes that evaluate under evaluation
/// `evaluation_id`, the budget of the instance they share; null once none
/// does.
pub fn evaluationDeadline(ctx: *module_context.Context, evaluation_id: u64) ?u64 {
    for (ctx.modules.routes.items) |*route| {
        const evaluating = switch (route.module) {
            .evaluating => |*evaluating| evaluating,
            .idle, .ready, .failed => continue,
        };
        if (evaluating.evaluation_id == evaluation_id)
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
    /// Reading the default export, or its `fetch`, raised.
    exception: bindings.Value,
    no_handler: NoHandler,
};

/// The only reader of a route's exports. Exports are live bindings, still in
/// their temporal dead zone or undefined until the evaluation promise
/// settles, so this runs only after settlement: a synchronous success or
/// `settleEvaluation`. The route's `env` is built here as well, from the
/// route's own bindings in the route's realm, so it exists once per ready
/// route; building it runs no JavaScript. Reading the handler can run a
/// getter (`resolveHandler`), and the runtime runs this under the route's
/// evaluation, installed as the turnless context with its owner window open
/// (`bootEvaluateUnder` in `worker/runtime/evaluations.zig`,
/// `settleUnderOwner` in `worker/runtime/modules.zig`), so that getter runs
/// under the evaluation's deadline like the rest of the module's top-level
/// code. Leaves the route `idle` on every path but `.ready`.
fn finishReadyRoute(ctx: *module_context.Context, index: usize) !ReadyOutcome {
    const route = &ctx.modules.routes.items[index];
    const realm = route.realm.?;
    const default_export = switch (try realm.moduleGetExport(route.entry_specifier, "default")) {
        .success => |value| value,
        .exception => |exception| return .{ .exception = exception },
    };
    var handler = switch (try resolveHandler(ctx.vm, realm, default_export)) {
        .handler => |handler| handler,
        .exception => |exception| return .{ .exception = exception },
        .no_handler => |no_handler| return .{ .no_handler = no_handler },
    };
    errdefer handler.deinit();
    const env = try route_env.build(realm, route.bindings);
    route.module = .{ .ready = .{ .handler = handler, .env = env } };
    return .ready;
}

const HandlerResolution = union(enum) {
    handler: modules_state.RouteHandler,
    /// Reading the object's `fetch` raised.
    exception: bindings.Value,
    no_handler: NoHandler,
};

/// The handler `default_export` offers, taking ownership of it on every
/// path: the default export itself when it is callable, else the `fetch` of
/// an object default export when that is callable, with the object as its
/// receiver, as Cloudflare Workers calls `export default { fetch }` and as
/// Hono's `app.fetch` and a class's prototype method need. The callable test
/// comes first, so a function with a `fetch` property of its own is still
/// the handler. `fetch` is read here, once: the route keeps the function and
/// its receiver rooted, so assigning another `fetch` to the object later, or
/// changing its prototype, never changes the route's handler. The read is an
/// ordinary property get, so a getter or a proxy trap runs, and what it
/// throws comes back as `.exception`.
fn resolveHandler(
    vm: *bindings.Vm,
    realm: bindings.Realm,
    default_export: bindings.Value,
) !HandlerResolution {
    var exported = js_value.JsValueOwned.fromOwnedValue(default_export);
    defer exported.deinit();
    if (js_value.JsFunctionOwned.initChecked(vm, exported.borrowed())) |function| {
        return .{ .handler = .{ .function = function, .receiver = null } };
    } else |err| switch (err) {
        error.HandlerNotCallable => {},
        else => return err,
    }
    const export_kind = try vm.valueKind(exported.ptr());
    if (export_kind != .object)
        return .{ .no_handler = .{ .default_export = export_kind, .fetch = null } };

    const fetch_value = switch (try realm.objectGetUtf8(exported.ptr(), "fetch")) {
        .success => |value| value,
        .exception => |exception| return .{ .exception = exception },
    };
    var fetch = js_value.JsValueOwned.fromOwnedValue(fetch_value);
    defer fetch.deinit();
    if (js_value.JsFunctionOwned.initChecked(vm, fetch.borrowed())) |function| {
        return .{ .handler = .{
            .function = function,
            .receiver = js_value.JsObjectOwned{ .inner = exported.take() },
        } };
    } else |err| switch (err) {
        error.HandlerNotCallable => {},
        else => return err,
    }
    return .{ .no_handler = .{ .default_export = .object, .fetch = try vm.valueKind(fetch.ptr()) } };
}

/// The end of one route's evaluation, settled or expired: the requests parked
/// on it, which the caller queues again so each runs against the route's new
/// state.
pub const Settlement = struct {
    /// Owned by the caller.
    waiters: std.ArrayListUnmanaged(u64),
    /// The evaluation the route evaluated under, which the caller closes
    /// once no other route still evaluates under it.
    evaluation_id: u64,
};

/// Finishes the evaluation of the next route whose entry is `specifier` and
/// whose realm has index `realm_index`, among the routes still evaluating,
/// when `Runtime.collectModuleSettlements` handles the settlement that
/// `collo_runtime_module_eval_settled` reported. Routes that share a realm and
/// an entry share one module instance, so one settlement finishes each of
/// them, one call at a time. A resolved await makes the route ready through
/// `finishReadyRoute`; it pins the route failed with `threw` when the default
/// export offers no handler or reading it or its `fetch` raised, which no
/// fresh evaluation of the module would change, and with `internal_error`
/// for any error, such as an allocation failure while the handler is read or
/// the `env` built, which a fresh worker may not meet. A rejected await pins
/// the route failed with `rejected` (`pinFailed`).
/// Returns the route's parked request ids for the caller to queue again, or
/// null once no route matches, as for a settlement that came late or twice,
/// or after its routes expired (`expireEvaluation`).
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
    const evaluation_id = ctx.modules.routes.items[index].module.evaluating.evaluation_id;
    if (!resolved) {
        std.log.warn("route module evaluation rejected; route pinned failed route={d} specifier={s}", .{
            index,
            specifier,
        });
        return .{ .waiters = pinFailed(ctx, index, .rejected), .evaluation_id = evaluation_id };
    }
    const route = &ctx.modules.routes.items[index];
    const waiters = route.module.evaluating.waiters;
    // The waiters move to the caller; the evaluating record owns nothing
    // else, so the tag flips in place.
    route.module = .idle;

    const outcome = finishReadyRoute(ctx, index) catch |err| {
        std.log.warn("route handler unreadable at settlement; route pinned failed route={d} specifier={s} failure=internal_error: {s}", .{
            index,
            specifier,
            @errorName(err),
        });
        pinIdleRoute(ctx, index, .internal_error);
        return .{ .waiters = waiters, .evaluation_id = evaluation_id };
    };
    switch (outcome) {
        .ready => {},
        .exception => |exception| {
            var owned = exception;
            owned.deinit();
            std.log.warn("route default export or its fetch raised at settlement; route pinned failed route={d} specifier={s}", .{
                index,
                specifier,
            });
            pinIdleRoute(ctx, index, .threw);
        },
        .no_handler => |no_handler| {
            std.log.warn("route default export offers no handler at settlement; route pinned failed route={d} specifier={s} {f}", .{
                index,
                specifier,
                no_handler,
            });
            pinIdleRoute(ctx, index, .threw);
        },
    }
    // The waiters run against the route's new state: its handler, or the
    // 500 of a failed route.
    return .{ .waiters = waiters, .evaluation_id = evaluation_id };
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
    const evaluation_id = ctx.modules.routes.items[index].module.evaluating.evaluation_id;
    return .{ .waiters = pinFailed(ctx, index, .exceeded_budget), .evaluation_id = evaluation_id };
}

/// Monotonic stamps of the steps of the boot's registration
/// (`bootRegisterPack`), which its caller records as boot phases of their
/// own. A zero stamp means the clock could not be read.
pub const BootEvalMarks = struct {
    pack_mapped_ns: u64 = 0,
    pack_parsed_ns: u64 = 0,
    pack_registered_ns: u64 = 0,
};

/// Registers the definition's artifact in `pack_fd`, a sealed memfd that
/// stays the caller's, and adds every route it carries, before the boot
/// evaluates them. The artifact must pass `module_pack.parse` and
/// `module_pack.validateDefinition`, which is the worker's only check of its
/// bytes; the bridge reads them afterwards through bounds-checked offsets. A
/// runtime boots once, so a runtime that holds routes fails with
/// `error.RoutesAlreadyBooted`. Any failure fails the init: no dispatch
/// carries code, so a worker without its routes could serve none of their
/// requests. A non-null `marks` receives the step stamps. Fails with the
/// error of the step that failed: mapping, parsing or checking the artifact,
/// reserving the routes, or registering it.
pub fn bootRegisterPack(
    ctx: *module_context.Context,
    pack_fd: std.posix.fd_t,
    marks: ?*BootEvalMarks,
) !void {
    if (ctx.modules.routes.items.len != 0)
        return error.RoutesAlreadyBooted;
    var pack = try module_pack_io.mapFdReadOnly(pack_fd, module_pack.max_pack_bytes);
    defer pack.deinit();
    if (marks) |m| m.pack_mapped_ns = process.monotonicNowNsOrZero();

    const parsed = try module_pack.parse(pack.bytes());
    try module_pack.validateDefinition(parsed);
    if (marks) |m| m.pack_parsed_ns = process.monotonicNowNsOrZero();

    // Reserved before the registration, so nothing after it can fail.
    try ctx.modules.routes.ensureTotalCapacityPrecise(ctx.allocator, parsed.routes.len);
    // The registration consumes the mapping `parsed` points into. Once it
    // succeeds, the VM keeps that mapping valid until it is destroyed, since
    // a worker never unregisters its pack, so the routes borrow their entry
    // specifiers and bindings from it (`Route` in `state.zig`).
    try ctx.vm.registerModulePackMapping(pack.take());
    for (0..parsed.routes.len) |route_index| {
        const route = parsed.routeAt(route_index);
        ctx.modules.routes.appendAssumeCapacity(.{
            .entry_specifier = route.entry_specifier,
            .bindings = route.bindings,
        });
    }
    if (marks) |m| m.pack_registered_ns = process.monotonicNowNsOrZero();
}

/// What the boot left a route in (`bootEvaluateRoute`).
pub const BootRouteOutcome = enum {
    /// Nothing of the route is in flight: it is ready or failed.
    settled,
    /// Its top-level await is in flight with the route `evaluating`; the
    /// caller arms the route's evaluation at its budget.
    pending,
};

/// Evaluates the entry of the route at `index`, still `idle`, in the route's
/// realm, under evaluation `evaluation_id` (`evaluateRoute` says which id
/// that must be), after `bootRegisterPack`, so a cold-started worker serves
/// its first request without module work. The caller evaluates every route
/// in route order.
///
/// A failure to create the route's realm, to read its handler for a cause of
/// the worker's own, or to build its `env` fails the init. A synchronous
/// throw, a read of the handler that raises and a default export that offers
/// no handler are the tenant's mistakes, which no later evaluation of the
/// same module instance can get past: they pin the route failed with
/// `threw`, as a rejected top-level await pins it with `rejected`, and are
/// logged once here. The worker still reports ready and answers the route's
/// requests with a 500, and the other routes are unaffected.
pub fn bootEvaluateRoute(ctx: *module_context.Context, index: usize, evaluation_id: u64) !BootRouteOutcome {
    switch (try evaluateRoute(ctx, index, evaluation_id)) {
        .ready => return .settled,
        // The event loop settles the top-level await after ready; a request
        // that arrives first parks as a waiter.
        .pending => return .pending,
        .exception => |exception| {
            var owned = exception;
            owned.deinit();
            pinIdleRoute(ctx, index, .threw);
            std.log.warn("boot route evaluation or handler read raised; route pinned failed route={d} specifier={s}", .{
                index,
                ctx.modules.routes.items[index].entry_specifier,
            });
            return .settled;
        },
        .no_handler => |no_handler| {
            pinIdleRoute(ctx, index, .threw);
            std.log.warn("boot route default export offers no handler; route pinned failed route={d} specifier={s} {f}", .{
                index,
                ctx.modules.routes.items[index].entry_specifier,
                no_handler,
            });
            return .settled;
        },
    }
}

/// Pins the `idle` route at `index` failed with `failure`, when no
/// `evaluating` record parks requests on it.
fn pinIdleRoute(
    ctx: *module_context.Context,
    index: usize,
    failure: modules_state.RouteModuleState.Failure,
) void {
    std.debug.assert(ctx.modules.routes.items[index].module == .idle);
    var waiters = pinFailed(ctx, index, failure);
    // Only an evaluating record parks requests.
    std.debug.assert(waiters.items.len == 0);
    waiters.deinit(ctx.allocator);
}

/// The one place a route becomes failed, for the worker's life. Returns the
/// requests parked on the route's evaluation, which the caller owns and
/// queues again so each gets its 500, empty for an `idle` route. Changes the
/// tag in place and allocates nothing.
///
/// It also owns the rule that sets `State.fresh_worker_may_serve`: the
/// worker gives way to a fresh one only once none of its routes can serve,
/// and only when one failed on an await or on an error of this worker
/// (`RouteModuleState.Failure`), which a fresh worker may get past. While
/// any route is ready or still evaluating, the worker keeps serving, so one
/// broken route never takes the healthy ones down with it, and a worker
/// whose routes all threw synchronously keeps answering 500s instead of
/// booting replacements that would throw again.
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
        ctx.modules.fresh_worker_may_serve = true;
    return waiters;
}

/// Whether every route is failed and at least one for a cause a fresh
/// worker may not meet.
fn freshWorkerMayServe(routes: []const modules_state.Route) bool {
    var fresh_worker_may_pass = false;
    for (routes) |route| {
        switch (route.module) {
            .idle, .ready, .evaluating => return false,
            .failed => |failure| switch (failure) {
                .threw => {},
                .rejected, .exceeded_budget, .internal_error => fresh_worker_may_pass = true,
            },
        }
    }
    return fresh_worker_may_pass;
}

//! Registration and evaluation of a route's entry module, and the table of
//! route module states (`State.route_modules`) that caches each ready
//! route's handler and `env` object (`RouteModule`). Runs on the worker's VM
//! thread. A route's pack is registered once, as permanent, before any
//! request names the route: the worker's boot registers the pack of
//! WorkerInit's route entry (`bootEvaluateRouteEntry`), and its specifiers
//! are recorded in `State.loaded_sources`. A dispatch names its route's
//! entry and carries no pack, so a request for a route no registered pack
//! holds fails. The pack holds every module the route's code names with a
//! string literal, so a handler's `import()` loads from the registered packs
//! alone, in the engine's loader (`moduleLoaderFetch` in
//! `bindings/jsc/runtime/module_loader.cpp`), with no message to the server.
//! Exports are read only after the evaluation settles, and a failed
//! evaluation stays failed for the worker's life (`RouteModuleState` in
//! `state.zig` says why).

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

pub const RouteHandlerResult = union(enum) {
    /// Points into the route-module table and stays valid until the table
    /// next changes, which happens only when a route's evaluation starts or
    /// settles.
    ready: *const modules_state.RouteModule,
    /// Owned by the caller.
    exception: bindings.Value,
    /// The entry's top-level await is in flight: the request joined the
    /// module's waiter list and runs again when the settlement queues it.
    pending,
};

/// How long a route module's top-level await may stay pending, from the
/// moment its evaluation goes pending; it matches the cap AWS Lambda puts on
/// a function's init phase. A hung await outlives every request, and traffic
/// keeps the worker from idling out, so past this budget the worker recycles
/// (`evaluationZombie`).
pub const module_eval_budget_ns: u64 = 10 * std.time.ns_per_s;

/// The handler and `env` of the route `request_ctx` dispatches to. A route
/// with no record yet has its entry evaluated from the pack the worker
/// registered (`registerRoutePack`). Returns `.pending` after parking the
/// request on an evaluation in flight, and `.exception` when the evaluation
/// or the export read threw, after pinning the route failed. Fails with
/// `error.RouteModuleEvaluationFailed` for a route already failed,
/// `error.RoutePackNotRegistered` when no registered pack holds the route's
/// entry, and otherwise with the error of the step that failed: reading the
/// handler or building `env`.
pub fn ensureRouteHandler(
    ctx: *module_context.Context,
    request_ctx: *request_context.RequestContext,
) !RouteHandlerResult {
    const specifier = request_ctx.dispatch_work.route_entry_specifier;

    if (ctx.modules.route_modules.getPtr(specifier)) |module_state| {
        switch (module_state.*) {
            .ready => {},
            .evaluating => |*evaluating| {
                try evaluating.waiters.append(ctx.allocator, request_ctx.exec.request_id);
                return .pending;
            },
            .failed => return error.RouteModuleEvaluationFailed,
        }
        return .{ .ready = readyRoute(ctx, specifier) orelse return error.HandlerNotCallable };
    }

    if (!sourceLoaded(ctx, specifier))
        return error.RoutePackNotRegistered;

    switch (try evaluateRouteModule(ctx, specifier, request_ctx.exec.request_id)) {
        .ready => {},
        .pending => return .pending,
        .exception => |exception| {
            // The route is pinned failed before the exception is served, so
            // later requests fail with `error.RouteModuleEvaluationFailed`
            // instead of importing the module again (`RouteModuleState` in
            // `state.zig`). A failure to pin, out of memory, propagates as on
            // the boot path: served without the pin, the route's failure would
            // rest on what JSC returns when the next request imports it again.
            var owned = exception;
            errdefer owned.deinit();
            try markRouteModuleFailed(ctx, specifier);
            return .{ .exception = owned };
        },
    }
    tracing.mark(ctx, request_ctx, "evaluate_module_done_ns");

    return .{ .ready = readyRoute(ctx, specifier) orelse return error.HandlerNotCallable };
}

const EvaluateOutcome = union(enum) {
    ready,
    pending,
    exception: bindings.Value,
};

/// The one place a route module is evaluated. A synchronous success reads
/// the handler at once through `finishReadyModule`; a top-level await parks
/// an `evaluating` record that `settleEvaluation` finishes later.
/// `waiter_request_id` is the request to park on that record, null on the
/// boot path, which has no request.
fn evaluateRouteModule(
    ctx: *module_context.Context,
    specifier: []const u8,
    waiter_request_id: ?u64,
) !EvaluateOutcome {
    switch (try ctx.vm.evaluateModule(specifier)) {
        .success => switch (try finishReadyModule(ctx, specifier)) {
            .ready => return .ready,
            .exception => |exception| return .{ .exception = exception },
        },
        .pending => {
            const owned_specifier = try ctx.allocator.dupe(u8, specifier);
            errdefer ctx.allocator.free(owned_specifier);
            var evaluating = modules_state.RouteModuleState.Evaluating{
                .deadline_mono_ns = ctx.nowMonoNs() +| module_eval_budget_ns,
            };
            errdefer evaluating.waiters.deinit(ctx.allocator);
            if (waiter_request_id) |request_id|
                try evaluating.waiters.append(ctx.allocator, request_id);
            try ctx.modules.route_modules.putNoClobber(
                ctx.allocator,
                owned_specifier,
                .{ .evaluating = evaluating },
            );
            return .pending;
        },
        .exception => |exception| return .{ .exception = exception },
        .unsupported => |exception| return .{ .exception = exception },
    }
}

const ReadyOutcome = union(enum) {
    ready,
    exception: bindings.Value,
};

/// The only reader of a route module's exports. Exports are live bindings,
/// still in their temporal dead zone or undefined until the evaluation
/// promise settles, so this runs only after settlement: a synchronous
/// success or `settleEvaluation`. The route's `env` is built here as well,
/// so it exists once per ready route; building it runs no JavaScript, which
/// keeps this safe outside a turn.
fn finishReadyModule(ctx: *module_context.Context, specifier: []const u8) !ReadyOutcome {
    // The worker's one bindings blob belongs to one route (`route_env.zig`).
    // Any other route fails, since it would otherwise receive that route's
    // secrets; a blob without bindings has none to give away.
    if (ctx.route_bindings_blob.len > route_env.empty_blob.len) {
        if (!std.mem.eql(u8, specifier, ctx.route_bindings_route))
            return error.RouteBindingsBelongToAnotherRoute;
    }
    const handler_value = switch (try ctx.vm.moduleGetExport(specifier, "default")) {
        .success => |value| value,
        .exception => |exception| return .{ .exception = exception },
    };
    var handler = try js_value.JsFunctionOwned.fromOwnedValueChecked(ctx.vm, handler_value);
    errdefer handler.deinit();
    var env = try route_env.build(ctx.vm, ctx.route_bindings_blob);
    errdefer env.deinit();

    const owned_specifier = try ctx.allocator.dupe(u8, specifier);
    errdefer ctx.allocator.free(owned_specifier);
    try ctx.modules.route_modules.putNoClobber(ctx.allocator, owned_specifier, .{
        .ready = .{ .handler = handler, .env = env },
    });
    return .ready;
}

pub const Settlement = struct {
    waiters: std.ArrayListUnmanaged(u64) = .{},
    /// `.none` for a settlement that came late or twice, after the record
    /// had already left `.evaluating`; the caller must not act on it.
    /// `.ready` means the await resolved, even when reading the handler then
    /// failed and left the next request to try again.
    transition: enum { none, ready, failed } = .none,
};

/// Finishes a pending evaluation that `collo_runtime_module_eval_settled`
/// reported, when `Runtime.collectModuleSettlements` handles it. A resolved
/// await moves the record to ready through `finishReadyModule`; a rejected
/// one pins it failed (`RouteModuleState` in `state.zig`). Returns the
/// parked request ids for the caller to queue again; the caller owns and
/// frees the list.
pub fn settleEvaluation(
    ctx: *module_context.Context,
    specifier: []const u8,
    resolved: bool,
) Settlement {
    const module_state = ctx.modules.route_modules.getPtr(specifier) orelse return .{};
    if (module_state.* != .evaluating)
        return .{};
    const waiters = module_state.evaluating.waiters;
    module_state.evaluating.waiters = .{};

    if (!resolved) {
        // The waiters were moved out above; the empty evaluating record owns
        // nothing else, so the tag flips in place.
        module_state.* = .failed;
        std.log.warn("route module evaluation rejected specifier={s}", .{specifier});
        return .{ .waiters = waiters, .transition = .failed };
    }

    const removed = ctx.modules.route_modules.fetchRemove(specifier).?;
    ctx.allocator.free(removed.key);
    const outcome = finishReadyModule(ctx, specifier) catch |err| blk: {
        std.log.warn("route module settlement finish failed specifier={s}: {s}", .{
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
            std.log.warn("route module default export raised at settlement specifier={s}", .{specifier});
        },
    };
    return .{ .waiters = waiters, .transition = .ready };
}

/// Whether the route's module has stayed pending past
/// `module_eval_budget_ns`, in which case the caller recycles the worker.
/// `deadlineTimeout` in `worker/serve/dispatch.zig` checks it and says why
/// a request's deadline is the wake that reaches it.
pub fn evaluationZombie(ctx: *module_context.Context, specifier: []const u8) bool {
    const module_state = ctx.modules.route_modules.getPtr(specifier) orelse return false;
    if (module_state.* != .evaluating)
        return false;
    return ctx.nowMonoNs() >= module_state.evaluating.deadline_mono_ns;
}

fn readyRoute(ctx: *module_context.Context, specifier: []const u8) ?*const modules_state.RouteModule {
    const module_state = ctx.modules.route_modules.getPtr(specifier) orelse return null;
    if (module_state.* != .ready)
        return null;
    return &module_state.ready;
}

/// The result of `bootEvaluateRouteEntry`, which registers the pack
/// WorkerInit delivered and evaluates the route's entry before the ready
/// handshake, so a cold-started worker serves its first request without
/// module work.
///
/// A failure to map, parse, check or register the pack propagates and fails
/// the init: no dispatch carries a pack, so a worker without its route's
/// pack could serve none of the route's requests. A synchronous throw pins
/// the route failed, as a rejected top-level await does, and the worker
/// still reports ready but never serves that handler. A default export that
/// is not callable is logged and left uncached, so each request evaluates
/// the entry again and fails on its own.
pub const BootEvaluateOutcome = enum {
    /// Nothing is left in flight: the entry is ready or failed, its default
    /// export is not callable, or the route-module table already held it.
    settled,
    /// A top-level await is in flight with an `.evaluating` record parked;
    /// the caller arms `module_eval_budget_ns` on the boot context.
    pending,
};

/// Monotonic stamps of the steps of a pack registration
/// (`registerRoutePack`), which the boot evaluation's caller records as boot
/// phases of their own. A zero stamp means the step did not run, because the
/// pack was already registered, or the clock could not be read.
pub const BootEvalMarks = struct {
    pack_mapped_ns: u64 = 0,
    pack_parsed_ns: u64 = 0,
    pack_registered_ns: u64 = 0,
};

/// Registers the route pack in `route_entry_fd`, a sealed memfd that stays
/// the caller's, with the VM as permanent, and records its specifiers in
/// `loaded_sources`. When a registered pack already holds `specifier`, the
/// call does nothing. The pack must hold `specifier`, and its modules must
/// share the entry's deploy scope. A non-null `marks` receives the step
/// stamps. Fails with the error of the step that failed: mapping, parsing or
/// checking the pack, or registering it.
pub fn registerRoutePack(
    ctx: *module_context.Context,
    route_entry_fd: std.posix.fd_t,
    specifier: []const u8,
    marks: ?*BootEvalMarks,
) !void {
    if (sourceLoaded(ctx, specifier))
        return;
    var pack = try module_pack_io.mapFdReadOnly(route_entry_fd, module_pack.max_pack_bytes);
    defer pack.deinit();
    if (marks) |m| m.pack_mapped_ns = process.monotonicNowNsOrZero();

    const parsed_pack = try module_pack.parse(pack.bytes());
    try module_pack.validateSameDeployScopedPack(parsed_pack, specifier);
    if (!module_pack.containsSpecifier(parsed_pack, specifier))
        return error.ModulePackEntryMismatch;
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

/// Registers the pack in `route_entry_fd`, which stays the caller's
/// (`registerRoutePack`), and evaluates `specifier`; `BootEvaluateOutcome`
/// says what each failure does. A non-null `marks` receives the step stamps.
pub fn bootEvaluateRouteEntry(
    ctx: *module_context.Context,
    route_entry_fd: std.posix.fd_t,
    specifier: []const u8,
    marks: ?*BootEvalMarks,
) !BootEvaluateOutcome {
    if (ctx.modules.route_modules.contains(specifier))
        return .settled;
    try registerRoutePack(ctx, route_entry_fd, specifier, marks);

    switch (evaluateRouteModule(ctx, specifier, null) catch |err| switch (err) {
        // An uncallable default export is the tenant's mistake and is left
        // to each request; every other error fails the init.
        error.HandlerNotCallable => {
            std.log.warn("boot route entry handler not callable specifier={s}", .{specifier});
            return .settled;
        },
        else => return err,
    }) {
        .ready => {},
        // The event loop settles the top-level await after ready; a request
        // that arrives first parks as a waiter.
        .pending => return .pending,
        .exception => |exception| {
            var owned = exception;
            owned.deinit();
            // A synchronous throw pins the same failed record a rejected
            // top-level await does (`RouteModuleState` in `state.zig`), so
            // requests fail at once with `error.RouteModuleEvaluationFailed`
            // and the worker answers each with a 500. A failure to pin, out
            // of memory, fails the init: in a ready worker without the pin,
            // the route's failure would rest on what JSC returns when each
            // request imports the module again.
            try markRouteModuleFailed(ctx, specifier);
            std.log.warn("boot route entry evaluation raised; route pinned failed specifier={s}", .{specifier});
        },
    }
    return .settled;
}

/// Pins a route failed after a synchronous throw, when no `.evaluating`
/// record exists for `settleEvaluation` to flip. Both callers,
/// `bootEvaluateRouteEntry` and `ensureRouteHandler`, return early when the
/// specifier already has a record, so this always inserts a new one.
fn markRouteModuleFailed(ctx: *module_context.Context, specifier: []const u8) !void {
    const owned_specifier = try ctx.allocator.dupe(u8, specifier);
    errdefer ctx.allocator.free(owned_specifier);
    try ctx.modules.route_modules.putNoClobber(ctx.allocator, owned_specifier, .failed);
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

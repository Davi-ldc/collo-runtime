//! Covers a worker that serves every route of its definition's route table
//! (`worker/modules/routes.zig`): dispatch by route index, each route in its
//! own realm or every route in one (`WorkerInit.flag_isolate_realm`), each
//! route's own `env`, the boot that evaluates every route before ready and
//! keeps one boot context open until the last top-level await settles,
//! settlements keyed by realm and specifier, and an index past the table. A
//! failure ends only its own route: a synchronous throw, a rejected await
//! and an await past its budget each pin their route failed while the
//! others serve, and the worker recycles, once its requests drain, only
//! when no route can serve and one failed on an await. The runtime here runs
//! in process with the table WorkerInit would carry; `local-e2e` serves the
//! same through the server in both realm modes, and `arbiter.zig` covers a
//! boot turn that never yields.

const std = @import("std");
const support = @import("bindings_support");
const ipc = @import("collo_ipc");
const worker = @import("collo_worker");
const rt = @import("collo_test_harness");

const route_table = ipc.route_table;
const Module = ipc.module_pack.Module;
const Failure = worker.testing.module_routes.RouteModuleState.Failure;

/// One runtime started with a route table, as a worker's boot starts it.
const Fixture = struct {
    vm: support.bindings.Vm,
    control_pair: [2]std.posix.fd_t,
    now_mono_ns: u64,
    completion: rt.CompletionFixture,
    runtime: worker.Runtime,
    table: []u8,

    /// Initializes in place: the runtime keeps pointers to the clock, the
    /// completion view and the table.
    fn init(self: *Fixture, routes: []const route_table.RouteInput, isolate_realm: bool) !void {
        const sealed = try route_table.buildSealed(std.testing.allocator, routes);
        defer sealed.close();
        self.table = try std.testing.allocator.alloc(u8, @intCast(sealed.blob_len));
        errdefer std.testing.allocator.free(self.table);
        if (try std.posix.pread(sealed.fd, self.table, 0) != self.table.len)
            return error.ShortTableRead;
        self.vm = try support.createVm();
        errdefer self.vm.deinit();
        self.control_pair = try rt.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
        errdefer for (self.control_pair) |fd| std.posix.close(fd);
        self.now_mono_ns = 0;
        self.completion = try rt.CompletionFixture.init();
        errdefer self.completion.deinit();
        self.runtime = try worker.Runtime.init(std.testing.allocator, &self.vm, self.control_pair[0], &self.completion.view, try rt.createCompletionEventfd(), .{
            .ctx = &self.now_mono_ns,
            .now_fn = rt.fakeNow,
            .route_table = self.table,
            .isolate_realm = isolate_realm,
        });
        errdefer self.runtime.deinit();
        try self.runtime.attachHostRuntime();
    }

    fn deinit(self: *Fixture) void {
        self.runtime.deinit();
        self.completion.deinit();
        for (self.control_pair) |fd| std.posix.close(fd);
        self.vm.deinit();
        std.testing.allocator.free(self.table);
        self.* = undefined;
    }

    /// Boots the routes as a worker does: installs the boot context and
    /// evaluates every route's entry from one pack of `modules`, whose first
    /// module is route 0's entry.
    fn boot(self: *Fixture, modules: []const Module) !void {
        const pack_fd = try rt.createModulePackGraphFd(modules, 0);
        defer std.posix.close(pack_fd);
        try self.runtime.installBootContext(&ipc.egress_token.none);
        try self.runtime.evaluateBootRoutes(pack_fd, 0, null);
    }

    /// Queues one request for the route at `route_index` without running it.
    fn enqueue(self: *Fixture, request_id: u64, route_index: u16) !void {
        var dispatch = try rt.initDispatchWork(std.testing.allocator, .{
            .request_id = request_id,
            .route_index = route_index,
            .deadline_monotonic_ns = 60 * std.time.ns_per_s,
        });
        defer dispatch.deinit();
        try rt.enqueueIngressRoute(&self.runtime, &dispatch, 1, .{});
    }

    /// Runs one request for the route at `route_index` to its end; the
    /// caller owns the response.
    fn send(self: *Fixture, request_id: u64, route_index: u16) !rt.IngressResponse {
        try self.enqueue(request_id, route_index);
        try rt.executeNextReady(&self.runtime);
        try rt.executeUntilRequestDone(&self.runtime, request_id);
        return rt.readIngressResponse(&self.runtime, self.control_pair[1], request_id);
    }

    /// `send`, expecting a 200, returning the body, which the caller frees.
    fn body(self: *Fixture, request_id: u64, route_index: u16) ![]u8 {
        var response = try self.send(request_id, route_index);
        defer response.deinit();
        try std.testing.expectEqual(@as(u16, 200), response.status);
        return response.takeBody();
    }

    fn expectBody(self: *Fixture, request_id: u64, route_index: u16, expected: []const u8) !void {
        const actual = try self.body(request_id, route_index);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(expected, actual);
    }

    fn module(self: *Fixture, route_index: usize) worker.testing.module_routes.RouteModuleState {
        return self.runtime.modules.state.routes.items[route_index].module;
    }

    fn realmIndex(self: *Fixture, route_index: usize) u32 {
        return self.runtime.modules.state.routes.items[route_index].realm.?.index();
    }
};

const counter_entry = "/__collo_route/routes/counter.js";
const other_entry = "/__collo_route/routes/other.js";

/// Counts its module instance's requests in a module variable and its
/// realm's in a global, and reports both with the route's binding and
/// whether the request is the realm's own `Request`.
const counter_source =
    \\let hits = 0;
    \\export default function handle(request, env) {
    \\    hits += 1;
    \\    globalThis.__requests = (globalThis.__requests ?? 0) + 1;
    \\    return JSON.stringify({
    \\        route: env.ROUTE,
    \\        hits,
    \\        requests: globalThis.__requests,
    \\        request: request instanceof Request,
    \\    });
    \\}
;

const three_routes = [_]route_table.RouteInput{
    .{ .entry_specifier = counter_entry, .bindings = &.{.{ .name = "ROUTE", .value = "a" }} },
    .{ .entry_specifier = counter_entry, .bindings = &.{.{ .name = "ROUTE", .value = "b" }} },
    .{ .entry_specifier = other_entry, .bindings = &.{} },
};

const three_modules = [_]Module{
    .{ .specifier = counter_entry, .source = counter_source, .dependencies = &.{} },
    .{ .specifier = other_entry, .source = "export default () => new Response(\"other\");", .dependencies = &.{} },
};

test "isolated realms give each route its own globals and module instance, and every route its own env" {
    var fixture: Fixture = undefined;
    try fixture.init(&three_routes, true);
    defer fixture.deinit();
    try fixture.boot(&three_modules);

    // Route 0 runs in the VM's main realm and every other route in one of
    // its own, all evaluated at boot.
    for (0..3) |index|
        try std.testing.expect(fixture.module(index) == .ready);
    try std.testing.expectEqual(@as(u32, 0), fixture.realmIndex(0));
    try std.testing.expect(fixture.realmIndex(1) != 0);
    try std.testing.expect(fixture.realmIndex(2) != 0);
    try std.testing.expect(fixture.realmIndex(1) != fixture.realmIndex(2));

    // Routes 0 and 1 share an entry, yet each counts alone: a module
    // instance and a global object per realm.
    try fixture.expectBody(1, 0, "{\"route\":\"a\",\"hits\":1,\"requests\":1,\"request\":true}");
    try fixture.expectBody(2, 1, "{\"route\":\"b\",\"hits\":1,\"requests\":1,\"request\":true}");
    try fixture.expectBody(3, 0, "{\"route\":\"a\",\"hits\":2,\"requests\":2,\"request\":true}");
    try fixture.expectBody(4, 2, "other");
}

test "a shared realm gives routes with one entry one module instance and every route its own env" {
    var fixture: Fixture = undefined;
    try fixture.init(&three_routes, false);
    defer fixture.deinit();
    try fixture.boot(&three_modules);

    for (0..3) |index| {
        try std.testing.expect(fixture.module(index) == .ready);
        try std.testing.expectEqual(@as(u32, 0), fixture.realmIndex(index));
    }

    // One instance and one global object behind both routes; the bindings
    // still differ, since each route builds its own `env`.
    try fixture.expectBody(1, 0, "{\"route\":\"a\",\"hits\":1,\"requests\":1,\"request\":true}");
    try fixture.expectBody(2, 1, "{\"route\":\"b\",\"hits\":2,\"requests\":2,\"request\":true}");
    try fixture.expectBody(3, 0, "{\"route\":\"a\",\"hits\":3,\"requests\":3,\"request\":true}");
    try fixture.expectBody(4, 2, "other");
}

test "the boot evaluates every route, serves the settled ones, and keeps its context open until the last await settles" {
    const sync_entry = "/__collo_route/routes/sync.js";
    const late_entry = "/__collo_route/routes/late.js";
    var fixture: Fixture = undefined;
    try fixture.init(&.{
        .{ .entry_specifier = sync_entry, .bindings = &.{} },
        .{ .entry_specifier = late_entry, .bindings = &.{} },
    }, true);
    defer fixture.deinit();
    try fixture.boot(&.{
        .{ .specifier = sync_entry, .source = "export default () => new Response(\"sync\");", .dependencies = &.{} },
        .{
            .specifier = late_entry,
            .source =
            \\await new Promise((resolve) => setTimeout(resolve, 5));
            \\export default () => new Response("late");
            ,
            .dependencies = &.{},
        },
    });

    // Route 1's top-level timer is due at 5 ms on the fake clock, so its
    // evaluation is in flight and the boot context, the owner of its
    // top-level code, stays open with the evaluation budget armed.
    try std.testing.expect(fixture.module(0) == .ready);
    try std.testing.expect(fixture.module(1) == .evaluating);
    const boot_ctx = fixture.runtime.bootContext() orelse return error.MissingBootContext;
    try std.testing.expect(boot_ctx.deadline_armed);

    // The settled route serves meanwhile.
    try fixture.expectBody(1, 0, "sync");
    try std.testing.expect(fixture.module(1) == .evaluating);
    try std.testing.expect(fixture.runtime.bootContext() != null);

    // A request for the route in flight parks on its evaluation, and runs
    // once the timer fires and the await settles; the boot context closes
    // with that last settlement.
    try fixture.enqueue(2, 1);
    try rt.executeNextReady(&fixture.runtime);
    try std.testing.expect(fixture.runtime.requests.active.contains(2));
    fixture.now_mono_ns = 10 * std.time.ns_per_ms;
    try rt.executeUntilRequestDone(&fixture.runtime, 2);
    const late = try rt.readIngressResponseBody(&fixture.runtime, fixture.control_pair[1], 2);
    defer std.testing.allocator.free(late);
    try std.testing.expectEqualStrings("late", late);
    try std.testing.expect(fixture.module(1) == .ready);
    try std.testing.expect(fixture.runtime.boot_ctx == .closed);
    try std.testing.expect(fixture.runtime.bootContext() == null);
}

test "an await past its budget pins only its own route failed, and the other routes keep serving" {
    const sync_entry = "/__collo_route/routes/sync.js";
    const hung_entry = "/__collo_route/routes/hung.js";
    var fixture: Fixture = undefined;
    try fixture.init(&.{
        .{ .entry_specifier = sync_entry, .bindings = &.{} },
        .{ .entry_specifier = hung_entry, .bindings = &.{} },
    }, true);
    defer fixture.deinit();
    try fixture.boot(&.{
        .{ .specifier = sync_entry, .source = "export default () => new Response(\"sync\");", .dependencies = &.{} },
        .{
            .specifier = hung_entry,
            .source = "await new Promise(() => {});\nexport default () => new Response(\"never\");\n",
            .dependencies = &.{},
        },
    });
    try std.testing.expect(fixture.module(0) == .ready);
    try std.testing.expect(fixture.module(1) == .evaluating);
    const boot_ctx = fixture.runtime.bootContext() orelse return error.MissingBootContext;
    try std.testing.expect(boot_ctx.deadline_armed);

    // A request for the hung route parks on it; its own deadline lies past
    // the budget, so the boot context's deadline is the wake that finds the
    // await hung.
    try fixture.enqueue(1, 1);
    try rt.executeNextReady(&fixture.runtime);
    try std.testing.expect(fixture.runtime.requests.active.contains(1));
    fixture.now_mono_ns = worker.testing.module_routes.module_eval_budget_ns + std.time.ns_per_ms;
    try fixture.runtime.collectDueRequestDeadlines();
    try rt.executeNextReady(&fixture.runtime);

    // The route is pinned failed and the boot context closed, but the worker
    // stays up: route 0 can still serve.
    try std.testing.expect(fixture.module(1) == .failed);
    try std.testing.expectEqual(Failure.exceeded_budget, fixture.module(1).failed);
    try std.testing.expect(fixture.runtime.boot_ctx == .closed);
    try std.testing.expect(!fixture.runtime.modules.state.recycle_after_drain);

    // The parked request gets the 500 a synchronous throw would give, and
    // route 0 serves.
    try rt.executeUntilRequestDone(&fixture.runtime, 1);
    var failed = try rt.readIngressResponse(&fixture.runtime, fixture.control_pair[1], 1);
    defer failed.deinit();
    try std.testing.expectEqual(@as(u16, 500), failed.status);
    try fixture.expectBody(2, 0, "sync");
    fixture.runtime.maybeRecycleAfterFailedEvaluation();
    try std.testing.expect(fixture.runtime.core.running);

    // A settlement that arrives after the expiry finds no route evaluating
    // and leaves the route failed.
    fixture.runtime.handleModuleEvaluationSettled(fixture.realmIndex(1), hung_entry, true);
    try std.testing.expect(fixture.module(1) == .failed);
    try fixture.expectBody(3, 0, "sync");
}

test "the worker recycles once every route failed and one of them on an await, after its requests drain" {
    const throws_entry = "/__collo_route/routes/throws.js";
    const rejects_entry = "/__collo_route/routes/rejects.js";
    const hung_entry = "/__collo_route/routes/hung.js";
    var fixture: Fixture = undefined;
    try fixture.init(&.{
        .{ .entry_specifier = throws_entry, .bindings = &.{} },
        .{ .entry_specifier = rejects_entry, .bindings = &.{} },
        .{ .entry_specifier = hung_entry, .bindings = &.{} },
    }, true);
    defer fixture.deinit();
    const pending_source = "await new Promise(() => {});\nexport default () => new Response(\"never\");\n";
    try fixture.boot(&.{
        .{
            .specifier = throws_entry,
            .source = "throw new Error(\"boom\");\nexport default function handle() { return \"never\"; }\n",
            .dependencies = &.{},
        },
        .{ .specifier = rejects_entry, .source = pending_source, .dependencies = &.{} },
        .{ .specifier = hung_entry, .source = pending_source, .dependencies = &.{} },
    });
    try std.testing.expectEqual(Failure.threw, fixture.module(0).failed);
    try std.testing.expect(fixture.module(1) == .evaluating);
    try std.testing.expect(fixture.module(2) == .evaluating);

    // A rejection leaves one route still evaluating, so the worker serves on.
    fixture.runtime.handleModuleEvaluationSettled(fixture.realmIndex(1), rejects_entry, false);
    try std.testing.expectEqual(Failure.rejected, fixture.module(1).failed);
    try std.testing.expect(!fixture.runtime.modules.state.recycle_after_drain);

    // The last route expires with a request parked on it: now no route can
    // serve, and a fresh worker might get past the awaits.
    try fixture.enqueue(1, 2);
    try rt.executeNextReady(&fixture.runtime);
    fixture.now_mono_ns = worker.testing.module_routes.module_eval_budget_ns + std.time.ns_per_ms;
    try fixture.runtime.collectDueRequestDeadlines();
    try rt.executeNextReady(&fixture.runtime);
    try std.testing.expectEqual(Failure.exceeded_budget, fixture.module(2).failed);
    try std.testing.expect(fixture.runtime.modules.state.recycle_after_drain);

    // The parked request is queued again and drains with the worker's own
    // 500 before the worker stops.
    fixture.runtime.maybeRecycleAfterFailedEvaluation();
    try std.testing.expect(fixture.runtime.core.running);
    try rt.executeUntilRequestDone(&fixture.runtime, 1);
    var failed = try rt.readIngressResponse(&fixture.runtime, fixture.control_pair[1], 1);
    defer failed.deinit();
    try std.testing.expectEqual(@as(u16, 500), failed.status);
    fixture.runtime.maybeRecycleAfterFailedEvaluation();
    try std.testing.expect(!fixture.runtime.core.running);
}

test "a worker whose every route threw synchronously keeps answering 500s instead of recycling" {
    const throws_entry = "/__collo_route/routes/throws.js";
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{ .entry_specifier = throws_entry, .bindings = &.{} }}, true);
    defer fixture.deinit();
    try fixture.boot(&.{.{
        .specifier = throws_entry,
        .source = "throw new Error(\"boom\");\nexport default function handle() { return \"never\"; }\n",
        .dependencies = &.{},
    }});

    // A fresh worker would evaluate the same module and throw again.
    try std.testing.expectEqual(Failure.threw, fixture.module(0).failed);
    try std.testing.expect(!fixture.runtime.modules.state.recycle_after_drain);
    var failed = try fixture.send(1, 0);
    defer failed.deinit();
    try std.testing.expectEqual(@as(u16, 500), failed.status);
    fixture.runtime.maybeRecycleAfterFailedEvaluation();
    try std.testing.expect(fixture.runtime.core.running);
}

test "routes sharing an entry settle together in one realm and apart in realms of their own, where a rejection fails only its own route" {
    const tla_entry = "/__collo_route/routes/tla.js";
    const tla_source =
        \\await new Promise((resolve) => setTimeout(resolve, 0));
        \\export default (request, env) => new Response(env.ROUTE);
    ;
    const routes = [_]route_table.RouteInput{
        .{ .entry_specifier = tla_entry, .bindings = &.{.{ .name = "ROUTE", .value = "a" }} },
        .{ .entry_specifier = tla_entry, .bindings = &.{.{ .name = "ROUTE", .value = "b" }} },
    };
    const modules = [_]Module{.{ .specifier = tla_entry, .source = tla_source, .dependencies = &.{} }};

    {
        // One realm, one instance: both routes wait on the same await. Each
        // evaluation registered a reaction of its own, so two settlements
        // arrive, and the first alone must make both routes ready.
        var fixture: Fixture = undefined;
        try fixture.init(&routes, false);
        defer fixture.deinit();
        try fixture.boot(&modules);
        try std.testing.expect(fixture.module(0) == .evaluating);
        try std.testing.expect(fixture.module(1) == .evaluating);
        // The top-level timer's turn settles the evaluation, which parks the
        // settlements until the loop collects them.
        fixture.now_mono_ns = 10 * std.time.ns_per_ms;
        try fixture.runtime.collectDueTimers();
        while (!fixture.runtime.scheduler.ready_queue.isEmpty())
            try rt.executeNextReady(&fixture.runtime);
        const parked = &fixture.runtime.modules.state.pending_settlements;
        try std.testing.expectEqual(@as(usize, 2), parked.items.len);
        const dropped = parked.pop() orelse return error.MissingSettlement;
        std.testing.allocator.free(dropped.specifier);
        fixture.runtime.collectModuleSettlements();
        try std.testing.expect(fixture.module(0) == .ready);
        try std.testing.expect(fixture.module(1) == .ready);
        try std.testing.expect(fixture.runtime.boot_ctx == .closed);
        try fixture.expectBody(1, 1, "b");
        try fixture.expectBody(2, 0, "a");
    }
    {
        // A realm each: a settlement under route 1's realm touches route 1
        // alone, and the real settlement that comes after it for that realm
        // finds nothing left to settle.
        var fixture: Fixture = undefined;
        try fixture.init(&routes, true);
        defer fixture.deinit();
        try fixture.boot(&modules);
        try std.testing.expect(fixture.module(0) == .evaluating);
        try std.testing.expect(fixture.module(1) == .evaluating);
        fixture.runtime.handleModuleEvaluationSettled(fixture.realmIndex(1), tla_entry, false);
        try std.testing.expect(fixture.module(1) == .failed);
        try std.testing.expect(fixture.module(0) == .evaluating);
        try std.testing.expect(fixture.runtime.bootContext() != null);
        // Route 0 can still serve, so the rejection asks for no recycle.
        try std.testing.expect(!fixture.runtime.modules.state.recycle_after_drain);

        try fixture.expectBody(1, 0, "a");
        try std.testing.expect(fixture.module(1) == .failed);
        try std.testing.expect(fixture.runtime.boot_ctx == .closed);
        var refused = try fixture.send(2, 1);
        defer refused.deinit();
        try std.testing.expectEqual(@as(u16, 500), refused.status);

        // With nothing left to drain, the worker still serves route 0.
        fixture.runtime.collectModuleSettlements();
        fixture.runtime.maybeRecycleAfterFailedEvaluation();
        try std.testing.expect(fixture.runtime.core.running);
        try fixture.expectBody(3, 0, "a");
    }
}

test "a synchronous throw at boot pins its own route failed and the other routes serve" {
    const ok_entry = "/__collo_route/routes/ok.js";
    const throws_entry = "/__collo_route/routes/throws.js";
    var fixture: Fixture = undefined;
    try fixture.init(&.{
        .{ .entry_specifier = ok_entry, .bindings = &.{} },
        .{ .entry_specifier = throws_entry, .bindings = &.{} },
    }, true);
    defer fixture.deinit();
    try fixture.boot(&.{
        .{ .specifier = ok_entry, .source = "export default () => new Response(\"ok\");", .dependencies = &.{} },
        .{
            .specifier = throws_entry,
            .source = "throw new Error(\"boom\");\nexport default function handle() { return \"never\"; }\n",
            .dependencies = &.{},
        },
    });

    try std.testing.expect(fixture.module(0) == .ready);
    try std.testing.expect(fixture.module(1) == .failed);
    try std.testing.expect(fixture.runtime.boot_ctx == .closed);
    var failed = try fixture.send(1, 1);
    defer failed.deinit();
    try std.testing.expectEqual(@as(u16, 500), failed.status);
    try fixture.expectBody(2, 0, "ok");
    try std.testing.expect(fixture.runtime.core.running);
}

test "a dispatch naming a route past the table answers 500 and the worker keeps serving" {
    var fixture: Fixture = undefined;
    try fixture.init(&three_routes, true);
    defer fixture.deinit();
    try fixture.boot(&three_modules);

    var refused = try fixture.send(1, three_routes.len);
    defer refused.deinit();
    try std.testing.expectEqual(@as(u16, 500), refused.status);
    try std.testing.expectEqual(ipc.RequestDoneStatus.internal_error, refused.doneStatus());
    try std.testing.expect(fixture.runtime.core.running);
    try fixture.expectBody(2, 2, "other");
}

test "a boot refuses a pack that lacks a route's entry" {
    var fixture: Fixture = undefined;
    try fixture.init(&three_routes, true);
    defer fixture.deinit();
    const pack_fd = try rt.createModulePackGraphFd(three_modules[0..1], 0);
    defer std.posix.close(pack_fd);
    try std.testing.expectError(error.ModulePackEntryMismatch, fixture.runtime.evaluateBootRoutes(pack_fd, 0, null));
    try std.testing.expect(!fixture.runtime.modules.state.loaded_sources.contains(counter_entry));
}

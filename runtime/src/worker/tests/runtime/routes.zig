//! Covers a worker that serves every route of its definition's artifact
//! (`worker/modules/routes.zig`): dispatch by route index, each route in its
//! own realm or every route in one (`WorkerInit.flag_isolate_realm`), each
//! route's own `env`, the boot that evaluates every route before ready and
//! keeps each pending module instance's evaluation open until its top-level
//! await settles, one evaluation for routes that share an instance,
//! settlements keyed by realm and specifier, and an index past the routes.
//! The handler is a callable default export, called with `this` undefined
//! even when it has a `fetch` of its own, or else the callable `fetch` of an
//! object default export, a prototype method or a class field included,
//! called with the object as `this` and with no third argument, and read
//! once, at boot or when the route's await settles. A failure ends only its
//! own route: a synchronous throw, a default export that offers no handler,
//! a read of the default export or of its `fetch` that raises, a rejected
//! await, an await past its budget and an error of the worker's own at
//! settlement each pin their route failed while the others serve, and the
//! worker asks the server to
//! retire it, still answering what reaches it, only when no route can serve
//! and one failed on an await or on the worker's own error. The runtime here
//! runs in process with the artifact WorkerInit would carry; `local-e2e`
//! serves the same through the server in both realm modes, and `arbiter.zig`
//! covers a boot turn that never yields.

const std = @import("std");
const support = @import("bindings_support");
const ipc = @import("collo_ipc");
const worker = @import("collo_worker");
const rt = @import("collo_test_harness");

const RouteInput = ipc.route_table.RouteInput;
const Module = ipc.module_pack.Module;
const Failure = worker.testing.module_routes.RouteModuleState.Failure;
const request_context = @import("collo_worker_request").context;
const retirement_notice = @import("retirement_notice.zig");

/// One runtime booted from an artifact, as a worker's boot boots it.
const Fixture = struct {
    vm: support.bindings.Vm,
    control_pair: [2]std.posix.fd_t,
    now_mono_ns: u64,
    completion: rt.CompletionFixture,
    runtime: worker.Runtime,

    /// Initializes in place: the runtime keeps pointers to the clock and the
    /// completion view.
    fn init(self: *Fixture, isolate_realm: bool) !void {
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
            .isolate_realm = isolate_realm,
        });
        errdefer self.runtime.deinit();
        try self.runtime.attachHostRuntime();
    }

    /// The runtime goes before the VM, whose pack its routes borrow from.
    fn deinit(self: *Fixture) void {
        self.runtime.deinit();
        self.completion.deinit();
        for (self.control_pair) |fd| std.posix.close(fd);
        self.vm.deinit();
        self.* = undefined;
    }

    /// Boots the routes as a worker does: registers the artifact of
    /// `modules` and `routes` and evaluates every route's entry.
    fn boot(self: *Fixture, modules: []const Module, routes: []const RouteInput) !void {
        const pack_fd = try rt.createDefinitionFd(modules, routes);
        defer std.posix.close(pack_fd);
        try self.runtime.evaluateBootRoutes(pack_fd, 0, null);
        self.runtime.sealStartupEvaluations();
    }

    /// The open evaluation that started at the route at `route_index`, or
    /// null once it closed.
    fn evaluation(self: *Fixture, route_index: usize) ?*request_context.RequestContext {
        return self.runtime.requests.active.get(request_context.evaluationId(route_index));
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

    fn expectStatus(self: *Fixture, request_id: u64, route_index: u16, expected: u16) !void {
        var response = try self.send(request_id, route_index);
        defer response.deinit();
        try std.testing.expectEqual(expected, response.status);
    }

    fn module(self: *Fixture, route_index: usize) worker.testing.module_routes.RouteModuleState {
        return self.runtime.modules.state.routes.items[route_index].module;
    }

    fn realmIndex(self: *Fixture, route_index: usize) u32 {
        return self.runtime.modules.state.routes.items[route_index].realm.?.index();
    }
};

const counter_entry = "/var/task/routes/counter.js";
const other_entry = "/var/task/routes/other.js";

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

const three_modules = [_]Module{
    .{ .specifier = counter_entry, .source = counter_source },
    .{ .specifier = other_entry, .source = "export default () => new Response(\"other\");" },
};

const three_routes = [_]RouteInput{
    .{ .entry_module = 0, .bindings = &.{.{ .name = "ROUTE", .value = "a" }} },
    .{ .entry_module = 0, .bindings = &.{.{ .name = "ROUTE", .value = "b" }} },
    .{ .entry_module = 1 },
};

/// The two-route definitions below: route 0's entry is module 0 and route
/// 1's is module 1.
const two_routes = [_]RouteInput{ .{ .entry_module = 0 }, .{ .entry_module = 1 } };

const throws_source = "throw new Error(\"boom\");\nexport default function handle() { return \"never\"; }\n";
const pending_source = "await new Promise(() => {});\nexport default () => new Response(\"never\");\n";

test "isolated realms give each route its own globals and module instance, and every route its own env" {
    var fixture: Fixture = undefined;
    try fixture.init(true);
    defer fixture.deinit();
    try fixture.boot(&three_modules, &three_routes);

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
    try fixture.init(false);
    defer fixture.deinit();
    try fixture.boot(&three_modules, &three_routes);

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

test "the boot evaluates every route, serves the settled ones, and keeps a pending route's evaluation open until its await settles" {
    var fixture: Fixture = undefined;
    try fixture.init(true);
    defer fixture.deinit();
    try fixture.boot(&.{
        .{ .specifier = "/var/task/routes/sync.js", .source = "export default () => new Response(\"sync\");" },
        .{
            .specifier = "/var/task/routes/late.js",
            .source =
            \\await new Promise((resolve) => setTimeout(resolve, 5));
            \\export default () => new Response("late");
            ,
        },
    }, &two_routes);

    // Route 0 settled in its synchronous part, which closed its evaluation.
    // Route 1's top-level timer is due at 5 ms on the fake clock, so its
    // evaluation, the owner of its top-level code, stays open with the
    // route's budget armed.
    try std.testing.expect(fixture.module(0) == .ready);
    try std.testing.expect(fixture.module(1) == .evaluating);
    try std.testing.expect(fixture.evaluation(0) == null);
    const evaluation = fixture.evaluation(1) orelse return error.MissingEvaluation;
    try std.testing.expect(evaluation.deadline_armed);

    // The settled route serves meanwhile.
    try fixture.expectBody(1, 0, "sync");
    try std.testing.expect(fixture.module(1) == .evaluating);
    try std.testing.expect(fixture.evaluation(1) != null);

    // A request for the route in flight parks on its evaluation, and runs
    // once the timer fires and the await settles; the evaluation closes with
    // that settlement.
    try fixture.enqueue(2, 1);
    try rt.executeNextReady(&fixture.runtime);
    try std.testing.expect(fixture.runtime.requests.active.contains(2));
    fixture.now_mono_ns = 10 * std.time.ns_per_ms;
    try rt.executeUntilRequestDone(&fixture.runtime, 2);
    const late = try rt.readIngressResponseBody(&fixture.runtime, fixture.control_pair[1], 2);
    defer std.testing.allocator.free(late);
    try std.testing.expectEqualStrings("late", late);
    try std.testing.expect(fixture.module(1) == .ready);
    try std.testing.expect(fixture.evaluation(1) == null);
}

test "an await past its budget pins only its own route failed, and the other routes keep serving" {
    const hung_entry = "/var/task/routes/hung.js";
    var fixture: Fixture = undefined;
    try fixture.init(true);
    defer fixture.deinit();
    try fixture.boot(&.{
        .{ .specifier = "/var/task/routes/sync.js", .source = "export default () => new Response(\"sync\");" },
        .{ .specifier = hung_entry, .source = pending_source },
    }, &two_routes);
    try std.testing.expect(fixture.module(0) == .ready);
    try std.testing.expect(fixture.module(1) == .evaluating);
    const evaluation = fixture.evaluation(1) orelse return error.MissingEvaluation;
    try std.testing.expect(evaluation.deadline_armed);

    // A request for the hung route parks on it; its own deadline lies past
    // the budget, so the evaluation's deadline is the wake that finds the
    // await hung.
    try fixture.enqueue(1, 1);
    try rt.executeNextReady(&fixture.runtime);
    try std.testing.expect(fixture.runtime.requests.active.contains(1));
    fixture.now_mono_ns = worker.testing.module_routes.module_eval_budget_ns + std.time.ns_per_ms;
    try fixture.runtime.collectDueRequestDeadlines();
    try rt.executeNextReady(&fixture.runtime);

    // The route is pinned failed and its evaluation closed, but the worker
    // stays up: route 0 can still serve.
    try std.testing.expect(fixture.module(1) == .failed);
    try std.testing.expectEqual(Failure.exceeded_budget, fixture.module(1).failed);
    try std.testing.expect(fixture.evaluation(1) == null);
    try std.testing.expect(!fixture.runtime.modules.state.fresh_worker_may_serve);

    // The parked request gets the 500 a synchronous throw would give, and
    // route 0 serves.
    try rt.executeUntilRequestDone(&fixture.runtime, 1);
    var failed = try rt.readIngressResponse(&fixture.runtime, fixture.control_pair[1], 1);
    defer failed.deinit();
    try std.testing.expectEqual(@as(u16, 500), failed.status);
    try fixture.expectBody(2, 0, "sync");
    try fixture.runtime.checkRetirement();
    try std.testing.expect(fixture.runtime.retirement.reason == null);

    // A settlement that arrives after the expiry finds no route evaluating
    // and leaves the route failed.
    fixture.runtime.handleModuleEvaluationSettled(fixture.realmIndex(1), hung_entry, true);
    try std.testing.expect(fixture.module(1) == .failed);
    try fixture.expectBody(3, 0, "sync");
}

test "the worker asks to retire once every route failed and one of them on an await, and still answers its parked request" {
    const rejects_entry = "/var/task/routes/rejects.js";
    var fixture: Fixture = undefined;
    try fixture.init(true);
    defer fixture.deinit();
    try fixture.boot(&.{
        .{ .specifier = "/var/task/routes/throws.js", .source = throws_source },
        .{ .specifier = rejects_entry, .source = pending_source },
        .{ .specifier = "/var/task/routes/hung.js", .source = pending_source },
    }, &.{ .{ .entry_module = 0 }, .{ .entry_module = 1 }, .{ .entry_module = 2 } });
    try std.testing.expectEqual(Failure.threw, fixture.module(0).failed);
    try std.testing.expect(fixture.module(1) == .evaluating);
    try std.testing.expect(fixture.module(2) == .evaluating);

    // A rejection leaves one route still evaluating, so the worker serves on.
    fixture.runtime.handleModuleEvaluationSettled(fixture.realmIndex(1), rejects_entry, false);
    try std.testing.expectEqual(Failure.rejected, fixture.module(1).failed);
    try std.testing.expect(!fixture.runtime.modules.state.fresh_worker_may_serve);

    // The last route expires with a request parked on it: now no route can
    // serve, and a fresh worker might get past the awaits.
    try fixture.enqueue(1, 2);
    try rt.executeNextReady(&fixture.runtime);
    fixture.now_mono_ns = worker.testing.module_routes.module_eval_budget_ns + std.time.ns_per_ms;
    try fixture.runtime.collectDueRequestDeadlines();
    try rt.executeNextReady(&fixture.runtime);
    try std.testing.expectEqual(Failure.exceeded_budget, fixture.module(2).failed);
    try std.testing.expect(fixture.runtime.modules.state.fresh_worker_may_serve);

    // The parked request, whose begin came before any notice, is queued
    // again and answers with the worker's own 500.
    try rt.executeUntilRequestDone(&fixture.runtime, 1);
    var failed = try rt.readIngressResponse(&fixture.runtime, fixture.control_pair[1], 1);
    defer failed.deinit();
    try std.testing.expectEqual(@as(u16, 500), failed.status);

    // The worker asks the server to retire it and stays in its loop.
    try fixture.runtime.checkRetirement();
    try std.testing.expectEqual(
        ipc.WorkerRetiringReason.routes_failed,
        try retirement_notice.read(fixture.control_pair[1]),
    );
    try std.testing.expect(fixture.runtime.core.running);
}

test "a worker whose every route threw synchronously keeps answering 500s instead of asking to retire" {
    var fixture: Fixture = undefined;
    try fixture.init(true);
    defer fixture.deinit();
    try fixture.boot(&.{.{ .specifier = "/var/task/routes/throws.js", .source = throws_source }}, &.{.{ .entry_module = 0 }});

    // A fresh worker would evaluate the same module and throw again.
    try std.testing.expectEqual(Failure.threw, fixture.module(0).failed);
    try std.testing.expect(!fixture.runtime.modules.state.fresh_worker_may_serve);
    try fixture.expectStatus(1, 0, 500);
    try fixture.runtime.checkRetirement();
    try std.testing.expect(fixture.runtime.retirement.reason == null);
}

test "routes sharing an entry settle together in one realm and apart in realms of their own, where a rejection fails only its own route" {
    const tla_entry = "/var/task/routes/tla.js";
    const tla_source =
        \\await new Promise((resolve) => setTimeout(resolve, 0));
        \\export default (request, env) => new Response(env.ROUTE);
    ;
    const routes = [_]RouteInput{
        .{ .entry_module = 0, .bindings = &.{.{ .name = "ROUTE", .value = "a" }} },
        .{ .entry_module = 0, .bindings = &.{.{ .name = "ROUTE", .value = "b" }} },
    };
    const modules = [_]Module{.{ .specifier = tla_entry, .source = tla_source }};

    {
        // One realm, one instance: both routes wait on the same await, under
        // the one evaluation route 0 started. Each route's evaluation call
        // registered a reaction of its own, so two settlements arrive, and
        // the first alone must make both routes ready.
        var fixture: Fixture = undefined;
        try fixture.init(false);
        defer fixture.deinit();
        try fixture.boot(&modules, &routes);
        try std.testing.expect(fixture.module(0) == .evaluating);
        try std.testing.expect(fixture.module(1) == .evaluating);
        try std.testing.expect(fixture.evaluation(0) != null);
        try std.testing.expect(fixture.evaluation(1) == null);
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
        try std.testing.expect(fixture.evaluation(0) == null);
        try fixture.expectBody(1, 1, "b");
        try fixture.expectBody(2, 0, "a");
    }
    {
        // A realm each, so an instance and an evaluation each: a settlement
        // under route 1's realm touches route 1 alone and closes its
        // evaluation, and the real settlement that comes after it for that
        // realm finds nothing left to settle.
        var fixture: Fixture = undefined;
        try fixture.init(true);
        defer fixture.deinit();
        try fixture.boot(&modules, &routes);
        try std.testing.expect(fixture.module(0) == .evaluating);
        try std.testing.expect(fixture.module(1) == .evaluating);
        try std.testing.expect(fixture.evaluation(1) != null);
        fixture.runtime.handleModuleEvaluationSettled(fixture.realmIndex(1), tla_entry, false);
        try std.testing.expect(fixture.module(1) == .failed);
        try std.testing.expect(fixture.module(0) == .evaluating);
        try std.testing.expect(fixture.evaluation(1) == null);
        try std.testing.expect(fixture.evaluation(0) != null);
        // Route 0 can still serve, so the rejection retires nothing.
        try std.testing.expect(!fixture.runtime.modules.state.fresh_worker_may_serve);

        try fixture.expectBody(1, 0, "a");
        try std.testing.expect(fixture.module(1) == .failed);
        try std.testing.expect(fixture.evaluation(0) == null);
        try fixture.expectStatus(2, 1, 500);

        // With nothing left to drain, the worker still serves route 0.
        fixture.runtime.collectModuleSettlements();
        try fixture.runtime.checkRetirement();
        try std.testing.expect(fixture.runtime.retirement.reason == null);
        try fixture.expectBody(3, 0, "a");
    }
}

test "a synchronous throw at boot pins its own route failed and the other routes serve" {
    var fixture: Fixture = undefined;
    try fixture.init(true);
    defer fixture.deinit();
    try fixture.boot(&.{
        .{ .specifier = "/var/task/routes/ok.js", .source = "export default () => new Response(\"ok\");" },
        .{ .specifier = "/var/task/routes/throws.js", .source = throws_source },
    }, &two_routes);

    try std.testing.expect(fixture.module(0) == .ready);
    try std.testing.expect(fixture.module(1) == .failed);
    try std.testing.expect(fixture.evaluation(0) == null);
    try std.testing.expect(fixture.evaluation(1) == null);
    try fixture.expectStatus(1, 1, 500);
    try fixture.expectBody(2, 0, "ok");
    try std.testing.expect(fixture.runtime.core.running);
}

test "an uncallable default export pins its route failed at boot while the worker boots and its other routes serve" {
    var fixture: Fixture = undefined;
    try fixture.init(true);
    defer fixture.deinit();
    try fixture.boot(&.{
        .{ .specifier = "/var/task/routes/ok.js", .source = "export default () => new Response(\"ok\");" },
        .{ .specifier = "/var/task/routes/number.js", .source = "export default 42;" },
    }, &two_routes);

    try std.testing.expect(fixture.module(0) == .ready);
    try std.testing.expectEqual(Failure.threw, fixture.module(1).failed);
    try std.testing.expect(fixture.evaluation(1) == null);
    // An unusable export depends on the module alone, so no fresh worker
    // would do better.
    try std.testing.expect(!fixture.runtime.modules.state.fresh_worker_may_serve);
    try fixture.expectStatus(1, 1, 500);
    try std.testing.expectEqual(Failure.threw, fixture.module(1).failed);
    try fixture.expectBody(2, 0, "ok");
    try std.testing.expect(fixture.runtime.core.running);
}

test "an object default export serves through its fetch, which receives the request and env and nothing else" {
    var fixture: Fixture = undefined;
    try fixture.init(true);
    defer fixture.deinit();
    try fixture.boot(&.{.{
        .specifier = "/var/task/routes/object.js",
        .source =
        \\export default {
        \\    fetch(request, env) {
        \\        return new Response(`${request instanceof Request}|${env.ROUTE}|${arguments.length}`);
        \\    },
        \\};
        ,
    }}, &.{.{ .entry_module = 0, .bindings = &.{.{ .name = "ROUTE", .value = "a" }} }});

    try std.testing.expect(fixture.module(0) == .ready);
    try std.testing.expect(fixture.evaluation(0) == null);
    // Cloudflare Workers passes an execution context as a third argument;
    // the worker has none to pass.
    try fixture.expectBody(1, 0, "true|a|2");
    try fixture.expectBody(2, 0, "true|a|2");
}

test "fetch runs with the default export as this" {
    var fixture: Fixture = undefined;
    try fixture.init(true);
    defer fixture.deinit();
    try fixture.boot(&.{.{
        .specifier = "/var/task/routes/receiver.js",
        .source =
        \\const app = {
        \\    name: "app",
        \\    fetch() {
        \\        return new Response(`${this === app}|${this.name}`);
        \\    },
        \\};
        \\export default app;
        ,
    }}, &.{.{ .entry_module = 0 }});

    try fixture.expectBody(1, 0, "true|app");
}

test "a class instance serves through a prototype fetch or a fetch field, each with the instance as this" {
    var fixture: Fixture = undefined;
    try fixture.init(true);
    defer fixture.deinit();
    try fixture.boot(&.{
        .{
            .specifier = "/var/task/routes/prototype.js",
            .source =
            \\class App {
            \\    constructor() {
            \\        this.greeting = "prototype";
            \\    }
            \\    fetch() {
            \\        return new Response(`${this instanceof App}|${this.greeting}`);
            \\    }
            \\}
            \\export default new App();
            ,
        },
        .{
            // Hono's `app.fetch` is this shape: an arrow function in a class
            // field, which reaches private state through its lexical `this`.
            .specifier = "/var/task/routes/field.js",
            .source =
            \\class App {
            \\    #name = "field";
            \\    fetch = (request, env) => new Response(this.#name);
            \\}
            \\export default new App();
            ,
        },
    }, &two_routes);

    try std.testing.expect(fixture.module(0) == .ready);
    try std.testing.expect(fixture.module(1) == .ready);
    try fixture.expectBody(1, 0, "true|prototype");
    try fixture.expectBody(2, 1, "field");
}

test "an object default export without a callable fetch pins its route failed at boot and the worker's other routes serve" {
    var fixture: Fixture = undefined;
    try fixture.init(true);
    defer fixture.deinit();
    try fixture.boot(&.{
        .{ .specifier = "/var/task/routes/object.js", .source = "export default { fetch() { return new Response(\"object\"); } };" },
        .{ .specifier = "/var/task/routes/empty.js", .source = "export default {};" },
        .{ .specifier = "/var/task/routes/string-fetch.js", .source = "export default { fetch: \"not a function\" };" },
        .{
            .specifier = "/var/task/routes/getter-throws.js",
            .source = "export default { get fetch() { throw new Error(\"no fetch\"); } };",
        },
    }, &.{ .{ .entry_module = 0 }, .{ .entry_module = 1 }, .{ .entry_module = 2 }, .{ .entry_module = 3 } });

    try std.testing.expect(fixture.module(0) == .ready);
    for (1..4) |index| {
        try std.testing.expectEqual(Failure.threw, fixture.module(index).failed);
        try std.testing.expect(fixture.evaluation(index) == null);
    }
    // Each failure depends on the module alone, so no fresh worker would do
    // better.
    try std.testing.expect(!fixture.runtime.modules.state.fresh_worker_may_serve);
    try fixture.expectStatus(1, 1, 500);
    try fixture.expectStatus(2, 2, 500);
    try fixture.expectStatus(3, 3, 500);
    try fixture.expectBody(4, 0, "object");
    try std.testing.expect(fixture.runtime.core.running);
}

test "the handler is read once, so assigning another fetch to the default export later changes nothing" {
    var fixture: Fixture = undefined;
    try fixture.init(true);
    defer fixture.deinit();
    try fixture.boot(&.{.{
        .specifier = "/var/task/routes/reassigns.js",
        .source =
        \\const app = {
        \\    fetch() {
        \\        app.fetch = () => new Response("replaced");
        \\        return new Response("original");
        \\    },
        \\};
        \\export default app;
        ,
    }}, &.{.{ .entry_module = 0 }});

    try fixture.expectBody(1, 0, "original");
    try fixture.expectBody(2, 0, "original");
}

test "a function default export is the handler even with a fetch of its own, called with this undefined, beside an object default export" {
    var fixture: Fixture = undefined;
    // One realm, so both shapes serve side by side in the same globals.
    try fixture.init(false);
    defer fixture.deinit();
    try fixture.boot(&.{
        .{
            .specifier = "/var/task/routes/function.js",
            .source =
            \\export default function handle() {
            \\    return new Response(`function|${this === undefined}`);
            \\}
            \\handle.fetch = () => new Response("fetch property");
            ,
        },
        .{ .specifier = "/var/task/routes/object.js", .source = "export default { fetch() { return new Response(\"object\"); } };" },
    }, &two_routes);

    try std.testing.expect(fixture.module(0) == .ready);
    try std.testing.expect(fixture.module(1) == .ready);
    try fixture.expectBody(1, 0, "function|true");
    try fixture.expectBody(2, 1, "object");
}

test "an object default export whose fetch a top-level await provides serves once the await settles" {
    var fixture: Fixture = undefined;
    try fixture.init(true);
    defer fixture.deinit();
    try fixture.boot(&.{.{
        .specifier = "/var/task/routes/late-object.js",
        .source =
        \\const app = { name: "late" };
        \\await new Promise((resolve) => setTimeout(resolve, 5));
        \\app.fetch = function () {
        \\    return new Response(this.name);
        \\};
        \\export default app;
        ,
    }}, &.{.{ .entry_module = 0 }});
    try std.testing.expect(fixture.module(0) == .evaluating);

    // A request parks on the evaluation; the timer settles the await, and
    // the read at settlement finds the object and the `fetch` the await
    // left on it.
    try fixture.enqueue(1, 0);
    try rt.executeNextReady(&fixture.runtime);
    try std.testing.expect(fixture.runtime.requests.active.contains(1));
    fixture.now_mono_ns = 10 * std.time.ns_per_ms;
    try rt.executeUntilRequestDone(&fixture.runtime, 1);
    const late = try rt.readIngressResponseBody(&fixture.runtime, fixture.control_pair[1], 1);
    defer std.testing.allocator.free(late);
    try std.testing.expectEqualStrings("late", late);
    try std.testing.expect(fixture.module(0) == .ready);
    try std.testing.expect(fixture.evaluation(0) == null);
    try fixture.expectBody(2, 0, "late");
}

test "a handler that cannot be read when its await settles pins its route failed, and its waiters get their 500" {
    var fixture: Fixture = undefined;
    try fixture.init(true);
    defer fixture.deinit();
    try fixture.boot(&.{
        .{ .specifier = "/var/task/routes/ok.js", .source = "export default () => new Response(\"ok\");" },
        .{
            .specifier = "/var/task/routes/late-number.js",
            .source =
            \\await new Promise((resolve) => setTimeout(resolve, 5));
            \\export default 42;
            ,
        },
    }, &two_routes);
    try std.testing.expect(fixture.module(1) == .evaluating);

    // A request parks on the evaluation; the timer settles the await, and
    // the export read at settlement finds no function.
    try fixture.enqueue(1, 1);
    try rt.executeNextReady(&fixture.runtime);
    try std.testing.expect(fixture.runtime.requests.active.contains(1));
    fixture.now_mono_ns = 10 * std.time.ns_per_ms;
    try rt.executeUntilRequestDone(&fixture.runtime, 1);
    var failed = try rt.readIngressResponse(&fixture.runtime, fixture.control_pair[1], 1);
    defer failed.deinit();
    try std.testing.expectEqual(@as(u16, 500), failed.status);
    try std.testing.expectEqual(Failure.threw, fixture.module(1).failed);
    try std.testing.expect(fixture.evaluation(1) == null);

    // Later requests fail at once, and route 0 serves.
    try fixture.expectStatus(2, 1, 500);
    try fixture.expectBody(3, 0, "ok");
}

test "an error of the worker's own when an await settles pins the route so that a fresh worker may serve" {
    var fixture: Fixture = undefined;
    try fixture.init(true);
    defer fixture.deinit();
    try fixture.boot(&.{.{
        .specifier = "/var/task/routes/late.js",
        .source =
        \\await new Promise((resolve) => setTimeout(resolve, 5));
        \\export default () => new Response("late");
        ,
    }}, &.{.{ .entry_module = 0 }});
    try std.testing.expect(fixture.module(0) == .evaluating);

    // A bindings section that claims one binding and holds none makes the
    // `env` fail at settlement with an error of the worker, not of the
    // module, as an allocation failure would. The boot's parse keeps such a
    // section out of a real artifact, so the test swaps it in afterwards.
    fixture.runtime.modules.state.routes.items[0].bindings = "\x01\x00\x00\x00";
    try fixture.enqueue(1, 0);
    try rt.executeNextReady(&fixture.runtime);
    fixture.now_mono_ns = 10 * std.time.ns_per_ms;
    try rt.executeUntilRequestDone(&fixture.runtime, 1);
    var failed = try rt.readIngressResponse(&fixture.runtime, fixture.control_pair[1], 1);
    defer failed.deinit();
    try std.testing.expectEqual(@as(u16, 500), failed.status);

    // The module did nothing wrong, so its only route failing lets a fresh
    // worker try, where a throw would keep this one answering 500s.
    try std.testing.expectEqual(Failure.internal_error, fixture.module(0).failed);
    try std.testing.expect(fixture.runtime.modules.state.fresh_worker_may_serve);
    try fixture.runtime.checkRetirement();
    try std.testing.expectEqual(
        ipc.WorkerRetiringReason.routes_failed,
        try retirement_notice.read(fixture.control_pair[1]),
    );
}

test "a dispatch naming a route past the artifact's routes answers 500 and the worker keeps serving" {
    var fixture: Fixture = undefined;
    try fixture.init(true);
    defer fixture.deinit();
    try fixture.boot(&three_modules, &three_routes);

    var refused = try fixture.send(1, three_routes.len);
    defer refused.deinit();
    try std.testing.expectEqual(@as(u16, 500), refused.status);
    try std.testing.expectEqual(ipc.RequestDoneStatus.internal_error, refused.doneStatus());
    try std.testing.expect(fixture.runtime.core.running);
    try fixture.expectBody(2, 2, "other");
}

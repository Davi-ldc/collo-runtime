//! Covers a request's life in the worker runtime from dispatch to its
//! `request_done`: the refusal of a begin whose pool slot names no live
//! slot, or that names the pool slot or the id of an unfinished request,
//! the cleanup of a finished request's timers and
//! immediates, the `host` and `expect` headers a handler receives as sent,
//! client resets and late body chunks, a `request_done` that finds the
//! control socket full and waits while its live slot keeps the request's
//! CPU, the stop when a packet finds the outbox holding one for every pool
//! slot, the identity and measures a `request_done`
//! carries, the CPU of the request's owner windows on every way a request
//! can finish and in its live slot as soon as a window is charged, a
//! deadline that expires before or during a handler, and an async handler's
//! settlement. Runs in `worker-test`, on a real VM with an injected clock.

const std = @import("std");
const support = @import("bindings_support");
const ipc = @import("collo_ipc");
const fd_mod = @import("collo_os").fd;
const worker_shared_page = @import("collo_worker_state").page;
const worker = @import("collo_worker");
const rt = @import("collo_test_harness");

const fakeNow = rt.fakeNow;
const initDispatchWork = rt.initDispatchWork;
const socketPairType = rt.socketPairType;
const runRouteAndExpectBody = rt.runRouteAndExpectBody;
const executeNextReady = rt.executeNextReady;
const executeUntilRequestDone = rt.executeUntilRequestDone;

test "scheduler cancels request timers when dispatch work finishes" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = fakeNow,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const route_specifier = try rt.routeSpecifier(std.testing.allocator, "/__test_route/unit.js");
    defer std.testing.allocator.free(route_specifier);
    const route_index = try rt.registerRoute(&runtime, route_specifier,
        \\let events = [];
        \\export default function handle(req) {
        \\    events.push("req:" + req.path);
        \\    setTimeout(() => { events.push("timer"); }, 1);
        \\    return events.join(",");
        \\}
        \\export function snapshot() {
        \\    return events.join(",");
        \\}
    );

    var dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = 1,
        .route_index = route_index,
        .request = .{ .path = "/unit" },
    });
    defer dispatch.deinit();
    try rt.enqueueIngressRoute(&runtime, &dispatch, 1, .{ .path = "/unit" });

    try executeNextReady(&runtime);
    try executeUntilRequestDone(&runtime, 1);
    var response = try rt.readIngressResponse(&runtime, control_pair[1], 1);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expect(std.mem.containsAtLeast(u8, response.body, 1, "req:/unit"));

    now_mono_ns += std.time.ns_per_ms;
    try runtime.collectDueTimers();
    try std.testing.expect(runtime.scheduler.ready_queue.pop() == null);

    var snapshot = try support.getExportOk(&vm, route_specifier, "snapshot");
    defer snapshot.deinit();
    var exec_ctx = support.makeExecCtx(2);
    try vm.turnEnter(&exec_ctx);
    var result = try support.invokeOk(&vm, &exec_ctx, &snapshot, &.{});
    defer result.deinit();
    try support.expectValueString(&vm, &result, "req:/unit");
    try vm.turnExit();
}

test "scheduler cancels request immediates when dispatch work finishes" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = fakeNow,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const route_specifier = try rt.routeSpecifier(std.testing.allocator, "/__test_route/immediate.js");
    defer std.testing.allocator.free(route_specifier);
    const route_index = try rt.registerRoute(&runtime, route_specifier,
        \\let events = [];
        \\export default function handle(req) {
        \\    events.push("req:" + req.path);
        \\    setImmediate(() => { events.push("immediate"); });
        \\    return events.join(",");
        \\}
        \\export function snapshot() {
        \\    return events.join(",");
        \\}
    );

    var dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = 1,
        .route_index = route_index,
        .request = .{ .path = "/unit" },
    });
    defer dispatch.deinit();
    try rt.enqueueIngressRoute(&runtime, &dispatch, 1, .{ .path = "/unit" });

    try executeNextReady(&runtime);
    try executeUntilRequestDone(&runtime, 1);
    var response = try rt.readIngressResponse(&runtime, control_pair[1], 1);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expect(std.mem.containsAtLeast(u8, response.body, 1, "req:/unit"));

    try runtime.collectReadyImmediates();
    try std.testing.expect(runtime.scheduler.ready_queue.pop() == null);

    var snapshot = try support.getExportOk(&vm, route_specifier, "snapshot");
    defer snapshot.deinit();
    var exec_ctx = support.makeExecCtx(2);
    try vm.turnEnter(&exec_ctx);
    var result = try support.invokeOk(&vm, &exec_ctx, &snapshot, &.{});
    defer result.deinit();
    try support.expectValueString(&vm, &result, "req:/unit");
    try vm.turnExit();
}

test "worker serves the routed handler whatever the Host header names" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = fakeNow,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    // The server routes by path alone (`server/routes/table.zig`), so a Host
    // that differs from the dispatch's authority (`demo.test` in the harness)
    // reaches the handler unchanged.
    var response = try rt.runRouteAndReadIngressResponseWithRequest(&runtime, control_pair[1],
        \\export default function handle(request) {
        \\    return request.headers.get("host");
        \\}
    , 4, "/__test_route/host.js", .{
        .path = "/host",
        .headers = &[_]ipc.RequestHeader{.{ .name = "host", .value = "Other.Test:8443" }},
    });
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("Other.Test:8443", response.body);
    try std.testing.expectEqual(ipc.RequestDoneStatus.ok, response.doneStatus());
}

test "an expect header reaches the handler unchanged" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = fakeNow,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    // Neither ingress nor the worker answers an expectation: no 100 Continue
    // and no 417, so the header is the handler's to read.
    var response = try rt.runRouteAndReadIngressResponseWithRequest(&runtime, control_pair[1],
        \\export default function handle(request) {
        \\    return request.headers.get("expect");
        \\}
    , 5, "/__test_route/expect.js", .{
        .path = "/expect",
        .headers = &[_]ipc.RequestHeader{
            .{ .name = "host", .value = "demo.test" },
            .{ .name = "expect", .value = "100-continue" },
        },
    });
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("100-continue", response.body);
    try std.testing.expectEqual(ipc.RequestDoneStatus.ok, response.doneStatus());
}

test "h2 stream reset cancels worker request before handler dispatch" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = fakeNow,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const route_specifier = try rt.routeSpecifier(std.testing.allocator, "/h2-reset.js");
    defer std.testing.allocator.free(route_specifier);
    const route_index = try rt.registerRoute(
        &runtime,
        route_specifier,
        "export default function() { return new Response('should not run'); }",
    );

    var dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = 41,
        .request_generation = 3,
        .request_slot = 7,
        .route_index = route_index,
        .request = .{
            .method = "POST",
            .path = "/cancelled",
            .headers = &[_]ipc.RequestHeader{
                .{ .name = "host", .value = "demo.test" },
                .{ .name = "content-length", .value = "4" },
            },
            .body_framing = .ingress_channel,
            .body_end_stream = false,
        },
    });
    defer dispatch.deinit();
    try rt.enqueueIngressRoute(&runtime, &dispatch, 1, .{
        .method = "POST",
        .path = "/cancelled",
        .headers = &[_]ipc.RequestHeader{
            .{ .name = "host", .value = "demo.test" },
            .{ .name = "content-length", .value = "4" },
        },
        .body_framing = .ingress_channel,
        .body_end_stream = false,
    });
    try std.testing.expect(runtime.requests.active.contains(41));

    const identity = ipc.ingress_channel.RequestIdentity{
        .request_id = 41,
        .request_generation = 3,
        .request_lane_id = 0,
        .request_slot = 7,
    };
    try runtime.enqueueIngressDescriptor(.{
        .allocator = std.testing.allocator,
        .descriptor = ipc.ingress_channel.Descriptor.requestReset(identity, 1, 0x8),
    });

    try executeNextReady(&runtime);
    try std.testing.expect(!runtime.requests.active.contains(41));
    // Cancelled before its handler ran, the request wrote no response: its
    // `request_done` came with no head, and nothing follows it.
    var response = try rt.readIngressResponse(&runtime, control_pair[1], 41);
    defer response.deinit();
    try std.testing.expectEqual(@as(usize, 0), response.headers_wire.len);
    try std.testing.expectEqual(@as(usize, 0), response.body.len);
    try std.testing.expectEqual(ipc.RequestDoneStatus.client_closed, response.doneStatus());
    try std.testing.expectEqual(@as(u16, 499), response.done.http_status);
    var control_poll = [1]std.posix.pollfd{.{ .fd = control_pair[1], .events = std.posix.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(usize, 0), try std.posix.poll(&control_poll, 0));
}

test "late h2 body chunk after request finish is stale no-op" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = fakeNow,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const route_specifier = try rt.routeSpecifier(std.testing.allocator, "/h2-late-body.js");
    defer std.testing.allocator.free(route_specifier);
    const route_index = try rt.registerRoute(
        &runtime,
        route_specifier,
        "export default function() { return new Response('done'); }",
    );

    var dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = 43,
        .request_generation = 9,
        .request_slot = 11,
        .route_index = route_index,
        .request = .{
            .method = "POST",
            .path = "/late-body",
            .headers = &[_]ipc.RequestHeader{
                .{ .name = "host", .value = "demo.test" },
                .{ .name = "content-length", .value = "4" },
            },
            .body_framing = .ingress_channel,
            .body_end_stream = false,
        },
    });
    defer dispatch.deinit();
    try rt.enqueueIngressRoute(&runtime, &dispatch, 3, .{
        .method = "POST",
        .path = "/late-body",
        .headers = &[_]ipc.RequestHeader{
            .{ .name = "host", .value = "demo.test" },
            .{ .name = "content-length", .value = "4" },
        },
        .body_framing = .ingress_channel,
        .body_end_stream = false,
    });

    try executeNextReady(&runtime);
    try executeUntilRequestDone(&runtime, 43);
    var response = try rt.readIngressResponse(&runtime, control_pair[1], 43);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expect(std.mem.containsAtLeast(u8, response.body, 1, "done"));
    try std.testing.expect(!runtime.requests.active.contains(43));

    const identity = ipc.ingress_channel.RequestIdentity{
        .request_id = 43,
        .request_generation = 9,
        .request_lane_id = 0,
        .request_slot = 11,
    };
    const late_payload = try std.testing.allocator.dupe(u8, "late");
    var late_payload_transferred = false;
    errdefer if (!late_payload_transferred)
        std.testing.allocator.free(late_payload);
    var body_descriptor = ipc.ingress_channel.Descriptor.requestBodyChunk(
        identity,
        3,
        0,
        @intCast(late_payload.len),
        true,
    );
    body_descriptor.flag_bits |= ipc.ingress_channel.flags.inline_bytes;
    late_payload_transferred = true;
    try runtime.enqueueIngressDescriptor(.{
        .allocator = std.testing.allocator,
        .descriptor = body_descriptor,
        .payload = late_payload,
    });

    try std.testing.expect(runtime.core.running);
    try std.testing.expect(!runtime.requests.active.contains(43));
    try std.testing.expect(runtime.scheduler.ready_queue.pop() == null);
}

/// Fills the worker's end of `control_pair` until a send would block, as a
/// server that stopped reading leaves it. The worker's end does not block,
/// as the child leaves it.
fn fillControlSocket(worker_fd: std.posix.fd_t) !void {
    try fd_mod.setNonblocking(worker_fd, true);
    const filler = [_]u8{0} ** 4096;
    while (true) {
        _ = std.posix.send(worker_fd, &filler, std.posix.MSG.NOSIGNAL) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return err,
        };
    }
}

/// Reads and drops every packet the server's end of `control_pair` holds.
fn drainServerEnd(server_fd: std.posix.fd_t) !void {
    var scratch: [8192]u8 = undefined;
    while (true) {
        var polls = [_]std.posix.pollfd{.{ .fd = server_fd, .events = std.posix.POLL.IN, .revents = 0 }};
        if (try std.posix.poll(&polls, 0) == 0)
            return;
        _ = try std.posix.recv(server_fd, &scratch, 0);
    }
}

test "a request_done that finds the control socket full waits while the request's live slot keeps its CPU, and goes out once the socket has room" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 0;
    var cpu_ns: u64 = 1_000;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = fakeNow,
        .cpu_clock = worker.Clock{ .ctx = &cpu_ns, .now_fn = fakeNow },
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const route_specifier = try rt.routeSpecifier(std.testing.allocator, "/socket-full-done.js");
    defer std.testing.allocator.free(route_specifier);
    const route_index = try rt.registerRoute(
        &runtime,
        route_specifier,
        "export default function() { return new Response('unsent'); }",
    );

    var dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = 44,
        .request_generation = 10,
        .request_slot = 1,
        .worker_slot = 5,
        .route_index = route_index,
        .request = .{ .path = "/socket-full-done" },
    });
    defer dispatch.deinit();
    try rt.enqueueIngressRoute(&runtime, &dispatch, 5, .{ .path = "/socket-full-done" });
    const request_ctx = runtime.requests.active.get(44) orelse return error.ExpectedActiveRequest;

    // A window of the request ran and was charged, then the server stopped
    // reading.
    worker.testing.owner.chargeContext(&runtime, request_ctx, 700);
    try fillControlSocket(control_pair[0]);
    try std.testing.expectEqual(
        worker.testing.response_finish.FinishOutcome.completed,
        try worker.testing.response_finish.finishRequest(&runtime, request_ctx, .client_closed, 499, .none),
    );

    // The context is gone; the packet waits, and the live slot keeps the
    // request's CPU for a server that would end it from there.
    try std.testing.expect(runtime.core.running);
    try std.testing.expect(!runtime.requests.active.contains(44));
    try std.testing.expect(!runtime.requests.done_outbox.isEmpty());
    const held = worker_shared_page.LiveSlotSnapshot.at(completion_fixture.view.page, 5);
    try std.testing.expect(held.matches(44, 10));
    try std.testing.expectEqual(@as(u64, 700), held.cpu_ns);

    // The server reads again; the writable socket sends the packet.
    try drainServerEnd(control_pair[1]);
    try worker.testing.scheduler.loop.handleControlWritable(&runtime);
    try std.testing.expect(runtime.requests.done_outbox.isEmpty());
    const read = try rt.readRequestDoneOf(control_pair[1], 44);
    try std.testing.expectEqual(@as(u64, 44), read.descriptor.request_id);
    try std.testing.expectEqual(ipc.RequestDoneStatus.client_closed, read.done.status);
    try std.testing.expectEqual(@as(u64, 700), read.done.cpu_ns);
}

test "a request_done that finds the outbox holding one packet for every pool slot stops the worker and keeps the request's live slot" {
    // The stop is logged at err, as a worker's would be.
    @import("root").expect_log_errors = 1;
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = fakeNow,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const route_specifier = try rt.routeSpecifier(std.testing.allocator, "/done-outbox-full.js");
    defer std.testing.allocator.free(route_specifier);
    const route_index = try rt.registerRoute(
        &runtime,
        route_specifier,
        "export default function() { return new Response('tracked'); }",
    );

    // One request on each pool slot finished while the socket was full, so
    // its packet waits: the most a server that keeps its pool slot rule lets
    // the worker owe (`request_done_outbox_capacity`).
    try std.testing.expectEqual(worker_shared_page.LIVE_SLOT_COUNT, worker.testing.runtime_requests.request_done_outbox_capacity);
    for (0..worker_shared_page.LIVE_SLOT_COUNT) |worker_slot| {
        const request_id: u64 = 1_000 + worker_slot;
        completion_fixture.view.beginLiveSlot(worker_slot, request_id, 1);
        try runtime.requests.done_outbox.push(.{
            .identity = .{ .request_id = request_id, .request_generation = 1, .request_lane_id = 0, .request_slot = @intCast(worker_slot) },
            .stream_id = @intCast(2 * worker_slot + 1),
            .done = .{ .status = .ok, .http_status = 200 },
        });
    }

    // A server that breaks the rule sends one more request on a pool slot
    // whose packet it has not read.
    var dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = 45,
        .request_generation = 11,
        .request_slot = 40,
        .worker_slot = 6,
        .route_index = route_index,
        .request = .{ .path = "/done-outbox-full" },
    });
    defer dispatch.deinit();
    try rt.enqueueIngressRoute(&runtime, &dispatch, 81, .{ .path = "/done-outbox-full" });

    const request_ctx = runtime.requests.active.get(45) orelse return error.ExpectedActiveRequest;
    try std.testing.expectError(
        error.RequestDoneOutboxFull,
        worker.testing.response_finish.finishRequest(&runtime, request_ctx, .ok, 200, .none),
    );

    // `finishRequest` stops the runtime itself, because some of its callers
    // only log the error; the server then ends the request from its live
    // slot, which still names it.
    try std.testing.expect(!runtime.core.running);
    const preserved = runtime.requests.active.get(45) orelse return error.ExpectedPreservedRequest;
    try std.testing.expect(preserved.finish_started);
    try std.testing.expect(worker_shared_page.LiveSlotSnapshot.at(completion_fixture.view.page, 6).matches(45, 11));
}

test "a request_done carries the dispatch's identity and the bytes served" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = fakeNow,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const route_specifier = try rt.routeSpecifier(std.testing.allocator, "/__test_route/record-identity.js");
    defer std.testing.allocator.free(route_specifier);
    const route_index = try rt.registerRoute(&runtime, route_specifier,
        \\export default function handle() {
        \\    return "ok";
        \\}
    );

    var dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = 18,
        .request_generation = 4,
        .request_lane_id = 3,
        .request_slot = 2,
        .worker_id = 6,
        .worker_generation = 3,
        .route_index = route_index,
        .request = .{ .path = "/record-identity" },
    });
    defer dispatch.deinit();
    try rt.enqueueIngressRoute(&runtime, &dispatch, 1, .{ .path = "/record-identity" });

    try executeNextReady(&runtime);
    try executeUntilRequestDone(&runtime, 18);
    // Every identity the packet carries is the dispatch's; the server keeps
    // the measures only under a request it dispatched to this worker.
    const read = try rt.readRequestDoneOf(control_pair[1], 18);
    try std.testing.expectEqual(@as(u64, 18), read.descriptor.request_id);
    try std.testing.expectEqual(@as(u64, 4), read.descriptor.request_generation);
    try std.testing.expectEqual(@as(u16, 3), read.descriptor.request_lane_id);
    try std.testing.expectEqual(@as(u32, 2), read.descriptor.request_slot);
    try std.testing.expectEqual(@as(u32, 1), read.descriptor.stream_id);
    try std.testing.expectEqual(ipc.RequestDoneStatus.ok, read.done.status);
    try std.testing.expectEqual(@as(u16, 200), read.done.http_status);
    try std.testing.expectEqual(@as(u64, 0), read.done.io_ns);
    try std.testing.expect(read.done.client_served_bytes > 0);
}

test "a charged window's CPU reaches the request's live slot without a pass of the loop" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    // The VM thread's real CPU clock, so the request's turn is charged what
    // it spent.
    var now_mono_ns: u64 = 100;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = fakeNow,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    // The handler spends some CPU and returns a thenable that never
    // settles, so the request stays live after its first turn.
    const route_specifier = try rt.routeSpecifier(std.testing.allocator, "/live-slot-cpu.js");
    defer std.testing.allocator.free(route_specifier);
    const route_index = try rt.registerRoute(&runtime, route_specifier,
        \\export default function handle() {
        \\    let acc = 0;
        \\    for (let i = 0; i < 100000; i++) acc += Math.sqrt(i);
        \\    return new Promise(() => { void acc; });
        \\}
    );
    var dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = 68,
        .request_generation = 2,
        .worker_slot = 9,
        .route_index = route_index,
        .deadline_monotonic_ns = 10 * std.time.ns_per_s,
        .request = .{ .path = "/live-slot-cpu" },
    });
    defer dispatch.deinit();
    try rt.enqueueIngressRoute(&runtime, &dispatch, 1, .{ .path = "/live-slot-cpu" });
    const page = completion_fixture.view.page;
    try std.testing.expect(worker_shared_page.LiveSlotSnapshot.at(page, 9).matches(68, 2));
    try std.testing.expectEqual(@as(u64, 0), worker_shared_page.LiveSlotSnapshot.at(page, 9).cpu_ns);

    // The request's first turn alone: its window is charged when the turn
    // ends, and no pass of the loop runs after it.
    try executeNextReady(&runtime);
    try std.testing.expect(runtime.requests.active.contains(68));
    const request_ctx = runtime.requests.active.get(68) orelse return error.ExpectedActiveRequest;
    try std.testing.expect(request_ctx.cpu_ns > 0);
    const slot = worker_shared_page.LiveSlotSnapshot.at(page, 9);
    try std.testing.expect(slot.matches(68, 2));
    try std.testing.expectEqual(request_ctx.cpu_ns, slot.cpu_ns);

    // A later begin on the same pool slot, which a server that keeps its
    // pool slot rule sends only after this request's `request_done`, takes
    // the live slot, and the older request's later charges leave it alone.
    completion_fixture.view.beginLiveSlot(9, 69, 1);
    worker.testing.owner.chargeContext(&runtime, request_ctx, 40);
    try std.testing.expectEqual(@as(u64, 0), worker_shared_page.LiveSlotSnapshot.at(page, 9).cpu_ns);
    try std.testing.expect(worker_shared_page.LiveSlotSnapshot.at(page, 9).matches(69, 1));
}

test "a request begin naming a pool slot the page has no live slot for is refused before it opens a request" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = fakeNow,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const route_specifier = try rt.routeSpecifier(std.testing.allocator, "/slot-past-page.js");
    defer std.testing.allocator.free(route_specifier);
    const route_index = try rt.registerRoute(&runtime, route_specifier, "export default () => new Response('never');");

    var dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = 70,
        .request_generation = 3,
        .worker_slot = 0,
        .route_index = route_index,
        .request = .{ .path = "/slot-past-page" },
    });
    defer dispatch.deinit();
    // The encoder refuses such a slot too, so the encoded begin is patched as
    // a broken server would send it.
    var payload_scratch: [ipc.max_message_bytes]u8 = undefined;
    const view = dispatch.view();
    const encoded = try ipc.encodeDispatchWorkInto(&payload_scratch, &view);
    const payload = try std.testing.allocator.dupe(u8, encoded);
    payload[@offsetOf(ipc.DispatchPacketHeader, "worker_slot")] = @intCast(worker_shared_page.LIVE_SLOT_COUNT);
    var descriptor = ipc.ingress_channel.Descriptor.requestBegin(.{
        .request_id = 70,
        .request_generation = 3,
        .request_lane_id = 0,
        .request_slot = 0,
    }, 1, 0, @intCast(payload.len), @intCast(dispatch.request_headers.len), true);
    descriptor.flag_bits |= ipc.ingress_channel.flags.inline_bytes;

    // The runtime takes the payload on every path, the refusal included.
    try std.testing.expectError(error.InvalidWorkerSlot, runtime.enqueueIngressDescriptor(.{
        .allocator = std.testing.allocator,
        .descriptor = descriptor,
        .payload = payload,
    }));
    try std.testing.expectEqual(@as(u32, 0), runtime.requests.active.count());
    // No slot was written: each still names no request.
    for (0..worker_shared_page.LIVE_SLOT_COUNT) |index|
        try std.testing.expectEqual(@as(u64, 0), worker_shared_page.LiveSlotSnapshot.at(completion_fixture.view.page, index).request_id);
}

test "a begin naming the pool slot or the id of an unfinished request is refused, and the holder keeps its live slot" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 0;
    var cpu_ns: u64 = 1_000;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = fakeNow,
        .cpu_clock = worker.Clock{ .ctx = &cpu_ns, .now_fn = fakeNow },
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const route_specifier = try rt.routeSpecifier(std.testing.allocator, "/held-slot.js");
    defer std.testing.allocator.free(route_specifier);
    const route_index = try rt.registerRoute(&runtime, route_specifier, "export default () => new Response('held');");

    // Request 80 holds pool slot 3 and has been charged CPU there.
    var holder = try initDispatchWork(std.testing.allocator, .{
        .request_id = 80,
        .request_generation = 7,
        .request_slot = 1,
        .worker_slot = 3,
        .route_index = route_index,
        .request = .{ .path = "/held-slot" },
    });
    defer holder.deinit();
    try rt.enqueueIngressRoute(&runtime, &holder, 1, .{ .path = "/held-slot" });
    const holder_ctx = runtime.requests.active.get(80) orelse return error.ExpectedActiveRequest;
    worker.testing.owner.chargeContext(&runtime, holder_ctx, 500);

    // A server that broke its pool slot rule sends another request on slot 3,
    // and one that broke its id rule sends request 80 again on slot 4.
    var same_slot = try initDispatchWork(std.testing.allocator, .{
        .request_id = 81,
        .request_generation = 8,
        .request_slot = 2,
        .worker_slot = 3,
        .route_index = route_index,
        .request = .{ .path = "/held-slot" },
    });
    defer same_slot.deinit();
    try std.testing.expectError(error.WorkerSlotInUse, rt.enqueueIngressRoute(&runtime, &same_slot, 3, .{ .path = "/held-slot" }));
    var same_id = try initDispatchWork(std.testing.allocator, .{
        .request_id = 80,
        .request_generation = 9,
        .request_slot = 3,
        .worker_slot = 4,
        .route_index = route_index,
        .request = .{ .path = "/held-slot" },
    });
    defer same_id.deinit();
    try std.testing.expectError(error.RequestIdInUse, rt.enqueueIngressRoute(&runtime, &same_id, 5, .{ .path = "/held-slot" }));

    // Neither refusal opened a request or wrote a live slot: slot 3 still
    // names the holder with its CPU, and slot 4 names nobody.
    try std.testing.expectEqual(@as(u32, 1), runtime.requests.active.count());
    const still_holding = runtime.requests.active.get(80) orelse return error.ExpectedActiveRequest;
    try std.testing.expect(still_holding == holder_ctx);
    const page = completion_fixture.view.page;
    try std.testing.expect(worker_shared_page.LiveSlotSnapshot.at(page, 3).matches(80, 7));
    try std.testing.expectEqual(@as(u64, 500), worker_shared_page.LiveSlotSnapshot.at(page, 3).cpu_ns);
    try std.testing.expectEqual(@as(u64, 0), worker_shared_page.LiveSlotSnapshot.at(page, 4).request_id);

    // Once the holder's finish sent its `request_done`, slot 3 takes a begin.
    try std.testing.expectEqual(
        worker.testing.response_finish.FinishOutcome.completed,
        try worker.testing.response_finish.finishRequest(&runtime, holder_ctx, .ok, 200, .none),
    );
    _ = try rt.readRequestDoneOf(control_pair[1], 80);
    try rt.enqueueIngressRoute(&runtime, &same_slot, 3, .{ .path = "/held-slot" });
    try std.testing.expect(worker_shared_page.LiveSlotSnapshot.at(page, 3).matches(81, 8));
}

// A `request_done`'s CPU (`RequestDone.cpu_ns`) is the CPU of the request's
// owner windows (`worker/runtime/owner.zig`): the deltas of the VM thread's
// CPU clock across each window, never the clock's reading. The native-finish
// tests below inject that clock frozen at a nonzero reading, so a window
// charges exactly zero, and a packet that held the clock's reading, the
// loop thread's whole CPU time, would show it. A request that ran
// JavaScript gets the CPU of its own windows, never the thread's total.

/// A frozen CPU clock reading, far from zero: a packet that took the
/// reading instead of a window's delta would carry it.
const frozen_cpu_reading_ns: u64 = 5 * std.time.ns_per_s;

test "native cancel completion without a vm turn publishes zero turn cpu" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 100;
    var cpu_ns: u64 = frozen_cpu_reading_ns;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = fakeNow,
        .cpu_clock = worker.Clock{ .ctx = &cpu_ns, .now_fn = fakeNow },
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const route_specifier = try rt.routeSpecifier(std.testing.allocator, "/native-cancel-turn-cpu.js");
    defer std.testing.allocator.free(route_specifier);
    const route_index = try rt.registerRoute(
        &runtime,
        route_specifier,
        "export default function() { return new Response('should not run'); }",
    );

    var dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = 61,
        .request_generation = 3,
        .request_slot = 7,
        .route_index = route_index,
        .request = .{ .path = "/native-cancel" },
    });
    defer dispatch.deinit();
    try rt.enqueueIngressRoute(&runtime, &dispatch, 1, .{ .path = "/native-cancel" });
    try std.testing.expect(runtime.requests.active.contains(61));

    const identity = ipc.ingress_channel.RequestIdentity{
        .request_id = 61,
        .request_generation = 3,
        .request_lane_id = 0,
        .request_slot = 7,
    };
    try runtime.enqueueIngressDescriptor(.{
        .allocator = std.testing.allocator,
        .descriptor = ipc.ingress_channel.Descriptor.requestReset(identity, 1, 0x8),
    });

    // The queued dispatch turn sees the reset and finishes the request
    // natively with 499: a turn attributed to the request that never enters
    // the VM.
    try executeNextReady(&runtime);
    try std.testing.expect(!runtime.requests.active.contains(61));
    const done = try rt.readRequestDone(&runtime, control_pair[1], 61);
    try std.testing.expectEqual(ipc.RequestDoneStatus.client_closed, done.status);
    // The frozen clock gave the request's windows no CPU, so the packet
    // carries exactly zero, never the loop thread's whole CPU time.
    try std.testing.expectEqual(@as(u64, 0), done.cpu_ns);
}

test "native deadline completion without a vm turn publishes zero turn cpu" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 10;
    var cpu_ns: u64 = frozen_cpu_reading_ns;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = fakeNow,
        .cpu_clock = worker.Clock{ .ctx = &cpu_ns, .now_fn = fakeNow },
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const route_specifier = try rt.routeSpecifier(std.testing.allocator, "/native-deadline-turn-cpu.js");
    defer std.testing.allocator.free(route_specifier);
    const route_index = try rt.registerRoute(&runtime, route_specifier,
        \\export default function handle() {
        \\    return "should not run";
        \\}
    );

    // The deadline has passed at dispatch, so the turn answers 504 before the
    // route module is evaluated or the VM entered.
    var dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = 62,
        .route_index = route_index,
        .deadline_monotonic_ns = 5,
    });
    defer dispatch.deinit();
    try rt.enqueueIngressRoute(&runtime, &dispatch, 1, .{});

    try executeNextReady(&runtime);
    try executeUntilRequestDone(&runtime, 62);
    var response = try rt.readIngressResponse(&runtime, control_pair[1], 62);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 504), response.status);
    try std.testing.expectEqual(ipc.RequestDoneStatus.deadline_timeout, response.doneStatus());
    try std.testing.expectEqual(@as(u64, 0), response.done.cpu_ns);
}

test "native internal failure without a vm turn publishes zero turn cpu" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 100;
    var cpu_ns: u64 = frozen_cpu_reading_ns;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = fakeNow,
        .cpu_clock = worker.Clock{ .ctx = &cpu_ns, .now_fn = fakeNow },
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    // The dispatch names a route index past the artifact's one route:
    // `lookupRouteHandler` refuses it before anything enters the VM, which
    // drives the 500 internal-error path of `failInternal`.
    const route_specifier = try rt.routeSpecifier(std.testing.allocator, "/native-fail-turn-cpu.js");
    defer std.testing.allocator.free(route_specifier);
    const route_index = try rt.registerRoute(&runtime, route_specifier, "export default function() { return 'unreached'; }");

    var dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = 63,
        .route_index = route_index + 1,
        .request = .{ .path = "/native-fail" },
    });
    defer dispatch.deinit();
    try rt.enqueueIngressRoute(&runtime, &dispatch, 1, .{ .path = "/native-fail" });

    try executeNextReady(&runtime);
    try executeUntilRequestDone(&runtime, 63);
    var response = try rt.readIngressResponse(&runtime, control_pair[1], 63);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 500), response.status);
    try std.testing.expectEqual(ipc.RequestDoneStatus.internal_error, response.doneStatus());
    try std.testing.expectEqual(@as(u64, 0), response.done.cpu_ns);
}

test "vm turn completion publishes the turn cpu delta not accumulated thread cpu" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 100;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = fakeNow,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    try rt.bootRoutes(&runtime, &.{
        .{ .specifier = "/turn-cpu-delta-heavy.js", .source = 
        \\export default function handle() {
        \\    let acc = 0;
        \\    for (let i = 0; i < 2000000; i++) acc += Math.sqrt(i);
        \\    return String(acc);
        \\}
        },
        .{ .specifier = "/turn-cpu-delta-light.js", .source = 
        \\export default function handle() {
        \\    return "light";
        \\}
        },
    });
    const heavy_route: u16 = 0;
    const light_route: u16 = 1;

    // Two million square-root additions take well over 1 ms of CPU even fully
    // compiled, so the floor shows the request's window measured its work
    // rather than a zero or garbage read.
    const busy_floor_ns: u64 = std.time.ns_per_ms;

    var dispatch_a = try initDispatchWork(std.testing.allocator, .{
        .request_id = 64,
        .route_index = heavy_route,
        .request = .{ .path = "/turn-heavy" },
    });
    defer dispatch_a.deinit();
    try rt.enqueueIngressRoute(&runtime, &dispatch_a, 1, .{ .path = "/turn-heavy" });
    try executeNextReady(&runtime);
    try executeUntilRequestDone(&runtime, 64);
    var response_a = try rt.readIngressResponse(&runtime, control_pair[1], 64);
    defer response_a.deinit();
    try std.testing.expectEqual(@as(u16, 200), response_a.status);
    const cpu_a = response_a.done.cpu_ns;

    try std.testing.expect(cpu_a >= busy_floor_ns);

    var dispatch_b = try initDispatchWork(std.testing.allocator, .{
        .request_id = 65,
        .route_index = light_route,
        .request = .{ .path = "/turn-light" },
    });
    defer dispatch_b.deinit();
    try rt.enqueueIngressRoute(&runtime, &dispatch_b, 1, .{ .path = "/turn-light" });
    try executeNextReady(&runtime);
    try executeUntilRequestDone(&runtime, 65);
    var response_b = try rt.readIngressResponse(&runtime, control_pair[1], 65);
    defer response_b.deinit();
    try std.testing.expectEqual(@as(u16, 200), response_b.status);
    const cpu_b = response_b.done.cpu_ns;

    try std.testing.expect(cpu_b > 0);
    // A per-window delta, not the thread clock: by this finish the loop
    // thread's total CPU already exceeds the heavy request's, so a reading of
    // the thread's clock would come out at least request A's value. The
    // light request's windows measure only its own work.
    try std.testing.expect(cpu_b < cpu_a);
}

test "native completion after a vm turn on the same thread does not inherit turn cpu" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 100;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = fakeNow,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const route_specifier = try rt.routeSpecifier(std.testing.allocator, "/turn-cpu-inherit.js");
    defer std.testing.allocator.free(route_specifier);
    const route_index = try rt.registerRoute(&runtime, route_specifier,
        \\export default function handle() {
        \\    let acc = 0;
        \\    for (let i = 0; i < 2000000; i++) acc += Math.sqrt(i);
        \\    return String(acc);
        \\}
    );

    const busy_floor_ns: u64 = std.time.ns_per_ms;

    // Request A runs a real VM turn on the harness thread, adding to the
    // thread clock the CPU a reading of that clock would leak into B.
    var dispatch_a = try initDispatchWork(std.testing.allocator, .{
        .request_id = 66,
        .route_index = route_index,
        .request = .{ .path = "/inherit-heavy" },
    });
    defer dispatch_a.deinit();
    try rt.enqueueIngressRoute(&runtime, &dispatch_a, 1, .{ .path = "/inherit-heavy" });
    try executeNextReady(&runtime);
    try executeUntilRequestDone(&runtime, 66);
    var response_a = try rt.readIngressResponse(&runtime, control_pair[1], 66);
    defer response_a.deinit();
    try std.testing.expectEqual(@as(u16, 200), response_a.status);
    try std.testing.expect(response_a.done.cpu_ns >= busy_floor_ns);

    // Request B, on the same runtime and thread, finishes natively: reset
    // before dispatch, it never enters the VM, and its `request_done` must
    // not inherit any of the thread CPU request A just used.
    var dispatch_b = try initDispatchWork(std.testing.allocator, .{
        .request_id = 67,
        .request_generation = 5,
        .request_slot = 9,
        .route_index = route_index,
        .request = .{ .path = "/inherit-cancel" },
    });
    defer dispatch_b.deinit();
    try rt.enqueueIngressRoute(&runtime, &dispatch_b, 3, .{ .path = "/inherit-cancel" });
    try std.testing.expect(runtime.requests.active.contains(67));

    const identity = ipc.ingress_channel.RequestIdentity{
        .request_id = 67,
        .request_generation = 5,
        .request_lane_id = 0,
        .request_slot = 9,
    };
    try runtime.enqueueIngressDescriptor(.{
        .allocator = std.testing.allocator,
        .descriptor = ipc.ingress_channel.Descriptor.requestReset(identity, 3, 0x8),
    });

    try executeNextReady(&runtime);
    const done = try rt.readRequestDone(&runtime, control_pair[1], 67);
    try std.testing.expectEqual(ipc.RequestDoneStatus.client_closed, done.status);
    // B's packet holds only its own window, the native finish, which takes
    // far less than the floor request A's work cleared; a reading of the
    // thread's clock would hold A's CPU too.
    try std.testing.expect(done.cpu_ns < busy_floor_ns);

    // Drain the stale .request_cancelled no-op the reset left queued.
    try executeNextReady(&runtime);
}

test "expired request deadline wins before synchronous handler dispatch" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 10;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = fakeNow,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const route_specifier = try rt.routeSpecifier(std.testing.allocator, "/__test_route/expired.js");
    defer std.testing.allocator.free(route_specifier);
    const route_index = try rt.registerRoute(&runtime, route_specifier,
        \\export default function handle() {
        \\    return "should not run";
        \\}
    );

    var dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = 19,
        .route_index = route_index,
        .deadline_monotonic_ns = 5,
    });
    defer dispatch.deinit();
    try rt.enqueueIngressRoute(&runtime, &dispatch, 1, .{});

    try executeNextReady(&runtime);
    try executeUntilRequestDone(&runtime, 19);
    var response = try rt.readIngressResponse(&runtime, control_pair[1], 19);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 504), response.status);
    try std.testing.expect(!std.mem.containsAtLeast(u8, response.body, 1, "should not run"));
    try std.testing.expectEqual(ipc.RequestDoneStatus.deadline_timeout, response.doneStatus());
}

test "expired deadline wins over queued async completion" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = fakeNow,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const route_specifier = try rt.routeSpecifier(std.testing.allocator, "/__test_route/async-deadline.js");
    defer std.testing.allocator.free(route_specifier);
    const route_index = try rt.registerRoute(&runtime, route_specifier,
        \\export default async function handle() {
        \\    await Promise.resolve();
        \\    return "late ok";
        \\}
    );

    var dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = 20,
        .route_index = route_index,
        .deadline_monotonic_ns = 5,
    });
    defer dispatch.deinit();
    try rt.enqueueIngressRoute(&runtime, &dispatch, 1, .{});

    try executeNextReady(&runtime);
    const completion_item = runtime.scheduler.ready_queue.pop() orelse return error.MissingRequestCompletion;
    switch (completion_item) {
        .request_completion => {},
        else => return error.MissingRequestCompletion,
    }
    try runtime.scheduler.ready_queue.push(completion_item);

    now_mono_ns = 5;
    try runtime.collectDueRequestDeadlines();
    try executeNextReady(&runtime);
    try executeUntilRequestDone(&runtime, 20);

    var response = try rt.readIngressResponse(&runtime, control_pair[1], 20);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 504), response.status);
    try std.testing.expect(!std.mem.containsAtLeast(u8, response.body, 1, "late ok"));
    try std.testing.expectEqual(ipc.RequestDoneStatus.deadline_timeout, response.doneStatus());
}

test "async handler resolves through Promise and rejection becomes 500" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = fakeNow,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const async_ok =
        \\export default async function handle(req) {
        \\    await Promise.resolve();
        \\    return Response.json({ ok: true, path: req.path });
        \\}
    ;
    const async_fail =
        \\export default async function handle() {
        \\    await Promise.resolve();
        \\    throw new Error("async boom");
        \\}
    ;
    const async_double_settle =
        \\export default function handle() {
        \\    return new Promise((resolve, reject) => {
        \\        resolve(Response.json({ value: "first" }));
        \\        reject(new Error("late reject"));
        \\        resolve(Response.json({ value: "late resolve" }));
        \\    });
        \\}
    ;
    try rt.bootRoutes(&runtime, &.{
        .{ .specifier = "/async-ok.js", .source = async_ok },
        .{ .specifier = "/async-fail.js", .source = async_fail },
        .{ .specifier = "/async-double-settle.js", .source = async_double_settle },
    });

    try runRouteAndExpectBody(&runtime, control_pair[1], async_ok, 10, "/async-ok.js", "\"ok\":true");
    try runRouteAndExpectBody(&runtime, control_pair[1], async_fail, 11, "/async-fail.js", "internal server error");
    try runRouteAndExpectBody(&runtime, control_pair[1], async_double_settle, 13, "/async-double-settle.js", "\"value\":\"first\"");
}

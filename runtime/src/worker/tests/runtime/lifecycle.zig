//! Covers a request's life in the worker runtime from dispatch to its
//! records: the cleanup of a finished request's timers
//! and immediates, the `host` and `expect` headers a handler receives as
//! sent, client resets and late body chunks, the stop when the record or
//! completion ring is full, the identity and measurements a usage record
//! carries, the per-turn and process CPU clocks on every way a request can
//! finish, a deadline that expires before or during a handler, an async
//! handler's settlement, and the phase stamps of a traced request. Runs in
//! `worker-test`, on a real VM with an injected clock.

const std = @import("std");
const support = @import("bindings_support");
const ipc = @import("collo_ipc");
const worker_metrics_state = @import("collo_worker_state").metrics;
const worker_shared_page = @import("collo_worker_state").page;
const worker = @import("collo_worker");
const rt = @import("collo_test_harness");

const fakeNow = rt.fakeNow;
const initDispatchWork = rt.initDispatchWork;
const socketPairType = rt.socketPairType;
const runRouteAndExpectBody = rt.runRouteAndExpectBody;
const executeNextReady = rt.executeNextReady;
const executeUntilRequestDone = rt.executeUntilRequestDone;

/// Drains the usage records the worker published on `view` into `out` as the
/// host does: from `cursor`, the host's own tail of the ring.
fn drainUsageRecords(
    cursor: *worker_shared_page.RecordCursor,
    view: *const worker_shared_page.WorkerWriterView,
    out: []worker_shared_page.CompletedRecord,
) !usize {
    return cursor.drain(view.header, view.completed_records, out) orelse error.TestUnexpectedUsageRingCorruption;
}

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
    try rt.registerRoute(&runtime, route_specifier,
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
        .route_entry_specifier = route_specifier,
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
    try rt.registerRoute(&runtime, route_specifier,
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
        .route_entry_specifier = route_specifier,
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
    try rt.registerRoute(
        &runtime,
        route_specifier,
        "export default function() { return new Response('should not run'); }",
    );

    var dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = 41,
        .request_generation = 3,
        .request_slot = 7,
        .route_entry_specifier = route_specifier,
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
    const done = try rt.readWorkerCompletion(&runtime, control_pair[1], 41);
    try std.testing.expectEqual(@as(u64, 41), done.external_request_id);
    try std.testing.expectEqual(ipc.RequestDoneStatus.client_closed, @as(ipc.RequestDoneStatus, @enumFromInt(done.status)));
    try std.testing.expectEqual(@as(u16, 499), done.http_status);
    // Cancelled before its handler ran, the request wrote no response: the
    // completion reader left the control socket unread, and it holds no head.
    var control_poll = [1]std.posix.pollfd{.{ .fd = control_pair[1], .events = std.posix.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(usize, 0), try std.posix.poll(&control_poll, 0));
    try std.testing.expect(!runtime.requests.active.contains(41));

    try executeNextReady(&runtime);
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
    try rt.registerRoute(
        &runtime,
        route_specifier,
        "export default function() { return new Response('done'); }",
    );

    var dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = 43,
        .request_generation = 9,
        .request_slot = 11,
        .route_entry_specifier = route_specifier,
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

test "a full record ring stops the worker and keeps the request live for death synthesis" {
    var vm = try support.createVm();
    defer vm.deinit();

    const metrics_fd = try worker_shared_page.createMemfd("runtime-completed-ring-full");
    defer std.posix.close(metrics_fd);
    var metrics_view = try worker_shared_page.mapReadWrite(metrics_fd);
    defer metrics_view.deinit();
    metrics_view.initializeCrashDefault(99, 0, 0);

    var metrics = worker_metrics_state.WorkState.init(&metrics_view);
    for (0..worker_shared_page.RECORD_RING_COUNT) |index| {
        try metrics.appendCompletedRecord(.{
            .request_id = @intCast(index + 1),
            .request_generation = 1,
            .worker_id = 1,
            .worker_generation = 1,
            .started_mono_ns = @intCast(index),
            .finished_mono_ns = @intCast(index + 1),
            .cpu_time_ns = 0,
            .io_time_ns = 0,
            .billing_sequence = @intCast(index + 1),
            .request_slot = 0,
            .request_lane_id = 0,
            .status = @intFromEnum(worker_shared_page.CompletedStatus.done),
            .flags = 0,
        });
    }

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 0;
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &metrics_view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = fakeNow,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const route_specifier = try rt.routeSpecifier(std.testing.allocator, "/completed-ring-full.js");
    defer std.testing.allocator.free(route_specifier);
    try rt.registerRoute(
        &runtime,
        route_specifier,
        "export default function() { return new Response('tracked'); }",
    );

    var dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = 44,
        .request_generation = 10,
        .request_slot = 1,
        .route_entry_specifier = route_specifier,
        .request = .{ .path = "/completed-ring-full" },
    });
    defer dispatch.deinit();
    try rt.enqueueIngressRoute(&runtime, &dispatch, 5, .{ .path = "/completed-ring-full" });

    const request_ctx = runtime.requests.active.get(44) orelse return error.ExpectedPreservedRequest;
    try std.testing.expectError(
        error.CompletedRecordRingFull,
        worker.testing.response_finish.finishRequest(&runtime, request_ctx, .ok, 200),
    );

    // `finishRequest` stops the runtime itself, because some of its callers
    // only log the error; otherwise a running worker could keep a request
    // whose usage record was never published.
    try std.testing.expect(!runtime.core.running);
    const preserved = runtime.requests.active.get(44) orelse return error.ExpectedPreservedRequest;
    try std.testing.expect(preserved.finish_started);
    try std.testing.expect(!preserved.live_slot_released);
    try std.testing.expectEqual(@as(u64, 10), preserved.request_generation);

    const slot_index: usize = @intCast(preserved.live_slot_index.index);
    const slot = &metrics_view.live_slots[slot_index];
    try std.testing.expectEqual(
        @intFromEnum(worker_shared_page.LiveSlotState.active),
        @atomicLoad(u32, &slot.state, .acquire),
    );
    try std.testing.expectEqual(@as(u64, 44), @atomicLoad(u64, &slot.request_id, .acquire));
}

test "worker completion ring overflow stops worker before retrying finalization" {
    var vm = try support.createVm();
    defer vm.deinit();

    const metrics_fd = try worker_shared_page.createMemfd("runtime-worker-completion-ring-full");
    defer std.posix.close(metrics_fd);
    var metrics_view = try worker_shared_page.mapReadWrite(metrics_fd);
    defer metrics_view.deinit();
    metrics_view.initializeCrashDefault(99, 0, 0);

    for (0..worker_shared_page.COMPLETION_RING_COUNT) |index| {
        try metrics_view.publishWorkerCompletion(.{
            .external_request_id = @intCast(index + 1),
            .request_lane_id = 0,
            .request_slot = 0,
            .request_generation = 1,
            .worker_id = 1,
            .worker_generation = 1,
            .status = @intFromEnum(ipc.RequestDoneStatus.ok),
            .http_status = 200,
        });
    }

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 0;
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &metrics_view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = fakeNow,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const route_specifier = try rt.routeSpecifier(std.testing.allocator, "/worker-completion-ring-full.js");
    defer std.testing.allocator.free(route_specifier);
    try rt.registerRoute(
        &runtime,
        route_specifier,
        "export default function() { return new Response('tracked'); }",
    );

    var dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = 45,
        .request_generation = 11,
        .request_slot = 1,
        .route_entry_specifier = route_specifier,
        .request = .{ .path = "/worker-completion-ring-full" },
    });
    defer dispatch.deinit();
    try rt.enqueueIngressRoute(&runtime, &dispatch, 5, .{ .path = "/worker-completion-ring-full" });

    const request_ctx = runtime.requests.active.get(45) orelse return error.ExpectedPreservedRequest;
    try std.testing.expectError(
        error.WorkerCompletionRingOverflow,
        worker.testing.response_finish.finishRequest(&runtime, request_ctx, .ok, 200),
    );

    try std.testing.expect(!runtime.core.running);
    const preserved = runtime.requests.active.get(45) orelse return error.ExpectedPreservedRequest;
    try std.testing.expect(preserved.finish_started);
    try std.testing.expect(!preserved.live_slot_released);
}

test "a usage record carries the dispatch's identity and the bytes served" {
    var vm = try support.createVm();
    defer vm.deinit();

    const metrics_fd = try worker_shared_page.createMemfd("runtime-record-identity");
    defer std.posix.close(metrics_fd);
    var metrics_view = try worker_shared_page.mapReadWrite(metrics_fd);
    defer metrics_view.deinit();
    metrics_view.initializeCrashDefault(99, 0, 0);

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 0;
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &metrics_view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = fakeNow,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const route_specifier = try rt.routeSpecifier(std.testing.allocator, "/__test_route/record-identity.js");
    defer std.testing.allocator.free(route_specifier);
    try rt.registerRoute(&runtime, route_specifier,
        \\export default function handle() {
        \\    return "ok";
        \\}
    );

    var dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = 18,
        .request_generation = 4,
        .request_slot = 2,
        .worker_id = 6,
        .worker_generation = 3,
        .route_entry_specifier = route_specifier,
        .request = .{ .path = "/record-identity" },
    });
    defer dispatch.deinit();
    try rt.enqueueIngressRoute(&runtime, &dispatch, 1, .{ .path = "/record-identity" });

    try executeNextReady(&runtime);
    try executeUntilRequestDone(&runtime, 18);
    var response = try rt.readIngressResponse(&runtime, control_pair[1], 18);
    defer response.deinit();
    try std.testing.expectEqual(@as(u64, 18), response.completion.external_request_id);

    var records: [1]worker_shared_page.CompletedRecord = undefined;
    var usage_cursor: worker_shared_page.RecordCursor = .{};
    try std.testing.expectEqual(@as(usize, 1), try drainUsageRecords(&usage_cursor, &metrics_view, &records));
    // Every identity in the record is the dispatch's; the server keeps a
    // record only for a request it dispatched to this worker
    // (`server/supervisor/usage_drain.zig`).
    try std.testing.expectEqual(@as(u64, 18), records[0].request_id);
    try std.testing.expectEqual(@as(u64, 4), records[0].request_generation);
    try std.testing.expectEqual(@as(u32, 2), records[0].request_slot);
    try std.testing.expectEqual(@as(u64, 6), records[0].worker_id);
    try std.testing.expectEqual(@as(u64, 3), records[0].worker_generation);
    try std.testing.expectEqual(@as(u64, 0), records[0].io_time_ns);
    try std.testing.expect(records[0].client_served_bytes > 0);
}

test "a record's cpu is the process cpu since the previous record, beside the per-turn clock" {
    var vm = try support.createVm();
    defer vm.deinit();

    const metrics_fd = try worker_shared_page.createMemfd("runtime-process-cpu-metrics");
    defer std.posix.close(metrics_fd);
    var metrics_view = try worker_shared_page.mapReadWrite(metrics_fd);
    defer metrics_view.deinit();
    metrics_view.initializeCrashDefault(99, 0, 0);

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 0;
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &metrics_view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = fakeNow,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const route_specifier = try rt.routeSpecifier(std.testing.allocator, "/__test_route/process-cpu.js");
    defer std.testing.allocator.free(route_specifier);
    try rt.registerRoute(&runtime, route_specifier,
        \\export default function handle() {
        \\    let acc = 0;
        \\    for (let i = 0; i < 2000000; i++) acc += Math.sqrt(i);
        \\    return String(acc);
        \\}
    );

    // Two million square-root additions take well over 1 ms of CPU even fully
    // compiled, so the floor shows the record measured the work done rather
    // than a zero or garbage read.
    const busy_floor_ns: u64 = std.time.ns_per_ms;
    var usage_cursor: worker_shared_page.RecordCursor = .{};
    var records: [1]worker_shared_page.CompletedRecord = undefined;

    var dispatch_a = try initDispatchWork(std.testing.allocator, .{
        .request_id = 31,
        .route_entry_specifier = route_specifier,
        .request = .{ .path = "/burn-a" },
    });
    defer dispatch_a.deinit();
    try rt.enqueueIngressRoute(&runtime, &dispatch_a, 1, .{ .path = "/burn-a" });
    try executeNextReady(&runtime);
    try executeUntilRequestDone(&runtime, 31);
    var response_a = try rt.readIngressResponse(&runtime, control_pair[1], 31);
    defer response_a.deinit();
    try std.testing.expectEqual(@as(u16, 200), response_a.status);
    try std.testing.expectEqual(@as(usize, 1), try drainUsageRecords(&usage_cursor, &metrics_view, &records));
    const record_a = records[0];

    try std.testing.expect(record_a.cpu_time_ns >= busy_floor_ns);
    try std.testing.expect(record_a.turn_cpu_ns > 0);
    // The first record's process CPU delta also covers what the process spent
    // outside request turns (VM boot, module evaluation, compilation and
    // collection), so it exceeds its own per-turn clock.
    try std.testing.expect(record_a.cpu_time_ns > record_a.turn_cpu_ns);

    var dispatch_b = try initDispatchWork(std.testing.allocator, .{
        .request_id = 32,
        .route_entry_specifier = route_specifier,
        .request = .{ .path = "/burn-b" },
    });
    defer dispatch_b.deinit();
    try rt.enqueueIngressRoute(&runtime, &dispatch_b, 1, .{ .path = "/burn-b" });
    try executeNextReady(&runtime);
    try executeUntilRequestDone(&runtime, 32);
    var response_b = try rt.readIngressResponse(&runtime, control_pair[1], 32);
    defer response_b.deinit();
    try std.testing.expectEqual(@as(u16, 200), response_b.status);
    try std.testing.expectEqual(@as(usize, 1), try drainUsageRecords(&usage_cursor, &metrics_view, &records));
    const record_b = records[0];

    try std.testing.expect(record_b.cpu_time_ns >= busy_floor_ns);
    try std.testing.expect(record_b.turn_cpu_ns > 0);
    // A delta, not a total: the process total would make the second record
    // at least the first, which absorbed the boot. The delta gives request B
    // only the span from A's finish to B's, the same work without the boot,
    // so it comes out smaller.
    try std.testing.expect(record_b.cpu_time_ns < record_a.cpu_time_ns);
}

// A record's turn CPU (`CompletedRecord.turn_cpu_ns`) is the
// `cpu_used_ns_total` the request's engine turns added at their exits, since
// `finishRequest` (`worker/serve/response_finish.zig`) runs between engine
// turns. A request cancelled, timed out or failed natively finishes inside a
// scheduler turn attributed to it without entering the VM, so its turn CPU
// is exactly zero, never the loop thread's CPU time, and a request that ran
// JavaScript gets the CPU of its own turns, never the thread's total.

test "native cancel completion without a vm turn publishes zero turn cpu" {
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

    const route_specifier = try rt.routeSpecifier(std.testing.allocator, "/native-cancel-turn-cpu.js");
    defer std.testing.allocator.free(route_specifier);
    try rt.registerRoute(
        &runtime,
        route_specifier,
        "export default function() { return new Response('should not run'); }",
    );

    var dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = 61,
        .request_generation = 3,
        .request_slot = 7,
        .route_entry_specifier = route_specifier,
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
    const done = try rt.readWorkerCompletion(&runtime, control_pair[1], 61);
    try std.testing.expectEqual(ipc.RequestDoneStatus.client_closed, @as(ipc.RequestDoneStatus, @enumFromInt(done.status)));
    try std.testing.expect(!runtime.requests.active.contains(61));

    var records: [1]worker_shared_page.CompletedRecord = undefined;
    var usage_cursor: worker_shared_page.RecordCursor = .{};
    try std.testing.expectEqual(@as(usize, 1), try drainUsageRecords(&usage_cursor, &completion_fixture.view, &records));
    try std.testing.expectEqual(@as(u64, 61), records[0].request_id);
    try std.testing.expectEqual(@intFromEnum(worker_shared_page.CompletedStatus.client_closed), records[0].status);
    // No VM turn ran for this request, so its per-turn clock is exactly zero,
    // never the loop thread's whole CPU time.
    try std.testing.expectEqual(@as(u64, 0), records[0].turn_cpu_ns);

    // Drain the stale .request_cancelled no-op the reset left queued.
    try executeNextReady(&runtime);
}

test "native deadline completion without a vm turn publishes zero turn cpu" {
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

    const route_specifier = try rt.routeSpecifier(std.testing.allocator, "/native-deadline-turn-cpu.js");
    defer std.testing.allocator.free(route_specifier);
    try rt.registerRoute(&runtime, route_specifier,
        \\export default function handle() {
        \\    return "should not run";
        \\}
    );

    // The deadline has passed at dispatch, so the turn answers 504 before the
    // route module is evaluated or the VM entered.
    var dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = 62,
        .route_entry_specifier = route_specifier,
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

    var records: [1]worker_shared_page.CompletedRecord = undefined;
    var usage_cursor: worker_shared_page.RecordCursor = .{};
    try std.testing.expectEqual(@as(usize, 1), try drainUsageRecords(&usage_cursor, &completion_fixture.view, &records));
    try std.testing.expectEqual(@as(u64, 62), records[0].request_id);
    try std.testing.expectEqual(@intFromEnum(worker_shared_page.CompletedStatus.deadline), records[0].status);
    try std.testing.expectEqual(@as(u64, 0), records[0].turn_cpu_ns);
}

test "native internal failure without a vm turn publishes zero turn cpu" {
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

    // No registered pack holds this route's entry: `ensureRouteHandler`
    // refuses the dispatch before anything enters the VM, which drives the
    // 500 internal-error path of `failInternal`.
    const route_specifier = try rt.routeSpecifier(std.testing.allocator, "/native-fail-turn-cpu.js");
    defer std.testing.allocator.free(route_specifier);

    var dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = 63,
        .route_entry_specifier = route_specifier,
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

    var records: [1]worker_shared_page.CompletedRecord = undefined;
    var usage_cursor: worker_shared_page.RecordCursor = .{};
    try std.testing.expectEqual(@as(usize, 1), try drainUsageRecords(&usage_cursor, &completion_fixture.view, &records));
    try std.testing.expectEqual(@as(u64, 63), records[0].request_id);
    try std.testing.expectEqual(@intFromEnum(worker_shared_page.CompletedStatus.internal_error), records[0].status);
    try std.testing.expectEqual(@as(u64, 0), records[0].turn_cpu_ns);
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

    const heavy_specifier = try rt.routeSpecifier(std.testing.allocator, "/turn-cpu-delta-heavy.js");
    defer std.testing.allocator.free(heavy_specifier);
    try rt.registerRoute(&runtime, heavy_specifier,
        \\export default function handle() {
        \\    let acc = 0;
        \\    for (let i = 0; i < 2000000; i++) acc += Math.sqrt(i);
        \\    return String(acc);
        \\}
    );

    const light_specifier = try rt.routeSpecifier(std.testing.allocator, "/turn-cpu-delta-light.js");
    defer std.testing.allocator.free(light_specifier);
    try rt.registerRoute(&runtime, light_specifier,
        \\export default function handle() {
        \\    return "light";
        \\}
    );

    // The same calibration as the process CPU test above: the floor shows the
    // per-turn clock measured the turn's work.
    const busy_floor_ns: u64 = std.time.ns_per_ms;
    var usage_cursor: worker_shared_page.RecordCursor = .{};
    var records: [1]worker_shared_page.CompletedRecord = undefined;

    var dispatch_a = try initDispatchWork(std.testing.allocator, .{
        .request_id = 64,
        .route_entry_specifier = heavy_specifier,
        .request = .{ .path = "/turn-heavy" },
    });
    defer dispatch_a.deinit();
    try rt.enqueueIngressRoute(&runtime, &dispatch_a, 1, .{ .path = "/turn-heavy" });
    try executeNextReady(&runtime);
    try executeUntilRequestDone(&runtime, 64);
    var response_a = try rt.readIngressResponse(&runtime, control_pair[1], 64);
    defer response_a.deinit();
    try std.testing.expectEqual(@as(u16, 200), response_a.status);
    try std.testing.expectEqual(@as(usize, 1), try drainUsageRecords(&usage_cursor, &completion_fixture.view, &records));
    const record_a = records[0];

    try std.testing.expect(record_a.turn_cpu_ns >= busy_floor_ns);
    // Below the same record's process CPU delta, which also absorbed the
    // boot: the per-turn clock covers part of that span, so a turn CPU read
    // from a zero or stale start could not satisfy this ordering.
    try std.testing.expect(record_a.cpu_time_ns > record_a.turn_cpu_ns);

    var dispatch_b = try initDispatchWork(std.testing.allocator, .{
        .request_id = 65,
        .route_entry_specifier = light_specifier,
        .request = .{ .path = "/turn-light" },
    });
    defer dispatch_b.deinit();
    try rt.enqueueIngressRoute(&runtime, &dispatch_b, 1, .{ .path = "/turn-light" });
    try executeNextReady(&runtime);
    try executeUntilRequestDone(&runtime, 65);
    var response_b = try rt.readIngressResponse(&runtime, control_pair[1], 65);
    defer response_b.deinit();
    try std.testing.expectEqual(@as(u16, 200), response_b.status);
    try std.testing.expectEqual(@as(usize, 1), try drainUsageRecords(&usage_cursor, &completion_fixture.view, &records));
    const record_b = records[0];

    try std.testing.expect(record_b.turn_cpu_ns > 0);
    // A per-turn delta, not the thread clock: by this finish the loop
    // thread's total CPU already exceeds the heavy request's, so a reading of
    // the thread's clock would come out at least record A's value. The light
    // turn measures only its own work.
    try std.testing.expect(record_b.turn_cpu_ns < record_a.turn_cpu_ns);
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
    try rt.registerRoute(&runtime, route_specifier,
        \\export default function handle() {
        \\    let acc = 0;
        \\    for (let i = 0; i < 2000000; i++) acc += Math.sqrt(i);
        \\    return String(acc);
        \\}
    );

    const busy_floor_ns: u64 = std.time.ns_per_ms;
    var usage_cursor: worker_shared_page.RecordCursor = .{};
    var records: [1]worker_shared_page.CompletedRecord = undefined;

    // Request A runs a real VM turn on the harness thread, adding to the
    // thread clock the CPU a reading of that clock would leak into B.
    var dispatch_a = try initDispatchWork(std.testing.allocator, .{
        .request_id = 66,
        .route_entry_specifier = route_specifier,
        .request = .{ .path = "/inherit-heavy" },
    });
    defer dispatch_a.deinit();
    try rt.enqueueIngressRoute(&runtime, &dispatch_a, 1, .{ .path = "/inherit-heavy" });
    try executeNextReady(&runtime);
    try executeUntilRequestDone(&runtime, 66);
    var response_a = try rt.readIngressResponse(&runtime, control_pair[1], 66);
    defer response_a.deinit();
    try std.testing.expectEqual(@as(u16, 200), response_a.status);
    try std.testing.expectEqual(@as(usize, 1), try drainUsageRecords(&usage_cursor, &completion_fixture.view, &records));
    try std.testing.expect(records[0].turn_cpu_ns >= busy_floor_ns);

    // Request B, on the same runtime and thread, finishes natively: reset
    // before dispatch, it never enters the VM, and its record must not
    // inherit any of the thread CPU request A just used.
    var dispatch_b = try initDispatchWork(std.testing.allocator, .{
        .request_id = 67,
        .request_generation = 5,
        .request_slot = 9,
        .route_entry_specifier = route_specifier,
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
    const done = try rt.readWorkerCompletion(&runtime, control_pair[1], 67);
    try std.testing.expectEqual(ipc.RequestDoneStatus.client_closed, @as(ipc.RequestDoneStatus, @enumFromInt(done.status)));

    try std.testing.expectEqual(@as(usize, 1), try drainUsageRecords(&usage_cursor, &completion_fixture.view, &records));
    try std.testing.expectEqual(@as(u64, 67), records[0].request_id);
    try std.testing.expectEqual(@intFromEnum(worker_shared_page.CompletedStatus.client_closed), records[0].status);
    try std.testing.expectEqual(@as(u64, 0), records[0].turn_cpu_ns);

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
    try rt.registerRoute(&runtime, route_specifier,
        \\export default function handle() {
        \\    return "should not run";
        \\}
    );

    var dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = 19,
        .route_entry_specifier = route_specifier,
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
    try rt.registerRoute(&runtime, route_specifier,
        \\export default async function handle() {
        \\    await Promise.resolve();
        \\    return "late ok";
        \\}
    );

    var dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = 20,
        .route_entry_specifier = route_specifier,
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

    try runRouteAndExpectBody(&runtime, control_pair[1],
        \\export default async function handle(req) {
        \\    await Promise.resolve();
        \\    return Response.json({ ok: true, path: req.path });
        \\}
    , 10, "/async-ok.js", "\"ok\":true");

    try runRouteAndExpectBody(&runtime, control_pair[1],
        \\export default async function handle() {
        \\    await Promise.resolve();
        \\    throw new Error("async boom");
        \\}
    , 11, "/async-fail.js", "internal server error");

    try runRouteAndExpectBody(&runtime, control_pair[1],
        \\export default function handle() {
        \\    return new Promise((resolve, reject) => {
        \\        resolve(Response.json({ value: "first" }));
        \\        reject(new Error("late reject"));
        \\        resolve(Response.json({ value: "late resolve" }));
        \\    });
        \\}
    , 13, "/async-double-settle.js", "\"value\":\"first\"");
}

test "a traced request stamps each phase up to its handler's call in order, the handler's lookup included" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    // Nonzero, since a stamp left at 0 marks a phase that did not run.
    var now_mono_ns: u64 = 100;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{
        .clock = .{ .ctx = &now_mono_ns, .now_fn = fakeNow },
        .trace_requests = true,
        .trace_all_requests = true,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const route_specifier = try rt.routeSpecifier(std.testing.allocator, "/__test_route/traced.js");
    defer std.testing.allocator.free(route_specifier);
    try rt.registerRoute(&runtime, route_specifier,
        \\export default async function handle() {
        \\    await Promise.resolve();
        \\    return "traced";
        \\}
    );

    // The first request evaluates the route's entry, which a worker's boot
    // does in production, so the second runs the path every request of a
    // booted worker takes.
    for ([_]u64{ 71, 72 }, [_]u32{ 1, 3 }) |request_id, stream_id| {
        var dispatch = try initDispatchWork(std.testing.allocator, .{
            .request_id = request_id,
            .route_entry_specifier = route_specifier,
            .request = .{ .path = "/traced" },
        });
        defer dispatch.deinit();
        try rt.enqueueIngressRoute(&runtime, &dispatch, stream_id, .{ .path = "/traced" });

        // The handler's thenable keeps the request active past its first
        // turn, so its stamps can be read before the finish prints them.
        try executeNextReady(&runtime);
        const request_ctx = runtime.requests.active.get(request_id) orelse return error.ExpectedActiveRequest;
        const trace = request_ctx.trace;
        try std.testing.expectEqual(request_id == 71, trace.evaluate_module_done_ns != 0);
        const phases = [_]u64{
            trace.dispatch_enqueued_ns,
            trace.execute_request_start_ns,
            trace.get_export_done_ns,
            trace.parse_request_done_ns,
            trace.make_request_done_ns,
            trace.handler_invoke_done_ns,
        };
        for (phases, 0..) |stamp, index| {
            try std.testing.expect(stamp != 0);
            if (index != 0) try std.testing.expect(phases[index - 1] <= stamp);
        }

        try executeUntilRequestDone(&runtime, request_id);
        var response = try rt.readIngressResponse(&runtime, control_pair[1], request_id);
        defer response.deinit();
        try std.testing.expectEqualStrings("traced", response.body);
    }
}

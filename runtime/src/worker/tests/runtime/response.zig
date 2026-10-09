//! Covers how a handler's result becomes the response the host receives.
//! Only a real `Response` sets the status and headers; any other value is
//! coerced to a text body inside the request turn. Extraction reads the
//! internal state rather than properties user code can tamper with and
//! refuses oversized bodies and headers, and clone fan-out and a
//! `Response.json` body stop at their caps. The writers send small bodies
//! inline, large ones through the shared payload ring and segmented ones
//! without flattening, with exact bytes at chunk boundaries. When the
//! control socket, whose worker end does not block, has no room, the
//! response waits in the request's outbox (its head with it when the head
//! has not gone out, and a fetch-streamed one at its head, its chunk or its
//! end), and the flush on the writability event, run by the loop or by the
//! test, finishes it, with the completion published after the last packet.
//! A deadline, a client reset or a local failure drops the parked rest
//! before it answers, a fetch aborted under a parked head fails only its own
//! stream, and a flush that finds the server gone stops the loop as a hangup
//! does. Runs in `worker-test`; the Web API side of `Response` is covered by
//! the `webapi` lane.

const std = @import("std");
const support = @import("bindings_support");
const bindings = @import("collo_bindings");
const fd_mod = @import("collo_os").fd;
const h2 = @import("collo_http").http2;
const ipc = @import("collo_ipc");
const limits = @import("collo_limits");
const worker_shared_page = @import("collo_worker_state").page;
const worker = @import("collo_worker");
const worker_request = @import("collo_worker_request");
const rt = @import("collo_test_harness");

const fakeNow = rt.fakeNow;
const initDispatchWork = rt.initDispatchWork;
const socketPairType = rt.socketPairType;
const readWorkerCompletion = rt.readWorkerCompletion;
const runRouteAndReadBody = rt.runRouteAndReadBody;
const runH2Route = rt.runH2Route;
const uring_backend = worker.testing.scheduler.uring_backend;

test "Response brand prevents plain objects from becoming HTTP responses" {
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

    var response = try rt.runRouteAndReadIngressResponse(&runtime, control_pair[1],
        \\export default function handle() {
        \\    return { status: 299, body: "not-a-response" };
        \\}
    , 13, "/plain-object-response.js");
    defer response.deinit();

    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expect(!std.mem.containsAtLeast(u8, response.body, 1, "not-a-response"));
}

test "fallback response coercion runs inside the request turn" {
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

    var response = try rt.runRouteAndReadIngressResponse(&runtime, control_pair[1],
        \\export default function handle() {
        \\    return {
        \\        toString() {
        \\            setTimeout(() => {}, 1);
        \\            return "fallback-turn-ok";
        \\        }
        \\    };
        \\}
    , 43, "/fallback-response-turn.js");
    defer response.deinit();

    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("fallback-turn-ok", response.body);
}

test "H2 route response emits descriptor batch and request done" {
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

    try runH2Route(
        &runtime,
        \\export default function handle() {
        \\    return new Response("h2-ok", {
        \\        status: 201,
        \\        headers: { "x-mode": "h2" }
        \\    });
        \\}
    ,
        91,
        7,
        "/h2-response.js",
        .{ .path = "/h2-response" },
    );

    var scratch: [ipc.max_message_bytes]u8 = undefined;
    var packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, control_pair[1], &scratch);
    try std.testing.expect(ipc.ingress_channel.isDescriptorBatchPacket(packet.bytes));
    var batch = try ipc.ingress_channel.decodeReceivedBatchPacket(std.testing.allocator, &packet);
    defer batch.deinit();

    try std.testing.expectEqual(@as(usize, 2), batch.items.len);
    try std.testing.expectEqual(@intFromEnum(ipc.ingress_channel.Op.response_head), batch.items[0].descriptor.op);
    try std.testing.expectEqual(@intFromEnum(ipc.ingress_channel.Op.response_chunk), batch.items[1].descriptor.op);
    try std.testing.expect(batch.items[1].descriptor.hasFlag(ipc.ingress_channel.flags.end_stream));
    try std.testing.expectEqualStrings("h2-ok", batch.items[1].payload);

    var head = try ipc.ingress_channel.decodeResponseHead(std.testing.allocator, batch.items[0].payload);
    defer head.deinit();
    try std.testing.expectEqual(@as(u16, 201), head.status);
    var saw_mode = false;
    for (head.headers) |header| {
        if (std.mem.eql(u8, header.name, "x-mode") and std.mem.eql(u8, header.value, "h2"))
            saw_mode = true;
    }
    try std.testing.expect(saw_mode);

    const done = try readWorkerCompletion(&runtime, control_pair[1], 91);
    try std.testing.expectEqual(@as(u64, 91), done.external_request_id);
    try std.testing.expectEqual(ipc.RequestDoneStatus.ok, @as(ipc.RequestDoneStatus, @enumFromInt(done.status)));
    try std.testing.expectEqual(@as(u16, 201), done.http_status);
}

test "H2 large route response uses shared payload ring" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    const ingress_payload_fd = try ipc.ingress_channel.createSharedPayloadMemfd();
    defer std.posix.close(ingress_payload_fd);
    var server_payload = try ipc.ingress_channel.mapSharedPayloadReadWrite(ingress_payload_fd, .server);
    defer server_payload.deinit();

    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{
        .clock = .{ .ctx = &now_mono_ns, .now_fn = fakeNow },
        .ingress_payload_fd = ingress_payload_fd,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    try runH2Route(
        &runtime,
        \\export default function handle() {
        \\    return new Response("x".repeat(64 * 1024));
        \\}
    ,
        92,
        9,
        "/h2-large-response.js",
        .{ .path = "/h2-large-response" },
    );

    var scratch: [ipc.max_message_bytes]u8 = undefined;
    var response_packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, control_pair[1], &scratch);
    try std.testing.expect(ipc.ingress_channel.isDescriptorBatchPacket(response_packet.bytes));
    var body_batch = try ipc.ingress_channel.decodeReceivedBatchPacketWithSharedPayload(std.testing.allocator, &response_packet, .{
        .worker_to_server = &server_payload,
    });
    defer body_batch.deinit();
    try std.testing.expectEqual(@as(usize, 2), body_batch.items.len);
    try std.testing.expectEqual(@intFromEnum(ipc.ingress_channel.Op.response_head), body_batch.items[0].descriptor.op);
    try std.testing.expectEqual(@intFromEnum(ipc.ingress_channel.Op.response_chunk), body_batch.items[1].descriptor.op);
    try std.testing.expect(body_batch.items[1].descriptor.hasFlag(ipc.ingress_channel.flags.end_stream));
    try std.testing.expect(!body_batch.items[1].payload_owned);
    try std.testing.expectEqual(@as(usize, 64 * 1024), body_batch.items[1].payload.len);
    try std.testing.expectEqual(@as(u8, 'x'), body_batch.items[1].payload[0]);
    try std.testing.expectEqual(@as(u8, 'x'), body_batch.items[1].payload[body_batch.items[1].payload.len - 1]);

    const done = try readWorkerCompletion(&runtime, control_pair[1], 92);
    try std.testing.expectEqual(@as(u64, 92), done.external_request_id);
    try std.testing.expectEqual(ipc.RequestDoneStatus.ok, @as(ipc.RequestDoneStatus, @enumFromInt(done.status)));
    try std.testing.expectEqual(@as(u16, 200), done.http_status);
}

test "H2 segmented Blob response emits chunks without flattening first" {
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

    try runH2Route(
        &runtime,
        \\export default function handle() {
        \\    const middle = new Blob([new Uint8Array([0, 255])]);
        \\    return new Response(new Blob([
        \\        new Uint8Array([65, 66]),
        \\        middle,
        \\        "tail",
        \\    ]), { status: 202 });
        \\}
    ,
        93,
        11,
        "/h2-segmented-blob-response.js",
        .{ .path = "/h2-segmented-blob-response" },
    );

    var scratch: [ipc.max_message_bytes]u8 = undefined;
    var head_packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, control_pair[1], &scratch);
    try std.testing.expect(!ipc.ingress_channel.isDescriptorBatchPacket(head_packet.bytes));
    var head_received = try ipc.ingress_channel.decodeReceivedPacket(std.testing.allocator, &head_packet);
    defer head_received.deinit();
    try std.testing.expectEqual(@intFromEnum(ipc.ingress_channel.Op.response_head), head_received.descriptor.op);
    try std.testing.expect(!head_received.descriptor.hasFlag(ipc.ingress_channel.flags.end_stream));
    var head = try ipc.ingress_channel.decodeResponseHead(std.testing.allocator, head_received.payload);
    defer head.deinit();
    try std.testing.expectEqual(@as(u16, 202), head.status);

    const expected_chunks = [_][]const u8{
        &[_]u8{ 65, 66 },
        &[_]u8{ 0, 255 },
        "tail",
    };
    for (expected_chunks, 0..) |expected, index| {
        var chunk_packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, control_pair[1], &scratch);
        try std.testing.expect(!ipc.ingress_channel.isDescriptorBatchPacket(chunk_packet.bytes));
        var chunk = try ipc.ingress_channel.decodeReceivedPacket(std.testing.allocator, &chunk_packet);
        defer chunk.deinit();
        try std.testing.expectEqual(@intFromEnum(ipc.ingress_channel.Op.response_chunk), chunk.descriptor.op);
        try std.testing.expectEqualSlices(u8, expected, chunk.payload);
        try std.testing.expectEqual(
            index + 1 == expected_chunks.len,
            chunk.descriptor.hasFlag(ipc.ingress_channel.flags.end_stream),
        );
    }

    const done = try readWorkerCompletion(&runtime, control_pair[1], 93);
    try std.testing.expectEqual(@as(u64, 93), done.external_request_id);
    try std.testing.expectEqual(ipc.RequestDoneStatus.ok, @as(ipc.RequestDoneStatus, @enumFromInt(done.status)));
    try std.testing.expectEqual(@as(u16, 202), done.http_status);
}

test "public Response property tampering does not affect internal response state" {
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

    var injected = try rt.runRouteAndReadIngressResponse(&runtime, control_pair[1],
        \\export default function handle() {
        \\    const response = new Response("bad", { headers: { "x-safe": "ok" } });
        \\    try {
        \\        response.headers = [["x-safe", "ok\r\nx-injected: yes"]];
        \\    } catch (_) {}
        \\    return response;
        \\}
    , 16, "/tampered-response-header.js");
    defer injected.deinit();
    try std.testing.expectEqual(@as(u16, 200), injected.status);
    try std.testing.expect(std.mem.containsAtLeast(u8, injected.headers_wire, 1, "x-safe: ok"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, injected.headers_wire, 1, "x-injected"));

    var invalid_status = try rt.runRouteAndReadIngressResponse(&runtime, control_pair[1],
        \\export default function handle() {
        \\    const response = new Response("bad");
        \\    try {
        \\        response.status = 700;
        \\    } catch (_) {}
        \\    return response;
        \\}
    , 17, "/tampered-response-status.js");
    defer invalid_status.deinit();
    try std.testing.expectEqual(@as(u16, 200), invalid_status.status);

    var immediate_header_reject = try rt.runRouteAndReadIngressResponse(&runtime, control_pair[1],
        \\export default function handle() {
        \\    const response = new Response("bad");
        \\    response.headers.set("x-safe", "ok\r\nx-injected: yes");
        \\    return response;
        \\}
    , 18, "/mutated-header-injection.js");
    defer immediate_header_reject.deinit();
    try std.testing.expectEqual(@as(u16, 500), immediate_header_reject.status);
    try std.testing.expect(!std.mem.containsAtLeast(u8, immediate_header_reject.headers_wire, 1, "x-injected"));

    var server_controlled_header = try rt.runRouteAndReadIngressResponse(&runtime, control_pair[1],
        \\export default function handle() {
        \\    const response = new Response("bad");
        \\    response.headers.set("content-length", "999");
        \\    return response;
        \\}
    , 19, "/server-controlled-response-header.js");
    defer server_controlled_header.deinit();
    try std.testing.expectEqual(@as(u16, 500), server_controlled_header.status);
    try std.testing.expect(!std.mem.containsAtLeast(u8, server_controlled_header.headers_wire, 1, "content-length: 999"));
}

test "Response constructor and json reject invalid Web API inputs" {
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

    const response = try runRouteAndReadBody(&runtime, control_pair[1],
        \\export default function handle() {
        \\    let primitiveInitThrows = false;
        \\    try {
        \\        new Response("missing", 404);
        \\    } catch (err) {
        \\        primitiveInitThrows = err instanceof TypeError;
        \\    }
        \\
        \\    let nullBodyStatusThrows = false;
        \\    try {
        \\        new Response("x", { status: 204 });
        \\    } catch (err) {
        \\        nullBodyStatusThrows = err instanceof TypeError;
        \\    }
        \\
        \\    let nullBodyStatusWithoutBody = false;
        \\    try {
        \\        nullBodyStatusWithoutBody = new Response(null, { status: 204 }).status === 204;
        \\    } catch (_) {}
        \\
        \\    let jsonUndefinedThrows = false;
        \\    try {
        \\        Response.json({ toJSON() { return undefined; } });
        \\    } catch (err) {
        \\        jsonUndefinedThrows = err instanceof TypeError;
        \\    }
        \\
        \\    let jsonNullBodyStatusThrows = false;
        \\    try {
        \\        Response.json({ ok: true }, { status: 204 });
        \\    } catch (err) {
        \\        jsonNullBodyStatusThrows = err instanceof TypeError;
        \\    }
        \\
        \\    return Response.json({
        \\        primitiveInitThrows,
        \\        nullBodyStatusThrows,
        \\        nullBodyStatusWithoutBody,
        \\        jsonUndefinedThrows,
        \\        jsonNullBodyStatusThrows
        \\    });
        \\}
    , 23, "/response-webapi-invalid-inputs.js");
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"primitiveInitThrows\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"nullBodyStatusThrows\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"nullBodyStatusWithoutBody\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"jsonUndefinedThrows\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"jsonNullBodyStatusThrows\":true"));
}

test "Response extraction uses current headers and preserves undefined string body" {
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

    var mutated_headers = try rt.runRouteAndReadIngressResponse(&runtime, control_pair[1],
        \\export default function handle() {
        \\    const response = new Response("ok", { headers: { "x-state": "old" } });
        \\    response.headers.set("x-state", "new");
        \\    response.headers.set("x-added", "yes");
        \\    return response;
        \\}
    , 18, "/response-mutated-headers.js");
    defer mutated_headers.deinit();
    try std.testing.expect(std.mem.containsAtLeast(u8, mutated_headers.headers_wire, 1, "x-state: new"));
    try std.testing.expect(std.mem.containsAtLeast(u8, mutated_headers.headers_wire, 1, "x-added: yes"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, mutated_headers.headers_wire, 1, "x-state: old"));

    var undefined_body = try rt.runRouteAndReadIngressResponse(&runtime, control_pair[1],
        \\export default function handle() {
        \\    return new Response("undefined", { headers: { "x-word": "undefined" } });
        \\}
    , 19, "/response-undefined-body.js");
    defer undefined_body.deinit();
    try std.testing.expect(std.mem.containsAtLeast(u8, undefined_body.headers_wire, 1, "x-word: undefined"));
    try std.testing.expectEqualStrings("undefined", undefined_body.body);

    var undefined_empty = try rt.runRouteAndReadIngressResponseWithRequest(&runtime, control_pair[1],
        \\export default function handle() {
        \\    return new Response(undefined);
        \\}
    , 20, "/response-undefined-empty.js", .{});
    defer undefined_empty.deinit();
    try std.testing.expectEqual(@as(u16, 200), undefined_empty.status);
    try std.testing.expectEqual(@as(usize, 0), undefined_empty.body.len);

    var null_empty = try rt.runRouteAndReadIngressResponseWithRequest(&runtime, control_pair[1],
        \\export default function handle() {
        \\    return new Response(null);
        \\}
    , 21, "/response-null-empty.js", .{});
    defer null_empty.deinit();
    try std.testing.expectEqual(@as(u16, 200), null_empty.status);
    try std.testing.expectEqual(@as(usize, 0), null_empty.body.len);

    var set_cookie = try rt.runRouteAndReadIngressResponse(&runtime, control_pair[1],
        \\export default function handle() {
        \\    const response = new Response("ok");
        \\    response.headers.append("set-cookie", "a=1");
        \\    response.headers.append("set-cookie", "b=2");
        \\    return response;
        \\}
    , 22, "/response-set-cookie.js");
    defer set_cookie.deinit();
    try std.testing.expect(std.mem.containsAtLeast(u8, set_cookie.headers_wire, 1, "set-cookie: a=1"));
    try std.testing.expect(std.mem.containsAtLeast(u8, set_cookie.headers_wire, 1, "set-cookie: b=2"));
}

test "Response extraction rejects oversized native response payloads before worker duplication" {
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

    var oversized_body = try rt.runRouteAndReadIngressResponse(&runtime, control_pair[1],
        \\export default function handle() {
        \\    return new Response("x".repeat(4 * 1024 * 1024 + 1));
        \\}
    , 31, "/response-oversized-body.js");
    defer oversized_body.deinit();
    try std.testing.expectEqual(@as(u16, 500), oversized_body.status);

    var too_many_headers = try rt.runRouteAndReadIngressResponse(&runtime, control_pair[1],
        \\export default function handle() {
        \\    const headers = new Headers();
        \\    for (let index = 0; index < 257; index++)
        \\        headers.set("x-" + index, "ok");
        \\    return new Response("ok", { headers });
        \\}
    , 32, "/response-too-many-headers.js");
    defer too_many_headers.deinit();
    try std.testing.expectEqual(@as(u16, 500), too_many_headers.status);

    var oversized_headers = try rt.runRouteAndReadIngressResponse(&runtime, control_pair[1],
        \\export default function handle() {
        \\    return new Response("ok", {
        \\        headers: { "x-big": "a".repeat(16 * 1024) }
        \\    });
        \\}
    , 33, "/response-oversized-headers.js");
    defer oversized_headers.deinit();
    try std.testing.expectEqual(@as(u16, 500), oversized_headers.status);
}

test "Response extraction reads internal state instead of observable properties" {
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

    var response = try rt.runRouteAndReadIngressResponse(&runtime, control_pair[1],
        \\export default function handle() {
        \\    const response = new Response("ok");
        \\    try {
        \\        Object.defineProperty(response, "status", {
        \\            get() { throw new Error("boom"); }
        \\        });
        \\    } catch (_) {}
        \\    return response;
        \\}
    , 20, "/response-extract-throws.js");
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("ok", response.body);
}

test "Response body methods share internal body state" {
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

    const response = try runRouteAndReadBody(&runtime, control_pair[1],
        \\export default async function handle() {
        \\    const jsonResponse = new Response("{\"value\":7}");
        \\    const before = jsonResponse.bodyUsed;
        \\    const parsed = await jsonResponse.json();
        \\    const after = jsonResponse.bodyUsed;
        \\    let secondPromiseReturned = false;
        \\    let secondRejected = false;
        \\    try {
        \\        const second = jsonResponse.text();
        \\        secondPromiseReturned = second instanceof Promise;
        \\        await second;
        \\    } catch (err) {
        \\        secondRejected = err instanceof TypeError && err.message === "Body already used";
        \\    }
        \\
        \\    const textResponse = new Response("hello");
        \\    const text = await textResponse.text();
        \\
        \\    let invalidPromiseReturned = false;
        \\    let invalidRejected = false;
        \\    try {
        \\        const invalid = new Response("{").json();
        \\        invalidPromiseReturned = invalid instanceof Promise;
        \\        await invalid;
        \\    } catch (err) {
        \\        invalidRejected = err instanceof SyntaxError;
        \\    }
        \\
        \\    return Response.json({
        \\        before,
        \\        after,
        \\        value: parsed.value,
        \\        secondPromiseReturned,
        \\        secondRejected,
        \\        text,
        \\        textUsed: textResponse.bodyUsed,
        \\        invalidPromiseReturned,
        \\        invalidRejected
        \\    });
        \\}
    , 23, "/response-body-state.js");
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"before\":false"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"after\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"value\":7"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"secondPromiseReturned\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"secondRejected\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"text\":\"hello\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"textUsed\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"invalidPromiseReturned\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"invalidRejected\":true"));
}

test "Response extraction can return a consumed internal body" {
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

    var response = try rt.runRouteAndReadIngressResponse(&runtime, control_pair[1],
        \\export default async function handle() {
        \\    const response = new Response("still-output");
        \\    await response.text();
        \\    return response;
        \\}
    , 24, "/response-consumed-extract.js");
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("still-output", response.body);
}

test "Response extraction preserves binary BodyInit bytes" {
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

    var response = try rt.runRouteAndReadIngressResponseWithRequest(&runtime, control_pair[1],
        \\export default function handle() {
        \\    return new Response(new Uint8Array([0, 255, 65]), {
        \\        headers: { "content-type": "application/octet-stream" },
        \\    });
        \\}
    , 25, "/response-binary-bodyinit.js", .{});
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expect(std.mem.containsAtLeast(u8, response.headers_wire, 1, "content-type: application/octet-stream"));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 255, 65 }, response.body);
}

// The ring batch loop behind `flushBufferedBody` must size each next chunk
// from the offset advanced by the bytes already batched. Sized from the base
// offset, the final chunk reads up to one chunk past the end of the body: a
// bounds panic in safe builds, and heap bytes sent to the client in
// ReleaseFast. Every case drives the flush end to end over a real shared
// payload ring and checks the exact bytes that reach the host.
test "flushBufferedBody delivers exact bytes at chunk boundaries without overread" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    const ingress_payload_fd = try ipc.ingress_channel.createSharedPayloadMemfd();
    defer std.posix.close(ingress_payload_fd);
    var server_payload = try ipc.ingress_channel.mapSharedPayloadReadWrite(ingress_payload_fd, .server);
    defer server_payload.deinit();

    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{
        .clock = .{ .ctx = &now_mono_ns, .now_fn = fakeNow },
        .ingress_payload_fd = ingress_payload_fd,
    });
    defer runtime.deinit();

    // This repeats the chunk limit the body writer computes: its scratch
    // buffer is `ipc.max_message_bytes` long, so `INGRESS_RESPONSE_CHUNK_BYTES`
    // is the smaller bound.
    const chunk_limit: usize = @min(
        ipc.max_message_bytes - @sizeOf(ipc.ingress_channel.Packet),
        limits.http_body.INGRESS_RESPONSE_CHUNK_BYTES,
    );
    // The batch path engages only for chunks above the shared payload
    // threshold. Should this fail, the cases below would no longer exercise
    // the ring math at all.
    try std.testing.expect(chunk_limit > ipc.ingress_channel.shared_payload_threshold);

    const cases = [_]usize{
        2 * chunk_limit, // exact multiple: loop must stop exactly at the end
        2 * chunk_limit + 1, // one past: 1-byte inline tail after the ring batch
        2 * chunk_limit - 1, // one short: final ring chunk of chunk_limit - 1
        chunk_limit + 40_000, // non-multiple tail still above the ring threshold
    };

    for (cases, 0..) |body_len, case_index| {
        const dispatch = try rt.initDispatchWork(std.testing.allocator, .{
            .request_id = 9100 + @as(u64, case_index),
        });
        var ctx = worker_request.context.RequestContext.initOwnedDispatch(
            std.testing.allocator,
            @intCast(21 + case_index),
            dispatch,
            .{ .index = 0, .generation = 1 },
            0,
        );
        defer ctx.deinit();

        const body = try std.testing.allocator.alloc(u8, body_len);
        defer std.testing.allocator.free(body);
        for (body, 0..) |*byte, index|
            byte.* = @truncate(index *% 31 +% 7 +% case_index);

        var buffered = worker_request.ingress.response_outbox.BufferedBody{
            .body = body,
            .offset = 0,
            .done_status = .ok,
            .http_status = 200,
        };
        const writer = worker.testing.response_payload_writer;
        try std.testing.expectEqual(writer.BodyProgress.sent, try writer.flushBufferedBody(&runtime, &ctx, &buffered));
        try std.testing.expectEqual(body_len, buffered.offset);
        try std.testing.expectEqual(@as(u64, body_len), ctx.client_served_bytes);

        // Drain the host end: every chunk equals the matching body slice byte
        // for byte, and only the final chunk carries end_stream.
        var received: usize = 0;
        var saw_end = false;
        while (!saw_end) {
            var scratch: [ipc.max_message_bytes]u8 = undefined;
            var raw_packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, control_pair[1], &scratch);
            if (ipc.ingress_channel.isDescriptorBatchPacket(raw_packet.bytes)) {
                var batch = try ipc.ingress_channel.decodeReceivedBatchPacketWithSharedPayload(std.testing.allocator, &raw_packet, .{
                    .worker_to_server = &server_payload,
                });
                defer batch.deinit();
                for (batch.items) |item| {
                    try std.testing.expect(!saw_end);
                    try std.testing.expectEqual(@intFromEnum(ipc.ingress_channel.Op.response_chunk), item.descriptor.op);
                    try std.testing.expect(item.payload.len <= body_len - received);
                    try std.testing.expectEqualSlices(u8, body[received..][0..item.payload.len], item.payload);
                    received += item.payload.len;
                    if (item.descriptor.hasFlag(ipc.ingress_channel.flags.end_stream))
                        saw_end = true;
                }
            } else {
                var single = try ipc.ingress_channel.decodeReceivedPacketWithSharedPayload(std.testing.allocator, &raw_packet, .{
                    .worker_to_server = &server_payload,
                });
                defer single.deinit();
                try std.testing.expectEqual(@intFromEnum(ipc.ingress_channel.Op.response_chunk), single.descriptor.op);
                try std.testing.expect(single.payload.len <= body_len - received);
                try std.testing.expectEqualSlices(u8, body[received..][0..single.payload.len], single.payload);
                received += single.payload.len;
                if (single.descriptor.hasFlag(ipc.ingress_channel.flags.end_stream))
                    saw_end = true;
            }
        }
        try std.testing.expectEqual(body_len, received);
    }
}

test "streaming body clone fan-out and Response.json enforce serverless quota caps" {
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

    const response = try runRouteAndReadBody(&runtime, control_pair[1],
        \\function makeStreamResponse() {
        \\    return new Response(new ReadableStream({
        \\        start(controller) {
        \\            controller.enqueue(new TextEncoder().encode("chunk"));
        \\            controller.close();
        \\        }
        \\    }));
        \\}
        \\export default async function handle() {
        \\    const source = makeStreamResponse();
        \\    let cloneCount = 0;
        \\    let cloneError = null;
        \\    try {
        \\        for (let index = 0; index < 64; index++) {
        \\            source.clone();
        \\            cloneCount++;
        \\        }
        \\    } catch (err) {
        \\        cloneError = err;
        \\    }
        \\    const cloneRejected = cloneError instanceof DOMException && cloneError.name === "QuotaExceededError";
        \\    const cloneCapped = cloneCount === 16;
        \\    const survivorClone = makeStreamResponse().clone();
        \\    const cloneWithinCapWorks = (await survivorClone.text()) === "chunk";
        \\
        \\    const chunk = "x".repeat(65536);
        \\    let jsonError = null;
        \\    try {
        \\        Response.json(new Array(80).fill(chunk));
        \\    } catch (err) {
        \\        jsonError = err;
        \\    }
        \\    const jsonRejected = jsonError instanceof DOMException
        \\        && jsonError.name === "QuotaExceededError"
        \\        && jsonError.message === "Response JSON body exceeds the serverless body limit";
        \\    const small = { nested: [1, 2.5, null, true], text: "café", quoted: "a\"b\\c" };
        \\    const jsonWithinCapMatches = (await Response.json(small).text()) === JSON.stringify(small);
        \\    const toJsonValue = { toJSON(key) { return "key:" + key; } };
        \\    const jsonToJsonMatches
        \\        = (await Response.json({ outer: toJsonValue }).text()) === JSON.stringify({ outer: toJsonValue });
        \\    let cyclicError = null;
        \\    try {
        \\        const cyclic = {};
        \\        cyclic.self = cyclic;
        \\        Response.json(cyclic);
        \\    } catch (err) {
        \\        cyclicError = err;
        \\    }
        \\    const jsonCyclicThrowsTypeError = cyclicError instanceof TypeError;
        \\    return Response.json({
        \\        cloneRejected,
        \\        cloneCapped,
        \\        cloneWithinCapWorks,
        \\        jsonRejected,
        \\        jsonWithinCapMatches,
        \\        jsonToJsonMatches,
        \\        jsonCyclicThrowsTypeError
        \\    });
        \\}
    , 40, "/dos-clone-json-caps.js");
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"cloneRejected\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"cloneCapped\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"cloneWithinCapWorks\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"jsonRejected\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"jsonWithinCapMatches\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"jsonToJsonMatches\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"jsonCyclicThrowsTypeError\":true"));
}

test "a response whose head finds the control socket full waits in the outbox until the socket drains" {
    var fixture: SocketFullWorker = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const runtime = &fixture.runtime;

    const filler_count = try fillSendBuffer(fixture.control_pair[0]);
    try std.testing.expect(filler_count > 0);
    try fixture.dispatch(401, alphabet_source, "/socket-full-head.js");

    const request_ctx = try runUntilParked(runtime, 401);
    try std.testing.expect(runtime.requests.control_send_blocked);
    try std.testing.expect(!request_ctx.response_committed);
    switch (request_ctx.response_outbox.pending) {
        .buffered_body => |buffered| {
            try std.testing.expect(buffered.head != null);
            try std.testing.expectEqual(@as(usize, 0), buffered.offset);
            try std.testing.expectEqual(alphabet_body_len, buffered.body.len);
        },
        else => return error.TestUnexpectedResult,
    }
    // The first batch wrote a ring chunk before its send found the socket
    // full, and took it back.
    const worker_payload = if (runtime.requests.ingress_payload) |*view| view else return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        ipc.ingress_channel.shared_payload_ring_capacity,
        try worker_payload.availableCapacity(.worker_to_server),
    );
    try fixture.expectNoCompletion();
    try fixture.expectWritablePollArmed();

    try std.testing.expectEqual(filler_count, try drainFiller(fixture.control_pair[1]));
    var response: ReadResponse = .{};
    defer response.deinit();
    try fixture.serveUntilFinished(&response, 401);
    try std.testing.expect(!runtime.requests.control_send_blocked);
    try response.readUntilEnd(&fixture);
    try std.testing.expectEqual(@as(?u16, 201), response.status);
    try expectAlphabetBody(response.body.items);

    const done = try readWorkerCompletion(runtime, fixture.control_pair[1], 401);
    try std.testing.expectEqual(@intFromEnum(ipc.RequestDoneStatus.ok), done.status);
    try std.testing.expectEqual(@as(u16, 201), done.http_status);
}

test "a response larger than the control socket's send buffer finishes from the flush once the server reads" {
    var fixture: SocketFullWorker = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const runtime = &fixture.runtime;

    try fixture.dispatch(402, parts_source, "/socket-full-body.js");
    const request_ctx = try runUntilParked(runtime, 402);
    try std.testing.expect(runtime.requests.control_send_blocked);
    try std.testing.expect(request_ctx.response_committed);
    const parked_offset = switch (request_ctx.response_outbox.pending) {
        .buffered_body => |buffered| parked: {
            try std.testing.expect(buffered.head == null);
            try std.testing.expectEqual(parts_body_len, buffered.body.len);
            break :parked buffered.offset;
        },
        else => return error.TestUnexpectedResult,
    };
    // Each part went out in one packet, so the rest starts at a part.
    try std.testing.expect(parked_offset > 0);
    try std.testing.expect(parked_offset < parts_body_len);
    try std.testing.expectEqual(@as(usize, 0), parked_offset % part_bytes);
    try fixture.expectNoCompletion();
    try fixture.expectWritablePollArmed();

    var response: ReadResponse = .{};
    defer response.deinit();
    try response.readAvailable(&fixture);
    try std.testing.expectEqual(@as(?u16, 202), response.status);
    try std.testing.expectEqual(parked_offset, response.body.items.len);
    try std.testing.expect(!response.ended);

    try fixture.serveUntilFinished(&response, 402);
    try response.readUntilEnd(&fixture);
    try std.testing.expectEqual(parts_body_len, response.body.items.len);
    try expectPartsBytes(response.body.items);

    const done = try readWorkerCompletion(runtime, fixture.control_pair[1], 402);
    try std.testing.expectEqual(@intFromEnum(ipc.RequestDoneStatus.ok), done.status);
    try std.testing.expectEqual(@as(u16, 202), done.http_status);
}

test "a deadline answers 504 in place of a response whose head waits in the outbox" {
    var fixture: SocketFullWorker = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const runtime = &fixture.runtime;

    const filler_count = try fillSendBuffer(fixture.control_pair[0]);
    try fixture.dispatch(403,
        \\export default function handle() {
        \\    return new Response("first answer", { status: 200 });
        \\}
    , "/socket-full-deadline.js");
    _ = try runUntilParked(runtime, 403);

    // The socket is still full, so the 504 waits in the outbox in place of
    // the first answer.
    try worker.testing.request_dispatch.deadlineTimeout(runtime, 403);
    const request_ctx = runtime.requests.active.get(403) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!request_ctx.response_committed);
    switch (request_ctx.response_outbox.pending) {
        .buffered_body => |buffered| {
            const head = buffered.head orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(u16, 504), head.status);
            try std.testing.expectEqualStrings("gateway timeout", buffered.body);
        },
        else => return error.TestUnexpectedResult,
    }
    try fixture.expectNoCompletion();

    try std.testing.expectEqual(filler_count, try drainFiller(fixture.control_pair[1]));
    var response: ReadResponse = .{};
    defer response.deinit();
    try fixture.serveUntilFinished(&response, 403);
    try response.readUntilEnd(&fixture);
    try std.testing.expectEqual(@as(?u16, 504), response.status);
    try std.testing.expectEqualStrings("gateway timeout", response.body.items);
    try std.testing.expect(!(try socketReadable(fixture.control_pair[1], 0)));

    const done = try readWorkerCompletion(runtime, fixture.control_pair[1], 403);
    try std.testing.expectEqual(@intFromEnum(ipc.RequestDoneStatus.deadline_timeout), done.status);
    try std.testing.expectEqual(@as(u16, 504), done.http_status);
}

test "a local failure resets a committed response whose rest waits in the outbox, and the worker keeps running" {
    var fixture: SocketFullWorker = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const runtime = &fixture.runtime;

    try fixture.dispatch(404, parts_source, "/socket-full-reset.js");
    const committed_ctx = try runUntilParked(runtime, 404);
    try std.testing.expect(committed_ctx.response_committed);

    // The socket is still full, so the reset waits in the outbox in place of
    // the rest of the body.
    worker.testing.request_dispatch.handleLocalFailure(runtime, 404, error.TestInjectedFailure);
    try std.testing.expect(runtime.core.running);
    const request_ctx = runtime.requests.active.get(404) orelse return error.TestUnexpectedResult;
    const internal_error_code: u32 = @intFromEnum(h2.ErrorCode.internal_error);
    switch (request_ctx.response_outbox.pending) {
        .stream_reset => |reset_code| try std.testing.expectEqual(internal_error_code, reset_code),
        else => return error.TestUnexpectedResult,
    }
    try fixture.expectNoCompletion();

    var response: ReadResponse = .{};
    defer response.deinit();
    try fixture.serveUntilFinished(&response, 404);
    try response.readUntilEnd(&fixture);
    try std.testing.expectEqual(@as(?u16, 202), response.status);
    try std.testing.expectEqual(@as(?u32, internal_error_code), response.reset_code);
    try std.testing.expect(response.body.items.len < parts_body_len);
    try expectPartsBytes(response.body.items);

    const done = try readWorkerCompletion(runtime, fixture.control_pair[1], 404);
    try std.testing.expectEqual(@intFromEnum(ipc.RequestDoneStatus.internal_error), done.status);
    try std.testing.expectEqual(@as(u16, 502), done.http_status);
}

test "a client reset drops the parked rest of a committed response and publishes its completion with nothing sent after it" {
    try expectParkedRestDropped(.{
        .request_id = 405,
        .specifier = "/socket-full-client-reset.js",
        .end = .client_reset,
        .done_status = .client_closed,
        .http_status = 499,
    });
}

test "a deadline drops the parked rest of a committed response and publishes its completion with nothing sent after it" {
    try expectParkedRestDropped(.{
        .request_id = 406,
        .specifier = "/socket-full-committed-deadline.js",
        .end = .deadline,
        .done_status = .deadline_timeout,
        .http_status = 504,
    });
}

test "a fetch-streamed response waits in the outbox at its head, its chunk and its end, and each flush sends the step that waited" {
    const origin = try rt.LocalOrigin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);
    var fixture: SocketFullWorker = undefined;
    try fixture.init(.{ .with_gateway = true });
    defer fixture.deinit();
    const runtime = &fixture.runtime;
    const source = try fetchStreamSource(origin);
    defer std.testing.allocator.free(source);

    var filler_count = try fillSendBuffer(fixture.control_pair[0]);
    try fixture.dispatch(407, source, "/socket-full-stream.js");
    const request_ctx = try runUntilParked(runtime, 407);
    try std.testing.expectEqual(.stream_head, std.meta.activeTag(request_ctx.response_outbox.pending));
    try std.testing.expect(!request_ctx.response_committed);
    try fixture.expectWritablePollArmed();

    // Each flush sends the step that waited, and the step after it waits in
    // turn, since the test fills the socket again before the worker runs.
    var response: ReadResponse = .{};
    defer response.deinit();
    try std.testing.expectEqual(filler_count, try drainFiller(fixture.control_pair[1]));
    try fixture.flushWhenWritable();
    try std.testing.expect(request_ctx.response_committed);
    try response.readAvailable(&fixture);
    try std.testing.expectEqual(@as(?u16, 200), response.status);

    filler_count = try fillSendBuffer(fixture.control_pair[0]);
    _ = try runUntilParked(runtime, 407);
    try std.testing.expectEqual(.stream_chunk, std.meta.activeTag(request_ctx.response_outbox.pending));
    try std.testing.expectEqual(filler_count, try drainFiller(fixture.control_pair[1]));
    try fixture.flushWhenWritable();
    try response.readAvailable(&fixture);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 255, 65 }, response.body.items);
    try std.testing.expect(!response.ended);

    filler_count = try fillSendBuffer(fixture.control_pair[0]);
    _ = try runUntilParked(runtime, 407);
    try std.testing.expectEqual(.stream_end, std.meta.activeTag(request_ctx.response_outbox.pending));
    try fixture.expectNoCompletion();
    try std.testing.expectEqual(filler_count, try drainFiller(fixture.control_pair[1]));
    try fixture.flushWhenWritable();
    try std.testing.expect(!runtime.requests.active.contains(407));
    try response.readUntilEnd(&fixture);
    try std.testing.expect(response.reset_code == null);

    const done = try readWorkerCompletion(runtime, fixture.control_pair[1], 407);
    try std.testing.expectEqual(@intFromEnum(ipc.RequestDoneStatus.ok), done.status);
    try std.testing.expectEqual(@as(u16, 200), done.http_status);
}

test "a fetch aborted while its streamed response's head waits resets that one stream from the flush, and the worker keeps running" {
    const origin = try rt.LocalOrigin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);
    var fixture: SocketFullWorker = undefined;
    try fixture.init(.{ .with_gateway = true });
    defer fixture.deinit();
    const runtime = &fixture.runtime;
    const source = try fetchStreamSource(origin);
    defer std.testing.allocator.free(source);

    const filler_count = try fillSendBuffer(fixture.control_pair[0]);
    try fixture.dispatch(408, source, "/socket-full-stream-abort.js");
    const request_ctx = try runUntilParked(runtime, 408);
    try std.testing.expectEqual(.stream_head, std.meta.activeTag(request_ctx.response_outbox.pending));

    // The gateway's acknowledgment of the fetch's abort releases the body's
    // view (`gateway_runtime.handleAbortAck`), so the pull the head's flush
    // starts cannot begin.
    const identity = request_ctx.response_stream_body orelse return error.TestUnexpectedResult;
    const ack = ipc.messages.EgressAbortAck.init(identity.fetch_id, identity.body_id);
    const gateway = fixture.gateway orelse return error.TestUnexpectedResult;
    try gateway.queueCompletionPacket(std.mem.asBytes(&ack));
    _ = try runtime.collectEgressGatewayPacketsBounded(64);
    const body = runtime.egress.state.bodies.get(identity.body_id) orelse return error.TestUnexpectedResult;
    try std.testing.expect(body.viewReleased());

    try std.testing.expectEqual(filler_count, try drainFiller(fixture.control_pair[1]));
    var response: ReadResponse = .{};
    defer response.deinit();
    try fixture.serveUntilFinished(&response, 408);
    try std.testing.expect(runtime.core.running);
    try response.readUntilEnd(&fixture);
    try std.testing.expectEqual(@as(?u16, 200), response.status);
    try std.testing.expectEqual(@as(usize, 0), response.body.items.len);
    try std.testing.expectEqual(@as(?u32, @intFromEnum(h2.ErrorCode.internal_error)), response.reset_code);

    const done = try readWorkerCompletion(runtime, fixture.control_pair[1], 408);
    try std.testing.expectEqual(@intFromEnum(ipc.RequestDoneStatus.internal_error), done.status);
    try std.testing.expectEqual(@as(u16, 200), done.http_status);
}

test "a flush whose send finds the server gone stops the loop as a hangup does" {
    var fixture: SocketFullWorker = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const runtime = &fixture.runtime;

    _ = try fillSendBuffer(fixture.control_pair[0]);
    try fixture.dispatch(409, alphabet_source, "/socket-full-server-gone.js");
    _ = try runUntilParked(runtime, 409);

    // The server goes away between the poll's report and the flush's send.
    try std.posix.shutdown(fixture.control_pair[1], .both);
    try std.testing.expectError(error.ControlPeerClosed, worker.testing.scheduler.loop.flushParkedResponses(runtime));
}

test "the loop sends a parked response once the server drains the socket, and publishes its completion after it" {
    var fixture: SocketFullWorker = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const runtime = &fixture.runtime;

    const filler_count = try fillSendBuffer(fixture.control_pair[0]);
    try fixture.dispatch(410, alphabet_source, "/socket-full-loop.js");
    _ = try runUntilParked(runtime, 410);
    try fixture.expectNoCompletion();

    // A second thread plays the server while this one runs the loop: it
    // drains the socket, reads the response to its end and hangs up, which
    // stops the loop.
    var server: LoopServer = .{ .fixture = &fixture, .filler_count = filler_count };
    defer server.response.deinit();
    const thread = try std.Thread.spawn(.{}, LoopServer.run, .{&server});
    const loop_result = worker.testing.scheduler.loop.run(runtime);
    thread.join();
    try loop_result;
    try server.result;
    if (server.shutdown_error) |err|
        return err;

    try std.testing.expect(!runtime.requests.active.contains(410));
    try std.testing.expect(!runtime.requests.control_send_blocked);
    try std.testing.expectEqual(@as(?u16, 201), server.response.status);
    try expectAlphabetBody(server.response.body.items);
    const done = try readWorkerCompletion(runtime, fixture.control_pair[1], 410);
    try std.testing.expectEqual(@intFromEnum(ipc.RequestDoneStatus.ok), done.status);
    try std.testing.expectEqual(@as(u16, 201), done.http_status);
}

/// How `expectParkedRestDropped` ends the request whose rest waits: as the
/// server's reset of the stream does, or as its deadline does.
const RequestEnd = enum { client_reset, deadline };

const ParkedRestCase = struct {
    request_id: u64,
    specifier: []const u8,
    end: RequestEnd,
    done_status: ipc.RequestDoneStatus,
    http_status: u16,
};

/// Parks the rest of a committed response, ends the request as `case.end`
/// says, and checks the completion, that the client got the head and a
/// prefix of the body, and that the flush the parked send left to arm sends
/// nothing more.
fn expectParkedRestDropped(case: ParkedRestCase) !void {
    var fixture: SocketFullWorker = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const runtime = &fixture.runtime;

    try fixture.dispatch(case.request_id, parts_source, case.specifier);
    const request_ctx = try runUntilParked(runtime, case.request_id);
    try std.testing.expect(request_ctx.response_committed);
    switch (case.end) {
        .client_reset => try worker.testing.request_dispatch.cancelClientReset(runtime, case.request_id),
        .deadline => try worker.testing.request_dispatch.deadlineTimeout(runtime, case.request_id),
    }
    try std.testing.expect(!runtime.requests.active.contains(case.request_id));
    try std.testing.expect(runtime.core.running);
    const done = try readWorkerCompletion(runtime, fixture.control_pair[1], case.request_id);
    try std.testing.expectEqual(@intFromEnum(case.done_status), done.status);
    try std.testing.expectEqual(case.http_status, done.http_status);

    var response: ReadResponse = .{};
    defer response.deinit();
    try response.readAvailable(&fixture);
    try std.testing.expectEqual(@as(?u16, 202), response.status);
    try std.testing.expect(!response.ended);
    try std.testing.expect(response.body.items.len < parts_body_len);
    try expectPartsBytes(response.body.items);
    try fixture.flushWhenWritable();
    try std.testing.expect(!runtime.requests.control_send_blocked);
    try std.testing.expect(!(try socketReadable(fixture.control_pair[1], 0)));
}

/// The server's side of the loop test, on a thread of its own: it reads the
/// filler, then the response to its end, then hangs up whatever it found.
const LoopServer = struct {
    fixture: *SocketFullWorker,
    filler_count: usize,
    response: ReadResponse = .{},
    result: anyerror!void = {},
    shutdown_error: ?anyerror = null,

    fn run(self: *LoopServer) void {
        self.result = self.serve();
        std.posix.shutdown(self.fixture.control_pair[1], .both) catch |err| {
            self.shutdown_error = err;
        };
    }

    fn serve(self: *LoopServer) !void {
        // The worker sends once part of the filler is read, so the filler
        // is read by count: the socket never has to look empty first.
        const server_fd = self.fixture.control_pair[1];
        var packet: [filler_packet_bytes + 1]u8 = undefined;
        for (0..self.filler_count) |_| {
            if (!try socketReadable(server_fd, 1000))
                return error.TestUnexpectedResult;
            const received = try std.posix.recv(server_fd, &packet, 0);
            try std.testing.expectEqual(filler_packet_bytes, received);
            try std.testing.expect(std.mem.allEqual(u8, packet[0..received], filler_byte));
        }
        try self.response.readUntilEnd(self.fixture);
    }
};

/// A handler that answers with a fetch's response, so its body streams from
/// the gateway: a head, one chunk of the three bytes `LocalOrigin` serves on
/// `/binary`, then the end, each written when the body's pull delivers it.
fn fetchStreamSource(origin: *const rt.LocalOrigin) ![]u8 {
    return std.fmt.allocPrint(std.testing.allocator,
        \\export default async function handle() {{
        \\    return await fetch("http://{s}:{d}/binary");
        \\}}
    , .{ origin.host(), origin.port });
}

/// A body of one ring chunk and an inline tail, the alphabet repeated, so a
/// test can check every byte.
const alphabet_body_len: usize = 64 * 1024 + 1000;
const alphabet_source = std.fmt.comptimePrint(
    \\export default function handle() {{
    \\    return new Response("abcdefghijklmnopqrstuvwxyz".repeat({d}).slice(0, {d}), {{ status: 201 }});
    \\}}
, .{ alphabet_body_len / 26 + 1, alphabet_body_len });

/// A Blob body whose parts each ride one inline packet, so a few parts fill
/// the send buffer once the head went out. Part `index` holds `index + 1`.
const part_bytes: usize = 16 * 1024;
const part_count: usize = 32;
const parts_body_len: usize = part_bytes * part_count;
const parts_source = std.fmt.comptimePrint(
    \\export default function handle() {{
    \\    const parts = [];
    \\    for (let index = 0; index < {d}; index++)
    \\        parts.push(new Uint8Array({d}).fill(index + 1));
    \\    return new Response(new Blob(parts), {{ status: 202 }});
    \\}}
, .{ part_count, part_bytes });

/// What a test sends on the worker's end of the control socket until a send
/// would block, and reads back as the server.
const filler_packet_bytes: usize = 16 * 1024;
const filler_byte: u8 = 0xee;
const max_filler_packets: usize = 1024;
/// Bounds every loop that waits on the worker or the kernel, polling once a
/// millisecond.
const max_wait_rounds: usize = 1000;

// The worker ring's `fs_fault` fixed file comes from the installed fs index,
// so the fixture installs the placeholder index with a live SEQPACKET pair.
const ring_index_bytes: []const u8 = &worker.fs.fs_index.placeholder_bytes;

/// A worker on its restricted ring whose control socket's worker end does
/// not block, as `zygote/child_boot.zig` leaves it, with a send buffer small
/// enough to fill. The test plays the server on the socket's other end and
/// on the shared payload ring. It is initialized in place, because the
/// runtime keeps pointers to the fields beside it.
const SocketFullWorker = struct {
    now_mono_ns: u64,
    scratch: []u8,
    control_pair: [2]std.posix.fd_t,
    ingress_payload_fd: std.posix.fd_t,
    server_payload: ipc.ingress_channel.SharedPayloadView,
    wake_set: ipc.egress_shared.WakeSet,
    /// The worker's egress session when no gateway serves it, and empty
    /// when one does.
    shared: ipc.egress_shared.SessionFds,
    gateway: ?*rt.LocalEgressGateway,
    worker_raw: ipc.egress_shared.RawFds,
    fault_pair: [2]std.posix.fd_t,
    vm: bindings.Vm,
    completion_fixture: rt.CompletionFixture,
    runtime: worker.Runtime,
    /// Arms its polls at its first `arm`, so a test that runs the loop,
    /// which brings a backend of its own, leaves none of these in flight.
    backend: uring_backend.UringBackend,

    /// Requested for the worker's end. The kernel caps the request at
    /// `net.core.wmem_max` and doubles it; with the default cap the buffer
    /// holds any single packet of these tests and less than the parts body.
    const send_buffer_request_bytes: c_int = 64 * 1024;

    const Options = struct {
        /// Serves the worker's egress session with a gateway that reaches a
        /// `LocalOrigin`, for a handler that fetches.
        with_gateway: bool = false,
    };

    fn init(self: *SocketFullWorker, options: Options) !void {
        self.now_mono_ns = 0;
        self.scratch = try std.testing.allocator.alloc(u8, ipc.max_message_bytes);
        errdefer std.testing.allocator.free(self.scratch);

        self.control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
        errdefer closePair(self.control_pair);
        try fd_mod.setNonblocking(self.control_pair[0], true);
        const send_buffer_bytes = send_buffer_request_bytes;
        try std.posix.setsockopt(
            self.control_pair[0],
            std.posix.SOL.SOCKET,
            std.posix.SO.SNDBUF,
            std.mem.asBytes(&send_buffer_bytes),
        );

        self.ingress_payload_fd = try ipc.ingress_channel.createSharedPayloadMemfd();
        errdefer std.posix.close(self.ingress_payload_fd);
        self.server_payload = try ipc.ingress_channel.mapSharedPayloadReadWrite(self.ingress_payload_fd, .server);
        errdefer self.server_payload.deinit();

        self.wake_set = try ipc.egress_shared.WakeSet.create();
        errdefer self.wake_set.deinit();
        if (options.with_gateway) {
            self.shared = .{};
            const gateway = try rt.LocalEgressGateway.startOnWakeSet(std.testing.allocator, .{
                .network = rt.local_origin_network,
            }, &self.wake_set);
            self.gateway = gateway;
            self.worker_raw = gateway.takeWorkerSharedFds();
        } else {
            self.gateway = null;
            self.shared = try ipc.egress_shared.createSessionForWorker(&self.wake_set);
            self.worker_raw = self.shared.takeWorkerHalf();
        }
        errdefer if (self.gateway) |gateway| gateway.deinit();
        errdefer self.shared.deinit();
        const ingress_payload_credit_fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
        var credit_fd_owned_by_runtime = false;
        errdefer if (!credit_fd_owned_by_runtime)
            std.posix.close(ingress_payload_credit_fd);

        self.fault_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
        errdefer closePair(self.fault_pair);
        try worker.fs.installForTestWithFault(ring_index_bytes, worker.fs.deploy_root, self.fault_pair[0], worker.fs.deploy_root);
        errdefer worker.fs.uninstallForTest();

        self.vm = try support.createVm();
        errdefer self.vm.deinit();
        self.completion_fixture = try rt.CompletionFixture.init();
        errdefer self.completion_fixture.deinit();
        // `Runtime.init` takes the credit eventfd, closing it on failure.
        credit_fd_owned_by_runtime = true;
        self.runtime = try worker.Runtime.init(
            std.testing.allocator,
            &self.vm,
            self.control_pair[0],
            &self.completion_fixture.view,
            try rt.createCompletionEventfd(),
            worker.RuntimeOptions{
                .clock = .{ .ctx = &self.now_mono_ns, .now_fn = fakeNow },
                .ingress_payload_fd = self.ingress_payload_fd,
                .egress_shared_fds = &self.worker_raw,
                .ingress_payload_credit_eventfd = ingress_payload_credit_fd,
            },
        );
        errdefer self.runtime.deinit();
        try self.runtime.attachHostRuntime();
        try self.runtime.initRestrictedWorkerRing();
        self.backend = .{};
    }

    fn deinit(self: *SocketFullWorker) void {
        self.backend.deinit();
        self.runtime.deinit();
        self.completion_fixture.deinit();
        self.vm.deinit();
        worker.fs.uninstallForTest();
        closePair(self.fault_pair);
        self.shared.deinit();
        if (self.gateway) |gateway|
            gateway.deinit();
        self.wake_set.deinit();
        self.server_payload.deinit();
        std.posix.close(self.ingress_payload_fd);
        closePair(self.control_pair);
        std.testing.allocator.free(self.scratch);
        self.* = undefined;
    }

    /// Registers `source` as the route at `specifier` and queues one request
    /// for it, as the server's request begin would.
    fn dispatch(self: *SocketFullWorker, request_id: u64, source: []const u8, specifier: []const u8) !void {
        const route_specifier = try rt.routeSpecifier(std.testing.allocator, specifier);
        defer std.testing.allocator.free(route_specifier);
        const route_index = try rt.registerRoute(&self.runtime, route_specifier, source);
        const request: rt.RequestParts = .{ .path = specifier };
        var dispatch_work = try initDispatchWork(std.testing.allocator, .{
            .request_id = request_id,
            .route_index = route_index,
            .request = request,
        });
        defer dispatch_work.deinit();
        try rt.enqueueIngressRoute(&self.runtime, &dispatch_work, 3, request);
    }

    /// Fails when the worker published any completion.
    fn expectNoCompletion(self: *SocketFullWorker) !void {
        var records: [worker_shared_page.COMPLETION_RING_COUNT]worker_shared_page.WorkerCompletionRecord = undefined;
        try std.testing.expectEqual(@as(usize, 0), try self.completion_fixture.view.drainWorkerCompletions(&records));
    }

    /// Arms the backend as the loop does before it waits, and fails unless
    /// that queued the poll for room in the control socket.
    fn expectWritablePollArmed(self: *SocketFullWorker) !void {
        try self.backend.arm(&self.runtime);
        try std.testing.expect(self.backend.control_writable_poll_armed);
    }

    /// Waits for the backend to report the control socket writable, then
    /// flushes the outboxes, as the loop does on that event
    /// (`scheduler/loop.zig`).
    fn flushWhenWritable(self: *SocketFullWorker) !void {
        var round: usize = 0;
        while (round < max_wait_rounds) : (round += 1) {
            try self.backend.arm(&self.runtime);
            var events: [8]uring_backend.Event = undefined;
            const ready = try self.backend.drain(&self.runtime, &events);
            for (events[0..ready]) |event| {
                switch (event) {
                    .control_writable => {
                        try self.runtime.flushPendingIngressResponses();
                        return;
                    },
                    .wakeup_ready => self.runtime.drainWakeup(),
                    else => {},
                }
            }
            std.Thread.sleep(std.time.ns_per_ms);
        }
        return error.TestUnexpectedResult;
    }

    /// Plays the server until `request_id` finishes: reads what the socket
    /// holds into `response`, then lets the worker flush once the socket
    /// has room.
    fn serveUntilFinished(self: *SocketFullWorker, response: *ReadResponse, request_id: u64) !void {
        var round: usize = 0;
        while (self.runtime.requests.active.contains(request_id)) : (round += 1) {
            if (round == max_wait_rounds)
                return error.TestUnexpectedResult;
            try response.readAvailable(self);
            try self.flushWhenWritable();
        }
    }
};

/// What a test, playing the server, read of one response. A second head
/// fails the read, since it would answer the request twice.
const ReadResponse = struct {
    status: ?u16 = null,
    body: std.ArrayList(u8) = .empty,
    reset_code: ?u32 = null,
    ended: bool = false,

    fn deinit(self: *ReadResponse) void {
        self.body.deinit(std.testing.allocator);
        self.* = undefined;
    }

    /// Reads the packets the server's end holds now.
    fn readAvailable(self: *ReadResponse, fixture: *SocketFullWorker) !void {
        while (try socketReadable(fixture.control_pair[1], 0))
            try self.readPacket(fixture);
    }

    /// Reads packets until the response ends or resets. The worker sent them
    /// all already, so a packet that does not arrive within a second fails.
    fn readUntilEnd(self: *ReadResponse, fixture: *SocketFullWorker) !void {
        while (!self.ended) {
            if (!try socketReadable(fixture.control_pair[1], 1000))
                return error.TestUnexpectedResult;
            try self.readPacket(fixture);
        }
    }

    fn readPacket(self: *ReadResponse, fixture: *SocketFullWorker) !void {
        var raw_packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, fixture.control_pair[1], fixture.scratch);
        const readers: ipc.ingress_channel.SharedPayloadReaders = .{ .worker_to_server = &fixture.server_payload };
        if (ipc.ingress_channel.isDescriptorBatchPacket(raw_packet.bytes)) {
            var batch = try ipc.ingress_channel.decodeReceivedBatchPacketWithSharedPayload(std.testing.allocator, &raw_packet, readers);
            defer batch.deinit();
            for (batch.items) |item|
                try self.take(item.descriptor, item.payload);
        } else {
            var single = try ipc.ingress_channel.decodeReceivedPacketWithSharedPayload(std.testing.allocator, &raw_packet, readers);
            defer single.deinit();
            try self.take(single.descriptor, single.payload);
        }
    }

    fn take(self: *ReadResponse, descriptor: ipc.ingress_channel.Descriptor, payload: []const u8) !void {
        try std.testing.expect(!self.ended);
        if (descriptor.op == @intFromEnum(ipc.ingress_channel.Op.response_head)) {
            try std.testing.expect(self.status == null);
            var head = try ipc.ingress_channel.decodeResponseHead(std.testing.allocator, payload);
            defer head.deinit();
            self.status = head.status;
            self.ended = descriptor.hasFlag(ipc.ingress_channel.flags.end_stream);
            return;
        }
        try std.testing.expect(self.status != null);
        if (descriptor.op == @intFromEnum(ipc.ingress_channel.Op.response_chunk)) {
            try self.body.appendSlice(std.testing.allocator, payload);
            self.ended = descriptor.hasFlag(ipc.ingress_channel.flags.end_stream);
            return;
        }
        if (descriptor.op == @intFromEnum(ipc.ingress_channel.Op.response_end)) {
            self.ended = true;
            return;
        }
        if (descriptor.op == @intFromEnum(ipc.ingress_channel.Op.response_reset)) {
            self.reset_code = descriptor.aux;
            self.ended = true;
            return;
        }
        return error.TestUnexpectedResult;
    }
};

/// Runs the runtime's collectors and its ready work, as the harness's
/// `executeUntilRequestDone` does, until the response of `request_id` waits
/// in its outbox, and returns the request.
fn runUntilParked(runtime: *worker.Runtime, request_id: u64) !*worker_request.context.RequestContext {
    var round: usize = 0;
    while (round < max_wait_rounds) : (round += 1) {
        if (runtime.requests.active.get(request_id)) |request_ctx| {
            if (!request_ctx.response_outbox.isEmpty())
                return request_ctx;
        }
        _ = try runtime.collectEgressGatewayPacketsBounded(64);
        runtime.collectModuleSettlements();
        try runtime.collectCompletedCryptoJobs();
        try runtime.collectCompletedFetches();
        try runtime.collectReadyFetchBodies();
        try runtime.collectDueTimers();
        try runtime.collectReadyImmediates();
        try runtime.collectDueRequestDeadlines();
        if (runtime.scheduler.ready_queue.pop()) |item| {
            try worker.testing.executeWorkItem(runtime, item);
            continue;
        }
        std.Thread.sleep(std.time.ns_per_ms);
    }
    return error.TestUnexpectedResult;
}

/// Sends filler packets on `worker_fd` until a send would block, and returns
/// how many went out.
fn fillSendBuffer(worker_fd: std.posix.fd_t) !usize {
    const filler: [filler_packet_bytes]u8 = @splat(filler_byte);
    var count: usize = 0;
    while (count < max_filler_packets) : (count += 1) {
        _ = std.posix.send(worker_fd, &filler, std.posix.MSG.NOSIGNAL) catch |err| switch (err) {
            error.WouldBlock => return count,
            else => return err,
        };
    }
    return error.TestUnexpectedResult;
}

/// Reads the filler packets `server_fd` holds and returns how many there
/// were.
fn drainFiller(server_fd: std.posix.fd_t) !usize {
    var packet: [filler_packet_bytes + 1]u8 = undefined;
    var count: usize = 0;
    while (count < max_filler_packets) : (count += 1) {
        if (!try socketReadable(server_fd, 0))
            return count;
        const received = try std.posix.recv(server_fd, &packet, 0);
        try std.testing.expectEqual(filler_packet_bytes, received);
        try std.testing.expect(std.mem.allEqual(u8, packet[0..received], filler_byte));
    }
    return error.TestUnexpectedResult;
}

/// Whether `fd` holds a packet to read within `timeout_ms`.
fn socketReadable(fd: std.posix.fd_t, timeout_ms: i32) !bool {
    var poll_fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    if (try std.posix.poll(&poll_fds, timeout_ms) == 0)
        return false;
    return (poll_fds[0].revents & std.posix.POLL.IN) != 0;
}

fn closePair(pair: [2]std.posix.fd_t) void {
    std.posix.close(pair[0]);
    std.posix.close(pair[1]);
}

/// Checks a body against the alphabet the handler of `alphabet_source`
/// repeats.
fn expectAlphabetBody(body: []const u8) !void {
    try std.testing.expectEqual(alphabet_body_len, body.len);
    for (body, 0..) |byte, index| {
        const expected: u8 = @intCast('a' + index % 26);
        if (byte != expected) {
            std.debug.print("body byte {d} is {d}, expected {d}\n", .{ index, byte, expected });
            return error.TestUnexpectedResult;
        }
    }
}

/// Checks bytes from the start of the body of `parts_source`, where part
/// `index` holds `index + 1`.
fn expectPartsBytes(bytes: []const u8) !void {
    for (bytes, 0..) |byte, index| {
        const expected: u8 = @intCast(index / part_bytes + 1);
        if (byte != expected) {
            std.debug.print("body byte {d} is {d}, expected {d}\n", .{ index, byte, expected });
            return error.TestUnexpectedResult;
        }
    }
}

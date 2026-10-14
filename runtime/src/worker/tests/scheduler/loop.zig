//! Covers how the worker's loop reads its control socket before it runs
//! work (`scheduler/loop.zig:run`): every packet the socket holds when it
//! turns readable is read first, so a client reset that waited with its
//! request's begin runs none of that request's JavaScript, and a body whose
//! packets waited behind its begin is whole when the request's item runs.
//! Each test queues the server's packets, then runs the real loop on this
//! thread while a second thread plays the server: it reads the responses and
//! hangs up, which stops the loop. Runs in `worker-test`; the loop's wait and
//! the scheduler's structures are covered by `worker/tests/scheduler.zig`.

const std = @import("std");
const support = @import("bindings_support");
const bindings = @import("collo_bindings");
const fd_mod = @import("collo_os").fd;
const ipc = @import("collo_ipc");
const worker = @import("collo_worker");
const rt = @import("collo_test_harness");

test "a client reset that waits with its request's begin runs none of the request's JavaScript, which ends client-closed" {
    var fixture: LoopWorker = undefined;
    try fixture.init();
    defer fixture.deinit();

    // A GET reports how many requests ran the handler's side effect.
    const source =
        \\globalThis.handled = 0;
        \\export default function handle(request) {
        \\    if (request.method === "GET") return new Response(String(globalThis.handled));
        \\    globalThis.handled += 1;
        \\    return new Response("handled");
        \\}
    ;
    const route_index = try fixture.registerRoute("/reset-with-begin.js", source);
    const reset_request: rt.RequestParts = .{ .method = "DELETE", .path = "/reset-with-begin.js" };
    var reset_dispatch = try dispatchWork(201, route_index, reset_request);
    defer reset_dispatch.deinit();
    const probe_request: rt.RequestParts = .{ .path = "/reset-with-begin.js" };
    var probe_dispatch = try dispatchWork(202, route_index, probe_request);
    defer probe_dispatch.deinit();

    // The client resets the stream right after sending it, and both packets
    // wait in the socket when the loop first looks.
    const stream_id: u32 = 5;
    try rt.sendIngressRoute(fixture.control_pair[1], &reset_dispatch, stream_id, reset_request);
    var scratch: [ipc.max_message_bytes]u8 = undefined;
    const cancel_code: u32 = 0x8;
    try ipc.ingress_channel.sendDescriptor(
        fixture.control_pair[1],
        ipc.ingress_channel.Descriptor.requestReset(identityOf(&reset_dispatch), stream_id, cancel_code),
        &scratch,
    );

    var server: LoopServer = .{
        .server_fd = fixture.control_pair[1],
        .first_id = 201,
        .probe = .{ .dispatch = &probe_dispatch, .request = probe_request, .stream_id = 7 },
    };
    try fixture.runLoop(&server);

    const done = server.first.done orelse return error.RequestDoneMissing;
    try std.testing.expectEqual(ipc.RequestDoneStatus.client_closed, done.status);
    try std.testing.expectEqual(@as(u16, 499), done.http_status);
    try std.testing.expectEqual(@as(usize, 0), server.first.response_descriptors);
    try std.testing.expectEqualStrings("0", server.second.bodyBytes());
}

test "a POST whose body packets wait behind its begin is answered in one item and one packet, the body whole when its handler runs" {
    var fixture: LoopWorker = undefined;
    try fixture.init();
    defer fixture.deinit();

    // Hono's shape: the handler awaits the body, answers JSON, and a
    // middleware that sets a header afterwards rebuilds the response around
    // the first one's body stream.
    const source =
        \\export default async function handle(request) {
        \\    const order = await request.json();
        \\    const inner = new Response(JSON.stringify({ total: order.qty * 2 }), {
        \\        headers: { "content-type": "application/json" },
        \\    });
        \\    await null;
        \\    const outer = new Response(inner.body, inner);
        \\    outer.headers.set("x-tenant", "t1");
        \\    return outer;
        \\}
    ;
    const route_index = try fixture.registerRoute("/body-behind-begin.js", source);
    // The body reaches the worker one DATA frame per packet, as a client that
    // writes it in pieces sends it.
    const body_pieces = [_][]const u8{ "{", "\"q", "ty", "\"", ":", "2", "1", "}" };
    const body_bytes = comptime blk: {
        var total: usize = 0;
        for (body_pieces) |piece| total += piece.len;
        break :blk total;
    };
    const request: rt.RequestParts = .{
        .method = "POST",
        .path = "/body-behind-begin.js",
        .headers = &[_]ipc.RequestHeader{
            .{ .name = "host", .value = "demo.test" },
            .{ .name = "content-length", .value = std.fmt.comptimePrint("{d}", .{body_bytes}) },
        },
        .body_framing = .ingress_channel,
        .body_end_stream = false,
    };
    var dispatch = try dispatchWork(211, route_index, request);
    defer dispatch.deinit();

    const stream_id: u32 = 9;
    try rt.sendIngressRoute(fixture.control_pair[1], &dispatch, stream_id, request);
    var scratch: [ipc.max_message_bytes]u8 = undefined;
    for (body_pieces, 0..) |piece, index| {
        const descriptor = ipc.ingress_channel.Descriptor.requestBodyChunk(
            identityOf(&dispatch),
            stream_id,
            0,
            @intCast(piece.len),
            index + 1 == body_pieces.len,
        );
        try ipc.ingress_channel.sendDescriptorPayload(fixture.control_pair[1], descriptor, piece, &scratch);
    }

    var server: LoopServer = .{ .server_fd = fixture.control_pair[1], .first_id = 211 };
    const reads_before = fixture.cpu_reads;
    try fixture.runLoop(&server);

    // One window, the request's item: its opening and the finish's fold. A
    // body read or a completion left to items of their own would open more.
    try std.testing.expectEqual(@as(u64, 2), fixture.cpu_reads - reads_before);
    const done = server.first.done orelse return error.RequestDoneMissing;
    try std.testing.expectEqual(ipc.RequestDoneStatus.ok, done.status);
    try std.testing.expectEqual(@as(usize, 1), server.first.packets);
    try std.testing.expectEqualStrings("{\"total\":42}", server.first.bodyBytes());
}

/// How long the server's thread waits for each packet before it fails the
/// test and hangs up, which stops a loop that never answers.
const read_timeout_ms: i32 = 2000;

/// An in-process worker whose control socket's worker end does not block,
/// as `zygote/child_boot.zig` leaves a real worker's, on a fake monotonic
/// clock that never moves, so no deadline or idle work passes during a test,
/// and a CPU clock that counts its readings.
const LoopWorker = struct {
    now_mono_ns: u64,
    cpu_reads: u64,
    control_pair: [2]std.posix.fd_t,
    vm: bindings.Vm,
    completion_fixture: rt.CompletionFixture,
    runtime: worker.Runtime,

    fn init(self: *LoopWorker) !void {
        self.now_mono_ns = 0;
        self.cpu_reads = 0;
        self.control_pair = try rt.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
        errdefer closePair(self.control_pair);
        try fd_mod.setNonblocking(self.control_pair[0], true);
        self.vm = try support.createVm();
        errdefer self.vm.deinit();
        self.completion_fixture = try rt.CompletionFixture.init();
        errdefer self.completion_fixture.deinit();
        self.runtime = try worker.Runtime.init(
            std.testing.allocator,
            &self.vm,
            self.control_pair[0],
            &self.completion_fixture.view,
            try rt.createCompletionEventfd(),
            worker.RuntimeOptions{
                .clock = .{ .ctx = &self.now_mono_ns, .now_fn = rt.fakeNow },
                .cpu_clock = .{ .ctx = &self.cpu_reads, .now_fn = countCpuRead },
            },
        );
        errdefer self.runtime.deinit();
        try self.runtime.attachHostRuntime();
    }

    fn deinit(self: *LoopWorker) void {
        self.runtime.deinit();
        self.completion_fixture.deinit();
        self.vm.deinit();
        closePair(self.control_pair);
        self.* = undefined;
    }

    fn registerRoute(self: *LoopWorker, specifier: []const u8, source: []const u8) !u16 {
        const route_specifier = try rt.routeSpecifier(std.testing.allocator, specifier);
        defer std.testing.allocator.free(route_specifier);
        return rt.registerRoute(&self.runtime, route_specifier, source);
    }

    /// Runs the loop on this thread while `server` plays the server's end on
    /// a thread of its own, until the server hangs up.
    fn runLoop(self: *LoopWorker, server: *LoopServer) !void {
        const thread = try std.Thread.spawn(.{}, LoopServer.run, .{server});
        const loop_result = worker.testing.scheduler.loop.run(&self.runtime);
        thread.join();
        try loop_result;
        try server.result;
        if (server.shutdown_error) |err|
            return err;
    }
};

/// The server's end of the control socket during a loop test, on a thread of
/// its own: it reads the request `first_id` up to its `request_done`, then
/// sends `probe` and reads it the same way when the test has one, and hangs
/// up whatever it found.
const LoopServer = struct {
    server_fd: std.posix.fd_t,
    first_id: u64,
    probe: ?Probe = null,
    first: ReadRequest = .{},
    second: ReadRequest = .{},
    result: anyerror!void = {},
    shutdown_error: ?anyerror = null,

    const Probe = struct {
        dispatch: *ipc.DispatchWork,
        request: rt.RequestParts,
        stream_id: u32,
    };

    fn run(self: *LoopServer) void {
        self.result = self.serve();
        std.posix.shutdown(self.server_fd, .both) catch |err| {
            self.shutdown_error = err;
        };
    }

    fn serve(self: *LoopServer) !void {
        try readRequest(self.server_fd, self.first_id, &self.first);
        const probe = self.probe orelse return;
        try rt.sendIngressRoute(self.server_fd, probe.dispatch, probe.stream_id, probe.request);
        try readRequest(self.server_fd, probe.dispatch.request_id, &self.second);
    }
};

/// What the server read of one request: the packets up to the one that held
/// its `request_done`, the request's descriptors before that `request_done`,
/// the inline bytes of its response chunks, and the `request_done`.
const ReadRequest = struct {
    packets: usize = 0,
    response_descriptors: usize = 0,
    body: [body_capacity]u8 = undefined,
    body_len: usize = 0,
    done: ?ipc.RequestDone = null,

    const body_capacity: usize = 64;

    fn bodyBytes(self: *const ReadRequest) []const u8 {
        return self.body[0..self.body_len];
    }

    fn take(
        self: *ReadRequest,
        request_id: u64,
        descriptor: ipc.ingress_channel.Descriptor,
        payload: []const u8,
    ) !void {
        if (descriptor.request_id != request_id)
            return;
        if (descriptor.op == @intFromEnum(ipc.ingress_channel.Op.request_done)) {
            self.done = try ipc.ingress_channel.decodeRequestDone(payload);
            return;
        }
        self.response_descriptors += 1;
        if (descriptor.op != @intFromEnum(ipc.ingress_channel.Op.response_chunk))
            return;
        if (payload.len > body_capacity - self.body_len)
            return error.TestUnexpectedResult;
        @memcpy(self.body[self.body_len..][0..payload.len], payload);
        self.body_len += payload.len;
    }
};

/// Reads the server's end of the control socket up to the `request_done` of
/// `request_id` into `out`. Every payload is inline.
fn readRequest(server_fd: std.posix.fd_t, request_id: u64, out: *ReadRequest) !void {
    const scratch = try std.testing.allocator.alloc(u8, ipc.max_message_bytes);
    defer std.testing.allocator.free(scratch);
    while (out.done == null) {
        var polls = [_]std.posix.pollfd{.{ .fd = server_fd, .events = std.posix.POLL.IN, .revents = 0 }};
        if (try std.posix.poll(&polls, read_timeout_ms) == 0)
            return error.RequestDoneMissing;
        var packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, server_fd, scratch);
        out.packets += 1;
        if (ipc.ingress_channel.isDescriptorBatchPacket(packet.bytes)) {
            var batch = try ipc.ingress_channel.decodeReceivedBatchPacket(std.testing.allocator, &packet);
            defer batch.deinit();
            for (batch.items) |item|
                try out.take(request_id, item.descriptor, item.payload);
        } else {
            var single = try ipc.ingress_channel.decodeReceivedPacket(std.testing.allocator, &packet);
            defer single.deinit();
            try out.take(request_id, single.descriptor, single.payload);
        }
    }
}

/// A dispatch of `request` to the route at `route_index` whose deadline lies
/// far past the fake clock's instant, so the loop's wait never wakes for it.
fn dispatchWork(request_id: u64, route_index: u16, request: rt.RequestParts) !ipc.DispatchWork {
    return rt.initDispatchWork(std.testing.allocator, .{
        .request_id = request_id,
        .route_index = route_index,
        .deadline_monotonic_ns = std.time.ns_per_hour,
        .request = request,
    });
}

fn identityOf(dispatch: *const ipc.DispatchWork) ipc.ingress_channel.RequestIdentity {
    return .{
        .request_id = dispatch.request_id,
        .request_generation = dispatch.request_generation,
        .request_lane_id = dispatch.request_lane_id,
        .request_slot = dispatch.request_slot,
    };
}

/// A thread CPU clock that counts its readings, each a microsecond later.
fn countCpuRead(ctx: ?*anyopaque) u64 {
    const reads: *u64 = @ptrCast(@alignCast(ctx.?));
    reads.* += 1;
    return reads.* * std.time.ns_per_us;
}

fn closePair(pair: [2]std.posix.fd_t) void {
    std.posix.close(pair[0]);
    std.posix.close(pair[1]);
}

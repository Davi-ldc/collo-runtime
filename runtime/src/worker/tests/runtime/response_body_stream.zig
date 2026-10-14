//! Covers a response whose body is a ReadableStream the handler built: the
//! head goes out before the stream yields anything, each chunk follows while
//! the stream is still open, and the request finishes, with a `request_done`
//! that counts every byte, only when the stream closes. A TransformStream's readable
//! streams what the handler writes after it returned. A stream that errors,
//! or yields a chunk that is not bytes, a string included, resets the
//! client's stream instead of ending it, and a client's reset cancels the
//! stream with the reset as its reason. The tests play the server on the
//! control socket and move the runtime's fake clock, so a source that waits
//! on a timer yields exactly when the test says. Runs in `worker-test`; the
//! bridge's half (extraction, reads, chunks, cancel) is covered in
//! `bindings-test` (`bindings/tests/response_extract.zig`), and a real
//! client over the server in `local-e2e`.

const std = @import("std");
const support = @import("bindings_support");
const bindings = @import("collo_bindings");
const h2 = @import("collo_http").http2;
const ipc = @import("collo_ipc");
const worker = @import("collo_worker");
const rt = @import("collo_test_harness");

/// The interval at which the sources below yield, on the fake clock.
const source_interval_ns: u64 = std.time.ns_per_s;

/// Far beyond any source's interval, so no request here meets its deadline.
const request_deadline_ns: u64 = 60 * std.time.ns_per_s;

/// The most work items or idle clock steps one wait runs before it fails.
const max_rounds: usize = 1000;

test "a handler's ReadableStream sends its head first and each chunk as the stream yields it, and the request finishes when it closes" {
    // A server-sent events stream: one event at once, a second one interval
    // later, and the close one more interval after that. With no high-water
    // mark the source is pulled only for a read, so each event waits for the
    // one before it to go out.
    const source =
        \\export default function handler() {
        \\    const encoder = new TextEncoder();
        \\    let pulls = 0;
        \\    return new Response(new ReadableStream({
        \\        start(controller) {
        \\            controller.enqueue(encoder.encode("data: one\n\n"));
        \\        },
        \\        pull(controller) {
        \\            return new Promise((resolve) => setTimeout(() => {
        \\                pulls += 1;
        \\                if (pulls === 1)
        \\                    controller.enqueue(encoder.encode("data: two\n\n"));
        \\                else
        \\                    controller.close();
        \\                resolve();
        \\            }, 1000));
        \\        },
        \\    }, { highWaterMark: 0 }), { headers: { "content-type": "text/event-stream" } });
        \\}
    ;
    var fixture: StreamFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const route_index = try fixture.registerRoute(source, "/sse.js");

    try fixture.dispatch(route_index, 901, "/events");
    try fixture.runReady();
    var response: ReceivedResponse = .{};
    defer response.deinit();
    try response.readAvailable(&fixture);
    try std.testing.expectEqual(@as(?u16, 200), response.status);
    try std.testing.expectEqualStrings("data: one\n\n", response.body.items);
    try std.testing.expect(!response.ended);
    try std.testing.expect(fixture.runtime.requests.active.contains(901));

    try fixture.advance(source_interval_ns);
    try response.readAvailable(&fixture);
    try std.testing.expectEqualStrings("data: one\n\ndata: two\n\n", response.body.items);
    try std.testing.expect(!response.ended);
    try std.testing.expect(fixture.runtime.requests.active.contains(901));

    try fixture.advance(source_interval_ns);
    try std.testing.expect(!fixture.runtime.requests.active.contains(901));
    try response.readAvailable(&fixture);
    try std.testing.expect(response.ended);
    try std.testing.expect(response.reset_code == null);
    try std.testing.expectEqualStrings("data: one\n\ndata: two\n\n", response.body.items);

    const done = response.done orelse return error.RequestDoneMissing;
    try std.testing.expectEqual(ipc.RequestDoneStatus.ok, done.status);
    try std.testing.expectEqual(@as(u16, 200), done.http_status);
    // The packet goes out when the stream closes, so it counts both events.
    try std.testing.expectEqual(@as(u64, "data: one\n\ndata: two\n\n".len), done.client_served_bytes);
}

test "a TransformStream's readable streams what the handler writes after it returned" {
    const source =
        \\export default function handler() {
        \\    const { readable, writable } = new TransformStream();
        \\    const writer = writable.getWriter();
        \\    const encoder = new TextEncoder();
        \\    (async () => {
        \\        await writer.write(encoder.encode("first "));
        \\        await new Promise((resolve) => setTimeout(resolve, 1000));
        \\        await writer.write(encoder.encode("second"));
        \\        await writer.close();
        \\    })();
        \\    return new Response(readable, { status: 201 });
        \\}
    ;
    var fixture: StreamFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const route_index = try fixture.registerRoute(source, "/transform.js");

    try fixture.dispatch(route_index, 902, "/transform");
    try fixture.runReady();
    var response: ReceivedResponse = .{};
    defer response.deinit();
    try response.readAvailable(&fixture);
    try std.testing.expectEqual(@as(?u16, 201), response.status);
    try std.testing.expectEqualStrings("first ", response.body.items);
    try std.testing.expect(!response.ended);

    try fixture.advance(source_interval_ns);
    try std.testing.expect(!fixture.runtime.requests.active.contains(902));
    try response.readAvailable(&fixture);
    try std.testing.expect(response.ended);
    try std.testing.expect(response.reset_code == null);
    try std.testing.expectEqualStrings("first second", response.body.items);

    const done = response.done orelse return error.RequestDoneMissing;
    try std.testing.expectEqual(ipc.RequestDoneStatus.ok, done.status);
    try std.testing.expectEqual(@as(u16, 201), done.http_status);
}

test "a stream that errors after the head resets the client's stream instead of ending it" {
    const source =
        \\export default function handler() {
        \\    return new Response(new ReadableStream({
        \\        start(controller) {
        \\            controller.enqueue(new TextEncoder().encode("before"));
        \\        },
        \\        pull(controller) {
        \\            controller.error(new Error("source failed"));
        \\        },
        \\    }, { highWaterMark: 0 }));
        \\}
    ;
    var fixture: StreamFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const route_index = try fixture.registerRoute(source, "/errors.js");

    try fixture.dispatch(route_index, 903, "/errors");
    try fixture.runReady();
    try std.testing.expect(!fixture.runtime.requests.active.contains(903));
    try std.testing.expect(fixture.runtime.core.running);

    var response: ReceivedResponse = .{};
    defer response.deinit();
    try response.readAvailable(&fixture);
    try std.testing.expectEqual(@as(?u16, 200), response.status);
    try std.testing.expectEqualStrings("before", response.body.items);
    try std.testing.expectEqual(@as(?u32, @intFromEnum(h2.ErrorCode.internal_error)), response.reset_code);

    const done = response.done orelse return error.RequestDoneMissing;
    try std.testing.expectEqual(ipc.RequestDoneStatus.js_exception, done.status);
    try std.testing.expectEqual(@as(u16, 200), done.http_status);
}

// The Fetch Standard reads a response body's stream as bytes only, so a
// string fails like any other value that is not an ArrayBuffer or an
// ArrayBufferView.
test "a string chunk resets the client's stream after the head and cancels the stream with a TypeError" {
    const source =
        \\export default function handler(request) {
        \\    if (new URL(request.url).pathname === "/reason")
        \\        return new Response(String(globalThis.cancelReason));
        \\    return new Response(new ReadableStream({
        \\        start(controller) {
        \\            controller.enqueue("text");
        \\        },
        \\        cancel(reason) {
        \\            globalThis.cancelReason = `${reason.name}: ${reason.message}`;
        \\        },
        \\    }));
        \\}
    ;
    var fixture: StreamFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const route_index = try fixture.registerRoute(source, "/not-bytes.js");

    try fixture.dispatch(route_index, 904, "/not-bytes");
    try fixture.runReady();
    var response: ReceivedResponse = .{};
    defer response.deinit();
    try response.readAvailable(&fixture);
    try std.testing.expectEqual(@as(?u16, 200), response.status);
    try std.testing.expectEqual(@as(usize, 0), response.body.items.len);
    try std.testing.expectEqual(@as(?u32, @intFromEnum(h2.ErrorCode.internal_error)), response.reset_code);
    const done = response.done orelse return error.RequestDoneMissing;
    try std.testing.expectEqual(ipc.RequestDoneStatus.js_exception, done.status);

    // The reason the stream is canceled with names the chunk as the error the read threw does.
    try fixture.expectReason(route_index, 905, "TypeError: ReadableStream chunks must be an ArrayBuffer or an ArrayBufferView");
}

test "a client's reset cancels the response stream with the reset as its reason" {
    // The source yields one chunk and then nothing, so the response stays
    // open until the client goes away.
    const source =
        \\export default function handler(request) {
        \\    if (new URL(request.url).pathname === "/reason")
        \\        return new Response(String(globalThis.cancelReason));
        \\    return new Response(new ReadableStream({
        \\        start(controller) {
        \\            controller.enqueue(new TextEncoder().encode("partial"));
        \\        },
        \\        pull() {
        \\            return new Promise(() => {});
        \\        },
        \\        cancel(reason) {
        \\            globalThis.cancelReason = `${reason.name}: ${reason.message}`;
        \\        },
        \\    }, { highWaterMark: 0 }));
        \\}
    ;
    var fixture: StreamFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const route_index = try fixture.registerRoute(source, "/reset.js");

    try fixture.dispatch(route_index, 906, "/reset");
    try fixture.runReady();
    var response: ReceivedResponse = .{};
    defer response.deinit();
    try response.readAvailable(&fixture);
    try std.testing.expectEqualStrings("partial", response.body.items);
    try std.testing.expect(!response.ended);
    try std.testing.expect(fixture.runtime.requests.active.contains(906));

    try fixture.resetStream(906);
    try fixture.runReady();
    try std.testing.expect(!fixture.runtime.requests.active.contains(906));
    // Only the `request_done` follows the reset: the stream is gone on the
    // server's side, so it gets no end and no reset.
    try response.readAvailable(&fixture);
    try std.testing.expectEqualStrings("partial", response.body.items);
    try std.testing.expect(!response.ended);
    const done = response.done orelse return error.RequestDoneMissing;
    try std.testing.expectEqual(ipc.RequestDoneStatus.client_closed, done.status);

    try fixture.expectReason(route_index, 907, "AbortError: The client reset the response stream");
}

/// A worker runtime on a control socket whose other end the test reads as
/// the server, with a fake clock the test moves. Responses here are small
/// enough to go inline, so no payload ring is mapped.
const StreamFixture = struct {
    now_mono_ns: u64,
    control_pair: [2]std.posix.fd_t,
    scratch: []u8,
    vm: bindings.Vm,
    completion_fixture: rt.CompletionFixture,
    runtime: worker.Runtime,

    /// The stream id every dispatch here names, which a reset must repeat.
    const stream_id: u32 = 3;

    fn init(self: *StreamFixture) !void {
        self.now_mono_ns = 0;
        self.scratch = try std.testing.allocator.alloc(u8, ipc.max_message_bytes);
        errdefer std.testing.allocator.free(self.scratch);
        self.control_pair = try rt.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
        errdefer closePair(self.control_pair);
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
            .{ .ctx = &self.now_mono_ns, .now_fn = rt.fakeNow },
        );
        errdefer self.runtime.deinit();
        try self.runtime.attachHostRuntime();
    }

    fn deinit(self: *StreamFixture) void {
        self.runtime.deinit();
        self.completion_fixture.deinit();
        self.vm.deinit();
        closePair(self.control_pair);
        std.testing.allocator.free(self.scratch);
        self.* = undefined;
    }

    fn registerRoute(self: *StreamFixture, source: []const u8, specifier: []const u8) !u16 {
        const route_specifier = try rt.routeSpecifier(std.testing.allocator, specifier);
        defer std.testing.allocator.free(route_specifier);
        return rt.registerRoute(&self.runtime, route_specifier, source);
    }

    /// Queues request `request_id` for `path` on the route at `route_index`,
    /// as the server's request begin would.
    fn dispatch(self: *StreamFixture, route_index: u16, request_id: u64, path: []const u8) !void {
        const request: rt.RequestParts = .{ .path = path };
        var dispatch_work = try rt.initDispatchWork(std.testing.allocator, .{
            .request_id = request_id,
            .route_index = route_index,
            .deadline_monotonic_ns = self.now_mono_ns + request_deadline_ns,
            .request = request,
        });
        defer dispatch_work.deinit();
        try rt.enqueueIngressRoute(&self.runtime, &dispatch_work, stream_id, request);
    }

    /// Sends the client's reset of request `request_id`'s stream, as the
    /// server does when the client resets it.
    fn resetStream(self: *StreamFixture, request_id: u64) !void {
        const identity: ipc.ingress_channel.RequestIdentity = .{
            .request_id = request_id,
            .request_generation = 1,
            .request_lane_id = 0,
            .request_slot = 0,
        };
        try self.runtime.enqueueIngressDescriptor(.{
            .allocator = std.testing.allocator,
            .descriptor = ipc.ingress_channel.Descriptor.requestReset(
                identity,
                stream_id,
                @intFromEnum(h2.ErrorCode.cancel),
            ),
            .payload = try std.testing.allocator.alloc(u8, 0),
        });
    }

    /// Runs what is ready, as the loop's passes do, without moving the clock,
    /// until nothing is.
    fn runReady(self: *StreamFixture) !void {
        var round: usize = 0;
        while (round < max_rounds) : (round += 1) {
            self.runtime.drainReadyBacklog();
            self.runtime.collectReadyIngressRequests();
            try self.runtime.collectDueTimers();
            try self.runtime.collectReadyImmediates();
            try self.runtime.collectDueRequestDeadlines();
            const item = self.runtime.scheduler.ready_queue.pop() orelse return;
            try worker.testing.executeWorkItem(&self.runtime, item);
        }
        return error.TestUnexpectedResult;
    }

    /// Moves the fake clock by `ns` and runs what became ready.
    fn advance(self: *StreamFixture, ns: u64) !void {
        self.now_mono_ns += ns;
        try self.runReady();
    }

    /// Runs request `request_id` for "/reason" on the route at `route_index`,
    /// whose handler answers with the reason its last stream was cancelled
    /// with, and expects `expected`.
    fn expectReason(self: *StreamFixture, route_index: u16, request_id: u64, expected: []const u8) !void {
        try self.dispatch(route_index, request_id, "/reason");
        try self.runReady();
        try std.testing.expect(!self.runtime.requests.active.contains(request_id));
        var response: ReceivedResponse = .{};
        defer response.deinit();
        try response.readAvailable(self);
        try std.testing.expect(response.ended);
        try std.testing.expectEqualStrings(expected, response.body.items);
    }
};

/// What the test, playing the server, read of one response from the
/// control socket, up to its `request_done`. A second head fails the read,
/// since it would answer the request twice, and so does any descriptor after
/// the `request_done`, which the worker sends last.
const ReceivedResponse = struct {
    status: ?u16 = null,
    body: std.ArrayList(u8) = .empty,
    reset_code: ?u32 = null,
    ended: bool = false,
    done: ?ipc.RequestDone = null,

    fn deinit(self: *ReceivedResponse) void {
        self.body.deinit(std.testing.allocator);
        self.* = undefined;
    }

    /// Reads every packet the server's end holds now.
    fn readAvailable(self: *ReceivedResponse, fixture: *StreamFixture) !void {
        while (try socketReadable(fixture.control_pair[1])) {
            var packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, fixture.control_pair[1], fixture.scratch);
            if (ipc.ingress_channel.isDescriptorBatchPacket(packet.bytes)) {
                var batch = try ipc.ingress_channel.decodeReceivedBatchPacket(std.testing.allocator, &packet);
                defer batch.deinit();
                for (batch.items) |item|
                    try self.take(item.descriptor, item.payload);
            } else {
                var single = try ipc.ingress_channel.decodeReceivedPacket(std.testing.allocator, &packet);
                defer single.deinit();
                try self.take(single.descriptor, single.payload);
            }
        }
    }

    fn take(self: *ReceivedResponse, descriptor: ipc.ingress_channel.Descriptor, payload: []const u8) !void {
        try std.testing.expect(self.done == null);
        if (descriptor.op == @intFromEnum(ipc.ingress_channel.Op.request_done)) {
            self.done = try ipc.ingress_channel.decodeRequestDone(payload);
            return;
        }
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

fn socketReadable(fd: std.posix.fd_t) !bool {
    var poll_fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    if (try std.posix.poll(&poll_fds, 0) == 0)
        return false;
    return (poll_fds[0].revents & std.posix.POLL.IN) != 0;
}

fn closePair(pair: [2]std.posix.fd_t) void {
    std.posix.close(pair[0]);
    std.posix.close(pair[1]);
}

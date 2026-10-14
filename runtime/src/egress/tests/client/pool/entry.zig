//! Tests of one HTTP/2 pool entry over a wire in memory: the client preface
//! queued when the entry joins the pool, ahead of any stream or answer; an
//! oversized request head that fails alone while the entry it would have
//! shared keeps serving; and `Pool.readEntryEvent` handing over an event
//! before anything that can fail runs.
//!
//! The wire is a plain one marked h2, standing in for a TLS wire whose ALPN
//! chose h2: the pool reads and writes plaintext through either. Each test
//! copies the server's frames into the wire's receive buffer, as the data
//! driver does, and reads what the client queued from the wire's send queue.
//! A test skips when the kernel or its policy offers no restricted io_uring,
//! since the pool hands every wire back through the data driver. Entries
//! over real TLS origins are covered by integration.zig.

const std = @import("std");
const network_policy = @import("../network_policy.zig");
const test_support = @import("support.zig");
const pool = test_support.pool;
const data_io = test_support.data_io;
const transport = test_support.transport;
const http2 = test_support.http2;

/// RFC 9113 §3.4: the first bytes a client sends on a connection.
const client_connection_preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
const frame_header_len: usize = 9;
const frame_type_rst_stream: u8 = 0x3;
const frame_type_settings: u8 = 0x4;
const flag_ack: u8 = 0x1;

/// The server's SETTINGS, empty.
const server_settings_frame = "\x00\x00\x00\x04\x00\x00\x00\x00\x00";
/// A final head for stream 1 that carries `connection: keep-alive`, which
/// RFC 9113 §8.2.2 makes a malformed response: `:status: 200` (static entry
/// 8, 0x88), then the field as a literal the decoder does not index (0x00).
/// END_HEADERS (0x4) is set and END_STREAM is not.
const malformed_head_frame = "\x00\x00\x18\x01\x04\x00\x00\x00\x01" ++
    "\x88" ++ "\x00\x0aconnection\x0akeep-alive";

/// A pool with its HPACK scratch and data driver. It must not move once
/// `init` ran, since the pool borrows the scratch.
const Fixture = struct {
    driver: data_io.Driver,
    hpack_scratch: http2.HpackScratch,
    pool: pool.Pool,
    /// The far end of the socketpair under the entry's wire, which nothing
    /// reads or writes.
    peer: ?std.posix.fd_t,

    const config: transport.Config = .{ .network = network_policy.public_https };

    fn init(self: *Fixture) !void {
        self.driver = try test_support.initDataDriver();
        errdefer self.driver.deinit();
        self.hpack_scratch = try http2.HpackScratch.init(std.testing.allocator);
        self.pool = pool.Pool.init(std.testing.allocator, .{}, &self.hpack_scratch);
        self.peer = null;
    }

    fn deinit(self: *Fixture) void {
        while (self.pool.entries.items.len != 0)
            self.pool.removeEntry(self.pool.entries.items[0], &self.driver);
        self.pool.deinit();
        self.hpack_scratch.deinit(std.testing.allocator);
        self.driver.deinit();
        if (self.peer) |fd|
            std.posix.close(fd);
    }

    /// A plan for a hop to `url`, a public HTTPS origin no test resolves.
    fn prepare(url: []const u8, headers: []const transport.Header) !transport.RequestPlan {
        return transport.prepareRequest(std.testing.allocator, url, "GET", headers, config);
    }

    /// Adds an entry for `key` over a fresh wire, as a dial whose handshake
    /// chose h2 does.
    fn addEntry(self: *Fixture, key: *const transport.OriginKey) !*pool.Entry {
        std.debug.assert(self.peer == null);
        const fds = try socketPair();
        self.peer = fds[1];
        const wire = try transport.Wire.createPlain(std.testing.allocator, .{ .handle = fds[0] }, test_support.wire_buffer_bytes);
        wire.protocol = .h2;
        return self.pool.addEntry(key, wire, config, &self.driver);
    }

    fn start(self: *Fixture, plan: *const transport.RequestPlan) !pool.StartResult {
        return self.pool.startRequest(plan, "", config, &self.driver);
    }
};

fn socketPair() ![2]std.posix.fd_t {
    var fds: [2]i32 = undefined;
    const rc = std.c.socketpair(
        std.posix.AF.UNIX,
        std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
        0,
        &fds,
    );
    switch (std.posix.errno(rc)) {
        .SUCCESS => return .{ fds[0], fds[1] },
        else => |err| return std.posix.unexpectedErrno(err),
    }
}

/// Stands in for a completed receive: `bytes` land in the wire's receive
/// buffer and the wire takes them.
fn feed(wire: *transport.Wire, bytes: []const u8) !void {
    @memcpy(wire.recvBuffer()[0..bytes.len], bytes);
    try wire.feedReceived(bytes.len);
}

const FrameHead = struct {
    length: u24,
    frame_type: u8,
    flags: u8,
    stream_id: u32,
};

/// The header of the frame that starts at `offset` of what the client sent.
fn sentFrameAt(sent: []const u8, offset: usize) !FrameHead {
    if (sent.len < offset + frame_header_len)
        return error.ExpectedClientFrame;
    const bytes = sent[offset..][0..frame_header_len];
    return .{
        .length = std.mem.readInt(u24, bytes[0..3], .big),
        .frame_type = bytes[3],
        .flags = bytes[4],
        .stream_id = std.mem.readInt(u32, bytes[5..9], .big) & 0x7fff_ffff,
    };
}

fn expectPending(start_result: pool.StartResult) !pool.StreamHandle {
    return switch (start_result) {
        .pending => |stream| stream,
        .entry_failed => |failed| failed.err,
        .failed => |err| err,
        .needs_connection => error.UnexpectedHttp2ConnectionMiss,
    };
}

test "a pooled HTTP/2 entry queues its preface when it joins, ahead of any stream or answer" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var plan = try Fixture.prepare("https://a.example/one", &.{});
    defer plan.deinit();
    const entry = try fixture.addEntry(&plan.origin_key);

    // Every fetch that waited for the dial may fail before it opens a stream,
    // and a server may wait for the preface before it sends anything, so
    // the preface leaves with the entry.
    try std.testing.expect(std.mem.startsWith(u8, entry.wire.sendSlice(), client_connection_preface));
    const joined_len = entry.wire.sendSlice().len;

    // The server's SETTINGS reaches the idle entry, and the acknowledgement
    // follows the preface.
    try feed(entry.wire, server_settings_frame);
    try std.testing.expectError(error.Http2WouldBlock, fixture.pool.readEntryEvent(entry));
    const sent = entry.wire.sendSlice();
    try std.testing.expect(std.mem.startsWith(u8, sent, client_connection_preface));
    const ack = try sentFrameAt(sent, joined_len);
    try std.testing.expectEqual(frame_type_settings, ack.frame_type);
    try std.testing.expectEqual(flag_ack, ack.flags);
    try std.testing.expectEqual(joined_len + frame_header_len, sent.len);
}

test "an oversized request head fails alone, and the entry it would have shared keeps serving" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var plan = try Fixture.prepare("https://a.example/one", &.{});
    defer plan.deinit();
    const entry = try fixture.addEntry(&plan.origin_key);
    const first = try expectPending(try fixture.start(&plan));
    try std.testing.expectEqual(entry, first.entry);

    // '~' has a 13-bit Huffman code, so the value would go out raw, and the
    // block could not fit the request block cap.
    const large = try std.testing.allocator.alloc(u8, 64 * 1024 - 1);
    defer std.testing.allocator.free(large);
    @memset(large, '~');
    var oversized = try Fixture.prepare("https://a.example/two", &.{.{ .name = "x-large", .value = large }});
    defer oversized.deinit();
    switch (try fixture.start(&oversized)) {
        .failed => |err| try std.testing.expectEqual(error.Http2RequestHeadersTooLarge, err),
        .pending, .needs_connection, .entry_failed => return error.ExpectedRequestFailure,
    }

    // The stream already on the entry is untouched and a new one joins it.
    try std.testing.expect(!entry.h2.closing);
    try std.testing.expect(entry.h2.hasActiveStreams());
    const next = try expectPending(try fixture.start(&plan));
    try std.testing.expectEqual(entry, next.entry);
    try std.testing.expect(next.stream_id != first.stream_id);
}

test "an entry event leaves before what its frame wrote is flushed, and the next read sends that first" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var plan = try Fixture.prepare("https://a.example/one", &.{});
    defer plan.deinit();
    const entry = try fixture.addEntry(&plan.origin_key);
    const stream = try expectPending(try fixture.start(&plan));
    try std.testing.expectEqual(@as(u32, 1), stream.stream_id);

    // The malformed head fails its stream, which writes RST_STREAM. An event
    // may own a decoded head or a body chunk, so a flush that could fail
    // must not run between producing it and returning it.
    try feed(entry.wire, server_settings_frame ++ malformed_head_frame);
    var event = try fixture.pool.readEntryEvent(entry);
    defer event.deinit();
    switch (event) {
        .failure => |failure| {
            try std.testing.expectEqual(stream.stream_id, failure.stream_id);
            try std.testing.expectEqual(error.Http2MalformedResponse, failure.err);
        },
        else => return error.ExpectedHttp2Failure,
    }
    try std.testing.expect(entry.hasOutgoing());
    const sent_before = entry.wire.sendSlice().len;

    try std.testing.expectError(error.Http2WouldBlock, fixture.pool.readEntryEvent(entry));
    try std.testing.expect(!entry.hasOutgoing());
    const reset = try sentFrameAt(entry.wire.sendSlice(), sent_before);
    try std.testing.expectEqual(frame_type_rst_stream, reset.frame_type);
    try std.testing.expectEqual(stream.stream_id, reset.stream_id);
    try std.testing.expectEqual(sent_before + frame_header_len + reset.length, entry.wire.sendSlice().len);
}

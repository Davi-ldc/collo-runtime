//! The worker's decoder for fetch bodies the gateway forwards encoded
//! (`worker/egress/body/decoder.zig`), fed borrowed extents with a release
//! log standing in for the body pool's release queue: each extent is
//! released exactly once and only on full consumption; decoding pauses at
//! the decoded watermark and resumes after pulls; the decoded budget and the
//! ratio guard fail the body; `deinit` hands back every extent; and limits
//! from a half-filled head fall back to defaults. Runs in `worker-test`; the
//! gateway's side of the encoded path runs in `egress-gateway-test`.

const std = @import("std");
const limits = @import("collo_limits");
const worker = @import("collo_worker");

const egress_body = worker.testing.egress_body;
const Body = egress_body.Body;
const Decoder = egress_body.Decoder;
const allocator = std.testing.allocator;

/// "hello world" as one gzip member.
const gzip_hello_world = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x03, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57,
    0x28, 0xcf, 0x2f, 0xca, 0x49, 0x01, 0x00, 0x85,
    0x11, 0x4a, 0x0d, 0x0b, 0x00, 0x00, 0x00,
};

/// gzip of 8192 'a' bytes, 44 encoded bytes for a ratio of about 186. It trips
/// the default ratio guard once the guard's minimum is lowered.
const gzip_bomb_8k_a = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x02, 0x03, 0xed, 0xc1, 0x01, 0x0d, 0x00, 0x00,
    0x00, 0xc2, 0xa0, 0xac, 0xef, 0x5f, 0xc2, 0x1c,
    0x6e, 0x40, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0xef, 0x06, 0xd5, 0x66, 0x6f, 0x0d,
    0x00, 0x20, 0x00, 0x00,
};

fn identity(body_id: u64) egress_body.Identity {
    return .{ .request_id = 10, .request_generation = 20, .fetch_id = 30, .body_id = body_id };
}

const ReleaseLog = struct {
    handles: [8]u64 = undefined,
    lens: [8]usize = undefined,
    count: usize = 0,

    fn releaseFn(context: ?*anyopaque, handle: u64, len: usize) void {
        const self: *ReleaseLog = @ptrCast(@alignCast(context.?));
        std.debug.assert(self.count < self.handles.len);
        self.handles[self.count] = handle;
        self.lens[self.count] = len;
        self.count += 1;
    }

    fn borrow(self: *ReleaseLog, bytes: []u8, handle: u64) egress_body.BorrowedChunk {
        return .{
            .bytes = bytes,
            .release = .{ .context = self, .handle = handle, .len = bytes.len, .release_fn = releaseFn },
        };
    }
};

fn endBody(body: *Body) void {
    body.releaseQueuedChunks(allocator);
    body.deinit(allocator);
}

/// Whether the decoder still holds encoded input or output it could not emit
/// within the decoded watermark, which a later drain decodes.
fn hasPendingWork(decoder: *const Decoder) bool {
    return decoder.pending.items.len != 0 or decoder.needs_output;
}

/// Pulls at most one decoded chunk into `out`; a pull already registered
/// stays.
fn pullAppend(body: *Body, out: *std.ArrayListUnmanaged(u8)) !void {
    _ = body.beginPull(.{ .deferred = null }) catch |err| switch (err) {
        error.FetchBodyReadInProgress => {},
        else => return err,
    };
    var pull = body.drainReadyForPull(allocator);
    defer pull.deinit(allocator);
    if (pull.bytes.isPresent())
        try out.appendSlice(allocator, pull.bytes.bytes);
}

test "decoder limits from a half-filled head fall back to defaults" {
    const defaults = egress_body.limitsFromHeadFields(0, 0, 0);
    try std.testing.expectEqual(limits.http_body.MATERIALIZED_BODY_BYTES_MAX, defaults.max_decoded_bytes);
    try std.testing.expect(defaults.max_pending_decoded_bytes != 0);
    try std.testing.expect(defaults.max_decoded_to_encoded_ratio != 0);
    _ = try defaults.normalized();

    const partial = egress_body.limitsFromHeadFields(1024, 0, 7);
    try std.testing.expectEqual(@as(usize, 1024), partial.max_decoded_bytes);
    try std.testing.expectEqual(defaults.max_pending_decoded_bytes, partial.max_pending_decoded_bytes);
    try std.testing.expectEqual(@as(u64, 7), partial.max_decoded_to_encoded_ratio);
}

test "the decoder decodes gzip across extents and releases each only once consumed" {
    var releases = ReleaseLog{};
    var body = Body.initOpen(allocator, identity(201));
    defer endBody(&body);
    var decoder = try Decoder.init(.gzip, .{ .max_decoded_bytes = 64, .max_pending_decoded_bytes = 64 });
    defer decoder.deinit(allocator);

    var header_extent: [10]u8 = gzip_hello_world[0..10].*;
    var rest_extent: [gzip_hello_world.len - 10]u8 = gzip_hello_world[10..].*;
    try std.testing.expect(!try body.beginPull(.{ .deferred = null }));

    // A header-only extent is consumed whole without output, and released.
    try decoder.pushBorrowed(allocator, &body, releases.borrow(&header_extent, 1));
    try std.testing.expectEqual(@as(usize, 1), releases.count);
    try std.testing.expectEqual(@as(usize, 10), releases.lens[0]);
    try std.testing.expectEqual(@as(usize, 0), decoder.pending.items.len);
    try std.testing.expect(!body.claimReadyForQueue());

    try decoder.pushBorrowed(allocator, &body, releases.borrow(&rest_extent, 2));
    try std.testing.expectEqual(@as(usize, 2), releases.count);
    try std.testing.expectEqual(@as(u64, 2), releases.handles[1]);
    try std.testing.expect(body.claimReadyForQueue());
    try std.testing.expect(try decoder.finish(allocator, &body));
    body.complete();

    var pull = body.drainReadyForPull(allocator);
    defer pull.deinit(allocator);
    try std.testing.expectEqualStrings("hello world", pull.bytes.bytes);
    try std.testing.expect(!pull.bytes.isBorrowed());
}

test "the decoder accepts concatenated gzip members" {
    var releases = ReleaseLog{};
    var body = Body.initOpen(allocator, identity(202));
    defer endBody(&body);
    var decoder = try Decoder.init(.gzip, .{ .max_decoded_bytes = 64, .max_pending_decoded_bytes = 64 });
    defer decoder.deinit(allocator);

    var first: [gzip_hello_world.len]u8 = gzip_hello_world;
    var second: [gzip_hello_world.len]u8 = gzip_hello_world;
    try std.testing.expect(!try body.beginPull(.{ .deferred = null }));
    try decoder.pushBorrowed(allocator, &body, releases.borrow(&first, 11));
    try decoder.pushBorrowed(allocator, &body, releases.borrow(&second, 12));
    try std.testing.expect(try decoder.finish(allocator, &body));

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    try pullAppend(&body, &out);
    try pullAppend(&body, &out);
    try std.testing.expectEqualStrings("hello worldhello world", out.items);
    try std.testing.expectEqual(@as(usize, 2), releases.count);
    try std.testing.expectEqual(@as(u64, 11), releases.handles[0]);
    try std.testing.expectEqual(@as(u64, 12), releases.handles[1]);
}

test "the decoder pauses at the decoded watermark and resumes after pulls, holding the extent until consumed" {
    var releases = ReleaseLog{};
    var body = Body.initOpen(allocator, identity(203));
    defer endBody(&body);
    var decoder = try Decoder.init(.gzip, .{ .max_decoded_bytes = 64, .max_pending_decoded_bytes = 5 });
    defer decoder.deinit(allocator);

    var encoded: [gzip_hello_world.len]u8 = gzip_hello_world;
    try std.testing.expect(!try body.beginPull(.{ .deferred = null }));
    try decoder.pushBorrowed(allocator, &body, releases.borrow(&encoded, 7));
    try std.testing.expectEqual(@as(usize, 5), body.queuedBytes());
    try std.testing.expect(hasPendingWork(&decoder));
    try std.testing.expectEqual(@as(usize, 0), releases.count);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    try pullAppend(&body, &out);
    while (hasPendingWork(&decoder)) {
        if (decoder.pending.items.len != 0)
            try std.testing.expectEqual(@as(usize, 0), releases.count);
        try decoder.drainPending(allocator, &body);
        try pullAppend(&body, &out);
    }
    try std.testing.expectEqual(@as(usize, 1), releases.count);
    try std.testing.expectEqual(@as(usize, gzip_hello_world.len), releases.lens[0]);

    try std.testing.expect(try decoder.finish(allocator, &body));
    body.complete();
    try pullAppend(&body, &out);
    try std.testing.expectEqualStrings("hello world", out.items);
}

test "the decoder finishes a trailer that arrives exactly at the decoded budget" {
    var releases = ReleaseLog{};
    var body = Body.initOpen(allocator, identity(204));
    defer endBody(&body);
    var decoder = try Decoder.init(.gzip, .{ .max_decoded_bytes = 11, .max_pending_decoded_bytes = 64 });
    defer decoder.deinit(allocator);

    var data_extent: [gzip_hello_world.len - 8]u8 = gzip_hello_world[0 .. gzip_hello_world.len - 8].*;
    var trailer_extent: [8]u8 = gzip_hello_world[gzip_hello_world.len - 8 ..].*;
    try std.testing.expect(!try body.beginPull(.{ .deferred = null }));
    try decoder.pushBorrowed(allocator, &body, releases.borrow(&data_extent, 11));
    try std.testing.expectEqual(@as(usize, 1), releases.count);
    // The trailer decodes to nothing and is still consumed and released.
    try decoder.pushBorrowed(allocator, &body, releases.borrow(&trailer_extent, 12));
    try std.testing.expectEqual(@as(usize, 2), releases.count);
    try std.testing.expect(try decoder.finish(allocator, &body));
    body.complete();

    var pull = body.drainReadyForPull(allocator);
    defer pull.deinit(allocator);
    try std.testing.expectEqualStrings("hello world", pull.bytes.bytes);
}

test "a finish while output waits over the watermark completes only after the reader drains" {
    var releases = ReleaseLog{};
    var body = Body.initOpen(allocator, identity(205));
    defer endBody(&body);
    var decoder = try Decoder.init(.gzip, .{ .max_decoded_bytes = 64, .max_pending_decoded_bytes = 5 });
    defer decoder.deinit(allocator);

    var encoded: [gzip_hello_world.len]u8 = gzip_hello_world;
    try std.testing.expect(!try body.beginPull(.{ .deferred = null }));
    try decoder.pushBorrowed(allocator, &body, releases.borrow(&encoded, 21));
    try std.testing.expect(!try decoder.finish(allocator, &body));
    try std.testing.expect(!try decoder.finish(allocator, &body));
    try std.testing.expect(decoder.end_seen);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    try pullAppend(&body, &out);
    var complete = false;
    while (!complete) {
        complete = try decoder.finish(allocator, &body);
        try pullAppend(&body, &out);
    }
    try std.testing.expectEqualStrings("hello world", out.items);
    try std.testing.expectEqual(@as(usize, 1), releases.count);
    try std.testing.expect(try decoder.finish(allocator, &body));
}

test "the decoded budget fails the decode and the extent is released exactly once" {
    var releases = ReleaseLog{};
    var body = Body.initOpen(allocator, identity(206));
    defer endBody(&body);
    var encoded: [gzip_hello_world.len]u8 = gzip_hello_world;
    {
        var decoder = try Decoder.init(.gzip, .{ .max_decoded_bytes = 10, .max_pending_decoded_bytes = 64 });
        defer decoder.deinit(allocator);
        try std.testing.expectError(
            error.FetchResponseTooLarge,
            decoder.pushBorrowed(allocator, &body, releases.borrow(&encoded, 31)),
        );
    }
    try std.testing.expectEqual(@as(usize, 1), releases.count);
    try std.testing.expectEqual(@as(u64, 31), releases.handles[0]);
}

test "the ratio guard fails a decompression bomb and the extent is released exactly once" {
    var releases = ReleaseLog{};
    var body = Body.initOpen(allocator, identity(207));
    defer endBody(&body);
    var encoded: [gzip_bomb_8k_a.len]u8 = gzip_bomb_8k_a;
    {
        var decoder = try Decoder.init(.gzip, .{
            .max_decoded_bytes = 16 * 1024,
            .max_pending_decoded_bytes = 16 * 1024,
            .ratio_guard_min_encoded_bytes = 1,
        });
        defer decoder.deinit(allocator);
        try std.testing.expectError(
            error.FetchCompressionRatioExceeded,
            decoder.pushBorrowed(allocator, &body, releases.borrow(&encoded, 51)),
        );
    }
    try std.testing.expectEqual(@as(usize, 1), releases.count);
    try std.testing.expectEqual(@as(usize, 0), body.queuedBytes());
}

test "the decoder releases an empty extent at once and keeps answering complete after its end" {
    var releases = ReleaseLog{};
    var body = Body.initOpen(allocator, identity(208));
    defer endBody(&body);
    var decoder = try Decoder.init(.gzip, .{ .max_decoded_bytes = 64, .max_pending_decoded_bytes = 64 });
    defer decoder.deinit(allocator);

    var empty_extent: [0]u8 = .{};
    try decoder.pushBorrowed(allocator, &body, releases.borrow(&empty_extent, 61));
    try std.testing.expectEqual(@as(usize, 1), releases.count);

    var encoded: [gzip_hello_world.len]u8 = gzip_hello_world;
    try std.testing.expect(!try body.beginPull(.{ .deferred = null }));
    try decoder.pushBorrowed(allocator, &body, releases.borrow(&encoded, 62));
    try std.testing.expectEqual(@as(usize, 2), releases.count);
    try std.testing.expect(try decoder.finish(allocator, &body));
    try std.testing.expect(try decoder.finish(allocator, &body));
    body.complete();

    var pull = body.drainReadyForPull(allocator);
    defer pull.deinit(allocator);
    try std.testing.expectEqualStrings("hello world", pull.bytes.bytes);
}

test "a decoder dropped mid-stream releases every extent it still holds" {
    var releases = ReleaseLog{};
    var body = Body.initOpen(allocator, identity(209));
    defer endBody(&body);
    var first_extent: [20]u8 = gzip_hello_world[0..20].*;
    var second_extent: [gzip_hello_world.len - 20]u8 = gzip_hello_world[20..].*;
    {
        var decoder = try Decoder.init(.gzip, .{ .max_decoded_bytes = 64, .max_pending_decoded_bytes = 5 });
        defer decoder.deinit(allocator);
        try std.testing.expect(!try body.beginPull(.{ .deferred = null }));
        try decoder.pushBorrowed(allocator, &body, releases.borrow(&first_extent, 71));
        try decoder.pushBorrowed(allocator, &body, releases.borrow(&second_extent, 72));
        try std.testing.expect(releases.count <= 1);
        try std.testing.expect(decoder.pending.items.len != 0);
    }
    try std.testing.expectEqual(@as(usize, 2), releases.count);
    try std.testing.expectEqual(@as(u64, 71), releases.handles[0]);
    try std.testing.expectEqual(@as(u64, 72), releases.handles[1]);
}

test "a body drops its decoder with the extents it holds" {
    var releases = ReleaseLog{};
    var body = Body.initOpen(allocator, identity(210));
    defer endBody(&body);
    const decoder = try allocator.create(Decoder);
    decoder.* = try Decoder.init(.gzip, .{ .max_decoded_bytes = 64, .max_pending_decoded_bytes = 5 });
    body.decoder = decoder;

    var extent: [gzip_hello_world.len]u8 = gzip_hello_world;
    try std.testing.expect(!try body.beginPull(.{ .deferred = null }));
    try decoder.pushBorrowed(allocator, &body, releases.borrow(&extent, 81));
    try std.testing.expectEqual(@as(usize, 0), releases.count);
    body.dropDecoder(allocator);
    try std.testing.expect(body.decoder == null);
    try std.testing.expectEqual(@as(usize, 1), releases.count);
}

//! The worker's encoded-body decoder fed borrowed extents, with a release
//! callback standing in for the gateway body-pool release queue. Each extent
//! is released exactly once and only on full consumption; decoding pauses at
//! the decoded watermark and resumes after pulls; the decoded budget and the
//! ratio guard fail the body; and `deinit` hands back every extent. The
//! gateway side of the same path runs end to end in
//! `egress-gateway-test` (`thin_demux.zig`).

const std = @import("std");
const test_support = @import("support.zig");
const limits = @import("collo_limits");
const fetch_body = test_support.fetch_body;
const decompress = test_support.decompress;
const stream_pump = test_support.stream_pump;
const encoded_body = @import("collo_egress_client").core.encoded_body;
const identity = test_support.identity;
const collectReleasedCredits = test_support.collectReleasedCredits;
const gzip_hello_world = test_support.gzip_hello_world;

/// gzip of 8192 'a' bytes, 44 encoded bytes for a ratio of about 186. It trips
/// the default ratio guard (`stream_pump.default_max_decoded_to_encoded_ratio`)
/// once the guard minimum is lowered.
const gzip_bomb_8k_a = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x02, 0x03, 0xed, 0xc1, 0x01, 0x0d, 0x00, 0x00,
    0x00, 0xc2, 0xa0, 0xac, 0xef, 0x5f, 0xc2, 0x1c,
    0x6e, 0x40, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0xef, 0x06, 0xd5, 0x66, 0x6f, 0x0d,
    0x00, 0x20, 0x00, 0x00,
};

const ReleaseLog = struct {
    seqs: [8]u64 = undefined,
    lens: [8]usize = undefined,
    count: usize = 0,

    fn releaseFn(context: ?*anyopaque, seq: u64, len: usize) void {
        const self: *ReleaseLog = @ptrCast(@alignCast(context.?));
        std.debug.assert(self.count < self.seqs.len);
        self.seqs[self.count] = seq;
        self.lens[self.count] = len;
        self.count += 1;
    }

    fn borrow(self: *ReleaseLog, bytes: []u8, seq: u64) fetch_body.BorrowedChunk {
        return .{
            .bytes = bytes,
            .release = .{
                .context = self,
                .seq = seq,
                .len = bytes.len,
                .release_fn = releaseFn,
            },
        };
    }
};

/// Pulls at most one decoded chunk into `out`. Tolerates a still-registered
/// pull waiter (an empty drain leaves it parked on the body).
fn pullAppend(body: *fetch_body.Body, out: *std.array_list.Aligned(u8, null)) !void {
    _ = body.beginPull(.{ .deferred = null }) catch |err| switch (err) {
        error.FetchBodyReadInProgress => {},
        else => return err,
    };
    var pull = try body.drainReadyForPull(std.testing.allocator);
    defer pull.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), pull.credits.slice().len);
    if (pull.bytes.isPresent())
        try out.appendSlice(std.testing.allocator, pull.bytes.bytes());
}

test "encoded body decoder limits from half-filled head fall back to defaults" {
    const defaults = encoded_body.limitsFromHeadFields(0, 0, 0);
    try std.testing.expectEqual(limits.http_body.MATERIALIZED_BODY_BYTES_MAX, defaults.max_decoded_bytes);
    try std.testing.expectEqual(stream_pump.default_max_pending_decoded_bytes, defaults.max_pending_decoded_bytes);
    try std.testing.expectEqual(stream_pump.default_max_decoded_to_encoded_ratio, defaults.max_decoded_to_encoded_ratio);
    // A half-filled head must still normalize into a usable (non-zero) budget.
    _ = try defaults.normalized();

    const partial = encoded_body.limitsFromHeadFields(1024, 0, 7);
    try std.testing.expectEqual(@as(usize, 1024), partial.max_decoded_bytes);
    try std.testing.expectEqual(stream_pump.default_max_pending_decoded_bytes, partial.max_pending_decoded_bytes);
    try std.testing.expectEqual(@as(u64, 7), partial.max_decoded_to_encoded_ratio);
}

test "encoded body decoder decodes gzip across extents and releases each only on full consumption" {
    if (!decompress.supportsZlib())
        return error.SkipZigTest;

    var releases = ReleaseLog{};
    var body = fetch_body.Body.initOpen(std.testing.allocator, identity(201), 64);
    defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);

    var decoder = try encoded_body.Decoder.init(.gzip, .{
        .max_decoded_bytes = 64,
        .max_pending_decoded_bytes = 64,
    });
    defer decoder.deinit(std.testing.allocator);

    var header_extent: [10]u8 = gzip_hello_world[0..10].*;
    var rest_extent: [gzip_hello_world.len - 10]u8 = gzip_hello_world[10..].*;

    try std.testing.expect(!try body.beginPull(.{ .deferred = null }));

    // Header-only extent: fully consumed, no decoded output, released at once.
    try std.testing.expect(!try decoder.pushBorrowed(
        std.testing.allocator,
        &body,
        releases.borrow(&header_extent, 1),
    ));
    try std.testing.expectEqual(@as(usize, 1), releases.count);
    try std.testing.expectEqual(@as(u64, 1), releases.seqs[0]);
    try std.testing.expectEqual(@as(usize, 10), releases.lens[0]);
    try std.testing.expectEqual(@as(usize, 0), decoder.pending.items.len);

    // Remainder: decoded output ready, extent released on full consumption.
    try std.testing.expect(try decoder.pushBorrowed(
        std.testing.allocator,
        &body,
        releases.borrow(&rest_extent, 2),
    ));
    try std.testing.expectEqual(@as(usize, 2), releases.count);
    try std.testing.expectEqual(@as(u64, 2), releases.seqs[1]);

    const finish = try decoder.finish(std.testing.allocator, &body);
    try std.testing.expect(finish.complete);
    try std.testing.expect(body.complete());

    var pull = try body.drainReadyForPull(std.testing.allocator);
    defer pull.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("hello world", pull.bytes.bytes());
    // Decoded chunks carry no credit; the releases are the flow-control
    // refill.
    try std.testing.expectEqual(@as(usize, 0), pull.credits.slice().len);
}

test "encoded body decoder accepts concatenated gzip members" {
    if (!decompress.supportsZlib())
        return error.SkipZigTest;

    var releases = ReleaseLog{};
    var body = fetch_body.Body.initOpen(std.testing.allocator, identity(202), 64);
    defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);

    var decoder = try encoded_body.Decoder.init(.gzip, .{
        .max_decoded_bytes = 64,
        .max_pending_decoded_bytes = 64,
    });
    defer decoder.deinit(std.testing.allocator);

    var first: [gzip_hello_world.len]u8 = gzip_hello_world;
    var second: [gzip_hello_world.len]u8 = gzip_hello_world;
    try std.testing.expect(!try body.beginPull(.{ .deferred = null }));
    try std.testing.expect(try decoder.pushBorrowed(
        std.testing.allocator,
        &body,
        releases.borrow(&first, 11),
    ));
    try std.testing.expect(try decoder.pushBorrowed(
        std.testing.allocator,
        &body,
        releases.borrow(&second, 12),
    ));
    const finish = try decoder.finish(std.testing.allocator, &body);
    try std.testing.expect(finish.complete);

    var pull = try body.drainReadyForPull(std.testing.allocator);
    defer pull.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("hello world", pull.bytes.bytes());
    try std.testing.expect(try body.beginPull(.{ .deferred = null }));
    var second_pull = try body.drainReadyForPull(std.testing.allocator);
    defer second_pull.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("hello world", second_pull.bytes.bytes());
    try std.testing.expectEqual(@as(usize, 2), releases.count);
    try std.testing.expectEqual(@as(u64, 11), releases.seqs[0]);
    try std.testing.expectEqual(@as(u64, 12), releases.seqs[1]);
}

test "encoded body decoder pauses at decoded watermark and resumes after pulls" {
    if (!decompress.supportsZlib())
        return error.SkipZigTest;

    var releases = ReleaseLog{};
    var body = fetch_body.Body.initOpen(std.testing.allocator, identity(202), 64);
    defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);

    var decoder = try encoded_body.Decoder.init(.gzip, .{
        .max_decoded_bytes = 64,
        .max_pending_decoded_bytes = 5,
    });
    defer decoder.deinit(std.testing.allocator);

    var encoded: [gzip_hello_world.len]u8 = gzip_hello_world;
    try std.testing.expect(!try body.beginPull(.{ .deferred = null }));
    try std.testing.expect(try decoder.pushBorrowed(
        std.testing.allocator,
        &body,
        releases.borrow(&encoded, 7),
    ));

    // Paused at the watermark: the extent is partly consumed and not
    // released.
    try std.testing.expectEqual(@as(usize, 5), body.queuedDecodedBytes());
    try std.testing.expect(decoder.hasPendingEncoded());
    try std.testing.expectEqual(@as(usize, 1), decoder.pending.items.len);
    try std.testing.expectEqual(@as(usize, 0), releases.count);

    var out: std.array_list.Aligned(u8, null) = .empty;
    defer out.deinit(std.testing.allocator);

    {
        var pull = try body.drainReadyForPull(std.testing.allocator);
        defer pull.deinit(std.testing.allocator);
        try out.appendSlice(std.testing.allocator, pull.bytes.bytes());
        try std.testing.expectEqual(@as(usize, 0), pull.credits.slice().len);
    }

    while (decoder.hasPendingEncoded()) {
        // The partially consumed extent stays unreleased across pauses.
        if (decoder.pending.items.len != 0)
            try std.testing.expectEqual(@as(usize, 0), releases.count);
        _ = try decoder.drainPending(std.testing.allocator, &body);
        try pullAppend(&body, &out);
    }

    // Full consumption is the release point.
    try std.testing.expectEqual(@as(usize, 1), releases.count);
    try std.testing.expectEqual(@as(u64, 7), releases.seqs[0]);
    try std.testing.expectEqual(@as(usize, gzip_hello_world.len), releases.lens[0]);

    const finish = try decoder.finish(std.testing.allocator, &body);
    try std.testing.expect(finish.complete);
    // complete() returns waiter readiness, which depends on pull timing here;
    // the state transition is what matters.
    _ = body.complete();
    try std.testing.expectEqual(fetch_body.State.complete, body.state);
    try pullAppend(&body, &out);
    try std.testing.expectEqualStrings("hello world", out.items);
}

test "encoded body decoder finishes trailer exactly at decoded budget" {
    if (!decompress.supportsZlib())
        return error.SkipZigTest;

    var releases = ReleaseLog{};
    var body = fetch_body.Body.initOpen(std.testing.allocator, identity(203), 64);
    defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);

    var decoder = try encoded_body.Decoder.init(.gzip, .{
        .max_decoded_bytes = 11,
        .max_pending_decoded_bytes = 64,
    });
    defer decoder.deinit(std.testing.allocator);

    var data_extent: [gzip_hello_world.len - 8]u8 = gzip_hello_world[0 .. gzip_hello_world.len - 8].*;
    var trailer_extent: [8]u8 = gzip_hello_world[gzip_hello_world.len - 8 ..].*;

    try std.testing.expect(!try body.beginPull(.{ .deferred = null }));
    try std.testing.expect(try decoder.pushBorrowed(
        std.testing.allocator,
        &body,
        releases.borrow(&data_extent, 11),
    ));
    try std.testing.expectEqual(@as(usize, 1), releases.count);

    // Trailer arrives in its own extent: zero decoded output, still consumed
    // and released within the exactly-exhausted budget.
    try std.testing.expect(!try decoder.pushBorrowed(
        std.testing.allocator,
        &body,
        releases.borrow(&trailer_extent, 12),
    ));
    try std.testing.expectEqual(@as(usize, 2), releases.count);

    const finish = try decoder.finish(std.testing.allocator, &body);
    try std.testing.expect(finish.complete);
    try std.testing.expect(body.complete());

    var pull = try body.drainReadyForPull(std.testing.allocator);
    defer pull.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("hello world", pull.bytes.bytes());
}

test "encoded body decoder finish over watermark completes only after drain" {
    if (!decompress.supportsZlib())
        return error.SkipZigTest;

    var releases = ReleaseLog{};
    var body = fetch_body.Body.initOpen(std.testing.allocator, identity(204), 64);
    defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);

    var decoder = try encoded_body.Decoder.init(.gzip, .{
        .max_decoded_bytes = 64,
        .max_pending_decoded_bytes = 5,
    });
    defer decoder.deinit(std.testing.allocator);

    var encoded: [gzip_hello_world.len]u8 = gzip_hello_world;
    try std.testing.expect(!try body.beginPull(.{ .deferred = null }));
    try std.testing.expect(try decoder.pushBorrowed(
        std.testing.allocator,
        &body,
        releases.borrow(&encoded, 21),
    ));
    try std.testing.expectEqual(@as(usize, 5), body.queuedDecodedBytes());

    // End seen while output is parked over the watermark: not complete yet,
    // and repeat finishes must stay tolerated (resume-after-watermark).
    const early = try decoder.finish(std.testing.allocator, &body);
    try std.testing.expect(!early.complete);
    const early_again = try decoder.finish(std.testing.allocator, &body);
    try std.testing.expect(!early_again.complete);
    try std.testing.expect(decoder.end_seen);

    var out: std.array_list.Aligned(u8, null) = .empty;
    defer out.deinit(std.testing.allocator);

    {
        var pull = try body.drainReadyForPull(std.testing.allocator);
        defer pull.deinit(std.testing.allocator);
        try out.appendSlice(std.testing.allocator, pull.bytes.bytes());
    }

    var complete = false;
    while (!complete) {
        const finish = try decoder.finish(std.testing.allocator, &body);
        complete = finish.complete;
        try pullAppend(&body, &out);
    }

    try std.testing.expectEqualStrings("hello world", out.items);
    try std.testing.expectEqual(@as(usize, 1), releases.count);

    // Double finish after completion keeps answering complete.
    const again = try decoder.finish(std.testing.allocator, &body);
    try std.testing.expect(again.complete);
}

test "encoded body decoder fails decoded budget and releases the extent exactly once" {
    if (!decompress.supportsZlib())
        return error.SkipZigTest;

    var releases = ReleaseLog{};
    var body = fetch_body.Body.initOpen(std.testing.allocator, identity(205), 64);
    defer {
        _ = collectReleasedCredits(&body);
        body.deinitAfterQueuedResourcesReleased(std.testing.allocator);
    }

    var encoded: [gzip_hello_world.len]u8 = gzip_hello_world;
    {
        var decoder = try encoded_body.Decoder.init(.gzip, .{
            .max_decoded_bytes = 10,
            .max_pending_decoded_bytes = 64,
        });
        defer decoder.deinit(std.testing.allocator);

        try std.testing.expectError(error.FetchResponseTooLarge, decoder.pushBorrowed(
            std.testing.allocator,
            &body,
            releases.borrow(&encoded, 31),
        ));
        // The worker fail path mirrors stream-pump error mapping: the body is
        // failed and the decoder torn down, releasing everything it held.
        _ = try body.fail(std.testing.allocator, "FetchResponseTooLarge");
        try std.testing.expect(body.isFailed());
    }
    try std.testing.expectEqual(@as(usize, 1), releases.count);
    try std.testing.expectEqual(@as(u64, 31), releases.seqs[0]);
}

test "encoded body decoder ratio guard fails decompression bombs" {
    if (!decompress.supportsZlib())
        return error.SkipZigTest;

    var releases = ReleaseLog{};
    var body = fetch_body.Body.initOpen(std.testing.allocator, identity(206), null);
    defer {
        _ = collectReleasedCredits(&body);
        body.deinitAfterQueuedResourcesReleased(std.testing.allocator);
    }

    var encoded: [gzip_bomb_8k_a.len]u8 = gzip_bomb_8k_a;
    {
        var decoder = try encoded_body.Decoder.init(.gzip, .{
            .max_decoded_bytes = 16 * 1024,
            .max_pending_decoded_bytes = 16 * 1024,
            // The default ratio stays; lowering the guard floor brings the
            // 44-byte bomb (8192 decoded, about 186x) into the guard's range.
            .ratio_guard_min_encoded_bytes = 1,
        });
        defer decoder.deinit(std.testing.allocator);

        try std.testing.expectError(error.FetchCompressionRatioExceeded, decoder.pushBorrowed(
            std.testing.allocator,
            &body,
            releases.borrow(&encoded, 51),
        ));
    }
    // Exactly one release, whether it fired on consumption or at deinit.
    try std.testing.expectEqual(@as(usize, 1), releases.count);
    try std.testing.expectEqual(@as(u64, 51), releases.seqs[0]);
    try std.testing.expectEqual(@as(usize, 0), body.queuedDecodedBytes());
}

test "encoded body decoder handles empty extents and tolerates double finish" {
    if (!decompress.supportsZlib())
        return error.SkipZigTest;

    var releases = ReleaseLog{};
    var body = fetch_body.Body.initOpen(std.testing.allocator, identity(207), 64);
    defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);

    var decoder = try encoded_body.Decoder.init(.gzip, .{
        .max_decoded_bytes = 64,
        .max_pending_decoded_bytes = 64,
    });
    defer decoder.deinit(std.testing.allocator);

    // Zero-length extent: no window to refill, released immediately so it can
    // never wedge the drain.
    var empty_extent: [0]u8 = .{};
    try std.testing.expect(!try decoder.pushBorrowed(
        std.testing.allocator,
        &body,
        releases.borrow(&empty_extent, 61),
    ));
    try std.testing.expectEqual(@as(usize, 1), releases.count);
    try std.testing.expectEqual(@as(usize, 0), releases.lens[0]);

    var encoded: [gzip_hello_world.len]u8 = gzip_hello_world;
    try std.testing.expect(!try body.beginPull(.{ .deferred = null }));
    try std.testing.expect(try decoder.pushBorrowed(
        std.testing.allocator,
        &body,
        releases.borrow(&encoded, 62),
    ));
    try std.testing.expectEqual(@as(usize, 2), releases.count);

    const first_finish = try decoder.finish(std.testing.allocator, &body);
    try std.testing.expect(first_finish.complete);
    const second_finish = try decoder.finish(std.testing.allocator, &body);
    try std.testing.expect(second_finish.complete);
    try std.testing.expect(body.complete());

    var pull = try body.drainReadyForPull(std.testing.allocator);
    defer pull.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("hello world", pull.bytes.bytes());
}

test "encoded body decoder deinit releases all unconsumed extents" {
    if (!decompress.supportsZlib())
        return error.SkipZigTest;

    var releases = ReleaseLog{};
    var body = fetch_body.Body.initOpen(std.testing.allocator, identity(208), 64);
    defer {
        _ = collectReleasedCredits(&body);
        body.deinitAfterQueuedResourcesReleased(std.testing.allocator);
    }

    var first_extent: [20]u8 = gzip_hello_world[0..20].*;
    var second_extent: [gzip_hello_world.len - 20]u8 = gzip_hello_world[20..].*;
    {
        var decoder = try encoded_body.Decoder.init(.gzip, .{
            .max_decoded_bytes = 64,
            .max_pending_decoded_bytes = 5,
        });
        defer decoder.deinit(std.testing.allocator);

        try std.testing.expect(!try body.beginPull(.{ .deferred = null }));
        _ = try decoder.pushBorrowed(
            std.testing.allocator,
            &body,
            releases.borrow(&first_extent, 71),
        );
        _ = try decoder.pushBorrowed(
            std.testing.allocator,
            &body,
            releases.borrow(&second_extent, 72),
        );
        // The watermark stalls the drain with the second extent untouched
        // (and typically the first one only partially consumed).
        try std.testing.expect(releases.count <= 1);
        try std.testing.expect(decoder.pending.items.len != 0);
    }
    // Teardown (cleanup/disconnect paths) must hand every extent back.
    try std.testing.expectEqual(@as(usize, 2), releases.count);
    try std.testing.expectEqual(@as(u64, 71), releases.seqs[0]);
    try std.testing.expectEqual(@as(u64, 72), releases.seqs[1]);
}

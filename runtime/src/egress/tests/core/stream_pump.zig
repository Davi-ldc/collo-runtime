//! The stream pump and the HTTP/2 encoded sink against real bodies and fake
//! pipes: HTTP/2 credits per chunk and across tee branches, the encoded cap,
//! tee sources and their single cancel point, pull completion and failure,
//! meter deltas, the HTTP/1 paths at the watermark and the decoded budget,
//! deflate's zlib-or-raw sniff, and the allocation count of a decode. The
//! HTTP/1 continuation that drives the pump from a socket is covered by
//! `egress/tests/client/http1/` in `egress-test`.

const std = @import("std");
const test_support = @import("support.zig");
const body_credit = test_support.body_credit;
const fetch_body = test_support.fetch_body;
const decompress = test_support.decompress;
const stream_pump = test_support.stream_pump;
const transport = test_support.transport;
const identity = test_support.identity;
const waiter = test_support.waiter;
const h2Credit = test_support.h2Credit;
const expectH2Credit = test_support.expectH2Credit;
const collectReleasedCredits = test_support.collectReleasedCredits;
const gzip_hello_world = test_support.gzip_hello_world;

test "h2 encoded sink transfers chunks with h2 encoded-byte credit" {
    var body = fetch_body.Body.initOpen(std.testing.allocator, identity(81), 16);
    defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);

    var sink = stream_pump.H2EncodedSink{ .max_encoded_bytes = 16 };

    const bytes = try std.testing.allocator.dupe(u8, "abc");
    try std.testing.expect(!try sink.appendH2DataOwned(std.testing.allocator, &body, 701, 21, bytes, 3, true));
    try std.testing.expect(try body.beginPull(.{ .deferred = null }));

    var pull = try body.drainReadyForPull(std.testing.allocator);
    defer pull.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("abc", pull.bytes.bytes());
    try std.testing.expectEqual(@as(usize, 1), pull.credits.slice().len);
    try expectH2Credit(pull.credits.slice()[0], 701, 21, 3, true);
}

test "default h2 advertised stream window fits identity decoded queue" {
    const config = transport.Config{};
    const h2_limits = try config.http2Limits().normalized();
    var body = fetch_body.Body.initOpen(std.testing.allocator, identity(82), config.max_response_body_bytes);
    defer {
        _ = collectReleasedCredits(&body);
        body.deinitAfterQueuedResourcesReleased(std.testing.allocator);
    }

    var sink = stream_pump.H2EncodedSink{
        .max_encoded_bytes = (try config.streamPumpLimits().normalized()).max_encoded_bytes,
    };

    const window_len: usize = @intCast(h2_limits.stream_receive_window);
    const bytes = try std.testing.allocator.alloc(u8, window_len);
    @memset(bytes, 'x');
    try std.testing.expect(!try sink.appendH2DataOwned(
        std.testing.allocator,
        &body,
        702,
        23,
        bytes,
        h2_limits.stream_receive_window,
        true,
    ));
    try std.testing.expectEqual(window_len, body.queuedDecodedBytes());
}

test "h2 encoded sink rejects encoded bytes beyond gateway wire budget" {
    var body = fetch_body.Body.initOpen(std.testing.allocator, identity(83), 64);
    defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);

    var sink = stream_pump.H2EncodedSink{ .max_encoded_bytes = 4 };

    const bytes = try std.testing.allocator.dupe(u8, "abcde");
    try std.testing.expectError(
        error.FetchResponseEncodedTooLarge,
        sink.appendH2DataOwned(std.testing.allocator, &body, 704, 24, bytes, 5, true),
    );
    try std.testing.expectEqual(@as(usize, 0), body.queuedDecodedBytes());
}

test "h2 encoded sink frees owned data when fetch body rejects append" {
    var body = fetch_body.Body.initOpen(std.testing.allocator, identity(84), 2);
    defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);

    var sink = stream_pump.H2EncodedSink{ .max_encoded_bytes = 16 };

    const bytes = try std.testing.allocator.dupe(u8, "abc");
    try std.testing.expectError(
        error.MaxBufferExceeded,
        sink.appendH2DataOwned(std.testing.allocator, &body, 705, 25, bytes, 3, true),
    );
    try std.testing.expectEqual(@as(usize, 0), body.queuedDecodedBytes());
}

test "cloned streaming fetch body tees chunks and releases h2 credit after both branches drain" {
    var body = fetch_body.Body.initOpen(std.testing.allocator, identity(18), null);
    defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);

    const first = try std.testing.allocator.dupe(u8, "abc");
    try std.testing.expect(!try body.appendOwnedChunk(std.testing.allocator, first, h2Credit(18, 41, 3, true)));

    const branch = try body.cloneBranch(std.testing.allocator, identity(19));
    defer branch.releaseAfterQueuedResourcesReleased(std.testing.allocator);
    defer branch.detachTeeLinks(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), body.queuedDecodedBytes());
    try std.testing.expectEqual(@as(usize, 3), branch.queuedDecodedBytes());

    try std.testing.expect(try body.beginPull(.{ .deferred = null }));
    var original_pull = try body.drainReadyForPull(std.testing.allocator);
    defer original_pull.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("abc", original_pull.bytes.bytes());
    // The latch shared with the branch reserves a slot, but this view is not
    // the last holder, so the take yields `.none`. Slots are sized from the
    // chunk's own fields, never from the shared latch's count, which another
    // body's drain can change. The credit surfaces once, on the last
    // holder's drain below.
    try std.testing.expectEqual(@as(usize, 1), original_pull.credits.slice().len);
    try std.testing.expect(original_pull.credits.slice()[0].isNone());
    try std.testing.expectEqual(@as(usize, 0), body.queuedDecodedBytes());
    try std.testing.expectEqual(@as(usize, 3), branch.queuedDecodedBytes());

    try std.testing.expect(try branch.beginPull(.{ .deferred = null }));
    var branch_pull = try branch.drainReadyForPull(std.testing.allocator);
    defer branch_pull.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("abc", branch_pull.bytes.bytes());
    try std.testing.expectEqual(@as(usize, 1), branch_pull.credits.slice().len);
    try std.testing.expectEqual(@as(usize, 0), branch.queuedDecodedBytes());
    try expectH2Credit(branch_pull.credits.slice()[0], 18, 41, 3, true);

    try std.testing.expect(!try body.beginPull(.{ .deferred = null }));
    try std.testing.expect(!try branch.beginPull(.{ .deferred = null }));
    const next = try std.testing.allocator.dupe(u8, "z");
    try std.testing.expect(try body.appendOwnedChunk(std.testing.allocator, next, .none));
    try std.testing.expect(body.complete());

    var original_next = try body.drainReadyForPull(std.testing.allocator);
    defer original_next.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("z", original_next.bytes.bytes());

    var branch_next = try branch.drainReadyForPull(std.testing.allocator);
    defer branch_next.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("z", branch_next.bytes.bytes());

    try std.testing.expect(try branch.beginPull(.{ .deferred = null }));
    var branch_done = try branch.drainReadyForPull(std.testing.allocator);
    defer branch_done.deinit(std.testing.allocator);
    try std.testing.expect(branch_done.done);
}

test "release drains shared h2 credit only after all tee branches release queued chunks" {
    var body = fetch_body.Body.initOpen(std.testing.allocator, identity(28), null);
    defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);

    const first = try std.testing.allocator.dupe(u8, "abc");
    try std.testing.expect(!try body.appendOwnedChunk(std.testing.allocator, first, h2Credit(28, 51, 3, true)));

    const branch = try body.cloneBranch(std.testing.allocator, identity(29));
    defer branch.releaseAfterQueuedResourcesReleased(std.testing.allocator);
    defer branch.detachTeeLinks(std.testing.allocator);

    const original_released = collectReleasedCredits(&body);
    const original_credits = original_released.slice();
    try std.testing.expectEqual(@as(usize, 0), original_credits.len);

    const branch_released = collectReleasedCredits(branch);
    const branch_credits = branch_released.slice();
    try std.testing.expectEqual(@as(usize, 1), branch_credits.len);
    try expectH2Credit(branch_credits[0], 28, 51, 3, true);
}

test "released original view keeps tee source alive for clone" {
    var body = fetch_body.Body.initOpen(std.testing.allocator, identity(38), null);
    defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);

    const branch = try body.cloneBranch(std.testing.allocator, identity(39));
    defer branch.releaseAfterQueuedResourcesReleased(std.testing.allocator);
    defer branch.detachTeeLinks(std.testing.allocator);

    try std.testing.expect(body.sourceCancelIdentityAfterViewRelease() == null);
    const root_released = collectReleasedCredits(&body);
    const root_credits = root_released.slice();
    try std.testing.expectEqual(@as(usize, 0), root_credits.len);
    body.markViewReleased(std.testing.allocator);

    try std.testing.expect(!try branch.beginPull(.{ .deferred = null }));
    const chunk = try std.testing.allocator.dupe(u8, "after-root-release");
    try std.testing.expect(try body.appendOwnedChunk(std.testing.allocator, chunk, h2Credit(38, 61, 18, true)));

    var branch_pull = try branch.drainReadyForPull(std.testing.allocator);
    defer branch_pull.deinit(std.testing.allocator);
    try std.testing.expect(branch_pull.waiter != null);
    try std.testing.expectEqualStrings("after-root-release", branch_pull.bytes.bytes());
    try std.testing.expectEqual(@as(usize, 1), branch_pull.credits.slice().len);
    try expectH2Credit(branch_pull.credits.slice()[0], 38, 61, 18, true);
}

test "last clone release after original release is the only source cancel point" {
    var body = fetch_body.Body.initOpen(std.testing.allocator, identity(48), null);
    defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);

    const first = try body.cloneBranch(std.testing.allocator, identity(49));
    defer first.releaseAfterQueuedResourcesReleased(std.testing.allocator);
    errdefer first.detachTeeLinks(std.testing.allocator);
    const second = try body.cloneBranch(std.testing.allocator, identity(50));
    defer second.releaseAfterQueuedResourcesReleased(std.testing.allocator);
    defer second.detachTeeLinks(std.testing.allocator);

    body.markViewReleased(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 48), first.sourceIdentity().body_id);
    try std.testing.expect(first.sourceCancelIdentityAfterViewRelease() == null);

    first.markViewReleased(std.testing.allocator);
    first.detachTeeLinks(std.testing.allocator);
    try std.testing.expect(second.sourceCancelIdentityAfterViewRelease() != null);
    const cancel_identity = second.sourceCancelIdentityAfterViewRelease().?;
    try std.testing.expectEqual(@as(u64, 48), cancel_identity.body_id);
    try std.testing.expectEqual(@as(u64, 30), cancel_identity.fetch_id);
}

test "pull fetch body returns done only after queued chunks drain" {
    var body = fetch_body.Body.initOpen(std.testing.allocator, identity(9), null);
    defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);

    const chunk = try std.testing.allocator.dupe(u8, "x");
    try std.testing.expect(!try body.appendOwnedChunk(std.testing.allocator, chunk, .none));
    try std.testing.expect(!body.complete());

    try std.testing.expect(try body.beginPull(.{ .deferred = null }));
    var chunk_pull = try body.drainReadyForPull(std.testing.allocator);
    defer chunk_pull.deinit(std.testing.allocator);
    try std.testing.expect(chunk_pull.waiter != null);
    try std.testing.expect(!chunk_pull.done);
    try std.testing.expectEqualStrings("x", chunk_pull.bytes.bytes());

    try std.testing.expect(try body.beginPull(.{ .deferred = null }));
    var done_pull = try body.drainReadyForPull(std.testing.allocator);
    defer done_pull.deinit(std.testing.allocator);
    try std.testing.expect(done_pull.waiter != null);
    try std.testing.expect(done_pull.done);
    try std.testing.expect(!done_pull.bytes.isPresent());
}

test "failed pull fetch body releases queued h2 credits" {
    var body = fetch_body.Body.initOpen(std.testing.allocator, identity(10), null);
    defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);

    const chunk = try std.testing.allocator.dupe(u8, "drop");
    try std.testing.expect(!try body.appendOwnedChunk(std.testing.allocator, chunk, h2Credit(10, 13, 4, true)));
    try std.testing.expect(try body.beginPull(.{ .deferred = null }));
    try std.testing.expect(try body.fail(std.testing.allocator, "reset"));

    var failed_pull = try body.drainReadyForPull(std.testing.allocator);
    defer failed_pull.deinit(std.testing.allocator);
    try std.testing.expect(failed_pull.waiter != null);
    try std.testing.expect(failed_pull.failed);
    try std.testing.expectEqual(@as(usize, 1), failed_pull.credits.slice().len);
    try expectH2Credit(failed_pull.credits.slice()[0], 10, 13, 4, true);
}

test "fetch body byte limit fails closed" {
    var body = fetch_body.Body.initOpen(std.testing.allocator, identity(3), 4);
    defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);

    try body.append("1234");
    try std.testing.expectError(error.MaxBufferExceeded, body.append("5"));
    try std.testing.expect(body.borrowCompleteBytes() == null);
}

test "failed fetch body wakes pending read without bytes" {
    var body = fetch_body.Body.initOpen(std.testing.allocator, identity(4), null);
    defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);

    try std.testing.expect(!try body.beginConsume(try waiter(std.testing.allocator)));
    try std.testing.expect(try body.fail(std.testing.allocator, "network closed"));

    try std.testing.expectEqual(fetch_body.State.failed, body.state);
    try std.testing.expect(body.isReadyForWaiter());
    try std.testing.expectEqualStrings("network closed", body.error_message.?);
    try std.testing.expect(body.borrowCompleteBytes() == null);
}

test "canceled fetch body records abort state" {
    var body = fetch_body.Body.initOpen(std.testing.allocator, identity(6), null);
    defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);

    try std.testing.expect(!try body.beginConsume(try waiter(std.testing.allocator)));
    try std.testing.expect(try body.cancel(std.testing.allocator, "fetch aborted", null));

    try std.testing.expect(body.isCanceled());
    try std.testing.expect(body.isFailed());
    try std.testing.expectEqualStrings("fetch aborted", body.error_message.?);
}

test "fetch body accounts egress meters incrementally while open" {
    var body = fetch_body.Body.initOpen(std.testing.allocator, identity(5), null);
    defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);

    body.setEgressMeters(.{ .billed_sent = 100, .billed_received = 23, .cost = 150 });
    var delta = body.takeUnaccountedEgressMeters();
    try std.testing.expectEqual(@as(u64, 100), delta.billed_sent);
    try std.testing.expectEqual(@as(u64, 23), delta.billed_received);
    try std.testing.expectEqual(@as(u64, 150), delta.cost);
    delta = body.takeUnaccountedEgressMeters();
    try std.testing.expectEqual(@as(u64, 0), delta.billed_sent);
    try std.testing.expectEqual(@as(u64, 0), delta.billed_received);
    try std.testing.expectEqual(@as(u64, 0), delta.cost);

    // Absolute totals set by maximum: a stale fold changes nothing, and a
    // grown total yields only its delta.
    body.setEgressMeters(.{ .billed_sent = 90, .billed_received = 23, .cost = 150 });
    body.setEgressMeters(.{ .billed_sent = 177, .billed_received = 23, .cost = 151 });
    delta = body.takeUnaccountedEgressMeters();
    try std.testing.expectEqual(@as(u64, 77), delta.billed_sent);
    try std.testing.expectEqual(@as(u64, 0), delta.billed_received);
    try std.testing.expectEqual(@as(u64, 1), delta.cost);
}

test "http1 pump waits for decoded capacity instead of failing a full queue" {
    var pipe = Http1BackpressurePipe.init(std.testing.allocator, 4);
    defer pipe.deinit();

    var pump = try stream_pump.Pump.initWithLimits(.identity, try (stream_pump.Limits{
        .max_decoded_bytes = 16,
        .max_pending_decoded_bytes = 4,
    }).normalized());
    defer pump.deinit(std.testing.allocator);

    try std.testing.expect(try pump.appendHttp1DataBackpressured(
        std.testing.allocator,
        &pipe,
        "xy",
        NeverCanceled{},
    ));
    try std.testing.expectEqual(@as(usize, 1), pipe.wait_calls);
    try std.testing.expectEqualStrings("xy", pipe.bytes.items);
}

test "http1 pump without capacity waiter still fails closed at decoded watermark" {
    var pipe = Http1NoWaitPipe{ .queued = 4 };

    var pump = try stream_pump.Pump.initWithLimits(.identity, try (stream_pump.Limits{
        .max_decoded_bytes = 16,
        .max_pending_decoded_bytes = 4,
    }).normalized());
    defer pump.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.FetchBodyDecodedQueueFull,
        pump.appendHttp1DataBackpressured(std.testing.allocator, &pipe, "xy", NeverCanceled{}),
    );
}

test "http1 compressed trailer can finish exactly at decoded budget" {
    if (!decompress.supportsZlib())
        return error.SkipZigTest;

    var pipe = Http1BackpressurePipe.init(std.testing.allocator, 0);
    defer pipe.deinit();

    var pump = try stream_pump.Pump.initWithLimits(.gzip, try (stream_pump.Limits{
        .max_decoded_bytes = 11,
        .max_encoded_bytes = gzip_hello_world.len,
        .max_pending_decoded_bytes = 64,
    }).normalized());
    defer pump.deinit(std.testing.allocator);

    const without_trailer = gzip_hello_world[0 .. gzip_hello_world.len - 8];
    try std.testing.expect(try pump.appendHttp1DataBackpressured(
        std.testing.allocator,
        &pipe,
        without_trailer,
        NeverCanceled{},
    ));
    try std.testing.expectEqualStrings("hello world", pipe.bytes.items);
    try std.testing.expectEqual(@as(usize, 0), pipe.wait_calls);

    _ = try pump.appendHttp1DataBackpressured(
        std.testing.allocator,
        &pipe,
        gzip_hello_world[gzip_hello_world.len - 8 ..],
        NeverCanceled{},
    );
    try std.testing.expect(try pump.finishBackpressured(std.testing.allocator, &pipe, NeverCanceled{}));
    try std.testing.expect(pipe.completed);
    try std.testing.expectEqualStrings("hello world", pipe.bytes.items);
    try std.testing.expectEqual(@as(usize, 0), pipe.wait_calls);
}

test "deflate sniffs zlib-wrapped and raw streams alike" {
    if (!decompress.supportsZlib())
        return error.SkipZigTest;

    // Both wire shapes of `Content-Encoding: deflate` decode: the conformant
    // zlib wrapper (RFC 1950) and the bare RFC 1951 stream that a long tail
    // of origins sends, which browsers and curl also tell apart by sniffing.
    const vectors = [_][]const u8{
        &test_support.zlib_deflate_hello_world,
        &test_support.raw_deflate_hello_world,
    };
    for (vectors) |vector| {
        var pipe = Http1BackpressurePipe.init(std.testing.allocator, 0);
        defer pipe.deinit();
        var pump = try stream_pump.Pump.initWithLimits(.deflate, try (stream_pump.Limits{
            .max_decoded_bytes = 11,
            .max_encoded_bytes = vector.len,
            .max_pending_decoded_bytes = 64,
        }).normalized());
        defer pump.deinit(std.testing.allocator);

        _ = try pump.appendHttp1DataBackpressured(std.testing.allocator, &pipe, vector, NeverCanceled{});
        try std.testing.expect(try pump.finishBackpressured(std.testing.allocator, &pipe, NeverCanceled{}));
        try std.testing.expect(pipe.completed);
        try std.testing.expectEqualStrings("hello world", pipe.bytes.items);
    }
}

test "deflate sniff survives a one-byte first chunk" {
    if (!decompress.supportsZlib())
        return error.SkipZigTest;

    // The sniff needs two bytes; a single-byte first read must be held and
    // replayed once the second byte decides the wrapping.
    const vector: []const u8 = &test_support.raw_deflate_hello_world;
    var pipe = Http1BackpressurePipe.init(std.testing.allocator, 0);
    defer pipe.deinit();
    var pump = try stream_pump.Pump.initWithLimits(.deflate, try (stream_pump.Limits{
        .max_decoded_bytes = 11,
        .max_encoded_bytes = vector.len,
        .max_pending_decoded_bytes = 64,
    }).normalized());
    defer pump.deinit(std.testing.allocator);

    for (vector) |byte| {
        _ = try pump.appendHttp1DataBackpressured(std.testing.allocator, &pipe, &.{byte}, NeverCanceled{});
    }
    try std.testing.expect(try pump.finishBackpressured(std.testing.allocator, &pipe, NeverCanceled{}));
    try std.testing.expect(pipe.completed);
    try std.testing.expectEqualStrings("hello world", pipe.bytes.items);
}

test "deflate stream shorter than the sniff is truncated, not accepted" {
    if (!decompress.supportsZlib())
        return error.SkipZigTest;

    var pipe = Http1BackpressurePipe.init(std.testing.allocator, 0);
    defer pipe.deinit();
    var pump = try stream_pump.Pump.initWithLimits(.deflate, try (stream_pump.Limits{
        .max_decoded_bytes = 11,
        .max_encoded_bytes = 16,
        .max_pending_decoded_bytes = 64,
    }).normalized());
    defer pump.deinit(std.testing.allocator);

    _ = try pump.appendHttp1DataBackpressured(std.testing.allocator, &pipe, &.{0x78}, NeverCanceled{});
    try std.testing.expectError(
        error.FetchResponseTruncated,
        pump.finishBackpressured(std.testing.allocator, &pipe, NeverCanceled{}),
    );
}

test "http1 compressed append fails when exhausted budget needs more output" {
    if (!decompress.supportsZlib())
        return error.SkipZigTest;

    var pipe = Http1BackpressurePipe.init(std.testing.allocator, 0);
    defer pipe.deinit();

    var pump = try stream_pump.Pump.initWithLimits(.gzip, try (stream_pump.Limits{
        .max_decoded_bytes = 10,
        .max_encoded_bytes = gzip_hello_world.len,
        .max_pending_decoded_bytes = 64,
    }).normalized());
    defer pump.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.FetchResponseTooLarge,
        pump.appendHttp1DataBackpressured(std.testing.allocator, &pipe, gzip_hello_world[0..], NeverCanceled{}),
    );
    try std.testing.expectEqualStrings("hello worl", pipe.bytes.items);
    try std.testing.expectEqual(@as(usize, 0), pipe.wait_calls);
}

test "gzip pump decode allocation count stays bounded" {
    if (!decompress.supportsZlib())
        return error.SkipZigTest;

    // A gzip member that expands about 186 times (44 encoded bytes to 8192
    // decoded), pushed through the pump in two wire chunks, stays within ten
    // allocations. Each push that produces output may reserve its
    // destination, grow it once, copy when `toOwnedSlice` cannot shrink in
    // place, and grow the body's chunk list; reallocating per decode step
    // would exceed the bound at once. Only allocations are counted: decoding
    // through a scratch buffer adds copies, not allocations, and would pass.
    const gzip_bomb_8k_a = [_]u8{
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x02, 0x03, 0xed, 0xc1, 0x01, 0x0d, 0x00, 0x00,
        0x00, 0xc2, 0xa0, 0xac, 0xef, 0x5f, 0xc2, 0x1c,
        0x6e, 0x40, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0xef, 0x06, 0xd5, 0x66, 0x6f, 0x0d,
        0x00, 0x20, 0x00, 0x00,
    };

    var body = fetch_body.Body.initOpen(std.testing.allocator, identity(88), null);
    defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);
    defer _ = collectReleasedCredits(&body);

    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = counting.allocator();

    var pump = try stream_pump.Pump.initWithLimits(.gzip, try (stream_pump.Limits{
        .max_decoded_bytes = 16 * 1024,
        .max_encoded_bytes = gzip_bomb_8k_a.len,
        .max_pending_decoded_bytes = 16 * 1024,
    }).normalized());
    defer pump.deinit(allocator);

    const split = 20;
    const first = try pump.appendHttp1DataAvailable(allocator, &body, gzip_bomb_8k_a[0..split], .none);
    try std.testing.expectEqual(@as(usize, split), first.consumed);
    const second = try pump.appendHttp1DataAvailable(allocator, &body, gzip_bomb_8k_a[split..], .none);
    try std.testing.expectEqual(@as(usize, gzip_bomb_8k_a.len - split), second.consumed);
    const finish = try pump.finishHttp1Available(allocator, &body, .none);
    try std.testing.expect(finish.complete);

    try std.testing.expectEqual(@as(usize, 8192), body.queuedDecodedBytes());
    try std.testing.expect(counting.alloc_index <= 10);
}

const NeverCanceled = struct {
    fn isCanceled(_: NeverCanceled) bool {
        return false;
    }
};

fn accumulateH2CreditBytes(
    credits: []const body_credit.Handle,
    source_id: u64,
    stream_id: u32,
    update_stream_window: bool,
) !usize {
    var released: usize = 0;
    for (credits) |credit| {
        switch (credit) {
            .h2_data => |h2| {
                try std.testing.expectEqual(source_id, h2.source_id);
                try std.testing.expectEqual(stream_id, h2.stream_id);
                try std.testing.expectEqual(update_stream_window, h2.update_stream_window);
                released += h2.encoded_bytes;
            },
            .none, .h1_resume => return error.ExpectedH2Credit,
        }
    }
    return released;
}

const Http1BackpressurePipe = struct {
    allocator: std.mem.Allocator,
    queued: usize,
    wait_calls: usize = 0,
    completed: bool = false,
    bytes: std.array_list.Aligned(u8, null) = .empty,

    fn init(allocator: std.mem.Allocator, queued: usize) Http1BackpressurePipe {
        return .{ .allocator = allocator, .queued = queued };
    }

    fn deinit(self: *Http1BackpressurePipe) void {
        self.bytes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn queuedDecodedBytes(self: *Http1BackpressurePipe) usize {
        return self.queued + self.bytes.items.len;
    }

    pub fn waitForDecodedCapacity(
        self: *Http1BackpressurePipe,
        bytes: usize,
        max_pending_decoded_bytes: usize,
        cancel_probe: NeverCanceled,
    ) !void {
        try std.testing.expect(!cancel_probe.isCanceled());
        const needed_capacity = @min(bytes, max_pending_decoded_bytes);
        try std.testing.expect(self.queuedDecodedBytes() > max_pending_decoded_bytes -| needed_capacity);
        self.wait_calls += 1;
        self.queued = 0;
    }

    pub fn appendOwnedChunk(
        self: *Http1BackpressurePipe,
        allocator: std.mem.Allocator,
        bytes: []u8,
        credit: body_credit.Handle,
    ) !bool {
        _ = allocator;
        try std.testing.expect(credit == .none);
        defer self.allocator.free(bytes);
        try self.bytes.appendSlice(self.allocator, bytes);
        return true;
    }

    pub fn complete(self: *Http1BackpressurePipe) bool {
        self.completed = true;
        return true;
    }
};

const Http1NoWaitPipe = struct {
    queued: usize,

    pub fn queuedDecodedBytes(self: *Http1NoWaitPipe) usize {
        return self.queued;
    }

    pub fn appendOwnedChunk(
        self: *Http1NoWaitPipe,
        allocator: std.mem.Allocator,
        bytes: []u8,
        credit: body_credit.Handle,
    ) !bool {
        _ = self;
        _ = credit;
        allocator.free(bytes);
        return true;
    }
};

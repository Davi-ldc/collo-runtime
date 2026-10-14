//! The stream pump and the HTTP/2 encoded sink against a real response
//! queue: HTTP/2 credits per chunk, the encoded cap, the queue's byte limit,
//! the HTTP/1 identity path at the watermark with its resume credit and at
//! the decoded budget, the compressed paths at the budget, deflate's
//! zlib-or-raw sniff, and the allocation count of a decode. The HTTP/1
//! continuation that drives the pump from a wire is covered by
//! `egress/tests/client/http1/` in `egress-test`.

const std = @import("std");
const egress_client = @import("collo_egress_client");
const test_support = @import("support.zig");
const body_credit = egress_client.core.body_credit;
const stream_pump = egress_client.core.stream_pump;
const ResponseQueue = egress_client.core.ResponseQueue;
const transport = egress_client.transport;
const network = egress_client.network;
const expectH2Credit = test_support.expectH2Credit;
const gzip_hello_world = test_support.gzip_hello_world;

const identity: egress_client.core.FetchBodyIdentity = .{
    .request_id = 10,
    .request_generation = 20,
    .fetch_id = 30,
    .body_id = 40,
};

test "h2 encoded sink queues each payload with its encoded-byte credit" {
    var queue = ResponseQueue.init(identity, 16);
    defer drainAndDeinit(&queue);

    var sink = stream_pump.H2EncodedSink{ .max_encoded_bytes = 16 };

    const bytes = try std.testing.allocator.dupe(u8, "abc");
    try std.testing.expect(!try sink.appendH2DataOwned(std.testing.allocator, &queue, 701, 21, bytes, 3, true));
    try std.testing.expect(queue.armPull());
    const pull = queue.pull(std.testing.allocator);
    defer std.testing.allocator.free(pull.bytes.?);
    try std.testing.expectEqualStrings("abc", pull.bytes.?);
    try expectH2Credit(pull.credit, 701, 21, 3, true);
}

test "default h2 advertised stream window fits the response queue" {
    const config = transport.Config{ .network = network.public_https };
    const h2_limits = try config.http2Limits().normalized();
    var queue = ResponseQueue.init(identity, config.max_response_body_bytes);
    defer drainAndDeinit(&queue);

    var sink = stream_pump.H2EncodedSink{
        .max_encoded_bytes = (try config.streamPumpLimits().normalized()).max_encoded_bytes,
    };

    const window_len: usize = @intCast(h2_limits.stream_receive_window);
    const bytes = try std.testing.allocator.alloc(u8, window_len);
    @memset(bytes, 'x');
    try std.testing.expect(!try sink.appendH2DataOwned(
        std.testing.allocator,
        &queue,
        702,
        23,
        bytes,
        h2_limits.stream_receive_window,
        true,
    ));
    try std.testing.expectEqual(window_len, queue.queuedBytes());
}

test "h2 encoded sink refuses bytes past the encoded cap" {
    var queue = ResponseQueue.init(identity, 64);
    defer drainAndDeinit(&queue);

    var sink = stream_pump.H2EncodedSink{ .max_encoded_bytes = 4 };

    const bytes = try std.testing.allocator.dupe(u8, "abcde");
    try std.testing.expectError(
        error.FetchResponseEncodedTooLarge,
        sink.appendH2DataOwned(std.testing.allocator, &queue, 704, 24, bytes, 5, true),
    );
    try std.testing.expectEqual(@as(usize, 0), queue.queuedBytes());
}

test "h2 encoded sink frees owned data when the queue refuses the append" {
    var queue = ResponseQueue.init(identity, 2);
    defer drainAndDeinit(&queue);

    var sink = stream_pump.H2EncodedSink{ .max_encoded_bytes = 16 };

    const bytes = try std.testing.allocator.dupe(u8, "abc");
    try std.testing.expectError(
        error.MaxBufferExceeded,
        sink.appendH2DataOwned(std.testing.allocator, &queue, 705, 25, bytes, 3, true),
    );
    try std.testing.expectEqual(@as(usize, 0), queue.queuedBytes());
}

test "identity pump pauses at the watermark and the append that fills it carries the resume credit" {
    var queue = ResponseQueue.init(identity, null);
    defer drainAndDeinit(&queue);
    var pump = try stream_pump.Pump.init(.identity, .{
        .max_decoded_bytes = 16,
        .max_pending_decoded_bytes = 4,
    });
    defer pump.deinit();
    const resume_credit = body_credit.h1Resume(9);

    const first = try pump.appendHttp1DataAvailable(std.testing.allocator, &queue, "abcdef", resume_credit);
    try std.testing.expectEqual(@as(usize, 4), first.consumed);
    try std.testing.expect(first.paused);

    // A full watermark takes nothing and pauses.
    const blocked = try pump.appendHttp1DataAvailable(std.testing.allocator, &queue, "ef", resume_credit);
    try std.testing.expectEqual(@as(usize, 0), blocked.consumed);
    try std.testing.expect(blocked.paused);

    try std.testing.expect(queue.armPull());
    const pull = queue.pull(std.testing.allocator);
    defer std.testing.allocator.free(pull.bytes.?);
    try std.testing.expectEqualStrings("abcd", pull.bytes.?);
    switch (pull.credit) {
        .h1_resume => |credit| try std.testing.expectEqual(@as(u64, 9), credit.source_id),
        .none, .h2_data => return error.ExpectedResumeCredit,
    }

    // Two bytes into four of room fill nothing, so they carry no credit.
    const rest = try pump.appendHttp1DataAvailable(std.testing.allocator, &queue, "ef", resume_credit);
    try std.testing.expectEqual(@as(usize, 2), rest.consumed);
    try std.testing.expect(!rest.paused);
    try std.testing.expect(queue.armPull());
    const next = queue.pull(std.testing.allocator);
    defer std.testing.allocator.free(next.bytes.?);
    try std.testing.expect(next.credit.isNone());
}

test "identity pump fails a body past its decoded budget" {
    var queue = ResponseQueue.init(identity, null);
    defer drainAndDeinit(&queue);
    var pump = try stream_pump.Pump.init(.identity, .{
        .max_decoded_bytes = 4,
        .max_pending_decoded_bytes = 4,
    });
    defer pump.deinit();

    _ = try pump.appendHttp1DataAvailable(std.testing.allocator, &queue, "abcd", .none);
    var collected: std.array_list.Aligned(u8, null) = .empty;
    defer collected.deinit(std.testing.allocator);
    _ = try drainBytes(&queue, &collected);
    try std.testing.expectError(
        error.FetchResponseTooLarge,
        pump.appendHttp1DataAvailable(std.testing.allocator, &queue, "e", .none),
    );
}

test "http1 compressed trailer can finish exactly at decoded budget" {
    var queue = ResponseQueue.init(identity, null);
    defer drainAndDeinit(&queue);
    var pump = try stream_pump.Pump.init(.gzip, .{
        .max_decoded_bytes = 11,
        .max_encoded_bytes = gzip_hello_world.len,
        .max_pending_decoded_bytes = 64,
    });
    defer pump.deinit();

    const without_trailer = gzip_hello_world[0 .. gzip_hello_world.len - 8];
    const head = try pump.appendHttp1DataAvailable(std.testing.allocator, &queue, without_trailer, .none);
    try std.testing.expectEqual(without_trailer.len, head.consumed);
    const trailer = try pump.appendHttp1DataAvailable(std.testing.allocator, &queue, gzip_hello_world[gzip_hello_world.len - 8 ..], .none);
    try std.testing.expectEqual(@as(usize, 8), trailer.consumed);
    try std.testing.expect((try pump.finishHttp1Available(std.testing.allocator, &queue, .none)).complete);

    var collected: std.array_list.Aligned(u8, null) = .empty;
    defer collected.deinit(std.testing.allocator);
    try std.testing.expect(try drainBytes(&queue, &collected));
    try std.testing.expectEqualStrings("hello world", collected.items);
}

test "deflate sniffs zlib-wrapped and raw streams alike" {
    // Both wire shapes of `Content-Encoding: deflate` decode: the conformant
    // zlib wrapper (RFC 1950) and the bare RFC 1951 stream that a long tail
    // of origins sends, which browsers and curl also tell apart by sniffing.
    const vectors = [_][]const u8{
        &test_support.zlib_deflate_hello_world,
        &test_support.raw_deflate_hello_world,
    };
    for (vectors) |vector| {
        var queue = ResponseQueue.init(identity, null);
        defer drainAndDeinit(&queue);
        var pump = try stream_pump.Pump.init(.deflate, .{
            .max_decoded_bytes = 11,
            .max_encoded_bytes = vector.len,
            .max_pending_decoded_bytes = 64,
        });
        defer pump.deinit();

        _ = try pump.appendHttp1DataAvailable(std.testing.allocator, &queue, vector, .none);
        try std.testing.expect((try pump.finishHttp1Available(std.testing.allocator, &queue, .none)).complete);
        var collected: std.array_list.Aligned(u8, null) = .empty;
        defer collected.deinit(std.testing.allocator);
        try std.testing.expect(try drainBytes(&queue, &collected));
        try std.testing.expectEqualStrings("hello world", collected.items);
    }
}

test "deflate sniff survives a one-byte first chunk" {
    // The sniff needs two bytes; a single-byte first read must be held and
    // replayed once the second byte decides the wrapping.
    const vector: []const u8 = &test_support.raw_deflate_hello_world;
    var queue = ResponseQueue.init(identity, null);
    defer drainAndDeinit(&queue);
    var pump = try stream_pump.Pump.init(.deflate, .{
        .max_decoded_bytes = 11,
        .max_encoded_bytes = vector.len,
        .max_pending_decoded_bytes = 64,
    });
    defer pump.deinit();

    for (vector) |byte|
        _ = try pump.appendHttp1DataAvailable(std.testing.allocator, &queue, &.{byte}, .none);
    try std.testing.expect((try pump.finishHttp1Available(std.testing.allocator, &queue, .none)).complete);
    var collected: std.array_list.Aligned(u8, null) = .empty;
    defer collected.deinit(std.testing.allocator);
    try std.testing.expect(try drainBytes(&queue, &collected));
    try std.testing.expectEqualStrings("hello world", collected.items);
}

test "deflate stream shorter than the sniff is truncated, not accepted" {
    var queue = ResponseQueue.init(identity, null);
    defer drainAndDeinit(&queue);
    var pump = try stream_pump.Pump.init(.deflate, .{
        .max_decoded_bytes = 11,
        .max_encoded_bytes = 16,
        .max_pending_decoded_bytes = 64,
    });
    defer pump.deinit();

    _ = try pump.appendHttp1DataAvailable(std.testing.allocator, &queue, &.{0x78}, .none);
    try std.testing.expectError(
        error.FetchResponseTruncated,
        pump.finishHttp1Available(std.testing.allocator, &queue, .none),
    );
}

test "http1 compressed append fails when exhausted budget needs more output" {
    var queue = ResponseQueue.init(identity, null);
    defer drainAndDeinit(&queue);
    var pump = try stream_pump.Pump.init(.gzip, .{
        .max_decoded_bytes = 10,
        .max_encoded_bytes = gzip_hello_world.len,
        .max_pending_decoded_bytes = 64,
    });
    defer pump.deinit();

    try std.testing.expectError(
        error.FetchResponseTooLarge,
        pump.appendHttp1DataAvailable(std.testing.allocator, &queue, gzip_hello_world[0..], .none),
    );
    var collected: std.array_list.Aligned(u8, null) = .empty;
    defer collected.deinit(std.testing.allocator);
    _ = try drainBytes(&queue, &collected);
    try std.testing.expectEqualStrings("hello worl", collected.items);
}

test "gzip pump decode allocation count stays bounded" {
    // A gzip member that expands about 186 times (44 encoded bytes to 8192
    // decoded), pushed through the pump in two wire chunks, stays within ten
    // allocations. Each push that produces output may reserve its
    // destination, grow it once, copy when `toOwnedSlice` cannot shrink in
    // place, and grow the queue's chunk list; reallocating per decode step
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

    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = counting.allocator();
    var queue = ResponseQueue.init(identity, null);
    defer {
        queue.releaseQueued(allocator, {}, ignoreCredit);
        queue.deinit(allocator);
    }

    var pump = try stream_pump.Pump.init(.gzip, .{
        .max_decoded_bytes = 16 * 1024,
        .max_encoded_bytes = gzip_bomb_8k_a.len,
        .max_pending_decoded_bytes = 16 * 1024,
    });
    defer pump.deinit();

    const split = 20;
    const first = try pump.appendHttp1DataAvailable(allocator, &queue, gzip_bomb_8k_a[0..split], .none);
    try std.testing.expectEqual(@as(usize, split), first.consumed);
    const second = try pump.appendHttp1DataAvailable(allocator, &queue, gzip_bomb_8k_a[split..], .none);
    try std.testing.expectEqual(@as(usize, gzip_bomb_8k_a.len - split), second.consumed);
    const finish = try pump.finishHttp1Available(allocator, &queue, .none);
    try std.testing.expect(finish.complete);

    try std.testing.expectEqual(@as(usize, 8192), queue.queuedBytes());
    try std.testing.expect(counting.alloc_index <= 10);
}

/// Pulls every queued chunk into `out` and returns whether the queue then
/// reported its end.
fn drainBytes(queue: *ResponseQueue, out: *std.array_list.Aligned(u8, null)) !bool {
    while (true) {
        _ = queue.armPull();
        const pull = queue.pull(std.testing.allocator);
        if (pull.bytes) |bytes| {
            defer std.testing.allocator.free(bytes);
            try out.appendSlice(std.testing.allocator, bytes);
        }
        if (pull.done)
            return true;
        if (pull.failed or pull.isEmpty())
            return false;
    }
}

fn drainAndDeinit(queue: *ResponseQueue) void {
    queue.releaseQueued(std.testing.allocator, {}, ignoreCredit);
    queue.deinit(std.testing.allocator);
}

fn ignoreCredit(_: void, _: body_credit.Handle) void {}

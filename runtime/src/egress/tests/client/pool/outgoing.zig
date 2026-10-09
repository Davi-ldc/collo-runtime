//! Tests of the HTTP/2 pool's bounded outgoing buffer: it refuses a write that
//! would grow it past its budget, and a flush keeps unsent bytes across
//! partial writes and reports which readiness the transport is waiting for.

const std = @import("std");
const test_support = @import("support.zig");
const pool = test_support.pool;
const data_io = test_support.data_io;
const readiness = test_support.readiness;
const transport = test_support.transport;
const TestH2Origin = test_support.TestH2Origin;
const collo_test_h2_origin_start = test_support.collo_test_h2_origin_start;
const collo_test_h2_origin_stop = test_support.collo_test_h2_origin_stop;
const collo_test_h2_origin_last_error = test_support.collo_test_h2_origin_last_error;
const collo_test_h2_origin_stream_count = test_support.collo_test_h2_origin_stream_count;
const collo_test_h2_origin_selected_alpn = test_support.collo_test_h2_origin_selected_alpn;
const test_h2_origin_alpn_h2 = test_support.test_h2_origin_alpn_h2;
const test_h2_origin_alpn_http11 = test_support.test_h2_origin_alpn_http11;
const test_alpn_h2 = test_support.test_alpn_h2;
const routableLocalIpv4 = test_support.routableLocalIpv4;
const FakeWriteTransport = test_support.FakeWriteTransport;

test "bounded outgoing refuses writes before growing past its budget" {
    var outgoing = pool.BoundedOutgoing.init(std.testing.allocator, 8);
    defer outgoing.deinit();

    try outgoing.writer.writeAll("12345678");
    try std.testing.expectEqual(@as(usize, 8), outgoing.writer.end);
    try std.testing.expect(outgoing.writer.buffer.len <= 8);

    try std.testing.expectError(error.WriteFailed, outgoing.writer.writeAll("x"));
    try std.testing.expect(outgoing.hit_limit);
    try std.testing.expect(outgoing.writer.buffer.len <= 8);
    try std.testing.expectEqual(@as(usize, 8), outgoing.writer.end);
}

test "bounded outgoing grows from an already buffered prefix" {
    var outgoing = pool.BoundedOutgoing.init(std.testing.allocator, 8);
    defer outgoing.deinit();

    try outgoing.writer.writeAll("1234");
    try outgoing.writer.writeAll("56");
    try std.testing.expectEqualStrings("123456", outgoing.written());
    try std.testing.expect(outgoing.writer.buffer.len <= 8);
}

test "outgoing flush preserves unsent bytes across partial writes" {
    var outgoing = pool.BoundedOutgoing.init(std.testing.allocator, 64);
    defer outgoing.deinit();
    try outgoing.writer.writeAll("abcdef");
    var offset: usize = 0;
    var wait: ?transport.IoInterest = null;
    var wire = FakeWriteTransport{
        .max_chunk = 2,
        .wait_after_bytes = 4,
        .wait_interest = .write,
    };

    try pool.flushOutgoingBuffer(&outgoing, &offset, &wait, &wire);
    try std.testing.expectEqual(@as(usize, 4), wire.written);
    try std.testing.expectEqual(transport.IoInterest.write, wait.?);
    try std.testing.expectEqual(@as(usize, 0), offset);
    try std.testing.expectEqualStrings("ef", outgoing.written());

    wire.wait_after_bytes = null;
    try pool.flushOutgoingBuffer(&outgoing, &offset, &wait, &wire);
    try std.testing.expectEqual(@as(usize, 6), wire.written);
    try std.testing.expectEqual(@as(?transport.IoInterest, null), wait);
    try std.testing.expectEqual(@as(usize, 0), outgoing.written().len);
}

test "outgoing flush tracks TLS write wanting read readiness" {
    var outgoing = pool.BoundedOutgoing.init(std.testing.allocator, 64);
    defer outgoing.deinit();
    try outgoing.writer.writeAll("abc");
    var offset: usize = 0;
    var wait: ?transport.IoInterest = null;
    var wire = FakeWriteTransport{
        .max_chunk = 8,
        .wait_after_bytes = 0,
        .wait_interest = .read,
    };

    try pool.flushOutgoingBuffer(&outgoing, &offset, &wait, &wire);
    try std.testing.expectEqual(@as(usize, 0), wire.written);
    try std.testing.expectEqual(transport.IoInterest.read, wait.?);
    try std.testing.expectEqual(@as(usize, 0), offset);
    try std.testing.expectEqualStrings("abc", outgoing.written());
}

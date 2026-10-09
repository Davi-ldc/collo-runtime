//! The intrusive heap and the byte buffers of `collo_common_io`: heap order
//! across removal and reinsertion, the `StreamBuffer` cursor, compaction and
//! capacity release, and the limits `ByteBudget` and `MaxBuf` enforce. The
//! io_uring wrappers are tested in `io/`, whose `all.zig` collects this file.

const std = @import("std");
const common_io = @import("collo_common_io");

const TestNode = struct {
    heap: common_io.heap.IntrusiveHeapField(TestNode) = .{},
    priority: u32,
    id: u32,
};

const TestHeap = common_io.heap.IntrusiveHeap(TestNode, void, less);

fn less(_: void, a: *const TestNode, b: *const TestNode) bool {
    return if (a.priority == b.priority) a.id < b.id else a.priority < b.priority;
}

test "common io root exposes grouped utilities" {
    _ = common_io.heap;
    _ = common_io.buffer;
}

test "common io intrusive heap returns nodes by priority" {
    var nodes = [_]TestNode{
        .{ .priority = 30, .id = 3 },
        .{ .priority = 10, .id = 1 },
        .{ .priority = 20, .id = 2 },
    };
    var heap = try TestHeap.initCapacity(std.testing.allocator, {}, nodes.len);
    defer heap.deinit();

    for (&nodes) |*node|
        heap.insertAssumeCapacity(node);

    try std.testing.expectEqual(@as(usize, 3), heap.len());
    try std.testing.expectEqual(@as(u32, 1), heap.deleteMin().?.id);
    try std.testing.expectEqual(@as(u32, 2), heap.deleteMin().?.id);
    try std.testing.expectEqual(@as(u32, 3), heap.deleteMin().?.id);
    try std.testing.expect(heap.deleteMin() == null);
}

test "common io intrusive heap orders removes and reinserts nodes" {
    var nodes = [_]TestNode{
        .{ .priority = 30, .id = 3 },
        .{ .priority = 10, .id = 1 },
        .{ .priority = 20, .id = 2 },
    };
    var heap = try TestHeap.initCapacity(std.testing.allocator, {}, nodes.len);
    defer heap.deinit();

    for (&nodes) |*node|
        heap.insertAssumeCapacity(node);

    try std.testing.expect(heap.remove(&nodes[1]));
    nodes[1].priority = 5;
    try heap.insert(&nodes[1]);

    try std.testing.expectEqual(@as(u32, 1), heap.deleteMin().?.id);
    try std.testing.expectEqual(@as(u32, 2), heap.deleteMin().?.id);
    try std.testing.expectEqual(@as(u32, 3), heap.deleteMin().?.id);
}

test "common io intrusive heap removes arbitrary nodes and reinserts them" {
    var nodes = [_]TestNode{
        .{ .priority = 40, .id = 4 },
        .{ .priority = 10, .id = 1 },
        .{ .priority = 30, .id = 3 },
        .{ .priority = 20, .id = 2 },
    };
    var heap = try TestHeap.initCapacity(std.testing.allocator, {}, nodes.len);
    defer heap.deinit();

    for (&nodes) |*node|
        heap.insertAssumeCapacity(node);

    try std.testing.expect(heap.remove(&nodes[1]));
    try std.testing.expect(!nodes[1].heap.inserted());
    try std.testing.expectEqual(@as(u32, 2), heap.deleteMin().?.id);

    nodes[1].priority = 5;
    try heap.insert(&nodes[1]);
    try std.testing.expectEqual(@as(u32, 1), heap.deleteMin().?.id);
    try std.testing.expectEqual(@as(u32, 3), heap.deleteMin().?.id);
    try std.testing.expectEqual(@as(u32, 4), heap.deleteMin().?.id);
}

test "common io stream buffer writes advances and resets" {
    var buffer = common_io.buffer.StreamBuffer.init(std.testing.allocator, 64);
    defer buffer.deinit();

    try buffer.write("hello world");
    try std.testing.expectEqualStrings("hello world", buffer.slice());
    try buffer.advance(6);
    try std.testing.expectEqualStrings("world", buffer.slice());
    try std.testing.expectEqual(@as(usize, 5), buffer.size());
    try buffer.advance(5);
    try std.testing.expect(buffer.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), buffer.size());
}

test "common io stream buffer supports append consume compact and reset" {
    var buffer = common_io.buffer.StreamBuffer.init(std.testing.allocator, 64);
    defer buffer.deinit();

    try buffer.write("abcdef");
    try buffer.advance(2);
    buffer.compact();
    try std.testing.expectEqualStrings("cdef", buffer.slice());
    try std.testing.expectError(error.StreamBufferAdvancePastEnd, buffer.advance(5));
    try buffer.advance(4);
    try std.testing.expect(buffer.isEmpty());
}

test "common io stream buffer compacts consumed prefix" {
    var buffer = common_io.buffer.StreamBuffer.init(std.testing.allocator, 64);
    defer buffer.deinit();

    try buffer.write("abcdef");
    try buffer.advance(2);
    buffer.compact();
    try std.testing.expectEqualStrings("cdef", buffer.slice());
    try std.testing.expectEqual(@as(usize, 0), buffer.cursor);
}

test "common io stream buffer refuses to advance past buffered data" {
    var buffer = common_io.buffer.StreamBuffer.init(std.testing.allocator, 64);
    defer buffer.deinit();

    try buffer.write("abc");
    try std.testing.expectError(error.StreamBufferAdvancePastEnd, buffer.advance(4));
}

test "common io stream buffer releases oversized capacity on reset" {
    // The buffer is built with a retain capacity of one byte, so any growth
    // exceeds it and `reset` frees the allocation.
    var buffer = common_io.buffer.StreamBuffer.init(std.testing.allocator, 1);
    defer buffer.deinit();

    try buffer.write("abcdef");
    try std.testing.expect(buffer.capacity() > 1);
    buffer.reset();
    try std.testing.expectEqual(@as(usize, 0), buffer.capacity());
}

test "common io byte budget reserves and releases within limit" {
    var budget = common_io.buffer.ByteBudget.init(10);
    try budget.tryReserve(4);
    try std.testing.expectEqual(@as(u64, 4), budget.used);
    try std.testing.expectEqual(@as(u64, 6), budget.remaining().?);
    try budget.release(3);
    try std.testing.expectEqual(@as(u64, 1), budget.used);
}

test "common io byte budget rejects overflow exceeded and underflow" {
    var limited = common_io.buffer.ByteBudget.init(10);
    try std.testing.expectError(error.ByteBudgetExceeded, limited.tryReserve(11));
    try limited.tryReserve(10);
    try std.testing.expectError(error.ByteBudgetExceeded, limited.tryReserve(1));
    try std.testing.expectError(error.ByteBudgetUnderflow, limited.release(11));

    var unlimited = common_io.buffer.ByteBudget.init(null);
    unlimited.used = std.math.maxInt(u64);
    try std.testing.expectError(error.ByteBudgetOverflow, unlimited.tryReserve(1));
}

test "common io byte budget unlimited mode accepts reservations" {
    var budget = common_io.buffer.ByteBudget.init(null);
    try budget.tryReserve(1024);
    try std.testing.expect(budget.remaining() == null);
    try std.testing.expect(budget.available(std.math.maxInt(u64) - 1024));
}

test "common io max buf accepts exactly its limit" {
    var max_buf = common_io.buffer.MaxBuf.init(5);
    try max_buf.onBytes(2);
    try max_buf.onBytes(3);
    try std.testing.expectEqual(@as(u64, 5), max_buf.used());
    try std.testing.expectEqual(@as(u64, 0), max_buf.remaining().?);
    try std.testing.expect(!max_buf.exceeded);
}

test "common io max buf latches exceeded when the stream grows past limit" {
    var max_buf = common_io.buffer.MaxBuf.init(5);
    try max_buf.onBytes(5);
    try std.testing.expectError(error.MaxBufferExceeded, max_buf.onBytes(1));
    try std.testing.expect(max_buf.exceeded);
    try std.testing.expectEqual(@as(u64, 5), max_buf.used());
}

test "common io max buf supports unlimited streams" {
    var max_buf = common_io.buffer.MaxBuf.init(null);
    try max_buf.onBytes(1024 * 1024);
    try std.testing.expect(max_buf.remaining() == null);
    try std.testing.expect(!max_buf.exceeded);
}

test "common io byte budget and max buf fail closed at limits" {
    var budget = common_io.buffer.ByteBudget.init(10);
    try budget.tryReserve(10);
    try std.testing.expectError(error.ByteBudgetExceeded, budget.tryReserve(1));
    try budget.release(4);
    try std.testing.expectEqual(@as(u64, 6), budget.used);

    var max_buf = common_io.buffer.MaxBuf.init(3);
    try max_buf.onBytes(3);
    try std.testing.expectError(error.MaxBufferExceeded, max_buf.onBytes(1));
    try std.testing.expect(max_buf.exceeded);
}

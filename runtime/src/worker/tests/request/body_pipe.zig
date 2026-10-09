//! Covers the request body pipe (`request/incoming_body/pipe.zig`): bytes
//! buffered in order, the byte bound checked before storage grows, bytes
//! accounted ahead of materialization charged once, a single consumer, and a
//! failure that records its message and keeps the pending waiter. The ingress
//! framing around the pipe is covered by `incoming_body.zig`. Runs in
//! `worker-test`.

const std = @import("std");
const worker_request = @import("collo_worker_request");
const incoming_body_pipe = worker_request.incoming_body_pipe;

test "body pipe starts empty and finishes idempotently" {
    var pipe = incoming_body_pipe.Pipe.init(std.testing.allocator, 16, .empty);
    defer pipe.deinit();

    try std.testing.expect(pipe.isComplete());
    try std.testing.expectEqualStrings("", pipe.textSlice());
    pipe.finish();
    try std.testing.expect(pipe.isComplete());
    try std.testing.expectEqualStrings("", pipe.textSlice());
}

test "body pipe buffers bytes in order" {
    var pipe = incoming_body_pipe.Pipe.init(std.testing.allocator, 16, .open);
    defer pipe.deinit();

    try pipe.pushBytes("hello");
    try pipe.pushBytes(" world");
    pipe.finish();

    try std.testing.expect(pipe.isComplete());
    try std.testing.expectEqualStrings("hello world", pipe.textSlice());
}

test "body pipe checks max buffer before growing storage" {
    var pipe = incoming_body_pipe.Pipe.init(std.testing.allocator, 3, .open);
    defer pipe.deinit();

    try pipe.pushBytes("abc");
    const capacity_after_limit = pipe.bytes.capacity();

    try std.testing.expectError(error.MaxBufferExceeded, pipe.pushBytes("d"));
    try std.testing.expect(pipe.max_buf.exceeded);
    try std.testing.expectEqual(capacity_after_limit, pipe.bytes.capacity());
    try std.testing.expectEqual(@as(u64, 3), pipe.max_buf.used());
    pipe.finish();
    try std.testing.expectEqualStrings("abc", pipe.textSlice());
}

test "body pipe can materialize already accounted bytes without double charging" {
    var pipe = incoming_body_pipe.Pipe.init(std.testing.allocator, 6, .open);
    defer pipe.deinit();

    try pipe.accountBytes(3);
    try pipe.pushPreAccountedBytes("abc");
    try pipe.pushBytes("def");
    pipe.finish();

    try std.testing.expectEqual(@as(u64, 6), pipe.max_buf.used());
    try std.testing.expectEqualStrings("abcdef", pipe.textSlice());
}

test "body pipe allows one consumer" {
    var pipe = incoming_body_pipe.Pipe.init(std.testing.allocator, 16, .open);
    defer pipe.deinit();

    try pipe.beginConsume(.{ .task_id = 1, .deferred = .{} });
    try std.testing.expect(pipe.used);
    try std.testing.expect(pipe.hasPendingWaiter());
    try std.testing.expectError(
        error.RequestBodyAlreadyUsed,
        pipe.beginConsume(.{ .task_id = 2, .deferred = .{} }),
    );

    var waiter = pipe.takeWaiter().?;
    defer waiter.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 1), waiter.task_id);
}

test "body pipe releases blob waiter content type" {
    var pipe = incoming_body_pipe.Pipe.init(std.testing.allocator, 16, .open);
    defer pipe.deinit();

    // A blob waiter owns its content type; the testing allocator fails the
    // test if the pipe's `deinit` leaks it.
    const content_type = try std.testing.allocator.dupe(u8, "application/octet-stream");
    try pipe.beginConsume(.{
        .task_id = 1,
        .kind = .blob,
        .content_type = content_type,
        .deferred = .{},
    });
}

test "body pipe fail records error and keeps waiter available" {
    var pipe = incoming_body_pipe.Pipe.init(std.testing.allocator, 16, .open);
    defer pipe.deinit();

    try pipe.beginConsume(.{ .task_id = 7, .deferred = .{} });
    pipe.fail("bad body");

    try std.testing.expectEqual(incoming_body_pipe.State.errored, pipe.state);
    try std.testing.expectEqualStrings("bad body", pipe.error_message.?);

    var waiter = pipe.takeWaiter().?;
    defer waiter.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 7), waiter.task_id);
}

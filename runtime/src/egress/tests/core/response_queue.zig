//! The gateway's response queue without a transport: one chunk and its own
//! credit per pull, credit-only chunks, the arm that decides when a producer
//! wakes the loop and when a pull moves anything, the end and the failure
//! after the queued chunks, sticky failure, cancel, the byte limit, release
//! of every queued credit without allocating, and the reference count. The
//! pump that feeds a queue has its own file in this suite (`all.zig`).

const std = @import("std");
const test_support = @import("support.zig");
const response_queue = test_support.response_queue;
const identity = test_support.identity;
const h2Credit = test_support.h2Credit;
const expectH2Credit = test_support.expectH2Credit;
const collectReleasedCredits = test_support.collectReleasedCredits;

const ResponseQueue = response_queue.ResponseQueue;

fn ownedBytes(text: []const u8) ![]u8 {
    return std.testing.allocator.dupe(u8, text);
}

/// Frees a pull's bytes; the caller checked them first.
fn freePull(pull: response_queue.Pull) void {
    if (pull.bytes) |bytes|
        std.testing.allocator.free(bytes);
}

test "an armed queue moves one chunk with its own credit per pull and disarms" {
    var queue = ResponseQueue.init(identity(1), null);
    defer queue.deinit(std.testing.allocator);

    try std.testing.expect(!try queue.appendOwnedChunk(std.testing.allocator, try ownedBytes("abc"), h2Credit(1, 11, 3, true)));
    try std.testing.expect(!try queue.appendOwnedChunk(std.testing.allocator, try ownedBytes("de"), h2Credit(1, 11, 2, false)));
    try std.testing.expectEqual(@as(usize, 5), queue.queuedBytes());

    try std.testing.expect(queue.armPull());
    const first = queue.pull(std.testing.allocator);
    defer freePull(first);
    try std.testing.expectEqualStrings("abc", first.bytes.?);
    try expectH2Credit(first.credit, 1, 11, 3, true);
    try std.testing.expect(first.disarmed);
    try std.testing.expectEqual(@as(usize, 2), queue.queuedBytes());

    // The arm went with the first chunk, so the next pull moves nothing
    // until the loop arms again.
    try std.testing.expect(queue.pull(std.testing.allocator).isEmpty());
    try std.testing.expect(queue.armPull());
    const second = queue.pull(std.testing.allocator);
    defer freePull(second);
    try std.testing.expectEqualStrings("de", second.bytes.?);
    try expectH2Credit(second.credit, 1, 11, 2, false);
    try std.testing.expectEqual(@as(usize, 0), queue.queuedBytes());
}

test "credit-only chunks come out one per pull ahead of the data and keep the arm" {
    var queue = ResponseQueue.init(identity(2), null);
    defer queue.deinit(std.testing.allocator);

    try std.testing.expect(!try queue.appendOwnedChunk(std.testing.allocator, &.{}, h2Credit(2, 1, 1, false)));
    try std.testing.expect(!try queue.appendOwnedChunk(std.testing.allocator, try ownedBytes("abc"), h2Credit(2, 1, 3, true)));
    // Empty bytes without a credit carry nothing and queue nothing.
    try std.testing.expect(!try queue.appendOwnedChunk(std.testing.allocator, &.{}, .none));

    try std.testing.expect(queue.armPull());
    const credit_only = queue.pull(std.testing.allocator);
    try std.testing.expect(credit_only.bytes == null);
    try expectH2Credit(credit_only.credit, 2, 1, 1, false);
    try std.testing.expect(!credit_only.disarmed);

    const data = queue.pull(std.testing.allocator);
    defer freePull(data);
    try std.testing.expectEqualStrings("abc", data.bytes.?);
    try expectH2Credit(data.credit, 2, 1, 3, true);
    try std.testing.expect(data.disarmed);
    try std.testing.expect(queue.pull(std.testing.allocator).isEmpty());
}

test "a pull never allocates" {
    var queue = ResponseQueue.init(identity(3), null);
    defer queue.deinit(std.testing.allocator);
    try std.testing.expect(!try queue.appendOwnedChunk(std.testing.allocator, &.{}, h2Credit(3, 1, 1, false)));
    try std.testing.expect(!try queue.appendOwnedChunk(std.testing.allocator, try ownedBytes("abc"), h2Credit(3, 1, 3, true)));

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expect(queue.armPull());
    _ = queue.pull(failing.allocator());
    const data = queue.pull(failing.allocator());
    defer freePull(data);
    try std.testing.expectEqualStrings("abc", data.bytes.?);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
}

test "a producer event wakes the loop only while the queue is armed" {
    var queue = ResponseQueue.init(identity(4), null);
    defer queue.deinit(std.testing.allocator);

    // Unarmed: the append wakes nothing, and arming reports the chunk.
    try std.testing.expect(!try queue.appendOwnedChunk(std.testing.allocator, try ownedBytes("a"), .none));
    try std.testing.expect(queue.armPull());
    const first = queue.pull(std.testing.allocator);
    defer freePull(first);
    try std.testing.expectEqualStrings("a", first.bytes.?);

    // Armed on an empty queue: arming finds nothing, and the next append,
    // and then the end, each ask for a wake until a pull takes the arm.
    try std.testing.expect(!queue.armPull());
    try std.testing.expect(try queue.appendOwnedChunk(std.testing.allocator, try ownedBytes("b"), .none));
    try std.testing.expect(queue.complete());
    const second = queue.pull(std.testing.allocator);
    defer freePull(second);
    try std.testing.expectEqualStrings("b", second.bytes.?);
    try std.testing.expect(!queue.complete());
}

test "a complete queue answers done only after its queued chunks, and disarms" {
    var queue = ResponseQueue.init(identity(5), null);
    defer queue.deinit(std.testing.allocator);
    try std.testing.expect(!try queue.appendOwnedChunk(std.testing.allocator, try ownedBytes("abc"), .none));
    try std.testing.expect(!queue.complete());

    try std.testing.expect(queue.armPull());
    const data = queue.pull(std.testing.allocator);
    defer freePull(data);
    try std.testing.expect(!data.done);
    try std.testing.expect(queue.armPull());
    const end = queue.pull(std.testing.allocator);
    try std.testing.expect(end.done);
    try std.testing.expect(end.disarmed);
    try std.testing.expect(end.bytes == null);
    try std.testing.expectError(error.FetchBodyNotWritable, queue.appendOwnedChunk(std.testing.allocator, &.{}, h2Credit(5, 1, 1, false)));
}

// A failed queue used to answer a chunk without a credit with an empty
// pull, which the gateway's drain reads as nothing to do, so the fetch hung.
test "a failed queue hands out every queued credit without its bytes, skipping chunks without one, then answers failed" {
    var queue = ResponseQueue.init(identity(6), null);
    defer queue.deinit(std.testing.allocator);
    try std.testing.expect(!try queue.appendOwnedChunk(std.testing.allocator, try ownedBytes("abc"), h2Credit(6, 1, 3, false)));
    try std.testing.expect(!try queue.appendOwnedChunk(std.testing.allocator, try ownedBytes("plain"), .none));
    try std.testing.expect(!try queue.appendOwnedChunk(std.testing.allocator, try ownedBytes("de"), h2Credit(6, 1, 2, true)));
    try std.testing.expect(queue.armPull());
    try std.testing.expect(queue.fail(std.testing.allocator, "upstream reset"));

    const first = queue.pull(std.testing.allocator);
    try std.testing.expect(first.bytes == null);
    try expectH2Credit(first.credit, 6, 1, 3, false);
    const second = queue.pull(std.testing.allocator);
    try std.testing.expect(second.bytes == null);
    try expectH2Credit(second.credit, 6, 1, 2, true);
    try std.testing.expectEqual(@as(usize, 0), queue.queuedBytes());
    const end = queue.pull(std.testing.allocator);
    try std.testing.expect(end.failed);
    try std.testing.expect(end.disarmed);
    try std.testing.expectEqualStrings("upstream reset", queue.failureMessage().?);
}

test "fail is sticky, never fails a complete queue, and still fails without memory for its message" {
    var queue = ResponseQueue.init(identity(7), null);
    defer queue.deinit(std.testing.allocator);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    _ = queue.fail(failing.allocator(), "first");
    try std.testing.expectEqual(response_queue.State.failed, queue.state);
    try std.testing.expect(queue.failureMessage() == null);
    _ = queue.fail(std.testing.allocator, "second");
    try std.testing.expect(queue.failureMessage() == null);

    var complete = ResponseQueue.init(identity(8), null);
    defer complete.deinit(std.testing.allocator);
    _ = complete.complete();
    _ = complete.fail(std.testing.allocator, "late");
    try std.testing.expectEqual(response_queue.State.complete, complete.state);
    try std.testing.expect(complete.failureMessage() == null);
}

// The loop reads the producer's end as the engine letting go of a fetch it
// stopped, so its cancel must leave that end to the producer and make sure
// the end wakes it.
test "cancel refuses later appends, leaves the producer's end to the producer and makes that end wake the loop" {
    var queue = ResponseQueue.init(identity(9), null);
    defer queue.deinit(std.testing.allocator);
    try std.testing.expect(!try queue.appendOwnedChunk(std.testing.allocator, try ownedBytes("abc"), h2Credit(9, 1, 3, false)));

    // Unarmed and open: the producer has not ended it.
    try std.testing.expect(!queue.cancel());
    try std.testing.expectEqual(response_queue.State.open, queue.state);
    try std.testing.expect(!queue.producerEnded());
    try std.testing.expectError(error.FetchBodyNotWritable, queue.appendOwnedChunk(std.testing.allocator, &.{}, h2Credit(9, 1, 1, false)));

    // The engine's end after the cancel asks for a wake and is the producer's.
    try std.testing.expect(queue.fail(std.testing.allocator, "FetchAborted"));
    try std.testing.expect(queue.producerEnded());
    try std.testing.expectEqualStrings("FetchAborted", queue.failureMessage().?);
    try std.testing.expectEqual(@as(usize, 1), collectReleasedCredits(&queue).len);

    // A queue the producer already ended reports it to the cancel.
    var complete = ResponseQueue.init(identity(13), null);
    defer complete.deinit(std.testing.allocator);
    _ = complete.complete();
    try std.testing.expect(complete.cancel());
    try std.testing.expectEqual(response_queue.State.complete, complete.state);
}

test "a canceled queue's pull hands out the queued credits without their bytes, then answers failed" {
    var queue = ResponseQueue.init(identity(14), null);
    defer queue.deinit(std.testing.allocator);
    try std.testing.expect(!try queue.appendOwnedChunk(std.testing.allocator, try ownedBytes("abc"), h2Credit(14, 1, 3, false)));
    try std.testing.expect(!try queue.appendOwnedChunk(std.testing.allocator, try ownedBytes("plain"), .none));
    try std.testing.expect(!queue.cancel());

    const first = queue.pull(std.testing.allocator);
    try std.testing.expect(first.bytes == null);
    try expectH2Credit(first.credit, 14, 1, 3, false);
    const end = queue.pull(std.testing.allocator);
    try std.testing.expect(end.failed);
    try std.testing.expectEqual(@as(usize, 0), queue.queuedBytes());
}

test "an append past the byte limit is refused, leaves its bytes to the caller and the queue open" {
    var queue = ResponseQueue.init(identity(10), 4);
    defer queue.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?u64, 4), queue.maxBytes());
    try std.testing.expect(!try queue.appendOwnedChunk(std.testing.allocator, try ownedBytes("abc"), .none));
    const refused = try ownedBytes("de");
    defer std.testing.allocator.free(refused);
    try std.testing.expectError(error.MaxBufferExceeded, queue.appendOwnedChunk(std.testing.allocator, refused, .none));
    try std.testing.expectEqual(response_queue.State.open, queue.state);
    try std.testing.expectEqual(@as(usize, 3), queue.queuedBytes());
    try std.testing.expectEqual(@as(usize, 0), collectReleasedCredits(&queue).len);
}

test "releaseQueued frees every chunk and passes each credit on without allocating" {
    var queue = ResponseQueue.init(identity(11), null);
    defer queue.deinit(std.testing.allocator);
    try std.testing.expect(!try queue.appendOwnedChunk(std.testing.allocator, try ownedBytes("abc"), h2Credit(11, 1, 3, false)));
    try std.testing.expect(!try queue.appendOwnedChunk(std.testing.allocator, try ownedBytes("de"), .none));
    try std.testing.expect(!try queue.appendOwnedChunk(std.testing.allocator, &.{}, h2Credit(11, 1, 0, true)));
    // A pulled prefix stays out of the release.
    try std.testing.expect(queue.armPull());
    const first = queue.pull(std.testing.allocator);
    defer freePull(first);
    try expectH2Credit(first.credit, 11, 1, 3, false);

    const released = collectReleasedCredits(&queue);
    try std.testing.expectEqual(@as(usize, 1), released.len);
    try expectH2Credit(released.slice()[0], 11, 1, 0, true);
    try std.testing.expectEqual(@as(usize, 0), queue.queuedBytes());
}

test "a queue the engine and the loop both hold is freed at the last release" {
    const queue = try std.testing.allocator.create(ResponseQueue);
    queue.* = ResponseQueue.init(identity(12), null);
    queue.retain();
    try std.testing.expect(!try queue.appendOwnedChunk(std.testing.allocator, try ownedBytes("abc"), h2Credit(12, 1, 3, true)));
    queue.release(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), collectReleasedCredits(queue).len);
    // The testing allocator's leak check is the assertion that this frees it.
    queue.release(std.testing.allocator);
}

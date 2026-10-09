//! Fetch body behavior without a transport: whole-body and pull reads, one
//! credit per read, borrowed extents released once after the last view,
//! allocation failures that leave chunks queued and tee views unchanged,
//! sticky failure and cancel override, queued-chunk release without
//! allocation, and tee reference counts. The pump and the decoder have their
//! own files in this suite (see `all.zig`).

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
const gzip_hello_world = test_support.gzip_hello_world;

test "body credit none helper" {
    const none: body_credit.Handle = .none;
    try std.testing.expect(none.isNone());
}

test "completed fetch body can be borrowed without consuming" {
    var body = try fetch_body.Body.initComplete(std.testing.allocator, identity(1), "payload", null);
    defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);

    try std.testing.expectEqual(fetch_body.State.complete, body.state);
    try std.testing.expectEqualStrings("payload", body.borrowCompleteBytes().?);
    try std.testing.expect(!body.consumed);
}

test "open fetch body read becomes ready only after completion" {
    var body = fetch_body.Body.initOpen(std.testing.allocator, identity(2), null);
    defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);

    try std.testing.expect(!try body.beginConsume(try waiter(std.testing.allocator)));
    try std.testing.expect(!body.isReadyForWaiter());
    try std.testing.expect(body.borrowCompleteBytes() == null);

    try body.append("hel");
    try body.append("lo");
    try std.testing.expect(body.complete());

    try std.testing.expect(body.isReadyForWaiter());
    try std.testing.expectEqualStrings("hello", body.borrowCompleteBytes().?);
    var second_waiter = try waiter(std.testing.allocator);
    try std.testing.expectError(error.FetchBodyAlreadyUsed, body.beginConsume(second_waiter));
    second_waiter.deinit(std.testing.allocator);
}

test "streamed fetch body drains chunks before terminal resolution" {
    var body = fetch_body.Body.initOpen(std.testing.allocator, identity(7), null);
    defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);

    try std.testing.expect(!try body.beginConsume(try waiter(std.testing.allocator)));
    const first = try std.testing.allocator.dupe(u8, "hel");
    try std.testing.expect(try body.appendOwnedChunk(std.testing.allocator, first, h2Credit(7, 1, 3, true)));
    try std.testing.expectEqual(@as(usize, 3), body.queuedDecodedBytes());

    var first_drain = try body.drainReadyForWaiter(std.testing.allocator);
    defer first_drain.deinit(std.testing.allocator);
    try std.testing.expect(!first_drain.terminal);
    try std.testing.expect(first_drain.waiter == null);
    try std.testing.expectEqual(@as(usize, 1), first_drain.credits.len);
    try std.testing.expectEqualStrings("hel", body.bytes.slice());
    try std.testing.expectEqual(@as(usize, 0), body.queuedDecodedBytes());

    const second = try std.testing.allocator.dupe(u8, "lo");
    try std.testing.expect(try body.appendOwnedChunk(std.testing.allocator, second, .none));
    try std.testing.expectEqual(@as(usize, 2), body.queuedDecodedBytes());
    try std.testing.expect(body.complete());

    var final_drain = try body.drainReadyForWaiter(std.testing.allocator);
    defer final_drain.deinit(std.testing.allocator);
    try std.testing.expect(final_drain.terminal);
    try std.testing.expect(final_drain.waiter != null);
    try std.testing.expectEqualStrings("hello", body.borrowCompleteBytes().?);
}

test "pull fetch body releases exactly one h2 credit per read" {
    var body = fetch_body.Body.initOpen(std.testing.allocator, identity(8), null);
    defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);

    const first = try std.testing.allocator.dupe(u8, "abc");
    try std.testing.expect(!try body.appendOwnedChunk(std.testing.allocator, first, h2Credit(8, 11, 3, true)));
    const second = try std.testing.allocator.dupe(u8, "de");
    try std.testing.expect(!try body.appendOwnedChunk(std.testing.allocator, second, h2Credit(8, 11, 2, false)));
    try std.testing.expectEqual(@as(usize, 5), body.queuedDecodedBytes());

    try std.testing.expect(try body.beginPull(.{ .deferred = null }));
    var first_pull = try body.drainReadyForPull(std.testing.allocator);
    defer first_pull.deinit(std.testing.allocator);
    try std.testing.expect(first_pull.waiter != null);
    try std.testing.expect(!first_pull.done);
    try std.testing.expectEqualStrings("abc", first_pull.bytes.bytes());
    try std.testing.expectEqual(@as(usize, 1), first_pull.credits.slice().len);
    try std.testing.expectEqual(@as(usize, 2), body.queuedDecodedBytes());
    try expectH2Credit(first_pull.credits.slice()[0], 8, 11, 3, true);

    try std.testing.expect(try body.beginPull(.{ .deferred = null }));
    var second_pull = try body.drainReadyForPull(std.testing.allocator);
    defer second_pull.deinit(std.testing.allocator);
    try std.testing.expect(second_pull.waiter != null);
    try std.testing.expect(!second_pull.done);
    try std.testing.expectEqualStrings("de", second_pull.bytes.bytes());
    try std.testing.expectEqual(@as(usize, 1), second_pull.credits.slice().len);
    try std.testing.expectEqual(@as(usize, 0), body.queuedDecodedBytes());
    try expectH2Credit(second_pull.credits.slice()[0], 8, 11, 2, false);
}

test "pull drain allocation failure leaves owned chunk queued" {
    var body = fetch_body.Body.initOpen(std.testing.allocator, identity(82), null);
    defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);

    // Three credit-bearing chunks, two empty credit-only carriers ahead of
    // the data chunk, exceed `PullCredits.inline_slots`, so the drain needs a
    // heap allocation; failing it proves nothing is popped before the
    // allocations succeed.
    try std.testing.expect(!try body.appendOwnedChunk(
        std.testing.allocator,
        &.{},
        h2Credit(82, 1, 1, false),
    ));
    try std.testing.expect(!try body.appendOwnedChunk(
        std.testing.allocator,
        &.{},
        h2Credit(82, 1, 2, false),
    ));
    const chunk = try std.testing.allocator.dupe(u8, "abc");
    try std.testing.expect(!try body.appendOwnedChunk(
        std.testing.allocator,
        chunk,
        h2Credit(82, 1, 3, true),
    ));
    try std.testing.expect(try body.beginPull(.{ .deferred = null }));

    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    try std.testing.expectError(error.OutOfMemory, body.drainReadyForPull(failing.allocator()));
    try std.testing.expectEqual(@as(usize, 3), body.queuedDecodedBytes());

    var pull = try body.drainReadyForPull(std.testing.allocator);
    defer pull.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("abc", pull.bytes.bytes());
    try std.testing.expectEqual(@as(usize, 3), pull.credits.slice().len);
    try expectH2Credit(pull.credits.slice()[2], 82, 1, 3, true);
}

test "pull drain with a single credit allocates nothing" {
    // Credit slots up to `PullCredits.inline_slots` are inline, so the
    // gateway's usual pull, one owned chunk with one HTTP/2 credit, allocates
    // nothing. The allocator fails its first allocation, so a heap credit
    // array would fail the drain.
    var body = fetch_body.Body.initOpen(std.testing.allocator, identity(86), null);
    defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);

    const chunk = try std.testing.allocator.dupe(u8, "abc");
    try std.testing.expect(!try body.appendOwnedChunk(
        std.testing.allocator,
        chunk,
        h2Credit(86, 1, 3, true),
    ));
    try std.testing.expect(try body.beginPull(.{ .deferred = null }));

    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    var pull = try body.drainReadyForPull(failing.allocator());
    try std.testing.expectEqualStrings("abc", pull.bytes.bytes());
    try std.testing.expectEqual(@as(usize, 1), pull.credits.slice().len);
    try expectH2Credit(pull.credits.slice()[0], 86, 1, 3, true);
    pull.deinit(std.testing.allocator);
}

test "borrowed fetch body pull settles before releasing the source" {
    var body = fetch_body.Body.initOpen(std.testing.allocator, identity(80), null);
    defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);

    var recorder = BorrowedReleaseRecorder{};
    var source = [_]u8{ 'a', 'b', 'c' };
    try std.testing.expect(!try body.appendBorrowedChunk(std.testing.allocator, .{
        .bytes = source[0..],
        .release = .{
            .context = &recorder,
            .seq = 42,
            .len = source.len,
            .release_fn = borrowedReleaseRecorder,
        },
    }, .none));

    try std.testing.expect(try body.beginPull(.{ .deferred = null }));
    var pull = try body.drainReadyForPull(std.testing.allocator);

    // The drain hands out the borrowed bytes themselves, without a copy, and
    // the release fires only at `deinit`, after the consumer copied them out.
    try std.testing.expect(pull.bytes.isBorrowed());
    try std.testing.expectEqualStrings("abc", pull.bytes.bytes());
    source[0] = 'z';
    try std.testing.expectEqualStrings("zbc", pull.bytes.bytes());
    try std.testing.expectEqual(@as(usize, 0), recorder.count);

    pull.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), recorder.count);
    try std.testing.expectEqual(@as(u64, 42), recorder.seq);
    try std.testing.expectEqual(@as(usize, 3), recorder.len);
}

test "pull drain of a creditless borrowed chunk allocates nothing" {
    var body = fetch_body.Body.initOpen(std.testing.allocator, identity(83), null);
    defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);

    var recorder = BorrowedReleaseRecorder{};
    var source = [_]u8{ 'a', 'b', 'c' };
    try std.testing.expect(!try body.appendBorrowedChunk(
        std.testing.allocator,
        .{
            .bytes = source[0..],
            .release = .{
                .context = &recorder,
                .seq = 43,
                .len = source.len,
                .release_fn = borrowedReleaseRecorder,
            },
        },
        .none,
    ));
    try std.testing.expect(try body.beginPull(.{ .deferred = null }));

    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    var pull = try body.drainReadyForPull(failing.allocator());
    try std.testing.expect(pull.bytes.isBorrowed());
    try std.testing.expectEqualStrings("abc", pull.bytes.bytes());
    try std.testing.expectEqual(@as(usize, 0), body.queuedDecodedBytes());
    try std.testing.expectEqual(@as(usize, 0), recorder.count);

    pull.deinit(failing.allocator());
    try std.testing.expectEqual(@as(usize, 1), recorder.count);
    try std.testing.expectEqual(@as(u64, 43), recorder.seq);
}

test "borrowed fetch body consume releases source after materializing complete bytes" {
    var body = fetch_body.Body.initOpen(std.testing.allocator, identity(81), null);
    defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);

    var recorder = BorrowedReleaseRecorder{};
    var source = [_]u8{ 'x', 'y', 'z' };
    try std.testing.expect(!try body.beginConsume(try waiter(std.testing.allocator)));
    try std.testing.expect(try body.appendBorrowedChunk(std.testing.allocator, .{
        .bytes = source[0..],
        .release = .{
            .context = &recorder,
            .seq = 100,
            .len = source.len,
            .release_fn = borrowedReleaseRecorder,
        },
    }, .none));
    try std.testing.expect(body.complete());

    var drain = try body.drainReadyForWaiter(std.testing.allocator);
    defer drain.deinit(std.testing.allocator);

    try std.testing.expect(drain.terminal);
    try std.testing.expectEqualStrings("xyz", body.borrowCompleteBytes().?);
    try std.testing.expectEqual(@as(usize, 1), recorder.count);
    try std.testing.expectEqual(@as(u64, 100), recorder.seq);
    try std.testing.expectEqual(@as(usize, 3), recorder.len);
}

test "cancel allocation failure preserves existing error message" {
    var body = fetch_body.Body.initOpen(std.testing.allocator, identity(84), null);
    defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);

    _ = try body.fail(std.testing.allocator, "old failure");

    var failing_cancel = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    try std.testing.expectError(
        error.OutOfMemory,
        body.cancel(failing_cancel.allocator(), "new cancel", null),
    );
    try std.testing.expectEqualStrings("old failure", body.failureMessage().?);

    var failing_view_cancel = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    try std.testing.expectError(
        error.OutOfMemory,
        body.cancelViewOnly(failing_view_cancel.allocator(), "new view cancel", null),
    );
    try std.testing.expectEqualStrings("old failure", body.failureMessage().?);
}

test "cancel allocation failures preserve tee state across fail indices" {
    for (0..8) |fail_index| {
        var root = fetch_body.Body.initOpen(std.testing.allocator, identity(108 + fail_index), null);
        defer root.deinitAfterQueuedResourcesReleased(std.testing.allocator);

        const first = try root.cloneBranch(std.testing.allocator, identity(208 + fail_index));
        defer first.releaseAfterQueuedResourcesReleased(std.testing.allocator);
        defer first.detachTeeLinks(std.testing.allocator);
        const second = try root.cloneBranch(std.testing.allocator, identity(308 + fail_index));
        defer second.releaseAfterQueuedResourcesReleased(std.testing.allocator);
        defer second.detachTeeLinks(std.testing.allocator);

        _ = try root.fail(std.testing.allocator, "old failure");

        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        const result = root.cancel(failing.allocator(), "new cancel", null);
        if (result) |_| {
            try std.testing.expect(root.isCanceled());
            try std.testing.expect(first.isCanceled());
            try std.testing.expect(second.isCanceled());
            try std.testing.expectEqualStrings("new cancel", root.failureMessage().?);
            try std.testing.expectEqualStrings("new cancel", first.failureMessage().?);
            try std.testing.expectEqualStrings("new cancel", second.failureMessage().?);
        } else |err| switch (err) {
            error.OutOfMemory => {
                try std.testing.expect(!root.isCanceled());
                try std.testing.expect(!first.isCanceled());
                try std.testing.expect(!second.isCanceled());
                try std.testing.expectEqualStrings("old failure", root.failureMessage().?);
                try std.testing.expectEqualStrings("old failure", first.failureMessage().?);
                try std.testing.expectEqualStrings("old failure", second.failureMessage().?);
            },
            else => return err,
        }
    }
}

test "cancel view allocation failures preserve old message across fail indices" {
    for (0..4) |fail_index| {
        var body = fetch_body.Body.initOpen(std.testing.allocator, identity(118 + fail_index), null);
        defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);

        _ = try body.fail(std.testing.allocator, "old failure");

        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        const result = body.cancelViewOnly(failing.allocator(), "new cancel", null);
        if (result) |_| {
            try std.testing.expect(body.isCanceled());
            try std.testing.expectEqualStrings("new cancel", body.failureMessage().?);
        } else |err| switch (err) {
            error.OutOfMemory => {
                try std.testing.expect(!body.isCanceled());
                try std.testing.expectEqualStrings("old failure", body.failureMessage().?);
            },
            else => return err,
        }
    }
}

test "fail is sticky: the first failure wins and a repeat fail allocates nothing" {
    var root = fetch_body.Body.initOpen(std.testing.allocator, identity(128), null);
    defer root.deinitAfterQueuedResourcesReleased(std.testing.allocator);

    const first = try root.cloneBranch(std.testing.allocator, identity(228));
    defer first.releaseAfterQueuedResourcesReleased(std.testing.allocator);
    defer first.detachTeeLinks(std.testing.allocator);
    const second = try root.cloneBranch(std.testing.allocator, identity(328));
    defer second.releaseAfterQueuedResourcesReleased(std.testing.allocator);
    defer second.detachTeeLinks(std.testing.allocator);

    _ = try root.fail(std.testing.allocator, "old failure");

    // A body that already failed keeps its first failure (sticky, like the
    // TLA-verified settlement states), so the repeat changes nothing; an
    // allocator that fails its first allocation proves it allocates nothing.
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    _ = try root.fail(failing.allocator(), "new failure");
    try std.testing.expectEqualStrings("old failure", root.failureMessage().?);
    try std.testing.expectEqualStrings("old failure", first.failureMessage().?);
    try std.testing.expectEqualStrings("old failure", second.failureMessage().?);
}

test "fail never retro-fails a complete body" {
    var body = fetch_body.Body.initOpen(std.testing.allocator, identity(129), null);
    defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);

    try body.append("done");
    try std.testing.expect(!body.complete());

    // The bytes fully arrived, so a late failure, such as a gateway
    // disconnect after END_STREAM, must not make the reader reject data it
    // already holds. Only `cancel`, a user abort, overrides a complete body.
    _ = try body.fail(std.testing.allocator, "late failure");
    try std.testing.expect(!body.isFailed());
    try std.testing.expectEqual(@as(?[]const u8, null), body.failureMessage());
}

test "first fail under allocation failure leaves the body open and retriable" {
    var root = fetch_body.Body.initOpen(std.testing.allocator, identity(130), null);
    defer root.deinitAfterQueuedResourcesReleased(std.testing.allocator);

    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    try std.testing.expectError(error.OutOfMemory, root.fail(failing.allocator(), "first failure"));
    try std.testing.expect(!root.isFailed());

    _ = try root.fail(std.testing.allocator, "first failure");
    try std.testing.expectEqualStrings("first failure", root.failureMessage().?);
}

test "failed waiter drain clears queued decoded byte accounting" {
    var body = fetch_body.Body.initOpen(std.testing.allocator, identity(85), null);
    defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);

    try std.testing.expect(!try body.beginConsume(try waiter(std.testing.allocator)));
    const chunk = try std.testing.allocator.dupe(u8, "leaked");
    try std.testing.expect(try body.appendOwnedChunk(
        std.testing.allocator,
        chunk,
        h2Credit(85, 1, 6, true),
    ));
    try std.testing.expectEqual(@as(usize, 6), body.queuedDecodedBytes());
    try std.testing.expect(try body.fail(std.testing.allocator, "network failed"));

    var drain = try body.drainReadyForWaiter(std.testing.allocator);
    defer drain.deinit(std.testing.allocator);
    try std.testing.expect(drain.failed);
    try std.testing.expect(drain.terminal);
    try std.testing.expect(drain.waiter != null);
    try std.testing.expectEqual(@as(usize, 0), body.queuedDecodedBytes());
    try std.testing.expectEqual(@as(usize, 1), drain.credits.len);
    try expectH2Credit(drain.credits[0], 85, 1, 6, true);
}

test "waiter drain allocation failures leave owned chunks queued" {
    for (0..4) |fail_index| {
        var body = fetch_body.Body.initOpen(std.testing.allocator, identity(138 + fail_index), null);
        defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);

        try std.testing.expect(!try body.beginConsume(try waiter(std.testing.allocator)));
        const chunk = try std.testing.allocator.dupe(u8, "owned");
        try std.testing.expect(try body.appendOwnedChunk(
            std.testing.allocator,
            chunk,
            h2Credit(138 + fail_index, 1, 5, true),
        ));
        try std.testing.expect(body.complete());

        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        const result = body.drainReadyForWaiter(failing.allocator());
        if (result) |result_drain| {
            var drain = result_drain;
            defer drain.deinit(std.testing.allocator);
            try std.testing.expect(drain.terminal);
            try std.testing.expectEqual(@as(usize, 0), body.queuedDecodedBytes());
        } else |err| switch (err) {
            error.OutOfMemory => {
                try std.testing.expectEqual(@as(usize, 5), body.queuedDecodedBytes());
                var drain = try body.drainReadyForWaiter(std.testing.allocator);
                defer drain.deinit(std.testing.allocator);
                try std.testing.expect(drain.terminal);
                try std.testing.expectEqual(@as(usize, 1), drain.credits.len);
            },
            else => return err,
        }
    }
}

test "waiter drain allocation failures leave borrowed chunks queued" {
    for (0..4) |fail_index| {
        var body = fetch_body.Body.initOpen(std.testing.allocator, identity(148 + fail_index), null);
        defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);

        var recorder = BorrowedReleaseRecorder{};
        var source = [_]u8{ 'b', 'o', 'r', 'r', 'o', 'w' };
        try std.testing.expect(!try body.beginConsume(try waiter(std.testing.allocator)));
        try std.testing.expect(try body.appendBorrowedChunk(
            std.testing.allocator,
            .{
                .bytes = source[0..],
                .release = .{
                    .context = &recorder,
                    .seq = 148 + fail_index,
                    .len = source.len,
                    .release_fn = borrowedReleaseRecorder,
                },
            },
            h2Credit(148 + fail_index, 1, source.len, true),
        ));
        try std.testing.expect(body.complete());

        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        const result = body.drainReadyForWaiter(failing.allocator());
        if (result) |result_drain| {
            var drain = result_drain;
            defer drain.deinit(std.testing.allocator);
            try std.testing.expect(drain.terminal);
            try std.testing.expectEqual(@as(usize, 1), recorder.count);
        } else |err| switch (err) {
            error.OutOfMemory => {
                try std.testing.expectEqual(@as(usize, 0), recorder.count);
                try std.testing.expectEqual(@as(usize, source.len), body.queuedDecodedBytes());
                var drain = try body.drainReadyForWaiter(std.testing.allocator);
                defer drain.deinit(std.testing.allocator);
                try std.testing.expect(drain.terminal);
                try std.testing.expectEqual(@as(usize, 1), recorder.count);
                try std.testing.expectEqual(@as(usize, 1), drain.credits.len);
            },
            else => return err,
        }
    }
}

test "tee waiter drains release a latched borrowed chunk only from the last view" {
    // The waiter drain sizes its borrowed-release array with
    // `hasBorrowedRelease`, an upper bound: a tee-latched borrow's take
    // yields null for every holder but the last. So the first view's drain
    // fires no release and the second view's fires exactly one.
    var root = fetch_body.Body.initOpen(std.testing.allocator, identity(160), null);
    defer root.deinitAfterQueuedResourcesReleased(std.testing.allocator);

    var recorder = BorrowedReleaseRecorder{};
    var source = [_]u8{ 't', 'e', 'e' };
    try std.testing.expect(!try root.appendBorrowedChunk(std.testing.allocator, .{
        .bytes = source[0..],
        .release = .{
            .context = &recorder,
            .seq = 160,
            .len = source.len,
            .release_fn = borrowedReleaseRecorder,
        },
    }, .none));

    const branch = try root.cloneBranch(std.testing.allocator, identity(260));
    defer branch.releaseAfterQueuedResourcesReleased(std.testing.allocator);
    defer branch.detachTeeLinks(std.testing.allocator);

    try std.testing.expect(try root.beginConsume(try waiter(std.testing.allocator)));
    var root_drain = try root.drainReadyForWaiter(std.testing.allocator);
    defer root_drain.deinit(std.testing.allocator);
    try std.testing.expect(!root_drain.terminal);
    try std.testing.expectEqualStrings("tee", root.bytes.slice());
    // The clone still holds the shared borrow.
    try std.testing.expectEqual(@as(usize, 0), recorder.count);

    try std.testing.expect(try branch.beginConsume(try waiter(std.testing.allocator)));
    var branch_drain = try branch.drainReadyForWaiter(std.testing.allocator);
    defer branch_drain.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), recorder.count);
    try std.testing.expectEqual(@as(u64, 160), recorder.seq);
    try std.testing.expectEqual(@as(usize, source.len), recorder.len);
}

test "tee append frees duplicated branch bytes when append fails" {
    for (0..6) |fail_index| {
        var body = fetch_body.Body.initOpen(std.testing.allocator, identity(90 + fail_index), null);
        defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);
        defer _ = test_support.collectReleasedCredits(&body);

        const branch = try body.cloneBranch(std.testing.allocator, identity(190 + fail_index));
        defer branch.releaseAfterQueuedResourcesReleased(std.testing.allocator);
        defer branch.detachTeeLinks(std.testing.allocator);
        defer _ = test_support.collectReleasedCredits(branch);

        const bytes = try std.testing.allocator.dupe(u8, "tee");
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        if (body.appendOwnedChunk(failing.allocator(), bytes, .none)) |_| {
            // The body owns bytes on success.
        } else |err| switch (err) {
            error.OutOfMemory => std.testing.allocator.free(bytes),
            else => return err,
        }
    }
}

test "clone branch allocation failures leave credited root chunk drainable" {
    for (0..10) |fail_index| {
        var root = fetch_body.Body.initOpen(std.testing.allocator, identity(158 + fail_index), null);
        defer root.deinitAfterQueuedResourcesReleased(std.testing.allocator);

        const chunk = try std.testing.allocator.dupe(u8, "clone");
        try std.testing.expect(!try root.appendOwnedChunk(
            std.testing.allocator,
            chunk,
            h2Credit(158 + fail_index, 1, 5, true),
        ));

        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        const result = root.cloneBranch(failing.allocator(), identity(258 + fail_index));
        if (result) |branch| {
            const root_released = test_support.collectReleasedCredits(&root);
            try std.testing.expectEqual(@as(usize, 0), root_released.len);

            var branch_released = test_support.collectReleasedCredits(branch);
            try std.testing.expectEqual(@as(usize, 1), branch_released.len);
            try expectH2Credit(branch_released.slice()[0], 158 + fail_index, 1, 5, true);

            branch.detachTeeLinks(std.testing.allocator);
            branch.releaseAfterQueuedResourcesReleased(std.testing.allocator);
        } else |err| switch (err) {
            error.OutOfMemory => {
                try std.testing.expectEqual(@as(usize, 5), root.queuedDecodedBytes());
                var released = test_support.collectReleasedCredits(&root);
                try std.testing.expectEqual(@as(usize, 1), released.len);
                try expectH2Credit(released.slice()[0], 158 + fail_index, 1, 5, true);
            },
            else => return err,
        }
    }
}

test "tee append rejects credit when all linked views are released" {
    var body = fetch_body.Body.initOpen(std.testing.allocator, identity(96), null);
    defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);

    const branch = try body.cloneBranch(std.testing.allocator, identity(196));
    defer branch.releaseAfterQueuedResourcesReleased(std.testing.allocator);
    defer branch.detachTeeLinks(std.testing.allocator);

    body.markViewReleased(std.testing.allocator);
    branch.markViewReleased(std.testing.allocator);

    const bytes = try std.testing.allocator.dupe(u8, "unused");
    try std.testing.expectError(
        error.FetchBodyNoActiveViews,
        body.appendOwnedChunk(std.testing.allocator, bytes, h2Credit(96, 1, 6, true)),
    );
    std.testing.allocator.free(bytes);
}

test "clone branch append failure does not retain root" {
    const root = try std.testing.allocator.create(fetch_body.Body);
    root.* = fetch_body.Body.initOpen(std.testing.allocator, identity(97), null);

    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 1 },
    );
    try std.testing.expectError(
        error.OutOfMemory,
        root.cloneBranch(failing.allocator(), identity(197)),
    );
    root.releaseAfterQueuedResourcesReleased(std.testing.allocator);
}

test "tee fail allocation failure leaves every view open" {
    for (0..4) |fail_index| {
        var root = fetch_body.Body.initOpen(std.testing.allocator, identity(106 + fail_index), null);
        defer root.deinitAfterQueuedResourcesReleased(std.testing.allocator);

        const first = try root.cloneBranch(std.testing.allocator, identity(206 + fail_index));
        defer first.releaseAfterQueuedResourcesReleased(std.testing.allocator);
        defer first.detachTeeLinks(std.testing.allocator);
        const second = try root.cloneBranch(std.testing.allocator, identity(306 + fail_index));
        defer second.releaseAfterQueuedResourcesReleased(std.testing.allocator);
        defer second.detachTeeLinks(std.testing.allocator);

        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        try std.testing.expectError(
            error.OutOfMemory,
            root.fail(failing.allocator(), "network failed"),
        );
        try std.testing.expectEqual(fetch_body.State.open, root.state);
        try std.testing.expectEqual(fetch_body.State.open, first.state);
        try std.testing.expectEqual(fetch_body.State.open, second.state);
        try std.testing.expect(root.failureMessage() == null);
        try std.testing.expect(first.failureMessage() == null);
        try std.testing.expect(second.failureMessage() == null);
    }
}

test "cancel no alloc fails all tee views consistently" {
    var root = fetch_body.Body.initOpen(std.testing.allocator, identity(107), null);
    defer root.deinitAfterQueuedResourcesReleased(std.testing.allocator);

    const branch = try root.cloneBranch(std.testing.allocator, identity(207));
    defer branch.releaseAfterQueuedResourcesReleased(std.testing.allocator);
    defer branch.detachTeeLinks(std.testing.allocator);

    try std.testing.expect(!root.cancelNoAlloc());
    try std.testing.expect(root.isCanceled());
    try std.testing.expect(branch.isCanceled());
    try std.testing.expect(root.isFailed());
    try std.testing.expect(branch.isFailed());
}

test "gateway disconnect drain preserves pending pull waiter" {
    var body = fetch_body.Body.initOpen(std.testing.allocator, identity(98), null);
    defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);

    const bytes = try std.testing.allocator.dupe(u8, "abc");
    try std.testing.expect(!try body.appendOwnedChunk(
        std.testing.allocator,
        bytes,
        h2Credit(98, 1, 3, true),
    ));
    try std.testing.expect(try body.beginPull(.{ .deferred = null }));

    var released = test_support.ReleasedCredits{};
    body.releaseQueuedChunksPreservingWaitersCallback(
        std.testing.allocator,
        &released,
        test_support.collectReleasedCreditForTest,
    );
    try std.testing.expectEqual(@as(usize, 1), released.len);
    try expectH2Credit(released.slice()[0], 98, 1, 3, true);

    try std.testing.expect(try body.fail(std.testing.allocator, "gateway disconnected"));
    var pull = try body.drainReadyForPull(std.testing.allocator);
    defer pull.deinit(std.testing.allocator);
    try std.testing.expect(pull.failed);
    try std.testing.expect(pull.waiter != null);
    try std.testing.expectEqual(@as(usize, 0), pull.credits.slice().len);
}

test "release queued chunks callback does not allocate" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();

    var body = fetch_body.Body.initOpen(allocator, identity(102), null);
    defer body.deinitAfterQueuedResourcesReleased(allocator);

    const bytes = try allocator.dupe(u8, "abc");
    try std.testing.expect(!try body.appendOwnedChunk(
        allocator,
        bytes,
        h2Credit(102, 1, 3, true),
    ));

    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;

    var released = test_support.ReleasedCredits{};
    body.releaseQueuedChunksCallback(
        allocator,
        &released,
        test_support.collectReleasedCreditForTest,
    );
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 1), released.len);
    try expectH2Credit(released.slice()[0], 102, 1, 3, true);
    try std.testing.expectEqual(@as(usize, 0), body.queuedDecodedBytes());
}

test "release queued borrowed chunk releases source and credit once" {
    var body = fetch_body.Body.initOpen(std.testing.allocator, identity(103), null);
    defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);

    var recorder = BorrowedReleaseRecorder{};
    var source = [_]u8{ 'b', 'o', 'd', 'y' };
    try std.testing.expect(!try body.appendBorrowedChunk(
        std.testing.allocator,
        .{
            .bytes = source[0..],
            .release = .{
                .context = &recorder,
                .seq = 103,
                .len = source.len,
                .release_fn = borrowedReleaseRecorder,
            },
        },
        h2Credit(103, 1, source.len, true),
    ));

    var released = test_support.ReleasedCredits{};
    body.releaseQueuedChunksCallback(
        std.testing.allocator,
        &released,
        test_support.collectReleasedCreditForTest,
    );

    try std.testing.expectEqual(@as(usize, 1), recorder.count);
    try std.testing.expectEqual(@as(u64, 103), recorder.seq);
    try std.testing.expectEqual(@as(usize, source.len), recorder.len);
    try std.testing.expectEqual(@as(usize, 1), released.len);
    try expectH2Credit(released.slice()[0], 103, 1, source.len, true);
}

test "release queued tee chunks emits shared credit only from last view" {
    var root = fetch_body.Body.initOpen(std.testing.allocator, identity(104), null);
    defer root.deinitAfterQueuedResourcesReleased(std.testing.allocator);

    const branch = try root.cloneBranch(std.testing.allocator, identity(204));
    defer branch.releaseAfterQueuedResourcesReleased(std.testing.allocator);
    defer branch.detachTeeLinks(std.testing.allocator);

    const bytes = try std.testing.allocator.dupe(u8, "tee");
    try std.testing.expect(!try root.appendOwnedChunk(
        std.testing.allocator,
        bytes,
        h2Credit(104, 1, 3, true),
    ));

    var root_released = test_support.ReleasedCredits{};
    root.releaseQueuedChunksCallback(
        std.testing.allocator,
        &root_released,
        test_support.collectReleasedCreditForTest,
    );
    try std.testing.expectEqual(@as(usize, 0), root_released.len);

    var branch_released = test_support.ReleasedCredits{};
    branch.releaseQueuedChunksCallback(
        std.testing.allocator,
        &branch_released,
        test_support.collectReleasedCreditForTest,
    );
    try std.testing.expectEqual(@as(usize, 1), branch_released.len);
    try expectH2Credit(branch_released.slice()[0], 104, 1, 3, true);
}

test "release queued borrowed tee chunks releases source only from last view" {
    var root = fetch_body.Body.initOpen(std.testing.allocator, identity(105), null);
    defer root.deinitAfterQueuedResourcesReleased(std.testing.allocator);

    const branch = try root.cloneBranch(std.testing.allocator, identity(205));
    defer branch.releaseAfterQueuedResourcesReleased(std.testing.allocator);
    defer branch.detachTeeLinks(std.testing.allocator);

    var recorder = BorrowedReleaseRecorder{};
    var source = [_]u8{ 't', 'e', 'e' };
    try std.testing.expect(!try root.appendBorrowedChunk(
        std.testing.allocator,
        .{
            .bytes = source[0..],
            .release = .{
                .context = &recorder,
                .seq = 105,
                .len = source.len,
                .release_fn = borrowedReleaseRecorder,
            },
        },
        h2Credit(105, 1, source.len, true),
    ));

    var root_released = test_support.ReleasedCredits{};
    root.releaseQueuedChunksCallback(
        std.testing.allocator,
        &root_released,
        test_support.collectReleasedCreditForTest,
    );
    try std.testing.expectEqual(@as(usize, 0), root_released.len);
    try std.testing.expectEqual(@as(usize, 0), recorder.count);

    var branch_released = test_support.ReleasedCredits{};
    branch.releaseQueuedChunksCallback(
        std.testing.allocator,
        &branch_released,
        test_support.collectReleasedCreditForTest,
    );
    try std.testing.expectEqual(@as(usize, 1), branch_released.len);
    try expectH2Credit(branch_released.slice()[0], 105, 1, source.len, true);
    try std.testing.expectEqual(@as(usize, 1), recorder.count);
    try std.testing.expectEqual(@as(u64, 105), recorder.seq);
}

test "released tee source continues forwarding chunks to active clone" {
    var root = fetch_body.Body.initOpen(std.testing.allocator, identity(99), null);
    defer root.deinitAfterQueuedResourcesReleased(std.testing.allocator);

    const branch = try root.cloneBranch(std.testing.allocator, identity(199));
    defer branch.releaseAfterQueuedResourcesReleased(std.testing.allocator);
    defer branch.detachTeeLinks(std.testing.allocator);

    root.markViewReleased(std.testing.allocator);
    try std.testing.expect(!try branch.beginPull(.{ .deferred = null }));

    const bytes = try std.testing.allocator.dupe(u8, "clone");
    try std.testing.expect(try root.appendOwnedChunk(
        std.testing.allocator,
        bytes,
        h2Credit(99, 1, 5, true),
    ));
    try std.testing.expectEqual(@as(usize, 0), root.queuedDecodedBytes());
    try std.testing.expectEqual(@as(usize, 5), branch.queuedDecodedBytes());

    var pull = try branch.drainReadyForPull(std.testing.allocator);
    defer pull.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("clone", pull.bytes.bytes());
    try std.testing.expectEqual(@as(usize, 1), pull.credits.slice().len);
    try expectH2Credit(pull.credits.slice()[0], 99, 1, 5, true);
}

test "released tee source forwards borrowed chunks to active clone without early release" {
    var root = fetch_body.Body.initOpen(std.testing.allocator, identity(106), null);
    defer root.deinitAfterQueuedResourcesReleased(std.testing.allocator);

    const branch = try root.cloneBranch(std.testing.allocator, identity(206));
    defer branch.releaseAfterQueuedResourcesReleased(std.testing.allocator);
    defer branch.detachTeeLinks(std.testing.allocator);

    root.markViewReleased(std.testing.allocator);
    try std.testing.expect(!try branch.beginPull(.{ .deferred = null }));

    var recorder = BorrowedReleaseRecorder{};
    var source = [_]u8{ 'c', 'l', 'o', 'n', 'e' };
    try std.testing.expect(try root.appendBorrowedChunk(
        std.testing.allocator,
        .{
            .bytes = source[0..],
            .release = .{
                .context = &recorder,
                .seq = 106,
                .len = source.len,
                .release_fn = borrowedReleaseRecorder,
            },
        },
        h2Credit(106, 1, source.len, true),
    ));
    try std.testing.expectEqual(@as(usize, 0), root.queuedDecodedBytes());
    try std.testing.expectEqual(@as(usize, source.len), branch.queuedDecodedBytes());
    try std.testing.expectEqual(@as(usize, 0), recorder.count);

    var pull = try branch.drainReadyForPull(std.testing.allocator);
    try std.testing.expectEqualStrings("clone", pull.bytes.bytes());
    try std.testing.expectEqual(@as(usize, 1), pull.credits.slice().len);
    try expectH2Credit(pull.credits.slice()[0], 106, 1, source.len, true);
    // The borrow release rides the drain and fires at deinit.
    try std.testing.expectEqual(@as(usize, 0), recorder.count);
    pull.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), recorder.count);
    try std.testing.expectEqual(@as(u64, 106), recorder.seq);
}

test "root side tee detach releases root refs retained by branches" {
    const root = try std.testing.allocator.create(fetch_body.Body);
    root.* = fetch_body.Body.initOpen(std.testing.allocator, identity(100), null);

    const branch = try root.cloneBranch(std.testing.allocator, identity(200));
    root.detachTeeLinks(std.testing.allocator);
    root.releaseAfterQueuedResourcesReleased(std.testing.allocator);
    branch.releaseAfterQueuedResourcesReleased(std.testing.allocator);
}

test "tee root holds one reference per linked branch" {
    const root = try std.testing.allocator.create(fetch_body.Body);
    root.* = fetch_body.Body.initOpen(std.testing.allocator, identity(110), null);

    const first = try root.cloneBranch(std.testing.allocator, identity(210));
    const second = try root.cloneBranch(std.testing.allocator, identity(310));

    try std.testing.expectEqual(@as(u32, 3), root.refs.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 2), first.refs.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 2), second.refs.load(.monotonic));

    root.detachTeeLinks(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 1), root.refs.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 1), first.refs.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 1), second.refs.load(.monotonic));
    try std.testing.expect(!first.isTeeBranch());
    try std.testing.expect(!second.isTeeBranch());

    root.releaseAfterQueuedResourcesReleased(std.testing.allocator);
    first.releaseAfterQueuedResourcesReleased(std.testing.allocator);
    second.releaseAfterQueuedResourcesReleased(std.testing.allocator);
}

test "tee branch detach releases exactly one root reference" {
    var root = fetch_body.Body.initOpen(std.testing.allocator, identity(111), null);
    defer root.deinitAfterQueuedResourcesReleased(std.testing.allocator);

    const branch = try root.cloneBranch(std.testing.allocator, identity(211));
    defer branch.releaseAfterQueuedResourcesReleased(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 2), root.refs.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 2), branch.refs.load(.monotonic));

    branch.detachTeeLinks(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 1), root.refs.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 1), branch.refs.load(.monotonic));
    try std.testing.expect(!root.hasTeeBranches());
    try std.testing.expect(!branch.isTeeBranch());
}

test "no allocation fail wakes pending pull waiter" {
    var body = fetch_body.Body.initOpen(std.testing.allocator, identity(101), null);
    defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);

    try std.testing.expect(!try body.beginPull(.{ .deferred = null }));
    try std.testing.expect(body.failNoAlloc());

    var pull = try body.drainReadyForPull(std.testing.allocator);
    defer pull.deinit(std.testing.allocator);
    try std.testing.expect(pull.failed);
    try std.testing.expect(pull.waiter != null);
    try std.testing.expectEqual(@as(usize, 0), pull.credits.slice().len);
}

test "released view preserves pending pull waiter until settlement" {
    var body = fetch_body.Body.initOpen(std.testing.allocator, identity(102), null);
    defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);

    try std.testing.expect(!try body.beginPull(.{ .deferred = null }));
    body.markViewReleasedPreservingWaiters(std.testing.allocator);
    try std.testing.expect(body.hasPendingWaiter());
    try std.testing.expect(body.viewReleased());

    const bytes = try std.testing.allocator.dupe(u8, "pending");
    try std.testing.expect(try body.appendOwnedChunk(
        std.testing.allocator,
        bytes,
        h2Credit(102, 1, 7, true),
    ));

    var pull = try body.drainReadyForPull(std.testing.allocator);
    defer pull.deinit(std.testing.allocator);
    try std.testing.expect(pull.waiter != null);
    try std.testing.expectEqualStrings("pending", pull.bytes.bytes());
    try std.testing.expectEqual(@as(usize, 1), pull.credits.slice().len);
    try expectH2Credit(pull.credits.slice()[0], 102, 1, 7, true);
}

test "released view wakes preserved pending pull waiter on terminal state" {
    {
        var body = fetch_body.Body.initOpen(std.testing.allocator, identity(103), null);
        defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);

        try std.testing.expect(!try body.beginPull(.{ .deferred = null }));
        body.markViewReleasedPreservingWaiters(std.testing.allocator);
        try std.testing.expect(body.complete());

        var pull = try body.drainReadyForPull(std.testing.allocator);
        defer pull.deinit(std.testing.allocator);
        try std.testing.expect(pull.done);
        try std.testing.expect(pull.waiter != null);
    }

    {
        var body = fetch_body.Body.initOpen(std.testing.allocator, identity(104), null);
        defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);

        try std.testing.expect(!try body.beginPull(.{ .deferred = null }));
        body.markViewReleasedPreservingWaiters(std.testing.allocator);
        try std.testing.expect(try body.fail(std.testing.allocator, "failed"));

        var pull = try body.drainReadyForPull(std.testing.allocator);
        defer pull.deinit(std.testing.allocator);
        try std.testing.expect(pull.failed);
        try std.testing.expect(pull.waiter != null);
    }
}

const BorrowedReleaseRecorder = struct {
    count: usize = 0,
    seq: u64 = 0,
    len: usize = 0,
};

fn borrowedReleaseRecorder(context: ?*anyopaque, seq: u64, len: usize) void {
    const recorder: *BorrowedReleaseRecorder = @ptrCast(@alignCast(context.?));
    recorder.count += 1;
    recorder.seq = seq;
    recorder.len = len;
}

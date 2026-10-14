//! The worker's fetch body without a runtime (`worker/egress/body/body.zig`
//! and `chunk.zig`): whole-body reads that materialize queued chunks as they
//! come, pulls of one chunk each, borrowed extents released exactly once
//! after the last view, waiter drains and clones that cannot allocate leaving
//! every chunk queued, tee appends that leave every view unchanged when they
//! fail, a released source that keeps feeding its clone and is stopped only
//! by its last view, a released clone whose read is pending that still takes
//! the root's chunks, tee reference counts, sticky failure and cancel
//! override, transitions that still happen without memory, pending pulls kept
//! across a drop of the queued chunks, and a ready item that stays claimed
//! from its queueing to its pop whatever the view does meanwhile. Each claim
//! a test makes stands for the item `common.queueClaimed` queues, and each
//! `noteReadyItemPopped` for that item's pop. Runs in `worker-test`; the
//! paths through a runtime are in the other suites of `worker/tests/egress/`,
//! and those through gateway packets and JavaScript in
//! `worker/tests/runtime/fetch.zig`.

const std = @import("std");
const worker = @import("collo_worker");

const egress_body = worker.testing.egress_body;
const Body = egress_body.Body;
const allocator = std.testing.allocator;

fn identity(body_id: u64) egress_body.Identity {
    return .{ .request_id = 10, .request_generation = 20, .fetch_id = 30, .body_id = body_id };
}

fn waiter() !egress_body.Waiter {
    return .{ .kind = .bytes, .content_type = try allocator.dupe(u8, ""), .deferred = null };
}

fn owned(text: []const u8) ![]u8 {
    return allocator.dupe(u8, text);
}

/// Records each extent release, standing in for the body pool's release
/// queue.
const ReleaseLog = struct {
    handles: [8]u64 = undefined,
    count: usize = 0,

    fn releaseFn(context: ?*anyopaque, handle: u64, len: usize) void {
        _ = len;
        const self: *ReleaseLog = @ptrCast(@alignCast(context.?));
        std.debug.assert(self.count < self.handles.len);
        self.handles[self.count] = handle;
        self.count += 1;
    }

    fn borrow(self: *ReleaseLog, bytes: []u8, handle: u64) egress_body.BorrowedChunk {
        return .{
            .bytes = bytes,
            .release = .{ .context = self, .handle = handle, .len = bytes.len, .release_fn = releaseFn },
        };
    }
};

/// Ends a body on the stack: drops its chunks, decoder and links, then frees
/// it.
fn endBody(body: *Body) void {
    body.releaseQueuedChunks(allocator);
    body.dropDecoder(allocator);
    body.detachTeeLinks(allocator);
    body.deinit(allocator);
}

/// Ends a branch `cloneBranch` returned.
fn endBranch(branch: *Body) void {
    branch.releaseQueuedChunks(allocator);
    branch.detachTeeLinks(allocator);
    branch.release(allocator);
}

test "a whole-body read drains queued chunks as they come and gets its waiter back once complete" {
    var body = Body.initOpen(allocator, identity(1));
    defer endBody(&body);

    try std.testing.expect(!try body.beginConsume(try waiter()));
    try std.testing.expect(!body.claimReadyForQueue());
    try body.appendOwnedChunk(allocator, try owned("hel"));
    try std.testing.expectEqual(@as(usize, 3), body.queuedBytes());
    try std.testing.expect(body.claimReadyForQueue());
    body.noteReadyItemPopped();

    var first = try body.drainReadyForWaiter(allocator);
    defer first.deinit(allocator);
    try std.testing.expect(!first.terminal);
    try std.testing.expect(first.waiter == null);
    try std.testing.expectEqualStrings("hel", body.bytes.slice());
    try std.testing.expectEqual(@as(usize, 0), body.queuedBytes());
    try std.testing.expect(body.borrowCompleteBytes() == null);

    try body.appendOwnedChunk(allocator, try owned("lo"));
    body.complete();
    try std.testing.expect(body.claimReadyForQueue());
    body.noteReadyItemPopped();
    var last = try body.drainReadyForWaiter(allocator);
    defer last.deinit(allocator);
    try std.testing.expect(last.terminal);
    try std.testing.expect(last.waiter != null);
    try std.testing.expectEqualStrings("hello", body.borrowCompleteBytes().?);

    var second = try waiter();
    try std.testing.expectError(error.FetchBodyAlreadyUsed, body.beginConsume(second));
    second.deinit(allocator);
}

test "a pull moves one chunk per read and answers done only after the last" {
    var body = Body.initOpen(allocator, identity(2));
    defer endBody(&body);

    try body.appendOwnedChunk(allocator, try owned("abc"));
    try body.appendOwnedChunk(allocator, try owned("de"));
    try std.testing.expect(try body.beginPull(.{ .deferred = null }));
    body.noteReadyItemPopped();
    var first = body.drainReadyForPull(allocator);
    defer first.deinit(allocator);
    try std.testing.expect(first.waiter != null);
    try std.testing.expect(!first.done);
    try std.testing.expectEqualStrings("abc", first.bytes.bytes);
    try std.testing.expectEqual(@as(usize, 2), body.queuedBytes());

    try std.testing.expect(try body.beginPull(.{ .deferred = null }));
    body.noteReadyItemPopped();
    var second = body.drainReadyForPull(allocator);
    defer second.deinit(allocator);
    try std.testing.expectEqualStrings("de", second.bytes.bytes);
    try std.testing.expect(!second.done);

    // An open, empty body has nothing for the next pull until it ends.
    try std.testing.expect(!try body.beginPull(.{ .deferred = null }));
    var empty = body.drainReadyForPull(allocator);
    defer empty.deinit(allocator);
    try std.testing.expect(empty.waiter == null);
    body.complete();
    try std.testing.expect(body.claimReadyForQueue());
    body.noteReadyItemPopped();
    var end = body.drainReadyForPull(allocator);
    defer end.deinit(allocator);
    try std.testing.expect(end.done);
    try std.testing.expect(!end.bytes.isPresent());
}

test "a borrowed chunk's pull hands out the pool's bytes and releases the extent only when the lease goes" {
    var body = Body.initOpen(allocator, identity(3));
    defer endBody(&body);
    var releases = ReleaseLog{};
    var source = [_]u8{ 'a', 'b', 'c' };
    try body.appendBorrowedChunk(allocator, releases.borrow(&source, 42));

    try std.testing.expect(try body.beginPull(.{ .deferred = null }));
    body.noteReadyItemPopped();
    var pull = body.drainReadyForPull(allocator);
    try std.testing.expect(pull.bytes.isBorrowed());
    source[0] = 'z';
    try std.testing.expectEqualStrings("zbc", pull.bytes.bytes);
    try std.testing.expectEqual(@as(usize, 0), releases.count);
    pull.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), releases.count);
    try std.testing.expectEqual(@as(u64, 42), releases.handles[0]);
}

test "a whole-body read releases each borrowed extent once its bytes are copied" {
    var body = Body.initOpen(allocator, identity(4));
    defer endBody(&body);
    var releases = ReleaseLog{};
    var source = [_]u8{ 'x', 'y', 'z' };
    try std.testing.expect(!try body.beginConsume(try waiter()));
    try body.appendBorrowedChunk(allocator, releases.borrow(&source, 100));
    body.complete();

    var drain = try body.drainReadyForWaiter(allocator);
    defer drain.deinit(allocator);
    try std.testing.expect(drain.terminal);
    try std.testing.expectEqualStrings("xyz", body.borrowCompleteBytes().?);
    try std.testing.expectEqual(@as(usize, 1), releases.count);
    try std.testing.expectEqual(@as(u64, 100), releases.handles[0]);
}

test "a waiter drain that cannot allocate leaves every chunk queued and every extent held" {
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    const body_allocator = failing.allocator();
    var body = Body.initOpen(body_allocator, identity(5));
    defer {
        body.releaseQueuedChunks(body_allocator);
        body.deinit(body_allocator);
    }
    var releases = ReleaseLog{};
    var source = [_]u8{ 'b', 'o', 'r' };
    try std.testing.expect(!try body.beginConsume(.{
        .kind = .bytes,
        .content_type = try body_allocator.dupe(u8, ""),
        .deferred = null,
    }));
    try body.appendOwnedChunk(body_allocator, try body_allocator.dupe(u8, "own"));
    try body.appendBorrowedChunk(body_allocator, releases.borrow(&source, 7));

    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try std.testing.expectError(error.OutOfMemory, body.drainReadyForWaiter(body_allocator));
    try std.testing.expectEqual(@as(usize, 6), body.queuedBytes());
    try std.testing.expectEqual(@as(usize, 0), releases.count);

    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    var drain = try body.drainReadyForWaiter(body_allocator);
    defer drain.deinit(body_allocator);
    try std.testing.expectEqualStrings("ownbor", body.bytes.slice());
    try std.testing.expectEqual(@as(usize, 1), releases.count);
}

test "a clone shares a borrowed extent, which goes back only once the last view drops it" {
    var root = Body.initOpen(allocator, identity(6));
    defer endBody(&root);
    var releases = ReleaseLog{};
    var source = [_]u8{ 's', 'h', 'r' };
    try root.appendBorrowedChunk(allocator, releases.borrow(&source, 9));
    const branch = try root.cloneBranch(allocator, identity(60));
    defer endBranch(branch);

    try std.testing.expect(try root.beginPull(.{ .deferred = null }));
    var root_pull = root.drainReadyForPull(allocator);
    try std.testing.expectEqualStrings("shr", root_pull.bytes.bytes);
    root_pull.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), releases.count);

    try std.testing.expect(try branch.beginPull(.{ .deferred = null }));
    var branch_pull = branch.drainReadyForPull(allocator);
    try std.testing.expectEqualStrings("shr", branch_pull.bytes.bytes);
    branch_pull.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), releases.count);
}

test "a root feeds each later chunk to its clone, sharing borrowed extents, and drops held ones once" {
    var root = Body.initOpen(allocator, identity(7));
    defer endBody(&root);
    const branch = try root.cloneBranch(allocator, identity(70));
    defer endBranch(branch);
    var releases = ReleaseLog{};
    var source = [_]u8{ 'l', 'a', 't', 'e' };
    try root.appendOwnedChunk(allocator, try owned("own"));
    try root.appendBorrowedChunk(allocator, releases.borrow(&source, 11));
    try std.testing.expectEqual(@as(usize, 7), root.queuedBytes());
    try std.testing.expectEqual(@as(usize, 7), branch.queuedBytes());

    // Dropping the queued chunks of one view keeps the extent for the other.
    branch.releaseQueuedChunks(allocator);
    try std.testing.expectEqual(@as(usize, 0), releases.count);
    root.releaseQueuedChunks(allocator);
    try std.testing.expectEqual(@as(usize, 1), releases.count);
}

test "a released source keeps feeding its open clone, and only the last view to let go stops the fetch" {
    var root = Body.initOpen(allocator, identity(8));
    defer endBody(&root);
    const branch = try root.cloneBranch(allocator, identity(80));
    defer endBranch(branch);

    root.markViewReleased(allocator);
    try std.testing.expect(root.sourceCancelIdentityAfterViewRelease() == null);
    try std.testing.expect(root.shouldKeepReleasedSource());
    try root.appendOwnedChunk(allocator, try owned("abc"));
    try std.testing.expectEqual(@as(usize, 0), root.queuedBytes());
    try std.testing.expectEqual(@as(usize, 3), branch.queuedBytes());

    branch.markViewReleased(allocator);
    const stop = branch.sourceCancelIdentityAfterViewRelease() orelse return error.TestExpectedSourceStop;
    try std.testing.expectEqual(root.identity.body_id, stop.body_id);
    const refused = try owned("x");
    defer allocator.free(refused);
    try std.testing.expectError(error.FetchBodyNoActiveViews, root.appendOwnedChunk(allocator, refused));
}

// A released clone with a read still pending counts as a view that reads,
// which keeps the fetch running, so it must also take the root's chunks: a
// clone that skipped them while the fetch ran on answered its read with a
// truncated body once the root completed.
test "a released clone whose read is pending still takes the root's later chunks" {
    var root = Body.initOpen(allocator, identity(17));
    defer endBody(&root);
    const branch = try root.cloneBranch(allocator, identity(170));
    defer endBranch(branch);

    try std.testing.expect(!try branch.beginConsume(try waiter()));
    branch.markViewReleasedPreservingWaiters();
    try std.testing.expect(branch.sourceCancelIdentityAfterViewRelease() == null);
    try root.appendOwnedChunk(allocator, try owned("late"));
    try std.testing.expectEqual(@as(usize, 4), branch.queuedBytes());

    root.complete();
    var drain = try branch.drainReadyForWaiter(allocator);
    defer drain.deinit(allocator);
    try std.testing.expect(drain.terminal);
    try std.testing.expectEqualStrings("late", branch.borrowCompleteBytes().?);
}

test "a clone that cannot allocate leaves its source with every chunk and extent" {
    var source = [_]u8{ 'c', 'l', 'o' };
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var releases = ReleaseLog{};
        var root = Body.initOpen(allocator, identity(9));
        defer endBody(&root);
        try root.appendOwnedChunk(allocator, try owned("own"));
        try root.appendBorrowedChunk(allocator, releases.borrow(&source, 13));
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        const branch = root.cloneBranch(failing.allocator(), identity(90)) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(@as(usize, 6), root.queuedBytes());
            try std.testing.expect(root.tee_branches.items.len == 0);
            try std.testing.expectEqual(@as(u32, 1), root.refs);
            try std.testing.expectEqual(@as(usize, 0), releases.count);
            continue;
        };
        try std.testing.expectEqual(@as(usize, 6), branch.queuedBytes());
        // The branch was built with the failing allocator; it frees with it.
        branch.releaseQueuedChunks(failing.allocator());
        branch.detachTeeLinks(failing.allocator());
        branch.release(failing.allocator());
        try std.testing.expectEqual(@as(usize, 0), releases.count);
        break;
    }
    try std.testing.expect(fail_index > 0);
}

test "an append that cannot reserve for every view leaves each view unchanged and the bytes the caller's" {
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(allocator, .{});
        const views_allocator = failing.allocator();
        var root = Body.initOpen(views_allocator, identity(10));
        defer {
            root.releaseQueuedChunks(views_allocator);
            root.detachTeeLinks(views_allocator);
            root.deinit(views_allocator);
        }
        const branch = try root.cloneBranch(views_allocator, identity(100));
        defer {
            branch.releaseQueuedChunks(views_allocator);
            branch.detachTeeLinks(views_allocator);
            branch.release(views_allocator);
        }
        const bytes = try views_allocator.dupe(u8, "tee");
        failing.fail_index = failing.alloc_index + fail_index;
        root.appendOwnedChunk(views_allocator, bytes) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(@as(usize, 0), root.queuedBytes());
            try std.testing.expectEqual(@as(usize, 0), branch.queuedBytes());
            views_allocator.free(bytes);
            continue;
        };
        try std.testing.expectEqual(@as(usize, 3), root.queuedBytes());
        try std.testing.expectEqual(@as(usize, 3), branch.queuedBytes());
        break;
    }
    try std.testing.expect(fail_index > 0);
}

test "a tee link holds one reference on each side, and detaching from either side drops both" {
    var root = Body.initOpen(allocator, identity(11));
    defer endBody(&root);
    const first = try root.cloneBranch(allocator, identity(110));
    const second = try root.cloneBranch(allocator, identity(111));
    try std.testing.expectEqual(@as(u32, 3), root.refs);
    try std.testing.expectEqual(@as(u32, 2), first.refs);

    // From the branch's side.
    first.detachTeeLinks(allocator);
    try std.testing.expectEqual(@as(u32, 2), root.refs);
    try std.testing.expectEqual(@as(u32, 1), first.refs);
    first.release(allocator);

    // From the root's side.
    root.detachTeeLinks(allocator);
    try std.testing.expectEqual(@as(u32, 1), root.refs);
    try std.testing.expectEqual(@as(u32, 1), second.refs);
    try std.testing.expect(second.tee_root == null);
    second.release(allocator);
}

test "fail is sticky and never fails a complete body; cancel overrides both and reaches every branch" {
    var body = Body.initOpen(allocator, identity(12));
    defer endBody(&body);
    body.fail(allocator, "first");
    body.fail(allocator, "second");
    try std.testing.expectEqualStrings("first", body.failureMessage().?);

    var complete = Body.initOpen(allocator, identity(13));
    defer endBody(&complete);
    const branch = try complete.cloneBranch(allocator, identity(130));
    defer endBranch(branch);
    complete.complete();
    complete.fail(allocator, "late");
    try std.testing.expectEqual(egress_body.State.complete, complete.state);
    try std.testing.expectEqual(egress_body.State.complete, branch.state);
    complete.cancel(allocator, "aborted", null);
    try std.testing.expectEqualStrings("aborted", complete.failureMessage().?);
    try std.testing.expectEqualStrings("aborted", branch.failureMessage().?);
}

test "fail and cancel without memory for their messages still fail every view" {
    var fail_index: usize = 0;
    while (fail_index < 4) : (fail_index += 1) {
        var root = Body.initOpen(allocator, identity(14));
        defer endBody(&root);
        const branch = try root.cloneBranch(allocator, identity(140));
        defer endBranch(branch);
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        // The messages a view keeps are freed with the allocator that made
        // them, so the failing allocator only refuses: each copy it grants is
        // the testing allocator's.
        root.fail(failing.allocator(), "failed");
        try std.testing.expect(root.isFailed());
        try std.testing.expect(branch.isFailed());
        root.cancel(failing.allocator(), "aborted", null);
        try std.testing.expect(root.isFailed());
        try std.testing.expect(branch.isFailed());
    }
}

test "dropping queued chunks keeps a pending pull, answered once the body ends" {
    var body = Body.initOpen(allocator, identity(15));
    defer endBody(&body);
    var releases = ReleaseLog{};
    var source = [_]u8{ 'g', 'o' };
    try std.testing.expect(!try body.beginPull(.{ .deferred = null }));
    try body.appendBorrowedChunk(allocator, releases.borrow(&source, 15));

    body.releaseQueuedChunksPreservingWaiters(allocator);
    try std.testing.expectEqual(@as(usize, 1), releases.count);
    try std.testing.expect(body.hasPendingWaiter());
    body.markViewReleasedPreservingWaiters();
    try std.testing.expect(body.hasPendingWaiter());

    body.fail(allocator, "egress gateway closed");
    try std.testing.expect(body.claimReadyForQueue());
    body.noteReadyItemPopped();
    var pull = body.drainReadyForPull(allocator);
    defer pull.deinit(allocator);
    try std.testing.expect(pull.failed);
    try std.testing.expect(pull.waiter != null);
    try std.testing.expect(!pull.bytes.isPresent());
}

// The ready queue holds as many body items as the body table has slots
// (`body/register.zig`), so a body may never have two queued at once.
// Releasing a view while its reader waits, and dropping its chunks as a
// detach does, used to clear the claim while the item still sat in the
// queue, and the next chunk queued a second item for the same body.
test "a body's ready item stays claimed from its queueing to its pop, whatever happens to the view meanwhile" {
    var body = Body.initOpen(allocator, identity(16));
    defer endBody(&body);
    try std.testing.expect(!try body.beginPull(.{ .deferred = null }));
    try body.appendOwnedChunk(allocator, try owned("a"));
    try std.testing.expect(body.claimReadyForQueue());

    // A release that keeps the waiting pull, then another chunk.
    body.markViewReleasedPreservingWaiters();
    try body.appendOwnedChunk(allocator, try owned("b"));
    try std.testing.expect(!body.claimReadyForQueue());

    // A detach's drop of the queued chunks, then the body's failure.
    body.releaseQueuedChunksPreservingWaiters(allocator);
    body.fail(allocator, "egress gateway closed");
    try std.testing.expect(!body.claimReadyForQueue());

    // Only the pop frees the claim, and the reader is still ready.
    body.noteReadyItemPopped();
    try std.testing.expect(body.claimReadyForQueue());
    body.noteReadyItemPopped();
    var pull = body.drainReadyForPull(allocator);
    defer pull.deinit(allocator);
    try std.testing.expect(pull.failed);
}

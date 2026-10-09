//! The credit ownership of `body_pump.PendingBatch`: at every moment a drained flow-control credit
//! belongs to exactly one of the caller, a payload slot or the worker's extent ledger. Each test
//! drives the batch through one failure point with a counting fake engine and checks that every
//! credit is released once and every drained buffer freed once; `std.testing.allocator` turns a
//! double free or a leak into a failure. The drain loop around the batch is covered in
//! `engine.zig`. Lane: egress-gateway-test.

const std = @import("std");
const gateway = @import("collo_egress_gateway");
const egress = @import("collo_egress_client");

const body_credit = egress.body_credit;
const fetch_body = egress.fetch_body;
const PendingBatch = gateway.body_pump.PendingBatch;

test "pending batch mid-chunk flush failure releases the chunk credit exactly once" {
    // When the payload array fills, the batch flushes in the middle of the
    // chunk: it already owns the bytes but has not staged the credit, which
    // rides the last split. Here that flush fails, and only the append's own
    // unwind can see the credit, so it must release it exactly once.
    var fake = FakeEngine{ .allocator = std.testing.allocator };
    var body = testBody();
    defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);
    var fetch = testFetch(&body);

    // One-byte worker chunks: a buffer longer than the payload array forces
    // the mid-chunk flush.
    const bytes = try std.testing.allocator.alloc(u8, gateway.body_pump.body_chunk_batch_max + 2);
    @memset(bytes, 'x');

    fake.publish_error = error.TestPublishFailure;
    var batch = PendingBatch{};
    try std.testing.expectError(
        error.TestPublishFailure,
        batch.appendChunk(&fake, &fetch, bytes, body_credit.h2Data(1, 1, 64, true), 1),
    );
    try std.testing.expectEqual(@as(usize, 1), fake.released_credits);

    // The failed flush kept its slots; none of them carried the credit, so
    // deinit frees the buffer once and releases nothing further.
    batch.deinit(&fake, &fetch);
    try std.testing.expectEqual(@as(usize, 1), fake.released_credits);
    try std.testing.expectEqual(@as(usize, 0), fake.release_failures);
    try std.testing.expectEqual(@as(usize, 0), fetch.outstanding_extents);
}

test "pending batch deinit releases a staged credit exactly once after a failed flush" {
    var fake = FakeEngine{ .allocator = std.testing.allocator };
    var body = testBody();
    defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);
    var fetch = testFetch(&body);

    const bytes = try std.testing.allocator.dupe(u8, "payload");
    var batch = PendingBatch{};
    // Stages one payload carrying the credit; no flush needed yet.
    try batch.appendChunk(&fake, &fetch, bytes, body_credit.h2Data(2, 3, 7, true), 64 * 1024);
    try std.testing.expectEqual(@as(usize, 0), fake.released_credits);

    fake.publish_error = error.TestPublishFailure;
    try std.testing.expectError(error.TestPublishFailure, batch.flush(&fake, &fetch, 0));
    // The slot survived the failed publish: the deinit sweep is the single
    // owner of the staged credit and hands it back exactly once.
    batch.deinit(&fake, &fetch);
    try std.testing.expectEqual(@as(usize, 1), fake.released_credits);
    try std.testing.expectEqual(@as(usize, 0), fake.release_failures);
    try std.testing.expectEqual(@as(usize, 0), fetch.outstanding_extents);
}

test "pending batch successful publish hands credits onward and deinit releases nothing" {
    var fake = FakeEngine{ .allocator = std.testing.allocator };
    var body = testBody();
    defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);
    var fetch = testFetch(&body);

    const first = try std.testing.allocator.dupe(u8, "alpha");
    const second = try std.testing.allocator.dupe(u8, "beta");
    var batch = PendingBatch{};
    try batch.appendChunk(&fake, &fetch, first, body_credit.h2Data(1, 1, 5, true), 64 * 1024);
    try batch.appendChunk(&fake, &fetch, second, .none, 64 * 1024);
    try batch.flush(&fake, &fetch, 0);
    batch.deinit(&fake, &fetch);

    // The worker's extent ledger owns the credit now; releasing it here as well
    // would refill the HTTP/2 window twice.
    try std.testing.expectEqual(@as(usize, 0), fake.released_credits);
    try std.testing.expectEqual(@as(usize, 1), fake.published_credits);
    try std.testing.expectEqual(@as(usize, 2), fake.published_entries);
    try std.testing.expectEqual(@as(usize, 2), fetch.outstanding_extents);
}

test "pending batch early flush failure returns the incoming credit before taking ownership" {
    var fake = FakeEngine{ .allocator = std.testing.allocator };
    var body = testBody();
    defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);
    var fetch = testFetch(&body);

    var batch = PendingBatch{};
    // Credit-less chunks fill the payload array, so the next append must flush
    // before it accepts the incoming chunk.
    var appended: usize = 0;
    while (appended < gateway.body_pump.body_chunk_batch_max) : (appended += 1) {
        const filler = try std.testing.allocator.dupe(u8, "f");
        try batch.appendChunk(&fake, &fetch, filler, .none, 64 * 1024);
    }

    fake.publish_error = error.TestPublishFailure;
    const bytes = try std.testing.allocator.dupe(u8, "incoming");
    try std.testing.expectError(
        error.TestPublishFailure,
        batch.appendChunk(&fake, &fetch, bytes, body_credit.h2Data(4, 4, 8, true), 64 * 1024),
    );
    // The incoming chunk never joined the batch: the append's own unwind freed
    // its bytes and released its credit, exactly once.
    try std.testing.expectEqual(@as(usize, 1), fake.released_credits);

    batch.deinit(&fake, &fetch);
    try std.testing.expectEqual(@as(usize, 1), fake.released_credits);
    try std.testing.expectEqual(@as(usize, 0), fake.release_failures);
}

fn testBody() fetch_body.Body {
    return fetch_body.Body.initOpen(std.testing.allocator, .{
        .request_id = 1,
        .request_generation = 1,
        .fetch_id = 1,
        .body_id = 1,
    }, null);
}

fn testFetch(body: *fetch_body.Body) gateway.active_fetch.Fetch {
    return .{
        .worker_session_id = 1,
        .budget_key = .{ .session_id = 1, .request_id = 1, .request_generation = 1 },
        .worker_attached = true,
        // The batch paths under test never dereference it: only a detach
        // touches the task, and these tests fail publishes with an error
        // that does not detach.
        .task = undefined,
        .body = body,
        .fetch_id = 1,
        .body_id = 1,
    };
}

/// Stands in for the engine the batch takes as `engine: anytype`: it counts
/// credit releases and publishes, and fails publishes on demand.
const FakeEngine = struct {
    allocator: std.mem.Allocator,
    inner: FakeInner = .{},
    publish_error: ?anyerror = null,
    publish_calls: usize = 0,
    published_entries: usize = 0,
    published_credits: usize = 0,
    released_credits: usize = 0,
    release_failures: usize = 0,
    last_release_error: ?anyerror = null,

    const FakeInner = struct {
        pub fn wakeCancellation(_: *FakeInner) void {}
    };

    pub fn sendBodyChunkBatch(
        self: *FakeEngine,
        worker_session_id: u64,
        fetch_id: u64,
        body_id: u64,
        chunks: []const gateway.engine.BodyChunkPayload,
    ) anyerror!usize {
        _ = worker_session_id;
        _ = fetch_id;
        _ = body_id;
        self.publish_calls += 1;
        if (self.publish_error) |err|
            return err;
        self.published_entries += chunks.len;
        for (chunks) |chunk| {
            if (!chunk.credit.isNone())
                self.published_credits += 1;
        }
        return chunks.len;
    }

    pub fn releaseCredit(self: *FakeEngine, credit: body_credit.Handle) anyerror!void {
        std.debug.assert(!credit.isNone());
        self.released_credits += 1;
    }

    pub fn reportWorkerCreditReleaseFailure(
        self: *FakeEngine,
        worker_session_id: u64,
        credit: body_credit.Handle,
        err: anyerror,
    ) void {
        _ = worker_session_id;
        _ = credit;
        self.last_release_error = err;
        self.release_failures += 1;
    }
};

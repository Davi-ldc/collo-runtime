//! The io_uring of an ingress lane (`runner/event_sources.zig`): a pass
//! hands everything its handlers prepared to the kernel in one counted
//! `io_uring_enter`, and only a pass that fills the submission queue enters
//! before its end. Lane `server-ingress-test`; the pass itself runs through
//! `lane_harness.zig`, whose `finishPass` ends it as the loop does.

const std = @import("std");
const limits = @import("collo_limits");
const lane_harness = @import("lane_harness.zig");

const LaneRing = lane_harness.runner.event_sources.LaneRing;

test "a pass that fills the submission queue enters once early and once at its end, and an empty submit enters not at all" {
    var ring = try LaneRing.init();
    defer ring.deinit();
    for (0..limits.ingress.ring_submission_entries + 1) |_| {
        const sqe = try ring.prepare();
        sqe.prep_nop();
        sqe.user_data = 0;
    }
    try std.testing.expectEqual(@as(u64, 1), ring.enters);
    try ring.submit();
    try std.testing.expectEqual(@as(u64, 2), ring.enters);
    try ring.submit();
    try std.testing.expectEqual(@as(u64, 2), ring.enters);
}

test "a pass that admits a request and arms its worker's polls hands every entry to the kernel in one io_uring_enter" {
    var scene: lane_harness.OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const ring = &scene.harness.rings[0];
    const enters_before = ring.enters;
    const prepared_before = ring.ring.sq.sqe_tail;

    try scene.client.get(1);
    try scene.client.drive();
    _ = try scene.stub.readRequestBegin();

    // The worker's first request armed its registration's polls: its
    // completion eventfd, its control socket, its fs-fault socket and its
    // pidfd.
    try std.testing.expect(ring.ring.sq.sqe_tail -% prepared_before >= 4);
    try std.testing.expectEqual(enters_before + 1, ring.enters);
    try std.testing.expect(!ring.hasPending());
}

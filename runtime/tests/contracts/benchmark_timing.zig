//! The cold-start timeline arithmetic of the sandbox benchmark
//! (`runtime/bench/sandbox/timing.zig`): phase durations from one request's
//! ordered timestamps, the errors for a missing or reordered timestamp, and
//! nearest-rank percentiles. Runs in `microbench-test` and `meta-test`;
//! `bench-cold-start` produces real timelines.

const std = @import("std");
const timing = @import("benchmark_timing");

// Every duration comes from the same request's timestamps, so the total equals
// the sum of the two phases exactly.
test "benchmark timing derives both phases and direct total from one request" {
    const sample = timing.Timeline{
        .request_sent_ns = 100,
        .worker_ready_ns = 140,
        .handler_enter_ns = 170,
        .response_received_ns = 220,
    };
    const result = try sample.durations();
    try std.testing.expectEqual(@as(u64, 40), result.creation_ns);
    try std.testing.expectEqual(@as(u64, 30), result.dispatch_ns);
    try std.testing.expectEqual(@as(u64, 70), result.total_ns);
    try std.testing.expectEqual(@as(u64, 120), result.response_ns);
    try std.testing.expectEqual(result.total_ns, result.creation_ns + result.dispatch_ns);
}

test "benchmark timing rejects missing warm or reordered timestamps" {
    const valid = timing.Timeline{
        .request_sent_ns = 100,
        .worker_ready_ns = 140,
        .handler_enter_ns = 170,
        .response_received_ns = 220,
    };
    inline for (@typeInfo(timing.Timeline).@"struct".fields) |field| {
        var sample = valid;
        @field(sample, field.name) = 0;
        try std.testing.expectError(error.MissingTimestamp, sample.durations());
    }
    var sample = valid;
    sample.worker_ready_ns = 99;
    try std.testing.expectError(error.WorkerAlreadyReady, sample.durations());
    sample = valid;
    sample.handler_enter_ns = 139;
    try std.testing.expectError(error.TimestampOrder, sample.durations());
    sample = valid;
    sample.response_received_ns = 169;
    try std.testing.expectError(error.TimestampOrder, sample.durations());
}

test "benchmark timing nearest rank percentiles reject empty and unsorted samples" {
    const samples = [_]u64{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    const result = try timing.Percentiles.fromSorted(&samples);
    try std.testing.expectEqual(@as(usize, 10), result.samples);
    try std.testing.expectEqual(@as(u64, 5), result.p50_ns);
    try std.testing.expectEqual(@as(u64, 10), result.p95_ns);
    try std.testing.expectEqual(@as(u64, 10), result.p99_ns);
    try std.testing.expectEqual(@as(u64, 10), result.max_ns);
    try std.testing.expectError(error.NoSamples, timing.Percentiles.fromSorted(&.{}));
    try std.testing.expectError(error.UnsortedSamples, timing.Percentiles.fromSorted(&.{ 2, 1 }));
    try std.testing.expectError(error.InvalidPercentile, timing.percentileSorted(&samples, 0));
    try std.testing.expectError(error.InvalidPercentile, timing.percentileSorted(&samples, 101));
}

test "benchmark total percentile is not the sum of phase percentiles" {
    const creation = try timing.Percentiles.fromSorted(&.{ 1, 100, 100 });
    const dispatch = try timing.Percentiles.fromSorted(&.{ 1, 100, 100 });
    // Paired phases are (100, 1), (1, 100), (100, 100).
    const total = try timing.Percentiles.fromSorted(&.{ 101, 101, 200 });
    try std.testing.expectEqual(@as(u64, 101), total.p50_ns);
    try std.testing.expect(total.p50_ns != creation.p50_ns + dispatch.p50_ns);
}

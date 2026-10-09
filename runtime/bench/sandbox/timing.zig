//! The cold-start timeline of one sampled request and the percentiles of a
//! run, computed by the controller. Every timestamp of a timeline is an
//! absolute CLOCK_MONOTONIC reading taken for the same request: the HTTP
//! client's send and response marks, the host's receipt of WorkerReady
//! (`ready_received_ns` in `host/launch.zig`) and the handler's entry mark.
//! The percentiles of the total come from each request's own total, never
//! from summed phase percentiles.

const std = @import("std");

/// One request's timestamps in nanoseconds; zero means the mark is missing.
pub const Timeline = struct {
    request_sent_ns: u64,
    worker_ready_ns: u64,
    handler_enter_ns: u64,
    response_received_ns: u64,

    /// The request's phases. Fails with `error.MissingTimestamp` when a mark
    /// is zero, with `error.WorkerAlreadyReady` when the worker was ready
    /// before the request was sent, so no cold start happened, and with
    /// `error.TimestampOrder` for any other mark out of order.
    pub fn durations(self: Timeline) !Durations {
        if (self.request_sent_ns == 0 or self.worker_ready_ns == 0 or
            self.handler_enter_ns == 0 or self.response_received_ns == 0)
            return error.MissingTimestamp;
        if (self.worker_ready_ns < self.request_sent_ns)
            return error.WorkerAlreadyReady;
        if (self.handler_enter_ns < self.worker_ready_ns or
            self.response_received_ns < self.handler_enter_ns)
            return error.TimestampOrder;
        return .{
            .creation_ns = self.worker_ready_ns - self.request_sent_ns,
            .dispatch_ns = self.handler_enter_ns - self.worker_ready_ns,
            .total_ns = self.handler_enter_ns - self.request_sent_ns,
            .response_ns = self.response_received_ns - self.request_sent_ns,
        };
    }
};

pub const Durations = struct {
    /// From the send to the host's receipt of WorkerReady.
    creation_ns: u64,
    /// From WorkerReady to the handler's first statement.
    dispatch_ns: u64,
    /// The cold start, from the send to the handler's first statement; always
    /// `creation_ns + dispatch_ns`.
    total_ns: u64,
    /// From the send to the end of the response.
    response_ns: u64,
};

/// Nearest-rank percentiles of one series of samples.
pub const Percentiles = struct {
    samples: usize,
    p50_ns: u64,
    p95_ns: u64,
    p99_ns: u64,
    max_ns: u64,

    /// `samples` must be in ascending order. Fails with `error.NoSamples` when
    /// it is empty and with `error.UnsortedSamples` when it is out of order.
    pub fn fromSorted(samples: []const u64) !Percentiles {
        if (samples.len == 0) return error.NoSamples;
        for (samples[1..], samples[0 .. samples.len - 1]) |next, previous| {
            if (next < previous) return error.UnsortedSamples;
        }
        return .{
            .samples = samples.len,
            .p50_ns = try percentileSorted(samples, 50),
            .p95_ns = try percentileSorted(samples, 95),
            .p99_ns = try percentileSorted(samples, 99),
            .max_ns = samples[samples.len - 1],
        };
    }
};

/// The nearest-rank `percentile` of ascending `samples`: the smallest sample
/// with at least that share of the samples at or below it. `percentile` runs
/// from 1 to 100; an empty `samples` fails with `error.NoSamples`. The order
/// is not checked here.
pub fn percentileSorted(samples: []const u64, percentile: u8) !u64 {
    if (samples.len == 0) return error.NoSamples;
    if (percentile == 0 or percentile > 100) return error.InvalidPercentile;
    const product = try std.math.mul(usize, samples.len, percentile);
    const rank = product / 100 + @intFromBool(product % 100 != 0);
    return samples[rank - 1];
}

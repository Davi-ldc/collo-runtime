//! Assertions over an `ingress.lane.CounterSnapshot`: the counters of work the
//! lane's hot path must never do, and the transport counters an HTTP/2
//! request raises. Not a suite of its own; `runner_contract.zig` imports it.

const std = @import("std");
const ingress = @import("collo_server_main").ingress;

pub fn expectForbiddenHotWorkZero(self: ingress.lane.CounterSnapshot) !void {
    try std.testing.expectEqual(@as(u64, 0), self.connection_slot_scans);
    try std.testing.expectEqual(@as(u64, 0), self.active_request_slot_scans);
    try std.testing.expectEqual(@as(u64, 0), self.runtime_pollfd_rebuilds);
    try std.testing.expectEqual(@as(u64, 0), self.runtime_pollfd_connection_slots_inspected);
    try std.testing.expectEqual(@as(u64, 0), self.runtime_pollfd_worker_slots_inspected);
    try std.testing.expectEqual(@as(u64, 0), self.sync_pidfd_poll_calls);
    try std.testing.expectEqual(@as(u64, 0), self.manual_deadline_scan_checks);
    try std.testing.expectEqual(@as(u64, 0), self.normal_scheduler_sleeps);
    try std.testing.expectEqual(@as(u64, 0), self.per_request_worker_done_polls);
    try std.testing.expectEqual(@as(u64, 0), self.per_request_pidfd_polls);
    try std.testing.expectEqual(@as(u64, 0), self.per_request_hard_timeout_submissions);
    try std.testing.expectEqual(@as(u64, 0), self.hot_path_allocations);
    try std.testing.expectEqual(@as(u64, 0), self.done_buffer_allocations);
    try std.testing.expectEqual(@as(u64, 0), self.accepted_stale_worker_generations);
}

pub fn expectHttp2TransportObserved(self: ingress.lane.CounterSnapshot) !void {
    try std.testing.expect(self.h2_server_protocol_time_ns > 0);
    try std.testing.expect(self.ingress_channels_started > 0);
}

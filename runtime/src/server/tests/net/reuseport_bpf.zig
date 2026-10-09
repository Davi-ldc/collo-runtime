//! The CPU-to-lane map the SO_REUSEPORT selector loads
//! (`server/net/reuseport_bpf.zig`): each lane's CPU holds the lane's index,
//! every other CPU `invalid_lane_index`, the returned count reaches the
//! highest lane CPU, and a CPU beyond the map is refused. Lane
//! `server-core-test`. No lane checks that the selector program loads and
//! attaches, which `server/net/listener.zig` treats as best effort.

const std = @import("std");
const reuseport_bpf = @import("collo_server_main").reuseport_bpf;

test "reuseport cpu lane map marks only pinned lane CPUs" {
    var cpu_to_lane: [8]u32 = undefined;
    const lane_cpu_ids = [_]usize{ 1, 3, 6 };

    const cpu_count = try reuseport_bpf.fillCpuLaneMap(&cpu_to_lane, &lane_cpu_ids);

    try std.testing.expectEqual(@as(usize, 7), cpu_count);
    try std.testing.expectEqual(reuseport_bpf.invalid_lane_index, cpu_to_lane[0]);
    try std.testing.expectEqual(@as(u32, 0), cpu_to_lane[1]);
    try std.testing.expectEqual(reuseport_bpf.invalid_lane_index, cpu_to_lane[2]);
    try std.testing.expectEqual(@as(u32, 1), cpu_to_lane[3]);
    try std.testing.expectEqual(reuseport_bpf.invalid_lane_index, cpu_to_lane[4]);
    try std.testing.expectEqual(reuseport_bpf.invalid_lane_index, cpu_to_lane[5]);
    try std.testing.expectEqual(@as(u32, 2), cpu_to_lane[6]);
}

test "reuseport cpu lane map rejects cpus outside fixed cpu_set_t scope" {
    var cpu_to_lane: [4]u32 = undefined;
    const lane_cpu_ids = [_]usize{4};

    try std.testing.expectError(
        error.CpuIdOutOfRange,
        reuseport_bpf.fillCpuLaneMap(&cpu_to_lane, &lane_cpu_ids),
    );
}

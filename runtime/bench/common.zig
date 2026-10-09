//! Helpers the benches share: knob lists read from the environment,
//! nearest-rank percentiles and CLOCK_MONOTONIC deadlines. Every function
//! runs on its caller's thread and keeps no state.

const std = @import("std");

/// Reads `env_name` as comma-separated positive integers, or copies
/// `default_values` when the variable is unset. The caller owns the returned
/// slice. An empty entry or a zero fails with `error.InvalidUsizeList`, and a
/// non-numeric entry with the parse error.
pub fn parseCommaSeparatedUsizeList(
    allocator: std.mem.Allocator,
    env_name: []const u8,
    default_values: []const usize,
) ![]usize {
    const raw = std.process.getEnvVarOwned(allocator, env_name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return allocator.dupe(usize, default_values),
        else => |other| return other,
    };
    defer allocator.free(raw);

    var values = std.ArrayList(usize).empty;
    errdefer values.deinit(allocator);
    var parts = std.mem.splitScalar(u8, raw, ',');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        if (trimmed.len == 0)
            return error.InvalidUsizeList;
        const value = try std.fmt.parseUnsigned(usize, trimmed, 10);
        if (value == 0)
            return error.InvalidUsizeList;
        try values.append(allocator, value);
    }
    if (values.items.len == 0)
        return error.InvalidUsizeList;
    return values.toOwnedSlice(allocator);
}

/// The nearest-rank `percentile` (1 to 100) of `sorted_values`, which the
/// caller sorts ascending and never passes empty.
pub fn percentileNearestRank(comptime T: type, sorted_values: []const T, percentile: u8) T {
    std.debug.assert(sorted_values.len != 0);
    std.debug.assert(percentile >= 1 and percentile <= 100);
    const rank = (@as(usize, percentile) * sorted_values.len + 99) / 100;
    return sorted_values[rank - 1];
}

/// CLOCK_MONOTONIC now plus `duration_ns`; fails with `error.Overflow` when
/// the sum leaves u64.
pub fn deadlineFromNowNs(duration_ns: u64) !u64 {
    return try std.math.add(u64, try monotonicNowNs(), duration_ns);
}

/// Polls `fd` once for the time left before `deadline_ns`, capped at
/// `max_poll_ms`. Fails with `error.BenchResponseTimeout` when the deadline
/// has passed or that one poll times out, so a cap shorter than the time left
/// times out early. POLLERR fails with `error.PollError`; POLLHUP returns
/// normally and leaves the caller's read to report it.
pub fn waitReadableBeforeDeadline(fd: std.posix.fd_t, deadline_ns: u64, max_poll_ms: u64) !void {
    const now = try monotonicNowNs();
    if (now >= deadline_ns)
        return error.BenchResponseTimeout;
    const remaining_ns = deadline_ns - now;
    const remaining_ms = @max(
        @as(u64, 1),
        @min(max_poll_ms, (remaining_ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms),
    );
    var pollfds = [1]std.posix.pollfd{
        .{
            .fd = fd,
            .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR,
            .revents = 0,
        },
    };
    const ready = try std.posix.poll(&pollfds, @intCast(remaining_ms));
    if (ready == 0)
        return error.BenchResponseTimeout;
    if (pollfds[0].revents & std.posix.POLL.ERR != 0)
        return error.PollError;
}

fn monotonicNowNs() !u64 {
    const ts = try std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC);
    const sec: u64 = @intCast(ts.sec);
    const nsec: u64 = @intCast(ts.nsec);
    return sec * std.time.ns_per_s + nsec;
}

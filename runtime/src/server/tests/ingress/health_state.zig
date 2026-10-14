//! How a lane reads the server's state for the health answer (`healthState`
//! in `ingress/runner/admission.zig`), from a real pidfd and published lane
//! states: a live zygote with every lane active reads ok, a zygote whose
//! process exited and a lane that is not active degrade it, and a stopping
//! server reads as stopping. The status and body of each state are covered
//! in `server_responses.zig`, and the answer on the wire by local-e2e. Lane
//! `server-ingress-test`.

const std = @import("std");
const server_main = @import("collo_server_main");
const process = @import("collo_os").process;

const admission = server_main.ingress.runner.admission;
const server_responses = server_main.ingress.server_responses;
const LaneRuntimeState = server_main.ingress.runner.LaneRuntimeState;
const Status = server_responses.HealthState.Status;

/// How long a test waits for a child it forked to exit.
const child_exit_wait_ms: i32 = 5_000;

/// A lane as `healthState` reads it: the state it published, and nothing
/// else.
const PublishedLane = struct {
    published: LaneRuntimeState,

    pub fn state(self: *const PublishedLane) LaneRuntimeState {
        return self.published;
    }
};

const serving = [_]PublishedLane{ .{ .published = .active }, .{ .published = .active } };

/// A pidfd of the test process itself, which is alive while the test reads
/// it.
fn ownPidFd() !std.posix.fd_t {
    return process.openPidFd(@intCast(std.os.linux.getpid()));
}

/// Reaps a child `fork` returned. Through `std.c.waitpid`, which reports a
/// child already reaped instead of treating it as unreachable.
fn reapChild(child_pid: std.posix.pid_t) void {
    var status: c_int = 0;
    _ = std.c.waitpid(child_pid, &status, 0);
}

test "a live zygote with every lane active reads ok" {
    const pidfd = try ownPidFd();
    defer std.posix.close(pidfd);

    const state = admission.healthState(false, pidfd, serving[0..]);
    try std.testing.expect(!state.stopping);
    try std.testing.expect(state.zygote_alive);
    try std.testing.expectEqual(@as(u16, 2), state.lanes_running);
    try std.testing.expectEqual(@as(u16, 2), state.lanes_total);
    try std.testing.expectEqual(Status.ok, state.status());
}

test "a zygote whose process exited reads as exited and degrades the answer" {
    const child_pid = try std.posix.fork();
    if (child_pid == 0)
        std.os.linux.exit_group(0);
    defer reapChild(child_pid);
    const pidfd = try process.openPidFd(@intCast(child_pid));
    defer std.posix.close(pidfd);
    try std.testing.expect(try process.waitForPidFdExit(pidfd, child_exit_wait_ms));

    const state = admission.healthState(false, pidfd, serving[0..]);
    try std.testing.expect(!state.zygote_alive);
    try std.testing.expectEqual(Status.degraded, state.status());
}

test "a lane that is not active counts as not running and degrades the answer" {
    const pidfd = try ownPidFd();
    defer std.posix.close(pidfd);

    const lanes = [_]PublishedLane{
        .{ .published = .active },
        .{ .published = .warming },
        .{ .published = .exited },
        .{ .published = .failed },
    };
    const state = admission.healthState(false, pidfd, lanes[0..]);
    try std.testing.expectEqual(@as(u16, 1), state.lanes_running);
    try std.testing.expectEqual(@as(u16, 4), state.lanes_total);
    try std.testing.expectEqual(Status.degraded, state.status());
}

test "a stopping server reads as stopping" {
    const pidfd = try ownPidFd();
    defer std.posix.close(pidfd);

    const state = admission.healthState(true, pidfd, serving[0..]);
    try std.testing.expect(state.stopping);
    try std.testing.expectEqual(Status.stopping, state.status());
}

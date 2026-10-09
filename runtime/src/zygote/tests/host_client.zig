//! The zygote control protocol's host side (`host_client.zig`), over real
//! socket pairs: the ready and WorkerInit-outcome waits time out instead of
//! blocking, and the two halves of a fork request match the reply to its
//! job. A real zygote forks in `zygote-integration`.

const std = @import("std");
const fd_mod = @import("collo_os").fd;
const zygote = @import("collo_zygote");
const process = @import("collo_os").process;

const host_client = zygote.host_client;
const ipc = zygote.ipc;

const ipc_socket_type: u32 = std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC;

/// The host's handle of a zygote whose control socket is one end of a socket
/// pair the test reads and answers on, and whose pidfd is the test process's
/// own, so the zygote never reads as exited.
const StandInZygote = struct {
    pair: [2]std.posix.fd_t,
    spawned: host_client.SpawnedZygote,

    fn init(self: *StandInZygote) !void {
        self.pair = try fd_mod.socketPairType(ipc_socket_type);
        errdefer closeAll(&self.pair);
        const pidfd = try process.openPidFd(@intCast(std.c.getpid()));
        self.spawned = .{
            .pid = @intCast(std.c.getpid()),
            .pidfd = pidfd,
            .control_fd = self.pair[0],
            .trace_read_fd = null,
            .trace_write_fd = null,
            .next_fork_job_id = 1,
        };
    }

    fn deinit(self: *StandInZygote) void {
        std.posix.close(self.spawned.pidfd);
        closeAll(&self.pair);
    }

    /// The zygote's end of the control socket.
    fn zygoteEnd(self: *const StandInZygote) std.posix.fd_t {
        return self.pair[1];
    }

    fn closeAll(fds: []std.posix.fd_t) void {
        for (fds) |*fd| {
            if (fd.* >= 0)
                std.posix.close(fd.*);
            fd.* = -1;
        }
    }
};

/// Descriptors the test process has open, from `/proc/self/fd`.
fn openFdCount() !usize {
    var dir = try std.fs.openDirAbsolute("/proc/self/fd", .{ .iterate = true });
    defer dir.close();
    var count: usize = 0;
    var entries = dir.iterate();
    while (try entries.next()) |_|
        count += 1;
    return count;
}

/// Answers the fork request queued on the zygote's end with a child of
/// `reply_job_id`: two eventfds stand in for its init socket and pidfd,
/// which the reply duplicates, so the test closes its own copies.
fn answerFork(stand_in: *const StandInZygote, reply_job_id: u64, pid: u32) !void {
    const init_stand_in = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC);
    defer std.posix.close(init_stand_in);
    const pidfd_stand_in = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC);
    defer std.posix.close(pidfd_stand_in);
    try ipc.sendForkReply(stand_in.zygoteEnd(), reply_job_id, pid, init_stand_in, pidfd_stand_in);
}

test "a fork request carries its job to the zygote and the reply comes back as the forked child of that job" {
    var stand_in: StandInZygote = undefined;
    try stand_in.init();
    defer stand_in.deinit();

    try host_client.sendForkRequest(&stand_in.spawned, 7, null);
    // The job ids a later request takes start past this one.
    try std.testing.expectEqual(@as(u64, 8), stand_in.spawned.next_fork_job_id);
    var request = try ipc.recvForkRequestWithFd(stand_in.zygoteEnd());
    defer request.deinit();
    try std.testing.expectEqual(@as(u64, 7), request.message.fork_job_id);
    try std.testing.expect(request.cgroup_dir_fd == null);

    try answerFork(&stand_in, 7, 4242);
    var forked = try host_client.receiveForkReply(&stand_in.spawned, 7);
    defer forked.deinit();
    try std.testing.expectEqual(@as(u32, 4242), forked.pid);
    try std.testing.expectEqual(@as(u64, 7), forked.fork_job_id);
    try std.testing.expect(forked.worker_init_fd != null);
    try std.testing.expect(forked.pidfd != null);
    try std.testing.expect(forked.cgroup_dir_fd == null);
}

test "a fork reply that names another job is a protocol failure and leaves no descriptor behind" {
    var stand_in: StandInZygote = undefined;
    try stand_in.init();
    defer stand_in.deinit();

    try host_client.sendForkRequest(&stand_in.spawned, 7, null);
    var request = try ipc.recvForkRequestWithFd(stand_in.zygoteEnd());
    request.deinit();
    try answerFork(&stand_in, 8, 4242);
    const before = try openFdCount();
    try std.testing.expectError(error.ZygoteProtocol, host_client.receiveForkReply(&stand_in.spawned, 7));
    // The receive installed the reply's two descriptors and closed them.
    try std.testing.expectEqual(before, try openFdCount());
}

test "a fork the zygote refuses reads as a transient failure" {
    var stand_in: StandInZygote = undefined;
    try stand_in.init();
    defer stand_in.deinit();

    try host_client.sendForkRequest(&stand_in.spawned, 7, null);
    var request = try ipc.recvForkRequestWithFd(stand_in.zygoteEnd());
    request.deinit();
    try ipc.sendForkFailed(stand_in.zygoteEnd(), 7);
    try std.testing.expectError(error.ForkTransientFailure, host_client.receiveForkReply(&stand_in.spawned, 7));
}

test "a zygote that closed its control socket reads as dead, not as a broken protocol" {
    var stand_in: StandInZygote = undefined;
    try stand_in.init();
    defer stand_in.deinit();

    try host_client.sendForkRequest(&stand_in.spawned, 7, null);
    // The zygote closes its end only as it exits, even while its pidfd does
    // not report the exit yet.
    std.posix.close(stand_in.pair[1]);
    stand_in.pair[1] = -1;
    try std.testing.expectError(error.ZygoteDied, host_client.receiveForkReply(&stand_in.spawned, 7));
}

test "zygote ready wait times out before blocking receive" {
    const pair = try fd_mod.socketPairType(ipc_socket_type);
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);

    try std.testing.expectError(error.ZygoteReadyTimeout, host_client.recvZygoteReadyBeforeTimeout(pair[1], null, 0));
}

test "zygote ready wait receives ready message before timeout" {
    const pair = try fd_mod.socketPairType(ipc_socket_type);
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);

    try ipc.sendZygoteReady(pair[0]);
    _ = try host_client.recvZygoteReadyBeforeTimeout(pair[1], null, 1_000);
}

test "worker init outcome wait times out before blocking receive" {
    const pair = try fd_mod.socketPairType(ipc_socket_type);
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);
    const self_pidfd = try process.openPidFd(@intCast(std.c.getpid()));
    defer std.posix.close(self_pidfd);

    try std.testing.expectError(error.WorkerInitTimeout, host_client.receiveWorkerInitOutcomeBeforeTimeout(pair[1], self_pidfd, null, 0));
}

test "worker init outcome wait receives outcome before timeout" {
    const pair = try fd_mod.socketPairType(ipc_socket_type);
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);
    const self_pidfd = try process.openPidFd(@intCast(std.c.getpid()));
    defer std.posix.close(self_pidfd);

    try ipc.sendWorkerReady(pair[0]);
    try std.testing.expectEqual(host_client.WorkerInitOutcome.ready, try host_client.receiveWorkerInitOutcomeBeforeTimeout(pair[1], self_pidfd, null, 1_000));
}

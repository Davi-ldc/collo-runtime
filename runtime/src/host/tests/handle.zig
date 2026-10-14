//! A ready worker's teardown (`host/handle.zig`) on a real child process: the
//! control socket's close ends the worker, the teardown waits for that exit
//! instead of killing, and then removes the worker's leaf by its name and
//! closes every descriptor. A plain directory under a temp dir stands in for
//! the leaf; the kill through `cgroup.kill` of a leaf that still has a member
//! needs a cgroup2 mount and runs in `zygote-integration`. Lane `host-test`.

const std = @import("std");
const ipc = @import("collo_ipc");
const fd_mod = @import("collo_os").fd;
const process = @import("collo_os").process;
const os_linux = @import("collo_os").linux;
const host = @import("collo_host");
const worker_shared_page = @import("collo_worker_state").page;

/// A payload ring view with no mapping, whose teardown unmaps nothing.
var inert_payload_bytes: [0]u8 align(std.heap.page_size_min) = .{};
var inert_payload_header: ipc.ingress_channel.SharedPayloadHeader = std.mem.zeroes(ipc.ingress_channel.SharedPayloadHeader);

fn expectClosed(fd: std.posix.fd_t) !void {
    const rc = std.os.linux.fcntl(fd, std.posix.F.GETFD, 0);
    try std.testing.expectEqual(std.posix.E.BADF, os_linux.syscallErrno(rc));
}

test "a handle's teardown closes the control socket, waits for the worker's exit and removes its leaf by name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("worker-11");

    const control = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    const child_pid = try std.posix.fork();
    if (child_pid == 0) {
        // Only raw syscalls here: the test binary may be multithreaded, and
        // fork cloned only the calling thread. The child waits for its end of
        // the control socket to hang up, as a worker's loop ends when the
        // server closes it, and exits cleanly.
        _ = std.os.linux.close(control[0]);
        var byte: [1]u8 = undefined;
        _ = std.os.linux.read(control[1], &byte, byte.len);
        std.os.linux.exit_group(0);
    }
    std.posix.close(control[1]);
    var collected = false;
    defer if (!collected) {
        std.posix.kill(child_pid, std.posix.SIG.KILL) catch |err| switch (err) {
            error.ProcessNotFound => {},
            else => std.log.warn("failed to kill the test's child pid={d}: {s}", .{ child_pid, @errorName(err) }),
        };
        _ = std.posix.waitpid(child_pid, 0);
    };
    const pidfd = try process.openPidFd(@intCast(child_pid));
    const page_fd = try worker_shared_page.createMemfd("collo-test-handle-page");
    defer std.posix.close(page_fd);
    const page = try worker_shared_page.mapHostReader(page_fd);
    const completion_eventfd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC);
    const credit_eventfd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC);

    var handle: host.WorkerHandle = .{
        .pid = @intCast(child_pid),
        .pidfd = pidfd,
        .control_fd = control[0],
        .leaf = .{ .workers_dir_fd = tmp.dir.fd, .job_id = 11 },
        .completion_eventfd = completion_eventfd,
        .ingress_payload_credit_eventfd = credit_eventfd,
        .ingress_payload = .{ .bytes = &inert_payload_bytes, .header = &inert_payload_header, .side = .server },
        .metrics = page,
    };
    handle.deinit();

    // A clean exit, not a kill: the teardown waited for the hang-up to end
    // the worker.
    const status = std.posix.waitpid(child_pid, 0).status;
    collected = true;
    try std.testing.expect(std.posix.W.IFEXITED(status));
    try std.testing.expectEqual(@as(u32, 0), std.posix.W.EXITSTATUS(status));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("worker-11", .{}));
    try expectClosed(control[0]);
    try expectClosed(pidfd);
    try expectClosed(completion_eventfd);
    try expectClosed(credit_eventfd);
}

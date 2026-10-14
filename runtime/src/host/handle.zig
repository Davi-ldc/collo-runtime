//! A ready worker as the host holds it: the process, its channels, and the
//! resources the host must release when the worker goes away. The launch
//! (`launch.zig`) builds it at `WorkerReady` and hands its fields over
//! whole; the server keeps it in the worker's record and tears it down on
//! the reaper's thread.
//!
//! The handle keeps only what the host still uses after ready. The state
//! page and the payload ring are mapped, so their memfds were closed once the
//! child held its own copies, and the cgroup leaf is named by the root's
//! workers directory and the fork job id (`cgroup_root.WorkerLeaf`), never by
//! a path. The worker's tmpfs lives in the worker's own mount namespace and
//! ends with it, so it leaves the host nothing to remove.

const std = @import("std");
const ipc = @import("collo_ipc");
const process = @import("collo_os").process;
const process_limits = @import("collo_limits").process;
const worker_shared_page = @import("collo_worker_state").page;

const cgroup_root = @import("cgroup_root.zig");
const dispatch = @import("dispatch.zig");

pub const WorkerHandle = struct {
    pid: u32,
    /// From the clone itself (CLONE_PIDFD); every kill and wait goes through
    /// it, never through `pid`, which the kernel reuses once the worker is
    /// reaped.
    pidfd: std.posix.fd_t,
    /// The per-worker control socket: WorkerInit went over it, and after
    /// ready it carries dispatch descriptors in and response frames and
    /// `request_done` out.
    control_fd: std.posix.fd_t,
    /// The leaf the worker was born in; `deinit` kills its members and
    /// removes it.
    leaf: cgroup_root.WorkerLeaf,
    /// The payload rings' wakes: the worker signals `completion_eventfd`,
    /// which the server's reader polls, and the server signals
    /// `ingress_payload_credit_eventfd` for the worker.
    completion_eventfd: std.posix.fd_t,
    ingress_payload_credit_eventfd: std.posix.fd_t,
    ingress_payload: ipc.ingress_channel.SharedPayloadView,
    /// The host's mapping of the state page, which the launch made. Every
    /// handle the launch hands over holds one until `deinit`; null only for a
    /// test fixture's handle that never had a page.
    metrics: ?worker_shared_page.HostReaderView,

    /// The channels a host reads a response of this worker on
    /// (`dispatch.readResponse`).
    pub fn responseChannels(self: *WorkerHandle) dispatch.ResponseChannels {
        return .{
            .control_fd = self.control_fd,
            .ingress_payload = &self.ingress_payload,
        };
    }

    /// Closes the control socket, waits for the worker to exit (SIGKILL
    /// after the exit-wait bound), then releases every resource in the order
    /// the kernel needs: the cgroup leaf last, once its member is gone.
    /// Blocks, so only a thread that may wait calls it.
    pub fn deinit(self: *WorkerHandle) void {
        std.posix.close(self.control_fd);
        var exited = process.waitForPidFdExit(self.pidfd, process_limits.PROCESS_EXIT_WAIT_MS) catch process.pidFdHasExited(self.pidfd);
        if (!exited) {
            process.pidFdSendSignal(self.pidfd, std.posix.SIG.KILL) catch |err| switch (err) {
                error.ProcessNotFound => {},
                else => std.log.warn("failed to SIGKILL stubborn worker pid {d}: {s}", .{ self.pid, @errorName(err) }),
            };
            exited = process.waitForPidFdExit(self.pidfd, process_limits.PROCESS_EXIT_WAIT_MS) catch process.pidFdHasExited(self.pidfd);
            if (!exited)
                std.log.warn("worker pid {d} did not report exit after SIGKILL; attempting resource cleanup anyway", .{self.pid});
        }
        if (self.metrics) |*metrics|
            metrics.deinit();
        self.ingress_payload.deinit();
        std.posix.close(self.ingress_payload_credit_eventfd);
        std.posix.close(self.completion_eventfd);
        self.leaf.remove();
        std.posix.close(self.pidfd);
        self.* = undefined;
    }
};

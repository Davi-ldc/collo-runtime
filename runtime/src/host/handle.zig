//! A ready worker as the host holds it: the process, its channels, and the
//! resources the host must release when the worker goes away.

const std = @import("std");
const ipc = @import("collo_ipc");
const process = @import("collo_os").process;
const process_limits = @import("collo_limits").process;
const worker_shared_page = @import("collo_worker_state").page;

const cgroup = @import("cgroup.zig");
const dispatch = @import("dispatch.zig");

pub const WorkerHandle = struct {
    allocator: std.mem.Allocator,
    pid: u32,
    pidfd: std.posix.fd_t,
    /// The per-worker control socket: WorkerInit went over it, and after
    /// ready it carries dispatch descriptors in and response frames out.
    control_fd: std.posix.fd_t,
    tmp_root: []u8,
    cgroup_dir: []u8,
    memory_limit_bytes: u64,
    /// The cgroup's CPU limit in cores (`cpu.max`). It travels with the
    /// memory limit, so whoever decides whether this worker may serve a route
    /// sees both limits its cgroup has.
    cpu_max_cores: u32,
    metrics_fd: std.posix.fd_t,
    completion_eventfd: std.posix.fd_t,
    ingress_payload_fd: std.posix.fd_t,
    ingress_payload_credit_eventfd: std.posix.fd_t,
    ingress_payload: ipc.ingress_channel.SharedPayloadView,
    /// The shared page the launch mapped; every handle `init` builds holds
    /// one until `deinit`, as does every handle `host/launch.zig` hands over.
    /// Null only for a handle that never had a page, which has nothing to
    /// drain.
    metrics: ?worker_shared_page.WorkerWriterView,
    /// Host end of the per-worker fs-fault SEQPACKET pair. Exactly one reader
    /// at a time across the worker's life: the launch serves module-eval
    /// faults and quiesces the channel before this handle exists; from then
    /// on whoever the host registers as the reader owns it.
    fs_fault_fd: std.posix.fd_t,

    pub fn init(
        allocator: std.mem.Allocator,
        pid: u32,
        pidfd: std.posix.fd_t,
        control_fd: std.posix.fd_t,
        tmp_root: []const u8,
        cgroup_dir: []const u8,
        memory_limit_bytes: u64,
        cpu_max_cores: u32,
        metrics_fd: std.posix.fd_t,
        completion_eventfd: std.posix.fd_t,
        ingress_payload_fd: std.posix.fd_t,
        ingress_payload_credit_eventfd: std.posix.fd_t,
        ingress_payload: ipc.ingress_channel.SharedPayloadView,
        metrics: worker_shared_page.WorkerWriterView,
        fs_fault_fd: std.posix.fd_t,
    ) !WorkerHandle {
        const owned_tmp_root = try allocator.dupe(u8, tmp_root);
        errdefer allocator.free(owned_tmp_root);
        const owned_cgroup_dir = try allocator.dupe(u8, cgroup_dir);
        errdefer allocator.free(owned_cgroup_dir);

        return .{
            .allocator = allocator,
            .pid = pid,
            .pidfd = pidfd,
            .control_fd = control_fd,
            .tmp_root = owned_tmp_root,
            .cgroup_dir = owned_cgroup_dir,
            .memory_limit_bytes = memory_limit_bytes,
            .cpu_max_cores = cpu_max_cores,
            .metrics_fd = metrics_fd,
            .completion_eventfd = completion_eventfd,
            .ingress_payload_fd = ingress_payload_fd,
            .ingress_payload_credit_eventfd = ingress_payload_credit_eventfd,
            .ingress_payload = ingress_payload,
            .metrics = metrics,
            .fs_fault_fd = fs_fault_fd,
        };
    }

    /// The two channels a response comes back on. Requires the metrics page
    /// to still be mapped.
    pub fn completionChannels(self: *WorkerHandle) dispatch.CompletionChannels {
        return .{
            .control_fd = self.control_fd,
            .completion_eventfd = self.completion_eventfd,
            .metrics = &self.metrics.?,
            .ingress_payload = &self.ingress_payload,
        };
    }

    /// Closes the control socket, waits for the worker to exit (SIGKILL
    /// after the exit-wait bound), then releases every resource in the order
    /// the kernel needs: the cgroup leaf last, once its member is gone.
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
        if (self.fs_fault_fd >= 0)
            std.posix.close(self.fs_fault_fd);
        std.posix.close(self.ingress_payload_credit_eventfd);
        std.posix.close(self.ingress_payload_fd);
        std.posix.close(self.completion_eventfd);
        // -1 only for a handle that never had a shared page (`metrics`).
        if (self.metrics_fd >= 0)
            std.posix.close(self.metrics_fd);
        std.fs.deleteTreeAbsolute(self.tmp_root) catch |err| switch (err) {
            error.FileNotFound => {},
            else => std.log.warn("host resource leak: failed to delete tmp_root '{s}': {s}", .{ self.tmp_root, @errorName(err) }),
        };
        cgroup.cleanupWorker(self.cgroup_dir);
        std.posix.close(self.pidfd);
        self.allocator.free(self.tmp_root);
        self.allocator.free(self.cgroup_dir);
        self.* = undefined;
    }
};

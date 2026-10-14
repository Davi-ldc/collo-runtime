//! The host's side of the zygote contract: spawning the zygote, the fork
//! requests and their replies, and each child's WorkerInit outcome. It runs
//! in the host process, and `SpawnedZygote` has no lock. In the server, the
//! thread that boots and stops the server spawns the zygote and tears it down
//! (`server/boot/root.zig`), the launcher thread sends every fork request
//! (`server/supervisor/launcher.zig`), and the lanes only read the zygote's
//! pidfd. Test harnesses fork from a thread they own, through the blocking
//! driver in `runtime/tests/support/zygote/root.zig`; the benchmarks carry
//! their own copy of it (`runtime/bench/host_lifecycle.zig:forkWorker`).
//!
//! A fork comes in two halves, `sendForkRequest` and `receiveForkReply`, so a
//! host waits for the reply among its other descriptors.
//!
//! Invariants:
//! - One fork request is in flight at a time. The zygote answers requests in
//!   order on one control socket, so a host reads the reply to a request
//!   before it sends the next.
//! - A missed reply kills the zygote. When none comes within
//!   `fork_reply_timeout_ms`, `killUnresponsiveZygote` sends SIGKILL, since a
//!   late reply would be read as the answer to the next request; the
//!   zygote's death is then the only failure left, and its pidfd reports it.
//! - Every fork request carries the child's cgroup leaf, and the caller
//!   alone picks fork job ids.
//! - The spawn starts the zygote by the launch contract `fork_loop.zig`
//!   declares: `fork_loop.environment` as its whole environment, and the
//!   trace pipe only when the caller asks for one.

const std = @import("std");
const ipc = @import("collo_ipc");
const fd_mod = @import("collo_os").fd;
const process = @import("collo_os").process;
const process_limits = @import("collo_limits").process;
const fork_loop = @import("fork_loop.zig");
const trace = @import("trace.zig");

const process_name = fork_loop.process_name;
const inherited_control_fd = fork_loop.inherited_control_fd;
const inherited_trace_fd = fork_loop.inherited_trace_fd;
const ipc_socket_type = fork_loop.ipc_socket_type;
const traceEvent = trace.traceEvent;
const tracePipe = trace.tracePipe;

// Bounds the zygote's boot: VM creation, the warmup corpus with its full GC and
// the helper-thread drain. It guards against a wedged zygote rather than
// measuring performance, so it is loose enough not to fail a healthy boot on a
// loaded machine.
const ZYGOTE_READY_TIMEOUT_MS: i32 = 5_000;
// Spawning the zygote cannot rely on request-scoped allocators.
const boot_allocator = std.heap.smp_allocator;
const PROCESS_REAP_CHECK_INTERVAL_NS: u64 = 10 * std.time.ns_per_ms;
const PROCESS_REAP_MAX_CHECKS: u32 = 100;

pub const SpawnOptions = struct {
    /// The binary to run as the zygote; null runs this process's own, found
    /// through `/proc/self/exe`.
    executable_path: ?[]const u8 = null,
    /// Whether the host, the zygote and each child's boot write the trace
    /// (`trace.zig`). Without it no pipe exists, so no process of the node
    /// holds one and nothing has to drain it.
    trace: bool,
};

/// The host's handle for the zygote process and its control fds.
pub const SpawnedZygote = struct {
    pid: u32,
    pidfd: std.posix.fd_t,
    control_fd: ?std.posix.fd_t,
    /// The trace pipe's read end, and the write end for the host's own
    /// launch markers; both null when the spawn asked for no trace.
    trace_read_fd: ?std.posix.fd_t,
    trace_write_fd: ?std.posix.fd_t,

    pub fn shutdown(self: *SpawnedZygote) void {
        if (self.control_fd) |fd| {
            std.posix.close(fd);
            self.control_fd = null;
        }
        if (self.trace_write_fd) |fd| {
            std.posix.close(fd);
            self.trace_write_fd = null;
        }
    }

    pub fn deinit(self: *SpawnedZygote) void {
        self.shutdown();
        var exited = process.waitForPidFdExit(self.pidfd, process_limits.PROCESS_EXIT_WAIT_MS) catch process.pidFdHasExited(self.pidfd);
        if (!exited) {
            process.pidFdSendSignal(self.pidfd, std.posix.SIG.KILL) catch |err| switch (err) {
                error.ProcessNotFound => {},
                else => std.log.warn("failed to SIGKILL stubborn zygote pid {d}: {s}", .{ self.pid, @errorName(err) }),
            };
            exited = process.waitForPidFdExit(self.pidfd, process_limits.PROCESS_EXIT_WAIT_MS) catch process.pidFdHasExited(self.pidfd);
            if (!exited)
                std.log.warn("zygote pid {d} did not report exit after SIGKILL; closing resources anyway", .{self.pid});
        }
        if (exited)
            reapZygoteBestEffort(self.pid);
        if (self.trace_read_fd) |fd|
            std.posix.close(fd);
        std.posix.close(self.pidfd);
        self.* = undefined;
    }
};

fn reapZygoteBestEffort(pid: u32) void {
    var status: c_int = 0;
    var checks: u32 = 0;
    while (checks < PROCESS_REAP_MAX_CHECKS) : (checks += 1) {
        const rc = std.c.waitpid(@intCast(pid), &status, std.c.W.NOHANG);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) {
                    std.Thread.sleep(PROCESS_REAP_CHECK_INTERVAL_NS);
                    continue;
                }
                return;
            },
            .INTR => continue,
            .CHILD => return,
            else => |err| {
                std.log.warn("failed to reap zygote pid {d}: {s}", .{ pid, @tagName(err) });
                return;
            },
        }
    }
    std.log.warn("zygote pid {d} did not reap within cleanup window", .{pid});
}

/// The host's handle for a worker the zygote forked, before WorkerInit. The
/// cgroup leaf the child was born in stays with whoever created it, since
/// the request only lent it.
pub const ForkedWorker = struct {
    pid: u32,
    worker_init_fd: ?std.posix.fd_t,
    /// Created atomically by the fork and delivered with the fork reply. Kill
    /// and wait paths use it instead of `pid`, which the kernel can reuse once
    /// the auto-reaped child exits.
    pidfd: ?std.posix.fd_t = null,
    /// The job id the host picked for this fork; it names the worker's cgroup
    /// leaf.
    fork_job_id: u64,

    pub fn deinit(self: *ForkedWorker) void {
        if (self.worker_init_fd) |fd|
            std.posix.close(fd);
        if (self.pidfd) |fd|
            std.posix.close(fd);
        self.* = undefined;
    }
};

pub fn spawnZygote(options: SpawnOptions) !SpawnedZygote {
    const exe_path = if (options.executable_path) |path|
        try boot_allocator.dupe(u8, path)
    else
        try std.fs.selfExePathAlloc(boot_allocator);
    defer boot_allocator.free(exe_path);
    const exe_path_z = try boot_allocator.dupeZ(u8, exe_path);
    defer boot_allocator.free(exe_path_z);

    const raw_control_pair = try fd_mod.socketPairType(ipc_socket_type);
    var control_read = fd_mod.OwnedFd.fromRaw(raw_control_pair[0]);
    errdefer control_read.deinit();
    var control_write = fd_mod.OwnedFd.fromRaw(raw_control_pair[1]);
    errdefer control_write.deinit();

    var trace_read: fd_mod.OwnedFd = .{};
    errdefer trace_read.deinit();
    var trace_write: fd_mod.OwnedFd = .{};
    errdefer trace_write.deinit();
    if (options.trace) {
        const raw_trace_pair = try tracePipe();
        trace_read = fd_mod.OwnedFd.fromRaw(raw_trace_pair[0]);
        trace_write = fd_mod.OwnedFd.fromRaw(raw_trace_pair[1]);
    }

    // The zygote reads an open `inherited_trace_fd` as a trace pipe, so that
    // descriptor is mapped exactly when a trace was asked for.
    const all_targets = [_]std.posix.fd_t{ inherited_control_fd, inherited_trace_fd };
    const targets = all_targets[0..if (options.trace) all_targets.len else 1];
    var control_spawn_source: fd_mod.OwnedFd = .{};
    defer control_spawn_source.deinit();
    var trace_spawn_source: fd_mod.OwnedFd = .{};
    defer trace_spawn_source.deinit();
    var fd_map_buffer: [all_targets.len]process.SpawnFdMap = undefined;
    fd_map_buffer[0] = .{
        .source_fd = try spawnSourceFd(&control_spawn_source, control_write.fd(), targets),
        .target_fd = inherited_control_fd,
    };
    if (options.trace) {
        fd_map_buffer[1] = .{
            .source_fd = try spawnSourceFd(&trace_spawn_source, trace_write.fd(), targets),
            .target_fd = inherited_trace_fd,
        };
    }
    const arg0: [*:0]const u8 = (process_name ++ "\x00").ptr;
    const argv = [_:null]?[*:0]const u8{arg0};
    // The pidfd comes with the child, so from here on every failure can kill
    // and reap the zygote through it.
    var spawned = try process.spawnInternal(.{
        .exe_path_z = exe_path_z.ptr,
        .argv = &argv,
        .envp = &fork_loop.environment,
        .fd_map = fd_map_buffer[0..targets.len],
    });
    const zygote_pid = spawned.pid;
    errdefer {
        process.pidFdSendSignal(spawned.pidfd.fd(), std.posix.SIG.KILL) catch |err| switch (err) {
            error.ProcessNotFound => {},
            else => std.log.warn("failed to SIGKILL zygote after spawn failure pid={d}: {s}", .{ zygote_pid, @errorName(err) }),
        };
        _ = process.waitForPidFdExit(spawned.pidfd.fd(), process_limits.PROCESS_EXIT_WAIT_MS) catch |err| blk: {
            std.log.warn("failed to wait for zygote after spawn failure pid={d}: {s}", .{ zygote_pid, @errorName(err) });
            break :blk false;
        };
        spawned.pidfd.deinit();
        reapZygoteBestEffort(zygote_pid);
    }
    control_write.deinit();
    // The zygote inherits the host's oom_score_adj. Raising it to
    // `OOM_SCORE_ADJ_ZYGOTE` places the zygote after the workers and the
    // gateway and before the host in the kernel's OOM order
    // (`common/limits/process.zig`). This ordering is defense in depth, so a
    // failed write only warns.
    process.writeOomScoreAdj(zygote_pid, process_limits.OOM_SCORE_ADJ_ZYGOTE) catch |err|
        std.log.warn("failed to set zygote oom_score_adj pid={d}: {s}", .{ zygote_pid, @errorName(err) });
    const trace_write_fd: ?std.posix.fd_t = if (trace_write.isValid()) trace_write.fd() else null;
    _ = try recvZygoteReadyBeforeTimeout(control_read.fd(), trace_write_fd, ZYGOTE_READY_TIMEOUT_MS);
    return .{
        .pid = zygote_pid,
        .pidfd = spawned.pidfd.release(),
        .control_fd = control_read.release(),
        .trace_read_fd = if (trace_read.isValid()) trace_read.release() else null,
        .trace_write_fd = if (trace_write.isValid()) trace_write.release() else null,
    };
}

fn spawnSourceFd(
    temporary: *fd_mod.OwnedFd,
    source_fd: std.posix.fd_t,
    reserved_targets: []const std.posix.fd_t,
) !std.posix.fd_t {
    var min_spare_fd: std.posix.fd_t = 3;
    for (reserved_targets) |target_fd|
        min_spare_fd = @max(min_spare_fd, target_fd + 1);
    for (reserved_targets) |target_fd| {
        if (source_fd != target_fd)
            continue;
        temporary.* = try fd_mod.OwnedFd.dupCloexecAtLeast(source_fd, min_spare_fd);
        return temporary.fd();
    }
    return source_fd;
}

/// Bound on a fork request's round trip. The fork takes well under a
/// millisecond; the budget covers a zygote briefly stalled by CPU contention.
/// A miss cannot be recovered by waiting longer: the control socket carries
/// one request at a time, so a late reply would be read as the answer to the
/// next request.
pub const fork_reply_timeout_ms: i32 = 5_000;

/// Why a fork produced no child. `ForkTransientFailure`: the zygote refused
/// this fork and serves the next one (`sendForkFailed` in
/// `common/ipc/zygote_worker.zig`). `ZygoteDied`: the zygote exited or closed
/// its control socket, which it does only as it exits. `ZygoteProtocol`: the
/// control socket failed or carried something the protocol does not allow.
pub const ForkError = error{ ForkTransientFailure, ZygoteDied, ZygoteProtocol };

/// Asks the zygote to fork the child of `fork_job_id`, born into the cgroup
/// leaf `cgroup_dir_fd`; the descriptor stays the caller's. The caller reads
/// the reply with `receiveForkReply` before it sends again, and when no reply
/// is readable within `fork_reply_timeout_ms` of this send it calls
/// `killUnresponsiveZygote`.
pub fn sendForkRequest(
    zygote: *SpawnedZygote,
    fork_job_id: u64,
    cgroup_dir_fd: std.posix.fd_t,
) error{ ZygoteDied, ZygoteProtocol }!void {
    const control_fd = zygote.control_fd orelse return error.ZygoteProtocol;
    if (process.pidFdHasExited(zygote.pidfd))
        return error.ZygoteDied;
    ipc.sendForkRequest(control_fd, fork_job_id, cgroup_dir_fd) catch |err|
        return zygoteFailure(zygote, err);
}

/// Reads the reply to the fork request `sendForkRequest` sent for
/// `fork_job_id`. Call it once the control socket polls readable, hung up or
/// in error; on a socket with nothing queued it blocks. The worker returned
/// owns the child's init socket and pidfd and names `fork_job_id`.
pub fn receiveForkReply(zygote: *SpawnedZygote, fork_job_id: u64) ForkError!ForkedWorker {
    const control_fd = zygote.control_fd orelse return error.ZygoteProtocol;
    var reply = ipc.recvForkReply(control_fd) catch |err| switch (err) {
        error.ForkTransientFailure => return error.ForkTransientFailure,
        else => return zygoteFailure(zygote, err),
    };
    if (reply.message.fork_job_id != fork_job_id) {
        reply.deinit();
        return error.ZygoteProtocol;
    }
    return .{
        .pid = reply.message.pid,
        .worker_init_fd = reply.worker_init_fd,
        .pidfd = reply.worker_pidfd,
        .fork_job_id = fork_job_id,
    };
}

/// Kills a zygote whose reply to `fork_job_id` did not come within
/// `fork_reply_timeout_ms`, so that the zygote's death is the only failure
/// left to handle: left alive, its late reply would arrive as the answer to
/// the next request. Sends SIGKILL and does not wait; the zygote's pidfd
/// reports the exit.
pub fn killUnresponsiveZygote(zygote: *SpawnedZygote, fork_job_id: u64) void {
    std.log.err(
        "zygote fork reply timed out after {d}ms fork_job_id={d}; killing zygote",
        .{ fork_reply_timeout_ms, fork_job_id },
    );
    process.pidFdSendSignal(zygote.pidfd, std.posix.SIG.KILL) catch |err| switch (err) {
        error.ProcessNotFound => {},
        else => std.log.warn("failed to kill unresponsive zygote: {s}", .{@errorName(err)}),
    };
}

/// The fork failure a control-socket error stands for. The zygote closes its
/// end only as it exits, so a hang-up is its death; any other error is its
/// death once its pidfd says so, and a broken protocol before that.
pub fn zygoteFailure(zygote: *SpawnedZygote, err: anyerror) error{ ZygoteDied, ZygoteProtocol } {
    return switch (err) {
        error.PeerClosed,
        error.BrokenPipe,
        error.ConnectionResetByPeer,
        => error.ZygoteDied,
        else => if (process.pidFdHasExited(zygote.pidfd)) error.ZygoteDied else error.ZygoteProtocol,
    };
}

/// Reads the child's one answer to WorkerInit on its init socket
/// (`ipc.recvInitOutcome` says how a read fails).
pub fn receiveWorkerInitOutcome(fd: std.posix.fd_t) !ipc.InitOutcome {
    return ipc.recvInitOutcome(fd);
}

/// Waits up to `timeout_ms` for the zygote's `ZygoteReady`, then reads it. A
/// zygote that stays silent fails with `error.ZygoteReadyTimeout`.
pub fn recvZygoteReadyBeforeTimeout(fd: std.posix.fd_t, trace_fd: ?std.posix.fd_t, timeout_ms: i32) !ipc.ZygoteReady {
    var pollfds = [1]std.posix.pollfd{
        .{
            .fd = fd,
            .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR,
            .revents = 0,
        },
    };

    const ready = try std.posix.poll(&pollfds, timeout_ms);
    if (ready == 0) {
        traceEvent(trace_fd, "host.zygote_ready.timeout");
        return error.ZygoteReadyTimeout;
    }

    return ipc.recvZygoteReady(fd);
}

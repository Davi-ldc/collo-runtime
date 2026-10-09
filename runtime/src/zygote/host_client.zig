//! The host's side of the zygote contract: spawning the zygote, the fork
//! requests and their replies, and the wait for each child's WorkerInit
//! outcome. It runs in the host process, and `SpawnedZygote` has no lock. In
//! the server, the thread that boots and stops the server spawns the zygote
//! and tears it down (`server/boot/root.zig`), the launcher thread sends
//! every fork request (`server/supervisor/launcher.zig`), and the lanes only
//! read the zygote's pidfd. Test harnesses and benchmarks fork from a thread
//! they own.
//!
//! A fork comes in two halves, `sendForkRequest` and `receiveForkReply`, so a
//! host with its own poll set (the server's launcher) waits for the reply
//! among its other descriptors; `requestForkWithJobId` joins the halves with
//! a blocking wait for hosts that own their thread.
//!
//! Invariants:
//! - One fork request is in flight at a time. The zygote answers requests in
//!   order on one control socket, so a host reads the reply to a request
//!   before it sends the next.
//! - A missed reply kills the zygote. When none comes within
//!   `fork_reply_timeout_ms`, `killUnresponsiveZygote` sends SIGKILL, since a
//!   late reply would be read as the answer to the next request; the
//!   zygote's death is then the only failure left, and its pidfd reports it.
//! - The spawn starts the zygote by the launch contract `fork_loop.zig`
//!   declares, with the worker's environment
//!   (`worker_environment_canonical_values` in `child_boot.zig` says why).

const std = @import("std");
const ipc = @import("collo_ipc");
const fd_mod = @import("collo_os").fd;
const process = @import("collo_os").process;
const process_limits = @import("collo_limits").process;
const child_boot = @import("child_boot.zig");
const fork_loop = @import("fork_loop.zig");
const state = @import("state.zig");
const trace = @import("trace.zig");

const process_name = fork_loop.process_name;
const inherited_control_fd = fork_loop.inherited_control_fd;
const inherited_trace_fd = fork_loop.inherited_trace_fd;
const ipc_socket_type = fork_loop.ipc_socket_type;
const zygote_env_vm_flags = fork_loop.zygote_env_vm_flags;
const zygote_env_postfork_exit_probe_path = fork_loop.zygote_env_postfork_exit_probe_path;
const zygote_env_warmup_corpus = fork_loop.zygote_env_warmup_corpus;
const zygote_generated_env_count = fork_loop.zygote_generated_env_count;
const worker_environment_retained_names = child_boot.worker_environment_retained_names;
const worker_environment_canonical_values = child_boot.worker_environment_canonical_values;
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
// Re-exported for harnesses that import this module but not collo_limits. The
// host sets a worker's init deadline at CLOCK_MONOTONIC plus the timeout, and
// the child arms its boot-evaluation watchdog at that deadline minus the
// cleanup reserve.
pub const worker_init_timeout_ms = process_limits.WORKER_INIT_TIMEOUT_MS;
pub const worker_init_cleanup_reserve_ns = process_limits.WORKER_INIT_CLEANUP_RESERVE_NS;

/// The host's handle for the zygote process and its control fds.
pub const SpawnedZygote = struct {
    pid: u32,
    pidfd: std.posix.fd_t,
    control_fd: ?std.posix.fd_t,
    trace_read_fd: ?std.posix.fd_t,
    trace_write_fd: ?std.posix.fd_t,
    next_fork_job_id: u64,

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

const SpawnCleanup = struct {
    pid: u32,
    pidfd: ?std.posix.fd_t = null,
    active: bool = true,

    fn disarm(self: *SpawnCleanup) void {
        self.active = false;
    }

    fn cleanup(self: *SpawnCleanup) void {
        if (!self.active)
            return;
        self.active = false;

        if (self.pidfd) |pidfd| {
            process.pidFdSendSignal(pidfd, std.posix.SIG.KILL) catch |err| switch (err) {
                error.ProcessNotFound => {},
                else => std.log.warn("failed to SIGKILL spawned zygote pid={d}: {s}", .{ self.pid, @errorName(err) }),
            };
            _ = process.waitForPidFdExit(pidfd, process_limits.PROCESS_EXIT_WAIT_MS) catch |err| blk: {
                std.log.warn("failed to wait for spawned zygote pid={d}: {s}", .{ self.pid, @errorName(err) });
                break :blk false;
            };
        } else {
            std.posix.kill(@intCast(self.pid), std.posix.SIG.KILL) catch |err| switch (err) {
                error.ProcessNotFound => {},
                else => std.log.warn("failed to SIGKILL spawned zygote by pid={d}: {s}", .{ self.pid, @errorName(err) }),
            };
        }
        reapZygoteBestEffort(self.pid);
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

/// The host's handle for a worker the zygote forked, before WorkerInit.
pub const ForkedWorker = struct {
    pid: u32,
    worker_init_fd: ?std.posix.fd_t,
    /// Created atomically by the fork and delivered with the fork reply. Kill
    /// and wait paths use it instead of `pid`, which the kernel can reuse once
    /// the auto-reaped child exits.
    pidfd: ?std.posix.fd_t = null,
    /// Job id the host reserved for this fork; it names the worker's cgroup
    /// directory.
    fork_job_id: u64 = 0,
    /// The worker's cgroup directory, created by the host before the fork; the
    /// child is born inside it. This module only closes the fd; removing the
    /// directory is the host's decision.
    cgroup_dir_fd: ?std.posix.fd_t = null,

    pub fn deinit(self: *ForkedWorker) void {
        if (self.worker_init_fd) |fd|
            std.posix.close(fd);
        if (self.pidfd) |fd|
            std.posix.close(fd);
        if (self.cgroup_dir_fd) |fd|
            std.posix.close(fd);
        self.* = undefined;
    }
};

/// Worker child startup result sent back across the WorkerInit control socket.
pub const WorkerInitOutcome = union(enum) {
    ready,
    failed: ipc.WorkerInitFailedReason,
};

pub fn spawnZygote(options: state.ZygoteOptions) !SpawnedZygote {
    const exe_path = if (options.executable_path) |path|
        try boot_allocator.dupe(u8, path)
    else
        try std.fs.selfExePathAlloc(boot_allocator);
    defer boot_allocator.free(exe_path);
    const exe_path_z = try boot_allocator.dupeZ(u8, exe_path);
    defer boot_allocator.free(exe_path_z);
    var zygote_env = try OwnedZygoteEnv.init(boot_allocator, options);
    defer zygote_env.deinit(boot_allocator);

    const raw_control_pair = try fd_mod.socketPairType(ipc_socket_type);
    var control_read = fd_mod.OwnedFd.fromRaw(raw_control_pair[0]);
    errdefer control_read.deinit();
    var control_write = fd_mod.OwnedFd.fromRaw(raw_control_pair[1]);
    errdefer control_write.deinit();

    const raw_trace_pair = try tracePipe();
    var trace_read = fd_mod.OwnedFd.fromRaw(raw_trace_pair[0]);
    errdefer trace_read.deinit();
    var trace_write = fd_mod.OwnedFd.fromRaw(raw_trace_pair[1]);
    errdefer trace_write.deinit();

    var control_spawn_source: fd_mod.OwnedFd = .{};
    defer control_spawn_source.deinit();
    var trace_spawn_source: fd_mod.OwnedFd = .{};
    defer trace_spawn_source.deinit();
    const inherited_fds = [_]std.posix.fd_t{
        inherited_control_fd,
        inherited_trace_fd,
    };
    const control_source_fd = try spawnSourceFd(
        &control_spawn_source,
        control_write.fd(),
        &inherited_fds,
    );
    const trace_source_fd = try spawnSourceFd(
        &trace_spawn_source,
        trace_write.fd(),
        &inherited_fds,
    );
    const arg0: [*:0]const u8 = (process_name ++ "\x00").ptr;
    const argv = [_:null]?[*:0]const u8{arg0};
    const fd_map = [_]process.SpawnFdMap{
        .{
            .source_fd = control_source_fd,
            .target_fd = inherited_control_fd,
        },
        .{
            .source_fd = trace_source_fd,
            .target_fd = inherited_trace_fd,
        },
    };
    const pid = try process.spawnInternal(.{
        .exe_path_z = exe_path_z.ptr,
        .argv = &argv,
        .envp = zygote_env.ptr(),
        .fd_map = &fd_map,
    });

    control_write.deinit();
    const zygote_pid: u32 = @intCast(pid);
    var spawn_cleanup = SpawnCleanup{ .pid = zygote_pid };
    errdefer spawn_cleanup.cleanup();
    var pidfd = fd_mod.OwnedFd.fromRaw(try process.openPidFd(zygote_pid));
    spawn_cleanup.pidfd = pidfd.fd();
    errdefer {
        process.pidFdSendSignal(pidfd.fd(), std.posix.SIG.KILL) catch |err| switch (err) {
            error.ProcessNotFound => {},
            else => std.log.warn("failed to SIGKILL zygote after spawn failure pid={d}: {s}", .{ zygote_pid, @errorName(err) }),
        };
        _ = process.waitForPidFdExit(pidfd.fd(), process_limits.PROCESS_EXIT_WAIT_MS) catch |err| blk: {
            std.log.warn("failed to wait for zygote after spawn failure pid={d}: {s}", .{ zygote_pid, @errorName(err) });
            break :blk false;
        };
        pidfd.deinit();
        spawn_cleanup.pidfd = null;
        reapZygoteBestEffort(zygote_pid);
        spawn_cleanup.disarm();
    }
    // The zygote inherits the host's oom_score_adj. Raising it places the
    // zygote after workers and before the gateway and the host in the kernel's
    // OOM order. This ordering is defense in depth, so a failed write only
    // warns.
    process.writeOomScoreAdj(zygote_pid, process_limits.OOM_SCORE_ADJ_ZYGOTE) catch |err|
        std.log.warn("failed to set zygote oom_score_adj pid={d}: {s}", .{ zygote_pid, @errorName(err) });
    _ = try recvZygoteReadyBeforeTimeout(control_read.fd(), trace_write.fd(), ZYGOTE_READY_TIMEOUT_MS);
    spawn_cleanup.disarm();
    return .{
        .pid = zygote_pid,
        .pidfd = pidfd.release(),
        .control_fd = control_read.release(),
        .trace_read_fd = trace_read.release(),
        .trace_write_fd = trace_write.release(),
        .next_fork_job_id = 1,
    };
}

pub fn requestFork(zygote: *SpawnedZygote) !ForkedWorker {
    const fork_job_id = zygote.next_fork_job_id;
    zygote.next_fork_job_id += 1;
    return requestForkWithJobId(zygote, fork_job_id, null);
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

const OwnedZygoteEnv = struct {
    entries: []?[*:0]const u8,
    strings: []?[:0]u8,

    fn init(allocator: std.mem.Allocator, options: state.ZygoteOptions) !OwnedZygoteEnv {
        const capacity = worker_environment_retained_names.len + zygote_generated_env_count;
        const entries = try allocator.alloc(?[*:0]const u8, capacity + 1);
        errdefer allocator.free(entries);
        const strings = try allocator.alloc(?[:0]u8, capacity);
        errdefer allocator.free(strings);
        @memset(entries, null);
        @memset(strings, null);

        var len: usize = 0;
        errdefer {
            for (strings) |maybe_string| {
                if (maybe_string) |string|
                    allocator.free(string);
            }
        }

        for (worker_environment_retained_names, worker_environment_canonical_values) |name, value| {
            try appendEnvEntry(allocator, entries, strings, &len, name, value);
        }

        var flags_buffer: [16]u8 = undefined;
        try appendEnvEntry(
            allocator,
            entries,
            strings,
            &len,
            zygote_env_vm_flags,
            try std.fmt.bufPrint(&flags_buffer, "{d}", .{options.vm_options.flags}),
        );
        if (options.postfork_exit_probe_path) |path| {
            try appendEnvEntry(
                allocator,
                entries,
                strings,
                &len,
                zygote_env_postfork_exit_probe_path,
                path,
            );
        }
        if (options.warmup_corpus) {
            try appendEnvEntry(
                allocator,
                entries,
                strings,
                &len,
                zygote_env_warmup_corpus,
                "1",
            );
        }
        entries[len] = null;
        return .{
            .entries = entries,
            .strings = strings,
        };
    }

    fn deinit(self: *OwnedZygoteEnv, allocator: std.mem.Allocator) void {
        for (self.strings) |maybe_string| {
            if (maybe_string) |string|
                allocator.free(string);
        }
        allocator.free(self.strings);
        allocator.free(self.entries);
        self.* = undefined;
    }

    fn ptr(self: *const OwnedZygoteEnv) [*:null]?[*:0]const u8 {
        return @ptrCast(self.entries.ptr);
    }
};

fn appendEnvEntry(
    allocator: std.mem.Allocator,
    entries: []?[*:0]const u8,
    strings: []?[:0]u8,
    len: *usize,
    name: []const u8,
    value: []const u8,
) !void {
    std.debug.assert(len.* < strings.len);
    const entry = try std.fmt.allocPrintSentinel(allocator, "{s}={s}", .{ name, value }, 0);
    strings[len.*] = entry;
    entries[len.*] = entry.ptr;
    len.* += 1;
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

/// Waits, bounded, for the fork reply to become readable. A timeout means the
/// zygote is alive but wedged, and its reply stream can no longer be trusted.
pub fn waitForkReplyReadable(control_fd: std.posix.fd_t, timeout_ms: i32) !void {
    var pollfds = [_]std.posix.pollfd{.{
        .fd = control_fd,
        .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR,
        .revents = 0,
    }};
    const ready = try std.posix.poll(&pollfds, timeout_ms);
    if (ready == 0)
        return error.ZygoteUnresponsive;
    // HUP and ERR fall through so the caller's receive reports the exact error.
}

/// Asks the zygote to fork the child of `fork_job_id`, born into the cgroup
/// leaf `cgroup_dir_fd` when there is one; the descriptor stays the caller's.
/// The caller reads the reply with `receiveForkReply` before it sends again,
/// and when no reply is readable within `fork_reply_timeout_ms` of this send
/// it calls `killUnresponsiveZygote`.
pub fn sendForkRequest(
    zygote: *SpawnedZygote,
    fork_job_id: u64,
    cgroup_dir_fd: ?std.posix.fd_t,
) error{ ZygoteDied, ZygoteProtocol }!void {
    const control_fd = zygote.control_fd orelse return error.ZygoteProtocol;
    if (process.pidFdHasExited(zygote.pidfd))
        return error.ZygoteDied;
    if (fork_job_id >= zygote.next_fork_job_id)
        zygote.next_fork_job_id = fork_job_id + 1;
    ipc.sendForkRequestWithCgroupFd(control_fd, fork_job_id, cgroup_dir_fd) catch |err|
        return zygoteFailure(zygote, err);
}

/// Reads the reply to the fork request `sendForkRequest` sent for
/// `fork_job_id`. Call it once the control socket polls readable, hung up or
/// in error; on a socket with nothing queued it blocks. The worker returned
/// owns the child's init socket and pidfd and names `fork_job_id`; the caller
/// adds the cgroup leaf it sent with the request.
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

/// Forks the child of `fork_job_id` and waits for it: `sendForkRequest`, a
/// wait of at most `fork_reply_timeout_ms`, then `receiveForkReply`. A zygote
/// that misses the reply is killed (`killUnresponsiveZygote`) and the call
/// fails with `ZygoteDied`. Blocks, so only a host that owns its thread calls
/// it.
pub fn requestForkWithJobId(
    zygote: *SpawnedZygote,
    fork_job_id: u64,
    cgroup_dir_fd: ?std.posix.fd_t,
) ForkError!ForkedWorker {
    try sendForkRequest(zygote, fork_job_id, cgroup_dir_fd);
    const control_fd = zygote.control_fd orelse return error.ZygoteProtocol;
    waitForkReplyReadable(control_fd, fork_reply_timeout_ms) catch |err| switch (err) {
        error.ZygoteUnresponsive => {
            killUnresponsiveZygote(zygote, fork_job_id);
            return error.ZygoteDied;
        },
        else => return zygoteFailure(zygote, err),
    };
    return receiveForkReply(zygote, fork_job_id);
}

/// The fork failure a control-socket error stands for. The zygote closes its
/// end only as it exits, so a hang-up is its death; any other error is its
/// death once its pidfd says so, and a broken protocol before that.
fn zygoteFailure(zygote: *SpawnedZygote, err: anyerror) error{ ZygoteDied, ZygoteProtocol } {
    return switch (err) {
        error.PeerClosed,
        error.BrokenPipe,
        error.ConnectionResetByPeer,
        => error.ZygoteDied,
        else => if (process.pidFdHasExited(zygote.pidfd)) error.ZygoteDied else error.ZygoteProtocol,
    };
}

pub fn receiveWorkerInitOutcome(fd: std.posix.fd_t) !WorkerInitOutcome {
    return switch (try ipc.recvInitOutcome(fd)) {
        .ready => .ready,
        .failed => |reason| .{ .failed = reason },
    };
}

pub fn receiveWorkerInitOutcomeBeforeTimeout(
    fd: std.posix.fd_t,
    pidfd: std.posix.fd_t,
    trace_fd: ?std.posix.fd_t,
    timeout_ms: i32,
) !WorkerInitOutcome {
    var pollfds = [2]std.posix.pollfd{
        .{
            .fd = fd,
            .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR,
            .revents = 0,
        },
        .{
            .fd = pidfd,
            .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR,
            .revents = 0,
        },
    };

    const ready = try std.posix.poll(&pollfds, timeout_ms);
    if (ready == 0) {
        traceEvent(trace_fd, "host.worker_init.timeout");
        return error.WorkerInitTimeout;
    }

    if ((pollfds[0].revents & std.posix.POLL.IN) != 0)
        return receiveWorkerInitOutcome(fd);

    if ((pollfds[1].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0) {
        traceEvent(trace_fd, "host.worker_init.worker_exited");
        return error.WorkerInitFailed;
    }

    if ((pollfds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0)
        return receiveWorkerInitOutcome(fd);

    return error.WorkerInitTimeout;
}

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

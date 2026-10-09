//! The zygote process: its entry from the launch the host set up
//! (`spawnZygote` in `host_client.zig`), its boot preparation, and the fork
//! loop that serves the host's fork requests. It runs on the zygote's main
//! thread. The launch contract is declared here: the zygote runs under
//! `process_name`, with its control socket at `inherited_control_fd`, the
//! write end of the trace pipe at `inherited_trace_fd` and its options in the
//! `zygote_env_*` variables.
//!
//! Invariants:
//! - The zygote is single-threaded at every fork. A fork from a
//!   multi-threaded process can leave a lock held forever by a thread the
//!   child does not have, and clone3 runs no pthread_atfork handlers. Boot
//!   preparation retires the engine's helper threads and proves the zygote
//!   single-threaded before it reports ready, and every fork checks again; a
//!   second thread ends the zygote.
//! - After `prepareZygoteAtBoot` the fork loop neither allocates nor touches
//!   the VM, so every worker inherits the same copy-on-write pages. The
//!   conventions gate `zygote fork loop stays VM-free and allocation-free
//!   after prepare` reads only the body of `serveForkRequests`; what it calls
//!   keeps the rule without a gate.
//! - A failure caused by one fork's resources refuses that fork, and the
//!   zygote keeps serving (`isTransientForkError`); any other failure ends
//!   the zygote.
//! - The kernel reaps every child (`installWorkerChildAutoReap`), so the
//!   zygote never waits for one.

const std = @import("std");
const bindings = @import("collo_bindings");
const decompress = @import("collo_egress_core").decompress;
const ipc = @import("collo_ipc");
const fd_mod = @import("collo_os").fd;
const process = @import("collo_os").process;
const process_limits = @import("collo_limits").process;
const child_boot = @import("child_boot.zig");
const state = @import("state.zig");
const trace = @import("trace.zig");
const warmup = @import("warmup.zig");
const worker_cgroup = @import("worker_boot/cgroup.zig");

const traceEvent = trace.traceEvent;
const traceEventFmt = trace.traceEventFmt;
const workerChildMain = child_boot.workerChildMain;

pub const process_name = "collo-zygote";
pub const inherited_control_fd: std.posix.fd_t = 3;
pub const inherited_trace_fd: std.posix.fd_t = 4;
pub const zygote_env_vm_flags = "COLLO_INTERNAL_ZYGOTE_VM_FLAGS";
pub const zygote_env_postfork_exit_probe_path = "COLLO_INTERNAL_ZYGOTE_POSTFORK_EXIT_PROBE_PATH";
pub const zygote_env_warmup_corpus = "COLLO_INTERNAL_ZYGOTE_WARMUP_CORPUS";
pub const zygote_generated_env_count: usize = 3;
// Control sockets must preserve message boundaries and carry SCM_RIGHTS fds.
pub const ipc_socket_type: u32 = std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC;

// JSC helper threads must retire quickly before a fork so the zygote can prove
// it is single-threaded.
const PREFORK_HELPER_THREAD_IDLE_TIMEOUT_NS = 1 * std.time.ns_per_ms;
// Interval between probes for a single-threaded zygote after prepareForFork.
const PREFORK_DRAIN_CHECK_INTERVAL_NS = 1 * std.time.ns_per_ms;
// At one probe per check interval, 50 probes bound boot preparation's drain at
// about 50 ms.
const PREFORK_DRAIN_MAX_CHECKS: u32 = 50;

pub fn runFromInheritedFds() !void {
    var control_owned = true;
    defer if (control_owned)
        std.posix.close(inherited_control_fd);
    var trace_owned = true;
    errdefer if (trace_owned)
        std.posix.close(inherited_trace_fd);

    const options = try zygoteOptionsFromEnv();
    var zygote = try state.Zygote.init(inherited_trace_fd, options);
    trace_owned = false;
    defer zygote.deinit();

    try prepareZygoteAtBoot(&zygote);
    try installWorkerChildAutoReap();
    try ipc.sendZygoteReady(inherited_control_fd);
    try serveForkRequests(&zygote, inherited_control_fd);
    std.posix.close(inherited_control_fd);
    control_owned = false;
}

fn zygoteOptionsFromEnv() !state.ZygoteOptions {
    var options = state.ZygoteOptions{};
    if (std.posix.getenv(zygote_env_vm_flags)) |value| {
        options.vm_options.flags = try std.fmt.parseUnsigned(u32, value, 10);
    }
    if (std.posix.getenv(zygote_env_postfork_exit_probe_path)) |value| {
        const path = value;
        if (path.len != 0)
            options.postfork_exit_probe_path = path;
    }
    if (std.posix.getenv(zygote_env_warmup_corpus)) |value| {
        options.warmup_corpus = std.mem.eql(u8, value, "1");
    }
    return options;
}

fn prepareZygoteAtBoot(zygote: *state.Zygote) !void {
    if (zygote.prepared_for_fork)
        return;

    // A worker decodes encoded fetch bodies inside a chroot that holds no library files, so the
    // decoders' libraries load here, before the first fork, and every worker inherits them
    // loaded (`decompress.load`).
    _ = decompress.load();
    try bindings.setHelperThreadsTimeoutOverrideNs(PREFORK_HELPER_THREAD_IDLE_TIMEOUT_NS);
    traceEventFmt(zygote.trace_fd, "zygote.helper_timeout.override={d}", .{PREFORK_HELPER_THREAD_IDLE_TIMEOUT_NS});
    if (zygote.warmup_corpus) {
        // The corpus runs before prepareForFork so the helper threads it
        // starts retire within the short idle timeout. The full GC afterwards
        // drops its garbage, leaving only the engine state it warmed in the
        // pages workers inherit.
        traceEvent(zygote.trace_fd, "zygote.warmup_corpus.run");
        try warmup.runCorpus(&zygote.vm);
        try zygote.vm.collectFullGCAndTrim();
        traceEvent(zygote.trace_fd, "zygote.warmup_corpus.done");
    }
    traceEvent(zygote.trace_fd, "zygote.prepare_for_fork");
    try zygote.vm.prepareForFork();
    // One idle timeout lets the helper threads retire before the probes start.
    std.Thread.sleep(PREFORK_HELPER_THREAD_IDLE_TIMEOUT_NS);
    try process.waitForSingleThreadedSelf(PREFORK_DRAIN_MAX_CHECKS, PREFORK_DRAIN_CHECK_INTERVAL_NS);
    // The engine reserves its heaps with MADV_DONTFORK. Every mapping alive
    // now belongs in the pages workers inherit, so the whole address space is
    // made inheritable once, after the last reservation and before the first
    // fork.
    const inheritable_mappings = try process.makeAddressSpaceForkInheritable();
    traceEventFmt(zygote.trace_fd, "zygote.address_space.inheritable={d}", .{inheritable_mappings});
    zygote.prepared_for_fork = true;
    zygote.prepare_count += 1;
    traceEvent(zygote.trace_fd, "zygote.prepared");
}

fn serveForkRequests(zygote: *state.Zygote, control_fd: std.posix.fd_t) !void {
    while (true) {
        // A truncated control message, caused by fd pressure during the
        // receive, still ends the zygote: the datagram is consumed and its job
        // id lost, and serving on without a reply would silently wedge the
        // host's one-at-a-time fork queue.
        var request = recvForkRequestRetryingPressure(control_fd) catch |err| switch (err) {
            error.ShortRead, error.PeerClosed => return,
            else => return err,
        };
        // The cgroup directory fd is closed by the parent after the clone and
        // by the child right after birth; this covers failures before either.
        errdefer request.deinit();

        try assertPreparedForkBaseline(zygote);
        traceEvent(zygote.trace_fd, "zygote.fork_request");

        // A child is never born outside a validated, empty worker cgroup. The
        // check runs before the clone, with the VM untouched, so any failure
        // here, whether a bad fd from the host or fd pressure, fails only this
        // fork.
        if (request.cgroup_dir_fd) |dir_fd| {
            worker_cgroup.validateEmptyWorkerCgroupDirFd(dir_fd) catch |err| {
                std.log.err("fork request cgroup fd rejected job_id={d}: {s}", .{
                    request.message.fork_job_id,
                    @errorName(err),
                });
                try ipc.sendForkFailed(control_fd, request.message.fork_job_id);
                traceEvent(zygote.trace_fd, "zygote.fork_failed.cgroup");
                request.deinit();
                continue;
            };
        }

        // Transient fd pressure before the fork fails only this job, so the
        // host can retry; the VM is untouched and the zygote keeps serving.
        const init_pair = fd_mod.socketPairType(ipc_socket_type) catch |err| {
            if (!isTransientForkError(err))
                return err;
            try ipc.sendForkFailed(control_fd, request.message.fork_job_id);
            traceEvent(zygote.trace_fd, "zygote.fork_failed.transient");
            request.deinit();
            continue;
        };
        var parent_init_fd: ?std.posix.fd_t = init_pair[0];
        var child_init_fd: ?std.posix.fd_t = init_pair[1];
        errdefer {
            if (parent_init_fd) |fd|
                std.posix.close(fd);
            if (child_init_fd) |fd|
                std.posix.close(fd);
        }

        // A fork from a multi-threaded process can leave a lock held forever
        // by a thread the child does not have. clone3 also runs no
        // pthread_atfork handlers, which is safe only because this loop is
        // single-threaded. A second thread therefore ends the zygote, while a
        // failure to read /proc/self/task is fd pressure and fails only this
        // job. This loop stays VM-free and allocation-free so every worker
        // inherits the same pages.
        process.assertSingleThreadedSelf() catch |err| switch (err) {
            error.ProcessNotSingleThreaded => return err,
            else => {
                std.posix.close(parent_init_fd.?);
                parent_init_fd = null;
                std.posix.close(child_init_fd.?);
                child_init_fd = null;
                try ipc.sendForkFailed(control_fd, request.message.fork_job_id);
                traceEvent(zygote.trace_fd, "zygote.fork_failed.transient");
                request.deinit();
                continue;
            },
        };
        var worker_pidfd_raw: std.posix.fd_t = -1;
        const worker_pid = process.cloneForkWithPidFd(request.cgroup_dir_fd, &worker_pidfd_raw) catch |err| {
            // A failed clone created no child and left the VM intact, so a
            // transient failure ends only this job.
            if (!isTransientForkError(err))
                return err;
            std.posix.close(parent_init_fd.?);
            parent_init_fd = null;
            std.posix.close(child_init_fd.?);
            child_init_fd = null;
            try ipc.sendForkFailed(control_fd, request.message.fork_job_id);
            traceEvent(zygote.trace_fd, "zygote.fork_failed.transient");
            request.deinit();
            continue;
        };
        if (worker_pid == 0) {
            if (request.cgroup_dir_fd) |fd|
                std.posix.close(fd);
            std.posix.close(control_fd);
            std.posix.close(parent_init_fd.?);
            parent_init_fd = null;
            workerChildMain(zygote, child_init_fd.?);
        }

        if (request.cgroup_dir_fd) |fd| {
            std.posix.close(fd);
            request.cgroup_dir_fd = null;
            traceEvent(zygote.trace_fd, "zygote.fork_into_cgroup");
        }
        std.posix.close(child_init_fd.?);
        child_init_fd = null;
        var worker_pidfd = fd_mod.OwnedFd.fromRaw(worker_pidfd_raw);
        defer worker_pidfd.deinit();
        // Workers are the kernel's first OOM victims. The zygote raises the
        // child's score because the child's chroot has no /proc; the child
        // cannot be serving yet, since the host releases it only after this
        // reply. The worker cgroup's memory limit is the real bound, so a
        // failed write only warns.
        process.writeOomScoreAdj(@intCast(worker_pid), process_limits.OOM_SCORE_ADJ_WORKER) catch |err|
            std.log.warn("failed to set worker oom_score_adj pid={d}: {s}", .{ worker_pid, @errorName(err) });
        try ipc.sendForkReply(control_fd, request.message.fork_job_id, @intCast(worker_pid), parent_init_fd.?, worker_pidfd.fd());
        traceEventFmt(zygote.trace_fd, "zygote.fork_reply={d}", .{worker_pid});
        std.posix.close(parent_init_fd.?);
        parent_init_fd = null;
    }
}

fn assertPreparedForkBaseline(zygote: *const state.Zygote) !void {
    if (!zygote.prepared_for_fork)
        return error.ZygoteNotPreparedForFork;
    if (zygote.prepare_count != 1)
        return error.ZygotePrepareCountChanged;
}

/// Fork failures caused by one job's resources rather than the zygote's state.
/// The VM is intact when they happen, so the zygote fails that job and keeps
/// serving instead of exiting, which would take every running worker with it.
/// Descriptor and memory pressure can meet the init socket pair or clone3,
/// whose pidfd takes a descriptor slot (`cloneForkError` in `common/os.zig`).
/// The cgroup errors from clone3 (busy, at its descendant limit, threaded, or
/// a stale fd) concern the cgroup the host prepared for this fork.
///
/// clone3 reports EACCES and EPERM as one error, and under CLONE_INTO_CGROUP
/// both usually concern that cgroup. When they concern the zygote's own
/// privileges instead, failing every fork is still better than exiting: every
/// cold start reports the error while running workers keep serving.
fn isTransientForkError(err: anyerror) bool {
    return switch (err) {
        error.SystemFdQuotaExceeded,
        error.ProcessFdQuotaExceeded,
        error.SystemResources,
        error.CgroupBusy,
        error.CgroupLimitReached,
        error.CgroupThreaded,
        error.InvalidHandle,
        error.PermissionDenied,
        => true,
        else => false,
    };
}

const RECV_PRESSURE_MAX_ATTEMPTS: u32 = 100;
const RECV_PRESSURE_RETRY_INTERVAL_NS: u64 = 10 * std.time.ns_per_ms;

/// A receive fails with SystemResources under kernel memory pressure before
/// the datagram is dequeued (fd pressure shows up as a truncated control
/// message instead), so the request is still queued and a bounded,
/// allocation-free retry serves it without dropping a reply. Pressure that
/// outlasts the bound, about a second, ends the zygote rather than spinning.
fn recvForkRequestRetryingPressure(control_fd: std.posix.fd_t) !ipc.ForkRequestWithFd {
    var attempts: u32 = 0;
    while (true) {
        return ipc.recvForkRequestWithFd(control_fd) catch |err| switch (err) {
            error.SystemResources => {
                attempts += 1;
                if (attempts >= RECV_PRESSURE_MAX_ATTEMPTS)
                    return err;
                std.Thread.sleep(RECV_PRESSURE_RETRY_INTERVAL_NS);
                continue;
            },
            else => |other| return other,
        };
    }
}

pub fn installWorkerChildAutoReap() !void {
    const linux = std.os.linux;
    var action = linux.Sigaction{
        .handler = .{ .handler = sigchldNoop },
        .mask = std.mem.zeroes(linux.sigset_t),
        .flags = linux.SA.NOCLDWAIT,
    };
    const rc = linux.sigaction(linux.SIG.CHLD, &action, null);
    return switch (linux.E.init(rc)) {
        .SUCCESS => {},
        .INVAL => error.InvalidSignalAction,
        else => |err| std.posix.unexpectedErrno(err),
    };
}

fn sigchldNoop(_: i32) callconv(.c) void {}

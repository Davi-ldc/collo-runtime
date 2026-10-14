//! The zygote process: its entry from the launch the host set up
//! (`spawnZygote` in `host_client.zig`), its boot preparation, and the fork
//! loop that serves the host's fork requests. It runs on the zygote's main
//! thread. The launch contract is declared here: the zygote runs under
//! `process_name` with `environment` as its whole environment, its control
//! socket at `inherited_control_fd` and, only when the host asked for a
//! trace, the write end of the trace pipe at `inherited_trace_fd`; every
//! other descriptor from 3 up is closed.
//!
//! Invariants:
//! - The zygote is single-threaded at every fork. A fork from a
//!   multi-threaded process can leave a lock held forever by a thread the
//!   child does not have, and clone3 runs no pthread_atfork handlers. Boot
//!   preparation retires the engine's helper threads and proves the zygote
//!   single-threaded before it reports ready, and every fork checks again; a
//!   second thread ends the zygote.
//! - After `prepareZygoteAtBoot` the fork loop neither allocates nor touches
//!   the VM, so every worker inherits the same copy-on-write pages.
//!   `serveForkRequests` takes the `Prepared` value only the preparation
//!   returns, so no fork comes before it. The conventions gate `zygote fork
//!   loop stays VM-free and allocation-free after prepare` reads only the
//!   body of `serveForkRequests`; what it calls keeps the rule without a gate.
//! - Every child is born inside the cgroup leaf its request carries
//!   (`CLONE_INTO_CGROUP`), and only into an empty cgroup2 directory. A
//!   request without exactly one leaf ends the zygote at its receive, so no
//!   path forks a child into the zygote's own cgroup.
//! - Every child starts with its own thread id in glibc, as a child of
//!   glibc's fork does: the clone hands the kernel the zygote thread's
//!   thread-id word (`CloneForkOptions.thread_id_word` in `common/os.zig`),
//!   which the preparation reads with PR_GET_TID_ADDRESS and checks. A kernel
//!   without CONFIG_CHECKPOINT_RESTORE has no PR_GET_TID_ADDRESS, and the
//!   zygote refuses to prepare there.
//! - A failure caused by one fork's resources refuses that fork, and the
//!   zygote keeps serving (`isTransientForkError`); any other failure ends
//!   the zygote.
//! - The kernel reaps every child (`installWorkerChildAutoReap`), so the
//!   zygote never waits for one.
//! - The zygote ends by exiting at once (`runFromInheritedFds`): with status
//!   0 when the host hangs up, and with status 1 after one line naming the
//!   error for any failure. It tears nothing down on the way out, the VM
//!   included. Everything it holds is its own memory and descriptors, which
//!   the kernel releases at exit, and the host waits for that exit on the
//!   zygote's pidfd, so teardown would only delay it.

const std = @import("std");
const bindings = @import("collo_bindings");
const ipc = @import("collo_ipc");
const fd_mod = @import("collo_os").fd;
const linux_helpers = @import("collo_os").linux;
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
/// The zygote's whole environment, which every worker inherits as it is.
/// The values are fixed rather than the machine's because the JSC and ICU
/// timezone and locale caches the zygote fills before its first fork must
/// be the same in every worker, and nothing else of the host's reaches the
/// zygote.
pub const environment = [_:null]?[*:0]const u8{ "TZ=UTC", "LANG=C.UTF-8" };
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

/// What only `prepareZygoteAtBoot` returns, and what every fork needs.
pub const Prepared = struct {
    /// The zygote's main thread's thread-id word
    /// (`collo_os.process.callingThreadIdWord`), read and checked by the
    /// preparation. Every clone hands it to the kernel, so each child's glibc
    /// knows the child's own thread id.
    thread_id_word: *std.os.linux.pid_t,
};

/// Runs the zygote from the launch the host set up to its exit, as the
/// header's last invariant says. The exit is `_exit`, which runs no exit
/// handler, static destructor or error trace: a zygote can end with a second
/// thread alive (`assertSingleThreadedSelf`), beside which exit handlers can
/// hang or crash, and a Debug build's error trace parses the binary's whole
/// debug info, which takes seconds.
pub fn runFromInheritedFds() noreturn {
    serve() catch |err| {
        std.log.err("zygote failed: {s}", .{@errorName(err)});
        std.c._exit(1);
    };
    std.c._exit(0);
}

/// Boots and serves until the host hangs up; any error ends the zygote.
fn serve() !void {
    const trace_fd = try inheritedTraceFd();
    var zygote = try state.Zygote.init(trace_fd);
    const prepared = try prepareZygoteAtBoot(&zygote);
    try installWorkerChildAutoReap();
    try ipc.sendZygoteReady(inherited_control_fd);
    try serveForkRequests(&zygote, prepared, inherited_control_fd);
}

/// The write end of the trace pipe at `inherited_trace_fd`, or null when the
/// host asked for no trace and so left that descriptor closed. Any other file
/// there breaks the launch contract.
fn inheritedTraceFd() !?std.posix.fd_t {
    var stat: std.os.linux.Stat = undefined;
    switch (linux_helpers.syscallErrno(std.os.linux.fstat(inherited_trace_fd, &stat))) {
        .SUCCESS => {},
        .BADF => return null,
        else => |errno| return std.posix.unexpectedErrno(errno),
    }
    if ((stat.mode & std.os.linux.S.IFMT) != std.os.linux.S.IFIFO)
        return error.InheritedTraceFdNotPipe;
    return inherited_trace_fd;
}

/// Prepares the zygote's VM once, so every worker inherits the same warmed
/// pages, and returns what every fork needs. The caller calls it once, before
/// it reports ready.
fn prepareZygoteAtBoot(zygote: *state.Zygote) !Prepared {
    // Every clone hands the kernel this thread's thread-id word, which is how
    // a worker's glibc learns the worker's own thread id. A zygote that
    // cannot name the word would fork workers whose glibc names this thread,
    // so it ends here.
    const thread_id_word = process.callingThreadIdWord() catch |err| {
        switch (err) {
            error.CheckpointRestoreUnavailable => std.log.err(
                "the kernel lacks CONFIG_CHECKPOINT_RESTORE, which the zygote needs for PR_GET_TID_ADDRESS",
                .{},
            ),
            error.ThreadIdWordUnset,
            error.ThreadIdWordMismatch,
            error.Unexpected,
            => std.log.err("the zygote cannot find its thread's id in glibc: {s}", .{@errorName(err)}),
        }
        return err;
    };
    traceEvent(zygote.trace_fd, "zygote.thread_id_word.checked");

    try bindings.setHelperThreadsTimeoutOverrideNs(PREFORK_HELPER_THREAD_IDLE_TIMEOUT_NS);
    traceEventFmt(zygote.trace_fd, "zygote.helper_timeout.override={d}", .{PREFORK_HELPER_THREAD_IDLE_TIMEOUT_NS});
    // The corpus runs before prepareForFork so the helper threads it starts
    // retire within the short idle timeout. The full GC afterwards drops its
    // garbage, leaving only the engine state it warmed in the pages workers
    // inherit.
    traceEvent(zygote.trace_fd, "zygote.warmup_corpus.run");
    try warmup.runCorpus(&zygote.vm);
    try zygote.vm.collectFullGCAndTrim();
    traceEvent(zygote.trace_fd, "zygote.warmup_corpus.done");

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
    traceEvent(zygote.trace_fd, "zygote.prepared");
    return .{ .thread_id_word = thread_id_word };
}

fn serveForkRequests(zygote: *state.Zygote, prepared: Prepared, control_fd: std.posix.fd_t) !void {
    while (true) {
        // A truncated control message, caused by fd pressure during the
        // receive, still ends the zygote: the datagram is consumed and its job
        // id lost, and serving on without a reply would silently wedge the
        // host's one-at-a-time fork queue. So does a request without exactly
        // one leaf.
        var request = recvForkRequestRetryingPressure(control_fd) catch |err| switch (err) {
            error.ShortRead, error.PeerClosed => return,
            else => return err,
        };
        // Closes the leaf on every path of this process; the child closes its
        // own copy before it boots, since it never returns here.
        defer request.deinit();
        const fork_job_id = request.message.fork_job_id;
        traceEvent(zygote.trace_fd, "zygote.fork_request");

        // A child is never born outside a validated, empty worker cgroup. The
        // check runs before the clone, with the VM untouched, so any failure
        // here, whether a bad fd from the host or fd pressure, fails only this
        // fork.
        worker_cgroup.validateEmptyWorkerCgroupDirFd(request.cgroup_dir_fd) catch |err| {
            std.log.err("fork request cgroup fd rejected job_id={d}: {s}", .{ fork_job_id, @errorName(err) });
            try refuseFork(zygote.trace_fd, control_fd, fork_job_id, "zygote.fork_failed.cgroup");
            continue;
        };

        // Transient fd pressure before the fork fails only this job, so the
        // host can retry; the VM is untouched and the zygote keeps serving.
        const init_pair = fd_mod.socketPairType(ipc_socket_type) catch |err| {
            if (!isTransientForkError(err))
                return err;
            try refuseFork(zygote.trace_fd, control_fd, fork_job_id, "zygote.fork_failed.transient");
            continue;
        };
        var host_init = fd_mod.OwnedFd.fromRaw(init_pair[0]);
        defer host_init.deinit();
        var child_init = fd_mod.OwnedFd.fromRaw(init_pair[1]);
        defer child_init.deinit();

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
                try refuseFork(zygote.trace_fd, control_fd, fork_job_id, "zygote.fork_failed.transient");
                continue;
            },
        };
        var worker_pidfd_raw: std.posix.fd_t = -1;
        const clone_options: process.CloneForkOptions = .{
            .cgroup_dir_fd = request.cgroup_dir_fd,
            .thread_id_word = prepared.thread_id_word,
        };
        const worker_pid = process.cloneForkWithPidFd(clone_options, &worker_pidfd_raw) catch |err| {
            // A failed clone created no child and left the VM intact, so a
            // transient failure ends only this job.
            if (!isTransientForkError(err))
                return err;
            try refuseFork(zygote.trace_fd, control_fd, fork_job_id, "zygote.fork_failed.transient");
            continue;
        };
        if (worker_pid == 0) {
            // The child keeps only its end of the init socket. The defers of
            // this loop never run in it, since it never returns.
            std.posix.close(request.cgroup_dir_fd);
            std.posix.close(control_fd);
            std.posix.close(host_init.fd());
            workerChildMain(zygote, child_init.fd());
        }

        traceEvent(zygote.trace_fd, "zygote.fork_into_cgroup");
        // The host reads the child's exit as the end of its init socket, which
        // takes every copy of the child's end closed, this one first.
        child_init.deinit();
        var worker_pidfd = fd_mod.OwnedFd.fromRaw(worker_pidfd_raw);
        defer worker_pidfd.deinit();
        // Workers are the kernel's first OOM victims. The zygote raises the
        // child's score because the child's chroot has no /proc; the child
        // cannot be serving yet, since the host releases it only after this
        // reply. The worker cgroup's memory limit is the real bound, so a
        // failed write only warns.
        process.writeOomScoreAdj(@intCast(worker_pid), process_limits.OOM_SCORE_ADJ_WORKER) catch |err|
            std.log.warn("failed to set worker oom_score_adj pid={d}: {s}", .{ worker_pid, @errorName(err) });
        try ipc.sendForkReply(control_fd, fork_job_id, @intCast(worker_pid), host_init.fd(), worker_pidfd.fd());
        traceEventFmt(zygote.trace_fd, "zygote.fork_reply={d}", .{worker_pid});
    }
}

/// Answers the request of `fork_job_id` with a refusal, after which the host
/// may retry and the zygote serves the next request (`sendForkFailed` in
/// `common/ipc/zygote_worker.zig`).
fn refuseFork(
    trace_fd: ?std.posix.fd_t,
    control_fd: std.posix.fd_t,
    fork_job_id: u64,
    comptime event: []const u8,
) !void {
    try ipc.sendForkFailed(control_fd, fork_job_id);
    traceEvent(trace_fd, event);
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
        return ipc.recvForkRequest(control_fd) catch |err| switch (err) {
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

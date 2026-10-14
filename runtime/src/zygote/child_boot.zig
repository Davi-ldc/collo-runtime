//! A worker child, from the clone in the zygote's fork loop (`fork_loop.zig`)
//! until it exits: its boot up to its one outcome on its init socket,
//! `WorkerReady` or `WorkerInitFailed`, then the worker's event loop
//! (`collo_worker`). It runs in the worker process on the one thread the
//! clone gives it, which becomes the worker's VM thread, and it never returns
//! into the fork loop: `workerChildMain` ends in `_exit` on every path.
//!
//! The boot is one sequence of steps, each of which fails with an error that
//! ends the boot; `Boot.reportFailure` maps that error to the one
//! `WorkerInitFailedReason` the host reads (`failureReason`). The boot's own
//! failure path writes no lifecycle field, since the host learns the reason
//! from the message; the sentinel, which starts before the routes evaluate,
//! can still stamp `dead` with `memory` or `sentinel` while they do, which
//! `host/launch.zig:Machine.endedCause` reads.
//!
//! The boot crosses the sandbox in a fixed order, and each step sits where
//! the kernel or the engine forces it:
//! - The child first checks that glibc knows its thread's own id, which the
//!   clone set (`fork_loop.zig`), since a wrong one would name a thread of
//!   the zygote in every call that reads it.
//! - The namespaces come first among the sandbox steps, while the child is
//!   still provably single-threaded: unshare(CLONE_NEWUSER) fails in a
//!   multi-threaded process.
//! - The page is mapped and installed as the log sink as soon as `WorkerInit`
//!   brings it, before the child closes the descriptors it was not given and
//!   points its standard error at /dev/null, so no log line of the boot is
//!   lost: before the sink a line reaches the server's stderr, after it the
//!   page's console ring (`log_sink.zig`).
//! - The child stays single-threaded and leaves the VM untouched until
//!   `applyPreThread` (`worker_boot/sandbox.zig`) has set no-new-privileges
//!   and dropped capabilities, since both are per-thread and a thread started
//!   earlier would keep the user namespace's capabilities. It proves it is
//!   single-threaded just before, while /proc is still there to read.
//! - The child checks the cgroup leaf it was born in
//!   (`worker_boot/cgroup.zig`) before the VM resumes, so no engine or tenant
//!   code runs under limits nobody set, and opens the leaf files it reads for
//!   its life before the chroot hides them.
//! - Every thread the worker will ever have starts between the capability
//!   drop and the seccomp filter, which denies clone: a thread started on
//!   first use after the filter aborts the worker. So the helper threads are
//!   pinned against retiring as soon as the VM resumes, and the compiler
//!   threads start before the filter.
//! - The worker's end of the control socket stops blocking right before the
//!   filter, which lets fcntl read flags but not set them.
//! - The filter is the last sandbox step. Then the child closes its write end
//!   of the trace pipe, and only then runs the first tenant code, the
//!   evaluation of every route's entry, before `WorkerReady`, so a ready
//!   worker's first request needs no module work and no tenant code ever
//!   holds the pipe.

const std = @import("std");
const bindings = @import("collo_bindings");
const worker_shared_page = @import("collo_worker_state").page;
const ipc = @import("collo_ipc");
const fd_mod = @import("collo_os").fd;
const process = @import("collo_os").process;
const limits = @import("collo_limits");
const process_limits = limits.process;
const log_sink = @import("log_sink.zig");
const state = @import("state.zig");
const trace = @import("trace.zig");
const worker_runtime = @import("collo_worker");
const worker_cgroup = @import("worker_boot/cgroup.zig");
const worker_sandbox = @import("worker_boot/sandbox.zig");

const traceEvent = trace.traceEvent;
const traceEventFmt = trace.traceEventFmt;

// Once seccomp denies clone, a retired WTF AutomaticThread can never be
// recreated, and its lazy restart aborts the worker. Workers therefore keep
// every helper thread parked for good instead of letting it retire.
const WORKER_HELPER_THREAD_PIN_TIMEOUT_NS: u64 = std.math.maxInt(u64);
// The worker's root allocator: its boot cannot rely on request-scoped
// allocators.
const boot_allocator = std.heap.smp_allocator;

pub fn workerChildMain(zygote: *state.Zygote, child_init_fd: std.posix.fd_t) noreturn {
    var boot: Boot = .{ .init_fd = child_init_fd, .zygote = zygote };
    boot.run() catch |err| {
        // A no-op when the boot already reported, as it does once its page
        // is mapped.
        boot.reportFailure(err);
        childExit(1);
    };
    childExit(0);
}

/// What the boot keeps between its steps and its failure report.
const Boot = struct {
    /// The init socket, which becomes the worker's control socket once
    /// `WorkerReady` went out.
    init_fd: std.posix.fd_t,
    /// The child's copy of the zygote's state: the VM it boots, which
    /// becomes the worker's, and the trace pipe's write end until
    /// `closeTrace`. The boot keeps no copy of the descriptor's number, so
    /// once it is closed no trace call of the child can write into a file
    /// that a later open gave the same number.
    zygote: *state.Zygote,
    /// The outcome went out, or its send failed. The host reads one outcome,
    /// and from `WorkerReady` on the socket carries none, so the boot sends
    /// at most one and nothing after a send that failed: the host then reads
    /// the child's exit as the end of its init (`host/launch.zig`).
    outcome_attempted: bool = false,
    /// The event loop runs.
    serving: bool = false,
    /// The failure came from a step that checks the host's input: its
    /// `WorkerInit`, a descriptor it brought or the leaf it prepared
    /// (`refuse`).
    refused: bool = false,
    /// `reportFailure` ran.
    failure_reported: bool = false,

    fn run(self: *Boot) !void {
        const zygote = self.zygote;
        // The two phases stamped before the page is mapped wait here.
        var buffered_stamps = [_]u64{0} ** worker_shared_page.BOOT_PHASE_COUNT;

        // The clone wrote this thread's id into glibc's copy of it
        // (`fork_loop.zig`); a clone that did not would leave the zygote's
        // thread there, and glibc's thread clock, the owner of a recursive or
        // robust mutex, and affinity calls on `pthread_self()` would all name
        // the zygote's thread. glibc builds its clock id without a system
        // call, so the raw `gettid` is the check's only one.
        try validateOwnThreadIdentity();
        traceEvent(zygote.trace_fd, "child.thread_identity.checked");

        // Namespaces come before every other sandbox step, while the child is
        // provably single-threaded (the zygote checks before clone3):
        // unshare(CLONE_NEWUSER) fails with EINVAL in a multi-threaded
        // process, and postForkChild later restarts the libpas scavenger
        // thread. Until applyPreThread sets no-new-privileges and drops
        // capabilities, the child stays single-threaded, calls nothing on the
        // VM and does only fd and plain Zig work.
        try worker_sandbox.applyPostForkNamespaces();
        traceEvent(zygote.trace_fd, "child.namespaces.entered");
        stampBuffered(&buffered_stamps, .namespaces_entered);

        traceEvent(zygote.trace_fd, "child.wait_worker_init");
        var received = try self.receiveWorkerInit();
        defer received.deinit();
        stampBuffered(&buffered_stamps, .worker_init_received);

        var page = page: {
            const page_fd = received.takeMetricsFd();
            defer std.posix.close(page_fd);
            break :page worker_shared_page.mapWorkerWriter(page_fd) catch |err| return self.refuse(err);
        };
        defer page.deinit();
        page.storeBootPhaseStamps(&buffered_stamps);
        stamp(&page, .metrics_mapped);
        log_sink.install(&page);
        // Uninstalled before `page.deinit` unmaps the page, since this defer
        // runs first.
        defer log_sink.uninstall();
        // Reported while the sink still takes the failure's log line.
        errdefer |err| self.reportFailure(err);
        traceEvent(zygote.trace_fd, "child.log_sink.installed");

        try closeUnexpectedWorkerFds(self.init_fd, zygote.trace_fd, &received);
        stamp(&page, .unexpected_fds_closed);

        received.message.validate() catch |err| return self.refuse(err);
        traceEvent(zygote.trace_fd, "child.worker_init.validated");
        stamp(&page, .worker_init_validated);

        const pid: u32 = @intCast(std.c.getpid());
        const leaf = worker_cgroup.validateAndOpenWorkerLeafAt(received.cgroup_dir_fd, pid, .{
            .memory_limit_bytes = received.message.memory_limit_bytes,
        }) catch |err| return self.refuse(err);
        defer std.posix.close(leaf.memory_events_fd);
        defer std.posix.close(leaf.memory_current_fd);
        std.posix.close(received.takeCgroupDirFd());
        traceEvent(zygote.trace_fd, "child.cgroup.validated");
        stamp(&page, .cgroup_validated);

        // The worker's wake descriptors come exactly when WorkerInit sets
        // `flag_egress`, and the session's regions exactly when it carries a
        // boot token, which `ipc.recvWorkerInit` holds the table to, and
        // `WorkerInit.validate` refuses a token without `flag_egress`. With
        // the wake descriptors and no regions the child boots detached: the
        // runtime holds the wake descriptors and maps no endpoint. With
        // neither, the worker's definition has no network grant, and the set
        // the runtime gets is empty.
        var egress_shared_fds = received.takeEgressSharedFds();
        errdefer egress_shared_fds.close();

        // The privileges applyPreThread removes are per-thread, so the child
        // proves it is still single-threaded first. This must run before the
        // chroot, which removes /proc.
        try process.assertSingleThreadedSelf();
        traceEvent(zygote.trace_fd, "child.single_threaded.asserted");
        stamp(&page, .single_threaded_asserted);

        try worker_sandbox.applyPreThread(.{ .tmpfs_size_bytes = received.message.tmpfs_size_bytes });
        traceEvent(zygote.trace_fd, "child.sandbox.applied");
        stamp(&page, .sandbox_applied);

        // From here on threads may exist, and each one inherits
        // no-new-privileges and empty capability sets.
        try zygote.vm.postForkChild();
        traceEvent(zygote.trace_fd, "child.post_fork_child");

        // Every helper thread is pinned against retiring
        // (`WORKER_HELPER_THREAD_PIN_TIMEOUT_NS`), and an idle one releases
        // its allocator cache once after `thread_cache_idle_release_ns`,
        // which lets the libpas scavenger reach its deep sleep in an idle
        // worker. Both are set right after `postForkChild`, which reset the
        // registry of automatic threads and cleared the zygote's overrides: a
        // thread reads them each time it parks, and one that parked under the
        // pin is never woken by a later change, so any helper thread the boot
        // starts from here on, by a collection or by the prespawn below,
        // parks under both.
        try bindings.setHelperThreadsTimeoutOverrideNs(WORKER_HELPER_THREAD_PIN_TIMEOUT_NS);
        try bindings.setHelperThreadsCacheReleaseNs(limits.worker.thread_cache_idle_release_ns);
        traceEventFmt(zygote.trace_fd, "child.helper_threads.pinned=cache_release:{d}", .{
            limits.worker.thread_cache_idle_release_ns,
        });

        var seeds: bindings.RandomSeeds = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seeds));
        try zygote.vm.reseedAfterFork(seeds);
        traceEvent(zygote.trace_fd, "child.reseed");

        // `process.env` is always empty: the definition's artifact holds the
        // routes' bindings, each of which reaches only its route's `env`
        // argument.
        try zygote.vm.installProcess();
        traceEvent(zygote.trace_fd, "child.process_env.installed");

        const gc_max_heap_size_bytes = worker_cgroup.memory.gcHeapLimitBytes(received.message.memory_limit_bytes);
        try bindings.setGcMaxHeapSizeOverrideBytes(gc_max_heap_size_bytes);
        traceEventFmt(zygote.trace_fd, "child.gc_override={d}", .{gc_max_heap_size_bytes});

        // The engine measures its memory against the worker's limit, as its
        // leaf's `memory.current`, which is what `memory.high` bounds, tmpfs
        // and kernel memory included; its own figure, from the zygote's statm
        // and the machine's memory, says nothing about the worker. The engine
        // reads the descriptor with pread, which the filter keeps, and the
        // override is cleared before the descriptor closes.
        try bindings.setMemoryStatusOverride(received.message.memory_limit_bytes, leaf.memory_current_fd);
        defer bindings.clearMemoryStatusOverride();
        const memory_status = try bindings.memoryStatus();
        traceEventFmt(zygote.trace_fd, "child.memory_status={d},{d}", .{
            memory_status.footprint_bytes,
            received.message.memory_limit_bytes,
        });
        stamp(&page, .vm_resumed);

        // The runtime's capacities stay at their defaults, the constants
        // every worker gets (`worker/runtime/types.zig:RuntimeLimits`).
        var runtime = try worker_runtime.initRuntime(
            boot_allocator,
            &zygote.vm,
            self.init_fd,
            &page,
            received.takeCompletionEventfd(),
            .{
                .clock = worker_runtime.Clock.monotonic(),
                .memory_events_fd = leaf.memory_events_fd,
                .ingress_payload_fd = received.ingress_payload_fd,
                .ingress_payload_credit_eventfd = received.takeIngressPayloadCreditEventfd(),
                .egress_shared_fds = &egress_shared_fds,
                .isolate_realm = received.message.isolatesRealms(),
                // The evaluations the boot opens copy it, so top-level code
                // fetches under it (`worker/runtime/evaluations.zig`).
                .boot_egress_token = received.message.boot_egress_token,
                // The definition's limits on JavaScript, checked by
                // `WorkerInit.validate`: each request's CPU budget, and the
                // wall time JavaScript no request owns may run at a stretch.
                .request_cpu_budget_ns = received.message.request_cpu_budget_ns,
                .unowned_time_limit_ns = received.message.unowned_time_limit_ns,
                .bench_handler = received.message.recordsBenchHandler(),
            },
        );
        defer runtime.deinit();
        // Reported before the runtime's teardown, which can outlast the
        // cleanup reserve an evaluation the init deadline stopped has left.
        errdefer |err| self.reportFailure(err);
        std.posix.close(received.takeIngressPayloadFd());

        try runtime.attachHostRuntime();
        try runtime.startSentinel();
        traceEvent(zygote.trace_fd, "child.sentinel.started");
        stamp(&page, .runtime_initialized);

        // Every thread the worker will ever have must exist before seccomp
        // denies clone; after it, WTF's Thread::create aborts the process. So
        // every compiler thread is started now, under the pin set after
        // `postForkChild`: the JS worklist, which serves all JIT tiers, and
        // the wasm worklist, each of which would otherwise start lazily on
        // its first enqueue, and the collector thread. They start with empty
        // queues and park until work arrives. collo_vm_create sizes both
        // worklists so this set is complete.
        try zygote.vm.prespawnCompilerThreads();
        traceEvent(zygote.trace_fd, "child.compiler_threads.prespawned");
        stamp(&page, .helper_threads_pinned);

        // The filter denies F_SETFL, so the control socket's worker end stops
        // blocking here. A response send that finds the socket full then
        // parks in its request's outbox behind a writability poll
        // (`worker/serve/response.zig`) instead of holding the VM thread, and
        // every deadline with it, until the host reads. The boot's only
        // message to the host, `WorkerReady` or `WorkerInitFailed`, goes out
        // with nothing queued ahead of it, so it never finds the socket full.
        try fd_mod.setNonblocking(self.init_fd, true);
        traceEvent(zygote.trace_fd, "child.control.nonblocking");

        try worker_sandbox.applySeccomp();
        traceEvent(zygote.trace_fd, "child.seccomp.applied");
        stamp(&page, .seccomp_applied);

        try zygote.vm.enableNodeFsForWorker();
        traceEvent(zygote.trace_fd, "child.node_fs.enabled");

        self.closeTrace();

        // The definition's artifact is registered and every route's entry
        // evaluated before ready, so a ready worker's first request needs no
        // module work. Registration failures, the init deadline and memory
        // exhaustion fail the init, because a published worker must hold its
        // definition registered; how user-code failures are kept is
        // `bootEvaluateRoute` in `worker/modules/routes.zig`. The evaluation
        // deadline leaves the cleanup reserve before the host's init
        // deadline, so the child can stop the VM, report the failure and exit
        // before the host kills it. Only JavaScript can be interrupted, by
        // the sentinel, so the native steps above are bounded by the host's
        // deadline alone.
        const eval_deadline_mono_ns = received.message.init_deadline_mono_ns -|
            process_limits.WORKER_INIT_CLEANUP_RESERVE_NS;
        var eval_marks: worker_runtime.BootEvalMarks = .{};
        runtime.evaluateBootRoutes(received.module_pack_fd, eval_deadline_mono_ns, &eval_marks) catch |err| {
            return switch (@as(anyerror, err)) {
                // The artifact the host sent fails its seals, size or format.
                error.InvalidModulePack,
                error.ModulePackTooLarge,
                error.MissingFdSeals,
                error.FileTooLarge,
                => self.refuse(err),
                else => err,
            };
        };
        std.posix.close(received.takeModulePackFd());
        // The evaluation's inner marks are stamped before the closing phase
        // so the phases read in order. A zero mark means a step did not run.
        stampAt(&page, .module_pack_mapped, eval_marks.pack_mapped_ns);
        stampAt(&page, .module_pack_parsed, eval_marks.pack_parsed_ns);
        stampAt(&page, .module_pack_registered, eval_marks.pack_registered_ns);
        stamp(&page, .routes_evaluated);
        runtime.sealStartupEvaluations();

        page.setState(.ready, .none);
        // Before the send, as `BootPhase.ready` in
        // `common/worker_state/page/boot_stamps.zig` requires.
        stamp(&page, .ready);
        self.outcome_attempted = true;
        try ipc.sendWorkerReady(self.init_fd);

        // From here on the init socket is the worker's control channel, and
        // a failure ends the worker without a message on it.
        self.serving = true;
        try worker_runtime.run(&runtime);
        std.posix.close(self.init_fd);
    }

    /// Waits for `WorkerInit` up to `WORKER_INIT_TIMEOUT_MS`, a bound beside
    /// the host's window, and receives it with every descriptor it brought.
    fn receiveWorkerInit(self: *Boot) !ipc.WorkerInitWithFds {
        var pollfds = [1]std.posix.pollfd{.{
            .fd = self.init_fd,
            .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR,
            .revents = 0,
        }};
        if (try std.posix.poll(&pollfds, process_limits.WORKER_INIT_TIMEOUT_MS) == 0) {
            traceEvent(self.zygote.trace_fd, "child.worker_init.timeout");
            return error.WorkerInitTimeout;
        }
        return ipc.recvWorkerInit(self.init_fd) catch |err| {
            // Traced by name, since several errors share one reason.
            traceEventFmt(self.zygote.trace_fd, "child.worker_init.recv_failed={s}", .{@errorName(err)});
            return err;
        };
    }

    /// Marks the failure `err` as one of a step that checks the host's input,
    /// which `failureReason` reads, and hands it back to end the boot. It
    /// returns an error union, never a value, because a `return` under
    /// `run`'s `errdefer |err|` takes the error code of an error union, and
    /// the compiler refuses a bare error set there.
    fn refuse(self: *Boot, err: anyerror) anyerror!void {
        self.refused = true;
        return err;
    }

    /// Ends a boot that failed with `err`, once: the error goes to the trace
    /// and the log, and the host gets its one outcome, `WorkerInitFailed`
    /// with `failureReason`, unless an outcome went out already or no
    /// `WorkerInit` came. A watchdog stop reports `init_deadline_exceeded`,
    /// and the child exits on its own within the cleanup reserve
    /// (`WorkerInitFailedReason.init_deadline_exceeded` says what the host
    /// does).
    fn reportFailure(self: *Boot, err: anyerror) void {
        if (self.failure_reported)
            return;
        self.failure_reported = true;
        traceEventFmt(self.zygote.trace_fd, "child.boot_failed={s}", .{@errorName(err)});
        if (self.serving) {
            std.log.err("worker event loop failed: {s}", .{@errorName(err)});
            return;
        }
        if (self.outcome_attempted) {
            std.log.err("worker could not send WorkerReady: {s}", .{@errorName(err)});
            return;
        }
        const reason = failureReason(err, self.refused) orelse return;
        std.log.err("worker boot failed: {s}", .{@errorName(err)});
        self.outcome_attempted = true;
        ipc.sendWorkerInitFailed(self.init_fd, reason) catch |send_err| switch (send_err) {
            error.PeerClosed => {},
            else => traceEventFmt(self.zygote.trace_fd, "child.init_failed.notification_dropped={s}", .{@errorName(send_err)}),
        };
    }

    /// Closes the child's write end of the trace pipe before its first
    /// tenant code, so code that escapes the engine can neither write lines
    /// into the operator's log nor fill the pipe the zygote and the host
    /// trace into. The page's boot stamps record the phases after it.
    fn closeTrace(self: *Boot) void {
        traceEvent(self.zygote.trace_fd, "child.trace.closed");
        self.zygote.closeTrace();
    }
};

/// The reason `WorkerInitFailed` carries for a boot that failed with `err`;
/// null for a `WorkerInit` that never came, which owes no outcome.
/// `refused` says the failure came from a step that checks the host's input
/// (`Boot.refuse`). Such a failure is the host's, `invalid_worker_init`,
/// unless the step's system calls failed for the child's own reasons
/// (`isResourceFailure`), which read as `internal_error` like every other
/// failure of the child's.
pub fn failureReason(err: anyerror, refused: bool) ?ipc.WorkerInitFailedReason {
    if (refused and !isResourceFailure(err))
        return .invalid_worker_init;
    return switch (err) {
        error.WorkerInitTimeout => null,
        error.MissingMetricsFd => .missing_metrics_fd,
        error.MissingIngressPayloadFd => .missing_ingress_payload_fd,
        error.MissingIngressPayloadCreditFd => .missing_ingress_payload_credit_fd,
        error.MissingEgressSharedFd => .missing_egress_shared_fd,
        error.MissingCompletionEventFd,
        error.MissingCgroupDirFd,
        error.MissingModulePackFd,
        error.InvalidFdCount,
        => .invalid_worker_init,
        error.WorkerInitDeadlineExceeded => .init_deadline_exceeded,
        else => .internal_error,
    };
}

/// Whether `err` says a system call failed for want of the child's own
/// memory or descriptors, or with an errno nothing expects, rather than
/// because what the host handed it failed a check: a check of the host's
/// input fails with an error of its own name.
fn isResourceFailure(err: anyerror) bool {
    return switch (err) {
        error.OutOfMemory,
        error.SystemResources,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        error.Unexpected,
        => true,
        else => false,
    };
}

/// Closes every descriptor WorkerInit did not bring, except the init socket
/// and the trace pipe, and points the standard descriptors at /dev/null. The
/// page's descriptor closed once mapped, and the leaf files the child keeps
/// (`worker_boot/cgroup.zig:OpenedWorkerLeaf`) are opened after this, so
/// neither needs a place in the allowlist.
fn closeUnexpectedWorkerFds(
    child_init_fd: std.posix.fd_t,
    trace_fd: ?std.posix.fd_t,
    received: *const ipc.WorkerInitWithFds,
) !void {
    const brought = [_]std.posix.fd_t{
        received.completion_eventfd,
        received.ingress_payload_fd,
        received.ingress_payload_credit_eventfd,
        received.cgroup_dir_fd,
        received.module_pack_fd,
    };
    var allow: [2 + brought.len + ipc.egress_shared.shared_fd_count]std.posix.fd_t = undefined;
    var len: usize = 0;

    allow[len] = child_init_fd;
    len += 1;
    if (trace_fd) |fd| {
        allow[len] = fd;
        len += 1;
    }
    for (brought) |fd| {
        allow[len] = fd;
        len += 1;
    }
    // The receiver took the regions whole or not at all, and the wake
    // descriptors likewise, so a set that is not whole has its wake
    // descriptors or nothing.
    const egress = received.egress_shared_fds;
    if (egress.isValid()) {
        for (egress.asArray()) |fd| {
            allow[len] = fd;
            len += 1;
        }
    } else {
        const wake = egress.wakeFds();
        if (wake.isValid()) {
            for (wake.asArray()) |fd| {
                allow[len] = fd;
                len += 1;
            }
        }
    }

    try fd_mod.closeAllExceptFrom(0, allow[0..len]);
    try fd_mod.redirectUnallowedStandardFdsToDevNull(allow[0..len]);
}

/// Fails unless glibc's CPU clock id for the calling thread is the one the
/// kernel builds from the thread's own id, which holds only when glibc's
/// cached thread id is the thread's own.
fn validateOwnThreadIdentity() !void {
    const libc_clock = try process.libcThreadCpuClockId();
    if (libc_clock != process.threadCpuClockId(std.os.linux.gettid()))
        return error.ThreadIdentityMismatch;
}

/// Records one CLOCK_MONOTONIC reading for a phase before the page is mapped.
fn stampBuffered(stamps: *[worker_shared_page.BOOT_PHASE_COUNT]u64, phase: worker_shared_page.BootPhase) void {
    stamps[@intFromEnum(phase)] = process.monotonicNowNsOrZero();
}

/// Records one CLOCK_MONOTONIC reading for a phase on the page, so a child
/// stuck mid-boot leaves its progress readable.
fn stamp(page: *worker_shared_page.WorkerWriterView, phase: worker_shared_page.BootPhase) void {
    page.storeBootPhaseStampNs(phase, process.monotonicNowNsOrZero());
}

/// Stamps a phase with a monotonic mark taken earlier, inside the evaluation;
/// reading the clock here would misattribute the time. A zero mark means the
/// step did not run and is left unstamped.
fn stampAt(page: *worker_shared_page.WorkerWriterView, phase: worker_shared_page.BootPhase, mark_ns: u64) void {
    if (mark_ns == 0)
        return;
    page.storeBootPhaseStampNs(phase, mark_ns);
}

fn childExit(status: u8) noreturn {
    std.c._exit(@intCast(status));
}

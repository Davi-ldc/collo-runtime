//! A worker child, from the clone in the zygote's fork loop (`fork_loop.zig`)
//! until it exits: its boot up to its one outcome on its init socket,
//! `WorkerReady` or `WorkerInitFailed` (`InitReport`), then the worker's event
//! loop (`collo_worker`). It runs in the worker process on the one thread the
//! clone gives it, which becomes the worker's VM thread, and it never returns
//! into the fork loop: `workerChildMain` ends in `_exit` on every path.
//!
//! The boot crosses the sandbox in a fixed order, and each step sits where
//! the kernel or the engine forces it:
//! - The child first checks that glibc knows its thread's own id, which the
//!   clone set (`fork_loop.zig`), since a wrong one would name a thread of
//!   the zygote in every call that reads it.
//! - The namespaces come first among the sandbox steps, while the child is
//!   still provably single-threaded: unshare(CLONE_NEWUSER) fails in a
//!   multi-threaded process.
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
//! - The filter is the last sandbox step. The first tenant code, the
//!   evaluation of every route's entry, runs after it and before
//!   `WorkerReady`, so a ready worker's first request needs no module work.
//!
//! From the mapping of the state page on, every `std.log` line of the child
//! goes into the page's console ring (`log_sink.zig`), since the child's
//! standard error points at /dev/null by then.

const std = @import("std");
const bindings = @import("collo_bindings");
const worker_shared_page = @import("collo_worker_state").page;
const ipc = @import("collo_ipc");
const fd_mod = @import("collo_os").fd;
const process = @import("collo_os").process;
const socket = @import("collo_os").socket;
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
pub const worker_environment_retained_names = [_][:0]const u8{ "TZ", "LANG" };
// The zygote starts with these fixed values, not the machine's, because the
// JSC and ICU timezone and locale caches it fills before forking must match
// what every worker sets after clearenv. Otherwise `Date` in a worker would use
// the machine's zone even though the worker sets UTC.
pub const worker_environment_canonical_values = [worker_environment_retained_names.len][:0]const u8{ "UTC", "C.UTF-8" };

extern fn clearenv() c_int;
extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

pub fn workerChildMain(zygote: *state.Zygote, child_init_fd: std.posix.fd_t) noreturn {
    var report: InitReport = .{ .fd = child_init_fd, .trace_fd = zygote.trace_fd };
    workerChildMainImpl(zygote, child_init_fd, &report) catch |err| {
        // An error the boot did not classify ends it before any outcome went
        // out, and is reported as `internal_error`. A child whose WorkerInit
        // never came owes no outcome.
        if (!report.attempted and err != error.WorkerInitTimeout)
            report.sendFailure(.internal_error);
        childExit(1);
    };
    childExit(0);
}

/// The boot's outcome on the init socket: `WorkerReady`, or
/// `WorkerInitFailed` with its reason. The host reads one outcome, and from
/// `WorkerReady` on the socket is the worker's control channel, which carries
/// none, so the boot sends at most one and sends nothing after a send that
/// failed: the host then reads the child's exit as the end of its init
/// (`Machine.finishInitOutcome` in `host/launch.zig`).
const InitReport = struct {
    fd: std.posix.fd_t,
    trace_fd: ?std.posix.fd_t,
    /// The outcome went out, or its send failed.
    attempted: bool = false,

    /// Sends `WorkerInitFailed` with `reason`, and traces a send that fails.
    fn sendFailure(self: *InitReport, reason: ipc.WorkerInitFailedReason) void {
        std.debug.assert(!self.attempted);
        self.attempted = true;
        ipc.sendWorkerInitFailed(self.fd, reason) catch |err| switch (err) {
            error.PeerClosed => {},
            else => traceEventFmt(self.trace_fd, "child.init_failed.notification_dropped={s}", .{@errorName(err)}),
        };
    }

    /// `sendFailure`, then the error that ends the boot.
    fn fail(self: *InitReport, reason: ipc.WorkerInitFailedReason) error{InitFailureReported} {
        self.sendFailure(reason);
        return error.InitFailureReported;
    }

    /// Sends `WorkerReady`. A send that fails ends the boot with no other
    /// outcome.
    fn ready(self: *InitReport) !void {
        std.debug.assert(!self.attempted);
        self.attempted = true;
        try ipc.sendWorkerReady(self.fd);
    }
};

fn workerChildMainImpl(zygote: *state.Zygote, child_init_fd: std.posix.fd_t, report: *InitReport) !void {
    const trace_fd = zygote.trace_fd;
    // Boot phases stamped before the metrics page is mapped are buffered here
    // and copied when it maps; later phases are also written straight to the
    // page, so a child stuck mid-boot leaves its progress readable.
    var boot_stamps = [_]u64{0} ** worker_shared_page.BOOT_PHASE_COUNT;

    // The clone wrote this thread's id into glibc's copy of it
    // (`fork_loop.zig`); a clone that did not would leave the zygote's
    // thread there, and glibc's thread clock, the owner of a recursive or
    // robust mutex, and affinity calls on `pthread_self()` would all name
    // the zygote's thread. glibc builds its clock id without a system call,
    // so the raw `gettid` is the check's only one.
    validateOwnThreadIdentity() catch |err| {
        traceEventFmt(trace_fd, "child.thread_identity.invalid={s}", .{@errorName(err)});
        return report.fail(.internal_error);
    };
    traceEvent(trace_fd, "child.thread_identity.checked");

    // Namespaces come before every other sandbox step, while the child is
    // provably single-threaded (the zygote checks before clone3):
    // unshare(CLONE_NEWUSER) fails with EINVAL in a multi-threaded process,
    // and postForkChild later restarts the libpas scavenger thread.
    worker_sandbox.applyPostForkNamespaces() catch |err| {
        std.log.err("worker namespace setup failed: {s}", .{@errorName(err)});
        return report.fail(.internal_error);
    };
    traceEvent(trace_fd, "child.namespaces.entered");
    stampBootPhase(&boot_stamps, null, .namespaces_entered);

    // Until applyPreThread sets no-new-privileges and drops capabilities, the
    // child stays single-threaded and calls nothing on zygote.vm. Both are
    // per-thread properties, and postForkChild restarts engine activity that
    // can create threads; a thread started earlier would keep the user
    // namespace's capabilities. Until then the child does only fd and plain
    // Zig work. The exit probe is written before the sandbox because its path
    // disappears at the chroot.
    installExitProbe(zygote.postfork_exit_probe_path);

    traceEvent(trace_fd, "child.wait_worker_init");

    var received = recvWorkerInitBeforeTimeout(child_init_fd, trace_fd) catch |err| {
        // Traced by name because several errors share one wire reason, and
        // the reason alone cannot tell them apart.
        traceEventFmt(trace_fd, "child.worker_init.recv_failed={s}", .{@errorName(err)});
        if (err == error.WorkerInitTimeout)
            return err;
        return report.fail(switch (err) {
            error.MissingMetricsFd => .missing_metrics_fd,
            error.MissingIngressPayloadFd => .missing_ingress_payload_fd,
            error.MissingIngressPayloadCreditFd => .missing_ingress_payload_credit_fd,
            error.MissingTmpRootFd,
            error.MissingCgroupDirFd,
            error.MissingCompletionEventFd,
            error.MissingRouteTableFd,
            error.MissingFsIndexFd,
            error.MissingFsFaultFd,
            error.MissingModulePackFd,
            error.InvalidFdCount,
            => .invalid_worker_init,
            error.MissingEgressSharedFd => .missing_egress_shared_fd,
            else => .internal_error,
        });
    };
    defer received.deinit();
    stampBootPhase(&boot_stamps, null, .worker_init_received);
    closeUnexpectedWorkerFds(child_init_fd, trace_fd, &received) catch
        return report.fail(.internal_error);
    stampBootPhase(&boot_stamps, null, .unexpected_fds_closed);

    const pid: u32 = @intCast(std.c.getpid());

    validateWorkerInit(&received.message) catch {
        markInitFailedIfPossible(received.metrics_fd);
        traceEvent(trace_fd, "child.worker_init.invalid");
        return report.fail(.invalid_worker_init);
    };
    traceEvent(trace_fd, "child.worker_init.validated");
    validateWorkerInitFds(&received) catch {
        markInitFailedIfPossible(received.metrics_fd);
        traceEvent(trace_fd, "child.worker_init.invalid_fds");
        return report.fail(.invalid_worker_init);
    };
    traceEvent(trace_fd, "child.worker_init.fds_validated");
    stampBootPhase(&boot_stamps, null, .worker_init_validated);

    // The definition's route table: each route's entry and the bindings that
    // only that route's `env` receives. The runtime checks the bytes when it
    // starts (`Modules.init` in `worker/runtime/modules.zig`).
    const mapped_route_table = mapRouteTableReadOnly(
        received.route_table_fd,
        received.message.route_table_len,
    ) catch {
        markInitFailedIfPossible(received.metrics_fd);
        return report.fail(.invalid_worker_init);
    };
    std.posix.close(received.takeRouteTableFd());
    defer std.posix.munmap(mapped_route_table);
    traceEventFmt(trace_fd, "child.route_table.mapped={d}", .{mapped_route_table.len});

    applyWorkerEnvironmentPolicy() catch {
        markInitFailedIfPossible(received.metrics_fd);
        return report.fail(.internal_error);
    };
    traceEvent(trace_fd, "child.env.cleared");
    stampBootPhase(&boot_stamps, null, .environment_cleared);

    const mapped_metrics = try worker_shared_page.mapReadWrite(received.metrics_fd);
    std.posix.close(received.takeMetricsFd());
    var maybe_metrics = mapped_metrics;
    var metrics_owned_by_state = false;
    defer if (!metrics_owned_by_state) maybe_metrics.deinit();
    traceEvent(trace_fd, "child.metrics.mapped");
    stampBootPhase(&boot_stamps, null, .metrics_mapped);
    maybe_metrics.storeBootPhaseStamps(&boot_stamps);

    var worker_state = state.WorkerState.init(
        boot_allocator,
        pid,
        received.message.memory_limit_bytes,
    ) catch {
        maybe_metrics.setState(.dead, .init_failed);
        return report.fail(.internal_error);
    };
    defer worker_state.deinit();

    worker_state.metrics = maybe_metrics;
    metrics_owned_by_state = true;
    // Uninstalled before `worker_state.deinit` unmaps the page, since this
    // defer runs first.
    log_sink.install(&(worker_state.metrics.?));
    defer log_sink.uninstall();
    traceEvent(trace_fd, "child.log_sink.installed");

    const leaf = worker_cgroup.validateAndOpenWorkerLeafAt(received.cgroup_dir_fd, pid, .{
        .memory_limit_bytes = received.message.memory_limit_bytes,
        .cpu_max_cores = received.message.cpu_max_cores,
    }) catch |err| {
        maybe_metrics.setState(.dead, .init_failed);
        traceEventFmt(trace_fd, "child.cgroup.invalid={s}", .{@errorName(err)});
        return report.fail(.invalid_worker_init);
    };
    worker_state.memory_events_fd = leaf.memory_events_fd;
    worker_state.memory_current_fd = leaf.memory_current_fd;
    std.posix.close(received.takeCgroupDirFd());
    traceEvent(trace_fd, "child.cgroup.validated");
    traceEvent(trace_fd, "child.memory_events.opened");
    traceEvent(trace_fd, "child.memory_current.opened");
    stampBootPhase(&boot_stamps, &maybe_metrics, .cgroup_validated);

    // The worker's wake descriptors come exactly when WorkerInit sets
    // `flag_egress`, and the session's regions exactly when it carries a
    // boot token (`ipc.recvWorkerInit`), and `validateWorkerInitFds` holds
    // the child to that. With the wake descriptors and no regions the child
    // boots detached: the runtime holds the wake descriptors for its ring and
    // maps no endpoint. With neither, the worker's definition has no network
    // grant, and the set the runtime gets is empty (`RawFds.isEmpty`).
    var egress_shared_fds = received.takeEgressSharedFds();
    errdefer egress_shared_fds.close();

    // The privileges applyPreThread removes are per-thread, so the child
    // proves it is still single-threaded first. This must run before the
    // chroot, which removes /proc; any read failure or a second thread fails
    // the init.
    process.assertSingleThreadedSelf() catch |err| {
        worker_state.metrics.?.setState(.dead, .init_failed);
        std.log.err("worker single-thread check failed pre-sandbox: {s}", .{@errorName(err)});
        return report.fail(.internal_error);
    };
    traceEvent(trace_fd, "child.single_threaded.asserted");
    stampBootPhase(&boot_stamps, &maybe_metrics, .single_threaded_asserted);

    worker_sandbox.applyPreThread(.{
        .tmp_root_fd = received.tmp_root_fd,
        .tmpfs_size_bytes = received.message.tmpfs_size_bytes,
    }) catch |err| {
        worker_state.metrics.?.setState(.dead, .init_failed);
        std.log.err("worker sandbox setup failed: {s}", .{@errorName(err)});
        return report.fail(switch (err) {
            error.InvalidWorkerTmpRoot,
            error.PermissionDenied,
            => .invalid_worker_init,
            else => .internal_error,
        });
    };
    std.posix.close(received.takeTmpRootFd());
    traceEvent(trace_fd, "child.sandbox.applied");
    stampBootPhase(&boot_stamps, &maybe_metrics, .sandbox_applied);

    // From here on threads may exist, and each one inherits no-new-privileges
    // and empty capability sets.
    zygote.vm.postForkChild() catch {
        worker_state.metrics.?.setState(.dead, .init_failed);
        return report.fail(.internal_error);
    };
    traceEvent(trace_fd, "child.post_fork_child");

    // Every helper thread is pinned against retiring
    // (`WORKER_HELPER_THREAD_PIN_TIMEOUT_NS`), and an idle one releases its
    // allocator cache once after `thread_cache_idle_release_ns`, which lets
    // the libpas scavenger reach its deep sleep in an idle worker. Both are
    // set right after `postForkChild`, which reset the registry of automatic
    // threads and cleared the zygote's overrides: a thread reads them each
    // time it parks, and one that parked under the pin is never woken by a
    // later change, so any helper thread the boot starts from here on, by a
    // collection or by the prespawn below, parks under both.
    bindings.setHelperThreadsTimeoutOverrideNs(WORKER_HELPER_THREAD_PIN_TIMEOUT_NS) catch {
        worker_state.metrics.?.setState(.dead, .init_failed);
        return report.fail(.internal_error);
    };
    bindings.setHelperThreadsCacheReleaseNs(limits.worker.thread_cache_idle_release_ns) catch {
        worker_state.metrics.?.setState(.dead, .init_failed);
        return report.fail(.internal_error);
    };
    traceEventFmt(trace_fd, "child.helper_threads.pinned=cache_release:{d}", .{
        limits.worker.thread_cache_idle_release_ns,
    });

    var seeds: bindings.RandomSeeds = undefined;
    std.posix.getrandom(std.mem.asBytes(&seeds)) catch {
        worker_state.metrics.?.setState(.dead, .init_failed);
        return report.fail(.internal_error);
    };
    zygote.vm.reseedAfterFork(seeds) catch {
        worker_state.metrics.?.setState(.dead, .init_failed);
        return report.fail(.internal_error);
    };
    traceEvent(trace_fd, "child.reseed");

    // `process.env` is always empty: the mapped table holds the routes'
    // bindings, each of which reaches only its route's `env` argument.
    zygote.vm.installProcess() catch {
        worker_state.metrics.?.setState(.dead, .init_failed);
        return report.fail(.internal_error);
    };
    traceEvent(trace_fd, "child.process_env.installed");

    const gc_max_heap_size_bytes = worker_cgroup.memory.gcHeapLimitBytes(received.message.memory_limit_bytes);
    bindings.setGcMaxHeapSizeOverrideBytes(gc_max_heap_size_bytes) catch {
        worker_state.metrics.?.setState(.dead, .init_failed);
        return report.fail(.internal_error);
    };
    traceEventFmt(trace_fd, "child.gc_override={d}", .{gc_max_heap_size_bytes});

    // The engine measures its memory against the worker's limit, as its
    // leaf's `memory.current`, which is what `memory.high` bounds, tmpfs and
    // kernel memory included; its own figure, from the zygote's statm and
    // the machine's memory, says nothing about the worker. The engine reads
    // the descriptor with pread, which the filter keeps.
    bindings.setMemoryStatusOverride(received.message.memory_limit_bytes, leaf.memory_current_fd) catch {
        worker_state.metrics.?.setState(.dead, .init_failed);
        return report.fail(.internal_error);
    };
    const memory_status = bindings.memoryStatus() catch {
        worker_state.metrics.?.setState(.dead, .init_failed);
        return report.fail(.internal_error);
    };
    traceEventFmt(trace_fd, "child.memory_status={d},{d}", .{
        memory_status.footprint_bytes,
        received.message.memory_limit_bytes,
    });
    stampBootPhase(&boot_stamps, &maybe_metrics, .vm_resumed);

    // The fs index is mapped after the chroot, so the working directory and
    // /tmp are the sandbox's, and before seccomp, which forbids the syscalls
    // it needs. An invalid index fails the init. initWorker owns both fds on
    // every path.
    worker_runtime.fs.initWorker(
        received.takeFsIndexFd(),
        received.takeFsFaultFd(),
    ) catch |err| {
        worker_state.metrics.?.setState(.dead, .init_failed);
        std.log.err("worker fs index setup failed: {s}", .{@errorName(err)});
        traceEvent(trace_fd, "child.fs_index.invalid");
        return report.fail(.invalid_fs_index);
    };
    defer worker_runtime.fs.deinitWorker();
    traceEvent(trace_fd, "child.fs_index.mapped");
    stampBootPhase(&boot_stamps, &maybe_metrics, .fs_index_mapped);

    const runtime_options = runtimeOptionsFromWorkerInit(&received.message, .{
        .clock = worker_runtime.Clock.monotonic(),
        .memory_events_fd = leaf.memory_events_fd,
        .trace_fd = trace_fd,
        .ingress_payload_fd = received.ingress_payload_fd,
        .ingress_payload_credit_eventfd = received.takeIngressPayloadCreditEventfd(),
        .egress_shared_fds = &egress_shared_fds,
        // Stays mapped until after `runtime.deinit`: the deferred munmap
        // above runs after the runtime's deferred teardown below.
        .route_table = mapped_route_table,
        .isolate_realm = received.message.isolatesRealms(),
        // Every evaluation of a route module copies it, so top-level code
        // fetches under it (`worker/runtime/evaluations.zig`).
        .boot_egress_token = received.message.boot_egress_token,
    });
    traceEvent(trace_fd, "child.runtime_options.resolved");

    var runtime = worker_runtime.initRuntime(
        boot_allocator,
        &zygote.vm,
        child_init_fd,
        &(worker_state.metrics.?),
        received.takeCompletionEventfd(),
        runtime_options,
    ) catch {
        worker_state.metrics.?.setState(.dead, .init_failed);
        return report.fail(.internal_error);
    };
    std.posix.close(received.takeIngressPayloadFd());
    defer runtime.deinit();
    traceWorkerEgressEndpoint(trace_fd, &runtime);

    runtime.initRestrictedWorkerRing() catch |err| {
        worker_state.metrics.?.setState(.dead, .init_failed);
        std.log.err("worker restricted io_uring setup failed: {s}", .{@errorName(err)});
        return report.fail(.internal_error);
    };
    const worker_ring_fd = runtime.workerRingFd() orelse {
        worker_state.metrics.?.setState(.dead, .init_failed);
        std.log.err("worker restricted io_uring setup completed without a ring fd", .{});
        return report.fail(.internal_error);
    };
    const worker_timer_fd = runtime.workerTimerFd() orelse {
        worker_state.metrics.?.setState(.dead, .init_failed);
        std.log.err("worker restricted io_uring setup completed without a timer fd", .{});
        return report.fail(.internal_error);
    };
    traceEvent(trace_fd, "child.worker_ring.ready");
    if (runtime.workerRingFixedFiles()) |files| {
        traceEventFmt(
            trace_fd,
            "child.worker_ring.fixed_files=control:{d},wakeup:{d},egress_completion:{d},egress_liveness:{d},timer:{d},ingress_payload_credit:{d}",
            .{ files[0], files[1], files[2], files[3], files[4], files[5] },
        );
    }

    runtime.attachHostRuntime() catch {
        worker_state.metrics.?.setState(.dead, .init_failed);
        return report.fail(.internal_error);
    };

    runtime.startSentinel() catch {
        worker_state.metrics.?.setState(.dead, .init_failed);
        return report.fail(.internal_error);
    };
    stampBootPhase(&boot_stamps, &maybe_metrics, .runtime_initialized);

    // Every thread the worker will ever have must exist before seccomp denies
    // clone; after it, WTF's Thread::create aborts the process. So every
    // compiler thread is started now, under the pin set after
    // `postForkChild`: the JS worklist, which serves all JIT tiers, and the
    // wasm worklist, each of which would otherwise start lazily on its first
    // enqueue, and the collector thread. They start with empty queues and
    // park until work arrives. collo_vm_create sizes both worklists so this
    // set is complete.
    zygote.vm.prespawnCompilerThreads() catch |err| {
        worker_state.metrics.?.setState(.dead, .init_failed);
        std.log.err("worker compiler thread pre-spawn failed: {s}", .{@errorName(err)});
        return report.fail(.internal_error);
    };
    traceEvent(trace_fd, "child.compiler_threads.prespawned");
    stampBootPhase(&boot_stamps, &maybe_metrics, .helper_threads_pinned);

    // The filter denies F_SETFL, so the control socket's worker end stops
    // blocking here. A response send that finds the socket full then parks
    // in its request's outbox behind a writability poll
    // (`worker/serve/response.zig`) instead of holding the VM thread, and
    // every deadline with it, until the host reads. The boot's only message
    // to the host, `WorkerReady` or `WorkerInitFailed`, goes out with
    // nothing queued ahead of it, so it never finds the socket full.
    fd_mod.setNonblocking(child_init_fd, true) catch |err| {
        worker_state.metrics.?.setState(.dead, .init_failed);
        std.log.err("worker control socket could not stop blocking: {s}", .{@errorName(err)});
        return report.fail(.internal_error);
    };
    traceEvent(trace_fd, "child.control.nonblocking");

    worker_sandbox.applySeccomp(.{
        .mode = .deny_direct_egress,
        .allowed_io_uring_enter_fd = worker_ring_fd,
        .allowed_timer_fd = worker_timer_fd,
    }) catch |err| {
        worker_state.metrics.?.setState(.dead, .init_failed);
        std.log.err("worker seccomp setup failed: {s}", .{@errorName(err)});
        return report.fail(.internal_error);
    };
    traceEvent(trace_fd, "child.seccomp.applied");
    stampBootPhase(&boot_stamps, &maybe_metrics, .seccomp_applied);

    zygote.vm.enableNodeFsForWorker() catch {
        worker_state.metrics.?.setState(.dead, .init_failed);
        return report.fail(.internal_error);
    };
    traceEvent(trace_fd, "child.node_fs.enabled");

    // The definition's pack is registered and every route's entry evaluated
    // before ready, so a ready worker's first request needs no module work.
    // Registration failures, the init deadline and memory exhaustion fail the
    // init, because a published worker that received a pack must hold it
    // registered; how user-code failures are kept is `bootEvaluateRoute` in
    // `worker/modules/routes.zig`.
    if (received.module_pack_fd) |module_pack_fd| {
        // The evaluation deadline leaves the cleanup reserve before the host's
        // init deadline, so the child can stop the VM, report the failure and
        // exit before the host kills it. Only JavaScript can be interrupted,
        // by the sentinel, so the native steps above are bounded by the host's
        // deadline alone.
        const eval_deadline_mono_ns = received.message.init_deadline_mono_ns -|
            process_limits.WORKER_INIT_CLEANUP_RESERVE_NS;

        // The receiver hands over the pack exactly when the message sets
        // `flag_serves_routes` (`ipc.recvWorkerInit`), and the message was
        // validated to carry a route table with routes in that case.
        var eval_marks: worker_runtime.BootEvalMarks = .{};
        runtime.evaluateBootRoutes(
            module_pack_fd,
            eval_deadline_mono_ns,
            &eval_marks,
        ) catch |err| {
            worker_state.metrics.?.setState(.dead, .init_failed);
            std.log.err("worker boot route evaluation setup failed: {s}", .{@errorName(err)});
            // A watchdog stop is reported with its own reason, and the child
            // exits on its own within the cleanup reserve
            // (`WorkerInitFailedReason.init_deadline_exceeded` says what the
            // host does).
            return report.fail(switch (err) {
                error.WorkerInitDeadlineExceeded => .init_deadline_exceeded,
                else => .internal_error,
            });
        };
        // The evaluation's inner marks are stamped before the closing phase so
        // the phases read in order. A zero mark means a step did not run.
        stampBootPhaseAt(&boot_stamps, &maybe_metrics, .module_pack_mapped, eval_marks.pack_mapped_ns);
        stampBootPhaseAt(&boot_stamps, &maybe_metrics, .module_pack_parsed, eval_marks.pack_parsed_ns);
        stampBootPhaseAt(&boot_stamps, &maybe_metrics, .module_pack_registered, eval_marks.pack_registered_ns);
        traceEvent(trace_fd, "child.routes.evaluated");
        stampBootPhase(&boot_stamps, &maybe_metrics, .routes_evaluated);
    }
    if (received.takeModulePackFd()) |fd|
        std.posix.close(fd);

    worker_state.metrics.?.setState(.ready, .none);
    worker_state.lifecycle_state = .ready;
    traceEvent(trace_fd, "child.worker_ready");
    try report.ready();
    stampBootPhase(&boot_stamps, &maybe_metrics, .ready_sent);

    // From here on the init socket is the worker's control channel, and a
    // failure ends the worker without a message on it.
    traceEvent(trace_fd, "worker.scheduler.uring");
    worker_runtime.run(&runtime) catch |err| {
        traceEventFmt(trace_fd, "worker.scheduler.failed={s}", .{@errorName(err)});
        std.log.err("worker event loop failed: {s}", .{@errorName(err)});
        return err;
    };
    traceEvent(trace_fd, "worker.scheduler.stopped");
    std.posix.close(child_init_fd);
}

fn recvWorkerInitBeforeTimeout(
    fd: std.posix.fd_t,
    trace_fd: ?std.posix.fd_t,
) !ipc.WorkerInitWithFds {
    var pollfds = [1]std.posix.pollfd{
        .{
            .fd = fd,
            .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR,
            .revents = 0,
        },
    };

    const ready = try std.posix.poll(&pollfds, process_limits.WORKER_INIT_TIMEOUT_MS);
    if (ready == 0) {
        traceEvent(trace_fd, "child.worker_init.timeout");
        return error.WorkerInitTimeout;
    }

    return ipc.recvWorkerInit(fd);
}

/// Closes every descriptor WorkerInit did not bring, except the init socket
/// and the trace pipe, and points the standard descriptors at /dev/null. The
/// leaf files the child keeps (`worker_boot/cgroup.zig:OpenedWorkerLeaf`)
/// are opened after it, so they need no place in the allowlist.
fn closeUnexpectedWorkerFds(
    child_init_fd: std.posix.fd_t,
    trace_fd: ?std.posix.fd_t,
    received: *const ipc.WorkerInitWithFds,
) !void {
    var allow: [1 + 1 + 7 + ipc.egress_shared.shared_fd_count + 1 + 2]std.posix.fd_t = undefined;
    var len: usize = 0;

    allow[len] = child_init_fd;
    len += 1;
    if (trace_fd) |fd| {
        allow[len] = fd;
        len += 1;
    }
    allow[len] = received.metrics_fd;
    len += 1;
    allow[len] = received.completion_eventfd;
    len += 1;
    allow[len] = received.ingress_payload_fd;
    len += 1;
    allow[len] = received.ingress_payload_credit_eventfd;
    len += 1;
    allow[len] = received.tmp_root_fd;
    len += 1;
    allow[len] = received.cgroup_dir_fd;
    len += 1;
    allow[len] = received.route_table_fd;
    len += 1;
    if (received.module_pack_fd) |fd| {
        allow[len] = fd;
        len += 1;
    }
    if (received.fs_index_fd >= 0) {
        allow[len] = received.fs_index_fd;
        len += 1;
    }
    if (received.fs_fault_fd >= 0) {
        allow[len] = received.fs_fault_fd;
        len += 1;
    }

    // The receiver took the wake descriptors exactly with `flag_egress` and
    // the regions whole or not at all, so a set that is not whole has its
    // wake descriptors or nothing.
    const egress = received.egress_shared_fds;
    if (egress.isValid()) {
        for (egress.asArray()) |fd| {
            allow[len] = fd;
            len += 1;
        }
    } else if (received.message.hasEgress()) {
        for (egress.wakeFds().asArray()) |fd| {
            allow[len] = fd;
            len += 1;
        }
    }

    try fd_mod.closeAllExceptFrom(0, allow[0..len]);
    try fd_mod.redirectUnallowedStandardFdsToDevNull(allow[0..len]);
}

fn validateWorkerInit(message: *const ipc.WorkerInit) !void {
    try message.validate();
    if (!message.wantsIsolatedNetwork())
        return error.InvalidWorkerInitFlags;
    if (!message.wantsDenyDirectEgress())
        return error.InvalidWorkerInitFlags;
}

fn validateWorkerInitFds(received: *const ipc.WorkerInitWithFds) !void {
    try worker_shared_page.validateMemfd(received.metrics_fd);
    try fd_mod.requireEventFd(received.completion_eventfd);
    try fd_mod.requireEventFd(received.ingress_payload_credit_eventfd);
    try worker_sandbox.tmp_root.validateFd(received.tmp_root_fd);
    try worker_cgroup.validateWorkerCgroupDirFd(received.cgroup_dir_fd);
    try fd_mod.requireSeals(received.route_table_fd, fd_mod.memfd_readonly_seals);
    // The fs index is mapped and parsed only after the sandbox, in
    // fs.initWorker; checking its seals and the fault channel's socket type
    // here makes a wrong descriptor fail the handshake instead of a later
    // filesystem access.
    try fd_mod.requireSeals(received.fs_index_fd, fd_mod.memfd_readonly_seals);
    try validateSeqpacketSocketFd(received.fs_fault_fd);
    try validateEgressFds(&received.message, received.egress_shared_fds);
}

/// A worker whose definition has a network grant gets its wake descriptors
/// (`flag_egress`), and one without gets no egress descriptor at all, so it
/// has nothing to reach a gateway with. The receiver already counted them
/// against the flag; this checks what they are, while /proc can still name
/// an eventfd.
fn validateEgressFds(message: *const ipc.WorkerInit, egress: ipc.egress_shared.RawFds) !void {
    if (!message.hasEgress()) {
        if (!egress.isEmpty())
            return error.UnexpectedEgressFds;
        return;
    }
    const egress_wake = egress.wakeFds();
    try fd_mod.requireEventFd(egress_wake.command_eventfd);
    try fd_mod.requireEventFd(egress_wake.completion_eventfd);
}

fn validateSeqpacketSocketFd(fd: std.posix.fd_t) !void {
    if (fd < 0)
        return error.InvalidFsFaultFd;
    const socket_type = socket.socketType(fd) catch return error.InvalidFsFaultFd;
    if (socket_type != std.posix.SOCK.SEQPACKET)
        return error.InvalidFsFaultFd;
}

/// Fails unless glibc's CPU clock id for the calling thread is the one the
/// kernel builds from the thread's own id, which holds only when glibc's
/// cached thread id is the thread's own.
fn validateOwnThreadIdentity() !void {
    const libc_clock = try process.libcThreadCpuClockId();
    if (libc_clock != process.threadCpuClockId(std.os.linux.gettid()))
        return error.ThreadIdentityMismatch;
}

fn mapRouteTableReadOnly(
    fd: std.posix.fd_t,
    len_u64: u64,
) ![]align(std.heap.page_size_min) const u8 {
    if (len_u64 < ipc.route_table.empty_blob.len)
        return error.InvalidRouteTable;
    if (len_u64 > ipc.route_table.bytes_max)
        return error.InvalidRouteTable;
    if (len_u64 > std.math.maxInt(usize))
        return error.InvalidRouteTable;
    const len: usize = @intCast(len_u64);
    try fd_mod.requireSeals(fd, fd_mod.memfd_readonly_seals);
    const stat = try std.posix.fstat(fd);
    if (stat.size != len)
        return error.InvalidRouteTable;
    // A shared mapping of a write-sealed memfd fails with EPERM while the fd
    // is open read-write, since mprotect could later break the seal. A private
    // read-only mapping of the sealed table shows the same bytes.
    return std.posix.mmap(
        null,
        len,
        std.posix.PROT.READ,
        .{ .TYPE = .PRIVATE },
        fd,
        0,
    );
}

pub fn applyWorkerEnvironmentPolicy() !void {
    if (clearenv() != 0)
        return error.WorkerEnvironmentSetupFailed;
    inline for (worker_environment_retained_names, worker_environment_canonical_values) |name, value|
        try setWorkerEnvironmentEntry(name, value);
}

fn setWorkerEnvironmentEntry(comptime name: [:0]const u8, comptime value: [:0]const u8) !void {
    comptime {
        var known = false;
        for (worker_environment_retained_names) |retained| {
            if (std.mem.eql(u8, retained, name))
                known = true;
        }
        if (!known)
            @compileError("worker environment entry must be listed in worker_environment_retained_names");
    }
    if (setenv(name, value, 1) != 0)
        return error.WorkerEnvironmentSetupFailed;
}

fn markInitFailedIfPossible(metrics_fd: std.posix.fd_t) void {
    var metrics = worker_shared_page.mapReadWrite(metrics_fd) catch return;
    defer metrics.deinit();
    metrics.setState(.dead, .init_failed);
}

fn runtimeOptionsFromWorkerInit(message: *const ipc.WorkerInit, base: worker_runtime.RuntimeOptions) worker_runtime.RuntimeOptions {
    var options = base;
    options.limits = runtimeLimitsFromBootOptions(&message.runtime);
    // The definition's limits on JavaScript, checked by `WorkerInit.validate`:
    // each request's CPU budget, and the wall time JavaScript no request owns
    // may run at a stretch.
    options.request_cpu_budget_ns = message.request_cpu_budget_ns;
    options.unowned_time_limit_ns = message.unowned_time_limit_ns;
    options.trace_requests = (message.runtime.runtime_flags & ipc.WorkerRuntimeBootOptions.flag_trace_requests) != 0;
    options.trace_all_requests = (message.runtime.runtime_flags & ipc.WorkerRuntimeBootOptions.flag_trace_all_requests) != 0;
    options.bench_handler =
        (message.runtime.runtime_flags & ipc.WorkerRuntimeBootOptions.flag_bench_handler) != 0;
    options.log_full_js_exceptions = (message.runtime.runtime_flags & ipc.WorkerRuntimeBootOptions.flag_log_full_js_exceptions) != 0;
    return options;
}

fn runtimeLimitsFromBootOptions(options: *const ipc.WorkerRuntimeBootOptions) worker_runtime.RuntimeLimits {
    return .{
        .max_fetches_per_request = @intCast(options.max_fetches_per_request),
        .max_fetches_per_worker = @intCast(options.max_fetches_per_worker),
        .max_timers_per_worker = @intCast(options.max_timers_per_worker),
        .ready_queue_capacity = @intCast(options.ready_queue_capacity),
        .request_task_capacity = @intCast(options.request_task_capacity),
        .crypto_thread_count = @intCast(options.crypto_thread_count),
        .crypto_max_in_flight_per_request = @intCast(options.crypto_max_in_flight_per_request),
        .crypto_max_in_flight_per_worker = @intCast(options.crypto_max_in_flight_per_worker),
    };
}

fn traceWorkerEgressEndpoint(trace_fd: ?std.posix.fd_t, runtime: *const worker_runtime.Runtime) void {
    const endpoint = runtime.egress.state.shared orelse {
        traceEvent(trace_fd, "child.egress_endpoint.detached");
        return;
    };
    traceFdMode(trace_fd, "child.egress_endpoint.liveness", endpoint.liveness_fd);
    traceFdMode(trace_fd, "child.egress_endpoint.peer_liveness", endpoint.peer_liveness_fd);
}

fn traceFdMode(trace_fd: ?std.posix.fd_t, comptime name: []const u8, fd: std.posix.fd_t) void {
    const flags = std.posix.fcntl(fd, std.posix.F.GETFL, 0) catch {
        traceEventFmt(trace_fd, name ++ "=fd:{d},flags:invalid,access:invalid", .{fd});
        return;
    };
    traceEventFmt(trace_fd, name ++ "=fd:{d},flags:0x{x},access:{s}", .{
        fd,
        flags,
        fdAccessName(flags),
    });
}

fn fdAccessName(flags: usize) []const u8 {
    return switch (flags & 0x3) {
        0 => "read",
        1 => "write",
        2 => "read_write",
        else => "unknown",
    };
}

/// Records one CLOCK_MONOTONIC reading for a boot phase in the local buffer
/// and, once the metrics page is mapped, in the page too.
fn stampBootPhase(
    stamps: *[worker_shared_page.BOOT_PHASE_COUNT]u64,
    metrics: ?*worker_shared_page.WorkerWriterView,
    phase: worker_shared_page.BootPhase,
) void {
    const now_ns = process.monotonicNowNsOrZero();
    stamps[@intFromEnum(phase)] = now_ns;
    if (metrics) |view|
        view.storeBootPhaseStampNs(phase, now_ns);
}

/// Stamps a phase with a monotonic mark taken earlier, inside the evaluation;
/// reading the clock here would misattribute the time. A zero mark means the
/// step did not run and is left unstamped.
fn stampBootPhaseAt(
    stamps: *[worker_shared_page.BOOT_PHASE_COUNT]u64,
    metrics: ?*worker_shared_page.WorkerWriterView,
    phase: worker_shared_page.BootPhase,
    mark_ns: u64,
) void {
    if (mark_ns == 0)
        return;
    stamps[@intFromEnum(phase)] = mark_ns;
    if (metrics) |view|
        view.storeBootPhaseStampNs(phase, mark_ns);
}

fn installExitProbe(path: ?[]const u8) void {
    const probe_path = path orelse return;
    const mode: [*:0]const u8 = "w";
    const c_path = boot_allocator.dupeZ(u8, probe_path) catch return;
    defer boot_allocator.free(c_path);
    const file = std.c.fopen(c_path.ptr, mode) orelse return;
    defer _ = std.c.fclose(file);
    _ = std.c.fwrite("postfork-exit-probe", 1, "postfork-exit-probe".len, file);
}

fn childExit(status: u8) noreturn {
    std.c._exit(@intCast(status));
}

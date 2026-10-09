//! The WorkerInit handoff as a machine: from a forked child to a ready
//! worker, or to a typed failure that hands the child back to its caller.
//!
//! The local steps (bindings memfd, tmp root, cgroup adopt, shared pages, the
//! WorkerInit sendmsg) are microsecond syscalls and run inline in `start`.
//! The wait for the child's answer belongs to the host: an evented host (the
//! server's launcher, `server/supervisor/launcher.zig`) polls the init socket
//! and the pidfd among its own descriptors and feeds `onEvent`, and the
//! synchronous driver `runToReady` drives the same transition table with
//! poll(2). The route's pack and the worker's egress descriptors ride
//! WorkerInit itself: every pack is resident, every launch sends the worker's
//! wake descriptors, and a launch with an egress session, which the host
//! attaches before it starts the launch, sends the session's regions too
//! (`LaunchEgress`). The boot token for the session is minted here, when
//! WorkerInit is sent, because its deadline is the child window this file
//! fixes. A launch without a session boots its child detached.
//!
//! A launch that fails neither kills, waits nor removes a cgroup on the
//! host's thread: `abandon` releases what the machine holds and hands the
//! child's pidfd and cgroup leaf back as an `AbandonedChild`, whose `reap`
//! does the blocking part on whichever thread may block.
//!
//! Clock contract: `owner_deadline_abs_ns` bounds the whole machine;
//! `child_init_deadline_abs_ns = min(send_time + WORKER_INIT_TIMEOUT_MS,
//! owner_deadline_abs_ns)` is fixed when WorkerInit is sent, travels in it
//! as the init deadline and as the boot token's deadline, and never changes
//! after. The phases before the send spend the owner's budget, never the
//! child's.

const std = @import("std");
const ipc = @import("collo_ipc");
const fd_mod = @import("collo_os").fd;
const process = @import("collo_os").process;
const process_limits = @import("collo_limits").process;
const limits = @import("collo_limits");
const worker_shared_page = @import("collo_worker_state").page;
const zygote = @import("collo_zygote");

const cgroup = @import("cgroup.zig");
const cgroup_root = @import("cgroup_root.zig");
const handle_mod = @import("handle.zig");

const route_bindings = ipc.route_bindings;

const TMP_ROOT_RANDOM_SUFFIX_BYTES: usize = 16;
const WORKER_TMP_ROOT_MODE: u32 = zygote.worker_boot.sandbox.tmp_root.required_mode;

/// Per-call packet cap of a boot-window fault drain. The deadline stays the
/// primary bound; this bounds one drain call so a flooding worker yields the
/// thread back to the poll loop, which re-arms on the still-readable fd.
pub const max_faults_per_drain: usize = 64;

/// Grace for the post-ready drain: async faults the worker sent before it
/// reported ready are answered by the launch inside this budget, quiescing
/// the channel before the fd hands over to the host's reader. A legitimate
/// worker has a handful of pending faults and hits are answered in
/// microseconds, so only cold misses spend real time here.
pub const post_ready_drain_grace_ns: u64 = 3 * std.time.ns_per_s;

pub const DrainOutcome = enum {
    /// The channel quiesced (recv hit WouldBlock) or the per-drain cap was
    /// reached; every received fault was answered. The caller re-arms on
    /// the fd and re-checks its deadline.
    idle,
    /// Worker end closed; nothing further can be served. The init fd and
    /// pidfd legs resolve the worker's fate.
    peer_closed,
    /// The deadline passed while packets kept arriving. Pre-ready this
    /// resolves to WorkerInitTimeout; in the post-ready grace any leftover
    /// packets reach the host's reader and are refused there.
    deadline_exhausted,
};

/// Host-side cold-start spans, recorded from phase-entry timestamps.
pub const LaunchSpans = struct {
    route_bindings_memfd_ns: u64 = 0,
    tmp_root_ns: u64 = 0,
    cgroup_adopt_ns: u64 = 0,
    /// The inside of `cgroup_adopt_ns`: probe, rewrite, path resolution.
    cgroup_adopt: cgroup.AdoptSpans = .{},
    shared_resources_ns: u64 = 0,
    init_send_ns: u64 = 0,
    ready_wait_ns: u64 = 0,
    total_ns: u64 = 0,
};

pub const LaunchError = error{
    WorkerCgroupNotPrepared,
    InvalidWorkerTmpRootMode,
    InvalidWorkerTmpRootOwner,
    InvalidBootOptions,
    /// A detached launch could not open the worker's wake descriptors from
    /// its wake set (`ipc.egress_shared.WakeSet.openWorkerWake`), for want of
    /// descriptors.
    EgressWakeUnavailable,
    WorkerInitTimeout,
    /// The child reported an init failure or ended before `WorkerReady`;
    /// `Machine.init_failure` says which.
    WorkerInitFailed,
    ZygoteProtocol,
    OutOfMemory,
};

/// What failed a child's init, which `error.WorkerInitFailed` does not say.
pub const InitFailure = union(enum) {
    /// The child sent `WorkerInitFailed` with this reason.
    reported: ipc.WorkerInitFailedReason,
    /// The child ended without a report, for memory: its sentinel stored
    /// reason `memory` on its page before it exited, or the kernel's OOM
    /// kill counted in its leaf's `memory.events.local`.
    memory,
    /// The child ended without a report, and neither its page nor its leaf
    /// names memory: it crashed, or something killed it.
    crash,

    pub fn format(self: InitFailure, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .reported => |reason| try writer.print("the child reported {s}", .{@tagName(reason)}),
            .memory => try writer.writeAll("the child ended for memory"),
            .crash => try writer.writeAll("the child ended without a report"),
        }
    }
};

/// What a fault-serve callback answers for one request.
pub const FaultAnswer = union(enum) {
    /// Owned: the drain sends it and closes it.
    ok: std.posix.fd_t,
    refused,
    not_found,
    fetch_failed,
};

/// The boot-window fault service. The drain (decode, no-fd containment,
/// exactly-one-fd responses, deadline and packet cap) is machine-owned;
/// only the answer is the host's.
pub const FaultServe = union(enum) {
    /// No serving context: the fault leg stays dark and the worker's faults
    /// wait for the host's post-ready reader.
    none,
    serve: Serve,

    pub const Serve = struct {
        ctx: ?*anyopaque = null,
        /// `deadline_ns` is the drain's absolute bound: an answer that has to
        /// fetch must not outlive it.
        serve: *const fn (ctx: ?*anyopaque, request: *const ipc.FsFaultRequest, deadline_ns: u64) FaultAnswer,
    };
};

/// What the boot token of a launch with an egress grant carries besides its deadline, which is
/// the child window this launch fixes when it sends WorkerInit. The machine scrubs its copy of
/// the key once the token is minted.
pub const BootEgress = struct {
    key: ipc.egress_token.Key,
    session_id: u64,
    policy_id: u16,
    budget: u32,
};

/// The egress descriptors a launch sends with WorkerInit: the worker's wake
/// descriptors always, and with a session its regions beside the boot token,
/// the pairing `ipc.zygote_worker` requires.
pub const LaunchEgress = union(enum) {
    /// No session: the child boots detached with wake descriptors this launch
    /// opens from the worker's wake set, borrowed for the length of `start`
    /// (`ipc.egress_shared.WakeSet.openWorkerWake`). Every fetch is refused
    /// until the host attaches the worker on its control socket
    /// (`ipc.egress_attach`).
    detached: *const ipc.egress_shared.WakeSet,
    /// The worker's half of the session the host attached for this launch,
    /// built on the worker's wake set
    /// (`ipc.egress_shared.createSessionForWorker`) and borrowed for the
    /// length of `start`, with what its boot token carries.
    attached: Attached,

    pub const Attached = struct {
        shared_fds: ipc.egress_shared.RawFds,
        boot: BootEgress,
    };
};

pub const LaunchOptions = struct {
    /// Every launch sends the worker's wake descriptors, so every host
    /// passes the worker's wake set or a session built on it.
    egress: LaunchEgress,
    /// The route's sealed bindings blob (`ipc.route_bindings`), borrowed for
    /// the length of `start`; the machine dups it and owns the copy. null
    /// means a route with no bindings, whose empty blob is built inline. The
    /// worker builds the route's `env` from it and never `process.env`.
    route_bindings: ?route_bindings.Sealed = null,
    /// null = `WorkerInit.defaultTmpfsSizeBytes(memory_limit_bytes)`; any
    /// other value is clamped to the memory limit.
    tmpfs_size_bytes: ?u64 = null,
    /// The worker cgroup's `cpu.max` quota, in cores. The default is the
    /// quota every worker of the server gets (`limits.worker.cpu_max_cores`).
    cpu_max_cores: u32 = limits.worker.cpu_max_cores,
    /// Runtime limits and diagnostic flags the child boots with; validated
    /// before WorkerInit is sent.
    boot: ipc.WorkerRuntimeBootOptions = ipc.WorkerRuntimeBootOptions.default(),
    /// The route the worker launches with, its pack borrowed for the length
    /// of `start`. A launch with a route entry serves routes: WorkerInit
    /// carries `flag_serves_routes`, and the child evaluates the entry before
    /// it reports ready, with timers for module top-level code and, when the
    /// child is attached, fetch under the boot token. null launches a worker
    /// with no route pack, which serves no route, since no dispatch carries
    /// one.
    route_entry: ?ipc.zygote_worker.RouteEntryInit = null,
    /// The sealed fs index, borrowed; null sends the placeholder index of a
    /// tree with no files.
    fs_index_memfd: ?std.posix.fd_t = null,
    fault_serve: FaultServe = .none,
    /// Whole-machine budget. 0 means no owner bound, and the child window is
    /// exactly WORKER_INIT_TIMEOUT_MS from the send.
    owner_deadline_abs_ns: u64 = 0,
    /// Overrides the child window entirely; a test seam for the
    /// deadline-shrink cases.
    init_deadline_override_abs_ns: ?u64 = null,
};

pub const LaunchPhase = enum(u8) {
    idle,
    /// WorkerInit sent; consuming init_fd/pidfd/fault_fd events.
    awaiting_ready,
    /// Ready received; grace-draining the fault channel (timer-bounded).
    grace_drain,
    ready,
    failed,
};

/// Events a host feeds to the machine. The sync driver synthesizes the same
/// events from poll(2) revents.
pub const LaunchEvent = union(enum) {
    init_readable,
    init_hup,
    pidfd_event,
    fault_readable,
    /// A fault drain (a job in evented mode) finished.
    fault_drain_done: DrainOutcome,
    grace_expired,
    child_deadline_expired,
};

/// Effects the machine asks of its host.
pub const LaunchEffect = union(enum) {
    none,
    arm_init_poll,
    arm_pidfd_poll,
    arm_fault_poll,
    start_fault_drain_job,
    arm_grace_timer: u64,
    report_ready,
    report_failed: LaunchError,
};

pub const StepResult = struct {
    effects: [4]LaunchEffect = @splat(.none),
    count: usize = 0,

    fn push(self: *StepResult, effect: LaunchEffect) void {
        std.debug.assert(self.count < self.effects.len);
        self.effects[self.count] = effect;
        self.count += 1;
    }
};

/// What a launch that gave up leaves of its child: the pidfd, and the cgroup
/// leaf the child was born into. Each is owned by the holder and unset when
/// the launch never had it; `reap` releases both.
pub const AbandonedChild = struct {
    pid: u32 = 0,
    pidfd: fd_mod.OwnedFd = .{},
    cgroup_dir: fd_mod.OwnedFd = .{},

    /// Kills the child, waits for its exit up to `PROCESS_EXIT_WAIT_MS`,
    /// removes its cgroup leaf with the bounded retries of
    /// `host/cgroup_root.zig` and closes both descriptors. The kill comes
    /// first because a leaf with a member refuses rmdir. Blocks, so only a
    /// thread that may wait calls it.
    pub fn reap(self: *AbandonedChild) void {
        if (self.pidfd.isValid()) {
            process.pidFdSendSignal(self.pidfd.fd(), std.posix.SIG.KILL) catch |err| switch (err) {
                error.ProcessNotFound => {},
                else => std.log.warn("failed to SIGKILL an abandoned worker pid={d}: {s}", .{ self.pid, @errorName(err) }),
            };
            const exited = process.waitForPidFdExit(self.pidfd.fd(), process_limits.PROCESS_EXIT_WAIT_MS) catch |err| blk: {
                std.log.warn("failed to wait for an abandoned worker pid={d}: {s}", .{ self.pid, @errorName(err) });
                break :blk false;
            };
            // The cgroup removal below kills any member again and retries.
            if (!exited)
                std.log.warn("abandoned worker pid={d} did not report its exit; removing its cgroup leaf anyway", .{self.pid});
        }
        if (self.cgroup_dir.isValid())
            cgroup_root.reapWorkerCgroupByFd(self.cgroup_dir.fd());
        self.cgroup_dir.deinit();
        self.pidfd.deinit();
    }
};

pub const Machine = struct {
    allocator: std.mem.Allocator,
    zygote_process: *zygote.host_client.SpawnedZygote,
    memory_limit_bytes: u64,
    options: LaunchOptions,

    phase: LaunchPhase = .idle,
    spans: LaunchSpans = .{},
    launch_started_ns: u64 = 0,
    phase_entered_ns: u64 = 0,
    child_init_deadline_abs_ns: u64 = 0,
    /// Host CLOCK_MONOTONIC immediately after consuming WorkerReady, before
    /// the post-ready fault drain and handle construction.
    ready_received_ns: u64 = 0,

    // Child identity, taken from the ForkedWorker on start.
    pid: u32 = 0,
    pidfd: std.posix.fd_t = -1,
    worker_init_fd: std.posix.fd_t = -1,

    // Local resources, owned until handle assembly or `abandon`.
    route_bindings_memfd: std.posix.fd_t = -1,
    route_bindings_blob_len: u64 = 0,
    tmp_root: ?[]u8 = null,
    tmp_root_dir_fd: std.posix.fd_t = -1,
    cgroup_dir: ?[]u8 = null,
    cgroup_dir_fd: std.posix.fd_t = -1,
    metrics_fd: std.posix.fd_t = -1,
    completion_eventfd: std.posix.fd_t = -1,
    ingress_payload_fd: std.posix.fd_t = -1,
    ingress_payload_credit_eventfd: std.posix.fd_t = -1,
    metrics: ?worker_shared_page.WorkerWriterView = null,
    ingress_payload: ?ipc.ingress_channel.SharedPayloadView = null,
    placeholder_fs_index_fd: std.posix.fd_t = -1,
    fs_fault_server_fd: std.posix.fd_t = -1,
    fs_fault_worker_fd: std.posix.fd_t = -1,

    serve_faults: bool = false,
    /// One drain in flight at a time (evented mode): the job is the channel's
    /// only reader while it runs.
    fault_drain_inflight: bool = false,
    /// Receive scratch for the boot-window fault channel, allocated on the
    /// first fault this boot serves: a boot with no faults never pays for it,
    /// and one that serves many pays once instead of a megabyte per wake.
    fault_scratch: ?[]u8 = null,
    boot_faults_served: u32 = 0,
    fail_reason: ?LaunchError = null,
    /// Set when the launch failed with `error.WorkerInitFailed`.
    init_failure: ?InitFailure = null,

    pub fn init(
        allocator: std.mem.Allocator,
        zygote_process: *zygote.host_client.SpawnedZygote,
        memory_limit_bytes: u64,
        options: LaunchOptions,
    ) Machine {
        return .{
            .allocator = allocator,
            .zygote_process = zygote_process,
            .memory_limit_bytes = memory_limit_bytes,
            .options = options,
        };
    }

    /// Takes every descriptor `forked` holds, so `forked` is empty whatever
    /// the outcome, runs the local steps (bindings memfd, tmp root, cgroup
    /// adopt, shared resources) and sends WorkerInit. The result asks the
    /// host to poll the init socket and the pidfd, or reports the failure;
    /// after a failure the host calls `abandon`.
    pub fn start(self: *Machine, forked: *zygote.host_client.ForkedWorker) StepResult {
        var result: StepResult = .{};
        self.takeChild(forked);
        self.prepare() catch |err| {
            self.fail(err, &result);
            return result;
        };
        self.sendInitAndAwait(&result);
        return result;
    }

    /// Sends WorkerInit and enters the ready wait, for a machine whose local
    /// steps are done; `start` ends with it.
    pub fn sendInit(self: *Machine) StepResult {
        var result: StepResult = .{};
        self.sendInitAndAwait(&result);
        return result;
    }

    fn takeChild(self: *Machine, forked: *zygote.host_client.ForkedWorker) void {
        self.pid = forked.pid;
        // The pidfd was created atomically by the clone (CLONE_PIDFD) and
        // travelled via SCM_RIGHTS; it is never re-derived from the pid.
        if (forked.pidfd) |fd| {
            self.pidfd = fd;
            forked.pidfd = null;
        }
        if (forked.worker_init_fd) |fd| {
            self.worker_init_fd = fd;
            forked.worker_init_fd = null;
        }
        if (forked.cgroup_dir_fd) |fd| {
            self.cgroup_dir_fd = fd;
            forked.cgroup_dir_fd = null;
        }
    }

    fn prepare(self: *Machine) LaunchError!void {
        const started = process.monotonicNowNs() catch return error.ZygoteProtocol;
        self.launch_started_ns = started;
        self.phase_entered_ns = started;

        if (self.worker_init_fd < 0)
            return error.ZygoteProtocol;
        if (self.pidfd < 0)
            return error.ZygoteProtocol;
        // A worker is born inside a pre-created cgroup (CLONE_INTO_CGROUP)
        // and is its only member by construction. Without the leaf there is
        // no memory bound, so there is no launch.
        if (self.cgroup_dir_fd < 0)
            return error.WorkerCgroupNotPrepared;

        var span_cursor_ns = started;

        const blob = if (self.options.route_bindings) |shared|
            shared.dupCloexec() catch |err| return mapResourceError(err)
        else
            route_bindings.createEmptySealed() catch |err| return mapResourceError(err);
        self.route_bindings_memfd = blob.fd;
        self.route_bindings_blob_len = blob.blob_len;
        self.spans.route_bindings_memfd_ns = spanDelta(&span_cursor_ns);

        const tmp_root = makeTmpRoot(self.allocator, self.pid) catch return error.OutOfMemory;
        self.tmp_root = tmp_root;
        createTmpRoot(tmp_root) catch return error.ZygoteProtocol;
        const tmp_dir = openValidatedTmpRoot(tmp_root) catch |err| return switch (err) {
            error.InvalidWorkerTmpRootMode => error.InvalidWorkerTmpRootMode,
            error.InvalidWorkerTmpRootOwner => error.InvalidWorkerTmpRootOwner,
            else => error.ZygoteProtocol,
        };
        self.tmp_root_dir_fd = tmp_dir.fd;
        self.traceFmt("host.worker.tmp_root={s}", .{tmp_root});
        // Every span closes after its own trace write: a trace write is a
        // write(2) into the zygote's pipe, and one between two cursors would
        // be counted in the phase that follows.
        self.spans.tmp_root_ns = spanDelta(&span_cursor_ns);

        self.cgroup_dir = cgroup.adoptPreparedWorkerDir(
            self.allocator,
            self.cgroup_dir_fd,
            self.memory_limit_bytes,
            self.options.cpu_max_cores,
            &self.spans.cgroup_adopt,
        ) catch return error.WorkerCgroupNotPrepared;
        self.spans.cgroup_adopt_ns = spanDelta(&span_cursor_ns);
        self.traceFmt("host.cgroup.dir={s}", .{self.cgroup_dir.?});
        self.traceFmt("host.cgroup.limits={d}/{d}", .{ self.memory_limit_bytes, self.options.cpu_max_cores });

        self.metrics_fd = worker_shared_page.createMemfd("collo-shared-metrics") catch
            return error.ZygoteProtocol;
        self.completion_eventfd = std.posix.eventfd(
            0,
            std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK,
        ) catch return error.ZygoteProtocol;
        self.ingress_payload_fd = ipc.ingress_channel.createSharedPayloadMemfd() catch
            return error.ZygoteProtocol;
        self.ingress_payload_credit_eventfd = std.posix.eventfd(
            0,
            std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK,
        ) catch return error.ZygoteProtocol;
        self.trace("host.metrics.created");

        var metrics = worker_shared_page.mapReadWrite(self.metrics_fd) catch
            return error.ZygoteProtocol;
        metrics.initializeCrashDefault(
            self.pid,
            self.memory_limit_bytes,
            process.monotonicNowNs() catch return error.ZygoteProtocol,
        );
        self.metrics = metrics;
        self.ingress_payload = ipc.ingress_channel.mapSharedPayloadReadWrite(self.ingress_payload_fd, .server) catch
            return error.ZygoteProtocol;

        if (self.options.fs_index_memfd == null) {
            self.placeholder_fs_index_fd = ipc.zygote_worker.createPlaceholderFsIndexMemfd() catch
                return error.ZygoteProtocol;
        }
        const fs_fault_pair = fd_mod.socketPairType(
            std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC,
        ) catch return error.ZygoteProtocol;
        self.fs_fault_server_fd = fs_fault_pair[0];
        self.fs_fault_worker_fd = fs_fault_pair[1];
        // Nonblocking from birth: boot-window drains read until WouldBlock.
        // The worker end is a separate open file description and keeps
        // blocking reads.
        fd_mod.setNonblocking(self.fs_fault_server_fd, true) catch
            return error.ZygoteProtocol;
        self.spans.shared_resources_ns = spanDelta(&span_cursor_ns);

        self.serve_faults = self.options.fault_serve != .none;
    }

    fn sendInitAndAwait(self: *Machine, result: *StepResult) void {
        self.sendWorkerInit() catch |err| {
            self.fail(err, result);
            return;
        };
        self.enter(.awaiting_ready);
        result.push(.arm_init_poll);
        result.push(.arm_pidfd_poll);
        if (self.serve_faults)
            result.push(.arm_fault_poll);
    }

    /// Sends WorkerInit with its descriptors. The child window is fixed here:
    /// the wire value is min(now + WORKER_INIT_TIMEOUT_MS, owner_deadline), so
    /// the phases before the send spent the owner's budget and the child gets
    /// its whole window. The boot token is minted here too, with that window
    /// as its deadline, after which the machine keeps no copy of its key, and
    /// a detached launch's wake descriptors are opened and, once the child
    /// holds its copies, closed here.
    fn sendWorkerInit(self: *Machine) LaunchError!void {
        var span_cursor_ns = process.monotonicNowNsOrZero();

        const send_now_ns = process.monotonicNowNs() catch return error.ZygoteProtocol;
        const default_deadline = send_now_ns +
            @as(u64, @intCast(process_limits.WORKER_INIT_TIMEOUT_MS)) * std.time.ns_per_ms;
        self.child_init_deadline_abs_ns = self.options.init_deadline_override_abs_ns orelse
            if (self.options.owner_deadline_abs_ns != 0)
                @min(default_deadline, self.options.owner_deadline_abs_ns)
            else
                default_deadline;

        self.options.boot.validate() catch return error.InvalidBootOptions;
        var detached_wake: ipc.egress_shared.WakeFds = .{};
        defer detached_wake.close();
        const egress_fds: ipc.egress_shared.RawFds = switch (self.options.egress) {
            .detached => |wake_set| blk: {
                detached_wake = wake_set.openWorkerWake() catch return error.EgressWakeUnavailable;
                break :blk ipc.egress_shared.RawFds.wakeOnly(detached_wake);
            },
            .attached => |attached| attached.shared_fds,
        };
        var message = ipc.WorkerInit.init(self.memory_limit_bytes, self.options.boot) catch
            return error.ZygoteProtocol;
        // The child checks its own cgroup against both limits.
        message.cpu_max_cores = self.options.cpu_max_cores;
        message.tmpfs_size_bytes = resolveTmpfsSizeBytes(self.memory_limit_bytes, self.options.tmpfs_size_bytes);
        message.route_bindings_blob_len = self.route_bindings_blob_len;
        message.init_deadline_mono_ns = self.child_init_deadline_abs_ns;
        message.boot_egress_token = switch (self.options.egress) {
            .detached => ipc.egress_token.none,
            .attached => |*attached| self.mintBootToken(&attached.boot),
        };
        message.enableEgressGatewaySandbox();
        if (self.options.route_entry != null)
            message.flags |= ipc.WorkerInit.flag_serves_routes;
        ipc.sendWorkerInitWithRouteBindingsAndEgressShared(
            self.worker_init_fd,
            &message,
            self.metrics_fd,
            self.completion_eventfd,
            self.ingress_payload_fd,
            self.ingress_payload_credit_eventfd,
            self.tmp_root_dir_fd,
            self.cgroup_dir_fd,
            self.route_bindings_memfd,
            egress_fds,
            self.options.route_entry,
            self.options.fs_index_memfd orelse self.placeholder_fs_index_fd,
            self.fs_fault_worker_fd,
        ) catch |err| return zygoteProtocolError(err);
        self.trace("host.worker_init.sent");
        self.spans.init_send_ns = spanDelta(&span_cursor_ns);

        // The worker end only had to survive the SCM_RIGHTS dup; the
        // bindings memfd likewise (the child holds its own reference now).
        std.posix.close(self.fs_fault_worker_fd);
        self.fs_fault_worker_fd = -1;
        std.posix.close(self.route_bindings_memfd);
        self.route_bindings_memfd = -1;
    }

    /// The boot token for `boot`'s session, whose deadline is the child
    /// window `sendWorkerInit` fixed. Scrubs `boot`'s key, the machine's only
    /// copy, which nothing reads once the token exists.
    fn mintBootToken(self: *const Machine, boot: *BootEgress) ipc.egress_token.Bytes {
        defer std.crypto.secureZero(u8, &boot.key.bytes);
        const token = ipc.egress_token.mint(&boot.key, .{
            .kind = .boot,
            .policy_id = boot.policy_id,
            .budget = boot.budget,
            .session_id = boot.session_id,
            .request_id = 0,
            .request_generation = 0,
            .deadline_monotonic_ns = self.child_init_deadline_abs_ns,
        });
        return ipc.egress_token.asBytes(&token).*;
    }

    /// The await-ready transition table, one event at a time. The caller
    /// (loop or sync driver) enforces the priority order when several fds
    /// are simultaneously ready: init POLLIN > pidfd > init HUP > fault.
    pub fn onEvent(self: *Machine, event: LaunchEvent) StepResult {
        var result: StepResult = .{};
        switch (event) {
            .init_readable, .init_hup => switch (self.phase) {
                // HUP without a queued outcome still tries the typed read.
                .awaiting_ready => self.finishInitOutcome(&result),
                else => {},
            },
            .pidfd_event => switch (self.phase) {
                .awaiting_ready => self.failChildEnded(&result),
                // A death after ready belongs to whoever holds the worker.
                else => {},
            },
            .fault_readable => switch (self.phase) {
                .awaiting_ready, .grace_drain => {
                    if (self.serve_faults and !self.fault_drain_inflight) {
                        self.fault_drain_inflight = true;
                        result.push(.start_fault_drain_job);
                    }
                },
                else => {},
            },
            .fault_drain_done => |outcome| {
                self.fault_drain_inflight = false;
                switch (outcome) {
                    .idle => if (self.serve_faults and self.phase == .awaiting_ready)
                        result.push(.arm_fault_poll),
                    .peer_closed, .deadline_exhausted => self.serve_faults = false,
                }
                if (self.phase == .grace_drain and !self.fault_drain_inflight)
                    self.completeReady(&result);
            },
            .grace_expired => if (self.phase == .grace_drain)
                self.completeReady(&result),
            .child_deadline_expired => switch (self.phase) {
                .awaiting_ready => {
                    self.trace("host.worker_init.timeout");
                    self.fail(error.WorkerInitTimeout, &result);
                },
                else => {},
            },
        }
        return result;
    }

    fn finishInitOutcome(self: *Machine, result: *StepResult) void {
        const outcome = zygote.host_client.receiveWorkerInitOutcome(self.worker_init_fd) catch |err| switch (err) {
            // The child holds its end of the init socket until it exits, so
            // a socket that ends without an outcome is the child's exit.
            error.PeerClosed => return self.failChildEnded(result),
            else => return self.fail(zygoteProtocolError(err), result),
        };
        switch (outcome) {
            .ready => {
                self.ready_received_ns = process.monotonicNowNsOrZero();
                self.spans.ready_wait_ns = self.ready_received_ns -| self.phase_entered_ns;
                if (self.serve_faults) {
                    // Async boot faults sent before ready are answered here,
                    // never by the host's reader: grace-drain before the fd
                    // escapes into the handle.
                    self.enter(.grace_drain);
                    result.push(.{ .arm_grace_timer = process.monotonicNowNsOrZero() +| post_ready_drain_grace_ns });
                    if (!self.fault_drain_inflight) {
                        self.fault_drain_inflight = true;
                        result.push(.start_fault_drain_job);
                    }
                    return;
                }
                self.completeReady(result);
            },
            .failed => |reason| {
                self.traceFmt("host.worker_init.failed={s}", .{@tagName(reason)});
                self.failInit(.{ .reported = reason }, result);
            },
        }
    }

    /// Fails the launch of a child that ended before `WorkerReady` without a
    /// report, for the cause its page and its leaf name.
    fn failChildEnded(self: *Machine, result: *StepResult) void {
        const cause = self.endedCause();
        self.traceFmt("host.worker_init.worker_exited={s}", .{@tagName(cause)});
        self.failInit(cause, result);
    }

    fn failInit(self: *Machine, cause: InitFailure, result: *StepResult) void {
        self.init_failure = cause;
        self.fail(error.WorkerInitFailed, result);
    }

    /// Why a child that ended without a report ended, by the rule the server
    /// applies to a published worker's death (`classifyWorkerDeath` in
    /// `server/supervisor/usage_drain.zig`): for memory when its page says
    /// its sentinel ended it for memory or its leaf counted a kernel OOM
    /// kill, which both land before the child's exit hangs its init socket
    /// up, and a crash otherwise. A page or a leaf it cannot read names no
    /// memory.
    fn endedCause(self: *const Machine) InitFailure {
        if (self.metrics) |*metrics| {
            // A reason outside `TerminationReason` names no memory.
            const snapshot = worker_shared_page.LifecycleSnapshot.load(metrics.header);
            if (snapshot.knownTerminationReason()) |reason| {
                if (reason == .memory)
                    return .memory;
            }
        }
        const cgroup_dir = self.cgroup_dir orelse return .crash;
        const events = cgroup.memory.readEventsLocal(self.allocator, cgroup_dir) catch |err| {
            std.log.warn("worker launch: memory.events.local of a child that ended could not be read: {s}", .{
                @errorName(err),
            });
            return .crash;
        };
        if (events.oom_kill > 0)
            return .memory;
        return .crash;
    }

    fn completeReady(self: *Machine, result: *StepResult) void {
        self.spans.total_ns = process.monotonicNowNsOrZero() -| self.launch_started_ns;
        if (self.boot_faults_served != 0)
            self.traceFmt("host.worker_init.fs_faults_served={d}", .{self.boot_faults_served});
        self.enter(.ready);
        result.push(.report_ready);
    }

    /// Assembles the handle; the machine relinquishes every resource it still
    /// owns. Call only in `.ready`. On `error.OutOfMemory` the machine still
    /// owns everything, and the host calls `abandon`.
    pub fn takeHandle(self: *Machine) LaunchError!handle_mod.WorkerHandle {
        std.debug.assert(self.phase == .ready);
        // The boot window is over: its fault scratch dies with it.
        if (self.fault_scratch) |scratch| {
            self.allocator.free(scratch);
            self.fault_scratch = null;
        }
        const handle = handle_mod.WorkerHandle.init(
            self.allocator,
            self.pid,
            self.pidfd,
            self.worker_init_fd,
            self.tmp_root.?,
            self.cgroup_dir.?,
            self.memory_limit_bytes,
            self.options.cpu_max_cores,
            self.metrics_fd,
            self.completion_eventfd,
            self.ingress_payload_fd,
            self.ingress_payload_credit_eventfd,
            self.ingress_payload.?,
            self.metrics.?,
            self.fs_fault_server_fd,
        ) catch return error.OutOfMemory;
        self.allocator.free(self.tmp_root.?);
        self.tmp_root = null;
        // The prepared fd rode the WorkerInit; the handle cleans by path.
        std.posix.close(self.cgroup_dir_fd);
        self.cgroup_dir_fd = -1;
        self.allocator.free(self.cgroup_dir.?);
        self.cgroup_dir = null;
        self.tmp_root_dir_fd = closeIfHeld(self.tmp_root_dir_fd);
        self.placeholder_fs_index_fd = closeIfHeld(self.placeholder_fs_index_fd);
        self.pidfd = -1;
        self.worker_init_fd = -1;
        self.metrics_fd = -1;
        self.completion_eventfd = -1;
        self.ingress_payload_fd = -1;
        self.ingress_payload_credit_eventfd = -1;
        self.metrics = null;
        self.ingress_payload = null;
        self.fs_fault_server_fd = -1;
        self.phase = .idle;
        return handle;
    }

    fn fail(self: *Machine, err: LaunchError, result: *StepResult) void {
        // The single funnel for every launch failure: without the phase and
        // the typed error here, a host only sees a dead worker with no story.
        std.log.warn("worker launch failed in phase={s}: {s}", .{ @tagName(self.phase), @errorName(err) });
        self.fail_reason = err;
        self.enter(.failed);
        result.push(.{ .report_failed = err });
    }

    fn faultScratch(self: *Machine) ![]u8 {
        if (self.fault_scratch) |scratch|
            return scratch;
        const scratch = try self.allocator.alloc(u8, ipc.max_message_bytes);
        self.fault_scratch = scratch;
        return scratch;
    }

    /// Releases everything the machine owns except the child's pidfd and its
    /// cgroup leaf, which the result hands to the caller: the init socket,
    /// the descriptors and mappings shared with the child, the bindings
    /// memfd, the fault scratch and the tmp root, whose directory the child
    /// sees only through its own mount namespace. Never signals, waits or
    /// retries, so an evented host calls it on its loop and leaves
    /// `AbandonedChild.reap` to a thread that may block. The machine is
    /// spent afterwards.
    pub fn abandon(self: *Machine) AbandonedChild {
        var child: AbandonedChild = .{ .pid = self.pid };
        if (self.pidfd >= 0) {
            child.pidfd = fd_mod.OwnedFd.fromRaw(self.pidfd);
            self.pidfd = -1;
        }
        if (self.cgroup_dir_fd >= 0) {
            child.cgroup_dir = fd_mod.OwnedFd.fromRaw(self.cgroup_dir_fd);
            self.cgroup_dir_fd = -1;
        }
        if (self.fault_scratch) |scratch| {
            self.allocator.free(scratch);
            self.fault_scratch = null;
        }
        if (self.metrics) |*metrics| metrics.deinit();
        self.metrics = null;
        if (self.ingress_payload) |*payload| payload.deinit();
        self.ingress_payload = null;
        self.worker_init_fd = closeIfHeld(self.worker_init_fd);
        self.route_bindings_memfd = closeIfHeld(self.route_bindings_memfd);
        self.metrics_fd = closeIfHeld(self.metrics_fd);
        self.completion_eventfd = closeIfHeld(self.completion_eventfd);
        self.ingress_payload_fd = closeIfHeld(self.ingress_payload_fd);
        self.ingress_payload_credit_eventfd = closeIfHeld(self.ingress_payload_credit_eventfd);
        self.placeholder_fs_index_fd = closeIfHeld(self.placeholder_fs_index_fd);
        self.fs_fault_server_fd = closeIfHeld(self.fs_fault_server_fd);
        self.fs_fault_worker_fd = closeIfHeld(self.fs_fault_worker_fd);
        self.tmp_root_dir_fd = closeIfHeld(self.tmp_root_dir_fd);
        if (self.tmp_root) |tmp_root| {
            std.fs.deleteTreeAbsolute(tmp_root) catch |err| switch (err) {
                error.FileNotFound => {},
                else => std.log.warn(
                    "failed to cleanup tmp_root '{s}': {s}",
                    .{ tmp_root, @errorName(err) },
                ),
            };
            self.allocator.free(tmp_root);
            self.tmp_root = null;
        }
        if (self.cgroup_dir) |dir| {
            self.allocator.free(dir);
            self.cgroup_dir = null;
        }
        return child;
    }

    /// Runs one bounded fault drain against the serve seam. Blocking on
    /// misses: evented mode calls this from its job, the sync driver inline.
    pub fn runFaultDrain(self: *Machine, deadline_ns: u64) !DrainOutcome {
        return switch (self.options.fault_serve) {
            .none => .peer_closed,
            .serve => |serve| drainFaultChannel(
                self.allocator,
                self.fs_fault_server_fd,
                deadline_ns,
                serve,
                &self.boot_faults_served,
                try self.faultScratch(),
            ),
        };
    }

    fn enter(self: *Machine, phase: LaunchPhase) void {
        self.phase = phase;
        self.phase_entered_ns = process.monotonicNowNsOrZero();
    }

    fn trace(self: *const Machine, event: []const u8) void {
        zygote.trace.traceEvent(self.zygote_process.trace_write_fd, event);
    }

    fn traceFmt(self: *const Machine, comptime fmt: []const u8, args: anytype) void {
        zygote.trace.traceEventFmt(self.zygote_process.trace_write_fd, fmt, args);
    }
};

/// Synchronous driver: the machine driven with poll(2) and direct calls, the
/// grace timer synthesized from the poll deadline. It blocks, so the caller
/// must own its thread, and a failure reaps the child before it returns.
pub fn runToReady(
    allocator: std.mem.Allocator,
    zygote_process: *zygote.host_client.SpawnedZygote,
    forked: *zygote.host_client.ForkedWorker,
    memory_limit_bytes: u64,
    options: LaunchOptions,
) LaunchError!handle_mod.WorkerHandle {
    var machine = Machine.init(allocator, zygote_process, memory_limit_bytes, options);
    var grace_deadline_ns: u64 = 0;
    var result = machine.start(forked);
    // Each turn consumes one step's effects. The ready wait ends by the
    // child window and the grace drain by its timer, so the loop is bounded
    // by those two deadlines and by the per-call cap of each fault drain.
    while (true) {
        const step = result;
        var drain_requested = false;
        for (step.effects[0..step.count]) |effect| switch (effect) {
            .report_ready => return takeReadyHandle(&machine),
            .report_failed => |err| return abandonFailed(&machine, err),
            .arm_grace_timer => |deadline_ns| grace_deadline_ns = deadline_ns,
            .start_fault_drain_job => drain_requested = true,
            // Polls are implicit in `pollNextEvent`.
            .none, .arm_init_poll, .arm_pidfd_poll, .arm_fault_poll => {},
        };
        const deadline_ns = switch (machine.phase) {
            .awaiting_ready => machine.child_init_deadline_abs_ns,
            .grace_drain => grace_deadline_ns,
            // Only the two waiting phases leave a step without a report.
            .idle, .ready, .failed => unreachable,
        };
        if (drain_requested) {
            const outcome = machine.runFaultDrain(deadline_ns) catch
                return abandonFailed(&machine, error.ZygoteProtocol);
            result = machine.onEvent(.{ .fault_drain_done = outcome });
            continue;
        }
        const event = pollNextEvent(&machine, deadline_ns) catch |err|
            return abandonFailed(&machine, err);
        result = machine.onEvent(event);
    }
}

fn takeReadyHandle(machine: *Machine) LaunchError!handle_mod.WorkerHandle {
    return machine.takeHandle() catch |err| return abandonFailed(machine, err);
}

fn abandonFailed(machine: *Machine, err: LaunchError) LaunchError {
    // A typed child failure announces its own exit: wait for the clean death
    // so the SIGKILL in `reap` finds nothing to kill.
    if (err == error.WorkerInitFailed and machine.pidfd >= 0)
        _ = process.waitForPidFdExit(machine.pidfd, process_limits.PROCESS_EXIT_WAIT_MS) catch false;
    var child = machine.abandon();
    child.reap();
    return err;
}

/// poll(2) leg of the sync driver: same fds, same priority (init POLLIN >
/// pidfd > init HUP > fault), same timeout mapping as the evented loop.
fn pollNextEvent(machine: *Machine, deadline_ns: u64) LaunchError!LaunchEvent {
    while (true) {
        const now_ns = process.monotonicNowNsOrZero();
        if (now_ns >= deadline_ns)
            return switch (machine.phase) {
                .grace_drain => .grace_expired,
                else => .child_deadline_expired,
            };
        var pollfds = [3]std.posix.pollfd{
            .{ .fd = machine.worker_init_fd, .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR, .revents = 0 },
            .{ .fd = machine.pidfd, .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR, .revents = 0 },
            .{ .fd = if (machine.serve_faults) machine.fs_fault_server_fd else -1, .events = std.posix.POLL.IN, .revents = 0 },
        };
        const remaining_ns = deadline_ns - now_ns;
        const remaining_ms: i32 = @intCast(@min(
            (remaining_ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms,
            @as(u64, std.math.maxInt(i32)),
        ));
        const ready = std.posix.poll(&pollfds, remaining_ms) catch
            return error.ZygoteProtocol;
        if (ready == 0)
            return switch (machine.phase) {
                .grace_drain => .grace_expired,
                else => .child_deadline_expired,
            };
        if (machine.phase == .grace_drain) {
            // Post-ready only the fault leg matters; init/pidfd noise belongs
            // to the host once the handle escapes.
            if ((pollfds[2].revents & std.posix.POLL.IN) != 0)
                return .fault_readable;
            return .grace_expired;
        }
        if ((pollfds[0].revents & std.posix.POLL.IN) != 0)
            return .init_readable;
        if ((pollfds[1].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0)
            return .pidfd_event;
        if ((pollfds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0)
            return .init_hup;
        if (machine.serve_faults and (pollfds[2].revents &
            (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0)
            return .fault_readable;
    }
}

/// Bounded drain of the boot-window fault channel: serves queued faults
/// until WouldBlock, the per-drain cap, the peer closing, or the deadline
/// passing. A fault request never carries fds, and a response carries
/// exactly one iff it is `.ok`. `served_faults` accumulates every request
/// answered across the whole boot window. Structural corruption errors out:
/// the launch fails this worker's init.
fn drainFaultChannel(
    allocator: std.mem.Allocator,
    fault_fd: std.posix.fd_t,
    deadline_ns: u64,
    serve: FaultServe.Serve,
    served_faults: *u32,
    scratch: []u8,
) !DrainOutcome {
    var drained_packets: usize = 0;
    while (true) {
        if (process.monotonicNowNsOrZero() >= deadline_ns)
            return .deadline_exhausted;
        if (drained_packets >= max_faults_per_drain)
            return .idle;
        var packet = ipc.recvPacketWithFdsScratch(allocator, fault_fd, scratch) catch |err| switch (err) {
            error.WouldBlock => return .idle,
            error.PeerClosed => return .peer_closed,
            else => return err,
        };
        defer packet.deinit();
        drained_packets += 1;
        if (packet.fd_count != 0)
            return error.UnexpectedFsFaultFd;
        var request = try ipc.fs_fault.decodeRequest(allocator, packet.bytes);
        defer request.deinit();
        const answer = serve.serve(serve.ctx, &request, deadline_ns);
        const status: ipc.FsFaultResponseStatus = switch (answer) {
            .ok => .ok,
            .refused => .refused,
            .not_found => .not_found,
            .fetch_failed => .fetch_failed,
        };
        var owned_file: fd_mod.OwnedFd = .{};
        defer owned_file.deinit();
        const file_ref: ?fd_mod.FdRef = switch (answer) {
            .ok => |fd| blk: {
                owned_file = fd_mod.OwnedFd.fromRaw(fd);
                break :blk owned_file.borrow();
            },
            else => null,
        };
        // Best-effort like every send to a worker: a dead peer surfaces on
        // the init and pidfd legs of the poll, not here.
        ipc.fs_fault.sendResponse(
            fault_fd,
            .{ .fault_id = request.fault_id, .status = status },
            file_ref,
        ) catch |err| {
            std.log.warn("boot fault response failed fault_id={d}: {s}", .{ request.fault_id, @errorName(err) });
        };
        served_faults.* +|= 1;
    }
}

fn closeIfHeld(fd: std.posix.fd_t) std.posix.fd_t {
    if (fd >= 0)
        std.posix.close(fd);
    return -1;
}

fn mapResourceError(err: anyerror) LaunchError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ZygoteProtocol,
    };
}

fn spanDelta(cursor_ns: *u64) u64 {
    const now_ns = process.monotonicNowNsOrZero();
    const delta = now_ns -| cursor_ns.*;
    cursor_ns.* = now_ns;
    return delta;
}

fn zygoteProtocolError(err: anyerror) LaunchError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ZygoteProtocol,
    };
}

fn resolveTmpfsSizeBytes(memory_limit_bytes: u64, configured_bytes: ?u64) u64 {
    if (configured_bytes) |bytes| {
        if (bytes != 0)
            return @min(bytes, memory_limit_bytes);
    }
    return ipc.WorkerInit.defaultTmpfsSizeBytes(memory_limit_bytes);
}

fn makeTmpRoot(allocator: std.mem.Allocator, pid: u32) ![]u8 {
    var suffix: [TMP_ROOT_RANDOM_SUFFIX_BYTES]u8 = undefined;
    std.crypto.random.bytes(&suffix);
    const suffix_hex = std.fmt.bytesToHex(suffix, .lower);
    return std.fmt.allocPrint(allocator, "/tmp/collo-{d}-{s}", .{ pid, suffix_hex });
}

fn createTmpRoot(path: []const u8) !void {
    // The path carries a cryptographically random suffix, and creation is
    // still exclusive so a pre-created path or symlink never becomes a
    // worker tmp.
    try std.posix.mkdir(path, WORKER_TMP_ROOT_MODE);
}

fn openValidatedTmpRoot(path: []const u8) !std.fs.Dir {
    var dir = try std.fs.openDirAbsolute(path, .{ .no_follow = true });
    errdefer dir.close();
    const stat = try std.posix.fstat(dir.fd);
    if ((stat.mode & 0o7777) != WORKER_TMP_ROOT_MODE)
        return error.InvalidWorkerTmpRootMode;
    if (stat.uid != std.os.linux.getuid())
        return error.InvalidWorkerTmpRootOwner;
    return dir;
}

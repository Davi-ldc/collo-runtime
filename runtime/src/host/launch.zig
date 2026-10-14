//! The WorkerInit handoff as a machine: from a forked child to a ready
//! worker, or to a typed failure that hands the child back to its caller.
//!
//! A launch runs in three calls. `init` takes the cgroup leaf the host made
//! for the fork. `prepare` runs the local steps, the state page, the payload
//! ring and their eventfds, which need no child, so the host runs them while
//! the zygote clones. `start` takes the forked child and sends WorkerInit,
//! and the machine then waits for the child's answer. The wait belongs to the
//! host: an evented host (the server's launcher,
//! `server/supervisor/launcher.zig`) polls the init socket and the pidfd
//! among its own descriptors and feeds `onEvent`, and the synchronous driver
//! `runToReady` drives the same machine with poll(2).
//!
//! The definition's artifact and the worker's egress descriptors ride
//! WorkerInit itself: a launch for a definition without a network grant sends
//! no egress descriptor, every other launch sends the worker's wake
//! descriptors, and a launch with an egress session, which the host attaches
//! before it starts the launch, sends the session's regions too
//! (`LaunchEgress`). The boot token for the session is minted here, when
//! WorkerInit is sent, because its deadline derives from the child window
//! this file fixes. A granted launch without a session boots its child
//! detached.
//!
//! The leaf is named by the root's workers directory and the fork job id
//! (`cgroup_root.WorkerLeaf`). Its descriptor lives only until WorkerInit
//! carries it, and the launch never reads the leaf's limits back: the host
//! wrote them, the zygote refused anything but an empty cgroup2 directory,
//! and the child checks its own membership and limits. The one file the
//! launch reads is `memory.events.local`, by name, for a child that ended
//! without a report (`Machine.endedCause`).
//!
//! A launch that fails neither kills, waits nor removes a cgroup on the
//! host's thread: `abandon` releases what the machine holds and hands the
//! child's pidfd, its cgroup leaf and its state page back as an
//! `AbandonedChild`, whose `kill` and `release` do the blocking part on
//! whichever thread may block. The page goes with them because a child that
//! got WorkerInit logs into its console ring from its sink's install on, its
//! boot failure included, and the ring holds all of it only once the child
//! is dead.
//!
//! Clock contract: the child window ends `WORKER_INIT_TIMEOUT_MS` after the
//! send, fixed when WorkerInit is sent and carried in it as the init
//! deadline; the boot token's deadline adds `MODULE_EVAL_BUDGET_NS` to it
//! (`bootEgressDeadline`). Neither changes after, and the local steps before
//! the send never spend the child's window.
//!
//! One thread drives a machine: the launcher's, or the thread of a harness
//! or benchmark that owns it.

const std = @import("std");
const ipc = @import("collo_ipc");
const cgroup = @import("collo_cgroup");
const fd_mod = @import("collo_os").fd;
const process = @import("collo_os").process;
const process_limits = @import("collo_limits").process;
const worker_shared_page = @import("collo_worker_state").page;
const zygote = @import("collo_zygote");

const cgroup_root = @import("cgroup_root.zig");
const handle_mod = @import("handle.zig");

pub const LaunchError = error{
    /// The host could not create or map what it shares with the worker (the
    /// state page, the payload ring and their eventfds), or `runToReady`
    /// could not poll for the child's answer, for want of memory or
    /// descriptors.
    LaunchResourcesUnavailable,
    /// A detached launch could not open the worker's wake descriptors from
    /// its wake set (`ipc.egress_shared.WakeSet.openWorkerWake`), for want of
    /// descriptors.
    EgressWakeUnavailable,
    WorkerInitTimeout,
    /// The child reported an init failure, or ended before `WorkerReady`,
    /// which the WorkerInit send finds too when the child's end of the init
    /// socket is already closed; `Machine.init_failure` says which.
    WorkerInitFailed,
    /// The fork reply came without the child's descriptors, WorkerInit could
    /// not be sent for any reason but the child's end, or the child's answer
    /// broke the protocol.
    ZygoteProtocol,
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

/// What the boot token of a launch with an egress grant carries besides its
/// deadline, which `bootEgressDeadline` derives from the child window this
/// launch fixes when it sends WorkerInit. The machine mints the token from
/// the caller's copy and keeps none, so the caller scrubs the key.
pub const BootEgress = struct {
    key: ipc.egress_token.Key,
    session_id: u64,
    policy_id: u16,
};

/// The egress descriptors a launch sends with WorkerInit: none for a
/// definition without a network grant, else the worker's wake descriptors,
/// and with a session its regions beside the boot token, the pairing
/// `ipc.zygote_worker` requires.
pub const LaunchEgress = union(enum) {
    /// The definition has no network grant: WorkerInit carries no egress
    /// descriptor and leaves `flag_egress` clear, and the worker can never
    /// be attached to a gateway.
    none,
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

/// The routes a worker serves: its definition's sealed artifact
/// (`ipc.module_pack`), which holds every route with its bindings and every
/// module they reach, built once per definition (`server/routes/artifacts.zig`)
/// and borrowed for the length of `start`. The child evaluates every route's
/// entry before it reports ready, and builds each route's `env` from the
/// route's own bindings, never from `process.env`.
pub const LaunchRoutes = struct {
    module_pack_fd: std.posix.fd_t,
    /// Each route runs in a realm of its own (`WorkerInit.flag_isolate_realm`).
    isolate_realm: bool,
};

pub const LaunchOptions = struct {
    /// The memory limit the leaf was created with, which WorkerInit carries
    /// for the child's check of its own leaf.
    memory_limit_bytes: u64,
    /// What the worker gets to reach the egress gateway with.
    egress: LaunchEgress,
    routes: LaunchRoutes,
    /// null = `WorkerInit.defaultTmpfsSizeBytes(memory_limit_bytes)`; any
    /// other value is clamped to the memory limit.
    tmpfs_size_bytes: ?u64 = null,
    /// The worker stamps its first handler call on its page for the
    /// cold-start benchmark (`WorkerInit.flag_bench_handler`).
    bench_handler: bool = false,
    /// The CPU each request of the worker may spend, 0 for no budget
    /// (`WorkerInit.request_cpu_budget_ns`).
    request_cpu_budget_ns: u64 = 0,
    /// The wall time JavaScript no request owns may run at a stretch in the
    /// worker (`WorkerInit.unowned_time_limit_ns`); a server passes its
    /// definition's request timeout.
    unowned_time_limit_ns: u64 = ipc.WorkerInit.default_unowned_time_limit_ns,
};

pub const LaunchPhase = enum(u8) {
    /// From `init` until WorkerInit is sent: the machine holds the leaf, and
    /// after `prepare` what it shares with the worker.
    preparing,
    /// WorkerInit sent; `onEvent` consumes the init socket's and the pidfd's
    /// events until the child window closes.
    awaiting_ready,
    ready,
    failed,
};

/// The events of the ready wait a host feeds `onEvent`. `runToReady`
/// synthesizes the same events from poll(2) revents.
pub const LaunchEvent = enum {
    init_readable,
    init_hup,
    pidfd_event,
    child_deadline_expired,
};

/// How the ready wait ended.
pub const Outcome = union(enum) {
    ready,
    failed: LaunchError,
};

/// What a launch that gave up leaves of its child: the pidfd, owned and unset
/// when no child was forked; the cgroup leaf it was born in, null when the
/// launch never had one; and the state page the launch mapped, null when it
/// mapped none. `reap`, or `kill` then `release`, releases all three.
pub const AbandonedChild = struct {
    pid: u32 = 0,
    pidfd: fd_mod.OwnedFd = .{},
    leaf: ?cgroup_root.WorkerLeaf = null,
    /// Holds the console ring of a child that got WorkerInit, into which it
    /// logs from its sink's install on, its `worker boot failed` line
    /// included. Tenant code may have run by then, so every line is hostile:
    /// a host that drains the ring does it through the ring's checked reads,
    /// and only after `kill`, once nothing writes the ring.
    page: ?worker_shared_page.HostReaderView = null,

    /// Kills the child through its pidfd and waits for its exit up to
    /// `PROCESS_EXIT_WAIT_MS`. Returns false when the exit went unseen, and
    /// the child may then still write its page. A launch that forked no
    /// child has nothing to kill. Blocks, so only a thread that may wait
    /// calls it.
    pub fn kill(self: *AbandonedChild) bool {
        if (!self.pidfd.isValid())
            return true;
        process.pidFdSendSignal(self.pidfd.fd(), std.posix.SIG.KILL) catch |err| switch (err) {
            error.ProcessNotFound => {},
            else => std.log.warn("failed to SIGKILL an abandoned worker pid={d}: {s}", .{ self.pid, @errorName(err) }),
        };
        const exited = process.waitForPidFdExit(self.pidfd.fd(), process_limits.PROCESS_EXIT_WAIT_MS) catch |err| blk: {
            std.log.warn("failed to wait for an abandoned worker pid={d}: {s}", .{ self.pid, @errorName(err) });
            break :blk false;
        };
        // `release` removes the leaf all the same, killing any member again.
        if (!exited)
            std.log.warn("abandoned worker pid={d} did not report its exit; removing its cgroup leaf anyway", .{self.pid});
        return exited;
    }

    /// Unmaps the page, removes the cgroup leaf by name (`WorkerLeaf.remove`)
    /// and closes the pidfd. A leaf with a member refuses rmdir, so `kill`
    /// runs first. Blocks on the leaf's removal.
    pub fn release(self: *AbandonedChild) void {
        if (self.page) |*page|
            page.deinit();
        self.page = null;
        if (self.leaf) |leaf|
            leaf.remove();
        self.leaf = null;
        self.pidfd.deinit();
    }

    /// `kill`, then `release`, for a host that keeps nothing the child
    /// logged into its page.
    pub fn reap(self: *AbandonedChild) void {
        _ = self.kill();
        self.release();
    }
};

pub const Machine = struct {
    /// The zygote's trace write end, borrowed for the machine's life; null
    /// without tracing (`zygote/trace.zig`).
    trace_fd: ?std.posix.fd_t,
    /// The leaf the child is born in; null once `takeHandle` or `abandon`
    /// handed it on.
    leaf: ?cgroup_root.WorkerLeaf,
    /// The leaf's directory, owned from `init` until WorkerInit carries it.
    /// The host borrows it for the fork request (CLONE_INTO_CGROUP).
    leaf_fd: std.posix.fd_t,

    phase: LaunchPhase = .preparing,
    child_init_deadline_abs_ns: u64 = 0,
    /// The boot token's deadline, fixed with the child window; 0 for a
    /// launch that mints no token.
    boot_egress_deadline_abs_ns: u64 = 0,
    /// CLOCK_MONOTONIC right after WorkerReady was read.
    ready_received_ns: u64 = 0,

    // The child, taken from the fork reply by `start`.
    pid: u32 = 0,
    pidfd: std.posix.fd_t = -1,
    worker_init_fd: std.posix.fd_t = -1,

    // What the worker shares with the host, made by `prepare`. The two
    // memfds live until WorkerInit carries them, since the mappings keep what
    // the host needs; the mappings and eventfds until the handle takes them.
    metrics_fd: std.posix.fd_t = -1,
    completion_eventfd: std.posix.fd_t = -1,
    ingress_payload_fd: std.posix.fd_t = -1,
    ingress_payload_credit_eventfd: std.posix.fd_t = -1,
    metrics: ?worker_shared_page.HostReaderView = null,
    ingress_payload: ?ipc.ingress_channel.SharedPayloadView = null,

    fail_reason: ?LaunchError = null,
    /// Set when the launch failed with `error.WorkerInitFailed`.
    init_failure: ?InitFailure = null,

    /// A launch whose child is born in `leaf`. The machine owns `leaf_fd`,
    /// that leaf's directory, from here on, whatever the outcome.
    pub fn init(leaf: cgroup_root.WorkerLeaf, leaf_fd: std.posix.fd_t, trace_fd: ?std.posix.fd_t) Machine {
        std.debug.assert(leaf_fd >= 0);
        return .{
            .trace_fd = trace_fd,
            .leaf = leaf,
            .leaf_fd = leaf_fd,
        };
    }

    /// Creates and maps what the worker shares with the host: the state
    /// page, the payload ring and their two eventfds. Call once, before
    /// `start`. A failure fails the machine and `start` reports it, since a
    /// fork request already sent must still have its reply read and its
    /// child handed back.
    pub fn prepare(self: *Machine) void {
        std.debug.assert(self.phase == .preparing);
        std.debug.assert(self.metrics == null);
        self.createShared() catch |err| return self.fail(err);
        self.trace("host.metrics.created");
    }

    /// The page's memfd comes with its header written, state `forked` and
    /// reason `crash` (`worker_shared_page.createMemfd`), so a child that
    /// dies before it stores a state of its own reads as crashed.
    fn createShared(self: *Machine) LaunchError!void {
        const eventfd_flags = std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK;
        self.metrics_fd = worker_shared_page.createMemfd("collo-shared-metrics") catch
            return error.LaunchResourcesUnavailable;
        self.completion_eventfd = std.posix.eventfd(0, eventfd_flags) catch
            return error.LaunchResourcesUnavailable;
        self.ingress_payload_fd = ipc.ingress_channel.createSharedPayloadMemfd() catch
            return error.LaunchResourcesUnavailable;
        self.ingress_payload_credit_eventfd = std.posix.eventfd(0, eventfd_flags) catch
            return error.LaunchResourcesUnavailable;
        self.metrics = worker_shared_page.mapHostReader(self.metrics_fd) catch
            return error.LaunchResourcesUnavailable;
        self.ingress_payload = ipc.ingress_channel.mapSharedPayloadReadWrite(self.ingress_payload_fd, .server) catch
            return error.LaunchResourcesUnavailable;
    }

    /// Takes every descriptor `forked` holds, so `forked` is empty whatever
    /// the outcome, and sends WorkerInit; the machine then waits for the
    /// child's answer (`onEvent`). Fails with the failure `prepare` kept or
    /// with its own, and the host then calls `abandon`. The key in
    /// `options.egress` stays the caller's to scrub.
    pub fn start(
        self: *Machine,
        forked: *zygote.host_client.ForkedWorker,
        options: *const LaunchOptions,
    ) LaunchError!void {
        self.takeChild(forked);
        if (self.fail_reason) |err|
            return err;
        std.debug.assert(self.phase == .preparing);
        std.debug.assert(self.metrics != null);
        if (self.worker_init_fd < 0)
            return self.failWithError(error.ZygoteProtocol);
        if (self.pidfd < 0)
            return self.failWithError(error.ZygoteProtocol);
        self.sendWorkerInit(options) catch |err| switch (err) {
            // The zygote closed its copy of the child's end after the clone,
            // and the child holds that end until it exits, so a send that
            // finds it closed meets the child's exit, as a receive does
            // (`finishInitOutcome`).
            error.PeerClosed => return self.failChildEnded(),
            else => |launch_err| return self.failWithError(launch_err),
        };
        self.phase = .awaiting_ready;
    }

    fn takeChild(self: *Machine, forked: *zygote.host_client.ForkedWorker) void {
        self.pid = forked.pid;
        // The pidfd is the kernel's handle on this child, from the clone
        // itself (CLONE_PIDFD) and passed over SCM_RIGHTS; it is never
        // derived from the pid, which the kernel reuses.
        if (forked.pidfd) |fd| {
            self.pidfd = fd;
            forked.pidfd = null;
        }
        if (forked.worker_init_fd) |fd| {
            self.worker_init_fd = fd;
            forked.worker_init_fd = null;
        }
    }

    /// Sends WorkerInit with its descriptors and fixes the child window at
    /// the send, so the steps before it never spend the child's window. The
    /// boot token is minted here too, with the deadline `bootEgressDeadline`
    /// derives from that window. Once the child holds its own copies, the
    /// leaf's descriptor and the two memfds close, and a detached launch's
    /// wake descriptors with them. `error.PeerClosed` is a send that found
    /// the child's end of the init socket closed; any other failure of the
    /// send is `error.ZygoteProtocol`.
    fn sendWorkerInit(self: *Machine, options: *const LaunchOptions) (LaunchError || error{PeerClosed})!void {
        const send_ns = process.monotonicNowNsOrZero();
        self.child_init_deadline_abs_ns = send_ns +
            @as(u64, @intCast(process_limits.WORKER_INIT_TIMEOUT_MS)) * std.time.ns_per_ms;

        var detached_wake: ipc.egress_shared.WakeFds = .{};
        defer detached_wake.close();
        // This is the one switch on `options.egress`, and it captures by
        // pointer: a switch that loads the union by value copies an attached
        // payload, key included, into this frame in an unoptimized build.
        var attached: ?*const LaunchEgress.Attached = null;
        // The sender sets `flag_egress` exactly when the set holds the wake
        // descriptors, so an empty set leaves the child without any.
        const egress_fds: ipc.egress_shared.RawFds = switch (options.egress) {
            .none => .{},
            .detached => |*wake_set| blk: {
                detached_wake = wake_set.*.openWorkerWake() catch return error.EgressWakeUnavailable;
                break :blk ipc.egress_shared.RawFds.wakeOnly(detached_wake);
            },
            .attached => |*payload| blk: {
                attached = payload;
                break :blk payload.shared_fds;
            },
        };
        self.boot_egress_deadline_abs_ns = if (attached != null)
            bootEgressDeadline(self.child_init_deadline_abs_ns)
        else
            0;
        var message = ipc.WorkerInit.init(options.memory_limit_bytes);
        message.tmpfs_size_bytes = resolveTmpfsSizeBytes(options.memory_limit_bytes, options.tmpfs_size_bytes);
        message.init_deadline_mono_ns = self.child_init_deadline_abs_ns;
        message.request_cpu_budget_ns = options.request_cpu_budget_ns;
        message.unowned_time_limit_ns = options.unowned_time_limit_ns;
        message.boot_egress_token = if (attached) |payload|
            mintBootToken(&payload.boot, self.boot_egress_deadline_abs_ns)
        else
            ipc.egress_token.none;
        if (options.routes.isolate_realm)
            message.flags |= ipc.WorkerInit.flag_isolate_realm;
        if (options.bench_handler)
            message.flags |= ipc.WorkerInit.flag_bench_handler;
        ipc.zygote_worker.sendWorkerInit(self.worker_init_fd, &message, .{
            .metrics_fd = self.metrics_fd,
            .completion_eventfd = self.completion_eventfd,
            .ingress_payload_fd = self.ingress_payload_fd,
            .ingress_payload_credit_eventfd = self.ingress_payload_credit_eventfd,
            .cgroup_dir_fd = self.leaf_fd,
            .egress_shared_fds = egress_fds,
            .module_pack_fd = options.routes.module_pack_fd,
        }) catch |err| switch (err) {
            error.PeerClosed => return error.PeerClosed,
            else => return error.ZygoteProtocol,
        };
        self.trace("host.worker_init.sent");

        self.leaf_fd = closeIfHeld(self.leaf_fd);
        self.metrics_fd = closeIfHeld(self.metrics_fd);
        self.ingress_payload_fd = closeIfHeld(self.ingress_payload_fd);
    }

    /// The boot token for `boot`'s session, admitting nothing from
    /// `deadline_abs_ns` on.
    fn mintBootToken(boot: *const BootEgress, deadline_abs_ns: u64) ipc.egress_token.Bytes {
        const token = ipc.egress_token.mint(&boot.key, .{
            .kind = .boot,
            .policy_id = boot.policy_id,
            .session_id = boot.session_id,
            .request_id = 0,
            .request_generation = 0,
            .deadline_monotonic_ns = deadline_abs_ns,
        });
        return ipc.egress_token.asBytes(&token).*;
    }

    /// The ready wait, one event at a time. Every event of the wait ends it,
    /// so the result is null only outside the wait, where an event belongs to
    /// whoever holds the worker and changes nothing. When several descriptors
    /// are ready the host feeds init POLLIN first, then the pidfd, then init
    /// HUP or ERR: a child's exit hangs its init socket up no later than its
    /// pidfd turns readable, and a queued outcome names the failure.
    pub fn onEvent(self: *Machine, event: LaunchEvent) ?Outcome {
        if (self.phase != .awaiting_ready)
            return null;
        return switch (event) {
            // A socket that hung up still has its queued outcome read.
            .init_readable, .init_hup => self.finishInitOutcome(),
            .pidfd_event => .{ .failed = self.failChildEnded() },
            .child_deadline_expired => blk: {
                self.trace("host.worker_init.timeout");
                break :blk self.failWait(error.WorkerInitTimeout);
            },
        };
    }

    fn finishInitOutcome(self: *Machine) Outcome {
        const outcome = zygote.host_client.receiveWorkerInitOutcome(self.worker_init_fd) catch |err| switch (err) {
            // The child holds its end of the init socket until it exits, so
            // a socket that ends without an outcome is the child's exit.
            error.PeerClosed => return .{ .failed = self.failChildEnded() },
            else => return self.failWait(error.ZygoteProtocol),
        };
        switch (outcome) {
            .ready => {
                self.ready_received_ns = process.monotonicNowNsOrZero();
                self.phase = .ready;
                return .ready;
            },
            .failed => |reason| {
                self.traceFmt("host.worker_init.failed={s}", .{@tagName(reason)});
                return .{ .failed = self.failInit(.{ .reported = reason }) };
            },
        }
    }

    /// Fails the launch of a child that ended before `WorkerReady` without a
    /// report, for the cause its page and its leaf name.
    fn failChildEnded(self: *Machine) LaunchError {
        const cause = self.endedCause();
        self.traceFmt("host.worker_init.worker_exited={s}", .{@tagName(cause)});
        return self.failInit(cause);
    }

    fn failInit(self: *Machine, cause: InitFailure) LaunchError {
        self.init_failure = cause;
        return self.failWithError(error.WorkerInitFailed);
    }

    /// Why a child that ended without a report ended, by the rule the server
    /// applies to a published worker's death (`Record.classifyDeath` in
    /// `server/supervisor/worker_table.zig`): for memory when its page says
    /// its sentinel ended it for memory or its leaf counted a kernel OOM
    /// kill, which both land before the child's exit hangs its init socket
    /// up, and a crash otherwise. A page or a leaf it cannot read names no
    /// memory.
    fn endedCause(self: *const Machine) InitFailure {
        if (self.metrics) |*metrics| {
            // A reason outside `TerminationReason` names no memory.
            if (metrics.loadLifecycle().knownTerminationReason()) |reason| {
                if (reason == .memory)
                    return .memory;
            }
        }
        const leaf = self.leaf orelse return .crash;
        const events_fd = leaf.openFile("memory.events.local") catch |err| {
            std.log.warn("worker launch: memory.events.local of a child that ended could not be opened: {s}", .{
                @errorName(err),
            });
            return .crash;
        };
        defer std.posix.close(events_fd);
        const events = cgroup.memory.readEvents(events_fd) catch |err| {
            std.log.warn("worker launch: memory.events.local of a child that ended could not be read: {s}", .{
                @errorName(err),
            });
            return .crash;
        };
        if (events.oom_kill > 0)
            return .memory;
        return .crash;
    }

    /// Hands the ready worker over: the handle owns every descriptor and
    /// mapping the machine still held, the leaf included, and the machine is
    /// spent. Call only in `.ready`.
    pub fn takeHandle(self: *Machine) handle_mod.WorkerHandle {
        std.debug.assert(self.phase == .ready);
        // WorkerInit carried these, and the send closed the host's copies.
        std.debug.assert(self.leaf_fd == -1);
        std.debug.assert(self.metrics_fd == -1);
        std.debug.assert(self.ingress_payload_fd == -1);
        const handle: handle_mod.WorkerHandle = .{
            .pid = self.pid,
            .pidfd = self.pidfd,
            .control_fd = self.worker_init_fd,
            .leaf = self.leaf.?,
            .completion_eventfd = self.completion_eventfd,
            .ingress_payload_credit_eventfd = self.ingress_payload_credit_eventfd,
            .ingress_payload = self.ingress_payload.?,
            .metrics = self.metrics.?,
        };
        self.leaf = null;
        self.pidfd = -1;
        self.worker_init_fd = -1;
        self.completion_eventfd = -1;
        self.ingress_payload_credit_eventfd = -1;
        self.metrics = null;
        self.ingress_payload = null;
        return handle;
    }

    /// Releases everything the machine owns except the child's pidfd, its
    /// cgroup leaf and the state page, which the result hands to the caller:
    /// the init socket, the leaf's descriptor, the payload ring and the
    /// eventfds. Never signals, waits or retries, so an evented host calls it
    /// on its loop and leaves the result to a thread that may block. The
    /// machine is spent afterwards.
    pub fn abandon(self: *Machine) AbandonedChild {
        var child: AbandonedChild = .{ .pid = self.pid, .leaf = self.leaf, .page = self.metrics };
        self.leaf = null;
        self.metrics = null;
        if (self.pidfd >= 0) {
            child.pidfd = fd_mod.OwnedFd.fromRaw(self.pidfd);
            self.pidfd = -1;
        }
        if (self.ingress_payload) |*payload| payload.deinit();
        self.ingress_payload = null;
        self.worker_init_fd = closeIfHeld(self.worker_init_fd);
        self.leaf_fd = closeIfHeld(self.leaf_fd);
        self.metrics_fd = closeIfHeld(self.metrics_fd);
        self.completion_eventfd = closeIfHeld(self.completion_eventfd);
        self.ingress_payload_fd = closeIfHeld(self.ingress_payload_fd);
        self.ingress_payload_credit_eventfd = closeIfHeld(self.ingress_payload_credit_eventfd);
        return child;
    }

    /// The single funnel for every launch failure: without the phase and the
    /// typed error here, a host only sees a dead worker with no story.
    fn fail(self: *Machine, err: LaunchError) void {
        std.log.warn("worker launch failed in phase={s}: {s}", .{ @tagName(self.phase), @errorName(err) });
        self.fail_reason = err;
        self.phase = .failed;
    }

    fn failWithError(self: *Machine, err: LaunchError) LaunchError {
        self.fail(err);
        return err;
    }

    fn failWait(self: *Machine, err: LaunchError) Outcome {
        self.fail(err);
        return .{ .failed = err };
    }

    fn trace(self: *const Machine, event: []const u8) void {
        zygote.trace.traceEvent(self.trace_fd, event);
    }

    fn traceFmt(self: *const Machine, comptime fmt: []const u8, args: anytype) void {
        zygote.trace.traceEventFmt(self.trace_fd, fmt, args);
    }
};

/// Synchronous driver for a host that owns its thread: the local steps,
/// WorkerInit and the ready wait, driven with poll(2) for a child already
/// forked into `machine`'s leaf. It blocks, and a failure reaps the child,
/// unmaps its page with whatever the child logged there and removes the leaf
/// before it returns; the machine is spent either way.
pub fn runToReady(
    machine: *Machine,
    forked: *zygote.host_client.ForkedWorker,
    options: *const LaunchOptions,
) LaunchError!handle_mod.WorkerHandle {
    machine.prepare();
    machine.start(forked, options) catch |err| return abandonFailed(machine, err);
    // Every event of the wait ends it, and `pollNextEvent` returns by the
    // child window at the latest, so this runs once.
    while (true) {
        const event = pollNextEvent(machine) catch |err| return abandonFailed(machine, err);
        const outcome = machine.onEvent(event) orelse continue;
        switch (outcome) {
            .ready => return machine.takeHandle(),
            .failed => |err| return abandonFailed(machine, err),
        }
    }
}

fn abandonFailed(machine: *Machine, err: LaunchError) LaunchError {
    // A child that reported its failure exits on its own: waiting for that
    // clean death leaves the SIGKILL in `reap` nothing to kill.
    if (err == error.WorkerInitFailed and machine.pidfd >= 0)
        _ = process.waitForPidFdExit(machine.pidfd, process_limits.PROCESS_EXIT_WAIT_MS) catch false;
    var child = machine.abandon();
    child.reap();
    return err;
}

/// The poll(2) leg of `runToReady`: the same descriptors and priority as the
/// launcher's poll set (init POLLIN, then the pidfd, then init HUP or ERR),
/// waiting no later than the child window. Each turn returns or waits, and a
/// turn whose revents name none of the three waits again, so the loop ends by
/// the window at the latest.
fn pollNextEvent(machine: *const Machine) LaunchError!LaunchEvent {
    const ready_events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR;
    while (true) {
        const now_ns = process.monotonicNowNsOrZero();
        if (now_ns >= machine.child_init_deadline_abs_ns)
            return .child_deadline_expired;
        var pollfds = [2]std.posix.pollfd{
            .{ .fd = machine.worker_init_fd, .events = ready_events, .revents = 0 },
            .{ .fd = machine.pidfd, .events = ready_events, .revents = 0 },
        };
        const remaining_ns = machine.child_init_deadline_abs_ns - now_ns;
        // The divisor is a nonzero constant.
        const remaining_ms = std.math.divCeil(u64, remaining_ns, std.time.ns_per_ms) catch unreachable;
        const ready = std.posix.poll(&pollfds, @intCast(@min(remaining_ms, std.math.maxInt(i32)))) catch
            return error.LaunchResourcesUnavailable;
        if (ready == 0)
            return .child_deadline_expired;
        if ((pollfds[0].revents & std.posix.POLL.IN) != 0)
            return .init_readable;
        if ((pollfds[1].revents & ready_events) != 0)
            return .pidfd_event;
        if ((pollfds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0)
            return .init_hup;
    }
}

/// The boot token's deadline: the init deadline plus `MODULE_EVAL_BUDGET_NS`.
/// Every route the boot evaluates ends its synchronous part before the init
/// deadline and its pending budget runs from there, so the token outlives
/// every startup evaluation; workers share the host's CLOCK_MONOTONIC.
pub fn bootEgressDeadline(init_deadline_abs_ns: u64) u64 {
    return init_deadline_abs_ns +| process_limits.MODULE_EVAL_BUDGET_NS;
}

fn closeIfHeld(fd: std.posix.fd_t) std.posix.fd_t {
    if (fd >= 0)
        std.posix.close(fd);
    return -1;
}

fn resolveTmpfsSizeBytes(memory_limit_bytes: u64, configured_bytes: ?u64) u64 {
    if (configured_bytes) |bytes| {
        if (bytes != 0)
            return @min(bytes, memory_limit_bytes);
    }
    return ipc.WorkerInit.defaultTmpfsSizeBytes(memory_limit_bytes);
}

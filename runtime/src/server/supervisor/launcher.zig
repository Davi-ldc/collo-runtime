//! The launcher: the node's one thread that turns a pool's claim for a worker
//! into a published worker, and that attaches live workers to a new egress
//! gateway when the one they had is lost. A cold start is fork, launch,
//! deliver. For each launch the launcher creates the worker's egress wake set
//! and its cgroup leaf, attaches its egress session when its definition has a
//! grant (`worker_factory.zig`), runs the fork RPC, sends `WorkerInit` and
//! waits for `WorkerReady` in one `poll` set over every launch in flight,
//! then hands the ready worker to `Deps.publish`, whose pool handoffs carry
//! its slots to the lanes of the waiting requests. The zygote serves one fork
//! at a time on one thread, so a single launcher thread loses no fork
//! throughput. One fork request at most is outstanding, and a claimed launch
//! waits for its turn holding no leaf and no session.
//!
//! The launcher never kills a worker, waits for an exit or removes a cgroup:
//! a failed launch goes to `Deps.failed` with its reason and what the child
//! left (`Leftovers`), a live worker whose new session the gateway refuses or
//! its control socket does not take goes to `Deps.retireForEgress`, and the
//! reaper does the rest. Besides its `poll`,
//! bounded by `fork_reply_timeout_ms`, `child_window_ms` and
//! `egress_attach_send_timeout_ms`, it waits only inside the gateway calls of
//! `Deps`: an attach round trip (`Deps.attachEgress`) or a gateway spawn
//! (`Deps.egressPrewarm`). Neither runs while a fork request is outstanding,
//! because a thread blocked past a fork reply's deadline fails that fork as
//! `fork_reply_timeout`, which kills the zygote and stops the server. The one
//! signal it sends is SIGKILL to a zygote that missed a fork reply or lost
//! its control socket, so that the zygote's death, which stops the server, is
//! the only failure left (`killUnresponsiveZygote` in
//! `zygote/host_client.zig`).
//!
//! Every session of a worker is built on its wake set
//! (`ipc.egress_shared.WakeSet`), because the worker's io_uring registers the
//! set's completion eventfd and liveness pipe at boot and no other file
//! afterwards. The launch's set goes to the worker's record at the publish,
//! which keeps it for the worker's life.
//!
//! A gateway loss (`gatewayLost`) starts a reattach pass on the launcher
//! thread: a gateway spawn, then one live worker per turn, each of a
//! definition with a grant and without a session of the current gateway. The
//! worker gets a new session on its wake set (`Deps.attachEgress`), its record
//! takes it (`Deps.setWorkerEgress`), and then the worker gets the session's
//! worker half on its control socket (`egress_attach`); the record changes
//! first so that no token minted after the worker attached names the old
//! session. A gateway that fails under an attach leaves the worker detached on
//! its old session and starts the pass over. A session the current gateway
//! removed on its own (`egressSessionLost`) leaves its worker detached as
//! well: the launcher takes the worker's record off the session
//! (`Deps.dropEgressSession`) and starts the pass over, which attaches it
//! again. A launch whose session's gateway is gone, or whose session was
//! removed, by `WorkerReady` takes the same steps before it publishes.
//!
//! After a loss, gateways spawn only in the pass, at least
//! `egress_prewarm_interval_ms` apart. An attach spawns a gateway when none is
//! current, so an attach that fails under the gateway, the first launch's
//! included, counts as a spawn of the pass's own and starts the interval too.
//! While the pass waits to spawn one, a launch boots its child detached
//! instead of attaching, as it does when its attach fails for any reason but
//! the gateway's refusal of the session, and the pass attaches the worker
//! after its publish. A gateway that dies at every attach therefore costs one
//! spawn per interval, and a worker whose session keeps being removed costs
//! one attach per interval.
//!
//! Growth follows the pools. A submit names a definition, and the launcher
//! claims launches for it while its pool wants them (`Deps.claim`), and again
//! after each worker of it publishes, since waiters the new worker could not
//! serve submit nothing more. A failure starts no launch by itself: a
//! definition whose boot always fails then waits for the next request to try
//! again. Launches whose leftovers the reaper has not torn down count against
//! the launch table until `leftoversReaped`, which bounds the reaper's retire
//! queue by the table.
//!
//! The boot inputs every launch sends, `WorkerRuntimeBootOptions` and the
//! tmpfs size, are read from the server's environment once, by the service
//! before `init` (`resolveWorkerRuntimeBootOptions`,
//! `resolveWorkerTmpfsSizeBytes`).
//!
//! Threads: `submit`, `stop`, `gatewayLost`, `egressSessionLost`,
//! `leftoversReaped`, `takeTraces` and `countersSnapshot` run on any thread,
//! `gatewayLost` also from inside a `Deps.attachEgress` on the launcher
//! thread. `init`, `start`, `join` and `deinit` run on the thread that owns
//! the launcher, the ingress service's, and everything else on the launcher
//! thread, which alone touches the launch table and the reattach pass and
//! calls `Deps`. The launcher also polls the zygote's pidfd, because a zygote
//! that exits stops every cold start and, with nothing to restart it, the
//! server.

const std = @import("std");
const builtin = @import("builtin");
const fd_mod = @import("collo_os").fd;
const process = @import("collo_os").process;
const ipc = @import("collo_ipc");
const limits = @import("collo_limits");
const server_limits = limits.server;
const process_limits = limits.process;
const worker_shared_page = @import("collo_worker_state").page;
const zygote = @import("collo_zygote");
const host = @import("collo_host");
const config = @import("collo_server_config");
const routes_mod = @import("collo_server_routes");
const lifecycle = @import("collo_server_lifecycle");
const egress_sizing = @import("collo_egress_gateway").sizing;

const pool = @import("pool.zig");
const worker_table = @import("worker_table.zig");

pub const DefinitionIndex = config.DefinitionIndex;

/// How long a launch waits for the zygote's reply to its fork request:
/// `fork_reply_timeout_ms` in `zygote/host_client.zig`, which says why waiting
/// longer cannot recover. A miss fails the launch with `fork_reply_timeout`.
pub const fork_reply_timeout_ms: i32 = zygote.host_client.fork_reply_timeout_ms;

/// The child window, from the `WorkerInit` send to `WorkerReady`:
/// `WORKER_INIT_TIMEOUT_MS` in `common/limits/process.zig`. `host/launch.zig`
/// fixes the deadline at the send, and a launch for a pool has no owner
/// deadline to clamp it, so the window is exactly this long. A miss fails the
/// launch with `child_window_expired`.
pub const child_window_ms: i32 = process_limits.WORKER_INIT_TIMEOUT_MS;

/// How long the reattach waits for a live worker's control socket to take its
/// `egress_attach` packet: the bound the server's control channel to the
/// gateway keeps too (`control_timeout_ms` in
/// `server/gateway/control_client.zig`). A full socket means the worker has
/// stopped reading its control messages, and one that takes nothing for this
/// long is retired (`Deps.retireForEgress`).
pub const egress_attach_send_timeout_ms: i32 = 1_000;

/// The shortest time between two gateway spawns the reattach asks for
/// (`Deps.egressPrewarm`), whether the last spawn failed or its gateway died,
/// counting an attach that failed under the gateway as a spawn, and between
/// two passes, each of which attaches a worker at most once.
pub const egress_prewarm_interval_ms: i32 = 1_000;

/// Session loss reports (`Launcher.egressSessionLost`) waiting for the
/// launcher thread. A gateway reports each session once and holds at most
/// `sizing.workers_max` of them, and the reports of a gateway that was
/// retired may still arrive beside the current one's, so a correct gateway
/// never fills this.
const lost_sessions_max: usize = 2 * egress_sizing.workers_max;

/// Finished launches `takeTraces` can return; older ones are dropped first.
pub const trace_capacity: usize = 256;

/// The CPU quota every launch gives its worker's cgroup leaf and checks the
/// leaf against at adoption, so the adoption's probe matches without a
/// rewrite.
const launch_cpu_max_cores: u32 = limits.worker.cpu_max_cores;

/// A worker launches with the first route of its definition: the route whose
/// pack WorkerInit carries and the child registers before it reports ready.
const launch_route: config.RouteIndex = 0;

/// How long the thread waits before polling again after poll(2) failed,
/// which it does only when the kernel lacks memory for the poll table.
/// Deadlines keep expiring meanwhile, so a launch never outlives its window.
const poll_retry_ns: u64 = 10 * std.time.ns_per_ms;

/// The wake eventfd, the zygote's pidfd, the zygote's control socket and the
/// control socket of the worker whose `egress_attach` waits for room lead the
/// poll set; each launch waiting for `WorkerReady` adds its init socket and
/// its pidfd.
const poll_fixed_sources: usize = 4;
const poll_wake: usize = 0;
const poll_zygote_pidfd: usize = 1;
const poll_zygote_control: usize = 2;
const poll_egress_send: usize = 3;

/// Why a launch was submitted. The counters carry it.
pub const GrowthReason = enum {
    /// A request waits and its pool may grow.
    waiter,
    /// A worker died while requests wait.
    replacement,
    /// A retirement freed a table entry while requests wait.
    capacity,
};

/// Where one launch stands. Each state waits in the launcher's thread:
/// `queued` for its turn at the zygote, `awaiting_reattach` for a turn with
/// no fork request outstanding, the other two in the `poll` set.
pub const LaunchState = enum {
    /// Claimed, waiting for the zygote's control socket, which carries one
    /// fork request at a time. The launch holds no cgroup leaf and no egress
    /// session yet.
    queued,
    /// The cgroup leaf is created, the egress session attached when the
    /// definition has a grant, and the fork request sent with the leaf; the
    /// reply is awaited until `fork_reply_timeout_ms`. One launch at most is
    /// here.
    fork_requested,
    /// `WorkerInit` is sent, and `WorkerReady` is awaited on the init socket,
    /// with the child's pidfd, until the child window closes.
    init_sent,
    /// The child reported `WorkerReady`, but the session the launch attached
    /// is gone: its gateway is no longer current, or the gateway removed it.
    /// The next turn with no fork request outstanding attaches the worker to
    /// the current gateway and publishes it.
    awaiting_reattach,
};

/// Why a launch produced no worker.
pub const LaunchFailure = enum {
    /// The cgroup leaf could not be created or configured, or the launcher
    /// has no worker cgroup root to create it under.
    cgroup_leaf,
    /// The worker's egress wake set could not be created
    /// (`ipc.egress_shared.WakeSet.create`), or a detached launch could not
    /// open the worker's wake descriptors from it, for want of descriptors.
    egress_wake_set,
    /// The zygote exited, or its control socket closed, before it replied.
    zygote_died,
    /// The zygote's reply or the child's init outcome broke the protocol.
    zygote_protocol,
    /// The zygote refused this fork and stays up to serve the next one
    /// (`error.ForkTransientFailure`).
    fork_refused,
    /// No fork reply within `fork_reply_timeout_ms`. A late reply would read
    /// as the answer to the next request, so the zygote is killed and the
    /// server stops.
    fork_reply_timeout,
    /// The gateway refused the launch's egress session
    /// (`error.EgressGatewayAttachRejected` from `Deps.attachEgress`), or a
    /// launch whose session was lost before `WorkerReady` was refused one by
    /// the current gateway or could not be sent it.
    egress_attach,
    /// The definition has an egress grant and no gateway gave its launch a
    /// session: none is wired, or the attachment came back incomplete.
    egress_gateway_required,
    /// The child came without the cgroup leaf it must be born in.
    worker_cgroup_not_prepared,
    /// The worker's tmp root came back with another mode than the launch
    /// created it with.
    invalid_worker_tmp_root_mode,
    /// The worker's tmp root came back owned by another user.
    invalid_worker_tmp_root_owner,
    /// The boot options failed `WorkerRuntimeBootOptions.validate`.
    invalid_boot_options,
    /// The child reported init failure or ended before `WorkerReady`. The
    /// launcher's log of the failure names the child's reason, or whether it
    /// ended for memory (`host.launch.InitFailure`).
    worker_init_failed,
    /// No `WorkerReady` within `child_window_ms`.
    child_window_expired,
    /// The server's end of the worker's control socket could not be made
    /// non-blocking.
    control_socket,
    out_of_memory,
    /// The launcher stopped before the launch finished.
    stopping,

    /// The failure a `host/launch.zig` error stands for. The switch has no
    /// `else`, so an error that file adds does not compile until it is given
    /// a failure here.
    pub fn fromLaunchError(err: host.launch.LaunchError) LaunchFailure {
        return switch (err) {
            error.WorkerCgroupNotPrepared => .worker_cgroup_not_prepared,
            error.InvalidWorkerTmpRootMode => .invalid_worker_tmp_root_mode,
            error.InvalidWorkerTmpRootOwner => .invalid_worker_tmp_root_owner,
            error.InvalidBootOptions => .invalid_boot_options,
            error.EgressWakeUnavailable => .egress_wake_set,
            error.WorkerInitTimeout => .child_window_expired,
            error.WorkerInitFailed => .worker_init_failed,
            error.ZygoteProtocol => .zygote_protocol,
            error.OutOfMemory => .out_of_memory,
        };
    }

    /// The failure a fork RPC error stands for.
    pub fn fromForkError(err: zygote.host_client.ForkError) LaunchFailure {
        return switch (err) {
            error.ForkTransientFailure => .fork_refused,
            error.ZygoteDied => .zygote_died,
            error.ZygoteProtocol => .zygote_protocol,
        };
    }

    /// Whether the zygote is gone, and with it every later launch.
    pub fn endsZygote(failure: LaunchFailure) bool {
        return switch (failure) {
            .zygote_died, .fork_reply_timeout => true,
            .cgroup_leaf,
            .egress_wake_set,
            .zygote_protocol,
            .fork_refused,
            .egress_attach,
            .egress_gateway_required,
            .worker_cgroup_not_prepared,
            .invalid_worker_tmp_root_mode,
            .invalid_worker_tmp_root_owner,
            .invalid_boot_options,
            .worker_init_failed,
            .child_window_expired,
            .control_socket,
            .out_of_memory,
            .stopping,
            => false,
        };
    }
};

/// What a failed launch leaves for the reaper, which kills the child, waits
/// for its exit and removes its cgroup leaf (`AbandonedChild.reap` in
/// `host/launch.zig`). Each descriptor is owned and moves to the callee of
/// `Deps.failed`; an unset one was never created. The callee hands a
/// `Leftovers` that `holdsChild` to the reaper, whose teardown ends with
/// `Launcher.leftoversReaped`. The launch's egress session needs no
/// teardown: the gateway drops a session once the worker's end of the
/// liveness pipe it watches closes, and the launcher closes its copy of the
/// session and the wake set, which holds no write end, while the reaper ends
/// the child's.
pub const Leftovers = struct {
    /// The child's pidfd from its fork reply and its cgroup leaf, created
    /// before the fork.
    child: host.launch.AbandonedChild = .{},

    /// Whether the reaper has a process or a cgroup leaf to tear down.
    pub fn holdsChild(self: *const Leftovers) bool {
        return self.child.pidfd.isValid() or self.child.cgroup_dir.isValid();
    }
};

/// The egress session `Deps.attachEgress` attached for a worker. A launch
/// hands its child the attachment's descriptors with `WorkerInit`, together
/// with the boot token `host/launch.zig` mints from `boot` for the fetches
/// made while the route's modules evaluate. `boot` is null when the
/// attachment's gateway was no longer current by the time its key was read;
/// the launch then sends neither the descriptors nor a token, and the worker
/// gets a session of the current gateway at `WorkerReady`. The reattach of a
/// live worker leaves `boot` unused.
pub const EgressAttach = struct {
    attachment: lifecycle.EgressGatewayAttachment,
    boot: ?host.launch.BootEgress,

    /// Scrubs the key of `boot` and forgets it, for an attach whose
    /// `WorkerInit` is sent or that sends none.
    pub fn dropBoot(self: *EgressAttach) void {
        if (self.boot) |*boot|
            std.crypto.secureZero(u8, &boot.key.bytes);
        self.boot = null;
    }

    /// Closes the session's descriptors this side holds and scrubs the key of
    /// `boot`.
    pub fn deinit(self: *EgressAttach) void {
        self.dropBoot();
        self.attachment.deinit();
    }
};

/// A live worker whose egress session is of a gateway other than the current
/// one, as `Deps.nextStaleEgressWorker` hands it to the reattach. The
/// reattach owns `control` and `wake_set` and closes both (`deinit`); the
/// other fields only name the worker back to `Deps`.
pub const ReattachTarget = struct {
    definition: DefinitionIndex,
    /// The worker's record. Pool records are never freed, so the pointer
    /// stays valid, but a record holds one worker after another:
    /// `worker_key` says whether it still holds this one.
    record: *worker_table.Record,
    worker_key: lifecycle.WorkerKey,
    /// A dup of the server's end of the worker's control socket, taken under
    /// the pool's mutex so that a retirement cannot close the descriptor, and
    /// a new one reuse its number, between the read and the dup. Invalid when
    /// this dup or the wake set's failed for want of descriptors, which the
    /// pass waits out like a gateway's failure: the worker stays detached,
    /// and the pass comes back to it after `egress_prewarm_interval_ms`.
    control: fd_mod.OwnedFd,
    /// Dups of the worker's wake set (`worker_table.Record.egress_wake_set`),
    /// taken with `control`, which its new session is built on.
    wake_set: ipc.egress_shared.WakeSet,

    pub fn deinit(self: *ReattachTarget) void {
        self.control.deinit();
        self.wake_set.deinit();
    }
};

/// A worker that reported `WorkerReady`, as `Deps.publish` receives it. The
/// handle owns every descriptor and mapping of the child; the record built
/// from it keeps the egress session, the wake set and the send scratch.
pub const ReadyWorker = struct {
    handle: host.WorkerHandle,
    /// The worker's wake set, which every later session of the worker is
    /// built on (`worker_table.Record.egress_wake_set`).
    egress_wake_set: ipc.egress_shared.WakeSet,
    /// The worker's egress session, 0 for a definition without a grant. It
    /// is of the current gateway unless that gateway failed under the
    /// worker's attach at `WorkerReady`; the reattach pass that failure
    /// starts then reaches the published worker.
    egress_generation: u64,
    egress_session_id: u64,
    /// `ipc.max_message_bytes` bytes from the launcher's `gpa`, the
    /// supervisor's allocator, allocated before the fork so that a launch
    /// that could not build its record never forks.
    dispatch_send_scratch: []u8,
    /// The child's own boot, from entering its namespaces to sending
    /// `WorkerReady`, by the stamps it wrote on its page (`childBootWorkNs`);
    /// 0 when a stamp is missing. Worker-written, so it describes only that
    /// worker's own records.
    boot_work_ns: u64 = 0,
};

/// What the launcher calls, on its own thread, to reach the pools, the
/// supervisor, the gateway and the reaper. Each call gets `ctx` back
/// unchanged.
pub const Deps = struct {
    ctx: *anyopaque,
    /// Claims a launch for `definition` when its pool wants one
    /// (`Pool.launchStarted` with the memory gate), or returns null.
    claim: *const fn (ctx: *anyopaque, definition: DefinitionIndex) ?pool.LaunchTicket,
    /// One attach round trip for a new egress session of a worker of
    /// `definition`, built on `wake_set`, the worker's wake set, or null
    /// without one when the definition has no egress grant
    /// (`worker_factory.attachLaunchEgress`). The caller owns the attachment.
    /// `error.EgressGatewayAttachRejected` is the gateway's refusal of this
    /// one session, which fails a launch with `egress_attach`, and
    /// `error.EgressGatewayRequired` says no gateway is wired, which fails it
    /// with `egress_gateway_required`. Any other error is a channel failure,
    /// which leaves the gateway retired and its loss reported
    /// (`Launcher.gatewayLost`), a spawn that failed, or descriptors the server
    /// could not create; the launch then boots its child detached.
    attachEgress: *const fn (
        ctx: *anyopaque,
        definition: DefinitionIndex,
        wake_set: *const ipc.egress_shared.WakeSet,
    ) anyerror!?EgressAttach,
    /// Takes `worker`, which it owns from the call: builds its record in the
    /// storage of the ticket's entry and publishes it (`Pool.publish`), then
    /// posts `dispatch_ready` for each handoff. Never fails.
    publish: *const fn (ctx: *anyopaque, definition: DefinitionIndex, ticket: pool.LaunchTicket, worker: ReadyWorker) void,
    /// Ends a launch that produced no worker: gives the ticket back
    /// (`Pool.launchEnded`), answers the waiters left with nothing to serve
    /// them (`Pool.takeStranded`) and hands `leftovers`, which it owns from
    /// the call, to the reaper. Never fails.
    failed: *const fn (ctx: *anyopaque, definition: DefinitionIndex, ticket: pool.LaunchTicket, failure: LaunchFailure, leftovers: Leftovers) void,
    /// The zygote's pidfd reported its exit. The server stops, since nothing
    /// restarts the zygote.
    zygoteExited: *const fn (ctx: *anyopaque) void,
    /// `Manager.currentGeneration`: the current gateway's generation, 0 while
    /// none is current. Generations grow with each spawn and are never
    /// reused, so a session of any other generation belongs to a gateway that
    /// is gone.
    egressCurrentGeneration: *const fn (ctx: *anyopaque) u64,
    /// `Manager.prewarm`: spawns a gateway when none is current.
    egressPrewarm: *const fn (ctx: *anyopaque) anyerror!void,
    /// `Manager.requestEnded` for the boot token of a worker that reported `WorkerReady`.
    egressBootEnded: *const fn (ctx: *anyopaque, generation: u64, session_id: u64) void,
    /// The next live worker of a definition with a grant whose egress session is not of gateway
    /// `generation`, with dups of its control socket and wake set taken under its pool's mutex,
    /// or null when none is left. Pool records are never freed, so the target stays addressable.
    /// A worker handed to `retireForEgress` is no longer live, which is what ends a pass.
    nextStaleEgressWorker: *const fn (ctx: *anyopaque, generation: u64) ?ReattachTarget,
    /// Writes the new session into the worker's record under its pool's mutex if the record still
    /// holds that worker; false when it was retired meanwhile.
    setWorkerEgress: *const fn (
        ctx: *anyopaque,
        target: *const ReattachTarget,
        generation: u64,
        session_id: u64,
    ) bool,
    /// Retires the worker through the reaper with reason `egress_reattach`. The worker may have
    /// left service since the target was taken, and the callee then does nothing.
    retireForEgress: *const fn (ctx: *anyopaque, target: *const ReattachTarget) void,
    /// Takes the live worker whose record names session `session_id` of gateway `generation`
    /// off that session, under its pool's mutex, so that it has no session and the next
    /// `nextStaleEgressWorker` returns it (`Supervisor.dropEgressSession`). False when no live
    /// worker holds that session.
    dropEgressSession: *const fn (ctx: *anyopaque, generation: u64, session_id: u64) bool,
};

pub const Options = struct {
    deps: Deps,
    /// Borrowed; outlives the launcher. The launcher thread alone sends fork
    /// requests on its control socket and assigns its fork job ids.
    zygote_process: *zygote.host_client.SpawnedZygote,
    /// Borrowed: a launch hands its child the definition's limits and route
    /// artifacts (pack, bindings, fs index).
    routes: *const routes_mod.Routes,
    /// Borrowed; null only in fixtures that never fork, since a worker is
    /// born only into a prepared leaf and a launch without a root fails with
    /// `cgroup_leaf`.
    worker_cgroup_root: ?*host.WorkerCgroupRoot,
    /// What every launch sends, read once at boot
    /// (`resolveWorkerRuntimeBootOptions`, `resolveWorkerTmpfsSizeBytes`).
    boot: ipc.WorkerRuntimeBootOptions,
    tmpfs_size_bytes: ?u64,
    /// Each pool's `launches_max`, which sizes the launch table to every
    /// launch the pools can have in flight together.
    launches_per_definition_max: u32,
};

pub const Counters = struct {
    submitted_waiter: u64 = 0,
    submitted_replacement: u64 = 0,
    submitted_capacity: u64 = 0,
    claimed: u64 = 0,
    published: u64 = 0,
    failed: u64 = 0,
    /// Submits that found no room in the launch table, because launches in
    /// flight and leftovers the reaper has not torn down filled it; their
    /// definitions are claimed again once room frees.
    deferred: u64 = 0,
    /// poll(2) failures of the launcher thread, each followed by
    /// `poll_retry_ns` of sleep.
    poll_failures: u64 = 0,
    /// Gateways reported lost (`gatewayLost`).
    gateway_losses: u64 = 0,
    /// Reattach passes that could not get a current gateway: the spawn
    /// failed, or its gateway was gone before the pass read its generation.
    egress_prewarm_failures: u64 = 0,
    /// Workers given a session of a new gateway: live ones and launches that
    /// reported ready after their gateway was lost.
    egress_reattached: u64 = 0,
    /// Live workers handed to `Deps.retireForEgress`: the gateway refused
    /// their session, or their control socket did not take it.
    egress_reattach_retired: u64 = 0,
    /// Workers and launches no gateway could attach: none was current while
    /// the pass waited to spawn one, the gateway failed under their attach,
    /// or the server could not duplicate their descriptors. They stay
    /// detached, with every `fetch` refused, until the pass reaches them.
    egress_left_detached: u64 = 0,
    /// Sessions the current gateway removed on its own from a live worker or
    /// a launch (`Launcher.egressSessionLost`), each of which a pass or the
    /// launch's `WorkerReady` replaces.
    egress_sessions_lost: u64 = 0,
    /// Session loss reports dropped because `lost_sessions_max` waited
    /// already, which only a gateway that reports sessions it never held can
    /// cause; the worker of each stays detached until its gateway is lost.
    egress_session_reports_dropped: u64 = 0,
};

/// What one launch did, from its claim to its publish or its failure, for
/// the cold-start benchmark and local-e2e (`Launcher.takeTraces`). Every
/// timestamp is a CLOCK_MONOTONIC reading in nanoseconds, the clock the child
/// stamps its boot phases with, so the server's marks and the child's stamps
/// subtract directly; 0 means the step did not happen.
pub const LaunchTrace = struct {
    definition: DefinitionIndex = 0,
    outcome: Outcome = .failed,
    /// Why the launch failed; null for a published worker.
    failure: ?LaunchFailure = null,
    /// The child's pid from its fork reply, 0 when no child was forked.
    pid: u32 = 0,
    /// The first `submit` for the definition since the launcher last took
    /// the submissions, or 0 for a launch claimed after a publish.
    submitted_ns: u64 = 0,
    claimed_ns: u64 = 0,
    fork_sent_ns: u64 = 0,
    fork_reply_ns: u64 = 0,
    init_sent_ns: u64 = 0,
    /// The launcher read `WorkerReady` (`Machine.ready_received_ns`).
    ready_received_ns: u64 = 0,
    /// `Deps.publish` returned: the worker is in its pool and the handoffs
    /// are posted.
    published_ns: u64 = 0,
    /// The child's own account of its boot, read from its shared page when it
    /// reported ready.
    child_stamps: [worker_shared_page.BOOT_PHASE_COUNT]u64 = @splat(0),
    spans: host.launch.LaunchSpans = .{},

    pub const Outcome = enum(u8) { published, failed };
};

/// One launch in flight, in its entry of `Launcher.launches`.
const Launch = struct {
    state: LaunchState,
    definition: DefinitionIndex,
    ticket: pool.LaunchTicket,
    /// Claim order: the oldest queued launch forks first.
    sequence: u64,
    /// The zygote's job id, which names the cgroup leaf; 0 before the fork.
    fork_job_id: u64 = 0,
    /// The cgroup leaf, from its creation until `Machine.start` takes it
    /// with the child.
    cgroup_dir: fd_mod.OwnedFd = .{},
    /// The worker's wake set, from `startFork` until the publish hands it to
    /// the worker's record or `endFailed` closes it: the launch's session is
    /// built on it, and a launch without one sends `WorkerInit` the worker's
    /// wake descriptors from it.
    wake_set: ipc.egress_shared.WakeSet = .{},
    /// From the attach until `Machine.start` sent `WorkerInit`, after which
    /// the child holds its own copies of the session's descriptors; null for
    /// a definition without a grant.
    egress: ?EgressAttach = null,
    /// The session's identity, kept for the record and for the check at
    /// `WorkerReady` that its gateway is still current; 0 without one.
    egress_generation: u64 = 0,
    egress_session_id: u64 = 0,
    /// `ReadyWorker.dispatch_send_scratch`, from before the fork until the
    /// publish takes it.
    dispatch_send_scratch: []u8 = &.{},
    /// The `WorkerInit` handoff, from the fork reply until ready or failed.
    machine: ?host.launch.Machine = null,
    /// When the current state's wait ends (CLOCK_MONOTONIC): the fork reply
    /// deadline, then the end of the child window.
    deadline_ns: u64 = 0,
    trace: LaunchTrace,
};

/// The reattach of live workers after a gateway loss or a session loss, one
/// gateway call per launcher turn. Launcher thread only.
const EgressPass = struct {
    phase: Phase = .idle,
    /// The gateway this pass attaches workers to, read after its prewarm.
    generation: u64 = 0,
    /// When the next prewarm may run (CLOCK_MONOTONIC):
    /// `egress_prewarm_interval_ms` after the last one, or after the last
    /// step that started the pass over because it failed (`restartPass`).
    prewarm_after_ns: u64 = 0,
    /// The last prewarm failed, so the next failure is not logged again.
    prewarm_failing: bool = false,
    /// The worker whose `egress_attach` waits for room on its control
    /// socket. The pass moves to the next worker only once it is sent or its
    /// worker retired.
    sending: ?EgressSend = null,

    const Phase = enum {
        /// No loss is waiting to be handled.
        idle,
        /// A loss came in: the next step spawns a gateway when none is current
        /// and reads its generation.
        prewarm,
        /// Each step attaches the next live worker whose session is not of
        /// `generation`.
        reattach,
    };
};

/// A live worker's `egress_attach`, waiting in the poll set for room on its
/// control socket.
const EgressSend = struct {
    target: ReattachTarget,
    /// The session whose worker half the packet carries, which the worker's
    /// record already names (`Deps.setWorkerEgress`).
    attachment: lifecycle.EgressGatewayAttachment,
    /// `egress_attach_send_timeout_ms` after the first attempt
    /// (CLOCK_MONOTONIC).
    deadline_ns: u64,
};

/// A session its gateway reported removed (`Launcher.egressSessionLost`).
const LostSession = struct {
    generation: u64,
    session_id: u64,
};

const DefinitionSet = std.bit_set.StaticBitSet(server_limits.worker_definitions_max);

pub const InitError = error{ OutOfMemory, InvalidLauncherOptions, InvalidBootOptions } ||
    std.posix.EventFdError;

pub const Launcher = struct {
    gpa: std.mem.Allocator,
    deps: Deps,
    zygote_process: *zygote.host_client.SpawnedZygote,
    routes: *const routes_mod.Routes,
    worker_cgroup_root: ?*host.WorkerCgroupRoot,
    boot: ipc.WorkerRuntimeBootOptions,
    tmpfs_size_bytes: ?u64,
    /// `definitionCount() * launches_per_definition_max` entries, allocated
    /// at `init`. Launcher thread only.
    launches: []?Launch,
    /// The poll set, `poll_fixed_sources` plus two entries per launch, and
    /// for each launch entry the index of its launch. Launcher thread only.
    pollfds: []std.posix.pollfd,
    poll_launches: []u32,
    /// Guards `submitted`, `submitted_ns`, `egress_lost_generation`,
    /// `lost_sessions` with its length and `counters`. A leaf, never held
    /// across a call.
    mutex: std.Thread.Mutex,
    /// A bit per definition submitted since the thread last looked. A second
    /// submit before then adds nothing, so submissions never queue beyond one
    /// per definition and `submit` cannot fail for room.
    submitted: DefinitionSet,
    /// When each set bit of `submitted` was set.
    submitted_ns: [server_limits.worker_definitions_max]u64,
    /// The newest generation `gatewayLost` reported since the thread last
    /// looked, 0 for none. Losses collapse into one like submissions do,
    /// since one pass serves them all.
    egress_lost_generation: u64,
    /// Session loss reports the thread has not taken yet, in arrival order;
    /// the first `lost_sessions_len` are set.
    lost_sessions: [lost_sessions_max]LostSession,
    lost_sessions_len: usize,
    counters: Counters,
    /// Failed launches whose leftovers hold a child or a leaf that the
    /// reaper has not torn down yet (`leftoversReaped`).
    leftovers_held: std.atomic.Value(u32),
    /// The eventfd `submit`, `stop`, `gatewayLost`, `egressSessionLost` and
    /// `leftoversReaped` write and the thread polls.
    wake: fd_mod.OwnedFd,
    stop_requested: std.atomic.Value(bool),
    thread: ?std.Thread,
    traces: TraceRing,

    // Launcher thread only.

    /// Launches in `launches`.
    in_flight: u32,
    /// The launch whose fork request is outstanding.
    forking: ?u32,
    next_sequence: u64,
    /// Definitions to claim for on the next turn: submitted while the table
    /// had no room, or with a worker just published.
    deferred: DefinitionSet,
    /// `submitted_ns` of the definitions taken from `submitted` and not yet
    /// answered by a claim that found nothing to start.
    pending_since_ns: [server_limits.worker_definitions_max]u64,
    /// No fork request may be sent: the zygote exited, or a failure that
    /// ends it was met.
    zygote_dead: bool,
    /// The zygote's pidfd reported the exit, which `Deps.zygoteExited` was
    /// told once; the pidfd leaves the poll set.
    zygote_exit_seen: bool,
    /// The last poll(2) failed, so the next failure is not logged again.
    poll_failing: bool,
    egress: EgressPass,

    /// Prepares the launcher in place: the launch table, the poll set, the
    /// trace ring and the wake eventfd. The thread starts at `start`. `gpa`
    /// must be the supervisor's allocator, since every worker's send scratch
    /// comes from it and its record frees it. Fails with
    /// `error.InvalidLauncherOptions` for a table that could hold no launch
    /// or more definitions than `worker_definitions_max`, with
    /// `error.InvalidBootOptions` when `options.boot` fails its validation,
    /// and with `error.OutOfMemory` or the eventfd's error, leaving nothing
    /// allocated.
    pub fn init(self: *Launcher, gpa: std.mem.Allocator, options: Options) InitError!void {
        const definition_count: usize = options.routes.definitionCount();
        if (definition_count == 0) return error.InvalidLauncherOptions;
        if (definition_count > server_limits.worker_definitions_max) return error.InvalidLauncherOptions;
        if (options.launches_per_definition_max == 0) return error.InvalidLauncherOptions;
        options.boot.validate() catch return error.InvalidBootOptions;

        const launch_capacity = definition_count * options.launches_per_definition_max;
        const launches = try gpa.alloc(?Launch, launch_capacity);
        errdefer gpa.free(launches);
        @memset(launches, null);
        const poll_capacity = poll_fixed_sources + 2 * launch_capacity;
        const pollfds = try gpa.alloc(std.posix.pollfd, poll_capacity);
        errdefer gpa.free(pollfds);
        const poll_launches = try gpa.alloc(u32, poll_capacity);
        errdefer gpa.free(poll_launches);
        const trace_entries = try gpa.alloc(LaunchTrace, trace_capacity);
        errdefer gpa.free(trace_entries);
        const wake = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);

        self.* = .{
            .gpa = gpa,
            .deps = options.deps,
            .zygote_process = options.zygote_process,
            .routes = options.routes,
            .worker_cgroup_root = options.worker_cgroup_root,
            .boot = options.boot,
            .tmpfs_size_bytes = options.tmpfs_size_bytes,
            .launches = launches,
            .pollfds = pollfds,
            .poll_launches = poll_launches,
            .mutex = .{},
            .submitted = .initEmpty(),
            .submitted_ns = @splat(0),
            .egress_lost_generation = 0,
            .lost_sessions = undefined,
            .lost_sessions_len = 0,
            .counters = .{},
            .leftovers_held = .init(0),
            .wake = fd_mod.OwnedFd.fromRaw(wake),
            .stop_requested = .init(false),
            .thread = null,
            .traces = .{ .entries = trace_entries },
            .in_flight = 0,
            .forking = null,
            .next_sequence = 1,
            .deferred = .initEmpty(),
            .pending_since_ns = @splat(0),
            .zygote_dead = false,
            .zygote_exit_seen = false,
            .poll_failing = false,
            .egress = .{},
        };
    }

    /// Starts the launcher thread. Fails with the spawn's error, and the
    /// launcher then stays stopped.
    pub fn start(self: *Launcher) std.Thread.SpawnError!void {
        std.debug.assert(self.thread == null);
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
    }

    /// Asks the launcher thread to claim launches for `definition` while its
    /// pool wants them. Any thread; never blocks beyond `mutex`. A wake that
    /// cannot be written is logged at `err` and the submission waits for the
    /// next wake.
    pub fn submit(self: *Launcher, definition: DefinitionIndex, reason: GrowthReason) void {
        std.debug.assert(definition < self.routes.definitionCount());
        const now_ns = process.monotonicNowNsOrZero();
        self.mutex.lock();
        if (!self.submitted.isSet(definition)) {
            self.submitted.set(definition);
            self.submitted_ns[definition] = now_ns;
        }
        switch (reason) {
            .waiter => self.counters.submitted_waiter += 1,
            .replacement => self.counters.submitted_replacement += 1,
            .capacity => self.counters.submitted_capacity += 1,
        }
        self.mutex.unlock();
        self.signalWake();
    }

    /// The gateway of `generation` is gone (`Manager.Deps.gatewayLost`): the
    /// launcher thread spawns a new one and attaches every live worker with a
    /// grant to it. Any thread, the launcher's own included, from `init` until
    /// `deinit`; never blocks beyond `mutex`. A wake that cannot be written is
    /// logged at `err` and the pass waits for the next wake.
    pub fn gatewayLost(self: *Launcher, generation: u64) void {
        std.debug.assert(generation != 0);
        self.mutex.lock();
        self.egress_lost_generation = @max(self.egress_lost_generation, generation);
        self.counters.gateway_losses += 1;
        self.mutex.unlock();
        self.signalWake();
    }

    /// Gateway `generation` removed session `session_id` on its own
    /// (`Manager.Deps.sessionLost`): the launcher thread takes the launch or
    /// the live worker that holds it off the session, and the worker gets a
    /// new one, from the next pass or before its publish. Any thread, from
    /// `init` until `deinit`; never blocks beyond `mutex`. A report past
    /// `lost_sessions_max` waiting ones is dropped, counted and logged at
    /// `err`.
    pub fn egressSessionLost(self: *Launcher, generation: u64, session_id: u64) void {
        std.debug.assert(generation != 0);
        self.mutex.lock();
        const kept = self.lost_sessions_len < self.lost_sessions.len;
        if (kept) {
            self.lost_sessions[self.lost_sessions_len] = .{ .generation = generation, .session_id = session_id };
            self.lost_sessions_len += 1;
        } else {
            self.counters.egress_session_reports_dropped += 1;
        }
        self.mutex.unlock();
        if (!kept) {
            std.log.err("egress gateway generation={d} reported session {d} lost past {d} waiting reports; its worker stays detached", .{
                generation,
                session_id,
                lost_sessions_max,
            });
            return;
        }
        self.signalWake();
    }

    /// Asks the thread to stop. Any thread. Launches still in flight end
    /// through `Deps.failed` with `stopping` before the thread exits.
    pub fn stop(self: *Launcher) void {
        self.stop_requested.store(true, .release);
        self.signalWake();
    }

    /// The reaper finished tearing down one `Leftovers` that `holdsChild`,
    /// which frees the launch-table room it held. Any thread, until `deinit`.
    pub fn leftoversReaped(self: *Launcher) void {
        const held = self.leftovers_held.fetchSub(1, .acq_rel);
        std.debug.assert(held != 0);
        self.signalWake();
    }

    /// Waits for the thread `start` spawned to exit after `stop`.
    pub fn join(self: *Launcher) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    /// Frees the launch table, the poll set and the trace ring and closes the
    /// wake eventfd, after `join` and after the reaper's last
    /// `leftoversReaped`.
    pub fn deinit(self: *Launcher) void {
        std.debug.assert(self.thread == null);
        for (self.launches) |launch|
            std.debug.assert(launch == null);
        std.debug.assert(self.egress.sending == null);
        self.gpa.free(self.traces.entries);
        self.gpa.free(self.poll_launches);
        self.gpa.free(self.pollfds);
        self.gpa.free(self.launches);
        self.wake.deinit();
        self.* = undefined;
    }

    /// Moves up to `out.len` finished launches into `out`, oldest first, and
    /// returns how many; the ring is empty afterwards, so traces that did not
    /// fit are lost.
    pub fn takeTraces(self: *Launcher, out: []LaunchTrace) usize {
        return self.traces.take(out);
    }

    pub fn countersSnapshot(self: *Launcher) Counters {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.counters;
    }

    fn threadMain(self: *Launcher) void {
        // The loop ends only on `stop`; every turn waits in `poll`, ends a
        // launch or takes one reattach step, which a pass has one of per live
        // worker, so it never spins.
        while (!self.stop_requested.load(.acquire)) {
            self.claimSubmitted();
            self.stepEgress();
            self.forkNext();
            self.waitAndHandle();
        }
        // The server is stopping, so a send still waiting is dropped without
        // retiring its worker.
        if (self.egress.sending) |*sending| {
            sending.attachment.deinit();
            sending.target.deinit();
            self.egress.sending = null;
        }
        for (self.launches, 0..) |*slot, index| {
            if (slot.* != null)
                self.endFailed(@intCast(index), .stopping);
        }
    }

    fn signalWake(self: *Launcher) void {
        const one: u64 = 1;
        _ = std.posix.write(self.wake.fd(), std.mem.asBytes(&one)) catch |err| switch (err) {
            // The counter is at its maximum, so a wake is already pending.
            error.WouldBlock => return,
            else => std.log.err("launcher wake write failed: {s}", .{@errorName(err)}),
        };
    }

    fn noteCounter(self: *Launcher, comptime field: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        @field(self.counters, field) += 1;
    }

    fn hasRoom(self: *const Launcher) bool {
        const held: usize = self.leftovers_held.load(.acquire);
        return self.in_flight + held < self.launches.len;
    }

    /// Claims launches for every definition submitted or deferred since the
    /// last turn.
    fn claimSubmitted(self: *Launcher) void {
        self.mutex.lock();
        const submitted = self.submitted;
        self.submitted = .initEmpty();
        var submitted_iterator = submitted.iterator(.{});
        while (submitted_iterator.next()) |definition| {
            if (self.pending_since_ns[definition] == 0)
                self.pending_since_ns[definition] = self.submitted_ns[definition];
        }
        self.mutex.unlock();

        const previously_deferred = self.deferred;
        var wanted = submitted;
        wanted.setUnion(previously_deferred);
        self.deferred = .initEmpty();
        var iterator = wanted.iterator(.{});
        while (iterator.next()) |definition| {
            if (self.claimFor(@intCast(definition))) continue;
            self.deferred.set(definition);
            if (!previously_deferred.isSet(definition))
                self.noteCounter("deferred");
        }
    }

    /// Claims launches for `definition` while its pool wants them, and
    /// returns false when the table ran out of room first. The pool refuses
    /// a claim once it has `launches_max` in flight, so the loop runs at most
    /// that many times plus one.
    fn claimFor(self: *Launcher, definition: DefinitionIndex) bool {
        while (self.hasRoom()) {
            const ticket = self.deps.claim(self.deps.ctx, definition) orelse {
                self.pending_since_ns[definition] = 0;
                return true;
            };
            self.queueLaunch(definition, ticket);
        }
        return false;
    }

    fn queueLaunch(self: *Launcher, definition: DefinitionIndex, ticket: pool.LaunchTicket) void {
        const index = for (self.launches, 0..) |launch, index| {
            if (launch == null) break index;
        } else unreachable; // `hasRoom` held: fewer launches than entries.
        self.launches[index] = Launch{
            .state = .queued,
            .definition = definition,
            .ticket = ticket,
            .sequence = self.next_sequence,
            .trace = .{
                .definition = definition,
                .submitted_ns = self.pending_since_ns[definition],
                .claimed_ns = process.monotonicNowNsOrZero(),
            },
        };
        self.next_sequence += 1;
        self.in_flight += 1;
        self.noteCounter("claimed");
    }

    /// One step of the egress side, with at most one gateway call: a launch
    /// awaiting its reattach first, then the pass. No gateway call runs while
    /// a fork request is outstanding, so none holds the thread while a fork
    /// reply's deadline runs; the losses reported since the last turn are
    /// taken first either way, since taking them calls no gateway.
    fn stepEgress(self: *Launcher) void {
        self.takeGatewayLoss();
        self.takeSessionLosses();
        if (self.forking != null) return;
        if (self.firstAwaitingReattach()) |index|
            return self.reattachReady(index);
        if (self.egress.sending != null) return;
        switch (self.egress.phase) {
            .idle => {},
            .prewarm => {
                const now_ns = process.monotonicNowNsOrZero();
                if (now_ns >= self.egress.prewarm_after_ns)
                    self.prewarmForPass(now_ns);
            },
            .reattach => self.reattachNextStale(),
        }
    }

    /// Starts the pass over when a gateway was lost since the last turn. A
    /// loss older than the gateway the pass runs for is a late report of one
    /// that pass already replaced, and it covers that gateway's workers.
    fn takeGatewayLoss(self: *Launcher) void {
        self.mutex.lock();
        const lost = self.egress_lost_generation;
        self.egress_lost_generation = 0;
        self.mutex.unlock();
        if (lost == 0) return;
        if (lost < self.egress.generation) return;
        self.egress.phase = .prewarm;
    }

    /// Takes the sessions reported lost since the last turn off the launches
    /// and live workers that hold them.
    fn takeSessionLosses(self: *Launcher) void {
        var taken: [lost_sessions_max]LostSession = undefined;
        self.mutex.lock();
        const count = self.lost_sessions_len;
        @memcpy(taken[0..count], self.lost_sessions[0..count]);
        self.lost_sessions_len = 0;
        self.mutex.unlock();
        for (taken[0..count]) |lost|
            self.dropLostSession(lost);
    }

    /// Takes the launch or the live worker holding `lost` off that session.
    /// A launch then goes to `awaiting_reattach` at `WorkerReady`, as one
    /// whose gateway was lost does. A live worker's record names no session
    /// from then on, and the pass, started over, attaches it again no sooner
    /// than `egress_prewarm_interval_ms` after its last prewarm, so a worker
    /// whose session keeps being removed gets one attach per interval.
    fn dropLostSession(self: *Launcher, lost: LostSession) void {
        for (self.launches) |*slot| {
            const launch = if (slot.*) |*held| held else continue;
            if (launch.egress_session_id != lost.session_id) continue;
            if (launch.egress_generation != lost.generation) continue;
            launch.egress_generation = 0;
            self.noteCounter("egress_sessions_lost");
            return;
        }
        if (!self.deps.dropEgressSession(self.deps.ctx, lost.generation, lost.session_id))
            return;
        self.noteCounter("egress_sessions_lost");
        self.egress.phase = .prewarm;
    }

    /// Whether the pass waits to spawn a gateway while none is current. A
    /// launch then boots detached rather than attach, since an attach would
    /// spawn a gateway on demand, before the interval the pass keeps.
    fn awaitsEgressGateway(self: *const Launcher) bool {
        if (self.egress.phase != .prewarm)
            return false;
        return self.deps.egressCurrentGeneration(self.deps.ctx) == 0;
    }

    /// Has a gateway spawned when none is current and points the pass at the
    /// current one. A failed spawn, or a gateway gone before its generation
    /// was read, leaves the pass to try again `egress_prewarm_interval_ms`
    /// later, with the workers detached meanwhile.
    fn prewarmForPass(self: *Launcher, now_ns: u64) void {
        std.debug.assert(self.egress.phase == .prewarm);
        self.egress.prewarm_after_ns = now_ns + msToNs(egress_prewarm_interval_ms);
        self.deps.egressPrewarm(self.deps.ctx) catch |err|
            return self.notePrewarmFailure(@errorName(err));
        const generation = self.deps.egressCurrentGeneration(self.deps.ctx);
        if (generation == 0)
            return self.notePrewarmFailure("the new gateway was lost at once");
        self.egress.prewarm_failing = false;
        self.egress.generation = generation;
        self.egress.phase = .reattach;
    }

    fn notePrewarmFailure(self: *Launcher, reason: []const u8) void {
        self.noteCounter("egress_prewarm_failures");
        if (!self.egress.prewarm_failing)
            std.log.warn("no egress gateway to attach live workers to, retrying: {s}", .{reason});
        self.egress.prewarm_failing = true;
    }

    /// The pass's step for the next live worker without a session of the
    /// current gateway: a new session, the record, then the packet. Ends the
    /// pass when none is left. The gateway's refusal of the session retires
    /// the worker; any other attach failure, and descriptors the server could
    /// not duplicate, are no fault of the worker, so it keeps its old session,
    /// detached, and the pass starts over to reach it again.
    fn reattachNextStale(self: *Launcher) void {
        std.debug.assert(self.egress.phase == .reattach);
        std.debug.assert(self.egress.sending == null);
        var target = self.deps.nextStaleEgressWorker(self.deps.ctx, self.egress.generation) orelse {
            self.egress.phase = .idle;
            return;
        };
        if (!target.control.isValid())
            return self.leaveStaleDetached(&target, "its control socket or wake set could not be duplicated");
        const attached = self.deps.attachEgress(self.deps.ctx, target.definition, &target.wake_set) catch |err| {
            if (err == error.EgressGatewayAttachRejected)
                return self.retireStale(&target, @errorName(err));
            return self.leaveStaleDetached(&target, @errorName(err));
        };
        // `nextStaleEgressWorker` names only workers of a definition with a
        // grant, so a null here means the two disagree, and retiring the
        // worker is what keeps the pass from meeting it again.
        var attach = attached orelse
            return self.retireStale(&target, "its definition has no egress grant");
        // A live worker booted long ago; only a launch sends a boot token.
        attach.dropBoot();
        // The gateway moved under the pass: this worker gets the newest one,
        // and the pass starts over for the others.
        if (attach.attachment.generation != self.egress.generation)
            self.egress.phase = .prewarm;
        const session_id = attach.attachment.session_id;
        if (!self.deps.setWorkerEgress(self.deps.ctx, &target, attach.attachment.generation, session_id)) {
            // The worker left service since the target was taken.
            attach.deinit();
            target.deinit();
            return;
        }
        self.egress.sending = .{
            .target = target,
            .attachment = attach.attachment,
            .deadline_ns = process.monotonicNowNsOrZero() + msToNs(egress_attach_send_timeout_ms),
        };
        self.trySendEgressAttach();
    }

    /// Sends the waiting `egress_attach`. A socket with no room keeps it in
    /// the poll set until its deadline; any other failure retires the worker,
    /// since its record already names a session the worker does not have.
    fn trySendEgressAttach(self: *Launcher) void {
        const sending = &self.egress.sending.?;
        ipc.egress_attach.send(sending.target.control.fd(), egressSharedFds(&sending.attachment)) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return self.failEgressSend(@errorName(err)),
        };
        sending.attachment.deinit();
        sending.target.deinit();
        self.egress.sending = null;
        self.noteCounter("egress_reattached");
    }

    fn failEgressSend(self: *Launcher, reason: []const u8) void {
        var sending = self.egress.sending.?;
        self.egress.sending = null;
        sending.attachment.deinit();
        self.retireStale(&sending.target, reason);
    }

    /// Leaves a live worker the pass could not attach for no fault of its own
    /// on its session, detached, closes the target's dups and starts the pass
    /// over, which reaches the worker again after `egress_prewarm_interval_ms`.
    fn leaveStaleDetached(self: *Launcher, target: *ReattachTarget, reason: []const u8) void {
        std.log.warn("egress reattach of worker {d} waits for the next pass: {s}", .{
            target.worker_key.worker_id,
            reason,
        });
        target.deinit();
        self.noteCounter("egress_left_detached");
        self.restartPass();
    }

    /// Starts the pass over after a step that failed, with its next spawn
    /// `egress_prewarm_interval_ms` away. An attach spawns a gateway when
    /// none is current, so one that failed under the gateway counts as a
    /// spawn of the pass's own, and a pass that cannot reach a worker for
    /// want of descriptors tries again once per interval.
    fn restartPass(self: *Launcher) void {
        self.egress.phase = .prewarm;
        self.egress.prewarm_after_ns = process.monotonicNowNsOrZero() + msToNs(egress_prewarm_interval_ms);
    }

    /// Hands a live worker the pass cannot attach to `Deps.retireForEgress`,
    /// so that its pool launches a replacement on demand, and closes the
    /// target's dups.
    fn retireStale(self: *Launcher, target: *ReattachTarget, reason: []const u8) void {
        std.log.warn("egress reattach of worker {d} failed, retiring it: {s}", .{
            target.worker_key.worker_id,
            reason,
        });
        self.deps.retireForEgress(self.deps.ctx, target);
        target.deinit();
        self.noteCounter("egress_reattach_retired");
    }

    fn firstAwaitingReattach(self: *const Launcher) ?u32 {
        for (self.launches, 0..) |*slot, index| {
            const launch = if (slot.*) |*waiting| waiting else continue;
            if (launch.state == .awaiting_reattach) return @intCast(index);
        }
        return null;
    }

    /// Attaches a launch that reported ready after its session was lost, with
    /// its gateway or alone, to the current gateway, then publishes it. A
    /// refused session or a failed send fails the launch with
    /// `egress_attach`; any other attach failure is no fault of the worker,
    /// so it is published detached and the pass that failure starts over
    /// reaches it. While the pass waits to spawn a gateway the launch is
    /// published detached without an attach.
    fn reattachReady(self: *Launcher, index: u32) void {
        const launch = &self.launches[index].?;
        std.debug.assert(launch.state == .awaiting_reattach);
        if (self.awaitsEgressGateway()) {
            self.noteCounter("egress_left_detached");
            return self.publishReady(index);
        }
        const name = self.routes.definition(launch.definition).name;
        const attached = self.deps.attachEgress(self.deps.ctx, launch.definition, &launch.wake_set) catch |err| {
            std.log.warn("egress attach of a ready worker of {s} failed: {s}", .{ name, @errorName(err) });
            if (err == error.EgressGatewayAttachRejected)
                return self.endFailed(index, .egress_attach);
            self.noteCounter("egress_left_detached");
            self.restartPass();
            return self.publishReady(index);
        };
        // The launch got a session at its start, so its definition has a
        // grant; a null answer contradicts that, and the launch fails rather
        // than publish a worker on a session no gateway keeps.
        var attach = attached orelse return self.endFailed(index, .egress_attach);
        defer attach.deinit();
        // Only `WorkerInit` went out on this socket, and the child has read
        // it, so the packet fits; a send that fails names a worker that
        // cannot serve either.
        ipc.egress_attach.send(launch.machine.?.worker_init_fd, egressSharedFds(&attach.attachment)) catch |err| {
            std.log.warn("egress attach of a ready worker of {s} could not be sent: {s}", .{ name, @errorName(err) });
            return self.endFailed(index, .egress_attach);
        };
        launch.egress_generation = attach.attachment.generation;
        launch.egress_session_id = attach.attachment.session_id;
        self.noteCounter("egress_reattached");
        self.publishReady(index);
    }

    /// Sends the next fork request when none is outstanding, for the oldest
    /// queued launch that gets that far; one that fails before its request
    /// ends and the next one tries.
    fn forkNext(self: *Launcher) void {
        // Each failed attempt ends a launch, so this runs at most once per
        // launch in the table.
        while (self.forking == null) {
            const index = self.oldestQueued() orelse return;
            self.startFork(index);
        }
    }

    fn oldestQueued(self: *const Launcher) ?u32 {
        var oldest: ?u32 = null;
        var oldest_sequence: u64 = std.math.maxInt(u64);
        for (self.launches, 0..) |*slot, index| {
            const queued = if (slot.*) |*launch| launch else continue;
            if (queued.state != .queued) continue;
            if (queued.sequence < oldest_sequence) {
                oldest = @intCast(index);
                oldest_sequence = queued.sequence;
            }
        }
        return oldest;
    }

    /// The send scratch, the wake set, the cgroup leaf, the egress session
    /// when the definition has a grant, then the fork request: everything the
    /// fork needs, cheapest first, so a launch that cannot get one of them
    /// never forks. Leaves `forking` set when the request went out; ends the
    /// launch otherwise.
    fn startFork(self: *Launcher, index: u32) void {
        const launch = &self.launches[index].?;
        std.debug.assert(launch.state == .queued);
        if (self.zygote_dead)
            return self.endFailed(index, .zygote_died);
        const root = self.worker_cgroup_root orelse
            return self.endFailed(index, .cgroup_leaf);

        launch.dispatch_send_scratch = self.gpa.alloc(u8, ipc.max_message_bytes) catch
            return self.endFailed(index, .out_of_memory);

        const definition = self.routes.definition(launch.definition);
        launch.wake_set = ipc.egress_shared.WakeSet.create() catch |err| {
            std.log.warn("egress wake set for {s} failed: {s}", .{ definition.name, @errorName(err) });
            return self.endFailed(index, .egress_wake_set);
        };

        const fork_job_id = self.zygote_process.next_fork_job_id;
        self.zygote_process.next_fork_job_id += 1;
        launch.fork_job_id = fork_job_id;
        const leaf_fd = root.createWorkerDir(fork_job_id, .{
            .memory_limit_bytes = definition.settings.limits.memoryBytes(),
            .cpu_max_cores = launch_cpu_max_cores,
        }) catch |err| {
            std.log.warn("worker cgroup leaf for {s} failed: {s}", .{ definition.name, @errorName(err) });
            return self.endFailed(index, .cgroup_leaf);
        };
        launch.cgroup_dir = fd_mod.OwnedFd.fromRaw(leaf_fd);

        if (self.attachForLaunch(index)) |failure|
            return self.endFailed(index, failure);

        zygote.host_client.sendForkRequest(self.zygote_process, fork_job_id, leaf_fd) catch |err|
            return self.endFailed(index, LaunchFailure.fromForkError(err));
        const now_ns = process.monotonicNowNsOrZero();
        launch.state = .fork_requested;
        launch.deadline_ns = now_ns + msToNs(fork_reply_timeout_ms);
        launch.trace.fork_sent_ns = now_ns;
        self.forking = index;
    }

    /// Attaches the egress session of launch `index` when its definition has
    /// a grant, and returns the launch's failure when the gateway refused the
    /// session or none is wired. The launch boots detached instead, to be
    /// attached by the pass after its publish, while the pass waits to spawn
    /// a gateway and when the attach fails for any other reason, which starts
    /// the pass over.
    fn attachForLaunch(self: *Launcher, index: u32) ?LaunchFailure {
        const launch = &self.launches[index].?;
        if (self.awaitsEgressGateway()) {
            self.noteCounter("egress_left_detached");
            return null;
        }
        const name = self.routes.definition(launch.definition).name;
        const attached = self.deps.attachEgress(self.deps.ctx, launch.definition, &launch.wake_set) catch |err| switch (err) {
            error.EgressGatewayAttachRejected => {
                std.log.warn("egress attach for a launch of {s} refused: {s}", .{ name, @errorName(err) });
                return .egress_attach;
            },
            error.EgressGatewayRequired => {
                std.log.warn("egress attach for a launch of {s} failed: {s}", .{ name, @errorName(err) });
                return .egress_gateway_required;
            },
            else => {
                std.log.warn("egress attach for a launch of {s} failed, so it boots detached: {s}", .{
                    name,
                    @errorName(err),
                });
                self.noteCounter("egress_left_detached");
                self.restartPass();
                return null;
            },
        };
        const attach = attached orelse return null;
        launch.egress = attach;
        launch.egress_generation = attach.attachment.generation;
        launch.egress_session_id = attach.attachment.session_id;
        if (!attach.attachment.isValid())
            return .egress_gateway_required;
        return null;
    }

    /// Builds the poll set, waits until a source is ready or the earliest
    /// deadline, handles what is ready, then fails what is past its deadline.
    /// A reply or a `WorkerReady` that arrived while the thread was held
    /// elsewhere, in a gateway call, is read before its deadline is judged,
    /// and a wait that would start past a deadline does not block.
    fn waitAndHandle(self: *Launcher) void {
        if (self.stop_requested.load(.acquire)) return;

        const count = self.buildPollSet();
        const timeout_ms = self.pollTimeoutMs(process.monotonicNowNsOrZero());
        const ready = std.posix.poll(self.pollfds[0..count], timeout_ms) catch |err| {
            self.noteCounter("poll_failures");
            if (!self.poll_failing)
                std.log.warn("launcher poll failed, retrying: {s}", .{@errorName(err)});
            self.poll_failing = true;
            std.Thread.sleep(poll_retry_ns);
            self.expireDeadlines(process.monotonicNowNsOrZero());
            return;
        };
        self.poll_failing = false;
        if (ready != 0)
            self.handleReady(count);
        self.expireDeadlines(process.monotonicNowNsOrZero());
    }

    /// Handles the sources the poll over the first `count` entries of the
    /// poll set found ready.
    fn handleReady(self: *Launcher, count: usize) void {
        if (self.pollfds[poll_wake].revents != 0)
            self.drainWake();
        // A reply the zygote sent before it died still names a live child,
        // whose boot no longer needs the zygote, so it is read before the
        // exit fails the launch that waits for it.
        if (self.pollfds[poll_zygote_control].revents != 0) {
            if (self.forking) |index|
                self.receiveForkReply(index);
        }
        if (self.pollfds[poll_zygote_pidfd].revents != 0)
            self.zygoteExited();
        if (self.pollfds[poll_egress_send].revents != 0) {
            if (self.egress.sending != null)
                self.trySendEgressAttach();
        }
        var entry: usize = poll_fixed_sources;
        while (entry < count) : (entry += 2) {
            const index = self.poll_launches[entry];
            const init_revents = self.pollfds[entry].revents;
            const pidfd_revents = self.pollfds[entry + 1].revents;
            const event = readyEvent(init_revents, pidfd_revents) orelse continue;
            // A handler above may have ended the launch since the poll set
            // was built.
            const launch = if (self.launches[index]) |*waiting| waiting else continue;
            if (launch.state != .init_sent) continue;
            self.applyEffects(index, launch.machine.?.onEvent(event));
        }
    }

    /// The machine event a launch's poll entries report, in the machine's
    /// priority order: init POLLIN, then the pidfd, then init HUP or ERR. A
    /// child's exit hangs up its init socket no later than its pidfd turns
    /// readable, and a hung-up socket polls readable, so the socket is read
    /// first: a queued outcome names the failure, and a socket that ends
    /// without one is the child's exit (`Machine.finishInitOutcome`).
    fn readyEvent(init_revents: i16, pidfd_revents: i16) ?host.launch.LaunchEvent {
        if ((init_revents & std.posix.POLL.IN) != 0) return .init_readable;
        if (pidfd_revents != 0) return .pidfd_event;
        if ((init_revents & (std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0) return .init_hup;
        return null;
    }

    fn buildPollSet(self: *Launcher) usize {
        const watch_zygote = !self.zygote_exit_seen;
        self.pollfds[poll_wake] = .{ .fd = self.wake.fd(), .events = std.posix.POLL.IN, .revents = 0 };
        self.pollfds[poll_zygote_pidfd] = .{
            .fd = if (watch_zygote) self.zygote_process.pidfd else -1,
            .events = std.posix.POLL.IN,
            .revents = 0,
        };
        self.pollfds[poll_zygote_control] = .{
            .fd = if (self.forking != null) self.zygote_process.control_fd orelse -1 else -1,
            .events = std.posix.POLL.IN,
            .revents = 0,
        };
        self.pollfds[poll_egress_send] = .{
            .fd = if (self.egress.sending) |*sending| sending.target.control.fd() else -1,
            .events = std.posix.POLL.OUT,
            .revents = 0,
        };
        var count: usize = poll_fixed_sources;
        for (self.launches, 0..) |*slot, index| {
            const waiting = if (slot.*) |*launch| launch else continue;
            if (waiting.state != .init_sent) continue;
            const machine = &waiting.machine.?;
            self.pollfds[count] = .{ .fd = machine.worker_init_fd, .events = std.posix.POLL.IN, .revents = 0 };
            self.pollfds[count + 1] = .{ .fd = machine.pidfd, .events = std.posix.POLL.IN, .revents = 0 };
            self.poll_launches[count] = @intCast(index);
            self.poll_launches[count + 1] = @intCast(index);
            count += 2;
        }
        return count;
    }

    /// Milliseconds until the earliest deadline of a launch waiting in the
    /// poll set or of the egress side, rounded up, or -1 when nothing waits
    /// on a deadline.
    fn pollTimeoutMs(self: *const Launcher, now_ns: u64) i32 {
        var earliest_ns: ?u64 = self.egressDeadlineNs(now_ns);
        for (self.launches) |*slot| {
            const waiting = if (slot.*) |*launch| launch else continue;
            switch (waiting.state) {
                .queued, .awaiting_reattach => continue,
                .fork_requested, .init_sent => {},
            }
            if (earliest_ns == null or waiting.deadline_ns < earliest_ns.?)
                earliest_ns = waiting.deadline_ns;
        }
        const deadline_ns = earliest_ns orelse return -1;
        const remaining_ns = deadline_ns -| now_ns;
        // The divisor is a nonzero constant.
        const remaining_ms = std.math.divCeil(u64, remaining_ns, std.time.ns_per_ms) catch unreachable;
        return @intCast(@min(remaining_ms, std.math.maxInt(i32)));
    }

    /// When the egress side next needs the thread, in `stepEgress` order: now
    /// for a launch awaiting its reattach, the end of a send's wait, then now
    /// or the next allowed prewarm for the pass. Null when nothing there
    /// waits on time. While a fork request is outstanding only the send's
    /// deadline counts, since the fork reply wakes the thread.
    fn egressDeadlineNs(self: *const Launcher, now_ns: u64) ?u64 {
        const steps = self.forking == null;
        if (steps and self.firstAwaitingReattach() != null) return now_ns;
        if (self.egress.sending) |*sending| return sending.deadline_ns;
        if (!steps) return null;
        return switch (self.egress.phase) {
            .idle => null,
            .prewarm => self.egress.prewarm_after_ns,
            .reattach => now_ns,
        };
    }

    fn expireDeadlines(self: *Launcher, now_ns: u64) void {
        if (self.egress.sending) |*sending| {
            if (now_ns >= sending.deadline_ns)
                self.failEgressSend("its control socket took nothing before the send deadline");
        }
        for (self.launches, 0..) |*slot, position| {
            const waiting = if (slot.*) |*launch| launch else continue;
            const index: u32 = @intCast(position);
            switch (waiting.state) {
                .queued, .awaiting_reattach => continue,
                .fork_requested => if (now_ns >= waiting.deadline_ns)
                    self.endFailed(index, .fork_reply_timeout),
                .init_sent => if (now_ns >= waiting.deadline_ns)
                    self.applyEffects(index, waiting.machine.?.onEvent(.child_deadline_expired)),
            }
        }
    }

    fn drainWake(self: *Launcher) void {
        var value: u64 = 0;
        _ = std.posix.read(self.wake.fd(), std.mem.asBytes(&value)) catch |err| switch (err) {
            error.WouldBlock => return,
            else => std.log.warn("launcher wake read failed: {s}", .{@errorName(err)}),
        };
    }

    /// The zygote's pidfd reported its exit. The outstanding fork request
    /// gets no reply; queued launches fail when their turn comes, and
    /// launches waiting for `WorkerReady` go on, since their children no
    /// longer need the zygote.
    fn zygoteExited(self: *Launcher) void {
        self.zygote_dead = true;
        self.zygote_exit_seen = true;
        if (self.forking) |index|
            self.endFailed(index, .zygote_died);
        std.log.err("the zygote exited; no worker can be launched", .{});
        self.deps.zygoteExited(self.deps.ctx);
    }

    fn receiveForkReply(self: *Launcher, index: u32) void {
        const launch = &self.launches[index].?;
        std.debug.assert(launch.state == .fork_requested);
        self.forking = null;
        var forked = zygote.host_client.receiveForkReply(self.zygote_process, launch.fork_job_id) catch |err|
            return self.endFailed(index, LaunchFailure.fromForkError(err));
        launch.trace.fork_reply_ns = process.monotonicNowNsOrZero();
        launch.trace.pid = forked.pid;
        forked.cgroup_dir_fd = launch.cgroup_dir.release();

        const definition = self.routes.definition(launch.definition);
        const artifact = self.routes.artifact(.{ .definition = launch.definition, .route = launch_route });
        // WorkerInit carries the worker's wake descriptors always, and the
        // session with its boot token or neither (`LaunchEgress` in
        // `host/launch.zig`). A session whose gateway was gone when its key
        // was read has no token, so the child boots detached and gets a
        // session of the current gateway at `WorkerReady`.
        var launch_egress: host.launch.LaunchEgress = .{ .detached = &launch.wake_set };
        // The machine takes a copy of the boot grant, which it scrubs once
        // the token is minted, and this frame keeps none.
        defer switch (launch_egress) {
            .attached => |*attached| std.crypto.secureZero(u8, &attached.boot.key.bytes),
            .detached => {},
        };
        if (launch.egress) |*attached| {
            if (attached.boot) |*boot| {
                launch_egress = .{ .attached = .{
                    .shared_fds = egressSharedFds(&attached.attachment),
                    .boot = boot.*,
                } };
            }
        }
        launch.machine = host.launch.Machine.init(
            self.gpa,
            self.zygote_process,
            definition.settings.limits.memoryBytes(),
            .{
                .egress = launch_egress,
                .route_bindings = artifact.bindings,
                .tmpfs_size_bytes = self.tmpfs_size_bytes,
                .cpu_max_cores = launch_cpu_max_cores,
                .boot = self.boot,
                .route_entry = .{
                    .fd = artifact.module_pack.fd(),
                    .specifier = artifact.entry_specifier,
                },
                .fs_index_memfd = artifact.fs_index.fd(),
            },
        );
        const result = launch.machine.?.start(&forked);
        // `start` took every descriptor `forked` held, and the child holds
        // its own copies of the session's descriptors once WorkerInit went
        // out, so the server's copies close either way, and the boot token
        // is minted, so its key goes too.
        forked.deinit();
        if (launch.egress) |*egress|
            egress.deinit();
        launch.egress = null;
        if (launch.machine.?.phase == .awaiting_ready) {
            launch.state = .init_sent;
            launch.deadline_ns = launch.machine.?.child_init_deadline_abs_ns;
            launch.trace.init_sent_ns = process.monotonicNowNsOrZero();
        }
        self.applyEffects(index, result);
    }

    /// Acts on what the launch's machine reported. The launcher polls the
    /// init socket and the pidfd of every launch waiting for `WorkerReady`,
    /// so the arm effects need nothing more.
    fn applyEffects(self: *Launcher, index: u32, result: host.launch.StepResult) void {
        for (result.effects[0..result.count]) |effect| switch (effect) {
            .none, .arm_init_poll, .arm_pidfd_poll => {},
            .report_ready => return self.onReady(index),
            .report_failed => |err| return self.endFailed(index, LaunchFailure.fromLaunchError(err)),
            // Every launch passes `fault_serve = .none`, so the machine never
            // serves boot faults and never asks for these.
            .arm_fault_poll, .start_fault_drain_job, .arm_grace_timer => unreachable,
        };
    }

    /// The child reported `WorkerReady`. A launch whose session's gateway is
    /// still current ends its boot token and publishes; one whose gateway
    /// was lost since its attach, or whose session the gateway removed
    /// (`dropLostSession` left its generation 0), waits for a turn of
    /// `stepEgress`, which attaches the worker to the current gateway first.
    fn onReady(self: *Launcher, index: u32) void {
        const launch = &self.launches[index].?;
        const machine = &launch.machine.?;
        launch.trace.ready_received_ns = machine.ready_received_ns;
        launch.trace.spans = machine.spans;
        if (machine.metrics) |*metrics| {
            for (&launch.trace.child_stamps, 0..) |*stamp, phase|
                stamp.* = metrics.loadBootPhaseStampNs(@enumFromInt(@as(u32, @intCast(phase))));
        }
        // Lanes send on this socket and read it from their io_uring loops,
        // which must never block on one worker, so its server end stops
        // blocking here, once for the worker's life.
        fd_mod.setNonblocking(machine.worker_init_fd, true) catch |err| {
            std.log.warn("worker control socket could not be made non-blocking: {s}", .{@errorName(err)});
            return self.endFailed(index, .control_socket);
        };
        if (launch.egress_session_id != 0) {
            const lost = launch.egress_generation == 0 or
                launch.egress_generation != self.deps.egressCurrentGeneration(self.deps.ctx);
            if (lost) {
                launch.state = .awaiting_reattach;
                return;
            }
            // The boot window ends at `WorkerReady`, so the boot token is
            // ended before any request can reach the worker.
            self.deps.egressBootEnded(self.deps.ctx, launch.egress_generation, launch.egress_session_id);
        }
        self.publishReady(index);
    }

    fn publishReady(self: *Launcher, index: u32) void {
        const launch = &self.launches[index].?;
        const handle = launch.machine.?.takeHandle() catch |err|
            return self.endFailed(index, LaunchFailure.fromLaunchError(err));
        launch.machine = null;
        const definition = launch.definition;
        const ready: ReadyWorker = .{
            .handle = handle,
            .egress_wake_set = launch.wake_set,
            .egress_generation = launch.egress_generation,
            .egress_session_id = launch.egress_session_id,
            .dispatch_send_scratch = launch.dispatch_send_scratch,
            .boot_work_ns = childBootWorkNs(&launch.trace.child_stamps),
        };
        launch.dispatch_send_scratch = &.{};
        launch.wake_set = .{};
        self.deps.publish(self.deps.ctx, definition, launch.ticket, ready);

        launch.trace.outcome = .published;
        launch.trace.published_ns = process.monotonicNowNsOrZero();
        self.traces.push(launch.trace);
        self.launches[index] = null;
        self.in_flight -= 1;
        self.noteCounter("published");
        // The worker served at most `concurrency` waiters, and the ones
        // beyond them submit nothing more, so the pool is asked again.
        self.deferred.set(definition);
    }

    /// Ends a launch without a worker: releases what the launch holds,
    /// hands its child and leaf to `Deps.failed` and frees its entry.
    fn endFailed(self: *Launcher, index: u32, failure: LaunchFailure) void {
        const launch = &self.launches[index].?;
        var leftovers: Leftovers = .{};
        // What failed the child's init, which only the machine knows.
        var init_failure: ?host.launch.InitFailure = null;
        if (launch.machine) |*machine| {
            init_failure = machine.init_failure;
            leftovers.child = machine.abandon();
            launch.machine = null;
        }
        // A leaf the machine never took: the fork request failed or got no
        // reply, and a child born into the leaf meanwhile dies with it.
        if (launch.cgroup_dir.isValid()) {
            std.debug.assert(!leftovers.child.cgroup_dir.isValid());
            leftovers.child.cgroup_dir = launch.cgroup_dir;
            launch.cgroup_dir = .{};
        }
        if (launch.egress) |*egress| {
            egress.deinit();
            launch.egress = null;
        }
        launch.wake_set.deinit();
        if (launch.dispatch_send_scratch.len != 0) {
            self.gpa.free(launch.dispatch_send_scratch);
            launch.dispatch_send_scratch = &.{};
        }
        if (self.forking == index)
            self.forking = null;
        if (failure.endsZygote())
            self.loseZygote(launch.fork_job_id, failure);

        if (failure != .stopping) {
            const name = self.routes.definition(launch.definition).name;
            if (init_failure) |cause| {
                std.log.warn("launch of {s} failed: {s}, {f}", .{ name, @tagName(failure), cause });
            } else {
                std.log.warn("launch of {s} failed: {s}", .{ name, @tagName(failure) });
            }
        }
        if (leftovers.holdsChild())
            _ = self.leftovers_held.fetchAdd(1, .acq_rel);
        self.deps.failed(self.deps.ctx, launch.definition, launch.ticket, failure, leftovers);

        launch.trace.outcome = .failed;
        launch.trace.failure = failure;
        self.traces.push(launch.trace);
        self.launches[index] = null;
        self.in_flight -= 1;
        self.noteCounter("failed");
    }

    /// No fork request may follow a failure that ends the zygote. The zygote
    /// is killed so that its pidfd reports the exit, which stops the server,
    /// even when it lingers after losing its control socket.
    fn loseZygote(self: *Launcher, fork_job_id: u64, failure: LaunchFailure) void {
        self.zygote_dead = true;
        switch (failure) {
            .fork_reply_timeout => zygote.host_client.killUnresponsiveZygote(self.zygote_process, fork_job_id),
            else => process.pidFdSendSignal(self.zygote_process.pidfd, std.posix.SIG.KILL) catch |err| switch (err) {
                error.ProcessNotFound => {},
                else => std.log.warn("failed to kill the zygote after {s}: {s}", .{ @tagName(failure), @errorName(err) }),
            },
        }
    }
};

/// Bounded ring of finished launches that drops the oldest when full. The
/// launcher thread pushes once per launch; readers take under the same
/// mutex.
const TraceRing = struct {
    mutex: std.Thread.Mutex = .{},
    entries: []LaunchTrace,
    head: usize = 0,
    len: usize = 0,

    fn push(self: *TraceRing, trace: LaunchTrace) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.len == self.entries.len) {
            // Drop the oldest: a benchmark run wants the tail of what just
            // ran, not the first launches of the process.
            self.entries[self.head] = trace;
            self.head = (self.head + 1) % self.entries.len;
            return;
        }
        self.entries[(self.head + self.len) % self.entries.len] = trace;
        self.len += 1;
    }

    fn take(self: *TraceRing, out: []LaunchTrace) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        const count = @min(out.len, self.len);
        for (out[0..count], 0..) |*slot, offset|
            slot.* = self.entries[(self.head + offset) % self.entries.len];
        self.head = 0;
        self.len = 0;
        return count;
    }
};

/// The worker's half of `attachment`, its regions and wake descriptors, as
/// `WorkerInit` and `egress_attach` carry it.
fn egressSharedFds(attachment: *const lifecycle.EgressGatewayAttachment) ipc.egress_shared.RawFds {
    return .{
        .command_control_fd = attachment.command_control.fd(),
        .command_producer_fd = attachment.command_producer.fd(),
        .command_consumer_fd = attachment.command_consumer.fd(),
        .command_data_fd = attachment.command_data.fd(),
        .completion_control_fd = attachment.completion_control.fd(),
        .completion_producer_fd = attachment.completion_producer.fd(),
        .completion_consumer_fd = attachment.completion_consumer.fd(),
        .completion_data_fd = attachment.completion_data.fd(),
        .body_pool_control_fd = attachment.body_pool_control.fd(),
        .body_pool_producer_fd = attachment.body_pool_producer.fd(),
        .body_pool_consumer_fd = attachment.body_pool_consumer.fd(),
        .body_pool_data_fd = attachment.body_pool_data.fd(),
        .upload_pool_control_fd = attachment.upload_pool_control.fd(),
        .upload_pool_producer_fd = attachment.upload_pool_producer.fd(),
        .upload_pool_consumer_fd = attachment.upload_pool_consumer.fd(),
        .upload_pool_data_fd = attachment.upload_pool_data.fd(),
        .command_eventfd = attachment.command_event.fd(),
        .completion_eventfd = attachment.completion_event.fd(),
        .liveness_fd = attachment.liveness.fd(),
        .peer_liveness_fd = attachment.peer_liveness.fd(),
    };
}

/// The span from the child entering its namespaces to its sending
/// `WorkerReady`, by the boot stamps it wrote on its page; 0 when either
/// stamp is missing.
fn childBootWorkNs(stamps: *const [worker_shared_page.BOOT_PHASE_COUNT]u64) u64 {
    const entered = stamps[@intFromEnum(worker_shared_page.BootPhase.namespaces_entered)];
    const ready = stamps[@intFromEnum(worker_shared_page.BootPhase.ready_sent)];
    if (entered == 0 or ready == 0)
        return 0;
    return ready -| entered;
}

fn msToNs(milliseconds: i32) u64 {
    std.debug.assert(milliseconds >= 0);
    return @as(u64, @intCast(milliseconds)) * std.time.ns_per_ms;
}

// The boot inputs, read from the server's own environment once at boot.
// `COLLO_DEBUG` also enables the boot trace in `server/boot/trace_drain.zig`.

const tmpfs_size_env = "COLLO_WORKER_FS_TMPFS_MIB";

/// The boot options every worker receives in WorkerInit: the defaults with
/// the environment's overrides applied. A malformed number keeps its default;
/// a combination `WorkerRuntimeBootOptions.validate` rejects fails the call.
pub fn resolveWorkerRuntimeBootOptions() error{InvalidBootOptions}!ipc.WorkerRuntimeBootOptions {
    var options = ipc.WorkerRuntimeBootOptions.default();
    options.crypto_thread_count = envCryptoThreadCount(
        "COLLO_WORKER_CRYPTO_THREADS",
        options.crypto_thread_count,
    );
    options.crypto_thread_stack_bytes = envU64(
        "COLLO_WORKER_CRYPTO_THREAD_STACK_KIB",
        options.crypto_thread_stack_bytes / 1024,
    ) *| 1024;
    options.crypto_max_in_flight_per_request = envU64(
        "COLLO_WORKER_CRYPTO_MAX_PENDING_PER_REQUEST",
        options.crypto_max_in_flight_per_request,
    );
    options.crypto_max_in_flight_per_worker = options.deriveCryptoMaxInFlightPerWorker();
    options.runtime_flags |= resolveTraceRuntimeFlags(
        hasEnv("COLLO_BENCH_TRACE_REQUEST"),
        hasEnv("COLLO_BENCH_TRACE_ALL_REQUESTS"),
    );
    if (envFlagEnabled("COLLO_BENCH_HANDLER"))
        options.runtime_flags |= ipc.WorkerRuntimeBootOptions.flag_bench_handler;
    options.runtime_flags |= resolveFullJsExceptionRuntimeFlags(
        hasEnv("COLLO_LOG_FULL_JS_EXCEPTIONS") or envFlagEnabled("COLLO_DEBUG"),
        builtin.mode == .Debug,
    );
    options.validate() catch return error.InvalidBootOptions;
    return options;
}

/// The tmpfs size the environment asks for, or null for the launch default.
/// The launch clamps whatever this returns to the worker's memory limit.
pub fn resolveWorkerTmpfsSizeBytes() ?u64 {
    const requested_mib = envU64(tmpfs_size_env, 0);
    if (requested_mib == 0)
        return null;
    return std.math.mul(u64, requested_mib, 1024 * 1024) catch null;
}

pub fn resolveTraceRuntimeFlags(trace_request: bool, trace_all_requests: bool) u32 {
    var flags: u32 = 0;
    if (trace_request)
        flags |= ipc.WorkerRuntimeBootOptions.flag_trace_requests;
    if (trace_all_requests)
        flags |= ipc.WorkerRuntimeBootOptions.flag_trace_all_requests;
    return flags;
}

pub fn resolveFullJsExceptionRuntimeFlags(requested: bool, debug_build: bool) u32 {
    if (!requested and !debug_build)
        return 0;
    return ipc.WorkerRuntimeBootOptions.flag_log_full_js_exceptions;
}

fn envCryptoThreadCount(name: [:0]const u8, default_value: u64) u64 {
    const value = std.posix.getenv(name) orelse return default_value;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "auto"))
        return ipc.WorkerRuntimeBootOptions.default().crypto_thread_count;
    const parsed = std.fmt.parseInt(u64, trimmed, 10) catch return default_value;
    return @min(parsed, ipc.WorkerRuntimeBootOptions.max_crypto_thread_count);
}

fn envU64(name: [:0]const u8, default_value: u64) u64 {
    const value = std.posix.getenv(name) orelse return default_value;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return std.fmt.parseInt(u64, trimmed, 10) catch default_value;
}

fn hasEnv(name: [:0]const u8) bool {
    return std.posix.getenv(name) != null;
}

/// True only for the value `1`, as `COLLO_BOOT_TRACE` reads, so that
/// `COLLO_DEBUG=0` stays inert.
fn envFlagEnabled(name: [:0]const u8) bool {
    const value = std.posix.getenv(name) orelse return false;
    return std.mem.eql(u8, std.mem.trim(u8, value, " \t\r\n"), "1");
}

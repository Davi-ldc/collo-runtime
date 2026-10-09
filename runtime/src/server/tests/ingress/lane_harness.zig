//! A whole ingress lane driven from the test thread, for the suites that need
//! the lane's own handlers: `worker_faults.zig`, `lane_commands.zig`,
//! `lane_connections.zig`, `lane_ring.zig`, `request_deadlines.zig`,
//! `completion_ring.zig`, `fs_fault.zig` and `egress_tokens.zig`. Not a
//! suite of its own.
//!
//! Each lane is a `runner.LaneWorker` over `TestService`, which stands in for
//! the ingress service: it holds the fixture supervisor and the lanes, posts
//! a command to its lane through `LaneWorker.post` as the service does, and
//! records instead of running what the launcher and the reaper are asked to
//! do, along with every `worker_died` one lane tells another. No lane thread
//! runs. A test writes the bytes a client or a worker sends, then calls the
//! loop handler the lane's event loop would call for them
//! (`fault.loop_handlers` in `server/ingress/fault.zig`), so every outcome is
//! read back deterministically: the handler's return, the frames the client
//! reads, the commands waiting in a lane's queue, the deadlines in its wheel,
//! the worker's entry in its pool and the retirements queued to the reaper.
//! A lane still owns its ring (`event_sources.LaneRing`), because its
//! handlers prepare polls and closes on it, and the harness discards the
//! completions those post.
//!
//! Each of those calls is one pass of the loop: after the handler, the
//! harness runs what the loop runs after the completions of a pass, the
//! connections the handler queued for a turn and the worker faults it
//! deferred (`ring_driver.runQueuedWork`), and ends the pass with the ring's
//! one submit, as the loop does.
//!
//! A client connection sits in a lane connection slot already in HTTP/2
//! state, over a socketpair with no TLS. A stub worker is a real worker handle
//! published into the fixture supervisor's pool, whose other ends the test
//! holds: the worker's end of its control and fault sockets, its own mappings
//! of the shared state page and of the payload rings, and a child process
//! that waits until the test kills it, so the worker's pidfd reports an exit
//! only then.
//!
//! The lane reads CLOCK_MONOTONIC. A test moves a request past its deadline
//! with `expireDeadlines`, which runs the lane's deadline sweep at a time the
//! test chooses. An answer the lane decides against the clock itself, such as
//! the 504 of a request whose deadline has passed, needs the clock past that
//! deadline: such a test gives its requests a deadline of milliseconds and
//! waits for it (`waitUntilClockPasses`).
//!
//! The egress gateway is `EgressGateways`, which a test installs and moves
//! by hand; until it does, no gateway is current and every dispatch carries
//! no egress token. A pass's lease renewal runs only when a test calls
//! `renewEgressLease`.

const std = @import("std");
const linux = std.os.linux;
const server_main = @import("collo_server_main");
const supervision = @import("collo_server_supervisor");
const gateway = @import("collo_server_gateway");
const analytics = @import("collo_server_analytics");
const config = @import("collo_server_config");
const routes_mod = @import("collo_server_routes");
const lifecycle = @import("collo_server_lifecycle");
const host = @import("collo_host");
const ipc = @import("collo_ipc");
const os = @import("collo_os");
const worker_state = @import("collo_worker_state");
const h2 = @import("collo_http").http2;
const hpack = @import("collo_hpack");

pub const fixture = @import("supervisor_fixture");
pub const ingress = server_main.ingress;
pub const runner = ingress.runner;
pub const fault = ingress.fault;
pub const commands = ingress.commands;
pub const lane_commands = ingress.lane_commands;
pub const pool = supervision.pool;
pub const page = worker_state.page;
pub const ingress_channel = ipc.ingress_channel;

pub const Supervisor = supervision.Supervisor;
pub const WorkerPool = supervision.WorkerPool;
pub const WorkerRecord = supervision.worker_table.Record;
pub const RetireReason = supervision.reaper.RetireReason;
pub const Lane = runner.LaneWorker(TestService);
pub const CommandTag = std.meta.Tag(commands.Command);

/// Lanes one harness runs.
pub const lanes_max: usize = 2;
/// Stub workers and client connections one harness tracks.
pub const stubs_max: usize = 4;
pub const clients_max: usize = 4;
/// Streams one client tracks, by stream id.
const client_streams_max: usize = 16;
/// Bytes a client keeps of what the lane wrote and it has not parsed yet:
/// one frame of the lane's largest size and room for the frames around it.
const client_inbox_bytes: usize = 256 * 1024;
/// The descriptor count a raw send may carry, one past what one receive
/// holds (`ipc.max_fds_per_message`).
pub const raw_descriptors_max: usize = ipc.max_fds_per_message + 1;
/// How long a test waits for a stub worker's process to exit once killed.
const child_exit_wait_ms: i32 = 5_000;
/// Commands a test reads from one lane's queue at once, far above the few a
/// lane test leaves waiting.
pub const queued_commands_max: usize = 16;
/// Waiters one `takeStranded` call hands over; `strandWaiters` calls again
/// until a call returns fewer.
const stranded_batch_max: usize = 32;
/// Sleeps `waitUntilClockPasses` takes before it gives up. A sleep lasts at
/// least as long as asked, so the first one normally passes the deadline.
const clock_naps_max: usize = 8;
/// The fixture's limits, whose values a scene keeps unless a test asks for
/// others.
const default_routes: fixture.RoutesOptions = .{};
/// The authority every client request names; the route table matches the
/// path alone.
pub const authority = "demo.example.test";

/// The definition stub workers serve unless a test names another, with a
/// path its route matches.
pub const default_definition: config.DefinitionIndex = fixture.default_definition;
pub const default_path = "/demo/request";

/// The key a lease holds while no gateway is current.
const no_egress_key: ipc.egress_token.Key = .{ .bytes = @splat(0) };

/// The egress gateway manager as a lane reads it at the start of a pass
/// (`currentGeneration` and `renewLease`, which `Manager` in
/// `server/gateway/manager.zig` answers in service). No gateway is current
/// until a test calls `install`. An installed gateway is a socket pair: each
/// renewal hands the lease a dup of `lease_end`, as the manager dups the
/// gateway's control socket, and the test reads the lanes' `request_ended`
/// batches from `gateway_end`.
pub const EgressGateways = struct {
    generation: u64 = 0,
    key: ipc.egress_token.Key = no_egress_key,
    lease_end: os.fd.OwnedFd = .{},
    gateway_end: os.fd.OwnedFd = .{},
    /// Every `renewLease` call, including the ones that change nothing.
    renewals: u32 = 0,
    /// Renewals whose dup failed, which empty the lease as the manager's do.
    renewals_failed: u32 = 0,

    pub fn deinit(self: *EgressGateways) void {
        self.lease_end.deinit();
        self.gateway_end.deinit();
        self.* = undefined;
    }

    pub fn currentGeneration(self: *const EgressGateways) u64 {
        return self.generation;
    }

    /// What `Manager.renewLease` does: hands `lease` the current gateway,
    /// keeps a lease that already holds it, and empties it while no gateway
    /// is current.
    pub fn renewLease(self: *EgressGateways, lease: *gateway.lease.Lease) void {
        self.renewals += 1;
        if (self.generation == 0) {
            if (lease.generation != 0)
                lease.replace(0, no_egress_key, .{});
            return;
        }
        if (lease.generation == self.generation)
            return;
        const control = os.fd.OwnedFd.dupCloexec(self.lease_end.fd()) catch {
            self.renewals_failed += 1;
            lease.replace(0, no_egress_key, .{});
            return;
        };
        lease.replace(self.generation, self.key, control);
    }

    /// Makes gateway `generation` current under `key`, over a new
    /// nonblocking socket pair. The previous gateway's ends close, so a lease
    /// that still holds a dup of its socket sends to nobody.
    pub fn install(self: *EgressGateways, generation: u64, key: ipc.egress_token.Key) !void {
        std.debug.assert(generation != 0);
        const pair = try os.fd.socketPairType(
            std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK,
        );
        self.lease_end.deinit();
        self.gateway_end.deinit();
        self.gateway_end = .fromRaw(pair[0]);
        self.lease_end = .fromRaw(pair[1]);
        self.generation = generation;
        self.key = key;
    }

    /// Leaves no gateway current, as the manager does when it retires its
    /// gateway, and closes the gateway's ends.
    pub fn retire(self: *EgressGateways) void {
        self.lease_end.deinit();
        self.gateway_end.deinit();
        self.generation = 0;
        self.key = no_egress_key;
    }
};

/// What a lane reads from the ingress service. The methods that carry a
/// pool's results to the lanes (`postToLane`, `postHandoff`, `strandWaiters`,
/// `queueRetirement`) do what `Service`'s methods of the same names do in
/// `server/ingress/service_deps.zig`, over the launcher and reaper doubles.
pub const TestService = struct {
    allocator: std.mem.Allocator,
    supervisor: *Supervisor,
    egress_gateways: *EgressGateways,
    routes: *const routes_mod.Routes,
    analytics: *analytics.Sink,
    hard_timeout_grace_ns: u64,
    /// Read only on the accept path, which the harness never runs: its
    /// connections arrive past the handshake. A test that runs the stop drain
    /// (`handleStop`) compiles that path without reaching it.
    ingress_tcp_notsent_lowat_bytes: u32 = 0,
    tls_context: *server_main.tls.BoringSslContext = undefined,
    lanes: []Lane,
    launcher: *Launcher,
    reaper: *Reaper,
    /// Where `postToLane` records each `worker_died` a lane accepted.
    deaths: *DeathNotices,
    stop_requested: std.atomic.Value(bool) = .init(false),
    next_request_id: std.atomic.Value(u64) = .init(1),

    /// A post that reaches no lane, as `Service.PostError`.
    pub const PostError = error{ InvalidLaneId, CommandEventfdCorrupt };

    pub fn shouldStop(self: *const TestService) bool {
        return self.stop_requested.load(.acquire);
    }

    /// Only a lane fault stops a lane, and with it the server, so a test
    /// whose lane keeps running checks that nothing called this.
    pub fn requestStopSignal(self: *TestService) void {
        self.stop_requested.store(true, .release);
    }

    pub fn allocateRequestId(self: *TestService) u64 {
        return self.next_request_id.fetchAdd(1, .monotonic);
    }

    /// Posts `command` to lane `lane_id` through `LaneWorker.post`, which
    /// consumes it on every path. False when that lane's queue is full for
    /// it or the lane is not running.
    pub fn postToLane(self: *TestService, lane_id: pool.LaneId, command: commands.Command) PostError!bool {
        if (lane_id >= self.lanes.len) {
            var refused = command;
            refused.deinit();
            return error.InvalidLaneId;
        }
        // Read before the post, which consumes the command.
        const notice: ?commands.WorkerDied = switch (command) {
            .worker_died => |died| died,
            else => null,
        };
        const posted = try self.lanes[lane_id].post(command);
        if (posted) {
            if (notice) |died| self.deaths.add(died);
        }
        return posted;
    }

    /// Raises wake bit `bit` on lane `lane_id` through `LaneWorker.raiseWake`,
    /// as the service does.
    pub fn raiseLaneWake(self: *TestService, lane_id: pool.LaneId, bit: u32) PostError!void {
        if (lane_id >= self.lanes.len)
            return error.InvalidLaneId;
        try self.lanes[lane_id].raiseWake(bit);
    }

    /// Posts `dispatch_ready` for a slot a pool handed to a waiting request.
    /// A lane that refuses it gives the slot back at once with the grant it
    /// carried (`Pool.returnHandoff`), and a slot handed on again posts
    /// again; each turn takes a waiter out of the pool's FIFO.
    pub fn postHandoff(self: *TestService, first: WorkerPool.Handoff) (PostError || error{SlotNotHeld})!void {
        var next: ?WorkerPool.Handoff = first;
        while (next) |handoff| {
            next = null;
            const posted = try self.postToLane(handoff.waiter.lane, .{ .dispatch_ready = .{
                .request_key = handoff.waiter.request_key,
                .worker_key = handoff.worker.key(),
                .worker = handoff.worker,
                .slot = handoff.slot,
                .reader = handoff.reader,
            } });
            if (posted)
                return;
            const worker_pool = self.supervisor.poolFor(handoff.worker.definition_index);
            switch (try worker_pool.returnHandoff(
                handoff.worker,
                handoff.slot,
                handoff.waiter.lane,
                handoff.reader,
                os.process.monotonicNowNsOrZero(),
            )) {
                .idle => {},
                .handed_to => |again| next = again,
                .retire => self.queueRetirement(handoff.worker),
            }
        }
    }

    /// Posts `dispatch_failed` for `reason` to the lane of each waiter of
    /// `definition`'s pool that nothing can serve, because no worker is live
    /// and no launch is in flight (`Pool.takeStranded`).
    pub fn strandWaiters(
        self: *TestService,
        definition: config.DefinitionIndex,
        reason: lane_commands.DispatchFailed.Reason,
    ) PostError!void {
        const worker_pool = self.supervisor.poolFor(definition);
        var batch: [stranded_batch_max]pool.Waiter = undefined;
        while (true) {
            const stranded = worker_pool.takeStranded(&batch);
            for (stranded) |waiter| {
                _ = try self.postToLane(waiter.lane, .{ .dispatch_failed = .{
                    .request_key = waiter.request_key,
                    .reason = reason,
                } });
            }
            if (stranded.len < batch.len)
                return;
        }
    }

    /// Queues the retirement of `worker`, which a pool call answered
    /// `.retire` for, to the reaper double.
    pub fn queueRetirement(self: *TestService, worker: *WorkerRecord) void {
        const worker_pool = self.supervisor.poolFor(worker.definition_index);
        const idle = if (worker_pool.inspect(worker)) |view| view.state == .retiring else false;
        self.reaper.queueRetirement(worker, if (idle) .idle else .died);
    }
};

/// The `worker_died` commands lanes accepted from each other, oldest first.
pub const DeathNotices = struct {
    notices: [notices_max]commands.WorkerDied = undefined,
    count: usize = 0,

    const notices_max: usize = 16;

    pub fn add(self: *DeathNotices, notice: commands.WorkerDied) void {
        if (self.count < self.notices.len)
            self.notices[self.count] = notice;
        self.count += 1;
    }

    /// The reason the latest notice of `worker_key`'s death gives, null when
    /// no lane was told of it.
    pub fn reasonOf(self: *const DeathNotices, worker_key: lifecycle.WorkerKey) ?fault.WorkerFaultReason {
        var reason: ?fault.WorkerFaultReason = null;
        for (self.notices[0..@min(self.count, self.notices.len)]) |notice| {
            if (notice.worker_key.eql(worker_key))
                reason = notice.reason;
        }
        return reason;
    }
};

/// Records the launches lanes submit; nothing forks.
pub const Launcher = struct {
    submissions: [submissions_max]Submission = undefined,
    submission_count: usize = 0,

    const submissions_max: usize = 16;

    pub const Submission = struct {
        definition: config.DefinitionIndex,
        reason: supervision.launcher.GrowthReason,
    };

    pub fn submit(self: *Launcher, definition: config.DefinitionIndex, reason: supervision.launcher.GrowthReason) void {
        if (self.submission_count < self.submissions.len)
            self.submissions[self.submission_count] = .{ .definition = definition, .reason = reason };
        self.submission_count += 1;
    }
};

/// Records the retirements lanes queue. Nothing is killed or torn down, so
/// a retired stub worker's process stays as the test left it.
pub const Reaper = struct {
    retirements: [retirements_max]Retirement = undefined,
    retirement_count: usize = 0,
    /// Wakes a lane wrote after it gave up reading a worker.
    pidfd_scan_wakes: u32 = 0,
    /// The deaths lanes told each other of, and the lanes whose records of a
    /// worker's fault a retirement reads. `Harness.init` sets both.
    deaths: *const DeathNotices,
    lanes: []const Lane = &.{},

    const retirements_max: usize = 16;

    pub const Retirement = struct {
        worker_key: lifecycle.WorkerKey,
        reason: RetireReason,
        /// The fault the lanes had recorded for the worker when its
        /// retirement was queued, null when none had: the reason a lane's
        /// registration of the worker carries, or else the one the latest
        /// `worker_died` notice gave. A retirement carries no fault of its
        /// own.
        fault_reason: ?fault.WorkerFaultReason,
    };

    pub fn queueRetirement(self: *Reaper, worker: *WorkerRecord, reason: RetireReason) void {
        const worker_key = worker.key();
        if (self.retirement_count < self.retirements.len)
            self.retirements[self.retirement_count] = .{
                .worker_key = worker_key,
                .reason = reason,
                .fault_reason = self.faultRecordedFor(worker_key),
            };
        self.retirement_count += 1;
    }

    /// A lane keeps the reason of a worker's fault on its registration of
    /// the worker (`Registration.fault`) until it releases the registration,
    /// which a lane that read the worker does after it queues the
    /// retirement. A lane that only held a request releases it first, and
    /// learned the reason from a `worker_died` notice.
    fn faultRecordedFor(self: *const Reaper, worker_key: lifecycle.WorkerKey) ?fault.WorkerFaultReason {
        for (self.lanes) |*lane_runner| {
            for (lane_runner.registrations.touched()) |*registration| {
                if (!registration.inUse() or registration.worker == null) continue;
                if (!registration.worker_key.eql(worker_key)) continue;
                if (registration.fault) |recorded| return recorded;
            }
        }
        return self.deaths.reasonOf(worker_key);
    }

    pub fn wakeForPidfdScan(self: *Reaper) void {
        self.pidfd_scan_wakes += 1;
    }

    /// The retirements queued for `worker_key`, of which a worker gets one.
    pub fn retirementsOf(self: *const Reaper, worker_key: lifecycle.WorkerKey) usize {
        var count: usize = 0;
        for (self.retirements[0..@min(self.retirement_count, self.retirements.len)]) |retirement| {
            if (retirement.worker_key.eql(worker_key))
                count += 1;
        }
        return count;
    }

    pub fn retirementOf(self: *const Reaper, worker_key: lifecycle.WorkerKey) ?Retirement {
        for (self.retirements[0..@min(self.retirement_count, self.retirements.len)]) |retirement| {
            if (retirement.worker_key.eql(worker_key))
                return retirement;
        }
        return null;
    }
};

pub const Harness = struct {
    gpa: std.mem.Allocator,
    supervisor: Supervisor,
    egress_gateways: EgressGateways,
    /// Every `worker_died` a lane accepted from another, which
    /// `TestService.postToLane` records and the reaper double reads.
    deaths: DeathNotices,
    launcher: Launcher,
    reaper: Reaper,
    service: TestService,
    /// Heap memory, since every lane keeps a pointer to `service`.
    lanes: []Lane,
    rings: [lanes_max]runner.event_sources.LaneRing,
    lanes_started: u16,
    stubs: [stubs_max]?*StubWorker,
    clients: [clients_max]?*Client,

    pub const Options = struct {
        lane_count: u16 = 1,
        /// The limits every fixture definition gets: `concurrency` sets the
        /// slots of each stub worker.
        routes: fixture.RoutesOptions = .{},
        /// The capacities of each lane's tables, a serving lane's unless a
        /// test fills one.
        table_capacities: runner.TableCapacities = .{},
        /// Each lane's connection timeouts, a serving lane's unless a test
        /// shortens them.
        connection_timeouts: runner.deadline_driver.ConnectionTimeouts = .{},
    };

    /// Builds the harness in place, since every lane keeps a pointer to
    /// `service`.
    pub fn init(self: *Harness, gpa: std.mem.Allocator, options: Options) !void {
        if (options.lane_count == 0 or options.lane_count > lanes_max)
            return error.InvalidLaneCount;
        self.* = .{
            .gpa = gpa,
            .supervisor = undefined,
            .egress_gateways = .{},
            .deaths = .{},
            .launcher = .{},
            .reaper = .{ .deaths = &self.deaths },
            .service = undefined,
            .lanes = &.{},
            .rings = undefined,
            .lanes_started = 0,
            .stubs = @splat(null),
            .clients = @splat(null),
        };
        self.supervisor = try fixture.minimalSupervisorWith(gpa, .{ .routes = options.routes });
        errdefer fixture.deinitMinimal(&self.supervisor);
        self.lanes = try gpa.alloc(Lane, options.lane_count);
        errdefer gpa.free(self.lanes);
        // A lane not started yet holds no registration, which the reaper
        // double may read.
        for (self.lanes, 0..) |*lane_runner, index|
            lane_runner.* = .{ .listener_index = @intCast(index) };
        self.reaper.lanes = self.lanes;
        self.service = .{
            .allocator = gpa,
            .supervisor = &self.supervisor,
            .egress_gateways = &self.egress_gateways,
            .routes = self.supervisor.routes,
            .analytics = self.supervisor.analytics,
            .hard_timeout_grace_ns = self.supervisor.hard_timeout_grace_ns,
            .lanes = self.lanes,
            .launcher = &self.launcher,
            .reaper = &self.reaper,
            .deaths = &self.deaths,
        };
        errdefer self.stopLanes();
        while (self.lanes_started < options.lane_count) : (self.lanes_started += 1)
            try self.startLane(self.lanes_started, options);
    }

    /// Tears the lanes down first, which finishes every request still open as
    /// a shutdown, then the clients and the stub workers' own ends, and last
    /// the supervisor, which tears down every worker still in a pool.
    pub fn deinit(self: *Harness) void {
        self.stopLanes();
        for (&self.clients) |*entry| {
            if (entry.*) |client| client.destroy();
            entry.* = null;
        }
        for (&self.stubs) |*entry| {
            if (entry.*) |stub| stub.destroy();
            entry.* = null;
        }
        // A test reads a stopped lane's access records, so each ring goes
        // only now; a lane that never started holds an empty one.
        for (self.lanes) |*lane_runner|
            lane_runner.access_ring.deinit();
        self.gpa.free(self.lanes);
        self.egress_gateways.deinit();
        fixture.deinitMinimal(&self.supervisor);
        self.* = undefined;
    }

    fn startLane(self: *Harness, index: u16, options: Options) !void {
        const lane_runner = &self.lanes[index];
        lane_runner.* = try Lane.init(index, null);
        errdefer lane_runner.access_ring.deinit();
        lane_runner.table_capacities = options.table_capacities;
        lane_runner.connection_timeouts = options.connection_timeouts;
        lane_runner.service = &self.service;
        try runner.ring_driver.Methods(Lane).initLane(lane_runner);
        errdefer runner.ring_driver.Methods(Lane).deinitLane(lane_runner);
        self.rings[index] = try runner.event_sources.LaneRing.init();
        errdefer self.rings[index].deinit();
        try runner.ring_driver.Methods(Lane).initRuntime(lane_runner);
        lane_runner.runtime_ring = &self.rings[index];
        lane_runner.lane_state.store(@intFromEnum(runner.LaneRuntimeState.active), .release);
    }

    /// Tears every lane down as `run` leaves it, finishing each request still
    /// open as a shutdown. A test that reads what the teardown sent calls it
    /// before `deinit`, which then finds no lane left to stop.
    pub fn stopLanes(self: *Harness) void {
        while (self.lanes_started > 0) {
            self.lanes_started -= 1;
            const index = self.lanes_started;
            const lane_runner = &self.lanes[index];
            // As `run` leaves a lane: it takes no post, and its ring is gone
            // when `deinitRuntime` runs.
            lane_runner.lane_state.store(@intFromEnum(runner.LaneRuntimeState.exited), .release);
            lane_runner.runtime_ring = null;
            runner.ring_driver.Methods(Lane).deinitRuntime(lane_runner);
            self.rings[index].deinit();
            runner.ring_driver.Methods(Lane).deinitLane(lane_runner);
        }
    }

    pub fn lane(self: *Harness, index: u16) *Lane {
        return &self.lanes[index];
    }

    /// Drops the completions the lane's polls posted. A test calls the
    /// handlers those completions would have called itself, and an unread
    /// completion queue would eventually refuse new polls.
    pub fn discardPollCompletions(self: *Harness, index: u16) !void {
        var cqes: [64]linux.io_uring_cqe = undefined;
        while (try self.rings[index].copyCompletions(&cqes) != 0) {}
    }

    /// Ends the loop pass a handler call stands for: the connections the
    /// handler queued for a turn, then the worker faults it deferred, then
    /// the `request_ended` batch of the requests the pass finished, then the
    /// submit of what the pass prepared on the ring.
    pub fn finishPass(self: *Harness, index: u16) !void {
        _ = try runner.ring_driver.Methods(Lane).runQueuedWork(self.lane(index));
        try self.rings[index].submit();
    }

    /// Runs what a pass runs first: lane `index` renews its egress lease
    /// when the current gateway is not the one the lease holds.
    pub fn renewEgressLease(self: *Harness, index: u16) void {
        runner.ring_driver.Methods(Lane).renewEgressLease(self.lane(index));
    }

    /// Writes the stub worker's egress session into its record, as the
    /// launcher does once the worker is attached (`Supervisor.setWorkerEgress`),
    /// so the lanes mint its requests' tokens for session `session_id` of
    /// gateway `generation`.
    pub fn setWorkerEgress(self: *Harness, stub: *const StubWorker, generation: u64, session_id: u64) !void {
        const target: supervision.launcher.ReattachTarget = .{
            .definition = stub.definition,
            .record = stub.record,
            .worker_key = stub.key,
            .control = .{},
            .wake_set = .{},
        };
        if (!self.supervisor.setWorkerEgress(&target, generation, session_id))
            return error.WorkerLeftThePool;
    }

    /// Whether every lane is still serving: no lane asked the server to stop.
    pub fn expectLanesRunning(self: *Harness) !void {
        try std.testing.expect(!self.service.shouldStop());
    }

    /// Publishes a stub worker into its definition's pool: idle with no
    /// reader, into a pool that holds no free slot yet, or, with
    /// `options.launched`, handed to the requests waiting in the pool.
    pub fn publishWorker(self: *Harness, options: StubWorker.Options) !*StubWorker {
        const entry = for (&self.stubs) |*candidate| {
            if (candidate.* == null) break candidate;
        } else return error.TooManyStubWorkers;
        const stub = try StubWorker.create(self, options);
        entry.* = stub;
        return stub;
    }

    /// Opens a client connection on lane `lane_index` and runs the HTTP/2
    /// preface and both sides' SETTINGS.
    pub fn connect(self: *Harness, lane_index: u16, options: Client.Options) !*Client {
        const entry = for (&self.clients) |*candidate| {
            if (candidate.* == null) break candidate;
        } else return error.TooManyClients;
        const client = try Client.create(self, lane_index, options);
        entry.* = client;
        errdefer {
            entry.* = null;
            client.destroy();
        }
        try client.start();
        return client;
    }

    pub const OpenedConnection = struct {
        /// The client's end of the socket pair, which the caller owns.
        client_fd: std.posix.fd_t,
        key: lifecycle.ConnectionKey,
    };

    /// Takes a connection slot on lane `lane_index` for the server's end of a
    /// fresh socket pair, as an accepted socket's past its TLS handshake
    /// (`accept_flow.startConnection`), so the connection speaks HTTP/2 at
    /// once. The slot owns the server's end, which the lane's close or its
    /// teardown closes.
    pub fn openConnectionSlot(self: *Harness, lane_index: u16) !OpenedConnection {
        const lane_runner = self.lane(lane_index);
        const pair = try os.fd.socketPairType(std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK);
        errdefer std.posix.close(pair[1]);
        const acquired = lane_runner.connections.acquire() orelse {
            std.posix.close(pair[0]);
            return error.ConnectionSlabFull;
        };
        const key: lifecycle.ConnectionKey = .{
            .lane_id = lane_index,
            .slot = acquired.index,
            .generation = acquired.generation,
        };
        const runtime = acquired.entry;
        const now = os.process.monotonicNowNsOrZero();
        runtime.key = key;
        runtime.fd = pair[0];
        runtime.streams = &lane_runner.h2_lane.streams;
        runtime.state = .http2_connection;
        runtime.wait_events = runner.event_sources.read_events;
        runtime.accepted_ns = now;
        runtime.last_progress_ns = now;
        return .{ .client_fd = pair[1], .key = key };
    }

    /// Runs the handler the lane runs when the connection in `slot` is
    /// readable.
    pub fn driveConnection(self: *Harness, lane_index: u16, slot: u32) !void {
        try self.discardPollCompletions(lane_index);
        try self.lane(lane_index).handleConnectionReadable(slot);
        try self.finishPass(lane_index);
    }

    pub fn poolOf(self: *Harness, stub: *const StubWorker) *WorkerPool {
        return self.supervisor.poolFor(stub.definition);
    }

    /// The pool's view of the stub worker, null once it left the table.
    pub fn workerView(self: *Harness, stub: *const StubWorker) ?WorkerPool.WorkerView {
        return self.poolOf(stub).inspect(stub.record);
    }

    /// Lane `lane_index`'s registration of the stub worker, which exists
    /// while the lane reads the worker.
    pub fn registration(self: *Harness, lane_index: u16, stub: *const StubWorker) ?u32 {
        return runner.worker_registration.Methods(Lane).findCompletionRegistrationIndex(self.lane(lane_index), stub.key);
    }

    pub fn expectRegistration(self: *Harness, lane_index: u16, stub: *const StubWorker) !u32 {
        return self.registration(lane_index, stub) orelse error.WorkerNotRegistered;
    }

    /// Runs the handler the lane runs when the worker's control socket is
    /// readable.
    pub fn handleControl(self: *Harness, lane_index: u16, stub: *const StubWorker) !void {
        const index = try self.expectRegistration(lane_index, stub);
        try self.discardPollCompletions(lane_index);
        try self.lane(lane_index).handleWorkerControlReadable(index);
        try self.finishPass(lane_index);
    }

    /// Runs the handler the lane runs when the worker's control socket takes
    /// bytes again after a send would have blocked.
    pub fn handleControlWritable(self: *Harness, lane_index: u16, stub: *const StubWorker) !void {
        const index = try self.expectRegistration(lane_index, stub);
        try self.discardPollCompletions(lane_index);
        try self.lane(lane_index).handleWorkerControlWritable(index);
        try self.finishPass(lane_index);
    }

    /// Runs the handler the lane runs when the worker's completion eventfd is
    /// readable.
    pub fn handleCompletions(self: *Harness, lane_index: u16, stub: *const StubWorker) !void {
        const index = try self.expectRegistration(lane_index, stub);
        try self.discardPollCompletions(lane_index);
        try self.lane(lane_index).handleWorkerCompletions(index);
        try self.finishPass(lane_index);
    }

    /// The control socket, then the completion ring: the order the lane
    /// reads a worker in, so a request's descriptors precede its completion.
    pub fn serveWorker(self: *Harness, lane_index: u16, stub: *const StubWorker) !void {
        try self.handleControl(lane_index, stub);
        try self.handleCompletions(lane_index, stub);
    }

    pub fn handleFsFault(self: *Harness, lane_index: u16, stub: *const StubWorker) !void {
        const index = try self.expectRegistration(lane_index, stub);
        try self.discardPollCompletions(lane_index);
        try self.lane(lane_index).handleWorkerFsFault(index);
        try self.finishPass(lane_index);
    }

    pub fn handleCommands(self: *Harness, lane_index: u16) !void {
        try self.discardPollCompletions(lane_index);
        try self.lane(lane_index).handleCommands();
        try self.finishPass(lane_index);
    }

    /// Runs the handler the lane runs when the pidfd of a worker it reads
    /// reports that the worker's process exited.
    pub fn handleWorkerExit(self: *Harness, lane_index: u16, stub: *const StubWorker) !void {
        const index = try self.expectRegistration(lane_index, stub);
        try self.discardPollCompletions(lane_index);
        try self.lane(lane_index).handleWorkerPidfd(index);
        try self.finishPass(lane_index);
    }

    /// Runs lane `lane_index`'s deadline sweep as if the clock read `now_ns`.
    pub fn expireDeadlines(self: *Harness, lane_index: u16, now_ns: u64) !void {
        try self.discardPollCompletions(lane_index);
        _ = try runner.deadline_driver.processExpired(Lane, self.lane(lane_index), now_ns);
        try self.finishPass(lane_index);
    }

    /// A time past every deadline and backstop of a request admitted now.
    pub fn pastEveryDeadline(self: *Harness) u64 {
        const timeout_ns = self.supervisor.routes.definition(default_definition).settings.limits.timeoutNs();
        return os.process.monotonicNowNsOrZero() + timeout_ns + self.service.hard_timeout_grace_ns + std.time.ns_per_s;
    }

    /// The oldest access record lane `lane_index` pushed and nobody took yet.
    pub fn takeAccessRecord(self: *Harness, lane_index: u16) ?analytics.access.AccessRecord {
        var record: analytics.access.AccessRecord = undefined;
        if (!self.lane(lane_index).access_ring.pop(&record))
            return null;
        return record;
    }

    /// The status of the oldest access record lane `lane_index` pushed and
    /// nobody took yet.
    pub fn takeAccessStatus(self: *Harness, lane_index: u16) ?u16 {
        const record = self.takeAccessRecord(lane_index) orelse return null;
        return record.status;
    }

    /// The key of the request the lane of `client` admitted for stream
    /// `stream_id`, null once that request ended or if it never began.
    pub fn requestKeyOf(self: *Harness, client: *const Client, stream_id: u32) ?lifecycle.RequestKey {
        const request = self.requestSlotOf(client, stream_id) orelse return null;
        return request.request_key;
    }

    /// The slot of the request the lane of `client` admitted for stream
    /// `stream_id`, null once that request ended or if it never began.
    pub fn requestSlotOf(self: *Harness, client: *const Client, stream_id: u32) ?*const runner.request_slot.RequestSlot {
        for (self.lane(client.lane_index).requests.touched()) |*request| {
            if (!request.isLive()) continue;
            if (request.ingress_channel_id != stream_id) continue;
            if (!request.connection_key.eql(client.key)) continue;
            return request;
        }
        return null;
    }

    /// When lane `lane_index`'s deadline wheel fires for `request_key`, null
    /// when the wheel holds no entry for it. A request has one deadline, so a
    /// second entry fails with `error.TwoDeadlinesForOneRequest`.
    pub fn deadlineArmedFor(self: *Harness, lane_index: u16, request_key: lifecycle.RequestKey) !?u64 {
        var armed: ?u64 = null;
        for (self.lane(lane_index).lane.deadline_wheel.entries.touched()) |*entry| {
            if (!entry.slab_link.live) continue;
            if (!entry.request_key.eql(request_key)) continue;
            if (armed != null) return error.TwoDeadlinesForOneRequest;
            armed = entry.deadline_monotonic_ns;
        }
        return armed;
    }

    /// The entries lane `lane_index`'s deadline wheel holds, which are the
    /// only request timers a lane has.
    pub fn armedDeadlineCount(self: *Harness, lane_index: u16) usize {
        return self.lane(lane_index).lane.deadline_wheel.active_len;
    }

    /// Copies of the commands waiting in lane `lane_index`'s queue, oldest
    /// first, which stay queued: the queue still owns what they point at, so
    /// a test reads them and never frees them. Fails with
    /// `error.TooManyQueuedCommands` when `out` cannot hold them all.
    pub fn queuedCommands(self: *Harness, lane_index: u16, out: []commands.Command) ![]const commands.Command {
        const queue = &self.lane(lane_index).lane.command_queue;
        queue.mutex.lock();
        defer queue.mutex.unlock();
        if (queue.fifo.len > out.len)
            return error.TooManyQueuedCommands;
        var place = queue.fifo.head;
        for (out[0..queue.fifo.len]) |*command| {
            const node = &queue.nodes.entries[place];
            command.* = node.command;
            place = node.slab_link.queue_next;
        }
        return out[0..queue.fifo.len];
    }

    /// Asserts that lane `lane_index`'s queue holds commands of exactly the
    /// kinds `expected`, oldest first.
    pub fn expectQueued(self: *Harness, lane_index: u16, expected: []const CommandTag) !void {
        var buffer: [queued_commands_max]commands.Command = undefined;
        const queued = try self.queuedCommands(lane_index, &buffer);
        try std.testing.expectEqual(expected.len, queued.len);
        for (expected, queued) |tag, command|
            try std.testing.expectEqual(tag, std.meta.activeTag(command));
    }

    /// Asserts the stub worker is out of service with exactly one retirement
    /// queued, as a death, and that the retirement names `reason` when one is
    /// given (`Reaper.Retirement.fault_reason` says when it can).
    pub fn expectFaulted(self: *Harness, stub: *const StubWorker, reason: ?fault.WorkerFaultReason) !void {
        const view = self.workerView(stub) orelse return error.WorkerLeftThePool;
        try std.testing.expectEqual(pool.EntryState.dead, view.state);
        try std.testing.expectEqual(@as(usize, 1), self.reaper.retirementsOf(stub.key));
        const retirement = self.reaper.retirementOf(stub.key).?;
        try std.testing.expectEqual(RetireReason.died, retirement.reason);
        if (reason) |expected|
            try std.testing.expectEqual(@as(?fault.WorkerFaultReason, expected), retirement.fault_reason);
    }

    /// Asserts the stub worker is in service with no retirement queued.
    pub fn expectServing(self: *Harness, stub: *const StubWorker) !void {
        const view = self.workerView(stub) orelse return error.WorkerLeftThePool;
        try std.testing.expectEqual(pool.EntryState.live, view.state);
        try std.testing.expectEqual(@as(usize, 0), self.reaper.retirementsOf(stub.key));
    }
};

/// The common shape of a lane test: one lane, one stub worker of the default
/// definition, and one client connection on the lane. Built in place, like
/// the harness inside it.
pub const OneWorker = struct {
    harness: Harness,
    stub: *StubWorker,
    client: *Client,

    pub const Options = struct {
        /// Slots of the stub worker.
        concurrency: u8 = 2,
        /// Each request's deadline after its admission.
        timeout_ms: u32 = default_routes.timeout_ms,
        control_send_buffer_bytes: ?u32 = null,
        initial_window_size: u32 = 1024 * 1024,
    };

    pub fn init(self: *OneWorker, options: Options) !void {
        try self.harness.init(std.testing.allocator, .{ .routes = .{
            .concurrency = options.concurrency,
            .timeout_ms = options.timeout_ms,
        } });
        errdefer self.harness.deinit();
        self.stub = try self.harness.publishWorker(.{ .control_send_buffer_bytes = options.control_send_buffer_bytes });
        self.client = try self.harness.connect(0, .{ .initial_window_size = options.initial_window_size });
    }

    pub fn deinit(self: *OneWorker) void {
        self.harness.deinit();
    }

    /// A GET on `stream_id`, as the stub worker received it.
    pub fn get(self: *OneWorker, stream_id: u32) !Dispatched {
        try self.client.get(stream_id);
        try self.client.drive();
        return self.stub.readRequestBegin();
    }

    /// A POST head on `stream_id` announcing `content_length` body bytes, as
    /// the stub worker received it.
    pub fn post(self: *OneWorker, stream_id: u32, content_length: usize) !Dispatched {
        try self.client.post(stream_id, content_length);
        try self.client.drive();
        return self.stub.readRequestBegin();
    }

    pub fn expectStatus(self: *OneWorker, stream_id: u32, status: u16) !void {
        try self.client.expectStatus(stream_id, status);
    }

    pub fn expectReset(self: *OneWorker, stream_id: u32) !void {
        try self.client.expectReset(stream_id);
    }

    /// The outcome every worker fault shares: the lanes keep serving, the
    /// worker is out of service with one retirement queued for `reason`, and
    /// the request on stream 1, whose head never went out, is answered 502
    /// with an access record that says so and names the fault.
    pub fn expectFaultAnswered(self: *OneWorker, reason: fault.WorkerFaultReason) !void {
        try self.harness.expectLanesRunning();
        try self.harness.expectFaulted(self.stub, reason);
        try self.expectStatus(1, 502);
        const record = self.harness.takeAccessRecord(0) orelse return error.AccessRecordMissing;
        try std.testing.expectEqual(@as(u16, 502), record.status);
        try std.testing.expectEqualStrings(reason.label(), record.facts.worker_fault);
    }
};

/// Two lanes sharing one stub worker of the default definition, with a
/// client connection on each. A test whose first request goes through lane 0
/// makes lane 0 the worker's reader (`Pool.acquire`), so the worker's output
/// for lane 1's requests reaches lane 1 through its queue. Built in place,
/// like the harness inside it.
pub const TwoLanes = struct {
    harness: Harness,
    stub: *StubWorker,
    /// The client connection on lane 0.
    first: *Client,
    /// The client connection on lane 1.
    second: *Client,

    pub const Options = struct {
        /// Slots of the stub worker: with 1, a request that arrives while
        /// another is in flight waits for its slot.
        concurrency: u8 = 2,
    };

    pub fn init(self: *TwoLanes, options: Options) !void {
        try self.harness.init(std.testing.allocator, .{
            .lane_count = 2,
            .routes = .{ .concurrency = options.concurrency },
        });
        errdefer self.harness.deinit();
        self.stub = try self.harness.publishWorker(.{});
        self.first = try self.harness.connect(0, .{});
        self.second = try self.harness.connect(1, .{});
    }

    pub fn deinit(self: *TwoLanes) void {
        self.harness.deinit();
    }

    /// A GET on stream `stream_id` of `client`, as the stub worker received
    /// it.
    pub fn get(self: *TwoLanes, client: *Client, stream_id: u32) !Dispatched {
        try client.get(stream_id);
        try client.drive();
        return self.stub.readRequestBegin();
    }
};

/// A request as the stub worker received it.
pub const Dispatched = struct {
    identity: ingress_channel.RequestIdentity,
    stream_id: u32,
    /// The request's body follows in chunk descriptors.
    body_follows: bool,
    deadline_monotonic_ns: u64,
    /// The token the worker presents in the request's fetches.
    egress_token: ipc.egress_token.Bytes,

    pub fn requestKey(self: Dispatched) lifecycle.RequestKey {
        return .{
            .lane_id = self.identity.request_lane_id,
            .slot = self.identity.request_slot,
            .generation = self.identity.request_generation,
        };
    }
};

/// How a stub worker ends a request on its shared page.
pub const Completion = struct {
    http_status: u16 = 200,
    done: ipc.RequestDoneStatus = .ok,
    /// The worker generation the record names; the worker's own by default.
    worker_generation: ?u64 = null,
};

/// The request body a stub worker read, appended to its caller's buffer.
pub const Body = struct {
    len: usize = 0,
    ended: bool = false,
};

/// The worker side of one published worker. The handle with the server's
/// ends belongs to the supervisor's record from the publish on; the stub
/// owns the worker's ends and its process.
pub const StubWorker = struct {
    harness: *Harness,
    record: *WorkerRecord,
    key: lifecycle.WorkerKey,
    definition: config.DefinitionIndex,
    child_pid: std.posix.pid_t,
    /// The test's own pidfd of the worker's process.
    child_pidfd: os.fd.OwnedFd,
    child_reaped: bool = false,
    /// The worker's end of its control socket, nonblocking; -1 once closed.
    control: std.posix.fd_t,
    /// The worker's end of its fault socket, nonblocking.
    fault: std.posix.fd_t,
    /// The worker's own mappings of its state page and payload rings.
    page_view: page.WorkerWriterView,
    payload: ingress_channel.SharedPayloadView,
    recv_scratch: []u8,
    send_scratch: []u8,

    pub const Options = struct {
        definition: config.DefinitionIndex = default_definition,
        /// SO_SNDBUF of the server's end of the control socket, the kernel
        /// default when null. The kernel doubles the value; a send of a
        /// packet larger than the buffer fails outright instead of waiting,
        /// so it must stay above the largest packet the lane sends.
        control_send_buffer_bytes: ?u32 = null,
        /// Published as the launch that requests waiting in the pool asked
        /// for, created now, so the publish hands its slots to them and each
        /// one's lane gets `dispatch_ready`. Otherwise the pool must be quiet
        /// (`supervisor_fixture.publishWorker`) and the worker is idle.
        launched: bool = false,
        /// The worker's own boot, which a request that rode its launch
        /// reports as its cold start.
        boot_work_ns: u64 = 0,
    };

    fn create(harness: *Harness, options: Options) !*StubWorker {
        const gpa = harness.gpa;
        const stub = try gpa.create(StubWorker);
        errdefer gpa.destroy(stub);

        const child_pid = try std.posix.fork();
        if (child_pid == 0)
            waitForSignalForever();
        errdefer reapChild(child_pid, true);
        const pidfd = try os.process.openPidFd(@intCast(child_pid));
        var pidfd_owned = true;
        errdefer if (pidfd_owned) std.posix.close(pidfd);
        var child_pidfd = try os.fd.OwnedFd.dupCloexec(pidfd);
        errdefer child_pidfd.deinit();

        const control = try os.fd.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
        var control_server_owned = true;
        errdefer if (control_server_owned) std.posix.close(control[0]);
        errdefer std.posix.close(control[1]);
        // The launcher makes the server's end nonblocking once for the
        // worker's life; the worker's end is the test's and never blocks it.
        try os.fd.setNonblocking(control[0], true);
        try os.fd.setNonblocking(control[1], true);
        if (options.control_send_buffer_bytes) |bytes| {
            const value: c_int = @intCast(bytes);
            try std.posix.setsockopt(control[0], std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, std.mem.asBytes(&value));
        }

        const fault_pair = try os.fd.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
        var fault_server_owned = true;
        errdefer if (fault_server_owned) std.posix.close(fault_pair[0]);
        errdefer std.posix.close(fault_pair[1]);
        try os.fd.setNonblocking(fault_pair[0], true);
        try os.fd.setNonblocking(fault_pair[1], true);

        const metrics_fd = try page.createMemfd("collo-lane-harness-page");
        var metrics_fd_owned = true;
        errdefer if (metrics_fd_owned) std.posix.close(metrics_fd);
        var server_page = try page.mapReadWrite(metrics_fd);
        var server_page_owned = true;
        errdefer if (server_page_owned) server_page.deinit();
        server_page.initializeCrashDefault(@intCast(child_pid), 0, 0);
        var worker_page = try page.mapReadWrite(metrics_fd);
        errdefer worker_page.deinit();

        const completion_eventfd = try std.posix.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        var completion_eventfd_owned = true;
        errdefer if (completion_eventfd_owned) std.posix.close(completion_eventfd);
        const credit_eventfd = try std.posix.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        var credit_eventfd_owned = true;
        errdefer if (credit_eventfd_owned) std.posix.close(credit_eventfd);

        const payload_fd = try ingress_channel.createSharedPayloadMemfd();
        var payload_fd_owned = true;
        errdefer if (payload_fd_owned) std.posix.close(payload_fd);
        var server_payload = try ingress_channel.mapSharedPayloadReadWrite(payload_fd, .server);
        var server_payload_owned = true;
        errdefer if (server_payload_owned) server_payload.deinit();
        var worker_payload = try ingress_channel.mapSharedPayloadReadWrite(payload_fd, .worker);
        errdefer worker_payload.deinit();

        var tmp_root_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const tmp_root = try uniqueTempPath(&tmp_root_buffer);
        try std.fs.makeDirAbsolute(tmp_root);
        errdefer std.fs.deleteTreeAbsolute(tmp_root) catch |err|
            std.log.warn("lane harness left {s}: {s}", .{ tmp_root, @errorName(err) });
        var cgroup_buffer: [std.fs.max_path_bytes]u8 = undefined;
        // Inside the temp tree and never created, so the teardown's cgroup
        // removal finds nothing and never reaches a real cgroup.
        const cgroup_dir = try std.fmt.bufPrint(&cgroup_buffer, "{s}/cgroup", .{tmp_root});

        const handle = try host.WorkerHandle.init(
            gpa,
            @intCast(child_pid),
            pidfd,
            control[0],
            tmp_root,
            cgroup_dir,
            64 * 1024 * 1024,
            1,
            metrics_fd,
            completion_eventfd,
            payload_fd,
            credit_eventfd,
            server_payload,
            server_page,
            fault_pair[0],
        );
        // The handle owns the server's ends from here on, and the publish
        // takes it whether it succeeds or not.
        pidfd_owned = false;
        control_server_owned = false;
        fault_server_owned = false;
        metrics_fd_owned = false;
        server_page_owned = false;
        completion_eventfd_owned = false;
        credit_eventfd_owned = false;
        payload_fd_owned = false;
        server_payload_owned = false;

        const publish_options: fixture.PublishOptions = .{
            .definition_index = options.definition,
            .record = .{
                .send_scratch_bytes = ipc.max_message_bytes,
                .created_mono_ns = if (options.launched) os.process.monotonicNowNsOrZero() else 0,
                .boot_work_ns = options.boot_work_ns,
            },
        };
        const record = if (options.launched) launched: {
            const launched = try fixture.publishLaunchedWorker(&harness.supervisor, handle, publish_options);
            for (launched.handoffs.slice()) |handoff|
                try harness.service.postHandoff(handoff);
            break :launched launched.record;
        } else try fixture.publishWorker(&harness.supervisor, handle, publish_options);

        const recv_scratch = try gpa.alloc(u8, ipc.max_message_bytes);
        errdefer gpa.free(recv_scratch);
        const send_scratch = try gpa.alloc(u8, ipc.max_message_bytes);
        errdefer gpa.free(send_scratch);

        stub.* = .{
            .harness = harness,
            .record = record,
            .key = record.key(),
            .definition = options.definition,
            .child_pid = child_pid,
            .child_pidfd = child_pidfd,
            .control = control[1],
            .fault = fault_pair[1],
            .page_view = worker_page,
            .payload = worker_payload,
            .recv_scratch = recv_scratch,
            .send_scratch = send_scratch,
        };
        return stub;
    }

    fn destroy(self: *StubWorker) void {
        const gpa = self.harness.gpa;
        self.kill() catch |err|
            std.log.warn("lane harness could not end a stub worker: {s}", .{@errorName(err)});
        self.closeControl();
        std.posix.close(self.fault);
        self.page_view.deinit();
        self.payload.deinit();
        self.child_pidfd.deinit();
        gpa.free(self.recv_scratch);
        gpa.free(self.send_scratch);
        gpa.destroy(self);
    }

    /// Ends the worker's process and waits until its pidfd reports the exit.
    pub fn kill(self: *StubWorker) !void {
        if (self.child_reaped)
            return;
        os.process.pidFdSendSignal(self.child_pidfd.fd(), std.posix.SIG.KILL) catch |err| switch (err) {
            error.ProcessNotFound => {},
            else => return err,
        };
        if (!try os.process.waitForPidFdExit(self.child_pidfd.fd(), child_exit_wait_ms))
            return error.StubWorkerDidNotExit;
        reapChild(self.child_pid, false);
        self.child_reaped = true;
    }

    pub fn processAlive(self: *const StubWorker) bool {
        return !os.process.pidFdHasExited(self.child_pidfd.fd());
    }

    /// Closes the worker's end of its control socket, as the kernel does
    /// when the worker's process goes, so the lane's next send meets a hung
    /// up peer.
    pub fn closeControl(self: *StubWorker) void {
        if (self.control < 0)
            return;
        std.posix.close(self.control);
        self.control = -1;
    }

    /// Reads the request descriptor the lane sent and the DispatchWork it
    /// carries.
    pub fn readRequestBegin(self: *StubWorker) !Dispatched {
        const gpa = self.harness.gpa;
        var packet = try ipc.recvPacketWithFdsScratch(gpa, self.control, self.recv_scratch);
        var received = try ingress_channel.decodeReceivedPacket(gpa, &packet);
        defer received.deinit();
        const descriptor = received.descriptor;
        if (descriptor.op != @intFromEnum(ingress_channel.Op.request_begin))
            return error.ExpectedRequestBegin;
        var work = try ingress_channel.decodeDispatchPayload(gpa, &received);
        defer work.deinit();
        return .{
            .identity = .{
                .request_id = descriptor.request_id,
                .request_generation = descriptor.request_generation,
                .request_lane_id = descriptor.request_lane_id,
                .request_slot = descriptor.request_slot,
            },
            .stream_id = descriptor.stream_id,
            .body_follows = !descriptor.hasFlag(ingress_channel.flags.end_stream),
            .deadline_monotonic_ns = work.deadline_monotonic_ns,
            .egress_token = work.egress_token,
        };
    }

    /// Whether a packet waits on the worker's end of its control socket.
    pub fn controlReadable(self: *StubWorker) !bool {
        var poll_fds = [1]std.posix.pollfd{.{ .fd = self.control, .events = std.posix.POLL.IN, .revents = 0 }};
        return try std.posix.poll(&poll_fds, 0) != 0;
    }

    /// Reads every packet waiting on the control socket, each of which must
    /// carry body chunks of `request`, and appends their payloads to
    /// `out[body.len..]`, inline or from the server-to-worker ring. A release
    /// of ring bytes a lane marked itself waiting for writes the completion
    /// eventfd, as a worker's does (`worker/scheduler/loop.zig`).
    pub fn readBody(self: *StubWorker, request: Dispatched, out: []u8, body: *Body) !void {
        const gpa = self.harness.gpa;
        const readers = ingress_channel.SharedPayloadReaders{
            .server_to_worker = &self.payload,
            .server_to_worker_credit_eventfd = self.record.handle.completion_eventfd,
        };
        while (true) {
            var packet = ipc.recvPacketWithFdsScratch(gpa, self.control, self.recv_scratch) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };
            if (ingress_channel.isDescriptorBatchPacket(packet.bytes)) {
                var batch = try ingress_channel.decodeReceivedBatchPacketWithSharedPayload(gpa, &packet, readers);
                defer batch.deinit();
                for (batch.items) |*item|
                    try appendBodyChunk(request, item, out, body);
            } else {
                var received = try ingress_channel.decodeReceivedPacketWithSharedPayload(gpa, &packet, readers);
                defer received.deinit();
                try appendBodyChunk(request, &received, out, body);
            }
        }
    }

    /// A response head of `status` with one header, as its own packet.
    pub fn sendHead(self: *StubWorker, request: Dispatched, status: u16, end_stream: bool) !void {
        const headers = [_]ingress_channel.ResponseHeader{.{ .name = "content-type", .value = "text/plain" }};
        var head_buffer: [256]u8 = undefined;
        const head = try ingress_channel.encodeResponseHeadInto(&head_buffer, status, &headers);
        const descriptor = ingress_channel.Descriptor.responseHead(
            request.identity,
            request.stream_id,
            0,
            @intCast(head.len),
            status,
            headers.len,
            end_stream,
        );
        try ingress_channel.sendDescriptorPayload(self.control, descriptor, head, self.send_scratch);
    }

    /// A response head descriptor whose payload is `payload` exactly, so a
    /// test can send one that does not decode.
    pub fn sendRawHead(self: *StubWorker, request: Dispatched, payload: []const u8) !void {
        const descriptor = ingress_channel.Descriptor.responseHead(
            request.identity,
            request.stream_id,
            0,
            @intCast(payload.len),
            200,
            0,
            false,
        );
        try ingress_channel.sendDescriptorPayload(self.control, descriptor, payload, self.send_scratch);
    }

    /// A response chunk riding inline, at most `shared_payload_threshold`
    /// bytes.
    pub fn sendChunk(self: *StubWorker, request: Dispatched, body: []const u8, end_stream: bool) !void {
        const descriptor = ingress_channel.Descriptor.responseChunk(
            request.identity,
            request.stream_id,
            0,
            @intCast(body.len),
            end_stream,
        );
        try ingress_channel.sendDescriptorPayload(self.control, descriptor, body, self.send_scratch);
    }

    /// A response chunk above `shared_payload_threshold`, its bytes in the
    /// worker-to-server ring and its descriptor on the control socket.
    pub fn sendRingChunk(self: *StubWorker, request: Dispatched, body: []const u8, end_stream: bool) !void {
        const descriptor = ingress_channel.Descriptor.responseChunk(
            request.identity,
            request.stream_id,
            0,
            @intCast(body.len),
            end_stream,
        );
        try ingress_channel.sendDescriptorPayloadRequireRing(
            self.control,
            descriptor,
            body,
            self.send_scratch,
            self.payload.writer(.worker_to_server),
        );
    }

    /// Whether the server wrote the worker's credit eventfd since the last
    /// call, which it does only when it frees room in the worker-to-server
    /// ring the worker marked itself waiting for. The read clears the count.
    pub fn creditSignalled(self: *StubWorker) !bool {
        var count: u64 = 0;
        _ = std.posix.read(self.record.handle.ingress_payload_credit_eventfd, std.mem.asBytes(&count)) catch |err| switch (err) {
            error.WouldBlock => return false,
            else => return err,
        };
        return count != 0;
    }

    /// The worker-to-server ring's cursors, the read one the server's.
    pub fn responseRingCursors(self: *const StubWorker) struct { read: u64, write: u64 } {
        const ring = &self.payload.header.rings[@intFromEnum(ingress_channel.SharedPayloadDirection.worker_to_server)];
        return .{
            .read = @atomicLoad(u64, &ring.read_cursor, .acquire),
            .write = @atomicLoad(u64, &ring.write_cursor, .acquire),
        };
    }

    /// A whole response: its head, then its body with END_STREAM.
    pub fn respond(self: *StubWorker, request: Dispatched, status: u16, body: []const u8) !void {
        try self.sendHead(request, status, false);
        try self.sendChunk(request, body, true);
    }

    /// A whole response and then its completion, what a worker that served
    /// `request` writes.
    pub fn answer(self: *StubWorker, request: Dispatched, status: u16, body: []const u8) !void {
        try self.respond(request, status, body);
        try self.publishCompletion(request, .{ .http_status = status });
    }

    /// Publishes the request's completion on the shared page and wakes the
    /// lane through the completion eventfd.
    pub fn publishCompletion(self: *StubWorker, request: Dispatched, completion: Completion) !void {
        try self.page_view.publishWorkerCompletion(.{
            .external_request_id = request.identity.request_id,
            .request_lane_id = request.identity.request_lane_id,
            .request_slot = request.identity.request_slot,
            .request_generation = request.identity.request_generation,
            .worker_id = self.key.worker_id,
            .worker_generation = completion.worker_generation orelse self.key.worker_generation,
            .status = @intFromEnum(completion.done),
            .http_status = completion.http_status,
        });
        try page.signalCompletionEventfd(self.record.handle.completion_eventfd);
    }

    /// Sets the completion ring's fatal flag, as a worker that overran its
    /// ring does, and wakes the lane.
    pub fn markCompletionRingFatal(self: *StubWorker) !void {
        @atomicStore(u32, &self.page_view.completion_header.fatal, 1, .release);
        try page.signalCompletionEventfd(self.record.handle.completion_eventfd);
    }

    /// Stores a read cursor of the server-to-worker ring 4 KiB past the start,
    /// which no honest worker stores before the server wrote that much: the
    /// server's next ring write finds the reader ahead of its own write
    /// cursor.
    pub fn corruptServerToWorkerRing(self: *StubWorker) void {
        const ring = &self.payload.header.rings[@intFromEnum(ingress_channel.SharedPayloadDirection.server_to_worker)];
        @atomicStore(u64, &ring.read_cursor, 4096, .release);
    }

    /// One datagram on the control socket, exactly `bytes`.
    pub fn sendControlBytes(self: *StubWorker, bytes: []const u8) !void {
        try ipc.packet.sendWithFds(self.control, bytes, &.{});
    }

    /// One datagram on the control socket with `descriptor_count` fresh
    /// descriptors attached.
    pub fn sendControlWithDescriptors(self: *StubWorker, bytes: []const u8, descriptor_count: usize) !void {
        try sendWithEventfds(self.control, bytes, descriptor_count);
    }

    /// One datagram on the fault socket with `descriptor_count` fresh
    /// descriptors attached.
    pub fn sendFaultWithDescriptors(self: *StubWorker, bytes: []const u8, descriptor_count: usize) !void {
        try sendWithEventfds(self.fault, bytes, descriptor_count);
    }

    /// An fs-fault request for `request`, on the fault socket.
    pub fn sendFsFault(self: *StubWorker, fault_id: u64, request_id: u64, request_generation: u64, path: []const u8) !void {
        try ipc.fs_fault.sendRequest(self.fault, self.send_scratch, .{
            .fault_id = fault_id,
            .request_id = request_id,
            .request_generation = request_generation,
            .worker_id = self.key.worker_id,
            .worker_generation = self.key.worker_generation,
            .path = path,
        });
    }

    /// The lane's answer to an fs-fault request, waiting on the fault socket.
    pub fn readFsFaultAnswer(self: *StubWorker) !ipc.fs_fault.ResponseWithFd {
        var packet = try ipc.recvPacketWithFdsScratch(self.harness.gpa, self.fault, self.recv_scratch);
        return ipc.fs_fault.decodeResponseFromPacket(&packet);
    }
};

fn appendBodyChunk(request: Dispatched, received: *const ingress_channel.Received, out: []u8, body: *Body) !void {
    const descriptor = received.descriptor;
    if (descriptor.op != @intFromEnum(ingress_channel.Op.request_body_chunk))
        return error.ExpectedRequestBodyChunk;
    if (descriptor.request_id != request.identity.request_id or descriptor.stream_id != request.stream_id)
        return error.BodyChunkOfAnotherRequest;
    if (received.payload.len > out.len - body.len)
        return error.BodyLargerThanBuffer;
    @memcpy(out[body.len..][0..received.payload.len], received.payload);
    body.len += received.payload.len;
    if (descriptor.hasFlag(ingress_channel.flags.end_stream))
        body.ended = true;
}

/// What one client stream received.
pub const ClientStream = struct {
    id: u32 = 0,
    /// The final response's status.
    status: ?u16 = null,
    /// Informational responses (1xx) before the final one.
    informational_count: u8 = 0,
    body_len: usize = 0,
    ended: bool = false,
    reset_code: ?u32 = null,
    /// RST_STREAM frames the stream received; a server sends one at most.
    reset_count: u8 = 0,
};

/// The client side of one connection a lane serves.
pub const Client = struct {
    harness: *Harness,
    lane_index: u16,
    /// The lane connection slot and its key, which stays valid until the lane
    /// closes the connection.
    slot: u32,
    key: lifecycle.ConnectionKey,
    fd: std.posix.fd_t,
    options: Options,
    encoder: hpack.Encoder,
    decoder: hpack.Decoder,
    inbox: []u8,
    inbox_len: usize = 0,
    streams: [client_streams_max]ClientStream = @splat(.{}),
    goaway_code: ?u32 = null,
    /// The last stream id the lane's GOAWAY says it processed.
    goaway_last_stream_id: ?u32 = null,
    peer_closed: bool = false,

    pub const Options = struct {
        /// SETTINGS_INITIAL_WINDOW_SIZE the client advertises, which bounds
        /// the response bytes the lane may send on a stream before the
        /// client returns credit.
        initial_window_size: u32 = 1024 * 1024,
    };

    fn create(harness: *Harness, lane_index: u16, options: Options) !*Client {
        const gpa = harness.gpa;
        const opened = try harness.openConnectionSlot(lane_index);
        errdefer std.posix.close(opened.client_fd);
        const key = opened.key;

        const client = try gpa.create(Client);
        errdefer gpa.destroy(client);
        var encoder = try hpack.Encoder.init();
        errdefer encoder.deinit();
        var decoder = try hpack.Decoder.init();
        errdefer decoder.deinit();
        const inbox = try gpa.alloc(u8, client_inbox_bytes);
        client.* = .{
            .harness = harness,
            .lane_index = lane_index,
            .slot = key.slot,
            .key = key,
            .fd = opened.client_fd,
            .options = options,
            .encoder = encoder,
            .decoder = decoder,
            .inbox = inbox,
        };
        return client;
    }

    fn destroy(self: *Client) void {
        const gpa = self.harness.gpa;
        std.posix.close(self.fd);
        self.encoder.deinit();
        self.decoder.deinit();
        gpa.free(self.inbox);
        gpa.destroy(self);
    }

    fn start(self: *Client) !void {
        try self.writeAll(h2.client_connection_preface);
        var settings: [3 * h2.setting_wire_len]u8 = undefined;
        // A header table of 0 keeps the lane's encoder off its dynamic
        // table, so every response head decodes on its own.
        try h2.encodeSetting(settings[0..h2.setting_wire_len], .header_table_size, 0);
        try h2.encodeSetting(settings[h2.setting_wire_len..][0..h2.setting_wire_len], .enable_push, 0);
        try h2.encodeSetting(settings[2 * h2.setting_wire_len ..][0..h2.setting_wire_len], .initial_window_size, self.options.initial_window_size);
        try self.writeFrame(.settings, 0, 0, &settings);
        try self.drive();
        try self.collect();
    }

    /// Whether the lane still holds this connection.
    pub fn open(self: *Client) bool {
        return switch (self.harness.lane(self.lane_index).connections.lookup(self.slot, self.key.generation)) {
            .live => true,
            .stale_generation, .vacant, .out_of_range => false,
        };
    }

    /// Runs the handler the lane runs when the connection is readable.
    pub fn drive(self: *Client) !void {
        if (!self.open())
            return;
        try self.harness.driveConnection(self.lane_index, self.slot);
    }

    /// Lets the lane flush what it queued for the client, then reads and
    /// parses every frame that arrived.
    pub fn collect(self: *Client) !void {
        if (self.open()) {
            try self.harness.discardPollCompletions(self.lane_index);
            try self.harness.lane(self.lane_index).handleConnectionWritable(self.slot);
            try self.harness.finishPass(self.lane_index);
        }
        while (!self.peer_closed and self.inbox_len < self.inbox.len) {
            const read_len = std.posix.read(self.fd, self.inbox[self.inbox_len..]) catch |err| switch (err) {
                error.WouldBlock => break,
                error.ConnectionResetByPeer => {
                    self.peer_closed = true;
                    break;
                },
                else => return err,
            };
            if (read_len == 0) {
                self.peer_closed = true;
                break;
            }
            self.inbox_len += read_len;
        }
        try self.parseFrames();
    }

    /// A request head on `stream_id`, which ends the stream unless a body
    /// follows; `content_length` announces that body.
    pub fn request(self: *Client, stream_id: u32, method: []const u8, path: []const u8, options: RequestOptions) !void {
        var content_length_buffer: [20]u8 = undefined;
        var headers: [6]hpack.Header = undefined;
        var count: usize = 0;
        headers[count] = .{ .name = ":method", .value = method };
        count += 1;
        headers[count] = .{ .name = ":scheme", .value = "https" };
        count += 1;
        headers[count] = .{ .name = ":authority", .value = authority };
        count += 1;
        headers[count] = .{ .name = ":path", .value = path };
        count += 1;
        if (options.content_length) |length| {
            headers[count] = .{
                .name = "content-length",
                .value = try std.fmt.bufPrint(&content_length_buffer, "{d}", .{length}),
            };
            count += 1;
        }
        var block = try self.encoder.encodeHeaders(self.harness.gpa, headers[0..count], 16 * 1024);
        defer block.deinit(self.harness.gpa);
        const end_headers: u8 = 0x4;
        const end_stream: u8 = if (options.body_follows) 0 else 0x1;
        try self.writeFrame(.headers, end_headers | end_stream, stream_id, block.bytes());
        try self.trackStream(stream_id);
    }

    pub const RequestOptions = struct {
        body_follows: bool = false,
        content_length: ?usize = null,
    };

    /// A GET on `stream_id` that ends the stream.
    pub fn get(self: *Client, stream_id: u32) !void {
        try self.request(stream_id, "GET", default_path, .{});
    }

    /// A POST head on `stream_id` announcing `content_length` body bytes.
    pub fn post(self: *Client, stream_id: u32, content_length: usize) !void {
        try self.request(stream_id, "POST", default_path, .{ .body_follows = true, .content_length = content_length });
    }

    /// A GET on `stream_id` and the key of the request the lane admitted for
    /// it, whether the request went to a worker or waits for a slot.
    pub fn getAdmitted(self: *Client, stream_id: u32) !lifecycle.RequestKey {
        try self.get(stream_id);
        try self.drive();
        return self.harness.requestKeyOf(self, stream_id) orelse error.RequestNotAdmitted;
    }

    /// Reads what the lane wrote and checks the final status of stream
    /// `stream_id`.
    pub fn expectStatus(self: *Client, stream_id: u32, status: u16) !void {
        try self.collect();
        const received = try self.stream(stream_id);
        try std.testing.expectEqual(@as(?u16, status), received.status);
    }

    /// Reads what the lane wrote and checks that stream `stream_id` was
    /// reset, by exactly one RST_STREAM, since nothing but PRIORITY may
    /// follow one (RFC 9113 §5.1).
    pub fn expectReset(self: *Client, stream_id: u32) !void {
        try self.collect();
        const received = try self.stream(stream_id);
        try std.testing.expect(received.reset_code != null);
        try std.testing.expectEqual(@as(u8, 1), received.reset_count);
    }

    /// One DATA frame on `stream_id`, at most the lane's largest frame.
    pub fn data(self: *Client, stream_id: u32, payload: []const u8, end_stream: bool) !void {
        try self.writeFrame(.data, if (end_stream) 0x1 else 0, stream_id, payload);
    }

    /// What stream `stream_id`, which this client opened, received so far.
    pub fn stream(self: *Client, stream_id: u32) !ClientStream {
        const entry = self.streamEntry(stream_id) orelse return error.StreamNotOpened;
        return entry.*;
    }

    fn trackStream(self: *Client, stream_id: u32) !void {
        for (&self.streams) |*entry| {
            if (entry.id == stream_id)
                return;
            if (entry.id == 0) {
                entry.* = .{ .id = stream_id };
                return;
            }
        }
        return error.TooManyClientStreams;
    }

    fn streamEntry(self: *Client, stream_id: u32) ?*ClientStream {
        for (&self.streams) |*entry| {
            if (entry.id == stream_id)
                return entry;
        }
        return null;
    }

    /// One frame as the client sends it, for a frame the helpers above do not
    /// write.
    pub fn writeFrame(self: *Client, frame_type: h2.FrameType, flags: u8, stream_id: u32, payload: []const u8) !void {
        var header_bytes: [h2.frame_header_len]u8 = undefined;
        const header = h2.FrameHeader{
            .length = @intCast(payload.len),
            .frame_type_raw = @intFromEnum(frame_type),
            .frame_type = frame_type,
            .flags = h2.Flags.fromByte(flags),
            .stream_id = stream_id,
        };
        try header.encode(&header_bytes);
        try self.writeAll(&header_bytes);
        try self.writeAll(payload);
    }

    /// Writes `bytes` whole, which need not end on a frame boundary. A full
    /// socket lets the lane read before the next attempt, which is what a
    /// client waiting on the network does.
    pub fn writeAll(self: *Client, bytes: []const u8) !void {
        var written: usize = 0;
        var stalls: usize = 0;
        while (written < bytes.len) {
            const amount = std.posix.write(self.fd, bytes[written..]) catch |err| switch (err) {
                error.WouldBlock => {
                    stalls += 1;
                    if (stalls > 64)
                        return error.LaneStoppedReading;
                    try self.drive();
                    continue;
                },
                else => return err,
            };
            written += amount;
        }
    }

    fn parseFrames(self: *Client) !void {
        var cursor: usize = 0;
        while (self.inbox_len - cursor >= h2.frame_header_len) {
            const header = try h2.FrameHeader.parse(self.inbox[cursor..][0..h2.frame_header_len]);
            const frame_len = h2.frame_header_len + @as(usize, header.length);
            if (self.inbox_len - cursor < frame_len)
                break;
            try self.applyFrame(header, self.inbox[cursor + h2.frame_header_len ..][0..header.length]);
            cursor += frame_len;
        }
        std.mem.copyForwards(u8, self.inbox[0 .. self.inbox_len - cursor], self.inbox[cursor..self.inbox_len]);
        self.inbox_len -= cursor;
    }

    fn applyFrame(self: *Client, header: h2.FrameHeader, payload: []const u8) !void {
        switch (header.frame_type) {
            .headers => {
                // The lane sends neither padding, nor priority, nor a header
                // block split over CONTINUATION frames.
                if (!header.flags.end_headers_or_ack)
                    return error.ContinuedResponseHeaderBlock;
                var decoded = try self.decoder.decodeBlock(self.harness.gpa, payload, 64, 64 * 1024);
                defer decoded.deinit(self.harness.gpa);
                const entry = self.streamEntry(header.stream_id) orelse return error.FrameOnUnknownStream;
                for (decoded.headers) |field| {
                    if (!std.mem.eql(u8, field.name, ":status"))
                        continue;
                    const status = try std.fmt.parseUnsigned(u16, field.value, 10);
                    if (status < 200) {
                        entry.informational_count += 1;
                    } else {
                        entry.status = status;
                    }
                }
                if (header.flags.end_stream)
                    entry.ended = true;
            },
            .data => {
                const entry = self.streamEntry(header.stream_id) orelse return error.FrameOnUnknownStream;
                entry.body_len += payload.len;
                if (header.flags.end_stream)
                    entry.ended = true;
            },
            .rst_stream => {
                const entry = self.streamEntry(header.stream_id) orelse return error.FrameOnUnknownStream;
                if (payload.len != 4)
                    return error.MalformedResetFrame;
                entry.reset_code = std.mem.readInt(u32, payload[0..4], .big);
                entry.reset_count +|= 1;
            },
            .goaway => {
                if (payload.len < 8)
                    return error.MalformedGoawayFrame;
                self.goaway_last_stream_id = std.mem.readInt(u32, payload[0..4], .big) & h2.max_window_size;
                self.goaway_code = std.mem.readInt(u32, payload[4..8], .big);
            },
            else => {},
        }
    }
};

/// Sends `bytes` on `fd` with `count` fresh eventfds as SCM_RIGHTS, up to one
/// more than a receive holds, and closes the sender's copies afterwards.
fn sendWithEventfds(fd: std.posix.fd_t, bytes: []const u8, count: usize) !void {
    if (count > raw_descriptors_max)
        return error.TooManyDescriptors;
    const cmsg = os.cmsg;
    var fds: [raw_descriptors_max]std.posix.fd_t = undefined;
    var opened: usize = 0;
    defer for (fds[0..opened]) |opened_fd| std.posix.close(opened_fd);
    while (opened < count) : (opened += 1)
        fds[opened] = try std.posix.eventfd(0, linux.EFD.CLOEXEC);

    const payload_len = @sizeOf(std.posix.fd_t) * count;
    var control: [cmsg.space(@sizeOf(std.posix.fd_t) * raw_descriptors_max)]u8 align(@alignOf(cmsg.Cmsghdr)) = @splat(0);
    const header: *cmsg.Cmsghdr = @ptrCast(&control);
    header.* = .{
        .len = cmsg.len(payload_len),
        .level = std.posix.SOL.SOCKET,
        .type = cmsg.scm_rights,
    };
    @memcpy(control[cmsg.dataOffset()..][0..payload_len], std.mem.sliceAsBytes(fds[0..count]));
    const iov = [1]std.posix.iovec_const{.{ .base = bytes.ptr, .len = bytes.len }};
    const message = std.posix.msghdr_const{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = iov.len,
        .control = &control,
        .controllen = cmsg.space(payload_len),
        .flags = 0,
    };
    _ = try std.posix.sendmsg(fd, &message, std.posix.MSG.NOSIGNAL);
}

/// Sleeps until CLOCK_MONOTONIC, the clock the lane reads, has passed
/// `deadline_ns`. Fails with `error.MonotonicClockUnreadable` when the clock
/// cannot be read, and with `error.ClockDidNotPassDeadline` after
/// `clock_naps_max` sleeps.
pub fn waitUntilClockPasses(deadline_ns: u64) !void {
    var naps: usize = 0;
    while (naps < clock_naps_max) : (naps += 1) {
        const now_ns = os.process.monotonicNowNsOrZero();
        if (now_ns == 0)
            return error.MonotonicClockUnreadable;
        if (now_ns > deadline_ns)
            return;
        std.Thread.sleep(deadline_ns - now_ns + 1);
    }
    return error.ClockDidNotPassDeadline;
}

/// The process's open descriptors, this count's own directory handle
/// included, so two counts compare.
pub fn openDescriptorCount() !usize {
    var dir = try std.fs.openDirAbsolute("/proc/self/fd", .{ .iterate = true });
    defer dir.close();
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next()) |_| count += 1;
    return count;
}

/// The stub worker's process: it only waits, so its pidfd reports an exit
/// when the test kills it and never before. The child of a process whose
/// other threads may hold libc's locks makes raw system calls only.
fn waitForSignalForever() noreturn {
    while (true)
        _ = linux.pause();
}

/// Collects an exited child. Through `std.c.waitpid`, which reports a child
/// already collected instead of treating it as unreachable; `kill_first`
/// ends a child the caller never handed out.
fn reapChild(child_pid: std.posix.pid_t, kill_first: bool) void {
    if (kill_first)
        std.posix.kill(child_pid, std.posix.SIG.KILL) catch |err|
            std.log.warn("lane harness could not kill child {d}: {s}", .{ child_pid, @errorName(err) });
    var status: c_int = 0;
    _ = std.c.waitpid(child_pid, &status, 0);
}

var temp_path_sequence: std.atomic.Value(u64) = .init(0);

/// A fresh path under /tmp for a stub worker's tmp root: the pid separates
/// test processes, the sequence the workers of one process.
fn uniqueTempPath(buffer: []u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "/tmp/collo-lane-harness-{d}-{d}", .{
        linux.getpid(),
        temp_path_sequence.fetchAdd(1, .monotonic),
    });
}

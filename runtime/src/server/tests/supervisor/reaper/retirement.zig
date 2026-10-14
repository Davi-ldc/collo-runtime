//! Retirement on the reaper (`server/supervisor/reaper/`). A lane that ends a
//! request at its deadline leaves its worker alive, and a worker that left
//! service is torn down by the reaper, never by the thread that decided it
//! was done. An idle worker past its TTL with no reader retires at once, and
//! one with a reader leaves service and is torn down only after that reader
//! gives its role up; the idle pass asks such a reader again, whichever
//! retirement it holds up. The watch over the idle workers no lane reads
//! retires one that sends its retiring notice as recycled, and one that exits
//! or hangs up its control socket as dead, and leaves a worker a lane reads
//! to that lane, one a lane took between the scan and the poll included,
//! whose answer to that lane turned its socket readable. A retirement naming
//! a worker still in service is refused, a
//! removal that leaves its pool wanting a worker asks for a launch, and a
//! failed launch's leftovers are torn down like a worker, the console lines
//! its child logged drained once it is dead, under its definition with no
//! worker id and no request. Each worker the reaper retires gets one line in
//! `workers.jsonl` saying how it ended, even when the stream is full, and a
//! worker the launcher retired for its egress session gets the death it met
//! first when one came before the retirement; the
//! shutdown's lines are `supervisor.zig`'s. The reaper's queue, idle pass and
//! watch run on the test thread here (`drainRetirements`,
//! `retireIdleWorkers`, `pollWatchedWorkers`, or its two halves
//! `scanWatchedWorkers` and `pollScannedWorkers`), with the lanes and the
//! launcher replaced by a double that records what the reaper asks of them.
//! The reaper thread's loop, with its waits and its readings of the node's
//! memory, runs only in a whole server (`local-e2e`). Lane
//! `server-supervisor-test`.

const std = @import("std");
const host = @import("collo_host");
const ipc = @import("collo_ipc");
const analytics = @import("collo_server_analytics");
const config = @import("collo_server_config");
const lifecycle = @import("collo_server_lifecycle");
const process = @import("collo_os").process;
const os_fd = @import("collo_os").fd;
const worker_shared_page = @import("collo_worker_state").page;
const supervision = @import("collo_server_supervisor");
const fixture = @import("supervisor_fixture");

const testing = std.testing;
const pool_mod = supervision.pool;
const Reaper = supervision.reaper.Reaper;
const GrowthReason = supervision.launcher.GrowthReason;
const Supervisor = supervision.Supervisor;
const WorkerRecord = supervision.worker_table.Record;
const WorkerPool = pool_mod.Pool(WorkerRecord);

const demo = fixture.default_definition;
const beta: config.DefinitionIndex = 1;
const gamma: config.DefinitionIndex = 2;
const far_ns: u64 = std.math.maxInt(u64);

/// What the reaper asks of the lanes and the launcher, recorded instead of
/// posted.
const RecordingDeps = struct {
    release_posts: [8]ReleasePost = undefined,
    release_post_count: usize = 0,
    died_posts: usize = 0,
    /// The first `submits.len` submits; `submit_count` counts them all.
    submits: [4]Submit = undefined,
    submit_count: usize = 0,
    leftovers_reaped: usize = 0,

    const ReleasePost = struct {
        lane: pool_mod.LaneId,
        worker_key: lifecycle.WorkerKey,
        epoch: pool_mod.ReaderEpoch,
    };

    const Submit = struct {
        definition: config.DefinitionIndex,
        reason: GrowthReason,
    };

    fn deps(self: *RecordingDeps) supervision.reaper.Deps {
        return .{
            .ctx = self,
            .postReleaseWorker = postReleaseWorker,
            .postWorkerDied = postWorkerDied,
            .submit = submit,
            .leftoversReaped = leftoversReaped,
        };
    }

    fn postReleaseWorker(
        ctx: *anyopaque,
        lane: pool_mod.LaneId,
        worker_key: lifecycle.WorkerKey,
        epoch: pool_mod.ReaderEpoch,
    ) bool {
        const self: *RecordingDeps = @ptrCast(@alignCast(ctx));
        if (self.release_post_count == self.release_posts.len)
            return false;
        self.release_posts[self.release_post_count] = .{ .lane = lane, .worker_key = worker_key, .epoch = epoch };
        self.release_post_count += 1;
        return true;
    }

    fn postWorkerDied(ctx: *anyopaque, lane: pool_mod.LaneId, worker_key: lifecycle.WorkerKey) bool {
        const self: *RecordingDeps = @ptrCast(@alignCast(ctx));
        _ = lane;
        _ = worker_key;
        self.died_posts += 1;
        return true;
    }

    fn submit(ctx: *anyopaque, definition: config.DefinitionIndex, reason: GrowthReason) void {
        const self: *RecordingDeps = @ptrCast(@alignCast(ctx));
        if (self.submit_count < self.submits.len)
            self.submits[self.submit_count] = .{ .definition = definition, .reason = reason };
        self.submit_count += 1;
    }

    fn leftoversReaped(ctx: *anyopaque) void {
        const self: *RecordingDeps = @ptrCast(@alignCast(ctx));
        self.leftovers_reaped += 1;
    }
};

/// A reaper over a fixture supervisor with no reaper thread, so the test
/// carries out the retire queue (`drainRetirements`) and the idle pass
/// (`retireIdleWorkers`) itself. Initialized in place, because the reaper
/// points at the supervisor and at the recording.
const Harness = struct {
    supervisor: Supervisor,
    recording: RecordingDeps,
    reaper: Reaper,

    fn init(self: *Harness, options: fixture.SupervisorOptions) !void {
        self.supervisor = try fixture.minimalSupervisorWith(testing.allocator, options);
        errdefer fixture.deinitMinimal(&self.supervisor);
        self.recording = .{};
        try self.reaper.init(testing.allocator, .{ .supervisor = &self.supervisor, .deps = self.recording.deps() });
    }

    /// The reaper's `deinit` requires an empty retire queue, and a test that
    /// failed midway may have left a retirement in it.
    fn deinit(self: *Harness) void {
        _ = self.reaper.drainRetirements();
        self.reaper.deinit();
        fixture.deinitMinimal(&self.supervisor);
    }
};

/// A child of the test that stands in for a worker's process: parked until a
/// signal ends it.
const ParkedChild = struct {
    pid: std.posix.pid_t,
    /// The descriptor a worker handle or a launch's leftovers takes over.
    pidfd: std.posix.fd_t,
    /// The test's own descriptor on the child, so it sees the child's exit
    /// after the teardown closed `pidfd`.
    watch: os_fd.OwnedFd,

    fn spawn() !ParkedChild {
        const pid = try std.posix.fork();
        if (pid == 0)
            parkUntilKilled();
        errdefer killAndReap(pid);
        const pidfd = try process.openPidFd(@intCast(pid));
        errdefer std.posix.close(pidfd);
        const watch = try os_fd.OwnedFd.dupCloexec(pidfd);
        return .{ .pid = pid, .pidfd = pidfd, .watch = watch };
    }

    fn alive(self: *const ParkedChild) bool {
        return !process.pidFdHasExited(self.watch.fd());
    }

    /// Ends the child as a crash ends a worker, and returns once its pidfd
    /// reports the exit.
    fn kill(self: *const ParkedChild) !void {
        try process.pidFdSendSignal(self.watch.fd(), std.posix.SIG.KILL);
        if (!try process.waitForPidFdExit(self.watch.fd(), 5_000))
            return error.TestChildDidNotExit;
    }

    /// Kills the child if it still runs and reaps it, so a failing test
    /// leaves no parked process behind. The pidfd is the taker's to close.
    fn deinit(self: *ParkedChild) void {
        if (self.alive()) {
            process.pidFdSendSignal(self.watch.fd(), std.posix.SIG.KILL) catch |err| switch (err) {
                error.ProcessNotFound => {},
                else => std.log.warn("parked child pid={d} not killed: {s}", .{ self.pid, @errorName(err) }),
            };
        }
        reap(self.pid);
        self.watch.deinit();
    }
};

/// Raw syscalls only: the test binary may have other threads, fork copied
/// only the calling one, and a lock another thread held stays held in the
/// child forever.
fn parkUntilKilled() noreturn {
    var none = [_]std.os.linux.pollfd{.{ .fd = -1, .events = 0, .revents = 0 }};
    while (true)
        _ = std.os.linux.ppoll(&none, none.len, null, null);
}

fn killAndReap(pid: std.posix.pid_t) void {
    _ = std.os.linux.kill(pid, std.posix.SIG.KILL);
    reap(pid);
}

/// Through `std.c.waitpid`, which tolerates ECHILD: another suite in the same
/// binary installs SA_NOCLDWAIT for the length of one test, and the kernel
/// may then have reaped the child already.
fn reap(pid: std.posix.pid_t) void {
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
}

/// Zero-length stand-in for the ingress payload mapping, which
/// `SharedPayloadView` teardown leaves unmapped.
var inert_payload_bytes: [0]u8 align(std.heap.page_size_min) = .{};
var inert_payload_header: ipc.ingress_channel.SharedPayloadHeader = std.mem.zeroes(ipc.ingress_channel.SharedPayloadHeader);

/// A worker handle for `child` that `WorkerHandle.deinit` takes apart end to
/// end, taking over `child.pidfd`: a cgroup leaf that names nothing
/// (`fixture.inertLeaf`), so the teardown never reaches the delegated cgroup
/// subtree and leaves nothing on disk, a control socket whose peer is
/// closed, eventfds and a real shared page. The reaper's watch takes the
/// closed peer for the worker's death.
fn handleFor(allocator: std.mem.Allocator, child: *const ParkedChild) !host.WorkerHandle {
    var peer: os_fd.OwnedFd = .{};
    defer peer.deinit();
    return handleWithPeer(allocator, child, &peer);
}

/// `handleFor` that hands the worker's end of the control socket to `peer`,
/// so the test writes there what a worker writes. A child forked while `peer`
/// is open inherits it, and its copy keeps the socket from hanging up, so a
/// test spawns its children first.
fn handleWithPeer(allocator: std.mem.Allocator, child: *const ParkedChild, peer: *os_fd.OwnedFd) !host.WorkerHandle {
    const leaf = try fixture.inertLeaf(allocator);
    const pair = try os_fd.socketPairType(std.posix.SOCK.SEQPACKET);
    errdefer std.posix.close(pair[0]);
    var worker_end = os_fd.OwnedFd.fromRaw(pair[1]);
    errdefer worker_end.deinit();
    const completion_eventfd = try std.posix.eventfd(0, 0);
    errdefer std.posix.close(completion_eventfd);
    const credit_eventfd = try std.posix.eventfd(0, 0);
    errdefer std.posix.close(credit_eventfd);
    // Mapped, then closed, as a launch does once the child holds its copy.
    const metrics_fd = try worker_shared_page.createMemfd("collo-test-retire-metrics");
    defer std.posix.close(metrics_fd);
    var metrics = try worker_shared_page.mapHostReader(metrics_fd);
    errdefer metrics.deinit();

    peer.* = worker_end;
    return .{
        .pid = @intCast(child.pid),
        .pidfd = child.pidfd,
        .control_fd = pair[0],
        .leaf = leaf,
        .completion_eventfd = completion_eventfd,
        .ingress_payload_credit_eventfd = credit_eventfd,
        .ingress_payload = .{ .bytes = &inert_payload_bytes, .header = &inert_payload_header, .side = .server },
        .metrics = metrics,
    };
}

/// `handleFor` whose page carries the sentinel's memory stamp, as a worker
/// its sentinel stopped past `memory.high` leaves it.
fn handleStampedMemory(allocator: std.mem.Allocator, child: *const ParkedChild) !host.WorkerHandle {
    var handle = try handleFor(allocator, child);
    errdefer handle.deinit();
    const page_fd = try worker_shared_page.createMemfd("collo-test-retire-memory");
    defer std.posix.close(page_fd);
    var worker_page = try worker_shared_page.mapWorkerWriter(page_fd);
    defer worker_page.deinit();
    @atomicStore(u32, &worker_page.header.termination_reason, @intFromEnum(worker_shared_page.TerminationReason.memory), .release);
    var stamped = try worker_shared_page.mapHostReader(page_fd);
    errdefer stamped.deinit();
    if (handle.metrics) |*unstamped|
        unstamped.deinit();
    handle.metrics = stamped;
    return handle;
}

fn requestKey(lane: pool_mod.LaneId, request: u32) lifecycle.RequestKey {
    return .{ .lane_id = lane, .slot = request, .generation = 1 };
}

fn expectAcquired(worker_pool: *WorkerPool, lane: pool_mod.LaneId, request: u32) !WorkerPool.Acquired {
    return switch (worker_pool.acquire(lane, requestKey(lane, request), far_ns)) {
        .acquired => |acquired| acquired,
        .wait, .full => error.TestExpectedAcquired,
    };
}

/// The epoch of the reader role an acquisition gave its lane.
fn expectNewReader(acquired: WorkerPool.Acquired) !pool_mod.ReaderEpoch {
    return switch (acquired.reader) {
        .you_become_reader => |epoch| epoch,
        .already, .transfer_from => error.TestExpectedReader,
    };
}

/// Whether `worker`'s record was torn down: its storage vacant, its page gone
/// for every drain and its pool entry emptied.
fn expectTornDown(supervisor: *Supervisor, worker: *WorkerRecord) !void {
    try testing.expectEqual(@as(u64, 0), worker.id);
    try testing.expect(!worker.page_mapped);
    try testing.expect(supervisor.poolFor(worker.definition_index).inspect(worker) == null);
}

test "a lane that ends a request at its deadline takes its floor and leaves the worker alive in its pool (#39)" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();
    var child = try ParkedChild.spawn();
    defer child.deinit();
    const supervisor = &harness.supervisor;
    const worker = try fixture.publishWorker(supervisor, try handleFor(testing.allocator, &child), .{});
    const demo_pool = supervisor.poolFor(demo);
    const key = worker.key();

    // Lane 0's request reached its deadline with no `request_done`, and the
    // lane takes its floor and ends its entry while it still holds the slot.
    const served = try expectAcquired(demo_pool, 0, 1);
    const dispatched = fixture.dispatchedRequest(1);
    try worker.requests.record(dispatched);
    _ = worker.usageFloor(served.slot, .{
        .request_id = dispatched.request_id,
        .request_generation = dispatched.request_key.generation,
    }, .deadline);
    worker.requests.end(dispatched.request_id);

    // The finish killed nothing and emptied nothing: the process runs, the
    // record holds the same worker with its page drainable, and the slot is
    // still the lane's to give back.
    try testing.expect(child.alive());
    try testing.expect(worker.key().eql(key));
    try testing.expect(worker.page_mapped);
    const view = demo_pool.inspect(worker) orelse return error.TestExpectedWorker;
    try testing.expectEqual(pool_mod.EntryState.live, view.state);
    try testing.expectEqual(@as(u8, 1), view.slots_held);
    try testing.expect((try demo_pool.release(worker, served.slot, 10)) == .idle);
}

test "a worker out of service is torn down on the reaper, never on the thread that retired it (#39)" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();
    var child = try ParkedChild.spawn();
    defer child.deinit();
    const supervisor = &harness.supervisor;
    const worker = try fixture.publishWorker(supervisor, try handleFor(testing.allocator, &child), .{});
    const demo_pool = supervisor.poolFor(demo);

    // A lane's death path: the worker leaves service, and with no lane
    // holding or reading it the lane queues its retirement and returns.
    const death = demo_pool.markDead(worker, worker.key()) orelse return error.TestExpectedDeath;
    try testing.expect(death.retire);
    harness.reaper.queueRetirement(worker, .died);

    // No kill, no exit wait and no drain ran on that thread: the process is
    // alive and the record still holds it.
    try testing.expect(child.alive());
    try testing.expect(worker.id != 0);
    try testing.expectEqual(pool_mod.EntryState.dead, (demo_pool.inspect(worker) orelse return error.TestExpectedWorker).state);

    // The reaper kills it, waits for its exit, drains its page and empties
    // its entry.
    try testing.expectEqual(@as(usize, 1), harness.reaper.drainRetirements());
    try testing.expect(!child.alive());
    try expectTornDown(supervisor, worker);
    try testing.expectEqual(@as(u64, 1), demo_pool.snapshot().counters.removed);
    try testing.expectEqual(@as(u64, 1), harness.reaper.countersSnapshot().retired_died);
}

test "an idle worker past its TTL with no reader retires at once, and a worker idle for less stays" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();
    var child = try ParkedChild.spawn();
    defer child.deinit();
    const supervisor = &harness.supervisor;
    const stale = try fixture.publishWorker(supervisor, try handleFor(testing.allocator, &child), .{
        .definition_index = demo,
        .now_ns = 1_000,
    });
    const fresh = try fixture.publishInertWorker(supervisor, .{ .definition_index = beta, .now_ns = 4_900 });

    // A zero TTL turns idle retirement off: an idle worker is the warm
    // capacity the pool keeps on purpose.
    supervisor.worker_idle_ttl_ns = 0;
    try testing.expectEqual(@as(usize, 0), harness.reaper.retireIdleWorkers(5_000));
    try testing.expect(child.alive());
    try testing.expect(supervisor.poolFor(demo).inspect(stale) != null);

    // Idle 4000 ns against a 1000 ns TTL, with no lane reading it: retired
    // and torn down without asking any lane, and since no request waits, the
    // reaper asks for no launch.
    supervisor.worker_idle_ttl_ns = 1_000;
    try testing.expectEqual(@as(usize, 1), harness.reaper.retireIdleWorkers(5_000));
    try testing.expect(!child.alive());
    try expectTornDown(supervisor, stale);
    try testing.expectEqual(@as(usize, 0), harness.recording.release_post_count);
    try testing.expectEqual(@as(usize, 0), harness.recording.submit_count);

    // Idle 100 ns: still in service.
    const view = supervisor.poolFor(beta).inspect(fresh) orelse return error.TestExpectedWorker;
    try testing.expectEqual(pool_mod.EntryState.live, view.state);
}

test "an idle worker with a reader leaves service at once and is torn down only after its reader vacates" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();
    var child = try ParkedChild.spawn();
    defer child.deinit();
    const supervisor = &harness.supervisor;
    const worker = try fixture.publishWorker(supervisor, try handleFor(testing.allocator, &child), .{});
    const demo_pool = supervisor.poolFor(demo);

    // Lane 0 serves one request on the worker and becomes its reader.
    const served = try expectAcquired(demo_pool, 0, 1);
    const epoch = try expectNewReader(served);
    try testing.expect((try demo_pool.release(worker, served.slot, 1_000)) == .idle);

    // The worker leaves service, so no slot of it goes out again, but lane 0
    // still reads it: the reaper asks lane 0 to give the role up and tears
    // nothing down.
    supervisor.worker_idle_ttl_ns = 1_000;
    _ = harness.reaper.retireIdleWorkers(5_000);
    try testing.expectEqual(pool_mod.EntryState.retiring, (demo_pool.inspect(worker) orelse return error.TestExpectedWorker).state);
    try testing.expect(child.alive());
    try testing.expectEqual(@as(usize, 1), harness.recording.release_post_count);
    const post = harness.recording.release_posts[0];
    try testing.expectEqual(@as(pool_mod.LaneId, 0), post.lane);
    try testing.expect(post.worker_key.eql(worker.key()));
    try testing.expectEqual(epoch, post.epoch);

    // A post can be lost, so each pass asks again while the reader holds on.
    _ = harness.reaper.retireIdleWorkers(6_000);
    try testing.expectEqual(@as(usize, 2), harness.recording.release_post_count);

    // Lane 0 runs `release_worker`: its role ends with the retirement, which
    // it queues.
    try testing.expectEqual(pool_mod.Transfer.retire, demo_pool.transferReader(worker, .{ .lane = 0, .epoch = epoch }, .nothing));
    harness.reaper.queueRetirement(worker, .idle);
    try testing.expect(child.alive());
    try testing.expectEqual(@as(usize, 1), harness.reaper.drainRetirements());
    try testing.expect(!child.alive());
    try expectTornDown(supervisor, worker);
}

test "a retirement naming a worker still in service is refused and leaves the worker as it was" {
    // The reaper reports the refusal once, at `err`: a caller queued a worker
    // its pool never reported finished.
    @import("root").expect_log_errors = 1;
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();
    var child = try ParkedChild.spawn();
    defer child.deinit();
    const supervisor = &harness.supervisor;
    const worker = try fixture.publishWorker(supervisor, try handleFor(testing.allocator, &child), .{});
    const key = worker.key();

    harness.reaper.queueRetirement(worker, .idle);
    try testing.expectEqual(@as(usize, 1), harness.reaper.drainRetirements());
    try testing.expect(child.alive());
    try testing.expect(worker.key().eql(key));
    try testing.expect(worker.page_mapped);
    const view = supervisor.poolFor(demo).inspect(worker) orelse return error.TestExpectedWorker;
    try testing.expectEqual(pool_mod.EntryState.live, view.state);
    try testing.expectEqual(@as(u64, 0), harness.reaper.countersSnapshot().retired_idle);
}

test "a removal that leaves its pool wanting a worker asks the launcher for one, once" {
    var harness: Harness = undefined;
    try harness.init(.{ .routes = .{ .concurrency = 1 } });
    defer harness.deinit();
    const supervisor = &harness.supervisor;
    const worker = try fixture.publishInertWorker(supervisor, .{});
    const demo_pool = supervisor.poolFor(demo);

    // Lane 0 holds the worker's only slot and reads it; lane 1's request
    // waits for a slot.
    const served = try expectAcquired(demo_pool, 0, 1);
    const epoch = try expectNewReader(served);
    try testing.expect(demo_pool.acquire(1, requestKey(1, 1), far_ns) == .wait);

    // The worker dies under lane 0, which ends its request, gives the slot
    // and the reader role back, and queues the retirement.
    const death = demo_pool.markDead(worker, worker.key()) orelse return error.TestExpectedDeath;
    try testing.expect(!death.retire);
    try testing.expect((try demo_pool.release(worker, served.slot, 10)) == .idle);
    try testing.expectEqual(pool_mod.Transfer.retire, demo_pool.transferReader(worker, .{ .lane = 0, .epoch = epoch }, .nothing));
    harness.reaper.queueRetirement(worker, .died);

    // After the removal a request still waits, with no worker live and no
    // launch in flight.
    try testing.expectEqual(@as(usize, 1), harness.reaper.drainRetirements());
    try expectTornDown(supervisor, worker);
    try testing.expectEqual(@as(usize, 1), harness.recording.submit_count);
    try testing.expectEqual(demo, harness.recording.submits[0].definition);
    try testing.expectEqual(GrowthReason.capacity, harness.recording.submits[0].reason);
    try testing.expect(demo_pool.cancelWaiter(requestKey(1, 1)));
}

test "a failed launch's leftovers are torn down on the reaper, the child killed and its cgroup leaf removed" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();
    var child = try ParkedChild.spawn();
    defer child.deinit();
    // A plain directory stands in for the workers directory, with the leaf
    // the launch created in it.
    var workers_path: []u8 = undefined;
    var workers_dir = try fixture.openScratchDir(testing.allocator, &workers_path);
    defer {
        workers_dir.close();
        std.fs.deleteTreeAbsolute(workers_path) catch {};
        testing.allocator.free(workers_path);
    }
    const job_id: u64 = 7;
    try workers_dir.makeDir("worker-7");

    // The launcher hands over what the child left, and never kills, waits or
    // removes anything itself.
    harness.reaper.queueLeftovers(.{ .definition = demo, .child = .{
        .pid = @intCast(child.pid),
        .pidfd = os_fd.OwnedFd.fromRaw(child.pidfd),
        .leaf = .{ .workers_dir_fd = workers_dir.fd, .job_id = job_id },
    } });
    try testing.expect(child.alive());

    // Once they are torn down, the launcher gets back the room in its launch
    // table they held.
    try testing.expectEqual(@as(usize, 1), harness.reaper.drainRetirements());
    try testing.expect(!child.alive());
    try testing.expectError(error.FileNotFound, workers_dir.access("worker-7", .{}));
    try testing.expectEqual(@as(usize, 1), harness.recording.leftovers_reaped);
}

/// One line of `logs.jsonl`, field for field.
const LogLine = struct {
    ts: u64,
    worker: []const u8,
    route: []const u8,
    worker_id: u64,
    worker_generation: u64,
    request_id: u64,
    level: []const u8,
    message: []const u8,
    truncated: bool,
    exception: bool,
};

test "a failed launch's console lines are drained once its child is dead, under its definition with no worker id and no request" {
    var analytics_dir = try fixture.AnalyticsDir.init(testing.allocator);
    defer analytics_dir.deinit(testing.allocator);
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();
    var child = try ParkedChild.spawn();
    defer child.deinit();

    // A sink of the test's own, whose console stream goes to a pipe the test
    // reads, stands in for the fixture's for the length of the test.
    const console = try std.posix.pipe2(.{ .CLOEXEC = true });
    defer std.posix.close(console[0]);
    defer std.posix.close(console[1]);
    try os_fd.setNonblocking(console[0], true);
    var sink: analytics.Sink = undefined;
    try sink.open(testing.allocator, .{ .directory = analytics_dir.path, .console_fd = console[1] });
    defer sink.close();
    const fixture_sink = harness.supervisor.analytics;
    harness.supervisor.analytics = &sink;
    defer harness.supervisor.analytics = fixture_sink;

    // The test plays the child through a mapping of its own: a tenant line
    // from the boot's evaluation, one that claims a request the child was
    // never dispatched, and the runtime's report of the failed boot.
    const page_fd = try worker_shared_page.createMemfd("collo-test-failed-launch-page");
    defer std.posix.close(page_fd);
    var child_page = try worker_shared_page.mapWorkerWriter(page_fd);
    defer child_page.deinit();
    child_page.publishLogLine(.info, 0, 0, 1, "top-level code ran");
    child_page.publishLogLine(.info, 0, 77, 1, "claims a request");
    child_page.publishLogLine(.err, worker_shared_page.LogLineFlags.runtime, 0, 1, "worker boot failed: InitDeadlineExceeded");

    harness.reaper.queueLeftovers(.{ .definition = beta, .child = .{
        .pid = @intCast(child.pid),
        .pidfd = os_fd.OwnedFd.fromRaw(child.pidfd),
        .page = try worker_shared_page.mapHostReader(page_fd),
    } });
    try testing.expectEqual(@as(usize, 1), harness.reaper.drainRetirements());
    try testing.expect(!child.alive());
    try testing.expectEqual(@as(usize, 1), harness.recording.leftovers_reaped);

    // Every line reaches stderr under the definition's name, the runtime's
    // under its label.
    sink.flushConsole();
    var console_buffer: [4096]u8 = undefined;
    const console_text = console_buffer[0..try std.posix.read(console[0], &console_buffer)];
    try testing.expect(std.mem.indexOf(u8, console_text, "[beta] top-level code ran\n") != null);
    try testing.expect(std.mem.indexOf(u8, console_text, "[beta] claims a request\n") != null);
    try testing.expect(std.mem.indexOf(u8, console_text, "[beta runtime] worker boot failed: InitDeadlineExceeded\n") != null);

    // The tenant's lines enter its log with worker id 0, which no worker
    // has, and request id 0; the runtime's line does not.
    sink.flush(process.monotonicNowNsOrZero());
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const records = try analytics_dir.tmp.dir.readFileAlloc(arena.allocator(), analytics.sink.fileName(.logs).?, 64 * 1024);
    var lines = std.mem.splitScalar(u8, records, '\n');
    const expected = [_][]const u8{ "top-level code ran", "claims a request" };
    for (expected) |message| {
        const line = try std.json.parseFromSliceLeaky(LogLine, arena.allocator(), lines.next() orelse "", .{});
        try testing.expectEqualStrings("beta", line.worker);
        try testing.expectEqualStrings("", line.route);
        try testing.expectEqual(@as(u64, 0), line.worker_id);
        try testing.expectEqual(@as(u64, 0), line.worker_generation);
        try testing.expectEqual(@as(u64, 0), line.request_id);
        try testing.expectEqualStrings(message, line.message);
    }
    try testing.expectEqualStrings("", lines.next() orelse "");
    try testing.expectEqual(@as(?[]const u8, null), lines.next());
}

test "an idle worker no lane reads that sends its retiring notice is retired by the watch as recycled, with no death" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();
    var child = try ParkedChild.spawn();
    defer child.deinit();
    var peer: os_fd.OwnedFd = .{};
    defer peer.deinit();
    const supervisor = &harness.supervisor;
    const worker = try fixture.publishWorker(supervisor, try handleWithPeer(testing.allocator, &child, &peer), .{});
    const demo_pool = supervisor.poolFor(demo);

    // Quiet, the worker is watched and stays in service.
    try testing.expectEqual(@as(usize, 1), harness.reaper.pollWatchedWorkers());
    try testing.expect(child.alive());
    try testing.expectEqual(pool_mod.EntryState.live, (demo_pool.inspect(worker) orelse return error.TestExpectedWorker).state);

    // Its VM was terminated, so it asks to be retired. No lane reads it, so
    // the reaper takes the notice to the pool without reading it, and since
    // the worker holds nothing, retires it at once.
    try ipc.worker_retiring.send(peer.fd(), .vm_terminated);
    try testing.expectEqual(@as(usize, 1), harness.reaper.pollWatchedWorkers());
    try testing.expect(!child.alive());
    try expectTornDown(supervisor, worker);
    const counters = harness.reaper.countersSnapshot();
    try testing.expectEqual(@as(u64, 1), counters.notices_seen);
    try testing.expectEqual(@as(u64, 1), counters.retired_recycled);
    try testing.expectEqual(@as(u64, 0), counters.deaths_seen);
    try testing.expectEqual(@as(u64, 0), counters.retired_died);
    const pool_counters = demo_pool.snapshot().counters;
    try testing.expectEqual(@as(u64, 1), pool_counters.notice_retirements);
    try testing.expectEqual(@as(u64, 0), pool_counters.deaths);
    try testing.expectEqual(@as(usize, 0), harness.recording.died_posts);
}

test "the watch retires as dead a worker that exits and one that hangs up its control socket, and leaves a quiet one in service" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();
    // Every child before any handle, so no child holds another worker's
    // socket.
    var exiting = try ParkedChild.spawn();
    defer exiting.deinit();
    var hanging_up = try ParkedChild.spawn();
    defer hanging_up.deinit();
    var quiet = try ParkedChild.spawn();
    defer quiet.deinit();
    var exiting_peer: os_fd.OwnedFd = .{};
    defer exiting_peer.deinit();
    var quiet_peer: os_fd.OwnedFd = .{};
    defer quiet_peer.deinit();
    const supervisor = &harness.supervisor;
    const exiting_worker = try fixture.publishWorker(supervisor, try handleWithPeer(testing.allocator, &exiting, &exiting_peer), .{
        .definition_index = demo,
    });
    // The worker's end of the control socket is closed while its process
    // still runs.
    const hanging_up_worker = try fixture.publishWorker(supervisor, try handleFor(testing.allocator, &hanging_up), .{
        .definition_index = beta,
    });
    const quiet_worker = try fixture.publishWorker(supervisor, try handleWithPeer(testing.allocator, &quiet, &quiet_peer), .{
        .definition_index = gamma,
    });

    try exiting.kill();
    try testing.expectEqual(@as(usize, 3), harness.reaper.pollWatchedWorkers());
    try expectTornDown(supervisor, exiting_worker);
    try expectTornDown(supervisor, hanging_up_worker);
    try testing.expect(!hanging_up.alive());
    try testing.expect(quiet.alive());
    try testing.expectEqual(pool_mod.EntryState.live, (supervisor.poolFor(gamma).inspect(quiet_worker) orelse return error.TestExpectedWorker).state);
    const counters = harness.reaper.countersSnapshot();
    try testing.expectEqual(@as(u64, 2), counters.deaths_seen);
    try testing.expectEqual(@as(u64, 2), counters.retired_died);
    try testing.expectEqual(@as(u64, 0), counters.notices_seen);
    // No lane held or read either worker, so no lane is told.
    try testing.expectEqual(@as(usize, 0), harness.recording.died_posts);
}

test "the watch leaves a worker a lane reads to that lane, its notice included" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();
    var child = try ParkedChild.spawn();
    defer child.deinit();
    var peer: os_fd.OwnedFd = .{};
    defer peer.deinit();
    const supervisor = &harness.supervisor;
    const worker = try fixture.publishWorker(supervisor, try handleWithPeer(testing.allocator, &child, &peer), .{});
    const demo_pool = supervisor.poolFor(demo);

    // Lane 0 served a request on the worker and still reads it, idle.
    const served = try expectAcquired(demo_pool, 0, 1);
    _ = try expectNewReader(served);
    try testing.expect((try demo_pool.release(worker, served.slot, 10)) == .idle);

    // Lane 0 reads the notice: the reaper neither watches the worker nor
    // takes it out of service.
    try ipc.worker_retiring.send(peer.fd(), .routes_failed);
    try testing.expectEqual(@as(usize, 0), harness.reaper.pollWatchedWorkers());
    try testing.expect(child.alive());
    try testing.expectEqual(pool_mod.EntryState.live, (demo_pool.inspect(worker) orelse return error.TestExpectedWorker).state);
    try testing.expectEqual(@as(u64, 0), harness.reaper.countersSnapshot().notices_seen);
}

test "the watch keeps in service a worker a lane took after the scan, whose answer turned its control socket readable, and retires it on a notice once a scan sees it unread again (#156)" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();
    var child = try ParkedChild.spawn();
    defer child.deinit();
    var peer: os_fd.OwnedFd = .{};
    defer peer.deinit();
    const supervisor = &harness.supervisor;
    const worker = try fixture.publishWorker(supervisor, try handleWithPeer(testing.allocator, &child, &peer), .{});
    const demo_pool = supervisor.poolFor(demo);

    // The scan lists the worker, published idle with no reader. Before the
    // poll, lane 0 takes a slot through the pool, which tells the reaper
    // nothing, and the worker's answer to it turns the socket readable.
    try testing.expectEqual(@as(usize, 1), harness.reaper.scanWatchedWorkers());
    const served = try expectAcquired(demo_pool, 0, 1);
    const epoch = try expectNewReader(served);
    _ = try std.posix.write(peer.fd(), "answer");
    try testing.expectEqual(@as(usize, 1), harness.reaper.pollScannedWorkers());
    try testing.expect(child.alive());
    var view = demo_pool.inspect(worker) orelse return error.TestExpectedWorker;
    try testing.expectEqual(pool_mod.EntryState.live, view.state);
    try testing.expectEqual(@as(u8, 1), view.slots_held);
    try testing.expectEqual(@as(?pool_mod.ReaderTenure, .{ .lane = 0, .epoch = epoch }), view.reader);

    // Lane 0 reads the answer, ends its request and gives the role up, and
    // the worker then asks to be retired. A poll over the old scan still
    // refuses, since lane 0's tenure moved the epoch the scan saw.
    var answer: [16]u8 = undefined;
    _ = try std.posix.read(worker.handle.control_fd, &answer);
    try testing.expect((try demo_pool.release(worker, served.slot, 10)) == .idle);
    try testing.expectEqual(pool_mod.Transfer.vacated, demo_pool.transferReader(worker, .{ .lane = 0, .epoch = epoch }, .nothing));
    try ipc.worker_retiring.send(peer.fd(), .routes_failed);
    try testing.expectEqual(@as(usize, 1), harness.reaper.pollScannedWorkers());
    try testing.expect(child.alive());
    view = demo_pool.inspect(worker) orelse return error.TestExpectedWorker;
    try testing.expectEqual(pool_mod.EntryState.live, view.state);

    // The next scan sees the worker unread under its new epoch, and the
    // notice retires it as recycled.
    try testing.expectEqual(@as(usize, 1), harness.reaper.pollWatchedWorkers());
    try testing.expect(!child.alive());
    try expectTornDown(supervisor, worker);
    const counters = harness.reaper.countersSnapshot();
    try testing.expectEqual(@as(u64, 3), counters.notices_seen);
    try testing.expectEqual(@as(u64, 2), counters.notices_stale);
    try testing.expectEqual(@as(u64, 1), counters.retired_recycled);
    try testing.expectEqual(@as(u64, 0), counters.deaths_seen);
    try testing.expectEqual(@as(u64, 1), demo_pool.snapshot().counters.notice_retirements);
}

test "the idle pass asks again the reader that holds up a worker retiring on its notice, and the retirement then finishes as recycled" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();
    var child = try ParkedChild.spawn();
    defer child.deinit();
    const supervisor = &harness.supervisor;
    const worker = try fixture.publishWorker(supervisor, try handleFor(testing.allocator, &child), .{});
    const demo_pool = supervisor.poolFor(demo);

    // Lane 0 reads the worker and holds a slot; lane 1 holds the other.
    const read = try expectAcquired(demo_pool, 0, 1);
    const epoch = try expectNewReader(read);
    const other = try expectAcquired(demo_pool, 1, 1);
    // Lane 0 reads the worker's notice: the worker leaves service with its
    // requests, which finish on it.
    try testing.expect(demo_pool.retireOnNotice(worker, worker.key()) == .draining);
    try testing.expect((try demo_pool.release(worker, read.slot, 10)) == .idle);
    // Lane 1's release is the last one, so lane 1 asks lane 0 to let go, and
    // that post is lost.
    const tenure = switch (try demo_pool.release(worker, other.slot, 11)) {
        .release_reader => |tenure| tenure,
        .idle, .handed_to, .retire => return error.TestExpectedReaderRelease,
    };
    try testing.expectEqual(pool_mod.ReaderTenure{ .lane = 0, .epoch = epoch }, tenure);

    // The idle pass asks lane 0 again, and tears nothing down.
    _ = harness.reaper.retireIdleWorkers(5_000);
    try testing.expectEqual(@as(usize, 1), harness.recording.release_post_count);
    const post = harness.recording.release_posts[0];
    try testing.expectEqual(@as(pool_mod.LaneId, 0), post.lane);
    try testing.expect(post.worker_key.eql(worker.key()));
    try testing.expectEqual(epoch, post.epoch);
    try testing.expect(child.alive());

    // Lane 0 lets go and queues the retirement under the departure the pool
    // recorded.
    try testing.expectEqual(pool_mod.Transfer.retire, demo_pool.transferReader(worker, tenure, .nothing));
    const view = demo_pool.inspect(worker) orelse return error.TestExpectedWorker;
    const departure = view.departure orelse return error.TestExpectedDeparture;
    try testing.expectEqual(pool_mod.Departure.recycled, departure);
    harness.reaper.queueRetirement(worker, supervision.reaper.RetireReason.fromDeparture(departure));
    try testing.expectEqual(@as(usize, 1), harness.reaper.drainRetirements());
    try testing.expect(!child.alive());
    try expectTornDown(supervisor, worker);
    try testing.expectEqual(@as(u64, 1), harness.reaper.countersSnapshot().retired_recycled);
}

test "each worker the reaper retires gets one line in workers.jsonl that says how it ended" {
    var analytics_dir = try fixture.AnalyticsDir.init(testing.allocator);
    defer analytics_dir.deinit(testing.allocator);
    var harness: Harness = undefined;
    try harness.init(.{ .analytics_directory = analytics_dir.path });
    defer harness.deinit();
    // Every child before any handle, so no child holds another worker's
    // socket.
    var idle_child = try ParkedChild.spawn();
    defer idle_child.deinit();
    var recycled_child = try ParkedChild.spawn();
    defer recycled_child.deinit();
    var crashed_child = try ParkedChild.spawn();
    defer crashed_child.deinit();
    var recycled_peer: os_fd.OwnedFd = .{};
    defer recycled_peer.deinit();
    const supervisor = &harness.supervisor;
    const created_ns = process.monotonicNowNsOrZero();
    const idle = try fixture.publishWorker(supervisor, try handleFor(testing.allocator, &idle_child), .{
        .definition_index = demo,
        .now_ns = 1_000,
        .record = .{ .created_mono_ns = created_ns },
    });
    const recycled = try fixture.publishWorker(supervisor, try handleWithPeer(testing.allocator, &recycled_child, &recycled_peer), .{
        .definition_index = beta,
        .now_ns = 4_900,
        .record = .{ .created_mono_ns = created_ns },
    });
    // Its control socket hangs up, which the watch takes for a crash.
    const crashed = try fixture.publishWorker(supervisor, try handleFor(testing.allocator, &crashed_child), .{
        .definition_index = gamma,
        .now_ns = 4_900,
        .record = .{ .created_mono_ns = created_ns },
    });
    const Expected = struct { worker: []const u8, worker_id: u64, worker_generation: u64, ending: []const u8 };
    const expected = [_]Expected{
        .{ .worker = "demo", .worker_id = idle.id, .worker_generation = idle.generation, .ending = "idle" },
        .{ .worker = "beta", .worker_id = recycled.id, .worker_generation = recycled.generation, .ending = "recycled" },
        .{ .worker = "gamma", .worker_id = crashed.id, .worker_generation = crashed.generation, .ending = "crash" },
    };

    // The idle pass retires the worker idle past its TTL, then the watch the
    // one that sent its notice and the one that hung up.
    supervisor.worker_idle_ttl_ns = 1_000;
    try testing.expectEqual(@as(usize, 1), harness.reaper.retireIdleWorkers(5_000));
    try ipc.worker_retiring.send(recycled_peer.fd(), .routes_failed);
    try testing.expectEqual(@as(usize, 2), harness.reaper.pollWatchedWorkers());
    const finished_ns = process.monotonicNowNsOrZero();

    var lines = try analytics_dir.readWorkers(testing.allocator, supervisor.analytics);
    defer lines.deinit();
    try testing.expectEqual(expected.len, lines.items.len);
    for (expected, lines.items) |want, line| {
        try testing.expectEqualStrings(want.worker, line.worker);
        try testing.expectEqual(want.worker_id, line.worker_id);
        try testing.expectEqual(want.worker_generation, line.worker_generation);
        try testing.expectEqualStrings(want.ending, line.ending);
        try testing.expect(line.life_ns > 0);
        try testing.expect(line.life_ns <= finished_ns - created_ns);
        try testing.expect(line.started_ts <= line.ts);
        // The fixture's cgroup leaf never exists, so the kernel's figures are
        // absent, never a made-up zero.
        try testing.expectEqual(@as(?u64, null), line.worker_cpu_ns);
        try testing.expectEqual(@as(?u64, null), line.memory_peak_bytes);
    }
    try testing.expectEqual(@as(u64, 0), supervisor.analytics.stats(.workers).dropped);
}

test "an egress retirement records the death its worker met first: memory from the page, a crash from an exit, and its own ending only for a worker still running" {
    var analytics_dir = try fixture.AnalyticsDir.init(testing.allocator);
    defer analytics_dir.deinit(testing.allocator);
    var harness: Harness = undefined;
    try harness.init(.{ .analytics_directory = analytics_dir.path });
    defer harness.deinit();
    var running_child = try ParkedChild.spawn();
    defer running_child.deinit();
    var crashed_child = try ParkedChild.spawn();
    defer crashed_child.deinit();
    var memory_child = try ParkedChild.spawn();
    defer memory_child.deinit();
    var removed_child = try ParkedChild.spawn();
    defer removed_child.deinit();
    const supervisor = &harness.supervisor;
    const Case = struct {
        child: *const ParkedChild,
        definition: config.DefinitionIndex,
        memory_stamped: bool = false,
        departure: pool_mod.Departure,
        ending: []const u8,
    };
    const cases = [_]Case{
        .{ .child = &running_child, .definition = demo, .departure = .egress, .ending = "egress_reattach" },
        .{ .child = &crashed_child, .definition = beta, .departure = .egress, .ending = "crash" },
        .{ .child = &memory_child, .definition = gamma, .memory_stamped = true, .departure = .egress, .ending = "memory_high" },
        // A session its gateway removed for the worker's doing, still running; the pool takes
        // one worker at a time, and the first case's is gone by then.
        .{ .child = &removed_child, .definition = demo, .departure = .egress_removed, .ending = "egress_session_removed" },
    };
    var worker_ids: [cases.len]u64 = undefined;

    // Two workers died before the launcher's retirement reached the reaper, as when the gateway
    // reported their session gone ahead of their own pidfd.
    try crashed_child.kill();
    try memory_child.kill();
    for (cases, &worker_ids) |case, *worker_id| {
        const handle = if (case.memory_stamped)
            try handleStampedMemory(testing.allocator, case.child)
        else
            try handleFor(testing.allocator, case.child);
        const worker = try fixture.publishWorker(supervisor, handle, .{ .definition_index = case.definition });
        worker_id.* = worker.id;
        const death = supervisor.poolFor(worker.definition_index).retireForEgress(worker, worker.key(), case.departure) orelse
            return error.TestExpectedRetirement;
        try testing.expect(death.retire);
        harness.reaper.queueRetirement(worker, supervision.reaper.RetireReason.fromDeparture(case.departure));
        try testing.expectEqual(@as(usize, 1), harness.reaper.drainRetirements());
        try expectTornDown(supervisor, worker);
    }

    var lines = try analytics_dir.readWorkers(testing.allocator, supervisor.analytics);
    defer lines.deinit();
    try testing.expectEqual(cases.len, lines.items.len);
    for (cases, worker_ids, lines.items) |case, worker_id, line| {
        try testing.expectEqual(worker_id, line.worker_id);
        try testing.expectEqualStrings(case.ending, line.ending);
    }
    const counters = harness.reaper.countersSnapshot();
    try testing.expectEqual(@as(u64, 3), counters.retired_egress_reattach);
    try testing.expectEqual(@as(u64, 1), counters.retired_egress_session_removed);
}

test "a worker line that finds its stream full is written out with the stream, not dropped" {
    var analytics_dir = try fixture.AnalyticsDir.init(testing.allocator);
    defer analytics_dir.deinit(testing.allocator);
    var harness: Harness = undefined;
    try harness.init(.{ .analytics_directory = analytics_dir.path });
    defer harness.deinit();
    var child = try ParkedChild.spawn();
    defer child.deinit();
    const supervisor = &harness.supervisor;
    const worker = try fixture.publishWorker(supervisor, try handleFor(testing.allocator, &child), .{});
    const worker_id = worker.id;

    // Earlier teardowns left the stream no room for one more line, as a
    // shutdown's do, since nothing flushes between them.
    try fixture.fillStream(testing.allocator, supervisor.analytics, .workers, 16);
    const death = supervisor.poolFor(demo).markDead(worker, worker.key()) orelse return error.TestExpectedDeath;
    try testing.expect(death.retire);
    harness.reaper.queueRetirement(worker, .died);
    try testing.expectEqual(@as(usize, 1), harness.reaper.drainRetirements());

    try testing.expectEqual(@as(u64, 0), supervisor.analytics.stats(.workers).dropped);
    var lines = try analytics_dir.readWorkers(testing.allocator, supervisor.analytics);
    defer lines.deinit();
    try testing.expectEqual(@as(usize, 1), lines.items.len);
    try testing.expectEqual(worker_id, lines.items[0].worker_id);
    try testing.expectEqualStrings("crash", lines.items[0].ending);
}

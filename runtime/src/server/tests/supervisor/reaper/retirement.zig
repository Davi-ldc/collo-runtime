//! Retirement on the reaper (`server/supervisor/reaper/`). A lane's deadline
//! floor leaves its worker alive, and a worker that left service is torn down
//! by the reaper, never by the thread that decided it was done. An idle
//! worker past its TTL with no reader retires at once, and one with a reader
//! leaves service and is torn down only after that reader gives its role up.
//! A retirement naming a worker still in service is refused, a removal that
//! leaves its pool wanting a worker asks for a launch, and a failed launch's
//! leftovers are torn down like a worker. The reaper's queue and idle pass
//! run on the test thread here, with the lanes and the launcher replaced by a
//! double that records what the reaper asks of them. The reaper thread
//! itself, with its pidfd polling and its readings of the node's memory, runs
//! only in a whole server (`local-e2e`). Lane `server-supervisor-test`.

const std = @import("std");
const host = @import("collo_host");
const ipc = @import("collo_ipc");
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

var path_sequence: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// A worker handle for `child` that `WorkerHandle.deinit` takes apart end to
/// end, taking over `child.pidfd`: a temp tree with a cgroup path inside it
/// that is never created, so the teardown never reaches the delegated cgroup
/// subtree, a control socket whose peer is closed, eventfds, the payload
/// memfd and a real shared page.
fn handleFor(allocator: std.mem.Allocator, child: *const ParkedChild) !host.WorkerHandle {
    const tmp_root = try std.fmt.allocPrint(allocator, "/tmp/collo-test-retire-{d}-{d}", .{
        std.os.linux.getpid(),
        path_sequence.fetchAdd(1, .monotonic),
    });
    defer allocator.free(tmp_root);
    try std.fs.makeDirAbsolute(tmp_root);
    errdefer std.fs.deleteTreeAbsolute(tmp_root) catch {};
    const cgroup_dir = try std.fmt.allocPrint(allocator, "{s}/cgroup", .{tmp_root});
    defer allocator.free(cgroup_dir);

    const pair = try os_fd.socketPairType(std.posix.SOCK.SEQPACKET);
    errdefer std.posix.close(pair[0]);
    std.posix.close(pair[1]);
    const completion_eventfd = try std.posix.eventfd(0, 0);
    errdefer std.posix.close(completion_eventfd);
    const credit_eventfd = try std.posix.eventfd(0, 0);
    errdefer std.posix.close(credit_eventfd);
    const payload_fd = try worker_shared_page.createMemfd("collo-test-retire-payload");
    errdefer std.posix.close(payload_fd);
    const metrics_fd = try worker_shared_page.createMemfd("collo-test-retire-metrics");
    errdefer std.posix.close(metrics_fd);
    var metrics = try worker_shared_page.mapReadWrite(metrics_fd);
    errdefer metrics.deinit();
    metrics.initializeCrashDefault(1, 0, 0);

    return host.WorkerHandle.init(
        allocator,
        @intCast(child.pid),
        child.pidfd,
        pair[0],
        tmp_root,
        cgroup_dir,
        64 * 1024 * 1024,
        1,
        metrics_fd,
        completion_eventfd,
        payload_fd,
        credit_eventfd,
        .{ .bytes = &inert_payload_bytes, .header = &inert_payload_header, .side = .server },
        metrics,
        -1,
    );
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

test "a lane's deadline floor settles its request and leaves the worker alive in its pool (#39)" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();
    var child = try ParkedChild.spawn();
    defer child.deinit();
    const supervisor = &harness.supervisor;
    const worker = try fixture.publishWorker(supervisor, try handleFor(testing.allocator, &child), .{});
    const demo_pool = supervisor.poolFor(demo);
    const key = worker.key();

    // Lane 0's request reached its deadline with no completion, and the lane
    // writes its floor while it still holds the slot.
    const served = try expectAcquired(demo_pool, 0, 1);
    try worker.requests.record(fixture.dispatchedRequest(1));
    supervisor.settleRequest(worker, 1, .{ .floor = .{ .status = .deadline } });
    // With no analytics directory the sink counts the floor and drops it.
    try testing.expectEqual(@as(u64, 1), supervisor.analytics.stats(.usage).discarded);
    try testing.expect(worker.requests.dispatchedFor(1) == null);

    // The settle killed nothing and emptied nothing: the process runs, the
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
    var leaf_path: []u8 = undefined;
    const leaf = try fixture.openScratchDir(testing.allocator, &leaf_path);
    defer {
        std.fs.deleteTreeAbsolute(leaf_path) catch {};
        testing.allocator.free(leaf_path);
    }

    // The launcher hands over what the child left, and never kills, waits or
    // removes anything itself.
    harness.reaper.queueLeftovers(.{ .child = .{
        .pid = @intCast(child.pid),
        .pidfd = os_fd.OwnedFd.fromRaw(child.pidfd),
        .cgroup_dir = os_fd.OwnedFd.fromRaw(leaf.fd),
    } });
    try testing.expect(child.alive());

    // Once they are torn down, the launcher gets back the room in its launch
    // table they held.
    try testing.expectEqual(@as(usize, 1), harness.reaper.drainRetirements());
    try testing.expect(!child.alive());
    try testing.expectError(error.FileNotFound, std.fs.accessAbsolute(leaf_path, .{}));
    try testing.expectEqual(@as(usize, 1), harness.recording.leftovers_reaped);
}

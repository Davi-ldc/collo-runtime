//! The worker supervisor's own state and decisions
//! (`server/supervisor/supervisor.zig`): its pools and record table built
//! whole or not at all, a worker torn down with the supervisor, its last
//! console lines drained under the request ids its request table confirms
//! and its line in `workers.jsonl` ended by the shutdown, a worker that
//! answered at its own deadline staying in service, and a worker's egress
//! session: the launcher rewrites it only while the record holds that worker
//! in service, retires a live worker whose session its gateway removed, and
//! after a gateway is lost takes the workers whose session is stale one at a
//! time. The pools in detail are covered in `worker_pool.zig` and `pool.zig`,
//! the request table and the usage floor in `usage.zig`, how a worker's
//! death classifies and the figures read off its leaf in `worker_table.zig`,
//! and the retirement of a worker in `reaper/retirement.zig`. Lane
//! `server-supervisor-test`.

const std = @import("std");
const ipc = @import("collo_ipc");
const process = @import("collo_os").process;
const analytics = @import("collo_server_analytics");
const routes_mod = @import("collo_server_routes");
const zygote = @import("collo_zygote");
const supervision = @import("collo_server_supervisor");
const fixture = @import("supervisor_fixture");

const Supervisor = supervision.Supervisor;
const request_table = supervision.request_table;
const worker_table = supervision.worker_table;
const WorkerRecord = worker_table.Record;
const pool_mod = supervision.pool;
const WorkerPool = pool_mod.Pool(WorkerRecord);

const demo = fixture.default_definition;
const beta: u16 = 1;
const far_ns: u64 = std.math.maxInt(u64);

fn expectAcquired(worker_pool: *WorkerPool, lane: pool_mod.LaneId, request: u32) !WorkerPool.Acquired {
    return switch (worker_pool.acquire(lane, .{ .lane_id = lane, .slot = request, .generation = 1 }, far_ns)) {
        .acquired => |acquired| acquired,
        .wait, .full => error.TestExpectedAcquired,
    };
}

fn buildAndTearDownSupervisor(
    allocator: std.mem.Allocator,
    routes: *const routes_mod.Routes,
    sink: *analytics.Sink,
    zygote_process: *zygote.host_client.SpawnedZygote,
) !void {
    var supervisor = try Supervisor.init(allocator, zygote_process, routes, sink, .{}, null);
    supervisor.deinit();
}

test "the supervisor's pools and record table are built whole or not at all" {
    const allocator = std.testing.allocator;
    const owned_routes = try fixture.OwnedRoutes.create(allocator);
    defer owned_routes.destroy(allocator);
    var sink: analytics.Sink = undefined;
    try sink.open(allocator, .{ .directory = null });
    defer sink.close();
    var zygote_stand_in = zygote.host_client.SpawnedZygote{
        .pid = 0,
        .pidfd = -1,
        .control_fd = null,
        .trace_read_fd = null,
        .trace_write_fd = null,
    };

    // Each allocation of the build fails in turn, and the testing allocator
    // checks that every failure leaves nothing behind.
    try std.testing.checkAllAllocationFailures(
        allocator,
        buildAndTearDownSupervisor,
        .{ &owned_routes.routes, &sink, &zygote_stand_in },
    );
}

/// The fields of a `logs.jsonl` line the shutdown test checks.
const LogLine = struct {
    worker_id: u64,
    route: []const u8,
    request_id: u64,
    message: []const u8,
};

test "a worker still in its pool when the supervisor ends is torn down, its last console lines drained under the requests its table confirms and its line in workers.jsonl ended by the shutdown" {
    const allocator = std.testing.allocator;
    var analytics_dir = try fixture.AnalyticsDir.init(allocator);
    defer analytics_dir.deinit(allocator);
    var supervisor = try fixture.minimalSupervisorWithAnalytics(allocator, analytics_dir.path);
    var supervisor_live = true;
    defer if (supervisor_live) fixture.deinitMinimal(&supervisor);

    const worker = try fixture.publishInertWorker(&supervisor, .{
        .record = .{ .created_mono_ns = process.monotonicNowNsOrZero() },
    });
    const worker_id = worker.id;
    const worker_generation = worker.generation;
    // The worker served request 501, then wrote one line under it and one
    // under a request it was never dispatched, which no drain read yet.
    try worker.requests.record(fixture.dispatchedRequest(501));
    worker.requests.end(501);
    var worker_page = try fixture.WorkerPage.attach(worker);
    defer worker_page.deinit();
    const view = &worker_page.writer;
    view.publishLogLine(.info, 0, 501, 1, "served");
    view.publishLogLine(.info, 0, 777, 1, "forged");

    // The supervisor's end drains the ring before the page goes and writes
    // the worker's line, closing the sink writes both out, and the testing
    // allocator proves the worker's handle and scratch went too.
    fixture.deinitMinimal(&supervisor);
    supervisor_live = false;

    var worker_lines = try analytics_dir.readWorkers(allocator, null);
    defer worker_lines.deinit();
    try std.testing.expectEqual(@as(usize, 1), worker_lines.items.len);
    try std.testing.expectEqualStrings(fixture.definition_names[demo], worker_lines.items[0].worker);
    try std.testing.expectEqual(worker_id, worker_lines.items[0].worker_id);
    try std.testing.expectEqual(worker_generation, worker_lines.items[0].worker_generation);
    try std.testing.expectEqualStrings("shutdown", worker_lines.items[0].ending);

    const contents = try analytics_dir.tmp.dir.readFileAlloc(allocator, "logs.jsonl", 64 * 1024);
    defer allocator.free(contents);
    var lines = std.mem.tokenizeScalar(u8, contents, '\n');
    const served = try std.json.parseFromSlice(LogLine, allocator, lines.next() orelse return error.TestExpectedLogLine, .{ .ignore_unknown_fields = true });
    defer served.deinit();
    try std.testing.expectEqual(worker_id, served.value.worker_id);
    try std.testing.expectEqual(@as(u64, 501), served.value.request_id);
    try std.testing.expectEqualStrings(fixture.route_patterns[demo], served.value.route);
    try std.testing.expectEqualStrings("served", served.value.message);
    const forged = try std.json.parseFromSlice(LogLine, allocator, lines.next() orelse return error.TestExpectedLogLine, .{ .ignore_unknown_fields = true });
    defer forged.deinit();
    try std.testing.expectEqual(@as(u64, 0), forged.value.request_id);
    try std.testing.expectEqualStrings("", forged.value.route);
    try std.testing.expectEqualStrings("forged", forged.value.message);
    try std.testing.expect(lines.next() == null);
}

test "a worker that answered 504 at one request's deadline stays in service and keeps its other request (#44)" {
    var supervisor = try fixture.minimalSupervisor(std.testing.allocator);
    defer fixture.deinitMinimal(&supervisor);
    const worker = try fixture.publishInertWorker(&supervisor, .{});
    const demo_pool = supervisor.poolFor(demo);

    // Two requests from two lanes share the worker's two slots.
    const timed_out = try expectAcquired(demo_pool, 0, 1);
    const other = try expectAcquired(demo_pool, 1, 1);
    try std.testing.expect(timed_out.worker == worker);
    try std.testing.expect(other.worker == worker);
    try worker.requests.record(fixture.dispatchedRequest(1));
    try worker.requests.record(fixture.dispatchedRequest(2));

    // The worker's sentinel ended the first request at its deadline: the
    // worker answered 504 itself and sent its `request_done`. The lane ends
    // the request and gives its slot back.
    worker.requests.end(1);
    try std.testing.expect((try demo_pool.release(worker, timed_out.slot, 10)) == .idle);

    // Nothing took the worker out of service or queued its retirement, and it
    // still holds the other request's slot and entry.
    const view = demo_pool.inspect(worker) orelse return error.TestExpectedWorker;
    try std.testing.expectEqual(pool_mod.EntryState.live, view.state);
    try std.testing.expectEqual(@as(u8, 1), view.slots_held);
    const counters = demo_pool.snapshot().counters;
    try std.testing.expectEqual(@as(u64, 0), counters.deaths);
    try std.testing.expectEqual(@as(u64, 0), counters.retirements);
    try std.testing.expectEqual(
        request_table.ForwardCheck.live,
        worker.requests.forwardCheck(2, fixture.dispatchedRequest(2).request_key),
    );

    // The other request completes on the same worker.
    worker.requests.end(2);
    try std.testing.expect((try demo_pool.release(worker, other.slot, 20)) == .idle);
    const after = demo_pool.inspect(worker) orelse return error.TestExpectedWorker;
    try std.testing.expectEqual(pool_mod.EntryState.live, after.state);
    try std.testing.expectEqual(@as(u8, 0), after.slots_held);
}

test "a worker's egress session changes only while its record holds that worker in service" {
    var supervisor = try fixture.minimalSupervisor(std.testing.allocator);
    defer fixture.deinitMinimal(&supervisor);
    const worker = try fixture.publishInertWorker(&supervisor, .{ .record = .{
        .egress_gateway_generation = 1,
        .egress_gateway_session_id = 5,
    } });
    try expectWorkerEgress(&supervisor, worker, .{ .generation = 1, .session_id = 5 });

    var target = reattachTargetOf(worker);
    try std.testing.expect(supervisor.setWorkerEgress(&target, 2, 6));
    try expectWorkerEgress(&supervisor, worker, .{ .generation = 2, .session_id = 6 });

    // A target that names another worker of the same record writes nothing.
    var other = target;
    other.worker_key.worker_id +%= 1;
    try std.testing.expect(!supervisor.setWorkerEgress(&other, 3, 7));
    try expectWorkerEgress(&supervisor, worker, .{ .generation = 2, .session_id = 6 });

    // Nor does one whose worker an egress retirement took out of service, which
    // happens once.
    const death = supervisor.retireForEgress(&target) orelse return error.TestExpectedRetirement;
    try std.testing.expect(death.retire);
    try std.testing.expect(supervisor.retireForEgress(&target) == null);
    try std.testing.expect(!supervisor.setWorkerEgress(&target, 3, 7));
    try expectWorkerEgress(&supervisor, worker, .{ .generation = 2, .session_id = 6 });
    const view = supervisor.poolFor(demo).inspect(worker) orelse return error.TestExpectedWorker;
    try std.testing.expectEqual(pool_mod.EntryState.dead, view.state);
    try std.testing.expectEqual(@as(?pool_mod.Departure, .egress), view.departure);
}

test "the next stale egress worker is the first live worker of another gateway, with dups of its control socket and wake set" {
    var supervisor = try fixture.minimalSupervisor(std.testing.allocator);
    defer fixture.deinitMinimal(&supervisor);
    const current: u64 = 4;
    const fresh = try fixture.publishInertWorker(&supervisor, .{
        .definition_index = demo,
        .record = .{
            .egress_gateway_generation = current,
            .egress_gateway_session_id = 1,
            .egress_wake_set = try ipc.egress_shared.WakeSet.create(),
        },
    });
    const stale = try fixture.publishInertWorker(&supervisor, .{
        .definition_index = beta,
        .record = .{
            .egress_gateway_generation = current - 1,
            .egress_gateway_session_id = 2,
            .egress_wake_set = try ipc.egress_shared.WakeSet.create(),
        },
    });

    var target = supervisor.nextStaleEgressWorker(current) orelse return error.TestExpectedStaleWorker;
    defer target.deinit();
    try std.testing.expectEqual(beta, target.definition);
    try std.testing.expectEqual(stale, target.record);
    try std.testing.expect(target.worker_key.eql(stale.key()));
    try expectSameFile(target.control.fd(), stale.handle.control_fd);
    const wake = &stale.egress_wake_set;
    try expectSameEventfd(target.wake_set.command_event.fd(), wake.command_event.fd());
    try expectSameEventfd(target.wake_set.completion_event.fd(), wake.completion_event.fd());
    try expectSameFile(target.wake_set.liveness_read.fd(), wake.liveness_read.fd());
    try expectSameFile(target.wake_set.peer_liveness_read.fd(), wake.peer_liveness_read.fd());

    // Once it has a session of the current gateway, no worker is stale.
    try std.testing.expect(supervisor.setWorkerEgress(&target, current, 3));
    try std.testing.expect(supervisor.nextStaleEgressWorker(current) == null);

    // Under the next gateway both are, in definition order, and a worker an
    // egress retirement took out of service is never handed out again.
    var first = supervisor.nextStaleEgressWorker(current + 1) orelse return error.TestExpectedStaleWorker;
    defer first.deinit();
    try std.testing.expectEqual(fresh, first.record);
    _ = supervisor.retireForEgress(&first) orelse return error.TestExpectedRetirement;
    var second = supervisor.nextStaleEgressWorker(current + 1) orelse return error.TestExpectedStaleWorker;
    defer second.deinit();
    try std.testing.expectEqual(stale, second.record);
}

test "the reattach pass never names a worker of a definition without a network grant" {
    var granted: [fixture.definition_names.len]bool = @splat(true);
    granted[demo] = false;
    var supervisor = try fixture.minimalSupervisorWith(std.testing.allocator, .{ .routes = .{ .granted = granted } });
    defer fixture.deinitMinimal(&supervisor);
    const current: u64 = 4;
    // Session 0 of no gateway is what a worker without a grant holds, which
    // reads as stale under any gateway.
    _ = try fixture.publishInertWorker(&supervisor, .{ .definition_index = demo });
    try std.testing.expect(supervisor.nextStaleEgressWorker(current) == null);

    const granted_worker = try fixture.publishInertWorker(&supervisor, .{
        .definition_index = beta,
        .record = .{ .egress_wake_set = try ipc.egress_shared.WakeSet.create() },
    });
    var target = supervisor.nextStaleEgressWorker(current) orelse return error.TestExpectedStaleWorker;
    defer target.deinit();
    try std.testing.expectEqual(granted_worker, target.record);
}

test "a session its gateway removed retires the live worker that holds it, once, and no pass reaches it" {
    var supervisor = try fixture.minimalSupervisor(std.testing.allocator);
    defer fixture.deinitMinimal(&supervisor);
    const current: u64 = 4;
    const kept = try fixture.publishInertWorker(&supervisor, .{
        .definition_index = demo,
        .record = .{
            .egress_gateway_generation = current,
            .egress_gateway_session_id = 7,
            .egress_wake_set = try ipc.egress_shared.WakeSet.create(),
        },
    });
    const lost = try fixture.publishInertWorker(&supervisor, .{
        .definition_index = beta,
        .record = .{
            .egress_gateway_generation = current,
            .egress_gateway_session_id = 8,
            .egress_wake_set = try ipc.egress_shared.WakeSet.create(),
        },
    });

    // The same session id under another gateway, or another session of this
    // one, names no worker.
    try std.testing.expect(supervisor.retireEgressSession(current - 1, 8) == null);
    try std.testing.expect(supervisor.retireEgressSession(current, 9) == null);

    const retired = supervisor.retireEgressSession(current, 8) orelse return error.TestExpectedRetirement;
    try std.testing.expectEqual(lost, retired.record);
    try std.testing.expect(retired.worker_key.eql(lost.key()));
    try std.testing.expect(retired.death.retire);
    const view = supervisor.poolFor(beta).inspect(lost) orelse return error.TestExpectedWorker;
    try std.testing.expectEqual(pool_mod.EntryState.dead, view.state);
    // The departure names the removal, so the worker's line blames the worker and not a lost
    // gateway.
    try std.testing.expectEqual(@as(?pool_mod.Departure, .egress_removed), view.departure);
    try expectWorkerEgress(&supervisor, kept, .{ .generation = current, .session_id = 7 });
    // Under the next gateway only the worker still in service is stale, so no
    // pass gives the retired one a session.
    var next = supervisor.nextStaleEgressWorker(current + 1) orelse return error.TestExpectedStaleWorker;
    defer next.deinit();
    try std.testing.expectEqual(kept, next.record);
    // A second report of the session finds no worker on it.
    try std.testing.expect(supervisor.retireEgressSession(current, 8) == null);

    // A worker already out of service is not retired again.
    var kept_target = reattachTargetOf(kept);
    _ = supervisor.retireForEgress(&kept_target) orelse return error.TestExpectedRetirement;
    try std.testing.expect(supervisor.retireEgressSession(current, 7) == null);
}

/// A reattach target naming `worker` as `Supervisor.nextStaleEgressWorker`
/// does, without the descriptors, which the egress reads and writes ignore.
fn reattachTargetOf(worker: *WorkerRecord) supervision.launcher.ReattachTarget {
    return .{
        .definition = worker.definition_index,
        .record = worker,
        .worker_key = worker.key(),
        .control = .{},
        .wake_set = .{},
    };
}

const ExpectedEgress = struct {
    generation: u64,
    session_id: u64,
};

fn expectWorkerEgress(supervisor: *Supervisor, worker: *WorkerRecord, expected: ExpectedEgress) !void {
    const egress = supervisor.workerEgress(worker);
    try std.testing.expectEqual(expected.generation, egress.generation);
    try std.testing.expectEqual(expected.session_id, egress.session_id);
}

/// Checks that `dup_fd` is another descriptor of the file `original_fd`
/// opens, by its device and inode.
fn expectSameFile(dup_fd: std.posix.fd_t, original_fd: std.posix.fd_t) !void {
    try std.testing.expect(dup_fd != original_fd);
    const dup_stat = try std.posix.fstat(dup_fd);
    const original_stat = try std.posix.fstat(original_fd);
    try std.testing.expectEqual(original_stat.dev, dup_stat.dev);
    try std.testing.expectEqual(original_stat.ino, dup_stat.ino);
}

/// Checks that `dup_fd` is another descriptor of the eventfd `original_fd`
/// opens. Every eventfd shares one inode, so the check counts through one
/// and reads the count from the other.
fn expectSameEventfd(dup_fd: std.posix.fd_t, original_fd: std.posix.fd_t) !void {
    try std.testing.expect(dup_fd != original_fd);
    const one: u64 = 1;
    try std.testing.expectEqual(@as(usize, 8), try std.posix.write(dup_fd, std.mem.asBytes(&one)));
    var count: u64 = 0;
    try std.testing.expectEqual(@as(usize, 8), try std.posix.read(original_fd, std.mem.asBytes(&count)));
    try std.testing.expectEqual(one, count);
}

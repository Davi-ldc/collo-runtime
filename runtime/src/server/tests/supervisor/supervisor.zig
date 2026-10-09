//! The worker supervisor's own state and decisions
//! (`server/supervisor/supervisor.zig`): its pools and record table built
//! whole or not at all, a worker torn down with the supervisor, its last
//! usage record written and its tmp root removed, how a worker's death
//! classifies from the termination reason on its page, the usage drain (a
//! full ring of refused records, and a head past the ring that fails it for
//! good), synthesis and a full usage stream as the supervisor runs them, the
//! settle a lane makes when a request ends (`Supervisor.settleRequest`),
//! which never takes the worker out of its pool, and a worker's egress
//! session: the launcher rewrites it only while the record holds that worker
//! in service, takes a live worker off a session its gateway removed, and
//! after a gateway is lost takes the workers whose session is stale one at a
//! time. The pools in detail are covered in `worker_pool.zig` and `pool.zig`,
//! the usage path's record format and exactly-once rules in `usage.zig`, and
//! the retirement of a worker in `reaper/retirement.zig`. Lane
//! `server-supervisor-test`.

const std = @import("std");
const ipc = @import("collo_ipc");
const analytics = @import("collo_server_analytics");
const routes_mod = @import("collo_server_routes");
const zygote = @import("collo_zygote");
const worker_shared_page = @import("collo_worker_state").page;
const worker_metrics_state = @import("collo_worker_state").metrics;
const supervision = @import("collo_server_supervisor");
const fixture = @import("supervisor_fixture");

const Supervisor = supervision.Supervisor;
const usage_drain = supervision.usage_drain;
const usage_log = supervision.usage_log;
const request_table = supervision.request_table;
const worker_table = supervision.worker_table;
const WorkerRecord = worker_table.Record;
const usage_key = supervision.accounting.usage;
const pool_mod = supervision.pool;
const WorkerPool = pool_mod.Pool(WorkerRecord);

const demo = fixture.default_definition;
const beta: u16 = 1;
const far_ns: u64 = std.math.maxInt(u64);

/// Worker-written usage records the supervisor's drains refused.
fn rejectedRecords(supervisor: *Supervisor) u64 {
    return supervisor.usageDrain().counters.records_rejected.load(.monotonic);
}

/// The request table entry of a request the server dispatched as `identity`
/// names it, to route 0 of the worker's definition, at 1 ns.
fn dispatchedAs(identity: worker_shared_page.LifecycleIdentity) request_table.Dispatched {
    return .{
        .request_id = identity.external_request_id,
        .request_key = .{
            .lane_id = identity.request_lane_id,
            .slot = identity.request_slot,
            .generation = identity.request_generation,
        },
        .route = 0,
        .accounting_flags = 0,
        .started_mono_ns = 1,
    };
}

/// Records left in `worker`'s usage ring as the worker's room check counts
/// them: from the tail the server last stored on the page to the worker's
/// head.
fn pendingRecords(worker: *const WorkerRecord) u64 {
    const header = worker.handle.metrics.?.header;
    return @atomicLoad(u64, &header.records_head, .acquire) -% @atomicLoad(u64, &header.records_tail, .acquire);
}

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
        .next_fork_job_id = 1,
    };

    // Each allocation of the build fails in turn, and the testing allocator
    // checks that every failure leaves nothing behind.
    try std.testing.checkAllAllocationFailures(
        allocator,
        buildAndTearDownSupervisor,
        .{ &owned_routes.routes, &sink, &zygote_stand_in },
    );
}

test "a worker still in its pool when the supervisor ends is torn down, its last usage record written and its tmp root gone" {
    const allocator = std.testing.allocator;
    var analytics_dir = try fixture.AnalyticsDir.init(allocator);
    defer analytics_dir.deinit(allocator);
    var supervisor = try fixture.minimalSupervisorWithAnalytics(allocator, analytics_dir.path);
    var supervisor_live = true;
    defer if (supervisor_live) fixture.deinitMinimal(&supervisor);

    const worker = try fixture.publishInertWorker(&supervisor, .{});
    try fixture.publishCompletedRecord(worker, 501);
    const tmp_root = try allocator.dupe(u8, worker.handle.tmp_root);
    defer allocator.free(tmp_root);

    // The record is still in the worker's ring. The supervisor's end drains it
    // before the page goes, closing the sink writes it, and the testing
    // allocator proves the worker's handle and scratch went too.
    fixture.deinitMinimal(&supervisor);
    supervisor_live = false;
    try std.testing.expectError(error.FileNotFound, std.fs.accessAbsolute(tmp_root, .{}));

    const contents = try analytics_dir.tmp.dir.readFileAlloc(allocator, "usage.jsonl", 64 * 1024);
    defer allocator.free(contents);
    var lines = std.mem.tokenizeScalar(u8, contents, '\n');
    const line = lines.next() orelse return error.TestExpectedUsageRecord;
    try std.testing.expect(lines.next() == null);
    const parsed = try std.json.parseFromSlice(fixture.UsageLine, allocator, line, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u64, 501), parsed.value.request_id);
    try std.testing.expectEqualStrings("worker", parsed.value.origin);
    try std.testing.expectEqualStrings(fixture.route_patterns[demo], parsed.value.route);
}

test "a worker's death classifies by the termination reason on its page when the enum names it, and by its cgroup otherwise" {
    var supervisor = try fixture.minimalSupervisorWithAnalytics(std.testing.allocator, null);
    defer fixture.deinitMinimal(&supervisor);
    // The inert handle's cgroup directory was never created, so a death the
    // cgroup decides reads as a crash.
    const worker = try fixture.publishInertWorker(&supervisor, .{});
    const header = worker.handle.metrics.?.header;

    // The sentinel's memory stamp decides whatever state sits next to it.
    @atomicStore(u32, &header.state, 77, .release);
    @atomicStore(u32, &header.termination_reason, @intFromEnum(worker_shared_page.TerminationReason.memory), .release);
    try std.testing.expectEqual(
        worker_shared_page.CompletedStatus.memory,
        usage_drain.classifyWorkerDeath(supervisor.usageDrain(), worker),
    );

    // A reason `TerminationReason` does not name says nothing.
    @atomicStore(u32, &header.termination_reason, 99, .release);
    try std.testing.expectEqual(
        worker_shared_page.CompletedStatus.crash,
        usage_drain.classifyWorkerDeath(supervisor.usageDrain(), worker),
    );
}

test "a supervisor drain writes the worker's measurements to usage.jsonl" {
    var analytics_dir = try fixture.AnalyticsDir.init(std.testing.allocator);
    defer analytics_dir.deinit(std.testing.allocator);
    var supervisor = try fixture.minimalSupervisorWithAnalytics(std.testing.allocator, analytics_dir.path);
    defer fixture.deinitMinimal(&supervisor);

    const fd = try worker_shared_page.createMemfd("worker-usage-drain");
    defer std.posix.close(fd);
    var view = try worker_shared_page.mapReadWrite(fd);
    defer view.deinit();
    view.initializeCrashDefault(1, 0, 0);

    var state = worker_metrics_state.WorkState.init(&view);
    try state.appendCompletedRecord(std.mem.zeroInit(worker_shared_page.CompletedRecord, .{
        .request_id = 1,
        .started_mono_ns = 10,
        .finished_mono_ns = 20,
        .cpu_time_ns = 1,
        .io_time_ns = 9,
        .client_served_bytes = 100,
        .fetch_billed_sent_bytes = 20,
        .fetch_billed_received_bytes = 3,
        .status = @intFromEnum(worker_shared_page.CompletedStatus.done),
    }));

    var worker = fixture.stackWorker(1, 1, demo);
    worker.handle.metrics = view;
    worker.page_mapped = true;
    try worker.requests.record(fixture.dispatchedRequest(1));

    try std.testing.expectEqual(
        @as(usize, 1),
        usage_drain.drainWorker(supervisor.usageDrain(), &worker),
    );
    try std.testing.expectEqual(@as(u64, 0), pendingRecords(&worker));

    var lines = try analytics_dir.readUsage(std.testing.allocator, supervisor.analytics);
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    const line = lines.items[0];
    try std.testing.expectEqual(@as(u64, 1), line.request_id);
    try std.testing.expectEqualStrings("demo", line.worker);
    try std.testing.expectEqual(@as(u64, 10), line.wall_time_ns);
    try std.testing.expectEqual(@as(u64, 1), line.cpu_time_ns);
    try std.testing.expectEqual(@as(u64, 9), line.io_time_ns);
    try std.testing.expectEqual(@as(u64, 100), line.client_served_bytes);
    try std.testing.expectEqual(@as(u64, 20), line.fetch_sent_bytes);
    try std.testing.expectEqual(@as(u64, 3), line.fetch_received_bytes);
}

/// A successful completion record the worker writes for `identity`.
fn completedFor(identity: worker_shared_page.LifecycleIdentity) worker_shared_page.CompletedRecord {
    return std.mem.zeroInit(worker_shared_page.CompletedRecord, .{
        .request_id = identity.external_request_id,
        .request_generation = identity.request_generation,
        .worker_id = identity.worker_id,
        .worker_generation = identity.worker_generation,
        .started_mono_ns = 1,
        .finished_mono_ns = 2,
        .cpu_time_ns = 77,
        .client_served_bytes = 4,
        .request_slot = identity.request_slot,
        .request_lane_id = identity.request_lane_id,
        .status = @intFromEnum(worker_shared_page.CompletedStatus.done),
    });
}

test "supervisor synthesized usage dedup uses lifecycle identity not external request id" {
    var analytics_dir = try fixture.AnalyticsDir.init(std.testing.allocator);
    defer analytics_dir.deinit(std.testing.allocator);
    var supervisor = try fixture.minimalSupervisorWithAnalytics(std.testing.allocator, analytics_dir.path);
    defer fixture.deinitMinimal(&supervisor);

    const fd = try worker_shared_page.createMemfd("worker-lifecycle-usage");
    defer std.posix.close(fd);
    var view = try worker_shared_page.mapReadWrite(fd);
    defer view.deinit();
    view.initializeCrashDefault(1, 0, 0);

    var worker = fixture.stackWorker(7, 3, demo);
    worker.handle.metrics = view;
    worker.page_mapped = true;

    const synthetic_identity = worker_shared_page.LifecycleIdentity{
        .external_request_id = 500,
        .request_lane_id = 1,
        .request_slot = 2,
        .request_generation = 3,
        .worker_id = 7,
        .worker_generation = 3,
    };
    const reused_external_id_identity = worker_shared_page.LifecycleIdentity{
        .external_request_id = 500,
        .request_lane_id = 1,
        .request_slot = 4,
        .request_generation = 9,
        .worker_id = 7,
        .worker_generation = 3,
    };

    // The server ends the first attempt itself and writes its floor.
    try worker.requests.record(dispatchedAs(synthetic_identity));
    usage_drain.settleRequest(supervisor.usageDrain(), &worker, synthetic_identity.external_request_id, .{ .floor = .{ .status = .deadline } });
    try std.testing.expectEqual(
        usage_log.SynthesizedState.written,
        supervisor.usage.synthesized.get(usage_key.keyFromIdentity(synthetic_identity)).?,
    );

    // A second attempt under the same request id is dispatched, so the
    // request table expects its record; only the synthesis index can tell the
    // two attempts apart.
    try worker.requests.record(dispatchedAs(reused_external_id_identity));
    var metrics = worker_metrics_state.WorkState.init(&view);
    try metrics.appendCompletedRecord(completedFor(reused_external_id_identity));
    try std.testing.expectEqual(@as(usize, 1), usage_drain.drainWorker(supervisor.usageDrain(), &worker));

    // The worker's own record for the synthesized attempt is skipped.
    try metrics.appendCompletedRecord(completedFor(synthetic_identity));
    try std.testing.expectEqual(@as(usize, 0), usage_drain.drainWorker(supervisor.usageDrain(), &worker));

    var lines = try analytics_dir.readUsage(std.testing.allocator, supervisor.analytics);
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, 2), lines.items.len);
    try std.testing.expectEqualStrings("server", lines.items[0].origin);
    try std.testing.expectEqualStrings("deadline", lines.items[0].error_code);
    try std.testing.expectEqualStrings("worker", lines.items[1].origin);
    try std.testing.expectEqual(@as(u64, 500), lines.items[1].request_id);
}

test "a drained record and a lifecycle synthesis write one record per attempt in either order" {
    var analytics_dir = try fixture.AnalyticsDir.init(std.testing.allocator);
    defer analytics_dir.deinit(std.testing.allocator);
    var supervisor = try fixture.minimalSupervisorWithAnalytics(std.testing.allocator, analytics_dir.path);
    defer fixture.deinitMinimal(&supervisor);

    const fd = try worker_shared_page.createMemfd("worker-usage-exactly-once");
    defer std.posix.close(fd);
    var view = try worker_shared_page.mapReadWrite(fd);
    defer view.deinit();
    view.initializeCrashDefault(1, 0, 0);

    var worker = fixture.stackWorker(9, 2, demo);
    worker.handle.metrics = view;
    worker.page_mapped = true;
    var metrics = worker_metrics_state.WorkState.init(&view);

    // Order 1: the worker's own record reaches the ring before the death path
    // synthesizes for the same lifecycle identity. The claim's scan must find
    // it, drain it, and turn the synthesis into a no-op.
    const identity_real_first = worker_shared_page.LifecycleIdentity{
        .external_request_id = 600,
        .request_lane_id = 1,
        .request_slot = 2,
        .request_generation = 5,
        .worker_id = 9,
        .worker_generation = 2,
    };
    try worker.requests.record(dispatchedAs(identity_real_first));
    try metrics.appendCompletedRecord(completedFor(identity_real_first));
    try std.testing.expectEqual(
        usage_drain.SynthesisOutcome.settled,
        try usage_drain.synthesizeFinalAccountingForLifecycle(supervisor.usageDrain(), &worker, identity_real_first.external_request_id, .{ .status = .crash }),
    );
    // No reservation was consumed for this identity.
    try std.testing.expectEqual(
        @as(?usage_log.SynthesizedState, null),
        supervisor.usage.synthesized.get(usage_key.keyFromIdentity(identity_real_first)),
    );
    try std.testing.expectEqual(@as(usize, 0), usage_drain.drainWorker(supervisor.usageDrain(), &worker));

    // Order 2: synthesis reserves and writes first; the worker's own record
    // for the same identity lands in the ring afterwards. The drain must skip
    // it instead of writing a second record.
    const identity_synth_first = worker_shared_page.LifecycleIdentity{
        .external_request_id = 601,
        .request_lane_id = 1,
        .request_slot = 3,
        .request_generation = 8,
        .worker_id = 9,
        .worker_generation = 2,
    };
    try worker.requests.record(dispatchedAs(identity_synth_first));
    try std.testing.expectEqual(
        usage_drain.SynthesisOutcome.settled,
        try usage_drain.synthesizeFinalAccountingForLifecycle(supervisor.usageDrain(), &worker, identity_synth_first.external_request_id, .{ .status = .deadline }),
    );
    try metrics.appendCompletedRecord(completedFor(identity_synth_first));
    try std.testing.expectEqual(@as(usize, 0), usage_drain.drainWorker(supervisor.usageDrain(), &worker));
    // The written key is reclaimed once the worker's record was skipped: the
    // exactly-once account for this identity is closed, not leaked.
    try std.testing.expectEqual(@as(usize, 0), supervisor.usage.synthesized.count());

    var lines = try analytics_dir.readUsage(std.testing.allocator, supervisor.analytics);
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, 2), lines.items.len);
    // The single record for the first request is the worker's own, carrying
    // its measured CPU, not a death floor.
    try std.testing.expectEqual(@as(u64, 600), lines.items[0].request_id);
    try std.testing.expectEqualStrings("worker", lines.items[0].origin);
    try std.testing.expectEqualStrings("done", lines.items[0].error_code);
    try std.testing.expectEqual(@as(u64, 77), lines.items[0].cpu_time_ns);
    try std.testing.expectEqual(@as(u64, 601), lines.items[1].request_id);
    try std.testing.expectEqualStrings("server", lines.items[1].origin);
    try std.testing.expectEqualStrings("deadline", lines.items[1].error_code);
}

test "a full usage stream drops and counts a drain's records while dispatch goes on" {
    // The sink logs the start of the full usage stream once, at `err`.
    @import("root").expect_log_errors = 1;
    var analytics_dir = try fixture.AnalyticsDir.init(std.testing.allocator);
    defer analytics_dir.deinit(std.testing.allocator);
    var supervisor = try fixture.minimalSupervisorWithAnalytics(std.testing.allocator, analytics_dir.path);
    defer fixture.deinitMinimal(&supervisor);
    const published = try fixture.publishInertWorker(&supervisor, .{});
    try fixture.fillUsageStream(std.testing.allocator, supervisor.analytics, 16);

    const fd = try worker_shared_page.createMemfd("worker-usage-stream-full");
    defer std.posix.close(fd);
    var view = try worker_shared_page.mapReadWrite(fd);
    defer view.deinit();
    view.initializeCrashDefault(1, 0, 0);
    var metrics = worker_metrics_state.WorkState.init(&view);

    // A completed request whose worker record waits for the drain.
    var worker = fixture.stackWorker(7, 3, demo);
    worker.handle.metrics = view;
    worker.page_mapped = true;
    try worker.requests.record(fixture.dispatchedRequest(2));
    try metrics.appendCompletedRecord(fixture.completedRecord(&worker, 2));
    try std.testing.expectEqual(request_table.Settled.awaiting_record, worker.requests.settle(2, true));

    // The stream has no room: the record is dropped and counted, the ring
    // moves past it, and the request no longer waits for it.
    try std.testing.expectEqual(@as(usize, 0), usage_drain.drainWorker(supervisor.usageDrain(), &worker));
    try std.testing.expectEqual(@as(u64, 0), pendingRecords(&worker));
    try std.testing.expectEqual(@as(u64, 1), supervisor.analytics.stats(.usage).dropped);
    try std.testing.expectEqual(@as(u64, 1), supervisor.analytics.stats(.usage).refused);
    try std.testing.expect(worker.requests.dispatchedFor(2) == null);
    try std.testing.expect(supervisor.analytics.full(.usage));

    // Dispatch reads nothing of the usage stream: the pool still hands out
    // its idle worker.
    const demo_pool = supervisor.poolFor(demo);
    const served = try expectAcquired(demo_pool, 0, 1);
    try std.testing.expect(served.worker == published);
    try std.testing.expect((try demo_pool.release(served.worker, served.slot, 1)) == .idle);

    // Written out, the stream has room again and is no longer full.
    supervisor.analytics.flush(0);
    try std.testing.expect(!supervisor.analytics.full(.usage));
}

/// Writes a record of request `index + 1` into every entry of `view`'s usage
/// ring, as a worker would, and leaves the head where it is.
fn fillUsageRing(view: *worker_shared_page.WorkerWriterView) void {
    for (view.completed_records, 0..) |*record, index| {
        record.* = std.mem.zeroInit(worker_shared_page.CompletedRecord, .{
            .request_id = @as(u64, @intCast(index + 1)),
            .started_mono_ns = 10,
            .finished_mono_ns = 20,
            .cpu_time_ns = 1,
            .io_time_ns = 9,
            .client_served_bytes = 1,
            .status = @intFromEnum(worker_shared_page.CompletedStatus.done),
        });
    }
}

test "a usage drain reads a full ring once and refuses the records of requests it never dispatched" {
    var analytics_dir = try fixture.AnalyticsDir.init(std.testing.allocator);
    defer analytics_dir.deinit(std.testing.allocator);
    var supervisor = try fixture.minimalSupervisorWithAnalytics(std.testing.allocator, analytics_dir.path);
    defer fixture.deinitMinimal(&supervisor);

    const fd = try worker_shared_page.createMemfd("worker-usage-full-ring");
    defer std.posix.close(fd);
    var view = try worker_shared_page.mapReadWrite(fd);
    defer view.deinit();
    view.initializeCrashDefault(1, 0, 0);
    fillUsageRing(&view);
    @atomicStore(u64, &view.header.records_head, worker_shared_page.RECORD_RING_COUNT, .release);

    var worker = fixture.stackWorker(1, 1, demo);
    worker.handle.metrics = view;
    worker.page_mapped = true;

    // No request was dispatched to this worker, so every record is refused,
    // and the ring moves past all of them.
    try std.testing.expectEqual(
        @as(usize, 0),
        usage_drain.drainWorker(supervisor.usageDrain(), &worker),
    );
    try std.testing.expect(!worker.usage_ring_failed);
    try std.testing.expectEqual(
        @as(u64, worker_shared_page.RECORD_RING_COUNT),
        worker.handle.metrics.?.host_cursors.records.tail,
    );
    try std.testing.expectEqual(@as(u64, 0), pendingRecords(&worker));
    try std.testing.expectEqual(@as(u64, worker_shared_page.RECORD_RING_COUNT), rejectedRecords(&supervisor));
    var lines = try analytics_dir.readUsage(std.testing.allocator, supervisor.analytics);
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, 0), lines.items.len);
}

test "a usage drain fails a ring whose head stands more than a ring past its tail, and no drain reads it again" {
    var analytics_dir = try fixture.AnalyticsDir.init(std.testing.allocator);
    defer analytics_dir.deinit(std.testing.allocator);
    var supervisor = try fixture.minimalSupervisorWithAnalytics(std.testing.allocator, analytics_dir.path);
    defer fixture.deinitMinimal(&supervisor);

    const fd = try worker_shared_page.createMemfd("worker-usage-hostile-head");
    defer std.posix.close(fd);
    var view = try worker_shared_page.mapReadWrite(fd);
    defer view.deinit();
    view.initializeCrashDefault(1, 0, 0);
    fillUsageRing(&view);

    var worker = fixture.stackWorker(1, 1, demo);
    worker.handle.metrics = view;
    worker.page_mapped = true;
    // The ring's first record is request 1's, which the table expects, so a
    // drain that read the ring would write it.
    try worker.requests.record(fixture.dispatchedRequest(1));

    // The worker claims four rings' worth of records.
    @atomicStore(u64, &view.header.records_head, worker_shared_page.RECORD_RING_COUNT * 4, .release);
    try std.testing.expectEqual(@as(usize, 0), usage_drain.drainWorker(supervisor.usageDrain(), &worker));
    try std.testing.expect(worker.usage_ring_failed);
    try std.testing.expectEqual(@as(u64, 0), worker.handle.metrics.?.host_cursors.records.tail);
    try std.testing.expectEqual(@as(u64, 0), @atomicLoad(u64, &view.header.records_tail, .acquire));

    // A head moved back to one an append could produce changes nothing.
    @atomicStore(u64, &view.header.records_head, 1, .release);
    try std.testing.expectEqual(@as(usize, 0), usage_drain.drainWorker(supervisor.usageDrain(), &worker));
    try std.testing.expectEqual(@as(u64, 0), worker.handle.metrics.?.host_cursors.records.tail);
    try std.testing.expectEqual(@as(u64, 0), rejectedRecords(&supervisor));
    var lines = try analytics_dir.readUsage(std.testing.allocator, supervisor.analytics);
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, 0), lines.items.len);
}

/// Whether `lines` holds a record of `request_id`.
fn holdsRequest(lines: []const fixture.UsageLine, request_id: u64) bool {
    for (lines) |line| {
        if (line.request_id == request_id) return true;
    }
    return false;
}

test "a drain of every worker writes a full usage stream out and offers the batch again, so a healthy file loses nothing" {
    var analytics_dir = try fixture.AnalyticsDir.init(std.testing.allocator);
    defer analytics_dir.deinit(std.testing.allocator);
    var supervisor = try fixture.minimalSupervisorWithAnalytics(std.testing.allocator, analytics_dir.path);
    defer fixture.deinitMinimal(&supervisor);

    const first = try fixture.publishInertWorker(&supervisor, .{ .definition_index = demo });
    const second = try fixture.publishInertWorker(&supervisor, .{ .definition_index = beta });
    try fixture.publishCompletedRecord(first, 41);
    try fixture.publishCompletedRecord(second, 42);
    try fixture.fillUsageStream(std.testing.allocator, supervisor.analytics, 16);

    // The first worker's record finds the stream full and stays in its ring
    // while the drain writes the stream out; offered again, it lands, and so
    // does the second worker's. The refusal lost nothing, so the stream was
    // never full and logged nothing.
    supervisor.drainAllWorkerUsage();
    try std.testing.expectEqual(@as(u64, 0), pendingRecords(first));
    try std.testing.expectEqual(@as(u64, 0), pendingRecords(second));
    try std.testing.expect(first.requests.dispatchedFor(41) == null);
    const stats = supervisor.analytics.stats(.usage);
    try std.testing.expectEqual(@as(u64, 0), stats.dropped);
    try std.testing.expectEqual(@as(u64, 0), stats.refused);
    try std.testing.expect(!supervisor.analytics.full(.usage));

    var lines = try analytics_dir.readUsage(std.testing.allocator, supervisor.analytics);
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, 2), lines.items.len);
    try std.testing.expect(holdsRequest(lines.items, 41));
    try std.testing.expect(holdsRequest(lines.items, 42));
}

test "a drain of every worker drops what a write-out leaves no room for, and every worker's ring still empties" {
    // The sink logs the start of the full usage stream once, at `err`.
    @import("root").expect_log_errors = 1;
    var analytics_dir = try fixture.AnalyticsDir.init(std.testing.allocator);
    defer analytics_dir.deinit(std.testing.allocator);
    var supervisor = try fixture.minimalSupervisorWithAnalytics(std.testing.allocator, analytics_dir.path);
    defer fixture.deinitMinimal(&supervisor);

    const first = try fixture.publishInertWorker(&supervisor, .{ .definition_index = demo });
    const second = try fixture.publishInertWorker(&supervisor, .{ .definition_index = beta });
    try fixture.publishCompletedRecord(first, 51);
    try fixture.publishCompletedRecord(second, 52);
    try fixture.fillUsageStream(std.testing.allocator, supervisor.analytics, 16);

    // The file takes no writes, so the write-out frees nothing: the first
    // worker's record is dropped after it, and the second worker's is
    // dropped without another write-out. Both requests stop waiting.
    {
        const refused = try fixture.FileWritesRefused.begin();
        defer refused.end();
        supervisor.drainAllWorkerUsage();
    }
    try std.testing.expectEqual(@as(u64, 0), pendingRecords(first));
    try std.testing.expectEqual(@as(u64, 0), pendingRecords(second));
    try std.testing.expect(first.requests.dispatchedFor(51) == null);
    try std.testing.expect(second.requests.dispatchedFor(52) == null);
    const stats = supervisor.analytics.stats(.usage);
    try std.testing.expectEqual(@as(u64, 2), stats.dropped);
    try std.testing.expectEqual(@as(u64, 1), stats.write_errors);
    try std.testing.expect(supervisor.analytics.full(.usage));

    var lines = try analytics_dir.readUsage(std.testing.allocator, supervisor.analytics);
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, 0), lines.items.len);
}

/// A shared page and the stack worker record whose ring it is, for tests that
/// drain a worker without a destroyable handle. Initialized in place because
/// the record holds a copy of the page's view.
const DrainableWorker = struct {
    fd: std.posix.fd_t,
    view: worker_shared_page.WorkerWriterView,
    record: WorkerRecord,

    fn init(self: *DrainableWorker, name: []const u8, id: u64, generation: u64) !void {
        self.fd = try worker_shared_page.createMemfd(name);
        errdefer std.posix.close(self.fd);
        self.view = try worker_shared_page.mapReadWrite(self.fd);
        self.view.initializeCrashDefault(1, 0, 0);
        self.record = fixture.stackWorker(id, generation, demo);
        self.record.handle.metrics = self.view;
        self.record.page_mapped = true;
    }

    fn deinit(self: *DrainableWorker) void {
        self.view.deinit();
        std.posix.close(self.fd);
    }

    /// A completed request: entered in the worker's request table as a
    /// dispatch does, unless it already is, and settled to wait for its
    /// record, which is appended to the ring as the worker does before it
    /// publishes the completion.
    fn publish(self: *DrainableWorker, request_id: u64) !void {
        if (self.record.requests.dispatchedFor(request_id) == null) {
            try self.record.requests.record(fixture.dispatchedRequest(request_id));
            if (self.record.requests.settle(request_id, true) != .awaiting_record)
                return error.RequestTableFull;
        }
        var metrics = worker_metrics_state.WorkState.init(&self.view);
        try metrics.appendCompletedRecord(fixture.completedRecord(&self.record, request_id));
    }

    fn pending(self: *const DrainableWorker) u64 {
        return pendingRecords(&self.record);
    }
};

test "usage records stay in usage.jsonl across a restart, and the next supervisor appends after them" {
    var analytics_dir = try fixture.AnalyticsDir.init(std.testing.allocator);
    defer analytics_dir.deinit(std.testing.allocator);

    var first_worker: DrainableWorker = undefined;
    try first_worker.init("worker-usage-before-restart", 7, 3);
    defer first_worker.deinit();
    {
        var first = try fixture.minimalSupervisorWithAnalytics(std.testing.allocator, analytics_dir.path);
        // Closing the sink writes and syncs what the drain appended.
        defer fixture.deinitMinimal(&first);
        try first_worker.publish(1);
        _ = usage_drain.drainWorker(first.usageDrain(), &first_worker.record);
    }

    // The next boot opens the same directory: nothing is reloaded, and
    // nothing already written is lost or written again.
    var second = try fixture.minimalSupervisorWithAnalytics(std.testing.allocator, analytics_dir.path);
    defer fixture.deinitMinimal(&second);
    var second_worker: DrainableWorker = undefined;
    try second_worker.init("worker-usage-after-restart", 8, 4);
    defer second_worker.deinit();
    try second_worker.publish(2);
    _ = usage_drain.drainWorker(second.usageDrain(), &second_worker.record);

    var lines = try analytics_dir.readUsage(std.testing.allocator, second.analytics);
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, 2), lines.items.len);
    try std.testing.expectEqual(@as(u64, 7), lines.items[0].worker_id);
    try std.testing.expectEqual(@as(u64, 1), lines.items[0].request_id);
    try std.testing.expectEqual(@as(u64, 8), lines.items[1].worker_id);
    try std.testing.expectEqual(@as(u64, 2), lines.items[1].request_id);
}

test "a batch the usage stream cannot take is held whole for a thread that writes out, and dropped whole and counted otherwise" {
    // The sink logs the start of the full usage stream once, at `err`.
    @import("root").expect_log_errors = 1;
    var analytics_dir = try fixture.AnalyticsDir.init(std.testing.allocator);
    defer analytics_dir.deinit(std.testing.allocator);
    var supervisor = try fixture.minimalSupervisorWithAnalytics(std.testing.allocator, analytics_dir.path);
    defer fixture.deinitMinimal(&supervisor);

    var worker: DrainableWorker = undefined;
    try worker.init("worker-usage-batch-refused", 7, 3);
    defer worker.deinit();
    const clock = analytics.Clock.capture();
    const identity = analytics.Identity.ofWorker(&worker.record);
    const records = [_]analytics.usage.UsageRecord{
        analytics.usage.fromCompleted(identity, .worker, fixture.completedRecord(&worker.record, 1), clock),
        analytics.usage.fromCompleted(identity, .worker, fixture.completedRecord(&worker.record, 2), clock),
    };

    // Room above the synthesis reserve for one of these records, a little
    // over 300 bytes each, but not for both.
    try fixture.fillUsageStream(std.testing.allocator, supervisor.analytics, usage_log.synthesis_reserve_bytes + 400);
    // Held, the batch costs nothing: nothing is counted and the stream is not
    // full.
    try std.testing.expectEqual(usage_log.AppendOutcome.held, supervisor.usage.append(&records, .hold));
    try std.testing.expectEqual(@as(u64, 0), supervisor.analytics.stats(.usage).dropped);
    try std.testing.expect(!supervisor.analytics.full(.usage));
    try std.testing.expectEqual(usage_log.AppendOutcome.dropped, supervisor.usage.append(&records, .drop));
    // The filler lines are the stream's only appends, and both records count
    // as lost.
    try std.testing.expectEqual(@as(u64, 2), supervisor.analytics.stats(.usage).appended);
    try std.testing.expectEqual(@as(u64, 2), supervisor.analytics.stats(.usage).dropped);
    try std.testing.expect(supervisor.analytics.full(.usage));

    var lines = try analytics_dir.readUsage(std.testing.allocator, supervisor.analytics);
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, 0), lines.items.len);
}

test "a drained batch may not take the synthesis reserve, and a floor may spend it" {
    // The dropped batch begins the full usage stream, which the sink logs
    // once, at `err`; the floor that lands in the reserve does not end it.
    @import("root").expect_log_errors = 1;
    var analytics_dir = try fixture.AnalyticsDir.init(std.testing.allocator);
    defer analytics_dir.deinit(std.testing.allocator);
    var supervisor = try fixture.minimalSupervisorWithAnalytics(std.testing.allocator, analytics_dir.path);
    defer fixture.deinitMinimal(&supervisor);
    try fixture.fillUsageStream(std.testing.allocator, supervisor.analytics, usage_log.synthesis_reserve_bytes);

    var worker: DrainableWorker = undefined;
    try worker.init("worker-usage-synthesis-reserve", 7, 3);
    defer worker.deinit();
    try worker.publish(1);

    // When room is short, floors are the records that still land, so the
    // drained record may not take the reserve: it is dropped and counted.
    try std.testing.expectEqual(@as(usize, 0), usage_drain.drainWorker(supervisor.usageDrain(), &worker.record));
    try std.testing.expectEqual(@as(u64, 0), worker.pending());
    try std.testing.expectEqual(@as(u64, 1), supervisor.analytics.stats(.usage).dropped);

    // A floor may.
    const identity = worker_shared_page.LifecycleIdentity{
        .external_request_id = 500,
        .request_lane_id = 1,
        .request_slot = 2,
        .request_generation = 3,
        .worker_id = 7,
        .worker_generation = 3,
    };
    try worker.record.requests.record(dispatchedAs(identity));
    try std.testing.expectEqual(
        usage_drain.SynthesisOutcome.settled,
        try usage_drain.synthesizeFinalAccountingForLifecycle(supervisor.usageDrain(), &worker.record, identity.external_request_id, .{ .status = .deadline }),
    );
    try std.testing.expectEqual(@as(u64, 1), supervisor.analytics.stats(.usage).dropped);
    try std.testing.expect(supervisor.analytics.full(.usage));

    var lines = try analytics_dir.readUsage(std.testing.allocator, supervisor.analytics);
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqualStrings("server", lines.items[0].origin);
    try std.testing.expectEqual(@as(u64, 500), lines.items[0].request_id);
}

test "a floor that finds the synthesis reserve spent is counted as lost and its caller carries on" {
    // The sink logs the start of the full usage stream once, at `err`.
    @import("root").expect_log_errors = 1;
    var analytics_dir = try fixture.AnalyticsDir.init(std.testing.allocator);
    defer analytics_dir.deinit(std.testing.allocator);
    var supervisor = try fixture.minimalSupervisorWithAnalytics(std.testing.allocator, analytics_dir.path);
    defer fixture.deinitMinimal(&supervisor);
    try fixture.fillUsageStream(std.testing.allocator, supervisor.analytics, 16);

    // A worker whose page is already gone: no record of it can be found.
    var worker = fixture.stackWorker(7, 3, demo);
    worker.handle.metrics = null;
    const identity = worker_shared_page.LifecycleIdentity{
        .external_request_id = 500,
        .request_lane_id = 1,
        .request_slot = 2,
        .request_generation = 3,
        .worker_id = 7,
        .worker_generation = 3,
    };
    try worker.requests.record(dispatchedAs(identity));

    // Synthesis runs on the lane that ends the request, and a full usage
    // stream must not end the lane with it.
    try std.testing.expectEqual(
        usage_drain.SynthesisOutcome.awaits_worker_record,
        try usage_drain.synthesizeFinalAccountingForLifecycle(supervisor.usageDrain(), &worker, identity.external_request_id, .{ .status = .deadline }),
    );
    try std.testing.expectEqual(@as(u64, 1), supervisor.analytics.stats(.usage).dropped);
    // No floor exists, so the reservation is rolled back and the request's
    // entry keeps expecting the worker's record: one that still arrives is
    // written.
    try std.testing.expect(!supervisor.usage.synthesized.contains(usage_key.keyFromIdentity(identity)));
    try std.testing.expect(worker.requests.expected(identity.external_request_id) != null);
}

test "a request whose record a drain already wrote gets no floor when the server ends it" {
    var analytics_dir = try fixture.AnalyticsDir.init(std.testing.allocator);
    defer analytics_dir.deinit(std.testing.allocator);
    var supervisor = try fixture.minimalSupervisorWithAnalytics(std.testing.allocator, analytics_dir.path);
    defer fixture.deinitMinimal(&supervisor);

    var worker: DrainableWorker = undefined;
    try worker.init("worker-usage-warm-drain-first", 9, 2);
    defer worker.deinit();

    // What a dispatch does once its slot is taken: record the request in the
    // worker's table before it is sent.
    const identity = worker_shared_page.LifecycleIdentity{
        .external_request_id = 600,
        .request_lane_id = 1,
        .request_slot = 2,
        .request_generation = 5,
        .worker_id = 9,
        .worker_generation = 2,
    };
    try worker.record.requests.record(dispatchedAs(identity));

    // The worker finishes and the periodic drain writes its record and empties
    // the ring before the lane ends the request as an internal error.
    try worker.publish(identity.external_request_id);
    try std.testing.expectEqual(@as(usize, 1), usage_drain.drainWorker(supervisor.usageDrain(), &worker.record));
    supervisor.settleRequest(&worker.record, identity.external_request_id, .{ .floor = .{ .status = .internal_error } });

    // The entry went with the settle.
    try std.testing.expect(worker.record.requests.dispatchedFor(identity.external_request_id) == null);

    var lines = try analytics_dir.readUsage(std.testing.allocator, supervisor.analytics);
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqualStrings("worker", lines.items[0].origin);
    try std.testing.expectEqual(identity.external_request_id, lines.items[0].request_id);
}

test "a worker that answered 504 at one request's deadline stays in service and keeps its other request (#44)" {
    var analytics_dir = try fixture.AnalyticsDir.init(std.testing.allocator);
    defer analytics_dir.deinit(std.testing.allocator);
    var supervisor = try fixture.minimalSupervisorWithAnalytics(std.testing.allocator, analytics_dir.path);
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
    // worker answered 504 itself, appended its own usage record and published
    // the completion. The lane settles it as completed and gives its slot
    // back.
    var deadline_record = fixture.completedRecord(worker, 1);
    deadline_record.status = @intFromEnum(worker_shared_page.CompletedStatus.deadline);
    var state = worker_metrics_state.WorkState.init(&worker.handle.metrics.?);
    try state.appendCompletedRecord(deadline_record);
    supervisor.settleRequest(worker, 1, .completed);
    try std.testing.expect((try demo_pool.release(worker, timed_out.slot, 10)) == .idle);

    // Nothing took the worker out of service or queued its retirement, and it
    // still holds the other request's slot.
    const view = demo_pool.inspect(worker) orelse return error.TestExpectedWorker;
    try std.testing.expectEqual(pool_mod.EntryState.live, view.state);
    try std.testing.expectEqual(@as(u8, 1), view.slots_held);
    const counters = demo_pool.snapshot().counters;
    try std.testing.expectEqual(@as(u64, 0), counters.deaths);
    try std.testing.expectEqual(@as(u64, 0), counters.retirements);

    // The usage record of the timed-out request is the worker's own.
    try std.testing.expectEqual(@as(usize, 1), usage_drain.drainWorker(supervisor.usageDrain(), worker));
    var lines = try analytics_dir.readUsage(std.testing.allocator, supervisor.analytics);
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqual(@as(u64, 1), lines.items[0].request_id);
    try std.testing.expectEqualStrings("worker", lines.items[0].origin);
    try std.testing.expectEqualStrings("deadline", lines.items[0].error_code);

    // The other request completes on the same worker.
    try state.appendCompletedRecord(fixture.completedRecord(worker, 2));
    supervisor.settleRequest(worker, 2, .completed);
    try std.testing.expect((try demo_pool.release(worker, other.slot, 20)) == .idle);
    const after = demo_pool.inspect(worker) orelse return error.TestExpectedWorker;
    try std.testing.expectEqual(pool_mod.EntryState.live, after.state);
    try std.testing.expectEqual(@as(u8, 0), after.slots_held);
}

/// The request table entry of `request_id` dispatched at `started_mono_ns`.
fn dispatchedAt(request_id: u64, started_mono_ns: u64) request_table.Dispatched {
    var dispatched = fixture.dispatchedRequest(request_id);
    dispatched.started_mono_ns = started_mono_ns;
    return dispatched;
}

test "a worker's request table is bounded and never allocates" {
    var table = request_table.RequestTable{};
    var request_id: u64 = 1;
    while (request_id <= request_table.entries_max) : (request_id += 1)
        try table.record(dispatchedAt(request_id, request_id * 10));
    try std.testing.expectError(error.RequestTableFull, table.record(dispatchedAt(request_id, 0)));

    // Marks land only on requests that hold an entry; a worker-written 0 or
    // an unknown id marks nothing.
    table.markUsageRecorded(&.{ 0, 1, 999 });
    try std.testing.expect(table.usageRecorded(1));
    try std.testing.expect(!table.usageRecorded(2));
    try std.testing.expect(!table.usageRecorded(999));
    try std.testing.expectEqual(@as(u64, 20), table.dispatchedFor(2).?.started_mono_ns);

    // A removed entry frees its place, and its mark goes with it.
    table.remove(1);
    try std.testing.expect(!table.usageRecorded(1));
    try table.record(dispatchedAt(request_id, 0));
    try std.testing.expect(!table.usageRecorded(request_id));
}

test "usage records reach the file in the order the drains appended them" {
    var analytics_dir = try fixture.AnalyticsDir.init(std.testing.allocator);
    defer analytics_dir.deinit(std.testing.allocator);
    var supervisor = try fixture.minimalSupervisorWithAnalytics(std.testing.allocator, analytics_dir.path);
    defer fixture.deinitMinimal(&supervisor);

    var first: DrainableWorker = undefined;
    try first.init("worker-usage-order-first", 7, 3);
    defer first.deinit();
    var second: DrainableWorker = undefined;
    try second.init("worker-usage-order-second", 8, 4);
    defer second.deinit();
    try first.publish(1);
    try second.publish(2);
    try first.publish(3);

    _ = usage_drain.drainWorker(supervisor.usageDrain(), &first.record);
    _ = usage_drain.drainWorker(supervisor.usageDrain(), &second.record);

    var lines = try analytics_dir.readUsage(std.testing.allocator, supervisor.analytics);
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, 3), lines.items.len);
    try std.testing.expectEqual(@as(u64, 1), lines.items[0].request_id);
    try std.testing.expectEqual(@as(u64, 3), lines.items[1].request_id);
    try std.testing.expectEqual(@as(u64, 2), lines.items[2].request_id);
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

test "a session its gateway removed is taken off the live worker that holds it, which the next pass then reaches" {
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
    try std.testing.expect(!supervisor.dropEgressSession(current - 1, 8));
    try std.testing.expect(!supervisor.dropEgressSession(current, 9));
    try std.testing.expect(supervisor.nextStaleEgressWorker(current) == null);

    try std.testing.expect(supervisor.dropEgressSession(current, 8));
    try expectWorkerEgress(&supervisor, lost, .{ .generation = 0, .session_id = 0 });
    try expectWorkerEgress(&supervisor, kept, .{ .generation = current, .session_id = 7 });
    // The worker without a session is stale under its own gateway, and only it.
    var target = supervisor.nextStaleEgressWorker(current) orelse return error.TestExpectedStaleWorker;
    defer target.deinit();
    try std.testing.expectEqual(lost, target.record);
    // A second report of the session finds no worker on it.
    try std.testing.expect(!supervisor.dropEgressSession(current, 8));

    // A worker out of service keeps whatever its record names.
    var kept_target = reattachTargetOf(kept);
    _ = supervisor.retireForEgress(&kept_target) orelse return error.TestExpectedRetirement;
    try std.testing.expect(!supervisor.dropEgressSession(current, 7));
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

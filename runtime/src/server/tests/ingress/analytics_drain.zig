//! How ingress produces and drains its records: the status and the worker
//! fault an access record carries for each way a request ends, and the usage
//! settle each way implies (`endingFor` and `settleOutcomeFor` in
//! `runner/request_finish.zig`), and the metrics tick of
//! `ingress/analytics_drain.zig`, which moves every lane's access ring into
//! the sink and flushes it, moves the worker whose log ring it drains first
//! along the supervisor's records, writing each line under the worker's
//! definition name, and takes out of service, once, a worker whose usage
//! ring head moved back behind the server's tail. Lane
//! `server-ingress-test`; draining one log ring is covered in
//! `tests/analytics/logs.zig`, the encoders and the sink in the rest of
//! `tests/analytics/`, and the usage drain's own handling of a failed ring
//! in `tests/supervisor/usage.zig`.

const std = @import("std");
const analytics = @import("collo_server_analytics");
const page = @import("collo_worker_state").page;
const server_main = @import("collo_server_main");
const server_config = @import("collo_server_config");
const supervision = @import("collo_server_supervisor");
const fixture = @import("supervisor_fixture");

const WorkerRecord = supervision.worker_table.Record;
const WorkerPool = supervision.WorkerPool;
const WorkerKey = server_main.lifecycle.WorkerKey;
const fault = server_main.ingress.fault;
const analytics_drain = server_main.ingress.analytics_drain;
const request_finish = server_main.ingress.runner.request_finish;
const server_responses = server_main.ingress.server_responses;
const access = analytics.access;

const file_bytes_max = 16 * 1024 * 1024;

test "an ended request's access record carries the status of the answer its client got" {
    var completion = std.mem.zeroes(page.WorkerCompletionRecord);
    completion.http_status = 201;
    // The worker's own status, whether or not its response went out; the
    // lane writes no response of its own.
    const answered = request_finish.endingFor(.{ .worker_completion = completion });
    try std.testing.expectEqual(@as(u16, 201), answered.status);
    try std.testing.expectEqual(@as(?server_responses.Id, null), answered.response);

    // A status the lane synthesizes is the status of the response it writes.
    const synthesized = [_]struct { outcome: request_finish.RequestOutcome, status: u16 }{
        .{ .outcome = .waiter_expired, .status = 503 },
        .{ .outcome = .unserved, .status = 503 },
        .{ .outcome = .deadline_expired, .status = 504 },
        .{ .outcome = .send_expired, .status = 504 },
        .{ .outcome = .{ .worker_died = .{ .status = .crash, .reason = .exited } }, .status = 502 },
    };
    for (synthesized) |case| {
        const ending = request_finish.endingFor(case.outcome);
        try std.testing.expectEqual(case.status, ending.status);
        const response = ending.response orelse return error.MissingLaneResponse;
        try std.testing.expectEqual(case.status, server_responses.get(response).status);
    }

    // With no response of the lane's own: a shutdown records the 503 of a
    // restarting service, and a client that left first the 499 a worker
    // reports for it.
    try std.testing.expectEqual(@as(u16, 503), request_finish.endingFor(.shutdown).status);
    const client_left = request_finish.endingFor(.stream_gone);
    try std.testing.expectEqual(request_finish.client_closed_status, client_left.status);

    // A worker fault rides the ending of the requests it ended, and only
    // theirs.
    const died: request_finish.RequestOutcome = .{ .worker_died = .{ .status = .crash, .reason = .exited } };
    try std.testing.expectEqual(@as(?fault.WorkerFaultReason, .exited), request_finish.endingFor(died).worker_fault);
    try std.testing.expectEqual(
        @as(?fault.WorkerFaultReason, .deadline_grace_expired),
        request_finish.endingFor(.deadline_expired).worker_fault,
    );
    try std.testing.expectEqual(@as(?fault.WorkerFaultReason, null), client_left.worker_fault);
    try std.testing.expectEqual(@as(?fault.WorkerFaultReason, null), answered.worker_fault);
    // A begin that never left met backpressure, which is no fault.
    try std.testing.expectEqual(@as(?fault.WorkerFaultReason, null), request_finish.endingFor(.send_expired).worker_fault);
}

test "a request the server ended settles a floor with its error code and the label of the worker fault that ended it" {
    // The worker's completion means it wrote its own record, and a request
    // whose begin never reached the worker leaves no usage at all.
    const completion = std.mem.zeroes(page.WorkerCompletionRecord);
    try std.testing.expect(request_finish.settleOutcomeFor(true, .{ .worker_completion = completion }) == .completed);
    const died: request_finish.RequestOutcome = .{ .worker_died = .{ .status = .crash, .reason = .packet_short } };
    try std.testing.expect(request_finish.settleOutcomeFor(false, died) == .abandoned);
    try std.testing.expect(request_finish.settleOutcomeFor(false, .send_expired) == .abandoned);

    const floors = [_]struct {
        outcome: request_finish.RequestOutcome,
        status: page.CompletedStatus,
        worker_fault: []const u8,
    }{
        .{ .outcome = died, .status = .crash, .worker_fault = "packet_short" },
        .{ .outcome = .deadline_expired, .status = .deadline, .worker_fault = "deadline_grace_expired" },
        .{ .outcome = .stream_gone, .status = .client_closed, .worker_fault = "" },
        .{ .outcome = .shutdown, .status = .internal_error, .worker_fault = "" },
    };
    for (floors) |case| {
        switch (request_finish.settleOutcomeFor(true, case.outcome)) {
            .floor => |floor| {
                try std.testing.expectEqual(case.status, floor.status);
                try std.testing.expectEqualStrings(case.worker_fault, floor.worker_fault);
            },
            .completed, .abandoned => return error.ExpectedFloor,
        }
    }
}

const FakeLane = struct {
    access_ring: access.AccessRing = .{},
};

/// The supervisor as the drain reads it in the tests whose rings never fail:
/// the worker records, and a pool that takes no worker out of service.
const FakeSupervisor = struct {
    records: []WorkerRecord,
    pool: FakePool = .{},

    pub fn poolFor(self: *FakeSupervisor, _: server_config.DefinitionIndex) *FakePool {
        return &self.pool;
    }
};

const FakePool = struct {
    pub fn markDead(_: *FakePool, _: *WorkerRecord, _: WorkerKey) ?WorkerPool.Death {
        return null;
    }
};

const FakeService = struct {
    supervisor: FakeSupervisor,
    analytics: *analytics.Sink,
    analytics_drain: analytics_drain.State = .{},
    lanes: []FakeLane,
    deaths_announced: usize = 0,

    pub fn announceWorkerDeath(
        self: *FakeService,
        _: *WorkerRecord,
        _: WorkerKey,
        _: WorkerPool.Death,
        _: fault.WorkerFaultReason,
    ) void {
        self.deaths_announced += 1;
    }
};

fn makeRecord(request_id: u64) access.AccessRecord {
    return access.recordFromFacts(access.stamp(.{
        .request_id = request_id,
        .worker = "demo",
        .method = "GET",
        .path = "/",
        .user_agent = "",
        .client_ip = "127.0.0.1",
        .started_mono_ns = 1_000_000_000,
    }), 200, .worker, 1_200_000_000);
}

test "a drain tick moves every lane's access records into access.jsonl" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const console = try tmp.dir.createFile("console.txt", .{ .read = true });
    defer console.close();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp.dir.realpath(".", &path_buffer);
    var sink: analytics.Sink = undefined;
    try sink.open(std.testing.allocator, .{ .directory = path, .console_fd = console.handle });
    defer sink.close();

    const lanes = try std.testing.allocator.alloc(FakeLane, 2);
    defer std.testing.allocator.free(lanes);
    for (lanes) |*lane|
        lane.* = .{};
    try std.testing.expect(lanes[0].access_ring.push(makeRecord(1)));
    try std.testing.expect(lanes[1].access_ring.push(makeRecord(2)));
    try std.testing.expect(lanes[1].access_ring.push(makeRecord(3)));

    var no_records = [_]WorkerRecord{};
    var service = FakeService{ .supervisor = .{ .records = &no_records }, .analytics = &sink, .lanes = lanes };
    const clock = analytics.Clock{ .wall_now_ms = 1_700_000_000_000, .mono_now_ns = 2_000_000_000 };
    analytics_drain.drainAt(&service, clock, 0, .announce);

    // The tick flushed, so the records are already in the file.
    const written = try tmp.dir.readFileAlloc(std.testing.allocator, "access.jsonl", file_bytes_max);
    defer std.testing.allocator.free(written);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, written, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, written, "\"request_id\":1,") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"request_id\":3,") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"client_ip\":\"127.0.0.1\"") != null);
}

/// A memfd page mapped as a worker maps it, written into the worker record
/// whose log ring it holds. The record's `handle.metrics` is a copy of `view`
/// that borrows its mapping, so only `deinit` unmaps it.
const LoggingWorker = struct {
    fd: std.posix.fd_t,
    view: page.WorkerWriterView,

    fn init(
        self: *LoggingWorker,
        record: *WorkerRecord,
        memfd_name: []const u8,
        definition: server_config.DefinitionIndex,
        worker_name: []const u8,
        id: u64,
    ) !void {
        self.fd = try page.createMemfd(memfd_name);
        errdefer std.posix.close(self.fd);
        self.view = try page.mapReadWrite(self.fd);
        self.view.initializeCrashDefault(1, 4096, 1);
        record.* = .{
            .id = id,
            .generation = 1,
            .definition_index = definition,
            .name = worker_name,
            .handle = undefined,
            .page_mapped = true,
        };
        record.handle.metrics = self.view;
    }

    fn deinit(self: *LoggingWorker) void {
        self.view.deinit();
        std.posix.close(self.fd);
    }
};

test "the worker a tick drains first moves along the records every tick, under its definition name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const console = try tmp.dir.createFile("console.txt", .{ .read = true });
    defer console.close();
    var sink: analytics.Sink = undefined;
    try sink.open(std.testing.allocator, .{ .directory = null, .console_fd = console.handle });
    defer sink.close();

    var records: [2]WorkerRecord = undefined;
    var first: LoggingWorker = undefined;
    try first.init(&records[0], "analytics-drain-rotation-first", 0, "first", 1);
    defer first.deinit();
    var second: LoggingWorker = undefined;
    try second.init(&records[1], "analytics-drain-rotation-second", 1, "second", 2);
    defer second.deinit();

    var no_lanes = [_]FakeLane{};
    var service = FakeService{ .supervisor = .{ .records = &records }, .analytics = &sink, .lanes = &no_lanes };
    const clock = analytics.Clock{ .wall_now_ms = 1_700_000_000_000, .mono_now_ns = 2_000_000_000 };
    // A worker that fills the console buffer alone crowds out whoever drains
    // after it, so the order must not always favor the same worker.
    for (0..2) |tick| {
        first.view.publishLogLine(.info, 0, 1, 1_000_000_000, if (tick == 0) "a" else "c");
        second.view.publishLogLine(.info, 0, 1, 1_000_000_000, if (tick == 0) "b" else "d");
        analytics_drain.drainAt(&service, clock, 0, .announce);
    }
    sink.flushConsole();
    try std.testing.expectEqual(@as(usize, 0), service.deaths_announced);

    const written = try tmp.dir.readFileAlloc(std.testing.allocator, "console.txt", file_bytes_max);
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings(
        "[first] a\n" ++
            "[second] b\n" ++
            "[second] d\n" ++
            "[first] c\n",
        written,
    );
}

/// The service as the metrics thread reads it, over a fixture supervisor
/// whose pools take a worker out of service for real. It keeps each death it
/// is asked to announce instead of posting it to lanes.
const SupervisedService = struct {
    supervisor: *supervision.Supervisor,
    analytics: *analytics.Sink,
    analytics_drain: analytics_drain.State = .{},
    lanes: []FakeLane,
    announcements: usize = 0,
    announced: ?Announced = null,

    const Announced = struct {
        worker_key: WorkerKey,
        reason: fault.WorkerFaultReason,
        retire: bool,
    };

    pub fn announceWorkerDeath(
        self: *SupervisedService,
        _: *WorkerRecord,
        worker_key: WorkerKey,
        death: WorkerPool.Death,
        reason: fault.WorkerFaultReason,
    ) void {
        self.announcements += 1;
        self.announced = .{ .worker_key = worker_key, .reason = reason, .retire = death.retire };
    }

    /// One pass of the metrics thread (`metricsThreadMain` in
    /// `ingress/service_observability.zig`): every worker's usage ring, then
    /// the analytics tick.
    fn metricsTick(self: *SupervisedService) void {
        supervision.usage_drain.drainAll(self.supervisor.usageDrain(), self.supervisor.records);
        const clock = analytics.Clock{ .wall_now_ms = 1_700_000_000_000, .mono_now_ns = 2_000_000_000 };
        analytics_drain.drainAt(self, clock, 0, .announce);
    }
};

test "a usage ring head the worker moves back between a drain's peek and its advance faults the worker within one metrics tick" {
    var supervisor = try fixture.minimalSupervisorWithAnalytics(std.testing.allocator, null);
    defer fixture.deinitMinimal(&supervisor);
    const worker = try fixture.publishInertWorker(&supervisor, .{});
    try fixture.publishCompletedRecord(worker, 1);
    try fixture.publishCompletedRecord(worker, 2);

    // A drain peeks both records through the server's cursor, the worker
    // stores its head back by one, and the drain's advance moves the tail
    // past what the peek saw without loading the head again.
    const view = &worker.handle.metrics.?;
    const cursor = &view.host_cursors.records;
    const peeked = cursor.peek(view.header) orelse return error.TestExpectedPeek;
    try std.testing.expectEqual(@as(u64, 2), peeked.count);
    @atomicStore(u64, &view.header.records_head, 1, .release);
    cursor.advance(view.header, peeked, peeked.count);

    var no_lanes = [_]FakeLane{};
    var service = SupervisedService{
        .supervisor = &supervisor,
        .analytics = supervisor.analytics,
        .lanes = &no_lanes,
    };
    service.metricsTick();

    // The tick's usage drain found the head behind the tail and failed the
    // ring, and its analytics drain took the worker out of service for it.
    try std.testing.expect(worker.usage_ring_failed);
    try std.testing.expectEqual(@as(usize, 1), service.announcements);
    const announced = service.announced orelse return error.TestExpectedDeath;
    try std.testing.expectEqual(worker.key(), announced.worker_key);
    try std.testing.expectEqual(fault.WorkerFaultReason.usage_record_protocol, announced.reason);
    // No lane holds or reads the worker, so its retirement is due at once.
    try std.testing.expect(announced.retire);
    const entry = supervisor.poolFor(worker.definition_index).inspect(worker) orelse return error.TestExpectedWorker;
    try std.testing.expectEqual(supervision.pool.EntryState.dead, entry.state);
    // The tail stays where the peek put it, on the server and on the page.
    try std.testing.expectEqual(@as(u64, 2), cursor.tail);
    try std.testing.expectEqual(@as(u64, 2), @atomicLoad(u64, &view.header.records_tail, .acquire));

    // Every later tick sees the failed ring again and announces nothing.
    service.metricsTick();
    try std.testing.expectEqual(@as(usize, 1), service.announcements);
}

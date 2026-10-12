//! How ingress produces and drains its records: the status and the worker
//! fault an access record carries for each way a request ends, and the usage
//! settle each way implies (`endingFor` and `settleOutcomeFor` in
//! `runner/request_finish.zig`), and the metrics tick of
//! `ingress/analytics_drain.zig`: it moves every lane's access ring into the
//! sink and flushes it; it drains each worker's console lines before its
//! usage records, moving the worker it drains first along the supervisor's
//! records, writing each line under the worker's definition name and under
//! the request and route the worker's request table confirms; and it takes
//! out of service, once, a worker whose usage ring head moved back behind the
//! server's tail or whose VM thread overran its owner's deadline. Lane
//! `server-ingress-test`; draining one log ring is covered in
//! `tests/analytics/logs.zig`, the encoders and the sink in the rest of
//! `tests/analytics/`, the usage drain's own handling of a failed ring in
//! `tests/supervisor/usage.zig`, and the request table's ring of ended
//! requests in `tests/supervisor/`.

const std = @import("std");
const analytics = @import("collo_server_analytics");
const page = @import("collo_worker_state").page;
const server_main = @import("collo_server_main");
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
        .{ .outcome = .{ .deadline_expired = .deadline_grace_expired }, .status = 504 },
        .{ .outcome = .{ .deadline_expired = .owner_overran }, .status = 504 },
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
    // theirs; a deadline's names the fault that found the request past it.
    const died: request_finish.RequestOutcome = .{ .worker_died = .{ .status = .crash, .reason = .exited } };
    try std.testing.expectEqual(@as(?fault.WorkerFaultReason, .exited), request_finish.endingFor(died).worker_fault);
    try std.testing.expectEqual(
        @as(?fault.WorkerFaultReason, .deadline_grace_expired),
        request_finish.endingFor(.{ .deadline_expired = .deadline_grace_expired }).worker_fault,
    );
    try std.testing.expectEqual(
        @as(?fault.WorkerFaultReason, .owner_overran),
        request_finish.endingFor(.{ .deadline_expired = .owner_overran }).worker_fault,
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
        .{ .outcome = .{ .deadline_expired = .deadline_grace_expired }, .status = .deadline, .worker_fault = "deadline_grace_expired" },
        .{ .outcome = .{ .deadline_expired = .owner_overran }, .status = .deadline, .worker_fault = "owner_overran" },
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

test "an owner overruns its deadline only past the grace, and a deadline near the top of the clock never wraps into an early fault" {
    const grace_ns = analytics_drain.ownerOverrunGraceNs(250 * std.time.ns_per_ms);
    // The grace backstop of a request that owns the overrun fires first.
    try std.testing.expectEqual(@as(u64, 350 * std.time.ns_per_ms), grace_ns);
    const deadline_ns: u64 = 10 * std.time.ns_per_s;

    try std.testing.expect(!analytics_drain.ownerOverran(0, std.math.maxInt(u64), grace_ns));
    try std.testing.expect(!analytics_drain.ownerOverran(deadline_ns, deadline_ns + 100 * std.time.ns_per_ms, grace_ns));
    try std.testing.expect(!analytics_drain.ownerOverran(deadline_ns, deadline_ns + grace_ns, grace_ns));
    try std.testing.expect(analytics_drain.ownerOverran(deadline_ns, deadline_ns + 400 * std.time.ns_per_ms, grace_ns));
    // The deadline is the worker's claim: without saturation, this sum would
    // wrap below `now` and fault the worker at once.
    const near_top = std.math.maxInt(u64) - std.time.ns_per_ms;
    try std.testing.expect(!analytics_drain.ownerOverran(near_top, std.math.maxInt(u64), grace_ns));
    // A grace that saturates the clock never faults either.
    try std.testing.expect(!analytics_drain.ownerOverran(deadline_ns, std.math.maxInt(u64), std.math.maxInt(u64)));
}

const FakeLane = struct {
    access_ring: access.AccessRing = .{},
};

/// The service as the metrics thread reads it, over a fixture supervisor
/// whose pools take a worker out of service for real. It keeps each death it
/// is asked to announce instead of posting it to lanes. `analytics` is a
/// sink of the test's own, whose console the test reads back; the
/// supervisor's sink takes the usage records.
const Service = struct {
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
        self: *Service,
        _: *WorkerRecord,
        worker_key: WorkerKey,
        death: WorkerPool.Death,
        reason: fault.WorkerFaultReason,
    ) void {
        self.announcements += 1;
        self.announced = .{ .worker_key = worker_key, .reason = reason, .retire = death.retire };
    }

    /// One metrics tick at `clock`.
    fn tickAt(self: *Service, clock: analytics.Clock) void {
        analytics_drain.drainAt(self, clock, 0, .announce);
    }
};

const tick_clock = analytics.Clock{ .wall_now_ms = 1_700_000_000_000, .mono_now_ns = 20 * std.time.ns_per_s };

/// A sink of the test's own whose console lines land in `console.txt` of a
/// temporary directory, with the record files in that directory too.
const OwnSink = struct {
    tmp: std.testing.TmpDir,
    console: std.fs.File,
    sink: analytics.Sink,

    fn init(target: *OwnSink, with_directory: bool) !void {
        target.tmp = std.testing.tmpDir(.{});
        errdefer target.tmp.cleanup();
        target.console = try target.tmp.dir.createFile("console.txt", .{ .read = true });
        errdefer target.console.close();
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = try target.tmp.dir.realpath(".", &path_buffer);
        try target.sink.open(std.testing.allocator, .{
            .directory = if (with_directory) path else null,
            .console_fd = target.console.handle,
        });
    }

    fn deinit(self: *OwnSink) void {
        self.sink.close();
        self.console.close();
        self.tmp.cleanup();
    }

    /// Everything the console stream wrote so far, which the caller frees.
    fn readConsole(self: *OwnSink) ![]u8 {
        self.sink.flushConsole();
        return self.tmp.dir.readFileAlloc(std.testing.allocator, "console.txt", file_bytes_max);
    }

    /// Everything `name` holds so far, which the caller frees.
    fn readFile(self: *OwnSink, name: []const u8) ![]u8 {
        self.sink.flush(0);
        return self.tmp.dir.readFileAlloc(std.testing.allocator, name, file_bytes_max);
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
    var supervisor = try fixture.minimalSupervisor(std.testing.allocator);
    defer fixture.deinitMinimal(&supervisor);
    var output: OwnSink = undefined;
    try output.init(true);
    defer output.deinit();

    const lanes = try std.testing.allocator.alloc(FakeLane, 2);
    defer std.testing.allocator.free(lanes);
    for (lanes) |*lane|
        lane.* = .{ .access_ring = try access.AccessRing.init() };
    defer for (lanes) |*lane| lane.access_ring.deinit();
    try std.testing.expect(lanes[0].access_ring.push(makeRecord(1)));
    try std.testing.expect(lanes[1].access_ring.push(makeRecord(2)));
    try std.testing.expect(lanes[1].access_ring.push(makeRecord(3)));

    var service = Service{ .supervisor = &supervisor, .analytics = &output.sink, .lanes = lanes };
    service.tickAt(tick_clock);

    // The tick flushed, so the records are already in the file.
    const written = try output.tmp.dir.readFileAlloc(std.testing.allocator, "access.jsonl", file_bytes_max);
    defer std.testing.allocator.free(written);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, written, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, written, "\"request_id\":1,") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"request_id\":3,") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"client_ip\":\"127.0.0.1\"") != null);
}

/// The view of `worker`'s shared page, which the record owns.
fn pageOf(worker: *WorkerRecord) !*page.WorkerWriterView {
    if (worker.handle.metrics) |*view|
        return view;
    return error.NoSharedPage;
}

test "the worker a tick drains first moves along the records every tick, under its definition name" {
    var supervisor = try fixture.minimalSupervisor(std.testing.allocator);
    defer fixture.deinitMinimal(&supervisor);
    var output: OwnSink = undefined;
    try output.init(false);
    defer output.deinit();
    const first = try fixture.publishInertWorker(&supervisor, .{ .definition_index = 0 });
    const second = try fixture.publishInertWorker(&supervisor, .{ .definition_index = 1 });

    var no_lanes = [_]FakeLane{};
    var service = Service{ .supervisor = &supervisor, .analytics = &output.sink, .lanes = &no_lanes };
    // A worker that fills the console buffer alone crowds out whoever drains
    // after it, so the order must not always favor the same worker.
    for (0..2) |tick| {
        (try pageOf(first)).publishLogLine(.info, 0, 0, 1_000_000_000, if (tick == 0) "a" else "c");
        (try pageOf(second)).publishLogLine(.info, 0, 0, 1_000_000_000, if (tick == 0) "b" else "d");
        service.tickAt(tick_clock);
    }
    try std.testing.expectEqual(@as(usize, 0), service.announcements);

    const written = try output.readConsole();
    defer std.testing.allocator.free(written);
    // The records hold the definitions in index order, so the first tick
    // starts at "demo" and the second at "beta".
    try std.testing.expectEqualStrings(
        "[demo] a\n" ++
            "[beta] b\n" ++
            "[beta] d\n" ++
            "[demo] c\n",
        written,
    );
}

test "a console line keeps its request id only when the worker's request table confirms it, and prints that request's route" {
    var supervisor = try fixture.minimalSupervisor(std.testing.allocator);
    defer fixture.deinitMinimal(&supervisor);
    var output: OwnSink = undefined;
    try output.init(true);
    defer output.deinit();
    const worker = try fixture.publishInertWorker(&supervisor, .{});
    const view = try pageOf(worker);

    // Request 5 is in flight on the worker; request 7 ran on it and ended,
    // which leaves it only in the table's ring of ended requests; request 9
    // was never sent to it, such as another worker's request.
    try worker.requests.record(fixture.dispatchedRequest(5));
    try worker.requests.record(fixture.dispatchedRequest(7));
    try std.testing.expect(worker.requests.settle(7, false) == .freed);
    view.publishLogLine(.info, 0, 5, 1_000_000_000, "live");
    view.publishLogLine(.info, 0, 7, 1_000_000_000, "ended");
    view.publishLogLine(.warn, 0, 9, 1_000_000_000, "forged");
    view.publishLogLine(.info, 0, 0, 1_000_000_000, "top level");

    var no_lanes = [_]FakeLane{};
    var service = Service{ .supervisor = &supervisor, .analytics = &output.sink, .lanes = &no_lanes };
    const refused_before = supervisor.usage_counters.console_ids_refused.load(.monotonic);
    service.tickAt(tick_clock);
    // Only the forged id counts; a line under no request names none.
    try std.testing.expectEqual(refused_before + 1, supervisor.usage_counters.console_ids_refused.load(.monotonic));

    const console = try output.readConsole();
    defer std.testing.allocator.free(console);
    try std.testing.expectEqualStrings(
        "[demo /demo/*] live\n" ++
            "[demo /demo/*] ended\n" ++
            "[demo] forged\n" ++
            "[demo] top level\n",
        console,
    );

    const records = try output.readFile("logs.jsonl");
    defer std.testing.allocator.free(records);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, records, "\n"), '\n');
    const expected = [_]struct { request_id: i64, route: []const u8 }{
        .{ .request_id = 5, .route = "/demo/*" },
        .{ .request_id = 7, .route = "/demo/*" },
        .{ .request_id = 0, .route = "" },
        .{ .request_id = 0, .route = "" },
    };
    for (expected) |line_expected| {
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, lines.next().?, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(line_expected.request_id, parsed.value.object.get("request_id").?.integer);
        try std.testing.expectEqualStrings(line_expected.route, parsed.value.object.get("route").?.string);
    }
    try std.testing.expect(lines.next() == null);
}

test "a console line of a request whose usage record the same tick drains still prints the request's route" {
    var supervisor = try fixture.minimalSupervisor(std.testing.allocator);
    defer fixture.deinitMinimal(&supervisor);
    var output: OwnSink = undefined;
    try output.init(false);
    defer output.deinit();
    const worker = try fixture.publishInertWorker(&supervisor, .{});

    // Request 3 completed: its entry awaits the usage record already in the
    // ring, and the tick's usage drain frees that entry. Console lines drain
    // first, so the line finds the entry itself rather than the table's ring
    // of ended requests, which would find it too.
    try fixture.publishCompletedRecord(worker, 3);
    (try pageOf(worker)).publishLogLine(.info, 0, 3, 1_000_000_000, "done");

    var no_lanes = [_]FakeLane{};
    var service = Service{ .supervisor = &supervisor, .analytics = &output.sink, .lanes = &no_lanes };
    service.tickAt(tick_clock);
    try std.testing.expect(worker.requests.dispatchedFor(3) == null);

    const console = try output.readConsole();
    defer std.testing.allocator.free(console);
    try std.testing.expectEqualStrings("[demo /demo/*] done\n", console);
}

test "a usage ring head the worker moves back between a drain's peek and its advance faults the worker within one metrics tick" {
    var supervisor = try fixture.minimalSupervisorWithAnalytics(std.testing.allocator, null);
    defer fixture.deinitMinimal(&supervisor);
    const worker = try fixture.publishInertWorker(&supervisor, .{});
    try fixture.publishCompletedRecord(worker, 1);
    try fixture.publishCompletedRecord(worker, 2);

    // A drain peeks both records through the server's cursor, the worker
    // stores its head back by one, and the drain's advance moves the tail
    // past what the peek saw without loading the head again.
    const view = try pageOf(worker);
    const cursor = &view.host_cursors.records;
    const peeked = cursor.peek(view.header) orelse return error.TestExpectedPeek;
    try std.testing.expectEqual(@as(u64, 2), peeked.count);
    @atomicStore(u64, &view.header.records_head, 1, .release);
    cursor.advance(view.header, peeked, peeked.count);

    var no_lanes = [_]FakeLane{};
    var service = Service{
        .supervisor = &supervisor,
        .analytics = supervisor.analytics,
        .lanes = &no_lanes,
    };
    service.tickAt(tick_clock);

    // The tick's usage drain found the head behind the tail and failed the
    // ring, and the same tick took the worker out of service for it.
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
    service.tickAt(tick_clock);
    try std.testing.expectEqual(@as(usize, 1), service.announcements);
}

test "a worker whose VM thread works for an owner 400 ms past its deadline is faulted once as owner_overran; 100 ms past, or no deadline, is left in service" {
    var supervisor = try fixture.minimalSupervisor(std.testing.allocator);
    defer fixture.deinitMinimal(&supervisor);
    // The fixture keeps the default 250 ms grace backstop, so the watch
    // fires past 350 ms.
    try std.testing.expectEqual(@as(u64, 250 * std.time.ns_per_ms), supervisor.hard_timeout_grace_ns);
    const hung = try fixture.publishInertWorker(&supervisor, .{ .definition_index = 0 });
    const late = try fixture.publishInertWorker(&supervisor, .{ .definition_index = 1 });
    const idle = try fixture.publishInertWorker(&supervisor, .{ .definition_index = 2 });
    const now_ns = tick_clock.mono_now_ns;
    (try pageOf(hung)).publishOwner(std.math.maxInt(u64), now_ns - 400 * std.time.ns_per_ms);
    (try pageOf(late)).publishOwner(41, now_ns - 100 * std.time.ns_per_ms);
    (try pageOf(idle)).publishOwner(0, 0);

    var no_lanes = [_]FakeLane{};
    var service = Service{ .supervisor = &supervisor, .analytics = supervisor.analytics, .lanes = &no_lanes };
    service.tickAt(tick_clock);

    try std.testing.expectEqual(@as(usize, 1), service.announcements);
    const announced = service.announced orelse return error.TestExpectedDeath;
    try std.testing.expectEqual(hung.key(), announced.worker_key);
    try std.testing.expectEqual(fault.WorkerFaultReason.owner_overran, announced.reason);
    // No lane holds or reads it, so its retirement, the reaper's kill, is
    // due at once.
    try std.testing.expect(announced.retire);
    const hung_entry = supervisor.poolFor(hung.definition_index).inspect(hung) orelse return error.TestExpectedWorker;
    try std.testing.expectEqual(supervision.pool.EntryState.dead, hung_entry.state);
    for ([_]*WorkerRecord{ late, idle }) |kept| {
        const entry = supervisor.poolFor(kept.definition_index).inspect(kept) orelse return error.TestExpectedWorker;
        try std.testing.expectEqual(supervision.pool.EntryState.live, entry.state);
    }

    // The page still names the overrun on the next tick, which announces
    // nothing more.
    service.tickAt(tick_clock);
    try std.testing.expectEqual(@as(usize, 1), service.announcements);
}

test "the exiting thread's last drain marks an owner overrun without announcing it" {
    var supervisor = try fixture.minimalSupervisor(std.testing.allocator);
    defer fixture.deinitMinimal(&supervisor);
    const hung = try fixture.publishInertWorker(&supervisor, .{});
    (try pageOf(hung)).publishOwner(1, tick_clock.mono_now_ns - std.time.ns_per_s);

    var no_lanes = [_]FakeLane{};
    var service = Service{ .supervisor = &supervisor, .analytics = supervisor.analytics, .lanes = &no_lanes };
    analytics_drain.drainAt(&service, tick_clock, 0, .mark_only);
    try std.testing.expectEqual(@as(usize, 0), service.announcements);
    const entry = supervisor.poolFor(hung.definition_index).inspect(hung) orelse return error.TestExpectedWorker;
    try std.testing.expectEqual(supervision.pool.EntryState.live, entry.state);
}

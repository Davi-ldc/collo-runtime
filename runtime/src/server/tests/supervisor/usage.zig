//! The usage path from a worker's usage record ring into `usage.jsonl`: what
//! a drain writes, whose identity, times and cold start it puts on each
//! record (the server's dispatch and the lane's end, never the worker's
//! claims), which rings it leaves alone (an unmapped page, a head moved
//! behind the server's tail), the route pattern every record carries, which
//! worker records the request table lets through, holds back until the
//! request ends or its floor is written, skips or refuses, how an ended
//! request settles and parks in that table and what its floor carries (the
//! live slot's CPU, or the running window the sentinel saw), the table's ring
//! of ended requests, the record format and its bound, what a full usage
//! stream drops, counts and settles, at a settle and at a death too, and the
//! exactly-once rules between a drain and synthesis, which allocate nothing.
//! Supervisor-level lifecycles that end in these drains, and a full usage
//! stream seen from the supervisor, are covered in `supervisor.zig` and
//! `reaper/retirement.zig`; the sink's own buffering, writes and files in
//! `server/tests/analytics/sink.zig`. Lane `server-supervisor-test`.

const std = @import("std");
const analytics = @import("collo_server_analytics");
const config = @import("collo_server_config");
const supervision = @import("collo_server_supervisor");
const worker_shared_page = @import("collo_worker_state").page;
const worker_metrics_state = @import("collo_worker_state").metrics;
const fixture = @import("supervisor_fixture");

const Supervisor = supervision.Supervisor;
const usage_drain = supervision.usage_drain;
const usage_log = supervision.usage_log;
const request_table = supervision.request_table;
const WorkerRecord = supervision.worker_table.Record;

/// A supervisor with a sink of its own, whose usage drain the tests run over
/// stack worker records. Initialized in place, because the drain context
/// points into the supervisor.
const Harness = struct {
    dir: fixture.AnalyticsDir,
    supervisor: Supervisor,

    /// A sink that keeps `usage.jsonl` in a temporary directory.
    fn init(self: *Harness) !void {
        return self.initKeepingFiles(true);
    }

    /// `keep_files` false gives a sink with no analytics directory.
    fn initKeepingFiles(self: *Harness, keep_files: bool) !void {
        self.dir = try fixture.AnalyticsDir.init(std.testing.allocator);
        errdefer self.dir.deinit(std.testing.allocator);
        self.supervisor = try fixture.minimalSupervisorWithAnalytics(
            std.testing.allocator,
            if (keep_files) self.dir.path else null,
        );
    }

    fn deinit(self: *Harness) void {
        fixture.deinitMinimal(&self.supervisor);
        self.dir.deinit(std.testing.allocator);
    }

    fn drain(self: *Harness) usage_drain.UsageDrain {
        return self.supervisor.usageDrain();
    }

    fn sink(self: *Harness) *analytics.Sink {
        return self.supervisor.analytics;
    }

    fn log(self: *Harness) *usage_log.UsageLog {
        return &self.supervisor.usage;
    }

    fn lines(self: *Harness) !fixture.UsageLines {
        return self.dir.readUsage(std.testing.allocator, self.sink());
    }

    fn rejected(self: *Harness) u64 {
        return self.drain().counters.records_rejected.load(.monotonic);
    }
};

/// A shared page with a ring the test writes completion records into, the way
/// a worker would.
const Page = struct {
    fd: std.posix.fd_t,
    view: worker_shared_page.WorkerWriterView,

    fn init(self: *Page, name: []const u8) !void {
        self.fd = try worker_shared_page.createMemfd(name);
        errdefer std.posix.close(self.fd);
        self.view = try worker_shared_page.mapReadWrite(self.fd);
        self.view.initializeCrashDefault();
    }

    fn deinit(self: *Page) void {
        self.view.deinit();
        std.posix.close(self.fd);
    }

    fn append(self: *Page, record: worker_shared_page.CompletedRecord) !void {
        var state = worker_metrics_state.WorkState.init(&self.view);
        try state.appendCompletedRecord(record);
    }

    /// Records left in the ring as the worker's room check counts them: from
    /// the tail the server last stored to the worker's head.
    fn pending(self: *const Page) u64 {
        const header = self.view.header;
        return @atomicLoad(u64, &header.records_head, .acquire) -% @atomicLoad(u64, &header.records_tail, .acquire);
    }
};

/// A stack worker record of definition 0 whose ring is `page`.
fn stackWorker(page: *Page, id: u64, generation: u64) WorkerRecord {
    return stackWorkerOf(page, id, generation, 0);
}

fn stackWorkerOf(page: *Page, id: u64, generation: u64, definition: config.DefinitionIndex) WorkerRecord {
    var worker = fixture.stackWorker(id, generation, definition);
    worker.handle.metrics = page.view;
    worker.page_mapped = true;
    return worker;
}

fn completedRecord(request_id: u64) worker_shared_page.CompletedRecord {
    return std.mem.zeroInit(worker_shared_page.CompletedRecord, .{
        .request_id = request_id,
        .cpu_ns = 3,
        .status = @intFromEnum(worker_shared_page.CompletedStatus.done),
    });
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

/// The worker's record for the request `identity` names, with the request
/// key fields an honest worker copies from its dispatch.
fn completedRecordFor(identity: worker_shared_page.LifecycleIdentity) worker_shared_page.CompletedRecord {
    var record = completedRecord(identity.external_request_id);
    record.request_lane_id = identity.request_lane_id;
    record.request_slot = identity.request_slot;
    record.request_generation = identity.request_generation;
    return record;
}

/// Notes the lane's end of request `request_id` on `worker`, a millisecond
/// after its dispatch at 1 ns, which a drain needs before it writes the
/// worker's record.
fn endRequest(worker: *WorkerRecord, request_id: u64) void {
    worker.requests.noteEnded(request_id, ended_ns);
}

/// The lane's end the tests note, `ended_ns - 1` after `dispatchedAs` and
/// `fixture.dispatchedRequest` start their requests.
const ended_ns: u64 = 1 + std.time.ns_per_ms;

test "a drain stamps the server's identity, times and cold start on the record, never what the worker wrote" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var page: Page = undefined;
    try page.init("usage-identity-stamp");
    defer page.deinit();
    var worker = stackWorker(&page, 7, 3);
    // A cold start's request, which the server dispatched at t and ended at
    // t + 5 ms, while the worker's record speaks of ten seconds.
    const dispatched_ns: u64 = 1_000_000_000;
    const lane_end_ns: u64 = dispatched_ns + 5 * std.time.ns_per_ms;
    var dispatched = fixture.dispatchedRequest(42);
    dispatched.accounting_flags = worker_shared_page.AccountingFlags.cold_start;
    dispatched.started_mono_ns = dispatched_ns;
    try worker.requests.record(dispatched);

    var record = completedRecord(42);
    record.client_served_bytes = 100;
    record.fetch_sent_bytes = 20;
    record.fetch_received_bytes = 3;
    record.fetch_wire_bytes = 77;
    record.exec_ns = 10 * std.time.ns_per_s;
    record.io_ns = 9;
    record.waiting_ns = 4;
    try page.append(record);

    // The record waits in the ring until the lane ends the request.
    try std.testing.expectEqual(@as(usize, 0), usage_drain.drainWorker(harness.drain(), &worker));
    try std.testing.expectEqual(@as(u64, 1), page.pending());
    worker.requests.noteEnded(42, lane_end_ns);
    const clock = analytics.Clock.capture();
    try std.testing.expectEqual(@as(usize, 1), usage_drain.drainWorker(harness.drain(), &worker));
    try std.testing.expectEqual(@as(u64, 0), page.pending());

    var lines = try harness.lines();
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    const line = lines.items[0];
    try std.testing.expectEqualStrings(fixture.definition_names[0], line.worker);
    try std.testing.expectEqualStrings(fixture.route_patterns[0], line.route);
    try std.testing.expectEqual(@as(u64, 7), line.worker_id);
    try std.testing.expectEqual(@as(u64, 3), line.worker_generation);
    try std.testing.expectEqualStrings("worker", line.origin);
    try std.testing.expectEqual(@as(u64, 42), line.request_id);
    try std.testing.expectEqualStrings("done", line.error_code);
    // The cold start, the wall time and `ts` are the server's: its
    // dispatch's flags, its dispatch to the lane's end, and that end on the
    // wall clock.
    try std.testing.expect(line.cold_start);
    try std.testing.expectEqual(5 * std.time.ns_per_ms, line.wall_ns);
    // The drain captured both clocks a moment after this test did.
    const expected_ts = clock.wallMs(lane_end_ns);
    try std.testing.expect(line.ts >= expected_ts);
    try std.testing.expect(line.ts <= expected_ts + 2);
    try std.testing.expectEqual(10 * std.time.ns_per_s, line.exec_ns);
    try std.testing.expectEqual(@as(u64, 3), line.cpu_ns);
    try std.testing.expectEqual(@as(u64, 9), line.io_ns);
    try std.testing.expectEqual(@as(u64, 4), line.waiting_ns);
    try std.testing.expectEqual(@as(u64, 100), line.client_served_bytes);
    try std.testing.expectEqual(@as(u64, 20), line.fetch_sent_bytes);
    try std.testing.expectEqual(@as(u64, 3), line.fetch_received_bytes);
    try std.testing.expectEqual(@as(u64, 77), line.fetch_wire_bytes);
}

test "a usage record carries the pattern of the route its request was dispatched to, whoever wrote it (#33)" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var page: Page = undefined;
    try page.init("usage-route-pattern");
    defer page.deinit();
    const beta: config.DefinitionIndex = 1;
    var worker = stackWorkerOf(&page, 7, 3, beta);

    // The worker's own record of one request, and a floor the server writes
    // for another it ended itself.
    try worker.requests.record(fixture.dispatchedRequest(10));
    try page.append(completedRecord(10));
    endRequest(&worker, 10);
    try std.testing.expectEqual(@as(usize, 1), usage_drain.drainWorker(harness.drain(), &worker));
    try worker.requests.record(fixture.dispatchedRequest(11));
    usage_drain.settleRequest(harness.drain(), &worker, 11, .{ .floor = .{ .status = .crash } }, ended_ns);

    var lines = try harness.lines();
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, 2), lines.items.len);
    try std.testing.expectEqual(@as(u64, 10), lines.items[0].request_id);
    try std.testing.expectEqualStrings("worker", lines.items[0].origin);
    try std.testing.expectEqual(@as(u64, 11), lines.items[1].request_id);
    try std.testing.expectEqualStrings("server", lines.items[1].origin);
    for (lines.items) |line| {
        try std.testing.expectEqualStrings(fixture.definition_names[beta], line.worker);
        try std.testing.expectEqualStrings(fixture.route_patterns[beta], line.route);
    }
}

test "a status outside the enum is recorded as internal_error" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var page: Page = undefined;
    try page.init("usage-hostile-status");
    defer page.deinit();
    var worker = stackWorker(&page, 7, 3);
    try worker.requests.record(fixture.dispatchedRequest(5));
    var record = completedRecord(5);
    record.status = 0xffff;
    try page.append(record);
    endRequest(&worker, 5);

    _ = usage_drain.drainWorker(harness.drain(), &worker);
    var lines = try harness.lines();
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqualStrings("internal_error", lines.items[0].error_code);
}

test "a record leaves the ring once the sink holds it, and reaches the file when the sink flushes" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var page: Page = undefined;
    try page.init("usage-held-before-flush");
    defer page.deinit();
    var worker = stackWorker(&page, 7, 3);
    try worker.requests.record(fixture.dispatchedRequest(42));
    try page.append(completedRecord(42));
    endRequest(&worker, 42);

    try std.testing.expectEqual(@as(usize, 1), usage_drain.drainWorker(harness.drain(), &worker));
    try std.testing.expectEqual(@as(u64, 0), page.pending());
    // A drain only copies into the sink's buffer; the flushing thread writes.
    const before_flush = try harness.dir.tmp.dir.readFileAlloc(std.testing.allocator, "usage.jsonl", 1024);
    defer std.testing.allocator.free(before_flush);
    try std.testing.expectEqual(@as(usize, 0), before_flush.len);

    var lines = try harness.lines();
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
}

test "a full usage stream drops and counts batches, keeps the reserve for floors and stays full until written out" {
    // The sink logs the start of the full usage stream once, at `err`, and
    // not again for the refusals that follow in the same episode.
    @import("root").expect_log_errors = 1;
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    try std.testing.expect(!harness.sink().full(.usage));

    const clock: analytics.Clock = .{ .wall_now_ms = 1_000_000, .mono_now_ns = 10 };
    const identity: analytics.Identity = .{ .worker = "demo", .route = "/demo/*", .worker_id = 7, .worker_generation = 3 };
    const record = analytics.usage.fromCompleted(
        identity,
        .worker,
        completedRecord(1),
        .{ .started_mono_ns = 1, .accounting_flags = 0 },
        clock.mono_now_ns,
        clock,
    );

    // Room for floors only: a batch must leave the synthesis reserve free.
    try fixture.fillStream(std.testing.allocator, harness.sink(), .usage, usage_log.synthesis_reserve_bytes);
    try std.testing.expectEqual(usage_log.AppendOutcome.dropped, harness.log().append(&.{record}, .drop));
    try std.testing.expectEqual(@as(u64, 1), harness.sink().stats(.usage).dropped);
    try std.testing.expect(harness.sink().full(.usage));
    try std.testing.expectEqual(usage_log.AppendOutcome.dropped, harness.log().append(&.{ record, record }, .drop));
    try std.testing.expectEqual(@as(u64, 3), harness.sink().stats(.usage).dropped);

    // A floor still lands in the reserve, and the stream stays full, since
    // batches still find no room.
    try std.testing.expectEqual(usage_log.FloorOutcome.taken, harness.log().appendFloor(&record));
    try std.testing.expect(harness.sink().full(.usage));

    // Written out, the stream has room again and takes batches.
    harness.sink().flush(0);
    try std.testing.expect(!harness.sink().full(.usage));
    try std.testing.expectEqual(usage_log.AppendOutcome.taken, harness.log().append(&.{record}, .drop));
    try std.testing.expectEqual(@as(u64, 3), harness.sink().stats(.usage).dropped);
}

test "a worst-case record stays within its encoded bound" {
    // Names past their caps, made of bytes that escape to six each.
    const name = [_]u8{0x01} ** 300;
    const widest = analytics.usage.UsageRecord{
        .identity = .{
            .worker = &name,
            .route = &name,
            .worker_id = std.math.maxInt(u64),
            .worker_generation = std.math.maxInt(u64),
        },
        .origin = .worker,
        .request_id = std.math.maxInt(u64),
        .ts_ms = std.math.maxInt(u64),
        .wall_ns = std.math.maxInt(u64),
        .exec_ns = std.math.maxInt(u64),
        .waiting_ns = std.math.maxInt(u64),
        .io_ns = std.math.maxInt(u64),
        .cpu_ns = std.math.maxInt(u64),
        .client_served_bytes = std.math.maxInt(u64),
        .fetch_sent_bytes = std.math.maxInt(u64),
        .fetch_received_bytes = std.math.maxInt(u64),
        .fetch_wire_bytes = std.math.maxInt(u64),
        .error_code = .internal_error,
        .cold_start = false,
        .worker_fault = name[0..@import("collo_limits").runtime_logs.WORKER_FAULT_BYTES_MAX],
    };
    var buffer: [analytics.usage.json_record_bytes_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try analytics.usage.writeRecordJson(&writer, &widest);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, writer.buffered(), .{});
    defer parsed.deinit();
}

test "without an analytics directory records are counted and dropped and the ring advances" {
    var harness: Harness = undefined;
    try harness.initKeepingFiles(false);
    defer harness.deinit();
    var page: Page = undefined;
    try page.init("usage-no-directory");
    defer page.deinit();
    var worker = stackWorker(&page, 7, 3);
    try worker.requests.record(fixture.dispatchedRequest(1));
    try page.append(completedRecord(1));
    endRequest(&worker, 1);

    try std.testing.expectEqual(@as(usize, 1), usage_drain.drainWorker(harness.drain(), &worker));
    try std.testing.expectEqual(@as(u64, 0), page.pending());
    try std.testing.expectEqual(@as(u64, 1), harness.sink().stats(.usage).discarded);
    try std.testing.expect(!harness.sink().full(.usage));
    try std.testing.expectEqual(@as(u64, 0), harness.sink().stats(.usage).dropped);
}

test "no drain reads a worker whose page is marked unmapped" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var page: Page = undefined;
    try page.init("usage-unmapped-page");
    defer page.deinit();
    var worker = stackWorker(&page, 7, 3);
    try worker.requests.record(fixture.dispatchedRequest(40));
    try page.append(completedRecord(40));
    endRequest(&worker, 40);

    // The final drain marks the page unmapped before the teardown unmaps it,
    // and from then on a lane's drain and the drain of every record leave
    // the ring alone.
    worker.page_mapped = false;
    try std.testing.expectEqual(@as(usize, 0), usage_drain.drainWorker(harness.drain(), &worker));
    usage_drain.drainAll(harness.drain(), (&worker)[0..1]);
    try std.testing.expectEqual(@as(u64, 1), page.pending());
    var lines = try harness.lines();
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, 0), lines.items.len);
}

test "a head moved back behind the server's tail fails the ring for good, and a request the server ends there gets a floor" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var page: Page = undefined;
    try page.init("usage-head-moved-back");
    defer page.deinit();
    var worker = stackWorker(&page, 9, 2);

    // Two records drained as usual put the server's tail at 2.
    for ([_]u64{ 840, 841 }) |request_id| {
        try worker.requests.record(fixture.dispatchedRequest(request_id));
        try page.append(completedRecord(request_id));
        endRequest(&worker, request_id);
    }
    try std.testing.expectEqual(@as(usize, 2), usage_drain.drainWorker(harness.drain(), &worker));

    // The worker appends request 842's record, then stores a head behind the
    // server's tail, which no append produces.
    try worker.requests.record(fixture.dispatchedRequest(842));
    try page.append(completedRecord(842));
    @atomicStore(u64, &page.view.header.records_head, 1, .release);
    try std.testing.expectEqual(@as(usize, 0), usage_drain.drainWorker(harness.drain(), &worker));
    try std.testing.expect(worker.usage_ring_failed);
    try std.testing.expectEqual(@as(u64, 2), worker.handle.metrics.?.host_cursors.records.tail);

    // A head put back where it was changes nothing: the ring stays failed, so
    // the floor the server writes for request 842 is its only record.
    @atomicStore(u64, &page.view.header.records_head, 3, .release);
    usage_drain.settleRequest(harness.drain(), &worker, 842, .{ .floor = .{
        .status = .crash,
        .worker_fault = "usage_record_protocol",
    } }, ended_ns);
    try std.testing.expectEqual(@as(usize, 0), usage_drain.drainWorker(harness.drain(), &worker));
    try std.testing.expectEqual(@as(u64, 2), worker.handle.metrics.?.host_cursors.records.tail);

    var lines = try harness.lines();
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, 3), lines.items.len);
    try std.testing.expectEqual(@as(u64, 842), lines.items[2].request_id);
    try std.testing.expectEqualStrings("server", lines.items[2].origin);
    try std.testing.expectEqualStrings("crash", lines.items[2].error_code);
    try std.testing.expectEqualStrings("usage_record_protocol", lines.items[2].worker_fault);
}

test "a drain refuses a record for a request the worker was never dispatched" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var page: Page = undefined;
    try page.init("usage-undispatched");
    defer page.deinit();
    var worker = stackWorker(&page, 7, 3);
    try worker.requests.record(fixture.dispatchedRequest(10));
    try page.append(completedRecord(11));
    try page.append(completedRecord(10));
    endRequest(&worker, 10);

    // The refused record is dropped, so the ring moves past it and the record
    // behind it is still written.
    try std.testing.expectEqual(@as(usize, 1), usage_drain.drainWorker(harness.drain(), &worker));
    try std.testing.expectEqual(@as(u64, 0), page.pending());
    try std.testing.expectEqual(@as(u64, 1), harness.rejected());

    var lines = try harness.lines();
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqual(@as(u64, 10), lines.items[0].request_id);
}

test "a request's record is written once and every duplicate is refused" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var page: Page = undefined;
    try page.init("usage-duplicate");
    defer page.deinit();
    var worker = stackWorker(&page, 7, 3);
    try worker.requests.record(fixture.dispatchedRequest(20));
    endRequest(&worker, 20);

    // A duplicate in the same batch, then one in a later drain.
    try page.append(completedRecord(20));
    try page.append(completedRecord(20));
    try std.testing.expectEqual(@as(usize, 1), usage_drain.drainWorker(harness.drain(), &worker));
    try page.append(completedRecord(20));
    try std.testing.expectEqual(@as(usize, 0), usage_drain.drainWorker(harness.drain(), &worker));
    try std.testing.expectEqual(@as(u64, 2), harness.rejected());
    try std.testing.expect(worker.requests.usageRecorded(20));

    var lines = try harness.lines();
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
}

test "a drain waits behind a request the server has not ended or whose floor it writes, and skips without a count the record of one whose floor it wrote" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var page: Page = undefined;
    try page.init("usage-waiting-record");
    defer page.deinit();
    var worker = stackWorker(&page, 7, 3);
    try worker.requests.record(fixture.dispatchedRequest(77));
    try worker.requests.record(fixture.dispatchedRequest(78));
    try page.append(completedRecord(77));
    try page.append(completedRecord(78));

    // Request 77 runs on as far as the server knows, so its record waits and
    // holds back 78's behind it, ended or not.
    endRequest(&worker, 78);
    try std.testing.expectEqual(@as(usize, 0), usage_drain.drainWorker(harness.drain(), &worker));
    try std.testing.expectEqual(@as(u64, 2), page.pending());

    // Ended, but its floor being written: still waiting.
    endRequest(&worker, 77);
    worker.requests.beginSynthesis(77);
    try std.testing.expectEqual(@as(usize, 0), usage_drain.drainWorker(harness.drain(), &worker));
    try std.testing.expectEqual(@as(u64, 2), page.pending());

    // Its floor written, 77's record is skipped, not refused, and 78's
    // written.
    worker.requests.finishSynthesis(77, true);
    try std.testing.expectEqual(@as(usize, 1), usage_drain.drainWorker(harness.drain(), &worker));
    try std.testing.expectEqual(@as(u64, 0), page.pending());
    try std.testing.expectEqual(@as(u64, 0), harness.rejected());
    // A second record for the same request is the worker breaking the rules.
    try page.append(completedRecord(77));
    try std.testing.expectEqual(@as(usize, 0), usage_drain.drainWorker(harness.drain(), &worker));
    try std.testing.expectEqual(@as(u64, 1), harness.rejected());

    var lines = try harness.lines();
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqual(@as(u64, 78), lines.items[0].request_id);
}

test "a floor stays parked after its slot is released, so the dying worker's record for it is skipped without a count and frees it" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var page: Page = undefined;
    try page.init("usage-parked-floor");
    defer page.deinit();
    var worker = stackWorker(&page, 7, 3);
    try worker.requests.record(fixture.dispatchedRequest(90));

    usage_drain.settleRequest(harness.drain(), &worker, 90, .{ .floor = .{ .status = .crash } }, ended_ns);
    try std.testing.expect(worker.requests.dispatchedFor(90) != null);
    try std.testing.expectEqual(@as(usize, 1), worker.requests.parked_count);

    try page.append(completedRecord(90));
    try std.testing.expectEqual(@as(usize, 0), usage_drain.drainWorker(harness.drain(), &worker));
    try std.testing.expectEqual(@as(u64, 0), page.pending());
    try std.testing.expectEqual(@as(u64, 0), harness.rejected());
    try std.testing.expect(worker.requests.dispatchedFor(90) == null);
    try std.testing.expectEqual(@as(usize, 0), worker.requests.parked_count);

    var lines = try harness.lines();
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqualStrings("server", lines.items[0].origin);
}

test "a floor is written and the worker's later record for its request is skipped, with an allocator that fails every allocation" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var page: Page = undefined;
    try page.init("usage-floor-no-allocation");
    defer page.deinit();
    var worker = stackWorker(&page, 9, 2);

    // From here on every allocation the supervisor's usage path could make
    // fails: writing a floor needs none.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    harness.supervisor.allocator = failing.allocator();
    harness.log().allocator = failing.allocator();
    defer harness.supervisor.allocator = std.testing.allocator;
    defer harness.log().allocator = std.testing.allocator;

    try worker.requests.record(fixture.dispatchedRequest(810));
    usage_drain.settleRequest(harness.drain(), &worker, 810, .{ .floor = .{ .status = .crash } }, ended_ns);
    try page.append(completedRecord(810));
    try std.testing.expectEqual(@as(usize, 0), usage_drain.drainWorker(harness.drain(), &worker));
    try std.testing.expectEqual(@as(u64, 0), harness.rejected());
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);

    var lines = try harness.lines();
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqualStrings("server", lines.items[0].origin);
    try std.testing.expectEqual(@as(u64, 810), lines.items[0].request_id);
}

test "synthesis writes nothing for a request whose worker record a drain already wrote" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var page: Page = undefined;
    try page.init("usage-drain-before-synthesis");
    defer page.deinit();
    var worker = stackWorker(&page, 9, 2);

    const identity = worker_shared_page.LifecycleIdentity{
        .external_request_id = 600,
        .request_lane_id = 1,
        .request_slot = 2,
        .request_generation = 5,
        .worker_id = 9,
        .worker_generation = 2,
    };
    try worker.requests.record(dispatchedAs(identity));
    try page.append(completedRecordFor(identity));
    endRequest(&worker, identity.external_request_id);

    // The periodic drain gets there first and empties the ring; then the
    // worker dies and the lane asks for a floor for the same request. Nothing
    // is left in the ring for the claim to find, so only the request table
    // can say the worker's record was already written.
    try std.testing.expectEqual(@as(usize, 1), usage_drain.drainWorker(harness.drain(), &worker));
    try std.testing.expect(worker.requests.usageRecorded(identity.external_request_id));
    try std.testing.expectEqual(
        usage_drain.SynthesisOutcome.settled,
        usage_drain.synthesizeFinalAccountingForLifecycle(harness.drain(), &worker, identity.external_request_id, .{ .status = .crash }, ended_ns),
    );

    var lines = try harness.lines();
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqualStrings("worker", lines.items[0].origin);
    try std.testing.expectEqualStrings("done", lines.items[0].error_code);
}

test "a claim's own drain writes the record a worker appended for a request the server just ended, and no floor follows" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var page: Page = undefined;
    try page.init("usage-claim-drains");
    defer page.deinit();
    var worker = stackWorker(&page, 9, 2);

    const identity = worker_shared_page.LifecycleIdentity{
        .external_request_id = 610,
        .request_lane_id = 1,
        .request_slot = 2,
        .request_generation = 5,
        .worker_id = 9,
        .worker_generation = 2,
    };
    try worker.requests.record(dispatchedAs(identity));
    try page.append(completedRecordFor(identity));

    try std.testing.expectEqual(
        usage_drain.SynthesisOutcome.settled,
        usage_drain.synthesizeFinalAccountingForLifecycle(harness.drain(), &worker, identity.external_request_id, .{ .status = .crash }, ended_ns),
    );
    try std.testing.expect(worker.requests.usageRecorded(identity.external_request_id));
    var lines = try harness.lines();
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqualStrings("worker", lines.items[0].origin);
    try std.testing.expectEqual(ended_ns - 1, lines.items[0].wall_ns);
}

test "a worker's record for another worker's request is refused, and the victim keeps its floor" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var victim_page: Page = undefined;
    try victim_page.init("usage-mark-victim");
    defer victim_page.deinit();
    var victim = stackWorker(&victim_page, 9, 2);
    var hostile_page: Page = undefined;
    try hostile_page.init("usage-mark-hostile");
    defer hostile_page.deinit();
    var hostile = stackWorker(&hostile_page, 11, 1);

    const identity = worker_shared_page.LifecycleIdentity{
        .external_request_id = 700,
        .request_lane_id = 1,
        .request_slot = 2,
        .request_generation = 5,
        .worker_id = 9,
        .worker_generation = 2,
    };
    try victim.requests.record(dispatchedAs(identity));
    // The hostile worker writes a record that copies the victim's request in
    // every field it controls.
    try hostile_page.append(completedRecordFor(identity));

    // The hostile worker's table holds no such request, so its record is
    // refused and marks nothing on the victim's table.
    try std.testing.expectEqual(@as(usize, 0), usage_drain.drainWorker(harness.drain(), &hostile));
    try std.testing.expectEqual(@as(u64, 0), hostile_page.pending());
    try std.testing.expectEqual(@as(u64, 1), harness.rejected());
    try std.testing.expect(!victim.requests.usageRecorded(identity.external_request_id));
    try std.testing.expectEqual(
        usage_drain.SynthesisOutcome.settled,
        usage_drain.synthesizeFinalAccountingForLifecycle(harness.drain(), &victim, identity.external_request_id, .{ .status = .crash }, ended_ns),
    );

    var lines = try harness.lines();
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqual(@as(u64, 9), lines.items[0].worker_id);
    try std.testing.expectEqualStrings("server", lines.items[0].origin);
    try std.testing.expectEqualStrings("crash", lines.items[0].error_code);
}

test "a worker record that arrives while its request's floor is written waits, and is kept when the floor is dropped" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var page: Page = undefined;
    try page.init("usage-during-synthesis");
    defer page.deinit();
    var worker = stackWorker(&page, 9, 2);

    const identity = worker_shared_page.LifecycleIdentity{
        .external_request_id = 750,
        .request_lane_id = 1,
        .request_slot = 2,
        .request_generation = 5,
        .worker_id = 9,
        .worker_generation = 2,
    };
    try worker.requests.record(dispatchedAs(identity));
    endRequest(&worker, identity.external_request_id);
    const claim = usage_drain.claimSynthesisForLifecycle(harness.drain(), &worker, identity);
    try std.testing.expect(!claim.worker_authored);

    // The request table holds the record back whatever request key it
    // carries: the request id alone names it.
    var late = completedRecord(identity.external_request_id);
    late.request_generation = identity.request_generation + 1;
    try page.append(late);
    try std.testing.expectEqual(@as(usize, 0), usage_drain.drainWorker(harness.drain(), &worker));
    try std.testing.expectEqual(@as(u64, 1), page.pending());
    try std.testing.expectEqual(@as(u64, 0), harness.rejected());

    // Had the floor been lost, the worker's record is the one to keep.
    worker.requests.finishSynthesis(identity.external_request_id, false);
    try std.testing.expectEqual(@as(usize, 1), usage_drain.drainWorker(harness.drain(), &worker));
    try std.testing.expect(worker.requests.usageRecorded(identity.external_request_id));

    var lines = try harness.lines();
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqualStrings("worker", lines.items[0].origin);
    try std.testing.expectEqual(identity.external_request_id, lines.items[0].request_id);
}

test "a floor carries its dispatch's flags and runs from the dispatch to the lane's end, and its settle parks the request's entry" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var page: Page = undefined;
    try page.init("usage-floor-dispatch");
    defer page.deinit();
    var worker = stackWorker(&page, 9, 2);

    // A cold start's request, which the server dispatched and ended 3 ms
    // later with no completion from the worker.
    var dispatched = fixture.dispatchedRequest(800);
    dispatched.accounting_flags = worker_shared_page.AccountingFlags.cold_start;
    dispatched.started_mono_ns = 1_000_000;
    try worker.requests.record(dispatched);
    usage_drain.settleRequest(harness.drain(), &worker, 800, .{ .floor = .{ .status = .deadline } }, 4_000_000);
    // Parked, for the record a dying worker may still have written.
    try std.testing.expect(worker.requests.dispatchedFor(800) != null);
    try std.testing.expect(worker.requests.verdict(800) == .skip);

    var lines = try harness.lines();
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    const line = lines.items[0];
    try std.testing.expectEqualStrings("server", line.origin);
    try std.testing.expectEqual(@as(u64, 800), line.request_id);
    try std.testing.expectEqualStrings("deadline", line.error_code);
    try std.testing.expect(line.cold_start);
    try std.testing.expectEqual(3 * std.time.ns_per_ms, line.wall_ns);
    try std.testing.expectEqual(@as(u64, 0), line.cpu_ns);
    try std.testing.expectEqual(@as(u64, 0), line.exec_ns);
}

test "a floor names the worker fault that ended its request, and a record the worker wrote names none" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var page: Page = undefined;
    try page.init("usage-floor-fault");
    defer page.deinit();
    var worker = stackWorker(&page, 9, 2);

    // One request the worker answered with its own record, and one the
    // server ended when the worker's process exited.
    try worker.requests.record(fixture.dispatchedRequest(820));
    try page.append(completedRecord(820));
    endRequest(&worker, 820);
    try std.testing.expectEqual(@as(usize, 1), usage_drain.drainWorker(harness.drain(), &worker));
    try worker.requests.record(fixture.dispatchedRequest(821));
    usage_drain.settleRequest(harness.drain(), &worker, 821, .{ .floor = .{
        .status = .crash,
        .worker_fault = "exited",
    } }, ended_ns);

    var lines = try harness.lines();
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, 2), lines.items.len);
    try std.testing.expectEqual(@as(u64, 820), lines.items[0].request_id);
    try std.testing.expectEqualStrings("worker", lines.items[0].origin);
    try std.testing.expectEqualStrings("", lines.items[0].worker_fault);
    try std.testing.expectEqual(@as(u64, 821), lines.items[1].request_id);
    try std.testing.expectEqualStrings("server", lines.items[1].origin);
    try std.testing.expectEqualStrings("crash", lines.items[1].error_code);
    try std.testing.expectEqualStrings("exited", lines.items[1].worker_fault);
}

test "a floor starts at its dispatch and takes the CPU its request's live slot measured, and a slot in a state the enum does not name gives none" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var page: Page = undefined;
    try page.init("usage-floor-live-slot");
    defer page.deinit();
    var worker = stackWorker(&page, 9, 2);

    const measured = worker_shared_page.LifecycleIdentity{
        .external_request_id = 830,
        .request_lane_id = 0,
        .request_slot = 3,
        .request_generation = 1,
        .worker_id = 9,
        .worker_generation = 2,
    };
    var unreadable = measured;
    unreadable.external_request_id = 831;
    unreadable.request_slot = 4;

    // The worker claimed a live slot for each request and flushed CPU into
    // both, then wrote a state no claim stores into the second.
    for ([_]worker_shared_page.LifecycleIdentity{ measured, unreadable }) |identity|
        try worker.requests.record(dispatchedAs(identity));
    var state = worker_metrics_state.WorkState.init(&page.view);
    const measured_slot = try state.allocateLiveSlot(measured);
    try state.updateLiveSlotCpu(measured_slot, 40);
    const unreadable_slot = try state.allocateLiveSlot(unreadable);
    try state.updateLiveSlotCpu(unreadable_slot, 50);
    @atomicStore(u32, &page.view.live_slots[unreadable_slot.index].state, 2, .release);

    usage_drain.settleRequest(harness.drain(), &worker, 830, .{ .floor = .{ .status = .crash } }, ended_ns);
    usage_drain.settleRequest(harness.drain(), &worker, 831, .{ .floor = .{ .status = .crash } }, ended_ns);

    var lines = try harness.lines();
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, 2), lines.items.len);
    const from_slot = lines.items[0];
    try std.testing.expectEqual(@as(u64, 830), from_slot.request_id);
    try std.testing.expectEqualStrings("server", from_slot.origin);
    try std.testing.expectEqual(@as(u64, 40), from_slot.cpu_ns);
    try std.testing.expectEqual(ended_ns - 1, from_slot.wall_ns);
    const from_dispatch = lines.items[1];
    try std.testing.expectEqual(@as(u64, 831), from_dispatch.request_id);
    try std.testing.expectEqualStrings("server", from_dispatch.origin);
    try std.testing.expectEqual(@as(u64, 0), from_dispatch.cpu_ns);
    try std.testing.expectEqual(ended_ns - 1, from_dispatch.wall_ns);
}

test "a floor takes the larger of its live slot's CPU and the window its sentinel saw running, and only for the request that window names" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var page: Page = undefined;
    try page.init("usage-floor-running-owner");
    defer page.deinit();
    var worker = stackWorker(&page, 9, 2);

    const running = worker_shared_page.LifecycleIdentity{
        .external_request_id = 832,
        .request_lane_id = 0,
        .request_slot = 3,
        .request_generation = 1,
        .worker_id = 9,
        .worker_generation = 2,
    };
    var other = running;
    other.external_request_id = 833;
    other.request_slot = 4;
    for ([_]worker_shared_page.LifecycleIdentity{ running, other }) |identity|
        try worker.requests.record(dispatchedAs(identity));
    // Both live slots last flushed 10 ms; the sentinel saw request 832 at
    // 40 ms when the worker died in its window.
    var state = worker_metrics_state.WorkState.init(&page.view);
    for ([_]worker_shared_page.LifecycleIdentity{ running, other }) |identity| {
        const slot = try state.allocateLiveSlot(identity);
        try state.updateLiveSlotCpu(slot, 10 * std.time.ns_per_ms);
    }
    page.view.publishRunningOwnerCpu(running.external_request_id, 40 * std.time.ns_per_ms);

    usage_drain.settleRequest(harness.drain(), &worker, 832, .{ .floor = .{ .status = .crash } }, ended_ns);
    usage_drain.settleRequest(harness.drain(), &worker, 833, .{ .floor = .{ .status = .crash } }, ended_ns);

    var lines = try harness.lines();
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, 2), lines.items.len);
    try std.testing.expectEqual(@as(u64, 832), lines.items[0].request_id);
    try std.testing.expectEqual(40 * std.time.ns_per_ms, lines.items[0].cpu_ns);
    try std.testing.expectEqual(@as(u64, 833), lines.items[1].request_id);
    try std.testing.expectEqual(10 * std.time.ns_per_ms, lines.items[1].cpu_ns);
}

test "a completed request keeps its entry for the worker's record, and an abandoned one frees it and refuses that record" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var page: Page = undefined;
    try page.init("usage-settle-awaits");
    defer page.deinit();
    var worker = stackWorker(&page, 7, 3);

    // The worker appends the record before it publishes the completion, and
    // the lane settles the request when it reads that completion; the
    // periodic drain comes later.
    try worker.requests.record(fixture.dispatchedRequest(30));
    try page.append(completedRecord(30));
    usage_drain.settleRequest(harness.drain(), &worker, 30, .completed, ended_ns);
    try std.testing.expect(worker.requests.dispatchedFor(30) != null);
    try std.testing.expectEqual(@as(u64, 1), page.pending());

    try std.testing.expectEqual(@as(usize, 1), usage_drain.drainWorker(harness.drain(), &worker));
    try std.testing.expect(worker.requests.dispatchedFor(30) == null);

    // A dispatch whose request never reached the worker gets no record: its
    // entry goes, and a record the worker writes for it anyway is refused.
    try worker.requests.record(fixture.dispatchedRequest(31));
    usage_drain.settleRequest(harness.drain(), &worker, 31, .abandoned, ended_ns);
    try std.testing.expect(worker.requests.dispatchedFor(31) == null);
    try page.append(completedRecord(31));
    try std.testing.expectEqual(@as(usize, 0), usage_drain.drainWorker(harness.drain(), &worker));
    try std.testing.expectEqual(@as(u64, 1), harness.rejected());

    var lines = try harness.lines();
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqual(@as(u64, 30), lines.items[0].request_id);
}

test "settling past the parked bound drains the worker first, so no honest record is lost" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var page: Page = undefined;
    try page.init("usage-settle-drains");
    defer page.deinit();
    var worker = stackWorker(&page, 7, 3);

    const total: u64 = request_table.parked_max + 1;
    var request_id: u64 = 1;
    while (request_id <= total) : (request_id += 1) {
        try worker.requests.record(fixture.dispatchedRequest(request_id));
        try page.append(completedRecord(request_id));
        usage_drain.settleRequest(harness.drain(), &worker, request_id, .completed, ended_ns);
    }
    // The last settle found the table full and drained the ring itself.
    try std.testing.expectEqual(@as(u64, 0), page.pending());
    try std.testing.expectEqual(@as(u64, 0), harness.rejected());

    var lines = try harness.lines();
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, total), lines.items.len);
}

test "an entry whose record never arrives is evicted once the table is full, and its late record refused" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var page: Page = undefined;
    try page.init("usage-settle-evicts");
    defer page.deinit();
    var worker = stackWorker(&page, 7, 3);

    // Completions published without records fill the table.
    var request_id: u64 = 1;
    while (request_id <= request_table.parked_max + 1) : (request_id += 1) {
        try worker.requests.record(fixture.dispatchedRequest(request_id));
        usage_drain.settleRequest(harness.drain(), &worker, request_id, .completed, ended_ns);
    }
    // The oldest waiting entry made room for the newest.
    try std.testing.expect(worker.requests.dispatchedFor(1) == null);
    try std.testing.expect(worker.requests.dispatchedFor(request_table.parked_max + 1) != null);

    try page.append(completedRecord(1));
    try std.testing.expectEqual(@as(usize, 0), usage_drain.drainWorker(harness.drain(), &worker));
    try std.testing.expectEqual(@as(u64, 1), harness.rejected());
}

test "settling past the bound with the usage stream full drops and counts the waiting records and evicts none" {
    // The sink logs the start of the full usage stream once, at `err`.
    @import("root").expect_log_errors = 1;
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var page: Page = undefined;
    try page.init("usage-settle-stream-full");
    defer page.deinit();
    var worker = stackWorker(&page, 7, 3);
    try fixture.fillStream(std.testing.allocator, harness.sink(), .usage, usage_log.synthesis_reserve_bytes);

    // The last settle finds the table full and drains the worker. The stream
    // drops the batch, and that settles every request in it, so the table
    // has room again without evicting anyone and nothing is left waiting.
    const total: u64 = request_table.parked_max + 1;
    var request_id: u64 = 1;
    while (request_id <= total) : (request_id += 1) {
        try worker.requests.record(fixture.dispatchedRequest(request_id));
        try page.append(completedRecord(request_id));
        usage_drain.settleRequest(harness.drain(), &worker, request_id, .completed, ended_ns);
    }
    try std.testing.expectEqual(@as(u64, 0), page.pending());
    try std.testing.expectEqual(total, harness.sink().stats(.usage).dropped);
    try std.testing.expect(worker.requests.dispatchedFor(1) == null);
    try std.testing.expect(worker.requests.dispatchedFor(total) == null);

    // Each request had its one record, so a second one is refused.
    try page.append(completedRecord(1));
    try std.testing.expectEqual(@as(usize, 0), usage_drain.drainWorker(harness.drain(), &worker));
    try std.testing.expectEqual(@as(u64, 1), harness.rejected());
}

test "a worker record a full usage stream drops at a death settles its request, and no floor is written over it" {
    // The sink logs the start of the full usage stream once, at `err`.
    @import("root").expect_log_errors = 1;
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var page: Page = undefined;
    try page.init("usage-death-stream-full");
    defer page.deinit();
    var worker = stackWorker(&page, 9, 2);

    const identity = worker_shared_page.LifecycleIdentity{
        .external_request_id = 900,
        .request_lane_id = 1,
        .request_slot = 2,
        .request_generation = 5,
        .worker_id = 9,
        .worker_generation = 2,
    };
    try worker.requests.record(dispatchedAs(identity));
    try page.append(completedRecordFor(identity));

    // The worker appended its record and died before it published the
    // completion, while the usage stream had room only for floors: the claim
    // finds the record, so no floor is written, and the drain after it drops
    // the record and settles the request.
    try fixture.fillStream(std.testing.allocator, harness.sink(), .usage, usage_log.synthesis_reserve_bytes);
    usage_drain.settleRequest(harness.drain(), &worker, identity.external_request_id, .{ .floor = .{ .status = .crash } }, ended_ns);
    try std.testing.expectEqual(@as(u64, 0), page.pending());
    try std.testing.expectEqual(@as(u64, 1), harness.sink().stats(.usage).dropped);
    try std.testing.expect(worker.requests.dispatchedFor(identity.external_request_id) == null);
    try std.testing.expectEqual(@as(u64, 0), harness.rejected());

    var lines = try harness.lines();
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, 0), lines.items.len);
}

test "a drain counts both the records it refused and the batch a full usage stream dropped" {
    // The sink logs the start of the full usage stream once, at `err`.
    @import("root").expect_log_errors = 1;
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var page: Page = undefined;
    try page.init("usage-rejected-then-full");
    defer page.deinit();
    var worker = stackWorker(&page, 7, 3);
    try worker.requests.record(fixture.dispatchedRequest(1000));
    endRequest(&worker, 1000);

    // A first batch of records for requests the worker was never dispatched,
    // which the ring advances past without the stream, then the record of
    // one it was, which needs the stream.
    var request_id: u64 = 1;
    while (request_id <= usage_log.batch_records_max) : (request_id += 1)
        try page.append(completedRecord(request_id));
    try page.append(completedRecord(1000));
    try fixture.fillStream(std.testing.allocator, harness.sink(), .usage, usage_log.synthesis_reserve_bytes);

    try std.testing.expectEqual(@as(usize, 0), usage_drain.drainWorker(harness.drain(), &worker));
    try std.testing.expectEqual(@as(u64, usage_log.batch_records_max), harness.rejected());
    try std.testing.expectEqual(@as(u64, 1), harness.sink().stats(.usage).dropped);
    try std.testing.expectEqual(@as(u64, 0), page.pending());
    try std.testing.expect(worker.requests.usageRecorded(1000));
}

test "a worker's request table moves an entry through its end, synthesis and settling" {
    var table = request_table.RequestTable{};
    try table.record(fixture.dispatchedRequest(1));
    try std.testing.expect(table.verdict(2) == .refuse);
    // A record waits until the lane ends the request, then is written with
    // the dispatch and that end.
    try std.testing.expect(table.verdict(1) == .wait);
    table.noteEnded(1, 9);
    switch (table.verdict(1)) {
        .write => |ended| {
            try std.testing.expectEqual(@as(u64, 1), ended.dispatched.request_id);
            try std.testing.expectEqual(@as(u64, 9), ended.ended_mono_ns);
        },
        .wait, .skip, .refuse => return error.TestExpectedWrite,
    }
    // A second end changes nothing.
    table.noteEnded(1, 11);
    try std.testing.expectEqual(@as(u64, 9), table.verdict(1).write.ended_mono_ns);

    // While the floor is written, worker records wait; a lost floor lets
    // them in again, and a written one settles the request, after which the
    // worker's record is skipped once and any other refused.
    table.beginSynthesis(1);
    try std.testing.expect(table.verdict(1) == .wait);
    table.finishSynthesis(1, false);
    try std.testing.expect(table.verdict(1) == .write);
    table.beginSynthesis(1);
    table.finishSynthesis(1, true);
    try std.testing.expect(table.usageRecorded(1));
    try std.testing.expect(table.verdict(1) == .skip);
    table.skipFloors(&.{1});
    try std.testing.expect(table.verdict(1) == .refuse);
    try std.testing.expectEqual(request_table.Settled.freed, table.settle(1, false));

    // A completed request waits for its record, and the mark that settles
    // it, written or dropped, frees the entry.
    try table.record(fixture.dispatchedRequest(2));
    table.noteEnded(2, 9);
    try std.testing.expectEqual(request_table.Settled.parked, table.settle(2, true));
    try std.testing.expect(table.verdict(2) == .write);
    table.markUsageRecorded(&.{2});
    try std.testing.expect(table.dispatchedFor(2) == null);

    // An abandoned dispatch frees its entry whatever it waited for.
    try table.record(fixture.dispatchedRequest(3));
    _ = table.settle(3, true);
    table.remove(3);
    try std.testing.expect(table.verdict(3) == .refuse);
}

test "a request table names the route of a request it holds or that left it recently, and of no other" {
    var table = request_table.RequestTable{};
    var routed = fixture.dispatchedRequest(5);
    routed.route = 3;
    try table.record(routed);
    try std.testing.expectEqual(@as(?config.RouteIndex, 3), table.routeOfRecent(5));
    try std.testing.expectEqual(@as(?config.RouteIndex, null), table.routeOfRecent(0));
    try std.testing.expectEqual(@as(?config.RouteIndex, null), table.routeOfRecent(6));

    // Every way out but `remove` leaves the route behind.
    try std.testing.expectEqual(request_table.Settled.freed, table.settle(5, false));
    try std.testing.expectEqual(@as(?config.RouteIndex, 3), table.routeOfRecent(5));
    try table.record(fixture.dispatchedRequest(7));
    table.remove(7);
    try std.testing.expectEqual(@as(?config.RouteIndex, null), table.routeOfRecent(7));

    // The ring keeps the last `ended_requests_max` requests.
    var request_id: u64 = 100;
    while (request_id < 100 + request_table.ended_requests_max) : (request_id += 1) {
        try table.record(fixture.dispatchedRequest(request_id));
        _ = table.settle(request_id, false);
    }
    try std.testing.expectEqual(@as(?config.RouteIndex, null), table.routeOfRecent(5));
    try std.testing.expectEqual(@as(?config.RouteIndex, 0), table.routeOfRecent(100));
    try std.testing.expectEqual(@as(?config.RouteIndex, 0), table.routeOfRecent(99 + request_table.ended_requests_max));
}

test "a kept floor gives way first when a completed request needs room to wait for its record" {
    var table = request_table.RequestTable{};
    // Every parked place taken by floors the server wrote.
    var request_id: u64 = 1;
    while (request_id <= request_table.parked_max) : (request_id += 1) {
        try table.record(fixture.dispatchedRequest(request_id));
        table.noteEnded(request_id, 9);
        table.beginSynthesis(request_id);
        table.finishSynthesis(request_id, true);
        try std.testing.expectEqual(request_table.Settled.parked, table.settle(request_id, false));
    }
    try std.testing.expectEqual(request_table.parked_max, table.parked_count);

    // A completed request takes the place of the oldest floor, which only
    // loses its silent skip.
    try table.record(fixture.dispatchedRequest(500));
    table.noteEnded(500, 9);
    try std.testing.expectEqual(request_table.Settled.parked, table.settle(500, true));
    try std.testing.expect(table.verdict(1) == .refuse);
    try std.testing.expect(table.verdict(2) == .skip);
    try std.testing.expect(table.verdict(500) == .write);
    try std.testing.expectEqual(request_table.parked_max, table.parked_count);
}

test "lifecycle search reaches records past the first peeked batch" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var page: Page = undefined;
    try page.init("usage-deep-scan");
    defer page.deinit();

    // A record at the head that must wait, its request not ended, stops
    // consumption at position 0, so the target far behind it is only
    // reachable by a search that keeps looking.
    var blocker = completedRecord(1);
    blocker.request_generation = 1;
    try page.append(blocker);

    const target_slot: u32 = 300;
    var index: u32 = 1;
    while (index <= target_slot) : (index += 1) {
        var filler = completedRecord(index + 1);
        filler.request_generation = 1;
        filler.request_slot = index;
        try page.append(filler);
    }
    var worker = stackWorker(&page, 7, 3);
    try worker.requests.record(fixture.dispatchedRequest(1));

    const identity = worker_shared_page.LifecycleIdentity{
        .external_request_id = target_slot + 1,
        .request_lane_id = 0,
        .request_slot = target_slot,
        .request_generation = 1,
        .worker_id = 7,
        .worker_generation = 3,
    };
    try worker.requests.record(dispatchedAs(identity));
    // A false here makes the server write a floor that then suppresses this
    // very record, the one carrying measured CPU.
    const claim = usage_drain.claimSynthesisForLifecycle(harness.drain(), &worker, identity);
    try std.testing.expect(claim.worker_authored);
    try std.testing.expect(claim.deep_scanned);
}

/// Builds a ring of `total + 1` records for worker 7/generation 3, makes the
/// one at `blocker_slot` wait (its request is in the table and not ended),
/// and asks whether the worker authored the record at `target_slot`.
///
/// The blocker's position is the whole point. With it at slot 0 the consume
/// pass advances nothing, which is the single point in the space where a
/// deep-scan offset counted twice still lands on the right record, so a test
/// that only covers that case cannot see the defect it exists to catch. Only
/// the target is in the worker's request table: the records before the
/// blocker name no request of it, so the drain refuses them and still
/// advances past them, which is the advance that matters here.
fn workerAuthoredAcrossBlocker(blocker_slot: u32, target_slot: u32, total: u32) !bool {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var page: Page = undefined;
    try page.init("usage-deep-scan-offset");
    defer page.deinit();

    var index: u32 = 0;
    while (index <= total) : (index += 1) {
        var record = completedRecord(index + 1);
        record.request_generation = 1;
        record.request_slot = index;
        try page.append(record);
    }
    var worker = stackWorker(&page, 7, 3);
    try worker.requests.record(fixture.dispatchedRequest(blocker_slot + 1));

    const identity = worker_shared_page.LifecycleIdentity{
        .external_request_id = target_slot + 1,
        .request_lane_id = 0,
        .request_slot = target_slot,
        .request_generation = 1,
        .worker_id = 7,
        .worker_generation = 3,
    };
    try worker.requests.record(dispatchedAs(identity));
    const claim = usage_drain.claimSynthesisForLifecycle(harness.drain(), &worker, identity);
    return claim.worker_authored;
}

test "lifecycle search covers the gap a partly consumed batch leaves" {
    // A drain peeks `usage_log.batch_records_max` (128) records at a time.
    // Blocker at 100: inside the first batch and past its middle, so the pass
    // consumes 100 records and the ring tail moves 100 forward. Target at 150
    // sits in the gap between what that batch examined (0..127) and where a
    // doubly-counted offset would resume the scan (200).
    try std.testing.expect(try workerAuthoredAcrossBlocker(100, 150, 200));
}

test "lifecycle search survives a blocker in a later batch" {
    // The first batch of `usage_log.batch_records_max` (128) records is
    // consumed cleanly; the blocker at 178 stops the second. The tail has now
    // moved 178, so a doubly-counted offset resumes at 356 while the records
    // examined stop at 255; target 300 falls in that gap, and the error
    // compounds with every batch already consumed.
    try std.testing.expect(try workerAuthoredAcrossBlocker(178, 300, 400));
}

//! The usage path from a worker's usage record ring into `usage.jsonl`: what
//! a drain writes, whose identity it puts on each record and which rings it
//! leaves alone (an unmapped page, a head moved behind the server's tail),
//! the route pattern every record carries, which worker records the request
//! table lets through and which it refuses, how an ended request settles in
//! that table and what its floor carries, the live slot's start and CPU
//! included, the record format and its bound, what a full usage stream
//! drops, counts and settles, at a settle and at a death too, and the
//! exactly-once rules between a drain and synthesis, including a floor the
//! index cannot grow for.
//! Supervisor-level lifecycles that end in these drains, and a full usage
//! stream seen from the supervisor, are covered in `supervisor.zig` and
//! `reaper/retirement.zig`; the sink's own buffering, writes and files in
//! `server/tests/analytics/sink.zig`. Lane `server-supervisor-test`.

const std = @import("std");
const process = @import("collo_os").process;
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
const usage_key = supervision.accounting.usage;
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
        self.view.initializeCrashDefault(1, 0, 0);
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
        .started_mono_ns = 1,
        .finished_mono_ns = 2,
        .cpu_time_ns = 3,
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

test "a drain stamps the server's identity on the record, never the one the worker wrote" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var page: Page = undefined;
    try page.init("usage-identity-stamp");
    defer page.deinit();
    var worker = stackWorker(&page, 7, 3);
    try worker.requests.record(fixture.dispatchedRequest(42));

    // The worker claims to be another worker.
    var record = completedRecord(42);
    record.worker_id = 99;
    record.worker_generation = 99;
    record.client_served_bytes = 100;
    record.fetch_billed_sent_bytes = 20;
    record.fetch_billed_received_bytes = 3;
    record.fetch_cost_bytes = 77;
    record.io_time_ns = 9;
    record.waiting_ns = 4;
    record.finished_mono_ns = 11;
    record.flags = worker_shared_page.CompletedRecordFlags.cold_start;
    try page.append(record);

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
    try std.testing.expect(line.cold_start);
    try std.testing.expectEqual(@as(u64, 10), line.wall_time_ns);
    try std.testing.expectEqual(@as(u64, 3), line.cpu_time_ns);
    try std.testing.expectEqual(@as(u64, 9), line.io_time_ns);
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
    try std.testing.expectEqual(@as(usize, 1), usage_drain.drainWorker(harness.drain(), &worker));
    try worker.requests.record(fixture.dispatchedRequest(11));
    usage_drain.settleRequest(harness.drain(), &worker, 11, .{ .floor = .{ .status = .crash } });

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
    const record = analytics.usage.fromCompleted(identity, .worker, completedRecord(1), clock);

    // Room for floors only: a batch must leave the synthesis reserve free.
    try fixture.fillUsageStream(std.testing.allocator, harness.sink(), usage_log.synthesis_reserve_bytes);
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
        .wall_time_ns = std.math.maxInt(u64),
        .cpu_time_ns = std.math.maxInt(u64),
        .io_time_ns = std.math.maxInt(u64),
        .waiting_ns = std.math.maxInt(u64),
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
    } });
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

test "a drain waits behind a reserved synthesis and skips a written one" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var page: Page = undefined;
    try page.init("usage-reserved-synthesis");
    defer page.deinit();
    var worker = stackWorker(&page, 7, 3);
    try worker.requests.record(fixture.dispatchedRequest(77));

    var record = completedRecord(77);
    record.request_generation = 5;
    record.request_slot = 6;
    record.request_lane_id = 2;
    try page.append(record);

    const key = usage_key.keyFromRecord(record, .{ .worker_id = 7, .worker_generation = 3 });
    try harness.log().synthesized.put(std.testing.allocator, key, .reserved);
    try std.testing.expectEqual(@as(usize, 0), usage_drain.drainWorker(harness.drain(), &worker));
    try std.testing.expectEqual(@as(u64, 1), page.pending());

    try harness.log().synthesized.put(std.testing.allocator, key, .written);
    try std.testing.expectEqual(@as(usize, 0), usage_drain.drainWorker(harness.drain(), &worker));
    try std.testing.expectEqual(@as(u64, 0), page.pending());
    try std.testing.expect(!harness.log().synthesized.contains(key));
    // A record for an attempt whose floor the server already wrote is
    // skipped, not refused.
    try std.testing.expectEqual(@as(u64, 0), harness.rejected());

    var lines = try harness.lines();
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, 0), lines.items.len);
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

    // The periodic drain gets there first and empties the ring; then the
    // worker dies and the lane asks for a floor for the same request. Nothing
    // is left in the ring for the claim to find, so only the request table
    // can say the worker's record was already written.
    try std.testing.expectEqual(@as(usize, 1), usage_drain.drainWorker(harness.drain(), &worker));
    try std.testing.expect(worker.requests.usageRecorded(identity.external_request_id));
    try std.testing.expectEqual(
        usage_drain.SynthesisOutcome.settled,
        try usage_drain.synthesizeFinalAccountingForLifecycle(harness.drain(), &worker, identity.external_request_id, .{ .status = .crash }),
    );

    var lines = try harness.lines();
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqualStrings("worker", lines.items[0].origin);
    try std.testing.expectEqualStrings("done", lines.items[0].error_code);
    try std.testing.expectEqual(@as(usize, 0), harness.log().synthesized.count());
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
    var forged = completedRecordFor(identity);
    forged.worker_id = identity.worker_id;
    forged.worker_generation = identity.worker_generation;
    try hostile_page.append(forged);

    // The hostile worker's table holds no such request, so its record is
    // refused and marks nothing on the victim's table.
    try std.testing.expectEqual(@as(usize, 0), usage_drain.drainWorker(harness.drain(), &hostile));
    try std.testing.expectEqual(@as(u64, 0), hostile_page.pending());
    try std.testing.expectEqual(@as(u64, 1), harness.rejected());
    try std.testing.expect(!victim.requests.usageRecorded(identity.external_request_id));
    try std.testing.expectEqual(
        usage_drain.SynthesisOutcome.settled,
        try usage_drain.synthesizeFinalAccountingForLifecycle(harness.drain(), &victim, identity.external_request_id, .{ .status = .crash }),
    );

    var lines = try harness.lines();
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqual(@as(u64, 9), lines.items[0].worker_id);
    try std.testing.expectEqualStrings("server", lines.items[0].origin);
    try std.testing.expectEqualStrings("crash", lines.items[0].error_code);
}

test "a worker record that arrives while its request's floor is written is refused" {
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
    const claim = try usage_drain.claimSynthesisForLifecycle(harness.drain(), &worker, identity);
    try std.testing.expect(claim.reservation.active);
    try std.testing.expect(!claim.worker_authored);

    // A record with a request key of its own choosing misses the synthesis
    // index, so only the request table stands between it and a second record
    // for the request.
    var late = completedRecord(identity.external_request_id);
    late.request_generation = identity.request_generation + 1;
    try page.append(late);
    try std.testing.expectEqual(@as(usize, 0), usage_drain.drainWorker(harness.drain(), &worker));
    try std.testing.expectEqual(@as(u64, 1), harness.rejected());

    // Had the floor been lost, a worker record would be the one to keep. The
    // steps run in the order synthesis takes them for a dropped floor.
    worker.requests.finishSynthesis(identity.external_request_id, false);
    harness.log().rollbackSynthesis(claim.reservation);
    try page.append(late);
    try std.testing.expectEqual(@as(usize, 1), usage_drain.drainWorker(harness.drain(), &worker));
}

test "a dropped floor leaves synthesis before its reservation goes, so a drain between the two keeps the worker's record" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var page: Page = undefined;
    try page.init("usage-dropped-floor-order");
    defer page.deinit();
    var worker = stackWorker(&page, 9, 2);

    const identity = worker_shared_page.LifecycleIdentity{
        .external_request_id = 760,
        .request_lane_id = 1,
        .request_slot = 2,
        .request_generation = 5,
        .worker_id = 9,
        .worker_generation = 2,
    };
    try worker.requests.record(dispatchedAs(identity));
    const claim = try usage_drain.claimSynthesisForLifecycle(harness.drain(), &worker, identity);
    try std.testing.expect(claim.reservation.active);
    try std.testing.expect(!claim.worker_authored);

    // The worker's own record for the attempt shows up while the floor is
    // written, and the floor is then dropped
    // (`synthesizeFinalAccountingForLifecycle`). Its entry leaves
    // `synthesizing` first.
    try page.append(completedRecordFor(identity));
    worker.requests.finishSynthesis(identity.external_request_id, false);

    // A drain before the reservation goes stops at the reserved record: it
    // stays in the ring and is not refused. In the other order the drain
    // would refuse it as a record for a request whose floor is being
    // written, and the request would end with no record at all.
    try std.testing.expectEqual(@as(usize, 0), usage_drain.drainWorker(harness.drain(), &worker));
    try std.testing.expectEqual(@as(u64, 1), page.pending());
    try std.testing.expectEqual(@as(u64, 0), harness.rejected());

    // Once the reservation goes, the next drain writes the worker's record.
    harness.log().rollbackSynthesis(claim.reservation);
    try std.testing.expectEqual(@as(usize, 1), usage_drain.drainWorker(harness.drain(), &worker));
    try std.testing.expectEqual(@as(u64, 0), page.pending());
    try std.testing.expect(worker.requests.usageRecorded(identity.external_request_id));

    var lines = try harness.lines();
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqualStrings("worker", lines.items[0].origin);
    try std.testing.expectEqual(identity.external_request_id, lines.items[0].request_id);
}

test "a floor carries its dispatch's flags and start, and its settle frees the request's entry" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var page: Page = undefined;
    try page.init("usage-floor-dispatch");
    defer page.deinit();
    var worker = stackWorker(&page, 9, 2);

    // A cold start's request, dispatched a millisecond before this reading
    // and ended by the server with no completion from the worker.
    const dispatch_age_ns: u64 = std.time.ns_per_ms;
    const before_ns = process.monotonicNowNsOrZero();
    var dispatched = fixture.dispatchedRequest(800);
    dispatched.accounting_flags = worker_shared_page.CompletedRecordFlags.cold_start;
    dispatched.started_mono_ns = before_ns - dispatch_age_ns;
    try worker.requests.record(dispatched);
    usage_drain.settleRequest(harness.drain(), &worker, 800, .{ .floor = .{ .status = .deadline } });
    const after_ns = process.monotonicNowNsOrZero();
    try std.testing.expect(worker.requests.dispatchedFor(800) == null);

    var lines = try harness.lines();
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    const line = lines.items[0];
    try std.testing.expectEqualStrings("server", line.origin);
    try std.testing.expectEqual(@as(u64, 800), line.request_id);
    try std.testing.expectEqualStrings("deadline", line.error_code);
    try std.testing.expect(line.cold_start);
    // The wall time runs from the dispatch to the settle.
    try std.testing.expect(line.wall_time_ns >= dispatch_age_ns);
    try std.testing.expect(line.wall_time_ns <= dispatch_age_ns + (after_ns - before_ns));
    try std.testing.expectEqual(@as(u64, 0), line.cpu_time_ns);
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
    try std.testing.expectEqual(@as(usize, 1), usage_drain.drainWorker(harness.drain(), &worker));
    try worker.requests.record(fixture.dispatchedRequest(821));
    usage_drain.settleRequest(harness.drain(), &worker, 821, .{ .floor = .{
        .status = .crash,
        .worker_fault = "exited",
    } });

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

test "a floor takes the start and CPU its request's live slot measured, and a slot in a state the enum does not name gives none" {
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

    // The server dispatched both requests a millisecond before this reading;
    // the worker claimed a live slot for each a second before it and flushed
    // CPU into both, then wrote a state no claim stores into the second.
    const dispatch_age_ns: u64 = std.time.ns_per_ms;
    const slot_age_ns: u64 = std.time.ns_per_s;
    const before_ns = process.monotonicNowNsOrZero();
    for ([_]worker_shared_page.LifecycleIdentity{ measured, unreadable }) |identity| {
        var dispatched = dispatchedAs(identity);
        dispatched.started_mono_ns = before_ns - dispatch_age_ns;
        try worker.requests.record(dispatched);
    }
    var state = worker_metrics_state.WorkState.init(&page.view);
    const measured_slot = try state.allocateLiveSlot(measured, before_ns - slot_age_ns);
    try state.updateLiveSlotCpu(measured_slot, 40);
    const unreadable_slot = try state.allocateLiveSlot(unreadable, before_ns - slot_age_ns);
    try state.updateLiveSlotCpu(unreadable_slot, 50);
    @atomicStore(u32, &page.view.live_slots[unreadable_slot.index].state, 2, .release);

    usage_drain.settleRequest(harness.drain(), &worker, 830, .{ .floor = .{ .status = .crash } });
    usage_drain.settleRequest(harness.drain(), &worker, 831, .{ .floor = .{ .status = .crash } });
    const elapsed_ns = process.monotonicNowNsOrZero() - before_ns;

    var lines = try harness.lines();
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, 2), lines.items.len);
    const from_slot = lines.items[0];
    try std.testing.expectEqual(@as(u64, 830), from_slot.request_id);
    try std.testing.expectEqualStrings("server", from_slot.origin);
    try std.testing.expectEqual(@as(u64, 40), from_slot.cpu_time_ns);
    try std.testing.expect(from_slot.wall_time_ns >= slot_age_ns);
    try std.testing.expect(from_slot.wall_time_ns <= slot_age_ns + elapsed_ns);
    const from_dispatch = lines.items[1];
    try std.testing.expectEqual(@as(u64, 831), from_dispatch.request_id);
    try std.testing.expectEqualStrings("server", from_dispatch.origin);
    try std.testing.expectEqual(@as(u64, 0), from_dispatch.cpu_time_ns);
    try std.testing.expect(from_dispatch.wall_time_ns >= dispatch_age_ns);
    try std.testing.expect(from_dispatch.wall_time_ns <= dispatch_age_ns + elapsed_ns);
}

test "a floor the exactly-once index cannot grow for is counted, and the request keeps expecting the worker's record" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var page: Page = undefined;
    try page.init("usage-floor-unindexed");
    defer page.deinit();
    var worker = stackWorker(&page, 9, 2);

    // A usage log over the harness's sink whose encode buffer is its only
    // allocation that succeeds, so the floor's reservation cannot grow the
    // index.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    var log = try usage_log.UsageLog.init(failing.allocator(), harness.sink());
    defer log.deinit();
    var drain = harness.drain();
    drain.usage = &log;

    try worker.requests.record(fixture.dispatchedRequest(810));
    usage_drain.settleRequest(drain, &worker, 810, .{ .floor = .{ .status = .crash } });
    try std.testing.expectEqual(@as(u64, 1), drain.counters.floors_unindexed.load(.monotonic));
    try std.testing.expect(worker.requests.expected(810) != null);

    // The worker's own record is the request's only one from then on, and a
    // drain keeps it.
    try page.append(completedRecord(810));
    try std.testing.expectEqual(@as(usize, 1), usage_drain.drainWorker(drain, &worker));
    var lines = try harness.lines();
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqualStrings("worker", lines.items[0].origin);
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
    usage_drain.settleRequest(harness.drain(), &worker, 30, .completed);
    try std.testing.expect(worker.requests.dispatchedFor(30) != null);
    try std.testing.expectEqual(@as(u64, 1), page.pending());

    try std.testing.expectEqual(@as(usize, 1), usage_drain.drainWorker(harness.drain(), &worker));
    try std.testing.expect(worker.requests.dispatchedFor(30) == null);

    // A dispatch whose request never reached the worker gets no record: its
    // entry goes, and a record the worker writes for it anyway is refused.
    try worker.requests.record(fixture.dispatchedRequest(31));
    usage_drain.settleRequest(harness.drain(), &worker, 31, .abandoned);
    try std.testing.expect(worker.requests.dispatchedFor(31) == null);
    try page.append(completedRecord(31));
    try std.testing.expectEqual(@as(usize, 0), usage_drain.drainWorker(harness.drain(), &worker));
    try std.testing.expectEqual(@as(u64, 1), harness.rejected());

    var lines = try harness.lines();
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqual(@as(u64, 30), lines.items[0].request_id);
}

test "settling past the awaiting bound drains the worker first, so no honest record is lost" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var page: Page = undefined;
    try page.init("usage-settle-drains");
    defer page.deinit();
    var worker = stackWorker(&page, 7, 3);

    const total: u64 = request_table.awaiting_record_max + 1;
    var request_id: u64 = 1;
    while (request_id <= total) : (request_id += 1) {
        try worker.requests.record(fixture.dispatchedRequest(request_id));
        try page.append(completedRecord(request_id));
        usage_drain.settleRequest(harness.drain(), &worker, request_id, .completed);
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
    while (request_id <= request_table.awaiting_record_max + 1) : (request_id += 1) {
        try worker.requests.record(fixture.dispatchedRequest(request_id));
        usage_drain.settleRequest(harness.drain(), &worker, request_id, .completed);
    }
    // The oldest waiting entry made room for the newest.
    try std.testing.expect(worker.requests.dispatchedFor(1) == null);
    try std.testing.expect(worker.requests.dispatchedFor(request_table.awaiting_record_max + 1) != null);

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
    try fixture.fillUsageStream(std.testing.allocator, harness.sink(), usage_log.synthesis_reserve_bytes);

    // The last settle finds the table full and drains the worker. The stream
    // drops the batch, and that settles every request in it, so the table
    // has room again without evicting anyone and nothing is left waiting.
    const total: u64 = request_table.awaiting_record_max + 1;
    var request_id: u64 = 1;
    while (request_id <= total) : (request_id += 1) {
        try worker.requests.record(fixture.dispatchedRequest(request_id));
        try page.append(completedRecord(request_id));
        usage_drain.settleRequest(harness.drain(), &worker, request_id, .completed);
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
    try fixture.fillUsageStream(std.testing.allocator, harness.sink(), usage_log.synthesis_reserve_bytes);
    usage_drain.settleRequest(harness.drain(), &worker, identity.external_request_id, .{ .floor = .{ .status = .crash } });
    try std.testing.expectEqual(@as(u64, 0), page.pending());
    try std.testing.expectEqual(@as(u64, 1), harness.sink().stats(.usage).dropped);
    try std.testing.expectEqual(@as(usize, 0), harness.log().synthesized.count());
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

    // A first batch of records for requests the worker was never dispatched,
    // which the ring advances past without the stream, then the record of
    // one it was, which needs the stream.
    var request_id: u64 = 1;
    while (request_id <= usage_log.batch_records_max) : (request_id += 1)
        try page.append(completedRecord(request_id));
    try page.append(completedRecord(1000));
    try fixture.fillUsageStream(std.testing.allocator, harness.sink(), usage_log.synthesis_reserve_bytes);

    try std.testing.expectEqual(@as(usize, 0), usage_drain.drainWorker(harness.drain(), &worker));
    try std.testing.expectEqual(@as(u64, usage_log.batch_records_max), harness.rejected());
    try std.testing.expectEqual(@as(u64, 1), harness.sink().stats(.usage).dropped);
    try std.testing.expectEqual(@as(u64, 0), page.pending());
    try std.testing.expect(worker.requests.usageRecorded(1000));
}

test "a worker's request table moves an entry through synthesis and settling" {
    var table = request_table.RequestTable{};
    try table.record(fixture.dispatchedRequest(1));
    try std.testing.expectEqual(@as(u64, 1), table.expected(1).?.request_id);
    try std.testing.expect(table.expected(2) == null);

    // While the floor is written, worker records are refused; a lost floor
    // lets them in again, and a written one closes the request.
    table.beginSynthesis(1);
    try std.testing.expect(table.expected(1) == null);
    table.finishSynthesis(1, false);
    try std.testing.expectEqual(@as(u64, 1), table.expected(1).?.request_id);
    table.beginSynthesis(1);
    table.finishSynthesis(1, true);
    try std.testing.expect(table.usageRecorded(1));
    try std.testing.expect(table.expected(1) == null);
    try std.testing.expectEqual(request_table.Settled.freed, table.settle(1, true));

    // A completed request waits for its record, and the mark that settles
    // it, written or dropped, frees the entry.
    try table.record(fixture.dispatchedRequest(2));
    try std.testing.expectEqual(request_table.Settled.awaiting_record, table.settle(2, true));
    try std.testing.expectEqual(@as(u64, 2), table.expected(2).?.request_id);
    table.markUsageRecorded(&.{2});
    try std.testing.expect(table.dispatchedFor(2) == null);

    // An abandoned dispatch frees its entry whatever it waited for.
    try table.record(fixture.dispatchedRequest(3));
    _ = table.settle(3, true);
    table.remove(3);
    try std.testing.expect(table.expected(3) == null);
}

test "lifecycle search reaches records past the first peeked batch" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var page: Page = undefined;
    try page.init("usage-deep-scan");
    defer page.deinit();

    // A blocked record at the head stops consumption at position 0, so the
    // target far behind it is only reachable by a search that keeps looking.
    var blocker = completedRecord(1);
    blocker.request_generation = 1;
    try page.append(blocker);
    try harness.log().synthesized.put(
        std.testing.allocator,
        usage_key.keyFromRecord(blocker, .{ .worker_id = 7, .worker_generation = 3 }),
        .reserved,
    );

    const target_slot: u32 = 300;
    var index: u32 = 1;
    while (index <= target_slot) : (index += 1) {
        var filler = completedRecord(index + 1);
        filler.request_generation = 1;
        filler.request_slot = index;
        try page.append(filler);
    }
    var worker = stackWorker(&page, 7, 3);

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
    const claim = try usage_drain.claimSynthesisForLifecycle(harness.drain(), &worker, identity);
    try std.testing.expect(claim.worker_authored);
}

/// Builds a ring of `total + 1` records for worker 7/generation 3, marks the
/// one at `blocker_slot` as a reserved synthesis, and asks whether the worker
/// authored the record at `target_slot`.
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
        if (index == blocker_slot)
            try harness.log().synthesized.put(
                std.testing.allocator,
                usage_key.keyFromRecord(record, .{ .worker_id = 7, .worker_generation = 3 }),
                .reserved,
            );
    }
    var worker = stackWorker(&page, 7, 3);

    const identity = worker_shared_page.LifecycleIdentity{
        .external_request_id = target_slot + 1,
        .request_lane_id = 0,
        .request_slot = target_slot,
        .request_generation = 1,
        .worker_id = 7,
        .worker_generation = 3,
    };
    try worker.requests.record(dispatchedAs(identity));
    const claim = try usage_drain.claimSynthesisForLifecycle(harness.drain(), &worker, identity);
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

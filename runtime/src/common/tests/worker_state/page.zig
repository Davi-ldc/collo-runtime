//! The page as a whole (`common/worker_state/page/`): its layout, the
//! memfd's creation, seals and zero state, the benchmark record and the
//! lifecycle tags read across two mappings, and the completion and console
//! rings from the worker's publish to the host's drain, which starts from
//! the host's own tail and validates the one copy it hands on. The host's
//! snapshots are covered in `snapshots.zig`, and the lane that drains
//! completions by the server-ingress lane.

const std = @import("std");
const page = @import("collo_worker_state").page;

/// A page memfd and one mapping of it, with the header the host writes at
/// launch.
const MappedPage = struct {
    fd: std.posix.fd_t,
    view: page.WorkerWriterView,

    fn init(name: []const u8) !MappedPage {
        const fd = try page.createMemfd(name);
        errdefer std.posix.close(fd);
        var view = try page.mapReadWrite(fd);
        view.initializeCrashDefault(1, 4096, 1);
        return .{ .fd = fd, .view = view };
    }

    fn deinit(self: *MappedPage) void {
        self.view.deinit();
        std.posix.close(self.fd);
    }
};

fn validCompletion(request_id: u64) page.WorkerCompletionPublish {
    return .{
        .external_request_id = request_id,
        .request_lane_id = 1,
        .request_slot = @intCast(request_id % 64),
        .request_generation = 3,
        .worker_id = 4,
        .worker_generation = 5,
        .status = 0,
        .http_status = 200,
        .cpu_time_ns = request_id * 3,
    };
}

// Separate mappings observe one release-published, immutable first-handler
// record. Missing measurements stay absent instead of becoming zero samples.
test "benchmark handler record publishes once across page views" {
    const fd = try page.createMemfd("worker-bench-handler");
    defer std.posix.close(fd);
    var writer = try page.mapReadWrite(fd);
    defer writer.deinit();
    var reader = try page.mapReadWrite(fd);
    defer reader.deinit();
    try std.testing.expect(reader.loadBenchHandler() == null);
    try std.testing.expect(writer.loadBenchHandler() == null);

    const first = page.BenchHandlerRecord{
        .request_id = 17,
        .worker_id = 23,
        .worker_generation = 4,
        .handler_started_ns = 123456,
    };
    var missing = first;
    missing.handler_started_ns = 0;
    writer.publishBenchHandler(missing);
    try std.testing.expect(reader.loadBenchHandler() == null);
    missing = first;
    missing.request_id = 0;
    writer.publishBenchHandler(missing);
    try std.testing.expect(reader.loadBenchHandler() == null);

    writer.publishBenchHandler(first);
    try std.testing.expectEqualDeep(first, reader.loadBenchHandler().?);
    try std.testing.expectEqualDeep(first, writer.loadBenchHandler().?);
    var later = first;
    later.request_id += 1;
    later.handler_started_ns += 100;
    writer.publishBenchHandler(later);
    try std.testing.expectEqualDeep(first, reader.loadBenchHandler().?);
}

test "worker shared page layout is fixed size" {
    try std.testing.expectEqual(@as(usize, 2), page.LIVE_SLOT_COUNT);
    try std.testing.expectEqual(@as(usize, 1024), page.RECORD_RING_COUNT);
    try std.testing.expectEqual(@as(usize, 16), page.COMPLETION_RING_COUNT);
    try std.testing.expectEqual(@as(usize, @sizeOf(page.Page)), page.byteSize());
}

test "worker shared page initializeCrashDefault starts in crash-safe mode" {
    const fd = try page.createMemfd("work-state-default");
    defer std.posix.close(fd);

    var view = try page.mapReadWrite(fd);
    defer view.deinit();

    view.initializeCrashDefault(77, 4096, 1234);
    try std.testing.expectEqual(@as(u32, page.VERSION), view.header.version);
    try std.testing.expectEqual(@intFromEnum(page.State.forked), view.header.state);
    try std.testing.expectEqual(@intFromEnum(page.TerminationReason.crash), view.header.termination_reason);
    try std.testing.expectEqual(@as(u32, 77), view.header.pid);
    try std.testing.expectEqual(@as(u64, 0), view.header.metrics_dropped_count);
    try std.testing.expectEqual(@as(u64, 0), view.header.records_head);
    try std.testing.expectEqual(@as(u64, 0), view.header.records_tail);
    try std.testing.expectEqual(@as(u64, 4096), view.header.memory_limit_bytes);
    try std.testing.expectEqual(@as(u64, 1234), view.header.worker_started_mono_ns);
}

// `WorkerWriterView.initializeCrashDefault` writes only the header and relies
// on a new memfd reading zero everywhere else; its comment says why it does
// not zero the page. This checks that reliance on every byte.
test "worker shared page initializeCrashDefault leaves a fresh memfd zero outside the header" {
    const fd = try page.createMemfd("work-state-fresh-init");
    defer std.posix.close(fd);

    var view = try page.mapReadWrite(fd);
    defer view.deinit();

    view.initializeCrashDefault(7, 8192, 4567);

    try std.testing.expectEqual(@as(u32, page.VERSION), view.header.version);
    try std.testing.expectEqual(@intFromEnum(page.State.forked), view.header.state);
    try std.testing.expectEqual(@intFromEnum(page.TerminationReason.crash), view.header.termination_reason);
    try std.testing.expectEqual(@as(u64, 8192), view.header.memory_limit_bytes);
    try std.testing.expectEqual(@as(u64, 4567), view.header.worker_started_mono_ns);
    try std.testing.expectEqual(@as(u64, 0), view.live_slots[0].request_id);
    try std.testing.expectEqual(@as(u64, 0), view.completed_records[0].request_id);
    try std.testing.expectEqual(@as(u64, 0), view.completion_records[0].external_request_id);

    var non_zero: usize = 0;
    for (view.bytes[@sizeOf(page.Header)..]) |byte| {
        if (byte != 0) non_zero += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), non_zero);
}

test "worker shared page zeroed mapping is rejected after memfd creation contract" {
    const fd = try std.posix.memfd_create("work-state-zeroed", std.os.linux.MFD.CLOEXEC);
    defer std.posix.close(fd);
    try std.posix.ftruncate(fd, page.byteSize());

    try std.testing.expectError(error.MissingFdSeals, page.mapReadWrite(fd));
}

test "worker shared page memfd is size sealed" {
    const fd = try page.createMemfd("work-state-sealed");
    defer std.posix.close(fd);

    try page.validateMemfd(fd);
    if (std.posix.ftruncate(fd, 0)) {
        return error.ExpectedSealedMetricsMemfd;
    } else |_| {}
}

test "the host's lifecycle snapshot reads the tags the worker's setState stored" {
    const fd = try page.createMemfd("worker-lifecycle-snapshot");
    defer std.posix.close(fd);
    var host_view = try page.mapReadWrite(fd);
    defer host_view.deinit();
    host_view.initializeCrashDefault(1, 0, 0);
    var worker_view = try page.mapReadWrite(fd);
    defer worker_view.deinit();

    const launched = page.LifecycleSnapshot.load(host_view.header);
    try std.testing.expectEqual(page.State.forked, launched.knownState().?);
    try std.testing.expectEqual(page.TerminationReason.crash, launched.knownTerminationReason().?);

    worker_view.setState(.dead, .memory);
    const died = page.LifecycleSnapshot.load(host_view.header);
    try std.testing.expectEqual(page.State.dead, died.knownState().?);
    try std.testing.expectEqual(page.TerminationReason.memory, died.knownTerminationReason().?);

    @atomicStore(u32, &worker_view.header.state, 999, .release);
    const unknown = page.LifecycleSnapshot.load(host_view.header);
    try std.testing.expect(unknown.knownState() == null);
    try std.testing.expectEqual(@as(u32, 999), unknown.state);
}

test "worker completion ring publishes many records with one eventfd wake" {
    var mapped = try MappedPage.init("worker-completion-ring");
    defer mapped.deinit();
    const view = &mapped.view;

    const event_fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
    defer std.posix.close(event_fd);

    try view.publishWorkerCompletion(validCompletion(10));
    try view.publishWorkerCompletion(validCompletion(11));
    try page.signalCompletionEventfd(event_fd);
    try std.testing.expectEqual(@as(u64, 1), try page.drainCompletionEventfd(event_fd));

    var out: [4]page.WorkerCompletionRecord = undefined;
    try std.testing.expectEqual(@as(usize, 2), try view.drainWorkerCompletions(&out));
    try std.testing.expectEqual(@as(u64, 10), out[0].external_request_id);
    try std.testing.expectEqual(@as(u64, 11), out[1].external_request_id);
}

test "a completion drain starts from the host's own tail, whatever the worker stores in the page's copy" {
    const fd = try page.createMemfd("worker-completion-host-tail");
    defer std.posix.close(fd);
    var host_view = try page.mapReadWrite(fd);
    defer host_view.deinit();
    host_view.initializeCrashDefault(1, 0, 0);
    var worker_view = try page.mapReadWrite(fd);
    defer worker_view.deinit();

    try worker_view.publishWorkerCompletion(validCompletion(1));
    try worker_view.publishWorkerCompletion(validCompletion(2));
    var out: [page.COMPLETION_RING_COUNT]page.WorkerCompletionRecord = undefined;
    try std.testing.expectEqual(@as(usize, 2), try host_view.drainWorkerCompletions(&out));
    try std.testing.expectEqual(@as(u64, 2), out[1].external_request_id);
    try std.testing.expectEqual(@as(u64, 6), out[1].cpu_time_ns);
    try std.testing.expectEqual(@as(u64, 2), host_view.host_cursors.completion_tail);
    // The worker's room check reads the tail the host stored.
    try std.testing.expectEqual(@as(u64, 2), @atomicLoad(u64, &worker_view.completion_header.tail, .acquire));

    // The worker rewinds the page's tail: the host's next drain finds
    // nothing new, then only the record published after.
    @atomicStore(u64, &worker_view.completion_header.tail, 0, .release);
    try std.testing.expectEqual(@as(usize, 0), try host_view.drainWorkerCompletions(&out));
    try worker_view.publishWorkerCompletion(validCompletion(3));
    try std.testing.expectEqual(@as(usize, 1), try host_view.drainWorkerCompletions(&out));
    try std.testing.expectEqual(@as(u64, 3), out[0].external_request_id);
    try std.testing.expectEqual(@as(u64, 3), host_view.host_cursors.completion_tail);
}

const CompletionCorruption = enum { sequence, http_status_low, http_status_high, status_past_last_tag, padding };

fn corruptCompletion(record: *page.WorkerCompletionRecord, corruption: CompletionCorruption) void {
    switch (corruption) {
        .sequence => record.sequence = 99,
        .http_status_low => record.http_status = 199,
        .http_status_high => record.http_status = 600,
        .status_past_last_tag => record.status = 7,
        .padding => record._reserved0 = 1,
    }
}

test "a completion out of sequence or failing validation turns the ring fatal and moves neither tail" {
    const cases = [_]struct { corruption: CompletionCorruption, expected: page.CompletionDrainError }{
        .{ .corruption = .sequence, .expected = error.WorkerCompletionSequenceMismatch },
        .{ .corruption = .http_status_low, .expected = error.InvalidWorkerCompletionStatus },
        .{ .corruption = .http_status_high, .expected = error.InvalidWorkerCompletionStatus },
        .{ .corruption = .status_past_last_tag, .expected = error.InvalidWorkerCompletionStatus },
        .{ .corruption = .padding, .expected = error.InvalidWorkerCompletionRecord },
    };
    for (cases) |case| {
        var mapped = try MappedPage.init("worker-completion-refused");
        defer mapped.deinit();
        const view = &mapped.view;

        try view.publishWorkerCompletion(validCompletion(1));
        corruptCompletion(&view.completion_records[0], case.corruption);
        var out: [1]page.WorkerCompletionRecord = undefined;
        try std.testing.expectError(case.expected, view.drainWorkerCompletions(&out));
        try std.testing.expectEqual(@as(u32, 1), @atomicLoad(u32, &view.completion_header.fatal, .acquire));
        try std.testing.expectEqual(@as(u64, 0), @atomicLoad(u64, &view.completion_header.tail, .acquire));
        try std.testing.expectEqual(@as(u64, 0), view.host_cursors.completion_tail);
        try std.testing.expectError(error.WorkerCompletionRingFatal, view.drainWorkerCompletions(&out));
    }
}

test "a completion head more than the ring past the host's tail, or behind it, turns the ring fatal" {
    var out: [page.COMPLETION_RING_COUNT]page.WorkerCompletionRecord = undefined;

    var ahead = try MappedPage.init("worker-completion-head-ahead");
    defer ahead.deinit();
    @atomicStore(u64, &ahead.view.completion_header.head, page.COMPLETION_RING_COUNT + 1, .release);
    try std.testing.expectError(error.WorkerCompletionRingCorrupt, ahead.view.drainWorkerCompletions(&out));
    try std.testing.expectEqual(@as(u32, 1), @atomicLoad(u32, &ahead.view.completion_header.fatal, .acquire));
    try std.testing.expectError(error.WorkerCompletionRingFatal, ahead.view.drainWorkerCompletions(&out));

    var behind = try MappedPage.init("worker-completion-head-behind");
    defer behind.deinit();
    try behind.view.publishWorkerCompletion(validCompletion(1));
    try behind.view.publishWorkerCompletion(validCompletion(2));
    try std.testing.expectEqual(@as(usize, 2), try behind.view.drainWorkerCompletions(&out));
    // The worker moves its head back behind what the host already took.
    @atomicStore(u64, &behind.view.completion_header.head, 1, .release);
    try std.testing.expectError(error.WorkerCompletionRingCorrupt, behind.view.drainWorkerCompletions(&out));
    try std.testing.expectEqual(@as(u64, 2), behind.view.host_cursors.completion_tail);
}

test "the worker publishes no completion the host's drain would refuse" {
    var mapped = try MappedPage.init("worker-completion-publish-refused");
    defer mapped.deinit();
    const view = &mapped.view;

    var invalid = validCompletion(1);
    invalid.http_status = 0;
    try std.testing.expectError(error.InvalidWorkerCompletionStatus, view.publishWorkerCompletion(invalid));
    invalid = validCompletion(1);
    invalid.status = 7;
    try std.testing.expectError(error.InvalidWorkerCompletionStatus, view.publishWorkerCompletion(invalid));
    try std.testing.expectEqual(@as(u64, 0), @atomicLoad(u64, &view.completion_header.head, .acquire));
    try std.testing.expectEqual(@as(u32, 0), @atomicLoad(u32, &view.completion_header.fatal, .acquire));

    try view.publishWorkerCompletion(validCompletion(2));
    var out: [1]page.WorkerCompletionRecord = undefined;
    try std.testing.expectEqual(@as(usize, 1), try view.drainWorkerCompletions(&out));
    try std.testing.expectEqual(@as(u64, 2), out[0].external_request_id);
    try std.testing.expectEqual(@as(u64, 1), out[0].sequence);
}

test "worker completion ring overflow marks shared page fatal" {
    var mapped = try MappedPage.init("worker-completion-overflow");
    defer mapped.deinit();
    const view = &mapped.view;

    for (0..page.COMPLETION_RING_COUNT) |index|
        try view.publishWorkerCompletion(validCompletion(index + 1));
    try std.testing.expectError(error.WorkerCompletionRingOverflow, view.publishWorkerCompletion(validCompletion(9999)));
    try std.testing.expectEqual(@as(u32, 1), @atomicLoad(u32, &view.completion_header.fatal, .acquire));
    try std.testing.expectEqual(@as(u64, 1), @atomicLoad(u64, &view.completion_header.overflow_count, .acquire));

    var out: [1]page.WorkerCompletionRecord = undefined;
    try std.testing.expectError(error.WorkerCompletionRingFatal, view.drainWorkerCompletions(&out));
}

test "completion records keep their order as the ring cycles and as the 64-bit sequence wraps" {
    var out: [page.COMPLETION_RING_COUNT]page.WorkerCompletionRecord = undefined;

    // A full ring drains whole, round after round, as a long-lived worker
    // cycles through it.
    var cycled = try MappedPage.init("worker-completion-cycle");
    defer cycled.deinit();
    var request_id: u64 = 1;
    for (0..3) |_| {
        const first = request_id;
        for (0..page.COMPLETION_RING_COUNT) |_| {
            try cycled.view.publishWorkerCompletion(validCompletion(request_id));
            request_id += 1;
        }
        try std.testing.expectEqual(@as(usize, page.COMPLETION_RING_COUNT), try cycled.view.drainWorkerCompletions(&out));
        var expected_id = first;
        for (out) |record| {
            try std.testing.expectEqual(expected_id, record.external_request_id);
            expected_id += 1;
        }
    }

    // Every cursor starts two records short of the 64-bit wrap. The ring
    // index runs on across it because the count divides 2^64.
    var wrapped = try MappedPage.init("worker-completion-wrap");
    defer wrapped.deinit();
    const start = std.math.maxInt(u64) - 1;
    @atomicStore(u64, &wrapped.view.completion_header.head, start, .release);
    @atomicStore(u64, &wrapped.view.completion_header.tail, start, .release);
    wrapped.view.host_cursors.completion_tail = start;
    for (1..5) |id|
        try wrapped.view.publishWorkerCompletion(validCompletion(id));
    try std.testing.expectEqual(@as(usize, 4), try wrapped.view.drainWorkerCompletions(&out));
    for (out[0..4], 1..) |record, id|
        try std.testing.expectEqual(@as(u64, id), record.external_request_id);
    try std.testing.expectEqual(@as(u64, 0), out[1].sequence);
    try std.testing.expectEqual(@as(u64, 2), wrapped.view.host_cursors.completion_tail);
}

test "worker log ring publishes and drains lines with attribution" {
    var mapped = try MappedPage.init("worker-log-ring");
    defer mapped.deinit();
    const view = &mapped.view;

    var scratch: [page.LOG_LINE_BYTES_MAX]u8 = undefined;
    var out: [8]page.DrainedLogLine = undefined;
    try std.testing.expectEqual(@as(usize, 0), try view.drainLogLinesChecked(&scratch, &out));

    view.publishLogLine(.info, 0, 42, 1111, "hello");
    view.publishLogLine(.err, page.LogLineFlags.js_exception, 43, 2222, "boom");

    const count = try view.drainLogLinesChecked(&scratch, &out);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings("hello", out[0].payload);
    try std.testing.expectEqual(@as(u64, 42), out[0].header.request_id);
    try std.testing.expectEqual(@intFromEnum(page.LogLevel.info), out[0].header.level);
    try std.testing.expectEqual(@as(u64, 1111), out[0].header.ts_mono_ns);
    try std.testing.expectEqualStrings("boom", out[1].payload);
    try std.testing.expectEqual(page.LogLineFlags.js_exception, out[1].header.flags);
    try std.testing.expectEqual(@as(u64, 43), out[1].header.request_id);
    try std.testing.expectEqual(@as(usize, 0), try view.drainLogLinesChecked(&scratch, &out));
}

test "the console ring's drain starts from the host's own tail" {
    var mapped = try MappedPage.init("worker-log-ring-host-tail");
    defer mapped.deinit();
    const view = &mapped.view;

    var scratch: [64]u8 = undefined;
    var lines: [4]page.DrainedLogLine = undefined;
    view.publishLogLine(.info, 0, 7, 100, "first");
    try std.testing.expectEqual(@as(usize, 1), try view.drainLogLinesChecked(&scratch, &lines));

    // The worker rewinds the page's copy of the tail; the next drain returns
    // only the line published after.
    @atomicStore(u64, &view.log_header.tail, 0, .release);
    view.publishLogLine(.info, 0, 7, 101, "second");
    try std.testing.expectEqual(@as(usize, 1), try view.drainLogLinesChecked(&scratch, &lines));
    try std.testing.expectEqualStrings("second", lines[0].payload);
    try std.testing.expectEqual(view.host_cursors.log_tail, @atomicLoad(u64, &view.log_header.tail, .acquire));
}

test "worker log ring truncates oversized payloads at a utf-8 boundary" {
    var mapped = try MappedPage.init("worker-log-ring-truncate");
    defer mapped.deinit();
    const view = &mapped.view;

    var big: [page.LOG_LINE_BYTES_MAX + 1000]u8 = undefined;
    @memset(&big, 'a');
    // Multibyte char straddling the cut: the boundary backs off below the cap.
    const snowman = "\u{2603}"; // 3 bytes
    @memcpy(big[page.LOG_LINE_BYTES_MAX - 1 .. page.LOG_LINE_BYTES_MAX + 2], snowman);
    view.publishLogLine(.info, 0, 1, 1, &big);

    var scratch: [page.LOG_LINE_BYTES_MAX]u8 = undefined;
    var out: [1]page.DrainedLogLine = undefined;
    try std.testing.expectEqual(@as(usize, 1), try view.drainLogLinesChecked(&scratch, &out));
    try std.testing.expect(out[0].header.flags & page.LogLineFlags.truncated != 0);
    try std.testing.expectEqual(@as(usize, page.LOG_LINE_BYTES_MAX - 1), out[0].payload.len);
    try std.testing.expect(out[0].payload[out[0].payload.len - 1] == 'a');
}

test "worker log ring drops newest on overflow and counts drops" {
    var mapped = try MappedPage.init("worker-log-ring-overflow");
    defer mapped.deinit();
    const view = &mapped.view;

    // 32 frames of exactly 4096 bytes (24 header + 4072 payload) fill the
    // 128 KiB ring completely.
    var payload: [page.LOG_LINE_BYTES_MAX - 24]u8 = undefined;
    @memset(&payload, 'x');
    var i: usize = 0;
    while (i < 32) : (i += 1)
        view.publishLogLine(.info, 0, i, i, &payload);
    try std.testing.expectEqual(@as(u64, 0), @atomicLoad(u64, &view.log_header.dropped_lines, .acquire));

    view.publishLogLine(.warn, 0, 99, 99, "dropped");
    try std.testing.expectEqual(@as(u64, 1), @atomicLoad(u64, &view.log_header.dropped_lines, .acquire));
    try std.testing.expectEqual(@as(u64, 7), @atomicLoad(u64, &view.log_header.dropped_bytes, .acquire));

    var scratch: [page.LOG_LINE_BYTES_MAX]u8 = undefined;
    var out: [1]page.DrainedLogLine = undefined;
    var drained: usize = 0;
    var last_request_id: u64 = 0;
    // One drain more than the ring holds, so a drain that never empties it
    // fails the count instead of looping.
    for (0..33) |_| {
        if (try view.drainLogLinesChecked(&scratch, &out) == 0)
            break;
        last_request_id = out[0].header.request_id;
        drained += 1;
    }
    try std.testing.expectEqual(@as(usize, 32), drained);
    try std.testing.expectEqual(@as(u64, 31), last_request_id);

    // Space freed: the next publish lands again.
    view.publishLogLine(.info, 0, 100, 100, "after");
    try std.testing.expectEqual(@as(usize, 1), try view.drainLogLinesChecked(&scratch, &out));
    try std.testing.expectEqualStrings("after", out[0].payload);
}

test "worker log ring wraps frames across the buffer boundary" {
    var mapped = try MappedPage.init("worker-log-ring-wrap");
    defer mapped.deinit();
    const view = &mapped.view;

    var scratch: [page.LOG_LINE_BYTES_MAX]u8 = undefined;
    var out: [4]page.DrainedLogLine = undefined;

    // Publish/drain lockstep frames of 4024 bytes: cursor passes the 128 KiB
    // boundary on round 33, so that round's frame (header and payload) wraps
    // modularly and must survive intact.
    var filler: [4000]u8 = undefined;
    var round: usize = 0;
    while (round < 34) : (round += 1) {
        @memset(&filler, @as(u8, @intCast('a' + (round % 26))));
        view.publishLogLine(.info, 0, round, round, &filler);
        try std.testing.expectEqual(@as(usize, 1), try view.drainLogLinesChecked(&scratch, out[0..1]));
        try std.testing.expectEqualSlices(u8, &filler, out[0].payload);
        try std.testing.expectEqual(@as(u64, round), out[0].header.request_id);
    }
    try std.testing.expect(@atomicLoad(u64, &view.log_header.head, .acquire) > page.LOG_RING_BYTES);
    try std.testing.expectEqual(@as(u64, 0), @atomicLoad(u64, &view.log_header.dropped_lines, .acquire));
}

test "worker log ring rejects hostile frame lengths fail-closed" {
    var mapped = try MappedPage.init("worker-log-ring-hostile");
    defer mapped.deinit();
    const view = &mapped.view;

    view.publishLogLine(.info, 0, 1, 1, "victim");
    // Hostile worker rewrites the frame length in shared memory.
    std.mem.writeInt(u32, view.log_bytes[0..4], 0xffff_ffff, .little);

    var scratch: [page.LOG_LINE_BYTES_MAX]u8 = undefined;
    var out: [1]page.DrainedLogLine = undefined;
    try std.testing.expectError(error.InvalidLogFrame, view.drainLogLinesChecked(&scratch, &out));
    try std.testing.expectError(error.LogRingFatal, view.drainLogLinesChecked(&scratch, &out));
    // A fatal ring also stops accepting writes: head stays where the victim
    // frame left it (24-byte header + 6-byte payload).
    view.publishLogLine(.info, 0, 2, 2, "ignored");
    try std.testing.expectEqual(@as(u64, 30), @atomicLoad(u64, &view.log_header.head, .acquire));
}

test "worker log ring passes an out-of-range level byte through instead of failing fatal" {
    var mapped = try MappedPage.init("worker-log-ring-level");
    defer mapped.deinit();
    const view = &mapped.view;

    view.publishLogLine(.info, 0, 1, 1, "hello");
    // Hostile worker rewrites the level byte (offset 4: after the u32
    // payload_len) to a value outside the LogLevel enum. Level is a display
    // attribute, not a frame invariant, so the drain must still succeed and
    // hand the raw byte to the consumer, which maps it to a default.
    view.log_bytes[4] = 0xff;

    var scratch: [page.LOG_LINE_BYTES_MAX]u8 = undefined;
    var out: [1]page.DrainedLogLine = undefined;
    try std.testing.expectEqual(@as(usize, 1), try view.drainLogLinesChecked(&scratch, &out));
    try std.testing.expectEqual(@as(u8, 0xff), out[0].header.level);
    try std.testing.expectEqualStrings("hello", out[0].payload);
    try std.testing.expectEqual(@as(u32, 0), @atomicLoad(u32, &view.log_header.fatal, .acquire));
}

test "worker log ring demands scratch for one full line" {
    var mapped = try MappedPage.init("worker-log-ring-scratch");
    defer mapped.deinit();
    const view = &mapped.view;

    view.publishLogLine(.info, 0, 1, 1, "0123456789");
    var tiny: [4]u8 = undefined;
    var out: [1]page.DrainedLogLine = undefined;
    try std.testing.expectError(error.LogScratchTooSmall, view.drainLogLinesChecked(&tiny, &out));

    // Scratch smaller than the batch but big enough for one line drains
    // incrementally without loss.
    var one_line: [10]u8 = undefined;
    view.publishLogLine(.info, 0, 2, 2, "abcdefghij");
    try std.testing.expectEqual(@as(usize, 1), try view.drainLogLinesChecked(&one_line, &out));
    try std.testing.expectEqualStrings("0123456789", out[0].payload);
    try std.testing.expectEqual(@as(usize, 1), try view.drainLogLinesChecked(&one_line, &out));
    try std.testing.expectEqualStrings("abcdefghij", out[0].payload);
}

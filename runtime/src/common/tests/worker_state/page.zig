//! The page as a whole (`common/worker_state/page/`): its layout and the
//! page a worker's first request touches, the memfd's creation, seals and
//! header, the benchmark record, the lifecycle tags and the owner section
//! read through the host's view, and the console ring from the worker's
//! publish to the host's drain, which starts from the host's own tail and
//! validates the one copy it hands on. The live slots are covered in
//! `live_slots.zig` and the host's snapshots in `snapshots.zig`.

const std = @import("std");
const limits = @import("collo_limits");
const page = @import("collo_worker_state").page;

/// A page memfd mapped once by the worker and once by the host.
const MappedPage = struct {
    fd: std.posix.fd_t,
    worker: page.WorkerWriterView,
    host: page.HostReaderView,

    fn init(self: *MappedPage, name: []const u8) !void {
        self.fd = try page.createMemfd(name);
        errdefer std.posix.close(self.fd);
        self.worker = try page.mapWorkerWriter(self.fd);
        errdefer self.worker.deinit();
        self.host = try page.mapHostReader(self.fd);
    }

    fn deinit(self: *MappedPage) void {
        self.host.deinit();
        self.worker.deinit();
        std.posix.close(self.fd);
    }
};

// Separate mappings observe one release-published, immutable first-handler
// record. Missing measurements stay absent instead of becoming zero samples.
test "benchmark handler record publishes once across page views" {
    var mapped: MappedPage = undefined;
    try mapped.init("worker-bench-handler");
    defer mapped.deinit();
    const writer = &mapped.worker;
    const reader = &mapped.host;
    try std.testing.expect(reader.loadBenchHandler() == null);

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
    var later = first;
    later.request_id += 1;
    later.handler_started_ns += 100;
    writer.publishBenchHandler(later);
    try std.testing.expectEqualDeep(first, reader.loadBenchHandler().?);
}

test "the host reads each boot stamp the child stored, and 0 for a phase it never reached" {
    var mapped: MappedPage = undefined;
    try mapped.init("worker-boot-stamps");
    defer mapped.deinit();

    var buffered: [page.BOOT_PHASE_COUNT]u64 = @splat(0);
    buffered[@intFromEnum(page.BootPhase.namespaces_entered)] = 10;
    buffered[@intFromEnum(page.BootPhase.worker_init_received)] = 20;
    mapped.worker.storeBootPhaseStamps(&buffered);
    mapped.worker.storeBootPhaseStampNs(.seccomp_applied, 30);

    try std.testing.expectEqual(@as(u64, 10), mapped.host.loadBootPhaseStampNs(.namespaces_entered));
    try std.testing.expectEqual(@as(u64, 20), mapped.host.loadBootPhaseStampNs(.worker_init_received));
    try std.testing.expectEqual(@as(u64, 30), mapped.host.loadBootPhaseStampNs(.seccomp_applied));
    try std.testing.expectEqual(@as(u64, 0), mapped.host.loadBootPhaseStampNs(.ready));
}

test "every worker's page has a live slot per pool slot the largest concurrency allows, and no completion or usage ring" {
    try std.testing.expectEqual(@as(usize, limits.server.worker_concurrency_max), page.LIVE_SLOT_COUNT);
    try std.testing.expectEqual(@as(usize, @sizeOf(page.Page)), page.byteSize());
    // A request's completion and measures travel as its `request_done` on
    // the control socket, so the page is the header and the slots in its
    // first 4 KiB, then the console ring.
    try std.testing.expectEqual(@as(usize, 131_744), page.byteSize());
    try std.testing.expectEqual(@as(usize, 440), @offsetOf(page.Page, "log_header"));
    try std.testing.expectEqual(@as(usize, 504), @offsetOf(page.Page, "boot_phase_stamps_mono_ns"));
    try std.testing.expectEqual(@as(usize, 640), @offsetOf(page.Page, "bench_handler"));
    try std.testing.expectEqual(@as(usize, 672), @offsetOf(page.Page, "log_bytes"));
    try std.testing.expectEqual(page.LOG_RING_BYTES, page.byteSize() - @offsetOf(page.Page, "log_bytes"));
    inline for (.{ "COMPLETION_RING_COUNT", "RECORD_RING_COUNT", "CompletedRecord", "WorkerCompletionRecord", "RecordCursor", "LiveSlotState" }) |decl|
        try std.testing.expect(!@hasDecl(page, decl));
    try std.testing.expect(!@hasField(page.Header, "records_head"));
    try std.testing.expect(!@hasField(page.LiveRequestSlot, "state"));
    try std.testing.expect(!@hasField(page.BootPhase, "fs_index_mapped"));
}

test "a new page reads as a worker that crashed before it wrote anything, with no owner and no request" {
    var mapped: MappedPage = undefined;
    try mapped.init("work-state-default");
    defer mapped.deinit();

    // The host reads this until the worker stores a state of its own.
    const launched = mapped.host.loadLifecycle();
    try std.testing.expectEqual(page.State.forked, launched.knownState().?);
    try std.testing.expectEqual(page.TerminationReason.crash, launched.knownTerminationReason().?);
    try std.testing.expect(!launched.startupEnded());
    const owner = mapped.host.loadOwner();
    try std.testing.expectEqual(@as(u64, 0), owner.owner_id);
    try std.testing.expectEqual(@as(u64, 0), owner.deadline_mono_ns);
    try std.testing.expect(mapped.host.loadRunningOwner() == null);
    try std.testing.expectEqual(@as(u64, 0), mapped.host.loadLiveSlot(0).request_id);
    try std.testing.expectEqual(@as(u32, page.VERSION), mapped.worker.header.version);
}

// `createMemfd` writes only the header and relies on a new memfd reading
// zero everywhere else; its comment says why it does not zero the page. This
// checks that reliance on every byte.
test "a new page is zero past its header" {
    var mapped: MappedPage = undefined;
    try mapped.init("work-state-fresh-init");
    defer mapped.deinit();

    var non_zero: usize = 0;
    for (mapped.worker.bytes[@sizeOf(page.Header)..]) |byte| {
        if (byte != 0) non_zero += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), non_zero);
}

test "a worker's boot and its requests write only the page's first 4 KiB until its console lines pass it" {
    var mapped: MappedPage = undefined;
    try mapped.init("worker-page-first-touch");
    defer mapped.deinit();
    const view = &mapped.worker;

    const stamps: [page.BOOT_PHASE_COUNT]u64 = @splat(7);
    view.storeBootPhaseStamps(&stamps);
    view.publishBenchHandler(.{ .request_id = 1, .worker_id = 2, .worker_generation = 3, .handler_started_ns = 4 });
    view.publishStartupEvaluationsEnded();
    view.publishOwner(1, 99);
    view.publishRunningOwnerCpu(1, 5);
    // Every pool slot at once, the last one included.
    for (0..page.LIVE_SLOT_COUNT) |index| {
        view.beginLiveSlot(index, index + 1, 1);
        view.storeLiveSlotCpu(index, index + 1, 5);
    }
    // The console ring starts in the same page: a short line stays there.
    view.publishLogLine(.info, 0, 1, 1, "x");

    const first_page: usize = 4096;
    var written_past: usize = 0;
    for (view.bytes[first_page..]) |byte| {
        if (byte != 0) written_past += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), written_past);

    // Console lines are the first writes past it.
    const long_line: [page.LOG_LINE_BYTES_MAX]u8 = @splat('y');
    view.publishLogLine(.info, 0, 1, 1, &long_line);
    for (view.bytes[first_page..]) |byte| {
        if (byte != 0) written_past += 1;
    }
    try std.testing.expect(written_past != 0);
}

test "worker shared page zeroed mapping is rejected after memfd creation contract" {
    const fd = try std.posix.memfd_create("work-state-zeroed", std.os.linux.MFD.CLOEXEC);
    defer std.posix.close(fd);
    try std.posix.ftruncate(fd, page.byteSize());

    try std.testing.expectError(error.MissingFdSeals, page.mapWorkerWriter(fd));
    try std.testing.expectError(error.MissingFdSeals, page.mapHostReader(fd));
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
    var mapped: MappedPage = undefined;
    try mapped.init("worker-lifecycle-snapshot");
    defer mapped.deinit();

    const launched = mapped.host.loadLifecycle();
    try std.testing.expectEqual(page.State.forked, launched.knownState().?);
    try std.testing.expectEqual(page.TerminationReason.crash, launched.knownTerminationReason().?);

    mapped.worker.setState(.dead, .memory);
    const died = mapped.host.loadLifecycle();
    try std.testing.expectEqual(page.State.dead, died.knownState().?);
    try std.testing.expectEqual(page.TerminationReason.memory, died.knownTerminationReason().?);

    // A sentinel that can no longer watch the worker names itself.
    mapped.worker.setState(.dead, .sentinel);
    const unwatched = mapped.host.loadLifecycle();
    try std.testing.expectEqual(page.TerminationReason.sentinel, unwatched.knownTerminationReason().?);
    try std.testing.expectEqual(@as(u32, 6), unwatched.termination_reason);

    @atomicStore(u32, &mapped.worker.header.state, 999, .release);
    const unknown = mapped.host.loadLifecycle();
    try std.testing.expect(unknown.knownState() == null);
    try std.testing.expectEqual(@as(u32, 999), unknown.state);
}

test "the host reads the owner the worker's VM thread published and the CPU its sentinel published" {
    var mapped: MappedPage = undefined;
    try mapped.init("worker-owner-section");
    defer mapped.deinit();
    const worker_view = &mapped.worker;

    worker_view.publishOwner(41, 9_000);
    const owner = mapped.host.loadOwner();
    try std.testing.expectEqual(@as(u64, 41), owner.owner_id);
    try std.testing.expectEqual(@as(u64, 9_000), owner.deadline_mono_ns);
    worker_view.publishOwner(0, 0);
    const idle = mapped.host.loadOwner();
    try std.testing.expectEqual(@as(u64, 0), idle.owner_id);
    try std.testing.expectEqual(@as(u64, 0), idle.deadline_mono_ns);

    // No owner's CPU was ever read: nothing to report.
    try std.testing.expect(mapped.host.loadRunningOwner() == null);
    worker_view.publishRunningOwnerCpu(41, 40_000_000);
    const running = mapped.host.loadRunningOwner() orelse return error.TestExpectedRunningOwner;
    try std.testing.expectEqual(@as(u64, 41), running.owner_id);
    try std.testing.expectEqual(@as(u64, 40_000_000), running.cpu_ns);
    worker_view.publishRunningOwnerCpu(42, 7);
    const next = mapped.host.loadRunningOwner() orelse return error.TestExpectedRunningOwner;
    try std.testing.expectEqual(@as(u64, 42), next.owner_id);
    try std.testing.expectEqual(@as(u64, 7), next.cpu_ns);
    // Two publications moved the sequence by two each, and it is even again.
    try std.testing.expectEqual(@as(u32, 4), @atomicLoad(u32, &worker_view.header.running_owner_sequence, .acquire));
}

test "worker log ring publishes and drains lines with attribution" {
    var mapped: MappedPage = undefined;
    try mapped.init("worker-log-ring");
    defer mapped.deinit();
    const view = &mapped.worker;
    const host = &mapped.host;

    var scratch: [page.LOG_LINE_BYTES_MAX]u8 = undefined;
    var out: [8]page.DrainedLogLine = undefined;
    try std.testing.expectEqual(@as(usize, 0), try host.drainLogLinesChecked(&scratch, &out));

    view.publishLogLine(.info, 0, 42, 1111, "hello");
    view.publishLogLine(.err, page.LogLineFlags.js_exception, 43, 2222, "boom");

    const count = try host.drainLogLinesChecked(&scratch, &out);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings("hello", out[0].payload);
    try std.testing.expectEqual(@as(u64, 42), out[0].header.request_id);
    try std.testing.expectEqual(@intFromEnum(page.LogLevel.info), out[0].header.level);
    try std.testing.expectEqual(@as(u64, 1111), out[0].header.ts_mono_ns);
    try std.testing.expectEqualStrings("boom", out[1].payload);
    try std.testing.expectEqual(page.LogLineFlags.js_exception, out[1].header.flags);
    try std.testing.expectEqual(@as(u64, 43), out[1].header.request_id);
    try std.testing.expectEqual(@as(usize, 0), try host.drainLogLinesChecked(&scratch, &out));
}

test "a runtime line keeps its flag through the console ring, and a bit outside LogLineFlags is dropped" {
    var mapped: MappedPage = undefined;
    try mapped.init("worker-log-ring-runtime");
    defer mapped.deinit();
    const view = &mapped.worker;
    const host = &mapped.host;

    const unknown_bit: u8 = 1 << 7;
    view.publishLogLine(.warn, page.LogLineFlags.runtime, 0, 10, "worker event loop failed");
    view.publishLogLine(.info, page.LogLineFlags.runtime | unknown_bit, 0, 11, "second");

    var scratch: [page.LOG_LINE_BYTES_MAX]u8 = undefined;
    var out: [2]page.DrainedLogLine = undefined;
    try std.testing.expectEqual(@as(usize, 2), try host.drainLogLinesChecked(&scratch, &out));
    try std.testing.expectEqual(page.LogLineFlags.runtime, out[0].header.flags);
    try std.testing.expectEqual(@as(u64, 0), out[0].header.request_id);
    try std.testing.expectEqualStrings("worker event loop failed", out[0].payload);
    try std.testing.expectEqual(page.LogLineFlags.runtime, out[1].header.flags);
}

test "the console ring's drain starts from the host's own tail" {
    var mapped: MappedPage = undefined;
    try mapped.init("worker-log-ring-host-tail");
    defer mapped.deinit();
    const view = &mapped.worker;
    const host = &mapped.host;

    var scratch: [64]u8 = undefined;
    var lines: [4]page.DrainedLogLine = undefined;
    view.publishLogLine(.info, 0, 7, 100, "first");
    try std.testing.expectEqual(@as(usize, 1), try host.drainLogLinesChecked(&scratch, &lines));

    // The worker rewinds the page's copy of the tail; the next drain returns
    // only the line published after.
    @atomicStore(u64, &view.log_header.tail, 0, .release);
    view.publishLogLine(.info, 0, 7, 101, "second");
    try std.testing.expectEqual(@as(usize, 1), try host.drainLogLinesChecked(&scratch, &lines));
    try std.testing.expectEqualStrings("second", lines[0].payload);
    try std.testing.expectEqual(host.host_cursors.log_tail, @atomicLoad(u64, &view.log_header.tail, .acquire));
}

test "worker log ring truncates oversized payloads at a utf-8 boundary" {
    var mapped: MappedPage = undefined;
    try mapped.init("worker-log-ring-truncate");
    defer mapped.deinit();
    const view = &mapped.worker;
    const host = &mapped.host;

    var big: [page.LOG_LINE_BYTES_MAX + 1000]u8 = undefined;
    @memset(&big, 'a');
    // Multibyte char straddling the cut: the boundary backs off below the cap.
    const snowman = "\u{2603}"; // 3 bytes
    @memcpy(big[page.LOG_LINE_BYTES_MAX - 1 .. page.LOG_LINE_BYTES_MAX + 2], snowman);
    view.publishLogLine(.info, 0, 1, 1, &big);

    var scratch: [page.LOG_LINE_BYTES_MAX]u8 = undefined;
    var out: [1]page.DrainedLogLine = undefined;
    try std.testing.expectEqual(@as(usize, 1), try host.drainLogLinesChecked(&scratch, &out));
    try std.testing.expect(out[0].header.flags & page.LogLineFlags.truncated != 0);
    try std.testing.expectEqual(@as(usize, page.LOG_LINE_BYTES_MAX - 1), out[0].payload.len);
    try std.testing.expect(out[0].payload[out[0].payload.len - 1] == 'a');
}

test "worker log ring drops newest on overflow and counts drops" {
    var mapped: MappedPage = undefined;
    try mapped.init("worker-log-ring-overflow");
    defer mapped.deinit();
    const view = &mapped.worker;
    const host = &mapped.host;

    // 32 frames of exactly 4096 bytes (24 header + 4072 payload) fill the
    // 128 KiB ring completely.
    var payload: [page.LOG_LINE_BYTES_MAX - 24]u8 = undefined;
    @memset(&payload, 'x');
    var i: usize = 0;
    while (i < 32) : (i += 1)
        view.publishLogLine(.info, 0, i, i, &payload);
    try std.testing.expectEqual(@as(u64, 0), @atomicLoad(u64, &view.log_header.dropped_lines, .acquire));

    view.publishLogLine(.warn, 0, 99, 99, "dropped");
    const dropped = host.loadLogDropCounters();
    try std.testing.expectEqual(@as(u64, 1), dropped.lines);
    try std.testing.expectEqual(@as(u64, 7), dropped.bytes);

    var scratch: [page.LOG_LINE_BYTES_MAX]u8 = undefined;
    var out: [1]page.DrainedLogLine = undefined;
    var drained: usize = 0;
    var last_request_id: u64 = 0;
    // One drain more than the ring holds, so a drain that never empties it
    // fails the count instead of looping.
    for (0..33) |_| {
        if (try host.drainLogLinesChecked(&scratch, &out) == 0)
            break;
        last_request_id = out[0].header.request_id;
        drained += 1;
    }
    try std.testing.expectEqual(@as(usize, 32), drained);
    try std.testing.expectEqual(@as(u64, 31), last_request_id);

    // Space freed: the next publish lands again.
    view.publishLogLine(.info, 0, 100, 100, "after");
    try std.testing.expectEqual(@as(usize, 1), try host.drainLogLinesChecked(&scratch, &out));
    try std.testing.expectEqualStrings("after", out[0].payload);
}

test "a line published without waiting is dropped and counted while another producer holds the console ring" {
    var mapped: MappedPage = undefined;
    try mapped.init("worker-log-ring-try-publish");
    defer mapped.deinit();
    {
        // The test thread stands for a producer mid-line.
        page.log_producer_mutex.lock();
        defer page.log_producer_mutex.unlock();
        try std.testing.expect(!mapped.worker.tryPublishLogLine(.warn, page.LogLineFlags.runtime, 0, 1, "dropped"));
    }
    try std.testing.expect(mapped.worker.tryPublishLogLine(.warn, page.LogLineFlags.runtime, 0, 2, "kept"));

    var scratch: [page.LOG_LINE_BYTES_MAX]u8 = undefined;
    var lines: [2]page.DrainedLogLine = undefined;
    try std.testing.expectEqual(@as(usize, 1), try mapped.host.drainLogLinesChecked(&scratch, &lines));
    try std.testing.expectEqualStrings("kept", lines[0].payload);
    const dropped = mapped.host.loadLogDropCounters();
    try std.testing.expectEqual(@as(u64, 1), dropped.lines);
    try std.testing.expectEqual(@as(u64, "dropped".len), dropped.bytes);
}

test "worker log ring wraps frames across the buffer boundary" {
    var mapped: MappedPage = undefined;
    try mapped.init("worker-log-ring-wrap");
    defer mapped.deinit();
    const view = &mapped.worker;
    const host = &mapped.host;

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
        try std.testing.expectEqual(@as(usize, 1), try host.drainLogLinesChecked(&scratch, out[0..1]));
        try std.testing.expectEqualSlices(u8, &filler, out[0].payload);
        try std.testing.expectEqual(@as(u64, round), out[0].header.request_id);
    }
    try std.testing.expect(@atomicLoad(u64, &view.log_header.head, .acquire) > page.LOG_RING_BYTES);
    try std.testing.expectEqual(@as(u64, 0), host.loadLogDropCounters().lines);
}

test "worker log ring rejects hostile frame lengths fail-closed" {
    var mapped: MappedPage = undefined;
    try mapped.init("worker-log-ring-hostile");
    defer mapped.deinit();
    const view = &mapped.worker;
    const host = &mapped.host;

    view.publishLogLine(.info, 0, 1, 1, "victim");
    // Hostile worker rewrites the frame length in shared memory.
    std.mem.writeInt(u32, view.log_bytes[0..4], 0xffff_ffff, .little);

    var scratch: [page.LOG_LINE_BYTES_MAX]u8 = undefined;
    var out: [1]page.DrainedLogLine = undefined;
    try std.testing.expectError(error.InvalidLogFrame, host.drainLogLinesChecked(&scratch, &out));
    try std.testing.expectError(error.LogRingFatal, host.drainLogLinesChecked(&scratch, &out));
    // A fatal ring also stops accepting writes: head stays where the victim
    // frame left it (24-byte header + 6-byte payload).
    view.publishLogLine(.info, 0, 2, 2, "ignored");
    try std.testing.expectEqual(@as(u64, 30), @atomicLoad(u64, &view.log_header.head, .acquire));
}

test "worker log ring passes an out-of-range level byte through instead of failing fatal" {
    var mapped: MappedPage = undefined;
    try mapped.init("worker-log-ring-level");
    defer mapped.deinit();
    const view = &mapped.worker;
    const host = &mapped.host;

    view.publishLogLine(.info, 0, 1, 1, "hello");
    // Hostile worker rewrites the level byte (offset 4: after the u32
    // payload_len) to a value outside the LogLevel enum. Level is a display
    // attribute, not a frame invariant, so the drain must still succeed and
    // hand the raw byte to the consumer, which maps it to a default.
    view.log_bytes[4] = 0xff;

    var scratch: [page.LOG_LINE_BYTES_MAX]u8 = undefined;
    var out: [1]page.DrainedLogLine = undefined;
    try std.testing.expectEqual(@as(usize, 1), try host.drainLogLinesChecked(&scratch, &out));
    try std.testing.expectEqual(@as(u8, 0xff), out[0].header.level);
    try std.testing.expectEqualStrings("hello", out[0].payload);
    try std.testing.expectEqual(@as(u32, 0), @atomicLoad(u32, &view.log_header.fatal, .acquire));
}

test "worker log ring demands scratch for one full line" {
    var mapped: MappedPage = undefined;
    try mapped.init("worker-log-ring-scratch");
    defer mapped.deinit();
    const view = &mapped.worker;
    const host = &mapped.host;

    view.publishLogLine(.info, 0, 1, 1, "0123456789");
    var tiny: [4]u8 = undefined;
    var out: [1]page.DrainedLogLine = undefined;
    try std.testing.expectError(error.LogScratchTooSmall, host.drainLogLinesChecked(&tiny, &out));

    // Scratch smaller than the batch but big enough for one line drains
    // incrementally without loss.
    var one_line: [10]u8 = undefined;
    view.publishLogLine(.info, 0, 2, 2, "abcdefghij");
    try std.testing.expectEqual(@as(usize, 1), try host.drainLogLinesChecked(&one_line, &out));
    try std.testing.expectEqualStrings("0123456789", out[0].payload);
    try std.testing.expectEqual(@as(usize, 1), try host.drainLogLinesChecked(&one_line, &out));
    try std.testing.expectEqualStrings("abcdefghij", out[0].payload);
}

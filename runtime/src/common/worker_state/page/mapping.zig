//! The page as one memfd: its layout (`Page`), its creation by the host and
//! the view that maps it. Host and worker run the same binary, which keeps
//! both ends on one layout, and the comptime checks of each section and of
//! `Page` pin it. Every mapping checks the memfd's seals, its size and the
//! header's `VERSION`, so a descriptor that is not a page `createMemfd` made
//! fails the map. A new page reads zero everywhere, and a zero-filled section
//! reads as an empty one. The worker maps a `WorkerWriterView` at boot and
//! writes through it from its VM thread; the host maps one at launch and
//! reads every section through it, keeping its own cursors of the rings it
//! drains in the view (`HostCursors`).

const std = @import("std");
const fd_mod = @import("collo_os").fd;

const BOOT_PHASE_COUNT = @import("boot_stamps.zig").BOOT_PHASE_COUNT;
const BenchHandlerRecord = @import("boot_stamps.zig").BenchHandlerRecord;
const BootPhase = @import("boot_stamps.zig").BootPhase;
const loadBenchHandlerRecord = @import("boot_stamps.zig").loadBenchHandlerRecord;
const COMPLETION_RING_COUNT = @import("completion_ring.zig").COMPLETION_RING_COUNT;
const DrainError = @import("completion_ring.zig").DrainError;
const WorkerCompletionPublish = @import("completion_ring.zig").WorkerCompletionPublish;
const WorkerCompletionRecord = @import("completion_ring.zig").WorkerCompletionRecord;
const WorkerCompletionRingHeader = @import("completion_ring.zig").WorkerCompletionRingHeader;
const drainCompletionRing = @import("completion_ring.zig").drainWorkerCompletions;
const recordForPublish = @import("completion_ring.zig").recordForPublish;
const DrainedLogLine = @import("console_ring.zig").DrainedLogLine;
const LOG_RING_BYTES = @import("console_ring.zig").LOG_RING_BYTES;
const LogLevel = @import("console_ring.zig").LogLevel;
const LogRingHeader = @import("console_ring.zig").LogRingHeader;
const drainLogLinesImpl = @import("console_ring.zig").drainLogLinesImpl;
const publishLogLineImpl = @import("console_ring.zig").publishLogLineImpl;
const Header = @import("lifecycle.zig").Header;
const State = @import("lifecycle.zig").State;
const TerminationReason = @import("lifecycle.zig").TerminationReason;
const LIVE_SLOT_COUNT = @import("live_slots.zig").LIVE_SLOT_COUNT;
const LiveRequestSlot = @import("live_slots.zig").LiveRequestSlot;
const RecordCursor = @import("snapshots.zig").RecordCursor;
const CompletedRecord = @import("usage_records.zig").CompletedRecord;
const RECORD_RING_COUNT = @import("usage_records.zig").RECORD_RING_COUNT;

/// Written at memfd creation and checked by every mapping, which fails on a
/// page `createMemfd` never initialized.
pub const VERSION: u32 = 1;

pub const Page = extern struct {
    header: Header,
    live_slots: [LIVE_SLOT_COUNT]LiveRequestSlot,
    records: [RECORD_RING_COUNT]CompletedRecord,
    completion_header: WorkerCompletionRingHeader,
    completion_records: [COMPLETION_RING_COUNT]WorkerCompletionRecord,
    log_header: LogRingHeader,
    log_bytes: [LOG_RING_BYTES]u8,
    boot_phase_stamps_mono_ns: [BOOT_PHASE_COUNT]u64,
    bench_handler: BenchHandlerRecord,
};

/// The host's own positions in the three rings it drains. Each drain starts
/// from its cursor here, moves it, and stores it to the page for the worker's
/// room check; no host code loads one of those stores back, so a worker that
/// rewrites them misleads only itself. Worker code never reads or moves
/// these cursors.
pub const HostCursors = struct {
    /// The usage record ring's, under the worker record's `metrics_mutex`
    /// (`server/supervisor/worker_table.zig`).
    records: RecordCursor = .{},
    /// The completion ring's tail, used only by the worker's reader lane.
    completion_tail: u64 = 0,
    /// The console ring's tail, under the worker record's `metrics_mutex`.
    log_tail: u64 = 0,
};

/// A read-write mapping of a worker's page (`mapReadWrite`). The worker maps
/// one at boot and writes through it. The host maps one at launch and reads
/// every section through it: the lifecycle header and the live slots through
/// their snapshots, the rings through their drains.
pub const WorkerWriterView = struct {
    bytes: []align(std.heap.page_size_min) u8,
    page: *Page,
    header: *Header,
    live_slots: []LiveRequestSlot,
    completed_records: []CompletedRecord,
    completion_header: *WorkerCompletionRingHeader,
    completion_records: []WorkerCompletionRecord,
    log_header: *LogRingHeader,
    log_bytes: []u8,
    /// Host side only. A copy of the view copies the cursors, so every drain
    /// reaches the one view that holds them by pointer: the server's view
    /// moves into the worker's record before its first drain.
    host_cursors: HostCursors = .{},

    /// Unmaps the page. Copies of a view share its mapping, so only one of
    /// them may be deinitialized.
    pub fn deinit(self: *WorkerWriterView) void {
        if (self.bytes.len != 0)
            std.posix.munmap(self.bytes);
        self.* = undefined;
    }

    pub fn setState(self: *WorkerWriterView, state: State, reason: TerminationReason) void {
        // The reason goes first, so a reader that loads the new state with
        // acquire ordering and then the reason, as `LifecycleSnapshot.load`
        // does, sees the reason stored with it.
        @atomicStore(u32, &self.header.termination_reason, @intFromEnum(reason), .release);
        @atomicStore(u32, &self.header.state, @intFromEnum(state), .release);
    }

    /// Host side, at launch. Writes the whole header of a page `createMemfd`
    /// just made, with state `forked` and reason `crash`: a worker that dies
    /// before it stores a state of its own reads as crashed. A path that
    /// recycles a page memfd has to zero it first.
    pub fn initializeCrashDefault(
        self: *WorkerWriterView,
        pid: u32,
        memory_limit_bytes: u64,
        worker_started_mono_ns: u64,
    ) void {
        // A freshly truncated memfd reads zero everywhere, so only the header
        // is written. Zeroing the page instead would commit all `byteSize()`
        // bytes as shmem per worker, which never shows in the worker's
        // Private_Dirty because the mapping is shared.
        self.header.* = .{
            .version = VERSION,
            .pid = pid,
            .state = @intFromEnum(State.forked),
            .termination_reason = @intFromEnum(TerminationReason.crash),
            .memory_limit_bytes = memory_limit_bytes,
            .worker_started_mono_ns = worker_started_mono_ns,
            .metrics_dropped_count = 0,
            .records_head = 0,
            .records_tail = 0,
            ._reserved0 = 0,
        };
    }

    /// Worker side, from the VM thread. Writes the record, then moves `head`
    /// past it. A full ring counts the overflow, turns fatal and fails with
    /// `error.WorkerCompletionRingOverflow`; a record the host's drain would
    /// refuse fails without being published.
    pub fn publishWorkerCompletion(self: *WorkerWriterView, completion: WorkerCompletionPublish) !void {
        const head = @atomicLoad(u64, &self.completion_header.head, .acquire);
        const tail = @atomicLoad(u64, &self.completion_header.tail, .acquire);
        if (head -% tail >= COMPLETION_RING_COUNT) {
            _ = @atomicRmw(u64, &self.completion_header.overflow_count, .Add, 1, .release);
            @atomicStore(u32, &self.completion_header.fatal, 1, .release);
            return error.WorkerCompletionRingOverflow;
        }
        const record = try recordForPublish(head, completion);
        self.completion_records[@intCast(head % COMPLETION_RING_COUNT)] = record;
        @atomicStore(u64, &self.completion_header.head, record.sequence, .release);
    }

    /// Host side, by the ring's one reader. Copies up to `out.len` completions
    /// from the host's tail (`HostCursors.completion_tail`), validated, and
    /// moves the tail past them; fails as `drainWorkerCompletions` in
    /// `completion_ring.zig` does.
    pub fn drainWorkerCompletions(self: *WorkerWriterView, out: []WorkerCompletionRecord) DrainError!usize {
        return drainCompletionRing(
            self.completion_header,
            self.completion_records,
            &self.host_cursors.completion_tail,
            out,
        );
    }

    /// Lossy append from the VM thread, the ring's only producer. A payload
    /// above `LOG_LINE_BYTES_MAX` is cut at a UTF-8 boundary and flagged
    /// truncated, and flag bits outside `LogLineFlags` are dropped. A full
    /// ring drops the line and counts it; a fatal ring drops it uncounted. It
    /// never fails, so writing a console line carries no error back into user
    /// code.
    pub fn publishLogLine(
        self: *WorkerWriterView,
        level: LogLevel,
        flags: u8,
        request_id: u64,
        ts_mono_ns: u64,
        payload: []const u8,
    ) void {
        publishLogLineImpl(self.log_header, self.log_bytes, level, flags, request_id, ts_mono_ns, payload);
    }

    /// Host side, by the ring's one consumer. Copies up to `out.len` lines,
    /// their payloads into `scratch`, and moves the host's tail past them;
    /// returns how many it copied. Fails with `error.LogScratchTooSmall` when
    /// the first line does not fit `scratch`. A corrupt cursor or frame turns
    /// the ring fatal and fails this drain and every later one.
    pub fn drainLogLinesChecked(
        self: *WorkerWriterView,
        scratch: []u8,
        out: []DrainedLogLine,
    ) !usize {
        return drainLogLinesImpl(self.log_header, self.log_bytes, &self.host_cursors.log_tail, scratch, out);
    }

    /// Counts one line the per-request console budget suppressed, in the
    /// counter the ring's own drops use, so the host's drop marker reports
    /// both causes. VM thread only, like `publishLogLine`.
    pub fn countBudgetDroppedLogLine(self: *WorkerWriterView) void {
        _ = @atomicRmw(u64, &self.log_header.dropped_lines, .Add, 1, .release);
    }

    /// The drop counters the host reports in its "N lines dropped" marker.
    pub fn loadLogDropCounters(self: *const WorkerWriterView) struct { lines: u64, bytes: u64 } {
        return .{
            .lines = @atomicLoad(u64, &self.log_header.dropped_lines, .acquire),
            .bytes = @atomicLoad(u64, &self.log_header.dropped_bytes, .acquire),
        };
    }

    /// Worker side, from the VM thread. Only the first record with a nonzero
    /// request id and start time lands, so a later request cannot overwrite
    /// the cold one while the host collects its sample. `request_id` is
    /// stored last, with release ordering, and marks the record complete.
    pub fn publishBenchHandler(self: *WorkerWriterView, record: BenchHandlerRecord) void {
        if (record.request_id == 0 or record.handler_started_ns == 0)
            return;
        const dest = &self.page.bench_handler;
        if (@atomicLoad(u64, &dest.request_id, .acquire) != 0)
            return;
        @atomicStore(u64, &dest.worker_id, record.worker_id, .monotonic);
        @atomicStore(u64, &dest.worker_generation, record.worker_generation, .monotonic);
        @atomicStore(u64, &dest.handler_started_ns, record.handler_started_ns, .monotonic);
        @atomicStore(u64, &dest.request_id, record.request_id, .release);
    }

    pub fn loadBenchHandler(self: *const WorkerWriterView) ?BenchHandlerRecord {
        return loadBenchHandlerRecord(&self.page.bench_handler);
    }

    pub fn storeBootPhaseStampNs(self: *WorkerWriterView, phase: BootPhase, now_mono_ns: u64) void {
        @atomicStore(
            u64,
            &self.page.boot_phase_stamps_mono_ns[@intFromEnum(phase)],
            now_mono_ns,
            .release,
        );
    }

    /// Copies the stamps the child buffered before it mapped the page, every
    /// phase before `metrics_mapped`. A zero slot is a phase that did not run
    /// and is skipped.
    pub fn storeBootPhaseStamps(self: *WorkerWriterView, stamps: *const [BOOT_PHASE_COUNT]u64) void {
        for (stamps, 0..) |stamp_ns, index| {
            if (stamp_ns == 0)
                continue;
            @atomicStore(u64, &self.page.boot_phase_stamps_mono_ns[index], stamp_ns, .release);
        }
    }

    pub fn loadBootPhaseStampNs(self: *const WorkerWriterView, phase: BootPhase) u64 {
        return @atomicLoad(
            u64,
            &self.page.boot_phase_stamps_mono_ns[@intFromEnum(phase)],
            .acquire,
        );
    }
};

pub fn byteSize() usize {
    return @sizeOf(Page);
}

pub fn validateInitialized(page: *const Page) !void {
    if (page.header.version != VERSION)
        return error.InvalidMetricsPage;
}

/// Creates a close-on-exec page memfd of `byteSize()` bytes with only the
/// header's `version` written; the caller owns the fd. It is sealed against
/// shrinking and growing, so the worker cannot truncate the file under the
/// host's mapping, where an access past the new end would raise SIGBUS.
pub fn createMemfd(name: []const u8) !std.posix.fd_t {
    const fd = try std.posix.memfd_create(
        name,
        std.os.linux.MFD.CLOEXEC | std.os.linux.MFD.ALLOW_SEALING,
    );
    errdefer std.posix.close(fd);

    try std.posix.ftruncate(fd, byteSize());

    var header = std.mem.zeroes(Header);
    header.version = VERSION;
    const written = try std.posix.pwrite(fd, std.mem.asBytes(&header), 0);
    if (written != @sizeOf(Header))
        return error.ShortWrite;

    try fd_mod.addSeals(fd, fd_mod.memfd_size_seals);
    return fd;
}

pub fn validateMemfd(fd: std.posix.fd_t) !void {
    try fd_mod.requireSeals(fd, fd_mod.memfd_size_seals);
    const stat = try std.posix.fstat(fd);
    if (@as(usize, @intCast(stat.size)) != byteSize())
        return error.InvalidMetricsPage;
}

/// Maps the page in `fd`, which stays the caller's, after checking its seals,
/// size and `VERSION`; the returned view owns the mapping.
pub fn mapReadWrite(fd: std.posix.fd_t) !WorkerWriterView {
    try validateMemfd(fd);
    const bytes = try std.posix.mmap(
        null,
        byteSize(),
        std.posix.PROT.READ | std.posix.PROT.WRITE,
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    errdefer std.posix.munmap(bytes);
    return writerViewFromBytes(bytes);
}

fn writerViewFromBytes(bytes: []align(std.heap.page_size_min) u8) !WorkerWriterView {
    if (bytes.len != @sizeOf(Page))
        return error.InvalidMetricsPage;

    const page: *Page = @ptrCast(@alignCast(bytes.ptr));
    try validateInitialized(page);

    return .{
        .bytes = bytes,
        .page = page,
        .header = &page.header,
        .live_slots = page.live_slots[0..],
        .completed_records = page.records[0..],
        .completion_header = &page.completion_header,
        .completion_records = page.completion_records[0..],
        .log_header = &page.log_header,
        .log_bytes = page.log_bytes[0..],
    };
}

comptime {
    if (@sizeOf(Page) != 288_544)
        @compileError("worker_state.page.Page size mismatch");
    if (@offsetOf(Page, "completion_records") != 155_936)
        @compileError("worker_state.page completion records offset mismatch");
    if (@offsetOf(Page, "log_bytes") <= @offsetOf(Page, "log_header"))
        @compileError("worker_state.page log bytes must follow the log ring header");
}

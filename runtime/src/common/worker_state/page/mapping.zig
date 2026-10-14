//! The page as one memfd: its layout (`Page`), its creation by the host and
//! the two views that map it. Host and worker run the same binary, which
//! keeps both ends on one layout, and the comptime checks of each section and
//! of `Page` pin it. Every mapping checks the memfd's seals, its size and the
//! header's `VERSION`, so a descriptor that is not a page `createMemfd` made
//! fails the map. A new page holds the header `createMemfd` wrote and reads
//! zero everywhere else, and a zero-filled section reads as an empty one.
//!
//! The worker maps a `WorkerWriterView` at boot and writes every section
//! through it. The host maps a `HostReaderView` at launch, which reaches the
//! page only through the snapshots (`snapshots.zig`), the console drain, the
//! boot stamps and the benchmark record, and keeps the host's own cursor of
//! the console ring (`HostCursors`). Host code holds no `WorkerWriterView`,
//! which `runtime/tests/conventions.zig` checks, so the compiler keeps it
//! from loading a page field twice or reading one past its checks.

const std = @import("std");
const fd_mod = @import("collo_os").fd;

const BOOT_PHASE_COUNT = @import("boot_stamps.zig").BOOT_PHASE_COUNT;
const BenchHandlerRecord = @import("boot_stamps.zig").BenchHandlerRecord;
const BootPhase = @import("boot_stamps.zig").BootPhase;
const loadBenchHandlerRecord = @import("boot_stamps.zig").loadBenchHandlerRecord;
const DrainedLogLine = @import("console_ring.zig").DrainedLogLine;
const LOG_RING_BYTES = @import("console_ring.zig").LOG_RING_BYTES;
const LogLevel = @import("console_ring.zig").LogLevel;
const LogRingHeader = @import("console_ring.zig").LogRingHeader;
const drainLogLinesImpl = @import("console_ring.zig").drainLogLinesImpl;
const publishLogLineImpl = @import("console_ring.zig").publishLogLineImpl;
const tryPublishLogLineImpl = @import("console_ring.zig").tryPublishLogLineImpl;
const Header = @import("lifecycle.zig").Header;
const State = @import("lifecycle.zig").State;
const TerminationReason = @import("lifecycle.zig").TerminationReason;
const LIVE_SLOT_COUNT = @import("live_slots.zig").LIVE_SLOT_COUNT;
const LiveRequestSlot = @import("live_slots.zig").LiveRequestSlot;
const live_slot_count_page_zero_max = @import("live_slots.zig").live_slot_count_page_zero_max;
const LifecycleSnapshot = @import("snapshots.zig").LifecycleSnapshot;
const LiveSlotSnapshot = @import("snapshots.zig").LiveSlotSnapshot;
const OwnerSnapshot = @import("snapshots.zig").OwnerSnapshot;
const RunningOwnerSnapshot = @import("snapshots.zig").RunningOwnerSnapshot;

/// Written at memfd creation and checked by every mapping, which fails on a
/// page `createMemfd` never initialized.
pub const VERSION: u32 = 1;

/// The page's sections. Everything but the console ring's bytes sits in the
/// first 4 KiB page, which the host's launch writes anyway: the header, the
/// live slots, the console ring's header, the boot stamps and the benchmark
/// record, as the comptime block at the end of this file pins. The console
/// ring comes last, and a worker touches it only as far as it has written
/// into it.
pub const Page = extern struct {
    header: Header,
    live_slots: [LIVE_SLOT_COUNT]LiveRequestSlot,
    log_header: LogRingHeader,
    boot_phase_stamps_mono_ns: [BOOT_PHASE_COUNT]u64,
    bench_handler: BenchHandlerRecord,
    log_bytes: [LOG_RING_BYTES]u8,
};

/// The host's own position in the console ring it drains. The drain starts
/// from it, moves it, and stores it to the page for the worker's room check;
/// no host code loads that store back, so a worker that rewrites it misleads
/// only itself. Worker code never reads or moves it.
pub const HostCursors = struct {
    /// The console ring's tail, under the worker record's `metrics_mutex`
    /// (`server/supervisor/worker_table.zig`).
    log_tail: u64 = 0,
};

/// The host's mapping of a worker's page (`mapHostReader`), held from launch
/// to the worker's end. It reaches the page only through the methods below,
/// each of which loads what it returns once; the mapping itself is an opaque
/// handle, so host code cannot name a page field. The mapping is writable
/// because the console drain stores the host's tail and the ring's fatal
/// flag there; no other method writes.
pub const HostReaderView = struct {
    mapping: *align(std.heap.page_size_min) HostMapping,
    /// A copy of the view copies the cursor, so every drain reaches the one
    /// view that holds it by pointer: the server's view moves into the
    /// worker's record before its first drain.
    host_cursors: HostCursors = .{},

    const HostMapping = opaque {};

    /// Unmaps the page. Copies of a view share its mapping, so only one of
    /// them may be deinitialized.
    pub fn deinit(self: *HostReaderView) void {
        const bytes: [*]align(std.heap.page_size_min) u8 = @ptrCast(self.mapping);
        std.posix.munmap(bytes[0..byteSize()]);
        self.* = undefined;
    }

    pub fn loadLifecycle(self: *const HostReaderView) LifecycleSnapshot {
        return LifecycleSnapshot.load(&self.page().header);
    }

    pub fn loadOwner(self: *const HostReaderView) OwnerSnapshot {
        return OwnerSnapshot.load(&self.page().header);
    }

    pub fn loadRunningOwner(self: *const HostReaderView) ?RunningOwnerSnapshot {
        return RunningOwnerSnapshot.load(&self.page().header);
    }

    /// The live slot at `index`, a pool slot the host dispatched on, under
    /// the caller rule `LiveSlotSnapshot.at` states.
    pub fn loadLiveSlot(self: *const HostReaderView, index: usize) LiveSlotSnapshot {
        return LiveSlotSnapshot.at(self.page(), index);
    }

    /// By the ring's one consumer. Copies up to `out.len` lines, their
    /// payloads into `scratch`, and moves the host's tail past them; returns
    /// how many it copied. Fails with `error.LogScratchTooSmall` when the
    /// first line does not fit `scratch`. A corrupt cursor or frame turns the
    /// ring fatal and fails this drain and every later one.
    pub fn drainLogLinesChecked(
        self: *HostReaderView,
        scratch: []u8,
        out: []DrainedLogLine,
    ) !usize {
        const target = self.page();
        return drainLogLinesImpl(&target.log_header, target.log_bytes[0..], &self.host_cursors.log_tail, scratch, out);
    }

    /// The drop counters the host reports in its "N lines dropped" marker.
    pub fn loadLogDropCounters(self: *const HostReaderView) struct { lines: u64, bytes: u64 } {
        const log_header = &self.page().log_header;
        return .{
            .lines = @atomicLoad(u64, &log_header.dropped_lines, .acquire),
            .bytes = @atomicLoad(u64, &log_header.dropped_bytes, .acquire),
        };
    }

    /// The stamp of `phase`, 0 when the child has not reached it. A
    /// diagnostic: the child can write any value.
    pub fn loadBootPhaseStampNs(self: *const HostReaderView, phase: BootPhase) u64 {
        return @atomicLoad(
            u64,
            &self.page().boot_phase_stamps_mono_ns[@intFromEnum(phase)],
            .acquire,
        );
    }

    /// The first instrumented handler call, or null before the worker
    /// published one. A diagnostic: the consumer matches every identity in it
    /// against its own records (`BenchHandlerRecord`).
    pub fn loadBenchHandler(self: *const HostReaderView) ?BenchHandlerRecord {
        return loadBenchHandlerRecord(&self.page().bench_handler);
    }

    fn page(self: *const HostReaderView) *Page {
        return @ptrCast(self.mapping);
    }
};

/// The worker's mapping of its page (`mapWorkerWriter`), through which its
/// threads write every section, as each method names. Host code never holds
/// one (`HostReaderView`); a test that plays the worker does.
pub const WorkerWriterView = struct {
    bytes: []align(std.heap.page_size_min) u8,
    page: *Page,
    header: *Header,
    log_header: *LogRingHeader,
    log_bytes: []u8,

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

    /// Worker side, from the VM thread once its startup evaluations all
    /// ended (`worker/runtime/evaluations.zig`).
    pub fn publishStartupEvaluationsEnded(self: *WorkerWriterView) void {
        @atomicStore(u32, &self.header.startup_evaluations_ended, 1, .release);
    }

    /// Worker side, from the VM thread at every owner change: the owner the
    /// VM thread now works for and that owner's wall deadline
    /// (CLOCK_MONOTONIC), both 0 while it works for none. The two are stored
    /// one after the other; `OwnerSnapshot` says what a host load of them
    /// may see.
    pub fn publishOwner(self: *WorkerWriterView, owner_id: u64, deadline_mono_ns: u64) void {
        @atomicStore(u64, &self.header.owner_deadline_mono_ns, deadline_mono_ns, .release);
        @atomicStore(u64, &self.header.owner_id, owner_id, .release);
    }

    /// Worker side, from the sentinel thread only: the CPU the owner
    /// `owner_id` has used, its CPU before the window that runs plus that
    /// window so far. The sequence is odd across the two stores and even
    /// after them, so a host load that finds the same even sequence before
    /// and after it read the pair read both from one call
    /// (`RunningOwnerSnapshot.load`).
    pub fn publishRunningOwnerCpu(self: *WorkerWriterView, owner_id: u64, cpu_ns: u64) void {
        const odd = @atomicLoad(u32, &self.header.running_owner_sequence, .monotonic) | 1;
        @atomicStore(u32, &self.header.running_owner_sequence, odd, .monotonic);
        // Release orders the odd sequence before each value, so a host that
        // loads a value of this call also loads a sequence other than the
        // even one it started from.
        @atomicStore(u64, &self.header.running_owner_id, owner_id, .release);
        @atomicStore(u64, &self.header.running_owner_cpu_ns, cpu_ns, .release);
        @atomicStore(u32, &self.header.running_owner_sequence, odd +% 1, .release);
    }

    /// Worker side, from the VM thread, when it takes a dispatched request:
    /// the live slot at `index`, the request's `DispatchWork.worker_slot`,
    /// now holds the request with no CPU yet, replacing the last request
    /// begun on that pool slot. The CPU, the generation and the id are
    /// stored in that order, each with release ordering, the reverse of the
    /// order `LiveSlotSnapshot.at` loads them.
    pub fn beginLiveSlot(self: *WorkerWriterView, index: usize, request_id: u64, request_generation: u64) void {
        std.debug.assert(request_id != 0);
        const slot = self.liveSlot(index);
        @atomicStore(u64, &slot.cpu_ns, 0, .release);
        @atomicStore(u64, &slot.request_generation, request_generation, .release);
        @atomicStore(u64, &slot.request_id, request_id, .release);
    }

    /// Worker side, from the VM thread: the CPU the request `request_id` has
    /// used so far, which the host reports if it ends the request before the
    /// worker finishes it. Nothing when the slot at `index` holds another
    /// request, so a store that a request makes after a later begin on its
    /// pool slot never lands in the later request's CPU.
    pub fn storeLiveSlotCpu(self: *WorkerWriterView, index: usize, request_id: u64, cpu_ns: u64) void {
        std.debug.assert(request_id != 0);
        const slot = self.liveSlot(index);
        if (@atomicLoad(u64, &slot.request_id, .monotonic) != request_id)
            return;
        @atomicStore(u64, &slot.cpu_ns, cpu_ns, .release);
    }

    /// The slot at `index`. The worker writes only slots its dispatches name,
    /// which their decoder bounds (`common/ipc/dispatch.zig`).
    fn liveSlot(self: *WorkerWriterView, index: usize) *LiveRequestSlot {
        std.debug.assert(index < LIVE_SLOT_COUNT);
        return &self.page.live_slots[index];
    }

    /// Lossy append. Any thread may call it: producers serialize on the
    /// ring's lock. A payload above `LOG_LINE_BYTES_MAX` is cut at a UTF-8
    /// boundary and flagged truncated, and flag bits outside `LogLineFlags`
    /// are dropped. A full ring drops the line and counts it; a fatal ring
    /// drops it uncounted. It never fails, so writing a console line carries
    /// no error back into user code.
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

    /// `publishLogLine` for a thread that must never wait for another
    /// (`zygote/log_sink.zig:never_wait_scope`): when another producer holds
    /// the ring's lock, the line is dropped and counted as a full ring's
    /// would be, and the call returns false.
    pub fn tryPublishLogLine(
        self: *WorkerWriterView,
        level: LogLevel,
        flags: u8,
        request_id: u64,
        ts_mono_ns: u64,
        payload: []const u8,
    ) bool {
        return tryPublishLogLineImpl(self.log_header, self.log_bytes, level, flags, request_id, ts_mono_ns, payload);
    }

    /// Counts one line the per-request console budget suppressed, in the
    /// counter the ring's own drops use, so the host's drop marker reports
    /// both causes.
    pub fn countBudgetDroppedLogLine(self: *WorkerWriterView) void {
        _ = @atomicRmw(u64, &self.log_header.dropped_lines, .Add, 1, .release);
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
};

pub fn byteSize() usize {
    return @sizeOf(Page);
}

pub fn validateInitialized(page: *const Page) !void {
    if (page.header.version != VERSION)
        return error.InvalidMetricsPage;
}

/// Creates a close-on-exec page memfd of `byteSize()` bytes and writes its
/// header, `VERSION` with state `forked` and reason `crash`, so a worker that
/// dies before it stores a state of its own reads as crashed; the caller
/// owns the fd. It is sealed against shrinking and growing, so the worker
/// cannot truncate the file under the host's mapping, where an access past
/// the new end would raise SIGBUS.
pub fn createMemfd(name: []const u8) !std.posix.fd_t {
    const fd = try std.posix.memfd_create(
        name,
        std.os.linux.MFD.CLOEXEC | std.os.linux.MFD.ALLOW_SEALING,
    );
    errdefer std.posix.close(fd);

    try std.posix.ftruncate(fd, byteSize());

    // A truncated memfd reads zero everywhere, so only the header is
    // written. Zeroing the page instead would commit all `byteSize()` bytes
    // as shmem per worker, which never shows in the worker's Private_Dirty
    // because the mapping is shared.
    var header = std.mem.zeroes(Header);
    header.version = VERSION;
    header.state = @intFromEnum(State.forked);
    header.termination_reason = @intFromEnum(TerminationReason.crash);
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

/// The worker's mapping of the page in `fd`, which stays the caller's, after
/// checking its seals, size and `VERSION`; the returned view owns the
/// mapping.
pub fn mapWorkerWriter(fd: std.posix.fd_t) !WorkerWriterView {
    const bytes = try mapChecked(fd);
    const target: *Page = @ptrCast(bytes.ptr);
    return .{
        .bytes = bytes,
        .page = target,
        .header = &target.header,
        .log_header = &target.log_header,
        .log_bytes = target.log_bytes[0..],
    };
}

/// The host's mapping of the page in `fd`, which stays the caller's, with
/// the same checks as `mapWorkerWriter`; the returned view owns the mapping.
pub fn mapHostReader(fd: std.posix.fd_t) !HostReaderView {
    const bytes = try mapChecked(fd);
    return .{ .mapping = @ptrCast(bytes.ptr) };
}

/// Maps `fd` shared and writable after checking its seals, its size and the
/// header's `VERSION`.
fn mapChecked(fd: std.posix.fd_t) ![]align(std.heap.page_size_min) u8 {
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
    std.debug.assert(bytes.len == @sizeOf(Page));
    try validateInitialized(@ptrCast(bytes.ptr));
    return bytes;
}

/// The memory page size the first-touch pins below count in: the smallest
/// either target uses.
const first_touch_page_bytes: usize = 4096;

/// The 4 KiB page that holds `field`'s last byte.
fn lastPageOf(comptime field: []const u8) usize {
    const end = @offsetOf(Page, field) + @sizeOf(@FieldType(Page, field));
    return (end - 1) / first_touch_page_bytes;
}

comptime {
    if (@sizeOf(Page) != 131_744)
        @compileError("worker_state.page.Page size mismatch");
    if (@offsetOf(Page, "live_slots") != 56)
        @compileError("worker_state.page live slots offset mismatch");
    if (@offsetOf(Page, "log_header") != 440)
        @compileError("worker_state.page log header offset mismatch");
    if (@offsetOf(Page, "boot_phase_stamps_mono_ns") != 504)
        @compileError("worker_state.page boot stamps offset mismatch");
    if (@offsetOf(Page, "bench_handler") != 640)
        @compileError("worker_state.page bench record offset mismatch");
    if (@offsetOf(Page, "log_bytes") != 672)
        @compileError("worker_state.page log bytes offset mismatch");

    // The first touches: page 0, which the host's launch writes, holds every
    // section before the console ring's bytes.
    if (lastPageOf("bench_handler") != 0)
        @compileError("worker_state.page every section before the console bytes must sit in the first 4 KiB page");
    // A layout with `live_slot_count_page_zero_max` live slots would still
    // keep those sections in page 0, so a higher concurrency maximum up to it
    // needs no layout change and no page more per worker.
    const page_zero_bytes_at_max = @sizeOf(Header) +
        live_slot_count_page_zero_max * @sizeOf(LiveRequestSlot) +
        @sizeOf(LogRingHeader) +
        @sizeOf([BOOT_PHASE_COUNT]u64) +
        @sizeOf(BenchHandlerRecord);
    if (page_zero_bytes_at_max > first_touch_page_bytes)
        @compileError("worker_state.page the header and the maximum live slots must fit the first 4 KiB page");
}

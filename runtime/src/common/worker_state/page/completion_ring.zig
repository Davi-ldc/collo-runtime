//! The completion ring: one record per finished request, which the worker's
//! VM thread publishes (`WorkerWriterView.publishWorkerCompletion`) before it
//! signals the completion eventfd, and which the ingress lane that reads the
//! worker drains through the host's mapping of the page.
//!
//! Every record is the worker's claim, and the drain reads it once. The drain
//! loads the worker's `head` once, keeps its own tail in host memory and
//! stores it to the page without reading it back, copies each record with one
//! load per field, validates the copy and hands that same copy on. The reader
//! drains the whole ring on every wake of the completion eventfd, so the ring
//! holds only what the worker published since the last wake.

const std = @import("std");

const LIVE_SLOT_COUNT = @import("live_slots.zig").LIVE_SLOT_COUNT;

/// Completions the worker can publish ahead of the host's drain. A lane can
/// give a worker slot back before it drains that request's completion, when
/// the client resets the stream for instance, and the pool can then send the
/// worker another request, so twice `LIVE_SLOT_COUNT` completions can wait
/// at once; `completion_ring_slack` covers the drain's latency. The count is
/// a power of two so that a record's index stays continuous when the 64-bit
/// sequence wraps. A full ring turns fatal
/// (`WorkerWriterView.publishWorkerCompletion`), and the lane faults the
/// worker.
pub const COMPLETION_RING_COUNT: usize =
    std.math.ceilPowerOfTwoAssert(usize, 2 * LIVE_SLOT_COUNT + completion_ring_slack);
const completion_ring_slack: usize = 8;

/// The largest tag of `RequestDoneStatus` in `common/ipc/messages.zig`, which
/// the worker publishes as a completion's status; the drain refuses a larger
/// one. This module does not import the IPC module, so
/// `runtime/tests/contracts/limits.zig` asserts that the two agree.
pub const worker_completion_status_max: u32 = 6;

/// One finished request as the worker publishes it and the host drains it.
pub const WorkerCompletionRecord = extern struct {
    /// One more than the record's ring position.
    sequence: u64,
    external_request_id: u64,
    request_generation: u64,
    worker_id: u64,
    worker_generation: u64,
    request_slot: u32,
    request_lane_id: u16,
    http_status: u16,
    status: u32,
    _reserved0: u32 = 0,
    /// The request's timeline, sealed by the worker when the request
    /// finishes. It rides this ring as well as the usage ring because the
    /// host writes the access record where it reads completions, on the side
    /// that knows the route. Zero on a completion that measured nothing.
    ///
    /// `cpu_time_ns` here is the turn clock (`CompletedRecord.turn_cpu_ns`),
    /// not the process delta that shares its name on the usage record. The
    /// process delta folds a worker's module evaluation into its first record
    /// and charges a co-scheduled request's work so far to whichever request
    /// finishes first, which is right for a worker's total and wrong for one
    /// request.
    cpu_time_ns: u64 = 0,
    io_time_ns: u64 = 0,
    waiting_ns: u64 = 0,
};

/// What the worker passes to `WorkerWriterView.publishWorkerCompletion`.
pub const WorkerCompletionPublish = struct {
    external_request_id: u64,
    request_lane_id: u16,
    request_slot: u32,
    request_generation: u64,
    worker_id: u64,
    worker_generation: u64,
    status: u32,
    http_status: u16,
    cpu_time_ns: u64 = 0,
    io_time_ns: u64 = 0,
    waiting_ns: u64 = 0,
};

/// The completion ring's cursors: the worker moves `head` past each record
/// it publishes, and `tail` is the copy of the host's tail that the host
/// stores after each drain and never reads back. The worker sets `fatal` when
/// the ring overflows, counting the overflow, and the host sets it when a
/// drain finds a bad record; a fatal ring fails every later drain with
/// `error.WorkerCompletionRingFatal`.
pub const WorkerCompletionRingHeader = extern struct {
    head: u64,
    tail: u64,
    overflow_count: u64,
    fatal: u32,
    _reserved0: u32,
    _reserved1: [4]u64,
};

/// How a drain fails. The lane counts each as a worker fault
/// (`classifyCompletion` in `server/ingress/fault.zig`).
pub const DrainError = error{
    WorkerCompletionRingFatal,
    WorkerCompletionRingCorrupt,
    WorkerCompletionSequenceMismatch,
    InvalidWorkerCompletionRecord,
    InvalidWorkerCompletionStatus,
};

/// Host side, by the ring's one reader. Copies the records between `tail.*`,
/// the host's own tail, and the worker's head into `out`, up to `out.len`,
/// moves `tail.*` past them, stores it to the page and returns how many it
/// copied. Each record is loaded once, field by field, and `out` receives the
/// copy that passed validation. A head more than `COMPLETION_RING_COUNT`
/// records past the tail, a record out of sequence or one that fails
/// validation turns the ring fatal and fails the drain without moving the
/// tail.
pub fn drainWorkerCompletions(
    header: *WorkerCompletionRingHeader,
    records: []const WorkerCompletionRecord,
    tail: *u64,
    out: []WorkerCompletionRecord,
) DrainError!usize {
    std.debug.assert(records.len == COMPLETION_RING_COUNT);
    if (@atomicLoad(u32, &header.fatal, .acquire) != 0)
        return error.WorkerCompletionRingFatal;

    const head = @atomicLoad(u64, &header.head, .acquire);
    const occupancy = head -% tail.*;
    if (occupancy > COMPLETION_RING_COUNT) {
        @atomicStore(u32, &header.fatal, 1, .release);
        return error.WorkerCompletionRingCorrupt;
    }
    const count: usize = @min(out.len, @as(usize, @intCast(occupancy)));
    var cursor = tail.*;
    for (out[0..count]) |*copy| {
        const expected_sequence = cursor +% 1;
        copy.* = loadWorkerCompletionRecord(&records[@intCast(cursor % COMPLETION_RING_COUNT)]);
        if (copy.sequence != expected_sequence) {
            @atomicStore(u32, &header.fatal, 1, .release);
            return error.WorkerCompletionSequenceMismatch;
        }
        validateWorkerCompletionRecord(copy) catch |err| {
            @atomicStore(u32, &header.fatal, 1, .release);
            return err;
        };
        cursor = expected_sequence;
    }
    tail.* = cursor;
    @atomicStore(u64, &header.tail, cursor, .release);
    return count;
}

/// Worker side, from the VM thread: the record `completion` describes at
/// ring position `head`, checked as the host's drain checks it.
pub fn recordForPublish(head: u64, completion: WorkerCompletionPublish) error{
    InvalidWorkerCompletionRecord,
    InvalidWorkerCompletionStatus,
}!WorkerCompletionRecord {
    const record = WorkerCompletionRecord{
        .sequence = head +% 1,
        .external_request_id = completion.external_request_id,
        .request_generation = completion.request_generation,
        .worker_id = completion.worker_id,
        .worker_generation = completion.worker_generation,
        .request_slot = completion.request_slot,
        .request_lane_id = completion.request_lane_id,
        .http_status = completion.http_status,
        .status = completion.status,
        .cpu_time_ns = completion.cpu_time_ns,
        .io_time_ns = completion.io_time_ns,
        .waiting_ns = completion.waiting_ns,
    };
    try validateWorkerCompletionRecord(&record);
    return record;
}

pub fn signalCompletionEventfd(fd: std.posix.fd_t) !void {
    const value: u64 = 1;
    const written = try std.posix.write(fd, std.mem.asBytes(&value));
    if (written != @sizeOf(u64))
        return error.ShortWrite;
}

pub fn drainCompletionEventfd(fd: std.posix.fd_t) !u64 {
    var value: u64 = 0;
    const read_len = try std.posix.read(fd, std.mem.asBytes(&value));
    if (read_len != @sizeOf(u64))
        return error.ShortRead;
    return value;
}

fn loadWorkerCompletionRecord(src: *const WorkerCompletionRecord) WorkerCompletionRecord {
    return .{
        .sequence = @atomicLoad(u64, &src.sequence, .monotonic),
        .external_request_id = @atomicLoad(u64, &src.external_request_id, .monotonic),
        .request_generation = @atomicLoad(u64, &src.request_generation, .monotonic),
        .worker_id = @atomicLoad(u64, &src.worker_id, .monotonic),
        .worker_generation = @atomicLoad(u64, &src.worker_generation, .monotonic),
        .request_slot = @atomicLoad(u32, &src.request_slot, .monotonic),
        .request_lane_id = @atomicLoad(u16, &src.request_lane_id, .monotonic),
        .http_status = @atomicLoad(u16, &src.http_status, .monotonic),
        .status = @atomicLoad(u32, &src.status, .monotonic),
        ._reserved0 = @atomicLoad(u32, &src._reserved0, .monotonic),
        .cpu_time_ns = @atomicLoad(u64, &src.cpu_time_ns, .monotonic),
        .io_time_ns = @atomicLoad(u64, &src.io_time_ns, .monotonic),
        .waiting_ns = @atomicLoad(u64, &src.waiting_ns, .monotonic),
    };
}

fn validateWorkerCompletionRecord(record: *const WorkerCompletionRecord) error{
    InvalidWorkerCompletionRecord,
    InvalidWorkerCompletionStatus,
}!void {
    if (record.status > worker_completion_status_max)
        return error.InvalidWorkerCompletionStatus;
    if (record.http_status < 200 or record.http_status > 599)
        return error.InvalidWorkerCompletionStatus;
    if (record._reserved0 != 0)
        return error.InvalidWorkerCompletionRecord;
    // The timeline fields are not validated: only the worker can measure
    // them, and the usage ring carries the same worker-written numbers. A
    // forged value distorts that worker's own records and breaks no
    // structural invariant. The access record's wall duration comes from the
    // lane's clock. Its status is `http_status`, which the lane replaces with
    // a 502 only when the worker completed without a response head on a
    // stream still open and not reset (`completionLeftNoAnswer` in
    // `server/ingress/runner/request_finish.zig`).
}

comptime {
    if (@sizeOf(WorkerCompletionRecord) != 80)
        @compileError("worker_state.page.WorkerCompletionRecord size mismatch");
    if (@offsetOf(WorkerCompletionRecord, "request_slot") != 40)
        @compileError("worker_state.page.WorkerCompletionRecord request_slot offset mismatch");
    if (@offsetOf(WorkerCompletionRecord, "status") != 48)
        @compileError("worker_state.page.WorkerCompletionRecord status offset mismatch");
    if (@offsetOf(WorkerCompletionRecord, "cpu_time_ns") != 56)
        @compileError("worker_state.page.WorkerCompletionRecord cpu_time_ns offset mismatch");
    if (@sizeOf(WorkerCompletionRingHeader) != 64)
        @compileError("worker_state.page.WorkerCompletionRingHeader size mismatch");
    if (COMPLETION_RING_COUNT != 16)
        @compileError("worker_state.page completion ring count mismatch");
    if (!std.math.isPowerOfTwo(COMPLETION_RING_COUNT))
        @compileError("worker_state.page completion ring count must be a power of two");

    const zero_completion_header = std.mem.zeroes(WorkerCompletionRingHeader);
    if (zero_completion_header.head != 0 or zero_completion_header.tail != 0 or zero_completion_header.fatal != 0)
        @compileError("worker completion ring header zero state must be empty");
}

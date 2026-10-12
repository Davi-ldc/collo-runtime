//! The usage record: what one finished request measured, as one line of
//! `usage.jsonl` (`sink.zig`). The usage log
//! (`server/supervisor/usage_log.zig`) encodes records with this
//! file and appends them to the sink in batches.
//!
//! Records in `usage.jsonl`, one JSON object per line:
//!
//!     {"ts":<unix ms>,"worker":"..","route":"..","worker_id":N,"worker_generation":N,
//!      "origin":"worker","request_id":N,"error_code":"done","cold_start":false,
//!      "wall_ns":N,"exec_ns":N,"waiting_ns":N,"io_ns":N,"cpu_ns":N,
//!      "client_served_bytes":N,"fetch_sent_bytes":N,"fetch_received_bytes":N,
//!      "fetch_wire_bytes":N,"worker_fault":""}
//!
//! The identity is the server's (`record.zig`): the worker whose completion
//! ring held the record, as the server's worker table names it, never the
//! identity fields the worker wrote, and the request id is always one the
//! server dispatched to that worker. `origin` says who measured. `worker`: the
//! worker reported the execution, waiting, I/O and CPU times, the byte
//! counters and `error_code` for a request the drain matched against the
//! worker's request table (`server/supervisor/usage_drain.zig`). `server`: the
//! server wrote the record for a request its worker could not account for.
//! The server's own clock gives every record's `wall_ns`, from its dispatch
//! to the lane's end of the request, and `ts`, that end on the wall clock;
//! its dispatch gives `cold_start`. `exec_ns`, `waiting_ns` and `io_ns`
//! partition the worker's own span of the request (`CompletedRecord` in
//! `common/worker_state/page/usage_records.zig`), which lies inside `wall_ns`.
//! `error_code` is how the request ended, in the same vocabulary as the
//! access record's. `worker_fault` names the worker fault that ended a
//! request the server wrote the record for
//! (`WorkerFaultReason.label` in `server/ingress/fault.zig`), "" otherwise. A
//! consumer joins a usage record to its access record on `worker_id`,
//! `worker_generation` and `request_id`.
//!
//! Plain values and pure functions, callable from any thread.

const std = @import("std");
const limits = @import("collo_limits").runtime_logs;
const page = @import("collo_worker_state").page;
const record = @import("record.zig");

const Identity = record.Identity;
const Clock = record.Clock;

/// Who measured the request: the worker reported it, or the server wrote a
/// floor for a request the worker could not account for.
pub const Origin = enum { worker, server };

pub const UsageRecord = struct {
    identity: Identity,
    origin: Origin,
    request_id: u64,
    /// Unix milliseconds of the server's end of the request.
    ts_ms: u64,
    /// From the server's dispatch of the request to the lane's end of it.
    wall_ns: u64,
    /// The worker's span of the request less its waiting and I/O: the time
    /// it ran.
    exec_ns: u64,
    /// Time the request was runnable but not executing; disjoint from
    /// `io_ns`.
    waiting_ns: u64,
    io_ns: u64,
    /// The request's CPU (`CompletedRecord.cpu_ns` in
    /// `common/worker_state/page/usage_records.zig`): on a record the worker
    /// wrote, as the worker measured it at the finish; on a floor, as its
    /// live slot last published it, 0 without a live slot or when the server
    /// caused the death (`synthesizeRecordForLifecycle` in
    /// `server/supervisor/usage_drain.zig`).
    cpu_ns: u64,
    client_served_bytes: u64,
    /// Outbound fetch payload bytes, per direction.
    fetch_sent_bytes: u64,
    fetch_received_bytes: u64,
    /// Outbound fetch bytes on the wire, TLS framing included.
    fetch_wire_bytes: u64,
    error_code: page.CompletedStatus,
    cold_start: bool,
    /// The label of the worker fault that ended the request, a static string
    /// of at most `WORKER_FAULT_BYTES_MAX` bytes; "" when none did, and
    /// always on a record the worker wrote.
    worker_fault: []const u8 = "",
};

/// What the server itself holds about a request it dispatched, which a usage
/// record takes its times and cold start from.
pub const Dispatch = struct {
    /// When the server dispatched the request (CLOCK_MONOTONIC).
    started_mono_ns: u64,
    /// The `page.AccountingFlags` the dispatch carried.
    accounting_flags: u32,
};

/// Projects a completion record onto the server's identity. The measurements
/// and the request id come from `completed`; the times and the cold start
/// come from the server: `dispatch` and `ended_mono_ns`, the server's end of
/// the request (CLOCK_MONOTONIC). A caller holding a worker-written record
/// overwrites the request id with the one its own table holds. A status
/// outside the enum reads as `internal_error`.
pub fn fromCompleted(
    identity: Identity,
    origin: Origin,
    completed: page.CompletedRecord,
    dispatch: Dispatch,
    ended_mono_ns: u64,
    clock: Clock,
) UsageRecord {
    return .{
        .identity = identity,
        .origin = origin,
        .request_id = completed.request_id,
        .ts_ms = clock.wallMs(ended_mono_ns),
        .wall_ns = ended_mono_ns -| dispatch.started_mono_ns,
        .exec_ns = completed.exec_ns,
        .waiting_ns = completed.waiting_ns,
        .io_ns = completed.io_ns,
        .cpu_ns = completed.cpu_ns,
        .client_served_bytes = completed.client_served_bytes,
        .fetch_sent_bytes = completed.fetch_sent_bytes,
        .fetch_received_bytes = completed.fetch_received_bytes,
        .fetch_wire_bytes = completed.fetch_wire_bytes,
        .error_code = std.meta.intToEnum(page.CompletedStatus, completed.status) catch .internal_error,
        .cold_start = (dispatch.accounting_flags & page.AccountingFlags.cold_start) != 0,
    };
}

/// Largest `usage.jsonl` record, without the newline the sink adds: the keys,
/// every number at its widest, the longest spelling of each enum, the
/// identity at its cap (`record.identity_json_bytes_max`) and the worker
/// fault label at its cap with worst-case escaping.
pub const json_record_bytes_max: usize = blk: {
    @setEvalBranchQuota(100_000);
    const widest: u64 = std.math.maxInt(u64);
    break :blk std.fmt.count(head_format, .{widest}) +
        record.identity_json_bytes_max +
        std.fmt.count(measures_format, .{
            record.longestTagName(Origin),
            widest,
            record.longestTagName(page.CompletedStatus),
            "false",
            widest,
            widest,
            widest,
            widest,
            widest,
            widest,
            widest,
            widest,
            widest,
        }) +
        worker_fault_key.len + record.stringBytesMax(limits.WORKER_FAULT_BYTES_MAX) +
        record_end.len;
};

/// Writes one record as a JSON object, at most `json_record_bytes_max` bytes
/// and without a trailing newline. Fails only when `writer` runs out of room.
pub fn writeRecordJson(writer: *std.Io.Writer, usage: *const UsageRecord) std.Io.Writer.Error!void {
    try writer.print(head_format, .{usage.ts_ms});
    try record.writeIdentity(writer, usage.identity);
    try writer.print(measures_format, .{
        @tagName(usage.origin),
        usage.request_id,
        @tagName(usage.error_code),
        boolName(usage.cold_start),
        usage.wall_ns,
        usage.exec_ns,
        usage.waiting_ns,
        usage.io_ns,
        usage.cpu_ns,
        usage.client_served_bytes,
        usage.fetch_sent_bytes,
        usage.fetch_received_bytes,
        usage.fetch_wire_bytes,
    });
    try writer.writeAll(worker_fault_key);
    try record.writeString(writer, usage.worker_fault);
    try writer.writeAll(record_end);
}

const head_format = "{{\"ts\":{d},";
const measures_format = ",\"origin\":\"{s}\",\"request_id\":{d},\"error_code\":\"{s}\",\"cold_start\":{s}" ++
    ",\"wall_ns\":{d},\"exec_ns\":{d},\"waiting_ns\":{d},\"io_ns\":{d},\"cpu_ns\":{d}" ++
    ",\"client_served_bytes\":{d},\"fetch_sent_bytes\":{d},\"fetch_received_bytes\":{d}" ++
    ",\"fetch_wire_bytes\":{d}";
const worker_fault_key = ",\"worker_fault\":";
const record_end = "}";

fn boolName(value: bool) []const u8 {
    return if (value) "true" else "false";
}

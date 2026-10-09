//! The usage record: what one finished request measured, as one line of
//! `usage.jsonl` (`sink.zig`). The usage log
//! (`server/supervisor/usage_log.zig`) encodes records with this
//! file and appends them to the sink in batches.
//!
//! Records in `usage.jsonl`, one JSON object per line:
//!
//!     {"ts":<unix ms>,"worker":"..","route":"..","worker_id":N,"worker_generation":N,
//!      "origin":"worker","request_id":N,"error_code":"done","cold_start":false,
//!      "wall_time_ns":N,"cpu_time_ns":N,"io_time_ns":N,"waiting_ns":N,
//!      "client_served_bytes":N,"fetch_sent_bytes":N,"fetch_received_bytes":N,
//!      "fetch_wire_bytes":N,"worker_fault":""}
//!
//! The identity is the server's (`record.zig`): the worker whose completion
//! ring held the record, as the server's worker table names it, never the
//! identity fields the worker wrote, and the request id is always one the
//! server dispatched to that worker. `origin` says who measured. `worker`: the
//! worker reported the times, the byte counters, `error_code` and
//! `cold_start` for a request the drain matched against the worker's request
//! table (`server/supervisor/usage_drain.zig`). `server`: the
//! server wrote the record for a request its worker could not account for.
//! `ts` is when the request finished, and `error_code` is how it ended, in the
//! same vocabulary as the access record's. `worker_fault` names the worker
//! fault that ended a request the server wrote the record for
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
    /// Unix milliseconds when the request finished.
    ts_ms: u64,
    wall_time_ns: u64,
    /// On a record the worker wrote, the worker process's CPU time since its
    /// previous record (`worker/serve/process_cpu.zig`), so it includes
    /// collection, compilation and crypto work, and a worker's first record
    /// includes its boot. On a floor, the CPU of the request's turns on the
    /// VM thread as its live slot last published it, 0 without a live slot or
    /// when the server caused the death (`synthesizeRecordForLifecycle` in
    /// `server/supervisor/usage_drain.zig`).
    cpu_time_ns: u64,
    io_time_ns: u64,
    /// Time the request was runnable but not executing; disjoint from
    /// `io_time_ns`.
    waiting_ns: u64,
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

/// Projects a completion record onto the server's identity. Only the
/// measurements and the request id come from `completed`, and its worker id
/// and generation are ignored; a caller holding a worker-written record
/// overwrites the request id with the one its own table holds. A status
/// outside the enum reads as `internal_error`.
pub fn fromCompleted(
    identity: Identity,
    origin: Origin,
    completed: page.CompletedRecord,
    clock: Clock,
) UsageRecord {
    return .{
        .identity = identity,
        .origin = origin,
        .request_id = completed.request_id,
        .ts_ms = clock.wallMs(completed.finished_mono_ns),
        .wall_time_ns = completed.finished_mono_ns -| completed.started_mono_ns,
        .cpu_time_ns = completed.cpu_time_ns,
        .io_time_ns = completed.io_time_ns,
        .waiting_ns = completed.waiting_ns,
        .client_served_bytes = completed.client_served_bytes,
        .fetch_sent_bytes = completed.fetch_billed_sent_bytes,
        .fetch_received_bytes = completed.fetch_billed_received_bytes,
        .fetch_wire_bytes = completed.fetch_cost_bytes,
        .error_code = std.meta.intToEnum(page.CompletedStatus, completed.status) catch .internal_error,
        .cold_start = page.completedRecordHasFlag(completed, page.CompletedRecordFlags.cold_start),
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
        usage.wall_time_ns,
        usage.cpu_time_ns,
        usage.io_time_ns,
        usage.waiting_ns,
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
    ",\"wall_time_ns\":{d},\"cpu_time_ns\":{d},\"io_time_ns\":{d},\"waiting_ns\":{d}" ++
    ",\"client_served_bytes\":{d},\"fetch_sent_bytes\":{d},\"fetch_received_bytes\":{d}" ++
    ",\"fetch_wire_bytes\":{d}";
const worker_fault_key = ",\"worker_fault\":";
const record_end = "}";

fn boolName(value: bool) []const u8 {
    return if (value) "true" else "false";
}

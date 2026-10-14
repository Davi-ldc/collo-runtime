//! The worker line: what one worker process used over its whole life, as one
//! line of `workers.jsonl` (`sink.zig`). The supervisor writes it in the
//! worker's teardown, after the exit and before the cgroup leaf goes
//! (`worker_registry.teardown` in `server/supervisor/worker_registry.zig`),
//! for every worker the server ends, those its shutdown stops included.
//!
//! Lines in `workers.jsonl`, one JSON object per line:
//!
//!     {"ts":<unix ms>,"worker":"..","worker_id":N,"worker_generation":N,
//!      "started_ts":<unix ms>,"life_ns":N,"worker_cpu_ns":N,
//!      "memory_peak_bytes":N,"ending":"idle"}
//!
//! `worker`, `worker_id` and `worker_generation` name the process as the
//! server's worker table does, the identity its requests' access records
//! carry, without a route, since any route of its definition runs on it.
//! `started_ts` is when the server published the worker and `ts` when its
//! teardown wrote the line, both on the wall clock, and `life_ns` the
//! monotonic time between them. `worker_cpu_ns` is the CPU of every thread
//! of the process over its life, boot, collection, compilation and
//! JavaScript no request owned included, as the kernel counted it in the
//! leaf's `cpu.stat`, so the worker cannot forge it; `memory_peak_bytes` is
//! the leaf's `memory.peak`. Either is null when the leaf cannot say, as on
//! a kernel without `memory.peak`. `ending` says how the life ended
//! (`Ending`), a memory death split by who stopped the worker, while its
//! requests' access records say `memory` either way. A consumer joins the
//! line to its requests' access records on `worker_id` and
//! `worker_generation`; the CPU here less their `cpu_ns` is what no request
//! owned.
//!
//! Plain values and pure functions, callable from any thread.

const std = @import("std");
const limits = @import("collo_limits").runtime_logs;
const record = @import("record.zig");

/// How a worker's life ended.
pub const Ending = enum {
    /// Its idle TTL or memory pressure retired it while it held no request.
    idle,
    /// It announced `worker_retiring`, its routes having failed, its VM
    /// having been terminated or its egress session having broken on the
    /// gateway's side, and was retired once its requests finished.
    recycled,
    /// Its sentinel stopped it past `memory.high`, its memory limit
    /// (`Death.memory_high` in `server/supervisor/worker_table.zig`).
    memory_high,
    /// The kernel's OOM killer ended it at `memory.max`, above its limit,
    /// which a worker reaches when its sentinel did not stop it first
    /// (`Death.memory_max`).
    memory_max,
    /// It died otherwise: a fault, its own exit or its deadline's grace.
    crash,
    /// Its gateway was lost and no other one could give it a session.
    egress_reattach,
    /// Its gateway removed its session for what it sent or left unread.
    egress_session_removed,
    /// The server's shutdown stopped it.
    shutdown,
};

pub const WorkerRecord = struct {
    /// The worker definition's name from the configuration.
    worker: []const u8,
    worker_id: u64,
    worker_generation: u64,
    /// Unix milliseconds of the worker's publish.
    started_ts_ms: u64,
    /// Unix milliseconds of the line.
    ts_ms: u64,
    life_ns: u64,
    worker_cpu_ns: ?u64,
    memory_peak_bytes: ?u64,
    ending: Ending,
};

/// Largest `workers.jsonl` line, without the newline the sink adds: the
/// keys, every number at its widest, the worker name at its cap with
/// worst-case escaping and the longest ending. An absent figure prints
/// `null`, narrower than any widest number.
pub const json_record_bytes_max: usize = blk: {
    @setEvalBranchQuota(100_000);
    const widest: u64 = std.math.maxInt(u64);
    const widest_figure = std.fmt.count("{d}", .{widest});
    break :blk std.fmt.count(head_format, .{widest}) +
        record.stringBytesMax(limits.WORKER_NAME_BYTES_MAX) +
        std.fmt.count(life_format, .{ widest, widest, widest, widest }) +
        cpu_key.len + widest_figure +
        peak_key.len + widest_figure +
        std.fmt.count(ending_format, .{record.longestTagName(Ending)});
};

/// Writes one line as a JSON object, at most `json_record_bytes_max` bytes
/// and without a trailing newline. Fails only when `writer` runs out of
/// room.
pub fn writeRecordJson(writer: *std.Io.Writer, line: *const WorkerRecord) std.Io.Writer.Error!void {
    try writer.print(head_format, .{line.ts_ms});
    try record.writeString(writer, record.utf8Prefix(line.worker, limits.WORKER_NAME_BYTES_MAX));
    try writer.print(life_format, .{ line.worker_id, line.worker_generation, line.started_ts_ms, line.life_ns });
    try writer.writeAll(cpu_key);
    try writeFigure(writer, line.worker_cpu_ns);
    try writer.writeAll(peak_key);
    try writeFigure(writer, line.memory_peak_bytes);
    try writer.print(ending_format, .{@tagName(line.ending)});
}

const head_format = "{{\"ts\":{d},\"worker\":";
const life_format = ",\"worker_id\":{d},\"worker_generation\":{d},\"started_ts\":{d},\"life_ns\":{d}";
const cpu_key = ",\"worker_cpu_ns\":";
const peak_key = ",\"memory_peak_bytes\":";
const ending_format = ",\"ending\":\"{s}\"}}";

fn writeFigure(writer: *std.Io.Writer, figure: ?u64) std.Io.Writer.Error!void {
    if (figure) |value| {
        try writer.print("{d}", .{value});
    } else {
        try writer.writeAll("null");
    }
}

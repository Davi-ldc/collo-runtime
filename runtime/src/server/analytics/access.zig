//! Access records: one per request the server answered or dispatched. An
//! ingress lane stamps a request's facts when it admits the request or
//! answers it alone (`AccessFacts`), turns them into an `AccessRecord` when
//! the request ends, and pushes that onto its own `AccessRing`. The ingress
//! metrics thread pops every lane's ring each tick and encodes the records
//! into `access.jsonl` (`drainRing`).
//!
//! Invariants:
//! - Identity, method, path, route, client address and timings come from the
//!   lane's own state. The worker's own report (CPU, I/O and waiting time,
//!   how the request ended, the status it answered) is copied off its
//!   completion into the slot the lane holds for that request, so a worker
//!   cannot attach it to another request's record.
//! - Facts and records are fixed-size plain data. Every string is cut at its
//!   cap (`common/limits/runtime_logs.zig`) and copied when the facts are
//!   stamped, so the request path never allocates for the access log; the
//!   worker fault label is a static string, copied as a slice.
//! - A request yields at most one record. A dispatched request emits when its
//!   slot finalizes, which clears the facts
//!   (`server/ingress/runner/request_finish.zig`), and a request the lane
//!   answers alone emits at that one answer.
//! - Each lane's ring has one producer, the lane thread, and one consumer, the
//!   metrics thread. A full ring drops the newest record and counts it.
//!
//! Records in `access.jsonl`, one JSON object per line:
//!
//!     {"ts":<unix ms>,"request_id":N,"worker":"..","route":"..","worker_id":N,
//!      "worker_generation":N,"method":"GET","path":"/..","status":200,
//!      "answered_by":"worker","cold_start":false,"duration_ms":N,"ttfb_ms":N,
//!      "cpu_time_ns":N,"io_time_ns":N,"waiting_ns":N,"cold_start_ms":N,
//!      "cold_start_blocked_ms":N,"error_code":"done","worker_fault":"",
//!      "client_ip":"..","user_agent":".."}
//!
//! `ts` is when the request ended. `worker_id` and `worker_generation` are 0
//! when no worker took the request, and `worker` and `route` are "" when it
//! matched no route. `worker_fault` names the worker fault that ended the
//! request (`WorkerFaultReason.label` in `server/ingress/fault.zig`), "" when
//! none did.

const std = @import("std");
const limits = @import("collo_limits").runtime_logs;
const worker_shared_page = @import("collo_worker_state").page;
const record = @import("record.zig");
const sink_mod = @import("sink.zig");

const CompletedStatus = worker_shared_page.CompletedStatus;
const Clock = record.Clock;
const Sink = sink_mod.Sink;

/// A request's access facts, carried in its ingress request slot from
/// admission to the end of the request. `request_id` 0 means nothing to emit:
/// the facts were never stamped or were already emitted.
pub const AccessFacts = struct {
    request_id: u64 = 0,
    worker_id: u64 = 0,
    worker_generation: u64 = 0,
    /// Monotonic time the lane admitted the request, before the pool hands it
    /// a worker slot, or began answering it alone.
    started_mono_ns: u64 = 0,
    /// Monotonic time the response head was queued toward the client; 0 when
    /// none was, as after a worker death or timeout before the head.
    first_byte_mono_ns: u64 = 0,
    /// The worker's timeline, copied off its completion when the request
    /// ends; 0 on every path where no worker finished the request.
    cpu_time_ns: u64 = 0,
    io_time_ns: u64 = 0,
    waiting_ns: u64 = 0,
    /// The cold start this request waited for: the new worker's own boot
    /// work (`Record.boot_work_ns` in `server/supervisor/worker_table.zig`),
    /// and how long this request was blocked on it, from its admission to its
    /// dispatch (`server/ingress/runner/dispatch.zig`).
    cold_start_ns: u64 = 0,
    cold_start_blocked_ns: u64 = 0,
    /// How the request ended, in the worker completion's vocabulary; `done`
    /// for success and for every request that never reached a worker.
    error_code: CompletedStatus = .done,
    /// The label of the worker fault that ended the request, a static string
    /// of at most `WORKER_FAULT_BYTES_MAX` bytes; "" when none did.
    worker_fault: []const u8 = "",
    cold_start: bool = false,
    worker_len: u16 = 0,
    route_len: u16 = 0,
    method_len: u8 = 0,
    path_len: u16 = 0,
    user_agent_len: u16 = 0,
    client_ip_len: u8 = 0,
    worker: [limits.WORKER_NAME_BYTES_MAX]u8 = undefined,
    /// The matched route pattern, "" when the request matched no route.
    route: [limits.ROUTE_BYTES_MAX]u8 = undefined,
    method: [limits.METHOD_BYTES_MAX]u8 = undefined,
    /// Client bytes: the request's path as dispatched.
    path: [limits.PATH_BYTES_MAX]u8 = undefined,
    /// Client bytes: the first `user-agent` value, "" when absent.
    user_agent: [limits.USER_AGENT_BYTES_MAX]u8 = undefined,
    /// The connection's TCP peer, "" when unknown.
    client_ip: [limits.CLIENT_IP_BYTES_MAX]u8 = undefined,

    comptime {
        std.debug.assert(limits.WORKER_NAME_BYTES_MAX <= std.math.maxInt(u16));
        std.debug.assert(limits.ROUTE_BYTES_MAX <= std.math.maxInt(u16));
        std.debug.assert(limits.METHOD_BYTES_MAX <= std.math.maxInt(u8));
        std.debug.assert(limits.PATH_BYTES_MAX <= std.math.maxInt(u16));
        std.debug.assert(limits.USER_AGENT_BYTES_MAX <= std.math.maxInt(u16));
        std.debug.assert(limits.CLIENT_IP_BYTES_MAX <= std.math.maxInt(u8));
    }

    pub fn workerSlice(self: *const AccessFacts) []const u8 {
        return self.worker[0..self.worker_len];
    }
    pub fn routeSlice(self: *const AccessFacts) []const u8 {
        return self.route[0..self.route_len];
    }
    pub fn methodSlice(self: *const AccessFacts) []const u8 {
        return self.method[0..self.method_len];
    }
    pub fn pathSlice(self: *const AccessFacts) []const u8 {
        return self.path[0..self.path_len];
    }
    pub fn userAgentSlice(self: *const AccessFacts) []const u8 {
        return self.user_agent[0..self.user_agent_len];
    }
    pub fn clientIpSlice(self: *const AccessFacts) []const u8 {
        return self.client_ip[0..self.client_ip_len];
    }
};

/// What the lane knows when it stamps a request's facts. The strings are
/// borrowed for the call: `stamp` copies them. The worker id and generation
/// are not here: the lane fills them in when the request's slot finalizes,
/// from the worker it dispatched to (`server/ingress/runner/request_finish.zig`).
pub const Stamp = struct {
    request_id: u64,
    /// The worker definition's name (`record.Identity.worker`), "" when the
    /// request matched no route.
    worker: []const u8,
    route: []const u8 = "",
    method: []const u8,
    path: []const u8,
    user_agent: []const u8,
    client_ip: []const u8,
    started_mono_ns: u64,
    cold_start: bool = false,
};

/// Builds a request's facts, cutting each string at its cap on a UTF-8
/// boundary.
pub fn stamp(options: Stamp) AccessFacts {
    var facts = AccessFacts{
        .request_id = options.request_id,
        .started_mono_ns = options.started_mono_ns,
        .cold_start = options.cold_start,
    };
    facts.worker_len = @intCast(copyBounded(&facts.worker, options.worker));
    facts.route_len = @intCast(copyBounded(&facts.route, options.route));
    facts.method_len = @intCast(copyBounded(&facts.method, options.method));
    facts.path_len = @intCast(copyBounded(&facts.path, options.path));
    facts.user_agent_len = @intCast(copyBounded(&facts.user_agent, options.user_agent));
    facts.client_ip_len = @intCast(copyBounded(&facts.client_ip, options.client_ip));
    return facts;
}

fn copyBounded(target: []u8, source: []const u8) usize {
    const prefix = record.utf8Prefix(source, target.len);
    @memcpy(target[0..prefix.len], prefix);
    return prefix.len;
}

/// The first `user-agent` value of `headers`, or "". `headers` is any slice
/// of entries with `name` and `value` byte slices. HPACK delivers header
/// names in lowercase, and every header list the lane records keeps them so.
pub fn userAgent(headers: anytype) []const u8 {
    for (headers) |header| {
        if (std.mem.eql(u8, header.name, "user-agent"))
            return header.value;
    }
    return "";
}

/// Who wrote the response. A worker answers every request that finalizes
/// through a request slot; the server answers the rest alone.
pub const AnsweredBy = enum {
    worker,
    server,

    pub fn jsonName(self: AnsweredBy) []const u8 {
        return switch (self) {
            .worker => "worker",
            .server => "server",
        };
    }
};

/// A finished request, as the lane hands it to the metrics thread.
pub const AccessRecord = struct {
    facts: AccessFacts,
    /// The status the client received, synthesized ones included.
    status: u16,
    answered_by: AnsweredBy,
    /// Monotonic time the request ended.
    finalize_mono_ns: u64,

    /// Start (`AccessFacts.started_mono_ns`) to end, in whole milliseconds; 0
    /// against a clock reading at or before the start.
    pub fn durationMs(self: *const AccessRecord) u64 {
        return (self.finalize_mono_ns -| self.facts.started_mono_ns) / std.time.ns_per_ms;
    }

    /// Start (`AccessFacts.started_mono_ns`) to response head, in whole
    /// milliseconds. 0 means no head was queued, so a head that was floors at
    /// 1: a fast first byte must not read as no first byte.
    pub fn ttfbMs(self: *const AccessRecord) u64 {
        if (self.facts.first_byte_mono_ns == 0)
            return 0;
        return @max(1, (self.facts.first_byte_mono_ns -| self.facts.started_mono_ns) / std.time.ns_per_ms);
    }
};

pub fn recordFromFacts(
    facts: AccessFacts,
    status: u16,
    answered_by: AnsweredBy,
    finalize_mono_ns: u64,
) AccessRecord {
    return .{
        .facts = facts,
        .status = status,
        .answered_by = answered_by,
        .finalize_mono_ns = finalize_mono_ns,
    };
}

/// Largest `access.jsonl` record: every key, every number at its widest, the
/// longest spelling of each enum and boolean, the identity at its cap
/// (`record.identity_json_bytes_max`) and every client string at its cap with
/// worst-case escaping, counted from the same format strings
/// `writeRecordJson` prints.
pub const json_record_bytes_max: usize = blk: {
    @setEvalBranchQuota(100_000);
    const widest: u64 = std.math.maxInt(u64);
    break :blk std.fmt.count(head_format, .{ widest, widest }) +
        record.identity_json_bytes_max +
        method_key.len + record.stringBytesMax(limits.METHOD_BYTES_MAX) +
        path_key.len + record.stringBytesMax(limits.PATH_BYTES_MAX) +
        std.fmt.count(measures_format, .{
            std.math.maxInt(u16),
            record.longestTagName(AnsweredBy),
            "false",
            widest,
            widest,
            widest,
            widest,
            widest,
            widest,
            widest,
            record.longestTagName(CompletedStatus),
        }) +
        worker_fault_key.len + record.stringBytesMax(limits.WORKER_FAULT_BYTES_MAX) +
        client_ip_key.len + record.stringBytesMax(limits.CLIENT_IP_BYTES_MAX) +
        user_agent_key.len + record.stringBytesMax(limits.USER_AGENT_BYTES_MAX) +
        record_end.len;
};

comptime {
    std.debug.assert(json_record_bytes_max < sink_mod.access_buffer_bytes_max);
}

/// Writes one record as a JSON object, at most `json_record_bytes_max` bytes
/// and without a trailing newline. Fails only when `writer` runs out of room.
pub fn writeRecordJson(writer: *std.Io.Writer, access: *const AccessRecord, clock: Clock) std.Io.Writer.Error!void {
    const facts = &access.facts;
    try writer.print(head_format, .{
        clock.wallMs(access.finalize_mono_ns),
        facts.request_id,
    });
    try record.writeIdentity(writer, .{
        .worker = facts.workerSlice(),
        .route = facts.routeSlice(),
        .worker_id = facts.worker_id,
        .worker_generation = facts.worker_generation,
    });
    try writer.writeAll(method_key);
    try record.writeString(writer, facts.methodSlice());
    try writer.writeAll(path_key);
    try record.writeString(writer, facts.pathSlice());
    try writer.print(measures_format, .{
        access.status,
        access.answered_by.jsonName(),
        if (facts.cold_start) "true" else "false",
        access.durationMs(),
        access.ttfbMs(),
        facts.cpu_time_ns,
        facts.io_time_ns,
        facts.waiting_ns,
        facts.cold_start_ns / std.time.ns_per_ms,
        facts.cold_start_blocked_ns / std.time.ns_per_ms,
        @tagName(facts.error_code),
    });
    try writer.writeAll(worker_fault_key);
    try record.writeString(writer, facts.worker_fault);
    try writer.writeAll(client_ip_key);
    try record.writeString(writer, facts.clientIpSlice());
    try writer.writeAll(user_agent_key);
    try record.writeString(writer, facts.userAgentSlice());
    try writer.writeAll(record_end);
}

const head_format = "{{\"ts\":{d},\"request_id\":{d},";
const method_key = ",\"method\":";
const path_key = ",\"path\":";
const measures_format = ",\"status\":{d},\"answered_by\":\"{s}\",\"cold_start\":{s},\"duration_ms\":{d}" ++
    ",\"ttfb_ms\":{d},\"cpu_time_ns\":{d},\"io_time_ns\":{d},\"waiting_ns\":{d}" ++
    ",\"cold_start_ms\":{d},\"cold_start_blocked_ms\":{d},\"error_code\":\"{s}\"";
const worker_fault_key = ",\"worker_fault\":";
const client_ip_key = ",\"client_ip\":";
const user_agent_key = ",\"user_agent\":";
const record_end = "}";

/// One lane's handoff of finished access records to the metrics thread.
/// Monotonic cursors, occupancy `head -% tail`. Both ends are server threads,
/// so nothing read from a slot needs validation. The ring holds one metrics
/// tick (`metrics_drain_interval_ns` in
/// `server/ingress/service_observability.zig`) of a lane that finishes up to
/// `capacity` requests in it, at about 1.4 KiB per slot.
pub const AccessRing = struct {
    pub const capacity: usize = 2048;

    comptime {
        std.debug.assert(std.math.isPowerOfTwo(capacity));
    }

    slots: [capacity]AccessRecord = undefined,
    /// Producer cursor: the lane thread writes it, release-published.
    head: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Consumer cursor: the metrics thread writes it, release-published.
    tail: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Records refused while full. The producer adds; the consumer takes.
    dropped: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// Lane thread only. Returns false, and counts the record, when the ring
    /// is full.
    pub fn push(self: *AccessRing, access: AccessRecord) bool {
        const head = self.head.load(.monotonic);
        const tail = self.tail.load(.acquire);
        if (head -% tail >= capacity) {
            _ = self.dropped.fetchAdd(1, .monotonic);
            return false;
        }
        self.slots[@intCast(head % capacity)] = access;
        self.head.store(head +% 1, .release);
        return true;
    }

    /// Metrics thread only. Copies the oldest record out; false when empty.
    pub fn pop(self: *AccessRing, out: *AccessRecord) bool {
        const tail = self.tail.load(.monotonic);
        const head = self.head.load(.acquire);
        if (head == tail)
            return false;
        out.* = self.slots[@intCast(tail % capacity)];
        self.tail.store(tail +% 1, .release);
        return true;
    }

    /// Metrics thread only: takes and resets the refused count.
    pub fn takeDropped(self: *AccessRing) u64 {
        return self.dropped.swap(0, .monotonic);
    }
};

/// Metrics thread only: moves the records in `ring` into the sink, at most
/// one ring's worth per call so a lane that keeps pushing cannot hold the
/// thread, and adds the records the ring refused to the stream's drops.
/// Without an access file the records are popped and counted as discarded.
pub fn drainRing(ring: *AccessRing, sink: *Sink, clock: Clock) void {
    var buffer: [json_record_bytes_max]u8 = undefined;
    var access: AccessRecord = undefined;
    const enabled = sink.enabled(.access);
    var popped: usize = 0;
    while (popped < AccessRing.capacity and ring.pop(&access)) {
        popped += 1;
        if (enabled) {
            var writer: std.Io.Writer = .fixed(&buffer);
            // Every string in the facts was cut at its cap when stamped, so
            // the record fits `json_record_bytes_max`.
            writeRecordJson(&writer, &access, clock) catch unreachable;
            sink.appendLossy(.access, writer.buffered());
        }
    }
    if (!enabled and popped != 0)
        sink.noteDiscarded(.access, popped);
    const refused = ring.takeDropped();
    if (refused != 0)
        sink.noteDropped(.access, refused);
}

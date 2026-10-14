//! Worker console lines: decoding a frame of a worker's log ring, encoding it
//! as a `logs.jsonl` record and as a stderr line, and draining a ring into the
//! sink. The ingress metrics thread drains every mapped worker's ring each
//! tick (`server/ingress/analytics_drain.zig`), and a worker's teardown
//! drains its dying ring once, on the reaper or, at shutdown, on the exiting
//! thread (`drainDyingRing`, called from the worker's teardown,
//! `server/supervisor/worker_registry.zig:teardown`). The reaper also drains
//! the ring of a failed launch's child once, after it killed the child,
//! through `drainRing` (`server/supervisor/reaper/root.zig:drainLaunchConsole`).
//!
//! Invariants:
//! - One thread consumes a given ring at a time. Both drains run under the
//!   worker record's `metrics_mutex` and only while its `page_mapped` is set
//!   (`server/supervisor/worker_table.zig`), and the teardown clears the flag
//!   under that mutex before it unmaps the page, so no drain reads a ring
//!   another is reading or one that is gone. A failed launch's ring has no
//!   record: the reaper holds its only mapping, so its one drain is the
//!   ring's only consumer.
//! - A line's request id and route come from the server's request table of
//!   the worker whose ring held the line, never from the line alone.
//! - Every frame is worker-written and hostile. The ring validates lengths
//!   and flags (`common/worker_state/page/console_ring.zig`); here an unknown level reads
//!   as info, a stamp in the future reads as the drain's own time, and the
//!   message is escaped on both outputs, so a worker can neither break a JSON
//!   line nor start a stderr line that looks like another worker's, nor send
//!   control sequences to the operator's terminal.
//! - Draining allocates nothing: each line is encoded from the ring's scratch
//!   into a stack buffer and copied into the sink, which drops and counts what
//!   finds no room.
//!
//! Records in `logs.jsonl`, one JSON object per line:
//!
//!     {"ts":<unix ms>,"worker":"..","route":"..","worker_id":N,"worker_generation":N,
//!      "request_id":N,"level":"info","message":"..","truncated":false,"exception":false}
//!     {"ts":<unix ms>,"worker":"..","route":"..","worker_id":N,"worker_generation":N,
//!      "dropped_lines":N}
//!
//! The second shape counts the lines the worker's ring dropped since that
//! worker's previous drop marker. `request_id` and `route` name the request
//! that wrote the line as the server's tables confirm it. A failed launch's
//! child has no worker id, since the server numbers a worker only at its
//! publish, so its lines carry `worker_id` and `worker_generation` 0, which
//! no worker has, and request id 0. A worker writes a
//! request id with each line, 0 outside any request, and that id is its own
//! claim; the drain keeps it only when the worker's request table holds that
//! request or ended it recently (`WorkerRequests`), and prints the route that
//! request matched. Any other id prints as 0 with no route and counts as
//! refused (`Drained.ids_refused`), so a worker can file a line only under a
//! request it was dispatched, never under another worker's or another
//! tenant's. On stderr each line reads `[<worker> <route>] <message>`, or
//! `[<worker>] <message>` without a route; a line break inside a message
//! continues on a line indented by two spaces, and control bytes and invalid
//! UTF-8 print as `\xNN`. A line the worker's runtime wrote for the operator
//! (`LogLineFlags.runtime`) reads `[<worker> runtime] <message>` on stderr
//! and never enters `logs.jsonl`, the tenant's log. The flag is the worker's
//! claim, so a worker that sets it on its own lines only hides them from its
//! own log.

const std = @import("std");
const limits = @import("collo_limits").runtime_logs;
const worker_shared_page = @import("collo_worker_state").page;
const record = @import("record.zig");
const sink_mod = @import("sink.zig");

const DrainedLogLine = worker_shared_page.DrainedLogLine;
const LogLevel = worker_shared_page.LogLevel;
const LogLineFlags = worker_shared_page.LogLineFlags;
const Identity = record.Identity;
const Clock = record.Clock;
const Sink = sink_mod.Sink;

comptime {
    // The drain never cuts a message again, so every line the ring accepts
    // must fit the record's message cap whole.
    std.debug.assert(limits.LINE_BYTES_MAX == worker_shared_page.LOG_LINE_BYTES_MAX);
}

/// Frames pulled per ring read. Their payloads borrow one scratch buffer, so
/// each batch is encoded before the next read reuses it.
pub const drain_batch_lines: usize = 64;

/// Lines teardown drains from a dying ring before it gives up. Teardown kills
/// the worker and waits for it to exit before this drain, but the wait is
/// bounded (`teardown` in `server/supervisor/worker_registry.zig`),
/// and a worker still alive when it gives up could keep refilling the ring
/// and hold teardown forever. The budget covers a full ring of minimum-size
/// frames with room to spare, and the lines past it are lost.
pub const dying_ring_line_budget: usize = 8192;

comptime {
    std.debug.assert(dying_ring_line_budget >=
        worker_shared_page.LOG_RING_BYTES / @sizeOf(worker_shared_page.LogFrameHeader));
}

/// Largest `logs.jsonl` record: the keys and integers of the line shape,
/// the identity, and a message at the cap with worst-case escaping.
pub const json_record_bytes_max: usize = 256 +
    record.identity_json_bytes_max +
    record.stringBytesMax(limits.LINE_BYTES_MAX);

/// Largest stderr line: the bracketed prefix and the message, each byte of
/// which prints as at most four (`\xNN`).
pub const console_record_bytes_max: usize = 8 +
    4 * (limits.WORKER_NAME_BYTES_MAX + limits.ROUTE_BYTES_MAX) +
    4 * limits.LINE_BYTES_MAX;

const encode_buffer_bytes = @max(json_record_bytes_max, console_record_bytes_max);

comptime {
    std.debug.assert(json_record_bytes_max < sink_mod.logs_buffer_bytes_max);
    std.debug.assert(console_record_bytes_max < sink_mod.console_buffer_bytes_max);
    // A stderr line and its newline fit one console write batch, so every
    // batch ends on a line boundary.
    std.debug.assert(console_record_bytes_max + 1 <= sink_mod.console_write_bytes_max);
}

/// One decoded console line. `message` borrows the drained frame's payload,
/// and `request_id` is the id the worker wrote until the drain checks it.
pub const Line = struct {
    request_id: u64,
    level: LogLevel,
    ts_ms: u64,
    message: []const u8,
    truncated: bool,
    exception: bool,
    /// The worker runtime's own line (`LogLineFlags.runtime`), for the
    /// operator: it goes to stderr only, never into the tenant's log.
    runtime: bool,
};

/// The label a runtime line carries in its stderr prefix where a tenant's
/// line carries its route, `[<worker> runtime]`. No route pattern can read
/// so, since every pattern starts with a slash.
pub const runtime_label = "runtime";

pub fn decodeLine(drained: DrainedLogLine, clock: Clock) Line {
    return .{
        .request_id = drained.header.request_id,
        .level = std.meta.intToEnum(LogLevel, drained.header.level) catch .info,
        .ts_ms = clock.wallMs(drained.header.ts_mono_ns),
        .message = drained.payload,
        .truncated = drained.header.flags & LogLineFlags.truncated != 0,
        .exception = drained.header.flags & LogLineFlags.js_exception != 0,
        .runtime = drained.header.flags & LogLineFlags.runtime != 0,
    };
}

/// The record's level name, after the console method that produces it.
pub fn levelName(level: LogLevel) []const u8 {
    return switch (level) {
        .debug => "debug",
        .info => "info",
        .warn => "warn",
        .err => "error",
    };
}

pub fn writeLineJson(writer: *std.Io.Writer, identity: Identity, line: Line) std.Io.Writer.Error!void {
    try writer.print("{{\"ts\":{d},", .{line.ts_ms});
    try record.writeIdentity(writer, identity);
    try writer.print(",\"request_id\":{d},\"level\":\"{s}\",\"message\":", .{
        line.request_id,
        levelName(line.level),
    });
    try record.writeString(writer, record.utf8Prefix(line.message, limits.LINE_BYTES_MAX));
    try writer.print(",\"truncated\":{s},\"exception\":{s}}}", .{
        boolName(line.truncated),
        boolName(line.exception),
    });
}

pub fn writeDroppedJson(
    writer: *std.Io.Writer,
    identity: Identity,
    ts_ms: u64,
    dropped_lines: u64,
) std.Io.Writer.Error!void {
    try writer.print("{{\"ts\":{d},", .{ts_ms});
    try record.writeIdentity(writer, identity);
    try writer.print(",\"dropped_lines\":{d}}}", .{dropped_lines});
}

/// Writes `message` as stderr text under the identity's prefix, without the
/// final newline the sink adds.
pub fn writeLineConsole(writer: *std.Io.Writer, identity: Identity, message: []const u8) std.Io.Writer.Error!void {
    try writeConsolePrefix(writer, identity);
    try writeConsoleText(writer, record.utf8Prefix(message, limits.LINE_BYTES_MAX), .continue_lines);
}

pub fn writeDroppedConsole(writer: *std.Io.Writer, identity: Identity, dropped_lines: u64) std.Io.Writer.Error!void {
    try writeConsolePrefix(writer, identity);
    try writer.print("collo: {d} console lines dropped", .{dropped_lines});
}

fn writeConsolePrefix(writer: *std.Io.Writer, identity: Identity) std.Io.Writer.Error!void {
    try writer.writeByte('[');
    try writeConsoleText(writer, record.utf8Prefix(identity.worker, limits.WORKER_NAME_BYTES_MAX), .escape_breaks);
    const route = record.utf8Prefix(identity.route, limits.ROUTE_BYTES_MAX);
    if (route.len != 0) {
        try writer.writeByte(' ');
        try writeConsoleText(writer, route, .escape_breaks);
    }
    try writer.writeAll("] ");
}

const LineBreaks = enum {
    /// A line break starts a continuation line indented by two spaces.
    continue_lines,
    /// A line break prints as `\x0a`, keeping the text on one line.
    escape_breaks,
};

/// Terminal-safe text. Printable ASCII, tab and valid UTF-8 pass through;
/// C0 controls (carriage return and escape included), DEL, C1 controls and
/// each byte of an invalid sequence print as `\xNN`, so the text cannot move
/// the cursor, and every physical line it starts begins with the continuation
/// indent. At most four output bytes per input byte.
fn writeConsoleText(writer: *std.Io.Writer, text: []const u8, breaks: LineBreaks) std.Io.Writer.Error!void {
    var index: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        if (byte == '\n' and breaks == .continue_lines) {
            try writer.writeAll("\n  ");
            index += 1;
        } else if (byte == '\t') {
            try writer.writeByte(byte);
            index += 1;
        } else if (byte < 0x20 or byte == 0x7f) {
            try writeHexEscape(writer, byte);
            index += 1;
        } else if (byte < 0x80) {
            try writer.writeByte(byte);
            index += 1;
        } else {
            const sequence_len = record.validSequenceLen(text, index);
            if (sequence_len == 0) {
                try writeHexEscape(writer, byte);
                index += 1;
            } else {
                const sequence = text[index..][0..sequence_len];
                // validSequenceLen has already validated the sequence.
                const codepoint = std.unicode.utf8Decode(sequence) catch unreachable;
                if (codepoint >= 0x80 and codepoint <= 0x9f) {
                    for (sequence) |sequence_byte|
                        try writeHexEscape(writer, sequence_byte);
                } else {
                    try writer.writeAll(sequence);
                }
                index += sequence_len;
            }
        }
    }
}

fn writeHexEscape(writer: *std.Io.Writer, byte: u8) std.Io.Writer.Error!void {
    try writer.print("\\x{x:0>2}", .{byte});
}

fn boolName(value: bool) []const u8 {
    return if (value) "true" else "false";
}

/// Encodes one line for both outputs and hands them to the sink. `buffer`
/// holds `encode_buffer_bytes`, and every field is cut at its cap before it
/// is encoded, so the fixed writer cannot run out of room.
fn emitLine(sink: *Sink, identity: Identity, line: Line, buffer: *[encode_buffer_bytes]u8) void {
    if (sink.enabled(.logs)) {
        var json: std.Io.Writer = .fixed(buffer);
        writeLineJson(&json, identity, line) catch unreachable;
        sink.appendLossy(.logs, json.buffered());
    } else {
        sink.noteDiscarded(.logs, 1);
    }
    var console: std.Io.Writer = .fixed(buffer);
    writeLineConsole(&console, identity, line.message) catch unreachable;
    sink.appendLossy(.console, console.buffered());
}

/// Hands a runtime line to stderr alone, under `[<worker> runtime]`. Its
/// request id names nothing the server checks or prints.
fn emitRuntimeLine(sink: *Sink, identity: Identity, message: []const u8, buffer: *[encode_buffer_bytes]u8) void {
    var runtime_identity = identity;
    runtime_identity.route = runtime_label;
    var console: std.Io.Writer = .fixed(buffer);
    writeLineConsole(&console, runtime_identity, message) catch unreachable;
    sink.appendLossy(.console, console.buffered());
}

fn emitDropped(sink: *Sink, identity: Identity, ts_ms: u64, dropped_lines: u64, buffer: *[encode_buffer_bytes]u8) void {
    if (sink.enabled(.logs)) {
        var json: std.Io.Writer = .fixed(buffer);
        writeDroppedJson(&json, identity, ts_ms, dropped_lines) catch unreachable;
        sink.appendLossy(.logs, json.buffered());
    } else {
        sink.noteDiscarded(.logs, 1);
    }
    var console: std.Io.Writer = .fixed(buffer);
    writeDroppedConsole(&console, identity, dropped_lines) catch unreachable;
    sink.appendLossy(.console, console.buffered());
}

/// What one drain of a log ring did.
pub const Drained = struct {
    lines: usize = 0,
    /// Lines whose request id the worker's request table did not confirm,
    /// printed with request id 0. Lines the worker wrote under id 0 are not
    /// counted.
    ids_refused: u64 = 0,
};

/// A worker's request table as its console drain asks it whose request a
/// line names. `Table` provides `routeOfRecent(request_id) ?RouteIndex`, the
/// route of a request the table holds or ended among its most recent ones
/// (`RequestTable` in `server/supervisor/request_table.zig`); `routes` are
/// the routes of the worker's definition, in the order the table's route
/// indexes count them, each with its `pattern`. The last answer is kept,
/// since a worker usually writes a run of lines for one request.
pub fn WorkerRequests(comptime Table: type, comptime Route: type) type {
    return struct {
        table: *Table,
        routes: []const Route,
        last_request_id: u64 = 0,
        last_route: []const u8 = "",

        const Self = @This();

        /// The route pattern of the request `request_id` names, or null when
        /// the worker was never dispatched that request or the table no
        /// longer remembers it. `request_id` is never 0.
        pub fn routeOf(self: *Self, request_id: u64) ?[]const u8 {
            std.debug.assert(request_id != 0);
            if (request_id == self.last_request_id)
                return self.last_route;
            const index = self.table.routeOfRecent(request_id) orelse return null;
            // The table records only routes the lane matched within the
            // worker's definition, so an index past them names no route.
            if (index >= self.routes.len)
                return null;
            self.last_request_id = request_id;
            self.last_route = self.routes[index].pattern;
            return self.last_route;
        }
    };
}

/// Drains up to `line_budget` lines of a worker's log ring into `sink`: each
/// line becomes a `logs.jsonl` record and a stderr line, and the lines the
/// ring counted as dropped since `drop_reported.*` become one drop marker,
/// after which `drop_reported.*` holds the ring's counter. `view` is the
/// host's mapping of the worker's page, and the caller must be the ring's
/// only consumer.
/// `requests` provides `routeOf(request_id) ?[]const u8`, as
/// `WorkerRequests` does: a line keeps its request id and takes that route
/// when it answers, and otherwise prints request id 0 under `identity`, whose
/// route is the one a line under no request carries. Fails when the ring is
/// fatal or corrupt; the lines before the fault are already in the sink, and
/// a faulted ring gets no drop marker, because its counter is no longer
/// trustworthy.
pub fn drainRing(
    view: *worker_shared_page.HostReaderView,
    requests: anytype,
    identity: Identity,
    drop_reported: *u64,
    sink: *Sink,
    clock: Clock,
    line_budget: usize,
) !Drained {
    var scratch: [worker_shared_page.LOG_LINE_BYTES_MAX]u8 = undefined;
    var batch: [drain_batch_lines]DrainedLogLine = undefined;
    var buffer: [encode_buffer_bytes]u8 = undefined;

    var drained: Drained = .{};
    while (drained.lines < line_budget) {
        const batch_len = @min(batch.len, line_budget - drained.lines);
        const count = try view.drainLogLinesChecked(&scratch, batch[0..batch_len]);
        if (count == 0)
            break;
        std.debug.assert(count <= batch_len);
        drained.lines += count;
        for (batch[0..count]) |frame| {
            var line = decodeLine(frame, clock);
            var line_identity = identity;
            if (line.runtime) {
                emitRuntimeLine(sink, identity, line.message, &buffer);
                continue;
            }
            if (line.request_id != 0) {
                if (requests.routeOf(line.request_id)) |route| {
                    line_identity.route = route;
                } else {
                    line.request_id = 0;
                    drained.ids_refused += 1;
                }
            }
            emitLine(sink, line_identity, line, &buffer);
        }
    }

    const ring_dropped = view.loadLogDropCounters().lines;
    const dropped = ring_dropped -| drop_reported.*;
    if (dropped != 0)
        emitDropped(sink, identity, clock.wall_now_ms, dropped, &buffer);
    drop_reported.* = ring_dropped;
    return drained;
}

/// Teardown's final drain of a worker's log ring, before its shared page is
/// unmapped, with `requests` as `drainRing` takes it. The caller guarantees
/// the periodic drain can no longer reach the worker (see the header), which
/// makes this the ring's only consumer. A fault ends the drain, and lines
/// still in the ring are lost with the page. Returns the lines whose request
/// id was refused, for the caller's count.
pub fn drainDyingRing(view: *worker_shared_page.HostReaderView, requests: anytype, identity: Identity, drop_reported: *u64, sink: *Sink) u64 {
    const drained = drainRing(view, requests, identity, drop_reported, sink, Clock.capture(), dying_ring_line_budget) catch |err| {
        std.log.warn("log ring of a dying worker failed; its remaining lines are lost worker_id={d}: {s}", .{
            identity.worker_id,
            @errorName(err),
        });
        return 0;
    };
    return drained.ids_refused;
}

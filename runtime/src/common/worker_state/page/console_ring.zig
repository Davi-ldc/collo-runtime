//! The console line ring: a byte ring of frames, each a `LogFrameHeader`
//! with its UTF-8 payload inline. The worker's VM thread appends lines and
//! never fails, and the host drains them through its `WorkerWriterView` of
//! the worker, the ring's one consumer. The drain keeps the host's tail in
//! host memory and stores it to the page without reading it back, loads the
//! worker's head once, and copies each frame header once and validates the
//! copy, so a worker that rewrites the ring during a drain can garble a
//! line's text but never a length or a cursor; a corrupt cursor or frame
//! turns the ring fatal.

const std = @import("std");

/// Byte capacity of the console line ring: floor(LOG_RING_BYTES /
/// (LOG_LINE_BYTES_MAX + the frame header)) = 31 max-size lines between two
/// host drains, which run `metrics_drain_interval_ns` apart
/// (`server/ingress/service_observability.zig`). A worker writing max-size
/// lines faster than that loses the newest ones, counted in the ring header:
/// the console stream is lossy by contract.
pub const LOG_RING_BYTES: usize = 128 * 1024;
/// Cap on one console line's UTF-8 payload. The C++ console formatter gets it
/// as its budget and truncates and flags a longer line before it reaches the
/// ring; the writer cuts again, and the host's drain treats a longer frame as
/// a corrupt ring.
pub const LOG_LINE_BYTES_MAX: usize = 4096;

pub const LogLevel = enum(u8) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,
};

pub const LogLineFlags = struct {
    /// The payload was cut at `LOG_LINE_BYTES_MAX`.
    pub const truncated: u8 = 1 << 0;
    /// The line is an uncaught JavaScript exception the worker formatted. The
    /// console formatter never sets it.
    pub const js_exception: u8 = 1 << 1;
};

const log_line_flags_valid: u8 =
    LogLineFlags.truncated |
    LogLineFlags.js_exception;

/// The fixed prefix of every log ring entry, followed inline by its UTF-8
/// payload. A frame wraps across the end of the ring, so the ring holds no
/// padding entries.
pub const LogFrameHeader = extern struct {
    payload_len: u32,
    level: u8,
    flags: u8,
    _reserved0: u16 = 0,
    request_id: u64,
    ts_mono_ns: u64,
};

pub const LogRingHeader = extern struct {
    /// Monotonic byte offsets: the worker owns the producer cursor, and
    /// `tail` is the copy of the host's consumer cursor that the host stores
    /// after each drain and never reads back. Occupancy is head -% tail.
    head: u64,
    tail: u64,
    /// Lines and payload bytes the worker dropped because the ring was full.
    /// `dropped_lines` also counts lines the per-request console budget
    /// suppressed; the host reports the lines as one marker line.
    dropped_lines: u64,
    dropped_bytes: u64,
    /// Set by the consumer when a drain finds the ring corrupt. The producer
    /// then drops every line uncounted, and every later drain fails with
    /// `error.LogRingFatal`.
    fatal: u32,
    _reserved0: u32 = 0,
    _reserved1: [3]u64 = @splat(0),
};

/// One drained line. `payload` points into the scratch buffer the caller
/// passed to the drain and stays valid until the next drain reuses it.
pub const DrainedLogLine = struct {
    header: LogFrameHeader,
    payload: []const u8,
};

pub fn publishLogLineImpl(
    header: *LogRingHeader,
    log_bytes: []u8,
    level: LogLevel,
    flags: u8,
    request_id: u64,
    ts_mono_ns: u64,
    payload: []const u8,
) void {
    if (@atomicLoad(u32, &header.fatal, .acquire) != 0)
        return;

    var line = payload;
    var line_flags = flags & log_line_flags_valid;
    if (line.len > LOG_LINE_BYTES_MAX) {
        line = line[0..utf8FloorBoundary(line, LOG_LINE_BYTES_MAX)];
        line_flags |= LogLineFlags.truncated;
    }

    const needed: u64 = @sizeOf(LogFrameHeader) + line.len;
    const head = @atomicLoad(u64, &header.head, .acquire);
    const tail = @atomicLoad(u64, &header.tail, .acquire);
    const occupancy = head -% tail;
    if (occupancy > LOG_RING_BYTES or LOG_RING_BYTES - @as(usize, @intCast(occupancy)) < needed) {
        _ = @atomicRmw(u64, &header.dropped_lines, .Add, 1, .release);
        _ = @atomicRmw(u64, &header.dropped_bytes, .Add, payload.len, .release);
        return;
    }

    var frame = LogFrameHeader{
        .payload_len = @intCast(line.len),
        .level = @intFromEnum(level),
        .flags = line_flags,
        .request_id = request_id,
        .ts_mono_ns = ts_mono_ns,
    };
    copyIntoLogRing(log_bytes, head, std.mem.asBytes(&frame));
    copyIntoLogRing(log_bytes, head +% @sizeOf(LogFrameHeader), line);
    @atomicStore(u64, &header.head, head +% needed, .release);
}

/// Host side. `tail` is the host's own consumer cursor, which the drain moves
/// and stores to the page.
pub fn drainLogLinesImpl(
    header: *LogRingHeader,
    log_bytes: []const u8,
    tail: *u64,
    scratch: []u8,
    out: []DrainedLogLine,
) !usize {
    if (@atomicLoad(u32, &header.fatal, .acquire) != 0)
        return error.LogRingFatal;
    if (out.len == 0)
        return 0;

    const head = @atomicLoad(u64, &header.head, .acquire);
    var cursor = tail.*;
    if (head -% cursor > LOG_RING_BYTES) {
        @atomicStore(u32, &header.fatal, 1, .release);
        return error.LogRingCorrupt;
    }

    var produced: usize = 0;
    var scratch_used: usize = 0;
    while (produced < out.len and cursor != head) {
        const remaining = head -% cursor;
        if (remaining < @sizeOf(LogFrameHeader)) {
            @atomicStore(u32, &header.fatal, 1, .release);
            return error.LogRingCorrupt;
        }
        // The worker can rewrite the page at any time, so every field is
        // validated from this local copy: a concurrent rewrite can garble
        // the payload text but never a length or a cursor.
        var frame: LogFrameHeader = undefined;
        copyFromLogRing(log_bytes, cursor, std.mem.asBytes(&frame));
        if (frame.payload_len > LOG_LINE_BYTES_MAX or
            frame._reserved0 != 0 or
            (frame.flags & ~log_line_flags_valid) != 0)
        {
            @atomicStore(u32, &header.fatal, 1, .release);
            return error.InvalidLogFrame;
        }
        // `level` is a display attribute, not a structural invariant. The
        // writer takes a LogLevel, so only a worker rewriting the page
        // produces an out-of-range byte; it passes through raw and the
        // consumer maps it to a default, instead of failing the ring over a
        // cosmetic value.
        const total: u64 = @sizeOf(LogFrameHeader) + frame.payload_len;
        if (remaining < total) {
            @atomicStore(u32, &header.fatal, 1, .release);
            return error.LogRingCorrupt;
        }
        if (scratch.len < frame.payload_len) {
            // An error only when nothing was drained: with partial progress
            // the drained frames are returned and the large frame waits for
            // the next drain with room for it.
            if (produced == 0)
                return error.LogScratchTooSmall;
            break;
        }
        if (scratch.len - scratch_used < frame.payload_len)
            break;
        const dest = scratch[scratch_used .. scratch_used + frame.payload_len];
        copyFromLogRing(log_bytes, cursor +% @sizeOf(LogFrameHeader), dest);
        out[produced] = .{ .header = frame, .payload = dest };
        produced += 1;
        scratch_used += frame.payload_len;
        cursor = cursor +% total;
    }
    tail.* = cursor;
    @atomicStore(u64, &header.tail, cursor, .release);
    return produced;
}

fn copyIntoLogRing(log_bytes: []u8, offset: u64, bytes: []const u8) void {
    const start: usize = @intCast(offset % LOG_RING_BYTES);
    const first = @min(bytes.len, LOG_RING_BYTES - start);
    @memcpy(log_bytes[start .. start + first], bytes[0..first]);
    if (bytes.len > first)
        @memcpy(log_bytes[0 .. bytes.len - first], bytes[first..]);
}

fn copyFromLogRing(log_bytes: []const u8, offset: u64, out: []u8) void {
    const start: usize = @intCast(offset % LOG_RING_BYTES);
    const first = @min(out.len, LOG_RING_BYTES - start);
    @memcpy(out[0..first], log_bytes[start .. start + first]);
    if (out.len > first)
        @memcpy(out[first..], log_bytes[0 .. out.len - first]);
}

/// The length of the longest prefix of at most `max_len` bytes that does not
/// split a UTF-8 sequence. It backs off at most three continuation bytes, the
/// longest tail a sequence has, so invalid UTF-8 is cut no more than three
/// bytes short of `max_len`.
fn utf8FloorBoundary(bytes: []const u8, max_len: usize) usize {
    if (bytes.len <= max_len) return bytes.len;
    var len = max_len;
    var backoff: usize = 0;
    while (len > 0 and backoff < 3 and (bytes[len] & 0b1100_0000) == 0b1000_0000) : (backoff += 1) {
        len -= 1;
    }
    return len;
}

comptime {
    if (@sizeOf(LogFrameHeader) != 24)
        @compileError("worker_state.page.LogFrameHeader size mismatch");
    if (@sizeOf(LogRingHeader) != 64)
        @compileError("worker_state.page.LogRingHeader size mismatch");
    if (LOG_LINE_BYTES_MAX + @sizeOf(LogFrameHeader) > LOG_RING_BYTES)
        @compileError("worker_state.page log ring must hold at least one max-size line");
}

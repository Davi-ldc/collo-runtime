//! What every analytics record shares: the identity the server stamps on it,
//! the clock that dates it and the JSON string encoding. Plain values and
//! functions that keep no state, callable from any thread.
//!
//! Invariants:
//! - An identity is built from the server's own tables, never from bytes a
//!   worker wrote, so a worker cannot choose whose record its output enters.
//! - `writeString` emits valid JSON for any input bytes and never writes more
//!   than `stringBytesMax(value.len)` bytes, and `writeIdentity` cuts each
//!   name at its cap, so an encoder whose buffer is sized from these bounds
//!   cannot overflow.

const std = @import("std");
const limits = @import("collo_limits").runtime_logs;
const process = @import("collo_os").process;

/// Whose record it is. Every field is the server's: the worker definition it
/// dispatched to, the route pattern it matched, and the id and generation it
/// gave that worker process.
pub const Identity = struct {
    /// The worker definition's name from the configuration.
    worker: []const u8,
    /// The matched route pattern, or "" when the record belongs to no route.
    route: []const u8,
    worker_id: u64,
    worker_generation: u64,

    /// The identity of a supervisor worker record (`server/supervisor/worker_table.zig`
    /// `Record`): its definition's name, which the record borrows from the
    /// route table, and no route. A worker process belongs to a definition,
    /// and any route of that definition may run on it, so no single pattern
    /// names every line the worker writes.
    pub fn ofWorker(worker: anytype) Identity {
        return .{
            .worker = worker.name,
            .route = "",
            .worker_id = worker.id,
            .worker_generation = worker.generation,
        };
    }
};

/// Largest output of `writeIdentity`: the four keys, two names at their caps
/// with worst-case escaping, and two 20-digit integers.
pub const identity_json_bytes_max: usize = 128 +
    stringBytesMax(limits.WORKER_NAME_BYTES_MAX) +
    stringBytesMax(limits.ROUTE_BYTES_MAX);

/// Writes the identity's fields as `"worker":..,"route":..,"worker_id":N,
/// "worker_generation":N`, without braces or a leading comma.
pub fn writeIdentity(writer: *std.Io.Writer, identity: Identity) std.Io.Writer.Error!void {
    try writer.writeAll("\"worker\":");
    try writeString(writer, utf8Prefix(identity.worker, limits.WORKER_NAME_BYTES_MAX));
    try writer.writeAll(",\"route\":");
    try writeString(writer, utf8Prefix(identity.route, limits.ROUTE_BYTES_MAX));
    try writer.print(",\"worker_id\":{d},\"worker_generation\":{d}", .{
        identity.worker_id,
        identity.worker_generation,
    });
}

/// One wall-clock and monotonic reading taken together. Records dated against
/// one reading keep their monotonic order, and each is off by at most the time
/// since the reading.
pub const Clock = struct {
    wall_now_ms: u64,
    mono_now_ns: u64,

    /// Reads both clocks. A wall clock before the epoch reads as 0.
    pub fn capture() Clock {
        const wall_ms = std.time.milliTimestamp();
        return .{
            .wall_now_ms = if (wall_ms > 0) @intCast(wall_ms) else 0,
            .mono_now_ns = process.monotonicNowNsOrZero(),
        };
    }

    /// Unix milliseconds of a monotonic stamp. A stamp of 0 or one at or
    /// after the reading maps to the reading itself: a console line's stamp
    /// is worker-written, and a record is never dated in the future.
    pub fn wallMs(self: Clock, mono_ns: u64) u64 {
        if (mono_ns == 0 or mono_ns >= self.mono_now_ns)
            return self.wall_now_ms;
        const age_ms = (self.mono_now_ns - mono_ns) / std.time.ns_per_ms;
        return self.wall_now_ms -| age_ms;
    }
};

/// The longest tag name of `Enum`, for a record bound that counts an enum
/// field at its widest spelling.
pub fn longestTagName(comptime Enum: type) []const u8 {
    comptime var longest: []const u8 = "";
    inline for (@typeInfo(Enum).@"enum".fields) |field| {
        if (field.name.len > longest.len)
            longest = field.name;
    }
    return longest;
}

/// Largest output of `writeString` for an input of `input_bytes`: two quotes
/// and at most six bytes per input byte, since a control byte becomes the
/// escape `\u00XX` and each byte of an invalid sequence becomes the six-byte
/// escape of U+FFFD.
pub fn stringBytesMax(input_bytes: usize) usize {
    return 2 + 6 * input_bytes;
}

/// Writes `value` as a JSON string. Well-formed UTF-8 passes through raw, so
/// a message in any script stays readable; quote, backslash and control bytes
/// are escaped; and each byte of an invalid UTF-8 sequence becomes U+FFFD,
/// because console messages and request fields are bytes a worker or a client
/// chose.
pub fn writeString(writer: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    try writer.writeByte('"');
    var index: usize = 0;
    while (index < value.len) {
        const byte = value[index];
        if (byte == '"') {
            try writer.writeAll("\\\"");
            index += 1;
        } else if (byte == '\\') {
            try writer.writeAll("\\\\");
            index += 1;
        } else if (byte == '\n') {
            try writer.writeAll("\\n");
            index += 1;
        } else if (byte == '\r') {
            try writer.writeAll("\\r");
            index += 1;
        } else if (byte == '\t') {
            try writer.writeAll("\\t");
            index += 1;
        } else if (byte < 0x20) {
            try writer.print("\\u{x:0>4}", .{byte});
            index += 1;
        } else if (byte < 0x80) {
            try writer.writeByte(byte);
            index += 1;
        } else {
            const sequence_len = validSequenceLen(value, index);
            if (sequence_len == 0) {
                try writer.writeAll("\\ufffd");
                index += 1;
            } else {
                try writer.writeAll(value[index..][0..sequence_len]);
                index += sequence_len;
            }
        }
    }
    try writer.writeByte('"');
}

/// Length of the valid UTF-8 sequence that starts at `value[index]`, or 0
/// when the bytes there are not one.
pub fn validSequenceLen(value: []const u8, index: usize) usize {
    std.debug.assert(index < value.len);
    const sequence_len = std.unicode.utf8ByteSequenceLength(value[index]) catch return 0;
    if (sequence_len > value.len - index)
        return 0;
    if (!std.unicode.utf8ValidateSlice(value[index..][0..sequence_len]))
        return 0;
    return sequence_len;
}

/// The longest prefix of `value` that fits `bytes_max` and does not split a
/// UTF-8 sequence. Backs off at most three continuation bytes, the most a
/// sequence has.
pub fn utf8Prefix(value: []const u8, bytes_max: usize) []const u8 {
    if (value.len <= bytes_max)
        return value;
    var len = bytes_max;
    var backoff: usize = 0;
    while (len > 0 and backoff < 3 and (value[len] & 0b1100_0000) == 0b1000_0000) {
        len -= 1;
        backoff += 1;
    }
    return value[0..len];
}

//! The lines `collo serve` writes to stderr for its operator, each prefixed
//! with `collo: `. A line is formatted on the stack and handed to the kernel
//! in one write, shorter than the pipe atomicity bound, so it never
//! interleaves with another thread's output and a process reading the stream
//! line by line sees it whole. A message longer than `line_bytes_max` is cut
//! and ends in "...".
//!
//! Any thread may call these functions; they hold no state.

const std = @import("std");
const config = @import("collo_server_config");

pub const line_prefix = "collo: ";
pub const line_bytes_max: usize = 2048;

const truncation_mark = "...\n";

comptime {
    // A configuration diagnostic fits whole after the prefix.
    std.debug.assert(line_prefix.len + config.Diagnostic.message_bytes_max + 1 < line_bytes_max);
    // POSIX keeps a pipe write of at most PIPE_BUF bytes, 4096 on Linux, in
    // one piece.
    std.debug.assert(line_bytes_max <= 4096);
}

pub fn line(comptime format: []const u8, args: anytype) void {
    var buffer: [line_bytes_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const complete = if (writer.print(line_prefix ++ format ++ "\n", args)) true else |err| switch (err) {
        // The fixed writer fails only when the buffer is full.
        error.WriteFailed => false,
    };
    emit(&writer, complete);
}

/// Text that `write(context, writer)` produces itself, prefix and newline
/// included, under the same single-write rule; the warning of
/// `SelfSignedCertificate.writeWarning` in `server/tls/self_signed.zig` is one.
pub fn written(context: anytype, write: anytype) void {
    var buffer: [line_bytes_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const complete = if (write(context, &writer)) true else |err| switch (err) {
        // The fixed writer fails only when the buffer is full.
        error.WriteFailed => false,
    };
    emit(&writer, complete);
}

fn emit(writer: *std.Io.Writer, complete: bool) void {
    if (!complete) {
        const buffer = writer.buffer;
        @memcpy(buffer[buffer.len - truncation_mark.len ..], truncation_mark);
        writer.end = buffer.len;
    }
    // A stderr that refuses the line leaves nothing else to tell; the exit
    // status still carries the outcome.
    std.fs.File.stderr().writeAll(writer.buffered()) catch return;
}

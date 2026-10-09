//! The boot trace pipe: event lines from the host, the zygote and every
//! worker child, read back by the host (the server's reader is
//! `server/boot/trace_drain.zig`). The host creates the pipe (`tracePipe`)
//! and keeps its read end and a write end for its own launch markers
//! (`SpawnedZygote` in `host_client.zig`); the zygote inherits the write end
//! at `inherited_trace_fd` (`fork_loop.zig`), and a worker child keeps it
//! across the fork. The functions here keep no state, so any thread of the
//! three processes may call them.
//!
//! Invariants:
//! - Tracing never blocks or fails its caller. Both ends of the pipe are
//!   nonblocking, so an event that finds the pipe full is dropped, and a
//!   write error is at most a warning.
//! - A line fits `TRACE_EVENT_BUFFER_BYTES` or is dropped whole. That bound
//!   is below PIPE_BUF, so each line is one atomic write, and lines from
//!   different writers never interleave.
//! - A null descriptor means tracing is off.

const std = @import("std");
const process_limits = @import("collo_limits").process;

/// Writes a boot trace line to the zygote's trace pipe; a null fd means tracing
/// is off. The host writes its own launch markers to the same pipe.
pub fn traceEvent(trace_fd: ?std.posix.fd_t, event: []const u8) void {
    if (trace_fd == null)
        return;

    var buffer: [process_limits.TRACE_EVENT_BUFFER_BYTES]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, "{s}\n", .{event}) catch return;
    writeBestEffort(trace_fd.?, line, "trace event");
}

pub fn traceEventFmt(trace_fd: ?std.posix.fd_t, comptime fmt: []const u8, args: anytype) void {
    if (trace_fd == null)
        return;

    var buffer: [process_limits.TRACE_EVENT_BUFFER_BYTES]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, fmt ++ "\n", args) catch return;
    writeBestEffort(trace_fd.?, line, "trace event");
}

pub fn tracePipe() ![2]std.posix.fd_t {
    return std.posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
}

fn writeBestEffort(fd: std.posix.fd_t, bytes: []const u8, context: []const u8) void {
    var remaining = bytes;
    while (remaining.len != 0) {
        const written = std.posix.write(fd, remaining) catch |err| switch (err) {
            error.WouldBlock, error.BrokenPipe, error.ConnectionResetByPeer => return,
            else => |unexpected| {
                std.log.warn("{s} write failed: {s}", .{ context, @errorName(unexpected) });
                return;
            },
        };
        if (written == 0)
            return;
        remaining = remaining[written..];
    }
}

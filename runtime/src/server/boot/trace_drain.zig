//! The reader of the boot trace pipe (`SpawnedZygote.trace_read_fd` in
//! `zygote/host_client.zig`) for the zygote's whole life. The host's launch
//! path, the zygote and every worker child write event lines into the pipe
//! (`zygote/trace.zig`), and both ends are nonblocking, so a pipe nobody reads
//! fills and every later event is dropped. The drain keeps it empty, logging
//! each event line when `loggingRequested` says so and discarding it
//! otherwise.
//!
//! A writer puts each line into the pipe whole, with one write of at most
//! `line_bytes_max` bytes, but a read ends wherever the bytes it takes run
//! out, so the drain reassembles lines across reads (`LineAssembler`).
//!
//! The thread that calls `init` also calls `deinit`, and the drain thread is
//! the only reader of the pipe and the only user of its assembler.
//! `SpawnedZygote` owns the pipe, so `deinit` runs before the zygote's
//! `deinit` closes it.

const std = @import("std");
const builtin = @import("builtin");
const fd_mod = @import("collo_os").fd;
const process_limits = @import("collo_limits").process;

const linux = std.os.linux;
const posix = std.posix;

/// Bytes moved out of the pipe per read.
const read_chunk_bytes: usize = 4096;

/// The longest line a writer puts into the pipe, its newline included.
pub const line_bytes_max: usize = process_limits.TRACE_EVENT_BUFFER_BYTES;

pub const TraceDrain = struct {
    /// Borrowed from `SpawnedZygote`.
    trace_fd: posix.fd_t,
    /// Wakes the drain so `deinit` can join it.
    wake_fd: fd_mod.OwnedFd,
    log_lines: bool,
    lines: LineAssembler,
    thread: std.Thread,

    /// Starts draining `trace_fd`, which must stay open until `deinit`
    /// returns.
    pub fn init(target: *TraceDrain, trace_fd: posix.fd_t, log_lines: bool) !void {
        var wake_fd = fd_mod.OwnedFd.fromRaw(try posix.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK));
        errdefer wake_fd.deinit();
        target.* = .{
            .trace_fd = trace_fd,
            .wake_fd = wake_fd,
            .log_lines = log_lines,
            .lines = .{},
            .thread = undefined,
        };
        target.thread = try std.Thread.spawn(.{}, drain, .{target});
    }

    pub fn deinit(self: *TraceDrain) void {
        const one: u64 = 1;
        // Writing 1 to an eventfd fails only on a counter near its maximum
        // or a closed descriptor. Without the wake the join below never
        // returns, so the process ends here instead of hanging.
        fd_mod.writeAllRaw(self.wake_fd.fd(), std.mem.asBytes(&one)) catch |err|
            std.debug.panic("cannot wake the boot trace drain: {s}", .{@errorName(err)});
        self.thread.join();
        self.wake_fd.deinit();
        self.* = undefined;
    }

    fn drain(self: *TraceDrain) void {
        var poll_fds = [_]posix.pollfd{
            .{ .fd = self.trace_fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = self.wake_fd.fd(), .events = posix.POLL.IN, .revents = 0 },
        };
        var buffer: [read_chunk_bytes]u8 = undefined;
        while (true) {
            _ = posix.poll(&poll_fds, -1) catch |err| {
                std.log.warn("boot trace drain cannot poll: {s}; trace events past a full pipe are dropped", .{@errorName(err)});
                return;
            };
            if ((poll_fds[1].revents & posix.POLL.IN) != 0)
                return;
            const trace_events = poll_fds[0].revents;
            if ((trace_events & (posix.POLL.IN | posix.POLL.HUP)) != 0) {
                if (!self.readAvailable(&buffer))
                    return;
            }
            // Every writer is gone and nothing is left to read.
            if ((trace_events & posix.POLL.HUP) != 0 and (trace_events & posix.POLL.IN) == 0)
                return;
        }
    }

    /// Reads until the pipe is empty. False when the pipe failed and the
    /// drain must stop.
    fn readAvailable(self: *TraceDrain, buffer: []u8) bool {
        while (true) {
            const length = posix.read(self.trace_fd, buffer) catch |err| switch (err) {
                error.WouldBlock => return true,
                else => {
                    std.log.warn("boot trace drain cannot read the pipe: {s}", .{@errorName(err)});
                    return false;
                },
            };
            if (length == 0)
                return true;
            if (self.log_lines)
                self.lines.feed(buffer[0..length], LogSink{});
        }
    }
};

/// Reassembles the pipe's lines across reads. The bytes a read leaves after
/// its last newline begin a line whose rest a later read brings, and they wait
/// here for it; whatever still waits when the drain ends is dropped. No writer
/// emits a line longer than `line_bytes_max`, so a piece that grows past it
/// without a newline is no event: its bytes are skipped up to the next newline
/// and reported once.
pub const LineAssembler = struct {
    held: [line_bytes_max - 1]u8 = undefined,
    held_len: usize = 0,
    /// The piece being read grew past the bound, and its bytes are skipped up
    /// to its newline.
    skipping: bool = false,

    /// Takes the bytes of one read. For each line they complete,
    /// `sink.line(text)` gets the line without its newline, valid only during
    /// the call, and for each piece past the bound `sink.overlong()` runs
    /// once.
    pub fn feed(self: *LineAssembler, bytes: []const u8, sink: anytype) void {
        var rest = bytes;
        while (std.mem.indexOfScalar(u8, rest, '\n')) |newline| {
            self.endLine(rest[0..newline], sink);
            rest = rest[newline + 1 ..];
        }
        self.hold(rest, sink);
    }

    fn endLine(self: *LineAssembler, tail: []const u8, sink: anytype) void {
        if (self.skipping) {
            self.skipping = false;
            return;
        }
        if (self.held_len == 0) {
            if (tail.len < line_bytes_max) sink.line(tail) else sink.overlong();
            return;
        }
        const line_len = self.held_len + tail.len;
        if (line_len < line_bytes_max) {
            @memcpy(self.held[self.held_len..line_len], tail);
            sink.line(self.held[0..line_len]);
        } else {
            sink.overlong();
        }
        self.held_len = 0;
    }

    fn hold(self: *LineAssembler, piece: []const u8, sink: anytype) void {
        if (self.skipping)
            return;
        const held_len = self.held_len + piece.len;
        if (held_len < line_bytes_max) {
            @memcpy(self.held[self.held_len..held_len], piece);
            self.held_len = held_len;
            return;
        }
        self.held_len = 0;
        self.skipping = true;
        sink.overlong();
    }
};

const LogSink = struct {
    fn line(_: LogSink, text: []const u8) void {
        const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
        if (trimmed.len != 0)
            std.log.info("boot-trace {s}", .{trimmed});
    }

    fn overlong(_: LogSink) void {
        std.log.info("boot-trace dropped a line longer than {d} bytes", .{line_bytes_max});
    }
};

/// `COLLO_BOOT_TRACE=1` or `COLLO_DEBUG=1` logs the trace; a Debug build
/// always does.
pub fn loggingRequested() bool {
    if (builtin.mode == .Debug)
        return true;
    return environmentFlag("COLLO_BOOT_TRACE") or environmentFlag("COLLO_DEBUG");
}

fn environmentFlag(name: [:0]const u8) bool {
    const value = posix.getenv(name) orelse return false;
    return std.mem.eql(u8, std.mem.trim(u8, value, " \t\r\n"), "1");
}

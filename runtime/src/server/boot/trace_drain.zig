//! The reader of the boot trace pipe (`SpawnedZygote.trace_read_fd` in
//! `zygote/host_client.zig`) for the zygote's whole life. The pipe exists
//! only when the boot trace is logged (`loggingRequested`), because the
//! server then spawns the zygote with tracing; without it there is nothing to
//! drain and no drain thread. The host's launch path, the zygote and every
//! worker child during its boot write event lines into the pipe
//! (`zygote/trace.zig`), and both ends are nonblocking, so a pipe nobody reads
//! fills and every later event is dropped. The drain keeps it empty and logs
//! each event line.
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
    /// Borrowed from `SpawnedZygote`; -1 without a pipe.
    trace_fd: posix.fd_t,
    /// Wakes the drain so `deinit` can join it; unset without a pipe.
    wake_fd: fd_mod.OwnedFd,
    lines: LineAssembler,
    /// Null for a zygote spawned without tracing, which has no pipe.
    thread: ?std.Thread,

    /// Starts draining `trace_fd`, which must stay open until `deinit`
    /// returns. A null `trace_fd`, a zygote spawned without tracing, starts
    /// nothing, and `deinit` then has nothing to stop.
    pub fn init(target: *TraceDrain, trace_fd: ?posix.fd_t) !void {
        target.* = .{
            .trace_fd = -1,
            .wake_fd = .{},
            .lines = .{},
            .thread = null,
        };
        target.trace_fd = trace_fd orelse return;
        target.wake_fd = fd_mod.OwnedFd.fromRaw(try posix.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK));
        errdefer target.wake_fd.deinit();
        target.thread = try std.Thread.spawn(.{}, drain, .{target});
    }

    pub fn deinit(self: *TraceDrain) void {
        if (self.thread) |thread| {
            const one: u64 = 1;
            // Writing 1 to an eventfd fails only on a counter near its
            // maximum or a closed descriptor. Without the wake the join below
            // never returns, so the process ends here instead of hanging.
            fd_mod.writeAllRaw(self.wake_fd.fd(), std.mem.asBytes(&one)) catch |err|
                std.debug.panic("cannot wake the boot trace drain: {s}", .{@errorName(err)});
            thread.join();
        }
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

/// Whether this server logs the boot trace (`traceLogged` over its build
/// mode and environment). The server spawns its zygote with a trace pipe
/// exactly then.
pub fn loggingRequested() bool {
    return traceLogged(.{
        .mode = builtin.mode,
        .boot_trace = posix.getenv("COLLO_BOOT_TRACE"),
        .debug = posix.getenv("COLLO_DEBUG"),
    });
}

/// What decides whether the boot trace is logged.
pub const TraceInputs = struct {
    mode: std.builtin.OptimizeMode,
    /// `COLLO_BOOT_TRACE`, null when unset.
    boot_trace: ?[]const u8,
    /// `COLLO_DEBUG`, null when unset.
    debug: ?[]const u8,
};

/// A Debug build always logs the trace; any other logs it when either
/// variable is `1`, so a ReleaseFast server without them spawns no pipe and
/// starts no drain thread.
pub fn traceLogged(inputs: TraceInputs) bool {
    if (inputs.mode == .Debug)
        return true;
    return flagSet(inputs.boot_trace) or flagSet(inputs.debug);
}

fn flagSet(value: ?[]const u8) bool {
    const text = value orelse return false;
    return std.mem.eql(u8, std.mem.trim(u8, text, " \t\r\n"), "1");
}

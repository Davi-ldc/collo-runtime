//! The boot trace drain (`server/boot/trace_drain.zig`): it keeps a pipe empty
//! while writers outrun the pipe's capacity, stops on request while the pipe
//! stays open, ends by itself once every writer is gone, and hands on whole
//! the lines its reads split, dropping a piece longer than any line a writer
//! emits. Lane `server-core-test`; the drain on a real zygote runs under
//! `zig build smoke`.

const std = @import("std");
const fd_mod = @import("collo_os").fd;
const trace_drain = @import("collo_server_main").boot.trace_drain;

/// Four times the default pipe capacity on a kernel with 4 KiB pages, where
/// pipe(7)'s 16 pages make 64 KiB, so the writes below finish only if the
/// drain keeps reading. With 64 KiB pages the pipe holds 1 MiB and the writes
/// fit without the drain.
const written_bytes_total: usize = 256 * 1024;

const Pipe = struct {
    read_end: fd_mod.OwnedFd,
    write_end: fd_mod.OwnedFd,

    /// Both ends nonblocking, as the zygote's trace pipe, then the write end
    /// made blocking so the test's writes wait for the drain.
    fn init() !Pipe {
        const raw = try std.posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
        var pipe: Pipe = .{
            .read_end = fd_mod.OwnedFd.fromRaw(raw[0]),
            .write_end = fd_mod.OwnedFd.fromRaw(raw[1]),
        };
        errdefer pipe.deinit();
        try fd_mod.setNonblocking(pipe.write_end.fd(), false);
        return pipe;
    }

    fn deinit(self: *Pipe) void {
        self.write_end.deinit();
        self.read_end.deinit();
    }
};

test "the drain keeps the pipe empty while writes outrun its capacity" {
    var pipe = try Pipe.init();
    defer pipe.deinit();
    var drain: trace_drain.TraceDrain = undefined;
    try drain.init(pipe.read_end.fd(), false);
    defer drain.deinit();

    const line = "boot-event zygote_ready\n";
    var written: usize = 0;
    while (written < written_bytes_total) : (written += line.len)
        try fd_mod.writeAllRaw(pipe.write_end.fd(), line);
}

test "the drain stops on request while the pipe stays open" {
    var pipe = try Pipe.init();
    defer pipe.deinit();
    var drain: trace_drain.TraceDrain = undefined;
    try drain.init(pipe.read_end.fd(), false);
    try fd_mod.writeAllRaw(pipe.write_end.fd(), "boot-event before_stop\n");
    drain.deinit();
}

test "the drain ends by itself once every writer is gone and still joins" {
    var pipe = try Pipe.init();
    defer pipe.deinit();
    var drain: trace_drain.TraceDrain = undefined;
    try drain.init(pipe.read_end.fd(), false);
    try fd_mod.writeAllRaw(pipe.write_end.fd(), "boot-event last\n");
    pipe.write_end.deinit();
    drain.deinit();
}

test "a line two reads split reaches the sink whole, between the lines around it" {
    var lines: trace_drain.LineAssembler = .{};
    var log: LineLog = .{};

    lines.feed("zygote.ready\nchild.boot.st", &log);
    try log.expectLines(&.{"zygote.ready"});
    lines.feed("arted\nworker.ready\n", &log);
    try log.expectLines(&.{ "zygote.ready", "child.boot.started", "worker.ready" });
}

test "a line waits for its newline across reads that bring none, an empty one included" {
    var lines: trace_drain.LineAssembler = .{};
    var log: LineLog = .{};

    lines.feed("host.launch", &log);
    lines.feed(".fork", &log);
    lines.feed("", &log);
    try log.expectLines(&.{});
    lines.feed("\n", &log);
    try log.expectLines(&.{"host.launch.fork"});
}

test "the longest line a writer emits passes in pieces, and a longer piece is dropped up to its newline" {
    const longest = [_]u8{'a'} ** (trace_drain.line_bytes_max - 1);
    var lines: trace_drain.LineAssembler = .{};
    var log: LineLog = .{};

    lines.feed(longest[0..100], &log);
    lines.feed(longest[100..], &log);
    lines.feed("\n", &log);
    try log.expectLines(&.{&longest});
    try std.testing.expectEqual(@as(usize, 0), log.overlong_count);

    // One byte past the bound across reads is reported once, the rest of that
    // piece is skipped, and the line after its newline arrives intact.
    lines.feed(&longest, &log);
    lines.feed("b", &log);
    lines.feed("bbb", &log);
    lines.feed("\nchild.after\n", &log);
    try log.expectLines(&.{ &longest, "child.after" });
    try std.testing.expectEqual(@as(usize, 1), log.overlong_count);

    // The same piece inside one read is dropped the same way.
    lines.feed(longest ++ "bb\nworker.after\n", &log);
    try log.expectLines(&.{ &longest, "child.after", "worker.after" });
    try std.testing.expectEqual(@as(usize, 2), log.overlong_count);
}

/// Keeps what a `LineAssembler` hands its sink, up to `lines_max` lines.
const LineLog = struct {
    texts: [lines_max][trace_drain.line_bytes_max]u8 = undefined,
    lens: [lines_max]usize = undefined,
    count: usize = 0,
    /// Lines past `lines_max`, which `expectLines` refuses.
    count_past_max: usize = 0,
    overlong_count: usize = 0,

    const lines_max: usize = 8;

    pub fn line(self: *LineLog, text: []const u8) void {
        if (self.count == lines_max) {
            self.count_past_max += 1;
            return;
        }
        @memcpy(self.texts[self.count][0..text.len], text);
        self.lens[self.count] = text.len;
        self.count += 1;
    }

    pub fn overlong(self: *LineLog) void {
        self.overlong_count += 1;
    }

    fn expectLines(self: *const LineLog, expected: []const []const u8) !void {
        try std.testing.expectEqual(@as(usize, 0), self.count_past_max);
        try std.testing.expectEqual(expected.len, self.count);
        for (expected, 0..) |text, index|
            try std.testing.expectEqualStrings(text, self.texts[index][0..self.lens[index]]);
    }
};

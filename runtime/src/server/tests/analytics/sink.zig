//! The analytics sink (`server/analytics/sink.zig`) against real files in a
//! temporary directory: one JSON Lines file per stream appended across opens,
//! batched writes on flush, multi-line records and the room they take,
//! whole-record refusal and drops at the buffer bound, the full flag and the
//! one `err` line a full usage stream logs, a refusal that a producer keeping
//! its record asks for and that marks nothing, the reopen a rotation that
//! renames the files asks for, a reopen that waits for a line a failed write
//! cut and a reopen that fails, the sync interval, the final write at close,
//! a missing directory, a planted symlink, a failed write, the console's own
//! flusher and its line-aligned write batches, and the console-only mode
//! without a directory. The record encoders are covered beside it in
//! `logs.zig` and `access.zig`, the ingress drain in
//! `tests/ingress/analytics_drain.zig`, and the signal that asks for a reopen
//! in `tests/boot/signals.zig`.

const std = @import("std");
const analytics = @import("collo_server_analytics");

const sink_mod = analytics.sink;
const Sink = analytics.Sink;

const file_bytes_max = 16 * 1024 * 1024;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    console: std.fs.File,
    path_buffer: [std.fs.max_path_bytes]u8 = undefined,
    path_len: usize = 0,

    fn init(target: *Fixture) !void {
        target.* = .{ .tmp = std.testing.tmpDir(.{}), .console = undefined };
        errdefer target.tmp.cleanup();
        target.console = try target.tmp.dir.createFile("console.txt", .{ .read = true });
        target.path_len = (try target.tmp.dir.realpath(".", &target.path_buffer)).len;
    }

    fn deinit(self: *Fixture) void {
        self.console.close();
        self.tmp.cleanup();
    }

    fn path(self: *const Fixture) []const u8 {
        return self.path_buffer[0..self.path_len];
    }

    fn open(self: *Fixture, sink: *Sink) !void {
        try sink.open(std.testing.allocator, .{
            .directory = self.path(),
            .console_fd = self.console.handle,
        });
    }

    fn read(self: *Fixture, name: []const u8) ![]u8 {
        return self.tmp.dir.readFileAlloc(std.testing.allocator, name, file_bytes_max);
    }

    fn expectFile(self: *Fixture, name: []const u8, expected: []const u8) !void {
        const actual = try self.read(name);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(expected, actual);
    }
};

test "records land as JSON Lines in one file per stream, appended across opens" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var sink: Sink = undefined;
    try fixture.open(&sink);
    try sink.append(.logs, "{\"n\":1}");
    sink.appendLossy(.logs, "{\"n\":2}");
    try sink.append(.access, "{\"a\":1}");
    try sink.append(.usage, "{\"u\":1}");
    sink.appendLossy(.console, "[w] hello");
    sink.flush(0);
    sink.close();

    try fixture.expectFile("logs.jsonl", "{\"n\":1}\n{\"n\":2}\n");
    try fixture.expectFile("access.jsonl", "{\"a\":1}\n");
    try fixture.expectFile("usage.jsonl", "{\"u\":1}\n");
    try fixture.expectFile("console.txt", "[w] hello\n");

    // A second open appends after what the first one wrote.
    try fixture.open(&sink);
    try sink.append(.logs, "{\"n\":3}");
    sink.close();
    try fixture.expectFile("logs.jsonl", "{\"n\":1}\n{\"n\":2}\n{\"n\":3}\n");
}

test "records wait in the buffer until a flush writes them in one batch" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var sink: Sink = undefined;
    try fixture.open(&sink);
    defer sink.close();

    try sink.append(.access, "{\"r\":1}");
    try sink.append(.access, "{\"r\":2}");
    try sink.append(.access, "{\"r\":3}");
    try fixture.expectFile("access.jsonl", "");
    try std.testing.expectEqual(@as(u64, 3), sink.stats(.access).appended);
    try std.testing.expectEqual(@as(u64, 0), sink.stats(.access).bytes_written);

    sink.flush(0);
    try fixture.expectFile("access.jsonl", "{\"r\":1}\n{\"r\":2}\n{\"r\":3}\n");
    try std.testing.expectEqual(@as(u64, 24), sink.stats(.access).bytes_written);
    try std.testing.expectEqual(@as(u64, 0), sink.stats(.access).write_errors);
}

test "a flush syncs a written file only once the sync interval has passed" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var sink: Sink = undefined;
    try fixture.open(&sink);
    defer sink.close();

    try sink.append(.usage, "{\"u\":1}");
    sink.flush(sink_mod.sync_interval_ns);
    try std.testing.expectEqual(@as(u64, 1), sink.stats(.usage).syncs);

    // Written inside the interval: on disk, not yet synced.
    try sink.append(.usage, "{\"u\":2}");
    sink.flush(sink_mod.sync_interval_ns + 1);
    try fixture.expectFile("usage.jsonl", "{\"u\":1}\n{\"u\":2}\n");
    try std.testing.expectEqual(@as(u64, 1), sink.stats(.usage).syncs);

    sink.flush(2 * sink_mod.sync_interval_ns);
    try std.testing.expectEqual(@as(u64, 2), sink.stats(.usage).syncs);

    // A file with nothing new is not synced again.
    sink.flush(3 * sink_mod.sync_interval_ns);
    try std.testing.expectEqual(@as(u64, 2), sink.stats(.usage).syncs);
    try std.testing.expectEqual(@as(u64, 0), sink.stats(.logs).syncs);
}

test "a full buffer refuses or drops whole records and a flush frees the room" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var sink: Sink = undefined;
    try fixture.open(&sink);
    defer sink.close();

    const record = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(record);
    @memset(record, 'x');
    const fit = sink_mod.logs_buffer_bytes_max / (record.len + 1);

    var appended: usize = 0;
    while (appended < fit) : (appended += 1)
        try sink.append(.logs, record);
    try std.testing.expectError(error.SinkBufferFull, sink.append(.logs, record));
    sink.appendLossy(.logs, record);
    var stats = sink.stats(.logs);
    try std.testing.expectEqual(@as(u64, fit), stats.appended);
    try std.testing.expectEqual(@as(u64, 1), stats.refused);
    try std.testing.expectEqual(@as(u64, 1), stats.dropped);
    // A record that still fits the space left is taken.
    try sink.append(.logs, "{}");

    sink.flush(0);
    const written = try fixture.read("logs.jsonl");
    defer std.testing.allocator.free(written);
    try std.testing.expectEqual(fit * (record.len + 1) + "{}\n".len, written.len);
    try std.testing.expectEqual(fit + 1, std.mem.count(u8, written, "\n"));

    try sink.append(.logs, record);
    stats = sink.stats(.logs);
    try std.testing.expectEqual(@as(u64, fit + 2), stats.appended);
}

test "a refusal makes a stream full until a flush makes room for the largest record it refused" {
    // Only the start of a full usage stream logs, once, at `err`.
    @import("root").expect_log_errors = 1;
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var sink: Sink = undefined;
    try fixture.open(&sink);
    defer sink.close();

    const record = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(record);
    @memset(record, 'x');

    const usage_fit = sink_mod.usage_buffer_bytes_max / (record.len + 1);
    var appended: usize = 0;
    while (appended < usage_fit) : (appended += 1)
        try sink.append(.usage, record);
    try std.testing.expect(!sink.full(.usage));
    try std.testing.expectError(error.SinkBufferFull, sink.append(.usage, record));
    try std.testing.expect(sink.full(.usage));
    // A record that still fits is taken without ending the episode, and a
    // second refusal in it logs nothing more.
    try sink.append(.usage, "{}");
    try std.testing.expectError(error.SinkBufferFull, sink.append(.usage, record));
    try std.testing.expect(sink.full(.usage));
    try std.testing.expectEqual(@as(u64, 2), sink.stats(.usage).refused);

    // A stream that drops instead of refusing is full the same way.
    const logs_fit = sink_mod.logs_buffer_bytes_max / (record.len + 1);
    appended = 0;
    while (appended < logs_fit) : (appended += 1)
        sink.appendLossy(.logs, record);
    try std.testing.expect(!sink.full(.logs));
    sink.appendLossy(.logs, record);
    try std.testing.expect(sink.full(.logs));
    try std.testing.expect(!sink.full(.access));

    sink.flush(0);
    try std.testing.expect(!sink.full(.usage));
    try std.testing.expect(!sink.full(.logs));
}

test "a producer that keeps its record is refused without a count or a full stream, and offers it again once written out" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var sink: Sink = undefined;
    try fixture.open(&sink);
    defer sink.close();

    const record = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(record);
    @memset(record, 'x');
    const keep_free: usize = 1024;
    const fit = (sink_mod.usage_buffer_bytes_max - keep_free) / (record.len + 1);

    var appended: usize = 0;
    while (appended < fit) : (appended += 1)
        try std.testing.expect(sink.tryAppendKeepingFree(.usage, record, keep_free));
    // No room for one more above the bytes kept free: the record stays the
    // producer's, so the stream counts nothing, is not full and logs nothing.
    try std.testing.expect(!sink.tryAppendKeepingFree(.usage, record, keep_free));
    const stats = sink.stats(.usage);
    try std.testing.expectEqual(@as(u64, fit), stats.appended);
    try std.testing.expectEqual(@as(u64, 0), stats.refused);
    try std.testing.expectEqual(@as(u64, 0), stats.dropped);
    try std.testing.expect(!sink.full(.usage));

    // Written out, the stream takes the record offered again.
    sink.flush(0);
    try std.testing.expect(sink.tryAppendKeepingFree(.usage, record, keep_free));
    try std.testing.expectEqual(@as(u64, fit + 1), sink.stats(.usage).appended);
}

test "a requested reopen writes what was buffered to the renamed file and then appends under the name" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var sink: Sink = undefined;
    try fixture.open(&sink);
    defer sink.close();

    try sink.append(.usage, "{\"u\":1}");
    try sink.append(.access, "{\"a\":1}");
    sink.flush(0);
    // A rotation renames the files and then asks for the reopen, as logrotate
    // does with a postrotate SIGHUP.
    try fixture.tmp.dir.rename("usage.jsonl", "usage.jsonl.1");
    try fixture.tmp.dir.rename("access.jsonl", "access.jsonl.1");
    try sink.append(.usage, "{\"u\":2}");
    sink.requestReopen();
    sink.flush(0);
    // What was buffered when the reopen was asked for went to the renamed
    // file, and the name is a new, empty file.
    try fixture.expectFile("usage.jsonl.1", "{\"u\":1}\n{\"u\":2}\n");
    try fixture.expectFile("usage.jsonl", "");
    try fixture.expectFile("access.jsonl", "");

    try sink.append(.usage, "{\"u\":3}");
    try sink.append(.access, "{\"a\":2}");
    sink.flush(0);
    try fixture.expectFile("usage.jsonl", "{\"u\":3}\n");
    try fixture.expectFile("access.jsonl", "{\"a\":2}\n");
    try fixture.expectFile("usage.jsonl.1", "{\"u\":1}\n{\"u\":2}\n");
    try fixture.expectFile("access.jsonl.1", "{\"a\":1}\n");

    // Without a new request the next flush reopens nothing.
    try fixture.tmp.dir.rename("usage.jsonl", "usage.jsonl.2");
    try sink.append(.usage, "{\"u\":4}");
    sink.flush(0);
    try fixture.expectFile("usage.jsonl.2", "{\"u\":3}\n{\"u\":4}\n");
}

test "a file whose last write stopped inside a line is reopened only once that line ends in it" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var sink: Sink = undefined;
    try fixture.open(&sink);
    defer sink.close();

    // A file size limit of four bytes cuts the first write inside its line.
    // The kernel also sends SIGXFSZ with the refusal, which would end the test
    // binary, so it is ignored while the limit holds; both are process-wide
    // and restored before the sink closes.
    var previous_action: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.XFSZ, &.{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, &previous_action);
    defer std.posix.sigaction(std.posix.SIG.XFSZ, &previous_action, null);
    const file_size_limit = try std.posix.getrlimit(.FSIZE);
    try std.posix.setrlimit(.FSIZE, .{ .cur = 4, .max = file_size_limit.max });
    // Back to a soft limit the hard limit already allowed, which cannot fail.
    defer std.posix.setrlimit(.FSIZE, file_size_limit) catch unreachable;

    try sink.append(.usage, "{\"u\":1}");
    sink.flush(0);
    try fixture.expectFile("usage.jsonl", "{\"u\"");
    try std.testing.expectEqual(@as(u64, 1), sink.stats(.usage).write_errors);

    try fixture.tmp.dir.rename("usage.jsonl", "usage.jsonl.1");
    sink.requestReopen();
    sink.flush(0);
    // The cut line still waits for its rest, so the usage file keeps its
    // descriptor while the other names open again.
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.access("usage.jsonl", .{}));

    try std.posix.setrlimit(.FSIZE, file_size_limit);
    sink.flush(0);
    try fixture.expectFile("usage.jsonl.1", "{\"u\":1}\n");
    try fixture.expectFile("usage.jsonl", "");
}

test "a reopen that cannot open a name keeps writing to the file already open and logs it once at err" {
    @import("root").expect_log_errors = 1;
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var sink: Sink = undefined;
    try fixture.open(&sink);
    defer sink.close();

    // A symlink planted under the name after the rename is refused, not
    // followed, so the records keep landing in the renamed file.
    try fixture.tmp.dir.rename("usage.jsonl", "usage.jsonl.1");
    try fixture.tmp.dir.symLink("elsewhere.txt", "usage.jsonl", .{});
    sink.requestReopen();
    sink.flush(0);
    try sink.append(.usage, "{\"u\":1}");
    try sink.append(.logs, "{\"n\":1}");
    sink.flush(0);
    try fixture.expectFile("usage.jsonl.1", "{\"u\":1}\n");
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.access("elsewhere.txt", .{}));
    // The other names opened again as asked.
    try fixture.expectFile("logs.jsonl", "{\"n\":1}\n");
}

test "a batch of lines is buffered whole and takes its size of the stream's room" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var sink: Sink = undefined;
    try fixture.open(&sink);
    defer sink.close();

    // A batch of two lines takes 16 bytes with the newline the sink adds,
    // so 16 more bytes kept free than the rest of the stream are refused,
    // and exactly the rest are not.
    const batch = "{\"u\":1}\n{\"u\":2}";
    try sink.append(.usage, batch);
    try std.testing.expect(!sink.tryAppendKeepingFree(.usage, "{}", sink_mod.usage_buffer_bytes_max - 16 - "{}\n".len + 1));
    try std.testing.expect(sink.tryAppendKeepingFree(.usage, "{}", sink_mod.usage_buffer_bytes_max - 16 - "{}\n".len));
    sink.flush(0);
    try fixture.expectFile("usage.jsonl", "{\"u\":1}\n{\"u\":2}\n{}\n");
    // Written out, the whole stream is room again.
    try std.testing.expect(sink.tryAppendKeepingFree(.usage, "{}", sink_mod.usage_buffer_bytes_max - "{}\n".len));
}

test "close writes and syncs what is still buffered" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var sink: Sink = undefined;
    try fixture.open(&sink);
    try sink.append(.usage, "{\"u\":1}");
    try sink.append(.access, "{\"a\":1}");
    sink.appendLossy(.console, "[w] last words");
    sink.close();

    try fixture.expectFile("usage.jsonl", "{\"u\":1}\n");
    try fixture.expectFile("access.jsonl", "{\"a\":1}\n");
    try fixture.expectFile("console.txt", "[w] last words\n");
}

test "a missing directory fails the open and leaves nothing open" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const missing = try std.fmt.bufPrint(&path_buffer, "{s}/missing", .{fixture.path()});
    var sink: Sink = undefined;
    try std.testing.expectError(error.FileNotFound, sink.open(std.testing.allocator, .{
        .directory = missing,
        .console_fd = fixture.console.handle,
    }));
    // The testing allocator fails this test if a stream buffer leaked.
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.access("missing", .{}));
}

test "a symlink planted under a record file's name is refused" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    try fixture.tmp.dir.symLink("elsewhere.txt", "access.jsonl", .{});
    var sink: Sink = undefined;
    try std.testing.expectError(error.SymLinkLoop, fixture.open(&sink));
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.access("elsewhere.txt", .{}));
}

test "a failed write is counted per flush and keeps its records buffered" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    // A read-only descriptor refuses every write.
    const read_only = try fixture.tmp.dir.openFile("console.txt", .{ .mode = .read_only });
    defer read_only.close();
    var sink: Sink = undefined;
    try sink.open(std.testing.allocator, .{ .directory = null, .console_fd = read_only.handle });
    defer sink.close();

    sink.appendLossy(.console, "[w] one");
    sink.flushConsole();
    var stats = sink.stats(.console);
    try std.testing.expectEqual(@as(u64, 1), stats.write_errors);
    try std.testing.expectEqual(@as(u64, 0), stats.bytes_written);

    // The first record stays buffered and is retried ahead of the second.
    sink.appendLossy(.console, "[w] two");
    sink.flushConsole();
    stats = sink.stats(.console);
    try std.testing.expectEqual(@as(u64, 2), stats.appended);
    try std.testing.expectEqual(@as(u64, 2), stats.write_errors);
    try std.testing.expectEqual(@as(u64, 0), stats.dropped);
}

test "without a directory record streams count what they discard and the console still writes" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var sink: Sink = undefined;
    try sink.open(std.testing.allocator, .{ .directory = null, .console_fd = fixture.console.handle });
    defer sink.close();

    try std.testing.expect(!sink.enabled(.logs));
    try std.testing.expect(!sink.enabled(.access));
    try std.testing.expect(!sink.enabled(.usage));
    try std.testing.expect(sink.enabled(.console));

    // A disabled stream accepts the record, so a producer that retries on
    // refusal never stalls on it.
    try sink.append(.usage, "{\"u\":1}");
    try std.testing.expect(sink.tryAppendKeepingFree(.usage, "{\"u\":2}", sink_mod.usage_buffer_bytes_max));
    sink.appendLossy(.access, "{\"a\":1}");
    sink.noteDiscarded(.logs, 2);
    try std.testing.expectEqual(@as(u64, 2), sink.stats(.usage).discarded);
    try std.testing.expectEqual(@as(u64, 1), sink.stats(.access).discarded);
    try std.testing.expectEqual(@as(u64, 2), sink.stats(.logs).discarded);
    try std.testing.expectEqual(@as(u64, 0), sink.stats(.usage).appended);

    // There is no file to reopen, so a reopen request changes nothing.
    sink.requestReopen();
    sink.flush(0);

    sink.appendLossy(.console, "[w] still here");
    sink.flushConsole();
    try fixture.expectFile("console.txt", "[w] still here\n");
}

test "a record flush leaves console lines to the console flusher" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var sink: Sink = undefined;
    try fixture.open(&sink);
    defer sink.close();

    try sink.append(.usage, "{\"u\":1}");
    sink.appendLossy(.console, "[w] waits");
    // The record files never wait on stderr, so a stalled stderr reader
    // cannot hold the flush that frees the usage stream.
    sink.flush(0);
    try fixture.expectFile("usage.jsonl", "{\"u\":1}\n");
    try fixture.expectFile("console.txt", "");
    try std.testing.expectEqual(@as(u64, 0), sink.stats(.console).bytes_written);

    sink.flushConsole();
    try fixture.expectFile("console.txt", "[w] waits\n");
}

test "console output larger than one write batch reaches stderr whole and in order" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var sink: Sink = undefined;
    try fixture.open(&sink);
    defer sink.close();

    // Lines of uneven length, so batch ends fall at different offsets, and
    // several write batches' worth in total.
    var expected: std.array_list.Aligned(u8, null) = .empty;
    defer expected.deinit(std.testing.allocator);
    var line_buffer: [256]u8 = undefined;
    var index: usize = 0;
    while (expected.items.len < 3 * sink_mod.console_write_bytes_max) : (index += 1) {
        const line = try std.fmt.bufPrint(&line_buffer, "[w] line {d} {s}", .{
            index,
            ("x" ** 200)[0 .. index % 200],
        });
        sink.appendLossy(.console, line);
        try expected.appendSlice(std.testing.allocator, line);
        try expected.append(std.testing.allocator, '\n');
    }
    try std.testing.expectEqual(@as(u64, 0), sink.stats(.console).dropped);

    sink.flushConsole();
    try fixture.expectFile("console.txt", expected.items);
}

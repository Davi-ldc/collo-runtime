//! The worker's `std.log` sink (`zygote/log_sink.zig`) over a state page in
//! this process: a line logged after `install` lands in the page's console
//! ring as the runtime's, at its level and under request id 0, a scoped line
//! names its scope, a line over the ring's cap is cut and flagged, nothing is
//! published once the sink is uninstalled, and the runtime's lines and the
//! VM thread's console lines interleave whole when they race. The tests call
//! the sink directly, since the test runner owns this binary's `logFn`; a
//! real worker's lines through `std.log` are covered by the
//! `zygote-integration` lane.

const std = @import("std");
const zygote = @import("collo_zygote");
const worker_shared_page = @import("collo_worker_state").page;

const log_sink = zygote.log_sink;
const LogLineFlags = worker_shared_page.LogLineFlags;

/// A state page in a memfd of this process, mapped once, as a worker child
/// maps its own.
const TestPage = struct {
    fd: std.posix.fd_t,
    view: worker_shared_page.WorkerWriterView,

    fn init(self: *TestPage) !void {
        self.fd = try worker_shared_page.createMemfd("collo-test-log-sink");
        errdefer std.posix.close(self.fd);
        self.view = try worker_shared_page.mapReadWrite(self.fd);
        self.view.initializeCrashDefault();
    }

    fn deinit(self: *TestPage) void {
        self.view.deinit();
        std.posix.close(self.fd);
    }

    /// Every line the ring holds, drained into `scratch`.
    fn drain(self: *TestPage, scratch: []u8, out: []worker_shared_page.DrainedLogLine) !usize {
        return self.view.drainLogLinesChecked(scratch, out);
    }
};

test "a line logged after install lands in the console ring as the runtime's, under request id 0" {
    var page: TestPage = undefined;
    try page.init();
    defer page.deinit();

    log_sink.install(&page.view);
    // A failed expectation must not leave the sink on a page that unmaps.
    errdefer log_sink.uninstall();
    try std.testing.expect(log_sink.tryPublish(.warn, .default, "worker event loop failed: {s}", .{"BrokenPipe"}));
    try std.testing.expect(log_sink.tryPublish(.err, .sentinel, "memory events read failed: {d}", .{5}));
    log_sink.uninstall();

    var scratch: [2 * worker_shared_page.LOG_LINE_BYTES_MAX]u8 = undefined;
    var lines: [4]worker_shared_page.DrainedLogLine = undefined;
    const count = try page.drain(&scratch, &lines);
    try std.testing.expectEqual(@as(usize, 2), count);

    try std.testing.expectEqual(@intFromEnum(worker_shared_page.LogLevel.warn), lines[0].header.level);
    try std.testing.expectEqual(LogLineFlags.runtime, lines[0].header.flags);
    try std.testing.expectEqual(@as(u64, 0), lines[0].header.request_id);
    try std.testing.expect(lines[0].header.ts_mono_ns != 0);
    try std.testing.expectEqualStrings("worker event loop failed: BrokenPipe", lines[0].payload);

    // A scoped line names its scope, as the default handler does.
    try std.testing.expectEqual(@intFromEnum(worker_shared_page.LogLevel.err), lines[1].header.level);
    try std.testing.expectEqualStrings("(sentinel) memory events read failed: 5", lines[1].payload);
}

test "a line over the console ring's cap is cut and flagged truncated" {
    var page: TestPage = undefined;
    try page.init();
    defer page.deinit();

    const long_text: [worker_shared_page.LOG_LINE_BYTES_MAX + 100]u8 = @splat('x');
    log_sink.install(&page.view);
    errdefer log_sink.uninstall();
    try std.testing.expect(log_sink.tryPublish(.info, .default, "{s}", .{&long_text}));
    log_sink.uninstall();

    var scratch: [2 * worker_shared_page.LOG_LINE_BYTES_MAX]u8 = undefined;
    var lines: [2]worker_shared_page.DrainedLogLine = undefined;
    try std.testing.expectEqual(@as(usize, 1), try page.drain(&scratch, &lines));
    try std.testing.expectEqual(worker_shared_page.LOG_LINE_BYTES_MAX, lines[0].payload.len);
    try std.testing.expectEqual(LogLineFlags.runtime | LogLineFlags.truncated, lines[0].header.flags);
}

test "nothing reaches a page once the sink is uninstalled" {
    var page: TestPage = undefined;
    try page.init();
    defer page.deinit();

    try std.testing.expect(!log_sink.tryPublish(.warn, .default, "before install", .{}));
    log_sink.install(&page.view);
    log_sink.uninstall();
    try std.testing.expect(!log_sink.tryPublish(.warn, .default, "after uninstall", .{}));

    var scratch: [worker_shared_page.LOG_LINE_BYTES_MAX]u8 = undefined;
    var lines: [2]worker_shared_page.DrainedLogLine = undefined;
    try std.testing.expectEqual(@as(usize, 0), try page.drain(&scratch, &lines));
}

test "the runtime's lines and the VM thread's console lines interleave whole when they race" {
    var page: TestPage = undefined;
    try page.init();
    defer page.deinit();

    log_sink.install(&page.view);
    defer log_sink.uninstall();
    // A second thread logs as the sentinel or the crypto pool would while
    // this one publishes console lines as the VM thread does.
    const runtime_thread = try std.Thread.spawn(.{}, publishRuntimeLines, .{});
    for (0..racing_lines_per_producer) |index|
        page.view.publishLogLine(.info, 0, index + 1, 1, "console line");
    runtime_thread.join();

    var scratch: [2 * worker_shared_page.LOG_LINE_BYTES_MAX]u8 = undefined;
    var lines: [64]worker_shared_page.DrainedLogLine = undefined;
    var runtime_count: usize = 0;
    var console_count: usize = 0;
    // Each drain returns at least one line until the ring is empty, so the
    // loop ends within one pass per line.
    for (0..2 * racing_lines_per_producer + 1) |_| {
        const count = try page.drain(&scratch, &lines);
        if (count == 0)
            break;
        for (lines[0..count]) |line| {
            if (line.header.flags & LogLineFlags.runtime != 0) {
                try std.testing.expectEqualStrings("runtime line", line.payload);
                runtime_count += 1;
            } else {
                try std.testing.expectEqualStrings("console line", line.payload);
                console_count += 1;
            }
        }
    }
    const dropped = page.view.loadLogDropCounters().lines;
    try std.testing.expectEqual(@as(u64, 0), dropped);
    try std.testing.expectEqual(racing_lines_per_producer, runtime_count);
    try std.testing.expectEqual(racing_lines_per_producer, console_count);
}

/// Lines each producer of the race writes: together with their frame
/// headers they fill well under the ring's `LOG_RING_BYTES`, so none is
/// dropped for room.
const racing_lines_per_producer: usize = 1000;

fn publishRuntimeLines() void {
    for (0..racing_lines_per_producer) |_| {
        const published = log_sink.tryPublish(.info, .default, "runtime line", .{});
        std.debug.assert(published);
    }
}

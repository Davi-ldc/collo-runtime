//! Where `std.log` lines go in every process of the binary, whose
//! `std_options.logFn` is `logFn` (`runtime/src/main.zig`). In the server,
//! the zygote and the gateway nothing is installed, and a line goes to the
//! process's standard error through `std.log.defaultLog`. A worker child
//! installs its state page once it has mapped it (`child_boot.zig`), and
//! from then on a line from any of its threads goes into the page's console
//! ring, at its own level, under request id 0 and flagged
//! `LogLineFlags.runtime`: the child pointed its standard error at /dev/null
//! when it closed the descriptors it was not given, and a worker must not
//! write lines the server would print as its own. The server writes a runtime
//! line to its own stderr, never to the tenant's log
//! (`server/analytics/logs.zig`). Lines a child logs between that close and
//! the page's mapping are lost; its boot trace covers that stretch.
//!
//! One installation per process. A line that finds the sink installed holds
//! `mutex` from its second check to its publish, so `uninstall` returns only
//! once no line is in flight, and the caller may unmap the page then. The
//! ring's producers, these lines and the VM thread's console lines, are
//! serialized by the page itself (`common/worker_state/page/console_ring.zig`).
//! Lock order: `mutex`, then the ring's lock.

const std = @import("std");
const worker_shared_page = @import("collo_worker_state").page;
const process = @import("collo_os").process;

/// Guards `installed` against `uninstall` for the length of a publish.
var mutex: std.Thread.Mutex = .{};
/// Read once without `mutex` by every line, so a process with no sink, the
/// server among them, never takes the lock.
var installed: std.atomic.Value(?*worker_shared_page.WorkerWriterView) = .init(null);

/// Sends every later log line of this process into `view`'s console ring.
/// `view` stays borrowed until `uninstall` returns.
pub fn install(view: *worker_shared_page.WorkerWriterView) void {
    mutex.lock();
    defer mutex.unlock();
    std.debug.assert(installed.load(.monotonic) == null);
    installed.store(view, .release);
}

/// Sends later lines back to standard error. Returns once no line is being
/// published into the page `install` borrowed.
pub fn uninstall() void {
    mutex.lock();
    defer mutex.unlock();
    installed.store(null, .release);
}

/// The binary's `std_options.logFn`.
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (tryPublish(level, scope, format, args))
        return;
    std.log.defaultLog(level, scope, format, args);
}

/// Publishes one line into the installed page's console ring; false when no
/// page is installed. A line longer than `LOG_LINE_BYTES_MAX` is cut and
/// flagged truncated, as the ring cuts any line.
pub fn tryPublish(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) bool {
    if (installed.load(.acquire) == null)
        return false;
    mutex.lock();
    defer mutex.unlock();
    const view = installed.load(.acquire) orelse return false;

    const prefix = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ";
    // One byte past the ring's cap, so a line that reaches it is longer than
    // the cap and the ring cuts it at a UTF-8 boundary.
    var buffer: [worker_shared_page.LOG_LINE_BYTES_MAX + 1]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var flags: u8 = worker_shared_page.LogLineFlags.runtime;
    writer.print(prefix ++ format, args) catch |err| switch (err) {
        // The line did not fit the buffer, so it goes out as far as it got.
        error.WriteFailed => flags |= worker_shared_page.LogLineFlags.truncated,
    };
    view.publishLogLine(ringLevel(level), flags, 0, process.monotonicNowNsOrZero(), writer.buffered());
    return true;
}

fn ringLevel(level: std.log.Level) worker_shared_page.LogLevel {
    return switch (level) {
        .err => .err,
        .warn => .warn,
        .info => .info,
        .debug => .debug,
    };
}

//! Where `std.log` lines go in every process of the binary, whose
//! `std_options.logFn` is `logFn` (`runtime/src/main.zig`). In the server,
//! the zygote and the gateway nothing is installed, and a line goes to the
//! process's standard error through `std.log.defaultLog`. A worker child
//! installs its state page as soon as `WorkerInit` brings it
//! (`child_boot.zig`), and from then on a line from any of its threads goes
//! into the page's console ring, at its own level, under request id 0 and
//! flagged `LogLineFlags.runtime`: right after, the child points its standard
//! error at /dev/null as it closes the descriptors it was not given, and a
//! worker must not write lines the server would print as its own. The server
//! writes a runtime line to its own stderr, never to the tenant's log
//! (`server/analytics/logs.zig`). A line the child logs before the
//! installation goes to the standard error it inherited, the server's, so no
//! stretch of its boot logs nowhere.
//!
//! One installation per process. A line that finds the sink installed holds
//! `mutex` from its second check to its publish, so `uninstall` returns only
//! once no line is in flight, and the caller may unmap the page then. The
//! ring's producers, these lines and the VM thread's console lines, are
//! serialized by the page itself (`common/worker_state/page/console_ring.zig`).
//! Lock order: `mutex`, then the ring's lock.
//!
//! A line of `never_wait_scope` waits for neither lock. The sentinel logs
//! under it (`worker/runtime/sentinel.zig`), and it is the one thread that
//! must never wait for another: it ends the worker once the worker's cgroup
//! passes `memory.high`, past which the kernel throttles each thread that
//! charges memory there on its way back to user space, wherever it stands,
//! inside either lock included, and an exit that waited out that thread
//! would let the worker keep growing toward `memory.max`. Such a line takes
//! each lock only when it is free and is dropped otherwise: uncounted when
//! the sink is busy, since the page may be on its way out, and counted with
//! the ring's own drops when the ring is.

const std = @import("std");
const worker_shared_page = @import("collo_worker_state").page;
const process = @import("collo_os").process;

/// The `std.log` scope whose lines never wait for a lock, as the file header
/// says. `worker/runtime/sentinel.zig` logs every line under it, and the
/// line's text names it as any scoped line does.
pub const never_wait_scope = .sentinel;

/// Guards `installed` against `uninstall` for the length of a publish. Public
/// so a test can stand for a line in flight.
pub var mutex: std.Thread.Mutex = .{};
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
/// flagged truncated, as the ring cuts any line. A line of
/// `never_wait_scope` that finds the sink or the ring busy is dropped, and
/// the call still returns true.
pub fn tryPublish(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) bool {
    if (installed.load(.acquire) == null)
        return false;

    // The line is formatted before either lock, which then guards only the
    // publish.
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
    const ts_mono_ns = process.monotonicNowNsOrZero();

    const never_waits = comptime scope == never_wait_scope;
    if (never_waits) {
        if (!mutex.tryLock())
            return true;
    } else {
        mutex.lock();
    }
    defer mutex.unlock();
    const view = installed.load(.acquire) orelse return false;
    if (never_waits) {
        _ = view.tryPublishLogLine(ringLevel(level), flags, 0, ts_mono_ns, writer.buffered());
    } else {
        view.publishLogLine(ringLevel(level), flags, 0, ts_mono_ns, writer.buffered());
    }
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

//! The signal monitor (`server/boot/signals.zig`): `start` masks SIGHUP, SIGINT and SIGTERM on
//! the calling thread and `deinit` restores the mask; a first stop signal reaches the attached
//! target once, including one that came before `attach`, and none after `detach`; a second stop
//! signal ends the process with 128 plus its number; a SIGHUP makes the attached target's
//! analytics sink open its renamed record files again at its next flush, including a SIGHUP
//! that came before `attach`, and counts toward no stop. The signal tests run in a forked child,
//! whose only threads are the forking thread and the monitor, so a process-directed signal can
//! reach no thread that leaves it unblocked, and the child's exit status carries the result.
//! `zig build smoke` delivers a terminal's hangup and Ctrl-C to a whole `collo serve`.
//! Lane: `server-core-test`.

const std = @import("std");
const signals_mod = @import("collo_server_main").boot.signals;
const Sink = @import("collo_server_analytics").Sink;

const linux = std.os.linux;
const posix = std.posix;
const Signals = signals_mod.Signals;

/// How long a child waits for its monitor to take a signal before it gives up.
const signal_wait_ms_max: u32 = 5_000;
/// What a child exits with when every check held.
const child_ok: u8 = 0;

test "start masks the three signals, the monitor joins untouched and deinit restores the mask" {
    const before = currentMask();
    const hup_blocked_before = posix.sigismember(&before, posix.SIG.HUP);
    const int_blocked_before = posix.sigismember(&before, posix.SIG.INT);
    const term_blocked_before = posix.sigismember(&before, posix.SIG.TERM);

    var sink: Sink = undefined;
    try sink.open(std.testing.allocator, .{ .directory = null });
    defer sink.close();
    var signals: Signals = undefined;
    try signals.start();
    // A failed expectation must not leave the signals blocked for the rest of the test binary.
    var started = true;
    defer if (started) signals.deinit();
    const during = currentMask();
    try std.testing.expect(posix.sigismember(&during, posix.SIG.HUP));
    try std.testing.expect(posix.sigismember(&during, posix.SIG.INT));
    try std.testing.expect(posix.sigismember(&during, posix.SIG.TERM));

    var counter: TargetCounter = .{};
    signals.attach(counter.target(&sink));
    signals.detach();
    try std.testing.expectEqual(@as(u32, 0), counter.stops.load(.acquire));
    try std.testing.expect(!sink.reopen_requested.load(.acquire));
    try std.testing.expect(!signals.stopRequested());
    signals.deinit();
    started = false;

    const after = currentMask();
    try std.testing.expectEqual(hup_blocked_before, posix.sigismember(&after, posix.SIG.HUP));
    try std.testing.expectEqual(int_blocked_before, posix.sigismember(&after, posix.SIG.INT));
    try std.testing.expectEqual(term_blocked_before, posix.sigismember(&after, posix.SIG.TERM));
}

test "a first signal reaches the target attached before or after it, and none after detach" {
    try expectChildExit(earlyAndDetachedChild, child_ok);
}

test "a second signal ends the process with 128 plus its number" {
    try expectChildExit(secondSignalChild, 128 + posix.SIG.INT);
}

test "a hangup makes the sink open its renamed files again, before and after a stop, and never ends the process" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(directory);
    hangup_directory = directory;
    try expectChildExit(hangupChild, child_ok);
}

/// Each check that fails exits with its own status, so the parent's report names it.
fn earlyAndDetachedChild() u8 {
    var sink: Sink = undefined;
    // A forked child never returns to the test runner's leak check.
    sink.open(std.heap.page_allocator, .{ .directory = null }) catch return 9;
    defer sink.close();
    {
        var signals: Signals = undefined;
        signals.start() catch return 10;
        defer signals.deinit();
        sendToSelf(posix.SIG.TERM) catch return 11;
        if (!waitFor(&signals, stopWasRequested)) return 12;
        var counter: TargetCounter = .{};
        signals.attach(counter.target(&sink));
        defer signals.detach();
        if (counter.stops.load(.acquire) != 1) return 13;
    }
    {
        var signals: Signals = undefined;
        signals.start() catch return 20;
        defer signals.deinit();
        var counter: TargetCounter = .{};
        signals.attach(counter.target(&sink));
        signals.detach();
        sendToSelf(posix.SIG.TERM) catch return 21;
        if (!waitFor(&signals, stopWasRequested)) return 22;
        if (counter.stops.load(.acquire) != 0) return 23;
    }
    return child_ok;
}

fn secondSignalChild() u8 {
    var sink: Sink = undefined;
    sink.open(std.heap.page_allocator, .{ .directory = null }) catch return 29;
    var signals: Signals = undefined;
    signals.start() catch return 30;
    var counter: TargetCounter = .{};
    signals.attach(counter.target(&sink));
    sendToSelf(posix.SIG.TERM) catch return 31;
    if (!waitFor(&counter, stopWasCalled)) return 32;
    if (counter.stops.load(.acquire) != 1) return 33;
    // The order in which pending standard signals are delivered is unspecified (signal(7)), so the
    // second one is sent only after the monitor took the first, and the exit status names it.
    sendToSelf(posix.SIG.INT) catch return 34;
    var waited_ms: u32 = 0;
    while (waited_ms < signal_wait_ms_max) : (waited_ms += 1)
        std.Thread.sleep(std.time.ns_per_ms);
    return 35;
}

/// The analytics directory `hangupChild` works in, set before the fork.
var hangup_directory: []const u8 = "";

fn hangupChild() u8 {
    var sink: Sink = undefined;
    sink.open(std.heap.page_allocator, .{ .directory = hangup_directory }) catch return 49;
    defer sink.close();
    var directory = std.fs.openDirAbsolute(hangup_directory, .{}) catch return 48;
    defer directory.close();
    var probe: ReopenProbe = .{ .sink = &sink, .directory = directory };
    var signals: Signals = undefined;
    signals.start() catch return 50;
    defer signals.deinit();

    // Sent before the target exists: whether the monitor reads it before or after `attach`, the
    // sink is asked to open the name again.
    directory.rename("usage.jsonl", "usage.jsonl.1") catch return 51;
    sendToSelf(posix.SIG.HUP) catch return 52;
    var counter: TargetCounter = .{};
    signals.attach(counter.target(&sink));
    defer signals.detach();
    if (!waitFor(&probe, reopenedUsageFile)) return 53;

    // Each signal is sent only after the monitor took the one before.
    directory.rename("usage.jsonl", "usage.jsonl.2") catch return 54;
    sendToSelf(posix.SIG.HUP) catch return 55;
    if (!waitFor(&probe, reopenedUsageFile)) return 56;
    if (counter.stops.load(.acquire) != 0) return 57;
    if (signals.stopRequested()) return 58;

    sendToSelf(posix.SIG.TERM) catch return 59;
    if (!waitFor(&counter, stopWasCalled)) return 60;
    // After a stop, a hangup still only reopens: were it counted as a second stop signal, the
    // process would end here with 128 plus its number.
    directory.rename("usage.jsonl", "usage.jsonl.3") catch return 61;
    sendToSelf(posix.SIG.HUP) catch return 62;
    if (!waitFor(&probe, reopenedUsageFile)) return 63;
    if (counter.stops.load(.acquire) != 1) return 64;
    return child_ok;
}

const TargetCounter = struct {
    stops: std.atomic.Value(u32) = .init(0),

    fn target(self: *TargetCounter, analytics: *Sink) Signals.Target {
        return .{ .context = self, .request_stop = &requestStop, .analytics = analytics };
    }

    fn requestStop(context: *anyopaque) void {
        const self: *TargetCounter = @ptrCast(@alignCast(context));
        _ = self.stops.fetchAdd(1, .acq_rel);
    }
};

/// The sink a hangup asks to reopen, and the directory its files are in.
const ReopenProbe = struct {
    sink: *Sink,
    directory: std.fs.Dir,
};

/// Whether a flush has opened `usage.jsonl` under its name again since it was renamed away,
/// which a flush does only for a reopen that was asked for.
fn reopenedUsageFile(probe: *ReopenProbe) bool {
    probe.sink.flush(0);
    probe.directory.access("usage.jsonl", .{}) catch return false;
    return true;
}

fn stopWasRequested(signals: *Signals) bool {
    return signals.stopRequested();
}

fn stopWasCalled(counter: *TargetCounter) bool {
    return counter.stops.load(.acquire) != 0;
}

/// Whether `condition(subject)` holds within `signal_wait_ms_max`.
fn waitFor(subject: anytype, condition: fn (@TypeOf(subject)) bool) bool {
    var waited_ms: u32 = 0;
    while (waited_ms < signal_wait_ms_max) : (waited_ms += 1) {
        if (condition(subject)) return true;
        std.Thread.sleep(std.time.ns_per_ms);
    }
    return condition(subject);
}

fn sendToSelf(signal_number: u8) !void {
    try posix.kill(linux.getpid(), signal_number);
}

/// Runs `child` in a forked copy of the test binary and expects it to exit with `status`.
fn expectChildExit(child: fn () u8, status: u8) !void {
    const pid = try posix.fork();
    if (pid == 0) {
        // The monitor reports a second signal on stderr; the exit status carries every result.
        const null_fd = posix.open("/dev/null", .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0) catch
            linux.exit_group(40);
        posix.dup2(null_fd, posix.STDERR_FILENO) catch linux.exit_group(41);
        linux.exit_group(child());
    }
    const wait = posix.waitpid(pid, 0);
    try std.testing.expect(std.c.W.IFEXITED(wait.status));
    try std.testing.expectEqual(@as(u32, status), std.c.W.EXITSTATUS(wait.status));
}

fn currentMask() posix.sigset_t {
    var mask: posix.sigset_t = undefined;
    posix.sigprocmask(posix.SIG.BLOCK, null, &mask);
    return mask;
}

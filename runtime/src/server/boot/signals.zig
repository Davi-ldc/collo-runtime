//! The signals the server process acts on, read from one signalfd by a
//! monitor thread: SIGINT and SIGTERM stop the server, and SIGHUP asks it to
//! reopen its analytics files.
//!
//! `start` masks the three signals on the calling thread, opens a signalfd for
//! them and starts the monitor thread, which reads them until `deinit`. It
//! must run before the process starts any other long-lived thread: threads
//! inherit their creator's mask, and a thread that left one of the signals
//! unblocked would take it with its default action, which for all three ends
//! the process without draining or cleaning up. Children start with an empty
//! mask in a session of their own (`spawnInternal` in `common/os.zig`), so a
//! terminal's Ctrl-C or hangup, which the terminal sends to its whole
//! foreground process group, reaches only the server, which then stops its
//! children itself, or reopens its files and keeps serving.
//!
//! On the first SIGINT or SIGTERM the monitor records the stop and calls the
//! attached target's `request_stop`, if any; `attach` calls it at once for a
//! stop that came before it. A second one ends the process at once with exit
//! status 128 plus the signal number, through `exit_group`, which runs no
//! atexit handler or static destructor while other threads still run. A
//! SIGHUP asks the attached target's analytics sink to reopen its record
//! files (`Sink.requestReopen` in `server/analytics/sink.zig`, which the
//! sink's next flush carries out) and counts toward no stop, before or after
//! one. One that comes while no target is attached waits for the next
//! `attach`, so a rotation during the boot still reaches the files the
//! server opened before it attached. The monitor lives from the start of the
//! boot until `deinit`, the last step of the teardown, so a second stop
//! signal behaves the same during the boot, the drain and the teardown, and
//! no signal is left pending when the mask is restored halfway through
//! cleanup.
//!
//! The thread that called `start` calls `attach`, `detach` and `deinit`. The
//! monitor calls the target while holding `target_mutex`, so once `detach`
//! returns the target is never called again; the target must not call back
//! into this type.

const std = @import("std");
const fd_mod = @import("collo_os").fd;
const Sink = @import("collo_server_analytics").Sink;
const report = @import("report.zig");

const linux = std.os.linux;
const posix = std.posix;

pub const Signals = struct {
    previous_mask: posix.sigset_t,
    signal_fd: fd_mod.OwnedFd,
    /// Wakes the monitor so `deinit` can join it.
    wake_fd: fd_mod.OwnedFd,
    thread: std.Thread,
    /// Taken before anything the target locks.
    target_mutex: std.Thread.Mutex,
    /// Guarded by `target_mutex`.
    target: ?Target,
    /// A SIGHUP came while no target was attached. Guarded by
    /// `target_mutex`.
    reopen_pending: bool,
    /// Set under `target_mutex` by the first stop signal.
    stop_requested: std.atomic.Value(bool),
    /// Set under `target_mutex` when the monitor cannot poll: the server is
    /// stopped, but not as a signal asked.
    monitor_failed: std.atomic.Value(bool),

    pub const Target = struct {
        context: *anyopaque,
        /// Asks the server to stop. Must return promptly and be safe to call
        /// from any thread.
        request_stop: *const fn (context: *anyopaque) void,
        /// The server's analytics sink, which a hangup asks to reopen its
        /// record files.
        analytics: *Sink,
    };

    /// Blocks the three signals on the calling thread and starts the
    /// monitor. Fails without changing the mask.
    pub fn start(self: *Signals) !void {
        const mask = monitoredMask();
        var previous_mask: posix.sigset_t = undefined;
        posix.sigprocmask(posix.SIG.BLOCK, &mask, &previous_mask);
        errdefer posix.sigprocmask(posix.SIG.SETMASK, &previous_mask, null);

        var signal_fd = fd_mod.OwnedFd.fromRaw(try posix.signalfd(-1, &mask, linux.SFD.CLOEXEC | linux.SFD.NONBLOCK));
        errdefer signal_fd.deinit();
        var wake_fd = fd_mod.OwnedFd.fromRaw(try posix.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK));
        errdefer wake_fd.deinit();
        self.* = .{
            .previous_mask = previous_mask,
            .signal_fd = signal_fd,
            .wake_fd = wake_fd,
            .thread = undefined,
            .target_mutex = .{},
            .target = null,
            .reopen_pending = false,
            .stop_requested = .init(false),
            .monitor_failed = .init(false),
        };
        self.thread = try std.Thread.spawn(.{}, monitor, .{self});
    }

    /// Hands stop and reopen requests to `target` until `detach`, including
    /// a stop and a reopen that came before this call. `target.context` and
    /// `target.analytics` must stay valid until `detach` returns.
    pub fn attach(self: *Signals, target: Target) void {
        self.target_mutex.lock();
        defer self.target_mutex.unlock();
        std.debug.assert(self.target == null);
        self.target = target;
        if (self.reopen_pending) {
            self.reopen_pending = false;
            target.analytics.requestReopen();
        }
        if (self.stop_requested.load(.acquire) or self.monitor_failed.load(.acquire))
            target.request_stop(target.context);
    }

    /// Stops handing requests to the attached target. A later first stop
    /// signal is still recorded, and a second one still ends the process.
    pub fn detach(self: *Signals) void {
        self.target_mutex.lock();
        defer self.target_mutex.unlock();
        self.target = null;
    }

    /// True once a signal asked the server to stop.
    pub fn stopRequested(self: *const Signals) bool {
        return self.stop_requested.load(.acquire);
    }

    /// Joins the monitor, closes the descriptors and restores the mask the
    /// calling thread had before `start`. Call it after `detach`. A signal
    /// that arrives once the monitor has joined takes its default action
    /// when the mask is restored.
    pub fn deinit(self: *Signals) void {
        const one: u64 = 1;
        // Writing 1 to an eventfd fails only on a counter near its maximum
        // or a closed descriptor. Without the wake the join below never
        // returns, so the process ends here instead of hanging.
        fd_mod.writeAllRaw(self.wake_fd.fd(), std.mem.asBytes(&one)) catch |err|
            std.debug.panic("cannot wake the signal monitor: {s}", .{@errorName(err)});
        self.thread.join();
        std.debug.assert(self.target == null);
        self.wake_fd.deinit();
        self.signal_fd.deinit();
        posix.sigprocmask(posix.SIG.SETMASK, &self.previous_mask, null);
        self.* = undefined;
    }

    fn monitor(self: *Signals) void {
        var poll_fds = [_]posix.pollfd{
            .{ .fd = self.signal_fd.fd(), .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = self.wake_fd.fd(), .events = posix.POLL.IN, .revents = 0 },
        };
        var stop_signals_seen: u32 = 0;
        // Ends only when `deinit` writes the wake descriptor, or when the
        // process ends on a second stop signal.
        while (true) {
            _ = posix.poll(&poll_fds, -1) catch |err| {
                // No signal can reach the server once the monitor is gone,
                // so it is stopped now rather than left unstoppable.
                std.log.err("signal monitor cannot poll: {s}; stopping the server", .{@errorName(err)});
                self.recordStop(&self.monitor_failed);
                return;
            };
            if ((poll_fds[1].revents & posix.POLL.IN) != 0)
                return;
            if ((poll_fds[0].revents & posix.POLL.IN) == 0)
                continue;
            while (self.readSignal()) |signal_number| {
                if (signal_number == posix.SIG.HUP) {
                    self.requestReopen();
                    continue;
                }
                stop_signals_seen += 1;
                if (stop_signals_seen == 1) {
                    self.recordStop(&self.stop_requested);
                } else {
                    report.line("a second shutdown signal ends the server without draining", .{});
                    linux.exit_group(exitStatusOf(signal_number));
                }
            }
        }
    }

    /// Sets `flag` and calls the attached target under `target_mutex`, so
    /// `attach` either sees the flag or the target is already in place, and
    /// the target is called exactly once.
    fn recordStop(self: *Signals, flag: *std.atomic.Value(bool)) void {
        self.target_mutex.lock();
        defer self.target_mutex.unlock();
        flag.store(true, .release);
        if (self.target) |target|
            target.request_stop(target.context);
    }

    fn requestReopen(self: *Signals) void {
        self.target_mutex.lock();
        defer self.target_mutex.unlock();
        if (self.target) |target| {
            target.analytics.requestReopen();
        } else {
            self.reopen_pending = true;
        }
    }

    /// The next queued signal, or null when none is queued.
    fn readSignal(self: *Signals) ?u32 {
        var info: linux.signalfd_siginfo = undefined;
        const length = posix.read(self.signal_fd.fd(), std.mem.asBytes(&info)) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => {
                std.log.warn("signal monitor cannot read the signalfd: {s}", .{@errorName(err)});
                return null;
            },
        };
        // The kernel writes whole records to a signalfd.
        if (length != @sizeOf(linux.signalfd_siginfo))
            return null;
        return info.signo;
    }
};

fn monitoredMask() posix.sigset_t {
    var mask = posix.sigemptyset();
    posix.sigaddset(&mask, posix.SIG.HUP);
    posix.sigaddset(&mask, posix.SIG.INT);
    posix.sigaddset(&mask, posix.SIG.TERM);
    return mask;
}

/// The shell convention for a process ended by a signal.
fn exitStatusOf(signal_number: u32) u8 {
    if (signal_number < 128)
        return @intCast(128 + signal_number);
    return 1;
}

//! Cancellable, deadline-bounded fd waits for the connect and HTTP/1 paths.
//!
//! A probe with a readiness driver parks the calling thread until the fd is
//! ready, the stage timeout or the request deadline passes, or the wake fd
//! fires; it rechecks cancellation and the request deadline on every wake. A
//! probe in owner-loop mode never parks: it records the wait and unwinds, and
//! the owner thread enforces the deadlines. A probe with neither returns at
//! once.

const std = @import("std");

const config_mod = @import("config.zig");
const connection_mod = @import("connection.zig");
const readiness = @import("collo_egress_readiness");

const HttpConnection = connection_mod.HttpConnection;
const IoInterest = config_mod.IoInterest;

pub const CancelProbe = struct {
    ctx: ?*anyopaque = null,
    is_canceled_fn: ?*const fn (?*anyopaque) bool = null,
    driver: ?*readiness.Driver = null,
    wake_fd: ?std.posix.fd_t = null,
    request_deadline_mono_ns: u64 = 0,
    /// Owner-loop mode: a wait records its interest and the error to report
    /// at stage expiry here and returns `error.EgressWouldBlock` instead of
    /// parking the thread. The owner thread parks the continuation on its
    /// watch list, resumes it on readiness and enforces the deadlines through
    /// that watch-list entry.
    would_block: ?*WouldBlock = null,

    pub const WouldBlock = struct {
        interest: IoInterest = .read,
        timeout_err: anyerror = error.FetchReadTimeout,
    };

    pub fn isEnabled(self: CancelProbe) bool {
        return self.driver != null or self.would_block != null;
    }

    pub fn isCanceled(self: CancelProbe) bool {
        const callback = self.is_canceled_fn orelse return false;
        return callback(self.ctx);
    }

    pub fn requestDeadlineExpiredAt(self: CancelProbe, now_mono_ns: u64) bool {
        return self.request_deadline_mono_ns != 0 and now_mono_ns >= self.request_deadline_mono_ns;
    }

    fn capDeadlineMonoNs(self: CancelProbe, deadline_mono_ns: u64) u64 {
        if (self.request_deadline_mono_ns == 0)
            return deadline_mono_ns;
        return @min(deadline_mono_ns, self.request_deadline_mono_ns);
    }

    pub fn waitFd(
        self: CancelProbe,
        fd: std.posix.fd_t,
        interest: IoInterest,
        timeout_ms: u32,
        expired_error: anyerror,
    ) !void {
        if (self.would_block) |park| {
            if (self.isCanceled())
                return error.FetchAborted;
            park.* = .{ .interest = interest, .timeout_err = expired_error };
            return error.EgressWouldBlock;
        }
        const driver = self.driver orelse return;
        while (true) {
            if (self.isCanceled())
                return error.FetchAborted;
            const stage_deadline_mono_ns = try readiness.deadlineAfterMs(timeout_ms);
            const deadline_mono_ns = self.capDeadlineMonoNs(stage_deadline_mono_ns);
            if (self.requestDeadlineExpiredAt(readiness.monotonicNowNs() catch deadline_mono_ns))
                return error.FetchRequestDeadlineExceeded;
            var context: u8 = 0;
            const source = readiness.Source{
                .context = &context,
                .handle = .{ .fd = fd },
                .deadline_mono_ns = deadline_mono_ns,
                .want_read = interest == .read,
                .want_write = interest == .write,
            };
            switch (try driver.wait(&.{source}, self.wake_fd)) {
                .ready => return,
                .expired => {
                    if (self.requestDeadlineExpiredAt(readiness.monotonicNowNs() catch deadline_mono_ns))
                        return error.FetchRequestDeadlineExceeded;
                    return expired_error;
                },
                .wake => {
                    if (self.isCanceled())
                        return error.FetchAborted;
                    if (self.requestDeadlineExpiredAt(readiness.monotonicNowNs() catch deadline_mono_ns))
                        return error.FetchRequestDeadlineExceeded;
                    if (self.wake_fd) |wake_fd|
                        drainEventFd(wake_fd);
                    continue;
                },
            }
        }
    }

    pub fn waitConnection(
        self: CancelProbe,
        connection: *HttpConnection,
        interest: IoInterest,
        timeout_ms: u32,
        expired_error: anyerror,
    ) !void {
        return self.waitFd(connection.fd(), interest, timeout_ms, expired_error);
    }
};

pub fn drainEventFd(fd: std.posix.fd_t) void {
    while (true) {
        var value: u64 = 0;
        _ = std.posix.read(fd, std.mem.asBytes(&value)) catch |err| switch (err) {
            error.WouldBlock => return,
            else => |unexpected| {
                std.log.debug("failed to drain egress cancel wake fd: {s}", .{@errorName(unexpected)});
                return;
            },
        };
    }
}

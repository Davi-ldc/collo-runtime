//! Readiness vocabulary shared by the egress client's I/O drivers and their
//! callers.
//!
//! A caller names what it waits on as a `WaitHandle` with read or write
//! interest and gets back a `Ready`, so it does not depend on whether the
//! driver behind the wait uses poll or io_uring.

const std = @import("std");

pub const WaitHandle = union(enum) {
    fd: std.posix.fd_t,

    pub fn eql(self: WaitHandle, other: WaitHandle) bool {
        return switch (self) {
            .fd => |fd| switch (other) {
                .fd => |other_fd| fd == other_fd,
            },
        };
    }
};

pub const Source = struct {
    context: *anyopaque,
    handle: WaitHandle,
    /// Absolute deadline on CLOCK_BOOTTIME, the clock of
    /// `readiness.monotonicNowNs`.
    deadline_mono_ns: u64,
    want_read: bool = true,
    want_write: bool = false,
};

pub const Ready = struct {
    context: *anyopaque,
    readable: bool,
    writable: bool,
};

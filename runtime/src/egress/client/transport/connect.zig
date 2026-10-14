//! Happy Eyeballs (RFC 8305) for one dial: the order and timing of the
//! nonblocking TCP connect attempts over a resolved host's addresses, and the
//! socket calls that start and finish one attempt.
//!
//! Candidates alternate IPv6 and IPv4, starting with IPv6. While attempts are
//! pending a new one is due every `attempt_delay_ns`, up to
//! `max_parallel_attempts` at once; when none is pending the next is due at
//! once. The first attempt to connect wins and the caller closes the rest.
//! `Schedule` decides only order and timing and touches no socket, so the
//! engine's owner thread drives it from its data driver's completions and
//! deadlines, and tests drive it on a fake clock. Every connect wait is
//! bounded by the dial's stall deadline, which the engine owns.

const std = @import("std");
const common_socket = @import("collo_os").socket;

pub const max_parallel_attempts: usize = 4;
/// RFC 8305's recommended delay between connection attempts.
pub const attempt_delay_ns: u64 = 250 * std.time.ns_per_ms;

pub const Launch = struct {
    slot: usize,
    address: std.net.Address,
};

pub const Schedule = struct {
    cursor: CandidateCursor,
    pending: [max_parallel_attempts]bool = @splat(false),
    pending_count: usize = 0,
    next_launch_ns: u64 = 0,

    /// Borrows `addresses` for the schedule's life.
    pub fn init(addresses: []const std.net.Address) Schedule {
        return .{ .cursor = CandidateCursor.init(addresses) };
    }

    /// The next attempt due at `now_ns` and the free slot it takes, or null
    /// when every slot is pending, the delay since the last launch has not
    /// passed, or no candidate is left. The caller starts the attempt and
    /// calls `markPending` if it waits for its connect, or asks again at once
    /// if it connected or failed to start.
    pub fn launchDue(self: *Schedule, now_ns: u64) ?Launch {
        if (self.pending_count == max_parallel_attempts)
            return null;
        if (self.pending_count != 0 and now_ns < self.next_launch_ns)
            return null;
        const slot = self.freeSlot() orelse return null;
        const address = self.cursor.next() orelse return null;
        return .{ .slot = slot, .address = address };
    }

    pub fn markPending(self: *Schedule, slot: usize, now_ns: u64) void {
        std.debug.assert(!self.pending[slot]);
        self.pending[slot] = true;
        self.pending_count += 1;
        self.next_launch_ns = now_ns +| attempt_delay_ns;
    }

    /// The attempt in `slot` connected or failed; the slot is free again.
    pub fn markDone(self: *Schedule, slot: usize) void {
        std.debug.assert(self.pending[slot]);
        self.pending[slot] = false;
        self.pending_count -= 1;
    }

    /// No attempt is pending and no candidate is left: the dial failed.
    pub fn exhausted(self: *const Schedule) bool {
        return self.pending_count == 0 and !self.cursor.hasMore();
    }

    /// The instant the next attempt becomes due while attempts are pending,
    /// or null when no launch waits on the delay.
    pub fn launchDeadlineNs(self: *const Schedule) ?u64 {
        if (self.pending_count == 0 or self.pending_count == max_parallel_attempts)
            return null;
        if (!self.cursor.hasMore())
            return null;
        return self.next_launch_ns;
    }

    fn freeSlot(self: *const Schedule) ?usize {
        for (self.pending, 0..) |pending, slot| {
            if (!pending)
                return slot;
        }
        return null;
    }
};

const Family = enum { ipv6, ipv4, other };

pub const CandidateCursor = struct {
    addresses: []const std.net.Address,
    next_ipv6: usize = 0,
    next_ipv4: usize = 0,
    next_other: usize = 0,
    prefer_ipv6: bool = true,
    remaining: usize,

    pub fn init(addresses: []const std.net.Address) CandidateCursor {
        return .{
            .addresses = addresses,
            .remaining = addresses.len,
        };
    }

    pub fn hasMore(self: *const CandidateCursor) bool {
        return self.remaining != 0;
    }

    pub fn next(self: *CandidateCursor) ?std.net.Address {
        if (self.remaining == 0)
            return null;

        const preferred: Family = if (self.prefer_ipv6) .ipv6 else .ipv4;
        const fallback: Family = if (self.prefer_ipv6) .ipv4 else .ipv6;
        if (self.takeFamily(preferred)) |address| {
            self.prefer_ipv6 = !self.prefer_ipv6;
            self.remaining -= 1;
            return address;
        }
        if (self.takeFamily(fallback)) |address| {
            self.prefer_ipv6 = !self.prefer_ipv6;
            self.remaining -= 1;
            return address;
        }
        if (self.takeFamily(.other)) |address| {
            self.remaining -= 1;
            return address;
        }
        self.remaining = 0;
        return null;
    }

    fn takeFamily(self: *CandidateCursor, family: Family) ?std.net.Address {
        const index_ptr = switch (family) {
            .ipv6 => &self.next_ipv6,
            .ipv4 => &self.next_ipv4,
            .other => &self.next_other,
        };
        while (index_ptr.* < self.addresses.len) {
            const index = index_ptr.*;
            index_ptr.* += 1;
            if (familyOf(self.addresses[index]) == family)
                return self.addresses[index];
        }
        return null;
    }
};

fn familyOf(address: std.net.Address) Family {
    return switch (address.any.family) {
        std.posix.AF.INET6 => .ipv6,
        std.posix.AF.INET => .ipv4,
        else => .other,
    };
}

pub const StartedAttempt = struct {
    /// A nonblocking, close-on-exec TCP socket the caller owns.
    fd: std.posix.fd_t,
    /// The connect completed at once; otherwise it is in progress and the
    /// socket turns writable when it ends either way.
    connected: bool,
};

/// Opens a nonblocking socket for `address` and starts its connect. Fails
/// with the socket or connect error; nothing stays open then.
pub fn startAttempt(address: std.net.Address) !StartedAttempt {
    const fd = try std.posix.socket(
        address.any.family,
        std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK,
        std.posix.IPPROTO.TCP,
    );
    errdefer std.posix.close(fd);

    try common_socket.setTcpNoDelay(fd);

    std.posix.connect(fd, &address.any, address.getOsSockLen()) catch |err| switch (err) {
        error.WouldBlock, error.ConnectionPending => return .{ .fd = fd, .connected = false },
        else => return err,
    };
    return .{ .fd = fd, .connected = true };
}

/// The outcome of an attempt whose socket turned writable: success, or the
/// connect's error (`SO_ERROR`).
pub fn finishAttempt(fd: std.posix.fd_t) !void {
    try common_socket.connectResult(fd);
}

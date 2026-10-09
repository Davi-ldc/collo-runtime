//! The eventfds that wake each side of a session: `command_eventfd` wakes the
//! gateway and `completion_eventfd` the worker, and both sides hold both. A
//! wake carries no data, since the rings and pools are the transport, and a
//! writer signals when `PacketWriteResult.eventfd_notify_required` says the
//! consumer may be asleep. Each side calls these on the thread that runs its
//! endpoint.

const std = @import("std");

const PacketWriteResult = @import("packet_ring.zig").PacketWriteResult;

/// Adds one to the eventfd `fd`. A counter too full to take it is already
/// readable, so `error.WouldBlock` is ignored; other failures are logged.
pub fn notify(fd: std.posix.fd_t) void {
    var one: u64 = 1;
    _ = std.posix.write(fd, std.mem.asBytes(&one)) catch |err| switch (err) {
        error.WouldBlock => return,
        else => |unexpected| {
            std.log.warn("egress shared eventfd notify failed: {s}", .{@errorName(unexpected)});
            return;
        },
    };
}

/// Signals the eventfd `fd` only when `result` says the consumer may be
/// asleep.
pub fn notifyAfterPacketWrite(fd: std.posix.fd_t, result: PacketWriteResult) void {
    if (!result.eventfd_notify_required)
        return;
    notify(fd);
}

/// Resets the eventfd `fd`; an already empty counter is not an error, and
/// other failures are logged.
pub fn drainEventfd(fd: std.posix.fd_t) void {
    var value: u64 = 0;
    _ = std.posix.read(fd, std.mem.asBytes(&value)) catch |err| switch (err) {
        error.WouldBlock => return,
        else => |unexpected| {
            std.log.warn("egress shared eventfd drain failed: {s}", .{@errorName(unexpected)});
            return;
        },
    };
}

//! Packet I/O on the IPC sockets: one sendmsg or recvmsg per packet, with
//! descriptors as SCM_RIGHTS ancillary data, and the byte helpers the codecs
//! beside this file use to lay packets out. Every process of the node calls
//! it; it holds no state, so any thread may use it on a socket that thread
//! owns.
//!
//! Every IPC socket is a connected AF_UNIX SOCK_SEQPACKET, so a packet
//! arrives whole or not at all, and no packet call here retries a partial
//! transfer; `readExact` alone loops, and only on a byte stream. A receive
//! the kernel truncated (MSG_TRUNC or MSG_CTRUNC), and a zero-length
//! datagram that carried descriptors, fail and close every descriptor that
//! did arrive, so a caller never decodes part of a packet and never leaks a
//! descriptor it did not see. Received descriptors are close-on-exec
//! (MSG_CMSG_CLOEXEC) and belong to the `ReceivedPacket` until a caller
//! takes them. Structs cross the socket as raw native-endian bytes
//! (`readStruct`, `writeStruct`), which is sound because both ends run the
//! same binary on one machine.

const std = @import("std");
const cmsg = @import("collo_os").cmsg;
const fd_mod = @import("collo_os").fd;
const messages = @import("messages.zig");

/// One received packet. `bytes` points into the caller's scratch, or into
/// `owned_buffer` when this packet allocated its own; `fds[0..fd_count]` are
/// owned here until `takeFd` moves one out, and `deinit` closes the rest.
pub const ReceivedPacket = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    owned_buffer: ?[]u8,
    fds: [messages.max_fds_per_message]fd_mod.OwnedFd,
    fd_count: usize,

    pub fn deinit(self: *ReceivedPacket) void {
        for (self.fds[0..self.fd_count]) |*entry|
            entry.deinit();
        if (self.owned_buffer) |buffer|
            self.allocator.free(buffer);
        self.* = undefined;
    }

    /// Moves descriptor `index`, which must be below `fd_count`, to the
    /// caller; `deinit` then skips its slot.
    pub fn takeFd(self: *ReceivedPacket, index: usize) fd_mod.OwnedFd {
        std.debug.assert(index < self.fd_count);
        const entry = self.fds[index];
        self.fds[index] = .{};
        return entry;
    }
};

/// `recvPacketWithFdsScratch` into a `messages.max_message_bytes` buffer
/// taken from `allocator`, which the packet owns and `deinit` frees.
pub fn recvPacketWithFdsAllocating(allocator: std.mem.Allocator, fd: std.posix.fd_t) !ReceivedPacket {
    const scratch = try allocator.alloc(u8, messages.max_message_bytes);
    errdefer allocator.free(scratch);
    var received = try recvPacketWithFdsScratch(allocator, fd, scratch);
    received.owned_buffer = scratch;
    return received;
}

/// Receives one packet into `scratch` with up to
/// `messages.max_fds_per_message` descriptors, without allocating:
/// `allocator` is only recorded for `deinit`. The packet borrows `scratch`,
/// so a caller reuses it only after the packet is decoded. Fails with
/// `error.DispatchScratchTooSmall` for an empty `scratch`, the errno errors
/// `recvmsgCompat` maps, `error.PeerClosed` when the receive returns no bytes
/// and no ancillary data, `error.EmptyPacketWithFds` when it returns no bytes
/// with ancillary data, `error.TruncatedMessage` when the packet is larger
/// than `scratch`, `error.TruncatedControlMessage` when its descriptors did
/// not all arrive, and the errors of `collectReceivedControlFds`; every
/// failure after the receive closes the descriptors it brought.
pub fn recvPacketWithFdsScratch(allocator: std.mem.Allocator, fd: std.posix.fd_t, scratch: []u8) !ReceivedPacket {
    if (scratch.len == 0)
        return error.DispatchScratchTooSmall;
    var control: [cmsg.space(@sizeOf(std.posix.fd_t) * messages.max_fds_per_message)]u8 align(@alignOf(cmsg.Cmsghdr)) =
        std.mem.zeroes([cmsg.space(@sizeOf(std.posix.fd_t) * messages.max_fds_per_message)]u8);
    var iov = [1]std.posix.iovec{
        .{
            .base = scratch.ptr,
            .len = scratch.len,
        },
    };
    var msg = std.posix.msghdr{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = iov.len,
        .control = &control,
        .controllen = control.len,
        .flags = 0,
    };
    const received = try recvmsgCompat(fd, &msg, std.posix.MSG.CMSG_CLOEXEC);
    if (received == 0) {
        // An end of stream also reads as zero bytes, but a zero-length
        // datagram still delivers the descriptors it carried: Linux checks
        // no length on a SOCK_SEQPACKET send and installs them on this
        // receive. Left open, a peer could fill the descriptor table by
        // repeating it.
        if (msg.controllen == 0 and (msg.flags & std.posix.MSG.CTRUNC) == 0)
            return error.PeerClosed;
        closeReceivedControlFds(&control, msg.controllen);
        return error.EmptyPacketWithFds;
    }
    if ((msg.flags & std.posix.MSG.TRUNC) != 0) {
        closeReceivedControlFds(&control, msg.controllen);
        return error.TruncatedMessage;
    }
    if ((msg.flags & std.posix.MSG.CTRUNC) != 0) {
        closeReceivedControlFds(&control, msg.controllen);
        return error.TruncatedControlMessage;
    }

    var result = ReceivedPacket{
        .allocator = allocator,
        .bytes = scratch[0..received],
        .owned_buffer = null,
        .fds = [_]fd_mod.OwnedFd{.{}} ** messages.max_fds_per_message,
        .fd_count = 0,
    };
    errdefer result.deinit();

    try collectReceivedControlFds(&control, msg.controllen, &result);

    return result;
}

/// Moves the SCM_RIGHTS descriptors of `control[0..controllen]` into
/// `result`. Any other ancillary message, a payload that is not whole
/// descriptors, a header that runs past `controllen`, or more than
/// `messages.max_fds_per_message` descriptors fails, and every descriptor in
/// the buffer is closed with `result.fd_count` reset, so a failure leaves no
/// descriptor open and none to close twice.
pub fn collectReceivedControlFds(
    control: []align(@alignOf(cmsg.Cmsghdr)) u8,
    controllen: usize,
    result: *ReceivedPacket,
) !void {
    var iterator = ControlMessageIterator.init(control, controllen);
    while (true) {
        const message = iterator.next() catch |err| {
            closeReceivedControlFds(control, controllen);
            result.fd_count = 0;
            return err;
        } orelse break;
        if (message.header.level != std.posix.SOL.SOCKET or message.header.type != cmsg.scm_rights) {
            closeReceivedControlFds(control, controllen);
            result.fd_count = 0;
            return error.UnexpectedAncillaryData;
        }

        const payload_len = message.payload.len;
        if (payload_len % @sizeOf(std.posix.fd_t) != 0) {
            closeReceivedControlFds(control, controllen);
            result.fd_count = 0;
            return error.InvalidControlMessage;
        }

        const fd_count = payload_len / @sizeOf(std.posix.fd_t);
        if (result.fd_count + fd_count > result.fds.len) {
            closeReceivedControlFds(control, controllen);
            result.fd_count = 0;
            return error.TooManyFds;
        }

        const fd_ptr: [*]const std.posix.fd_t = @ptrCast(@alignCast(message.payload.ptr));
        for (0..fd_count) |index|
            result.fds[result.fd_count + index] = fd_mod.OwnedFd.fromRaw(fd_ptr[index]);
        result.fd_count += fd_count;
    }
}

/// Closes every descriptor of every SCM_RIGHTS message in
/// `control[0..controllen]`. It trusts no header: a length is clamped to the
/// buffer, and the walk stops at the first header that cannot advance it.
pub fn closeReceivedControlFds(control: []align(@alignOf(cmsg.Cmsghdr)) u8, controllen: usize) void {
    const bounded_len = @min(controllen, control.len);
    var offset: usize = 0;
    while (offset + @sizeOf(cmsg.Cmsghdr) <= bounded_len) {
        const header: *const cmsg.Cmsghdr = @ptrCast(@alignCast(control[offset..].ptr));
        const available_len = @min(header.len, bounded_len - offset);
        if (header.level == std.posix.SOL.SOCKET and header.type == cmsg.scm_rights and available_len > cmsg.dataOffset()) {
            const payload_len = available_len - cmsg.dataOffset();
            const fd_count = payload_len / @sizeOf(std.posix.fd_t);
            const payload_start = offset + cmsg.dataOffset();
            const fd_ptr: [*]const std.posix.fd_t = @ptrCast(@alignCast(control[payload_start..].ptr));
            for (0..fd_count) |index|
                std.posix.close(fd_ptr[index]);
        }

        if (header.len < cmsg.dataOffset())
            return;
        const next_offset = offset + cmsg.alignLen(header.len);
        if (next_offset <= offset or next_offset > bounded_len)
            return;
        offset = next_offset;
    }
}

/// Sends `bytes` as one packet with `fds` as SCM_RIGHTS. The descriptors
/// stay the caller's, since the kernel duplicates them into the receiver.
/// Fails with `error.TooManyFds` above `messages.max_fds_per_message`,
/// `error.ShortWrite` when the kernel took less than the whole packet, and
/// the errno errors `sendmsgCompat` maps.
pub fn sendWithFds(fd: std.posix.fd_t, bytes: []const u8, fds: []const std.posix.fd_t) !void {
    if (fds.len == 0) {
        try sendExact(fd, bytes);
        return;
    }
    if (fds.len > messages.max_fds_per_message)
        return error.TooManyFds;

    var control: [cmsg.space(@sizeOf(std.posix.fd_t) * messages.max_fds_per_message)]u8 align(@alignOf(cmsg.Cmsghdr)) =
        std.mem.zeroes([cmsg.space(@sizeOf(std.posix.fd_t) * messages.max_fds_per_message)]u8);
    const header: *cmsg.Cmsghdr = @ptrCast(@alignCast(&control));
    header.* = .{
        .len = cmsg.len(@sizeOf(std.posix.fd_t) * fds.len),
        .level = std.posix.SOL.SOCKET,
        .type = cmsg.scm_rights,
    };
    const fd_ptr: [*]std.posix.fd_t = @ptrCast(@alignCast(control[cmsg.dataOffset()..].ptr));
    for (fds, 0..) |passed_fd, index|
        fd_ptr[index] = passed_fd;

    const iov = [1]std.posix.iovec_const{
        .{
            .base = bytes.ptr,
            .len = bytes.len,
        },
    };
    const msg = std.posix.msghdr_const{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = iov.len,
        .control = &control,
        .controllen = cmsg.space(@sizeOf(std.posix.fd_t) * fds.len),
        .flags = 0,
    };
    // SCM_RIGHTS messages are sent only over connected AF_UNIX SOCK_SEQPACKET
    // control sockets. The payload and fd rights are atomic there; retrying a
    // short sendmsg would risk duplicating or losing fd ownership.
    const written = try sendmsgCompat(fd, &msg, std.posix.MSG.NOSIGNAL);
    if (written != bytes.len)
        return error.ShortWrite;
}

/// Fills `bytes` from a byte stream with as many reads as it takes; fails
/// with `error.EndOfStream` when the stream ends first. Not for the
/// SEQPACKET sockets, where each read consumes a whole packet.
pub fn readExact(fd: std.posix.fd_t, bytes: []u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const received = try std.posix.read(fd, bytes[offset..]);
        if (received == 0)
            return error.EndOfStream;
        offset += received;
    }
}

/// Sends `bytes` as one packet without descriptors; fails with
/// `error.ShortWrite` when the kernel took less, and with the errno errors
/// `sendCompat` maps.
pub fn sendExact(fd: std.posix.fd_t, bytes: []const u8) !void {
    const written = try sendCompat(fd, bytes, std.posix.MSG.NOSIGNAL);
    if (written != bytes.len)
        return error.ShortWrite;
}

/// Receives one packet that must be exactly `bytes.len` long; a shorter one
/// fails with `error.ShortRead`, a longer one with `error.TruncatedMessage`.
pub fn recvPacketExact(fd: std.posix.fd_t, bytes: []u8) !void {
    const received = try recvPacket(fd, bytes);
    if (received != bytes.len)
        return error.ShortRead;
}

/// Receives one packet that must carry no descriptors and returns its
/// length. A packet larger than `bytes` fails with `error.TruncatedMessage`.
/// Descriptors a peer attached find no control buffer, so the kernel closes
/// them in this process and sets MSG_CTRUNC, which fails with
/// `error.UnexpectedAncillaryData`.
pub fn recvPacket(fd: std.posix.fd_t, bytes: []u8) !usize {
    var iov = [1]std.posix.iovec{
        .{
            .base = bytes.ptr,
            .len = bytes.len,
        },
    };
    var msg = std.posix.msghdr{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = iov.len,
        .control = null,
        .controllen = 0,
        .flags = 0,
    };
    const received = try recvmsgCompat(fd, &msg, 0);
    if ((msg.flags & std.posix.MSG.TRUNC) != 0)
        return error.TruncatedMessage;
    if ((msg.flags & std.posix.MSG.CTRUNC) != 0)
        return error.UnexpectedAncillaryData;
    return received;
}

/// Copies the bytes of `value.*` to the front of `dest`, which must hold
/// them, and returns how many it wrote.
pub fn writeStruct(dest: []u8, value: anytype) usize {
    const bytes = std.mem.asBytes(value);
    @memcpy(dest[0..bytes.len], bytes);
    return bytes.len;
}

/// Copies `value` to the front of `dest`, which must hold it, and returns
/// its length.
pub fn writeSlice(dest: []u8, value: []const u8) usize {
    @memcpy(dest[0..value.len], value);
    return value.len;
}

/// A `T` copied out of the first `@sizeOf(T)` bytes, which need no
/// alignment. The caller has checked that `bytes` is long enough.
pub fn readStruct(comptime T: type, bytes: []const u8) T {
    var value: T = undefined;
    @memcpy(std.mem.asBytes(&value), bytes[0..@sizeOf(T)]);
    return value;
}

/// The `len` bytes at `cursor.*`, borrowed from `packet`, and advances the
/// cursor past them. Fails with `error.ShortRead` when they run past the
/// packet and `error.InvalidPacket` when the end overflows.
pub fn readSlice(packet: []const u8, cursor: *usize, len: u32) ![]const u8 {
    const start = cursor.*;
    const end = std.math.add(usize, start, @as(usize, len)) catch return error.InvalidPacket;
    if (end > packet.len)
        return error.ShortRead;
    cursor.* = end;
    return packet[start..end];
}

const ControlMessage = struct {
    header: *const cmsg.Cmsghdr,
    payload: []align(@alignOf(std.posix.fd_t)) const u8,
};

/// Walks the ancillary messages of a receive. A header whose length is
/// shorter than its own header, runs past the received control length or
/// cannot advance the walk fails with `error.InvalidControlMessage`.
const ControlMessageIterator = struct {
    control: []align(@alignOf(cmsg.Cmsghdr)) u8,
    bounded_len: usize,
    offset: usize = 0,

    fn init(control: []align(@alignOf(cmsg.Cmsghdr)) u8, controllen: usize) ControlMessageIterator {
        return .{
            .control = control,
            .bounded_len = @min(controllen, control.len),
        };
    }

    fn next(self: *ControlMessageIterator) !?ControlMessage {
        if (self.offset + @sizeOf(cmsg.Cmsghdr) > self.bounded_len)
            return null;

        const header: *const cmsg.Cmsghdr = @ptrCast(@alignCast(self.control[self.offset..].ptr));
        if (header.len < cmsg.dataOffset() or header.len > self.bounded_len - self.offset)
            return error.InvalidControlMessage;

        const payload_start = self.offset + cmsg.dataOffset();
        const payload_end = self.offset + header.len;
        const payload: []align(@alignOf(std.posix.fd_t)) const u8 = @alignCast(self.control[payload_start..payload_end]);

        const next_offset = self.offset + cmsg.alignLen(header.len);
        if (next_offset <= self.offset)
            return error.InvalidControlMessage;
        self.offset = next_offset;

        return .{
            .header = header,
            .payload = payload,
        };
    }
};

fn sendCompat(fd: std.posix.fd_t, bytes: []const u8, flags: u32) !usize {
    while (true) {
        const rc = std.c.send(fd, bytes.ptr, bytes.len, flags);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .BADF, .NOTSOCK => return error.InvalidHandle,
            .CONNRESET, .CONNREFUSED, .PIPE, .NOTCONN, .TIMEDOUT => return error.PeerClosed,
            .MSGSIZE => return error.MessageTooBig,
            .NOBUFS, .NOMEM => return error.SystemResources,
            // The table covers the errno values Linux returns for a send on a
            // connected AF_UNIX socket. A syscall result never panics, so an
            // errno that reaches here is a hole in the table, logged by name
            // because the caller sees only `error.Unexpected`.
            else => |errno| {
                std.log.warn("ipc send: unmapped errno {s} fd={d}", .{ @tagName(errno), fd });
                return error.Unexpected;
            },
        }
    }
}

fn sendmsgCompat(fd: std.posix.fd_t, msg: *const std.posix.msghdr_const, flags: u32) !usize {
    while (true) {
        const rc = std.c.sendmsg(fd, msg, flags);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .ACCES => return error.AccessDenied,
            .AGAIN => return error.WouldBlock,
            .BADF, .NOTSOCK => return error.InvalidHandle,
            .CONNRESET, .CONNREFUSED, .PIPE, .NOTCONN, .TIMEDOUT => return error.PeerClosed,
            .MSGSIZE => return error.MessageTooBig,
            .NOBUFS, .NOMEM => return error.SystemResources,
            // An errno the table misses is logged by name, as in `sendCompat`.
            else => |errno| {
                std.log.warn("ipc sendmsg: unmapped errno {s} fd={d}", .{ @tagName(errno), fd });
                return error.Unexpected;
            },
        }
    }
}

fn recvmsgCompat(fd: std.posix.fd_t, msg: *std.posix.msghdr, flags: u32) !usize {
    while (true) {
        const rc = std.c.recvmsg(fd, msg, flags);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .BADF => return error.InvalidHandle,
            .CONNRESET, .CONNREFUSED, .PIPE, .NOTCONN, .TIMEDOUT => return error.PeerClosed,
            .NOBUFS, .NOMEM => return error.SystemResources,
            // A full descriptor table is resource pressure, never a protocol
            // violation. Per unix(7), descriptors beyond RLIMIT_NOFILE are
            // closed in the receiver without failing the call, so that
            // pressure usually surfaces as MSG_CTRUNC instead.
            .MFILE, .NFILE => return error.SystemResources,
            .NOTSOCK => return error.InvalidHandle,
            // An errno the table misses is logged by name, as in `sendCompat`.
            else => |errno| {
                std.log.warn("ipc recvmsg: unmapped errno {s} fd={d}", .{ @tagName(errno), fd });
                return error.Unexpected;
            },
        }
    }
}

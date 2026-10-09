//! The TCP peer of an accepted ingress connection. The lane's multishot
//! accept records no address, so connection setup reads it once with
//! getpeername and keeps it on the connection slot, where the access log
//! formats it as the request's client IP. It lives on the lane thread with
//! the slot that holds it. Only the TCP peer counts: no forwarded header is
//! trusted, so a reverse proxy in front of the server is what this records.

const std = @import("std");
const linux = std.os.linux;
const collo_linux = @import("collo_os").linux;

/// Fixed size, so every connection slot carries it inline. A dual-stack
/// listener reports IPv4 clients as IPv4-mapped IPv6 addresses; those are
/// stored as IPv4.
pub const PeerAddress = struct {
    family: Family = .unknown,
    /// IPv4 fills the first four bytes, in network order.
    bytes: [16]u8 = @splat(0),

    pub const Family = enum(u8) { unknown, ipv4, ipv6 };

    /// Longest text `text` returns: an IPv6 address with no zero run to
    /// compress.
    pub const text_bytes_max: usize = 39;

    /// Scratch for `text`. The standard IPv6 formatter writes
    /// `[address]:port`, and `text` returns the address inside the brackets.
    pub const TextBuffer = [text_bytes_max + "[]:0".len]u8;

    const ipv4_mapped_prefix = [12]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff };

    /// Reads the peer of an accepted socket. A peer that reset the connection
    /// before this call reads as `.unknown`; the TLS handshake then sees the
    /// reset and closes the slot.
    pub fn fromSocket(fd: std.posix.fd_t) !PeerAddress {
        var storage: linux.sockaddr.storage = undefined;
        var len: linux.socklen_t = @sizeOf(linux.sockaddr.storage);
        const rc = linux.getpeername(fd, @ptrCast(&storage), &len);
        return switch (collo_linux.syscallErrno(rc)) {
            .SUCCESS => fromSockaddr(&storage, len),
            .NOTCONN => .{},
            .NOBUFS => error.SystemResources,
            else => |errno| std.posix.unexpectedErrno(errno),
        };
    }

    /// `len` is the length the kernel wrote. Any family other than IPv4 and
    /// IPv6, or an address shorter than its family's, reads as `.unknown`.
    pub fn fromSockaddr(storage: *const linux.sockaddr.storage, len: linux.socklen_t) PeerAddress {
        switch (storage.family) {
            linux.AF.INET => {
                if (len < @sizeOf(linux.sockaddr.in))
                    return .{};
                const in: *const linux.sockaddr.in = @ptrCast(storage);
                var peer = PeerAddress{ .family = .ipv4 };
                @memcpy(peer.bytes[0..4], std.mem.asBytes(&in.addr));
                return peer;
            },
            linux.AF.INET6 => {
                if (len < @sizeOf(linux.sockaddr.in6))
                    return .{};
                const in6: *const linux.sockaddr.in6 = @ptrCast(storage);
                if (std.mem.eql(u8, in6.addr[0..12], &ipv4_mapped_prefix)) {
                    var peer = PeerAddress{ .family = .ipv4 };
                    @memcpy(peer.bytes[0..4], in6.addr[12..16]);
                    return peer;
                }
                return .{ .family = .ipv6, .bytes = in6.addr };
            },
            else => return .{},
        }
    }

    /// The address as text, borrowed from `buffer`: a dotted quad for IPv4,
    /// the RFC 5952 form for IPv6, and empty when the peer is unknown.
    pub fn text(self: *const PeerAddress, buffer: *TextBuffer) []const u8 {
        switch (self.family) {
            .unknown => return "",
            .ipv4 => return std.fmt.bufPrint(buffer, "{d}.{d}.{d}.{d}", .{
                self.bytes[0],
                self.bytes[1],
                self.bytes[2],
                self.bytes[3],
            }) catch unreachable,
            .ipv6 => {
                const address = std.net.Ip6Address.init(self.bytes, 0, 0, 0);
                const wrapped = std.fmt.bufPrint(buffer, "{f}", .{address}) catch unreachable;
                const close = std.mem.lastIndexOfScalar(u8, wrapped, ']') orelse unreachable;
                return wrapped[1..close];
            },
        }
    }
};

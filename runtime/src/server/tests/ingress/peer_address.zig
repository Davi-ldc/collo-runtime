//! Decoding and formatting of an ingress connection's TCP peer
//! (`ingress/peer_address.zig`): from hand-built socket addresses, from a
//! loopback connection accepted without an address buffer as the lane's
//! multishot accept does, and from sockets that have no IP peer. Lane
//! `server-ingress-test`; `local-e2e` checks that a served request's access
//! record carries the peer the lane accepted.

const std = @import("std");
const linux = std.os.linux;
const server_main = @import("collo_server_main");

const PeerAddress = server_main.ingress.peer_address.PeerAddress;

fn ipv4Storage(octets: [4]u8) linux.sockaddr.storage {
    var storage = std.mem.zeroes(linux.sockaddr.storage);
    const in: *linux.sockaddr.in = @ptrCast(&storage);
    in.* = .{ .port = std.mem.nativeToBig(u16, 443), .addr = @bitCast(octets) };
    return storage;
}

fn ipv6Storage(bytes: [16]u8) linux.sockaddr.storage {
    var storage = std.mem.zeroes(linux.sockaddr.storage);
    const in6: *linux.sockaddr.in6 = @ptrCast(&storage);
    in6.* = .{ .port = std.mem.nativeToBig(u16, 443), .flowinfo = 0, .addr = bytes, .scope_id = 0 };
    return storage;
}

fn expectText(expected: []const u8, peer: PeerAddress) !void {
    var buffer: PeerAddress.TextBuffer = undefined;
    try std.testing.expectEqualStrings(expected, peer.text(&buffer));
}

test "an IPv4 peer formats as a dotted quad without its port" {
    const storage = ipv4Storage(.{ 203, 0, 113, 7 });
    const peer = PeerAddress.fromSockaddr(&storage, @sizeOf(linux.sockaddr.in));
    try std.testing.expectEqual(PeerAddress.Family.ipv4, peer.family);
    try expectText("203.0.113.7", peer);
}

test "an IPv4-mapped IPv6 peer is stored and formatted as IPv4" {
    const storage = ipv6Storage(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 198, 51, 100, 9 });
    const peer = PeerAddress.fromSockaddr(&storage, @sizeOf(linux.sockaddr.in6));
    try std.testing.expectEqual(PeerAddress.Family.ipv4, peer.family);
    try expectText("198.51.100.9", peer);
}

test "an IPv6 peer formats in compressed form without brackets or port" {
    const storage = ipv6Storage(.{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 });
    const peer = PeerAddress.fromSockaddr(&storage, @sizeOf(linux.sockaddr.in6));
    try std.testing.expectEqual(PeerAddress.Family.ipv6, peer.family);
    try expectText("2001:db8::1", peer);
}

test "the longest IPv6 text fits the declared bound" {
    const storage = ipv6Storage(@splat(0xff));
    const peer = PeerAddress.fromSockaddr(&storage, @sizeOf(linux.sockaddr.in6));
    var buffer: PeerAddress.TextBuffer = undefined;
    const text = peer.text(&buffer);
    try std.testing.expectEqualStrings("ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", text);
    try std.testing.expectEqual(PeerAddress.text_bytes_max, text.len);
}

test "a truncated address or a non-IP family reads as unknown with empty text" {
    const truncated = ipv6Storage(@splat(0xff));
    const short = PeerAddress.fromSockaddr(&truncated, @sizeOf(linux.sockaddr.in));
    try std.testing.expectEqual(PeerAddress.Family.unknown, short.family);
    try expectText("", short);

    var unix_storage = std.mem.zeroes(linux.sockaddr.storage);
    unix_storage.family = linux.AF.UNIX;
    const unix_peer = PeerAddress.fromSockaddr(&unix_storage, @sizeOf(linux.sockaddr.un));
    try std.testing.expectEqual(PeerAddress.Family.unknown, unix_peer.family);
    try expectText("", unix_peer);
}

test "a loopback connection accepted without an address buffer reads its peer as 127.0.0.1" {
    const flags = std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC;
    const listener = try std.posix.socket(std.posix.AF.INET, flags, 0);
    defer std.posix.close(listener);
    var address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    var address_len = address.getOsSockLen();
    try std.posix.bind(listener, &address.any, address_len);
    try std.posix.listen(listener, 1);
    try std.posix.getsockname(listener, &address.any, &address_len);

    const client = try std.posix.socket(std.posix.AF.INET, flags, 0);
    defer std.posix.close(client);
    try std.posix.connect(client, &address.any, address_len);
    const accepted = try std.posix.accept(listener, null, null, std.posix.SOCK.CLOEXEC);
    defer std.posix.close(accepted);

    const peer = try PeerAddress.fromSocket(accepted);
    try std.testing.expectEqual(PeerAddress.Family.ipv4, peer.family);
    try expectText("127.0.0.1", peer);
}

test "a socket without an IP peer reads as unknown" {
    var pair: [2]std.posix.fd_t = undefined;
    const rc = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &pair);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.E.init(rc));
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);
    const unix_peer = try PeerAddress.fromSocket(pair[0]);
    try std.testing.expectEqual(PeerAddress.Family.unknown, unix_peer.family);

    // A TCP socket that never connected has no peer: getpeername answers
    // ENOTCONN, the same answer as a peer that reset before setup.
    const unconnected = try std.posix.socket(
        std.posix.AF.INET,
        std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
        0,
    );
    defer std.posix.close(unconnected);
    const tcp_peer = try PeerAddress.fromSocket(unconnected);
    try std.testing.expectEqual(PeerAddress.Family.unknown, tcp_peer.family);
}

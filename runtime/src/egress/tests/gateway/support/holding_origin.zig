//! A one-connection HTTP/1.1 origin for the gateway suites that answers its one request with a
//! response head announcing a long body, sends the first bytes of that body and then holds the
//! connection open, sending nothing more, until the client closes it. It reports the close on an
//! eventfd a test polls, so a test sees the moment the gateway's engine dropped the fetch. It
//! serves on this host's routable address (`collo_test_net`), since every network grant refuses
//! loopback, and a host without one skips the test. Its one thread waits in `poll` on its socket
//! and a stop eventfd, so `stop` ends it whatever the client did. Holds no tests.

const std = @import("std");
const network = @import("collo_egress_client").network;
const test_net = @import("collo_test_net");

/// The body the head announces, far more than the origin ever sends.
pub const announced_body_bytes: usize = 1024 * 1024;
/// The body bytes the origin sends before it holds the connection.
pub const sent_body_bytes: usize = 1024;
/// The longest URL `url` writes.
pub const url_bytes_max: usize = 64;

pub const HoldingOrigin = struct {
    server: std.net.Server,
    host_buffer: [64]u8,
    host_len: usize,
    port: u16,
    /// Written once the client closed its connection.
    closed_fd: std.posix.fd_t,
    /// Written by `stop`.
    stop_fd: std.posix.fd_t,
    thread: std.Thread,

    /// Listens on every address and serves one connection from a thread. Fails with
    /// `error.SkipZigTest` on a host without a routable IPv4 address.
    pub fn start(allocator: std.mem.Allocator) !*HoldingOrigin {
        var host_buffer: [64]u8 = undefined;
        const host = try test_net.routableLocalIpv4(&host_buffer);
        const address = try std.net.Address.parseIp4("0.0.0.0", 0);
        var server = try address.listen(.{ .reuse_address = true });
        errdefer server.deinit();
        const closed_fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
        errdefer std.posix.close(closed_fd);
        const stop_fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
        errdefer std.posix.close(stop_fd);
        const origin = try allocator.create(HoldingOrigin);
        errdefer allocator.destroy(origin);
        origin.* = .{
            .server = server,
            .host_buffer = host_buffer,
            .host_len = host.len,
            .port = server.listen_address.getPort(),
            .closed_fd = closed_fd,
            .stop_fd = stop_fd,
            .thread = undefined,
        };
        origin.thread = try std.Thread.spawn(.{}, serve, .{origin});
        return origin;
    }

    /// Ends the thread, whether or not a client came or closed, and frees the origin.
    pub fn stop(self: *HoldingOrigin, allocator: std.mem.Allocator) void {
        signal(self.stop_fd);
        self.thread.join();
        self.server.deinit();
        std.posix.close(self.closed_fd);
        std.posix.close(self.stop_fd);
        allocator.destroy(self);
    }

    /// The origin's address as a policy entry names it.
    pub fn ipv4(self: *const HoldingOrigin) ![4]u8 {
        const address = try std.net.Address.parseIp4(self.host_buffer[0..self.host_len], 0);
        return network.address.ipv4Bytes(address);
    }

    /// `http://` the origin's address and port, then `/hold`.
    pub fn url(self: *const HoldingOrigin, buffer: *[url_bytes_max]u8) []const u8 {
        return std.fmt.bufPrint(buffer, "http://{s}:{d}/hold", .{
            self.host_buffer[0..self.host_len],
            self.port,
        }) catch unreachable;
    }

    /// Waits up to `timeout_ms` for the client to close its connection and returns whether it
    /// did.
    pub fn waitClientClosed(self: *const HoldingOrigin, timeout_ms: i32) !bool {
        var pollfds = [_]std.posix.pollfd{.{ .fd = self.closed_fd, .events = std.posix.POLL.IN, .revents = 0 }};
        return try std.posix.poll(&pollfds, timeout_ms) == 1;
    }

    fn serve(self: *HoldingOrigin) void {
        if (!self.waitReadable(self.server.stream.handle))
            return;
        const connection = self.server.accept() catch return;
        defer connection.stream.close();
        self.answer(connection.stream) catch return;
        // Hold: read whatever the client sends until it closes, or until `stop`.
        var scratch: [1024]u8 = undefined;
        while (self.waitReadable(connection.stream.handle)) {
            const read = connection.stream.read(&scratch) catch 0;
            if (read == 0) {
                signal(self.closed_fd);
                return;
            }
        }
    }

    /// Reads the request head and writes the response head and the first body bytes.
    fn answer(self: *HoldingOrigin, stream: std.net.Stream) !void {
        var request: [2048]u8 = undefined;
        var received: usize = 0;
        while (std.mem.indexOf(u8, request[0..received], "\r\n\r\n") == null) {
            if (received == request.len or !self.waitReadable(stream.handle))
                return error.TestRequestHeadMissing;
            const read = try stream.read(request[received..]);
            if (read == 0)
                return error.TestRequestHeadMissing;
            received += read;
        }
        var head: [128]u8 = undefined;
        try stream.writeAll(try std.fmt.bufPrint(
            &head,
            "HTTP/1.1 200 OK\r\ncontent-length: {d}\r\n\r\n",
            .{announced_body_bytes},
        ));
        const body: [sent_body_bytes]u8 = @splat('h');
        try stream.writeAll(&body);
    }

    /// Waits until `fd` is readable (true) or `stop` was called (false).
    fn waitReadable(self: *HoldingOrigin, fd: std.posix.fd_t) bool {
        var pollfds = [_]std.posix.pollfd{
            .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = self.stop_fd, .events = std.posix.POLL.IN, .revents = 0 },
        };
        // The thread ends with the test, so it waits without a bound; `stop` ends the wait.
        while (true) {
            _ = std.posix.poll(&pollfds, -1) catch return false;
            if (pollfds[1].revents != 0)
                return false;
            if (pollfds[0].revents != 0)
                return true;
        }
    }
};

fn signal(fd: std.posix.fd_t) void {
    const one: u64 = 1;
    _ = std.posix.write(fd, std.mem.asBytes(&one)) catch |err|
        std.debug.panic("holding origin eventfd write failed: {s}", .{@errorName(err)});
}

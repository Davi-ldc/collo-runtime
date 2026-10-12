//! The plain HTTP/1.1 origin the local-e2e suites fetch from through the
//! egress gateway, and the routable address it is reached at. It runs one
//! thread of the test process and serves one request per connection.
//!
//! Handlers reach it through this host's routable IPv4 address, never
//! loopback, because the gateway refuses loopback under every `network`
//! setting. That address is private on every development and CI host the lane
//! runs on, so a grant that names the origin also sets `allowPrivateNetworks`
//! (`network.zig`). It cannot be a TLS origin: the test server certificate
//! names no address the gateway could verify it against.

const std = @import("std");

/// An origin that answers every request with a precomputed gzip body and
/// `content-encoding: gzip`, except three paths: `hold_path`, which it reads
/// and then holds open without an answer until it stops, so a fetch of that
/// path stays in flight; `barrier_path`, which it answers only once the test
/// calls `releaseBarrier` or the origin stops, serving nothing else
/// meanwhile; and `redirect_path`, which it answers with a 302 to another
/// origin's `/gzip`.
pub const GzipOrigin = struct {
    server: std.net.Server,
    host_buffer: [64]u8,
    host_len: usize,
    port: u16,
    thread: std.Thread,
    /// Connections the origin accepted before `stop`, whatever they carried.
    /// Each counts before the origin answers or holds it, so a fetch that got
    /// its answer is already counted. A test that expects a fetch to be
    /// denied before it connects expects 0.
    accepted: std.atomic.Value(usize),
    /// How many requests for `hold_path` the origin holds; their streams are
    /// the first `held` entries of `held_streams`. Only the origin's thread
    /// writes either, and `stop` closes the streams after joining it.
    held: std.atomic.Value(usize),
    held_streams: [held_streams_max]std.net.Stream,
    stopping: std.atomic.Value(bool),
    /// Set by `releaseBarrier` or `stop`.
    barrier_released: std.Thread.ResetEvent,

    pub const hold_path = "/hold";
    pub const barrier_path = "/barrier";
    /// `/redirect?to=<host:port>` answers 302 with
    /// `location: http://<host:port>/gzip`.
    pub const redirect_path = "/redirect";
    /// Requests the origin holds at once; a request past them is closed
    /// unanswered.
    const held_streams_max: usize = 4;
    /// Polls `waitForHeld` makes, `held_poll_interval_ns` apart.
    const held_polls_max: usize = 500;
    const held_poll_interval_ns: u64 = 10 * std.time.ns_per_ms;
    /// Bytes of a request head the origin reads.
    const request_head_bytes_max: usize = 2048;
    /// Bytes of a `to` target a redirect accepts, enough for an IPv6
    /// literal in brackets and a port.
    const redirect_target_bytes_max: usize = 64;

    /// What `gzip_hello_world` decodes to.
    pub const decoded_body = "hello world";
    /// gzip("hello world").
    const gzip_hello_world = [_]u8{
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x03, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57,
        0x28, 0xcf, 0x2f, 0xca, 0x49, 0x01, 0x00, 0x85,
        0x11, 0x4a, 0x0d, 0x0b, 0x00, 0x00, 0x00,
    };
    const response_head = std.fmt.comptimePrint(
        "HTTP/1.1 200 OK\r\n" ++
            "content-type: text/plain\r\n" ++
            "content-encoding: gzip\r\n" ++
            "content-length: {d}\r\n" ++
            "connection: close\r\n\r\n",
        .{gzip_hello_world.len},
    );
    const bad_request = "HTTP/1.1 400 Bad Request\r\ncontent-length: 0\r\nconnection: close\r\n\r\n";

    /// Starts an origin on an ephemeral port of every IPv4 address. Skips the
    /// test when the host has no routable IPv4 address (`routableLocalIpv4`).
    /// The caller ends it with `stop`.
    pub fn start(allocator: std.mem.Allocator) !*GzipOrigin {
        var host_buffer: [64]u8 = undefined;
        const host_value = try routableLocalIpv4(&host_buffer);
        const address = try std.net.Address.parseIp4("0.0.0.0", 0);
        var server = try address.listen(.{ .reuse_address = true });
        errdefer server.deinit();
        const origin = try allocator.create(GzipOrigin);
        errdefer allocator.destroy(origin);
        origin.* = .{
            .server = server,
            .host_buffer = host_buffer,
            .host_len = host_value.len,
            .port = server.listen_address.getPort(),
            .thread = undefined,
            .accepted = std.atomic.Value(usize).init(0),
            .held = std.atomic.Value(usize).init(0),
            .held_streams = undefined,
            .stopping = std.atomic.Value(bool).init(false),
            .barrier_released = .{},
        };
        origin.thread = try std.Thread.spawn(.{}, GzipOrigin.serve, .{origin});
        return origin;
    }

    /// The routable IPv4 address handlers reach the origin at.
    pub fn host(self: *const GzipOrigin) []const u8 {
        return self.host_buffer[0..self.host_len];
    }

    /// `<host>:<port>`, written into `buffer`, as a grant or a URL names it.
    pub fn authority(self: *const GzipOrigin, buffer: []u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "{s}:{d}", .{ self.host(), self.port });
    }

    pub fn stop(self: *GzipOrigin, allocator: std.mem.Allocator) void {
        self.stopping.store(true, .release);
        self.barrier_released.set();
        const address = std.net.Address.parseIp4("127.0.0.1", self.port) catch null;
        if (address) |addr| {
            if (std.net.tcpConnectToAddress(addr)) |stream| {
                stream.close();
            } else |_| {}
        }
        self.thread.join();
        for (self.held_streams[0..self.held.load(.acquire)]) |stream|
            stream.close();
        self.server.deinit();
        allocator.destroy(self);
    }

    /// Waits until the origin holds `minimum` requests for `hold_path`, at
    /// most `held_polls_max` polls.
    pub fn waitForHeld(self: *const GzipOrigin, minimum: usize) !void {
        for (0..held_polls_max) |_| {
            if (self.held.load(.acquire) >= minimum)
                return;
            std.Thread.sleep(held_poll_interval_ns);
        }
        return error.OriginHeldRequestNotObserved;
    }

    /// Lets the origin answer the request it holds at `barrier_path`, and
    /// every later one at once.
    pub fn releaseBarrier(self: *GzipOrigin) void {
        self.barrier_released.set();
    }

    fn serve(self: *GzipOrigin) void {
        while (!self.stopping.load(.acquire)) {
            const connection = self.server.accept() catch return;
            if (self.stopping.load(.acquire)) {
                connection.stream.close();
                return;
            }
            var buffer: [request_head_bytes_max]u8 = undefined;
            const head = readRequestHead(connection.stream, &buffer);
            _ = self.accepted.fetchAdd(1, .acq_rel);
            if (std.mem.startsWith(u8, head, "GET " ++ hold_path ++ " ")) {
                self.hold(connection.stream);
            } else if (std.mem.startsWith(u8, head, "GET " ++ barrier_path ++ " ")) {
                self.barrier_released.wait();
                answer(connection.stream);
                connection.stream.close();
            } else if (std.mem.startsWith(u8, head, "GET " ++ redirect_path ++ "?to=")) {
                redirect(connection.stream, head["GET ".len + redirect_path.len + "?to=".len ..]);
                connection.stream.close();
            } else {
                answer(connection.stream);
                connection.stream.close();
            }
        }
    }

    /// Keeps `stream` open without an answer until `stop`, or closes it at
    /// once when the origin already holds `held_streams_max` requests.
    fn hold(self: *GzipOrigin, stream: std.net.Stream) void {
        const count = self.held.load(.monotonic);
        if (count < held_streams_max) {
            self.held_streams[count] = stream;
            self.held.store(count + 1, .release);
        } else {
            stream.close();
        }
    }

    /// Writes the gzip response; a peer that left first loses only its
    /// answer.
    fn answer(stream: std.net.Stream) void {
        stream.writeAll(response_head) catch return;
        stream.writeAll(&gzip_hello_world) catch return;
    }

    /// Answers 302 to the `/gzip` of the target that starts `rest`, the
    /// request line after `?to=`. A target with a byte outside an authority's
    /// alphabet gets a 400, so nothing the request carries reaches a header
    /// line but an address and a port.
    fn redirect(stream: std.net.Stream, rest: []const u8) void {
        const target_end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        const target = rest[0..target_end];
        if (target.len == 0 or target.len > redirect_target_bytes_max or !isAuthority(target)) {
            stream.writeAll(bad_request) catch return;
            return;
        }
        var head_buffer: [256]u8 = undefined;
        const head = std.fmt.bufPrint(
            &head_buffer,
            "HTTP/1.1 302 Found\r\nlocation: http://{s}/gzip\r\ncontent-length: 0\r\nconnection: close\r\n\r\n",
            .{target},
        ) catch return;
        stream.writeAll(head) catch return;
    }

    fn isAuthority(text: []const u8) bool {
        for (text) |byte| {
            const allowed = std.ascii.isAlphanumeric(byte) or byte == '.' or byte == ':' or
                byte == '-' or byte == '[' or byte == ']';
            if (!allowed) return false;
        }
        return true;
    }

    /// Reads `stream` until the end of a request head, a full `buffer`, the
    /// peer's close or a read error, and returns what it read.
    fn readRequestHead(stream: std.net.Stream, buffer: []u8) []const u8 {
        var total: usize = 0;
        while (std.mem.indexOf(u8, buffer[0..total], "\r\n\r\n") == null) {
            if (total == buffer.len)
                break;
            const read_len = stream.read(buffer[total..]) catch break;
            if (read_len == 0)
                break;
            total += read_len;
        }
        return buffer[0..total];
    }
};

/// `route?host=<origin host>&port=<origin port>`, for the fixture handlers
/// that fetch from the origin (`api/fetch_gzip.js`).
pub fn gzipRoutePath(allocator: std.mem.Allocator, route: []const u8, origin: *const GzipOrigin) ![:0]u8 {
    return std.fmt.allocPrintSentinel(allocator, "{s}?host={s}&port={d}", .{ route, origin.host(), origin.port }, 0);
}

/// The source address the kernel would route external traffic from, written
/// into `out`, as the shared test-network fixture finds it
/// (`runtime/tests/support/net/local_address.zig`). Skips the test when the
/// host has no such IPv4 address, or one no grant can reach.
pub const routableLocalIpv4 = @import("collo_test_harness").test_net.routableLocalIpv4;

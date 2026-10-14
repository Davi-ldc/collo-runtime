//! Shared fixtures for the HTTP/2 pool tests: the local TLS origins of the
//! test shim, declared in `runtime/tests/support/tls/shim.zig` and re-exported
//! here, a routable local IPv4 address, the data driver with its skip rule, a
//! TLS wire dialed and handshaken through that driver the way the engine's
//! dials do it, and a write transport that accepts bounded chunks.

const std = @import("std");
const local_address = @import("collo_test_net");
const tls_shim = @import("collo_test_tls_shim");
const egress_client = @import("collo_egress_client");
pub const pool = egress_client.pool;
pub const data_io = egress_client.data_io;
pub const transport = egress_client.transport;
pub const http2 = egress_client.http2;

pub const TestH2Origin = tls_shim.TestH2Origin;
pub const collo_test_h2_origin_start = tls_shim.collo_test_h2_origin_start;
pub const collo_bench_h2_origin_start = tls_shim.collo_bench_h2_origin_start;
pub const collo_test_h2_origin_stop = tls_shim.collo_test_h2_origin_stop;
pub const collo_test_h2_origin_last_error = tls_shim.collo_test_h2_origin_last_error;
pub const collo_test_h2_origin_stream_count = tls_shim.collo_test_h2_origin_stream_count;
pub const collo_test_h2_origin_selected_alpn = tls_shim.collo_test_h2_origin_selected_alpn;

pub const TestTlsResumptionOrigin = tls_shim.TestTlsResumptionOrigin;
pub const collo_test_tls_resumption_origin_start = tls_shim.collo_test_tls_resumption_origin_start;
pub const collo_test_tls_resumption_origin_join = tls_shim.collo_test_tls_resumption_origin_join;
pub const collo_test_tls_resumption_origin_stop = tls_shim.collo_test_tls_resumption_origin_stop;
pub const collo_test_tls_resumption_origin_resumed_count = tls_shim.collo_test_tls_resumption_origin_resumed_count;
pub const collo_test_tls_resumption_origin_handshakes = tls_shim.collo_test_tls_resumption_origin_handshakes;
pub const collo_test_tls_resumption_origin_last_error = tls_shim.collo_test_tls_resumption_origin_last_error;

pub const test_h2_origin_alpn_h2 = tls_shim.test_h2_origin_alpn_h2;
pub const test_h2_origin_alpn_http11 = tls_shim.test_h2_origin_alpn_http11;
pub const test_alpn_h2 = tls_shim.test_alpn_h2;

/// The buffer cap of every wire these tests dial.
pub const wire_buffer_bytes: usize = 256 * 1024;

pub fn routableLocalIpv4(out: *[64]u8) ![]const u8 {
    return local_address.routableLocalIpv4(out);
}

/// The io_uring data driver, or a skip when this kernel or its policy offers
/// no restricted ring; any other failure fails the test.
pub fn initDataDriver() !data_io.Driver {
    return data_io.Driver.init(std.testing.allocator) catch |err| switch (err) {
        error.UnsupportedKernel, error.PermissionDenied => return error.SkipZigTest,
        else => |other| return other,
    };
}

pub const DialOptions = struct {
    server_name: []const u8,
    session_key: ?[]const u8 = null,
    offer_h2: bool = true,
};

/// Connects to `address`, creates a TLS wire over the socket and steps its
/// handshake on `driver`'s completions until it is done. The wire stays
/// registered in the driver; release it with `releaseWire`.
pub fn dialTlsWire(driver: *data_io.Driver, address: std.net.Address, options: DialOptions) !*transport.Wire {
    const stream = try std.net.tcpConnectToAddress(address);
    setNonblocking(stream.handle) catch |err| {
        stream.close();
        return err;
    };
    const wire = try transport.Wire.createTls(std.testing.allocator, stream, .{
        .server_name = options.server_name,
        .insecure_tls = true,
        .session_key = options.session_key,
        .offer_h2 = options.offer_h2,
    }, wire_buffer_bytes);
    errdefer releaseWire(driver, wire);
    var steps: usize = 0;
    while (steps < 256) : (steps += 1) {
        switch (try wire.handshakeStep()) {
            .done => return wire,
            .wait => |interest| try waitWire(driver, wire, interest),
        }
    }
    return error.TlsHandshakeStalled;
}

/// One data-driver wait on `wire` for `interest`, failing on the wire's error
/// or after 5 s.
pub fn waitWire(driver: *data_io.Driver, wire: *transport.Wire, interest: transport.IoInterest) !void {
    var context: u8 = 0;
    const result = try driver.wait(&.{.{
        .context = &context,
        .io = .{ .wire = wire },
        .deadline_mono_ns = try transport.config.deadlineAfterMs(5_000),
        .want_read = interest == .read,
        .want_write = interest == .write,
    }}, null);
    switch (result) {
        .ready, .wake, .tick => {},
        .failed => |failure| return failure.err,
        .expired => return error.WireWaitTimeout,
    }
}

/// Releases a wire the driver has seen: freed here once the driver confirms
/// its cancel, or freed by the driver after its terminal completions.
pub fn releaseWire(driver: *data_io.Driver, wire: *transport.Wire) void {
    if (driver.cancelConnectionForClose(wire))
        wire.deinit();
}

fn setNonblocking(fd: std.posix.fd_t) !void {
    const flags = try std.posix.fcntl(fd, std.posix.F.GETFL, 0);
    const nonblock_flag: usize = 1 << @bitOffsetOf(std.posix.O, "NONBLOCK");
    _ = try std.posix.fcntl(fd, std.posix.F.SETFL, flags | nonblock_flag);
}

pub const FakeWriteTransport = struct {
    max_chunk: usize,
    wait_after_bytes: ?usize = null,
    wait_interest: transport.IoInterest = .write,
    written: usize = 0,

    pub fn writeStep(self: *FakeWriteTransport, bytes: []const u8) !transport.IoStep {
        if (self.wait_after_bytes) |limit| {
            if (self.written >= limit)
                return .{ .wait = self.wait_interest };
            const remaining_before_wait = limit - self.written;
            const amount = @min(bytes.len, @min(self.max_chunk, remaining_before_wait));
            self.written += amount;
            return .{ .ready = amount };
        }

        const amount = @min(bytes.len, self.max_chunk);
        self.written += amount;
        return .{ .ready = amount };
    }
};

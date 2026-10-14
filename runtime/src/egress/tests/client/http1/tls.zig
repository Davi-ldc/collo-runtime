//! HTTP/1 exchanges over TLS wires against the test shim's TLS origin
//! (`collo_test_tls_http1_origin_start`, runtime/tests/support/tls/): a
//! pooled HTTPS wire whose peer closes without a close_notify, or resets,
//! under a GET reads as the end of the stream, and the GET replays on a new
//! connection. The harness in support.zig dials and handshakes the wires on
//! the production data driver. Plain-HTTP exchanges are tested in
//! streaming.zig, and the TLS wire's end of stream alone in ../wire.zig.

const std = @import("std");
const local_address = @import("collo_test_net");
const tls_shim = @import("collo_test_tls_shim");
const network_policy = @import("../network_policy.zig");
const test_support = @import("support.zig");

const transport = test_support.transport;
const Client = test_support.Client;
const Response = test_support.Response;
const fetchViaExchange = test_support.fetchViaExchange;

const gpa = std.testing.allocator;

/// The test shim's TLS HTTP/1 origin, reached on this host's routable
/// address, where it listens with every other one. Its policy admits that
/// address on the origin's port alone.
const LocalTlsHttp1Origin = struct {
    handle: *tls_shim.TestTlsHttp1Origin,
    port: u16,
    host_buffer: [64]u8,
    host_len: usize,
    /// Backs `policy`, which points into it; the heap keeps it in place.
    origins: network_policy.Origins,

    /// `mode` is how the origin ends a connection at its second request
    /// (`tls_shim.test_tls_http1_origin_close_second` or `_reset_second`).
    fn start(allocator: std.mem.Allocator, mode: c_int) !*LocalTlsHttp1Origin {
        const origin = try allocator.create(LocalTlsHttp1Origin);
        errdefer allocator.destroy(origin);
        origin.host_len = (try local_address.routableLocalIpv4(&origin.host_buffer)).len;
        var handle: ?*tls_shim.TestTlsHttp1Origin = null;
        if (tls_shim.collo_test_tls_http1_origin_start(mode, &handle, &origin.port) != 0)
            return error.TestTlsOriginStartFailed;
        origin.handle = handle orelse return error.TestTlsOriginStartFailed;
        errdefer tls_shim.collo_test_tls_http1_origin_stop(origin.handle);
        origin.origins = .{};
        try origin.origins.init(origin.host(), &.{origin.port});
        return origin;
    }

    /// Joins the origin's thread, which first finishes the connection it
    /// serves, so every client wire to it must be closed first.
    fn stop(self: *LocalTlsHttp1Origin, allocator: std.mem.Allocator) void {
        tls_shim.collo_test_tls_http1_origin_stop(self.handle);
        allocator.destroy(self);
    }

    fn host(self: *const LocalTlsHttp1Origin) []const u8 {
        return self.host_buffer[0..self.host_len];
    }

    /// `https://<host>:<port><path>`, which the caller frees.
    fn url(self: *const LocalTlsHttp1Origin, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "https://{s}:{d}{s}", .{ self.host(), self.port, path });
    }

    fn policy(self: *const LocalTlsHttp1Origin) transport.network.Policy {
        return self.origins.policy();
    }

    fn accepted(self: *const LocalTlsHttp1Origin) u32 {
        return tls_shim.collo_test_tls_http1_origin_accepted(self.handle);
    }
};

// The origin answers the first GET on a connection and closes on the second
// without answering and without a close_notify. The pooled wire is clean
// when the second GET leases it, and the close under the request ends the
// TLS stream before any response byte, so the GET, bodiless and idempotent,
// is sent again on a fresh connection instead of waiting out its stall
// window.
test "egress http1 replays a GET whose pooled TLS wire's peer closes under it without a close_notify" {
    try expectGetReplayedAfterTlsPeerEnd(tls_shim.test_tls_http1_origin_close_second);
}

// The same death as a reset, which the data driver reads as the end of the
// stream.
test "egress http1 replays a GET whose pooled TLS wire's peer resets under it" {
    try expectGetReplayedAfterTlsPeerEnd(tls_shim.test_tls_http1_origin_reset_second);
}

fn expectGetReplayedAfterTlsPeerEnd(mode: c_int) !void {
    const origin = try LocalTlsHttp1Origin.start(gpa, mode);
    defer origin.stop(gpa);
    var client: Client = undefined;
    try client.init(gpa);
    defer client.deinit();

    const url = try origin.url(gpa, "/kept");
    defer gpa.free(url);
    // The origin's certificate names another host, so the test skips
    // verification. The stall window bounds the wait the end of the TLS
    // stream must cut short.
    const config: transport.Config = .{
        .network = origin.policy(),
        .insecure_tls = true,
        .max_response_body_bytes = 64,
        .socket_timeout_ms = 2_000,
    };

    for (0..2) |_| {
        var response = Response.init(url);
        defer response.deinit(gpa);
        try fetchViaExchange(&client, .{ .url = url }, config, &response);
        try response.expectBody(gpa, test_support.kept_body);
    }
    try std.testing.expectEqual(@as(u32, 2), origin.accepted());
}

//! Shared fixtures for the HTTP/2 pool tests: the local TLS origins of the
//! test shim, declared in `runtime/tests/support/tls/shim.zig` and re-exported
//! here, a routable local IPv4 address, and a write transport that accepts
//! bounded chunks.

const std = @import("std");
const local_address = @import("collo_test_net");
const tls_shim = @import("collo_test_tls_shim");
pub const pool = @import("collo_egress_client").pool;
pub const data_io = pool.data_io;
pub const readiness = pool.readiness;
pub const transport = pool.transport;

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

pub fn routableLocalIpv4(out: *[64]u8) ![]const u8 {
    return local_address.routableLocalIpv4(out);
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

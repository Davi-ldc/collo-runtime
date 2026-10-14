//! Per-fetch transport configuration and the egress clock: the network policy
//! every hop is checked against, body and protocol limits, timeouts and pool
//! isolation identities, and the monotonic clock every egress deadline is
//! read on.
//!
//! The defaults serve standalone use and tests, except `network`, which has
//! none, so every caller names what its fetches may reach. The gateway
//! builds one `Config` per fetch from its limits, the policy its token
//! names, the fetch's request deadline and its isolation identities.
//! Deadlines are absolute nanoseconds on `monotonicNowNs`, and zero means
//! none.
//!
//! HTTP/2 connection limits come from the config of the fetch that opened
//! the connection and are not part of any pool key: the gateway sets the same
//! limits on every fetch, and a later fetch's own response cap still applies
//! per stream.

const std = @import("std");
const core = @import("collo_egress_core");
const egress_tls = @import("../tls.zig");
const http2 = @import("h2/codec/root.zig");
const limits = @import("collo_limits");
const network = @import("collo_network");

const stream_pump = core.stream_pump;

pub const default_http2_max_outgoing_buffer_bytes: usize = 1024 * 1024;
pub const default_wire_buffer_bytes: usize = default_http2_max_outgoing_buffer_bytes;
pub const PoolIsolationId = [16]u8;
pub const SecurityCellId = PoolIsolationId;
pub const zero_pool_isolation_id: PoolIsolationId = [_]u8{0} ** 16;

pub const IoInterest = egress_tls.IoInterest;
pub const IoStep = egress_tls.IoStep;

pub const Protocol = enum {
    plain,
    tls,

    pub fn fromScheme(scheme: []const u8) ?Protocol {
        if (std.ascii.eqlIgnoreCase(scheme, "http"))
            return .plain;
        if (std.ascii.eqlIgnoreCase(scheme, "https"))
            return .tls;
        return null;
    }
};

/// Reads CLOCK_BOOTTIME, the clock the data driver's absolute io_uring
/// timeouts (`IORING_TIMEOUT_BOOTTIME`) compare against, so a deadline the
/// engine computes and the timeout the ring arms for it agree.
pub fn monotonicNowNs() !u64 {
    const ts = try std.posix.clock_gettime(std.posix.CLOCK.BOOTTIME);
    const sec: u64 = @intCast(ts.sec);
    const nsec: u64 = @intCast(ts.nsec);
    return sec * std.time.ns_per_s + nsec;
}

pub fn deadlineAfterMs(timeout_ms: u32) !u64 {
    return (try monotonicNowNs()) +| @as(u64, timeout_ms) * std.time.ns_per_ms;
}

pub const Config = struct {
    /// What the fetch may reach, checked on every hop, redirects included:
    /// the scheme, host and port before DNS and every resolved address after
    /// it (`request/policy.zig`). It points into memory its owner keeps for
    /// as long as the fetch runs: the gateway's decoded table, or a constant
    /// such as `network.public_https`.
    network: network.Policy,
    max_response_body_bytes: usize = limits.http_body.MATERIALIZED_BODY_BYTES_MAX,
    /// Wire bytes accepted for one response, bounded apart from decoded bytes
    /// so a compressed response cannot spend unbounded network and CPU while
    /// producing little decoded output.
    max_encoded_response_bytes: usize = limits.http_body.MATERIALIZED_BODY_BYTES_MAX,
    max_pending_decoded_body_bytes: usize = stream_pump.default_max_pending_decoded_bytes,
    max_decoded_to_encoded_ratio: u64 = stream_pump.default_max_decoded_to_encoded_ratio,
    /// How long the fetch may wait on the network without progress: each dial
    /// phase (DNS, TCP connect, TLS handshake) and each wait on the origin
    /// once connected.
    socket_timeout_ms: u32 = 5_000,
    /// Deadline of the whole fetch: in the gateway, the deadline of the
    /// egress token that admitted it. Zero leaves only the per-stage socket
    /// timeouts, as for a standalone caller.
    request_deadline_mono_ns: u64 = 0,
    /// Disables certificate verification for tests and benchmarks. It must
    /// never come from a worker message or a tenant request option; the
    /// gateway never sets it and asserts so for every fetch.
    insecure_tls: bool = false,
    /// False keeps the fetch on HTTP/1: its dials offer only http/1.1 and it
    /// never opens an HTTP/2 stream.
    enable_http2: bool = true,
    http2_max_active_streams: usize = http2.default_limits.max_active_streams,
    http2_stream_receive_window: u32 = http2.default_limits.stream_receive_window,
    http2_conn_receive_window: u32 = http2.default_limits.connection_receive_window,
    http2_receive_window_update_threshold: u32 = http2.default_limits.receive_window_update_threshold,
    http2_max_pending_body_credit_per_stream: usize = http2.default_limits.max_pending_body_credit_per_stream,
    http2_max_pending_body_credit_per_connection: usize = http2.default_limits.max_pending_body_credit_per_connection,
    http2_max_outgoing_buffer_bytes: usize = default_http2_max_outgoing_buffer_bytes,
    /// Bytes a connection's wire may hold on this side, plain or TLS alike:
    /// its queued sends plus TLS ciphertext the read BIO has not taken
    /// (`wire.zig:Wire.max_buffered_bytes`).
    wire_buffer_bytes: usize = default_wire_buffer_bytes,
    http1_pool_max_entries: usize = 16,
    /// Reuse saves the DNS, connect and TLS cost, but an idle connection must
    /// be dropped before typical server and middlebox windows close it
    /// (nginx defaults to 75 s and sends nothing on expiry): a silently closed
    /// connection costs the next fetch a write and a wait before its retry.
    /// A server's Keep-Alive hint caps its own entries further.
    http1_pool_idle_timeout_ns: u64 = 60 * std.time.ns_per_s,
    http1_pool_max_connection_age_ns: u64 = 30 * 60 * std.time.ns_per_s,
    http1_pool_max_requests_per_connection: usize = 256,
    max_redirects: usize = 20,
    /// Draining a redirect's body only keeps its connection reusable, so the
    /// drain has its own cap and a redirect chain cannot spend the response
    /// body budget on every hop.
    max_redirect_drain_bytes: usize = 64 * 1024,
    /// Pool isolation identities, part of every origin key and TLS session
    /// key. The gateway fills them with the fetch's security cell and policy
    /// so one gateway never shares connections or sessions across tenants;
    /// zero serves standalone use and tests.
    pool_security_cell_id: PoolIsolationId = zero_pool_isolation_id,
    pool_policy_id: PoolIsolationId = zero_pool_isolation_id,

    pub fn http2Limits(self: Config) http2.Limits {
        // A stream's receive window promises the peer that many bytes, and
        // the pump pauses on pending decoded bytes only, with no separate
        // encoded watermark. The advertised window and per-stream credit
        // therefore stay within the decoded queue budget.
        const decoded_pending_cap = @max(
            @as(usize, 1),
            @min(self.max_pending_decoded_body_bytes, self.max_response_body_bytes),
        );
        const encoded_pending_cap = @max(
            @as(usize, 1),
            @min(decoded_pending_cap, self.max_encoded_response_bytes),
        );
        const stream_window_cap: u32 = @intCast(@min(
            encoded_pending_cap,
            @as(usize, std.math.maxInt(u32)),
        ));
        return .{
            .max_active_streams = self.http2_max_active_streams,
            .stream_receive_window = @min(self.http2_stream_receive_window, stream_window_cap),
            .connection_receive_window = self.http2_conn_receive_window,
            .receive_window_update_threshold = self.http2_receive_window_update_threshold,
            .max_pending_body_credit_per_stream = @min(
                self.http2_max_pending_body_credit_per_stream,
                decoded_pending_cap,
            ),
            .max_pending_body_credit_per_connection = self.http2_max_pending_body_credit_per_connection,
        };
    }

    pub fn streamPumpLimits(self: Config) stream_pump.Limits {
        return .{
            .max_decoded_bytes = self.max_response_body_bytes,
            .max_encoded_bytes = self.max_encoded_response_bytes,
            .max_pending_decoded_bytes = self.max_pending_decoded_body_bytes,
            .max_decoded_to_encoded_ratio = self.max_decoded_to_encoded_ratio,
        };
    }

    pub fn capDeadlineMonoNs(self: Config, deadline_mono_ns: u64) u64 {
        if (self.request_deadline_mono_ns == 0)
            return deadline_mono_ns;
        return @min(deadline_mono_ns, self.request_deadline_mono_ns);
    }

    /// The stall deadline: `socket_timeout_ms` after `now_mono_ns`, capped by
    /// the request deadline. The socket timeout measures network silence, so
    /// the engine recomputes this at every dial phase and on every sign of
    /// origin progress. A long transfer that keeps progressing pushes the
    /// deadline forward, a silent origin lets it fire, and
    /// `request_deadline_mono_ns` still bounds the whole fetch.
    pub fn stallDeadlineFromNow(self: Config, now_mono_ns: u64) u64 {
        const raw = now_mono_ns +| @as(u64, self.socket_timeout_ms) * std.time.ns_per_ms;
        return self.capDeadlineMonoNs(raw);
    }

    pub fn requestDeadlineExpiredAt(self: Config, now_mono_ns: u64) bool {
        return self.request_deadline_mono_ns != 0 and now_mono_ns >= self.request_deadline_mono_ns;
    }

    /// The deadline that bounds the whole fetch, or the largest instant when
    /// it has none.
    pub fn requestDeadlineOrUnbounded(self: Config) u64 {
        if (self.request_deadline_mono_ns != 0)
            return self.request_deadline_mono_ns;
        return std.math.maxInt(u64);
    }
};

//! The largest fetch the worker-to-gateway packets can carry (`egress.zig`),
//! shared by the worker, the codec and the gateway. These bounds are
//! structural, so the gateway's policy (`egress/gateway/policy.zig`) can
//! tighten them and never loosen them. A small request body rides inline in
//! the start packet; a larger one streams through the upload pool as
//! extents, bounded only by `request_body_pooled_bytes_max`, and the gateway
//! assembles it on its heap and keeps it for redirect replay.
//!
//! The start packet holds its header, method, URL, request headers and
//! inline body, so `request_body_inline_bytes_max` is what remains of
//! `request_packet_bytes_max` after the other maxima. `egress.zig` asserts
//! that `request_packet_bytes_max` and `request_start_header_bytes` match
//! the ring's packet bound and the start header's size.

const std = @import("std");

pub const request_packet_bytes_max: usize = 1024 * 1024;
pub const request_start_header_bytes: usize = 112;
pub const request_method_bytes_max: usize = 32;
pub const request_url_bytes_max: usize = 16 * 1024;
pub const request_headers_bytes_max: usize = 64 * 1024;
pub const response_status_text_bytes_max: usize = 1024;
pub const response_url_bytes_max: usize = request_url_bytes_max;
pub const response_headers_bytes_max: usize = request_headers_bytes_max;

pub const request_body_inline_bytes_max: usize =
    request_packet_bytes_max -
    request_start_header_bytes -
    request_method_bytes_max -
    request_url_bytes_max -
    request_headers_bytes_max;

/// The worker sends a body up to this size inline in the start packet and
/// streams a larger one through the upload pool. It equals one pool block
/// (`egress_shared.body_pool_block_size`) and the HTTP/1 wire's
/// coalesced-write bound (`max_coalesced_body_bytes` in
/// `egress/client/transport/http1/wire.zig`), though nothing ties them. The
/// decoder still accepts inline bodies up to `request_body_inline_bytes_max`.
pub const request_body_inline_preferred_bytes_max: usize = 16 * 1024;

/// Ceiling of a pool-streamed request body. It bounds the gateway's
/// per-fetch assembly buffer, which lives through redirects, and not the
/// pool, since each extent returns to the pool as soon as it is copied out.
/// `validate` in `egress/gateway/policy.zig` refuses a
/// `max_request_body_bytes` above it.
pub const request_body_pooled_bytes_max: usize = 32 * 1024 * 1024;

comptime {
    std.debug.assert(request_packet_bytes_max > request_start_header_bytes);
    std.debug.assert(request_body_inline_bytes_max > 0);
    std.debug.assert(request_body_inline_preferred_bytes_max <= request_body_inline_bytes_max);
    std.debug.assert(request_body_pooled_bytes_max >= request_body_inline_bytes_max);
    std.debug.assert(request_body_pooled_bytes_max <= std.math.maxInt(u32));
    std.debug.assert(request_start_header_bytes <= std.math.maxInt(u32));
    std.debug.assert(request_method_bytes_max <= std.math.maxInt(u32));
    std.debug.assert(request_url_bytes_max <= std.math.maxInt(u32));
    std.debug.assert(request_headers_bytes_max <= std.math.maxInt(u32));
    std.debug.assert(request_body_inline_bytes_max <= std.math.maxInt(u32));
    std.debug.assert(response_status_text_bytes_max <= std.math.maxInt(u32));
    std.debug.assert(response_url_bytes_max <= std.math.maxInt(u32));
    std.debug.assert(response_headers_bytes_max <= std.math.maxInt(u32));
}

//! The largest fetch the worker-to-gateway packets can carry (`egress.zig`),
//! shared by the worker, the codec and the gateway. These bounds are
//! structural, so the gateway's policy (`egress/gateway/policy.zig`) can
//! tighten them and never loosen them. A small request body rides inline in
//! the start packet; a larger one streams through the upload pool as
//! extents, bounded by `request_body_pooled_bytes_max` per body and, with the
//! copies of its start, `request_body_pooled_in_flight_bytes_max` per
//! session, and the gateway assembles it in its upload budget and keeps it
//! for redirect replay.
//!
//! The start packet holds its header, method, URL, request headers and
//! inline body, so `request_body_inline_bytes_max` is what remains of
//! `request_packet_bytes_max` after the other maxima. `egress.zig` asserts
//! that `request_packet_bytes_max` and `request_start_header_bytes` match
//! the ring's packet bound and the start header's size.

const std = @import("std");
const messages = @import("messages.zig");

pub const request_packet_bytes_max: usize = 1024 * 1024;
pub const request_start_header_bytes: usize = 104;
pub const request_method_bytes_max: usize = 32;
pub const request_url_bytes_max: usize = 16 * 1024;
pub const request_headers_bytes_max: usize = 64 * 1024;
pub const response_status_text_bytes_max: usize = 1024;
pub const response_url_bytes_max: usize = request_url_bytes_max;
pub const response_headers_bytes_max: usize = request_headers_bytes_max;
/// The longest message a fetch's error packet carries. The gateway's texts
/// are its own and an engine error's name, or the network setting's denial,
/// which names a host it cuts short (`network.grant.denial_bytes_max`), so the
/// cap bounds the completion-ring room a fetch's terminal packet takes.
pub const response_error_message_bytes_max: usize = 1024;

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

/// The most a gateway's assembly record of one pooled start takes
/// (`egress/gateway/fetch_table.zig:Upload`, which asserts that it fits).
pub const pooled_start_record_bytes: usize = 512;

/// The bytes a gateway keeps for a pooled start besides its body, from its
/// admission to its terminal packet: copies of the method, the URL and the
/// header names and values, the slices of the headers, and the assembly
/// record. Both ends compute it from the same fields of the start, the
/// worker before it sends it and the gateway when it admits it, and count it
/// with the announced body length against
/// `request_body_pooled_in_flight_bytes_max`, so the copies stay inside the
/// session's upload room. `headers` is any slice of values with `name` and
/// `value` byte slices.
pub fn pooledStartHeldBytes(method_len: usize, url_len: usize, headers: anytype) u64 {
    var held: u64 = pooled_start_record_bytes + method_len + url_len;
    for (headers) |header|
        held += @sizeOf(messages.RequestHeader) + header.name.len + header.value.len;
    return held;
}

/// `pooledStartHeldBytes` of the largest start the packets carry.
pub const pooled_start_held_bytes_max: usize = pooled_start_record_bytes +
    request_method_bytes_max +
    request_url_bytes_max +
    request_headers_bytes_max +
    messages.max_request_header_count * @sizeOf(messages.RequestHeader);

/// Bytes one egress session's pooled starts may hold in the gateway at once,
/// each counted as its announced body length plus `pooledStartHeldBytes`:
/// twice the largest body. Both ends read it and count a fetch's bytes until
/// its terminal packet. The worker parks a pooled start that would pass it
/// until earlier uploads end, so the gateway's refusal of one past it never
/// reaches an honest worker.
pub const request_body_pooled_in_flight_bytes_max: usize = 2 * request_body_pooled_bytes_max;

comptime {
    std.debug.assert(request_packet_bytes_max > request_start_header_bytes);
    std.debug.assert(request_body_inline_bytes_max > 0);
    std.debug.assert(request_body_inline_preferred_bytes_max <= request_body_inline_bytes_max);
    std.debug.assert(request_body_pooled_bytes_max >= request_body_inline_bytes_max);
    std.debug.assert(request_body_pooled_bytes_max <= std.math.maxInt(u32));
    // A start that waits for room waits only behind other starts: one alone always fits.
    std.debug.assert(request_body_pooled_in_flight_bytes_max >= request_body_pooled_bytes_max + pooled_start_held_bytes_max);
    std.debug.assert(request_start_header_bytes <= std.math.maxInt(u32));
    std.debug.assert(request_method_bytes_max <= std.math.maxInt(u32));
    std.debug.assert(request_url_bytes_max <= std.math.maxInt(u32));
    std.debug.assert(request_headers_bytes_max <= std.math.maxInt(u32));
    std.debug.assert(request_body_inline_bytes_max <= std.math.maxInt(u32));
    std.debug.assert(response_status_text_bytes_max <= std.math.maxInt(u32));
    std.debug.assert(response_url_bytes_max <= std.math.maxInt(u32));
    std.debug.assert(response_headers_bytes_max <= std.math.maxInt(u32));
    std.debug.assert(response_error_message_bytes_max <= std.math.maxInt(u32));
}

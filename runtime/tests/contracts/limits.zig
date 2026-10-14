//! Comptime asserts that tie limits of different modules together; the
//! comment above each block names the limits it relates. `collo_limits`
//! imports nothing (`common/limits/root.zig` says why), so a relation between
//! one of its constants and a module that imports it cannot live there.
//!
//! `runtime/all_tests.zig` imports this file, so every build of the aggregate
//! test binary checks it and a drift fails compilation. It declares no tests;
//! only the compiler evaluates it. A bound derived for one consumer stays
//! asserted at that consumer, as the server's pending body and response
//! buffers are in `server/ingress/runner/flow_control.zig` and
//! `write_queue.zig`; this file relates only limits that two modules share.

const std = @import("std");
const limits = @import("collo_limits");
const cgroup = @import("collo_cgroup");
const dns_name = @import("collo_dns_name");
const ipc = @import("collo_ipc");
const h2_protocol = @import("collo_http").http2;
const network = @import("collo_network");
const gateway_policy = @import("collo_egress_gateway").policy;
const transport_config = @import("collo_egress_client").transport.config;
const server_config = @import("collo_server_config");
const server_main = @import("collo_server_main");
const worker_shared_page = @import("collo_worker_state").page;

// The gateway's `Policy` defaults against the shared budgets and the IPC
// caps. Each default that equals a budget cites it in its declaration, and
// its assert fails once the two stop being equal, as a literal left behind
// by a later budget change would. `egress/gateway/policy.zig` asserts at
// comptime that `production` holds the IPC bounds.
comptime {
    const default_policy = gateway_policy.Policy{};
    // Both response caps equal the size a worker holds a body whole in.
    // Above it, the gateway delivers fetch bodies the worker then refuses to
    // buffer or return; below it, the gateway refuses bodies the worker could
    // hold. The encoded cap bounds the wire bytes of a compressed response
    // against the same budget.
    std.debug.assert(default_policy.max_response_body_bytes ==
        limits.http_body.MATERIALIZED_BODY_BYTES_MAX);
    std.debug.assert(default_policy.max_encoded_response_bytes ==
        limits.http_body.MATERIALIZED_BODY_BYTES_MAX);
    // The body drain moves at most this many bytes from a fetch's body queue
    // into the worker's body pool per step, and `EGRESS_BODY_CHUNK_BYTES` is
    // where that pacing is documented.
    std.debug.assert(default_policy.max_body_chunk_bytes ==
        limits.http_body.EGRESS_BODY_CHUNK_BYTES);
    // The pooled upload default sits exactly at the IPC's ceiling: above, the
    // IPC could not carry what the gateway admits; below, the gateway refuses
    // uploads the IPC can carry.
    std.debug.assert(default_policy.max_request_body_bytes ==
        ipc.fetch_limits.request_body_pooled_bytes_max);
    // The request header bytes stay within the fetch IPC's header cap and
    // the response header bytes within the room a fetch head message leaves.
    std.debug.assert(default_policy.max_request_header_bytes <=
        ipc.fetch_limits.request_headers_bytes_max);
    std.debug.assert(default_policy.max_response_header_bytes <=
        gateway_policy.maxResponseHeaderBytesForIpc());
    // The header count defaults sit at the IPC's header count cap: above, the
    // IPC could not carry them; below, the gateway refuses headers the IPC
    // can carry.
    std.debug.assert(default_policy.max_request_headers ==
        ipc.max_request_header_count);
    std.debug.assert(default_policy.max_response_headers ==
        ipc.max_request_header_count);
}

// The transport's `Config` defaults match the gateway policy's. The gateway
// builds each fetch's `Config` from its policy, but a client built with the
// default `Config`, as standalone callers, tests and benchmarks are, must
// keep the same body budget.
comptime {
    const default_config = transport_config.Config{ .network = network.public_https };
    std.debug.assert(default_config.max_response_body_bytes ==
        limits.http_body.MATERIALIZED_BODY_BYTES_MAX);
    std.debug.assert(default_config.max_encoded_response_bytes ==
        limits.http_body.MATERIALIZED_BODY_BYTES_MAX);
}

// The worker's response header caps against the caps the server decodes a
// worker response with. The body needs no assert, because the worker and the
// server both cite `MATERIALIZED_BODY_BYTES_MAX` directly.
comptime {
    const response_model = @import("collo_worker_request").response_model;
    const ingress_h2 = server_main.http2.writing;
    // The caps are equal. Should they ever split, the server's may only be
    // larger: a response the worker validated would otherwise fail
    // `decodeResponseHeadBounded` in the server and be dropped.
    std.debug.assert(ingress_h2.max_worker_response_header_count ==
        response_model.max_response_header_count);
    std.debug.assert(ingress_h2.max_worker_response_header_bytes ==
        response_model.max_response_header_bytes);
}

// The server's HTTP/2 SETTINGS against the protocol bounds in
// `collo_http.http2`. Nothing normalizes these values at run time, as the
// egress client's `Limits.normalized` does: `queueServerSettingsAndAck` in
// `server/ingress/http2/writing.zig` writes them to the wire as they are.
comptime {
    // Right after its SETTINGS the server raises the connection window with
    // a WINDOW_UPDATE of the window minus `default_initial_window_size`. A
    // window equal to that default sends an increment of zero, which the
    // peer treats as a connection PROTOCOL_ERROR (RFC 9113 §6.9), and a
    // smaller one cannot be expressed at all.
    std.debug.assert(limits.h2.INGRESS_CONNECTION_RECV_WINDOW_BYTES >
        h2_protocol.default_initial_window_size);
    // A SETTINGS_INITIAL_WINDOW_SIZE above `max_window_size` is a connection
    // FLOW_CONTROL_ERROR at the peer (RFC 9113 §6.5.2), and the connection
    // window must be a valid window as well.
    std.debug.assert(limits.h2.INGRESS_STREAM_RECV_WINDOW_BYTES <=
        h2_protocol.max_window_size);
    std.debug.assert(limits.h2.INGRESS_CONNECTION_RECV_WINDOW_BYTES <=
        h2_protocol.max_window_size);
    // SETTINGS_MAX_FRAME_SIZE outside its protocol range is itself a
    // connection PROTOCOL_ERROR (RFC 9113 §6.5.2). Below the protocol
    // default, the server's own check on inbound frames would also reject
    // frames the protocol allows.
    std.debug.assert(limits.h2.INGRESS_MAX_FRAME_SIZE_BYTES >=
        h2_protocol.default_max_frame_size);
    std.debug.assert(limits.h2.INGRESS_MAX_FRAME_SIZE_BYTES <=
        h2_protocol.max_frame_payload_len);
}

// The egress client's window defaults against the protocol bound.
// `Limits.normalized` in `egress/client/transport/h2/codec/client.zig`
// rejects a window above it with `error.InvalidHttp2Limits`, so a default
// past the bound would fail every HTTP/2 egress connection at run time.
comptime {
    std.debug.assert(limits.h2.EGRESS_STREAM_RECV_WINDOW_BYTES <=
        h2_protocol.max_window_size);
    std.debug.assert(limits.h2.EGRESS_CONNECTION_RECV_WINDOW_BYTES <=
        h2_protocol.max_window_size);
}

// `common/limits/h2.zig` documents the egress stream window as smaller than
// the server's and the egress connection window as larger, each on purpose.
// A change that flips either relation revisits those comments and the
// windows' consumers instead of dropping the assert.
comptime {
    std.debug.assert(limits.h2.EGRESS_STREAM_RECV_WINDOW_BYTES <
        limits.h2.INGRESS_STREAM_RECV_WINDOW_BYTES);
    std.debug.assert(limits.h2.EGRESS_CONNECTION_RECV_WINDOW_BYTES >
        limits.h2.INGRESS_CONNECTION_RECV_WINDOW_BYTES);
}

// The CPU quota every launch gives its worker against the quota
// `common/cgroup.zig` gives a leaf configured or checked without one
// (`worker.Limits`). The cgroup module imports nothing, so it keeps its own
// copy, and a copy that drifted would configure or check a leaf with a quota
// no launch uses.
comptime {
    std.debug.assert(limits.worker.cpu_max_cores == cgroup.cpu.DEFAULT_MAX_CORES);
}

// The server's configuration bounds (`common/limits/server.zig`) against the
// IPC messages a configured route travels through and the host-name bound of
// `common/dns_name.zig`.
comptime {
    // A route's text bindings reach the worker as its bindings section in
    // the definition artifact; a larger per-route bound would accept
    // bindings no worker can receive.
    std.debug.assert(limits.server.binding_bytes_per_route_max ==
        ipc.route_bindings.bytes_max);
    // Every route of a definition travels in its one artifact, and a
    // dispatch names a route by a u16 index into it.
    std.debug.assert(limits.server.routes_per_definition_max ==
        ipc.route_table.routes_max);
    std.debug.assert(ipc.route_table.routes_max <= std.math.maxInt(u16) + 1);
    // Every `:param` segment of a matched pattern becomes one capture in the
    // dispatch message, so the deepest pattern's captures must fit it.
    std.debug.assert(limits.server.route_path_segments_max ==
        ipc.max_route_capture_count);
    // The total pack budget must admit at least one pack of the largest size
    // the pack format allows.
    std.debug.assert(limits.server.pack_bytes_total_max >=
        ipc.module_pack.max_pack_bytes);
    // The longest `network.allow` entry is a suffix pattern over the longest
    // host name DNS admits, with the largest port.
    std.debug.assert(limits.server.network_allow_entry_bytes_max ==
        "*.".len + dns_name.max_name_bytes + ":65535".len);
}

// The `network` grammar (`common/network/`, which imports only the limits)
// against the modules that bound the same text. Its longest name is the DNS
// name check's, and `common/tests/network/pattern.zig` tests that every
// canonical name it admits passes `dns_name.validateName`. A denial's
// message, which the worker writes to the tenant's log as one
// console line, must fit one line of the console ring.
comptime {
    std.debug.assert(network.pattern.name_bytes_max == dns_name.max_name_bytes);
    std.debug.assert(network.grant.denial_bytes_max <= worker_shared_page.LOG_LINE_BYTES_MAX);
}

// WorkerInit's unowned limit of a launch made without a worker definition
// against the `timeoutMs` a definition gets when it sets none. A launch for a
// definition sends that definition's own; the two defaults must not drift, or
// a test launch would bound unowned JavaScript by a limit no configuration
// gives.
comptime {
    const default_timeout_ns = @as(u64, server_config.default_settings.limits.timeout_ms) *
        std.time.ns_per_ms;
    std.debug.assert(ipc.WorkerInit.default_unowned_time_limit_ns == default_timeout_ns);
}

// A lane's ingress bounds (`common/limits/ingress.zig`, which imports
// nothing) against the bounds of what they hold.
comptime {
    // A worker's reader receives a packet only while a whole batch of
    // descriptors still fits the forwarding window (`windowHasRoom` in
    // `server/ingress/runner/h2_worker_ipc.zig`). A window below one batch
    // would never let it receive, and one below two would let it receive
    // only once the lanes had applied everything it forwarded before, so the
    // worker's output would stop at every packet.
    std.debug.assert(limits.ingress.forwarded_commands_per_worker_max >=
        2 * ipc.ingress_channel.max_batch_descriptors);
    // A connection whose header block would pass the lane's budget closes,
    // so a budget below one block's bound would close a client that sends a
    // block the server admits, even with no other connection on the lane.
    std.debug.assert(limits.ingress.header_block_bytes_per_lane_max >=
        limits.headers.INGRESS_H2_REQUEST_HEADER_BLOCK_BYTES);
}

// One request per pool slot, on both ends: the pool hands a worker at most
// `worker_concurrency_max` requests at once and takes a slot back only at its
// request's `request_done` or the worker's death (`server/supervisor/pool.zig`),
// a dispatch names the pool slot its request holds (`DispatchWork.worker_slot`,
// a u8 the decoder bounds by `worker_concurrency_max`), the worker writes that
// request's live slot at that index of its page (`LIVE_SLOT_COUNT` slots), and
// it keeps one task per request (`request_task_capacity`). A table smaller
// than the pool's bound would refuse a request the server may send; a larger
// one would size every worker's tables for requests that never come.
comptime {
    std.debug.assert(worker_shared_page.LIVE_SLOT_COUNT == limits.server.worker_concurrency_max);
    std.debug.assert(limits.worker.request_task_capacity == worker_shared_page.LIVE_SLOT_COUNT);
    std.debug.assert(worker_shared_page.LIVE_SLOT_COUNT <= std.math.maxInt(u8) + 1);
    std.debug.assert(worker_shared_page.LIVE_SLOT_COUNT <= worker_shared_page.live_slot_count_page_zero_max);
}

// Relations deliberately left unasserted:
// - The egress WINDOW_UPDATE threshold below the stream window. The
//   constants put `EGRESS_RECV_WINDOW_UPDATE_THRESHOLD_BYTES` above
//   `EGRESS_STREAM_RECV_WINDOW_BYTES`, and `receiveWindowThreshold` in
//   `egress/client/transport/h2/codec/client.zig` clamps the threshold to
//   half the smaller window at run time.
// - The frame size against the receive windows. Flow control bounds DATA
//   bytes whatever the frame size cap is, so neither order is required.
// - The server's connection window against its stream window. The
//   connection window is the larger, but nothing depends on that order.

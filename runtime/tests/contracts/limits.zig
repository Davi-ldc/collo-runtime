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
const ipc = @import("collo_ipc");
const h2_protocol = @import("collo_http").http2;
const gateway_policy = @import("collo_egress_gateway").policy;
const transport_config = @import("collo_egress_transport").config;
const server_main = @import("collo_server_main");
const worker_shared_page = @import("collo_worker_state").page;

// The gateway's `Policy` defaults against the shared budgets and the IPC
// caps. Each default that equals a budget cites it in its declaration, and
// its assert fails once the two stop being equal, as a literal left behind
// by a later budget change would. `Engine.init` in
// `egress/gateway/engine.zig` runs `policy.validate`, so a default that
// fails it stops every gateway from starting.
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
    // A policy may lower the pooled upload ceiling but never raise it, and
    // the default sits exactly at it: above, `validate` fails; below, the
    // gateway refuses uploads the IPC can carry.
    std.debug.assert(default_policy.max_request_body_bytes ==
        ipc.fetch_limits.request_body_pooled_bytes_max);
    // `validate` bounds the request header bytes by the fetch IPC's header
    // cap and the response header bytes by the room a fetch head message
    // leaves.
    std.debug.assert(default_policy.max_request_header_bytes <=
        ipc.fetch_limits.request_headers_bytes_max);
    std.debug.assert(default_policy.max_response_header_bytes <=
        gateway_policy.maxResponseHeaderBytesForIpc());
    // The header count defaults sit at the IPC's header count cap: above,
    // `validate` fails; below, the gateway refuses headers the IPC can carry.
    std.debug.assert(default_policy.max_request_headers ==
        ipc.max_request_header_count);
    std.debug.assert(default_policy.max_response_headers ==
        ipc.max_request_header_count);
}

// The fetches a worker lets one request start against the fetch budget the
// server stamps into the request's egress token and into the boot token. The
// worker refuses a request's fetch past its count itself
// (`fetch_runtime.schedule` in `worker/egress/`), and the gateway counts a
// start past the token's budget as an invalid command, so a count above
// either budget would have an honest worker struck.
comptime {
    const boot_options = ipc.WorkerRuntimeBootOptions{};
    std.debug.assert(boot_options.max_fetches_per_request <=
        gateway_policy.production.max_fetches_per_request);
    std.debug.assert(boot_options.max_fetches_per_request <=
        gateway_policy.production.max_fetches_per_boot);
}

// The transport's `Config` defaults match the gateway policy's. The gateway
// builds each fetch's `Config` from its policy, but a client built with the
// default `Config`, as standalone callers, tests and benchmarks are, must
// keep the same body budget.
comptime {
    const default_config = transport_config.Config{};
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

// The fs fault budgets against the worker tmpfs they protect. The C++ copy
// of the fault file ceiling is kept equal by hand, and
// `COLLO_FS_FAULT_MAX_FILE_BYTES` in `bindings/include/collo/abi.h` says
// why; these asserts relate only the Zig constants.
comptime {
    // The budget is a percentage of the tmpfs: zero would reject every
    // fault, and above 100 materialized files could fill more than the
    // tmpfs they share with the worker's own writes.
    std.debug.assert(limits.fs_fault.materialize_budget_percent > 0 and
        limits.fs_fault.materialize_budget_percent <= 100);
    // The ceiling equals the default tmpfs size; `max_fault_file_bytes` says
    // why. The limits module imports nothing, so the equality is asserted
    // here instead of derived. On a default-sized worker the budget admits
    // only `materialize_budget_percent` of the ceiling, and that gap is
    // intended, so nothing ties the budget to one ceiling-sized file.
    std.debug.assert(limits.fs_fault.max_fault_file_bytes ==
        ipc.messages.WorkerInit.default_tmpfs_size_bytes);
    // The sweep runs when a request finishes and walks the ledger at most
    // once per interval (`sweepIdleMaterialized` in `worker/fs/copies.zig`),
    // so even on a busy worker an idle copy can outlive the threshold by one
    // interval. An interval above the threshold would make that lag longer
    // than the threshold it enforces.
    std.debug.assert(limits.fs_fault.materialized_sweep_interval_ns <=
        limits.fs_fault.materialized_idle_eviction_ns);
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
// IPC messages and the state page a configured route travels through.
comptime {
    // A route's text bindings reach the worker as its section of the route
    // table; a larger per-route bound would accept bindings no worker can
    // receive.
    std.debug.assert(limits.server.binding_bytes_per_route_max ==
        ipc.route_bindings.bytes_max);
    // Every route of a definition travels in one route table, and a dispatch
    // names a route by a u16 index into it.
    std.debug.assert(limits.server.routes_per_definition_max ==
        ipc.route_table.routes_max);
    std.debug.assert(ipc.route_table.routes_max <= std.math.maxInt(u16) + 1);
    // `concurrency` counts request slots on the worker's state page.
    std.debug.assert(limits.server.worker_concurrency_max ==
        worker_shared_page.LIVE_SLOT_COUNT);
    // Every `:param` segment of a matched pattern becomes one capture in the
    // dispatch message, so the deepest pattern's captures must fit it.
    std.debug.assert(limits.server.route_path_segments_max ==
        ipc.max_route_capture_count);
    // The total pack budget must admit at least one pack of the largest size
    // the pack format allows.
    std.debug.assert(limits.server.pack_bytes_total_max >=
        ipc.module_pack.max_pack_bytes);
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

// The completion ring's status bound against the statuses a worker publishes.
// The drain (`validateWorkerCompletionRecord` in
// `common/worker_state/page/completion_ring.zig`) refuses a status above the
// bound as a worker fault, so a tag added to `RequestDoneStatus` without
// raising the bound would fault every worker that publishes it.
comptime {
    var status_max: u32 = 0;
    for (std.enums.values(ipc.RequestDoneStatus)) |status|
        status_max = @max(status_max, @intFromEnum(status));
    std.debug.assert(worker_shared_page.worker_completion_status_max == status_max);
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

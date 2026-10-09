//! Collects the suites of the server's ingress (`server/ingress/`). Lane
//! `server-ingress-test`. `fault.zig` pins the failure-domain tables;
//! `worker_faults.zig`, `lane_commands.zig`, `request_deadlines.zig`,
//! `egress_tokens.zig` and `connection_rekey.zig` drive a whole lane through
//! its loop handlers against stub workers (`lane_harness.zig`); a whole
//! service with real workers runs in `local-e2e`.

comptime {
    _ = @import("fault.zig");
    _ = @import("slabs.zig");
    _ = @import("deadline_wheel.zig");
    _ = @import("completion_ring.zig");
    _ = @import("command_queue.zig");
    _ = @import("work_queues.zig");
    _ = @import("listener_accept.zig");
    _ = @import("server_responses.zig");
    _ = @import("health_state.zig");
    _ = @import("fs_fault.zig");
    _ = @import("h2_worker_framing.zig");
    _ = @import("peer_address.zig");
    _ = @import("runner_contract.zig");
    _ = @import("stream_target.zig");
    _ = @import("analytics_drain.zig");
    _ = @import("worker_faults.zig");
    _ = @import("lane_commands.zig");
    _ = @import("request_deadlines.zig");
    _ = @import("egress_tokens.zig");
    _ = @import("connection_rekey.zig");
}

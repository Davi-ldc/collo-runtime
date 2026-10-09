//! The egress gateway: the process that performs every outbound fetch. The server's side of it,
//! which spawns it and talks to it, is `server/gateway/`. Server code reads only the four files
//! both processes compile, `control.zig`, `launch.zig`, `policy.zig` and `sizing.zig`, and never
//! the gateway's loop, shards or engines (`runtime/tests/conventions.zig` checks it).
//!
//! `control.zig` is the wire between the server and the gateway, and `launch.zig` the gateway's
//! arg0 and inherited descriptor. `policy.zig` holds the limits both sides share and the network
//! policy table the server sends in its hello, and `sizing.zig` the numbers both sides must
//! agree on.
//!
//! Everything else runs only in the gateway. `runtime/` is its boot and event loop on the
//! process's main thread, `readiness.zig` the loop's io_uring wait, and `sandbox.zig` the sandbox
//! the process applies to itself. The loop's state is the worker sessions (`worker_registry.zig`,
//! `sessions.zig`, `drop_queue.zig`, `backpressure.zig`) with the fetch budgets of their tokens
//! (`budgets.zig`), the routes from worker ids to shards (`router.zig`), the active-fetch counts
//! (`limit_tracker.zig`) and the control packets still to send (`control_queue.zig`);
//! `publisher.zig` writes into worker endpoints. Behind the loop,
//! `shard_set.zig` and `shard.zig` own the shards, each with a budgeted allocator
//! (`counting_allocator.zig`, limits in `supervisor_limits.zig`) and an engine (`engine.zig`)
//! whose threads run the outbound transport. An engine keeps its admitted fetches in
//! `active_table.zig` and `active_fetch.zig`, learns which need attention through
//! `ready_scan.zig`, and turns responses into worker packets in `body_pump.zig`.

const builtin = @import("builtin");
const std = @import("std");

pub const control = @import("control.zig");
pub const engine = @import("engine.zig");
pub const active_fetch = @import("active_fetch.zig");
pub const active_table = @import("active_table.zig");
pub const backpressure = @import("backpressure.zig");
pub const body_pump = @import("body_pump.zig");
pub const budgets = @import("budgets.zig");
pub const control_queue = @import("control_queue.zig");
pub const counting_allocator = @import("counting_allocator.zig");
pub const drop_queue = @import("drop_queue.zig");
pub const launch = @import("launch.zig");
pub const limit_tracker = @import("limit_tracker.zig");
pub const policy = @import("policy.zig");
pub const publisher = @import("publisher.zig");
pub const readiness = @import("readiness.zig");
pub const ready_scan = @import("ready_scan.zig");
pub const router = @import("router.zig");
pub const runtime = @import("runtime/root.zig");
pub const sandbox = @import("sandbox.zig");
pub const sessions = @import("sessions.zig");
pub const shard = @import("shard.zig");
pub const shard_set = @import("shard_set.zig");
pub const sizing = @import("sizing.zig");
pub const supervisor_limits = @import("supervisor_limits.zig");
pub const worker_registry = @import("worker_registry.zig");

pub const testing = if (builtin.is_test) struct {
    /// The runtime loop's shard flow (the collection pass and the shard supervisor) as a comptime
    /// mixin: chaos tests instantiate `Methods` over a minimal recording gateway, so the real
    /// supervisor, backstop and redispatch code runs against real shards without worker
    /// shared-memory endpoints.
    pub const shard_flow = @import("runtime/shard_flow.zig");
    /// Release-flow credit-ack aggregation (`PendingCreditAck.tryMerge`): the merge rule must
    /// mirror `CreditBatch.add`'s, so tests pin it directly.
    pub const body_release_flow = @import("runtime/body_release_flow.zig");
    /// Worker-command dispatch and pooled-upload assembly as comptime mixins: the worker_flow
    /// suite instantiates both `Methods` over a minimal gateway harness, so the real adversarial
    /// dispatch runs against real shared-memory endpoints, the security boundary of the process
    /// that holds the network capability.
    pub const worker_flow = @import("runtime/worker_flow.zig");
    pub const upload_flow = @import("runtime/upload_flow.zig");
    /// The control socket's flow as a comptime mixin: the admission and control suites feed a
    /// harness gateway its hello through the real flow, so the key, the policy table and each
    /// entry's isolation id are the ones fetch admission reads.
    pub const control_flow = @import("runtime/control_flow.zig");
} else struct {};

pub const process_name = launch.process_name;
pub const inherited_control_fd = launch.inherited_control_fd;

/// The gateway process's entry point, run from `main` when arg0 is `process_name`. Runs on the
/// descriptor `launch.zig` defines and returns when the server shuts the gateway down. A command
/// line with anything after arg0 fails with `error.InvalidEgressGatewayArguments`, since the
/// server's spawn passes nothing there.
pub fn runFromInheritedControlFd(allocator: std.mem.Allocator) !void {
    if (std.os.argv.len != 1)
        return error.InvalidEgressGatewayArguments;
    try runtime.run(allocator, launch.inherited_control_fd);
}

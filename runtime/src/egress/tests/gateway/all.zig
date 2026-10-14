//! Collects the suites of the egress gateway process (`egress/gateway/`). Lane:
//! egress-gateway-test. The server's side of the gateway is covered in `server/tests/gateway/`.

comptime {
    _ = @import("body_pump.zig");
    _ = @import("command_flow.zig");
    _ = @import("control.zig");
    _ = @import("control_flow.zig");
    _ = @import("counting_allocator.zig");
    _ = @import("credit_batch.zig");
    _ = @import("engine.zig");
    _ = @import("fetch_flow.zig");
    _ = @import("fetch_table.zig");
    _ = @import("policy.zig");
    _ = @import("publisher.zig");
    _ = @import("readiness.zig");
    _ = @import("ready_scan.zig");
    _ = @import("release_flow.zig");
    _ = @import("sandbox.zig");
    _ = @import("session_flow.zig");
    _ = @import("sessions.zig");
    _ = @import("shard.zig");
    _ = @import("shard_flow.zig");
    _ = @import("sizing.zig");
    _ = @import("upload_flow.zig");
}

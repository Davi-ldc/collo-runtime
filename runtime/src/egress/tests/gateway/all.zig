//! Collects the suites of the egress gateway process (`egress/gateway/`). Lane:
//! egress-gateway-test. The server's side of the gateway is covered in `server/tests/gateway/`.

comptime {
    _ = @import("body_pump.zig");
    _ = @import("budgets.zig");
    _ = @import("control.zig");
    _ = @import("control_flow.zig");
    _ = @import("engine.zig");
    _ = @import("policy.zig");
    _ = @import("publisher.zig");
    _ = @import("readiness.zig");
    _ = @import("runtime.zig");
    _ = @import("sandbox.zig");
    _ = @import("shard.zig");
    _ = @import("shard_chaos.zig");
    _ = @import("shard_lifecycle.zig");
    _ = @import("shard_set.zig");
    _ = @import("sizing.zig");
    _ = @import("thin_demux.zig");
    _ = @import("worker_flow.zig");
}

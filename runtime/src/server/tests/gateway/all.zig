//! Collects the suites of the server's side of the egress gateway (`server/gateway/`), which
//! `server-gateway-test` runs in the JSC-linked aggregate: the manager against real gateways
//! (their loss, the respawn and the lease it hands out), the lane's lease over a fake control
//! socket, and the gateway spawn. The control client and the control wire are built without the
//! rest of the server from `control_plane.zig`, the root of `server-gateway-control-test`, and the
//! gateway process's own suites are in `egress/tests/gateway/`.

comptime {
    _ = @import("lease.zig");
    _ = @import("manager.zig");
    _ = @import("process.zig");
}

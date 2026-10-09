//! Root of `server-gateway-control-test`: the server's gateway control client
//! (`server/gateway/control_client.zig`) and the control wire it speaks
//! (`egress/gateway/control.zig`), with no engine. The client's own file is
//! the module root, so the binary holds the client and the wire and nothing
//! else of the server (`addGatewayControlSuite` in `runtime/build/tests.zig`).
//! The `test` aggregate runs the same binary. The manager that owns the
//! client, run against a real gateway, is covered in `manager.zig`.

comptime {
    _ = @import("control_wire.zig");
    _ = @import("control_client.zig");
}

//! Collects the HTTP/2 pool tests for the `egress-pool` suite and the egress
//! client aggregate.

comptime {
    _ = @import("readiness.zig");
    _ = @import("integration.zig");
    _ = @import("outgoing.zig");
    _ = @import("lifecycle.zig");
}

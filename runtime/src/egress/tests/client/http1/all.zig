//! Collects the HTTP/1 egress client tests: the wire protocol, request plans
//! and redirects, and exchanges streamed from a local origin over the data
//! driver, on plain and TLS wires.

comptime {
    _ = @import("parser.zig");
    _ = @import("request_plan.zig");
    _ = @import("streaming.zig");
    _ = @import("tls.zig");
}

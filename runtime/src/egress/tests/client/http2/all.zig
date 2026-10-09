//! HTTP/2 codec tests. They need no JSC or network: `egress-fast-test` and
//! `h2-transport-test` run them alone, and the egress client suite imports
//! them for `egress-test`.

comptime {
    _ = @import("session.zig");
    _ = @import("client.zig");
    _ = @import("multiplexing.zig");
}

//! Root of the JSC-free `egress-http1` suite, run in the `egress-fast-test`
//! lane; the aggregate reaches the same tests through client/all.zig.
//! http1/support.zig gets its local-address fixture from the `collo_test_net`
//! module, so this root links without the JSC test graph.

comptime {
    _ = @import("http1/all.zig");
}

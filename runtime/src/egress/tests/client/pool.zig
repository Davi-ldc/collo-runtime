//! Root of the `egress-pool` suite. The pool tests take their local-address
//! fixture from the `collo_test_net` module, so this suite builds and runs
//! without the aggregate test graph.
comptime {
    _ = @import("pool/all.zig");
}

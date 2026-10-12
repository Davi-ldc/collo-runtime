//! The `collo_network` suite: the allow entry grammar, the address classes,
//! the setting rules, the matching of hops against grants and policies, the
//! denial text, and the policy image's builder, checks and decoding. It runs
//! in the `common-test` lane through the common aggregator, and alone,
//! without an engine, in `common-fast-test`.

comptime {
    _ = @import("address.zig");
    _ = @import("grant.zig");
    _ = @import("pattern.zig");
    _ = @import("setting.zig");
    _ = @import("table.zig");
}

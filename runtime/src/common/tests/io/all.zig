//! Collects the tests of `common/io/` for `common-test`: the
//! `collo_common_io` heap and buffer tests in `../io.zig`, its io_uring
//! user_data and restriction tests beside this file, and the tag registry
//! test of the separate `collo_io_uring_tags` module.

comptime {
    _ = @import("../io.zig");
    _ = @import("restricted_uring.zig");
    _ = @import("uring.zig");
    _ = @import("uring_tags.zig");
}

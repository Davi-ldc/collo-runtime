//! Root of the `local-e2e` lane (`addLocalE2e` in `runtime/build/tests.zig`).
//! Zig runs only the tests it reaches from a compilation's root file, so a
//! suite of the lane runs only once it is imported here.
//! `local_server/e2e.zig` states what the lane covers and what it needs from
//! the machine.

comptime {
    _ = @import("local_server/e2e.zig");
}

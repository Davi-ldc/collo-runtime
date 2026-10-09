//! Root of the two bindings smokes, `zig build test-bindings-sanitized` (ASan and LSan) and
//! `zig build test-bindings-valgrind` (Memcheck). Each builds these suites in Debug and links
//! them against a bridge built for the same checker, so a leak or an invalid access on the VM
//! lifecycle and pack mapping paths fails the run. Both use the stock test runner and stay out
//! of `zig build test`; `bindings-test` (`all.zig`) runs every bindings suite, these two included.

const std = @import("std");

comptime {
    _ = std;
    _ = @import("module_pack_mapping.zig");
    _ = @import("vm_lifecycle.zig");
}

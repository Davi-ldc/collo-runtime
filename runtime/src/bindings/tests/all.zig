//! The bindings suites, collected into `runtime/all_tests.zig`: `zig build test` runs them with
//! the rest of the aggregate and `zig build bindings-test` runs them alone. They drive JSC VMs
//! through the `collo_bindings` wrappers and the helpers in
//! `runtime/tests/support/bindings/root.zig`, with the test thread as the VM thread. `smoke.zig`
//! is a separate root, built for the sanitizer and Valgrind lanes.

comptime {
    _ = @import("body_stream_roots.zig");
    _ = @import("microtask_owner.zig");
    _ = @import("module_loader.zig");
    _ = @import("module_pack_mapping.zig");
    _ = @import("realms.zig");
    _ = @import("request_new.zig");
    _ = @import("request_scoped_roots.zig");
    _ = @import("reseed.zig");
    _ = @import("response_extract.zig");
    _ = @import("set_timeout.zig");
    _ = @import("turn_bridge.zig");
    _ = @import("values.zig");
    _ = @import("vm_lifecycle.zig");
    _ = @import("vm_termination.zig");
    _ = @import("webcrypto_request_turn.zig");
}

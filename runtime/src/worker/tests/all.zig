//! The worker module's suites in the JSC-linked aggregate
//! (`runtime/all_tests.zig`), which the `worker-test` lane runs by filtering
//! on `src.worker.tests.`. The JSC-free request transport files are collected
//! by `request/transport.zig` instead and run in `worker-fast-test`.

comptime {
    _ = @import("fs_fault.zig");
    _ = @import("fs_index.zig");
    _ = @import("scheduler.zig");
    _ = @import("sentinel.zig");
    _ = @import("request/all.zig");
    _ = @import("runtime/all.zig");
}

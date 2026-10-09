//! The server's suites in the JSC-linked aggregate (`runtime/all_tests.zig`). Each directory's
//! `all.zig` collects one area of `server/`, and `domain_steps` in `runtime/build/tests.zig` runs
//! each area as a lane by test name prefix; `server-core-test` takes `net/`, `tls/`, `boot/` and
//! `lifecycle.zig` together. The suites in `http2/` are not collected here: they run without JSC
//! in `server-fast-test`, which also runs the analytics, config, routes and supervisor
//! collections a second time without JSC.

comptime {
    _ = @import("lifecycle.zig");
    _ = @import("analytics/all.zig");
    _ = @import("boot/all.zig");
    _ = @import("config/all.zig");
    _ = @import("gateway/all.zig");
    _ = @import("ingress/all.zig");
    _ = @import("net/all.zig");
    _ = @import("routes/all.zig");
    _ = @import("supervisor/all.zig");
    _ = @import("tls/all.zig");
}

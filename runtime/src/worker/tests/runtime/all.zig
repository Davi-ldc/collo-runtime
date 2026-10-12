//! The worker runtime suites of the JSC-linked aggregate, run by
//! `worker-test`. Most drive a `worker.Runtime` on a real VM through the
//! shared harness (`runtime/tests/support/worker/runtime_harness.zig`), with
//! an injected clock and a socket pair standing in for the server.

comptime {
    _ = @import("arbiter.zig");
    _ = @import("body.zig");
    _ = @import("boot_eval.zig");
    _ = @import("console.zig");
    _ = @import("core.zig");
    _ = @import("crypto_pool.zig");
    _ = @import("env.zig");
    _ = @import("fetch.zig");
    _ = @import("lifecycle.zig");
    _ = @import("limits.zig");
    _ = @import("modules.zig");
    _ = @import("multiplexing.zig");
    _ = @import("response.zig");
    _ = @import("response_body_stream.zig");
    _ = @import("routes.zig");
    _ = @import("server_api.zig");
    _ = @import("timeline.zig");
    _ = @import("vm_hooks.zig");
    _ = @import("wasm.zig");
}

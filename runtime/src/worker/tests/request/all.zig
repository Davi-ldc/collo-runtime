//! The request suites of the JSC-linked aggregate, run by `worker-test`.
//! `head.zig`, `incoming_body.zig` and `h2.zig` belong to the JSC-free root
//! `transport.zig` instead; `zig build test` runs both the aggregate and that
//! root, so listing them here too would run them twice.
comptime {
    _ = @import("body_pipe.zig");
    _ = @import("context.zig");
    _ = @import("response.zig");
    _ = @import("task.zig");
}

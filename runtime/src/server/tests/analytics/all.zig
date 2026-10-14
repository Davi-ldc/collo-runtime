//! Collects the suites of the server's analytics module (`server/analytics/`):
//! the sink, console lines, access records with a dispatched request's usage,
//! and the worker line. No engine runs in them: the `server-analytics` suite
//! of `server-fast-test` runs them alone, and `server-analytics-test` runs
//! them in the JSC-linked aggregate. The usage floor a lane reads off a
//! worker's page is covered with the supervisor in
//! `server/tests/supervisor/usage.zig`.

comptime {
    _ = @import("sink.zig");
    _ = @import("logs.zig");
    _ = @import("access.zig");
    _ = @import("workers.zig");
}

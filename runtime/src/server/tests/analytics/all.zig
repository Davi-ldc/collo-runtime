//! Collects the suites of the server's analytics module (`server/analytics/`):
//! the sink, console lines and access records. No engine runs in them: the
//! `server-analytics` suite of `server-fast-test` runs them alone, and
//! `server-analytics-test` runs them in the JSC-linked aggregate. Usage
//! records are covered with the supervisor in `server/tests/supervisor/`.

comptime {
    _ = @import("sink.zig");
    _ = @import("logs.zig");
    _ = @import("access.zig");
}

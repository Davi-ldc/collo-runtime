//! Root of the JSC-free `worker-request-transport` suite, which the
//! `worker-fast-test` and `h2-transport-test` lanes run without a WebKit
//! build. Its entry in `stub_suites` (`runtime/build/tests.zig`) lists the
//! modules these files may import; a file that needs the engine belongs in
//! `all.zig` instead.

comptime {
    _ = @import("head.zig");
    _ = @import("incoming_body.zig");
    _ = @import("h2.zig");
}

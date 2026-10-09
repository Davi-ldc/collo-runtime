//! Collects the HTTP/1 egress client tests: the wire parser, request plans and
//! redirects, the BIO TLS transport, and exchanges streamed from a local
//! origin.

comptime {
    _ = @import("parser.zig");
    _ = @import("request_plan.zig");
    _ = @import("tls_bio.zig");
    _ = @import("streaming.zig");
}

//! Root of the egress client suite, which `egress-test` runs. The task,
//! policy, DNS cache, connect, data-driver, wire and TLS tests sit beside
//! this file; the engine, HTTP/1, HTTP/2 and pool suites sit in their
//! directories.

comptime {
    _ = @import("task.zig");
    _ = @import("policy.zig");
    _ = @import("dns_cache.zig");
    _ = @import("connect.zig");
    _ = @import("data_io.zig");
    _ = @import("wire.zig");
    _ = @import("tls.zig");
    _ = @import("engine/all.zig");
    _ = @import("http1/all.zig");
    _ = @import("http2/all.zig");
    _ = @import("pool/all.zig");
}

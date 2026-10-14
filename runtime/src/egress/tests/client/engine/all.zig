//! The engine tests of the egress client suite (`egress-test`), one file per
//! engine file they cover: `credit_sources.zig` the credit source table,
//! `root.zig` the engine's lifecycle, its queues and task references,
//! `dial.zig` dials, admission and the origin records, `h2.zig` HTTP/2
//! streams and their credits, those kept across a restart included, `h1.zig`
//! HTTP/1 fetches.
//!
//! Apart from `credit_sources.zig`, the tests run a real `Engine`, with its
//! owner thread and its DNS resolver threads, against origins on this host's
//! routable address (`support.zig`, `../http1/support.zig` and the test
//! shim's TLS origins). Each fetch's network policy names the origins it
//! reaches (`../network_policy.zig`). Results are read from the task and its
//! response queue, and settlement is counted from the wakes the engine
//! sends. A test skips when the kernel offers no restricted io_uring.

comptime {
    _ = @import("credit_sources.zig");
    _ = @import("root.zig");
    _ = @import("dial.zig");
    _ = @import("h2.zig");
    _ = @import("h1.zig");
}

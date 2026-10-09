//! Root of the server's worker-supervision tests. `pool.zig` holds one
//! definition's pool on its own, `worker_pool.zig` the pools as the
//! supervisor builds and keeps them, `supervisor.zig` the supervisor's own
//! decisions, `usage.zig` the usage path into `usage.jsonl`, `components.zig`
//! the small parts, `worker_factory.zig` the egress side of a launch,
//! `launcher.zig` the launcher against a stand-in zygote, and `reaper/` the
//! reaper's memory readings, retirements and memory-pressure passes.
//!
//! The aggregate reaches this file through `server/tests/all.zig`, and
//! `server-supervisor-test` runs that slice of it. `runtime/build/tests.zig`
//! also compiles it alone as the `server-supervisor` suite of
//! `server-fast-test`, against stub bindings and only the modules that
//! suite's entry lists. A test here therefore runs no JavaScript and imports
//! nothing beyond those modules and the fixtures every stub suite receives,
//! `supervisor_fixture` among them.

comptime {
    _ = @import("pool.zig");
    _ = @import("worker_pool.zig");
    _ = @import("components.zig");
    _ = @import("supervisor.zig");
    _ = @import("usage.zig");
    _ = @import("worker_factory.zig");
    _ = @import("launcher.zig");
    _ = @import("reaper/memory.zig");
    _ = @import("reaper/reaping.zig");
    _ = @import("reaper/retirement.zig");
}

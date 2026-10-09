//! Collects the suites of the server's network setup (`server/net/`): the
//! lane plan, the listening sockets and the reuseport CPU selector's map.
//! Lane `server-core-test`.

comptime {
    _ = @import("lane_plan.zig");
    _ = @import("listener.zig");
    _ = @import("reuseport_bpf.zig");
}

//! The `collo serve` boot suites (`server/boot/`), run in lane
//! `server-core-test`.

comptime {
    _ = @import("command_line.zig");
    _ = @import("root.zig");
    _ = @import("signals.zig");
    _ = @import("trace_drain.zig");
}

//! The egress gateway: the process that performs every outbound fetch. The server's side of it,
//! which spawns it and talks to it, is `server/gateway/`. Server code reads only the four files
//! both processes compile, `control.zig`, `launch.zig`, `policy.zig` and `sizing.zig`, and never
//! the gateway's loop, shards or engines (`runtime/tests/conventions.zig` checks it).
//!
//! `control.zig` is the wire between the server and the gateway, with the hello that hands over
//! the server's network policy image, and `launch.zig` the gateway's arg0 and inherited
//! descriptor. `policy.zig` holds the limits every fetch runs under and the check of a fetch
//! start, and `sizing.zig` the gateway's plan and the most sessions any gateway holds, which the
//! server reads.
//!
//! Everything else runs only in the gateway. `runtime/` is its boot and event loop on the
//! process's main thread, `readiness.zig` the loop's io_uring wait, and `sandbox.zig` the sandbox
//! the process applies to itself. The loop's state is the worker sessions (`sessions.zig`, each
//! with the ledger of the body-pool extents its worker holds), the one table of fetches
//! (`fetch_table.zig`) and the control packets still to send (`control_queue.zig`);
//! `publisher.zig` writes into worker endpoints, and `credit_batch.zig` merges the flow-control
//! credits on their way back to the engines. Behind the loop, `shard.zig` owns the shards, each
//! with a budgeted allocator (`counting_allocator.zig`, limits in `containment.zig`) and an
//! engine (`engine.zig`) whose threads run the outbound transport and report ready fetches
//! through `ready_scan.zig`.
//!
//! The gateway exits at once when `runtime.run` returns (`runFromInheritedControlFd`): with
//! status 0 when the server shut it down, and with status 1 after one line naming the error for
//! any failure. Nothing after that return tears anything down. What is left is the process's own
//! memory, descriptors and threads, which the kernel releases at exit, and the server waits for
//! the exit on the gateway's pidfd for a bounded time before it sends SIGKILL
//! (`server/gateway/process.zig`), so teardown would only delay it.

const std = @import("std");

pub const containment = @import("containment.zig");
pub const control = @import("control.zig");
pub const control_queue = @import("control_queue.zig");
pub const counting_allocator = @import("counting_allocator.zig");
pub const credit_batch = @import("credit_batch.zig");
pub const engine = @import("engine.zig");
pub const fetch_table = @import("fetch_table.zig");
pub const launch = @import("launch.zig");
pub const policy = @import("policy.zig");
pub const publisher = @import("publisher.zig");
pub const readiness = @import("readiness.zig");
pub const ready_scan = @import("ready_scan.zig");
pub const runtime = @import("runtime/root.zig");
pub const sandbox = @import("sandbox.zig");
pub const sessions = @import("sessions.zig");
pub const shard = @import("shard.zig");
pub const sizing = @import("sizing.zig");

pub const process_name = launch.process_name;
pub const inherited_control_fd = launch.inherited_control_fd;

/// The gateway process's entry point, run from `main` when arg0 is `process_name`. Runs on the
/// descriptor `launch.zig` defines until the server shuts the gateway down, then exits as the
/// header says. The exit is `_exit`, which runs no exit handler, static destructor or error
/// trace: engine threads may still be alive, beside which exit handlers can hang or crash, and a
/// Debug build's error trace parses the binary's whole debug info, which takes seconds.
pub fn runFromInheritedControlFd(allocator: std.mem.Allocator) noreturn {
    serve(allocator) catch |err| {
        std.log.err("egress gateway failed: {s}", .{@errorName(err)});
        std.c._exit(1);
    };
    std.c._exit(0);
}

/// Boots and serves until the server shuts the gateway down. A command line with anything after
/// arg0 fails with `error.InvalidEgressGatewayArguments`, since the server's spawn passes nothing
/// there.
fn serve(allocator: std.mem.Allocator) !void {
    if (std.os.argv.len != 1)
        return error.InvalidEgressGatewayArguments;
    try runtime.run(allocator, launch.inherited_control_fd);
}

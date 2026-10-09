//! The entry point of `sandbox-bench`, the cold-start and memory benchmark of
//! the production server path (`sandbox/README.md`). One binary plays every
//! role, picked by arg0 and then by its one argument. The daemon re-executes
//! this binary as the zygote and as the gateway, so the arg0 names matched
//! here must stay equal to `zygote.process_name` and
//! `gateway.process_name`. `daemon` runs the measured node (`daemon.zig`)
//! inside a trial's cgroup, and `cold`, `memory` or `all` runs the controller
//! (`controller.zig`), which stays outside every measured cgroup.

const std = @import("std");
const controller = @import("sandbox/controller.zig");
const daemon = @import("sandbox/daemon.zig");
const zygote = @import("collo_zygote");
const gateway = @import("collo_egress_gateway");

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    const name = std.fs.path.basename(args[0]);
    if (std.mem.eql(u8, name, "collo-zygote")) {
        try zygote.fork_loop.runFromInheritedFds();
        return;
    }
    if (std.mem.eql(u8, name, "collo-egress-gateway")) {
        try gateway.runFromInheritedControlFd(allocator);
        return;
    }
    if (args.len != 2) {
        std.debug.print("usage: sandbox-bench <cold|memory|all|daemon>\n", .{});
        return error.InvalidArguments;
    }
    if (std.mem.eql(u8, args[1], "daemon")) {
        try daemon.run(allocator);
        return;
    }
    const mode = std.meta.stringToEnum(controller.Mode, args[1]) orelse
        return error.InvalidArguments;
    controller.run(allocator, mode) catch |err| {
        controller.emit(.{
            .schema = "collo.microbench.v1",
            .kind = "failed",
            .error_name = @errorName(err),
        }) catch |write_err| std.debug.print("cannot report failure: {s}\n", .{@errorName(write_err)});
        return err;
    };
}

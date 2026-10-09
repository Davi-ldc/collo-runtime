//! Entrypoint of the `collo` binary. The zygote and the egress gateway are this
//! same executable re-executed under their process names, so arg0 selects those
//! roles first. Any other arg0 reads a command from the first argument: `serve`
//! runs the server boot (`server/boot/root.zig`), and anything else, or no
//! argument at all, prints the usage line to stderr and exits with status 2,
//! the status the boot uses for invalid usage.
//!
//! The root allocator is the process-lifetime allocator that the gateway and
//! the server receive: a `DebugAllocator` in Debug builds and `smp_allocator`
//! otherwise.

const std = @import("std");
const builtin = @import("builtin");
const egress_gateway = @import("collo_egress_gateway");
const zygote = @import("collo_zygote");
const server = @import("collo_server_main");

const boot_mod = server.boot;
const command_line = boot_mod.command_line;

pub fn main() !void {
    if (try boot()) |exit_status|
        std.posix.exit(exit_status);
}

fn boot() !?u8 {
    var root_allocator = RootAllocator{};
    const allocator = root_allocator.allocator();
    defer root_allocator.deinit();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    const arg0 = args.next() orelse "";
    if (isGatewayProcessName(arg0)) {
        try egress_gateway.runFromInheritedControlFd(allocator);
        return null;
    }
    if (isZygoteProcessName(arg0)) {
        try zygote.fork_loop.runFromInheritedFds();
        return null;
    }
    const command = args.next() orelse return try printUsage();
    if (!std.mem.eql(u8, command, "serve"))
        return try printUsage();

    var diagnostic: command_line.Diagnostic = .{};
    const invocation = command_line.parse(&args, &diagnostic) catch |err| switch (err) {
        error.InvalidUsage => return @intFromEnum(boot_mod.invalidUsage(&diagnostic)),
    };
    return @intFromEnum(boot_mod.serve(allocator, invocation));
}

fn printUsage() !u8 {
    try std.fs.File.stderr().writeAll(command_line.usage);
    return @intFromEnum(boot_mod.ExitStatus.invalid);
}

fn isGatewayProcessName(arg0: []const u8) bool {
    return std.mem.eql(u8, std.fs.path.basename(arg0), egress_gateway.process_name);
}

fn isZygoteProcessName(arg0: []const u8) bool {
    return std.mem.eql(u8, std.fs.path.basename(arg0), zygote.process_name);
}

const RootAllocator = struct {
    debug: if (builtin.mode == .Debug) std.heap.DebugAllocator(.{}) else void =
        if (builtin.mode == .Debug) .init else {},

    fn allocator(self: *RootAllocator) std.mem.Allocator {
        return switch (builtin.mode) {
            .Debug => self.debug.allocator(),
            else => std.heap.smp_allocator,
        };
    }

    fn deinit(self: *RootAllocator) void {
        if (builtin.mode == .Debug)
            _ = self.debug.deinit();
    }
};

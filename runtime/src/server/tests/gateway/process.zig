//! The gateway spawn (`server/gateway/process.zig`): an allocation that fails before the spawn
//! fails it with `error.OutOfMemory` before any socket or process exists. Spawning a real gateway,
//! which reads the hello with the compiled policy image the spawn sends after its ready report, is
//! covered in `manager.zig`. Lane: server-gateway.

const std = @import("std");
const gateway = @import("collo_server_gateway");
const CompiledImage = @import("policy_image.zig").CompiledImage;

test "egress gateway process spawn allocation failure does not acquire process resources" {
    var compiled: CompiledImage = undefined;
    try compiled.init(std.testing.allocator);
    defer compiled.deinit(std.testing.allocator);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, gateway.process.spawn(failing.allocator(), .{
        .executable_path = "/tmp/collo-egress-gateway-test-not-executed",
        .key = .{ .bytes = @splat(0x6b) },
        .policy_image = compiled.image(),
    }));
}

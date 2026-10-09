//! The gateway spawn (`server/gateway/process.zig`): an allocation that fails before the spawn
//! fails it with `error.OutOfMemory` before any socket or process exists. Spawning a real gateway,
//! which reads the hello the spawn sends after its ready report, is covered in `manager.zig`.
//! Lane: server-gateway.

const std = @import("std");
const gateway = @import("collo_server_gateway");
const policy = @import("collo_egress_gateway").policy;

test "egress gateway process spawn allocation failure does not acquire process resources" {
    const table = policy.PolicyTable.single(policy.public_https);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, gateway.process.spawn(failing.allocator(), .{
        .executable_path = "/tmp/collo-egress-gateway-test-not-executed",
        .key = .{ .bytes = @splat(0x6b) },
        .table = &table,
    }));
}

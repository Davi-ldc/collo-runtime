//! The ingress lane plan (`server/net/lane_plan.zig`): the lane count against
//! its queue, CPU and memory caps, CPU selection, and the interface a listen
//! address maps to. The interface lookups read this machine's own interface
//! list, so they rely only on `lo` and on documentation addresses no host
//! assigns. Lane `server-core-test`; the lanes running on the plan are covered
//! by `server-ingress-test`.

const std = @import("std");
const lane_plan = @import("collo_server_main").lane_plan;

test "static lane count follows RX queues within CPU and memory caps" {
    try std.testing.expectEqual(@as(usize, 2), try lane_plan.resolveStaticLaneCount(2, 4, 32, 0));
    try std.testing.expectEqual(@as(usize, 4), try lane_plan.resolveStaticLaneCount(8, 4, 32, 0));
    try std.testing.expectEqual(@as(usize, 3), try lane_plan.resolveStaticLaneCount(8, 8, 3, 0));
    try std.testing.expectError(error.NoRxQueues, lane_plan.resolveStaticLaneCount(0, 4, 32, 0));
}

test "a lane's memory shape charges its tables at their limits, so a node with 10 GiB available runs a lane on each of 4 CPUs" {
    const runner = @import("collo_server_main").ingress.runner;
    const available_bytes: usize = 10 * 1024 * 1024 * 1024;
    const cpu_count = 4;
    for ([_]usize{ 1, 16 }) |definition_count| {
        const shape = runner.laneMemoryShape(definition_count);
        const capacity = (available_bytes / lane_plan.lane_memory_share_divisor) / shape.estimatedHeavyLaneBytes();
        try std.testing.expectEqual(@as(usize, cpu_count), try lane_plan.resolveStaticLaneCount(cpu_count, cpu_count, capacity, 0));
    }
    // Each definition adds its workers' registrations and the queue places
    // reserved for them.
    try std.testing.expect(runner.laneMemoryShape(16).resident_cap_bytes > runner.laneMemoryShape(1).resident_cap_bytes);
}

test "explicit lane count override is capped only by allowed CPUs" {
    try std.testing.expectEqual(@as(usize, 6), try lane_plan.resolveStaticLaneCount(2, 8, 32, 6));
    try std.testing.expectEqual(@as(usize, 8), try lane_plan.resolveStaticLaneCount(2, 8, 32, 16));
}

test "lane cpu ids preserve allowed cpu order" {
    const allowed_cpu_ids = [_]usize{ 2, 4, 7, 9 };
    const lane_cpu_ids = try lane_plan.selectLaneCpuIds(
        std.testing.allocator,
        &allowed_cpu_ids,
        3,
    );
    defer std.testing.allocator.free(lane_cpu_ids);

    try std.testing.expectEqualSlices(usize, &.{ 2, 4, 7 }, lane_cpu_ids);
}

test "lane cpu selection rejects impossible lane counts" {
    const allowed_cpu_ids = [_]usize{ 1, 3 };
    try std.testing.expectError(
        error.InvalidLaneCount,
        lane_plan.selectLaneCpuIds(std.testing.allocator, &allowed_cpu_ids, 3),
    );
}

test "loopback interface queues are read from sysfs" {
    const interface = try lane_plan.interfaceQueues(std.testing.allocator, lane_plan.InterfaceName.loopback);
    try std.testing.expectEqualStrings("lo", interface.name.slice());
    try std.testing.expect(interface.rx_queues >= 1);
}

test "queues of an interface that does not exist fail clearly" {
    const missing = try lane_plan.InterfaceName.init("collo-missing");
    try std.testing.expectError(error.FileNotFound, lane_plan.interfaceQueues(std.testing.allocator, missing));
}

test "interface names reject empty, oversized and path-like names" {
    try std.testing.expectError(error.InvalidInterfaceName, lane_plan.InterfaceName.init(""));
    try std.testing.expectError(error.InvalidInterfaceName, lane_plan.InterfaceName.init("a-name-of-sixteen"));
    try std.testing.expectError(error.InvalidInterfaceName, lane_plan.InterfaceName.init("../lo"));
    const longest = try lane_plan.InterfaceName.init("fifteen-bytes-1");
    try std.testing.expectEqualStrings("fifteen-bytes-1", longest.slice());
}

test "every loopback address maps to lo" {
    const addresses = [_]std.net.Address{
        try std.net.Address.parseIp4("127.0.0.1", 8443),
        try std.net.Address.parseIp4("127.1.2.3", 0),
        try std.net.Address.parseIp6("::1", 8443),
        try std.net.Address.parseIp6("::ffff:127.0.0.1", 8443),
    };
    for (addresses) |address| {
        const name = (try lane_plan.interfaceFor(std.testing.allocator, address)) orelse return error.TestExpectedInterface;
        try std.testing.expectEqualStrings("lo", name.slice());
    }
}

test "the unspecified address maps to no single interface" {
    const addresses = [_]std.net.Address{
        try std.net.Address.parseIp4("0.0.0.0", 8443),
        try std.net.Address.parseIp6("::", 8443),
        try std.net.Address.parseIp6("::ffff:0.0.0.0", 8443),
    };
    for (addresses) |address|
        try std.testing.expect((try lane_plan.interfaceFor(std.testing.allocator, address)) == null);
}

test "an address no interface holds maps to no single interface" {
    // 192.0.2.0/24 and 2001:db8::/32 are reserved for documentation.
    const addresses = [_]std.net.Address{
        try std.net.Address.parseIp4("192.0.2.1", 8443),
        try std.net.Address.parseIp6("2001:db8::1", 8443),
    };
    for (addresses) |address|
        try std.testing.expect((try lane_plan.interfaceFor(std.testing.allocator, address)) == null);
}

test "a loopback plan names lo and targets the schedulable CPUs, not lo's one queue" {
    const shape = testShape();
    var plan = try lane_plan.build(std.testing.allocator, try std.net.Address.parseIp4("127.0.0.1", 0), shape, 0);
    defer plan.deinit(std.testing.allocator);
    const interface = plan.interface orelse return error.TestExpectedInterface;
    try std.testing.expectEqualStrings("lo", interface.name.slice());
    // `testShape` keeps the memory cap above the CPU count.
    try std.testing.expectEqual(plan.allowed_cpu_count, plan.lane_count);
    try std.testing.expectEqualSlices(usize, plan.allowed_cpu_ids[0..plan.lane_count], plan.lane_cpu_ids);
}

test "the queue target follows an interface's receive queues, except lo's" {
    const eth = try lane_plan.InterfaceName.init("eth0");
    try std.testing.expectEqual(@as(usize, 4), lane_plan.queueTarget(.{ .name = eth, .rx_queues = 4, .tx_queues = 4 }, 8));
    try std.testing.expectEqual(@as(usize, 8), lane_plan.queueTarget(.{ .name = lane_plan.InterfaceName.loopback, .rx_queues = 1, .tx_queues = 1 }, 8));
    try std.testing.expectEqual(@as(usize, 8), lane_plan.queueTarget(null, 8));
}

test "an unspecified-address plan targets the schedulable CPUs" {
    const shape = testShape();
    var plan = try lane_plan.build(std.testing.allocator, try std.net.Address.parseIp4("0.0.0.0", 0), shape, 0);
    defer plan.deinit(std.testing.allocator);
    try std.testing.expect(plan.interface == null);
    try std.testing.expect(plan.lane_count >= 1);
    try std.testing.expect(plan.lane_count <= plan.allowed_cpu_count);
    try std.testing.expectEqualSlices(usize, plan.allowed_cpu_ids[0..plan.lane_count], plan.lane_cpu_ids);
}

/// A footprint small enough that the memory cap never binds below the CPU
/// count on a test machine.
fn testShape() lane_plan.MemoryShape {
    return .{ .resident_cap_bytes = 1 };
}

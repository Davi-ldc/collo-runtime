//! The ring of ready task tokens a shard engine fills for the gateway's loop
//! (`egress/gateway/ready_scan.zig`): an enqueue asks for a wake only when it takes the ring or the
//! scan bit from empty to set, a token without a handle and a token that finds the ring full set
//! the scan bit instead of being dropped, a drain moves tokens in order and says whether any are
//! left, and a clear drops everything. The tokens name a task the scan never reads, so the tests
//! hand it the address of a task they never initialize. How the collection pass resolves a token
//! to its record is covered in `shard_flow.zig`. Lane: egress-gateway-test.

const std = @import("std");
const gateway = @import("collo_egress_gateway");

const ready_scan = gateway.ready_scan;
const Task = @import("collo_egress_client").task.Task;

fn tokenFor(task: *Task, handle: u64) Task.ReadyToken {
    return .{ .task = task, .generation = handle };
}

test "an enqueue asks for a wake only when it takes the ring from empty to non-empty" {
    const task = try std.testing.allocator.create(Task);
    defer std.testing.allocator.destroy(task);
    var scan = try ready_scan.Scan.init(std.testing.allocator, 4);
    defer scan.deinit(std.testing.allocator);

    try std.testing.expect(scan.enqueueTask(tokenFor(task, 1)));
    // A second token finds a wake already owed.
    try std.testing.expect(!scan.enqueueTask(tokenFor(task, 2)));

    var out: [4]ready_scan.Event = undefined;
    const drained = scan.drain(&out);
    try std.testing.expectEqual(@as(usize, 2), drained.len);
    try std.testing.expect(!drained.scan_required);
    try std.testing.expect(!drained.has_more);
    // The drain emptied the ring, so the next token asks again.
    try std.testing.expect(scan.enqueueTask(tokenFor(task, 3)));
}

test "a token without a handle and a token that finds the ring full set the scan bit, which asks for one wake" {
    const task = try std.testing.allocator.create(Task);
    defer std.testing.allocator.destroy(task);
    var scan = try ready_scan.Scan.init(std.testing.allocator, 2);
    defer scan.deinit(std.testing.allocator);

    // A task outside the fetch table carries handle 0, which asks for a look at every fetch.
    try std.testing.expect(scan.enqueueTask(tokenFor(task, 0)));
    try std.testing.expect(!scan.enqueueTask(tokenFor(task, 0)));
    var out: [4]ready_scan.Event = undefined;
    var drained = scan.drain(&out);
    try std.testing.expectEqual(@as(usize, 0), drained.len);
    try std.testing.expect(drained.scan_required);

    try std.testing.expect(scan.enqueueTask(tokenFor(task, 1)));
    try std.testing.expect(!scan.enqueueTask(tokenFor(task, 2)));
    // The ring is full: the token sets the scan bit, which was clear, so it asks for a wake.
    try std.testing.expect(scan.enqueueTask(tokenFor(task, 3)));
    try std.testing.expect(!scan.enqueueTask(tokenFor(task, 4)));
    drained = scan.drain(&out);
    try std.testing.expectEqual(@as(usize, 2), drained.len);
    try std.testing.expectEqual(@as(u64, 1), out[0].handle);
    try std.testing.expectEqual(@as(u64, 2), out[1].handle);
    try std.testing.expect(drained.scan_required);
    try std.testing.expect(!drained.has_more);
}

test "a drain moves tokens in order, at most as many as fit, and says whether any are left" {
    const task = try std.testing.allocator.create(Task);
    defer std.testing.allocator.destroy(task);
    var scan = try ready_scan.Scan.init(std.testing.allocator, 4);
    defer scan.deinit(std.testing.allocator);

    for (1..4) |handle|
        _ = scan.enqueueTask(tokenFor(task, handle));
    var small: [2]ready_scan.Event = undefined;
    var drained = scan.drain(&small);
    try std.testing.expectEqual(@as(usize, 2), drained.len);
    try std.testing.expect(drained.has_more);
    try std.testing.expectEqual(@as(u64, 1), small[0].handle);
    try std.testing.expectEqual(@as(u64, 2), small[1].handle);
    try std.testing.expectEqual(task, small[0].task);

    // Tokens queued after a partial drain wrap around the ring and keep their order.
    for (4..7) |handle|
        _ = scan.enqueueTask(tokenFor(task, handle));
    var large: [8]ready_scan.Event = undefined;
    drained = scan.drain(&large);
    try std.testing.expectEqual(@as(usize, 4), drained.len);
    try std.testing.expect(!drained.has_more);
    for (large[0..drained.len], 3..) |event, handle|
        try std.testing.expectEqual(@as(u64, handle), event.handle);
}

test "the scan bit asks for a wake once until a drain takes it" {
    var scan = try ready_scan.Scan.init(std.testing.allocator, 1);
    defer scan.deinit(std.testing.allocator);

    try std.testing.expect(scan.requestScan());
    try std.testing.expect(!scan.requestScan());
    var out: [1]ready_scan.Event = undefined;
    try std.testing.expect(scan.drain(&out).scan_required);
    try std.testing.expect(!scan.drain(&out).scan_required);
    try std.testing.expect(scan.requestScan());
}

test "a clear drops every token and the scan bit" {
    const task = try std.testing.allocator.create(Task);
    defer std.testing.allocator.destroy(task);
    var scan = try ready_scan.Scan.init(std.testing.allocator, 4);
    defer scan.deinit(std.testing.allocator);

    _ = scan.enqueueTask(tokenFor(task, 1));
    _ = scan.enqueueTask(tokenFor(task, 2));
    _ = scan.requestScan();
    scan.clear();
    var out: [4]ready_scan.Event = undefined;
    const drained = scan.drain(&out);
    try std.testing.expectEqual(@as(usize, 0), drained.len);
    try std.testing.expect(!drained.scan_required);
    try std.testing.expect(!drained.has_more);
    try std.testing.expect(scan.enqueueTask(tokenFor(task, 3)));
}

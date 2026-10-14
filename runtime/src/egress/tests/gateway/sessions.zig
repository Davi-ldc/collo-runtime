//! The gateway's session records and their registry (`egress/gateway/sessions.zig`): session ids
//! that start at 1 and never come back within one gateway, an attach that fails for memory and
//! leaves the registry as it was, the index map after the swap a removal makes, marking for drop
//! without an allocation, and the extent ledger that returns each released extent's shard, engine
//! run and credit, refuses a release it never recorded, and holds entries only while an extent is
//! outstanding. Attaching through the control socket and removing sessions from the loop are
//! covered in `control_flow.zig` and `session_flow.zig`. Lane: egress-gateway-test.

const std = @import("std");
const gateway = @import("collo_egress_gateway");
const ipc = @import("collo_ipc");

const support = @import("support/gateway.zig");

const body_credit = @import("collo_egress_client").core.body_credit;
const policy = gateway.policy;
const sessions = gateway.sessions;

const cell: policy.SecurityCellId = @splat(3);

/// The gateway's view of a fresh session, which the caller owns.
fn gatewayEndpoint() !ipc.egress_shared.Endpoint {
    var fds = try support.createSession();
    defer fds.deinit();
    var gateway_raw = try support.dupEgressRawFds(fds.rawForGateway());
    return ipc.egress_shared.mapEndpointTakeForGateway(&gateway_raw);
}

/// A body-pool handle of slot `index` in its `generation`, as the pool encodes one.
fn handleFor(index: u32, generation: u32) ipc.egress_shared.BodyPoolHandle {
    return (@as(u64, generation) << 32) | (@as(u64, index) + 1);
}

fn released(handle: ipc.egress_shared.BodyPoolHandle, len: u32) ipc.egress_shared.BodyPoolView.ReleasedExtent {
    return .{ .handle = handle, .len = len, .block_index = 0, .block_count = 1 };
}

test "sessions get ids from 1 that never come back, and a removal keeps every index right" {
    var registry: sessions.Registry = .{};
    defer registry.deinit(std.testing.allocator);

    var ids: [3]u64 = undefined;
    for (&ids, 0..) |*id, index| {
        var endpoint = try gatewayEndpoint();
        const attached = registry.attach(std.testing.allocator, &endpoint, cell) catch |err| {
            endpoint.deinit();
            return err;
        };
        try std.testing.expectEqual(index, attached.index);
        id.* = attached.session_id;
    }
    try std.testing.expectEqualSlices(u64, &.{ 1, 2, 3 }, &ids);

    // Removing the first moves the last into its slot, and the index map follows it.
    var removed = registry.removeAt(0);
    try std.testing.expectEqual(@as(u64, 1), removed.id);
    removed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), registry.len());
    try std.testing.expect(registry.byId(1) == null);
    try std.testing.expectEqual(@as(usize, 0), registry.indexOf(3).?);
    try std.testing.expectEqual(@as(usize, 1), registry.indexOf(2).?);
    try std.testing.expectEqual(@as(u64, 3), registry.byIndex(0).id);
    try std.testing.expectEqual(@as(u64, 3), registry.byId(3).?.id);

    // The next attach takes a new id, never the removed one.
    var endpoint = try gatewayEndpoint();
    const attached = registry.attach(std.testing.allocator, &endpoint, cell) catch |err| {
        endpoint.deinit();
        return err;
    };
    try std.testing.expectEqual(@as(u64, 4), attached.session_id);
    try std.testing.expectEqual(@as(usize, 2), attached.index);
    try std.testing.expectEqual(cell, registry.byId(4).?.security_cell_id);
}

test "an attach that fails for memory leaves the registry as it was and the endpoint with the caller" {
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const allocator = failing.allocator();
        var registry: sessions.Registry = .{};
        var endpoint = try gatewayEndpoint();
        const attached = registry.attach(allocator, &endpoint, cell) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(@as(usize, 0), registry.len());
            try std.testing.expectEqual(@as(u32, 0), registry.index_by_id.count());
            // No id was spent on the refused attach.
            try std.testing.expectEqual(@as(u64, 1), registry.next_session_id);
            // The caller still owns a whole endpoint.
            endpoint.deinit();
            registry.deinit(allocator);
            continue;
        };
        try std.testing.expectEqual(@as(u64, 1), attached.session_id);
        registry.deinit(allocator);
        if (!failing.has_induced_failure)
            break;
    }
}

test "marking a session for drop is idempotent, and each marked session is found and counted off once removed" {
    var registry: sessions.Registry = .{};
    defer registry.deinit(std.testing.allocator);
    for (0..3) |_| {
        var endpoint = try gatewayEndpoint();
        _ = registry.attach(std.testing.allocator, &endpoint, cell) catch |err| {
            endpoint.deinit();
            return err;
        };
    }
    try std.testing.expect(registry.nextDrop() == null);

    registry.markForDrop(registry.byId(2).?);
    registry.markForDrop(registry.byId(2).?);
    registry.markForDrop(registry.byId(3).?);
    try std.testing.expectEqual(@as(usize, 2), registry.drops_pending);

    var dropped: [2]u64 = undefined;
    for (&dropped) |*id| {
        const index = registry.nextDrop().?;
        try std.testing.expect(registry.byIndex(index).drop_pending);
        var removed = registry.removeAt(index);
        id.* = removed.id;
        removed.deinit(std.testing.allocator);
    }
    std.mem.sort(u64, &dropped, {}, std.sort.asc(u64));
    try std.testing.expectEqualSlices(u64, &.{ 2, 3 }, &dropped);
    try std.testing.expectEqual(@as(usize, 0), registry.drops_pending);
    try std.testing.expect(registry.nextDrop() == null);
    try std.testing.expect(!registry.byId(1).?.drop_pending);
}

test "removing a marked session other than the one nextDrop names lowers the pending drops" {
    var registry: sessions.Registry = .{};
    defer registry.deinit(std.testing.allocator);
    for (0..2) |_| {
        var endpoint = try gatewayEndpoint();
        _ = registry.attach(std.testing.allocator, &endpoint, cell) catch |err| {
            endpoint.deinit();
            return err;
        };
    }
    registry.markForDrop(registry.byId(1).?);
    registry.markForDrop(registry.byId(2).?);
    var removed = registry.removeAt(registry.indexOf(2).?);
    removed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), registry.drops_pending);
    try std.testing.expectEqual(@as(u64, 1), registry.byIndex(registry.nextDrop().?).id);
}

test "a recorded extent comes back with its shard, engine run and credit, and the entries go with the last one" {
    var ledger: sessions.ExtentLedger = .{};
    defer ledger.deinit(std.testing.allocator);

    try ledger.reserve(std.testing.allocator);
    const first = handleFor(4, 9);
    const second = handleFor(5, 2);
    ledger.record(first, 100, 1, 3, body_credit.h2Data(7, 3, 100, true));
    ledger.record(second, 16, 2, 5, body_credit.h1Resume(8));
    try std.testing.expectEqual(@as(u32, 2), ledger.outstanding);

    const taken_first = ledger.take(std.testing.allocator, released(first, 100)).?;
    try std.testing.expectEqual(@as(u32, 1), taken_first.shard_index);
    try std.testing.expectEqual(@as(gateway.engine.Run, 3), taken_first.run);
    switch (taken_first.credit) {
        .h2_data => |credit| {
            try std.testing.expectEqual(@as(u64, 7), credit.source_id);
            try std.testing.expectEqual(@as(u32, 3), credit.stream_id);
            try std.testing.expectEqual(@as(usize, 100), credit.encoded_bytes);
        },
        else => return error.TestUnexpectedCredit,
    }
    try std.testing.expect(ledger.entries != null);
    // A slot's entry is taken once: a second release of the same extent finds nothing.
    try std.testing.expect(ledger.take(std.testing.allocator, released(first, 100)) == null);

    const taken_second = ledger.take(std.testing.allocator, released(second, 16)).?;
    try std.testing.expectEqual(@as(u32, 2), taken_second.shard_index);
    try std.testing.expectEqual(@as(gateway.engine.Run, 5), taken_second.run);
    try std.testing.expect(taken_second.credit == .h1_resume);
    // With nothing outstanding the session holds no entries.
    try std.testing.expectEqual(@as(u32, 0), ledger.outstanding);
    try std.testing.expect(ledger.entries == null);

    // The next publication allocates them again.
    try ledger.reserve(std.testing.allocator);
    try std.testing.expect(ledger.entries != null);
    ledger.record(first, 1, 0, 1, .none);
    try std.testing.expect(ledger.take(std.testing.allocator, released(first, 1)) != null);
    try std.testing.expect(ledger.entries == null);
}

test "a release of an extent never recorded, of an old generation or of another length finds nothing" {
    var ledger: sessions.ExtentLedger = .{};
    defer ledger.deinit(std.testing.allocator);

    // An idle session holds no entries, so any release misses.
    try std.testing.expect(ledger.take(std.testing.allocator, released(handleFor(0, 1), 1)) == null);

    try ledger.reserve(std.testing.allocator);
    const handle = handleFor(6, 4);
    ledger.record(handle, 32, 0, 1, body_credit.h1Resume(1));

    try std.testing.expect(ledger.take(std.testing.allocator, released(handleFor(7, 4), 32)) == null);
    try std.testing.expect(ledger.take(std.testing.allocator, released(handleFor(6, 3), 32)) == null);
    try std.testing.expect(ledger.take(std.testing.allocator, released(handleFor(6, 5), 32)) == null);
    try std.testing.expect(ledger.take(std.testing.allocator, released(handle, 31)) == null);
    // A malformed handle misses too.
    try std.testing.expect(ledger.take(std.testing.allocator, released(0, 32)) == null);

    // The misses left the entry in place.
    try std.testing.expectEqual(@as(u32, 1), ledger.outstanding);
    try std.testing.expect(ledger.take(std.testing.allocator, released(handle, 32)) != null);
}

test "a ledger freed while extents are outstanding frees its entries" {
    var ledger: sessions.ExtentLedger = .{};
    try ledger.reserve(std.testing.allocator);
    // A second reserve keeps the entries it has.
    try ledger.reserve(std.testing.allocator);
    ledger.record(handleFor(1, 1), 8, 0, 1, .none);
    ledger.record(handleFor(2, 1), 8, 0, 1, .none);
    ledger.deinit(std.testing.allocator);
}

test "a ledger whose first reserve fails for memory holds no entries and records nothing" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var ledger: sessions.ExtentLedger = .{};
    try std.testing.expectError(error.OutOfMemory, ledger.reserve(failing.allocator()));
    try std.testing.expect(ledger.entries == null);
    try std.testing.expectEqual(@as(u32, 0), ledger.outstanding);
    ledger.deinit(failing.allocator());
}

//! The gateway's fetch table (`egress/gateway/fetch_table.zig`): records found by their session
//! and fetch id and resolved by their handles, handles that never repeat for a freed slot and are
//! never 0, ids that mean nothing outside their session, the per-session lists the session records
//! hold, the per-cell counts admission caps, slot reuse, and an insert that fails for memory
//! changing nothing. How records begin and end inside the loop is covered in `fetch_flow.zig`.
//! Lane: egress-gateway-test.

const std = @import("std");
const gateway = @import("collo_egress_gateway");

const fetch_table = gateway.fetch_table;
const policy = gateway.policy;

const cell_a: policy.SecurityCellId = @splat(1);
const cell_b: policy.SecurityCellId = @splat(2);

fn fetchOf(session_id: u64, fetch_id: u64) fetch_table.Fetch {
    return .{
        .session_id = session_id,
        .fetch_id = fetch_id,
        .body_id = fetch_id + 1000,
        .shard_index = 0,
        .upload_bytes = 0,
        .stage = .admitting,
    };
}

fn slotIndex(handle: fetch_table.Handle) u32 {
    return @truncate(handle);
}

/// The fetch ids of `list` from its head, with each record's back link checked against the one
/// before it.
fn expectList(table: *fetch_table.Table, list: fetch_table.List, expected: []const u64) !void {
    try std.testing.expectEqual(@as(u32, @intCast(expected.len)), list.len);
    var cursor = list.first;
    var previous: fetch_table.Index = fetch_table.null_index;
    for (expected) |fetch_id| {
        try std.testing.expect(cursor != fetch_table.null_index);
        const record = table.at(cursor);
        try std.testing.expectEqual(fetch_id, record.fetch_id);
        try std.testing.expectEqual(previous, record.prev);
        previous = cursor;
        cursor = record.next;
    }
    try std.testing.expectEqual(fetch_table.null_index, cursor);
}

test "a record is found by its session and fetch id and resolves by its handle until it is removed" {
    var table: fetch_table.Table = .{};
    defer table.deinit(std.testing.allocator);
    var list: fetch_table.List = .{};

    const handle = try table.insert(std.testing.allocator, &list, cell_a, fetchOf(1, 5));
    try std.testing.expectEqual(@as(usize, 1), table.count());
    try std.testing.expect(table.contains(1, 5));
    try std.testing.expectEqual(handle, table.find(1, 5).?);
    const record = table.get(handle).?;
    try std.testing.expectEqual(@as(u64, 1), record.session_id);
    try std.testing.expectEqual(@as(u64, 5), record.fetch_id);
    try std.testing.expectEqual(@as(u64, 1005), record.body_id);

    const removed = table.remove(&list, cell_a, handle);
    try std.testing.expectEqual(@as(u64, 5), removed.fetch_id);
    try std.testing.expectEqual(@as(usize, 0), table.count());
    try std.testing.expect(!table.contains(1, 5));
    try std.testing.expect(table.find(1, 5) == null);
    try std.testing.expect(table.get(handle) == null);
    try expectList(&table, list, &.{});
}

test "a freed slot gets a new handle when it is reused, and the old handle resolves to nothing" {
    var table: fetch_table.Table = .{};
    defer table.deinit(std.testing.allocator);
    var list: fetch_table.List = .{};

    const first = try table.insert(std.testing.allocator, &list, cell_a, fetchOf(1, 5));
    _ = table.remove(&list, cell_a, first);
    const second = try table.insert(std.testing.allocator, &list, cell_a, fetchOf(1, 6));
    // The slot is reused, and the generation moved on, so the two handles differ.
    try std.testing.expectEqual(@as(usize, 1), table.slotCount());
    try std.testing.expectEqual(slotIndex(first), slotIndex(second));
    try std.testing.expect(first != second);
    try std.testing.expect(table.get(first) == null);
    try std.testing.expectEqual(@as(u64, 6), table.get(second).?.fetch_id);
    // The same fetch id again also gets a handle of its own: a wake token kept from the first
    // record never resolves to the second.
    _ = table.remove(&list, cell_a, second);
    const third = try table.insert(std.testing.allocator, &list, cell_a, fetchOf(1, 5));
    try std.testing.expect(third != first);
    try std.testing.expect(table.get(first) == null);
    _ = table.remove(&list, cell_a, third);
}

test "handles are never 0, slot 0 included" {
    try std.testing.expect(fetch_table.handleOf(0, 1) != 0);
    try std.testing.expect(fetch_table.handleOf(0, std.math.maxInt(u32)) != 0);

    var table: fetch_table.Table = .{};
    defer table.deinit(std.testing.allocator);
    var list: fetch_table.List = .{};
    // Many generations of slot 0 each give a nonzero handle that the next one replaces.
    var previous: fetch_table.Handle = 0;
    for (0..64) |round| {
        const handle = try table.insert(std.testing.allocator, &list, cell_a, fetchOf(1, round + 1));
        try std.testing.expectEqual(@as(u32, 0), slotIndex(handle));
        try std.testing.expect(handle != 0);
        try std.testing.expect(handle != previous);
        previous = handle;
        _ = table.remove(&list, cell_a, handle);
    }
}

test "a fetch id of one session never resolves in another session" {
    var table: fetch_table.Table = .{};
    defer table.deinit(std.testing.allocator);
    var list_a: fetch_table.List = .{};
    var list_b: fetch_table.List = .{};

    const handle_a = try table.insert(std.testing.allocator, &list_a, cell_a, fetchOf(1, 5));
    // Session 2 holds no fetch 5, whatever session 1 holds.
    try std.testing.expect(!table.contains(2, 5));
    try std.testing.expect(table.find(2, 5) == null);

    // Both sessions may use the same id; each resolves to its own record.
    const handle_b = try table.insert(std.testing.allocator, &list_b, cell_a, fetchOf(2, 5));
    try std.testing.expect(handle_a != handle_b);
    try std.testing.expectEqual(handle_a, table.find(1, 5).?);
    try std.testing.expectEqual(handle_b, table.find(2, 5).?);
    try std.testing.expectEqual(@as(u64, 1), table.get(handle_a).?.session_id);
    try std.testing.expectEqual(@as(u64, 2), table.get(handle_b).?.session_id);
    try expectList(&table, list_a, &.{5});
    try expectList(&table, list_b, &.{5});

    // Removing one session's record leaves the other's in place.
    _ = table.remove(&list_a, cell_a, handle_a);
    try std.testing.expect(table.find(1, 5) == null);
    try std.testing.expectEqual(handle_b, table.find(2, 5).?);
    try expectList(&table, list_b, &.{5});
    _ = table.remove(&list_b, cell_a, handle_b);
}

test "a session's list stays linked through removals from its head, middle and tail" {
    var table: fetch_table.Table = .{};
    defer table.deinit(std.testing.allocator);
    var list: fetch_table.List = .{};

    var handles: [5]fetch_table.Handle = undefined;
    for (&handles, 1..) |*handle, fetch_id|
        handle.* = try table.insert(std.testing.allocator, &list, cell_a, fetchOf(1, fetch_id));
    // Inserts link at the head.
    try expectList(&table, list, &.{ 5, 4, 3, 2, 1 });

    _ = table.remove(&list, cell_a, handles[4]);
    try expectList(&table, list, &.{ 4, 3, 2, 1 });
    _ = table.remove(&list, cell_a, handles[2]);
    try expectList(&table, list, &.{ 4, 2, 1 });
    _ = table.remove(&list, cell_a, handles[0]);
    try expectList(&table, list, &.{ 4, 2 });
    _ = table.remove(&list, cell_a, handles[3]);
    try expectList(&table, list, &.{2});
    _ = table.remove(&list, cell_a, handles[1]);
    try expectList(&table, list, &.{});
}

test "a cell's count rises with each record and its entry goes with the last" {
    var table: fetch_table.Table = .{};
    defer table.deinit(std.testing.allocator);
    var list_a: fetch_table.List = .{};
    var list_b: fetch_table.List = .{};

    const first = try table.insert(std.testing.allocator, &list_a, cell_a, fetchOf(1, 1));
    const second = try table.insert(std.testing.allocator, &list_b, cell_a, fetchOf(2, 1));
    const other = try table.insert(std.testing.allocator, &list_b, cell_b, fetchOf(2, 2));
    try std.testing.expectEqual(@as(u32, 2), table.cellCount(cell_a));
    try std.testing.expectEqual(@as(u32, 1), table.cellCount(cell_b));

    _ = table.remove(&list_a, cell_a, first);
    try std.testing.expectEqual(@as(u32, 1), table.cellCount(cell_a));
    _ = table.remove(&list_b, cell_a, second);
    try std.testing.expectEqual(@as(u32, 0), table.cellCount(cell_a));
    try std.testing.expect(!table.cells.contains(cell_a));
    try std.testing.expectEqual(@as(u32, 1), table.cellCount(cell_b));
    _ = table.remove(&list_b, cell_b, other);
    try std.testing.expectEqual(@as(usize, 0), table.cells.count());
}

test "a freed slot is reused before the table grows, and a walk of the slots skips it" {
    var table: fetch_table.Table = .{};
    defer table.deinit(std.testing.allocator);
    var list: fetch_table.List = .{};

    const first = try table.insert(std.testing.allocator, &list, cell_a, fetchOf(1, 1));
    const middle = try table.insert(std.testing.allocator, &list, cell_a, fetchOf(1, 2));
    const last = try table.insert(std.testing.allocator, &list, cell_a, fetchOf(1, 3));
    try std.testing.expectEqual(@as(usize, 3), table.slotCount());

    _ = table.remove(&list, cell_a, middle);
    var live: usize = 0;
    for (0..table.slotCount()) |index| {
        if (table.liveAt(index)) |record| {
            try std.testing.expect(record.fetch_id != 2);
            try std.testing.expectEqual(table.find(1, record.fetch_id).?, table.handleAt(@intCast(index)));
            live += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), live);

    const reused = try table.insert(std.testing.allocator, &list, cell_a, fetchOf(1, 4));
    try std.testing.expectEqual(@as(usize, 3), table.slotCount());
    try std.testing.expectEqual(slotIndex(middle), slotIndex(reused));

    _ = table.remove(&list, cell_a, first);
    _ = table.remove(&list, cell_a, last);
    _ = table.remove(&list, cell_a, reused);
}

test "an insert that fails for memory leaves the table, the list and the cell count as they were" {
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const allocator = failing.allocator();
        var table: fetch_table.Table = .{};
        var list: fetch_table.List = .{};

        const first = table.insert(allocator, &list, cell_a, fetchOf(1, 1)) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(@as(usize, 0), table.count());
            try std.testing.expectEqual(@as(u32, 0), list.len);
            try std.testing.expectEqual(fetch_table.null_index, list.first);
            try std.testing.expectEqual(@as(u32, 0), table.cellCount(cell_a));
            table.deinit(allocator);
            continue;
        };
        const second = table.insert(allocator, &list, cell_b, fetchOf(1, 2)) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(@as(usize, 1), table.count());
            try expectList(&table, list, &.{1});
            try std.testing.expectEqual(@as(u32, 1), table.cellCount(cell_a));
            try std.testing.expectEqual(@as(u32, 0), table.cellCount(cell_b));
            try std.testing.expect(table.find(1, 2) == null);
            _ = table.remove(&list, cell_a, first);
            table.deinit(allocator);
            continue;
        };
        try expectList(&table, list, &.{ 2, 1 });
        _ = table.remove(&list, cell_a, first);
        _ = table.remove(&list, cell_b, second);
        table.deinit(allocator);
        if (!failing.has_induced_failure)
            break;
    }
}

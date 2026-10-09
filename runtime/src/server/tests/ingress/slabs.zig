//! The fault-in slab every per-lane table is built on (`ingress/slab.zig`): a
//! fresh slab touches none of its pages, a started lane holds no page of its
//! tables until it serves, and one accept and one admission make only their
//! entries' pages resident; a fault-in mapping, the access ring's included,
//! refuses transparent huge pages; released entries come back last in first
//! out before the high-water mark grows; a key looks up live, vacant once its
//! entry is released and stale once the entry is handed out again; and a
//! FIFO place keeps its membership across the release and reuse of its
//! entry. Lane `server-ingress-test`.

const std = @import("std");
const analytics = @import("collo_server_analytics");
const server_main = @import("collo_server_main");
const supervision = @import("collo_server_supervisor");
const lane_harness = @import("lane_harness.zig");

const ingress = server_main.ingress;
const lifecycle = server_main.lifecycle;
const slab = ingress.slab;

const SmallEntry = struct {
    slab_link: slab.Link = .{},
    value: u64 = 0,
};
const SmallSlab = slab.FaultInSlab(SmallEntry);

/// The resident pages of the mapping that holds `entries`, which starts on
/// a page boundary, as `mincore(2)` reports them.
fn residentPages(entries: anytype) !usize {
    const bytes = std.mem.sliceAsBytes(entries);
    if (bytes.len == 0)
        return 0;
    const page = std.heap.pageSize();
    const len = std.mem.alignForward(usize, bytes.len, page);
    const vector = try std.testing.allocator.alloc(u8, len / page);
    defer std.testing.allocator.free(vector);
    const start: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(bytes.ptr));
    try std.posix.mincore(start, len, vector.ptr);
    var count: usize = 0;
    for (vector) |state| {
        if (state & 1 != 0)
            count += 1;
    }
    return count;
}

test "a fresh slab touches none of its pages, and one in use only the pages of the entries it handed out" {
    var table = try SmallSlab.init(1 << 16);
    defer table.deinit();
    try std.testing.expectEqual(@as(usize, 0), try residentPages(table.entries));

    const handed_out: usize = 100;
    for (0..handed_out) |_|
        _ = table.acquire() orelse return error.SlabFullTooSoon;
    const resident = try residentPages(table.entries);
    try std.testing.expect(resident >= 1);
    try std.testing.expect(resident <= handed_out * @sizeOf(SmallEntry) / std.heap.pageSize() + 1);
}

test "a started lane holds no page of its tables, its read buffer or its scratch until it serves" {
    var harness: lane_harness.Harness = undefined;
    try harness.init(std.testing.allocator, .{});
    defer harness.deinit();
    const lane = harness.lane(0);

    try std.testing.expectEqual(@as(usize, 0), try residentPages(lane.connections.entries));
    try std.testing.expectEqual(@as(usize, 0), try residentPages(lane.requests.entries));
    try std.testing.expectEqual(@as(usize, 0), try residentPages(lane.registrations.entries));
    try std.testing.expectEqual(@as(usize, 0), try residentPages(lane.h2_lane.mapping));
    try std.testing.expectEqual(@as(usize, 0), try residentPages(lane.h2_lane.streams.entries));
    try std.testing.expectEqual(@as(usize, 0), try residentPages(lane.lane.deadline_wheel.entries.entries));
    try std.testing.expectEqual(@as(usize, 0), try residentPages(lane.lane.command_queue.nodes.entries));
    try std.testing.expectEqual(@as(usize, 0), try residentPages(lane.access_ring.slots));
}

test "one accept and one admission make resident only the pages of the entries they took" {
    var fixture: lane_harness.OneWorker = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    _ = try fixture.get(1);
    const lane = fixture.harness.lane(0);

    try std.testing.expectEqual(@as(u32, 1), lane.connections.high_water);
    try std.testing.expectEqual(@as(u32, 1), lane.requests.high_water);
    try std.testing.expectEqual(@as(u32, 1), lane.h2_lane.streams.high_water);
    try std.testing.expectEqual(@as(u32, 1), lane.lane.deadline_wheel.entries.high_water);
    try expectOnlyTouchedResident(&lane.connections);
    try expectOnlyTouchedResident(&lane.requests);
    try expectOnlyTouchedResident(&lane.h2_lane.streams);
    try expectOnlyTouchedResident(&lane.registrations);
    try expectOnlyTouchedResident(&lane.lane.deadline_wheel.entries);
    try expectOnlyTouchedResident(&lane.lane.command_queue.nodes);
}

test "a fault-in mapping refuses transparent huge pages" {
    std.fs.accessAbsolute("/sys/kernel/mm/transparent_hugepage/enabled", .{}) catch |err| switch (err) {
        // The kernel has no huge page to refuse.
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    var table = try SmallSlab.init(1 << 20);
    defer table.deinit();
    try std.testing.expect(try refusesHugePages(@intFromPtr(table.entries.ptr)));

    var ring = try analytics.access.AccessRing.init();
    defer ring.deinit();
    try std.testing.expect(try refusesHugePages(@intFromPtr(ring.slots.ptr)));
}

/// Fails unless the table's resident pages are at most the pages its
/// entries below the high-water mark span from the start of the mapping.
fn expectOnlyTouchedResident(table: anytype) !void {
    const touched_bytes = std.mem.sliceAsBytes(table.touched()).len;
    const touched_pages = std.math.divCeil(usize, touched_bytes, std.heap.pageSize()) catch unreachable;
    try std.testing.expect(try residentPages(table.entries) <= touched_pages);
}

/// Whether the mapping that holds `address` carries the kernel's `nh` flag
/// (MADV_NOHUGEPAGE) in `/proc/self/smaps`.
fn refusesHugePages(address: usize) !bool {
    const smaps = try std.fs.cwd().readFileAlloc(std.testing.allocator, "/proc/self/smaps", 256 * 1024 * 1024);
    defer std.testing.allocator.free(smaps);
    var lines = std.mem.splitScalar(u8, smaps, '\n');
    var inside = false;
    while (lines.next()) |line| {
        if (mappingRange(line)) |range| {
            inside = range.start <= address and address < range.end;
            continue;
        }
        if (!inside or !std.mem.startsWith(u8, line, "VmFlags:"))
            continue;
        var flags = std.mem.tokenizeScalar(u8, line["VmFlags:".len..], ' ');
        while (flags.next()) |flag| {
            if (std.mem.eql(u8, flag, "nh"))
                return true;
        }
        return false;
    }
    return error.MappingNotFound;
}

/// The address range of an smaps header line (`start-end perms ...`), or
/// null for a field line.
fn mappingRange(line: []const u8) ?struct { start: usize, end: usize } {
    const dash = std.mem.indexOfScalar(u8, line, '-') orelse return null;
    const space = std.mem.indexOfScalar(u8, line, ' ') orelse return null;
    if (dash > space)
        return null;
    const start = std.fmt.parseUnsigned(usize, line[0..dash], 16) catch return null;
    const end = std.fmt.parseUnsigned(usize, line[dash + 1 .. space], 16) catch return null;
    return .{ .start = start, .end = end };
}

test "a key looks up live, vacant once its entry is released, and stale once the entry is handed out again" {
    var table = try SmallSlab.init(2);
    defer table.deinit();

    const first = table.acquire() orelse return error.SlabRefusedItsFirstEntry;
    try std.testing.expectEqual(@as(u64, 1), first.generation);
    first.entry.value = 7;
    switch (table.lookup(first.index, first.generation)) {
        .live => |entry| try std.testing.expectEqual(@as(u64, 7), entry.value),
        else => return error.KeyNotLive,
    }

    table.release(first.index);
    try std.testing.expectEqual(slab.LookupTag.vacant, std.meta.activeTag(table.lookup(first.index, first.generation)));
    try std.testing.expect(table.get(first.index) == null);

    const second = table.acquire() orelse return error.SlabRefusedAFreeEntry;
    try std.testing.expectEqual(first.index, second.index);
    try std.testing.expect(second.generation != first.generation);
    // Handed out again, the entry starts from its defaults.
    try std.testing.expectEqual(@as(u64, 0), second.entry.value);
    try std.testing.expectEqual(slab.LookupTag.stale_generation, std.meta.activeTag(table.lookup(first.index, first.generation)));

    // An entry never handed out reads as vacant, and one past the capacity
    // as out of range.
    try std.testing.expectEqual(slab.LookupTag.vacant, std.meta.activeTag(table.lookup(1, 1)));
    try std.testing.expectEqual(slab.LookupTag.out_of_range, std.meta.activeTag(table.lookup(2, 1)));
}

test "released entries come back last in first out before the high-water mark grows" {
    var table = try SmallSlab.init(4);
    defer table.deinit();

    const a = table.acquire().?;
    _ = table.acquire().?;
    const c = table.acquire().?;
    try std.testing.expectEqual(@as(u32, 3), table.high_water);
    table.release(a.index);
    table.release(c.index);

    try std.testing.expectEqual(c.index, table.acquire().?.index);
    try std.testing.expectEqual(a.index, table.acquire().?.index);
    try std.testing.expectEqual(@as(u32, 3), table.high_water);
    try std.testing.expectEqual(@as(u32, 3), table.acquire().?.index);
    try std.testing.expect(table.acquire() == null);
    try std.testing.expectEqual(@as(u32, 4), table.live_count);
}

test "a generation skips zero when it wraps" {
    try std.testing.expectEqual(@as(u64, 2), slab.nextGeneration(1));
    try std.testing.expectEqual(@as(u64, 1), slab.nextGeneration(std.math.maxInt(u64)));
}

test "a FIFO place is queued once, keeps its membership across the release and reuse of its entry, and pops in order" {
    var table = try SmallSlab.init(4);
    defer table.deinit();
    var fifo: slab.Fifo(SmallEntry) = .{};

    const first = table.acquire().?;
    const second = table.acquire().?;
    try std.testing.expect(fifo.push(&table, first.index));
    try std.testing.expect(!fifo.push(&table, first.index));
    try std.testing.expect(fifo.push(&table, second.index));
    try std.testing.expectEqual(@as(u32, 2), fifo.len);

    table.release(first.index);
    const again = table.acquire().?;
    try std.testing.expectEqual(first.index, again.index);
    try std.testing.expect(again.entry.slab_link.queued);
    try std.testing.expect(!fifo.push(&table, again.index));

    try std.testing.expectEqual(@as(?u32, first.index), fifo.pop(&table));
    try std.testing.expectEqual(@as(?u32, second.index), fifo.pop(&table));
    try std.testing.expectEqual(@as(?u32, null), fifo.pop(&table));
    try std.testing.expect(!table.entries[first.index].slab_link.queued);
}

test "the lane's keys are the lifecycle key types the pool hands back" {
    try std.testing.expect(lifecycle.RequestKey == supervision.pool.RequestKey);
}

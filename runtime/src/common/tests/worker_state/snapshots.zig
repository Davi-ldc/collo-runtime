//! The host's snapshots of a worker's page (`common/worker_state/page/snapshots.zig`): a live
//! slot's raw state compared and never cast, its identity matched on the copy the caller keeps,
//! the lifecycle tags converted only when their enums name them, and the usage record ring's
//! cursor, which keeps the host's tail in host memory, refuses a head no append can produce and
//! never reloads the head between a peek and its advance. The server's use of them, the death
//! record and the fault a corrupt ring raises, is covered by the server-supervisor lane.

const std = @import("std");
const page = @import("collo_worker_state").page;
const metrics = @import("collo_worker_state").metrics;

const identity: page.LifecycleIdentity = .{
    .external_request_id = 41,
    .request_lane_id = 2,
    .request_slot = 7,
    .request_generation = 3,
    .worker_id = 11,
    .worker_generation = 5,
};

fn claimedSlot(state: u32) page.LiveRequestSlot {
    var slot = std.mem.zeroes(page.LiveRequestSlot);
    slot.generation = 1;
    slot.request_id = identity.external_request_id;
    slot.request_lane_id = identity.request_lane_id;
    slot.request_slot = identity.request_slot;
    slot.request_generation = identity.request_generation;
    slot.worker_id = identity.worker_id;
    slot.worker_generation = identity.worker_generation;
    slot.started_mono_ns = 1_000;
    slot.cpu_time_ns = 250;
    slot.state = state;
    return slot;
}

test "a live slot whose state is 2 reads as inactive and matches no identity" {
    // 2 is outside `LiveSlotState`, where a cast would be illegal behavior.
    const slots = [_]page.LiveRequestSlot{ claimedSlot(2), claimedSlot(std.math.maxInt(u32)) };
    for (&slots) |*slot| {
        const snapshot = page.LiveSlotSnapshot.load(slot);
        try std.testing.expect(!snapshot.isActive());
        try std.testing.expect(!snapshot.matches(identity));
    }
    try std.testing.expect(page.LiveSlotSnapshot.find(&slots, identity) == null);

    const active = [_]page.LiveRequestSlot{ claimedSlot(@intFromEnum(page.LiveSlotState.empty)), claimedSlot(@intFromEnum(page.LiveSlotState.active)) };
    const found = page.LiveSlotSnapshot.find(&active, identity) orelse return error.TestExpectedMatch;
    try std.testing.expect(found.isActive());
}

test "a live slot snapshot is matched on every identity field and keeps what it copied" {
    var slot = claimedSlot(@intFromEnum(page.LiveSlotState.active));
    const snapshot = page.LiveSlotSnapshot.load(&slot);
    try std.testing.expect(snapshot.matches(identity));

    var other = identity;
    other.request_generation += 1;
    try std.testing.expect(!snapshot.matches(other));
    other = identity;
    other.worker_generation += 1;
    try std.testing.expect(!snapshot.matches(other));
    other = identity;
    other.request_lane_id += 1;
    try std.testing.expect(!snapshot.matches(other));
    // `billing_sequence` is a correlation copy, not part of the key.
    other = identity;
    other.billing_sequence = 99;
    try std.testing.expect(snapshot.matches(other));

    // The worker rewrites the slot after the load; the copy is unchanged.
    slot.request_id = 999;
    slot.cpu_time_ns = 1 << 40;
    slot.state = @intFromEnum(page.LiveSlotState.empty);
    try std.testing.expect(snapshot.matches(identity));
    try std.testing.expectEqual(@as(u64, 250), snapshot.cpu_time_ns);
    try std.testing.expectEqual(@as(u64, 1_000), snapshot.started_mono_ns);
}

test "a lifecycle tag outside its enum reads as null" {
    var header = std.mem.zeroes(page.Header);
    header.state = @intFromEnum(page.State.dead);
    header.termination_reason = @intFromEnum(page.TerminationReason.memory);
    const known = page.LifecycleSnapshot.load(&header);
    try std.testing.expectEqual(page.State.dead, known.knownState().?);
    try std.testing.expectEqual(page.TerminationReason.memory, known.knownTerminationReason().?);

    header.state = 0;
    header.termination_reason = 6;
    const unknown = page.LifecycleSnapshot.load(&header);
    try std.testing.expect(unknown.knownState() == null);
    try std.testing.expect(unknown.knownTerminationReason() == null);
    try std.testing.expectEqual(@as(u32, 6), unknown.termination_reason);

    header.termination_reason = std.math.maxInt(u32);
    try std.testing.expect(page.LifecycleSnapshot.load(&header).knownTerminationReason() == null);
}

fn record(request_id: u64) page.CompletedRecord {
    return .{
        .request_id = request_id,
        .started_mono_ns = request_id * 10,
        .finished_mono_ns = request_id * 10 + 5,
        .cpu_time_ns = request_id,
        .io_time_ns = 0,
        .status = @intFromEnum(page.CompletedStatus.done),
        .flags = 0,
    };
}

test "a head moved back between peek and advance leaves the host's tail where the peek put it, and the next peek refuses the ring" {
    const fd = try page.createMemfd("snapshots-head-moved-back");
    defer std.posix.close(fd);
    var view = try page.mapReadWrite(fd);
    defer view.deinit();
    var work_state = metrics.WorkState.init(&view);
    for (1..4) |request_id|
        try work_state.appendCompletedRecord(record(request_id));

    var cursor: page.RecordCursor = .{};
    const peeked = cursor.peek(view.header) orelse return error.TestUnexpectedCorruption;
    try std.testing.expectEqual(@as(u64, 3), peeked.count);
    var out: [4]page.CompletedRecord = undefined;
    try std.testing.expectEqual(@as(usize, 3), peeked.copy(view.completed_records, 0, &out));
    try std.testing.expectEqual(@as(u64, 3), out[2].request_id);

    // The worker moves its head back before the host consumes what it peeked.
    @atomicStore(u64, &view.header.records_head, 1, .release);
    cursor.advance(view.header, peeked, peeked.count);
    try std.testing.expectEqual(@as(u64, 3), cursor.tail);
    try std.testing.expectEqual(@as(u64, 3), @atomicLoad(u64, &view.header.records_tail, .acquire));

    try std.testing.expect(cursor.peek(view.header) == null);
    try std.testing.expect(cursor.drain(view.header, view.completed_records, &out) == null);
    try std.testing.expectEqual(@as(u64, 3), cursor.tail);
}

test "a head more than the ring ahead of the host's tail is refused, and a full ring is not" {
    var header = std.mem.zeroes(page.Header);
    var cursor: page.RecordCursor = .{ .tail = 40 };

    header.records_head = 40 + page.RECORD_RING_COUNT;
    const full = cursor.peek(&header) orelse return error.TestUnexpectedCorruption;
    try std.testing.expectEqual(@as(u64, page.RECORD_RING_COUNT), full.count);

    header.records_head = 40 + page.RECORD_RING_COUNT + 1;
    try std.testing.expect(cursor.peek(&header) == null);
    header.records_head = std.math.maxInt(u64);
    try std.testing.expect(cursor.peek(&header) == null);
}

test "the host's tail is never read back from the page" {
    const fd = try page.createMemfd("snapshots-tail-read-back");
    defer std.posix.close(fd);
    var view = try page.mapReadWrite(fd);
    defer view.deinit();
    var work_state = metrics.WorkState.init(&view);
    for (1..3) |request_id|
        try work_state.appendCompletedRecord(record(request_id));

    var cursor: page.RecordCursor = .{};
    var out: [4]page.CompletedRecord = undefined;
    try std.testing.expectEqual(@as(usize, 1), cursor.drain(view.header, view.completed_records, out[0..1]).?);
    try std.testing.expectEqual(@as(u64, 1), out[0].request_id);

    // A worker that rewrites `records_tail` changes only its own room check.
    @atomicStore(u64, &view.header.records_tail, 0, .release);
    try std.testing.expectEqual(@as(usize, 1), cursor.drain(view.header, view.completed_records, &out).?);
    try std.testing.expectEqual(@as(u64, 2), out[0].request_id);
    try std.testing.expectEqual(@as(u64, 2), @atomicLoad(u64, &view.header.records_tail, .acquire));
}

test "a peek copies past a skip and across the ring's wrap, and advances by the prefix taken" {
    var header = std.mem.zeroes(page.Header);
    const records = try std.testing.allocator.alloc(page.CompletedRecord, page.RECORD_RING_COUNT);
    defer std.testing.allocator.free(records);
    @memset(records, std.mem.zeroes(page.CompletedRecord));
    const start: u64 = page.RECORD_RING_COUNT - 2;
    for (0..4) |offset| {
        const position = start + offset;
        records[@intCast(position % page.RECORD_RING_COUNT)] = record(100 + offset);
    }
    header.records_head = start + 4;
    var cursor: page.RecordCursor = .{ .tail = start };

    const peeked = cursor.peek(&header) orelse return error.TestUnexpectedCorruption;
    var out: [4]page.CompletedRecord = undefined;
    try std.testing.expectEqual(@as(usize, 3), peeked.copy(records, 1, &out));
    try std.testing.expectEqual(@as(u64, 101), out[0].request_id);
    try std.testing.expectEqual(@as(u64, 103), out[2].request_id);
    try std.testing.expectEqual(@as(usize, 0), peeked.copy(records, 4, &out));

    cursor.advance(&header, peeked, 2);
    try std.testing.expectEqual(start + 2, cursor.tail);
    const rest = cursor.peek(&header) orelse return error.TestUnexpectedCorruption;
    try std.testing.expectEqual(@as(u64, 2), rest.count);
}

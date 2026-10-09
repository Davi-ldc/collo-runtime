//! One copy of a pool slot (`common/ipc/egress_shared/slot_snapshot.zig`): a slot the producer
//! rewrites between the consumer's validation and its borrow still yields the validated copy's
//! extent, and a copy that is not the published extent the handle names, or lies outside the data
//! region, is refused by its validation and by its borrow alike. The gateway's upload path, which
//! drops a worker whose extent is refused, is covered by the egress-gateway lane.

const std = @import("std");
const ipc = @import("collo_ipc");

const egress_shared = ipc.egress_shared;
const SlotSnapshot = egress_shared.SlotSnapshot;

const capacity: usize = 4 * egress_shared.body_pool_block_size;
const generation: u32 = 7;

fn publishedSlot(offset: u32, len: u32) egress_shared.BodyPoolSlot {
    return .{
        .state = @intFromEnum(egress_shared.BodyPoolSlotState.published),
        .generation = generation,
        .offset = offset,
        .len = len,
        .block_count = 1,
    };
}

fn patternedData() ![]u8 {
    const data = try std.testing.allocator.alloc(u8, capacity);
    for (data, 0..) |*byte, index|
        byte.* = @truncate(index *% 31);
    return data;
}

test "a slot rewritten between validation and borrow yields the validated copy (#40)" {
    const data = try patternedData();
    defer std.testing.allocator.free(data);
    var slot = publishedSlot(egress_shared.body_pool_block_size, 100);

    const copy = SlotSnapshot.load(&slot);
    try copy.validate(generation, 100, capacity);

    // The producer moves the extent to the end of the region and grows it
    // past the mapping between the two calls.
    @atomicStore(u32, &slot.offset, @intCast(capacity - 1), .release);
    @atomicStore(u32, &slot.len, std.math.maxInt(u32), .release);

    const bytes = try copy.borrow(data);
    try std.testing.expectEqual(@as(usize, 100), bytes.len);
    try std.testing.expectEqual(@intFromPtr(data.ptr) + egress_shared.body_pool_block_size, @intFromPtr(bytes.ptr));
    try std.testing.expectEqualSlices(u8, data[egress_shared.body_pool_block_size..][0..100], bytes);

    // A fresh load sees the rewrite, and its validation refuses it.
    try std.testing.expectError(error.InvalidEgressSharedRing, SlotSnapshot.load(&slot).validate(generation, 100, capacity));
}

test "a copy that is not the published extent the handle names is refused" {
    var slot = publishedSlot(0, 64);
    try SlotSnapshot.load(&slot).validate(generation, 64, capacity);

    try std.testing.expectError(error.InvalidEgressSharedRing, SlotSnapshot.load(&slot).validate(generation + 1, 64, capacity));
    try std.testing.expectError(error.InvalidEgressSharedRing, SlotSnapshot.load(&slot).validate(generation, 65, capacity));
    try std.testing.expectError(error.InvalidEgressSharedRing, SlotSnapshot.load(&slot).validate(generation, 0, capacity));
    try std.testing.expectError(error.InvalidEgressSharedRing, SlotSnapshot.load(&slot).validate(generation, capacity + 1, capacity));

    slot.state = @intFromEnum(egress_shared.BodyPoolSlotState.reserved);
    try std.testing.expectError(error.InvalidEgressSharedRing, SlotSnapshot.load(&slot).validate(generation, 64, capacity));
    // A state outside the enum is compared, never cast.
    slot.state = 9;
    try std.testing.expectError(error.InvalidEgressSharedRing, SlotSnapshot.load(&slot).validate(generation, 64, capacity));
}

test "a copy outside the data region is refused by validation and by borrow" {
    const data = try patternedData();
    defer std.testing.allocator.free(data);

    var past_end = publishedSlot(@intCast(capacity - 8), 16);
    const past_end_copy = SlotSnapshot.load(&past_end);
    try std.testing.expectError(error.InvalidEgressSharedRing, past_end_copy.validate(generation, 16, capacity));
    try std.testing.expectError(error.InvalidEgressSharedRing, past_end_copy.borrow(data));

    var far_offset = publishedSlot(std.math.maxInt(u32), std.math.maxInt(u32));
    const far_copy = SlotSnapshot.load(&far_offset);
    try std.testing.expectError(error.InvalidEgressSharedRing, far_copy.borrow(data));

    var last_byte = publishedSlot(@intCast(capacity - 1), 1);
    const last_copy = SlotSnapshot.load(&last_byte);
    try last_copy.validate(generation, 1, capacity);
    try std.testing.expectEqual(data[capacity - 1], (try last_copy.borrow(data))[0]);
}

//! One copy of a pool slot, the only way a consumer reads a slot the
//! producer published (`body_pool.zig`). The gateway's main loop is the
//! reader this exists for: on the upload pool the worker is the producer and
//! can rewrite its slots at any moment, so the gateway loads a slot once,
//! validates that copy against the pool's capacity and slices the extent
//! from the copy. A worker that rewrites the slot after the load changes
//! nothing the gateway does with it. The extent's bytes stay in shared
//! memory, where the worker can still garble its own upload but cannot move
//! the slice. The worker reads the gateway's body pool slots the same way.

const BodyPoolSlot = @import("body_pool.zig").BodyPoolSlot;
const BodyPoolSlotState = @import("body_pool.zig").BodyPoolSlotState;

/// Where a validated copy's extent lies in its pool's data region.
pub const Extent = struct {
    offset: usize,
    len: usize,
};

/// A slot's fields, each loaded once. `state` stays the raw value the
/// producer stored.
pub const SlotSnapshot = struct {
    state: u32,
    generation: u32,
    offset: u32,
    len: u32,

    /// Loads `state` first, with acquire ordering, which pairs with the
    /// producer's release store when it publishes the slot, then
    /// `generation`, `offset` and `len` once each.
    pub fn load(slot: *const BodyPoolSlot) SlotSnapshot {
        const state = @atomicLoad(u32, &slot.state, .acquire);
        return .{
            .state = state,
            .generation = @atomicLoad(u32, &slot.generation, .monotonic),
            .offset = @atomicLoad(u32, &slot.offset, .monotonic),
            .len = @atomicLoad(u32, &slot.len, .monotonic),
        };
    }

    /// Checks that the copy is a published extent of `generation`, exactly
    /// `len` bytes long, inside a data region of `capacity` bytes. Fails
    /// with `error.InvalidEgressSharedRing` otherwise.
    pub fn validate(self: SlotSnapshot, generation: u32, len: usize, capacity: usize) error{InvalidEgressSharedRing}!void {
        if (self.state != @intFromEnum(BodyPoolSlotState.published))
            return error.InvalidEgressSharedRing;
        if (self.generation != generation)
            return error.InvalidEgressSharedRing;
        if (len == 0 or len > capacity)
            return error.InvalidEgressSharedRing;
        if (self.len != len)
            return error.InvalidEgressSharedRing;
        _ = try self.extent(capacity);
    }

    /// The copy's extent inside a data region of `capacity` bytes. The
    /// bounds are checked here too, so a copy that skipped `validate` still
    /// cannot reach past the region.
    pub fn extent(self: SlotSnapshot, capacity: usize) error{InvalidEgressSharedRing}!Extent {
        const offset: usize = self.offset;
        const len: usize = self.len;
        if (offset > capacity)
            return error.InvalidEgressSharedRing;
        if (len > capacity - offset)
            return error.InvalidEgressSharedRing;
        return .{ .offset = offset, .len = len };
    }

    /// The copy's bytes in `data`, the pool's data region.
    pub fn borrow(copy: SlotSnapshot, data: []const u8) error{InvalidEgressSharedRing}![]const u8 {
        const range = try copy.extent(data.len);
        return data[range.offset..][0..range.len];
    }
};

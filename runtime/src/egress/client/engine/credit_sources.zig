//! The engine's credit sources: one per HTTP/2 stream and per HTTP/1 fetch
//! the owner runs. A source's id is the name every flow-control credit of
//! that stream or of that fetch's body carries back from the gateway
//! (`body_credit.H2Data.source_id`, `body_credit.H1Resume.source_id`).
//!
//! A source id is an allocation sequence number above the source's slot
//! index. The sequence counts up for the engine's whole life and never
//! restarts with a run, so a credit kept across a stop and a start, or
//! returned after its stream ended, names no live source and changes
//! nothing; a credit whose kind or HTTP/2 stream id does not match its
//! source changes nothing either. The sequence has `sequence_bits` bits, so
//! an id repeats only after that many allocations, years at any rate an
//! owner thread can open streams.
//!
//! A credit never becomes a message. The gateway's thread adds it to its
//! source's released credit, and a source with released credit sits in the
//! dirty list once until the owner takes it. Both that list and the chain
//! `take` hands the owner run through the slots themselves, so they need no
//! storage of their own, cannot overflow, and a release never waits for the
//! owner. The owner applies each source's credit at once: the summed bytes of
//! its window-reopening HTTP/2 credits, then the one credit of the stream's
//! last DATA frame, or an HTTP/1 resume.
//!
//! Slots are allocated as sources first need them, up to the table's
//! capacity, and retired ones are reused first, newest first, so the table
//! costs the memory of the most sources that ran at once.
//!
//! Locking: `acquire`, `retire`, `release`, `take` and `clear` run with
//! `Engine.mutex` held, and only `acquire` moves the slots. A slot's taken
//! credit, its taken chain and its target are owner state: only the owner
//! thread writes or reads them, and `claimNext` runs without the mutex.

const std = @import("std");
const core = @import("collo_egress_core");
const h2 = @import("h2.zig");
const h1 = @import("h1.zig");

const body_credit = core.body_credit;

pub const slot_bits = 18;
pub const sequence_bits = 64 - slot_bits;
/// Most sources an engine can have; `CreditSources.init` takes at most this
/// many.
pub const capacity_max: usize = 1 << slot_bits;
const slot_mask: u64 = capacity_max - 1;
const sequence_max: u64 = (1 << sequence_bits) - 1;
const no_slot: u32 = std.math.maxInt(u32);
/// The first allocation of slots; later ones double, up to the capacity.
const slots_initial: usize = 16;

pub const Kind = enum { h2, h1 };

/// What the owner applies a source's credit to.
pub const Target = union(Kind) {
    h2: *h2.Stream,
    h1: *h1.Fetch,
};

/// The credit released for one source and not yet applied.
pub const Credit = struct {
    /// Summed bytes of the HTTP/2 credits that also reopen the stream window.
    window_bytes: usize = 0,
    /// At least one such credit arrived, possibly of zero bytes.
    window: bool = false,
    /// Bytes of the stream's last DATA frame, whose credit reopens only the
    /// connection window. A stream has one such credit.
    final_bytes: usize = 0,
    final: bool = false,
    /// An HTTP/1 resume arrived.
    resumed: bool = false,
};

/// A source's taken credit and what it applies to, from `claimNext`.
pub const Claim = struct {
    target: Target,
    credit: Credit,
};

/// The first slot of the chain `take` moved out; `claimNext` walks it.
pub const Taken = struct {
    next: u32 = no_slot,
};

const Slot = struct {
    /// The id credits name; 0 while the slot is free.
    id: u64 = 0,
    kind: Kind = .h2,
    /// The stream an HTTP/2 source's credits must name.
    stream_id: u32 = 0,
    released: Credit = .{},
    /// Listed in the dirty list. It stays set across a retire, so a slot is
    /// listed at most once whoever holds it, and `take` clears it.
    queued: bool = false,
    next_dirty: u32 = no_slot,
    /// Owner state: the credit the last `take` moved out, the id it was
    /// released for, and the next slot of that take's chain. `acquire`
    /// leaves `next_taken` alone, so reusing a slot while the owner walks
    /// the chain never cuts it.
    taken: Credit = .{},
    taken_id: u64 = 0,
    next_taken: u32 = no_slot,
    target: Target = undefined,
    next_free: u32 = no_slot,
};

pub const CreditSources = struct {
    allocator: std.mem.Allocator,
    /// The most slots the table allocates.
    capacity: usize,
    slots: std.ArrayListUnmanaged(Slot) = .empty,
    /// Retired slots, linked through `Slot.next_free`.
    free_head: u32 = no_slot,
    live: usize = 0,
    next_sequence: u64 = 1,
    /// Slots with released credit, linked through `Slot.next_dirty`.
    dirty_head: u32 = no_slot,

    /// `capacity` is the most HTTP/2 streams and HTTP/1 fetches the engine
    /// runs at once. Allocates nothing until the first `acquire`.
    pub fn init(allocator: std.mem.Allocator, capacity: usize) CreditSources {
        std.debug.assert(capacity != 0);
        std.debug.assert(capacity <= capacity_max);
        return .{ .allocator = allocator, .capacity = capacity };
    }

    pub fn deinit(self: *CreditSources) void {
        std.debug.assert(self.live == 0);
        self.slots.deinit(self.allocator);
        self.* = undefined;
    }

    /// Gives `target` a source and returns its id. `stream_id` is the HTTP/2
    /// stream an h2 target's credits name, and 0 for an h1 target. Fails with
    /// `error.EgressEngineSourcesExhausted` when every slot of the capacity
    /// is taken, and `error.OutOfMemory` when a new slot cannot be allocated.
    pub fn acquire(self: *CreditSources, target: Target, stream_id: u32) error{ EgressEngineSourcesExhausted, OutOfMemory }!u64 {
        var index = self.free_head;
        if (index != no_slot) {
            self.free_head = self.slots.items[index].next_free;
        } else {
            index = try self.addSlot();
        }
        const slot = &self.slots.items[index];
        std.debug.assert(slot.id == 0);
        const id = (self.next_sequence << slot_bits) | index;
        self.next_sequence = if (self.next_sequence == sequence_max) 1 else self.next_sequence + 1;
        slot.id = id;
        slot.kind = std.meta.activeTag(target);
        slot.stream_id = stream_id;
        slot.released = .{};
        slot.taken = .{};
        slot.taken_id = 0;
        slot.target = target;
        slot.next_free = no_slot;
        self.live += 1;
        return id;
    }

    /// Frees the source `id`, so every credit still naming it changes
    /// nothing.
    pub fn retire(self: *CreditSources, id: u64) void {
        const index = slotIndex(id);
        const slot = &self.slots.items[index];
        std.debug.assert(slot.id == id);
        slot.id = 0;
        slot.released = .{};
        slot.taken = .{};
        slot.taken_id = 0;
        slot.target = undefined;
        slot.next_free = self.free_head;
        self.free_head = @intCast(index);
        self.live -= 1;
    }

    /// Adds `credit` to its source's released credit. Returns true when the
    /// source was not listed yet, so the owner must be woken; false when the
    /// owner will take the credit with an earlier one, or when the credit
    /// names no live source of its kind and changes nothing.
    pub fn release(self: *CreditSources, credit: body_credit.Handle) bool {
        switch (credit) {
            .none => return false,
            .h2_data => |data| {
                const index = self.liveSlot(data.source_id, .h2, data.stream_id) orelse return false;
                const released = &self.slots.items[index].released;
                // A sum past the stream's window is dropped whole when the
                // owner compares it with what the stream holds.
                if (data.update_stream_window) {
                    released.window_bytes +|= data.encoded_bytes;
                    released.window = true;
                } else {
                    released.final_bytes +|= data.encoded_bytes;
                    released.final = true;
                }
                return self.list(index);
            },
            .h1_resume => |resumed| {
                const index = self.liveSlot(resumed.source_id, .h1, 0) orelse return false;
                self.slots.items[index].released.resumed = true;
                return self.list(index);
            },
        }
    }

    /// Owner thread: moves every listed source's released credit to its
    /// taken credit and chains those slots for `claimNext`. A slot freed
    /// since it was listed takes nothing.
    pub fn take(self: *CreditSources) Taken {
        var taken: Taken = .{};
        var index = self.dirty_head;
        self.dirty_head = no_slot;
        while (index != no_slot) {
            const slot = &self.slots.items[index];
            std.debug.assert(slot.queued);
            const next = slot.next_dirty;
            slot.queued = false;
            slot.next_dirty = no_slot;
            slot.taken = slot.released;
            slot.taken_id = slot.id;
            slot.released = .{};
            slot.next_taken = taken.next;
            taken.next = @intCast(index);
            index = next;
        }
        return taken;
    }

    /// Owner thread, without the mutex: the next credit of `taken`'s chain,
    /// with its target, skipping sources that retired since the take; null
    /// at the chain's end. The caller may acquire and retire sources between
    /// calls.
    pub fn claimNext(self: *CreditSources, taken: *Taken) ?Claim {
        while (taken.next != no_slot) {
            const slot = &self.slots.items[taken.next];
            taken.next = slot.next_taken;
            if (slot.taken_id == 0 or slot.taken_id != slot.id)
                continue;
            const claimed: Claim = .{ .target = slot.target, .credit = slot.taken };
            slot.taken = .{};
            slot.taken_id = 0;
            return claimed;
        }
        return null;
    }

    /// Drops every listed credit once a run ended, when every source has
    /// retired.
    pub fn clear(self: *CreditSources) void {
        std.debug.assert(self.live == 0);
        var index = self.dirty_head;
        self.dirty_head = no_slot;
        while (index != no_slot) {
            const slot = &self.slots.items[index];
            index = slot.next_dirty;
            slot.queued = false;
            slot.next_dirty = no_slot;
            slot.released = .{};
        }
    }

    /// Allocates a slot that was never used, doubling the allocation up to
    /// the capacity.
    fn addSlot(self: *CreditSources) error{ EgressEngineSourcesExhausted, OutOfMemory }!u32 {
        const len = self.slots.items.len;
        if (len == self.capacity)
            return error.EgressEngineSourcesExhausted;
        if (len == self.slots.capacity) {
            const grown = @min(self.capacity, @max(slots_initial, 2 * self.slots.capacity));
            try self.slots.ensureTotalCapacityPrecise(self.allocator, grown);
        }
        self.slots.appendAssumeCapacity(.{});
        return @intCast(len);
    }

    /// Lists slot `index` unless it is listed already; returns whether it
    /// was not.
    fn list(self: *CreditSources, index: usize) bool {
        const slot = &self.slots.items[index];
        if (slot.queued)
            return false;
        slot.queued = true;
        slot.next_dirty = self.dirty_head;
        self.dirty_head = @intCast(index);
        return true;
    }

    fn liveSlot(self: *const CreditSources, id: u64, kind: Kind, stream_id: u32) ?usize {
        if (id == 0)
            return null;
        const index = slotIndex(id);
        if (index >= self.slots.items.len)
            return null;
        const slot = &self.slots.items[index];
        if (slot.id != id or slot.kind != kind or slot.stream_id != stream_id)
            return null;
        return index;
    }
};

fn slotIndex(id: u64) usize {
    return @intCast(id & slot_mask);
}

comptime {
    std.debug.assert(slot_bits < 32);
    std.debug.assert(capacity_max < no_slot);
    std.debug.assert(sequence_bits >= 32);
}

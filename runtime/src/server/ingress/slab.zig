//! The fault-in slab, the table behind every per-lane collection of an
//! ingress lane (its connections, requests, streams, worker registrations,
//! deadline entries and command nodes), and the FIFO a slab's places can wait
//! on. A slab is owned by one lane; the command queue's slab is the one that
//! other threads reach, under the queue's mutex.
//!
//! Invariants:
//! - A slab reserves `capacity` entries of address space when it is created,
//!   with MAP_NORESERVE, and writes none of it. An entry is written first when
//!   it is first handed out, so the pages a lane holds are the ones its
//!   busiest moment needed, and an idle lane holds none.
//! - Entries below `high_water` have been handed out at least once. A
//!   released entry goes on top of a LIFO free stack, and `acquire` takes the
//!   top before it raises `high_water`, so the lane reuses the entry it
//!   touched last, whose page is resident.
//! - Every entry carries a generation that is 1 when the entry is first
//!   handed out and advances at each release, skipping 0, which no key holds.
//!   A key holds an index and a generation: kept past the entry's release it
//!   looks up as `vacant`, and as `stale_generation` once the entry is handed
//!   out again. An index at or past `high_water` looks up as `vacant` without
//!   its memory being read.
//! - An entry's place may wait on one `Fifo` of its slab. The membership
//!   belongs to the place, not to the entry handed out there: it survives
//!   `release` and `acquire`, so a place is queued at most once while its
//!   occupants change, and a pop yields whatever entry the place holds then,
//!   or a vacant place.

const std = @import("std");

/// The index that names no entry.
pub const none: u32 = std.math.maxInt(u32);

/// What a slab keeps in each of its entries, which embed it as `slab_link`.
/// Only the slab and its FIFO write it.
pub const Link = struct {
    /// The generation a key to the entry carries while the entry is live.
    generation: u64 = 0,
    /// The next entry down the free stack while the entry is free.
    next_free: u32 = none,
    live: bool = false,
    /// The place waits on its slab's FIFO (`Fifo`).
    queued: bool = false,
    /// The next place on that FIFO.
    queue_next: u32 = none,
};

pub const LookupTag = enum {
    live,
    stale_generation,
    vacant,
    out_of_range,
};

/// The generation after `generation`, skipping 0 on wrap.
pub fn nextGeneration(generation: u64) u64 {
    const next = generation +% 1;
    return if (next == 0) 1 else next;
}

pub fn FaultInSlab(comptime T: type) type {
    comptime {
        if (!@hasField(T, "slab_link") or @FieldType(T, "slab_link") != Link)
            @compileError(@typeName(T) ++ " must embed `slab_link: slab.Link`");
    }
    return struct {
        const Self = @This();

        /// The reserved mapping, `capacity` entries long.
        entries: []T = &.{},
        /// Entries below this have been handed out at least once.
        high_water: u32 = 0,
        /// The top of the free stack, the entry released last.
        free_head: u32 = none,
        /// Entries handed out and not released.
        live_count: u32 = 0,

        pub const Acquired = struct {
            index: u32,
            generation: u64,
            entry: *T,
        };

        pub const Lookup = union(LookupTag) {
            live: *T,
            stale_generation,
            vacant,
            out_of_range,
        };

        /// Reserves `entry_count` entries of address space and touches none.
        /// Fails with `error.InvalidSlabCapacity` for zero, and with the
        /// mapping's error when the address space cannot be reserved.
        pub fn init(entry_count: u32) (error{InvalidSlabCapacity} || std.posix.MMapError)!Self {
            if (entry_count == 0 or entry_count == none)
                return error.InvalidSlabCapacity;
            const bytes = try std.posix.mmap(
                null,
                mappingBytes(entry_count),
                std.posix.PROT.READ | std.posix.PROT.WRITE,
                .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true },
                -1,
                0,
            );
            const first: [*]T = @ptrCast(@alignCast(bytes.ptr));
            return .{ .entries = first[0..entry_count] };
        }

        /// Unmaps the slab whether or not entries are live: a live entry
        /// here means another structure still holds its key, which the
        /// owner's teardown checks before this.
        pub fn deinit(self: *Self) void {
            if (self.entries.len != 0) {
                const first: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(self.entries.ptr));
                std.posix.munmap(first[0..mappingBytes(@intCast(self.entries.len))]);
            }
            self.* = .{};
        }

        pub fn capacity(self: *const Self) u32 {
            return @intCast(self.entries.len);
        }

        /// Hands out an entry, reset to `T`'s defaults and live under its
        /// generation, or null when every entry is live. Its FIFO membership
        /// stays as it was.
        pub fn acquire(self: *Self) ?Acquired {
            var index: u32 = undefined;
            var generation: u64 = undefined;
            var queued = false;
            var queue_next: u32 = none;
            if (self.free_head != none) {
                index = self.free_head;
                const link = &self.entries[index].slab_link;
                self.free_head = link.next_free;
                generation = link.generation;
                queued = link.queued;
                queue_next = link.queue_next;
            } else if (self.high_water < self.entries.len) {
                index = self.high_water;
                self.high_water += 1;
                generation = 1;
            } else return null;
            const entry = &self.entries[index];
            entry.* = .{ .slab_link = .{
                .generation = generation,
                .live = true,
                .queued = queued,
                .queue_next = queue_next,
            } };
            self.live_count += 1;
            return .{ .index = index, .generation = generation, .entry = entry };
        }

        /// Returns the live entry at `index` to the free stack under its
        /// next generation. The entry's other fields stay as they were until
        /// it is handed out again; the caller has freed what they own.
        pub fn release(self: *Self, index: u32) void {
            std.debug.assert(index < self.high_water);
            const link = &self.entries[index].slab_link;
            std.debug.assert(link.live);
            link.live = false;
            link.generation = nextGeneration(link.generation);
            link.next_free = self.free_head;
            self.free_head = index;
            self.live_count -= 1;
        }

        /// The live entry at `index`, or null.
        pub fn get(self: *Self, index: u32) ?*T {
            if (index >= self.high_water)
                return null;
            const entry = &self.entries[index];
            return if (entry.slab_link.live) entry else null;
        }

        /// The entry a key names: live under that generation, stale when the
        /// entry was handed out again, vacant when it is free or was never
        /// handed out, out of range past the capacity.
        pub fn lookup(self: *Self, index: u32, generation: u64) Lookup {
            if (index >= self.entries.len)
                return .out_of_range;
            if (index >= self.high_water)
                return .vacant;
            const entry = &self.entries[index];
            if (!entry.slab_link.live)
                return .vacant;
            if (entry.slab_link.generation != generation)
                return .stale_generation;
            return .{ .live = entry };
        }

        /// The entries handed out at least once, live or free; a caller that
        /// walks the slab checks `slab_link.live`.
        pub fn touched(self: *const Self) []T {
            return self.entries[0..self.high_water];
        }

        fn mappingBytes(entry_count: u32) usize {
            return std.mem.alignForward(usize, @as(usize, entry_count) * @sizeOf(T), std.heap.page_size_min);
        }
    };
}

/// A FIFO of places of one slab, threaded through their links, so it can
/// never fill. A place is on it at most once (`Link.queued`).
pub fn Fifo(comptime T: type) type {
    return struct {
        const Self = @This();
        const Slab = FaultInSlab(T);

        head: u32 = none,
        tail: u32 = none,
        len: u32 = 0,

        /// Queues the place `index`, a place handed out at least once,
        /// unless it is queued already. Returns whether it queued it.
        pub fn push(self: *Self, slab_table: *Slab, index: u32) bool {
            std.debug.assert(index < slab_table.high_water);
            const link = &slab_table.entries[index].slab_link;
            if (link.queued)
                return false;
            link.queued = true;
            link.queue_next = none;
            if (self.tail == none)
                self.head = index
            else
                slab_table.entries[self.tail].slab_link.queue_next = index;
            self.tail = index;
            self.len += 1;
            return true;
        }

        /// The oldest place queued, no longer queued, or null when none is.
        pub fn pop(self: *Self, slab_table: *Slab) ?u32 {
            const index = self.head;
            if (index == none)
                return null;
            const link = &slab_table.entries[index].slab_link;
            self.head = link.queue_next;
            if (self.head == none)
                self.tail = none;
            link.queued = false;
            link.queue_next = none;
            self.len -= 1;
            return index;
        }
    };
}

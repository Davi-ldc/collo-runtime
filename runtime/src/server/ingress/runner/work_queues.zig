//! The lane thread's ready queues, holding the connections and the worker
//! deaths that wait for the event loop's next pass, and its pool of header
//! buffers, one held by each connection from accept to close.
//!
//! Each queue has one entry per item it can hold, and an item is on its
//! queue at most once, behind its `queued` or `death_queued` flag, which the
//! pop clears, so neither queue can fill. A connection's flag outlives the
//! slot's reset while an entry for it waits (`finishClose` in
//! `connection_flow.zig`, `startConnection` in `accept_flow.zig`), and an
//! entry popped for a reset slot serves the connection that took its place.
//! A registration with a death queued is not reset before the pop
//! (`releaseRegistrationIfIdle` in `worker_registration.zig`).

const std = @import("std");

const fault = @import("../fault.zig");
const ingress_state = @import("../state.zig");

const LaneFault = fault.LaneFault;

pub fn Methods(comptime Self: type) type {
    return struct {
        /// Queues the connection in `slot`, a slot of `connection_slots`, for
        /// a turn of the event loop.
        pub fn enqueueConnection(self: *Self, slot: u32) void {
            const runtime = &self.connection_slots[slot];
            if (!runtime.active or runtime.queued)
                return;
            // The queue holds one entry per slot, and this slot has none.
            self.ready_connections.push(slot) catch unreachable;
            runtime.queued = true;
        }

        pub fn popConnection(self: *Self) ?u32 {
            const slot = self.ready_connections.pop() orelse return null;
            if (slot < self.connection_slots.len)
                self.connection_slots[slot].queued = false;
            return slot;
        }

        /// Queues the deferred worker fault of registration
        /// `registration_index` for the loop's next pass.
        pub fn enqueueDeath(self: *Self, registration_index: u32) LaneFault!void {
            if (registration_index >= self.completion_registration_count)
                return error.InvalidCompletionRegistration;
            const registration = &self.completion_registrations[registration_index];
            if (registration.death_queued)
                return;
            try self.ready_death_regs.push(registration_index);
            registration.death_queued = true;
        }

        pub fn popDeath(self: *Self) ?u32 {
            const index = self.ready_death_regs.pop() orelse return null;
            if (index < self.completion_registration_count)
                self.completion_registrations[index].death_queued = false;
            return index;
        }

        pub fn acquireHeaderBuffer(self: *Self) ?u32 {
            return self.header_buffers.acquire();
        }

        pub fn releaseHeaderBuffer(self: *Self, index: u32) void {
            self.header_buffers.release(index);
        }

        pub fn headerBuffer(self: *Self, index: u32) []u8 {
            return self.header_buffers.buffer(index);
        }
    };
}

/// The connections waiting for a turn, by connection slot.
pub const ReadyQueue = struct {
    items: []u32 = &.{},
    head: usize = 0,
    len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !ReadyQueue {
        return .{
            .items = try allocator.alloc(u32, capacity),
        };
    }

    pub fn deinit(self: *ReadyQueue, allocator: std.mem.Allocator) void {
        allocator.free(self.items);
        self.* = .{};
    }

    pub fn push(self: *ReadyQueue, value: u32) !void {
        if (self.len == self.items.len)
            return error.ReadyConnectionQueueFull;
        const tail = (self.head + self.len) % self.items.len;
        self.items[tail] = value;
        self.len += 1;
    }

    pub fn pop(self: *ReadyQueue) ?u32 {
        if (self.len == 0)
            return null;
        const value = self.items[self.head];
        self.head = (self.head + 1) % self.items.len;
        self.len -= 1;
        return value;
    }
};

/// The registrations whose deferred worker fault waits for the loop's next
/// pass (`worker_fault.deferWorkerFault`), by registration index.
pub fn DeathQueue(comptime capacity: usize) type {
    return struct {
        items: [capacity]u32 = undefined,
        head: usize = 0,
        len: usize = 0,

        pub fn push(self: *@This(), value: u32) error{DeathQueueFull}!void {
            if (self.len == self.items.len)
                return error.DeathQueueFull;
            const tail = (self.head + self.len) % self.items.len;
            self.items[tail] = value;
            self.len += 1;
        }

        pub fn pop(self: *@This()) ?u32 {
            if (self.len == 0)
                return null;
            const value = self.items[self.head];
            self.head = (self.head + 1) % self.items.len;
            self.len -= 1;
            return value;
        }
    };
}

pub const HeaderBufferPool = struct {
    bytes: []u8 = &.{},
    free_slots: []u32 = &.{},
    used_slots: []bool = &.{},
    free_count: usize = 0,
    buffer_bytes: usize = 0,
    /// Releases refused by the guards in `release`. Each one is a caller bug,
    /// such as a stale index, a double release or a free list already full,
    /// and the guard drops it to keep the pool consistent, so this count is
    /// the only trace left. An assertion would not do: in ReleaseFast it is a
    /// promise to the optimizer that the case never happens.
    release_rejected: u64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        connection_count: usize,
        max_buffers: usize,
        buffer_bytes: usize,
    ) !HeaderBufferPool {
        const buffer_count = @min(connection_count, max_buffers);
        const bytes = try allocator.alloc(u8, buffer_count * buffer_bytes);
        errdefer allocator.free(bytes);
        const free_slots = try allocator.alloc(u32, buffer_count);
        errdefer allocator.free(free_slots);
        const used_slots = try allocator.alloc(bool, buffer_count);
        errdefer allocator.free(used_slots);
        for (free_slots, 0..) |*slot, index|
            slot.* = @intCast(index);
        @memset(used_slots, false);
        return .{
            .bytes = bytes,
            .free_slots = free_slots,
            .used_slots = used_slots,
            .free_count = buffer_count,
            .buffer_bytes = buffer_bytes,
        };
    }

    pub fn deinit(self: *HeaderBufferPool, allocator: std.mem.Allocator) void {
        // The arrays are freed whether or not buffers are out. A buffer still
        // out here means a connection slot still holds its `buffer_index`,
        // which lane teardown (`deinitRuntime` in `ring_driver.zig`) asserts
        // against, next to the slab counts it must agree with.
        allocator.free(self.used_slots);
        allocator.free(self.free_slots);
        allocator.free(self.bytes);
        self.* = .{};
    }

    pub fn acquire(self: *HeaderBufferPool) ?u32 {
        if (self.free_count == 0)
            return null;
        self.free_count -= 1;
        const index = self.free_slots[self.free_count];
        std.debug.assert(index < self.used_slots.len);
        std.debug.assert(!self.used_slots[index]);
        self.used_slots[index] = true;
        return index;
    }

    pub fn release(self: *HeaderBufferPool, index: u32) void {
        if (index == ingress_state.invalid_slot)
            return;
        // These three guards are the release path's only protection, and none
        // may assert the negation of what it tests. In ReleaseFast such an
        // assertion is a promise to the optimizer, which then deletes the
        // guard's body with its `return`, and the rejected index or count
        // reaches the writes below as an out-of-bounds write in the server,
        // the process nothing supervises.
        if (index >= self.free_slots.len) {
            self.release_rejected += 1;
            return;
        }
        if (!self.used_slots[index]) {
            self.release_rejected += 1;
            return;
        }
        if (self.free_count >= self.free_slots.len) {
            self.release_rejected += 1;
            return;
        }
        self.used_slots[index] = false;
        self.free_slots[self.free_count] = index;
        self.free_count += 1;
    }

    pub fn buffer(self: *HeaderBufferPool, index: u32) []u8 {
        std.debug.assert(index < self.free_slots.len);
        std.debug.assert(self.used_slots[index]);
        const start = @as(usize, index) * self.buffer_bytes;
        return self.bytes[start .. start + self.buffer_bytes];
    }
};

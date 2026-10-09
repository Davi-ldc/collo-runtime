//! The request deadline wheel of one ingress lane, owned and driven by the
//! lane thread: each dispatched request's deadline sits in one bucket of a
//! ring that advances one `tick_ns` per bucket, and the lane's deadline
//! timer fires at the next wake the wheel computes.
//!
//! Invariants:
//! - No entry expires before its absolute deadline. A bucket visit files an
//!   entry with rounds left, or with a deadline still ahead, back into the
//!   bucket.
//! - Entries and buckets are allocated once at init, so inserting never
//!   allocates. `IngressLane` gives the wheel one entry per request slot.
//! - A handle carries its entry's generation, so cancelling after the entry
//!   expired or was reused changes nothing.
//! - While entries are armed, the wheel's clock moves only in `expireDue`,
//!   one tick at a time; an empty wheel jumps to the current time on its
//!   next insert.

const std = @import("std");
const ingress_state = @import("state.zig");

/// Deadline resolution: a deadline fires on the first tick at or after it.
pub const tick_ns: u64 = 5 * std.time.ns_per_ms;
pub const fallback_grace_ns: u64 = 50 * std.time.ns_per_ms;
pub const minimum_slots: usize = 1024;
const invalid_index: u32 = ingress_state.invalid_slot;

pub const Handle = struct {
    slot: u32,
    generation: u64,
};

pub const Expired = struct {
    request_key: ingress_state.RequestKey,
    connection_key: ingress_state.ConnectionKey,
    worker_key: ingress_state.WorkerKey,
    deadline_monotonic_ns: u64,
};

pub const Counters = struct {
    inserts: u64 = 0,
    cancels: u64 = 0,
    expirations: u64 = 0,
    stale_cancels: u64 = 0,
    stale_timers: u64 = 0,
    overfull_due_drains: u64 = 0,
    armed_transitions: u64 = 0,
    disarmed_transitions: u64 = 0,
};

const Entry = struct {
    generation: u64 = 1,
    active: bool = false,
    cancelled: bool = false,
    next_free: u32 = invalid_index,
    bucket: u32 = invalid_index,
    next: u32 = invalid_index,
    prev: u32 = invalid_index,
    rounds_remaining: u64 = 0,
    request_key: ingress_state.RequestKey = .{ .lane_id = 0, .slot = 0, .generation = 0 },
    connection_key: ingress_state.ConnectionKey = .{ .lane_id = 0, .slot = 0, .generation = 0 },
    worker_key: ingress_state.WorkerKey = .{ .worker_id = 0, .worker_generation = 0 },
    deadline_monotonic_ns: u64 = 0,
};

pub fn entrySizeBytes() usize {
    return @sizeOf(Entry);
}

pub const DeadlineWheel = struct {
    allocator: std.mem.Allocator,
    entries: []Entry,
    buckets: []u32,
    free_head: u32,
    free_len: usize,
    cursor: u32 = 0,
    current_time_ns: u64,
    pending_due_head: u32 = invalid_index,
    pending_due_tail: u32 = invalid_index,
    active_len: usize = 0,
    armed: bool = false,
    next_deadline_monotonic_ns: ?u64 = null,
    next_deadline_dirty: bool = false,
    counters: Counters = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        capacity: usize,
        slot_count: usize,
        now_monotonic_ns: u64,
    ) !DeadlineWheel {
        if (capacity == 0 or capacity > std.math.maxInt(u32))
            return error.InvalidDeadlineCapacity;
        if (slot_count < minimum_slots or slot_count > std.math.maxInt(u32))
            return error.InvalidDeadlineWheelSlots;
        const entries = try allocator.alloc(Entry, capacity);
        errdefer allocator.free(entries);
        const buckets = try allocator.alloc(u32, slot_count);
        errdefer allocator.free(buckets);
        @memset(buckets, invalid_index);
        for (entries, 0..) |*entry, index| {
            entry.* = .{
                .generation = 1,
                .next_free = if (index + 1 < capacity) @intCast(index + 1) else invalid_index,
            };
        }
        return .{
            .allocator = allocator,
            .entries = entries,
            .buckets = buckets,
            .free_head = 0,
            .free_len = capacity,
            .current_time_ns = now_monotonic_ns,
        };
    }

    pub fn deinit(self: *DeadlineWheel) void {
        // Like the slabs, the wheel frees its arrays whether or not entries
        // are live. A live entry means a request slot still holds its handle,
        // which lane teardown asserts against (`deinitRuntime` in
        // `runner/ring_driver.zig`).
        self.allocator.free(self.buckets);
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    /// Arms `absolute_deadline_ns` for a request and returns the handle that
    /// cancels it. Fails with `error.DeadlineWheelFull` when every entry is
    /// armed.
    pub fn insert(
        self: *DeadlineWheel,
        request_key: ingress_state.RequestKey,
        connection_key: ingress_state.ConnectionKey,
        worker_key: ingress_state.WorkerKey,
        now_monotonic_ns: u64,
        absolute_deadline_ns: u64,
    ) !Handle {
        if (self.free_head == invalid_index)
            return error.DeadlineWheelFull;
        self.syncIdleClock(now_monotonic_ns);

        const entry_index = self.free_head;
        const entry = &self.entries[entry_index];
        self.free_head = entry.next_free;
        self.free_len -= 1;

        const delta_ns = absolute_deadline_ns -| self.current_time_ns;
        const ticks_from_now = @max(@as(u64, 1), ceilDiv(delta_ns, tick_ns));
        const bucket: u32 = @intCast((@as(u64, self.cursor) + ticks_from_now) % self.buckets.len);
        const rounds = (ticks_from_now - 1) / self.buckets.len;
        entry.* = .{
            .generation = entry.generation,
            .active = true,
            .cancelled = false,
            .bucket = bucket,
            .rounds_remaining = rounds,
            .request_key = request_key,
            .connection_key = connection_key,
            .worker_key = worker_key,
            .deadline_monotonic_ns = absolute_deadline_ns,
        };
        self.push(bucket, entry_index);
        self.active_len += 1;
        self.counters.inserts += 1;
        self.noteInsertedDeadline(absolute_deadline_ns);
        self.setArmed(true);
        return .{ .slot = entry_index, .generation = entry.generation };
    }

    /// Disarms the entry `handle` names; false when the handle is stale.
    pub fn cancel(self: *DeadlineWheel, handle: Handle) bool {
        const entry = self.entryForHandle(handle) orelse {
            self.counters.stale_cancels += 1;
            return false;
        };
        if (entry.cancelled) {
            self.counters.stale_cancels += 1;
            return false;
        }
        entry.cancelled = true;
        self.unlink(handle.slot);
        self.releaseEntry(handle.slot);
        self.counters.cancels += 1;
        self.maybeDisarm();
        return true;
    }

    /// Advances the wheel's clock toward `now_monotonic_ns` one tick at a time
    /// and writes up to `out.len` expired entries, which leave the wheel.
    /// Entries due past `out.len` wait in a pending list that the next call
    /// drains first, so none is lost.
    pub fn expireDue(self: *DeadlineWheel, now_monotonic_ns: u64, out: []Expired) usize {
        var emitted: usize = 0;
        emitted += self.drainPendingDue(out[emitted..]);
        while (emitted < out.len and self.active_len != 0 and self.current_time_ns +| tick_ns <= now_monotonic_ns) {
            self.current_time_ns +|= tick_ns;
            self.cursor = @intCast((@as(u64, self.cursor) + 1) % self.buckets.len);
            emitted += self.expireBucket(out[emitted..]);
            emitted += self.drainPendingDue(out[emitted..]);
        }
        self.maybeDisarm();
        return emitted;
    }

    /// When the lane's deadline timer should fire next: now while expired
    /// entries are still pending, otherwise the earliest deadline rounded up
    /// to a tick and capped at one revolution of the wheel ahead. Null when no
    /// deadline is armed.
    pub fn nextWakeDeadlineNs(self: *DeadlineWheel, now_monotonic_ns: u64) ?u64 {
        if (self.pending_due_head != invalid_index)
            return now_monotonic_ns;

        const deadline_monotonic_ns = self.nextDeadlineNs() orelse return null;
        const delta_ns = deadline_monotonic_ns -| self.current_time_ns;
        const ticks_until_deadline = @max(@as(u64, 1), ceilDiv(delta_ns, tick_ns));
        const deadline_wake_ns = self.current_time_ns +| (ticks_until_deadline *| tick_ns);
        const maintenance_wake_ns = self.current_time_ns +|
            (@as(u64, self.buckets.len) *| tick_ns);
        const wake_monotonic_ns = @min(deadline_wake_ns, maintenance_wake_ns);
        if (wake_monotonic_ns < now_monotonic_ns)
            return now_monotonic_ns;
        return wake_monotonic_ns;
    }

    pub fn isEmpty(self: *const DeadlineWheel) bool {
        return self.active_len == 0;
    }

    fn expireBucket(self: *DeadlineWheel, out: []Expired) usize {
        var emitted: usize = 0;
        var index = self.buckets[self.cursor];
        self.buckets[self.cursor] = invalid_index;
        while (index != invalid_index) {
            const next = self.entries[index].next;
            const entry = &self.entries[index];
            entry.next = invalid_index;
            entry.prev = invalid_index;
            if (entry.cancelled) {
                self.releaseEntry(index);
            } else if (entry.rounds_remaining != 0) {
                entry.rounds_remaining -= 1;
                self.push(self.cursor, index);
            } else if (entry.deadline_monotonic_ns > self.current_time_ns) {
                self.push(self.cursor, index);
            } else {
                if (emitted < out.len) {
                    out[emitted] = self.expiredFromEntry(entry);
                    emitted += 1;
                    self.counters.expirations += 1;
                    self.releaseEntry(index);
                } else {
                    self.enqueuePendingDue(index);
                    self.counters.overfull_due_drains += 1;
                }
            }
            index = next;
        }
        return emitted;
    }

    fn drainPendingDue(self: *DeadlineWheel, out: []Expired) usize {
        var emitted: usize = 0;
        while (self.pending_due_head != invalid_index and emitted < out.len) {
            const index = self.pending_due_head;
            const entry = &self.entries[index];
            self.pending_due_head = entry.next;
            if (self.pending_due_head == invalid_index)
                self.pending_due_tail = invalid_index;
            entry.next = invalid_index;
            entry.prev = invalid_index;
            if (entry.cancelled) {
                self.releaseEntry(index);
                continue;
            }
            if (entry.deadline_monotonic_ns > self.current_time_ns) {
                self.push(self.cursor, index);
                continue;
            }
            out[emitted] = self.expiredFromEntry(entry);
            emitted += 1;
            self.counters.expirations += 1;
            self.releaseEntry(index);
        }
        return emitted;
    }

    fn enqueuePendingDue(self: *DeadlineWheel, index: u32) void {
        const entry = &self.entries[index];
        entry.bucket = invalid_index;
        entry.prev = self.pending_due_tail;
        entry.next = invalid_index;
        if (self.pending_due_tail == invalid_index)
            self.pending_due_head = index
        else
            self.entries[self.pending_due_tail].next = index;
        self.pending_due_tail = index;
    }

    fn expiredFromEntry(_: *DeadlineWheel, entry: *const Entry) Expired {
        return .{
            .request_key = entry.request_key,
            .connection_key = entry.connection_key,
            .worker_key = entry.worker_key,
            .deadline_monotonic_ns = entry.deadline_monotonic_ns,
        };
    }

    fn push(self: *DeadlineWheel, bucket: u32, index: u32) void {
        const old_head = self.buckets[bucket];
        const entry = &self.entries[index];
        entry.bucket = bucket;
        entry.prev = invalid_index;
        entry.next = old_head;
        if (old_head != invalid_index)
            self.entries[old_head].prev = index;
        self.buckets[bucket] = index;
    }

    fn unlink(self: *DeadlineWheel, index: u32) void {
        const entry = &self.entries[index];
        if (entry.bucket == invalid_index) {
            self.unlinkPendingDue(index);
            return;
        }
        if (entry.prev != invalid_index)
            self.entries[entry.prev].next = entry.next
        else
            self.buckets[entry.bucket] = entry.next;
        if (entry.next != invalid_index)
            self.entries[entry.next].prev = entry.prev;
        entry.bucket = invalid_index;
        entry.next = invalid_index;
        entry.prev = invalid_index;
    }

    fn unlinkPendingDue(self: *DeadlineWheel, index: u32) void {
        const entry = &self.entries[index];
        std.debug.assert(entry.active);
        std.debug.assert(entry.bucket == invalid_index);
        std.debug.assert(self.pending_due_head != invalid_index);
        if (entry.prev != invalid_index) {
            self.entries[entry.prev].next = entry.next;
        } else {
            std.debug.assert(self.pending_due_head == index);
            self.pending_due_head = entry.next;
        }
        if (entry.next != invalid_index) {
            self.entries[entry.next].prev = entry.prev;
        } else {
            std.debug.assert(self.pending_due_tail == index);
            self.pending_due_tail = entry.prev;
        }
        entry.next = invalid_index;
        entry.prev = invalid_index;
    }

    fn releaseEntry(self: *DeadlineWheel, index: u32) void {
        const entry = &self.entries[index];
        self.noteRemovedDeadline(entry.deadline_monotonic_ns);
        entry.* = .{
            .generation = ingress_state.nextGeneration(entry.generation),
            .active = false,
            .next_free = self.free_head,
        };
        self.free_head = index;
        self.free_len += 1;
        std.debug.assert(self.active_len > 0);
        self.active_len -= 1;
    }

    fn syncIdleClock(self: *DeadlineWheel, now_monotonic_ns: u64) void {
        if (self.active_len != 0)
            return;
        if (now_monotonic_ns <= self.current_time_ns)
            return;
        self.current_time_ns = now_monotonic_ns;
    }

    fn noteInsertedDeadline(self: *DeadlineWheel, deadline_monotonic_ns: u64) void {
        if (self.next_deadline_dirty)
            return;
        if (self.next_deadline_monotonic_ns) |current| {
            if (deadline_monotonic_ns < current)
                self.next_deadline_monotonic_ns = deadline_monotonic_ns;
        } else {
            self.next_deadline_monotonic_ns = deadline_monotonic_ns;
        }
    }

    fn noteRemovedDeadline(self: *DeadlineWheel, deadline_monotonic_ns: u64) void {
        if (self.next_deadline_monotonic_ns) |current| {
            if (deadline_monotonic_ns == current)
                self.next_deadline_dirty = true;
        }
    }

    fn nextDeadlineNs(self: *DeadlineWheel) ?u64 {
        if (!self.next_deadline_dirty)
            return self.next_deadline_monotonic_ns;
        self.next_deadline_monotonic_ns = self.recomputeNextDeadlineNs();
        self.next_deadline_dirty = false;
        return self.next_deadline_monotonic_ns;
    }

    fn recomputeNextDeadlineNs(self: *DeadlineWheel) ?u64 {
        var best: ?u64 = null;
        var active_count: usize = 0;
        for (self.buckets) |head|
            self.scanNextDeadlineList(head, &best, &active_count);
        self.scanNextDeadlineList(self.pending_due_head, &best, &active_count);
        std.debug.assert(active_count == self.active_len);
        return best;
    }

    fn scanNextDeadlineList(
        self: *DeadlineWheel,
        head: u32,
        best: *?u64,
        active_count: *usize,
    ) void {
        var index = head;
        var inspected: usize = 0;
        while (index != invalid_index) {
            std.debug.assert(inspected < self.entries.len);
            const entry = &self.entries[index];
            std.debug.assert(entry.active);
            if (!entry.cancelled) {
                active_count.* += 1;
                if (best.*) |current| {
                    if (entry.deadline_monotonic_ns < current)
                        best.* = entry.deadline_monotonic_ns;
                } else {
                    best.* = entry.deadline_monotonic_ns;
                }
            }
            inspected += 1;
            index = entry.next;
        }
    }

    fn entryForHandle(self: *DeadlineWheel, handle: Handle) ?*Entry {
        if (handle.slot >= self.entries.len)
            return null;
        const entry = &self.entries[handle.slot];
        if (!entry.active or entry.generation != handle.generation)
            return null;
        return entry;
    }

    fn setArmed(self: *DeadlineWheel, armed: bool) void {
        if (self.armed == armed)
            return;
        self.armed = armed;
        if (armed)
            self.counters.armed_transitions += 1
        else
            self.counters.disarmed_transitions += 1;
    }

    fn maybeDisarm(self: *DeadlineWheel) void {
        if (self.active_len == 0 and self.pending_due_head == invalid_index) {
            self.next_deadline_monotonic_ns = null;
            self.next_deadline_dirty = false;
            self.setArmed(false);
        }
    }
};

fn ceilDiv(numerator: u64, denominator: u64) u64 {
    if (numerator == 0)
        return 0;
    return (numerator - 1) / denominator + 1;
}

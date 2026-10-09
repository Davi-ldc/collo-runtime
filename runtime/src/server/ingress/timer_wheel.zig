//! The request deadline wheel of one ingress lane, owned and driven by the
//! lane thread: each dispatched request's deadline sits in one bucket of a
//! ring that advances one `tick_ns` per bucket, and the lane's deadline
//! timer fires at the next wake the wheel computes.
//!
//! Invariants:
//! - No entry expires before its absolute deadline. A bucket visit files an
//!   entry with rounds left, or with a deadline still ahead, back into the
//!   bucket.
//! - Entries live in a fault-in slab and buckets are allocated once at init,
//!   so inserting never allocates. `IngressLane` gives the wheel one entry
//!   per request the lane can hold.
//! - A handle carries its entry's generation, so cancelling after the entry
//!   expired or was reused changes nothing.
//! - While entries are armed, the wheel's clock moves only in `expireDue`,
//!   one tick at a time; an empty wheel jumps to the current time on its
//!   next insert.

const std = @import("std");
const lifecycle = @import("collo_server_lifecycle");
const slab = @import("slab.zig");

/// Deadline resolution: a deadline fires on the first tick at or after it.
pub const tick_ns: u64 = 5 * std.time.ns_per_ms;
pub const minimum_slots: usize = 1024;
const invalid_index: u32 = slab.none;

pub const Handle = struct {
    slot: u32,
    generation: u64,
};

pub const Expired = struct {
    request_key: lifecycle.RequestKey,
    connection_key: lifecycle.ConnectionKey,
    worker_key: lifecycle.WorkerKey,
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
    slab_link: slab.Link = .{},
    bucket: u32 = invalid_index,
    next: u32 = invalid_index,
    prev: u32 = invalid_index,
    rounds_remaining: u64 = 0,
    request_key: lifecycle.RequestKey = .{ .lane_id = 0, .slot = 0, .generation = 0 },
    connection_key: lifecycle.ConnectionKey = .{ .lane_id = 0, .slot = 0, .generation = 0 },
    worker_key: lifecycle.WorkerKey = .{ .worker_id = 0, .worker_generation = 0 },
    deadline_monotonic_ns: u64 = 0,
};

pub fn entrySizeBytes() usize {
    return @sizeOf(Entry);
}

pub const DeadlineWheel = struct {
    allocator: std.mem.Allocator,
    entries: slab.FaultInSlab(Entry),
    buckets: []u32,
    cursor: u32 = 0,
    current_time_ns: u64,
    pending_due_head: u32 = invalid_index,
    pending_due_tail: u32 = invalid_index,
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
        if (capacity == 0 or capacity >= std.math.maxInt(u32))
            return error.InvalidDeadlineCapacity;
        if (slot_count < minimum_slots or slot_count > std.math.maxInt(u32))
            return error.InvalidDeadlineWheelSlots;
        var entries = try slab.FaultInSlab(Entry).init(@intCast(capacity));
        errdefer entries.deinit();
        const buckets = try allocator.alloc(u32, slot_count);
        errdefer allocator.free(buckets);
        @memset(buckets, invalid_index);
        return .{
            .allocator = allocator,
            .entries = entries,
            .buckets = buckets,
            .current_time_ns = now_monotonic_ns,
        };
    }

    pub fn deinit(self: *DeadlineWheel) void {
        // Like the slabs, the wheel frees its arrays whether or not entries
        // are live. A live entry means a request slot still holds its handle,
        // which lane teardown asserts against (`deinitRuntime` in
        // `runner/ring_driver.zig`).
        self.allocator.free(self.buckets);
        self.entries.deinit();
        self.* = undefined;
    }

    /// Entries armed now, those due and waiting in the pending list included.
    /// A cancel releases its entry at once.
    pub fn liveEntries(self: *const DeadlineWheel) u32 {
        return self.entries.live_count;
    }

    /// Arms `absolute_deadline_ns` for a request and returns the handle that
    /// cancels it. Fails with `error.DeadlineWheelFull` when every entry is
    /// armed.
    pub fn insert(
        self: *DeadlineWheel,
        request_key: lifecycle.RequestKey,
        connection_key: lifecycle.ConnectionKey,
        worker_key: lifecycle.WorkerKey,
        now_monotonic_ns: u64,
        absolute_deadline_ns: u64,
    ) !Handle {
        self.syncIdleClock(now_monotonic_ns);
        const acquired = self.entries.acquire() orelse return error.DeadlineWheelFull;
        const entry = acquired.entry;

        const delta_ns = absolute_deadline_ns -| self.current_time_ns;
        const ticks_from_now = @max(@as(u64, 1), ceilDiv(delta_ns, tick_ns));
        const bucket: u32 = @intCast((@as(u64, self.cursor) + ticks_from_now) % self.buckets.len);
        const rounds = (ticks_from_now - 1) / self.buckets.len;
        entry.bucket = bucket;
        entry.rounds_remaining = rounds;
        entry.request_key = request_key;
        entry.connection_key = connection_key;
        entry.worker_key = worker_key;
        entry.deadline_monotonic_ns = absolute_deadline_ns;
        self.push(bucket, acquired.index);
        self.counters.inserts += 1;
        self.noteInsertedDeadline(absolute_deadline_ns);
        self.setArmed(true);
        return .{ .slot = acquired.index, .generation = acquired.generation };
    }

    /// Disarms the entry `handle` names and releases it; false when the
    /// handle is stale, because the entry expired, was cancelled or was
    /// handed out again.
    pub fn cancel(self: *DeadlineWheel, handle: Handle) bool {
        if (self.entryForHandle(handle) == null) {
            self.counters.stale_cancels += 1;
            return false;
        }
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
        while (emitted < out.len and self.liveEntries() != 0 and self.current_time_ns +| tick_ns <= now_monotonic_ns) {
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
        return self.liveEntries() == 0;
    }

    fn expireBucket(self: *DeadlineWheel, out: []Expired) usize {
        var emitted: usize = 0;
        var index = self.buckets[self.cursor];
        self.buckets[self.cursor] = invalid_index;
        while (index != invalid_index) {
            const entry = self.at(index);
            const next = entry.next;
            entry.next = invalid_index;
            entry.prev = invalid_index;
            if (entry.rounds_remaining != 0) {
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
            const entry = self.at(index);
            self.pending_due_head = entry.next;
            if (self.pending_due_head == invalid_index)
                self.pending_due_tail = invalid_index;
            entry.next = invalid_index;
            entry.prev = invalid_index;
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
        const entry = self.at(index);
        entry.bucket = invalid_index;
        entry.prev = self.pending_due_tail;
        entry.next = invalid_index;
        if (self.pending_due_tail == invalid_index)
            self.pending_due_head = index
        else
            self.at(self.pending_due_tail).next = index;
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
        const entry = self.at(index);
        entry.bucket = bucket;
        entry.prev = invalid_index;
        entry.next = old_head;
        if (old_head != invalid_index)
            self.at(old_head).prev = index;
        self.buckets[bucket] = index;
    }

    fn unlink(self: *DeadlineWheel, index: u32) void {
        const entry = self.at(index);
        if (entry.bucket == invalid_index) {
            self.unlinkPendingDue(index);
            return;
        }
        if (entry.prev != invalid_index)
            self.at(entry.prev).next = entry.next
        else
            self.buckets[entry.bucket] = entry.next;
        if (entry.next != invalid_index)
            self.at(entry.next).prev = entry.prev;
        entry.bucket = invalid_index;
        entry.next = invalid_index;
        entry.prev = invalid_index;
    }

    fn unlinkPendingDue(self: *DeadlineWheel, index: u32) void {
        const entry = self.at(index);
        std.debug.assert(entry.slab_link.live);
        std.debug.assert(entry.bucket == invalid_index);
        std.debug.assert(self.pending_due_head != invalid_index);
        if (entry.prev != invalid_index) {
            self.at(entry.prev).next = entry.next;
        } else {
            std.debug.assert(self.pending_due_head == index);
            self.pending_due_head = entry.next;
        }
        if (entry.next != invalid_index) {
            self.at(entry.next).prev = entry.prev;
        } else {
            std.debug.assert(self.pending_due_tail == index);
            self.pending_due_tail = entry.prev;
        }
        entry.next = invalid_index;
        entry.prev = invalid_index;
    }

    fn releaseEntry(self: *DeadlineWheel, index: u32) void {
        self.noteRemovedDeadline(self.at(index).deadline_monotonic_ns);
        self.entries.release(index);
    }

    fn syncIdleClock(self: *DeadlineWheel, now_monotonic_ns: u64) void {
        if (self.liveEntries() != 0)
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
        std.debug.assert(active_count == self.liveEntries());
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
            std.debug.assert(inspected < self.entries.high_water);
            const entry = self.at(index);
            std.debug.assert(entry.slab_link.live);
            active_count.* += 1;
            if (best.*) |current| {
                if (entry.deadline_monotonic_ns < current)
                    best.* = entry.deadline_monotonic_ns;
            } else {
                best.* = entry.deadline_monotonic_ns;
            }
            inspected += 1;
            index = entry.next;
        }
    }

    fn entryForHandle(self: *DeadlineWheel, handle: Handle) ?*Entry {
        return switch (self.entries.lookup(handle.slot, handle.generation)) {
            .live => |entry| entry,
            .stale_generation, .vacant, .out_of_range => null,
        };
    }

    fn at(self: *DeadlineWheel, index: u32) *Entry {
        return &self.entries.entries[index];
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
        if (self.liveEntries() == 0 and self.pending_due_head == invalid_index) {
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

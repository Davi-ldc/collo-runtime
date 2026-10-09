//! The worker sessions the gateway must drop, each queued once. The gateway's loop thread owns the
//! queue through `worker_registry.Registry`.
//!
//! Marking never fails. When the heap queue cannot grow, the session goes into a fixed ring of
//! `forced_capacity` entries; when that ring is full as well, the session id is lost and the
//! queue records an overflow, so the registry drops every attached worker instead
//! (`worker_registry.Registry.nextDrop`). An overflow costs healthy sessions too, but it never
//! leaves a marked one attached.

const std = @import("std");

const forced_capacity: usize = 64;

pub const Queue = struct {
    items: std.array_list.Aligned(u64, null) = .empty,
    pending: std.AutoHashMapUnmanaged(u64, void) = .empty,
    head: usize = 0,
    forced: [forced_capacity]u64 = undefined,
    forced_head: usize = 0,
    forced_count: usize = 0,
    forced_overflowed: bool = false,

    pub fn deinit(self: *Queue, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
        self.pending.deinit(allocator);
        self.* = undefined;
    }

    pub fn mark(self: *Queue, allocator: std.mem.Allocator, worker_session_id: u64) void {
        if (self.forcedContains(worker_session_id))
            return;
        if (self.pending.contains(worker_session_id))
            return;

        self.pending.put(allocator, worker_session_id, {}) catch {
            self.pushForced(worker_session_id);
            return;
        };
        self.items.append(allocator, worker_session_id) catch {
            _ = self.pending.remove(worker_session_id);
            self.pushForced(worker_session_id);
            return;
        };
    }

    pub fn next(self: *Queue) ?u64 {
        if (self.popForced()) |worker_session_id|
            return worker_session_id;
        if (self.head >= self.items.items.len) {
            self.reset();
            return null;
        }

        const worker_session_id = self.items.items[self.head];
        self.head += 1;
        _ = self.pending.remove(worker_session_id);
        self.compactIfUseful();
        return worker_session_id;
    }

    pub fn len(self: *const Queue) usize {
        return self.items.items.len - self.head + self.forced_count +
            @intFromBool(self.forced_overflowed);
    }

    /// Whether a session was lost to a full fixed ring since the last call; clears the flag. The
    /// caller must then drop every attached worker, since the lost session is not known.
    pub fn takeForcedOverflow(self: *Queue) bool {
        const overflowed = self.forced_overflowed;
        self.forced_overflowed = false;
        return overflowed;
    }

    fn reset(self: *Queue) void {
        self.items.clearRetainingCapacity();
        self.head = 0;
    }

    fn compactIfUseful(self: *Queue) void {
        if (self.head < 1024)
            return;
        if (self.head * 2 < self.items.items.len)
            return;
        const remaining = self.items.items[self.head..];
        std.mem.copyForwards(u64, self.items.items[0..remaining.len], remaining);
        self.items.shrinkRetainingCapacity(remaining.len);
        self.head = 0;
    }

    fn forcedContains(self: *const Queue, worker_session_id: u64) bool {
        var index: usize = 0;
        while (index < self.forced_count) : (index += 1) {
            const slot = (self.forced_head + index) % self.forced.len;
            if (self.forced[slot] == worker_session_id)
                return true;
        }
        return false;
    }

    fn pushForced(self: *Queue, worker_session_id: u64) void {
        if (self.forcedContains(worker_session_id))
            return;
        if (self.forced_count == self.forced.len) {
            self.forced_overflowed = true;
            return;
        }
        const tail = (self.forced_head + self.forced_count) % self.forced.len;
        self.forced[tail] = worker_session_id;
        self.forced_count += 1;
    }

    fn popForced(self: *Queue) ?u64 {
        if (self.forced_count == 0)
            return null;
        const worker_session_id = self.forced[self.forced_head];
        self.forced_head = (self.forced_head + 1) % self.forced.len;
        self.forced_count -= 1;
        if (self.forced_count == 0)
            self.forced_head = 0;
        return worker_session_id;
    }
};

/// Lets `egress/tests/gateway/runtime.zig` fill the fixed ring without failing an allocation.
pub const testing = struct {
    pub const forcedQueueCapacity = forced_capacity;

    pub fn pushForced(queue: *Queue, worker_session_id: u64) void {
        queue.pushForced(worker_session_id);
    }
};

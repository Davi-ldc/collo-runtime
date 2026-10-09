//! The min-heap of armed request deadlines, owned by the runtime's scheduler
//! state on the worker's VM thread. Its capacity is fixed at init and it
//! never grows. Entries are not removed when a request finishes or re-arms:
//! the reader drops an entry unless its id, generation and due time still
//! match a request whose deadline is armed and not yet queued
//! (`validRequestDeadline` in `resources.zig`). Equal due times order by
//! request id, so the order never depends on insertion.

const std = @import("std");

pub const Entry = struct {
    request_id: u64,
    request_generation: u64,
    due_mono_ns: u64,
};

pub const DeadlineHeap = struct {
    allocator: std.mem.Allocator,
    entries: []Entry,
    len: usize = 0,

    /// Allocates room for `capacity` entries. Fails with
    /// `error.InvalidCapacity` for zero, or with OutOfMemory.
    pub fn initCapacity(allocator: std.mem.Allocator, capacity: usize) !DeadlineHeap {
        if (capacity == 0)
            return error.InvalidCapacity;
        return .{
            .allocator = allocator,
            .entries = try allocator.alloc(Entry, capacity),
        };
    }

    pub fn deinit(self: *DeadlineHeap) void {
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    /// Fails with `error.DeadlineHeapFull` at capacity; the caller may drop
    /// stale entries and retry.
    pub fn push(self: *DeadlineHeap, entry: Entry) !void {
        if (self.len == self.entries.len)
            return error.DeadlineHeapFull;
        var index = self.len;
        self.len += 1;
        while (index != 0) {
            const parent = (index - 1) / 2;
            if (!less(entry, self.entries[parent]))
                break;
            self.entries[index] = self.entries[parent];
            index = parent;
        }
        self.entries[index] = entry;
    }

    pub fn peek(self: *const DeadlineHeap) ?Entry {
        if (self.len == 0)
            return null;
        return self.entries[0];
    }

    pub fn popMin(self: *DeadlineHeap) ?Entry {
        if (self.len == 0)
            return null;
        const result = self.entries[0];
        self.len -= 1;
        if (self.len != 0)
            self.siftDown(0, self.entries[self.len]);
        return result;
    }

    /// Removes the entry at heap position `index`, which must be below
    /// `len`. The last entry moves into the hole and sifts up or down.
    pub fn removeAt(self: *DeadlineHeap, index: usize) void {
        std.debug.assert(index < self.len);
        self.len -= 1;
        if (index == self.len)
            return;
        const replacement = self.entries[self.len];
        if (index != 0 and less(replacement, self.entries[(index - 1) / 2])) {
            var cursor = index;
            while (cursor != 0) {
                const parent = (cursor - 1) / 2;
                if (!less(replacement, self.entries[parent]))
                    break;
                self.entries[cursor] = self.entries[parent];
                cursor = parent;
            }
            self.entries[cursor] = replacement;
        } else {
            self.siftDown(index, replacement);
        }
    }

    fn siftDown(self: *DeadlineHeap, start_index: usize, value: Entry) void {
        var index = start_index;
        while (true) {
            const left = index * 2 + 1;
            if (left >= self.len)
                break;
            const right = left + 1;
            var child = left;
            if (right < self.len and less(self.entries[right], self.entries[left]))
                child = right;
            if (!less(self.entries[child], value))
                break;
            self.entries[index] = self.entries[child];
            index = child;
        }
        self.entries[index] = value;
    }
};

fn less(a: Entry, b: Entry) bool {
    if (a.due_mono_ns == b.due_mono_ns)
        return a.request_id < b.request_id;
    return a.due_mono_ns < b.due_mono_ns;
}

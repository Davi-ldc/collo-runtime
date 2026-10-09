//! The setImmediate queue and the execution of its callbacks, on the worker's
//! VM thread. Immediates run in batches: an immediate scheduled while a
//! batch runs gets the next generation, so a callback that keeps scheduling
//! itself lets the loop serve other events between batches. The queue is a
//! slab of `RuntimeLimits.max_timers_per_worker` slots allocated at init
//! that never grows.

const std = @import("std");
const callbacks = @import("callbacks.zig");
const js_value = @import("collo_worker_js").value;

pub const ImmediateEntry = struct {
    id: u64,
    request_id: u64,
    generation: u64,
    /// When setImmediate was called, which is when the callback became
    /// ready. It survives a return to the pending queue after a full ready
    /// queue, so the request's io interval closes at scheduling time.
    scheduled_at_mono_ns: u64 = 0,
    callback: js_value.JsFunctionOwned,
    /// The Immediate object setImmediate returned, passed as `this` and
    /// marked destroyed when the callback runs or is cancelled.
    this_arg: ?js_value.JsValueOwned = null,
    args: ?[]js_value.JsValueOwned = null,

    pub fn deinit(self: *ImmediateEntry, allocator: std.mem.Allocator) void {
        self.callback.deinit();
        if (self.this_arg) |*this_arg|
            this_arg.deinit();
        if (self.args) |args| {
            for (args) |*arg|
                arg.deinit();
            allocator.free(args);
        }
        self.* = undefined;
    }
};

const ImmediateNode = struct {
    entry: ImmediateEntry = undefined,
    active: bool = false,
    slot: usize = 0,
    previous: ?usize = null,
    next: ?usize = null,
};

pub const ImmediateQueue = struct {
    allocator: std.mem.Allocator,
    nodes: []ImmediateNode = &.{},
    free_slots: []usize = &.{},
    free_len: usize = 0,
    head: ?usize = null,
    tail: ?usize = null,

    pub fn initCapacity(allocator: std.mem.Allocator, initial_capacity: usize) !ImmediateQueue {
        var self = ImmediateQueue{
            .allocator = allocator,
        };
        errdefer self.deinit();

        self.nodes = try allocator.alloc(ImmediateNode, initial_capacity);
        for (self.nodes, 0..) |*node, index|
            node.* = .{ .slot = index };

        self.free_slots = try allocator.alloc(usize, initial_capacity);
        for (0..initial_capacity) |index|
            self.free_slots[index] = index;
        self.free_len = initial_capacity;

        return self;
    }

    pub fn deinit(self: *ImmediateQueue) void {
        for (self.nodes) |*node| {
            if (node.active)
                node.entry.deinit(self.allocator);
        }
        if (self.nodes.len != 0)
            self.allocator.free(self.nodes);
        if (self.free_slots.len != 0)
            self.allocator.free(self.free_slots);
        self.* = undefined;
    }

    pub fn reservedCount(self: *const ImmediateQueue) usize {
        std.debug.assert(self.free_len <= self.nodes.len);
        return self.nodes.len - self.free_len;
    }

    pub fn capacity(self: *const ImmediateQueue) usize {
        return self.nodes.len;
    }

    pub fn isEmpty(self: *const ImmediateQueue) bool {
        return self.head == null;
    }

    /// Appends `entry`, which the queue owns on success. Fails with
    /// `error.ImmediateQueueFull` when every slot is taken.
    pub fn push(self: *ImmediateQueue, entry: ImmediateEntry) !void {
        const slot = try self.acquireSlot();
        const node = &self.nodes[slot];
        node.entry = entry;
        node.active = true;
        node.previous = self.tail;
        node.next = null;

        if (self.tail) |tail_slot| {
            self.nodes[tail_slot].next = slot;
        } else {
            self.head = slot;
        }
        self.tail = slot;
    }

    /// Puts back, ahead of every other entry, one the collector took but
    /// could not queue, so the batch keeps its order. Fails like `push`.
    pub fn pushFront(self: *ImmediateQueue, entry: ImmediateEntry) !void {
        const slot = try self.acquireSlot();
        const node = &self.nodes[slot];
        node.entry = entry;
        node.active = true;
        node.previous = null;
        node.next = self.head;

        if (self.head) |head_slot| {
            self.nodes[head_slot].previous = slot;
        } else {
            self.tail = slot;
        }
        self.head = slot;
    }

    /// Removes the head entry when it belongs to `generation`, and returns
    /// null otherwise. Generations only grow along the queue, so the head
    /// holds the oldest one.
    pub fn popGeneration(self: *ImmediateQueue, generation: u64) ?ImmediateEntry {
        const slot = self.head orelse return null;
        const node = &self.nodes[slot];
        std.debug.assert(node.active);
        if (node.entry.generation != generation)
            return null;
        return self.removeNode(slot);
    }

    /// Frees the entry `immediate_id` if `request_id` scheduled it, without
    /// marking its Immediate object destroyed. Returns whether it was found.
    pub fn cancelByIdForRequest(
        self: *ImmediateQueue,
        immediate_id: u64,
        request_id: u64,
    ) bool {
        var entry = self.takeByIdForRequest(immediate_id, request_id) orelse return false;
        entry.deinit(self.allocator);
        return true;
    }

    /// Removes the entry `immediate_id` if `request_id` scheduled it and
    /// hands it to the caller. Scans every slot.
    pub fn takeByIdForRequest(
        self: *ImmediateQueue,
        immediate_id: u64,
        request_id: u64,
    ) ?ImmediateEntry {
        for (0..self.nodes.len) |slot| {
            const node = &self.nodes[slot];
            if (!node.active)
                continue;
            if (node.entry.id != immediate_id)
                continue;
            if (node.entry.request_id != request_id)
                continue;

            return self.removeNode(slot);
        }
        return null;
    }

    /// Frees every entry `request_id` scheduled, without marking their
    /// Immediate objects destroyed, and returns how many there were.
    pub fn cancelForRequest(self: *ImmediateQueue, request_id: u64) usize {
        var canceled: usize = 0;
        while (self.takeForRequest(request_id)) |entry| {
            var immediate = entry;
            immediate.deinit(self.allocator);
            canceled += 1;
        }
        return canceled;
    }

    /// Removes one entry `request_id` scheduled and hands it to the caller;
    /// null when none is left.
    pub fn takeForRequest(self: *ImmediateQueue, request_id: u64) ?ImmediateEntry {
        for (0..self.nodes.len) |slot| {
            const node = &self.nodes[slot];
            if (!node.active)
                continue;
            if (node.entry.request_id != request_id)
                continue;

            return self.removeNode(slot);
        }
        return null;
    }

    fn acquireSlot(self: *ImmediateQueue) !usize {
        if (self.free_len == 0)
            return error.ImmediateQueueFull;
        self.free_len -= 1;
        return self.free_slots[self.free_len];
    }

    fn removeNode(self: *ImmediateQueue, slot: usize) ImmediateEntry {
        const node = &self.nodes[slot];
        std.debug.assert(node.active);

        if (node.previous) |previous_slot| {
            self.nodes[previous_slot].next = node.next;
        } else {
            self.head = node.next;
        }

        if (node.next) |next_slot| {
            self.nodes[next_slot].previous = node.previous;
        } else {
            self.tail = node.previous;
        }

        const entry = node.entry;
        self.releaseSlot(node);
        return entry;
    }

    fn releaseSlot(self: *ImmediateQueue, node: *ImmediateNode) void {
        node.active = false;
        node.entry = undefined;
        node.previous = null;
        node.next = null;
        self.free_slots[self.free_len] = node.slot;
        self.free_len += 1;
    }
};

/// Runs the `.immediate_callback` work item: takes the entry out of the
/// ready map, marks its Immediate object destroyed, and calls the callback
/// in a turn of its request. An immediate cancelled after it was queued is
/// no longer in the map, and the item does nothing.
pub fn executeCallback(runtime: anytype, immediate_id: u64) !void {
    const removed = runtime.scheduler.ready_immediate_callbacks.fetchRemove(immediate_id) orelse return;
    var immediate = removed.value;
    defer immediate.deinit(runtime.core.allocator);

    markDestroyed(runtime, &immediate);
    try callbacks.invokeDiscard(
        runtime,
        immediate.request_id,
        &immediate.callback,
        if (immediate.this_arg) |*this_arg| this_arg.ptr() else null,
        immediate.args,
    );
}

/// Sets `_destroyed` on the entry's Immediate object, if it has one. A
/// failure only logs, because the entry is gone either way.
pub fn markDestroyed(runtime: anytype, immediate: *const ImmediateEntry) void {
    const this_arg = if (immediate.this_arg) |*value| value else return;
    runtime.core.vm.markImmediateDestroyed(this_arg.ptr()) catch |err| {
        std.log.warn("failed to mark immediate destroyed immediate_id={d}: {s}", .{
            immediate.id,
            @errorName(err),
        });
    };
}

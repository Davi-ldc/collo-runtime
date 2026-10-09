//! The timer heap and the execution of timer callbacks, on the worker's VM
//! thread. The timer host functions only hand timers to the runtime; this
//! file orders them by due time, breaking ties by timer id, and runs each
//! callback as a turn of the request that scheduled it. The heap is a slab of
//! `RuntimeLimits.max_timers_per_worker` slots allocated at init that never
//! grows.

const std = @import("std");
const common_io = @import("collo_common_io");
const callbacks = @import("callbacks.zig");
const js_value = @import("collo_worker_js").value;

pub const TimerEntry = struct {
    id: u64,
    request_id: u64,
    due_mono_ns: u64,
    /// The delay a repeating timer is re-armed with after each callback.
    delay_ms: u32 = 0,
    repeats: bool = false,
    callback: js_value.JsFunctionOwned,
    args: ?[]js_value.JsValueOwned = null,

    pub fn deinit(self: *TimerEntry, allocator: std.mem.Allocator) void {
        self.callback.deinit();
        if (self.args) |args| {
            for (args) |*arg|
                arg.deinit();
            allocator.free(args);
        }
        self.* = undefined;
    }
};

const TimerNode = struct {
    heap: common_io.heap.IntrusiveHeapField(TimerNode) = .{},
    entry: TimerEntry = undefined,
    active: bool = false,
    slot: usize = 0,
};

fn timerNodeLess(_: void, a: *const TimerNode, b: *const TimerNode) bool {
    return if (a.entry.due_mono_ns == b.entry.due_mono_ns)
        a.entry.id < b.entry.id
    else
        a.entry.due_mono_ns < b.entry.due_mono_ns;
}

const TimerNodeHeap = common_io.heap.IntrusiveHeap(TimerNode, void, timerNodeLess);

pub const TimerHeap = struct {
    allocator: std.mem.Allocator,
    nodes: []TimerNode = &.{},
    free_slots: []usize = &.{},
    free_len: usize = 0,
    heap: TimerNodeHeap,

    /// A heap without slots, which rejects every push; `initCapacity` makes
    /// a usable one.
    pub fn init(allocator: std.mem.Allocator) TimerHeap {
        return .{
            .allocator = allocator,
            .heap = TimerNodeHeap.init(allocator, {}),
        };
    }

    /// Allocates `initial_capacity` slots, the heap's size for its lifetime.
    pub fn initCapacity(allocator: std.mem.Allocator, initial_capacity: usize) !TimerHeap {
        var self = init(allocator);
        errdefer self.deinit();
        self.nodes = try allocator.alloc(TimerNode, initial_capacity);
        for (self.nodes, 0..) |*node, index|
            node.* = .{ .slot = index };
        self.free_slots = try allocator.alloc(usize, initial_capacity);
        try self.heap.ensureTotalCapacity(initial_capacity);

        for (0..initial_capacity) |index| {
            self.free_slots[index] = index;
        }
        self.free_len = initial_capacity;
        return self;
    }

    pub fn deinit(self: *TimerHeap) void {
        for (self.nodes) |*node| {
            if (node.active)
                node.entry.deinit(self.allocator);
        }
        self.heap.deinit();
        if (self.nodes.len != 0)
            self.allocator.free(self.nodes);
        if (self.free_slots.len != 0)
            self.allocator.free(self.free_slots);
        self.* = undefined;
    }

    pub fn len(self: *const TimerHeap) usize {
        return self.heap.len();
    }

    pub fn reservedCount(self: *const TimerHeap) usize {
        std.debug.assert(self.free_len <= self.nodes.len);
        return self.nodes.len - self.free_len;
    }

    pub fn capacity(self: *const TimerHeap) usize {
        return self.nodes.len;
    }

    /// Inserts `entry`, which the heap owns on success. Fails with
    /// `error.TimerHeapFull` when every slot is taken.
    pub fn push(self: *TimerHeap, entry: TimerEntry) !void {
        if (self.free_len == 0)
            return error.TimerHeapFull;

        self.free_len -= 1;
        const slot = self.free_slots[self.free_len];
        const node = &self.nodes[slot];
        node.entry = entry;
        node.active = true;
        node.heap = .{};
        self.heap.insertAssumeCapacity(node);
    }

    pub fn peekDueNs(self: *const TimerHeap) ?u64 {
        const node = self.heap.peek() orelse return null;
        return node.entry.due_mono_ns;
    }

    /// Removes and returns the earliest timer if it is due at `now_mono_ns`.
    pub fn popDue(self: *TimerHeap, now_mono_ns: u64) ?TimerEntry {
        const node = self.heap.peek() orelse return null;
        if (node.entry.due_mono_ns > now_mono_ns)
            return null;
        return self.popMin();
    }

    /// Frees timer `timer_id` if `request_id` scheduled it, and returns
    /// whether it was found. Scans every slot.
    pub fn cancelByIdForRequest(self: *TimerHeap, timer_id: u64, request_id: u64) bool {
        for (self.nodes) |*node| {
            if (!node.active or node.entry.id != timer_id or node.entry.request_id != request_id)
                continue;

            _ = self.heap.remove(node);
            node.entry.deinit(self.allocator);
            self.releaseSlot(node);
            return true;
        }
        return false;
    }

    /// Frees every timer `request_id` scheduled and returns how many there
    /// were.
    pub fn cancelForRequest(self: *TimerHeap, request_id: u64) usize {
        var canceled: usize = 0;
        for (self.nodes) |*node| {
            if (!node.active or node.entry.request_id != request_id)
                continue;
            _ = self.heap.remove(node);
            node.entry.deinit(self.allocator);
            self.releaseSlot(node);
            canceled += 1;
        }
        return canceled;
    }

    fn popMin(self: *TimerHeap) ?TimerEntry {
        const node = self.heap.deleteMin() orelse return null;
        const entry = node.entry;
        self.releaseSlot(node);
        return entry;
    }

    fn releaseSlot(self: *TimerHeap, node: *TimerNode) void {
        node.active = false;
        node.entry = undefined;
        node.heap = .{};
        self.free_slots[self.free_len] = node.slot;
        self.free_len += 1;
    }
};

/// Runs the `.timer_callback` work item: takes the timer out of the ready map
/// and calls its callback in a turn of its request. A repeating timer goes
/// back into the heap, due one delay after the callback returns, unless the
/// callback cleared it or its request ended. A timer cancelled after it was
/// queued is no longer in the map, and the item does nothing. A callback
/// error is returned after the re-arm.
pub fn executeCallback(runtime: anytype, timer_id: u64) !void {
    const removed = runtime.scheduler.ready_timer_callbacks.fetchRemove(timer_id) orelse return;
    var timer = removed.value;
    var timer_owned = true;
    defer if (timer_owned)
        timer.deinit(runtime.core.allocator);

    // While its callback runs the timer is in no container. These fields let
    // a clearTimeout from inside the callback stop the repeat, and keep a
    // repeating timer counted against `max_timers_per_worker` until it is
    // back in the heap.
    runtime.scheduler.executing_timer_id = timer.id;
    runtime.scheduler.executing_timer_request_id = timer.request_id;
    runtime.scheduler.executing_timer_cancelled = false;
    runtime.scheduler.executing_repeating_timer_reserved = timer.repeats;
    defer {
        runtime.scheduler.executing_timer_id = null;
        runtime.scheduler.executing_timer_request_id = 0;
        runtime.scheduler.executing_timer_cancelled = false;
        runtime.scheduler.executing_repeating_timer_reserved = false;
    }

    var callback_err: ?anyerror = null;
    callbacks.invokeDiscard(runtime, timer.request_id, &timer.callback, timer.args) catch |err| {
        callback_err = err;
    };

    if (timer.repeats and !runtime.scheduler.executing_timer_cancelled and runtime.requests.active.contains(timer.request_id)) {
        timer.due_mono_ns = runtime.nowMonoNs() + @as(u64, timer.delay_ms) * std.time.ns_per_ms;
        try runtime.scheduler.timers.push(timer);
        timer_owned = false;
    }

    if (callback_err) |err|
        return err;
}

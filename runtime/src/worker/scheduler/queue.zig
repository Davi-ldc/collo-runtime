//! The ready queue: a bounded FIFO of work items the worker loop runs one per
//! turn. It is not shared between threads; every producer runs on the VM
//! thread, after reading the control channel, a timer, request I/O or a
//! completion another thread published. The runtime keeps two, the queue
//! and its backlog, each of `RuntimeLimits.ready_queue_capacity` items. When
//! both are full, `tryQueueReadyWorkReadySince` (`runtime/scheduler.zig`)
//! sets the rescan flag of the item's producer, while timers, immediates and
//! request deadlines stay in their own containers for the next pass.

const std = @import("std");
const request_task = @import("collo_worker_request").task;

pub const WorkItem = union(enum) {
    request: u64,
    timer_callback: u64,
    immediate_callback: u64,
    request_completion: request_task.TaskToken,
    request_body_ready: u64,
    request_cancelled: u64,
    request_deadline: u64,
    fetch_completion: u64,
    fetch_body_ready: u64,
    /// A response arrived for this fault id; settles the reads waiting on
    /// it (`fs/fault_completion.zig`).
    fs_fault_completion: u64,
};

/// Metadata a slot carries from enqueue to pop. The owner is resolved once,
/// at enqueue, because by pop the handler maps may no longer hold the
/// entry: a timer, immediate or fetch entry leaves its map when it runs, and
/// a cancel removes it while the item still waits. `ready_since_mono_ns` is
/// when the producer saw the work become ready, such as a timer's due time
/// or the gateway's completion stamp; zero means ready at enqueue.
pub const SlotMeta = struct {
    enqueued_mono_ns: u64 = 0,
    owner_request_id: u64 = 0,
    ready_since_mono_ns: u64 = 0,
};

pub const ReadyQueue = struct {
    allocator: std.mem.Allocator,
    items: []WorkItem,
    meta: []SlotMeta,
    head: usize,
    tail: usize,
    len: usize,
    /// Metadata of the item the latest `pop` returned, all zero when
    /// unstamped. The loop's turn telemetry reads and clears it right after
    /// the pop.
    last_popped_meta: SlotMeta,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !ReadyQueue {
        if (capacity == 0)
            return error.InvalidCapacity;

        const items = try allocator.alloc(WorkItem, capacity);
        errdefer allocator.free(items);

        return .{
            .allocator = allocator,
            .items = items,
            .meta = try allocator.alloc(SlotMeta, capacity),
            .head = 0,
            .tail = 0,
            .len = 0,
            .last_popped_meta = .{},
        };
    }

    pub fn deinit(self: *ReadyQueue) void {
        self.allocator.free(self.meta);
        self.allocator.free(self.items);
        self.* = undefined;
    }

    /// `tryPush` that fails with `error.QueueFull`.
    pub fn push(self: *ReadyQueue, item: WorkItem) !void {
        if (!self.tryPush(item))
            return error.QueueFull;
    }

    pub fn tryPush(self: *ReadyQueue, item: WorkItem) bool {
        return self.tryPushStamped(item, .{});
    }

    /// Appends `item` with `meta`, whose stamps come from the runtime's
    /// clock so a test's fake clock stays consistent; zeroed metadata leaves
    /// the turn telemetry inert. Returns false when the queue is full.
    pub fn tryPushStamped(self: *ReadyQueue, item: WorkItem, meta: SlotMeta) bool {
        if (self.len == self.items.len)
            return false;

        self.items[self.tail] = item;
        self.meta[self.tail] = meta;
        self.tail = (self.tail + 1) % self.items.len;
        self.len += 1;
        return true;
    }

    pub fn pop(self: *ReadyQueue) ?WorkItem {
        if (self.len == 0)
            return null;

        const item = self.items[self.head];
        self.last_popped_meta = self.meta[self.head];
        self.head = (self.head + 1) % self.items.len;
        self.len -= 1;
        return item;
    }

    /// Moves items, with their metadata and in order, into `target` until
    /// this queue is empty or `target` is full.
    pub fn drainInto(self: *ReadyQueue, target: *ReadyQueue) void {
        while (self.len != 0) {
            const item = self.items[self.head];
            if (!target.tryPushStamped(item, self.meta[self.head]))
                return;
            self.head = (self.head + 1) % self.items.len;
            self.len -= 1;
        }
    }

    pub fn isEmpty(self: *const ReadyQueue) bool {
        return self.len == 0;
    }

    pub fn remainingCapacity(self: *const ReadyQueue) usize {
        return self.items.len - self.len;
    }
};

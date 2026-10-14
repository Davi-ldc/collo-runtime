//! How a shard engine tells the gateway's loop which of its fetches need attention: a ring of
//! ready task tokens and a bit that asks for a look at every fetch of the shard. The inner
//! engine's threads enqueue through the engine's wake callback (`engine.zig`), and the loop drains
//! on its own thread in bounded batches (`runtime/shard_flow.zig`). One mutex guards the whole
//! scan.
//!
//! An enqueue returns true only when it took the ring, or the scan bit, from empty to non-empty,
//! and only then does the caller write the engine's wake eventfd. An entry that lands in a
//! non-empty ring has a wake in flight or a drain running, and a drain that leaves entries behind
//! writes the eventfd itself, so no entry waits for a wake that never comes. A full ring drops
//! nothing: the entry sets the scan bit instead, and the next drain looks at every fetch.

const std = @import("std");
const egress = @import("collo_egress_client");

const task_model = egress.task;

pub const Event = struct {
    /// Only an address until the fetch table shows a live record with this handle holding this
    /// task: the task may have been freed and its memory reused since the token was queued.
    task: *task_model.Task,
    /// The handle of the task's record in the gateway's fetch table (`fetch_table.Handle`), never
    /// 0: a token without one sets the scan bit instead (`enqueueTask`).
    handle: u64,
};

pub const Drain = struct {
    len: usize,
    scan_required: bool,
    has_more: bool,
};

pub const Scan = struct {
    mutex: std.Thread.Mutex = .{},
    events: []Event,
    head: usize = 0,
    len: usize = 0,
    scan_required: bool = false,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Scan {
        std.debug.assert(capacity != 0);
        return .{ .events = try allocator.alloc(Event, capacity) };
    }

    pub fn deinit(self: *Scan, allocator: std.mem.Allocator) void {
        allocator.free(self.events);
        self.* = undefined;
    }

    /// Queues `ready` and returns whether the caller must write the wake eventfd. A token with
    /// handle 0, or one that finds the ring full, sets the scan bit instead.
    pub fn enqueueTask(self: *Scan, ready: task_model.Task.ReadyToken) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (ready.generation == 0 or self.len == self.events.len)
            return self.requestScanLocked();
        const was_empty = self.len == 0;
        const index = (self.head + self.len) % self.events.len;
        self.events[index] = .{ .task = ready.task, .handle = ready.generation };
        self.len += 1;
        return was_empty;
    }

    /// Sets the scan bit and returns true when it was clear: a set bit already has a wake in
    /// flight, or a running pass will see it, since every pass calls `drain`, which takes the
    /// bit.
    pub fn requestScan(self: *Scan) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.requestScanLocked();
    }

    fn requestScanLocked(self: *Scan) bool {
        const was_set = self.scan_required;
        self.scan_required = true;
        return !was_set;
    }

    /// Moves up to `out.len` task tokens into `out`, and takes and clears the scan bit.
    pub fn drain(self: *Scan, out: []Event) Drain {
        self.mutex.lock();
        defer self.mutex.unlock();
        const count = @min(out.len, self.len);
        for (out[0..count]) |*slot| {
            slot.* = self.events[self.head];
            self.head = (self.head + 1) % self.events.len;
        }
        self.len -= count;
        if (self.len == 0)
            self.head = 0;
        const scan_required = self.scan_required;
        self.scan_required = false;
        return .{
            .len = count,
            .scan_required = scan_required,
            .has_more = self.len != 0,
        };
    }

    /// Drops every queued token and the scan bit. Only for an engine between runs, whose tokens
    /// all name tasks of the run that ended.
    pub fn clear(self: *Scan) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.head = 0;
        self.len = 0;
        self.scan_required = false;
    }
};

//! How a shard engine learns which of its fetches need attention: a ring of ready task tokens, a
//! ring of worker sessions whose fetches need a rescan, and a bit that asks for a scan of every
//! active fetch. The inner engine's threads enqueue task tokens and scan requests through the
//! engine's wake callback, the gateway's loop thread enqueues rescans, and `engine.Engine` drains
//! everything on the loop thread in bounded batches. One mutex guards the whole queue.
//!
//! An enqueue returns true only when it took a ring, or the scan bit, from empty to non-empty,
//! and only then does the caller write the engine's wake eventfd. An entry that lands in a
//! non-empty ring has a wake in flight or a drain running, and a drain that leaves entries
//! behind writes the eventfd itself (`Engine.collectReadyCompletedInto`), so no entry waits for
//! a wake that never comes. A full ring drops nothing: the entry sets the scan bit instead, and
//! the next drain scans every active fetch.

const std = @import("std");
const egress = @import("collo_egress_client");

const task_model = egress.task;

pub const Event = struct {
    /// Only an address until the active table shows the task is still there with this
    /// `generation` (`Engine.processReadyEvent`): the task may have been freed and its memory
    /// reused since the token was queued.
    task: *task_model.Task,
    generation: u64,
};

pub const Drain = struct {
    len: usize,
    scan_required: bool,
    has_more: bool,
};

pub const WorkerDrain = struct {
    len: usize,
    has_more: bool,
};

pub const Scan = struct {
    mutex: std.Thread.Mutex = .{},
    events: []Event,
    worker_scans: []u64,
    head: usize = 0,
    len: usize = 0,
    worker_scan_head: usize = 0,
    worker_scan_len: usize = 0,
    scan_required: bool = false,
    next_generation: u64 = 1,
    overflow_scan_total: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Scan {
        const events = try allocator.alloc(Event, capacity);
        errdefer allocator.free(events);
        const worker_scans = try allocator.alloc(u64, capacity);
        return .{
            .events = events,
            .worker_scans = worker_scans,
        };
    }

    pub fn deinit(self: *Scan, allocator: std.mem.Allocator) void {
        allocator.free(self.events);
        allocator.free(self.worker_scans);
        self.* = undefined;
    }

    /// Queues `ready` and returns whether the caller must write the wake eventfd. A token with
    /// generation 0, or one that finds the ring full, sets the scan bit instead.
    pub fn enqueueTask(self: *Scan, ready: task_model.Task.ReadyToken) bool {
        const generation = ready.generation;
        if (generation == 0)
            return self.requestScan(false);

        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.len == self.events.len)
            return self.requestScanLocked(true);
        const was_empty = self.len == 0;
        const index = (self.head + self.len) % self.events.len;
        self.events[index] = .{
            .task = ready.task,
            .generation = generation,
        };
        self.len += 1;
        return was_empty;
    }

    /// Sets the scan bit and returns true when it was clear: a set bit already has a wake in
    /// flight, or a running pass will see it, since every pass calls `drain`, which takes the
    /// bit. `count_overflow` also counts the request in `overflow_scan_total`.
    pub fn requestScan(self: *Scan, count_overflow: bool) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.requestScanLocked(count_overflow);
    }

    fn requestScanLocked(self: *Scan, count_overflow: bool) bool {
        const was_set = self.scan_required;
        self.scan_required = true;
        if (count_overflow)
            self.overflow_scan_total +|= 1;
        return !was_set;
    }

    /// Queues a rescan of `worker_session_id`'s fetches and returns whether the caller must write
    /// the wake eventfd: false for a session already queued and for an append to a non-empty
    /// ring. A full ring sets the scan bit instead.
    pub fn enqueueWorkerScan(self: *Scan, worker_session_id: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.containsWorkerScanLocked(worker_session_id))
            return false;
        if (self.worker_scan_len == self.worker_scans.len)
            return self.requestScanLocked(true);
        const was_empty = self.worker_scan_len == 0;
        const index = (self.worker_scan_head + self.worker_scan_len) % self.worker_scans.len;
        self.worker_scans[index] = worker_session_id;
        self.worker_scan_len += 1;
        return was_empty;
    }

    /// Moves up to `out.len` task tokens into `out`, and takes and clears the scan bit.
    pub fn drain(self: *Scan, out: []Event) Drain {
        self.mutex.lock();
        defer self.mutex.unlock();
        const count = @min(out.len, self.len);
        var copied: usize = 0;
        while (copied < count) : (copied += 1) {
            out[copied] = self.events[self.head];
            self.head = (self.head + 1) % self.events.len;
            self.len -= 1;
        }
        const scan_required = self.scan_required;
        self.scan_required = false;
        const has_more = self.len != 0;
        if (self.len == 0)
            self.head = 0;
        return .{
            .len = count,
            .scan_required = scan_required,
            .has_more = has_more,
        };
    }

    pub fn drainWorkerScans(self: *Scan, out: []u64) WorkerDrain {
        self.mutex.lock();
        defer self.mutex.unlock();
        const count = @min(out.len, self.worker_scan_len);
        var copied: usize = 0;
        while (copied < count) : (copied += 1) {
            out[copied] = self.worker_scans[self.worker_scan_head];
            self.worker_scan_head = (self.worker_scan_head + 1) % self.worker_scans.len;
            self.worker_scan_len -= 1;
        }
        const has_more = self.worker_scan_len != 0;
        if (self.worker_scan_len == 0)
            self.worker_scan_head = 0;
        return .{
            .len = count,
            .has_more = has_more,
        };
    }

    /// Drops every queued event and worker scan and the scan bit. Only for an
    /// engine between runs whose active table is empty, so every dropped
    /// entry is stale.
    pub fn clear(self: *Scan) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.head = 0;
        self.len = 0;
        self.worker_scan_head = 0;
        self.worker_scan_len = 0;
        self.scan_required = false;
    }

    /// Generations skip 0, which marks a task outside the active table and, in a token, asks for
    /// a scan.
    pub fn nextGeneration(self: *Scan) u64 {
        const generation = self.next_generation;
        self.next_generation +%= 1;
        if (self.next_generation == 0)
            self.next_generation = 1;
        return generation;
    }

    pub fn overflowScanTotal(self: *const Scan) u64 {
        return self.overflow_scan_total;
    }

    fn containsWorkerScanLocked(self: *const Scan, worker_session_id: u64) bool {
        var offset: usize = 0;
        while (offset < self.worker_scan_len) : (offset += 1) {
            const index = (self.worker_scan_head + offset) % self.worker_scans.len;
            if (self.worker_scans[index] == worker_session_id)
                return true;
        }
        return false;
    }
};

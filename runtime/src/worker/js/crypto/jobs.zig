//! The worker's WebCrypto thread pool: runs native crypto jobs off the VM
//! thread and hands each one back to the VM thread to settle or destroy. It
//! belongs to the `worker` module. Pool threads run the jobs; every `Pool`
//! method runs on the VM thread.
//!
//! `Pool.init` starts every pool thread at once, and the pool never starts
//! one later. The worker builds its pool in `Runtime.init`, before seccomp
//! denies clone. A pool thread calls only `bindings.runCryptoJob`, and
//! `CryptoJob::run` in `webapi/crypto/jobs.h` reads and writes only the job's
//! native data. Settling or destroying a job may touch JSC handles, so both
//! happen only on the VM thread.
//!
//! An accepted job sits in exactly one of four places until the VM thread
//! pops it: the pending array, a pool thread, the completed ring or the
//! discarded ring. `max_in_flight_per_worker` bounds the jobs in flight and
//! sizes the array and both rings, so none of them can overflow.
//!
//! `wakeup_fd` is the scheduler's wakeup eventfd, borrowed. The pool writes it
//! after each completion and cancellation, and `Pool.deinit` joins every
//! thread, so the owner calls `deinit` before closing the eventfd.

const std = @import("std");
const bindings = @import("collo_bindings");
const os_process = @import("collo_os").process;

// Defaults for a `Config` that leaves a field unset. The worker sets every
// field from its `RuntimeLimits`, whose defaults come from
// `ipc.WorkerRuntimeBootOptions` in `common/ipc/messages.zig`.
//
// glibc places static TLS on the thread stack and pthread_create rejects a
// stack smaller than static TLS + guard + PTHREAD_STACK_MIN with a synchronous
// EINVAL, which std.Thread.spawn treats as unreachable. The default leaves
// room for the static TLS, the guard page and BoringSSL's frames while
// staying below glibc's usual 8 MiB default.
const default_thread_stack_bytes: usize = 4 * 1024 * 1024;
const default_max_in_flight_per_request: usize = 6;
const default_max_in_flight_per_worker: usize = 64 * default_max_in_flight_per_request;

pub const Entry = struct {
    request_id: u64,
    job: *bindings.RawCryptoJob,
    /// CLOCK_MONOTONIC reading the pool thread takes when the job finishes,
    /// or zero when the clock failed. The request counts as ready from this
    /// instant, so its I/O time ends when the work ended rather than when the
    /// VM thread noticed.
    completed_at_ns: u64 = 0,
};

pub const Config = struct {
    /// Zero builds a disabled pool that accepts no job.
    thread_count: usize = 0,
    thread_stack_bytes: usize = default_thread_stack_bytes,
    /// Jobs one request may have from submission until the VM thread pops
    /// them.
    max_in_flight_per_request: usize = default_max_in_flight_per_request,
    /// The same bound across every request; it sizes each queue.
    max_in_flight_per_worker: usize = default_max_in_flight_per_worker,

    /// Returns a config with two threads whatever `allowed_cpus` is. Extra
    /// crypto work waits in the bounded queue instead of starting threads that
    /// would compete with request JavaScript.
    pub fn withAutoThreads(allowed_cpus: usize) Config {
        _ = allowed_cpus;
        return .{
            .thread_count = 2,
        };
    }
};

/// A handle to the pool. The state lives on the heap because the pool threads
/// hold a pointer to it while the handle moves with its `Runtime`; a null
/// state is a disabled pool.
pub const Pool = struct {
    state: ?*State = null,

    /// Starts `config.thread_count` threads, borrowing `wakeup_fd` until
    /// `deinit`. Fails with `error.InvalidCryptoJobPoolConfig` for a zero
    /// in-flight bound, or with an allocation or spawn error; a failure joins
    /// every thread already started.
    pub fn init(allocator: std.mem.Allocator, wakeup_fd: std.posix.fd_t, config: Config) !Pool {
        if (config.thread_count == 0)
            return .{};
        if (config.max_in_flight_per_request == 0 or config.max_in_flight_per_worker == 0)
            return error.InvalidCryptoJobPoolConfig;

        const state = try allocator.create(State);
        var state_initialized = false;
        errdefer {
            if (state_initialized) {
                state.shutdownAndJoin();
                state.deinit();
            }
            allocator.destroy(state);
        }
        state.* = try State.init(allocator, wakeup_fd, config);
        state_initialized = true;
        try state.start();
        return .{ .state = state };
    }

    /// Stops and joins every thread, then destroys every job the pool still
    /// holds, which is why it must run on the VM thread.
    pub fn deinit(self: *Pool) void {
        const state = self.state orelse return;
        const allocator = state.allocator;
        state.shutdownAndJoin();
        state.deinit();
        allocator.destroy(state);
        self.* = .{};
    }

    /// Queues `job` for request `request_id` and owns it on success; on
    /// failure the caller keeps it. Fails with `error.CryptoJobPoolUnavailable`
    /// for a disabled pool, `error.InvalidCryptoJob` for request id zero,
    /// `error.CryptoJobPoolStopping` during shutdown,
    /// `error.CryptoJobOutsideActiveRequest` while an earlier cancellation of
    /// the request drains, and `error.CryptoJobWorkerQueueFull` or
    /// `error.CryptoJobRequestQueueFull` at an in-flight bound.
    pub fn submit(self: *Pool, request_id: u64, job: *bindings.RawCryptoJob) !void {
        const state = self.state orelse return error.CryptoJobPoolUnavailable;
        try state.submit(.{ .request_id = request_id, .job = job });
    }

    /// Moves every queued or completed job of `request_id` to the discarded
    /// ring, marks a running one to follow when it finishes, and wakes the VM
    /// thread to destroy them.
    pub fn cancelForRequest(self: *Pool, request_id: u64) void {
        const state = self.state orelse return;
        state.cancelForRequest(request_id);
    }

    /// Takes the oldest finished job, which the VM thread must settle or
    /// destroy.
    pub fn popCompleted(self: *Pool) ?Entry {
        const state = self.state orelse return null;
        return state.popCompleted();
    }

    /// Takes the oldest discarded job, which the VM thread must destroy.
    pub fn popDiscarded(self: *Pool) ?Entry {
        const state = self.state orelse return null;
        return state.popDiscarded();
    }

    /// Whether a completed or discarded job is waiting for the VM thread.
    pub fn hasReady(self: *Pool) bool {
        const state = self.state orelse return false;
        return state.hasReady();
    }
};

const State = struct {
    allocator: std.mem.Allocator,
    wakeup_fd: std.posix.fd_t,
    /// Guards the queues, the per-request maps, `global_in_flight` and
    /// `stopping`. The VM thread alone touches `threads` and `started_len`,
    /// and the remaining fields do not change after `init`.
    mutex: std.Thread.Mutex = .{},
    /// Wakes idle pool threads when a job is queued, a running job ends, a
    /// request is canceled or the pool stops.
    condition: std.Thread.Condition = .{},
    /// Jobs waiting for a thread, unordered: a removal moves the last entry
    /// into the gap.
    pending: []Entry,
    pending_len: usize = 0,
    completed: EntryRing,
    discarded: EntryRing,
    threads: []std.Thread,
    started_len: usize = 0,
    thread_stack_bytes: usize,
    /// Jobs per request from submission until the VM thread pops them.
    counts_by_request: std.AutoHashMapUnmanaged(u64, usize) = .empty,
    /// Jobs per request now running on a pool thread.
    running_by_request: std.AutoHashMapUnmanaged(u64, usize) = .empty,
    /// Requests canceled while one of their jobs ran. Such a job finishes
    /// into `discarded`, and the mark stays, refusing new jobs for that
    /// request id, until the VM thread pops the request's last job.
    canceled_requests: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// Jobs from submission until the VM thread pops them, across requests.
    global_in_flight: usize = 0,
    max_in_flight_per_request: usize,
    stopping: bool = false,

    fn init(allocator: std.mem.Allocator, wakeup_fd: std.posix.fd_t, config: Config) !State {
        const pending = try allocator.alloc(Entry, config.max_in_flight_per_worker);
        errdefer allocator.free(pending);
        const completed = try allocator.alloc(Entry, config.max_in_flight_per_worker);
        errdefer allocator.free(completed);
        const discarded = try allocator.alloc(Entry, config.max_in_flight_per_worker);
        errdefer allocator.free(discarded);
        const threads = try allocator.alloc(std.Thread, config.thread_count);
        errdefer allocator.free(threads);

        var counts_by_request = std.AutoHashMapUnmanaged(u64, usize){};
        errdefer counts_by_request.deinit(allocator);
        try counts_by_request.ensureTotalCapacity(
            allocator,
            @intCast(config.max_in_flight_per_worker),
        );
        var running_by_request = std.AutoHashMapUnmanaged(u64, usize){};
        errdefer running_by_request.deinit(allocator);
        try running_by_request.ensureTotalCapacity(
            allocator,
            @intCast(config.max_in_flight_per_worker),
        );
        var canceled_requests = std.AutoHashMapUnmanaged(u64, void){};
        errdefer canceled_requests.deinit(allocator);
        try canceled_requests.ensureTotalCapacity(
            allocator,
            @intCast(config.max_in_flight_per_worker),
        );

        return .{
            .allocator = allocator,
            .wakeup_fd = wakeup_fd,
            .pending = pending,
            .completed = EntryRing.init(completed),
            .discarded = EntryRing.init(discarded),
            .threads = threads,
            .thread_stack_bytes = config.thread_stack_bytes,
            .counts_by_request = counts_by_request,
            .running_by_request = running_by_request,
            .canceled_requests = canceled_requests,
            .max_in_flight_per_request = config.max_in_flight_per_request,
        };
    }

    fn deinit(self: *State) void {
        std.debug.assert(self.started_len == 0);
        for (self.pending[0..self.pending_len]) |entry|
            bindings.destroyCryptoJob(entry.job);
        self.completed.destroyJobs();
        self.discarded.destroyJobs();
        self.counts_by_request.deinit(self.allocator);
        self.running_by_request.deinit(self.allocator);
        self.canceled_requests.deinit(self.allocator);
        self.allocator.free(self.threads);
        self.allocator.free(self.discarded.items);
        self.allocator.free(self.completed.items);
        self.allocator.free(self.pending);
        self.* = undefined;
    }

    fn start(self: *State) !void {
        while (self.started_len < self.threads.len) {
            self.threads[self.started_len] = try std.Thread.spawn(
                .{ .stack_size = self.thread_stack_bytes },
                State.threadMain,
                .{self},
            );
            self.started_len += 1;
        }
    }

    fn shutdownAndJoin(self: *State) void {
        self.mutex.lock();
        self.stopping = true;
        self.condition.broadcast();
        self.mutex.unlock();

        for (self.threads[0..self.started_len]) |thread|
            thread.join();
        self.started_len = 0;
    }

    fn submit(self: *State, entry: Entry) !void {
        if (entry.request_id == 0)
            return error.InvalidCryptoJob;

        std.debug.assert(self.started_len == self.threads.len);

        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.stopping)
            return error.CryptoJobPoolStopping;
        if (self.canceled_requests.contains(entry.request_id))
            return error.CryptoJobOutsideActiveRequest;
        if (self.global_in_flight >= self.pending.len)
            return error.CryptoJobWorkerQueueFull;

        const count_entry = self.counts_by_request.getOrPutAssumeCapacity(entry.request_id);
        if (!count_entry.found_existing)
            count_entry.value_ptr.* = 0;
        if (count_entry.value_ptr.* >= self.max_in_flight_per_request) {
            if (!count_entry.found_existing)
                _ = self.counts_by_request.remove(entry.request_id);
            return error.CryptoJobRequestQueueFull;
        }
        count_entry.value_ptr.* += 1;
        self.global_in_flight += 1;

        self.pending[self.pending_len] = entry;
        self.pending_len += 1;
        self.condition.signal();
    }

    fn cancelForRequest(self: *State, request_id: u64) void {
        if (request_id == 0)
            return;

        self.mutex.lock();
        var pending_index: usize = 0;
        while (pending_index < self.pending_len) {
            const entry = self.pending[pending_index];
            if (entry.request_id != request_id) {
                pending_index += 1;
                continue;
            }

            swapRemove(self.pending, &self.pending_len, pending_index);
            self.appendDiscardedLocked(entry);
        }

        // One full rotation of the ring keeps the other requests'
        // completions in order.
        var completed_count = self.completed.len;
        while (completed_count != 0) : (completed_count -= 1) {
            const entry = self.completed.pop().?;
            if (entry.request_id != request_id) {
                self.completed.pushAssumeCapacity(entry);
                continue;
            }
            self.appendDiscardedLocked(entry);
        }

        if (self.running_by_request.contains(request_id)) {
            self.canceled_requests.putAssumeCapacity(request_id, {});
        } else {
            _ = self.canceled_requests.remove(request_id);
        }
        self.condition.broadcast();
        self.mutex.unlock();
        wakeEventfd(self.wakeup_fd);
    }

    fn popCompleted(self: *State) ?Entry {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = self.completed.pop() orelse return null;
        self.releaseInFlightLocked(entry.request_id);
        return entry;
    }

    fn popDiscarded(self: *State) ?Entry {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = self.discarded.pop() orelse return null;
        self.releaseInFlightLocked(entry.request_id);
        if (!self.counts_by_request.contains(entry.request_id))
            _ = self.canceled_requests.remove(entry.request_id);
        return entry;
    }

    fn hasReady(self: *State) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.completed.len != 0 or self.discarded.len != 0;
    }

    fn threadMain(self: *State) void {
        while (true) {
            var entry = self.takeRunnable() orelse return;
            bindings.runCryptoJob(entry.job);
            entry.completed_at_ns = os_process.monotonicNowNsOrZero();
            self.complete(entry);
        }
    }

    fn takeRunnable(self: *State) ?Entry {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (true) {
            if (self.stopping)
                return null;

            var index: usize = 0;
            while (index < self.pending_len) : (index += 1) {
                const entry = self.pending[index];
                if (self.running_by_request.get(entry.request_id)) |running| {
                    if (running >= self.max_in_flight_per_request)
                        continue;
                }

                swapRemove(self.pending, &self.pending_len, index);
                const running_entry =
                    self.running_by_request.getOrPutAssumeCapacity(entry.request_id);
                if (!running_entry.found_existing)
                    running_entry.value_ptr.* = 0;
                running_entry.value_ptr.* += 1;
                return entry;
            }

            self.condition.wait(&self.mutex);
        }
    }

    fn complete(self: *State, entry: Entry) void {
        self.mutex.lock();
        self.releaseRunningLocked(entry.request_id);
        if (self.canceled_requests.contains(entry.request_id)) {
            self.appendDiscardedLocked(entry);
            self.condition.broadcast();
            self.mutex.unlock();
            wakeEventfd(self.wakeup_fd);
            return;
        }
        self.completed.pushAssumeCapacity(entry);
        self.condition.broadcast();
        self.mutex.unlock();
        wakeEventfd(self.wakeup_fd);
    }

    fn appendDiscardedLocked(self: *State, entry: Entry) void {
        std.debug.assert(self.discarded.len < self.discarded.items.len);
        self.discarded.pushAssumeCapacity(entry);
    }

    fn releaseRunningLocked(self: *State, request_id: u64) void {
        const running = self.running_by_request.getPtr(request_id) orelse return;
        if (running.* <= 1) {
            _ = self.running_by_request.remove(request_id);
            return;
        }
        running.* -= 1;
    }

    fn releaseInFlightLocked(self: *State, request_id: u64) void {
        if (self.global_in_flight > 0)
            self.global_in_flight -= 1;
        const count = self.counts_by_request.getPtr(request_id) orelse return;
        if (count.* <= 1) {
            _ = self.counts_by_request.remove(request_id);
            return;
        }
        count.* -= 1;
    }
};

/// A fixed-capacity FIFO over a slice its owner allocates and frees.
const EntryRing = struct {
    items: []Entry,
    head: usize = 0,
    len: usize = 0,

    fn init(items: []Entry) EntryRing {
        return .{ .items = items };
    }

    fn pushAssumeCapacity(self: *EntryRing, entry: Entry) void {
        std.debug.assert(self.len < self.items.len);
        const tail = (self.head + self.len) % self.items.len;
        self.items[tail] = entry;
        self.len += 1;
    }

    fn pop(self: *EntryRing) ?Entry {
        if (self.len == 0)
            return null;
        const entry = self.items[self.head];
        self.head = (self.head + 1) % self.items.len;
        self.len -= 1;
        if (self.len == 0)
            self.head = 0;
        return entry;
    }

    fn destroyJobs(self: *EntryRing) void {
        while (self.pop()) |entry|
            bindings.destroyCryptoJob(entry.job);
    }
};

/// Removes `items[index]` from the first `len.*` entries by moving the last
/// one into its place.
fn swapRemove(items: []Entry, len: *usize, index: usize) void {
    std.debug.assert(index < len.*);
    len.* -= 1;
    if (index != len.*)
        items[index] = items[len.*];
}

/// Wakes the VM thread's loop. A full eventfd counter means a wake is already
/// pending, so `error.WouldBlock` needs nothing more.
fn wakeEventfd(fd: std.posix.fd_t) void {
    var one: u64 = 1;
    _ = std.posix.write(fd, std.mem.asBytes(&one)) catch |err| switch (err) {
        error.WouldBlock, error.BrokenPipe, error.ConnectionResetByPeer => return,
        else => std.log.warn("crypto job wake eventfd write failed: {s}", .{@errorName(err)}),
    };
}

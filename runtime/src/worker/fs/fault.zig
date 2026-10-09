//! The fault plane: copies a file of the worker's read-only tree into its
//! tmpfs on the first read, over the dedicated fault channel
//! (`ipc.fs_fault`), and tracks every copy so it can be evicted. An async
//! read parks its promise in the fault table and settles on the event loop;
//! a sync read blocks the VM thread in `faultSync`. Every file of the plane
//! runs on the worker's VM thread, including the response reader, the
//! local-read stamp and the idle sweep.
//!
//! Readers of one path share one in-flight fault. Each waiter keeps its own
//! request id and generation, and the settle skips a waiter whose request
//! ended or moved to a new generation, so a fault never settles into the
//! wrong request.
//!
//! A fault request carries its first reader's identity. The boot context
//! has no worker identity, which a worker learns only from DispatchWork, so
//! inside the boot evaluation window it faults with an all-zero identity.
//! After the window its faults are denied here (`faultIdentity`), as the
//! host end refuses that identity once the worker is ready. Responses are
//! never gated by the window: an async boot fault answered after ready
//! still settles.
//!
//! Which file holds what:
//! - This file: the fault table with its caps, the identity a fault request
//!   carries, and the request an async read sends (`schedule`).
//! - `fault_sync.zig`: the sync read, which waits for its response on the
//!   VM thread.
//! - `fault_completion.zig`: a response read off the channel, the completion
//!   work item it queues and the settle of the waiters.
//! - `copies.zig`: the copies in the tmpfs, their ledger and their eviction.

const std = @import("std");
const fault_limits = @import("collo_limits").fs_fault;
const ipc = @import("collo_ipc");
const worker_fs = @import("index.zig");
const copies = @import("copies.zig");
const promise_deferred = @import("collo_worker_js").deferred;
const request_context = @import("collo_worker_request").context;

/// Caps on the fault table and on the waiters of one fault. They are
/// constants here because the table is worker-global and keyed by path, not
/// per request, and WorkerInit does not tune them. A full table or waiter
/// list rejects the read's promise instead of growing.
pub const max_faults_per_worker: usize = 64;
pub const max_fault_waiters_per_task: usize = 64;

// The largest file that may fault in is `fs_fault.max_fault_file_bytes`.
// `schedule` and `faultSync` reject a larger file before the request leaves
// the worker, and `readMaterialized` applies the same bound, so a fault
// never yields more than a local read could. Below it, the budget from
// `materializeBudgetBytes` is the limit.

pub const Waiter = struct {
    request_id: u64,
    request_generation: u64,
    deferred: promise_deferred.DeferredOwned,
    /// Whether this waiter's request counts a ready item for it. It is set
    /// when the completion is queued (`noteWaitersReady`) or when the waiter
    /// joins a fault whose completion already is, and cleared by the
    /// waiter's settle sub-turn or `releaseUnconsumedWaiterCounts`, so a
    /// waiter that joined late or a settle that stopped early never leaves
    /// the count unbalanced.
    ready_counted: bool = false,

    pub fn deinit(self: *Waiter) void {
        self.deferred.deinit();
        self.* = undefined;
    }
};

pub const Outcome = union(enum) {
    pending,
    materialized,
    /// A static string, the rejection reason of every waiter.
    failed: []const u8,
};

pub const Task = struct {
    id: u64,
    /// Owned index key, relative to `deploy_root`. It is the coalescing key
    /// and the storage `State.faults_by_path` borrows.
    path: []u8,
    /// Index position the path resolved to when the fault was sent.
    entry: usize,
    waiters: std.ArrayListUnmanaged(Waiter),
    outcome: Outcome,
    done: bool,
    queued: bool,
    /// Monotonic time the response was read, the readiness stamp that
    /// closes every waiter's io interval. The packet arrived earlier by at
    /// most the loop's delay in reading it.
    completed_at_ns: u64 = 0,

    /// Appends `waiter`, which the task owns on success. Fails with
    /// `error.FsFaultWaiterLimitExceeded` at `max_fault_waiters_per_task` or
    /// with OutOfMemory, leaving `waiter` the caller's.
    pub fn addWaiter(
        self: *Task,
        allocator: std.mem.Allocator,
        waiter: Waiter,
    ) !void {
        if (self.waiters.items.len >= max_fault_waiters_per_task)
            return error.FsFaultWaiterLimitExceeded;
        try self.waiters.append(allocator, waiter);
    }

    pub fn deinit(self: *Task, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        for (self.waiters.items) |*waiter|
            waiter.deinit();
        self.waiters.deinit(allocator);
        self.* = undefined;
    }
};

pub const State = struct {
    tasks: std.AutoHashMapUnmanaged(u64, Task) = .{},
    /// Index key to in-flight fault id, for coalescing. Keys borrow the
    /// task's `path`, so an entry is removed before its task is freed.
    faults_by_path: std.StringHashMapUnmanaged(u64) = .{},
    next_fault_id: u64 = 1,
    /// Set when a finished fault could not queue its completion because the
    /// ready queue and its backlog were full; `collectCompletions` retries
    /// on the loop's next pass.
    rescan_needed: bool = false,
    /// True only while the synchronous evaluation of the routes' entries
    /// runs (`Runtime.evaluateBootRoutes`), which ends before the worker
    /// sends its ready message. Inside it the boot context faults with the
    /// all-zero identity; after it `faultIdentity` denies the boot context,
    /// as the host end refuses that identity once the worker is ready.
    /// Responses are never gated by it.
    boot_window_open: bool = false,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        var it = self.tasks.valueIterator();
        while (it.next()) |task|
            task.deinit(allocator);
        self.tasks.deinit(allocator);
        self.faults_by_path.deinit(allocator);
        self.* = undefined;
    }
};

/// The identity a fault request carries, resolved by `faultIdentity` for
/// both `schedule` and `faultSync`.
const FaultIdentity = struct {
    request: *request_context.RequestContext,
    wire_request_id: u64,
    wire_request_generation: u64,
    wire_worker_id: u64,
    wire_worker_generation: u64,
};

/// The request's own ids with the worker identity from its DispatchWork, or
/// all zeros for the boot context inside the boot window. Fails with
/// `error.FsFaultOutsideActiveRequest` when no such request is active, or
/// when it has no generation and is not the boot context inside the window.
pub fn faultIdentity(runtime: anytype, request_id: u64, key: []const u8) !FaultIdentity {
    const state: *State = &runtime.fs_fault;
    const request = runtime.requests.active.get(request_id) orelse
        return error.FsFaultOutsideActiveRequest;
    if (request.request_generation == 0) {
        if (request_id != request_context.boot_request_id or !state.boot_window_open) {
            runtime.traceRuntimeEvent("worker.fs_fault.boot_denied={s}", .{key});
            return error.FsFaultOutsideActiveRequest;
        }
        return .{
            .request = request,
            .wire_request_id = 0,
            .wire_request_generation = 0,
            .wire_worker_id = 0,
            .wire_worker_generation = 0,
        };
    }
    return .{
        .request = request,
        .wire_request_id = request_id,
        .wire_request_generation = request.request_generation,
        .wire_worker_id = request.dispatch_work.worker_id,
        .wire_worker_generation = request.dispatch_work.worker_generation,
    };
}

/// Parks `deferred` on the fault for `normalized`, the normalized absolute
/// path of a file in the tree, joining an in-flight fault of the same path
/// or sending a new request, and returns the fault id. Takes `deferred` on
/// every path: a failure releases it, and the C++ caller rejects its own
/// promise. A path outside the index, a file above
/// `fs_fault.max_fault_file_bytes` or the whole budget, a denied identity,
/// or a full table or waiter list fails before anything is sent, and a
/// failed send leaves no fault state behind.
pub fn schedule(
    runtime: anytype,
    request_id: u64,
    normalized: []const u8,
    deferred: promise_deferred.DeferredOwned,
) !u64 {
    var owned_deferred = deferred;
    var deferred_moved = false;
    defer if (!deferred_moved)
        owned_deferred.deinit();

    const state: *State = &runtime.fs_fault;
    const view = worker_fs.indexView() orelse return error.FsFaultUnavailable;
    const fault_fd = worker_fs.faultFd() orelse return error.FsFaultUnavailable;

    const key = worker_fs.deployKey(normalized) orelse return error.InvalidFsFaultPath;
    if (key.len == 0 or key.len > ipc.fs_fault.max_path_bytes)
        return error.InvalidFsFaultPath;
    const entry = view.lookup(key) orelse return error.InvalidFsFaultPath;
    // The binding already answers EFBIG for a file above the ceiling before
    // it calls here; this check keeps the bound for any other caller.
    if (view.entrySizeAt(entry) > fault_limits.max_fault_file_bytes)
        return error.FsFaultFileTooLarge;
    // A file larger than the whole budget can never fit, since evicting
    // every copy frees at most the budget, so it fails the same way before
    // anything is sent.
    if (view.entrySizeAt(entry) > copies.materializeBudgetBytes())
        return error.FsFaultFileTooLarge;

    // The identity, including the boot denial, is resolved before any fault
    // state changes.
    const identity = try faultIdentity(runtime, request_id, key);
    const request = identity.request;

    const waiter = Waiter{
        .request_id = request_id,
        .request_generation = request.request_generation,
        .deferred = owned_deferred,
    };
    // The waiter owns the deferred from here, so the error paths below
    // release it only through the waiter.
    deferred_moved = true;
    var waiter_owned = waiter;
    var waiter_moved = false;
    errdefer if (!waiter_moved)
        waiter_owned.deinit();

    // Join the in-flight fault of the same path when there is one.
    if (state.faults_by_path.get(key)) |existing_id| {
        if (state.tasks.getPtr(existing_id)) |existing| {
            try existing.addWaiter(runtime.core.allocator, waiter_owned);
            waiter_moved = true;
            // A waiter joining a fault whose completion is already queued
            // missed `noteWaitersReady`. Its data is ready, so the time until
            // its settle sub-turn is queue wait, not io. Its ready item is
            // counted here, which only increments the counter because the
            // request is running its own turn, and the settle consumes it as
            // for every other waiter.
            if (existing.done and existing.queued) {
                const joined = &existing.waiters.items[existing.waiters.items.len - 1];
                request.noteReady(existing.completed_at_ns, runtime.nowMonoNs(), true);
                joined.ready_counted = true;
            }
            return existing_id;
        }
        _ = state.faults_by_path.remove(key);
    }

    // A full table rejects the read's promise rather than dropping the read
    // or growing the table.
    if (state.tasks.count() >= max_faults_per_worker)
        return error.FsFaultWorkerLimitExceeded;

    const fault_id = state.next_fault_id;
    state.next_fault_id +%= 1;
    if (state.next_fault_id == 0)
        state.next_fault_id = 1;

    const owned_path = try runtime.core.allocator.dupe(u8, key);
    var path_moved = false;
    errdefer if (!path_moved) runtime.core.allocator.free(owned_path);

    try state.tasks.ensureUnusedCapacity(runtime.core.allocator, 1);
    try state.faults_by_path.ensureUnusedCapacity(runtime.core.allocator, 1);

    var task = Task{
        .id = fault_id,
        .path = owned_path,
        .entry = entry,
        .waiters = .empty,
        .outcome = .pending,
        .done = false,
        .queued = false,
    };
    path_moved = true;
    errdefer task.deinit(runtime.core.allocator);
    try task.waiters.ensureUnusedCapacity(runtime.core.allocator, 1);

    // The request is sent before the table changes, so a failed send leaves
    // no fault state behind.
    try ipc.sendFsFaultRequest(fault_fd, runtime.core.dispatch_recv_scratch, .{
        .fault_id = fault_id,
        .request_id = identity.wire_request_id,
        .request_generation = identity.wire_request_generation,
        .worker_id = identity.wire_worker_id,
        .worker_generation = identity.wire_worker_generation,
        .path = task.path,
    });

    task.waiters.appendAssumeCapacity(waiter_owned);
    waiter_moved = true;
    state.tasks.putAssumeCapacityNoClobber(fault_id, task);
    state.faults_by_path.putAssumeCapacityNoClobber(task.path, fault_id);
    runtime.traceRuntimeEvent("worker.fs_fault.sent={s}", .{task.path});
    return fault_id;
}

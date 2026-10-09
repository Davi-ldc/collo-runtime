//! A shard engine's table of active fetches: the array of admitted fetches and every index into
//! it, by worker-scoped identity, fetch, body and task, plus the lists per worker session and per
//! request, the request being the one whose egress token admitted the fetch (`budgets.BudgetKey`).
//! `engine.Engine` owns it, and only the gateway's loop thread touches it.
//!
//! Every active fetch is present in every index, and every stored position names the fetch's
//! current slot. Removal moves the last fetch into the freed slot, so `removeAt` repairs the moved
//! fetch's positions before it returns; swap-remove and repair live together here so that no
//! caller can break the invariant. A fetch in the table also stamps a nonzero `ready_generation`
//! on its task, which a ready event must match (`ready_scan.zig`), and removal clears it.

const std = @import("std");
const egress = @import("collo_egress_client");

const active_fetch = @import("active_fetch.zig");
const budgets = @import("budgets.zig");

const task_model = egress.task;

pub const WorkerFetchKey = struct {
    worker_session_id: u64,
    fetch_id: u64,
};

pub const WorkerBodyKey = struct {
    worker_session_id: u64,
    body_id: u64,
};

const ScopedFetchList = std.array_list.Aligned(active_fetch.WorkerScopedFetch, null);

/// A fetch's position in each per-key list that holds it.
const BucketIndex = struct {
    worker: usize = std.math.maxInt(usize),
    request: usize = std.math.maxInt(usize),
};

pub const Table = struct {
    items: std.array_list.Aligned(active_fetch.Fetch, null) = .empty,
    bucket_indexes: std.array_list.Aligned(BucketIndex, null) = .empty,
    by_scoped: std.AutoHashMapUnmanaged(active_fetch.WorkerScopedFetch, usize) = .empty,
    by_fetch: std.AutoHashMapUnmanaged(WorkerFetchKey, usize) = .empty,
    by_body: std.AutoHashMapUnmanaged(WorkerBodyKey, usize) = .empty,
    by_task: std.AutoHashMapUnmanaged(*task_model.Task, usize) = .empty,
    by_worker_session: std.AutoHashMapUnmanaged(u64, ScopedFetchList) = .empty,
    by_request: std.AutoHashMapUnmanaged(budgets.BudgetKey, ScopedFetchList) = .empty,

    pub fn deinit(self: *Table, allocator: std.mem.Allocator, owner: anytype) void {
        for (self.items.items) |*fetch|
            fetch.deinit(owner);
        self.items.deinit(allocator);
        self.bucket_indexes.deinit(allocator);
        self.by_scoped.deinit(allocator);
        self.by_fetch.deinit(allocator);
        self.by_body.deinit(allocator);
        self.by_task.deinit(allocator);
        deinitScopedFetchLists(u64, allocator, &self.by_worker_session);
        deinitScopedFetchLists(budgets.BudgetKey, allocator, &self.by_request);
        self.* = undefined;
    }

    pub fn len(self: *const Table) usize {
        return self.items.items.len;
    }

    pub fn get(self: *Table, index: usize) *active_fetch.Fetch {
        return &self.items.items[index];
    }

    pub fn getConst(self: *const Table, index: usize) *const active_fetch.Fetch {
        return &self.items.items[index];
    }

    /// Adds `fetch` and returns its slot. Stamps `ready_generation`, which must be nonzero, on
    /// the task unless the task already carries one. The table owns the fetch only once every
    /// index holds it: on error the table is unchanged and the caller still owns `fetch`.
    pub fn append(
        self: *Table,
        allocator: std.mem.Allocator,
        fetch: active_fetch.Fetch,
        ready_generation: u64,
    ) !usize {
        try self.items.append(allocator, fetch);
        errdefer _ = self.items.pop();
        try self.bucket_indexes.append(allocator, .{});
        const index = self.items.items.len - 1;
        errdefer _ = self.bucket_indexes.pop();
        try self.indexAt(allocator, index, ready_generation);
        return index;
    }

    /// Removes the fetch in slot `index` and returns it; the caller owns it and must `deinit`
    /// it. The last fetch moves into `index`.
    pub fn removeAt(
        self: *Table,
        allocator: std.mem.Allocator,
        index: usize,
    ) active_fetch.Fetch {
        const removed_fetch = &self.items.items[index];
        self.removeIndexesFor(allocator, index, removed_fetch);
        const removed = self.items.swapRemove(index);
        _ = self.bucket_indexes.swapRemove(index);
        if (index < self.items.items.len)
            self.updateMovedIndex(index);
        return removed;
    }

    pub fn find(
        self: *Table,
        worker_session_id: u64,
        fetch_id: u64,
        body_id: u64,
    ) ?*active_fetch.Fetch {
        const index = self.findIndex(worker_session_id, fetch_id, body_id) orelse return null;
        return &self.items.items[index];
    }

    pub fn findIndex(
        self: *const Table,
        worker_session_id: u64,
        fetch_id: u64,
        body_id: u64,
    ) ?usize {
        return self.by_scoped.get(scopedFetch(worker_session_id, fetch_id, body_id));
    }

    pub fn indexByTask(self: *const Table, task: *task_model.Task) ?usize {
        return self.by_task.get(task);
    }

    pub fn indexByFetch(self: *const Table, worker_session_id: u64, fetch_id: u64) ?usize {
        return self.by_fetch.get(fetchKey(worker_session_id, fetch_id));
    }

    pub fn hasBody(self: *const Table, worker_session_id: u64, fetch_id: u64, body_id: u64) bool {
        return self.findIndex(worker_session_id, fetch_id, body_id) != null;
    }

    pub fn hasFetch(self: *const Table, worker_session_id: u64, fetch_id: u64) bool {
        return self.by_fetch.contains(fetchKey(worker_session_id, fetch_id));
    }

    /// Whether the session already uses `fetch_id` or `body_id` for an active fetch. Either one
    /// alone makes a new fetch a duplicate, since the fetch and body indexes each need it unique.
    pub fn hasWorkerIdentity(
        self: *const Table,
        worker_session_id: u64,
        fetch_id: u64,
        body_id: u64,
    ) bool {
        return self.by_fetch.contains(fetchKey(worker_session_id, fetch_id)) or
            self.by_body.contains(bodyKey(worker_session_id, body_id));
    }

    pub fn countForWorkerSession(self: *const Table, worker_session_id: u64) usize {
        const fetches = self.by_worker_session.get(worker_session_id) orelse return 0;
        return fetches.items.len;
    }

    pub fn scopedForWorkerSession(
        self: *const Table,
        worker_session_id: u64,
    ) ?[]const active_fetch.WorkerScopedFetch {
        const fetches = self.by_worker_session.get(worker_session_id) orelse return null;
        return fetches.items;
    }

    /// The active fetches the token of request `key` admitted, or null when it has none. The
    /// slice is the table's own list: removing a fetch reorders it.
    pub fn scopedForRequest(
        self: *const Table,
        key: budgets.BudgetKey,
    ) ?[]const active_fetch.WorkerScopedFetch {
        const fetches = self.by_request.get(key) orelse return null;
        return fetches.items;
    }

    fn indexAt(
        self: *Table,
        allocator: std.mem.Allocator,
        index: usize,
        ready_generation: u64,
    ) !void {
        const fetch = &self.items.items[index];
        const scoped = fetch.scopedFetch();
        const by_fetch = fetchKey(fetch.worker_session_id, fetch.fetch_id);
        const by_body = bodyKey(fetch.worker_session_id, fetch.body_id);

        var scoped_indexed = false;
        var fetch_indexed = false;
        var body_indexed = false;
        var task_indexed = false;
        var worker_indexed = false;
        var request_indexed = false;
        var generation_assigned = false;
        errdefer {
            if (request_indexed)
                _ = removeScopedFromIndexListAt(
                    budgets.BudgetKey,
                    allocator,
                    &self.by_request,
                    fetch.budget_key,
                    self.bucket_indexes.items[index].request,
                );
            if (worker_indexed)
                _ = removeScopedFromIndexListAt(
                    u64,
                    allocator,
                    &self.by_worker_session,
                    fetch.worker_session_id,
                    self.bucket_indexes.items[index].worker,
                );
            if (body_indexed)
                _ = self.by_body.remove(by_body);
            if (fetch_indexed)
                _ = self.by_fetch.remove(by_fetch);
            if (scoped_indexed)
                _ = self.by_scoped.remove(scoped);
            if (task_indexed)
                _ = self.by_task.remove(fetch.task);
            if (generation_assigned)
                fetch.task.ready_generation.store(0, .monotonic);
        }

        if (fetch.task.ready_generation.load(.monotonic) == 0) {
            std.debug.assert(ready_generation != 0);
            fetch.task.ready_generation.store(ready_generation, .monotonic);
            generation_assigned = true;
        }
        try self.by_scoped.putNoClobber(allocator, scoped, index);
        scoped_indexed = true;
        try self.by_fetch.putNoClobber(allocator, by_fetch, index);
        fetch_indexed = true;
        try self.by_body.putNoClobber(allocator, by_body, index);
        body_indexed = true;
        try self.by_task.putNoClobber(allocator, fetch.task, index);
        task_indexed = true;
        self.bucket_indexes.items[index].worker = try appendScopedToIndexList(
            u64,
            allocator,
            &self.by_worker_session,
            fetch.worker_session_id,
            scoped,
        );
        worker_indexed = true;
        self.bucket_indexes.items[index].request = try appendScopedToIndexList(
            budgets.BudgetKey,
            allocator,
            &self.by_request,
            fetch.budget_key,
            scoped,
        );
        request_indexed = true;
    }

    fn removeIndexesFor(
        self: *Table,
        allocator: std.mem.Allocator,
        index: usize,
        fetch: *const active_fetch.Fetch,
    ) void {
        const scoped = fetch.scopedFetch();
        _ = self.by_scoped.remove(scoped);
        _ = self.by_fetch.remove(fetchKey(fetch.worker_session_id, fetch.fetch_id));
        _ = self.by_body.remove(bodyKey(fetch.worker_session_id, fetch.body_id));
        _ = self.by_task.remove(fetch.task);
        fetch.task.ready_generation.store(0, .monotonic);
        const bucket_index = self.bucket_indexes.items[index];
        const moved_worker = removeScopedFromIndexListAt(
            u64,
            allocator,
            &self.by_worker_session,
            fetch.worker_session_id,
            bucket_index.worker,
        );
        self.repairWorkerBucketIndex(moved_worker, bucket_index.worker);
        const moved_request = removeScopedFromIndexListAt(
            budgets.BudgetKey,
            allocator,
            &self.by_request,
            fetch.budget_key,
            bucket_index.request,
        );
        self.repairRequestBucketIndex(moved_request, bucket_index.request);
    }

    fn updateMovedIndex(self: *Table, index: usize) void {
        const moved = &self.items.items[index];
        const scoped = moved.scopedFetch();
        if (self.by_scoped.getPtr(scoped)) |stored|
            stored.* = index;
        if (self.by_fetch.getPtr(fetchKey(moved.worker_session_id, moved.fetch_id))) |stored|
            stored.* = index;
        if (self.by_body.getPtr(bodyKey(moved.worker_session_id, moved.body_id))) |stored|
            stored.* = index;
        if (self.by_task.getPtr(moved.task)) |stored|
            stored.* = index;
    }

    fn repairWorkerBucketIndex(
        self: *Table,
        moved: ?active_fetch.WorkerScopedFetch,
        bucket_index: usize,
    ) void {
        const scoped = moved orelse return;
        const active_index = self.by_scoped.get(scoped) orelse unreachable;
        self.bucket_indexes.items[active_index].worker = bucket_index;
    }

    fn repairRequestBucketIndex(
        self: *Table,
        moved: ?active_fetch.WorkerScopedFetch,
        bucket_index: usize,
    ) void {
        const scoped = moved orelse return;
        const active_index = self.by_scoped.get(scoped) orelse unreachable;
        self.bucket_indexes.items[active_index].request = bucket_index;
    }
};

fn deinitScopedFetchLists(
    comptime Key: type,
    allocator: std.mem.Allocator,
    map: *std.AutoHashMapUnmanaged(Key, ScopedFetchList),
) void {
    var values = map.valueIterator();
    while (values.next()) |list|
        list.deinit(allocator);
    map.deinit(allocator);
}

fn appendScopedToIndexList(
    comptime Key: type,
    allocator: std.mem.Allocator,
    map: *std.AutoHashMapUnmanaged(Key, ScopedFetchList),
    key: Key,
    scoped: active_fetch.WorkerScopedFetch,
) !usize {
    var entry = try map.getOrPut(allocator, key);
    if (!entry.found_existing)
        entry.value_ptr.* = .empty;
    errdefer if (!entry.found_existing and entry.value_ptr.items.len == 0) {
        var removed = map.fetchRemove(key).?;
        removed.value.deinit(allocator);
    };
    try entry.value_ptr.append(allocator, scoped);
    return entry.value_ptr.items.len - 1;
}

fn removeScopedFromIndexListAt(
    comptime Key: type,
    allocator: std.mem.Allocator,
    map: *std.AutoHashMapUnmanaged(Key, ScopedFetchList),
    key: Key,
    index: usize,
) ?active_fetch.WorkerScopedFetch {
    const list = map.getPtr(key) orelse unreachable;
    std.debug.assert(index < list.items.len);
    const moved = if (index + 1 < list.items.len) list.items[list.items.len - 1] else null;
    _ = list.swapRemove(index);
    if (list.items.len != 0)
        return moved;
    var removed = map.fetchRemove(key).?;
    removed.value.deinit(allocator);
    return moved;
}

fn scopedFetch(worker_session_id: u64, fetch_id: u64, body_id: u64) active_fetch.WorkerScopedFetch {
    return .{
        .worker_session_id = worker_session_id,
        .fetch_id = fetch_id,
        .body_id = body_id,
    };
}

fn fetchKey(worker_session_id: u64, fetch_id: u64) WorkerFetchKey {
    return .{
        .worker_session_id = worker_session_id,
        .fetch_id = fetch_id,
    };
}

fn bodyKey(worker_session_id: u64, body_id: u64) WorkerBodyKey {
    return .{
        .worker_session_id = worker_session_id,
        .body_id = body_id,
    };
}

//! The gateway's routes: for every fetch the gateway admitted, the shard that runs it and the
//! security cell it was admitted under, keyed by the fetch and body ids the worker chose within
//! its session. A route here is one fetch's way to its shard, unrelated to the routes a worker
//! serves. The gateway's loop thread owns the router.
//!
//! Every key includes the worker session, so one worker's ids never resolve to another worker's
//! fetch. A route is in all four indexes or in none: when an index fails to take it, `record`
//! removes it from the ones it already reached, so no command resolves half a route. Within a
//! session a fetch id and a body id each belong to one route, which `record` asserts after the
//! caller has checked `containsIdentity`. A route exists from admission until its fetch retires
//! or its worker goes; whoever removes it also undoes the admission counts (`retireRoute` in
//! `runtime/worker_flow.zig`).
//!
//! A route also keeps what admission decided about its fetch, the security cell and the policy
//! table entry its token named, so a fetch resubmitted after its shard restarts
//! (`runtime/shard_flow.zig`) runs under the same pool key and the same network policy on every
//! hop.

const std = @import("std");

const policy_mod = @import("policy.zig");

pub const RouteKey = struct {
    worker_session_id: u64,
    fetch_id: u64,
    body_id: u64,
};

pub const FetchKey = struct {
    worker_session_id: u64,
    fetch_id: u64,
};

pub const BodyKey = struct {
    worker_session_id: u64,
    body_id: u64,
};

pub const Record = struct {
    shard_index: usize,
    security_cell_id: policy_mod.PoolIsolationId,
    /// The id of the `policy.PolicyTable` entry the fetch's verified token named. The table
    /// never changes for the life of the gateway, so the id names the same entry at any later
    /// resubmission.
    policy_id: u16,
};

pub const Route = struct {
    key: RouteKey,
    record: Record,
};

const RouteEntry = struct {
    record: Record,
    worker_bucket_index: usize,
};

const RouteKeyList = std.array_list.Aligned(RouteKey, null);

pub const Router = struct {
    by_route: std.AutoHashMapUnmanaged(RouteKey, RouteEntry) = .empty,
    by_fetch: std.AutoHashMapUnmanaged(FetchKey, RouteKey) = .empty,
    by_body: std.AutoHashMapUnmanaged(BodyKey, RouteKey) = .empty,
    by_worker: std.AutoHashMapUnmanaged(u64, RouteKeyList) = .empty,

    pub fn deinit(self: *Router, allocator: std.mem.Allocator) void {
        self.by_route.deinit(allocator);
        self.by_fetch.deinit(allocator);
        self.by_body.deinit(allocator);
        deinitRouteKeyLists(allocator, &self.by_worker);
        self.* = undefined;
    }

    pub fn containsIdentity(
        self: *const Router,
        worker_session_id: u64,
        fetch_id: u64,
        body_id: u64,
    ) bool {
        const route_key = routeKey(worker_session_id, fetch_id, body_id);
        return self.by_route.contains(route_key) or
            self.by_fetch.contains(fetchKey(worker_session_id, fetch_id)) or
            self.by_body.contains(bodyKey(worker_session_id, body_id));
    }

    /// Records the route of a newly admitted fetch after the caller found its identity unused
    /// with `containsIdentity`. On error nothing is recorded.
    pub fn record(
        self: *Router,
        allocator: std.mem.Allocator,
        key: RouteKey,
        route_record: Record,
    ) !void {
        std.debug.assert(!self.containsIdentity(key.worker_session_id, key.fetch_id, key.body_id));
        try self.by_route.putNoClobber(allocator, key, .{
            .record = route_record,
            .worker_bucket_index = std.math.maxInt(usize),
        });
        var route_indexed = true;
        var fetch_indexed = false;
        var body_indexed = false;
        var worker_indexed = false;
        errdefer {
            if (worker_indexed) {
                const entry = self.by_route.get(key).?;
                _ = removeRouteFromWorkerListAt(
                    allocator,
                    &self.by_worker,
                    key.worker_session_id,
                    entry.worker_bucket_index,
                );
            }
            if (body_indexed)
                _ = self.by_body.remove(bodyKey(key.worker_session_id, key.body_id));
            if (fetch_indexed)
                _ = self.by_fetch.remove(fetchKey(key.worker_session_id, key.fetch_id));
            if (route_indexed)
                _ = self.by_route.remove(key);
        }
        try self.by_fetch.putNoClobber(allocator, fetchKey(key.worker_session_id, key.fetch_id), key);
        fetch_indexed = true;
        try self.by_body.putNoClobber(allocator, bodyKey(key.worker_session_id, key.body_id), key);
        body_indexed = true;
        const worker_bucket_index = try appendRouteToWorkerList(
            allocator,
            &self.by_worker,
            key.worker_session_id,
            key,
        );
        self.by_route.getPtr(key).?.worker_bucket_index = worker_bucket_index;
        worker_indexed = true;
        route_indexed = false;
    }

    pub fn routeForKey(self: *const Router, key: RouteKey) ?Route {
        const entry = self.by_route.get(key) orelse return null;
        return .{ .key = key, .record = entry.record };
    }

    pub fn routeForFetch(self: *const Router, worker_session_id: u64, fetch_id: u64) ?Route {
        const key = self.by_fetch.get(fetchKey(worker_session_id, fetch_id)) orelse return null;
        return self.routeForKey(key);
    }

    /// The route of `body_id`, or null when that body belongs to a fetch other than `fetch_id`.
    pub fn routeForBody(self: *const Router, worker_session_id: u64, fetch_id: u64, body_id: u64) ?Route {
        const key = self.by_body.get(bodyKey(worker_session_id, body_id)) orelse return null;
        if (key.fetch_id != fetch_id)
            return null;
        return self.routeForKey(key);
    }

    pub fn remove(self: *Router, allocator: std.mem.Allocator, key: RouteKey) ?Route {
        const removed = self.by_route.fetchRemove(key) orelse return null;
        _ = self.by_fetch.remove(fetchKey(key.worker_session_id, key.fetch_id));
        _ = self.by_body.remove(bodyKey(key.worker_session_id, key.body_id));
        const moved = removeRouteFromWorkerListAt(
            allocator,
            &self.by_worker,
            key.worker_session_id,
            removed.value.worker_bucket_index,
        );
        self.repairWorkerBucketIndex(moved, removed.value.worker_bucket_index);
        return .{ .key = key, .record = removed.value.record };
    }

    /// Removes every route of `worker_session_id`, passing each to `on_remove` once it has left
    /// every index.
    pub fn removeWorkerRoutes(
        self: *Router,
        allocator: std.mem.Allocator,
        comptime Context: type,
        context: Context,
        worker_session_id: u64,
        comptime on_remove: fn (Context, Route) void,
    ) void {
        while (true) {
            const routes = self.by_worker.getPtr(worker_session_id) orelse return;
            if (routes.items.len == 0)
                return;
            const key = routes.items[routes.items.len - 1];
            const route = self.remove(allocator, key) orelse unreachable;
            on_remove(context, route);
        }
    }

    fn repairWorkerBucketIndex(self: *Router, moved: ?RouteKey, bucket_index: usize) void {
        const key = moved orelse return;
        const entry = self.by_route.getPtr(key) orelse unreachable;
        entry.worker_bucket_index = bucket_index;
    }
};

pub fn routeKey(worker_session_id: u64, fetch_id: u64, body_id: u64) RouteKey {
    return .{
        .worker_session_id = worker_session_id,
        .fetch_id = fetch_id,
        .body_id = body_id,
    };
}

fn fetchKey(worker_session_id: u64, fetch_id: u64) FetchKey {
    return .{
        .worker_session_id = worker_session_id,
        .fetch_id = fetch_id,
    };
}

fn bodyKey(worker_session_id: u64, body_id: u64) BodyKey {
    return .{
        .worker_session_id = worker_session_id,
        .body_id = body_id,
    };
}

fn deinitRouteKeyLists(
    allocator: std.mem.Allocator,
    map: *std.AutoHashMapUnmanaged(u64, RouteKeyList),
) void {
    var values = map.valueIterator();
    while (values.next()) |list|
        list.deinit(allocator);
    map.deinit(allocator);
}

fn appendRouteToWorkerList(
    allocator: std.mem.Allocator,
    map: *std.AutoHashMapUnmanaged(u64, RouteKeyList),
    worker_session_id: u64,
    key: RouteKey,
) !usize {
    var entry = try map.getOrPut(allocator, worker_session_id);
    if (!entry.found_existing)
        entry.value_ptr.* = .empty;
    errdefer if (!entry.found_existing and entry.value_ptr.items.len == 0) {
        var removed = map.fetchRemove(worker_session_id).?;
        removed.value.deinit(allocator);
    };
    try entry.value_ptr.append(allocator, key);
    return entry.value_ptr.items.len - 1;
}

fn removeRouteFromWorkerListAt(
    allocator: std.mem.Allocator,
    map: *std.AutoHashMapUnmanaged(u64, RouteKeyList),
    worker_session_id: u64,
    index: usize,
) ?RouteKey {
    const routes = map.getPtr(worker_session_id) orelse unreachable;
    std.debug.assert(index < routes.items.len);
    const moved = if (index + 1 < routes.items.len) routes.items[routes.items.len - 1] else null;
    _ = routes.swapRemove(index);
    if (routes.items.len != 0)
        return moved;
    var removed = map.fetchRemove(worker_session_id).?;
    removed.value.deinit(allocator);
    return moved;
}

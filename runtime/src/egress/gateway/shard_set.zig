//! The egress gateway's shards: their lifetimes, the wake descriptors the readiness ring polls,
//! and which shards each worker session has fetches on, so that a worker-wide detach, cancel or
//! wake, or the cancel of one of its requests, reaches only those shards. The gateway's main loop
//! thread owns the set. Routing a fetch and deciding when to drop a worker are the gateway
//! loop's job (`runtime/`).
//!
//! Every admitted fetch records one reference on its session's shard (`recordWorkerFetch`), and
//! retiring its route drops it (`removeWorkerFetch`); `shards_by_worker` and
//! `worker_shard_positions` always describe the same pairs. A fetch an engine still runs for its
//! worker has a route, so every such fetch sits on a shard its session lists.

const std = @import("std");
const builtin = @import("builtin");

const active_fetch = @import("active_fetch.zig");
const budgets = @import("budgets.zig");
const engine_mod = @import("engine.zig");
const policy_mod = @import("policy.zig");
const readiness_mod = @import("readiness.zig");
const shard_mod = @import("shard.zig");

pub const Set = struct {
    list: std.array_list.Aligned(shard_mod.Shard, null) = .empty,
    interests: std.array_list.Aligned(readiness_mod.ShardFd, null) = .empty,
    shards_by_worker: std.AutoHashMapUnmanaged(u64, WorkerShardList) = .empty,
    worker_shard_positions: std.AutoHashMapUnmanaged(WorkerShardKey, usize) = .empty,

    /// `memory_budget_bytes` caps each shard's counting allocator (0 for no
    /// cap). The gateway passes `supervisor_limits.shard_memory.budget_bytes`;
    /// tests pass what their scenario needs.
    pub fn init(
        allocator: std.mem.Allocator,
        shard_count: usize,
        engine_config: engine_mod.Config,
        memory_budget_bytes: u64,
    ) !Set {
        var set = Set{};
        errdefer set.deinit(allocator);
        try set.list.ensureTotalCapacity(allocator, shard_count);
        for (0..shard_count) |index| {
            try set.list.append(allocator, try shard_mod.Shard.init(allocator, .{
                .id = index,
                .engine = engine_config,
                .memory_budget_bytes = memory_budget_bytes,
            }));
        }
        return set;
    }

    pub fn deinit(self: *Set, allocator: std.mem.Allocator) void {
        for (self.list.items) |*shard|
            shard.deinit();
        self.list.deinit(allocator);
        self.interests.deinit(allocator);
        deinitWorkerShardLists(allocator, &self.shards_by_worker);
        self.worker_shard_positions.deinit(allocator);
        self.* = undefined;
    }

    pub fn len(self: *const Set) usize {
        return self.list.items.len;
    }

    pub fn get(self: *Set, index: usize) *shard_mod.Shard {
        std.debug.assert(index < self.list.items.len);
        return &self.list.items[index];
    }

    /// Creates every shard's threads and rings. The gateway calls it before
    /// its seccomp filter, which denies creating either afterwards. On
    /// failure, the shards already started are stopped again.
    pub fn startAll(
        self: *Set,
        callback_ctx: ?*anyopaque,
        packet_sender: engine_mod.PacketSender,
        body_sender: engine_mod.BodyChunkBatchSender,
        worker_pressure_probe: engine_mod.WorkerPressureProbe,
        worker_fault_reporter: engine_mod.WorkerFaultReporter,
    ) !void {
        var started_count: usize = 0;
        errdefer self.stopStarted(started_count);
        for (self.list.items) |*shard| {
            try shard.start(
                callback_ctx,
                packet_sender,
                body_sender,
                worker_pressure_probe,
                worker_fault_reporter,
            );
            started_count += 1;
        }
    }

    pub fn stopStarted(self: *Set, started_count: usize) void {
        std.debug.assert(started_count <= self.list.items.len);
        stopStartedSlice(shard_mod.Shard, self.list.items, started_count);
    }

    pub fn refreshInterests(
        self: *Set,
        allocator: std.mem.Allocator,
    ) ![]const readiness_mod.ShardFd {
        try self.interests.resize(allocator, self.list.items.len);
        for (self.list.items, 0..) |shard, index| {
            self.interests.items[index] = .{
                .index = index,
                .wake_fd = shard.wakeFd(),
            };
        }
        return self.interests.items;
    }

    /// The shard for a fetch to `url` under `isolation`, the pool key its submit passes
    /// (`shard.hashFetch`).
    pub fn selectIndex(
        self: *const Set,
        isolation: policy_mod.PoolIsolation,
        url: []const u8,
    ) usize {
        return shard_mod.hashFetch(isolation, url, self.list.items.len);
    }

    pub fn collectReadyCompleted(
        self: *Set,
        shard_index: usize,
        list_gpa: std.mem.Allocator,
        completed: *std.array_list.Aligned(active_fetch.WorkerScopedFetch, null),
    ) !void {
        // `completed` belongs to the gateway, so it grows with `list_gpa`
        // (`Engine.collectReadyCompletedInto` says why).
        try self.get(shard_index).engine.collectReadyCompletedInto(list_gpa, completed);
    }

    pub fn detachWorker(self: *Set, worker_session_id: u64) void {
        const shards = self.shards_by_worker.get(worker_session_id) orelse return;
        for (shards.items) |worker_shard|
            self.get(worker_shard.index).engine.detachWorker(worker_session_id);
    }

    /// Cancels every fetch of the request `key` names on the shards its session has fetches
    /// on, which hold all of them (see the file header). A key whose session has none is a
    /// no-op, so an ended request that never fetched costs one lookup.
    pub fn cancelRequest(self: *Set, key: budgets.BudgetKey) void {
        const shards = self.shards_by_worker.get(key.session_id) orelse return;
        for (shards.items) |worker_shard|
            self.get(worker_shard.index).engine.cancelRequest(key);
    }

    pub fn cancelWorkerForBackpressure(self: *Set, worker_session_id: u64) void {
        const shards = self.shards_by_worker.get(worker_session_id) orelse return;
        for (shards.items) |worker_shard|
            self.get(worker_shard.index).engine.cancelWorkerForBackpressure(worker_session_id);
    }

    pub fn wakeForWorkerPressureChange(self: *Set, worker_session_id: u64) void {
        const shards = self.shards_by_worker.get(worker_session_id) orelse return;
        for (shards.items) |worker_shard|
            self.get(worker_shard.index).engine.wakeForWorkerPressureChange(worker_session_id);
    }

    pub fn recordWorkerFetch(
        self: *Set,
        allocator: std.mem.Allocator,
        worker_session_id: u64,
        shard_index: usize,
    ) !void {
        std.debug.assert(shard_index < self.list.items.len);
        const key = WorkerShardKey{
            .worker_session_id = worker_session_id,
            .shard_index = shard_index,
        };
        if (self.worker_shard_positions.get(key)) |position| {
            const shards = self.shards_by_worker.getPtr(worker_session_id) orelse unreachable;
            std.debug.assert(position < shards.items.len);
            std.debug.assert(shards.items[position].index == shard_index);
            shards.items[position].count += 1;
            return;
        }

        var entry = try self.shards_by_worker.getOrPut(allocator, worker_session_id);
        if (!entry.found_existing)
            entry.value_ptr.* = .empty;
        errdefer if (!entry.found_existing and entry.value_ptr.items.len == 0) {
            var removed = self.shards_by_worker.fetchRemove(worker_session_id).?;
            removed.value.deinit(allocator);
        };

        const position = entry.value_ptr.items.len;
        try entry.value_ptr.append(allocator, .{
            .index = shard_index,
            .count = 1,
        });
        errdefer _ = entry.value_ptr.pop();
        try self.worker_shard_positions.putNoClobber(allocator, key, position);
    }

    pub fn removeWorkerFetch(
        self: *Set,
        allocator: std.mem.Allocator,
        worker_session_id: u64,
        shard_index: usize,
    ) void {
        const key = WorkerShardKey{
            .worker_session_id = worker_session_id,
            .shard_index = shard_index,
        };
        const position = self.worker_shard_positions.get(key) orelse return;
        const shards = self.shards_by_worker.getPtr(worker_session_id) orelse unreachable;
        std.debug.assert(position < shards.items.len);
        std.debug.assert(shards.items[position].index == shard_index);
        if (shards.items[position].count > 1) {
            shards.items[position].count -= 1;
            return;
        }

        _ = self.worker_shard_positions.remove(key);
        const moved = if (position + 1 < shards.items.len) shards.items[shards.items.len - 1] else null;
        _ = shards.swapRemove(position);
        if (moved) |moved_shard| {
            const moved_key = WorkerShardKey{
                .worker_session_id = worker_session_id,
                .shard_index = moved_shard.index,
            };
            const moved_position = self.worker_shard_positions.getPtr(moved_key) orelse unreachable;
            moved_position.* = position;
        }
        if (shards.items.len != 0)
            return;
        var removed = self.shards_by_worker.fetchRemove(worker_session_id).?;
        removed.value.deinit(allocator);
    }
};

const WorkerShard = struct {
    index: usize,
    count: usize,
};

const WorkerShardKey = struct {
    worker_session_id: u64,
    shard_index: usize,
};

const WorkerShardList = std.array_list.Aligned(WorkerShard, null);

fn stopStartedSlice(comptime ShardType: type, shards: []ShardType, started_count: usize) void {
    std.debug.assert(started_count <= shards.len);
    var remaining = started_count;
    while (remaining != 0) {
        remaining -= 1;
        shards[remaining].stop();
    }
}

pub const testing = if (builtin.is_test) struct {
    pub const stopStartedSlice = shard_set_test_stopStartedSlice;

    pub fn workerShardCount(set: *const Set, worker_session_id: u64) usize {
        const shards = set.shards_by_worker.get(worker_session_id) orelse return 0;
        return shards.items.len;
    }

    pub fn workerShardRefCount(
        set: *const Set,
        worker_session_id: u64,
        shard_index: usize,
    ) usize {
        const position = set.worker_shard_positions.get(.{
            .worker_session_id = worker_session_id,
            .shard_index = shard_index,
        }) orelse return 0;
        const shards = set.shards_by_worker.get(worker_session_id) orelse return 0;
        return shards.items[position].count;
    }
} else struct {};

fn shard_set_test_stopStartedSlice(comptime ShardType: type, shards: []ShardType, started_count: usize) void {
    stopStartedSlice(ShardType, shards, started_count);
}

fn deinitWorkerShardLists(
    allocator: std.mem.Allocator,
    map: *std.AutoHashMapUnmanaged(u64, WorkerShardList),
) void {
    var values = map.valueIterator();
    while (values.next()) |list|
        list.deinit(allocator);
    map.deinit(allocator);
}

//! The worker sessions attached to the gateway: their slots, the index from session id to slot,
//! the readiness interests of their eventfds, and the queue of sessions to drop. The gateway's
//! loop thread owns the registry.
//!
//! The registry assigns session ids, never a worker: a counter from 1 that skips 0. An egress
//! token names its session by id (`common/ipc/egress_token.zig`), so no id may come back within
//! one gateway's life, or a later session would be admitted under an earlier one's tokens; a
//! 64-bit counter that counts attaches cannot wrap that soon.
//!
//! The registry owns only the sessions themselves, with the fetch budgets each record holds
//! (`sessions.Worker.budgets`): removing one here frees its budgets but leaves its routes and
//! shard state alone, and the caller tears those down before it destroys the removed session
//! (`removeWorker` in `runtime/worker_flow.zig`).

const std = @import("std");
const ipc = @import("collo_ipc");

const drop_queue = @import("drop_queue.zig");
const policy_mod = @import("policy.zig");
const readiness_mod = @import("readiness.zig");
const sessions = @import("sessions.zig");

pub const Attached = struct {
    index: usize,
    session_id: u64,
};

pub const Registry = struct {
    list: std.array_list.Aligned(sessions.Worker, null) = .empty,
    index_by_session: std.AutoHashMapUnmanaged(u64, usize) = .empty,
    interests: std.array_list.Aligned(readiness_mod.WorkerFd, null) = .empty,
    drop_queue: drop_queue.Queue = .{},
    drop_all_active: bool = false,
    next_session_id: u64 = 1,

    pub fn deinit(self: *Registry, allocator: std.mem.Allocator) void {
        for (self.list.items) |*worker|
            worker.deinit(allocator);
        self.list.deinit(allocator);
        self.index_by_session.deinit(allocator);
        self.interests.deinit(allocator);
        self.drop_queue.deinit(allocator);
        self.* = undefined;
    }

    pub fn len(self: *const Registry) usize {
        return self.list.items.len;
    }

    /// Attaches a new session that takes over `endpoint`, leaving it undefined, and stamps the
    /// session id into each of its rings and pools. On error the caller still owns `endpoint`.
    pub fn attachEndpoint(
        self: *Registry,
        allocator: std.mem.Allocator,
        endpoint: *ipc.egress_shared.Endpoint,
        security_cell_id: policy_mod.PoolIsolationId,
    ) !Attached {
        const session_id = self.nextSessionId();
        try self.index_by_session.ensureUnusedCapacity(allocator, 1);
        try self.list.ensureUnusedCapacity(allocator, 1);

        endpoint.command.setSession(session_id, session_id);
        endpoint.completion.setSession(session_id, session_id);
        endpoint.body_pool.setSession(session_id, session_id);
        endpoint.upload_pool.setSession(session_id, session_id);

        const index = self.list.items.len;
        self.index_by_session.putAssumeCapacityNoClobber(session_id, index);
        var indexed = true;
        errdefer {
            if (indexed)
                _ = self.index_by_session.remove(session_id);
        }

        self.list.appendAssumeCapacity(.{
            .session_id = session_id,
            .security_cell_id = security_cell_id,
            .endpoint = endpoint.*,
        });
        endpoint.* = undefined;
        indexed = false;
        return .{
            .index = index,
            .session_id = session_id,
        };
    }

    /// Removes the session in slot `index` and returns it; the caller tears down what refers to
    /// it and then calls `deinit`. The last session moves into `index`.
    pub fn removeAt(self: *Registry, index: usize) sessions.Worker {
        std.debug.assert(index < self.list.items.len);
        const removed = self.list.swapRemove(index);
        std.debug.assert(self.index_by_session.remove(removed.session_id));
        if (index < self.list.items.len) {
            const swapped_session_id = self.list.items[index].session_id;
            const swapped_index = self.index_by_session.getPtr(swapped_session_id);
            std.debug.assert(swapped_index != null);
            swapped_index.?.* = index;
        }
        return removed;
    }

    pub fn byIndex(self: *Registry, index: usize) ?*sessions.Worker {
        if (index >= self.list.items.len)
            return null;
        return &self.list.items[index];
    }

    pub fn bySession(self: *Registry, session_id: u64) ?*sessions.Worker {
        const index = self.indexBySession(session_id) orelse return null;
        return self.byIndex(index);
    }

    pub fn indexBySession(self: *const Registry, session_id: u64) ?usize {
        return self.index_by_session.get(session_id);
    }

    pub fn markForDrop(
        self: *Registry,
        allocator: std.mem.Allocator,
        worker_session_id: u64,
    ) void {
        self.drop_queue.mark(allocator, worker_session_id);
    }

    /// The next session to drop, or null. Once the drop queue has lost a session to overflow,
    /// it returns attached sessions one after another until none is left, so the caller must
    /// remove each session it gets before asking again.
    pub fn nextDrop(self: *Registry) ?u64 {
        if (self.drop_queue.next()) |worker_session_id|
            return worker_session_id;
        if (self.drop_all_active) {
            if (self.list.items.len != 0)
                return self.list.items[0].session_id;
            self.drop_all_active = false;
            return null;
        }
        if (!self.drop_queue.takeForcedOverflow())
            return null;
        self.drop_all_active = true;
        if (self.list.items.len == 0) {
            self.drop_all_active = false;
            return null;
        }
        return self.list.items[0].session_id;
    }

    pub fn refreshInterests(
        self: *Registry,
        allocator: std.mem.Allocator,
    ) ![]const readiness_mod.WorkerFd {
        try self.interests.resize(allocator, self.list.items.len);
        for (self.list.items, 0..) |worker, index| {
            self.interests.items[index] = .{
                .session_id = worker.session_id,
                .command_eventfd = worker.endpoint.command_eventfd,
                .liveness_fd = worker.endpoint.peer_liveness_fd,
            };
        }
        return self.interests.items;
    }

    fn nextSessionId(self: *Registry) u64 {
        const session_id = self.next_session_id;
        self.next_session_id +%= 1;
        if (self.next_session_id == 0)
            self.next_session_id = 1;
        return session_id;
    }
};

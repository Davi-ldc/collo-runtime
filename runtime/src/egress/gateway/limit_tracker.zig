//! The active-fetch counts per worker session and per security cell, which bound how many fetches
//! a session and a cell run at once whatever tokens they present. Admission checks both before a
//! fetch reaches a shard engine (`runtime/worker_flow.zig`), and whatever retires the fetch's route
//! lowers both (`retireRoute`). The gateway's loop thread owns the tracker.
//!
//! A count of zero has no entry, so the maps hold only sessions and cells with fetches running.

const std = @import("std");

const policy_mod = @import("policy.zig");

pub const Tracker = struct {
    active_fetches_by_worker: std.AutoHashMapUnmanaged(u64, usize) = .empty,
    active_fetches_by_security_cell: std.AutoHashMapUnmanaged(
        policy_mod.PoolIsolationId,
        usize,
    ) = .empty,

    pub fn deinit(self: *Tracker, allocator: std.mem.Allocator) void {
        self.active_fetches_by_worker.deinit(allocator);
        self.active_fetches_by_security_cell.deinit(allocator);
        self.* = undefined;
    }

    pub fn activeFetchesForWorker(self: *const Tracker, worker_session_id: u64) usize {
        return self.active_fetches_by_worker.get(worker_session_id) orelse 0;
    }

    pub fn incrementWorkerFetchCount(
        self: *Tracker,
        allocator: std.mem.Allocator,
        worker_session_id: u64,
    ) !void {
        const entry = try self.active_fetches_by_worker.getOrPut(allocator, worker_session_id);
        if (!entry.found_existing)
            entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;
    }

    pub fn decrementWorkerFetchCount(self: *Tracker, worker_session_id: u64) void {
        const count = self.active_fetches_by_worker.getPtr(worker_session_id) orelse return;
        if (count.* <= 1) {
            _ = self.active_fetches_by_worker.remove(worker_session_id);
        } else {
            count.* -= 1;
        }
    }

    pub fn removeWorkerFetchCount(self: *Tracker, worker_session_id: u64) void {
        _ = self.active_fetches_by_worker.remove(worker_session_id);
    }

    pub fn activeFetchesForSecurityCell(
        self: *const Tracker,
        security_cell_id: policy_mod.PoolIsolationId,
    ) usize {
        return self.active_fetches_by_security_cell.get(security_cell_id) orelse 0;
    }

    pub fn incrementSecurityCellFetchCount(
        self: *Tracker,
        allocator: std.mem.Allocator,
        security_cell_id: policy_mod.PoolIsolationId,
    ) !void {
        const entry = try self.active_fetches_by_security_cell.getOrPut(
            allocator,
            security_cell_id,
        );
        if (!entry.found_existing)
            entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;
    }

    pub fn decrementSecurityCellFetchCount(
        self: *Tracker,
        security_cell_id: policy_mod.PoolIsolationId,
    ) void {
        const count = self.active_fetches_by_security_cell.getPtr(security_cell_id) orelse return;
        if (count.* <= 1) {
            _ = self.active_fetches_by_security_cell.remove(security_cell_id);
        } else {
            count.* -= 1;
        }
    }
};

//! Assembly of the request bodies a worker sends through its upload pool, as a comptime mixin
//! over the gateway run on its loop thread. A fetch start with the body-pooled flag is admitted
//! in full (its token verified, a fetch taken from the token's budget, its route and counts
//! recorded; `runtime/worker_flow.zig`) and then waits here, with the submit options admission
//! chose for it, while the worker streams its body as upload-pool extents. Each extent is copied
//! into the fetch's assembly buffer and released to the pool at once, so the pool only carries
//! bytes in transit and no fetch holds pool space while it waits; `Policy.max_request_body_bytes`
//! bounds a body, not the pool's size. Once the announced length has arrived, the fetch goes to
//! its shard engine with the buffer handed over without a copy, and the task keeps it, so a
//! redirect replays the body as it does an inline one.
//!
//! The buffer comes from the gateway's allocator and goes back to it, never through the shard's
//! counting allocator, so the shard's memory count and budget never see it. The task may drop it
//! on an engine thread, which is safe because every shard's counting allocator forwards to that
//! same allocator (`shard.Shard.init`), and engine threads already free through it.
//!
//! Assembly state never outlives the fetch's route: whatever removes the route, a cancel, the
//! worker's removal, a failure or the `request_ended` of the request whose token admitted the
//! fetch, also drops it (`retireRoute` in `runtime/worker_flow.zig`). Only a failure gives the
//! fetch back to the token's budget; a canceled fetch stays spent, and the other two take the
//! budget away with the session or the request.

const std = @import("std");
const ipc = @import("collo_ipc");
const os_process = @import("collo_os").process;

const budgets = @import("../budgets.zig");
const engine_mod = @import("../engine.zig");
const router_mod = @import("../router.zig");
const sessions = @import("../sessions.zig");

pub const PendingKey = struct {
    worker_session_id: u64,
    fetch_id: u64,
};

pub const PendingUpload = struct {
    route_key: router_mod.RouteKey,
    shard_index: usize,
    /// What admission decided for the fetch: its pools, network policy, deadline and the request
    /// whose budget it took a fetch from (`budget_key`). Submission adds the assembled body as
    /// `owned_body`, which is null until then.
    options: engine_mod.SubmitOptions,
    /// Wire flags minus the pooled bit, so the engine task stores the same
    /// flags an inline submission would.
    flags: u32,
    method: []u8,
    url: []u8,
    /// Flat name/value byte storage `headers` slices point into.
    header_bytes: []u8,
    headers: []ipc.RequestHeader,
    /// The assembly buffer, sized to the announced length, from the gateway's allocator.
    /// Submission hands it to the engine with that allocator and empties this field, so `deinit`
    /// frees it only for a fetch that never reached the engine.
    buffer: []u8,
    /// Bytes assembled so far. Extents arrive in order, each announcing the running total.
    received: u64,
    /// Links the uploads of one request (`PendingUploads.by_request`).
    request_node: std.DoublyLinkedList.Node = .{},

    pub fn deinit(self: *PendingUpload, allocator: std.mem.Allocator) void {
        allocator.free(self.method);
        allocator.free(self.url);
        allocator.free(self.headers);
        allocator.free(self.header_bytes);
        if (self.buffer.len != 0)
            allocator.free(self.buffer);
        self.* = undefined;
    }
};

/// The gateway's uploads still assembling, by the fetch the worker's extents name and by the
/// request whose token admitted them, so `request_ended` finds a request's uploads without a
/// scan. An upload is in both indexes or in neither, and a request has an entry in `by_request`
/// only while its list holds an upload. The indexes own the uploads.
pub const PendingUploads = struct {
    by_fetch: std.AutoHashMapUnmanaged(PendingKey, *PendingUpload) = .empty,
    by_request: std.AutoHashMapUnmanaged(budgets.BudgetKey, std.DoublyLinkedList) = .empty,

    /// Frees every upload still assembling.
    pub fn deinit(self: *PendingUploads, allocator: std.mem.Allocator) void {
        var uploads = self.by_fetch.valueIterator();
        while (uploads.next()) |pending| {
            pending.*.deinit(allocator);
            allocator.destroy(pending.*);
        }
        self.by_fetch.deinit(allocator);
        self.by_request.deinit(allocator);
        self.* = undefined;
    }

    pub fn contains(self: *const PendingUploads, key: PendingKey) bool {
        return self.by_fetch.contains(key);
    }

    pub fn get(self: *const PendingUploads, key: PendingKey) ?*PendingUpload {
        return self.by_fetch.get(key);
    }

    /// An upload still assembling under the token of request `budget_key`, or null when it has
    /// none.
    pub fn anyOfRequest(
        self: *const PendingUploads,
        budget_key: budgets.BudgetKey,
    ) ?*PendingUpload {
        const uploads = self.by_request.get(budget_key) orelse return null;
        const node = uploads.first orelse unreachable;
        const pending: *PendingUpload = @fieldParentPtr("request_node", node);
        return pending;
    }

    /// Makes room in both indexes for one more upload, so `putAssumeCapacity` cannot fail.
    fn ensureUnusedCapacity(self: *PendingUploads, allocator: std.mem.Allocator) !void {
        try self.by_fetch.ensureUnusedCapacity(allocator, 1);
        try self.by_request.ensureUnusedCapacity(allocator, 1);
    }

    fn putAssumeCapacity(self: *PendingUploads, key: PendingKey, pending: *PendingUpload) void {
        self.by_fetch.putAssumeCapacityNoClobber(key, pending);
        const entry = self.by_request.getOrPutAssumeCapacity(pending.options.budget_key);
        if (!entry.found_existing)
            entry.value_ptr.* = .{};
        entry.value_ptr.append(&pending.request_node);
    }

    /// Takes the upload of `key` out of both indexes and returns it, or null when there is none;
    /// the caller owns the upload afterwards.
    fn remove(self: *PendingUploads, key: PendingKey) ?*PendingUpload {
        const removed = self.by_fetch.fetchRemove(key) orelse return null;
        const pending = removed.value;
        const budget_key = pending.options.budget_key;
        const uploads = self.by_request.getPtr(budget_key) orelse unreachable;
        uploads.remove(&pending.request_node);
        if (uploads.first == null)
            std.debug.assert(self.by_request.remove(budget_key));
        return pending;
    }
};

pub fn Methods(comptime Gateway: type) type {
    return struct {
        /// Holds an admitted body-pooled fetch until its body has arrived, then submits it on
        /// shard `shard_index` with the options admission chose. The caller keeps the admission
        /// and undoes it when this fails: with `error.EgressGatewayRequestBodyLimitExceeded` for an
        /// announced length of zero or above the policy, with
        /// `error.EgressGatewayDuplicateFetchIdentity` for a fetch id already assembling, or with
        /// `error.OutOfMemory`.
        pub fn registerPendingUpload(
            self: *Gateway,
            worker: *sessions.Worker,
            fetch: ipc.EgressFetchStartView,
            shard_index: usize,
            options: engine_mod.SubmitOptions,
        ) !void {
            std.debug.assert(options.owned_body == null);
            std.debug.assert(options.budget_key.session_id == worker.session_id);
            if (fetch.pooled_body_len == 0 or
                fetch.pooled_body_len > self.policy.max_request_body_bytes)
                return error.EgressGatewayRequestBodyLimitExceeded;
            const key = PendingKey{
                .worker_session_id = worker.session_id,
                .fetch_id = fetch.fetch_id,
            };
            if (self.pending_uploads.contains(key))
                return error.EgressGatewayDuplicateFetchIdentity;
            try self.pending_uploads.ensureUnusedCapacity(self.allocator);

            const pending = try self.allocator.create(PendingUpload);
            errdefer self.allocator.destroy(pending);
            const method = try self.allocator.dupe(u8, fetch.method);
            errdefer self.allocator.free(method);
            const url = try self.allocator.dupe(u8, fetch.url);
            errdefer self.allocator.free(url);
            var header_bytes_len: usize = 0;
            for (fetch.headers) |header|
                header_bytes_len += header.name.len + header.value.len;
            const header_bytes = try self.allocator.alloc(u8, header_bytes_len);
            errdefer self.allocator.free(header_bytes);
            const headers = try self.allocator.alloc(ipc.RequestHeader, fetch.headers.len);
            errdefer self.allocator.free(headers);
            var offset: usize = 0;
            for (fetch.headers, 0..) |header, index| {
                const name = header_bytes[offset..][0..header.name.len];
                @memcpy(name, header.name);
                offset += header.name.len;
                const value = header_bytes[offset..][0..header.value.len];
                @memcpy(value, header.value);
                offset += header.value.len;
                headers[index] = .{ .name = name, .value = value };
            }
            const buffer = try self.allocator.alloc(u8, @intCast(fetch.pooled_body_len));
            errdefer self.allocator.free(buffer);

            pending.* = .{
                .route_key = .{
                    .worker_session_id = worker.session_id,
                    .fetch_id = fetch.fetch_id,
                    .body_id = fetch.body_id,
                },
                .shard_index = shard_index,
                .options = options,
                .flags = fetch.flags & ~ipc.egress_fetch_start_flag_body_pooled,
                .method = method,
                .url = url,
                .header_bytes = header_bytes,
                .headers = headers,
                .buffer = buffer,
                .received = 0,
            };
            self.pending_uploads.putAssumeCapacity(key, pending);
        }

        /// Applies a batch of upload extents and returns false when the worker must be dropped:
        /// a batch that does not decode, an extent the pool rejects, or invalid commands past the
        /// worker's budget.
        pub fn handleUploadChunkBatch(self: *Gateway, worker: *sessions.Worker, bytes: []const u8) bool {
            const chunks = ipc.decodeEgressUploadChunkBatch(self.decode_scratch, bytes) catch return false;
            var released_any = false;
            for (chunks) |chunk| {
                if (!self.applyUploadChunk(worker, chunk, &released_any))
                    return false;
            }
            // Released extents refill the worker's pool, and its upload pump
            // waits on the completion eventfd.
            if (released_any)
                ipc.egress_shared.notify(worker.endpoint.completion_eventfd);
            return true;
        }

        pub fn applyUploadChunk(
            self: *Gateway,
            worker: *sessions.Worker,
            chunk: ipc.EgressUploadChunkView,
            released_any: *bool,
        ) bool {
            // An extent the pool rejects means corrupt shared state, so the
            // worker is dropped as for a corrupt command ring.
            const extent = worker.endpoint.upload_pool.borrowContiguousChunk(
                chunk.upload_pool_offset,
                chunk.len,
            ) catch |err| {
                std.log.warn("egress gateway invalid upload extent session={d} fetch_id={d}: {s}", .{
                    worker.session_id,
                    chunk.fetch_id,
                    @errorName(err),
                });
                return false;
            };
            const key = PendingKey{
                .worker_session_id = worker.session_id,
                .fetch_id = chunk.fetch_id,
            };
            const pending = self.pending_uploads.get(key) orelse {
                // Extents can still arrive after a cancel, a failure or the
                // request's end removed the fetch; their space just goes back
                // to the pool.
                releaseUploadExtent(worker, chunk, released_any);
                return true;
            };
            if (chunk.body_bytes_total != pending.received + chunk.len or
                chunk.body_bytes_total > pending.buffer.len)
            {
                releaseUploadExtent(worker, chunk, released_any);
                self.failPendingUpload(worker, key, "egress upload ledger mismatch");
                return self.recordInvalidWorkerCommand(worker);
            }
            @memcpy(pending.buffer[@intCast(pending.received)..][0..chunk.len], extent);
            pending.received += chunk.len;
            releaseUploadExtent(worker, chunk, released_any);
            if (pending.received == pending.buffer.len)
                self.submitAssembledUpload(worker, key);
            return true;
        }

        pub fn submitAssembledUpload(self: *Gateway, worker: *sessions.Worker, key: PendingKey) void {
            const pending = self.pending_uploads.remove(key) orelse return;
            defer {
                pending.deinit(self.allocator);
                self.allocator.destroy(pending);
            }
            // The engine owns the buffer from the call on, whether it
            // succeeds or fails, and frees it with the allocator that
            // allocated it (`engine.SubmitOptions.owned_body`).
            var options = pending.options;
            options.owned_body = .{ .bytes = pending.buffer, .allocator = self.allocator };
            pending.buffer = &.{};
            self.shards.get(pending.shard_index).engine.submit(worker.session_id, .{
                .fetch_id = key.fetch_id,
                // `submit` never reads the token: `options` carries what admission granted.
                .egress_token = ipc.egress_token.none,
                .body_id = pending.route_key.body_id,
                .flags = pending.flags,
                .max_body_bytes = 0,
                .method = pending.method,
                .url = pending.url,
                .headers = pending.headers,
                .body = &.{},
            }, options) catch |err| {
                // The fetch never reached the engine, so its budget gets the
                // fetch back and its route and counts are removed.
                self.queueFetchError(worker.session_id, key.fetch_id, pending.route_key.body_id, @errorName(err)) catch |send_err|
                    std.log.warn("failed to queue egress upload submit error: {s}", .{@errorName(send_err)});
                worker.budgets.refund(options.budget_key, os_process.monotonicNowNsOrZero());
                self.removeRoute(pending.route_key);
                return;
            };
        }

        /// Ends an assembling fetch: queues `message` to the worker as its error, gives the
        /// token's budget its fetch back and removes the route.
        pub fn failPendingUpload(
            self: *Gateway,
            worker: *sessions.Worker,
            key: PendingKey,
            message: []const u8,
        ) void {
            const pending = self.pending_uploads.remove(key) orelse return;
            const route_key = pending.route_key;
            const budget_key = pending.options.budget_key;
            self.queueFetchError(worker.session_id, key.fetch_id, route_key.body_id, message) catch |send_err|
                std.log.warn("failed to queue egress upload failure: {s}", .{@errorName(send_err)});
            pending.deinit(self.allocator);
            self.allocator.destroy(pending);
            worker.budgets.refund(budget_key, os_process.monotonicNowNsOrZero());
            self.removeRoute(route_key);
        }

        /// Drops every upload still assembling under the token of `budget_key`, whose request
        /// ended: each loses its route, counts and buffer, the worker gets no packet for it, and
        /// no budget gets a fetch back, since the request's budget ended with it.
        pub fn dropRequestUploads(self: *Gateway, budget_key: budgets.BudgetKey) void {
            while (self.pending_uploads.anyOfRequest(budget_key)) |pending| {
                const route_key = pending.route_key;
                self.removeRoute(route_key);
                // Removing the route retires the upload (`retireRoute`); this
                // call only guarantees the loop advances should the route be
                // gone already.
                self.retirePendingUpload(route_key.worker_session_id, route_key.fetch_id);
            }
        }

        /// Drops the assembly state, if any, of a fetch whose route is being removed.
        pub fn retirePendingUpload(self: *Gateway, worker_session_id: u64, fetch_id: u64) void {
            const pending = self.pending_uploads.remove(.{
                .worker_session_id = worker_session_id,
                .fetch_id = fetch_id,
            }) orelse return;
            pending.deinit(self.allocator);
            self.allocator.destroy(pending);
        }

        pub fn deinitPendingUploads(self: *Gateway) void {
            self.pending_uploads.deinit(self.allocator);
        }

        fn releaseUploadExtent(
            worker: *sessions.Worker,
            chunk: ipc.EgressUploadChunkView,
            released_any: *bool,
        ) void {
            // The release queue holds one entry per pool slot, so it cannot
            // overflow. A failure means corrupt shared state, and the extent
            // is left for the session's teardown.
            worker.endpoint.upload_pool.releaseChunk(chunk.upload_pool_offset, chunk.len) catch |err| {
                std.log.warn("egress gateway upload extent release failed session={d}: {s}", .{
                    worker.session_id,
                    @errorName(err),
                });
                return;
            };
            released_any.* = true;
        }
    };
}

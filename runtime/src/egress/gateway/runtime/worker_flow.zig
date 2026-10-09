//! What the gateway does with its worker sessions, as a comptime mixin over the gateway run on its
//! loop thread: draining a worker's command ring, admitting fetch starts, handling cancels and
//! body releases, removing workers, and measuring each worker's backpressure.
//!
//! Every command is untrusted input to the process that holds the network capability, and the
//! gateway trusts nothing in a fetch start before `egress_token.verify` accepts its token under
//! the hello's key (`runtime/control_flow.zig`). The request ids, the deadline, the budget and the
//! network policy of a fetch come from the verified token alone, never from the packet around it.
//! Admission checks, in this order, the tag, the token's session against the session whose ring
//! carried it, the deadline, the policy id in the hello's table, the active-fetch caps of the
//! session and of its security cell, and unused fetch and body ids in the session. Only then does
//! it take one fetch from the token's budget (`budgets.zig`), its first step that changes state,
//! so a refused fetch costs no budget. It then records the route and the counts and undoes them,
//! with the budget use, unless the fetch reaches an engine or the upload assembler; a failure the
//! worker caused (`isWorkerPolicySubmitError`) keeps the budget use.
//!
//! A failing command ring, a command that does not decode or an upload extent the pool rejects
//! removes the worker at once. A well-formed command that breaks a rule counts as invalid
//! instead, and more of those than `sessions.max_invalid_commands_per_window` in one window
//! remove the worker. Every removal the server did not ask for is reported to it
//! (`control.SessionRemoved`), and the server gives the worker a new session no sooner than its
//! reattach interval allows (`server/supervisor/launcher.zig`). A bad token, another session's token and an exhausted budget count; an
//! expired token, an ended boot token and an unknown policy id do not, since an honest fetch can
//! race its token's deadline or its boot's end and only the server mints a policy id. An honest
//! worker presents a bad tag only for its requests in flight across a gateway replacement, whose
//! tokens carry the old key, far fewer than the window allows.

const std = @import("std");
const ipc = @import("collo_ipc");
const os_process = @import("collo_os").process;

const backpressure = @import("../backpressure.zig");
const budgets = @import("../budgets.zig");
const engine_mod = @import("../engine.zig");
const policy_mod = @import("../policy.zig");
const router_mod = @import("../router.zig");
const sessions = @import("../sessions.zig");

const egress_token = ipc.egress_token;

const command_drain_batch: usize = 64;

pub const WorkerRemovalReason = enum {
    liveness_closed,
    command_ring_failed,
    attach_ack_failed,
    forced_drop,
};

/// Every way admission refuses a fetch start. The switches are exhaustive, so a new refusal
/// cannot be added without deciding its message and whether it counts as an invalid command.
const Refusal = enum {
    invalid_token,
    other_session,
    clock_unavailable,
    expired,
    unknown_policy,
    worker_fetch_limit,
    security_cell_fetch_limit,
    duplicate_identity,
    shard_restarting,
    budget_exhausted,
    boot_ended,

    /// The message the worker's fetch fails with.
    fn message(self: Refusal) []const u8 {
        return switch (self) {
            .invalid_token => "invalid egress token",
            .other_session => "egress token of another session",
            .clock_unavailable => "egress clock unavailable",
            .expired => "egress token expired",
            .unknown_policy => "egress policy unknown",
            .worker_fetch_limit => "egress worker fetch limit exceeded",
            .security_cell_fetch_limit => "egress security cell fetch limit exceeded",
            .duplicate_identity => "duplicate egress fetch identity",
            .shard_restarting => "egress shard restarting",
            .budget_exhausted => "egress fetch budget exhausted",
            .boot_ended => "egress boot token ended",
        };
    }

    /// Whether the refusal counts against the worker's invalid-command window; the file header
    /// says why the token refusals split as they do.
    fn isStrike(self: Refusal) bool {
        return switch (self) {
            .invalid_token,
            .other_session,
            .worker_fetch_limit,
            .security_cell_fetch_limit,
            .duplicate_identity,
            .budget_exhausted,
            => true,
            .clock_unavailable,
            .expired,
            .unknown_policy,
            .shard_restarting,
            .boot_ended,
            => false,
        };
    }
};

pub fn Methods(comptime Gateway: type) type {
    return struct {
        /// Drains the body-pool releases of the worker in slot `index`, then up to
        /// `command_drain_batch` of its commands. Returns false when the worker must be removed.
        pub fn handleWorker(self: *Gateway, index: usize) bool {
            const worker = self.workers.byIndex(index) orelse return false;
            ipc.egress_shared.drainEventfd(worker.endpoint.command_eventfd);
            self.drainWorkerPoolReleases(worker);
            defer self.wakeWorkerAfterCommandDrops(worker);
            var drained: usize = 0;
            while (drained < command_drain_batch) : (drained += 1) {
                const packet = worker.endpoint.command.readPacket(self.scratch) catch |err| {
                    std.log.warn("egress gateway command ring read failed session={d}: {s}", .{ worker.session_id, @errorName(err) });
                    return false;
                } orelse return true;
                if (!self.handleWorkerPacket(worker, packet))
                    return false;
            }
            // A full batch may leave commands in the ring; writing the command
            // eventfd brings the next loop pass back for them.
            ipc.egress_shared.notify(worker.endpoint.command_eventfd);
            return true;
        }

        pub fn handleWorkerPacket(self: *Gateway, worker: *sessions.Worker, bytes: []const u8) bool {
            if (bytes.len < @sizeOf(u32))
                return false;
            const kind = ipc.decodeMessageKind(ipc.packet.readStruct(u32, bytes[0..@sizeOf(u32)])) catch return false;
            switch (kind) {
                .egress_fetch_start => {
                    const fetch = ipc.decodeEgressFetchStart(self.decode_scratch, bytes) catch |err| {
                        std.log.warn("invalid egress fetch start: {s}", .{@errorName(err)});
                        return false;
                    };
                    return admitFetchStart(self, worker, fetch);
                },
                .egress_cancel => if (!self.handleCancel(worker, bytes)) return false,
                .egress_release_body => if (!self.handleReleaseBody(worker, bytes)) return false,
                .egress_upload_chunk_batch => if (!self.handleUploadChunkBatch(worker, bytes)) return false,
                else => return false,
            }
            return true;
        }

        /// Admits a decoded fetch start in the order the file header gives, or refuses it with an
        /// error packet to the worker. Returns false when the worker must be removed.
        fn admitFetchStart(
            self: *Gateway,
            worker: *sessions.Worker,
            fetch: ipc.EgressFetchStartView,
        ) bool {
            const token = egress_token.fromBytes(&fetch.egress_token);
            const fields = egress_token.verify(&self.hello.key, &token) catch
                return refuseFetch(self, worker, fetch, .invalid_token);
            if (fields.session_id != worker.session_id)
                return refuseFetch(self, worker, fetch, .other_session);
            // A clock that cannot be read could not tell an expired token from a live one.
            const now_ns = os_process.monotonicNowNs() catch
                return refuseFetch(self, worker, fetch, .clock_unavailable);
            if (egress_token.expired(&token, now_ns))
                return refuseFetch(self, worker, fetch, .expired);
            const network = self.hello.policies.lookup(fields.policy_id) orelse {
                std.log.err("egress token names policy id={d} outside the hello's {d} policies", .{
                    fields.policy_id,
                    self.hello.policies.count,
                });
                return refuseFetch(self, worker, fetch, .unknown_policy);
            };
            const worker_fetches = self.activeFetchesForWorker(worker.session_id);
            if (worker_fetches >= self.policy.max_active_fetches_per_worker_session)
                return refuseFetch(self, worker, fetch, .worker_fetch_limit);
            const cell_fetches = self.activeFetchesForSecurityCell(worker.security_cell_id);
            if (cell_fetches >= self.policy.max_active_fetches_per_security_cell)
                return refuseFetch(self, worker, fetch, .security_cell_fetch_limit);
            if (self.router.containsIdentity(worker.session_id, fetch.fetch_id, fetch.body_id))
                return refuseFetch(self, worker, fetch, .duplicate_identity);
            const isolation = policy_mod.PoolIsolation{
                .security_cell_id = worker.security_cell_id,
                .policy_id = self.hello.isolation_ids[fields.policy_id],
            };
            const shard_index = self.shards.selectIndex(isolation, fetch.url);
            if (self.shards.get(shard_index).quarantined) {
                // The shard is restarting, so the fetch fails instead of
                // queueing. Restarts run synchronously on this loop, so this
                // cannot happen yet; it keeps the rule should teardown ever run
                // asynchronously.
                return refuseFetch(self, worker, fetch, .shard_restarting);
            }
            switch (worker.budgets.take(fields, now_ns)) {
                .taken => {},
                .exhausted => return refuseFetch(self, worker, fetch, .budget_exhausted),
                .boot_ended => return refuseFetch(self, worker, fetch, .boot_ended),
            }

            const route_key = router_mod.RouteKey{
                .worker_session_id = worker.session_id,
                .fetch_id = fetch.fetch_id,
                .body_id = fetch.body_id,
            };
            const options = engine_mod.SubmitOptions{
                .isolation = isolation,
                .network = network.*,
                .request_deadline_mono_ns = fields.deadline_monotonic_ns,
                .budget_key = budgets.BudgetKey.ofToken(fields),
            };
            var admission = FetchAdmission(Gateway){
                .worker = worker,
                .route_key = route_key,
                .shard_index = shard_index,
                .budget_key = options.budget_key,
                .budget_taken_ns = now_ns,
            };
            defer admission.rollback(self);

            self.router.record(self.allocator, route_key, .{
                .shard_index = shard_index,
                .security_cell_id = worker.security_cell_id,
                .policy_id = fields.policy_id,
            }) catch |err| {
                failFetch(self, worker, fetch, @errorName(err));
                return true;
            };
            admission.route_recorded = true;
            self.shards.recordWorkerFetch(
                self.allocator,
                worker.session_id,
                shard_index,
            ) catch |err| {
                failFetch(self, worker, fetch, @errorName(err));
                return true;
            };
            admission.shard_worker_recorded = true;
            self.incrementWorkerFetchCount(worker.session_id) catch |err| {
                failFetch(self, worker, fetch, @errorName(err));
                return true;
            };
            admission.worker_count_incremented = true;
            self.incrementSecurityCellFetchCount(worker.security_cell_id) catch |err| {
                failFetch(self, worker, fetch, @errorName(err));
                return true;
            };
            admission.security_cell_count_incremented = true;

            // A body-pooled fetch waits in the upload assembler until its announced length has
            // arrived as upload-pool extents (`runtime/upload_flow.zig`); any other goes to its
            // engine now. Either way the fetch is committed once the call returns.
            const pooled = (fetch.flags & ipc.egress_fetch_start_flag_body_pooled) != 0;
            const engine = &self.shards.get(shard_index).engine;
            const handed_over = if (pooled)
                self.registerPendingUpload(worker, fetch, shard_index, options)
            else
                engine.submit(worker.session_id, fetch, options);
            handed_over catch |err| {
                if (isWorkerPolicySubmitError(err)) {
                    admission.budget_refund_pending = false;
                    if (!self.recordInvalidWorkerCommand(worker))
                        return false;
                }
                failFetch(self, worker, fetch, @errorName(err));
                return true;
            };
            admission.committed = true;
            return true;
        }

        /// Fails the fetch with the refusal's message, after counting an invalid command when the
        /// refusal is a strike. Returns false when that count removes the worker.
        fn refuseFetch(
            self: *Gateway,
            worker: *sessions.Worker,
            fetch: ipc.EgressFetchStartView,
            refusal: Refusal,
        ) bool {
            if (refusal.isStrike()) {
                if (!self.recordInvalidWorkerCommand(worker))
                    return false;
            }
            failFetch(self, worker, fetch, refusal.message());
            return true;
        }

        /// Queues the error packet that fails the fetch with `text`.
        fn failFetch(
            self: *Gateway,
            worker: *sessions.Worker,
            fetch: ipc.EgressFetchStartView,
            text: []const u8,
        ) void {
            const session = worker.session_id;
            self.queueFetchError(session, fetch.fetch_id, fetch.body_id, text) catch |err| {
                std.log.warn("failed to queue egress fetch error fetch_id={d}: {s}", .{
                    fetch.fetch_id,
                    @errorName(err),
                });
            };
        }

        /// Removes the worker in slot `index`: detaches its fetches in every shard, removes its
        /// routes and active-fetch count, and destroys the session, whose budgets go with it.
        /// Closing the session's end of the liveness pipe the worker watches detaches the worker,
        /// and the server learns of the removal from the report sent here
        /// (`control.SessionRemoved`), except for a session whose attach ack never left, which the
        /// server never knew. Fails, which ends the gateway, when that report can be neither sent
        /// nor queued (`runtime/control_flow.zig`).
        pub fn removeWorker(self: *Gateway, index: usize, reason: WorkerRemovalReason) !void {
            var removed = self.workers.removeAt(index);
            const session_id = removed.session_id;
            std.log.warn("egress gateway removing worker session={d} reason={s}", .{
                session_id,
                @tagName(reason),
            });
            self.shards.detachWorker(session_id);
            self.removeRoutesForWorker(session_id);
            self.limits.removeWorkerFetchCount(session_id);
            removed.deinit(self.allocator);
            switch (reason) {
                .attach_ack_failed => {},
                .liveness_closed,
                .command_ring_failed,
                .forced_drop,
                => try self.reportSessionRemoved(session_id),
            }
        }

        pub fn handleCancel(self: *Gateway, worker: *sessions.Worker, bytes: []const u8) bool {
            const message = ipc.decodeEgressCancel(bytes) catch return false;
            const route = self.router.routeForFetch(worker.session_id, message.fetch_id) orelse return self.recordInvalidWorkerCommand(worker);
            const shard = self.shards.get(route.record.shard_index);
            shard.engine.cancelFetch(worker.session_id, message);
            self.queueAbortAck(worker.session_id, message.fetch_id, route.key.body_id) catch |err|
                std.log.warn("failed to queue egress abort ack fetch_id={d}: {s}", .{ message.fetch_id, @errorName(err) });
            if (!shard.engine.hasActiveFetch(worker.session_id, message.fetch_id))
                self.removeRoute(route.key);
            return true;
        }

        pub fn handleReleaseBody(self: *Gateway, worker: *sessions.Worker, bytes: []const u8) bool {
            const message = ipc.decodeEgressReleaseBody(bytes) catch return false;
            const key = router_mod.RouteKey{
                .worker_session_id = worker.session_id,
                .fetch_id = message.fetch_id,
                .body_id = message.body_id,
            };
            const route = self.router.routeForKey(key) orelse return self.recordInvalidWorkerCommand(worker);
            const shard = self.shards.get(route.record.shard_index);
            shard.engine.releaseBody(worker.session_id, message);
            self.queueAbortAck(worker.session_id, message.fetch_id, message.body_id) catch |err|
                std.log.warn("failed to queue egress release ack fetch_id={d} body_id={d}: {s}", .{ message.fetch_id, message.body_id, @errorName(err) });
            if (!shard.engine.hasActiveBody(worker.session_id, message.fetch_id, message.body_id))
                self.removeRoute(key);
            return true;
        }

        pub fn recordInvalidWorkerCommand(self: *Gateway, worker: *sessions.Worker) bool {
            _ = self;
            return worker.recordInvalidCommandAt(os_process.monotonicNowNsOrZero());
        }

        pub fn queueAbortAck(self: *Gateway, worker_session_id: u64, fetch_id: u64, body_id: u64) !void {
            const message = ipc.EgressAbortAck.init(fetch_id, body_id);
            try self.queuePacket(worker_session_id, std.mem.asBytes(&message));
        }

        pub fn queueFetchError(
            self: *Gateway,
            worker_session_id: u64,
            fetch_id: u64,
            body_id: u64,
            message: []const u8,
        ) !void {
            const bytes = try ipc.encodeEgressFetchErrorInto(self.scratch, .{
                .fetch_id = fetch_id,
                .body_id = body_id,
                .message = message,
                .ready_at_mono_ns = os_process.monotonicNowNsOrZero(),
            });
            try self.queuePacket(worker_session_id, bytes);
        }

        pub fn findWorkerBySession(self: *Gateway, worker_session_id: u64) ?*sessions.Worker {
            return self.workers.bySession(worker_session_id);
        }

        pub fn findWorkerIndexBySession(self: *Gateway, worker_session_id: u64) ?usize {
            return self.workers.indexBySession(worker_session_id);
        }

        pub fn markWorkerForDrop(self: *Gateway, worker_session_id: u64) void {
            self.workers.markForDrop(self.allocator, worker_session_id);
        }

        /// Removes every session marked for drop. Fails as `removeWorker` does.
        pub fn drainPendingWorkerDrops(self: *Gateway) !void {
            while (self.workers.nextDrop()) |worker_session_id| {
                if (self.findWorkerIndexBySession(worker_session_id)) |index|
                    try self.removeWorker(index, .forced_drop);
            }
        }

        pub fn refreshAllWorkerBackpressure(self: *Gateway) void {
            const now_ns = os_process.monotonicNowNsOrZero();
            var index: usize = 0;
            while (index < self.workers.len()) : (index += 1) {
                self.refreshWorkerBackpressure(index, now_ns);
            }
        }

        /// Measures the worker in slot `index` again and wakes its shards when the level changed.
        /// At `hard` it cancels the worker's fetches once per stay and marks the worker for drop
        /// after `backpressure.hard_drop_grace_ns`; a worker whose rings cannot be read is marked
        /// for drop at once.
        pub fn refreshWorkerBackpressure(self: *Gateway, index: usize, now_ns: u64) void {
            const worker = self.workers.byIndex(index) orelse return;
            const previous = worker.backpressure_level;
            const next = self.measureWorkerBackpressure(worker) catch {
                self.markWorkerForDrop(worker.session_id);
                return;
            };

            if (previous != next) {
                worker.backpressure_level = next;
                self.wakeShardsForWorkerPressureChange(worker.session_id);
            }

            switch (next) {
                .hard => {
                    if (worker.hard_pressure_since_ns == 0) {
                        worker.hard_pressure_since_ns = now_ns;
                        worker.hard_pressure_cancel_sent = false;
                    }
                    if (!worker.hard_pressure_cancel_sent) {
                        self.cancelWorkerFetchesForBackpressure(worker.session_id);
                        worker.hard_pressure_cancel_sent = true;
                    }
                    if (now_ns -| worker.hard_pressure_since_ns >= backpressure.hard_drop_grace_ns) {
                        self.markWorkerForDrop(worker.session_id);
                    }
                },
                .normal, .reduced_chunks, .paused => {
                    worker.hard_pressure_since_ns = 0;
                    worker.hard_pressure_cancel_sent = false;
                },
            }
        }

        pub fn measureWorkerBackpressure(self: *Gateway, worker: *sessions.Worker) !backpressure.Level {
            _ = self;
            // Occupancy is read without draining releases, which only
            // `drainWorkerPoolReleases` may do (`runtime/body_release_flow.zig`).
            // The body pool's usage therefore reflects the last drain, which
            // `handleWorker` runs before it reads the worker's commands.
            return backpressure.compute(
                worker.backpressure_level,
                try worker.endpoint.completion.usage(),
                try worker.endpoint.body_pool.usage(),
            );
        }

        pub fn wakeShardsForWorkerPressureChange(self: *Gateway, worker_session_id: u64) void {
            self.shards.wakeForWorkerPressureChange(worker_session_id);
        }

        pub fn cancelWorkerFetchesForBackpressure(self: *Gateway, worker_session_id: u64) void {
            self.shards.cancelWorkerForBackpressure(worker_session_id);
        }

        pub fn removeRoutesForWorker(self: *Gateway, worker_session_id: u64) void {
            self.router.removeWorkerRoutes(
                self.allocator,
                *Gateway,
                self,
                worker_session_id,
                Gateway.retireRoute,
            );
        }

        pub fn removeRoute(self: *Gateway, key: router_mod.RouteKey) void {
            const route = self.router.remove(self.allocator, key) orelse return;
            self.retireRoute(route);
        }

        /// Undoes the admission of a route already taken out of the router: drops the fetch's
        /// assembly state if it has any, and lowers the shard's per-worker count and the active
        /// fetches of the worker and of its security cell. Cancels, failures, a request's end and
        /// worker removal all retire routes through here.
        pub fn retireRoute(self: *Gateway, route: router_mod.Route) void {
            self.retirePendingUpload(route.key.worker_session_id, route.key.fetch_id);
            self.shards.removeWorkerFetch(
                self.allocator,
                route.key.worker_session_id,
                route.record.shard_index,
            );
            self.decrementWorkerFetchCount(route.key.worker_session_id);
            self.decrementSecurityCellFetchCount(route.record.security_cell_id);
        }

        /// After a drain, a higher drop count on the command ring means the worker found the ring
        /// full and parked a command. The ring has room again, so the gateway writes the
        /// completion eventfd the worker waits on; without it, a lone parked fetch start would
        /// wait for an unrelated completion.
        pub fn wakeWorkerAfterCommandDrops(self: *Gateway, worker: *sessions.Worker) void {
            _ = self;
            const drops = @atomicLoad(u64, &worker.endpoint.command.producer.dropped_packets, .acquire);
            if (drops == worker.last_seen_command_drops)
                return;
            worker.last_seen_command_drops = drops;
            ipc.egress_shared.notify(worker.endpoint.completion_eventfd);
        }

        pub fn activeFetchesForWorker(self: *Gateway, worker_session_id: u64) usize {
            return self.limits.activeFetchesForWorker(worker_session_id);
        }

        pub fn incrementWorkerFetchCount(self: *Gateway, worker_session_id: u64) !void {
            try self.limits.incrementWorkerFetchCount(self.allocator, worker_session_id);
        }

        pub fn decrementWorkerFetchCount(self: *Gateway, worker_session_id: u64) void {
            self.limits.decrementWorkerFetchCount(worker_session_id);
        }

        pub fn activeFetchesForSecurityCell(self: *Gateway, security_cell_id: policy_mod.PoolIsolationId) usize {
            return self.limits.activeFetchesForSecurityCell(security_cell_id);
        }

        pub fn incrementSecurityCellFetchCount(self: *Gateway, security_cell_id: policy_mod.PoolIsolationId) !void {
            try self.limits.incrementSecurityCellFetchCount(self.allocator, security_cell_id);
        }

        pub fn decrementSecurityCellFetchCount(self: *Gateway, security_cell_id: policy_mod.PoolIsolationId) void {
            self.limits.decrementSecurityCellFetchCount(security_cell_id);
        }
    };
}

/// What one admission has done since it took a fetch from the token's budget. `rollback` undoes
/// it in reverse order unless the fetch was committed to an engine or to the upload assembler.
fn FetchAdmission(comptime Gateway: type) type {
    return struct {
        /// Stays valid through the admission: nothing on its path attaches or removes a session.
        worker: *sessions.Worker,
        route_key: router_mod.RouteKey,
        shard_index: usize,
        budget_key: budgets.BudgetKey,
        /// The instant admission took the fetch, at which the budget it came from was live.
        budget_taken_ns: u64,
        budget_refund_pending: bool = true,
        route_recorded: bool = false,
        shard_worker_recorded: bool = false,
        worker_count_incremented: bool = false,
        security_cell_count_incremented: bool = false,
        committed: bool = false,

        fn rollback(self: *@This(), gateway: *Gateway) void {
            if (self.committed)
                return;
            if (self.security_cell_count_incremented)
                gateway.decrementSecurityCellFetchCount(self.worker.security_cell_id);
            if (self.worker_count_incremented)
                gateway.decrementWorkerFetchCount(self.route_key.worker_session_id);
            if (self.shard_worker_recorded)
                gateway.shards.removeWorkerFetch(
                    gateway.allocator,
                    self.route_key.worker_session_id,
                    self.shard_index,
                );
            if (self.route_recorded)
                _ = gateway.router.remove(gateway.allocator, self.route_key);
            if (self.budget_refund_pending)
                self.worker.budgets.refund(self.budget_key, self.budget_taken_ns);
        }
    };
}

/// Submission errors the worker caused with what it sent: the fetch it took from its token's
/// budget stays spent and the command counts as invalid.
fn isWorkerPolicySubmitError(err: anyerror) bool {
    return switch (err) {
        error.InvalidEgressGatewayFetchIdentity,
        error.EgressGatewayDuplicateFetchIdentity,
        error.EgressGatewayWorkerFetchLimitExceeded,
        error.TooManyFetchHeaders,
        error.EgressGatewayRequestHeadersTooLarge,
        error.EgressGatewayRequestBodyLimitExceeded,
        error.EgressGatewayResponseBodyLimitExceeded,
        error.InvalidEgressGatewayResponseBodyLimit,
        => true,
        else => false,
    };
}

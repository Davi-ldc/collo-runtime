//! One shard's fetch engine in the egress gateway. It admits fetches against the gateway's
//! limits, runs them on the outbound transport engine (`collo_egress_client`) and publishes each
//! one's head, body and outcome to the worker that asked, as packets through the sinks the
//! gateway installs (`Sinks`, `body_pump.zig`).
//!
//! The engine never reads the token in a start packet. The loop admits each fetch under its
//! verified token and passes what the token grants with the submit (`SubmitOptions`): the request
//! the fetch belongs to and its network policy entry. The transport takes that entry as the
//! fetch's own configuration and checks the host before DNS and the address class after it, on
//! every hop, redirects included.
//!
//! The gateway's main loop thread owns the `Engine`: its active table, the drain of its ready
//! scan, its sinks and counters. Of what this file owns, the inner engine's owner and connector
//! threads touch only tasks, fetch bodies and `wake`, which queues a ready task and writes
//! `wake_fd`.
//!
//! An error confined to one fetch's publication path fails only that fetch
//! (`isFetchDemotableError`); any other error leaves the collection pass, and the shard
//! supervisor (`runtime/shard_flow.zig`) restarts the engine on the threads and rings it booted
//! with, since the gateway's seccomp filter forbids creating new ones.

const std = @import("std");
const builtin = @import("builtin");
const bindings = @import("collo_bindings");
const ipc = @import("collo_ipc");
const egress = @import("collo_egress_client");

const active_fetch = @import("active_fetch.zig");
const active_table = @import("active_table.zig");
const body_pump = @import("body_pump.zig");
const budgets = @import("budgets.zig");
const body_credit = egress.body_credit;
const fetch_body = egress.fetch_body;
const policy_mod = @import("policy.zig");
const ready_scan = @import("ready_scan.zig");
const task_model = egress.task;
const transport = egress.transport;

pub const Config = struct {
    queue_capacity: usize = 1024,
    /// Connector threads of the inner engine, which run every DNS, TCP and TLS dial for both
    /// protocols (`ThreadConfig.connector_count` in `egress/client/engine/root.zig` gives the
    /// default's reason). HTTP/1 dials have no per-origin coalescing like HTTP/2's connect
    /// groups (`h2_types.zig`), so concurrent HTTP/1 fetches that dial one origin each take a
    /// connector. The owner thread runs beside them, so a shard has this many engine threads
    /// plus one (`sizing.EngineThreadCounts`). Zero keeps the engine constructible but never
    /// available, which tests use to exercise the IPC boundary without threads.
    h2_connector_count: usize = 2,
    policy: policy_mod.Policy = .{},
    /// Capacity of the ready-event queue; zero means twice `queue_capacity`.
    ready_event_capacity: usize = 0,
};

/// Target of the collection fault hook in test builds (`Engine.test_collect_fault`).
pub const TestCollectFault = struct {
    worker_session_id: u64,
    fetch_id: u64,
    err: anyerror,
};

pub const PacketSender = *const fn (?*anyopaque, u64, []const u8) anyerror!void;
pub const BodyChunkPayload = active_fetch.BodyChunkPayload;
/// Publishes one body chunk batch and returns the number of pool extents
/// written (the worker session's slot ledger gained that many entries); the
/// fetch counts them as outstanding until the release observer drains them.
pub const BodyChunkBatchSender = *const fn (
    ?*anyopaque,
    u64,
    u64,
    u64,
    []const BodyChunkPayload,
    []u8,
) anyerror!usize;
pub const WorkerPressureProbe = *const fn (?*anyopaque, u64) policy_mod.WorkerPressure;
pub const WorkerFaultReporter = *const fn (?*anyopaque, u64, []const u8) void;
/// The gateway's callbacks, installed before `start` and called with `ctx` on the main loop
/// thread.
pub const Sinks = struct {
    ctx: ?*anyopaque = null,
    packet_sender: ?PacketSender = null,
    body_chunk_batch_sender: ?BodyChunkBatchSender = null,
    worker_pressure_probe: ?WorkerPressureProbe = null,
    worker_fault_reporter: ?WorkerFaultReporter = null,
};
// One collection pass takes at most `ready_event_collect_max` ready events and
// `ready_worker_scan_collect_max` worker scans, in batches of `ready_event_batch_max` and
// `ready_worker_scan_batch_max`. Whatever remains signals `wake_fd` again for the next pass,
// so one busy shard cannot hold the main loop.
const ready_event_batch_max: usize = 256;
const ready_event_collect_max: usize = 1024;
const ready_worker_scan_batch_max: usize = 256;
const ready_worker_scan_collect_max: usize = 1024;

pub const WorkerFetchKey = active_table.WorkerFetchKey;
pub const WorkerBodyKey = active_table.WorkerBodyKey;

/// One replay-safe fetch that `partitionActivesForTeardown` extracted from a
/// stopped engine, pending redispatch onto the same engine once it restarts.
pub const ReplayFetch = struct {
    worker_session_id: u64,
    /// The request the fetch belongs to, which the redispatched attempt keeps, so the request's
    /// `request_ended` still cancels it.
    budget_key: budgets.BudgetKey,
    fetch_id: u64,
    body_id: u64,
    /// Original absolute deadline from admission (0 = none); the redispatched
    /// attempt keeps it, so a restart never extends a request's budget.
    request_deadline_mono_ns: u64,
    /// The dead attempt's `cost` meter. The redispatched task adds it as cost
    /// only (`SubmitOptions.egress_cost_base`): the worker received nothing
    /// from that attempt, so its `billed_sent` and `billed_received` stay zero.
    dead_attempt_cost: u64,
    /// The request's task, with a reference the partition took. Its URL,
    /// method, headers and body copies stay valid through the active table's
    /// teardown because the shard's counting allocator survives the restart.
    /// Whoever consumes the item releases it exactly once.
    task: *task_model.Task,
};

/// What admission granted a fetch. `isolation`, `network` and `budget_key` have no default,
/// since each decides what the fetch may reach or whose request it serves.
pub const SubmitOptions = struct {
    /// The pool key: the fetch's security cell and the isolation id of its policy entry
    /// (`policy.networkPolicyIsolationId`).
    isolation: policy_mod.PoolIsolation,
    /// The policy table entry the fetch's token names, checked on every hop.
    network: policy_mod.NetworkPolicy,
    /// The request the fetch's token names. `cancelRequest` cancels the fetch by it, and the
    /// response body carries its request id and generation. Its session is the submitting
    /// worker's.
    budget_key: budgets.BudgetKey,
    request_deadline_mono_ns: u64 = 0,
    /// An assembled pooled-upload request body with the allocator that
    /// allocated it, the gateway's own (`runtime/upload_flow.zig`). Ownership
    /// transfers to the engine on the call: the task takes it without
    /// copying on success, and submit frees it on error, both with that
    /// allocator, so the shard's counting allocator never frees bytes it did
    /// not count. `fetch.body` must be empty when set.
    owned_body: ?task_model.OwnedBody = null,
    /// Cost of earlier attempts, added to the task before submission
    /// (`Task.addEgressBase`). A redispatched fetch passes its dead attempt's
    /// cost and nothing for `billed_sent` or `billed_received`, since the
    /// worker received nothing from that attempt; the transport treats a retried HTTP/2
    /// attempt the same way.
    egress_cost_base: u64 = 0,
};

pub const Engine = struct {
    allocator: std.mem.Allocator,
    inner: egress.Engine,
    wake_fd: std.posix.fd_t,
    scratch: []u8,
    policy: policy_mod.Policy,
    active: active_table.Table = .{},
    ready: ready_scan.Scan,
    sinks: Sinks = .{},
    body_credit_release_failed_total: u64 = 0,
    body_credit_leaked_bytes: u64 = 0,
    worker_session_force_detach_total: u64 = 0,
    /// Fetches `demoteFetch` failed one at a time after an error confined to
    /// them, instead of failing the shard. It survives restarts and wraps.
    demoted_fetch_errors_total: u64 = 0,
    /// Collection fault hook for test builds; in other builds it is `void`
    /// and every check on it is comptime-dead. Once armed through
    /// `armCollectFault` in `egress/tests/gateway/support/engine.zig`,
    /// the next collection pass returns the chosen error when it reaches the
    /// named fetch, before pumping it, and the hook disarms. It models a
    /// shard-fatal fault outside the per-fetch whitelist that surfaces
    /// mid-collection after earlier fetches of the same pass completed, the
    /// interleaving that the shard supervisor and the route-removal defer in
    /// `shard_flow.collectShardReady` must contain.
    test_collect_fault: if (builtin.is_test) ?TestCollectFault else void =
        if (builtin.is_test) null else {},

    pub fn init(allocator: std.mem.Allocator, config: Config) !Engine {
        try policy_mod.validate(config.policy);
        const wake_fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
        errdefer std.posix.close(wake_fd);
        var inner = try egress.Engine.init(allocator, config.queue_capacity, .{
            .connector_count = config.h2_connector_count,
        });
        errdefer inner.deinit();
        inner.setPreRegisterRecvBuffers(true);
        const scratch = try allocator.alloc(u8, ipc.max_message_bytes);
        errdefer allocator.free(scratch);
        var ready = try ready_scan.Scan.init(allocator, resolveReadyEventCapacity(config));
        errdefer ready.deinit(allocator);
        return .{
            .allocator = allocator,
            .inner = inner,
            .wake_fd = wake_fd,
            .scratch = scratch,
            .policy = config.policy,
            .ready = ready,
        };
    }

    pub fn deinit(self: *Engine) void {
        self.stop();
        self.active.deinit(self.allocator, self);
        self.inner.deinit();
        self.ready.deinit(self.allocator);
        self.allocator.free(self.scratch);
        std.posix.close(self.wake_fd);
        self.* = undefined;
    }

    pub fn setPacketSender(self: *Engine, ctx: ?*anyopaque, sender: PacketSender) void {
        self.sinks.ctx = ctx;
        self.sinks.packet_sender = sender;
    }

    pub fn setBodyChunkBatchSender(self: *Engine, sender: BodyChunkBatchSender) void {
        self.sinks.body_chunk_batch_sender = sender;
    }

    pub fn setWorkerPressureProbe(self: *Engine, probe: WorkerPressureProbe) void {
        self.sinks.worker_pressure_probe = probe;
    }

    pub fn setWorkerFaultReporter(self: *Engine, reporter: WorkerFaultReporter) void {
        self.sinks.worker_fault_reporter = reporter;
    }

    /// Begins a run of the inner engine. Only the first call creates threads
    /// and rings (see `egress.Engine.start`), so a restart under the
    /// gateway's seccomp filter creates neither.
    pub fn start(self: *Engine) !void {
        try self.inner.start(self, wake);
    }

    pub fn stop(self: *Engine) void {
        self.inner.stop();
    }

    /// Empties a stopped engine for its next run: tears down the active
    /// table, whose fetches the caller has already partitioned
    /// (`partitionActivesForTeardown`), and drops the ready queue and any
    /// pending wake. Sinks, counters and the inner engine's threads stay.
    pub fn clearForRestart(self: *Engine) void {
        std.debug.assert(!self.inner.started);
        self.active.deinit(self.allocator, self);
        self.active = .{};
        self.ready.clear();
        drainWakeFd(self.wake_fd);
    }

    /// Admits a fetch of `worker_session_id` under what `options` grants and submits it to the
    /// inner engine; the engine owns `options.owned_body` from the call on. Fails, leaving
    /// nothing behind, when the fetch's identity is zero or already active, the session is at
    /// `Policy.max_active_fetches_per_worker_session`, the request exceeds the limits (headers,
    /// request body, or a response limit above the limits'), an allocation fails, or the inner
    /// engine refuses the task.
    pub fn submit(
        self: *Engine,
        worker_session_id: u64,
        fetch: ipc.EgressFetchStartView,
        options: SubmitOptions,
    ) !void {
        // From here the engine owns `options.owned_body`: every error path
        // frees it until the task takes it without copying.
        var owned_body_transferred = false;
        errdefer if (options.owned_body) |owned| {
            if (!owned_body_transferred)
                owned.allocator.free(owned.bytes);
        };
        std.debug.assert(options.owned_body == null or fetch.body.len == 0);
        std.debug.assert(options.budget_key.session_id == worker_session_id);
        const body_len = if (options.owned_body) |owned| owned.bytes.len else fetch.body.len;
        var header_storage: [ipc.max_request_header_count]bindings.NameValuePair = undefined;
        if (fetch.fetch_id == 0 or fetch.body_id == 0)
            return error.InvalidEgressGatewayFetchIdentity;
        if (self.active.hasWorkerIdentity(worker_session_id, fetch.fetch_id, fetch.body_id))
            return error.EgressGatewayDuplicateFetchIdentity;
        if (self.active.countForWorkerSession(worker_session_id) >= self.policy.max_active_fetches_per_worker_session)
            return error.EgressGatewayWorkerFetchLimitExceeded;
        if (fetch.headers.len > @min(header_storage.len, self.policy.max_request_headers))
            return error.TooManyFetchHeaders;
        if (requestHeaderBytes(fetch.headers) > self.policy.max_request_header_bytes)
            return error.EgressGatewayRequestHeadersTooLarge;
        if (body_len > self.policy.max_request_body_bytes)
            return error.EgressGatewayRequestBodyLimitExceeded;
        for (fetch.headers, 0..) |header, index| {
            header_storage[index] = .{
                .name = rawString(header.name),
                .value = rawString(header.value),
            };
        }

        const identity = bindings.FetchBodyIdentity{
            .request_id = options.budget_key.request_id,
            .request_generation = options.budget_key.request_generation,
            .fetch_id = fetch.fetch_id,
            .body_id = fetch.body_id,
        };
        const max_body_bytes = try policy_mod.resolveMaxResponseBodyBytes(
            fetch.max_body_bytes,
            self.policy.max_response_body_bytes,
        );

        const body = try self.allocator.create(fetch_body.Body);
        var body_owned = true;
        var body_initialized = false;
        errdefer {
            if (body_owned and body_initialized)
                body.deinitAfterQueuedResourcesReleased(self.allocator);
            if (body_owned)
                self.allocator.destroy(body);
        }
        body.* = fetch_body.Body.initOpen(self.allocator, identity, @as(u64, @intCast(max_body_bytes)));
        body_initialized = true;

        const task = try self.allocator.create(task_model.Task);
        var task_owned = true;
        var task_initialized = false;
        errdefer if (task_owned) {
            if (task_initialized)
                task.release()
            else
                self.allocator.destroy(task);
        };
        task.* = if (options.owned_body) |owned|
            try task_model.Task.initOwnedBody(
                self.allocator,
                fetch.fetch_id,
                identity.request_id,
                fetch.url,
                fetch.method,
                owned,
                header_storage[0..fetch.headers.len],
                fetch.flags,
                identity,
                body,
            )
        else
            try task_model.Task.init(
                self.allocator,
                fetch.fetch_id,
                identity.request_id,
                fetch.url,
                fetch.method,
                fetch.body,
                header_storage[0..fetch.headers.len],
                fetch.flags,
                identity,
                body,
            );
        // The task owns the assembled buffer now; its cleanup paths free it.
        owned_body_transferred = true;
        task_initialized = true;
        body_owned = false;
        if (options.egress_cost_base != 0)
            task.addEgressBase(0, 0, options.egress_cost_base);

        const network = transportEgressPolicy(options.network);
        const config = transport.Config{
            .allow_plain_http = network.allow_plain_http,
            .allow_private_networks = network.allow_private_networks,
            .max_response_body_bytes = max_body_bytes,
            .max_encoded_response_bytes = @min(self.policy.max_encoded_response_bytes, max_body_bytes),
            .socket_timeout_ms = self.policy.socket_timeout_ms,
            .request_deadline_mono_ns = options.request_deadline_mono_ns,
            .enable_http2 = self.policy.enable_http2,
            .max_redirects = self.policy.max_redirects,
            .max_redirect_drain_bytes = self.policy.max_redirect_drain_bytes,
            .pool_security_cell_id = options.isolation.security_cell_id,
            .pool_policy_id = options.isolation.policy_id,
        };
        std.debug.assert(!config.insecure_tls);

        const active_index = try self.active.append(self.allocator, .{
            .worker_session_id = worker_session_id,
            .budget_key = options.budget_key,
            .worker_attached = true,
            .task = task,
            .body = body,
            .fetch_id = fetch.fetch_id,
            .body_id = fetch.body_id,
            .request_deadline_mono_ns = options.request_deadline_mono_ns,
        }, self.ready.nextGeneration());
        task_owned = false;
        var active_owned = true;
        errdefer if (active_owned) {
            var removed = self.active.removeAt(self.allocator, active_index);
            removed.deinit(self);
        };

        try self.inner.submit(.{
            .task = task,
            .config = config,
        }, self, wake);

        active_owned = false;
    }

    pub fn collectReady(self: *Engine) !void {
        var completed: std.array_list.Aligned(active_fetch.WorkerScopedFetch, null) = .empty;
        defer completed.deinit(self.allocator);
        try self.collectReadyCompleted(&completed);
    }

    /// `collectReadyCompletedInto` with the engine's own allocator, so `completed` must belong to
    /// it: the list in `collectReady`, or a test's list when both use the testing allocator. The
    /// gateway passes its own allocator instead (see `collectReadyCompletedInto`).
    pub fn collectReadyCompleted(
        self: *Engine,
        completed: *std.array_list.Aligned(active_fetch.WorkerScopedFetch, null),
    ) !void {
        return self.collectReadyCompletedInto(self.allocator, completed);
    }

    /// Publishes what the ready fetches produced and appends the identity of every fetch the
    /// pass retired to `completed`. `list_gpa` must be the allocator that owns `completed`, never
    /// the shard's counting allocator: the owner frees the list without going through the
    /// counting allocator, so its capacity would stay charged to the shard's memory budget, and
    /// a reused list would carry one shard's allocator into another's pass. An error is
    /// shard-scoped and may follow fetches the pass already published and retired; `completed`
    /// still holds those, and the caller removes their routes before it supervises the shard
    /// (`collectShardReady` and `superviseShardFailure` in `runtime/shard_flow.zig`).
    pub fn collectReadyCompletedInto(
        self: *Engine,
        list_gpa: std.mem.Allocator,
        completed: *std.array_list.Aligned(active_fetch.WorkerScopedFetch, null),
    ) !void {
        drainWakeFd(self.wake_fd);

        var scan_required = false;
        var ready_batch: [ready_event_batch_max]ready_scan.Event = undefined;
        var processed: usize = 0;
        var has_more = false;
        while (processed < ready_event_collect_max) {
            const drain = self.ready.drain(&ready_batch);
            scan_required = scan_required or drain.scan_required;
            has_more = drain.has_more;
            for (ready_batch[0..drain.len]) |event| {
                try self.processReadyEvent(event, list_gpa, completed);
            }
            processed += drain.len;
            if (drain.len < ready_batch.len)
                break;
        }

        var worker_scan_batch: [ready_worker_scan_batch_max]u64 = undefined;
        var worker_scan_processed: usize = 0;
        var worker_scan_has_more = false;
        while (worker_scan_processed < ready_worker_scan_collect_max) {
            const drain = self.ready.drainWorkerScans(&worker_scan_batch);
            worker_scan_has_more = drain.has_more;
            for (worker_scan_batch[0..drain.len]) |worker_session_id| {
                try self.processWorkerActive(worker_session_id, list_gpa, completed);
            }
            worker_scan_processed += drain.len;
            if (drain.len < worker_scan_batch.len)
                break;
        }

        if (has_more or worker_scan_has_more)
            signalWakeFd(self.wake_fd);
        if (scan_required)
            try self.processAllActive(list_gpa, completed);

        // A fatal error that escaped the inner engine's owner loop, such as
        // an allocation that failed at the shard's memory budget while it
        // rebuilt its watch list, is returned only after the pass published
        // whatever had already settled. The run loop then restarts this
        // shard's engine rather than keep routing fetches to a dead owner
        // thread.
        if (self.inner.takeOwnerFault()) |err|
            return err;
    }

    fn processWorkerActive(
        self: *Engine,
        worker_session_id: u64,
        list_gpa: std.mem.Allocator,
        completed: *std.array_list.Aligned(active_fetch.WorkerScopedFetch, null),
    ) !void {
        var cursor: usize = 0;
        while (true) {
            const fetches = self.active.scopedForWorkerSession(worker_session_id) orelse return;
            if (cursor >= fetches.len)
                return;
            const scoped = fetches[cursor];
            const index = self.active.findIndex(
                scoped.worker_session_id,
                scoped.fetch_id,
                scoped.body_id,
            ) orelse {
                cursor += 1;
                continue;
            };
            if (try self.processActiveAt(index, list_gpa, completed))
                continue;
            cursor += 1;
        }
    }

    fn processAllActive(
        self: *Engine,
        list_gpa: std.mem.Allocator,
        completed: *std.array_list.Aligned(active_fetch.WorkerScopedFetch, null),
    ) !void {
        var index: usize = 0;
        while (index < self.active.len()) {
            if (try self.processActiveAt(index, list_gpa, completed))
                continue;
            index += 1;
        }
    }

    fn processReadyEvent(
        self: *Engine,
        event: ready_scan.Event,
        list_gpa: std.mem.Allocator,
        completed: *std.array_list.Aligned(active_fetch.WorkerScopedFetch, null),
    ) !void {
        if (event.generation == 0)
            return;
        const index = self.active.indexByTask(event.task) orelse return;
        const fetch = self.active.get(index);
        if (fetch.task != event.task)
            return;
        if (fetch.task.ready_generation.load(.monotonic) != event.generation)
            return;
        _ = try self.processActiveAt(index, list_gpa, completed);
    }

    fn processActiveAt(
        self: *Engine,
        index: usize,
        list_gpa: std.mem.Allocator,
        completed: *std.array_list.Aligned(active_fetch.WorkerScopedFetch, null),
    ) !bool {
        const fetch = self.active.get(index);
        if (builtin.is_test) {
            if (self.test_collect_fault) |fault| {
                if (fault.worker_session_id == fetch.worker_session_id and
                    fault.fetch_id == fetch.fetch_id)
                {
                    self.test_collect_fault = null;
                    return fault.err;
                }
            }
        }
        // An error confined to this fetch's publication path fails only this
        // fetch; any other error returns to the caller, which restarts the
        // shard.
        self.pumpFetch(fetch) catch |err| {
            if (!isFetchDemotableError(err))
                return err;
            try self.demoteFetch(fetch, err);
        };

        if (!fetch.canRetire())
            return false;
        // `completed` grows with `list_gpa`, the caller's allocator, never the
        // shard's (see `collectReadyCompletedInto`).
        try completed.append(list_gpa, fetch.scopedFetch());
        var removed = self.active.removeAt(self.allocator, index);
        removed.deinit(self);
        return true;
    }

    fn pumpFetch(self: *Engine, fetch: *active_fetch.Fetch) !void {
        try body_pump.publishHeadIfReady(self, fetch);
        if (fetch.head_sent)
            try body_pump.drainBody(self, fetch);
    }

    /// Fails one fetch after an error confined to its publication path. Unless the fetch is
    /// already terminal, the worker gets an error packet with the fetch's meters, so
    /// `billed_sent` and `billed_received` still count what the origin delivered, as on the
    /// canceled path of `body_pump.publishHeadIfReady`. The stream is then canceled, which
    /// resets it and returns its held credit to the HTTP/2 connection window
    /// (`Connection.cancelStream`), and the normal retire path reaps the fetch once its task
    /// settles. When the error packet itself fails, nothing shows the damage is confined to this
    /// fetch any longer, so `cause` is returned and the caller escalates.
    fn demoteFetch(self: *Engine, fetch: *active_fetch.Fetch, cause: anyerror) !void {
        if (!fetch.terminal) {
            fetch.sendError(self, "egress internal error", fetch.egressMeters()) catch |send_err| {
                std.log.warn(
                    "egress gateway fetch demotion double-faulted session={d} fetch_id={d}: cause={s} send={s}",
                    .{ fetch.worker_session_id, fetch.fetch_id, @errorName(cause), @errorName(send_err) },
                );
                return cause;
            };
        }
        fetch.detachAndCancel(self, "egress internal error");
        self.inner.wakeCancellation();
        self.demoted_fetch_errors_total +%= 1;
        std.log.warn(
            "egress gateway demoted fetch session={d} fetch_id={d} body_id={d}: {s}",
            .{ fetch.worker_session_id, fetch.fetch_id, fetch.body_id, @errorName(cause) },
        );
    }

    /// Sorts every active fetch of a stopped engine before its restart. A fetch that is safe to
    /// replay (`isReplaySafeForRedispatch`) goes to `replay_out` with a retained task and what
    /// resubmitting it needs. Every other fetch goes to `retired_out` for route removal and is
    /// failed with `demoteFetch`, unless the worker already has its outcome, in which case it is
    /// only detached for the table's teardown to reap. Call it only after `stop`: the partition
    /// reads task state (`done`, `redirect_count`, the request fields) that engine threads write
    /// while the engine runs.
    ///
    /// Both lists grow with `gpa`, the caller's allocator, never the shard's, because they
    /// outlive the active table. An error here is a second fault during containment, and the
    /// caller ends the gateway process.
    pub fn partitionActivesForTeardown(
        self: *Engine,
        gpa: std.mem.Allocator,
        replay_out: *std.array_list.Aligned(ReplayFetch, null),
        retired_out: *std.array_list.Aligned(active_fetch.WorkerScopedFetch, null),
        cause: anyerror,
    ) !void {
        var index: usize = 0;
        while (index < self.active.len()) : (index += 1) {
            const fetch = self.active.get(index);
            if (isReplaySafeForRedispatch(fetch)) {
                // Only the dead attempt's `cost` carries over to the
                // redispatched task, as for a retried HTTP/2 attempt. Its
                // `billed_sent` and `billed_received` are dropped, since the
                // worker received nothing, and are not added to cost either:
                // `meters.cost` counts the TLS ciphertext that already carried
                // those bytes, so adding them would count them twice.
                const meters = fetch.egressMeters();
                try replay_out.append(gpa, .{
                    .worker_session_id = fetch.worker_session_id,
                    .budget_key = fetch.budget_key,
                    .fetch_id = fetch.fetch_id,
                    .body_id = fetch.body_id,
                    .request_deadline_mono_ns = fetch.request_deadline_mono_ns,
                    .dead_attempt_cost = meters.cost,
                    .task = fetch.task,
                });
                // Retain only after the append committed: an append failure
                // must not strand a reference nobody will release.
                fetch.task.retain();
                continue;
            }
            try retired_out.append(gpa, fetch.scopedFetch());
            if (fetch.terminal)
                continue; // Worker already saw a terminal packet (or canceled).
            if (fetch.body_end_sent) {
                // The worker received the complete body; only extent returns
                // are pending, and those tolerate a retired route. An error
                // packet here would contradict a stream the worker already
                // finished, so detach silently.
                fetch.detachAndCancel(self, "egress shard restarted");
                continue;
            }
            try self.demoteFetch(fetch, cause);
        }
    }

    /// Submits a fetch that `partitionActivesForTeardown` extracted to this engine after its
    /// restart, with the same worker identity and request, the original deadline and the dead
    /// attempt's cost. `isolation` and `network` must be what the fetch was admitted under, which
    /// the caller keeps in the fetch's route. It only reads `item.task`; the caller releases it
    /// whether this succeeds or fails, so the item has one owner throughout. Fails like `submit`.
    pub fn resubmitReplayFetch(
        self: *Engine,
        item: ReplayFetch,
        isolation: policy_mod.PoolIsolation,
        network: policy_mod.NetworkPolicy,
    ) !void {
        var header_storage: [ipc.max_request_header_count]ipc.RequestHeader = undefined;
        const task = item.task;
        std.debug.assert(task.request_id == item.budget_key.request_id);
        std.debug.assert(task.response_body_identity.request_generation == item.budget_key.request_generation);
        if (task.headers.len > header_storage.len)
            return error.TooManyFetchHeaders;
        for (task.headers, 0..) |header, index| {
            header_storage[index] = .{
                .name = header.name,
                .value = header.value,
            };
        }
        try self.submit(item.worker_session_id, .{
            .fetch_id = item.fetch_id,
            // `submit` never reads the token: `options` carries what admission granted.
            .egress_token = ipc.egress_token.none,
            .body_id = item.body_id,
            .flags = task.flags,
            // The old body carries the resolved limit, and resubmitting it
            // resolves to the same value: an explicit limit at or below the
            // policy's passes through unchanged.
            .max_body_bytes = task.response_body.maxDecodedBytes() orelse 0,
            .method = task.method,
            .url = task.url,
            .headers = header_storage[0..task.headers.len],
            .body = task.body,
        }, .{
            .isolation = isolation,
            .network = network,
            .budget_key = item.budget_key,
            .request_deadline_mono_ns = item.request_deadline_mono_ns,
            .egress_cost_base = item.dead_attempt_cost,
        });
    }

    /// A worker returned a body-pool extent: releases its flow-control credit,
    /// which refills the HTTP/2 window, and retires the fetch once body end
    /// went out and nothing remains outstanding. A retired fetch or a finished
    /// stream is fine, since the pool's generation-checked handles already
    /// authenticated the release.
    pub fn releaseExtentCredit(
        self: *Engine,
        worker_session_id: u64,
        fetch_id: u64,
        body_id: u64,
        credit: body_credit.Handle,
    ) void {
        self.releaseExtentCreditOnly(fetch_id, credit);
        self.noteExtentReleasedAndMaybeRetire(worker_session_id, fetch_id, body_id);
    }

    /// The credit half of an extent release. The release observer
    /// (`runtime/body_release_flow.zig`) merges consecutive extents of one
    /// stream whose `update_stream_window` flags match, the rule of
    /// `active_fetch.CreditBatch.add`, and delivers one ack here with their
    /// `encoded_bytes` summed, so the engine's owner thread wakes once per run
    /// instead of once per extent. The ack can arrive after the per-extent
    /// bookkeeping of `noteExtentReleasedAndMaybeRetire`, which is safe: the
    /// engine treats an ack for a finished or reset stream as a no-op, and the
    /// retire path does not depend on the ack.
    pub fn releaseExtentCreditOnly(self: *Engine, fetch_id: u64, credit: body_credit.Handle) void {
        self.inner.tryReleaseFetchBodyCredit(credit) catch |err| {
            self.body_credit_release_failed_total +|= 1;
            std.log.warn("egress extent credit release failed fetch_id={d}: {s}", .{ fetch_id, @errorName(err) });
        };
    }

    /// Bookkeeping half of an extent release; runs once per extent even when
    /// the credit ack was aggregated.
    pub fn noteExtentReleasedAndMaybeRetire(
        self: *Engine,
        worker_session_id: u64,
        fetch_id: u64,
        body_id: u64,
    ) void {
        const index = self.active.findIndex(worker_session_id, fetch_id, body_id) orelse return;
        const fetch = self.active.get(index);
        fetch.noteExtentReleased();
        if (fetch.body_end_sent and fetch.outstanding_extents == 0) {
            // The last extent came home after body end: the worker holds
            // nothing of this fetch anymore, so the release itself is the
            // retire signal (drainBody never re-runs a finished body).
            fetch.terminal = true;
            if (fetch.canRetire()) {
                var removed = self.active.removeAt(self.allocator, index);
                removed.deinit(self);
            }
        }
    }

    pub fn cancelFetch(self: *Engine, worker_session_id: u64, cancel: ipc.EgressCancel) void {
        const index = self.active.indexByFetch(worker_session_id, cancel.fetch_id) orelse return;
        const fetch = self.active.get(index);
        fetch.detachAndCancel(self, "fetch aborted");
        self.inner.wakeCancellation();
    }

    pub fn releaseBody(self: *Engine, worker_session_id: u64, release: ipc.EgressReleaseBody) void {
        const fetch = self.active.find(worker_session_id, release.fetch_id, release.body_id) orelse return;
        fetch.detachAndCancel(self, "fetch body released");
        self.inner.wakeCancellation();
    }

    pub fn detachWorker(self: *Engine, worker_session_id: u64) void {
        var canceled = false;
        const fetches = self.active.scopedForWorkerSession(worker_session_id) orelse return;
        for (fetches) |scoped| {
            const fetch = self.active.find(scoped.worker_session_id, scoped.fetch_id, scoped.body_id) orelse continue;
            fetch.detachAndCancel(self, "worker disconnected");
            canceled = true;
        }
        if (canceled)
            self.inner.wakeCancellation();
    }

    /// Cancels every fetch of the request `key` names, which the server reported ended: the
    /// worker gets no further packet for any of them. A key with no fetch here is a no-op.
    pub fn cancelRequest(self: *Engine, key: budgets.BudgetKey) void {
        var canceled = false;
        const fetches = self.active.scopedForRequest(key) orelse return;
        for (fetches) |scoped| {
            const fetch = self.active.find(scoped.worker_session_id, scoped.fetch_id, scoped.body_id) orelse continue;
            fetch.detachAndCancel(self, "request completed");
            canceled = true;
        }
        if (canceled)
            self.inner.wakeCancellation();
    }

    pub fn cancelWorkerForBackpressure(self: *Engine, worker_session_id: u64) void {
        var canceled = false;
        const fetches = self.active.scopedForWorkerSession(worker_session_id) orelse return;
        for (fetches) |scoped| {
            const fetch = self.active.find(scoped.worker_session_id, scoped.fetch_id, scoped.body_id) orelse continue;
            fetch.detachAndCancel(self, "egress worker backpressure");
            canceled = true;
        }
        if (canceled)
            self.inner.wakeCancellation();
        if (canceled)
            wake(self, .generic);
    }

    pub fn wakeForWorkerPressureChange(self: *Engine, worker_session_id: u64) void {
        if (self.active.countForWorkerSession(worker_session_id) == 0)
            return;
        if (!self.ready.enqueueWorkerScan(worker_session_id))
            return;
        signalWakeFd(self.wake_fd);
    }

    pub fn hasActiveBody(self: *const Engine, worker_session_id: u64, fetch_id: u64, body_id: u64) bool {
        return self.active.hasBody(worker_session_id, fetch_id, body_id);
    }

    pub fn hasActiveFetch(self: *const Engine, worker_session_id: u64, fetch_id: u64) bool {
        return self.active.hasFetch(worker_session_id, fetch_id);
    }

    pub fn workerPressure(self: *Engine, worker_session_id: u64) policy_mod.WorkerPressure {
        const probe = self.sinks.worker_pressure_probe orelse return .{};
        return probe(self.sinks.ctx, worker_session_id);
    }

    pub fn releaseCredit(self: *Engine, credit: body_credit.Handle) !void {
        try self.inner.tryReleaseFetchBodyCredit(credit);
    }

    pub fn reportWorkerCreditReleaseFailure(
        self: *Engine,
        worker_session_id: u64,
        credit: body_credit.Handle,
        err: anyerror,
    ) void {
        self.body_credit_release_failed_total +|= 1;
        self.body_credit_leaked_bytes +|= creditBytes(credit);
        self.worker_session_force_detach_total +|= 1;
        self.detachWorker(worker_session_id);
        if (self.sinks.worker_fault_reporter) |reporter| {
            reporter(self.sinks.ctx, worker_session_id, "body credit release failed");
        }
        std.log.warn(
            "egress gateway forcing worker detach after body credit release failure worker_session_id={d}: {s}",
            .{ worker_session_id, @errorName(err) },
        );
    }

    pub fn sendPacket(self: *Engine, worker_session_id: u64, bytes: []const u8) !void {
        const sender = self.sinks.packet_sender orelse return error.EgressGatewayPacketSenderUnavailable;
        try sender(self.sinks.ctx, worker_session_id, bytes);
    }

    pub fn sendBodyChunkBatch(
        self: *Engine,
        worker_session_id: u64,
        fetch_id: u64,
        body_id: u64,
        chunks: []const BodyChunkPayload,
    ) !usize {
        const sender = self.sinks.body_chunk_batch_sender orelse
            return error.EgressGatewayPacketSenderUnavailable;
        return try sender(
            self.sinks.ctx,
            worker_session_id,
            fetch_id,
            body_id,
            chunks,
            self.scratch,
        );
    }
};

/// Errors proven confined to one fetch's publication path, which `processActiveAt` turns into
/// that fetch's failure (`Engine.demoteFetch`) instead of the shard's. Each entry must leave no
/// engine, pool or session state half changed when it surfaces:
///
/// - `OutOfMemory` from the drain and publish path (credit arrays, drained buffers, the
///   retire-list append). Every allocation site unwinds through errdefers and
///   `PendingBatch.deinit`, which leave the fetch releasable, and no pool or ring was touched.
///   The shard's memory budget (`supervisor_limits.shard_memory`) makes this the error a
///   runaway shard hits.
/// - `EgressIpcScratchTooSmall` and `InvalidEgressPacket` from encoding this fetch's own packet,
///   which are size checks made before any write.
///
/// Pool or extent inconsistencies, ring corruption, `InvalidFetchBodyStorage` (a borrowed lease
/// in the gateway means an invariant between layers broke) and every unlisted error stay fatal
/// to the shard, so a fault in shared state never passes for one bad fetch.
fn isFetchDemotableError(err: anyerror) bool {
    return switch (err) {
        error.OutOfMemory,
        error.EgressIpcScratchTooSmall,
        error.InvalidEgressPacket,
        => true,
        else => false,
    };
}

/// Whether a fetch of a stopped engine can be submitted again after the restart without the
/// worker noticing. It applies the transport's rule for replaying a pooled HTTP/2 request
/// (`isH2IdempotentReplayable`: an idempotent method and no request body) and also requires
/// that the worker has seen nothing of the response: no head, no body end, no published extent.
/// A redirected task is excluded, because `replaceRequest` already swapped its request for the
/// hop's target, and the finished hops' `billed_sent` and `billed_received` must not be
/// counted again as if the client had asked for the chain twice. Anything ambiguous is demoted
/// instead. It runs only on a stopped engine (`partitionActivesForTeardown`), so the task reads
/// cannot race its threads.
fn isReplaySafeForRedispatch(fetch: *active_fetch.Fetch) bool {
    if (fetch.terminal or fetch.head_sent or fetch.body_end_sent)
        return false;
    if (fetch.outstanding_extents != 0 or !fetch.worker_attached)
        return false;
    const task = fetch.task;
    if (task.isCanceled() or task.redirect_count != 0)
        return false;
    if (task.body.len != 0)
        return false;
    return std.ascii.eqlIgnoreCase(task.method, "GET") or
        std.ascii.eqlIgnoreCase(task.method, "HEAD") or
        std.ascii.eqlIgnoreCase(task.method, "OPTIONS") or
        std.ascii.eqlIgnoreCase(task.method, "DELETE");
}

fn resolveReadyEventCapacity(config: Config) usize {
    if (config.ready_event_capacity != 0)
        return config.ready_event_capacity;
    return @max(@as(usize, 1), config.queue_capacity *| 2);
}

fn requestHeaderBytes(headers: []const ipc.RequestHeader) usize {
    var total: usize = 0;
    for (headers) |header|
        total +|= header.name.len + header.value.len;
    return total;
}

/// The transport's checks for a fetch under `network`, which the transport runs on every hop,
/// redirects included: the scheme and its host rules before DNS, then the class of every
/// resolved address (`transport.EgressPolicy`).
fn transportEgressPolicy(network: policy_mod.NetworkPolicy) transport.EgressPolicy {
    return switch (network.kind) {
        // The transport's own host rules are the whole host check of `any_host`.
        .any_host => .{
            .allow_plain_http = network.allow_http,
            .allow_private_networks = network.allow_private_networks,
        },
    };
}

fn creditBytes(credit: body_credit.Handle) u64 {
    return switch (credit) {
        .h2_data => |h2| @intCast(h2.encoded_bytes),
        .none, .h1_resume => 0,
    };
}

/// The inner engine's wake callback, which its threads call when a task becomes ready or the
/// active table needs a full scan; `cancelWorkerForBackpressure` also calls it on the main loop
/// thread.
fn wake(ctx: ?*anyopaque, event: egress.WakeEvent) void {
    const engine: *Engine = @ptrCast(@alignCast(ctx orelse return));
    // Only the transition from empty to non-empty writes the eventfd. A
    // non-empty queue already has a wake pending, or a drain pass running
    // that will take the entry, so a write per event would only add syscalls.
    const should_signal = switch (event) {
        .generic => engine.ready.requestScan(false),
        .task_ready => |task| engine.ready.enqueueTask(task),
    };
    if (!should_signal)
        return;
    signalWakeFd(engine.wake_fd);
}

fn signalWakeFd(fd: std.posix.fd_t) void {
    var one: u64 = 1;
    _ = std.posix.write(fd, std.mem.asBytes(&one)) catch |err| switch (err) {
        error.WouldBlock => return,
        else => |unexpected| {
            std.log.warn("egress gateway wake write failed: {s}", .{@errorName(unexpected)});
            return;
        },
    };
}

fn drainWakeFd(fd: std.posix.fd_t) void {
    var value: u64 = 0;
    _ = std.posix.read(fd, std.mem.asBytes(&value)) catch |err| switch (err) {
        error.WouldBlock => return,
        else => |unexpected| {
            std.log.warn("egress gateway wake drain failed: {s}", .{@errorName(unexpected)});
            return;
        },
    };
}

fn rawString(value: []const u8) bindings.RawString {
    return .{
        .ptr = if (value.len == 0) null else value.ptr,
        .len = value.len,
    };
}

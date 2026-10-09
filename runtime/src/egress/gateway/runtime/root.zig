//! The gateway process's boot and event loop. The server spawns the process
//! (`server/gateway/process.zig`), and the loop runs on its main thread, which owns the worker
//! registry with each session's fetch budgets, the router, the active-fetch counts, the pending
//! uploads, the control socket and what the server's hello brings: the key that verifies egress
//! tokens and the network policy table. The loop's work lives in the comptime mixins beside this
//! file: `control_flow.zig` (the control socket), `worker_flow.zig` (worker commands and
//! backpressure), `upload_flow.zig` (pooled request bodies), `shard_flow.zig` (shard collection
//! and supervision) and `body_release_flow.zig` (body-pool releases).
//!
//! Boot order is fixed. The sizing plan is computed and the decoder libraries load before the
//! sandbox hides /proc and every library file; the trust store loads before any engine thread
//! exists; the shards' threads and the readiness ring exist before seccomp, which forbids
//! creating either; and gateway-ready is the last step.
//!
//! Dependencies run one way: the loop routes worker commands to shards, a shard owns an engine,
//! and only the engine calls the outbound transport. The gateway holds the network capability,
//! so every worker command is hostile input, even from a worker of the same definition. A new
//! command path must pass the checks the existing ones do: the token verification and the fetch
//! budget in `worker_flow.zig` (`budgets.zig`), the session-scoped routes in `router.zig`, and
//! the network policy the token names, which the egress transport enforces on every hop against
//! server-side request forgery (SSRF). Isolation is keyed by worker session, security cell and
//! policy entry, and a worker's fetch and body ids mean nothing outside its session.

const std = @import("std");
const egress_client = @import("collo_egress_client");
const ipc = @import("collo_ipc");

const active_fetch = @import("../active_fetch.zig");
const control = @import("../control.zig");
const engine_mod = @import("../engine.zig");
const limit_tracker = @import("../limit_tracker.zig");
const policy_mod = @import("../policy.zig");
const readiness_mod = @import("../readiness.zig");
const router_mod = @import("../router.zig");
const sandbox = @import("../sandbox.zig");
const shard_set = @import("../shard_set.zig");
const sizing = @import("../sizing.zig");
const supervisor_limits = @import("../supervisor_limits.zig");
const worker_registry = @import("../worker_registry.zig");
const body_release_flow = @import("body_release_flow.zig");
const control_flow = @import("control_flow.zig");
const shard_flow = @import("shard_flow.zig");
const upload_flow = @import("upload_flow.zig");
const worker_flow = @import("worker_flow.zig");

const scratch_len: usize = ipc.max_message_bytes;
const PendingControlPackets = control_flow.PendingControlPackets;

/// Boots the gateway on `control_fd`, the control socket it inherits from the server
/// (`launch.zig`), and runs its loop until the server shuts it down. The gateway owns
/// `control_fd` from the call on and closes it when it stops.
pub fn run(allocator: std.mem.Allocator, control_fd: std.posix.fd_t) !void {
    // The plan reads the cgroup's CPU quota through /proc, which the sandbox hides, and the
    // server computes the same plan from the same environment (`sizing.zig`).
    const plan = try sizing.Plan.compute();
    // The decoders' libraries load before the sandbox, whose root holds no library files
    // (`sandbox.zig`); a coding whose library does not load here is never advertised or decoded.
    warnMissingDecoders(egress_client.decompress.load());
    try sandbox.applyProcessBaseline();
    // The trust store loads now, before any engine thread exists and before seccomp, so no
    // verified fetch reads the filesystem and the first one does not pay for the load.
    try egress_client.tls.preloadVerifiedContext();
    var gateway = try Gateway.init(allocator, control_fd, plan);
    defer gateway.deinit();
    try gateway.run();
}

/// A gateway without zlib or the brotli decoder still boots: it advertises only the codings it
/// decodes (`decompress.defaultAcceptEncoding`), and a response in another coding fails its fetch
/// with `error.UnsupportedCompressionMethod`.
fn warnMissingDecoders(support: egress_client.decompress.Support) void {
    if (!support.zlib) {
        std.log.warn("egress gateway: zlib did not load; fetches advertise only the identity coding", .{});
    } else if (!support.brotli) {
        std.log.warn("egress gateway: the brotli decoder did not load; fetches do not advertise br", .{});
    }
}

const Gateway = struct {
    allocator: std.mem.Allocator,
    control_fd: std.posix.fd_t,
    workers: worker_registry.Registry = .{},
    shards: shard_set.Set = .{},
    limits: limit_tracker.Tracker = .{},
    router: router_mod.Router = .{},
    completed_fetches: std.array_list.Aligned(active_fetch.WorkerScopedFetch, null) = .empty,
    max_workers: usize,
    /// The limits every fetch runs under, `policy.production`.
    policy: policy_mod.Policy,
    /// The token key, the network policy table and each entry's isolation id, which only the
    /// server's hello writes (`control_flow.zig`).
    hello: control_flow.HelloState = .{},
    scratch: []u8,
    /// Scratch for decoding worker commands, used only on the loop thread. It lives on the heap:
    /// its arrays are sized by the protocol's limits, too large for a stack, and as a
    /// thread-local it would be copied into every thread of the binary.
    decode_scratch: *ipc.GatewayEgressDecodeScratch,
    pending_control_packets: PendingControlPackets = .{},
    /// Admitted body-pooled fetches whose request bodies are still arriving (`upload_flow.zig`).
    pending_uploads: upload_flow.PendingUploads = .{},
    /// True while a shard-ready collection pass runs, so that completion-eventfd writes wait
    /// for the end of the pass and each worker gets one instead of one per packet.
    coalesce_completion_notifies: bool = false,

    const BodyReleaseFlow = body_release_flow.Methods(Gateway);
    const ControlFlow = control_flow.Methods(Gateway);
    const ShardFlow = shard_flow.Methods(Gateway);
    const UploadFlow = upload_flow.Methods(Gateway);
    const WorkerFlow = worker_flow.Methods(Gateway);

    pub const drainWorkerPoolReleases = BodyReleaseFlow.drainWorkerPoolReleases;

    pub const drainControl = ControlFlow.drainControl;
    pub const controlEvents = ControlFlow.controlEvents;
    pub const sendAttachAck = ControlFlow.sendAttachAck;
    pub const reportSessionRemoved = ControlFlow.reportSessionRemoved;
    pub const sendOrQueueControlPacket = ControlFlow.sendOrQueueControlPacket;
    pub const flushPendingControlPackets = ControlFlow.flushPendingControlPackets;
    pub const handleControl = ControlFlow.handleControl;

    pub const queuePacket = ShardFlow.queuePacket;
    pub const publishBodyChunkBatch = ShardFlow.publishBodyChunkBatch;
    pub const noteCompletionWrite = ShardFlow.noteCompletionWrite;
    pub const flushCompletionNotifies = ShardFlow.flushCompletionNotifies;
    pub const refreshReadinessInterests = ShardFlow.refreshReadinessInterests;
    pub const collectShardReady = ShardFlow.collectShardReady;
    pub const superviseShardFailure = ShardFlow.superviseShardFailure;
    pub const redispatchReplayFetch = ShardFlow.redispatchReplayFetch;

    pub const registerPendingUpload = UploadFlow.registerPendingUpload;
    pub const handleUploadChunkBatch = UploadFlow.handleUploadChunkBatch;
    pub const applyUploadChunk = UploadFlow.applyUploadChunk;
    pub const submitAssembledUpload = UploadFlow.submitAssembledUpload;
    pub const failPendingUpload = UploadFlow.failPendingUpload;
    pub const dropRequestUploads = UploadFlow.dropRequestUploads;
    pub const retirePendingUpload = UploadFlow.retirePendingUpload;
    pub const deinitPendingUploads = UploadFlow.deinitPendingUploads;

    pub const handleWorker = WorkerFlow.handleWorker;
    pub const handleWorkerPacket = WorkerFlow.handleWorkerPacket;
    pub const wakeWorkerAfterCommandDrops = WorkerFlow.wakeWorkerAfterCommandDrops;
    pub const removeWorker = WorkerFlow.removeWorker;
    pub const handleCancel = WorkerFlow.handleCancel;
    pub const handleReleaseBody = WorkerFlow.handleReleaseBody;
    pub const recordInvalidWorkerCommand = WorkerFlow.recordInvalidWorkerCommand;
    pub const queueAbortAck = WorkerFlow.queueAbortAck;
    pub const queueFetchError = WorkerFlow.queueFetchError;
    pub const findWorkerBySession = WorkerFlow.findWorkerBySession;
    pub const findWorkerIndexBySession = WorkerFlow.findWorkerIndexBySession;
    pub const markWorkerForDrop = WorkerFlow.markWorkerForDrop;
    pub const drainPendingWorkerDrops = WorkerFlow.drainPendingWorkerDrops;
    pub const refreshAllWorkerBackpressure = WorkerFlow.refreshAllWorkerBackpressure;
    pub const refreshWorkerBackpressure = WorkerFlow.refreshWorkerBackpressure;
    pub const measureWorkerBackpressure = WorkerFlow.measureWorkerBackpressure;
    pub const wakeShardsForWorkerPressureChange = WorkerFlow.wakeShardsForWorkerPressureChange;
    pub const cancelWorkerFetchesForBackpressure = WorkerFlow.cancelWorkerFetchesForBackpressure;
    pub const removeRoutesForWorker = WorkerFlow.removeRoutesForWorker;
    pub const removeRoute = WorkerFlow.removeRoute;
    pub const retireRoute = WorkerFlow.retireRoute;
    pub const activeFetchesForWorker = WorkerFlow.activeFetchesForWorker;
    pub const incrementWorkerFetchCount = WorkerFlow.incrementWorkerFetchCount;
    pub const decrementWorkerFetchCount = WorkerFlow.decrementWorkerFetchCount;
    pub const activeFetchesForSecurityCell = WorkerFlow.activeFetchesForSecurityCell;
    pub const incrementSecurityCellFetchCount = WorkerFlow.incrementSecurityCellFetchCount;
    pub const decrementSecurityCellFetchCount = WorkerFlow.decrementSecurityCellFetchCount;

    fn init(
        allocator: std.mem.Allocator,
        control_fd: std.posix.fd_t,
        plan: sizing.Plan,
    ) !Gateway {
        var control_fd_owned = true;
        errdefer if (control_fd_owned) std.posix.close(control_fd);

        const shard_memory_budget_bytes = supervisor_limits.shard_memory.budget_bytes;
        // Once both buffers are gateway fields, `errdefer gateway.deinit()`
        // frees them, so they take no errdefer of their own, which would free
        // them a second time on the shard-init error path.
        // FIXME: a failed `decode_scratch` allocation leaks `scratch`.
        const scratch = try allocator.alloc(u8, scratch_len);
        const decode_scratch = try allocator.create(ipc.GatewayEgressDecodeScratch);
        decode_scratch.* = .{};
        var gateway = Gateway{
            .allocator = allocator,
            .control_fd = control_fd,
            .max_workers = plan.workers_max,
            .policy = policy_mod.production,
            .scratch = scratch,
            .decode_scratch = decode_scratch,
        };
        control_fd_owned = false;
        errdefer gateway.deinit();

        gateway.shards = try shard_set.Set.init(allocator, plan.shard_count, .{
            .policy = gateway.policy,
            .h2_connector_count = plan.engine_threads.h2_connectors,
        }, shard_memory_budget_bytes);
        return gateway;
    }

    fn deinit(self: *Gateway) void {
        self.shards.deinit(self.allocator);
        self.workers.deinit(self.allocator);
        self.deinitPendingUploads();
        self.limits.deinit(self.allocator);
        self.router.deinit(self.allocator);
        self.completed_fetches.deinit(self.allocator);
        if (self.scratch.len != 0) {
            self.allocator.free(self.scratch);
        }
        self.allocator.destroy(self.decode_scratch);
        std.posix.close(self.control_fd);
        self.* = undefined;
    }

    fn run(self: *Gateway) !void {
        try self.shards.startAll(
            self,
            queuePacketCallback,
            publishBodyChunkBatchCallback,
            workerPressureProbeCallback,
            workerFaultReporterCallback,
        );
        var readiness = try readiness_mod.Backend.init(self.allocator, self.shards.len(), self.max_workers);
        defer readiness.deinit();
        try sandbox.applySeccompAfterThreadsStarted();
        // Gateway-ready must be the last boot step: the server's spawn waits
        // for it, and the gateway the server then records must be fully
        // sandboxed, with no boot step left for an attach to race. Nothing has
        // been sent on the control socket yet, so this nonblocking send cannot
        // find the buffer full.
        try control.sendGatewayReady(self.control_fd);
        while (true) {
            self.refreshAllWorkerBackpressure();
            const interests = try self.refreshReadinessInterests();
            try readiness.pruneWorkers(interests.workers);
            try readiness.armWithControlEvents(
                self.control_fd,
                self.controlEvents(),
                interests.shards,
                interests.workers,
            );

            var ready_events: [readiness_mod.wait_ready_max]readiness_mod.Ready = undefined;
            const ready_count = try readiness.wait(&ready_events);
            try self.drainPendingWorkerDrops();
            self.refreshAllWorkerBackpressure();

            for (ready_events[0..ready_count]) |event| {
                switch (event) {
                    .control => |revents| {
                        if ((revents & (std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0)
                            return;
                        if ((revents & std.posix.POLL.OUT) != 0)
                            try self.flushPendingControlPackets();
                        if ((revents & std.posix.POLL.IN) != 0) {
                            if (try self.drainControl())
                                return;
                            try self.flushPendingControlPackets();
                        }
                    },
                    else => {},
                }
            }

            for (ready_events[0..ready_count]) |event| {
                switch (event) {
                    .control => {},
                    .shard => |shard_ready| {
                        // A shard fault restarts that shard in place. Only a
                        // failed teardown or restart, or an exhausted restart
                        // budget, propagates from the supervisor, and that ends
                        // the process. This event consumed the shard's readiness
                        // poll, so the next pass arms the restarted engine's
                        // wake eventfd again.
                        if ((shard_ready.revents & (std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0) {
                            try self.superviseShardFailure(shard_ready.index, error.EgressGatewayShardFailed);
                        } else if ((shard_ready.revents & std.posix.POLL.IN) != 0) {
                            self.collectShardReady(shard_ready.index) catch |err|
                                // An error the engine did not demote to one
                                // fetch's failure belongs to the whole shard.
                                try self.superviseShardFailure(shard_ready.index, err);
                        }
                    },
                    .worker => |worker_ready| {
                        const index = self.findWorkerIndexBySession(worker_ready.session_id) orelse continue;
                        if (worker_ready.source == .liveness and (worker_ready.revents & (std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0) {
                            std.log.warn("egress gateway worker liveness closed session={d} revents=0x{x}", .{
                                worker_ready.session_id,
                                @as(u16, @bitCast(worker_ready.revents)),
                            });
                            try self.removeWorker(index, .liveness_closed);
                            continue;
                        }
                        if (worker_ready.source == .command and (worker_ready.revents & std.posix.POLL.IN) != 0) {
                            if (!self.handleWorker(index)) {
                                try self.removeWorker(index, .command_ring_failed);
                                continue;
                            }
                        }
                    },
                }
            }
            try self.drainPendingWorkerDrops();
            self.refreshAllWorkerBackpressure();
        }
    }
};

fn queuePacketCallback(ctx: ?*anyopaque, worker_session_id: u64, bytes: []const u8) !void {
    const gateway: *Gateway = @ptrCast(@alignCast(ctx orelse return error.EgressGatewayUnavailable));
    try gateway.queuePacket(worker_session_id, bytes);
}

fn publishBodyChunkBatchCallback(
    ctx: ?*anyopaque,
    worker_session_id: u64,
    fetch_id: u64,
    body_id: u64,
    chunks: []const engine_mod.BodyChunkPayload,
    scratch: []u8,
) !usize {
    const gateway: *Gateway = @ptrCast(@alignCast(ctx orelse return error.EgressGatewayUnavailable));
    return try gateway.publishBodyChunkBatch(worker_session_id, fetch_id, body_id, chunks, scratch);
}

/// The engines' worker-pressure probe. A worker that is gone, or whose completion ring cannot be
/// read, reports `pause_pulls`, so no body is drained toward it.
fn workerPressureProbeCallback(ctx: ?*anyopaque, worker_session_id: u64) policy_mod.WorkerPressure {
    const gateway: *Gateway = @ptrCast(@alignCast(ctx orelse return .{ .pause_pulls = true }));
    const worker = gateway.findWorkerBySession(worker_session_id) orelse return .{ .pause_pulls = true };
    var pressure = worker.pressure();
    pressure.pool_free_bytes = worker.endpoint.body_pool.freeBlocks() * ipc.egress_shared.body_pool_block_size;
    const ring_usage = worker.endpoint.completion.usage() catch return .{ .pause_pulls = true };
    pressure.completion_ring_free_bytes = ring_usage.capacity - ring_usage.used;
    return pressure;
}

fn workerFaultReporterCallback(ctx: ?*anyopaque, worker_session_id: u64, reason: []const u8) void {
    const gateway: *Gateway = @ptrCast(@alignCast(ctx orelse return));
    std.log.warn(
        "egress gateway marking worker for drop worker_session_id={d}: {s}",
        .{ worker_session_id, reason },
    );
    gateway.markWorkerForDrop(worker_session_id);
}

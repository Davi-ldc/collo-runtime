//! A stand-in for the gateway's loop (`runtime/root.zig`) for the admission and control suites
//! (`worker_flow.zig`, `control_flow.zig`). It instantiates the real runtime mixins (worker
//! commands, pooled uploads, the shard flow, body releases and the control socket) over real
//! gateway state, one real shared-memory endpoint and a socket pair. The test plays the worker on
//! the endpoint, writing command packets into the command ring and reading what the gateway
//! queues on the completion ring, and plays the server on its end of the socket pair, where the
//! hello and `request_ended` arrive as a server sends them. Everything allocates from
//! `std.testing.allocator`, so every case is also a leak check.
//!
//! The harness attaches its worker straight to the registry, not through an `attach_worker`
//! packet, so a gateway built without its hello still holds one session to present tokens from.

const std = @import("std");
const gateway = @import("collo_egress_gateway");
const ipc = @import("collo_ipc");
const os = @import("collo_os");

const budgets = gateway.budgets;
const control = gateway.control;
const policy = gateway.policy;
const sessions = gateway.sessions;
const egress_token = ipc.egress_token;

const body_release_flow = gateway.testing.body_release_flow;
const control_flow = gateway.testing.control_flow;
const shard_flow = gateway.testing.shard_flow;
const upload_flow = gateway.testing.upload_flow;
const worker_flow = gateway.testing.worker_flow;

/// The loop's decode scratch. It holds `ipc.egress.max_upload_chunk_batch_count` upload views,
/// too large for the test stack the harness lives on, so it is a file-level variable.
var loop_decode_scratch: ipc.GatewayEgressDecodeScratch = .{};

/// The batch the harness sends `request_ended` entries in; its packet buffer is too large for
/// the test stack.
var request_ended_batch: control.RequestEndedBatch = .{};

/// The key every harness's hello carries.
pub const hello_key: egress_token.Key = keyFrom(0x5a);
/// The key of the gateway before this one, under which a worker may still hold tokens.
pub const earlier_key: egress_token.Key = keyFrom(0xa5);
pub const security_cell_id: policy.SecurityCellId = @splat(7);
/// A deadline after any monotonic time the run reads, so a token minted with it is live.
pub const live_deadline_ns: u64 = std.math.maxInt(u64) / 2;
/// A deadline every monotonic clock has passed, so a token minted with it has expired.
pub const passed_deadline_ns: u64 = 1;
/// The longest URL `loopbackUrl` writes.
pub const loopback_url_bytes_max: usize = 32;
/// The request every token names unless a test says otherwise.
pub const request_id: u64 = 11;
pub const request_generation: u64 = 3;
/// The largest packet the loop sends the server, an attach ack; a removal report is shorter.
const server_packet_bytes_max: usize = @sizeOf(control.Header) + @sizeOf(control.AttachAck);

/// The gateway's loop state as `runtime/root.zig` declares it, with the same mixins.
pub const Loop = struct {
    allocator: std.mem.Allocator,
    control_fd: std.posix.fd_t,
    workers: gateway.worker_registry.Registry = .{},
    shards: gateway.shard_set.Set = .{},
    limits: gateway.limit_tracker.Tracker = .{},
    router: gateway.router.Router = .{},
    completed_fetches: std.array_list.Aligned(gateway.active_fetch.WorkerScopedFetch, null) = .empty,
    max_workers: usize = 4,
    policy: policy.Policy,
    hello: control_flow.HelloState = .{},
    scratch: []u8,
    decode_scratch: *ipc.GatewayEgressDecodeScratch = &loop_decode_scratch,
    pending_control_packets: control_flow.PendingControlPackets = .{},
    pending_uploads: upload_flow.PendingUploads = .{},
    coalesce_completion_notifies: bool = false,

    const BodyReleaseFlow = body_release_flow.Methods(Loop);
    const ControlFlow = control_flow.Methods(Loop);
    const ShardFlow = shard_flow.Methods(Loop);
    const UploadFlow = upload_flow.Methods(Loop);
    const WorkerFlow = worker_flow.Methods(Loop);

    pub const drainWorkerPoolReleases = BodyReleaseFlow.drainWorkerPoolReleases;

    pub const drainControl = ControlFlow.drainControl;
    pub const controlEvents = ControlFlow.controlEvents;
    pub const sendAttachAck = ControlFlow.sendAttachAck;
    pub const reportSessionRemoved = ControlFlow.reportSessionRemoved;
    pub const sendOrQueueControlPacket = ControlFlow.sendOrQueueControlPacket;
    pub const flushPendingControlPackets = ControlFlow.flushPendingControlPackets;
    pub const handleControl = ControlFlow.handleControl;

    pub const queuePacket = ShardFlow.queuePacket;
    pub const noteCompletionWrite = ShardFlow.noteCompletionWrite;
    pub const flushCompletionNotifies = ShardFlow.flushCompletionNotifies;

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
};

pub const Options = struct {
    /// The limits the loop admits under; only the suites that test a limit change it.
    policy: policy.Policy = .{},
    /// The table of the hello the server sends at init, or null for a gateway that has not
    /// received its hello.
    hello_table: ?policy.PolicyTable = policy.PolicyTable.single(policy.public_https),
    shard_count: usize = 1,
    /// Connector threads of each shard engine (`engine.Config.h2_connector_count`). With 0 an
    /// engine refuses every submission with `error.EgressEngineUnavailable` after its task took
    /// the fetch, so the task ends inside `Engine.submit` on the test's thread.
    engine_connector_count: usize = 1,
};

/// What a token minted by `Harness.token` names. The defaults make a live request token of the
/// harness's session under the hello's key.
pub const TokenOptions = struct {
    key: *const egress_token.Key = &hello_key,
    kind: egress_token.Kind = .request,
    /// The harness's own session when null.
    session_id: ?u64 = null,
    policy_id: u16 = policy.public_https_id,
    budget: u32 = 16,
    request_id: u64 = request_id,
    request_generation: u64 = request_generation,
    deadline_monotonic_ns: u64 = live_deadline_ns,
};

pub const FetchOptions = struct {
    fetch_id: u64,
    body_id: u64,
    token: egress_token.Bytes,
    /// Request-body bytes the worker announces for the upload pool; nonzero sets the
    /// body-pooled flag.
    pooled_body_len: u64 = 0,
    /// The response-body limit the worker asks for; 0 leaves the gateway's own.
    max_body_bytes: u64 = 0,
};

/// The URL of fetch `fetch_id`: a loopback origin, which the transport refuses whatever a policy
/// entry allows, without a packet on the network. An admitted fetch to it stays in its engine's
/// active table until a collection pass, which these suites never run, so its record can be read.
/// Each fetch id below 62,500 gets an origin of its own, so no two fetches of a test share a
/// connection attempt and the suites do not depend on how the transport groups them.
pub fn loopbackUrl(buffer: *[loopback_url_bytes_max]u8, fetch_id: u64) []const u8 {
    const third = (fetch_id / 250) % 250;
    const fourth = fetch_id % 250 + 1;
    return std.fmt.bufPrint(buffer, "https://127.0.{d}.{d}:9/", .{ third, fourth }) catch unreachable;
}

/// Owns the loop stand-in, the worker's view of the endpoint, whose other view the loop's
/// registry owns, and the server's end of the control socket pair.
pub const Harness = struct {
    loop: Loop,
    worker_endpoint: ipc.egress_shared.Endpoint,
    session_id: u64,
    /// The server's end of the control socket; the loop owns the other end.
    server_fd: std.posix.fd_t,
    encode_scratch: []u8,
    read_buffer: []u8,

    pub fn init(options: Options) !Harness {
        const control_pair = try os.fd.socketPairType(
            std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK,
        );
        var self = Harness{
            .loop = .{
                .allocator = std.testing.allocator,
                .control_fd = control_pair[0],
                .policy = options.policy,
                .scratch = undefined,
            },
            .worker_endpoint = undefined,
            .session_id = 0,
            .server_fd = control_pair[1],
            .encode_scratch = undefined,
            .read_buffer = undefined,
        };
        errdefer {
            std.posix.close(self.loop.control_fd);
            std.posix.close(self.server_fd);
        }
        self.loop.scratch = try std.testing.allocator.alloc(u8, ipc.max_message_bytes);
        errdefer std.testing.allocator.free(self.loop.scratch);
        self.encode_scratch = try std.testing.allocator.alloc(u8, ipc.max_message_bytes);
        errdefer std.testing.allocator.free(self.encode_scratch);
        self.read_buffer = try std.testing.allocator.alloc(u8, ipc.max_message_bytes);
        errdefer std.testing.allocator.free(self.read_buffer);

        self.loop.shards = try gateway.shard_set.Set.init(
            std.testing.allocator,
            options.shard_count,
            .{ .h2_connector_count = options.engine_connector_count },
            gateway.supervisor_limits.shard_memory.budget_bytes,
        );
        errdefer self.loop.shards.deinit(std.testing.allocator);

        // The server sends the hello before any attach, right after the gateway reports ready.
        if (options.hello_table) |table| {
            try control.sendHello(self.server_fd, &hello_key, &table);
            try std.testing.expect(!try self.loop.drainControl());
        }

        // A real endpoint with the worker's view here and the gateway's view attached to the
        // registry. Each view maps duplicates of the raw fds, so the gateway owns a set apart
        // from the worker's.
        var fds = try createSession();
        defer fds.deinit();
        var worker_raw = try dupEgressRawFds(fds.rawForWorker());
        self.worker_endpoint = try ipc.egress_shared.mapEndpointTakeForWorker(&worker_raw);
        errdefer self.worker_endpoint.deinit();
        var gateway_raw = try dupEgressRawFds(fds.rawForGateway());
        var gateway_endpoint = try ipc.egress_shared.mapEndpointTakeForGateway(&gateway_raw);
        var gateway_endpoint_owned = true;
        errdefer if (gateway_endpoint_owned) gateway_endpoint.deinit();

        errdefer self.loop.workers.deinit(std.testing.allocator);
        const attached = try self.loop.workers.attachEndpoint(
            std.testing.allocator,
            &gateway_endpoint,
            security_cell_id,
        );
        gateway_endpoint_owned = false;
        self.session_id = attached.session_id;
        return self;
    }

    pub fn deinit(self: *Harness) void {
        // `deinitPendingUploads` frees what a test left assembling. `shards.deinit` stops a
        // started engine, joins its threads and frees it the same way as one never started.
        self.loop.deinitPendingUploads();
        self.loop.shards.deinit(std.testing.allocator);
        self.loop.workers.deinit(std.testing.allocator);
        self.loop.limits.deinit(std.testing.allocator);
        self.loop.router.deinit(std.testing.allocator);
        self.loop.completed_fetches.deinit(std.testing.allocator);
        self.worker_endpoint.deinit();
        std.posix.close(self.loop.control_fd);
        if (self.server_fd >= 0)
            std.posix.close(self.server_fd);
        std.testing.allocator.free(self.loop.scratch);
        std.testing.allocator.free(self.encode_scratch);
        std.testing.allocator.free(self.read_buffer);
        self.* = undefined;
    }

    /// Starts the shard engines, so an admitted fetch runs the real submit path. Only a test
    /// that expects a fetch to reach an engine needs them.
    pub fn startShards(self: *Harness) !void {
        try self.loop.shards.startAll(
            null,
            noopPacketSender,
            noopBodyChunkBatchSender,
            unboundedPressureProbe,
            ignoringFaultReporter,
        );
    }

    pub fn worker(self: *Harness) *sessions.Worker {
        return self.loop.workers.bySession(self.session_id).?;
    }

    /// The key the loop verifies tokens under: the hello's, or the zero key before it.
    pub fn helloKey(self: *const Harness) *const egress_token.Key {
        return &self.loop.hello.key;
    }

    /// The hello's policy table, empty before it.
    pub fn helloPolicies(self: *const Harness) *const policy.PolicyTable {
        return &self.loop.hello.policies;
    }

    /// The pool isolation id the loop computed for entry `policy_id` of the hello's table.
    pub fn isolationId(self: *const Harness, policy_id: u16) policy.PoolIsolationId {
        std.debug.assert(policy_id < self.loop.hello.policies.count);
        return self.loop.hello.isolation_ids[policy_id];
    }

    pub fn tokenFields(self: *const Harness, options: TokenOptions) egress_token.Fields {
        return .{
            .kind = options.kind,
            .policy_id = options.policy_id,
            .budget = options.budget,
            .session_id = options.session_id orelse self.session_id,
            .request_id = options.request_id,
            .request_generation = options.request_generation,
            .deadline_monotonic_ns = options.deadline_monotonic_ns,
        };
    }

    /// A token minted as the server mints one.
    pub fn token(self: *const Harness, options: TokenOptions) egress_token.Bytes {
        const minted = egress_token.mint(options.key, self.tokenFields(options));
        return egress_token.asBytes(&minted).*;
    }

    /// The boot token of the harness's session, with the child window ending at
    /// `deadline_monotonic_ns`.
    pub fn bootToken(self: *const Harness, deadline_monotonic_ns: u64) egress_token.Bytes {
        return self.token(.{
            .kind = .boot,
            .request_id = 0,
            .request_generation = 0,
            .deadline_monotonic_ns = deadline_monotonic_ns,
        });
    }

    pub fn encodeFetchStart(self: *Harness, options: FetchOptions) ![]u8 {
        const pooled = options.pooled_body_len != 0;
        var url_buffer: [loopback_url_bytes_max]u8 = undefined;
        return ipc.encodeEgressFetchStartInto(self.encode_scratch, .{
            .fetch_id = options.fetch_id,
            .egress_token = options.token,
            .body_id = options.body_id,
            .flags = if (pooled) ipc.egress_fetch_start_flag_body_pooled else 0,
            .max_body_bytes = options.max_body_bytes,
            .method = if (pooled) "POST" else "GET",
            .url = loopbackUrl(&url_buffer, options.fetch_id),
            .headers = &.{},
            .body = "",
            .pooled_body_len = options.pooled_body_len,
        });
    }

    /// Hands one fetch start to the loop's dispatch and returns whether the worker stays.
    pub fn sendFetchStart(self: *Harness, options: FetchOptions) !bool {
        const packet = try self.encodeFetchStart(options);
        return self.loop.handleWorkerPacket(self.worker(), packet);
    }

    /// Sends a fetch start that admission must accept: the worker stays, nothing is struck and
    /// no error packet is queued.
    pub fn expectAdmitted(self: *Harness, options: FetchOptions) !void {
        const strikes = self.worker().invalid_commands.count;
        try std.testing.expect(try self.sendFetchStart(options));
        try std.testing.expectEqual(strikes, self.worker().invalid_commands.count);
        try self.expectNoMoreCompletionPackets();
        try std.testing.expect(self.loop.router.routeForBody(
            self.session_id,
            options.fetch_id,
            options.body_id,
        ) != null);
    }

    /// Sends a fetch start that admission must refuse with `message`, keeping the worker, and
    /// checks the strike it counted, or that it counted none.
    pub fn expectRefused(
        self: *Harness,
        options: FetchOptions,
        message: []const u8,
        strike: Strike,
    ) !void {
        const strikes = self.worker().invalid_commands.count;
        try std.testing.expect(try self.sendFetchStart(options));
        const expected = switch (strike) {
            .strike => strikes + 1,
            .no_strike => strikes,
        };
        try std.testing.expectEqual(expected, self.worker().invalid_commands.count);
        try self.expectQueuedFetchError(options.fetch_id, options.body_id, message);
        try self.expectNoMoreCompletionPackets();
        // Nothing of the fetch was admitted: no route and no engine work.
        try std.testing.expect(self.loop.router.routeForFetch(self.session_id, options.fetch_id) == null);
    }

    pub fn writeCommand(self: *Harness, bytes: []const u8) !void {
        _ = try self.worker_endpoint.command.writePacket(bytes);
    }

    /// Writes a request-body extent into the upload pool as the worker would and returns its
    /// handle, by which the gateway borrows the same extent.
    pub fn writeUploadExtent(self: *Harness, bytes: []const u8) !u64 {
        return self.worker_endpoint.upload_pool.writeChunk(bytes);
    }

    pub fn expectQueuedFetchError(self: *Harness, fetch_id: u64, body_id: u64, message: []const u8) !void {
        const packet = (try self.worker_endpoint.completion.readPacket(self.read_buffer)) orelse
            return error.MissingQueuedFetchError;
        const view = try ipc.decodeEgressFetchError(packet);
        try std.testing.expectEqual(fetch_id, view.fetch_id);
        try std.testing.expectEqual(body_id, view.body_id);
        try std.testing.expectEqualStrings(message, view.message);
    }

    pub fn expectNoMoreCompletionPackets(self: *Harness) !void {
        try std.testing.expect((try self.worker_endpoint.completion.readPacket(self.read_buffer)) == null);
    }

    /// Sends the hello for `table` under `hello_key` as a server does, without draining it.
    pub fn sendHello(self: *Harness, table: *const policy.PolicyTable) !void {
        try control.sendHello(self.server_fd, &hello_key, table);
    }

    /// Sends `entries` as one `request_ended` packet, as a lane flushes its batch, and has the
    /// loop drain the control socket, which must keep the gateway running.
    pub fn sendRequestEnded(self: *Harness, entries: []const control.RequestEndedEntry) !void {
        try self.sendRequestEndedPacket(entries);
        try std.testing.expect(!try self.loop.drainControl());
    }

    /// Sends `entries` as one `request_ended` packet and leaves it on the socket.
    pub fn sendRequestEndedPacket(self: *Harness, entries: []const control.RequestEndedEntry) !void {
        request_ended_batch.clear();
        for (entries) |entry|
            try std.testing.expect(request_ended_batch.append(entry));
        try request_ended_batch.sendAndClear(self.server_fd);
    }

    /// Takes the next packet the loop sent the server, which must report the removal of session
    /// `session_id`.
    pub fn expectSessionRemovedReport(self: *Harness, session_id: u64) !void {
        var scratch: [server_packet_bytes_max]u8 = undefined;
        var packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, self.server_fd, &scratch);
        defer packet.deinit();
        switch (try control.decodeGatewayToServerPacket(&packet)) {
            .session_removed => |removed| try std.testing.expectEqual(session_id, removed.session_id),
            .attach_ack => return error.TestUnexpectedControlPacket,
        }
    }

    /// Closes the server's end of the control socket, as a server that is gone does.
    pub fn closeServerEnd(self: *Harness) void {
        std.posix.close(self.server_fd);
        self.server_fd = -1;
    }

    /// Checks that no packet from the loop waits on the server's end.
    pub fn expectNoServerPacket(self: *Harness) !void {
        var scratch: [server_packet_bytes_max]u8 = undefined;
        try std.testing.expectError(
            error.WouldBlock,
            ipc.recvPacketWithFdsScratch(std.testing.allocator, self.server_fd, &scratch),
        );
    }

    /// Fills the loop's end of the control socket with one-byte packets the server has not read,
    /// so the loop's next send finds it full, and returns how many it sent.
    pub fn fillControlSocket(self: *Harness) !usize {
        const byte = [_]u8{0};
        // A socket pair holds a few hundred one-byte packets.
        for (0..65_536) |sent| {
            _ = std.posix.send(self.loop.control_fd, &byte, std.posix.MSG.NOSIGNAL) catch |err| switch (err) {
                error.WouldBlock => return sent,
                else => return err,
            };
        }
        return error.TestSocketNeverFills;
    }

    /// Reads `count` one-byte packets `fillControlSocket` sent, so the socket has room again.
    pub fn drainFiller(self: *Harness, count: usize) !void {
        var scratch: [server_packet_bytes_max]u8 = undefined;
        for (0..count) |_| {
            var packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, self.server_fd, &scratch);
            defer packet.deinit();
            try std.testing.expectEqual(@as(usize, 1), packet.bytes.len);
        }
    }

    /// The fetches left in the budget of the session's token for this request, or null while the
    /// session holds no live budget for it.
    pub fn budgetRemaining(self: *Harness, budget_request_id: u64, budget_request_generation: u64) ?u32 {
        for (self.worker().budgets.slots) |slot| {
            if (slot.deadline_monotonic_ns == 0)
                continue;
            if (slot.request_id == budget_request_id and slot.request_generation == budget_request_generation)
                return slot.remaining;
        }
        return null;
    }

    /// The engine's record of an admitted fetch, or null when its shard holds none.
    pub fn activeFetch(self: *Harness, fetch_id: u64, body_id: u64) ?*gateway.active_fetch.Fetch {
        const route = self.loop.router.routeForBody(self.session_id, fetch_id, body_id) orelse return null;
        const shard = self.loop.shards.get(route.record.shard_index);
        return shard.engine.active.find(self.session_id, fetch_id, body_id);
    }

    /// The submit options admission gives a fetch under a live request token of this session,
    /// for the upload tests that register a pending upload directly.
    pub fn uploadSubmitOptions(self: *Harness, deadline_monotonic_ns: u64) gateway.engine.SubmitOptions {
        return .{
            .isolation = .{
                .security_cell_id = security_cell_id,
                .policy_id = self.isolationId(policy.public_https_id),
            },
            .network = policy.public_https,
            .budget_key = .{
                .session_id = self.session_id,
                .request_id = request_id,
                .request_generation = request_generation,
            },
            .request_deadline_mono_ns = deadline_monotonic_ns,
        };
    }
};

pub const Strike = enum { strike, no_strike };

/// A fetch start whose body comes through the upload pool (the body-pooled flag set, no inline
/// bytes), for the upload tests that call `registerPendingUpload` and `applyUploadChunk` directly
/// instead of through the wire codec, so they also reach checks the codec makes unreachable, such
/// as an announced length of zero. Admission has verified the token by then, so the view carries
/// none.
pub fn pooledFetchView(fetch_id: u64, body_id: u64, pooled_body_len: u64) ipc.EgressFetchStartView {
    return .{
        .fetch_id = fetch_id,
        .egress_token = egress_token.none,
        .body_id = body_id,
        .flags = ipc.egress_fetch_start_flag_body_pooled,
        .method = "POST",
        .url = "https://127.0.0.1:9/",
        .headers = &.{},
        .body = "",
        .pooled_body_len = pooled_body_len,
    };
}

/// A fixed key whose bytes all differ, so a key read shifted or truncated would differ too.
pub fn keyFrom(seed: u8) egress_token.Key {
    var key: egress_token.Key = undefined;
    for (&key.bytes, 0..) |*byte, index|
        byte.* = seed +% @as(u8, @intCast(index * 7));
    return key;
}

fn noopPacketSender(ctx: ?*anyopaque, worker_session_id: u64, bytes: []const u8) anyerror!void {
    _ = ctx;
    _ = worker_session_id;
    _ = bytes;
}

fn noopBodyChunkBatchSender(
    ctx: ?*anyopaque,
    worker_session_id: u64,
    fetch_id: u64,
    body_id: u64,
    chunks: []const gateway.engine.BodyChunkPayload,
    scratch: []u8,
) anyerror!usize {
    _ = ctx;
    _ = worker_session_id;
    _ = fetch_id;
    _ = body_id;
    _ = scratch;
    return chunks.len;
}

fn unboundedPressureProbe(ctx: ?*anyopaque, worker_session_id: u64) policy.WorkerPressure {
    _ = ctx;
    _ = worker_session_id;
    return .{ .pool_free_bytes = std.math.maxInt(usize) };
}

fn ignoringFaultReporter(ctx: ?*anyopaque, worker_session_id: u64, reason: []const u8) void {
    _ = ctx;
    _ = worker_session_id;
    _ = reason;
}

/// A session on a wake set of its own. The session holds its own copy of
/// every wake descriptor, so the set closes once the session is built.
pub fn createSession() !ipc.egress_shared.SessionFds {
    var wake_set = try ipc.egress_shared.WakeSet.create();
    defer wake_set.deinit();
    return ipc.egress_shared.createSessionForWorker(&wake_set);
}

fn dupEgressRawFds(fds: ipc.egress_shared.RawFds) !ipc.egress_shared.RawFds {
    var out = ipc.egress_shared.RawFds{};
    errdefer out.close();
    out.command_control_fd = try std.posix.dup(fds.command_control_fd);
    out.command_producer_fd = try std.posix.dup(fds.command_producer_fd);
    out.command_consumer_fd = try std.posix.dup(fds.command_consumer_fd);
    out.command_data_fd = try std.posix.dup(fds.command_data_fd);
    out.completion_control_fd = try std.posix.dup(fds.completion_control_fd);
    out.completion_producer_fd = try std.posix.dup(fds.completion_producer_fd);
    out.completion_consumer_fd = try std.posix.dup(fds.completion_consumer_fd);
    out.completion_data_fd = try std.posix.dup(fds.completion_data_fd);
    out.body_pool_control_fd = try std.posix.dup(fds.body_pool_control_fd);
    out.body_pool_producer_fd = try std.posix.dup(fds.body_pool_producer_fd);
    out.body_pool_consumer_fd = try std.posix.dup(fds.body_pool_consumer_fd);
    out.body_pool_data_fd = try std.posix.dup(fds.body_pool_data_fd);
    out.upload_pool_control_fd = try std.posix.dup(fds.upload_pool_control_fd);
    out.upload_pool_producer_fd = try std.posix.dup(fds.upload_pool_producer_fd);
    out.upload_pool_consumer_fd = try std.posix.dup(fds.upload_pool_consumer_fd);
    out.upload_pool_data_fd = try std.posix.dup(fds.upload_pool_data_fd);
    out.command_eventfd = try std.posix.dup(fds.command_eventfd);
    out.completion_eventfd = try std.posix.dup(fds.completion_eventfd);
    out.liveness_fd = try std.posix.dup(fds.liveness_fd);
    out.peer_liveness_fd = try std.posix.dup(fds.peer_liveness_fd);
    return out;
}

//! The real gateway (`runtime/root.zig:Gateway`) for the gateway suites, built as the process
//! builds it but without the sandbox, with one session attached straight to it. The test plays
//! the worker on the session's endpoint, writing commands into the command ring and reading what
//! the gateway writes on the completion ring, and plays the server on its end of the control
//! socket pair, where the hello, attaches and `boot_ended` arrive as a server sends them; the
//! hello carries a policy image in a sealed memfd (`policy_image.zig`). Everything allocates from
//! `std.testing.allocator`, so every case is also a leak check. Holds no tests.
//!
//! The harness attaches its session through `session_flow.attachSession`, not through an
//! `attach_worker` packet, so a gateway built without its hello still holds one session to
//! present tokens from. Shards start only when a test asks (`Options.start_shards`): an engine
//! that never started refuses every submission with `error.EgressEngineUnavailable`, so most
//! suites see admission and its refusals without a thread. `startRunningFetch` puts a fetch in
//! the table as if its engine ran it, with a task and a response queue the test drives, so the
//! pump and the release drain run against a real endpoint without the network.

const std = @import("std");
const gateway = @import("collo_egress_gateway");
const ipc = @import("collo_ipc");
const os = @import("collo_os");
const egress = @import("collo_egress_client");
const http = @import("collo_http");

const policy_image = @import("policy_image.zig");

const control = gateway.control;
const fetch_table = gateway.fetch_table;
const policy = gateway.policy;
const runtime = gateway.runtime;
const sessions = gateway.sessions;
const egress_token = ipc.egress_token;
const network = egress.network;
const ResponseQueue = egress.core.ResponseQueue;
const Task = egress.task.Task;

/// The key every harness's hello carries.
pub const hello_key: egress_token.Key = keyFrom(0x5a);
/// The key of the gateway before this one, under which a worker may still hold tokens.
pub const earlier_key: egress_token.Key = keyFrom(0xa5);
pub const security_cell_id: policy.SecurityCellId = @splat(7);
/// A deadline after any monotonic time the run reads, so a token minted with it is live.
pub const live_deadline_ns: u64 = std.math.maxInt(u64) / 2;
/// A deadline every monotonic clock has passed, so a token minted with it has expired.
pub const passed_deadline_ns: u64 = 1;
/// The longest host `loopbackHost` writes.
pub const loopback_host_bytes_max: usize = 16;
/// The longest URL `loopbackUrl` writes.
pub const loopback_url_bytes_max: usize = 32;
/// The port of every URL `loopbackUrl` writes.
pub const loopback_port: u16 = 9;
/// The request every token names unless a test says otherwise.
pub const request_id: u64 = 11;
pub const request_generation: u64 = 3;
/// The largest packet the gateway sends the server, an attach ack; a removal report is shorter.
const server_packet_bytes_max: usize = @sizeOf(control.Header) + @sizeOf(control.AttachAck);

pub const Options = struct {
    /// The limits the gateway admits under; only the suites that test a limit change it.
    policy: policy.Policy = policy.production,
    /// Whether the server sends the hello carrying `policy_image.standard` at init; false for a
    /// gateway that has not received its hello.
    hello: bool = true,
    /// Sessions the gateway holds at once; the harness's own session takes one.
    sessions_max: usize = 4,
    shard_count: usize = 1,
    /// Whether the shards' engines start, so an admitted inline fetch reaches the transport.
    start_shards: bool = false,
    shard_memory_budget_bytes: u64 = gateway.containment.shard_memory.budget_bytes,
};

/// What a token minted by `Harness.token` names. The defaults make a live request token of the
/// harness's session under the hello's key.
pub const TokenOptions = struct {
    key: *const egress_token.Key = &hello_key,
    kind: egress_token.Kind = .request,
    /// The harness's own session when null.
    session_id: ?u64 = null,
    policy_id: network.PolicyId = policy_image.public_https_id,
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
    /// The fetch's URL; `loopbackUrl` of `fetch_id` when null.
    url: ?[]const u8 = null,
};

/// A fetch `startRunningFetch` put in the table: its handle and the task and queue the test
/// drives in place of an engine.
pub const RunningFetch = struct {
    handle: fetch_table.Handle,
    task: *Task,
    queue: *ResponseQueue,
};

/// A second session `Harness.attachPeer` attached, with the worker's view of its endpoint.
pub const Peer = struct {
    session_id: u64,
    worker_endpoint: ipc.egress_shared.Endpoint,

    pub fn deinit(self: *Peer) void {
        self.worker_endpoint.deinit();
        self.* = undefined;
    }
};

/// The host of fetch `fetch_id`'s URL: a loopback address, which the transport refuses whatever a
/// policy grants, without a packet on the network. Each fetch id below 62,500 gets an address of
/// its own, so no two fetches of a test share a connection attempt.
pub fn loopbackHost(buffer: *[loopback_host_bytes_max]u8, fetch_id: u64) []const u8 {
    const third = (fetch_id / 250) % 250;
    const fourth = fetch_id % 250 + 1;
    return std.fmt.bufPrint(buffer, "127.0.{d}.{d}", .{ third, fourth }) catch unreachable;
}

/// The URL of fetch `fetch_id`: `https://` `loopbackHost` on `loopback_port`.
pub fn loopbackUrl(buffer: *[loopback_url_bytes_max]u8, fetch_id: u64) []const u8 {
    var host_buffer: [loopback_host_bytes_max]u8 = undefined;
    const host = loopbackHost(&host_buffer, fetch_id);
    return std.fmt.bufPrint(buffer, "https://{s}:{d}/", .{ host, loopback_port }) catch unreachable;
}

/// What a pooled start `Harness.encodeFetchStart` writes for fetch `fetch_id` holds in the
/// session's upload bytes: its body's announced length and the copies of its start, a `POST` to
/// `loopbackUrl` without headers.
pub fn pooledStartBytes(fetch_id: u64, pooled_body_len: u64) u64 {
    var url_buffer: [loopback_url_bytes_max]u8 = undefined;
    const url = loopbackUrl(&url_buffer, fetch_id);
    return pooled_body_len + ipc.fetch_limits.pooledStartHeldBytes("POST".len, url.len, &[_]ipc.RequestHeader{});
}

/// Owns the gateway, the worker's view of the harness's session, whose other view the gateway
/// owns, and the server's end of the control socket pair.
pub const Harness = struct {
    gateway: *runtime.Gateway,
    worker_endpoint: ipc.egress_shared.Endpoint,
    session_id: u64,
    /// The server's end of the control socket; the gateway owns the other end.
    server_fd: std.posix.fd_t,
    encode_scratch: []u8,
    read_buffer: []u8,

    pub fn init(options: Options) !Harness {
        const allocator = std.testing.allocator;
        const control_pair = try os.fd.socketPairType(
            std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK,
        );
        errdefer std.posix.close(control_pair[1]);
        const encode_scratch = try allocator.alloc(u8, ipc.max_message_bytes);
        errdefer allocator.free(encode_scratch);
        const read_buffer = try allocator.alloc(u8, ipc.max_message_bytes);
        errdefer allocator.free(read_buffer);
        const gateway_state = allocator.create(runtime.Gateway) catch |err| {
            std.posix.close(control_pair[0]);
            return err;
        };
        errdefer allocator.destroy(gateway_state);
        try gateway_state.init(allocator, control_pair[0], .{
            .shard_count = options.shard_count,
            .sessions_max = options.sessions_max,
            .policy = options.policy,
            .shard_memory_budget_bytes = options.shard_memory_budget_bytes,
        });
        errdefer gateway_state.deinit();

        var self = Harness{
            .gateway = gateway_state,
            .worker_endpoint = undefined,
            .session_id = 0,
            .server_fd = control_pair[1],
            .encode_scratch = encode_scratch,
            .read_buffer = read_buffer,
        };
        if (options.start_shards)
            try gateway_state.startShards();
        // The server sends the hello before any attach, right after the gateway reports ready.
        if (options.hello) {
            try self.sendStandardHello();
            try std.testing.expect(!try runtime.control_flow.drainControl(gateway_state));
        }
        const peer = try self.attachPeer();
        self.worker_endpoint = peer.worker_endpoint;
        self.session_id = peer.session_id;
        return self;
    }

    pub fn deinit(self: *Harness) void {
        // The gateway ends its sessions' fetches, stops its shards and closes its control end.
        self.gateway.deinit();
        std.testing.allocator.destroy(self.gateway);
        self.worker_endpoint.deinit();
        if (self.server_fd >= 0)
            std.posix.close(self.server_fd);
        std.testing.allocator.free(self.encode_scratch);
        std.testing.allocator.free(self.read_buffer);
        self.* = undefined;
    }

    /// Attaches one more session in `security_cell_id` straight to the gateway and returns it
    /// with the worker's view of its endpoint, which the caller frees.
    pub fn attachPeer(self: *Harness) !Peer {
        return self.attachPeerInCell(security_cell_id);
    }

    pub fn attachPeerInCell(self: *Harness, cell: policy.SecurityCellId) !Peer {
        // Each view maps duplicates of the raw fds, so the gateway owns a set apart from the
        // worker's.
        var fds = try createSession();
        defer fds.deinit();
        var worker_raw = try dupEgressRawFds(fds.rawForWorker());
        var worker_endpoint = try ipc.egress_shared.mapEndpointTakeForWorker(&worker_raw);
        errdefer worker_endpoint.deinit();
        var gateway_raw = try dupEgressRawFds(fds.rawForGateway());
        var gateway_endpoint = try ipc.egress_shared.mapEndpointTakeForGateway(&gateway_raw);
        errdefer gateway_endpoint.deinit();
        const attached = try runtime.session_flow.attachSession(self.gateway, &gateway_endpoint, cell);
        return .{ .session_id = attached.session_id, .worker_endpoint = worker_endpoint };
    }

    pub fn session(self: *Harness) *sessions.Session {
        return self.gateway.sessions.byId(self.session_id).?;
    }

    /// The record of fetch `fetch_id` of the harness's session, or null when it has none.
    pub fn record(self: *Harness, fetch_id: u64) ?*fetch_table.Fetch {
        const handle = self.gateway.fetches.find(self.session_id, fetch_id) orelse return null;
        return self.gateway.fetches.get(handle);
    }

    pub fn tokenFields(self: *const Harness, options: TokenOptions) egress_token.Fields {
        return .{
            .kind = options.kind,
            .policy_id = options.policy_id,
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
            .method = if (pooled) "POST" else "GET",
            .url = options.url orelse loopbackUrl(&url_buffer, options.fetch_id),
            .headers = &.{},
            .body = "",
            .pooled_body_len = options.pooled_body_len,
        });
    }

    /// Hands one command to the gateway's dispatch and returns whether the session stays.
    pub fn sendCommand(self: *Harness, bytes: []const u8) bool {
        return runtime.command_flow.handlePacket(self.gateway, self.session(), bytes);
    }

    /// Hands one fetch start to the gateway's dispatch and returns whether the session stays.
    pub fn sendFetchStart(self: *Harness, options: FetchOptions) !bool {
        const packet = try self.encodeFetchStart(options);
        return self.sendCommand(packet);
    }

    /// Hands a stop for fetch `fetch_id` to the gateway's dispatch and returns whether the
    /// session stays.
    pub fn sendStop(self: *Harness, fetch_id: u64) bool {
        const stop = ipc.EgressStop.init(fetch_id);
        return self.sendCommand(std.mem.asBytes(&stop));
    }

    /// Sends a fetch start that admission must accept: the session stays, no packet is queued
    /// and the fetch has a record.
    pub fn expectAdmitted(self: *Harness, options: FetchOptions) !void {
        try std.testing.expect(try self.sendFetchStart(options));
        try self.expectNoMoreCompletionPackets();
        try std.testing.expect(self.record(options.fetch_id) != null);
    }

    /// Sends a fetch start that admission must refuse with `message`: the session stays, the
    /// error packet is queued, and nothing of the fetch was admitted.
    pub fn expectRefused(self: *Harness, options: FetchOptions, message: []const u8) !void {
        const fetches_before = self.session().fetches.len;
        try std.testing.expect(try self.sendFetchStart(options));
        try self.expectFetchError(options.fetch_id, options.body_id, message);
        try self.expectNoMoreCompletionPackets();
        try std.testing.expectEqual(fetches_before, self.session().fetches.len);
        try std.testing.expect(!self.session().drop_pending);
    }

    pub fn writeCommand(self: *Harness, bytes: []const u8) !void {
        _ = try self.worker_endpoint.command.writePacket(bytes);
    }

    /// Drains the session's command ring as the loop does when its command eventfd turns
    /// readable, and returns whether the session stays.
    pub fn handleCommands(self: *Harness) bool {
        return runtime.command_flow.handleCommands(self.gateway, self.session());
    }

    /// Writes `bytes` into the session's command ring and has the gateway handle its command
    /// eventfd's readiness as its loop does, which removes the session, with a report to the
    /// server, for a command that breaks the protocol. Returns whether the session is still
    /// attached.
    pub fn deliverCommand(self: *Harness, bytes: []const u8) !bool {
        try self.writeCommand(bytes);
        try runtime.session_flow.handleSessionReady(self.gateway, .{
            .session_id = self.session_id,
            .source = gateway.readiness.SessionSource.command,
            .revents = std.posix.POLL.IN,
        });
        return self.gateway.sessions.byId(self.session_id) != null;
    }

    /// Writes a request-body extent into the upload pool as the worker would and returns its
    /// handle, by which the gateway borrows the same extent.
    pub fn writeUploadExtent(self: *Harness, bytes: []const u8) !u64 {
        return self.worker_endpoint.upload_pool.writeChunk(bytes);
    }

    /// Takes the next completion packet, which must fail fetch `fetch_id` with `message` and
    /// the cause `failed`, as every refusal and failure the gateway itself decides does.
    pub fn expectFetchError(self: *Harness, fetch_id: u64, body_id: u64, message: []const u8) !void {
        try self.expectFetchErrorWithCause(fetch_id, body_id, message, .failed);
    }

    pub fn expectFetchErrorWithCause(
        self: *Harness,
        fetch_id: u64,
        body_id: u64,
        message: []const u8,
        cause: ipc.EgressFetchErrorCause,
    ) !void {
        const packet = (try self.worker_endpoint.completion.readPacket(self.read_buffer)) orelse
            return error.MissingQueuedFetchError;
        const view = try ipc.decodeEgressFetchError(packet);
        try std.testing.expectEqual(fetch_id, view.fetch_id);
        try std.testing.expectEqual(body_id, view.body_id);
        try std.testing.expectEqualStrings(message, view.message);
        try std.testing.expectEqual(cause, view.cause);
    }

    /// Takes the next completion packet, which must acknowledge the stop of fetch `fetch_id`.
    pub fn expectAbortAck(self: *Harness, fetch_id: u64, body_id: u64) !void {
        const packet = (try self.worker_endpoint.completion.readPacket(self.read_buffer)) orelse
            return error.MissingQueuedAbortAck;
        const ack = try ipc.decodeEgressAbortAck(packet);
        try std.testing.expectEqual(fetch_id, ack.fetch_id);
        try std.testing.expectEqual(body_id, ack.body_id);
    }

    /// Takes the next completion packet, which must end fetch `fetch_id`'s body.
    pub fn expectBodyEnd(self: *Harness, fetch_id: u64, body_id: u64) !void {
        const packet = (try self.worker_endpoint.completion.readPacket(self.read_buffer)) orelse
            return error.MissingQueuedBodyEnd;
        const end = try ipc.decodeEgressBodyEnd(packet);
        try std.testing.expectEqual(fetch_id, end.fetch_id);
        try std.testing.expectEqual(body_id, end.body_id);
    }

    /// Takes the next completion packet, which must be fetch `fetch_id`'s head, and returns its
    /// status.
    pub fn expectHead(self: *Harness, fetch_id: u64) !u16 {
        const packet = (try self.worker_endpoint.completion.readPacket(self.read_buffer)) orelse
            return error.MissingQueuedHead;
        var scratch: ipc.WorkerEgressDecodeScratch = undefined;
        const head = try ipc.decodeEgressFetchHead(&scratch, packet);
        try std.testing.expectEqual(fetch_id, head.fetch_id);
        return head.status;
    }

    /// Takes the next completion packet, which must be a body chunk batch of fetch `fetch_id`,
    /// copies its extents' bytes into `out` in order and returns the extents, which the caller
    /// releases with `releaseExtents`, and the byte count.
    pub fn expectBodyChunks(
        self: *Harness,
        fetch_id: u64,
        out: []u8,
        extents_out: []ipc.EgressBodyChunkView,
    ) !struct { extents: usize, bytes: usize } {
        const packet = (try self.worker_endpoint.completion.readPacket(self.read_buffer)) orelse
            return error.MissingQueuedBodyChunks;
        const scratch = try std.testing.allocator.create(ipc.WorkerEgressDecodeScratch);
        defer std.testing.allocator.destroy(scratch);
        const chunks = try ipc.decodeEgressBodyChunkBatch(scratch, packet);
        var written: usize = 0;
        for (chunks, 0..) |chunk, index| {
            try std.testing.expectEqual(fetch_id, chunk.fetch_id);
            const bytes = try self.worker_endpoint.body_pool.borrowContiguousChunk(chunk.body_pool_offset, chunk.len);
            @memcpy(out[written..][0..bytes.len], bytes);
            written += bytes.len;
            extents_out[index] = chunk;
        }
        return .{ .extents = chunks.len, .bytes = written };
    }

    /// Returns `extents` to the body pool as the worker does once it consumed them.
    pub fn releaseExtents(self: *Harness, extents: []const ipc.EgressBodyChunkView) !void {
        for (extents) |extent|
            try self.worker_endpoint.body_pool.releaseChunk(extent.body_pool_offset, extent.len);
    }

    pub fn expectNoMoreCompletionPackets(self: *Harness) !void {
        try std.testing.expect((try self.worker_endpoint.completion.readPacket(self.read_buffer)) == null);
    }

    /// Puts a fetch of the harness's session in the table as if shard `shard_index`'s engine ran
    /// it: a task and a response queue allocated from the shard's allocator, the task carrying
    /// the record's handle. No engine thread touches them; the test appends to the queue and
    /// settles the task (`settleSuccess`, `settleCanceled`).
    pub fn startRunningFetch(self: *Harness, fetch_id: u64, body_id: u64, shard_index: usize) !RunningFetch {
        const engine = &self.gateway.shards.get(shard_index).engine;
        const handle = try runtime.fetch_flow.insert(self.gateway, self.session(), .{
            .session_id = self.session_id,
            .fetch_id = fetch_id,
            .body_id = body_id,
            .shard_index = shard_index,
            .upload_bytes = 0,
            .stage = .admitting,
        });
        errdefer runtime.fetch_flow.end(self.gateway, handle, .silent);
        const identity = egress.core.FetchBodyIdentity{
            .request_id = request_id,
            .request_generation = request_generation,
            .fetch_id = fetch_id,
            .body_id = body_id,
        };
        const queue = try engine.allocator.create(ResponseQueue);
        queue.* = ResponseQueue.init(identity, self.gateway.policy.max_response_body_bytes);
        errdefer queue.release(engine.allocator);
        const task = try engine.allocator.create(Task);
        errdefer engine.allocator.destroy(task);
        queue.retain();
        errdefer queue.release(engine.allocator);
        task.* = try Task.init(
            engine.allocator,
            fetch_id,
            "https://origin.test/",
            "GET",
            "",
            &.{},
            0,
            queue,
        );
        // What the engine's submit stores, which every wake token of the task names.
        task.engine.ready_generation = handle;
        self.gateway.fetches.get(handle).?.stage = .{ .running = .{
            .task = task,
            .queue = queue,
            .run = engine.run,
        } };
        return .{ .handle = handle, .task = task, .queue = queue };
    }

    /// Settles `fetch`'s task with a response head of `status` and no headers, as the engine
    /// publishes a headers-first result.
    pub fn settleSuccess(self: *Harness, fetch: RunningFetch, status: u16) !void {
        try self.settleSuccessWithHeaders(fetch, status, &.{});
    }

    /// Settles `fetch`'s task with a response head of `status` carrying copies of `headers`.
    pub fn settleSuccessWithHeaders(
        self: *Harness,
        fetch: RunningFetch,
        status: u16,
        headers: []const http.Header,
    ) !void {
        _ = self;
        const task = fetch.task;
        task.mutex.lock();
        defer task.mutex.unlock();
        const url = try task.resultAllocator().dupe(u8, "https://origin.test/");
        const copies = try task.copyResponseHeaders(headers);
        task.result = .{ .success = .{
            .status = status,
            .url = url,
            .headers = copies,
        } };
        task.done = true;
    }

    /// Settles `fetch`'s task as canceled, with no result, as the engine settles a task it
    /// stopped.
    pub fn settleCanceled(self: *Harness, fetch: RunningFetch) void {
        _ = self;
        fetch.task.mutex.lock();
        defer fetch.task.mutex.unlock();
        fetch.task.done = true;
    }

    /// Sends a hello under `hello_key` whose image is the memfd `table_fd`, `table_bytes` long, as
    /// a server does, without draining it.
    pub fn sendHello(self: *Harness, table_fd: std.posix.fd_t, table_bytes: u32) !void {
        try control.sendHello(self.server_fd, &hello_key, table_fd, table_bytes);
    }

    /// Sends the hello a server sends for `policy_image.standard`, without draining it.
    pub fn sendStandardHello(self: *Harness) !void {
        const image = try policy_image.standard(std.testing.allocator);
        defer std.testing.allocator.free(image);
        try self.sendHelloImage(image);
    }

    /// Sends the hello a server sends for the policy image `image`, without draining it.
    pub fn sendHelloImage(self: *Harness, image: []const u8) !void {
        var memfd = try policy_image.memfdHolding(image, os.fd.memfd_readonly_seals);
        defer memfd.deinit();
        try self.sendHello(memfd.fd(), @intCast(image.len));
    }

    /// Has the gateway drain its control socket, which must keep it running.
    pub fn drainControl(self: *Harness) !void {
        try std.testing.expect(!try runtime.control_flow.drainControl(self.gateway));
    }

    /// Sends the attach of the gateway's half `fds` of a session under `request_id_value`, as a
    /// server does, and has the gateway drain the control socket.
    pub fn sendAttach(self: *Harness, request_id_value: u64, fds: ipc.egress_shared.RawFds) !void {
        try control.sendAttachWorker(self.server_fd, request_id_value, security_cell_id, fds);
        try self.drainControl();
    }

    /// Takes the next packet the gateway sent the server, which must be the ack of attach
    /// `request_id_value` with `status`, and returns the session it names (0 for a refusal).
    pub fn expectAttachAck(
        self: *Harness,
        request_id_value: u64,
        status: control.AttachAckStatus,
    ) !u64 {
        var scratch: [server_packet_bytes_max]u8 = undefined;
        var packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, self.server_fd, &scratch);
        defer packet.deinit();
        const ack = switch (try control.decodeGatewayToServerPacket(&packet)) {
            .attach_ack => |ack| ack,
            .session_removed => return error.TestUnexpectedControlPacket,
        };
        try std.testing.expectEqual(@intFromEnum(status), ack.status);
        try std.testing.expectEqual(request_id_value, ack.request_id);
        return ack.worker_session_id;
    }

    /// Sends the end of session `session_id`'s boot token, as the server's metrics pass does,
    /// and has the gateway drain the control socket.
    pub fn sendBootEnded(self: *Harness, session_id: u64) !void {
        try control.sendBootEnded(self.server_fd, session_id);
        try self.drainControl();
    }

    /// Takes the next packet the gateway sent the server, which must report the removal of
    /// session `session_id` for `cause`.
    pub fn expectSessionRemovedReport(
        self: *Harness,
        session_id: u64,
        cause: control.SessionRemovedCause,
    ) !void {
        var scratch: [server_packet_bytes_max]u8 = undefined;
        var packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, self.server_fd, &scratch);
        defer packet.deinit();
        switch (try control.decodeGatewayToServerPacket(&packet)) {
            .session_removed => |removed| {
                try std.testing.expectEqual(session_id, removed.session_id);
                try std.testing.expectEqual(cause, removed.cause);
            },
            .attach_ack => return error.TestUnexpectedControlPacket,
        }
    }

    /// Closes the server's end of the control socket, as a server that is gone does.
    pub fn closeServerEnd(self: *Harness) void {
        std.posix.close(self.server_fd);
        self.server_fd = -1;
    }

    /// Checks that no packet from the gateway waits on the server's end.
    pub fn expectNoServerPacket(self: *Harness) !void {
        var scratch: [server_packet_bytes_max]u8 = undefined;
        try std.testing.expectError(
            error.WouldBlock,
            ipc.recvPacketWithFdsScratch(std.testing.allocator, self.server_fd, &scratch),
        );
    }

    /// Fills the gateway's end of the control socket with one-byte packets the server has not
    /// read, so the gateway's next send finds it full, and returns how many it sent.
    pub fn fillControlSocket(self: *Harness) !usize {
        const byte = [_]u8{0};
        // A socket pair holds a few hundred one-byte packets.
        for (0..65_536) |sent| {
            _ = std.posix.send(self.gateway.control_fd, &byte, std.posix.MSG.NOSIGNAL) catch |err| switch (err) {
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
};

/// A fetch start whose body comes through the upload pool (the body-pooled flag set, no inline
/// bytes), for tests that call the upload assembler directly instead of through the wire codec,
/// so they also reach checks the codec makes unreachable. Admission has verified the token by
/// then, so the view carries none.
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

/// A session on a wake set of its own. The session holds its own copy of every wake descriptor,
/// so the set closes once the session is built.
pub fn createSession() !ipc.egress_shared.SessionFds {
    var wake_set = try ipc.egress_shared.WakeSet.create();
    defer wake_set.deinit();
    return ipc.egress_shared.createSessionForWorker(&wake_set);
}

/// Duplicates every descriptor of `fds`, so a mapping that takes the copies leaves `fds` open
/// for the session's other side.
pub fn dupEgressRawFds(fds: ipc.egress_shared.RawFds) !ipc.egress_shared.RawFds {
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

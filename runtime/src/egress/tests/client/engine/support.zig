//! Shared support of the engine tests (`egress-test`): starting an engine
//! with a wake callback that counts each task's wakes; a resolver the test
//! scripts and can hold; origins that keep a dial in one phase (a listener
//! whose full accept queue keeps a TCP connect in progress, an origin that
//! accepts and never answers, a relay that holds a TLS handshake partway
//! through the server's flight) or that must see no connection; a count of
//! the process's descriptors; a policy for test names that resolve to this
//! host; and helpers that read a task's result and its response queue the
//! way the gateway loop does.

const std = @import("std");
const egress_client = @import("collo_egress_client");
const local_address = @import("collo_test_net");
const network_policy = @import("../network_policy.zig");

const egress_engine = egress_client.engine;
const core = egress_client.core;
const network = egress_client.network;
const task_model = egress_client.task;
const ResponseQueue = core.ResponseQueue;

/// The engine's wake callback context. It counts every wake and, for up to
/// `tasks_max` distinct tasks, the `task_ready` wakes of each, so a test can
/// check that a fetch settled exactly once.
pub const WakeState = struct {
    mutex: std.Thread.Mutex = .{},
    count: usize = 0,
    tasks: [tasks_max]?*task_model.Task = @splat(null),
    task_wakes: [tasks_max]usize = @splat(0),
    /// A `task_ready` wake named a task past `tasks_max`.
    overflowed: bool = false,

    pub const tasks_max: usize = 256;

    fn note(self: *WakeState, event: egress_engine.WakeEvent) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.count += 1;
        const task = switch (event) {
            .generic => return,
            .task_ready => |ready| ready.task,
        };
        for (&self.tasks, &self.task_wakes) |*slot, *wakes| {
            if (slot.* == null)
                slot.* = task;
            if (slot.* == task) {
                wakes.* += 1;
                return;
            }
        }
        self.overflowed = true;
    }

    /// The `task_ready` wakes `task` received so far.
    pub fn taskReadyCount(self: *WakeState, task: *task_model.Task) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(!self.overflowed);
        for (self.tasks, self.task_wakes) |slot, wakes| {
            if (slot == task)
                return wakes;
        }
        return 0;
    }

    pub fn total(self: *WakeState) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.count;
    }
};

pub fn wakeEngineTest(ctx: ?*anyopaque, event: egress_engine.WakeEvent) void {
    const wake: *WakeState = @ptrCast(@alignCast(ctx orelse return));
    wake.note(event);
}

/// Starts the engine, or skips when the kernel offers no restricted
/// io_uring; any other failure fails the test.
pub fn startEngine(engine: *egress_engine.Engine, wake: *WakeState) !void {
    engine.start(wake, wakeEngineTest) catch |err| switch (err) {
        error.EgressIoUringUnsupported => return error.SkipZigTest,
        else => return err,
    };
}

/// The resolver a test puts in the engine's DNS cache
/// (`engine.dns_cache.config.resolver`) before it starts the engine. It
/// counts its calls; it answers the addresses `reset` named, each with the
/// port the test gave it rather than the one asked for, or fails with
/// `error.UnknownHostName` when `reset` named none; and when told to hold,
/// it stays inside the call until `releaseHeld`. The cache's resolver is a
/// bare function, so the state is global: one engine uses it at a time,
/// `reset` runs before that engine starts its resolver threads, and
/// spawning them orders the writes of `reset` before their reads.
pub const TestResolver = struct {
    var answer_buffer: [answer_max]std.net.Address = undefined;
    var answer_len: usize = 0;
    var hold = false;
    var calls: std.atomic.Value(usize) = .init(0);
    var release: std.Thread.ResetEvent = .{};

    pub const answer_max: usize = 4;

    /// The longest a held call waits for `releaseHeld`. It outlasts every
    /// wait of a test, and it lets the engine's deinit, which joins the
    /// resolver threads, end even when a test fails before it releases.
    const hold_ns_max: u64 = 10 * std.time.ns_per_s;

    pub const Script = struct {
        answer: []const std.net.Address = &.{},
        hold: bool = false,
    };

    pub fn reset(script: Script) void {
        std.debug.assert(script.answer.len <= answer_max);
        @memcpy(answer_buffer[0..script.answer.len], script.answer);
        answer_len = script.answer.len;
        hold = script.hold;
        calls.store(0, .release);
        release.reset();
    }

    pub fn resolve(allocator: std.mem.Allocator, host: []const u8, port: u16) egress_client.dns_cache.LookupResult {
        _ = host;
        _ = port;
        _ = calls.fetchAdd(1, .acq_rel);
        if (hold) {
            release.timedWait(hold_ns_max) catch return .{ .failure = error.DnsLookupFailed };
        }
        if (answer_len == 0)
            return .{ .failure = error.UnknownHostName };
        const addresses = allocator.dupe(std.net.Address, answer_buffer[0..answer_len]) catch |err|
            return .{ .failure = err };
        return .{ .success = addresses };
    }

    /// Lets every held call go on to its answer.
    pub fn releaseHeld() void {
        release.set();
    }

    /// The calls so far, held ones included.
    pub fn callCount() usize {
        return calls.load(.acquire);
    }

    /// Waits until `count` calls entered the resolver: with `hold`, until a
    /// resolver thread sits inside each of them.
    pub fn waitCalls(count: usize, timeout_ms: u64) !void {
        const start_instant = try std.time.Instant.now();
        while (calls.load(.acquire) < count) {
            const now = try std.time.Instant.now();
            if (now.since(start_instant) >= timeout_ms * std.time.ns_per_ms)
                return error.ResolverNeverCalled;
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }
};

const dial_test_suffix_rules = [_]network.Pattern{.{ .host = .{ .suffix = "dial.test" }, .port = 0 }};

const dial_test_grant: network.Grant = .{
    .allow_http = true,
    .allow_private_networks = true,
    .any = false,
    .names = &.{},
    .suffixes = &dial_test_suffix_rules,
    .ipv4 = &.{},
    .ipv6 = &.{},
};

/// Every name under `dial.test`, over HTTP on port 80 or HTTPS on port 443,
/// private addresses included: the grant of a fetch whose name the
/// `TestResolver` answers with this host's address and a test origin's
/// port. No real resolver ever sees these names.
pub const dial_test_names: network.Policy = .{ .grants = &.{&dial_test_grant} };

/// A listener whose accept queue is full: it never accepts, and filler
/// connections hold its queue, so a further TCP connect stays in progress
/// while the kernel drops its SYNs. The test that needs it skips on a host
/// whose TCP stack lacks that behavior and completes the connect anyway;
/// `runtime/tests/support/skip_allowlist.zon` names the capability for each
/// such test.
pub const FullListener = struct {
    server: std.net.Server,
    port: u16,
    fillers: [fillers_max]std.posix.fd_t = @splat(-1),

    const fillers_max: usize = 8;
    const connect = egress_client.transport.connect;

    pub fn start(host: []const u8) !FullListener {
        const bind_address = try std.net.Address.parseIp4(host, 0);
        var listener = FullListener{
            .server = try bind_address.listen(.{ .reuse_address = true, .kernel_backlog = 0 }),
            .port = undefined,
        };
        errdefer listener.stop();
        listener.port = listener.server.listen_address.getPort();
        const address = try std.net.Address.parseIp4(host, listener.port);
        for (&listener.fillers) |*filler| {
            const started = try connect.startAttempt(address);
            if (started.connected) {
                filler.* = started.fd;
                continue;
            }
            var poll_fds = [_]std.posix.pollfd{.{ .fd = started.fd, .events = std.posix.POLL.OUT, .revents = 0 }};
            if ((try std.posix.poll(&poll_fds, 200)) != 0) {
                filler.* = started.fd;
                continue;
            }
            // This connect is still in progress: the queue is full.
            std.posix.close(started.fd);
            return listener;
        }
        return error.SkipZigTest;
    }

    pub fn stop(self: *FullListener) void {
        for (&self.fillers) |*filler| {
            if (filler.* >= 0)
                std.posix.close(filler.*);
            filler.* = -1;
        }
        self.server.deinit();
    }
};

/// A listener nothing accepts from: a connection that reaches it waits in
/// its accept queue, where `hasPendingConnection` finds it.
pub const IdleListener = struct {
    server: std.net.Server,
    port: u16,

    pub fn start(host: []const u8) !IdleListener {
        const bind_address = try std.net.Address.parseIp4(host, 0);
        const server = try bind_address.listen(.{ .reuse_address = true });
        return .{ .server = server, .port = server.listen_address.getPort() };
    }

    /// Whether a connection completed its handshake with the listener. One
    /// that closed since still waits in the queue until accepted.
    pub fn hasPendingConnection(self: *const IdleListener) !bool {
        var poll_fds = [_]std.posix.pollfd{.{ .fd = self.server.stream.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        return (try std.posix.poll(&poll_fds, 0)) != 0;
    }

    pub fn stop(self: *IdleListener) void {
        self.server.deinit();
    }
};

/// Accepts and holds up to `capacity` connections without reading a request
/// or writing a response, so an HTTP/1 fetch against it parks until its own
/// stall deadline and a TLS dial stays in its handshake. `waitClientHello`
/// pins such a dial in its handshaking phase. `writeLate` writes to the held
/// sockets to model readiness that arrives after the engine dropped the
/// fetch.
pub const HeldOrigin = struct {
    server: std.net.Server,
    held: []?std.net.Stream,
    host_buffer: [64]u8,
    host_len: usize,
    port: u16,
    thread: std.Thread = undefined,
    held_len: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    accepted: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Backs `policy`, which points into it; the origin's heap address keeps
    /// it in place.
    origins: network_policy.Origins = .{},

    /// The content type of a TLS handshake record (RFC 8446), the first byte
    /// a TLS client sends.
    const tls_handshake_record: u8 = 22;

    pub fn start(allocator: std.mem.Allocator, capacity: usize) !*HeldOrigin {
        var host_buffer: [64]u8 = undefined;
        const host_text = try local_address.routableLocalIpv4(&host_buffer);
        const bind_address = try std.net.Address.parseIp4("0.0.0.0", 0);
        var server = try bind_address.listen(.{ .reuse_address = true });
        errdefer server.deinit();
        const held = try allocator.alloc(?std.net.Stream, capacity);
        errdefer allocator.free(held);
        @memset(held, null);
        const origin = try allocator.create(HeldOrigin);
        errdefer allocator.destroy(origin);
        origin.* = .{
            .server = server,
            .held = held,
            .host_buffer = host_buffer,
            .host_len = host_text.len,
            .port = server.listen_address.getPort(),
        };
        try origin.origins.init(origin.host(), &.{origin.port});
        origin.thread = try std.Thread.spawn(.{}, HeldOrigin.threadMain, .{origin});
        return origin;
    }

    pub fn host(self: *const HeldOrigin) []const u8 {
        return self.host_buffer[0..self.host_len];
    }

    /// Plain HTTP and HTTPS to this origin's address and port, and nowhere
    /// else. Valid until `stop`.
    pub fn policy(self: *const HeldOrigin) egress_client.network.Policy {
        return self.origins.policy();
    }

    pub fn url(self: *const HeldOrigin, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://{s}:{d}/held", .{ self.host(), self.port });
    }

    pub fn httpsUrl(self: *const HeldOrigin, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "https://{s}:{d}/held", .{ self.host(), self.port });
    }

    pub fn stop(self: *HeldOrigin, allocator: std.mem.Allocator) void {
        self.stopping.store(true, .release);
        if (std.net.Address.parseIp(self.host(), self.port)) |address| {
            if (std.net.tcpConnectToAddress(address)) |stream|
                stream.close()
            else |_| {}
        } else |_| {}
        self.thread.join();
        for (self.held[0..self.held_len.load(.acquire)]) |maybe_stream| {
            if (maybe_stream) |stream| stream.close();
        }
        self.server.deinit();
        allocator.free(self.held);
        allocator.destroy(self);
    }

    pub fn waitAccepted(self: *const HeldOrigin, count: usize, timeout_ms: u64) !void {
        const start_instant = try std.time.Instant.now();
        while (self.accepted.load(.acquire) < count) {
            const now = try std.time.Instant.now();
            if (now.since(start_instant) >= timeout_ms * std.time.ns_per_ms)
                return error.HeldOriginNeverAccepted;
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }

    /// Waits until the held connection `index` received the first bytes of a
    /// TLS ClientHello, and consumes what arrived. A dial sends its
    /// ClientHello only once its connect finished and its handshake began, so
    /// this pins the dial in its handshaking phase.
    pub fn waitClientHello(self: *HeldOrigin, index: usize, timeout_ms: u64) !void {
        const stream = try self.heldStream(index, timeout_ms);
        const start_instant = try std.time.Instant.now();
        var buffer: [4096]u8 = undefined;
        while (true) {
            var poll_fds = [_]std.posix.pollfd{.{ .fd = stream.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            if ((try std.posix.poll(&poll_fds, 10)) != 0) {
                const read = try std.posix.read(stream.handle, &buffer);
                if (read == 0)
                    return error.HeldConnectionClosedBeforeClientHello;
                if (buffer[0] != tls_handshake_record)
                    return error.HeldConnectionReceivedNoClientHello;
                return;
            }
            const now = try std.time.Instant.now();
            if (now.since(start_instant) >= timeout_ms * std.time.ns_per_ms)
                return error.HeldConnectionNeverReceivedClientHello;
        }
    }

    /// Reads the held connection `index` until the engine's end of it
    /// closes: whatever it sent (a ClientHello, a request head), then end
    /// of stream.
    pub fn waitPeerClosed(self: *HeldOrigin, index: usize, timeout_ms: u64) !void {
        const stream = try self.heldStream(index, timeout_ms);
        const start_instant = try std.time.Instant.now();
        var buffer: [4096]u8 = undefined;
        while (true) {
            var poll_fds = [_]std.posix.pollfd{.{ .fd = stream.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            if ((try std.posix.poll(&poll_fds, 10)) != 0) {
                const read = std.posix.read(stream.handle, &buffer) catch |err| switch (err) {
                    error.ConnectionResetByPeer => return,
                    else => return err,
                };
                if (read == 0)
                    return;
            }
            const now = try std.time.Instant.now();
            if (now.since(start_instant) >= timeout_ms * std.time.ns_per_ms)
                return error.HeldConnectionNeverClosed;
        }
    }

    /// Best-effort write on every held connection: readiness for sockets the
    /// engine no longer watches.
    pub fn writeLate(self: *HeldOrigin, bytes: []const u8) void {
        for (self.held[0..self.held_len.load(.acquire)]) |maybe_stream| {
            if (maybe_stream) |stream|
                _ = stream.write(bytes) catch {};
        }
    }

    /// The held connection `index`, once the origin accepted it. The origin
    /// thread stores it before it publishes `held_len`.
    fn heldStream(self: *const HeldOrigin, index: usize, timeout_ms: u64) !std.net.Stream {
        std.debug.assert(index < self.held.len);
        const start_instant = try std.time.Instant.now();
        while (self.held_len.load(.acquire) <= index) {
            const now = try std.time.Instant.now();
            if (now.since(start_instant) >= timeout_ms * std.time.ns_per_ms)
                return error.HeldOriginNeverAccepted;
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
        const stream = self.held[index] orelse return error.HeldConnectionMissing;
        return stream;
    }

    fn threadMain(self: *HeldOrigin) void {
        while (true) {
            const connection = self.server.accept() catch return;
            if (self.stopping.load(.acquire)) {
                connection.stream.close();
                return;
            }
            const held_len = self.held_len.load(.acquire);
            if (held_len < self.held.len) {
                self.held[held_len] = connection.stream;
                self.held_len.store(held_len + 1, .release);
            } else {
                connection.stream.close();
            }
            _ = self.accepted.fetchAdd(1, .acq_rel);
        }
    }
};

/// A TCP relay in front of a TLS origin that holds a handshake partway
/// through the server's flight. It hands the client the origin's bytes one
/// per write, `trickle_pause_ns` apart, and keeps the last byte it received
/// back until the test opens the gate, so the client steps its handshake on
/// every byte it gets and cannot finish it: the flight's last record stays
/// incomplete. Once the gate is open it relays the origin's bytes as they
/// come. The client's bytes always pass at once. It serves one connection.
pub const TrickleProxy = struct {
    server: std.net.Server,
    upstream: std.net.Address,
    port: u16,
    thread: std.Thread = undefined,
    /// Origin bytes handed to the client so far.
    relayed: std.atomic.Value(usize) = .init(0),
    gate_open: std.atomic.Value(bool) = .init(false),
    stopping: std.atomic.Value(bool) = .init(false),

    /// The origin bytes the relay holds at most: far more than a handshake
    /// flight. The relay stops reading the origin while the buffer is full.
    const held_bytes_max: usize = 64 * 1024;
    const client_chunk_bytes: usize = 16 * 1024;
    const trickle_pause_ns: u64 = 1 * std.time.ns_per_ms;
    /// How long one relay round waits for either side.
    const poll_step_ms: i32 = 1;
    /// Each idle round takes `poll_step_ms`, and a test's connection carries
    /// one handshake and a few frames, so a relay past this many rounds
    /// outlived its test and gives up.
    const relay_rounds_max: usize = 200_000;

    /// Listens on `host` and relays to `upstream_port` on `host`.
    pub fn start(allocator: std.mem.Allocator, host: []const u8, upstream_port: u16) !*TrickleProxy {
        const upstream = try std.net.Address.parseIp4(host, upstream_port);
        const bind_address = try std.net.Address.parseIp4(host, 0);
        var server = try bind_address.listen(.{ .reuse_address = true });
        errdefer server.deinit();
        const proxy = try allocator.create(TrickleProxy);
        errdefer allocator.destroy(proxy);
        proxy.* = .{
            .server = server,
            .upstream = upstream,
            .port = server.listen_address.getPort(),
        };
        proxy.thread = try std.Thread.spawn(.{}, TrickleProxy.threadMain, .{proxy});
        return proxy;
    }

    /// From now on the relay hands over every origin byte as it comes,
    /// including the one it held back.
    pub fn openGate(self: *TrickleProxy) void {
        self.gate_open.store(true, .release);
    }

    pub fn waitRelayed(self: *const TrickleProxy, count: usize, timeout_ms: u64) !void {
        const start_instant = try std.time.Instant.now();
        while (self.relayed.load(.acquire) < count) {
            const now = try std.time.Instant.now();
            if (now.since(start_instant) >= timeout_ms * std.time.ns_per_ms)
                return error.TrickleNeverRelayed;
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }

    /// Joins the relay thread, which ends once its client or origin closes,
    /// and otherwise within a round of this call.
    pub fn stop(self: *TrickleProxy, allocator: std.mem.Allocator) void {
        self.stopping.store(true, .release);
        // A connection of its own wakes an accept the thread may block in.
        if (std.net.tcpConnectToAddress(self.server.listen_address)) |stream|
            stream.close()
        else |_| {}
        self.thread.join();
        self.server.deinit();
        allocator.destroy(self);
    }

    fn threadMain(self: *TrickleProxy) void {
        const connection = self.server.accept() catch return;
        defer connection.stream.close();
        if (self.stopping.load(.acquire))
            return;
        const upstream = std.net.tcpConnectToAddress(self.upstream) catch return;
        defer upstream.close();
        self.relay(connection.stream, upstream);
    }

    fn relay(self: *TrickleProxy, client: std.net.Stream, upstream: std.net.Stream) void {
        // Origin bytes received and not yet handed to the client.
        var held: [held_bytes_max]u8 = undefined;
        var held_start: usize = 0;
        var held_end: usize = 0;
        var client_bytes: [client_chunk_bytes]u8 = undefined;
        for (0..relay_rounds_max) |_| {
            if (self.stopping.load(.acquire))
                return;
            if (self.gate_open.load(.acquire)) {
                if (held_end > held_start) {
                    client.writeAll(held[held_start..held_end]) catch return;
                    _ = self.relayed.fetchAdd(held_end - held_start, .acq_rel);
                    held_start = held_end;
                }
            } else if (held_end - held_start > 1) {
                // One byte per write, and never the last one received.
                client.writeAll(held[held_start..][0..1]) catch return;
                held_start += 1;
                _ = self.relayed.fetchAdd(1, .acq_rel);
                std.Thread.sleep(trickle_pause_ns);
            }
            if (held_start == held_end) {
                held_start = 0;
                held_end = 0;
            }
            var poll_fds = [_]std.posix.pollfd{
                .{ .fd = client.handle, .events = std.posix.POLL.IN, .revents = 0 },
                // Poll ignores a negative descriptor.
                .{ .fd = if (held_end < held.len) upstream.handle else -1, .events = std.posix.POLL.IN, .revents = 0 },
            };
            _ = std.posix.poll(&poll_fds, poll_step_ms) catch return;
            if (poll_fds[0].revents != 0) {
                const count = client.read(&client_bytes) catch return;
                if (count == 0)
                    return;
                upstream.writeAll(client_bytes[0..count]) catch return;
            }
            if (poll_fds[1].revents != 0) {
                const count = upstream.read(held[held_end..]) catch return;
                if (count == 0)
                    return;
                held_end += count;
            }
        }
    }
};

/// The most descriptors `openDescriptorCount` counts, far past what a test
/// process holds; a longer listing is an error, not a count.
const descriptors_counted_max: usize = 1 << 16;

/// The descriptors this process holds, listed from `/proc/self/fd`, so a
/// test sees a socket the engine opens or closes. The listing includes the
/// descriptor that reads it, the same in every call. A count compares with
/// another only while no thread but the engine's owner opens or closes
/// descriptors in between: no origin thread accepting, no resolver thread
/// in a real lookup.
pub fn openDescriptorCount() !usize {
    var dir = try std.fs.openDirAbsolute("/proc/self/fd", .{ .iterate = true });
    defer dir.close();
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next()) |_| {
        count += 1;
        if (count > descriptors_counted_max)
            return error.TooManyDescriptorsToCount;
    }
    return count;
}

/// Waits until the process holds exactly `expected` descriptors, as
/// `openDescriptorCount` counts them.
pub fn waitDescriptorCount(expected: usize, timeout_ms: u64) !void {
    const start_instant = try std.time.Instant.now();
    while (true) {
        const count = try openDescriptorCount();
        if (count == expected)
            return;
        const now = try std.time.Instant.now();
        if (now.since(start_instant) >= timeout_ms * std.time.ns_per_ms) {
            std.debug.print("open descriptors: {d}, expected {d}\n", .{ count, expected });
            return error.DescriptorCountNeverReached;
        }
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
}

/// Waits until a queue is complete, with every chunk appended, so the
/// teardown credit release sees the full queue.
pub fn waitBodyComplete(queue: *ResponseQueue, timeout_ms: u64) !void {
    const start = try std.time.Instant.now();
    while (queueState(queue) != .complete) {
        try std.testing.expect(queueState(queue) != .failed);
        std.Thread.sleep(1 * std.time.ns_per_ms);
        const now = try std.time.Instant.now();
        if (now.since(start) >= timeout_ms * std.time.ns_per_ms)
            return error.BodyDidNotComplete;
    }
}

/// Pulls a response body into `buffer` the way the gateway loop does,
/// returning each chunk's credit to the engine, which surfaces an HTTP/2
/// stream's deferred end.
pub fn readBody(engine: *egress_engine.Engine, queue: *ResponseQueue, buffer: []u8, timeout_ms: u64) ![]const u8 {
    var len: usize = 0;
    const start = try std.time.Instant.now();
    while (true) {
        _ = queue.armPull();
        const pulled = queue.pull(std.testing.allocator);
        if (pulled.bytes) |bytes| {
            defer std.testing.allocator.free(bytes);
            if (bytes.len > buffer.len - len)
                return error.BodyTooLargeForTest;
            @memcpy(buffer[len..][0..bytes.len], bytes);
            len += bytes.len;
        }
        engine.releaseFetchBodyCredit(pulled.credit);
        if (pulled.done)
            return buffer[0..len];
        if (pulled.failed)
            return error.BodyFailed;
        if (pulled.isEmpty())
            std.Thread.sleep(1 * std.time.ns_per_ms);
        const now = try std.time.Instant.now();
        if (now.since(start) >= timeout_ms * std.time.ns_per_ms)
            return error.BodyDidNotComplete;
    }
}

/// A fetch that fails other than by a network denial publishes
/// "fetch failed: <ErrorName>"; this matches the error name at the end of
/// the message.
pub fn expectTaskFailureMessage(task: *task_model.Task, expected_error_name: []const u8) !void {
    task.mutex.lock();
    defer task.mutex.unlock();
    const result = task.result orelse return error.MissingFetchResult;
    switch (result) {
        .success => return error.UnexpectedFetchSuccess,
        .failure => |failure| {
            if (!std.mem.endsWith(u8, failure.message, expected_error_name)) {
                std.debug.print("unexpected failure message: {s}\n", .{failure.message});
                return error.UnexpectedFailureMessage;
            }
        },
    }
}

/// The fetch failed because its network policy refused the hop to `origin`
/// for `denial`: a network-denied failure with the text
/// `collo_network.writeDenial` writes, which names the refused hop.
pub fn expectTaskDenied(task: *task_model.Task, origin: network.Origin, denial: network.Denial) !void {
    var expected_buffer: [network.grant.denial_bytes_max]u8 = undefined;
    var expected: std.Io.Writer = .fixed(&expected_buffer);
    try network.writeDenial(&expected, origin, denial);
    task.mutex.lock();
    defer task.mutex.unlock();
    const result = task.result orelse return error.MissingFetchResult;
    switch (result) {
        .success => return error.UnexpectedFetchSuccess,
        .failure => |failure| {
            try std.testing.expectEqual(task_model.FailureCause.network_denied, failure.cause);
            try std.testing.expectEqualStrings(expected.buffered(), failure.message);
        },
    }
}

/// The fetch's published head came at the end of a redirect and names
/// `url`, the last hop's.
pub fn expectTaskRedirectedTo(task: *task_model.Task, url: []const u8) !void {
    task.mutex.lock();
    defer task.mutex.unlock();
    const result = task.result orelse return error.MissingFetchResult;
    switch (result) {
        .success => |success| {
            try std.testing.expect(success.redirected);
            try std.testing.expectEqualStrings(url, success.url);
        },
        .failure => |failure| {
            std.debug.print("unexpected fetch failure: {s}\n", .{failure.message});
            return error.UnexpectedFetchFailure;
        },
    }
}

/// A canceled fetch is done with no result, and the engine woke the gateway
/// for it exactly once. Call it after a point that proves the engine is done
/// with the fetch, such as `Engine.stop`, which returns only once the owner
/// settled everything; a second settlement before that point would have
/// woken the gateway again or published a result.
pub fn expectSettledOnceCanceled(wake: *WakeState, task: *task_model.Task) !void {
    {
        task.mutex.lock();
        defer task.mutex.unlock();
        try std.testing.expect(task.done);
        try std.testing.expect(task.result == null);
    }
    try std.testing.expectEqual(@as(usize, 1), wake.taskReadyCount(task));
}

const EngineCreditRelease = struct {
    engine: *egress_engine.Engine,
    count: usize = 0,
};

fn releaseCreditToEngine(context: *EngineCreditRelease, credit: core.body_credit.Handle) void {
    context.engine.releaseFetchBodyCredit(credit);
    context.count += 1;
}

/// Returns every credit `task`'s queue holds to the engine and frees the
/// queued chunks; returns how many credits went back. At a test's teardown it
/// runs after `Engine.stop`, deferred after the releases so it runs before
/// them: a credit a running engine took could resume a body that then appends
/// after its queue was emptied, and the queue's deinit would abort the whole
/// test binary instead of failing the test. After `stop` a release is a no-op.
pub fn releaseTaskBodyCredits(engine: *egress_engine.Engine, task: *task_model.Task) usize {
    var release_context = EngineCreditRelease{ .engine = engine };
    task.response_body.releaseQueued(std.testing.allocator, &release_context, releaseCreditToEngine);
    return release_context.count;
}

pub fn initEngineFetchTask(
    allocator: std.mem.Allocator,
    id: u64,
    url: []const u8,
    body_id: u64,
) !task_model.Task {
    return initEngineFetchTaskShaped(allocator, id, url, body_id, "GET", "", 1024);
}

pub fn initEngineFetchTaskShaped(
    allocator: std.mem.Allocator,
    id: u64,
    url: []const u8,
    body_id: u64,
    method: []const u8,
    request_body: []const u8,
    max_body_bytes: u64,
) !task_model.Task {
    const identity = core.FetchBodyIdentity{
        .request_id = 100 + id,
        .request_generation = 200 + id,
        .fetch_id = id,
        .body_id = body_id,
    };
    const queue = try allocator.create(ResponseQueue);
    queue.* = ResponseQueue.init(identity, max_body_bytes);
    // On success the task takes the queue's reference.
    errdefer queue.release(allocator);
    return task_model.Task.init(allocator, id, url, method, request_body, &.{}, 0, queue);
}

pub fn taskDone(task: *task_model.Task) bool {
    task.mutex.lock();
    defer task.mutex.unlock();
    return task.done;
}

pub fn waitTaskDone(task: *task_model.Task, timeout_ms: u64) !void {
    const start = try std.time.Instant.now();
    while (!taskDone(task)) {
        const now = try std.time.Instant.now();
        if (now.since(start) >= timeout_ms * std.time.ns_per_ms)
            return error.TaskDidNotComplete;
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
}

pub fn expectTaskStatus(task: *task_model.Task, expected: u16) !void {
    task.mutex.lock();
    defer task.mutex.unlock();
    const result = task.result orelse return error.MissingFetchResult;
    switch (result) {
        .success => |success| try std.testing.expectEqual(expected, success.status),
        .failure => |failure| {
            std.debug.print("unexpected fetch failure: {s}\n", .{failure.message});
            return error.UnexpectedFetchFailure;
        },
    }
}

pub fn queueState(queue: *ResponseQueue) core.response_queue.State {
    queue.mutex.lock();
    defer queue.mutex.unlock();
    return queue.state;
}

/// Waits until `condition(context)` holds, polling every millisecond.
pub fn waitUntil(context: anytype, comptime condition: fn (@TypeOf(context)) bool, timeout_ms: u64) !void {
    const start = try std.time.Instant.now();
    while (!condition(context)) {
        const now = try std.time.Instant.now();
        if (now.since(start) >= timeout_ms * std.time.ns_per_ms)
            return error.ConditionNeverHeld;
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
}

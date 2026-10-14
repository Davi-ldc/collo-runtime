//! Measures HTTP/1 egress through one egress engine, the engine a gateway
//! shard runs, against a plain-HTTP origin on a thread of this process. Every
//! sample starts a fresh engine and origin and runs a closed loop of GETs
//! over a fixed number of slots, where each slot submits its next fetch once
//! the body of its previous one ended. The origin serves one scenario per
//! sample: a closed connection per request, keep-alive, or keep-alive with a
//! gzip body, which the engine decodes before the bytes reach the response
//! queue. Like every egress bench it builds ReleaseFast without JSC.
//!
//! The bench consumes each fetch the way the gateway's loop does: it arms
//! the task's response queue before it sleeps, pulls one chunk per pull,
//! returns every chunk's credit to the engine, and sleeps on an eventfd that
//! the engine's wake callback writes. A sample fails unless every decoded
//! body equals `expected_body` byte for byte and the connections the origin
//! accepted prove reuse: one per request when the origin closes, and under
//! keep-alive at most one per slot, since each fetch leases a connection the
//! engine's HTTP/1 pool kept.
//!
//! COLLO_BENCH_EGRESS_HTTP1_ITERATIONS sets the samples per scenario,
//! COLLO_BENCH_EGRESS_HTTP1_REQUESTS the fetches per sample and
//! COLLO_BENCH_EGRESS_HTTP1_INFLIGHT the slots.

const std = @import("std");
const bench_common = @import("common.zig");
const bench_metadata = @import("metadata.zig");
const local_origin = @import("local_origin.zig");
const proc_memory = @import("proc_memory.zig");
const egress = @import("collo_egress_client");

const Engine = egress.engine.Engine;
const ResponseQueue = egress.core.ResponseQueue;
const Task = egress.task.Task;

const bench_name = "egress_http1";
const default_iterations: usize = 5;
const default_requests: usize = 32;
const default_inflight: usize = 1;

/// Connections the origin serves at once, which bounds the slots.
const origin_connections_max: usize = 64;
/// How long a sample may go without progress before it fails.
const stall_timeout_ns: u64 = 30 * std.time.ns_per_s;
/// Chunks one `Consumer.advance` pulls before the other fetches get a turn.
const pulls_per_advance_max: usize = 64;

/// The decoded body of every response.
const expected_body = "hello world";
/// `expected_body` compressed with gzip: the body the gzip scenario sends.
const gzip_body = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x03, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57,
    0x28, 0xcf, 0x2f, 0xca, 0x49, 0x01, 0x00, 0x85,
    0x11, 0x4a, 0x0d, 0x0b, 0x00, 0x00, 0x00,
};

const Scenario = enum {
    close,
    keep_alive,
    gzip_keep_alive,

    fn keepAlive(self: Scenario) bool {
        return self != .close;
    }

    fn gzip(self: Scenario) bool {
        return self == .gzip_keep_alive;
    }
};

const scenarios = [_]Scenario{ .close, .keep_alive, .gzip_keep_alive };

const Options = struct {
    iterations: usize,
    requests: usize,
    /// Slots of the closed loop, at most `requests`.
    inflight: usize,
};

const Sample = struct {
    elapsed_ns: u64,
    requests_per_second: f64,
    /// Over the sample's fetches: from submit to the end of the body.
    latency_p50_ns: u64,
    latency_p99_ns: u64,
    /// Over the sample's fetches: from submit to the published head.
    ttfb_p50_ns: u64,
    ttfb_p99_ns: u64,
    accepted_connections: u64,
    /// The process with the sample's engine still running.
    memory: proc_memory.Metrics,
};

pub fn main() !void {
    // The engine's owner thread allocates while the bench thread does, and
    // smp_allocator keeps a freelist per thread, so no allocator lock adds
    // contention the gateway does not have.
    const allocator = std.heap.smp_allocator;
    try bench_metadata.print(allocator, bench_name);
    const iterations = try envUsize(allocator, "COLLO_BENCH_EGRESS_HTTP1_ITERATIONS", default_iterations);
    const requests = try envUsize(allocator, "COLLO_BENCH_EGRESS_HTTP1_REQUESTS", default_requests);
    const inflight = try envUsize(allocator, "COLLO_BENCH_EGRESS_HTTP1_INFLIGHT", default_inflight);
    if (iterations == 0 or requests == 0 or inflight == 0) {
        std.debug.print("{s}: iterations, requests and inflight must be nonzero\n", .{bench_name});
        return error.InvalidBenchConfig;
    }
    if (inflight > origin_connections_max) {
        std.debug.print(
            "{s}: inflight={d} exceeds the origin's {d} connections\n",
            .{ bench_name, inflight, origin_connections_max },
        );
        return error.InvalidBenchConfig;
    }
    const options: Options = .{
        .iterations = iterations,
        .requests = requests,
        .inflight = @min(inflight, requests),
    };
    const local = try LocalAddress.init();
    for (scenarios) |scenario|
        try runScenario(allocator, scenario, options, &local);
}

fn runScenario(
    allocator: std.mem.Allocator,
    scenario: Scenario,
    options: Options,
    local: *const LocalAddress,
) !void {
    const samples = try allocator.alloc(Sample, options.iterations);
    defer allocator.free(samples);
    for (samples, 1..) |*sample, iteration| {
        sample.* = try runSample(allocator, scenario, options, local);
        printJsonSample(scenario, options, iteration, sample.*);
    }
    try printSummary(allocator, scenario, options, samples);
}

fn runSample(
    allocator: std.mem.Allocator,
    scenario: Scenario,
    options: Options,
    local: *const LocalAddress,
) !Sample {
    var origin: Origin = undefined;
    try origin.start(scenario);
    defer origin.stop();

    var url_buffer: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "http://{s}:{d}/bench", .{ local.host(), origin.port });
    // The engine stops before this returns, so the grant outlives every hop
    // that reads it.
    var grant: local_origin.LocalGrant = undefined;
    try grant.init(local.bytes, &.{origin.port});
    const request: Request = .{
        .url = url,
        .method = "GET",
        .config = .{
            .network = grant.policy(),
            .max_response_body_bytes = 64 * 1024,
            // The pool keeps every slot's connection between its fetches and
            // retires none by request count within a sample, so the origin's
            // accept count reflects reuse alone.
            .http1_pool_max_entries = options.inflight,
            .http1_pool_max_requests_per_connection = options.requests,
        },
        .expected_body = expected_body,
    };

    const latencies_ns = try allocator.alloc(u64, options.requests);
    defer allocator.free(latencies_ns);
    const ttfbs_ns = try allocator.alloc(u64, options.requests);
    defer allocator.free(ttfbs_ns);
    const slots = try allocator.alloc(?Fetch, options.inflight);
    defer allocator.free(slots);
    @memset(slots, null);

    var consumer: Consumer = undefined;
    // One fetch per slot at a time.
    try consumer.init(allocator, options.inflight);
    defer consumer.deinit();
    defer {
        consumer.stop();
        for (slots) |*slot| {
            if (slot.*) |*fetch|
                consumer.discard(fetch);
        }
    }

    var timer = try std.time.Timer.start();
    var submitted: usize = 0;
    for (slots) |*slot| {
        slot.* = try consumer.createFetch(request);
        submitted += 1;
        try consumer.submit(&slot.*.?, &timer);
    }

    var completed: usize = 0;
    var deadline_ns = try bench_common.deadlineFromNowNs(stall_timeout_ns);
    while (completed < options.requests) {
        var progressed = false;
        for (slots) |*slot| {
            const fetch = if (slot.*) |*held| held else continue;
            switch (try consumer.advance(fetch, &timer)) {
                .idle => continue,
                .progressed => {},
                .finished => {
                    latencies_ns[completed] = fetch.end_ns - fetch.submit_ns;
                    ttfbs_ns[completed] = fetch.head_ns.? - fetch.submit_ns;
                    completed += 1;
                    consumer.discard(fetch);
                    slot.* = null;
                    if (submitted < options.requests) {
                        slot.* = try consumer.createFetch(request);
                        submitted += 1;
                        try consumer.submit(&slot.*.?, &timer);
                    }
                },
            }
            progressed = true;
        }
        if (progressed) {
            deadline_ns = try bench_common.deadlineFromNowNs(stall_timeout_ns);
        } else {
            consumer.wait(deadline_ns) catch |err| {
                std.debug.print(
                    "{s}: {s} stalled at {d}/{d} fetches\n",
                    .{ bench_name, @tagName(scenario), completed, options.requests },
                );
                return err;
            };
        }
    }
    const elapsed_ns = timer.read();

    const accepted = origin.accepted.load(.acquire);
    try checkReuse(scenario, options, accepted);
    std.mem.sort(u64, latencies_ns, {}, std.sort.asc(u64));
    std.mem.sort(u64, ttfbs_ns, {}, std.sort.asc(u64));
    const elapsed_s = @as(f64, @floatFromInt(@max(elapsed_ns, 1))) / @as(f64, std.time.ns_per_s);
    return .{
        .elapsed_ns = elapsed_ns,
        .requests_per_second = @as(f64, @floatFromInt(options.requests)) / elapsed_s,
        .latency_p50_ns = bench_common.percentileNearestRank(u64, latencies_ns, 50),
        .latency_p99_ns = bench_common.percentileNearestRank(u64, latencies_ns, 99),
        .ttfb_p50_ns = bench_common.percentileNearestRank(u64, ttfbs_ns, 50),
        .ttfb_p99_ns = bench_common.percentileNearestRank(u64, ttfbs_ns, 99),
        .accepted_connections = accepted,
        .memory = try proc_memory.readProcess(allocator, @intCast(std.os.linux.getpid())),
    };
}

/// The origin's accepted connections must match the scenario. A close
/// response forbids reuse, so every request dials. Under keep-alive the pool
/// keeps every connection between fetches, so the engine never holds more
/// connections than fetches in flight, one per slot; it holds fewer when a
/// fetch ends before another slot's first fetch starts, which then leases the
/// idle connection.
fn checkReuse(scenario: Scenario, options: Options, accepted: u64) !void {
    switch (scenario) {
        .close => {
            if (accepted == options.requests)
                return;
        },
        .keep_alive, .gzip_keep_alive => {
            if (accepted != 0) {
                if (accepted <= options.inflight)
                    return;
            }
        },
    }
    std.debug.print(
        "{s}: {s} accepted {d} connections for {d} requests over {d} slots\n",
        .{ bench_name, @tagName(scenario), accepted, options.requests, options.inflight },
    );
    return error.EgressHttp1BenchReuseMismatch;
}

/// The address the bench dials its origins at, which listen on every
/// address: the default route's source address, since every grant refuses
/// loopback (`local_origin.zig`).
const LocalAddress = struct {
    bytes: [4]u8,
    host_buffer: [15]u8,
    host_len: usize,

    fn init() !LocalAddress {
        var self: LocalAddress = .{
            .bytes = try local_origin.routableLocalIpv4(),
            .host_buffer = undefined,
            .host_len = 0,
        };
        self.host_len = local_origin.formatIpv4(self.bytes, &self.host_buffer).len;
        return self;
    }

    fn host(self: *const LocalAddress) []const u8 {
        return self.host_buffer[0..self.host_len];
    }
};

/// What a fetch asks for.
const Request = struct {
    url: []const u8,
    method: []const u8,
    body: []const u8 = "",
    config: egress.Config,
    /// The decoded body the fetch must deliver byte for byte; null counts
    /// its bytes only.
    expected_body: ?[]const u8 = null,
};

/// One fetch as its consumer tracks it. It holds a reference to its task,
/// and through the task to the task's response queue, until
/// `Consumer.discard`.
const Fetch = struct {
    task: *Task,
    config: egress.Config,
    expected_body: ?[]const u8,
    /// Readings of the sample's timer.
    submit_ns: u64 = 0,
    head_ns: ?u64 = null,
    end_ns: u64 = 0,
    body_bytes: usize = 0,
};

const Progress = enum {
    /// Nothing new; the fetch's queue is armed, so the engine wakes the
    /// consumer on its next chunk or end.
    idle,
    /// The head or a chunk arrived; the body has not ended.
    progressed,
    /// The body ended and was checked.
    finished,
};

/// One engine and the bench thread's consumer of its fetches. The engine's
/// wake callback writes `wake_fd`, an eventfd the consumer sleeps on between
/// passes over its fetches. Initialize it in place: the engine keeps a
/// pointer to it as its wake context.
const Consumer = struct {
    allocator: std.mem.Allocator,
    engine: Engine,
    wake_fd: std.posix.fd_t,
    next_task_id: u64,

    /// Starts an engine that runs up to `fetches_max` fetches at once, the
    /// most a sample has in flight.
    fn init(self: *Consumer, allocator: std.mem.Allocator, fetches_max: usize) !void {
        const wake_fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
        errdefer std.posix.close(wake_fd);
        self.* = .{
            .allocator = allocator,
            .engine = try Engine.init(allocator, fetches_max),
            .wake_fd = wake_fd,
            .next_task_id = 0,
        };
        errdefer self.engine.deinit();
        try self.engine.start(self, wakeFromEngine);
    }

    /// Frees the engine, after `stop` and after every fetch was discarded.
    fn deinit(self: *Consumer) void {
        self.engine.deinit();
        std.posix.close(self.wake_fd);
        self.* = undefined;
    }

    /// Ends the engine's run, which settles every fetch the engine still
    /// holds, so no chunk reaches a response queue afterwards.
    fn stop(self: *Consumer) void {
        self.engine.stop();
    }

    /// A fetch of `request` whose task holds a response queue of its own.
    /// The fetch holds the task's only reference until it is submitted.
    fn createFetch(self: *Consumer, request: Request) !Fetch {
        const allocator = self.allocator;
        self.next_task_id += 1;
        const id = self.next_task_id;
        const identity: egress.core.FetchBodyIdentity = .{
            .request_id = id,
            .request_generation = 1,
            .fetch_id = id,
            .body_id = id,
        };
        const queue = try allocator.create(ResponseQueue);
        queue.* = ResponseQueue.init(identity, null);
        const task = allocator.create(Task) catch |err| {
            queue.release(allocator);
            return err;
        };
        // On success the task takes over the queue's only reference.
        task.* = Task.init(
            allocator,
            id,
            request.url,
            request.method,
            request.body,
            &.{},
            0,
            queue,
        ) catch |err| {
            allocator.destroy(task);
            queue.release(allocator);
            return err;
        };
        return .{ .task = task, .config = request.config, .expected_body = request.expected_body };
    }

    /// Submits `fetch`'s task, stamping it with `timer`'s reading. On error
    /// the fetch stays unsubmitted and still holds its task.
    fn submit(self: *Consumer, fetch: *Fetch, timer: *std.time.Timer) !void {
        fetch.submit_ns = timer.read();
        try self.engine.submit(.{ .task = fetch.task, .config = fetch.config });
    }

    /// Takes what `fetch`'s task and response queue hold now: the head once
    /// the task settled, then body chunks, each checked against
    /// `fetch.expected_body` before its credit goes back to the engine. Fails
    /// when the fetch or its body failed, its status is not 200, or its body
    /// differs from the one expected.
    fn advance(self: *Consumer, fetch: *Fetch, timer: *std.time.Timer) !Progress {
        var progress: Progress = .idle;
        if (fetch.head_ns == null) {
            switch (settledHead(fetch.task)) {
                .pending => return .idle,
                .failed => |message| {
                    std.debug.print(
                        "{s}: fetch of {s} failed: {s}\n",
                        .{ bench_name, fetch.task.url, message },
                    );
                    return error.BenchFetchFailed;
                },
                .status => |status| {
                    if (status != 200) {
                        std.debug.print(
                            "{s}: fetch of {s} answered {d}\n",
                            .{ bench_name, fetch.task.url, status },
                        );
                        return error.BenchUnexpectedStatus;
                    }
                    fetch.head_ns = timer.read();
                    progress = .progressed;
                },
            }
        }
        const queue = fetch.task.response_body;
        var pulls: usize = 0;
        while (pulls < pulls_per_advance_max) : (pulls += 1) {
            if (!queue.armPull())
                return progress;
            const pulled = queue.pull(self.allocator);
            self.engine.releaseFetchBodyCredit(pulled.credit);
            if (pulled.bytes) |bytes| {
                defer self.allocator.free(bytes);
                try takeBody(fetch, bytes);
            }
            if (pulled.failed) {
                const message = queue.failureMessage() orelse "no message";
                std.debug.print("{s}: body of {s} failed: {s}\n", .{ bench_name, fetch.task.url, message });
                return error.BenchBodyFailed;
            }
            if (pulled.done) {
                fetch.end_ns = timer.read();
                try finishBody(fetch);
                return .finished;
            }
            progress = .progressed;
        }
        return .progressed;
    }

    /// Returns the credits of the chunks still queued for `fetch` and drops
    /// its task reference. Valid for a fetch never submitted, one whose body
    /// ended, and any fetch once the engine stopped, so no chunk can reach
    /// the queue afterwards. A stopped engine drops the credits, since it
    /// holds no stream they could open.
    fn discard(self: *Consumer, fetch: *Fetch) void {
        fetch.task.response_body.releaseQueued(self.allocator, &self.engine, Engine.releaseFetchBodyCredit);
        fetch.task.release();
        fetch.* = undefined;
    }

    /// Sleeps until the engine wakes the consumer. Fails with
    /// `error.BenchResponseTimeout` once CLOCK_MONOTONIC passes
    /// `deadline_ns`.
    fn wait(self: *Consumer, deadline_ns: u64) !void {
        const max_poll_ms = stall_timeout_ns / std.time.ns_per_ms;
        try bench_common.waitReadableBeforeDeadline(self.wake_fd, deadline_ns, max_poll_ms);
        var wakes: u64 = 0;
        _ = std.posix.read(self.wake_fd, std.mem.asBytes(&wakes)) catch |err| switch (err) {
            // Nothing to drain; the next pass finds no progress and waits
            // again.
            error.WouldBlock => {},
            else => return err,
        };
    }
};

/// The engine's wake callback, on its owner thread. Every wake means the
/// same to the consumer, which scans all its fetches after each.
fn wakeFromEngine(context: ?*anyopaque, event: egress.engine.WakeEvent) void {
    _ = event;
    const consumer: *Consumer = @ptrCast(@alignCast(context.?));
    const one: u64 = 1;
    _ = std.posix.write(consumer.wake_fd, std.mem.asBytes(&one)) catch |err| switch (err) {
        // A saturated eventfd already holds a wake.
        error.WouldBlock => {},
        // The consumer's stall deadline then fails the sample.
        else => std.debug.print("{s}: engine wake failed: {s}\n", .{ bench_name, @errorName(err) }),
    };
}

const Head = union(enum) {
    pending,
    status: u16,
    /// In the task's result arena, or static.
    failed: []const u8,
};

fn settledHead(task: *Task) Head {
    task.mutex.lock();
    defer task.mutex.unlock();
    if (!task.done)
        return .pending;
    const result = task.result orelse return .{ .failed = "task settled without a result" };
    return switch (result) {
        .success => |success| .{ .status = success.status },
        .failure => |failure| .{ .failed = failure.message },
    };
}

/// Counts `bytes` into `fetch`'s body after checking them against the
/// expected body at that offset.
fn takeBody(fetch: *Fetch, bytes: []const u8) !void {
    if (fetch.expected_body) |expected| {
        const end = fetch.body_bytes + bytes.len;
        if (end > expected.len)
            return error.BenchUnexpectedBody;
        if (!std.mem.eql(u8, expected[fetch.body_bytes..end], bytes))
            return error.BenchUnexpectedBody;
    }
    fetch.body_bytes += bytes.len;
}

fn finishBody(fetch: *const Fetch) !void {
    const expected = fetch.expected_body orelse return;
    if (fetch.body_bytes != expected.len)
        return error.BenchUnexpectedBody;
}

/// A plain HTTP/1.1 origin on its own thread. One poll(2) loop serves up to
/// `origin_connections_max` connections at once and answers each request
/// head, once its blank line arrived, with the scenario's response in one
/// write; under `close` it then closes the connection. It reads heads only,
/// since the bench sends bodiless GETs. Initialize it in place: its thread
/// holds a pointer to it.
const Origin = struct {
    listener: std.net.Server,
    port: u16,
    /// The scenario's whole response, head and body.
    response: [response_bytes_max]u8,
    response_len: usize,
    close_after_response: bool,
    /// Written by `stop`; the loop returns once it is readable.
    stop_fd: std.posix.fd_t,
    thread: std.Thread,
    /// Connections accepted so far, counted before the first byte is read.
    accepted: std.atomic.Value(u64),

    const response_bytes_max: usize = 256;
    /// A request head that outgrows this fails its connection.
    const request_head_bytes_max: usize = 4096;

    const Connection = struct {
        fd: std.posix.fd_t,
        head: [request_head_bytes_max]u8,
        head_len: usize,
    };

    fn start(self: *Origin, scenario: Scenario) !void {
        const listen_address = try std.net.Address.parseIp4("0.0.0.0", 0);
        // Nonblocking, so a client that resets between the poll and the
        // accept cannot block the loop where `stop` would never reach it.
        // Accepted connections block, which their single small reads and
        // writes after a poll allow.
        var listener = try listen_address.listen(.{ .reuse_address = true, .force_nonblocking = true });
        errdefer listener.deinit();
        const stop_fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC);
        errdefer std.posix.close(stop_fd);
        self.* = .{
            .listener = listener,
            .port = listener.listen_address.getPort(),
            .response = undefined,
            .response_len = 0,
            .close_after_response = !scenario.keepAlive(),
            .stop_fd = stop_fd,
            .thread = undefined,
            .accepted = .init(0),
        };
        self.response_len = (try formatResponse(&self.response, scenario)).len;
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
    }

    fn stop(self: *Origin) void {
        const one: u64 = 1;
        // Without the wake the join below would never return.
        _ = std.posix.write(self.stop_fd, std.mem.asBytes(&one)) catch |err|
            std.debug.panic("{s}: origin stop failed: {s}", .{ bench_name, @errorName(err) });
        self.thread.join();
        std.posix.close(self.stop_fd);
        self.listener.deinit();
        self.* = undefined;
    }

    fn threadMain(self: *Origin) void {
        // The fetches still running then fail, which fails the sample.
        self.serve() catch |err|
            std.debug.print("{s}: origin stopped serving: {s}\n", .{ bench_name, @errorName(err) });
    }

    fn serve(self: *Origin) !void {
        var connections: [origin_connections_max]Connection = undefined;
        var connection_count: usize = 0;
        defer for (connections[0..connection_count]) |connection| std.posix.close(connection.fd);
        var pollfds: [origin_connections_max + 2]std.posix.pollfd = undefined;
        // Runs until `stop`, blocking in poll(2) once per pass.
        while (true) {
            pollfds[0] = .{ .fd = self.stop_fd, .events = std.posix.POLL.IN, .revents = 0 };
            pollfds[1] = .{
                .fd = self.listener.stream.handle,
                // A full table leaves new connections in the listen backlog.
                .events = if (connection_count < origin_connections_max) std.posix.POLL.IN else 0,
                .revents = 0,
            };
            for (connections[0..connection_count], pollfds[2..][0..connection_count]) |connection, *pollfd|
                pollfd.* = .{ .fd = connection.fd, .events = std.posix.POLL.IN, .revents = 0 };
            _ = try std.posix.poll(pollfds[0 .. connection_count + 2], -1);
            if (pollfds[0].revents != 0)
                return;

            // Downward, so a removal that moves the last connection into the
            // freed place moves one this pass already served.
            var index = connection_count;
            while (index > 0) {
                index -= 1;
                if (pollfds[index + 2].revents == 0)
                    continue;
                if (self.serveReadable(&connections[index]))
                    continue;
                std.posix.close(connections[index].fd);
                connection_count -= 1;
                connections[index] = connections[connection_count];
            }
            if (pollfds[1].revents & std.posix.POLL.IN != 0) {
                const accepted = self.listener.accept() catch |err| switch (err) {
                    // The client gave up between the poll and the accept.
                    error.WouldBlock, error.ConnectionAborted => continue,
                    else => return err,
                };
                connections[connection_count] = .{
                    .fd = accepted.stream.handle,
                    .head = undefined,
                    .head_len = 0,
                };
                connection_count += 1;
                _ = self.accepted.fetchAdd(1, .release);
            }
        }
    }

    /// Reads what arrived on `connection` and answers every complete request
    /// head in it. Returns false when the connection must close: the client
    /// closed or reset it, a head outgrew the buffer, or the scenario closes
    /// after each response.
    fn serveReadable(self: *const Origin, connection: *Connection) bool {
        const free = connection.head[connection.head_len..];
        if (free.len == 0)
            return false;
        // A failed read is a reset connection, which only closes it.
        const received = std.posix.recv(connection.fd, free, 0) catch return false;
        if (received == 0)
            return false;
        connection.head_len += received;
        // Each pass consumes one head, so the bytes received bound the loop.
        while (std.mem.indexOf(u8, connection.head[0..connection.head_len], "\r\n\r\n")) |head_end| {
            sendAll(connection.fd, self.response[0..self.response_len]) catch return false;
            const unread = connection.head[head_end + "\r\n\r\n".len .. connection.head_len];
            std.mem.copyForwards(u8, connection.head[0..unread.len], unread);
            connection.head_len = unread.len;
            if (self.close_after_response)
                return false;
        }
        return true;
    }
};

fn formatResponse(buffer: []u8, scenario: Scenario) ![]const u8 {
    const body: []const u8 = if (scenario.gzip()) &gzip_body else expected_body;
    var writer: std.Io.Writer = .fixed(buffer);
    try writer.print("HTTP/1.1 200 OK\r\ncontent-length: {d}\r\n", .{body.len});
    if (scenario.gzip())
        try writer.writeAll("content-encoding: gzip\r\n");
    try writer.print("connection: {s}\r\n\r\n", .{if (scenario.keepAlive()) "keep-alive" else "close"});
    try writer.writeAll(body);
    return writer.buffered();
}

/// MSG_NOSIGNAL turns a write to a connection the client already closed
/// into an error instead of SIGPIPE.
fn sendAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var sent: usize = 0;
    // Each pass sends at least one byte or fails.
    while (sent < bytes.len)
        sent += try std.posix.send(fd, bytes[sent..], std.posix.MSG.NOSIGNAL);
}

fn envUsize(allocator: std.mem.Allocator, name: []const u8, default: usize) !usize {
    const raw = std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return default,
        else => return err,
    };
    defer allocator.free(raw);
    return std.fmt.parseUnsigned(usize, std.mem.trim(u8, raw, " \t\r\n"), 10);
}

fn printJsonSample(scenario: Scenario, options: Options, iteration: usize, sample: Sample) void {
    std.debug.print(
        "{{\"bench\":\"{s}\",\"scenario\":\"{s}\",\"iteration\":{d},\"requests\":{d},\"inflight\":{d},\"elapsed_ns\":{d},\"req_per_s\":{d:.1},\"latency_p50_ns\":{d},\"latency_p99_ns\":{d},\"ttfb_p50_ns\":{d},\"ttfb_p99_ns\":{d},\"accepted_connections\":{d},\"rss_kib\":{d},\"pss_kib\":{d},\"private_dirty_kib\":{d}}}\n",
        .{
            bench_name,
            @tagName(scenario),
            iteration,
            options.requests,
            options.inflight,
            sample.elapsed_ns,
            sample.requests_per_second,
            sample.latency_p50_ns,
            sample.latency_p99_ns,
            sample.ttfb_p50_ns,
            sample.ttfb_p99_ns,
            sample.accepted_connections,
            sample.memory.rss_kib,
            sample.memory.pss_kib,
            sample.memory.private_dirty_kib,
        },
    );
}

/// Medians over the samples of each per-sample figure, plus the best rate.
fn printSummary(
    allocator: std.mem.Allocator,
    scenario: Scenario,
    options: Options,
    samples: []const Sample,
) !void {
    const scratch = try allocator.alloc(u64, samples.len);
    defer allocator.free(scratch);
    const rates = try allocator.alloc(f64, samples.len);
    defer allocator.free(rates);
    for (samples, rates) |sample, *rate|
        rate.* = sample.requests_per_second;
    std.mem.sort(f64, rates, {}, std.sort.asc(f64));
    std.debug.print(
        "{s}_summary scenario={s} samples={d} requests={d} inflight={d} req_per_s_p50={d:.1} req_per_s_best={d:.1} latency_p50_ns={d} latency_p99_ns={d} ttfb_p50_ns={d} ttfb_p99_ns={d} accepted_connections={d}\n",
        .{
            bench_name,
            @tagName(scenario),
            samples.len,
            options.requests,
            options.inflight,
            bench_common.percentileNearestRank(f64, rates, 50),
            rates[rates.len - 1],
            medianOf(scratch, samples, "latency_p50_ns"),
            medianOf(scratch, samples, "latency_p99_ns"),
            medianOf(scratch, samples, "ttfb_p50_ns"),
            medianOf(scratch, samples, "ttfb_p99_ns"),
            medianOf(scratch, samples, "accepted_connections"),
        },
    );
}

fn medianOf(scratch: []u64, samples: []const Sample, comptime field: []const u8) u64 {
    for (samples, scratch) |sample, *value|
        value.* = @field(sample, field);
    std.mem.sort(u64, scratch, {}, std.sort.asc(u64));
    return bench_common.percentileNearestRank(u64, scratch, 50);
}

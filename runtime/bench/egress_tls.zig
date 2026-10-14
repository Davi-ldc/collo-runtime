//! Measures TLS egress through one egress engine, the engine a gateway shard
//! runs, against local HTTP/2 origins of the test TLS shim
//! (`collo_bench_h2_origin_start`), each serving exactly one connection on a
//! thread of its own. Every sample starts a fresh engine and origin. Like
//! every egress bench it builds ReleaseFast without JSC.
//!
//! `tls_handshake_full` times a fresh engine's first fetch from submit to its
//! response head: the DNS cache's first lookup, the TCP connect, a full TLS
//! handshake on the engine's owner thread, the HTTP/2 session setup and one
//! stream. Each sample dials under a security cell of its own, so its
//! session key (`tls.buildSessionKey`) never matches a ticket an earlier
//! sample left in the process-wide client session cache.
//!
//! The transfer scenarios measure HTTP/2 over one established connection:
//! one untimed fetch pays for the dial, then the sample times `streams`
//! fetches submitted at once, as uploads, downloads, small responses or a
//! 100-stream multiplex. A transfer sample fails unless the origin answered
//! every stream on its one connection and the body bytes received total the
//! stream count times the response size.
//!
//! The bench consumes each fetch the way the gateway's loop does: it arms
//! the task's response queue before it sleeps, pulls one chunk per pull,
//! returns every chunk's credit to the engine, which opens HTTP/2
//! flow-control windows only as credits come back, and sleeps on an eventfd
//! that the engine's wake callback writes.
//!
//! No scenario times a resumed handshake. A resumed dial needs an origin that
//! redeems a ticket an earlier connection to the same name and port received
//! and then answers HTTP, and no shim origin does both: a bench origin builds
//! its own server context and serves one connection on a port the kernel
//! picks, and the resumption origin answers no request.
//!
//! COLLO_BENCH_EGRESS_ITERATIONS sets the measured samples per scenario and
//! COLLO_BENCH_EGRESS_WARMUP the unmeasured samples before them.

const std = @import("std");
const bench_common = @import("common.zig");
const bench_metadata = @import("metadata.zig");
const local_origin = @import("local_origin.zig");
const proc_memory = @import("proc_memory.zig");
const egress = @import("collo_egress_client");
const tls_shim = @import("collo_test_tls_shim");

const Engine = egress.engine.Engine;
const ResponseQueue = egress.core.ResponseQueue;
const Task = egress.task.Task;
const TestH2Origin = tls_shim.TestH2Origin;

const bench_name = "egress_tls";
const default_iterations: usize = 20;
const default_warmup_iterations: usize = 3;

/// How long a sample may go without progress before it fails.
const stall_timeout_ns: u64 = 30 * std.time.ns_per_s;
/// Chunks one `Consumer.advance` pulls before the other fetches get a turn.
const pulls_per_advance_max: usize = 64;
/// The most timed streams a scenario runs, plus the untimed one.
const fetches_max: usize = 101;
/// The largest HTTP/2 flow-control window.
const h2_window_bytes_max: usize = (1 << 31) - 1;

const Scenario = struct {
    name: []const u8,
    /// One untimed fetch opens the connection before the timed ones.
    primed: bool,
    streams: u32,
    request_body_bytes: usize = 0,
    /// What the origin sends for every stream but its first, which it
    /// answers with an empty body.
    response_body_bytes: usize = 0,
};

const scenarios = [_]Scenario{
    .{ .name = "tls_handshake_full", .primed = false, .streams = 1 },
    .{ .name = "upload_16k", .primed = true, .streams = 1, .request_body_bytes = 16 * 1024 },
    .{ .name = "upload_256k", .primed = true, .streams = 1, .request_body_bytes = 256 * 1024 },
    .{ .name = "download_16k", .primed = true, .streams = 1, .response_body_bytes = 16 * 1024 },
    .{ .name = "download_256k", .primed = true, .streams = 1, .response_body_bytes = 256 * 1024 },
    .{ .name = "small_frame_h2", .primed = true, .streams = 32, .response_body_bytes = 1 },
    .{ .name = "multiplex_100_small_h2", .primed = true, .streams = 100, .response_body_bytes = 2 },
};

comptime {
    for (scenarios) |scenario| {
        std.debug.assert(scenario.streams != 0);
        std.debug.assert(@intFromBool(scenario.primed) + scenario.streams <= fetches_max);
    }
}

const Sample = struct {
    /// From the first timed submit to the end of the last body.
    elapsed_ns: u64,
    /// From the first timed submit to the first published head.
    ttfb_ns: u64,
    /// The process with the sample's engine still running.
    memory: proc_memory.Metrics,
};

pub fn main() !void {
    // The engine's owner thread allocates while the bench thread does, and
    // smp_allocator keeps a freelist per thread, so no allocator lock adds
    // contention the gateway does not have.
    const allocator = std.heap.smp_allocator;
    try bench_metadata.print(allocator, bench_name);
    const iterations = try envUsize(allocator, "COLLO_BENCH_EGRESS_ITERATIONS", default_iterations);
    const warmup_iterations = try envUsize(allocator, "COLLO_BENCH_EGRESS_WARMUP", default_warmup_iterations);
    if (iterations == 0) {
        std.debug.print("{s}: iterations must be nonzero\n", .{bench_name});
        return error.InvalidBenchConfig;
    }
    const local = try LocalAddress.init();
    var sample_number: u64 = 0;
    for (scenarios) |scenario| {
        var warmup: usize = 0;
        while (warmup < warmup_iterations) : (warmup += 1) {
            sample_number += 1;
            _ = try runSample(allocator, scenario, &local, securityCell(sample_number));
        }
        const samples = try allocator.alloc(Sample, iterations);
        defer allocator.free(samples);
        for (samples, 1..) |*sample, iteration| {
            sample_number += 1;
            sample.* = try runSample(allocator, scenario, &local, securityCell(sample_number));
            printJsonSample(scenario, iteration, sample.*);
        }
        try printSummary(allocator, scenario, samples);
    }
}

/// A security cell no other sample of this process uses.
fn securityCell(sample_number: u64) [16]u8 {
    var cell: [16]u8 = @splat(0);
    std.mem.writeInt(u64, cell[0..8], sample_number, .little);
    return cell;
}

fn runSample(
    allocator: std.mem.Allocator,
    scenario: Scenario,
    local: *const LocalAddress,
    security_cell: [16]u8,
) !Sample {
    const primed_streams: u32 = @intFromBool(scenario.primed);
    const origin = try Origin.start(primed_streams + scenario.streams, scenario.response_body_bytes);
    defer origin.stop();

    var url_buffer: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "https://{s}:{d}/bench", .{ local.host(), origin.port });
    // The engine stops before this returns, so the grant outlives every hop
    // that reads it.
    var grant: local_origin.LocalGrant = undefined;
    try grant.init(local.bytes, &.{origin.port});
    const config = sampleConfig(scenario, grant.policy(), security_cell);
    const request_body = try allocator.alloc(u8, scenario.request_body_bytes);
    defer allocator.free(request_body);
    @memset(request_body, 'p');

    var fetches: [fetches_max]?Fetch = @splat(null);
    var consumer: Consumer = undefined;
    try consumer.init(allocator, @intFromBool(scenario.primed) + scenario.streams);
    defer consumer.deinit();
    defer {
        consumer.stop();
        for (&fetches) |*slot| {
            if (slot.*) |*fetch|
                consumer.discard(fetch);
        }
    }

    var timer = try std.time.Timer.start();
    if (scenario.primed) {
        const priming = fetches[0..1];
        priming[0] = try consumer.createFetch(.{ .url = url, .method = "GET", .config = config });
        try consumer.submit(&priming[0].?, &timer);
        _ = try runToEnd(&consumer, priming, &timer, origin);
    }

    // Tasks copy their request bodies here, before the timed window.
    const timed = fetches[primed_streams..][0..scenario.streams];
    const method: []const u8 = if (scenario.request_body_bytes == 0) "GET" else "POST";
    const request: Request = .{ .url = url, .method = method, .body = request_body, .config = config };
    for (timed) |*slot|
        slot.* = try consumer.createFetch(request);
    timer.reset();
    for (timed) |*slot|
        try consumer.submit(&slot.*.?, &timer);
    const outcome = try runToEnd(&consumer, timed, &timer, origin);

    const answered = origin.streamCount();
    if (answered != primed_streams + scenario.streams) {
        std.debug.print(
            "{s}: {s}: the origin answered {d} of {d} streams on its one connection\n",
            .{ bench_name, scenario.name, answered, primed_streams + scenario.streams },
        );
        return error.EgressTlsBenchConnectionNotReused;
    }
    // The origin's first stream carries no body: the untimed fetch's, or the
    // first timed one's when no fetch primed the connection.
    const full_responses: usize = if (scenario.primed) scenario.streams else scenario.streams - 1;
    const expected_body_bytes = full_responses * scenario.response_body_bytes;
    if (outcome.body_bytes != expected_body_bytes) {
        std.debug.print(
            "{s}: {s}: received {d} body bytes, expected {d}\n",
            .{ bench_name, scenario.name, outcome.body_bytes, expected_body_bytes },
        );
        return error.EgressTlsBenchUnexpectedBodyBytes;
    }
    return .{
        .elapsed_ns = outcome.last_end_ns,
        .ttfb_ns = outcome.first_head_ns,
        .memory = try proc_memory.readProcess(allocator, @intCast(std.os.linux.getpid())),
    };
}

const BatchOutcome = struct {
    /// Readings of the sample's timer.
    first_head_ns: u64 = std.math.maxInt(u64),
    last_end_ns: u64 = 0,
    body_bytes: usize = 0,
};

/// Advances every submitted fetch in `slots` until each body ended,
/// discarding each fetch as it ends. On failure it prints the origin's error,
/// a diagnostic only: the origin's thread may still be writing it.
fn runToEnd(consumer: *Consumer, slots: []?Fetch, timer: *std.time.Timer, origin: Origin) !BatchOutcome {
    var outcome: BatchOutcome = .{};
    var remaining = slots.len;
    var deadline_ns = try bench_common.deadlineFromNowNs(stall_timeout_ns);
    errdefer {
        const origin_error = origin.lastError();
        if (origin_error.len != 0)
            std.debug.print("{s}: origin error: {s}\n", .{ bench_name, origin_error });
    }
    while (remaining != 0) {
        var progressed = false;
        for (slots) |*slot| {
            const fetch = if (slot.*) |*held| held else continue;
            switch (try consumer.advance(fetch, timer)) {
                .idle => continue,
                .progressed => {},
                .finished => {
                    outcome.first_head_ns = @min(outcome.first_head_ns, fetch.head_ns.?);
                    outcome.last_end_ns = @max(outcome.last_end_ns, fetch.end_ns);
                    outcome.body_bytes += fetch.body_bytes;
                    consumer.discard(fetch);
                    slot.* = null;
                    remaining -= 1;
                },
            }
            progressed = true;
        }
        if (progressed) {
            deadline_ns = try bench_common.deadlineFromNowNs(stall_timeout_ns);
        } else {
            consumer.wait(deadline_ns) catch |err| {
                std.debug.print(
                    "{s}: stalled with {d} of {d} fetches open\n",
                    .{ bench_name, remaining, slots.len },
                );
                return err;
            };
        }
    }
    return outcome;
}

/// One config for every fetch of a sample, so they all share the origin key
/// of the one connection the origin accepts. The stream limit admits every
/// timed stream at once, since a pool entry at its limit makes the engine
/// dial a second connection; the priming stream never counts against it,
/// because a stream leaves the connection's active set before its queue
/// completes (`completeStreamAt` in the HTTP/2 codec). The bench origin
/// sends each response whole without waiting for window updates, so each
/// stream's receive window covers a whole response and the connection's
/// covers every stream at once, within the HTTP/2 maximum. The body limits
/// cover the windows, since `Config.http2Limits` clamps the windows to them.
fn sampleConfig(
    scenario: Scenario,
    policy: egress.network.Policy,
    security_cell: [16]u8,
) egress.Config {
    const response_window = @max(scenario.response_body_bytes, 64 * 1024);
    const stream_window: usize = @min(response_window, h2_window_bytes_max);
    const connection_window: usize = @min(stream_window * scenario.streams, h2_window_bytes_max);
    // Room for a whole request body in the HTTP/2 send queue and on the wire.
    const outgoing_bytes: usize = @max(scenario.request_body_bytes + 64 * 1024, 1024 * 1024);
    return .{
        .network = policy,
        .insecure_tls = true,
        .socket_timeout_ms = 15_000,
        .max_response_body_bytes = stream_window,
        .max_encoded_response_bytes = stream_window,
        .max_pending_decoded_body_bytes = stream_window,
        .http2_max_active_streams = scenario.streams,
        .http2_stream_receive_window = @intCast(stream_window),
        .http2_conn_receive_window = @intCast(connection_window),
        .http2_max_pending_body_credit_per_stream = stream_window,
        .http2_max_pending_body_credit_per_connection = connection_window,
        .http2_max_outgoing_buffer_bytes = outgoing_bytes,
        .wire_buffer_bytes = outgoing_bytes,
        .pool_security_cell_id = security_cell,
    };
}

/// A bench origin of the test TLS shim. It serves `expected_stream_count`
/// streams on the one connection it accepts, answers its first stream with
/// an empty body and every later one with `response_body_bytes`.
const Origin = struct {
    handle: *TestH2Origin,
    port: u16,

    fn start(expected_stream_count: u32, response_body_bytes: usize) !Origin {
        var handle: ?*TestH2Origin = null;
        var port: u16 = 0;
        const status = tls_shim.collo_bench_h2_origin_start(
            expected_stream_count,
            response_body_bytes,
            &handle,
            &port,
        );
        if (status != 0) {
            const reason = std.mem.span(tls_shim.collo_test_tls_last_error());
            std.debug.print("{s}: origin start failed: {s}\n", .{ bench_name, reason });
            return error.BenchOriginStartFailed;
        }
        return .{ .handle = handle orelse return error.BenchOriginStartFailed, .port = port };
    }

    fn stop(self: Origin) void {
        tls_shim.collo_test_h2_origin_stop(self.handle);
    }

    /// Responses answered so far, all on the origin's one connection. Each
    /// is counted before its last frame is written, so once a body ended its
    /// response is counted.
    fn streamCount(self: Origin) u32 {
        return tls_shim.collo_test_h2_origin_stream_count(self.handle);
    }

    fn lastError(self: Origin) []const u8 {
        return std.mem.span(tls_shim.collo_test_h2_origin_last_error(self.handle));
    }
};

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

    /// Starts an engine that runs up to `fetches_in_flight` fetches at once,
    /// the most a sample has in flight.
    fn init(self: *Consumer, allocator: std.mem.Allocator, fetches_in_flight: usize) !void {
        const wake_fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
        errdefer std.posix.close(wake_fd);
        self.* = .{
            .allocator = allocator,
            .engine = try Engine.init(allocator, fetches_in_flight),
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

fn envUsize(allocator: std.mem.Allocator, name: []const u8, default: usize) !usize {
    const raw = std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return default,
        else => return err,
    };
    defer allocator.free(raw);
    return std.fmt.parseUnsigned(usize, std.mem.trim(u8, raw, " \t\r\n"), 10);
}

fn printJsonSample(scenario: Scenario, iteration: usize, sample: Sample) void {
    std.debug.print(
        "{{\"bench\":\"{s}\",\"scenario\":\"{s}\",\"iteration\":{d},\"streams\":{d},\"request_body_bytes\":{d},\"response_body_bytes\":{d},\"elapsed_ns\":{d},\"ttfb_ns\":{d},\"ns_per_stream\":{d:.3},\"rss_kib\":{d},\"pss_kib\":{d},\"private_dirty_kib\":{d}}}\n",
        .{
            bench_name,
            scenario.name,
            iteration,
            scenario.streams,
            scenario.request_body_bytes,
            scenario.response_body_bytes,
            sample.elapsed_ns,
            sample.ttfb_ns,
            nsPerStream(scenario, sample.elapsed_ns),
            sample.memory.rss_kib,
            sample.memory.pss_kib,
            sample.memory.private_dirty_kib,
        },
    );
}

/// Percentiles over the samples of the time per stream and of the first
/// head.
fn printSummary(allocator: std.mem.Allocator, scenario: Scenario, samples: []const Sample) !void {
    const elapsed_ns = try allocator.alloc(u64, samples.len);
    defer allocator.free(elapsed_ns);
    const ttfb_ns = try allocator.alloc(u64, samples.len);
    defer allocator.free(ttfb_ns);
    for (samples, elapsed_ns, ttfb_ns) |sample, *elapsed, *ttfb| {
        elapsed.* = sample.elapsed_ns;
        ttfb.* = sample.ttfb_ns;
    }
    std.mem.sort(u64, elapsed_ns, {}, std.sort.asc(u64));
    std.mem.sort(u64, ttfb_ns, {}, std.sort.asc(u64));
    std.debug.print(
        "{s}_summary scenario={s} samples={d} streams={d} p50_ns_per_stream={d:.3} p95_ns_per_stream={d:.3} ttfb_p50_ns={d} ttfb_p95_ns={d}\n",
        .{
            bench_name,
            scenario.name,
            samples.len,
            scenario.streams,
            nsPerStream(scenario, bench_common.percentileNearestRank(u64, elapsed_ns, 50)),
            nsPerStream(scenario, bench_common.percentileNearestRank(u64, elapsed_ns, 95)),
            bench_common.percentileNearestRank(u64, ttfb_ns, 50),
            bench_common.percentileNearestRank(u64, ttfb_ns, 95),
        },
    );
}

fn nsPerStream(scenario: Scenario, elapsed_ns: u64) f64 {
    return @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(scenario.streams));
}

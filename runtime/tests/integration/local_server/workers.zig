//! How the server shares workers among requests and lanes, seen from clients
//! against real sandboxed workers: two connections on two lanes served at
//! once by one worker, a steady load on one connection served by the one
//! worker its first request launched, at concurrency 1 on one CPU too, the
//! scale-out that gives workers waiting on timers company and keeps workers
//! spinning on one CPU alone, a deadline that ends its request and
//! keeps its worker, a worker's death answered on every lane that held one of
//! its requests, request bodies that meet a worker running synchronous
//! JavaScript or a worker that dies, workers that retire one after another
//! under a steady load without a 502, and the line a killed worker leaves in
//! `workers.jsonl` with the CPU and memory peak its cgroup leaf counted, which
//! only a real leaf can give. The routes answer with a token drawn once per
//! worker process (`fixtures/local_e2e/api/token.js`), which
//! tells whether two responses came from one worker; the retiring workers
//! fail their only route (`api/boot_rejects.js`), under a configuration the
//! test writes (`network.zig:configText`). Lane `local-e2e`; the pool's own
//! rules run without a server in `server/tests/supervisor/`, and a lane
//! against stub workers in `server/tests/ingress/`.

const std = @import("std");
const process = @import("collo_os").process;
const harness_mod = @import("harness.zig");
const network_mod = @import("network.zig");

const Harness = harness_mod.Harness;
const Client = harness_mod.Client;
const LaunchTrace = harness_mod.LaunchTrace;
const tokenOf = harness_mod.tokenOf;
const uploadReplyOf = harness_mod.uploadReplyOf;

/// Requests of the steady load: enough that, with the old one-request
/// workers, several would meet the worker still finishing the one before.
const steady_requests: usize = 64;
/// Requests of the one-CPU load: each follows the previous response at once.
const single_cpu_requests: usize = 512;
/// Connections of the scale-out loads, each with one request in flight at a
/// time: more than one worker of `concurrency` 1 can serve at once.
const scale_load_clients: usize = 4;
/// How long a scale-out load lasts: many scale-out samples
/// (`scheduler_limits.scale_out.sample_interval_ns`, 100 ms).
const scale_load_ns: u64 = 1500 * std.time.ns_per_ms;
/// Requests one scale-out connection sends at most; the load's duration
/// ends it first.
const scale_load_requests_max: usize = 4096;
/// A body well past the worker's control socket buffer, about 208 KiB by
/// default, and past the stream's receive window, 512 KiB, so the lane holds
/// part of it and the client waits for credit.
const upload_bytes: u64 = 2 * 1024 * 1024;
/// The part of the body a client sends before its worker is killed.
const partial_upload_bytes: u64 = 256 * 1024;
/// DATA frames of the uploads: each chunk stays under the payload ring's
/// threshold, so it travels inline on the worker's control socket
/// (`shared_payload_threshold` in `common/ipc/ingress_channel/payload_ring.zig`).
const upload_frame_bytes: u32 = 16 * 1024;
/// Connections that keep the retiring route under load, each with one
/// request in flight at a time: more than the definition's default
/// `concurrency`, so requests also wait in its pool for a replacement.
const retiring_load_clients: usize = 4;
/// How long the load lasts: long enough for many workers in turn to fail
/// their route and retire under it.
const retiring_load_ns: u64 = 2 * std.time.ns_per_s;
/// Requests one load connection sends at most; the load's duration ends it
/// first.
const retiring_load_requests_max: usize = 4096;

test "two connections on two lanes are served at once by one worker and both get their responses" {
    var harness: Harness = undefined;
    try harness.init(.{ .lane_count = 2 });
    defer harness.deinit();
    errdefer harness_mod.dumpZygoteTrace(&harness.spawned);
    const definition = try harness.definitionIndex("token");

    var lane_zero = try harness_mod.openClientOnLane(&harness, 0);
    defer lane_zero.close();
    var lane_one = try harness_mod.openClientOnLane(&harness, 1);
    defer lane_one.close();

    // The first request launches the route's worker, and lane 0, whose
    // request took the worker's first slot, reads it from then on
    // (`server/supervisor/pool.zig`). Its slot comes back once the lane
    // drains the worker's completion, which can trail the response.
    const warm = try lane_zero.get("/token");
    const token = try tokenOf(&warm);
    _ = try harness_mod.waitForSlotsHeld(&harness, definition, 0);

    // Each request holds the worker long enough for the other to arrive, so
    // the worker runs both at once. Lane 1's response comes back through
    // lane 0, the worker's reader, which forwards it to lane 1.
    const from_lane_one = try lane_one.sendGet("/token?ms=500");
    const from_lane_zero = try lane_zero.sendGet("/token?ms=500");
    const one = try lane_one.readResponse(from_lane_one);
    const zero = try lane_zero.readResponse(from_lane_zero);
    try std.testing.expect(token.eql(try tokenOf(&one)));
    try std.testing.expect(token.eql(try tokenOf(&zero)));

    var traces: [16]LaunchTrace = undefined;
    const launches = harness_mod.countLaunches(harness.takeLaunches(&traces), definition);
    try std.testing.expectEqual(@as(usize, 1), launches.published);
    try std.testing.expectEqual(@as(usize, 0), launches.failed);
}

test "a steady load on one connection is served by the one worker its first request launched" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();
    errdefer harness_mod.dumpZygoteTrace(&harness.spawned);
    const definition = try harness.definitionIndex("token");

    var client = try Client.open(&harness);
    defer client.close();

    // Each request follows the previous response at once. The worker's
    // completion rides the packet that ends the previous response, so the
    // lane has the slot back before the next request arrives.
    const first = try client.get("/token");
    const token = try tokenOf(&first);
    for (1..steady_requests) |_| {
        const response = try client.get("/token");
        try std.testing.expect(token.eql(try tokenOf(&response)));
    }

    var traces: [16]LaunchTrace = undefined;
    const launches = harness_mod.countLaunches(harness.takeLaunches(&traces), definition);
    try std.testing.expectEqual(@as(usize, 1), launches.published);
    try std.testing.expectEqual(@as(usize, 0), launches.failed);
}

/// Restricts the calling thread, and every thread and process it starts
/// afterwards, to its first allowed CPU, and returns the mask it had, which
/// the caller restores with `std.os.linux.sched_setaffinity`.
fn pinToFirstAllowedCpu() !std.os.linux.cpu_set_t {
    const previous = try std.posix.sched_getaffinity(0);
    var pinned = std.mem.zeroes(std.os.linux.cpu_set_t);
    for (previous, 0..) |word, word_index| {
        if (word == 0) continue;
        pinned[word_index] = word & (~word +% 1);
        break;
    }
    try std.os.linux.sched_setaffinity(0, &pinned);
    return previous;
}

test "one connection at concurrency 1 on one CPU is served by the one worker its first request launched (#157)" {
    const configuration = try network_mod.configText(std.testing.allocator, &.{.{
        .name = "single",
        .routes = &.{.{ .path = "/single", .entry = "./api/token.js" }},
        .concurrency = 1,
    }});
    defer std.testing.allocator.free(configuration);
    // The server, its zygote and every worker share one CPU, so the lane that
    // writes a response and the client's next request run while the worker
    // that wrote it waits for the CPU. A worker that freed its slot only in
    // a packet of its own, after its cleanup, left that request waiting
    // behind a slot it no longer needed.
    const previous_affinity = try pinToFirstAllowedCpu();
    // A mask the thread held a moment ago is always accepted again.
    defer std.os.linux.sched_setaffinity(0, &previous_affinity) catch |err|
        std.debug.panic("restoring the test thread's CPU mask failed: {s}", .{@errorName(err)});
    var harness: Harness = undefined;
    try harness.init(.{ .config_source = configuration });
    defer harness.deinit();
    errdefer harness_mod.dumpZygoteTrace(&harness.spawned);
    const definition = try harness.definitionIndex("single");

    var client = try Client.open(&harness);
    defer client.close();
    const first = try client.get("/single");
    const token = try tokenOf(&first);
    for (1..single_cpu_requests) |_| {
        const response = try client.get("/single");
        try std.testing.expect(token.eql(try tokenOf(&response)));
    }

    var traces: [16]LaunchTrace = undefined;
    const launches = harness_mod.countLaunches(harness.takeLaunches(&traces), definition);
    try std.testing.expectEqual(@as(usize, 1), launches.published);
    try std.testing.expectEqual(@as(usize, 0), launches.failed);
}

/// A connection that sends `path` again as soon as each answer arrives,
/// until `end_ns`, and counts the answers.
const SteadyClient = struct {
    client: Client,
    path: []const u8,
    /// CLOCK_MONOTONIC instant after which no request starts.
    end_ns: u64,
    requests: usize = 0,
    /// The status of the first answer other than 200, which ends the load.
    unexpected_status: ?u16 = null,
    failure: ?anyerror = null,

    fn run(self: *SteadyClient) void {
        for (0..scale_load_requests_max) |_| {
            const now_ns = process.monotonicNowNs() catch |err| {
                self.failure = err;
                return;
            };
            if (now_ns >= self.end_ns) return;
            const response = self.client.get(self.path) catch |err| {
                self.failure = err;
                return;
            };
            self.requests += 1;
            if (response.status != 200) {
                self.unexpected_status = response.status;
                return;
            }
        }
    }
};

/// Runs `clients_count` connections of `SteadyClient` against `path` for
/// `scale_load_ns` and checks that every answer was 200.
fn runSteadyLoad(harness: *Harness, comptime clients_count: usize, path: []const u8) !void {
    var load: [clients_count]SteadyClient = undefined;
    var opened: usize = 0;
    defer for (load[0..opened]) |*steady| steady.client.close();
    const end_ns = (try process.monotonicNowNs()) + scale_load_ns;
    for (&load) |*steady| {
        steady.* = .{ .client = try Client.open(harness), .path = path, .end_ns = end_ns };
        opened += 1;
    }
    var threads: [clients_count]std.Thread = undefined;
    var running: usize = 0;
    defer for (threads[0..running]) |thread| thread.join();
    for (&load, &threads) |*steady, *thread| {
        thread.* = try std.Thread.spawn(.{}, SteadyClient.run, .{steady});
        running += 1;
    }
    for (threads[0..running]) |thread| thread.join();
    running = 0;
    for (&load) |*steady| {
        if (steady.failure) |failure| return failure;
        if (steady.unexpected_status) |status| {
            std.debug.print("an answer of the steady load had status {d}\n", .{status});
            return error.UnexpectedStatus;
        }
        try std.testing.expect(steady.requests > 0);
    }
}

test "a definition whose workers wait on timers gets workers beside its first while its requests keep waiting (#157)" {
    const configuration = try network_mod.configText(std.testing.allocator, &.{.{
        .name = "timers",
        .routes = &.{.{ .path = "/timers", .entry = "./api/token.js" }},
        .concurrency = 1,
    }});
    defer std.testing.allocator.free(configuration);
    var harness: Harness = undefined;
    try harness.init(.{ .config_source = configuration });
    defer harness.deinit();
    errdefer harness_mod.dumpZygoteTrace(&harness.spawned);
    const definition = try harness.definitionIndex("timers");

    // Each request holds its worker's only slot through a timer and uses
    // almost no CPU, so the waiters behind it wait for slots, and the
    // scale-out verdict grants a worker more at each sample while they do.
    try runSteadyLoad(&harness, scale_load_clients, "/timers?ms=40");

    var traces: [16]LaunchTrace = undefined;
    const launches = harness_mod.countLaunches(harness.takeLaunches(&traces), definition);
    try std.testing.expect(launches.published >= 2);
    try std.testing.expect(launches.published <= scale_load_clients);
    try std.testing.expectEqual(@as(usize, 0), launches.failed);
}

test "a definition whose workers spin on one CPU keeps the one worker its first request launched however many requests wait (#157)" {
    const configuration = try network_mod.configText(std.testing.allocator, &.{.{
        .name = "spin",
        .routes = &.{.{ .path = "/spin", .entry = "./api/token.js" }},
        .concurrency = 1,
    }});
    defer std.testing.allocator.free(configuration);
    // The server, its workers and the clients share one CPU, which the one
    // worker's turns and the lane's writes already fill, so a worker more
    // would only split it.
    const previous_affinity = try pinToFirstAllowedCpu();
    // A mask the thread held a moment ago is always accepted again.
    defer std.os.linux.sched_setaffinity(0, &previous_affinity) catch |err|
        std.debug.panic("restoring the test thread's CPU mask failed: {s}", .{@errorName(err)});
    var harness: Harness = undefined;
    try harness.init(.{ .config_source = configuration });
    defer harness.deinit();
    errdefer harness_mod.dumpZygoteTrace(&harness.spawned);
    const definition = try harness.definitionIndex("spin");

    try runSteadyLoad(&harness, scale_load_clients, "/spin?spin=3");

    var traces: [16]LaunchTrace = undefined;
    const launches = harness_mod.countLaunches(harness.takeLaunches(&traces), definition);
    try std.testing.expectEqual(@as(usize, 1), launches.published);
    try std.testing.expectEqual(@as(usize, 0), launches.failed);
}

test "a request past its deadline is answered 504 while its worker serves the request beside it and the next one" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();
    errdefer harness_mod.dumpZygoteTrace(&harness.spawned);
    const definition = try harness.definitionIndex("deadline");

    var held = try Client.open(&harness);
    defer held.close();
    var other = try Client.open(&harness);
    defer other.close();

    const warm = try other.get("/deadline");
    const token = try tokenOf(&warm);
    const worker = try harness_mod.waitForSlotsHeld(&harness, definition, 0);

    // The route's deadline is 1000 ms (`fixtures/local_e2e/collo.json`). The
    // held request never answers by itself; the other one arrives 500 ms
    // later and answers 600 ms after that, so both run on the worker when
    // the first one's deadline passes and the worker answers it 504 itself.
    const hanging = try held.sendGet("/deadline?hang=1");
    _ = try harness_mod.waitForSlotsHeld(&harness, definition, 1);
    std.Thread.sleep(500 * std.time.ns_per_ms);
    const beside = try other.sendGet("/deadline?ms=600");
    const timed_out = try held.readResponse(hanging);
    try std.testing.expectEqual(@as(u16, 504), timed_out.status);
    const answered = try other.readResponse(beside);
    try std.testing.expect(token.eql(try tokenOf(&answered)));

    // The deadline ended its request and left the worker serving.
    const next = try other.get("/deadline");
    try std.testing.expect(token.eql(try tokenOf(&next)));
    const after = try harness_mod.soleLiveWorker(&harness, definition);
    try std.testing.expect(after.key.eql(worker.key));
}

test "a worker killed while it holds requests from two lanes answers both 502 and a new worker serves the next request" {
    var harness: Harness = undefined;
    try harness.init(.{ .lane_count = 2 });
    defer harness.deinit();
    errdefer harness_mod.dumpZygoteTrace(&harness.spawned);
    const definition = try harness.definitionIndex("token");

    var lane_zero = try harness_mod.openClientOnLane(&harness, 0);
    defer lane_zero.close();
    var lane_one = try harness_mod.openClientOnLane(&harness, 1);
    defer lane_one.close();

    // Both requests below must reach the worker the first one launched, so
    // they wait for its slot to come back.
    const warm = try lane_zero.get("/token");
    const token = try tokenOf(&warm);
    _ = try harness_mod.waitForSlotsHeld(&harness, definition, 0);
    const from_lane_one = try lane_one.sendGet("/token?hang=1");
    const from_lane_zero = try lane_zero.sendGet("/token?hang=1");
    const worker = try harness_mod.waitForSlotsHeld(&harness, definition, 2);
    try harness_mod.killWorker(worker);

    // Lane 0 reads the worker and sees it die; lane 1 holds a request on it
    // and hears of the death from lane 0. Neither response head went out,
    // so each request is answered 502.
    const zero = try lane_zero.readResponse(from_lane_zero);
    const one = try lane_one.readResponse(from_lane_one);
    try std.testing.expectEqual(@as(u16, 502), zero.status);
    try std.testing.expectEqual(@as(u16, 502), one.status);

    const next = try lane_one.get("/token");
    try std.testing.expect(!token.eql(try tokenOf(&next)));
}

test "an upload past the worker's control socket buffer reaches whole a worker running synchronous JavaScript" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();
    errdefer harness_mod.dumpZygoteTrace(&harness.spawned);

    var client = try Client.open(&harness);
    defer client.close();

    // For a second the handler runs JavaScript and reads nothing. The lane's
    // sends fill the worker's control socket, the rest of the body waits in
    // the lane behind the socket's writability, and the client waits for
    // flow-control credit until the handler reads the body.
    const stream = try client.sendPost("/upload?spin_ms=1000", upload_bytes);
    try std.testing.expectEqual(upload_bytes, try client.sendBody(stream, upload_bytes, upload_frame_bytes, true));
    const response = try client.readResponse(stream);
    const reply = try uploadReplyOf(&response);
    try std.testing.expectEqual(upload_bytes, reply.length);

    // The connection and the worker keep serving.
    const next_stream = try client.sendPost("/upload", 0);
    const next = try client.readResponse(next_stream);
    const next_reply = try uploadReplyOf(&next);
    try std.testing.expectEqual(@as(u64, 0), next_reply.length);
    try std.testing.expect(reply.token.eql(next_reply.token));
}

test "a worker killed mid-upload answers the upload 502 and the lane serves the next request" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();
    errdefer harness_mod.dumpZygoteTrace(&harness.spawned);
    const definition = try harness.definitionIndex("upload");

    var client = try Client.open(&harness);
    defer client.close();

    // An empty upload launches the route's worker first. Once its slot is
    // back, the next upload reaches that worker at once and is the one
    // request it holds.
    const warm_stream = try client.sendPost("/upload", 0);
    const warm = try client.readResponse(warm_stream);
    const warm_reply = try uploadReplyOf(&warm);
    _ = try harness_mod.waitForSlotsHeld(&harness, definition, 0);

    // The handler waits for the whole body, which never comes: the client
    // sends part of it and the worker dies while its request reads.
    const stream = try client.sendPost("/upload", upload_bytes);
    _ = try client.sendBody(stream, partial_upload_bytes, upload_frame_bytes, false);
    const worker = try harness_mod.waitForSlotsHeld(&harness, definition, 1);
    try harness_mod.killWorker(worker);
    const response = try client.readResponse(stream);
    try std.testing.expectEqual(@as(u16, 502), response.status);

    // The lane serves the next request, from a new worker.
    const next_stream = try client.sendPost("/upload", 0);
    const next = try client.readResponse(next_stream);
    const next_reply = try uploadReplyOf(&next);
    try std.testing.expect(!warm_reply.token.eql(next_reply.token));
}

test "a killed worker's line in workers.jsonl carries the CPU and memory peak its leaf counted" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();
    errdefer harness_mod.dumpZygoteTrace(&harness.spawned);
    const definition = try harness.definitionIndex("token");

    var client = try Client.open(&harness);
    defer client.close();
    const served = try client.get("/token");
    _ = try tokenOf(&served);
    const worker = try harness_mod.waitForSlotsHeld(&harness, definition, 0);
    // `memory.peak` exists from Linux 5.19 on.
    const memory_peak_available = harness_mod.leafHasFile(worker, "memory.peak");

    // The reaper tears the dead worker down: it waits for the exit, reads
    // the leaf's `cpu.stat` and `memory.peak`, writes the line, and only then
    // removes the leaf.
    try harness_mod.killWorker(worker);
    var lines = try harness_mod.waitForRecordLines(harness_mod.WorkerLine, &harness, "workers.jsonl", 1);
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    const line = lines.items[0];
    try std.testing.expectEqualStrings("token", line.worker);
    try std.testing.expectEqual(worker.key.worker_id, line.worker_id);
    try std.testing.expectEqual(worker.key.worker_generation, line.worker_generation);
    // A SIGKILL from outside the kernel's OOM killer is a crash.
    try std.testing.expectEqualStrings("crash", line.ending);
    try std.testing.expect(line.started_ts <= line.ts);
    try std.testing.expect(line.life_ns > 0);

    // The leaf counts every thread of the worker from its clone on, boot
    // included, so even at the microsecond grain of `cpu.stat` it holds at
    // least what the access record of the one request counted on the VM
    // thread.
    const worker_cpu_ns = line.worker_cpu_ns orelse return error.WorkerCpuNotRead;
    try std.testing.expect(worker_cpu_ns > 0);
    var access = try harness_mod.waitForRecordLines(harness_mod.AccessLine, &harness, "access.jsonl", 1);
    defer access.deinit();
    try std.testing.expectEqual(@as(usize, 1), access.items.len);
    const request_record = access.items[0];
    try std.testing.expectEqual(line.worker_id, request_record.worker_id);
    try std.testing.expectEqual(line.worker_generation, request_record.worker_generation);
    const request_cpu_ns = request_record.cpu_ns orelse return error.TestExpectedUsage;
    if (worker_cpu_ns < request_cpu_ns) {
        std.debug.print("the leaf counted {d} ns of CPU, less than the {d} ns of its request's access record\n", .{
            worker_cpu_ns,
            request_cpu_ns,
        });
        return error.WorkerCpuBelowRequestCpu;
    }
    if (memory_peak_available) {
        const memory_peak_bytes = line.memory_peak_bytes orelse return error.MemoryPeakNotRead;
        try std.testing.expect(memory_peak_bytes > 0);
    } else {
        std.debug.print("the kernel gives a worker's leaf no memory.peak, so the line's memory_peak_bytes goes unchecked\n", .{});
    }
}

test "a worker that retires while requests arrive answers every one of them, none with 502" {
    const configuration = try network_mod.configText(std.testing.allocator, &.{.{
        .name = "boot-rejects",
        .routes = &.{.{ .path = "/boot-rejects", .entry = "./api/boot_rejects.js" }},
    }});
    defer std.testing.allocator.free(configuration);
    var harness: Harness = undefined;
    try harness.init(.{ .config_source = configuration });
    defer harness.deinit();
    errdefer harness_mod.dumpZygoteTrace(&harness.spawned);
    const definition = try harness.definitionIndex("boot-rejects");

    // Each worker's boot evaluates its only route, which fails about 50 ms
    // later, once the worker is ready: the requests parked on the route get
    // its 500, and the worker asks the server to retire it while it may still
    // hold requests and more arrive. A begin that crossed the notice is
    // answered 503 by the worker without running JavaScript, and the rest
    // wait in the pool for a fresh worker, which fails in turn. The server
    // ends a worker only once no lane can send it a begin, so no request
    // meets a worker that is gone.
    var load: [retiring_load_clients]LoadClient = undefined;
    var opened: usize = 0;
    defer for (load[0..opened]) |*load_client| load_client.client.close();
    const end_ns = (try process.monotonicNowNs()) + retiring_load_ns;
    for (&load) |*load_client| {
        load_client.* = .{ .client = try Client.open(&harness), .path = "/boot-rejects", .end_ns = end_ns };
        opened += 1;
    }
    var threads: [retiring_load_clients]std.Thread = undefined;
    var running: usize = 0;
    defer for (threads[0..running]) |thread| thread.join();
    for (&load, &threads) |*load_client, *thread| {
        thread.* = try std.Thread.spawn(.{}, LoadClient.run, .{load_client});
        running += 1;
    }
    for (threads[0..running]) |thread| thread.join();
    running = 0;

    var requests: usize = 0;
    var failed_route_answers: usize = 0;
    for (&load) |*load_client| {
        if (load_client.failure) |err| return err;
        if (load_client.unexpected) |*response| {
            std.debug.print("a request under the load was answered {d} (reset {d}, code {d}): {s}\n", .{
                response.status,
                response.raw.reset,
                response.raw.reset_code,
                response.body(),
            });
            return error.UnexpectedResponseStatus;
        }
        requests += load_client.requests;
        failed_route_answers += load_client.failed_route_answers;
    }
    // The first requests of every worker park on its route until it fails.
    try std.testing.expect(failed_route_answers >= 1);

    // One access record per request, and none of them a worker's death: the
    // failed route's 500s, and the worker's own 503s for the begins that
    // reached it after it asked to retire.
    var access = try harness_mod.waitForRecordLines(harness_mod.AccessLine, &harness, "access.jsonl", requests);
    defer access.deinit();
    try std.testing.expectEqual(requests, access.items.len);
    for (access.items) |record| {
        switch (record.status) {
            500 => try std.testing.expectEqualStrings("internal_error", record.error_code),
            503 => try std.testing.expectEqualStrings("worker_retiring", record.error_code),
            else => {
                std.debug.print("an access record says {d}, error code {s}, worker fault {s}\n", .{
                    record.status,
                    record.error_code,
                    record.worker_fault,
                });
                return error.UnexpectedAccessRecord;
            },
        }
    }

    // Workers launched one after another, no launch ended without a worker
    // (`launches_ended`), and every worker the test launched was retired as
    // recycled, none as a death. The pool's counters, read under the lock
    // that saw it empty, cover the whole run, where the launcher's trace ring
    // keeps only its latest launches. The configuration has no other
    // definition, so every retirement the reaper counts is one of this
    // pool's.
    const emptied = try harness_mod.waitForPoolEmpty(&harness, definition);
    const published = emptied.counters.published;
    try std.testing.expect(published >= 2);
    try std.testing.expectEqual(@as(u64, 0), emptied.counters.launches_ended);
    const counters = try harness_mod.waitForRecycledRetirements(&harness, published);
    try std.testing.expectEqual(published, counters.retired_recycled);
    try std.testing.expectEqual(@as(u64, 0), counters.retired_died);
}

/// One connection of a steady load, driven by a thread of its own, which
/// sends one request after another until `end_ns` and counts how each was
/// answered.
const LoadClient = struct {
    client: Client,
    path: []const u8,
    /// CLOCK_MONOTONIC instant after which no request starts.
    end_ns: u64,
    requests: usize = 0,
    /// Answers 500, which the retiring route gives the requests parked on it.
    failed_route_answers: usize = 0,
    /// The first answer other than 500 or 503, which ends this connection's
    /// load; its status is 0 for a stream reset before its response head.
    unexpected: ?harness_mod.Response = null,
    failure: ?anyerror = null,

    fn run(self: *LoadClient) void {
        for (0..retiring_load_requests_max) |_| {
            const now_ns = process.monotonicNowNs() catch |err| {
                self.failure = err;
                return;
            };
            if (now_ns >= self.end_ns) return;
            const response = self.client.get(self.path) catch |err| {
                self.failure = err;
                return;
            };
            self.requests += 1;
            switch (response.status) {
                500 => self.failed_route_answers += 1,
                // A retiring worker's answer to a begin it got after its
                // notice, which a run may or may not produce.
                503 => {},
                else => {
                    self.unexpected = response;
                    return;
                },
            }
        }
    }
};

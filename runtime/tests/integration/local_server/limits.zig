//! A worker definition's limits, enforced through the production stack. A
//! handler that spins past the definition's `cpuMs` is answered 503 with
//! error code `cpu`, and a new worker serves the next request. JavaScript no
//! request owns, a FinalizationRegistry callback that never returns, is
//! stopped at the definition's `timeoutMs`, and its worker leaves service and
//! is replaced. A definition at the largest `concurrency` serves that many
//! slow requests at once from one worker. A worker that grows past its
//! `memoryMiB` dies, ended by its sentinel at `memory.high` or by the
//! kernel's OOM kill at `memory.max`: its request's access record says
//! `memory` either way, and the worker's line in `workers.jsonl` says which
//! (`memory_high` or `memory_max`), so each memory test proves the stop it
//! names. Each test writes its configuration with `network.zig:configText`
//! around handlers in `fixtures/local_e2e/api/`. Lane `local-e2e`; the
//! parser's bounds run in `server/tests/config/`, the sentinel's two clocks
//! in `worker/tests/sentinel.zig`, the worker's own answers in
//! `worker/tests/runtime/limits.zig` and `multiplexing.zig`, and the
//! classification of a death in `server/tests/supervisor/`.

const std = @import("std");
const limits = @import("collo_limits");
const process = @import("collo_os").process;
const server_main = @import("collo_server_main");
const harness_mod = @import("harness.zig");
const network_mod = @import("network.zig");

const Harness = harness_mod.Harness;
const Client = harness_mod.Client;
const LaunchTrace = harness_mod.LaunchTrace;
const AccessLine = harness_mod.AccessLine;
const WorkerLine = harness_mod.WorkerLine;
const Token = harness_mod.Token;
const tokenOf = harness_mod.tokenOf;
const expectStatus = harness_mod.expectStatus;
const waitForRecordLines = harness_mod.waitForRecordLines;

/// The CPU budget of the spinning handler's definition.
const cpu_budget_ms: u32 = 50;
/// That definition's wall deadline, far past the budget, so the CPU limit is
/// the one that ends the request.
const cpu_test_timeout_ms: u32 = 5000;
/// The `timeoutMs` of the definition whose worker hangs outside any request,
/// which bounds each stretch of JavaScript its worker owner runs.
const unowned_limit_ms: u32 = 1000;
/// Time past a limit and its grace for the server to take the worker out of
/// service: the sentinel's wake, the notice's trip and the lane's drain, on
/// a host that may be loaded.
const service_exit_slack_ms: u64 = 1000;
/// Bound on the wait for a worker whose VM was stopped to leave service.
const retirement_wait_ms: u64 = 5000;

/// The slow requests of the concurrency test: as many as one worker may run.
const wide_concurrency: u8 = limits.server.worker_concurrency_max;
/// How long each slow request awaits a timer.
const slow_request_ms: u64 = 500;
/// Wall time the slow requests may take together: less than two timers, so
/// no request waited for another's slot.
const wide_wall_ns_max: u64 = 2 * slow_request_ms * std.time.ns_per_ms;
/// Streams one held client keeps open at once
/// (`h2_client_tracked_streams_max` in `runtime/tests/support/tls/tls_shim.cc`).
const client_streams_max: usize = 8;
const wide_clients: usize = @divExact(@as(usize, wide_concurrency), client_streams_max);

/// The memory limit of the growing route's definition.
const memory_limit_mib: u32 = 32;

/// Polls `expectMemoryEndings` makes, `record_poll_interval_ns` apart; the
/// reaper writes a worker's line once it tore the worker down.
const record_polls_max: usize = 500;
const record_poll_interval_ns: u64 = 10 * std.time.ns_per_ms;

comptime {
    std.debug.assert(memory_limit_mib >= limits.server.worker_memory_mib_min);
    std.debug.assert(cpu_budget_ms < cpu_test_timeout_ms);
}

test "a handler that spins past its definition's cpuMs is answered 503 cpu, and a new worker serves the next request" {
    const configuration = try network_mod.configText(std.testing.allocator, &.{.{
        .name = "cpu",
        .routes = &.{
            .{ .path = "/cpu/spin", .entry = "./api/hang_sync.js" },
            .{ .path = "/cpu/token", .entry = "./api/token.js" },
        },
        .timeout_ms = cpu_test_timeout_ms,
        .cpu_ms = cpu_budget_ms,
    }});
    defer std.testing.allocator.free(configuration);
    var harness: Harness = undefined;
    try harness.init(.{ .config_source = configuration });
    defer harness.deinit();
    errdefer harness_mod.dumpZygoteTrace(&harness.spawned);
    const definition = try harness.definitionIndex("cpu");
    var client = try Client.open(&harness);
    defer client.close();

    const warm = try client.get("/cpu/token");
    const token = try tokenOf(&warm);
    const worker = try harness_mod.waitForSlotsHeld(&harness, definition, 0);

    // The handler never yields and its wall deadline is far off, so the
    // sentinel stops it on the VM thread's CPU clock once the request spent
    // its budget. A stopped VM runs no JavaScript again, so the worker asks
    // to retire, and its pool takes it out of service.
    const spun = try client.get("/cpu/spin");
    try expectStatus(&spun, 503);
    try std.testing.expectEqualStrings("cpu limit exceeded", spun.body());
    try harness_mod.waitForWorkerOutOfService(&harness, worker, retirement_wait_ms);

    const next = try client.get("/cpu/token");
    try std.testing.expect(!token.eql(try tokenOf(&next)));
    var traces: [16]LaunchTrace = undefined;
    const launches = harness_mod.countLaunches(harness.takeLaunches(&traces), definition);
    try std.testing.expectEqual(@as(usize, 2), launches.published);
    try std.testing.expectEqual(@as(usize, 0), launches.failed);

    // The access record says why the request ended, and the worker's own
    // measure on it holds at least the budget's CPU.
    var access = try waitForRecordLines(AccessLine, &harness, "access.jsonl", 3);
    defer access.deinit();
    const stopped = try soleAccessRecordWithStatus(access.items, 503);
    try std.testing.expectEqualStrings("/cpu/spin", stopped.route);
    try std.testing.expectEqualStrings("cpu", stopped.error_code);
    try expectUsage(stopped, .{
        .origin = "worker",
        .cpu_ns_min = @as(u64, cpu_budget_ms) * std.time.ns_per_ms,
    });
}

test "a worker hung in JavaScript no request owns leaves service within its timeoutMs, and a new worker serves the next request" {
    const configuration = try network_mod.configText(std.testing.allocator, &.{.{
        .name = "unowned",
        .routes = &.{.{ .path = "/finalization", .entry = "./api/finalization_spin.js" }},
        .timeout_ms = unowned_limit_ms,
    }});
    defer std.testing.allocator.free(configuration);
    var harness: Harness = undefined;
    try harness.init(.{ .config_source = configuration });
    defer harness.deinit();
    errdefer harness_mod.dumpZygoteTrace(&harness.spawned);
    const definition = try harness.definitionIndex("unowned");
    var client = try Client.open(&harness);
    defer client.close();

    // The request registers targets nothing keeps with a FinalizationRegistry
    // whose callback never returns, then allocates `garbageMiB` buffers of
    // 1 MiB that it drops at once, enough that a collection runs and finds
    // some of the targets dead (`api/finalization_spin.js`). Its synchronous
    // handler decided the response first, so it answers 200 and frees its
    // slot.
    const registered = try client.get("/finalization?spin=1");
    const token = try tokenOf(&registered);
    const worker = try harness_mod.waitForSlotsHeld(&harness, definition, 0);

    // The cleanup runs under the worker's own owner, each stretch of which
    // the definition's `timeoutMs` bounds. The sentinel stops it there and
    // the worker asks to retire; the server's watch of the owner's deadline,
    // a grace later, ends a worker whose sentinel could not.
    const grace_ns = server_main.ingress.analytics_drain.ownerOverrunGraceNs(
        harness.runtime_server.supervisor.hard_timeout_grace_ns,
    );
    const wait_ms = @as(u64, unowned_limit_ms) + @divFloor(grace_ns, std.time.ns_per_ms) + service_exit_slack_ms;
    try harness_mod.waitForWorkerOutOfService(&harness, worker, wait_ms);

    const next = try client.get("/finalization");
    try std.testing.expect(!token.eql(try tokenOf(&next)));
    var traces: [16]LaunchTrace = undefined;
    const launches = harness_mod.countLaunches(harness.takeLaunches(&traces), definition);
    try std.testing.expectEqual(@as(usize, 2), launches.published);
    try std.testing.expectEqual(@as(usize, 0), launches.failed);

    // The sentinel stopped the callback, so the worker left on its own
    // notice and was retired as recycled; the server's watch, which faults a
    // hung worker as a death, never had to act.
    const counters = try harness_mod.waitForRecycledRetirements(&harness, 1);
    try std.testing.expectEqual(@as(u64, 0), counters.retired_died);
}

test "a definition at the largest concurrency serves that many slow requests at once from one worker" {
    const configuration = try network_mod.configText(std.testing.allocator, &.{.{
        .name = "wide",
        .routes = &.{.{ .path = "/token", .entry = "./api/token.js" }},
        .concurrency = wide_concurrency,
    }});
    defer std.testing.allocator.free(configuration);
    var harness: Harness = undefined;
    try harness.init(.{ .config_source = configuration });
    defer harness.deinit();
    errdefer harness_mod.dumpZygoteTrace(&harness.spawned);
    const definition = try harness.definitionIndex("wide");

    var clients: [wide_clients]Client = undefined;
    var opened: usize = 0;
    defer for (clients[0..opened]) |*client| client.close();
    for (&clients) |*client| {
        client.* = try Client.open(&harness);
        opened += 1;
    }

    // The first request launches the worker; the slow ones then find it
    // ready with every slot free.
    const warm = try clients[0].get("/token");
    const token = try tokenOf(&warm);
    _ = try harness_mod.waitForSlotsHeld(&harness, definition, 0);

    // Each request awaits a timer. A worker that holds them all at once
    // answers every one about one timer later; slots taken in turns would
    // need two timers or more.
    var path_buffer: [32]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/token?ms={d}", .{slow_request_ms});
    var streams: [wide_clients][client_streams_max]u32 = undefined;
    const started_ns = try process.monotonicNowNs();
    for (&clients, &streams) |*client, *client_streams| {
        for (client_streams) |*stream| stream.* = try client.sendGet(path);
    }
    for (&clients, &streams) |*client, *client_streams| {
        for (client_streams) |stream| {
            const response = try client.readResponse(stream);
            try std.testing.expect(token.eql(try tokenOf(&response)));
        }
    }
    const wall_ns = (try process.monotonicNowNs()) - started_ns;
    if (wall_ns >= wide_wall_ns_max) {
        std.debug.print("{d} requests of {d} ms took {d} ms together\n", .{
            wide_concurrency,
            slow_request_ms,
            @divFloor(wall_ns, std.time.ns_per_ms),
        });
        return error.SlowRequestsNotConcurrent;
    }

    var traces: [16]LaunchTrace = undefined;
    const launches = harness_mod.countLaunches(harness.takeLaunches(&traces), definition);
    try std.testing.expectEqual(@as(usize, 1), launches.published);
    try std.testing.expectEqual(@as(usize, 0), launches.failed);
}

test "a worker past memory.high is ended by its sentinel and its request is recorded as a memory death" {
    const configuration = try memoryConfiguration();
    defer std.testing.allocator.free(configuration);
    var harness: Harness = undefined;
    try harness.init(.{ .config_source = configuration });
    defer harness.deinit();
    errdefer harness_mod.dumpZygoteTrace(&harness.spawned);
    var client = try Client.open(&harness);
    defer client.close();

    // The handler keeps every MiB it fills. Once the leaf's memory passes
    // `memory.high`, the kernel counts a `high` event, and the worker's
    // sentinel marks its page dead for memory and exits while the request is
    // in flight.
    const grown = try client.get("/memory?grow=1");
    try expectStatus(&grown, 502);
    _ = try expectServedAfterMemoryDeath(&client);
    try expectMemoryDeathRecords(&harness, 3);
    // A sentinel that missed the event would leave the worker to the
    // kernel's OOM kill at `memory.max`, whose line says `memory_max`.
    try expectMemoryEndings(&harness, .{ .memory_high = 1 });
}

test "a worker past memory.max is killed by the kernel and classified by its leaf's oom_kill" {
    const configuration = try memoryConfiguration();
    defer std.testing.allocator.free(configuration);
    var harness: Harness = undefined;
    try harness.init(.{ .config_source = configuration });
    defer harness.deinit();
    errdefer harness_mod.dumpZygoteTrace(&harness.spawned);
    const definition = try harness.definitionIndex("memory");
    var client = try Client.open(&harness);
    defer client.close();

    const warm = try client.get("/memory");
    const token = try tokenOf(&warm);
    const worker = try harness_mod.waitForSlotsHeld(&harness, definition, 0);

    // With `memory.high` lifted the sentinel sees no `high` event, and the
    // growing worker meets `memory.max`, where the kernel's OOM kill takes
    // every task of its leaf and counts `oom_kill` there. The worker's page
    // still says ready, so only that count can make the death a memory one.
    try harness_mod.liftMemoryHigh(worker);
    const grown = try client.get("/memory?grow=1");
    try expectStatus(&grown, 502);
    try std.testing.expect(!token.eql(try expectServedAfterMemoryDeath(&client)));
    try expectMemoryDeathRecords(&harness, 4);
    try expectMemoryEndings(&harness, .{ .memory_max = 1 });
}

/// The configuration of the memory tests: the growing route's definition at
/// `memory_limit_mib`, and another definition, which serves while a worker of
/// the first one dies. The caller owns it.
fn memoryConfiguration() ![]u8 {
    return network_mod.configText(std.testing.allocator, &.{
        .{
            .name = "memory",
            .routes = &.{.{ .path = "/memory", .entry = "./api/memory_grow.js" }},
            .memory_mib = memory_limit_mib,
        },
        .{
            .name = "token",
            .routes = &.{.{ .path = "/token", .entry = "./api/token.js" }},
        },
    });
}

/// After a memory death, a new worker serves the growing route and the other
/// definition serves as before. Returns the new worker's token.
fn expectServedAfterMemoryDeath(client: *Client) !Token {
    const next = try client.get("/memory");
    const token = try tokenOf(&next);
    const other = try client.get("/token");
    _ = try tokenOf(&other);
    return token;
}

/// Checks the record of the one request a memory death ended, among the
/// `requests` records the test's requests left: it answers 502 with error
/// code `memory` and the fault the lane saw the death by, the worker's exit
/// or its hang-up, and its usage is the floor the server read off the dead
/// worker's page.
fn expectMemoryDeathRecords(harness: *Harness, requests: usize) !void {
    var access = try waitForRecordLines(AccessLine, harness, "access.jsonl", requests);
    defer access.deinit();
    try std.testing.expectEqual(requests, access.items.len);
    const died = try soleAccessRecordWithStatus(access.items, 502);
    try std.testing.expectEqualStrings("/memory", died.route);
    try std.testing.expectEqualStrings("memory", died.error_code);
    if (!isDeathFault(died.worker_fault)) {
        std.debug.print("the death's access record names the worker fault {s}\n", .{died.worker_fault});
        return error.UnexpectedWorkerFault;
    }
    try expectUsage(died, .{ .origin = "server" });
}

/// The lines of `workers.jsonl` of workers that ended for memory, by who
/// stopped them.
const MemoryEndings = struct {
    /// `memory_high`: the worker's sentinel, past `memory.high`.
    memory_high: usize = 0,
    /// `memory_max`: the kernel's OOM kill at `memory.max`.
    memory_max: usize = 0,
};

/// Waits until `workers.jsonl` holds as many memory endings as `expected`
/// counts, which the reaper writes once it tore each worker down, and fails
/// with `error.UnexpectedMemoryEndings` when it holds others then.
fn expectMemoryEndings(harness: *Harness, expected: MemoryEndings) !void {
    var found: MemoryEndings = .{};
    for (0..record_polls_max) |_| {
        var lines = try waitForRecordLines(WorkerLine, harness, "workers.jsonl", 0);
        defer lines.deinit();
        found = .{};
        for (lines.items) |line| {
            if (std.mem.eql(u8, line.ending, "memory_high"))
                found.memory_high += 1;
            if (std.mem.eql(u8, line.ending, "memory_max"))
                found.memory_max += 1;
        }
        if (found.memory_high + found.memory_max >= expected.memory_high + expected.memory_max) break;
        std.Thread.sleep(record_poll_interval_ns);
    }
    if (std.meta.eql(found, expected)) return;
    std.debug.print("workers.jsonl holds {d} memory_high and {d} memory_max endings, not {d} and {d}\n", .{
        found.memory_high,
        found.memory_max,
        expected.memory_high,
        expected.memory_max,
    });
    return error.UnexpectedMemoryEndings;
}

/// Whether `label` names a fault by which a lane sees a worker die on its
/// own (`WorkerFaultReason.label` in `server/ingress/fault.zig`).
fn isDeathFault(label: []const u8) bool {
    if (std.mem.eql(u8, label, "exited")) return true;
    return std.mem.eql(u8, label, "peer_closed");
}

/// The one record of `records` with `status`. Fails with
/// `error.AccessRecordNotObserved` when none has it and with
/// `error.SeveralAccessRecords` when more than one does.
fn soleAccessRecordWithStatus(records: []const AccessLine, status: u16) !AccessLine {
    var found: ?AccessLine = null;
    for (records) |record| {
        if (record.status != status) continue;
        if (found != null) return error.SeveralAccessRecords;
        found = record;
    }
    return found orelse error.AccessRecordNotObserved;
}

const ExpectedUsage = struct {
    /// `worker` for the worker's own measures, `server` for a floor.
    origin: []const u8,
    cpu_ns_min: u64 = 0,
};

/// Checks the usage on `record`, the access record of a request the server
/// dispatched: who measured it and the CPU it holds.
fn expectUsage(record: AccessLine, expected: ExpectedUsage) !void {
    try std.testing.expectEqualStrings(expected.origin, record.origin orelse return error.UsageNotRecorded);
    const cpu_ns = record.cpu_ns orelse return error.UsageNotRecorded;
    if (cpu_ns < expected.cpu_ns_min) {
        std.debug.print("the access record holds {d} ns of CPU, less than {d}\n", .{ cpu_ns, expected.cpu_ns_min });
        return error.UsageCpuTooLow;
    }
}

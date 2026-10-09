//! Containment of shard failures, with threaded shard engines and the real shard supervisor
//! (`runtime/shard_flow.zig`) running inside a recording stand-in for the gateway loop that has no
//! worker endpoints. An error confined to one fetch fails only that fetch. Any other error
//! restarts only its shard and leaves the other shards alone; the restart fails the shard's
//! fetches except the replay-safe ones, which run again on the restarted engine under the request
//! and the policy entry their routes recorded, and a replay whose entry the table lacks fails
//! alone. A shard past its restart budget ends the gateway process. Cases cover a fault in the
//! middle of a collection pass, the restart budget, a shard at its memory budget, a fault that
//! escapes the owner loop, the grant a redispatch keeps, and a restart under the gateway's
//! seccomp filter in a forked child. The restart's steps without engine threads are covered in
//! `shard_lifecycle.zig`. Lane: egress-gateway-test.

const std = @import("std");
const gateway = @import("collo_egress_gateway");
const engine_test = @import("support/engine.zig");
const shard_flow = gateway.testing.shard_flow;
const control_flow = gateway.testing.control_flow;
const egress = @import("collo_egress_client");
const ipc = @import("collo_ipc");

const body_credit = egress.core.body_credit;

/// The security cell every route of these tests records.
const route_security_cell_id: gateway.policy.SecurityCellId = [_]u8{9} ** 16;

/// One connector thread, so each shard runs live engine threads as production
/// shards do: supervision and the memory budget must hold while those threads
/// run, which the engines without threads in `shard_lifecycle.zig` cannot show.
const threaded_config = gateway.engine.Config{
    .h2_connector_count = 1,
};

test "chaos: shard-fatal fault mid-collection contains to the shard and spares the neighbor" {
    PacketRecorder.reset();
    var chaos = try ChaosGateway.init(2, gateway.supervisor_limits.shard_memory.budget_bytes);
    defer chaos.deinit();
    const victim = chaos.shards.get(0);
    const neighbor = chaos.shards.get(1);

    // A is replay-safe on the victim shard: idempotent, without a body, and
    // nothing delivered. Its redispatch after the restart reaches the real
    // transport, so its origin is a loopback address, which every network
    // policy denies at once, without DNS or the network.
    try engine_test.injectActiveRequest(&victim.engine, 1, 1, 1, .{
        .url = "https://127.0.0.1:9/",
        .request_deadline_mono_ns = 777,
    });
    try chaos.recordRoute(1, 1, 1, 0);
    // B already delivered its head and has meters running, so the supervisor
    // must demote it with an error packet that carries those meters.
    try engine_test.injectActive(&victim.engine, 2, 2, 2);
    try engine_test.setActiveBodyEgressMeters(&victim.engine, 2, 2, 2, .{
        .billed_sent = 5,
        .billed_received = 7,
        .cost = 3,
    });
    try engine_test.appendReadyBodyChunk(&victim.engine, 2, 2, 2, "queued");
    try chaos.recordRoute(2, 2, 2, 0);
    // C completes in the pass that fails. A completed fetch has left the
    // active table, so the supervisor's partition never sees it, and only the
    // route-removal defer in `collectShardReady` removes its route once the
    // pass fails. Its task is done but the fetch is not terminal, so the head
    // publish sends the task's failure as an error packet and the fetch
    // retires in the same pass.
    try engine_test.injectActive(&victim.engine, 3, 3, 3);
    try engine_test.markActiveTaskDone(&victim.engine, 3, 3);
    try chaos.recordRoute(3, 3, 3, 0);
    // D is the neighbor shard's fetch, which must notice none of this.
    try engine_test.injectActive(&neighbor.engine, 4, 4, 4);
    try chaos.recordRoute(4, 4, 4, 1);

    // The ready queue is first in, first out: C completes first, then the
    // armed fault fires when the same collection pass reaches B.
    try engine_test.wakeActiveTask(&victim.engine, 3, 3, 3);
    try engine_test.wakeActiveTask(&victim.engine, 2, 2, 2);
    engine_test.armCollectFault(&victim.engine, 2, 2, error.InjectedShardFault);

    // The armed error leaves the collection pass undemoted, and the shard
    // supervisor restarts the shard.
    try std.testing.expect(try chaos.collectOrSupervise(0));

    // C completed in the failed pass, and its route is gone all the same.
    try std.testing.expect(chaos.router.routeForBody(3, 3, 3) == null);
    try std.testing.expect(PacketRecorder.findError(3, 3) != null);

    // The victim restarted exactly once; the neighbor never did.
    try std.testing.expectEqual(@as(u64, 1), victim.restarts);
    try std.testing.expectEqual(@as(u64, 0), neighbor.restarts);
    try std.testing.expectEqual(@as(u64, 0), victim.restart_backstop.trips);

    // B was demoted: its terminal error packet carries the meters of what was
    // delivered, its route is gone, and the shard's demotion count survived the
    // engine restart.
    const demoted = PacketRecorder.findError(2, 2) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 5), demoted.billed_sent_total);
    try std.testing.expectEqual(@as(u64, 7), demoted.billed_received_total);
    try std.testing.expectEqual(@as(u64, 3), demoted.cost_total);
    try std.testing.expect(chaos.router.routeForBody(2, 2, 2) == null);
    try std.testing.expectEqual(@as(u64, 1), engine_test.demotedFetchErrors(&victim.engine));

    // A was resubmitted on the restarted engine without its worker noticing:
    // the same identity is back in the cleared active table, its route still
    // names the same shard, and its worker got no error packet.
    try std.testing.expect(victim.engine.hasActiveBody(1, 1, 1));
    try std.testing.expectEqual(@as(usize, 1), engine_test.activeFetchCount(&victim.engine));
    const kept = chaos.router.routeForBody(1, 1, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), kept.record.shard_index);
    try std.testing.expect(PacketRecorder.findError(1, 1) == null);

    // D is untouched and completes through the normal retire path, which
    // removes its route; the gateway and both shards are still running.
    try std.testing.expect(neighbor.engine.hasActiveBody(4, 4, 4));
    try engine_test.markActiveTaskDone(&neighbor.engine, 4, 4);
    try engine_test.wakeActiveTask(&neighbor.engine, 4, 4, 4);
    try std.testing.expect(!try chaos.collectOrSupervise(1));
    try std.testing.expect(PacketRecorder.findError(4, 4) != null);
    try std.testing.expect(chaos.router.routeForBody(4, 4, 4) == null);
    try std.testing.expectEqual(@as(usize, 0), engine_test.activeFetchCount(&neighbor.engine));
}

test "chaos: fourth shard fault inside the window trips the backstop and propagates" {
    PacketRecorder.reset();
    var chaos = try ChaosGateway.init(2, gateway.supervisor_limits.shard_memory.budget_bytes);
    defer chaos.deinit();
    const victim = chaos.shards.get(0);

    // Each of the `max_restarts_in_window` faults inside the window restarts
    // the shard in place.
    for (0..gateway.supervisor_limits.shard_restart.max_restarts_in_window) |_|
        try chaos.superviseShardFailure(0, error.InjectedShardFault);
    try std.testing.expectEqual(@as(u64, 3), victim.restarts);
    try std.testing.expectEqual(@as(u64, 0), victim.restart_backstop.trips);

    // The next fault trips the backstop: the supervisor returns the original
    // cause, and the run loop returning it ends the gateway process.
    try std.testing.expectError(
        error.InjectedShardFault,
        chaos.superviseShardFailure(0, error.InjectedShardFault),
    );
    try std.testing.expectEqual(@as(u64, 3), victim.restarts);
    try std.testing.expectEqual(@as(u64, 1), victim.restart_backstop.trips);
    try std.testing.expectEqual(@as(u64, 0), chaos.shards.get(1).restarts);
}

test "chaos: shard memory budget storm is caught by rung one and the gateway survives" {
    PacketRecorder.reset();
    var chaos = try ChaosGateway.init(1, gateway.supervisor_limits.shard_memory.budget_bytes);
    defer chaos.deinit();
    const shard0 = chaos.shards.get(0);

    // A fetch in mid-stream whose next drain must allocate: two empty
    // credit-only chunks ahead of the data chunk give the drain three
    // credits, more than `PullCredits.inline_slots` in
    // `egress/core/body_settlement.zig` holds inline, so the drain allocates
    // its credit list on the heap and always hits the budget.
    try engine_test.injectActive(&shard0.engine, 1, 1, 1);
    try engine_test.appendReadyBodyChunkWithCredit(&shard0.engine, 1, 1, 1, "", body_credit.h2Data(1, 1, 1, false));
    try engine_test.appendReadyBodyChunkWithCredit(&shard0.engine, 1, 1, 1, "", body_credit.h2Data(1, 1, 2, false));
    try engine_test.appendReadyBodyChunkWithCredit(&shard0.engine, 1, 1, 1, "doomed", body_credit.h2Data(1, 1, 6, true));
    try chaos.recordRoute(1, 1, 1, 0);

    // The budget tightens to exactly the current live bytes, so the budget
    // refuses every further allocation on this shard.
    const tightened = shard0.memory.liveBytes();
    shard0.memory.setBudget(tightened);
    try engine_test.wakeActiveTask(&shard0.engine, 1, 1, 1);
    // `OutOfMemory` is demotable (`isFetchDemotableError` in `engine.zig`), so
    // the collection pass succeeds without supervision and fails only the
    // fetch that allocated.
    try std.testing.expect(!try chaos.collectOrSupervise(0));
    try std.testing.expectEqual(@as(u64, 1), engine_test.demotedFetchErrors(&shard0.engine));
    try std.testing.expectEqual(@as(u64, 0), shard0.restarts);
    try std.testing.expect(PacketRecorder.findError(1, 1) != null);
    // The budget held: nothing was admitted past it.
    try std.testing.expect(shard0.memory.liveBytes() <= tightened);

    // The gateway is still running: with the budget back to normal, the same
    // shard admits, completes and retires new work.
    shard0.memory.setBudget(gateway.supervisor_limits.shard_memory.budget_bytes);
    try engine_test.injectActive(&shard0.engine, 2, 2, 2);
    try chaos.recordRoute(2, 2, 2, 0);
    try engine_test.markActiveTaskDone(&shard0.engine, 2, 2);
    try engine_test.wakeActiveTask(&shard0.engine, 2, 2, 2);
    try std.testing.expect(!try chaos.collectOrSupervise(0));
    try std.testing.expect(PacketRecorder.findError(2, 2) != null);
    try std.testing.expect(chaos.router.routeForBody(2, 2, 2) == null);

    // The demoted fetch retires through the normal completion path once its
    // task settles, and that retirement removes its route.
    try engine_test.markActiveTaskDone(&shard0.engine, 1, 1);
    try engine_test.wakeActiveTask(&shard0.engine, 1, 1, 1);
    try std.testing.expect(!try chaos.collectOrSupervise(0));
    try std.testing.expect(chaos.router.routeForBody(1, 1, 1) == null);
    try std.testing.expectEqual(@as(usize, 0), engine_test.activeFetchCount(&shard0.engine));
    try std.testing.expectEqual(@as(u64, 0), engine_test.bodyCreditReleaseFailures(&shard0.engine));
}

test "chaos: owner-loop escape surfaces through collection and restarts the shard" {
    PacketRecorder.reset();
    var chaos = try ChaosGateway.init(2, gateway.supervisor_limits.shard_memory.budget_bytes);
    defer chaos.deinit();
    const victim = chaos.shards.get(0);

    // A replay-safe fetch on the victim, which the restart must carry onto the
    // restarted engine as it would for any other shard failure.
    try engine_test.injectActiveRequest(&victim.engine, 1, 1, 1, .{
        .url = "https://127.0.0.1:9/",
    });
    try chaos.recordRoute(1, 1, 1, 0);

    // The owner-fault latch models the owner loop dying on a watch-list
    // allocation that keeps failing at the budget. The pass returns an owner
    // fault after its fetches rather than through the demotion check, so even
    // as `OutOfMemory` it leaves the pass and drives the shard supervisor.
    engine_test.injectOwnerFault(&victim.engine, error.OutOfMemory);
    try std.testing.expect(try chaos.collectOrSupervise(0));
    try std.testing.expectEqual(@as(u64, 1), victim.restarts);
    try std.testing.expectEqual(@as(u64, 0), chaos.shards.get(1).restarts);

    // The replay-safe fetch was resubmitted, and its worker got no error.
    try std.testing.expect(victim.engine.hasActiveBody(1, 1, 1));
    try std.testing.expect(PacketRecorder.findError(1, 1) == null);

    // Taking the latch clears it and every start clears it too, so the
    // restarted engine collects cleanly.
    try std.testing.expect(!try chaos.collectOrSupervise(0));
}

test "chaos: a redispatched fetch keeps the request and the policy entry it was admitted under" {
    PacketRecorder.reset();
    var chaos = try ChaosGateway.init(2, gateway.supervisor_limits.shard_memory.budget_bytes);
    defer chaos.deinit();
    // Entry 1 lets plain HTTP through the scheme check and entry 0 does not, so the error that
    // ends a resubmitted plain-HTTP fetch names the entry it ran under.
    var table = gateway.policy.PolicyTable.single(gateway.policy.public_https);
    table.entries[1] = .{ .kind = .any_host, .allow_private_networks = true, .allow_http = true };
    table.count = 2;
    chaos.hello = helloFor(&table);
    const victim = chaos.shards.get(0);

    // Replay-safe and admitted under entry 1, which only its route records. Its loopback origin,
    // which every entry denies, settles it on the engine threads without DNS or the network.
    try engine_test.injectActiveRequest(&victim.engine, 1, 1, 1, .{
        .url = "http://127.0.0.1:9/",
        .request_id = 42,
        .request_generation = 7,
    });
    try chaos.recordRouteUnder(1, 1, 1, 0, 1);

    try chaos.superviseShardFailure(0, error.InjectedShardFault);
    try std.testing.expectEqual(@as(u64, 1), victim.restarts);
    try std.testing.expect(victim.engine.hasActiveBody(1, 1, 1));
    try std.testing.expect(PacketRecorder.findError(1, 1) == null);
    try std.testing.expectEqual(
        gateway.budgets.BudgetKey{ .session_id = 1, .request_id = 42, .request_generation = 7 },
        engine_test.activeFetchBudgetKey(&victim.engine, 1, 1, 1).?,
    );

    // Only the restarted engine's threads settle the resubmission. Under entry 0 the scheme
    // check would refuse it as PlainHttpFetchDisabled before the address check runs.
    const wait_start = try std.time.Instant.now();
    while (PacketRecorder.findError(1, 1) == null) {
        try std.testing.expect(!try chaos.collectOrSupervise(0));
        const now = try std.time.Instant.now();
        if (now.since(wait_start) > 5 * std.time.ns_per_s)
            return error.TestTimeout;
        std.Thread.sleep(std.time.ns_per_ms);
    }
    const failure = PacketRecorder.findError(1, 1).?;
    try std.testing.expect(std.mem.indexOf(u8, failure.message(), "EgressDenied") != null);
}

test "chaos: a replay whose route names an entry the table lacks fails only that fetch" {
    PacketRecorder.reset();
    var chaos = try ChaosGateway.init(1, gateway.supervisor_limits.shard_memory.budget_bytes);
    defer chaos.deinit();
    const victim = chaos.shards.get(0);

    // Two replay-safe fetches on one shard. Admission records only ids its table holds, so the
    // first route's entry 5, past a table of one entry, stands for an admission bug; the second
    // route names entry 0.
    try engine_test.injectActiveRequest(&victim.engine, 1, 1, 1, .{ .url = "https://127.0.0.1:9/" });
    try engine_test.setActiveBodyEgressMeters(&victim.engine, 1, 1, 1, .{
        .billed_sent = 5,
        .billed_received = 7,
        .cost = 3,
    });
    try chaos.recordRouteUnder(1, 1, 1, 0, 5);
    try engine_test.injectActiveRequest(&victim.engine, 1, 2, 2, .{ .url = "https://127.0.0.1:9/" });
    try chaos.recordRoute(1, 2, 2, 0);

    try chaos.superviseShardFailure(0, error.InjectedShardFault);
    try std.testing.expectEqual(@as(u64, 1), victim.restarts);
    try std.testing.expectEqual(@as(u64, 0), victim.restart_backstop.trips);

    // The first fails with an internal error carrying only the dead attempt's cost, and its
    // route goes.
    const failed = PacketRecorder.findError(1, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("egress internal error", failed.message());
    try std.testing.expectEqual(@as(u64, 3), failed.cost_total);
    try std.testing.expect(chaos.router.routeForBody(1, 1, 1) == null);
    try std.testing.expect(!victim.engine.hasActiveBody(1, 1, 1));

    // The second runs again on the restarted engine without its worker noticing.
    try std.testing.expect(victim.engine.hasActiveBody(1, 2, 2));
    try std.testing.expect(PacketRecorder.findError(1, 2) == null);
    try std.testing.expect(chaos.router.routeForBody(1, 2, 2) != null);
}

// The gateway seals itself with a filter that denies clone, clone3,
// io_uring_setup and io_uring_register once its threads exist
// (`sandbox.applySeccompAfterThreadsStarted`), so a shard restart must run on
// the threads and rings created at boot. The filter cannot be removed, so a
// forked child installs it and reports the step it reached as its exit
// status.
test "chaos: shard restart under the gateway seccomp filter reuses the shard's threads and serves again" {
    const pid = try std.posix.fork();
    if (pid == 0)
        std.os.linux.exit_group(@intFromEnum(restartUnderGatewaySeccomp()));
    const wait = std.posix.waitpid(pid, 0);
    try std.testing.expect(std.c.W.IFEXITED(wait.status));
    try std.testing.expectEqual(
        SeccompRestartOutcome.served_after_restart,
        @as(SeccompRestartOutcome, @enumFromInt(std.c.W.EXITSTATUS(wait.status))),
    );
}

/// The step the forked child of the seccomp restart test stopped at.
const SeccompRestartOutcome = enum(u8) {
    served_after_restart = 0,
    harness_init_failed = 1,
    no_new_privs_failed = 2,
    filter_install_failed = 3,
    filter_not_enforced = 4,
    thread_census_failed = 5,
    restart_failed = 6,
    thread_count_changed = 7,
    replay_not_resubmitted = 8,
    replay_not_served = 9,
    unexpected_supervision = 10,
    neighbor_disturbed = 11,
    _,
};

fn restartUnderGatewaySeccomp() SeccompRestartOutcome {
    const linux = std.os.linux;
    PacketRecorder.reset();
    var chaos = ChaosGateway.init(2, gateway.supervisor_limits.shard_memory.budget_bytes) catch
        return .harness_init_failed;
    defer chaos.deinit();
    const victim = chaos.shards.get(0);
    const neighbor = chaos.shards.get(1);

    // Replay-safe on the victim, so the restarted engine must run it. The
    // policy denies its loopback origin, which settles it on the engine
    // threads without DNS or the network.
    engine_test.injectActiveRequest(&victim.engine, 1, 1, 1, .{
        .url = "https://127.0.0.1:9/",
    }) catch return .harness_init_failed;
    chaos.recordRoute(1, 1, 1, 0) catch return .harness_init_failed;
    engine_test.injectActive(&neighbor.engine, 2, 2, 2) catch return .harness_init_failed;
    chaos.recordRoute(2, 2, 2, 1) catch return .harness_init_failed;

    // The order of `Gateway.run` in `runtime/root.zig`: every shard started,
    // then the filter. No-new-privileges stands in for `applyProcessBaseline`,
    // which also chroots and drops capabilities.
    if (linux.E.init(linux.prctl(@intFromEnum(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0)) != .SUCCESS)
        return .no_new_privs_failed;
    gateway.sandbox.applySeccompAfterThreadsStarted() catch return .filter_install_failed;
    // Without the filter both probes fail on their null arguments instead.
    if (linux.E.init(linux.syscall2(.clone3, 0, 0)) != .PERM or
        linux.E.init(linux.syscall2(.io_uring_setup, 0, 0)) != .PERM)
        return .filter_not_enforced;

    const threads_before = countProcessThreads() catch return .thread_census_failed;
    chaos.superviseShardFailure(0, error.InjectedShardFault) catch return .restart_failed;
    const threads_after = countProcessThreads() catch return .thread_census_failed;
    if (threads_after != threads_before)
        return .thread_count_changed;
    if (!victim.engine.hasActiveBody(1, 1, 1) or PacketRecorder.findError(1, 1) != null)
        return .replay_not_resubmitted;

    // Only the restarted engine's threads can settle the resubmitted fetch.
    const wait_start = std.time.Instant.now() catch return .replay_not_served;
    while (PacketRecorder.findError(1, 1) == null) {
        const supervised = chaos.collectOrSupervise(0) catch return .unexpected_supervision;
        if (supervised)
            return .unexpected_supervision;
        const now = std.time.Instant.now() catch return .replay_not_served;
        if (now.since(wait_start) > 5 * std.time.ns_per_s)
            return .replay_not_served;
        std.Thread.sleep(std.time.ns_per_ms);
    }
    if (chaos.router.routeForBody(1, 1, 1) != null or victim.restarts != 1)
        return .replay_not_served;
    if (neighbor.restarts != 0 or !neighbor.engine.hasActiveBody(2, 2, 2))
        return .neighbor_disturbed;
    return .served_after_restart;
}

fn countProcessThreads() !usize {
    var tasks = try std.fs.openDirAbsolute("/proc/self/task", .{ .iterate = true });
    defer tasks.close();
    var iterator = tasks.iterate();
    var count: usize = 0;
    while (try iterator.next()) |_|
        count += 1;
    return count;
}

/// A stand-in for the gateway loop with a real shard set, a real router and
/// the real shard flow (`shard_flow.Methods`: the collection pass, the shard
/// supervisor and the resubmission); only publication to workers is replaced,
/// by the recording stubs below. Everything allocates from
/// `std.testing.allocator`, so every case is also a leak check.
const ChaosGateway = struct {
    allocator: std.mem.Allocator,
    shards: gateway.shard_set.Set = .{},
    router: gateway.router.Router = .{},
    completed_fetches: std.array_list.Aligned(gateway.active_fetch.WorkerScopedFetch, null) = .empty,
    coalesce_completion_notifies: bool = false,
    scratch: []u8,
    /// What the server's hello brought, of which the supervisor's redispatch reads the policy
    /// table and each entry's isolation id: the one-entry table, unless a test installs another.
    hello: control_flow.HelloState,

    const ShardFlow = shard_flow.Methods(ChaosGateway);
    pub const collectShardReady = ShardFlow.collectShardReady;
    pub const superviseShardFailure = ShardFlow.superviseShardFailure;
    pub const redispatchReplayFetch = ShardFlow.redispatchReplayFetch;

    fn init(shard_count: usize, memory_budget_bytes: u64) !ChaosGateway {
        const table = gateway.policy.PolicyTable.single(gateway.policy.public_https);
        var chaos = ChaosGateway{
            .allocator = std.testing.allocator,
            .scratch = try std.testing.allocator.alloc(u8, ipc.max_message_bytes),
            .hello = helloFor(&table),
        };
        errdefer chaos.deinit();
        chaos.shards = try gateway.shard_set.Set.init(
            std.testing.allocator,
            shard_count,
            threaded_config,
            memory_budget_bytes,
        );
        try chaos.shards.startAll(
            null,
            recordingPacketSender,
            countingBodyChunkBatchSender,
            unboundedPressureProbe,
            ignoringFaultReporter,
        );
        return chaos;
    }

    fn deinit(self: *ChaosGateway) void {
        self.shards.deinit(self.allocator);
        self.router.deinit(self.allocator);
        self.completed_fetches.deinit(self.allocator);
        self.allocator.free(self.scratch);
    }

    /// What `Gateway.run` in `runtime/root.zig` does with a ready shard: an
    /// error the collection pass returns, which the engine did not demote,
    /// goes to the shard supervisor. Returns whether the supervisor ran, so a
    /// test can tell a demoted fetch from a restarted shard.
    fn collectOrSupervise(self: *ChaosGateway, shard_index: usize) !bool {
        self.collectShardReady(shard_index) catch |err| {
            try self.superviseShardFailure(shard_index, err);
            return true;
        };
        return false;
    }

    /// The route admission records for a fetch on `shard_index` admitted under the table's
    /// `public_https_id` entry.
    fn recordRoute(
        self: *ChaosGateway,
        worker_session_id: u64,
        fetch_id: u64,
        body_id: u64,
        shard_index: usize,
    ) !void {
        try self.recordRouteUnder(
            worker_session_id,
            fetch_id,
            body_id,
            shard_index,
            gateway.policy.public_https_id,
        );
    }

    /// `recordRoute` for a fetch admitted under table entry `policy_id`.
    fn recordRouteUnder(
        self: *ChaosGateway,
        worker_session_id: u64,
        fetch_id: u64,
        body_id: u64,
        shard_index: usize,
        policy_id: u16,
    ) !void {
        try self.router.record(self.allocator, .{
            .worker_session_id = worker_session_id,
            .fetch_id = fetch_id,
            .body_id = body_id,
        }, .{
            .shard_index = shard_index,
            .security_cell_id = route_security_cell_id,
            .policy_id = policy_id,
        });
    }

    // What the shard flow calls on its gateway. The real `removeRoute` lives
    // in `runtime/worker_flow.zig` and the real publication in
    // `runtime/shard_flow.zig`, where it writes into worker endpoints; these
    // keep the router consistent and record the packets.
    pub fn removeRoute(self: *ChaosGateway, key: gateway.router.RouteKey) void {
        _ = self.router.remove(self.allocator, key);
    }

    pub fn flushCompletionNotifies(self: *ChaosGateway) void {
        // Worker completion eventfds do not exist in this harness.
        _ = self;
    }

    pub fn queuePacket(self: *ChaosGateway, worker_session_id: u64, bytes: []const u8) !void {
        _ = self;
        PacketRecorder.record(worker_session_id, bytes);
    }
};

/// The state the gateway's control flow keeps after a hello carrying `table`: each entry's
/// isolation id folds the gateway's limits into the entry, as `runtime/control_flow.zig` computes
/// it when the hello arrives.
fn helloFor(table: *const gateway.policy.PolicyTable) control_flow.HelloState {
    var hello: control_flow.HelloState = .{
        .received = true,
        .key = .{ .bytes = @splat(0x6b) },
        .policies = table.*,
    };
    const limits_id = gateway.policy.policyIsolationId(gateway.policy.production);
    for (table.slice(), 0..) |entry, index| {
        hello.isolation_ids[index] =
            gateway.policy.networkPolicyIsolationId(limits_id, @intCast(index), entry);
    }
    return hello;
}

/// Packets meant for workers, recorded by session and fetch so every case can
/// attribute error packets, their messages and meters. Only the test's thread
/// touches it: packets are published during collection and supervision, on
/// the thread that stands in for the gateway loop, and never by an engine
/// thread.
const PacketRecorder = struct {
    const Entry = struct {
        worker_session_id: u64,
        fetch_id: u64,
        body_id: u64,
        billed_sent_total: u64,
        billed_received_total: u64,
        cost_total: u64,
        message_bytes: [message_bytes_max]u8,
        message_len: usize,

        fn message(self: *const Entry) []const u8 {
            return self.message_bytes[0..self.message_len];
        }
    };

    const message_bytes_max: usize = 64;

    var errors: [16]Entry = undefined;
    var error_count: usize = 0;
    var other_packets: usize = 0;

    fn reset() void {
        error_count = 0;
        other_packets = 0;
    }

    fn record(worker_session_id: u64, bytes: []const u8) void {
        if (bytes.len >= @sizeOf(u32)) {
            const kind = ipc.decodeMessageKind(ipc.packet.readStruct(u32, bytes[0..@sizeOf(u32)])) catch return;
            if (kind == .egress_fetch_error) {
                const view = ipc.decodeEgressFetchError(bytes) catch return;
                if (error_count < errors.len) {
                    const message_len = @min(view.message.len, message_bytes_max);
                    errors[error_count] = .{
                        .worker_session_id = worker_session_id,
                        .fetch_id = view.fetch_id,
                        .body_id = view.body_id,
                        .billed_sent_total = view.billed_sent_total,
                        .billed_received_total = view.billed_received_total,
                        .cost_total = view.cost_total,
                        .message_bytes = undefined,
                        .message_len = message_len,
                    };
                    @memcpy(errors[error_count].message_bytes[0..message_len], view.message[0..message_len]);
                    error_count += 1;
                }
                return;
            }
        }
        other_packets += 1;
    }

    fn findError(worker_session_id: u64, fetch_id: u64) ?Entry {
        for (errors[0..error_count]) |entry| {
            if (entry.worker_session_id == worker_session_id and entry.fetch_id == fetch_id)
                return entry;
        }
        return null;
    }
};

fn recordingPacketSender(ctx: ?*anyopaque, worker_session_id: u64, bytes: []const u8) anyerror!void {
    _ = ctx;
    PacketRecorder.record(worker_session_id, bytes);
}

fn countingBodyChunkBatchSender(
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
    // One pool extent per payload, as an unfragmented pool gives: a payload
    // lands in one contiguous run of blocks.
    return chunks.len;
}

fn unboundedPressureProbe(ctx: ?*anyopaque, worker_session_id: u64) gateway.policy.WorkerPressure {
    _ = ctx;
    _ = worker_session_id;
    return .{ .pool_free_bytes = std.math.maxInt(usize) };
}

fn ignoringFaultReporter(ctx: ?*anyopaque, worker_session_id: u64, reason: []const u8) void {
    _ = ctx;
    _ = worker_session_id;
    _ = reason;
}

//! The launcher (`server/supervisor/launcher.zig`) against a stand-in
//! zygote and a stand-in supervisor and gateway: a submission claims a
//! launch through `Deps.claim`, the fork request goes out with the cgroup leaf
//! the launcher made, WorkerInit carries the egress session and a boot token
//! minted under the key of the session's gateway with the child window as its
//! deadline, and the ready worker reaches `Deps.publish` with its session and
//! its trace while `Deps.egressBootEnded` ends its boot token. Each way a
//! launch fails reaches `Deps.failed` with its reason and the child and leaf
//! it leaves behind, the child still running, because the launcher kills no
//! worker and waits for no exit. After a publish the launcher claims again, so
//! waiters the new worker could not serve get a launch without another
//! submission. A failed launch's leftovers keep their room in the launch
//! table until the reaper calls `leftoversReaped`. A zygote that misses a fork
//! reply is killed, and the zygote's exit reaches `Deps.zygoteExited`. The
//! launch failure tables are pinned.
//!
//! A lost gateway (`Launcher.gatewayLost`) has the launcher bring up the next
//! one (`Deps.egressPrewarm`, `Deps.egressCurrentGeneration`) and attach
//! every worker of another gateway to it: a new session from
//! `Deps.attachEgress`, written into the worker's record
//! (`Deps.setWorkerEgress`) before the `egress_attach` packet that carries it
//! leaves on the worker's control socket. A refused session, or a packet the
//! worker's socket refuses or takes nothing of within
//! `egress_attach_send_timeout_ms`, sends the worker to
//! `Deps.retireForEgress`. A gateway that fails under an attach, and dups the
//! server could not make, leave the worker detached on its old session, and
//! the pass runs again, no sooner than `egress_prewarm_interval_ms` after the
//! last spawn. A session the gateway removed (`Launcher.egressSessionLost`)
//! takes its worker off it (`Deps.dropEgressSession`), and a pass attaches it
//! to that gateway again, at most once per interval; a launch holding it gets
//! another before its publish, and a report no one holds starts nothing. No
//! spawn runs while a fork request is outstanding, a late report of an older
//! gateway's loss starts none, and a launch whose gateway is gone by
//! `WorkerReady` is attached to the next one before its publish. A launch
//! whose attach fails under the gateway, or that comes while the pass waits
//! to spawn one, boots detached, and a `WorkerReady` read after a gateway call
//! held the launcher past the child window still publishes. A definition
//! without a grant launches with no session. Lane `server-supervisor-test`.
//!
//! The stand-in zygote is a thread of the test that serves the launcher's end
//! of a socket pair as the zygote's fork loop does, answering each fork
//! request as the test scripts it: a refusal, no reply at all, or a child
//! cloned into the leaf the request carries, at once or once the test
//! releases it, whose init socket and pidfd go back in the reply and whose
//! part of WorkerInit the stand-in then plays. The child holds its end of the
//! init socket until it dies, as a worker does, so a child that dies before
//! `WorkerReady` hangs the socket up before its pidfd turns readable.
//! The zygote's own process is a child that only waits to be killed. Claims
//! come from grants the test makes, or from a real pool when the test needs
//! the pool's rule for growth. The board's gateway hands out sessions of one
//! generation at a time, each generation with a fixed key, and its live
//! workers stand for published records, each with both ends of a control
//! socket, so a reattach needs no child. A clone into a leaf needs the
//! delegated cgroup subtree that `wsl-config run` provides, so the tests that
//! make a leaf skip without it; a leaf the launcher cannot configure, a
//! reattach and the zygote's exit need none. Real zygotes and workers launch
//! in `zygote-integration` and `local-e2e`, which also kills a real gateway
//! under a live worker.

const std = @import("std");
const supervision = @import("collo_server_supervisor");
const lifecycle = @import("collo_server_lifecycle");
const zygote = @import("collo_zygote");
const host = @import("collo_host");
const ipc = @import("collo_ipc");
const cgroup = @import("collo_cgroup");
const fd_mod = @import("collo_os").fd;
const process = @import("collo_os").process;
const process_limits = @import("collo_limits").process;
const egress_policy = @import("collo_egress_gateway").policy;
const fixture = @import("supervisor_fixture");

const egress_token = ipc.egress_token;
const launcher_mod = supervision.launcher;
const pool = supervision.pool;
const worker_table = supervision.worker_table;
const testing = std.testing;
const DefinitionIndex = launcher_mod.DefinitionIndex;
const LaunchFailure = launcher_mod.LaunchFailure;
const LaunchTrace = launcher_mod.LaunchTrace;

/// Bounds each wait for work the launcher or the stand-in does at once: a
/// launch is local work that takes milliseconds.
const wait_bound_ns: u64 = 5 * std.time.ns_per_s;
/// How long a stand-in poll waits before it looks at its stop flag again.
const stand_in_poll_ms: i32 = 20;
/// The launches each pool can have in flight; the launch table holds that
/// many for every definition, as the service sizes it.
const launches_per_definition_max = supervision.scheduler_limits.capacity.pool_cold_starts_in_flight_max;
/// The launch table of every harness: room for the launches the fixture's
/// pools can have in flight together.
const launch_table_len = fixture.definition_names.len * launches_per_definition_max;
/// Launches one test makes at most: a table full of failed launches and one
/// more.
const launches_max = launch_table_len + 1;
/// Every launch here is for the fixture's default definition.
const launch_definition: DefinitionIndex = fixture.default_definition;
/// The generation of the board's gateway until a test loses it; each later
/// gateway takes the next number, as the manager numbers its spawns.
const test_gateway_generation: u64 = 1;
/// Published workers one test hands the board's stand-in supervisor at most.
const live_workers_max: usize = 4;
/// Sessions the board's gateway hands out in one test at most: one per
/// launch and a few reattaches of each live worker.
const sessions_max: usize = launches_max + 4 * live_workers_max;
/// Reattach targets one test hands out at most. A pass that asked for more
/// would never end, so the board fails the test instead.
const reattach_targets_max: usize = 4 * live_workers_max;
/// `egress_attach` packets one worker takes in one test at most.
const attach_log_max: usize = 4;
/// Gateway spawns whose time the board keeps.
const prewarms_max: usize = 8;
/// Attaches whose start the board keeps.
const attach_stamps_max: usize = 8;
/// A definition the board never grants a launch: a submission for it shows
/// that the launcher thread started a turn, and nothing else.
const probe_definition: DefinitionIndex = fixture.definition_names.len - 1;
const prewarm_interval_ns: u64 = @as(u64, @intCast(launcher_mod.egress_prewarm_interval_ms)) * std.time.ns_per_ms;
const attach_send_timeout_ns: u64 = @as(u64, @intCast(launcher_mod.egress_attach_send_timeout_ms)) * std.time.ns_per_ms;
const fork_reply_timeout_ns: u64 = @as(u64, @intCast(launcher_mod.fork_reply_timeout_ms)) * std.time.ns_per_ms;
const child_window_ns: u64 = @as(u64, @intCast(launcher_mod.child_window_ms)) * std.time.ns_per_ms;
const exit_wait_ns: u64 = @as(u64, @intCast(process_limits.PROCESS_EXIT_WAIT_MS)) * std.time.ns_per_ms;
/// Covers a poll timeout rounded to whole milliseconds.
const window_slack_ns: u64 = 10 * std.time.ns_per_ms;

test "the launcher waits for a fork reply as long as the zygote's own bound and for a child as long as its init window" {
    try testing.expectEqual(zygote.host_client.fork_reply_timeout_ms, launcher_mod.fork_reply_timeout_ms);
    try testing.expectEqual(process_limits.WORKER_INIT_TIMEOUT_MS, launcher_mod.child_window_ms);
}

test "every host launch error maps to the launch failure that names it" {
    inline for (@typeInfo(host.launch.LaunchError).error_set.?) |member| {
        const err = @field(host.launch.LaunchError, member.name);
        try testing.expectEqual(comptime failureFor(member.name), LaunchFailure.fromLaunchError(err));
    }
}

test "only a zygote that died or stopped answering ends every later launch" {
    for (std.enums.values(LaunchFailure)) |failure| {
        const ends = switch (failure) {
            .zygote_died, .fork_reply_timeout => true,
            else => false,
        };
        try testing.expectEqual(ends, failure.endsZygote());
    }
}

test "a cgroup leaf the launcher cannot configure fails the launch before any fork request" {
    var harness: Harness = undefined;
    try harness.init(.{ .root = .plain_directory });
    defer harness.deinit();

    // The root sits on a plain directory: the leaf's mkdir works, but the
    // leaf has none of cgroupfs's control files, so writing its limits fails
    // and `createWorkerDir` removes the leaf it made.
    harness.board.grantClaims(launch_definition, 1);
    harness.launcher.submit(launch_definition, .waiter);
    try harness.board.waitFor(.failed, 1, wait_bound_ns);
    harness.quiesce();

    const board = &harness.board;
    try board.expectNoFailure();
    const failed = &board.failed[0];
    try testing.expectEqual(LaunchFailure.cgroup_leaf, failed.failure);
    try testing.expectEqual(launch_definition, failed.definition);
    try testing.expectEqual(board.claims[0].ticket, failed.ticket);
    try testing.expect(!failed.leftovers.holdsChild());
    try testing.expectEqual(@as(usize, 0), board.attaches);
    try testing.expectEqual(@as(usize, 0), board.fork_requests);
    try testing.expectEqual(@as(usize, 0), board.published_len);
    try harness.expectNoWorkerLeaf();
}

test "a submitted launch claims once, forks once into its leaf and publishes the ready worker with its session and trace" {
    var harness: Harness = undefined;
    try harness.init(.{ .root = .delegated });
    defer harness.deinit();

    harness.board.script(&.{.ready});
    harness.board.grantClaims(launch_definition, 1);
    harness.launcher.submit(launch_definition, .waiter);
    try harness.board.waitFor(.published, 1, wait_bound_ns);
    harness.quiesce();

    const board = &harness.board;
    try board.expectNoFailure();
    try testing.expectEqual(@as(usize, 1), board.claims_len);
    try testing.expectEqual(@as(usize, 1), board.fork_requests);
    try testing.expectEqual(@as(usize, 1), board.fork_requests_with_leaf);
    try testing.expectEqual(@as(usize, 0), board.failed_len);
    const published = &board.published[0];
    try testing.expectEqual(launch_definition, published.definition);
    try testing.expectEqual(board.claims[0].ticket, published.ticket);

    // The handle is the child the stand-in cloned, with the session the
    // attach handed out and a send scratch of a whole message.
    const child = &board.children[0];
    try testing.expectEqual(@as(u32, @intCast(child.pid)), published.worker.handle.pid);
    try testing.expectEqual(child.pid, try pidOfPidFd(published.worker.handle.pidfd));
    try testing.expectEqual(test_gateway_generation, published.worker.egress_generation);
    try testing.expectEqual(board.attached_session_id, published.worker.egress_session_id);
    try testing.expectEqual(ipc.max_message_bytes, published.worker.dispatch_send_scratch.len);

    // WorkerInit carried the definition's route table and pack, the files
    // the server built at boot, with the definition's realm mode, and the
    // leaf the child was born in, and the handle cleans that same leaf.
    const routes = &harness.routes.?.routes;
    const artifact = routes.artifact(launch_definition);
    const init_routes = board.init_routes;
    try testing.expect(init_routes.serves_routes);
    try testing.expectEqual(routes.definition(launch_definition).settings.isolate_realm, init_routes.isolate_realm);
    try testing.expectEqual(artifact.route_table.blob_len, init_routes.table_len);
    try testing.expectEqual(try inodeOf(artifact.route_table.fd), init_routes.table_inode);
    try testing.expectEqual(try inodeOf(artifact.module_pack.fd()), init_routes.pack_inode);
    var leaf_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const leaf = try harness.leafPath(&leaf_buffer, child.fork_job_id);
    try testing.expectEqualStrings(leaf, board.initLeaf());
    try testing.expectEqualStrings(leaf, published.worker.handle.cgroup_dir);

    // The launcher makes the server's end of the control socket nonblocking
    // once, for the worker's life, so no lane does it per dispatch.
    try testing.expect(try isNonblocking(published.worker.handle.control_fd));

    // The trace orders the launch's steps, each stamped.
    var traces: [launches_max]LaunchTrace = undefined;
    try testing.expectEqual(@as(usize, 1), harness.launcher.takeTraces(&traces));
    const trace = traces[0];
    try testing.expectEqual(LaunchTrace.Outcome.published, trace.outcome);
    try testing.expectEqual(@as(?LaunchFailure, null), trace.failure);
    try testing.expectEqual(@as(u32, @intCast(child.pid)), trace.pid);
    const steps = [_]u64{
        trace.submitted_ns, trace.claimed_ns,        trace.fork_sent_ns, trace.fork_reply_ns,
        trace.init_sent_ns, trace.ready_received_ns, trace.published_ns,
    };
    for (steps, 0..) |stamp, index| {
        try testing.expect(stamp != 0);
        if (index != 0) try testing.expect(steps[index - 1] <= stamp);
    }
    try testing.expect(board.answered_ns <= trace.ready_received_ns);

    const counters = harness.launcher.countersSnapshot();
    try testing.expectEqual(@as(u64, 1), counters.submitted_waiter);
    try testing.expectEqual(@as(u64, 1), counters.claimed);
    try testing.expectEqual(@as(u64, 1), counters.published);
    try testing.expectEqual(@as(u64, 0), counters.failed);
}

test "the launcher claims again after a publish while waiters remain, so one submission gives two waiters at concurrency 1 a worker each" {
    // One slot per worker and one launch in flight at a time, so the pool
    // can grant the second waiter's launch only once the first worker is
    // published.
    const limits: fixture.RoutesOptions = .{ .concurrency = 1 };
    var definition_pool: DefinitionPool = undefined;
    try definition_pool.init(testing.allocator, .{
        .concurrency = limits.concurrency,
        .workers_max = 2,
        .launches_max = 1,
        .waiters_max = 2,
    });
    defer definition_pool.deinit();
    var harness: Harness = undefined;
    try harness.init(.{ .root = .delegated, .limits = limits, .pool = &definition_pool });
    defer harness.deinit();

    harness.board.script(&.{ .ready, .ready });
    // Two requests wait with deadlines that never pass, and one submission
    // asks for their workers.
    for (0..2) |request| {
        const key: lifecycle.RequestKey = .{ .lane_id = 0, .slot = @intCast(request), .generation = 1 };
        try testing.expect(definition_pool.acquire(0, key, std.math.maxInt(u64)) == .wait);
    }
    harness.launcher.submit(launch_definition, .waiter);
    try harness.board.waitFor(.published, 2, wait_bound_ns);
    harness.quiesce();

    const board = &harness.board;
    try board.expectNoFailure();
    try testing.expectEqual(@as(usize, 2), board.claims_len);
    try testing.expectEqual(@as(usize, 2), board.fork_requests);
    try testing.expectEqual(@as(usize, 0), board.failed_len);
    for (board.published[0..board.published_len]) |*published|
        try testing.expectEqual(@as(usize, 1), published.handoffs);
    const pool_state = definition_pool.snapshot();
    try testing.expectEqual(@as(u32, 0), pool_state.waiters);
    try testing.expectEqual(@as(u32, 2), pool_state.workers_live);

    // The second launch was claimed after the first worker was published,
    // and no submission dates it.
    var traces: [launches_max]LaunchTrace = undefined;
    try testing.expectEqual(@as(usize, 2), harness.launcher.takeTraces(&traces));
    try testing.expect(traces[0].submitted_ns != 0);
    try testing.expect(traces[0].published_ns <= traces[1].claimed_ns);
    try testing.expectEqual(@as(u64, 0), traces[1].submitted_ns);
    const counters = harness.launcher.countersSnapshot();
    try testing.expectEqual(@as(u64, 1), counters.submitted_waiter);
    try testing.expectEqual(@as(u64, 2), counters.claimed);
    try testing.expectEqual(@as(u64, 2), counters.published);
    try testing.expectEqual(@as(u64, 0), counters.deferred);
}

test "a child that reports init failure fails the launch and is handed over alive, with its leaf, for the reaper" {
    var harness: Harness = undefined;
    try harness.init(.{ .root = .delegated });
    defer harness.deinit();

    harness.board.script(&.{.init_failed});
    harness.board.grantClaims(launch_definition, 1);
    harness.launcher.submit(launch_definition, .waiter);
    try harness.board.waitFor(.failed, 1, wait_bound_ns);
    harness.quiesce();

    const board = &harness.board;
    try board.expectNoFailure();
    const failed = &board.failed[0];
    try testing.expectEqual(LaunchFailure.worker_init_failed, failed.failure);
    try testing.expectEqual(board.claims[0].ticket, failed.ticket);
    try testing.expectEqual(@as(usize, 0), board.published_len);
    try harness.expectChildHandedOverAlive(failed, 0);
    // The launcher waits for no exit: the failure reached its dependents
    // well before the bound a wait for the child's own exit would take.
    try testing.expect(failed.at_ns -| board.answered_ns < exit_wait_ns);

    var traces: [launches_max]LaunchTrace = undefined;
    try testing.expectEqual(@as(usize, 1), harness.launcher.takeTraces(&traces));
    try testing.expectEqual(LaunchTrace.Outcome.failed, traces[0].outcome);
    try testing.expectEqual(@as(?LaunchFailure, .worker_init_failed), traces[0].failure);
    try testing.expectEqual(@as(u32, @intCast(board.children[0].pid)), traces[0].pid);
    try testing.expect(traces[0].init_sent_ns != 0);
    try testing.expectEqual(@as(u64, 0), traces[0].published_ns);
}

test "a fork the zygote refuses fails the launch with its leaf for the reaper, and the next submission forks again" {
    var harness: Harness = undefined;
    try harness.init(.{ .root = .delegated });
    defer harness.deinit();

    harness.board.script(&.{ .refuse, .ready });
    harness.board.grantClaims(launch_definition, 1);
    harness.launcher.submit(launch_definition, .waiter);
    try harness.board.waitFor(.failed, 1, wait_bound_ns);
    // A failed launch starts no other by itself; the next one waits for a
    // submission.
    harness.board.grantClaims(launch_definition, 1);
    harness.launcher.submit(launch_definition, .waiter);
    try harness.board.waitFor(.published, 1, wait_bound_ns);
    harness.quiesce();

    const board = &harness.board;
    try board.expectNoFailure();
    try testing.expectEqual(@as(usize, 2), board.fork_requests);
    try testing.expect(board.fork_job_ids[0] != board.fork_job_ids[1]);
    const failed = &board.failed[0];
    try testing.expectEqual(LaunchFailure.fork_refused, failed.failure);
    try testing.expectEqual(board.claims[0].ticket, failed.ticket);
    // No child exists for a refused fork, but the leaf made for it does.
    try testing.expect(!failed.leftovers.child.pidfd.isValid());
    try harness.expectLeaf(&failed.leftovers.child.cgroup_dir, board.fork_job_ids[0]);
    try testing.expectEqual(@as(usize, 1), board.published_len);
    try testing.expectEqual(board.claims[1].ticket, board.published[0].ticket);
}

test "a launch table full of failed launches' leftovers holds back a claim until the reaper calls leftoversReaped, and the claim then forks" {
    var harness: Harness = undefined;
    try harness.init(.{ .root = .delegated });
    defer harness.deinit();

    // Every launch the table holds fails and leaves its leaf, and the board
    // grants one launch more.
    const answers = [_]Answer{.refuse} ** launch_table_len ++ [_]Answer{.ready};
    harness.board.script(&answers);
    harness.board.grantClaims(launch_definition, launches_max);
    harness.launcher.submit(launch_definition, .waiter);
    try harness.board.waitFor(.failed, launch_table_len, wait_bound_ns);
    // Each failure ended a launch but kept its room for the leaf, so no
    // claim followed any of them.
    try testing.expectEqual(launch_table_len, harness.board.count(.claims));
    try testing.expectEqual(launch_table_len, harness.board.count(.fork_requests));

    // The test plays the reaper for the first failure's leftovers, its leaf.
    var leftovers = harness.board.takeLeftovers(0);
    const held_leaf = leftovers.holdsChild();
    leftovers.child.reap();
    try testing.expect(held_leaf);
    const reaped_ns = process.monotonicNowNsOrZero();
    harness.launcher.leftoversReaped();
    try harness.board.waitFor(.published, 1, wait_bound_ns);
    harness.quiesce();

    const board = &harness.board;
    try board.expectNoFailure();
    try testing.expectEqual(launches_max, board.claims_len);
    try testing.expectEqual(launches_max, board.fork_requests);
    try testing.expectEqual(board.claims[launch_table_len].ticket, board.published[0].ticket);
    var traces: [launches_max]LaunchTrace = undefined;
    try testing.expectEqual(launches_max, harness.launcher.takeTraces(&traces));
    const last = traces[launch_table_len];
    try testing.expectEqual(LaunchTrace.Outcome.published, last.outcome);
    try testing.expect(reaped_ns <= last.claimed_ns);
    // The claim the full table held back still dates from the submission.
    try testing.expectEqual(traces[0].submitted_ns, last.submitted_ns);
    const counters = harness.launcher.countersSnapshot();
    try testing.expectEqual(@as(u64, 1), counters.deferred);
    try testing.expectEqual(@as(u64, launch_table_len), counters.failed);
}

test "a child that exits before WorkerReady fails the launch at once instead of at the end of its window" {
    var harness: Harness = undefined;
    try harness.init(.{ .root = .delegated });
    defer harness.deinit();

    harness.board.script(&.{.child_exits});
    harness.board.grantClaims(launch_definition, 1);
    harness.launcher.submit(launch_definition, .waiter);
    try harness.board.waitFor(.failed, 1, wait_bound_ns);
    harness.quiesce();

    const board = &harness.board;
    try board.expectNoFailure();
    const failed = &board.failed[0];
    // The child's exit hung up its init socket before its pidfd turned
    // readable, and an init socket that ends without an outcome is the
    // child's exit, not a broken protocol.
    try testing.expectEqual(LaunchFailure.worker_init_failed, failed.failure);
    try testing.expect(failed.leftovers.child.pidfd.isValid());
    try testing.expect(try process.waitForPidFdExit(
        failed.leftovers.child.pidfd.fd(),
        @intCast(process_limits.PROCESS_EXIT_WAIT_MS),
    ));
    try harness.expectLeaf(&failed.leftovers.child.cgroup_dir, board.children[0].fork_job_id);
    // The child's exit ended the wait, not the window.
    try testing.expect(failed.at_ns -| board.answered_ns < child_window_ns);
}

test "an egress session the gateway refuses fails the launch before the fork, with its leaf for the reaper" {
    var harness: Harness = undefined;
    try harness.init(.{ .root = .delegated });
    defer harness.deinit();

    harness.board.refuseAttach();
    harness.board.grantClaims(launch_definition, 1);
    harness.launcher.submit(launch_definition, .waiter);
    try harness.board.waitFor(.failed, 1, wait_bound_ns);
    harness.quiesce();

    const board = &harness.board;
    try board.expectNoFailure();
    const failed = &board.failed[0];
    try testing.expectEqual(LaunchFailure.egress_attach, failed.failure);
    try testing.expectEqual(@as(usize, 1), board.attaches);
    // The launch gets everything the fork needs before it forks, so a
    // refused session costs no child.
    try testing.expectEqual(@as(usize, 0), board.fork_requests);
    try testing.expect(!failed.leftovers.child.pidfd.isValid());
    // The leaf was made for the job the launcher numbered last.
    try harness.expectLeaf(&failed.leftovers.child.cgroup_dir, harness.spawned.next_fork_job_id - 1);
}

test "the zygote's exit reaches the launcher's dependents" {
    // The launcher logs the zygote's exit at `err`, since no worker can be
    // launched after it.
    @import("root").expect_log_errors = 1;
    var harness: Harness = undefined;
    try harness.init(.{ .root = .plain_directory });
    defer harness.deinit();

    try process.pidFdSendSignal(harness.zygote_process.?.pidfd.fd(), std.posix.SIG.KILL);
    try harness.board.waitFor(.zygote_exited, 1, wait_bound_ns);
    harness.quiesce();

    const board = &harness.board;
    try board.expectNoFailure();
    try testing.expectEqual(@as(usize, 0), board.claims_len);
    try testing.expectEqual(@as(usize, 0), board.fork_requests);
    try testing.expectEqual(@as(usize, 0), board.failed_len);
}

test "a fork reply that never comes fails the launch at the zygote's bound, and the launcher kills the zygote, whose exit reaches the dependents" {
    // This test spends `fork_reply_timeout_ms` of real time, since a test
    // cannot shorten the launcher's wait for a fork reply.
    var harness: Harness = undefined;
    try harness.init(.{ .root = .delegated });
    defer harness.deinit();
    // The launcher logs at `err` both the kill of the zygote that missed its
    // reply and the zygote's exit.
    @import("root").expect_log_errors = 2;

    harness.board.script(&.{.unanswered});
    harness.board.grantClaims(launch_definition, 1);
    harness.launcher.submit(launch_definition, .waiter);
    try harness.board.waitFor(.failed, 1, fork_reply_timeout_ns + wait_bound_ns);
    try harness.board.waitFor(.zygote_exited, 1, wait_bound_ns);
    harness.quiesce();

    const board = &harness.board;
    try board.expectNoFailure();
    const failed = &board.failed[0];
    try testing.expectEqual(LaunchFailure.fork_reply_timeout, failed.failure);
    try testing.expectEqual(@as(usize, 1), board.fork_requests);
    // The request carried a leaf, and no child was born into it.
    try testing.expect(!failed.leftovers.child.pidfd.isValid());
    try harness.expectLeaf(&failed.leftovers.child.cgroup_dir, board.fork_job_ids[0]);
    var traces: [launches_max]LaunchTrace = undefined;
    try testing.expectEqual(@as(usize, 1), harness.launcher.takeTraces(&traces));
    try testing.expectEqual(@as(?LaunchFailure, .fork_reply_timeout), traces[0].failure);
    try testing.expect(traces[0].fork_sent_ns != 0);
    try testing.expectEqual(@as(u64, 0), traces[0].fork_reply_ns);
    try testing.expect(failed.at_ns -| traces[0].fork_sent_ns >= fork_reply_timeout_ns);
    // Nothing but the launcher's kill ends the stand-in zygote's process.
    try testing.expect(process.pidFdHasExited(harness.zygote_process.?.pidfd.fd()));
}

test "stopping the launcher ends a launch in flight as stopping and leaves its child alive" {
    var harness: Harness = undefined;
    try harness.init(.{ .root = .delegated });
    defer harness.deinit();

    harness.board.script(&.{.silent});
    harness.board.grantClaims(launch_definition, 1);
    harness.launcher.submit(launch_definition, .waiter);
    // WorkerInit reached the child, so the launch waits for WorkerReady.
    try harness.board.waitFor(.inits_received, 1, wait_bound_ns);
    harness.quiesce();

    const board = &harness.board;
    try board.expectNoFailure();
    try testing.expectEqual(@as(usize, 1), board.failed_len);
    const failed = &board.failed[0];
    try testing.expectEqual(LaunchFailure.stopping, failed.failure);
    try testing.expectEqual(@as(usize, 0), board.published_len);
    try harness.expectChildHandedOverAlive(failed, 0);
}

test "a child that never answers WorkerInit fails the launch when its window closes and is left alive" {
    // This test spends `child_window_ms` of real time, since a test cannot
    // shorten the child window.
    var harness: Harness = undefined;
    try harness.init(.{ .root = .delegated });
    defer harness.deinit();

    harness.board.script(&.{.silent});
    harness.board.grantClaims(launch_definition, 1);
    const submitted_ns = process.monotonicNowNsOrZero();
    harness.launcher.submit(launch_definition, .waiter);
    try harness.board.waitFor(.failed, 1, child_window_ns + wait_bound_ns);
    harness.quiesce();

    const board = &harness.board;
    try board.expectNoFailure();
    const failed = &board.failed[0];
    try testing.expectEqual(LaunchFailure.child_window_expired, failed.failure);
    // The window opens at the WorkerInit send, after the submission, so the
    // failure cannot come sooner.
    try testing.expect(failed.at_ns -| submitted_ns + window_slack_ns >= child_window_ns);
    try harness.expectChildHandedOverAlive(failed, 0);
}

test "WorkerInit carries a boot token for the launch's session under its gateway's key with the child window as its deadline, and WorkerReady ends it once before the publish" {
    var harness: Harness = undefined;
    try harness.init(.{ .root = .delegated });
    defer harness.deinit();

    harness.board.script(&.{.ready});
    harness.board.grantClaims(launch_definition, 1);
    harness.launcher.submit(launch_definition, .waiter);
    try harness.board.waitFor(.published, 1, wait_bound_ns);
    try harness.board.waitFor(.boot_ended, 1, wait_bound_ns);
    harness.quiesce();

    const board = &harness.board;
    try board.expectNoFailure();
    try testing.expect(board.init_carried_egress);
    try testing.expect(board.init_deadline_ns != 0);
    const token = egress_token.fromBytes(&board.init_boot_egress_token);
    const fields = try egress_token.verify(&keyOf(test_gateway_generation), &token);
    try testing.expectEqual(egress_token.Fields{
        .kind = .boot,
        .policy_id = egress_policy.public_https_id,
        .budget = @intCast(egress_policy.production.max_fetches_per_boot),
        .session_id = board.attached_session_id,
        .request_id = 0,
        .request_generation = 0,
        .deadline_monotonic_ns = board.init_deadline_ns,
    }, fields);
    // The key is the one of the gateway the session belongs to.
    try testing.expectError(
        error.BadTag,
        egress_token.verify(&keyOf(test_gateway_generation + 1), &token),
    );

    try testing.expectEqual(@as(usize, 1), board.boot_ended_len);
    try testing.expectEqual(SessionRef{
        .generation = test_gateway_generation,
        .session_id = board.attached_session_id,
    }, board.boot_ended[0]);
    try testing.expectEqual(@as(usize, 1), board.published[0].boot_ends_before_publish);
    // The session's gateway was still current at WorkerReady, so nothing
    // followed WorkerInit on the worker's control socket.
    try testing.expect(!board.published[0].egress_attach_queued);
}

test "a definition without an egress grant launches with no session and no boot token, and its WorkerReady ends nothing" {
    var harness: Harness = undefined;
    try harness.init(.{ .root = .delegated });
    defer harness.deinit();

    harness.board.withholdGrant(launch_definition);
    harness.board.script(&.{.ready});
    harness.board.grantClaims(launch_definition, 1);
    harness.launcher.submit(launch_definition, .waiter);
    try harness.board.waitFor(.published, 1, wait_bound_ns);
    harness.quiesce();

    const board = &harness.board;
    try board.expectNoFailure();
    try testing.expectEqual(@as(usize, 1), board.attaches);
    try testing.expectEqual(@as(usize, 0), board.sessions_len);
    try testing.expect(egress_token.isNone(&board.init_boot_egress_token));
    try testing.expect(!board.init_carried_egress);
    const published = &board.published[0];
    try testing.expectEqual(@as(u64, 0), published.worker.egress_generation);
    try testing.expectEqual(@as(u64, 0), published.worker.egress_session_id);
    try testing.expectEqual(@as(usize, 0), board.boot_ended_len);
    try testing.expect(!published.egress_attach_queued);
}

test "a launch whose gateway is lost before its key is read boots the child detached and gets a session of the next gateway on its control socket before its publish" {
    var harness: Harness = undefined;
    try harness.init(.{ .root = .delegated });
    defer harness.deinit();

    // The gateway dies right after it acknowledges the launch's attach, so
    // the session it handed out has no boot token.
    harness.board.loseGatewayAtAttach(1);
    harness.board.script(&.{.ready});
    harness.board.grantClaims(launch_definition, 1);
    harness.launcher.submit(launch_definition, .waiter);
    try harness.board.waitFor(.published, 1, wait_bound_ns);
    harness.quiesce();

    const board = &harness.board;
    try board.expectNoFailure();
    try testing.expect(egress_token.isNone(&board.init_boot_egress_token));
    try testing.expect(!board.init_carried_egress);
    try testing.expectEqual(@as(usize, 2), board.sessions_len);
    try testing.expectEqual(test_gateway_generation, board.sessions[0].generation);
    const next = board.sessions[1];
    try testing.expectEqual(test_gateway_generation + 1, next.generation);
    const published = &board.published[0];
    try testing.expectEqual(next.generation, published.worker.egress_generation);
    try testing.expectEqual(next.session_id, published.worker.egress_session_id);
    try testing.expect(published.egress_attach_queued);
    var log: AttachLog = .{};
    try takeAttachPackets(board.children[0].worker_end.fd(), &log);
    try testing.expectEqual(@as(usize, 1), log.len);
    try testing.expectEqual(next.command_data_inode, log.inodes[0]);
}

test "a launch whose gateway is lost before WorkerReady is attached to the next gateway on its control socket before its publish" {
    var harness: Harness = undefined;
    try harness.init(.{ .root = .delegated });
    defer harness.deinit();

    harness.board.script(&.{.ready_on_release});
    harness.board.grantClaims(launch_definition, 1);
    harness.launcher.submit(launch_definition, .waiter);
    try harness.board.waitFor(.inits_received, 1, wait_bound_ns);
    // The child holds a session of the first gateway when that gateway is
    // lost, and the pass that follows finds no published worker to attach.
    harness.loseGateway();
    try harness.board.waitFor(.reattach_passes_finished, 1, wait_bound_ns);
    harness.board.release();
    try harness.board.waitFor(.published, 1, wait_bound_ns);
    harness.quiesce();

    const board = &harness.board;
    try board.expectNoFailure();
    try testing.expectEqual(@as(usize, 2), board.sessions_len);
    const next = board.sessions[1];
    try testing.expectEqual(test_gateway_generation + 1, next.generation);
    try testing.expectEqual(launch_definition, next.definition);
    const published = &board.published[0];
    try testing.expectEqual(next.generation, published.worker.egress_generation);
    try testing.expectEqual(next.session_id, published.worker.egress_session_id);
    try testing.expect(published.egress_attach_queued);
    var log: AttachLog = .{};
    try takeAttachPackets(board.children[0].worker_end.fd(), &log);
    try testing.expectEqual(@as(usize, 1), log.len);
    try testing.expectEqual(next.command_data_inode, log.inodes[0]);
}

test "a lost gateway has the launcher bring up the next one and attach each worker to it, writing the new session into the record before the egress_attach that carries it" {
    var harness: Harness = undefined;
    try harness.init(.{ .root = .plain_directory });
    defer harness.deinit();
    const workers = [_]usize{
        try harness.board.addLiveWorker(0, test_gateway_generation, 101),
        try harness.board.addLiveWorker(1, test_gateway_generation, 102),
    };

    harness.loseGateway();
    try harness.board.waitFor(.reattach_passes_finished, 1, wait_bound_ns);
    harness.quiesce();

    const board = &harness.board;
    try board.expectNoFailure();
    try testing.expectEqual(@as(usize, 1), board.prewarms);
    try testing.expectEqual(test_gateway_generation + 1, board.gateway_generation);
    // Every query for stale workers named the gateway the pass attaches to.
    try testing.expectEqual(@as(usize, 0), board.stale_query_mismatches);
    for (workers) |index| {
        const worker = &board.live[index];
        try takeAttachPackets(worker.worker_end.fd(), &worker.attach_log);
        try testing.expect(!worker.retired);
        try testing.expectEqual(@as(usize, 1), worker.sets);
        try testing.expectEqual(board.gateway_generation, worker.record.egress_gateway_generation);
        const session = board.sessionById(worker.record.egress_gateway_session_id) orelse
            return error.TestUnknownEgressSession;
        try testing.expectEqual(worker.record.definition_index, session.definition);
        try testing.expectEqual(@as(usize, 1), worker.attach_log.len);
        try testing.expectEqual(session.command_data_inode, worker.attach_log.inodes[0]);
    }
    try testing.expect(board.live[workers[0]].record.egress_gateway_session_id !=
        board.live[workers[1]].record.egress_gateway_session_id);
    const counters = harness.launcher.countersSnapshot();
    try testing.expectEqual(@as(u64, 1), counters.gateway_losses);
    try testing.expectEqual(@as(u64, 2), counters.egress_reattached);
}

test "a reattach the next gateway refuses hands the worker to retireForEgress without touching its record or its socket" {
    var harness: Harness = undefined;
    try harness.init(.{ .root = .plain_directory });
    defer harness.deinit();
    const refused = try harness.board.addLiveWorker(1, test_gateway_generation, 101);
    const attached = try harness.board.addLiveWorker(0, test_gateway_generation, 102);
    harness.board.refuseAttachFor(1);

    harness.loseGateway();
    try harness.board.waitFor(.reattach_passes_finished, 1, wait_bound_ns);
    harness.quiesce();

    const board = &harness.board;
    try board.expectNoFailure();
    const worker = &board.live[refused];
    try takeAttachPackets(worker.worker_end.fd(), &worker.attach_log);
    try testing.expect(worker.retired);
    try testing.expectEqual(@as(usize, 1), worker.retires);
    try testing.expectEqual(@as(usize, 0), worker.sets);
    try testing.expectEqual(test_gateway_generation, worker.record.egress_gateway_generation);
    try testing.expectEqual(@as(u64, 101), worker.record.egress_gateway_session_id);
    try testing.expectEqual(@as(usize, 0), worker.attach_log.len);
    // The refusal fails that worker's attach alone.
    const other = &board.live[attached];
    try takeAttachPackets(other.worker_end.fd(), &other.attach_log);
    try testing.expect(!other.retired);
    try testing.expectEqual(board.gateway_generation, other.record.egress_gateway_generation);
    try testing.expectEqual(@as(usize, 1), other.attach_log.len);
    const counters = harness.launcher.countersSnapshot();
    try testing.expectEqual(@as(u64, 1), counters.egress_reattach_retired);
    try testing.expectEqual(@as(u64, 0), counters.egress_left_detached);
}

test "a worker retired while its reattach waited for the gateway gets no egress_attach" {
    var harness: Harness = undefined;
    try harness.init(.{ .root = .plain_directory });
    defer harness.deinit();
    const retiring = try harness.board.addLiveWorker(0, test_gateway_generation, 101);
    const staying = try harness.board.addLiveWorker(1, test_gateway_generation, 102);
    harness.board.retireBeforeSet(retiring);

    harness.loseGateway();
    try harness.board.waitFor(.reattach_passes_finished, 1, wait_bound_ns);
    harness.quiesce();

    const board = &harness.board;
    try board.expectNoFailure();
    const worker = &board.live[retiring];
    try takeAttachPackets(worker.worker_end.fd(), &worker.attach_log);
    try testing.expectEqual(@as(usize, 1), worker.sets);
    try testing.expectEqual(@as(usize, 0), worker.attach_log.len);
    // The worker left service on its own, so the launcher retires nothing.
    try testing.expectEqual(@as(usize, 0), worker.retires);
    const other = &board.live[staying];
    try takeAttachPackets(other.worker_end.fd(), &other.attach_log);
    try testing.expectEqual(board.gateway_generation, other.record.egress_gateway_generation);
    try testing.expectEqual(@as(usize, 1), other.attach_log.len);
}

test "an egress_attach the worker cannot take hands it to retireForEgress after its new session was written" {
    var harness: Harness = undefined;
    try harness.init(.{ .root = .plain_directory });
    defer harness.deinit();
    const index = try harness.board.addLiveWorker(0, test_gateway_generation, 101);
    // A worker whose end of the control socket is closed refuses every send.
    harness.board.closeWorkerEnd(index);

    harness.loseGateway();
    try harness.board.waitFor(.reattach_passes_finished, 1, wait_bound_ns);
    harness.quiesce();

    const board = &harness.board;
    try board.expectNoFailure();
    const worker = &board.live[index];
    try testing.expectEqual(@as(usize, 1), worker.sets);
    try testing.expectEqual(@as(usize, 1), worker.retires);
    try testing.expect(worker.retired);
}

test "a gateway lost during a reattach pass runs the pass again, which leaves every worker on the gateway that survived" {
    var harness: Harness = undefined;
    try harness.init(.{ .root = .plain_directory });
    defer harness.deinit();
    const workers = [_]usize{
        try harness.board.addLiveWorker(0, test_gateway_generation, 101),
        try harness.board.addLiveWorker(1, test_gateway_generation, 102),
    };
    // The next gateway dies right after it acknowledges the pass's first
    // attach, and an attach while no gateway is up brings up the one after.
    harness.board.loseGatewayAtAttach(1);

    harness.loseGateway();
    try harness.board.waitFor(.reattach_passes_finished, 2, wait_bound_ns);
    harness.quiesce();

    const board = &harness.board;
    try board.expectNoFailure();
    try testing.expectEqual(@as(usize, 2), board.prewarms);
    try testing.expectEqual(test_gateway_generation + 2, board.gateway_generation);
    for (workers) |index| {
        const worker = &board.live[index];
        try takeAttachPackets(worker.worker_end.fd(), &worker.attach_log);
        try testing.expect(!worker.retired);
        try testing.expectEqual(board.gateway_generation, worker.record.egress_gateway_generation);
        const session = board.sessionById(worker.record.egress_gateway_session_id) orelse
            return error.TestUnknownEgressSession;
        try testing.expectEqual(@as(?u64, session.command_data_inode), worker.attach_log.last());
    }
    // The second pass waited the interval the launcher keeps between spawns.
    try testing.expect(board.prewarm_ns[1] + window_slack_ns >= board.prewarm_ns[0] + prewarm_interval_ns);
}

test "an attach the gateway fails under leaves the worker detached on its old session, and the pass runs again once egress_prewarm_interval_ms has passed" {
    var harness: Harness = undefined;
    try harness.init(.{ .root = .plain_directory });
    defer harness.deinit();
    const index = try harness.board.addLiveWorker(0, test_gateway_generation, 101);
    // The next gateway fails under the pass's first attach, and the manager
    // reports that loss too.
    harness.board.failAttachAt(1);

    harness.loseGateway();
    try harness.board.waitFor(.reattach_passes_finished, 2, wait_bound_ns);
    harness.quiesce();

    const board = &harness.board;
    try board.expectNoFailure();
    const worker = &board.live[index];
    try takeAttachPackets(worker.worker_end.fd(), &worker.attach_log);
    // Nothing retired the worker, and the only session written into its
    // record is the one of the gateway after the failed one.
    try testing.expect(!worker.retired);
    try testing.expectEqual(@as(usize, 0), worker.retires);
    try testing.expectEqual(@as(usize, 1), worker.sets);
    try testing.expectEqual(test_gateway_generation + 2, board.gateway_generation);
    try testing.expectEqual(board.gateway_generation, worker.record.egress_gateway_generation);
    const session = board.sessionById(worker.record.egress_gateway_session_id) orelse
        return error.TestUnknownEgressSession;
    try testing.expectEqual(@as(usize, 1), worker.attach_log.len);
    try testing.expectEqual(session.command_data_inode, worker.attach_log.inodes[0]);
    try testing.expectEqual(@as(usize, 2), board.prewarms);
    try testing.expect(board.prewarm_ns[1] + window_slack_ns >= board.prewarm_ns[0] + prewarm_interval_ns);
    const counters = harness.launcher.countersSnapshot();
    try testing.expectEqual(@as(u64, 1), counters.egress_left_detached);
    try testing.expectEqual(@as(u64, 0), counters.egress_reattach_retired);
}

test "the next gateway spawn waits egress_prewarm_interval_ms from an attach that failed, as from a spawn of the pass's own" {
    // This test spends `egress_attach_send_timeout_ms` and then
    // `egress_prewarm_interval_ms` of real time.
    var harness: Harness = undefined;
    try harness.init(.{ .root = .plain_directory });
    defer harness.deinit();
    // The pass reaches the second worker only once the first worker's send
    // has waited its whole bound, which is as long as the interval, so the
    // pass's own spawn no longer holds the next one back.
    const silent = try harness.board.addLiveWorker(0, test_gateway_generation, 101);
    const failing = try harness.board.addLiveWorker(1, test_gateway_generation, 102);
    try harness.board.stopReading(silent);
    // The second worker's attach, the pass's second, fails under the gateway.
    harness.board.failAttachAt(2);

    harness.loseGateway();
    try harness.board.waitFor(
        .reattach_passes_finished,
        2,
        attach_send_timeout_ns + prewarm_interval_ns + wait_bound_ns,
    );
    harness.quiesce();

    const board = &harness.board;
    try board.expectNoFailure();
    try testing.expectEqual(@as(usize, 2), board.prewarms);
    try testing.expect(board.live[silent].retired);
    const worker = &board.live[failing];
    try takeAttachPackets(worker.worker_end.fd(), &worker.attach_log);
    try testing.expect(!worker.retired);
    try testing.expectEqual(board.gateway_generation, worker.record.egress_gateway_generation);
    // An attach spawns a gateway when none is current, so the launcher counts
    // a failed one as a spawn.
    try testing.expect(board.prewarm_ns[1] + window_slack_ns >= board.attach_ns[1] + prewarm_interval_ns);
}

test "a worker whose control socket takes nothing is retired once egress_attach_send_timeout_ms has passed" {
    var harness: Harness = undefined;
    try harness.init(.{ .root = .plain_directory });
    defer harness.deinit();
    const index = try harness.board.addLiveWorker(0, test_gateway_generation, 101);
    try harness.board.stopReading(index);

    harness.loseGateway();
    try harness.board.waitFor(.reattach_passes_finished, 1, attach_send_timeout_ns + wait_bound_ns);
    harness.quiesce();

    const board = &harness.board;
    try board.expectNoFailure();
    const worker = &board.live[index];
    try testing.expectEqual(@as(usize, 1), worker.sets);
    try testing.expectEqual(@as(usize, 1), worker.retires);
    try testing.expect(worker.retired);
    // The send waited its whole bound for room before it gave up.
    try testing.expect(worker.retire_ns + window_slack_ns >= worker.set_ns + attach_send_timeout_ns);
    const counters = harness.launcher.countersSnapshot();
    try testing.expectEqual(@as(u64, 1), counters.egress_reattach_retired);
    try testing.expectEqual(@as(u64, 0), counters.egress_reattached);
}

test "a gateway lost while a fork request is outstanding gets no spawn until the fork reply is in" {
    var harness: Harness = undefined;
    try harness.init(.{ .root = .delegated });
    defer harness.deinit();
    const index = try harness.board.addLiveWorker(1, test_gateway_generation, 101);

    harness.board.script(&.{.reply_on_release});
    harness.board.grantClaims(launch_definition, 1);
    harness.launcher.submit(launch_definition, .waiter);
    try harness.board.waitFor(.fork_requests, 1, wait_bound_ns);
    harness.loseGateway();
    try harness.awaitLauncherTurn();
    // A spawn now would hold the launcher thread while the fork reply's
    // deadline runs.
    try testing.expectEqual(@as(usize, 0), harness.board.count(.prewarms));

    harness.board.release();
    try harness.board.waitFor(.published, 1, wait_bound_ns);
    try harness.board.waitFor(.reattach_passes_finished, 1, wait_bound_ns);
    harness.quiesce();

    const board = &harness.board;
    try board.expectNoFailure();
    var traces: [launches_max]LaunchTrace = undefined;
    try testing.expectEqual(@as(usize, 1), harness.launcher.takeTraces(&traces));
    try testing.expect(traces[0].fork_reply_ns != 0);
    try testing.expect(traces[0].fork_reply_ns <= board.prewarm_ns[0]);
    const worker = &board.live[index];
    try testing.expectEqual(board.gateway_generation, worker.record.egress_gateway_generation);
}

test "a loss reported for a gateway older than the one the pass attached to starts no spawn" {
    var harness: Harness = undefined;
    try harness.init(.{ .root = .plain_directory });
    defer harness.deinit();
    const index = try harness.board.addLiveWorker(0, test_gateway_generation, 101);

    harness.loseGateway();
    try harness.board.waitFor(.reattach_passes_finished, 1, wait_bound_ns);
    // A second report of the first gateway's loss arrives late, after the
    // pass moved every worker to the next gateway.
    harness.launcher.gatewayLost(test_gateway_generation);
    try harness.awaitLauncherTurn();
    harness.quiesce();

    const board = &harness.board;
    try board.expectNoFailure();
    try testing.expectEqual(@as(usize, 1), board.prewarms);
    const worker = &board.live[index];
    try testing.expectEqual(@as(usize, 1), worker.sets);
    try testing.expectEqual(test_gateway_generation + 1, worker.record.egress_gateway_generation);
    try testing.expectEqual(@as(u64, 2), harness.launcher.countersSnapshot().gateway_losses);
}

test "a session its gateway removed leaves the live worker without one until the next pass attaches it to that gateway again" {
    var harness: Harness = undefined;
    try harness.init(.{ .root = .plain_directory });
    defer harness.deinit();
    const lost = try harness.board.addLiveWorker(0, test_gateway_generation, 101);
    const kept = try harness.board.addLiveWorker(1, test_gateway_generation, 102);

    harness.launcher.egressSessionLost(test_gateway_generation, 101);
    try harness.board.waitFor(.reattach_passes_finished, 1, wait_bound_ns);
    harness.quiesce();

    const board = &harness.board;
    try board.expectNoFailure();
    // The gateway stayed current, so the pass attached the worker to it again.
    try testing.expectEqual(test_gateway_generation, board.gateway_generation);
    const worker = &board.live[lost];
    try takeAttachPackets(worker.worker_end.fd(), &worker.attach_log);
    try testing.expectEqual(@as(usize, 1), worker.drops);
    try testing.expectEqual(@as(usize, 1), worker.sets);
    try testing.expect(!worker.retired);
    try testing.expectEqual(test_gateway_generation, worker.record.egress_gateway_generation);
    const session = board.sessionById(worker.record.egress_gateway_session_id) orelse
        return error.TestUnknownEgressSession;
    try testing.expectEqual(@as(usize, 1), worker.attach_log.len);
    try testing.expectEqual(session.command_data_inode, worker.attach_log.inodes[0]);
    // The other worker kept its session.
    const other = &board.live[kept];
    try takeAttachPackets(other.worker_end.fd(), &other.attach_log);
    try testing.expectEqual(@as(usize, 0), other.sets);
    try testing.expectEqual(@as(u64, 102), other.record.egress_gateway_session_id);
    try testing.expectEqual(@as(usize, 0), other.attach_log.len);
    const counters = harness.launcher.countersSnapshot();
    try testing.expectEqual(@as(u64, 1), counters.egress_sessions_lost);
    try testing.expectEqual(@as(u64, 1), counters.egress_reattached);
    try testing.expectEqual(@as(u64, 0), counters.gateway_losses);
}

test "a removed session no live worker or launch holds starts no pass" {
    var harness: Harness = undefined;
    try harness.init(.{ .root = .plain_directory });
    defer harness.deinit();
    const index = try harness.board.addLiveWorker(0, test_gateway_generation, 101);

    // A worker that exited leaves its session to be removed after its record went.
    harness.launcher.egressSessionLost(test_gateway_generation, 999);
    try harness.awaitLauncherTurn();
    harness.quiesce();

    const board = &harness.board;
    try board.expectNoFailure();
    try testing.expectEqual(@as(usize, 1), board.unmatched_drops);
    try testing.expectEqual(@as(usize, 0), board.prewarms);
    try testing.expectEqual(@as(usize, 0), board.live[index].sets);
    try testing.expectEqual(@as(u64, 101), board.live[index].record.egress_gateway_session_id);
    try testing.expectEqual(@as(u64, 0), harness.launcher.countersSnapshot().egress_sessions_lost);
}

test "a worker whose session keeps being removed is attached again no sooner than egress_prewarm_interval_ms after the last pass" {
    var harness: Harness = undefined;
    try harness.init(.{ .root = .plain_directory });
    defer harness.deinit();
    const index = try harness.board.addLiveWorker(0, test_gateway_generation, 101);

    harness.launcher.egressSessionLost(test_gateway_generation, 101);
    try harness.board.waitFor(.reattach_passes_finished, 1, wait_bound_ns);
    // The gateway removes the new session at once too.
    harness.launcher.egressSessionLost(test_gateway_generation, harness.board.sessionOf(index));
    try harness.board.waitFor(.reattach_passes_finished, 2, prewarm_interval_ns + wait_bound_ns);
    harness.quiesce();

    const board = &harness.board;
    try board.expectNoFailure();
    const worker = &board.live[index];
    try takeAttachPackets(worker.worker_end.fd(), &worker.attach_log);
    try testing.expectEqual(@as(usize, 2), worker.drops);
    try testing.expectEqual(@as(usize, 2), worker.sets);
    try testing.expectEqual(@as(usize, 2), worker.attach_log.len);
    try testing.expectEqual(@as(usize, 2), board.prewarms);
    try testing.expect(board.prewarm_ns[1] + window_slack_ns >= board.prewarm_ns[0] + prewarm_interval_ns);
    try testing.expectEqual(@as(u64, 2), harness.launcher.countersSnapshot().egress_sessions_lost);
}

test "a reattach target whose descriptors the server could not duplicate keeps its worker, which the pass reaches again after egress_prewarm_interval_ms" {
    var harness: Harness = undefined;
    try harness.init(.{ .root = .plain_directory });
    defer harness.deinit();
    const index = try harness.board.addLiveWorker(0, test_gateway_generation, 101);
    harness.board.failDups(index, 1);

    harness.loseGateway();
    try harness.board.waitFor(.reattach_passes_finished, 2, prewarm_interval_ns + wait_bound_ns);
    harness.quiesce();

    const board = &harness.board;
    try board.expectNoFailure();
    const worker = &board.live[index];
    try takeAttachPackets(worker.worker_end.fd(), &worker.attach_log);
    try testing.expect(!worker.retired);
    try testing.expectEqual(@as(usize, 0), worker.retires);
    try testing.expectEqual(@as(usize, 1), worker.sets);
    try testing.expectEqual(board.gateway_generation, worker.record.egress_gateway_generation);
    try testing.expectEqual(@as(usize, 1), worker.attach_log.len);
    try testing.expect(board.prewarm_ns[1] + window_slack_ns >= board.prewarm_ns[0] + prewarm_interval_ns);
    const counters = harness.launcher.countersSnapshot();
    try testing.expectEqual(@as(u64, 1), counters.egress_left_detached);
    try testing.expectEqual(@as(u64, 0), counters.egress_reattach_retired);
}

test "a launch whose session its gateway removed before WorkerReady gets another of that gateway before its publish" {
    var harness: Harness = undefined;
    try harness.init(.{ .root = .delegated });
    defer harness.deinit();

    harness.board.script(&.{.ready_on_release});
    harness.board.grantClaims(launch_definition, 1);
    harness.launcher.submit(launch_definition, .waiter);
    try harness.board.waitFor(.inits_received, 1, wait_bound_ns);
    harness.launcher.egressSessionLost(test_gateway_generation, harness.board.sessionIdAt(0));
    try harness.awaitLauncherTurn();
    harness.board.release();
    try harness.board.waitFor(.published, 1, wait_bound_ns);
    harness.quiesce();

    const board = &harness.board;
    try board.expectNoFailure();
    try testing.expectEqual(@as(usize, 2), board.sessions_len);
    const first = board.sessions[0];
    const next = board.sessions[1];
    try testing.expectEqual(test_gateway_generation, next.generation);
    try testing.expect(next.session_id != first.session_id);
    const published = &board.published[0];
    try testing.expectEqual(next.generation, published.worker.egress_generation);
    try testing.expectEqual(next.session_id, published.worker.egress_session_id);
    try testing.expect(published.egress_attach_queued);
    // The removed session's boot token has nothing left to end at the gateway.
    try testing.expectEqual(@as(usize, 0), board.boot_ended_len);
    const counters = harness.launcher.countersSnapshot();
    try testing.expectEqual(@as(u64, 1), counters.egress_sessions_lost);
    try testing.expectEqual(@as(u64, 1), counters.egress_reattached);
}

test "a launch whose attach the gateway fails under boots its child detached and is published without a session" {
    var harness: Harness = undefined;
    try harness.init(.{ .root = .delegated });
    defer harness.deinit();

    harness.board.failAttachAt(1);
    harness.board.script(&.{.ready});
    harness.board.grantClaims(launch_definition, 1);
    harness.launcher.submit(launch_definition, .waiter);
    try harness.board.waitFor(.published, 1, wait_bound_ns);
    // The failed attach took the gateway with it, and the pass brings up the next one.
    try harness.board.waitFor(.prewarms, 1, prewarm_interval_ns + wait_bound_ns);
    harness.quiesce();

    const board = &harness.board;
    try board.expectNoFailure();
    try testing.expectEqual(@as(usize, 0), board.failed_len);
    try testing.expect(!board.init_carried_egress);
    try testing.expect(egress_token.isNone(&board.init_boot_egress_token));
    const published = &board.published[0];
    try testing.expectEqual(@as(u64, 0), published.worker.egress_generation);
    try testing.expectEqual(@as(u64, 0), published.worker.egress_session_id);
    try testing.expectEqual(@as(u64, 1), harness.launcher.countersSnapshot().egress_left_detached);
    // The launch's attach counts as a spawn, so the pass's spawn waited the
    // interval after it.
    try testing.expect(board.prewarm_ns[0] + window_slack_ns >= board.attach_ns[0] + prewarm_interval_ns);
}

test "while the pass waits to spawn a gateway a launch boots its child detached without an attach" {
    var harness: Harness = undefined;
    try harness.init(.{ .root = .delegated });
    defer harness.deinit();

    // The first loss has the pass spawn the next gateway at once; the second
    // finds the pass's interval running, so no gateway is current for a while.
    harness.loseGateway();
    try harness.board.waitFor(.reattach_passes_finished, 1, wait_bound_ns);
    harness.loseGateway();
    try harness.awaitLauncherTurn();
    harness.board.script(&.{.ready});
    harness.board.grantClaims(launch_definition, 1);
    harness.launcher.submit(launch_definition, .waiter);
    try harness.board.waitFor(.published, 1, wait_bound_ns);
    harness.quiesce();

    const board = &harness.board;
    try board.expectNoFailure();
    // Neither pass found a live worker, so no attach at all means the launch
    // made none.
    try testing.expectEqual(@as(usize, 0), board.attaches);
    try testing.expect(!board.init_carried_egress);
    try testing.expectEqual(@as(u64, 0), board.published[0].worker.egress_session_id);
    try testing.expectEqual(@as(u64, 1), harness.launcher.countersSnapshot().egress_left_detached);
}

test "a WorkerReady that arrives while a gateway spawn holds the launcher past the child window is read, and the worker published" {
    var harness: Harness = undefined;
    try harness.init(.{ .root = .delegated });
    defer harness.deinit();

    harness.board.script(&.{.ready_on_release});
    harness.board.grantClaims(launch_definition, 1);
    harness.launcher.submit(launch_definition, .waiter);
    try harness.board.waitFor(.inits_received, 1, wait_bound_ns);
    // The loss has the launcher spawn a gateway that takes longer than the
    // whole child window, and the child reports ready while it does.
    harness.board.delayPrewarms(child_window_ns + 500 * std.time.ns_per_ms);
    harness.loseGateway();
    try harness.board.waitFor(.prewarms, 1, wait_bound_ns);
    harness.board.release();
    try harness.board.waitFor(.published, 1, child_window_ns + wait_bound_ns);
    harness.quiesce();

    const board = &harness.board;
    try board.expectNoFailure();
    try testing.expectEqual(@as(usize, 0), board.failed_len);
    try testing.expectEqual(@as(usize, 1), board.published_len);
}

/// The launch failure each host launch error stands for. A name the error
/// set gains fails to compile here until it gets a row.
fn failureFor(comptime error_name: []const u8) LaunchFailure {
    const rows = .{
        .{ "WorkerCgroupNotPrepared", LaunchFailure.worker_cgroup_not_prepared },
        .{ "InvalidWorkerTmpRootMode", LaunchFailure.invalid_worker_tmp_root_mode },
        .{ "InvalidWorkerTmpRootOwner", LaunchFailure.invalid_worker_tmp_root_owner },
        .{ "InvalidBootOptions", LaunchFailure.invalid_boot_options },
        .{ "EgressWakeUnavailable", LaunchFailure.egress_wake_set },
        .{ "WorkerInitTimeout", LaunchFailure.child_window_expired },
        .{ "WorkerInitFailed", LaunchFailure.worker_init_failed },
        .{ "ZygoteProtocol", LaunchFailure.zygote_protocol },
        .{ "OutOfMemory", LaunchFailure.out_of_memory },
    };
    inline for (rows) |row| {
        if (comptime std.mem.eql(u8, row[0], error_name))
            return row[1];
    }
    @compileError("no launch failure row for error." ++ error_name);
}

/// What the stand-in does with one fork request.
const Answer = enum {
    /// Clone the child, reply, take WorkerInit and answer WorkerReady.
    ready,
    /// As `ready`, answering WorkerReady only once the test calls
    /// `Board.release`.
    ready_on_release,
    /// As `ready`, with the fork request left unanswered until the test
    /// calls `Board.release`.
    reply_on_release,
    /// As `ready`, answering WorkerInitFailed instead.
    init_failed,
    /// As `ready`, then kill the child instead of answering.
    child_exits,
    /// As `ready`, then never answer.
    silent,
    /// Refuse the fork without a child, as a zygote does when the job's own
    /// resources fail it (`ipc.sendForkFailed`).
    refuse,
    /// Take the fork request and never reply, as a wedged zygote does.
    unanswered,
};

const Claim = struct {
    definition: DefinitionIndex,
    ticket: pool.LaunchTicket,
};

const Published = struct {
    definition: DefinitionIndex,
    ticket: pool.LaunchTicket,
    worker: launcher_mod.ReadyWorker,
    /// The waiters the pool handed a slot of this worker; 0 without a pool.
    handoffs: usize = 0,
    /// A packet already waited on the worker's end of its control socket when
    /// `Deps.publish` ran. After WorkerReady only the launcher's
    /// `egress_attach` can be there.
    egress_attach_queued: bool = false,
    /// The boot tokens `Deps.egressBootEnded` had ended when `Deps.publish`
    /// ran.
    boot_ends_before_publish: usize = 0,
};

/// A definition's pool whose records are the board's published workers,
/// standing for the records the supervisor builds.
const DefinitionPool = pool.Pool(Published);

const Failed = struct {
    definition: DefinitionIndex,
    ticket: pool.LaunchTicket,
    failure: LaunchFailure,
    leftovers: launcher_mod.Leftovers,
    /// When `Deps.failed` ran (CLOCK_MONOTONIC).
    at_ns: u64,
};

/// A process standing in for the zygote's or a worker's, with what the test
/// keeps of it.
const StandInChild = struct {
    pid: std.posix.pid_t,
    /// The test's own pidfd, which ends the child.
    pidfd: fd_mod.OwnedFd,
    /// The fork job the child answers, 0 for the zygote's process.
    fork_job_id: u64 = 0,
    /// The worker's end of its init socket; empty for the zygote's process.
    worker_end: fd_mod.OwnedFd = .{},
};

/// What the stand-in child read in WorkerInit.
const InitSeen = struct {
    /// The routes WorkerInit announced: the table's length and inode, the
    /// pack's inode (0 without one), and the realm mode.
    routes: InitRoutes,
    leaf: []const u8,
    boot_egress_token: egress_token.Bytes,
    init_deadline_ns: u64,
    /// WorkerInit carried the worker's half of an egress session.
    carried_egress: bool,
};

const InitRoutes = struct {
    serves_routes: bool = false,
    isolate_realm: bool = false,
    table_len: u64 = 0,
    table_inode: u64 = 0,
    pack_inode: u64 = 0,
};

/// A session the board's gateway handed out through `attachEgress`, with
/// the inode of its command-ring data memfd, which every copy of the
/// session's descriptors shares, so a received half tells which session it
/// is.
const Session = struct {
    definition: DefinitionIndex,
    generation: u64,
    session_id: u64,
    command_data_inode: u64,
};

/// A session as `Deps.egressBootEnded` names it.
const SessionRef = struct {
    generation: u64,
    session_id: u64,
};

/// The sessions of the `egress_attach` packets one worker received, by the
/// inode of each packet's command-ring data memfd, oldest first.
const AttachLog = struct {
    inodes: [attach_log_max]u64 = undefined,
    len: usize = 0,

    fn contains(self: *const AttachLog, inode: u64) bool {
        return std.mem.indexOfScalar(u64, self.inodes[0..self.len], inode) != null;
    }

    fn last(self: *const AttachLog) ?u64 {
        if (self.len == 0) return null;
        return self.inodes[self.len - 1];
    }
};

/// A published worker as the board's stand-in supervisor keeps it for a
/// reattach: its record, which names its key, its definition and its egress
/// session, and both ends of its control socket. The record is a vacant one
/// given a key, enough for `Deps` to name the worker back.
const LiveWorker = struct {
    record: worker_table.Record,
    /// The server's end, which the record's handle would keep; each reattach
    /// target carries a dup of it.
    server_end: fd_mod.OwnedFd,
    /// The worker's end, where the launcher's `egress_attach` packets arrive.
    worker_end: fd_mod.OwnedFd,
    /// The packets taken from `worker_end` so far.
    attach_log: AttachLog = .{},
    /// The record no longer holds this worker: `retireForEgress` retired it,
    /// or `setWorkerEgress` found it retired.
    retired: bool = false,
    /// `setWorkerEgress` finds the worker retired, as when the reaper retired
    /// it while its reattach waited for the gateway.
    retire_before_set: bool = false,
    /// The worker never reads its control socket, so the board takes nothing
    /// from `worker_end` either.
    never_reads: bool = false,
    /// Reattach targets of this worker still to hand out without their dups,
    /// as when the server is out of descriptors.
    dup_failures_left: usize = 0,
    sets: usize = 0,
    retires: usize = 0,
    /// `dropEgressSession` calls that took this worker off its session.
    drops: usize = 0,
    /// When the last `setWorkerEgress` and `retireForEgress` for this worker
    /// ran (CLOCK_MONOTONIC).
    set_ns: u64 = 0,
    retire_ns: u64 = 0,
};

/// What the launcher's dependencies and the stand-in zygote saw, under one
/// lock: the launcher thread calls the dependencies, the stand-in thread
/// serves fork requests, and the test thread waits on `condition` for
/// either.
const Board = struct {
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},

    /// The pool of `launch_definition` when the test gives one, borrowed:
    /// claims for that definition come from it with the memory gate open,
    /// and publishes and failures go back to it, as the supervisor's do.
    pool: ?*DefinitionPool = null,
    /// The launcher the harness runs, which a gateway lost inside
    /// `attachEgress` reports to.
    launcher: ?*launcher_mod.Launcher = null,
    /// Launches `claimLaunch` grants per definition before it answers null,
    /// for a definition without a pool.
    claims_left: [fixture.definition_names.len]u32 = @splat(0),
    claims: [launches_max]Claim = undefined,
    claims_len: usize = 0,
    /// Claims asked for `probe_definition`, one per launcher turn that took a
    /// probe submission.
    probe_claims: usize = 0,

    /// The board's gateway: the generation `attachEgress` stamps on new
    /// sessions, and whether that gateway is up, which
    /// `egressCurrentGeneration` reports as `Manager.currentGeneration` does.
    /// A loss takes it down, and `egressPrewarm`, or an attach while it is
    /// down, brings up the next generation, as `Manager.prewarm` and
    /// `Manager.attachWorker` do.
    gateway_generation: u64 = test_gateway_generation,
    gateway_up: bool = true,
    prewarms: usize = 0,
    prewarm_ns: [prewarms_max]u64 = @splat(0),
    /// How long each `egressPrewarm` holds the launcher thread.
    prewarm_delay_ns: u64 = 0,
    /// The attach, counted from 1, after which the board's gateway dies and
    /// the launcher hears of it; 0 for none. The attach itself succeeds, but
    /// its gateway is gone before its key is read, so it has no boot token.
    lose_gateway_at_attach: usize = 0,
    /// The attach, counted from 1, under which the board's gateway fails: it
    /// goes down, the launcher hears of it, and the attach fails with
    /// `error.EgressGatewayUnavailable`, as `Manager.attachWorker` does when
    /// the control channel breaks; 0 for none.
    fail_attach_at: usize = 0,
    /// Definitions whose attach the gateway refuses, as a nack does.
    attach_refused: [fixture.definition_names.len]bool = @splat(false),
    /// Definitions without an egress grant, whose attach answers null.
    no_grant: [fixture.definition_names.len]bool = @splat(false),
    attaches: usize = 0,
    attach_ns: [attach_stamps_max]u64 = @splat(0),
    /// The session id the last attach handed out.
    attached_session_id: u64 = 0,
    sessions: [sessions_max]Session = undefined,
    sessions_len: usize = 0,
    boot_ended: [launches_max]SessionRef = undefined,
    boot_ended_len: usize = 0,

    /// The published workers a reattach pass walks; the launches of a test
    /// never add to them.
    live: [live_workers_max]LiveWorker = undefined,
    live_len: usize = 0,
    reattach_targets: usize = 0,
    /// `nextStaleEgressWorker` queries whose generation was not the board's
    /// gateway's.
    stale_query_mismatches: usize = 0,
    /// The `egressPrewarm` calls made before the last query that found no
    /// stale worker, which ends a pass: the passes that reached their end.
    reattach_passes_finished: usize = 0,
    /// `dropEgressSession` calls that found no live worker on the session.
    unmatched_drops: usize = 0,

    published: [launches_max]Published = undefined,
    published_len: usize = 0,
    failed: [launches_max]Failed = undefined,
    failed_len: usize = 0,
    zygote_exited: bool = false,

    /// The stand-in's answers, one per fork request, in order.
    answers: [launches_max]Answer = undefined,
    answers_len: usize = 0,
    answers_taken: usize = 0,
    fork_requests: usize = 0,
    fork_requests_with_leaf: usize = 0,
    fork_job_ids: [launches_max]u64 = undefined,
    children: [launches_max]StandInChild = undefined,
    children_len: usize = 0,
    inits_received: usize = 0,
    /// Children whose init socket the launcher closed before any WorkerInit.
    inits_abandoned: usize = 0,
    init_routes: InitRoutes = .{},
    init_leaf_buffer: [std.fs.max_path_bytes]u8 = undefined,
    init_leaf_len: usize = 0,
    init_boot_egress_token: egress_token.Bytes = egress_token.none,
    /// The child window's end as WorkerInit carried it.
    init_deadline_ns: u64 = 0,
    init_carried_egress: bool = false,
    /// Lets the held step of a `.reply_on_release` or `.ready_on_release`
    /// answer go out.
    released: bool = false,
    /// When the stand-in last answered a WorkerInit or ended its child.
    answered_ns: u64 = 0,
    /// The first error of the stand-in thread or of a dependency; it ends
    /// the test's waits.
    failure: ?anyerror = null,

    const Event = enum {
        claims,
        fork_requests,
        published,
        failed,
        inits_received,
        zygote_exited,
        boot_ended,
        prewarms,
        reattach_passes_finished,
        probe_claims,
    };

    fn deps(self: *Board) launcher_mod.Deps {
        return .{
            .ctx = self,
            .claim = claimLaunch,
            .attachEgress = attachEgress,
            .publish = publishWorker,
            .failed = launchFailed,
            .zygoteExited = zygoteExited,
            .egressCurrentGeneration = egressCurrentGeneration,
            .egressPrewarm = egressPrewarm,
            .egressBootEnded = egressBootEnded,
            .nextStaleEgressWorker = nextStaleEgressWorker,
            .setWorkerEgress = setWorkerEgress,
            .retireForEgress = retireForEgress,
            .dropEgressSession = dropEgressSession,
        };
    }

    fn script(self: *Board, answers: []const Answer) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(self.answers_len + answers.len <= self.answers.len);
        @memcpy(self.answers[self.answers_len..][0..answers.len], answers);
        self.answers_len += answers.len;
    }

    fn grantClaims(self: *Board, definition: DefinitionIndex, launches: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.claims_left[definition] += launches;
    }

    fn refuseAttach(self: *Board) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.attach_refused = @splat(true);
    }

    fn refuseAttachFor(self: *Board, definition: DefinitionIndex) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.attach_refused[definition] = true;
    }

    fn withholdGrant(self: *Board, definition: DefinitionIndex) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.no_grant[definition] = true;
    }

    fn loseGatewayAtAttach(self: *Board, attach: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.lose_gateway_at_attach = attach;
    }

    fn failAttachAt(self: *Board, attach: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.fail_attach_at = attach;
    }

    /// Takes the board's gateway down and tells the launcher, from the
    /// launcher thread inside a dependency, which `gatewayLost` allows since
    /// it calls none.
    fn loseGatewayLocked(self: *Board) void {
        self.gateway_up = false;
        self.launcher.?.gatewayLost(self.gateway_generation);
    }

    /// Takes the board's gateway down and returns its generation, which the
    /// caller reports to the launcher outside the board's lock.
    fn loseGateway(self: *Board) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.gateway_up = false;
        return self.gateway_generation;
    }

    fn bringUpGatewayLocked(self: *Board) void {
        std.debug.assert(!self.gateway_up);
        self.gateway_generation += 1;
        self.gateway_up = true;
    }

    fn release(self: *Board) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.released = true;
        self.condition.broadcast();
    }

    /// Hands the stand-in supervisor a published worker of `definition`
    /// whose record names session `session_id` of gateway `generation`, with
    /// a control socket and a wake set of its own, and returns its place in
    /// `live`.
    fn addLiveWorker(self: *Board, definition: DefinitionIndex, generation: u64, session_id: u64) !usize {
        var wake_set = try ipc.egress_shared.WakeSet.create();
        errdefer wake_set.deinit();
        const pair = try fd_mod.socketPairType(
            std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK,
        );
        var server_end = fd_mod.OwnedFd.fromRaw(pair[0]);
        var worker_end = fd_mod.OwnedFd.fromRaw(pair[1]);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.live_len == self.live.len) {
            server_end.deinit();
            worker_end.deinit();
            return error.TestTooManyLiveWorkers;
        }
        var record = worker_table.Record.vacant(definition, fixture.definition_names[definition]);
        // Keys are never 0, and each live worker of a test gets its own.
        record.id = self.live_len + 1;
        record.generation = 1;
        record.egress_gateway_generation = generation;
        record.egress_gateway_session_id = session_id;
        record.egress_wake_set = wake_set;
        self.live[self.live_len] = .{
            .record = record,
            .server_end = server_end,
            .worker_end = worker_end,
        };
        self.live_len += 1;
        return self.live_len - 1;
    }

    fn retireBeforeSet(self: *Board, index: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.live[index].retire_before_set = true;
    }

    fn failDups(self: *Board, index: usize, failures: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.live[index].dup_failures_left = failures;
    }

    /// The session live worker `index`'s record names now.
    fn sessionOf(self: *Board, index: usize) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.live[index].record.egress_gateway_session_id;
    }

    /// The id of the `index`-th session `attachEgress` handed out.
    fn sessionIdAt(self: *Board, index: usize) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(index < self.sessions_len);
        return self.sessions[index].session_id;
    }

    fn delayPrewarms(self: *Board, delay_ns: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.prewarm_delay_ns = delay_ns;
    }

    /// Fills live worker `index`'s control socket with packets it never
    /// reads, so a send to it would block until the worker read.
    fn stopReading(self: *Board, index: usize) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const worker = &self.live[index];
        worker.never_reads = true;
        const byte = [_]u8{0};
        // A socket pair holds a few hundred one-byte packets.
        for (0..65_536) |_| {
            _ = std.posix.send(worker.server_end.fd(), &byte, std.posix.MSG.NOSIGNAL) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };
        }
        return error.TestSocketNeverFills;
    }

    /// The live worker whose record `target` names; a target that names
    /// another record, or another worker of the record, fails the test.
    fn liveWorkerForLocked(self: *Board, target: *const launcher_mod.ReattachTarget) ?*LiveWorker {
        for (self.live[0..self.live_len]) |*worker| {
            if (&worker.record != target.record) continue;
            if (!target.worker_key.eql(worker.record.key())) {
                self.noteFailureLocked(error.TestReattachTargetOfAnotherWorker);
                return null;
            }
            return worker;
        }
        self.noteFailureLocked(error.TestReattachTargetUnknown);
        return null;
    }

    /// Closes the worker's end of live worker `index`'s control socket, as a
    /// worker that died does, so every send to it fails.
    fn closeWorkerEnd(self: *Board, index: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.live[index].worker_end.deinit();
    }

    fn closeLiveWorkers(self: *Board) void {
        for (self.live[0..self.live_len]) |*worker| {
            worker.server_end.deinit();
            worker.worker_end.deinit();
            worker.record.egress_wake_set.deinit();
        }
        self.live_len = 0;
    }

    fn sessionById(self: *const Board, session_id: u64) ?*const Session {
        for (self.sessions[0..self.sessions_len]) |*session| {
            if (session.session_id == session_id) return session;
        }
        return null;
    }

    /// Whether a packet waits on the worker's end of the control socket of
    /// stand-in child `pid`.
    fn childHasPacketLocked(self: *const Board, pid: u32) bool {
        for (self.children[0..self.children_len]) |*child| {
            if (@as(u32, @intCast(child.pid)) != pid) continue;
            if (!child.worker_end.isValid()) return false;
            const readiness = pollReadiness(child.worker_end.fd(), 0) catch return false;
            return readiness == .readable;
        }
        return false;
    }

    /// Waits until `event` happened at least `at_least` times, at most
    /// `bound_ns`. A failure the stand-in or a dependency recorded ends the
    /// wait with that error.
    fn waitFor(self: *Board, event: Event, at_least: usize, bound_ns: u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var timer = try std.time.Timer.start();
        while (self.countLocked(event) < at_least) {
            if (self.failure) |failure| return failure;
            const elapsed_ns = timer.read();
            if (elapsed_ns >= bound_ns) return error.TestLauncherEventMissing;
            self.condition.timedWait(&self.mutex, bound_ns - elapsed_ns) catch |err| switch (err) {
                error.Timeout => {},
            };
        }
    }

    /// How many times `event` happened so far, while the launcher and the
    /// stand-in may still run.
    fn count(self: *Board, event: Event) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.countLocked(event);
    }

    fn countLocked(self: *const Board, event: Event) usize {
        return switch (event) {
            .claims => self.claims_len,
            .fork_requests => self.fork_requests,
            .published => self.published_len,
            .failed => self.failed_len,
            .inits_received => self.inits_received,
            .zygote_exited => @intFromBool(self.zygote_exited),
            .boot_ended => self.boot_ended_len,
            .prewarms => self.prewarms,
            .reattach_passes_finished => self.reattach_passes_finished,
            .probe_claims => self.probe_claims,
        };
    }

    fn expectNoFailure(self: *Board) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.failure) |failure| return failure;
    }

    fn noteFailureLocked(self: *Board, err: anyerror) void {
        if (self.failure == null)
            self.failure = err;
        self.condition.broadcast();
    }

    fn noteFailure(self: *Board, err: anyerror) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.noteFailureLocked(err);
    }

    fn poolFor(self: *const Board, definition: DefinitionIndex) ?*DefinitionPool {
        return if (definition == launch_definition) self.pool else null;
    }

    /// A ticket for a launch of `definition` when its pool, or else a grant,
    /// allows one.
    fn grantLocked(self: *Board, definition: DefinitionIndex) ?pool.LaunchTicket {
        if (self.poolFor(definition)) |definition_pool|
            return definition_pool.launchStarted(true);
        if (self.claims_left[definition] == 0) return null;
        self.claims_left[definition] -= 1;
        return .{ .entry = @intCast(self.claims_len) };
    }

    /// Moves out the leftovers of the `index`-th failed launch, as the reaper
    /// takes what `Deps.failed` handed it, so the teardown has nothing left
    /// to reap for that launch.
    fn takeLeftovers(self: *Board, index: usize) launcher_mod.Leftovers {
        self.mutex.lock();
        defer self.mutex.unlock();
        const leftovers = self.failed[index].leftovers;
        self.failed[index].leftovers = .{};
        return leftovers;
    }

    /// Records a fork request and returns the answer the test scripted for
    /// it; an unscripted request is a failure, answered with a refusal.
    fn takeAnswer(self: *Board, fork_job_id: u64, carries_leaf: bool) Answer {
        self.mutex.lock();
        defer self.mutex.unlock();
        defer self.condition.broadcast();
        if (self.fork_requests < self.fork_job_ids.len)
            self.fork_job_ids[self.fork_requests] = fork_job_id;
        self.fork_requests += 1;
        if (carries_leaf)
            self.fork_requests_with_leaf += 1;
        if (self.answers_taken == self.answers_len) {
            self.noteFailureLocked(error.TestUnscriptedForkRequest);
            return .refuse;
        }
        const answer = self.answers[self.answers_taken];
        self.answers_taken += 1;
        return answer;
    }

    /// Takes `child` over, so the test's teardown ends it whatever happens
    /// next, and returns its place.
    fn adoptChild(self: *Board, child: StandInChild) !usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.children_len == self.children.len) {
            var excess = child;
            endChild(&excess);
            return error.TestTooManyChildren;
        }
        self.children[self.children_len] = child;
        self.children_len += 1;
        return self.children_len - 1;
    }

    fn giveWorkerEnd(self: *Board, index: usize, worker_end: fd_mod.OwnedFd) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.children[index].worker_end = worker_end;
    }

    /// Closes the stand-in's copy of child `index`'s end of its init socket,
    /// which leaves the child's own copy the last one.
    fn dropWorkerEnd(self: *Board, index: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.children[index].worker_end.deinit();
    }

    fn noteInit(self: *Board, seen: InitSeen) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.init_routes = seen.routes;
        self.init_leaf_len = @min(seen.leaf.len, self.init_leaf_buffer.len);
        @memcpy(self.init_leaf_buffer[0..self.init_leaf_len], seen.leaf[0..self.init_leaf_len]);
        self.init_boot_egress_token = seen.boot_egress_token;
        self.init_deadline_ns = seen.init_deadline_ns;
        self.init_carried_egress = seen.carried_egress;
        self.inits_received += 1;
        self.condition.broadcast();
    }

    fn noteAbandoned(self: *Board) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.inits_abandoned += 1;
        self.condition.broadcast();
    }

    fn noteAnswered(self: *Board) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.answered_ns = process.monotonicNowNsOrZero();
    }

    fn initLeaf(self: *const Board) []const u8 {
        return self.init_leaf_buffer[0..self.init_leaf_len];
    }

    /// Ends every worker child, before any handle or leaf is released, so
    /// the removal of a leaf never meets a member.
    fn endChildren(self: *Board) void {
        for (self.children[0..self.children_len]) |*child|
            endChild(child);
        self.children_len = 0;
    }
};

fn boardOf(ctx: *anyopaque) *Board {
    return @ptrCast(@alignCast(ctx));
}

fn claimLaunch(ctx: *anyopaque, definition: DefinitionIndex) ?pool.LaunchTicket {
    const board = boardOf(ctx);
    board.mutex.lock();
    defer board.mutex.unlock();
    if (definition >= board.claims_left.len) return null;
    if (definition == probe_definition) {
        board.probe_claims += 1;
        board.condition.broadcast();
    }
    const ticket = board.grantLocked(definition) orelse return null;
    if (board.claims_len == board.claims.len) {
        // The ticket stays taken, which only a test that already failed sees.
        board.noteFailureLocked(error.TestTooManyClaims);
        return null;
    }
    board.claims[board.claims_len] = .{ .definition = definition, .ticket = ticket };
    board.claims_len += 1;
    board.condition.broadcast();
    return ticket;
}

/// A new session of the board's gateway on `wake_set`, as
/// `worker_factory.attachLaunchEgress` returns one: the worker's half, and
/// what its boot token carries under the key of the session's gateway, which,
/// as `Manager.keyFor`, the board knows only while that gateway is current. A
/// launch and a reattach both attach here.
fn attachEgress(
    ctx: *anyopaque,
    definition: DefinitionIndex,
    wake_set: *const ipc.egress_shared.WakeSet,
) anyerror!?launcher_mod.EgressAttach {
    const board = boardOf(ctx);
    board.mutex.lock();
    defer board.mutex.unlock();
    defer board.condition.broadcast();
    if (board.attaches < board.attach_ns.len)
        board.attach_ns[board.attaches] = process.monotonicNowNsOrZero();
    board.attaches += 1;
    if (board.no_grant[definition])
        return null;
    if (board.attach_refused[definition])
        return error.EgressGatewayAttachRejected;
    if (board.attaches == board.fail_attach_at) {
        if (board.gateway_up)
            board.loseGatewayLocked();
        return error.EgressGatewayUnavailable;
    }
    if (board.sessions_len == board.sessions.len) {
        board.noteFailureLocked(error.TestTooManyEgressSessions);
        return error.TestTooManyEgressSessions;
    }
    if (!board.gateway_up)
        board.bringUpGatewayLocked();
    const generation = board.gateway_generation;
    var session = try ipc.egress_shared.createSessionForWorker(wake_set);
    board.attached_session_id += 1;
    var attachment = fixture.egressAttachment(&session, generation, board.attached_session_id);
    errdefer attachment.deinit();
    board.sessions[board.sessions_len] = .{
        .definition = definition,
        .generation = generation,
        .session_id = board.attached_session_id,
        .command_data_inode = try inodeOf(attachment.command_data.fd()),
    };
    board.sessions_len += 1;
    if (board.attaches == board.lose_gateway_at_attach)
        board.loseGatewayLocked();
    const key_known = board.gateway_up and board.gateway_generation == generation;
    return .{
        .attachment = attachment,
        .boot = if (!key_known) null else .{
            .key = keyOf(generation),
            .session_id = board.attached_session_id,
            .policy_id = egress_policy.public_https_id,
            .budget = @intCast(egress_policy.production.max_fetches_per_boot),
        },
    };
}

fn egressCurrentGeneration(ctx: *anyopaque) u64 {
    const board = boardOf(ctx);
    board.mutex.lock();
    defer board.mutex.unlock();
    return if (board.gateway_up) board.gateway_generation else 0;
}

fn egressPrewarm(ctx: *anyopaque) anyerror!void {
    const board = boardOf(ctx);
    board.mutex.lock();
    if (board.prewarms < board.prewarm_ns.len)
        board.prewarm_ns[board.prewarms] = process.monotonicNowNsOrZero();
    board.prewarms += 1;
    const delay_ns = board.prewarm_delay_ns;
    board.condition.broadcast();
    board.mutex.unlock();
    // A spawn this slow holds the launcher thread as a gateway slow to
    // report ready does, while the test and the stand-in go on.
    if (delay_ns != 0)
        std.Thread.sleep(delay_ns);
    board.mutex.lock();
    defer board.mutex.unlock();
    if (!board.gateway_up)
        board.bringUpGatewayLocked();
    board.condition.broadcast();
}

fn egressBootEnded(ctx: *anyopaque, generation: u64, session_id: u64) void {
    const board = boardOf(ctx);
    board.mutex.lock();
    defer board.mutex.unlock();
    if (board.boot_ended_len == board.boot_ended.len)
        return board.noteFailureLocked(error.TestTooManyBootEnds);
    board.boot_ended[board.boot_ended_len] = .{ .generation = generation, .session_id = session_id };
    board.boot_ended_len += 1;
    board.condition.broadcast();
}

/// The first live worker whose session is not of gateway `generation`, with
/// a dup of its control socket, or null when none is left, which ends the
/// launcher's pass.
fn nextStaleEgressWorker(ctx: *anyopaque, generation: u64) ?launcher_mod.ReattachTarget {
    const board = boardOf(ctx);
    board.mutex.lock();
    defer board.mutex.unlock();
    defer board.condition.broadcast();
    if (generation != board.gateway_generation)
        board.stale_query_mismatches += 1;
    for (board.live[0..board.live_len]) |*worker| {
        if (worker.retired) continue;
        if (worker.record.egress_gateway_generation == generation) continue;
        if (board.reattach_targets == reattach_targets_max) {
            board.noteFailureLocked(error.TestReattachPassNeverEnds);
            return null;
        }
        if (worker.dup_failures_left != 0) {
            // As `Supervisor.nextStaleEgressWorker` hands out a worker whose dups failed.
            worker.dup_failures_left -= 1;
            board.reattach_targets += 1;
            return .{
                .definition = worker.record.definition_index,
                .record = &worker.record,
                .worker_key = worker.record.key(),
                .control = .{},
                .wake_set = .{},
            };
        }
        var control = fd_mod.OwnedFd.dupCloexec(worker.server_end.fd()) catch |err| {
            board.noteFailureLocked(err);
            return null;
        };
        const wake_set = worker.record.egress_wake_set.dup() catch |err| {
            control.deinit();
            board.noteFailureLocked(err);
            return null;
        };
        board.reattach_targets += 1;
        return .{
            .definition = worker.record.definition_index,
            .record = &worker.record,
            .worker_key = worker.record.key(),
            .control = control,
            .wake_set = wake_set,
        };
    }
    board.reattach_passes_finished = board.prewarms;
    return null;
}

/// Writes the new session into the worker's record, unless the test retired
/// the worker meanwhile. The `egress_attach` carrying that session must not
/// have reached the worker yet, which the packets queued so far show.
fn setWorkerEgress(
    ctx: *anyopaque,
    target: *const launcher_mod.ReattachTarget,
    generation: u64,
    session_id: u64,
) bool {
    const board = boardOf(ctx);
    board.mutex.lock();
    defer board.mutex.unlock();
    defer board.condition.broadcast();
    const worker = board.liveWorkerForLocked(target) orelse return false;
    worker.sets += 1;
    worker.set_ns = process.monotonicNowNsOrZero();
    const session = board.sessionById(session_id) orelse {
        board.noteFailureLocked(error.TestUnknownEgressSession);
        return false;
    };
    if (worker.worker_end.isValid() and !worker.never_reads) {
        takeAttachPackets(worker.worker_end.fd(), &worker.attach_log) catch |err|
            board.noteFailureLocked(err);
    }
    if (worker.attach_log.contains(session.command_data_inode))
        board.noteFailureLocked(error.TestEgressAttachBeforeSessionWritten);
    if (worker.retire_before_set) {
        worker.retired = true;
        return false;
    }
    worker.record.egress_gateway_generation = generation;
    worker.record.egress_gateway_session_id = session_id;
    return true;
}

fn retireForEgress(ctx: *anyopaque, target: *const launcher_mod.ReattachTarget) void {
    const board = boardOf(ctx);
    board.mutex.lock();
    defer board.mutex.unlock();
    const worker = board.liveWorkerForLocked(target) orelse return;
    worker.retired = true;
    worker.retires += 1;
    worker.retire_ns = process.monotonicNowNsOrZero();
    board.condition.broadcast();
}

/// Takes the live worker on session `session_id` of gateway `generation` off
/// it, as `Supervisor.dropEgressSession` does.
fn dropEgressSession(ctx: *anyopaque, generation: u64, session_id: u64) bool {
    const board = boardOf(ctx);
    board.mutex.lock();
    defer board.mutex.unlock();
    defer board.condition.broadcast();
    for (board.live[0..board.live_len]) |*worker| {
        if (worker.retired) continue;
        if (worker.record.egress_gateway_generation != generation) continue;
        if (worker.record.egress_gateway_session_id != session_id) continue;
        worker.record.egress_gateway_generation = 0;
        worker.record.egress_gateway_session_id = 0;
        worker.drops += 1;
        return true;
    }
    board.unmatched_drops += 1;
    return false;
}

fn publishWorker(
    ctx: *anyopaque,
    definition: DefinitionIndex,
    ticket: pool.LaunchTicket,
    worker: launcher_mod.ReadyWorker,
) void {
    const board = boardOf(ctx);
    board.mutex.lock();
    defer board.mutex.unlock();
    if (board.published_len == board.published.len) {
        var excess = worker;
        excess.handle.deinit();
        excess.egress_wake_set.deinit();
        testing.allocator.free(excess.dispatch_send_scratch);
        board.noteFailureLocked(error.TestTooManyPublishes);
        return;
    }
    const published = &board.published[board.published_len];
    published.* = .{
        .definition = definition,
        .ticket = ticket,
        .worker = worker,
        .egress_attach_queued = board.childHasPacketLocked(worker.handle.pid),
        .boot_ends_before_publish = board.boot_ended_len,
    };
    board.published_len += 1;
    if (board.poolFor(definition)) |definition_pool| {
        const handoffs = definition_pool.publish(ticket, published, process.monotonicNowNsOrZero()) catch |err|
            return board.noteFailureLocked(err);
        published.handoffs = handoffs.len;
    }
    board.condition.broadcast();
}

fn launchFailed(
    ctx: *anyopaque,
    definition: DefinitionIndex,
    ticket: pool.LaunchTicket,
    failure: LaunchFailure,
    leftovers: launcher_mod.Leftovers,
) void {
    const board = boardOf(ctx);
    board.mutex.lock();
    defer board.mutex.unlock();
    if (board.poolFor(definition)) |definition_pool|
        definition_pool.launchEnded(ticket) catch |err| board.noteFailureLocked(err);
    if (board.failed_len == board.failed.len) {
        // The launch table keeps this launch's room until the test's
        // teardown, which is fine for a test that already failed.
        var excess = leftovers;
        excess.child.reap();
        board.noteFailureLocked(error.TestTooManyFailures);
        return;
    }
    board.failed[board.failed_len] = .{
        .definition = definition,
        .ticket = ticket,
        .failure = failure,
        .leftovers = leftovers,
        .at_ns = process.monotonicNowNsOrZero(),
    };
    board.failed_len += 1;
    board.condition.broadcast();
}

fn zygoteExited(ctx: *anyopaque) void {
    const board = boardOf(ctx);
    board.mutex.lock();
    defer board.mutex.unlock();
    board.zygote_exited = true;
    board.condition.broadcast();
}

/// The key of the board's gateway `generation`: fixed, so a test can verify a
/// boot token, and another for every generation, as the server draws one per
/// gateway.
fn keyOf(generation: u64) egress_token.Key {
    var key: egress_token.Key = undefined;
    for (&key.bytes, 0..) |*byte, index| {
        const offset: u64 = @intCast(index);
        byte.* = @truncate(0x40 +% generation +% offset);
    }
    std.debug.assert(!key.isZero());
    return key;
}

fn inodeOf(fd: std.posix.fd_t) !u64 {
    const stat = try std.posix.fstat(fd);
    return @intCast(stat.ino);
}

/// Takes every packet queued on `fd`, each of which must be an
/// `egress_attach` carrying a session's worker half, into `log`, and closes
/// the descriptors.
fn takeAttachPackets(fd: std.posix.fd_t, log: *AttachLog) !void {
    // Each turn takes one packet, and the log bounds how many may come.
    while (try pollReadiness(fd, 0) == .readable) {
        if (log.len == log.inodes.len)
            return error.TestTooManyEgressAttachPackets;
        var scratch: [64]u8 = undefined;
        var received = try ipc.recvPacketWithFdsScratch(testing.allocator, fd, &scratch);
        defer received.deinit();
        var half = try ipc.egress_attach.decode(&received);
        defer half.close();
        if (!half.isValid())
            return error.TestEgressAttachIncomplete;
        log.inodes[log.len] = try inodeOf(half.command_data_fd);
        log.len += 1;
    }
}

/// A launcher over a stand-in zygote, its routes, a worker cgroup root and
/// the board its dependencies report to. Initialized in place, since the
/// launcher, the stand-in thread and the board hold pointers into it.
/// `deinit` releases whatever `init` got to, in reverse, and plays the
/// reaper for every failed launch's leftovers.
const Harness = struct {
    routes: ?*fixture.OwnedRoutes,
    /// The directory a root over a plain directory sits in; null otherwise.
    plain_parent: ?std.testing.TmpDir,
    root: ?host.WorkerCgroupRoot,
    board: Board,
    /// The process whose pidfd stands for the zygote's.
    zygote_process: ?StandInChild,
    /// What the launcher borrows as the zygote: that process's pidfd and the
    /// launcher's end of the control socket.
    spawned: zygote.host_client.SpawnedZygote,
    /// The stand-in's end of the control socket.
    serve_fd: fd_mod.OwnedFd,
    stand_in: ?std.Thread,
    stand_in_stopping: std.atomic.Value(bool),
    launcher: launcher_mod.Launcher,
    launcher_initialized: bool,
    launcher_started: bool,
    launcher_joined: bool,

    const RootKind = enum {
        /// A host directory under the delegated subtree, where a child can be
        /// cloned into a leaf; the test skips without one.
        delegated,
        /// A host directory over a plain directory, which takes a leaf's
        /// mkdir but none of its limits.
        plain_directory,
    };

    const Options = struct {
        root: RootKind,
        /// The limits every fixture definition gets.
        limits: fixture.RoutesOptions = .{},
        /// `Board.pool`. It must outlive the harness, whose launcher thread
        /// calls it until `quiesce`.
        pool: ?*DefinitionPool = null,
    };

    fn init(self: *Harness, options: Options) !void {
        self.* = .{
            .routes = null,
            .plain_parent = null,
            .root = null,
            .board = .{ .pool = options.pool },
            .zygote_process = null,
            .spawned = .{
                .pid = 0,
                .pidfd = -1,
                .control_fd = null,
                .trace_read_fd = null,
                .trace_write_fd = null,
                .next_fork_job_id = 1,
            },
            .serve_fd = .{},
            .stand_in = null,
            .stand_in_stopping = std.atomic.Value(bool).init(false),
            .launcher = undefined,
            .launcher_initialized = false,
            .launcher_started = false,
            .launcher_joined = false,
        };
        errdefer self.deinit();

        switch (options.root) {
            .delegated => self.root = try delegatedCgroupRoot(),
            .plain_directory => {
                self.plain_parent = std.testing.tmpDir(.{ .iterate = true });
                self.root = try host.WorkerCgroupRoot.claimHostDir(testing.allocator, self.plain_parent.?.dir.fd);
            },
        }
        self.routes = try fixture.OwnedRoutes.createWith(testing.allocator, options.limits);
        self.zygote_process = try cloneIdleChild(null, null);
        const control = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
        self.spawned.control_fd = control[0];
        self.serve_fd = fd_mod.OwnedFd.fromRaw(control[1]);
        self.spawned.pid = @intCast(self.zygote_process.?.pid);
        self.spawned.pidfd = self.zygote_process.?.pidfd.fd();
        self.stand_in = try std.Thread.spawn(.{}, standInMain, .{self});

        // The launcher allocates each worker's send scratch from this
        // allocator, so a scratch a failed launch keeps shows as a leak.
        try self.launcher.init(testing.allocator, .{
            .deps = self.board.deps(),
            .zygote_process = &self.spawned,
            .routes = &self.routes.?.routes,
            .worker_cgroup_root = &self.root.?,
            .boot = ipc.WorkerRuntimeBootOptions.default(),
            .tmpfs_size_bytes = null,
            .launches_per_definition_max = launches_per_definition_max,
        });
        self.launcher_initialized = true;
        self.board.launcher = &self.launcher;
        try self.launcher.start();
        self.launcher_started = true;
    }

    /// Takes the board's gateway down and tells the launcher, as the
    /// manager's control reader does when a gateway's channel fails.
    fn loseGateway(self: *Harness) void {
        const generation = self.board.loseGateway();
        self.launcher.gatewayLost(generation);
    }

    /// Returns once a launcher turn that began after this call has ended,
    /// so whatever the test did before the call has been through a whole
    /// turn. A turn shows itself by asking a claim for `probe_definition`,
    /// and two probes in a row mean the first one's turn is over.
    fn awaitLauncherTurn(self: *Harness) !void {
        for (0..2) |_| {
            const before = self.board.count(.probe_claims);
            self.launcher.submit(probe_definition, .waiter);
            try self.board.waitFor(.probe_claims, before + 1, wait_bound_ns);
        }
    }

    /// Stops the launcher thread, whose launches in flight end through
    /// `Deps.failed`, then the stand-in thread. Afterwards no other thread
    /// touches the board, so a test reads it directly.
    fn quiesce(self: *Harness) void {
        if (self.launcher_started and !self.launcher_joined) {
            self.launcher.stop();
            self.launcher.join();
            self.launcher_joined = true;
        }
        if (self.stand_in) |thread| {
            self.stand_in_stopping.store(true, .release);
            thread.join();
            self.stand_in = null;
        }
    }

    fn deinit(self: *Harness) void {
        self.quiesce();
        self.board.endChildren();
        self.board.closeLiveWorkers();
        self.releaseOutcomes();
        if (self.launcher_initialized) {
            self.launcher.deinit();
            self.launcher_initialized = false;
        }
        if (self.zygote_process) |*child| {
            endChild(child);
            self.zygote_process = null;
        }
        self.serve_fd.deinit();
        if (self.spawned.control_fd) |control_fd| {
            std.posix.close(control_fd);
            self.spawned.control_fd = null;
        }
        if (self.root) |*root| {
            root.deinit(testing.allocator);
            self.root = null;
        }
        if (self.plain_parent) |*parent| {
            parent.cleanup();
            self.plain_parent = null;
        }
        if (self.routes) |routes| {
            routes.destroy(testing.allocator);
            self.routes = null;
        }
    }

    /// Releases what the dependencies took, as the supervisor and the reaper
    /// do: each published worker's handle, which removes its leaf, its wake
    /// set and its send scratch, and each failed launch's child and leaf,
    /// whose teardown gives the launcher its room back.
    fn releaseOutcomes(self: *Harness) void {
        const board = &self.board;
        for (board.published[0..board.published_len]) |*published| {
            published.worker.handle.deinit();
            published.worker.egress_wake_set.deinit();
            testing.allocator.free(published.worker.dispatch_send_scratch);
        }
        board.published_len = 0;
        for (board.failed[0..board.failed_len]) |*failed| {
            const holds_child = failed.leftovers.holdsChild();
            failed.leftovers.child.reap();
            if (holds_child and self.launcher_initialized)
                self.launcher.leftoversReaped();
        }
        board.failed_len = 0;
    }

    /// The path of the leaf the launcher makes for fork job `fork_job_id`.
    fn leafPath(self: *const Harness, buffer: []u8, fork_job_id: u64) ![]const u8 {
        return std.fmt.bufPrint(buffer, "{s}/worker-{d}", .{ self.root.?.workers_dir_path, fork_job_id });
    }

    /// Checks that `leaf` is the open leaf of fork job `fork_job_id`.
    fn expectLeaf(self: *const Harness, leaf: *const fd_mod.OwnedFd, fork_job_id: u64) !void {
        try testing.expect(leaf.isValid());
        var expected_buffer: [std.fs.max_path_bytes]u8 = undefined;
        var actual_buffer: [std.fs.max_path_bytes]u8 = undefined;
        try testing.expectEqualStrings(
            try self.leafPath(&expected_buffer, fork_job_id),
            try fd_mod.procFdTarget(leaf.fd(), &actual_buffer),
        );
    }

    /// Checks that a failed launch handed over the stand-in's child
    /// `child_index`, still running, with its pidfd and the leaf of its fork
    /// job.
    fn expectChildHandedOverAlive(self: *const Harness, failed: *const Failed, child_index: usize) !void {
        const child = &self.board.children[child_index];
        try testing.expect(!process.pidFdHasExited(child.pidfd.fd()));
        const handed = &failed.leftovers.child;
        try testing.expect(handed.pidfd.isValid());
        try testing.expectEqual(@as(u32, @intCast(child.pid)), handed.pid);
        try testing.expectEqual(child.pid, try pidOfPidFd(handed.pidfd.fd()));
        try self.expectLeaf(&handed.cgroup_dir, child.fork_job_id);
    }

    /// Checks that no `worker-*` leaf is left in the root's host directory.
    fn expectNoWorkerLeaf(self: *const Harness) !void {
        var dir = try std.fs.openDirAbsolute(self.root.?.workers_dir_path, .{ .iterate = true });
        defer dir.close();
        var entries = dir.iterate();
        while (try entries.next()) |entry| {
            if (std.mem.startsWith(u8, entry.name, "worker-"))
                return error.TestWorkerLeafLeft;
        }
    }
};

/// The stand-in zygote's thread. Its first error is recorded on the board,
/// where it ends the test's waits.
fn standInMain(harness: *Harness) void {
    serveForkRequests(harness) catch |err| harness.board.noteFailure(err);
}

fn serveForkRequests(harness: *Harness) !void {
    while (!harness.stand_in_stopping.load(.acquire)) {
        switch (try pollReadiness(harness.serve_fd.fd(), stand_in_poll_ms)) {
            .quiet => {},
            .readable, .hung_up => try serveForkRequest(harness),
        }
    }
}

/// Answers one fork request as the zygote's fork loop does, then plays the
/// child's part of WorkerInit as the board's script says.
fn serveForkRequest(harness: *Harness) !void {
    const board = &harness.board;
    var request = try ipc.recvForkRequestWithFd(harness.serve_fd.fd());
    defer request.deinit();
    const fork_job_id = request.message.fork_job_id;
    const answer = board.takeAnswer(fork_job_id, request.cgroup_dir_fd != null);
    switch (answer) {
        .refuse => return ipc.sendForkFailed(harness.serve_fd.fd(), fork_job_id),
        .unanswered => return,
        .reply_on_release => if (!try awaitRelease(harness)) return,
        .ready, .ready_on_release, .init_failed, .child_exits, .silent => {},
    }

    // The child holds the worker's end of its init socket, as a worker does
    // for its whole life, so its exit hangs the socket up before its pidfd
    // turns readable. The stand-in plays the worker's part of WorkerInit on a
    // copy of that end.
    const init_pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    var server_end = fd_mod.OwnedFd.fromRaw(init_pair[0]);
    defer server_end.deinit();
    var worker_end_owned = fd_mod.OwnedFd.fromRaw(init_pair[1]);
    errdefer worker_end_owned.deinit();
    var child = try cloneIdleChild(request.cgroup_dir_fd, init_pair[1]);
    child.fork_job_id = fork_job_id;
    const child_pid = child.pid;
    const child_pidfd = child.pidfd.fd();
    const index = try board.adoptChild(child);
    board.giveWorkerEnd(index, worker_end_owned);
    worker_end_owned = .{};
    const worker_end = init_pair[1];
    try ipc.sendForkReply(harness.serve_fd.fd(), fork_job_id, @intCast(child_pid), server_end.fd(), child_pidfd);
    // SCM_RIGHTS gave the launcher its own copy; closing this one lets the
    // launcher's close of the server's end reach the worker's end as a
    // hang-up.
    server_end.deinit();

    switch (try awaitWorkerInit(harness, worker_end)) {
        .abandoned => return board.noteAbandoned(),
        .received => {},
    }
    if (answer == .ready_on_release) {
        if (!try awaitRelease(harness))
            return;
    }
    // Stamped before the answer, so a failure the answer causes is never
    // dated before it.
    board.noteAnswered();
    switch (answer) {
        .ready, .ready_on_release, .reply_on_release => try ipc.sendWorkerReady(worker_end),
        .init_failed => try ipc.sendWorkerInitFailed(worker_end, .internal_error),
        .child_exits => {
            // The stand-in's copy closes first, so the child's exit closes
            // the worker's end for good, as a worker's exit does.
            board.dropWorkerEnd(index);
            try process.pidFdSendSignal(child_pidfd, std.posix.SIG.KILL);
        },
        .silent => {},
        .refuse, .unanswered => unreachable,
    }
}

const InitOutcome = enum { received, abandoned };

/// Takes the WorkerInit the launcher sends on `worker_end` and closes every
/// descriptor it carried. `.abandoned`: the launcher closed the server's end
/// first, or the test is stopping the stand-in.
fn awaitWorkerInit(harness: *Harness, worker_end: std.posix.fd_t) !InitOutcome {
    var timer = try std.time.Timer.start();
    while (timer.read() < wait_bound_ns) {
        if (harness.stand_in_stopping.load(.acquire))
            return .abandoned;
        switch (try pollReadiness(worker_end, stand_in_poll_ms)) {
            .quiet => {},
            .hung_up => return .abandoned,
            .readable => {
                var init = try ipc.recvWorkerInit(worker_end);
                defer init.deinit();
                var leaf_buffer: [std.fs.max_path_bytes]u8 = undefined;
                const leaf = try fd_mod.procFdTarget(init.cgroup_dir_fd, &leaf_buffer);
                harness.board.noteInit(.{
                    .routes = .{
                        .serves_routes = init.message.servesRoutes(),
                        .isolate_realm = init.message.isolatesRealms(),
                        .table_len = init.message.route_table_len,
                        .table_inode = try inodeOf(init.route_table_fd),
                        .pack_inode = if (init.module_pack_fd) |fd| try inodeOf(fd) else 0,
                    },
                    .leaf = leaf,
                    .boot_egress_token = init.message.boot_egress_token,
                    .init_deadline_ns = init.message.init_deadline_mono_ns,
                    .carried_egress = init.egress_shared_fds.isValid(),
                });
                return .received;
            },
        }
    }
    return error.TestWorkerInitMissing;
}

/// Waits until the test releases the held step of a `.reply_on_release` or
/// `.ready_on_release` answer. Returns false when the test stops the
/// stand-in first.
fn awaitRelease(harness: *Harness) !bool {
    const board = &harness.board;
    const poll_ns: u64 = @as(u64, @intCast(stand_in_poll_ms)) * std.time.ns_per_ms;
    board.mutex.lock();
    defer board.mutex.unlock();
    var timer = try std.time.Timer.start();
    while (!board.released) {
        if (harness.stand_in_stopping.load(.acquire))
            return false;
        if (timer.read() >= wait_bound_ns)
            return error.TestReadyNeverReleased;
        board.condition.timedWait(&board.mutex, poll_ns) catch |err| switch (err) {
            error.Timeout => {},
        };
    }
    return true;
}

const Readiness = enum { quiet, readable, hung_up };

fn pollReadiness(fd: std.posix.fd_t, timeout_ms: i32) !Readiness {
    var descriptors = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    if (try std.posix.poll(&descriptors, timeout_ms) == 0)
        return .quiet;
    if ((descriptors[0].revents & std.posix.POLL.IN) != 0)
        return .readable;
    return .hung_up;
}

/// Clones a child that does nothing until SIGKILL ends it, born in
/// `cgroup_dir_fd` when one is given, as the zygote's fork loop clones a
/// worker into its leaf (CLONE_INTO_CGROUP), with a pidfd from the clone
/// itself. A worker's stand-in passes its end of the init socket as
/// `keep_fd`, which the child holds until it dies.
fn cloneIdleChild(cgroup_dir_fd: ?std.posix.fd_t, keep_fd: ?std.posix.fd_t) !StandInChild {
    var pidfd: std.posix.fd_t = -1;
    const pid = try process.cloneForkWithPidFd(cgroup_dir_fd, &pidfd);
    if (pid == 0)
        idleUntilKilled(keep_fd);
    return .{ .pid = pid, .pidfd = fd_mod.OwnedFd.fromRaw(pidfd) };
}

/// The body of every stand-in child. A raw clone of this multithreaded
/// process may run no libc and no allocator, whose locks another thread may
/// have held at the clone, so it makes raw system calls only. It closes every
/// descriptor it inherited but `keep_fd`, so it keeps no other socket of the
/// launcher open and a peer's hang-up still reaches the launcher.
fn idleUntilKilled(keep_fd: ?std.posix.fd_t) noreturn {
    const last_fd: u32 = std.math.maxInt(u32);
    if (keep_fd) |keep| {
        const kept: u32 = @intCast(keep);
        if (kept != 0)
            _ = std.os.linux.syscall3(.close_range, 0, kept - 1, 0);
        _ = std.os.linux.syscall3(.close_range, kept + 1, last_fd, 0);
    } else {
        _ = std.os.linux.syscall3(.close_range, 0, last_fd, 0);
    }
    var no_descriptors: [1]std.os.linux.pollfd = undefined;
    while (true)
        _ = std.os.linux.ppoll(&no_descriptors, 0, null, null);
}

/// Kills and reaps a stand-in child and closes what the test kept of it.
fn endChild(child: *StandInChild) void {
    if (child.pidfd.isValid()) {
        process.pidFdSendSignal(child.pidfd.fd(), std.posix.SIG.KILL) catch |err| switch (err) {
            error.ProcessNotFound => {},
            else => std.log.warn("stand-in child {d} was not killed: {s}", .{ child.pid, @errorName(err) }),
        };
        collectExitedChild(child.pid);
    }
    child.pidfd.deinit();
    child.worker_end.deinit();
}

/// Reaps `pid`, waiting for its exit. Goes through `std.c.waitpid` rather
/// than `std.posix.waitpid`, which treats ECHILD as `unreachable`: the
/// aggregate binary also runs `zygote/tests/fork_loop.zig`, which installs
/// SA_NOCLDWAIT for the length of one test and restores the previous action
/// without checking the result, so a child the kernel already reaped is a
/// state to tolerate.
fn collectExitedChild(pid: std.posix.pid_t) void {
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
}

/// The pid a pidfd names, from its `/proc/self/fdinfo` entry.
fn pidOfPidFd(pidfd: std.posix.fd_t) !std.posix.pid_t {
    var path_buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/proc/self/fdinfo/{d}", .{pidfd});
    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    var buffer: [1024]u8 = undefined;
    const len = try file.readAll(&buffer);
    var lines = std.mem.splitScalar(u8, buffer[0..len], '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "Pid:"))
            continue;
        return std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, line["Pid:".len..], " \t"), 10);
    }
    return error.TestPidfdInfoMissing;
}

fn isNonblocking(fd: std.posix.fd_t) !bool {
    const flags = try std.posix.fcntl(fd, std.posix.F.GETFL, 0);
    const nonblock_flag: usize = 1 << @bitOffsetOf(std.posix.O, "NONBLOCK");
    return (flags & nonblock_flag) != 0;
}

/// The worker cgroup root a test that makes a leaf needs: a host directory
/// under the delegated directory `COLLO_TEST_WORKER_CGROUP_ROOT` names,
/// which `wsl-config run` exports, or else `COLLO_WORKER_CGROUP_ROOT`, with
/// this process inside it, since cgroup v2 lets a process clone a child into
/// a leaf only within the subtree delegated to it. The test skips when the
/// host has no such subtree: delegated cgroup v2 is the missing capability.
fn delegatedCgroupRoot() !host.WorkerCgroupRoot {
    const names = [_][]const u8{ "COLLO_TEST_WORKER_CGROUP_ROOT", "COLLO_WORKER_CGROUP_ROOT" };
    for (names) |name| {
        const value = std.posix.getenv(name) orelse continue;
        if (value.len == 0)
            continue;
        if (!insideSubtree(value))
            return error.SkipZigTest;
        return host.WorkerCgroupRoot.init(testing.allocator, .{ .env_root = value }) catch |err| switch (err) {
            error.WorkerCgroupDelegationUnavailable => return error.SkipZigTest,
            else => return err,
        };
    }
    return error.SkipZigTest;
}

/// Whether this process's own cgroup lies below `root_path`. A cgroup or a
/// root this process cannot read counts as outside.
fn insideSubtree(root_path: []const u8) bool {
    const own = cgroup.path.workerDirForPid(testing.allocator, @intCast(std.os.linux.getpid())) catch return false;
    defer testing.allocator.free(own);
    const root = std.fs.cwd().realpathAlloc(testing.allocator, root_path) catch return false;
    defer testing.allocator.free(root);
    if (own.len <= root.len)
        return false;
    return std.mem.startsWith(u8, own, root) and own[root.len] == '/';
}

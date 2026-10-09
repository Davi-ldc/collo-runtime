//! The zygote and its workers against the real kernel (lane
//! `zygote-integration`, inside the delegated cgroup subtree): zygote boot and
//! fork, cgroup placement and adoption, the WorkerInit handoff and its
//! failures, the sandboxed worker's boot order and idle cost, the node fs
//! tree and the fs fault channel, module evaluation at init with its
//! deadline, a worker that loses its egress gateway and is attached to a new
//! one, wasm after seccomp, and the host's bounded response reader.
//!
//! The test thread plays the host against a zygote spawned from the installed
//! `collo` binary. Most tests launch through `host.launch` and dispatch
//! through `host.dispatch`, with the runtime harness for requests and
//! responses; the WorkerInit failure tests send a hand-built WorkerInit
//! through `zygote.ipc` instead. A test that cannot place a worker skips. The
//! launch's transitions without a child are in `host/tests/launch.zig`, and
//! the whole server flow is the `local-e2e` lane.

const std = @import("std");
const os = @import("collo_os");
const limits = @import("collo_limits");
const support = @import("zygote_support");

const fd_mod = os.fd;
const process = os.process;
const zygote = support.zygote;
const fs_index = zygote.ipc.fs_index;
const host = support.host;
const worker_cgroup = zygote.worker_boot.cgroup;
const rt = @import("collo_test_harness");
const worker_memory_limit_bytes: u64 = 1024 * 1024 * 1024;

/// Skips the test when this environment cannot place workers at all; every
/// other launch failure is the test's to judge.
fn launchOrSkip(
    spawned: *zygote.host_client.SpawnedZygote,
    fork_job_id: u64,
    options: support.LaunchOptions,
) !support.LaunchedWorker {
    return support.launchWorker(
        std.testing.allocator,
        spawned,
        worker_memory_limit_bytes,
        fork_job_id,
        options,
    ) catch |err| switch (err) {
        error.WorkerCgroupDelegationUnavailable => return error.SkipZigTest,
        else => return err,
    };
}

/// The wake descriptors of a WorkerInit sent without a session, as a launch
/// opens them from a worker's wake set (`WakeSet.openWorkerWake`), here of a
/// set of their own. The caller closes them once WorkerInit is sent.
fn detachedWake() !zygote.ipc.egress_shared.WakeFds {
    var wake_set = try zygote.ipc.egress_shared.WakeSet.create();
    defer wake_set.deinit();
    return wake_set.openWorkerWake();
}

test "spawned zygote owns a pidfd and deinit observes exit" {
    var spawned = try support.spawnZygote();
    // A failed expect must not leak the zygote, and `deinit` runs mid-test
    // because the test observes the exit it causes.
    var spawned_armed = true;
    defer if (spawned_armed) spawned.deinit();
    try std.testing.expect(spawned.pidfd >= 0);
    try std.testing.expect(!process.pidFdHasExited(spawned.pidfd));

    const pidfd = try std.posix.dup(spawned.pidfd);
    defer std.posix.close(pidfd);
    spawned_armed = false;
    spawned.deinit();
    try support.waitForPidFdExit(pidfd);
}

test "prepare_for_fork runs once at boot and zygote stays prepared across fork requests" {
    var spawned = try support.spawnZygote();
    defer spawned.deinit();

    var first = try zygote.host_client.requestFork(&spawned);
    var first_armed = true;
    defer if (first_armed) first.deinit();
    const first_pidfd = try process.openPidFd(first.pid);
    defer std.posix.close(first_pidfd);

    first_armed = false;
    first.deinit();
    try support.waitForPidFdExit(first_pidfd);

    var second = try zygote.host_client.requestFork(&spawned);
    var second_armed = true;
    defer if (second_armed) second.deinit();
    const second_pidfd = try process.openPidFd(second.pid);
    defer std.posix.close(second_pidfd);

    second_armed = false;
    second.deinit();
    try support.waitForPidFdExit(second_pidfd);

    spawned.shutdown();
    try support.expectChildExitStatus(spawned.pid, 0);

    var trace = try support.drainTrace(&spawned, std.testing.allocator);
    defer trace.deinit();

    try std.testing.expectEqual(@as(usize, 1), trace.countEq("zygote.prepare_for_fork"));
    try std.testing.expectEqual(@as(usize, 1), trace.countEq("zygote.prepared"));
    try std.testing.expectEqual(@as(usize, 2), trace.countEq("zygote.fork_request"));
}

test "zygote boots with the warmup corpus enabled, prepares once, and still forks" {
    // The server always runs the warmup corpus; every other test runs it off.
    // A corpus exception fails the zygote's boot, which stops every worker
    // launch on the node, so this checks that the zygote still serves a fork
    // after the corpus ran and that prepare_for_fork ran once: the corpus
    // runs before prepareForFork, and both run once at boot.
    var spawned = try support.spawnZygoteWithWarmupCorpus();
    defer spawned.deinit();

    var worker = try zygote.host_client.requestFork(&spawned);
    defer worker.deinit();

    const worker_pidfd = try std.posix.dup(worker.pidfd.?);
    defer std.posix.close(worker_pidfd);

    // No WorkerInit follows, so the child stops waiting after
    // `worker_init_timeout_ms` and exits; that it was forked at all proves
    // the zygote booted with the corpus and is serving.
    try std.testing.expect(try process.waitForPidFdExit(worker_pidfd, 3_500));

    spawned.shutdown();
    try support.expectChildExitStatus(spawned.pid, 0);

    var trace = try support.drainTrace(&spawned, std.testing.allocator);
    defer trace.deinit();
    try std.testing.expectEqual(@as(usize, 1), trace.countEq("zygote.warmup_corpus.run"));
    try std.testing.expectEqual(@as(usize, 1), trace.countEq("zygote.warmup_corpus.done"));
    try std.testing.expectEqual(@as(usize, 1), trace.countEq("zygote.prepare_for_fork"));
    try std.testing.expectEqual(@as(usize, 1), trace.countEq("zygote.prepared"));
    // The corpus runs before the fork barrier: warmup finishes, then the
    // zygote declares itself prepared.
    try support.expectTraceBefore(trace, "zygote.warmup_corpus.done", "zygote.prepared");
}

test "worker adopts a host-prepared worker-<job_id> cgroup and deletes it on teardown" {
    // The production placement: a leaf created by the host before the fork,
    // entered by CLONE_INTO_CGROUP, adopted after it. Pins single-member
    // enforcement, the limit rewrite at adoption, and the delete on teardown.
    var root = support.cgroupRoot(std.testing.allocator) catch |err| switch (err) {
        error.WorkerCgroupDelegationUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer root.deinit(std.testing.allocator);

    var spawned = try support.spawnZygote();
    defer spawned.deinit();

    // Reserve a fork job id and create and configure its own cgroup, as the
    // server's launcher does before every fork (`server/supervisor/launcher.zig`).
    // The prepared cgroup carries a different limit than the launch's below,
    // so a passing memory.max assertion proves the adoption rewrote it.
    const fork_job_id: u64 = 90_001;
    const prepared_limit_bytes: u64 = 2 * worker_memory_limit_bytes;
    const prepared_fd = root.createWorkerDir(fork_job_id, .{
        .memory_limit_bytes = prepared_limit_bytes,
    }) catch return error.SkipZigTest;
    var prepared_fd_owned = true;
    errdefer if (prepared_fd_owned) {
        std.posix.close(prepared_fd);
        root.removeWorkerDir(fork_job_id);
    };

    // The child is born inside the prepared cgroup via CLONE_INTO_CGROUP.
    var worker = try zygote.host_client.requestForkWithJobId(&spawned, fork_job_id, prepared_fd);
    worker.fork_job_id = fork_job_id;
    worker.cgroup_dir_fd = prepared_fd;
    prepared_fd_owned = false;
    var worker_armed = true;
    defer if (worker_armed) worker.deinit();

    var wake_set = try zygote.ipc.egress_shared.WakeSet.create();
    defer wake_set.deinit();
    var egress_shared = try zygote.ipc.egress_shared.createSessionForWorker(&wake_set);
    defer egress_shared.deinit();

    var handle = try host.runToReady(
        std.testing.allocator,
        &spawned,
        &worker,
        worker_memory_limit_bytes,
        .{ .egress = .{ .attached = .{
            .shared_fds = egress_shared.rawForWorker(),
            .boot = rt.localBootEgress(),
        } } },
    );
    var handle_armed = true;
    defer if (handle_armed) handle.deinit();

    // The resolved cgroup is the prepared worker-<id> leaf under the root's
    // workers directory.
    const expected_leaf = try std.fmt.allocPrint(std.testing.allocator, "worker-{d}", .{fork_job_id});
    defer std.testing.allocator.free(expected_leaf);
    try std.testing.expect(std.mem.endsWith(u8, handle.cgroup_dir, expected_leaf));
    try std.testing.expect(std.mem.startsWith(u8, handle.cgroup_dir, root.workers_dir_path));

    const expected_cgroup_dir = try std.testing.allocator.dupe(u8, handle.cgroup_dir);
    defer std.testing.allocator.free(expected_cgroup_dir);

    // The worker is the cgroup's only member: born inside it, nothing else
    // ever joins.
    const cgroup_procs_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/cgroup.procs", .{handle.cgroup_dir});
    defer std.testing.allocator.free(cgroup_procs_path);
    const cgroup_procs = try support.readFileAlloc(cgroup_procs_path, std.testing.allocator);
    defer std.testing.allocator.free(cgroup_procs);
    const pid_string = try std.fmt.allocPrint(std.testing.allocator, "{d}", .{worker.pid});
    defer std.testing.allocator.free(pid_string);
    try std.testing.expect(std.mem.containsAtLeast(u8, cgroup_procs, 1, pid_string));
    try std.testing.expectEqualStrings(
        pid_string,
        std.mem.trim(u8, cgroup_procs, &std.ascii.whitespace),
    );

    // Adoption rewrote the create-time limit to the launch's: memory.high
    // carries the limit itself and memory.max the kill headroom above it
    // (`memory.maxBytes`), neither derived from the doubled create-time limit.
    const memory_high_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/memory.high", .{handle.cgroup_dir});
    defer std.testing.allocator.free(memory_high_path);
    try std.testing.expectEqual(worker_memory_limit_bytes, try support.readUnsignedFile(memory_high_path));
    const memory_max_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/memory.max", .{handle.cgroup_dir});
    defer std.testing.allocator.free(memory_max_path);
    try std.testing.expectEqual(
        worker_cgroup.memory.maxBytes(worker_memory_limit_bytes),
        try support.readUnsignedFile(memory_max_path),
    );

    const worker_pidfd = try std.posix.dup(handle.pidfd);
    defer std.posix.close(worker_pidfd);

    // Teardown deletes the prepared leaf.
    handle_armed = false;
    handle.deinit();
    try support.waitForPidFdExit(worker_pidfd);
    try std.testing.expectError(error.FileNotFound, std.fs.accessAbsolute(expected_cgroup_dir, .{}));

    worker_armed = false;
    worker.deinit();

    spawned.shutdown();
    try support.expectChildExitStatus(spawned.pid, 0);
}

test "independent runtime gate: prepared cgroup child serves sealed hello-world and exits" {
    // A worker born into a leaf prepared with the limits it is launched with
    // is the leaf's only member, serves one request from a sealed route pack,
    // and on teardown exits and leaves no leaf behind.
    var root = support.cgroupRoot(std.testing.allocator) catch |err| switch (err) {
        error.WorkerCgroupDelegationUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer root.deinit(std.testing.allocator);

    var spawned = try support.spawnZygote();
    defer spawned.deinit();

    var wake_set = try zygote.ipc.egress_shared.WakeSet.create();
    defer wake_set.deinit();
    var egress_shared = try zygote.ipc.egress_shared.createSessionForWorker(&wake_set);
    defer egress_shared.deinit();

    const fork_job_id: u64 = 90_002;
    const expected_cgroup_dir = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/worker-{d}",
        .{ root.workers_dir_path, fork_job_id },
    );
    defer std.testing.allocator.free(expected_cgroup_dir);

    const prepared_fd = root.createWorkerDir(fork_job_id, .{
        .memory_limit_bytes = worker_memory_limit_bytes,
    }) catch return error.SkipZigTest;
    errdefer root.removeWorkerDir(fork_job_id);
    var prepared_fd_owned = true;
    errdefer if (prepared_fd_owned) std.posix.close(prepared_fd);

    var worker = try zygote.host_client.requestForkWithJobId(&spawned, fork_job_id, prepared_fd);
    worker.fork_job_id = fork_job_id;
    worker.cgroup_dir_fd = prepared_fd;
    prepared_fd_owned = false;
    defer {
        if (worker.pidfd != null) {
            host.terminateForkedWorkerBestEffort(&worker);
        } else {
            worker.deinit();
        }
    }

    const route_specifier = "/__collo_route/test/independent-runtime-hello.js";
    const source =
        \\export default function handle(request) {
        \\  return new Response("Hello, world! " + request.method);
        \\}
    ;
    const route_fd = try rt.createModulePackFd(route_specifier, source);
    defer std.posix.close(route_fd);
    var route = try rt.SingleRoute.init(route_fd, route_specifier);
    defer route.deinit();

    var gate_handle = try host.runToReady(
        std.testing.allocator,
        &spawned,
        &worker,
        worker_memory_limit_bytes,
        .{
            .egress = .{ .attached = .{
                .shared_fds = egress_shared.rawForWorker(),
                .boot = rt.localBootEgress(),
            } },
            .routes = route.launchRoutes(),
        },
    );
    var handle_armed = true;
    defer if (handle_armed) gate_handle.deinit();

    try std.testing.expectEqualStrings(expected_cgroup_dir, gate_handle.cgroup_dir);
    try worker_cgroup.worker.validateLimits(
        std.testing.allocator,
        gate_handle.cgroup_dir,
        .{ .memory_limit_bytes = worker_memory_limit_bytes },
        .require_configured,
    );

    const cgroup_procs_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/cgroup.procs",
        .{gate_handle.cgroup_dir},
    );
    defer std.testing.allocator.free(cgroup_procs_path);
    const cgroup_procs = try support.readFileAlloc(cgroup_procs_path, std.testing.allocator);
    defer std.testing.allocator.free(cgroup_procs);
    var pid_buffer: [10]u8 = undefined;
    const pid_string = try std.fmt.bufPrint(&pid_buffer, "{d}", .{worker.pid});
    try std.testing.expectEqualStrings(
        pid_string,
        std.mem.trim(u8, cgroup_procs, &std.ascii.whitespace),
    );

    const request_id: u64 = 90_002;
    const request = rt.RequestParts{ .method = "GET", .path = "/hello" };
    var dispatch = try rt.initDispatchWork(std.testing.allocator, .{
        .request_id = request_id,
        .deadline_monotonic_ns = try forkedDeadlineNs(),
        .request = request,
    });
    defer dispatch.deinit();
    try rt.sendIngressRoute(gate_handle.control_fd, &dispatch, 1, request);
    var response = try readForkedIngressResponse(&gate_handle, request_id, 8_000);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqual(zygote.ipc.RequestDoneStatus.ok, response.doneStatus());
    try std.testing.expectEqualStrings("Hello, world! GET", response.body);
    try std.testing.expect(!process.pidFdHasExited(gate_handle.pidfd));

    var worker_pidfd = try fd_mod.OwnedFd.dupCloexec(gate_handle.pidfd);
    defer worker_pidfd.deinit();
    handle_armed = false;
    gate_handle.deinit();
    try support.waitForPidFdExit(worker_pidfd.fd());
    try std.testing.expectError(error.FileNotFound, std.fs.accessAbsolute(expected_cgroup_dir, .{}));
}

test "a worker refuses a request begin that carries a file descriptor and stops" {
    // The pack reached the worker in WorkerInit, so no ingress packet
    // may carry a descriptor. A request begin with the pack attached fails to
    // decode in the worker's control loop, which ends the worker before any
    // handler runs.
    var spawned = try support.spawnZygote();
    defer spawned.deinit();

    const route_specifier = "/__collo_route/test/descriptor-refused.js";
    const route_fd = try rt.createModulePackFd(route_specifier,
        \\export default function handle() {
        \\  return new Response("served");
        \\}
    );
    defer std.posix.close(route_fd);
    var route = try rt.SingleRoute.init(route_fd, route_specifier);
    defer route.deinit();
    var launched = try launchOrSkip(&spawned, 90_019, .{
        .routes = route.launchRoutes(),
    });
    defer launched.deinit();
    const handle = &launched.handle;

    var dispatch = try rt.initDispatchWork(std.testing.allocator, .{
        .request_id = 90_019,
        .deadline_monotonic_ns = try forkedDeadlineNs(),
    });
    defer dispatch.deinit();
    const payload_scratch = try std.testing.allocator.alloc(u8, zygote.ipc.max_message_bytes);
    defer std.testing.allocator.free(payload_scratch);
    var view = dispatch.view();
    const payload = try zygote.ipc.encodeDispatchWorkInto(payload_scratch, &view);
    const packet_scratch = try std.testing.allocator.alloc(u8, zygote.ipc.max_message_bytes);
    defer std.testing.allocator.free(packet_scratch);
    const begin = zygote.ipc.ingress_channel.Descriptor.requestBegin(
        .{
            .request_id = dispatch.request_id,
            .request_generation = dispatch.request_generation,
            .request_lane_id = dispatch.request_lane_id,
            .request_slot = dispatch.request_slot,
        },
        1,
        0,
        @intCast(payload.len),
        @intCast(dispatch.request_headers.len),
        true,
    );
    const encoded = try zygote.ipc.ingress_channel.encodeDescriptorPayloadInto(packet_scratch, begin, payload);
    try zygote.ipc.packet.sendWithFds(handle.control_fd, encoded, &.{route_fd});

    try support.waitForPidFdExit(handle.pidfd);
    // The init socket became the control socket at WorkerReady, so the
    // failed loop leaves nothing on it, a WorkerInitFailed least of all.
    try std.testing.expectError(error.PeerClosed, zygote.ipc.recvInitOutcome(handle.control_fd));
    var trace = try support.drainTrace(&spawned, std.testing.allocator);
    defer trace.deinit();
    try std.testing.expect(trace.containsPrefix("worker.scheduler.failed=InvalidPacket"));
}

test "worker self-timeout without WorkerInit" {
    var spawned = try support.spawnZygote();
    defer spawned.deinit();

    var worker = try zygote.host_client.requestFork(&spawned);
    defer worker.deinit();

    const worker_pidfd = try std.posix.dup(worker.pidfd.?);
    defer std.posix.close(worker_pidfd);

    // The child stops waiting for WorkerInit after `worker_init_timeout_ms`,
    // and this wait outlasts it.
    try std.testing.expect(try process.waitForPidFdExit(worker_pidfd, 3_500));

    spawned.shutdown();
    try support.expectChildExitStatus(spawned.pid, 0);

    var trace = try support.drainTrace(&spawned, std.testing.allocator);
    defer trace.deinit();
    try std.testing.expect(trace.containsPrefix("child.worker_init.timeout"));
}

test "valid worker init reseeds immediately, applies sandbox, starts poll loop, and starts sentinel before ready" {
    var spawned = try support.spawnZygote();
    defer spawned.deinit();

    const fork_job_id: u64 = 90_003;
    // An initialized worker has no self-timeout, so a failed assertion must
    // still tear it down; the worker itself is stopped mid-test so the
    // post-cleanup assertions can look at what it left behind.
    var launched = try launchOrSkip(&spawned, fork_job_id, .{});
    defer launched.deinit();
    const handle = &launched.handle;
    const tmp_root_copy = try std.testing.allocator.dupe(u8, handle.tmp_root);
    defer std.testing.allocator.free(tmp_root_copy);
    // The worker lives in the leaf prepared for its fork job under the root.
    const expected_cgroup_dir = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/worker-{d}",
        .{ launched.root.workers_dir_path, fork_job_id },
    );
    defer std.testing.allocator.free(expected_cgroup_dir);
    try std.testing.expectEqualStrings(expected_cgroup_dir, handle.cgroup_dir);

    const worker_pidfd = try std.posix.dup(handle.pidfd);
    defer std.posix.close(worker_pidfd);

    const metrics = handle.metrics.?;
    try std.testing.expectEqual(zygote.worker_state.page.VERSION, metrics.header.version);
    try std.testing.expectEqual(@intFromEnum(zygote.worker_state.page.State.ready), metrics.header.state);
    try std.testing.expectEqual(@intFromEnum(zygote.worker_state.page.TerminationReason.none), metrics.header.termination_reason);
    try std.testing.expectEqual(handle.pid, metrics.header.pid);
    try std.testing.expectEqual(worker_memory_limit_bytes, metrics.header.memory_limit_bytes);
    for (metrics.live_slots) |slot|
        try std.testing.expectEqual(@intFromEnum(zygote.worker_state.page.LiveSlotState.empty), slot.state);

    const memory_events_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/memory.events.local", .{handle.cgroup_dir});
    defer std.testing.allocator.free(memory_events_path);
    const memory_events = try support.readFileAlloc(memory_events_path, std.testing.allocator);
    defer std.testing.allocator.free(memory_events);
    try std.testing.expect(std.mem.containsAtLeast(u8, memory_events, 1, "high 0"));

    const cgroup_procs_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/cgroup.procs", .{handle.cgroup_dir});
    defer std.testing.allocator.free(cgroup_procs_path);
    const cgroup_procs = try support.readFileAlloc(cgroup_procs_path, std.testing.allocator);
    defer std.testing.allocator.free(cgroup_procs);
    const pid_string = try std.fmt.allocPrint(std.testing.allocator, "{d}", .{handle.pid});
    defer std.testing.allocator.free(pid_string);
    try std.testing.expect(std.mem.containsAtLeast(u8, cgroup_procs, 1, pid_string));

    launched.stopWorker();
    try support.waitForPidFdExit(worker_pidfd);
    try std.testing.expectError(error.FileNotFound, std.fs.accessAbsolute(tmp_root_copy, .{}));
    try std.testing.expectError(error.FileNotFound, std.fs.accessAbsolute(expected_cgroup_dir, .{}));

    spawned.shutdown();
    try support.expectChildExitStatus(spawned.pid, 0);

    var trace = try support.drainTrace(&spawned, std.testing.allocator);
    defer trace.deinit();

    // The boot order the sandbox depends on: the child proves it is
    // single-threaded, sets no-new-privileges and drops its capabilities
    // inside the sandbox, and only then resumes JSC and libpas, so every
    // helper thread it starts later (the crypto pool, the sentinel, the wasm
    // worklist) inherits no-new-privileges and empty capability sets.
    try support.expectTraceBefore(trace, "child.wait_worker_init", "child.single_threaded.asserted");
    try support.expectTraceBefore(trace, "child.single_threaded.asserted", "child.sandbox.applied");
    try support.expectTraceBefore(trace, "child.sandbox.applied", "child.post_fork_child");
    try support.expectTraceBefore(trace, "child.post_fork_child", "child.reseed");
    try support.expectTraceBefore(trace, "child.reseed", "child.process_env.installed");
    try support.expectTraceBefore(trace, "child.worker_init.validated", "child.metrics.mapped");
    try support.expectTraceBefore(trace, "child.metrics.mapped", "child.cgroup.validated");
    try support.expectTraceBefore(trace, "child.cgroup.validated", "child.memory_events.opened");
    try support.expectTraceBefore(trace, "child.memory_events.opened", "child.sandbox.applied");
    try support.expectTraceBefore(trace, "child.sandbox.applied", "child.memory_events.registered");
    try support.expectTraceBefore(trace, "child.memory_events.registered", "child.worker_ring.ready");
    try support.expectTraceBefore(trace, "child.worker_ring.ready", "child.sentinel.started");
    try support.expectTraceBefore(trace, "child.sentinel.started", "child.compiler_threads.prespawned");
    try support.expectTraceBefore(trace, "child.compiler_threads.prespawned", "child.control.nonblocking");
    try support.expectTraceBefore(trace, "child.control.nonblocking", "child.seccomp.applied");
    try support.expectTraceBefore(trace, "child.seccomp.applied", "child.node_fs.enabled");
    try support.expectTraceBefore(trace, "child.node_fs.enabled", "child.worker_ready");
    try support.expectTraceBefore(trace, "child.worker_ready", "worker.scheduler.uring");
    try std.testing.expect(trace.containsPrefix("child.gc_override="));
    try std.testing.expect(trace.containsPrefix("host.cgroup.dir="));
    try std.testing.expect(trace.containsPrefix("host.cgroup.limits="));
    try std.testing.expect(trace.containsPrefix("child.sentinel.poll_backend"));
    try std.testing.expect(trace.containsPrefix("worker.scheduler.uring"));

    const attach_index = trace.indexOfPrefix("host.cgroup.dir=") orelse return error.MissingTraceEvent;
    const metrics_index = trace.indexOf("host.metrics.created") orelse return error.MissingTraceEvent;
    const ready_index = trace.indexOf("child.worker_ready") orelse return error.MissingTraceEvent;
    try std.testing.expect(attach_index < metrics_index);
    try std.testing.expect(metrics_index < ready_index);

    const gc_event_index = trace.indexOfPrefix("child.gc_override=") orelse return error.MissingTraceEvent;
    const gc_event = trace.messages[gc_event_index];
    const gc_prefix = "child.gc_override=";
    const gc_value = try std.fmt.parseUnsigned(u64, gc_event[gc_prefix.len..], 10);
    try std.testing.expectEqual(worker_cgroup.memory.gcHeapLimitBytes(worker_memory_limit_bytes), gc_value);
}

/// CPU an idle worker may spend, in thousandths of one core. Its only
/// periodic work is the allocator scavenger's poll, far below this; a
/// scavenger that never sleeps holds the whole core.
const idle_worker_cpu_budget_per_mille: u64 = 50;
const idle_worker_window_ns: u64 = std.time.ns_per_s;

fn readThreadCount(pid: u32) !u64 {
    var path_buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/proc/{d}/status", .{pid});
    const status = try support.readFileAlloc(path, std.testing.allocator);
    defer std.testing.allocator.free(status);
    var lines = std.mem.splitScalar(u8, status, '\n');
    while (lines.next()) |line| {
        const prefix = "Threads:";
        if (std.mem.startsWith(u8, line, prefix))
            return std.fmt.parseUnsigned(u64, std.mem.trim(u8, line[prefix.len..], &std.ascii.whitespace), 10);
    }
    return error.MissingThreadCount;
}

test "an idle worker spends almost no CPU and keeps every thread" {
    var spawned = try support.spawnZygote();
    defer spawned.deinit();

    const route_specifier = "/__collo_route/test/idle-hello.js";
    const route_fd = try rt.createModulePackFd(route_specifier,
        \\export default function handle() {
        \\  return new Response("idle");
        \\}
    );
    defer std.posix.close(route_fd);
    var route = try rt.SingleRoute.init(route_fd, route_specifier);
    defer route.deinit();
    var launched = try launchOrSkip(&spawned, 90_018, .{
        .routes = route.launchRoutes(),
    });
    defer launched.deinit();
    const handle = &launched.handle;

    // A served request leaves the allocator holding the caches and freed
    // pages of a worker that has done real work.
    const request_id: u64 = 90_018;
    var dispatch = try rt.initDispatchWork(std.testing.allocator, .{
        .request_id = request_id,
        .deadline_monotonic_ns = try forkedDeadlineNs(),
    });
    defer dispatch.deinit();
    try rt.sendIngressRoute(handle.control_fd, &dispatch, 1, .{});
    var response = try readForkedIngressResponse(handle, request_id, 8_000);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 200), response.status);

    // The worker is the only process in its cgroup, so the cgroup's CPU
    // total is the worker's, every thread included.
    const threads_before = try readThreadCount(handle.pid);
    const usage_before_usec = try host.cgroup.cpu.readStatUsageUsec(std.testing.allocator, handle.cgroup_dir);
    const started_ns = try process.monotonicNowNs();
    std.Thread.sleep(idle_worker_window_ns);
    const usage_after_usec = try host.cgroup.cpu.readStatUsageUsec(std.testing.allocator, handle.cgroup_dir);
    const elapsed_ns = (try process.monotonicNowNs()) - started_ns;
    const threads_after = try readThreadCount(handle.pid);

    const used_usec = usage_after_usec - usage_before_usec;
    const budget_usec = elapsed_ns / std.time.ns_per_us * idle_worker_cpu_budget_per_mille / 1000;
    if (used_usec > budget_usec) {
        std.debug.print("idle worker used {d} us of CPU in {d} us (budget {d} us)\n", .{
            used_usec,
            elapsed_ns / std.time.ns_per_us,
            budget_usec,
        });
        return error.TestUnexpectedResult;
    }
    // Seccomp denies clone, so a thread that retired while idle could
    // never come back.
    try std.testing.expectEqual(threads_before, threads_after);
}

test "worker node fs round trip stays inside chroot tmpfs" {
    var spawned = try support.spawnZygote();
    defer spawned.deinit();

    // The writable scratch is /tmp/**, so the round trip lives under /tmp;
    // the placeholder index (no files, header only) makes every read in the
    // read-only tree ENOENT and every write there EROFS.
    const route_specifier = "/__collo_route/test/fs-roundtrip.js";
    const source =
        \\import fs, { readFile, writeFile } from "node:fs";
        \\
        \\export default async function handle() {
        \\  fs.mkdirSync("/tmp/nested");
        \\  fs.writeFileSync("/tmp/nested/a.txt", "alpha");
        \\  const a = fs.readFileSync("/tmp/nested/a.txt", "utf8");
        \\  await writeFile("/tmp/nested/b.txt", "beta");
        \\  const b = await readFile("/tmp/nested/b.txt", "utf8");
        \\  const list = fs.readdirSync("/tmp/nested").sort().join(",");
        \\  const fileStat = fs.statSync("/tmp/nested/a.txt");
        \\  const dirStat = fs.statSync("/tmp/nested");
        \\  fs.renameSync("/tmp/nested/a.txt", "/tmp/nested/c.txt");
        \\  const renamed = fs.existsSync("/tmp/nested/c.txt");
        \\  let etcCode = "none";
        \\  try {
        \\    fs.readFileSync("/etc/passwd");
        \\    etcCode = "read";
        \\  } catch (error) {
        \\    etcCode = error.code;
        \\  }
        \\  const escaped = fs.existsSync("../../../../etc/passwd");
        \\  let rootWrite = "none";
        \\  try {
        \\    fs.writeFileSync("/outside-tmp.txt", "x");
        \\    rootWrite = "wrote";
        \\  } catch (error) {
        \\    rootWrite = error.code;
        \\  }
        \\  fs.unlinkSync("/tmp/nested/b.txt");
        \\  fs.unlinkSync("/tmp/nested/c.txt");
        \\  return new Response(JSON.stringify({
        \\    a,
        \\    b,
        \\    list,
        \\    file: fileStat.isFile,
        \\    dir: dirStat.isDirectory,
        \\    renamed,
        \\    removed: !fs.existsSync("/tmp/nested/b.txt"),
        \\    etcCode,
        \\    escaped,
        \\    rootWrite,
        \\  }));
        \\}
    ;
    const route_fd = try rt.createModulePackFd(route_specifier, source);
    defer std.posix.close(route_fd);
    var route = try rt.SingleRoute.init(route_fd, route_specifier);
    defer route.deinit();

    var launched = try launchOrSkip(&spawned, 90_004, .{
        .routes = route.launchRoutes(),
    });
    defer launched.deinit();
    const handle = &launched.handle;

    var dispatch = try rt.initDispatchWork(std.testing.allocator, .{
        .request_id = 42,
        .deadline_monotonic_ns = try forkedDeadlineNs(),
    });
    defer dispatch.deinit();
    try rt.sendIngressRoute(handle.control_fd, &dispatch, 1, .{});
    var response = try readForkedIngressResponse(handle, 42, 8_000);
    defer response.deinit();

    const expected =
        \\"a":"alpha","b":"beta","list":"a.txt,b.txt","file":true,"dir":true,"renamed":true,"removed":true,"etcCode":"ENOENT","escaped":false,"rootWrite":"EROFS"
    ;
    if (!std.mem.containsAtLeast(u8, response.body, 1, expected)) {
        std.debug.print("unexpected fs roundtrip response (status={d}):\n{s}\n", .{ response.status, response.body });
        return error.WorkerFsRouteUnexpectedResponse;
    }
}

test "worker node fs tmpfs cap returns ENOSPC" {
    var spawned = try support.spawnZygote();
    defer spawned.deinit();

    const route_specifier = "/__collo_route/test/fs-cap.js";
    const source =
        \\import fs from "fs";
        \\
        \\export default function handle() {
        \\  try {
        \\    fs.writeFileSync("/tmp/too-big", "x".repeat(2 * 1024 * 1024));
        \\    return new Response("write-succeeded", { status: 500 });
        \\  } catch (error) {
        \\    return new Response(error.code);
        \\  }
        \\}
    ;
    const route_fd = try rt.createModulePackFd(route_specifier, source);
    defer std.posix.close(route_fd);
    var route = try rt.SingleRoute.init(route_fd, route_specifier);
    defer route.deinit();

    var launched = try launchOrSkip(&spawned, 90_005, .{
        .tmpfs_size_bytes = 1024 * 1024,
        .routes = route.launchRoutes(),
    });
    defer launched.deinit();
    const handle = &launched.handle;

    var dispatch = try rt.initDispatchWork(std.testing.allocator, .{
        .request_id = 43,
        .deadline_monotonic_ns = try forkedDeadlineNs(),
    });
    defer dispatch.deinit();
    try rt.sendIngressRoute(handle.control_fd, &dispatch, 1, .{});
    var response = try readForkedIngressResponse(handle, 43, 8_000);
    defer response.deinit();

    try std.testing.expectEqualStrings("ENOSPC", response.body);
}

/// A sealed fs index memfd for `files`, which must be in index order: the
/// artifact a launch hands a worker. The caller owns the fd.
fn createTestFsIndexMemfd(allocator: std.mem.Allocator, mtime_ms: u64, files: []const fs_index.File) !std.posix.fd_t {
    const bytes = try fs_index.buildIndexBytes(allocator, mtime_ms, files);
    defer allocator.free(bytes);
    return createSealedMemfdFromBytes(bytes);
}

fn createSealedMemfdFromBytes(bytes: []const u8) !std.posix.fd_t {
    const fd = try std.posix.memfd_create(
        "collo-test-fs-index",
        std.os.linux.MFD.CLOEXEC | std.os.linux.MFD.ALLOW_SEALING,
    );
    errdefer std.posix.close(fd);
    try fd_mod.writeAllRaw(fd, bytes);
    try std.posix.lseek_SET(fd, 0);
    try fd_mod.addSeals(fd, fd_mod.memfd_readonly_seals);
    return fd;
}

test "worker fs index serves file tree metadata, EROFS matrix, and explicit ENOENT" {
    // A real forked worker with a non-placeholder index: stat, exists and
    // readdir answer from the index with no fault traffic; every mutation
    // outside /tmp, a rename across the two included, is EROFS; /tmp keeps
    // working. Reads of entries not yet materialized fault, which the
    // "worker fs fault" tests cover, so this matrix never reads a tree file.
    // The tree is anchored at /var/task, the working directory, so an entry
    // whose first segment is `tmp` is served read-only at ./tmp/** while the
    // absolute /tmp stays independent writable scratch; "/" and "/var" are
    // virtual read-only directories listing only the namespace roots.
    var spawned = try support.spawnZygote();
    defer spawned.deinit();

    const fs_index_memfd = try createTestFsIndexMemfd(std.testing.allocator, 1_730_000_000_123, &.{
        .{ .path = "assets/logo.svg", .size = 512, .sha256 = @splat(0x11) },
        .{ .path = "data/config.json", .size = 42, .sha256 = @splat(0x22) },
        .{ .path = "data/nested/deep.txt", .size = 7, .sha256 = @splat(0x33) },
        .{ .path = "index.js", .size = 100, .sha256 = @splat(0x44) },
        .{ .path = "tmp/config.json", .size = 9, .sha256 = @splat(0x55) },
    });
    defer std.posix.close(fs_index_memfd);

    const route_specifier = "/__collo_route/test/fs-index-metadata.js";
    const source =
        \\import fs from "node:fs";
        \\
        \\export default function handle() {
        \\  const st = fs.statSync("data/config.json");
        \\  const stDir = fs.statSync("./data");
        \\  const cwdList = fs.readdirSync(".").join(",");
        \\  const rootList = fs.readdirSync("/").join(",");
        \\  const varList = fs.readdirSync("/var").join(",");
        \\  const dataList = fs.readdirSync("data").join(",");
        \\  let missingDir = "none";
        \\  try { fs.readdirSync("/does-not-exist"); missingDir = "listed"; } catch (e) { missingDir = e.code; }
        \\  let writeCode = "none";
        \\  try { fs.writeFileSync("data/config.json", "x"); writeCode = "wrote"; } catch (e) { writeCode = e.code; }
        \\  let mkdirCode = "none";
        \\  try { fs.mkdirSync("data/new-dir"); mkdirCode = "made"; } catch (e) { mkdirCode = e.code; }
        \\  let unlinkCode = "none";
        \\  try { fs.unlinkSync("data/config.json"); unlinkCode = "unlinked"; } catch (e) { unlinkCode = e.code; }
        \\  let renameCode = "none";
        \\  try { fs.renameSync("data/config.json", "/tmp/stolen.json"); renameCode = "renamed"; } catch (e) { renameCode = e.code; }
        \\  const shadowSize = fs.statSync("./tmp/config.json").size;
        \\  let shadowWrite = "none";
        \\  try { fs.writeFileSync("./tmp/config.json", "x"); shadowWrite = "wrote"; } catch (e) { shadowWrite = e.code; }
        \\  const scratchBefore = fs.existsSync("/tmp/config.json");
        \\  fs.writeFileSync("/tmp/config.json", "scratch");
        \\  const scratchRead = fs.readFileSync("/tmp/config.json", "utf8");
        \\  const shadowStill = fs.statSync("./tmp/config.json").size;
        \\  fs.writeFileSync("/tmp/ok.txt", "ok");
        \\  const tmpRead = fs.readFileSync("/tmp/ok.txt", "utf8");
        \\  return new Response(JSON.stringify({
        \\    size: st.size,
        \\    mtimeMs: st.mtimeMs,
        \\    file: st.isFile,
        \\    dirIsDir: stDir.isDirectory,
        \\    cwdList,
        \\    rootList,
        \\    varList,
        \\    dataList,
        \\    missingDir,
        \\    writeCode,
        \\    mkdirCode,
        \\    unlinkCode,
        \\    renameCode,
        \\    shadowSize,
        \\    shadowWrite,
        \\    scratchBefore,
        \\    scratchRead,
        \\    shadowStill,
        \\    tmpRead,
        \\    missing: fs.existsSync("data/nope.json"),
        \\    exists: fs.existsSync("data/config.json"),
        \\  }));
        \\}
    ;
    const route_fd = try rt.createModulePackFd(route_specifier, source);
    defer std.posix.close(route_fd);
    var route = try rt.SingleRoute.init(route_fd, route_specifier);
    defer route.deinit();

    var launched = try launchOrSkip(&spawned, 90_006, .{
        .fs_index_memfd = fs_index_memfd,
        .routes = route.launchRoutes(),
    });
    defer launched.deinit();
    const handle = &launched.handle;

    var dispatch = try rt.initDispatchWork(std.testing.allocator, .{
        .request_id = 44,
        .deadline_monotonic_ns = try forkedDeadlineNs(),
    });
    defer dispatch.deinit();
    try rt.sendIngressRoute(handle.control_fd, &dispatch, 1, .{});
    var response = try readForkedIngressResponse(handle, 44, 8_000);
    defer response.deinit();

    const expected =
        \\"size":42,"mtimeMs":1730000000123,"file":true,"dirIsDir":true,"cwdList":"assets,data,index.js,tmp","rootList":"tmp,var","varList":"task","dataList":"config.json,nested","missingDir":"ENOENT","writeCode":"EROFS","mkdirCode":"EROFS","unlinkCode":"EROFS","renameCode":"EROFS","shadowSize":9,"shadowWrite":"EROFS","scratchBefore":false,"scratchRead":"scratch","shadowStill":9,"tmpRead":"ok","missing":false,"exists":true
    ;
    if (!std.mem.containsAtLeast(u8, response.body, 1, expected)) {
        std.debug.print("unexpected fs index metadata response (status={d}):\n{s}\n", .{ response.status, response.body });
        return error.WorkerFsIndexUnexpectedResponse;
    }
}

// The fs fault fixture: one text file whose index entry carries the sha256
// of its real bytes, so the worker's check after copying the file in passes
// end to end. The route reads it with an explicit "utf8", since a read
// without an encoding returns a Uint8Array.
const fs_fault_e2e_path = "data/hello.txt";
const fs_fault_e2e_content = "hello from the fault plane e2e\n";

fn createFsFaultFixtureIndexMemfd(allocator: std.mem.Allocator) !std.posix.fd_t {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(fs_fault_e2e_content, &digest, .{});
    return createTestFsIndexMemfd(allocator, 1_730_000_000_123, &.{
        .{ .path = fs_fault_e2e_path, .size = fs_fault_e2e_content.len, .sha256 = digest },
    });
}

const fs_fault_e2e_route_source =
    \\import fs from "node:fs";
    \\export default async function handle() {
    \\  try {
    \\    const content = await fs.promises.readFile("data/hello.txt", "utf8");
    \\    return new Response("resolved:" + content);
    \\  } catch (e) {
    \\    return new Response("rejected:" + String(e));
    \\  }
    \\}
;

test "worker fs fault: async readFile faults, harness serves bytes, promise resolves" {
    var spawned = try support.spawnZygote();
    defer spawned.deinit();

    const fs_index_memfd = try createFsFaultFixtureIndexMemfd(std.testing.allocator);
    defer std.posix.close(fs_index_memfd);

    const route_specifier = "/__collo_route/test/fs-fault-e1.js";
    const route_fd = try rt.createModulePackFd(route_specifier, fs_fault_e2e_route_source);
    defer std.posix.close(route_fd);
    var route = try rt.SingleRoute.init(route_fd, route_specifier);
    defer route.deinit();

    var launched = try launchOrSkip(&spawned, 90_007, .{
        .fs_index_memfd = fs_index_memfd,
        .routes = route.launchRoutes(),
    });
    defer launched.deinit();
    const handle = &launched.handle;

    var dispatch = try rt.initDispatchWork(std.testing.allocator, .{
        .request_id = 46,
        .deadline_monotonic_ns = try forkedDeadlineNs(),
    });
    defer dispatch.deinit();
    try rt.sendIngressRoute(handle.control_fd, &dispatch, 1, .{});

    // The harness plays the host: it receives the fault and serves the bytes.
    var fault_request = try support.readFsFaultRequest(std.testing.allocator, handle.fs_fault_fd, 8_000);
    defer fault_request.deinit();
    try std.testing.expectEqualStrings(fs_fault_e2e_path, fault_request.path);
    try std.testing.expectEqual(@as(u64, 46), fault_request.request_id);
    try support.respondFsFaultOk(handle.fs_fault_fd, fault_request.fault_id, fs_fault_e2e_content);

    var response = try readForkedIngressResponse(handle, 46, 8_000);
    defer response.deinit();
    try std.testing.expectEqualStrings("resolved:" ++ fs_fault_e2e_content, response.body);

    var trace = try support.drainTrace(&spawned, std.testing.allocator);
    defer trace.deinit();
    try support.expectTraceBefore(
        trace,
        "worker.fs_fault.sent=" ++ fs_fault_e2e_path,
        "worker.fs_fault.settled=" ++ fs_fault_e2e_path,
    );
}

test "worker fs fault: second read of a materialized path is local, zero second fault" {
    var spawned = try support.spawnZygote();
    defer spawned.deinit();

    const fs_index_memfd = try createFsFaultFixtureIndexMemfd(std.testing.allocator);
    defer std.posix.close(fs_index_memfd);

    const route_specifier = "/__collo_route/test/fs-fault-e2.js";
    const route_fd = try rt.createModulePackFd(route_specifier, fs_fault_e2e_route_source);
    defer std.posix.close(route_fd);
    var route = try rt.SingleRoute.init(route_fd, route_specifier);
    defer route.deinit();

    var launched = try launchOrSkip(&spawned, 90_008, .{
        .fs_index_memfd = fs_index_memfd,
        .routes = route.launchRoutes(),
    });
    defer launched.deinit();
    const handle = &launched.handle;

    // First request faults and materializes.
    var first_dispatch = try rt.initDispatchWork(std.testing.allocator, .{
        .request_id = 48,
        .deadline_monotonic_ns = try forkedDeadlineNs(),
    });
    defer first_dispatch.deinit();
    try rt.sendIngressRoute(handle.control_fd, &first_dispatch, 1, .{});
    var fault_request = try support.readFsFaultRequest(std.testing.allocator, handle.fs_fault_fd, 8_000);
    defer fault_request.deinit();
    try support.respondFsFaultOk(handle.fs_fault_fd, fault_request.fault_id, fs_fault_e2e_content);
    var first_response = try readForkedIngressResponse(handle, 48, 8_000);
    defer first_response.deinit();
    try std.testing.expectEqualStrings("resolved:" ++ fs_fault_e2e_content, first_response.body);

    // Second request, same path: served from the tmpfs copy, so the host sees
    // no further fault traffic. Its stream id is odd, as a client-initiated
    // HTTP/2 stream's must be (`validateStreamBeginDescriptor` rejects even
    // ids).
    var second_dispatch = try rt.initDispatchWork(std.testing.allocator, .{
        .request_id = 49,
        .deadline_monotonic_ns = try forkedDeadlineNs(),
    });
    defer second_dispatch.deinit();
    try rt.sendIngressRoute(handle.control_fd, &second_dispatch, 3, .{});
    var second_response = try readForkedIngressResponse(handle, 49, 8_000);
    defer second_response.deinit();
    try std.testing.expectEqualStrings("resolved:" ++ fs_fault_e2e_content, second_response.body);
    try support.expectNoFsFaultRequest(handle.fs_fault_fd, 300);

    var trace = try support.drainTrace(&spawned, std.testing.allocator);
    defer trace.deinit();
    try std.testing.expect(trace.containsPrefix("worker.fs_fault.hit_local=/var/task/" ++ fs_fault_e2e_path));
    try std.testing.expectEqual(
        @as(usize, 1),
        trace.countEq("worker.fs_fault.sent=" ++ fs_fault_e2e_path),
    );
}

test "worker fs fault: sha256 mismatch rejects fail-closed, nothing materializes, worker lives" {
    var spawned = try support.spawnZygote();
    defer spawned.deinit();

    const fs_index_memfd = try createFsFaultFixtureIndexMemfd(std.testing.allocator);
    defer std.posix.close(fs_index_memfd);

    const route_specifier = "/__collo_route/test/fs-fault-e3.js";
    const route_fd = try rt.createModulePackFd(route_specifier, fs_fault_e2e_route_source);
    defer std.posix.close(route_fd);
    var route = try rt.SingleRoute.init(route_fd, route_specifier);
    defer route.deinit();

    var launched = try launchOrSkip(&spawned, 90_009, .{
        .fs_index_memfd = fs_index_memfd,
        .routes = route.launchRoutes(),
    });
    defer launched.deinit();
    const handle = &launched.handle;

    // Wrong bytes of the right size: passes the size check, fails sha256.
    var wrong_content: [fs_fault_e2e_content.len]u8 = fs_fault_e2e_content.*;
    wrong_content[0] ^= 0x01;

    var first_dispatch = try rt.initDispatchWork(std.testing.allocator, .{
        .request_id = 50,
        .deadline_monotonic_ns = try forkedDeadlineNs(),
    });
    defer first_dispatch.deinit();
    try rt.sendIngressRoute(handle.control_fd, &first_dispatch, 1, .{});
    var first_fault = try support.readFsFaultRequest(std.testing.allocator, handle.fs_fault_fd, 8_000);
    defer first_fault.deinit();
    try support.respondFsFaultOk(handle.fs_fault_fd, first_fault.fault_id, &wrong_content);
    var first_response = try readForkedIngressResponse(handle, 50, 8_000);
    defer first_response.deinit();
    try std.testing.expect(std.mem.containsAtLeast(u8, first_response.body, 1, "rejected:"));
    try std.testing.expect(std.mem.containsAtLeast(u8, first_response.body, 1, "sha256 mismatch"));

    // The worker is alive and nothing was copied in: the same path faults
    // again, which proves no bytes were kept, and the right bytes now
    // resolve it. Its stream id is odd, as a client-initiated HTTP/2
    // stream's must be.
    var second_dispatch = try rt.initDispatchWork(std.testing.allocator, .{
        .request_id = 51,
        .deadline_monotonic_ns = try forkedDeadlineNs(),
    });
    defer second_dispatch.deinit();
    try rt.sendIngressRoute(handle.control_fd, &second_dispatch, 3, .{});
    var second_fault = try support.readFsFaultRequest(std.testing.allocator, handle.fs_fault_fd, 8_000);
    defer second_fault.deinit();
    try std.testing.expectEqualStrings(fs_fault_e2e_path, second_fault.path);
    try support.respondFsFaultOk(handle.fs_fault_fd, second_fault.fault_id, fs_fault_e2e_content);
    var second_response = try readForkedIngressResponse(handle, 51, 8_000);
    defer second_response.deinit();
    try std.testing.expectEqualStrings("resolved:" ++ fs_fault_e2e_content, second_response.body);
}

// ---------------------------------------------------------------------------
// Synchronous faults, the stash of async answers during a synchronous wait,
// the module evaluation window, whose fault requests carry the boot
// context's all-zero identity, and how evaluation failures end. The harness
// plays the host on the fault channel; during
// evaluation the launch machine's fault-serve callback (runToReady) answers
// faults inline, one at a time, between WorkerInit and the init outcome.

const fs_fault_stash_path = "data/stash.txt";
const fs_fault_stash_content = "stash bytes for the sync wait\n";

fn createFsFaultStashIndexMemfd(allocator: std.mem.Allocator) !std.posix.fd_t {
    var hello_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(fs_fault_e2e_content, &hello_digest, .{});
    var stash_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(fs_fault_stash_content, &stash_digest, .{});
    // Index order: the paths sort hello before stash.
    return createTestFsIndexMemfd(allocator, 1_730_000_000_123, &.{
        .{ .path = fs_fault_e2e_path, .size = fs_fault_e2e_content.len, .sha256 = hello_digest },
        .{ .path = fs_fault_stash_path, .size = fs_fault_stash_content.len, .sha256 = stash_digest },
    });
}

test "worker fs fault: sync readFileSync miss faults, harness serves, bytes return" {
    var spawned = try support.spawnZygote();
    defer spawned.deinit();

    const fs_index_memfd = try createFsFaultFixtureIndexMemfd(std.testing.allocator);
    defer std.posix.close(fs_index_memfd);

    const route_specifier = "/__collo_route/test/fs-fault-f3-sync.js";
    const route_fd = try rt.createModulePackFd(route_specifier,
        \\import fs from "node:fs";
        \\export default function handle() {
        \\  const content = fs.readFileSync("data/hello.txt", "utf8");
        \\  return new Response("sync:" + content);
        \\}
    );
    defer std.posix.close(route_fd);
    var route = try rt.SingleRoute.init(route_fd, route_specifier);
    defer route.deinit();

    var launched = try launchOrSkip(&spawned, 90_010, .{
        .fs_index_memfd = fs_index_memfd,
        .routes = route.launchRoutes(),
    });
    defer launched.deinit();
    const handle = &launched.handle;

    var dispatch = try rt.initDispatchWork(std.testing.allocator, .{
        .request_id = 60,
        .deadline_monotonic_ns = try forkedDeadlineNs(),
    });
    defer dispatch.deinit();
    try rt.sendIngressRoute(handle.control_fd, &dispatch, 1, .{});

    // The worker is blocked inside readFileSync until this answers.
    var fault_request = try support.readFsFaultRequest(std.testing.allocator, handle.fs_fault_fd, 8_000);
    defer fault_request.deinit();
    try std.testing.expectEqualStrings(fs_fault_e2e_path, fault_request.path);
    try std.testing.expectEqual(@as(u64, 60), fault_request.request_id);
    try support.respondFsFaultOk(handle.fs_fault_fd, fault_request.fault_id, fs_fault_e2e_content);

    var response = try readForkedIngressResponse(handle, 60, 8_000);
    defer response.deinit();
    try std.testing.expectEqualStrings("sync:" ++ fs_fault_e2e_content, response.body);

    var trace = try support.drainTrace(&spawned, std.testing.allocator);
    defer trace.deinit();
    try support.expectTraceBefore(
        trace,
        "worker.fs_fault.sent=" ++ fs_fault_e2e_path,
        "worker.fs_fault.settled=" ++ fs_fault_e2e_path,
    );
}

test "worker fs fault: async response during sync wait is stashed, both settle" {
    var spawned = try support.spawnZygote();
    defer spawned.deinit();

    const fs_index_memfd = try createFsFaultStashIndexMemfd(std.testing.allocator);
    defer std.posix.close(fs_index_memfd);

    const route_specifier = "/__collo_route/test/fs-fault-f3-stash.js";
    const route_fd = try rt.createModulePackFd(route_specifier,
        \\import fs from "node:fs";
        \\export default async function handle() {
        \\  const pending = fs.promises.readFile("data/hello.txt", "utf8");
        \\  const syncContent = fs.readFileSync("data/stash.txt", "utf8");
        \\  const asyncContent = await pending;
        \\  return new Response("sync:" + syncContent + "|async:" + asyncContent);
        \\}
    );
    defer std.posix.close(route_fd);
    var route = try rt.SingleRoute.init(route_fd, route_specifier);
    defer route.deinit();

    var launched = try launchOrSkip(&spawned, 90_011, .{
        .fs_index_memfd = fs_index_memfd,
        .routes = route.launchRoutes(),
    });
    defer launched.deinit();
    const handle = &launched.handle;

    var dispatch = try rt.initDispatchWork(std.testing.allocator, .{
        .request_id = 62,
        .deadline_monotonic_ns = try forkedDeadlineNs(),
    });
    defer dispatch.deinit();
    try rt.sendIngressRoute(handle.control_fd, &dispatch, 1, .{});

    // Wire order: the async fault leaves first, then the sync fault blocks
    // the worker. Answering the async one first lands its response inside
    // the sync wait, which is the stash path.
    var async_fault = try support.readFsFaultRequest(std.testing.allocator, handle.fs_fault_fd, 8_000);
    defer async_fault.deinit();
    try std.testing.expectEqualStrings(fs_fault_e2e_path, async_fault.path);
    var sync_fault = try support.readFsFaultRequest(std.testing.allocator, handle.fs_fault_fd, 8_000);
    defer sync_fault.deinit();
    try std.testing.expectEqualStrings(fs_fault_stash_path, sync_fault.path);

    try support.respondFsFaultOk(handle.fs_fault_fd, async_fault.fault_id, fs_fault_e2e_content);
    try support.respondFsFaultOk(handle.fs_fault_fd, sync_fault.fault_id, fs_fault_stash_content);

    var response = try readForkedIngressResponse(handle, 62, 8_000);
    defer response.deinit();
    try std.testing.expectEqualStrings(
        "sync:" ++ fs_fault_stash_content ++ "|async:" ++ fs_fault_e2e_content,
        response.body,
    );

    var trace = try support.drainTrace(&spawned, std.testing.allocator);
    defer trace.deinit();
    // The async response was consumed inside the sync wait without loss, and
    // its waiters settled through the normal completion path afterwards.
    try std.testing.expect(trace.containsPrefix("worker.fs_fault.stashed=" ++ fs_fault_e2e_path));
    try support.expectTraceBefore(
        trace,
        "worker.fs_fault.stashed=" ++ fs_fault_e2e_path,
        "worker.fs_fault.settled=" ++ fs_fault_e2e_path,
    );
}

test "worker fs fault: withheld sync fault answer 504s within the request deadline" {
    var spawned = try support.spawnZygote();
    defer spawned.deinit();

    const fs_index_memfd = try createFsFaultFixtureIndexMemfd(std.testing.allocator);
    defer std.posix.close(fs_index_memfd);

    const route_specifier = "/__collo_route/test/fs-fault-f3-stuck.js";
    const route_fd = try rt.createModulePackFd(route_specifier,
        \\import fs from "node:fs";
        \\export default function handle() {
        \\  const content = fs.readFileSync("data/hello.txt");
        \\  return new Response("sync:" + content);
        \\}
    );
    defer std.posix.close(route_fd);
    var route = try rt.SingleRoute.init(route_fd, route_specifier);
    defer route.deinit();

    var launched = try launchOrSkip(&spawned, 90_012, .{
        .fs_index_memfd = fs_index_memfd,
        .routes = route.launchRoutes(),
    });
    defer launched.deinit();
    const handle = &launched.handle;

    // A short deadline: the ppoll horizon is the request's remaining budget,
    // so the withheld answer surfaces as the request's own 504 well inside
    // the reader budget below, never as an unbounded block.
    var dispatch = try rt.initDispatchWork(std.testing.allocator, .{
        .request_id = 64,
        .deadline_monotonic_ns = (try process.monotonicNowNs()) + 2 * std.time.ns_per_s,
    });
    defer dispatch.deinit();
    try rt.sendIngressRoute(handle.control_fd, &dispatch, 1, .{});

    // The host receives the fault and never answers it.
    var fault_request = try support.readFsFaultRequest(std.testing.allocator, handle.fs_fault_fd, 8_000);
    defer fault_request.deinit();
    try std.testing.expectEqualStrings(fs_fault_e2e_path, fault_request.path);

    var response = try readForkedIngressResponse(handle, 64, 8_000);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 504), response.status);
}

test "worker fs fault: boot context fault after ready is denied fail-closed" {
    var spawned = try support.spawnZygote();
    defer spawned.deinit();

    const fs_index_memfd = try createFsFaultFixtureIndexMemfd(std.testing.allocator);
    defer std.posix.close(fs_index_memfd);

    const route_specifier = "/__collo_route/test/fs-fault-f3-postready.js";
    const route_fd = try rt.createModulePackFd(route_specifier,
        \\import fs from "node:fs";
        \\export default function handle() { return new Response(globalThis.__boot_read); }
        \\globalThis.__boot_read = "pending";
        \\await new Promise((resolve) => setTimeout(resolve, 100));
        \\try {
        \\  await fs.promises.readFile("data/hello.txt");
        \\  globalThis.__boot_read = "resolved";
        \\} catch (e) {
        \\  globalThis.__boot_read = "denied";
        \\}
    );
    defer std.posix.close(route_fd);
    var route = try rt.SingleRoute.init(route_fd, route_specifier);
    defer route.deinit();

    // A route delivered at init: the synchronous slice of its evaluation
    // runs before ready, and the timer-parked continuation, with its
    // readFile, runs after ready, outside the evaluation window, where the
    // worker must deny it locally with no traffic on the fault channel. The
    // route makes the launch serve routes, which installs the boot context
    // that top-level timers need.
    var launched = try launchOrSkip(&spawned, 90_013, .{
        .fs_index_memfd = fs_index_memfd,
        .routes = route.launchRoutes(),
    });
    defer launched.deinit();
    const handle = &launched.handle;

    // The denial happens when the module's timer fires, shortly after
    // ready; the fault channel must stay silent through it.
    try support.expectNoFsFaultRequest(handle.fs_fault_fd, 600);

    var dispatch = try rt.initDispatchWork(std.testing.allocator, .{
        .request_id = 66,
        .deadline_monotonic_ns = try forkedDeadlineNs(),
    });
    defer dispatch.deinit();
    try rt.sendIngressRoute(handle.control_fd, &dispatch, 1, .{});
    var response = try readForkedIngressResponse(handle, 66, 8_000);
    defer response.deinit();
    try std.testing.expectEqualStrings("denied", response.body);

    var trace = try support.drainTrace(&spawned, std.testing.allocator);
    defer trace.deinit();
    try std.testing.expect(trace.containsPrefix("worker.fs_fault.boot_denied=" ++ fs_fault_e2e_path));
}

test "worker fs fault: a sync read during module evaluation is served under the boot context's all-zero identity" {
    var spawned = try support.spawnZygote();
    defer spawned.deinit();

    const fs_index_memfd = try createFsFaultFixtureIndexMemfd(std.testing.allocator);
    defer std.posix.close(fs_index_memfd);

    const route_specifier = "/__collo_route/test/fs-fault-f3-bootwindow.js";
    const route_fd = try rt.createModulePackFd(route_specifier,
        \\import fs from "node:fs";
        \\const content = fs.readFileSync("data/hello.txt", "utf8");
        \\export default function handle() { return new Response("boot:" + content); }
    );
    defer std.posix.close(route_fd);
    var route = try rt.SingleRoute.init(route_fd, route_specifier);
    defer route.deinit();

    // The evaluation-window fault policy, through the launch's serve
    // callback: the all-zero boot identity with the known path serves the
    // fixture, any other identity is refused, and any other path is not
    // found. The drain owns the fd it is handed, so every answer carries a
    // fresh dup.
    const content_fd = try createSealedMemfdFromBytes(fs_fault_e2e_content);
    defer std.posix.close(content_fd);
    const FaultPolicy = struct {
        path: []const u8,
        content_fd: std.posix.fd_t,
        served_boot_reads: usize = 0,

        fn serve(
            ctx: ?*anyopaque,
            request: *const zygote.ipc.FsFaultRequest,
            _: u64,
        ) host.launch.FaultAnswer {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (request.request_id != 0 or request.request_generation != 0 or
                request.worker_id != 0 or request.worker_generation != 0)
                return .refused;
            if (!std.mem.eql(u8, request.path, self.path))
                return .not_found;
            const served_fd = std.posix.dup(self.content_fd) catch return .fetch_failed;
            self.served_boot_reads += 1;
            return .{ .ok = served_fd };
        }
    };
    var fault_policy = FaultPolicy{ .path = fs_fault_e2e_path, .content_fd = content_fd };
    var launched = try launchOrSkip(&spawned, 90_014, .{
        .fs_index_memfd = fs_index_memfd,
        .routes = route.launchRoutes(),
        .fault_serve = .{ .serve = .{
            .ctx = &fault_policy,
            .serve = FaultPolicy.serve,
        } },
    });
    defer launched.deinit();
    const handle = &launched.handle;
    try std.testing.expectEqual(@as(usize, 1), fault_policy.served_boot_reads);

    var dispatch = try rt.initDispatchWork(std.testing.allocator, .{
        .request_id = 68,
        .deadline_monotonic_ns = try forkedDeadlineNs(),
    });
    defer dispatch.deinit();
    try rt.sendIngressRoute(handle.control_fd, &dispatch, 1, .{});
    var response = try readForkedIngressResponse(handle, 68, 8_000);
    defer response.deinit();
    try std.testing.expectEqualStrings("boot:" ++ fs_fault_e2e_content, response.body);

    var trace = try support.drainTrace(&spawned, std.testing.allocator);
    defer trace.deinit();
    try support.expectTraceBefore(
        trace,
        "worker.fs_fault.sent=" ++ fs_fault_e2e_path,
        "worker.fs_fault.settled=" ++ fs_fault_e2e_path,
    );
}

test "a fetch during module evaluation whose origin answers 600 rejects instead of hanging" {
    var origin = try Origin600.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);

    var gateway = try rt.LocalEgressGateway.start(std.testing.allocator, .{
        .network = rt.local_origin_network,
    });
    defer gateway.deinit();
    var egress_shared_fds = gateway.takeWorkerSharedFds();
    defer egress_shared_fds.close();

    var spawned = try support.spawnZygote();
    defer spawned.deinit();

    const route_specifier = "/__collo_route/test/fs-fault-f3-c55.js";
    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\export default function handle() {{ return new Response(globalThis.__boot_fetch); }}
        \\globalThis.__boot_fetch = "pending";
        \\try {{
        \\  const res = await fetch("http://{s}:{d}/");
        \\  globalThis.__boot_fetch = "status:" + res.status;
        \\}} catch (e) {{
        \\  globalThis.__boot_fetch = "rejected";
        \\}}
    , .{ origin.host(), origin.port });
    defer std.testing.allocator.free(source);
    const route_fd = try rt.createModulePackFd(route_specifier, source);
    defer std.posix.close(route_fd);
    var route = try rt.SingleRoute.init(route_fd, route_specifier);
    defer route.deinit();

    var launched = try launchOrSkip(&spawned, 90_015, .{
        .egress = .{ .attached = .{
            .shared_fds = egress_shared_fds,
            .boot = rt.localBootEgress(),
        } },
        .routes = route.launchRoutes(),
    });
    defer launched.deinit();
    const handle = &launched.handle;

    // Status 600 is outside the range the Response bridge accepts, so the
    // head ends as a typed fetch error and the module's fetch rejects; the
    // module catches it and its evaluation settles instead of pending
    // forever.
    var dispatch = try rt.initDispatchWork(std.testing.allocator, .{
        .request_id = 70,
        .deadline_monotonic_ns = try forkedDeadlineNs(),
    });
    defer dispatch.deinit();
    try rt.sendIngressRoute(handle.control_fd, &dispatch, 1, .{});
    var response = try readForkedIngressResponse(handle, 70, 15_000);
    defer response.deinit();
    try std.testing.expectEqualStrings("rejected", response.body);
}

test "a synchronous throw during module evaluation pins the route failed and its handler never serves" {
    var spawned = try support.spawnZygote();
    defer spawned.deinit();

    const route_specifier = "/__collo_route/test/fs-fault-f3-c56.js";
    const route_fd = try rt.createModulePackFd(route_specifier,
        \\export default function handle() { return new Response("should-not-serve"); }
        \\throw new Error("boot init failed");
    );
    defer std.posix.close(route_fd);
    var route = try rt.SingleRoute.init(route_fd, route_specifier);
    defer route.deinit();

    // The sync throw happens after the hoisted default export initialized:
    // without the sticky failed record the per-request re-import would serve
    // the handler of an init that failed. The failure is the tenant code's,
    // so the worker still becomes ready, but it must answer 500.
    var launched = try launchOrSkip(&spawned, 90_016, .{
        .routes = route.launchRoutes(),
    });
    defer launched.deinit();
    const handle = &launched.handle;

    var dispatch = try rt.initDispatchWork(std.testing.allocator, .{
        .request_id = 72,
        .deadline_monotonic_ns = try forkedDeadlineNs(),
    });
    defer dispatch.deinit();
    try rt.sendIngressRoute(handle.control_fd, &dispatch, 1, .{});
    var response = try readForkedIngressResponse(handle, 72, 8_000);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 500), response.status);
    try std.testing.expect(!std.mem.containsAtLeast(u8, response.body, 1, "should-not-serve"));
}

/// One-connection HTTP/1.1 origin answering status 600, outside the Response
/// bridge's [200, 599] on purpose. The route fetches it at the routable local
/// IPv4 address, since the egress policy denies loopback even with private
/// networks allowed.
const Origin600 = struct {
    server: std.net.Server,
    host_buffer: [64]u8,
    host_len: usize,
    port: u16,
    thread: std.Thread,

    fn start(allocator: std.mem.Allocator) !*Origin600 {
        var host_buffer: [64]u8 = undefined;
        const host_slice = try rt.test_net.routableLocalIpv4(&host_buffer);
        const address = try std.net.Address.parseIp4("0.0.0.0", 0);
        var server = try address.listen(.{ .reuse_address = true });
        errdefer server.deinit();
        const origin = try allocator.create(Origin600);
        errdefer allocator.destroy(origin);
        origin.* = .{
            .server = server,
            .host_buffer = host_buffer,
            .host_len = host_slice.len,
            .port = server.listen_address.getPort(),
            .thread = undefined,
        };
        origin.thread = try std.Thread.spawn(.{}, Origin600.threadMain, .{origin});
        return origin;
    }

    fn host(self: *const Origin600) []const u8 {
        return self.host_buffer[0..self.host_len];
    }

    fn stop(self: *Origin600, allocator: std.mem.Allocator) void {
        // Unblock accept() if no connection ever arrived.
        const address = std.net.Address.parseIp(self.host(), self.port) catch null;
        if (address) |addr| {
            if (std.net.tcpConnectToAddress(addr)) |stream| {
                stream.close();
            } else |_| {}
        }
        self.thread.join();
        self.server.deinit();
        allocator.destroy(self);
    }

    fn threadMain(self: *Origin600) void {
        var connection = self.server.accept() catch return;
        defer connection.stream.close();
        var buffer: [2048]u8 = undefined;
        var received_len: usize = 0;
        while (received_len < buffer.len) {
            const amount = connection.stream.read(buffer[received_len..]) catch return;
            if (amount == 0)
                break;
            received_len += amount;
            if (std.mem.indexOf(u8, buffer[0..received_len], "\r\n\r\n") != null)
                break;
        }
        connection.stream.writeAll(
            "HTTP/1.1 600 Not A Status\r\ncontent-length: 0\r\nconnection: close\r\n\r\n",
        ) catch return;
    }
};

test "a worker that loses its egress gateway keeps serving, refuses fetch with a TypeError and fetches again after egress_attach" {
    // Each origin serves one connection: the first answers the fetch made
    // before the gateway goes, the second the fetch made after the reattach.
    var before_origin = try rt.LocalOrigin.start(std.testing.allocator);
    defer before_origin.stop(std.testing.allocator);
    var after_origin = try rt.LocalOrigin.start(std.testing.allocator);
    defer after_origin.stop(std.testing.allocator);

    var spawned = try support.spawnZygote();
    defer spawned.deinit();

    // The host keeps the worker's wake set, which every session of the worker
    // is built on.
    var wake_set = try zygote.ipc.egress_shared.WakeSet.create();
    defer wake_set.deinit();
    var first_gateway = try rt.LocalEgressGateway.startOnWakeSet(std.testing.allocator, .{
        .network = rt.local_origin_network,
    }, &wake_set);
    var first_gateway_alive = true;
    defer if (first_gateway_alive) first_gateway.deinit();
    var first_fds = first_gateway.takeWorkerSharedFds();
    defer first_fds.close();

    // The request path picks the origin, and a refused fetch answers with the
    // class of its error.
    const route_specifier = "/__collo_route/test/egress-reattach.js";
    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\export default async function handle(request) {{
        \\  const port = new URL(request.url).pathname === "/before" ? {d} : {d};
        \\  try {{
        \\    const res = await fetch("http://{s}:" + port + "/binary");
        \\    return new Response("fetched:" + res.status);
        \\  }} catch (err) {{
        \\    return new Response(err instanceof TypeError ? "TypeError" : "other:" + String(err));
        \\  }}
        \\}}
    , .{ before_origin.port, after_origin.port, before_origin.host() });
    defer std.testing.allocator.free(source);
    const route_fd = try rt.createModulePackFd(route_specifier, source);
    defer std.posix.close(route_fd);
    var route = try rt.SingleRoute.init(route_fd, route_specifier);
    defer route.deinit();

    var launched = try launchOrSkip(&spawned, 90_020, .{
        .egress = .{ .attached = .{
            .shared_fds = first_fds,
            .boot = rt.localBootEgress(),
        } },
        .routes = route.launchRoutes(),
    });
    defer launched.deinit();
    const handle = &launched.handle;

    const before_body = try forkedRequestBody(handle,90_020, 1, "/before");
    defer std.testing.allocator.free(before_body);
    try std.testing.expectEqualStrings("fetched:200", before_body);
    var starts: [2]rt.FetchStartIdentity = undefined;
    try std.testing.expectEqual(@as(usize, 1), first_gateway.recordedFetchStarts(&starts));

    // Ending the gateway closes its end of the session's liveness pipe, which
    // the worker sees as `egress_closed`. Whether this request's fetch comes
    // before or after the worker handles it, the fetch fails with a TypeError
    // and the worker keeps serving.
    first_gateway_alive = false;
    first_gateway.deinit();
    const during_body = try forkedRequestBody(handle,90_021, 3, "/during");
    defer std.testing.allocator.free(during_body);
    try std.testing.expectEqualStrings("TypeError", during_body);
    try std.testing.expect(!process.pidFdHasExited(handle.pidfd));

    // The host attaches the worker to a new gateway, as the launcher does once
    // one is up, and the next fetch goes through it under its request's
    // token.
    var second_gateway = try attachToNewGateway(handle, &wake_set);
    defer second_gateway.deinit();

    const after_body = try forkedRequestBody(handle,90_022, 5, "/after");
    defer std.testing.allocator.free(after_body);
    try std.testing.expectEqualStrings("fetched:200", after_body);
    try std.testing.expectEqual(@as(usize, 1), second_gateway.recordedFetchStarts(&starts));
    const presented = try rt.verifyEgressToken(&starts[0].egress_token);
    try std.testing.expectEqual(@as(u64, 90_022), presented.request_id);
    try std.testing.expectEqual(@as(usize, 1), after_origin.accepted.load(.acquire));
}

test "an egress_attach to a worker still attached fails its fetch in flight with a TypeError and moves the worker to the new gateway" {
    // A listener that completes handshakes from its backlog but never
    // accepts: the first fetch connects, sends and stays in flight.
    var host_buffer: [64]u8 = undefined;
    const silent_host = try rt.test_net.routableLocalIpv4(&host_buffer);
    var bind_address = try std.net.Address.parseIp4("0.0.0.0", 0);
    var silent_server = try bind_address.listen(.{ .reuse_address = true });
    defer silent_server.deinit();
    var origin = try rt.LocalOrigin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);

    var spawned = try support.spawnZygote();
    defer spawned.deinit();

    var wake_set = try zygote.ipc.egress_shared.WakeSet.create();
    defer wake_set.deinit();
    var first_gateway = try rt.LocalEgressGateway.startOnWakeSet(std.testing.allocator, .{
        .network = rt.local_origin_network,
    }, &wake_set);
    var first_gateway_alive = true;
    defer if (first_gateway_alive) first_gateway.deinit();
    var first_fds = first_gateway.takeWorkerSharedFds();
    defer first_fds.close();

    const route_specifier = "/__collo_route/test/egress-replace.js";
    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\export default async function handle(request) {{
        \\  const target = new URL(request.url).pathname === "/hang"
        \\    ? "http://{s}:{d}/hang"
        \\    : "http://{s}:{d}/binary";
        \\  try {{
        \\    const res = await fetch(target);
        \\    return new Response("fetched:" + res.status);
        \\  }} catch (err) {{
        \\    return new Response(err instanceof TypeError ? "TypeError:" + err.message : "other:" + String(err));
        \\  }}
        \\}}
    , .{ silent_host, silent_server.listen_address.getPort(), origin.host(), origin.port });
    defer std.testing.allocator.free(source);
    const route_fd = try rt.createModulePackFd(route_specifier, source);
    defer std.posix.close(route_fd);
    var route = try rt.SingleRoute.init(route_fd, route_specifier);
    defer route.deinit();

    var launched = try launchOrSkip(&spawned, 90_021, .{
        .egress = .{ .attached = .{
            .shared_fds = first_fds,
            .boot = rt.localBootEgress(),
        } },
        .routes = route.launchRoutes(),
    });
    defer launched.deinit();
    const handle = &launched.handle;

    try sendForkedRequest(handle,90_021, 1, "/hang");
    try waitForFetchStarts(first_gateway, 1, 8_000);

    // The worker still holds the first gateway's session when the host
    // attaches it to a new one, so it detaches first, which fails the fetch
    // in flight.
    var second_gateway = try attachToNewGateway(handle, &wake_set);
    defer second_gateway.deinit();
    const hang_body = try readForkedBody(handle, 90_021);
    defer std.testing.allocator.free(hang_body);
    try std.testing.expectEqualStrings("TypeError:fetch failed: egress gateway closed", hang_body);

    // Both gateways wake on the worker's one command eventfd, so the first
    // ends before the next fetch. The liveness pipe keeps the second
    // gateway's end, so the first one's exit does not detach the worker.
    first_gateway_alive = false;
    first_gateway.deinit();
    const after_body = try forkedRequestBody(handle,90_022, 3, "/after");
    defer std.testing.allocator.free(after_body);
    try std.testing.expectEqualStrings("fetched:200", after_body);
    var starts: [2]rt.FetchStartIdentity = undefined;
    try std.testing.expectEqual(@as(usize, 1), second_gateway.recordedFetchStarts(&starts));
    try std.testing.expect(!process.pidFdHasExited(handle.pidfd));
}

/// Starts a gateway on a new egress session of the forked worker behind
/// `handle` and hands the worker that session in an `egress_attach` packet on
/// its control socket, as the launcher does once a new gateway is up. The
/// session is built on `wake_set`, the worker's, which the host keeps: the
/// worker's ring polls only the files it registered at boot, and nothing can
/// change that table afterwards (`common/io/restricted_uring.zig`). The new
/// session's write end of the liveness pipe also ends the hang-up an earlier
/// gateway's exit left on it.
fn attachToNewGateway(
    handle: *host.WorkerHandle,
    wake_set: *const zygote.ipc.egress_shared.WakeSet,
) !*rt.LocalEgressGateway {
    const gateway = try rt.LocalEgressGateway.startOnWakeSet(std.testing.allocator, .{
        .network = rt.local_origin_network,
    }, wake_set);
    errdefer gateway.deinit();
    var worker_half = gateway.takeWorkerSharedFds();
    defer worker_half.close();
    try zygote.ipc.egress_attach.send(handle.control_fd, worker_half);
    return gateway;
}

/// Waits up to `budget_ms` for `gateway` to record `count` fetch starts.
fn waitForFetchStarts(gateway: *rt.LocalEgressGateway, count: usize, budget_ms: u32) !void {
    var starts: [4]rt.FetchStartIdentity = undefined;
    std.debug.assert(count <= starts.len);
    var waited_ms: u32 = 0;
    while (gateway.recordedFetchStarts(&starts) < count) : (waited_ms += 1) {
        if (waited_ms >= budget_ms)
            return error.FetchNeverStarted;
        std.Thread.sleep(std.time.ns_per_ms);
    }
}

/// Sends one request for `path` to the one route a forked worker serves, on
/// `stream_id`, which must be odd as a client-initiated HTTP/2 stream's is.
fn sendForkedRequest(
    handle: *host.WorkerHandle,
    request_id: u64,
    stream_id: u32,
    path: []const u8,
) !void {
    const request = rt.RequestParts{ .path = path };
    var dispatch = try rt.initDispatchWork(std.testing.allocator, .{
        .request_id = request_id,
        .deadline_monotonic_ns = try forkedDeadlineNs(),
        .request = request,
    });
    defer dispatch.deinit();
    try rt.sendIngressRoute(handle.control_fd, &dispatch, stream_id, request);
}

/// Reads the response to `request_id`, which must be a 200, and returns its
/// body; the caller owns the body.
fn readForkedBody(handle: *host.WorkerHandle, request_id: u64) ![]u8 {
    var response = try readForkedIngressResponse(handle, request_id, 8_000);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 200), response.status);
    return response.takeBody();
}

/// `sendForkedRequest` and then `readForkedBody`.
fn forkedRequestBody(
    handle: *host.WorkerHandle,
    request_id: u64,
    stream_id: u32,
    path: []const u8,
) ![]u8 {
    try sendForkedRequest(handle,request_id, stream_id, path);
    return readForkedBody(handle, request_id);
}

test "worker init fails closed on an invalid fs index" {
    var spawned = try support.spawnZygote();
    defer spawned.deinit();

    // Sealed, so it passes the fd validation, but not a COLLOFS1 index: the
    // child's map and parse fail the init rather than boot with a broken view
    // of the file tree.
    const bad_index_fd = try createSealedMemfdFromBytes("definitely not an fs index");
    defer std.posix.close(bad_index_fd);

    if (launchOrSkip(&spawned, 90_017, .{ .fs_index_memfd = bad_index_fd })) |launched_value| {
        var launched = launched_value;
        launched.deinit();
        return error.UnexpectedWorkerReady;
    } else |err| switch (err) {
        // A failed launch has already terminated the child and waited for
        // its exit.
        error.WorkerInitFailed => {},
        else => return err,
    }

    spawned.shutdown();
    try support.expectChildExitStatus(spawned.pid, 0);

    var trace = try support.drainTrace(&spawned, std.testing.allocator);
    defer trace.deinit();
    try std.testing.expect(trace.containsPrefix("child.fs_index.invalid"));
    try std.testing.expect(!trace.containsPrefix("child.fs_index.mapped"));
    try std.testing.expect(!trace.containsPrefix("child.worker_ready"));
}

// WebAssembly must keep a worker alive after seccomp. The JSC wasm compile
// worklist starts its thread lazily with `clone`, which the filter denies
// with EPERM, and the failed Thread::create aborts the worker while its
// metrics still read ready. The worker therefore starts the worklist threads
// in the boot window between the sandbox's privilege boundary and seccomp
// (`collo_vm_prespawn_compiler_threads`, which starts the JS worklist in the
// same call) and keeps them from retiring.
//
// Instantiation, async compilation and the IPInt-to-BBQ tier-up under a hot
// loop each run in their own worker, so an abort in one cannot mask the
// others, and each must leave its worker alive with its metrics reading
// ready. Each must also settle: the scheduler pumps JSC's DeferredWorkTimer
// (`pumpDeferredWork` in `worker/scheduler/loop.zig`) in place of the
// RunLoop, which a worker never runs because the scheduler is its event
// loop, and the worklist thread wakes a blocked loop through the eventfd
// registered with `collo_vm_set_deferred_work_wakeup_fd`. The assertion is
// therefore the exact 200 body of each case: a worker that survives without
// settling fails, and a death shows the DIED diagnosis instead of a body.
fn wasmOutcomeSurvived(outcome: []const u8, expected_200_body: []const u8) bool {
    return std.mem.eql(u8, outcome, expected_200_body);
}
fn probeWasmOutcome(allocator: std.mem.Allocator, request_id: u64, source: []const u8) ![]u8 {
    var spawned = try support.spawnZygote();
    defer spawned.deinit();

    const route_specifier = "/__collo_route/test/wasm-probe.js";
    const route_fd = try rt.createModulePackFd(route_specifier, source);
    defer std.posix.close(route_fd);
    var route = try rt.SingleRoute.init(route_fd, route_specifier);
    defer route.deinit();

    var launched = support.launchWorker(
        allocator,
        &spawned,
        worker_memory_limit_bytes,
        request_id,
        .{ .routes = route.launchRoutes() },
    ) catch |err| switch (err) {
        error.WorkerCgroupDelegationUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer launched.deinit();
    const handle = &launched.handle;

    var dispatch = try rt.initDispatchWork(allocator, .{
        .request_id = request_id,
        .deadline_monotonic_ns = try forkedDeadlineNs(),
    });
    defer dispatch.deinit();
    try rt.sendIngressRoute(handle.control_fd, &dispatch, 1, .{});

    // A denied clone aborts the worker. The "DIED" text, with the metrics
    // page state and whether the process exited, is returned instead of an
    // error, so a worklist thread that was not started early fails the
    // caller's assertion with the full diagnosis, whose error name and
    // `process_exited` tell a death from a hang.
    var response = readForkedIngressResponse(handle, request_id, 8_000) catch |err| {
        const state_raw: u32 = if (handle.metrics) |m| m.header.state else 0xffff_ffff;
        const reason_raw: u32 = if (handle.metrics) |m| m.header.termination_reason else 0xffff_ffff;
        const exited = process.pidFdHasExited(handle.pidfd);
        return std.fmt.allocPrint(
            allocator,
            "DIED:{s} state={d} termination_reason={d} process_exited={}",
            .{ @errorName(err), state_raw, reason_raw, exited },
        );
    };
    defer response.deinit();
    return allocator.dupe(u8, response.body);
}

test "wasm instantiate, compile, and tier-up keep the worker alive after seccomp with a pre-spawned worklist" {
    // Minimal module `bytes`: exports f() -> i32 returning 42.
    const wrapper_prefix =
        \\export default async function handle() {
        \\  const bytes = new Uint8Array([
        \\    0x00,0x61,0x73,0x6d, 0x01,0x00,0x00,0x00,
        \\    0x01,0x05,0x01,0x60,0x00,0x01,0x7f,
        \\    0x03,0x02,0x01,0x00,
        \\    0x07,0x05,0x01,0x01,0x66,0x00,0x00,
        \\    0x0a,0x06,0x01,0x04,0x00,0x41,0x2a,0x0b,
        \\  ]);
        \\  let outcome = "none";
        \\  try {
        \\
    ;
    const wrapper_suffix =
        \\
        \\  } catch (e) {
        \\    outcome = "error:" + (e && e.name ? e.name : String(e));
        \\  }
        \\  return new Response(outcome);
        \\}
    ;
    const Case = struct { name: []const u8, id: u64, body: []const u8, expected: []const u8 };
    const cases = [_]Case{
        .{ .name = "instantiate", .id = 77, .expected = "ok:instantiate:42", .body = 
        \\    const { instance } = await WebAssembly.instantiate(bytes);
        \\    outcome = "ok:instantiate:" + instance.exports.f();
        },
        .{ .name = "compile", .id = 78, .expected = "ok:compile:true", .body = 
        \\    const mod = await WebAssembly.compile(bytes);
        \\    outcome = "ok:compile:" + (mod instanceof WebAssembly.Module);
        },
        .{ .name = "tierup", .id = 79, .expected = "ok:tierup:126000000", .body = 
        \\    const { instance } = await WebAssembly.instantiate(bytes);
        \\    let acc = 0;
        \\    for (let i = 0; i < 3000000; i++) acc += instance.exports.f();
        \\    outcome = "ok:tierup:" + acc;
        },
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(
            std.testing.allocator,
            "{s}{s}{s}",
            .{ wrapper_prefix, case.body, wrapper_suffix },
        );
        defer std.testing.allocator.free(source);
        const outcome = try probeWasmOutcome(std.testing.allocator, case.id, source);
        defer std.testing.allocator.free(outcome);
        std.debug.print("wasm[{s}]: {s}\n", .{ case.name, outcome });
        // A death shows the DIED diagnosis and a worker that survives
        // without settling shows the timeout diagnosis; both fail here with
        // the observed outcome.
        if (!wasmOutcomeSurvived(outcome, case.expected)) {
            std.debug.print(
                "wasm[{s}] failed: expected exact 200 body '{s}' (survive and settle)\n",
                .{ case.name, case.expected },
            );
            return error.TestUnexpectedResult;
        }
    }
}

/// A dispatch deadline on the real monotonic clock for a forked worker. The
/// harness default (`DispatchParts.deadline_monotonic_ns`) is an instant on
/// the in-process fake clock, long past on the real one, so a forked worker
/// would answer every request with a 504 before running the handler.
fn forkedDeadlineNs() !u64 {
    return (try process.monotonicNowNs()) + 30 * std.time.ns_per_s;
}

/// Reads the response to `request_id` from a forked worker's handle within
/// `budget_ms`, with the harness byte caps (`host.dispatch.readResponse`);
/// the caller owns the response.
fn readForkedIngressResponse(
    handle: *host.WorkerHandle,
    request_id: u64,
    budget_ms: u32,
) !host.dispatch.Response {
    return host.dispatch.readResponse(std.testing.allocator, handle.completionChannels(), request_id, .{
        .wall_ms = budget_ms,
        .max_body_bytes = rt.default_read_max_body_bytes,
        .max_headers_bytes = rt.default_read_max_headers_bytes,
    });
}

test "bounded response reader errors on a malformed trailing control packet" {
    // Once the completion record is visible on the metrics page, the bounded
    // reader drains the frames still queued on the control fd. A malformed
    // frame there, such as kind 8, which names no message, surfaces as the
    // decode error instead of a partial response returned as success. No
    // worker is involved: an in-process socketpair and the metrics fixture,
    // with this side playing both ends.
    const ipc = zygote.ipc;
    var fixture = try rt.CompletionFixture.init();
    defer fixture.deinit();
    const completion_eventfd = try rt.createCompletionEventfd();
    defer std.posix.close(completion_eventfd);

    const pair = try rt.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    const server_fd = pair[0];
    const worker_fd = pair[1];
    defer std.posix.close(server_fd);
    defer std.posix.close(worker_fd);

    // The worker's side: a complete, well-formed response for request 91...
    const request_id: u64 = 91;
    const identity = ipc.ingress_channel.RequestIdentity{
        .request_id = request_id,
        .request_generation = 1,
        .request_lane_id = 0,
        .request_slot = 0,
    };
    var send_scratch: [ipc.max_message_bytes]u8 = undefined;
    var head_scratch: [256]u8 = undefined;
    const head_payload = try ipc.ingress_channel.encodeResponseHeadInto(
        &head_scratch,
        200,
        &[_]ipc.ingress_channel.ResponseHeader{},
    );
    try ipc.ingress_channel.sendDescriptorPayload(
        worker_fd,
        ipc.ingress_channel.Descriptor.responseHead(identity, 1, 0, 0, 200, 0, false),
        head_payload,
        &send_scratch,
    );
    try ipc.ingress_channel.sendDescriptorPayload(
        worker_fd,
        ipc.ingress_channel.Descriptor.responseChunk(identity, 1, 0, 0, false),
        "hello",
        &send_scratch,
    );
    try ipc.ingress_channel.sendDescriptor(
        worker_fd,
        ipc.ingress_channel.Descriptor.responseEnd(identity, 1),
        &send_scratch,
    );
    // ...followed by a malformed trailing packet: message kind 8, which names
    // no message and decodeMessageKind rejects.
    var bogus: [8]u8 = undefined;
    std.mem.writeInt(u32, bogus[0..4], 8, .little);
    std.mem.writeInt(u32, bogus[4..8], 0, .little);
    try fd_mod.writeAllRaw(worker_fd, &bogus);

    // The completion is published before the read, so the reader takes the
    // ring-first path and then drains the control fd.
    try fixture.view.publishWorkerCompletion(.{
        .external_request_id = request_id,
        .request_lane_id = 0,
        .request_slot = 0,
        .request_generation = 1,
        .worker_id = 1,
        .worker_generation = 1,
        .status = @intFromEnum(ipc.RequestDoneStatus.ok),
        .http_status = 200,
    });

    try std.testing.expectError(error.InvalidMessageKind, rt.readIngressResponseBounded(.{
        .control_fd = server_fd,
        .completion_eventfd = completion_eventfd,
        .metrics = &fixture.view,
    }, request_id, 2_000));
}

test "bounded response reader errors on a broken control channel (POLLERR/POLLNVAL)" {
    // Both poll sites classify ERR and NVAL before their readability
    // branches. Otherwise the ring-first drain masks NVAL as a truncated
    // success, and the waiting poll reports the socket's incidental recv
    // error instead of the reader's own. Only WouldBlock and
    // ControlPeerClosed are benign.
    {
        var fixture = try rt.CompletionFixture.init();
        defer fixture.deinit();
        const completion_eventfd = try rt.createCompletionEventfd();
        defer std.posix.close(completion_eventfd);

        // Ring-first site: a closed fd number makes poll(2) report POLLNVAL.
        const pair = try rt.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
        std.posix.close(pair[0]);
        std.posix.close(pair[1]);
        const dead_fd = pair[0];

        const request_id: u64 = 92;
        try fixture.view.publishWorkerCompletion(.{
            .external_request_id = request_id,
            .request_lane_id = 0,
            .request_slot = 0,
            .request_generation = 1,
            .worker_id = 1,
            .worker_generation = 1,
            .status = @intFromEnum(zygote.ipc.RequestDoneStatus.ok),
            .http_status = 200,
        });

        try std.testing.expectError(error.ControlChannelBroken, rt.readIngressResponseBounded(.{
            .control_fd = dead_fd,
            .completion_eventfd = completion_eventfd,
            .metrics = &fixture.view,
        }, request_id, 2_000));
    }

    {
        var fixture = try rt.CompletionFixture.init();
        defer fixture.deinit();
        const completion_eventfd = try rt.createCompletionEventfd();
        defer std.posix.close(completion_eventfd);

        // Waiting site: connect a nonblocking TCP socket to a just-closed
        // loopback listener. Linux reports POLLERR|POLLHUP; the probe pins
        // POLLERR before handing the same fd to the production reader.
        var listener = try (try std.net.Address.parseIp4("127.0.0.1", 0)).listen(.{
            .reuse_address = true,
        });
        const refused_address = listener.listen_address;
        listener.deinit();
        const pollerr_fd = try std.posix.socket(
            refused_address.any.family,
            std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK,
            std.posix.IPPROTO.TCP,
        );
        defer std.posix.close(pollerr_fd);
        std.posix.connect(
            pollerr_fd,
            &refused_address.any,
            refused_address.getOsSockLen(),
        ) catch |err| switch (err) {
            error.WouldBlock, error.ConnectionPending, error.ConnectionRefused => {},
            else => return err,
        };
        var pollerr_probe = [1]std.posix.pollfd{.{
            .fd = pollerr_fd,
            .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR,
            .revents = 0,
        }};
        try std.testing.expectEqual(@as(usize, 1), try std.posix.poll(&pollerr_probe, 1_000));
        try std.testing.expect((pollerr_probe[0].revents & std.posix.POLL.ERR) != 0);

        try std.testing.expectError(error.ControlChannelBroken, rt.readIngressResponseBounded(.{
            .control_fd = pollerr_fd,
            .completion_eventfd = completion_eventfd,
            .metrics = &fixture.view,
        }, 93, 2_000));
    }
}

test "real cgroup memory events opens and accepts POLLPRI interest" {
    const memory_events = worker_cgroup.openCurrentWorkerMemoryEvents(
        std.testing.allocator,
        @intCast(std.c.getpid()),
    ) catch |err| switch (err) {
        error.FileNotFound,
        error.InvalidWorkerCgroupDir,
        error.PermissionDenied,
        => return error.SkipZigTest,
        else => return err,
    };
    defer {
        std.posix.close(memory_events.fd);
        std.testing.allocator.free(memory_events.cgroup_dir);
    }

    _ = try worker_cgroup.memory.readEvents(memory_events.fd);
    var pollfds = [1]std.posix.pollfd{
        .{
            .fd = memory_events.fd,
            .events = std.posix.POLL.PRI | std.posix.POLL.HUP | std.posix.POLL.ERR,
            .revents = 0,
        },
    };
    _ = try std.posix.poll(&pollfds, 0);
}

test "worker cgroup dir fd validation rejects ordinary directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expectError(
        error.InvalidWorkerCgroupDir,
        worker_cgroup.validateWorkerCgroupDirFd(tmp.dir.fd),
    );
}

test "worker init with non-directory tmp root fd fails and marks init_failed" {
    var spawned = try support.spawnZygote();
    defer spawned.deinit();

    var worker = try zygote.host_client.requestFork(&spawned);
    var worker_armed = true;
    defer if (worker_armed) worker.deinit();

    const worker_pidfd = try std.posix.dup(worker.pidfd.?);
    defer std.posix.close(worker_pidfd);

    const metrics_fd = try zygote.worker_state.page.createMemfd("collo-invalid-metrics");
    defer std.posix.close(metrics_fd);
    const completion_eventfd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
    defer std.posix.close(completion_eventfd);
    const ingress_payload_fd = try zygote.ipc.ingress_channel.createSharedPayloadMemfd();
    defer std.posix.close(ingress_payload_fd);
    const ingress_payload_credit_eventfd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
    defer std.posix.close(ingress_payload_credit_eventfd);
    var metrics = try zygote.worker_state.page.mapReadWrite(metrics_fd);
    defer metrics.deinit();
    metrics.initializeCrashDefault(worker.pid, worker_memory_limit_bytes, try process.monotonicNowNs());

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var not_dir = try tmp.dir.createFile("not-dir", .{});
    defer not_dir.close();

    var message = try zygote.ipc.WorkerInit.init(
        worker_memory_limit_bytes,
        zygote.ipc.WorkerRuntimeBootOptions.default(),
    );
    message.enableEgressGatewaySandbox();
    // Valid deadline so the probe stays on the tmp-root fd axis.
    message.init_deadline_mono_ns = (try process.monotonicNowNs()) + 3 * std.time.ns_per_s;
    var wake = try detachedWake();
    defer wake.close();
    try zygote.ipc.sendWorkerInitWithEgressShared(
        worker.worker_init_fd.?,
        &message,
        metrics_fd,
        completion_eventfd,
        ingress_payload_fd,
        ingress_payload_credit_eventfd,
        not_dir.handle,
        tmp.dir.fd,
        zygote.ipc.egress_shared.RawFds.wakeOnly(wake),
    );

    switch (try zygote.host_client.receiveWorkerInitOutcome(worker.worker_init_fd.?)) {
        .ready => return error.UnexpectedReady,
        .failed => |reason| try std.testing.expectEqual(
            zygote.ipc.WorkerInitFailedReason.invalid_worker_init,
            reason,
        ),
    }

    try std.testing.expectEqual(@intFromEnum(zygote.worker_state.page.State.dead), metrics.header.state);
    try std.testing.expectEqual(
        @intFromEnum(zygote.worker_state.page.TerminationReason.init_failed),
        metrics.header.termination_reason,
    );

    worker_armed = false;
    worker.deinit();
    try support.waitForPidFdExit(worker_pidfd);

    spawned.shutdown();
    try support.expectChildExitStatus(spawned.pid, 0);

    var trace = try support.drainTrace(&spawned, std.testing.allocator);
    defer trace.deinit();
    try std.testing.expect(trace.containsPrefix("child.worker_init.invalid_fds"));
    try std.testing.expect(!trace.containsPrefix("child.cgroup.validated"));
    try std.testing.expect(!trace.containsPrefix("child.memory_events.opened"));
}

test "worker init with ordinary cgroup dir fd fails and marks init_failed" {
    var spawned = try support.spawnZygote();
    defer spawned.deinit();

    var worker = try zygote.host_client.requestFork(&spawned);
    var worker_armed = true;
    defer if (worker_armed) worker.deinit();

    const worker_pidfd = try std.posix.dup(worker.pidfd.?);
    defer std.posix.close(worker_pidfd);

    const metrics_fd = try zygote.worker_state.page.createMemfd("collo-invalid-cgroup-metrics");
    defer std.posix.close(metrics_fd);
    const completion_eventfd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
    defer std.posix.close(completion_eventfd);
    const ingress_payload_fd = try zygote.ipc.ingress_channel.createSharedPayloadMemfd();
    defer std.posix.close(ingress_payload_fd);
    const ingress_payload_credit_eventfd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
    defer std.posix.close(ingress_payload_credit_eventfd);
    var metrics = try zygote.worker_state.page.mapReadWrite(metrics_fd);
    defer metrics.deinit();
    metrics.initializeCrashDefault(worker.pid, worker_memory_limit_bytes, try process.monotonicNowNs());

    const tmp_root_path = try support.makeTempPath(std.testing.allocator, "collo-valid-tmp-root");
    defer std.testing.allocator.free(tmp_root_path);
    defer support.cleanupTmpRoot(tmp_root_path);
    try std.posix.mkdir(tmp_root_path, zygote.worker_boot.sandbox.tmp_root.required_mode);
    var tmp_root = try std.fs.openDirAbsolute(tmp_root_path, .{ .no_follow = true });
    defer tmp_root.close();

    var fake_cgroup = std.testing.tmpDir(.{});
    defer fake_cgroup.cleanup();

    var message = try zygote.ipc.WorkerInit.init(
        worker_memory_limit_bytes,
        zygote.ipc.WorkerRuntimeBootOptions.default(),
    );
    message.enableEgressGatewaySandbox();
    // Valid deadline so the probe stays on the cgroup fd axis.
    message.init_deadline_mono_ns = (try process.monotonicNowNs()) + 3 * std.time.ns_per_s;
    var wake = try detachedWake();
    defer wake.close();
    try zygote.ipc.sendWorkerInitWithEgressShared(
        worker.worker_init_fd.?,
        &message,
        metrics_fd,
        completion_eventfd,
        ingress_payload_fd,
        ingress_payload_credit_eventfd,
        tmp_root.fd,
        fake_cgroup.dir.fd,
        zygote.ipc.egress_shared.RawFds.wakeOnly(wake),
    );

    switch (try zygote.host_client.receiveWorkerInitOutcome(worker.worker_init_fd.?)) {
        .ready => return error.UnexpectedReady,
        .failed => |reason| try std.testing.expectEqual(
            zygote.ipc.WorkerInitFailedReason.invalid_worker_init,
            reason,
        ),
    }

    try std.testing.expectEqual(@intFromEnum(zygote.worker_state.page.State.dead), metrics.header.state);
    try std.testing.expectEqual(
        @intFromEnum(zygote.worker_state.page.TerminationReason.init_failed),
        metrics.header.termination_reason,
    );

    worker_armed = false;
    worker.deinit();
    try support.waitForPidFdExit(worker_pidfd);

    spawned.shutdown();
    try support.expectChildExitStatus(spawned.pid, 0);

    var trace = try support.drainTrace(&spawned, std.testing.allocator);
    defer trace.deinit();
    try std.testing.expect(trace.containsPrefix("child.worker_init.invalid_fds"));
    try std.testing.expect(!trace.containsPrefix("child.cgroup.validated"));
    try std.testing.expect(!trace.containsPrefix("child.memory_events.opened"));
}

test "worker init rejects invalid runtime boot options" {
    var spawned = try support.spawnZygote();
    defer spawned.deinit();

    var worker = try zygote.host_client.requestFork(&spawned);
    var worker_armed = true;
    defer if (worker_armed) worker.deinit();

    const worker_pidfd = try std.posix.dup(worker.pidfd.?);
    defer std.posix.close(worker_pidfd);

    const metrics_fd = try zygote.worker_state.page.createMemfd("collo-current-alias");
    defer std.posix.close(metrics_fd);
    const completion_eventfd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
    defer std.posix.close(completion_eventfd);
    const ingress_payload_fd = try zygote.ipc.ingress_channel.createSharedPayloadMemfd();
    defer std.posix.close(ingress_payload_fd);
    const ingress_payload_credit_eventfd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
    defer std.posix.close(ingress_payload_credit_eventfd);
    var metrics = try zygote.worker_state.page.mapReadWrite(metrics_fd);
    defer metrics.deinit();
    metrics.initializeCrashDefault(worker.pid, worker_memory_limit_bytes, try process.monotonicNowNs());

    var tmp_root = std.testing.tmpDir(.{});
    defer tmp_root.cleanup();

    var options = zygote.ipc.WorkerRuntimeBootOptions.default();
    options.crypto_thread_count = 0;
    var message = try zygote.ipc.WorkerInit.init(worker_memory_limit_bytes, options);
    message.enableEgressGatewaySandbox();
    var wake = try detachedWake();
    defer wake.close();
    try zygote.ipc.sendWorkerInitWithEgressShared(
        worker.worker_init_fd.?,
        &message,
        metrics_fd,
        completion_eventfd,
        ingress_payload_fd,
        ingress_payload_credit_eventfd,
        tmp_root.dir.fd,
        tmp_root.dir.fd,
        zygote.ipc.egress_shared.RawFds.wakeOnly(wake),
    );

    switch (try zygote.host_client.receiveWorkerInitOutcome(worker.worker_init_fd.?)) {
        .ready => return error.UnexpectedReady,
        .failed => |reason| try std.testing.expectEqual(
            zygote.ipc.WorkerInitFailedReason.invalid_worker_init,
            reason,
        ),
    }

    try std.testing.expectEqual(
        @intFromEnum(zygote.worker_state.page.TerminationReason.init_failed),
        metrics.header.termination_reason,
    );

    worker_armed = false;
    worker.deinit();
    try support.waitForPidFdExit(worker_pidfd);

    spawned.shutdown();
    try support.expectChildExitStatus(spawned.pid, 0);
}

test "a child sends one outcome for a WorkerInit short of a descriptor and exits with nothing after it" {
    var spawned = try support.spawnZygote();
    defer spawned.deinit();

    var worker = try zygote.host_client.requestFork(&spawned);
    var worker_armed = true;
    defer if (worker_armed) worker.deinit();

    const worker_pidfd = try std.posix.dup(worker.pidfd.?);
    defer std.posix.close(worker_pidfd);

    // A WorkerInit without its descriptor table, which the child's receive
    // refuses for its first missing descriptor.
    var message = try zygote.ipc.WorkerInit.init(
        worker_memory_limit_bytes,
        zygote.ipc.WorkerRuntimeBootOptions.default(),
    );
    message.enableEgressGatewaySandbox();
    message.init_deadline_mono_ns = (try process.monotonicNowNs()) + 3 * std.time.ns_per_s;
    try zygote.ipc.packet.sendExact(worker.worker_init_fd.?, std.mem.asBytes(&message));

    switch (try zygote.host_client.receiveWorkerInitOutcome(worker.worker_init_fd.?)) {
        .ready => return error.UnexpectedReady,
        .failed => |reason| try std.testing.expectEqual(
            zygote.ipc.WorkerInitFailedReason.missing_metrics_fd,
            reason,
        ),
    }
    // Once the child is gone, its init socket holds no second outcome.
    try support.waitForPidFdExit(worker_pidfd);
    try std.testing.expectError(error.PeerClosed, zygote.ipc.recvInitOutcome(worker.worker_init_fd.?));

    worker_armed = false;
    worker.deinit();

    spawned.shutdown();
    try support.expectChildExitStatus(spawned.pid, 0);

    var trace = try support.drainTrace(&spawned, std.testing.allocator);
    defer trace.deinit();
    try std.testing.expect(trace.containsPrefix("child.worker_init.recv_failed=MissingMetricsFd"));
}

test "post-fork invalid init flushes exit probe before _exit" {
    const exit_probe_path = try support.makeTempPath(std.testing.allocator, "collo-exit-probe");
    defer std.testing.allocator.free(exit_probe_path);
    defer std.fs.deleteFileAbsolute(exit_probe_path) catch {};

    var spawned = try support.spawnZygoteWithExitProbe(exit_probe_path);
    defer spawned.deinit();

    var worker = try zygote.host_client.requestFork(&spawned);
    var worker_armed = true;
    defer if (worker_armed) worker.deinit();

    const worker_pidfd = try std.posix.dup(worker.pidfd.?);
    defer std.posix.close(worker_pidfd);

    const metrics_fd = try zygote.worker_state.page.createMemfd("collo-exit-probe-metrics");
    defer std.posix.close(metrics_fd);
    const completion_eventfd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
    defer std.posix.close(completion_eventfd);
    const ingress_payload_fd = try zygote.ipc.ingress_channel.createSharedPayloadMemfd();
    defer std.posix.close(ingress_payload_fd);
    const ingress_payload_credit_eventfd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
    defer std.posix.close(ingress_payload_credit_eventfd);
    var metrics = try zygote.worker_state.page.mapReadWrite(metrics_fd);
    defer metrics.deinit();
    metrics.initializeCrashDefault(worker.pid, worker_memory_limit_bytes, try process.monotonicNowNs());

    var tmp_root = std.testing.tmpDir(.{});
    defer tmp_root.cleanup();

    // The probe is what this test asserts; the failure only has to happen
    // after the fork. Invalid runtime options through the production sender
    // provoke it without hand-building the WorkerInit fd array, so protocol
    // fd additions cannot silently change which failure this exercises.
    var options = zygote.ipc.WorkerRuntimeBootOptions.default();
    options.crypto_thread_count = 0;
    var message = try zygote.ipc.WorkerInit.init(worker_memory_limit_bytes, options);
    message.enableEgressGatewaySandbox();
    var wake = try detachedWake();
    defer wake.close();
    try zygote.ipc.sendWorkerInitWithEgressShared(
        worker.worker_init_fd.?,
        &message,
        metrics_fd,
        completion_eventfd,
        ingress_payload_fd,
        ingress_payload_credit_eventfd,
        tmp_root.dir.fd,
        tmp_root.dir.fd,
        zygote.ipc.egress_shared.RawFds.wakeOnly(wake),
    );

    switch (try zygote.host_client.receiveWorkerInitOutcome(worker.worker_init_fd.?)) {
        .ready => return error.UnexpectedReady,
        .failed => |reason| try std.testing.expectEqual(zygote.ipc.WorkerInitFailedReason.invalid_worker_init, reason),
    }

    worker_armed = false;
    worker.deinit();
    try support.waitForPidFdExit(worker_pidfd);

    const probe_contents = try support.readFileAlloc(exit_probe_path, std.testing.allocator);
    defer std.testing.allocator.free(probe_contents);
    try std.testing.expectEqualStrings("postfork-exit-probe", probe_contents);

    spawned.shutdown();
    try support.expectChildExitStatus(spawned.pid, 0);
}

test "worker boot eval hung in the sync slice dies typed at the init deadline before the wall kill" {
    try expectBootDiesAtInitDeadline(1, 90_031);
}

test "a boot past its init deadline evaluates no further route, so a worker of the most isolated routes still dies typed in time" {
    try expectBootDiesAtInitDeadline(zygote.ipc.route_table.routes_max, 90_032);
}

/// Route 0's entry: its synchronous top-level slice never lets a microtask
/// drain settle, since each microtask enqueues another, and it starts no
/// timer and no fetch, so only the watchdog can end it.
const init_deadline_spin_source =
    \\export default function handle() { return new Response("unreachable"); }
    \\function spin() { Promise.resolve().then(spin); }
    \\spin();
;
const init_deadline_plain_source = "export default () => new Response(\"plain\");";

/// Boots a worker of `route_count` routes, every one past the first in a
/// realm of its own, whose route 0 spins. The child's watchdog, armed at
/// init_deadline_mono_ns less the cleanup reserve, stops the VM, and the boot
/// evaluates no route after that: a typed init failure
/// (.init_deadline_exceeded) arrives on the init fd and the child exits by
/// itself, so the passing path sends no signal. The failure lands neither
/// before the arm point (deadline less reserve) nor at or after the deadline
/// itself, whatever the routes left behind route 0 would have cost.
fn expectBootDiesAtInitDeadline(route_count: usize, fork_job_id: u64) !void {
    var spawned = try support.spawnZygote();
    defer spawned.deinit();

    // The child is born inside a prepared leaf with the same limits the
    // WorkerInit below announces, so its cgroup validation passes and the
    // boot reaches the eval.
    var root = support.cgroupRoot(std.testing.allocator) catch |err| switch (err) {
        error.WorkerCgroupDelegationUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer root.deinit(std.testing.allocator);
    const cgroup_dir_fd = try root.createWorkerDir(fork_job_id, .{
        .memory_limit_bytes = worker_memory_limit_bytes,
        .cpu_max_cores = limits.worker.cpu_max_cores,
    });
    defer std.posix.close(cgroup_dir_fd);
    // After the worker's exit below; a resident member would block the rmdir.
    defer root.removeWorkerDir(fork_job_id);

    var worker = try zygote.host_client.requestForkWithJobId(&spawned, fork_job_id, cgroup_dir_fd);
    var worker_armed = true;
    defer if (worker_armed) worker.deinit();

    const worker_pidfd = try std.posix.dup(worker.pidfd.?);
    defer std.posix.close(worker_pidfd);
    // A broken watchdog leaves the child spinning JS forever; never leak it
    // past a failing test. Errdefer only: the passing path must observe the
    // voluntary exit, with no signal ever sent.
    errdefer process.pidFdSendSignal(worker_pidfd, std.posix.SIG.KILL) catch {};

    const tmp_root_path = try support.makeTempPath(std.testing.allocator, "collo-init-deadline-tmp");
    defer std.testing.allocator.free(tmp_root_path);
    defer support.cleanupTmpRoot(tmp_root_path);
    try std.posix.mkdir(tmp_root_path, zygote.worker_boot.sandbox.tmp_root.required_mode);
    var tmp_root_dir = try std.fs.openDirAbsolute(tmp_root_path, .{ .no_follow = true });
    defer tmp_root_dir.close();

    const metrics_fd = try zygote.worker_state.page.createMemfd("collo-init-deadline-metrics");
    defer std.posix.close(metrics_fd);
    const completion_eventfd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
    defer std.posix.close(completion_eventfd);
    const ingress_payload_fd = try zygote.ipc.ingress_channel.createSharedPayloadMemfd();
    defer std.posix.close(ingress_payload_fd);
    const ingress_payload_credit_eventfd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
    defer std.posix.close(ingress_payload_credit_eventfd);
    var wake_set = try zygote.ipc.egress_shared.WakeSet.create();
    defer wake_set.deinit();
    var egress_shared = try zygote.ipc.egress_shared.createSessionForWorker(&wake_set);
    defer egress_shared.deinit();
    var metrics = try zygote.worker_state.page.mapReadWrite(metrics_fd);
    defer metrics.deinit();
    metrics.initializeCrashDefault(worker.pid, worker_memory_limit_bytes, try process.monotonicNowNs());

    const fs_index_fd = try zygote.ipc.zygote_worker.createPlaceholderFsIndexMemfd();
    defer std.posix.close(fs_index_fd);
    const fs_fault_pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(fs_fault_pair[0]);
    defer std.posix.close(fs_fault_pair[1]);

    const routes_max = zygote.ipc.route_table.routes_max;
    var specifier_buffers: [routes_max][64]u8 = undefined;
    var modules: [routes_max]zygote.ipc.module_pack.Module = undefined;
    var routes: [routes_max]zygote.ipc.route_table.RouteInput = undefined;
    for (0..route_count) |index| {
        const specifier = try std.fmt.bufPrint(&specifier_buffers[index], "/__collo_route/test/init-deadline-{d}.js", .{index});
        modules[index] = .{
            .specifier = specifier,
            .source = if (index == 0) init_deadline_spin_source else init_deadline_plain_source,
            .dependencies = &.{},
        };
        routes[index] = .{ .entry_specifier = specifier, .bindings = &.{} };
    }
    const pack_fd = try rt.createModulePackGraphFd(modules[0..route_count], 0);
    defer std.posix.close(pack_fd);
    const table = try zygote.ipc.route_table.buildSealed(std.testing.allocator, routes[0..route_count]);
    defer table.close();

    var message = try zygote.ipc.WorkerInit.init(
        worker_memory_limit_bytes,
        zygote.ipc.WorkerRuntimeBootOptions.default(),
    );
    message.route_table_len = table.blob_len;
    message.flags |= zygote.ipc.WorkerInit.flag_serves_routes | zygote.ipc.WorkerInit.flag_isolate_realm;
    message.enableEgressGatewaySandbox();
    // The host's window: now plus WORKER_INIT_TIMEOUT_MS, fixed before the
    // send, the same absolute value both ends enforce. The boot token takes
    // it as its deadline, as `host/launch.zig` mints it.
    const init_deadline_mono_ns = (try process.monotonicNowNs()) +
        @as(u64, @intCast(zygote.host_client.worker_init_timeout_ms)) * std.time.ns_per_ms;
    message.init_deadline_mono_ns = init_deadline_mono_ns;
    message.boot_egress_token = rt.bootEgressToken(init_deadline_mono_ns);
    try zygote.ipc.sendWorkerInitWithRouteTableAndEgressShared(
        worker.worker_init_fd.?,
        &message,
        metrics_fd,
        completion_eventfd,
        ingress_payload_fd,
        ingress_payload_credit_eventfd,
        tmp_root_dir.fd,
        cgroup_dir_fd,
        table.fd,
        egress_shared.rawForWorker(),
        fs_index_fd,
        fs_fault_pair[1],
        pack_fd,
    );

    // Wait past the deadline: a working watchdog answers typed before it; a
    // broken one turns into WorkerInitTimeout here and fails the test, and
    // the errdefer kills the spinning child.
    const outcome = try zygote.host_client.receiveWorkerInitOutcomeBeforeTimeout(
        worker.worker_init_fd.?,
        worker_pidfd,
        null,
        zygote.host_client.worker_init_timeout_ms + 2_000,
    );
    const outcome_at_ns = try process.monotonicNowNs();
    switch (outcome) {
        .ready => return error.UnexpectedReady,
        .failed => |reason| try std.testing.expectEqual(
            zygote.ipc.WorkerInitFailedReason.init_deadline_exceeded,
            reason,
        ),
    }
    // The watchdog arms at the deadline less the reserve, so the typed
    // failure lands inside the reserve: at or after the arm point and
    // strictly before the deadline at which the host would SIGKILL.
    try std.testing.expect(outcome_at_ns < init_deadline_mono_ns);
    try std.testing.expect(
        outcome_at_ns >= init_deadline_mono_ns - zygote.host_client.worker_init_cleanup_reserve_ns,
    );

    // The child exits by itself inside the reserve; this path sent no
    // signal.
    worker_armed = false;
    worker.deinit();
    try support.waitForPidFdExit(worker_pidfd);

    try std.testing.expectEqual(@intFromEnum(zygote.worker_state.page.State.dead), metrics.header.state);
    try std.testing.expectEqual(
        @intFromEnum(zygote.worker_state.page.TerminationReason.init_failed),
        metrics.header.termination_reason,
    );

    spawned.shutdown();
    try support.expectChildExitStatus(spawned.pid, 0);

    var trace = try support.drainTrace(&spawned, std.testing.allocator);
    defer trace.deinit();
    // The child died in the evaluation: every native phase completed, and
    // the evaluation never did.
    try std.testing.expect(trace.containsPrefix("child.boot_context.installed"));
    try std.testing.expect(!trace.containsPrefix("child.routes.evaluated"));
    try std.testing.expect(!trace.containsPrefix("child.worker_ready"));
}

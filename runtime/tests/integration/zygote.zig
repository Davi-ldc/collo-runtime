//! The zygote and its workers against the real kernel (lane
//! `zygote-integration`, inside the delegated cgroup subtree): zygote boot,
//! warmup and fork, the zygote's environment, a fork request without a leaf,
//! cgroup placement with every limit on the live leaf and the child's check
//! of it, the WorkerInit handoff and its failures with the page left as the
//! host wrote it, the sandboxed worker's boot order and its trace pipe closed
//! before tenant code, its threads asleep when idle, the garbage it gives
//! back once it goes quiet and the zygote pages it keeps shared when its
//! requests leave little behind, the footprint its engine
//! reads from its leaf and its mapped shared objects, a worker with no egress
//! descriptor, workers whose `/tmp` the host never sees, a root read-only but
//! for `/tmp` as `node:fs` sees it, the runtime's log lines and the tenant's
//! exception in a worker's console ring, module evaluation at init with its
//! deadline, a worker that loses its egress gateway and is attached to a new
//! one, wasm after seccomp, and the host's bounded response reader.
//!
//! The test thread plays the host against a zygote spawned from the installed
//! `collo` binary. Most tests launch through `host.launch` and read
//! responses through `host.dispatch`; the WorkerInit failure tests hand a
//! child a hand-built WorkerInit through `zygote.ipc` instead. Every launch
//! carries a definition of one route or more (`ipc.module_pack`). A test that
//! cannot place a worker skips. The launch's transitions without a child are
//! in `host/tests/launch.zig`, the sandbox's own probes in
//! `zygote/tests/sandbox.zig`, and the whole server flow is the `local-e2e`
//! lane.

const std = @import("std");
const os = @import("collo_os");
const limits = @import("collo_limits");
const support = @import("zygote_support");

const fd_mod = os.fd;
const process = os.process;
const zygote = support.zygote;
const ipc = zygote.ipc;
const host = support.host;
const worker_cgroup = zygote.worker_boot.cgroup;
const worker_page = zygote.worker_state.page;
const rt = @import("collo_test_harness");
const worker_memory_limit_bytes: u64 = 1024 * 1024 * 1024;

/// One worker definition of one route, sealed as the artifact a launch
/// carries (`host.dispatch.createModulePackFd`); `deinit` closes it.
const TestRoute = struct {
    pack_fd: std.posix.fd_t,

    /// The route's entry is `source`, keyed `<task_root>/<name>.js`.
    fn init(name: []const u8, source: []const u8) !TestRoute {
        const specifier = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}.js", .{
            ipc.module_pack.task_root,
            name,
        });
        defer std.testing.allocator.free(specifier);
        return .{ .pack_fd = try host.dispatch.createModulePackFd(std.testing.allocator, specifier, source) };
    }

    fn deinit(self: *TestRoute) void {
        std.posix.close(self.pack_fd);
        self.* = undefined;
    }

    fn launchRoutes(self: *const TestRoute) host.launch.LaunchRoutes {
        return .{ .module_pack_fd = self.pack_fd, .isolate_realm = true };
    }
};

/// The entry of a route whose behavior a test does not look at.
const plain_route_source = "export default () => new Response(\"plain\");";

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

/// `support.forkBareChild` with the test's memory limit, skipping where
/// workers cannot be placed.
fn forkBareOrSkip(spawned: *zygote.host_client.SpawnedZygote, fork_job_id: u64) !support.BareChild {
    return support.forkBareChild(std.testing.allocator, spawned, worker_memory_limit_bytes, fork_job_id) catch |err| switch (err) {
        error.WorkerCgroupDelegationUnavailable => return error.SkipZigTest,
        else => return err,
    };
}

/// Which descriptors `countDescriptors` counts.
const DescriptorMatch = union(enum) {
    /// Every pipe.
    any_pipe,
    /// The one open file whose `/proc/<pid>/fd` link this is, such as
    /// `pipeLink` gives.
    link: []const u8,
};

/// How many of process `pid`'s descriptors from `first_fd` up match
/// `match`, read from `/proc/<pid>/fd`.
fn countDescriptors(pid: u32, first_fd: std.posix.fd_t, match: DescriptorMatch) !usize {
    var path_buffer: [32]u8 = undefined;
    const fd_dir_path = try std.fmt.bufPrint(&path_buffer, "/proc/{d}/fd", .{pid});
    var dir = try std.fs.openDirAbsolute(fd_dir_path, .{ .iterate = true });
    defer dir.close();
    var count: usize = 0;
    var entries = dir.iterate();
    while (try entries.next()) |entry| {
        if (try std.fmt.parseInt(std.posix.fd_t, entry.name, 10) < first_fd)
            continue;
        var target_buffer: [64]u8 = undefined;
        const target = dir.readLink(entry.name, &target_buffer) catch |err| switch (err) {
            // Closed between the listing and the read.
            error.FileNotFound => continue,
            else => return err,
        };
        const matched = switch (match) {
            .any_pipe => std.mem.startsWith(u8, target, "pipe:"),
            .link => |link| std.mem.eql(u8, target, link),
        };
        if (matched)
            count += 1;
    }
    return count;
}

/// The link of process `pid`'s descriptor `fd` in `/proc/<pid>/fd`, written
/// into `buffer`; null when the process has no such descriptor.
fn descriptorLink(pid: u32, fd: std.posix.fd_t, buffer: []u8) !?[]const u8 {
    var path_buffer: [48]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/proc/{d}/fd/{d}", .{ pid, fd });
    return std.posix.readlink(path, buffer) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
}

/// The `/proc/<pid>/fd` link of the pipe one of whose ends is this
/// process's `fd`, `pipe:[<inode>]`, written into `buffer`. Every descriptor
/// of either end, in any process, has the same link.
fn pipeLink(fd: std.posix.fd_t, buffer: []u8) ![]const u8 {
    const stat = try std.posix.fstat(fd);
    return std.fmt.bufPrint(buffer, "pipe:[{d}]", .{stat.ino});
}

/// Spawns a zygote, with the trace pipe when `trace` is set, whose standard
/// input is a pipe, as a piped `zig build` hands it one, and gives the test
/// process its own standard input back before returning. A zygote keeps its
/// spawner's standard descriptors (`common/os.zig:spawnInternal`), so a test
/// of the zygote's pipes has to tell its trace pipe from them.
fn spawnWithPipedStandardInput(trace: bool) !zygote.host_client.SpawnedZygote {
    const linux = std.os.linux;
    const pipe = try std.posix.pipe2(.{ .CLOEXEC = true });
    defer std.posix.close(pipe[0]);
    defer std.posix.close(pipe[1]);
    // F_DUPFD_CLOEXEC, the same number on every Linux target.
    const f_dupfd_cloexec: i32 = 1030;
    const saved_rc = linux.fcntl(0, f_dupfd_cloexec, 3);
    const saved_stdin: ?std.posix.fd_t = switch (linux.E.init(saved_rc)) {
        .SUCCESS => @intCast(saved_rc),
        // The test process runs with its standard input closed.
        .BADF => null,
        else => |errno| return std.posix.unexpectedErrno(errno),
    };
    // The test process reads nothing from its standard input while the
    // pipe stands in for it.
    std.posix.dup2(pipe[0], 0) catch |err| {
        if (saved_stdin) |fd|
            std.posix.close(fd);
        return err;
    };
    defer {
        if (saved_stdin) |fd| {
            // `std.posix.dup2` retries the kernel's transient errors, and a
            // target that is open leaves it no other.
            std.posix.dup2(fd, 0) catch |err|
                std.debug.panic("the test's standard input cannot be restored: {s}", .{@errorName(err)});
            std.posix.close(fd);
        } else {
            std.posix.close(0);
        }
    }
    return if (trace) support.spawnZygote() else support.spawnZygoteWithoutTrace();
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

test "the zygote warms up and prepares once at boot, and stays prepared across fork requests" {
    // The warmup always runs, in this zygote as in the server's, and before
    // prepareForFork, so its helper threads retire within the short idle
    // timeout. A corpus exception would fail the boot and every launch.
    var spawned = try support.spawnZygote();
    defer spawned.deinit();

    var first = try forkBareOrSkip(&spawned, 90_001);
    first.deinit();
    var second = try forkBareOrSkip(&spawned, 90_002);
    second.deinit();

    spawned.shutdown();
    try support.expectChildExitStatus(spawned.pid, 0);

    var trace = try support.drainTrace(&spawned, std.testing.allocator);
    defer trace.deinit();
    try std.testing.expectEqual(@as(usize, 1), trace.countEq("zygote.warmup_corpus.run"));
    try std.testing.expectEqual(@as(usize, 1), trace.countEq("zygote.warmup_corpus.done"));
    try std.testing.expectEqual(@as(usize, 1), trace.countEq("zygote.prepare_for_fork"));
    try std.testing.expectEqual(@as(usize, 1), trace.countEq("zygote.prepared"));
    try std.testing.expectEqual(@as(usize, 2), trace.countEq("zygote.fork_request"));
    try support.expectTraceBefore(trace, "zygote.warmup_corpus.done", "zygote.prepared");
}

test "the zygote's environment is exactly its launch contract's, and its workers inherit it" {
    var spawned = try support.spawnZygote();
    defer spawned.deinit();
    try expectLaunchEnvironment(spawned.pid);

    var route = try TestRoute.init("environment", plain_route_source);
    defer route.deinit();
    var launched = try launchOrSkip(&spawned, 90_003, .{ .routes = route.launchRoutes() });
    defer launched.deinit();
    try expectLaunchEnvironment(launched.handle.pid);
}

/// Fails unless process `pid`'s environment is `zygote.fork_loop.environment`
/// entry for entry.
fn expectLaunchEnvironment(pid: u32) !void {
    var path_buffer: [32]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/proc/{d}/environ", .{pid});
    const environ = try support.readFileAlloc(path, std.testing.allocator);
    defer std.testing.allocator.free(environ);
    var entries = std.mem.splitScalar(u8, std.mem.trimEnd(u8, environ, "\x00"), 0);
    for (zygote.fork_loop.environment) |expected| {
        const entry = entries.next() orelse return error.EnvironmentEntryMissing;
        try std.testing.expectEqualStrings(std.mem.span(expected.?), entry);
    }
    if (entries.next()) |extra| {
        std.debug.print("process {d} holds an environment entry beyond the contract: {s}\n", .{ pid, extra });
        return error.UnexpectedEnvironmentEntry;
    }
}

test "a fork request without a leaf ends the zygote before any fork" {
    // Every child is born inside a leaf, so the receive refuses a request
    // without exactly one, and the zygote ends rather than fork into its own
    // cgroup.
    var spawned = try support.spawnZygote();
    defer spawned.deinit();

    const request = ipc.ForkRequest.init(90_004);
    try ipc.packet.sendExact(spawned.control_fd.?, std.mem.asBytes(&request));
    try std.testing.expectError(error.ZygoteDied, zygote.host_client.receiveForkReply(&spawned, 90_004));
    try support.waitForPidFdExit(spawned.pidfd);
    try support.expectChildExitStatus(spawned.pid, 1);

    var trace = try support.drainTrace(&spawned, std.testing.allocator);
    defer trace.deinit();
    try std.testing.expectEqual(@as(usize, 0), trace.countEq("zygote.fork_request"));
    try std.testing.expect(!trace.containsPrefix("zygote.fork_reply="));
}

test "a worker born into its prepared leaf is its only member, finds every limit the launch set, serves, and its teardown removes the leaf" {
    var spawned = try support.spawnZygote();
    defer spawned.deinit();

    var route = try TestRoute.init("leaf-hello",
        \\export default function handle(request) {
        \\  return new Response("Hello, world! " + request.method);
        \\}
    );
    defer route.deinit();
    var wake_set = try ipc.egress_shared.WakeSet.create();
    defer wake_set.deinit();
    var egress_shared = try ipc.egress_shared.createSessionForWorker(&wake_set);
    defer egress_shared.deinit();
    var launched = try launchOrSkip(&spawned, 90_005, .{
        .egress = .{ .attached = .{
            .shared_fds = egress_shared.rawForWorker(),
            .boot = rt.localBootEgress(),
        } },
        .routes = route.launchRoutes(),
    });
    defer launched.deinit();
    const handle = &launched.handle;
    const leaf = handle.leaf;

    // Born inside the leaf and never joined by anything else.
    var procs_buffer: [64]u8 = undefined;
    const procs = try leaf.readFile("cgroup.procs", &procs_buffer);
    var pid_buffer: [10]u8 = undefined;
    try std.testing.expectEqualStrings(
        try std.fmt.bufPrint(&pid_buffer, "{d}", .{handle.pid}),
        std.mem.trim(u8, procs, &std.ascii.whitespace),
    );
    // Every limit the launch wrote, `memory.swap.max` 0 included where the
    // kernel accounts swap, the same ones the child checked before its VM
    // resumed.
    try std.testing.expectEqual(worker_memory_limit_bytes, try support.readLeafUnsigned(leaf, "memory.high"));
    try std.testing.expectEqual(
        worker_cgroup.memory.maxBytes(worker_memory_limit_bytes),
        try support.readLeafUnsigned(leaf, "memory.max"),
    );
    {
        var name_buffer: [host.WorkerLeaf.name_bytes_max]u8 = undefined;
        const leaf_fd = try std.posix.openat(leaf.workers_dir_fd, leaf.name(&name_buffer), .{
            .ACCMODE = .RDONLY,
            .DIRECTORY = true,
            .CLOEXEC = true,
        }, 0);
        defer std.posix.close(leaf_fd);
        try worker_cgroup.worker.validateLimitsAt(leaf_fd, .{ .memory_limit_bytes = worker_memory_limit_bytes });
    }

    const request = rt.RequestParts{ .method = "GET", .path = "/hello" };
    var dispatch = try rt.initDispatchWork(std.testing.allocator, .{
        .request_id = 90_005,
        .deadline_monotonic_ns = try forkedDeadlineNs(),
        .request = request,
    });
    defer dispatch.deinit();
    try rt.sendIngressRoute(handle.control_fd, &dispatch, 1, request);
    var response = try readForkedIngressResponse(handle, 90_005, 8_000);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqual(ipc.RequestDoneStatus.ok, response.done.status);
    try std.testing.expectEqualStrings("Hello, world! GET", response.body);

    var worker_pidfd = try fd_mod.OwnedFd.dupCloexec(handle.pidfd);
    defer worker_pidfd.deinit();
    launched.stopWorker();
    try support.waitForPidFdExit(worker_pidfd.fd());
    try std.testing.expectError(error.FileNotFound, leaf.openFile("cgroup.procs"));
}

test "a leaf whose limits differ from WorkerInit's fails the child's one check, and the launch leaves no leaf behind" {
    // The host never reads a leaf back: the child's pass over its leaf is
    // what refuses limits nobody meant to set.
    var spawned = try support.spawnZygote();
    defer spawned.deinit();
    var root = support.cgroupRoot(std.testing.allocator) catch |err| switch (err) {
        error.WorkerCgroupDelegationUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer root.deinit(std.testing.allocator);
    var route = try TestRoute.init("leaf-mismatch", plain_route_source);
    defer route.deinit();
    var wake_set = try ipc.egress_shared.WakeSet.create();
    defer wake_set.deinit();

    const fork_job_id: u64 = 90_006;
    const leaf_fd = try root.createWorkerDir(fork_job_id, .{ .memory_limit_bytes = 2 * worker_memory_limit_bytes });
    var machine = host.launch.Machine.init(root.leaf(fork_job_id), leaf_fd, spawned.trace_write_fd);
    var forked = support.requestFork(&spawned, fork_job_id, leaf_fd) catch |err| {
        var abandoned = machine.abandon();
        abandoned.reap();
        return err;
    };
    defer forked.deinit();
    const options: host.LaunchOptions = .{
        .memory_limit_bytes = worker_memory_limit_bytes,
        .egress = .{ .detached = &wake_set },
        .routes = route.launchRoutes(),
    };
    if (host.runToReady(&machine, &forked, &options)) |handle_value| {
        var handle = handle_value;
        handle.deinit();
        return error.UnexpectedWorkerReady;
    } else |err| {
        if (err != error.WorkerInitFailed)
            return err;
    }
    const failure = machine.init_failure orelse return error.MissingInitFailure;
    switch (failure) {
        .reported => |reason| try std.testing.expectEqual(ipc.WorkerInitFailedReason.invalid_worker_init, reason),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectError(error.FileNotFound, root.leaf(fork_job_id).openFile("cgroup.procs"));

    var trace = try support.drainTrace(&spawned, std.testing.allocator);
    defer trace.deinit();
    try std.testing.expect(trace.containsPrefix("child.boot_failed="));
    try std.testing.expect(!trace.containsPrefix("child.cgroup.validated"));
}

test "a worker refuses a request begin that carries a file descriptor, stops, and logs why in its console ring" {
    // The definition reached the worker in WorkerInit, so no ingress packet
    // may carry a descriptor. A request begin with one attached fails to
    // decode in the worker's control loop, which ends the worker before any
    // handler runs.
    var spawned = try support.spawnZygote();
    defer spawned.deinit();

    var route = try TestRoute.init("descriptor-refused",
        \\export default function handle() {
        \\  return new Response("served");
        \\}
    );
    defer route.deinit();
    var launched = try launchOrSkip(&spawned, 90_007, .{ .routes = route.launchRoutes() });
    defer launched.deinit();
    const handle = &launched.handle;

    var dispatch = try rt.initDispatchWork(std.testing.allocator, .{
        .request_id = 90_007,
        .deadline_monotonic_ns = try forkedDeadlineNs(),
    });
    defer dispatch.deinit();
    const payload_scratch = try std.testing.allocator.alloc(u8, ipc.max_message_bytes);
    defer std.testing.allocator.free(payload_scratch);
    var view = dispatch.view();
    const payload = try ipc.encodeDispatchWorkInto(payload_scratch, &view);
    const packet_scratch = try std.testing.allocator.alloc(u8, ipc.max_message_bytes);
    defer std.testing.allocator.free(packet_scratch);
    const begin = ipc.ingress_channel.Descriptor.requestBegin(
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
    const encoded = try ipc.ingress_channel.encodeDescriptorPayloadInto(packet_scratch, begin, payload);
    try ipc.packet.sendWithFds(handle.control_fd, encoded, &.{route.pack_fd});

    try support.waitForPidFdExit(handle.pidfd);
    // The init socket became the control socket at WorkerReady, so the
    // failed loop leaves nothing on it, a WorkerInitFailed least of all.
    try std.testing.expectError(error.PeerClosed, ipc.recvInitOutcome(handle.control_fd));
    // The worker's stderr is /dev/null, so its last word reaches the host
    // only through its page's console ring, as the runtime's line.
    const lines = try drainConsoleLines(std.testing.allocator, &handle.metrics.?);
    defer freeConsoleLines(std.testing.allocator, lines);
    var found = false;
    for (lines) |line| {
        if (line.header.flags & worker_page.LogLineFlags.runtime == 0)
            continue;
        if (std.mem.indexOf(u8, line.text, "worker event loop failed: ") != null)
            found = true;
    }
    if (!found) {
        std.debug.print("no runtime line in the console ring names the refused packet ({d} lines)\n", .{lines.len});
        return error.TestUnexpectedResult;
    }
}

test "worker self-timeout without WorkerInit" {
    var spawned = try support.spawnZygote();
    defer spawned.deinit();

    var child = try forkBareOrSkip(&spawned, 90_008);
    defer child.deinit();

    // The child stops waiting for WorkerInit after `WORKER_INIT_TIMEOUT_MS`,
    // and this wait outlasts it.
    try std.testing.expect(try process.waitForPidFdExit(child.pidfd(), limits.process.WORKER_INIT_TIMEOUT_MS + 500));

    var trace = try support.drainTrace(&spawned, std.testing.allocator);
    defer trace.deinit();
    try std.testing.expect(trace.containsPrefix("child.worker_init.timeout"));
    // A child whose WorkerInit never came owes no outcome.
    try std.testing.expectError(error.PeerClosed, ipc.recvInitOutcome(child.initFd()));
}

test "a worker crosses the sandbox in order, closes its trace pipe before tenant code and stamps the rest on its page" {
    var spawned = try support.spawnZygote();
    defer spawned.deinit();

    var route = try TestRoute.init("boot-order", plain_route_source);
    defer route.deinit();
    // An initialized worker has no self-timeout, so a failed assertion must
    // still tear it down; the worker itself is stopped mid-test so the trace
    // holds everything it wrote.
    var launched = try launchOrSkip(&spawned, 90_009, .{ .routes = route.launchRoutes() });
    defer launched.deinit();
    const handle = &launched.handle;

    // The host's map checked the page's version.
    const page = &handle.metrics.?;
    const lifecycle = page.loadLifecycle();
    try std.testing.expectEqual(@as(?worker_page.State, .ready), lifecycle.knownState());
    try std.testing.expectEqual(@as(?worker_page.TerminationReason, .none), lifecycle.knownTerminationReason());
    // No request was dispatched, so no live slot names one.
    for (0..worker_page.LIVE_SLOT_COUNT) |index|
        try std.testing.expectEqual(@as(u64, 0), page.loadLiveSlot(index).request_id);
    // The phases after the trace closed reach the host through the page,
    // read here as soon as `WorkerReady` arrived, as the launcher reads it,
    // so the last stamp is already there.
    try std.testing.expect(page.loadBootPhaseStampNs(.seccomp_applied) != 0);
    try std.testing.expect(page.loadBootPhaseStampNs(.routes_evaluated) >= page.loadBootPhaseStampNs(.seccomp_applied));
    try std.testing.expect(page.loadBootPhaseStampNs(.ready) >= page.loadBootPhaseStampNs(.routes_evaluated));

    var events_buffer: [256]u8 = undefined;
    const memory_events = try handle.leaf.readFile("memory.events.local", &events_buffer);
    try std.testing.expect(std.mem.containsAtLeast(u8, memory_events, 1, "high 0"));

    launched.stopWorker();
    spawned.shutdown();
    try support.expectChildExitStatus(spawned.pid, 0);

    var trace = try support.drainTrace(&spawned, std.testing.allocator);
    defer trace.deinit();

    // The boot order the sandbox depends on: the page and its log sink come
    // before the descriptor close, the leaf's check before the VM resumes,
    // and the child proves it is single-threaded, sets no-new-privileges and
    // drops its capabilities inside the sandbox before it resumes JSC and
    // libpas, so every helper thread it starts later inherits
    // no-new-privileges and empty capability sets. The trace pipe closes
    // after the filter and before the first tenant code.
    const order = [_][]const u8{
        "child.wait_worker_init",
        "child.log_sink.installed",
        "child.worker_init.validated",
        "child.cgroup.validated",
        "child.single_threaded.asserted",
        "child.sandbox.applied",
        "child.post_fork_child",
        "child.reseed",
        "child.process_env.installed",
        "child.sentinel.started",
        "child.compiler_threads.prespawned",
        "child.control.nonblocking",
        "child.seccomp.applied",
        "child.node_fs.enabled",
        "child.trace.closed",
    };
    for (order[0 .. order.len - 1], order[1..]) |first, second|
        try support.expectTraceBefore(trace, first, second);
    try std.testing.expect(trace.containsPrefix("host.metrics.created"));

    // Nothing of the child follows the close.
    const closed_index = trace.indexOf("child.trace.closed") orelse return error.MissingTraceEvent;
    for (trace.messages[closed_index + 1 ..]) |message| {
        if (std.mem.startsWith(u8, message, "child.") or std.mem.startsWith(u8, message, "worker.")) {
            std.debug.print("the child traced after closing its pipe: {s}\n", .{message});
            return error.TestUnexpectedResult;
        }
    }

    const gc_prefix = "child.gc_override=";
    const gc_event = trace.messages[trace.indexOfPrefix(gc_prefix) orelse return error.MissingTraceEvent];
    const gc_value = try std.fmt.parseUnsigned(u64, gc_event[gc_prefix.len..], 10);
    try std.testing.expectEqual(worker_cgroup.memory.gcHeapLimitBytes(worker_memory_limit_bytes), gc_value);
}

test "a worker holds no pipe once its boot ends, its zygote's trace pipe least of all, and a zygote spawned without a trace holds no pipe of its own" {
    // `.none` gives the worker no egress descriptor, whose liveness pipe
    // would be its only other pipe. The zygote's own descriptors start at 3:
    // below are its spawner's standard descriptors, which each zygote here
    // gets with a pipe among them.
    const trace_fd = zygote.fork_loop.inherited_trace_fd;
    var route = try TestRoute.init("no-pipe", plain_route_source);
    defer route.deinit();
    {
        var spawned = try spawnWithPipedStandardInput(true);
        defer spawned.deinit();
        var stdin_buffer: [64]u8 = undefined;
        const zygote_stdin = (try descriptorLink(spawned.pid, 0, &stdin_buffer)) orelse return error.MissingStandardInput;
        try std.testing.expect(std.mem.startsWith(u8, zygote_stdin, "pipe:"));

        // The trace pipe's write end sits where the launch contract puts it,
        // and the zygote holds no other pipe of its own.
        var trace_pipe_buffer: [64]u8 = undefined;
        const trace_pipe = try pipeLink(spawned.trace_read_fd.?, &trace_pipe_buffer);
        var link_buffer: [64]u8 = undefined;
        const zygote_trace = (try descriptorLink(spawned.pid, trace_fd, &link_buffer)) orelse return error.MissingTraceDescriptor;
        try std.testing.expectEqualStrings(trace_pipe, zygote_trace);
        try std.testing.expectEqual(@as(usize, 1), try countDescriptors(spawned.pid, 3, .any_pipe));

        // The worker closed its copy of the trace pipe, and its standard
        // descriptors are /dev/null, so it holds no pipe at all.
        var launched = try launchOrSkip(&spawned, 90_010, .{ .egress = .none, .routes = route.launchRoutes() });
        defer launched.deinit();
        try std.testing.expectEqual(@as(usize, 0), try countDescriptors(launched.handle.pid, 0, .{ .link = trace_pipe }));
        try std.testing.expectEqual(@as(usize, 0), try countDescriptors(launched.handle.pid, 0, .any_pipe));
    }
    {
        var spawned = try spawnWithPipedStandardInput(false);
        defer spawned.deinit();
        try std.testing.expect(spawned.trace_read_fd == null);
        // Without the trace, `trace_fd` is the lowest free number once the
        // zygote has found it closed, so the first file the zygote keeps
        // open takes it, such as the engine's `/proc/self/statm`, which it
        // reads for its own footprint. None of them is a pipe.
        try std.testing.expectEqual(@as(usize, 0), try countDescriptors(spawned.pid, 3, .any_pipe));

        var launched = try launchOrSkip(&spawned, 90_011, .{ .egress = .none, .routes = route.launchRoutes() });
        defer launched.deinit();
        try std.testing.expectEqual(@as(usize, 0), try countDescriptors(launched.handle.pid, 0, .any_pipe));
    }
}

/// How long a worker gets after its last turn before its threads must all
/// sleep: its idle collection `limits.worker.idle_collection_delay_ns` after
/// the last turn (500 ms), which keeps the collector thread working while it
/// runs; that thread's allocator cache release
/// `limits.worker.thread_cache_idle_release_ns` after its last work (500
/// ms); then the scavenger, which that release wakes, returning the pages it
/// was handed once they are older than its epoch delay (300 ms off macOS)
/// and sleeping again after two empty passes 100 ms apart; with a second
/// for the collection itself on a loaded machine.
const idle_worker_settle_ns: u64 = 2500 * std.time.ns_per_ms;
/// A bound, counted from ready, on the wake the sentinel of a worker that
/// evaluated routes at boot may still have planned: the init window
/// `limits.process.WORKER_INIT_TIMEOUT_MS`, which began when WorkerInit was
/// sent, before ready. The boot evaluation's window publishes the init
/// deadline less `WORKER_INIT_CLEANUP_RESERVE_NS`, and the sentinel plans a
/// wake for it. Closing the window publishes no owner, which never wakes the
/// sentinel to drop the plan (`Sentinel.publish` wakes it only for an
/// earlier expiry), so it wakes at that deadline, finds no owner and blocks
/// again.
const idle_worker_boot_wake_ns: u64 = @as(u64, @intCast(limits.process.WORKER_INIT_TIMEOUT_MS)) * std.time.ns_per_ms;
/// The window over which no thread of an idle worker may run. A later
/// window can leave the sentinel a plan too, at its owner's deadline: a
/// request's (`forkedDeadlineNs`; the launch sets no CPU budget) or the
/// worker owner's (`WorkerInit.default_unowned_time_limit_ns` past the
/// window's start). Both lie far past the end of this window, so only the
/// boot evaluation's needs a wait.
const idle_worker_window_ns: u64 = 2 * std.time.ns_per_s;
/// CPU an idle worker may spend over the window, in microseconds: the
/// measurement's own noise, since none of its threads runs.
const idle_worker_cpu_noise_usec: u64 = 2_000;

comptime {
    std.debug.assert(limits.worker.idle_collection_delay_ns + limits.worker.thread_cache_idle_release_ns < idle_worker_settle_ns);
}

/// The context switches of every thread of process `pid` so far, voluntary
/// and not: a thread that sleeps without waking adds none.
fn readContextSwitches(pid: u32) !u64 {
    var path_buffer: [64]u8 = undefined;
    const task_path = try std.fmt.bufPrint(&path_buffer, "/proc/{d}/task", .{pid});
    var task_dir = try std.fs.openDirAbsolute(task_path, .{ .iterate = true });
    defer task_dir.close();
    var total: u64 = 0;
    var tasks = task_dir.iterate();
    while (try tasks.next()) |task| {
        var status_path_buffer: [96]u8 = undefined;
        const status_path = try std.fmt.bufPrint(&status_path_buffer, "{s}/{s}/status", .{ task_path, task.name });
        // A thread that ended between the listing and the read has no status
        // left and no more switches to add.
        const status = support.readFileAlloc(status_path, std.testing.allocator) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer std.testing.allocator.free(status);
        var lines = std.mem.splitScalar(u8, status, '\n');
        while (lines.next()) |line| {
            inline for (.{ "voluntary_ctxt_switches:", "nonvoluntary_ctxt_switches:" }) |prefix| {
                if (std.mem.startsWith(u8, line, prefix))
                    total += try std.fmt.parseUnsigned(u64, std.mem.trim(u8, line[prefix.len..], &std.ascii.whitespace), 10);
            }
        }
    }
    return total;
}

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

/// The CPU every process of `leaf` has spent, in microseconds, from its
/// `cpu.stat`.
fn readLeafCpuUsageUsec(leaf: host.WorkerLeaf) !u64 {
    var buffer: [1024]u8 = undefined;
    const stat = try leaf.readFile("cpu.stat", &buffer);
    var lines = std.mem.splitScalar(u8, stat, '\n');
    while (lines.next()) |line| {
        const prefix = "usage_usec ";
        if (std.mem.startsWith(u8, line, prefix))
            return std.fmt.parseUnsigned(u64, std.mem.trim(u8, line[prefix.len..], &std.ascii.whitespace), 10);
    }
    return error.MissingCpuUsage;
}

test "an idle worker's threads all sleep and none retires" {
    var spawned = try support.spawnZygote();
    defer spawned.deinit();

    // The handler gets a function hot enough for an optimizing compile,
    // allocates, and awaits a digest, so the VM thread and a compiler thread
    // both hold allocator caches.
    var route = try TestRoute.init("idle-busy",
        \\function mix(seed) {
        \\  let value = seed | 0;
        \\  for (let i = 0; i < 64; i++) value = (value * 31 + i) | 0;
        \\  return value;
        \\}
        \\
        \\export default async function handle() {
        \\  let total = 0;
        \\  for (let i = 0; i < 200000; i++) total = (total + mix(i)) | 0;
        \\  const blocks = [];
        \\  for (let i = 0; i < 256; i++) blocks.push(new Uint8Array(4096).fill(i));
        \\  const digest = await crypto.subtle.digest("SHA-256", blocks[255]);
        \\  return new Response(`${total}:${digest.byteLength}:${blocks.length}`);
        \\}
    );
    defer route.deinit();
    var launched = try launchOrSkip(&spawned, 90_012, .{ .routes = route.launchRoutes() });
    defer launched.deinit();
    const ready_ns = try process.monotonicNowNs();
    const handle = &launched.handle;

    for (0..3) |index| {
        const request_id: u64 = 90_012 + index;
        var dispatch = try rt.initDispatchWork(std.testing.allocator, .{
            .request_id = request_id,
            .deadline_monotonic_ns = try forkedDeadlineNs(),
        });
        defer dispatch.deinit();
        try rt.sendIngressRoute(handle.control_fd, &dispatch, @intCast(2 * index + 1), .{});
        var response = try readForkedIngressResponse(handle, request_id, 8_000);
        defer response.deinit();
        try std.testing.expectEqual(@as(u16, 200), response.status);
    }

    // Nothing in the worker wakes once the caches are released, the
    // scavenger has returned what they held and the sentinel's wake for the
    // boot evaluation has passed: every helper thread waits on a condition,
    // and the sentinel sleeps with no timeout, or until a wake it planned
    // for a deadline past the window (`idle_worker_window_ns`).
    const settle_start_ns = try process.monotonicNowNs();
    const quiet_from_ns = @max(settle_start_ns + idle_worker_settle_ns, ready_ns + idle_worker_boot_wake_ns);
    std.Thread.sleep(quiet_from_ns - settle_start_ns);
    const threads_before = try readThreadCount(handle.pid);
    const window_start_ns = try process.monotonicNowNs();
    const switches_before = try readContextSwitches(handle.pid);
    // The worker is the only process in its cgroup, so the cgroup's CPU
    // total is the worker's, every thread included.
    const usage_before_usec = try readLeafCpuUsageUsec(handle.leaf);
    std.Thread.sleep(idle_worker_window_ns);
    const usage_after_usec = try readLeafCpuUsageUsec(handle.leaf);
    const switches_after = try readContextSwitches(handle.pid);
    const window_end_ns = try process.monotonicNowNs();
    const threads_after = try readThreadCount(handle.pid);
    const window_ms = (window_end_ns - window_start_ns) / std.time.ns_per_ms;

    // Seccomp denies clone, so a thread that retired while idle could never
    // come back, and its context switches leave the total with it.
    if (threads_after != threads_before) {
        std.debug.print("an idle worker went from {d} to {d} threads in {d} ms\n", .{
            threads_before,
            threads_after,
            window_ms,
        });
        return error.IdleWorkerThreadRetired;
    }
    if (switches_after != switches_before) {
        std.debug.print("an idle worker's threads went from {d} to {d} context switches in {d} ms\n", .{
            switches_before,
            switches_after,
            window_ms,
        });
        return error.IdleWorkerThreadWoke;
    }
    // The cgroup's CPU total never decreases.
    const cpu_usec = usage_after_usec - usage_before_usec;
    if (cpu_usec > idle_worker_cpu_noise_usec) {
        std.debug.print("an idle worker spent {d} us of CPU in {d} ms\n", .{ cpu_usec, window_ms });
        return error.IdleWorkerSpentCpu;
    }
}

/// The least the retaining request below must grow its worker's leaf by,
/// well under the cells it keeps, so the bound holds however the engine
/// packs them.
const idle_collection_growth_min_bytes: u64 = 16 * 1024 * 1024;

test "a worker gives back what its requests left behind once it goes quiet, through its seccomp filter, and serves again with its state intact" {
    var spawned = try support.spawnZygote();
    defer spawned.deinit();

    // `/retain` keeps the cells it builds reachable from module state, so
    // no collection can free them while it runs or after; `/drop` lets them
    // go and then allocates nothing more.
    var route = try TestRoute.init("idle-collect",
        \\let retained = null;
        \\let served = 0;
        \\export default function handle(request) {
        \\  served += 1;
        \\  if (request.url.endsWith("/retain")) {
        \\    const rounds = [];
        \\    for (let round = 0; round < 64; round++) {
        \\      const items = [];
        \\      for (let i = 0; i < 4096; i++) items.push({ round, index: i, label: `item-${round}-${i}` });
        \\      rounds.push(items);
        \\    }
        \\    retained = rounds;
        \\    return new Response(`retained:${rounds.length * rounds[0].length}`);
        \\  }
        \\  if (request.url.endsWith("/drop")) {
        \\    const count = retained.length * retained[0].length;
        \\    retained = null;
        \\    return new Response(`dropped:${count}`);
        \\  }
        \\  return new Response(`served:${served}`);
        \\}
    );
    defer route.deinit();
    var launched = try launchOrSkip(&spawned, 90_040, .{ .routes = route.launchRoutes() });
    defer launched.deinit();
    const handle = &launched.handle;

    // Every reading follows a settle, in which the worker's idle collection
    // after its last request has run and the scavenger has returned what it
    // freed, so none races the collection.
    std.Thread.sleep(idle_worker_settle_ns);
    const ready_bytes = try support.readLeafUnsigned(handle.leaf, "memory.current");
    try serveForkedGet(handle, 90_040, 1, "/retain", "retained:262144");
    std.Thread.sleep(idle_worker_settle_ns);
    const retained_bytes = try support.readLeafUnsigned(handle.leaf, "memory.current");
    try serveForkedGet(handle, 90_041, 3, "/drop", "dropped:262144");
    std.Thread.sleep(idle_worker_settle_ns);
    const dropped_bytes = try support.readLeafUnsigned(handle.leaf, "memory.current");

    const growth_bytes = retained_bytes -| ready_bytes;
    const returned_bytes = retained_bytes -| dropped_bytes;
    if (growth_bytes < idle_collection_growth_min_bytes or returned_bytes < growth_bytes / 2) {
        std.debug.print("leaf memory.current: {d} B ready, {d} B retained, {d} B once dropped\n", .{
            ready_bytes,
            retained_bytes,
            dropped_bytes,
        });
        return error.IdleWorkerKeptGarbage;
    }
    // The worker lived through both collections, and its module state with
    // it.
    try serveForkedGet(handle, 90_042, 5, "/count", "served:3");
}

/// How much more private dirty memory a worker may hold after ten small
/// requests and the idle collection that follows them than when it was
/// ready: what the requests themselves leave, far below the zygote pages a
/// full collection would make the worker's own.
const small_requests_private_dirty_growth_max_bytes: u64 = 512 * 1024;

test "a worker serving small requests keeps the pages it shares with the zygote once it goes quiet" {
    var spawned = try support.spawnZygote();
    defer spawned.deinit();

    var route = try TestRoute.init("idle-small",
        \\export default function handle() {
        \\  return new Response("small");
        \\}
    );
    defer route.deinit();
    var launched = try launchOrSkip(&spawned, 90_043, .{ .routes = route.launchRoutes() });
    defer launched.deinit();
    const handle = &launched.handle;

    // Both readings follow a settle, the second one covering the idle
    // collection after the last request.
    std.Thread.sleep(idle_worker_settle_ns);
    const ready_bytes = try readPrivateDirtyBytes(handle.pid);
    for (0..10) |index| {
        try serveForkedGet(handle, 90_043 + index, @intCast(2 * index + 1), "/", "small");
    }
    std.Thread.sleep(idle_worker_settle_ns);
    const quiet_bytes = try readPrivateDirtyBytes(handle.pid);

    if (quiet_bytes -| ready_bytes > small_requests_private_dirty_growth_max_bytes) {
        std.debug.print("private dirty: {d} B ready, {d} B once quiet\n", .{ ready_bytes, quiet_bytes });
        return error.IdleWorkerUnsharedZygotePages;
    }
}

/// The Private_Dirty of process `pid`, from `/proc/<pid>/smaps_rollup`, in
/// bytes.
fn readPrivateDirtyBytes(pid: u32) !u64 {
    var path_buffer: [48]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/proc/{d}/smaps_rollup", .{pid});
    const rollup = try support.readFileAlloc(path, std.testing.allocator);
    defer std.testing.allocator.free(rollup);
    var lines = std.mem.splitScalar(u8, rollup, '\n');
    while (lines.next()) |line| {
        const prefix = "Private_Dirty:";
        if (!std.mem.startsWith(u8, line, prefix))
            continue;
        const value = std.mem.trim(u8, line[prefix.len..], &std.ascii.whitespace);
        const unit = " kB";
        if (!std.mem.endsWith(u8, value, unit))
            return error.InvalidSmapsRollup;
        const kib = try std.fmt.parseUnsigned(u64, std.mem.trimEnd(u8, value[0 .. value.len - unit.len], " "), 10);
        return kib * 1024;
    }
    return error.InvalidSmapsRollup;
}

/// Sends a GET of `path` to a forked worker on stream `stream_id` and
/// checks that it answers 200 with `expected_body`.
fn serveForkedGet(
    handle: *host.WorkerHandle,
    request_id: u64,
    stream_id: u32,
    path: []const u8,
    expected_body: []const u8,
) !void {
    const request = rt.RequestParts{ .method = "GET", .path = path };
    var dispatch = try rt.initDispatchWork(std.testing.allocator, .{
        .request_id = request_id,
        .deadline_monotonic_ns = try forkedDeadlineNs(),
        .request = request,
    });
    defer dispatch.deinit();
    try rt.sendIngressRoute(handle.control_fd, &dispatch, stream_id, request);
    var response = try readForkedIngressResponse(handle, request_id, 8_000);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqual(ipc.RequestDoneStatus.ok, response.done.status);
    try std.testing.expectEqualStrings(expected_body, response.body);
}

test "a worker's engine reads its footprint from its own cgroup leaf, within the leaf's memory.current" {
    var spawned = try support.spawnZygote();
    defer spawned.deinit();

    var route = try TestRoute.init("footprint", plain_route_source);
    defer route.deinit();
    var launched = try launchOrSkip(&spawned, 90_013, .{ .routes = route.launchRoutes() });
    defer launched.deinit();
    // The child read its footprint, its leaf's memory.current, before it
    // built its runtime and started its sentinel and compiler threads and
    // evaluated its route, and its heap gives a freed page back
    // only once the page has sat empty for the scavenger's epoch delay
    // (`pas_scavenger_max_epoch_delta`, 300 ms off macOS), so the leaf holds
    // at least as much once the worker is ready.
    const memory_current = try support.readLeafUnsigned(launched.handle.leaf, "memory.current");

    launched.stopWorker();
    spawned.shutdown();
    try support.expectChildExitStatus(spawned.pid, 0);
    var trace = try support.drainTrace(&spawned, std.testing.allocator);
    defer trace.deinit();

    const prefix = "child.memory_status=";
    const event = trace.messages[trace.indexOfPrefix(prefix) orelse return error.MissingTraceEvent];
    var fields = std.mem.splitScalar(u8, event[prefix.len..], ',');
    const footprint_bytes = try std.fmt.parseUnsigned(u64, fields.next() orelse return error.InvalidTraceEvent, 10);
    const limit_bytes = try std.fmt.parseUnsigned(u64, fields.next() orelse return error.InvalidTraceEvent, 10);
    try std.testing.expect(footprint_bytes != 0);
    try std.testing.expect(footprint_bytes <= memory_current);
    try std.testing.expectEqual(worker_memory_limit_bytes, limit_bytes);
}

test "a worker of a definition without a network grant boots through its filter with no egress descriptor and serves" {
    var spawned = try support.spawnZygote();
    defer spawned.deinit();

    var route = try TestRoute.init("no-grant-hello",
        \\export default function handle() {
        \\  return new Response("no grant");
        \\}
    );
    defer route.deinit();
    // `.none` sends WorkerInit without `flag_egress` and without the wake
    // descriptors, so the worker's loop has no egress descriptor to wait on.
    var launched = try launchOrSkip(&spawned, 90_014, .{
        .egress = .none,
        .routes = route.launchRoutes(),
    });
    defer launched.deinit();
    const handle = &launched.handle;

    var dispatch = try rt.initDispatchWork(std.testing.allocator, .{
        .request_id = 90_014,
        .deadline_monotonic_ns = try forkedDeadlineNs(),
        .egress_token = ipc.egress_token.none,
    });
    defer dispatch.deinit();
    try rt.sendIngressRoute(handle.control_fd, &dispatch, 1, .{});
    var response = try readForkedIngressResponse(handle, 90_014, 8_000);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("no grant", response.body);
}

test "two workers each see only their own /tmp, and the host's /tmp never gains their files" {
    var spawned = try support.spawnZygote();
    defer spawned.deinit();

    // Names unique to this run, so a file the host's /tmp holds can only be
    // one a worker wrote.
    const marker_path = try support.makeTempPath(std.testing.allocator, "collo-worker-tmp");
    defer std.testing.allocator.free(marker_path);
    const marker = std.fs.path.basename(marker_path);
    var route = try TestRoute.init("tmp-isolation",
        \\import fs from "node:fs";
        \\
        \\export default function handle(request) {
        \\  const name = request.query.get("name");
        \\  fs.writeFileSync(`/tmp/${name}`, name);
        \\  return new Response(fs.readdirSync("/tmp").join(","));
        \\}
    );
    defer route.deinit();

    var first = try launchOrSkip(&spawned, 90_015, .{ .routes = route.launchRoutes() });
    defer first.deinit();
    var second = try launchOrSkip(&spawned, 90_016, .{ .routes = route.launchRoutes() });
    defer second.deinit();

    const workers = [_]struct { handle: *host.WorkerHandle, suffix: []const u8, request_id: u64 }{
        .{ .handle = &first.handle, .suffix = "first", .request_id = 90_015 },
        .{ .handle = &second.handle, .suffix = "second", .request_id = 90_016 },
    };
    for (workers) |worker| {
        var name_buffer: [128]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "{s}-{s}", .{ marker, worker.suffix });
        var query_buffer: [160]u8 = undefined;
        var dispatch = try rt.initDispatchWork(std.testing.allocator, .{
            .request_id = worker.request_id,
            .deadline_monotonic_ns = try forkedDeadlineNs(),
            .request = .{ .raw_query = try std.fmt.bufPrint(&query_buffer, "name={s}", .{name}) },
        });
        defer dispatch.deinit();
        try rt.sendIngressRoute(worker.handle.control_fd, &dispatch, 1, .{});
        var response = try readForkedIngressResponse(worker.handle, worker.request_id, 8_000);
        defer response.deinit();
        try std.testing.expectEqual(@as(u16, 200), response.status);
        // Each worker's /tmp is a fresh tmpfs holding its own file alone.
        try std.testing.expectEqualStrings(name, response.body);

        // Each worker mounted its tmpfs in its own mount namespace, so the
        // host's /tmp never sees the file.
        var host_path_buffer: [160]u8 = undefined;
        const host_path = try std.fmt.bufPrint(&host_path_buffer, "/tmp/{s}", .{name});
        try std.testing.expectError(error.FileNotFound, std.fs.accessAbsolute(host_path, .{}));
    }
}

/// One line drained from a worker's console ring, its text copied out of the
/// drain's scratch.
const ConsoleLine = struct {
    header: worker_page.LogFrameHeader,
    text: []u8,
};

/// Drains every line the console ring of `view`, the host's mapping of a
/// worker's page, holds now, in ring order; the caller frees the result with
/// `freeConsoleLines`. The test must be the ring's only consumer.
fn drainConsoleLines(allocator: std.mem.Allocator, view: *worker_page.HostReaderView) ![]ConsoleLine {
    var lines: std.ArrayList(ConsoleLine) = .empty;
    errdefer {
        for (lines.items) |line|
            allocator.free(line.text);
        lines.deinit(allocator);
    }
    var scratch: [worker_page.LOG_LINE_BYTES_MAX]u8 = undefined;
    var batch: [16]worker_page.DrainedLogLine = undefined;
    // The scratch fits any line, so a drain of a ring that holds a line takes
    // at least one, and the ring holds at most one line per frame header that
    // fits in it: a ring its worker no longer writes is empty within this
    // many drains.
    const drain_count_max = worker_page.LOG_RING_BYTES / @sizeOf(worker_page.LogFrameHeader) + 1;
    for (0..drain_count_max) |_| {
        const count = try view.drainLogLinesChecked(&scratch, &batch);
        if (count == 0)
            return try lines.toOwnedSlice(allocator);
        for (batch[0..count]) |drained| {
            const text = try allocator.dupe(u8, drained.payload);
            errdefer allocator.free(text);
            try lines.append(allocator, .{ .header = drained.header, .text = text });
        }
    }
    return error.ConsoleRingNotEmptied;
}

fn freeConsoleLines(allocator: std.mem.Allocator, lines: []ConsoleLine) void {
    for (lines) |line|
        allocator.free(line.text);
    allocator.free(lines);
}

test "a handler's exception lands in its worker's console ring as the tenant's one line, with no runtime copy" {
    // The tenant's line carries the exception's text under the request's id;
    // the runtime writes no line of its own about it, so the exception's
    // text reaches only the tenant's log. The zygote is the installed
    // `collo`, so its workers log through that binary's `std_options.logFn`
    // (`runtime/src/main.zig`).
    var spawned = try support.spawnZygote();
    defer spawned.deinit();

    const thrown_message = "handler failed on purpose";
    var route = try TestRoute.init("tenant-exception", "export default function handle() {\n" ++
        "  throw new Error(\"" ++ thrown_message ++ "\");\n" ++
        "}\n");
    defer route.deinit();
    var launched = try launchOrSkip(&spawned, 90_017, .{ .routes = route.launchRoutes() });
    defer launched.deinit();
    const handle = &launched.handle;

    const request_id: u64 = 90_017;
    var dispatch = try rt.initDispatchWork(std.testing.allocator, .{
        .request_id = request_id,
        .deadline_monotonic_ns = try forkedDeadlineNs(),
    });
    defer dispatch.deinit();
    try rt.sendIngressRoute(handle.control_fd, &dispatch, 1, .{});
    var response = try readForkedIngressResponse(handle, request_id, 8_000);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 500), response.status);
    try std.testing.expectEqual(ipc.RequestDoneStatus.js_exception, response.done.status);

    // The VM thread publishes the line before it writes the 500, so the ring
    // holds it once the response is read.
    const lines = try drainConsoleLines(std.testing.allocator, &handle.metrics.?);
    defer freeConsoleLines(std.testing.allocator, lines);

    var tenant_count: usize = 0;
    for (lines) |line| {
        if (line.header.request_id == request_id) {
            tenant_count += 1;
            try std.testing.expectEqual(@intFromEnum(worker_page.LogLevel.err), line.header.level);
            try std.testing.expectEqual(worker_page.LogLineFlags.js_exception, line.header.flags);
            try std.testing.expect(std.mem.indexOf(u8, line.text, thrown_message) != null);
        } else if (line.header.flags & worker_page.LogLineFlags.runtime != 0) {
            var named_buffer: [48]u8 = undefined;
            const named = try std.fmt.bufPrint(&named_buffer, "request_id={d}", .{request_id});
            if (std.mem.indexOf(u8, line.text, named) != null) {
                std.debug.print("the runtime logged its own line about the exception: {s}\n", .{line.text});
                return error.TestUnexpectedResult;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 1), tenant_count);
}

/// File-name prefixes of the shared objects for libraries the binary links
/// statically: zlib, brotli, zstd and ICU.
const linked_library_prefixes = [_][]const u8{ "libz.so", "libbrotli", "libzstd", "libicu" };

/// Bound on a `/proc/<pid>/maps` read; a worker's maps are a few thousand
/// lines.
const worker_maps_bytes_max: usize = 4 * 1024 * 1024;

test "a forked worker maps no zlib, brotli, zstd or ICU shared object" {
    var spawned = try support.spawnZygote();
    defer spawned.deinit();

    var route = try TestRoute.init("maps", plain_route_source);
    defer route.deinit();
    var launched = try launchOrSkip(&spawned, 90_018, .{ .routes = route.launchRoutes() });
    defer launched.deinit();

    var path_buffer: [32]u8 = undefined;
    const maps_path = try std.fmt.bufPrint(&path_buffer, "/proc/{d}/maps", .{launched.handle.pid});
    const maps = try std.fs.cwd().readFileAlloc(std.testing.allocator, maps_path, worker_maps_bytes_max);
    defer std.testing.allocator.free(maps);
    inline for (linked_library_prefixes) |prefix| {
        if (std.mem.indexOf(u8, maps, "/" ++ prefix) != null) {
            std.debug.print("the worker maps a shared object starting with {s}\n", .{prefix});
            return error.TestUnexpectedResult;
        }
    }
}

test "worker node fs round trip stays inside chroot tmpfs" {
    var spawned = try support.spawnZygote();
    defer spawned.deinit();

    // The writable scratch is /tmp/**, so the round trip lives under /tmp;
    // the rest of the root is read-only, so a write outside /tmp fails with
    // the kernel's EROFS, and the machine's /etc does not exist there.
    var route = try TestRoute.init("fs-roundtrip",
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
    );
    defer route.deinit();

    var launched = try launchOrSkip(&spawned, 90_019, .{ .routes = route.launchRoutes() });
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
        return error.WorkerFsRoundTripUnexpectedResponse;
    }
}

test "worker node fs tmpfs cap returns ENOSPC" {
    var spawned = try support.spawnZygote();
    defer spawned.deinit();

    var route = try TestRoute.init("fs-cap",
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
    );
    defer route.deinit();

    var launched = try launchOrSkip(&spawned, 90_020, .{
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

test "a worker's root is read-only but for /tmp, with /var/task as its empty working directory, as node:fs sees it" {
    // Each write, mkdir or unlink outside /tmp gets the kernel's EROFS, a
    // relative one included since the working directory is /var/task, which
    // a listing of `.` shows empty where `/` would list tmp and var, and a
    // rename out of /tmp gets EXDEV, the error across mounts. A listing is
    // sorted, a directory read is EISDIR, a file listed is ENOTDIR, a path
    // holding a NUL is refused before any syscall, and `existsSync("")`
    // answers false.
    var spawned = try support.spawnZygote();
    defer spawned.deinit();

    var route = try TestRoute.init("read-only-root",
        \\import fs from "node:fs";
        \\
        \\function code(operation) {
        \\  try {
        \\    operation();
        \\    return "ok";
        \\  } catch (error) {
        \\    return error.code;
        \\  }
        \\}
        \\
        \\export default function handle() {
        \\  const task = fs.statSync("/var/task");
        \\  fs.mkdirSync("/tmp/s");
        \\  fs.writeFileSync("/tmp/s/b", "b");
        \\  fs.writeFileSync("/tmp/s/c", "c");
        \\  fs.writeFileSync("/tmp/s/a", "a");
        \\  fs.writeFileSync("/tmp/x", "x");
        \\  let renameCode = "none";
        \\  let renameDest = "none";
        \\  try {
        \\    fs.renameSync("/tmp/x", "/var/task/x");
        \\    renameCode = "renamed";
        \\  } catch (error) {
        \\    renameCode = error.code;
        \\    renameDest = error.dest;
        \\  }
        \\  return new Response(JSON.stringify({
        \\    taskIsDirectory: task.isDirectory,
        \\    taskMode: (task.mode & 0o777).toString(8),
        \\    taskList: fs.readdirSync("/var/task").join(","),
        \\    cwdList: fs.readdirSync(".").join(","),
        \\    rootList: fs.readdirSync("/").join(","),
        \\    sorted: fs.readdirSync("/tmp/s").join(","),
        \\    writeRoot: code(() => fs.writeFileSync("/new.txt", "x")),
        \\    writeVar: code(() => fs.writeFileSync("/var/new.txt", "x")),
        \\    writeTask: code(() => fs.writeFileSync("/var/task/new.txt", "x")),
        \\    writeRelative: code(() => fs.writeFileSync("relative.txt", "x")),
        \\    mkdirRoot: code(() => fs.mkdirSync("/made")),
        \\    mkdirVar: code(() => fs.mkdirSync("/var/made")),
        \\    mkdirTask: code(() => fs.mkdirSync("/var/task/made")),
        \\    unlinkRoot: code(() => fs.unlinkSync("/missing")),
        \\    unlinkVar: code(() => fs.unlinkSync("/var/missing")),
        \\    unlinkTask: code(() => fs.unlinkSync("/var/task/missing")),
        \\    renameCode,
        \\    renameDest,
        \\    etc: code(() => fs.readFileSync("/etc/passwd")),
        \\    readDirectory: code(() => fs.readFileSync("/tmp/s")),
        \\    listFile: code(() => fs.readdirSync("/tmp/s/a")),
        \\    nulPath: code(() => fs.readFileSync("/tmp/a\u0000b")),
        \\    emptyExists: fs.existsSync(""),
        \\  }));
        \\}
    );
    defer route.deinit();

    var launched = try launchOrSkip(&spawned, 90_021, .{ .routes = route.launchRoutes() });
    defer launched.deinit();
    const handle = &launched.handle;

    var dispatch = try rt.initDispatchWork(std.testing.allocator, .{
        .request_id = 90_021,
        .deadline_monotonic_ns = try forkedDeadlineNs(),
    });
    defer dispatch.deinit();
    try rt.sendIngressRoute(handle.control_fd, &dispatch, 1, .{});
    var response = try readForkedIngressResponse(handle, 90_021, 8_000);
    defer response.deinit();

    const expected =
        \\{"taskIsDirectory":true,"taskMode":"755","taskList":"","cwdList":"","rootList":"tmp,var","sorted":"a,b,c","writeRoot":"EROFS","writeVar":"EROFS","writeTask":"EROFS","writeRelative":"EROFS","mkdirRoot":"EROFS","mkdirVar":"EROFS","mkdirTask":"EROFS","unlinkRoot":"EROFS","unlinkVar":"EROFS","unlinkTask":"EROFS","renameCode":"EXDEV","renameDest":"/var/task/x","etc":"ENOENT","readDirectory":"EISDIR","listFile":"ENOTDIR","nulPath":"ERR_INVALID_ARG_VALUE","emptyExists":false}
    ;
    if (!std.mem.eql(u8, response.body, expected)) {
        std.debug.print("unexpected read-only root response (status={d}):\n{s}\n", .{ response.status, response.body });
        return error.WorkerRootUnexpectedResponse;
    }
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
    var route = try TestRoute.init("boot-fetch-600", source);
    defer route.deinit();

    var launched = try launchOrSkip(&spawned, 90_022, .{
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

    var route = try TestRoute.init("boot-throw",
        \\export default function handle() { return new Response("should-not-serve"); }
        \\throw new Error("boot init failed");
    );
    defer route.deinit();

    // The sync throw happens after the hoisted default export initialized:
    // without the sticky failed record the handler of an init that failed
    // would serve. The failure is the tenant code's, so the worker still
    // becomes ready, but it must answer 500.
    var launched = try launchOrSkip(&spawned, 90_023, .{ .routes = route.launchRoutes() });
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
    var wake_set = try ipc.egress_shared.WakeSet.create();
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
    var route = try TestRoute.init("egress-reattach", source);
    defer route.deinit();

    var launched = try launchOrSkip(&spawned, 90_024, .{
        .egress = .{ .attached = .{
            .shared_fds = first_fds,
            .boot = rt.localBootEgress(),
        } },
        .routes = route.launchRoutes(),
    });
    defer launched.deinit();
    const handle = &launched.handle;

    const before_body = try forkedRequestBody(handle, 90_024, 1, "/before");
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
    const during_body = try forkedRequestBody(handle, 90_025, 3, "/during");
    defer std.testing.allocator.free(during_body);
    try std.testing.expectEqualStrings("TypeError", during_body);
    try std.testing.expect(!process.pidFdHasExited(handle.pidfd));

    // The host attaches the worker to a new gateway, as the launcher does once
    // one is up, and the next fetch goes through it under its request's
    // token.
    var second_gateway = try attachToNewGateway(handle, &wake_set);
    defer second_gateway.deinit();

    const after_body = try forkedRequestBody(handle, 90_026, 5, "/after");
    defer std.testing.allocator.free(after_body);
    try std.testing.expectEqualStrings("fetched:200", after_body);
    try std.testing.expectEqual(@as(usize, 1), second_gateway.recordedFetchStarts(&starts));
    const presented = try rt.verifyEgressToken(&starts[0].egress_token);
    try std.testing.expectEqual(@as(u64, 90_026), presented.request_id);
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

    var wake_set = try ipc.egress_shared.WakeSet.create();
    defer wake_set.deinit();
    var first_gateway = try rt.LocalEgressGateway.startOnWakeSet(std.testing.allocator, .{
        .network = rt.local_origin_network,
    }, &wake_set);
    var first_gateway_alive = true;
    defer if (first_gateway_alive) first_gateway.deinit();
    var first_fds = first_gateway.takeWorkerSharedFds();
    defer first_fds.close();

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
    var route = try TestRoute.init("egress-replace", source);
    defer route.deinit();

    var launched = try launchOrSkip(&spawned, 90_027, .{
        .egress = .{ .attached = .{
            .shared_fds = first_fds,
            .boot = rt.localBootEgress(),
        } },
        .routes = route.launchRoutes(),
    });
    defer launched.deinit();
    const handle = &launched.handle;

    try sendForkedRequest(handle, 90_027, 1, "/hang");
    try waitForFetchStarts(first_gateway, 1, 8_000);

    // The worker still holds the first gateway's session when the host
    // attaches it to a new one, so it detaches first, which fails the fetch
    // in flight.
    var second_gateway = try attachToNewGateway(handle, &wake_set);
    defer second_gateway.deinit();
    const hang_body = try readForkedBody(handle, 90_027);
    defer std.testing.allocator.free(hang_body);
    try std.testing.expectEqualStrings("TypeError:fetch failed: egress gateway closed", hang_body);

    // Both gateways wake on the worker's one command eventfd, so the first
    // ends before the next fetch. The liveness pipe keeps the second
    // gateway's end, so the first one's exit does not detach the worker.
    first_gateway_alive = false;
    first_gateway.deinit();
    const after_body = try forkedRequestBody(handle, 90_028, 3, "/after");
    defer std.testing.allocator.free(after_body);
    try std.testing.expectEqualStrings("fetched:200", after_body);
    var starts: [2]rt.FetchStartIdentity = undefined;
    try std.testing.expectEqual(@as(usize, 1), second_gateway.recordedFetchStarts(&starts));
    try std.testing.expect(!process.pidFdHasExited(handle.pidfd));
}

/// Starts a gateway on a new egress session of the forked worker behind
/// `handle` and hands the worker that session in an `egress_attach` packet on
/// its control socket, as the launcher does once a new gateway is up. The
/// session is built on `wake_set`, the worker's, which the host keeps: a
/// worker keeps the wake descriptors it booted with for every later session.
/// The new session's write end of the liveness pipe also ends the hang-up an
/// earlier gateway's exit left on it.
fn attachToNewGateway(
    handle: *host.WorkerHandle,
    wake_set: *const ipc.egress_shared.WakeSet,
) !*rt.LocalEgressGateway {
    const gateway = try rt.LocalEgressGateway.startOnWakeSet(std.testing.allocator, .{
        .network = rt.local_origin_network,
    }, wake_set);
    errdefer gateway.deinit();
    var worker_half = gateway.takeWorkerSharedFds();
    defer worker_half.close();
    try ipc.egress_attach.send(handle.control_fd, worker_half);
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
    try sendForkedRequest(handle, request_id, stream_id, path);
    return readForkedBody(handle, request_id);
}

// WebAssembly must keep a worker alive after seccomp. The JSC wasm compile
// worklist starts its thread lazily with `clone`, which the filter denies
// with EPERM, and the failed Thread::create aborts the worker while its
// page still reads ready. The worker therefore starts the worklist threads
// in the boot window between the sandbox's privilege boundary and seccomp
// (`collo_vm_prespawn_compiler_threads`, which starts the JS worklist in the
// same call) and keeps them from retiring.
//
// Instantiation, async compilation and the IPInt-to-BBQ tier-up under a hot
// loop each run in their own worker, so an abort in one cannot mask the
// others, and each must leave its worker alive with its page reading ready.
// Each must also settle: the scheduler pumps JSC's DeferredWorkTimer
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

    var route = try TestRoute.init("wasm-probe", source);
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

    // A denied clone aborts the worker. The "DIED" text, with the page's
    // state and whether the process exited, is returned instead of an error,
    // so a worklist thread that was not started early fails the caller's
    // assertion with the full diagnosis, whose error name and
    // `process_exited` tell a death from a hang.
    var response = readForkedIngressResponse(handle, request_id, 8_000) catch |err| {
        const lifecycle: ?worker_page.LifecycleSnapshot = if (handle.metrics) |m| m.loadLifecycle() else null;
        const state_raw: u32 = if (lifecycle) |snapshot| snapshot.state else 0xffff_ffff;
        const reason_raw: u32 = if (lifecycle) |snapshot| snapshot.termination_reason else 0xffff_ffff;
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
        .{ .name = "instantiate", .id = 90_029, .expected = "ok:instantiate:42", .body = 
        \\    const { instance } = await WebAssembly.instantiate(bytes);
        \\    outcome = "ok:instantiate:" + instance.exports.f();
        },
        .{ .name = "compile", .id = 90_030, .expected = "ok:compile:true", .body = 
        \\    const mod = await WebAssembly.compile(bytes);
        \\    outcome = "ok:compile:" + (mod instanceof WebAssembly.Module);
        },
        .{ .name = "tierup", .id = 90_031, .expected = "ok:tierup:126000000", .body = 
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
    return host.dispatch.readResponse(std.testing.allocator, handle.responseChannels(), request_id, .{
        .wall_ms = budget_ms,
        .max_body_bytes = rt.default_read_max_body_bytes,
        .max_headers_bytes = rt.default_read_max_headers_bytes,
    });
}

/// The response frames of a well-formed answer to `identity`, head, one
/// chunk and end, as a worker sends them on `worker_fd`.
fn sendWellFormedResponse(worker_fd: std.posix.fd_t, identity: ipc.ingress_channel.RequestIdentity) !void {
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
}

test "bounded response reader errors on a malformed packet before the request_done" {
    // The reader takes packets until the request's `request_done`, which the
    // worker sends after every other descriptor of the request. A malformed
    // packet among them, such as message kind 8, which names no message,
    // surfaces as the decode error instead of a response returned as
    // success. No worker is involved: an in-process socketpair, with this
    // side playing both ends.
    const pair = try rt.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    const server_fd = pair[0];
    const worker_fd = pair[1];
    defer std.posix.close(server_fd);
    defer std.posix.close(worker_fd);

    const request_id: u64 = 91;
    const identity = ipc.ingress_channel.RequestIdentity{
        .request_id = request_id,
        .request_generation = 1,
        .request_lane_id = 0,
        .request_slot = 0,
    };
    try sendWellFormedResponse(worker_fd, identity);
    var bogus: [8]u8 = undefined;
    std.mem.writeInt(u32, bogus[0..4], 8, .little);
    std.mem.writeInt(u32, bogus[4..8], 0, .little);
    try fd_mod.writeAllRaw(worker_fd, &bogus);
    var send_scratch: [ipc.max_message_bytes]u8 = undefined;
    try ipc.ingress_channel.sendRequestDone(worker_fd, identity, 1, .{
        .status = .ok,
        .http_status = 200,
    }, &send_scratch);

    try std.testing.expectError(error.InvalidMessageKind, host.dispatch.readResponse(
        std.testing.allocator,
        .{ .control_fd = server_fd },
        request_id,
        .{
            .wall_ms = 2_000,
            .max_body_bytes = rt.default_read_max_body_bytes,
            .max_headers_bytes = rt.default_read_max_headers_bytes,
        },
    ));
}

test "bounded response reader errors on a broken control channel (POLLERR/POLLNVAL)" {
    // The reader classifies ERR and NVAL before readability, so a broken
    // channel reports the reader's own error instead of the socket's
    // incidental receive error or a truncated success. Only WouldBlock and
    // ControlPeerClosed are benign.
    const budget: host.dispatch.ReadBudget = .{
        .wall_ms = 2_000,
        .max_body_bytes = rt.default_read_max_body_bytes,
        .max_headers_bytes = rt.default_read_max_headers_bytes,
    };
    {
        // A closed fd number makes poll(2) report POLLNVAL.
        const pair = try rt.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
        std.posix.close(pair[0]);
        std.posix.close(pair[1]);
        try std.testing.expectError(
            error.ControlChannelBroken,
            host.dispatch.readResponse(std.testing.allocator, .{ .control_fd = pair[0] }, 92, budget),
        );
    }
    {
        // Connect a nonblocking TCP socket to a just-closed loopback
        // listener. Linux reports POLLERR|POLLHUP; the probe pins POLLERR
        // before handing the same fd to the reader.
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

        try std.testing.expectError(
            error.ControlChannelBroken,
            host.dispatch.readResponse(std.testing.allocator, .{ .control_fd = pollerr_fd }, 93, budget),
        );
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

/// What a host shares with a child it hands a WorkerInit by hand: the state
/// page, created and mapped here as a launch does, the completion eventfd,
/// and the payload memfd with its credit eventfd. `deinit` releases them.
const HandBuiltShared = struct {
    page_fd: std.posix.fd_t,
    page: worker_page.HostReaderView,
    completion_eventfd: std.posix.fd_t,
    payload_fd: std.posix.fd_t,
    payload_credit_eventfd: std.posix.fd_t,

    fn init(self: *HandBuiltShared) !void {
        const eventfd_flags = std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK;
        self.page_fd = try worker_page.createMemfd("collo-test-hand-built-page");
        errdefer std.posix.close(self.page_fd);
        self.page = try worker_page.mapHostReader(self.page_fd);
        errdefer self.page.deinit();
        self.completion_eventfd = try std.posix.eventfd(0, eventfd_flags);
        errdefer std.posix.close(self.completion_eventfd);
        self.payload_fd = try ipc.ingress_channel.createSharedPayloadMemfd();
        errdefer std.posix.close(self.payload_fd);
        self.payload_credit_eventfd = try std.posix.eventfd(0, eventfd_flags);
    }

    fn deinit(self: *HandBuiltShared) void {
        std.posix.close(self.payload_credit_eventfd);
        std.posix.close(self.payload_fd);
        std.posix.close(self.completion_eventfd);
        self.page.deinit();
        std.posix.close(self.page_fd);
        self.* = undefined;
    }

    /// The WorkerInit table for this host's descriptors and the caller's
    /// leaf, egress and artifact, every one borrowed.
    fn fds(
        self: *const HandBuiltShared,
        leaf_fd: std.posix.fd_t,
        egress_shared_fds: ipc.egress_shared.RawFds,
        module_pack_fd: std.posix.fd_t,
    ) ipc.WorkerInitFds {
        return .{
            .metrics_fd = self.page_fd,
            .completion_eventfd = self.completion_eventfd,
            .ingress_payload_fd = self.payload_fd,
            .ingress_payload_credit_eventfd = self.payload_credit_eventfd,
            .cgroup_dir_fd = leaf_fd,
            .egress_shared_fds = egress_shared_fds,
            .module_pack_fd = module_pack_fd,
        };
    }

    /// Fails unless the page's lifecycle is still the one the host wrote:
    /// a failed boot reports its reason on the init socket and leaves the
    /// page alone.
    fn expectPageAsHostWrote(self: *const HandBuiltShared) !void {
        const lifecycle = self.page.loadLifecycle();
        try std.testing.expectEqual(@as(?worker_page.State, .forked), lifecycle.knownState());
        try std.testing.expectEqual(@as(?worker_page.TerminationReason, .crash), lifecycle.knownTerminationReason());
    }
};

test "a WorkerInit whose leaf is no cgroup fails as invalid_worker_init and leaves the page as the host wrote it" {
    var spawned = try support.spawnZygote();
    defer spawned.deinit();
    var child = try forkBareOrSkip(&spawned, 90_032);
    defer child.deinit();
    var shared: HandBuiltShared = undefined;
    try shared.init();
    defer shared.deinit();
    var route = try TestRoute.init("leaf-refused", plain_route_source);
    defer route.deinit();
    var not_a_leaf = std.testing.tmpDir(.{});
    defer not_a_leaf.cleanup();

    var message = ipc.WorkerInit.init(worker_memory_limit_bytes);
    message.init_deadline_mono_ns = (try process.monotonicNowNs()) + 3 * std.time.ns_per_s;
    try ipc.sendWorkerInit(child.initFd(), &message, shared.fds(not_a_leaf.dir.fd, .{}, route.pack_fd));

    switch (try support.receiveWorkerInitOutcomeBeforeTimeout(child.initFd(), child.pidfd(), 3_000)) {
        .ready => return error.UnexpectedReady,
        .failed => |reason| try std.testing.expectEqual(ipc.WorkerInitFailedReason.invalid_worker_init, reason),
    }
    try support.waitForPidFdExit(child.pidfd());
    try shared.expectPageAsHostWrote();
    // The child mapped the page, so its early phases are there, and never
    // got past the leaf.
    try std.testing.expect(shared.page.loadBootPhaseStampNs(.metrics_mapped) != 0);
    try std.testing.expectEqual(@as(u64, 0), shared.page.loadBootPhaseStampNs(.cgroup_validated));

    var trace = try support.drainTrace(&spawned, std.testing.allocator);
    defer trace.deinit();
    try std.testing.expect(trace.containsPrefix("child.boot_failed=InvalidWorkerCgroupDir"));
    try std.testing.expect(!trace.containsPrefix("child.cgroup.validated"));
}

test "a WorkerInit with an unknown flag fails as invalid_worker_init and leaves the page as the host wrote it" {
    var spawned = try support.spawnZygote();
    defer spawned.deinit();
    var child = try forkBareOrSkip(&spawned, 90_033);
    defer child.deinit();
    var shared: HandBuiltShared = undefined;
    try shared.init();
    defer shared.deinit();
    var route = try TestRoute.init("flag-refused", plain_route_source);
    defer route.deinit();

    var message = ipc.WorkerInit.init(worker_memory_limit_bytes);
    message.init_deadline_mono_ns = (try process.monotonicNowNs()) + 3 * std.time.ns_per_s;
    message.flags |= 1 << 31;
    try ipc.sendWorkerInit(child.initFd(), &message, shared.fds(child.leaf_fd, .{}, route.pack_fd));

    switch (try support.receiveWorkerInitOutcomeBeforeTimeout(child.initFd(), child.pidfd(), 3_000)) {
        .ready => return error.UnexpectedReady,
        .failed => |reason| try std.testing.expectEqual(ipc.WorkerInitFailedReason.invalid_worker_init, reason),
    }
    try support.waitForPidFdExit(child.pidfd());
    try shared.expectPageAsHostWrote();

    var trace = try support.drainTrace(&spawned, std.testing.allocator);
    defer trace.deinit();
    try std.testing.expect(trace.containsPrefix("child.boot_failed=InvalidWorkerInitFlags"));
    try std.testing.expect(!trace.containsPrefix("child.worker_init.validated"));
}

test "a child sends one outcome for a WorkerInit short of a descriptor and exits with nothing after it" {
    var spawned = try support.spawnZygote();
    defer spawned.deinit();
    var child = try forkBareOrSkip(&spawned, 90_034);
    defer child.deinit();

    // A WorkerInit without its descriptor table, which the child's receive
    // refuses for its first missing descriptor.
    var message = ipc.WorkerInit.init(worker_memory_limit_bytes);
    message.init_deadline_mono_ns = (try process.monotonicNowNs()) + 3 * std.time.ns_per_s;
    try ipc.packet.sendExact(child.initFd(), std.mem.asBytes(&message));

    switch (try zygote.host_client.receiveWorkerInitOutcome(child.initFd())) {
        .ready => return error.UnexpectedReady,
        .failed => |reason| try std.testing.expectEqual(ipc.WorkerInitFailedReason.missing_metrics_fd, reason),
    }
    // Once the child is gone, its init socket holds no second outcome.
    try support.waitForPidFdExit(child.pidfd());
    try std.testing.expectError(error.PeerClosed, ipc.recvInitOutcome(child.initFd()));

    var trace = try support.drainTrace(&spawned, std.testing.allocator);
    defer trace.deinit();
    try std.testing.expect(trace.containsPrefix("child.worker_init.recv_failed=MissingMetricsFd"));
}

test "worker boot eval hung in the sync slice dies typed at the init deadline before the wall kill" {
    try expectBootDiesAtInitDeadline(1, 90_035);
}

test "a boot past its init deadline evaluates no further route, so a worker of the most isolated routes still dies typed in time" {
    try expectBootDiesAtInitDeadline(ipc.route_table.routes_max, 90_036);
}

/// Route 0's entry: its synchronous top-level slice never lets a microtask
/// drain settle, since each microtask enqueues another, and it starts no
/// timer and no fetch, so only the watchdog can end it.
const init_deadline_spin_source =
    \\export default function handle() { return new Response("unreachable"); }
    \\function spin() { Promise.resolve().then(spin); }
    \\spin();
;

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

    // The child is born inside a leaf with the limits the WorkerInit below
    // announces, so its leaf check passes and the boot reaches the eval.
    var child = try forkBareOrSkip(&spawned, fork_job_id);
    defer child.deinit();
    // A broken watchdog leaves the child spinning JS forever; `deinit` kills
    // it, while the passing path observes the voluntary exit first.
    var shared: HandBuiltShared = undefined;
    try shared.init();
    defer shared.deinit();
    var wake_set = try ipc.egress_shared.WakeSet.create();
    defer wake_set.deinit();
    var egress_shared = try ipc.egress_shared.createSessionForWorker(&wake_set);
    defer egress_shared.deinit();

    const routes_max = ipc.route_table.routes_max;
    var specifier_buffers: [routes_max][64]u8 = undefined;
    var modules: [routes_max]ipc.module_pack.Module = undefined;
    var routes: [routes_max]ipc.route_table.RouteInput = undefined;
    for (0..route_count) |index| {
        const specifier = try std.fmt.bufPrint(&specifier_buffers[index], "{s}/init-deadline-{d}.js", .{
            ipc.module_pack.task_root,
            index,
        });
        modules[index] = .{
            .specifier = specifier,
            .source = if (index == 0) init_deadline_spin_source else plain_route_source,
        };
        routes[index] = .{ .entry_module = @intCast(index) };
    }
    const pack_fd = try host.dispatch.createDefinitionFd(std.testing.allocator, modules[0..route_count], routes[0..route_count]);
    defer std.posix.close(pack_fd);

    var message = ipc.WorkerInit.init(worker_memory_limit_bytes);
    message.flags |= ipc.WorkerInit.flag_isolate_realm;
    // The host's window: now plus WORKER_INIT_TIMEOUT_MS, fixed before the
    // send, the same absolute value both ends enforce. The boot token takes
    // it as its deadline too: this boot ends at the init deadline, so the
    // budget `host/launch.zig:bootEgressDeadline` adds would change nothing.
    const init_deadline_mono_ns = (try process.monotonicNowNs()) +
        @as(u64, @intCast(limits.process.WORKER_INIT_TIMEOUT_MS)) * std.time.ns_per_ms;
    message.init_deadline_mono_ns = init_deadline_mono_ns;
    message.boot_egress_token = rt.bootEgressToken(init_deadline_mono_ns);
    try ipc.sendWorkerInit(
        child.initFd(),
        &message,
        shared.fds(child.leaf_fd, egress_shared.rawForWorker(), pack_fd),
    );

    // Wait past the deadline: a working watchdog answers typed before it; a
    // broken one turns into WorkerInitTimeout here and fails the test.
    const outcome = try support.receiveWorkerInitOutcomeBeforeTimeout(
        child.initFd(),
        child.pidfd(),
        limits.process.WORKER_INIT_TIMEOUT_MS + 2_000,
    );
    const outcome_at_ns = try process.monotonicNowNs();
    switch (outcome) {
        .ready => return error.UnexpectedReady,
        .failed => |reason| try std.testing.expectEqual(ipc.WorkerInitFailedReason.init_deadline_exceeded, reason),
    }
    // The watchdog arms at the deadline less the reserve, so the typed
    // failure lands inside the reserve: at or after the arm point and
    // strictly before the deadline at which the host would SIGKILL.
    try std.testing.expect(outcome_at_ns < init_deadline_mono_ns);
    try std.testing.expect(outcome_at_ns >= init_deadline_mono_ns - limits.process.WORKER_INIT_CLEANUP_RESERVE_NS);

    // The child exits by itself inside the reserve; this path sent no
    // signal.
    try support.waitForPidFdExit(child.pidfd());
    try shared.expectPageAsHostWrote();
    // The child died in the evaluation: every native phase completed, and
    // the evaluation never did.
    try std.testing.expect(shared.page.loadBootPhaseStampNs(.seccomp_applied) != 0);
    try std.testing.expectEqual(@as(u64, 0), shared.page.loadBootPhaseStampNs(.routes_evaluated));

    var trace = try support.drainTrace(&spawned, std.testing.allocator);
    defer trace.deinit();
    try std.testing.expect(trace.containsPrefix("child.node_fs.enabled"));
    try std.testing.expect(trace.containsPrefix("child.trace.closed"));
}

//! Support for tests that drive a real zygote (`zygote_support`): where test
//! workers' cgroup leaves go, the blocking fork driver and init-outcome wait
//! a host that owns its thread uses, a worker launched through the host path
//! to ready, a child forked into a leaf with no WorkerInit, zygote spawns
//! with and without the boot trace, and that trace read back as lines. The
//! zygote-integration and local-e2e lanes, the forked web API suites and
//! the zygote's unit suites use it, on the test's own thread.
//!
//! Every zygote starts from the installed `collo` binary at
//! `collo_process_options.collo_executable_path`, a plain path, so a run step
//! whose tests use this module depends on the install (`install_collo_step`
//! in `runtime/build/context.zig`). A worker launch needs the delegated
//! cgroup subtree and fails with `error.WorkerCgroupDelegationUnavailable`
//! without one, which the tests turn into a skip.

const std = @import("std");
const process_options = @import("collo_process_options");
const process = @import("collo_os").process;
const worker = @import("collo_worker");

pub const bindings = @import("collo_bindings");
pub const zygote = @import("collo_zygote");
pub const host = @import("collo_host");

const ipc = zygote.ipc;
const host_client = zygote.host_client;

comptime {
    _ = worker;
}

const test_cgroup_root_env = "COLLO_TEST_WORKER_CGROUP_ROOT";
const worker_cgroup_root_env = "COLLO_WORKER_CGROUP_ROOT";

/// Where a test's worker leaves go: the first non-empty directory named by
/// the test variable, which `wsl-config run` exports, or by the variable
/// `collo serve` reads (`worker_cgroup_root_env` in `server/boot/root.zig`).
/// Each names a process-free delegated directory. Without either, a test
/// carves the subtree out of its own cgroup, which works only when that
/// cgroup is delegated and holds no other process.
pub fn cgroupPlacement() host.cgroup_root.Placement {
    inline for (.{ test_cgroup_root_env, worker_cgroup_root_env }) |name| {
        if (std.posix.getenv(name)) |value| {
            if (value.len != 0)
                return .{ .env_root = value };
        }
    }
    return .delegated;
}

/// The worker cgroup root at `cgroupPlacement()`, which the caller owns and
/// releases with `deinit`. Fails with `error.WorkerCgroupDelegationUnavailable`
/// when this environment cannot place workers.
pub fn cgroupRoot(allocator: std.mem.Allocator) !host.WorkerCgroupRoot {
    return host.WorkerCgroupRoot.init(allocator, cgroupPlacement());
}

/// Forks the child of `fork_job_id` into the leaf `leaf_fd` and waits for
/// the reply: `sendForkRequest`, a wait of at most `fork_reply_timeout_ms`,
/// then `receiveForkReply` (`zygote/host_client.zig`). A zygote that misses
/// the reply is killed and the call fails with `ZygoteDied`. The leaf stays
/// the caller's. Blocks, so only a host that owns its thread calls it.
pub fn requestFork(
    spawned: *host_client.SpawnedZygote,
    fork_job_id: u64,
    leaf_fd: std.posix.fd_t,
) host_client.ForkError!host_client.ForkedWorker {
    try host_client.sendForkRequest(spawned, fork_job_id, leaf_fd);
    const control_fd = spawned.control_fd orelse return error.ZygoteProtocol;
    var pollfds = [_]std.posix.pollfd{.{
        .fd = control_fd,
        .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR,
        .revents = 0,
    }};
    const ready = std.posix.poll(&pollfds, host_client.fork_reply_timeout_ms) catch |err|
        return host_client.zygoteFailure(spawned, err);
    if (ready == 0) {
        host_client.killUnresponsiveZygote(spawned, fork_job_id);
        return error.ZygoteDied;
    }
    // HUP and ERR fall through, so the receive reports the exact error.
    return host_client.receiveForkReply(spawned, fork_job_id);
}

/// Waits up to `timeout_ms` for a child's answer to WorkerInit on `fd`, or
/// its exit on `pidfd`. An exit with no answer queued fails with
/// `error.WorkerInitFailed` and a silent child with `error.WorkerInitTimeout`.
pub fn receiveWorkerInitOutcomeBeforeTimeout(
    fd: std.posix.fd_t,
    pidfd: std.posix.fd_t,
    timeout_ms: i32,
) !ipc.InitOutcome {
    const ready_events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR;
    var pollfds = [2]std.posix.pollfd{
        .{ .fd = fd, .events = ready_events, .revents = 0 },
        .{ .fd = pidfd, .events = ready_events, .revents = 0 },
    };
    if (try std.posix.poll(&pollfds, timeout_ms) == 0)
        return error.WorkerInitTimeout;
    // A queued answer wins over the exit that follows it.
    if ((pollfds[0].revents & std.posix.POLL.IN) != 0)
        return host_client.receiveWorkerInitOutcome(fd);
    if ((pollfds[1].revents & ready_events) != 0)
        return error.WorkerInitFailed;
    if ((pollfds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0)
        return host_client.receiveWorkerInitOutcome(fd);
    return error.WorkerInitTimeout;
}

/// A worker launched through the whole host path: its own cgroup leaf,
/// forked into it, handed its WorkerInit, ready. `deinit` tears the worker
/// down, which removes its leaf, before the root that holds the leaf.
pub const LaunchedWorker = struct {
    allocator: std.mem.Allocator,
    root: host.WorkerCgroupRoot,
    /// The wake set a worker launched with a null `egress` booted detached
    /// on; empty when the caller chose the worker's egress (`none`,
    /// `detached` or `attached`) and keeps any wake set it needs.
    wake_set: ipc.egress_shared.WakeSet,
    handle: host.WorkerHandle,
    handle_alive: bool = true,

    /// Tears the worker down ahead of `deinit`, for tests that observe the
    /// teardown, such as the leaf's removal, while the root still exists.
    pub fn stopWorker(self: *LaunchedWorker) void {
        if (!self.handle_alive)
            return;
        self.handle_alive = false;
        self.handle.deinit();
    }

    pub fn deinit(self: *LaunchedWorker) void {
        self.stopWorker();
        self.wake_set.deinit();
        self.root.deinit(self.allocator);
        self.* = undefined;
    }
};

/// `host.LaunchOptions` with `egress` optional and without
/// `memory_limit_bytes`, which `launchWorker` takes on its own. A null
/// `egress` launches the worker detached on a wake set the launched worker
/// keeps (`LaunchedWorker.wake_set`), so a test that makes no fetch states
/// nothing about egress. Every other field is the host's, default included,
/// since the type is built from the host's.
pub const LaunchOptions = blk: {
    const info = @typeInfo(host.LaunchOptions).@"struct";
    var fields: [info.fields.len - 1]std.builtin.Type.StructField = undefined;
    var count: usize = 0;
    for (info.fields) |host_field| {
        if (std.mem.eql(u8, host_field.name, "memory_limit_bytes"))
            continue;
        var field = host_field;
        if (std.mem.eql(u8, field.name, "egress")) {
            const no_egress: ?host.launch.LaunchEgress = null;
            field.type = ?host.launch.LaunchEgress;
            field.default_value_ptr = &no_egress;
            field.alignment = @alignOf(?host.launch.LaunchEgress);
        }
        fields[count] = field;
        count += 1;
    }
    break :blk @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = false,
    } });
};

/// The host's options for `options`, with `memory_limit_bytes` and `egress`
/// as the launch's.
fn hostLaunchOptions(
    options: LaunchOptions,
    memory_limit_bytes: u64,
    egress: host.launch.LaunchEgress,
) host.LaunchOptions {
    var launch_options: host.LaunchOptions = undefined;
    inline for (@typeInfo(host.LaunchOptions).@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "memory_limit_bytes")) {
            launch_options.memory_limit_bytes = memory_limit_bytes;
        } else if (comptime std.mem.eql(u8, field.name, "egress")) {
            launch_options.egress = egress;
        } else {
            @field(launch_options, field.name) = @field(options, field.name);
        }
    }
    return launch_options;
}

/// Creates the leaf `worker-<fork_job_id>` with `memory_limit_bytes`, forks
/// into it and runs the launch to ready; the caller owns the result. When
/// `options` brings no egress, the worker boots detached on a wake set the
/// result owns. On any failure the forked child is killed, its leaf removed
/// and every resource released; `error.WorkerCgroupDelegationUnavailable`
/// means this environment cannot place workers at all.
pub fn launchWorker(
    allocator: std.mem.Allocator,
    spawned: *host_client.SpawnedZygote,
    memory_limit_bytes: u64,
    fork_job_id: u64,
    options: LaunchOptions,
) !LaunchedWorker {
    var root = try cgroupRoot(allocator);
    errdefer root.deinit(allocator);

    var wake_set: ipc.egress_shared.WakeSet = .{};
    errdefer wake_set.deinit();
    const egress: host.launch.LaunchEgress = options.egress orelse blk: {
        wake_set = try ipc.egress_shared.WakeSet.create();
        break :blk .{ .detached = &wake_set };
    };
    const launch_options = hostLaunchOptions(options, memory_limit_bytes, egress);

    const leaf_fd = try root.createWorkerDir(fork_job_id, .{ .memory_limit_bytes = memory_limit_bytes });
    // The machine owns the leaf's descriptor from here, and a launch that
    // fails hands the leaf back for removal.
    var machine = host.launch.Machine.init(root.leaf(fork_job_id), leaf_fd, spawned.trace_write_fd);
    var forked = requestFork(spawned, fork_job_id, leaf_fd) catch |err| {
        var abandoned = machine.abandon();
        abandoned.reap();
        return err;
    };
    // The launch takes every descriptor `forked` holds, whatever its outcome.
    defer forked.deinit();
    const handle = try host.runToReady(&machine, &forked, &launch_options);
    return .{
        .allocator = allocator,
        .root = root,
        .wake_set = wake_set,
        .handle = handle,
    };
}

/// A child forked into a leaf of its own that gets no WorkerInit from this
/// module, for tests that hand-build one or send none. `deinit` kills the
/// child if it still runs, waits for its exit, then removes the leaf and
/// the root.
pub const BareChild = struct {
    allocator: std.mem.Allocator,
    root: host.WorkerCgroupRoot,
    forked: host_client.ForkedWorker,
    /// The leaf's directory, which a hand-built WorkerInit carries; the
    /// child already left it behind.
    leaf_fd: std.posix.fd_t,

    pub fn initFd(self: *const BareChild) std.posix.fd_t {
        return self.forked.worker_init_fd.?;
    }

    pub fn pidfd(self: *const BareChild) std.posix.fd_t {
        return self.forked.pidfd.?;
    }

    pub fn deinit(self: *BareChild) void {
        const child_pidfd = self.pidfd();
        process.pidFdSendSignal(child_pidfd, std.posix.SIG.KILL) catch |err| switch (err) {
            error.ProcessNotFound => {},
            else => std.log.warn("failed to kill a bare test child: {s}", .{@errorName(err)}),
        };
        _ = process.waitForPidFdExit(child_pidfd, 1_000) catch false;
        const fork_job_id = self.forked.fork_job_id;
        self.forked.deinit();
        std.posix.close(self.leaf_fd);
        // The leaf refuses its removal while the child is a member.
        self.root.leaf(fork_job_id).remove();
        self.root.deinit(self.allocator);
        self.* = undefined;
    }
};

/// Creates the leaf `worker-<fork_job_id>` with `memory_limit_bytes` and
/// forks a child into it; the caller owns the result.
/// `error.WorkerCgroupDelegationUnavailable` means this environment cannot
/// place workers at all.
pub fn forkBareChild(
    allocator: std.mem.Allocator,
    spawned: *host_client.SpawnedZygote,
    memory_limit_bytes: u64,
    fork_job_id: u64,
) !BareChild {
    var root = try cgroupRoot(allocator);
    errdefer root.deinit(allocator);
    const leaf_fd = try root.createWorkerDir(fork_job_id, .{ .memory_limit_bytes = memory_limit_bytes });
    errdefer {
        std.posix.close(leaf_fd);
        root.leaf(fork_job_id).remove();
    }
    const forked = try requestFork(spawned, fork_job_id, leaf_fd);
    return .{
        .allocator = allocator,
        .root = root,
        .forked = forked,
        .leaf_fd = leaf_fd,
    };
}

/// Spawns a zygote that writes the boot trace, as every test reads it.
pub fn spawnZygote() !host_client.SpawnedZygote {
    return host_client.spawnZygote(.{
        .executable_path = process_options.collo_executable_path,
        .trace = true,
    });
}

/// Spawns a zygote with no trace pipe, as `collo serve` does unless an
/// operator asks for the trace.
pub fn spawnZygoteWithoutTrace() !host_client.SpawnedZygote {
    return host_client.spawnZygote(.{
        .executable_path = process_options.collo_executable_path,
        .trace = false,
    });
}

/// Trace lines read back from a zygote's trace pipe, in the order they were
/// written. `deinit` frees them.
pub const TraceLog = struct {
    allocator: std.mem.Allocator,
    messages: [][]u8,

    pub fn deinit(self: *TraceLog) void {
        for (self.messages) |message|
            self.allocator.free(message);
        self.allocator.free(self.messages);
        self.* = undefined;
    }

    pub fn countEq(self: TraceLog, expected: []const u8) usize {
        var count: usize = 0;
        for (self.messages) |message| {
            if (std.mem.eql(u8, message, expected))
                count += 1;
        }
        return count;
    }

    pub fn indexOf(self: TraceLog, expected: []const u8) ?usize {
        for (self.messages, 0..) |message, index| {
            if (std.mem.eql(u8, message, expected))
                return index;
        }
        return null;
    }

    pub fn indexOfPrefix(self: TraceLog, prefix: []const u8) ?usize {
        for (self.messages, 0..) |message, index| {
            if (std.mem.startsWith(u8, message, prefix))
                return index;
        }
        return null;
    }

    pub fn containsPrefix(self: TraceLog, prefix: []const u8) bool {
        return self.indexOfPrefix(prefix) != null;
    }
};

/// Waits for `pid`, a child of the test process such as the zygote, and
/// expects a normal exit with status `expected`.
pub fn expectChildExitStatus(pid: u32, expected: u8) !void {
    const result = std.posix.waitpid(@intCast(pid), 0);
    try std.testing.expect(std.c.W.IFEXITED(result.status));
    try std.testing.expectEqual(expected, std.c.W.EXITSTATUS(result.status));
}

/// Fails the test unless the process behind `pidfd` exits within a second.
pub fn waitForPidFdExit(pidfd: std.posix.fd_t) !void {
    var pollfds = [1]std.posix.pollfd{
        .{
            .fd = pidfd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
    };

    const ready = try std.posix.poll(&pollfds, 1_000);
    try std.testing.expect(ready > 0);
    try std.testing.expect((pollfds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0);
}

/// Reads every line written so far to the trace pipe of `spawned`, which the
/// zygote, each worker child's boot and the host's launch write to; the
/// caller owns the log. The read never blocks, so a test drains only after
/// the events it checks. A zygote spawned without a trace yields an empty
/// log.
pub fn drainTrace(spawned: *const host_client.SpawnedZygote, allocator: std.mem.Allocator) !TraceLog {
    const trace_fd = spawned.trace_read_fd orelse return .{
        .allocator = allocator,
        .messages = try allocator.alloc([]u8, 0),
    };

    var bytes = std.array_list.Aligned(u8, null).empty;
    defer bytes.deinit(allocator);

    while (true) {
        var buffer: [256]u8 = undefined;
        const read_len = std.posix.read(trace_fd, &buffer) catch |err| switch (err) {
            error.WouldBlock => break,
            else => return err,
        };
        if (read_len == 0)
            break;
        try bytes.appendSlice(allocator, buffer[0..read_len]);
    }

    var lines = std.array_list.Aligned([]u8, null).empty;
    errdefer {
        for (lines.items) |line|
            allocator.free(line);
        lines.deinit(allocator);
    }

    var iterator = std.mem.splitScalar(u8, bytes.items, '\n');
    while (iterator.next()) |line| {
        if (line.len == 0)
            continue;
        try lines.append(allocator, try allocator.dupe(u8, line));
    }

    return .{
        .allocator = allocator,
        .messages = try lines.toOwnedSlice(allocator),
    };
}

/// Expects the first occurrence of line `first` before the first occurrence
/// of `second`; fails with `error.MissingTraceEvent` when either is absent.
pub fn expectTraceBefore(trace: TraceLog, first: []const u8, second: []const u8) !void {
    const first_index = trace.indexOf(first) orelse return error.MissingTraceEvent;
    const second_index = trace.indexOf(second) orelse return error.MissingTraceEvent;
    try std.testing.expect(first_index < second_index);
}

/// The unsigned number the leaf's file `file_name` holds, such as
/// `memory.current`, read without a path.
pub fn readLeafUnsigned(leaf: host.WorkerLeaf, file_name: []const u8) !u64 {
    var buffer: [64]u8 = undefined;
    const contents = try leaf.readFile(file_name, &buffer);
    return std.fmt.parseUnsigned(u64, std.mem.trim(u8, contents, &std.ascii.whitespace), 10);
}

pub fn readFileAlloc(path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, 4096);
}

pub fn makeTempPath(allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "/tmp/{s}-{d}-{d}", .{
        prefix,
        std.c.getpid(),
        try process.monotonicNowNs(),
    });
}

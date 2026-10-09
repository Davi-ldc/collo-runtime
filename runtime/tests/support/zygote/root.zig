//! Support for tests that drive a real zygote (`zygote_support`): where test
//! workers' cgroup leaves go, a worker launched through the host path to
//! ready, zygote spawns with test options, the zygote's trace pipe read back
//! as lines, and the host's end of the fs fault channel. The
//! zygote-integration and local-e2e lanes, the forked web API suites and the
//! zygote's sandbox tests use it, on the test's own thread.
//!
//! Every zygote starts from the installed `collo` binary at
//! `collo_process_options.collo_executable_path`, a plain path, so a run step
//! whose tests use this module depends on the install (`install_collo_step`
//! in `runtime/build/context.zig`). A worker launch needs the delegated
//! cgroup subtree and fails with `error.WorkerCgroupDelegationUnavailable`
//! without one, which the tests turn into a skip.

const std = @import("std");
const process_options = @import("collo_process_options");
const fd_mod = @import("collo_os").fd;
const process = @import("collo_os").process;
const worker = @import("collo_worker");

pub const bindings = @import("collo_bindings");
pub const zygote = @import("collo_zygote");
pub const host = @import("collo_host");

const ipc = zygote.ipc;

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

/// A worker launched through the whole host path: its own cgroup leaf,
/// forked into it, handed its WorkerInit, ready. `deinit` tears the worker
/// down, which removes its leaf, before the root that holds the leaf.
pub const LaunchedWorker = struct {
    allocator: std.mem.Allocator,
    root: host.WorkerCgroupRoot,
    /// The wake set of a worker the caller launched without egress, which
    /// booted detached; empty when the caller brought the worker's egress
    /// and keeps its own wake set.
    wake_set: ipc.egress_shared.WakeSet,
    handle: host.WorkerHandle,
    handle_alive: bool = true,

    /// Tears the worker down ahead of `deinit`, for tests that observe the
    /// teardown (tmp root gone, leaf removed) while the root still exists.
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

/// `host.LaunchOptions` with `egress` optional: null launches the worker
/// detached on a wake set the launched worker keeps
/// (`LaunchedWorker.wake_set`), so a test that makes no fetch states nothing
/// about egress. Every other field is the host's, default included, since the
/// type is built from the host's.
pub const LaunchOptions = blk: {
    const info = @typeInfo(host.LaunchOptions).@"struct";
    var fields = info.fields[0..info.fields.len].*;
    for (&fields) |*field| {
        if (std.mem.eql(u8, field.name, "egress")) {
            const no_egress: ?host.launch.LaunchEgress = null;
            field.type = ?host.launch.LaunchEgress;
            field.default_value_ptr = &no_egress;
            field.alignment = @alignOf(?host.launch.LaunchEgress);
        }
    }
    break :blk @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = false,
    } });
};

/// The host's options for `options` with `egress` as the launch's egress.
fn hostLaunchOptions(options: LaunchOptions, egress: host.launch.LaunchEgress) host.LaunchOptions {
    var launch_options: host.LaunchOptions = undefined;
    inline for (@typeInfo(host.LaunchOptions).@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "egress")) {
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
/// result owns. On any failure the forked child is terminated and every
/// resource released; `error.WorkerCgroupDelegationUnavailable` means this
/// environment cannot place workers at all.
pub fn launchWorker(
    allocator: std.mem.Allocator,
    spawned: *zygote.host_client.SpawnedZygote,
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
    const launch_options = hostLaunchOptions(options, egress);

    const prepared_fd = try root.createWorkerDir(fork_job_id, .{
        .memory_limit_bytes = memory_limit_bytes,
    });
    var prepared_fd_owned = true;
    errdefer if (prepared_fd_owned) {
        std.posix.close(prepared_fd);
        root.removeWorkerDir(fork_job_id);
    };

    var forked = try zygote.host_client.requestForkWithJobId(spawned, fork_job_id, prepared_fd);
    forked.fork_job_id = fork_job_id;
    forked.cgroup_dir_fd = prepared_fd;
    prepared_fd_owned = false;
    errdefer host.terminateForkedWorkerBestEffort(&forked);

    const handle = try host.runToReady(allocator, spawned, &forked, memory_limit_bytes, launch_options);
    // The launch took every fd `forked` held, the cgroup leaf's included, so
    // only the struct is left to release.
    forked.deinit();
    return .{
        .allocator = allocator,
        .root = root,
        .wake_set = wake_set,
        .handle = handle,
    };
}

pub fn spawnZygote() !zygote.host_client.SpawnedZygote {
    return spawnZygoteWithOptions(.{});
}

pub fn spawnZygoteWithExitProbe(exit_probe_path: []const u8) !zygote.host_client.SpawnedZygote {
    return spawnZygoteWithOptions(.{ .postfork_exit_probe_path = exit_probe_path });
}

/// Spawns a zygote that runs the warmup corpus at boot, as the server's
/// always does (`server/boot/root.zig`); the other spawns here leave it off.
/// A corpus exception fails the zygote's boot, and with it every worker
/// launch on the node.
pub fn spawnZygoteWithWarmupCorpus() !zygote.host_client.SpawnedZygote {
    return spawnZygoteWithOptions(.{ .warmup_corpus = true });
}

fn spawnZygoteWithOptions(options: zygote.state.ZygoteOptions) !zygote.host_client.SpawnedZygote {
    var resolved_options = options;
    resolved_options.executable_path = process_options.collo_executable_path;
    return zygote.host_client.spawnZygote(resolved_options);
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
/// zygote, its workers and the host's launch all write to; the caller owns
/// the log. The read never blocks, so a test drains only after the events it
/// checks. A zygote without a trace pipe yields an empty log.
pub fn drainTrace(spawned: *const zygote.host_client.SpawnedZygote, allocator: std.mem.Allocator) !TraceLog {
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

// ---------------------------------------------------------------------------
// The host's end of `WorkerHandle.fs_fault_fd`, the wire `ipc.fs_fault`
// defines. The worker speaks first with an FsFaultRequest; these helpers
// receive it and answer with an FsFaultResponse, which on `.ok` carries one
// sealed memfd of the file's bytes over SCM_RIGHTS. In these tests the
// harness is the host; in the server, `server/ingress/runner/fs_fault_control.zig`
// meets the worker on the same wire.

/// Polls `fs_fault_fd` for up to `timeout_ms` and decodes one FsFaultRequest,
/// which the caller owns and frees with `deinit`. Fails with
/// `error.MissingFsFaultRequest` when none arrives in time and with
/// `error.UnexpectedFsFaultRequestFds` when descriptors ride along.
pub fn readFsFaultRequest(
    allocator: std.mem.Allocator,
    fs_fault_fd: std.posix.fd_t,
    timeout_ms: i32,
) !ipc.FsFaultRequest {
    var pollfds = [1]std.posix.pollfd{.{
        .fd = fs_fault_fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = try std.posix.poll(&pollfds, timeout_ms);
    if (ready == 0 or (pollfds[0].revents & std.posix.POLL.IN) == 0)
        return error.MissingFsFaultRequest;
    var scratch: [ipc.max_message_bytes]u8 = undefined;
    // `decodeRequest` copies the bytes it keeps, so the packet is freed here.
    var packet = try ipc.recvPacketWithFdsScratch(allocator, fs_fault_fd, &scratch);
    defer packet.deinit();
    if (packet.fd_count != 0)
        return error.UnexpectedFsFaultRequestFds;
    return try ipc.fs_fault.decodeRequest(allocator, packet.bytes);
}

/// Fails with `error.UnexpectedFsFaultRequest` when a request becomes
/// readable on `fs_fault_fd` within `timeout_ms`. Tests use it to show the
/// worker answered a read without asking the host.
pub fn expectNoFsFaultRequest(fs_fault_fd: std.posix.fd_t, timeout_ms: i32) !void {
    var pollfds = [1]std.posix.pollfd{.{
        .fd = fs_fault_fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = try std.posix.poll(&pollfds, timeout_ms);
    if (ready != 0 and (pollfds[0].revents & std.posix.POLL.IN) != 0)
        return error.UnexpectedFsFaultRequest;
}

/// Answers fault `fault_id` with `.ok` and a sealed memfd holding `bytes`,
/// the one descriptor an `.ok` response carries; the memfd is closed here
/// once sent.
pub fn respondFsFaultOk(fs_fault_fd: std.posix.fd_t, fault_id: u64, bytes: []const u8) !void {
    const memfd = try createSealedFsFaultMemfd(bytes);
    defer std.posix.close(memfd);
    try ipc.sendFsFaultResponse(
        fs_fault_fd,
        .{ .fault_id = fault_id, .status = .ok },
        fd_mod.FdRef.fromRaw(memfd),
    );
}

/// Answers fault `fault_id` with `status`, which must not be `.ok`; such a
/// response carries no descriptor.
pub fn respondFsFaultStatus(
    fs_fault_fd: std.posix.fd_t,
    fault_id: u64,
    status: ipc.FsFaultResponseStatus,
) !void {
    try ipc.sendFsFaultResponse(fs_fault_fd, .{ .fault_id = fault_id, .status = status }, null);
}

fn createSealedFsFaultMemfd(bytes: []const u8) !std.posix.fd_t {
    const fd = try std.posix.memfd_create(
        "collo-test-fs-fault-bytes",
        std.os.linux.MFD.CLOEXEC | std.os.linux.MFD.ALLOW_SEALING,
    );
    errdefer std.posix.close(fd);
    try fd_mod.writeAllRaw(fd, bytes);
    try std.posix.lseek_SET(fd, 0);
    try fd_mod.addSeals(fd, fd_mod.memfd_readonly_seals);
    return fd;
}

pub fn readFileAlloc(path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, 4096);
}

pub fn readUnsignedFile(path: []const u8) !u64 {
    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    var buffer: [64]u8 = undefined;
    const len = try file.readAll(&buffer);
    const trimmed = std.mem.trim(u8, buffer[0..len], &std.ascii.whitespace);
    return std.fmt.parseUnsigned(u64, trimmed, 10);
}

pub fn makeTempPath(allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "/tmp/{s}-{d}-{d}", .{
        prefix,
        std.c.getpid(),
        try process.monotonicNowNs(),
    });
}

pub fn cleanupTmpRoot(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch |err|
        std.log.warn("failed to remove zygote test tmp root {s}: {s}", .{ path, @errorName(err) });
}

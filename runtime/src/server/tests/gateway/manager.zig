//! The gateway manager (`server/gateway/manager.zig`): the security cell it derives from a worker
//! definition, a spawn that fails, and, against real gateways spawned from the installed binary,
//! the supervisor's hooks and the loss of a gateway. A spawn that fails leaves no gateway current
//! and reports no loss. An attach leaves only the worker's half of the new session open on the
//! server's side. Killing the gateway hangs up its control socket, which the manager's reader sees
//! as an error: the manager retires the gateway, so no generation is current and its key is gone,
//! and reports the loss once through `Deps.gatewayLost`. The next attach spawns a new gateway under
//! a new key, which a renewed lease then carries. A session whose worker gives it up is removed by
//! the gateway, which stays current, and its report reaches `Deps.sessionLost` with the gateway's
//! generation. The lease is covered in `lease.zig`, the control
//! client's failure tiers in `control_client.zig`, and the launcher's reattach of live workers in
//! `server/tests/supervisor/launcher.zig`. Lane: server-gateway.

const std = @import("std");
const ipc = @import("collo_ipc");
const gateway = @import("collo_server_gateway");
const launch = @import("collo_egress_gateway").launch;
const process_options = @import("collo_process_options");

const egress_token = ipc.egress_token;
const linux = std.os.linux;
const Manager = gateway.Manager;
const Lease = gateway.lease.Lease;

/// Waits for another thread's event in slices of `wait_slice_ns`, at most `wait_slices_max` of
/// them, so a manager that never reports fails the test instead of hanging it.
const wait_slice_ns: u64 = 100 * std.time.ns_per_ms;
const wait_slices_max: usize = 50;
/// Bounds the scan of `/proc`; the kernel's pid space holds at most 2^22 processes.
const proc_entries_max: usize = 1 << 22;
const probe_ok: u8 = 0;
const probe_missing: u8 = 1;

test "egress gateway security cell is the worker definition" {
    const first = gateway.manager.securityCellIdForDefinition("api");
    const same_definition = gateway.manager.securityCellIdForDefinition("api");
    const other_definition = gateway.manager.securityCellIdForDefinition("api-2");
    const prefix_definition = gateway.manager.securityCellIdForDefinition("ap");

    // Every worker of one definition lands in one cell, and no two
    // definitions share a cell.
    try std.testing.expectEqualSlices(u8, &first, &same_definition);
    try std.testing.expect(!std.mem.eql(u8, &first, &other_definition));
    try std.testing.expect(!std.mem.eql(u8, &first, &prefix_definition));
}

test "a gateway whose control channel fails is retired and the next attach spawns a new one (#41)" {
    if (try missingGatewayCapability()) |missing| {
        std.debug.print("skipped: {s}\n", .{missing});
        return error.SkipZigTest;
    }

    var losses: LossRecorder = .{};
    var manager: Manager = undefined;
    manager.init(std.testing.allocator, .{
        .executable_path = process_options.collo_executable_path,
    });
    defer manager.deinit();
    manager.setDeps(losses.deps());
    defer manager.clearDeps();

    try manager.prewarm();
    try std.testing.expectEqual(@as(u64, 1), manager.currentGeneration());
    var first_key: egress_token.Key = undefined;
    try std.testing.expect(manager.keyFor(1, &first_key));
    try std.testing.expect(!first_key.isZero());
    var other_key: egress_token.Key = undefined;
    try std.testing.expect(!manager.keyFor(2, &other_key));

    // The gateway's death hangs up its end of the control socket, which fails the reader.
    try std.posix.kill(try findGatewayPid(), std.posix.SIG.KILL);
    try std.testing.expectEqual(@as(?u64, 1), losses.waitFirst());
    try std.testing.expectEqual(@as(u64, 0), manager.currentGeneration());
    try std.testing.expect(!manager.keyFor(1, &other_key));
    // A boot token's end for the dead gateway has nowhere to go and fails nothing.
    manager.requestEnded(1, .{ .session_id = 1, .request_id = 0, .request_generation = 0 });

    // The next launch's attach spawns generation 2 under a key of its own.
    var wake_set = try ipc.egress_shared.WakeSet.create();
    defer wake_set.deinit();
    var attachment = try manager.attachWorker("app", &wake_set);
    defer attachment.deinit();
    try std.testing.expectEqual(@as(u64, 2), attachment.generation);
    try std.testing.expect(attachment.session_id != 0);
    try std.testing.expectEqual(@as(u64, 2), manager.currentGeneration());
    var second_key: egress_token.Key = undefined;
    try std.testing.expect(manager.keyFor(2, &second_key));
    try std.testing.expect(!std.mem.eql(u8, &first_key.bytes, &second_key.bytes));

    // A renewed lease carries the new gateway's generation and key and a descriptor of its live
    // control socket, on which the boot token's end of the new session goes out.
    const lease = try std.testing.allocator.create(Lease);
    defer std.testing.allocator.destroy(lease);
    lease.* = .{};
    defer lease.deinit();
    manager.renewLease(lease);
    try std.testing.expectEqual(@as(u64, 2), lease.generation);
    try std.testing.expectEqualSlices(u8, &second_key.bytes, &lease.key.bytes);
    try std.testing.expect(lease.control.isValid());
    lease.noteEnded(2, .{
        .session_id = attachment.session_id,
        .request_id = 0,
        .request_generation = 0,
    });
    lease.flush();
    try std.testing.expectEqual(@as(u64, 0), lease.ended_batches_dropped_full);
    try std.testing.expectEqual(@as(u64, 0), lease.ended_batches_dropped_closed);
    try std.testing.expectEqual(@as(usize, 1), losses.calls());
}

test "a session the worker gives up reaches Deps.sessionLost under its gateway's generation, and the gateway stays current" {
    if (try missingGatewayCapability()) |missing| {
        std.debug.print("skipped: {s}\n", .{missing});
        return error.SkipZigTest;
    }

    var losses: LossRecorder = .{};
    var manager: Manager = undefined;
    manager.init(std.testing.allocator, .{
        .executable_path = process_options.collo_executable_path,
    });
    defer manager.deinit();
    manager.setDeps(losses.deps());
    defer manager.clearDeps();

    var wake_set = try ipc.egress_shared.WakeSet.create();
    defer wake_set.deinit();
    var attachment = try manager.attachWorker("app", &wake_set);
    const session_id = attachment.session_id;
    // The worker's half holds the only write end of the pipe the gateway watches, so closing it
    // is what a worker that detached itself does: the gateway removes the session and reports it.
    attachment.deinit();

    const lost = losses.waitFirstSession() orelse return error.TestSessionLossNotReported;
    try std.testing.expectEqual(@as(u64, 1), lost[0]);
    try std.testing.expectEqual(session_id, lost[1]);
    try std.testing.expectEqual(@as(u64, 1), manager.currentGeneration());
    try std.testing.expectEqual(@as(usize, 1), losses.sessionCalls());
    try std.testing.expectEqual(@as(usize, 0), losses.calls());

    // The gateway still attaches; a later session of the same worker gets a new id.
    var next = try manager.attachWorker("app", &wake_set);
    defer next.deinit();
    try std.testing.expectEqual(@as(u64, 1), next.generation);
    try std.testing.expect(next.session_id != session_id);
}

test "a gateway that cannot be spawned leaves no gateway current and reports no loss" {
    var losses: LossRecorder = .{};
    var manager: Manager = undefined;
    manager.init(std.testing.allocator, .{ .executable_path = "/nonexistent/collo-egress-gateway" });
    defer manager.deinit();
    manager.setDeps(losses.deps());
    defer manager.clearDeps();

    try std.testing.expectError(error.FileNotFound, manager.prewarm());
    try std.testing.expectEqual(@as(u64, 0), manager.currentGeneration());
    var key: egress_token.Key = undefined;
    try std.testing.expect(!manager.keyFor(1, &key));

    // A launch's attach fails with the spawn's error and leaves the worker's wake set alone.
    var wake_set = try ipc.egress_shared.WakeSet.create();
    defer wake_set.deinit();
    try std.testing.expectError(error.FileNotFound, manager.attachWorker("app", &wake_set));
    try std.testing.expect(wake_set.isValid());

    const lease = try std.testing.allocator.create(Lease);
    defer std.testing.allocator.destroy(lease);
    lease.* = .{};
    defer lease.deinit();
    manager.renewLease(lease);
    try std.testing.expectEqual(@as(u64, 0), lease.generation);
    try std.testing.expect(!lease.control.isValid());
    try std.testing.expectEqual(@as(usize, 0), losses.calls());
}

test "the supervisor's hooks reach a live gateway, whose attach leaves only the worker's half open" {
    if (try missingGatewayCapability()) |missing| {
        std.debug.print("skipped: {s}\n", .{missing});
        return error.SkipZigTest;
    }

    var manager: Manager = undefined;
    manager.init(std.testing.allocator, .{
        .executable_path = process_options.collo_executable_path,
    });
    defer manager.deinit();

    try gateway.manager.prewarmCallback(&manager);
    try std.testing.expectEqual(@as(u64, 1), gateway.manager.currentGenerationCallback(&manager));
    var key: egress_token.Key = undefined;
    try std.testing.expect(gateway.manager.keyForCallback(&manager, 1, &key));
    try std.testing.expect(!key.isZero());
    // A second prewarm keeps the current gateway.
    try gateway.manager.prewarmCallback(&manager);
    try std.testing.expectEqual(@as(u64, 1), manager.currentGeneration());

    // A lease renewed while its gateway stays current keeps its descriptor.
    const lease = try std.testing.allocator.create(Lease);
    defer std.testing.allocator.destroy(lease);
    lease.* = .{};
    defer lease.deinit();
    manager.renewLease(lease);
    const held_fd = lease.control.fd();
    manager.renewLease(lease);
    try std.testing.expectEqual(held_fd, lease.control.fd());

    var wake_set = try ipc.egress_shared.WakeSet.create();
    defer wake_set.deinit();
    const open_before = try openFdCount();
    var attachment = try gateway.manager.attachWorkerCallback(&manager, "app", &wake_set);
    try std.testing.expect(attachment.isValid());
    try std.testing.expectEqual(@as(u64, 1), attachment.generation);
    // The gateway's half and the session's other descriptors closed once the gateway acknowledged.
    const worker_half_fd_count = ipc.egress_shared.region_fd_count + ipc.egress_shared.wake_fd_count;
    try std.testing.expectEqual(open_before + worker_half_fd_count, try openFdCount());
    gateway.manager.bootEndedCallback(&manager, 1, attachment.session_id);
    attachment.deinit();
    try std.testing.expectEqual(open_before, try openFdCount());
    try std.testing.expectEqual(@as(u64, 1), manager.currentGeneration());
}

/// Records `Deps.gatewayLost` and `Deps.sessionLost`, which a control reader thread calls with no
/// manager lock held.
const LossRecorder = struct {
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    count: usize = 0,
    first: ?u64 = null,
    /// The first session reported lost, as its gateway's generation and its id.
    first_session: ?[2]u64 = null,
    session_count: usize = 0,

    fn deps(self: *LossRecorder) gateway.manager.Deps {
        return .{ .ctx = self, .gatewayLost = gatewayLost, .sessionLost = sessionLost };
    }

    fn sessionLost(ctx: *anyopaque, generation: u64, session_id: u64) void {
        const self: *LossRecorder = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.first_session == null)
            self.first_session = .{ generation, session_id };
        self.session_count += 1;
        self.condition.broadcast();
    }

    /// Waits for the first session loss and returns it, or null when none came.
    fn waitFirstSession(self: *LossRecorder) ?[2]u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (0..wait_slices_max) |_| {
            if (self.first_session) |session|
                return session;
            self.condition.timedWait(&self.mutex, wait_slice_ns) catch |err| switch (err) {
                error.Timeout => {},
            };
        }
        return self.first_session;
    }

    fn sessionCalls(self: *LossRecorder) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.session_count;
    }

    fn gatewayLost(ctx: *anyopaque, generation: u64) void {
        const self: *LossRecorder = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.first == null)
            self.first = generation;
        self.count += 1;
        self.condition.broadcast();
    }

    /// Waits for the first loss and returns its generation, or null when none came.
    fn waitFirst(self: *LossRecorder) ?u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (0..wait_slices_max) |_| {
            if (self.first) |generation|
                return generation;
            self.condition.timedWait(&self.mutex, wait_slice_ns) catch |err| switch (err) {
                error.Timeout => {},
            };
        }
        return self.first;
    }

    fn calls(self: *LossRecorder) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.count;
    }
};

/// The pid of this process's one live child that runs as the gateway (`launch.process_name`),
/// found through procfs, since the manager keeps its gateway process to itself.
fn findGatewayPid() !std.posix.pid_t {
    const own_pid = linux.getpid();
    var proc = try std.fs.openDirAbsolute("/proc", .{ .iterate = true });
    defer proc.close();
    var iterator = proc.iterate();
    var found: ?std.posix.pid_t = null;
    for (0..proc_entries_max) |_| {
        const entry = (try iterator.next()) orelse
            return found orelse error.TestGatewayProcessNotFound;
        const pid = std.fmt.parseInt(std.posix.pid_t, entry.name, 10) catch continue;
        if (!isLiveGatewayChild(proc, entry.name, own_pid))
            continue;
        if (found != null)
            return error.TestSeveralGatewayProcesses;
        found = pid;
    }
    return error.TestProcScanUnbounded;
}

/// Whether `/proc/<name>` is a child of `own_pid` that has not exited and whose arg0 is the
/// gateway's. A process that exits during the scan reads as no match.
fn isLiveGatewayChild(proc: std.fs.Dir, name: []const u8, own_pid: std.posix.pid_t) bool {
    var path_buffer: [64]u8 = undefined;
    var stat_buffer: [1024]u8 = undefined;
    const stat_path = std.fmt.bufPrint(&path_buffer, "{s}/stat", .{name}) catch return false;
    const stat = proc.readFile(stat_path, &stat_buffer) catch return false;
    // The command name in parentheses may hold spaces, so the fields start after the last one.
    const name_end = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return false;
    var fields = std.mem.tokenizeScalar(u8, stat[name_end + 1 ..], ' ');
    const state = fields.next() orelse return false;
    if (state[0] == 'Z' or state[0] == 'X')
        return false;
    const ppid_text = fields.next() orelse return false;
    const ppid = std.fmt.parseInt(std.posix.pid_t, ppid_text, 10) catch return false;
    if (ppid != own_pid)
        return false;

    var cmdline_buffer: [256]u8 = undefined;
    const cmdline_path = std.fmt.bufPrint(&path_buffer, "{s}/cmdline", .{name}) catch return false;
    const cmdline = proc.readFile(cmdline_path, &cmdline_buffer) catch return false;
    const arg0_end = std.mem.indexOfScalar(u8, cmdline, 0) orelse cmdline.len;
    return std.mem.eql(u8, cmdline[0..arg0_end], launch.process_name);
}

/// What this host lacks to boot a sandboxed gateway, or null when it has it all. The gateway's
/// sandbox (`egress/gateway/sandbox.zig`) enters unprivileged user and mount namespaces and
/// installs a seccomp filter; each probe tries the same in a forked child with raw system calls,
/// so a defect in the sandbox cannot make a capable host look incapable.
fn missingGatewayCapability() !?[]const u8 {
    if (try probeExit(probeUserAndMountNamespaces) != probe_ok)
        return "no unprivileged user and mount namespaces on this host";
    if (try probeExit(probeSeccomp) != probe_ok)
        return "no seccomp filters for this process";
    return null;
}

fn probeExit(probe: fn () u8) !u8 {
    const pid = try std.posix.fork();
    if (pid == 0)
        linux.exit_group(probe());
    const wait = std.posix.waitpid(pid, 0);
    try std.testing.expect(std.c.W.IFEXITED(wait.status));
    return @intCast(std.c.W.EXITSTATUS(wait.status));
}

fn probeUserAndMountNamespaces() u8 {
    const uid = linux.getuid();
    const gid = linux.getgid();
    if (linux.E.init(linux.unshare(linux.CLONE.NEWUSER)) != .SUCCESS)
        return probe_missing;
    if (!writeProcFile("/proc/self/setgroups", "deny\n"))
        return probe_missing;
    var map_buffer: [64]u8 = undefined;
    const uid_map = std.fmt.bufPrint(&map_buffer, "0 {d} 1\n", .{uid}) catch return probe_missing;
    if (!writeProcFile("/proc/self/uid_map", uid_map))
        return probe_missing;
    const gid_map = std.fmt.bufPrint(&map_buffer, "0 {d} 1\n", .{gid}) catch return probe_missing;
    if (!writeProcFile("/proc/self/gid_map", gid_map))
        return probe_missing;
    if (linux.E.init(linux.unshare(linux.CLONE.NEWNS)) != .SUCCESS)
        return probe_missing;
    if (linux.E.init(linux.mount(null, "/", null, linux.MS.PRIVATE | linux.MS.REC, 0)) != .SUCCESS)
        return probe_missing;
    return probe_ok;
}

/// A filter that allows everything, installed after no-new-privileges as the gateway does.
fn probeSeccomp() u8 {
    if (linux.E.init(linux.prctl(@intFromEnum(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0)) != .SUCCESS)
        return probe_missing;
    const Instruction = extern struct { code: u16, jt: u8, jf: u8, k: u32 };
    const Program = extern struct { len: u16, filter: [*]const Instruction };
    const bpf_ret_k: u16 = 0x06;
    const allow_all = [_]Instruction{.{ .code = bpf_ret_k, .jt = 0, .jf = 0, .k = linux.SECCOMP.RET.ALLOW }};
    const program: Program = .{ .len = allow_all.len, .filter = &allow_all };
    if (linux.E.init(linux.seccomp(linux.SECCOMP.SET_MODE_FILTER, 0, &program)) != .SUCCESS)
        return probe_missing;
    return probe_ok;
}

fn writeProcFile(path: [:0]const u8, bytes: []const u8) bool {
    const rc = linux.open(path, .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
    if (linux.E.init(rc) != .SUCCESS)
        return false;
    const fd: std.posix.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    return linux.write(fd, bytes.ptr, bytes.len) == bytes.len;
}

/// Open descriptors of this process, counted from `/proc/self/fd` without the one the count
/// itself opens.
fn openFdCount() !usize {
    var dir = try std.fs.openDirAbsolute("/proc/self/fd", .{ .iterate = true });
    defer dir.close();
    var count: usize = 0;
    var iterator = dir.iterate();
    while (try iterator.next()) |_|
        count += 1;
    return count - 1;
}

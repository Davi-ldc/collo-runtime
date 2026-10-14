//! The launch machine without a zygote: the local steps `prepare` runs before
//! the fork reply and the WorkerInit `start` sends at it, attached with its
//! session and boot token, detached with the worker's wake descriptors alone
//! or without any egress descriptor for a definition with no grant, with the
//! definition's realm mode, time limits and artifact and the leaf as its one
//! directory; a leaf whose limits the launch never reads back; no copy of the
//! boot token's key in the machine; a local step out of descriptors and a
//! fork reply without the child's descriptors, both reported by `start`; a
//! send that finds the child gone, reported as the child's exit; the ready
//! wait's outcomes and the cause it records for a child whose init failed
//! (`InitFailure`); what `takeHandle` and `abandon` hand over, the page with
//! what the child logged included; and `AbandonedChild.reap` on a real child
//! process. Plain directories under a temp dir stand in for the cgroup
//! leaves, and socket pairs exercise the real typed WorkerInit sender and
//! WorkerReady receiver; sandbox and zygote behavior remain in the
//! integration lane. Lane `host-test`.

const std = @import("std");
const ipc = @import("collo_ipc");
const fd_mod = @import("collo_os").fd;
const process = @import("collo_os").process;
const os_linux = @import("collo_os").linux;
const process_limits = @import("collo_limits").process;
const host = @import("collo_host");
const zygote = @import("collo_zygote");
const worker_shared_page = @import("collo_worker_state").page;

const launch = host.launch;
const Machine = launch.Machine;
const LaunchPhase = launch.LaunchPhase;

const memory_limit_bytes: u64 = 64 * 1024 * 1024;
const child_window_ns: u64 = @as(u64, @intCast(process_limits.WORKER_INIT_TIMEOUT_MS)) * std.time.ns_per_ms;

/// A machine posed mid-boot with no leaf, child or descriptor: every fd stays
/// -1, so a mistaken use fails loudly rather than touching an unrelated
/// descriptor.
fn posed(phase: LaunchPhase) Machine {
    return .{
        .trace_fd = null,
        .leaf = null,
        .leaf_fd = -1,
        .phase = phase,
    };
}

fn expectClosed(fd: std.posix.fd_t) !void {
    const rc = std.os.linux.fcntl(fd, std.posix.F.GETFD, 0);
    try std.testing.expectEqual(std.posix.E.BADF, os_linux.syscallErrno(rc));
}

fn expectOpen(fd: std.posix.fd_t) !void {
    const rc = std.os.linux.fcntl(fd, std.posix.F.GETFD, 0);
    try std.testing.expectEqual(std.posix.E.SUCCESS, os_linux.syscallErrno(rc));
}

fn eventFd() !std.posix.fd_t {
    return std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC);
}

/// The file behind `fd`, by device and inode: both ends of a pipe share it,
/// and every memfd and directory has its own.
fn fileIdentity(fd: std.posix.fd_t) ![2]u64 {
    const stat = try std.posix.fstat(fd);
    return .{ @intCast(stat.dev), @intCast(stat.ino) };
}

fn isDirectory(fd: std.posix.fd_t) !bool {
    const stat = try std.posix.fstat(fd);
    return (stat.mode & std.os.linux.S.IFMT) == std.os.linux.S.IFDIR;
}

/// Whether the pipe end `fd` reports a hang-up: no write end is left.
fn hungUp(fd: std.posix.fd_t) !bool {
    var pollfds = [1]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    _ = try std.posix.poll(&pollfds, 0);
    return (pollfds[0].revents & std.posix.POLL.HUP) != 0;
}

/// Whether anything waits to be read on `fd`.
fn readable(fd: std.posix.fd_t) !bool {
    var pollfds = [1]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    return try std.posix.poll(&pollfds, 0) != 0;
}

/// Whether a wake through `writer` reaches `reader`: two descriptors of one
/// eventfd, since every eventfd shares one anonymous inode and fstat cannot
/// tell them apart.
fn sameEventFd(writer: std.posix.fd_t, reader: std.posix.fd_t) !bool {
    ipc.egress_shared.notify(writer);
    var value: u64 = 0;
    _ = std.posix.read(reader, std.mem.asBytes(&value)) catch |err| switch (err) {
        error.WouldBlock => return false,
        else => return err,
    };
    return value == 1;
}

/// Collects a child the test forked when the test ends before `reap` killed
/// it, so it never outlives the run as a zombie.
fn killAndCollect(pid: std.posix.pid_t) void {
    std.posix.kill(pid, std.posix.SIG.KILL) catch |err| switch (err) {
        error.ProcessNotFound => {},
        else => std.log.warn("failed to kill the test's child pid={d}: {s}", .{ pid, @errorName(err) }),
    };
    _ = std.posix.waitpid(pid, 0);
}

/// The directory `worker-<job_id>` under `parent`, made and opened as the
/// launcher's leaf would be, minus cgroupfs: it holds none of a leaf's files.
fn makeLeaf(parent: std.fs.Dir, job_id: u64) !std.posix.fd_t {
    var name_buffer: [host.WorkerLeaf.name_bytes_max]u8 = undefined;
    const leaf: host.WorkerLeaf = .{ .workers_dir_fd = parent.fd, .job_id = job_id };
    const name = leaf.name(&name_buffer);
    try parent.makeDir(name);
    return std.posix.openat(parent.fd, name, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
}

/// The key every boot token in these tests is minted under, and what the
/// tokens carry besides their deadline.
const boot_key: ipc.egress_token.Key = .{ .bytes = @splat(0x5a) };
const boot_egress: launch.BootEgress = .{
    .key = boot_key,
    .session_id = 41,
    .policy_id = 0,
};

/// Whether a launch sends a session, the worker's wake descriptors alone, or
/// no egress descriptor at all.
const Egress = enum { none, detached, attached };

/// A launch through `prepare` and `start` without a zygote. A plain
/// directory under the fixture's temp dir stands in for the leaf, an eventfd
/// for the child's pidfd and another for the definition's artifact, since
/// the receiver only counts descriptors, and `pair[1]` is the child's end of
/// its init socket. Initialized in place, since a detached launch points at
/// `wake_set`.
const InitSend = struct {
    tmp: std.testing.TmpDir,
    pair: [2]std.posix.fd_t,
    artifact_fd: std.posix.fd_t,
    wake_set: ipc.egress_shared.WakeSet,
    session: ipc.egress_shared.SessionFds,
    machine: Machine,
    options: launch.LaunchOptions,

    const job_id: u64 = 7;

    /// The wake set and a session on it exist either way; `egress` decides
    /// whether the launch sends the session's half and its boot token, the
    /// wake descriptors alone, or nothing.
    fn init(self: *InitSend, egress: Egress) !void {
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
        errdefer closePair(self.pair);
        self.artifact_fd = try eventFd();
        errdefer std.posix.close(self.artifact_fd);
        self.wake_set = try ipc.egress_shared.WakeSet.create();
        errdefer self.wake_set.deinit();
        self.session = try ipc.egress_shared.createSessionForWorker(&self.wake_set);
        errdefer self.session.deinit();
        const leaf_fd = try makeLeaf(self.tmp.dir, job_id);
        self.machine = Machine.init(.{ .workers_dir_fd = self.tmp.dir.fd, .job_id = job_id }, leaf_fd, null);
        self.options = .{
            .memory_limit_bytes = memory_limit_bytes,
            .egress = switch (egress) {
                .none => .none,
                .detached => .{ .detached = &self.wake_set },
                .attached => .{ .attached = .{ .shared_fds = self.session.rawForWorker(), .boot = boot_egress } },
            },
            .routes = .{ .module_pack_fd = self.artifact_fd, .isolate_realm = false },
        };
    }

    /// Takes the stand-in child as a fork reply would deliver it: a copy of
    /// the host's end of the init socket and a stand-in pidfd.
    fn start(self: *InitSend) launch.LaunchError!void {
        var forked = zygote.host_client.ForkedWorker{
            .pid = 0,
            .worker_init_fd = std.posix.dup(self.pair[0]) catch return error.LaunchResourcesUnavailable,
            .pidfd = eventFd() catch return error.LaunchResourcesUnavailable,
            .fork_job_id = job_id,
        };
        return self.machine.start(&forked, &self.options);
    }

    /// `prepare`, then `start`, as the launcher runs them around a fork.
    fn send(self: *InitSend) !void {
        self.machine.prepare();
        try self.start();
    }

    /// The leaf's directory, opened again by name.
    fn openLeaf(self: *InitSend) !std.posix.fd_t {
        return std.posix.openat(self.tmp.dir.fd, "worker-7", .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    }

    fn deinit(self: *InitSend) void {
        // Never reaped: the stand-in pidfd names no process, and the temp
        // dir's cleanup removes the leaf.
        var child = self.machine.abandon();
        child.pidfd.deinit();
        if (child.page) |*page|
            page.deinit();
        self.session.deinit();
        self.wake_set.deinit();
        std.posix.close(self.artifact_fd);
        closePair(self.pair);
        self.tmp.cleanup();
    }

    fn closePair(pair: [2]std.posix.fd_t) void {
        std.posix.close(pair[0]);
        std.posix.close(pair[1]);
    }
};

test "a launch tells the child its routes' realm mode and sends the definition's artifact" {
    for ([_]bool{ false, true }) |isolate_realm| {
        var send: InitSend = undefined;
        try send.init(.attached);
        defer send.deinit();
        send.options.routes.isolate_realm = isolate_realm;

        try send.send();
        try std.testing.expectEqual(LaunchPhase.awaiting_ready, send.machine.phase);

        var received = try ipc.zygote_worker.recvWorkerInit(send.pair[1]);
        defer received.deinit();
        try received.message.validate();
        try std.testing.expectEqual(isolate_realm, received.message.isolatesRealms());
        try std.testing.expect(!received.message.recordsBenchHandler());
        try std.testing.expectEqual(try fileIdentity(send.artifact_fd), try fileIdentity(received.module_pack_fd));
    }
}

test "a launch for the cold-start benchmark asks the worker to stamp its first handler call" {
    var send: InitSend = undefined;
    try send.init(.none);
    defer send.deinit();
    send.options.bench_handler = true;

    try send.send();

    var received = try ipc.zygote_worker.recvWorkerInit(send.pair[1]);
    defer received.deinit();
    try received.message.validate();
    try std.testing.expect(received.message.recordsBenchHandler());
}

test "each launch's WorkerInit carries its own leaf as its one directory, which nothing on the host read: an empty directory without cgroupfs's files launches" {
    // Two launches of one host, each with a leaf that holds none of the
    // files a read-back would open, and no host directory besides.
    for (0..2) |_| {
        var send: InitSend = undefined;
        try send.init(.none);
        defer send.deinit();

        try send.send();

        var received = try ipc.zygote_worker.recvWorkerInit(send.pair[1]);
        defer received.deinit();
        try received.message.validate();
        const leaf_fd = try send.openLeaf();
        defer std.posix.close(leaf_fd);
        try std.testing.expectEqual(try fileIdentity(leaf_fd), try fileIdentity(received.cgroup_dir_fd));
        const others = [_]std.posix.fd_t{
            received.metrics_fd,
            received.completion_eventfd,
            received.ingress_payload_fd,
            received.ingress_payload_credit_eventfd,
            received.module_pack_fd,
        };
        for (others) |fd|
            try std.testing.expect(!try isDirectory(fd));
        try std.testing.expect(received.egress_shared_fds.isEmpty());
    }
}

test "the local steps run before the fork reply, WorkerInit sent at the reply carries what they made, and the child window starts at the send" {
    var send: InitSend = undefined;
    try send.init(.none);
    defer send.deinit();

    // The launcher runs these while the zygote clones, before any child is
    // in hand.
    send.machine.prepare();
    try std.testing.expectEqual(LaunchPhase.preparing, send.machine.phase);
    const page_identity = try fileIdentity(send.machine.metrics_fd);
    const payload_identity = try fileIdentity(send.machine.ingress_payload_fd);
    const reply_ns = process.monotonicNowNsOrZero();
    try send.start();

    var received = try ipc.zygote_worker.recvWorkerInit(send.pair[1]);
    defer received.deinit();
    try received.message.validate();
    try std.testing.expectEqual(page_identity, try fileIdentity(received.metrics_fd));
    try std.testing.expectEqual(payload_identity, try fileIdentity(received.ingress_payload_fd));
    try std.testing.expect(received.message.init_deadline_mono_ns >= reply_ns + child_window_ns);
    try std.testing.expectEqual(received.message.init_deadline_mono_ns, send.machine.child_init_deadline_abs_ns);
    // The child holds its own copies, so the host's copies of the leaf and
    // of both memfds closed with the send; the mappings stay.
    try std.testing.expectEqual(@as(std.posix.fd_t, -1), send.machine.leaf_fd);
    try std.testing.expectEqual(@as(std.posix.fd_t, -1), send.machine.metrics_fd);
    try std.testing.expectEqual(@as(std.posix.fd_t, -1), send.machine.ingress_payload_fd);
    try std.testing.expect(send.machine.metrics != null);
    try std.testing.expect(send.machine.ingress_payload != null);
}

test "an attached launch sends the session's half beside a boot token whose deadline adds the evaluation budget to the child window" {
    var send: InitSend = undefined;
    try send.init(.attached);
    defer send.deinit();

    try send.send();

    var received = try ipc.zygote_worker.recvWorkerInit(send.pair[1]);
    defer received.deinit();
    try received.message.validate();
    var half = received.takeEgressSharedFds();
    defer half.close();
    try std.testing.expect(half.isValid());
    try std.testing.expectEqual(
        try fileIdentity(send.session.rawForWorker().command_data_fd),
        try fileIdentity(half.command_data_fd),
    );

    const token = ipc.egress_token.fromBytes(&received.message.boot_egress_token);
    const fields = try ipc.egress_token.verify(&boot_key, &token);
    try std.testing.expectEqual(ipc.egress_token.Kind.boot, fields.kind);
    try std.testing.expectEqual(boot_egress.session_id, fields.session_id);
    try std.testing.expectEqual(boot_egress.policy_id, fields.policy_id);
    try std.testing.expectEqual(@as(u64, 0), fields.request_id);
    try std.testing.expectEqual(@as(u64, 0), fields.request_generation);
    const deadline = received.message.init_deadline_mono_ns + process_limits.MODULE_EVAL_BUDGET_NS;
    try std.testing.expectEqual(deadline, fields.deadline_monotonic_ns);
    // The launcher reads the deadline here for the worker's record.
    try std.testing.expectEqual(deadline, send.machine.boot_egress_deadline_abs_ns);
}

test "the boot token's deadline adds the evaluation budget to the init deadline and saturates" {
    try std.testing.expectEqual(3 + process_limits.MODULE_EVAL_BUDGET_NS, launch.bootEgressDeadline(3));
    try std.testing.expectEqual(std.math.maxInt(u64), launch.bootEgressDeadline(std.math.maxInt(u64)));
}

test "a launch for a definition without a network grant sends no egress descriptor and leaves flag_egress clear" {
    var send: InitSend = undefined;
    try send.init(.none);
    defer send.deinit();

    try send.send();

    var received = try ipc.zygote_worker.recvWorkerInit(send.pair[1]);
    defer received.deinit();
    try received.message.validate();
    try std.testing.expect(!received.message.hasEgress());
    try std.testing.expect(ipc.egress_token.isNone(&received.message.boot_egress_token));
    try std.testing.expect(received.egress_shared_fds.isEmpty());
    try std.testing.expectEqual(@as(u64, 0), send.machine.boot_egress_deadline_abs_ns);
}

test "a launch sends the definition's request CPU budget and its limit on JavaScript no request owns" {
    var send: InitSend = undefined;
    try send.init(.attached);
    defer send.deinit();
    send.options.request_cpu_budget_ns = 50 * std.time.ns_per_ms;
    send.options.unowned_time_limit_ns = 1 * std.time.ns_per_s;

    try send.send();

    var received = try ipc.zygote_worker.recvWorkerInit(send.pair[1]);
    defer received.deinit();
    try received.message.validate();
    try std.testing.expectEqual(@as(u64, 50 * std.time.ns_per_ms), received.message.request_cpu_budget_ns);
    try std.testing.expectEqual(@as(u64, 1 * std.time.ns_per_s), received.message.unowned_time_limit_ns);
    try std.testing.expectEqual(memory_limit_bytes, received.message.memory_limit_bytes);
}

test "a detached launch carries the wake set and no regions" {
    var send: InitSend = undefined;
    try send.init(.detached);
    defer send.deinit();

    try send.send();

    var received = try ipc.zygote_worker.recvWorkerInit(send.pair[1]);
    defer received.deinit();
    try received.message.validate();
    try std.testing.expect(ipc.egress_token.isNone(&received.message.boot_egress_token));
    var wake = received.takeEgressSharedFds();
    defer wake.close();
    try std.testing.expectEqual(@as(usize, 0), wake.regionCount());
    try std.testing.expect(wake.wakeFds().isValid());
    try std.testing.expectEqual(try fileIdentity(send.wake_set.liveness_read.fd()), try fileIdentity(wake.liveness_fd));
    try std.testing.expectEqual(try fileIdentity(send.wake_set.peer_liveness_read.fd()), try fileIdentity(wake.peer_liveness_fd));
    try std.testing.expect(try sameEventFd(wake.completion_eventfd, send.wake_set.completion_event.fd()));
    try std.testing.expect(try sameEventFd(wake.command_eventfd, send.wake_set.command_event.fd()));

    // The launch kept no copy of the write end the worker got, so once the
    // fixture's unsent session lets go of its own, the pipe the gateways
    // watch hangs up when the worker's end closes.
    send.session.deinit();
    try std.testing.expect(!try hungUp(send.wake_set.peer_liveness_read.fd()));
    std.posix.close(wake.peer_liveness_fd);
    wake.peer_liveness_fd = -1;
    try std.testing.expect(try hungUp(send.wake_set.peer_liveness_read.fd()));
}

test "a session built for a reattach shares the boot wake descriptors and has new regions" {
    var send: InitSend = undefined;
    try send.init(.attached);
    defer send.deinit();

    try send.send();

    var received = try ipc.zygote_worker.recvWorkerInit(send.pair[1]);
    defer received.deinit();
    const boot_half = received.egress_shared_fds;
    try std.testing.expect(boot_half.isValid());

    var reattach = try ipc.egress_shared.createSessionForWorker(&send.wake_set);
    defer reattach.deinit();
    // The new gateway's copy of its end of the pipe the worker watches,
    // which it holds once it acknowledged the attach.
    const gateway_liveness = try std.posix.dup(reattach.rawForGateway().liveness_fd);
    var reattach_half = reattach.takeWorkerHalf();
    defer reattach_half.close();

    try std.testing.expectEqual(try fileIdentity(boot_half.liveness_fd), try fileIdentity(reattach_half.liveness_fd));
    try std.testing.expectEqual(try fileIdentity(boot_half.peer_liveness_fd), try fileIdentity(reattach_half.peer_liveness_fd));
    try std.testing.expect(try sameEventFd(reattach_half.completion_eventfd, boot_half.completion_eventfd));
    try std.testing.expect(try sameEventFd(reattach_half.command_eventfd, boot_half.command_eventfd));
    try std.testing.expect(!std.meta.eql(
        try fileIdentity(boot_half.command_data_fd),
        try fileIdentity(reattach_half.command_data_fd),
    ));
    try std.testing.expect(!std.meta.eql(
        try fileIdentity(boot_half.upload_pool_control_fd),
        try fileIdentity(reattach_half.upload_pool_control_fd),
    ));

    // With the launch's session gone, the new gateway alone keeps the
    // worker's liveness end from hanging up, and its death hangs it up.
    send.session.deinit();
    try std.testing.expect(!try hungUp(boot_half.liveness_fd));
    std.posix.close(gateway_liveness);
    try std.testing.expect(try hungUp(boot_half.liveness_fd));
}

test "a local step that runs out of descriptors fails the launch's resources, start reports it with the child in hand and sends no WorkerInit, and abandon closes what the steps made" {
    var send: InitSend = undefined;
    try send.init(.none);
    defer send.deinit();

    // The page's memfd and the completion eventfd take the two lowest free
    // descriptors, and a soft limit just above them refuses the payload
    // ring's memfd with EMFILE. The limit is process-wide, so it is put back
    // before the test opens anything else.
    const first_free = try eventFd();
    const second_free = try eventFd();
    std.posix.close(first_free);
    std.posix.close(second_free);
    const previous_limit = try std.posix.getrlimit(.NOFILE);
    try std.posix.setrlimit(.NOFILE, .{ .cur = @intCast(second_free + 1), .max = previous_limit.max });
    send.machine.prepare();
    // Back to a soft limit the hard limit already allowed, which cannot fail.
    std.posix.setrlimit(.NOFILE, previous_limit) catch unreachable;

    try std.testing.expectEqual(LaunchPhase.failed, send.machine.phase);
    try std.testing.expectEqual(@as(?launch.LaunchError, error.LaunchResourcesUnavailable), send.machine.fail_reason);
    try std.testing.expectEqual(first_free, send.machine.metrics_fd);
    try std.testing.expectEqual(second_free, send.machine.completion_eventfd);
    try std.testing.expectEqual(@as(std.posix.fd_t, -1), send.machine.ingress_payload_fd);
    try std.testing.expect(send.machine.metrics == null);

    var forked = zygote.host_client.ForkedWorker{
        .pid = 4242,
        .worker_init_fd = try std.posix.dup(send.pair[0]),
        .pidfd = try eventFd(),
        .fork_job_id = InitSend.job_id,
    };
    const pidfd = forked.pidfd.?;
    try std.testing.expectError(error.LaunchResourcesUnavailable, send.machine.start(&forked, &send.options));
    // The machine took the child, so its abandonment hands it to the reaper.
    try std.testing.expect(forked.worker_init_fd == null);
    try std.testing.expect(forked.pidfd == null);
    try std.testing.expectEqual(pidfd, send.machine.pidfd);
    try std.testing.expect(!try readable(send.pair[1]));

    var child = send.machine.abandon();
    defer child.pidfd.deinit();
    try std.testing.expectEqual(pidfd, child.pidfd.fd());
    try std.testing.expect(child.page == null);
    try expectClosed(first_free);
    try expectClosed(second_free);
}

test "a WorkerInit send that finds the child's end of the init socket closed fails the launch as the child's exit, for the cause its leaf names" {
    var send: InitSend = undefined;
    try send.init(.none);
    defer send.deinit();
    send.machine.prepare();
    // The kernel's OOM kill counted in the leaf, which a child killed before
    // WorkerInit reached it leaves.
    try send.tmp.dir.writeFile(.{
        .sub_path = "worker-7/memory.events.local",
        .data = "low 0\nhigh 0\nmax 1\noom 1\noom_kill 1\n",
    });
    // The child holds its end of the init socket until it exits, and the
    // zygote closed its own copy after the clone.
    const pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    std.posix.close(pair[1]);
    var forked = zygote.host_client.ForkedWorker{
        .pid = 4242,
        .worker_init_fd = pair[0],
        .pidfd = try eventFd(),
        .fork_job_id = InitSend.job_id,
    };

    try std.testing.expectError(error.WorkerInitFailed, send.machine.start(&forked, &send.options));
    try std.testing.expectEqual(@as(?launch.LaunchError, error.WorkerInitFailed), send.machine.fail_reason);
    try std.testing.expectEqual(@as(?launch.InitFailure, .memory), send.machine.init_failure);
    try std.testing.expectEqual(LaunchPhase.failed, send.machine.phase);
}

test "a launch keeps no copy of its boot token's key, neither once WorkerInit went out nor in what it leaves when abandoned" {
    var send: InitSend = undefined;
    try send.init(.attached);
    defer send.deinit();

    try send.send();
    var received = try ipc.zygote_worker.recvWorkerInit(send.pair[1]);
    defer received.deinit();
    // The token went out, minted under the key.
    const token = ipc.egress_token.fromBytes(&received.message.boot_egress_token);
    _ = try ipc.egress_token.verify(&boot_key, &token);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.asBytes(&send.machine), &boot_key.bytes) == null);

    var child = send.machine.abandon();
    defer child.pidfd.deinit();
    defer if (child.page) |*page| page.deinit();
    try std.testing.expect(std.mem.indexOf(u8, std.mem.asBytes(&child), &boot_key.bytes) == null);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.asBytes(&send.machine), &boot_key.bytes) == null);
}

test "a fork reply without the child's init socket fails start as a broken protocol and empties the forked worker" {
    var send: InitSend = undefined;
    try send.init(.none);
    defer send.deinit();
    send.machine.prepare();

    var forked = zygote.host_client.ForkedWorker{
        .pid = 0,
        .worker_init_fd = null,
        .pidfd = try eventFd(),
        .fork_job_id = InitSend.job_id,
    };
    try std.testing.expectError(error.ZygoteProtocol, send.machine.start(&forked, &send.options));
    try std.testing.expectEqual(@as(?launch.LaunchError, error.ZygoteProtocol), send.machine.fail_reason);
    try std.testing.expectEqual(LaunchPhase.failed, send.machine.phase);
    try std.testing.expect(forked.pidfd == null);
    try std.testing.expect(!try readable(send.pair[1]));
}

test "abandon hands back the pidfd, the leaf and the page, and releases everything else" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const leaf: host.WorkerLeaf = .{ .workers_dir_fd = tmp.dir.fd, .job_id = 5 };
    const leaf_fd = try makeLeaf(tmp.dir, 5);
    var machine = Machine.init(leaf, leaf_fd, null);
    machine.prepare();
    // A child taken from a fork reply, before WorkerInit went out.
    machine.pid = 4242;
    machine.pidfd = try eventFd();
    machine.worker_init_fd = try eventFd();
    const released = [_]std.posix.fd_t{
        machine.worker_init_fd,
        machine.leaf_fd,
        machine.metrics_fd,
        machine.completion_eventfd,
        machine.ingress_payload_fd,
        machine.ingress_payload_credit_eventfd,
    };
    const pidfd = machine.pidfd;

    var child = machine.abandon();
    defer child.pidfd.deinit();
    defer if (child.page) |*page| page.deinit();

    try std.testing.expectEqual(@as(u32, 4242), child.pid);
    try std.testing.expectEqual(pidfd, child.pidfd.fd());
    try expectOpen(pidfd);
    try std.testing.expectEqual(@as(?host.WorkerLeaf, leaf), child.leaf);
    try std.testing.expect(child.page != null);
    for (released) |fd|
        try expectClosed(fd);
    try std.testing.expect(machine.metrics == null);
    try std.testing.expect(machine.ingress_payload == null);
    // The machine is spent: a second abandonment hands nothing over.
    const empty = machine.abandon();
    try std.testing.expect(!empty.pidfd.isValid());
    try std.testing.expect(empty.leaf == null);
    try std.testing.expect(empty.page == null);
}

test "the page an abandoned launch hands back holds what the child logged after WorkerInit, for a drain once the child is dead" {
    var send: InitSend = undefined;
    try send.init(.none);
    defer send.deinit();
    try send.send();

    // The child maps the page WorkerInit brought, installs it as its log
    // sink and reports its boot's failure there before it exits.
    var received = try ipc.zygote_worker.recvWorkerInit(send.pair[1]);
    defer received.deinit();
    var child_page = try worker_shared_page.mapWorkerWriter(received.metrics_fd);
    defer child_page.deinit();
    const line = "worker boot failed: InvalidWorkerInit";
    child_page.publishLogLine(.err, worker_shared_page.LogLineFlags.runtime, 0, 1, line);
    try ipc.zygote_worker.sendWorkerInitFailed(send.pair[1], .invalid_worker_init);
    _ = send.machine.onEvent(.init_readable) orelse return error.TestExpectedOutcome;

    var child = send.machine.abandon();
    defer child.pidfd.deinit();
    defer if (child.page) |*page| page.deinit();
    const page = if (child.page) |*held| held else return error.TestExpectedPage;
    var scratch: [worker_shared_page.LOG_LINE_BYTES_MAX]u8 = undefined;
    var lines: [2]worker_shared_page.DrainedLogLine = undefined;
    try std.testing.expectEqual(@as(usize, 1), try page.drainLogLinesChecked(&scratch, &lines));
    try std.testing.expectEqualStrings(line, lines[0].payload);
    try std.testing.expectEqual(worker_shared_page.LogLineFlags.runtime, lines[0].header.flags);
}

test "reaping an abandoned child kills it, removes its leaf by name and closes its pidfd" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const leaf_fd = try makeLeaf(tmp.dir, 9);
    std.posix.close(leaf_fd);

    const child_pid = try std.posix.fork();
    if (child_pid == 0) {
        // Only raw syscalls here: the test binary may be multithreaded, and
        // fork cloned only the calling thread.
        while (true) std.posix.nanosleep(60, 0);
    }
    var collected = false;
    defer if (!collected) killAndCollect(child_pid);
    const pidfd = try process.openPidFd(@intCast(child_pid));

    // A plain directory has no `cgroup.kill`, so the removal is the rmdir by
    // name alone.
    var child: launch.AbandonedChild = .{
        .pid = @intCast(child_pid),
        .pidfd = fd_mod.OwnedFd.fromRaw(pidfd),
        .leaf = .{ .workers_dir_fd = tmp.dir.fd, .job_id = 9 },
    };
    child.reap();

    const status = std.posix.waitpid(child_pid, 0).status;
    collected = true;
    try std.testing.expect(std.posix.W.IFSIGNALED(status));
    try std.testing.expectEqual(@as(u32, std.posix.SIG.KILL), std.posix.W.TERMSIG(status));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("worker-9", .{}));
    try std.testing.expect(!child.pidfd.isValid());
    try std.testing.expect(child.leaf == null);
    try expectClosed(pidfd);
}

test "WorkerReady ends the wait ready and stamps its receipt, and the handle takes everything the machine held" {
    var send: InitSend = undefined;
    try send.init(.none);
    defer send.deinit();
    try send.send();
    var received = try ipc.zygote_worker.recvWorkerInit(send.pair[1]);
    received.deinit();

    try ipc.zygote_worker.sendWorkerReady(send.pair[1]);
    const outcome = send.machine.onEvent(.init_readable) orelse return error.TestExpectedOutcome;
    try std.testing.expect(outcome == .ready);
    try std.testing.expectEqual(LaunchPhase.ready, send.machine.phase);
    try std.testing.expect(send.machine.ready_received_ns != 0);

    const control_fd = send.machine.worker_init_fd;
    var handle = send.machine.takeHandle();
    try std.testing.expectEqual(control_fd, handle.control_fd);
    try std.testing.expectEqual(host.WorkerLeaf{ .workers_dir_fd = send.tmp.dir.fd, .job_id = InitSend.job_id }, handle.leaf);
    try std.testing.expect(handle.metrics != null);
    try std.testing.expect(send.machine.leaf == null);
    try std.testing.expectEqual(@as(std.posix.fd_t, -1), send.machine.pidfd);
    try std.testing.expectEqual(@as(std.posix.fd_t, -1), send.machine.worker_init_fd);
    try std.testing.expect(send.machine.metrics == null);
    // Released by hand: the stand-in pidfd names no process a teardown could
    // wait for.
    std.posix.close(handle.control_fd);
    std.posix.close(handle.pidfd);
    std.posix.close(handle.completion_eventfd);
    std.posix.close(handle.ingress_payload_credit_eventfd);
    handle.ingress_payload.deinit();
    handle.metrics.?.deinit();
}

test "a child that dies before ready fails the launch typed" {
    var machine = posed(.awaiting_ready);
    const outcome = machine.onEvent(.pidfd_event) orelse return error.TestExpectedOutcome;
    try std.testing.expectEqual(launch.Outcome{ .failed = error.WorkerInitFailed }, outcome);
    try std.testing.expectEqual(LaunchPhase.failed, machine.phase);
    try std.testing.expectEqual(@as(?launch.LaunchError, error.WorkerInitFailed), machine.fail_reason);
    // No page or leaf names memory, so the child crashed or was killed.
    try std.testing.expectEqual(@as(?launch.InitFailure, .crash), machine.init_failure);
}

test "an init socket that ends without an outcome fails the launch as the child's exit" {
    // A child holds its init socket until it exits, so the socket ends without
    // an outcome only when the child is gone. Its end closes either with the
    // WorkerInit it never read still queued, which the host reads as a reset,
    // or with an empty queue, which reads as end of stream.
    for ([_]bool{ true, false }) |init_unread| {
        const pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
        if (init_unread)
            try ipc.packet.sendExact(pair[0], "WorkerInit");
        std.posix.close(pair[1]);
        var machine = posed(.awaiting_ready);
        machine.worker_init_fd = pair[0];
        const outcome = machine.onEvent(.init_readable) orelse return error.TestExpectedOutcome;
        try std.testing.expectEqual(launch.Outcome{ .failed = error.WorkerInitFailed }, outcome);
        try std.testing.expectEqual(@as(?launch.InitFailure, .crash), machine.init_failure);
        const child = machine.abandon();
        try std.testing.expect(!child.pidfd.isValid());
    }
}

test "a child that ended for memory before ready fails its launch with memory as the cause" {
    // The sentinel's mark on the page, read when the init socket ends.
    {
        const page_fd = try worker_shared_page.createMemfd("collo-test-ended-for-memory");
        defer std.posix.close(page_fd);
        // The test plays the child's sentinel through a mapping of its own.
        var worker_page = try worker_shared_page.mapWorkerWriter(page_fd);
        defer worker_page.deinit();
        worker_page.setState(.dead, .memory);
        const pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
        std.posix.close(pair[1]);
        var machine = posed(.awaiting_ready);
        machine.worker_init_fd = pair[0];
        machine.metrics = try worker_shared_page.mapHostReader(page_fd);
        _ = machine.onEvent(.init_readable) orelse return error.TestExpectedOutcome;
        try std.testing.expectEqual(@as(?launch.InitFailure, .memory), machine.init_failure);
        var child = machine.abandon();
        child.release();
    }
    // The kernel's OOM kill counted in the leaf, read by name when the pidfd
    // reports the exit. A plain directory with the events file stands in.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.makeDir("worker-3");
        try tmp.dir.writeFile(.{
            .sub_path = "worker-3/memory.events.local",
            .data = "low 0\nhigh 0\nmax 1\noom 1\noom_kill 1\n",
        });
        var machine = posed(.awaiting_ready);
        machine.leaf = .{ .workers_dir_fd = tmp.dir.fd, .job_id = 3 };
        _ = machine.onEvent(.pidfd_event) orelse return error.TestExpectedOutcome;
        try std.testing.expectEqual(@as(?launch.InitFailure, .memory), machine.init_failure);
        _ = machine.abandon();
    }
}

test "a child's reported init failure fails its launch with the child's reason" {
    const pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(pair[1]);
    try ipc.zygote_worker.sendWorkerInitFailed(pair[1], .init_deadline_exceeded);
    var machine = posed(.awaiting_ready);
    machine.worker_init_fd = pair[0];
    const outcome = machine.onEvent(.init_readable) orelse return error.TestExpectedOutcome;
    try std.testing.expectEqual(launch.Outcome{ .failed = error.WorkerInitFailed }, outcome);
    try std.testing.expectEqual(
        @as(?launch.InitFailure, .{ .reported = .init_deadline_exceeded }),
        machine.init_failure,
    );
    _ = machine.abandon();
}

test "an init outcome that does not decode fails the launch as a broken protocol" {
    const pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(pair[1]);
    const unknown_reason = ipc.messages.WorkerInitFailed{
        .kind = @intFromEnum(ipc.messages.MessageKind.worker_init_failed),
        .reason = 999,
    };
    try ipc.packet.sendExact(pair[1], std.mem.asBytes(&unknown_reason));
    var machine = posed(.awaiting_ready);
    machine.worker_init_fd = pair[0];
    const outcome = machine.onEvent(.init_readable) orelse return error.TestExpectedOutcome;
    try std.testing.expectEqual(launch.Outcome{ .failed = error.ZygoteProtocol }, outcome);
    _ = machine.abandon();
}

test "the child window expiring fails the launch as a timeout" {
    var machine = posed(.awaiting_ready);
    const outcome = machine.onEvent(.child_deadline_expired) orelse return error.TestExpectedOutcome;
    try std.testing.expectEqual(launch.Outcome{ .failed = error.WorkerInitTimeout }, outcome);
    try std.testing.expectEqual(@as(?launch.LaunchError, error.WorkerInitTimeout), machine.fail_reason);
}

test "an event after the wait ended belongs to whoever holds the worker and changes nothing" {
    for ([_]LaunchPhase{ .ready, .failed }) |phase| {
        for (std.enums.values(launch.LaunchEvent)) |event| {
            var machine = posed(phase);
            try std.testing.expectEqual(@as(?launch.Outcome, null), machine.onEvent(event));
            try std.testing.expectEqual(phase, machine.phase);
        }
    }
}

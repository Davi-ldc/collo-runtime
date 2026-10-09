//! The launch machine without a zygote: the await-ready transition table with
//! synthetic outcomes and the cause it records for a child whose init failed
//! (`InitFailure`), the WorkerInit `sendInit` sends, attached with its
//! session and boot token or detached with the worker's wake descriptors
//! alone, the wake set a reattach's session shares with the launch's, what
//! `start` takes from the forked worker and refuses without a cgroup leaf,
//! what `abandon` hands back, and `AbandonedChild.reap` on a real child
//! process. Socket pairs exercise the real typed WorkerReady receiver and
//! WorkerInit sender; sandbox and zygote behavior remain in the integration
//! lane.

const std = @import("std");
const ipc = @import("collo_ipc");
const fd_mod = @import("collo_os").fd;
const process = @import("collo_os").process;
const os_linux = @import("collo_os").linux;
const host = @import("collo_host");
const zygote = @import("collo_zygote");
const worker_shared_page = @import("collo_worker_state").page;

const launch = host.launch;
const Machine = launch.Machine;
const LaunchPhase = launch.LaunchPhase;
const StepResult = launch.StepResult;
const EffectTag = std.meta.Tag(launch.LaunchEffect);

/// Trace-silent stand-in: the transitions trace through the zygote's write
/// fd, and null is exactly "tracing off".
var quiet_zygote = zygote.host_client.SpawnedZygote{
    .pid = 0,
    .pidfd = -1,
    .control_fd = null,
    .trace_read_fd = null,
    .trace_write_fd = null,
    .next_fork_job_id = 1,
};

/// The wake set of machines that never send WorkerInit. It holds no
/// descriptor, so a mistaken send fails at its first open.
var unsent_wake_set: ipc.egress_shared.WakeSet = .{};

/// A machine posed mid-boot: no child, no fds. Every fd stays -1 so a
/// mistaken arm fails loudly rather than touching an unrelated descriptor.
fn posed(phase: LaunchPhase, serve_faults: bool) Machine {
    return .{
        .allocator = std.testing.allocator,
        .zygote_process = &quiet_zygote,
        .memory_limit_bytes = 0,
        .options = .{ .egress = .{ .detached = &unsent_wake_set } },
        .phase = phase,
        .serve_faults = serve_faults,
    };
}

fn expectEffects(result: StepResult, expected: []const EffectTag) !void {
    try std.testing.expectEqual(expected.len, result.count);
    for (expected, 0..) |tag, index|
        try std.testing.expectEqual(tag, std.meta.activeTag(result.effects[index]));
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
/// and every memfd has its own.
fn fileIdentity(fd: std.posix.fd_t) ![2]u64 {
    const stat = try std.posix.fstat(fd);
    return .{ @intCast(stat.dev), @intCast(stat.ino) };
}

/// Whether the pipe end `fd` reports a hang-up: no write end is left.
fn hungUp(fd: std.posix.fd_t) !bool {
    var pollfds = [1]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    _ = try std.posix.poll(&pollfds, 0);
    return (pollfds[0].revents & std.posix.POLL.HUP) != 0;
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

/// The key every boot token in these tests is minted under, and what the
/// tokens carry besides their deadline.
const boot_key: ipc.egress_token.Key = .{ .bytes = @splat(0x5a) };
const boot_egress: launch.BootEgress = .{
    .key = boot_key,
    .session_id = 41,
    .policy_id = 0,
    .budget = 16,
};

/// Whether a launch sends a session or the worker's wake descriptors alone.
const Egress = enum { detached, attached };

/// The routes of an `InitSend` launch: a one-route table, and whether each
/// route runs in a realm of its own.
const Routes = struct {
    isolate_realm: bool = false,
};

/// A machine posed after its local steps, with every descriptor `sendInit`
/// reads, so `sendInit` sends a real WorkerInit down `pair[0]`. One eventfd
/// stands in for every borrowed descriptor, since the receiver only counts
/// them; the two the send closes get eventfds of their own. Initialized in
/// place, since a detached launch points at `wake_set`.
const InitSend = struct {
    pair: [2]std.posix.fd_t,
    stand_in_fd: std.posix.fd_t,
    wake_set: ipc.egress_shared.WakeSet,
    session: ipc.egress_shared.SessionFds,
    /// The launch's route table when it has routes.
    table: ?ipc.route_table.Sealed,
    machine: Machine,

    /// With `routes`, the launch carries a one-route table, whose length
    /// WorkerInit announces, and the stand-in as its pack. The wake set and
    /// a session on it exist either way; `egress` decides whether the launch
    /// sends the session's half and its boot token or the wake descriptors
    /// alone.
    fn init(self: *InitSend, routes: ?Routes, egress: Egress) !void {
        self.pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
        errdefer closePair(self.pair);
        self.stand_in_fd = try eventFd();
        errdefer std.posix.close(self.stand_in_fd);
        self.wake_set = try ipc.egress_shared.WakeSet.create();
        errdefer self.wake_set.deinit();
        self.session = try ipc.egress_shared.createSessionForWorker(&self.wake_set);
        errdefer self.session.deinit();
        self.table = null;
        if (routes != null) {
            self.table = try ipc.route_table.buildSealed(std.testing.allocator, &.{.{
                .entry_specifier = "/__collo_route/demo/entry.js",
                .bindings = &.{},
            }});
        }
        errdefer if (self.table) |table| table.close();

        self.machine = posed(.idle, false);
        self.machine.memory_limit_bytes = 64 * 1024 * 1024;
        self.machine.options.egress = switch (egress) {
            .detached => .{ .detached = &self.wake_set },
            .attached => .{ .attached = .{ .shared_fds = self.session.rawForWorker(), .boot = boot_egress } },
        };
        if (routes) |route_options| {
            self.machine.options.routes = .{
                .table = self.table.?,
                .module_pack_fd = self.stand_in_fd,
                .isolate_realm = route_options.isolate_realm,
            };
            self.machine.route_table_len = self.table.?.blob_len;
        } else {
            self.machine.route_table_len = ipc.route_table.empty_blob.len;
        }
        self.machine.worker_init_fd = self.pair[0];
        self.machine.metrics_fd = self.stand_in_fd;
        self.machine.completion_eventfd = self.stand_in_fd;
        self.machine.ingress_payload_fd = self.stand_in_fd;
        self.machine.ingress_payload_credit_eventfd = self.stand_in_fd;
        self.machine.tmp_root_dir_fd = self.stand_in_fd;
        self.machine.cgroup_dir_fd = self.stand_in_fd;
        self.machine.placeholder_fs_index_fd = self.stand_in_fd;
        self.machine.route_table_memfd = try eventFd();
        errdefer std.posix.close(self.machine.route_table_memfd);
        self.machine.fs_fault_worker_fd = try eventFd();
    }

    fn deinit(self: *InitSend) void {
        if (self.machine.route_table_memfd >= 0)
            std.posix.close(self.machine.route_table_memfd);
        if (self.machine.fs_fault_worker_fd >= 0)
            std.posix.close(self.machine.fs_fault_worker_fd);
        if (self.table) |table|
            table.close();
        self.session.deinit();
        self.wake_set.deinit();
        std.posix.close(self.stand_in_fd);
        closePair(self.pair);
    }

    fn closePair(pair: [2]std.posix.fd_t) void {
        std.posix.close(pair[0]);
        std.posix.close(pair[1]);
    }
};

test "a launch with routes tells the child it serves them and in which realm mode, and sends the pack" {
    for ([_]bool{ false, true }) |isolate_realm| {
        var send: InitSend = undefined;
        try send.init(.{ .isolate_realm = isolate_realm }, .attached);
        defer send.deinit();

        try expectEffects(send.machine.sendInit(), &.{ .arm_init_poll, .arm_pidfd_poll });
        try std.testing.expectEqual(LaunchPhase.awaiting_ready, send.machine.phase);
        // The send closed the machine's dup of the table.
        try std.testing.expectEqual(@as(std.posix.fd_t, -1), send.machine.route_table_memfd);

        var received = try ipc.recvWorkerInit(send.pair[1]);
        defer received.deinit();
        try received.message.validate();
        try std.testing.expect(received.message.servesRoutes());
        try std.testing.expectEqual(isolate_realm, received.message.isolatesRealms());
        // The send carries the length the fixture recorded in `prepare`'s
        // place; server/tests/supervisor/launcher.zig follows a real
        // `prepare` from the table to the child.
        try std.testing.expectEqual(send.table.?.blob_len, received.message.route_table_len);
        try std.testing.expect(received.module_pack_fd != null);
    }
}

test "a launch without routes sends the empty table and leaves the serves-routes flag clear" {
    var send: InitSend = undefined;
    try send.init(null, .attached);
    defer send.deinit();

    try expectEffects(send.machine.sendInit(), &.{ .arm_init_poll, .arm_pidfd_poll });

    var received = try ipc.recvWorkerInit(send.pair[1]);
    defer received.deinit();
    try received.message.validate();
    try std.testing.expect(!received.message.servesRoutes());
    try std.testing.expect(!received.message.isolatesRealms());
    try std.testing.expectEqual(@as(u64, ipc.route_table.empty_blob.len), received.message.route_table_len);
    try std.testing.expect(received.module_pack_fd == null);
}

test "an attached launch sends the session's half beside a boot token that expires with the child window (#48)" {
    var send: InitSend = undefined;
    try send.init(null, .attached);
    defer send.deinit();

    try expectEffects(send.machine.sendInit(), &.{ .arm_init_poll, .arm_pidfd_poll });

    var received = try ipc.recvWorkerInit(send.pair[1]);
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
    try std.testing.expectEqual(boot_egress.budget, fields.budget);
    try std.testing.expectEqual(@as(u64, 0), fields.request_id);
    try std.testing.expectEqual(@as(u64, 0), fields.request_generation);
    try std.testing.expect(send.machine.child_init_deadline_abs_ns != 0);
    try std.testing.expectEqual(send.machine.child_init_deadline_abs_ns, fields.deadline_monotonic_ns);
    try std.testing.expectEqual(received.message.init_deadline_mono_ns, fields.deadline_monotonic_ns);
}

test "a launch without a grant carries the wake set and no regions" {
    var send: InitSend = undefined;
    try send.init(null, .detached);
    defer send.deinit();

    try expectEffects(send.machine.sendInit(), &.{ .arm_init_poll, .arm_pidfd_poll });

    var received = try ipc.recvWorkerInit(send.pair[1]);
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
    try send.init(null, .attached);
    defer send.deinit();

    try expectEffects(send.machine.sendInit(), &.{ .arm_init_poll, .arm_pidfd_poll });

    var received = try ipc.recvWorkerInit(send.pair[1]);
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

test "a launch without its cgroup leaf fails before any local step and empties the forked worker" {
    const init_fd = try eventFd();
    const pidfd = try eventFd();
    var forked = zygote.host_client.ForkedWorker{
        .pid = 0,
        .worker_init_fd = init_fd,
        .pidfd = pidfd,
    };
    var machine = Machine.init(std.testing.allocator, &quiet_zygote, 64 * 1024 * 1024, .{
        .egress = .{ .detached = &unsent_wake_set },
    });

    try expectEffects(machine.start(&forked), &.{.report_failed});
    try std.testing.expectEqual(@as(?launch.LaunchError, error.WorkerCgroupNotPrepared), machine.fail_reason);
    // The machine took every descriptor, so the caller has nothing left to
    // close twice, and no tmp root was created for a launch that cannot run.
    try std.testing.expect(forked.worker_init_fd == null);
    try std.testing.expect(forked.pidfd == null);
    try std.testing.expect(machine.tmp_root == null);

    var child = machine.abandon();
    defer child.pidfd.deinit();
    try std.testing.expectEqual(pidfd, child.pidfd.fd());
    try std.testing.expect(!child.cgroup_dir.isValid());
    try expectClosed(init_fd);
}

test "abandon hands back the pidfd and the cgroup leaf and releases everything else" {
    var tmp_path_buffer: [96]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_path_buffer, "/tmp/collo-test-abandon-{d}-{d}", .{
        std.os.linux.getpid(),
        process.monotonicNowNsOrZero(),
    });
    try std.fs.makeDirAbsolute(tmp_path);
    errdefer std.fs.deleteTreeAbsolute(tmp_path) catch {};

    var machine = posed(.failed, false);
    machine.pid = 4242;
    machine.pidfd = try eventFd();
    machine.cgroup_dir_fd = try eventFd();
    machine.cgroup_dir = try std.testing.allocator.dupe(u8, "/sys/fs/cgroup/never-touched");
    machine.tmp_root = try std.testing.allocator.dupe(u8, tmp_path);
    const released = [_]std.posix.fd_t{
        try eventFd(), try eventFd(), try eventFd(), try eventFd(),
        try eventFd(), try eventFd(), try eventFd(), try eventFd(),
    };
    machine.worker_init_fd = released[0];
    machine.route_table_memfd = released[1];
    machine.metrics_fd = released[2];
    machine.completion_eventfd = released[3];
    machine.ingress_payload_fd = released[4];
    machine.ingress_payload_credit_eventfd = released[5];
    machine.fs_fault_server_fd = released[6];
    machine.tmp_root_dir_fd = released[7];
    const pidfd = machine.pidfd;
    const leaf_fd = machine.cgroup_dir_fd;

    var child = machine.abandon();
    defer child.pidfd.deinit();
    defer child.cgroup_dir.deinit();

    try std.testing.expectEqual(@as(u32, 4242), child.pid);
    try std.testing.expectEqual(pidfd, child.pidfd.fd());
    try std.testing.expectEqual(leaf_fd, child.cgroup_dir.fd());
    try expectOpen(pidfd);
    try expectOpen(leaf_fd);
    for (released) |fd|
        try expectClosed(fd);
    // The tmp root goes with the machine; the cgroup path is only freed,
    // since the leaf belongs to whoever reaps the child.
    try std.testing.expectError(error.FileNotFound, std.fs.accessAbsolute(tmp_path, .{}));
    try std.testing.expect(machine.tmp_root == null);
    try std.testing.expect(machine.cgroup_dir == null);
    try std.testing.expectEqual(@as(std.posix.fd_t, -1), machine.pidfd);
    try std.testing.expectEqual(@as(std.posix.fd_t, -1), machine.cgroup_dir_fd);
}

test "reaping an abandoned child kills it, removes its leaf and closes both descriptors" {
    const child_pid = try std.posix.fork();
    if (child_pid == 0) {
        // Only raw syscalls here: the test binary may be multithreaded, and
        // fork cloned only the calling thread.
        while (true) std.posix.nanosleep(60, 0);
    }
    var collected = false;
    defer if (!collected) killAndCollect(child_pid);
    const pidfd = try process.openPidFd(@intCast(child_pid));

    // A plain directory stands in for the cgroup leaf: removing a leaf is a
    // kill through its `cgroup.kill`, which a plain directory lacks, then an
    // rmdir by the path behind the descriptor.
    var leaf_path_buffer: [96]u8 = undefined;
    const leaf_path = try std.fmt.bufPrint(&leaf_path_buffer, "/tmp/collo-test-leaf-{d}-{d}", .{
        std.os.linux.getpid(),
        process.monotonicNowNsOrZero(),
    });
    try std.fs.makeDirAbsolute(leaf_path);
    errdefer std.fs.deleteTreeAbsolute(leaf_path) catch {};
    const leaf_fd = try std.posix.open(leaf_path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);

    var child: launch.AbandonedChild = .{
        .pid = @intCast(child_pid),
        .pidfd = fd_mod.OwnedFd.fromRaw(pidfd),
        .cgroup_dir = fd_mod.OwnedFd.fromRaw(leaf_fd),
    };
    child.reap();

    const status = std.posix.waitpid(child_pid, 0).status;
    collected = true;
    try std.testing.expect(std.posix.W.IFSIGNALED(status));
    try std.testing.expectEqual(@as(u32, std.posix.SIG.KILL), std.posix.W.TERMSIG(status));
    try std.testing.expectError(error.FileNotFound, std.fs.accessAbsolute(leaf_path, .{}));
    try std.testing.expect(!child.pidfd.isValid());
    try std.testing.expect(!child.cgroup_dir.isValid());
    try expectClosed(pidfd);
    try expectClosed(leaf_fd);
}

test "WorkerReady receipt is recorded before the post-ready drain" {
    const pair = try fd_mod.socketPairType(
        std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC,
    );
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);
    var machine = posed(.awaiting_ready, true);
    machine.worker_init_fd = pair[0];
    try ipc.sendWorkerReady(pair[1]);
    try expectEffects(machine.onEvent(.init_readable), &.{ .arm_grace_timer, .start_fault_drain_job });
    try std.testing.expectEqual(LaunchPhase.grace_drain, machine.phase);
    const received_ns = machine.ready_received_ns;
    try std.testing.expect(received_ns != 0);
    try std.testing.expectEqual(@as(u64, 0), machine.spans.total_ns);
    try expectEffects(machine.onEvent(.{ .fault_drain_done = .idle }), &.{.report_ready});
    try std.testing.expectEqual(received_ns, machine.ready_received_ns);
    try std.testing.expectEqual(LaunchPhase.ready, machine.phase);
}

test "a child that dies before ready fails the launch typed" {
    var machine = posed(.awaiting_ready, false);
    const result = machine.onEvent(.pidfd_event);
    try expectEffects(result, &.{.report_failed});
    try std.testing.expectEqual(LaunchPhase.failed, machine.phase);
    try std.testing.expectEqual(@as(?launch.LaunchError, error.WorkerInitFailed), machine.fail_reason);
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
        var machine = posed(.awaiting_ready, false);
        machine.worker_init_fd = pair[0];
        try expectEffects(machine.onEvent(.init_readable), &.{.report_failed});
        try std.testing.expectEqual(@as(?launch.LaunchError, error.WorkerInitFailed), machine.fail_reason);
        // No page or leaf names memory, so the child crashed or was killed.
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
        var page = try worker_shared_page.mapReadWrite(page_fd);
        page.initializeCrashDefault(4242, 64 * 1024 * 1024, 1);
        page.setState(.dead, .memory);
        const pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
        std.posix.close(pair[1]);
        var machine = posed(.awaiting_ready, false);
        machine.worker_init_fd = pair[0];
        machine.metrics = page;
        try expectEffects(machine.onEvent(.init_readable), &.{.report_failed});
        try std.testing.expectEqual(@as(?launch.InitFailure, .memory), machine.init_failure);
        _ = machine.abandon();
    }
    // The kernel's OOM kill counted in the leaf, read when the pidfd reports
    // the exit. A plain directory with the events file stands in for it.
    {
        var leaf = std.testing.tmpDir(.{});
        defer leaf.cleanup();
        try leaf.dir.writeFile(.{
            .sub_path = "memory.events.local",
            .data = "low 0\nhigh 0\nmax 1\noom 1\noom_kill 1\n",
        });
        var machine = posed(.awaiting_ready, false);
        machine.cgroup_dir = try leaf.dir.realpathAlloc(std.testing.allocator, ".");
        try expectEffects(machine.onEvent(.pidfd_event), &.{.report_failed});
        try std.testing.expectEqual(@as(?launch.InitFailure, .memory), machine.init_failure);
        _ = machine.abandon();
    }
}

test "a child's reported init failure fails its launch with the child's reason" {
    const pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(pair[1]);
    try ipc.sendWorkerInitFailed(pair[1], .invalid_fs_index);
    var machine = posed(.awaiting_ready, false);
    machine.worker_init_fd = pair[0];
    try expectEffects(machine.onEvent(.init_readable), &.{.report_failed});
    try std.testing.expectEqual(@as(?launch.LaunchError, error.WorkerInitFailed), machine.fail_reason);
    try std.testing.expectEqual(
        @as(?launch.InitFailure, .{ .reported = .invalid_fs_index }),
        machine.init_failure,
    );
    _ = machine.abandon();
}

test "an init outcome that does not decode fails the launch as a broken protocol" {
    const pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(pair[1]);
    const unknown_reason = ipc.WorkerInitFailed{
        .kind = @intFromEnum(ipc.MessageKind.worker_init_failed),
        .reason = 999,
    };
    try ipc.packet.sendExact(pair[1], std.mem.asBytes(&unknown_reason));
    var machine = posed(.awaiting_ready, false);
    machine.worker_init_fd = pair[0];
    try expectEffects(machine.onEvent(.init_readable), &.{.report_failed});
    try std.testing.expectEqual(@as(?launch.LaunchError, error.ZygoteProtocol), machine.fail_reason);
    _ = machine.abandon();
}

test "a death after ready belongs to the worker's holder, not the launch" {
    var machine = posed(.ready, false);
    const result = machine.onEvent(.pidfd_event);
    try expectEffects(result, &.{});
    try std.testing.expectEqual(LaunchPhase.ready, machine.phase);
}

test "the child window expiring fails the launch as a timeout" {
    var machine = posed(.awaiting_ready, false);
    const result = machine.onEvent(.child_deadline_expired);
    try expectEffects(result, &.{.report_failed});
    try std.testing.expectEqual(@as(?launch.LaunchError, error.WorkerInitTimeout), machine.fail_reason);
}

test "the child window does not fire a machine already past the ready wait" {
    var machine = posed(.grace_drain, true);
    const result = machine.onEvent(.child_deadline_expired);
    try expectEffects(result, &.{});
    try std.testing.expectEqual(LaunchPhase.grace_drain, machine.phase);
}

test "boot faults drain one at a time" {
    var machine = posed(.awaiting_ready, true);
    // First readiness starts the drain.
    try expectEffects(machine.onEvent(.fault_readable), &.{.start_fault_drain_job});
    try std.testing.expect(machine.fault_drain_inflight);
    // A second readiness while it runs must not start a second reader of
    // the same channel.
    try expectEffects(machine.onEvent(.fault_readable), &.{});

    // An idle drain re-arms the poll; the channel stays served.
    try expectEffects(machine.onEvent(.{ .fault_drain_done = .idle }), &.{.arm_fault_poll});
    try std.testing.expect(!machine.fault_drain_inflight);
    try std.testing.expect(machine.serve_faults);
}

test "a closed fault channel stops the boot-window service" {
    var machine = posed(.awaiting_ready, true);
    try expectEffects(machine.onEvent(.fault_readable), &.{.start_fault_drain_job});
    try expectEffects(machine.onEvent(.{ .fault_drain_done = .peer_closed }), &.{});
    try std.testing.expect(!machine.serve_faults);
    // No service, no re-arm: a further readiness is inert.
    try expectEffects(machine.onEvent(.fault_readable), &.{});
}

test "the post-ready grace completes on its last drain" {
    var machine = posed(.grace_drain, true);
    machine.fault_drain_inflight = true;
    // The drain that empties the channel is what releases the handle.
    try expectEffects(machine.onEvent(.{ .fault_drain_done = .peer_closed }), &.{.report_ready});
    try std.testing.expectEqual(LaunchPhase.ready, machine.phase);
}

test "the grace timer completes a boot whose channel stayed quiet" {
    var machine = posed(.grace_drain, true);
    try expectEffects(machine.onEvent(.grace_expired), &.{.report_ready});
    try std.testing.expectEqual(LaunchPhase.ready, machine.phase);
}

test "a grace timer that fires after the handle left is inert" {
    var machine = posed(.ready, false);
    try expectEffects(machine.onEvent(.grace_expired), &.{});
    try std.testing.expectEqual(LaunchPhase.ready, machine.phase);
}

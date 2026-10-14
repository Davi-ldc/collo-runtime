//! The zygote and worker handshakes of `common/ipc/zygote_worker.zig`: the
//! fork request with its one descriptor, the leaf; WorkerInit's fields,
//! layout and refusals; its descriptor table, which the message alone
//! announces (the state page, the two eventfds, the payload memfd and the
//! leaf, then the session's regions with a boot token, the wake descriptors
//! with `flag_egress`, and the definition artifact last); and the init
//! outcome. Everything runs over in-process socketpairs, memfds and
//! eventfds; the zygote integration lane covers the same handshakes against
//! a real zygote and worker.

const std = @import("std");
const ipc = @import("collo_ipc");
const fd_mod = @import("collo_os").fd;

const WorkerInit = ipc.WorkerInit;
const egress_token = ipc.egress_token;
const egress_shared = ipc.egress_shared;

/// The key the tests mint tokens under: fixed, so no test reads the system's
/// random source, and nonzero, since the zero key verifies nothing.
const token_key: egress_token.Key = .{ .bytes = @splat(0x5c) };

/// A boot token's bytes, as the host writes them into WorkerInit.
fn bootTokenBytes() egress_token.Bytes {
    const token = egress_token.mint(&token_key, .{
        .kind = .boot,
        .policy_id = 0,
        .session_id = 7,
        .request_id = 0,
        .request_generation = 0,
        .deadline_monotonic_ns = 9_000_000_000,
    });
    return egress_token.asBytes(&token).*;
}

/// Open descriptors of this process, counted from `/proc/self/fd` without
/// the directory's own.
fn openFdCount() !usize {
    var dir = try std.fs.openDirAbsolute("/proc/self/fd", .{ .iterate = true });
    defer dir.close();
    var count: usize = 0;
    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        const fd = std.fmt.parseInt(std.posix.fd_t, entry.name, 10) catch continue;
        if (fd == dir.fd)
            continue;
        count += 1;
    }
    return count;
}

/// Fails unless each descriptor of `received` is a new descriptor of the
/// file `sent` holds at the same index, told apart by device and inode.
fn expectSameFiles(sent: []const std.posix.fd_t, received: []const std.posix.fd_t) !void {
    try std.testing.expectEqual(sent.len, received.len);
    for (sent, received) |sent_fd, received_fd| {
        try std.testing.expect(received_fd != sent_fd);
        const sent_stat = try std.posix.fstat(sent_fd);
        const received_stat = try std.posix.fstat(received_fd);
        try std.testing.expectEqual(sent_stat.dev, received_stat.dev);
        try std.testing.expectEqual(sent_stat.ino, received_stat.ino);
    }
}

/// Fails unless each slot of `received` holds a new descriptor of the file
/// `sent` holds in the same slot, with the regions present in both or in
/// neither. The two eventfds share one anonymous inode, so a count written
/// through the sent descriptor must be read through the received one.
fn expectSameEgressFiles(sent: egress_shared.RawFds, received: egress_shared.RawFds) !void {
    try std.testing.expectEqual(sent.regionCount(), received.regionCount());
    if (sent.regionCount() == 0) {
        try expectSameFiles(&sent.wakeFds().asArray(), &received.wakeFds().asArray());
    } else {
        try expectSameFiles(&sent.asArray(), &received.asArray());
    }
    const eventfds = [_][2]std.posix.fd_t{
        .{ sent.command_eventfd, received.command_eventfd },
        .{ sent.completion_eventfd, received.completion_eventfd },
    };
    for (eventfds, 1..) |pair, count| {
        const written: u64 = count;
        try std.testing.expectEqual(@as(usize, @sizeOf(u64)), try std.posix.write(pair[0], std.mem.asBytes(&written)));
        var read: u64 = 0;
        try std.testing.expectEqual(@as(usize, @sizeOf(u64)), try std.posix.read(pair[1], std.mem.asBytes(&read)));
        try std.testing.expectEqual(written, read);
    }
}

/// A real file for every descriptor of a WorkerInit table, for tests that
/// send through the host's sender or build a table by hand. The table's shape
/// lives here alone. The control pair is nonblocking, so a receive finds
/// nothing when a send was refused. Initialized in place; `deinit` closes
/// everything.
const WorkerInitTableFixture = struct {
    control_pair: [2]std.posix.fd_t,
    /// A stream pair standing in for the state page: what the child writes
    /// to its descriptor, the test reads at the other end.
    metrics_pair: [2]std.posix.fd_t,
    /// The worker's wake set, which both the session and the wake
    /// descriptors of a WorkerInit without one are built on.
    wake_set: egress_shared.WakeSet,
    session: egress_shared.SessionFds,
    detached_wake: egress_shared.WakeFds,
    completion_eventfd: std.posix.fd_t,
    ingress_payload_fd: std.posix.fd_t,
    ingress_payload_credit_eventfd: std.posix.fd_t,
    /// A directory standing in for the worker's cgroup leaf.
    leaf: std.testing.TmpDir,
    artifact_fd: std.posix.fd_t,

    /// Descriptors every WorkerInit carries ahead of its egress descriptors.
    const base_fd_count: usize = 5;
    /// Descriptors of a WorkerInit with a boot token, which carries the
    /// session's whole half, the artifact included.
    const attached_fd_count: usize = base_fd_count + egress_shared.shared_fd_count + 1;
    /// Descriptors of a WorkerInit without a boot token: the same table
    /// without the session's regions, its wake descriptors kept.
    const detached_fd_count: usize = attached_fd_count - egress_shared.region_fd_count;
    /// Descriptors of a WorkerInit without egress: no egress descriptor at
    /// all.
    const no_egress_fd_count: usize = attached_fd_count - egress_shared.shared_fd_count;

    comptime {
        std.debug.assert(attached_fd_count == ipc.max_fds_per_message);
    }

    fn init(self: *WorkerInitTableFixture) !void {
        const control_flags = std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK;
        self.control_pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | control_flags);
        errdefer closePair(self.control_pair);
        self.metrics_pair = try fd_mod.socketPairType(std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC);
        errdefer closePair(self.metrics_pair);
        self.wake_set = try egress_shared.WakeSet.create();
        errdefer self.wake_set.deinit();
        self.session = try egress_shared.createSessionForWorker(&self.wake_set);
        errdefer self.session.deinit();
        self.detached_wake = try self.wake_set.openWorkerWake();
        errdefer self.detached_wake.close();
        self.completion_eventfd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
        errdefer std.posix.close(self.completion_eventfd);
        self.ingress_payload_fd = try ipc.ingress_channel.createSharedPayloadMemfd();
        errdefer std.posix.close(self.ingress_payload_fd);
        self.ingress_payload_credit_eventfd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
        errdefer std.posix.close(self.ingress_payload_credit_eventfd);
        self.leaf = std.testing.tmpDir(.{});
        errdefer self.leaf.cleanup();
        self.artifact_fd = try std.posix.memfd_create("test-definition-artifact", std.os.linux.MFD.CLOEXEC);
        errdefer std.posix.close(self.artifact_fd);
        try fd_mod.writeAllRaw(self.artifact_fd, "artifact-bytes");
    }

    fn deinit(self: *WorkerInitTableFixture) void {
        std.posix.close(self.artifact_fd);
        self.leaf.cleanup();
        std.posix.close(self.ingress_payload_credit_eventfd);
        std.posix.close(self.ingress_payload_fd);
        std.posix.close(self.completion_eventfd);
        self.detached_wake.close();
        self.session.deinit();
        self.wake_set.deinit();
        closePair(self.metrics_pair);
        closePair(self.control_pair);
    }

    /// The egress descriptors of a WorkerInit with a boot token: the
    /// session's worker half.
    fn attachedHalf(self: *const WorkerInitTableFixture) egress_shared.RawFds {
        return self.session.rawForWorker();
    }

    /// The egress descriptors of a WorkerInit without a boot token: wake
    /// descriptors and no region.
    fn detachedHalf(self: *const WorkerInitTableFixture) egress_shared.RawFds {
        return egress_shared.RawFds.wakeOnly(self.detached_wake);
    }

    /// The descriptors the host's sender takes, with `half` as the egress
    /// descriptors.
    fn fds(self: *const WorkerInitTableFixture, half: egress_shared.RawFds) ipc.WorkerInitFds {
        return .{
            .metrics_fd = self.metrics_pair[1],
            .completion_eventfd = self.completion_eventfd,
            .ingress_payload_fd = self.ingress_payload_fd,
            .ingress_payload_credit_eventfd = self.ingress_payload_credit_eventfd,
            .cgroup_dir_fd = self.leaf.dir.fd,
            .egress_shared_fds = half,
            .module_pack_fd = self.artifact_fd,
        };
    }

    /// The table of a WorkerInit with a boot token, in wire order.
    fn attachedTable(self: *const WorkerInitTableFixture) [attached_fd_count]std.posix.fd_t {
        var table: [attached_fd_count]std.posix.fd_t = undefined;
        table[0] = self.metrics_pair[1];
        table[1] = self.completion_eventfd;
        table[2] = self.ingress_payload_fd;
        table[3] = self.ingress_payload_credit_eventfd;
        table[4] = self.leaf.dir.fd;
        const egress_fds = self.attachedHalf().asArray();
        @memcpy(table[base_fd_count..][0..egress_shared.shared_fd_count], &egress_fds);
        table[attached_fd_count - 1] = self.artifact_fd;
        return table;
    }

    /// The table of a WorkerInit without a boot token, in wire order: the
    /// attached table with the detached wake descriptors in place of the
    /// session's half.
    fn detachedTable(self: *const WorkerInitTableFixture) [detached_fd_count]std.posix.fd_t {
        const attached = self.attachedTable();
        var table: [detached_fd_count]std.posix.fd_t = undefined;
        @memcpy(table[0..base_fd_count], attached[0..base_fd_count]);
        @memcpy(table[base_fd_count..][0..egress_shared.wake_fd_count], &self.detached_wake.asArray());
        table[detached_fd_count - 1] = self.artifact_fd;
        return table;
    }

    /// The table of a WorkerInit without egress, in wire order.
    fn noEgressTable(self: *const WorkerInitTableFixture) [no_egress_fd_count]std.posix.fd_t {
        const attached = self.attachedTable();
        var table: [no_egress_fd_count]std.posix.fd_t = undefined;
        @memcpy(table[0..base_fd_count], attached[0..base_fd_count]);
        table[no_egress_fd_count - 1] = self.artifact_fd;
        return table;
    }

    /// Sends `message` through the sender a host uses, with `half` as its
    /// egress descriptors and the fixture's files for every other one.
    fn send(self: *const WorkerInitTableFixture, message: *const WorkerInit, half: egress_shared.RawFds) !void {
        try ipc.sendWorkerInit(self.control_pair[0], message, self.fds(half));
    }

    /// Sends `message` by hand, with `table` as its descriptors, so the table
    /// can disagree with the message.
    fn sendRaw(self: *const WorkerInitTableFixture, message: WorkerInit, table: []const std.posix.fd_t) !void {
        try ipc.packet.sendWithFds(self.control_pair[0], std.mem.asBytes(&message), table);
    }

    fn closePair(pair: [2]std.posix.fd_t) void {
        std.posix.close(pair[0]);
        std.posix.close(pair[1]);
    }
};

/// A message every check of `WorkerInit.validate` passes, with no flag.
fn validMessage() WorkerInit {
    var message = WorkerInit.init(64);
    message.init_deadline_mono_ns = 1;
    return message;
}

test "an attached worker init carries the session's half beside its boot token, and the artifact last" {
    var fixture: WorkerInitTableFixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var message = validMessage();
    const boot_token = bootTokenBytes();
    message.boot_egress_token = boot_token;
    try fixture.send(&message, fixture.attachedHalf());

    var received = try ipc.recvWorkerInit(fixture.control_pair[1]);
    defer received.deinit();
    try received.message.validate();
    try std.testing.expect(received.message.hasEgress());
    try std.testing.expectEqualSlices(u8, &boot_token, &received.message.boot_egress_token);

    // Every base descriptor is a new descriptor of the file sent in its slot.
    try expectSameFiles(
        &.{ fixture.metrics_pair[1], fixture.completion_eventfd, fixture.ingress_payload_fd, fixture.ingress_payload_credit_eventfd, fixture.leaf.dir.fd },
        &.{ received.metrics_fd, received.completion_eventfd, received.ingress_payload_fd, received.ingress_payload_credit_eventfd, received.cgroup_dir_fd },
    );
    const metrics_fd = received.takeMetricsFd();
    defer std.posix.close(metrics_fd);
    try fd_mod.writeAllRaw(metrics_fd, "page");
    var buffer: [16]u8 = undefined;
    const read_len = try std.posix.read(fixture.metrics_pair[0], &buffer);
    try std.testing.expectEqualStrings("page", buffer[0..read_len]);
    var payload = try ipc.ingress_channel.mapSharedPayloadReadWrite(received.ingress_payload_fd, .worker);
    payload.deinit();

    // Every slot of the half holds the file sent in it, and mapping checks
    // every descriptor of the half for its kind and access.
    var half = received.takeEgressSharedFds();
    defer half.close();
    try expectSameEgressFiles(fixture.attachedHalf(), half);
    var endpoint = try egress_shared.mapEndpointTakeForWorker(&half);
    defer endpoint.deinit();
    _ = try endpoint.command.writePacket("fetch_start");
    const taken_again = received.takeEgressSharedFds();
    try std.testing.expect(taken_again.isEmpty());

    // The artifact closes the table.
    const artifact_fd = received.takeModulePackFd();
    defer std.posix.close(artifact_fd);
    const artifact_len = try std.posix.pread(artifact_fd, &buffer, 0);
    try std.testing.expectEqualStrings("artifact-bytes", buffer[0..artifact_len]);
    try std.testing.expectEqual(@as(std.posix.fd_t, -1), received.takeModulePackFd());
}

test "a detached worker init carries its wake descriptors and neither a region nor a boot token, and the artifact after them" {
    var fixture: WorkerInitTableFixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var message = validMessage();
    message.flags |= WorkerInit.flag_isolate_realm;
    try fixture.send(&message, fixture.detachedHalf());

    var received = try ipc.recvWorkerInit(fixture.control_pair[1]);
    defer received.deinit();
    try received.message.validate();
    try std.testing.expect(egress_token.isNone(&received.message.boot_egress_token));
    try std.testing.expect(received.message.isolatesRealms());
    var wake = received.takeEgressSharedFds();
    defer wake.close();
    try std.testing.expectEqual(@as(usize, 0), wake.regionCount());
    try std.testing.expect(wake.wakeFds().isValid());
    try expectSameEgressFiles(fixture.detachedHalf(), wake);
    try expectSameFiles(&.{fixture.artifact_fd}, &.{received.module_pack_fd});
}

test "a worker init without egress carries no egress descriptor, and the sender owns flag_egress" {
    var fixture: WorkerInitTableFixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    // A caller that sets the flag but has no egress descriptor sends none,
    // and the packet says so.
    var flagged = validMessage();
    flagged.flags |= WorkerInit.flag_egress;
    try fixture.send(&flagged, .{});
    var received = try ipc.recvWorkerInit(fixture.control_pair[1]);
    defer received.deinit();
    try std.testing.expect(!received.message.hasEgress());
    try std.testing.expect(received.egress_shared_fds.isEmpty());
    // The artifact follows the leaf directly.
    try expectSameFiles(&.{fixture.artifact_fd}, &.{received.module_pack_fd});

    // A caller that clears the flag but sends the wake descriptors gets the
    // flag on the packet.
    const plain = validMessage();
    try fixture.send(&plain, fixture.detachedHalf());
    var detached = try ipc.recvWorkerInit(fixture.control_pair[1]);
    defer detached.deinit();
    try std.testing.expect(detached.message.hasEgress());
    try std.testing.expect(detached.egress_shared_fds.wakeFds().isValid());
}

test "the sender refuses regions without a boot token, a token without regions, an incomplete set and a negative descriptor" {
    var fixture: WorkerInitTableFixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const without_token = validMessage();
    var with_token = without_token;
    with_token.boot_egress_token = bootTokenBytes();
    const half = fixture.attachedHalf();
    var no_liveness = half;
    no_liveness.liveness_fd = -1;
    var some_regions = half;
    some_regions.body_pool_data_fd = -1;

    try std.testing.expectError(error.InvalidWorkerInit, fixture.send(&without_token, half));
    try std.testing.expectError(error.InvalidWorkerInit, fixture.send(&with_token, fixture.detachedHalf()));
    try std.testing.expectError(error.InvalidWorkerInit, fixture.send(&with_token, .{}));
    try std.testing.expectError(error.InvalidEgressSharedEndpoint, fixture.send(&with_token, no_liveness));
    try std.testing.expectError(error.InvalidEgressSharedEndpoint, fixture.send(&with_token, some_regions));

    // Each part that is one descriptor long must be a descriptor.
    const fields = [_][]const u8{
        "metrics_fd",
        "completion_eventfd",
        "ingress_payload_fd",
        "ingress_payload_credit_eventfd",
        "cgroup_dir_fd",
        "module_pack_fd",
    };
    inline for (fields) |field| {
        var table_fds = fixture.fds(fixture.detachedHalf());
        @field(table_fds, field) = -1;
        try std.testing.expectError(
            error.InvalidWorkerInit,
            ipc.sendWorkerInit(fixture.control_pair[0], &without_token, table_fds),
        );
    }
    try std.testing.expectError(error.WouldBlock, ipc.recvWorkerInit(fixture.control_pair[1]));
}

test "the receiver refuses a WorkerInit packet longer or shorter than the struct" {
    var fixture: WorkerInitTableFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const message = validMessage();
    const table = fixture.noEgressTable();

    var longer: [@sizeOf(WorkerInit) + 1]u8 = undefined;
    @memcpy(longer[0..@sizeOf(WorkerInit)], std.mem.asBytes(&message));
    longer[@sizeOf(WorkerInit)] = 'x';
    const open_before = try openFdCount();
    try ipc.packet.sendWithFds(fixture.control_pair[0], &longer, &table);
    try std.testing.expectError(error.TruncatedMessage, ipc.recvWorkerInit(fixture.control_pair[1]));
    try ipc.packet.sendWithFds(fixture.control_pair[0], longer[0 .. @sizeOf(WorkerInit) - 1], &table);
    try std.testing.expectError(error.ShortRead, ipc.recvWorkerInit(fixture.control_pair[1]));
    try std.testing.expectEqual(open_before, try openFdCount());
}

/// The egress a hand-built WorkerInit announces.
const EgressShape = enum {
    /// Neither `flag_egress` nor a boot token: no egress descriptor.
    none,
    /// `flag_egress` without a boot token: the wake descriptors alone.
    wake,
    /// `flag_egress` and a boot token: the session's whole half.
    session,
};

/// One hand-built WorkerInit table and what `recvWorkerInit` makes of it.
const TableCase = struct {
    name: []const u8,
    /// Descriptors sent, a prefix of the table the case is run with.
    fd_count: usize,
    /// Null for a table the receiver takes.
    expected: ?anyerror,
};

/// Sends a WorkerInit announcing the `egress` shape and the first
/// `case.fd_count` descriptors of `table`, and checks the receiver's outcome:
/// `case.expected`, or the wake descriptors and the regions the message
/// announces. Refused or not, the receiver leaves no descriptor of its own
/// open.
fn expectTableReceived(
    fixture: *const WorkerInitTableFixture,
    egress: EgressShape,
    table: []const std.posix.fd_t,
    case: TableCase,
) !void {
    errdefer std.debug.print("worker init table case: {s} (egress {s})\n", .{ case.name, @tagName(egress) });
    var message = validMessage();
    switch (egress) {
        .none => {},
        .wake => message.flags |= WorkerInit.flag_egress,
        .session => {
            message.flags |= WorkerInit.flag_egress;
            message.boot_egress_token = bootTokenBytes();
        },
    }

    const open_before = try openFdCount();
    try fixture.sendRaw(message, table[0..case.fd_count]);
    if (case.expected) |expected| {
        try std.testing.expectError(expected, ipc.recvWorkerInit(fixture.control_pair[1]));
    } else {
        var received = try ipc.recvWorkerInit(fixture.control_pair[1]);
        defer received.deinit();
        switch (egress) {
            .none => try std.testing.expect(received.egress_shared_fds.isEmpty()),
            .wake, .session => try std.testing.expect(received.egress_shared_fds.wakeFds().isValid()),
        }
        const regions: usize = if (egress == .session) egress_shared.region_fd_count else 0;
        try std.testing.expectEqual(regions, received.egress_shared_fds.regionCount());
        try std.testing.expect(received.module_pack_fd >= 0);
    }
    try std.testing.expectEqual(open_before, try openFdCount());
}

test "the receiver reads the descriptor table the boot token and flag_egress announce, and names the first missing part" {
    var fixture: WorkerInitTableFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const attached_table = fixture.attachedTable();
    const detached_table = fixture.detachedTable();
    const no_egress_table = fixture.noEgressTable();
    const base = WorkerInitTableFixture.base_fd_count;
    const attached = WorkerInitTableFixture.attached_fd_count;
    const detached = WorkerInitTableFixture.detached_fd_count;
    const no_egress = WorkerInitTableFixture.no_egress_fd_count;
    const wake = egress_shared.wake_fd_count;

    const no_egress_cases = [_]TableCase{
        .{ .name = "nothing", .fd_count = 0, .expected = error.MissingMetricsFd },
        .{ .name = "no completion eventfd", .fd_count = 1, .expected = error.MissingCompletionEventFd },
        .{ .name = "no payload memfd", .fd_count = 2, .expected = error.MissingIngressPayloadFd },
        .{ .name = "no credit eventfd", .fd_count = 3, .expected = error.MissingIngressPayloadCreditFd },
        .{ .name = "no leaf", .fd_count = 4, .expected = error.MissingCgroupDirFd },
        .{ .name = "no artifact", .fd_count = base, .expected = error.MissingModulePackFd },
        .{ .name = "whole", .fd_count = no_egress, .expected = null },
    };
    for (no_egress_cases) |case|
        try expectTableReceived(&fixture, .none, &no_egress_table, case);

    const detached_cases = [_]TableCase{
        .{ .name = "no leaf", .fd_count = 4, .expected = error.MissingCgroupDirFd },
        .{ .name = "wake cut", .fd_count = base + wake - 2, .expected = error.MissingEgressSharedFd },
        .{ .name = "no artifact", .fd_count = base + wake, .expected = error.MissingModulePackFd },
        .{ .name = "whole", .fd_count = detached, .expected = null },
    };
    for (detached_cases) |case|
        try expectTableReceived(&fixture, .wake, &detached_table, case);

    const attached_cases = [_]TableCase{
        .{ .name = "half cut", .fd_count = attached - 3, .expected = error.MissingEgressSharedFd },
        .{ .name = "no artifact", .fd_count = attached - 1, .expected = error.MissingModulePackFd },
        .{ .name = "whole", .fd_count = attached, .expected = null },
    };
    for (attached_cases) |case|
        try expectTableReceived(&fixture, .session, &attached_table, case);

    // The token and the session's regions come together or not at all, and
    // so do `flag_egress` and the wake descriptors; a descriptor past the
    // artifact belongs to no part.
    try expectTableReceived(&fixture, .wake, &attached_table, .{
        .name = "the regions without a token",
        .fd_count = attached,
        .expected = error.InvalidFdCount,
    });
    try expectTableReceived(&fixture, .session, &detached_table, .{
        .name = "a token without the regions",
        .fd_count = detached,
        .expected = error.MissingEgressSharedFd,
    });
    try expectTableReceived(&fixture, .none, &detached_table, .{
        .name = "wake descriptors without flag_egress",
        .fd_count = detached,
        .expected = error.InvalidFdCount,
    });
    try expectTableReceived(&fixture, .wake, &no_egress_table, .{
        .name = "flag_egress without the wake descriptors",
        .fd_count = no_egress,
        .expected = error.MissingEgressSharedFd,
    });
}

test "worker init carries every field through the init socket" {
    var fixture: WorkerInitTableFixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var message = WorkerInit.init(512 * 1024 * 1024);
    message.tmpfs_size_bytes = 64 * 1024 * 1024;
    message.init_deadline_mono_ns = 123_456_789;
    message.request_cpu_budget_ns = 50 * std.time.ns_per_ms;
    message.unowned_time_limit_ns = 1_500 * std.time.ns_per_ms;
    message.flags = WorkerInit.flag_isolate_realm | WorkerInit.flag_bench_handler;
    message.boot_egress_token = bootTokenBytes();
    try fixture.send(&message, fixture.attachedHalf());

    var received = try ipc.recvWorkerInit(fixture.control_pair[1]);
    defer received.deinit();
    try received.message.validate();
    var expected = message;
    expected.flags |= WorkerInit.flag_egress;
    try std.testing.expectEqual(expected, received.message);
    try std.testing.expect(received.message.isolatesRealms());
    try std.testing.expect(received.message.recordsBenchHandler());
}

test "worker init starts with no flag, no boot token and no deadline, bounds tmpfs by memory, and carries only what varies" {
    const message = WorkerInit.init(1024);
    try std.testing.expectEqual(@as(u64, 1024), message.memory_limit_bytes);
    try std.testing.expectEqual(@as(u64, 1024), message.tmpfs_size_bytes);
    try std.testing.expectEqual(
        WorkerInit.default_tmpfs_size_bytes,
        WorkerInit.init(WorkerInit.default_tmpfs_size_bytes * 2).tmpfs_size_bytes,
    );
    try std.testing.expectEqual(@as(u32, 0), message.flags);
    try std.testing.expect(egress_token.isNone(&message.boot_egress_token));
    try std.testing.expectEqual(@as(u64, 0), message.request_cpu_budget_ns);
    try std.testing.expectEqual(WorkerInit.default_unowned_time_limit_ns, message.unowned_time_limit_ns);
    // `validate` refuses a zero deadline, so every sender sets one.
    try std.testing.expectEqual(@as(u64, 0), message.init_deadline_mono_ns);
    try std.testing.expectError(error.InvalidWorkerInitDeadline, message.validate());

    // The limits that never vary are constants both ends compile
    // (`common/limits/worker.zig`): no runtime options, CPU quota, route
    // table length or sandbox switch travels.
    try std.testing.expectEqual(@as(usize, 104), @sizeOf(WorkerInit));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(WorkerInit, "boot_egress_token"));
    try std.testing.expectEqual(@as(usize, 80), @offsetOf(WorkerInit, "init_deadline_mono_ns"));
    try std.testing.expectEqual(@as(usize, 96), @offsetOf(WorkerInit, "unowned_time_limit_ns"));
    try std.testing.expect(!@hasDecl(ipc, "WorkerRuntimeBootOptions"));
    inline for (.{ "runtime", "cpu_max_cores", "route_table_len", "_reserved0" }) |field|
        try std.testing.expect(!@hasField(WorkerInit, field));
    inline for (.{ "flag_isolated_network", "flag_deny_direct_egress", "flag_serves_routes" }) |decl|
        try std.testing.expect(!@hasDecl(WorkerInit, decl));
}

test "worker init refuses a tmpfs, CPU budget or unowned limit outside its bounds, a boot token without flag_egress and an unknown flag" {
    var message = validMessage();
    try message.validate();

    message.memory_limit_bytes = 0;
    try std.testing.expectError(error.ZeroMemoryLimit, message.validate());
    message.memory_limit_bytes = 64;

    message.tmpfs_size_bytes = 0;
    try std.testing.expectError(error.InvalidWorkerInitTmpfsSize, message.validate());
    message.tmpfs_size_bytes = 65;
    try std.testing.expectError(error.InvalidWorkerInitTmpfsSize, message.validate());
    message.tmpfs_size_bytes = 64;
    try message.validate();

    // 0 is no budget; the bound itself passes and one past it fails.
    message.request_cpu_budget_ns = WorkerInit.request_cpu_budget_ns_max;
    try message.validate();
    message.request_cpu_budget_ns = WorkerInit.request_cpu_budget_ns_max + 1;
    try std.testing.expectError(error.InvalidWorkerInitTimeLimit, message.validate());
    message.request_cpu_budget_ns = 0;

    // Unowned JavaScript always has a limit.
    message.unowned_time_limit_ns = 0;
    try std.testing.expectError(error.InvalidWorkerInitTimeLimit, message.validate());
    message.unowned_time_limit_ns = WorkerInit.unowned_time_limit_ns_max;
    try message.validate();
    message.unowned_time_limit_ns = WorkerInit.unowned_time_limit_ns_max + 1;
    try std.testing.expectError(error.InvalidWorkerInitTimeLimit, message.validate());
    message.unowned_time_limit_ns = WorkerInit.default_unowned_time_limit_ns;

    // A boot token is spent through egress descriptors the flag announces.
    message.boot_egress_token = bootTokenBytes();
    try std.testing.expectError(error.InvalidWorkerInitFlags, message.validate());
    message.flags |= WorkerInit.flag_egress;
    try message.validate();
    message.boot_egress_token = egress_token.none;
    try message.validate();

    // Every flag the struct names passes; any other bit fails.
    message.flags = WorkerInit.valid_flags;
    try message.validate();
    message.flags |= 1 << 3;
    try std.testing.expectError(error.InvalidWorkerInitFlags, message.validate());
    message.flags = 1 << 31;
    try std.testing.expectError(error.InvalidWorkerInitFlags, message.validate());
}

test "a fork request carries exactly the leaf, as a new descriptor of the same file" {
    const pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);
    var leaf = std.testing.tmpDir(.{});
    defer leaf.cleanup();

    try ipc.sendForkRequest(pair[0], 7, leaf.dir.fd);
    var received = try ipc.recvForkRequest(pair[1]);
    defer received.deinit();
    try std.testing.expectEqual(@as(u64, 7), received.message.fork_job_id);
    try expectSameFiles(&.{leaf.dir.fd}, &.{received.cgroup_dir_fd});

    const taken = received.takeCgroupDirFd();
    defer std.posix.close(taken);
    try std.testing.expectEqual(@as(std.posix.fd_t, -1), received.takeCgroupDirFd());
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(ipc.ForkRequest));
    try std.testing.expect(!@hasDecl(ipc.ForkRequest, "Flags"));
}

test "the fork request receiver refuses no descriptor, two descriptors and a nonzero reserved field, closing what arrived" {
    const pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);
    var leaf = std.testing.tmpDir(.{});
    defer leaf.cleanup();

    const open_before = try openFdCount();
    // A fork request without a leaf is no launch's shape: a worker is born
    // inside its cgroup.
    const request = ipc.ForkRequest.init(11);
    try ipc.packet.sendWithFds(pair[0], std.mem.asBytes(&request), &.{});
    try std.testing.expectError(error.InvalidFdCount, ipc.recvForkRequest(pair[1]));

    try ipc.packet.sendWithFds(pair[0], std.mem.asBytes(&request), &.{ leaf.dir.fd, leaf.dir.fd });
    try std.testing.expectError(error.InvalidFdCount, ipc.recvForkRequest(pair[1]));

    var reserved = request;
    reserved._reserved0 = 1;
    try ipc.packet.sendWithFds(pair[0], std.mem.asBytes(&reserved), &.{leaf.dir.fd});
    try std.testing.expectError(error.InvalidForkRequest, ipc.recvForkRequest(pair[1]));

    try ipc.packet.sendWithFds(pair[0], std.mem.asBytes(&request)[0 .. @sizeOf(ipc.ForkRequest) - 1], &.{leaf.dir.fd});
    try std.testing.expectError(error.ShortRead, ipc.recvForkRequest(pair[1]));
    try std.testing.expectEqual(open_before, try openFdCount());
}

test "a fork failed reply decodes as a transient failure without descriptors" {
    const pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);

    try ipc.sendForkFailed(pair[0], 21);
    try std.testing.expectError(error.ForkTransientFailure, ipc.recvForkReply(pair[1]));
}

test "the init outcome refuses an unknown failure reason, 7 among them" {
    const pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);

    for ([_]u32{ 7, 999 }) |reason| {
        const failed = ipc.WorkerInitFailed{
            .kind = @intFromEnum(ipc.MessageKind.worker_init_failed),
            .reason = reason,
        };
        try ipc.packet.sendExact(pair[0], std.mem.asBytes(&failed));
        try std.testing.expectError(error.InvalidWorkerInitFailedReason, ipc.recvInitOutcome(pair[1]));
    }

    try ipc.sendWorkerInitFailed(pair[0], .init_deadline_exceeded);
    try std.testing.expectEqual(
        ipc.InitOutcome{ .failed = .init_deadline_exceeded },
        try ipc.recvInitOutcome(pair[1]),
    );
    try ipc.sendWorkerReady(pair[0]);
    try std.testing.expectEqual(ipc.InitOutcome.ready, try ipc.recvInitOutcome(pair[1]));
}

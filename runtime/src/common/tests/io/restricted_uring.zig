//! The worker's restricted io_uring contract in `restricted_uring.zig`: the
//! user_data layout, including the control slot's read and write polls
//! decoding as different kinds, the restriction allowlist that admits only
//! the ring-enable registration and POLL_ADD on a fixed file, the fixed-file
//! slot order, `validateWorkerFixedFiles` against real socket pairs,
//! eventfds and a timerfd, with the egress slots filled for a worker with a
//! network grant and empty for one without, the kernel's registration of a
//! ring whose egress slots are empty, and the two errors that name a ring
//! setup the kernel refuses (`initRingParams`). Creating and enabling the
//! restricted ring for a worker is covered by the scheduler tests in the
//! `worker-test` lane.

const std = @import("std");
const common_io = @import("collo_common_io");
const linux = std.os.linux;

const restricted_uring = common_io.restricted_uring;

test "restricted worker io_uring user data round trips" {
    const encoded = try (restricted_uring.UserData{ .kind = .egress_completion_poll, .generation = 7, .value = 42 }).pack();
    const decoded = try restricted_uring.UserData.unpack(encoded);
    try std.testing.expectEqual(restricted_uring.OperationKind.egress_completion_poll, decoded.kind);
    try std.testing.expectEqual(@as(u64, 7), decoded.generation);
    try std.testing.expectEqual(@as(u64, 42), decoded.value);
    try std.testing.expectError(error.InvalidUserDataTag, restricted_uring.UserData.unpack(0));
}

test "restricted worker io_uring user data round trips the control write poll as its own kind" {
    // The largest generation sets every bit of the field just below the
    // kind, so a kind that overlapped it would decode as another kind.
    const generation = restricted_uring.max_user_data_generation;
    const write_poll = try (restricted_uring.UserData{ .kind = .control_writable_poll, .generation = generation }).pack();
    const read_poll = try (restricted_uring.UserData{ .kind = .control_poll, .generation = generation }).pack();
    try std.testing.expect(write_poll != read_poll);

    const decoded = try restricted_uring.UserData.unpack(write_poll);
    try std.testing.expectEqual(restricted_uring.OperationKind.control_writable_poll, decoded.kind);
    try std.testing.expectEqual(generation, decoded.generation);
    try std.testing.expectEqual(@as(u64, 0), decoded.value);
    try std.testing.expectEqual(restricted_uring.OperationKind.control_poll, (try restricted_uring.UserData.unpack(read_poll)).kind);
}

test "restricted worker io_uring exposes only readiness opcodes" {
    const restrictions = restricted_uring.workerRestrictions();
    try std.testing.expectEqual(restricted_uring.worker_restriction_count, restrictions.len);
    try std.testing.expectEqual(@as(usize, 4), restrictions.len);
    try std.testing.expectEqual(restricted_uring.RestrictionOpcode.register_op, restrictions[0].opcode);
    try std.testing.expectEqual(@as(u8, @intCast(@intFromEnum(linux.IORING_REGISTER.REGISTER_ENABLE_RINGS))), restrictions[0].arg.register_op);
    try std.testing.expectEqual(restricted_uring.RestrictionOpcode.sqe_op, restrictions[1].opcode);
    try std.testing.expectEqual(@as(u8, @intFromEnum(linux.IORING_OP.POLL_ADD)), restrictions[1].arg.sqe_op);
    try std.testing.expectEqual(restricted_uring.RestrictionOpcode.sqe_flags_allowed, restrictions[2].opcode);
    try std.testing.expectEqual(@as(u8, @intCast(linux.IOSQE_FIXED_FILE)), restrictions[2].arg.sqe_flags);
    try std.testing.expectEqual(restricted_uring.RestrictionOpcode.sqe_flags_required, restrictions[3].opcode);
    try std.testing.expectEqual(@as(u8, @intCast(linux.IOSQE_FIXED_FILE)), restrictions[3].arg.sqe_flags);
}

test "restricted worker fixed-file table has no gateway or network slot" {
    try std.testing.expectEqual(@as(usize, 7), restricted_uring.FixedFile.count);
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(restricted_uring.FixedFile.control));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(restricted_uring.FixedFile.wakeup));
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(restricted_uring.FixedFile.egress_completion));
    try std.testing.expectEqual(@as(u32, 3), @intFromEnum(restricted_uring.FixedFile.egress_liveness));
    try std.testing.expectEqual(@as(u32, 4), @intFromEnum(restricted_uring.FixedFile.timer));
    try std.testing.expectEqual(@as(u32, 5), @intFromEnum(restricted_uring.FixedFile.ingress_payload_credit));
    try std.testing.expectEqual(@as(u32, 6), @intFromEnum(restricted_uring.FixedFile.fs_fault));
}

test "restricted worker fixed-file validation checks fd types" {
    var control_pair: [2]std.posix.fd_t = undefined;
    const socketpair_rc = linux.socketpair(
        std.posix.AF.UNIX,
        std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC,
        0,
        &control_pair,
    );
    try expectLinuxSuccess(socketpair_rc);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    const wakeup_fd = try std.posix.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    defer std.posix.close(wakeup_fd);
    const completion_fd = try std.posix.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    defer std.posix.close(completion_fd);
    const liveness_fd = try std.posix.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    defer std.posix.close(liveness_fd);
    const ingress_payload_credit_fd = try std.posix.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    defer std.posix.close(ingress_payload_credit_fd);
    const timer_fd = try std.posix.timerfd_create(.MONOTONIC, .{
        .CLOEXEC = true,
        .NONBLOCK = true,
    });
    defer std.posix.close(timer_fd);

    var fs_fault_pair: [2]std.posix.fd_t = undefined;
    const fs_fault_rc = linux.socketpair(
        std.posix.AF.UNIX,
        std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC,
        0,
        &fs_fault_pair,
    );
    try expectLinuxSuccess(fs_fault_rc);
    defer std.posix.close(fs_fault_pair[0]);
    defer std.posix.close(fs_fault_pair[1]);

    var fixed_files = [_]std.posix.fd_t{
        control_pair[0],
        wakeup_fd,
        completion_fd,
        liveness_fd,
        timer_fd,
        ingress_payload_credit_fd,
        fs_fault_pair[0],
    };
    try restricted_uring.validateWorkerFixedFiles(&fixed_files, .granted);

    fixed_files[@intFromEnum(restricted_uring.FixedFile.control)] = wakeup_fd;
    try std.testing.expectError(error.InvalidWorkerRingFixedFile, restricted_uring.validateWorkerFixedFiles(&fixed_files, .granted));
    fixed_files[@intFromEnum(restricted_uring.FixedFile.control)] = control_pair[0];

    fixed_files[@intFromEnum(restricted_uring.FixedFile.wakeup)] = control_pair[1];
    try std.testing.expectError(error.InvalidWorkerRingFixedFile, restricted_uring.validateWorkerFixedFiles(&fixed_files, .granted));
    fixed_files[@intFromEnum(restricted_uring.FixedFile.wakeup)] = wakeup_fd;

    fixed_files[@intFromEnum(restricted_uring.FixedFile.egress_completion)] = timer_fd;
    try std.testing.expectError(error.InvalidWorkerRingFixedFile, restricted_uring.validateWorkerFixedFiles(&fixed_files, .granted));
    fixed_files[@intFromEnum(restricted_uring.FixedFile.egress_completion)] = completion_fd;

    fixed_files[@intFromEnum(restricted_uring.FixedFile.ingress_payload_credit)] = timer_fd;
    try std.testing.expectError(error.InvalidWorkerRingFixedFile, restricted_uring.validateWorkerFixedFiles(&fixed_files, .granted));
    fixed_files[@intFromEnum(restricted_uring.FixedFile.ingress_payload_credit)] = ingress_payload_credit_fd;

    fixed_files[@intFromEnum(restricted_uring.FixedFile.timer)] = liveness_fd;
    try std.testing.expectError(error.InvalidWorkerRingFixedFile, restricted_uring.validateWorkerFixedFiles(&fixed_files, .granted));
    fixed_files[@intFromEnum(restricted_uring.FixedFile.timer)] = completion_fd;
    try std.testing.expectError(error.InvalidWorkerRingFixedFile, restricted_uring.validateWorkerFixedFiles(&fixed_files, .granted));
    fixed_files[@intFromEnum(restricted_uring.FixedFile.timer)] = timer_fd;

    fixed_files[@intFromEnum(restricted_uring.FixedFile.fs_fault)] = wakeup_fd;
    try std.testing.expectError(error.InvalidWorkerRingFixedFile, restricted_uring.validateWorkerFixedFiles(&fixed_files, .granted));
    fixed_files[@intFromEnum(restricted_uring.FixedFile.fs_fault)] = fs_fault_pair[0];
    try restricted_uring.validateWorkerFixedFiles(&fixed_files, .granted);

    // A granted worker never has an empty egress slot.
    fixed_files[@intFromEnum(restricted_uring.FixedFile.egress_liveness)] = restricted_uring.empty_slot;
    try std.testing.expectError(error.InvalidWorkerRingFixedFile, restricted_uring.validateWorkerFixedFiles(&fixed_files, .granted));
}

test "a worker without a network grant has empty egress slots and nothing else empty" {
    var fixture: SlotFixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var fixed_files = fixture.files();
    fixed_files[@intFromEnum(restricted_uring.FixedFile.egress_completion)] = restricted_uring.empty_slot;
    fixed_files[@intFromEnum(restricted_uring.FixedFile.egress_liveness)] = restricted_uring.empty_slot;
    try restricted_uring.validateWorkerFixedFiles(&fixed_files, .none);

    // An egress descriptor in a worker that has no grant is refused, as is
    // an empty slot anywhere else.
    fixed_files[@intFromEnum(restricted_uring.FixedFile.egress_completion)] = fixture.spare_eventfd;
    try std.testing.expectError(error.InvalidWorkerRingFixedFile, restricted_uring.validateWorkerFixedFiles(&fixed_files, .none));
    fixed_files[@intFromEnum(restricted_uring.FixedFile.egress_completion)] = restricted_uring.empty_slot;
    fixed_files[@intFromEnum(restricted_uring.FixedFile.wakeup)] = restricted_uring.empty_slot;
    try std.testing.expectError(error.InvalidWorkerRingFixedFile, restricted_uring.validateWorkerFixedFiles(&fixed_files, .none));
}

test "the kernel registers a worker ring whose egress slots are empty and polls its other slots" {
    var fixture: SlotFixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var fixed_files = fixture.files();
    fixed_files[@intFromEnum(restricted_uring.FixedFile.egress_completion)] = restricted_uring.empty_slot;
    fixed_files[@intFromEnum(restricted_uring.FixedFile.egress_liveness)] = restricted_uring.empty_slot;
    var ring = try restricted_uring.WorkerRing.init(.{ .files = fixed_files });
    defer ring.deinit();

    // A wake through the eventfd in the wakeup slot completes its poll.
    try ring.pollFixed(.{ .kind = .wakeup_poll }, .wakeup, linux.POLL.IN);
    _ = try ring.submit();
    const one: u64 = 1;
    _ = try std.posix.write(fixture.wakeup_fd, std.mem.asBytes(&one));
    var completions: [4]restricted_uring.Completion = undefined;
    const count = try ring.wait(&completions, 1);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(restricted_uring.OperationKind.wakeup_poll, completions[0].user_data.kind);
    try std.testing.expect(completions[0].res >= 0);
}

test "a ring setup the kernel refuses for a flag it does not know fails as an unsupported kernel, never as another error" {
    // No kernel defines setup flag bit 31, so the setup fails with EINVAL,
    // the same refusal a kernel gives for a flag it predates.
    var params = std.mem.zeroInit(linux.io_uring_params, .{ .flags = @as(u32, 1) << 31 });
    if (restricted_uring.initRingParams(4, &params)) |ring| {
        var unexpected = ring;
        unexpected.deinit();
        return error.TestUnexpectedRing;
    } else |err| switch (err) {
        error.UnsupportedKernel => {},
        // The `io_uring_disabled` sysctl or a seccomp filter refuses every
        // setup before the kernel reads its flags; the caller skips on it
        // the same way.
        error.PermissionDenied => {},
        else => return err,
    }
}

/// One descriptor of the right kind for every slot of a worker ring, plus a
/// spare eventfd.
const SlotFixture = struct {
    control_pair: [2]std.posix.fd_t,
    fs_fault_pair: [2]std.posix.fd_t,
    wakeup_fd: std.posix.fd_t,
    completion_fd: std.posix.fd_t,
    liveness_pipe: [2]std.posix.fd_t,
    timer_fd: std.posix.fd_t,
    ingress_payload_credit_fd: std.posix.fd_t,
    spare_eventfd: std.posix.fd_t,

    fn init(self: *SlotFixture) !void {
        try expectLinuxSuccess(linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC, 0, &self.control_pair));
        errdefer closeAll(&self.control_pair);
        try expectLinuxSuccess(linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC, 0, &self.fs_fault_pair));
        errdefer closeAll(&self.fs_fault_pair);
        self.wakeup_fd = try std.posix.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        errdefer std.posix.close(self.wakeup_fd);
        self.completion_fd = try std.posix.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        errdefer std.posix.close(self.completion_fd);
        self.liveness_pipe = try std.posix.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
        errdefer closeAll(&self.liveness_pipe);
        self.timer_fd = try std.posix.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true, .NONBLOCK = true });
        errdefer std.posix.close(self.timer_fd);
        self.ingress_payload_credit_fd = try std.posix.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        errdefer std.posix.close(self.ingress_payload_credit_fd);
        self.spare_eventfd = try std.posix.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    }

    fn deinit(self: *SlotFixture) void {
        closeAll(&self.control_pair);
        closeAll(&self.fs_fault_pair);
        std.posix.close(self.wakeup_fd);
        std.posix.close(self.completion_fd);
        closeAll(&self.liveness_pipe);
        std.posix.close(self.timer_fd);
        std.posix.close(self.ingress_payload_credit_fd);
        std.posix.close(self.spare_eventfd);
    }

    /// Every slot filled, in `FixedFile` order.
    fn files(self: *const SlotFixture) [restricted_uring.FixedFile.count]std.posix.fd_t {
        return .{
            self.control_pair[0],
            self.wakeup_fd,
            self.completion_fd,
            self.liveness_pipe[0],
            self.timer_fd,
            self.ingress_payload_credit_fd,
            self.fs_fault_pair[0],
        };
    }

    fn closeAll(fds: []const std.posix.fd_t) void {
        for (fds) |fd|
            std.posix.close(fd);
    }
};

fn expectLinuxSuccess(rc: usize) !void {
    return switch (std.os.linux.E.init(rc)) {
        .SUCCESS => {},
        else => error.SystemCallFailed,
    };
}

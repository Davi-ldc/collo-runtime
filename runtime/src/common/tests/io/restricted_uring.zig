//! The worker's restricted io_uring contract in `restricted_uring.zig`: the
//! user_data layout, including the control slot's read and write polls
//! decoding as different kinds, the restriction allowlist that admits only
//! the ring-enable registration and POLL_ADD on a fixed file, the fixed-file
//! slot order, and `validateWorkerFixedFiles` against real socket pairs,
//! eventfds and a timerfd. Creating and enabling the restricted ring is
//! covered by the scheduler tests in the `worker-test` lane.

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
    try restricted_uring.validateWorkerFixedFiles(&fixed_files);

    fixed_files[@intFromEnum(restricted_uring.FixedFile.control)] = wakeup_fd;
    try std.testing.expectError(error.InvalidWorkerRingFixedFile, restricted_uring.validateWorkerFixedFiles(&fixed_files));
    fixed_files[@intFromEnum(restricted_uring.FixedFile.control)] = control_pair[0];

    fixed_files[@intFromEnum(restricted_uring.FixedFile.wakeup)] = control_pair[1];
    try std.testing.expectError(error.InvalidWorkerRingFixedFile, restricted_uring.validateWorkerFixedFiles(&fixed_files));
    fixed_files[@intFromEnum(restricted_uring.FixedFile.wakeup)] = wakeup_fd;

    fixed_files[@intFromEnum(restricted_uring.FixedFile.egress_completion)] = timer_fd;
    try std.testing.expectError(error.InvalidWorkerRingFixedFile, restricted_uring.validateWorkerFixedFiles(&fixed_files));
    fixed_files[@intFromEnum(restricted_uring.FixedFile.egress_completion)] = completion_fd;

    fixed_files[@intFromEnum(restricted_uring.FixedFile.ingress_payload_credit)] = timer_fd;
    try std.testing.expectError(error.InvalidWorkerRingFixedFile, restricted_uring.validateWorkerFixedFiles(&fixed_files));
    fixed_files[@intFromEnum(restricted_uring.FixedFile.ingress_payload_credit)] = ingress_payload_credit_fd;

    fixed_files[@intFromEnum(restricted_uring.FixedFile.timer)] = liveness_fd;
    try std.testing.expectError(error.InvalidWorkerRingFixedFile, restricted_uring.validateWorkerFixedFiles(&fixed_files));
    fixed_files[@intFromEnum(restricted_uring.FixedFile.timer)] = completion_fd;
    try std.testing.expectError(error.InvalidWorkerRingFixedFile, restricted_uring.validateWorkerFixedFiles(&fixed_files));
    fixed_files[@intFromEnum(restricted_uring.FixedFile.timer)] = timer_fd;

    fixed_files[@intFromEnum(restricted_uring.FixedFile.fs_fault)] = wakeup_fd;
    try std.testing.expectError(error.InvalidWorkerRingFixedFile, restricted_uring.validateWorkerFixedFiles(&fixed_files));
    fixed_files[@intFromEnum(restricted_uring.FixedFile.fs_fault)] = fs_fault_pair[0];
    try restricted_uring.validateWorkerFixedFiles(&fixed_files);
}

fn expectLinuxSuccess(rc: usize) !void {
    return switch (std.os.linux.E.init(rc)) {
        .SUCCESS => {},
        else => error.SystemCallFailed,
    };
}

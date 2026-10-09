//! The gateway loop's readiness ring (`egress/gateway/readiness.zig`): the user_data encoding that
//! tells poll and removal completions apart, the restriction set the ring registers, the removal
//! results taken as benign, a removed worker's polls, which stay in the op table, marked closing,
//! until the kernel posts their final completions, so no op id is reused while the kernel still
//! holds a poll under it, and a worker's liveness pipe, which wakes the loop on its hang-up and
//! never on a byte the worker wrote into it. The tests that build a ring skip when the kernel or
//! the sandbox refuses io_uring. The loop that drives the ring is covered by local-e2e, which
//! spawns real gateways. Lane: egress-gateway-test.

const std = @import("std");
const linux = std.os.linux;
const gateway = @import("collo_egress_gateway");
const restricted_uring = @import("collo_common_io").restricted_uring;

const readiness = gateway.readiness;

test "egress gateway readiness user data separates poll and cancel completions" {
    const UserData = readiness.testing.UserDataForTest;
    const CompletionKind = readiness.testing.CompletionKindForTest;

    const poll = try (UserData{ .kind = .poll, .op_id = 42 }).pack();
    const decoded_poll = try UserData.unpack(poll);
    try std.testing.expectEqual(CompletionKind.poll, decoded_poll.kind);
    try std.testing.expectEqual(@as(u64, 42), decoded_poll.op_id);

    const cancel = try (UserData{ .kind = .cancel, .op_id = 42 }).pack();
    const decoded_cancel = try UserData.unpack(cancel);
    try std.testing.expectEqual(CompletionKind.cancel, decoded_cancel.kind);
    try std.testing.expectEqual(@as(u64, 42), decoded_cancel.op_id);
    try std.testing.expect(poll != cancel);

    try std.testing.expectError(
        error.InvalidEgressGatewayReadinessTag,
        UserData.unpack(0),
    );
    try std.testing.expectError(
        error.InvalidEgressGatewayReadinessOpId,
        (UserData{ .kind = .poll, .op_id = 0 }).pack(),
    );
}

test "egress gateway readiness ring allows poll add, remove, and timeout" {
    const restrictions = readiness.gatewayReadinessRestrictions();

    try std.testing.expectEqual(readiness.gateway_readiness_restriction_count, restrictions.len);
    try std.testing.expectEqual(restricted_uring.RestrictionOpcode.register_op, restrictions[0].opcode);
    try std.testing.expectEqual(
        @as(u8, @intCast(@intFromEnum(linux.IORING_REGISTER.REGISTER_ENABLE_RINGS))),
        restrictions[0].arg.register_op,
    );
    try std.testing.expectEqual(restricted_uring.RestrictionOpcode.sqe_op, restrictions[1].opcode);
    try std.testing.expectEqual(
        @as(u8, @intCast(@intFromEnum(linux.IORING_OP.POLL_ADD))),
        restrictions[1].arg.sqe_op,
    );
    try std.testing.expectEqual(restricted_uring.RestrictionOpcode.sqe_op, restrictions[2].opcode);
    try std.testing.expectEqual(
        @as(u8, @intCast(@intFromEnum(linux.IORING_OP.POLL_REMOVE))),
        restrictions[2].arg.sqe_op,
    );
    try std.testing.expectEqual(restricted_uring.RestrictionOpcode.sqe_op, restrictions[3].opcode);
    try std.testing.expectEqual(
        @as(u8, @intCast(@intFromEnum(linux.IORING_OP.TIMEOUT))),
        restrictions[3].arg.sqe_op,
    );
}

test "egress gateway readiness keeps stale worker ops until terminal poll cqes" {
    const control_fd = try std.posix.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    defer std.posix.close(control_fd);
    const command_fd = try std.posix.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    defer std.posix.close(command_fd);
    const liveness_fd = try std.posix.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    defer std.posix.close(liveness_fd);

    var backend = readiness.Backend.init(std.testing.allocator, 0, 1) catch |err| switch (err) {
        error.UnsupportedKernel, error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer backend.deinit();

    const shards: [0]readiness.ShardFd = .{};
    const workers = [_]readiness.WorkerFd{.{
        .session_id = 7,
        .command_eventfd = command_fd,
        .liveness_fd = liveness_fd,
    }};
    try backend.arm(control_fd, &shards, &workers);

    try std.testing.expectEqual(@as(usize, 1), readiness.testing.workerArmCount(&backend));
    try std.testing.expectEqual(@as(usize, 2), readiness.testing.workerArmedOpCount(&backend, 7));
    try std.testing.expectEqual(@as(usize, 3), readiness.testing.opCount(&backend));

    const no_workers: [0]readiness.WorkerFd = .{};
    try backend.pruneWorkers(&no_workers);

    try std.testing.expectEqual(@as(usize, 0), readiness.testing.workerArmCount(&backend));
    try std.testing.expectEqual(@as(usize, 0), readiness.testing.workerArmedOpCount(&backend, 7));
    try std.testing.expectEqual(@as(usize, 2), readiness.testing.workerClosingOpCount(&backend, 7));
    try std.testing.expectEqual(@as(usize, 3), readiness.testing.opCount(&backend));

    // The removals' completions and the closing polls' final completions yield
    // no `Ready`, and each wait returns within `readiness.wait_tick_ns`.
    var ready: [4]readiness.Ready = undefined;
    var iterations: usize = 0;
    while (readiness.testing.workerClosingOpCount(&backend, 7) != 0) : (iterations += 1) {
        try std.testing.expect(iterations < 8);
        const ready_count = try backend.wait(&ready);
        try std.testing.expectEqual(@as(usize, 0), ready_count);
    }

    try std.testing.expectEqual(@as(usize, 1), readiness.testing.opCount(&backend));
}

test "a byte a worker writes into the pipe the gateway watches wakes nothing, and the pipe's hang-up still does" {
    const control_fd = try std.posix.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    defer std.posix.close(control_fd);
    const command_fd = try std.posix.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    defer std.posix.close(command_fd);
    const pipe = try std.posix.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
    defer std.posix.close(pipe[0]);
    var write_end: ?std.posix.fd_t = pipe[1];
    defer if (write_end) |fd| std.posix.close(fd);

    var backend = readiness.Backend.init(std.testing.allocator, 0, 1) catch |err| switch (err) {
        error.UnsupportedKernel, error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer backend.deinit();

    // The worker holds the write end, and nothing in the gateway reads the pipe.
    _ = try std.posix.write(pipe[1], "x");
    const shards: [0]readiness.ShardFd = .{};
    const workers = [_]readiness.WorkerFd{.{
        .session_id = 7,
        .command_eventfd = command_fd,
        .liveness_fd = pipe[0],
    }};
    try backend.arm(control_fd, &shards, &workers);

    // Only the tick ends each wait; the readable pipe completes no poll.
    var ready: [4]readiness.Ready = undefined;
    for (0..2) |_| {
        try std.testing.expectEqual(@as(usize, 0), try backend.wait(&ready));
        try backend.arm(control_fd, &shards, &workers);
    }

    std.posix.close(pipe[1]);
    write_end = null;
    const count = try backend.wait(&ready);
    try std.testing.expectEqual(@as(usize, 1), count);
    switch (ready[0]) {
        .worker => |worker| {
            try std.testing.expectEqual(@as(u64, 7), worker.session_id);
            try std.testing.expectEqual(readiness.WorkerSource.liveness, worker.source);
            try std.testing.expect((worker.revents & std.posix.POLL.HUP) != 0);
        },
        else => return error.TestUnexpectedReadiness,
    }
}

test "egress gateway readiness treats cancel races as benign" {
    try std.testing.expect(readiness.testing.cancelResultIsBenign(0));
    try std.testing.expect(readiness.testing.cancelResultIsBenign(
        -@as(i32, @intFromEnum(linux.E.NOENT)),
    ));
    try std.testing.expect(readiness.testing.cancelResultIsBenign(
        -@as(i32, @intFromEnum(linux.E.ALREADY)),
    ));
    try std.testing.expect(readiness.testing.cancelResultIsBenign(
        -@as(i32, @intFromEnum(linux.E.CANCELED)),
    ));
    try std.testing.expect(!readiness.testing.cancelResultIsBenign(
        -@as(i32, @intFromEnum(linux.E.INVAL)),
    ));
}

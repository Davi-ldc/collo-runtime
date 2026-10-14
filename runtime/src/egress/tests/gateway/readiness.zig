//! The gateway loop's readiness ring (`egress/gateway/readiness.zig`): the restriction set the
//! ring registers; polls that follow their targets, added when a shard starts or a session
//! attaches and removed when the session goes; a completion that re-arms only its own target on
//! `rearm`, and a removed session that is never re-armed; a removed session's polls, which stay in
//! the op table, marked closing, until the kernel posts their final completions, so no op id is
//! reused while the kernel still holds a poll under it, and whose late completions and removal
//! races yield nothing; the control poll, replaced only when its events change; a session's
//! liveness pipe, which wakes the loop on its hang-up and never on a byte the worker wrote into
//! it; and a signal that interrupts the wait, which ends it with nothing ready. The tests that build a ring skip when the kernel or the sandbox refuses io_uring. The loop
//! that drives the ring is covered by `session_flow.zig` and by local-e2e, which spawns real
//! gateways. Lane: egress-gateway-test.

const std = @import("std");
const linux = std.os.linux;
const gateway = @import("collo_egress_gateway");
const restricted_uring = @import("collo_common_io").restricted_uring;

const readiness = gateway.readiness;

/// Waits at most this many ticks for the kernel to post a poll's final completion.
const final_completion_waits_max: usize = 8;

fn initBackend(shard_count: usize, max_sessions: usize) !readiness.Backend {
    return readiness.Backend.init(std.testing.allocator, shard_count, max_sessions) catch |err| switch (err) {
        error.UnsupportedKernel, error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
}

fn eventfd() !std.posix.fd_t {
    return std.posix.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
}

fn signal(fd: std.posix.fd_t) !void {
    const one: u64 = 1;
    _ = try std.posix.write(fd, std.mem.asBytes(&one));
}

fn drainEventfd(fd: std.posix.fd_t) !void {
    var value: u64 = 0;
    _ = try std.posix.read(fd, std.mem.asBytes(&value));
}

fn addSession(backend: *readiness.Backend, session_id: u64, command_fd: std.posix.fd_t, liveness_fd: std.posix.fd_t) !void {
    try backend.reserveSession();
    try backend.addSession(session_id, command_fd, liveness_fd);
}

/// Runs waits, re-arming between them as the loop does, until every poll the kernel still held
/// has posted its final completion; none of those completions is a ready event.
fn waitForFinalCompletions(backend: *readiness.Backend, ops_left: usize) !void {
    var ready: [4]readiness.Ready = undefined;
    var waits: usize = 0;
    while (backend.ops.count() != ops_left) : (waits += 1) {
        try std.testing.expect(waits < final_completion_waits_max);
        try backend.rearm();
        try std.testing.expectEqual(@as(usize, 0), try backend.wait(&ready));
    }
}

test "the readiness ring admits only poll add, poll remove and timeout" {
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

test "a removed session's polls stay in the op table, closing, until their final completions, which wake nothing" {
    const command_fd = try eventfd();
    defer std.posix.close(command_fd);
    const liveness_fd = try eventfd();
    defer std.posix.close(liveness_fd);

    var backend = try initBackend(0, 1);
    defer backend.deinit();

    try addSession(&backend, 7, command_fd, liveness_fd);
    try std.testing.expectEqual(@as(u32, 1), backend.sessions.count());
    try std.testing.expectEqual(@as(u32, 2), backend.ops.count());

    try backend.removeSession(7);
    try std.testing.expectEqual(@as(u32, 0), backend.sessions.count());
    // The kernel still holds both polls, so their op ids stay taken, marked closing.
    try std.testing.expectEqual(@as(u32, 2), backend.ops.count());
    var ops = backend.ops.valueIterator();
    while (ops.next()) |op|
        try std.testing.expect(op.state == .closing);

    try waitForFinalCompletions(&backend, 0);
}

test "a removal racing its poll's completion is benign and wakes nothing" {
    const command_fd = try eventfd();
    defer std.posix.close(command_fd);
    const liveness_fd = try eventfd();
    defer std.posix.close(liveness_fd);

    var backend = try initBackend(0, 1);
    defer backend.deinit();

    try addSession(&backend, 7, command_fd, liveness_fd);
    // The command poll completes in the kernel before the loop reaps it, so the removal finds
    // it completed or canceled; either answer is benign, and the poll's own completion arrives
    // for an op already closing.
    try signal(command_fd);
    try backend.removeSession(7);
    try waitForFinalCompletions(&backend, 0);
}

test "a completion re-arms only its own target, and only on rearm" {
    const shard_fd = try eventfd();
    defer std.posix.close(shard_fd);
    const command_7 = try eventfd();
    defer std.posix.close(command_7);
    const liveness_7 = try eventfd();
    defer std.posix.close(liveness_7);
    const command_8 = try eventfd();
    defer std.posix.close(command_8);
    const liveness_8 = try eventfd();
    defer std.posix.close(liveness_8);

    var backend = try initBackend(1, 2);
    defer backend.deinit();

    try backend.addShard(0, shard_fd);
    try addSession(&backend, 7, command_7, liveness_7);
    try addSession(&backend, 8, command_8, liveness_8);
    try std.testing.expectEqual(@as(u32, 5), backend.ops.count());
    const shard_op = backend.shards[0].op_id.?;
    const session_8 = backend.sessions.get(8).?;
    const liveness_7_op = backend.sessions.get(7).?.liveness_op_id.?;

    try signal(command_7);
    var ready: [4]readiness.Ready = undefined;
    try backend.rearm();
    try std.testing.expectEqual(@as(usize, 1), try backend.wait(&ready));
    switch (ready[0]) {
        .session => |session| {
            try std.testing.expectEqual(@as(u64, 7), session.session_id);
            try std.testing.expectEqual(readiness.SessionSource.command, session.source);
            try std.testing.expect((session.revents & std.posix.POLL.IN) != 0);
        },
        else => return error.TestUnexpectedReadiness,
    }
    // The completion consumed its poll, and nothing is armed again before the loop asks.
    try std.testing.expect(backend.sessions.get(7).?.command_op_id == null);
    try std.testing.expectEqual(@as(u32, 4), backend.ops.count());

    try drainEventfd(command_7);
    try backend.rearm();
    try std.testing.expect(backend.sessions.get(7).?.command_op_id != null);
    try std.testing.expectEqual(@as(u32, 5), backend.ops.count());
    // Every other poll is the one it was.
    try std.testing.expectEqual(shard_op, backend.shards[0].op_id.?);
    try std.testing.expectEqual(session_8.command_op_id.?, backend.sessions.get(8).?.command_op_id.?);
    try std.testing.expectEqual(session_8.liveness_op_id.?, backend.sessions.get(8).?.liveness_op_id.?);
    try std.testing.expectEqual(liveness_7_op, backend.sessions.get(7).?.liveness_op_id.?);

    // A shard's poll follows the same rule.
    try signal(shard_fd);
    try std.testing.expectEqual(@as(usize, 1), try backend.wait(&ready));
    switch (ready[0]) {
        .shard => |shard| try std.testing.expectEqual(@as(usize, 0), shard.index),
        else => return error.TestUnexpectedReadiness,
    }
    try std.testing.expect(backend.shards[0].op_id == null);
    try drainEventfd(shard_fd);
    try backend.rearm();
    try std.testing.expect(backend.shards[0].op_id != null);
}

test "a session removed after its poll completed is never armed again" {
    const command_fd = try eventfd();
    defer std.posix.close(command_fd);
    const liveness_fd = try eventfd();
    defer std.posix.close(liveness_fd);

    var backend = try initBackend(0, 1);
    defer backend.deinit();

    try addSession(&backend, 7, command_fd, liveness_fd);
    try signal(command_fd);
    var ready: [4]readiness.Ready = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.wait(&ready));

    try backend.removeSession(7);
    // Only the liveness poll is left, closing; the completed command poll comes back for nobody.
    try backend.rearm();
    try std.testing.expect(backend.sessions.get(7) == null);
    try std.testing.expectEqual(@as(u32, 1), backend.ops.count());
    try waitForFinalCompletions(&backend, 0);
}

test "the control poll is replaced only when its events change" {
    const control_fd = try eventfd();
    defer std.posix.close(control_fd);

    var backend = try initBackend(0, 1);
    defer backend.deinit();

    try backend.armControl(control_fd, std.posix.POLL.IN);
    const first = backend.control.op_id.?;
    try backend.armControl(control_fd, std.posix.POLL.IN);
    try std.testing.expectEqual(first, backend.control.op_id.?);
    try std.testing.expectEqual(@as(u32, 1), backend.ops.count());

    // Output waits while control packets are queued; an eventfd is always writable, so the new
    // poll completes at once, and the replaced one ends without a ready event.
    try backend.armControl(control_fd, std.posix.POLL.IN | std.posix.POLL.OUT);
    try std.testing.expect(backend.control.op_id.? != first);
    var ready: [4]readiness.Ready = undefined;
    var saw_output = false;
    var waits: usize = 0;
    while (backend.ops.count() != 0) : (waits += 1) {
        try std.testing.expect(waits < final_completion_waits_max);
        const count = try backend.wait(&ready);
        for (ready[0..count]) |event| switch (event) {
            .control => |revents| {
                try std.testing.expect((revents & std.posix.POLL.OUT) != 0);
                saw_output = true;
            },
            else => return error.TestUnexpectedReadiness,
        };
        try backend.rearm();
    }
    try std.testing.expect(saw_output);
    try std.testing.expect(backend.control.op_id == null);
}

fn ignoreSignal(_: i32) callconv(.c) void {}

/// Sends `SIGUSR2` to thread `tid` every millisecond until `done` is set,
/// at most `attempts_max` times, so one of them lands while the thread is
/// inside the wait.
fn interruptUntilDone(tid: std.posix.pid_t, done: *const std.atomic.Value(bool), attempts_max: usize) void {
    var attempts: usize = 0;
    while (attempts < attempts_max and !done.load(.acquire)) : (attempts += 1) {
        _ = linux.tgkill(linux.getpid(), tid, std.posix.SIG.USR2);
        std.Thread.sleep(std.time.ns_per_ms);
    }
}

test "a signal that interrupts the wait ends it with nothing ready, and the next wait still ends at the tick (#158)" {
    var backend = try initBackend(0, 0);
    defer backend.deinit();

    // A handler without SA_RESTART, so the signal interrupts the wait the
    // way a debugger or a profiler attaching to the gateway does. Restored
    // before the test ends, since the action is process-wide.
    var previous_action: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.USR2, &.{
        .handler = .{ .handler = ignoreSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, &previous_action);
    defer std.posix.sigaction(std.posix.SIG.USR2, &previous_action, null);

    var done = std.atomic.Value(bool).init(false);
    // Nothing is armed but the tick, so without the signals the wait lasts
    // `wait_tick_ns`; the sender stops after twice that.
    const attempts_max: usize = 2 * readiness.wait_tick_ns / std.time.ns_per_ms;
    const sender = try std.Thread.spawn(.{}, interruptUntilDone, .{ linux.gettid(), &done, attempts_max });
    var ready: [4]readiness.Ready = undefined;
    const interrupted = backend.wait(&ready);
    done.store(true, .release);
    sender.join();
    try std.testing.expectEqual(@as(usize, 0), try interrupted);

    // The tick queued before the signal still ends the next wait.
    try backend.rearm();
    try std.testing.expectEqual(@as(usize, 0), try backend.wait(&ready));
}

test "a byte a worker writes into the pipe the gateway watches wakes nothing, and the pipe's hang-up still does" {
    const command_fd = try eventfd();
    defer std.posix.close(command_fd);
    const pipe = try std.posix.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
    defer std.posix.close(pipe[0]);
    var write_end: ?std.posix.fd_t = pipe[1];
    defer if (write_end) |fd| std.posix.close(fd);

    var backend = try initBackend(0, 1);
    defer backend.deinit();

    // The worker holds the write end, and nothing in the gateway reads the pipe.
    _ = try std.posix.write(pipe[1], "x");
    try addSession(&backend, 7, command_fd, pipe[0]);

    // Only the tick ends each wait; the readable pipe completes no poll.
    var ready: [4]readiness.Ready = undefined;
    for (0..2) |_| {
        try backend.rearm();
        try std.testing.expectEqual(@as(usize, 0), try backend.wait(&ready));
    }

    std.posix.close(pipe[1]);
    write_end = null;
    try backend.rearm();
    const count = try backend.wait(&ready);
    try std.testing.expectEqual(@as(usize, 1), count);
    switch (ready[0]) {
        .session => |session| {
            try std.testing.expectEqual(@as(u64, 7), session.session_id);
            try std.testing.expectEqual(readiness.SessionSource.liveness, session.source);
            try std.testing.expect((session.revents & std.posix.POLL.HUP) != 0);
        },
        else => return error.TestUnexpectedReadiness,
    }
}

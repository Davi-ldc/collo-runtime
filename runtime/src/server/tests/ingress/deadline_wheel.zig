//! A lane's request deadline wheel (`ingress/timer_wheel.zig`): insert and
//! cancel, expiry at the absolute deadline after the wheel wraps or its clock
//! jumps, a due bucket holding more entries than one drain takes, the next
//! wake rounded up to a tick and capped at one revolution, a handle that goes
//! stale when its request slot is reused, and the armed transitions the lane's
//! timer follows. Releasing a completed request cancels its deadline first.
//! Lane `server-ingress-test`. What an expiry does to its request and worker
//! runs through a whole lane in `request_deadlines.zig` and
//! `completion_ring.zig`; in `local-e2e` the worker answers a served
//! request's deadline itself, so the wheel entry is only cancelled.

const std = @import("std");
const server_main = @import("collo_server_main");
const worker_shared_page = @import("collo_worker_state").page;

const ingress = server_main.ingress;
const lifecycle = server_main.lifecycle;

test "ingress deadline wheel insert cancel wrap and stale timeout" {
    var wheel = try ingress.timer_wheel.DeadlineWheel.init(std.testing.allocator, 2, ingress.timer_wheel.minimum_slots, 0);
    defer wheel.deinit();
    const conn = ingress.state.ConnectionKey{ .lane_id = 1, .slot = 0, .generation = 1 };
    const worker = ingress.state.WorkerKey{ .worker_id = 1, .worker_generation = 2 };
    const req = ingress.state.RequestKey{ .lane_id = 1, .slot = 0, .generation = 1 };

    const cancel_handle = try wheel.insert(req, conn, worker, 0, ingress.timer_wheel.tick_ns);
    try std.testing.expect(wheel.cancel(cancel_handle));
    const deadline = (@as(u64, ingress.timer_wheel.minimum_slots) + 1) * ingress.timer_wheel.tick_ns;
    _ = try wheel.insert(req, conn, worker, 0, deadline);
    var expired: [1]ingress.timer_wheel.Expired = undefined;
    try std.testing.expectEqual(@as(usize, 0), wheel.expireDue(deadline - ingress.timer_wheel.tick_ns, &expired));
    try std.testing.expectEqual(@as(usize, 1), wheel.expireDue(deadline, &expired));
    try std.testing.expect(!wheel.cancel(cancel_handle));
}

test "deadline wheel drains overfull due bucket without full revolution delay" {
    var wheel = try ingress.timer_wheel.DeadlineWheel.init(std.testing.allocator, 3, ingress.timer_wheel.minimum_slots, 0);
    defer wheel.deinit();
    const conn = ingress.state.ConnectionKey{ .lane_id = 1, .slot = 0, .generation = 1 };
    const worker = ingress.state.WorkerKey{ .worker_id = 1, .worker_generation = 1 };
    _ = try wheel.insert(
        .{ .lane_id = 1, .slot = 0, .generation = 1 },
        conn,
        worker,
        0,
        ingress.timer_wheel.tick_ns,
    );
    _ = try wheel.insert(
        .{ .lane_id = 1, .slot = 1, .generation = 1 },
        conn,
        worker,
        0,
        ingress.timer_wheel.tick_ns,
    );
    _ = try wheel.insert(
        .{ .lane_id = 1, .slot = 2, .generation = 1 },
        conn,
        worker,
        0,
        ingress.timer_wheel.tick_ns,
    );
    var one: [1]ingress.timer_wheel.Expired = undefined;
    try std.testing.expectEqual(@as(usize, 1), wheel.expireDue(ingress.timer_wheel.tick_ns, &one));
    try std.testing.expectEqual(
        ingress.timer_wheel.tick_ns,
        wheel.nextWakeDeadlineNs(ingress.timer_wheel.tick_ns).?,
    );
    var rest: [2]ingress.timer_wheel.Expired = undefined;
    try std.testing.expectEqual(@as(usize, 2), wheel.expireDue(ingress.timer_wheel.tick_ns, &rest));
}

test "deadline wheel cancel unlinks pending due entry before freelist release" {
    var wheel = try ingress.timer_wheel.DeadlineWheel.init(std.testing.allocator, 2, ingress.timer_wheel.minimum_slots, 0);
    defer wheel.deinit();
    const conn = ingress.state.ConnectionKey{ .lane_id = 1, .slot = 0, .generation = 1 };
    const worker = ingress.state.WorkerKey{ .worker_id = 1, .worker_generation = 1 };
    const pending_handle = try wheel.insert(
        .{ .lane_id = 1, .slot = 0, .generation = 1 },
        conn,
        worker,
        0,
        ingress.timer_wheel.tick_ns,
    );
    _ = try wheel.insert(
        .{ .lane_id = 1, .slot = 1, .generation = 1 },
        conn,
        worker,
        0,
        ingress.timer_wheel.tick_ns,
    );

    var one: [1]ingress.timer_wheel.Expired = undefined;
    try std.testing.expectEqual(@as(usize, 1), wheel.expireDue(ingress.timer_wheel.tick_ns, &one));
    try std.testing.expect(wheel.cancel(pending_handle));
    try std.testing.expect(wheel.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), wheel.expireDue(ingress.timer_wheel.tick_ns, &one));

    _ = try wheel.insert(
        .{ .lane_id = 1, .slot = 2, .generation = 1 },
        conn,
        worker,
        ingress.timer_wheel.tick_ns,
        ingress.timer_wheel.tick_ns * 2,
    );
    try std.testing.expectEqual(@as(usize, 1), wheel.expireDue(ingress.timer_wheel.tick_ns * 2, &one));
}

test "deadline wheel next wake follows earliest rounded deadline" {
    const start_ns = 10 * std.time.ns_per_ms;
    var wheel = try ingress.timer_wheel.DeadlineWheel.init(
        std.testing.allocator,
        2,
        ingress.timer_wheel.minimum_slots,
        start_ns,
    );
    defer wheel.deinit();
    const conn = ingress.state.ConnectionKey{ .lane_id = 1, .slot = 0, .generation = 1 };
    const worker = ingress.state.WorkerKey{ .worker_id = 1, .worker_generation = 1 };

    _ = try wheel.insert(
        .{ .lane_id = 1, .slot = 0, .generation = 1 },
        conn,
        worker,
        start_ns,
        23 * std.time.ns_per_ms,
    );
    try std.testing.expectEqual(
        25 * std.time.ns_per_ms,
        wheel.nextWakeDeadlineNs(start_ns).?,
    );
    _ = try wheel.insert(
        .{ .lane_id = 1, .slot = 1, .generation = 1 },
        conn,
        worker,
        start_ns,
        17 * std.time.ns_per_ms,
    );
    try std.testing.expectEqual(
        20 * std.time.ns_per_ms,
        wheel.nextWakeDeadlineNs(start_ns).?,
    );
}

test "deadline wheel next wake recomputes after earliest cancellation" {
    var wheel = try ingress.timer_wheel.DeadlineWheel.init(std.testing.allocator, 2, ingress.timer_wheel.minimum_slots, 0);
    defer wheel.deinit();
    const conn = ingress.state.ConnectionKey{ .lane_id = 1, .slot = 0, .generation = 1 };
    const worker = ingress.state.WorkerKey{ .worker_id = 1, .worker_generation = 1 };
    const first = try wheel.insert(
        .{ .lane_id = 1, .slot = 0, .generation = 1 },
        conn,
        worker,
        0,
        10 * std.time.ns_per_ms,
    );
    _ = try wheel.insert(
        .{ .lane_id = 1, .slot = 1, .generation = 1 },
        conn,
        worker,
        0,
        20 * std.time.ns_per_ms,
    );

    try std.testing.expect(wheel.cancel(first));
    try std.testing.expectEqual(
        20 * std.time.ns_per_ms,
        wheel.nextWakeDeadlineNs(0).?,
    );
}

test "deadline wheel next wake caps long sleeps to one wheel revolution" {
    var wheel = try ingress.timer_wheel.DeadlineWheel.init(std.testing.allocator, 1, ingress.timer_wheel.minimum_slots, 0);
    defer wheel.deinit();
    const wheel_span_ns = @as(u64, ingress.timer_wheel.minimum_slots) * ingress.timer_wheel.tick_ns;
    _ = try wheel.insert(
        .{ .lane_id = 1, .slot = 0, .generation = 1 },
        .{ .lane_id = 1, .slot = 0, .generation = 1 },
        .{ .worker_id = 1, .worker_generation = 1 },
        0,
        wheel_span_ns * 3,
    );

    try std.testing.expectEqual(wheel_span_ns, wheel.nextWakeDeadlineNs(0).?);
}

test "deadline wheel insert after time advance expires at absolute deadline" {
    var wheel = try ingress.timer_wheel.DeadlineWheel.init(std.testing.allocator, 1, ingress.timer_wheel.minimum_slots, 0);
    defer wheel.deinit();
    var out: [1]ingress.timer_wheel.Expired = undefined;
    try std.testing.expectEqual(@as(usize, 0), wheel.expireDue(50 * std.time.ns_per_ms, &out));
    _ = try wheel.insert(
        .{ .lane_id = 1, .slot = 0, .generation = 1 },
        .{ .lane_id = 1, .slot = 0, .generation = 1 },
        .{ .worker_id = 1, .worker_generation = 1 },
        50 * std.time.ns_per_ms,
        60 * std.time.ns_per_ms,
    );
    try std.testing.expectEqual(
        60 * std.time.ns_per_ms,
        wheel.nextWakeDeadlineNs(50 * std.time.ns_per_ms).?,
    );
    try std.testing.expectEqual(@as(usize, 0), wheel.expireDue(55 * std.time.ns_per_ms, &out));
    try std.testing.expectEqual(@as(usize, 1), wheel.expireDue(60 * std.time.ns_per_ms, &out));
}

test "request completion cancels deadline handle before slot release" {
    var lane = try ingress.lane.IngressLane.init(std.testing.allocator, .{ .lane_id = 1, .max_connections = 1, .max_requests = 1 }, 0);
    defer lane.deinit();
    const conn = try lane.allocateAcceptedConnection(.{});
    const worker = ingress.state.WorkerKey{ .worker_id = 1, .worker_generation = 1 };
    const req = try lane.state.requests.alloc(1, conn, worker, 0, ingress.timer_wheel.tick_ns);
    _ = try lane.insertDeadline(req, conn, worker, ingress.timer_wheel.tick_ns, 0);
    lane.releaseCompletedRequest(req);
    var out: [1]ingress.timer_wheel.Expired = undefined;
    try std.testing.expectEqual(@as(usize, 0), lane.deadline_wheel.expireDue(ingress.timer_wheel.tick_ns, &out));
    try std.testing.expectEqual(@as(u64, 1), lane.deadline_wheel.counters.cancels);
}

test "stale deadline handle after request slot reuse is ignored and counted" {
    var lane = try ingress.lane.IngressLane.init(std.testing.allocator, .{ .lane_id = 1, .max_connections = 1, .max_requests = 1 }, 0);
    defer lane.deinit();
    const conn = try lane.allocateAcceptedConnection(.{});
    const worker = ingress.state.WorkerKey{ .worker_id = 1, .worker_generation = 1 };
    const first = try lane.state.requests.alloc(1, conn, worker, 0, 100);
    const handle = try lane.insertDeadline(first, conn, worker, 100, 0);
    try std.testing.expect(lane.deadline_wheel.cancel(handle));
    _ = lane.state.requests.release(first);
    const second = try lane.state.requests.alloc(2, conn, worker, 0, 100);
    try std.testing.expect(first.generation != second.generation);
    try std.testing.expect(!lane.deadline_wheel.cancel(handle));
    try std.testing.expectEqual(@as(u64, 1), lane.deadline_wheel.counters.stale_cancels);
}

test "deadline wheel arms and disarms lane timer source on boundary transitions" {
    var wheel = try ingress.timer_wheel.DeadlineWheel.init(std.testing.allocator, 1, ingress.timer_wheel.minimum_slots, 0);
    defer wheel.deinit();
    const handle = try wheel.insert(
        .{ .lane_id = 1, .slot = 0, .generation = 1 },
        .{ .lane_id = 1, .slot = 0, .generation = 1 },
        .{ .worker_id = 1, .worker_generation = 1 },
        0,
        ingress.timer_wheel.tick_ns,
    );
    try std.testing.expect(wheel.armed);
    try std.testing.expect(wheel.cancel(handle));
    try std.testing.expect(!wheel.armed);
    try std.testing.expectEqual(@as(u64, 1), wheel.counters.armed_transitions);
    try std.testing.expectEqual(@as(u64, 1), wheel.counters.disarmed_transitions);
}

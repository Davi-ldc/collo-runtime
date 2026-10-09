//! A lane's request deadline wheel (`ingress/timer_wheel.zig`): insert and
//! cancel, expiry at the absolute deadline after the wheel wraps or its clock
//! jumps, a due bucket holding more entries than one drain takes, the next
//! wake rounded up to a tick and capped at one revolution, a handle that goes
//! stale once its entry moves, and the armed transitions the lane's timer
//! follows. A request's handle cancels its entry once. Lane
//! `server-ingress-test`. What an expiry does to its request and worker
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
    const conn = lifecycle.ConnectionKey{ .lane_id = 1, .slot = 0, .generation = 1 };
    const worker = lifecycle.WorkerKey{ .worker_id = 1, .worker_generation = 2 };
    const req = lifecycle.RequestKey{ .lane_id = 1, .slot = 0, .generation = 1 };

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
    const conn = lifecycle.ConnectionKey{ .lane_id = 1, .slot = 0, .generation = 1 };
    const worker = lifecycle.WorkerKey{ .worker_id = 1, .worker_generation = 1 };
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
    const conn = lifecycle.ConnectionKey{ .lane_id = 1, .slot = 0, .generation = 1 };
    const worker = lifecycle.WorkerKey{ .worker_id = 1, .worker_generation = 1 };
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
    const conn = lifecycle.ConnectionKey{ .lane_id = 1, .slot = 0, .generation = 1 };
    const worker = lifecycle.WorkerKey{ .worker_id = 1, .worker_generation = 1 };

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
    const conn = lifecycle.ConnectionKey{ .lane_id = 1, .slot = 0, .generation = 1 };
    const worker = lifecycle.WorkerKey{ .worker_id = 1, .worker_generation = 1 };
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

test "a request's deadline handle cancels its wheel entry once, and a second cancel finds nothing" {
    var lane = try ingress.lane.IngressLane.init(std.testing.allocator, .{ .lane_id = 1, .max_requests = 1 }, 0);
    defer lane.deinit();
    const conn = lifecycle.ConnectionKey{ .lane_id = 1, .slot = 0, .generation = 1 };
    const worker = lifecycle.WorkerKey{ .worker_id = 1, .worker_generation = 1 };
    const req = lifecycle.RequestKey{ .lane_id = 1, .slot = 0, .generation = 1 };
    var handle: ?ingress.timer_wheel.Handle = null;
    try lane.armRequestDeadline(&handle, req, conn, worker, ingress.timer_wheel.tick_ns, 0);
    try std.testing.expect(lane.cancelRequestDeadline(&handle));
    try std.testing.expectEqual(@as(?ingress.timer_wheel.Handle, null), handle);
    try std.testing.expect(!lane.cancelRequestDeadline(&handle));
    var out: [1]ingress.timer_wheel.Expired = undefined;
    try std.testing.expectEqual(@as(usize, 0), lane.deadline_wheel.expireDue(ingress.timer_wheel.tick_ns, &out));
    try std.testing.expectEqual(@as(u64, 1), lane.deadline_wheel.counters.cancels);
}

test "re-arming a request's deadline moves its one wheel entry, and the old handle goes stale" {
    var lane = try ingress.lane.IngressLane.init(std.testing.allocator, .{ .lane_id = 1, .max_requests = 1 }, 0);
    defer lane.deinit();
    const conn = lifecycle.ConnectionKey{ .lane_id = 1, .slot = 0, .generation = 1 };
    const worker = lifecycle.WorkerKey{ .worker_id = 1, .worker_generation = 1 };
    const req = lifecycle.RequestKey{ .lane_id = 1, .slot = 0, .generation = 1 };
    var handle: ?ingress.timer_wheel.Handle = null;
    try lane.armRequestDeadline(&handle, req, conn, worker, 100, 0);
    const first = handle.?;
    // The wheel holds one entry: the move frees the old one before it takes
    // its place again.
    try lane.armRequestDeadline(&handle, req, conn, worker, 200, 0);
    try std.testing.expect(first.generation != handle.?.generation);
    try std.testing.expect(!lane.deadline_wheel.cancel(first));
    try std.testing.expectEqual(@as(u64, 1), lane.deadline_wheel.counters.stale_cancels);
    try std.testing.expectEqual(@as(u32, 1), lane.deadline_wheel.liveEntries());
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

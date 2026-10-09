//! Contracts of the lane runner that need no live lane: event data packing,
//! counter snapshot arithmetic, deadline and poll bookkeeping, header buffer
//! ownership, the hard-timeout deadline, and the lane's bounded structures
//! failing cleanly when their allocation fails. Lane `server-ingress-test`;
//! how the TLS handshake's errors close a connection is pinned with the other
//! failure-domain tables in `fault.zig`.

const std = @import("std");
const server_main = @import("collo_server_main");
const ingress_assertions = @import("assertions.zig");

const ingress = server_main.ingress;
const event_sources = ingress.runner.event_sources;

test "runner event data round trips kind index and generation, and refuses a tag naming no kind" {
    const original = event_sources.EventData{ .kind = .worker_completion, .index = 42, .generation = 77 };
    const decoded = try event_sources.unpackEventData(event_sources.packEventData(original));
    try std.testing.expectEqual(original.kind, decoded.kind);
    try std.testing.expectEqual(original.index, decoded.index);
    try std.testing.expectEqual(original.generation, decoded.generation);

    // The kind is the top byte, and no kind is numbered this high.
    const unknown_kind: u64 = @as(u64, std.math.maxInt(u8)) << 56;
    try std.testing.expectError(error.UnknownCqeTag, event_sources.unpackEventData(unknown_kind));
}

test "counter snapshots keep ingress-channel transport metrics outside the forbidden hot-path work" {
    const CounterSnapshot = ingress.lane.CounterSnapshot;
    const before = CounterSnapshot{
        .h2_server_protocol_time_ns = 10,
        .ingress_channels_started = 1,
        .h2_request_body_frames = 2,
        .h2_request_body_bytes = 32,
        .h2_worker_descriptor_batches = 1,
        .h2_worker_descriptors = 3,
        .ingress_response_body_bytes = 64,
    };
    const after = CounterSnapshot{
        .h2_server_protocol_time_ns = 25,
        .ingress_channels_started = 3,
        .h2_request_body_frames = 7,
        .h2_request_body_bytes = 160,
        .h2_worker_descriptor_batches = 4,
        .h2_worker_descriptors = 9,
        .ingress_response_body_bytes = 320,
    };
    const delta = CounterSnapshot.diff(after, before);

    try std.testing.expectEqual(@as(u64, 15), delta.h2_server_protocol_time_ns);
    try std.testing.expectEqual(@as(u64, 2), delta.ingress_channels_started);
    try std.testing.expectEqual(@as(u64, 5), delta.h2_request_body_frames);
    try std.testing.expectEqual(@as(u64, 128), delta.h2_request_body_bytes);
    try std.testing.expectEqual(@as(u64, 3), delta.h2_worker_descriptor_batches);
    try std.testing.expectEqual(@as(u64, 6), delta.h2_worker_descriptors);
    try std.testing.expectEqual(@as(u64, 256), delta.ingress_response_body_bytes);

    try ingress_assertions.expectHttp2TransportObserved(delta);
    try ingress_assertions.expectForbiddenHotWorkZero(delta);

    var aggregate = CounterSnapshot{};
    aggregate.add(before);
    aggregate.add(delta);
    try std.testing.expectEqual(after.h2_server_protocol_time_ns, aggregate.h2_server_protocol_time_ns);
    try std.testing.expectEqual(after.ingress_response_body_bytes, aggregate.ingress_response_body_bytes);
}

test "pre-request deadlines use heap order instead of scanning connection slots" {
    const runtime = ingress.runner.connection_slot;
    var slots = [_]runtime.Slot{
        .{ .key = .{ .lane_id = 0, .slot = 0, .generation = 1 }, .pre_request_deadline_active = true, .pre_request_deadline_ns = 30 },
        .{ .key = .{ .lane_id = 0, .slot = 1, .generation = 1 }, .pre_request_deadline_active = true, .pre_request_deadline_ns = 10 },
        .{ .key = .{ .lane_id = 0, .slot = 2, .generation = 1 }, .pre_request_deadline_active = true, .pre_request_deadline_ns = 20 },
    };
    var heap = try runtime.PreRequestDeadlineHeap.initCapacity(std.testing.allocator, {}, slots.len);
    defer heap.deinit();

    for (&slots) |*slot|
        heap.insertAssumeCapacity(slot);

    try std.testing.expectEqual(@as(u32, 1), heap.deleteMin().?.key.slot);
    try std.testing.expect(heap.remove(&slots[2]));
    slots[2].pre_request_deadline_ns = 5;
    try heap.insert(&slots[2]);
    try std.testing.expectEqual(@as(u32, 2), heap.deleteMin().?.key.slot);
    try std.testing.expectEqual(@as(u32, 0), heap.deleteMin().?.key.slot);
}

test "connection interest registers newly required write readiness while read poll is armed" {
    const missing = ingress.runner.connection_flow.missingConnectionInterest(
        event_sources.read_write_events,
        event_sources.read_interest,
    );
    try std.testing.expect((missing & event_sources.write_interest) != 0);
    try std.testing.expect((missing & event_sources.read_interest) == 0);
}

test "connection close poll cancel plan tracks armed read and write polls" {
    const none = ingress.runner.connection_flow.connectionPollCancelPlan(0);
    try std.testing.expect(!none.read);
    try std.testing.expect(!none.write);

    const read = ingress.runner.connection_flow.connectionPollCancelPlan(event_sources.read_interest);
    try std.testing.expect(read.read);
    try std.testing.expect(!read.write);

    const read_write = ingress.runner.connection_flow.connectionPollCancelPlan(
        event_sources.read_interest | event_sources.write_interest,
    );
    try std.testing.expect(read_write.read);
    try std.testing.expect(read_write.write);
}

test "header buffer pool tracks ownership for release assertions" {
    var pool = try ingress.runner.work_queues.HeaderBufferPool.init(
        std.testing.allocator,
        2,
        2,
        16,
    );
    defer pool.deinit(std.testing.allocator);

    const first = pool.acquire() orelse return error.MissingHeaderBuffer;
    try std.testing.expect(pool.used_slots[first]);

    pool.release(first);
    try std.testing.expect(!pool.used_slots[first]);

    const second = pool.acquire() orelse return error.MissingHeaderBuffer;
    try std.testing.expectEqual(first, second);
    try std.testing.expect(pool.used_slots[second]);
}

test "ingress hard timeout deadline uses configured supervisor grace" {
    const deadline_driver = ingress.runner.deadline_driver;
    const route_deadline_ns = 10 * std.time.ns_per_s;
    try std.testing.expectEqual(
        route_deadline_ns + 250 * std.time.ns_per_ms,
        deadline_driver.effectiveHardTimeoutDeadline(route_deadline_ns, 250 * std.time.ns_per_ms),
    );
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        deadline_driver.effectiveHardTimeoutDeadline(std.math.maxInt(u64) - 1, 250 * std.time.ns_per_ms),
    );
}

test "failing allocator covers launch bounded structure initialization" {
    {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        try std.testing.expectError(error.OutOfMemory, ingress.commands.Queue.init(failing.allocator(), 1, 0));
    }
    {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
        try std.testing.expectError(error.OutOfMemory, ingress.timer_wheel.DeadlineWheel.init(failing.allocator(), 1, ingress.timer_wheel.minimum_slots, 0));
    }
    {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        try std.testing.expectError(error.OutOfMemory, server_main.listener.IngressListeners.init(failing.allocator(), .{ .address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0), .lane_count = 2, .backlog = 16 }));
    }
}

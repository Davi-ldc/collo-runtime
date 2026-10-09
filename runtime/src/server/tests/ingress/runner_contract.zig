//! Contracts of the lane runner that need no live lane: event data packing,
//! counter snapshot arithmetic, the connection deadline a connection's state
//! calls for and the heap that orders them, poll bookkeeping, the size of a
//! connection slot, the command reserve, the hard-timeout deadline, and the
//! lane's bounded structures failing cleanly when their allocation fails.
//! Lane `server-ingress-test`; how the TLS handshake's errors close a
//! connection is pinned with the other failure-domain tables in `fault.zig`.

const std = @import("std");
const server_main = @import("collo_server_main");
const supervision = @import("collo_server_supervisor");
const limits = @import("collo_limits");
const ingress_assertions = @import("assertions.zig");

const ingress = server_main.ingress;
const event_sources = ingress.runner.event_sources;
const connection_slot = ingress.runner.connection_slot;
const deadline_driver = ingress.runner.deadline_driver;

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

test "counter snapshots subtract and add field by field" {
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

    var aggregate = CounterSnapshot{};
    aggregate.add(before);
    aggregate.add(delta);
    try std.testing.expectEqual(after.h2_server_protocol_time_ns, aggregate.h2_server_protocol_time_ns);
    try std.testing.expectEqual(after.ingress_response_body_bytes, aggregate.ingress_response_body_bytes);
}

fn expectDeadline(actual: ?connection_slot.Deadline, kind: connection_slot.DeadlineKind, at_ns: u64) !void {
    const deadline = actual orelse return error.NoDeadline;
    try std.testing.expectEqual(kind, deadline.kind);
    try std.testing.expectEqual(at_ns, deadline.at_ns);
}

test "a connection's one deadline follows its state: pre-request, stall, idle, or none while its streams run" {
    const timeouts: deadline_driver.ConnectionTimeouts = .{ .pre_request_ns = 3, .idle_ns = 300, .stall_ns = 10 };
    var slot: connection_slot.Slot = .{ .accepted_ns = 1000, .last_progress_ns = 1000 };

    // From the accept until the first request, whatever moves meanwhile.
    try expectDeadline(deadline_driver.desiredDeadline(&slot, timeouts), .pre_request, 1003);
    slot.last_progress_ns = 2000;
    slot.h2_pending_response_bytes = 1;
    try expectDeadline(deadline_driver.desiredDeadline(&slot, timeouts), .pre_request, 1003);

    // A first request started and a stream runs: the request's own
    // deadline governs, unless the client holds something back.
    slot.awaiting_first_request = false;
    slot.ingress_channel_count = 1;
    try expectDeadline(deadline_driver.desiredDeadline(&slot, timeouts), .stall, 2010);
    slot.h2_pending_response_bytes = 0;
    try std.testing.expectEqual(@as(?connection_slot.Deadline, null), deadline_driver.desiredDeadline(&slot, timeouts));

    // No stream: idle from the moment the last one ended, unless a write
    // the socket has not taken stalls first.
    slot.ingress_channel_count = 0;
    slot.idle_since_ns = 5000;
    try expectDeadline(deadline_driver.desiredDeadline(&slot, timeouts), .idle, 5300);
    slot.h2_write_len = 9;
    try expectDeadline(deadline_driver.desiredDeadline(&slot, timeouts), .stall, 2010);

    // A close that flushes its GOAWAY is bounded by the stall deadline, and
    // one that does not flush needs no deadline.
    slot.closing = .{ .reason = .idle_timeout, .flush = true };
    try expectDeadline(deadline_driver.desiredDeadline(&slot, timeouts), .stall, 2010);
    slot.closing = .{ .reason = .idle_timeout, .flush = false };
    try std.testing.expectEqual(@as(?connection_slot.Deadline, null), deadline_driver.desiredDeadline(&slot, timeouts));
}

test "connection deadlines leave their heap in deadline order, ties by key" {
    var slots = [_]connection_slot.Slot{
        .{ .key = .{ .lane_id = 0, .slot = 0, .generation = 1 }, .deadline = .{ .kind = .idle, .at_ns = 30 } },
        .{ .key = .{ .lane_id = 0, .slot = 1, .generation = 1 }, .deadline = .{ .kind = .pre_request, .at_ns = 10 } },
        .{ .key = .{ .lane_id = 0, .slot = 2, .generation = 1 }, .deadline = .{ .kind = .stall, .at_ns = 20 } },
    };
    var heap = try connection_slot.DeadlineHeap.initCapacity(std.testing.allocator, {}, slots.len);
    defer heap.deinit();

    for (&slots) |*slot|
        heap.insertAssumeCapacity(slot);

    try std.testing.expectEqual(@as(u32, 1), heap.deleteMin().?.key.slot);
    try std.testing.expect(heap.remove(&slots[2]));
    slots[2].deadline = .{ .kind = .stall, .at_ns = 5 };
    try heap.insert(&slots[2]);
    try std.testing.expectEqual(@as(u32, 2), heap.deleteMin().?.key.slot);
    try std.testing.expectEqual(@as(u32, 0), heap.deleteMin().?.key.slot);
}

test "a connection slot holds positions into the lane's stream slab, not its streams" {
    // The streams of every connection share the lane's slab of
    // `limits.ingress.streams_per_lane_max` entries, so a slot carries only
    // an id and a slab index per position.
    try std.testing.expect(@sizeOf(connection_slot.Slot) <= 1536);
    try std.testing.expectEqual(
        limits.ingress.streams_per_connection_max,
        @as(u32, @intCast(@typeInfo(@FieldType(connection_slot.Slot, "stream_ids")).array.len)),
    );
}

test "the command reserve counts, per worker entry, a death, a reader grant, one completion per slot and the forwarding window" {
    const per_entry = 2 + @as(usize, supervision.pool.slots_per_worker_max) + limits.ingress.forwarded_commands_per_worker_max;
    const entries = supervision.scheduler_limits.capacity.pool_workers_max;
    try std.testing.expectEqual(@as(usize, 0), ingress.lane.obligationReserve(0));
    try std.testing.expectEqual(per_entry * entries, ingress.lane.obligationReserve(1));
    try std.testing.expectEqual(3 * per_entry * entries, ingress.lane.obligationReserve(3));
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

test "ingress hard timeout deadline uses configured supervisor grace" {
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
        try std.testing.expectError(error.OutOfMemory, ingress.timer_wheel.DeadlineWheel.init(failing.allocator(), 1, ingress.timer_wheel.minimum_slots, 0));
    }
    {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        try std.testing.expectError(error.OutOfMemory, server_main.listener.IngressListeners.init(failing.allocator(), .{ .address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0), .lane_count = 2, .backlog = 16 }));
    }
}

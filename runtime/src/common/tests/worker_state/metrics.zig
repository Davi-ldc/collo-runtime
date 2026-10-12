//! The worker's side of the shared state page (`worker_state/metrics.zig`):
//! live slot claims and their generations, every slot of the page claimable
//! before the next claim fails, a slot state outside `LiveSlotState`
//! compared raw on the worker's side too, the usage record ring's append and
//! wrap as the host's cursor drains it, the dead-on-full rule, and the death
//! record built from a live slot's snapshot. The host's reads are covered in
//! `snapshots.zig`, and the server's use of them by the server-supervisor
//! lane.

const std = @import("std");
const page = @import("collo_worker_state").page;
const metrics = @import("collo_worker_state").metrics;

fn testIdentity(request_id: u64) page.LifecycleIdentity {
    return .{
        .external_request_id = request_id,
        .request_lane_id = 1,
        .request_slot = @intCast(request_id % 64),
        .request_generation = request_id + 100,
        .worker_id = 7,
        .worker_generation = 9,
    };
}

fn testRecord(request_id: u64) page.CompletedRecord {
    return .{
        .request_id = request_id,
        .cpu_ns = 3,
        .io_ns = 7,
        .status = @intFromEnum(page.CompletedStatus.done),
    };
}

test "worker metrics live slot allocate free and reuse changes generation" {
    const fd = try page.createMemfd("work-state-slots");
    defer std.posix.close(fd);

    var view = try page.mapReadWrite(fd);
    defer view.deinit();
    view.initializeCrashDefault();

    var worker_metrics_state = metrics.WorkState.init(&view);
    const first = try worker_metrics_state.allocateLiveSlot(testIdentity(10));
    try std.testing.expectEqual(@as(u32, 0), first.index);
    try worker_metrics_state.freeLiveSlot(first);
    const second = try worker_metrics_state.allocateLiveSlot(testIdentity(20));
    try std.testing.expectEqual(first.index, second.index);
    try std.testing.expect(second.generation != first.generation);
}

test "a worker claims every live slot of its page and the next claim fails" {
    const fd = try page.createMemfd("work-state-every-slot");
    defer std.posix.close(fd);

    var view = try page.mapReadWrite(fd);
    defer view.deinit();
    view.initializeCrashDefault();

    var worker_metrics_state = metrics.WorkState.init(&view);
    var handles: [page.LIVE_SLOT_COUNT]metrics.LiveSlotHandle = undefined;
    for (&handles, 1..) |*handle, request_id| {
        handle.* = try worker_metrics_state.allocateLiveSlot(testIdentity(request_id));
        try std.testing.expectEqual(@as(u32, @intCast(request_id - 1)), handle.index);
    }
    try std.testing.expectError(
        error.NoFreeLiveSlot,
        worker_metrics_state.allocateLiveSlot(testIdentity(page.LIVE_SLOT_COUNT + 1)),
    );

    // A freed slot takes the next claim.
    const freed = handles[page.LIVE_SLOT_COUNT / 2];
    try worker_metrics_state.freeLiveSlot(freed);
    const reclaimed = try worker_metrics_state.allocateLiveSlot(testIdentity(page.LIVE_SLOT_COUNT + 2));
    try std.testing.expectEqual(freed.index, reclaimed.index);
}

test "worker metrics stale live slot handle is rejected" {
    const fd = try page.createMemfd("work-state-stale");
    defer std.posix.close(fd);

    var view = try page.mapReadWrite(fd);
    defer view.deinit();
    view.initializeCrashDefault();

    var worker_metrics_state = metrics.WorkState.init(&view);
    const first = try worker_metrics_state.allocateLiveSlot(testIdentity(1));
    try worker_metrics_state.freeLiveSlot(first);
    _ = try worker_metrics_state.allocateLiveSlot(testIdentity(2));
    try std.testing.expectError(error.StaleLiveSlot, worker_metrics_state.freeLiveSlot(first));
}

test "worker metrics never claims or updates a live slot whose state is outside LiveSlotState" {
    const fd = try page.createMemfd("work-state-unknown-slot-state");
    defer std.posix.close(fd);

    var view = try page.mapReadWrite(fd);
    defer view.deinit();
    view.initializeCrashDefault();

    var worker_metrics_state = metrics.WorkState.init(&view);
    const claimed = try worker_metrics_state.allocateLiveSlot(testIdentity(1));
    // 2 is neither empty nor active. The state is compared as the integer it
    // is, so the claim and the update below refuse the slot, where a cast to
    // `LiveSlotState` would be illegal behavior.
    @atomicStore(u32, &view.live_slots[claimed.index].state, 2, .release);
    try std.testing.expectError(error.StaleLiveSlot, worker_metrics_state.updateLiveSlotCpu(claimed, 5));
    try std.testing.expectError(error.StaleLiveSlot, worker_metrics_state.freeLiveSlot(claimed));

    // Every other slot is claimable, and none is the corrupted one.
    for (1..page.LIVE_SLOT_COUNT) |offset| {
        const other = try worker_metrics_state.allocateLiveSlot(testIdentity(offset + 1));
        try std.testing.expect(other.index != claimed.index);
    }
    try std.testing.expectError(
        error.NoFreeLiveSlot,
        worker_metrics_state.allocateLiveSlot(testIdentity(page.LIVE_SLOT_COUNT + 1)),
    );
    try std.testing.expectEqual(@as(u32, 2), @atomicLoad(u32, &view.live_slots[claimed.index].state, .acquire));
}

test "worker metrics records append and wrap as the host's cursor drains them" {
    const fd = try page.createMemfd("work-state-ring");
    defer std.posix.close(fd);

    var view = try page.mapReadWrite(fd);
    defer view.deinit();
    view.initializeCrashDefault();

    var worker_metrics_state = metrics.WorkState.init(&view);
    var cursor: page.RecordCursor = .{};
    var request_id: u64 = 1;
    while (request_id <= page.RECORD_RING_COUNT + 3) : (request_id += 1) {
        if (request_id == page.RECORD_RING_COUNT + 1) {
            var drained: [page.RECORD_RING_COUNT]page.CompletedRecord = undefined;
            try std.testing.expectEqual(@as(?usize, page.RECORD_RING_COUNT), cursor.drain(view.header, view.completed_records, &drained));
        }
        try worker_metrics_state.appendCompletedRecord(testRecord(request_id));
    }

    var out: [4]page.CompletedRecord = undefined;
    try std.testing.expectEqual(@as(?usize, 3), cursor.drain(view.header, view.completed_records, &out));
    try std.testing.expectEqual(@as(u64, page.RECORD_RING_COUNT + 1), out[0].request_id);
    try std.testing.expectEqual(@as(u64, page.RECORD_RING_COUNT + 3), out[2].request_id);
}

test "a usage record crosses the ring with every measure and meter it carries" {
    const fd = try page.createMemfd("work-state-record-fields");
    defer std.posix.close(fd);

    var view = try page.mapReadWrite(fd);
    defer view.deinit();
    view.initializeCrashDefault();

    const sent = page.CompletedRecord{
        .request_id = 9,
        .request_generation = 8,
        .exec_ns = 7,
        .waiting_ns = 6,
        .io_ns = 5,
        .cpu_ns = 4,
        .client_served_bytes = 3,
        .fetch_sent_bytes = 2,
        .fetch_received_bytes = 1,
        .fetch_wire_bytes = 10,
        .request_slot = 11,
        .request_lane_id = 12,
        .status = @intFromEnum(page.CompletedStatus.worker_stopped),
    };
    var worker_metrics_state = metrics.WorkState.init(&view);
    try worker_metrics_state.appendCompletedRecord(sent);

    var cursor: page.RecordCursor = .{};
    var out: [1]page.CompletedRecord = undefined;
    try std.testing.expectEqual(@as(?usize, 1), cursor.drain(view.header, view.completed_records, &out));
    try std.testing.expectEqualDeep(sent, out[0]);
}

test "worker metrics full ring marks the worker dead and keeps every published record" {
    const fd = try page.createMemfd("work-state-full");
    defer std.posix.close(fd);

    var view = try page.mapReadWrite(fd);
    defer view.deinit();
    view.initializeCrashDefault();

    var worker_metrics_state = metrics.WorkState.init(&view);
    for (0..page.RECORD_RING_COUNT + 1) |index| {
        const result = worker_metrics_state.appendCompletedRecord(testRecord(index + 1));
        if (index < page.RECORD_RING_COUNT)
            try result
        else
            try std.testing.expectError(error.CompletedRecordRingFull, result);
    }

    const lifecycle = page.LifecycleSnapshot.load(view.header);
    try std.testing.expectEqual(page.State.dead, lifecycle.knownState().?);
    try std.testing.expectEqual(page.TerminationReason.crash, lifecycle.knownTerminationReason().?);
    const cursor: page.RecordCursor = .{};
    const peeked = cursor.peek(view.header) orelse return error.TestUnexpectedCorruption;
    try std.testing.expectEqual(@as(u64, page.RECORD_RING_COUNT), peeked.count);
}

test "worker metrics record ring indexes wrap without overflowing counters" {
    const fd = try page.createMemfd("work-state-counter-wrap");
    defer std.posix.close(fd);

    var view = try page.mapReadWrite(fd);
    defer view.deinit();
    view.initializeCrashDefault();

    // Both cursors start two records short of the 64-bit wrap: the page's
    // copy for the worker's room check and the host's own.
    const start = std.math.maxInt(u64) - 1;
    @atomicStore(u64, &view.header.records_tail, start, .release);
    @atomicStore(u64, &view.header.records_head, start, .release);
    var cursor: page.RecordCursor = .{ .tail = start };

    var worker_metrics_state = metrics.WorkState.init(&view);
    try worker_metrics_state.appendCompletedRecord(testRecord(1));
    try worker_metrics_state.appendCompletedRecord(testRecord(2));

    const peeked = cursor.peek(view.header) orelse return error.TestUnexpectedCorruption;
    try std.testing.expectEqual(@as(u64, 2), peeked.count);

    var out: [2]page.CompletedRecord = undefined;
    try std.testing.expectEqual(@as(?usize, 2), cursor.drain(view.header, view.completed_records, &out));
    try std.testing.expectEqual(@as(u64, 1), out[0].request_id);
    try std.testing.expectEqual(@as(u64, 2), out[1].request_id);
    try std.testing.expectEqual(@as(u64, 0), cursor.tail);
    const drained = cursor.peek(view.header) orelse return error.TestUnexpectedCorruption;
    try std.testing.expectEqual(@as(u64, 0), drained.count);
}

test "worker metrics death record comes from the live slot snapshot that matched" {
    const fd = try page.createMemfd("work-state-death-record");
    defer std.posix.close(fd);

    var view = try page.mapReadWrite(fd);
    defer view.deinit();
    view.initializeCrashDefault();

    var worker_metrics_state = metrics.WorkState.init(&view);
    const identity = testIdentity(5);
    const handle = try worker_metrics_state.allocateLiveSlot(identity);
    try worker_metrics_state.updateLiveSlotCpu(handle, 77);
    const snapshot = page.LiveSlotSnapshot.find(view.live_slots, identity) orelse return error.TestExpectedMatch;

    // The worker frees the slot after the snapshot; the record keeps what the
    // snapshot copied.
    try worker_metrics_state.freeLiveSlot(handle);
    try std.testing.expect(page.LiveSlotSnapshot.find(view.live_slots, identity) == null);

    const record = metrics.synthesizeDeathRecord(snapshot, .crash);
    try std.testing.expectEqual(@as(u64, 5), record.request_id);
    try std.testing.expectEqual(@as(u64, 77), record.cpu_ns);
    try std.testing.expectEqual(@intFromEnum(page.CompletedStatus.crash), record.status);
}

test "worker metrics death synthesis keeps the live slot's key and CPU and zeroes the rest" {
    const slot = page.LiveRequestSlot{
        .generation = 1,
        .request_id = 55,
        .request_generation = 4,
        .worker_id = 7,
        .worker_generation = 2,
        .cpu_ns = 20,
        .request_slot = 3,
        .request_lane_id = 1,
        .state = @intFromEnum(page.LiveSlotState.active),
    };
    const record = metrics.synthesizeDeathRecord(page.LiveSlotSnapshot.load(&slot), .deadline);
    try std.testing.expectEqual(@as(u64, 55), record.request_id);
    try std.testing.expectEqual(@as(u64, 4), record.request_generation);
    try std.testing.expectEqual(@as(u32, 3), record.request_slot);
    try std.testing.expectEqual(@as(u16, 1), record.request_lane_id);
    try std.testing.expectEqual(@as(u64, 20), record.cpu_ns);
    try std.testing.expectEqual(@as(u64, 0), record.exec_ns);
    try std.testing.expectEqual(@as(u64, 0), record.waiting_ns);
    try std.testing.expectEqual(@as(u64, 0), record.io_ns);
    try std.testing.expectEqual(@as(u64, 0), record.client_served_bytes);
    try std.testing.expectEqual(@as(u64, 0), record.fetch_wire_bytes);
    try std.testing.expectEqual(@intFromEnum(page.CompletedStatus.deadline), record.status);
}

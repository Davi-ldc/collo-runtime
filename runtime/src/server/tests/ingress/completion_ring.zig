//! The server's side of a worker's completion ring
//! (`common/worker_state/page/completion_ring.zig`): one drain per eventfd
//! wake, a record out of sequence or an overflow turning the ring fatal, and
//! the checks that drop a record of an older worker or request
//! (`IngressLane.applySharedCompletionRecord`). Through a whole lane
//! (`lane_harness.zig`): a record out of sequence is a worker fault that
//! leaves its request to the death path, a record naming another worker
//! generation is dropped and the next one applies, the lane drains from its
//! own tail whatever the worker stores in the page's, and a completion the
//! worker published before the deadline backstop fired wins over it. Lane
//! `server-ingress-test`; a fatal ring and the races between a completion
//! and a worker's death are in `worker_faults.zig`, completions read for
//! another lane in `lane_commands.zig`, and the backstop itself in
//! `request_deadlines.zig`.

const std = @import("std");
const server_main = @import("collo_server_main");
const worker_shared_page = @import("collo_worker_state").page;
const lane_harness = @import("lane_harness.zig");

const ingress = server_main.ingress;
const OneWorker = lane_harness.OneWorker;

/// A completion of request `request_id`, in lane slot `request_slot`, that
/// worker 1 of generation 1 publishes.
fn publishOn(view: *worker_shared_page.WorkerWriterView, request_id: u64, request_slot: u32) !void {
    try view.publishWorkerCompletion(.{
        .external_request_id = request_id,
        .request_lane_id = 0,
        .request_slot = request_slot,
        .request_generation = 1,
        .worker_id = 1,
        .worker_generation = 1,
        .status = @intFromEnum(worker_shared_page.CompletedStatus.done),
        .http_status = 200,
    });
}

test "one drain after an eventfd wake takes every completion and stores the server's tail to the page" {
    const fd = try worker_shared_page.createMemfd("completion-abi");
    defer std.posix.close(fd);
    var view = try worker_shared_page.mapReadWrite(fd);
    defer view.deinit();
    view.initializeCrashDefault(1, 0, 0);
    const event_fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
    defer std.posix.close(event_fd);
    try publishOn(&view, 1, 0);
    try publishOn(&view, 2, 1);
    try worker_shared_page.signalCompletionEventfd(event_fd);
    try std.testing.expectEqual(@as(u64, 1), try worker_shared_page.drainCompletionEventfd(event_fd));

    var out: [worker_shared_page.COMPLETION_RING_COUNT]worker_shared_page.WorkerCompletionRecord = undefined;
    try std.testing.expectEqual(@as(usize, 2), try view.drainWorkerCompletions(&out));
    try std.testing.expectEqual(@as(u64, 1), out[0].external_request_id);
    try std.testing.expectEqual(@as(u64, 2), out[1].external_request_id);
    try std.testing.expectEqual(@as(u64, 2), view.host_cursors.completion_tail);
    try std.testing.expectEqual(@as(u64, 2), @atomicLoad(u64, &view.completion_header.tail, .acquire));
}

test "worker completion sequence mismatch is fatal and does not wedge tail" {
    const fd = try worker_shared_page.createMemfd("completion-sequence-mismatch");
    defer std.posix.close(fd);
    var view = try worker_shared_page.mapReadWrite(fd);
    defer view.deinit();
    view.initializeCrashDefault(1, 0, 0);
    try publishOn(&view, 1, 0);
    view.completion_records[0].sequence = 99;
    var out: [1]worker_shared_page.WorkerCompletionRecord = undefined;
    try std.testing.expectError(error.WorkerCompletionSequenceMismatch, view.drainWorkerCompletions(&out));
    try std.testing.expectEqual(@as(u32, 1), @atomicLoad(u32, &view.completion_header.fatal, .acquire));
    try std.testing.expectEqual(@as(u64, 0), view.host_cursors.completion_tail);
    try std.testing.expectEqual(@as(u64, 0), @atomicLoad(u64, &view.completion_header.tail, .acquire));
}

test "worker completion ring overflow marks shared page fatal" {
    const fd = try worker_shared_page.createMemfd("completion-overflow");
    defer std.posix.close(fd);
    var view = try worker_shared_page.mapReadWrite(fd);
    defer view.deinit();
    view.initializeCrashDefault(1, 0, 0);

    var index: u32 = 0;
    while (index < worker_shared_page.COMPLETION_RING_COUNT) : (index += 1)
        try publishOn(&view, index + 1, index);
    try std.testing.expectError(error.WorkerCompletionRingOverflow, publishOn(&view, 9999, 0));
    try std.testing.expectEqual(@as(u32, 1), @atomicLoad(u32, &view.completion_header.fatal, .acquire));
    try std.testing.expectEqual(@as(u64, 1), @atomicLoad(u64, &view.completion_header.overflow_count, .acquire));
}

test "worker shared-page stale worker generation is ignored and counted" {
    var lane = try ingress.lane.IngressLane.init(std.testing.allocator, .{ .lane_id = 0, .max_connections = 1, .max_requests = 1 }, 0);
    defer lane.deinit();
    const conn = try lane.allocateAcceptedConnection(.{});
    const worker = ingress.state.WorkerKey{ .worker_id = 1, .worker_generation = 2 };
    const req = try lane.state.requests.alloc(1, conn, worker, 0, 1);
    const completion = worker_shared_page.WorkerCompletionRecord{
        .sequence = 1,
        .external_request_id = 1,
        .request_generation = req.generation,
        .worker_id = worker.worker_id,
        .worker_generation = 1,
        .request_slot = req.slot,
        .request_lane_id = req.lane_id,
        .http_status = 200,
        .status = 0,
    };
    try std.testing.expect(!lane.applySharedCompletionRecord(completion));
    try std.testing.expectEqual(@as(u64, 1), lane.completion_counters.stale_worker_generation);
}

test "worker shared-page stale request generation is ignored and counted" {
    var lane = try ingress.lane.IngressLane.init(std.testing.allocator, .{ .lane_id = 0, .max_connections = 1, .max_requests = 1 }, 0);
    defer lane.deinit();
    const conn = try lane.allocateAcceptedConnection(.{});
    const worker = ingress.state.WorkerKey{ .worker_id = 1, .worker_generation = 1 };
    const req = try lane.state.requests.alloc(1, conn, worker, 0, 1);
    _ = lane.state.requests.release(req);
    _ = try lane.state.requests.alloc(2, conn, worker, 0, 1);
    const completion = worker_shared_page.WorkerCompletionRecord{
        .sequence = 1,
        .external_request_id = 1,
        .request_generation = req.generation,
        .worker_id = worker.worker_id,
        .worker_generation = worker.worker_generation,
        .request_slot = req.slot,
        .request_lane_id = req.lane_id,
        .http_status = 200,
        .status = 0,
    };
    try std.testing.expect(!lane.applySharedCompletionRecord(completion));
    try std.testing.expectEqual(@as(u64, 1), lane.completion_counters.stale_request_generation);
}

test "a completion record out of sequence faults its worker and leaves its request to the death path (#34)" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const request = try scene.get(1);

    try scene.stub.publishCompletion(request, .{});
    // The ring's first record must carry sequence 1.
    scene.stub.page_view.completion_records[0].sequence = 99;
    try scene.harness.handleCompletions(0, scene.stub);
    // Nothing of the record is applied: the death path answers the request.
    try scene.expectFaultAnswered(.completion_sequence_mismatch);
}

test "a completion naming another worker generation is dropped, and the next record applies" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const request = try scene.get(1);

    try scene.stub.respond(request, 200, "ok");
    try scene.stub.publishCompletion(request, .{ .worker_generation = scene.stub.key.worker_generation + 1 });
    try scene.stub.publishCompletion(request, .{});
    try scene.harness.serveWorker(0, scene.stub);

    try scene.harness.expectLanesRunning();
    try scene.harness.expectServing(scene.stub);
    try scene.expectStatus(1, 200);
    try std.testing.expectEqual(@as(?u16, 200), scene.harness.takeAccessStatus(0));
    const counters = scene.harness.lane(0).lane.counters;
    try std.testing.expectEqual(@as(u64, 1), counters.stale_worker_completion);
}

test "the lane drains from its own completion tail whatever tail the worker stores in the page" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();

    const first = try scene.get(1);
    try scene.stub.answer(first, 200, "first");
    try scene.harness.serveWorker(0, scene.stub);
    try scene.expectStatus(1, 200);
    try std.testing.expectEqual(@as(?u16, 200), scene.harness.takeAccessStatus(0));

    // The worker stores the tail back to the start of the ring, as if the
    // lane had drained nothing; the first record still sits in its entry.
    @atomicStore(u64, &scene.stub.page_view.completion_header.tail, 0, .release);
    const second = try scene.get(3);
    try scene.stub.answer(second, 200, "second");
    try scene.harness.serveWorker(0, scene.stub);

    try scene.harness.expectLanesRunning();
    try scene.harness.expectServing(scene.stub);
    try scene.expectStatus(3, 200);
    try std.testing.expectEqual(@as(?u16, 200), scene.harness.takeAccessStatus(0));
    // A drain that took its tail from the page would deliver the first
    // record again, and count it stale.
    const counters = scene.harness.lane(0).lane.counters;
    try std.testing.expectEqual(@as(u64, 0), counters.stale_worker_completion);
    try std.testing.expectEqual(@as(u64, 2), @atomicLoad(u64, &scene.stub.page_view.completion_header.tail, .acquire));
}

test "a completion the worker published before the backstop fired wins over the deadline fault" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const request = try scene.get(1);

    // The whole response and its completion are out, and the lane has read
    // neither when the backstop fires.
    try scene.stub.respond(request, 200, "in time");
    try scene.stub.publishCompletion(request, .{});
    try scene.harness.expireDeadlines(0, scene.harness.pastEveryDeadline());

    try scene.harness.expectLanesRunning();
    try scene.harness.expectServing(scene.stub);
    try scene.expectStatus(1, 200);
    const counters = scene.harness.lane(0).lane.counters;
    try std.testing.expectEqual(@as(u64, 1), counters.completion_before_timeout);
    try std.testing.expectEqual(@as(u64, 0), counters.deadline_grace_faults);
}

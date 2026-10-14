//! The fetch tasks a worker holds and the completion items they bound
//! (`worker/egress/fetch_runtime.zig`, `task_runtime.zig` and
//! `State.noteReadyItemPopped`), on a runtime attached to a session whose
//! gateway end the test plays: tasks waiting for their completion to run,
//! with the completions still queued for tasks already gone, stay within
//! `fetches_per_worker_max`, whether or not their fetches still count. No
//! JavaScript runs. Runs in `worker-test`; the fetch count on the gateway's
//! lifetime is covered by `worker/tests/runtime/fetch.zig`.

const std = @import("std");
const support = @import("bindings_support");
const limits = @import("collo_limits");
const worker = @import("collo_worker");
const rt = @import("collo_test_harness");
const egress_support = @import("support.zig");

const allocator = std.testing.allocator;
const fetches_max = limits.worker.fetches_per_worker_max;
const per_request = limits.worker.fetches_per_request_max;
const request_count = fetches_max / per_request;

comptime {
    // The test fills the worker's tasks with whole requests' fetches.
    std.debug.assert(fetches_max % per_request == 0);
}

/// Schedules a bodiless GET for the live request `request_id` with no
/// promise behind it, and returns its fetch id.
fn scheduleGet(runtime: *worker.Runtime, request_id: u64) !u64 {
    return runtime.scheduleFetch(request_id, .{
        .url = "https://origin.test/answer",
        .method = "GET",
        .body = "",
        .headers = &.{},
        .flags = 0,
    }, .{});
}

// A completion item holds its place in the ready queue until it pops, so the
// tasks whose completion waits there, and the completions whose task an
// evaluation's close already destroyed, must keep the worker from starting
// more fetches than the queue has room for. Counting only the fetches the
// gateway still answers for let a worker whose fetches failed at once start
// new ones while their completions waited.
test "a worker refuses a fetch while its waiting tasks and their orphaned completions reach fetches_per_worker_max" {
    var session: rt.RawSession = undefined;
    try session.init();
    defer session.deinit();
    var vm = try support.createVm();
    defer vm.deinit();
    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try egress_support.initRuntime(&vm, &completion_fixture, &now_mono_ns, &session);
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    var actives: [request_count + 1]rt.ActiveRequest = undefined;
    var active_count: usize = 0;
    defer for (actives[0..active_count]) |active| active.deinit();
    for (&actives, 0..) |*active, index| {
        active.* = try rt.ActiveRequest.init(allocator, &runtime, 61 + index, 0);
        active_count += 1;
    }

    // Every fetch fails at the gateway before its head, so it stops counting
    // while its task waits for its completion to run.
    for (actives[0..request_count]) |active| {
        for (0..per_request) |_| {
            const fetch_id = try scheduleGet(&runtime, active.request_id);
            try session.sendErrorFor(&runtime, fetch_id, .failed, "origin unreachable");
        }
    }
    try std.testing.expectEqual(@as(usize, 0), runtime.egress.state.fetches.count());
    try std.testing.expectEqual(@as(usize, fetches_max), runtime.egress.state.tasks.count());
    try std.testing.expectEqual(@as(usize, fetches_max), egress_support.queuedCompletionItems(&runtime));
    const last = actives[request_count];
    try std.testing.expectError(error.FetchWorkerLimitExceeded, scheduleGet(&runtime, last.request_id));

    // Destroying the tasks leaves their completions queued, still counted.
    for (actives[0..request_count]) |active|
        runtime.reapFetchesForRequest(active.request_id);
    try std.testing.expectEqual(@as(usize, 0), runtime.egress.state.tasks.count());
    try std.testing.expectEqual(@as(u32, fetches_max), runtime.egress.state.completion_ready_orphans);
    try std.testing.expectError(error.FetchWorkerLimitExceeded, scheduleGet(&runtime, last.request_id));

    // Once they pop, whether or not they run, the slots come back.
    try egress_support.runQueued(&runtime);
    try std.testing.expectEqual(@as(usize, 0), egress_support.queuedCompletionItems(&runtime));
    try std.testing.expectEqual(@as(u32, 0), runtime.egress.state.completion_ready_orphans);
    _ = try scheduleGet(&runtime, last.request_id);
}

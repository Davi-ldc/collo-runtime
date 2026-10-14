//! The body table's slots and the ready items they bound
//! (`worker/egress/body/register.zig`, `common.zig`, `cleanup.zig` and
//! `State.noteReadyItemPopped`), on a runtime without a gateway session: at
//! most `fetch_bodies_per_worker_max` views, clones included; a body that
//! leaves the table while its ready item waits keeps its slot until the item
//! pops; and a body never has two items queued. Runs in `worker-test`; the
//! body without a runtime is in `body.zig`.

const std = @import("std");
const support = @import("bindings_support");
const limits = @import("collo_limits");
const worker = @import("collo_worker");
const rt = @import("collo_test_harness");
const egress_support = @import("../support.zig");

const egress_body = worker.testing.egress_body;
const allocator = std.testing.allocator;
const bodies_max = limits.worker.fetch_bodies_per_worker_max;

test "a worker holds at most fetch_bodies_per_worker_max body views, clones included, and refuses the next" {
    var vm = try support.createVm();
    defer vm.deinit();
    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try egress_support.initRuntime(&vm, &completion_fixture, &now_mono_ns, null);
    defer runtime.deinit();
    try runtime.attachHostRuntime();
    const active = try rt.ActiveRequest.init(allocator, &runtime, 41, 0);
    defer active.deinit();

    const first = try egress_body.registerOpen(&runtime, active.ctx, 1);
    const second = try egress_body.registerOpen(&runtime, active.ctx, 2);
    for (2..bodies_max) |index|
        _ = try egress_body.registerOpen(&runtime, active.ctx, index + 1);
    try std.testing.expectEqual(@as(usize, bodies_max), runtime.egress.state.bodies.count());
    try std.testing.expectError(error.FetchBodyLimitExceeded, egress_body.registerOpen(&runtime, active.ctx, 9_999));
    try std.testing.expectError(error.FetchBodyLimitExceeded, egress_body.clone(&runtime, second));

    // A view that goes frees its slot for the next clone.
    try std.testing.expect(egress_body.release(&runtime, first));
    _ = try egress_body.clone(&runtime, second);
    try std.testing.expectError(error.FetchBodyLimitExceeded, egress_body.clone(&runtime, second));
}

// The ready queue has room for one item per slot, so an item whose body left
// the table must keep that body's slot until it pops; otherwise new bodies
// and their items fill the queue past its room while the old items wait.
test "a body that leaves the table while its ready item waits keeps its slot until the item pops" {
    var vm = try support.createVm();
    defer vm.deinit();
    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try egress_support.initRuntime(&vm, &completion_fixture, &now_mono_ns, null);
    defer runtime.deinit();
    try runtime.attachHostRuntime();
    const active = try rt.ActiveRequest.init(allocator, &runtime, 42, 0);
    defer active.deinit();

    for (0..bodies_max) |index| {
        const identity = try egress_body.registerOpen(&runtime, active.ctx, index + 1);
        const body = egress_body.ptr(&runtime, identity).?;
        try std.testing.expect(!try body.beginPull(.{ .deferred = null }));
        body.complete();
        egress_body.queueIfReady(&runtime, body);
    }
    try std.testing.expectEqual(@as(usize, bodies_max), egress_support.queuedBodyItems(&runtime));

    // Request cleanup takes every body out of the table; their items stay.
    egress_body.cleanupForRequest(&runtime, 42);
    try std.testing.expectEqual(@as(usize, 0), runtime.egress.state.bodies.count());
    try std.testing.expectEqual(@as(usize, bodies_max), egress_support.queuedBodyItems(&runtime));
    try std.testing.expectError(error.FetchBodyLimitExceeded, egress_body.registerOpen(&runtime, active.ctx, 9_999));

    try egress_support.runQueued(&runtime);
    try std.testing.expectEqual(@as(usize, 0), egress_support.queuedBodyItems(&runtime));
    try std.testing.expectEqual(@as(u32, 0), runtime.egress.state.body_ready_orphans);
    _ = try egress_body.registerOpen(&runtime, active.ctx, 9_999);
}

// A release that keeps the body for its waiting pull used to clear the
// body's claim on the ready queue while its item still waited there, so the
// next chunk queued a second item for the same body.
test "a view released while its ready item waits queues no second item when the next chunk comes" {
    var vm = try support.createVm();
    defer vm.deinit();
    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try egress_support.initRuntime(&vm, &completion_fixture, &now_mono_ns, null);
    defer runtime.deinit();
    try runtime.attachHostRuntime();
    const active = try rt.ActiveRequest.init(allocator, &runtime, 43, 0);
    defer active.deinit();

    const identity = try egress_body.registerOpen(&runtime, active.ctx, 5);
    const body = egress_body.ptr(&runtime, identity).?;
    const item: worker.testing.scheduler.queue.WorkItem = .{ .fetch_body_ready = identity.body_id };
    try std.testing.expect(!try body.beginPull(.{ .deferred = null }));
    try body.appendOwnedChunk(allocator, try allocator.dupe(u8, "a"));
    egress_body.queueReadyViews(&runtime, body);
    try std.testing.expectEqual(@as(usize, 1), egress_support.queuedCount(&runtime, item));

    // The pending pull keeps the released view, which still takes chunks.
    try std.testing.expect(egress_body.release(&runtime, identity));
    try std.testing.expect(egress_body.ptr(&runtime, identity).? == body);
    try body.appendOwnedChunk(allocator, try allocator.dupe(u8, "b"));
    egress_body.queueReadyViews(&runtime, body);
    try std.testing.expectEqual(@as(usize, 1), egress_support.queuedCount(&runtime, item));
}

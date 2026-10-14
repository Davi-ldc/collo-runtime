//! Cancelling and releasing fetch body views on a runtime without a gateway
//! session (`worker/egress/body/cleanup.zig`): an abort answers the read
//! already waiting on the fetch's body, and a cancelled or released encoded
//! source whose decoder paused at the decoded watermark resumes it, so the
//! clone it still feeds completes. Runs in `worker-test`; the body without a
//! runtime is in `body.zig` and the decoder in `decoder.zig`.

const std = @import("std");
const support = @import("bindings_support");
const worker = @import("collo_worker");
const rt = @import("collo_test_harness");
const egress_support = @import("../support.zig");

const egress_body = worker.testing.egress_body;
const allocator = std.testing.allocator;

// An abort used to drop the reader waiting on the body along with its
// queued chunks, so its promise stayed pending until the request ended.
test "aborting a fetch answers the read already waiting on its body" {
    var vm = try support.createVm();
    defer vm.deinit();
    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try egress_support.initRuntime(&vm, &completion_fixture, &now_mono_ns, null);
    defer runtime.deinit();
    try runtime.attachHostRuntime();
    const active = try rt.ActiveRequest.init(allocator, &runtime, 44, 0);
    defer active.deinit();

    const identity = try egress_body.registerOpen(&runtime, active.ctx, 9);
    const body = egress_body.ptr(&runtime, identity).?;
    try std.testing.expect(!try body.beginConsume(.{
        .kind = .text,
        .content_type = try allocator.dupe(u8, ""),
        .deferred = null,
    }));

    egress_body.cancelForFetch(&runtime, 9, null);
    try std.testing.expect(body.isFailed());
    try std.testing.expect(body.hasPendingWaiter());
    try std.testing.expectEqual(
        @as(usize, 1),
        egress_support.queuedCount(&runtime, .{ .fetch_body_ready = identity.body_id }),
    );
}

const PausedClone = struct {
    root: egress_body.Identity,
    branch: egress_body.Identity,
};

/// An encoded source with an open clone whose decoder paused at a decoded
/// watermark of 5 bytes, because the source's own view holds that much
/// unread, with encoded input left and the body's end already seen. Each
/// extent the decoder holds is released into `releases`.
fn pausedEncodedClone(
    runtime: *worker.Runtime,
    active: rt.ActiveRequest,
    releases: *egress_support.ReleaseLog,
    encoded: []u8,
) !PausedClone {
    const root_identity = try egress_body.registerOpen(runtime, active.ctx, 11);
    const root = egress_body.ptr(runtime, root_identity).?;
    const decoder = try allocator.create(egress_body.Decoder);
    decoder.* = egress_body.Decoder.init(.gzip, .{
        .max_decoded_bytes = 64,
        .max_pending_decoded_bytes = 5,
    }) catch |err| {
        allocator.destroy(decoder);
        return err;
    };
    root.decoder = decoder;
    const branch_identity = try egress_body.clone(runtime, root_identity);

    try decoder.pushBorrowed(allocator, root, releases.borrow(encoded, 1));
    try std.testing.expectEqual(@as(usize, 5), root.queuedBytes());
    try std.testing.expect(decoder.pending.items.len != 0 or decoder.needs_output);
    try std.testing.expectEqual(@as(usize, 0), releases.count);
    // The end arrives while the decoder waits, as the gateway runtime hands
    // a body end to it (`gateway_runtime.zig:handleBodyEnd`).
    try std.testing.expect(!try decoder.finish(allocator, root));
    return .{ .root = root_identity, .branch = branch_identity };
}

/// Checks that the clone got the whole decoded body and completed, and that
/// the decoder consumed and released its one extent.
fn expectCloneCompleted(runtime: *worker.Runtime, paused: PausedClone, releases: *const egress_support.ReleaseLog) !void {
    const branch = egress_body.ptr(runtime, paused.branch).?;
    try std.testing.expectEqual(egress_body.State.complete, branch.state);
    try std.testing.expectEqual(@as(usize, "hello world".len), branch.queuedBytes());
    try std.testing.expectEqual(@as(usize, 1), releases.count);
    if (egress_body.ptr(runtime, paused.root)) |root|
        try std.testing.expect(root.decoder == null);
}

// The decoder's room is its source's queue, and only the source's ready item
// or a new extent resumed it; a cancel emptied that queue and resumed
// nothing, so once the end had arrived the clone never completed.
test "cancelling an encoded source whose decoder paused lets the clone it feeds complete" {
    var releases = egress_support.ReleaseLog{};
    var encoded = egress_support.gzip_hello_world;
    var vm = try support.createVm();
    defer vm.deinit();
    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try egress_support.initRuntime(&vm, &completion_fixture, &now_mono_ns, null);
    defer runtime.deinit();
    try runtime.attachHostRuntime();
    const active = try rt.ActiveRequest.init(allocator, &runtime, 45, 0);
    defer active.deinit();

    const paused = try pausedEncodedClone(&runtime, active, &releases, &encoded);
    egress_body.cancel(&runtime, paused.root);
    try expectCloneCompleted(&runtime, paused, &releases);
}

test "releasing an encoded source that still feeds a clone lets its paused decoder finish" {
    var releases = egress_support.ReleaseLog{};
    var encoded = egress_support.gzip_hello_world;
    var vm = try support.createVm();
    defer vm.deinit();
    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try egress_support.initRuntime(&vm, &completion_fixture, &now_mono_ns, null);
    defer runtime.deinit();
    try runtime.attachHostRuntime();
    const active = try rt.ActiveRequest.init(allocator, &runtime, 46, 0);
    defer active.deinit();

    const paused = try pausedEncodedClone(&runtime, active, &releases, &encoded);
    // The released source stays in the table while its clone reads.
    try std.testing.expect(egress_body.release(&runtime, paused.root));
    try std.testing.expect(egress_body.ptr(&runtime, paused.root) != null);
    try expectCloneCompleted(&runtime, paused, &releases);
}

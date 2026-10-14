//! Gateway packets applied to fetch bodies on a runtime attached to a
//! session whose gateway end the test plays (`worker/egress/gateway_runtime.zig`):
//! the acknowledgment of a stop fails the fetch's source body and every clone
//! still open, and answers a clone's waiting read; a packet that does not
//! decode detaches the worker, which then asks to be retired, while a worker
//! whose gateway hung up does not. Runs in `worker-test`; the paths through
//! JavaScript are in `worker/tests/runtime/fetch.zig`.

const std = @import("std");
const support = @import("bindings_support");
const ipc = @import("collo_ipc");
const worker = @import("collo_worker");
const rt = @import("collo_test_harness");
const egress_support = @import("support.zig");

const egress_body = worker.testing.egress_body;
const allocator = std.testing.allocator;

// The acknowledgment used to fail only the source view, so a clone still
// reading waited for chunks the gateway would never send.
test "a stop's acknowledgment fails the source body and the clone still reading it, whose read is answered" {
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
    const active = try rt.ActiveRequest.init(allocator, &runtime, 51, 0);
    defer active.deinit();

    const root_identity = try egress_body.registerOpen(&runtime, active.ctx, 21);
    const branch_identity = try egress_body.clone(&runtime, root_identity);
    const branch = egress_body.ptr(&runtime, branch_identity).?;
    try std.testing.expect(!try branch.beginConsume(.{
        .kind = .text,
        .content_type = try allocator.dupe(u8, ""),
        .deferred = null,
    }));

    const ack = ipc.EgressAbortAck.init(root_identity.fetch_id, root_identity.body_id);
    _ = try session.gateway.completion.writePacket(std.mem.asBytes(&ack));
    _ = try runtime.collectEgressGatewayPacketsBounded(8);

    try std.testing.expect(runtime.egress.state.shared != null);
    try std.testing.expect(egress_body.ptr(&runtime, root_identity).?.isFailed());
    try std.testing.expect(branch.isFailed());
    try std.testing.expectEqual(
        @as(usize, 1),
        egress_support.queuedCount(&runtime, .{ .fetch_body_ready = branch_identity.body_id }),
    );
}

test "a worker that detaches on a packet only a gateway defect writes asks to be retired" {
    var vm = try support.createVm();
    defer vm.deinit();
    var now_mono_ns: u64 = 0;

    var faulted_session: rt.RawSession = undefined;
    try faulted_session.init();
    defer faulted_session.deinit();
    var faulted_completions = try rt.CompletionFixture.init();
    defer faulted_completions.deinit();
    var faulted = try egress_support.initRuntime(&vm, &faulted_completions, &now_mono_ns, &faulted_session);
    defer faulted.deinit();
    try faulted.attachHostRuntime();

    // A kind no completion packet has: the worker detaches, since only a broken gateway writes
    // one, and no gateway will give it a session again.
    const unknown_kind = [_]u8{ 0xff, 0xff, 0x00, 0x00, 0, 0, 0, 0 };
    _ = try faulted_session.gateway.completion.writePacket(&unknown_kind);
    _ = try faulted.collectEgressGatewayPacketsBounded(8);
    try std.testing.expect(faulted.egress.state.shared == null);
    try faulted.checkRetirement();
    try std.testing.expectEqual(@as(?ipc.WorkerRetiringReason, .egress_detached), faulted.retirement.reason);
}

test "a worker whose gateway hung up detaches without asking to be retired" {
    var vm = try support.createVm();
    defer vm.deinit();
    var now_mono_ns: u64 = 0;
    var session: rt.RawSession = undefined;
    try session.init();
    defer session.deinit();
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try egress_support.initRuntime(&vm, &completion_fixture, &now_mono_ns, &session);
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    // The loop's answer to the hang-up of the pipe the gateway holds: the server gives the worker
    // a session of the next gateway, or retires it when the gateway removed the session.
    runtime.disconnectEgressGatewayWithReason("liveness_hup");
    try std.testing.expect(runtime.egress.state.shared == null);
    try runtime.checkRetirement();
    try std.testing.expectEqual(@as(?ipc.WorkerRetiringReason, null), runtime.retirement.reason);
}

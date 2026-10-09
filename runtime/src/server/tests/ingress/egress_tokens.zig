//! The egress token an ingress lane mints for each request it dispatches and
//! the `request_ended` entry the request's finish owes the gateway, driven
//! through `lane_harness.zig` with its `EgressGateways` standing in for the
//! manager. A lane mints from its own lease, and only for a worker whose
//! session belongs to the gateway the lease holds; any other dispatch carries
//! `egress_token.none` and its finish owes nothing. The ends a pass noted
//! leave as one packet when the pass ends, and a lane's teardown sends what
//! it still holds before it closes the lease. A pass renews the lease only
//! when the manager's generation moved. Lane `server-ingress-test`; the lease
//! alone is covered in `server/tests/gateway/lease.zig`, and the gateway's
//! checks of the token in `egress/tests/gateway/worker_flow.zig`.

const std = @import("std");
const ipc = @import("collo_ipc");
const control = @import("collo_egress_gateway").control;
const policy = @import("collo_egress_gateway").policy;
const lane_harness = @import("lane_harness.zig");

const egress_token = ipc.egress_token;
const runner = lane_harness.runner;
const Dispatched = lane_harness.Dispatched;
const Harness = lane_harness.Harness;
const OneWorker = lane_harness.OneWorker;

const gateway_generation: u64 = 3;
const gateway_key: egress_token.Key = .{ .bytes = @splat(0x3c) };
const next_gateway_key: egress_token.Key = .{ .bytes = @splat(0xc3) };
const session_id: u64 = 77;

test "a request token names the request, its deadline, the single policy entry and the request budget" {
    const slot: runner.request_slot.RequestSlot = .{
        .request_key = .{ .lane_id = 1, .slot = 2, .generation = 4 },
        .request_id = 9,
        .deadline_ns = 1_000,
    };
    try std.testing.expectEqual(egress_token.Fields{
        .kind = .request,
        .policy_id = policy.public_https_id,
        .budget = policy.production.max_fetches_per_request,
        .session_id = session_id,
        .request_id = 9,
        .request_generation = 4,
        .deadline_monotonic_ns = 1_000,
    }, runner.dispatch.requestTokenFields(&slot, session_id));
}

test "a dispatch to a worker of the lease's gateway carries a token its key verifies and sends the gateway nothing (#31)" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const harness = &scene.harness;
    try attachToGateway(harness, scene.stub);

    const request = try scene.get(1);
    const token = egress_token.fromBytes(&request.egress_token);
    try std.testing.expectEqual(egress_token.Fields{
        .kind = .request,
        .policy_id = policy.public_https_id,
        .budget = policy.production.max_fetches_per_request,
        .session_id = session_id,
        .request_id = request.identity.request_id,
        .request_generation = request.identity.request_generation,
        .deadline_monotonic_ns = request.deadline_monotonic_ns,
    }, try egress_token.verify(&gateway_key, &token));
    try std.testing.expectError(error.BadTag, egress_token.verify(&next_gateway_key, &token));

    // The slot keeps the session its finish owes an end to, and the dispatch
    // sent the gateway nothing.
    const slot = harness.requestSlotOf(scene.client, 1) orelse return error.RequestNotAdmitted;
    try std.testing.expectEqual(gateway_generation, slot.egress_gateway_generation);
    try std.testing.expectEqual(session_id, slot.egress_gateway_session_id);
    try expectNothingSent(harness);
}

test "a worker without a session of the lease's gateway gets no token and its finish sends nothing" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const harness = &scene.harness;
    try harness.egress_gateways.install(gateway_generation, gateway_key);
    harness.renewEgressLease(0);

    // A worker launched without a session, then one whose session belongs to
    // an earlier gateway and waits for its reattach.
    const sessions = [_]u64{ 0, gateway_generation - 1 };
    for (sessions, 0..) |generation, index| {
        if (generation != 0)
            try harness.setWorkerEgress(scene.stub, generation, session_id);
        const stream_id: u32 = @intCast(2 * index + 1);
        const request = try scene.get(stream_id);
        try std.testing.expect(egress_token.isNone(&request.egress_token));
        const slot = harness.requestSlotOf(scene.client, stream_id) orelse return error.RequestNotAdmitted;
        try std.testing.expectEqual(@as(u64, 0), slot.egress_gateway_generation);
        try std.testing.expectEqual(@as(u64, 0), slot.egress_gateway_session_id);

        try scene.stub.answer(request, 200, "ok");
        try harness.serveWorker(0, scene.stub);
        try scene.expectStatus(stream_id, 200);
        try std.testing.expect(harness.requestKeyOf(scene.client, stream_id) == null);
        try expectNothingSent(harness);
    }
}

test "the requests a pass finishes reach the gateway as one request_ended packet when the pass ends" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const harness = &scene.harness;
    try attachToGateway(harness, scene.stub);

    const first = try scene.get(1);
    const second = try scene.get(3);
    try scene.stub.answer(first, 200, "first");
    try scene.stub.answer(second, 200, "second");
    try harness.handleControl(0, scene.stub);
    try expectNothingSent(harness);

    // Both completions end their requests in one pass.
    try harness.handleCompletions(0, scene.stub);
    try scene.expectStatus(1, 200);
    try scene.expectStatus(3, 200);
    try expectEnded(harness, &.{ endedEntry(first), endedEntry(second) });
    try expectNothingSent(harness);
    try std.testing.expectEqual(@as(u64, 0), harness.lane(0).egress_lease.ended_batches_dropped_full);
    try std.testing.expectEqual(@as(u64, 0), harness.lane(0).egress_lease.ended_batches_dropped_closed);
}

test "a pass renews the lease only when the manager's generation moved" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const harness = &scene.harness;
    const gateways = &harness.egress_gateways;
    const lease = &harness.lane(0).egress_lease;

    // No gateway is current and the lease holds none.
    harness.renewEgressLease(0);
    try std.testing.expectEqual(@as(u32, 0), gateways.renewals);

    try gateways.install(gateway_generation, gateway_key);
    harness.renewEgressLease(0);
    harness.renewEgressLease(0);
    try std.testing.expectEqual(@as(u32, 1), gateways.renewals);
    try std.testing.expectEqual(gateway_generation, lease.generation);

    try gateways.install(gateway_generation + 1, next_gateway_key);
    harness.renewEgressLease(0);
    harness.renewEgressLease(0);
    try std.testing.expectEqual(@as(u32, 2), gateways.renewals);
    try std.testing.expectEqual(gateway_generation + 1, lease.generation);

    // Once the gateway is lost, the next pass empties the lease, and a worker
    // of the lost gateway gets no token.
    try harness.setWorkerEgress(scene.stub, gateway_generation + 1, session_id);
    gateways.retire();
    harness.renewEgressLease(0);
    harness.renewEgressLease(0);
    try std.testing.expectEqual(@as(u32, 3), gateways.renewals);
    try std.testing.expectEqual(@as(u64, 0), lease.generation);
    try std.testing.expectEqual(@as(u32, 0), gateways.renewals_failed);
    const request = try scene.get(1);
    try std.testing.expect(egress_token.isNone(&request.egress_token));
}

test "a lane's teardown sends the ends of the requests it finishes before it closes the lease" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const harness = &scene.harness;
    try attachToGateway(harness, scene.stub);

    // The request is still open when its lane stops, which finishes it as a
    // shutdown.
    const request = try scene.get(1);
    harness.stopLanes();
    try expectEnded(harness, &.{endedEntry(request)});
    try expectNothingSent(harness);
    try std.testing.expectEqual(@as(u64, 0), harness.lane(0).egress_lease.generation);
}

/// Installs gateway `gateway_generation` under `gateway_key`, renews lane 0's
/// lease, and gives `stub` session `session_id` of that gateway.
fn attachToGateway(harness: *Harness, stub: *const lane_harness.StubWorker) !void {
    try harness.egress_gateways.install(gateway_generation, gateway_key);
    harness.renewEgressLease(0);
    try std.testing.expectEqual(gateway_generation, harness.lane(0).egress_lease.generation);
    try harness.setWorkerEgress(stub, gateway_generation, session_id);
}

fn endedEntry(request: Dispatched) control.RequestEndedEntry {
    return .{
        .session_id = session_id,
        .request_id = request.identity.request_id,
        .request_generation = request.identity.request_generation,
    };
}

/// Reads one packet from the gateway's end and checks that it is a
/// `request_ended` naming `expected`, in order.
fn expectEnded(harness: *Harness, expected: []const control.RequestEndedEntry) !void {
    var scratch: [control.request_ended_bytes_max]u8 = undefined;
    var packet = try ipc.recvPacketWithFdsScratch(
        std.testing.allocator,
        harness.egress_gateways.gateway_end.fd(),
        &scratch,
    );
    defer packet.deinit();
    const ended = switch (try control.decode(&packet)) {
        .request_ended => |ended| ended,
        else => return error.TestUnexpectedControlMessage,
    };
    try std.testing.expectEqual(expected.len, ended.count);
    for (expected, 0..) |entry, index|
        try std.testing.expectEqual(entry, ended.entry(index));
}

fn expectNothingSent(harness: *Harness) !void {
    var scratch: [control.request_ended_bytes_max]u8 = undefined;
    try std.testing.expectError(error.WouldBlock, ipc.recvPacketWithFdsScratch(
        std.testing.allocator,
        harness.egress_gateways.gateway_end.fd(),
        &scratch,
    ));
}

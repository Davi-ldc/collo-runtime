//! The egress token an ingress lane mints for each request it dispatches,
//! driven through `lane_harness.zig` with its `EgressGateways` standing in
//! for the manager. A token names its route's network policy, compiled from
//! the configuration (`server/routes/network.zig`). A lane mints from its own
//! lease, and only for a worker whose session belongs to the gateway the
//! lease holds; any other dispatch carries `egress_token.none`. A lease holds
//! no descriptor of the gateway, so neither a dispatch nor a finish can send
//! it anything (`server/tests/gateway/lease.zig`). A pass renews the lease
//! only when the manager's generation moved. Lane `server-ingress-test`; the
//! lease alone is covered in `server/tests/gateway/lease.zig`, the compiled
//! policies in `server/tests/routes/network.zig`, and the gateway's checks of
//! the token in `egress/tests/gateway/command_flow.zig`.

const std = @import("std");
const ipc = @import("collo_ipc");
const config = @import("collo_server_config");
const routes = @import("collo_server_routes");
const lane_harness = @import("lane_harness.zig");

const egress_token = ipc.egress_token;
const runner = lane_harness.runner;
const Harness = lane_harness.Harness;
const OneWorker = lane_harness.OneWorker;

const gateway_generation: u64 = 3;
const gateway_key: egress_token.Key = .{ .bytes = @splat(0x3c) };
const next_gateway_key: egress_token.Key = .{ .bytes = @splat(0xc3) };
const session_id: u64 = 77;

test "a request token names the request, its deadline and the policy it is given" {
    const slot: runner.request_slot.RequestSlot = .{
        .request_key = .{ .lane_id = 1, .slot = 2, .generation = 4 },
        .request_id = 9,
        .deadline_ns = 1_000,
    };
    try std.testing.expectEqual(egress_token.Fields{
        .kind = .request,
        .policy_id = 7,
        .session_id = session_id,
        .request_id = 9,
        .request_generation = 4,
        .deadline_monotonic_ns = 1_000,
    }, runner.dispatch.requestTokenFields(&slot, session_id, 7));
}

test "two routes of one definition with different values produce tokens with different policy ids, and a route without network produces policy 0" {
    const allocator = std.testing.allocator;
    var diagnostic: config.Diagnostic = .{};
    var parsed = config.parse(allocator,
        \\{"workers": {"api": {"routes": {
        \\   "/a": {"entry": "a.js", "network": {"allow": ["a.example.com"]}},
        \\   "/b": {"entry": "b.js", "network": {"allow": ["b.example.com"]}},
        \\   "/c": {"entry": "c.js"}
        \\ }}}}
    , "/srv/app/collo.json", &diagnostic) catch |err| {
        std.debug.print("unexpected rejection: {s}\n", .{diagnostic.message()});
        return err;
    };
    defer parsed.deinit();
    var policies: routes.NetworkPolicies = undefined;
    try policies.init(allocator, parsed.definitions, &diagnostic);
    defer policies.deinit(allocator);

    var policy_ids: [3]u16 = undefined;
    for (&policy_ids, 0..) |*policy_id, index| {
        const slot: runner.request_slot.RequestSlot = .{
            .request_key = .{ .lane_id = 1, .slot = 2, .generation = 4 },
            .request_id = 9,
            .deadline_ns = 1_000,
            .route = .{ .definition = 0, .route = @intCast(index) },
        };
        policy_id.* = runner.dispatch.requestTokenFields(&slot, session_id, policies.routePolicy(slot.route)).policy_id;
    }
    try std.testing.expect(policy_ids[0] != routes.network.deny_all_id);
    try std.testing.expect(policy_ids[1] != routes.network.deny_all_id);
    try std.testing.expect(policy_ids[0] != policy_ids[1]);
    try std.testing.expectEqual(routes.network.deny_all_id, policy_ids[2]);
}

test "a dispatch to a worker of the lease's gateway carries a token its key verifies (#31)" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const harness = &scene.harness;
    try attachToGateway(harness, scene.stub);

    const request = try scene.get(1);
    const slot = harness.requestSlotOf(scene.client, 1) orelse return error.RequestNotAdmitted;
    // The fixture's routes are granted, so the token names a policy that
    // admits something.
    const route_policy = harness.service.routes.network.routePolicy(slot.route);
    try std.testing.expect(route_policy != routes.network.deny_all_id);
    const token = egress_token.fromBytes(&request.egress_token);
    try std.testing.expectEqual(egress_token.Fields{
        .kind = .request,
        .policy_id = route_policy,
        .session_id = session_id,
        .request_id = request.identity.request_id,
        .request_generation = request.identity.request_generation,
        .deadline_monotonic_ns = request.deadline_monotonic_ns,
    }, try egress_token.verify(&gateway_key, &token));
    try std.testing.expectError(error.BadTag, egress_token.verify(&next_gateway_key, &token));

    try scene.stub.answer(request, 200, "ok");
    try harness.handleControl(0, scene.stub);
    try scene.expectStatus(1, 200);
}

test "a worker without a session of the lease's gateway gets no token" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const harness = &scene.harness;
    harness.egress_gateways.install(gateway_generation, gateway_key);
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

        try scene.stub.answer(request, 200, "ok");
        try harness.handleControl(0, scene.stub);
        try scene.expectStatus(stream_id, 200);
        try std.testing.expect(harness.requestKeyOf(scene.client, stream_id) == null);
    }
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

    gateways.install(gateway_generation, gateway_key);
    harness.renewEgressLease(0);
    harness.renewEgressLease(0);
    try std.testing.expectEqual(@as(u32, 1), gateways.renewals);
    try std.testing.expectEqual(gateway_generation, lease.generation);

    gateways.install(gateway_generation + 1, next_gateway_key);
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
    try std.testing.expect(lease.key.isZero());
    const request = try scene.get(1);
    try std.testing.expect(egress_token.isNone(&request.egress_token));
}

/// Installs gateway `gateway_generation` under `gateway_key`, renews lane 0's
/// lease, and gives `stub` session `session_id` of that gateway.
fn attachToGateway(harness: *Harness, stub: *const lane_harness.StubWorker) !void {
    harness.egress_gateways.install(gateway_generation, gateway_key);
    harness.renewEgressLease(0);
    try std.testing.expectEqual(gateway_generation, harness.lane(0).egress_lease.generation);
    try harness.setWorkerEgress(stub, gateway_generation, session_id);
}

//! The lease an ingress lane holds on the current egress gateway (`server/gateway/lease.zig`): it
//! holds the gateway's generation and key alone, so minting a request's token sends the gateway
//! nothing, and it mints only for workers of the gateway it holds. Renewing the lease scrubs the
//! previous key. The manager that hands leases out is covered in `manager.zig`. Lane:
//! server-gateway.

const std = @import("std");
const ipc = @import("collo_ipc");
const gateway = @import("collo_server_gateway");

const egress_token = ipc.egress_token;
const Lease = gateway.lease.Lease;

const lease_key: egress_token.Key = .{ .bytes = @splat(0x5a) };
const other_key: egress_token.Key = .{ .bytes = @splat(0xa5) };
const zero_key: egress_token.Key = .{ .bytes = @splat(0) };
const generation: u64 = 7;
const session_id: u64 = 41;

test "a lease mints from its key alone and holds no descriptor of the gateway (#31)" {
    // The generation and the key are all a lane holds, so it has nothing to send the gateway a
    // packet on.
    const fields = std.meta.fields(Lease);
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expectEqualStrings("generation", fields[0].name);
    try std.testing.expectEqualStrings("key", fields[1].name);
    var lease: Lease = .{};
    defer lease.deinit();
    lease.replace(generation, lease_key);

    const request_count: usize = 64;
    for (1..request_count + 1) |request_id| {
        const token = lease.mint(generation, requestFields(request_id));
        try expectToken(&token, &lease_key, requestFields(request_id));
    }
}

test "a lease mints tokens only for workers of the gateway it holds" {
    var lease: Lease = .{};
    defer lease.deinit();
    // A lease that holds no gateway mints nothing.
    try expectNone(&lease.mint(0, requestFields(1)));
    try expectNone(&lease.mint(generation, requestFields(1)));

    lease.replace(generation, lease_key);
    // A worker whose session belongs to another gateway is detached or waiting for its
    // reattach, so its request carries no token and the worker refuses the fetch itself.
    try expectNone(&lease.mint(generation - 1, requestFields(1)));
    try expectNone(&lease.mint(generation + 1, requestFields(1)));
    try expectNone(&lease.mint(0, requestFields(1)));

    const minted = lease.mint(generation, requestFields(1));
    try expectToken(&minted, &lease_key, requestFields(1));
    const token = egress_token.fromBytes(&minted);
    try std.testing.expectError(error.BadTag, egress_token.verify(&other_key, &token));
}

test "renewing the lease mints under the new key alone" {
    var lease: Lease = .{};
    defer lease.deinit();

    lease.replace(generation, lease_key);
    lease.replace(generation + 1, other_key);
    try std.testing.expectEqualSlices(u8, &other_key.bytes, &lease.key.bytes);

    try expectNone(&lease.mint(generation, requestFields(2)));
    const minted = lease.mint(generation + 1, requestFields(2));
    try expectToken(&minted, &other_key, requestFields(2));
    const token = egress_token.fromBytes(&minted);
    try std.testing.expectError(error.BadTag, egress_token.verify(&lease_key, &token));
}

test "a lease renewed while no gateway is current mints nothing and keeps no key" {
    var lease: Lease = .{};
    defer lease.deinit();
    lease.replace(generation, lease_key);

    // With no gateway current the manager hands out generation 0 and the zero key.
    lease.replace(0, zero_key);
    try std.testing.expect(lease.key.isZero());
    try expectNone(&lease.mint(0, requestFields(2)));
    try expectNone(&lease.mint(generation, requestFields(2)));
}

fn requestFields(request_id: u64) egress_token.Fields {
    return .{
        .kind = .request,
        .policy_id = 0,
        .session_id = session_id,
        .request_id = request_id,
        .request_generation = request_id + 1_000,
        .deadline_monotonic_ns = 5_000_000_000 + request_id,
    };
}

fn expectToken(
    bytes: *const egress_token.Bytes,
    key: *const egress_token.Key,
    expected: egress_token.Fields,
) !void {
    try std.testing.expect(!egress_token.isNone(bytes));
    const token = egress_token.fromBytes(bytes);
    try std.testing.expectEqual(expected, try egress_token.verify(key, &token));
}

fn expectNone(bytes: *const egress_token.Bytes) !void {
    try std.testing.expect(egress_token.isNone(bytes));
}

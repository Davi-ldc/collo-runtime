//! A client connection's kTLS rekey state across the requests it carries:
//! the state the connection's TLS handshake installed stays the connection's,
//! byte for byte, when a request a worker answered finishes. Driven through
//! `lane_harness.zig` against a stub worker. Lane `server-ingress-test`; the
//! KeyUpdate that advances the state on a kernel TLS socket is covered in
//! `common/tests/ktls.zig`.

const std = @import("std");
const ktls = @import("collo_ktls");
const lane_harness = @import("lane_harness.zig");

const OneWorker = lane_harness.OneWorker;

test "a connection keeps its kTLS rekey state byte for byte across a request its worker finishes" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const harness = &scene.harness;

    // A TLS 1.3 state after several KeyUpdates in each direction, as the
    // handshake and the connection's own reads leave it. The harness's
    // socket carries no kernel TLS, so the lane's reads through the state see
    // only application data.
    const connection = &harness.lane(0).connections.entries[scene.client.slot];
    connection.ktls_rekey_state = try ktls.RekeyState.initTls13(
        ktls.tls13_aes_128_gcm_sha256,
        &client_to_server_secret,
        &server_to_client_secret,
    );
    connection.ktls_rekey_state.read_generation = 3;
    connection.ktls_rekey_state.write_generation = 5;
    var installed = connection.ktls_rekey_state;
    defer installed.zero();

    const request = try scene.get(1);
    try scene.stub.answer(request, 200, "ok");
    try harness.serveWorker(0, scene.stub);
    try scene.expectStatus(1, 200);
    try std.testing.expect(harness.requestKeyOf(scene.client, 1) == null);

    try std.testing.expect(scene.client.open());
    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&installed),
        std.mem.asBytes(&connection.ktls_rekey_state),
    );
}

const client_to_server_secret = [_]u8{0x5a} ** 32;
const server_to_client_secret = [_]u8{0xa5} ** 32;

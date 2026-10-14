//! The gateway's end of the control socket (`runtime/control_flow.zig`), over the real gateway in
//! `support/gateway.zig` with the test as the server. The hello gives the gateway its key and the
//! policies of the image it lends, looked up by id, which admission then applies, and leaves no
//! copy of the key in the gateway's scratch; an image whose memfd lacks the write seal, whose size
//! is not the hello's length or that does not decode ends the gateway, which then admits nothing.
//! A token's policy places its fetch by that policy's pool id. Before the hello the gateway takes
//! nothing but shutdown, and a second hello ends it. An attach the gateway cannot map, or one past
//! its session limit, is refused with a `rejected` ack and leaves the gateway and its other
//! sessions running. `boot_ended` ends the boot token of the session it names and of no other,
//! and fails the fetches that token admitted, an assembling upload at once and a running fetch
//! once its engine let go, leaving request fetches alone; one for a session the gateway does not
//! hold is skipped, and a repeated one changes nothing. A
//! session the gateway removes on its own reaches the server as a report, except one whose attach
//! ack never left; a report the full socket holds back leaves in order once there is room, one the
//! server can no longer receive is dropped, and one that can be neither sent nor queued ends the
//! gateway. The wire format of these packets is covered in `control.zig`, the image's own rules in
//! `common/tests/network/` and admission in `command_flow.zig`. Lane: egress-gateway-test.

const std = @import("std");
const gateway = @import("collo_egress_gateway");
const os = @import("collo_os");
const network = @import("collo_egress_client").network;

const gateway_support = @import("support/gateway.zig");
const policy_image = @import("support/policy_image.zig");

const control = gateway.control;
const policy = gateway.policy;
const runtime = gateway.runtime;
const Harness = gateway_support.Harness;

const any_host = [_]network.Pattern{.{ .host = .any, .port = 0 }};

/// Passes when the packet waiting on the control socket breaks the hello's order: `drainControl`
/// fails with it, which ends the gateway's loop, so the server sees the channel fail.
fn expectOutOfOrder(harness: *Harness) !void {
    try std.testing.expectError(
        error.EgressGatewayControlOutOfOrder,
        runtime.control_flow.drainControl(harness.gateway),
    );
}

test "the hello gives the gateway its key and the image's policies by id" {
    var harness = try Harness.init(.{ .hello = false });
    defer harness.deinit();
    try std.testing.expect(harness.gateway.hello.key.isZero());
    try std.testing.expect(harness.gateway.hello.lookup(0) == null);

    const image = try policy_image.standard(std.testing.allocator);
    defer std.testing.allocator.free(image);
    var memfd = try policy_image.memfdHolding(image, os.fd.memfd_readonly_seals);
    defer memfd.deinit();
    try harness.sendHello(memfd.fd(), @intCast(image.len));
    try harness.drainControl();

    try std.testing.expect(harness.gateway.hello.received);
    try std.testing.expectEqualSlices(u8, &gateway_support.hello_key.bytes, &harness.gateway.hello.key.bytes);
    try std.testing.expectEqual(policy_image.standard_policy_count, harness.gateway.hello.policyCount());
    // Policy 0 grants nothing, the next any public host over HTTPS, the last over HTTP as well.
    const granted_nothing = harness.gateway.hello.lookup(0) orelse return error.MissingPolicy;
    try std.testing.expectEqual(@as(usize, 0), granted_nothing.grants.len);
    const https_only = harness.gateway.hello.lookup(policy_image.public_https_id) orelse
        return error.MissingPolicy;
    try std.testing.expectEqual(@as(usize, 1), https_only.grants.len);
    try std.testing.expect(https_only.grants[0].any);
    try std.testing.expect(!https_only.grants[0].allow_http);
    const with_http = harness.gateway.hello.lookup(policy_image.public_http_and_https_id) orelse
        return error.MissingPolicy;
    try std.testing.expect(with_http.grants[0].allow_http);
    try std.testing.expect(harness.gateway.hello.lookup(@intCast(policy_image.standard_policy_count)) == null);

    // The scratch control packets and worker commands pass through, and the one worker-bound
    // packets are encoded in, keep no copy of the key.
    try std.testing.expect(std.mem.indexOf(u8, harness.gateway.read_scratch, &gateway_support.hello_key.bytes) == null);
    try std.testing.expect(std.mem.indexOf(u8, harness.gateway.encode_scratch, &gateway_support.hello_key.bytes) == null);

    // A token minted under the hello's key now admits.
    try harness.expectAdmitted(.{ .fetch_id = 1, .body_id = 1, .token = harness.token(.{}), .pooled_body_len = 8 });
}

test "a hello whose memfd lacks the write seal, whose size differs from its length, or whose image is corrupt ends the gateway and admits nothing" {
    const image = try policy_image.standard(std.testing.allocator);
    defer std.testing.allocator.free(image);
    const corrupt = try std.testing.allocator.dupe(u8, image);
    defer std.testing.allocator.free(corrupt);
    // A changed magic matches no image.
    corrupt[0] ^= 1;

    const Case = struct {
        bytes: []const u8,
        seals: usize,
        table_bytes: u32,
    };
    const cases = [_]Case{
        // Sealed against resizes alone, so its bytes could still change after the gateway read
        // them.
        .{ .bytes = image, .seals = os.fd.memfd_size_seals, .table_bytes = @intCast(image.len) },
        .{ .bytes = image, .seals = os.fd.memfd_readonly_seals, .table_bytes = @intCast(image.len - 1) },
        .{ .bytes = corrupt, .seals = os.fd.memfd_readonly_seals, .table_bytes = @intCast(corrupt.len) },
    };
    for (cases) |case| {
        var harness = try Harness.init(.{ .hello = false });
        defer harness.deinit();
        var memfd = try policy_image.memfdHolding(case.bytes, case.seals);
        defer memfd.deinit();
        try harness.sendHello(memfd.fd(), case.table_bytes);
        try std.testing.expectError(
            error.InvalidEgressGatewayPolicyImage,
            runtime.control_flow.drainControl(harness.gateway),
        );

        try std.testing.expect(!harness.gateway.hello.received);
        try std.testing.expect(harness.gateway.hello.key.isZero());
        try std.testing.expectEqual(@as(usize, 0), harness.gateway.hello.policyCount());
        // A token minted under the hello's key verifies under no key the gateway holds.
        try harness.expectRefused(
            .{ .fetch_id = 1, .body_id = 1, .token = harness.token(.{}) },
            "invalid egress token",
        );
    }
}

test "a token's policy places its fetch by that policy's pool id" {
    const shard_count: usize = 4;
    var harness = try Harness.init(.{ .shard_count = shard_count });
    defer harness.deinit();

    // Policy 0, which grants nothing, is admitted like the others; the transport refuses its
    // fetches once they run.
    for (0..policy_image.standard_policy_count) |index| {
        const policy_id: network.PolicyId = @intCast(index);
        const fetch_id: u64 = 10 + index;
        try harness.expectAdmitted(.{
            .fetch_id = fetch_id,
            .body_id = fetch_id,
            .token = harness.token(.{ .policy_id = policy_id, .request_id = 50 + index }),
            .pooled_body_len = 8,
        });
        const record = harness.record(fetch_id) orelse return error.MissingRecord;
        var url_buffer: [gateway_support.loopback_url_bytes_max]u8 = undefined;
        const expected_shard = gateway.shard.hashFetch(.{
            .security_cell_id = gateway_support.security_cell_id,
            .policy_id = policy.poolPolicyId(policy_id),
        }, gateway_support.loopbackUrl(&url_buffer, fetch_id), shard_count);
        try std.testing.expectEqual(expected_shard, record.shard_index);
    }
}

test "before its hello the gateway ends on any packet but shutdown" {
    // A `boot_ended` before the hello.
    {
        var harness = try Harness.init(.{ .hello = false });
        defer harness.deinit();
        try control.sendBootEnded(harness.server_fd, harness.session_id);
        try expectOutOfOrder(&harness);
        try std.testing.expect(!harness.session().boot_ended);
    }
    // An attach before the hello: the gateway neither maps the session nor acknowledges it.
    {
        var harness = try Harness.init(.{ .hello = false });
        defer harness.deinit();
        var fds = try gateway_support.createSession();
        defer fds.deinit();
        try control.sendAttachWorker(harness.server_fd, 1, gateway_support.security_cell_id, fds.rawForGateway());
        try expectOutOfOrder(&harness);
        try std.testing.expectEqual(@as(usize, 1), harness.gateway.sessions.len());
        try harness.expectNoServerPacket();
    }
    // Shutdown before the hello is an orderly stop.
    {
        var harness = try Harness.init(.{ .hello = false });
        defer harness.deinit();
        try control.sendShutdown(harness.server_fd);
        try std.testing.expect(try runtime.control_flow.drainControl(harness.gateway));
    }
}

test "a second hello ends the gateway and leaves the first key and policies in place" {
    var harness = try Harness.init(.{});
    defer harness.deinit();

    // An image of one policy besides policy 0, which would shrink the table were it taken.
    const settings = [_]network.Setting{.{ .allow = &any_host, .allow_http = true }};
    const members = [_]usize{0};
    const policies = [_][]const usize{&members};
    const image = try policy_image.encode(std.testing.allocator, &settings, &policies);
    defer std.testing.allocator.free(image);
    var memfd = try policy_image.memfdHolding(image, os.fd.memfd_readonly_seals);
    defer memfd.deinit();
    try control.sendHello(harness.server_fd, &gateway_support.earlier_key, memfd.fd(), @intCast(image.len));
    try expectOutOfOrder(&harness);

    try std.testing.expectEqualSlices(u8, &gateway_support.hello_key.bytes, &harness.gateway.hello.key.bytes);
    try std.testing.expectEqual(policy_image.standard_policy_count, harness.gateway.hello.policyCount());
}

test "an attach the gateway cannot map is refused alone and its other sessions keep running" {
    var harness = try Harness.init(.{});
    defer harness.deinit();

    var mapped = try gateway_support.createSession();
    defer mapped.deinit();
    try harness.sendAttach(1, mapped.rawForGateway());
    const mapped_session = try harness.expectAttachAck(1, .ok);
    try std.testing.expectEqual(@as(usize, 2), harness.gateway.sessions.len());

    // The worker's half grants the worker's access to each region, so the gateway cannot map the
    // regions it writes.
    var unmappable = try gateway_support.createSession();
    defer unmappable.deinit();
    try harness.sendAttach(2, unmappable.rawForWorker());
    try std.testing.expectEqual(@as(u64, 0), try harness.expectAttachAck(2, .rejected));
    try harness.expectNoServerPacket();
    try std.testing.expectEqual(@as(usize, 2), harness.gateway.sessions.len());

    // The session attached before still admits a fetch under its own token.
    const session = harness.gateway.sessions.byId(mapped_session) orelse return error.MissingSession;
    const start = try harness.encodeFetchStart(.{
        .fetch_id = 1,
        .body_id = 1,
        .token = harness.token(.{ .session_id = mapped_session }),
        .pooled_body_len = 8,
    });
    try std.testing.expect(runtime.command_flow.handlePacket(harness.gateway, session, start));
    try std.testing.expect(harness.gateway.fetches.find(mapped_session, 1) != null);
    try std.testing.expect(!session.drop_pending);
}

test "an attach past the gateway's session limit is refused alone, and a removal makes room" {
    // The harness's own session fills a limit of one.
    var harness = try Harness.init(.{ .sessions_max = 1 });
    defer harness.deinit();

    var fds = try gateway_support.createSession();
    defer fds.deinit();
    try harness.sendAttach(1, fds.rawForGateway());
    try std.testing.expectEqual(@as(u64, 0), try harness.expectAttachAck(1, .rejected));
    try harness.expectNoServerPacket();
    try std.testing.expectEqual(@as(usize, 1), harness.gateway.sessions.len());
    try std.testing.expect(harness.gateway.sessions.byId(harness.session_id) != null);

    const index = harness.gateway.sessions.indexOf(harness.session_id) orelse return error.MissingSession;
    try runtime.session_flow.removeSession(harness.gateway, index, .liveness_closed);
    try harness.expectSessionRemovedReport(harness.session_id, .liveness_closed);
    try harness.sendAttach(2, fds.rawForGateway());
    const attached = try harness.expectAttachAck(2, .ok);
    try std.testing.expect(attached != 0);
    // Session ids never come back within one gateway, so no later session takes an earlier one's
    // tokens.
    try std.testing.expect(attached > harness.session_id);
    try std.testing.expectEqual(@as(usize, 1), harness.gateway.sessions.len());
}

test "boot_ended ends the boot token of the session it names and of no other" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    var peer = try harness.attachPeer();
    defer peer.deinit();

    try harness.sendBootEnded(harness.session_id);
    try std.testing.expect(harness.session().boot_ended);
    const peer_session = harness.gateway.sessions.byId(peer.session_id) orelse return error.MissingSession;
    try std.testing.expect(!peer_session.boot_ended);

    try harness.expectRefused(
        .{ .fetch_id = 1, .body_id = 1, .token = harness.bootToken(gateway_support.live_deadline_ns), .pooled_body_len = 8 },
        "egress boot token ended",
    );
    // The peer's boot token still admits on the peer's ring.
    const start = try harness.encodeFetchStart(.{
        .fetch_id = 1,
        .body_id = 1,
        .token = harness.token(.{
            .kind = .boot,
            .session_id = peer.session_id,
            .request_id = 0,
            .request_generation = 0,
        }),
        .pooled_body_len = 8,
    });
    try std.testing.expect(runtime.command_flow.handlePacket(harness.gateway, peer_session, start));
    try std.testing.expect(harness.gateway.fetches.find(peer.session_id, 1) != null);
}

test "boot_ended for a session the gateway does not hold is skipped, and sent twice changes nothing more" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const boot = harness.bootToken(gateway_support.live_deadline_ns);

    // A session the gateway never attached, or one it removed: the server's end can trail.
    try harness.sendBootEnded(harness.session_id + 100);
    try std.testing.expect(!harness.session().boot_ended);
    try harness.expectAdmitted(.{ .fetch_id = 1, .body_id = 1, .token = boot, .pooled_body_len = 8 });

    try harness.sendBootEnded(harness.session_id);
    try harness.expectFetchError(1, 1, "egress boot token ended");
    try harness.sendBootEnded(harness.session_id);
    try harness.expectNoMoreCompletionPackets();
    try std.testing.expect(harness.session().boot_ended);
    try harness.expectRefused(
        .{ .fetch_id = 2, .body_id = 2, .token = boot, .pooled_body_len = 8 },
        "egress boot token ended",
    );
    // Nothing else changed: a request token admits, and the gateway answered the server nothing.
    try harness.expectAdmitted(.{ .fetch_id = 3, .body_id = 3, .token = harness.token(.{}), .pooled_body_len = 8 });
    try harness.expectNoServerPacket();
}

// The boot token's end used to stop admission only, so a worker compromised after its startup
// kept every fetch its boot token had started until the token's deadline.
test "boot_ended fails the boot token's assembling uploads at once and its running fetches once the engine let go, and leaves request fetches alone" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const boot = harness.bootToken(gateway_support.live_deadline_ns);
    try harness.expectAdmitted(.{ .fetch_id = 1, .body_id = 1, .token = boot, .pooled_body_len = 8 });
    try harness.expectAdmitted(.{ .fetch_id = 2, .body_id = 2, .token = harness.token(.{}), .pooled_body_len = 8 });
    // A boot fetch past its head, as the engine runs it.
    const running = try harness.startRunningFetch(3, 3, 0);
    harness.record(3).?.boot = true;
    try harness.settleSuccess(running, 200);
    try runtime.body_pump.pump(harness.gateway, running.handle);
    _ = try harness.expectHead(3);
    const upload_bytes_before = harness.session().upload_bytes_in_flight;

    try harness.sendBootEnded(harness.session_id);
    try harness.expectFetchError(1, 1, "egress boot token ended");
    try harness.expectNoMoreCompletionPackets();
    try std.testing.expect(harness.record(1) == null);
    try std.testing.expect(harness.session().upload_bytes_in_flight < upload_bytes_before);
    // The running one was canceled in the engine and waits for it to let go.
    try std.testing.expect(running.queue.canceled);
    try std.testing.expect(harness.record(3) != null);
    _ = running.queue.fail(harness.gateway.shards.get(0).engine.allocator, "FetchAborted");
    runtime.fetch_flow.retireIfSettled(harness.gateway, running.handle);
    try harness.expectFetchError(3, 3, "egress boot token ended");
    try harness.expectNoMoreCompletionPackets();

    // The request token's upload is untouched.
    try std.testing.expect(harness.record(2) != null);
    try std.testing.expectEqual(@as(u32, 1), harness.session().fetches.len);
}

test "a session the gateway removes on its own reaches the server as a report with its cause, and one whose attach ack never left does not" {
    const Reported = struct {
        reason: runtime.session_flow.RemovalReason,
        cause: gateway.control.SessionRemovedCause,
    };
    const reported = [_]Reported{
        .{ .reason = .liveness_closed, .cause = .liveness_closed },
        .{ .reason = .command_ring_failed, .cause = .protocol_violation },
        .{ .reason = .dropped, .cause = .protocol_violation },
    };
    for (reported) |case| {
        var harness = try Harness.init(.{});
        defer harness.deinit();
        try runtime.session_flow.removeSession(harness.gateway, 0, case.reason);
        try std.testing.expectEqual(@as(usize, 0), harness.gateway.sessions.len());
        try harness.expectSessionRemovedReport(harness.session_id, case.cause);
        try harness.expectNoServerPacket();
    }

    var harness = try Harness.init(.{});
    defer harness.deinit();
    try runtime.session_flow.removeSession(harness.gateway, 0, .attach_ack_failed);
    try std.testing.expectEqual(@as(usize, 0), harness.gateway.sessions.len());
    try harness.expectNoServerPacket();
}

test "a removal report the full socket holds back waits behind the packets before it and leaves once there is room" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const filler = try harness.fillControlSocket();

    try runtime.session_flow.removeSession(harness.gateway, 0, .liveness_closed);
    try std.testing.expectEqual(@as(usize, 1), harness.gateway.pending_control_packets.len());
    // The loop then polls the socket for room.
    try std.testing.expect((runtime.control_flow.controlEvents(harness.gateway) & std.posix.POLL.OUT) != 0);

    try harness.drainFiller(filler);
    try runtime.control_flow.flushPendingControlPackets(harness.gateway);
    try std.testing.expect(harness.gateway.pending_control_packets.isEmpty());
    try std.testing.expectEqual(@as(i16, std.posix.POLL.IN), runtime.control_flow.controlEvents(harness.gateway));
    try harness.expectSessionRemovedReport(harness.session_id, .liveness_closed);
    try harness.expectNoServerPacket();
}

test "a removal report to a server that closed its end is dropped, and the gateway goes on to the hang-up" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    harness.closeServerEnd();

    try runtime.session_flow.removeSession(harness.gateway, 0, .liveness_closed);
    try std.testing.expectEqual(@as(usize, 0), harness.gateway.sessions.len());
    try std.testing.expect(harness.gateway.pending_control_packets.isEmpty());
    // The loop sees the server gone on its control socket, where it ends.
    try std.testing.expect(try runtime.control_flow.drainControl(harness.gateway));
}

test "a removal report that can be neither sent nor queued ends the gateway" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const filler = try harness.fillControlSocket();
    // Reports of sessions the gateway never had fill the queue the full socket holds them in; the
    // bound keeps a broken queue from looping forever.
    var queued: usize = 0;
    while (true) : (queued += 1) {
        try std.testing.expect(queued <= gateway.sizing.sessions_max + 1);
        runtime.control_flow.reportSessionRemoved(harness.gateway, harness.session_id + 1 + queued, .protocol_violation) catch |err| {
            try std.testing.expectEqual(error.EgressGatewayControlBackpressure, err);
            break;
        };
    }

    try std.testing.expectError(
        error.EgressGatewayControlBackpressure,
        runtime.session_flow.removeSession(harness.gateway, 0, .dropped),
    );
    // The session is gone all the same; the gateway's end makes the server replace it.
    try std.testing.expectEqual(@as(usize, 0), harness.gateway.sessions.len());
    try harness.drainFiller(filler);
}

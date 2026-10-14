//! A worker session's commands in the gateway (`runtime/command_flow.zig`), the process that
//! holds the network capability and reads what a possibly compromised worker sends, over the real
//! gateway in `support/gateway.zig`.
//!
//! A packet that does not decode removes the session. A fetch start is admitted only under an
//! egress token that verifies under the key of the gateway's hello, names the presenting session,
//! has not expired, is no boot token after the session's `boot_ended`, names a policy of the
//! hello's image, fits the session's and the cell's active-fetch caps, uses a fetch id the session
//! does not hold, has a shape within the limits and, for a pooled body, fits the session's upload
//! bytes in flight with the copies of its start, checked in that order; a token keeps admitting
//! past what one request may start, the worker's share to hold. Each refusal queues an error
//! packet naming it and fails only that fetch: the session stays and is not marked for drop,
//! however many refusals it earns.
//! A policy that grants nothing, policy 0 included, is admitted, and the transport fails its fetch.
//! The request, the deadline and the pool key a fetch runs under come from the verified token. A
//! stop names a fetch by id; one the session no longer holds is ignored. The upload assembly is
//! covered in `upload_flow.zig`, how a fetch ends and its counts in `fetch_flow.zig`, the hello and
//! `boot_ended` packets in `control_flow.zig`, the shape rules in `policy.zig` and the token in
//! `common/tests/ipc/egress_token.zig`. Lane: egress-gateway-test.

const std = @import("std");
const gateway = @import("collo_egress_gateway");
const ipc = @import("collo_ipc");
const network = @import("collo_egress_client").network;

const gateway_support = @import("support/gateway.zig");
const policy_image = @import("support/policy_image.zig");

const policy = gateway.policy;
const runtime = gateway.runtime;
const egress_token = ipc.egress_token;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Harness = gateway_support.Harness;

const request_id = gateway_support.request_id;
const request_generation = gateway_support.request_generation;
const security_cell_id = gateway_support.security_cell_id;

/// Collection passes `collectUntilEnded` runs before it fails. Each pass follows a wake, and every
/// settled fetch wakes its engine at least once.
const collection_rounds_max: usize = 64;
/// How long one wait for an engine thread's wake lasts before the test fails.
const wake_timeout_ms: i32 = 5_000;

/// Delivers `bytes` as the session's next command, which must break the protocol: the session
/// goes, the server hears of it, and the worker gets no packet.
fn expectRemovedFor(harness: *Harness, bytes: []const u8) !void {
    const session_id = harness.session_id;
    try std.testing.expect(!try harness.deliverCommand(bytes));
    try harness.expectSessionRemovedReport(session_id, .protocol_violation);
    try harness.expectNoMoreCompletionPackets();
    try std.testing.expectEqual(@as(usize, 0), harness.gateway.sessions.len());
}

test "dispatch: a packet shorter than a message kind removes the session" {
    var harness = try Harness.init(.{});
    defer harness.deinit();

    // A packet shorter than the `u32` message kind is a corrupt frame, not a command.
    try expectRemovedFor(&harness, &[_]u8{0x01});
}

test "dispatch: an unknown message kind removes the session" {
    var harness = try Harness.init(.{});
    defer harness.deinit();

    var bytes: [8]u8 = @splat(0);
    std.mem.writeInt(u32, bytes[0..4], 0xdead_beef, .little);
    try expectRemovedFor(&harness, &bytes);
}

test "dispatch: a truncated fetch start removes the session" {
    var harness = try Harness.init(.{});
    defer harness.deinit();

    // The kind is right but the packet is too short for a fetch start, so the decoder refuses it:
    // a framing fault, not a refusal.
    var bytes: [8]u8 = @splat(0);
    std.mem.writeInt(u32, bytes[0..4], @intFromEnum(ipc.MessageKind.egress_fetch_start), .little);
    try expectRemovedFor(&harness, &bytes);
}

test "dispatch: a fetch start that carries no token does not decode and removes the session" {
    var harness = try Harness.init(.{});
    defer harness.deinit();

    // An honest worker refuses a fetch without a token before it leaves, and the encoder refuses
    // to write one, so this start is a well-formed one with its token cleared afterwards.
    const packet = try harness.encodeFetchStart(.{ .fetch_id = 1, .body_id = 1, .token = harness.token(.{}) });
    const token_offset = @offsetOf(ipc.EgressFetchStartHeader, "egress_token");
    packet[token_offset..][0..egress_token.token_bytes].* = egress_token.none;

    try expectRemovedFor(&harness, packet);
    try std.testing.expectEqual(@as(usize, 0), harness.gateway.fetches.count());
}

test "admission: a fetch under a valid token reaches its engine with the token's request" {
    var harness = try Harness.init(.{ .start_shards = true });
    defer harness.deinit();

    try harness.expectAdmitted(.{ .fetch_id = 9, .body_id = 10, .token = harness.token(.{}) });

    // The fetch start names no request, so the verified token is the only place the response
    // body's identity can take it from.
    const record = harness.record(9) orelse return error.MissingRecord;
    try std.testing.expect(record.stage == .running);
    const identity = record.stage.running.task.response_body.identity;
    try std.testing.expectEqual(request_id, identity.request_id);
    try std.testing.expectEqual(request_generation, identity.request_generation);
    try std.testing.expectEqual(@as(u64, 9), identity.fetch_id);
    try std.testing.expectEqual(@as(u64, 10), identity.body_id);
    try std.testing.expectEqual(@as(u32, 1), harness.session().fetches.len);
    try std.testing.expectEqual(@as(u32, 1), harness.gateway.fetches.cellCount(security_cell_id));
}

test "admission: a pooled fetch holds the grant its token decided: request, deadline, policy and pool key" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const deadline = gateway_support.live_deadline_ns - 7;

    try harness.expectAdmitted(.{
        .fetch_id = 3,
        .body_id = 4,
        .token = harness.token(.{
            .policy_id = policy_image.public_http_and_https_id,
            .request_id = 41,
            .request_generation = 5,
            .deadline_monotonic_ns = deadline,
        }),
        .pooled_body_len = 16,
    });

    const record = harness.record(3) orelse return error.MissingRecord;
    try std.testing.expect(record.stage == .assembling);
    const grant = record.stage.assembling.grant;
    try std.testing.expectEqual(@as(u64, 41), grant.request_id);
    try std.testing.expectEqual(@as(u64, 5), grant.request_generation);
    try std.testing.expectEqual(deadline, grant.deadline_mono_ns);
    try std.testing.expectEqualSlices(u8, &security_cell_id, &grant.isolation.security_cell_id);
    try std.testing.expectEqualSlices(
        u8,
        &policy.poolPolicyId(policy_image.public_http_and_https_id),
        &grant.isolation.policy_id,
    );
    // A start names no response cap, so every fetch runs under the gateway's.
    try std.testing.expectEqual(harness.gateway.policy.max_response_body_bytes, grant.max_response_body_bytes);
    // The network policy is the hello's entry for the token's id.
    const expected_policy = harness.gateway.hello.lookup(policy_image.public_http_and_https_id) orelse
        return error.MissingPolicy;
    try std.testing.expectEqual(expected_policy.grants.len, grant.network.grants.len);
    try std.testing.expectEqual(expected_policy.grants[0], grant.network.grants[0]);
}

test "admission: a fetch its engine cannot take fails with the engine's error and leaves nothing behind" {
    // The shards never started, so the engine refuses the submission after admission reserved the
    // fetch's record, and ending that record is the one undo.
    var harness = try Harness.init(.{});
    defer harness.deinit();

    try harness.expectRefused(
        .{ .fetch_id = 1, .body_id = 2, .token = harness.token(.{}) },
        "EgressEngineUnavailable",
    );
    try std.testing.expect(harness.record(1) == null);
    try std.testing.expectEqual(@as(u32, 0), harness.gateway.fetches.cellCount(security_cell_id));
}

test "admission: an allocation failure for the fetch's record fails the fetch alone" {
    var harness = try Harness.init(.{});
    defer harness.deinit();

    // Reserving the record is admission's first allocation.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    harness.gateway.allocator = failing.allocator();
    try harness.expectRefused(
        .{ .fetch_id = 1, .body_id = 1, .token = harness.token(.{}), .pooled_body_len = 8 },
        "OutOfMemory",
    );
    harness.gateway.allocator = std.testing.allocator;

    try std.testing.expect(harness.record(1) == null);
    try std.testing.expectEqual(@as(u64, 0), harness.session().upload_bytes_in_flight);
    try harness.expectAdmitted(.{ .fetch_id = 2, .body_id = 2, .token = harness.token(.{}), .pooled_body_len = 8 });
}

test "admission: a token changed after it was minted fails as an invalid token and the session stays" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const minted = harness.token(.{});

    // Another policy, session or request, a later deadline and a changed tag byte: a worker
    // cannot rewrite a field the tag covers, nor the tag itself.
    const offsets = [_]usize{
        @offsetOf(egress_token.Token, "policy_id"),
        @offsetOf(egress_token.Token, "session_id"),
        @offsetOf(egress_token.Token, "request_id"),
        @offsetOf(egress_token.Token, "deadline_monotonic_ns") + 7,
        egress_token.body_bytes + 3,
    };
    for (offsets, 1..) |offset, fetch_id| {
        var tampered = minted;
        tampered[offset] +%= 1;
        try harness.expectRefused(
            .{ .fetch_id = fetch_id, .body_id = fetch_id, .token = tampered },
            "invalid egress token",
        );
    }
}

test "admission: a token minted under an earlier gateway's key fails as an invalid token" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const stale = harness.token(.{ .key = &gateway_support.earlier_key });
    try harness.expectRefused(
        .{ .fetch_id = 1, .body_id = 1, .token = stale },
        "invalid egress token",
    );
}

test "admission: a tagged token of a kind the gateway does not know fails as an invalid token" {
    var harness = try Harness.init(.{});
    defer harness.deinit();

    // Only a holder of the key can tag a token, so this stands for a server that mints a kind
    // this gateway does not know.
    var other_kind = harness.token(.{});
    other_kind[@offsetOf(egress_token.Token, "kind")] = egress_token.kind_boot + 1;
    retag(&other_kind, &gateway_support.hello_key);
    try harness.expectRefused(
        .{ .fetch_id = 1, .body_id = 1, .token = other_kind },
        "invalid egress token",
    );
}

test "admission: a gateway that has not received its hello admits no token" {
    var harness = try Harness.init(.{ .hello = false });
    defer harness.deinit();
    try std.testing.expect(harness.gateway.hello.key.isZero());

    // A token the server minted under the key it has not sent yet verifies under no key the
    // gateway holds.
    try harness.expectRefused(
        .{ .fetch_id = 1, .body_id = 1, .token = harness.token(.{}) },
        "invalid egress token",
    );
}

test "admission: another session's token fails" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    var peer = try harness.attachPeer();
    defer peer.deinit();

    // A live token of another session of the gateway, presented from this session's ring.
    const foreign = harness.token(.{ .session_id = peer.session_id });
    try harness.expectRefused(
        .{ .fetch_id = 1, .body_id = 1, .token = foreign },
        "egress token of another session",
    );
}

test "admission: a request token past its deadline fails" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const expired = harness.token(.{ .deadline_monotonic_ns = gateway_support.passed_deadline_ns });
    try harness.expectRefused(
        .{ .fetch_id = 1, .body_id = 1, .token = expired, .pooled_body_len = 8 },
        "egress token expired",
    );
}

test "admission: a boot token past its window fails" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    try harness.expectRefused(
        .{ .fetch_id = 1, .body_id = 1, .token = harness.bootToken(gateway_support.passed_deadline_ns), .pooled_body_len = 8 },
        "egress token expired",
    );
}

test "admission: a boot token after its boot_ended fails, the upload it started ends, and the session's request tokens still admit" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const boot = harness.bootToken(gateway_support.live_deadline_ns);

    // Within its window the boot token admits fetches, until the server ends it.
    try harness.expectAdmitted(.{ .fetch_id = 1, .body_id = 1, .token = boot, .pooled_body_len = 8 });
    try harness.sendBootEnded(harness.session_id);
    try std.testing.expect(harness.session().boot_ended);
    // The end fails the upload the boot token started, with its terminal packet.
    try harness.expectFetchError(1, 1, "egress boot token ended");
    try std.testing.expect(harness.record(1) == null);
    try harness.expectRefused(
        .{ .fetch_id = 2, .body_id = 2, .token = boot, .pooled_body_len = 8 },
        "egress boot token ended",
    );

    // A request token still admits.
    try harness.expectAdmitted(.{ .fetch_id = 3, .body_id = 3, .token = harness.token(.{}), .pooled_body_len = 8 });
}

test "admission: a token naming a policy the hello did not carry fails" {
    // Only the server mints policy ids, so the gateway reports the id as a server bug.
    @import("root").expect_log_errors = 1;
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const unknown_policy = harness.token(.{ .policy_id = policy_image.standard_policy_count });
    try harness.expectRefused(
        .{ .fetch_id = 1, .body_id = 1, .token = unknown_policy },
        "egress policy unknown",
    );
}

test "admission: a fetch under policy 0 is admitted and fails in the transport with the denial" {
    var harness = try Harness.init(.{ .start_shards = true });
    defer harness.deinit();
    const token = harness.token(.{ .policy_id = network.table.deny_all_id });

    try harness.expectAdmitted(.{ .fetch_id = 1, .body_id = 2, .token = token });

    // The transport refuses the policy that grants nothing before DNS, and the denial reaches the
    // worker as the fetch's error.
    try collectUntilEnded(&harness, 1);
    var host_buffer: [gateway_support.loopback_host_bytes_max]u8 = undefined;
    var text_buffer: [network.grant.denial_bytes_max]u8 = undefined;
    var text: std.Io.Writer = .fixed(&text_buffer);
    try network.writeDenial(&text, .{
        .scheme = .https,
        .host = gateway_support.loopbackHost(&host_buffer, 1),
        .port = gateway_support.loopback_port,
    }, .no_grant);
    try harness.expectFetchErrorWithCause(1, 2, text.buffered(), .network_denied);
    try harness.expectNoMoreCompletionPackets();
    try std.testing.expectEqual(@as(u32, 0), harness.session().fetches.len);
    try std.testing.expect(!harness.session().drop_pending);
}

test "admission: two tokens of one session whose policies differ give their fetches pool keys that differ" {
    var harness = try Harness.init(.{});
    defer harness.deinit();

    const policy_ids = [_]network.PolicyId{ policy_image.public_https_id, policy_image.public_http_and_https_id };
    for (policy_ids, 1..) |policy_id, fetch_id| {
        try harness.expectAdmitted(.{
            .fetch_id = fetch_id,
            .body_id = fetch_id,
            .token = harness.token(.{ .policy_id = policy_id, .request_id = 20 + fetch_id }),
            .pooled_body_len = 8,
        });
    }
    // A pool key is the session's security cell and its policy's pool id.
    const first = (harness.record(1) orelse return error.MissingRecord).stage.assembling.grant.isolation;
    const second = (harness.record(2) orelse return error.MissingRecord).stage.assembling.grant.isolation;
    try std.testing.expectEqualSlices(u8, &first.security_cell_id, &second.security_cell_id);
    try std.testing.expect(!std.mem.eql(u8, &first.policy_id, &second.policy_id));
    try std.testing.expectEqualSlices(u8, &policy.poolPolicyId(policy_ids[0]), &first.policy_id);
    try std.testing.expectEqualSlices(u8, &policy.poolPolicyId(policy_ids[1]), &second.policy_id);
}

test "admission: the tag is checked before the session and the session before the deadline" {
    var harness = try Harness.init(.{});
    defer harness.deinit();

    // Another session's token that has also expired fails for the session.
    const foreign_expired = harness.token(.{
        .session_id = harness.session_id + 1,
        .deadline_monotonic_ns = gateway_support.passed_deadline_ns,
    });
    try harness.expectRefused(
        .{ .fetch_id = 1, .body_id = 1, .token = foreign_expired },
        "egress token of another session",
    );

    // A changed token of another session that has also expired fails for the tag.
    var tampered = foreign_expired;
    tampered[@offsetOf(egress_token.Token, "deadline_monotonic_ns")] +%= 1;
    try harness.expectRefused(
        .{ .fetch_id = 2, .body_id = 2, .token = tampered },
        "invalid egress token",
    );
}

test "admission: the deadline, the boot end and the policy are checked before the caps" {
    @import("root").expect_log_errors = 1;
    var harness = try Harness.init(.{ .policy = .{ .max_active_fetches_per_worker_session = 0 } });
    defer harness.deinit();
    try harness.sendBootEnded(harness.session_id);

    try harness.expectRefused(
        .{ .fetch_id = 1, .body_id = 1, .token = harness.token(.{ .deadline_monotonic_ns = gateway_support.passed_deadline_ns }) },
        "egress token expired",
    );
    try harness.expectRefused(
        .{ .fetch_id = 2, .body_id = 2, .token = harness.bootToken(gateway_support.live_deadline_ns) },
        "egress boot token ended",
    );
    try harness.expectRefused(
        .{ .fetch_id = 3, .body_id = 3, .token = harness.token(.{ .policy_id = policy_image.standard_policy_count }) },
        "egress policy unknown",
    );
    try harness.expectRefused(
        .{ .fetch_id = 4, .body_id = 4, .token = harness.token(.{}) },
        "egress worker fetch limit exceeded",
    );
}

test "admission: the session's active-fetch cap refuses the start past it, and a fetch's terminal packet makes room" {
    var harness = try Harness.init(.{ .policy = .{ .max_active_fetches_per_worker_session = 2 } });
    defer harness.deinit();

    try harness.expectAdmitted(.{ .fetch_id = 1, .body_id = 1, .token = harness.token(.{}), .pooled_body_len = 8 });
    try harness.expectAdmitted(.{ .fetch_id = 2, .body_id = 2, .token = harness.token(.{}), .pooled_body_len = 8 });
    try harness.expectRefused(
        .{ .fetch_id = 3, .body_id = 3, .token = harness.token(.{}), .pooled_body_len = 8 },
        "egress worker fetch limit exceeded",
    );

    // The stop ends fetch 1 with its abort ack, the packet that settles the worker's own count.
    try std.testing.expect(harness.sendStop(1));
    try harness.expectAbortAck(1, 1);
    try std.testing.expectEqual(@as(u32, 1), harness.session().fetches.len);
    try harness.expectAdmitted(.{ .fetch_id = 4, .body_id = 4, .token = harness.token(.{}), .pooled_body_len = 8 });
}

// The gateway used to keep a budget of 16 fetches per token. The worker now holds each request to
// its share itself, and the gateway admits by the session's and the cell's caps alone, so a token
// presented again keeps admitting until its deadline.
test "admission: one token admits fetches past the old per-token budget, a request token and the boot token alike" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const old_token_budget: u64 = 16;
    const request_token = harness.token(.{});
    const boot_token = harness.bootToken(gateway_support.live_deadline_ns);

    var fetch_id: u64 = 1;
    while (fetch_id <= old_token_budget + 1) : (fetch_id += 1)
        try harness.expectAdmitted(.{ .fetch_id = fetch_id, .body_id = fetch_id, .token = request_token, .pooled_body_len = 8 });
    while (fetch_id <= 2 * (old_token_budget + 1)) : (fetch_id += 1)
        try harness.expectAdmitted(.{ .fetch_id = fetch_id, .body_id = fetch_id, .token = boot_token, .pooled_body_len = 8 });
    try std.testing.expectEqual(@as(u32, @intCast(2 * (old_token_budget + 1))), harness.session().fetches.len);
}

test "admission: the security cell's active-fetch cap counts every session of the cell" {
    var harness = try Harness.init(.{ .policy = .{ .max_active_fetches_per_security_cell = 1 } });
    defer harness.deinit();
    var same_cell = try harness.attachPeer();
    defer same_cell.deinit();
    const other_cell_id: policy.SecurityCellId = @splat(9);
    var other_cell = try harness.attachPeerInCell(other_cell_id);
    defer other_cell.deinit();

    try harness.expectAdmitted(.{ .fetch_id = 1, .body_id = 1, .token = harness.token(.{}), .pooled_body_len = 8 });

    // The peer of the same cell holds no fetch of its own, but the cell is full.
    try std.testing.expect(try sendPeerFetchStart(&harness, &same_cell, .{
        .fetch_id = 1,
        .body_id = 1,
        .token = harness.token(.{ .session_id = same_cell.session_id }),
        .pooled_body_len = 8,
    }));
    try expectPeerFetchError(&same_cell, 1, 1, "egress security cell fetch limit exceeded");
    try std.testing.expect(harness.gateway.fetches.find(same_cell.session_id, 1) == null);

    // A session of another cell is not counted against it.
    try std.testing.expect(try sendPeerFetchStart(&harness, &other_cell, .{
        .fetch_id = 1,
        .body_id = 1,
        .token = harness.token(.{ .session_id = other_cell.session_id }),
        .pooled_body_len = 8,
    }));
    try std.testing.expect(harness.gateway.fetches.find(other_cell.session_id, 1) != null);
    try std.testing.expectEqual(@as(u32, 1), harness.gateway.fetches.cellCount(security_cell_id));
    try std.testing.expectEqual(@as(u32, 1), harness.gateway.fetches.cellCount(other_cell_id));
}

test "admission: a fetch id the session already holds is refused, and body ids name nothing" {
    var harness = try Harness.init(.{});
    defer harness.deinit();

    try harness.expectAdmitted(.{ .fetch_id = 7, .body_id = 8, .token = harness.token(.{}), .pooled_body_len = 8 });
    // A worker cannot reuse the id of a live fetch, whatever body id it pairs it with.
    try harness.expectRefused(
        .{ .fetch_id = 7, .body_id = 8, .token = harness.token(.{}), .pooled_body_len = 8 },
        "duplicate egress fetch identity",
    );
    try harness.expectRefused(
        .{ .fetch_id = 7, .body_id = 99, .token = harness.token(.{}), .pooled_body_len = 8 },
        "duplicate egress fetch identity",
    );
    // A body id is the worker's own label, echoed in packets, so another fetch may carry it.
    try harness.expectAdmitted(.{ .fetch_id = 9, .body_id = 8, .token = harness.token(.{}), .pooled_body_len = 8 });

    // The same fetch id in another session is another fetch.
    var peer = try harness.attachPeer();
    defer peer.deinit();
    try std.testing.expect(try sendPeerFetchStart(&harness, &peer, .{
        .fetch_id = 7,
        .body_id = 8,
        .token = harness.token(.{ .session_id = peer.session_id }),
        .pooled_body_len = 8,
    }));
    try std.testing.expect(harness.gateway.fetches.find(peer.session_id, 7) != null);
}

test "admission: a start whose shape breaks the limits is refused before any buffer exists" {
    var harness = try Harness.init(.{ .policy = .{ .max_request_body_bytes = 1024, .max_request_headers = 1 } });
    defer harness.deinit();

    // One byte past the announced-length limit.
    try harness.expectRefused(
        .{ .fetch_id = 1, .body_id = 1, .token = harness.token(.{}), .pooled_body_len = 1025 },
        "EgressGatewayRequestBodyLimitExceeded",
    );
    // A zero fetch id names no fetch the worker could stop.
    try harness.expectRefused(
        .{ .fetch_id = 0, .body_id = 5, .token = harness.token(.{}), .pooled_body_len = 32 },
        "InvalidEgressGatewayFetchIdentity",
    );
    // More headers than the policy allows.
    const headers = [_]ipc.RequestHeader{
        .{ .name = "a", .value = "1" },
        .{ .name = "b", .value = "2" },
    };
    try std.testing.expect(harness.sendCommand(try encodeStartWithHeaders(&harness, 2, harness.token(.{}), &headers)));
    try harness.expectFetchError(2, 2, "TooManyFetchHeaders");

    try harness.expectNoMoreCompletionPackets();
    try std.testing.expectEqual(@as(u32, 0), harness.session().fetches.len);
    try std.testing.expectEqual(@as(u64, 0), harness.gateway.upload_memory.liveBytes());

    // At the limit the start is admitted.
    try harness.expectAdmitted(.{ .fetch_id = 3, .body_id = 3, .token = harness.token(.{}), .pooled_body_len = 1024 });
}

// A pooled start's copies of its method, URL and headers used to sit on the gateway's heap
// outside every budget, so a session held up to about 88 KiB per pooled fetch beyond its upload
// bytes.
test "admission: pooled starts past the session's upload bytes in flight, the copies of their starts included, are refused, and an ended upload returns its bytes" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const largest: u64 = ipc.fetch_limits.request_body_pooled_bytes_max;
    const in_flight_max: u64 = ipc.fetch_limits.request_body_pooled_in_flight_bytes_max;

    // The largest body fits a session alone, and its start's copies count with it.
    try harness.expectAdmitted(.{ .fetch_id = 1, .body_id = 1, .token = harness.token(.{}), .pooled_body_len = largest });
    const first = gateway_support.pooledStartBytes(1, largest);
    try std.testing.expect(first > largest);
    try std.testing.expectEqual(first, harness.session().upload_bytes_in_flight);

    // A body that would fit the rest only without its start's copies is refused; one byte less
    // is admitted and fills the session.
    const rest_body = in_flight_max - first - gateway_support.pooledStartBytes(2, 0);
    try harness.expectRefused(
        .{ .fetch_id = 2, .body_id = 2, .token = harness.token(.{}), .pooled_body_len = rest_body + 1 },
        "egress upload bytes in flight exceeded",
    );
    try harness.expectAdmitted(.{ .fetch_id = 3, .body_id = 3, .token = harness.token(.{}), .pooled_body_len = rest_body });
    try std.testing.expectEqual(in_flight_max, harness.session().upload_bytes_in_flight);
    try harness.expectRefused(
        .{ .fetch_id = 4, .body_id = 4, .token = harness.token(.{}), .pooled_body_len = 1 },
        "egress upload bytes in flight exceeded",
    );

    // A stop ends the first upload with its abort ack, which returns its bytes, copies included.
    try std.testing.expect(harness.sendStop(1));
    try harness.expectAbortAck(1, 1);
    try std.testing.expectEqual(in_flight_max - first, harness.session().upload_bytes_in_flight);
    try harness.expectAdmitted(.{ .fetch_id = 5, .body_id = 5, .token = harness.token(.{}), .pooled_body_len = 1 });
}

test "admission: refused starts never remove the session, however many it sends" {
    var harness = try Harness.init(.{});
    defer harness.deinit();

    // A worker that keeps the tokens of an earlier gateway, or forges them, earns one error packet
    // per start and nothing else; a refused command costs the gateway what an accepted one does.
    const refused_starts: usize = 2048;
    for (0..refused_starts) |index| {
        const stale = harness.token(.{
            .key = &gateway_support.earlier_key,
            .request_id = 100 + index,
        });
        try harness.expectRefused(
            .{ .fetch_id = index + 1, .body_id = index + 1, .token = stale },
            "invalid egress token",
        );
    }

    // The session survived them, and a start under the new key is admitted.
    try harness.expectAdmitted(.{
        .fetch_id = refused_starts + 1,
        .body_id = refused_starts + 1,
        .token = harness.token(.{}),
        .pooled_body_len = 8,
    });
}

test "dispatch: handleCommands drains every queued command and queues an error per refused start" {
    var harness = try Harness.init(.{});
    defer harness.deinit();

    // Three starts under a forged token wait on the command ring together.
    const forged = harness.token(.{ .key = &gateway_support.earlier_key });
    const ids = [_]u64{ 100, 200, 300 };
    for (ids) |id|
        try harness.writeCommand(try harness.encodeFetchStart(.{ .fetch_id = id, .body_id = id + 1, .token = forged }));

    // One drain pass handles all three, and the session stays.
    try std.testing.expect(harness.handleCommands());
    for (ids) |id|
        try harness.expectFetchError(id, id + 1, "invalid egress token");
    try harness.expectNoMoreCompletionPackets();
    try std.testing.expect(!harness.session().drop_pending);
}

test "dispatch: a stop ends the fetch it names with one abort ack, and a second stop of it is ignored" {
    var harness = try Harness.init(.{});
    defer harness.deinit();

    try harness.expectAdmitted(.{ .fetch_id = 5, .body_id = 6, .token = harness.token(.{}), .pooled_body_len = 8 });
    try std.testing.expect(harness.sendStop(5));
    try harness.expectAbortAck(5, 6);
    try std.testing.expect(harness.record(5) == null);

    // The worker cannot see when the gateway ended its fetch, so a stop that crosses the end is
    // no violation.
    try std.testing.expect(harness.sendStop(5));
    try harness.expectNoMoreCompletionPackets();
    try std.testing.expect(!harness.session().drop_pending);
}

test "dispatch: a stop for a fetch the session never had is ignored and keeps the session" {
    var harness = try Harness.init(.{});
    defer harness.deinit();

    const stop = ipc.EgressStop.init(4242);
    try harness.writeCommand(std.mem.asBytes(&stop));
    try std.testing.expect(harness.handleCommands());
    try harness.expectNoMoreCompletionPackets();
    try std.testing.expect(!harness.session().drop_pending);
}

test "dispatch: a stop that does not decode removes the session" {
    var harness = try Harness.init(.{});
    defer harness.deinit();

    // The kind of a stop in a packet of the wrong length.
    var bytes: [@sizeOf(ipc.EgressStop) + 8]u8 = @splat(0);
    std.mem.writeInt(u32, bytes[0..4], @intFromEnum(ipc.MessageKind.egress_stop), .little);
    try expectRemovedFor(&harness, &bytes);
}

/// Runs collection passes on the shard of fetch `fetch_id` as the gateway's loop does when the
/// shard's wake eventfd turns readable, until the fetch's record is gone, which the collection
/// pass that ends the fetch frees.
fn collectUntilEnded(harness: *Harness, fetch_id: u64) !void {
    const record = harness.record(fetch_id) orelse return error.MissingRecord;
    const shard_index = record.shard_index;
    const wake_fd = harness.gateway.shards.get(shard_index).engine.wake_fd;
    for (0..collection_rounds_max) |_| {
        if (harness.record(fetch_id) == null)
            return;
        var pollfds = [_]std.posix.pollfd{.{
            .fd = wake_fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        if (try std.posix.poll(&pollfds, wake_timeout_ms) == 0)
            return error.TestTimeout;
        try runtime.shard_flow.collectShardReady(harness.gateway, shard_index);
    }
    return error.TestTimeout;
}

/// Hands one fetch start to the gateway's dispatch as `peer`'s session sent it and returns
/// whether the session stays.
fn sendPeerFetchStart(harness: *Harness, peer: *gateway_support.Peer, options: gateway_support.FetchOptions) !bool {
    const packet = try harness.encodeFetchStart(options);
    const session = harness.gateway.sessions.byId(peer.session_id) orelse return error.MissingSession;
    return runtime.command_flow.handlePacket(harness.gateway, session, packet);
}

/// Takes the next packet on `peer`'s completion ring, which must fail fetch `fetch_id` with
/// `message`.
fn expectPeerFetchError(peer: *gateway_support.Peer, fetch_id: u64, body_id: u64, message: []const u8) !void {
    const buffer = try std.testing.allocator.alloc(u8, ipc.max_message_bytes);
    defer std.testing.allocator.free(buffer);
    const packet = (try peer.worker_endpoint.completion.readPacket(buffer)) orelse
        return error.MissingQueuedFetchError;
    const view = try ipc.decodeEgressFetchError(packet);
    try std.testing.expectEqual(fetch_id, view.fetch_id);
    try std.testing.expectEqual(body_id, view.body_id);
    try std.testing.expectEqualStrings(message, view.message);
}

/// A well-formed inline start of fetch `fetch_id` carrying `headers`.
fn encodeStartWithHeaders(
    harness: *Harness,
    fetch_id: u64,
    token: egress_token.Bytes,
    headers: []const ipc.RequestHeader,
) ![]u8 {
    return ipc.encodeEgressFetchStartInto(harness.encode_scratch, .{
        .fetch_id = fetch_id,
        .egress_token = token,
        .body_id = fetch_id,
        .method = "GET",
        .url = "https://127.0.0.1:9/",
        .headers = headers,
        .body = "",
    });
}

/// Tags `bytes` under `key` as `egress_token.mint` does, so a test can stand for a server that
/// mints a field this gateway does not accept.
fn retag(bytes: *egress_token.Bytes, key: *const egress_token.Key) void {
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, bytes[0..egress_token.body_bytes], &key.bytes);
    bytes[egress_token.body_bytes..].* = mac[0..egress_token.tag_bytes].*;
}

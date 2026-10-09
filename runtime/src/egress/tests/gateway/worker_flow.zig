//! Worker command dispatch (`runtime/worker_flow.zig`) and pooled upload assembly
//! (`runtime/upload_flow.zig`) in the gateway, the process that holds the network capability and
//! reads what a possibly compromised worker sends, over the loop stand-in in `support/loop.zig`.
//!
//! A packet that does not decode removes the worker. A fetch start is admitted only under an
//! egress token that verifies under the key of the gateway's hello, names the presenting
//! session, has not expired, names an entry of the hello's policy table, fits the session's and
//! the cell's active-fetch caps and has a fetch left in its budget, checked in that order. Each
//! refusal queues an error packet. A forged token, another session's token and a spent budget
//! count an invalid command; an expired token and an unknown policy id do not, since an honest
//! worker can race its deadline and only the server mints policy ids. A failure after admission
//! took the fetch gives it back to the budget, unless the worker caused it, which strikes. The
//! request id, generation and deadline the engine gets come from the verified token, since the
//! start names no request.
//! Invalid commands past the window's budget remove the worker, and an honest worker still
//! holding an earlier gateway's tokens stays below it. Cancels and body releases for unknown
//! fetches count as invalid, and upload assembly refuses bad lengths, duplicate identities, ledger
//! mismatches and bad handles, and keeps its buffers out of the shard's memory count whether the
//! upload reaches the engine or not. The budget rules are covered in `budgets.zig`, the hello and
//! `request_ended` in `control_flow.zig`, the token in `common/tests/ipc/egress_token.zig`, and
//! the router, invalid-command window and backpressure state these mixins update in `runtime.zig`.
//! Lane: egress-gateway-test.

const std = @import("std");
const gateway = @import("collo_egress_gateway");
const ipc = @import("collo_ipc");
const limits = @import("collo_limits");

const loop_support = @import("support/loop.zig");

const policy = gateway.policy;
const sessions = gateway.sessions;
const egress_token = ipc.egress_token;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Harness = loop_support.Harness;

const request_id = loop_support.request_id;
const request_generation = loop_support.request_generation;
const security_cell_id = loop_support.security_cell_id;

test "dispatch: a packet shorter than a message kind removes the worker" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const worker = harness.worker();

    // A packet shorter than the `u32` message kind is a corrupt frame, not a command:
    // `handleWorkerPacket` returns false, the run loop removes the worker, and no invalid
    // command is counted.
    try std.testing.expect(!harness.loop.handleWorkerPacket(worker, &[_]u8{0x01}));
    try std.testing.expectEqual(@as(u32, 0), worker.invalid_commands.count);
}

test "dispatch: an unknown message kind removes the worker" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const worker = harness.worker();

    var bytes: [8]u8 = @splat(0);
    std.mem.writeInt(u32, bytes[0..4], 0xdead_beef, .little);
    try std.testing.expect(!harness.loop.handleWorkerPacket(worker, &bytes));
    try std.testing.expectEqual(@as(u32, 0), worker.invalid_commands.count);
}

test "dispatch: a truncated fetch-start removes the worker" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const worker = harness.worker();

    // The kind is right but the packet is too short for a fetch start, so the decoder refuses
    // it and dispatch removes the worker: a framing fault, not an invalid command.
    var bytes: [8]u8 = @splat(0);
    std.mem.writeInt(u32, bytes[0..4], @intFromEnum(ipc.MessageKind.egress_fetch_start), .little);
    try std.testing.expect(!harness.loop.handleWorkerPacket(worker, &bytes));
    try std.testing.expectEqual(@as(u32, 0), worker.invalid_commands.count);
}

test "admission: a fetch under a valid token reaches the engine with the token's request, deadline and budget" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    try harness.startShards();
    const deadline = loop_support.live_deadline_ns - 7;
    const token = harness.token(.{ .budget = 4, .deadline_monotonic_ns = deadline });

    try harness.expectAdmitted(.{ .fetch_id = 9, .body_id = 10, .token = token });

    // Admission recorded the route under the token's policy entry and both counts once.
    const route = harness.loop.router.routeForBody(harness.session_id, 9, 10) orelse
        return error.MissingRoute;
    try std.testing.expectEqual(@as(usize, 0), route.record.shard_index);
    try std.testing.expectEqual(policy.public_https_id, route.record.policy_id);
    try std.testing.expectEqual(@as(usize, 1), harness.loop.activeFetchesForWorker(harness.session_id));
    try std.testing.expectEqual(@as(usize, 1), harness.loop.activeFetchesForSecurityCell(security_cell_id));

    // The token's budget started at this first fetch and lost one fetch to it.
    try std.testing.expectEqual(@as(?u32, 3), harness.budgetRemaining(request_id, request_generation));

    // The engine's record carries the token's request and deadline: the fetch start names no
    // request, so the verified token is the only place they can come from.
    const fetch = harness.activeFetch(9, 10) orelse return error.MissingActiveFetch;
    try std.testing.expectEqual(deadline, fetch.request_deadline_mono_ns);
    try std.testing.expectEqual(gateway.budgets.BudgetKey{
        .session_id = harness.session_id,
        .request_id = request_id,
        .request_generation = request_generation,
    }, fetch.budget_key);
    try std.testing.expectEqual(request_id, fetch.task.request_id);
}

test "admission: a token changed after it was minted fails as an invalid token and strikes" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const minted = harness.token(.{ .budget = 1 });

    // A raised budget, another session or request, a later deadline and a changed tag byte: a
    // worker cannot rewrite a field the tag covers, nor the tag itself.
    const offsets = [_]usize{
        @offsetOf(egress_token.Token, "budget"),
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
            .strike,
        );
    }
    try std.testing.expectEqual(@as(u32, offsets.len), harness.worker().invalid_commands.count);
}

test "admission: a token minted under an earlier gateway's key fails as an invalid token and strikes" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const stale = harness.token(.{ .key = &loop_support.earlier_key });
    try harness.expectRefused(
        .{ .fetch_id = 1, .body_id = 1, .token = stale },
        "invalid egress token",
        .strike,
    );
}

test "dispatch: a fetch start that carries no token does not decode and removes the worker" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const worker = harness.worker();

    // An honest worker refuses a fetch without a token before it leaves, and the encoder refuses
    // to write one, so this start is a well-formed one with its token cleared afterwards.
    const packet = try harness.encodeFetchStart(.{ .fetch_id = 1, .body_id = 1, .token = harness.token(.{}) });
    const token_offset = @offsetOf(ipc.EgressFetchStartHeader, "egress_token");
    packet[token_offset..][0..egress_token.token_bytes].* = egress_token.none;

    try std.testing.expect(!harness.loop.handleWorkerPacket(worker, packet));
    try std.testing.expectEqual(@as(u32, 0), worker.invalid_commands.count);
    try harness.expectNoMoreCompletionPackets();
}

test "admission: a tagged token of another version or kind fails as an invalid token and strikes" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const minted = harness.token(.{});

    // Only a holder of the key can tag a token, so these stand for a server that mints a
    // layout or kind this gateway does not know: the same refusal and the same strike.
    var other_version = minted;
    other_version[@offsetOf(egress_token.Token, "version")] = egress_token.version + 1;
    retag(&other_version, &loop_support.hello_key);
    try harness.expectRefused(
        .{ .fetch_id = 1, .body_id = 1, .token = other_version },
        "invalid egress token",
        .strike,
    );

    var other_kind = minted;
    other_kind[@offsetOf(egress_token.Token, "kind")] = egress_token.kind_boot + 1;
    retag(&other_kind, &loop_support.hello_key);
    try harness.expectRefused(
        .{ .fetch_id = 2, .body_id = 2, .token = other_kind },
        "invalid egress token",
        .strike,
    );
}

test "admission: a gateway that has not received its hello admits no token" {
    var harness = try Harness.init(.{ .hello_table = null });
    defer harness.deinit();
    try std.testing.expect(harness.helloKey().isZero());

    // A token the server minted under the key it has not sent yet verifies under no key the
    // gateway holds.
    try harness.expectRefused(
        .{ .fetch_id = 1, .body_id = 1, .token = harness.token(.{}) },
        "invalid egress token",
        .strike,
    );
}

test "admission: another session's token fails and strikes" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const foreign = harness.token(.{ .session_id = harness.session_id + 1 });
    try harness.expectRefused(
        .{ .fetch_id = 1, .body_id = 1, .token = foreign },
        "egress token of another session",
        .strike,
    );
}

test "admission: an expired token fails without a strike" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    // A worker that sends a fetch just before its request's deadline races it honestly.
    const expired = harness.token(.{ .deadline_monotonic_ns = loop_support.passed_deadline_ns });
    try harness.expectRefused(
        .{ .fetch_id = 1, .body_id = 1, .token = expired },
        "egress token expired",
        .no_strike,
    );
    try std.testing.expectEqual(@as(?u32, null), harness.budgetRemaining(request_id, request_generation));
}

test "admission: a token naming a policy the hello did not carry fails without a strike" {
    // Only the server mints policy ids, so the gateway reports the id as a server bug.
    @import("root").expect_log_errors = 1;
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const unknown_policy = harness.token(.{ .policy_id = policy.public_https_id + 1 });
    try harness.expectRefused(
        .{ .fetch_id = 1, .body_id = 1, .token = unknown_policy },
        "egress policy unknown",
        .no_strike,
    );
    try std.testing.expectEqual(@as(?u32, null), harness.budgetRemaining(request_id, request_generation));
}

test "admission: a token whose budget is spent fails and strikes" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    try harness.startShards();
    const token = harness.token(.{ .budget = 2 });

    try harness.expectAdmitted(.{ .fetch_id = 1, .body_id = 1, .token = token });
    try harness.expectAdmitted(.{ .fetch_id = 2, .body_id = 2, .token = token });
    try std.testing.expectEqual(@as(?u32, 0), harness.budgetRemaining(request_id, request_generation));
    try harness.expectRefused(
        .{ .fetch_id = 3, .body_id = 3, .token = token },
        "egress fetch budget exhausted",
        .strike,
    );
    // The refusal undid nothing of the two fetches admitted before it.
    try std.testing.expectEqual(@as(usize, 2), harness.loop.activeFetchesForWorker(harness.session_id));
}

test "admission: a failure after the budget was taken gives the fetch back without a strike" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    try harness.startShards();
    const token = harness.token(.{ .budget = 1 });

    // Recording the route is admission's first allocation, after the fetch was taken from the
    // budget, so failing it fails a fetch the worker did nothing wrong with.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    harness.loop.allocator = failing.allocator();
    try harness.expectRefused(
        .{ .fetch_id = 1, .body_id = 1, .token = token },
        "OutOfMemory",
        .no_strike,
    );
    harness.loop.allocator = std.testing.allocator;

    // The rollback gave the fetch back, so the token's single fetch still admits.
    try std.testing.expectEqual(@as(?u32, 1), harness.budgetRemaining(request_id, request_generation));
    try std.testing.expectEqual(@as(usize, 0), harness.loop.activeFetchesForWorker(harness.session_id));
    try harness.expectAdmitted(.{ .fetch_id = 2, .body_id = 2, .token = token });
    try std.testing.expectEqual(@as(?u32, 0), harness.budgetRemaining(request_id, request_generation));
}

test "admission: a submit error the worker caused keeps the budget use and strikes" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const token = harness.token(.{ .budget = 2 });

    // A response limit above the gateway's is what the worker asked for, and the engine refuses
    // it after admission took the fetch.
    try harness.expectRefused(
        .{ .fetch_id = 1, .body_id = 1, .token = token, .max_body_bytes = std.math.maxInt(u64) },
        "EgressGatewayResponseBodyLimitExceeded",
        .strike,
    );
    try std.testing.expectEqual(@as(?u32, 1), harness.budgetRemaining(request_id, request_generation));
    try std.testing.expectEqual(@as(usize, 0), harness.loop.activeFetchesForWorker(harness.session_id));
}

test "admission: the tag is checked before the session and the session before the deadline" {
    var harness = try Harness.init(.{});
    defer harness.deinit();

    // Another session's token that has also expired strikes for the session.
    const foreign_expired = harness.token(.{
        .session_id = harness.session_id + 1,
        .deadline_monotonic_ns = loop_support.passed_deadline_ns,
    });
    try harness.expectRefused(
        .{ .fetch_id = 1, .body_id = 1, .token = foreign_expired },
        "egress token of another session",
        .strike,
    );

    // A changed token that has also expired strikes for the tag.
    var tampered_expired = harness.token(.{ .deadline_monotonic_ns = loop_support.passed_deadline_ns });
    tampered_expired[@offsetOf(egress_token.Token, "budget")] +%= 1;
    try harness.expectRefused(
        .{ .fetch_id = 2, .body_id = 2, .token = tampered_expired },
        "invalid egress token",
        .strike,
    );
}

test "admission: the deadline and the policy are checked before the caps, and the caps before the budget" {
    @import("root").expect_log_errors = 1;
    var harness = try Harness.init(.{ .policy = .{ .max_active_fetches_per_worker_session = 0 } });
    defer harness.deinit();

    try harness.expectRefused(
        .{ .fetch_id = 1, .body_id = 1, .token = harness.token(.{ .deadline_monotonic_ns = loop_support.passed_deadline_ns }) },
        "egress token expired",
        .no_strike,
    );
    try harness.expectRefused(
        .{ .fetch_id = 2, .body_id = 2, .token = harness.token(.{ .policy_id = policy.public_https_id + 1 }) },
        "egress policy unknown",
        .no_strike,
    );
    try harness.expectRefused(
        .{ .fetch_id = 3, .body_id = 3, .token = harness.token(.{}) },
        "egress worker fetch limit exceeded",
        .strike,
    );
    // The cap refused the fetch before it took anything from the token's budget.
    try std.testing.expectEqual(@as(?u32, null), harness.budgetRemaining(request_id, request_generation));
}

test "admission: an honest worker's tokens from the gateway before stay below the strike limit" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    try harness.startShards();

    // Across a gateway replacement a worker keeps the tokens of the requests it has in flight,
    // and each of their fetches fails the new key: at most this many strikes.
    const fetches_per_request = policy.production.max_fetches_per_request;
    const in_flight_fetches = @as(usize, limits.server.worker_concurrency_max) * fetches_per_request;
    try std.testing.expect(in_flight_fetches < sessions.max_invalid_commands_per_window);

    for (0..in_flight_fetches) |index| {
        const stale = harness.token(.{
            .key = &loop_support.earlier_key,
            .request_id = 100 + index / fetches_per_request,
            .budget = @intCast(fetches_per_request),
        });
        try harness.expectRefused(
            .{ .fetch_id = index + 1, .body_id = index + 1, .token = stale },
            "invalid egress token",
            .strike,
        );
    }
    try std.testing.expectEqual(@as(u32, @intCast(in_flight_fetches)), harness.worker().invalid_commands.count);

    // The session survived them, and the first request dispatched under the new key fetches.
    try harness.expectAdmitted(.{
        .fetch_id = in_flight_fetches + 1,
        .body_id = in_flight_fetches + 1,
        .token = harness.token(.{}),
    });
}

test "admission: the per-worker active-fetch cap refuses with a strike" {
    // The gateway enforces its own limit whatever the worker sends.
    var harness = try Harness.init(.{ .policy = .{ .max_active_fetches_per_worker_session = 0 } });
    defer harness.deinit();
    try harness.expectRefused(
        .{ .fetch_id = 3, .body_id = 4, .token = harness.token(.{}) },
        "egress worker fetch limit exceeded",
        .strike,
    );
}

test "admission: the per-security-cell active-fetch cap refuses with a strike" {
    // A generous per-worker limit and a security-cell limit of zero: the second check refuses.
    var harness = try Harness.init(.{ .policy = .{
        .max_active_fetches_per_worker_session = 64,
        .max_active_fetches_per_security_cell = 0,
    } });
    defer harness.deinit();
    try harness.expectRefused(
        .{ .fetch_id = 3, .body_id = 4, .token = harness.token(.{}) },
        "egress security cell fetch limit exceeded",
        .strike,
    );
}

test "admission: a duplicate fetch identity refuses with a strike" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const worker = harness.worker();

    // The router already holds this identity, as an earlier admission would leave it, and a
    // worker cannot reuse the identity of a live fetch.
    try harness.loop.router.record(harness.loop.allocator, .{
        .worker_session_id = worker.session_id,
        .fetch_id = 7,
        .body_id = 8,
    }, .{
        .shard_index = 0,
        .security_cell_id = security_cell_id,
        .policy_id = policy.public_https_id,
    });

    try std.testing.expect(try harness.sendFetchStart(.{ .fetch_id = 7, .body_id = 8, .token = harness.token(.{}) }));
    try std.testing.expectEqual(@as(u32, 1), worker.invalid_commands.count);
    try harness.expectQueuedFetchError(7, 8, "duplicate egress fetch identity");
    // The identity check runs before the budget is taken.
    try std.testing.expectEqual(@as(?u32, null), harness.budgetRemaining(request_id, request_generation));
}

test "strikes: the invalid-command cap tips a further strike into worker removal" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const worker = harness.worker();

    // The window fills to its budget through the path dispatch uses, with the same clock; it
    // stays open for `sessions.invalid_command_window_ns`, so every one of these lands inside it.
    var count: u32 = 0;
    while (count < sessions.max_invalid_commands_per_window) : (count += 1)
        try std.testing.expect(harness.loop.recordInvalidWorkerCommand(worker));

    // One more invalid command exceeds the budget, so dispatch asks for the worker's removal
    // instead of counting it and going on.
    const forged = harness.token(.{ .key = &loop_support.earlier_key });
    try std.testing.expect(!try harness.sendFetchStart(.{ .fetch_id = 1, .body_id = 1, .token = forged }));
}

test "strikes: handleWorker over the command ring reports removal when a strike tips the cap" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const worker = harness.worker();

    var count: u32 = 0;
    while (count < sessions.max_invalid_commands_per_window) : (count += 1)
        try std.testing.expect(harness.loop.recordInvalidWorkerCommand(worker));

    // The run loop's whole drain path: the packet arrives on the command ring, `handleWorker`
    // drains it, and the invalid command past the budget makes it return false.
    const forged = harness.token(.{ .key = &loop_support.earlier_key });
    try harness.writeCommand(try harness.encodeFetchStart(.{ .fetch_id = 1, .body_id = 1, .token = forged }));
    try std.testing.expect(!harness.loop.handleWorker(0));

    // The run loop removes the worker on that signal, which tears down its registry slot and
    // its budgets, leaves the gateway clean and tells the server, whose worker lost its session.
    try harness.loop.removeWorker(0, .command_ring_failed);
    try std.testing.expectEqual(@as(usize, 0), harness.loop.workers.len());
    try harness.expectSessionRemovedReport(harness.session_id);
}

test "dispatch: handleWorker drains every queued command and queues an error per bad start" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const worker = harness.worker();

    // Three starts under a forged token wait on the command ring together.
    const forged = harness.token(.{ .key = &loop_support.earlier_key });
    const ids = [_]u64{ 100, 200, 300 };
    for (ids) |id|
        try harness.writeCommand(try harness.encodeFetchStart(.{ .fetch_id = id, .body_id = id + 1, .token = forged }));

    // One drain pass handles all three: three invalid commands and three error packets, and
    // the worker stays.
    try std.testing.expect(harness.loop.handleWorker(0));
    try std.testing.expectEqual(@as(u32, 3), worker.invalid_commands.count);
    for (ids) |id|
        try harness.expectQueuedFetchError(id, id + 1, "invalid egress token");
    try harness.expectNoMoreCompletionPackets();
}

test "dispatch: a cancel for an unknown fetch is a strike, not a crash" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const worker = harness.worker();

    var message = ipc.EgressCancel.init(4242, 0);
    try harness.writeCommand(std.mem.asBytes(&message));
    try std.testing.expect(harness.loop.handleWorker(0));
    try std.testing.expectEqual(@as(u32, 1), worker.invalid_commands.count);
}

test "dispatch: a release-body for an unknown route is a strike, not a crash" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const worker = harness.worker();

    var message = ipc.EgressReleaseBody.init(4242, 4343);
    try harness.writeCommand(std.mem.asBytes(&message));
    try std.testing.expect(harness.loop.handleWorker(0));
    try std.testing.expectEqual(@as(u32, 1), worker.invalid_commands.count);
}

test "upload: registerPendingUpload rejects an empty or oversized announced body" {
    var harness = try Harness.init(.{ .policy = .{ .max_request_body_bytes = 1024 } });
    defer harness.deinit();
    const worker = harness.worker();
    const options = harness.uploadSubmitOptions(loop_support.live_deadline_ns);

    // The wire codec refuses an announced length of zero in both directions, so only a view
    // built here can reach this check.
    try std.testing.expectError(
        error.EgressGatewayRequestBodyLimitExceeded,
        harness.loop.registerPendingUpload(worker, loop_support.pooledFetchView(1, 1, 0), 0, options),
    );
    // One byte over the policy's limit is refused before any buffer is allocated.
    try std.testing.expectError(
        error.EgressGatewayRequestBodyLimitExceeded,
        harness.loop.registerPendingUpload(worker, loop_support.pooledFetchView(1, 1, 1025), 0, options),
    );
}

test "upload: a duplicate pending-upload identity is rejected" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const worker = harness.worker();
    const options = harness.uploadSubmitOptions(loop_support.live_deadline_ns);

    try harness.loop.registerPendingUpload(worker, loop_support.pooledFetchView(5, 6, 32), 0, options);
    // The same session and fetch id while the first upload still assembles can only be forged.
    try std.testing.expectError(
        error.EgressGatewayDuplicateFetchIdentity,
        harness.loop.registerPendingUpload(worker, loop_support.pooledFetchView(5, 6, 32), 0, options),
    );
}

test "upload: a chunk whose running total mismatches the ledger fails the upload with a strike" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const worker = harness.worker();

    try harness.loop.registerPendingUpload(
        worker,
        loop_support.pooledFetchView(7, 8, 32),
        0,
        harness.uploadSubmitOptions(loop_support.live_deadline_ns),
    );
    const handle = try harness.writeUploadExtent(&[_]u8{0xab} ** 32);

    // `body_bytes_total` must equal the bytes received so far (0) plus `len` (32); a worker
    // that claims another total corrupts the assembly ledger.
    var released = false;
    const chunk = ipc.EgressUploadChunkView{
        .fetch_id = 7,
        .upload_pool_offset = handle,
        .len = 32,
        .body_bytes_total = 99,
    };
    // The first invalid command inside the window: `applyUploadChunk` returns true, so the
    // worker stays, but the pending upload fails with an error.
    try std.testing.expect(harness.loop.applyUploadChunk(worker, chunk, &released));
    try std.testing.expectEqual(@as(u32, 1), worker.invalid_commands.count);
    try harness.expectQueuedFetchError(7, 8, "egress upload ledger mismatch");
    try std.testing.expect(!harness.loop.pending_uploads.contains(.{
        .worker_session_id = worker.session_id,
        .fetch_id = 7,
    }));
}

test "upload: an unborrowable pool handle removes the worker" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const worker = harness.worker();

    try harness.loop.registerPendingUpload(
        worker,
        loop_support.pooledFetchView(9, 10, 32),
        0,
        harness.uploadSubmitOptions(loop_support.live_deadline_ns),
    );
    // Handle 0 never names a published extent. A handle the pool rejects means corrupt shared
    // state, so `applyUploadChunk` returns false and the worker is removed.
    var released = false;
    const chunk = ipc.EgressUploadChunkView{
        .fetch_id = 9,
        .upload_pool_offset = 0,
        .len = 32,
        .body_bytes_total = 32,
    };
    try std.testing.expect(!harness.loop.applyUploadChunk(worker, chunk, &released));
}

test "upload: an extent trailing a retired fetch is released quietly" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const worker = harness.worker();

    // This fetch has no pending upload, as after a cancel, a failure or its request's end
    // retired it, so its late extent goes back to the pool without counting an invalid command.
    const handle = try harness.writeUploadExtent(&[_]u8{0xcd} ** 16);
    var released = false;
    const chunk = ipc.EgressUploadChunkView{
        .fetch_id = 4242,
        .upload_pool_offset = handle,
        .len = 16,
        .body_bytes_total = 16,
    };
    try std.testing.expect(harness.loop.applyUploadChunk(worker, chunk, &released));
    try std.testing.expect(released);
    try std.testing.expectEqual(@as(u32, 0), worker.invalid_commands.count);
}

test "upload: a body-pooled fetch waits for its body, then reaches the engine with its token's request and deadline" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    try harness.startShards();
    const worker = harness.worker();

    const deadline = loop_support.live_deadline_ns - 11;
    const payload = [_]u8{0xee} ** 48;
    const token = harness.token(.{ .budget = 4, .deadline_monotonic_ns = deadline });
    try harness.expectAdmitted(.{
        .fetch_id = 11,
        .body_id = 12,
        .token = token,
        .pooled_body_len = payload.len,
    });
    // Admission took the fetch from the token's budget and parked it until its body arrives.
    try std.testing.expectEqual(@as(?u32, 3), harness.budgetRemaining(request_id, request_generation));
    try std.testing.expect(harness.loop.pending_uploads.contains(.{
        .worker_session_id = worker.session_id,
        .fetch_id = 11,
    }));
    try std.testing.expect(harness.activeFetch(11, 12) == null);

    // One extent carries the whole announced body, so assembly completes and the fetch is
    // submitted with its buffer handed to the engine's task.
    const handle = try harness.writeUploadExtent(&payload);
    var released = false;
    const chunk = ipc.EgressUploadChunkView{
        .fetch_id = 11,
        .upload_pool_offset = handle,
        .len = payload.len,
        .body_bytes_total = payload.len,
    };
    try std.testing.expect(harness.loop.applyUploadChunk(worker, chunk, &released));
    try std.testing.expect(!harness.loop.pending_uploads.contains(.{
        .worker_session_id = worker.session_id,
        .fetch_id = 11,
    }));

    // The engine's record carries what admission took from the token, as an inline body's does.
    const fetch = harness.activeFetch(11, 12) orelse return error.MissingActiveFetch;
    try std.testing.expectEqual(deadline, fetch.request_deadline_mono_ns);
    try std.testing.expectEqual(gateway.budgets.BudgetKey{
        .session_id = harness.session_id,
        .request_id = request_id,
        .request_generation = request_generation,
    }, fetch.budget_key);
}

test "upload: removing a worker frees its assembling uploads with their routes and counts" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const session_id = harness.session_id;
    const pending_key = gateway.testing.upload_flow.PendingKey{
        .worker_session_id = session_id,
        .fetch_id = 31,
    };

    try harness.expectAdmitted(.{
        .fetch_id = 31,
        .body_id = 32,
        .token = harness.token(.{}),
        .pooled_body_len = 64,
    });
    try std.testing.expect(harness.loop.pending_uploads.contains(pending_key));

    try harness.loop.removeWorker(0, .forced_drop);
    try harness.expectSessionRemovedReport(session_id);

    // The upload left both of its indexes; the testing allocator's leak check at `deinit` shows
    // its buffers went with it.
    try std.testing.expectEqual(@as(usize, 0), harness.loop.workers.len());
    try std.testing.expect(!harness.loop.pending_uploads.contains(pending_key));
    try std.testing.expect(harness.loop.pending_uploads.anyOfRequest(.{
        .session_id = session_id,
        .request_id = request_id,
        .request_generation = request_generation,
    }) == null);
    try std.testing.expect(harness.loop.router.routeForFetch(session_id, 31) == null);
    try std.testing.expectEqual(@as(usize, 0), harness.loop.activeFetchesForWorker(session_id));
    try std.testing.expectEqual(@as(usize, 0), harness.loop.activeFetchesForSecurityCell(security_cell_id));
}

test "upload: a failed upload gives its fetch back to the token's budget" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const worker = harness.worker();

    const token = harness.token(.{ .budget = 1 });
    try harness.expectAdmitted(.{ .fetch_id = 21, .body_id = 22, .token = token, .pooled_body_len = 32 });
    try std.testing.expectEqual(@as(?u32, 0), harness.budgetRemaining(request_id, request_generation));

    // A ledger mismatch fails the upload before it reaches an engine.
    const handle = try harness.writeUploadExtent(&[_]u8{0xab} ** 32);
    var released = false;
    const chunk = ipc.EgressUploadChunkView{
        .fetch_id = 21,
        .upload_pool_offset = handle,
        .len = 32,
        .body_bytes_total = 99,
    };
    try std.testing.expect(harness.loop.applyUploadChunk(worker, chunk, &released));
    try harness.expectQueuedFetchError(21, 22, "egress upload ledger mismatch");
    try std.testing.expectEqual(@as(?u32, 1), harness.budgetRemaining(request_id, request_generation));
    try std.testing.expectEqual(@as(usize, 0), harness.loop.activeFetchesForWorker(harness.session_id));
}

test "upload: an assembled upload's task frees its buffer without moving its shard's memory count" {
    // Without connector threads the engine refuses the submission after the fetch's task took
    // the buffer, so the task ends inside the submit, on this thread.
    var harness = try Harness.init(.{ .engine_connector_count = 0 });
    defer harness.deinit();
    const worker = harness.worker();
    const shard_memory = harness.loop.shards.get(0).memory;
    const token = harness.token(.{ .budget = 4 });

    // An inline fetch refused the same way sizes the shard's active table, which keeps its
    // capacity, so from here the count moves only with what the upload's task holds.
    try harness.expectRefused(
        .{ .fetch_id = 1, .body_id = 1, .token = token },
        "EgressEngineUnavailable",
        .no_strike,
    );
    const live_bytes_before = shard_memory.liveBytes();

    const payload = [_]u8{0x5c} ** 48;
    try harness.expectAdmitted(.{
        .fetch_id = 2,
        .body_id = 2,
        .token = token,
        .pooled_body_len = payload.len,
    });
    const handle = try harness.writeUploadExtent(&payload);
    var released = false;
    const chunk = ipc.EgressUploadChunkView{
        .fetch_id = 2,
        .upload_pool_offset = handle,
        .len = payload.len,
        .body_bytes_total = payload.len,
    };
    try std.testing.expect(harness.loop.applyUploadChunk(worker, chunk, &released));

    // The assembled fetch reached the engine, whose task took the buffer and ended.
    try harness.expectQueuedFetchError(2, 2, "EgressEngineUnavailable");
    try std.testing.expect(!harness.loop.pending_uploads.contains(.{
        .worker_session_id = worker.session_id,
        .fetch_id = 2,
    }));
    try std.testing.expectEqual(live_bytes_before, shard_memory.liveBytes());
}

test "upload: an upload dropped before submission leaves its shard's memory count unchanged" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const worker = harness.worker();
    const shard_memory = harness.loop.shards.get(0).memory;
    const live_bytes_before = shard_memory.liveBytes();

    try harness.expectAdmitted(.{
        .fetch_id = 3,
        .body_id = 3,
        .token = harness.token(.{}),
        .pooled_body_len = 64,
    });
    // Half the body arrives, then the request ends, which drops the upload with its buffer.
    const handle = try harness.writeUploadExtent(&[_]u8{0x3c} ** 32);
    var released = false;
    const chunk = ipc.EgressUploadChunkView{
        .fetch_id = 3,
        .upload_pool_offset = handle,
        .len = 32,
        .body_bytes_total = 32,
    };
    try std.testing.expect(harness.loop.applyUploadChunk(worker, chunk, &released));
    try harness.sendRequestEnded(&.{.{
        .session_id = harness.session_id,
        .request_id = request_id,
        .request_generation = request_generation,
    }});

    try std.testing.expect(!harness.loop.pending_uploads.contains(.{
        .worker_session_id = worker.session_id,
        .fetch_id = 3,
    }));
    try std.testing.expectEqual(live_bytes_before, shard_memory.liveBytes());
}

/// Recomputes the tag of `bytes` under `key` as `egress_token.mint` does, so a token whose
/// version or kind byte changed passes the tag check and reaches the checks behind it.
fn retag(bytes: *egress_token.Bytes, key: *const egress_token.Key) void {
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, bytes[0..egress_token.body_bytes], &key.bytes);
    bytes[egress_token.body_bytes..].* = mac[0..egress_token.tag_bytes].*;
}

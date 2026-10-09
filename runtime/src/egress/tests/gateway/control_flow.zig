//! The gateway's end of the control socket (`runtime/control_flow.zig`) for what the server tells
//! it about egress tokens, over the loop stand-in in `support/loop.zig` with the test as the
//! server. The hello gives the gateway its key, its policy table and one isolation id per entry,
//! which admission then applies, and leaves no copy of the key in the packet scratch; before the
//! hello the gateway takes nothing but shutdown, and a second hello ends it. A `request_ended`
//! entry ends its request's budget, so the same token starts a new one, cancels the request's
//! running fetches and drops its assembling uploads, and leaves every other request's alone; an
//! entry for a session the gateway does not hold, or a batch sent twice, changes nothing more. A
//! boot token admits nothing past the child window or after its own `request_ended`, and neither
//! refusal counts against the worker. A session the gateway removes on its own reaches the server
//! as a report, except one whose attach ack never left; a report the full socket holds back leaves
//! in order once there is room, one the server can no longer receive is dropped, and one that can
//! be neither sent nor queued ends the gateway. The wire format of these packets is covered in
//! `control.zig` and the budget rules in `budgets.zig`. Lane: egress-gateway-test.

const std = @import("std");
const gateway = @import("collo_egress_gateway");
const ipc = @import("collo_ipc");

const engine_test = @import("support/engine.zig");
const loop_support = @import("support/loop.zig");

const control = gateway.control;
const policy = gateway.policy;
const Harness = loop_support.Harness;

const request_id = loop_support.request_id;
const request_generation = loop_support.request_generation;

/// The entry a test harness sends for an origin that is plain HTTP on a private address.
const loosened: policy.NetworkPolicy = .{
    .kind = .any_host,
    .allow_private_networks = true,
    .allow_http = true,
};

fn twoEntryTable() policy.PolicyTable {
    var table: policy.PolicyTable = .{ .count = 2 };
    table.entries[0] = policy.public_https;
    table.entries[1] = loosened;
    return table;
}

/// Passes when the packet waiting on the control socket breaks the hello's order: `drainControl`
/// fails with it, which ends the gateway's loop, so the server sees the channel fail.
fn expectOutOfOrder(harness: *Harness) !void {
    try std.testing.expectError(error.EgressGatewayControlOutOfOrder, harness.loop.drainControl());
}

test "the hello gives the gateway its key, its policy table and one isolation id per entry" {
    var harness = try Harness.init(.{ .hello_table = null });
    defer harness.deinit();
    try std.testing.expect(harness.helloKey().isZero());

    const table = twoEntryTable();
    try harness.sendHello(&table);
    try std.testing.expect(!try harness.loop.drainControl());

    try std.testing.expectEqualSlices(u8, &loop_support.hello_key.bytes, &harness.helloKey().bytes);
    try std.testing.expectEqual(table.count, harness.helloPolicies().count);
    const limits_id = policy.policyIsolationId(policy.production);
    for (table.slice(), 0..) |entry, index| {
        const id: u16 = @intCast(index);
        try std.testing.expectEqual(entry, harness.helloPolicies().slice()[index]);
        const expected = policy.networkPolicyIsolationId(limits_id, id, entry);
        try std.testing.expectEqualSlices(u8, &expected, &harness.isolationId(id));
    }
    // Fetches under the two entries never share a pooled connection.
    try std.testing.expect(!std.mem.eql(u8, &harness.isolationId(0), &harness.isolationId(1)));
    // The packet scratch, which worker commands and worker-bound packets
    // also pass through, keeps no copy of the key.
    try std.testing.expect(std.mem.indexOf(u8, harness.loop.scratch, &loop_support.hello_key.bytes) == null);
}

test "a token's policy entry places its fetch by that entry's isolation id" {
    const shard_count: usize = 4;
    var harness = try Harness.init(.{ .hello_table = twoEntryTable(), .shard_count = shard_count });
    defer harness.deinit();
    try harness.startShards();

    for ([_]u16{ 0, 1 }) |policy_id| {
        const fetch_id: u64 = 10 + policy_id;
        try harness.expectAdmitted(.{
            .fetch_id = fetch_id,
            .body_id = fetch_id,
            .token = harness.token(.{ .policy_id = policy_id, .request_id = 50 + policy_id }),
        });
        const route = harness.loop.router.routeForBody(harness.session_id, fetch_id, fetch_id) orelse
            return error.MissingRoute;
        try std.testing.expectEqual(policy_id, route.record.policy_id);
        var url_buffer: [loop_support.loopback_url_bytes_max]u8 = undefined;
        const expected_shard = gateway.shard.hashFetch(.{
            .security_cell_id = loop_support.security_cell_id,
            .policy_id = harness.isolationId(policy_id),
        }, loop_support.loopbackUrl(&url_buffer, fetch_id), shard_count);
        try std.testing.expectEqual(expected_shard, route.record.shard_index);
    }
}

test "before its hello the gateway ends on any packet but shutdown" {
    // A `request_ended` before the hello.
    {
        var harness = try Harness.init(.{ .hello_table = null });
        defer harness.deinit();
        try harness.sendRequestEndedPacket(&.{.{
            .session_id = harness.session_id,
            .request_id = request_id,
            .request_generation = request_generation,
        }});
        try expectOutOfOrder(&harness);
    }
    // An attach before the hello: the gateway neither maps the session nor acknowledges it.
    {
        var harness = try Harness.init(.{ .hello_table = null });
        defer harness.deinit();
        var fds = try loop_support.createSession();
        defer fds.deinit();
        try control.sendAttachWorker(harness.server_fd, 1, loop_support.security_cell_id, fds.rawForGateway());
        try expectOutOfOrder(&harness);
        try std.testing.expectEqual(@as(usize, 1), harness.loop.workers.len());
        var scratch: [256]u8 = undefined;
        try std.testing.expectError(
            error.WouldBlock,
            ipc.recvPacketWithFdsScratch(std.testing.allocator, harness.server_fd, &scratch),
        );
    }
    // Shutdown before the hello is an orderly stop.
    {
        var harness = try Harness.init(.{ .hello_table = null });
        defer harness.deinit();
        try control.sendShutdown(harness.server_fd);
        try std.testing.expect(try harness.loop.drainControl());
    }
}

test "a second hello ends the gateway and leaves the first key in place" {
    var harness = try Harness.init(.{});
    defer harness.deinit();

    const table = policy.PolicyTable.single(loosened);
    try control.sendHello(harness.server_fd, &loop_support.earlier_key, &table);
    try expectOutOfOrder(&harness);
    try std.testing.expectEqualSlices(u8, &loop_support.hello_key.bytes, &harness.helloKey().bytes);
    try std.testing.expectEqual(policy.public_https, harness.helloPolicies().slice()[0]);
}

test "request_ended ends the request's budget, and the same token starts a new one" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    try harness.startShards();
    const token = harness.token(.{ .budget = 1 });

    try harness.expectAdmitted(.{ .fetch_id = 1, .body_id = 1, .token = token });
    try harness.expectRefused(
        .{ .fetch_id = 2, .body_id = 2, .token = token },
        "egress fetch budget exhausted",
        .strike,
    );

    try harness.sendRequestEnded(&.{.{
        .session_id = harness.session_id,
        .request_id = request_id,
        .request_generation = request_generation,
    }});
    try std.testing.expectEqual(@as(?u32, null), harness.budgetRemaining(request_id, request_generation));

    // A worker that kept the token after its request gets the token's budget again, and only
    // until the token's deadline (`budgets.zig`).
    try harness.expectAdmitted(.{ .fetch_id = 3, .body_id = 3, .token = token });
    try std.testing.expectEqual(@as(?u32, 0), harness.budgetRemaining(request_id, request_generation));
}

test "request_ended cancels the request's running fetches and leaves other requests' fetches running" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    try harness.startShards();

    try harness.expectAdmitted(.{ .fetch_id = 1, .body_id = 1, .token = harness.token(.{ .request_id = 11 }) });
    try harness.expectAdmitted(.{ .fetch_id = 2, .body_id = 2, .token = harness.token(.{ .request_id = 12 }) });

    try harness.sendRequestEnded(&.{.{
        .session_id = harness.session_id,
        .request_id = 11,
        .request_generation = request_generation,
    }});

    const engine = &harness.loop.shards.get(0).engine;
    try std.testing.expect(engine_test.activeFetchCanceled(engine, harness.session_id, 1));
    try std.testing.expect(!engine_test.activeFetchCanceled(engine, harness.session_id, 2));
    try std.testing.expectEqual(@as(?u32, null), harness.budgetRemaining(11, request_generation));
    try std.testing.expect(harness.budgetRemaining(12, request_generation) != null);
}

test "request_ended drops the request's assembling uploads, keeps other requests' uploads and sends the worker nothing" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const ended_upload = gateway.testing.upload_flow.PendingKey{
        .worker_session_id = harness.session_id,
        .fetch_id = 5,
    };
    const kept_upload = gateway.testing.upload_flow.PendingKey{
        .worker_session_id = harness.session_id,
        .fetch_id = 7,
    };

    try harness.expectAdmitted(.{
        .fetch_id = 5,
        .body_id = 6,
        .token = harness.token(.{ .request_id = 11 }),
        .pooled_body_len = 32,
    });
    try harness.expectAdmitted(.{
        .fetch_id = 7,
        .body_id = 8,
        .token = harness.token(.{ .request_id = 12 }),
        .pooled_body_len = 32,
    });
    try std.testing.expect(harness.loop.pending_uploads.contains(ended_upload));
    try std.testing.expect(harness.loop.pending_uploads.contains(kept_upload));

    try harness.sendRequestEnded(&.{.{
        .session_id = harness.session_id,
        .request_id = 11,
        .request_generation = request_generation,
    }});

    // The ended request's upload, its route and its count are gone, and its budget with them.
    try std.testing.expect(!harness.loop.pending_uploads.contains(ended_upload));
    try std.testing.expect(harness.loop.router.routeForFetch(harness.session_id, 5) == null);
    try std.testing.expectEqual(@as(?u32, null), harness.budgetRemaining(11, request_generation));
    // The other request's upload still assembles, under its own budget.
    try std.testing.expect(harness.loop.pending_uploads.contains(kept_upload));
    try std.testing.expect(harness.loop.router.routeForFetch(harness.session_id, 7) != null);
    try std.testing.expectEqual(@as(usize, 1), harness.loop.activeFetchesForWorker(harness.session_id));
    try std.testing.expect(harness.budgetRemaining(12, request_generation) != null);
    try harness.expectNoMoreCompletionPackets();
}

test "a boot token admits nothing past the child window or after its request_ended, and neither refusal strikes (#48)" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    try harness.startShards();

    // A boot token whose child window has closed.
    try harness.expectRefused(
        .{ .fetch_id = 1, .body_id = 1, .token = harness.bootToken(loop_support.passed_deadline_ns) },
        "egress token expired",
        .no_strike,
    );

    // Within the window the boot token admits fetches, until the launcher ends it at
    // `WorkerReady`.
    const boot = harness.bootToken(loop_support.live_deadline_ns);
    try harness.expectAdmitted(.{ .fetch_id = 2, .body_id = 2, .token = boot });
    try harness.sendRequestEnded(&.{.{
        .session_id = harness.session_id,
        .request_id = 0,
        .request_generation = 0,
    }});
    try harness.expectRefused(
        .{ .fetch_id = 3, .body_id = 3, .token = boot },
        "egress boot token ended",
        .no_strike,
    );
    try std.testing.expectEqual(@as(u32, 0), harness.worker().invalid_commands.count);

    // The session's request tokens still admit.
    try harness.expectAdmitted(.{ .fetch_id = 4, .body_id = 4, .token = harness.token(.{}) });
}

test "request_ended skips a session the gateway does not hold, and a batch sent twice ends nothing more" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    try harness.startShards();
    const token = harness.token(.{ .budget = 2 });
    try harness.expectAdmitted(.{ .fetch_id = 1, .body_id = 1, .token = token });

    const entries = [_]control.RequestEndedEntry{
        .{
            .session_id = harness.session_id + 1,
            .request_id = request_id,
            .request_generation = request_generation,
        },
        .{
            .session_id = harness.session_id,
            .request_id = request_id,
            .request_generation = request_generation,
        },
    };
    try harness.sendRequestEnded(&entries);
    try harness.sendRequestEnded(&entries);
    try std.testing.expectEqual(@as(?u32, null), harness.budgetRemaining(request_id, request_generation));

    // The token starts one budget of its own size, and nothing counted against the worker.
    try harness.expectAdmitted(.{ .fetch_id = 2, .body_id = 2, .token = token });
    try std.testing.expectEqual(@as(?u32, 1), harness.budgetRemaining(request_id, request_generation));
    try std.testing.expectEqual(@as(u32, 0), harness.worker().invalid_commands.count);
}

test "a session the gateway removes on its own reaches the server as a report, and one whose attach ack never left does not" {
    const reported = [_]gateway.testing.worker_flow.WorkerRemovalReason{ .liveness_closed, .command_ring_failed, .forced_drop };
    for (reported) |reason| {
        var harness = try Harness.init(.{});
        defer harness.deinit();
        try harness.loop.removeWorker(0, reason);
        try std.testing.expectEqual(@as(usize, 0), harness.loop.workers.len());
        try harness.expectSessionRemovedReport(harness.session_id);
        try harness.expectNoServerPacket();
    }

    var harness = try Harness.init(.{});
    defer harness.deinit();
    try harness.loop.removeWorker(0, .attach_ack_failed);
    try std.testing.expectEqual(@as(usize, 0), harness.loop.workers.len());
    try harness.expectNoServerPacket();
}

test "a removal report the full socket holds back waits behind the packets before it and leaves once there is room" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const filler = try harness.fillControlSocket();

    try harness.loop.removeWorker(0, .liveness_closed);
    try std.testing.expectEqual(@as(usize, 1), harness.loop.pending_control_packets.len());
    // The loop then polls the socket for room.
    try std.testing.expect((harness.loop.controlEvents() & std.posix.POLL.OUT) != 0);

    try harness.drainFiller(filler);
    try harness.loop.flushPendingControlPackets();
    try std.testing.expect(harness.loop.pending_control_packets.isEmpty());
    try harness.expectSessionRemovedReport(harness.session_id);
    try harness.expectNoServerPacket();
}

test "a removal report to a server that closed its end is dropped, and the gateway goes on to the hang-up" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    harness.closeServerEnd();

    try harness.loop.removeWorker(0, .liveness_closed);
    try std.testing.expectEqual(@as(usize, 0), harness.loop.workers.len());
    try std.testing.expect(harness.loop.pending_control_packets.isEmpty());
    // The loop sees the server gone on its control socket, where it ends.
    try std.testing.expect(try harness.loop.drainControl());
}

test "a removal report that can be neither sent nor queued ends the gateway" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const filler = try harness.fillControlSocket();
    // Reports of sessions the loop never had fill the queue the full socket holds them in; the
    // bound keeps a broken queue from looping forever.
    var queued: usize = 0;
    while (true) : (queued += 1) {
        try std.testing.expect(queued <= gateway.sizing.workers_max + 1);
        harness.loop.reportSessionRemoved(harness.session_id + 1 + queued) catch |err| {
            try std.testing.expectEqual(error.EgressGatewayControlBackpressure, err);
            break;
        };
    }

    try std.testing.expectError(
        error.EgressGatewayControlBackpressure,
        harness.loop.removeWorker(0, .forced_drop),
    );
    // The session is gone all the same; the gateway's end makes the server replace it.
    try std.testing.expectEqual(@as(usize, 0), harness.loop.workers.len());
    try harness.drainFiller(filler);
}

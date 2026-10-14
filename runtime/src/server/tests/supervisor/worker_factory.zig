//! The egress side of a launch as the supervisor prepares it
//! (`server/supervisor/worker_factory.zig`), against a gateway that stands
//! behind the supervisor's egress hooks on the test thread. A worker of a
//! definition with a grant gets a new session built on its wake set, and a
//! boot token grant beside it that names the session's gateway key, the
//! definition's boot policy and the boot budget; once that gateway is no
//! longer current the session comes without a grant. A definition without a
//! grant gets nothing and asks the gateway nothing. A launch with no gateway
//! wired, a session the gateway hands back incomplete or an attach that fails
//! leaves nothing open. What the launcher does with the grant is covered in
//! `launcher.zig`, and the union a boot policy names in
//! `server/tests/routes/network.zig`. The supervisor ends a published
//! worker's boot token once the worker's startup-end flag reads 1
//! (`Supervisor.progressBootEgress`), on the launch's session whatever
//! session the worker holds now, retries a failed send whatever the flag
//! reads later, sends nothing for any other flag value or past the token's
//! deadline, and an end sent for one worker leaves the record's next worker
//! alone. Lane `server-supervisor-test`.

const std = @import("std");
const ipc = @import("collo_ipc");
const lifecycle = @import("collo_server_lifecycle");
const supervision = @import("collo_server_supervisor");
const fixture = @import("supervisor_fixture");

const testing = std.testing;
const worker_factory = supervision.worker_factory;
const egress_token = ipc.egress_token;
const Supervisor = supervision.Supervisor;
const WakeSet = ipc.egress_shared.WakeSet;

const gateway_generation: u64 = 5;
const gateway_key: egress_token.Key = .{ .bytes = @splat(0x6b) };
const first_session_id: u64 = 9;

test "a launch's egress pairs a new session on the worker's wake set with a boot grant under its gateway's key" {
    var supervisor = try fixture.minimalSupervisor(testing.allocator);
    defer fixture.deinitMinimal(&supervisor);
    var gateway: FakeGateway = .{};
    gateway.wire(&supervisor);
    var wake_set = try WakeSet.create();
    defer wake_set.deinit();

    var egress = (try worker_factory.attachLaunchEgress(&supervisor, fixture.default_definition, &wake_set)) orelse
        return error.TestExpectedEgressGrant;
    defer egress.attachment.deinit();
    try testing.expect(egress.attachment.isValid());
    try testing.expectEqual(gateway_generation, egress.attachment.generation);
    try testing.expectEqual(first_session_id, egress.attachment.session_id);
    const boot = egress.boot orelse return error.TestExpectedBootGrant;
    try testing.expectEqualSlices(u8, &gateway_key.bytes, &boot.key.bytes);
    try testing.expectEqual(first_session_id, boot.session_id);
    const boot_policy = supervisor.routes.network.bootPolicy(fixture.default_definition);
    try testing.expect(boot_policy != 0);
    try testing.expectEqual(boot_policy, boot.policy_id);

    // The attach named the worker's definition and built on its wake set.
    try testing.expectEqual(@as(u32, 1), gateway.attaches);
    try testing.expectEqualStrings(fixture.definition_names[fixture.default_definition], gateway.definition_name);
    try testing.expectEqual(@as(?*const WakeSet, &wake_set), gateway.wake_set);
    try testing.expectEqual(@as(?u64, gateway_generation), gateway.key_asked_for);
}

test "a session whose gateway is no longer current once the attach returns comes without a boot grant" {
    var supervisor = try fixture.minimalSupervisor(testing.allocator);
    defer fixture.deinitMinimal(&supervisor);
    var gateway: FakeGateway = .{ .key_known = false };
    gateway.wire(&supervisor);
    var wake_set = try WakeSet.create();
    defer wake_set.deinit();

    var egress = (try worker_factory.attachLaunchEgress(&supervisor, fixture.default_definition, &wake_set)) orelse
        return error.TestExpectedEgressGrant;
    defer egress.attachment.deinit();
    try testing.expect(egress.attachment.isValid());
    try testing.expect(egress.boot == null);
    try testing.expectEqual(@as(?u64, gateway_generation), gateway.key_asked_for);
}

test "a definition without a network grant gets no session and asks the gateway nothing" {
    var granted: [fixture.definition_names.len]bool = @splat(true);
    granted[fixture.default_definition] = false;
    var supervisor = try fixture.minimalSupervisorWith(testing.allocator, .{ .routes = .{ .granted = granted } });
    defer fixture.deinitMinimal(&supervisor);
    var gateway: FakeGateway = .{};
    gateway.wire(&supervisor);
    var wake_set = try WakeSet.create();
    defer wake_set.deinit();

    try testing.expect(!worker_factory.definitionHasEgressGrant(&supervisor, fixture.default_definition));
    try testing.expect(worker_factory.definitionHasEgressGrant(&supervisor, fixture.default_definition + 1));
    try testing.expect(try worker_factory.attachLaunchEgress(&supervisor, fixture.default_definition, &wake_set) == null);
    try testing.expectEqual(@as(u32, 0), gateway.attaches);
    try testing.expect(gateway.key_asked_for == null);
}

test "a launch's egress fails with nothing open when no gateway is wired, the attach fails or its session is incomplete" {
    var supervisor = try fixture.minimalSupervisor(testing.allocator);
    defer fixture.deinitMinimal(&supervisor);
    var wake_set = try WakeSet.create();
    defer wake_set.deinit();
    const open_before = try openFdCount();

    try testing.expectError(
        error.EgressGatewayRequired,
        worker_factory.attachLaunchEgress(&supervisor, fixture.default_definition, &wake_set),
    );

    var refusing: FakeGateway = .{ .attach_error = error.EgressGatewayAttachRejected };
    refusing.wire(&supervisor);
    try testing.expectError(
        error.EgressGatewayAttachRejected,
        worker_factory.attachLaunchEgress(&supervisor, fixture.default_definition, &wake_set),
    );

    var incomplete: FakeGateway = .{ .incomplete = true };
    incomplete.wire(&supervisor);
    try testing.expectError(
        error.EgressGatewayRequired,
        worker_factory.attachLaunchEgress(&supervisor, fixture.default_definition, &wake_set),
    );
    try testing.expectEqual(@as(u32, 1), incomplete.attaches);
    try testing.expect(incomplete.key_asked_for == null);
    try testing.expectEqual(open_before, try openFdCount());
}

const boot_deadline_ns: u64 = 10 * std.time.ns_per_s;
const boot_token: supervision.worker_table.BootToken = .{
    .gateway_generation = gateway_generation,
    .session_id = first_session_id,
    .deadline_mono_ns = boot_deadline_ns,
};

test "the startup-end flag ends the boot token once, and readiness alone does not" {
    var supervisor = try fixture.minimalSupervisor(testing.allocator);
    defer fixture.deinitMinimal(&supervisor);
    const worker = try fixture.publishInertWorker(&supervisor, .{});
    var worker_page = try fixture.WorkerPage.attach(worker);
    defer worker_page.deinit();
    worker.boot_egress = boot_token;
    var gateway: FakeGateway = .{};
    gateway.wire(&supervisor);
    worker_page.writer.setState(.ready, .none);
    supervisor.progressBootEgress(worker, 1);
    try testing.expectEqual(@as(usize, 0), gateway.end_attempts);

    worker_page.writer.publishStartupEvaluationsEnded();
    supervisor.progressBootEgress(worker, 2);
    try testing.expectEqual(@as(usize, 1), gateway.end_attempts);
    try testing.expect(worker.boot_egress == null);
    supervisor.progressBootEgress(worker, 3);
    try testing.expectEqual(@as(usize, 1), gateway.end_attempts);
}

test "a failed boot end is retried even if the worker clears its startup flag" {
    var supervisor = try fixture.minimalSupervisor(testing.allocator);
    defer fixture.deinitMinimal(&supervisor);
    const worker = try fixture.publishInertWorker(&supervisor, .{});
    var worker_page = try fixture.WorkerPage.attach(worker);
    defer worker_page.deinit();
    worker.boot_egress = boot_token;
    var gateway: FakeGateway = .{ .end_sent = false };
    gateway.wire(&supervisor);
    const view = &worker_page.writer;
    view.publishStartupEvaluationsEnded();
    supervisor.progressBootEgress(worker, 1);
    try testing.expectEqual(@as(usize, 1), gateway.end_attempts);
    @atomicStore(u32, &view.header.startup_evaluations_ended, 0, .release);
    gateway.end_sent = true;
    supervisor.progressBootEgress(worker, 2);
    try testing.expectEqual(@as(usize, 2), gateway.end_attempts);
    try testing.expect(worker.boot_egress == null);
}

test "a worker on a replacement session has the boot token of its launch session ended" {
    var supervisor = try fixture.minimalSupervisor(testing.allocator);
    defer fixture.deinitMinimal(&supervisor);
    const worker = try fixture.publishInertWorker(&supervisor, .{});
    var worker_page = try fixture.WorkerPage.attach(worker);
    defer worker_page.deinit();
    worker.boot_egress = boot_token;
    var gateway: FakeGateway = .{};
    gateway.wire(&supervisor);
    worker.egress_gateway_generation = gateway_generation + 1;
    worker.egress_gateway_session_id = first_session_id + 1;
    worker_page.writer.publishStartupEvaluationsEnded();
    supervisor.progressBootEgress(worker, 1);
    try testing.expectEqual(gateway_generation, gateway.ended_generation);
    try testing.expectEqual(first_session_id, gateway.ended_session);
}

test "a startup-end flag other than 1 ends nothing, and a token past its deadline is dropped unsent" {
    var supervisor = try fixture.minimalSupervisor(testing.allocator);
    defer fixture.deinitMinimal(&supervisor);
    const worker = try fixture.publishInertWorker(&supervisor, .{});
    var worker_page = try fixture.WorkerPage.attach(worker);
    defer worker_page.deinit();
    worker.boot_egress = boot_token;
    var gateway: FakeGateway = .{};
    gateway.wire(&supervisor);
    const view = &worker_page.writer;
    for ([_]u32{ 0, 2, std.math.maxInt(u32) }) |flag| {
        @atomicStore(u32, &view.header.startup_evaluations_ended, flag, .release);
        supervisor.progressBootEgress(worker, 1);
    }
    try testing.expectEqual(@as(usize, 0), gateway.end_attempts);
    supervisor.progressBootEgress(worker, boot_deadline_ns);
    try testing.expect(worker.boot_egress == null);
    view.publishStartupEvaluationsEnded();
    supervisor.progressBootEgress(worker, boot_deadline_ns);
    try testing.expectEqual(@as(usize, 0), gateway.end_attempts);
}

test "an end sent for one worker leaves the boot token of the record's next worker" {
    var supervisor = try fixture.minimalSupervisor(testing.allocator);
    defer fixture.deinitMinimal(&supervisor);
    const worker = try fixture.publishInertWorker(&supervisor, .{});
    var worker_page = try fixture.WorkerPage.attach(worker);
    defer worker_page.deinit();
    worker.boot_egress = boot_token;
    worker_page.writer.publishStartupEvaluationsEnded();
    const old = worker.bootEndAttempt(1).?;
    // The record now holds another worker, whose end is not owed yet.
    worker.generation += 1;
    worker.boot_end_pending = false;
    worker.completeBootEnd(old);
    try testing.expectEqual(boot_token, worker.boot_egress.?);
}

/// One gateway behind the supervisor's egress hooks, run on the test thread:
/// each attach builds a session on the wake set it is given, as
/// `Manager.attachWorker` does, and the gateway's key is known only while
/// `key_known`, as `Manager.keyFor` knows it only while that gateway is
/// current.
const FakeGateway = struct {
    key_known: bool = true,
    /// What every attach fails with instead of building a session.
    attach_error: ?anyerror = null,
    /// Every attach hands back a session with id 0, which `isValid` refuses.
    incomplete: bool = false,
    attaches: u32 = 0,
    definition_name: []const u8 = "",
    wake_set: ?*const WakeSet = null,
    key_asked_for: ?u64 = null,
    /// What each boot token's end answers, as `Manager.endBoot` does.
    end_sent: bool = true,
    end_attempts: usize = 0,
    ended_generation: u64 = 0,
    ended_session: u64 = 0,

    fn wire(self: *FakeGateway, supervisor: *Supervisor) void {
        supervisor.setEgressGatewayHooks(.{
            .ctx = self,
            .attach = attach,
            .currentGeneration = currentGeneration,
            .keyFor = keyFor,
            .prewarm = prewarm,
            .bootEnded = bootEnded,
        });
    }

    fn attach(
        ctx: *anyopaque,
        definition_name: []const u8,
        wake_set: *const WakeSet,
    ) anyerror!lifecycle.EgressGatewayAttachment {
        const self: *FakeGateway = @ptrCast(@alignCast(ctx));
        self.attaches += 1;
        self.definition_name = definition_name;
        self.wake_set = wake_set;
        if (self.attach_error) |err|
            return err;
        var session = try ipc.egress_shared.createSessionForWorker(wake_set);
        const session_id = if (self.incomplete) 0 else first_session_id + self.attaches - 1;
        return fixture.egressAttachment(&session, gateway_generation, session_id);
    }

    fn currentGeneration(ctx: *anyopaque) u64 {
        const self: *FakeGateway = @ptrCast(@alignCast(ctx));
        return if (self.key_known) gateway_generation else 0;
    }

    fn keyFor(ctx: *anyopaque, generation: u64, out: *egress_token.Key) bool {
        const self: *FakeGateway = @ptrCast(@alignCast(ctx));
        self.key_asked_for = generation;
        if (!self.key_known or generation != gateway_generation)
            return false;
        out.* = gateway_key;
        return true;
    }

    fn prewarm(ctx: *anyopaque) anyerror!void {
        _ = ctx;
        return error.TestUnexpectedPrewarm;
    }

    fn bootEnded(ctx: *anyopaque, generation: u64, session_id: u64) bool {
        const self: *FakeGateway = @ptrCast(@alignCast(ctx));
        self.end_attempts += 1;
        self.ended_generation = generation;
        self.ended_session = session_id;
        return self.end_sent;
    }
};

/// Open descriptors of this process, counted from `/proc/self/fd` without
/// the one the count itself opens.
fn openFdCount() !usize {
    var dir = try std.fs.openDirAbsolute("/proc/self/fd", .{ .iterate = true });
    defer dir.close();
    var count: usize = 0;
    var iterator = dir.iterate();
    while (try iterator.next()) |_|
        count += 1;
    return count - 1;
}

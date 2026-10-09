//! The egress side of a launch as the supervisor prepares it
//! (`server/supervisor/worker_factory.zig`), against a gateway that stands
//! behind the supervisor's egress hooks on the test thread. A worker of a
//! definition with a grant gets a new session built on its wake set, and a
//! boot token grant beside it that names the session's gateway key, the one
//! entry of the policy table and the boot budget; once that gateway is no
//! longer current the session comes without a grant. A launch with no
//! gateway wired, a session the gateway hands back incomplete or an attach
//! that fails leaves nothing open. What the launcher does with the grant is
//! covered in `launcher.zig`. Lane `server-supervisor-test`.

const std = @import("std");
const ipc = @import("collo_ipc");
const lifecycle = @import("collo_server_lifecycle");
const egress_policy = @import("collo_egress_gateway").policy;
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
    try testing.expectEqual(egress_policy.public_https_id, boot.policy_id);
    try testing.expectEqual(@as(u32, egress_policy.production.max_fetches_per_boot), boot.budget);

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

    fn bootEnded(ctx: *anyopaque, generation: u64, session_id: u64) void {
        _ = ctx;
        _ = generation;
        _ = session_id;
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

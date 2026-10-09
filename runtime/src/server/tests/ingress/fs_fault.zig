//! The lane's answers on a worker's fault socket (`runner/fs_fault_control.zig`),
//! driven through a whole lane (`lane_harness.zig`). An authorized fault is
//! answered not found whatever its path, because every route shares the empty
//! placeholder index, and the identity check refuses the request-less boot
//! permit and a request id no request of the lane holds. No answer carries a
//! descriptor, and none takes the worker out of service; a fault request that
//! does not decode does, as a worker fault. Lane `server-ingress-test`; a
//! fault datagram carrying descriptors is in `worker_faults.zig`, and the
//! worker's side of the channel in `worker/tests/fs_fault.zig`.

const std = @import("std");
const ipc = @import("collo_ipc");
const lane_harness = @import("lane_harness.zig");

const OneWorker = lane_harness.OneWorker;

/// Sends one fault on the worker's fault socket, runs the lane's fault
/// handler and returns the answer the worker reads.
fn exchange(
    scene: *OneWorker,
    fault_id: u64,
    request_id: u64,
    request_generation: u64,
    path: []const u8,
) !ipc.fs_fault.ResponseWithFd {
    try scene.stub.sendFsFault(fault_id, request_id, request_generation, path);
    try scene.harness.handleFsFault(0, scene.stub);
    return scene.stub.readFsFaultAnswer();
}

test "an authorized fault is answered not found for any path, without a descriptor" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const request = try scene.get(1);

    const faults = [_]struct { id: u64, path: []const u8 }{
        .{ .id = 1, .path = "a/indexed.txt" },
        .{ .id = 2, .path = "b/absent.txt" },
    };
    const identity = request.identity;
    for (faults) |fs_fault| {
        var answer = try exchange(
            &scene,
            fs_fault.id,
            identity.request_id,
            identity.request_generation,
            fs_fault.path,
        );
        defer answer.deinit();
        try std.testing.expectEqual(ipc.FsFaultResponseStatus.not_found, answer.response.status);
        try std.testing.expectEqual(fs_fault.id, answer.response.fault_id);
        try std.testing.expect(answer.file_fd == null);
    }
    try scene.harness.expectLanesRunning();
    try scene.harness.expectServing(scene.stub);
}

test "the boot permit and a request id no request holds are refused, without a descriptor" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const request = try scene.get(1);

    // A lane reads a worker only once it is ready, so the request-less boot
    // identity 0/0 is refused.
    {
        var answer = try exchange(&scene, 4, 0, 0, "a/indexed.txt");
        defer answer.deinit();
        try std.testing.expectEqual(ipc.FsFaultResponseStatus.refused, answer.response.status);
        try std.testing.expectEqual(@as(u64, 4), answer.response.fault_id);
        try std.testing.expect(answer.file_fd == null);
    }

    // The worker's own identity with a request id no request of the lane
    // holds.
    {
        const unknown_request_id = request.identity.request_id + 1000;
        const generation = request.identity.request_generation;
        var answer = try exchange(&scene, 5, unknown_request_id, generation, "a/indexed.txt");
        defer answer.deinit();
        try std.testing.expectEqual(ipc.FsFaultResponseStatus.refused, answer.response.status);
        try std.testing.expectEqual(@as(u64, 5), answer.response.fault_id);
        try std.testing.expect(answer.file_fd == null);
    }
    try scene.harness.expectLanesRunning();
    try scene.harness.expectServing(scene.stub);
}

test "a fault request that does not decode faults its worker and the lane keeps serving" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    _ = try scene.get(1);

    // The message kind alone, too short for a fault request's header.
    var packet: [4]u8 = undefined;
    std.mem.writeInt(u32, &packet, @intFromEnum(ipc.MessageKind.fs_fault_request), .little);
    try ipc.packet.sendWithFds(scene.stub.fault, &packet, &.{});
    try scene.harness.handleFsFault(0, scene.stub);
    try scene.expectFaultAnswered(.fs_fault_request_undecodable);
}

//! The lane's generational connection and request slabs
//! (`ingress/state.zig`): stale keys and reused external ids are refused, and
//! slots release their descriptors and cold allocations. Lane:
//! server-ingress-test.

const std = @import("std");
const fd_helpers = @import("collo_os").fd;
const server_main = @import("collo_server_main");
const supervision = @import("collo_server_supervisor");

const ingress = server_main.ingress;
const lifecycle = server_main.lifecycle;

const ConnectionKey = ingress.state.ConnectionKey;
const ConnectionSlab = ingress.state.ConnectionSlab;
const LaneState = ingress.state.LaneState;
const LookupTag = ingress.state.LookupTag;
const RequestSlab = ingress.state.RequestSlab;
const RequestTerminalState = ingress.state.RequestTerminalState;
const SlabCounters = ingress.state.SlabCounters;
const WorkerKey = ingress.state.WorkerKey;

test "ingress generational slabs reject stale slots and external id reuse" {
    var counters = ingress.state.SlabCounters{};
    var requests = try ingress.state.RequestSlab.init(std.testing.allocator, 1, 1, &counters);
    defer requests.deinit();
    const conn = ingress.state.ConnectionKey{ .lane_id = 1, .slot = 0, .generation = 1 };
    const worker = ingress.state.WorkerKey{ .worker_id = 1, .worker_generation = 1 };

    const first = try requests.alloc(7, conn, worker, 0, 10);
    try std.testing.expectEqual(ingress.state.LookupTag.live, requests.release(first));
    const second = try requests.alloc(7, conn, worker, 0, 10);
    try std.testing.expect(first.generation != second.generation);
    try std.testing.expectError(error.StaleRequestGeneration, requests.completeByExternalId(first, 7));
    try std.testing.expectError(error.ExternalRequestIdMismatch, requests.completeByExternalId(second, 8));
}

test "the lane's keys are the lifecycle key types the pool hands back" {
    const key = lifecycle.WorkerKey{ .worker_id = 1, .worker_generation = 2 };
    const ingress_key: ingress.state.WorkerKey = key;
    try std.testing.expect(key.eql(ingress_key));
    try std.testing.expect(ingress.state.RequestKey == supervision.pool.RequestKey);
}

test "external request id reuse cannot affect lifecycle" {
    var counters = ingress.state.SlabCounters{};
    var requests = try ingress.state.RequestSlab.init(std.testing.allocator, 0, 1, &counters);
    defer requests.deinit();
    const conn = ingress.state.ConnectionKey{ .lane_id = 0, .slot = 0, .generation = 1 };
    const worker = ingress.state.WorkerKey{ .worker_id = 1, .worker_generation = 1 };
    const old = try requests.alloc(42, conn, worker, 0, 1);
    _ = requests.release(old);
    const new = try requests.alloc(42, conn, worker, 0, 1);
    try std.testing.expectError(error.StaleRequestGeneration, requests.completeByExternalId(old, 42));
    try requests.completeByExternalId(new, 42);
}

test "a reused request slot starts active under its new request and worker keys" {
    var counters = ingress.state.SlabCounters{};
    var requests = try ingress.state.RequestSlab.init(std.testing.allocator, 0, 1, &counters);
    defer requests.deinit();
    const conn = ingress.state.ConnectionKey{ .lane_id = 0, .slot = 0, .generation = 1 };
    const worker_a = ingress.state.WorkerKey{ .worker_id = 1, .worker_generation = 1 };
    const worker_b = ingress.state.WorkerKey{ .worker_id = 1, .worker_generation = 2 };

    const old = try requests.alloc(42, conn, worker_a, 0, 1);
    try std.testing.expect(requests.lookup(old).live.markTerminal(.completed_by_worker));
    _ = requests.release(old);
    const new = try requests.alloc(42, conn, worker_b, 0, 1);

    try std.testing.expect(old.generation != new.generation);
    try std.testing.expectEqual(ingress.state.RequestTerminalState.active, requests.lookup(new).live.terminal);
    try std.testing.expect(requests.lookup(new).live.worker_key.eql(worker_b));
}

test "closing a live connection closes its socket and counts the close" {
    var counters = ingress.state.SlabCounters{};
    var slab = try ingress.state.ConnectionSlab.init(std.testing.allocator, 0, 1, &counters);
    defer slab.deinit();
    const pair = try fd_helpers.socketPairType(std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(pair[1]);
    const key = try slab.alloc(fd_helpers.OwnedFd.fromRaw(pair[0]));
    try std.testing.expectEqual(ingress.state.LookupTag.live, slab.closeConnection(key));
    try std.testing.expectEqual(@as(u64, 1), counters.connection_close_calls);
    try std.testing.expectEqual(ingress.state.LookupTag.live, try slab.releaseConnectionSlot(key));
}

test "repeated accept and close leaks no descriptor" {
    const before = try fdCount();
    var counters = ingress.state.SlabCounters{};
    var slab = try ingress.state.ConnectionSlab.init(std.testing.allocator, 0, 1, &counters);
    defer slab.deinit();
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const pair = try fd_helpers.socketPairType(std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC);
        defer std.posix.close(pair[1]);
        const key = try slab.alloc(fd_helpers.OwnedFd.fromRaw(pair[0]));
        _ = slab.closeConnection(key);
        _ = try slab.releaseConnectionSlot(key);
    }
    const after = try fdCount();
    try std.testing.expectEqual(before, after);
}

fn fdCount() !usize {
    var dir = try std.fs.openDirAbsolute("/proc/self/fd", .{ .iterate = true });
    defer dir.close();
    var count: usize = 0;
    var it = dir.iterate();
    while (try it.next()) |_| count += 1;
    return count;
}
test "connection slab slot reuse rejects stale key" {
    var counters = SlabCounters{};
    var slab = try ConnectionSlab.init(std.testing.allocator, 2, 1, &counters);
    defer slab.deinit();

    const first = try slab.alloc(.{});
    try std.testing.expectEqual(LookupTag.live, try slab.releaseConnectionSlot(first));
    const second = try slab.alloc(.{});
    try std.testing.expectEqual(first.slot, second.slot);
    try std.testing.expect(second.generation != first.generation);
    try std.testing.expectEqual(LookupTag.stale_generation, std.meta.activeTag(slab.lookup(first)));
    try std.testing.expectEqual(@as(u64, 1), counters.connection_lookup_stale_generation);
}

test "request slab slot reuse rejects stale key and external id reuse" {
    var counters = SlabCounters{};
    var slab = try RequestSlab.init(std.testing.allocator, 3, 1, &counters);
    defer slab.deinit();

    const connection_key = ConnectionKey{ .lane_id = 3, .slot = 9, .generation = 1 };
    const worker_key = WorkerKey{ .worker_id = 4, .worker_generation = 5 };
    const first = try slab.alloc(77, connection_key, worker_key, 10, 20);
    try std.testing.expectEqual(LookupTag.live, slab.release(first));
    const second = try slab.alloc(77, connection_key, worker_key, 30, 40);
    try std.testing.expectEqual(first.slot, second.slot);
    try std.testing.expect(second.generation != first.generation);
    try std.testing.expectError(error.StaleRequestGeneration, slab.completeByExternalId(first, 77));
    try slab.completeByExternalId(second, 77);
    try std.testing.expectEqual(RequestTerminalState.completed_by_worker, slab.lookup(second).live.terminal);
}

test "LaneState slab counters remain valid after init return" {
    var state = try LaneState.init(std.testing.allocator, 4, 1, 1);
    defer state.deinit();

    const conn = try state.connections.alloc(.{});
    try std.testing.expectEqual(@as(u64, 1), state.counters.connection_allocations);
    try std.testing.expectEqual(LookupTag.live, try state.connections.releaseConnectionSlot(conn));

    const worker = WorkerKey{ .worker_id = 1, .worker_generation = 1 };
    const req = try state.requests.alloc(7, .{ .lane_id = 4, .slot = 0, .generation = 1 }, worker, 0, 10);
    try std.testing.expectEqual(@as(u64, 1), state.counters.request_allocations);
    try std.testing.expectEqual(LookupTag.live, state.requests.release(req));
}

test "release live connection slot with open fd fails in debug test mode" {
    var counters = SlabCounters{};
    var slab = try ConnectionSlab.init(std.testing.allocator, 1, 1, &counters);
    defer slab.deinit();

    const pair = try fd_helpers.socketPairType(std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(pair[1]);
    const key = try slab.alloc(fd_helpers.OwnedFd.fromRaw(pair[0]));
    try std.testing.expectError(error.ConnectionFdStillOpen, slab.releaseConnectionSlot(key));
    try std.testing.expectEqual(@as(u64, 1), counters.connection_release_fd_open_failures);
    try std.testing.expectEqual(LookupTag.live, slab.closeConnection(key));
    try std.testing.expectEqual(LookupTag.live, try slab.releaseConnectionSlot(key));
}

test "release live connection slot with terminal owner flag and open fd still fails" {
    var counters = SlabCounters{};
    var slab = try ConnectionSlab.init(std.testing.allocator, 1, 1, &counters);
    defer slab.deinit();

    const pair = try fd_helpers.socketPairType(std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(pair[1]);
    const key = try slab.alloc(fd_helpers.OwnedFd.fromRaw(pair[0]));
    slab.lookup(key).live.terminal_owner = true;
    try std.testing.expectError(error.ConnectionFdStillOpen, slab.releaseConnectionSlot(key));
    try std.testing.expectEqual(@as(u64, 1), counters.connection_release_fd_open_failures);
    try std.testing.expectEqual(LookupTag.live, slab.closeConnection(key));
    try std.testing.expectEqual(LookupTag.live, try slab.releaseConnectionSlot(key));
}

test "connection transfer to terminal owner clears slab fd before release" {
    var counters = SlabCounters{};
    var slab = try ConnectionSlab.init(std.testing.allocator, 1, 1, &counters);
    defer slab.deinit();

    const pair = try fd_helpers.socketPairType(std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(pair[1]);
    const key = try slab.alloc(fd_helpers.OwnedFd.fromRaw(pair[0]));
    var transferred_fd = try slab.transferConnectionToTerminalOwner(key);
    defer transferred_fd.deinit();
    try std.testing.expect(transferred_fd.isValid());
    try std.testing.expect(!slab.lookup(key).live.fd.isValid());
    try std.testing.expectEqual(LookupTag.live, try slab.releaseConnectionSlot(key));
}

test "request external id alone cannot complete another live request" {
    var counters = SlabCounters{};
    var slab = try RequestSlab.init(std.testing.allocator, 1, 2, &counters);
    defer slab.deinit();

    const connection_key = ConnectionKey{ .lane_id = 1, .slot = 0, .generation = 1 };
    const worker_key = WorkerKey{ .worker_id = 8, .worker_generation = 9 };
    const first = try slab.alloc(100, connection_key, worker_key, 0, 10);
    const second = try slab.alloc(100, connection_key, worker_key, 0, 10);
    try std.testing.expect(first.slot != second.slot);
    try std.testing.expectError(error.ExternalRequestIdMismatch, slab.completeByExternalId(second, 101));
    try std.testing.expectEqual(@as(u64, 1), counters.external_request_id_mismatch);
}

test "deinit releases cold allocations for live slots" {
    var counters = SlabCounters{};
    var connections = try ConnectionSlab.init(std.testing.allocator, 1, 1, &counters);
    var requests = try RequestSlab.init(std.testing.allocator, 1, 1, &counters);
    const conn = try connections.alloc(.{});
    const req = try requests.alloc(2, conn, .{ .worker_id = 3, .worker_generation = 4 }, 6, 7);
    try connections.attachColdDebug(conn, "connection debug");
    try requests.attachColdDebug(req, "request debug");
    requests.deinit();
    connections.deinit();
}

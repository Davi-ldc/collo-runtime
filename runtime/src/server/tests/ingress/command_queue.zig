//! The lane command queue (`ingress/commands.zig`): a command keeps its
//! payload through the queue, a full queue refuses a command and keeps the
//! ones it holds, and the queue's ordinary places and its reserve fill
//! apart: a reader's forwarded output takes only reserved places, a worker's
//! death and a reader grant take a reserved place first and an ordinary one
//! once the reserve is full, and every other command takes only ordinary
//! ones. A command the
//! queue refuses, abandons at teardown or cannot wake the lane for frees what
//! it owns. The queue writes only the places it used, and one eventfd wake
//! covers several commands. Lane `server-ingress-test`; what a lane does with
//! each command is tested in `lane_commands.zig`.

const std = @import("std");
const ipc = @import("collo_ipc");
const server_main = @import("collo_server_main");
const supervision = @import("collo_server_supervisor");
const command_queue_support = @import("../support/command_queue.zig");

const ingress = server_main.ingress;
const Command = ingress.commands.Command;
const Queue = ingress.commands.Queue;
const WorkerKey = ingress.lane_commands.WorkerKey;

fn workerDied(worker_key: WorkerKey) Command {
    return .{ .worker_died = .{ .worker_key = worker_key, .reason = .exited } };
}

/// A slot handed to a waiting request, with the reader grant that came with
/// it. The queue only carries the record's pointer.
fn dispatchReady(
    worker: *supervision.worker_table.Record,
    reader: supervision.pool.ReaderGrant,
) Command {
    return .{ .dispatch_ready = .{
        .request_key = .{ .lane_id = 0, .slot = 1, .generation = 1 },
        .worker_key = .{ .worker_id = 1, .worker_generation = 1 },
        .worker = worker,
        .slot = 0,
        .reader = reader,
    } };
}

/// The record a forwarded descriptor names. The queue only carries its
/// pointer.
var forwarding_record: supervision.worker_table.Record = .{
    .id = 1,
    .generation = 1,
    .definition_index = 0,
    .name = "forwarding",
    .handle = undefined,
};

/// A forwarded response chunk carrying `payload` inline, in a copy from `gpa`
/// that the command owns.
fn forwardedDescriptor(gpa: std.mem.Allocator, payload: []const u8) !Command {
    const bytes = try gpa.dupe(u8, payload);
    const identity = ipc.ingress_channel.RequestIdentity{
        .request_id = 9,
        .request_generation = 1,
        .request_lane_id = 0,
        .request_slot = 1,
    };
    const stream_id: u32 = 1;
    const end_stream = true;
    const descriptor = ipc.ingress_channel.Descriptor.responseChunk(
        identity,
        stream_id,
        0,
        @intCast(bytes.len),
        end_stream,
    );
    return .{ .forwarded_descriptor = .{
        .request_key = .{ .lane_id = 0, .slot = 1, .generation = 1 },
        .worker_key = .{ .worker_id = 1, .worker_generation = 1 },
        .worker = &forwarding_record,
        .reader_lane_id = 1,
        .descriptor = descriptor,
        .payload = .{ .inline_bytes = .{ .bytes = bytes, .allocator = gpa } },
    } };
}

test "a worker_died keeps its worker key and reason through the queue" {
    var queue = try Queue.init(2, 1);
    defer queue.deinit();

    const worker_key = WorkerKey{ .worker_id = 4, .worker_generation = 9 };
    try std.testing.expect(try queue.post(workerDied(worker_key)));

    const command = queue.dequeue() orelse return error.MissingCommand;
    try std.testing.expect(command.worker_died.worker_key.eql(worker_key));
    try std.testing.expectEqual(.exited, command.worker_died.reason);
}

test "a full queue refuses a command and keeps the ones it holds" {
    var queue = try Queue.init(1, 0);
    defer queue.deinit();

    try std.testing.expect(try queue.post(.shutdown));
    try std.testing.expect(!try queue.post(.shutdown));
    try std.testing.expectEqual(@as(u64, 1), queue.counters.refused_full);
    try std.testing.expectEqual(.shutdown, std.meta.activeTag(queue.dequeue().?));
    try std.testing.expect(queue.dequeue() == null);
}

test "deaths and reader grants fill a one-definition lane's reserve, which the other commands never reach" {
    const reserve = ingress.lane.obligationReserve(1);
    var queue = try Queue.init(1, reserve);
    defer queue.deinit();
    var record: supervision.worker_table.Record = .{
        .id = 1,
        .definition_index = 0,
        .name = "queued",
        .handle = undefined,
    };

    try std.testing.expect(try queue.post(.shutdown));
    try std.testing.expect(!try queue.post(.shutdown));
    // A handoff that does not make the lane the worker's reader can be
    // refused: its sender gives the slot back to the pool.
    try std.testing.expect(!try queue.post(dispatchReady(&record, .already)));
    try std.testing.expect(try queue.post(dispatchReady(&record, .{ .you_become_reader = 1 })));
    for (1..reserve) |worker_id| {
        const worker_key = WorkerKey{ .worker_id = worker_id, .worker_generation = 1 };
        try std.testing.expect(try queue.post(workerDied(worker_key)));
    }
    const past_reserve = WorkerKey{ .worker_id = reserve, .worker_generation = 1 };
    try std.testing.expect(!try queue.post(workerDied(past_reserve)));

    try std.testing.expectEqual(@as(u64, 3), queue.counters.refused_full);
    try std.testing.expectEqual(1 + reserve, queue.pending());
}

test "worker output never takes an ordinary place, a death takes one once the reserve is full, and ordinary commands never take a reserved one" {
    var queue = try Queue.init(2, 1);
    defer queue.deinit();

    try std.testing.expect(try queue.post(try forwardedDescriptor(std.testing.allocator, "first")));
    // The reserve is full; the free ordinary places do not take a reader's
    // forward, but they take a death.
    try std.testing.expect(!try queue.post(try forwardedDescriptor(std.testing.allocator, "second")));
    try std.testing.expect(try queue.post(.shutdown));
    try std.testing.expect(try queue.post(workerDied(.{ .worker_id = 2, .worker_generation = 1 })));
    try std.testing.expectEqual(@as(usize, 1), queue.reserved_used);
    try std.testing.expectEqual(@as(usize, 2), queue.ordinary_used);
    try std.testing.expect(!try queue.post(workerDied(.{ .worker_id = 3, .worker_generation = 1 })));
    try std.testing.expect(!try queue.post(.shutdown));
    try std.testing.expectEqual(@as(u64, 3), queue.counters.refused_full);

    // A place freed by a dequeue goes back to its own kind.
    var first = queue.dequeue() orelse return error.MissingCommand;
    first.deinit();
    try std.testing.expect(!try queue.post(.shutdown));
    try std.testing.expect(try queue.post(workerDied(.{ .worker_id = 4, .worker_generation = 1 })));
    try std.testing.expectEqual(@as(usize, 1), queue.reserved_used);
}

test "a death takes a reserved place before an ordinary one, leaving the ordinary places to the commands that can take nothing else" {
    var queue = try Queue.init(1, 1);
    defer queue.deinit();

    try std.testing.expect(try queue.post(workerDied(.{ .worker_id = 1, .worker_generation = 1 })));
    try std.testing.expectEqual(@as(usize, 1), queue.reserved_used);
    try std.testing.expectEqual(@as(usize, 0), queue.ordinary_used);
    try std.testing.expect(try queue.post(.shutdown));
}

test "a queue torn down with a forwarded descriptor in it frees the descriptor's inline bytes" {
    var queue = try Queue.init(1, 1);
    defer queue.deinit();

    // `std.testing.allocator` fails the test if the bytes outlive the queue.
    try std.testing.expect(try queue.post(try forwardedDescriptor(std.testing.allocator, "queued")));
}

test "a post the full queue refuses frees what the command owns" {
    var queue = try Queue.init(1, 0);
    defer queue.deinit();

    try std.testing.expect(!try queue.post(try forwardedDescriptor(std.testing.allocator, "refused")));
}

test "a queue writes only the places it used, whatever its capacity" {
    var queue = try Queue.init(4096, 4096);
    defer queue.deinit();

    try std.testing.expect(try queue.post(workerDied(.{ .worker_id = 7, .worker_generation = 8 })));
    try std.testing.expect(try queue.post(.shutdown));
    try std.testing.expectEqual(@as(u32, 2), queue.nodes.high_water);

    // A place freed and taken again is the one written last.
    var command = queue.dequeue() orelse return error.MissingCommand;
    command.deinit();
    try std.testing.expect(try queue.post(.shutdown));
    try std.testing.expectEqual(@as(u32, 2), queue.nodes.high_water);
}

test "a dequeue leaves the place it took empty" {
    var queue = try Queue.init(1, 0);
    defer queue.deinit();

    try std.testing.expect(try queue.post(.shutdown));
    const command = queue.dequeue() orelse return error.MissingCommand;
    try std.testing.expectEqual(.shutdown, std.meta.activeTag(command));
    try std.testing.expectEqual(.empty, std.meta.activeTag(queue.nodes.entries[0].command));
}

test "one eventfd wake covers several commands" {
    var queue = try Queue.init(2, 1);
    defer queue.deinit();

    try std.testing.expect(try queue.post(.shutdown));
    try std.testing.expect(try queue.post(workerDied(.{ .worker_id = 1, .worker_generation = 1 })));
    try std.testing.expectEqual(@as(u64, 2), try queue.drainWake());
    try std.testing.expect(queue.dequeue() != null);
    try std.testing.expect(queue.dequeue() != null);
    try std.testing.expectEqual(@as(u64, 1), queue.counters.eventfd_wakes);
}

test "a post whose wake cannot be written fails, queues nothing and frees what the command owns" {
    var queue = try Queue.init(2, 1);
    defer queue.deinit();

    command_queue_support.closeCommandEventFd(&queue);
    try std.testing.expectError(
        error.CommandEventfdCorrupt,
        queue.post(try forwardedDescriptor(std.testing.allocator, "unwoken")),
    );
    try std.testing.expectEqual(@as(usize, 0), queue.pending());
    try std.testing.expectEqual(@as(u64, 1), queue.counters.eventfd_signal_failures);
}

//! The lane's ready queues (`server/ingress/runner/work_queues.zig`): a
//! connection and a worker registration each wait on their queue at most
//! once, also when the item is reset while its entry waits, so a queue with
//! one entry per item never fills. Lane `server-ingress-test`; the loop pass
//! that drains both runs through `lane_harness.zig`.

const std = @import("std");
const ingress = @import("collo_server_main").ingress;

const connection_slot = ingress.runner.connection_slot;
const work_queues = ingress.runner.work_queues;
const Registration = ingress.completions.Registration;

const slot_count: usize = 4;
const registration_count: usize = 3;

/// What `work_queues.Methods` reads of a lane.
const Lane = struct {
    connection_slots: []connection_slot.Slot,
    ready_connections: work_queues.ReadyQueue,
    completion_registrations: [registration_count]Registration = @splat(.{}),
    completion_registration_count: usize = registration_count,
    ready_death_regs: work_queues.DeathQueue(registration_count) = .{},

    /// Every connection slot active, with a ready queue of one entry per
    /// slot, as `ring_driver.initRuntime` sizes it.
    fn init(self: *Lane) !void {
        const slots = try std.testing.allocator.alloc(connection_slot.Slot, slot_count);
        errdefer std.testing.allocator.free(slots);
        @memset(slots, .{ .active = true });
        self.* = .{
            .connection_slots = slots,
            .ready_connections = try work_queues.ReadyQueue.init(std.testing.allocator, slot_count),
        };
    }

    fn deinit(self: *Lane) void {
        self.ready_connections.deinit(std.testing.allocator);
        std.testing.allocator.free(self.connection_slots);
    }
};

const Queues = work_queues.Methods(Lane);

test "a connection waits for a turn once, also when its slot takes a new connection while the entry waits" {
    var lane: Lane = undefined;
    try lane.init();
    defer lane.deinit();

    Queues.enqueueConnection(&lane, 1);
    Queues.enqueueConnection(&lane, 1);
    try std.testing.expectEqual(@as(usize, 1), lane.ready_connections.len);

    // The connection closes and the next accept takes its slot, keeping the
    // flag of the entry that still waits (`accept_flow.startConnection`).
    const queued = lane.connection_slots[1].queued;
    lane.connection_slots[1] = .{ .active = true, .queued = queued };
    Queues.enqueueConnection(&lane, 1);
    try std.testing.expectEqual(@as(usize, 1), lane.ready_connections.len);

    // Every slot fits at once, which is the queue's whole capacity.
    for (0..slot_count) |slot|
        Queues.enqueueConnection(&lane, @intCast(slot));
    try std.testing.expectEqual(slot_count, lane.ready_connections.len);

    // The pop clears the flag, so the slot may wait again.
    try std.testing.expectEqual(@as(?u32, 1), Queues.popConnection(&lane));
    try std.testing.expect(!lane.connection_slots[1].queued);
    Queues.enqueueConnection(&lane, 1);
    try std.testing.expectEqual(slot_count, lane.ready_connections.len);
}

test "a vacant connection slot is never queued" {
    var lane: Lane = undefined;
    try lane.init();
    defer lane.deinit();

    lane.connection_slots[2].active = false;
    Queues.enqueueConnection(&lane, 2);
    try std.testing.expectEqual(@as(usize, 0), lane.ready_connections.len);
    try std.testing.expect(!lane.connection_slots[2].queued);
}

test "a worker fault waits once per registration, and an index past the registrations is a lane fault" {
    var lane: Lane = undefined;
    try lane.init();
    defer lane.deinit();

    try Queues.enqueueDeath(&lane, 2);
    try Queues.enqueueDeath(&lane, 2);
    try std.testing.expectEqual(@as(usize, 1), lane.ready_death_regs.len);
    for (0..registration_count) |index|
        try Queues.enqueueDeath(&lane, @intCast(index));
    try std.testing.expectEqual(registration_count, lane.ready_death_regs.len);
    try std.testing.expectError(error.InvalidCompletionRegistration, Queues.enqueueDeath(&lane, registration_count));

    try std.testing.expectEqual(@as(?u32, 2), Queues.popDeath(&lane));
    try std.testing.expect(!lane.completion_registrations[2].death_queued);
    try Queues.enqueueDeath(&lane, 2);
    try std.testing.expectEqual(registration_count, lane.ready_death_regs.len);
}

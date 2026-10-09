//! The lane's ready queues (`server/ingress/runner/work_queues.zig`): a
//! connection and a worker registration each wait on their queue at most
//! once, also when the slot is released and taken by a new connection while
//! its place waits, so a queue threaded through its slab never fills. Lane
//! `server-ingress-test`; the loop pass that drains both runs through
//! `lane_harness.zig`.

const std = @import("std");
const ingress = @import("collo_server_main").ingress;

const connection_slot = ingress.runner.connection_slot;
const completions = ingress.completions;
const work_queues = ingress.runner.work_queues;

const slot_count: u32 = 4;
const registration_count: u32 = 3;

/// What `work_queues.Methods` reads of a lane.
const Lane = struct {
    connections: connection_slot.ConnectionSlab,
    ready_connections: connection_slot.ReadyQueue = .{},
    registrations: completions.RegistrationSlab,
    deferred_deaths: completions.DeathQueue = .{},

    /// Every connection slot and registration handed out.
    fn init(self: *Lane) !void {
        self.* = .{
            .connections = try connection_slot.ConnectionSlab.init(slot_count),
            .registrations = undefined,
        };
        errdefer self.connections.deinit();
        self.registrations = try completions.RegistrationSlab.init(registration_count);
        for (0..slot_count) |_|
            _ = self.connections.acquire().?;
        for (0..registration_count) |_|
            _ = self.registrations.acquire().?;
    }

    fn deinit(self: *Lane) void {
        self.registrations.deinit();
        self.connections.deinit();
    }
};

const Queues = work_queues.Methods(Lane);

test "a connection waits for a turn once, also when its slot takes a new connection while the place waits" {
    var lane: Lane = undefined;
    try lane.init();
    defer lane.deinit();

    Queues.enqueueConnection(&lane, 1);
    Queues.enqueueConnection(&lane, 1);
    try std.testing.expectEqual(@as(u32, 1), lane.ready_connections.len);

    // The connection closes and the next accept takes its slot; the place
    // keeps waiting, once.
    lane.connections.release(1);
    try std.testing.expectEqual(@as(u32, 1), lane.connections.acquire().?.index);
    Queues.enqueueConnection(&lane, 1);
    try std.testing.expectEqual(@as(u32, 1), lane.ready_connections.len);

    // Every slot fits at once.
    for (0..slot_count) |slot|
        Queues.enqueueConnection(&lane, @intCast(slot));
    try std.testing.expectEqual(slot_count, lane.ready_connections.len);

    // The pop clears the membership, so the slot may wait again.
    try std.testing.expectEqual(@as(?u32, 1), Queues.popConnection(&lane));
    try std.testing.expect(!lane.connections.entries[1].slab_link.queued);
    Queues.enqueueConnection(&lane, 1);
    try std.testing.expectEqual(slot_count, lane.ready_connections.len);
}

test "a vacant connection slot is never queued, and a place freed while it waits pops as vacant" {
    var lane: Lane = undefined;
    try lane.init();
    defer lane.deinit();

    lane.connections.release(2);
    Queues.enqueueConnection(&lane, 2);
    try std.testing.expectEqual(@as(u32, 0), lane.ready_connections.len);
    try std.testing.expect(!lane.connections.entries[2].slab_link.queued);

    Queues.enqueueConnection(&lane, 3);
    lane.connections.release(3);
    try std.testing.expectEqual(@as(?u32, 3), Queues.popConnection(&lane));
    try std.testing.expect(lane.connections.get(3) == null);
}

test "a worker fault waits once per registration, and an index past the registrations is a lane fault" {
    var lane: Lane = undefined;
    try lane.init();
    defer lane.deinit();

    try Queues.enqueueDeath(&lane, 2);
    try Queues.enqueueDeath(&lane, 2);
    try std.testing.expectEqual(@as(u32, 1), lane.deferred_deaths.len);
    try std.testing.expect(Queues.deathQueued(&lane, 2));
    for (0..registration_count) |index|
        try Queues.enqueueDeath(&lane, @intCast(index));
    try std.testing.expectEqual(registration_count, lane.deferred_deaths.len);
    try std.testing.expectError(error.InvalidCompletionRegistration, Queues.enqueueDeath(&lane, registration_count));

    try std.testing.expectEqual(@as(?u32, 2), Queues.popDeath(&lane));
    try std.testing.expect(!Queues.deathQueued(&lane, 2));
    try Queues.enqueueDeath(&lane, 2);
    try std.testing.expectEqual(registration_count, lane.deferred_deaths.len);
}

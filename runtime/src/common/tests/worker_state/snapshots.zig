//! The host's snapshots of a worker's page (`common/worker_state/page/snapshots.zig`), taken
//! through its `HostReaderView`: a live slot read at its pool slot, its request id and generation
//! matched on the copy the caller keeps, the lifecycle tags converted only when their enums name
//! them, the startup-end flag read as ended only at 1, the owner section's pairs, and the running
//! owner's refused while its sequence is odd. The server's use of them, the floor of a request the
//! server ended, is covered by the server-supervisor lane.

const std = @import("std");
const page = @import("collo_worker_state").page;

/// A page memfd mapped once by the worker and once by the host.
const MappedPage = struct {
    fd: std.posix.fd_t,
    worker: page.WorkerWriterView,
    host: page.HostReaderView,

    fn init(self: *MappedPage, name: []const u8) !void {
        self.fd = try page.createMemfd(name);
        errdefer std.posix.close(self.fd);
        self.worker = try page.mapWorkerWriter(self.fd);
        errdefer self.worker.deinit();
        self.host = try page.mapHostReader(self.fd);
    }

    fn deinit(self: *MappedPage) void {
        self.host.deinit();
        self.worker.deinit();
        std.posix.close(self.fd);
    }
};

/// Writes a live slot by hand, as a worker that breaks the writers' order
/// or values could.
fn writeSlot(view: *page.WorkerWriterView, index: usize, request_id: u64, request_generation: u64, cpu_ns: u64) void {
    view.page.live_slots[index] = .{
        .request_id = request_id,
        .request_generation = request_generation,
        .cpu_ns = cpu_ns,
    };
}

test "a live slot no request was begun on names no request and matches none" {
    var mapped: MappedPage = undefined;
    try mapped.init("snapshot-live-slot-untouched");
    defer mapped.deinit();

    for (0..page.LIVE_SLOT_COUNT) |index| {
        const snapshot = mapped.host.loadLiveSlot(index);
        try std.testing.expectEqual(@as(u64, 0), snapshot.request_id);
        try std.testing.expectEqual(@as(u64, 0), snapshot.request_generation);
        try std.testing.expectEqual(@as(u64, 0), snapshot.cpu_ns);
        // The host's request ids are never 0, so even a zero generation
        // matches nothing here.
        try std.testing.expect(!snapshot.matches(1, 0));
    }
}

test "a live slot matches on its request id and generation alone, as the worker wrote them" {
    var mapped: MappedPage = undefined;
    try mapped.init("snapshot-live-slot-identity-only");
    defer mapped.deinit();

    // A worker can write any identity by hand; the copy matches the request
    // it names, whose record is that worker's own.
    writeSlot(&mapped.worker, 5, 41, 3, 250);
    const snapshot = mapped.host.loadLiveSlot(5);
    try std.testing.expect(snapshot.matches(41, 3));
    try std.testing.expectEqual(@as(u64, 250), snapshot.cpu_ns);
    try std.testing.expect(!snapshot.matches(41, 2));
    try std.testing.expect(!snapshot.matches(42, 3));
}

test "a live slot snapshot refuses a stale generation or another request id, and keeps what it copied" {
    var mapped: MappedPage = undefined;
    try mapped.init("snapshot-live-slot-identity");
    defer mapped.deinit();

    mapped.worker.beginLiveSlot(7, 41, 3);
    mapped.worker.storeLiveSlotCpu(7, 41, 250);
    const snapshot = mapped.host.loadLiveSlot(7);
    try std.testing.expect(snapshot.matches(41, 3));
    // Another generation or another request id matches nothing, and neither
    // does another pool slot.
    try std.testing.expect(!snapshot.matches(41, 2));
    try std.testing.expect(!snapshot.matches(41, 4));
    try std.testing.expect(!snapshot.matches(40, 3));
    try std.testing.expect(!mapped.host.loadLiveSlot(6).matches(41, 3));

    // The worker rewrites the slot after the load; the copy is unchanged.
    writeSlot(&mapped.worker, 7, 999, 3, 1 << 40);
    try std.testing.expect(snapshot.matches(41, 3));
    try std.testing.expectEqual(@as(u64, 250), snapshot.cpu_ns);
}

test "a lifecycle tag outside its enum reads as null" {
    var header = std.mem.zeroes(page.Header);
    header.state = @intFromEnum(page.State.dead);
    header.termination_reason = @intFromEnum(page.TerminationReason.memory);
    const known = page.LifecycleSnapshot.load(&header);
    try std.testing.expectEqual(page.State.dead, known.knownState().?);
    try std.testing.expectEqual(page.TerminationReason.memory, known.knownTerminationReason().?);

    header.termination_reason = @intFromEnum(page.TerminationReason.sentinel);
    try std.testing.expectEqual(page.TerminationReason.sentinel, page.LifecycleSnapshot.load(&header).knownTerminationReason().?);

    header.state = 0;
    header.termination_reason = 7;
    const unknown = page.LifecycleSnapshot.load(&header);
    try std.testing.expect(unknown.knownState() == null);
    try std.testing.expect(unknown.knownTerminationReason() == null);
    try std.testing.expectEqual(@as(u32, 7), unknown.termination_reason);

    // 4 names no reason.
    header.termination_reason = 4;
    try std.testing.expect(page.LifecycleSnapshot.load(&header).knownTerminationReason() == null);

    header.termination_reason = std.math.maxInt(u32);
    try std.testing.expect(page.LifecycleSnapshot.load(&header).knownTerminationReason() == null);
}

test "the startup-end flag reads as ended at 1 and at no other value" {
    var mapped: MappedPage = undefined;
    try mapped.init("startup-completion-snapshot");
    defer mapped.deinit();
    try std.testing.expect(!mapped.host.loadLifecycle().startupEnded());
    mapped.worker.publishStartupEvaluationsEnded();
    try std.testing.expect(mapped.host.loadLifecycle().startupEnded());
    for ([_]u32{ 0, 2, std.math.maxInt(u32) }) |value| {
        @atomicStore(u32, &mapped.worker.header.startup_evaluations_ended, value, .release);
        try std.testing.expect(!mapped.host.loadLifecycle().startupEnded());
    }
}

test "the host's view reads the owner section the worker publishes" {
    var mapped: MappedPage = undefined;
    try mapped.init("owner-sections-through-host-view");
    defer mapped.deinit();

    try std.testing.expect(mapped.host.loadRunningOwner() == null);
    mapped.worker.publishOwner(41, 9_000);
    mapped.worker.publishRunningOwnerCpu(41, 700);
    const owner = mapped.host.loadOwner();
    try std.testing.expectEqual(@as(u64, 41), owner.owner_id);
    try std.testing.expectEqual(@as(u64, 9_000), owner.deadline_mono_ns);
    const running = mapped.host.loadRunningOwner() orelse return error.TestExpectedRunningOwner;
    try std.testing.expectEqual(@as(u64, 41), running.owner_id);
    try std.testing.expectEqual(@as(u64, 700), running.cpu_ns);
}

test "a running owner load refuses a pair the sentinel is still storing, and a pair that names no owner" {
    var header = std.mem.zeroes(page.Header);
    header.running_owner_id = 41;
    header.running_owner_cpu_ns = 100;

    // Odd: the sentinel is between its two stores.
    header.running_owner_sequence = 3;
    try std.testing.expect(page.RunningOwnerSnapshot.load(&header) == null);
    header.running_owner_sequence = std.math.maxInt(u32);
    try std.testing.expect(page.RunningOwnerSnapshot.load(&header) == null);

    header.running_owner_sequence = 2;
    const stable = page.RunningOwnerSnapshot.load(&header) orelse return error.TestExpectedRunningOwner;
    try std.testing.expectEqual(@as(u64, 41), stable.owner_id);
    try std.testing.expectEqual(@as(u64, 100), stable.cpu_ns);

    // A pair under owner id 0 names no owner.
    header.running_owner_id = 0;
    try std.testing.expect(page.RunningOwnerSnapshot.load(&header) == null);
}

test "the owner snapshot keeps the raw id and deadline the page holds" {
    var header = std.mem.zeroes(page.Header);
    const idle = page.OwnerSnapshot.load(&header);
    try std.testing.expectEqual(@as(u64, 0), idle.owner_id);
    try std.testing.expectEqual(@as(u64, 0), idle.deadline_mono_ns);

    header.owner_id = std.math.maxInt(u64);
    header.owner_deadline_mono_ns = 12_345;
    const owned = page.OwnerSnapshot.load(&header);
    // The copy keeps what it loaded after the worker rewrites the page.
    header.owner_deadline_mono_ns = 0;
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), owned.owner_id);
    try std.testing.expectEqual(@as(u64, 12_345), owned.deadline_mono_ns);
}

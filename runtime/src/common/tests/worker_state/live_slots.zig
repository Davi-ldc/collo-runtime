//! The worker's writes to its live slots (`WorkerWriterView.beginLiveSlot`
//! and `storeLiveSlotCpu` in `common/worker_state/page/mapping.zig`) read
//! back through the host's `HostReaderView.loadLiveSlot`: a request's slot
//! sits at the pool slot its dispatch names, every pool slot has its own, a
//! slot keeps the last request begun on it with that request's last CPU
//! until the next begin, and a request's store after a later begin on its
//! pool slot changes nothing. The snapshot's own refusals are covered in
//! `snapshots.zig`.

const std = @import("std");
const page = @import("collo_worker_state").page;

/// A page memfd mapped once by the worker and once by the host.
const TwoViews = struct {
    fd: std.posix.fd_t,
    host: page.HostReaderView,
    worker: page.WorkerWriterView,

    fn init(self: *TwoViews, name: []const u8) !void {
        self.fd = try page.createMemfd(name);
        errdefer std.posix.close(self.fd);
        self.host = try page.mapHostReader(self.fd);
        errdefer self.host.deinit();
        self.worker = try page.mapWorkerWriter(self.fd);
    }

    fn deinit(self: *TwoViews) void {
        self.worker.deinit();
        self.host.deinit();
        std.posix.close(self.fd);
    }
};

test "a dispatched request writes its live slot at its pool slot and no other" {
    var views: TwoViews = undefined;
    try views.init("live-slot-at-pool-slot");
    defer views.deinit();

    views.worker.beginLiveSlot(3, 41, 7);
    const begun = views.host.loadLiveSlot(3);
    try std.testing.expect(begun.matches(41, 7));
    try std.testing.expectEqual(@as(u64, 0), begun.cpu_ns);

    views.worker.storeLiveSlotCpu(3, 41, 1_500);
    try std.testing.expectEqual(@as(u64, 1_500), views.host.loadLiveSlot(3).cpu_ns);

    // Every other slot still names no request.
    for (0..page.LIVE_SLOT_COUNT) |index| {
        if (index == 3)
            continue;
        const other = views.host.loadLiveSlot(index);
        try std.testing.expectEqual(@as(u64, 0), other.request_id);
        try std.testing.expect(!other.matches(41, 7));
    }
}

test "a finished request keeps its live slot and its last CPU until the next begin on its pool slot" {
    var views: TwoViews = undefined;
    try views.init("live-slot-kept-after-finish");
    defer views.deinit();

    // The worker finishes request 41 and sends its `request_done`; nothing
    // in the protocol touches the slot, so a host that reads it before it
    // gives the pool slot back still finds the request and its CPU.
    views.worker.beginLiveSlot(3, 41, 7);
    views.worker.storeLiveSlotCpu(3, 41, 1_500);
    const finished = views.host.loadLiveSlot(3);
    try std.testing.expect(finished.matches(41, 7));
    try std.testing.expectEqual(@as(u64, 1_500), finished.cpu_ns);

    // The next request on the pool slot replaces it, with no CPU yet.
    views.worker.beginLiveSlot(3, 42, 8);
    const next = views.host.loadLiveSlot(3);
    try std.testing.expect(next.matches(42, 8));
    try std.testing.expect(!next.matches(41, 7));
    try std.testing.expectEqual(@as(u64, 0), next.cpu_ns);
}

test "every pool slot has a live slot of its own, the last one included" {
    var views: TwoViews = undefined;
    try views.init("live-slot-every-pool-slot");
    defer views.deinit();

    for (0..page.LIVE_SLOT_COUNT) |index| {
        const request_id: u64 = 100 + index;
        views.worker.beginLiveSlot(index, request_id, 1);
        views.worker.storeLiveSlotCpu(index, request_id, index * 10);
    }
    for (0..page.LIVE_SLOT_COUNT) |index| {
        const snapshot = views.host.loadLiveSlot(index);
        try std.testing.expect(snapshot.matches(100 + index, 1));
        try std.testing.expectEqual(@as(u64, index * 10), snapshot.cpu_ns);
    }
}

test "a request's CPU store after a later begin on its pool slot changes nothing" {
    var views: TwoViews = undefined;
    try views.init("live-slot-reused-pool-slot");
    defer views.deinit();

    views.worker.beginLiveSlot(2, 41, 7);
    views.worker.storeLiveSlotCpu(2, 41, 900);
    views.worker.beginLiveSlot(2, 42, 8);
    views.worker.storeLiveSlotCpu(2, 41, 5_000);
    const kept = views.host.loadLiveSlot(2);
    try std.testing.expect(kept.matches(42, 8));
    try std.testing.expectEqual(@as(u64, 0), kept.cpu_ns);

    views.worker.storeLiveSlotCpu(2, 42, 60);
    try std.testing.expectEqual(@as(u64, 60), views.host.loadLiveSlot(2).cpu_ns);
}

test "a live slot is 24 bytes and every one of them fits the page's first 4 KiB with room for 64" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(page.LiveRequestSlot));
    try std.testing.expectEqual(@as(usize, 56), @offsetOf(page.Page, "live_slots"));
    const live_slots_end = @offsetOf(page.Page, "live_slots") + @sizeOf(@FieldType(page.Page, "live_slots"));
    try std.testing.expect(live_slots_end <= 4096);
    try std.testing.expect(@offsetOf(page.Page, "live_slots") +
        page.live_slot_count_page_zero_max * @sizeOf(page.LiveRequestSlot) <= 4096);
}

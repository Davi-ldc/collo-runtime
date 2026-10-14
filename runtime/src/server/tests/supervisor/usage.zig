//! The server's side of what a dispatched request used: the worker's request
//! table, which lets a descriptor or a `request_done` through only for a
//! request in flight under its own key, lets nothing of a request through
//! once its `request_done` went on, and names the route of a console line's
//! request; and the usage floor a lane takes for a request it ended without
//! the worker's `request_done`, which reads only the live slot at the
//! request's pool slot while that slot holds the request, and the running
//! window only when it names the request. The access line these measures
//! enter, its format and its bound are covered in
//! `server/tests/analytics/access.zig`, and the lane that fills it in
//! `server/tests/ingress/`. Lane `server-supervisor-test`.

const std = @import("std");
const config = @import("collo_server_config");
const lifecycle = @import("collo_server_lifecycle");
const supervision = @import("collo_server_supervisor");
const access = @import("collo_server_analytics").access;
const worker_shared_page = @import("collo_worker_state").page;
const fixture = @import("supervisor_fixture");

const request_table = supervision.request_table;
const worker_table = supervision.worker_table;
const WorkerRecord = worker_table.Record;
const Origin = access.Origin;

/// A shared page the test writes live slots and the running window into, the
/// way a worker would, and the host's mapping of it, which the record reads.
const Page = struct {
    fd: std.posix.fd_t,
    writer: worker_shared_page.WorkerWriterView,
    reader: worker_shared_page.HostReaderView,

    fn init(self: *Page, name: []const u8) !void {
        self.fd = try worker_shared_page.createMemfd(name);
        errdefer std.posix.close(self.fd);
        self.writer = try worker_shared_page.mapWorkerWriter(self.fd);
        errdefer self.writer.deinit();
        self.reader = try worker_shared_page.mapHostReader(self.fd);
    }

    fn deinit(self: *Page) void {
        self.reader.deinit();
        self.writer.deinit();
        std.posix.close(self.fd);
    }

    /// The live slot at `index` holds `request` and has charged it `cpu_ns`.
    fn charge(self: *Page, index: usize, request: worker_table.LiveRequest, cpu_ns: u64) void {
        self.writer.beginLiveSlot(index, request.request_id, request.request_generation);
        self.writer.storeLiveSlotCpu(index, request.request_id, cpu_ns);
    }
};

/// A stack worker record of definition 0 whose page is `page`.
fn stackWorker(page: *Page) WorkerRecord {
    var worker = fixture.stackWorker(9, 2, 0);
    worker.handle.metrics = page.reader;
    worker.page_mapped = true;
    return worker;
}

test "a descriptor goes on only for a request in flight under its own key, until the request's request_done went on" {
    var table = request_table.RequestTable{};
    const dispatched = fixture.dispatchedRequest(40);
    try table.record(dispatched);
    var rewritten = dispatched.request_key;
    rewritten.generation += 1;

    // A request the worker was never dispatched goes nowhere, and an identity
    // rewritten onto a request it was dispatched is the worker's fault.
    try std.testing.expectEqual(request_table.ForwardCheck.absent, table.forwardCheck(41, dispatched.request_key));
    try std.testing.expectEqual(request_table.ForwardCheck.mismatch, table.forwardCheck(40, rewritten));

    // The request's output goes on as often as the worker sends it. A mark
    // under a rewritten key or another id marks nothing.
    try std.testing.expectEqual(request_table.ForwardCheck.live, table.forwardCheck(40, dispatched.request_key));
    table.markDoneForwarded(40, rewritten);
    table.markDoneForwarded(41, dispatched.request_key);
    try std.testing.expectEqual(request_table.ForwardCheck.live, table.forwardCheck(40, dispatched.request_key));

    // Once its `request_done` went on, nothing of the request does, and the
    // rewritten identity is still the worker's fault.
    table.markDoneForwarded(40, dispatched.request_key);
    try std.testing.expectEqual(request_table.ForwardCheck.absent, table.forwardCheck(40, dispatched.request_key));
    try std.testing.expectEqual(request_table.ForwardCheck.mismatch, table.forwardCheck(40, rewritten));

    // Once the lane ends the request, every descriptor naming it is stale,
    // and a mark that comes after finds nothing to mark.
    table.end(40);
    table.markDoneForwarded(40, dispatched.request_key);
    try std.testing.expectEqual(request_table.ForwardCheck.absent, table.forwardCheck(40, dispatched.request_key));
}

test "a request id the worker writes as 0 names no entry, free or held" {
    var table = request_table.RequestTable{};
    try table.record(fixture.dispatchedRequest(1));
    // A free entry holds request id 0 under an all-zero key.
    const zero_key: lifecycle.RequestKey = .{ .lane_id = 0, .slot = 0, .generation = 0 };
    try std.testing.expectEqual(request_table.ForwardCheck.absent, table.forwardCheck(0, zero_key));
    try std.testing.expectEqual(request_table.ForwardCheck.absent, table.forwardCheck(0, fixture.dispatchedRequest(1).request_key));
    table.markDoneForwarded(0, zero_key);
    try std.testing.expectEqual(request_table.ForwardCheck.live, table.forwardCheck(1, fixture.dispatchedRequest(1).request_key));
    try std.testing.expectEqual(@as(?config.RouteIndex, null), table.routeOfRecent(0));
}

test "a worker's table holds one entry per request it can have in flight and refuses one more rather than overwrite an entry" {
    var table = request_table.RequestTable{};
    var request_id: u64 = 1;
    while (request_id <= request_table.entries_max) : (request_id += 1)
        try table.record(fixture.dispatchedRequest(request_id));
    try std.testing.expectError(error.RequestTableFull, table.record(fixture.dispatchedRequest(request_id)));
    // Every entry still names its own request.
    request_id = 1;
    while (request_id <= request_table.entries_max) : (request_id += 1) {
        const key = fixture.dispatchedRequest(request_id).request_key;
        try std.testing.expectEqual(request_table.ForwardCheck.live, table.forwardCheck(request_id, key));
    }
    // A request that ends frees its entry for the next dispatch.
    table.end(1);
    try table.record(fixture.dispatchedRequest(request_id));
}

test "a request table names the route of a request it holds or that ended recently, and of no other" {
    var table = request_table.RequestTable{};
    var routed = fixture.dispatchedRequest(5);
    routed.route = 3;
    try table.record(routed);
    try std.testing.expectEqual(@as(?config.RouteIndex, 3), table.routeOfRecent(5));
    try std.testing.expectEqual(@as(?config.RouteIndex, null), table.routeOfRecent(6));

    // A request that ended after its begin reached the worker leaves its
    // route behind; one whose begin never did leaves nothing, since that
    // worker has no request to name.
    table.end(5);
    try std.testing.expectEqual(@as(?config.RouteIndex, 3), table.routeOfRecent(5));
    try table.record(fixture.dispatchedRequest(7));
    table.remove(7);
    try std.testing.expectEqual(@as(?config.RouteIndex, null), table.routeOfRecent(7));

    // The ring keeps the last `ended_requests_max` requests.
    var request_id: u64 = 100;
    while (request_id < 100 + request_table.ended_requests_max) : (request_id += 1) {
        try table.record(fixture.dispatchedRequest(request_id));
        table.end(request_id);
    }
    try std.testing.expectEqual(@as(?config.RouteIndex, null), table.routeOfRecent(5));
    try std.testing.expectEqual(@as(?config.RouteIndex, 0), table.routeOfRecent(100));
    try std.testing.expectEqual(@as(?config.RouteIndex, 0), table.routeOfRecent(99 + request_table.ended_requests_max));
}

test "a request the server ended takes its live slot's CPU as its floor, and the worker's later request_done finds no request" {
    var page: Page = undefined;
    try page.init("usage-floor-live-slot");
    defer page.deinit();
    var worker = stackWorker(&page);
    var dispatched = fixture.dispatchedRequest(830);
    dispatched.request_key.slot = 3;
    try worker.requests.record(dispatched);
    const request: worker_table.LiveRequest = .{ .request_id = 830, .request_generation = dispatched.request_key.generation };
    const worker_slot: u8 = 1;
    page.charge(worker_slot, request, 40);

    // The lane ends the request for a deadline: its floor is what the worker
    // measured, under the server's origin, and nothing only `request_done`
    // carries.
    const floor = worker.usageFloor(worker_slot, request, .deadline);
    try std.testing.expectEqual(Origin.server, floor.origin);
    try std.testing.expectEqual(@as(u64, 40), floor.cpu_ns);
    try std.testing.expectEqual(@as(u64, 0), floor.exec_ns);
    try std.testing.expectEqual(@as(u64, 0), floor.waiting_ns);
    try std.testing.expectEqual(@as(u64, 0), floor.io_ns);
    try std.testing.expectEqual(@as(u64, 0), floor.client_served_bytes);
    try std.testing.expectEqual(@as(u64, 0), floor.fetch_sent_bytes);
    try std.testing.expectEqual(@as(u64, 0), floor.fetch_received_bytes);
    worker.requests.end(830);

    // The worker's own `request_done` comes too late to enter any record.
    try std.testing.expectEqual(
        request_table.ForwardCheck.absent,
        worker.requests.forwardCheck(830, dispatched.request_key),
    );
}

test "a floor reads only the live slot at its request's pool slot, and only while that slot holds its request id and generation" {
    var page: Page = undefined;
    try page.init("usage-floor-slot-identity");
    defer page.deinit();
    var worker = stackWorker(&page);
    const request: worker_table.LiveRequest = .{ .request_id = 840, .request_generation = 4 };

    // The request is charged at another slot than the one the lane dispatched
    // it on, which no honest worker does.
    page.charge(2, request, 50);
    try std.testing.expectEqual(@as(u64, 0), worker.usageFloor(1, request, .crash).cpu_ns);

    // The slot holds the request under an earlier generation of its lane
    // slot, or an earlier request of the pool slot.
    page.charge(1, .{ .request_id = 840, .request_generation = 3 }, 60);
    try std.testing.expectEqual(@as(u64, 0), worker.usageFloor(1, request, .crash).cpu_ns);
    page.charge(1, .{ .request_id = 839, .request_generation = 4 }, 70);
    try std.testing.expectEqual(@as(u64, 0), worker.usageFloor(1, request, .crash).cpu_ns);

    // The slot holds the request until the next begin on its pool slot.
    page.charge(1, request, 80);
    try std.testing.expectEqual(@as(u64, 80), worker.usageFloor(1, request, .crash).cpu_ns);
    page.writer.beginLiveSlot(1, 841, 4);
    try std.testing.expectEqual(@as(u64, 0), worker.usageFloor(1, request, .crash).cpu_ns);
}

test "a floor takes the larger of its live slot's CPU and the window its sentinel saw running, only for the request that window names, and none for a death the server caused" {
    var page: Page = undefined;
    try page.init("usage-floor-running-owner");
    defer page.deinit();
    var worker = stackWorker(&page);
    const running: worker_table.LiveRequest = .{ .request_id = 832, .request_generation = 1 };
    const other: worker_table.LiveRequest = .{ .request_id = 833, .request_generation = 1 };
    // Both live slots last stored 10 ms; the sentinel saw request 832 at 40 ms
    // when the worker died in its window.
    page.charge(0, running, 10 * std.time.ns_per_ms);
    page.charge(1, other, 10 * std.time.ns_per_ms);
    page.writer.publishRunningOwnerCpu(running.request_id, 40 * std.time.ns_per_ms);

    try std.testing.expectEqual(40 * std.time.ns_per_ms, worker.usageFloor(0, running, .crash).cpu_ns);
    try std.testing.expectEqual(10 * std.time.ns_per_ms, worker.usageFloor(1, other, .crash).cpu_ns);
    // A window the sentinel saw for a request whose pool slot a later
    // request took still counts for that request.
    page.writer.beginLiveSlot(0, 834, 1);
    try std.testing.expectEqual(40 * std.time.ns_per_ms, worker.usageFloor(0, running, .memory).cpu_ns);
    // The server ended both requests for a fault of its own.
    try std.testing.expectEqual(@as(u64, 0), worker.usageFloor(0, running, .internal_error).cpu_ns);
    try std.testing.expectEqual(@as(u64, 0), worker.usageFloor(1, other, .internal_error).cpu_ns);
}

test "a worker without a page gives a floor of the server's origin and nothing else" {
    var worker = fixture.stackWorker(9, 2, 0);
    worker.handle.metrics = null;
    const floor = worker.usageFloor(0, .{ .request_id = 850, .request_generation = 1 }, .crash);
    try std.testing.expectEqual(Origin.server, floor.origin);
    try std.testing.expectEqual(@as(u64, 0), floor.cpu_ns);
}

//! The ingress service's metrics thread (`server/ingress/service_observability.zig`)
//! against a stop: it keeps draining what the lanes produce after the
//! service's stop flag rises, and ends only at the observability stop the
//! service raises once its lanes have joined. Lane `server-ingress-test`;
//! what one tick drains is covered in `analytics_drain.zig`, and a whole
//! service stopping under load in `local-e2e`.

const std = @import("std");
const analytics = @import("collo_server_analytics");
const server_main = @import("collo_server_main");
const supervision = @import("collo_server_supervisor");
const fixture = @import("supervisor_fixture");

const WorkerRecord = supervision.worker_table.Record;
const WorkerPool = supervision.WorkerPool;
const WorkerKey = server_main.lifecycle.WorkerKey;
const fault = server_main.ingress.fault;
const analytics_drain = server_main.ingress.analytics_drain;
const service_observability = server_main.ingress.service_observability;
const access = analytics.access;

/// How long the test waits for the metrics thread to drain a record, far
/// past one `metrics_drain_interval_ns`.
const drain_wait_ns: u64 = 5 * std.time.ns_per_s;
const drain_poll_ns: u64 = 5 * std.time.ns_per_ms;

const FakeLane = struct {
    access_ring: access.AccessRing = .{},
};

/// The service as its metrics thread reads it, over a fixture supervisor,
/// with its stop flag already raised and its lanes not yet joined: the state
/// a stopping service is in while its lanes finish their requests.
const StoppingService = struct {
    supervisor: *supervision.Supervisor,
    analytics: *analytics.Sink,
    analytics_drain: analytics_drain.State = .{},
    lanes: []FakeLane,
    stop_requested: std.atomic.Value(bool) = .init(true),
    observability_stop: std.atomic.Value(bool) = .init(false),

    pub fn shouldStop(self: *const StoppingService) bool {
        return self.stop_requested.load(.acquire);
    }

    pub fn announceWorkerDeath(
        _: *StoppingService,
        _: *WorkerRecord,
        _: WorkerKey,
        _: WorkerPool.Death,
        _: fault.WorkerFaultReason,
    ) void {}
};

const Observability = service_observability.Methods(StoppingService);

test "the metrics thread keeps draining access records after the stop flag rises, until the lanes have joined" {
    var analytics_dir = try fixture.AnalyticsDir.init(std.testing.allocator);
    defer analytics_dir.deinit(std.testing.allocator);
    var supervisor = try fixture.minimalSupervisorWithAnalytics(std.testing.allocator, analytics_dir.path);
    defer fixture.deinitMinimal(&supervisor);

    var lanes = [_]FakeLane{.{ .access_ring = try access.AccessRing.init() }};
    defer lanes[0].access_ring.deinit();
    var service = StoppingService{ .supervisor = &supervisor, .analytics = supervisor.analytics, .lanes = &lanes };
    try std.testing.expect(service.shouldStop());

    const thread = try std.Thread.spawn(.{}, Observability.metricsThreadMain, .{&service});
    var joined = false;
    defer if (!joined) {
        service.observability_stop.store(true, .release);
        thread.join();
    };

    // A lane still finishing an admitted request after the stop pushes its
    // access record.
    try std.testing.expect(lanes[0].access_ring.push(access.recordFromFacts(access.stamp(.{
        .request_id = 41,
        .worker = "demo",
        .method = "GET",
        .path = "/demo/after-stop",
        .user_agent = "",
        .client_ip = "127.0.0.1",
        .started_mono_ns = 1,
    }), 200, .worker, 2)));

    var waited_ns: u64 = 0;
    var drained = false;
    while (waited_ns < drain_wait_ns) : (waited_ns += drain_poll_ns) {
        if (try accessFileHolds(&analytics_dir, "\"request_id\":41,")) {
            drained = true;
            break;
        }
        std.Thread.sleep(drain_poll_ns);
    }
    try std.testing.expect(drained);

    // The lanes have joined: only now does the thread end.
    service.observability_stop.store(true, .release);
    thread.join();
    joined = true;
}

/// Whether `access.jsonl` holds `needle` yet. The metrics thread flushes the
/// sink at the end of every tick, so a drained record is in the file.
fn accessFileHolds(analytics_dir: *fixture.AnalyticsDir, needle: []const u8) !bool {
    const contents = analytics_dir.tmp.dir.readFileAlloc(std.testing.allocator, "access.jsonl", 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer std.testing.allocator.free(contents);
    return std.mem.indexOf(u8, contents, needle) != null;
}

//! The worker sentinel on its own: a stale generation never fires, it starts
//! without io_uring, a near deadline fires through its poll timeout while
//! its request is the published turn owner, and it starts watching the
//! current cgroup's memory events, skipped when the process has no worker
//! cgroup. Co-scheduled deadlines and owner gating inside a running runtime
//! are covered by `worker/tests/runtime/arbiter.zig` in the same worker-test
//! lane.

const std = @import("std");
const bindings = @import("collo_bindings");
const worker = @import("collo_worker");
const worker_testing = @import("collo_worker_test_support");
const zygote = @import("collo_zygote");
const process = @import("collo_os").process;
const worker_shared_page = @import("collo_worker_state").page;

const sentinel = worker_testing.sentinel;
const cgroup = zygote.worker_boot.cgroup;

const TestTermination = struct {
    requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn request(ctx: *anyopaque) !void {
        const self: *TestTermination = @ptrCast(@alignCast(ctx));
        self.requested.store(true, .release);
    }
};

test "worker sentinel ignores stale timeout generation" {
    var vm = try bindings.Vm.createDefault();
    defer vm.deinit();

    var guard = try sentinel.Sentinel.init(&vm, .{});
    defer guard.deinit();

    const first_generation = try guard.arm(1, 10);
    guard.disarm(1, first_generation);
    const second_generation = try guard.arm(2, 20);

    guard.handleTimeout(1, first_generation);
    try std.testing.expect(!guard.terminationWasRequested(2, second_generation));
}

test "worker sentinel starts without io_uring" {
    var vm = try bindings.Vm.createDefault();
    defer vm.deinit();

    var guard = try sentinel.Sentinel.init(&vm, .{});
    defer guard.deinit();

    try guard.start();
    const generation = try guard.arm(1, process.monotonicNowNsOrZero() + std.time.ns_per_s);
    guard.disarm(1, generation);
}

test "worker sentinel fires near-future deadline through poll timeout" {
    var vm = try bindings.Vm.createDefault();
    defer vm.deinit();
    var termination = TestTermination{};

    var guard = try sentinel.Sentinel.init(&vm, .{
        .termination_hook = .{
            .ctx = &termination,
            .request = TestTermination.request,
        },
    });
    defer guard.deinit();

    try guard.start();
    const generation = try guard.arm(3, process.monotonicNowNsOrZero() + 5 * std.time.ns_per_ms);
    // An expired deadline fires only while its request is the published turn
    // owner, so the test publishes it.
    guard.publishTurnOwner(3);

    const stop = process.monotonicNowNsOrZero() + std.time.ns_per_s;
    while (!guard.terminationWasRequested(3, generation)) {
        if (process.monotonicNowNsOrZero() >= stop)
            return error.SentinelDeadlineDidNotFire;
        std.Thread.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(termination.requested.load(.acquire));
}

test "worker sentinel memory stop path works through command fd" {
    const pid: u32 = @intCast(std.c.getpid());
    const memory_events = cgroup.openCurrentWorkerMemoryEvents(std.testing.allocator, pid) catch |err| switch (err) {
        error.FileNotFound,
        error.InvalidWorkerCgroupDir,
        error.PermissionDenied,
        => return error.SkipZigTest,
        else => return err,
    };
    defer {
        std.posix.close(memory_events.fd);
        std.testing.allocator.free(memory_events.cgroup_dir);
    }

    const events = try cgroup.memory.readEvents(memory_events.fd);
    if (events.high != 0)
        return error.RealCgroupAlreadyUnderMemoryPressure;

    const metrics_fd = try worker_shared_page.createMemfd("collo-sentinel-stop-test");
    defer std.posix.close(metrics_fd);
    var metrics = try worker_shared_page.mapReadWrite(metrics_fd);
    defer metrics.deinit();
    metrics.initializeCrashDefault(pid, 1024 * 1024, try process.monotonicNowNs());

    var vm = try bindings.Vm.createDefault();
    defer vm.deinit();

    var guard = try sentinel.Sentinel.init(&vm, .{
        .memory_events_fd = memory_events.fd,
        .metrics = &metrics,
    });
    defer guard.deinit();
    try guard.start();
}

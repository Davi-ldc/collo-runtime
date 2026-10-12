//! The worker sentinel on its own (`runtime/sentinel.zig`), driven through
//! its publication with a stand-in thread for the VM thread: an owner that
//! spins is stopped for CPU long before its wall deadline, one that sleeps is
//! stopped at its wall deadline and not before, a publication that can
//! expire before the sentinel's planned wake wakes it, the owner's CPU
//! reaches the page before the termination request, a fire is recorded once,
//! and a descriptor that turns invalid under the poll ends the worker
//! through the failure hook with the page's reason `sentinel`. It also starts
//! without io_uring and starts watching the current cgroup's memory events,
//! skipped when the process has no worker cgroup. Fires inside a running
//! runtime are covered by `worker/tests/runtime/arbiter.zig` in the same
//! worker-test lane.

const std = @import("std");
const bindings = @import("collo_bindings");
const worker_testing = @import("collo_worker_test_support");
const zygote = @import("collo_zygote");
const process = @import("collo_os").process;
const worker_shared_page = @import("collo_worker_state").page;

const sentinel = worker_testing.sentinel;
const cgroup = zygote.worker_boot.cgroup;

/// A thread standing in for the VM thread, whose CPU clock the sentinel
/// reads: it spins or sleeps until told to stop.
const StandIn = struct {
    tid: std.atomic.Value(std.os.linux.pid_t) = std.atomic.Value(std.os.linux.pid_t).init(0),
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    spin: bool,

    fn main(self: *StandIn) void {
        self.tid.store(std.os.linux.gettid(), .release);
        while (!self.stop.load(.acquire)) {
            if (!self.spin)
                std.Thread.sleep(std.time.ns_per_ms);
        }
    }

    /// Starts the thread and returns once its id is known.
    fn start(self: *StandIn) !std.Thread {
        const thread = try std.Thread.spawn(.{}, main, .{self});
        while (self.tid.load(.acquire) == 0)
            std.Thread.sleep(std.time.ns_per_ms);
        return thread;
    }

    fn join(self: *StandIn, thread: std.Thread) void {
        self.stop.store(true, .release);
        thread.join();
    }

    fn cpuNs(self: *StandIn) !u64 {
        return process.threadCpuNs(process.threadCpuClockId(self.tid.load(.acquire)));
    }
};

/// A termination hook that records when it ran and what the page's
/// running-owner section held at that moment, instead of terminating a VM.
const TestTermination = struct {
    count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    fired_at_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    page: ?*worker_shared_page.WorkerWriterView = null,
    running_owner: ?worker_shared_page.RunningOwnerSnapshot = null,

    fn request(ctx: *anyopaque) !void {
        const self: *TestTermination = @ptrCast(@alignCast(ctx));
        if (self.page) |page|
            self.running_owner = worker_shared_page.RunningOwnerSnapshot.load(page.header);
        self.fired_at_ns.store(process.monotonicNowNsOrZero(), .release);
        _ = self.count.fetchAdd(1, .acq_rel);
    }

    fn hook(self: *TestTermination) sentinel.TerminationHook {
        return .{ .ctx = self, .request = request };
    }

    /// Waits until the hook ran; fails after `budget_ns` of real time.
    fn wait(self: *TestTermination, budget_ns: u64) !void {
        const stop = process.monotonicNowNsOrZero() + budget_ns;
        while (self.count.load(.acquire) == 0) {
            if (process.monotonicNowNsOrZero() >= stop)
                return error.SentinelDidNotFire;
            std.Thread.sleep(std.time.ns_per_ms);
        }
    }
};

const TestFailure = struct {
    cause: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    called: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn fail(ctx: *anyopaque, cause: sentinel.FailureCause) void {
        const self: *TestFailure = @ptrCast(@alignCast(ctx));
        self.cause.store(@intFromEnum(cause), .release);
        self.called.store(true, .release);
    }

    fn hook(self: *TestFailure) sentinel.FailureHook {
        return .{ .ctx = self, .fail = fail };
    }

    fn wait(self: *TestFailure, budget_ns: u64) !sentinel.FailureCause {
        const stop = process.monotonicNowNsOrZero() + budget_ns;
        while (!self.called.load(.acquire)) {
            if (process.monotonicNowNsOrZero() >= stop)
                return error.SentinelDidNotFail;
            std.Thread.sleep(std.time.ns_per_ms);
        }
        return @enumFromInt(self.cause.load(.acquire));
    }
};

test "worker sentinel starts without io_uring and sleeps with no owner published" {
    var vm = try bindings.Vm.createDefault();
    defer vm.deinit();
    var termination = TestTermination{};

    var guard = try sentinel.Sentinel.init(&vm, .{ .termination_hook = termination.hook() });
    defer guard.deinit();
    try guard.start();

    // An owner with a near deadline that leaves before it passes is never
    // stopped: the sentinel watches only the owner published now.
    guard.publish(.{ .owner_id = 1, .wall_deadline_ns = process.monotonicNowNsOrZero() + 30 * std.time.ns_per_ms });
    guard.publish(.{});
    std.Thread.sleep(80 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u32, 0), termination.count.load(.acquire));
    try std.testing.expect(guard.fired() == null);
}

test "a spinning owner is stopped for its CPU long before its wall deadline" {
    var vm = try bindings.Vm.createDefault();
    defer vm.deinit();
    var stand_in = StandIn{ .spin = true };
    const thread = try stand_in.start();
    defer stand_in.join(thread);
    var termination = TestTermination{};

    var guard = try sentinel.Sentinel.init(&vm, .{
        .vm_thread_tid = stand_in.tid.load(.acquire),
        .termination_hook = termination.hook(),
    });
    defer guard.deinit();
    try guard.start();

    const published_at_ns = process.monotonicNowNsOrZero();
    const cpu_now_ns = try stand_in.cpuNs();
    guard.publish(.{
        .owner_id = 7,
        .wall_deadline_ns = published_at_ns + 10 * std.time.ns_per_s,
        .cpu_deadline_ns = cpu_now_ns + 20 * std.time.ns_per_ms,
        .window_cpu_start_ns = cpu_now_ns,
    });

    try termination.wait(5 * std.time.ns_per_s);
    const fired = guard.fired() orelse return error.FireNotRecorded;
    try std.testing.expectEqual(@as(u64, 7), fired.owner_id);
    try std.testing.expectEqual(sentinel.Cause.cpu, fired.cause);
    // 20 ms of CPU take at least 20 ms of wall time and, on an idle core,
    // little more; the wall deadline lies 10 s out, so a fire in the first
    // seconds can only come from the CPU clock.
    const elapsed_ns = termination.fired_at_ns.load(.acquire) - published_at_ns;
    try std.testing.expect(elapsed_ns >= 20 * std.time.ns_per_ms);
    try std.testing.expect(elapsed_ns < 5 * std.time.ns_per_s);
    guard.publish(.{});
}

test "a sleeping owner is stopped at its wall deadline, not before, though its CPU deadline is nearer" {
    var vm = try bindings.Vm.createDefault();
    defer vm.deinit();
    var stand_in = StandIn{ .spin = false };
    const thread = try stand_in.start();
    defer stand_in.join(thread);
    var termination = TestTermination{};

    var guard = try sentinel.Sentinel.init(&vm, .{
        .vm_thread_tid = stand_in.tid.load(.acquire),
        .termination_hook = termination.hook(),
    });
    defer guard.deinit();
    try guard.start();

    const published_at_ns = process.monotonicNowNsOrZero();
    const wall_deadline_ns = published_at_ns + 300 * std.time.ns_per_ms;
    const cpu_now_ns = try stand_in.cpuNs();
    guard.publish(.{
        .owner_id = 9,
        .wall_deadline_ns = wall_deadline_ns,
        .cpu_deadline_ns = cpu_now_ns + 20 * std.time.ns_per_ms,
        .window_cpu_start_ns = cpu_now_ns,
    });

    try termination.wait(5 * std.time.ns_per_s);
    const fired = guard.fired() orelse return error.FireNotRecorded;
    try std.testing.expectEqual(@as(u64, 9), fired.owner_id);
    try std.testing.expectEqual(sentinel.Cause.deadline, fired.cause);
    // The thread slept, so its 20 ms of CPU never came: the sentinel woke
    // when that CPU could at the earliest have been spent, found it unspent
    // and slept on until the wall deadline.
    try std.testing.expect(termination.fired_at_ns.load(.acquire) >= wall_deadline_ns);
    guard.publish(.{});
}

test "a publication that can expire before the sentinel's planned wake wakes it" {
    var vm = try bindings.Vm.createDefault();
    defer vm.deinit();
    var stand_in = StandIn{ .spin = false };
    const thread = try stand_in.start();
    defer stand_in.join(thread);
    var termination = TestTermination{};

    var guard = try sentinel.Sentinel.init(&vm, .{
        .vm_thread_tid = stand_in.tid.load(.acquire),
        .termination_hook = termination.hook(),
    });
    defer guard.deinit();
    try guard.start();

    // The first owner's deadline 30 s out becomes the sentinel's plan.
    guard.publish(.{ .owner_id = 1, .wall_deadline_ns = process.monotonicNowNsOrZero() + 30 * std.time.ns_per_s });
    std.Thread.sleep(50 * std.time.ns_per_ms);
    // A second owner, 50 ms from its deadline, takes over. Unless the
    // publication wakes the sentinel, it sleeps on toward the first plan.
    const published_at_ns = process.monotonicNowNsOrZero();
    guard.publish(.{ .owner_id = 2, .wall_deadline_ns = published_at_ns + 50 * std.time.ns_per_ms });

    try termination.wait(5 * std.time.ns_per_s);
    const fired = guard.fired() orelse return error.FireNotRecorded;
    try std.testing.expectEqual(@as(u64, 2), fired.owner_id);
    try std.testing.expectEqual(sentinel.Cause.deadline, fired.cause);
    guard.publish(.{});
}

test "the owner's CPU reaches the page before the termination request, and a fire is recorded once" {
    var vm = try bindings.Vm.createDefault();
    defer vm.deinit();
    const page_fd = try worker_shared_page.createMemfd("collo-sentinel-running-cpu");
    defer std.posix.close(page_fd);
    var page = try worker_shared_page.mapReadWrite(page_fd);
    defer page.deinit();
    page.initializeCrashDefault();

    var stand_in = StandIn{ .spin = true };
    const thread = try stand_in.start();
    defer stand_in.join(thread);
    var termination = TestTermination{ .page = &page };

    var guard = try sentinel.Sentinel.init(&vm, .{
        .metrics = &page,
        .vm_thread_tid = stand_in.tid.load(.acquire),
        .termination_hook = termination.hook(),
    });
    defer guard.deinit();
    try guard.start();

    const cpu_now_ns = try stand_in.cpuNs();
    guard.publish(.{
        .owner_id = 11,
        .wall_deadline_ns = process.monotonicNowNsOrZero() + 30 * std.time.ns_per_ms,
        .cpu_before_ns = 5 * std.time.ns_per_ms,
        .window_cpu_start_ns = cpu_now_ns,
    });

    try termination.wait(5 * std.time.ns_per_s);
    const running = termination.running_owner orelse return error.RunningOwnerCpuMissing;
    try std.testing.expectEqual(@as(u64, 11), running.owner_id);
    // The CPU before the window plus the part of the window the thread spun.
    try std.testing.expect(running.cpu_ns > 5 * std.time.ns_per_ms);

    // A later owner past its deadline finds the VM already terminated: a
    // second fire would change nothing, so none is requested.
    guard.publish(.{ .owner_id = 12, .wall_deadline_ns = process.monotonicNowNsOrZero() });
    std.Thread.sleep(50 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u32, 1), termination.count.load(.acquire));
    try std.testing.expectEqual(@as(u64, 11), guard.fired().?.owner_id);
    guard.publish(.{});
}

test "a memory events descriptor that turns invalid under the poll ends the worker as a sentinel failure" {
    // The failure is logged at err, as a worker's would be.
    @import("root").expect_log_errors = 1;
    var vm = try bindings.Vm.createDefault();
    defer vm.deinit();
    const page_fd = try worker_shared_page.createMemfd("collo-sentinel-failure");
    defer std.posix.close(page_fd);
    var page = try worker_shared_page.mapReadWrite(page_fd);
    defer page.deinit();
    page.initializeCrashDefault();

    // A memfd holding a parseable `memory.events.local` stands in for the
    // cgroup file: the poll waits on it for POLLPRI, which a regular file
    // never reports.
    const events_fd = try std.posix.memfd_create("collo-sentinel-memory-events", std.os.linux.MFD.CLOEXEC);
    var events_open = true;
    defer if (events_open) std.posix.close(events_fd);
    const events_text = "low 0\nhigh 0\nmax 0\noom 0\noom_kill 0\n";
    _ = try std.posix.pwrite(events_fd, events_text, 0);

    var failure = TestFailure{};
    var guard = try sentinel.Sentinel.init(&vm, .{
        .memory_events_fd = events_fd,
        .metrics = &page,
        .failure_hook = failure.hook(),
    });
    defer guard.deinit();
    try guard.start();

    // Closed under the sleeping poll, then the sentinel is woken: its next
    // poll finds the descriptor invalid. Today's sentinel returned from its
    // thread there and the worker went on with no watch at all.
    std.posix.close(events_fd);
    events_open = false;
    guard.publish(.{ .owner_id = 1, .wall_deadline_ns = process.monotonicNowNsOrZero() + 30 * std.time.ns_per_s });

    try std.testing.expectEqual(sentinel.FailureCause.memory_events_invalid, try failure.wait(5 * std.time.ns_per_s));
    const lifecycle = worker_shared_page.LifecycleSnapshot.load(page.header);
    try std.testing.expectEqual(worker_shared_page.State.dead, lifecycle.knownState().?);
    try std.testing.expectEqual(worker_shared_page.TerminationReason.sentinel, lifecycle.knownTerminationReason().?);
    guard.publish(.{});
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
    metrics.initializeCrashDefault();

    var vm = try bindings.Vm.createDefault();
    defer vm.deinit();

    var guard = try sentinel.Sentinel.init(&vm, .{
        .memory_events_fd = memory_events.fd,
        .metrics = &metrics,
    });
    defer guard.deinit();
    try guard.start();
}

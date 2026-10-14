//! Engine tests of the engine's lifecycle and queues
//! (`egress/client/engine/root.zig`, lane `egress-test`): an engine that never
//! started refuses a submit and creates no thread; a submit holds a task
//! reference that every path releases once, a stop included; cancels and
//! credits never wait for an owner that is busy; a stopped engine serves
//! again after a start, also after a recoverable owner fault; and a dead
//! data ring settles every fetch, latches the owner fault and refuses a
//! restart. The credit source table is tested on its own in
//! `credit_sources.zig`, and credits that cross a restart in `h2.zig`.

const std = @import("std");
const egress_client = @import("collo_egress_client");
const http1_support = @import("../http1/support.zig");
const network_policy = @import("../network_policy.zig");
const support = @import("support.zig");

const egress_engine = egress_client.engine;
const body_credit = egress_client.body_credit;
const task_model = egress_client.task;

/// A wake callback that holds the owner thread inside the first `task_ready`
/// wake until the test lets it go, so the test can act as a producer while
/// the owner is busy. Every wake is also counted in `counts`.
const BlockingWake = struct {
    counts: support.WakeState = .{},
    entered: std.Thread.ResetEvent = .{},
    release: std.Thread.ResetEvent = .{},
    blocked: std.atomic.Value(bool) = .init(false),

    fn wake(ctx: ?*anyopaque, event: egress_engine.WakeEvent) void {
        const self: *BlockingWake = @ptrCast(@alignCast(ctx.?));
        support.wakeEngineTest(&self.counts, event);
        if (event == .generic)
            return;
        if (self.blocked.swap(true, .acq_rel))
            return;
        self.entered.set();
        self.release.wait();
    }

    fn start(self: *BlockingWake, engine: *egress_engine.Engine) !void {
        engine.start(self, wake) catch |err| switch (err) {
            error.EgressIoUringUnsupported => return error.SkipZigTest,
            else => return err,
        };
    }

    /// Waits until the owner sits inside the first `task_ready` wake.
    fn waitEntered(self: *BlockingWake) !void {
        self.entered.timedWait(2 * std.time.ns_per_s) catch return error.OwnerNeverSettled;
    }
};

fn engineStopping(engine: *egress_engine.Engine) bool {
    engine.mutex.lock();
    defer engine.mutex.unlock();
    return engine.stopping;
}

fn ownerFaultLatched(engine: *egress_engine.Engine) bool {
    return engine.owner_fault.load(.acquire) != 0;
}

fn expectTaskFailed(task: *task_model.Task) !void {
    task.mutex.lock();
    defer task.mutex.unlock();
    const result = task.result orelse return error.MissingFetchResult;
    try std.testing.expect(result == .failure);
}

test "egress engine initializes and deinitializes without starting" {
    var engine = try egress_engine.Engine.init(std.testing.allocator, 4);
    engine.deinit();
}

// The gateway's seccomp filter forbids new threads once its shards run, so
// a submit must never start the engine: an engine nobody started refuses
// the fetch, and the fetch stays the caller's to settle.
test "egress engine refuses a submit before it starts" {
    var task = try support.initEngineFetchTask(std.testing.allocator, 1, "https://example.test/", 1);
    defer task.deinit();
    var engine = try egress_engine.Engine.init(std.testing.allocator, 4);
    defer engine.deinit();
    try std.testing.expectError(error.EgressEngineUnavailable, engine.submit(.{
        .task = &task,
        .config = .{ .network = network_policy.public_https },
    }));
    try std.testing.expect(engine.owner_thread == null);
    try std.testing.expectEqual(@as(u32, 1), task.refs.load(.acquire));
}

// The gateway may drop its own reference to a task while the engine still
// has it queued, for example when a run failed before its stop. The owner is
// held inside the first fetch's settlement, so the second stays queued: the
// submit must have taken a reference, and the stop that settles the queued
// fetch releases it once.
test "egress engine submit holds a task reference that a stop releases once for a fetch it never started" {
    var blocker = try support.initEngineFetchTask(std.testing.allocator, 1, "not a url", 1);
    defer blocker.deinit();
    var queued = try support.initEngineFetchTask(std.testing.allocator, 2, "https://example.test/", 2);
    defer queued.deinit();

    var engine = try egress_engine.Engine.init(std.testing.allocator, 4);
    defer engine.deinit();
    var wake = BlockingWake{};
    try wake.start(&engine);
    defer wake.release.set();
    const config = egress_client.Config{ .network = network_policy.public_https };

    // The blocker fails to prepare, and its settlement holds the owner.
    try engine.submit(.{ .task = &blocker, .config = config });
    try wake.waitEntered();
    try engine.submit(.{ .task = &queued, .config = config });
    try std.testing.expectEqual(@as(u32, 2), queued.refs.load(.acquire));

    const stopper = try std.Thread.spawn(.{}, egress_engine.Engine.stop, .{&engine});
    // On a failed wait the owner is let go and the stop joined before the
    // engine's own deinit stops it again.
    errdefer {
        wake.release.set();
        stopper.join();
    }
    try support.waitUntil(&engine, engineStopping, 2_000);
    wake.release.set();
    stopper.join();

    try expectTaskFailed(&blocker);
    try support.expectTaskFailureMessage(&queued, "EgressEngineStopped");
    try std.testing.expectEqual(@as(usize, 1), wake.counts.taskReadyCount(&queued));
    try std.testing.expectEqual(@as(u32, 1), queued.refs.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), blocker.refs.load(.acquire));
}

const Producer = struct {
    engine: *egress_engine.Engine,
    tasks: []task_model.Task,
    done: std.Thread.ResetEvent = .{},

    fn run(self: *Producer) void {
        for (self.tasks) |*task|
            self.engine.cancel(task);
        for (0..64) |index| {
            const source_id: u64 = index + 1;
            self.engine.releaseFetchBodyCredit(body_credit.h1Resume(source_id));
            self.engine.releaseFetchBodyCredit(body_credit.h2Data(source_id, 1, 16, true));
        }
        self.done.set();
    }
};

// The gateway's loop calls cancel and returns credits on behalf of every
// shard and session, so neither may wait for an owner iteration, which can
// include a TLS handshake step. The owner is held inside a settlement while a
// producer cancels more fetches than the old message queue held and returns
// credits; the producer must finish without the owner. No source is live, so
// the credits are dropped at once; that a live source's credits never need
// room is tested on the table in `credit_sources.zig`.
test "egress engine cancels and credits never wait for a busy owner" {
    var blocker = try support.initEngineFetchTask(std.testing.allocator, 1, "not a url", 1);
    defer blocker.deinit();
    var tasks: [8]task_model.Task = undefined;
    var initialized: usize = 0;
    defer for (tasks[0..initialized]) |*task| task.deinit();
    for (&tasks, 0..) |*task, index| {
        task.* = try support.initEngineFetchTask(std.testing.allocator, 10 + index, "https://example.test/", 10 + index);
        initialized += 1;
    }

    var engine = try egress_engine.Engine.init(std.testing.allocator, 2);
    defer engine.deinit();
    var wake = BlockingWake{};
    try wake.start(&engine);
    defer wake.release.set();

    try engine.submit(.{ .task = &blocker, .config = .{ .network = network_policy.public_https } });
    try wake.waitEntered();
    var producer = Producer{ .engine = &engine, .tasks = &tasks };
    const thread = try std.Thread.spawn(.{}, Producer.run, .{&producer});
    const finished = if (producer.done.timedWait(1_000 * std.time.ns_per_ms)) |_| true else |_| false;
    wake.release.set();
    thread.join();
    try std.testing.expect(finished);

    // Every cancel's reference comes back once the run ends.
    engine.stop();
    for (&tasks) |*task|
        try std.testing.expectEqual(@as(u32, 1), task.refs.load(.acquire));
}

// An owner that cannot build its watch list at the shard's memory budget
// ends its run with the fault latched, like a dead ring, but the ring lives
// on, so the shard supervisor's restart serves again. The engine's allocator
// fails the owner's first allocation of the second run, which is that
// watch list.
test "egress engine serves again after a recoverable owner fault" {
    var origin = try http1_support.LocalHttp1Origin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);
    const fast_url = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/fast", .{ origin.host(), origin.port });
    defer std.testing.allocator.free(fast_url);
    var refused = try support.initEngineFetchTask(std.testing.allocator, 4_800, fast_url, 4_800);
    defer refused.deinit();
    var served = try support.initEngineFetchTask(std.testing.allocator, 4_801, fast_url, 4_801);
    defer served.deinit();

    // Only the engine allocates from it: the test thread outside runs, the
    // owner thread inside them.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var engine = try egress_engine.Engine.init(failing.allocator(), 4);
    defer engine.deinit();
    defer _ = support.releaseTaskBodyCredits(&engine, &served);
    defer engine.stop();
    var wake = support.WakeState{};
    // The first start creates the ring and the threads. The owner is parked
    // when the failure is armed, and the next start publishes it to the
    // owner through the engine's mutex.
    try support.startEngine(&engine, &wake);
    engine.stop();
    failing.fail_index = failing.alloc_index;
    try support.startEngine(&engine, &wake);
    try support.waitUntil(&engine, ownerFaultLatched, 2_000);
    try std.testing.expectEqual(error.OutOfMemory, engine.takeOwnerFault().?);
    const config = egress_client.Config{
        .network = origin.policy(),
        .enable_http2 = false,
        .max_response_body_bytes = 1024,
        .max_encoded_response_bytes = 1024,
        .socket_timeout_ms = 10_000,
    };
    try std.testing.expectError(error.EgressEngineStopped, engine.submit(.{ .task = &refused, .config = config }));

    engine.stop();
    failing.fail_index = std.math.maxInt(usize);
    try support.startEngine(&engine, &wake);
    try engine.submit(.{ .task = &served, .config = config });
    try support.waitTaskDone(&served, 2_000);
    try support.expectTaskStatus(&served, 200);
    try support.waitBodyComplete(served.response_body, 2_000);
}

// A ring whose fd no longer names an io_uring fails every wait: the owner
// settles what it held, latches the fault for the shard supervisor, and a
// restart refuses the dead ring.
test "egress engine dead data ring settles every fetch, latches the owner fault and refuses a restart" {
    var origin = try support.HeldOrigin.start(std.testing.allocator, 1);
    defer origin.stop(std.testing.allocator);
    const held_url = try origin.url(std.testing.allocator);
    defer std.testing.allocator.free(held_url);
    var held = try support.initEngineFetchTask(std.testing.allocator, 4_400, held_url, 4_400);
    defer held.deinit();

    var engine = try egress_engine.Engine.init(std.testing.allocator, 8);
    defer engine.deinit();
    defer _ = support.releaseTaskBodyCredits(&engine, &held);
    defer engine.stop();
    var wake = support.WakeState{};
    try support.startEngine(&engine, &wake);
    const config = egress_client.Config{
        .network = origin.policy(),
        .enable_http2 = false,
        .socket_timeout_ms = 10_000,
    };

    try engine.submit(.{ .task = &held, .config = config });
    try origin.waitAccepted(1, 5_000);
    std.Thread.sleep(20 * std.time.ns_per_ms);

    // dup2 replaces the ring fd with an eventfd atomically, so the owner's
    // next enter reports that the fd is no io_uring.
    const imposter = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC);
    defer std.posix.close(imposter);
    try std.posix.dup2(imposter, engine.data_driver.?.ring.fd);
    engine.signalWake();

    try support.waitTaskDone(&held, 2_000);
    const start = try std.time.Instant.now();
    while (engine.owner_fault.load(.acquire) == 0) {
        std.Thread.sleep(1 * std.time.ns_per_ms);
        const now = try std.time.Instant.now();
        if (now.since(start) >= 2_000 * std.time.ns_per_ms)
            return error.OwnerFaultNeverLatched;
    }
    try std.testing.expect(engine.takeOwnerFault() != null);
    // No owner drains the queue any more, so producers are refused instead
    // of queueing behind it.
    var late = try support.initEngineFetchTask(std.testing.allocator, 4_401, held_url, 4_401);
    defer late.deinit();
    try std.testing.expectError(error.EgressEngineStopped, engine.submit(.{ .task = &late, .config = config }));
    engine.cancel(&held);
    engine.stop();
    try std.testing.expectError(error.EgressDataRingDead, engine.start(&wake, support.wakeEngineTest));
}

test "egress engine serves again after stop and start" {
    var fast_origin = try http1_support.LocalHttp1Origin.start(std.testing.allocator);
    defer fast_origin.stop(std.testing.allocator);
    const fast_url = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/fast", .{ fast_origin.host(), fast_origin.port });
    defer std.testing.allocator.free(fast_url);
    var before = try support.initEngineFetchTask(std.testing.allocator, 4_700, fast_url, 4_700);
    defer before.deinit();
    var after = try support.initEngineFetchTask(std.testing.allocator, 4_701, fast_url, 4_701);
    defer after.deinit();

    var engine = try egress_engine.Engine.init(std.testing.allocator, 8);
    defer engine.deinit();
    defer _ = support.releaseTaskBodyCredits(&engine, &before);
    defer _ = support.releaseTaskBodyCredits(&engine, &after);
    defer engine.stop();
    var wake = support.WakeState{};
    try support.startEngine(&engine, &wake);
    const config = egress_client.Config{
        .network = fast_origin.policy(),
        .enable_http2 = false,
        .max_response_body_bytes = 1024,
        .max_encoded_response_bytes = 1024,
        .socket_timeout_ms = 10_000,
    };

    try engine.submit(.{ .task = &before, .config = config });
    try support.waitTaskDone(&before, 2_000);
    try support.waitBodyComplete(before.response_body, 2_000);

    engine.stop();
    try std.testing.expectError(error.EgressEngineUnavailable, engine.submit(.{ .task = &after, .config = config }));
    try support.startEngine(&engine, &wake);
    try std.testing.expect(engine.takeOwnerFault() == null);

    try engine.submit(.{ .task = &after, .config = config });
    try support.waitTaskDone(&after, 2_000);
    try support.expectTaskStatus(&after, 200);
    try support.waitBodyComplete(after.response_body, 2_000);
}

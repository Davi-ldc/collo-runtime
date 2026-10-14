//! What the worker egress suites that run a runtime share: a runtime on a
//! fake clock, attached to a session whose gateway end the test plays or to
//! none; the count of one item in the ready queue and its backlog; a pass
//! that runs every queued item as the loop does; and a borrowed extent whose
//! release a log records instead of the body pool. No JavaScript runs.

const std = @import("std");
const support = @import("bindings_support");
const worker = @import("collo_worker");
const rt = @import("collo_test_harness");

const WorkItem = worker.testing.scheduler.queue.WorkItem;
const ReadyQueue = worker.testing.scheduler.queue.ReadyQueue;
const egress_body = worker.testing.egress_body;

/// "hello world" as one gzip member.
pub const gzip_hello_world = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x03, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57,
    0x28, 0xcf, 0x2f, 0xca, 0x49, 0x01, 0x00, 0x85,
    0x11, 0x4a, 0x0d, 0x0b, 0x00, 0x00, 0x00,
};

/// A runtime on the fake clock `now_mono_ns`, attached to `session` when one
/// is given and detached without a grant otherwise. The caller attaches the
/// host runtime once the value has its final address, since the VM keeps a
/// pointer to it.
pub fn initRuntime(
    vm: *support.bindings.Vm,
    completion_fixture: *rt.CompletionFixture,
    now_mono_ns: *u64,
    session: ?*rt.RawSession,
) !worker.Runtime {
    return worker.Runtime.init(std.testing.allocator, vm, null, &completion_fixture.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{
        .clock = .{ .ctx = now_mono_ns, .now_fn = rt.fakeNow },
        .egress_shared_fds = if (session) |raw| &raw.worker_raw else null,
    });
}

/// How many slots of the ready queue and its backlog hold `item`.
pub fn queuedCount(runtime: *worker.Runtime, item: WorkItem) usize {
    return queuedIn(&runtime.scheduler.ready_queue, item) + queuedIn(&runtime.scheduler.ready_backlog, item);
}

fn queuedIn(queue: *const ReadyQueue, item: WorkItem) usize {
    var count: usize = 0;
    var offset: usize = 0;
    while (offset < queue.len) : (offset += 1) {
        if (std.meta.eql(queue.items[(queue.head + offset) % queue.items.len], item))
            count += 1;
    }
    return count;
}

/// How many `fetch_body_ready` items the ready queue and its backlog hold,
/// whatever body they name.
pub fn queuedBodyItems(runtime: *worker.Runtime) usize {
    return queuedKindIn(&runtime.scheduler.ready_queue, .fetch_body_ready) +
        queuedKindIn(&runtime.scheduler.ready_backlog, .fetch_body_ready);
}

/// How many `fetch_completion` items the ready queue and its backlog hold.
pub fn queuedCompletionItems(runtime: *worker.Runtime) usize {
    return queuedKindIn(&runtime.scheduler.ready_queue, .fetch_completion) +
        queuedKindIn(&runtime.scheduler.ready_backlog, .fetch_completion);
}

fn queuedKindIn(queue: *const ReadyQueue, kind: std.meta.Tag(WorkItem)) usize {
    var count: usize = 0;
    var offset: usize = 0;
    while (offset < queue.len) : (offset += 1) {
        if (std.meta.activeTag(queue.items[(queue.head + offset) % queue.items.len]) == kind)
            count += 1;
    }
    return count;
}

/// Pops and runs every item the ready queue and its backlog hold, as the
/// loop's passes do, up to a bound no test reaches.
pub fn runQueued(runtime: *worker.Runtime) !void {
    var round: usize = 0;
    while (round < 4096) : (round += 1) {
        runtime.drainReadyBacklog();
        const item = runtime.scheduler.ready_queue.pop() orelse return;
        try worker.testing.executeWorkItem(runtime, item);
    }
    return error.TestReadyQueueNeverEmptied;
}

/// Records each extent release, standing in for the body pool's release
/// queue.
pub const ReleaseLog = struct {
    count: usize = 0,

    fn releaseFn(context: ?*anyopaque, handle: u64, len: usize) void {
        _ = handle;
        _ = len;
        const self: *ReleaseLog = @ptrCast(@alignCast(context.?));
        self.count += 1;
    }

    pub fn borrow(self: *ReleaseLog, bytes: []u8, handle: u64) egress_body.BorrowedChunk {
        return .{
            .bytes = bytes,
            .release = .{ .context = self, .handle = handle, .len = bytes.len, .release_fn = releaseFn },
        };
    }
};

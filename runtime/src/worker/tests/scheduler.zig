//! The scheduler's structures and the worker ring: ready queue order,
//! wrap-around and slot metadata, timer heap order and cancellation,
//! immediate generations and cancellation, the fixed capacity of each, and
//! the worker ring's fixed-file table, its idle re-arm and the control
//! socket's write poll, armed only while a send waits, whose hangup fails
//! the wait as the read poll's does. The one loop run here meets a hangup
//! before its first wait and stops cleanly. The loop running real turns, and
//! flushing a parked response, is covered by `worker/tests/runtime/` in the
//! same worker-test lane, and inside a sandboxed worker by the
//! zygote-integration lane.

const std = @import("std");
const bindings = @import("collo_bindings");
const fd_mod = @import("collo_os").fd;
const ipc = @import("collo_ipc");
const restricted_uring = @import("collo_common_io").restricted_uring;
const worker = @import("collo_worker");
const worker_testing = @import("collo_worker_test_support");
const rt = @import("collo_test_harness");
const immediates = worker_testing.scheduler.immediates;
const ready_queue = worker_testing.scheduler.queue;
const scheduler_uring_backend = worker_testing.scheduler.uring_backend;
const timers = worker_testing.scheduler.timers;

test "ready queue preserves fifo order" {
    var queue = try ready_queue.ReadyQueue.init(std.testing.allocator, 4);
    defer queue.deinit();

    try queue.push(.{ .request = 1 });
    try queue.push(.{ .timer_callback = 2 });

    try std.testing.expectEqual(@as(usize, 2), queue.len);
    try std.testing.expectEqual(@as(u64, 1), queue.pop().?.request);
    try std.testing.expectEqual(@as(u64, 2), queue.pop().?.timer_callback);
    try std.testing.expect(queue.isEmpty());
}

test "ready queue wraps correctly" {
    var queue = try ready_queue.ReadyQueue.init(std.testing.allocator, 2);
    defer queue.deinit();

    try queue.push(.{ .request = 10 });
    _ = queue.pop();
    try queue.push(.{ .request = 20 });
    try queue.push(.{ .request = 30 });

    try std.testing.expectEqual(@as(u64, 20), queue.pop().?.request);
    try std.testing.expectEqual(@as(u64, 30), queue.pop().?.request);
}

test "ready queue slot metadata rides enqueue, backlog drain, and pop" {
    var ready = try ready_queue.ReadyQueue.init(std.testing.allocator, 2);
    defer ready.deinit();
    var backlog = try ready_queue.ReadyQueue.init(std.testing.allocator, 2);
    defer backlog.deinit();

    // The owner and the readiness stamp are set once, at enqueue, and travel
    // with the slot.
    const meta_a: ready_queue.SlotMeta = .{
        .enqueued_mono_ns = 100,
        .owner_request_id = 41,
        .ready_since_mono_ns = 90,
    };
    const meta_b: ready_queue.SlotMeta = .{
        .enqueued_mono_ns = 110,
        .owner_request_id = 42,
        .ready_since_mono_ns = 0,
    };
    const meta_c: ready_queue.SlotMeta = .{
        .enqueued_mono_ns = 120,
        .owner_request_id = 43,
        .ready_since_mono_ns = 105,
    };

    try std.testing.expect(ready.tryPushStamped(.{ .request = 41 }, meta_a));
    try std.testing.expect(ready.tryPushStamped(.{ .fetch_completion = 42 }, meta_b));
    // With the ready queue full, the overflow item carries the same metadata
    // into the backlog, as `tryQueueReadyWorkReadySince` does.
    try std.testing.expect(!ready.tryPushStamped(.{ .timer_callback = 43 }, meta_c));
    try std.testing.expect(backlog.tryPushStamped(.{ .timer_callback = 43 }, meta_c));

    try std.testing.expectEqual(@as(u64, 41), ready.pop().?.request);
    try std.testing.expectEqual(meta_a, ready.last_popped_meta);

    // drainInto keeps each slot's metadata across the move, including the
    // wrap-around the freed head slot forces on the target.
    backlog.drainInto(&ready);
    try std.testing.expect(backlog.isEmpty());
    try std.testing.expectEqual(@as(u64, 42), ready.pop().?.fetch_completion);
    try std.testing.expectEqual(meta_b, ready.last_popped_meta);
    try std.testing.expectEqual(@as(u64, 43), ready.pop().?.timer_callback);
    try std.testing.expectEqual(meta_c, ready.last_popped_meta);
}

test "timer heap returns earliest timers first" {
    var heap = try timers.TimerHeap.initCapacity(std.testing.allocator, 3);
    defer heap.deinit();

    try heap.push(.{ .id = 2, .request_id = 1, .due_mono_ns = 30, .callback = .{ .inner = .{} } });
    try heap.push(.{ .id = 1, .request_id = 1, .due_mono_ns = 10, .callback = .{ .inner = .{} } });
    try heap.push(.{ .id = 3, .request_id = 2, .due_mono_ns = 20, .callback = .{ .inner = .{} } });

    try std.testing.expectEqual(@as(u64, 10), heap.peekDueNs().?);
    try std.testing.expect(heap.popDue(9) == null);
    try std.testing.expectEqual(@as(u64, 1), heap.popDue(10).?.id);
    try std.testing.expectEqual(@as(u64, 3), heap.popDue(25).?.id);
    try std.testing.expectEqual(@as(u64, 2), heap.popDue(30).?.id);
}

test "timer heap cancels timers by request id" {
    var heap = try timers.TimerHeap.initCapacity(std.testing.allocator, 3);
    defer heap.deinit();

    try heap.push(.{ .id = 1, .request_id = 10, .due_mono_ns = 30, .callback = .{ .inner = .{} } });
    try heap.push(.{ .id = 2, .request_id = 11, .due_mono_ns = 10, .callback = .{ .inner = .{} } });
    try heap.push(.{ .id = 3, .request_id = 10, .due_mono_ns = 20, .callback = .{ .inner = .{} } });

    try std.testing.expectEqual(@as(usize, 2), heap.cancelForRequest(10));
    const remaining = heap.popDue(10).?;
    try std.testing.expectEqual(@as(u64, 2), remaining.id);
    try std.testing.expect(heap.popDue(100) == null);
}

test "timer heap cancels one timer by id and request" {
    var heap = try timers.TimerHeap.initCapacity(std.testing.allocator, 3);
    defer heap.deinit();

    try heap.push(.{ .id = 1, .request_id = 10, .due_mono_ns = 10, .callback = .{ .inner = .{} } });
    try heap.push(.{ .id = 2, .request_id = 10, .due_mono_ns = 5, .callback = .{ .inner = .{} } });
    try heap.push(.{ .id = 3, .request_id = 11, .due_mono_ns = 1, .callback = .{ .inner = .{} } });

    try std.testing.expect(!heap.cancelByIdForRequest(3, 10));
    try std.testing.expect(heap.cancelByIdForRequest(2, 10));
    try std.testing.expectEqual(@as(usize, 2), heap.len());
    try std.testing.expectEqual(@as(u64, 3), heap.popDue(30).?.id);
    try std.testing.expectEqual(@as(u64, 1), heap.popDue(30).?.id);
    try std.testing.expect(heap.popDue(30) == null);
}

test "timer heap push never grows implicitly" {
    var heap = try timers.TimerHeap.initCapacity(std.testing.allocator, 1);
    defer heap.deinit();

    var id: u64 = 1;
    while (heap.len() < heap.capacity()) : (id += 1) {
        try heap.push(.{ .id = id, .request_id = 1, .due_mono_ns = id, .callback = .{ .inner = .{} } });
    }
    try std.testing.expectError(error.TimerHeapFull, heap.push(.{ .id = id, .request_id = 1, .due_mono_ns = id, .callback = .{ .inner = .{} } }));
}

test "timer heap reuses capacity after pop and cancel" {
    var heap = try timers.TimerHeap.initCapacity(std.testing.allocator, 2);
    defer heap.deinit();

    try heap.push(.{ .id = 1, .request_id = 1, .due_mono_ns = 10, .callback = .{ .inner = .{} } });
    try heap.push(.{ .id = 2, .request_id = 1, .due_mono_ns = 20, .callback = .{ .inner = .{} } });
    var popped = heap.popDue(10).?;
    popped.deinit(std.testing.allocator);

    try heap.push(.{ .id = 3, .request_id = 2, .due_mono_ns = 5, .callback = .{ .inner = .{} } });
    var reused = heap.popDue(5).?;
    defer reused.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 3), reused.id);
    try std.testing.expect(heap.cancelByIdForRequest(2, 1));

    try heap.push(.{ .id = 4, .request_id = 3, .due_mono_ns = 1, .callback = .{ .inner = .{} } });
    try heap.push(.{ .id = 5, .request_id = 3, .due_mono_ns = 2, .callback = .{ .inner = .{} } });
    try std.testing.expectEqual(@as(usize, 2), heap.len());
}

test "immediate queue preserves fifo order within generation" {
    var queue = try immediates.ImmediateQueue.initCapacity(std.testing.allocator, 3);
    defer queue.deinit();

    try queue.push(.{
        .id = 1,
        .request_id = 10,
        .generation = 0,
        .callback = .{ .inner = .{} },
    });
    try queue.push(.{
        .id = 2,
        .request_id = 10,
        .generation = 0,
        .callback = .{ .inner = .{} },
    });
    try queue.push(.{
        .id = 3,
        .request_id = 10,
        .generation = 1,
        .callback = .{ .inner = .{} },
    });

    var first = queue.popGeneration(0).?;
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 1), first.id);

    var second = queue.popGeneration(0).?;
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 2), second.id);

    try std.testing.expect(queue.popGeneration(0) == null);

    var third = queue.popGeneration(1).?;
    defer third.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 3), third.id);
}

test "immediate queue cancels by id and request" {
    var queue = try immediates.ImmediateQueue.initCapacity(std.testing.allocator, 3);
    defer queue.deinit();

    try queue.push(.{
        .id = 1,
        .request_id = 10,
        .generation = 0,
        .callback = .{ .inner = .{} },
    });
    try queue.push(.{
        .id = 2,
        .request_id = 11,
        .generation = 0,
        .callback = .{ .inner = .{} },
    });
    try queue.push(.{
        .id = 3,
        .request_id = 10,
        .generation = 0,
        .callback = .{ .inner = .{} },
    });

    try std.testing.expect(!queue.cancelByIdForRequest(2, 10));
    try std.testing.expect(queue.cancelByIdForRequest(1, 10));
    try std.testing.expectEqual(@as(usize, 2), queue.reservedCount());
    try std.testing.expectEqual(@as(usize, 1), queue.cancelForRequest(10));

    var remaining = queue.popGeneration(0).?;
    defer remaining.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 2), remaining.id);
    try std.testing.expect(queue.popGeneration(0) == null);
}

test "immediate queue push never grows implicitly and reuses capacity" {
    var queue = try immediates.ImmediateQueue.initCapacity(std.testing.allocator, 1);
    defer queue.deinit();

    try queue.push(.{
        .id = 1,
        .request_id = 10,
        .generation = 0,
        .callback = .{ .inner = .{} },
    });
    try std.testing.expectError(error.ImmediateQueueFull, queue.push(.{
        .id = 2,
        .request_id = 10,
        .generation = 0,
        .callback = .{ .inner = .{} },
    }));

    var popped = queue.popGeneration(0).?;
    popped.deinit(std.testing.allocator);

    try queue.push(.{
        .id = 3,
        .request_id = 10,
        .generation = 0,
        .callback = .{ .inner = .{} },
    });
    var reused = queue.popGeneration(0).?;
    defer reused.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 3), reused.id);
}

test "worker scheduler requires restricted ring" {
    const control_pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var vm = try bindings.Vm.createDefault();
    defer vm.deinit();

    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{});
    defer runtime.deinit();

    try std.testing.expectError(error.WorkerRingUnavailable, scheduler_uring_backend.UringBackend.init(&runtime));
}

// The worker ring's `fs_fault` fixed file comes from the installed fs index,
// so ring tests install the placeholder index with a live SEQPACKET pair.
const ring_index_bytes: []const u8 = &worker.fs.fs_index.placeholder_bytes;

test "worker ring arm is idempotent while polls stay armed" {
    const control_pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    var wake_set = try ipc.egress_shared.WakeSet.create();
    defer wake_set.deinit();
    var shared = try ipc.egress_shared.createSessionForWorker(&wake_set);
    defer shared.deinit();
    var worker_raw = shared.takeWorkerHalf();
    const ingress_payload_credit_fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
    var ingress_payload_credit_owned_by_runtime = false;
    errdefer if (!ingress_payload_credit_owned_by_runtime)
        std.posix.close(ingress_payload_credit_fd);

    const fault_pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(fault_pair[0]);
    defer std.posix.close(fault_pair[1]);
    try worker.fs.installForTestWithFault(ring_index_bytes, worker.fs.deploy_root, fault_pair[0], worker.fs.deploy_root);
    defer worker.fs.uninstallForTest();

    var vm = try bindings.Vm.createDefault();
    defer vm.deinit();

    ingress_payload_credit_owned_by_runtime = true;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{
        .egress_shared_fds = &worker_raw,
        .ingress_payload_credit_eventfd = ingress_payload_credit_fd,
    });
    defer runtime.deinit();

    try runtime.initRestrictedWorkerRing();

    var backend = try scheduler_uring_backend.UringBackend.init(&runtime);
    defer backend.deinit();

    const after_init = runtime.workerSchedulerMetricsSnapshot();
    try std.testing.expectEqual(@as(u64, 1), after_init.worker_ring_arm_calls);
    try std.testing.expect(after_init.worker_ring_sqe_submits >= 2);
    try std.testing.expectEqual(@as(u64, 1), after_init.worker_ring_submit_syscalls);

    for (0..32) |_|
        try backend.arm(&runtime);

    const after_idle_rearms = runtime.workerSchedulerMetricsSnapshot();
    try std.testing.expectEqual(after_init.worker_ring_arm_calls + 32, after_idle_rearms.worker_ring_arm_calls);
    try std.testing.expectEqual(after_init.worker_ring_sqe_submits, after_idle_rearms.worker_ring_sqe_submits);
    try std.testing.expectEqual(after_init.worker_ring_submit_syscalls, after_idle_rearms.worker_ring_submit_syscalls);
    try std.testing.expectEqual(after_init.worker_ring_cqes, after_idle_rearms.worker_ring_cqes);
}

/// A worker runtime with its restricted ring, built as the idempotent-arm
/// test builds it. `control_pair[1]` is the server's end.
const RingRuntime = struct {
    control_pair: [2]std.posix.fd_t,
    fault_pair: [2]std.posix.fd_t,
    wake_set: ipc.egress_shared.WakeSet,
    shared: ipc.egress_shared.SessionFds,
    vm: bindings.Vm,
    completion_fixture: rt.CompletionFixture,
    runtime: worker.Runtime,
    server_end_open: bool,

    fn init(self: *RingRuntime) !void {
        self.control_pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
        errdefer for (self.control_pair) |fd| std.posix.close(fd);
        self.server_end_open = true;
        self.wake_set = try ipc.egress_shared.WakeSet.create();
        errdefer self.wake_set.deinit();
        self.shared = try ipc.egress_shared.createSessionForWorker(&self.wake_set);
        errdefer self.shared.deinit();
        var worker_raw = self.shared.takeWorkerHalf();
        const ingress_payload_credit_fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
        var credit_owned_by_runtime = false;
        errdefer if (!credit_owned_by_runtime) std.posix.close(ingress_payload_credit_fd);

        self.fault_pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
        errdefer for (self.fault_pair) |fd| std.posix.close(fd);
        try worker.fs.installForTestWithFault(ring_index_bytes, worker.fs.deploy_root, self.fault_pair[0], worker.fs.deploy_root);
        errdefer worker.fs.uninstallForTest();

        self.vm = try bindings.Vm.createDefault();
        errdefer self.vm.deinit();
        self.completion_fixture = try rt.CompletionFixture.init();
        errdefer self.completion_fixture.deinit();
        credit_owned_by_runtime = true;
        self.runtime = try worker.Runtime.init(std.testing.allocator, &self.vm, self.control_pair[0], &self.completion_fixture.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{
            .egress_shared_fds = &worker_raw,
            .ingress_payload_credit_eventfd = ingress_payload_credit_fd,
        });
        errdefer self.runtime.deinit();
        try self.runtime.initRestrictedWorkerRing();
    }

    fn closeServerEnd(self: *RingRuntime) void {
        std.posix.close(self.control_pair[1]);
        self.server_end_open = false;
    }

    fn deinit(self: *RingRuntime) void {
        self.runtime.deinit();
        self.completion_fixture.deinit();
        self.vm.deinit();
        worker.fs.uninstallForTest();
        for (self.fault_pair) |fd| std.posix.close(fd);
        self.shared.deinit();
        self.wake_set.deinit();
        std.posix.close(self.control_pair[0]);
        if (self.server_end_open) std.posix.close(self.control_pair[1]);
    }
};

test "worker ring polls the control socket for room only while a send waits for it" {
    var fixture: RingRuntime = undefined;
    try fixture.init();
    defer fixture.deinit();
    const runtime = &fixture.runtime;

    var backend = try scheduler_uring_backend.UringBackend.init(runtime);
    defer backend.deinit();
    const idle = runtime.workerSchedulerMetricsSnapshot();
    try backend.arm(runtime);
    try std.testing.expectEqual(idle.worker_ring_sqe_submits, runtime.workerSchedulerMetricsSnapshot().worker_ring_sqe_submits);

    runtime.requests.control_send_blocked = true;
    try backend.arm(runtime);
    try backend.arm(runtime);
    try std.testing.expectEqual(idle.worker_ring_sqe_submits + 1, runtime.workerSchedulerMetricsSnapshot().worker_ring_sqe_submits);

    // Nothing is queued toward the server, so the socket has room at once.
    var events: [8]scheduler_uring_backend.Event = undefined;
    const ready = try backend.wait(runtime, &events);
    var writable = false;
    for (events[0..ready]) |event| {
        if (event == .control_writable) writable = true;
    }
    try std.testing.expect(writable);

    // The flush the event calls for finds nothing parked and clears the
    // flag, so the next arm queues no write poll. It may queue others: the
    // wait reaps every poll that completed, not only the write poll.
    try runtime.flushPendingIngressResponses();
    try std.testing.expect(!runtime.requests.control_send_blocked);
    try backend.arm(runtime);
    try std.testing.expect(!backend.control_writable_poll_armed);
}

test "worker loop stops without error when the server hung up before the loop waits" {
    var fixture: RingRuntime = undefined;
    try fixture.init();
    defer fixture.deinit();

    // The read poll completes with the hangup as soon as it is armed, so the
    // loop's non-blocking drain reaps it before any blocking wait.
    fixture.closeServerEnd();
    try worker_testing.scheduler.loop.run(&fixture.runtime);
}

test "worker ring fails the wait with the control peer closed when the write poll meets a hangup" {
    var fixture: RingRuntime = undefined;
    try fixture.init();
    defer fixture.deinit();
    const runtime = &fixture.runtime;

    // Only the write poll watches the control socket: this backend counts the
    // read poll as in flight and never queues it. A closed peer reports room
    // and the hangup together, and the hangup wins.
    var backend: scheduler_uring_backend.UringBackend = .{ .control_poll_armed = true };
    defer backend.deinit();
    runtime.requests.control_send_blocked = true;
    fixture.closeServerEnd();
    try backend.arm(runtime);
    try std.testing.expect(backend.control_writable_poll_armed);
    var events: [8]scheduler_uring_backend.Event = undefined;
    try std.testing.expectError(error.ControlPeerClosed, backend.wait(runtime, &events));
}

test "worker ring fixed table contains only expected control wakeup egress timer ingress-credit and fs-fault fds" {
    const control_pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var wake_set = try ipc.egress_shared.WakeSet.create();
    defer wake_set.deinit();
    var shared = try ipc.egress_shared.createSessionForWorker(&wake_set);
    defer shared.deinit();
    var worker_raw = shared.takeWorkerHalf();
    const ingress_payload_credit_fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
    var ingress_payload_credit_owned_by_runtime = false;
    errdefer if (!ingress_payload_credit_owned_by_runtime)
        std.posix.close(ingress_payload_credit_fd);
    const released_completion_eventfd = worker_raw.completion_eventfd;
    const released_liveness_fd = worker_raw.liveness_fd;
    const released_command_eventfd = worker_raw.command_eventfd;

    const fault_pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(fault_pair[0]);
    defer std.posix.close(fault_pair[1]);
    try worker.fs.installForTestWithFault(ring_index_bytes, worker.fs.deploy_root, fault_pair[0], worker.fs.deploy_root);
    defer worker.fs.uninstallForTest();

    var vm = try bindings.Vm.createDefault();
    defer vm.deinit();

    ingress_payload_credit_owned_by_runtime = true;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{
        .egress_shared_fds = &worker_raw,
        .ingress_payload_credit_eventfd = ingress_payload_credit_fd,
    });
    defer runtime.deinit();

    try runtime.initRestrictedWorkerRing();

    const fixed_files = runtime.workerRingFixedFiles() orelse return error.MissingWorkerRingFixedFiles;
    try std.testing.expectEqual(control_pair[0], fixed_files[@intFromEnum(restricted_uring.FixedFile.control)]);
    try std.testing.expectEqual(runtime.scheduler.wakeup_fd.?, fixed_files[@intFromEnum(restricted_uring.FixedFile.wakeup)]);
    try std.testing.expectEqual(released_completion_eventfd, fixed_files[@intFromEnum(restricted_uring.FixedFile.egress_completion)]);
    try std.testing.expectEqual(released_liveness_fd, fixed_files[@intFromEnum(restricted_uring.FixedFile.egress_liveness)]);
    try std.testing.expectEqual(runtime.workerTimerFd().?, fixed_files[@intFromEnum(restricted_uring.FixedFile.timer)]);
    try std.testing.expectEqual(ingress_payload_credit_fd, fixed_files[@intFromEnum(restricted_uring.FixedFile.ingress_payload_credit)]);
    try std.testing.expectEqual(fault_pair[0], fixed_files[@intFromEnum(restricted_uring.FixedFile.fs_fault)]);

    try std.testing.expect(fixed_files[@intFromEnum(restricted_uring.FixedFile.egress_completion)] != released_command_eventfd);
    for (fixed_files) |fd|
        try expectNotRegularFileOrDirectory(fd);
}

test "worker ring fixed table rejects sockets outside the control slot" {
    const control_pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    const wrong_socket_pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(wrong_socket_pair[0]);
    defer std.posix.close(wrong_socket_pair[1]);

    const fault_pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(fault_pair[0]);
    defer std.posix.close(fault_pair[1]);

    const wakeup_fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
    defer std.posix.close(wakeup_fd);
    const completion_fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
    defer std.posix.close(completion_fd);
    const liveness_fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
    defer std.posix.close(liveness_fd);
    const ingress_payload_credit_fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
    defer std.posix.close(ingress_payload_credit_fd);
    const timer_fd = try std.posix.timerfd_create(.MONOTONIC, .{
        .CLOEXEC = true,
        .NONBLOCK = true,
    });
    defer std.posix.close(timer_fd);

    var fixed_files = [_]std.posix.fd_t{
        control_pair[0],
        wakeup_fd,
        wrong_socket_pair[0],
        liveness_fd,
        timer_fd,
        ingress_payload_credit_fd,
        fault_pair[0],
    };
    try std.testing.expectError(error.InvalidWorkerRingFixedFile, restricted_uring.validateWorkerFixedFiles(&fixed_files));

    fixed_files[@intFromEnum(restricted_uring.FixedFile.egress_completion)] = completion_fd;
    try restricted_uring.validateWorkerFixedFiles(&fixed_files);

    fixed_files[@intFromEnum(restricted_uring.FixedFile.timer)] = wrong_socket_pair[0];
    try std.testing.expectError(error.InvalidWorkerRingFixedFile, restricted_uring.validateWorkerFixedFiles(&fixed_files));
    fixed_files[@intFromEnum(restricted_uring.FixedFile.timer)] = liveness_fd;
    try std.testing.expectError(error.InvalidWorkerRingFixedFile, restricted_uring.validateWorkerFixedFiles(&fixed_files));
    fixed_files[@intFromEnum(restricted_uring.FixedFile.timer)] = timer_fd;

    fixed_files[@intFromEnum(restricted_uring.FixedFile.wakeup)] = control_pair[0];
    try std.testing.expectError(error.InvalidWorkerRingFixedFile, restricted_uring.validateWorkerFixedFiles(&fixed_files));
}

fn expectNotRegularFileOrDirectory(fd: std.posix.fd_t) !void {
    const stat = try std.posix.fstat(fd);
    const file_type = stat.mode & std.os.linux.S.IFMT;
    try std.testing.expect(file_type != std.os.linux.S.IFREG);
    try std.testing.expect(file_type != std.os.linux.S.IFDIR);
}

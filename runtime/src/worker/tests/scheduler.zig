//! The scheduler's structures and the loop's wait: ready queue order,
//! wrap-around and slot metadata, timer heap order and cancellation,
//! immediate generations and cancellation, the fixed capacity of each, and
//! the `ppoll` wait (`scheduler/poll_backend.zig`): it asks the control
//! socket for room only while a send, the retirement notice or a
//! `request_done` waits for it, sends a waiting `request_done` once the
//! socket has room, fails with the control peer closed on a hangup, reports
//! the wakeup and payload credit eventfds, a deadline already due and a
//! session whose gateway hung up, whether the worker held it from boot or
//! took it from an `egress_attach`, watches nothing of an `egress_attach`
//! that a worker without a network grant refuses, closing every descriptor
//! it brought, and does not block while a gateway drain may have left
//! packets past its batch bound. The one loop run here meets a hangup before
//! its first wait and stops cleanly. The loop reading every queued control
//! packet before it runs work is covered by `worker/tests/scheduler/loop.zig`,
//! the loop running real turns, and resuming a parked response, by
//! `worker/tests/runtime/` in the same worker-test lane, and inside a
//! sandboxed worker by the zygote-integration lane.

const std = @import("std");
const bindings = @import("collo_bindings");
const fd_mod = @import("collo_os").fd;
const ipc = @import("collo_ipc");
const worker = @import("collo_worker");
const worker_testing = @import("collo_worker_test_support");
const rt = @import("collo_test_harness");
const immediates = worker_testing.scheduler.immediates;
const ready_queue = worker_testing.scheduler.queue;
const poll_backend = worker_testing.scheduler.poll_backend;
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

test "a request's cancel finds nothing in an empty timer heap or immediate queue, emptied ones included, and finds what is scheduled again" {
    // A request's finish cancels its timers and immediates whether or not
    // anything is scheduled, and an empty heap or queue answers at once.
    var heap = try timers.TimerHeap.initCapacity(std.testing.allocator, 2);
    defer heap.deinit();
    try std.testing.expectEqual(@as(usize, 0), heap.cancelForRequest(10));
    try heap.push(.{ .id = 1, .request_id = 10, .due_mono_ns = 5, .callback = .{ .inner = .{} } });
    var popped = heap.popDue(5).?;
    popped.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), heap.cancelForRequest(10));
    try heap.push(.{ .id = 2, .request_id = 10, .due_mono_ns = 5, .callback = .{ .inner = .{} } });
    try std.testing.expectEqual(@as(usize, 1), heap.cancelForRequest(10));
    try std.testing.expectEqual(@as(usize, 0), heap.reservedCount());

    var queue = try immediates.ImmediateQueue.initCapacity(std.testing.allocator, 2);
    defer queue.deinit();
    try std.testing.expect(queue.takeForRequest(10) == null);
    try queue.push(.{ .id = 1, .request_id = 10, .generation = 0, .callback = .{ .inner = .{} } });
    var taken = queue.takeForRequest(10).?;
    taken.deinit(std.testing.allocator);
    try std.testing.expect(queue.takeForRequest(10) == null);
    try std.testing.expectEqual(@as(usize, 0), queue.reservedCount());

    // A full queue, no free slot left, still answers for each request.
    try queue.push(.{ .id = 2, .request_id = 10, .generation = 0, .callback = .{ .inner = .{} } });
    try queue.push(.{ .id = 3, .request_id = 11, .generation = 0, .callback = .{ .inner = .{} } });
    var first = queue.takeForRequest(10).?;
    first.deinit(std.testing.allocator);
    try std.testing.expect(queue.takeForRequest(10) == null);
    try std.testing.expectEqual(@as(usize, 1), queue.reservedCount());
    var second = queue.takeForRequest(11).?;
    second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), queue.reservedCount());
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

/// A worker runtime on a control socket pair with a payload credit eventfd,
/// and, when `egress` brings one, a session. `control_pair[1]` is the
/// server's end.
const PollRuntime = struct {
    control_pair: [2]std.posix.fd_t,
    credit_fd: std.posix.fd_t,
    vm: bindings.Vm,
    completion_fixture: rt.CompletionFixture,
    runtime: worker.Runtime,
    server_end_open: bool,

    fn init(self: *PollRuntime, egress: *ipc.egress_shared.RawFds) !void {
        self.control_pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
        errdefer for (self.control_pair) |fd| std.posix.close(fd);
        self.server_end_open = true;
        // The worker's end does not block, as the child leaves it.
        try fd_mod.setNonblocking(self.control_pair[0], true);
        self.credit_fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
        var credit_owned_by_runtime = false;
        errdefer if (!credit_owned_by_runtime) std.posix.close(self.credit_fd);

        self.vm = try bindings.Vm.createDefault();
        errdefer self.vm.deinit();
        self.completion_fixture = try rt.CompletionFixture.init();
        errdefer self.completion_fixture.deinit();
        credit_owned_by_runtime = true;
        self.runtime = try worker.Runtime.init(std.testing.allocator, &self.vm, self.control_pair[0], &self.completion_fixture.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{
            .egress_shared_fds = egress,
            .ingress_payload_credit_eventfd = self.credit_fd,
        });
    }

    fn closeServerEnd(self: *PollRuntime) void {
        std.posix.close(self.control_pair[1]);
        self.server_end_open = false;
    }

    fn deinit(self: *PollRuntime) void {
        self.runtime.deinit();
        self.completion_fixture.deinit();
        self.vm.deinit();
        std.posix.close(self.control_pair[0]);
        if (self.server_end_open) std.posix.close(self.control_pair[1]);
    }
};

/// Whether `events` holds an event with the tag `tag`.
fn hasEvent(events: []const poll_backend.Event, tag: std.meta.Tag(poll_backend.Event)) bool {
    for (events) |event| {
        if (std.meta.activeTag(event) == tag)
            return true;
    }
    return false;
}

test "the loop's wait asks the control socket for room only while a send waits for it" {
    var no_egress: ipc.egress_shared.RawFds = .{};
    var fixture: PollRuntime = undefined;
    try fixture.init(&no_egress);
    defer fixture.deinit();
    const runtime = &fixture.runtime;
    const backend: poll_backend.PollBackend = .{};
    var events: [poll_backend.events_max]poll_backend.Event = undefined;

    // Nothing is queued toward the server, so the socket has room, which the
    // wait does not ask about while nothing waits for it.
    var ready = try backend.drain(runtime, &events);
    try std.testing.expect(!hasEvent(events[0..ready], .control_writable));

    runtime.requests.control_send_blocked = true;
    ready = try backend.drain(runtime, &events);
    try std.testing.expect(hasEvent(events[0..ready], .control_writable));

    // The event's handler finds no response waiting and clears the flag, so
    // the next wait asks no more.
    try worker_testing.scheduler.loop.handleControlWritable(runtime);
    try std.testing.expect(!runtime.requests.control_send_blocked);
    ready = try backend.drain(runtime, &events);
    try std.testing.expect(!hasEvent(events[0..ready], .control_writable));
}

test "a request_done waiting in the outbox makes the wait ask for room, and goes out once the socket has it" {
    var no_egress: ipc.egress_shared.RawFds = .{};
    var fixture: PollRuntime = undefined;
    try fixture.init(&no_egress);
    defer fixture.deinit();
    const runtime = &fixture.runtime;
    const backend: poll_backend.PollBackend = .{};
    var events: [poll_backend.events_max]poll_backend.Event = undefined;

    // A finished request whose packet found the socket full.
    try runtime.requests.done_outbox.push(.{
        .identity = .{ .request_id = 77, .request_generation = 5, .request_lane_id = 2, .request_slot = 9 },
        .stream_id = 11,
        .done = .{ .status = .ok, .http_status = 200, .cpu_ns = 900 },
    });

    var ready = try backend.drain(runtime, &events);
    try std.testing.expect(hasEvent(events[0..ready], .control_writable));

    try worker_testing.scheduler.loop.handleControlWritable(runtime);
    try std.testing.expect(runtime.requests.done_outbox.isEmpty());
    ready = try backend.drain(runtime, &events);
    try std.testing.expect(!hasEvent(events[0..ready], .control_writable));

    // The server reads the packet under the request's identity.
    var scratch: [4096]u8 = undefined;
    var packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, fixture.control_pair[1], &scratch);
    var received = try ipc.ingress_channel.decodeReceivedPacket(std.testing.allocator, &packet);
    defer received.deinit();
    try std.testing.expectEqual(@as(u8, @intFromEnum(ipc.ingress_channel.Op.request_done)), received.descriptor.op);
    try std.testing.expectEqual(@as(u64, 77), received.descriptor.request_id);
    try std.testing.expectEqual(@as(u64, 5), received.descriptor.request_generation);
    try std.testing.expectEqual(@as(u32, 11), received.descriptor.stream_id);
    const done = try ipc.ingress_channel.decodeRequestDone(received.payload);
    try std.testing.expectEqual(@as(u64, 900), done.cpu_ns);
    try std.testing.expectEqual(@as(u16, 200), done.http_status);
}

test "worker loop stops without error when the server hung up before the loop waits" {
    var no_egress: ipc.egress_shared.RawFds = .{};
    var fixture: PollRuntime = undefined;
    try fixture.init(&no_egress);
    defer fixture.deinit();

    // The socket reports the hangup at once, so the loop's non-blocking
    // drain meets it before any blocking wait.
    fixture.closeServerEnd();
    try worker_testing.scheduler.loop.run(&fixture.runtime);
}

test "the wait fails with the control peer closed when the server hangs up while a send waits for room" {
    var no_egress: ipc.egress_shared.RawFds = .{};
    var fixture: PollRuntime = undefined;
    try fixture.init(&no_egress);
    defer fixture.deinit();
    const runtime = &fixture.runtime;

    // A closed peer reports room and the hangup together, and the hangup
    // wins.
    runtime.requests.control_send_blocked = true;
    fixture.closeServerEnd();
    const backend: poll_backend.PollBackend = .{};
    var events: [poll_backend.events_max]poll_backend.Event = undefined;
    try std.testing.expectError(error.ControlPeerClosed, backend.wait(runtime, &events));
}

test "the wait reports the wakeup and payload credit eventfds once written, and not after their drain" {
    var no_egress: ipc.egress_shared.RawFds = .{};
    var fixture: PollRuntime = undefined;
    try fixture.init(&no_egress);
    defer fixture.deinit();
    const runtime = &fixture.runtime;
    const backend: poll_backend.PollBackend = .{};
    var events: [poll_backend.events_max]poll_backend.Event = undefined;

    runtime.wake();
    const one: u64 = 1;
    _ = try std.posix.write(fixture.credit_fd, std.mem.asBytes(&one));
    var ready = try backend.wait(runtime, &events);
    try std.testing.expect(hasEvent(events[0..ready], .wakeup_ready));
    try std.testing.expect(hasEvent(events[0..ready], .ingress_payload_credit_ready));

    runtime.drainWakeup();
    runtime.drainIngressPayloadCredit();
    ready = try backend.drain(runtime, &events);
    try std.testing.expect(!hasEvent(events[0..ready], .wakeup_ready));
    try std.testing.expect(!hasEvent(events[0..ready], .ingress_payload_credit_ready));
}

test "the wait returns at once with the deadline event for a deadline already due" {
    var no_egress: ipc.egress_shared.RawFds = .{};
    var fixture: PollRuntime = undefined;
    try fixture.init(&no_egress);
    defer fixture.deinit();
    const runtime = &fixture.runtime;

    // Nothing else is ready, so a wait that ignored the deadline would block
    // for good.
    const backend: poll_backend.PollBackend = .{ .deferred_backstop_deadline_ns = runtime.nowMonoNs() };
    var events: [poll_backend.events_max]poll_backend.Event = undefined;
    const ready = try backend.wait(runtime, &events);
    try std.testing.expect(hasEvent(events[0..ready], .timer_deadline));
}

test "the wait does not block while a gateway drain may have left packets past its batch bound" {
    var no_egress: ipc.egress_shared.RawFds = .{};
    var fixture: PollRuntime = undefined;
    try fixture.init(&no_egress);
    defer fixture.deinit();
    const runtime = &fixture.runtime;

    // The drain that stopped at its bound had drained the completion eventfd,
    // so nothing the wait watches is ready. A wait that blocked would sleep
    // until the deadline far ahead and report it.
    const backend: poll_backend.PollBackend = .{
        .egress_completion_debt = true,
        .deferred_backstop_deadline_ns = runtime.nowMonoNs() + 10 * std.time.ns_per_s,
    };
    var events: [poll_backend.events_max]poll_backend.Event = undefined;
    try std.testing.expectEqual(@as(usize, 0), try backend.wait(runtime, &events));
}

test "a session whose gateway hung up is reported closed at the next wait" {
    var wake_set = try ipc.egress_shared.WakeSet.create();
    defer wake_set.deinit();
    var session = try ipc.egress_shared.createSessionForWorker(&wake_set);
    defer session.deinit();
    // Taking the worker's half closes every gateway descriptor the session
    // held, the write end of the liveness pipe the worker watches among them,
    // so the worker sees its gateway gone.
    var worker_raw = session.takeWorkerHalf();
    defer worker_raw.close();
    var fixture: PollRuntime = undefined;
    try fixture.init(&worker_raw);
    defer fixture.deinit();
    const runtime = &fixture.runtime;
    try std.testing.expect(runtime.egress.state.shared != null);

    const backend: poll_backend.PollBackend = .{};
    var events: [poll_backend.events_max]poll_backend.Event = undefined;
    const ready = try backend.drain(runtime, &events);
    var closed_count: usize = 0;
    for (events[0..ready]) |event| {
        switch (event) {
            .egress_closed => |reason| {
                closed_count += 1;
                try std.testing.expectEqual(poll_backend.EgressClosedReason.liveness_hup, reason);
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 1), closed_count);
}

test "the wait watches the session an egress_attach brings from the next wait on" {
    // A worker booted without a session holds only its wake descriptors,
    // which the wait does not watch: the liveness pipe has no write end yet,
    // so a watch on the boot's read end would report a hangup at once.
    var wake_set = try ipc.egress_shared.WakeSet.create();
    defer wake_set.deinit();
    var boot_fds = ipc.egress_shared.RawFds.wakeOnly(try wake_set.openWorkerWake());
    defer boot_fds.close();
    var fixture: PollRuntime = undefined;
    try fixture.init(&boot_fds);
    defer fixture.deinit();
    const runtime = &fixture.runtime;
    try std.testing.expect(runtime.egress.state.shared == null);

    const backend: poll_backend.PollBackend = .{};
    var events: [poll_backend.events_max]poll_backend.Event = undefined;
    var ready = try backend.drain(runtime, &events);
    try std.testing.expect(!hasEvent(events[0..ready], .egress_closed));

    // A session on the worker's wake set whose gateway is already gone:
    // taking the worker's half closes the gateway's write end of the pipe
    // the worker watches.
    var session = try ipc.egress_shared.createSessionForWorker(&wake_set);
    defer session.deinit();
    var worker_half = session.takeWorkerHalf();
    defer worker_half.close();
    try ipc.egress_attach.send(fixture.control_pair[1], worker_half);
    try worker_testing.scheduler.loop.collectControlPacket(runtime);
    try std.testing.expect(runtime.egress.state.shared != null);

    ready = try backend.drain(runtime, &events);
    var closed_count: usize = 0;
    for (events[0..ready]) |event| {
        switch (event) {
            .egress_closed => |reason| {
                closed_count += 1;
                try std.testing.expectEqual(poll_backend.EgressClosedReason.liveness_hup, reason);
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 1), closed_count);
}

test "a worker without a network grant refuses an egress_attach, closes every descriptor it brought and watches none of them" {
    var no_egress: ipc.egress_shared.RawFds = .{};
    var fixture: PollRuntime = undefined;
    try fixture.init(&no_egress);
    defer fixture.deinit();
    const runtime = &fixture.runtime;
    try std.testing.expect(runtime.egress.state.grant() == .none);

    // The half's write end of the pipe a gateway watches is the pipe's only
    // write end once the test closes its own copy, so the pipe hangs up
    // exactly when the worker has closed the copy it received.
    var wake_set = try ipc.egress_shared.WakeSet.create();
    defer wake_set.deinit();
    var session = try ipc.egress_shared.createSessionForWorker(&wake_set);
    defer session.deinit();
    var worker_half = session.takeWorkerHalf();
    defer worker_half.close();
    try ipc.egress_attach.send(fixture.control_pair[1], worker_half);
    worker_half.close();

    try std.testing.expectError(error.EgressNotGranted, worker_testing.scheduler.loop.collectControlPacket(runtime));
    try std.testing.expect(runtime.egress.state.shared == null);
    var peer_liveness = [_]std.posix.pollfd{.{ .fd = wake_set.peer_liveness_read.fd(), .events = 0, .revents = 0 }};
    try std.testing.expectEqual(@as(usize, 1), try std.posix.poll(&peer_liveness, 0));
    try std.testing.expect((peer_liveness[0].revents & std.posix.POLL.HUP) != 0);

    // The session's gateway end is closed too, so a watch on its liveness
    // pipe would report a hangup.
    const backend: poll_backend.PollBackend = .{};
    var events: [poll_backend.events_max]poll_backend.Event = undefined;
    try std.testing.expectEqual(@as(usize, 0), try backend.drain(runtime, &events));
}

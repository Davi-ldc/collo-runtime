//! The worker's event loop on its VM thread: collecting ready work, pumping
//! the engine's deferred work, reading the control channel, and running one
//! work item per turn. Each work item runs in a window of its one owner, the
//! request or evaluation its queue slot names (`runtime/owner.zig`), which
//! charges it the item's CPU, lets the sentinel stop only that owner's
//! JavaScript and moves a request's timeline. A request that already spent
//! its CPU budget or passed its deadline is answered instead of running the
//! item's JavaScript, and one a window took past its budget is answered
//! after the item (`serve/termination.zig`). An fs fault item has no single
//! owner; its settle opens a window per waiter (`fs/fault_completion.zig`).
//! The deferred-work pump always runs under the worker owner.
//!
//! Each tick starts with the retirement check (`runtime/retirement.zig`): a
//! sentinel fire or a worker none of whose routes can serve sends the
//! server one `worker_retiring` notice, and the loop goes on serving until
//! the server closes the control channel. The loop returns when the control
//! channel hangs up or `core.running` turns false, which only a failure the
//! server's synthesis covers sets. An egress gateway that closes only
//! detaches the worker (`egress/gateway_runtime.zig`), and an
//! `egress_attach` packet on the control channel attaches it again. The
//! worker's end of the control channel does not block
//! (`zygote/child_boot.zig`): a response or a notice that finds it full
//! waits, and the loop sends it when the socket turns writable or the
//! payload ring gets room (`serve/response.zig`).

const std = @import("std");
const bindings = @import("collo_bindings");
const ipc = @import("collo_ipc");
const worker_limits = @import("collo_limits").worker;
const state = @import("../runtime/root.zig");
const runtime_owner = @import("../runtime/owner.zig");
const uring_backend = @import("uring_backend.zig");
const ready_queue = @import("queue.zig");
const immediates = @import("immediates.zig");
const timers = @import("timers.zig");
const request_dispatch = @import("../serve/dispatch.zig");
const termination = @import("../serve/termination.zig");
const response_body_stream = @import("../serve/response_body_stream.zig");
const egress_completion = @import("../egress/completion_runtime.zig");
const egress_gateway = @import("../egress/gateway_runtime.zig");
const exception_log = @import("collo_worker_js").exception_log;

/// Runs the loop until the control channel hangs up or `core.running` turns
/// false. Fails when the ring, a collector or the control channel fails.
pub fn run(runtime: *state.Runtime) !void {
    var backend = try uring_backend.UringBackend.init(runtime);
    defer backend.deinit();

    // JSC queues async wasm settlement (WebAssembly.instantiate and compile)
    // on its DeferredWorkTimer, which schedules through a RunLoop this worker
    // never runs. The wakeup eventfd replaces the RunLoop's wake: when the
    // wasm worklist thread schedules a settle task, it sets the gate's
    // pending flag and writes the eventfd, which a blocked ring wait sees as
    // `wakeup_ready`. The fd and the VM both exist here, so a failure is a
    // bug and fails the loop. `Runtime.deinit` unregisters the fd before the
    // scheduler closes it.
    if (runtime.scheduler.wakeup_fd) |wakeup_fd|
        try runtime.core.vm.setDeferredWorkWakeupFd(wakeup_fd);
    var deferred_pending_imminent = false;

    var egress_completion_debt = false;
    while (runtime.core.running) {
        runtime.scheduler.metrics.worker_loop_ticks += 1;
        // Two loads in the common case. A fire in the last tick's work item
        // answers the requests it stopped and sends the notice here, before
        // this tick reads any begin.
        runtime.checkRetirement() catch |err| switch (err) {
            error.ControlPeerClosed => return,
            else => return err,
        };
        // A body-pool release that failed inside a handler or a turn detaches
        // the worker here, where none runs. The wait below checks again
        // first, so a failure in this tick never waits for the next wake.
        runtime.detachEgressAfterFailedRelease();
        // A death record reads the live slot, so each tick publishes the CPU
        // used so far; a worker killed mid-request still accounts for the
        // windows it already ran.
        runtime.flushLiveRequestCpuBestEffort();
        try collectFast(runtime);
        if (!runtime.core.running)
            break;

        // With no deferred work the pump costs one atomic exchange on the
        // wakeup gate per tick. While imminent work is outstanding the
        // backstop deadline keeps the loop rechecking, so a settle whose
        // scheduling a termination cut short still runs instead of waiting
        // forever; the eventfd above is the normal signal.
        deferred_pending_imminent = pumpDeferredWork(runtime, deferred_pending_imminent);
        runtime.endSpentBudgets();
        backend.deferred_backstop_deadline_ns = if (deferred_pending_imminent)
            runtime.nowMonoNs() + uring_backend.deferred_work_backstop_ns
        else
            0;
        if (!runtime.core.running)
            break;

        if (egress_completion_debt and runtime.egress.state.shared != null) {
            egress_completion_debt = try runtime.collectEgressGatewayPacketsBounded(gatewayIpcDrainBatch(runtime));
        } else {
            egress_completion_debt = false;
        }
        if (!runtime.core.running)
            break;

        try backend.arm(runtime);
        var drained_events: [8]uring_backend.Event = undefined;
        const drained = backend.drain(runtime, &drained_events) catch |err| switch (err) {
            error.ControlPeerClosed => return,
            else => return err,
        };
        var drained_wakeup = false;
        for (drained_events[0..drained]) |event| {
            if (std.meta.activeTag(event) == .wakeup_ready)
                drained_wakeup = true;
            handleEvent(runtime, event, &egress_completion_debt) catch |err| switch (err) {
                error.ControlPeerClosed => return,
                else => return err,
            };
        }
        if (!runtime.core.running)
            break;
        // The deferred-work gate cannot lose a wake only if every drain of the
        // wakeup eventfd is followed by a pump before the loop blocks (see
        // `collo_vm_deferred_work_scheduled` in `bindings/jsc/runtime/vm.cpp`).
        // This tick's pump already ran, so a wakeup drained here sends the
        // loop back to the top; otherwise a settle scheduled between the pump
        // and this drain would wait until some unrelated event.
        if (drained_wakeup)
            continue;

        if (runtime.scheduler.ready_queue.pop()) |item| {
            try executeWorkItem(runtime, item);
            continue;
        }
        if (!runtime.core.running)
            break;

        // A settlement the drained events collected may have spent a
        // request's budget, and a fire in this tick's collect pass or pump
        // retires the worker now, not at the next wake.
        runtime.endSpentBudgets();
        runtime.checkRetirement() catch |err| switch (err) {
            error.ControlPeerClosed => return,
            else => return err,
        };
        // Published again before blocking, so the CPU of this tick's windows
        // is not lost if the worker is killed during the wait.
        runtime.flushLiveRequestCpuBestEffort();
        runtime.detachEgressAfterFailedRelease();
        backend.idle_cache_release_deadline_ns = idleCacheReleaseDeadline(runtime);
        try backend.arm(runtime);
        var events: [8]uring_backend.Event = undefined;
        const ready = backend.wait(runtime, &events) catch |err| switch (err) {
            error.ControlPeerClosed => return,
            else => return err,
        };
        releaseIdleThreadCache(runtime);
        backend.idle_cache_release_deadline_ns = 0;
        if (ready == 0)
            continue;

        for (events[0..ready]) |event|
            handleEvent(runtime, event, &egress_completion_debt) catch |err| switch (err) {
                error.ControlPeerClosed => return,
                else => return err,
            };
        if (!runtime.core.running)
            break;
    }
}

/// When the blocked loop must wake to release the VM thread's allocator
/// cache: `thread_cache_idle_release_ns` after its last owner window ended,
/// or 0 when the cache is already released. The worker's seccomp filter
/// denies the signals libpas suspends an idle thread with, so the thread
/// stops its own allocators after the same idle time; otherwise the
/// scavenger polls for the worker's life (`common/limits/worker.zig`). Idle
/// means no owner's work, not no live request: a request parked on a slow
/// fetch leaves the thread just as idle.
fn idleCacheReleaseDeadline(runtime: *const state.Runtime) u64 {
    if (runtime.owners.thread_cache_released)
        return 0;
    return runtime.owners.idle_since_mono_ns +| worker_limits.thread_cache_idle_release_ns;
}

/// Releases the VM thread's allocator cache once it has been idle long
/// enough (`idleCacheReleaseDeadline`), at most once per idle stretch.
fn releaseIdleThreadCache(runtime: *state.Runtime) void {
    if (runtime.owners.thread_cache_released or runtime.owners.current_id != 0)
        return;
    if (runtime.nowMonoNs() < idleCacheReleaseDeadline(runtime))
        return;
    bindings.releaseThreadAllocatorCache();
    runtime.owners.thread_cache_released = true;
}

fn handleEvent(
    runtime: *state.Runtime,
    event: uring_backend.Event,
    egress_completion_debt: *bool,
) !void {
    switch (event) {
        .control_ready => collectControlPacket(runtime) catch |err| switch (err) {
            error.ControlPeerClosed => return error.ControlPeerClosed,
            else => return err,
        },
        .control_writable => try flushParkedResponses(runtime),
        .wakeup_ready => {
            runtime.drainWakeup();
            try collectFast(runtime);
        },
        .egress_completion_ready => {
            if (runtime.egress.state.shared) |*endpoint|
                ipc.egress_shared.drainEventfd(endpoint.completion_eventfd);
            if (runtime.egress.state.shared != null)
                egress_completion_debt.* = try runtime.collectEgressGatewayPacketsBounded(gatewayIpcDrainBatch(runtime));
        },
        .egress_closed => |reason| runtime.disconnectEgressGatewayWithReason(@tagName(reason)),
        .ingress_payload_credit_ready => {
            runtime.drainIngressPayloadCredit();
            try flushParkedResponses(runtime);
        },
        .fs_fault_ready => try runtime.collectFsFaultResponse(),
        .timer_deadline => try collectFast(runtime),
    }
}

/// Sends what the requests' outboxes hold (`serve/response.zig`), then a
/// retirement notice that found the socket full (`runtime/retirement.zig`).
/// A send that finds the server gone fails with `error.ControlPeerClosed`,
/// which stops the loop as a hangup seen by a control poll does; the server
/// may close between a poll's report and the send.
pub fn flushParkedResponses(runtime: *state.Runtime) !void {
    runtime.flushPendingIngressResponses() catch |err| switch (err) {
        error.PeerClosed => return error.ControlPeerClosed,
        else => return err,
    };
    try runtime.sendRetirementNotice();
}

fn gatewayIpcDrainBatch(runtime: *const state.Runtime) usize {
    return if (runtime.scheduler.ready_queue.isEmpty())
        uring_backend.gateway_ipc_drain_batch_body_heavy
    else
        uring_backend.gateway_ipc_drain_batch_interactive;
}

fn collectFast(runtime: *state.Runtime) !void {
    runtime.drainReadyBacklog();
    runtime.collectModuleSettlements();
    try runtime.collectCompletedCryptoJobs();
    try runtime.collectCompletedFetches();
    try runtime.collectReadyFetchBodies();
    runtime.collectReadyIngressRequests();
    runtime.collectReadyRequestCompletions();
    runtime.collectFsFaultCompletions();
    try runtime.collectDueTimers();
    try runtime.collectReadyImmediates();
    try runtime.collectDueRequestDeadlines();
}

/// The ring a request descriptor's payload may sit in, with the eventfd its
/// release signals when a lane marked the ring waiting for room: the
/// completion eventfd, which the worker's reader lane polls already, so a
/// lane parked on the ring needs no poll of its own
/// (`server/ingress/runner/request_body.zig`).
fn requestPayloadReaders(
    runtime: *state.Runtime,
    ingress_payload: *ipc.ingress_channel.SharedPayloadView,
) ipc.ingress_channel.SharedPayloadReaders {
    return .{
        .server_to_worker = ingress_payload,
        .server_to_worker_credit_eventfd = runtime.egress.completion_eventfd,
    };
}

/// Takes one packet from the control socket: the ingress descriptors it
/// carries join the request queue, and an `egress_attach` attaches the worker
/// to the session it brings. Call it once each time the read poll reports
/// input: the worker's end of the socket does not block, so a call that
/// finds no packet fails with `error.WouldBlock`. Fails with
/// `error.ControlPeerClosed` once the server hangs up, and with the decode's
/// or the attach's error for a packet the worker cannot take, which ends the
/// loop.
pub fn collectControlPacket(runtime: *state.Runtime) !void {
    const control_fd = runtime.core.control_fd orelse return;
    var packet = ipc.recvPacketWithFdsScratch(runtime.core.allocator, control_fd, runtime.core.dispatch_recv_scratch) catch |err| switch (err) {
        error.PeerClosed => return error.ControlPeerClosed,
        else => return err,
    };
    var packet_alive = true;
    errdefer if (packet_alive)
        packet.deinit();
    const kind = if (packet.bytes.len >= @sizeOf(u32))
        ipc.decodeMessageKind(ipc.packet.readStruct(u32, packet.bytes[0..@sizeOf(u32)])) catch return error.InvalidMessageKind
    else
        return error.ShortRead;
    switch (kind) {
        .ingress_channel => {
            // Ingress decoders always deinit the packet, including error paths,
            // so ownership must be transferred before the fallible decode call.
            packet_alive = false;
            if (ipc.ingress_channel.isDescriptorBatchPacket(packet.bytes)) {
                var batch = if (runtime.requests.ingress_payload) |*ingress_payload|
                    try ipc.ingress_channel.decodeReceivedBatchPacketWithSharedPayload(
                        runtime.core.allocator,
                        &packet,
                        requestPayloadReaders(runtime, ingress_payload),
                    )
                else
                    try ipc.ingress_channel.decodeReceivedBatchPacket(runtime.core.allocator, &packet);
                defer batch.deinit();
                for (0..batch.items.len) |index| {
                    const received = batch.take(index);
                    try runtime.enqueueIngressDescriptor(received);
                }
            } else {
                const received = if (runtime.requests.ingress_payload) |*ingress_payload|
                    try ipc.ingress_channel.decodeReceivedPacketWithSharedPayload(
                        runtime.core.allocator,
                        &packet,
                        requestPayloadReaders(runtime, ingress_payload),
                    )
                else
                    try ipc.ingress_channel.decodeReceivedPacket(runtime.core.allocator, &packet);
                try runtime.enqueueIngressDescriptor(received);
            }
        },
        .egress_attach => {
            // `decode` takes the descriptors only on success; on failure they
            // stay in the packet, whose errdefer deinit closes them. A half
            // that does not map is a server bug, and its error leaves the
            // loop as a malformed control packet's does.
            var fds = try ipc.egress_attach.decode(&packet);
            packet.deinit();
            packet_alive = false;
            defer fds.close();
            var egress_ctx = runtime.egressContext();
            try egress_gateway.attach(&egress_ctx, &fds);
        },
        else => {
            packet.deinit();
            packet_alive = false;
            return error.InvalidMessageKind;
        },
    }
}

/// Runs one work item, the one the ready queue popped last, as a turn in a
/// window of its owner: the request or evaluation its queue slot names,
/// resolved when it was queued because the handler maps may no longer hold
/// the entry (`readyItemOwnerRequestId`). The turn consumes the ready item
/// that enqueue counted. An item with no owner, an fs fault completion or
/// one whose entry was gone at enqueue, opens no window. A request owner
/// that already reached an ending, its CPU budget spent or its deadline
/// passed, is answered first, and the item then runs with its request
/// finished, which only releases what the item held. A request a window of
/// the item took past its budget is answered after it. Each handler's
/// failure is answered or logged per item and never ends the loop.
pub fn executeWorkItem(runtime: *state.Runtime, item: ready_queue.WorkItem) !void {
    const owner_id = runtime.scheduler.ready_queue.last_popped_meta.owner_request_id;
    runtime.scheduler.ready_queue.last_popped_meta = .{};
    if (owner_id != 0) {
        const previous_owner_id = runtime_owner.enter(runtime, owner_id, .{ .consumes_ready_item = true });
        defer runtime_owner.leave(runtime, previous_owner_id);
        termination.endAtBoundary(runtime, owner_id);
        runItem(runtime, item);
    } else {
        runItem(runtime, item);
    }
    runtime.endSpentBudgets();
}

fn runItem(runtime: *state.Runtime, item: ready_queue.WorkItem) void {
    switch (item) {
        .request => |request_id| request_dispatch.execute(runtime, request_id) catch |err|
            request_dispatch.handleLocalFailure(runtime, request_id, err),
        .timer_callback => |timer_id| timers.executeCallback(runtime, timer_id) catch |err|
            std.log.warn("timer callback failed timer_id={d}: {s}", .{ timer_id, @errorName(err) }),
        .immediate_callback => |immediate_id| immediates.executeCallback(runtime, immediate_id) catch |err|
            std.log.warn("immediate callback failed immediate_id={d}: {s}", .{
                immediate_id,
                @errorName(err),
            }),
        .request_completion => |token| request_dispatch.executeCompletion(runtime, token) catch |err|
            request_dispatch.handleCompletionFailure(runtime, token, err),
        .request_body_ready => |request_id| request_dispatch.executeBodyReady(runtime, request_id) catch |err|
            request_dispatch.handleLocalFailure(runtime, request_id, err),
        .request_cancelled => |request_id| request_dispatch.cancelClientReset(runtime, request_id) catch |err|
            request_dispatch.handleLocalFailure(runtime, request_id, err),
        .request_deadline => |request_id| request_dispatch.deadlineTimeout(runtime, request_id) catch |err|
            request_dispatch.handleLocalFailure(runtime, request_id, err),
        .fetch_completion => |fetch_id| {
            var egress_ctx = runtime.egressContext();
            egress_completion.execute(&egress_ctx, fetch_id) catch |err|
                egress_completion.handleFailure(&egress_ctx, fetch_id, err);
        },
        .fetch_body_ready => |body_id| runtime.executeFetchBodyReady(body_id) catch |err|
            runtime.handleFetchBodyReadyFailure(body_id, err),
        .fs_fault_completion => |fault_id| runtime.executeFsFaultCompletion(fault_id) catch |err|
            runtime.handleFsFaultCompletionFailure(fault_id, err),
        .response_body_stream => |request_id| response_body_stream.execute(runtime, request_id) catch |err|
            request_dispatch.handleLocalFailure(runtime, request_id, err),
    }
}

/// Runs every ready deferred settle task, such as an async wasm promise
/// settlement, as one turn, and returns whether imminent deferred work is
/// still outstanding: a compile running on the worklist thread, or a settle
/// stranded by a pass cut short. The caller keeps the backstop deadline
/// armed while it returns true.
///
/// The JSC ticket carries no owner, because its script execution owner is
/// the shared global object, so no single request or evaluation owns a
/// settle: one can outlive the code that started it, and handing it to the
/// only live request would spend that stranger's deadline, CPU and egress
/// identity. Every settle therefore runs on the worker owner's exec context
/// (`runtime/owner.zig`), which charges no request and which no host call
/// that needs an active owner accepts, and under the worker owner's wall
/// limit, so a settle continuation that never yields is stopped by the
/// sentinel. A reaction in it whose registrant is still open runs restored
/// to that registrant, under its limits.
pub fn pumpDeferredWork(runtime: *state.Runtime, pending_imminent: bool) bool {
    const vm = runtime.core.vm;
    // Always consume the gate, even on a backstop-driven pass: a flag raced
    // in for work this pass is about to run would otherwise buy one extra
    // no-op pump next tick.
    const scheduled = vm.deferredWorkScheduled();
    if (!pending_imminent and !scheduled)
        return false;

    // A deferred settle has no popped slot, so no request executes in the
    // timeline while it runs: its duration falls in each live request's open
    // slice, as waiting or I/O (`worker/request/context.zig`).
    const exec_ctx = &runtime.owners.worker_exec;
    const previous_owner_id = runtime_owner.enter(runtime, exec_ctx.request_id, .{});
    defer runtime_owner.leave(runtime, previous_owner_id);

    var pump_state = bindings.DeferredWorkState.none;
    const result = vm.pumpDeferredWork(exec_ctx, &pump_state) catch |err| {
        std.log.warn("deferred work pump failed: {s}", .{@errorName(err)});
        return false;
    };
    switch (result) {
        .success => {},
        .exception => |exception| {
            var owned = exception;
            defer owned.deinit();
            exception_log.logException(vm, exec_ctx.request_id, &owned, "deferred work settle");
        },
    }
    return pump_state.pending_imminent;
}

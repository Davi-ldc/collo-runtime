//! The worker's event loop on its VM thread: collecting ready work, pumping
//! the engine's deferred work, reading the control channel, and running one
//! work item per turn. Each turn publishes its owning request to the
//! sentinel and records turn telemetry for a request; the two attributions
//! differ for timer and immediate turns (`turnOwnerRequestId`). A fault turn
//! has no single owner in either; its settle publishes each waiter's request
//! per sub-turn (`fs/fault_completion.zig`). The loop returns when the
//! control channel hangs up or `core.running` turns false. An egress gateway
//! that closes only detaches the worker (`egress/gateway_runtime.zig`), and
//! an `egress_attach` packet on the control channel attaches it again. The
//! worker's end of the control channel does not block
//! (`zygote/child_boot.zig`): a response send that finds it full parks in
//! its request's outbox, and the loop flushes the outboxes when the socket
//! turns writable or the payload ring gets room (`serve/response.zig`).

const std = @import("std");
const bindings = @import("collo_bindings");
const ipc = @import("collo_ipc");
const state = @import("../runtime/root.zig");
const uring_backend = @import("uring_backend.zig");
const ready_queue = @import("queue.zig");
const immediates = @import("immediates.zig");
const timers = @import("timers.zig");
const request_dispatch = @import("../serve/dispatch.zig");
const egress_completion = @import("../egress/completion_runtime.zig");
const egress_gateway = @import("../egress/gateway_runtime.zig");
const scheduler_resources = @import("resources.zig");
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
    // The request-less exec context of deferred-work turns after boot (see
    // `pumpDeferredWork`).
    var host_pump_exec_ctx = bindings.ExecCtx.init(0);
    var deferred_pending_imminent = false;

    var egress_completion_debt = false;
    while (runtime.core.running) {
        runtime.scheduler.metrics.worker_loop_ticks += 1;
        // A body-pool release that failed inside a handler or a turn detaches
        // the worker here, where none runs. The wait below checks again
        // first, so a failure in this tick never waits for the next wake.
        runtime.detachEgressAfterFailedRelease();
        // A death record reads the live slot, so each tick publishes the CPU
        // used so far; a worker killed mid-request still accounts for the
        // turns it already ran.
        runtime.flushLiveRequestCpuBestEffort();
        try collectFast(runtime);
        if (!runtime.core.running)
            break;

        // With no deferred work the pump costs one atomic exchange on the
        // wakeup gate per tick. While imminent work is outstanding the
        // backstop deadline keeps the loop rechecking, so a settle whose
        // scheduling a termination cut short still runs instead of waiting
        // forever; the eventfd above is the normal signal.
        deferred_pending_imminent = pumpDeferredWork(
            runtime,
            &host_pump_exec_ctx,
            deferred_pending_imminent,
        );
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

        // A failed module evaluation, or a deadline fire that left the VM
        // terminated, stops the loop only here and only once no queued work
        // or live request remains, so every parked request has been answered
        // by this worker before it stops.
        runtime.maybeRecycleAfterFailedEvaluation();
        if (!runtime.core.running)
            break;

        // Published again before blocking, so the CPU of this tick's turns
        // is not lost if the worker is killed during the wait.
        runtime.flushLiveRequestCpuBestEffort();
        runtime.detachEgressAfterFailedRelease();
        try backend.arm(runtime);
        var events: [8]uring_backend.Event = undefined;
        const ready = backend.wait(runtime, &events) catch |err| switch (err) {
            error.ControlPeerClosed => return,
            else => return err,
        };
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

/// Sends what the requests' outboxes hold (`serve/response.zig`). A send
/// that finds the server gone fails with `error.ControlPeerClosed`, which
/// stops the loop as a hangup seen by a control poll does; the server may
/// close between a poll's report and the send.
pub fn flushParkedResponses(runtime: *state.Runtime) !void {
    runtime.flushPendingIngressResponses() catch |err| switch (err) {
        error.PeerClosed => return error.ControlPeerClosed,
        else => return err,
    };
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

/// Runs one work item as a turn: publishes its owner to the sentinel,
/// records its telemetry and hands it to its handler. Each handler's failure
/// is answered or logged per item and never ends the loop.
pub fn executeWorkItem(runtime: *state.Runtime, item: ready_queue.WorkItem) !void {
    beginTurnTelemetry(runtime, item);
    defer finishTurnTelemetry(runtime);
    scheduler_resources.publishTurnOwner(runtime, turnOwnerRequestId(runtime, item));
    defer scheduler_resources.clearTurnOwner(runtime);
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
    }
}

/// Runs every ready deferred settle task, such as an async wasm promise
/// settlement, as one turn, and returns whether imminent deferred work is
/// still outstanding: a compile running on the worklist thread, or a settle
/// stranded by a pass cut short. The caller keeps the backstop deadline
/// armed while it returns true.
///
/// The JSC ticket carries no request identity, because its script execution
/// owner is the shared global object, so the turn's owner is never inferred
/// from the requests that happen to be live. A settle can outlive the
/// request that started it, and handing it to the only live request would
/// spend that stranger's deadline, CPU and egress identity. While the boot
/// context exists the settle runs under it, which is sound because a worker
/// has one boot, registered under the reserved boot id, and boot-time code is
/// what produces these settles; its exec context carries the boot's deadline
/// and CPU, and its id feeds the sentinel's owner gate. After the boot
/// context closes, every settle runs under the request-less host context
/// with owner 0, so request-scoped host calls from it fail.
///
/// FIXME: a settle continuation that hangs after boot runs outside the
/// sentinel's owner gate, since no deadline matches owner 0, so no request
/// deadline can stop it; only the host killing the worker bounds it, and its
/// CPU is charged to no request. Closing the gap needs the JSC ticket to
/// carry an owner {request_id, generation}; the loop cannot infer one.
pub fn pumpDeferredWork(
    runtime: *state.Runtime,
    host_exec_ctx: *bindings.ExecCtx,
    pending_imminent: bool,
) bool {
    const vm = runtime.core.vm;
    // Always consume the gate, even on a backstop-driven pass: a flag raced
    // in for work this pass is about to run would otherwise buy one extra
    // no-op pump next tick.
    const scheduled = vm.deferredWorkScheduled();
    if (!pending_imminent and !scheduled)
        return false;

    var owner: u64 = 0;
    var exec_ctx: *bindings.ExecCtx = host_exec_ctx;
    if (runtime.bootContext()) |boot_ctx| {
        owner = boot_ctx.exec.request_id;
        exec_ctx = &boot_ctx.exec;
    }

    scheduler_resources.publishTurnOwner(runtime, owner);
    defer scheduler_resources.clearTurnOwner(runtime);
    runtime.scheduler.executing_turn_request_id = owner;
    // A deferred settle has no popped slot, so no request executes in the
    // timeline while it runs: its duration falls in each live request's open
    // slice, as waiting or I/O (`worker/request/context.zig`).
    runtime.scheduler.executing_turn_real_owner = 0;
    runtime.scheduler.turn_started_mono_ns = runtime.nowMonoNs();
    runtime.scheduler.turn_queued_wait_ns = 0;
    defer finishTurnTelemetry(runtime);

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
            exception_log.logException(vm, owner, &owned, "deferred work settle");
        },
    }
    return pump_state.pending_imminent;
}

/// The request the sentinel treats as the turn's owner. It differs from the
/// telemetry attribution in `beginTurnTelemetry`, which counts timer and
/// immediate turns as no request's because their duration shows up as other
/// requests' queued time: the sentinel needs a callback turn's owning
/// request too, or a hung callback could never be stopped, since its
/// deadline would never match the published owner.
fn turnOwnerRequestId(runtime: *state.Runtime, item: ready_queue.WorkItem) u64 {
    // The resolver the enqueue used, called before the work item removes
    // its entry from the handler maps. A fault completion resolves to 0
    // because it spans several requests; its settle publishes each waiter's
    // request per sub-turn instead (`fs/fault_completion.zig`).
    return runtime.readyItemOwnerRequestId(item);
}

/// Attributes the turn to its owning request before it runs. A request's
/// completed record carries its queued time and longest turn
/// (`CompletedRecord` in `common/worker_state/page/usage_records.zig`), and
/// `finishRequest` must find the request's final turn while it writes that
/// record in the middle of it.
fn beginTurnTelemetry(runtime: *state.Runtime, item: ready_queue.WorkItem) void {
    const scheduler = &runtime.scheduler;
    const now = runtime.nowMonoNs();
    const meta = scheduler.ready_queue.last_popped_meta;
    scheduler.ready_queue.last_popped_meta = .{};
    scheduler.turn_started_mono_ns = now;
    scheduler.turn_queued_wait_ns = if (meta.enqueued_mono_ns != 0 and now > meta.enqueued_mono_ns)
        now - meta.enqueued_mono_ns
    else
        0;
    // The slot's owner, resolved at enqueue because the handler maps may no
    // longer hold the entry, starts executing in the io/waiting timeline and
    // consumes the ready item its enqueue counted.
    scheduler.executing_turn_real_owner = meta.owner_request_id;
    if (meta.owner_request_id != 0) {
        if (runtime.requests.active.get(meta.owner_request_id)) |request_ctx|
            request_ctx.noteTurnBegin(now, true);
    }
    scheduler.executing_turn_request_id = switch (item) {
        .request,
        .request_body_ready,
        .request_cancelled,
        .request_deadline,
        => |request_id| request_id,
        .request_completion => |token| if (runtime.requests.tasks.get(token)) |task|
            task.request_id
        else
            0,
        .fetch_completion => |fetch_id| if (runtime.egress.state.tasks.get(fetch_id)) |task|
            task.request_id
        else
            0,
        .fetch_body_ready => |body_id| if (runtime.egress.state.bodies.get(body_id)) |body|
            body.identity.request_id
        else
            0,
        // Timer and immediate turns count as no request's; their duration
        // still shows up as other requests' queued time. A fault settle can
        // span several requests, so it has no single owner either.
        .timer_callback, .immediate_callback, .fs_fault_completion => 0,
    };
}

fn finishTurnTelemetry(runtime: *state.Runtime) void {
    const scheduler = &runtime.scheduler;
    const request_id = scheduler.executing_turn_request_id;
    const real_owner = scheduler.executing_turn_real_owner;
    const started_ns = scheduler.turn_started_mono_ns;
    const queued_ns = scheduler.turn_queued_wait_ns;
    scheduler.executing_turn_request_id = 0;
    scheduler.executing_turn_real_owner = 0;
    scheduler.turn_started_mono_ns = 0;
    scheduler.turn_queued_wait_ns = 0;
    const now = runtime.nowMonoNs();
    // The slot's owner leaves the executing state. A request that finished
    // during this turn is gone from the table, and `noteFinish` already
    // sealed its timeline.
    if (real_owner != 0) {
        if (runtime.requests.active.get(real_owner)) |request_ctx|
            request_ctx.noteTurnEnd(now);
    }
    if (request_id == 0 or started_ns == 0)
        return;
    // A request that finished during this turn is gone from the table here;
    // finishRequest already folded the partial turn into its record.
    const request_ctx = runtime.requests.active.get(request_id) orelse return;
    request_ctx.max_turn_ns = @max(request_ctx.max_turn_ns, now - started_ns);
    request_ctx.queued_ns_total +|= queued_ns;
}

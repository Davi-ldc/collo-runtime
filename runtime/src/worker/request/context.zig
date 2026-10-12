//! Per-request worker state: the decoded `DispatchWork`, the request's body
//! pipe and pending response bytes, the execution context the engine bridge
//! reads, and the time, CPU and byte counts the request's completed record
//! reports. A context belongs to the worker's VM thread, lives in the
//! runtime's active map under its request id, and dies only in
//! `Runtime.destroyRequestContext`.
//!
//! Every identity a context carries comes from the host's dispatch: request
//! id, generation, lane slot and worker. The worker adds none of its own to
//! what it publishes. The one context not built from a dispatch is an
//! evaluation's (`RequestContext.initEvaluation`), which owns a route
//! module's top-level code.
//!
//! The id space is shared with the engine bridge (`COLLO_REQUEST_ID_MAX` in
//! `abi.h`). Dispatched ids count up from 1 and stay at or below
//! `request_id_max`; the ids above it are reserved for the owners that are
//! not requests: one evaluation per route index of the definition, then the
//! worker owner at the top (`runtime/owner.zig`). 0 means no request
//! everywhere an id is read.

const std = @import("std");
const bindings = @import("collo_bindings");
const ipc = @import("collo_ipc");
const limits = @import("collo_limits");
const worker_metrics_state = @import("collo_worker_state").metrics;
const body = @import("incoming_body/pipe.zig");
const request_head = @import("head.zig");
const request_task = @import("task.zig");
const response_outbox = @import("ingress/response_outbox.zig");
const response_stream = @import("response_stream.zig");

pub const BodyReadKind = body.ReadKind;
pub const BodyWaiter = body.Waiter;

/// The request body as it arrives on the ingress channel, materialized in a
/// pipe bounded by `MATERIALIZED_BODY_BYTES_MAX`.
pub const IncomingBody = struct {
    pipe: body.Pipe = .{},
    initialized: bool = false,

    pub fn initFromHead(
        self: *IncomingBody,
        allocator: std.mem.Allocator,
        head: *request_head.ParsedHead,
    ) !void {
        try self.initFromIngressFraming(allocator, head.body_framing, head.body_framing == .none);
    }

    /// A request with no body framing must end its stream with the head;
    /// anything else fails with `error.InvalidDispatchRequestHead`.
    pub fn initFromIngressFraming(
        self: *IncomingBody,
        allocator: std.mem.Allocator,
        framing: ipc.RequestBodyFraming,
        end_stream: bool,
    ) !void {
        self.deinit(allocator);
        const initial_pipe_state: body.State = switch (framing) {
            .none => .empty,
            .ingress_channel => if (end_stream) .empty else .open,
        };
        var pipe = body.Pipe.init(allocator, limits.http_body.MATERIALIZED_BODY_BYTES_MAX, initial_pipe_state);
        errdefer pipe.deinit();

        if (framing == .none and !end_stream)
            return error.InvalidDispatchRequestHead;

        self.* = .{
            .pipe = pipe,
            .initialized = true,
        };
        pipe = .{};
    }

    pub fn deinit(self: *IncomingBody, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.pipe.deinit();
        self.* = .{};
    }

    pub fn beginRead(
        self: *IncomingBody,
        allocator: std.mem.Allocator,
        waiter: BodyWaiter,
    ) !void {
        if (self.pipe.used or self.pipe.hasPendingWaiter())
            return error.RequestBodyAlreadyUsed;
        _ = allocator;
        try self.pipe.beginConsume(waiter);
    }

    pub fn takeWaiter(self: *IncomingBody) ?BodyWaiter {
        return self.pipe.takeWaiter();
    }

    pub fn rollbackWaiterForScheduleFailure(self: *IncomingBody) void {
        self.pipe.rollbackPendingConsume();
    }

    pub fn isUsed(self: *const IncomingBody) bool {
        return self.pipe.used;
    }

    pub fn isInitialized(self: *const IncomingBody) bool {
        return self.initialized;
    }

    pub fn hasWaiter(self: *const IncomingBody) bool {
        return self.pipe.hasPendingWaiter();
    }

    pub fn isComplete(self: *const IncomingBody) bool {
        return self.pipe.isComplete();
    }

    /// Bytes past the pipe's bound fail with `error.RequestTooLarge`.
    pub fn appendH2ReadBytes(self: *IncomingBody, allocator: std.mem.Allocator, bytes: []const u8, end_stream: bool) !void {
        _ = allocator;
        if (!self.initialized)
            return error.RequestBodyNotInitialized;
        if (self.isComplete())
            return;
        if (bytes.len != 0) {
            self.pipe.pushBytes(bytes) catch |err| switch (err) {
                error.MaxBufferExceeded => return error.RequestTooLarge,
                else => return err,
            };
        }
        if (end_stream)
            self.pipe.finish();
    }

    pub fn textSlice(self: *const IncomingBody) []const u8 {
        return self.pipe.textSlice();
    }
};

/// The largest id a dispatched request may carry. Every id above it names an
/// owner that is not a request, so the bridge charges it no per-request
/// console budget and the worker refuses a dispatch that carries one
/// (`request/http2/ingress.zig`).
pub const request_id_max: u64 = worker_owner_id - evaluation_count - 1;

/// One evaluation id per route a definition may hold.
pub const evaluation_count: u64 = limits.server.routes_per_definition_max;

/// The id of the evaluation of the route at index 0; the route at index `i`
/// gets `evaluation_id_first + i` (`evaluationId`). Routes that share a
/// module instance share the evaluation of the route that started it.
pub const evaluation_id_first: u64 = request_id_max + 1;

/// The worker owner's id, the top of the id space: JavaScript that neither a
/// request nor an open evaluation owns (`runtime/owner.zig`).
pub const worker_owner_id: u64 = std.math.maxInt(u64);

comptime {
    // The bridge reserves the same range (`COLLO_REQUEST_ID_MAX` in
    // `abi.h`), so both sides agree on which ids are requests.
    std.debug.assert(request_id_max == bindings.request_id_max);
    std.debug.assert(evaluation_id_first == bindings.request_id_max + 1);
    // One evaluation id per route index, and none of them the worker owner's.
    std.debug.assert(evaluation_id_first + evaluation_count == worker_owner_id);
}

/// Whether `id` names an owner that is not a dispatched request: an
/// evaluation or the worker owner.
pub fn isReservedId(id: u64) bool {
    return id > request_id_max;
}

/// Whether `id` names an evaluation.
pub fn isEvaluationId(id: u64) bool {
    return id > request_id_max and id < worker_owner_id;
}

/// The evaluation id of the route at `route_index` in the definition's route
/// table, which holds at most `routes_per_definition_max` routes.
pub fn evaluationId(route_index: usize) u64 {
    std.debug.assert(route_index < evaluation_count);
    return evaluation_id_first + @as(u64, @intCast(route_index));
}

pub const RequestContext = struct {
    exec: bindings.ExecCtx,
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    /// Allocated from the base allocator by the IPC decode, not from `arena`;
    /// `deinit` frees it before the arena.
    dispatch_work: ipc.DispatchWork,
    live_slot_index: worker_metrics_state.LiveSlotHandle,
    started_mono_ns: u64,
    io_time_ns: u64,
    /// Time the request had work ready that the worker did not run, because
    /// another request's turn ran, the loop was draining or the queue was
    /// deep. Disjoint from `io_time_ns`, because the two states exclude each
    /// other (`noteReady`).
    waiting_ns: u64,
    /// Work items of this request in the ready queue or its backlog, counted
    /// at enqueue from the owner the slot carries. Zero while the request is
    /// not executing means it waits on I/O.
    ready_items: u32,
    /// A window of this request is open (`runtime/owner.zig`): a work item
    /// it owns, an fs fault waiter's or crypto settlement's sub-turn, or a
    /// reaction it registered that runs inside another owner's drain.
    executing_turn: bool,
    /// `noteFinish` ran and the timeline is closed. Every transition is a
    /// no-op from here on, so neither a context kept after a failed finish
    /// nor a late event can add time to it.
    timeline_sealed: bool,
    /// Start of the current stretch without a turn of this request, reset
    /// at every turn end. Readiness stamped earlier is clamped to it: a
    /// producer stamp taken inside the request's own turn must not turn
    /// execution into waiting time. Within one stretch the state only moves
    /// from I/O to runnable, so [this, `state_since_ns`] is always I/O time
    /// and safe to move.
    nonexec_since_ns: u64,
    /// Start of the current I/O, waiting or executing slice. Valid from
    /// request start on, never a sentinel.
    state_since_ns: u64,
    /// The request's CPU: the VM thread's over this context's owner windows
    /// (`runtime/owner.zig`), closed windows only, plus the crypto pool's
    /// over its jobs, added when each settles (`js/crypto/runtime.zig`).
    /// `finishRequest` folds the window it runs in before it reads the total.
    cpu_ns: u64,
    /// The CPU `cpu_ns` may reach, its definition's `cpuMs`, copied at the
    /// decode of a dispatched request (`ingress/runtime.zig`); 0 for none,
    /// as for every evaluation.
    cpu_budget_ns: u64,
    /// `cpu_ns` reached `cpu_budget_ns`. Set once, by the charge that got
    /// there (`owner.chargeContext`); the request then runs no more of its
    /// JavaScript and answers 503 (`serve/termination.zig`).
    cpu_spent: bool,
    /// The worker had asked to retire when this request's begin arrived
    /// (`runtime/retirement.zig`), so it answers 503 `worker_retiring`
    /// without running JavaScript.
    arrived_retiring: bool,
    /// Response body bytes this request handed to the host for its client.
    client_served_bytes: u64,
    /// HTTP payload this request's fetches sent and received, and the
    /// ciphertext they moved, accumulated from the fetch body meters
    /// (`EgressMeters` in `egress/core/fetch_body.zig`).
    fetch_billed_sent_bytes: u64,
    fetch_billed_received_bytes: u64,
    fetch_cost_bytes: u64,
    /// Fetches this request started, finished or not. `fetch_runtime.schedule`
    /// in `worker/egress/` holds it to `RuntimeLimits.max_fetches_per_request`,
    /// which is never above the fetch budget of the request's egress token,
    /// since the gateway spends that budget on every fetch it admits. It stays
    /// 0 in an evaluation's context: the evaluations share the boot token, so
    /// their fetches count in `Evaluations.boot_fetches_started`.
    egress_fetches_started: u64,
    body: IncomingBody,
    /// The source a streamed response pulls from, from its head until it
    /// ends: a fetch body or a ReadableStream (`response_stream.zig`).
    response_stream: response_stream.Source,
    response_outbox: response_outbox.Outbox,
    response_credit: ipc.response_credit.Window = .{},
    response_advance: response_stream.Advance = .{},
    response_done_status: ipc.RequestDoneStatus,
    response_http_status: u16,
    response_committed: bool,
    client_reset: bool,
    ingress_channel_id: u32,
    /// The host-assigned generation, `dispatch_work.request_generation`.
    /// Every message the worker sends under this request carries it, a fetch
    /// start inside the egress token the server minted: the gateway admits a
    /// fetch only under the generation its verified token names, and the
    /// host serves an fs fault only for the generation of a live request
    /// slot. Nonzero for every dispatched request
    /// (`validateStreamBeginDescriptor` in `request/http2/ingress.zig`); 0
    /// marks an evaluation.
    request_generation: u64,
    /// The deadline at `exec.deadline_monotonic_ns` is enforced: it sits on
    /// the loop's deadline heap and the sentinel watches it while the owner
    /// runs (`scheduler/resources.zig:armRequestDeadline`).
    deadline_armed: bool,
    deadline_due_queued: bool,
    finish_started: bool,
    webapi_cleanup_done: bool,
    live_slot_released: bool,
    dispatch_started: bool,
    dispatch_queued: bool,
    body_ready_queued: bool,
    cancel_queued: bool,
    /// When this request's `request`, `request_body_ready` and
    /// `request_cancelled` items first became ready, kept while a full ready
    /// queue makes their enqueue wait, so that wait counts as waiting
    /// (`ingress/runtime.zig:queueStamped`); 0 while none waits.
    dispatch_ready_since_ns: u64,
    body_ready_since_ns: u64,
    cancel_ready_since_ns: u64,
    request_task: ?request_task.TaskToken,
    trace_enabled: bool,
    trace: RequestTrace,

    /// Takes ownership of `dispatch_work`.
    pub fn initOwnedDispatch(
        allocator: std.mem.Allocator,
        ingress_channel_id: u32,
        dispatch_work: ipc.DispatchWork,
        live_slot_index: worker_metrics_state.LiveSlotHandle,
        started_mono_ns: u64,
    ) RequestContext {
        var exec = bindings.ExecCtx.init(dispatch_work.request_id);
        exec.deadline_monotonic_ns = dispatch_work.deadline_monotonic_ns;
        return .{
            .exec = exec,
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .dispatch_work = dispatch_work,
            .live_slot_index = live_slot_index,
            .started_mono_ns = started_mono_ns,
            .io_time_ns = 0,
            .waiting_ns = 0,
            .ready_items = 0,
            .executing_turn = false,
            .timeline_sealed = false,
            .nonexec_since_ns = started_mono_ns,
            .state_since_ns = started_mono_ns,
            .cpu_ns = 0,
            .cpu_budget_ns = 0,
            .cpu_spent = false,
            .arrived_retiring = false,
            .client_served_bytes = 0,
            .fetch_billed_sent_bytes = 0,
            .fetch_billed_received_bytes = 0,
            .fetch_cost_bytes = 0,
            .egress_fetches_started = 0,
            .body = .{},
            .response_stream = .none,
            .response_outbox = .{},
            .response_done_status = .ok,
            .response_http_status = 200,
            .response_committed = false,
            .client_reset = false,
            .ingress_channel_id = ingress_channel_id,
            .request_generation = dispatch_work.request_generation,
            .deadline_armed = false,
            .deadline_due_queued = false,
            .finish_started = false,
            .webapi_cleanup_done = false,
            .live_slot_released = false,
            .dispatch_started = false,
            .dispatch_queued = false,
            .body_ready_queued = false,
            .cancel_queued = false,
            .dispatch_ready_since_ns = 0,
            .body_ready_since_ns = 0,
            .cancel_ready_since_ns = 0,
            .request_task = null,
            .trace_enabled = false,
            .trace = .{ .request_id = dispatch_work.request_id },
        };
    }

    // The request's timeline. At every moment the request is in exactly one
    // of three states: executing a turn of its own, runnable (`ready_items`
    // above zero while the worker runs something else), or waiting on I/O
    // (nothing runnable). Each transition closes the elapsed slice into the
    // total of the state it leaves, so the request's turns, `waiting_ns` and
    // `io_time_ns` add up to its wall time exactly. A turn that runs none of
    // this request's work, another request's or one no request owns, falls
    // in this request's open slice and closes with it as waiting or I/O.
    // Every transition runs on the VM thread. A readiness stamp a producer
    // took earlier is applied after the fact, clamped to [`state_since_ns`,
    // now], so no slice goes negative. Only a dispatched request keeps a
    // timeline: an evaluation's context never counts a ready item and
    // `runtime/owner.zig` opens and closes no turn on it.

    /// A work item of this request became ready. `ready_since_ns` is the
    /// producer's stamp, or 0 for now. `counted` adds the item to
    /// `ready_items`; fs fault waiters are counted by the fault fan-out and
    /// consumed by their settle sub-turns, and crypto settlements count and
    /// consume in one step.
    pub fn noteReady(self: *RequestContext, ready_since_ns: u64, now_ns: u64, counted: bool) void {
        if (self.timeline_sealed) return;
        if (!self.executing_turn) {
            const raw = if (ready_since_ns == 0) now_ns else ready_since_ns;
            if (self.ready_items == 0) {
                const rs = std.math.clamp(raw, self.state_since_ns, now_ns);
                self.io_time_ns +|= rs - self.state_since_ns;
                self.state_since_ns = rs;
            } else if (raw < self.state_since_ns) {
                // An earlier readiness drained after a later stamp already
                // opened the runnable slice, so the request was runnable
                // from the earlier stamp on. The window between the two
                // stamps went to I/O at the first close; the runnable slice
                // now opens at the earlier stamp and takes the window back
                // from I/O, so drain order does not decide the split and the
                // next transition counts the window once, as waiting. The
                // floor is the current stretch without a turn, so a stamp
                // taken inside the request's own turn moves nothing: its
                // waiting starts when the turn ends.
                const floored = @max(raw, self.nonexec_since_ns);
                if (floored < self.state_since_ns) {
                    const window_ns = self.state_since_ns - floored;
                    // Every slice closed since `nonexec_since_ns` went to
                    // I/O, so the window is part of `io_time_ns`.
                    std.debug.assert(window_ns <= self.io_time_ns);
                    self.io_time_ns -= window_ns;
                    self.state_since_ns = floored;
                }
            }
        }
        if (counted)
            self.ready_items +|= 1;
    }

    /// A turn of this request starts, closing the open waiting slice, or an
    /// I/O slice when nothing was counted ready. `consumes_ready_item` pairs
    /// with the enqueue that counted the item.
    pub fn noteTurnBegin(self: *RequestContext, now_ns: u64, consumes_ready_item: bool) void {
        if (self.timeline_sealed) return;
        if (!self.executing_turn) {
            const since = @min(self.state_since_ns, now_ns);
            if (self.ready_items > 0)
                self.waiting_ns +|= now_ns - since
            else
                self.io_time_ns +|= now_ns - since;
            self.executing_turn = true;
            self.state_since_ns = now_ns;
        }
        if (consumes_ready_item)
            self.ready_items -|= 1;
    }

    /// A work item counted for this request vanished before its turn, as a
    /// timer its own code cleared after the item was queued, or a fault
    /// waiter whose settle stopped. Takes the item back from `ready_items`.
    /// When the request is not executing and nothing of it is ready any
    /// more, the runnable slice closes at `now_ns` into `waiting_ns`, and
    /// what follows is I/O; the new stretch without a turn starts there, so
    /// a readiness stamped earlier cannot turn that waiting into I/O again.
    pub fn noteReadyWithdrawn(self: *RequestContext, now_ns: u64) void {
        if (self.timeline_sealed) return;
        if (self.ready_items == 0) return;
        self.ready_items -= 1;
        if (self.executing_turn or self.ready_items != 0)
            return;
        const since = @min(self.state_since_ns, now_ns);
        self.waiting_ns +|= now_ns - since;
        self.state_since_ns = @max(self.state_since_ns, now_ns);
        self.nonexec_since_ns = self.state_since_ns;
    }

    /// The turn ends. Whether the next slice is runnable or I/O depends on
    /// what is still queued, and is decided at the next transition.
    pub fn noteTurnEnd(self: *RequestContext, now_ns: u64) void {
        if (self.timeline_sealed) return;
        self.executing_turn = false;
        self.state_since_ns = @max(self.state_since_ns, now_ns);
        self.nonexec_since_ns = self.state_since_ns;
    }

    /// The final fold, run by `finishRequest`, which seals the timeline. A
    /// request that finishes inside one of its own turns, including an fs
    /// fault waiter sub-turn, has no open slice. One finished outside its
    /// turns, by a client reset, a deadline or shutdown, closes its current
    /// slice here.
    pub fn noteFinish(self: *RequestContext, now_ns: u64) void {
        if (self.timeline_sealed) return;
        if (!self.executing_turn) {
            const since = @min(self.state_since_ns, now_ns);
            if (self.ready_items > 0)
                self.waiting_ns +|= now_ns - since
            else
                self.io_time_ns +|= now_ns - since;
        }
        self.timeline_sealed = true;
        self.state_since_ns = now_ns;
    }

    /// The time the request ran its own turns: its span from the begin's
    /// decode to `noteFinish`, less its waiting and I/O, which the timeline
    /// splits exactly. The timeline must be sealed.
    pub fn execNs(self: *const RequestContext) u64 {
        std.debug.assert(self.timeline_sealed);
        const span_ns = self.state_since_ns -| self.started_mono_ns;
        return span_ns -| self.waiting_ns -| self.io_time_ns;
    }

    /// An evaluation's context: the owner of the top-level code of the module
    /// instance the route at `route_index` evaluates, for its fetches, timers
    /// and CPU. `Runtime` opens it before that code first runs and closes it
    /// when the instance's evaluation settles or expires
    /// (`worker/runtime/evaluations.zig`), which also removes it from the
    /// active map, so a native completion arriving later finds no owner and is
    /// dropped. Takes ownership of `dispatch_work`, whose request id must be
    /// `evaluation_id` and whose egress token is the copy of WorkerInit's boot
    /// token the evaluation's fetches present. Besides its id, five fields
    /// differ from a dispatched request's:
    ///  - `dispatch_work.route_index` names the route, so the evaluation's
    ///    timers and callbacks run in that route's realm.
    ///  - `dispatch_started` is true. The ingress rescan queues every active
    ///    entry that has not started; a queued evaluation would write a
    ///    response into a stream that does not exist.
    ///  - `live_slot_released` is true. An evaluation has no live slot on the
    ///    shared page, and the per-tick CPU flush must skip it.
    ///  - `exec.deadline_monotonic_ns` is 0 until the evaluation arms one, and
    ///    goes back to 0 when it closes, so no timer inherits a stale deadline.
    ///  - `request_generation` is 0, the mark fs faults use to recognize an
    ///    evaluation, and the generation a boot token names.
    pub fn initEvaluation(
        allocator: std.mem.Allocator,
        evaluation_id: u64,
        route_index: u16,
        dispatch_work: ipc.DispatchWork,
        started_mono_ns: u64,
    ) RequestContext {
        std.debug.assert(isEvaluationId(evaluation_id));
        std.debug.assert(dispatch_work.request_id == evaluation_id);
        var ctx = initOwnedDispatch(
            allocator,
            0,
            dispatch_work,
            .{ .index = 0, .generation = 0 },
            started_mono_ns,
        );
        ctx.dispatch_work.route_index = route_index;
        ctx.request_generation = 0;
        ctx.exec.deadline_monotonic_ns = 0;
        ctx.dispatch_started = true;
        ctx.live_slot_released = true;
        return ctx;
    }

    /// Whether code running under this context may start new work: a fetch,
    /// a crypto job, a timer or an immediate, or a read, pull or clone of a
    /// fetch body. The caller found the context in the runtime's active map,
    /// so it is a dispatched request or an open evaluation, and it accepts
    /// work until its finish starts. The finish's cleanup can still run its
    /// JavaScript, such as a pending read's rejection, and nothing that code
    /// starts may outlive the response or leave the worker after it was
    /// decided. The worker owner never enters the map, so its JavaScript
    /// starts none.
    pub fn acceptsWork(self: *const RequestContext) bool {
        return !self.finish_started;
    }

    pub fn requestAllocator(self: *RequestContext) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Marks the response committed: its head went out, so a failure from
    /// here on resets the stream instead of answering it anew.
    pub fn markResponseCommitted(self: *RequestContext) void {
        self.response_committed = true;
    }

    pub fn deinit(self: *RequestContext) void {
        // Releases a body stream's handles without running JavaScript: a
        // context destroyed at the runtime's teardown can still hold one.
        self.response_stream.deinit();
        self.response_outbox.assertEmpty();
        self.body.deinit(self.requestAllocator());
        self.dispatch_work.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Fields of `RequestContext` allocated from the base allocator rather than
/// the request arena. The block below fails the build when a name here
/// leaves the struct.
pub const base_allocator_owned_fields = [_][]const u8{
    "dispatch_work",
};

comptime {
    for (base_allocator_owned_fields) |field_name| {
        if (!@hasField(RequestContext, field_name))
            @compileError("RequestContext base-allocator ownership marker references missing field: " ++ field_name);
    }
}

/// Monotonic stamps of one request's phases, printed by `serve/trace.zig`
/// when request tracing is on. A stamp left at 0 marks a phase that did not
/// run.
pub const RequestTrace = struct {
    request_id: u64 = 0,
    dispatch_enqueued_ns: u64 = 0,
    execute_request_start_ns: u64 = 0,
    evaluate_module_done_ns: u64 = 0,
    /// The request has its route's handler: the default export the route's
    /// evaluation read, which the route's record keeps
    /// (`Runtime.ensureRouteHandler` in `worker/runtime/evaluations.zig`).
    get_export_done_ns: u64 = 0,
    parse_request_done_ns: u64 = 0,
    make_request_done_ns: u64 = 0,
    handler_invoke_done_ns: u64 = 0,
    completion_received_ns: u64 = 0,
    response_extract_done_ns: u64 = 0,
    response_write_done_ns: u64 = 0,
    completion_published_ns: u64 = 0,
};

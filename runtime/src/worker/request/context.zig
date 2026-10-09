//! Per-request worker state: the decoded `DispatchWork`, the request's body
//! pipe and pending response bytes, the execution context the engine bridge
//! reads, and the time and byte counts the request's completed record
//! reports. A context belongs to the worker's VM thread, lives in the
//! runtime's active map under its request id, and dies only in
//! `Runtime.destroyRequestContext`.
//!
//! Every identity a context carries comes from the host's dispatch: request
//! id, generation, lane slot and worker. The worker adds none of its own to
//! what it publishes. The boot context is the one context not built from a
//! dispatch (`RequestContext.initBoot`).

const std = @import("std");
const bindings = @import("collo_bindings");
const ipc = @import("collo_ipc");
const limits = @import("collo_limits");
const worker_metrics_state = @import("collo_worker_state").metrics;
const body = @import("incoming_body/pipe.zig");
const request_head = @import("head.zig");
const request_task = @import("task.zig");
const response_outbox = @import("ingress/response_outbox.zig");

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

/// The boot context's request id. Zero means "no request" everywhere a
/// request id is read (the sentinel, the checks of the `collo_runtime_*`
/// exports in `worker/host/`, an empty live slot), so the boot context needs
/// a nonzero id that no dispatch carries: request ids count up from 1 and
/// never reach this value. The egress wire knows the boot context as the
/// request-less boot permit (request id and generation 0), and
/// `upload_runtime.sendStart` is the one place that translates.
pub const boot_request_id: u64 = std.math.maxInt(u64);

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
    /// A turn of this request is running. That includes fs fault waiter
    /// sub-turns and timer and immediate callback turns, which the turn
    /// telemetry of `scheduler/loop.zig` attributes to no request.
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
    /// Total ready-queue wait of this request's work items, which its
    /// completed record carries as `queued_ns`. A sum over items, whose waits
    /// overlap when several are queued at once, so it is no timeline column;
    /// `waiting_ns` is.
    queued_ns_total: u64,
    /// Longest completed turn of this request. `finishRequest` folds in the
    /// final turn, which is still running when the record is written.
    max_turn_ns: u64,
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
    /// since the gateway spends that budget on every fetch it admits.
    egress_fetches_started: u64,
    body: IncomingBody,
    response_stream_body: ?bindings.FetchBodyIdentity,
    response_stream_pull_pending: bool,
    response_outbox: response_outbox.Outbox,
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
    /// marks the boot context.
    request_generation: u64,
    deadline_generation: u64,
    deadline_armed: bool,
    deadline_due_queued: bool,
    finish_started: bool,
    webapi_cleanup_done: bool,
    live_slot_released: bool,
    dispatch_started: bool,
    dispatch_queued: bool,
    body_ready_queued: bool,
    cancel_queued: bool,
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
        return .{
            .exec = .{
                .request_id = dispatch_work.request_id,
                .deadline_monotonic_ns = dispatch_work.deadline_monotonic_ns,
                .cpu_used_ns_total = 0,
                .turn_cpu_start_ns = 0,
                .termination_reason = @intFromEnum(bindings.TerminationReason.none),
                ._reserved = .{ 0, 0, 0, 0, 0, 0, 0 },
            },
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
            .queued_ns_total = 0,
            .max_turn_ns = 0,
            .client_served_bytes = 0,
            .fetch_billed_sent_bytes = 0,
            .fetch_billed_received_bytes = 0,
            .fetch_cost_bytes = 0,
            .egress_fetches_started = 0,
            .body = .{},
            .response_stream_body = null,
            .response_stream_pull_pending = false,
            .response_outbox = .{},
            .response_done_status = .ok,
            .response_http_status = 200,
            .response_committed = false,
            .client_reset = false,
            .ingress_channel_id = ingress_channel_id,
            .request_generation = dispatch_work.request_generation,
            .deadline_generation = 0,
            .deadline_armed = false,
            .deadline_due_queued = false,
            .finish_started = false,
            .webapi_cleanup_done = false,
            .live_slot_released = false,
            .dispatch_started = false,
            .dispatch_queued = false,
            .body_ready_queued = false,
            .cancel_queued = false,
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
    // now], so no slice goes negative. `queued_ns_total` is not part of the
    // timeline.

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

    /// The boot context: the identity module top-level code uses for
    /// fetches and timers. It is installed before the route entry is
    /// evaluated and closed when that evaluation settles
    /// (`Runtime.closeBootContext`), which also removes it from the active
    /// map, so a native completion arriving later finds no request and is
    /// dropped. Besides its id, `boot_request_id`, four fields differ from a
    /// dispatched request's:
    ///  - `dispatch_started` is true. The ingress rescan queues every active
    ///    entry that has not started; a queued boot context would wait on its
    ///    own evaluation and then write a response into a stream that does
    ///    not exist.
    ///  - `live_slot_released` is true. The boot context has no live slot on
    ///    the shared page, and the per-tick CPU flush must skip it.
    ///  - `exec.deadline_monotonic_ns` is 0. The evaluation budget is armed
    ///    separately (`Runtime.evaluateBootRouteEntry`) and reset to 0 when
    ///    the evaluation settles, so instance timers never inherit a stale
    ///    deadline.
    ///  - `request_generation` is 0, the mark fs faults use to recognize the
    ///    boot context, and the generation a boot token names.
    pub fn initBoot(
        allocator: std.mem.Allocator,
        dispatch_work: ipc.DispatchWork,
        started_mono_ns: u64,
    ) RequestContext {
        var ctx = initOwnedDispatch(
            allocator,
            0,
            dispatch_work,
            .{ .index = 0, .generation = 0 },
            started_mono_ns,
        );
        ctx.request_generation = 0;
        ctx.exec.request_id = boot_request_id;
        ctx.exec.deadline_monotonic_ns = 0;
        ctx.dispatch_started = true;
        ctx.live_slot_released = true;
        ctx.trace.request_id = boot_request_id;
        return ctx;
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
    /// evaluation read, which the route table keeps
    /// (`ensureRouteHandler` in `worker/modules/routes.zig`).
    get_export_done_ns: u64 = 0,
    parse_request_done_ns: u64 = 0,
    make_request_done_ns: u64 = 0,
    handler_invoke_done_ns: u64 = 0,
    completion_received_ns: u64 = 0,
    response_extract_done_ns: u64 = 0,
    response_write_done_ns: u64 = 0,
    completion_published_ns: u64 = 0,
};

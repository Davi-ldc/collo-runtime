//! The view of the worker runtime that the egress files work through: its
//! allocator, VM, limits and clock, its request table and ready queues, and
//! callbacks for a gateway disconnect, a request failure and a network
//! denial's line in the tenant's log. The worker's
//! event loop thread, which is also the VM thread, is the only one that uses
//! it. `Runtime.egressContext` (`runtime/egress.zig`) builds one per call, so a
//! context holds no state of its own; everything mutable sits behind its
//! pointers and belongs to the runtime.

const std = @import("std");
const bindings = @import("collo_bindings");
const ipc = @import("collo_ipc");
const process_limits = @import("collo_limits").process;
const request_context = @import("collo_worker_request").context;
const ready_queue = @import("../scheduler/queue.zig");
const runtime_types = @import("../runtime/types.zig");
const state = @import("state.zig");

pub const RequestMap = std.AutoHashMapUnmanaged(u64, *request_context.RequestContext);

pub const DisconnectFn = *const fn (?*anyopaque, []const u8) void;
pub const ReleaseResponseHoldsBeforeDetachFn = *const fn (?*anyopaque) void;
pub const RequestFailureFn = *const fn (?*anyopaque, u64, anyerror) void;
pub const DenialLogFn = *const fn (?*anyopaque, u64, []const u8) void;

pub const Context = struct {
    allocator: std.mem.Allocator,
    vm: *bindings.Vm,
    limits: runtime_types.RuntimeLimits,
    clock: runtime_types.Clock,
    egress_state: *state.State,
    requests: *RequestMap,
    /// `Evaluations.boot_fetches_started` (`runtime/evaluations.zig`): the
    /// one count of fetches under the boot token, which every evaluation's
    /// fetch adds to instead of its context's own.
    boot_fetches_started: *u64,
    /// `Evaluations.boot_egress_token` (`runtime/evaluations.zig`), the copy
    /// the startup evaluations take theirs from.
    boot_egress_token: *ipc.egress_token.Bytes,
    ready_queue: *ready_queue.ReadyQueue,
    ready_backlog: *ready_queue.ReadyQueue,
    /// The runtime's one packet buffer, shared by everything the event loop
    /// thread reads or encodes. Completion packets are read into it and
    /// gateway commands are encoded into it, so a packet handler must be done
    /// with the packet's bytes before it sends a command.
    dispatch_recv_scratch: []u8,
    /// Decode scratch for gateway completion packets, owned by the runtime
    /// and heap-held for the reasons the decode scratch comment in
    /// `common/ipc/egress.zig` gives. A decoded view points into it and stays
    /// valid only until the next decode of the same kind.
    decode_scratch: *ipc.WorkerEgressDecodeScratch,
    wakeup_fd: ?std.posix.fd_t,
    trace_fd: ?std.posix.fd_t,
    running: *bool,
    /// `Egress.detach_in_progress` (`runtime/egress.zig`), which every
    /// context the VM thread builds shares.
    detach_in_progress: *bool,
    disconnect_context: ?*anyopaque,
    disconnect_fn: DisconnectFn,
    /// Returns the pool bytes that parked response chunks borrow, before the
    /// endpoint is unmapped. It may queue each response's advance, but runs
    /// no JavaScript and finishes no request.
    response_holds_context: ?*anyopaque,
    release_response_holds_before_detach_fn: ReleaseResponseHoldsBeforeDetachFn,
    request_failure_context: ?*anyopaque,
    request_failure_fn: RequestFailureFn,
    denial_log_context: ?*anyopaque,
    denial_log_fn: DenialLogFn,

    pub fn wake(self: *Context) void {
        const fd = self.wakeup_fd orelse return;
        var one: u64 = 1;
        _ = std.posix.write(fd, std.mem.asBytes(&one)) catch |err| switch (err) {
            error.WouldBlock => return,
            else => |unexpected| {
                std.log.warn("worker wakeup eventfd write failed: {s}", .{@errorName(unexpected)});
                return;
            },
        };
    }

    pub fn tryQueueReady(self: *Context, item: ready_queue.WorkItem) bool {
        return self.tryQueueReadyReadySince(item, 0);
    }

    /// Queues `item` as `Runtime.tryQueueReadyWorkReadySince`
    /// (`runtime/scheduler.zig`) does, resolving the owner of the two egress
    /// item kinds at enqueue. `ready_since_mono_ns` is when the gateway made the
    /// work ready, or zero for ready now. When both queues are full, sets the
    /// item's rescan flag and returns false. The caller leaves it for that
    /// rescan; the full queue rule is in `Runtime.tryQueueReadyWorkReadySince`.
    pub fn tryQueueReadyReadySince(
        self: *Context,
        item: ready_queue.WorkItem,
        ready_since_mono_ns: u64,
    ) bool {
        const now = self.clock.now();
        const owner: u64 = switch (item) {
            .fetch_completion => |fetch_id| if (self.egress_state.tasks.get(fetch_id)) |task|
                task.request_id
            else
                0,
            .fetch_body_ready => |body_id| if (self.egress_state.bodies.get(body_id)) |body|
                body.identity.request_id
            else
                0,
            else => 0,
        };
        const meta: ready_queue.SlotMeta = .{
            .enqueued_mono_ns = now,
            .owner_request_id = owner,
            .ready_since_mono_ns = ready_since_mono_ns,
        };
        if (self.ready_queue.tryPushStamped(item, meta)) {
            self.noteOwnerReady(meta);
            return true;
        }
        if (self.ready_backlog.tryPushStamped(item, meta)) {
            self.noteOwnerReady(meta);
            self.wake();
            return true;
        }
        self.markRescanNeeded(item);
        return false;
    }

    /// Gives back the ready count of every queued `item` whose work vanished,
    /// as a body that left the table, the way `Runtime.withdrawReadyWork`
    /// does for a cleared timer (`runtime/scheduler.zig`): each slot naming
    /// it stops charging its owner, and a dispatched request that owned one
    /// closes its runnable time now. The items still pop, in no window. Each
    /// pass clears one slot, so the loop ends within the queue's and the
    /// backlog's capacity.
    pub fn withdrawReady(self: *Context, item: ready_queue.WorkItem) void {
        const now = self.clock.now();
        while (self.ready_queue.withdraw(item) orelse self.ready_backlog.withdraw(item)) |owner_id| {
            if (request_context.isReservedId(owner_id))
                continue;
            const ctx = self.requests.get(owner_id) orelse continue;
            ctx.noteReadyWithdrawn(now);
        }
    }

    /// Only a dispatched request keeps a timeline, so an evaluation's items
    /// count nothing.
    fn noteOwnerReady(self: *Context, meta: ready_queue.SlotMeta) void {
        if (meta.owner_request_id == 0 or request_context.isReservedId(meta.owner_request_id))
            return;
        const ctx = self.requests.get(meta.owner_request_id) orelse return;
        ctx.noteReady(meta.ready_since_mono_ns, meta.enqueued_mono_ns, true);
    }

    fn markRescanNeeded(self: *Context, item: ready_queue.WorkItem) void {
        switch (item) {
            .fetch_completion => self.egress_state.fetch_task_rescan_needed = true,
            .fetch_body_ready => self.egress_state.fetch_body_rescan_needed = true,
            else => {},
        }
    }

    /// Releases response-side borrows while the disconnect owner still
    /// holds the old mapping. This callback never re-enters the VM.
    pub fn releaseResponseHoldsBeforeDetach(self: *Context) void {
        self.release_response_holds_before_detach_fn(self.response_holds_context);
    }

    /// Clears the runtime's copy of the boot token and every evaluation's. A
    /// replacement session refuses this token as another gateway's or another
    /// session's, and each refusal is a strike
    /// (`egress/gateway/runtime/worker_flow.zig`), so a disconnect clears
    /// every copy and later startup fetches fail in the worker instead.
    pub fn revokeBootEgress(self: *Context) void {
        self.boot_egress_token.* = ipc.egress_token.none;
        var iterator = self.requests.iterator();
        while (iterator.next()) |entry| {
            if (request_context.isEvaluationId(entry.key_ptr.*))
                entry.value_ptr.*.dispatch_work.egress_token = ipc.egress_token.none;
        }
    }

    pub fn stop(self: *Context) void {
        self.running.* = false;
    }

    /// Detaches the worker from its gateway session through the runtime
    /// (`gateway_runtime.disconnectWithReason` says what that fails and
    /// releases). The event loop keeps running, and the worker stays detached
    /// until the server attaches a new session. Does nothing when the worker
    /// is already detached.
    pub fn disconnectEgressGateway(self: *Context) void {
        self.disconnectEgressGatewayWithReason("runtime");
    }

    pub fn disconnectEgressGatewayWithReason(self: *Context, reason: []const u8) void {
        self.disconnect_fn(self.disconnect_context, reason);
    }

    pub fn handleRequestFailure(self: *Context, request_id: u64, err: anyerror) void {
        self.request_failure_fn(self.request_failure_context, request_id, err);
    }

    /// Writes `message`, the text of a fetch the network setting denied, as
    /// one `warn` line in the tenant's log under `request_id`
    /// (`Runtime.logNetworkDenial`).
    pub fn logNetworkDenial(self: *Context, request_id: u64, message: []const u8) void {
        self.denial_log_fn(self.denial_log_context, request_id, message);
    }

    pub fn traceRuntimeEvent(self: *Context, comptime fmt: []const u8, args: anytype) void {
        const fd = self.trace_fd orelse return;
        var buffer: [process_limits.TRACE_EVENT_BUFFER_BYTES]u8 = undefined;
        const line = std.fmt.bufPrint(&buffer, fmt ++ "\n", args) catch return;
        _ = std.posix.write(fd, line) catch return;
    }
};

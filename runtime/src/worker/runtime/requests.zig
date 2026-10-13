//! The request domain of the worker runtime. `Requests` is its state: the
//! active map from request id to `RequestContext`, the request task table,
//! settled handler results waiting for their turn, the shared ingress
//! payload region with its credit eventfd, whether a response send has
//! found the control socket full since it last turned writable, and the
//! `request_done` packets that went alone and found it full. A finished
//! request whose last packet carries a step of its response waits in the
//! active map instead, with that step in its outbox
//! (`serve/response_finish.zig`).
//! `Methods` holds the runtime's request operations, which `Runtime`
//! declares as its own (`root.zig`): queueing the ingress work the control
//! channel delivers, request completions and failures, and the end of a
//! request context. It belongs to the worker's VM thread.
//!
//! The active map holds the open evaluations under their evaluation ids
//! (`evaluations.zig`) beside the dispatched requests: every owner that may
//! hold work, and never the worker owner. A context in it dies only in
//! `destroyRequestContext`; `Requests` frees the map, never a context.
//! `Requests.init` takes the credit eventfd, closing it on failure, and
//! `deinitIngress` closes it after.
//!
//! Named bound: `request_done_outbox_capacity`.

const std = @import("std");
const bindings = @import("collo_bindings");
const ipc = @import("collo_ipc");
const worker_shared_page = @import("collo_worker_state").page;
const request_context = @import("collo_worker_request").context;
const request_completion = @import("collo_worker_request").completion;
const request_ingress = @import("collo_worker_request").ingress.runtime;
const request_task = @import("collo_worker_request").task;
const request_dispatch = @import("../serve/dispatch.zig");
const runtime_types = @import("types.zig");

/// Most `request_done` packets the worker holds alone while the control
/// socket has no room for them (`serve/response_finish.zig`), which, with
/// the finished requests whose last packet waits in their outbox, never
/// outnumber the pool slots. The server gives a pool
/// slot back to its pool only once the `request_done` of the slot's request
/// arrives or the worker dies (`server/ingress/runner/request_slot.zig`), so
/// every packet the worker still owes names a request that holds one of its
/// pool slots, and a worker has at most `LIVE_SLOT_COUNT` of them. The bound
/// rests on the server, so a packet past it is an error rather than an
/// assertion: the worker stops, and the server ends the requests it still
/// waits on from their live slots.
pub const request_done_outbox_capacity: usize = worker_shared_page.LIVE_SLOT_COUNT;

/// A finished request's `request_done` and where it goes: the identity and
/// stream every descriptor of the request carries.
pub const PendingRequestDone = struct {
    identity: ipc.ingress_channel.RequestIdentity,
    stream_id: u32,
    done: ipc.ingress_channel.RequestDone,
};

/// The `request_done` packets that found the control socket full, oldest
/// first, in storage `Requests.init` reserves and nothing writes until a
/// packet first waits.
pub const RequestDoneOutbox = struct {
    entries: []PendingRequestDone,
    head: usize = 0,
    len: usize = 0,

    pub fn isEmpty(self: *const RequestDoneOutbox) bool {
        return self.len == 0;
    }

    /// Queues `entry` behind every packet already waiting. Fails with
    /// `error.RequestDoneOutboxFull` when `request_done_outbox_capacity`
    /// packets wait.
    pub fn push(self: *RequestDoneOutbox, entry: PendingRequestDone) error{RequestDoneOutboxFull}!void {
        if (self.len == self.entries.len)
            return error.RequestDoneOutboxFull;
        self.entries[(self.head + self.len) % self.entries.len] = entry;
        self.len += 1;
    }

    /// The packet that has waited longest; it stays queued until `pop`.
    pub fn oldest(self: *const RequestDoneOutbox) ?*const PendingRequestDone {
        if (self.len == 0)
            return null;
        return &self.entries[self.head];
    }

    pub fn pop(self: *RequestDoneOutbox) void {
        std.debug.assert(self.len != 0);
        self.head = (self.head + 1) % self.entries.len;
        self.len -= 1;
    }
};

pub const Requests = struct {
    active: std.AutoHashMapUnmanaged(u64, *request_context.RequestContext),
    tasks: request_task.RequestTaskTable,
    /// A request's settled handler result, held until its
    /// `request_completion` work item runs (`request/completion.zig`).
    pending_completions: std.AutoHashMapUnmanaged(u64, request_completion.Completion),
    /// Mapped read-write from `RuntimeOptions.ingress_payload_fd` as the
    /// worker's side (`SharedPayloadSide`).
    ingress_payload: ?ipc.ingress_channel.SharedPayloadView,
    /// When it turns readable, the loop drains it and queues the advance of
    /// each response that waits for payload room (`scheduler/loop.zig`).
    ingress_payload_credit_eventfd: ?std.posix.fd_t,
    /// Id of the next request body read (`request/body_read.zig`).
    next_body_task_id: u64,
    /// A response send found the control socket full since it last turned
    /// writable. While it holds, the loop polls the socket for room
    /// (`scheduler/poll_backend.zig`), and the writable event clears it
    /// (`serve/response.zig:notifyTransport`).
    control_send_blocked: bool = false,
    /// While it holds a packet, the loop polls the control socket for room
    /// and sends what it holds when the socket turns writable
    /// (`serve/response_finish.zig:flushPendingRequestDones`).
    done_outbox: RequestDoneOutbox,
    /// A dispatched request finished since the loop's last idle collection,
    /// so the heap may hold the garbage its work left. Set where a finished
    /// request leaves the active map (`serve/response_finish.zig`) and
    /// cleared by the idle collection (`scheduler/idle.zig`), which runs at
    /// most once per stretch between requests.
    idle_collection_owed: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        limits: runtime_types.RuntimeLimits,
        options: runtime_types.RuntimeOptions,
    ) !Requests {
        const ingress_payload_credit_eventfd = options.ingress_payload_credit_eventfd;
        errdefer if (ingress_payload_credit_eventfd) |fd| {
            std.posix.close(fd);
        };

        var ingress_payload = if (options.ingress_payload_fd) |fd|
            try ipc.ingress_channel.mapSharedPayloadReadWrite(fd, .worker)
        else
            null;
        errdefer if (ingress_payload) |*view| {
            view.deinit();
        };

        const done_entries = try allocator.alloc(PendingRequestDone, request_done_outbox_capacity);
        errdefer allocator.free(done_entries);

        return .{
            .active = .{},
            .tasks = try request_task.RequestTaskTable.init(allocator, limits.request_task_capacity),
            .pending_completions = .{},
            .ingress_payload = ingress_payload,
            .ingress_payload_credit_eventfd = ingress_payload_credit_eventfd,
            .next_body_task_id = 1,
            .done_outbox = .{ .entries = done_entries },
        };
    }

    pub fn deinitTables(self: *Requests, allocator: std.mem.Allocator) void {
        var completion_it = self.pending_completions.iterator();
        while (completion_it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.pending_completions.deinit(allocator);
        self.tasks.deinit();
        allocator.free(self.done_outbox.entries);
        self.done_outbox = .{ .entries = &.{} };
    }

    pub fn deinitIngress(self: *Requests) void {
        if (self.ingress_payload) |*view| {
            view.deinit();
        }
        if (self.ingress_payload_credit_eventfd) |fd| {
            std.posix.close(fd);
        }
        self.ingress_payload = null;
        self.ingress_payload_credit_eventfd = null;
    }

    /// Frees the map and leaves it empty, not undefined: the runtime's
    /// teardown releases the fetch bodies after the requests, and a body's
    /// release still looks its request up (`egress/body/common.zig:accountEgress`,
    /// `egress/context.zig:Context.withdrawReady`), which must find none.
    pub fn deinitActiveMap(self: *Requests, allocator: std.mem.Allocator) void {
        self.active.deinit(allocator);
        self.active = .empty;
    }
};

pub fn Methods(comptime Runtime: type) type {
    return struct {
        pub fn enqueueIngressDescriptor(self: *Runtime, received: ipc.ingress_channel.Received) !void {
            try request_ingress.enqueueDescriptor(self, received);
        }

        pub fn collectReadyIngressRequests(self: *Runtime) void {
            request_ingress.collectReadyRequests(self);
        }

        pub fn handleRequestFailure(self: *Runtime, request_id: u64, err: anyerror) void {
            request_dispatch.handleLocalFailure(self, request_id, err);
        }

        pub fn scheduleRequestTaskCompletion(
            self: *Runtime,
            token: request_task.TaskToken,
            request_id: u64,
            request_generation: u64,
            value: bindings.Value,
            is_error: bool,
        ) !void {
            try request_completion.schedule(self, token, request_id, request_generation, value, is_error);
        }

        pub fn collectReadyRequestCompletions(self: *Runtime) void {
            request_completion.collectReady(self);
        }

        /// The one place a live RequestContext dies. The VM's microtask-owner
        /// token is released here rather than at each call site: the table is
        /// keyed by `&ctx.exec`, and a reaction this request registered can still
        /// wait on a module-scope promise, so a token that outlived its storage
        /// would read freed memory the next time that promise settles. Teardown,
        /// an evaluation's close, a finished request and an enqueue rollback
        /// all come through here.
        pub fn destroyRequestContext(self: *Runtime, ctx: *request_context.RequestContext) void {
            self.core.vm.releaseExecCtx(&ctx.exec) catch |err|
                std.log.warn("failed to release exec ctx owner request_id={d}: {s}", .{
                    ctx.exec.request_id,
                    @errorName(err),
                });
            ctx.deinit();
            self.core.allocator.destroy(ctx);
        }
    };
}

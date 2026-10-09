//! The request domain of the worker runtime. `Requests` is its state: the
//! active map from request id to `RequestContext`, the request task table,
//! settled handler results waiting for their turn, the shared ingress
//! payload region with its credit eventfd, and whether a response send has
//! found the control socket full since the outboxes were last flushed.
//! `Methods` holds the runtime's request operations, which `Runtime`
//! declares as its own (`root.zig`): queueing the ingress work the control
//! channel delivers, request completions and failures, the flush of parked
//! responses, and the end of a request context. It belongs to the worker's
//! VM thread.
//!
//! The active map holds the boot context under `boot_request_id` beside the
//! dispatched requests. A context in it dies only in
//! `destroyRequestContext`; `Requests` frees the map, never a context.
//! `Requests.init` takes the credit eventfd, closing it on failure, and
//! `deinitIngress` closes it after.

const std = @import("std");
const bindings = @import("collo_bindings");
const ipc = @import("collo_ipc");
const request_context = @import("collo_worker_request").context;
const request_completion = @import("collo_worker_request").completion;
const request_ingress = @import("collo_worker_request").ingress.runtime;
const request_task = @import("collo_worker_request").task;
const request_dispatch = @import("../serve/dispatch.zig");
const response_flow = @import("../serve/response.zig");
const runtime_types = @import("types.zig");

pub const Requests = struct {
    active: std.AutoHashMapUnmanaged(u64, *request_context.RequestContext),
    tasks: request_task.RequestTaskTable,
    /// A request's settled handler result, held until its
    /// `request_completion` work item runs (`request/completion.zig`).
    pending_completions: std.AutoHashMapUnmanaged(u64, request_completion.Completion),
    /// Mapped read-write from `RuntimeOptions.ingress_payload_fd` as the
    /// worker's side (`SharedPayloadSide`).
    ingress_payload: ?ipc.ingress_channel.SharedPayloadView,
    /// When it turns readable, the loop drains it and flushes the responses
    /// parked for payload room (`scheduler/loop.zig`).
    ingress_payload_credit_eventfd: ?std.posix.fd_t,
    /// Id of the next request body read (`request/body_read.zig`).
    next_body_task_id: u64,
    /// A response send found the control socket full since the outboxes
    /// were last flushed. While it holds, the loop polls the socket for room
    /// (`scheduler/uring_backend.zig`); the flush clears it before it sends
    /// (`serve/response.zig`).
    control_send_blocked: bool = false,

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

        return .{
            .active = .{},
            .tasks = try request_task.RequestTaskTable.init(allocator, limits.request_task_capacity),
            .pending_completions = .{},
            .ingress_payload = ingress_payload,
            .ingress_payload_credit_eventfd = ingress_payload_credit_eventfd,
            .next_body_task_id = 1,
        };
    }

    pub fn deinitTables(self: *Requests, allocator: std.mem.Allocator) void {
        var completion_it = self.pending_completions.iterator();
        while (completion_it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.pending_completions.deinit(allocator);
        self.tasks.deinit();
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

    pub fn deinitActiveMap(self: *Requests, allocator: std.mem.Allocator) void {
        self.active.deinit(allocator);
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
        /// the boot context's close, a finished request and an enqueue rollback
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

        pub fn flushPendingIngressResponses(self: *Runtime) !void {
            try response_flow.flushPendingIngressResponses(self);
        }
    };
}

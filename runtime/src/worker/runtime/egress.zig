//! The egress domain of the worker runtime. `Egress` is its state: the
//! worker's egress state (`egress/state.zig`, which also gives the teardown
//! order) and the request completion eventfd. `Methods` holds the runtime's
//! egress operations, which `Runtime` declares as its own (`root.zig`):
//! fetches and their bodies, the egress gateway's packets and session, and
//! the egress context through which the files under `worker/egress/` reach
//! the runtime. It belongs to the worker's VM thread.
//!
//! The callbacks `installEgressCallbacks` binds hold the runtime's address,
//! so they are bound when the runtime is attached (`vm_hooks.zig`) and again
//! before `Runtime.deinit` releases the bodies.

const std = @import("std");
const bindings = @import("collo_bindings");
const ipc = @import("collo_ipc");
const egress_core = @import("collo_egress_core");
const request_context = @import("collo_worker_request").context;
const promise_deferred = @import("collo_worker_js").deferred;
const runtime_types = @import("types.zig");
const egress_state = @import("../egress/state.zig");
const egress_context = @import("../egress/context.zig");
const egress_body = @import("../egress/body/root.zig");
const egress_gateway = @import("../egress/gateway_runtime.zig");
const egress_gateway_control = @import("../egress/gateway_control.zig");
const egress_fetch = @import("../egress/fetch_runtime.zig");
const egress_task = @import("../egress/task_runtime.zig");
const request_dispatch = @import("../serve/dispatch.zig");
const response_flow = @import("../serve/response.zig");

const FetchBodyReadKind = egress_core.fetch_body.ReadKind;
const FetchBodyResponseStreamDrain = egress_body.ResponseStreamDrain;

pub const Egress = struct {
    state: egress_state.State,
    /// Written after each completion record the worker publishes on its
    /// shared page (`serve/response_finish.zig`); `Runtime.init` says why
    /// this channel is required. Owned here, and closed by
    /// `deinitAfterBodiesReleased` unless the gateway endpoint holds the same
    /// descriptor and closes it itself.
    completion_eventfd: std.posix.fd_t,

    pub fn init(
        allocator: std.mem.Allocator,
        limits: runtime_types.RuntimeLimits,
        completion_eventfd: std.posix.fd_t,
        shared_fds: ?*ipc.egress_shared.RawFds,
    ) !Egress {
        return .{
            .state = try egress_state.State.init(allocator, limits, shared_fds),
            .completion_eventfd = completion_eventfd,
        };
    }

    pub fn deinitTasks(self: *Egress, allocator: std.mem.Allocator) void {
        self.state.deinitTasks(allocator);
    }

    pub fn deinitAfterBodiesReleased(self: *Egress, allocator: std.mem.Allocator) void {
        const completion_eventfd_owned_by_endpoint = if (self.state.shared) |*endpoint|
            endpoint.completion_eventfd == self.completion_eventfd
        else
            false;

        self.state.deinitAfterBodiesReleased(allocator);

        if (self.completion_eventfd >= 0 and !completion_eventfd_owned_by_endpoint)
            std.posix.close(self.completion_eventfd);
        self.completion_eventfd = -1;
    }

    /// Teardown for a runtime whose `init` failed after this domain was
    /// built. No runtime exists yet to give `body/cleanup.zig` an egress
    /// context, so each body drops its reference here instead.
    pub fn deinitFailedInit(self: *Egress, allocator: std.mem.Allocator) void {
        self.state.deinitTasks(allocator);
        var body_it = self.state.bodies.iterator();
        while (body_it.next()) |entry| {
            entry.value_ptr.*.releaseAfterQueuedResourcesReleased(allocator);
        }
        self.state.bodies.clearRetainingCapacity();
        self.deinitAfterBodiesReleased(allocator);
    }

    pub fn hasSharedEndpoint(self: *const Egress) bool {
        return self.state.shared != null;
    }
};

pub fn Methods(comptime Runtime: type) type {
    return struct {
        pub fn scheduleFetch(
            self: *Runtime,
            request_id: u64,
            url: []const u8,
            method: []const u8,
            body: []const u8,
            headers: []const bindings.NameValuePair,
            flags: u32,
            deferred: promise_deferred.DeferredOwned,
        ) !u64 {
            if (self.bootIdentityClosed(request_id)) {
                var owned_deferred = deferred;
                owned_deferred.deinit();
                return error.FetchOutsideActiveRequest;
            }
            var egress_ctx = self.egressContext();
            return egress_fetch.schedule(
                &egress_ctx,
                request_id,
                url,
                method,
                body,
                headers,
                flags,
                deferred,
            );
        }

        pub fn disconnectEgressGateway(self: *Runtime) void {
            var egress_ctx = self.egressContext();
            egress_gateway.disconnect(&egress_ctx);
        }

        pub fn disconnectEgressGatewayWithReason(self: *Runtime, reason: []const u8) void {
            var egress_ctx = self.egressContext();
            egress_gateway.disconnectWithReason(&egress_ctx, reason);
        }

        /// `gateway_runtime.detachAfterFailedRelease`, for the event loop.
        pub fn detachEgressAfterFailedRelease(self: *Runtime) void {
            var egress_ctx = self.egressContext();
            egress_gateway.detachAfterFailedRelease(&egress_ctx);
        }

        pub fn cancelFetchesForRequest(self: *Runtime, request_id: u64) void {
            var egress_ctx = self.egressContext();
            egress_task.cancelForRequest(&egress_ctx, request_id);
        }

        pub fn reapFetchesForRequest(self: *Runtime, request_id: u64) void {
            var egress_ctx = self.egressContext();
            egress_task.reapForRequest(&egress_ctx, request_id);
        }

        pub fn cancelFetch(self: *Runtime, fetch_id: u64, reason: ?bindings.Value) void {
            var egress_ctx = self.egressContext();
            egress_task.cancel(&egress_ctx, fetch_id, reason);
        }

        pub fn registerFetchBody(
            self: *Runtime,
            request: *const request_context.RequestContext,
            fetch_id: u64,
            bytes: []const u8,
        ) !bindings.FetchBodyIdentity {
            var egress_ctx = self.egressContext();
            return egress_body.registerComplete(&egress_ctx, request, fetch_id, bytes, null);
        }

        pub fn registerFetchBodyComplete(
            self: *Runtime,
            request: *const request_context.RequestContext,
            fetch_id: u64,
            bytes: []const u8,
            max_bytes: ?u64,
        ) !bindings.FetchBodyIdentity {
            var egress_ctx = self.egressContext();
            return egress_body.registerComplete(&egress_ctx, request, fetch_id, bytes, max_bytes);
        }

        pub fn registerFetchBodyOpen(
            self: *Runtime,
            request: *const request_context.RequestContext,
            fetch_id: u64,
            max_bytes: ?u64,
        ) !bindings.FetchBodyIdentity {
            var egress_ctx = self.egressContext();
            return egress_body.registerOpen(&egress_ctx, request, fetch_id, max_bytes);
        }

        pub fn appendFetchBodyBytes(self: *Runtime, identity: bindings.FetchBodyIdentity, bytes: []const u8) !void {
            var egress_ctx = self.egressContext();
            try egress_body.appendBytes(&egress_ctx, identity, bytes);
        }

        pub fn completeFetchBody(self: *Runtime, identity: bindings.FetchBodyIdentity) !void {
            var egress_ctx = self.egressContext();
            try egress_body.complete(&egress_ctx, identity);
        }

        pub fn failFetchBody(self: *Runtime, identity: bindings.FetchBodyIdentity, message: []const u8) !void {
            var egress_ctx = self.egressContext();
            try egress_body.fail(&egress_ctx, identity, message);
        }

        pub fn scheduleFetchBodyConsume(
            self: *Runtime,
            identity: bindings.FetchBodyIdentity,
            kind: FetchBodyReadKind,
            content_type: []const u8,
            deferred: promise_deferred.DeferredOwned,
        ) !u64 {
            var egress_ctx = self.egressContext();
            return egress_body.scheduleConsume(&egress_ctx, identity, kind, content_type, deferred);
        }

        pub fn scheduleFetchBodyPull(
            self: *Runtime,
            identity: bindings.FetchBodyIdentity,
            deferred: promise_deferred.DeferredOwned,
        ) !u64 {
            var egress_ctx = self.egressContext();
            return egress_body.schedulePull(&egress_ctx, identity, deferred);
        }

        pub fn borrowFetchBody(self: *Runtime, identity: bindings.FetchBodyIdentity) ?[]const u8 {
            var egress_ctx = self.egressContext();
            return egress_body.borrow(&egress_ctx, identity);
        }

        pub fn cloneFetchBody(self: *Runtime, identity: bindings.FetchBodyIdentity) !bindings.FetchBodyIdentity {
            var egress_ctx = self.egressContext();
            return egress_body.clone(&egress_ctx, identity);
        }

        pub fn cancelFetchBody(self: *Runtime, identity: bindings.FetchBodyIdentity) void {
            var egress_ctx = self.egressContext();
            egress_body.cancel(&egress_ctx, identity);
        }

        pub fn releaseFetchBody(self: *Runtime, identity: bindings.FetchBodyIdentity) bool {
            var egress_ctx = self.egressContext();
            return egress_body.release(&egress_ctx, identity);
        }

        pub fn beginFetchBodyResponseStreamPull(self: *Runtime, identity: bindings.FetchBodyIdentity) !void {
            var egress_ctx = self.egressContext();
            try egress_body.beginResponseStreamPull(&egress_ctx, identity);
        }

        pub fn drainFetchBodyResponseStreamReady(
            self: *Runtime,
            identity: bindings.FetchBodyIdentity,
        ) !FetchBodyResponseStreamDrain {
            var egress_ctx = self.egressContext();
            return egress_body.drainResponseStreamReady(&egress_ctx, identity);
        }

        pub fn releaseFetchBodyResponseStreamCredits(
            self: *Runtime,
            credits: []const egress_core.body_credit.Handle,
        ) void {
            var egress_ctx = self.egressContext();
            for (credits) |credit| {
                egress_gateway_control.releaseBodyCredit(&egress_ctx, credit);
            }
        }

        /// Flushes the coalesced gateway notification for body-pool releases
        /// that came after `drainFetchBodyResponseStreamReady`'s own flush. The
        /// drain's deinit releases borrowed extents, and a missed wake stalls the
        /// origin's flow control.
        pub fn flushFetchBodyPoolReleases(self: *Runtime) void {
            var egress_ctx = self.egressContext();
            egress_gateway_control.flushBodyPoolReleases(&egress_ctx);
        }

        pub fn cleanupFetchBodiesForRequest(self: *Runtime, request_id: u64) void {
            var egress_ctx = self.egressContext();
            egress_body.cleanupForRequest(&egress_ctx, request_id);
        }

        pub fn executeFetchBodyReady(self: *Runtime, body_id: u64) !void {
            // This consumes the readiness the current stamp describes; the next
            // gateway packet stamps a new one, since handlers set the stamp only
            // when it is zero.
            if (self.egress.state.bodies.get(body_id)) |body|
                body.ready_at_mono_ns = 0;
            if (try response_flow.executeFetchBodyStreamReady(self, body_id))
                return;
            var egress_ctx = self.egressContext();
            try egress_body.executeReady(&egress_ctx, body_id);
        }

        pub fn handleFetchBodyReadyFailure(self: *Runtime, body_id: u64, err: anyerror) void {
            var egress_ctx = self.egressContext();
            egress_body.handleReadyFailure(&egress_ctx, body_id, err);
        }

        pub fn egressContext(self: *Runtime) egress_context.Context {
            const context: *anyopaque = @ptrCast(self);
            return .{
                .allocator = self.core.allocator,
                .vm = self.core.vm,
                .limits = self.core.limits,
                .clock = self.core.clock,
                .egress_state = &self.egress.state,
                .requests = &self.requests.active,
                .ready_queue = &self.scheduler.ready_queue,
                .ready_backlog = &self.scheduler.ready_backlog,
                .dispatch_recv_scratch = self.core.dispatch_recv_scratch,
                .decode_scratch = self.core.egress_decode_scratch,
                .wakeup_fd = self.scheduler.wakeup_fd,
                .trace_fd = self.observability.trace_fd,
                .running = &self.core.running,
                .disconnect_context = context,
                .disconnect_fn = disconnectEgressGatewayCallback,
                .request_failure_context = context,
                .request_failure_fn = requestFailureCallback,
            };
        }

        pub fn collectCompletedFetches(self: *Runtime) !void {
            var egress_ctx = self.egressContext();
            try egress_task.collectCompleted(&egress_ctx);
        }

        pub fn collectEgressGatewayPacket(self: *Runtime) !void {
            var egress_ctx = self.egressContext();
            try egress_gateway.collectPacket(&egress_ctx);
        }

        pub fn collectEgressGatewayPacketsBounded(self: *Runtime, max_packets: usize) !bool {
            var egress_ctx = self.egressContext();
            return egress_gateway.collectPacketsBounded(&egress_ctx, max_packets);
        }

        pub fn handleEgressGatewayPacketBytes(self: *Runtime, bytes: []const u8) !void {
            var egress_ctx = self.egressContext();
            try egress_gateway.handlePacketBytes(&egress_ctx, bytes);
        }

        pub fn collectReadyFetchBodies(self: *Runtime) !void {
            var egress_ctx = self.egressContext();
            try egress_body.collectReady(&egress_ctx);
        }

        pub fn installEgressCallbacks(self: *Runtime) void {
            const context: *anyopaque = @ptrCast(self);
            var egress_ctx = self.egressContext();
            egress_gateway_control.bindBodyPoolRelease(
                &egress_ctx,
                context,
                releaseGatewayBodyPoolChunkCallback,
                releaseFetchBodyCreditCallback,
            );
        }

        fn releaseGatewayBodyPoolChunkCallback(context: ?*anyopaque, seq: u64, len: usize) void {
            const runtime: *Runtime = @ptrCast(@alignCast(context orelse return));
            var egress_ctx = runtime.egressContext();
            egress_gateway_control.noteBodyPoolChunkReleased(&egress_ctx, seq, len);
        }

        fn releaseFetchBodyCreditCallback(context: ?*anyopaque, credit: egress_core.body_credit.Handle) void {
            const runtime: *Runtime = @ptrCast(@alignCast(context orelse return));
            var egress_ctx = runtime.egressContext();
            egress_gateway_control.releaseBodyCredit(&egress_ctx, credit);
        }

        fn disconnectEgressGatewayCallback(context: ?*anyopaque, reason: []const u8) void {
            const runtime: *Runtime = @ptrCast(@alignCast(context orelse return));
            var egress_ctx = runtime.egressContext();
            egress_gateway.disconnectWithReason(&egress_ctx, reason);
        }

        fn requestFailureCallback(context: ?*anyopaque, request_id: u64, err: anyerror) void {
            const runtime: *Runtime = @ptrCast(@alignCast(context orelse return));
            request_dispatch.handleLocalFailure(runtime, request_id, err);
        }
    };
}

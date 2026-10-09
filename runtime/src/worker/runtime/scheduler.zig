//! The scheduler domain of the worker runtime. `Scheduler` is its state: the
//! ready queue and its backlog, the request-deadline heap, timers and
//! immediates with their ready maps, the loop's wakeup eventfd, the
//! restricted worker ring, and the bookkeeping of the turn running now.
//! `Methods` holds the runtime's operations on that state, which `Runtime`
//! declares as its own (`root.zig`): queueing ready work, timers and
//! immediates, request deadlines and the sentinel's view of them, the worker
//! ring, and waking and draining the loop. It belongs to the worker's VM
//! thread; other threads only write the wakeup eventfd (`wakeup_fd`). The
//! policy over the state lives in `scheduler/resources.zig` and
//! `scheduler/loop.zig`. Every capacity comes from `RuntimeLimits` and is
//! reserved in `init`.

const std = @import("std");
const bindings = @import("collo_bindings");
const restricted_uring = @import("collo_common_io").restricted_uring;
const js_value = @import("collo_worker_js").value;
const request_context = @import("collo_worker_request").context;
const ready_queue_mod = @import("../scheduler/queue.zig");
const deadlines_mod = @import("../scheduler/deadlines.zig");
const immediates_mod = @import("../scheduler/immediates.zig");
const timers_mod = @import("../scheduler/timers.zig");
const scheduler_resources = @import("../scheduler/resources.zig");
const runtime_types = @import("types.zig");

pub const Scheduler = struct {
    ready_queue: ready_queue_mod.ReadyQueue,
    ready_backlog: ready_queue_mod.ReadyQueue,
    request_deadlines: deadlines_mod.DeadlineHeap,
    timers: timers_mod.TimerHeap,
    pending_immediate_callbacks: immediates_mod.ImmediateQueue,
    ready_timer_callbacks: std.AutoHashMapUnmanaged(u64, timers_mod.TimerEntry),
    ready_immediate_callbacks: std.AutoHashMapUnmanaged(u64, immediates_mod.ImmediateEntry),
    /// Wakes the loop. The crypto pool's threads, the engine's deferred-work
    /// notification (from the wasm worklist thread too) and `Runtime.wake`
    /// write it, so the other threads must stop writing before `deinit`
    /// closes it.
    wakeup_fd: ?std.posix.fd_t,
    worker_ring_fixed_files: ?[restricted_uring.FixedFile.count]std.posix.fd_t,
    worker_ring: ?restricted_uring.WorkerRing,
    worker_timer_fd: ?std.posix.fd_t,
    metrics: runtime_types.WorkerSchedulerMetrics,
    /// The request whose completed record counts the running turn's duration
    /// and queue wait, or 0. Timer, immediate and fault turns count toward no
    /// request (`beginTurnTelemetry` in `scheduler/loop.zig`).
    /// `finishRequest` reads it to fold a still-running final turn into the
    /// record.
    executing_turn_request_id: u64,
    /// The owner of the running turn's work item, resolved at enqueue, or 0.
    /// It differs from `executing_turn_request_id` for timer and immediate
    /// turns, which count toward no request's record yet still run their
    /// request in its I/O and waiting timeline.
    executing_turn_real_owner: u64,
    /// Monotonic start of the running turn, or 0 outside a turn.
    turn_started_mono_ns: u64,
    /// Ready-queue wait of the item that started the current turn.
    turn_queued_wait_ns: u64,
    next_timer_id: u64,
    executing_timer_id: ?u64,
    executing_timer_request_id: u64,
    executing_timer_cancelled: bool,
    executing_repeating_timer_reserved: bool,
    immediate_next_generation: u64,
    immediate_collect_generation: ?u64,
    ingress_rescan_needed: bool,
    request_completion_rescan_needed: bool,

    pub fn init(allocator: std.mem.Allocator, limits: runtime_types.RuntimeLimits) !Scheduler {
        const wakeup_fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
        errdefer std.posix.close(wakeup_fd);

        var ready_queue = try ready_queue_mod.ReadyQueue.init(allocator, limits.ready_queue_capacity);
        errdefer ready_queue.deinit();

        var ready_backlog = try ready_queue_mod.ReadyQueue.init(allocator, limits.ready_queue_capacity);
        errdefer ready_backlog.deinit();

        var request_deadlines = try deadlines_mod.DeadlineHeap.initCapacity(
            allocator,
            limits.request_task_capacity,
        );
        errdefer request_deadlines.deinit();

        var timer_heap = try timers_mod.TimerHeap.initCapacity(allocator, limits.max_timers_per_worker);
        errdefer timer_heap.deinit();

        var pending_immediate_callbacks =
            try immediates_mod.ImmediateQueue.initCapacity(allocator, limits.max_timers_per_worker);
        errdefer pending_immediate_callbacks.deinit();

        var ready_timer_callbacks: std.AutoHashMapUnmanaged(u64, timers_mod.TimerEntry) = .{};
        errdefer ready_timer_callbacks.deinit(allocator);
        try ready_timer_callbacks.ensureTotalCapacity(
            allocator,
            try hashCapacity(limits.max_timers_per_worker),
        );

        var ready_immediate_callbacks: std.AutoHashMapUnmanaged(u64, immediates_mod.ImmediateEntry) = .{};
        errdefer ready_immediate_callbacks.deinit(allocator);
        try ready_immediate_callbacks.ensureTotalCapacity(
            allocator,
            try hashCapacity(limits.max_timers_per_worker),
        );

        return .{
            .ready_queue = ready_queue,
            .ready_backlog = ready_backlog,
            .request_deadlines = request_deadlines,
            .timers = timer_heap,
            .pending_immediate_callbacks = pending_immediate_callbacks,
            .ready_timer_callbacks = ready_timer_callbacks,
            .ready_immediate_callbacks = ready_immediate_callbacks,
            .wakeup_fd = wakeup_fd,
            .worker_ring_fixed_files = null,
            .worker_ring = null,
            .worker_timer_fd = null,
            .metrics = .{},
            .executing_turn_request_id = 0,
            .executing_turn_real_owner = 0,
            .turn_started_mono_ns = 0,
            .turn_queued_wait_ns = 0,
            .next_timer_id = 1,
            .executing_timer_id = null,
            .executing_timer_request_id = 0,
            .executing_timer_cancelled = false,
            .executing_repeating_timer_reserved = false,
            .immediate_next_generation = 0,
            .immediate_collect_generation = null,
            .ingress_rescan_needed = false,
            .request_completion_rescan_needed = false,
        };
    }

    pub fn deinitWorkerRing(self: *Scheduler) void {
        if (self.worker_ring) |*ring| {
            ring.deinit();
            self.worker_ring = null;
        }
        if (self.worker_timer_fd) |fd| {
            std.posix.close(fd);
            self.worker_timer_fd = null;
        }
        self.worker_ring_fixed_files = null;
    }

    pub fn deinit(self: *Scheduler, allocator: std.mem.Allocator) void {
        self.deinitWorkerRing();

        var timer_it = self.ready_timer_callbacks.iterator();
        while (timer_it.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        self.ready_timer_callbacks.deinit(allocator);

        var immediate_it = self.ready_immediate_callbacks.iterator();
        while (immediate_it.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        self.ready_immediate_callbacks.deinit(allocator);

        if (self.wakeup_fd) |fd| {
            // `Runtime.deinit` unregisters the engine's deferred-work wakeup
            // and joins the crypto pool before calling this, so neither
            // thread can write this fd's number after the close recycles it.
            std.posix.close(fd);
        }

        self.pending_immediate_callbacks.deinit();
        self.timers.deinit();
        self.request_deadlines.deinit();
        self.ready_backlog.deinit();
        self.ready_queue.deinit();
        self.* = undefined;
    }
};

pub fn Methods(comptime Runtime: type) type {
    return struct {
        pub fn initRestrictedWorkerRing(self: *Runtime) !void {
            try scheduler_resources.initRestrictedWorkerRing(self);
        }

        pub fn workerRingFd(self: *const Runtime) ?std.posix.fd_t {
            return scheduler_resources.workerRingFd(self);
        }

        pub fn workerTimerFd(self: *const Runtime) ?std.posix.fd_t {
            return scheduler_resources.workerTimerFd(self);
        }

        pub fn workerRingFixedFiles(self: *const Runtime) ?[restricted_uring.FixedFile.count]std.posix.fd_t {
            return scheduler_resources.workerRingFixedFiles(self);
        }

        pub fn workerSchedulerMetricsSnapshot(self: *const Runtime) runtime_types.WorkerSchedulerMetrics {
            return scheduler_resources.workerSchedulerMetricsSnapshot(self);
        }

        pub fn armRequestDeadline(self: *Runtime, request: *request_context.RequestContext) !void {
            try scheduler_resources.armRequestDeadline(self, request);
        }

        pub fn disarmRequestDeadline(self: *Runtime, request: *request_context.RequestContext) void {
            scheduler_resources.disarmRequestDeadline(self, request);
        }

        pub fn requestDeadlineTerminationRequested(self: *Runtime, request: *const request_context.RequestContext) bool {
            return scheduler_resources.requestDeadlineTerminationRequested(self, request);
        }

        /// True only when the sentinel requested termination for this request's
        /// armed deadline, which leaves the VM unable to run JavaScript for good.
        /// It is not the clock-expiry half of
        /// `requestDeadlineTerminationRequested`: a 504 answered without a fire
        /// leaves the VM healthy and the worker in service. Read it before the
        /// disarm, which removes the entry and the bit with it.
        pub fn requestDeadlineSentinelFired(self: *Runtime, request: *const request_context.RequestContext) bool {
            if (!request.deadline_armed)
                return false;
            return self.observability.sentinel.terminationWasRequested(request.exec.request_id, request.deadline_generation);
        }

        fn releaseOwnedJsValues(allocator: std.mem.Allocator, args: ?[]js_value.JsValueOwned) void {
            const owned_args = args orelse return;
            for (owned_args) |*arg|
                arg.deinit();
            allocator.free(owned_args);
        }

        pub fn scheduleTimer(
            self: *Runtime,
            request_id: u64,
            callback: js_value.JsFunctionOwned,
            args: ?[]js_value.JsValueOwned,
            delay_ms: u32,
            repeats: bool,
        ) !u64 {
            if (self.bootIdentityClosed(request_id)) {
                var owned_callback = callback;
                owned_callback.deinit();
                releaseOwnedJsValues(self.core.allocator, args);
                return error.TimerOutsideActiveRequest;
            }
            return scheduler_resources.scheduleTimer(self, request_id, callback, args, delay_ms, repeats);
        }

        pub fn scheduleImmediate(
            self: *Runtime,
            request_id: u64,
            callback: js_value.JsFunctionOwned,
            this_arg: ?js_value.JsValueOwned,
            args: ?[]js_value.JsValueOwned,
        ) !u64 {
            if (self.bootIdentityClosed(request_id)) {
                var owned_callback = callback;
                owned_callback.deinit();
                if (this_arg) |owned_this| {
                    var owned = owned_this;
                    owned.deinit();
                }
                releaseOwnedJsValues(self.core.allocator, args);
                return error.TimerOutsideActiveRequest;
            }
            return scheduler_resources.scheduleImmediate(self, request_id, callback, this_arg, args);
        }

        pub fn scheduleTimeout(self: *Runtime, request_id: u64, callback: bindings.Value, delay_ms: u32) !u64 {
            if (self.bootIdentityClosed(request_id)) {
                var owned_callback = callback;
                owned_callback.deinit();
                return error.TimerOutsideActiveRequest;
            }
            return scheduler_resources.scheduleTimeout(self, request_id, callback, delay_ms);
        }

        /// The request a ready item belongs to, for the timeline and the turn
        /// telemetry. It is resolved at enqueue, because the maps it reads may
        /// lose the entry before the pop: an executed handler and a cancel both
        /// remove entries while the item still sits in the queue. An fs fault
        /// item spans several requests and has no single owner.
        pub fn readyItemOwnerRequestId(self: *Runtime, item: ready_queue_mod.WorkItem) u64 {
            return switch (item) {
                .request,
                .request_body_ready,
                .request_cancelled,
                .request_deadline,
                => |request_id| request_id,
                .request_completion => |token| if (self.requests.tasks.get(token)) |task|
                    task.request_id
                else
                    0,
                .fetch_completion => |fetch_id| if (self.egress.state.tasks.get(fetch_id)) |task|
                    task.request_id
                else
                    0,
                .fetch_body_ready => |body_id| if (self.egress.state.bodies.get(body_id)) |body|
                    body.identity.request_id
                else
                    0,
                .timer_callback => |timer_id| if (self.scheduler.ready_timer_callbacks.getPtr(timer_id)) |timer|
                    timer.request_id
                else
                    0,
                .immediate_callback => |immediate_id| if (self.scheduler.ready_immediate_callbacks.getPtr(immediate_id)) |immediate|
                    immediate.request_id
                else
                    0,
                .fs_fault_completion => 0,
            };
        }

        /// Queues `item` as ready now. Returns false when the queue and its
        /// backlog are both full, and the producer then keeps the item for a
        /// later pass (`scheduler/queue.zig` says how each kind is retried).
        pub fn tryQueueReadyWork(self: *Runtime, item: ready_queue_mod.WorkItem) bool {
            return self.tryQueueReadyWorkReadySince(item, 0);
        }

        /// `ready_since_mono_ns` is the producer's readiness stamp, such as a
        /// timer's deadline or a gateway completion's stamp, or 0 for ready at
        /// enqueue. It rides the queue slot so the timeline closes the I/O slice
        /// when the answer arrived, not when the loop drained it.
        pub fn tryQueueReadyWorkReadySince(
            self: *Runtime,
            item: ready_queue_mod.WorkItem,
            ready_since_mono_ns: u64,
        ) bool {
            const now = self.core.clock.now();
            const meta: ready_queue_mod.SlotMeta = .{
                .enqueued_mono_ns = now,
                .owner_request_id = self.readyItemOwnerRequestId(item),
                .ready_since_mono_ns = ready_since_mono_ns,
            };
            if (self.scheduler.ready_queue.tryPushStamped(item, meta)) {
                noteOwnerReady(self, meta);
                return true;
            }
            if (self.scheduler.ready_backlog.tryPushStamped(item, meta)) {
                noteOwnerReady(self, meta);
                self.wake();
                return true;
            }
            markReadyRescanNeeded(self, item);
            self.wake();
            return false;
        }

        fn noteOwnerReady(self: *Runtime, meta: ready_queue_mod.SlotMeta) void {
            if (meta.owner_request_id == 0 or meta.owner_request_id == request_context.boot_request_id)
                return;
            const ctx = self.requests.active.get(meta.owner_request_id) orelse return;
            ctx.noteReady(meta.ready_since_mono_ns, meta.enqueued_mono_ns, true);
        }

        pub fn drainReadyBacklog(self: *Runtime) void {
            self.scheduler.ready_backlog.drainInto(&self.scheduler.ready_queue);
        }

        fn markReadyRescanNeeded(self: *Runtime, item: ready_queue_mod.WorkItem) void {
            switch (item) {
                .request, .request_body_ready, .request_cancelled => {
                    self.scheduler.ingress_rescan_needed = true;
                },
                .request_completion => {
                    self.scheduler.request_completion_rescan_needed = true;
                },
                .request_deadline => {},
                .fetch_completion => {
                    self.egress.state.fetch_task_rescan_needed = true;
                },
                .fetch_body_ready => {
                    self.egress.state.fetch_body_rescan_needed = true;
                },
                .fs_fault_completion => {
                    self.fs_fault.rescan_needed = true;
                },
                .timer_callback, .immediate_callback => {},
            }
        }

        pub fn collectDueTimers(self: *Runtime) !void {
            try scheduler_resources.collectDueTimers(self);
        }

        pub fn collectReadyImmediates(self: *Runtime) !void {
            try scheduler_resources.collectReadyImmediates(self);
        }

        pub fn collectDueRequestDeadlines(self: *Runtime) !void {
            try scheduler_resources.collectDueRequestDeadlines(self);
        }

        pub fn nextRequestDeadlineNs(self: *Runtime) ?u64 {
            return scheduler_resources.nextRequestDeadlineNs(self);
        }

        pub fn cancelTimersForRequest(self: *Runtime, request_id: u64) void {
            scheduler_resources.cancelTimersForRequest(self, request_id);
            scheduler_resources.cancelImmediatesForRequest(self, request_id);
        }

        pub fn cancelTimeout(self: *Runtime, request_id: u64, timer_id: u64) void {
            scheduler_resources.cancelTimeout(self, request_id, timer_id);
        }

        pub fn cancelImmediate(self: *Runtime, request_id: u64, immediate_id: u64) void {
            scheduler_resources.cancelImmediate(self, request_id, immediate_id);
        }

        pub fn drainWakeup(self: *Runtime) void {
            const fd = self.scheduler.wakeup_fd orelse return;
            drainEventFd(fd, "worker wakeup");
        }

        pub fn drainIngressPayloadCredit(self: *Runtime) void {
            const fd = self.requests.ingress_payload_credit_eventfd orelse return;
            drainEventFd(fd, "worker ingress payload credit");
        }

        fn drainEventFd(fd: std.posix.fd_t, comptime name: []const u8) void {
            while (true) {
                var counter: u64 = 0;
                _ = std.posix.read(fd, std.mem.asBytes(&counter)) catch |err| switch (err) {
                    error.WouldBlock => return,
                    else => |unexpected| {
                        std.log.warn(name ++ " eventfd read failed: {s}", .{@errorName(unexpected)});
                        return;
                    },
                };
            }
        }

        pub fn wake(self: *Runtime) void {
            const fd = self.scheduler.wakeup_fd orelse return;
            var one: u64 = 1;
            _ = std.posix.write(fd, std.mem.asBytes(&one)) catch |err| switch (err) {
                error.WouldBlock => return,
                else => |unexpected| {
                    std.log.warn("worker wakeup eventfd write failed: {s}", .{@errorName(unexpected)});
                    return;
                },
            };
        }
    };
}

fn hashCapacity(value: usize) !u32 {
    if (value > std.math.maxInt(u32)) {
        return error.CapacityTooLarge;
    }
    return @intCast(value);
}

//! The event loop of an ingress lane thread in the server: the lane's one
//! io_uring, the dispatch of each completion to its handler, the handlers of
//! a worker registration's polls, the writability poll of a worker's control
//! socket, the shutdown drain, the renewal and the sends of the lane's
//! egress lease, and the per-lane arrays the loop serves (connection slots,
//! request slots, header buffers, IPC scratch).
//!
//! Invariants:
//! - The loop runs a handler per completion, per queued connection and per
//!   deferred worker fault, and each one returns `LaneFault!void`
//!   (`fault.loop_handlers`, checked in `root.zig`): a failure a client or a
//!   worker causes is settled inside the handler as a connection or worker
//!   outcome (`fault.zig`), so an error that leaves `run` is the lane's own.
//! - A handler runs to its end before the next one starts, and none runs
//!   another, except the deadline backstop, which first takes the worker's
//!   output or the lane's commands so that a completion that came in time
//!   wins over the fault (`deadline_driver.zig`).
//! - A completion of a worker registration's poll reaches its handler only
//!   while the registration still holds the worker it was armed for (its
//!   generation) and, for a poll only a reader arms, while the lane still
//!   reads that worker; any other completion is counted as stale.
//! - A pass first renews the lane's egress lease when the manager's current
//!   gateway is not the one the lease holds (`renewEgressLease`), and last
//!   sends the `request_ended` entries its finishes noted (`runQueuedWork`).
//!   It waits for a completion only after both, and the wait ends the pass,
//!   so no handler mints a token under a lease older than the lane's last
//!   wait and no entry sits in the batch while the lane sleeps.
//! - Shutdown refuses new work first (accepts in `accept_flow.zig`, new
//!   streams in `admission.zig`), then serves until no request of the lane is
//!   live and the lane reads no worker, because a reader that left would
//!   strand the output of another lane's request on a worker it read. It
//!   ends only with its command queue empty, closing the lane to posts in
//!   the same step, since a `dispatch_ready` queued and never run would hold
//!   a worker slot for good.
//! - Only the lane thread touches what `initRuntime` allocates and the
//!   egress lease. Teardown gives back what commands still queued hold,
//!   finishes every request, closes every connection, gives its reader roles
//!   back, sends the `request_ended` entries its finishes noted and closes
//!   the lease's descriptor, and checks that every slab is free again,
//!   asserting it after a clean stop; only then does it free the arrays.

const std = @import("std");
const linux = std.os.linux;

const ipc = @import("collo_ipc");
const http_common = @import("collo_http");
const limits = @import("collo_limits");
const uring_tags = @import("collo_io_uring_tags");
const accept = @import("../accept.zig");
const completions = @import("../completions.zig");
const fault = @import("../fault.zig");
const http2_writing = @import("../http2/writing.zig");
const lane_mod = @import("../lane.zig");
const accept_flow = @import("accept_flow.zig");
const command_flow = @import("command_flow.zig");
const connection_flow = @import("connection_flow.zig");
const connection_slot = @import("connection_slot.zig");
const deadline_driver = @import("deadline_driver.zig");
const dispatch = @import("dispatch.zig");
const event_sources = @import("event_sources.zig");
const fs_fault_control = @import("fs_fault_control.zig");
const request_finish = @import("request_finish.zig");
const request_slot = @import("request_slot.zig");
const work_queues = @import("work_queues.zig");
const worker_control = @import("worker_control.zig");
const worker_fault = @import("worker_fault.zig");
const worker_registration = @import("worker_registration.zig");

const LaneFault = fault.LaneFault;

/// Submission queue entries of the lane's io_uring, which carries the accept
/// and every poll the lane arms.
pub const accept_queue_depth: u16 = 64;
pub const max_header_buffers_per_lane: usize = 256;
pub const header_buffer_bytes: usize =
    http_common.http2.frame_header_len + limits.h2.INGRESS_MAX_FRAME_SIZE_BYTES;
/// Completions one drain takes from the ring.
const cqe_batch_max: usize = 64;
/// Ring calls in a row that may fail transiently (`fault.ringErrorIsTransient`)
/// before the lane reports the last failure. A failed wait is retried after
/// the loop reaps what the ring holds, which is what clears a completion
/// queue overflow, so only a ring that keeps failing that long is broken.
const ring_transient_failures_max: u32 = 64;
/// How long the shutdown drain waits before it looks again at the tenures it
/// still holds over workers busy with other lanes' requests. Those lanes give
/// their slots back to the pool without telling the reader, so nothing else
/// wakes the drain when the worker goes idle.
const shutdown_tenure_check_ns: u64 = std.time.ns_per_ms;

comptime {
    // An accept completion is told apart from every other one by its top
    // byte (`dispatchCqe`).
    for (std.enums.values(event_sources.EventKind)) |kind|
        std.debug.assert(@intFromEnum(kind) != uring_tags.server_ingress_high_byte);
}

/// Consecutive transient failures of the lane's ring calls. A completion
/// reaped resets the count.
const RingRetries = struct {
    failures: u32 = 0,

    fn note(self: *RingRetries, err: fault.RingError) LaneFault!void {
        if (!fault.ringErrorIsTransient(err))
            return err;
        self.failures += 1;
        if (self.failures >= ring_transient_failures_max)
            return err;
    }
};

/// Submits what is queued and waits until the ring holds a completion. A
/// transient failure, a signal interrupting the wait among them, ends the
/// wait and is counted (`RingRetries`).
fn waitForCompletion(ring: *linux.IoUring, retries: *RingRetries) LaneFault!void {
    _ = ring.submit_and_wait(1) catch |err| {
        try retries.note(err);
        return;
    };
}

pub fn Methods(comptime Self: type) type {
    return struct {
        const Accept = accept_flow.Methods(Self);
        const Command = command_flow.Methods(Self);
        const Connection = connection_flow.Methods(Self);
        const Deadlines = deadline_driver.Methods(Self);
        const Dispatch = dispatch.Methods(Self);
        const FsFaultControl = fs_fault_control.Methods(Self);
        const Queues = work_queues.Methods(Self);
        const RequestFinish = request_finish.Methods(Self);
        const WorkerControl = worker_control.Methods(Self);
        const WorkerFault = worker_fault.Methods(Self);
        const WorkerRegistration = worker_registration.Methods(Self);

        pub fn run(self: *Self) LaneFault!void {
            try initLane(self);
            defer deinitLane(self);

            try initRuntime(self);
            defer deinitRuntime(self);

            var ring = try linux.IoUring.init(accept_queue_depth, 0);
            defer ring.deinit();
            self.runtime_ring = &ring;
            defer self.runtime_ring = null;

            try armCommandPoll(self, &ring);
            try armTimerPoll(self, &ring);
            try Accept.ensureAcceptArmed(self, &ring);
            var terminal_state: event_sources.LaneRuntimeState = .exited;
            defer self.lane_state.store(@intFromEnum(terminal_state), .release);
            errdefer terminal_state = .failed;
            self.lane_state.store(@intFromEnum(event_sources.LaneRuntimeState.active), .release);
            var retries: RingRetries = .{};
            while (!self.service.shouldStop())
                try runPass(self, &ring, &retries);
            try self.handleStop();
        }

        /// Loop handler, run once the service is stopping: queues GOAWAY with
        /// no new streams on every HTTP/2 connection, serves until no request
        /// of the lane is live, it reads no worker and its command queue is
        /// empty, closes the lane to posts, then closes each connection still
        /// open.
        pub fn handleStop(self: *Self) LaneFault!void {
            const ring = self.runtime_ring orelse return error.IngressRingUnavailable;
            for (self.connection_slots) |*runtime| {
                if (!runtime.active or runtime.state != .http2_connection)
                    continue;
                // A connection that cannot take the frame still drains its
                // streams; the frame only spares a well-behaved client the
                // 503 a new stream gets now. The turn flushes it.
                try http2_writing.queueGoawayNoNewStreams(Self, self, runtime);
                Queues.enqueueConnection(self, runtime.key.slot);
            }
            var retries: RingRetries = .{};
            while (true) {
                try releaseIdleTenures(self);
                if (self.dynamic_request_count == 0 and !readsAnyWorker(self)) {
                    if (closeIfQueueEmpty(self))
                        break;
                    // A slot handed to a request that ended meanwhile is in
                    // the queue, and only running its `dispatch_ready` gives
                    // it back; a grant it carries can make the lane a reader
                    // again, which the next round sees.
                    try self.handleCommands();
                    _ = try runQueuedWork(self);
                    continue;
                }
                if (self.dynamic_request_count == 0) {
                    const now = self.monotonicNowNs();
                    try deadline_driver.armTimerNoLaterThan(Self, self, now, now +| shutdown_tenure_check_ns);
                }
                try runPass(self, ring, &retries);
            }
            for (self.connection_slots) |*runtime| {
                if (runtime.active)
                    try Connection.tearDownConnection(self, runtime);
            }
        }

        /// Loop handler: drives the connection in `slot`, whose read poll
        /// fired or which another handler queued for a turn.
        pub fn handleConnectionReadable(self: *Self, slot: u32) LaneFault!void {
            return driveSlot(self, slot);
        }

        /// Loop handler: drives the connection in `slot` after its write
        /// poll fired. A drive flushes the queued writes before it reads.
        pub fn handleConnectionWritable(self: *Self, slot: u32) LaneFault!void {
            return driveSlot(self, slot);
        }

        /// Loop handler: the reader drains the worker's control socket and
        /// re-arms its polls, or runs the death path on a fault.
        pub fn handleWorkerControlReadable(self: *Self, registration_index: u32) LaneFault!void {
            switch (try WorkerControl.drainWorkerControl(self, registration_index, .yield_to_backlog)) {
                .ok, .would_block => _ = try WorkerRegistration.armWorkerPolls(self, registration_index),
                .fault => |reason| try WorkerFault.faultWorker(self, registration_index, reason),
            }
        }

        /// Loop handler: the worker's control socket has room for the bytes
        /// this lane parked on it (`armWorkerControlWritable`).
        pub fn handleWorkerControlWritable(self: *Self, registration_index: u32) LaneFault!void {
            try Dispatch.flushBlockedSends(self, registration_index);
        }

        /// Loop handler: the reader answers the worker's fault requests and
        /// re-arms its polls, or runs the death path on a fault.
        pub fn handleWorkerFsFault(self: *Self, registration_index: u32) LaneFault!void {
            switch (try FsFaultControl.drainWorkerFsFault(self, registration_index)) {
                .ok, .would_block => _ = try WorkerRegistration.armWorkerPolls(self, registration_index),
                .fault => |reason| try WorkerFault.faultWorker(self, registration_index, reason),
            }
        }

        /// Loop handler: the worker's payload credit eventfd fired, so its
        /// server-to-worker ring may have room for the bodies this lane
        /// parked on it. Every lane polling the eventfd retries its own
        /// bodies whatever its read of the count found, since another lane's
        /// read may have taken the count first.
        pub fn handleWorkerPayloadCredit(self: *Self, registration_index: u32) LaneFault!void {
            const registration = try registrationAt(self, registration_index);
            const wakes = event_sources.drainEventFd(registration.ingress_payload_credit_eventfd) catch |err| wakes: {
                switch (try fault.classifyWorkerError(.{ .wake = err })) {
                    .ok, .would_block => break :wakes 0,
                    .fault => |reason| return WorkerFault.faultWorker(self, registration_index, reason),
                }
            };
            self.lane.counters.h2_request_body_credit_wakes += wakes;
            try Dispatch.flushBlockedSends(self, registration_index);
        }

        /// Loop handler: the pidfd of a worker this lane reads reported its
        /// exit.
        pub fn handleWorkerPidfd(self: *Self, registration_index: u32) LaneFault!void {
            try WorkerFault.faultWorker(self, registration_index, .exited);
        }

        /// Arms a one-shot writability poll on the worker's control socket
        /// for a send of this lane that would block; its completion runs
        /// `handleWorkerControlWritable`. A poll already in flight serves.
        pub fn armWorkerControlWritable(self: *Self, registration_index: u32) LaneFault!void {
            const registration = try registrationAt(self, registration_index);
            if (registration.control_writable_poll_registered)
                return;
            const ring = self.runtime_ring orelse return error.IngressRingUnavailable;
            try self.runtime_events.queuePoll(
                ring,
                registration.control_fd,
                event_sources.pollMask(event_sources.write_events),
                .{ .kind = .worker_control_writable, .index = registration_index, .generation = registration.generation },
            );
            registration.control_writable_poll_registered = true;
        }

        pub fn initRuntime(self: *Self) LaneFault!void {
            self.connection_slots = try self.service.allocator.alloc(
                connection_slot.Slot,
                self.lane.state.connections.slots.len,
            );
            errdefer self.service.allocator.free(self.connection_slots);
            @memset(self.connection_slots, .{});

            self.pre_request_deadlines = try connection_slot.PreRequestDeadlineHeap.initCapacity(
                self.service.allocator,
                {},
                self.connection_slots.len,
            );
            errdefer {
                Deadlines.preRequestDeadlineHeap(self).deinit();
                self.pre_request_deadlines = null;
            }

            self.ready_connections = try work_queues.ReadyQueue.init(
                self.service.allocator,
                self.connection_slots.len,
            );
            errdefer self.ready_connections.deinit(self.service.allocator);

            self.dynamic_requests = try self.service.allocator.alloc(
                request_slot.RequestSlot,
                self.lane.state.requests.slots.len,
            );
            errdefer self.service.allocator.free(self.dynamic_requests);
            @memset(self.dynamic_requests, .{});
            self.dynamic_request_count = 0;

            self.ipc_send_scratch = try self.service.allocator.alloc(u8, ipc.max_message_bytes);
            errdefer {
                self.service.allocator.free(self.ipc_send_scratch);
                self.ipc_send_scratch = &.{};
            }
            self.ipc_recv_scratch = try self.service.allocator.alloc(u8, ipc.max_message_bytes);
            errdefer {
                self.service.allocator.free(self.ipc_recv_scratch);
                self.ipc_recv_scratch = &.{};
            }

            self.header_buffers = try work_queues.HeaderBufferPool.init(
                self.service.allocator,
                self.connection_slots.len,
                max_header_buffers_per_lane,
                header_buffer_bytes,
            );
            errdefer self.header_buffers.deinit(self.service.allocator);

            self.runtime_events = try event_sources.EventSet.init();
        }

        pub fn initLane(self: *Self) LaneFault!void {
            if (self.lane_initialized)
                return;
            self.lane = try lane_mod.IngressLane.init(
                self.service.allocator,
                .{
                    .lane_id = self.listener_index,
                    .command_obligation_reserve = lane_mod.obligationReserve(
                        self.service.routes.definitionCount(),
                    ),
                },
                self.monotonicNowNs(),
            );
            // `lane_initialized` flips under both locks, `runtime_mutex` first:
            // command producers read it under `runtime_mutex` (`post` in
            // `root.zig`) and counter snapshots under `counters_mutex`
            // (`countersSnapshot` in `root.zig`).
            self.runtime_mutex.lock();
            defer self.runtime_mutex.unlock();
            self.counters_mutex.lock();
            defer self.counters_mutex.unlock();
            self.lane_initialized = true;
        }

        pub fn deinitLane(self: *Self) void {
            self.runtime_mutex.lock();
            defer self.runtime_mutex.unlock();
            self.counters_mutex.lock();
            defer self.counters_mutex.unlock();
            if (!self.lane_initialized)
                return;
            self.retained_counters.add(self.lane.countersSnapshot());
            self.lane_initialized = false;
            self.lane.deinit();
        }

        /// Runs after the ring is gone and the lane stopped taking posts.
        /// After a clean `handleStop` no request is live, no connection open,
        /// no worker read and no command queued. After a lane fault it gives
        /// back what the commands still queued hold, ends each request still
        /// live as `.shutdown`, closes each connection, and tells the other
        /// lanes and the pool what each registration still owes them
        /// (`worker_registration.endRegistrationAtTeardown`); the server is
        /// stopping then.
        pub fn deinitRuntime(self: *Self) void {
            // `run` stores `.exited` only when `handleStop` returned, and a
            // lane fault stores `.failed` before this runs.
            const stopped_clean = self.state() == .exited;
            var teardown_failed = false;
            Command.returnQueuedHandoffs(self) catch |err| {
                teardown_failed = true;
                noteTeardownFailure(self, "give back a queued handoff", err);
            };
            for (self.dynamic_requests, 0..) |*active, index| {
                if (!active.active)
                    continue;
                RequestFinish.finishRequest(self, @intCast(index), .shutdown) catch |err| {
                    teardown_failed = true;
                    noteTeardownFailure(self, "finish a request", err);
                };
            }
            for (self.connection_slots) |*runtime| {
                if (!runtime.active)
                    continue;
                Connection.tearDownConnection(self, runtime) catch |err| {
                    teardown_failed = true;
                    noteTeardownFailure(self, "close a connection", err);
                };
            }
            for (self.completion_registrations[0..self.completion_registration_count], 0..) |*registration, index| {
                if (!registration.inUse())
                    continue;
                WorkerRegistration.endRegistrationAtTeardown(self, @intCast(index)) catch |err| {
                    teardown_failed = true;
                    noteTeardownFailure(self, "end a worker registration", err);
                };
            }
            // The ring took the registrations' polls with it, and a
            // registration owns nothing else: its descriptors are the
            // worker's record's.
            self.completion_registration_count = 0;
            // The finishes above noted their `request_ended` entries on the
            // lease, which sends them before it closes its descriptor. Its
            // counts move into the retained counters in the same critical
            // section that resets it, so a snapshot counts them once.
            self.egress_lease.flush();
            {
                self.counters_mutex.lock();
                defer self.counters_mutex.unlock();
                self.retained_counters.egress_ended_batches_dropped_full += self.egress_lease.ended_batches_dropped_full;
                self.retained_counters.egress_ended_batches_dropped_closed += self.egress_lease.ended_batches_dropped_closed;
                self.egress_lease.deinit();
                self.egress_lease = .{};
            }
            // Every request is finished and every connection closed, so each
            // liveness count must be zero here. The runner's count and the
            // lane slabs' free lists are kept by different code on different
            // paths, so their agreement is a real cross-check. Nothing else
            // would notice a slot that never comes back: the slabs are
            // preallocated, so a leaked slot moves no RSS, passes through no
            // allocator and stays invisible to a leak checker until the slab
            // runs out and new work is refused. A teardown that failed, or one
            // after a lane fault, broke the state these counts describe, so
            // it reports a disagreement instead of asserting.
            if (stopped_clean and !teardown_failed) {
                std.debug.assert(self.dynamic_request_count == 0);
                std.debug.assert(self.lane.state.requests.free_len == self.lane.state.requests.slots.len);
                std.debug.assert(self.lane.state.connections.free_len == self.lane.state.connections.slots.len);
                std.debug.assert(self.header_buffers.free_count == self.header_buffers.free_slots.len);
                std.debug.assert(self.lane.deadline_wheel.free_len == self.lane.deadline_wheel.entries.len);
            } else if (!livenessCountsClear(self)) {
                std.log.err(
                    "ingress lane {d} tore down with state still held: requests={d} request_slots_free={d}/{d} connection_slots_free={d}/{d}",
                    .{
                        self.listener_index,
                        self.dynamic_request_count,
                        self.lane.state.requests.free_len,
                        self.lane.state.requests.slots.len,
                        self.lane.state.connections.free_len,
                        self.lane.state.connections.slots.len,
                    },
                );
            }
            if (self.pre_request_deadlines) |*heap| {
                heap.deinit();
                self.pre_request_deadlines = null;
            }
            self.pre_request_deadline_count = 0;
            self.header_buffers.deinit(self.service.allocator);
            self.runtime_events.deinit();
            if (self.ipc_send_scratch.len != 0) {
                self.service.allocator.free(self.ipc_send_scratch);
                self.ipc_send_scratch = &.{};
            }
            if (self.ipc_recv_scratch.len != 0) {
                self.service.allocator.free(self.ipc_recv_scratch);
                self.ipc_recv_scratch = &.{};
            }
            self.service.allocator.free(self.dynamic_requests);
            self.ready_connections.deinit(self.service.allocator);
            self.service.allocator.free(self.connection_slots);
            self.connection_slots = &.{};
            self.ready_connections = .{};
            self.dynamic_requests = &.{};
            self.header_buffers = .{};
            self.lane.accept_registration = .{};
        }

        /// A failure met while tearing the lane down: the server stops, and
        /// the teardown goes on with the rest.
        fn noteTeardownFailure(self: *Self, comptime what: []const u8, err: LaneFault) void {
            self.service.requestStopSignal();
            std.log.err("ingress lane {d} failed to " ++ what ++ " at teardown: {s}", .{ self.listener_index, @errorName(err) });
        }

        /// Whether no request, request slot, connection slot, header buffer
        /// or wheel entry of the lane is still held.
        fn livenessCountsClear(self: *Self) bool {
            if (self.dynamic_request_count != 0) return false;
            if (self.lane.state.requests.free_len != self.lane.state.requests.slots.len) return false;
            if (self.lane.state.connections.free_len != self.lane.state.connections.slots.len) return false;
            if (self.header_buffers.free_count != self.header_buffers.free_slots.len) return false;
            return self.lane.deadline_wheel.free_len == self.lane.deadline_wheel.entries.len;
        }

        fn armCommandPoll(self: *Self, ring: *linux.IoUring) LaneFault!void {
            try self.runtime_events.queuePoll(
                ring,
                self.lane.command_queue.commandEventFd(),
                event_sources.pollMask(event_sources.read_events),
                .{ .kind = .command },
            );
        }

        fn armTimerPoll(self: *Self, ring: *linux.IoUring) LaneFault!void {
            try self.runtime_events.queuePoll(
                ring,
                self.runtime_events.timer_fd,
                event_sources.pollMask(event_sources.read_events),
                .{ .kind = .deadline_timer },
            );
        }

        /// One turn of the loop: renews the egress lease when the gateway
        /// changed, re-arms the accept when it is due, submits what a
        /// transient failure left queued, runs the completions the ring holds
        /// and the rest of the pass (`runQueuedWork`), and waits for a
        /// completion when none of that found work. The completions the wait
        /// brings run in the next pass, after its renewal.
        fn runPass(self: *Self, ring: *linux.IoUring, retries: *RingRetries) LaneFault!void {
            renewEgressLease(self);
            if (!self.service.shouldStop()) {
                _ = self.lane.accept_registration.finishBackoff(self.monotonicNowNs());
                if (self.lane.accept_registration.state == .inactive)
                    try Accept.ensureAcceptArmed(self, ring);
            }
            if (ring.sq_ready() != 0)
                try event_sources.submitPending(ring);
            var did_work = try drainRingCqes(self, ring, retries);
            did_work = (try runQueuedWork(self)) or did_work;
            if (!did_work)
                try waitForCompletion(ring, retries);
        }

        /// Gives the lane's egress lease the current gateway's key and a
        /// descriptor of its control socket, or empties it while no gateway
        /// is current (`Manager.renewLease` in `server/gateway/manager.zig`),
        /// when the manager's current gateway is not the one the lease holds.
        /// Comparing the generations is one atomic load, so every pass makes
        /// it, and only a gateway change takes the manager's mutex.
        pub fn renewEgressLease(self: *Self) void {
            const gateways = self.service.egress_gateways;
            if (gateways.currentGeneration() != self.egress_lease.generation)
                gateways.renewLease(&self.egress_lease);
        }

        /// The rest of a pass after the completions it ran: the connections
        /// handlers queued for a turn, then the worker faults they deferred,
        /// then one `request_ended` packet with the entries the pass's
        /// finishes noted on the egress lease (`Lease.flush`), which never
        /// waits. Returns whether the connections or the faults found work.
        pub fn runQueuedWork(self: *Self) LaneFault!bool {
            const drove = try driveQueuedConnections(self);
            const faulted = try WorkerFault.processDeferredWorkerFaults(self);
            self.egress_lease.flush();
            return drove or faulted;
        }

        /// Takes the completions the ring holds without waiting and runs
        /// each one's handler. Returns whether it took any. A transient
        /// failure gives up this turn and is counted (`RingRetries`).
        fn drainRingCqes(self: *Self, ring: *linux.IoUring, retries: *RingRetries) LaneFault!bool {
            var cqes: [cqe_batch_max]linux.io_uring_cqe = undefined;
            const ready = ring.copy_cqes(&cqes, 0) catch |err| {
                try retries.note(err);
                return false;
            };
            if (ready == 0)
                return false;
            retries.failures = 0;
            for (cqes[0..ready]) |cqe|
                try dispatchCqe(self, ring, cqe);
            return true;
        }

        /// Runs the handler a completion names, after the poll bookkeeping:
        /// a one-shot poll that completed is no longer in flight. A completion
        /// for a connection or a registration that has moved on, or one of a
        /// poll the lane cancelled, is counted as stale. Every user_data was
        /// packed by the lane, so one that decodes to nothing is a lane fault.
        fn dispatchCqe(self: *Self, ring: *linux.IoUring, cqe: linux.io_uring_cqe) LaneFault!void {
            if (accept.unpackAcceptUserData(cqe.user_data)) |_| {
                return self.handleAcceptCqe(cqe);
            } else |err| switch (err) {
                error.InvalidUserDataTag => {},
                error.InvalidLaneId => return error.InvalidLaneId,
            }
            const data = try event_sources.unpackEventData(cqe.user_data);
            switch (data.kind) {
                .command => {
                    try self.handleCommands();
                    try armCommandPoll(self, ring);
                },
                .deadline_timer => {
                    try self.handleDeadlineTimer();
                    try armTimerPoll(self, ring);
                },
                .connection_poll_cancel => self.lane.counters.connection_poll_cancel_cqes += 1,
                .worker_poll_cancel => self.lane.counters.worker_poll_cancel_cqes += 1,
                .connection, .connection_read, .connection_write => {
                    if (data.index >= self.connection_slots.len) {
                        self.lane.counters.stale_connection_cqe += 1;
                        return;
                    }
                    const runtime = &self.connection_slots[data.index];
                    if (!runtime.active or
                        connection_slot.connectionGenerationTag(runtime.key) != data.generation)
                    {
                        self.lane.counters.stale_connection_cqe += 1;
                        return;
                    }
                    switch (data.kind) {
                        .connection_write => {
                            runtime.registered_wait_events &= ~event_sources.write_interest;
                            try self.handleConnectionWritable(data.index);
                        },
                        .connection_read => {
                            runtime.registered_wait_events &= ~event_sources.read_interest;
                            try self.handleConnectionReadable(data.index);
                        },
                        else => {
                            runtime.registered_wait_events = 0;
                            try self.handleConnectionReadable(data.index);
                        },
                    }
                },
                .worker_completion => if (workerPollReady(self, data, cqe.res))
                    try self.handleWorkerCompletions(data.index),
                .worker_control => if (workerPollReady(self, data, cqe.res))
                    try self.handleWorkerControlReadable(data.index),
                .worker_control_writable => if (workerPollReady(self, data, cqe.res))
                    try self.handleWorkerControlWritable(data.index),
                .worker_payload_credit => if (workerPollReady(self, data, cqe.res))
                    try self.handleWorkerPayloadCredit(data.index),
                .worker_fs_fault => if (workerPollReady(self, data, cqe.res))
                    try self.handleWorkerFsFault(data.index),
                .worker_pidfd => if (workerPollReady(self, data, cqe.res))
                    try self.handleWorkerPidfd(data.index),
            }
        }

        /// Takes the completion of a worker registration's poll: clears its
        /// in-flight flag and returns whether it reports readiness for the
        /// handler. A completion for a registration that moved on, or of a
        /// poll a cancel removed (ECANCELED), is counted as stale.
        fn workerPollReady(self: *Self, data: event_sources.EventData, result: i32) bool {
            const registration = registrationForCqe(self, data) orelse {
                self.lane.counters.stale_worker_poll_cqes += 1;
                return false;
            };
            const in_flight = pollInFlight(registration, data.kind) orelse {
                self.lane.counters.stale_worker_poll_cqes += 1;
                return false;
            };
            in_flight.* = false;
            if (result == -@as(i32, @intFromEnum(linux.E.CANCELED))) {
                self.lane.counters.stale_worker_poll_cqes += 1;
                return false;
            }
            return true;
        }

        /// The registration a worker poll's completion names, or null when
        /// the place was freed or holds a later worker since the poll was
        /// armed, or when the poll is one only a reader arms and the lane no
        /// longer reads the worker.
        fn registrationForCqe(self: *Self, data: event_sources.EventData) ?*completions.Registration {
            if (data.index >= self.completion_registration_count)
                return null;
            const registration = &self.completion_registrations[data.index];
            if (!registration.inUse())
                return null;
            if (registration.generation != data.generation)
                return null;
            switch (data.kind) {
                .worker_completion, .worker_control, .worker_fs_fault, .worker_pidfd => {
                    if (!registration.reading())
                        return null;
                },
                else => {},
            }
            return registration;
        }

        /// Drives the connections handlers queued for a turn, each once per
        /// pass at most as many times as the lane has connection slots, so a
        /// connection that queues itself again cannot hold the loop.
        fn driveQueuedConnections(self: *Self) LaneFault!bool {
            var did_work = false;
            var budget = self.connection_slots.len;
            while (budget != 0) : (budget -= 1) {
                const slot = Queues.popConnection(self) orelse break;
                did_work = true;
                try self.handleConnectionReadable(slot);
            }
            return did_work;
        }

        /// Drives the connection in `slot` (`connection_flow.driveConnection`),
        /// counting a slot out of range as stale.
        fn driveSlot(self: *Self, slot: u32) LaneFault!void {
            if (slot >= self.connection_slots.len) {
                self.lane.counters.stale_connection_cqe += 1;
                return;
            }
            _ = try Connection.driveConnection(self, slot);
        }

        /// The registration at `registration_index`, which must hold a
        /// worker: a handler reaches one only through a completion or a call
        /// that checked it, so anything else is the lane's own mistake.
        fn registrationAt(self: *Self, registration_index: u32) LaneFault!*completions.Registration {
            if (registration_index >= self.completion_registration_count)
                return error.InvalidCompletionRegistration;
            const registration = &self.completion_registrations[registration_index];
            if (!registration.inUse())
                return error.InvalidCompletionRegistration;
            return registration;
        }

        /// Gives up every tenure over a worker on which the lane has no
        /// request, as the shutdown drain needs. A tenure over a worker other
        /// lanes still use stays (`Pool.transferReader` answers `.kept`).
        fn releaseIdleTenures(self: *Self) LaneFault!void {
            for (self.completion_registrations[0..self.completion_registration_count], 0..) |*registration, index| {
                if (!registration.inUse() or !registration.reading())
                    continue;
                if (registration.inflight_request_len != 0)
                    continue;
                _ = try Command.giveUpTenure(self, @intCast(index));
            }
        }

        /// Closes the lane to commands when its queue is empty, and says
        /// whether it did. The check and the close run under `runtime_mutex`,
        /// which every post holds from its check of the lane's state through
        /// its push (`post` in `root.zig`), so a post lands before the close
        /// and is seen here, or after it and is refused to its sender, which
        /// keeps what it carried (`lane_commands.zig`).
        fn closeIfQueueEmpty(self: *Self) bool {
            self.runtime_mutex.lock();
            defer self.runtime_mutex.unlock();
            if (self.lane.command_queue.pending() != 0)
                return false;
            self.lane_state.store(@intFromEnum(event_sources.LaneRuntimeState.closed), .release);
            return true;
        }

        fn readsAnyWorker(self: *Self) bool {
            for (self.completion_registrations[0..self.completion_registration_count]) |*registration| {
                if (registration.inUse() and registration.reading())
                    return true;
            }
            return false;
        }
    };
}

/// The in-flight flag of a registration's poll of `kind`; null for a kind
/// no registration polls.
fn pollInFlight(registration: *completions.Registration, kind: event_sources.EventKind) ?*bool {
    return switch (kind) {
        .worker_completion => &registration.poll_registered,
        .worker_control => &registration.control_poll_registered,
        .worker_control_writable => &registration.control_writable_poll_registered,
        .worker_payload_credit => &registration.ingress_payload_credit_poll_registered,
        .worker_fs_fault => &registration.fs_fault_poll_registered,
        .worker_pidfd => &registration.pidfd_poll_registered,
        .command,
        .deadline_timer,
        .connection,
        .connection_read,
        .connection_write,
        .connection_poll_cancel,
        .worker_poll_cancel,
        => null,
    };
}

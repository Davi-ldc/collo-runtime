//! The server's ingress lane runner: one `LaneWorker` per listener, each
//! running its own io_uring event loop on a lane thread pinned to the CPU the
//! service assigned it. A lane accepts client connections, runs their TLS
//! handshake and HTTP/2, admits each request into the pool of its route's
//! worker definition, dispatches it on a worker slot, reads the workers it is
//! the reader of on behalf of every lane, and answers the client from the
//! worker's response.
//!
//! Once `threadMain` enters the event loop (`run` in `ring_driver.zig`), the
//! lane thread is the only mutator of connection slots, request slots, worker
//! registrations, runtime events and header buffers. Other threads may only
//! post commands (`post`, under `runtime_mutex`), snapshot counters under
//! `counters_mutex`, read `lane_state`, and drain `access_ring` (the metrics
//! thread). `prepareStart` and `deinit` run on the service's thread while the
//! lane thread is not running. A flow file must not spawn a thread, block the
//! lane thread outside the ring wait, or change lane state from another
//! thread.
//!
//! The flow files are generic over the lane type, as `Methods(Self)` mixins
//! or as functions that take it, and call each other through the owning
//! file's `Methods(Self)`. Besides its own functions, `LaneWorker` declares
//! only what callers reach through the lane type: the loop's handlers, which
//! the event loop calls on the lane and `fault.assertLoopHandlers` checks
//! against `fault.loop_handlers`, and the calls the HTTP/2 driver makes on
//! its `Worker` (`http2/connection.zig`).
//!
//! The loop's handlers return only `LaneFault`, and a lane fault is the only
//! error `run` returns. `threadMain` stops the server on one, or when the
//! lane cannot be pinned to its CPU, and on nothing else.
//!
//! The service a lane runs under provides `allocator`, `supervisor`,
//! `routes`, `analytics`, `tls_context`, `hard_timeout_grace_ns`,
//! `ingress_tcp_notsent_lowat_bytes`, `lanes`, `launcher` (`submit`),
//! `reaper` (`wakeForPidfdScan`), `egress_gateways` (`currentGeneration`,
//! `renewLease`), `shouldStop`, `requestStopSignal`, `allocateRequestId`,
//! `postToLane` and `queueRetirement` (`service.zig`).
//! A flow file reaches the service only through these, and imports none of
//! the service's files.
//!
//! Which file holds what:
//! - This file: `LaneWorker` with its fields, its start, thread entry and
//!   teardown, its command posts, and the declarations above.
//! - `ring_driver.zig`: the event loop, the completion dispatch, the worker
//!   handlers, the writability poll of a worker's control socket, the
//!   shutdown drain and the lane's allocations; `event_sources.zig`: the
//!   user_data encoding, poll masks, submissions and the deadline timerfd;
//!   `work_queues.zig`: the queues of connections waiting for a turn and of
//!   deferred worker faults, and the header buffers.
//! - `accept_flow.zig`, `tls_handshake.zig` and `connection_flow.zig`:
//!   client connections from accept to close; `connection_slot.zig`: a
//!   connection's state, with its HTTP/2 stream table in `stream_table.zig`,
//!   its flow-control windows and buffered request bodies in
//!   `flow_control.zig`, and its write queue and buffered responses in
//!   `write_queue.zig`.
//! - `admission.zig`: a new stream's route match, its admission into the
//!   pool, the launch or the 503 that follows when the pool cannot serve its
//!   waiters, and the answers the lane writes alone; `dispatch.zig`: dispatch
//!   to a worker slot, the begin and reset sends and every send that waits
//!   for room; `request_body.zig`: request bodies and client resets;
//!   `request_slot.zig`: the lane's slot of each request it admitted;
//!   `h2_worker_ipc.zig`: worker response descriptors, read or forwarded.
//! - `worker_completions.zig`: worker completions; `request_finish.zig`: the
//!   end of a request and the worker slot it gives back; `worker_fault.zig`:
//!   a worker's death path; `worker_registration.zig`: the lane's
//!   registration of each worker it sends to or reads, with the reader
//!   tenure; `worker_control.zig` and `fs_fault_control.zig`: a worker's
//!   control and fs-fault channels.
//! - `deadline_driver.zig`: request and pre-request deadlines.
//! - `command_flow.zig`: the lane's commands and the reader role it gives
//!   up.

const std = @import("std");
const linux = std.os.linux;
const process = @import("collo_os").process;

const supervision = @import("collo_server_supervisor");
const gateway = @import("collo_server_gateway");
const access_log = @import("collo_server_analytics").access;
const server_limits = @import("collo_limits").server;
const accept = @import("../accept.zig");
const commands = @import("../commands.zig");
const completions = @import("../completions.zig");
const fault = @import("../fault.zig");
const lane_mod = @import("../lane.zig");
const ingress_state = @import("../state.zig");
const lane_plan = @import("../../net/lane_plan.zig");
const timer_wheel = @import("../timer_wheel.zig");
pub const event_sources = @import("event_sources.zig");
pub const worker_completions = @import("worker_completions.zig");
pub const connection_slot = @import("connection_slot.zig");
pub const stream_table = @import("stream_table.zig");
pub const flow_control = @import("flow_control.zig");
pub const write_queue = @import("write_queue.zig");
pub const deadline_driver = @import("deadline_driver.zig");
pub const ring_driver = @import("ring_driver.zig");
pub const accept_flow = @import("accept_flow.zig");
pub const connection_flow = @import("connection_flow.zig");
pub const command_flow = @import("command_flow.zig");
pub const request_finish = @import("request_finish.zig");
pub const worker_fault = @import("worker_fault.zig");
pub const worker_registration = @import("worker_registration.zig");
pub const work_queues = @import("work_queues.zig");
pub const admission = @import("admission.zig");
pub const dispatch = @import("dispatch.zig");
pub const request_body = @import("request_body.zig");
pub const h2_worker_ipc = @import("h2_worker_ipc.zig");
pub const worker_control = @import("worker_control.zig");
pub const fs_fault_control = @import("fs_fault_control.zig");
pub const request_slot = @import("request_slot.zig");
pub const tls_handshake = @import("tls_handshake.zig");

const LaneFault = fault.LaneFault;
const pool = supervision.pool;

/// Workers one lane can register at once: every worker the node can have, so
/// a lane never runs out while each worker holds one registration per lane.
const max_completion_registrations: usize =
    server_limits.worker_definitions_max * supervision.scheduler_limits.capacity.pool_workers_max;
const max_header_buffers_per_lane: usize = ring_driver.max_header_buffers_per_lane;
const header_buffer_bytes: usize = ring_driver.header_buffer_bytes;

pub const LaneRuntimeState = event_sources.LaneRuntimeState;

/// A lane's footprint for the lane plan. The command queue is counted with
/// the reserve of the largest configuration (`lane_mod.obligationReserve`),
/// since the plan runs before the lanes know their definitions' count.
pub fn laneMemoryShape() lane_plan.MemoryShape {
    const config = lane_mod.Config{};
    return .{
        .connection_slot_bytes = @sizeOf(ingress_state.ConnectionSlot),
        .request_slot_bytes = @sizeOf(ingress_state.RequestSlot),
        .deadline_entry_bytes = timer_wheel.entrySizeBytes(),
        .command_bytes = @sizeOf(commands.Command),
        .active_request_bytes = @sizeOf(RequestSlot),
        .runner_connection_bytes = @sizeOf(connection_slot.Slot),
        .max_connections = config.max_connections,
        .max_requests = config.max_requests,
        .command_capacity = config.command_queue_capacity +
            lane_mod.obligationReserve(server_limits.worker_definitions_max),
        .header_buffer_count = max_header_buffers_per_lane,
        .header_buffer_bytes = header_buffer_bytes,
    };
}

const ConnectionSlot = connection_slot.Slot;
const RequestSlot = request_slot.RequestSlot;

pub fn LaneWorker(comptime Service: type) type {
    return struct {
        const Self = @This();
        pub const ServiceType = Service;

        service: *Service = undefined,
        listener: *std.net.Server = undefined,
        listener_index: u16,
        cpu_id: ?usize = null,
        lane: lane_mod.IngressLane = undefined,
        lane_initialized: bool = false,
        retained_counters: lane_mod.CounterSnapshot = .{},
        /// Access-record handoff: the lane thread pushes one record per
        /// request when the request finishes, and the metrics thread drains
        /// it every tick (`analytics_drain.zig`). One producer and one
        /// consumer, so it takes no mutex. It lives on the `LaneWorker`, not
        /// on `lane`, so it survives the lane's re-initialization like
        /// `retained_counters`.
        access_ring: access_log.AccessRing = .{},
        counters_mutex: std.Thread.Mutex = .{},
        /// Held by a producer from the running check through its post, and
        /// by `deinitLane` while it destroys the queue, so a command never
        /// lands in a queue being torn down. Comes after every pool mutex
        /// and before the queue's own (`commands.zig`).
        runtime_mutex: std.Thread.Mutex = .{},
        thread: ?std.Thread = null,
        /// What stopped the lane: a lane fault from `run`, or the CPU pin.
        run_error: ?anyerror = null,
        lane_state: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(LaneRuntimeState.exited)),
        accept_counters: accept.Counters = .{},
        /// Registrations `[0, completion_registration_count)` have been used;
        /// a free one among them is taken again before the count grows
        /// (`worker_registration.registrationFor`).
        completion_registrations: [max_completion_registrations]completions.Registration = undefined,
        completion_registration_count: usize = 0,
        /// Registrations whose worker fault waits for the end of the handler
        /// that met it (`worker_fault.deferWorkerFault`); the loop runs
        /// them on every pass.
        ready_death_regs: work_queues.DeathQueue(max_completion_registrations) = .{},
        connection_slots: []ConnectionSlot = &.{},
        pre_request_deadlines: ?connection_slot.PreRequestDeadlineHeap = null,
        ready_connections: work_queues.ReadyQueue = .{},
        dynamic_requests: []RequestSlot = &.{},
        dynamic_request_count: usize = 0,
        /// Finishes that found nothing counted. Non-zero means this counter and
        /// the request slab disagree about how many requests are live, which is
        /// the only sign a leaked slab slot leaves: a slot that never comes back
        /// moves no RSS and passes through no allocator, so a divergence nobody
        /// records is indistinguishable from health until the slab runs out.
        dynamic_request_underflow: u64 = 0,
        header_buffers: work_queues.HeaderBufferPool = .{},
        pre_request_deadline_count: usize = 0,
        runtime_events: event_sources.EventSet = .{},
        runtime_ring: ?*linux.IoUring = null,
        ipc_send_scratch: []u8 = &.{},
        ipc_recv_scratch: []u8 = &.{},
        tcp_notsent_lowat_warning_logged: bool = false,
        /// The key this lane mints egress tokens with and its own descriptor
        /// for `request_ended`, renewed at the start of a loop pass when the
        /// gateway generation moved (`ring_driver.zig`). Only the lane thread
        /// touches it.
        egress_lease: gateway.lease.Lease = .{},

        comptime {
            fault.assertLoopHandlers(Self);
        }

        pub fn state(self: *const Self) LaneRuntimeState {
            return @enumFromInt(self.lane_state.load(.acquire));
        }

        pub fn running(self: *const Self) bool {
            return switch (self.state()) {
                .warming, .active => true,
                .closed, .exited, .failed => false,
            };
        }

        pub fn prepareStart(self: *Self, service: *Service, listener: *std.net.Server) !void {
            self.service = service;
            self.listener = listener;
            self.run_error = null;
            if (self.lane_initialized)
                return error.IngressLaneStillDraining;
            self.lane_state.store(@intFromEnum(LaneRuntimeState.warming), .release);
        }

        pub fn deinit(self: *Self) void {
            if (self.lane_initialized)
                ring_driver.Methods(Self).deinitLane(self);
            self.* = undefined;
        }

        pub fn countersSnapshot(self: *const Self) lane_mod.CounterSnapshot {
            const mutex = @constCast(&self.counters_mutex);
            mutex.lock();
            defer mutex.unlock();
            var snapshot = self.retained_counters;
            if (self.lane_initialized)
                snapshot.add(self.lane.countersSnapshot());
            // The lease outlives the lane's state; its teardown moves these
            // into `retained_counters` under the same mutex.
            snapshot.egress_ended_batches_dropped_full += self.egress_lease.ended_batches_dropped_full;
            snapshot.egress_ended_batches_dropped_closed += self.egress_lease.ended_batches_dropped_closed;
            return snapshot;
        }

        pub fn threadMain(self: *Self) void {
            if (self.cpu_id) |cpu_id| {
                lane_plan.pinCurrentThreadToCpu(cpu_id) catch |err| {
                    self.run_error = err;
                    self.lane_state.store(@intFromEnum(LaneRuntimeState.failed), .release);
                    self.service.requestStopSignal();
                    std.log.err("ingress lane {d} failed to pin to cpu {d}: {s}", .{
                        self.listener_index,
                        cpu_id,
                        @errorName(err),
                    });
                    return;
                };
            }
            ring_driver.Methods(Self).run(self) catch |err| {
                self.run_error = err;
                self.lane_state.store(@intFromEnum(LaneRuntimeState.failed), .release);
                self.service.requestStopSignal();
                std.log.err("ingress lane {d} failed: {s}", .{ self.listener_index, @errorName(err) });
                return;
            };
            self.lane_state.store(@intFromEnum(LaneRuntimeState.exited), .release);
        }

        pub fn monotonicNowNs(self: *const Self) u64 {
            _ = self;
            return process.monotonicNowNsOrZero();
        }

        /// Posts `command` to this lane's queue from any thread, consuming it
        /// on every path (`commands.Queue.post`). False when the queue is full
        /// for it, or when the lane is not running and has no queue to take
        /// it. Fails with `error.CommandEventfdCorrupt` when the lane's wake
        /// cannot be written.
        pub fn post(self: *Self, command: commands.Command) error{CommandEventfdCorrupt}!bool {
            self.runtime_mutex.lock();
            defer self.runtime_mutex.unlock();
            if (!self.running() or !self.lane_initialized) {
                var refused = command;
                refused.deinit();
                return false;
            }
            return self.lane.command_queue.post(command);
        }

        /// Posts `command` to lane `lane_id` (`Service.postToLane`), this lane
        /// included, consuming it on every path. False when that lane's queue
        /// is full for it or the lane is not running.
        pub fn postToLane(self: *Self, lane_id: pool.LaneId, command: commands.Command) LaneFault!bool {
            return self.service.postToLane(lane_id, command);
        }

        // The loop's handlers (`fault.loop_handlers`), which the event loop
        // calls on the lane.
        pub const handleConnectionReadable = ring_driver.Methods(Self).handleConnectionReadable;
        pub const handleConnectionWritable = ring_driver.Methods(Self).handleConnectionWritable;
        pub const handleAcceptCqe = accept_flow.Methods(Self).handleAcceptCqe;
        pub const handleCommands = command_flow.Methods(Self).handleCommands;
        pub const handleWorkerControlReadable = ring_driver.Methods(Self).handleWorkerControlReadable;
        pub const handleWorkerControlWritable = ring_driver.Methods(Self).handleWorkerControlWritable;
        pub const handleWorkerCompletions = worker_completions.Methods(Self).handleWorkerCompletions;
        pub const handleWorkerFsFault = ring_driver.Methods(Self).handleWorkerFsFault;
        pub const handleWorkerPayloadCredit = ring_driver.Methods(Self).handleWorkerPayloadCredit;
        pub const handleStop = ring_driver.Methods(Self).handleStop;
        pub const handleWorkerPidfd = ring_driver.Methods(Self).handleWorkerPidfd;

        pub fn handleDeadlineTimer(self: *Self) LaneFault!void {
            return deadline_driver.handleDeadlineTimer(Self, self);
        }

        // What the HTTP/2 driver calls on its `Worker` (`http2/connection.zig`).
        pub const startDynamicH2 = admission.Methods(Self).startDynamicH2;
        pub const handleH2DataFrame = request_body.Methods(Self).handleH2DataFrame;
        pub const handleH2DataFrameBatch = request_body.Methods(Self).handleH2DataFrameBatch;
        pub const handleH2ResetFrame = request_body.Methods(Self).handleH2ResetFrame;
        pub const flushPendingH2RequestBodies = request_body.Methods(Self).flushPendingH2RequestBodies;
        pub const updateConnectionInterest = connection_flow.Methods(Self).updateConnectionInterest;
        pub const closeRuntimeConnection = connection_flow.Methods(Self).closeRuntimeConnection;
    };
}

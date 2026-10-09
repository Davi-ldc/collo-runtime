//! The server's ingress lane runner: one `LaneWorker` per listener, each
//! running its own io_uring event loop on a lane thread pinned to the CPU the
//! service assigned it. A lane accepts client connections, runs their TLS
//! handshake and HTTP/2, admits each request into the pool of its route's
//! worker definition, dispatches it on a worker slot, reads the workers it is
//! the reader of on behalf of every lane, and answers the client from the
//! worker's response.
//!
//! Once `threadMain` enters the event loop (`run` in `ring_driver.zig`), the
//! lane thread is the only mutator of the lane's tables: its connections,
//! requests, streams and worker registrations, each a fault-in slab
//! (`../slab.zig`) that costs memory only as far as the lane has used it,
//! and of its runtime events. Other threads may only post commands (`post`,
//! under `runtime_mutex`), raise its wake bits (`raiseWake`, under the same
//! mutex), snapshot counters under `counters_mutex`, read `lane_state`, and
//! drain `access_ring` (the metrics thread). `prepareStart` and `deinit` run
//! on the service's thread while the lane thread is not running. A flow file
//! must not spawn a thread, block the lane thread outside the ring wait, or
//! change lane state from another thread.
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
//! `postToLane`, `raiseLaneWake` and `queueRetirement` (`service.zig`).
//! A flow file reaches the service only through these, and imports none of
//! the service's files.
//!
//! Which file holds what:
//! - This file: `LaneWorker` with its fields, its start, thread entry and
//!   teardown, its command posts and wake bits, its memory shape for the lane
//!   plan, and the declarations above.
//! - `ring_driver.zig`: the event loop, the completion dispatch, the worker
//!   handlers, the writability poll of a worker's control socket, the wake
//!   bits' handling, the shutdown drain and the lane's allocations;
//!   `event_sources.zig`: the ring with its one submission per pass, the
//!   user_data encoding, poll masks and the deadline timerfd;
//!   `work_queues.zig`: the queues of connections waiting for a turn and of
//!   deferred worker faults.
//! - `accept_flow.zig`, `tls_handshake.zig` and `connection_flow.zig`:
//!   client connections from accept to close; `connection_slot.zig`: a
//!   connection's state, with its HTTP/2 streams in `stream_table.zig`, its
//!   flow-control windows and buffered request bodies in `flow_control.zig`,
//!   and its write queue and buffered responses in `write_queue.zig`.
//! - `admission.zig`: a new stream's route match, its admission into the
//!   pool, the launch or the 503 that follows when the pool cannot serve its
//!   waiters, and the answers the lane writes alone; `dispatch.zig`: dispatch
//!   to a worker slot, the begin and reset sends and every send that waits
//!   for room; `request_body.zig`: request bodies and client resets;
//!   `request_slot.zig`: the lane's slot of each request it admitted;
//!   `h2_worker_ipc.zig`: worker response descriptors, read or forwarded,
//!   and the forwarding window.
//! - `worker_completions.zig`: worker completions; `request_finish.zig`: the
//!   end of a request and the worker slot it gives back; `worker_fault.zig`:
//!   a worker's death path; `worker_registration.zig`: the lane's
//!   registration of each worker it sends to or reads, with the reader
//!   tenure; `worker_control.zig` and `fs_fault_control.zig`: a worker's
//!   control and fs-fault channels.
//! - `deadline_driver.zig`: request deadlines and each connection's one
//!   deadline (pre-request, idle or stall).
//! - `command_flow.zig`: the lane's commands and the reader role it gives
//!   up.

const std = @import("std");
const process = @import("collo_os").process;

const supervision = @import("collo_server_supervisor");
const gateway = @import("collo_server_gateway");
const access_log = @import("collo_server_analytics").access;
const ipc = @import("collo_ipc");
const limits = @import("collo_limits");
const accept = @import("../accept.zig");
const commands = @import("../commands.zig");
const completions = @import("../completions.zig");
const fault = @import("../fault.zig");
const lane_mod = @import("../lane.zig");
const lane_plan = @import("../../net/lane_plan.zig");
const timer_wheel = @import("../timer_wheel.zig");
const http2_lane = @import("../http2/lane_resources.zig");
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

pub const LaneRuntimeState = event_sources.LaneRuntimeState;

/// Registrations one lane can hold: every worker the node can have, so a
/// lane never runs out while each worker holds one registration per lane.
pub const max_completion_registrations: u32 =
    @intCast(limits.server.worker_definitions_max * supervision.scheduler_limits.capacity.pool_workers_max);

/// The capacities of a lane's tables. A serving lane keeps the limits; a
/// test shrinks them to reach a full table.
pub const TableCapacities = struct {
    connections: u32 = limits.ingress.connections_per_lane_max,
    requests: u32 = limits.ingress.requests_per_lane_max,
    streams: u32 = limits.ingress.streams_per_lane_max,
};

/// The bits other threads raise on a lane (`LaneWorker.raiseWake`), each
/// asking for one kind of retry on the lane's next pass.
pub const wake = struct {
    /// A worker freed room in its server-to-worker payload ring that a
    /// request body of this lane waits for (`request_body.zig`).
    pub const payload_credit: u32 = 1 << 0;
    /// A worker this lane reads, whose forwarding window was full, has room
    /// again (`h2_worker_ipc.zig`).
    pub const window_reopened: u32 = 1 << 1;
};

/// A lane's resident memory with every table full and every buffer used,
/// for a configuration of `definition_count` worker definitions: the cost
/// the lane plan's memory cap charges per lane. The tables fault in, so a
/// lane holds this only at its busiest; at start it holds almost none of it.
pub fn laneMemoryShape(definition_count: usize) lane_plan.MemoryShape {
    const registrations = definition_count * supervision.scheduler_limits.capacity.pool_workers_max;
    const command_places = limits.ingress.commands_per_lane_max + lane_mod.obligationReserve(definition_count);
    var bytes: usize = 0;
    bytes += limits.ingress.connections_per_lane_max * (@sizeOf(ConnectionSlot) + @sizeOf(*ConnectionSlot));
    bytes += limits.ingress.requests_per_lane_max * (@sizeOf(RequestSlot) + timer_wheel.entrySizeBytes());
    bytes += command_places * commands.node_bytes;
    bytes += registrations * @sizeOf(completions.Registration);
    bytes += http2_lane.LaneResources.residentCapBytes(limits.ingress.streams_per_lane_max);
    bytes += limits.ingress.header_block_bytes_per_lane_max;
    bytes += 2 * ipc.max_message_bytes;
    bytes += access_log.AccessRing.slot_bytes;
    return .{ .resident_cap_bytes = bytes };
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
        /// `retained_counters`. `init` maps its slots.
        access_ring: access_log.AccessRing = .{},
        counters_mutex: std.Thread.Mutex = .{},
        /// Held by a producer from the running check through its post or its
        /// wake, and by `deinitLane` while it destroys the queue, so neither
        /// lands in a queue being torn down. Comes after every pool mutex and
        /// before the queue's own (`commands.zig`).
        runtime_mutex: std.Thread.Mutex = .{},
        thread: ?std.Thread = null,
        /// What stopped the lane: a lane fault from `run`, or the CPU pin.
        run_error: ?anyerror = null,
        lane_state: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(LaneRuntimeState.exited)),
        accept_counters: accept.Counters = .{},
        /// The `wake` bits raised since the lane last took them. A raise that
        /// sets a bit writes the command queue's eventfd, and the lane takes
        /// every bit when its command poll fires (`ring_driver.zig`), so no
        /// raise is lost and several coalesce into one wake.
        wake_bits: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        connections: connection_slot.ConnectionSlab = .{},
        /// The connections waiting for a turn of the loop.
        ready_connections: connection_slot.ReadyQueue = .{},
        /// Each connection's one deadline (`deadline_driver.zig`).
        connection_deadlines: ?connection_slot.DeadlineHeap = null,
        /// The pre-request, idle and stall timeouts. Tests shorten them;
        /// nothing else changes them.
        connection_timeouts: deadline_driver.ConnectionTimeouts = .{},
        /// The capacities `ring_driver.initRuntime` gives the tables.
        table_capacities: TableCapacities = .{},
        requests: request_slot.RequestSlab = .{},
        /// Requests live in `requests`, kept by the admission and the finish.
        request_count: usize = 0,
        /// Finishes that found nothing counted. Non-zero means this counter
        /// and the request slab disagree about how many requests are live,
        /// which is the only sign a leaked slab entry leaves: an entry that
        /// never comes back passes through no allocator, so a divergence
        /// nobody records is indistinguishable from health until the slab
        /// runs out.
        request_underflow: u64 = 0,
        registrations: completions.RegistrationSlab = .{},
        /// The last poll epoch handed to a registration
        /// (`worker_registration.zig`). Every epoch is new, so a completion
        /// of a poll armed under an earlier one reads as stale whichever
        /// registration holds its place now.
        registration_epoch: u32 = 0,
        /// Registrations whose worker fault waits for the end of the handler
        /// that met it (`worker_fault.deferWorkerFault`); the loop runs them
        /// on every pass.
        deferred_deaths: completions.DeathQueue = .{},
        /// What the lane's connections share for HTTP/2: the read buffer, the
        /// HPACK scratch, the header block budget and the stream slab. Valid
        /// while the lane's runtime exists (`ring_driver.initRuntime`).
        h2_lane: http2_lane.LaneResources = undefined,
        runtime_events: event_sources.EventSet = .{},
        runtime_ring: ?*event_sources.LaneRing = null,
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

        /// The lane of listener `listener_index`, with its access ring
        /// reserved; the tables of its runtime come with
        /// `ring_driver.initLane` and `initRuntime`.
        pub fn init(listener_index: u16, cpu_id: ?usize) !Self {
            return .{
                .listener_index = listener_index,
                .cpu_id = cpu_id,
                .access_ring = try access_log.AccessRing.init(),
            };
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
            self.access_ring.deinit();
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

        /// Raises `bit` of `wake` on this lane from any thread, writing the
        /// lane's wake unless the bit was raised already. A lane that is not
        /// running takes no wake and has nothing to retry.
        pub fn raiseWake(self: *Self, bit: u32) error{CommandEventfdCorrupt}!void {
            self.runtime_mutex.lock();
            defer self.runtime_mutex.unlock();
            if (!self.running() or !self.lane_initialized)
                return;
            const previous = self.wake_bits.fetchOr(bit, .seq_cst);
            if (previous & bit == 0)
                try self.lane.command_queue.wake();
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

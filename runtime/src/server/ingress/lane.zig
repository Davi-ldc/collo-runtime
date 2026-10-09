//! The state one ingress lane owns besides its tables of connections,
//! requests, streams and worker registrations (`runner/root.zig`): the
//! request deadline wheel (`timer_wheel.zig`), the command queue
//! (`commands.zig`), the multishot accept registration (`uring.zig`) and the
//! lane's counters. The lane thread creates it when it starts
//! (`LaneWorker.lane` in `runner/root.zig`) and is its only writer. Other
//! threads post through the command queue, which locks itself, and read the
//! counters through `LaneWorker.countersSnapshot`.

const std = @import("std");
const limits = @import("collo_limits");
const lifecycle = @import("collo_server_lifecycle");
const commands = @import("commands.zig");
const timer_wheel = @import("timer_wheel.zig");
const uring = @import("uring.zig");
const supervision = @import("collo_server_supervisor");

/// Sizes of a lane's state besides its tables. A serving lane uses the
/// defaults and reserves command places for its configuration
/// (`obligationReserve`).
pub const Config = struct {
    lane_id: u16 = 0,
    /// Deadline wheel entries: one per request the lane can hold.
    max_requests: usize = limits.ingress.requests_per_lane_max,
    deadline_wheel_slots: usize = timer_wheel.minimum_slots,
    command_queue_capacity: usize = limits.ingress.commands_per_lane_max,
    /// Command places only the commands that discharge an obligation may
    /// fill (`commands.Queue`).
    command_obligation_reserve: usize = 0,
};

/// The command places a lane reserves for `definition_count` worker
/// definitions: for each entry of each pool's worker table, one death, one
/// reader grant, one forwarded completion per slot, and the forwarding
/// window of the entry's output (`commands.zig` says why that bounds them).
pub fn obligationReserve(definition_count: usize) usize {
    const per_entry = 2 + @as(usize, supervision.pool.slots_per_worker_max) +
        limits.ingress.forwarded_commands_per_worker_max;
    return per_entry * definition_count * supervision.scheduler_limits.capacity.pool_workers_max;
}

/// Monotonic counters of one lane. `Service.countersSnapshot` sums them over
/// the lanes, and `diff` gives the counts between two snapshots.
pub const CounterSnapshot = struct {
    accepted_connections: u64 = 0,
    accepted_connection_slab_exhaustion: u64 = 0,
    accepted_during_shutdown: u64 = 0,
    accepted_tcp_notsent_lowat_failures: u64 = 0,
    /// Accepted sockets closed because their descriptor flags, socket
    /// options, peer address or TLS session could not be set up.
    accepted_setup_failures: u64 = 0,
    /// Passes of the lane's loop.
    loop_passes: u64 = 0,
    /// `io_uring_enter` calls the lane made: one per pass at most, unless a
    /// pass filled the submission queue (`event_sources.LaneRing`).
    ring_enters: u64 = 0,
    /// Streams whose path matched a route in the route table.
    route_matches: u64 = 0,
    /// Requests that took a worker slot at admission (`Pool.acquire` answered
    /// `.acquired`).
    worker_pool_ready_picks: u64 = 0,
    dispatch_handoffs: u64 = 0,
    /// Commands whose request, stream or worker registration was gone by the
    /// time the lane ran them.
    stale_commands: u64 = 0,
    /// Slots handed to a request of this lane that it gave back unused: the
    /// request had ended, or its worker had died.
    handoffs_returned: u64 = 0,
    /// Requests answered 503 because their deadline came while they waited
    /// for a worker slot.
    waiters_expired: u64 = 0,
    /// Requests answered 503 because no worker could serve them
    /// (`Pool.takeStranded`).
    waiters_stranded: u64 = 0,
    /// Reader tenures this lane gave up while the worker was idle, for a
    /// `release_worker` or at shutdown.
    reader_tenures_released: u64 = 0,
    /// `release_worker` posts a full reader's queue refused; the reader
    /// keeps its role.
    release_worker_refusals: u64 = 0,
    /// Workers this lane faulted because a request outlived its deadline by
    /// the hard-timeout grace.
    deadline_grace_faults: u64 = 0,
    deadline_wheel_inserts: u64 = 0,
    worker_completion_records_drained: u64 = 0,
    worker_completion_drain_fatal_errors: u64 = 0,
    completed_requests: u64 = 0,
    stale_connection_cqe: u64 = 0,
    connection_poll_cancel_attempts: u64 = 0,
    connection_poll_cancel_cqes: u64 = 0,
    /// Completions of the closes of connection sockets the lane submitted.
    connection_close_cqes: u64 = 0,
    /// Completions of the cancels the lane submitted for a worker
    /// registration's polls.
    worker_poll_cancel_cqes: u64 = 0,
    /// Completions of a worker registration's poll that reported no
    /// readiness: the registration had moved on, or a cancel removed the
    /// poll.
    stale_worker_poll_cqes: u64 = 0,
    stale_worker_completion: u64 = 0,
    stale_timeout: u64 = 0,
    /// Dispatched requests past their deadline and grace that a completion
    /// ended after all, taken just before the backstop or parked behind the
    /// response, so their worker took no fault.
    completion_before_timeout: u64 = 0,
    worker_completion_registrations: u64 = 0,
    silent_queue_overflows: u64 = 0,
    worker_completion_eventfd_wakes: u64 = 0,
    command_eventfd_wakes: u64 = 0,
    timerfd_expirations: u64 = 0,
    deadline_wheel_expired: u64 = 0,
    readiness_cqes_processed: u64 = 0,
    /// Connections closed at their pre-request, idle and stall deadlines.
    pre_request_timeouts: u64 = 0,
    idle_timeouts: u64 = 0,
    stall_timeouts: u64 = 0,
    /// Connections closed because their header block would have passed the
    /// lane's header block budget.
    header_block_budget_closes: u64 = 0,
    h2_server_protocol_time_ns: u64 = 0,
    ingress_channels_started: u64 = 0,
    h2_request_body_frames: u64 = 0,
    h2_request_body_bytes: u64 = 0,
    h2_request_body_ring_full: u64 = 0,
    /// Wakes that retried this lane's request bodies parked on a full
    /// payload ring.
    h2_request_body_credit_wakes: u64 = 0,
    h2_request_body_deferred_flushes: u64 = 0,
    h2_worker_descriptor_batches: u64 = 0,
    h2_worker_descriptors: u64 = 0,
    /// Descriptors this lane read as a worker's reader and forwarded to the
    /// lane that owns their request.
    worker_descriptors_forwarded: u64 = 0,
    /// Descriptors this lane's reader dropped instead of forwarding: the
    /// owner's queue refused one, or refused an earlier one of the same
    /// response, or the worker's request table no longer held the request.
    forwarded_descriptor_drops: u64 = 0,
    /// Times this lane's reader stopped receiving a worker's packets because
    /// its forwarding window had no room for one more
    /// (`limits.ingress.forwarded_commands_per_worker_max`).
    forward_window_waits: u64 = 0,
    /// `payload_consumed` answers a reader's full queue refused; the ring
    /// bytes they would free stay held.
    payload_answer_drops: u64 = 0,
    /// Fault answers dropped because the worker's fault socket had no room;
    /// the worker's read then ends at its request's deadline.
    fs_fault_answer_drops: u64 = 0,
    ingress_response_body_bytes: u64 = 0,
    /// `request_ended` batches lost because the gateway's control socket was
    /// full, and because the gateway was gone (`server/gateway/lease.zig`).
    /// Each costs its requests' fetches until their tokens' deadlines.
    egress_ended_batches_dropped_full: u64 = 0,
    egress_ended_batches_dropped_closed: u64 = 0,

    pub fn add(self: *CounterSnapshot, other: CounterSnapshot) void {
        inline for (std.meta.fields(CounterSnapshot)) |field|
            @field(self, field.name) += @field(other, field.name);
    }

    pub fn diff(after: CounterSnapshot, before: CounterSnapshot) CounterSnapshot {
        var delta = CounterSnapshot{};
        inline for (std.meta.fields(CounterSnapshot)) |field| {
            const after_value = @field(after, field.name);
            const before_value = @field(before, field.name);
            @field(delta, field.name) = after_value -| before_value;
        }
        return delta;
    }
};

pub const IngressLane = struct {
    allocator: std.mem.Allocator,
    lane_id: u16,
    deadline_wheel: timer_wheel.DeadlineWheel,
    command_queue: commands.Queue,
    accept_registration: uring.AcceptRegistration = .{},
    counters: CounterSnapshot = .{},

    pub fn init(allocator: std.mem.Allocator, config: Config, now_monotonic_ns: u64) !IngressLane {
        var wheel = try timer_wheel.DeadlineWheel.init(
            allocator,
            config.max_requests,
            config.deadline_wheel_slots,
            now_monotonic_ns,
        );
        errdefer wheel.deinit();
        var queue = try commands.Queue.init(
            config.command_queue_capacity,
            config.command_obligation_reserve,
        );
        errdefer queue.deinit();
        return .{
            .allocator = allocator,
            .lane_id = config.lane_id,
            .deadline_wheel = wheel,
            .command_queue = queue,
        };
    }

    pub fn deinit(self: *IngressLane) void {
        self.command_queue.deinit();
        self.deadline_wheel.deinit();
        self.* = undefined;
    }

    /// Arms the request's deadline in the wheel and stores its handle in
    /// `handle`, cancelling the one it held.
    pub fn armRequestDeadline(
        self: *IngressLane,
        handle: *?timer_wheel.Handle,
        request_key: lifecycle.RequestKey,
        connection_key: lifecycle.ConnectionKey,
        worker_key: lifecycle.WorkerKey,
        deadline_ns: u64,
        now_ns: u64,
    ) !void {
        _ = self.cancelRequestDeadline(handle);
        handle.* = try self.deadline_wheel.insert(
            request_key,
            connection_key,
            worker_key,
            now_ns,
            deadline_ns,
        );
        self.counters.deadline_wheel_inserts += 1;
    }

    /// Cancels the deadline `handle` holds, if any, and returns whether one
    /// was armed.
    pub fn cancelRequestDeadline(self: *IngressLane, handle: *?timer_wheel.Handle) bool {
        const armed = handle.* orelse return false;
        handle.* = null;
        return self.deadline_wheel.cancel(armed);
    }

    pub fn recordDispatchHandoff(self: *IngressLane) void {
        self.counters.dispatch_handoffs += 1;
    }

    pub fn recordCompletionDrained(self: *IngressLane, count: usize) void {
        self.counters.worker_completion_records_drained += @intCast(count);
        self.counters.completed_requests += @intCast(count);
    }

    pub fn countersSnapshot(self: *const IngressLane) CounterSnapshot {
        var snapshot = self.counters;
        snapshot.stale_timeout += self.deadline_wheel.counters.stale_timers;
        snapshot.command_eventfd_wakes += self.command_queue.counters.eventfd_wakes;
        return snapshot;
    }
};

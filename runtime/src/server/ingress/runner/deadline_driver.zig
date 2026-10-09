//! The deadlines of an ingress lane, on the lane thread: the wheel of request
//! deadlines (`timer_wheel.zig`) and the heap of connection deadlines, both
//! served by the lane's one deadline timerfd. The timerfd is the only wake
//! for an expiry, so a deadline earlier than the armed one re-arms it.
//! Removing a deadline may leave it armed early, which costs one spurious
//! wake that re-arms it.
//!
//! A request's wheel entry falls at its deadline while it waits for a worker
//! slot or for room to send its begin, and at the deadline plus
//! `hard_timeout_grace_ns` once the begin reached the worker (`dispatch.zig`
//! moves it). A deadline ends a waiting request with 503 and takes it out of
//! its pool's waiters, and ends a request whose begin never left with 504,
//! its worker untouched. A worker that has the begin answers 504 itself when
//! the deadline passes, so an entry that fires after the grace means it did
//! not: once the backstop has read everything the worker wrote, and unless
//! the worker's completion is parked on the request behind its response, the
//! worker takes a fault, which ends the request with 504 and the worker's
//! other requests with 502. A healthy worker therefore never dies of a
//! deadline.
//!
//! A connection has at most one deadline at a time, one entry in the heap,
//! and which one follows from its state (`desiredDeadline`):
//! - pre-request, from the accept until its first request starts, at the
//!   accept plus `pre_request_timeout_ns`; nothing extends it, and it closes
//!   the connection with GOAWAY NO_ERROR.
//! - stall, while the lane holds something of the connection that only the
//!   client can move (`Slot.stalled`), or while a close waits to flush its
//!   GOAWAY, at the last byte read or written plus `stall_timeout_ns`; it
//!   closes the connection at once, without waiting for its write queue.
//! - idle, while the connection has no stream and nothing stalls, at the
//!   moment it came to have none plus `idle_timeout_ns`; only a new stream
//!   ends it, and it queues GOAWAY NO_ERROR naming the last stream and closes
//!   once that is written, a write the stall deadline bounds.
//! A connection with streams in flight and nothing stalled has none: its
//! requests' deadlines govern.
//!
//! The heap is re-keyed lazily. A deadline that moves later, as the stall
//! deadline does with every byte, only changes the state it follows from;
//! the expiry of the entry finds the later deadline and files it again. Only
//! a deadline that appears or moves earlier touches the heap at once
//! (`syncConnectionDeadline`), which every drive of a connection calls last.

const std = @import("std");

const limits = @import("collo_limits");
const fault = @import("../fault.zig");
const timer_wheel = @import("../timer_wheel.zig");
const command_flow = @import("command_flow.zig");
const connection_flow = @import("connection_flow.zig");
const connection_slot = @import("connection_slot.zig");
const request_finish = @import("request_finish.zig");
const worker_completions = @import("worker_completions.zig");
const worker_fault = @import("worker_fault.zig");
const worker_registration = @import("worker_registration.zig");

const LaneFault = fault.LaneFault;
const Slot = connection_slot.Slot;
const Deadline = connection_slot.Deadline;

/// How long each connection deadline runs, from `limits.ingress`. A test
/// shortens them on its lane (`LaneWorker.connection_timeouts`).
pub const ConnectionTimeouts = struct {
    pre_request_ns: u64 = limits.ingress.pre_request_timeout_ns,
    idle_ns: u64 = limits.ingress.idle_timeout_ns,
    stall_ns: u64 = limits.ingress.stall_timeout_ns,
};

/// Wheel entries one expiry pass handles. Entries past it stay due, and the
/// wheel then reports `now` as its next wake (`nextWakeDeadlineNs`), so the
/// re-arm after the pass fires the timerfd again at once.
const expired_batch_max: usize = 64;

/// The deadline at which the lane times out a dispatched request: the
/// request's own deadline plus the supervisor's hard-timeout grace,
/// saturating at the largest timestamp.
pub fn effectiveHardTimeoutDeadline(request_deadline_ns: u64, hard_timeout_grace_ns: u64) u64 {
    return request_deadline_ns +| hard_timeout_grace_ns;
}

/// The deadline the connection's state calls for now (the file header), or
/// null when it calls for none.
pub fn desiredDeadline(runtime: *const Slot, timeouts: ConnectionTimeouts) ?Deadline {
    if (runtime.closing) |closing| {
        if (closing.flush and runtime.h2WritesPending())
            return .{ .kind = .stall, .at_ns = runtime.last_progress_ns +| timeouts.stall_ns };
        return null;
    }
    if (runtime.awaiting_first_request)
        return .{ .kind = .pre_request, .at_ns = runtime.accepted_ns +| timeouts.pre_request_ns };
    if (runtime.stalled())
        return .{ .kind = .stall, .at_ns = runtime.last_progress_ns +| timeouts.stall_ns };
    if (runtime.ingress_channel_count == 0) {
        const since = runtime.idle_since_ns orelse return null;
        return .{ .kind = .idle, .at_ns = since +| timeouts.idle_ns };
    }
    return null;
}

/// Loop handler: drains the timerfd and handles the deadlines due now. Its
/// poll is re-armed by the loop (`ring_driver.zig`).
pub fn handleDeadlineTimer(comptime Lane: type, lane: *Lane) LaneFault!void {
    const expirations = lane.runtime_events.drainDeadlineTimer() catch |err| expirations: {
        try fault.classifyTimerReadError(err);
        break :expirations 0;
    };
    lane.lane.counters.timerfd_expirations += expirations;
    const now = lane.monotonicNowNs();
    _ = try processExpired(Lane, lane, now);
    try armTimerAt(Lane, lane, now);
}

/// Handles the deadlines due at `now`: the connections past their deadline
/// and the requests past their wheel entry. Returns whether it did any work.
/// A wheel entry whose request ended or whose slot holds a later request
/// counts as stale.
pub fn processExpired(comptime Lane: type, lane: *Lane, now: u64) LaneFault!bool {
    const did_connection_work = try processExpiredConnectionDeadlines(Lane, lane, now);
    var expired: [expired_batch_max]timer_wheel.Expired = undefined;
    const count = lane.lane.deadline_wheel.expireDue(now, &expired);
    if (count == 0)
        return did_connection_work;
    lane.lane.counters.deadline_wheel_expired += count;
    for (expired[0..count]) |deadline|
        try expireRequest(Lane, lane, deadline);
    return true;
}

fn expireRequest(comptime Lane: type, lane: *Lane, deadline: timer_wheel.Expired) LaneFault!void {
    const RequestFinish = request_finish.Methods(Lane);
    const request_index = liveRequestSlot(Lane, lane, deadline) orelse {
        lane.lane.counters.stale_timeout += 1;
        return;
    };
    const request = &lane.requests.entries[request_index];
    // The wheel let the entry go.
    request.deadline = null;
    if (request.waiting()) {
        // The deadline fixed at admission passed before any worker took the
        // request. Its finish cancels the waiter; a waiter the pool already
        // handed a slot has its `dispatch_ready` on the way, and that
        // command gives the slot back when it finds the request gone. 503
        // either way.
        lane.lane.counters.waiters_expired += 1;
        try RequestFinish.finishRequest(lane, request_index, .waiter_expired);
    } else if (!request.begin_sent) {
        // The begin still waits for room in the worker's socket, which is
        // backpressure under the request's deadline and no fault.
        try RequestFinish.finishRequest(lane, request_index, .send_expired);
    } else {
        try expireDispatchedRequest(Lane, lane, deadline);
    }
}

/// The backstop of a dispatched request: its deadline and the grace both
/// passed without the worker ending it. A completion the worker published in
/// time but the lane has not taken yet wins over the fault, so the reader
/// reads the worker's output to its end first, and a lane that only holds
/// the request runs the commands the reader forwarded to it. A worker that
/// kept its control socket filling through that whole read may still have
/// the completion behind it, so its backstop moves out by one more grace,
/// once. A completion parked behind the response's body ends the request
/// instead of a fault.
fn expireDispatchedRequest(comptime Lane: type, lane: *Lane, deadline: timer_wheel.Expired) LaneFault!void {
    const RequestFinish = request_finish.Methods(Lane);
    const WorkerFault = worker_fault.Methods(Lane);
    const WorkerRegistration = worker_registration.Methods(Lane);
    const registration_index = WorkerRegistration.findCompletionRegistrationIndex(lane, deadline.worker_key) orelse
        return error.WorkerCompletionRegistrationNotFound;
    if (lane.registrations.entries[registration_index].reading()) {
        switch (try worker_completions.Methods(Lane).readForBackstop(lane, registration_index)) {
            .done => {},
            .socket_busy => if (liveRequestSlot(Lane, lane, deadline)) |request_index| {
                if (try deferBackstop(Lane, lane, request_index))
                    return;
            },
        }
    } else {
        try command_flow.Methods(Lane).handleCommands(lane);
    }
    const request_index = liveRequestSlot(Lane, lane, deadline) orelse {
        lane.lane.counters.completion_before_timeout += 1;
        return;
    };
    if (try RequestFinish.finishParkedCompletion(lane, request_index)) {
        lane.lane.counters.completion_before_timeout += 1;
        return;
    }
    // A request still live keeps its worker's registration, so the drain
    // above cannot have freed it; it is looked up again by key all the
    // same, since nothing promises it kept its place.
    const current_index = WorkerRegistration.findCompletionRegistrationIndex(lane, deadline.worker_key) orelse
        return error.WorkerCompletionRegistrationNotFound;
    lane.lane.counters.deadline_grace_faults += 1;
    try WorkerFault.faultWorker(lane, current_index, .deadline_grace_expired);
}

/// Moves the backstop of the request in `request_index` out by one more
/// grace, the first time only, and says whether it did.
fn deferBackstop(comptime Lane: type, lane: *Lane, request_index: u32) LaneFault!bool {
    const request = &lane.requests.entries[request_index];
    if (request.backstop_deferred)
        return false;
    request.backstop_deferred = true;
    const now = lane.monotonicNowNs();
    try lane.lane.armRequestDeadline(
        &request.deadline,
        request.request_key,
        request.connection_key,
        request.worker_key,
        now +| lane.service.hard_timeout_grace_ns,
        now,
    );
    return true;
}

/// The request slot an expired wheel entry names, when that slot still
/// holds the same request on the same worker.
fn liveRequestSlot(comptime Lane: type, lane: *Lane, deadline: timer_wheel.Expired) ?u32 {
    const active = switch (lane.requests.lookup(deadline.request_key.slot, deadline.request_key.generation)) {
        .live => |active| active,
        .stale_generation, .vacant, .out_of_range => return null,
    };
    if (!active.worker_key.eql(deadline.worker_key))
        return null;
    return deadline.request_key.slot;
}

/// Takes every connection deadline due at `now` off the heap. One whose
/// connection's state now calls for a later deadline goes back under it; one
/// that calls for none drops; one still due expires. Returns whether any was
/// due.
fn processExpiredConnectionDeadlines(comptime Lane: type, lane: *Lane, now: u64) LaneFault!bool {
    const heap = Methods(Lane).connectionDeadlines(lane);
    var did_work = false;
    while (heap.peek()) |runtime| {
        if (runtime.deadline.?.at_ns > now)
            return did_work;
        _ = heap.deleteMin();
        runtime.deadline = null;
        did_work = true;
        const desired = desiredDeadline(runtime, lane.connection_timeouts) orelse continue;
        if (desired.at_ns > now) {
            runtime.deadline = desired;
            heap.insertAssumeCapacity(runtime);
            continue;
        }
        expireConnection(Lane, lane, runtime, desired.kind);
    }
    return did_work;
}

fn expireConnection(comptime Lane: type, lane: *Lane, runtime: *Slot, kind: connection_slot.DeadlineKind) void {
    const Connection = connection_flow.Methods(Lane);
    switch (kind) {
        .pre_request => {
            lane.lane.counters.pre_request_timeouts += 1;
            Connection.closeRuntimeConnection(lane, runtime, .{ .reason = .pre_request_timeout, .goaway = .no_error });
        },
        .idle => {
            lane.lane.counters.idle_timeouts += 1;
            Connection.closeRuntimeConnection(lane, runtime, .{ .reason = .idle_timeout, .goaway = .no_error });
        },
        .stall => {
            lane.lane.counters.stall_timeouts += 1;
            // A close already flushing stops flushing; a new one queues no
            // GOAWAY, since the client is not taking bytes.
            Connection.closeRuntimeConnection(lane, runtime, .{ .reason = .stall_timeout, .goaway = null });
        },
    }
}

pub fn armTimer(comptime Lane: type, lane: *Lane) LaneFault!void {
    try armTimerAt(Lane, lane, lane.monotonicNowNs());
}

/// Arms the deadline timerfd at the earliest deadline of either source, or
/// disarms it when none is left.
pub fn armTimerAt(comptime Lane: type, lane: *Lane, now: u64) LaneFault!void {
    try lane.runtime_events.armDeadlineTimer(nextDeadlineNs(Lane, lane, now));
}

/// Arms the deadline timerfd at the earliest deadline, but no later than
/// `latest_ns`, so the lane wakes by then even with nothing due.
pub fn armTimerNoLaterThan(comptime Lane: type, lane: *Lane, now: u64, latest_ns: u64) LaneFault!void {
    const next = nextDeadlineNs(Lane, lane, now) orelse latest_ns;
    try lane.runtime_events.armDeadlineTimer(@min(next, latest_ns));
}

/// Moves the timerfd earlier to `deadline_ns` when it is armed later or not
/// at all; a deadline after the armed one keeps it.
pub fn armTimerNoLaterThanDeadline(comptime Lane: type, lane: *Lane, deadline_ns: u64) LaneFault!void {
    if (lane.runtime_events.timer_armed_ns) |armed| {
        if (armed <= deadline_ns)
            return;
    }
    try lane.runtime_events.armDeadlineTimer(deadline_ns);
}

fn nextDeadlineNs(comptime Lane: type, lane: *Lane, now: u64) ?u64 {
    var next_deadline_ns = lane.lane.deadline_wheel.nextWakeDeadlineNs(now);
    if (Methods(Lane).connectionDeadlines(lane).peek()) |runtime|
        next_deadline_ns = minOptionalDeadline(next_deadline_ns, runtime.deadline.?.at_ns);
    // The loop re-arms an accept parked in backoff once the backoff ends
    // (`accept_flow.zig`), and with no connection or request nothing else
    // may wake the lane by then.
    if (lane.lane.accept_registration.state == .backoff) {
        next_deadline_ns = minOptionalDeadline(next_deadline_ns, lane.lane.accept_registration.backoff_until_ns);
    }
    return next_deadline_ns;
}

fn minOptionalDeadline(current: ?u64, candidate: u64) ?u64 {
    if (current) |deadline|
        return @min(deadline, candidate);
    return candidate;
}

pub fn Methods(comptime Self: type) type {
    return struct {
        /// Brings the connection's heap entry in step with the deadline its
        /// state calls for: files a deadline it lacks or one earlier than its
        /// entry at once, and leaves a later one to the entry's expiry. It
        /// also notes the moment the connection came to have no stream, from
        /// which its idle deadline runs, and clears it once a stream opens.
        pub fn syncConnectionDeadline(self: *Self, runtime: *Slot) LaneFault!void {
            if (runtime.ingress_channel_count != 0 or runtime.awaiting_first_request) {
                runtime.idle_since_ns = null;
            } else if (runtime.idle_since_ns == null) {
                runtime.idle_since_ns = self.monotonicNowNs();
            }
            const desired = desiredDeadline(runtime, self.connection_timeouts) orelse return;
            const heap = connectionDeadlines(self);
            if (runtime.deadline) |current| {
                if (current.at_ns <= desired.at_ns)
                    return;
                _ = heap.remove(runtime);
            }
            runtime.deadline = desired;
            heap.insertAssumeCapacity(runtime);
            try armTimerNoLaterThanDeadline(Self, self, desired.at_ns);
        }

        /// Removes the connection's heap entry if it has one, so callers need
        /// not check first.
        pub fn clearConnectionDeadline(self: *Self, runtime: *Slot) void {
            if (runtime.deadline == null)
                return;
            _ = connectionDeadlines(self).remove(runtime);
            runtime.deadline = null;
        }

        /// Valid only while the lane's runtime exists (`ring_driver.initRuntime`);
        /// a call outside it reaches `unreachable`.
        pub fn connectionDeadlines(self: *Self) *connection_slot.DeadlineHeap {
            if (self.connection_deadlines) |*heap|
                return heap;
            unreachable;
        }
    };
}

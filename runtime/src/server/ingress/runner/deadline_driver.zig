//! The deadlines of an ingress lane, on the lane thread: the wheel of request
//! deadlines (`timer_wheel.zig`) and the heap of pre-request deadlines that
//! close a connection which has not started a request, both served by the
//! lane's one deadline timerfd. The timerfd is the only wake for an expiry,
//! so adding a deadline earlier than the armed one must re-arm it
//! (`armTimerAt`). Removing a deadline may leave it armed early, which costs
//! one spurious wake that re-arms it.
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

const std = @import("std");

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

/// How long an accepted connection may go without starting its first
/// request, which covers the TLS handshake, the HTTP/2 preface and the first
/// stream's headers. Only the accept arms it, and the first request clears it
/// for good.
const pre_request_timeout_ns: u64 = 3 * std.time.ns_per_s;

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

/// Loop handler: drains the timerfd and handles the deadlines due now. Its
/// poll is re-armed by the loop (`ring_driver.zig`).
pub fn handleDeadlineTimer(comptime Lane: type, lane: *Lane) LaneFault!void {
    const expirations = lane.runtime_events.drainDeadlineTimer() catch |err| expirations: {
        try fault.classifyTimerReadError(err);
        break :expirations 0;
    };
    lane.lane.counters.real_timerfd_expirations += expirations;
    lane.lane.counters.timerfd_expirations += expirations;
    const now = lane.monotonicNowNs();
    _ = try processExpired(Lane, lane, now);
    try armTimerAt(Lane, lane, now);
}

/// Handles the deadlines due at `now`: closes the connections past their
/// pre-request deadline and expires the requests past their wheel entry.
/// Returns whether it did any work. A wheel entry whose request ended or
/// whose slot holds a later request counts as stale.
pub fn processExpired(comptime Lane: type, lane: *Lane, now: u64) LaneFault!bool {
    const did_pre_request_work = processExpiredConnectionDeadlines(Lane, lane, now);
    var expired: [expired_batch_max]timer_wheel.Expired = undefined;
    const count = lane.lane.deadline_wheel.expireDue(now, &expired);
    if (count == 0)
        return did_pre_request_work;
    lane.lane.counters.deadline_wheel_expired += count;
    lane.lane.counters.deadline_wheel_timeout_events += count;
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
    const request = &lane.dynamic_requests[request_index];
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
    if (lane.completion_registrations[registration_index].reading()) {
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
    const request = &lane.dynamic_requests[request_index];
    if (request.backstop_deferred)
        return false;
    request.backstop_deferred = true;
    const now = lane.monotonicNowNs();
    _ = try lane.lane.insertDeadline(
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
    if (deadline.request_key.slot >= lane.dynamic_requests.len)
        return null;
    const active = &lane.dynamic_requests[deadline.request_key.slot];
    if (!active.active)
        return null;
    if (!active.request_key.eql(deadline.request_key))
        return null;
    if (!active.worker_key.eql(deadline.worker_key))
        return null;
    return deadline.request_key.slot;
}

/// Closes every connection whose pre-request deadline has passed, and drops
/// the heap entries of connections that closed or started a request. A
/// connection's close finishes on its next turn, so its deadline leaves the
/// heap here.
fn processExpiredConnectionDeadlines(comptime Lane: type, lane: *Lane, now: u64) bool {
    if (lane.pre_request_deadline_count == 0)
        return false;
    var did_work = false;
    while (Methods(Lane).peekPreRequestDeadline(lane)) |conn| {
        if (!conn.active or !conn.pre_request_deadline_active) {
            Methods(Lane).clearPreRequestDeadline(lane, conn);
            did_work = true;
            continue;
        }
        if (conn.pre_request_deadline_ns > now)
            return did_work;
        Methods(Lane).clearPreRequestDeadline(lane, conn);
        did_work = true;
        switch (conn.state) {
            .tls_handshake, .http2_connection => {
                lane.lane.counters.pre_request_timeouts += 1;
                connection_flow.Methods(Lane).closeRuntimeConnection(lane, conn, .{ .reason = .idle, .goaway = .no_error });
            },
            .vacant => {},
        }
    }
    return did_work;
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

fn nextDeadlineNs(comptime Lane: type, lane: *Lane, now: u64) ?u64 {
    var next_deadline_ns = lane.lane.deadline_wheel.nextWakeDeadlineNs(now);
    if (Methods(Lane).peekPreRequestDeadline(lane)) |runtime| {
        next_deadline_ns = minOptionalDeadline(next_deadline_ns, runtime.pre_request_deadline_ns);
    }
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
        /// Arms the deadline that closes a connection which has not started
        /// a request by then, replacing any it had. The heap holds one entry
        /// per connection slot, so the insert cannot fail. The caller re-arms
        /// the timerfd (`armTimerAt`).
        pub fn activatePreRequestDeadline(
            self: *Self,
            runtime: *connection_slot.Slot,
            now: u64,
        ) void {
            if (!runtime.pre_request_deadline_active) {
                runtime.pre_request_deadline_active = true;
                self.pre_request_deadline_count += 1;
            } else {
                _ = preRequestDeadlineHeap(self).remove(runtime);
            }
            runtime.pre_request_deadline_ns = now +| pre_request_timeout_ns;
            preRequestDeadlineHeap(self).insertAssumeCapacity(runtime);
        }

        /// Removes the connection's pre-request deadline if it has one, so
        /// callers need not check first.
        pub fn clearPreRequestDeadline(self: *Self, runtime: *connection_slot.Slot) void {
            const removed = preRequestDeadlineHeap(self).remove(runtime);
            if (!runtime.pre_request_deadline_active) {
                runtime.pre_request_deadline_ns = 0;
                if (removed and self.pre_request_deadline_count != 0)
                    self.pre_request_deadline_count -= 1;
                return;
            }
            std.debug.assert(removed);
            runtime.pre_request_deadline_active = false;
            runtime.pre_request_deadline_ns = 0;
            std.debug.assert(self.pre_request_deadline_count != 0);
            if (self.pre_request_deadline_count != 0)
                self.pre_request_deadline_count -= 1;
        }

        pub fn peekPreRequestDeadline(self: *Self) ?*connection_slot.Slot {
            return preRequestDeadlineHeap(self).peek();
        }

        /// Valid only while the lane's runtime exists (`ring_driver.initRuntime`);
        /// a call outside it reaches `unreachable`.
        pub fn preRequestDeadlineHeap(
            self: *Self,
        ) *connection_slot.PreRequestDeadlineHeap {
            if (self.pre_request_deadlines) |*heap|
                return heap;
            unreachable;
        }
    };
}

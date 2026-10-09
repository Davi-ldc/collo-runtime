//! The client connections of an ingress lane from readiness to close, on the
//! lane thread: driving each ready connection through its TLS handshake or
//! HTTP/2, keeping its io_uring polls and its one deadline in step with what
//! it waits for, and closing it.
//!
//! A connection closes in two steps. `closeRuntimeConnection` takes the
//! decision wherever a failure is met, inside any handler: the connection
//! reads and queues nothing more, a GOAWAY goes to the end of its write queue
//! when HTTP/2 can still speak, and the connection goes on the ready queue.
//! Its next `driveConnection`, which only the loop's connection handlers
//! call and never another handler, resets its streams toward their workers
//! through the lane's handler for a client's RST_STREAM
//! (`handleH2ResetFrame`), flushes the queue while a GOAWAY waits in it, and
//! tears the connection down. So no handler finds the slot of a connection
//! it is working on gone under it.
//!
//! Polls are one-shot, one per interest. `registered_wait_events` records
//! the polls in flight: a poll's completion clears its bit (the loop's
//! connection handlers in `ring_driver.zig`) and `updateConnectionInterest`
//! arms only the interests without one, so while the record is kept a
//! connection has at most one poll per interest. Every poll and cancel
//! carries the connection's slot and generation in its user_data, so a
//! completion that outlives its connection reads as stale and a cancel
//! cannot reach a later connection on the same fd. The socket closes through
//! the ring behind the cancels of its polls (`event_sources.LaneRing`), so
//! the descriptor's number stays taken until no prepared entry names it.
//!
//! Every drive ends by bringing the connection's deadline in step with what
//! it now waits for (`deadline_driver.syncConnectionDeadline`): the loop's
//! turn (`driveConnection`) and a handler's drive of a connection with bytes
//! waiting (`driveHttp2`) alike. Whatever changes a connection outside a
//! drive queues it for a turn, so its deadline follows within the pass.

const std = @import("std");
const process = @import("collo_os").process;
const h2 = @import("collo_http").http2;

const fault = @import("../fault.zig");
const connection_slot = @import("connection_slot.zig");
const deadline_driver = @import("deadline_driver.zig");
const event_sources = @import("event_sources.zig");
const request_body = @import("request_body.zig");
const stream_table = @import("stream_table.zig");
const tls_handshake = @import("tls_handshake.zig");
const work_queues = @import("work_queues.zig");
const http2_connection = @import("../http2/connection.zig");
const http2_writing = @import("../http2/writing.zig");

const ConnectionSlot = connection_slot.Slot;
const LaneFault = fault.LaneFault;

pub fn Methods(comptime Self: type) type {
    return struct {
        const Deadlines = deadline_driver.Methods(Self);
        const Queues = work_queues.Methods(Self);

        /// Drives the connection in `slot` by its phase, the TLS handshake
        /// or HTTP/2, which act on every failure a client causes there, and
        /// finishes its close once the lane has decided one, before the
        /// drive or during it; a connection that stays brings its deadline
        /// in step. The loop's connection handlers call it, for a poll that
        /// completed or a connection queued for a turn, and nothing else
        /// does; `slot` holds a live connection. Returns whether anything
        /// happened; fails only with a lane fault.
        pub fn driveConnection(self: *Self, slot: u32) LaneFault!bool {
            const runtime = self.connections.get(slot) orelse return false;
            if (runtime.closing == null) {
                const did_work = switch (runtime.state) {
                    .tls_handshake => handshake: {
                        const handshake_did_work = try tls_handshake.drive(Self, self, runtime);
                        if (runtime.closing == null)
                            try Deadlines.syncConnectionDeadline(self, runtime);
                        break :handshake handshake_did_work;
                    },
                    .http2_connection => try driveHttp2(self, runtime),
                };
                if (runtime.closing == null)
                    return did_work;
            }
            return finishClose(Self, self, runtime);
        }

        /// Drives an HTTP/2 connection that has not been asked to close,
        /// then brings its deadline in step unless the drive decided a
        /// close. A decided close waits for the connection's next turn
        /// (`driveConnection`), so a handler that drives a connection
        /// between its own steps still finds the slot afterwards. Returns
        /// whether anything happened.
        pub fn driveHttp2(self: *Self, runtime: *ConnectionSlot) LaneFault!bool {
            std.debug.assert(runtime.state == .http2_connection);
            const start_ns = monotonicNowNs();
            const did_work = try http2_connection.drive(Self, self, runtime);
            self.lane.counters.h2_server_protocol_time_ns += monotonicNowNs() -| start_ns;
            if (runtime.closing == null)
                try Deadlines.syncConnectionDeadline(self, runtime);
            return did_work;
        }

        /// Arms a poll for each interest in `runtime.wait_events` that has
        /// none in flight. Fails with `error.IngressRingUnavailable` outside
        /// the lane's event loop, and with the ring's errors when a poll
        /// cannot be prepared.
        pub fn updateConnectionInterest(self: *Self, runtime: *ConnectionSlot) LaneFault!void {
            if (!runtime.isLive())
                return;
            const missing = missingConnectionInterest(
                runtime.wait_events,
                runtime.registered_wait_events,
            );
            if (missing == 0)
                return;

            const ring = self.runtime_ring orelse return error.IngressRingUnavailable;
            if ((missing & event_sources.read_interest) != 0) {
                try queueConnectionPoll(ring, runtime, event_sources.read_interest, .connection_read);
                runtime.registered_wait_events |= event_sources.read_interest;
            }
            if ((missing & event_sources.write_interest) != 0) {
                try queueConnectionPoll(ring, runtime, event_sources.write_interest, .connection_write);
                runtime.registered_wait_events |= event_sources.write_interest;
            }
        }

        /// Takes the decision to close the connection as `close` says, from
        /// any handler on the lane thread. When the connection speaks HTTP/2
        /// and `close.goaway` names a code, a GOAWAY with it ends the write
        /// queue, if the queue can take it. From here on the connection
        /// reads and queues nothing, and it goes on the ready queue, whose
        /// turn (`driveConnection`) finishes the close. A connection already
        /// closing keeps its first reason, stops waiting to flush and is
        /// queued again, so a second failure, or a deadline, ends a flush
        /// its socket does not take.
        pub fn closeRuntimeConnection(
            self: *Self,
            runtime: *ConnectionSlot,
            close: fault.ConnectionClose,
        ) void {
            if (!runtime.isLive())
                return;
            if (runtime.closing) |*closing| {
                closing.flush = false;
                Queues.enqueueConnection(self, runtime.key.slot);
                return;
            }
            const goaway_queued = if (close.goaway) |error_code|
                http2_writing.queueCloseGoaway(self.service.allocator, runtime, error_code)
            else
                false;
            runtime.closing = .{
                .reason = close.reason,
                .flush = goaway_queued,
                .decided_ns = self.monotonicNowNs(),
            };
            if (close.reason == .header_block_budget)
                self.lane.counters.header_block_budget_closes += 1;
            Queues.enqueueConnection(self, runtime.key.slot);
        }

        /// Closes the connection at once, without flushing anything, for the
        /// lane's own teardown, when no later pass will drive it. Its
        /// streams are reset toward their workers first, as on every close.
        pub fn tearDownConnection(self: *Self, runtime: *ConnectionSlot) LaneFault!void {
            if (!runtime.isLive())
                return;
            closeRuntimeConnection(self, runtime, .{ .reason = .server_stop, .goaway = null });
            _ = try finishClose(Self, self, runtime);
        }

        /// Resumes a connection after one of its requests finished: its next
        /// drive sends the window updates and the response bytes the finish
        /// left buffered, and its deadline follows its streams. A connection
        /// the lane closed, or decided to close, is left to that close.
        pub fn keepConnectionAfterActiveRequest(self: *Self, runtime: *ConnectionSlot) void {
            if (!runtime.isOpen())
                return;
            Queues.enqueueConnection(self, runtime.key.slot);
        }
    };
}

pub fn missingConnectionInterest(wait_events: i16, registered_wait_events: i16) i16 {
    return event_sources.readinessInterest(wait_events) & ~registered_wait_events;
}

pub const ConnectionPollCancelPlan = struct {
    read: bool = false,
    write: bool = false,
};

pub fn connectionPollCancelPlan(registered_wait_events: i16) ConnectionPollCancelPlan {
    return .{
        .read = (registered_wait_events & event_sources.read_interest) != 0,
        .write = (registered_wait_events & event_sources.write_interest) != 0,
    };
}

/// Finishes the close `closeRuntimeConnection` decided: resets the
/// connection's streams toward their workers, once, flushes the write queue
/// while a GOAWAY waits in it, and tears the connection down once nothing
/// more needs to go out. A queue the socket cannot take yet keeps the
/// connection until its write poll brings it back, under its stall deadline.
fn finishClose(comptime Self: type, self: *Self, runtime: *ConnectionSlot) LaneFault!bool {
    const closing = &runtime.closing.?;
    if (!closing.streams_reset) {
        closing.streams_reset = true;
        try resetStreams(Self, self, runtime);
    }
    if (closing.flush) {
        _ = try http2_writing.flushPendingWrite(Self, self, runtime);
        if (closing.flush and runtime.h2WritesPending()) {
            try deadline_driver.Methods(Self).syncConnectionDeadline(self, runtime);
            return true;
        }
    }
    try tearDown(Self, self, runtime);
    return true;
}

/// Resets each stream of a closing connection that may hold a request,
/// through the lane's handler for a client's RST_STREAM with CANCEL, so the
/// request leaves its worker or its wait. Nothing goes to the client, whose
/// connection is closing.
fn resetStreams(comptime Self: type, self: *Self, runtime: *ConnectionSlot) LaneFault!void {
    for (runtime.stream_ids, 0..) |stream_id, position| {
        if (stream_id == 0)
            continue;
        switch (stream_table.streamAt(runtime, position).state) {
            .preparing, .active => {},
            .vacant, .draining_response => continue,
        }
        _ = request_body.Methods(Self).handleH2ResetFrame(self, runtime, stream_id, @intFromEnum(h2.ErrorCode.cancel)) catch |err|
            switch (try fault.classifyConnectionError(.{ .http2 = err })) {
                // The connection is closing already, which is all either
                // outcome asks; the request is left to its deadline.
                .keep, .close => {},
            };
    }
}

/// Tears a connection down: its deadline, TLS session, polls, protocol
/// state, socket and slab entry all go, and the slot is free for the next
/// accept. The polls are cancelled before the socket closes, since a poll in
/// flight holds the socket open in the kernel; inside the loop both go
/// through the ring in that order, and outside it, where tearing the ring
/// down cancelled every poll, the socket closes at once.
fn tearDown(comptime Self: type, self: *Self, runtime: *ConnectionSlot) LaneFault!void {
    const reason: fault.ConnectionCloseReason = if (runtime.closing) |closing| closing.reason else .server_stop;
    deadline_driver.Methods(Self).clearConnectionDeadline(self, runtime);
    if (runtime.tls_connection) |*connection| {
        connection.deinit();
        runtime.tls_connection = null;
    }
    runtime.deinitProtocolState(self.service.allocator, &self.h2_lane.header_blocks);
    runtime.ktls_rekey_state.zero();
    if (self.runtime_ring) |ring| {
        try cancelConnectionPolls(Self, self, ring, runtime);
        try ring.queueClose(runtime.fd, .{
            .kind = .connection_close,
            .index = runtime.key.slot,
            .generation = connection_slot.connectionGenerationTag(runtime.key),
        });
    } else {
        std.posix.close(runtime.fd);
    }
    runtime.fd = -1;
    runtime.registered_wait_events = 0;
    std.log.debug("ingress lane {d} closed a connection: {s}", .{ self.listener_index, reason.label() });
    // A ready-queue entry for this slot stays queued across the release
    // (`work_queues.zig`).
    self.connections.release(runtime.key.slot);
}

fn queueConnectionPoll(
    ring: *event_sources.LaneRing,
    runtime: *ConnectionSlot,
    interest: i16,
    kind: event_sources.EventKind,
) LaneFault!void {
    try ring.queuePoll(
        runtime.fd,
        event_sources.pollMask(event_sources.pollEventsForInterest(interest)),
        .{
            .kind = kind,
            .index = runtime.key.slot,
            .generation = connection_slot.connectionGenerationTag(runtime.key),
        },
    );
}

fn cancelConnectionPolls(comptime Self: type, self: *Self, ring: *event_sources.LaneRing, runtime: *ConnectionSlot) LaneFault!void {
    const plan = connectionPollCancelPlan(runtime.registered_wait_events);
    if (plan.read)
        try queueConnectionPollCancel(Self, self, ring, runtime, .connection_read);
    if (plan.write)
        try queueConnectionPollCancel(Self, self, ring, runtime, .connection_write);
}

fn queueConnectionPollCancel(
    comptime Self: type,
    self: *Self,
    ring: *event_sources.LaneRing,
    runtime: *ConnectionSlot,
    target_kind: event_sources.EventKind,
) LaneFault!void {
    // Cancel by user_data instead of fd so fd reuse cannot target a new connection.
    const tag = connection_slot.connectionGenerationTag(runtime.key);
    self.lane.counters.connection_poll_cancel_attempts += 1;
    try ring.queuePollCancel(
        .{ .kind = .connection_poll_cancel, .index = runtime.key.slot, .generation = tag },
        .{ .kind = target_kind, .index = runtime.key.slot, .generation = tag },
    );
}

fn monotonicNowNs() u64 {
    return process.monotonicNowNsOrZero();
}

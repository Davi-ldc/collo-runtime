//! The HTTP/2 connection driver of an ingress lane, on the lane thread that
//! owns the connection slot, whose state `runner/connection_slot.zig`
//! holds. This file runs a connection's turn (`drive`) and acts on the
//! errors a client causes. `reading.zig` reads the socket and handles each
//! frame; `writing.zig` queues and writes everything bound for the client:
//! response heads and bodies, control frames, and the WINDOW_UPDATE frames
//! that return receive credit.
//!
//! The driver is generic over `Worker`, the lane. It reads the lane's
//! `h2_lane` (`lane_resources.zig`) and `service.allocator`, and calls on it
//! the stream handlers of `runner/admission.zig` (`startDynamicH2`,
//! `refuseH2Stream`) and `runner/request_body.zig` (`handleH2DataFrame`,
//! `handleH2DataFrameBatch`, `handleH2ResetFrame`,
//! `flushPendingH2RequestBodies`), `updateConnectionInterest`,
//! `queueConnectionTurn`, `closeRuntimeConnection`, the response credit of
//! `runner/dispatch.zig` (`responseChunkRetired`, `grantResponseCredit`)
//! and the lane's clock (`monotonicNowNs`), each of which `LaneWorker`
//! declares (`runner/root.zig`), and counts its client writes in
//! `lane.counters`.
//!
//! Every error a client causes ends in the driver as a `ConnectionOutcome`
//! (`server/ingress/fault.zig`), sorted with the table of the callee that
//! returned it and acted on where it is met: a stream error resets its
//! stream, and a connection error asks the lane to close the connection
//! (`closeRuntimeConnection` on the lane), which queues GOAWAY while HTTP/2
//! can still speak. `drive` and the functions other files call to answer or
//! reset a stream fail only with the lane's own faults (`LaneFault`). The
//! functions that queue a worker's response return its errors instead, for
//! the caller to sort with `classifyResponseQueueError`, since only the
//! caller knows the worker.
//!
//! Invariants:
//! - No read starts while the socket refuses queued writes (the queue is
//!   blocked, `runner/write_queue.zig`), so a client that does not read its
//!   responses is not read either. A read once made is handled to its last
//!   byte (`reading.zig`).
//! - A drive flushes the connection's queue before its first read and after
//!   each read, and what it queues in between waits for the next of those
//!   flushes (`Slot.h2_driving`), so the frames one read brings about leave
//!   in one write, with the receive credit the connection owes at its tail.
//! - A connection closes in two steps (`runner/connection_flow.zig`). The
//!   driver only asks the lane to close it, and from then on the connection
//!   reads no frame and queues none; its queue is written only while the
//!   close flushes the GOAWAY that `queueCloseGoaway` put last in it.
//! - One drive reads the socket at most `reads_per_drive_max` times, so a
//!   client that keeps its socket full waits for the lane's next pass like
//!   every other connection.
//! - A drive reads only while no read poll of the connection is in flight,
//!   and after a read that left room in the read buffer it arms the poll
//!   instead of reading again. A one-shot poll armed on a readable socket
//!   completes at once, so neither rule leaves bytes unread; they only spare
//!   the reads that would find nothing.

const connection_slot = @import("../runner/connection_slot.zig");
const event_sources = @import("../runner/event_sources.zig");
const fault = @import("../fault.zig");
const reading = @import("reading.zig");
const writing = @import("writing.zig");

const LaneFault = fault.LaneFault;
/// What the frame loop and the queue functions meet before the drive sorts
/// it: the lane's own faults and the HTTP/2 layer's errors.
pub const Http2Failure = fault.LaneFault || fault.Http2Error;
const Slot = connection_slot.Slot;

/// Socket reads one drive makes before it gives the lane back to its other
/// connections. One read takes at most the lane's read buffer
/// (`lane_resources.zig:LaneResources.read_buffer_bytes`).
const reads_per_drive_max: usize = 8;

/// What the lane did with a DATA frame's payload, which decides when its
/// receive credit goes back to the client.
pub const DataFrameHandling = enum {
    /// The bytes reached their last owner: the worker (inline on its control
    /// socket or through its ingress payload ring), a response the lane wrote
    /// alone, or a reset stream. The server holds none of them, so the credit
    /// returns now.
    consumed,
    /// The server still holds the bytes: the stream has no worker yet, or its
    /// worker's ingress payload ring is full. No WINDOW_UPDATE goes out until
    /// the bytes reach the worker, or until the stream ends and drops them,
    /// which returns the connection's share of the credit.
    deferred,
};

/// One DATA frame of a batch. `window_credit_len` is the flow-control credit
/// the frame consumed: its whole payload, padding included.
pub const DataFrameChunk = struct {
    payload: []const u8,
    end_stream: bool,
    window_credit_len: usize,
};

/// Advances one connection until its socket would block or a read leaves
/// room in the read buffer, the socket refuses queued writes, the
/// connection closes or `reads_per_drive_max` reads are made, and returns
/// whether anything happened. A connection whose read poll is in flight is
/// not read. What the drive queues leaves at its flushes: one before the
/// first read, which also takes what the pass queued for the connection
/// before the drive, and one after each read. A stream error resets its
/// stream; any other error a client causes asks the lane to close the
/// connection (`closeRuntimeConnection` on `Worker`). Fails only with a lane
/// fault.
pub fn drive(comptime Worker: type, worker: *Worker, runtime: *Slot) LaneFault!bool {
    if (!runtime.isOpen())
        return false;
    // Appends during the drive leave at its flushes and ask for no turn
    // (`writing.zig:noteQueued`).
    runtime.h2_driving = true;
    defer runtime.h2_driving = false;
    return driveFrames(Worker, worker, runtime) catch |err| {
        try closeForError(Worker, worker, runtime, err);
        return true;
    };
}

fn driveFrames(comptime Worker: type, worker: *Worker, runtime: *Slot) Http2Failure!bool {
    var did_work = false;
    // A queue the socket refused moves first, and nothing else does until
    // the socket takes it: its write poll brought the connection here, or
    // the turn finds that poll still in flight and the write is not tried.
    if (runtime.h2WritesBlocked()) {
        did_work = try writing.flushPendingWrite(Worker, worker, runtime);
        if (!runtime.isOpen() or runtime.h2WritesBlocked())
            return did_work;
    }
    did_work = (try worker.flushPendingH2RequestBodies(runtime)) or did_work;
    did_work = (try writing.flushPendingResponseData(Worker, worker, runtime, null)) or did_work;
    // What the pass queued before the drive and what the drive queued so far
    // leave in one write, with the receive credit the connection owes.
    did_work = (try writing.flushPendingWrite(Worker, worker, runtime)) or did_work;
    if (!runtime.isOpen() or runtime.h2WritesBlocked())
        return did_work;

    // A read poll in flight reports the socket's next bytes, so a turn the
    // connection got for its writes or a request's finish reads nothing.
    if (runtime.registered_wait_events & event_sources.read_interest != 0)
        return did_work;
    var reads: usize = 0;
    while (runtime.isOpen() and !runtime.h2WritesBlocked()) : (reads += 1) {
        if (reads == reads_per_drive_max) {
            // Bytes may remain on the socket. The read poll then completes
            // at once and brings the connection back on a later pass.
            try awaitReadable(Worker, worker, runtime);
            return true;
        }
        const outcome = try reading.readAndProcess(Worker, worker, runtime);
        switch (outcome) {
            .idle => return did_work,
            .ended, .full, .short => did_work = true,
        }
        // What the read queued leaves before the next read, with the credit
        // the read made owed, alone once it is due, so a drive of several
        // reads never holds the client's window at half or below
        // (`Slot.h2WindowUpdateDue`).
        _ = try writing.flushPendingWrite(Worker, worker, runtime);
        switch (outcome) {
            .idle, .ended, .full => {},
            // A read that left room in the buffer emptied the socket, so the
            // read poll stands in for the next read, which would most likely
            // find nothing; bytes that came since complete it at once.
            .short => {
                try awaitReadable(Worker, worker, runtime);
                return true;
            },
        }
    }
    return did_work;
}

/// Arms the connection's read poll, unless the connection closes or the
/// socket refuses queued writes: such a connection is read again only once
/// its write poll brought it back and the queue drained.
fn awaitReadable(comptime Worker: type, worker: *Worker, runtime: *Slot) LaneFault!void {
    if (!runtime.isOpen() or runtime.h2WritesBlocked())
        return;
    runtime.wait_events = event_sources.read_events;
    try worker.updateConnectionInterest(runtime);
}

pub const IoDirection = enum { read, write };

/// Acts on a read or write of the client socket that did not complete: one
/// that would block waits for the socket's readiness in that direction, and
/// reading waits too while writes are queued. One that failed asks the lane
/// to close the connection. Returns whether the connection closes.
pub fn actOnClientIo(
    comptime Worker: type,
    worker: *Worker,
    runtime: *Slot,
    direction: IoDirection,
    err: (fault.LaneFault || fault.ClientIoError),
) LaneFault!bool {
    switch (try fault.classifyConnectionError(.{ .client_io = err })) {
        .keep => {
            runtime.wait_events = switch (direction) {
                .read => event_sources.read_events,
                .write => event_sources.write_events,
            };
            try worker.updateConnectionInterest(runtime);
            return false;
        },
        .close => |close| {
            worker.closeRuntimeConnection(runtime, close);
            return true;
        },
    }
}

/// Asks the lane to close the connection for an HTTP/2 error as its table
/// row says, or returns the error when it is the lane's own. Every row
/// closes. An error a row kept would still have interrupted the frame or
/// the write it concerned, which nothing resumes, so it closes as the
/// lane's own failure.
pub fn closeForError(comptime Worker: type, worker: *Worker, runtime: *Slot, err: Http2Failure) LaneFault!void {
    const close: fault.ConnectionClose = switch (try fault.classifyConnectionError(.{ .http2 = err })) {
        .close => |close| close,
        .keep => .{ .reason = .internal_error, .goaway = .internal_error },
    };
    worker.closeRuntimeConnection(runtime, close);
}

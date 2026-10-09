//! An ingress lane's registration of one worker: what the lane keeps for a
//! worker it has requests on or reads. Owned by the lane thread, in the
//! lane's registration slab (`LaneWorker.registrations` in
//! `runner/root.zig`); the registration's life is run by
//! `runner/worker_registration.zig`.
//!
//! - A lane registers a worker when it first dispatches a request to it or
//!   becomes its reader, and keeps the registration while it has requests on
//!   the worker, reads it, or has a fault of it deferred to the end of a
//!   pass (its place on the lane's death queue, `slab_link.queued`).
//!   `tenure` is set exactly while the lane is the worker's reader
//!   (`server/supervisor/pool.zig`); only then does the registration poll
//!   the worker's completion eventfd, control socket, fault socket and pidfd,
//!   on behalf of every lane with requests on the worker. A reader stops
//!   reading only when `Pool.transferReader` ends its tenure (`.vacated` or
//!   `.retire`), so an idle worker keeps its reader. Either kind of
//!   registration may poll the control socket for writability while a send
//!   of the lane's waits for room; a send that waits on the worker's full
//!   payload ring polls nothing (`runner/request_body.zig`).
//! - A reader whose worker's forwarding window is full (`window_blocked`)
//!   arms no poll on the worker's control socket until the window reopens,
//!   so it neither receives the worker's packets nor spins on them
//!   (`runner/worker_control.zig`). Its completion wake meanwhile serves
//!   only the request bodies waiting for ring room, and the ring waits behind
//!   the control socket (`runner/worker_completions.zig`).
//! - The descriptors and the payload view are borrowed from the worker's
//!   record (`server/supervisor/worker_table.zig`). The record outlives the
//!   registration, because a request's slot or the reader role keeps the
//!   worker in its pool's table, and the pool frees nothing before
//!   `Pool.remove`.
//! - Every poll carries the registration's index and `generation`, and the
//!   generation advances whenever the registration is freed, so a poll
//!   completion armed for an earlier worker in the same place reads as stale.
//!   A completion of a poll only a reader arms is also dropped once the
//!   registration no longer reads (`reading`).
//! - While it reads, the registration keeps the reader's account of the
//!   worker-to-server ring (`ring_payloads`): the payloads it forwarded to
//!   other lanes stay held, in ring order, until their owners answer, and
//!   ring bytes are freed only over the answered prefix
//!   (`lane_commands.PayloadConsumed`, `runner/h2_worker_ipc.zig`).

const std = @import("std");
const ipc = @import("collo_ipc");
const fault = @import("fault.zig");
const lifecycle = @import("collo_server_lifecycle");
const slab = @import("slab.zig");
const supervision = @import("collo_server_supervisor");
const worker_shared_page = @import("collo_worker_state").page;

const pool = supervision.pool;
const WorkerRecord = supervision.worker_table.Record;
const WorkerPool = supervision.WorkerPool;

pub const WorkerCompletionRecord = worker_shared_page.WorkerCompletionRecord;

/// The lane's registrations.
pub const RegistrationSlab = slab.FaultInSlab(Registration);
/// The registrations whose worker fault waits for the loop's next pass
/// (`runner/worker_fault.zig`, `deferWorkerFault`).
pub const DeathQueue = slab.Fifo(Registration);

/// Requests of one lane on one worker: each holds its own slot of the worker,
/// and a worker has at most `pool.slots_per_worker_max` slots.
pub const max_worker_inflight_requests: usize = pool.slots_per_worker_max;

/// The requests of other lanes whose responses the reader stopped forwarding
/// after the owner's queue refused one of their descriptors: the rest of each
/// response drops too, and the header of `runner/h2_worker_ipc.zig` says how
/// such a request ends. A key leaves when the response's last descriptor or
/// the request's completion passes the reader. A worker produces at most
/// `pool.slots_per_worker_max` responses at once, so a full list forgets its
/// oldest key.
pub const ForwardLoss = struct {
    keys: [pool.slots_per_worker_max]lifecycle.RequestKey = undefined,
    len: u8 = 0,

    pub fn contains(self: *const ForwardLoss, key: lifecycle.RequestKey) bool {
        for (self.keys[0..self.len]) |existing| {
            if (existing.eql(key))
                return true;
        }
        return false;
    }

    pub fn add(self: *ForwardLoss, key: lifecycle.RequestKey) void {
        if (self.contains(key))
            return;
        if (self.len == self.keys.len) {
            std.mem.copyForwards(lifecycle.RequestKey, self.keys[0 .. self.len - 1], self.keys[1..self.len]);
            self.len -= 1;
        }
        self.keys[self.len] = key;
        self.len += 1;
    }

    pub fn remove(self: *ForwardLoss, key: lifecycle.RequestKey) void {
        for (self.keys[0..self.len], 0..) |existing, index| {
            if (!existing.eql(key))
                continue;
            std.mem.copyForwards(lifecycle.RequestKey, self.keys[index .. self.len - 1], self.keys[index + 1 .. self.len]);
            self.len -= 1;
            return;
        }
    }
};

pub const Registration = struct {
    slab_link: slab.Link = .{},
    /// The worker; null only while the registration is being bound.
    worker: ?*WorkerRecord = null,
    worker_key: lifecycle.WorkerKey = .{ .worker_id = 0, .worker_generation = 0 },
    /// The epoch every poll's user_data carries: it advances whenever the
    /// registration stops reading or is freed, so a completion of a poll
    /// armed before reads as stale.
    generation: u32 = 0,
    /// The reader tenure this lane holds over the worker, set exactly while
    /// it reads the worker.
    tenure: ?pool.ReaderTenure = null,
    /// Why this lane took the worker for dead, set by the first fault the
    /// lane records; every request the death ends carries it. It lasts until
    /// the registration is freed, which is after the death path queued the
    /// worker's retirement.
    fault: ?fault.WorkerFaultReason = null,
    /// The pool's notice of a death a deferred fault took out of service,
    /// which the death path still owes the lanes it names
    /// (`worker_fault.deferWorkerFault`).
    death_notice: ?WorkerPool.Death = null,
    event_fd: std.posix.fd_t = -1,
    control_fd: std.posix.fd_t = -1,
    pidfd: std.posix.fd_t = -1,
    /// The server end of the worker's fault socket pair. Only the reader
    /// reads it and answers on it.
    fs_fault_fd: std.posix.fd_t = -1,
    ingress_payload: ?*ipc.ingress_channel.SharedPayloadView = null,
    /// The eventfd the worker polls for room in its worker-to-server ring,
    /// which the reader signals only when the worker marked itself waiting
    /// (`SharedPayloadReadRelease`).
    ingress_payload_credit_eventfd: std.posix.fd_t = -1,
    inflight_request_keys: [max_worker_inflight_requests]lifecycle.RequestKey = undefined,
    inflight_request_len: usize = 0,
    /// One flag per poll in flight; a completion clears its own.
    poll_registered: bool = false,
    control_poll_registered: bool = false,
    fs_fault_poll_registered: bool = false,
    pidfd_poll_registered: bool = false,
    control_writable_poll_registered: bool = false,
    /// The reader stopped receiving the worker's packets until the worker's
    /// forwarding window reopens (the file header).
    window_blocked: bool = false,
    /// The reader's account of the worker's `worker_to_server` ring: what
    /// it decoded and holds for other lanes, and where the next payload
    /// starts (`ipc.ingress_channel.SharedPayloadHolds`). Kept for one
    /// tenure; `endTenure` clears it without freeing ring bytes.
    ring_payloads: ipc.ingress_channel.SharedPayloadHolds = .{},
    /// Responses this reader stopped forwarding (`ForwardLoss`). Kept for
    /// one tenure; `endTenure` clears it.
    forward_loss: ForwardLoss = .{},

    /// Ends the tenure: forgets the ring account and the forward losses,
    /// freeing no ring bytes. The caller has submitted the cancels of the
    /// polls only a reader arms; their completions find a registration that
    /// no longer reads and are dropped. A live worker's role is given up only
    /// with the account empty, since the next reader decodes from the ring's
    /// read cursor (`Pool.transferReader`).
    pub fn endTenure(self: *Registration) void {
        self.tenure = null;
        self.ring_payloads.clear();
        self.forward_loss = .{};
        self.window_blocked = false;
    }

    pub fn inUse(self: *const Registration) bool {
        return self.slab_link.live;
    }

    pub fn reading(self: *const Registration) bool {
        return self.tenure != null;
    }

    pub fn containsInflight(self: *const Registration, request_key: lifecycle.RequestKey) bool {
        for (self.inflight_request_keys[0..self.inflight_request_len]) |existing| {
            if (existing.eql(request_key))
                return true;
        }
        return false;
    }

    pub fn removeInflight(self: *Registration, request_key: lifecycle.RequestKey) void {
        var index: usize = 0;
        while (index < self.inflight_request_len) : (index += 1) {
            if (!self.inflight_request_keys[index].eql(request_key))
                continue;
            self.inflight_request_len -= 1;
            self.inflight_request_keys[index] = self.inflight_request_keys[self.inflight_request_len];
            return;
        }
    }

    pub fn copyInflight(self: *const Registration, out: []lifecycle.RequestKey) usize {
        const count = @min(out.len, self.inflight_request_len);
        @memcpy(out[0..count], self.inflight_request_keys[0..count]);
        return count;
    }
};

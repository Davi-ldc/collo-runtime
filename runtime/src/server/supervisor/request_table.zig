//! The requests of one worker as the usage path needs them: what the server
//! dispatched to it (each request's identity, route, accounting flags and
//! start), whether a request's usage record is settled, and, once the
//! request ended, whether the worker's own record for it is still to come.
//! Every supervisor worker record holds one (`worker_table.Record.requests`).
//! The worker's reader also claims here the one completion of a request it
//! forwards to another lane (`claimCompletion`), and checks each descriptor
//! it forwards against the request it names (`forwardCheck`).
//!
//! The table decides which worker-written usage records the server keeps. A
//! worker appends a request's record to its usage ring before it publishes
//! the request's completion, so when the server settles a request the worker
//! completed, the record is already in the ring or already drained. A drain
//! keeps a worker record only when its request id names an entry of the
//! table of the worker whose ring held it, and that request still expects a
//! record (`expected`); every other record is counted as rejected and
//! dropped (`usage_drain.zig`). A worker therefore cannot write a record for
//! a request it was never dispatched, two records for one request, or one
//! for a request whose floor the server wrote. A kept record carries the
//! entry's request id and route, never the identity fields the worker wrote.
//!
//! An entry is in one of these states:
//! - `in_flight`: the request holds one of the worker's pool slots, and no
//!   usage record is settled for it.
//! - `synthesizing`: the request holds a slot and the server is writing its
//!   floor record (`claimSynthesisForLifecycle` in `usage_drain.zig`); a
//!   worker record for it is refused.
//! - `recorded`: the request holds a slot and its usage record is settled:
//!   written by a drain or as a floor, or dropped by a full usage stream
//!   (`UsageLog.append`). Either way no other record is kept for it.
//! - `awaiting_record`: the request gave its slot back, and the worker's own
//!   record for it is not drained yet: the one appended before the
//!   completion, or one a synthesis left expected (`SynthesisOutcome` in
//!   `usage_drain.zig`). The drain that settles the record, writing or
//!   dropping it, frees the entry.
//!
//! Bounds: at most `in_flight_max` entries hold a slot, since a worker's pool
//! gives it at most its definition's `concurrency` slots, and at most
//! `awaiting_record_max` wait for a record, so `entries_max` entries always
//! suffice and recording never allocates. When one more request would await
//! its record past that bound, the settling thread drains the worker first,
//! which frees the entries whose records an honest worker already appended
//! (`settleRequest` in `usage_drain.zig`). If the table is still full, the
//! worker published completions without appending their records first: the
//! oldest waiting entry is evicted, and a record for that request that shows
//! up later is refused.
//!
//! Locks: `mutex` is a leaf. A drain checks and marks entries while it holds
//! the worker's `metrics_mutex`, and synthesis claims a request under the
//! same lock (`claimSynthesisForLifecycle`), so the table and the ring scan
//! give one answer. The table's methods take only `mutex`, so a dispatch
//! never waits on a drain, and a settle does only when it drains the worker
//! itself.

const std = @import("std");
const server_limits = @import("collo_limits").server;
const lifecycle = @import("collo_server_lifecycle");
const config = @import("collo_server_config");

/// Entries that hold a pool slot: one per slot a worker can have.
pub const in_flight_max: usize = server_limits.worker_concurrency_max;
/// Completed requests one worker may leave waiting for their usage record
/// between two usage drains (`metrics_drain_interval_ns` apart, in
/// `server/ingress/service_observability.zig`) before a settling thread
/// drains the worker itself. A worker that finishes more requests than this
/// per interval costs one drain per this many completions on the threads
/// that settle them; below it, settling never drains.
pub const awaiting_record_max: usize = 32;
pub const entries_max: usize = in_flight_max + awaiting_record_max;

pub const EntryState = enum(u8) {
    free,
    in_flight,
    synthesizing,
    recorded,
    awaiting_record,
};

/// A request the server dispatched to the table's worker, as the lane
/// records it before it sends the request, so that the worker's record can
/// never reach a drain ahead of its entry.
pub const Dispatched = struct {
    /// Never 0: the server allocates no request id 0
    /// (`Service.allocateRequestId` in `server/ingress/service.zig`).
    request_id: u64,
    /// The lane request slot the dispatch names. With the worker's key it is
    /// the request's identity in the worker's live slot and in the usage
    /// log's exactly-once index.
    request_key: lifecycle.RequestKey,
    /// The route the lane matched, within the worker's definition. The
    /// request's usage record carries its pattern.
    route: config.RouteIndex,
    /// The `CompletedRecordFlags` the dispatch carries, which a floor record
    /// carries too.
    accounting_flags: u32,
    /// When the server dispatched the request (CLOCK_MONOTONIC). A floor
    /// record starts here when no live slot of the worker matches the
    /// request, and at the live slot's start when one does
    /// (`synthesizeRecordForLifecycle` in `usage_drain.zig`).
    started_mono_ns: u64,
};

pub const Entry = struct {
    /// Meaningful unless `state` is `free`.
    dispatched: Dispatched = unused,
    /// Order among `awaiting_record` entries; the lowest is evicted first.
    settled_sequence: u64 = 0,
    state: EntryState = .free,
    /// The worker's reader forwarded a completion for the request
    /// (`claimCompletion`).
    completion_claimed: bool = false,

    const unused: Dispatched = .{
        .request_id = 0,
        .request_key = .{ .lane_id = 0, .slot = 0, .generation = 0 },
        .route = 0,
        .accounting_flags = 0,
        .started_mono_ns = 0,
    };
};

/// What `claimCompletion` found for a completion a worker published.
pub const CompletionClaim = enum {
    /// The request holds its slot and no completion of it was claimed
    /// before; this one is now.
    claimed,
    /// The request gave its slot back or has no entry, or a completion of
    /// it was claimed already.
    stale,
    /// The table holds the request id under another request key, which only
    /// a worker that rewrote the identity of a request it was sent names.
    mismatch,
};

/// What `forwardCheck` found for a descriptor a worker addressed to a request
/// of another lane.
pub const ForwardCheck = enum {
    /// The request holds its slot under the descriptor's key.
    live,
    /// The request gave its slot back or has no entry. Its owner would drop
    /// the descriptor, so the reader drops it instead of taking a place in
    /// the owner's queue.
    absent,
    /// The table holds the request id under another request key, which only
    /// a worker that rewrote the identity of a request it was sent names.
    mismatch,
};

/// How `settle` left a request's entry.
pub const Settled = enum {
    /// The entry is free, or the request had none.
    freed,
    /// The entry waits for the worker's record.
    awaiting_record,
    /// The entry would wait for the worker's record, but `awaiting_record_max`
    /// entries already do; it is unchanged and still holds its slot's place.
    awaiting_full,
};

pub const RequestTable = struct {
    entries: [entries_max]Entry = @splat(.{}),
    /// Entries in `awaiting_record`.
    awaiting_count: usize = 0,
    /// Source of `Entry.settled_sequence`.
    settled_sequence_next: u64 = 1,
    mutex: std.Thread.Mutex = .{},

    /// Records a request dispatched to this table's worker.
    /// `error.RequestTableFull` means a caller broke the bounds in the header:
    /// a request recorded twice, or an entry its request never settled. The
    /// dispatch fails rather than overwrite another request's entry.
    pub fn record(self: *RequestTable, dispatched: Dispatched) error{RequestTableFull}!void {
        std.debug.assert(dispatched.request_id != 0);
        self.mutex.lock();
        defer self.mutex.unlock();
        for (&self.entries) |*entry| {
            if (entry.state == .free) {
                entry.* = .{ .dispatched = dispatched, .state = .in_flight };
                return;
            }
        }
        return error.RequestTableFull;
    }

    /// Frees the request's entry whatever it waits for: the dispatch never
    /// reached the worker, so no record for it is kept or written. A request
    /// with no entry is left alone.
    pub fn remove(self: *RequestTable, request_id: u64) void {
        std.debug.assert(request_id != 0);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (findLocked(self, request_id)) |entry|
            freeLocked(self, entry);
    }

    /// The request ended and is giving its slot back. With
    /// `expects_worker_record`, the request's usage still comes from the
    /// worker's own record (`settleRequest` in `usage_drain.zig` says when): an
    /// entry with no record yet waits for it, unless `awaiting_record_max`
    /// entries already wait. Otherwise the server accounted for the request
    /// itself and the entry is freed.
    pub fn settle(self: *RequestTable, request_id: u64, expects_worker_record: bool) Settled {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = findLocked(self, request_id) orelse return .freed;
        switch (entry.state) {
            // `findLocked` returns no free entry.
            .free => unreachable,
            .awaiting_record => return .awaiting_record,
            .recorded, .synthesizing => {
                freeLocked(self, entry);
                return .freed;
            },
            .in_flight => {
                if (!expects_worker_record) {
                    freeLocked(self, entry);
                    return .freed;
                }
                if (self.awaiting_count >= awaiting_record_max)
                    return .awaiting_full;
                awaitLocked(self, entry);
                return .awaiting_record;
            },
        }
    }

    /// `settle` for a request whose worker record is expected, evicting the
    /// oldest awaiting entry when `awaiting_record_max` entries wait. Returns
    /// the id of the evicted request, whose record is now refused when it
    /// shows up.
    pub fn settleEvictingOldest(self: *RequestTable, request_id: u64) ?u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = findLocked(self, request_id) orelse return null;
        if (entry.state != .in_flight) {
            if (entry.state != .awaiting_record)
                freeLocked(self, entry);
            return null;
        }
        var evicted: ?u64 = null;
        if (self.awaiting_count >= awaiting_record_max) {
            const oldest = oldestAwaitingLocked(self);
            evicted = oldest.dispatched.request_id;
            freeLocked(self, oldest);
        }
        awaitLocked(self, entry);
        return evicted;
    }

    /// Claims the one completion of the request `request_id` and
    /// `request_key` name, which the worker's reader forwards to the lane
    /// that owns the request. A worker writes its completions in memory it
    /// controls, so this is what bounds the completions a reader forwards to
    /// one per request in flight, the bound the owner lane's command reserve
    /// counts on (`server/ingress/commands.zig`).
    pub fn claimCompletion(
        self: *RequestTable,
        request_id: u64,
        request_key: lifecycle.RequestKey,
    ) CompletionClaim {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = findLocked(self, request_id) orelse return .stale;
        if (!entry.dispatched.request_key.eql(request_key))
            return .mismatch;
        switch (entry.state) {
            .in_flight, .synthesizing, .recorded => {},
            .free, .awaiting_record => return .stale,
        }
        if (entry.completion_claimed)
            return .stale;
        entry.completion_claimed = true;
        return .claimed;
    }

    /// Checks a descriptor the worker's reader is about to forward to the
    /// lane that owns its request (`server/ingress/runner/h2_worker_ipc.zig`):
    /// the request `request_id` names must hold its slot under
    /// `request_key`.
    pub fn forwardCheck(
        self: *RequestTable,
        request_id: u64,
        request_key: lifecycle.RequestKey,
    ) ForwardCheck {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = findLocked(self, request_id) orelse return .absent;
        if (!entry.dispatched.request_key.eql(request_key))
            return .mismatch;
        return switch (entry.state) {
            .in_flight, .synthesizing, .recorded => .live,
            .free, .awaiting_record => .absent,
        };
    }

    /// What the server dispatched for `request_id`, or null when the table
    /// holds no entry for it.
    pub fn dispatchedFor(self: *RequestTable, request_id: u64) ?Dispatched {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = findLocked(self, request_id) orelse return null;
        return entry.dispatched;
    }

    /// What the server dispatched for `request_id` when the table expects a
    /// usage record for it, the one a drain then writes under that entry's
    /// request id and route; null when it expects none: no entry, a record
    /// already settled, or a floor being written.
    pub fn expected(self: *RequestTable, request_id: u64) ?Dispatched {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = findLocked(self, request_id) orelse return null;
        return switch (entry.state) {
            .in_flight, .awaiting_record => entry.dispatched,
            .free, .synthesizing, .recorded => null,
        };
    }

    /// Marks the records of `request_ids` as settled, whether the usage
    /// stream took them or a full stream dropped them: a request in flight
    /// becomes `recorded`, and one awaiting its record frees its entry. An
    /// id the table holds in no such state is skipped.
    pub fn markUsageRecorded(self: *RequestTable, request_ids: []const u64) void {
        if (request_ids.len == 0)
            return;
        self.mutex.lock();
        defer self.mutex.unlock();
        for (request_ids) |request_id| {
            const entry = findLocked(self, request_id) orelse continue;
            switch (entry.state) {
                .in_flight => entry.state = .recorded,
                .awaiting_record => freeLocked(self, entry),
                .free, .synthesizing, .recorded => {},
            }
        }
    }

    pub fn usageRecorded(self: *RequestTable, request_id: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = findLocked(self, request_id) orelse return false;
        return entry.state == .recorded;
    }

    /// The server starts writing the floor record of a request in flight.
    pub fn beginSynthesis(self: *RequestTable, request_id: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = findLocked(self, request_id) orelse return;
        if (entry.state == .in_flight)
            entry.state = .synthesizing;
    }

    /// The floor record of a request was written, or could not be, in which
    /// case a worker record for the request is accepted again.
    pub fn finishSynthesis(self: *RequestTable, request_id: u64, written: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = findLocked(self, request_id) orelse return;
        if (entry.state == .synthesizing)
            entry.state = if (written) .recorded else .in_flight;
    }

    /// Caller holds `mutex`. Id 0 matches nothing, so a worker-written 0
    /// cannot reach a free entry.
    fn findLocked(self: *RequestTable, request_id: u64) ?*Entry {
        if (request_id == 0)
            return null;
        for (&self.entries) |*entry| {
            if (entry.state != .free and entry.dispatched.request_id == request_id)
                return entry;
        }
        return null;
    }

    fn freeLocked(self: *RequestTable, entry: *Entry) void {
        if (entry.state == .awaiting_record) {
            std.debug.assert(self.awaiting_count > 0);
            self.awaiting_count -= 1;
        }
        entry.* = .{};
    }

    fn awaitLocked(self: *RequestTable, entry: *Entry) void {
        std.debug.assert(entry.state == .in_flight);
        std.debug.assert(self.awaiting_count < awaiting_record_max);
        entry.state = .awaiting_record;
        entry.settled_sequence = self.settled_sequence_next;
        self.settled_sequence_next += 1;
        self.awaiting_count += 1;
    }

    fn oldestAwaitingLocked(self: *RequestTable) *Entry {
        std.debug.assert(self.awaiting_count > 0);
        var oldest: ?*Entry = null;
        for (&self.entries) |*entry| {
            if (entry.state != .awaiting_record)
                continue;
            if (oldest) |current| {
                if (entry.settled_sequence < current.settled_sequence)
                    oldest = entry;
            } else {
                oldest = entry;
            }
        }
        return oldest.?;
    }
};

//! The requests of one worker as the usage path needs them: what the server
//! dispatched to it (each request's identity, route, accounting flags and
//! start), when the server ended each one, whether a request's usage record
//! is settled, and, once the request ended, which record of it is still to
//! come. Every supervisor worker record holds one
//! (`worker_table.Record.requests`). The worker's reader also claims here the
//! one completion of a request it forwards to another lane
//! (`claimCompletion`), and checks each descriptor it forwards against the
//! request it names (`forwardCheck`). The console drain names a line's
//! request through it (`routeOfRecent`).
//!
//! The table alone decides which record of a request the server keeps. A
//! worker appends a request's record to its usage ring before it publishes
//! the request's completion, so when the server settles a request the worker
//! completed, the record is already in the ring or already drained. A drain
//! asks the table about each worker record (`verdict`): it writes the record
//! only for a request of this table that still expects one and that the
//! server has ended (`noteEnded`), since the record's times are the server's
//! dispatch and end; it leaves the record in the ring while the server has
//! not ended the request or writes its floor; it skips the record silently
//! when the server already wrote the request's floor; and it refuses every
//! other record, counted (`usage_drain.zig`). A worker therefore cannot write
//! a record for a request it was never dispatched, two records for one
//! request, or one beside the floor the server wrote. A kept record carries
//! the entry's request id and route, never the identity fields the worker
//! wrote.
//!
//! An entry is in one of these states:
//! - `in_flight`: the request holds one of the worker's pool slots, and no
//!   usage record is settled for it.
//! - `synthesizing`: the request holds a slot and the server is writing its
//!   floor record (`claimSynthesisForLifecycle` in `usage_drain.zig`); a
//!   worker record for it waits in the ring.
//! - `recorded`: the request holds a slot and its usage record is settled:
//!   written by a drain or as the server's floor (`Entry.floor`), or dropped
//!   by a full usage stream (`UsageLog.append`). No other record is kept for
//!   it.
//! - `floor_written`: the request gave its slot back after the server wrote
//!   its floor. The entry stays so that the worker's own record for the
//!   request, which a dying worker may still have appended, is skipped
//!   without a count, as it is while the slot is held; the drain that meets
//!   that record frees it.
//! - `awaiting_record`: the request gave its slot back, and the worker's own
//!   record for it is not drained yet: the one appended before the
//!   completion, or one a synthesis left expected (`SynthesisOutcome` in
//!   `usage_drain.zig`). The drain that settles the record, writing or
//!   dropping it, frees the entry.
//!
//! Bounds: at most `in_flight_max` entries hold a slot, since a worker's pool
//! gives it at most its definition's `concurrency` slots, and at most
//! `parked_max` entries stay after their slot was released, awaiting a
//! record or keeping a floor, so `entries_max` entries always suffice and
//! recording never allocates. When one more entry would stay past that
//! bound, the oldest kept floor goes first, since it only spares a count; an
//! entry awaiting its record makes the settling thread drain the worker
//! first, which frees the entries whose records an honest worker already
//! appended (`settleRequest` in `usage_drain.zig`), and if the table is still
//! full, the worker published completions without appending their records
//! first: the oldest parked entry is evicted, and a record for that request
//! that shows up later is refused.
//!
//! Every request the worker heard of leaves its route in a ring of the last
//! `ended_requests_max` when its entry goes: settled, recorded, skipped or
//! evicted, but not `remove`d, since a request whose begin never reached the
//! worker cannot appear in its console lines. The console drain finds a
//! line's request among the entries, then in the ring, so a line a worker
//! wrote after its request ended still names the request's route.
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
/// Entries one worker may leave in the table after their slot was released:
/// completed requests waiting for their usage record between two usage
/// drains (`metrics_drain_interval_ns` apart, in
/// `server/ingress/service_observability.zig`), and floors kept until the
/// worker's record shows up. A worker that finishes more requests than this
/// per interval costs one drain per this many completions on the threads
/// that settle them; below it, settling never drains.
pub const parked_max: usize = 32;
pub const entries_max: usize = in_flight_max + parked_max;
/// Requests whose route the console drain can still find after their entry
/// left the table. The metrics thread drains console lines every
/// `metrics_drain_interval_ns`, so this covers a worker that ends this many
/// requests between two drains.
pub const ended_requests_max: usize = 256;

pub const EntryState = enum(u8) {
    free,
    in_flight,
    synthesizing,
    recorded,
    floor_written,
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
    /// the request's identity in the worker's live slot.
    request_key: lifecycle.RequestKey,
    /// The route the lane matched, within the worker's definition. The
    /// request's usage record carries its pattern.
    route: config.RouteIndex,
    /// The `AccountingFlags` (`common/worker_state/page/usage_records.zig`)
    /// the dispatch carries, from which the request's usage record takes its
    /// cold start.
    accounting_flags: u32,
    /// When the server dispatched the request (CLOCK_MONOTONIC), where the
    /// request's usage record starts, the worker's and a floor alike
    /// (`usageDispatch` in `usage_drain.zig`).
    started_mono_ns: u64,
};

/// A dispatched request the server ended.
pub const Ended = struct {
    dispatched: Dispatched,
    /// When the lane ended the request (CLOCK_MONOTONIC), where its usage
    /// record ends.
    ended_mono_ns: u64,
};

pub const Entry = struct {
    /// Meaningful unless `state` is `free`.
    dispatched: Dispatched = unused,
    /// When the lane ended the request (`noteEnded`); 0 while it has not.
    ended_mono_ns: u64 = 0,
    /// Order among parked entries; the lowest goes first.
    settled_sequence: u64 = 0,
    state: EntryState = .free,
    /// The usage record settled for a `recorded` entry is the server's floor,
    /// so the worker's own record for the request is skipped, not refused.
    floor: bool = false,
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

    fn parked(entry: *const Entry) bool {
        return entry.state == .awaiting_record or entry.state == .floor_written;
    }
};

/// A request whose entry left the table, as the console drain looks it up.
pub const EndedRequest = struct {
    request_id: u64,
    route: config.RouteIndex,
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

/// What a drain does with a worker record for a request id (`verdict`).
pub const Verdict = union(enum) {
    /// The table expects the record and the server ended its request: the
    /// drain writes it with these times.
    write: Ended,
    /// The record stays in the ring for a later drain: the server has not
    /// ended the request yet, or is writing its floor.
    wait,
    /// The server wrote the request's floor: the drain moves past the record
    /// without a count and frees the entry (`skipFloors`).
    skip,
    /// No record of this request is expected: the drain refuses it, counted.
    refuse,
};

/// How `settle` left a request's entry.
pub const Settled = enum {
    /// The entry is free, or the request had none.
    freed,
    /// The entry stays parked: it waits for the worker's record, or keeps
    /// the floor the server wrote.
    parked,
    /// The entry would wait for the worker's record, but `parked_max` entries
    /// already wait and none of them is a floor that could go first; it is
    /// unchanged and still holds its slot's place.
    parked_full,
};

pub const RequestTable = struct {
    entries: [entries_max]Entry = @splat(.{}),
    /// Entries in `awaiting_record` or `floor_written`.
    parked_count: usize = 0,
    /// Source of `Entry.settled_sequence`.
    settled_sequence_next: u64 = 1,
    /// A ring of `ended_len` requests ending at `ended_next`, the newest
    /// last; the slots past `ended_len` are never read.
    ended: [ended_requests_max]EndedRequest = undefined,
    ended_next: usize = 0,
    ended_len: usize = 0,
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
    /// reached the worker, so no record for it is kept or written, and no
    /// console line of the worker can name it. A request with no entry is
    /// left alone.
    pub fn remove(self: *RequestTable, request_id: u64) void {
        std.debug.assert(request_id != 0);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (findLocked(self, request_id)) |entry|
            freeLocked(self, entry);
    }

    /// The lane ended the request at `ended_mono_ns`, the instant its access
    /// record ends at too. The usage path calls it first when it settles a
    /// request whose begin reached the worker (`settleRequest` in
    /// `usage_drain.zig`), before any drain or floor, so a record the drain
    /// writes ends at the server's end and none is written before it. A
    /// request with no entry, or ended already, is left alone.
    pub fn noteEnded(self: *RequestTable, request_id: u64, ended_mono_ns: u64) void {
        std.debug.assert(ended_mono_ns != 0);
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = findLocked(self, request_id) orelse return;
        if (entry.ended_mono_ns == 0)
            entry.ended_mono_ns = ended_mono_ns;
    }

    /// The request ended and is giving its slot back. With
    /// `expects_worker_record`, the request's usage still comes from the
    /// worker's own record (`settleRequest` in `usage_drain.zig` says when):
    /// an entry with no record yet waits for it, unless `parked_max` entries
    /// already stay and none is a floor that may go first. A written floor
    /// stays parked, room permitting. Otherwise the server accounted for the
    /// request itself and the entry is freed.
    pub fn settle(self: *RequestTable, request_id: u64, expects_worker_record: bool) Settled {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = findLocked(self, request_id) orelse return .freed;
        switch (entry.state) {
            // `findLocked` returns no free entry.
            .free => unreachable,
            .awaiting_record, .floor_written => return .parked,
            .recorded => return settleRecordedLocked(self, entry),
            .synthesizing => {
                retireLocked(self, entry);
                return .freed;
            },
            .in_flight => {
                if (!expects_worker_record) {
                    retireLocked(self, entry);
                    return .freed;
                }
                if (!makeParkingRoomLocked(self))
                    return .parked_full;
                parkLocked(self, entry, .awaiting_record);
                return .parked;
            },
        }
    }

    /// `settle` for a request whose worker record is expected, evicting the
    /// oldest parked entry when `parked_max` entries stay. Returns the id of
    /// an evicted request that awaited its record, which is now refused when
    /// it shows up.
    pub fn settleEvictingOldest(self: *RequestTable, request_id: u64) ?u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = findLocked(self, request_id) orelse return null;
        switch (entry.state) {
            .free => unreachable,
            .awaiting_record, .floor_written => return null,
            .recorded => {
                _ = settleRecordedLocked(self, entry);
                return null;
            },
            .synthesizing => {
                retireLocked(self, entry);
                return null;
            },
            .in_flight => {},
        }
        var evicted: ?u64 = null;
        if (!makeParkingRoomLocked(self)) {
            const oldest = oldestParkedLocked(self, .awaiting_record).?;
            evicted = oldest.dispatched.request_id;
            retireLocked(self, oldest);
        }
        parkLocked(self, entry, .awaiting_record);
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
        if (!holdsSlot(entry.*))
            return .stale;
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
        if (holdsSlot(entry.*))
            return .live;
        return .absent;
    }

    /// What the server dispatched for `request_id`, or null when the table
    /// holds no entry for it.
    pub fn dispatchedFor(self: *RequestTable, request_id: u64) ?Dispatched {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = findLocked(self, request_id) orelse return null;
        return entry.dispatched;
    }

    /// What a drain does with a worker record for `request_id` (`Verdict`).
    pub fn verdict(self: *RequestTable, request_id: u64) Verdict {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = findLocked(self, request_id) orelse return .refuse;
        switch (entry.state) {
            .free => unreachable,
            .in_flight, .awaiting_record => {
                if (entry.ended_mono_ns == 0)
                    return .wait;
                return .{ .write = .{
                    .dispatched = entry.dispatched,
                    .ended_mono_ns = entry.ended_mono_ns,
                } };
            },
            .synthesizing => return .wait,
            .floor_written => return .skip,
            .recorded => {
                if (entry.floor)
                    return .skip;
                return .refuse;
            },
        }
    }

    /// Whether the table expects a usage record for `request_id`: an entry in
    /// flight or awaiting its record. A record found in the ring for such a
    /// request is one a drain keeps once the server ends the request.
    pub fn expectsRecord(self: *RequestTable, request_id: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = findLocked(self, request_id) orelse return false;
        return entry.state == .in_flight or entry.state == .awaiting_record;
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
                .awaiting_record => retireLocked(self, entry),
                .free, .synthesizing, .recorded, .floor_written => {},
            }
        }
    }

    /// Notes that a drain moved past the worker's records of `request_ids`,
    /// whose floors the server wrote: a kept floor frees its entry, and one
    /// whose request still holds its slot refuses any further record. An id
    /// in any other state is skipped.
    pub fn skipFloors(self: *RequestTable, request_ids: []const u64) void {
        if (request_ids.len == 0)
            return;
        self.mutex.lock();
        defer self.mutex.unlock();
        for (request_ids) |request_id| {
            const entry = findLocked(self, request_id) orelse continue;
            switch (entry.state) {
                .floor_written => retireLocked(self, entry),
                .recorded => entry.floor = false,
                .free, .in_flight, .synthesizing, .awaiting_record => {},
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

    /// The floor record of a request was written, which settles its usage
    /// (`recorded` with `floor`), or could not be, in which case a worker
    /// record for the request is accepted again.
    pub fn finishSynthesis(self: *RequestTable, request_id: u64, written: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = findLocked(self, request_id) orelse return;
        if (entry.state != .synthesizing)
            return;
        if (written) {
            entry.state = .recorded;
            entry.floor = true;
        } else {
            entry.state = .in_flight;
        }
    }

    /// The route of the request `request_id` names, from its entry in any
    /// state or from the ring of ended requests; null for id 0 and for any
    /// request the worker never heard of or ended too long ago.
    pub fn routeOfRecent(self: *RequestTable, request_id: u64) ?config.RouteIndex {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (findLocked(self, request_id)) |entry|
            return entry.dispatched.route;
        for (0..self.ended_len) |offset| {
            // Newest first: a request id is never reused, so order only
            // shortens the usual search, a line of a request just ended.
            const index = (self.ended_next + ended_requests_max - 1 - offset) % ended_requests_max;
            if (self.ended[index].request_id == request_id)
                return self.ended[index].route;
        }
        return null;
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

    /// Frees `entry`, a request the worker heard of, and remembers its route
    /// in the ring of ended requests.
    fn retireLocked(self: *RequestTable, entry: *Entry) void {
        self.ended[self.ended_next] = .{
            .request_id = entry.dispatched.request_id,
            .route = entry.dispatched.route,
        };
        self.ended_next = (self.ended_next + 1) % ended_requests_max;
        if (self.ended_len < ended_requests_max)
            self.ended_len += 1;
        freeLocked(self, entry);
    }

    fn freeLocked(self: *RequestTable, entry: *Entry) void {
        if (entry.parked()) {
            std.debug.assert(self.parked_count > 0);
            self.parked_count -= 1;
        }
        entry.* = .{};
    }

    /// A `recorded` entry whose request gives its slot back: a floor stays
    /// parked when there is room for it, and any other entry is freed.
    fn settleRecordedLocked(self: *RequestTable, entry: *Entry) Settled {
        std.debug.assert(entry.state == .recorded);
        if (entry.floor and makeParkingRoomLocked(self)) {
            parkLocked(self, entry, .floor_written);
            return .parked;
        }
        retireLocked(self, entry);
        return .freed;
    }

    /// Room for one more parked entry: true when there is room, after
    /// evicting the oldest kept floor if that makes it; false when every
    /// parked entry awaits a record.
    fn makeParkingRoomLocked(self: *RequestTable) bool {
        if (self.parked_count < parked_max)
            return true;
        const oldest_floor = oldestParkedLocked(self, .floor_written) orelse return false;
        retireLocked(self, oldest_floor);
        return true;
    }

    fn parkLocked(self: *RequestTable, entry: *Entry, state: EntryState) void {
        switch (state) {
            .awaiting_record => std.debug.assert(entry.state == .in_flight),
            .floor_written => std.debug.assert(entry.state == .recorded),
            .free, .in_flight, .synthesizing, .recorded => unreachable,
        }
        std.debug.assert(self.parked_count < parked_max);
        entry.state = state;
        entry.settled_sequence = self.settled_sequence_next;
        self.settled_sequence_next += 1;
        self.parked_count += 1;
    }

    fn oldestParkedLocked(self: *RequestTable, state: EntryState) ?*Entry {
        var oldest: ?*Entry = null;
        for (&self.entries) |*entry| {
            if (entry.state != state)
                continue;
            if (oldest) |current| {
                if (entry.settled_sequence < current.settled_sequence)
                    oldest = entry;
            } else {
                oldest = entry;
            }
        }
        return oldest;
    }
};

/// Whether an entry in `entry`'s state still holds its pool slot.
fn holdsSlot(entry: Entry) bool {
    return switch (entry.state) {
        .in_flight, .synthesizing, .recorded => true,
        .free, .awaiting_record, .floor_written => false,
    };
}

//! The host's reads of three sections a worker writes on its page: the
//! lifecycle header, the live slots and the usage record ring. Every host
//! reader of those sections goes through this file.
//!
//! The worker can rewrite any byte of its page at any moment, so two loads
//! of one field can disagree, and a check made on the first says nothing
//! about the second. Each type here therefore loads every field it needs
//! once, with one atomic load per field, into a private copy; the caller
//! validates that copy and uses only the copy. A tag stays the raw integer
//! the page holds: it is compared with the value it should have, or
//! converted with `std.enums.fromInt`, which yields null for a value its
//! enum does not name, and never with `@enumFromInt`. A cursor the host owns
//! lives in the host's memory: the host stores it to the page for the
//! worker's room check and never loads it back. The completion and console
//! rings keep the same rule inside their drains (`completion_ring.zig`,
//! `console_ring.zig`), and the boot stamps and the benchmark record are
//! diagnostics loaded once each (`boot_stamps.zig`).
//!
//! A copy that passes its checks is still the worker's claim. A live slot
//! that matches an identity names a request the host sent to that worker,
//! and the start time and CPU it reports reach only that worker's records.
//! A `RecordCursor` has one user at a time; the server's drains hold the
//! worker record's `metrics_mutex` (`server/supervisor/worker_table.zig`).

const std = @import("std");

const Header = @import("lifecycle.zig").Header;
const State = @import("lifecycle.zig").State;
const TerminationReason = @import("lifecycle.zig").TerminationReason;
const LifecycleIdentity = @import("live_slots.zig").LifecycleIdentity;
const LiveRequestSlot = @import("live_slots.zig").LiveRequestSlot;
const LiveSlotState = @import("live_slots.zig").LiveSlotState;
const CompletedRecord = @import("usage_records.zig").CompletedRecord;
const RECORD_RING_COUNT = @import("usage_records.zig").RECORD_RING_COUNT;

/// The lifecycle header's two tags, loaded once each and kept raw.
pub const LifecycleSnapshot = struct {
    state: u32,
    termination_reason: u32,

    /// Loads `state` and then `termination_reason`, each once with acquire
    /// ordering. The worker stores the reason first
    /// (`WorkerWriterView.setState`), so the reason this load sees was stored
    /// with the state it sees, or after it.
    pub fn load(header: *const Header) LifecycleSnapshot {
        const state = @atomicLoad(u32, &header.state, .acquire);
        const termination_reason = @atomicLoad(u32, &header.termination_reason, .acquire);
        return .{ .state = state, .termination_reason = termination_reason };
    }

    /// The state, or null for a value `State` does not name.
    pub fn knownState(self: LifecycleSnapshot) ?State {
        return std.enums.fromInt(State, self.state);
    }

    /// The termination reason, or null for a value `TerminationReason` does
    /// not name.
    pub fn knownTerminationReason(self: LifecycleSnapshot) ?TerminationReason {
        return std.enums.fromInt(TerminationReason, self.termination_reason);
    }
};

/// One live slot with each field loaded once. `state` stays the raw value
/// the page holds, so a value outside `LiveSlotState` reads as inactive.
pub const LiveSlotSnapshot = struct {
    state: u32,
    generation: u64,
    request_id: u64,
    request_generation: u64,
    worker_id: u64,
    worker_generation: u64,
    request_slot: u32,
    request_lane_id: u16,
    started_mono_ns: u64,
    cpu_time_ns: u64,

    /// Loads `state` first, with acquire ordering, then every other field
    /// once. The worker stores `state` last when it claims a slot
    /// (`WorkState.allocateLiveSlot` in `metrics.zig`), so an active copy
    /// holds that claim's fields or later ones; `matches` checks the copy's
    /// identity either way.
    pub fn load(slot: *const LiveRequestSlot) LiveSlotSnapshot {
        const state = @atomicLoad(u32, &slot.state, .acquire);
        return .{
            .state = state,
            .generation = @atomicLoad(u64, &slot.generation, .monotonic),
            .request_id = @atomicLoad(u64, &slot.request_id, .monotonic),
            .request_generation = @atomicLoad(u64, &slot.request_generation, .monotonic),
            .worker_id = @atomicLoad(u64, &slot.worker_id, .monotonic),
            .worker_generation = @atomicLoad(u64, &slot.worker_generation, .monotonic),
            .request_slot = @atomicLoad(u32, &slot.request_slot, .monotonic),
            .request_lane_id = @atomicLoad(u16, &slot.request_lane_id, .monotonic),
            .started_mono_ns = @atomicLoad(u64, &slot.started_mono_ns, .monotonic),
            .cpu_time_ns = @atomicLoad(u64, &slot.cpu_time_ns, .monotonic),
        };
    }

    pub fn isActive(self: *const LiveSlotSnapshot) bool {
        return self.state == @intFromEnum(LiveSlotState.active);
    }

    /// Whether the copy is an active slot that holds the request `identity`
    /// names. Every identity field takes part except `billing_sequence`.
    pub fn matches(self: *const LiveSlotSnapshot, identity: LifecycleIdentity) bool {
        if (!self.isActive())
            return false;
        if (self.request_id != identity.external_request_id)
            return false;
        if (self.request_lane_id != identity.request_lane_id)
            return false;
        if (self.request_slot != identity.request_slot)
            return false;
        if (self.request_generation != identity.request_generation)
            return false;
        if (self.worker_id != identity.worker_id)
            return false;
        return self.worker_generation == identity.worker_generation;
    }

    /// The copy of the first slot in `slots` that matches `identity`, or
    /// null when none does. Each slot is loaded once, and the copy returned
    /// is the one the match ran on.
    pub fn find(slots: []const LiveRequestSlot, identity: LifecycleIdentity) ?LiveSlotSnapshot {
        for (slots) |*slot| {
            const snapshot = load(slot);
            if (snapshot.matches(identity))
                return snapshot;
        }
        return null;
    }
};

/// The host's cursor of the usage record ring. The worker moves the page's
/// `records_head` past each record it appends; the host's tail lives here,
/// moves only in `advance`, and reaches the page's `records_tail` as a store
/// the host never loads back, so a worker that rewrites `records_tail` only
/// misleads its own room check.
pub const RecordCursor = struct {
    /// The ring position of the next record the host takes.
    tail: u64 = 0,

    /// What one peek saw: the records between the host's tail and the
    /// worker's head as the peek loaded it.
    pub const Peeked = struct {
        tail: u64,
        /// At most `RECORD_RING_COUNT`.
        count: u64,

        /// Copies the records of this peek from `skip` records past its tail
        /// into `out`, each field loaded once, and returns how many it
        /// copied: as many as fit, none when `skip` reaches `count`. `records`
        /// is the page's ring.
        pub fn copy(self: Peeked, records: []const CompletedRecord, skip: u64, out: []CompletedRecord) usize {
            std.debug.assert(records.len == RECORD_RING_COUNT);
            std.debug.assert(self.count <= RECORD_RING_COUNT);
            if (skip >= self.count)
                return 0;
            const available: usize = @intCast(self.count - skip);
            const copied = @min(out.len, available);
            var position = self.tail +% skip;
            for (out[0..copied]) |*record| {
                const index: usize = @intCast(position % RECORD_RING_COUNT);
                record.* = loadCompletedRecord(&records[index]);
                position +%= 1;
            }
            return copied;
        }
    };

    /// Loads the worker's `records_head` once. Null when the head stands
    /// behind the host's tail or more than `RECORD_RING_COUNT` records past
    /// it: no append puts it there, so the worker broke the ring's protocol.
    pub fn peek(self: *const RecordCursor, header: *const Header) ?Peeked {
        const head = @atomicLoad(u64, &header.records_head, .acquire);
        const count = head -% self.tail;
        if (count > RECORD_RING_COUNT)
            return null;
        return .{ .tail = self.tail, .count = count };
    }

    /// Consumes the first `count` records of `peeked`, which must be this
    /// cursor's latest peek: moves the tail past them and stores it to the
    /// page's `records_tail`, where the worker's room check reads it. The new
    /// tail comes from `peeked` alone, so a head the worker moves after the
    /// peek changes nothing here, and the next peek finds the contradiction.
    pub fn advance(self: *RecordCursor, header: *Header, peeked: Peeked, count: u64) void {
        std.debug.assert(peeked.tail == self.tail);
        std.debug.assert(count <= peeked.count);
        if (count == 0)
            return;
        self.tail = peeked.tail +% count;
        @atomicStore(u64, &header.records_tail, self.tail, .release);
    }

    /// Peeks, copies up to `out.len` records and consumes them. Returns how
    /// many it took, or null for a corrupt ring (`peek`), which it leaves
    /// untouched.
    pub fn drain(self: *RecordCursor, header: *Header, records: []const CompletedRecord, out: []CompletedRecord) ?usize {
        const peeked = self.peek(header) orelse return null;
        const copied = peeked.copy(records, 0, out);
        self.advance(header, peeked, copied);
        return copied;
    }
};

fn loadCompletedRecord(src: *const CompletedRecord) CompletedRecord {
    return .{
        .request_id = @atomicLoad(u64, &src.request_id, .monotonic),
        .request_generation = @atomicLoad(u64, &src.request_generation, .monotonic),
        .worker_id = @atomicLoad(u64, &src.worker_id, .monotonic),
        .worker_generation = @atomicLoad(u64, &src.worker_generation, .monotonic),
        .started_mono_ns = @atomicLoad(u64, &src.started_mono_ns, .monotonic),
        .finished_mono_ns = @atomicLoad(u64, &src.finished_mono_ns, .monotonic),
        .cpu_time_ns = @atomicLoad(u64, &src.cpu_time_ns, .monotonic),
        .io_time_ns = @atomicLoad(u64, &src.io_time_ns, .monotonic),
        .waiting_ns = @atomicLoad(u64, &src.waiting_ns, .monotonic),
        .queued_ns = @atomicLoad(u64, &src.queued_ns, .monotonic),
        .max_turn_ns = @atomicLoad(u64, &src.max_turn_ns, .monotonic),
        .turn_cpu_ns = @atomicLoad(u64, &src.turn_cpu_ns, .monotonic),
        .client_served_bytes = @atomicLoad(u64, &src.client_served_bytes, .monotonic),
        .fetch_billed_sent_bytes = @atomicLoad(u64, &src.fetch_billed_sent_bytes, .monotonic),
        .fetch_billed_received_bytes = @atomicLoad(u64, &src.fetch_billed_received_bytes, .monotonic),
        .fetch_cost_bytes = @atomicLoad(u64, &src.fetch_cost_bytes, .monotonic),
        .billing_sequence = @atomicLoad(u64, &src.billing_sequence, .monotonic),
        .request_slot = @atomicLoad(u32, &src.request_slot, .monotonic),
        .request_lane_id = @atomicLoad(u16, &src.request_lane_id, .monotonic),
        ._reserved1 = @atomicLoad(u16, &src._reserved1, .monotonic),
        .status = @atomicLoad(u32, &src.status, .monotonic),
        .flags = @atomicLoad(u32, &src.flags, .monotonic),
    };
}

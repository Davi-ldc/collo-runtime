//! The copies the host takes of two sections a worker writes on its page:
//! the lifecycle header with its owner section, and the live slots. The host
//! takes them through its `HostReaderView` (`mapping.zig`), which gives it no
//! other way to those sections.
//!
//! The worker can rewrite any byte of its page at any moment, so two loads
//! of one field can disagree, and a check made on the first says nothing
//! about the second. Each type here therefore loads every field it needs
//! once, with one atomic load per field, into a private copy; the caller
//! validates that copy and uses only the copy. A tag stays the raw integer
//! the page holds: it is compared with the value it should have, or
//! converted with `std.enums.fromInt`, which yields null for a value its
//! enum does not name, and never with `@enumFromInt`. The console ring keeps
//! the same rule inside its drain (`console_ring.zig`), with the host's
//! cursor in host memory, and the boot stamps and the benchmark record are
//! diagnostics loaded once each (`boot_stamps.zig`).
//!
//! A copy that passes its checks is still the worker's claim. A live slot
//! that matches the identity of a request the host sent to that worker
//! reports CPU that reaches only that worker's records; the same holds for
//! the owner section's deadline and CPU.

const std = @import("std");

const Header = @import("lifecycle.zig").Header;
const State = @import("lifecycle.zig").State;
const TerminationReason = @import("lifecycle.zig").TerminationReason;
const LIVE_SLOT_COUNT = @import("live_slots.zig").LIVE_SLOT_COUNT;
const LiveRequestSlot = @import("live_slots.zig").LiveRequestSlot;
const Page = @import("mapping.zig").Page;

/// The lifecycle header's two tags and its startup-end flag, each loaded
/// once and kept raw.
pub const LifecycleSnapshot = struct {
    state: u32,
    termination_reason: u32,
    startup_evaluations_ended: u32,

    /// Loads `state`, then `termination_reason`, then the startup-end flag,
    /// each once with acquire ordering. The worker stores the reason first
    /// (`WorkerWriterView.setState`), so the reason this load sees was stored
    /// with the state it sees, or after it.
    pub fn load(header: *const Header) LifecycleSnapshot {
        const state = @atomicLoad(u32, &header.state, .acquire);
        const termination_reason = @atomicLoad(u32, &header.termination_reason, .acquire);
        return .{
            .state = state,
            .termination_reason = termination_reason,
            .startup_evaluations_ended = @atomicLoad(u32, &header.startup_evaluations_ended, .acquire),
        };
    }

    /// Whether the startup-end flag is 1; any other value is no end.
    pub fn startupEnded(self: LifecycleSnapshot) bool {
        return self.startup_evaluations_ended == 1;
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

/// The owner the worker's VM thread works for, as it last published it
/// (`WorkerWriterView.publishOwner`), each field loaded once. The two are
/// stored one after the other, so a load during an owner change may pair one
/// owner's id with the other's deadline: the deadline is the value to act
/// on, and the id only names an owner in the host's log.
pub const OwnerSnapshot = struct {
    owner_id: u64,
    /// CLOCK_MONOTONIC; 0 while the VM thread works for no owner.
    deadline_mono_ns: u64,

    pub fn load(header: *const Header) OwnerSnapshot {
        const owner_id = @atomicLoad(u64, &header.owner_id, .acquire);
        const deadline_mono_ns = @atomicLoad(u64, &header.owner_deadline_mono_ns, .acquire);
        return .{ .owner_id = owner_id, .deadline_mono_ns = deadline_mono_ns };
    }
};

/// The CPU of the owner the worker's sentinel watches, as the sentinel last
/// read it (`WorkerWriterView.publishRunningOwnerCpu`), both values from one
/// store of the pair.
pub const RunningOwnerSnapshot = struct {
    owner_id: u64,
    cpu_ns: u64,

    /// The pair, or null when the sentinel was storing it during the load,
    /// when the sequence moved between the loads or when no owner was ever
    /// stored. One attempt, no retry: a worker that keeps its sequence moving
    /// only loses its own CPU from a record.
    pub fn load(header: *const Header) ?RunningOwnerSnapshot {
        const before = @atomicLoad(u32, &header.running_owner_sequence, .acquire);
        if (before & 1 != 0)
            return null;
        // Acquire keeps the second load of the sequence after both values.
        const owner_id = @atomicLoad(u64, &header.running_owner_id, .acquire);
        const cpu_ns = @atomicLoad(u64, &header.running_owner_cpu_ns, .acquire);
        const after = @atomicLoad(u32, &header.running_owner_sequence, .monotonic);
        if (after != before)
            return null;
        if (owner_id == 0)
            return null;
        return .{ .owner_id = owner_id, .cpu_ns = cpu_ns };
    }
};

/// One live slot with each field loaded once.
pub const LiveSlotSnapshot = struct {
    request_id: u64,
    request_generation: u64,
    cpu_ns: u64,

    /// Loads the live slot at `index`, the pool slot the host dispatched a
    /// request on, so below `LIVE_SLOT_COUNT`: the request's identity first,
    /// then its CPU, each once with acquire ordering. The worker's begin
    /// stores them in the reverse order with release ordering
    /// (`WorkerWriterView.beginLiveSlot`). The copy is exact for the request
    /// that holds the pool slot while the host reads: a copy with that
    /// request's identity holds its CPU or a later store of it, never an
    /// earlier request's. That rests on the caller, which reads a request's
    /// slot before it gives the pool slot back, so no later begin runs
    /// during the read (`server/supervisor/worker_table.zig:Record.usageFloor`);
    /// a load racing a begin could pair the older identity with the newer
    /// request's CPU.
    pub fn at(page: *const Page, index: usize) LiveSlotSnapshot {
        std.debug.assert(index < LIVE_SLOT_COUNT);
        const slot: *const LiveRequestSlot = &page.live_slots[index];
        const request_id = @atomicLoad(u64, &slot.request_id, .acquire);
        const request_generation = @atomicLoad(u64, &slot.request_generation, .acquire);
        return .{
            .request_id = request_id,
            .request_generation = request_generation,
            .cpu_ns = @atomicLoad(u64, &slot.cpu_ns, .acquire),
        };
    }

    /// Whether the copy holds the request the host knows by `request_id` and
    /// `request_generation`; a slot that an earlier or a later request of the
    /// same pool slot holds does not match, nor does one no request ever
    /// held, since the host's request ids are never 0.
    pub fn matches(self: *const LiveSlotSnapshot, request_id: u64, request_generation: u64) bool {
        std.debug.assert(request_id != 0);
        if (self.request_id != request_id)
            return false;
        return self.request_generation == request_generation;
    }
};

//! The page's lifecycle header and the tags it stores. The host writes the
//! header whole at launch; afterwards each field has one writer thread in the
//! worker, named on the field. The sentinel thread stores `state` and
//! `termination_reason` only right before it ends the process. A host reader
//! loads the tags once through `LifecycleSnapshot` and the owner section
//! through `OwnerSnapshot` and `RunningOwnerSnapshot` (`snapshots.zig`),
//! which keep each value raw and convert a tag only when its enum names it.

const std = @import("std");

pub const State = enum(u32) {
    forked = 1,
    ready = 2,
    dead = 3,
};

pub const TerminationReason = enum(u32) {
    none = 0,
    cpu = 1,
    memory = 2,
    crash = 3,
    init_failed = 4,
    deadline = 5,
    /// The sentinel thread could no longer watch the worker, its poll, its
    /// command descriptor, the memory events or the VM thread's CPU clock
    /// having failed, and ended the process: a worker it cannot stop is
    /// outside the bounds the server relies on.
    sentinel = 6,
};

/// The lifecycle header. The host writes it whole at launch
/// (`WorkerWriterView.initializeCrashDefault`).
///
/// `records_head` is the worker's cursor of the usage record ring, and
/// `records_tail` the copy of the host's cursor that the host stores for the
/// worker's room check and never reads back (`RecordCursor` in
/// `snapshots.zig`).
///
/// The owner section says whom the worker's VM thread works for. The VM
/// thread stores `owner_id` and `owner_deadline_mono_ns` at every owner
/// change (`WorkerWriterView.publishOwner`), 0 and 0 while it works for no
/// owner; the server compares the deadline with its own clock to find a
/// worker whose sentinel failed to stop an owner past it. The sentinel
/// stores `running_owner_id` and `running_owner_cpu_ns`, the CPU the owner
/// it watches has used, from its own thread whenever it reads that clock,
/// so a request that dies inside a window still has the CPU of that window
/// (`WorkerWriterView.publishRunningOwnerCpu`); `running_owner_sequence`
/// brackets the pair, so a host load takes both from one store. Every value
/// in the section is the worker's claim.
pub const Header = extern struct {
    version: u32,
    /// VM thread, and the sentinel right before it ends the process.
    state: u32,
    /// Stored with `state` by the same writer, before it.
    termination_reason: u32,
    /// Sentinel thread. Odd while it stores the running owner's pair.
    running_owner_sequence: u32,
    /// VM thread.
    records_head: u64,
    /// Host.
    records_tail: u64,
    /// VM thread.
    owner_id: u64,
    /// VM thread. CLOCK_MONOTONIC; 0 for none.
    owner_deadline_mono_ns: u64,
    /// Sentinel thread; 0 before it read any owner's CPU.
    running_owner_id: u64,
    /// Sentinel thread.
    running_owner_cpu_ns: u64,
};

comptime {
    if (@sizeOf(Header) != 64)
        @compileError("worker_state.page.Header size mismatch");
    if (@offsetOf(Header, "records_head") != 16)
        @compileError("worker_state.page.Header records_head offset mismatch");
    if (@offsetOf(Header, "owner_id") != 32)
        @compileError("worker_state.page.Header owner_id offset mismatch");
    if (@offsetOf(Header, "running_owner_id") != 48)
        @compileError("worker_state.page.Header running_owner_id offset mismatch");

    const zero_header = std.mem.zeroes(Header);
    if (zero_header.records_head != 0 or
        zero_header.records_tail != 0)
    {
        @compileError("worker_state.page zero-filled record cursors must describe an empty ring");
    }
    if (zero_header.owner_id != 0 or
        zero_header.owner_deadline_mono_ns != 0 or
        zero_header.running_owner_sequence != 0 or
        zero_header.running_owner_id != 0)
    {
        @compileError("worker_state.page zero-filled owner section must name no owner");
    }
}

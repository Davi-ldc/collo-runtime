//! The page's lifecycle header and the tags it stores. `createMemfd` writes
//! the header whole (`mapping.zig`); afterwards each field has one writer
//! thread in the worker, named on the field. The sentinel thread stores
//! `state` and `termination_reason` only right before it ends the process.
//! The boot's own failure path writes no field and reports in
//! `WorkerInitFailed`, but the sentinel starts before the routes evaluate,
//! so it can still stamp `dead` with `memory` or `sentinel` during the boot,
//! which `host/launch.zig:Machine.endedCause` reads, and the VM thread
//! publishes the owner section during the boot's evaluations. A host reader
//! loads the tags once through `LifecycleSnapshot` and the owner section
//! through `OwnerSnapshot` and `RunningOwnerSnapshot` (`snapshots.zig`),
//! which keep each value raw and convert a tag only when its enum names it.

const std = @import("std");

pub const State = enum(u32) {
    forked = 1,
    ready = 2,
    dead = 3,
};

/// Value 4 names no reason, and a host reader takes it as unknown
/// (`LifecycleSnapshot.knownTerminationReason`).
pub const TerminationReason = enum(u32) {
    none = 0,
    cpu = 1,
    memory = 2,
    crash = 3,
    deadline = 5,
    /// The sentinel thread could no longer watch the worker, its poll, its
    /// command descriptor, the memory events or the VM thread's CPU clock
    /// having failed, and ended the process: a worker it cannot stop is
    /// outside the bounds the server relies on.
    sentinel = 6,
};

/// The lifecycle header. `createMemfd` writes it whole, state `forked` and
/// reason `crash`, so a worker that dies before it stores a state of its own
/// reads as crashed.
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
    owner_id: u64,
    /// VM thread. CLOCK_MONOTONIC; 0 for none.
    owner_deadline_mono_ns: u64,
    /// Sentinel thread; 0 before it read any owner's CPU.
    running_owner_id: u64,
    /// Sentinel thread.
    running_owner_cpu_ns: u64,
    /// VM thread. 1 once the worker's startup evaluations all ended
    /// (`worker/runtime/evaluations.zig`), 0 before. The host may end the
    /// boot token early on 1; no value extends the token's deadline.
    startup_evaluations_ended: u32,
    _reserved0: u32,
};

comptime {
    if (@sizeOf(Header) != 56)
        @compileError("worker_state.page.Header size mismatch");
    if (@offsetOf(Header, "owner_id") != 16)
        @compileError("worker_state.page.Header owner_id offset mismatch");
    if (@offsetOf(Header, "running_owner_id") != 32)
        @compileError("worker_state.page.Header running_owner_id offset mismatch");
    if (@offsetOf(Header, "startup_evaluations_ended") != 48 or
        @offsetOf(Header, "_reserved0") != 52)
        @compileError("worker_state.page.Header startup end offset mismatch");

    const zero_header = std.mem.zeroes(Header);
    if (zero_header.owner_id != 0 or
        zero_header.owner_deadline_mono_ns != 0 or
        zero_header.running_owner_sequence != 0 or
        zero_header.running_owner_id != 0)
    {
        @compileError("worker_state.page zero-filled owner section must name no owner");
    }
}

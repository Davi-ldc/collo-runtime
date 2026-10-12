//! The live slots, one per request a worker can have in flight. The worker's
//! VM thread claims, updates and frees a slot through `WorkState` in
//! `metrics.zig`, which publishes a claim by storing `state` last. Every
//! field is the worker's claim to the host, which reads a slot only through
//! `LiveSlotSnapshot` (`snapshots.zig`): one copy of the slot, its state
//! compared as the raw integer it is.

const std = @import("std");
const limits = @import("collo_limits");

/// Requests a worker can have in flight at once, one live slot each: the
/// largest `concurrency` a definition may set, whatever the worker's own
/// definition sets, so every worker's page has one layout.
pub const LIVE_SLOT_COUNT: usize = limits.server.worker_concurrency_max;

pub const LiveSlotState = enum(u32) {
    empty = 0,
    active = 1,
};

/// One request in flight on the worker, written when it starts and cleared
/// when it finishes. The host reads it when it ends a request the worker did
/// not complete, for the CPU the request used until then.
pub const LiveRequestSlot = extern struct {
    generation: u64,
    request_id: u64,
    request_generation: u64 = 0,
    worker_id: u64 = 0,
    worker_generation: u64 = 0,
    /// The request's CPU so far (`cpu_ns` of `CompletedRecord` in
    /// `usage_records.zig`), as the VM thread last published it between the
    /// request's owner windows.
    cpu_ns: u64,
    request_slot: u32 = 0,
    request_lane_id: u16 = 0,
    _reserved1: u16 = 0,
    state: u32,
    _reserved2: u32 = 0,
};

/// The identity of one dispatched request on one worker, as the worker
/// copies it into a live slot and the host matches a slot against it.
pub const LifecycleIdentity = struct {
    external_request_id: u64,
    request_lane_id: u16,
    request_slot: u32,
    request_generation: u64,
    worker_id: u64,
    worker_generation: u64,
};

comptime {
    if (@sizeOf(LiveRequestSlot) != 64)
        @compileError("worker_state.page.LiveRequestSlot size mismatch");
    if (@offsetOf(LiveRequestSlot, "cpu_ns") != 40)
        @compileError("worker_state.page.LiveRequestSlot cpu_ns offset mismatch");
    if (@offsetOf(LiveRequestSlot, "state") != 56)
        @compileError("worker_state.page.LiveRequestSlot state offset mismatch");
    if (@intFromEnum(LiveSlotState.empty) != 0)
        @compileError("worker_state.page zero-filled live slots must be empty");

    const zero_slot = std.mem.zeroes(LiveRequestSlot);
    if (zero_slot.generation != 0 or
        zero_slot.request_id != 0 or
        zero_slot.request_generation != 0 or
        zero_slot.worker_id != 0 or
        zero_slot.worker_generation != 0 or
        zero_slot.cpu_ns != 0 or
        zero_slot.request_slot != 0 or
        zero_slot.request_lane_id != 0 or
        zero_slot._reserved1 != 0 or
        zero_slot.state != @intFromEnum(LiveSlotState.empty) or
        zero_slot._reserved2 != 0)
    {
        @compileError("worker_state.page zero-filled LiveRequestSlot is not a valid empty slot");
    }
}

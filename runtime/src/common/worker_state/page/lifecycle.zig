//! The page's lifecycle header and the tags it stores. The worker stores
//! `state` and `termination_reason` from its VM thread, and its sentinel
//! thread stores them right before it ends the process under memory
//! pressure; the sentinel writes nothing else on the page. A host reader
//! loads both once through `LifecycleSnapshot` (`snapshots.zig`), which
//! keeps them raw and converts each only when its enum names the value.

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
};

/// The lifecycle header. The host writes it whole at launch
/// (`WorkerWriterView.initializeCrashDefault`); afterwards the worker stores
/// `state` and `termination_reason`. `records_head` is the worker's cursor of
/// the usage record ring, and `records_tail` the copy of the host's cursor
/// that the host stores for the worker's room check and never reads back
/// (`RecordCursor` in `snapshots.zig`).
pub const Header = extern struct {
    version: u32,
    pid: u32,
    state: u32,
    termination_reason: u32,
    memory_limit_bytes: u64,
    worker_started_mono_ns: u64,
    metrics_dropped_count: u64,
    records_head: u64,
    records_tail: u64,
    _reserved0: u64,
};

comptime {
    const zero_header = std.mem.zeroes(Header);
    if (zero_header.metrics_dropped_count != 0 or
        zero_header.records_head != 0 or
        zero_header.records_tail != 0)
    {
        @compileError("worker_state.page zero-filled record counters must describe an empty ring");
    }
}

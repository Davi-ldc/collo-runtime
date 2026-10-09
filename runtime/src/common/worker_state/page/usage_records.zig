//! The usage record ring: what each finished request measured, appended by
//! the worker's VM thread through `WorkState` in `metrics.zig` and drained by
//! the host, one drain at a time, through `RecordCursor` (`snapshots.zig`).
//! The worker moves the header's `records_head` past each record it appends.
//! The host keeps its own tail, refuses a head more than `RECORD_RING_COUNT`
//! records past it or behind it, and stores each move to `records_tail` for
//! the worker's room check without reading it back.

/// Usage records the worker can publish ahead of the host's drain; a full
/// ring stops the worker (`WorkState.appendCompletedRecord`).
pub const RECORD_RING_COUNT: usize = 1024;

pub const CompletedStatus = enum(u32) {
    done = 0,
    cpu = 1,
    memory = 2,
    deadline = 3,
    crash = 4,
    bad_request = 5,
    js_exception = 6,
    internal_error = 7,
    client_closed = 8,
};

/// What one finished request measured, as the worker appends it to the usage
/// record ring before it publishes the request's completion. Every identity
/// field is the worker's claim, which the host checks against its own
/// records before it writes anything under it.
pub const CompletedRecord = extern struct {
    request_id: u64,
    request_generation: u64 = 0,
    worker_id: u64 = 0,
    worker_generation: u64 = 0,
    started_mono_ns: u64,
    finished_mono_ns: u64,
    /// The worker process's CPU time since its previous record, as the
    /// CLOCK_PROCESS_CPUTIME_ID delta. It includes collection, compilation,
    /// crypto and wasm work, and a worker's first record includes its module
    /// evaluation. `turn_cpu_ns` holds the request's own turns.
    cpu_time_ns: u64,
    io_time_ns: u64,
    /// Time the request was runnable but not executing, the interference part
    /// of wall time = execution + waiting + I/O. Disjoint from `io_time_ns`,
    /// since a request is in one state at a time.
    waiting_ns: u64 = 0,
    /// Sum of the ready-queue waits of the request's work items, the delay
    /// other requests on the worker added. Items queued at once overlap, so
    /// this is not a part of wall time; `waiting_ns` is.
    queued_ns: u64 = 0,
    /// Longest event-loop turn the request ran, the head-of-line blocking it
    /// caused the worker's other requests.
    max_turn_ns: u64 = 0,
    /// CPU time of the request's own event-loop turns
    /// (CLOCK_THREAD_CPUTIME_ID, folded at each turn's exit); the usage
    /// record carries `cpu_time_ns`.
    turn_cpu_ns: u64 = 0,
    /// Byte meters: bytes served to the request's client, outbound fetch
    /// payload bytes per direction, and outbound fetch bytes on the wire with
    /// TLS framing. All four stay zero on a record the host synthesizes for a
    /// worker that died.
    client_served_bytes: u64 = 0,
    fetch_billed_sent_bytes: u64 = 0,
    fetch_billed_received_bytes: u64 = 0,
    fetch_cost_bytes: u64 = 0,
    billing_sequence: u64 = 0,
    request_slot: u32 = 0,
    request_lane_id: u16 = 0,
    _reserved1: u16 = 0,
    status: u32,
    /// Bits of `CompletedRecordFlags`; every other bit is reserved and must stay zero.
    flags: u32,
};

/// The host's accounting flags, which the worker echoes from the dispatch.
pub const CompletedRecordFlags = struct {
    /// The dispatch launched a worker for this request.
    pub const cold_start: u32 = 1 << 0;
};

pub fn completedRecordHasFlag(record: CompletedRecord, flag: u32) bool {
    return (record.flags & flag) != 0;
}

comptime {
    if (@sizeOf(CompletedRecord) != 152)
        @compileError("worker_state.page.CompletedRecord size mismatch");
    if (@intFromEnum(CompletedStatus.done) != 0)
        @compileError("worker_state.page zero-filled completed records must decode as done if inspected");
}

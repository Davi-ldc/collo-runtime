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

/// How a request ended, in the vocabulary of the usage and access records'
/// `error_code`.
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
    /// The request reached a worker that had asked to be retired, which ran
    /// none of its JavaScript.
    worker_retiring = 9,
    /// A termination another owner of the worker's VM caused stopped the
    /// request.
    worker_stopped = 10,
};

/// What one finished request measured, as the worker appends it to the usage
/// record ring before it publishes the request's completion. The request key
/// (`request_id`, `request_generation`, `request_slot`, `request_lane_id`) is
/// the worker's claim, which the host checks against its own records before
/// it writes anything under it; the times of the request's life and its
/// cold-start flag are the server's own and never ride here.
///
/// `exec_ns`, `waiting_ns` and `io_ns` partition the worker's span of the
/// request, from the decode of its begin to its finish: running, runnable
/// but not running, and waiting on I/O. `cpu_ns` is the request's CPU: the
/// VM thread's while the request owns it, plus the crypto pool's on its jobs.
/// The byte meters carry the names the usage record's JSON gives them; all
/// four stay zero on a record the host writes for a request the worker could
/// not account for.
pub const CompletedRecord = extern struct {
    request_id: u64,
    request_generation: u64 = 0,
    exec_ns: u64 = 0,
    waiting_ns: u64 = 0,
    io_ns: u64 = 0,
    cpu_ns: u64 = 0,
    /// Bytes served to the request's client.
    client_served_bytes: u64 = 0,
    /// Outbound fetch payload bytes, per direction.
    fetch_sent_bytes: u64 = 0,
    fetch_received_bytes: u64 = 0,
    /// Outbound fetch bytes on the wire, TLS framing included.
    fetch_wire_bytes: u64 = 0,
    request_slot: u32 = 0,
    request_lane_id: u16 = 0,
    _reserved1: u16 = 0,
    /// `CompletedStatus`; the host reads a value outside it as
    /// `internal_error`.
    status: u32,
    _reserved2: u32 = 0,
};

/// The accounting flags the server stamps on a dispatch and keeps in its
/// request table (`Dispatched.accounting_flags` in
/// `server/supervisor/request_table.zig`).
pub const AccountingFlags = struct {
    /// The dispatch launched a worker for this request.
    pub const cold_start: u32 = 1 << 0;
};

comptime {
    if (@sizeOf(CompletedRecord) != 96)
        @compileError("worker_state.page.CompletedRecord size mismatch");
    if (@offsetOf(CompletedRecord, "client_served_bytes") != 48)
        @compileError("worker_state.page.CompletedRecord client_served_bytes offset mismatch");
    if (@offsetOf(CompletedRecord, "status") != 88)
        @compileError("worker_state.page.CompletedRecord status offset mismatch");
    if (@intFromEnum(CompletedStatus.done) != 0)
        @compileError("worker_state.page zero-filled completed records must decode as done if inspected");
}

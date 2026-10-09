//! The shape of one ingress lane of the server: the capacities of its
//! tables, what it buffers for a client before it can act on it, the
//! deadlines that end a connection that does not start, goes idle or stalls,
//! the batching of its io_uring, and how much of one worker's output may
//! wait in other lanes' queues. Each bound says what it protects. The lane's
//! tables fault in on first use, so a capacity here costs address space at
//! start and memory only as far as the lane has used it. It must import
//! nothing; `root.zig` says why.

/// Connections one lane holds at once. A connection slot costs about a
/// kilobyte once touched, so the bound protects the lane's share of the
/// process's descriptors and the walk of its slab at teardown, not its memory
/// at start. An accepted socket past it is closed at once.
pub const connections_per_lane_max: u32 = 4096;

/// Requests one lane holds at once, waiting for a worker or dispatched. A
/// stream past it is refused with REFUSED_STREAM, which the client may retry,
/// and the connection goes on.
pub const requests_per_lane_max: u32 = 4096;

/// HTTP/2 streams one lane holds at once across its connections, twice its
/// requests, since a stream also lives while its response drains after its
/// request ended. A stream past it is refused with REFUSED_STREAM, so a
/// connection that opens many streams costs only the streams it opens.
pub const streams_per_lane_max: u32 = 8192;

/// Concurrent streams of one connection, which the server advertises as
/// SETTINGS_MAX_CONCURRENT_STREAMS. A stream past it is refused with
/// REFUSED_STREAM. Each connection keeps one reference per stream, so the
/// bound also sizes the connection slot.
pub const streams_per_connection_max: u32 = 64;

/// Bytes of unfinished header blocks one lane holds across its connections.
/// A header block is the only client input the lane must hold whole before
/// it can act on it: DATA goes to its stream in pieces and every other frame
/// is short. Without this bound, every connection at the per-block bound
/// (`headers.INGRESS_H2_REQUEST_HEADER_BLOCK_BYTES`) would hold 128 MiB. The
/// connection whose append would pass it gets GOAWAY ENHANCE_YOUR_CALM and
/// closes; no other connection is touched.
pub const header_block_bytes_per_lane_max: usize = 8 * 1024 * 1024;

/// Frames of one header block, its HEADERS and CONTINUATION frames together,
/// so a client cannot keep the lane assembling a block of empty fragments.
/// Past it the connection gets GOAWAY ENHANCE_YOUR_CALM.
pub const header_block_frames_max: u32 = 128;

/// Frames one socket read may carry that cost the lane work without moving
/// a request forward: every frame but HEADERS and DATA, and DATA that is
/// empty or all padding. Past it the connection gets GOAWAY
/// ENHANCE_YOUR_CALM, so a flood costs the client its connection.
pub const budgeted_frames_per_read_max: u32 = 128;

/// How long an accepted connection may take to start its first request: the
/// TLS handshake, the client preface and the first stream's headers. It runs
/// from the accept and nothing extends it, so a client that sends bytes
/// without starting a request still loses its connection.
pub const pre_request_timeout_ns: u64 = 3 * 1_000_000_000;

/// How long a connection may stay open with no stream. Only a new stream
/// ends it: PING, SETTINGS and WINDOW_UPDATE keep no connection alive. At
/// expiry the lane queues GOAWAY NO_ERROR naming the last stream it
/// processed and closes once that is written, a write the stall deadline
/// bounds.
pub const idle_timeout_ns: u64 = 300 * 1_000_000_000;

/// How long a connection may go without a byte read or written while the
/// lane holds something of it that only the client can move: a partial frame
/// or header block, writes queued behind a full socket, or response bytes
/// held by flow control. At expiry the lane closes it without waiting for its
/// write queue.
pub const stall_timeout_ns: u64 = 10 * 1_000_000_000;

/// Submission queue entries of a lane's io_uring. A pass prepares its polls,
/// cancels and closes there and hands them to the kernel in the one
/// `io_uring_enter` that also waits, so the queue holds what one pass
/// prepares; a fuller pass submits early and counts it.
pub const ring_submission_entries: u16 = 256;

/// Completion queue entries of a lane's io_uring: room for a completion of
/// every poll a busy lane keeps armed, so the kernel rarely has to hold
/// completions on its overflow list.
pub const ring_completion_entries: u32 = 4096;

/// Ordinary places of a lane's command queue, which every command may fill.
/// The commands that discharge an obligation also have a reserve per worker
/// table entry (`server/ingress/lane.zig`, `obligationReserve`).
pub const commands_per_lane_max: u32 = 1024;

/// Commands of one worker's output that may wait in other lanes' queues at
/// once: the descriptors its reader forwards and the answers to their ring
/// payloads. The reader receives a packet of the worker only while a full
/// batch of descriptors still fits, so a worker that writes faster than the
/// lanes it answers can apply it waits in its own socket, and each lane
/// reserves this many places per worker table entry, so worker output never
/// takes an ordinary place of a queue.
pub const forwarded_commands_per_worker_max: u32 = 64;

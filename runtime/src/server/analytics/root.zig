//! The server's local analytics: worker console lines, one access record per
//! request the server answered or dispatched, one usage record per finished
//! request and one line per worker the server ended, appended as JSON Lines
//! to files in the analytics directory. Console lines also always go to
//! stderr, and without a directory they are the only output: every record is
//! counted as discarded.
//!
//! - `sink.zig`: the files and the console stream, their bounded buffers, the
//!   batched writes, the sync interval, the loss counters, the full flag a
//!   stream raises when it refuses a record, and the reopen a rotation asks
//!   for.
//! - `record.zig`: the identity, clock and JSON string encoding every record
//!   kind shares.
//! - `logs.zig`: console lines from a worker's log ring, and the final drain
//!   of a dying worker's ring.
//! - `access.zig`: access facts, access records and the lane handoff ring.
//! - `usage.zig`: the usage record and its line format.
//! - `workers.zig`: the worker line and its format.
//!
//! The server stamps every record's owner from its own tables: the worker, the
//! route pattern, and the worker process's id and generation. No record takes
//! its owner from bytes a worker wrote, which is how this module keeps the
//! invariant in `skills/runtime/references/main.md` that a worker cannot
//! choose whose record its measurements enter. Every access and usage record
//! carries a request id the server dispatched: a usage record the worker
//! measured (origin `worker`) is written only for a request the server's
//! table of that worker still expects a record for, under the table's id
//! (`server/supervisor/usage_drain.zig`). A console line keeps the request
//! id the worker wrote with it only when that worker's request table holds
//! the request or ended it recently, and prints that request's route
//! (`logs.zig`); any other id prints as 0. A worker can still file a line
//! under another of its own requests, but never under another worker's.
//!
//! The server owns the one `Sink` (`server/main.zig`). The ingress metrics
//! thread drains rings into it and flushes the record files, the ingress
//! console thread writes console lines to stderr, and worker teardown, the
//! usage drains and the lanes that write floor usage records append from
//! their own threads. `sink.zig` states the locking.

pub const sink = @import("sink.zig");
pub const record = @import("record.zig");
pub const logs = @import("logs.zig");
pub const access = @import("access.zig");
pub const usage = @import("usage.zig");
pub const workers = @import("workers.zig");

pub const Sink = sink.Sink;
pub const Stream = sink.Stream;
pub const Identity = record.Identity;
pub const Clock = record.Clock;

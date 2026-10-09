//! I/O building blocks shared by the ingress server, the gateway and the
//! worker. `buffer.zig` holds byte budgets and the stream buffer, `heap.zig`
//! the intrusive priority heap behind timer and deadline queues, `uring.zig` a
//! tagged io_uring wrapper for deadlines and readiness, and
//! `restricted_uring.zig` the worker's restricted ring plus the restriction
//! helpers the other sandboxed rings use. Every instance belongs to one
//! thread; the only process-wide state is `uring.zig`'s count of undecodable
//! completions. The module links no libc.

pub const heap = @import("heap.zig");
pub const buffer = @import("buffer.zig");
pub const uring = @import("uring.zig");
pub const restricted_uring = @import("restricted_uring.zig");

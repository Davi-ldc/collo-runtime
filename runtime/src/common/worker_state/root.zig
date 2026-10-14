//! A worker's shared state page, a memfd the host and the worker both map
//! read-write. The worker writes it, and every byte the host reads from it is
//! hostile input; `page.zig` states who writes what and how a host reader
//! must treat it.
//!
//! - `page.zig`, with one file per section under `page/`: the lifecycle
//!   header, the live slots, the console ring, the boot phase stamps and the
//!   benchmark record, the host's snapshots of what the worker writes, and
//!   the page's layout, creation and mapping. The worker maps it as a
//!   `WorkerWriterView`, through which it writes every section, and the host
//!   as a `HostReaderView`, which only reads.

pub const page = @import("page.zig");

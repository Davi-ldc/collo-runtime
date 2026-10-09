//! A worker's shared state page, a memfd the host and the worker both map
//! read-write. The worker writes it, and every byte the host reads from it is
//! hostile input; `page.zig` states who writes what and how a host reader
//! must treat it.
//!
//! - `page.zig`, with one file per section under `page/`: the lifecycle
//!   header, the layout of the live slots and the usage record ring, the
//!   completion and console rings, the boot phase stamps and the benchmark
//!   record, the host's snapshots of what the worker writes, and the page's
//!   layout, creation and mapping. The worker and the host both map it as a
//!   `WorkerWriterView`.
//! - `metrics.zig`: the worker's writes to the live slots and the usage
//!   record ring, through `WorkState`, and the death record the host builds
//!   from a live slot's snapshot.

pub const page = @import("page.zig");
pub const metrics = @import("metrics.zig");

//! Runtime limits, one file per domain. Each domain file is a leaf that
//! imports nothing, so any module can cite these without a layering cycle.
//! Moving a constant here never changes its value: where two modules hold
//! different (or coincidentally equal) numbers they get distinct names side
//! by side, and unifying the values is a separate decision.
//!
//! Index of the limit files outside this module, as pointers only. Most
//! live in modules that import this one, so importing them back would cycle;
//! fetch_limits' module does not, but pulling it in would break the leaf
//! design and give the file two homes:
//! - runtime/src/server/supervisor/scheduler_limits.zig — scheduler policy
//!   (memory ladder, pool capacity).
//! - runtime/src/egress/gateway/supervisor_limits.zig — shard
//!   containment (restart backstop, memory budget).
//! - runtime/src/common/ipc/fetch_limits.zig — fetch IPC wire shape
//!   (packet/url/header caps, 32 MiB pooled request-body ceiling).
//! - runtime/src/egress/gateway/policy.zig — per-fetch gateway policy
//!   defaults (cite http_body and fetch_limits).
//! - runtime/src/egress/gateway/sizing.zig — the gateway's worker cap
//!   and the descriptor budget that bounds it and the shard count; the
//!   gateway's resource limits are in process.zig here.
//! - runtime/src/server/analytics/sink.zig — analytics stream buffers, the
//!   console write batch and the sync interval; the record field caps they
//!   hold live in runtime_logs.zig.
//! - runtime/src/server/analytics/access.zig (`AccessRing.capacity`) and
//!   runtime/src/server/analytics/logs.zig (`drain_batch_lines`,
//!   `dying_ring_line_budget`) — the lane access handoff and the log ring
//!   drains.
//! - runtime/src/server/ingress/analytics_drain.zig — console lines drained
//!   per worker per metrics tick.
//! - runtime/src/server/supervisor/usage_log.zig (usage batch and
//!   synthesis reserve), usage_drain.zig (`write_outs_per_drain_max`) and
//!   request_table.zig (entries per worker) — the usage path.
//! - runtime/src/server/config/parse.zig (`KeyPath.depth_max`) and
//!   diagnostic.zig (`Diagnostic.message_bytes_max`) — reading the
//!   configuration; the bounds on what it declares are in server.zig here.
//! - runtime/src/server/routes/table.zig (`node_count_max`,
//!   `match_visits_max`) and imports.zig (`imports_max`, `nesting_max`) —
//!   the route trie and the scan of a module's imports.
//! - runtime/src/common/ipc/fs_index.zig (`path_bytes_max`, `entries_max`)
//!   and route_bindings.zig (`bytes_max`, `entries_max`, both equal to
//!   server.zig's per-route binding bounds) — the WorkerInit memfds.
//! Cross-domain relations between those centrals and these domain files are
//! comptime-asserted in runtime/tests/contracts/limits.zig, compiled by the
//! aggregate `zig build test` suite — drift is a compile error there.

pub const process = @import("process.zig");
pub const http_body = @import("http_body.zig");
pub const h2 = @import("h2.zig");
pub const headers = @import("headers.zig");
pub const ingress = @import("ingress.zig");
pub const worker = @import("worker.zig");
pub const runtime_logs = @import("runtime_logs.zig");
pub const fs_fault = @import("fs_fault.zig");
pub const server = @import("server.zig");
pub const pool = @import("pool.zig");

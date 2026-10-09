//! Budgets for faulting files of a worker's read-only file tree into its
//! tmpfs, read by the worker that copies them in. The host side has no file
//! source yet and answers every fault for an indexed path with a failure
//! (`server/ingress/runner/fs_fault_control.zig`). It must import nothing;
//! `root.zig` says why. Its relations to constants of other modules are
//! checked in `runtime/tests/contracts/limits.zig`.

/// Largest file a worker may fault in, equal to the default worker tmpfs
/// size, `WorkerInit.default_tmpfs_size_bytes` in `common/ipc/messages.zig`.
/// A larger file cannot fit a default-sized tmpfs, so every fault path
/// rejects it before a request leaves the worker, even on a worker whose
/// tmpfs was configured larger. Below it, `materialize_budget_percent` of the
/// worker's actual tmpfs is the limit. The C++ fs binding reads its own copy,
/// `COLLO_FS_FAULT_MAX_FILE_BYTES` in `bindings/include/collo/abi.h`, and no
/// build step compares the two, so a change here must change that header too.
pub const max_fault_file_bytes: u64 = 256 * 1024 * 1024;

/// How long a materialized file may go unread before the worker deletes its
/// tmpfs copy at the next idle sweep, freeing memory charged to the worker's
/// cgroup. The next read faults the file in again.
pub const materialized_idle_eviction_ns: u64 = 5 * 60 * 1_000_000_000;

/// Shortest time between two idle sweeps. The sweep runs when a request
/// finishes and walks the list of materialized files at most once per
/// interval, so most request finishes skip the walk.
pub const materialized_sweep_interval_ns: u64 = 30 * 1_000_000_000;

/// Share of the worker's tmpfs, in percent, that materialized files may
/// occupy (the tmpfs size comes from WorkerInit). Before copying a file in,
/// the worker evicts the least recently used ones until the new file fits
/// within that share, so materialized files cannot push the worker's own
/// /tmp writes into ENOSPC; a file larger than the whole share is rejected
/// before it is requested. No measurement has calibrated the value yet.
pub const materialize_budget_percent: u64 = 50;

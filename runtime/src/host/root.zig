//! The host side of the runtime's process contract.
//!
//! A host is whoever stands outside the sandbox and drives a zygote: it
//! prepares the cgroup leaf a worker is born into, forks the worker, hands
//! the child its WorkerInit table and waits for ready, dispatches requests
//! over the ingress channel, reads the responses, and tears the worker down.
//! The server that `collo serve` boots is one host; the test harnesses and
//! benchmarks are the others. Nothing here decides which route a request
//! takes, how the egress gateway works or how usage is recorded: a host
//! resolves those before it calls in.
//!
//! - `cgroup_root.zig`: the delegated cgroup subtree and each worker's leaf,
//!   named by the subtree and the fork job id (`WorkerLeaf`).
//! - `host_identity.zig`: the names a host claims in a parent other hosts
//!   share, and the proof that a host behind such a name is gone, which the
//!   boot sweep of the cgroup subtree uses.
//! - `launch.zig`: the WorkerInit handoff, from a forked child to a ready
//!   worker.
//! - `handle.zig`: a ready worker's descriptors and mappings.
//! - `dispatch.zig`: one request sent to a worker and its response read
//!   back, for harnesses and benchmarks.

pub const cgroup_root = @import("cgroup_root.zig");
pub const host_identity = @import("host_identity.zig");
pub const launch = @import("launch.zig");
pub const handle = @import("handle.zig");
pub const dispatch = @import("dispatch.zig");

pub const WorkerCgroupRoot = cgroup_root.WorkerCgroupRoot;
pub const WorkerLeaf = cgroup_root.WorkerLeaf;
pub const WorkerHandle = handle.WorkerHandle;
pub const LaunchOptions = launch.LaunchOptions;
pub const runToReady = launch.runToReady;

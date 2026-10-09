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
//! - `cgroup_root.zig`, `cgroup.zig`: the delegated cgroup subtree and each
//!   worker's leaf.
//! - `launch.zig`: the WorkerInit handoff, from a forked child to a ready
//!   worker.
//! - `handle.zig`: a ready worker's descriptors and mappings.
//! - `dispatch.zig`: one request sent to a worker and its response read
//!   back, for harnesses and benchmarks.

const std = @import("std");
const zygote = @import("collo_zygote");
const process = @import("collo_os").process;
const process_limits = @import("collo_limits").process;

pub const cgroup_root = @import("cgroup_root.zig");
pub const cgroup = @import("cgroup.zig");
pub const launch = @import("launch.zig");
pub const handle = @import("handle.zig");
pub const dispatch = @import("dispatch.zig");

pub const WorkerCgroupRoot = cgroup_root.WorkerCgroupRoot;
pub const WorkerHandle = handle.WorkerHandle;
pub const LaunchOptions = launch.LaunchOptions;
pub const runToReady = launch.runToReady;

/// Kills a forked worker that never reached a handle (no WorkerInit sent,
/// or an init that failed) and removes the cgroup leaf it was born into.
pub fn terminateForkedWorkerBestEffort(forked: *zygote.host_client.ForkedWorker) void {
    // The pidfd from the fork reply is the kernel-attested handle; the
    // numeric pid is subject to reuse once the auto-reaped child exits. A
    // ForkedWorker without one (test fixtures) has no process to kill.
    if (forked.pidfd) |pidfd| {
        process.pidFdSendSignal(pidfd, std.posix.SIG.KILL) catch |err| switch (err) {
            error.ProcessNotFound => {},
            else => std.log.warn("failed to terminate forked worker pid={d}: {s}", .{ forked.pid, @errorName(err) }),
        };
        // A still-listed member blocks the rmdir below; the reap retries
        // after cgroup.kill, so a failed wait only slows the cleanup.
        _ = process.waitForPidFdExit(pidfd, process_limits.PROCESS_EXIT_WAIT_MS) catch |err|
            std.log.debug("wait for worker exit before cgroup reap failed: {s}", .{@errorName(err)});
    }
    if (forked.cgroup_dir_fd) |dir_fd|
        cgroup_root.reapWorkerCgroupByFd(dir_fd);
    forked.deinit();
}

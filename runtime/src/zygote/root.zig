//! The zygote: one process that initializes and warms a JSC VM, then forks
//! every worker from it, so workers share its pages through copy-on-write.
//! Its code runs in three processes, one file each: `host_client.zig` in the
//! host, which spawns the zygote and asks it for forks; `fork_loop.zig` in
//! the zygote, from its launch to the loop that serves those forks; and
//! `child_boot.zig` in a worker child, from the clone through its boot to
//! its event loop. `worker_boot/` holds the cgroup checks the fork loop and
//! the child run and the sandbox the child applies, `trace.zig` the boot
//! trace pipe all three write to, `state.zig` the zygote's state and a
//! child's, and `warmup.zig` the corpus that fills shared engine state
//! before the first fork.

pub const host_client = @import("host_client.zig");
pub const fork_loop = @import("fork_loop.zig");
pub const child_boot = @import("child_boot.zig");
pub const trace = @import("trace.zig");
pub const state = @import("state.zig");
pub const warmup = @import("warmup.zig");
pub const ipc = @import("collo_ipc");
pub const worker = @import("collo_worker");
pub const worker_state = @import("collo_worker_state");

pub const process_name = fork_loop.process_name;

pub const worker_boot = struct {
    pub const cgroup = @import("worker_boot/cgroup.zig");
    pub const sandbox = @import("worker_boot/sandbox.zig");
};

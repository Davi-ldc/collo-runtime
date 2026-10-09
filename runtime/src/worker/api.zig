//! Module root of `collo_worker`: the runtime of one worker process, from
//! `initRuntime` to the end of its event loop. The zygote's worker child
//! builds and drives it (`zygote/child_boot.zig`).
//!
//! `runtime/` holds the `Runtime` and its state per domain; `scheduler/` the
//! event loop with its ready queue, timers, immediates and request
//! deadlines; `serve/` a request's run from its dispatch to its completed
//! record; `modules/` route pack registration and evaluation; `egress/`
//! fetches through the egress gateway; `fs/` the node:fs view of the
//! read-only file tree and its fault plane; `js/` the crypto pool and the
//! handler's `Request` and `Response`; `host/` the `collo_runtime_*`
//! functions the engine bridge calls on the runtime that
//! `Runtime.attachHostRuntime` installed. Request state and the JSC plumbing
//! are modules of their own that this one imports: `collo_worker_request`
//! (`request_api.zig`) and `collo_worker_js` (`js/jsc/root.zig`).
//!
//! Everything here belongs to the worker's VM thread, which runs the loop.
//! The crypto pool's threads run native jobs and hand each back to the VM
//! thread. The sentinel's thread can terminate the running JavaScript or end
//! the process, and touches no state the VM thread owns. Both start before
//! seccomp denies clone, as every worker thread must (`zygote/child_boot.zig`).
//!
//! Every eventfd, socket, timer and ring the runtime uses is created or
//! received before seccomp, which denies creating them; after it, files can
//! be opened only inside the chroot's tmpfs (`zygote/worker_boot/sandbox.zig`).
//! The worker ring registers several of them as fixed files without owning
//! them, and each is closed by the domain that created or received it.
//!
//! What each `collo_runtime_*` function does with the handles it receives is
//! stated in `abi.h`, or for the fs fault exports, which `fs.cpp` declares
//! itself, in `host/fs_fault.zig`: promise deferreds and values are consumed
//! on every call, while a crypto job passes to Zig only on success. Every
//! crypto job, fetch, fetch body and timer carries the id of the request that
//! started it, and the end of that request cancels or releases each one
//! (`cleanupRequestSubresources` in
//! `serve/response_finish.zig`, and `Runtime.closeBootContext` for the boot
//! context).

const std = @import("std");
const builtin = @import("builtin");
const bindings = @import("collo_bindings");
const worker_shared_page = @import("collo_worker_state").page;
const runtime_core = @import("runtime/root.zig");
const runtime_types = @import("runtime/types.zig");
const scheduler_loop = @import("scheduler/loop.zig");
const scheduler_queue = @import("scheduler/queue.zig");
const host_completion = @import("host/completion.zig");
const host_crypto = @import("host/crypto.zig");
const host_fetch = @import("host/fetch.zig");
const host_fs_fault = @import("host/fs_fault.zig");
const host_module_settlement = @import("host/module_settlement.zig");
const host_request_body = @import("host/request_body.zig");
const host_timers = @import("host/timers.zig");

/// The node:fs view of the worker's read-only file tree. The zygote's worker
/// child initializes it between the chroot and seccomp, and the C++ fs
/// binding calls it through the `collo_worker_fs_*` functions referenced
/// below.
pub const fs = @import("fs/index.zig");

pub const Clock = runtime_types.Clock;
pub const Runtime = runtime_core.Runtime;
pub const RuntimeLimits = runtime_types.RuntimeLimits;
pub const RuntimeOptions = runtime_types.RuntimeOptions;
/// The marks `zygote/child_boot.zig` stamps as boot phases inside the boot
/// evaluation (`modules/routes.zig` defines them).
pub const BootEvalMarks = @import("modules/routes.zig").BootEvalMarks;

/// Runs one work item as a turn, as the loop does (`scheduler/loop.zig`),
/// for a caller that drives the runtime without `run`.
pub fn executeWorkItem(runtime: *runtime_core.Runtime, item: scheduler_queue.WorkItem) !void {
    try scheduler_loop.executeWorkItem(runtime, item);
}

/// The internal files the worker suites reach through this module; empty
/// outside test builds.
pub const testing = if (builtin.is_test) struct {
    pub const request_dispatch = @import("serve/dispatch.zig");
    pub const module_routes = @import("modules/routes.zig");
    pub const response_finish = @import("serve/response_finish.zig");
    pub const response_payload_writer = @import("serve/response_payload_writer.zig");
    pub const process_cpu = @import("serve/process_cpu.zig");
    pub const sentinel = @import("runtime/sentinel.zig");

    pub const scheduler = struct {
        pub const loop = @import("scheduler/loop.zig");
        pub const queue = @import("scheduler/queue.zig");
        pub const immediates = @import("scheduler/immediates.zig");
        pub const timers = @import("scheduler/timers.zig");
        pub const uring_backend = @import("scheduler/uring_backend.zig");
    };

    pub fn executeWorkItem(runtime: *runtime_core.Runtime, item: scheduler.queue.WorkItem) !void {
        try scheduler.loop.executeWorkItem(runtime, item);
    }
} else struct {};

// The engine bridge calls these exports and no Zig code does, so they are
// referenced here: a file the compiler never analyzes emits none of its
// `export fn`s.
comptime {
    _ = host_completion.collo_runtime_complete_request_task;
    _ = host_crypto.collo_runtime_crypto_job_enqueue;
    _ = host_fetch.collo_runtime_fetch;
    _ = host_fetch.collo_runtime_fetch_cancel;
    _ = host_fetch.collo_runtime_fetch_body_consume;
    _ = host_fetch.collo_runtime_fetch_body_pull;
    _ = host_fetch.collo_runtime_fetch_body_borrow;
    _ = host_fetch.collo_runtime_fetch_body_clone;
    _ = host_fetch.collo_runtime_fetch_body_cancel;
    _ = host_fetch.collo_runtime_fetch_body_release;
    _ = host_fs_fault.collo_runtime_fs_fault_read_file;
    _ = host_fs_fault.collo_runtime_fs_fault_sync;
    _ = host_fs_fault.collo_runtime_fs_fault_hit_local;
    _ = host_module_settlement.collo_runtime_module_eval_settled;
    _ = host_request_body.collo_runtime_request_text;
    _ = host_request_body.collo_runtime_request_json;
    _ = host_request_body.collo_runtime_request_array_buffer;
    _ = host_request_body.collo_runtime_request_bytes;
    _ = host_request_body.collo_runtime_request_blob;
    _ = host_request_body.collo_runtime_request_form_data;
    _ = host_timers.collo_runtime_set_timer;
    _ = host_timers.collo_runtime_clear_timeout;
    _ = host_timers.collo_runtime_set_immediate;
    _ = host_timers.collo_runtime_clear_immediate;
    _ = fs.collo_worker_fs_route;
    _ = fs.collo_worker_fs_readdir_next;
}

/// Builds the runtime of one worker; `Runtime.init` says what it takes and
/// what stays the caller's. Once the result sits at its final address, the
/// caller sets up the worker ring, calls `attachHostRuntime` and starts the
/// sentinel, all before seccomp, as `zygote/child_boot.zig` does.
pub fn initRuntime(
    allocator: std.mem.Allocator,
    vm: *bindings.Vm,
    control_fd: ?std.posix.fd_t,
    metrics_view: *worker_shared_page.WorkerWriterView,
    completion_eventfd: std.posix.fd_t,
    options: runtime_types.RuntimeOptions,
) !runtime_core.Runtime {
    var runtime = try runtime_core.Runtime.init(allocator, vm, control_fd, metrics_view, completion_eventfd, options);
    errdefer runtime.deinit();
    return runtime;
}

/// Runs the event loop on the calling thread, the VM thread, until it stops
/// (`run` in `scheduler/loop.zig` says when and how it fails).
pub fn run(runtime: *runtime_core.Runtime) !void {
    try scheduler_loop.run(runtime);
}

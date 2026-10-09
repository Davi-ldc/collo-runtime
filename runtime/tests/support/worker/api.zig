//! Test access to the worker runtime's internals, module
//! `collo_worker_test_support`. It re-exports `collo_worker.testing`, which
//! `runtime/src/worker/api.zig` declares only in test builds, so a reference
//! to `sentinel` or `scheduler` compiles only inside a test compilation.
//! Production code imports `collo_worker` and never this module.

const worker = @import("collo_worker");

pub const RequestContext = @import("collo_worker_request").context.RequestContext;
pub const sentinel = worker.testing.sentinel;

pub const scheduler = worker.testing.scheduler;

/// Runs one work item on `runtime` as the worker's event loop would. Call it
/// on the thread that owns `runtime`.
pub fn executeWorkItem(runtime: *worker.Runtime, item: scheduler.queue.WorkItem) !void {
    try scheduler.loop.executeWorkItem(runtime, item);
}

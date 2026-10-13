//! What the worker's VM thread does once it has gone idle, between two of
//! the loop's blocked waits (`loop.zig`). After
//! `thread_cache_idle_release_ns` with no owner's work it releases its own
//! allocator cache, which libpas could otherwise reclaim only by
//! suspending it with a signal the seccomp filter denies. And once a
//! dispatched request has finished and the worker holds none, after
//! `idle_collection_delay_ns` with no owner's work it collects the whole
//! heap and hands the freed memory back to the kernel
//! (`collo_vm_collect_full_gc_and_trim` in `bindings/include/collo/abi.h`),
//! once per stretch between requests (`Requests.idle_collection_owed`). The
//! engine would never collect an idle worker on its own: its timer-driven
//! collections need the RunLoop a worker never runs, and its
//! allocation-paced ones wait for the next allocations. Both delays
//! count from the end of the last owner window (`Owners.idle_since_mono_ns`),
//! which comes after the window in which the last request finished. The wait
//! wakes for the earlier of the two (`deadlineNs`), and `runDue` does what
//! is due once it returns. Everything here runs on the VM thread outside
//! every owner window: no request is charged for it, and the sentinel
//! watches no owner while it runs.
//!
//! The collection runs only while the active map holds no dispatched
//! request and no owner window is open, so no request's JavaScript, native
//! state or response is in flight, and none can begin during it: a begin is
//! read on this thread (`loop.zig:collectControlPacket`), after the
//! collection returns. Everything a later request reaches, the routes'
//! handlers, module registries, realms and Web API objects, is rooted by
//! the VM, as every collection the engine starts on its own at an
//! allocation already requires. An evaluation still open keeps its roots
//! too, so it does not hold the collection back. The FinalizationRegistry
//! callbacks the collection makes due run in the next tick's deferred-work
//! pump, under the worker owner (`loop.zig:pumpDeferredWork`). A request
//! whose begin arrives while the collection runs waits in the control
//! socket for it to end; one that was already readable is served first,
//! since the collection runs only when the wait returned for its deadline
//! alone.

const std = @import("std");
const worker_limits = @import("collo_limits").worker;
const bindings = @import("collo_bindings");
const request_context = @import("collo_worker_request").context;
const state = @import("../runtime/root.zig");
const poll_backend = @import("poll_backend.zig");

/// When the blocked loop must wake for idle work: the earlier of the cache
/// release and the collection, or 0 when neither is pending.
pub fn deadlineNs(runtime: *const state.Runtime) u64 {
    const release_ns = cacheReleaseDeadlineNs(runtime);
    const collection_ns = collectionDeadlineNs(runtime);
    if (release_ns == 0)
        return collection_ns;
    if (collection_ns == 0)
        return release_ns;
    return @min(release_ns, collection_ns);
}

/// Does the idle work that is due now that the loop's blocked wait returned
/// `events`: the collection first, whose trim stops the VM thread's
/// allocators too, then the cache release.
pub fn runDue(runtime: *state.Runtime, events: []const poll_backend.Event) void {
    if (collectionDue(runtime, events)) {
        runtime.requests.idle_collection_owed = false;
        runtime.core.vm.collectFullGCAndTrim() catch |err|
            std.log.warn("idle collection failed: {s}", .{@errorName(err)});
    }
    if (cacheReleaseDue(runtime)) {
        bindings.releaseThreadAllocatorCache();
        runtime.owners.thread_cache_released = true;
    }
}

/// `thread_cache_idle_release_ns` after the last owner window ended, or 0
/// when the cache is already released. Idle means no owner's work, not no
/// live request: a request parked on a slow fetch leaves the thread just as
/// idle.
fn cacheReleaseDeadlineNs(runtime: *const state.Runtime) u64 {
    if (runtime.owners.thread_cache_released)
        return 0;
    return runtime.owners.idle_since_mono_ns +| worker_limits.thread_cache_idle_release_ns;
}

fn cacheReleaseDue(runtime: *const state.Runtime) bool {
    if (runtime.owners.current_id != 0)
        return false;
    const due_ns = cacheReleaseDeadlineNs(runtime);
    if (due_ns == 0)
        return false;
    return runtime.nowMonoNs() >= due_ns;
}

/// `idle_collection_delay_ns` after the last owner window ended, or 0 while
/// no finished request owes a collection or a dispatched request is held.
fn collectionDeadlineNs(runtime: *const state.Runtime) u64 {
    if (!runtime.requests.idle_collection_owed)
        return 0;
    if (holdsDispatchedRequest(runtime))
        return 0;
    return runtime.owners.idle_since_mono_ns +| worker_limits.idle_collection_delay_ns;
}

/// Whether the collection is due, and nothing the wait reported comes
/// first. A ready descriptor may hold a request's begin, which is served
/// before the collection; the next blocked wait finds the deadline passed
/// and returns at once, and the collection runs then if the worker is still
/// idle.
fn collectionDue(runtime: *const state.Runtime, events: []const poll_backend.Event) bool {
    if (runtime.owners.current_id != 0)
        return false;
    const due_ns = collectionDeadlineNs(runtime);
    if (due_ns == 0)
        return false;
    if (runtime.nowMonoNs() < due_ns)
        return false;
    for (events) |event| {
        if (std.meta.activeTag(event) != .timer_deadline)
            return false;
    }
    return true;
}

/// Whether the active map holds a dispatched request; the evaluations it
/// also holds do not count.
fn holdsDispatchedRequest(runtime: *const state.Runtime) bool {
    var ids = runtime.requests.active.keyIterator();
    while (ids.next()) |id| {
        if (!request_context.isReservedId(id.*))
            return true;
    }
    return false;
}

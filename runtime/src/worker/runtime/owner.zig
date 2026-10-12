//! Whom the worker's VM thread works for, and the one place that changes
//! it. An owner is a dispatched request; an evaluation, the owner of one
//! module instance's top-level code (`evaluations.zig`); or the worker
//! owner, one per process, for JavaScript neither of those owns: the
//! deferred-work pump, a reaction whose registrant was released or whose
//! evaluation closed, and a module settlement that arrives after its
//! evaluation closed. Their ids tell them apart (`request/context.zig`).
//! Requests and evaluations live in the runtime's active map; the worker
//! owner's exec context is `Owners.worker_exec`, which never enters that
//! map, so every host call that needs an active owner refuses its
//! JavaScript.
//!
//! An owner window opens when the VM thread starts work on an owner's
//! behalf and closes when that work ends. `enter` opens one and returns the
//! owner it interrupts; `leave` closes it and reopens the interrupted one, so
//! windows nest like the work they cover, and a caller that enters leaves on
//! every path. Each border reads the VM thread's CPU clock once, and a
//! closed window's CPU goes to its owner: `RequestContext.cpu_ns` or
//! `Owners.worker_cpu_ns`. A window covers everything the thread does for
//! its owner: the JavaScript, the bridge's native work and the worker's own
//! Zig code around it. Work outside every window, the loop's own passes, is
//! charged to nobody. An owner whose context ends inside its own window, a
//! request that finishes in its own turn or an evaluation closed by its own
//! deadline, is not found when the window closes and gets nothing more, so
//! `finishRequest` folds the window first (`foldOpenWindow`) and its records
//! hold every nanosecond up to the finish.
//!
//! Limits. A dispatched request has its wall deadline and, when its
//! definition sets `cpuMs`, a CPU budget; an evaluation has the deadline it
//! armed; the worker owner gets `Owners.unowned_time_limit_ns` of wall time
//! from the start of each of its windows. Every border publishes the new
//! owner with what is left of its limits to the sentinel
//! (`sentinel.Publication`), which stops only the published owner's
//! JavaScript, and its wall deadline to the shared page, where the server
//! faults a worker whose owner overran it. A limit already spent when a
//! window opens is not published, because a fire then would stop the native
//! answer the worker gives instead of running the owner's JavaScript
//! (`termination.endAtBoundary`); only an owner that passes a limit while it
//! runs is stopped. A charge that takes a request to its CPU budget marks it
//! `cpu_spent`, and the loop answers it after the work item
//! (`termination.endSpentBudgets`).
//!
//! A border also moves a dispatched request's timeline
//! (`RequestContext.noteTurnBegin`, `noteTurnEnd`); an evaluation and the
//! worker owner keep no timeline. The engine bridge reports the borders of
//! each restored promise reaction through the owner-transition hook
//! (`vm_hooks.zig`), which enters the reaction's owner, so a reaction is
//! charged to its registrant whoever drains it. Everything here runs on the
//! VM thread, the only thread whose CPU clock it reads.

const std = @import("std");
const bindings = @import("collo_bindings");
const process = @import("collo_os").process;
const request_context = @import("collo_worker_request").context;
const runtime_types = @import("types.zig");
const sentinel_mod = @import("sentinel.zig");

pub const worker_owner_id = request_context.worker_owner_id;

/// The owner state of a runtime (`Runtime.owners`).
pub const Owners = struct {
    /// The owner whose window is open, 0 between windows.
    current_id: u64,
    /// The VM thread's CPU clock when the open window began; meaningful only
    /// while `current_id` is not 0.
    window_cpu_start_ns: u64,
    /// The largest reading of `cpu_clock` so far. A thread's CPU time never
    /// decreases, so a reading below it, a failed read included, counts as
    /// this one and charges nothing.
    cpu_last_ns: u64,
    cpu_clock: runtime_types.Clock,
    /// The worker owner's exec context, id `worker_owner_id`. The
    /// deferred-work pump's turn runs on it, and a module settlement whose
    /// evaluation closed runs with it as the turnless context, so the bridge
    /// sees the same owner this file charges. The bridge keys owner tokens by
    /// its address, so `Runtime.deinit` releases it before the runtime's
    /// storage goes.
    worker_exec: bindings.ExecCtx,
    /// The CPU of the worker owner's windows. It belongs to no request.
    worker_cpu_ns: u64,
    /// The wall-clock limit of each window of the worker owner, its
    /// definition's `timeoutMs` (`WorkerInit.unowned_time_limit_ns`), so no
    /// JavaScript in the worker runs longer than that without an owner's
    /// deadline.
    unowned_time_limit_ns: u64,
    /// The worker owner's wall deadline in the window open now,
    /// CLOCK_MONOTONIC, set when that window opens.
    worker_deadline_ns: u64,
    /// The CPU budget each dispatched request gets at its decode, its
    /// definition's `cpuMs` (`WorkerInit.request_cpu_budget_ns`); 0 for
    /// none.
    request_cpu_budget_ns: u64,
    /// A charge took a request to its CPU budget since
    /// `termination.endSpentBudgets` last ran.
    budget_overrun_pending: bool,
    /// When the VM thread last stopped working for any owner, on the
    /// runtime's clock: the start of its idle time, from which the loop
    /// releases the thread's allocator cache (`scheduler/loop.zig`).
    idle_since_mono_ns: u64,
    /// The VM thread released its allocator cache and has run no owner's
    /// work since.
    thread_cache_released: bool,

    /// `options.unowned_time_limit_ns` is never 0: WorkerInit refuses it
    /// (`WorkerInit.validate`), and the option's default is WorkerInit's.
    pub fn init(options: runtime_types.RuntimeOptions) Owners {
        std.debug.assert(options.unowned_time_limit_ns != 0);
        return .{
            .current_id = 0,
            .window_cpu_start_ns = 0,
            .cpu_last_ns = 0,
            .cpu_clock = options.cpu_clock,
            .worker_exec = bindings.ExecCtx.init(worker_owner_id),
            .worker_cpu_ns = 0,
            .unowned_time_limit_ns = options.unowned_time_limit_ns,
            .worker_deadline_ns = 0,
            .request_cpu_budget_ns = options.request_cpu_budget_ns,
            .budget_overrun_pending = false,
            .idle_since_mono_ns = 0,
            .thread_cache_released = false,
        };
    }
};

pub const EnterOptions = struct {
    /// The window starts a work item whose enqueue counted a ready item for
    /// its request, which the turn consumes (`RequestContext.noteTurnBegin`).
    consumes_ready_item: bool = false,
};

/// The owner of the JavaScript the bridge reports under `exec_ctx`: its id,
/// or the worker owner for null, which the bridge passes for JavaScript no
/// exec context claims (a released registrant, a closed evaluation, no
/// turnless context). An exec context with id 0 names no owner either.
pub fn ownerOf(exec_ctx: ?*const bindings.ExecCtx) u64 {
    const context = exec_ctx orelse return worker_owner_id;
    if (context.request_id == 0)
        return worker_owner_id;
    return context.request_id;
}

/// Opens a window of `owner_id`, which is not 0, closing the one open now,
/// and returns the owner it interrupts, 0 when none. The caller hands that
/// value to `leave` on every path once the owner's work is done. Entering
/// the owner already running keeps its window open and only applies
/// `options`.
pub fn enter(runtime: anytype, owner_id: u64, options: EnterOptions) u64 {
    std.debug.assert(owner_id != 0);
    const owners = &runtime.owners;
    const previous_id = owners.current_id;
    const now_ns = runtime.nowMonoNs();
    if (previous_id == owner_id) {
        if (options.consumes_ready_item)
            turnBegin(runtime, owner_id, now_ns, true);
        return previous_id;
    }
    switchWindow(runtime, owner_id, now_ns);
    turnBegin(runtime, owner_id, now_ns, options.consumes_ready_item);
    return previous_id;
}

/// Closes the open window and reopens the window of `previous_id`, the
/// value the matching `enter` returned. With 0 the VM thread works for no
/// owner and the sentinel sees none.
pub fn leave(runtime: anytype, previous_id: u64) void {
    const owners = &runtime.owners;
    if (owners.current_id == previous_id)
        return;
    const now_ns = runtime.nowMonoNs();
    switchWindow(runtime, previous_id, now_ns);
    // The interrupted owner resumes work it already counted.
    turnBegin(runtime, previous_id, now_ns, false);
}

/// Charges `request` the CPU of its open window so far and restarts the
/// window, for `finishRequest`, which writes the request's CPU into its
/// records from inside that window. Does nothing when another owner's
/// window is open.
pub fn foldOpenWindow(runtime: anytype, request: *request_context.RequestContext) void {
    const owners = &runtime.owners;
    if (owners.current_id != request.exec.request_id)
        return;
    const cpu_now_ns = readCpu(owners);
    chargeContext(runtime, request, cpu_now_ns -| owners.window_cpu_start_ns);
    owners.window_cpu_start_ns = cpu_now_ns;
}

/// Adds `cpu_ns` to the CPU of `context`, a request or an evaluation, from
/// a window of its own or from the crypto pool's run of its job
/// (`js/crypto/runtime.zig`). A request whose CPU reaches its budget is
/// marked `cpu_spent` once, for `termination.endSpentBudgets` to answer.
pub fn chargeContext(runtime: anytype, context: *request_context.RequestContext, cpu_ns: u64) void {
    context.cpu_ns +|= cpu_ns;
    if (context.cpu_budget_ns == 0 or context.cpu_spent)
        return;
    if (context.cpu_ns < context.cpu_budget_ns)
        return;
    context.cpu_spent = true;
    runtime.owners.budget_overrun_pending = true;
}

/// Publishes the owner `context` names again while its window is open, after
/// its deadline was armed or disarmed (`scheduler/resources.zig`), so the
/// sentinel watches the limits it has now. The window and its CPU are
/// unchanged.
pub fn refreshPublication(runtime: anytype, context: *const request_context.RequestContext) void {
    const owners = &runtime.owners;
    if (owners.current_id == 0 or owners.current_id != context.exec.request_id)
        return;
    publish(runtime, contextPublication(runtime, context, owners.window_cpu_start_ns));
}

/// Closes the open window into its owner and makes `next_id` the owner the
/// sentinel sees, with a window starting now. The timeline of the owner that
/// leaves ends here; the caller begins the next one's.
fn switchWindow(runtime: anytype, next_id: u64, now_ns: u64) void {
    const owners = &runtime.owners;
    const cpu_now_ns = readCpu(owners);
    const current_id = owners.current_id;
    if (current_id != 0) {
        charge(runtime, current_id, cpu_now_ns -| owners.window_cpu_start_ns);
        turnEnd(runtime, current_id, now_ns);
    }
    owners.current_id = next_id;
    owners.window_cpu_start_ns = cpu_now_ns;
    // Any owner's work refills the thread's allocator cache, and the end of
    // the last window starts the idle time the loop measures.
    if (next_id == 0) {
        owners.idle_since_mono_ns = now_ns;
    } else {
        owners.thread_cache_released = false;
    }
    // The sentinel compares the worker owner's deadline with CLOCK_MONOTONIC
    // whatever clock the runtime has, so it is set from that clock.
    if (next_id == worker_owner_id)
        owners.worker_deadline_ns = process.monotonicNowNsOrZero() +| owners.unowned_time_limit_ns;
    // Published before the next owner's timeline opens, so the sentinel
    // never sees JavaScript of an owner whose turn has begun under another.
    publish(runtime, publicationOf(runtime, next_id, cpu_now_ns));
}

fn publish(runtime: anytype, publication: sentinel_mod.Publication) void {
    runtime.observability.sentinel.publish(publication);
    runtime.observability.metrics_view.publishOwner(publication.owner_id, publication.wall_deadline_ns);
}

/// What the sentinel watches while `owner_id`'s window is open, the window
/// having started at `window_cpu_start_ns`: no owner for 0, and the owner
/// alone, with no limit, for a request or an evaluation already gone from
/// the active map, whose window only finishes native work.
fn publicationOf(runtime: anytype, owner_id: u64, window_cpu_start_ns: u64) sentinel_mod.Publication {
    if (owner_id == 0)
        return .{};
    const owners = &runtime.owners;
    if (owner_id == worker_owner_id) {
        return .{
            .owner_id = owner_id,
            .wall_deadline_ns = owners.worker_deadline_ns,
            .cpu_before_ns = owners.worker_cpu_ns,
            .window_cpu_start_ns = window_cpu_start_ns,
        };
    }
    const context = runtime.requests.active.get(owner_id) orelse return .{
        .owner_id = owner_id,
        .window_cpu_start_ns = window_cpu_start_ns,
    };
    return contextPublication(runtime, context, window_cpu_start_ns);
}

/// A request's or an evaluation's limits, as far as they are left: its
/// armed wall deadline while it lies ahead on the runtime's clock, and its
/// CPU budget while some of it remains.
fn contextPublication(
    runtime: anytype,
    context: *const request_context.RequestContext,
    window_cpu_start_ns: u64,
) sentinel_mod.Publication {
    var publication: sentinel_mod.Publication = .{
        .owner_id = context.exec.request_id,
        .cpu_before_ns = context.cpu_ns,
        .window_cpu_start_ns = window_cpu_start_ns,
    };
    if (context.deadline_armed and context.exec.deadline_monotonic_ns > runtime.nowMonoNs())
        publication.wall_deadline_ns = context.exec.deadline_monotonic_ns;
    if (context.cpu_budget_ns != 0 and context.cpu_ns < context.cpu_budget_ns)
        publication.cpu_deadline_ns = window_cpu_start_ns +| (context.cpu_budget_ns - context.cpu_ns);
    return publication;
}

fn readCpu(owners: *Owners) u64 {
    owners.cpu_last_ns = @max(owners.cpu_last_ns, owners.cpu_clock.now());
    return owners.cpu_last_ns;
}

fn charge(runtime: anytype, owner_id: u64, cpu_ns: u64) void {
    if (owner_id == worker_owner_id) {
        runtime.owners.worker_cpu_ns +|= cpu_ns;
        return;
    }
    const context = runtime.requests.active.get(owner_id) orelse return;
    chargeContext(runtime, context, cpu_ns);
}

fn turnBegin(runtime: anytype, owner_id: u64, now_ns: u64, consumes_ready_item: bool) void {
    const request = timelineOwner(runtime, owner_id) orelse return;
    request.noteTurnBegin(now_ns, consumes_ready_item);
}

fn turnEnd(runtime: anytype, owner_id: u64, now_ns: u64) void {
    const request = timelineOwner(runtime, owner_id) orelse return;
    request.noteTurnEnd(now_ns);
}

/// The dispatched request `owner_id` names while it is active; null for no
/// owner, an evaluation, the worker owner or a request that ended.
fn timelineOwner(runtime: anytype, owner_id: u64) ?*request_context.RequestContext {
    if (owner_id == 0)
        return null;
    if (request_context.isReservedId(owner_id))
        return null;
    return runtime.requests.active.get(owner_id);
}

//! The worker's runtime: the state of one worker process's event loop, and
//! the object behind the `collo_runtime_*` functions the engine bridge calls
//! (`worker/host/`). `Runtime` holds one field per domain and declares the
//! operations of each domain's file as its own methods, so the rest of the
//! worker calls them on the runtime. Everything here belongs to the worker's
//! VM thread. The sentinel's thread requests termination and records which
//! owner it stopped, which the VM thread reads, and ends the process on
//! memory pressure or its own failure (`sentinel.zig`).
//!
//! The runtime starts no thread but the sentinel's, in `startSentinel`, which
//! the worker's boot calls before it installs its seccomp filter, which
//! denies clone (`zygote/child_boot.zig`). Nothing in the runtime may start a
//! thread after that, on first use or otherwise.
//!
//! Whom the VM thread works for at every moment is decided in one place,
//! `owner.zig`: a dispatched request, the evaluation of a route module's
//! top-level code, or the worker owner, and the CPU, the sentinel's view and
//! a request's timeline all follow that owner.
//!
//! Which file holds what. Every file below but `core.zig`, `types.zig`,
//! `owner.zig`, `sentinel.zig` and `egress.zig` has a `Methods(Runtime)`
//! mixin whose functions `Runtime` declares as its own, and a domain file
//! holds its state beside it. The egress operations are the functions of
//! `worker/egress/`, which take `*Runtime` themselves, and `Runtime`
//! declares the ones the rest of the worker calls.
//! - This file: `Runtime` with its fields, its construction and teardown,
//!   its clock and the sentinel's start.
//! - `owner.zig`: the owner of the VM thread and its windows, as functions
//!   over the runtime that every domain calls.
//! - `evaluations.zig`: the owners of route modules' top-level code, from
//!   the boot's evaluation of every route's entry to each one's close.
//! - `vm_hooks.zig`: what `attachHostRuntime` registers on the VM, with the
//!   owner-transition hook and the console and exception-log sinks.
//! - `scheduler.zig`: the ready queue, timers and immediates, request
//!   deadlines and the loop's wakeup eventfd.
//! - `requests.zig`: request contexts, ingress work, request completions and
//!   the `request_done` packets that wait for room in the control socket.
//! - `egress.zig`: the state of fetches and their bodies through the egress
//!   gateway, and the run of a body's ready item.
//! - `modules.zig`: route module evaluation settlements and expiries.
//! - `retirement.zig`: the worker's decision to give way to a fresh one, when
//!   its VM can run no JavaScript again or no route can serve, and the notice
//!   that tells the server.
//! - `observability.zig`: the shared page, the sentinel and the request id a
//!   line of the tenant's log carries.
//! - `core.zig`: the handles every domain reads; `types.zig`: the options,
//!   limits and clocks the runtime is built from; `sentinel.zig`: the
//!   sentinel's thread.

const std = @import("std");
const bindings = @import("collo_bindings");
const worker_shared_page = @import("collo_worker_state").page;
const runtime_types = @import("types.zig");
const egress_body = @import("../egress/body/root.zig");
const egress_fetch = @import("../egress/fetch_runtime.zig");
const egress_gateway = @import("../egress/gateway_runtime.zig");
const egress_gateway_control = @import("../egress/gateway_control.zig");
const egress_task = @import("../egress/task_runtime.zig");
const exception_log = @import("collo_worker_js").exception_log;
const response_flow = @import("../serve/response.zig");
const runtime_core = @import("core.zig");
const runtime_egress = @import("egress.zig");
const runtime_evaluations = @import("evaluations.zig");
const runtime_modules = @import("modules.zig");
const runtime_observability = @import("observability.zig");
const runtime_owner = @import("owner.zig");
const runtime_requests = @import("requests.zig");
const runtime_retirement = @import("retirement.zig");
const runtime_scheduler = @import("scheduler.zig");
const runtime_vm_hooks = @import("vm_hooks.zig");
const termination = @import("../serve/termination.zig");

const coerceRuntimeOptions = runtime_types.coerceRuntimeOptions;

pub const Runtime = struct {
    core: runtime_core.Core,
    scheduler: runtime_scheduler.Scheduler,
    requests: runtime_requests.Requests,
    egress: runtime_egress.Egress,
    modules: runtime_modules.Modules,
    /// Whom the VM thread works for, with the worker owner's exec context and
    /// CPU (`owner.zig`).
    owners: runtime_owner.Owners,
    /// What the startup evaluations copy and count (`evaluations.zig`); the
    /// evaluations themselves live in the active map.
    evaluations: runtime_evaluations.Evaluations,
    /// The VM can run no JavaScript again: the sentinel fired, and its
    /// termination cannot be cleared (`forbidExecutionOnTermination` has no
    /// reset). Set in one place, the loop's check of the fire
    /// (`checkRetirement` in `retirement.zig`), which also retires the
    /// worker.
    vm_terminated: bool,
    /// Whether, and why, the worker asked the server to retire it
    /// (`retirement.zig`).
    retirement: runtime_retirement.Retirement,
    observability: runtime_observability.Observability,
    // Filled in `attachHostRuntime`, because `self` has a stable address only
    // from then on; `exception_log` holds a pointer to this field while it is
    // attached.
    exception_sink_registration: exception_log.Registration,

    const EvaluationsMethods = runtime_evaluations.Methods(Runtime);
    const VmHooksMethods = runtime_vm_hooks.Methods(Runtime);
    const SchedulerMethods = runtime_scheduler.Methods(Runtime);
    const RequestsMethods = runtime_requests.Methods(Runtime);
    const ModulesMethods = runtime_modules.Methods(Runtime);
    const ObservabilityMethods = runtime_observability.Methods(Runtime);
    const RetirementMethods = runtime_retirement.Methods(Runtime);

    /// The writer view of the shared page holds every live request's slot,
    /// whose CPU the server reads when it ends a request the worker did not
    /// finish, and the completion eventfd is what the worker writes when it
    /// releases a request payload from the shared ring while a lane waits
    /// for room (`scheduler/loop.zig:requestPayloadReaders`), so both are
    /// required; every worker receives them with its WorkerInit. A
    /// request's completion itself is its `request_done` on the control
    /// socket (`serve/response_finish.zig`).
    ///
    /// Takes ownership of `completion_eventfd` at call entry. On success it is
    /// closed by runtime teardown; on failure it is closed before returning.
    /// `options` becomes a `RuntimeOptions` (`coerceRuntimeOptions`), whose
    /// field docs say which descriptors the runtime takes and which it
    /// borrows. `vm`, `control_fd` and `metrics_view` stay the caller's, and
    /// the runtime closes none of them. `vm` and `metrics_view` must outlive
    /// the runtime; `control_fd` must stay open until `run` returns, since
    /// teardown does not use it.
    pub fn init(
        allocator: std.mem.Allocator,
        vm: *bindings.Vm,
        control_fd: ?std.posix.fd_t,
        metrics_view: *worker_shared_page.WorkerWriterView,
        completion_eventfd: std.posix.fd_t,
        options: anytype,
    ) !Runtime {
        const runtime_options = coerceRuntimeOptions(options);
        var completion_eventfd_pending: ?std.posix.fd_t = completion_eventfd;
        errdefer if (completion_eventfd_pending) |fd| {
            std.posix.close(fd);
        };

        var ingress_payload_credit_eventfd_pending = runtime_options.ingress_payload_credit_eventfd;
        errdefer if (ingress_payload_credit_eventfd_pending) |fd| {
            std.posix.close(fd);
        };

        var modules = runtime_modules.Modules.init(runtime_options.isolate_realm);
        errdefer modules.deinit(allocator);

        var core = try runtime_core.Core.init(allocator, vm, control_fd, runtime_options);
        errdefer core.deinit();

        var observability = try runtime_observability.Observability.init(vm, metrics_view, runtime_options);
        errdefer observability.deinit();

        var egress = try runtime_egress.Egress.init(completion_eventfd, runtime_options.egress_shared_fds);
        completion_eventfd_pending = null;
        errdefer egress.deinitFailedInit(allocator);

        var scheduler = try runtime_scheduler.Scheduler.init(allocator, core.limits);
        errdefer scheduler.deinit(allocator);

        ingress_payload_credit_eventfd_pending = null;
        var requests = try runtime_requests.Requests.init(allocator, core.limits, runtime_options);
        errdefer {
            requests.deinitIngress();
            requests.deinitTables(allocator);
            requests.deinitActiveMap(allocator);
        }

        return .{
            .core = core,
            .scheduler = scheduler,
            .requests = requests,
            .egress = egress,
            .modules = modules,
            .owners = runtime_owner.Owners.init(runtime_options),
            .evaluations = .{
                .boot_egress_token = runtime_options.boot_egress_token,
                .boot_fetches_started = 0,
            },
            .vm_terminated = false,
            .retirement = .{},
            .observability = observability,
            .exception_sink_registration = undefined,
        };
    }

    pub fn deinit(self: *Runtime) void {
        // What `attachHostRuntime` registered, in the reverse order
        // (`vm_hooks.zig`).
        exception_log.clearRegistrationIf(&self.exception_sink_registration);
        self.core.vm.setConsoleSink(null, null, 0, 0, 0) catch |err|
            std.log.warn("failed to detach console sink: {s}", .{@errorName(err)});
        self.core.vm.setOwnerTransitionHook(null, null) catch |err|
            std.log.warn("failed to detach owner-transition hook: {s}", .{@errorName(err)});
        self.core.vm.setHostRuntime(null) catch |err|
            std.log.warn("failed to detach host runtime: {s}", .{@errorName(err)});
        // The deferred-work wakeup is unregistered (fd -1) before
        // `scheduler.deinit` closes the eventfd it writes: the wasm worklist
        // notification outlives this runtime and must go inert rather than
        // write to a recycled fd number.
        self.core.vm.setDeferredWorkWakeupFd(-1) catch |err|
            std.log.warn("failed to unregister deferred work wakeup: {s}", .{@errorName(err)});

        var request_it = self.requests.active.iterator();
        while (request_it.next()) |entry| {
            response_flow.releasePendingIngressResponse(self, entry.value_ptr.*);
            self.destroyRequestContext(entry.value_ptr.*);
        }
        self.requests.deinitActiveMap(self.core.allocator);
        // The bridge keys owner tokens by this exec context's address, which
        // dies with the runtime (`owner.zig`).
        self.core.vm.releaseExecCtx(&self.owners.worker_exec) catch |err|
            std.log.warn("failed to release the worker owner's exec ctx: {s}", .{@errorName(err)});
        self.requests.deinitIngress();

        self.modules.deinit(self.core.allocator);
        self.requests.deinitTables(self.core.allocator);

        // The order `egress/state.zig` gives for its teardown.
        self.egress.deinitTasks(self.core.allocator);
        egress_body.releaseAllForShutdown(self);
        self.egress.deinitAfterBodiesReleased(self.core.allocator);

        self.observability.deinit();
        self.scheduler.deinit(self.core.allocator);
        self.core.deinit();
        self.* = undefined;
    }

    pub fn nowMonoNs(self: *const Runtime) u64 {
        return self.core.clock.now();
    }

    pub fn startSentinel(self: *Runtime) !void {
        try self.observability.sentinel.start();
    }

    /// Answers every request a charge took past its CPU budget
    /// (`termination.endSpentBudgets`); the loop calls it outside every owner
    /// window.
    pub fn endSpentBudgets(self: *Runtime) void {
        termination.endSpentBudgets(self);
    }

    pub const evaluateBootRoutes = EvaluationsMethods.evaluateBootRoutes;
    pub const sealStartupEvaluations = EvaluationsMethods.sealStartupEvaluations;
    pub const lookupRouteHandler = ModulesMethods.lookupRouteHandler;
    pub const armEvaluationBudget = EvaluationsMethods.armEvaluationBudget;
    pub const closeEvaluationOnceSettled = EvaluationsMethods.closeEvaluationOnceSettled;
    pub const closeEvaluation = EvaluationsMethods.closeEvaluation;
    pub const enterTurnless = EvaluationsMethods.enterTurnless;
    pub const leaveTurnless = EvaluationsMethods.leaveTurnless;

    pub const attachHostRuntime = VmHooksMethods.attachHostRuntime;

    pub const armRequestDeadline = SchedulerMethods.armRequestDeadline;
    pub const disarmRequestDeadline = SchedulerMethods.disarmRequestDeadline;
    pub const scheduleTimer = SchedulerMethods.scheduleTimer;
    pub const scheduleImmediate = SchedulerMethods.scheduleImmediate;
    pub const readyItemOwnerRequestId = SchedulerMethods.readyItemOwnerRequestId;
    pub const tryQueueReadyWork = SchedulerMethods.tryQueueReadyWork;
    pub const tryQueueReadyWorkReadySince = SchedulerMethods.tryQueueReadyWorkReadySince;
    pub const queueReadyWork = SchedulerMethods.queueReadyWork;
    pub const drainReadyBacklog = SchedulerMethods.drainReadyBacklog;
    pub const withdrawReadyWork = SchedulerMethods.withdrawReadyWork;
    pub const collectDueTimers = SchedulerMethods.collectDueTimers;
    pub const collectReadyImmediates = SchedulerMethods.collectReadyImmediates;
    pub const collectDueRequestDeadlines = SchedulerMethods.collectDueRequestDeadlines;
    pub const nextRequestDeadlineNs = SchedulerMethods.nextRequestDeadlineNs;
    pub const cancelTimersForRequest = SchedulerMethods.cancelTimersForRequest;
    pub const cancelTimeout = SchedulerMethods.cancelTimeout;
    pub const cancelImmediate = SchedulerMethods.cancelImmediate;
    pub const drainWakeup = SchedulerMethods.drainWakeup;
    pub const drainIngressPayloadCredit = SchedulerMethods.drainIngressPayloadCredit;
    pub const wake = SchedulerMethods.wake;

    pub const enqueueIngressDescriptor = RequestsMethods.enqueueIngressDescriptor;
    pub const collectReadyIngressRequests = RequestsMethods.collectReadyIngressRequests;
    pub const handleRequestFailure = RequestsMethods.handleRequestFailure;
    pub const scheduleRequestTaskCompletion = RequestsMethods.scheduleRequestTaskCompletion;
    pub const collectReadyRequestCompletions = RequestsMethods.collectReadyRequestCompletions;
    pub const destroyRequestContext = RequestsMethods.destroyRequestContext;

    pub const scheduleFetch = egress_fetch.schedule;
    pub const disconnectEgressGatewayWithReason = egress_gateway.disconnectWithReason;
    pub const detachEgressAfterFailedRelease = egress_gateway.detachAfterFailedRelease;
    pub const collectEgressGatewayPacketsBounded = egress_gateway.collectPacketsBounded;
    pub const cancelFetchesForRequest = egress_task.cancelForRequest;
    pub const reapFetchesForRequest = egress_task.reapForRequest;
    pub const cancelFetch = egress_task.cancel;
    pub const scheduleFetchBodyConsume = egress_body.scheduleConsume;
    pub const scheduleFetchBodyPull = egress_body.schedulePull;
    pub const borrowFetchBody = egress_body.borrow;
    pub const cloneFetchBody = egress_body.clone;
    pub const cancelFetchBody = egress_body.cancel;
    pub const releaseFetchBody = egress_body.release;
    pub const beginFetchBodyResponseStreamPull = egress_body.beginResponseStreamPull;
    pub const drainFetchBodyResponseStreamReady = egress_body.drainResponseStreamReady;
    pub const cleanupFetchBodiesForRequest = egress_body.cleanupForRequest;
    pub const executeFetchBodyReady = runtime_egress.executeFetchBodyReady;
    pub const handleFetchBodyReadyFailure = egress_body.handleReadyFailure;
    pub const flushFetchBodyPoolReleases = egress_gateway_control.flushBodyPoolReleases;

    pub const collectModuleSettlements = ModulesMethods.collectModuleSettlements;
    pub const handleModuleEvaluationSettled = ModulesMethods.handleModuleEvaluationSettled;
    pub const expireRouteEvaluations = ModulesMethods.expireRouteEvaluations;
    pub const modulesContext = ModulesMethods.modulesContext;
    pub const realmOfRoute = ModulesMethods.realmOfRoute;

    pub const logNetworkDenial = ObservabilityMethods.logNetworkDenial;

    pub const checkRetirement = RetirementMethods.checkRetirement;
    pub const requestRetirement = RetirementMethods.requestRetirement;
    pub const sendRetirementNotice = RetirementMethods.sendRetirementNotice;
};

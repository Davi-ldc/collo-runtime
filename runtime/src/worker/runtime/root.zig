//! The worker's runtime: the state of one worker process's event loop, and
//! the object behind the `collo_runtime_*` functions the engine bridge calls
//! (`worker/host/`). `Runtime` holds one field per domain and declares the
//! operations of each domain's file as its own methods, so the rest of the
//! worker calls them on the runtime. Everything here belongs to the worker's
//! VM thread. The crypto pool runs jobs on threads of its own and hands each
//! back to that thread. The sentinel's thread requests termination and
//! records which owner it stopped, which the VM thread reads, and ends the
//! process on memory pressure or its own failure (`sentinel.zig`).
//!
//! The runtime starts no threads but these, the crypto pool's in `init` and
//! the sentinel's in `startSentinel`, and the worker's boot calls both
//! before it installs its seccomp filter, which denies clone
//! (`zygote/child_boot.zig`). Nothing in the runtime may start a thread
//! after that, on first use or otherwise.
//!
//! Whom the VM thread works for at every moment is decided in one place,
//! `owner.zig`: a dispatched request, the evaluation of a route module's
//! top-level code, or the worker owner, and the CPU, the sentinel's view and
//! a request's timeline all follow that owner.
//!
//! Which file holds what. Every file below but `core.zig`, `types.zig`,
//! `owner.zig` and `sentinel.zig` has a `Methods(Runtime)` mixin whose
//! functions `Runtime` declares as its own, and a domain file holds its
//! state beside it.
//! - This file: `Runtime` with its fields, its construction and teardown,
//!   its clock and the sentinel's start.
//! - `owner.zig`: the owner of the VM thread and its windows, as functions
//!   over the runtime that every domain calls.
//! - `evaluations.zig`: the owners of route modules' top-level code, from
//!   the boot's evaluation of every route's entry to each one's close.
//! - `vm_hooks.zig`: what `attachHostRuntime` registers on the VM, with the
//!   owner-transition hook and the console and exception-log sinks.
//! - `scheduler.zig`: the ready queue, timers and immediates, request
//!   deadlines, the worker ring and the loop's eventfds.
//! - `requests.zig`: request contexts, ingress work and request completions.
//! - `egress.zig`: fetches and their bodies through the egress gateway.
//! - `modules.zig`: route module evaluation settlements and expiries.
//! - `retirement.zig`: the worker's decision to give way to a fresh one, when
//!   its VM can run no JavaScript again or no route can serve, and the notice
//!   that tells the server.
//! - `crypto.zig`: WebCrypto jobs.
//! - `fs_fault.zig`: the entry points into the fault plane
//!   (`worker/fs/fault.zig`).
//! - `observability.zig`: the shared page, the sentinel, trace events and
//!   the request id a line of the tenant's log carries.
//! - `core.zig`: the handles every domain reads; `types.zig`: the options,
//!   limits and clocks the runtime is built from; `sentinel.zig`: the
//!   sentinel's thread.

const std = @import("std");
const bindings = @import("collo_bindings");
const worker_shared_page = @import("collo_worker_state").page;
const runtime_types = @import("types.zig");
const egress_body = @import("../egress/body/root.zig");
const exception_log = @import("collo_worker_js").exception_log;
const response_flow = @import("../serve/response.zig");
const fs_fault = @import("../fs/fault.zig");
const runtime_core = @import("core.zig");
const runtime_crypto = @import("crypto.zig");
const runtime_egress = @import("egress.zig");
const runtime_evaluations = @import("evaluations.zig");
const runtime_fs_fault = @import("fs_fault.zig");
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
    crypto: runtime_crypto.Crypto,
    /// In-flight fs faults, one task per path however many requests wait on
    /// it (`worker/fs/fault.zig` owns the behavior).
    fs_fault: fs_fault.State,
    /// Whom the VM thread works for, with the worker owner's exec context and
    /// CPU (`owner.zig`).
    owners: runtime_owner.Owners,
    /// What every evaluation of a route module copies (`evaluations.zig`);
    /// the evaluations themselves live in the active map.
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
    const EgressMethods = runtime_egress.Methods(Runtime);
    const ModulesMethods = runtime_modules.Methods(Runtime);
    const CryptoMethods = runtime_crypto.Methods(Runtime);
    const FsFaultMethods = runtime_fs_fault.Methods(Runtime);
    const ObservabilityMethods = runtime_observability.Methods(Runtime);
    const RetirementMethods = runtime_retirement.Methods(Runtime);

    /// The writer view of the shared page and the completion eventfd are the
    /// only completion channel a request has (a completion record, then a
    /// signal), so both are required; every worker receives them with its
    /// WorkerInit.
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

        exception_log.configure(.{
            .log_full_exceptions = runtime_options.log_full_js_exceptions,
        });

        // A route's `env` is built only once its module is ready, so a
        // malformed route table is refused here, before the worker reports
        // ready.
        var modules = try runtime_modules.Modules.init(
            allocator,
            runtime_options.route_table,
            runtime_options.isolate_realm,
        );
        errdefer modules.deinit(allocator);

        var core = try runtime_core.Core.init(allocator, vm, control_fd, runtime_options);
        errdefer core.deinit();

        var observability = try runtime_observability.Observability.init(vm, metrics_view, runtime_options);
        errdefer observability.deinit();

        var egress = try runtime_egress.Egress.init(
            allocator,
            core.limits,
            completion_eventfd,
            runtime_options.egress_shared_fds,
        );
        completion_eventfd_pending = null;
        errdefer egress.deinitFailedInit(allocator);

        var scheduler = try runtime_scheduler.Scheduler.init(allocator, core.limits);
        errdefer scheduler.deinit(allocator);

        var crypto = try runtime_crypto.Crypto.init(allocator, scheduler.wakeup_fd.?, core.limits);
        errdefer crypto.deinit();

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
            .crypto = crypto,
            .fs_fault = .{},
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
        self.crypto.deinit();

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

        self.scheduler.deinitWorkerRing();

        self.fs_fault.deinit(self.core.allocator);
        self.modules.deinit(self.core.allocator);
        self.requests.deinitTables(self.core.allocator);

        // The release callbacks are bound to this address before the bodies
        // go: a runtime that never ran `attachHostRuntime` has none, and an
        // unbound release does nothing (`BodyPoolReleaseContext` in
        // `egress/state.zig`), so the extents would never reach the gateway.
        self.installEgressCallbacks();
        self.egress.deinitTasks(self.core.allocator);
        var egress_ctx = self.egressContext();
        egress_body.releaseAllForShutdown(&egress_ctx);
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
    pub const ensureRouteHandler = EvaluationsMethods.ensureRouteHandler;
    pub const armEvaluationBudget = EvaluationsMethods.armEvaluationBudget;
    pub const closeEvaluationOnceSettled = EvaluationsMethods.closeEvaluationOnceSettled;
    pub const closeEvaluation = EvaluationsMethods.closeEvaluation;
    pub const enterTurnless = EvaluationsMethods.enterTurnless;
    pub const leaveTurnless = EvaluationsMethods.leaveTurnless;

    pub const attachHostRuntime = VmHooksMethods.attachHostRuntime;

    pub const initRestrictedWorkerRing = SchedulerMethods.initRestrictedWorkerRing;
    pub const workerRingFd = SchedulerMethods.workerRingFd;
    pub const workerTimerFd = SchedulerMethods.workerTimerFd;
    pub const workerRingFixedFiles = SchedulerMethods.workerRingFixedFiles;
    pub const workerSchedulerMetricsSnapshot = SchedulerMethods.workerSchedulerMetricsSnapshot;
    pub const armRequestDeadline = SchedulerMethods.armRequestDeadline;
    pub const disarmRequestDeadline = SchedulerMethods.disarmRequestDeadline;
    pub const scheduleTimer = SchedulerMethods.scheduleTimer;
    pub const scheduleImmediate = SchedulerMethods.scheduleImmediate;
    pub const readyItemOwnerRequestId = SchedulerMethods.readyItemOwnerRequestId;
    pub const tryQueueReadyWork = SchedulerMethods.tryQueueReadyWork;
    pub const tryQueueReadyWorkReadySince = SchedulerMethods.tryQueueReadyWorkReadySince;
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
    pub const flushPendingIngressResponses = RequestsMethods.flushPendingIngressResponses;

    pub const scheduleFetch = EgressMethods.scheduleFetch;
    pub const disconnectEgressGateway = EgressMethods.disconnectEgressGateway;
    pub const disconnectEgressGatewayWithReason = EgressMethods.disconnectEgressGatewayWithReason;
    pub const detachEgressAfterFailedRelease = EgressMethods.detachEgressAfterFailedRelease;
    pub const cancelFetchesForRequest = EgressMethods.cancelFetchesForRequest;
    pub const reapFetchesForRequest = EgressMethods.reapFetchesForRequest;
    pub const cancelFetch = EgressMethods.cancelFetch;
    pub const registerFetchBody = EgressMethods.registerFetchBody;
    pub const registerFetchBodyComplete = EgressMethods.registerFetchBodyComplete;
    pub const registerFetchBodyOpen = EgressMethods.registerFetchBodyOpen;
    pub const appendFetchBodyBytes = EgressMethods.appendFetchBodyBytes;
    pub const completeFetchBody = EgressMethods.completeFetchBody;
    pub const failFetchBody = EgressMethods.failFetchBody;
    pub const scheduleFetchBodyConsume = EgressMethods.scheduleFetchBodyConsume;
    pub const scheduleFetchBodyPull = EgressMethods.scheduleFetchBodyPull;
    pub const borrowFetchBody = EgressMethods.borrowFetchBody;
    pub const cloneFetchBody = EgressMethods.cloneFetchBody;
    pub const cancelFetchBody = EgressMethods.cancelFetchBody;
    pub const releaseFetchBody = EgressMethods.releaseFetchBody;
    pub const beginFetchBodyResponseStreamPull = EgressMethods.beginFetchBodyResponseStreamPull;
    pub const drainFetchBodyResponseStreamReady = EgressMethods.drainFetchBodyResponseStreamReady;
    pub const releaseFetchBodyResponseStreamCredits = EgressMethods.releaseFetchBodyResponseStreamCredits;
    pub const flushFetchBodyPoolReleases = EgressMethods.flushFetchBodyPoolReleases;
    pub const cleanupFetchBodiesForRequest = EgressMethods.cleanupFetchBodiesForRequest;
    pub const executeFetchBodyReady = EgressMethods.executeFetchBodyReady;
    pub const handleFetchBodyReadyFailure = EgressMethods.handleFetchBodyReadyFailure;
    pub const egressContext = EgressMethods.egressContext;
    pub const collectCompletedFetches = EgressMethods.collectCompletedFetches;
    pub const collectEgressGatewayPacket = EgressMethods.collectEgressGatewayPacket;
    pub const collectEgressGatewayPacketsBounded = EgressMethods.collectEgressGatewayPacketsBounded;
    pub const handleEgressGatewayPacketBytes = EgressMethods.handleEgressGatewayPacketBytes;
    pub const collectReadyFetchBodies = EgressMethods.collectReadyFetchBodies;
    pub const installEgressCallbacks = EgressMethods.installEgressCallbacks;

    pub const collectModuleSettlements = ModulesMethods.collectModuleSettlements;
    pub const handleModuleEvaluationSettled = ModulesMethods.handleModuleEvaluationSettled;
    pub const expireRouteEvaluations = ModulesMethods.expireRouteEvaluations;
    pub const modulesContext = ModulesMethods.modulesContext;
    pub const realmOfRoute = ModulesMethods.realmOfRoute;

    pub const scheduleCryptoJob = CryptoMethods.scheduleCryptoJob;
    pub const collectCompletedCryptoJobs = CryptoMethods.collectCompletedCryptoJobs;
    pub const cancelCryptoJobsForRequest = CryptoMethods.cancelCryptoJobsForRequest;

    pub const scheduleFsFaultRead = FsFaultMethods.scheduleFsFaultRead;
    pub const fsFaultReadSync = FsFaultMethods.fsFaultReadSync;
    pub const collectFsFaultResponse = FsFaultMethods.collectFsFaultResponse;
    pub const collectFsFaultCompletions = FsFaultMethods.collectFsFaultCompletions;
    pub const executeFsFaultCompletion = FsFaultMethods.executeFsFaultCompletion;
    pub const handleFsFaultCompletionFailure = FsFaultMethods.handleFsFaultCompletionFailure;

    pub const traceRuntimeEvent = ObservabilityMethods.traceRuntimeEvent;
    pub const logNetworkDenial = ObservabilityMethods.logNetworkDenial;
    pub const flushLiveRequestCpuBestEffort = ObservabilityMethods.flushLiveRequestCpuBestEffort;

    pub const checkRetirement = RetirementMethods.checkRetirement;
    pub const requestRetirement = RetirementMethods.requestRetirement;
    pub const sendRetirementNotice = RetirementMethods.sendRetirementNotice;
};

//! Evaluations: the owners of route modules' top-level code. One evaluation
//! exists per module instance being evaluated. It opens for the route whose
//! entry first runs the instance, every route that shares the instance
//! joins it (`evaluationInFlight` in `worker/modules/routes.zig`), and it
//! closes once no route evaluates under it: when the instance's evaluation
//! settles, throws or passes its budget. `Evaluations` is the state they
//! share, and `Methods` holds the runtime's operations on them, which
//! `Runtime` declares as its own. They run on the worker's VM thread.
//!
//! An evaluation's context sits in the active map under its id
//! (`request_context.evaluationId`), so its top-level code sets timers,
//! fetches and starts crypto jobs under that id as a request does under its
//! own: one route's top-level code cannot clear another's timers, and a
//! route's top-level timers end with its own evaluation. The startup
//! evaluations, those opened before `sealStartupEvaluations`, present their
//! copies of WorkerInit's boot token, whose request id and generation 0 mark
//! it as the boot token on the egress wire; a later evaluation gets none.
//! Once the last of them closes, the worker sets the lifecycle page's
//! startup-end flag, which lets the server end the token before its deadline
//! (`server/supervisor/worker_table.zig:Record.bootEndAttempt`). While its
//! code runs outside a turn, the evaluation is the bridge's turnless context
//! (`Vm.setTurnlessExecCtx`), so host calls resolve to it and every reaction
//! its code registers carries its token, and its owner window is open
//! (`owner.zig`).
//!
//! Deadlines: the init deadline bounds the synchronous part of every route
//! the boot evaluates, a pending one's continuations included; an evaluation
//! a request starts runs its synchronous part under that request's
//! deadline; past its synchronous part, a pending evaluation has its routes'
//! own budget (`Evaluating.deadline_mono_ns` in `worker/modules/state.zig`).
//! The sentinel stops a turn only for the evaluation whose turn it is, and a
//! fire still retires the worker, since it forbids execution in the whole
//! VM (`retirement.zig`).

const std = @import("std");
const bindings = @import("collo_bindings");
const ipc = @import("collo_ipc");
const request_context = @import("collo_worker_request").context;
const modules_routes = @import("../modules/routes.zig");
const response_flow = @import("../serve/response.zig");
const runtime_owner = @import("owner.zig");

pub const Evaluations = struct {
    /// WorkerInit's boot token (`RuntimeOptions.boot_egress_token`), which
    /// each startup evaluation copies when it opens. `sealStartupEvaluations`
    /// and a gateway disconnect (`egress/context.zig:Context.revokeBootEgress`)
    /// clear it.
    boot_egress_token: ipc.egress_token.Bytes,
    /// The startup evaluations still open, one bit per evaluation id less
    /// `request_context.evaluation_id_first`; routes that share a module
    /// instance share its one evaluation.
    startup_owners: std.bit_set.StaticBitSet(request_context.evaluation_count) = .initEmpty(),
    /// Set once the boot evaluated every route; evaluations opened later are
    /// not startup evaluations.
    startup_sealed: bool = false,
    /// Fetches every evaluation together started under the boot token,
    /// finished or not, for the worker's life. The gateway keeps one budget
    /// for the token however many evaluations present a copy, so
    /// `fetch_runtime.schedule` in `worker/egress/` counts an evaluation's
    /// fetch here instead of in its context.
    boot_fetches_started: u64,
};

/// An evaluation the caller holds open: its id and its context in the
/// active map.
const Evaluation = struct {
    id: u64,
    context: *request_context.RequestContext,
};

pub fn Methods(comptime Runtime: type) type {
    return struct {
        /// Registers the definition's pack WorkerInit delivered and evaluates
        /// every route's entry, in route order, before the worker reports
        /// ready (`bootRegisterPack` and `bootEvaluateRoute` in
        /// `worker/modules/routes.zig`). With a top-level await, ready means
        /// the synchronous part is done and the event loop settles the
        /// evaluation later.
        ///
        /// A nonzero `init_deadline_mono_ns` is the host's absolute init
        /// deadline minus the child's cleanup reserve. Every evaluation the
        /// boot opens is armed at it, so the sentinel watches the synchronous
        /// part of every route, and once it has passed no further route is
        /// evaluated and the boot fails with
        /// `error.WorkerInitDeadlineExceeded`. Zero, as in-process tests
        /// pass, arms nothing during the synchronous parts. Once every route
        /// ran, each evaluation still in flight is armed at its routes' own
        /// budget instead; failing to arm one fails the init, since an await
        /// that never settles would otherwise keep its evaluation, with its
        /// timers and fetches, open for the worker's life.
        pub fn evaluateBootRoutes(
            self: *Runtime,
            module_pack_fd: std.posix.fd_t,
            init_deadline_mono_ns: u64,
            marks: ?*modules_routes.BootEvalMarks,
        ) !void {
            // Fs faults of top-level code, synchronous or not, are allowed
            // only while the synchronous evaluation runs. The window closes
            // on return, before the zygote's child sends ready, so every boot
            // permit (request id and generation 0) a legitimate fault sends
            // is already queued on the socket when the host reads ready, and
            // the host refuses one that comes after. Top-level code after an
            // await runs after ready and the worker refuses it at the same
            // gate (`faultIdentity` in `worker/fs/fault.zig`).
            self.fs_fault.boot_window_open = true;
            defer self.fs_fault.boot_window_open = false;
            var ctx = self.modulesContext();
            try modules_routes.bootRegisterPack(&ctx, module_pack_fd, marks);
            var any_pending = false;
            for (0..self.modules.state.routes.items.len) |index| {
                // Past the init deadline the sentinel has stopped the VM or
                // is about to, so a later route would only create its realm
                // and fail, inside the child's cleanup reserve.
                if (init_deadline_mono_ns != 0 and self.nowMonoNs() >= init_deadline_mono_ns)
                    return error.WorkerInitDeadlineExceeded;
                if (try bootEvaluate(self, index, init_deadline_mono_ns) == .pending)
                    any_pending = true;
            }
            if (!any_pending)
                return;
            for (self.modules.state.routes.items) |route| {
                const evaluating = switch (route.module) {
                    .evaluating => |evaluating| evaluating,
                    .idle, .ready, .failed => continue,
                };
                try self.armEvaluationBudget(evaluating.evaluation_id);
            }
        }

        /// Ends the set of startup evaluations once the boot evaluated every
        /// route, at once for a worker without routes (`zygote/child_boot.zig`).
        /// Clears the runtime's copy of the boot token, so a later evaluation
        /// gets none while the startup evaluations still open keep theirs, and
        /// sets the startup-end flag when none is open.
        pub fn sealStartupEvaluations(self: *Runtime) void {
            self.evaluations.startup_sealed = true;
            self.evaluations.boot_egress_token = ipc.egress_token.none;
            publishStartupEnd(self);
        }

        fn publishStartupEnd(self: *Runtime) void {
            if (!self.evaluations.startup_sealed or
                self.evaluations.startup_owners.count() != 0)
                return;
            self.observability.metrics_view.publishStartupEvaluationsEnded();
        }

        /// The handler and `env` of the route `request_ctx` dispatches to
        /// (`lookupRouteHandler` in `worker/modules/routes.zig`). A route
        /// still `idle` has its entry evaluated now, under the evaluation of
        /// its module instance, whose synchronous part runs under the
        /// request's deadline: `.pending` parks the request on the
        /// evaluation, armed from then on at its budget, and `.exception`
        /// pins the route failed. Fails as `lookupRouteHandler` and
        /// `evaluateRequestedRoute` do, or when the evaluation cannot be
        /// opened or armed.
        pub fn ensureRouteHandler(
            self: *Runtime,
            request_ctx: *request_context.RequestContext,
        ) !modules_routes.RouteHandlerResult {
            var ctx = self.modulesContext();
            switch (try modules_routes.lookupRouteHandler(&ctx, request_ctx)) {
                .ready => |route| return .{ .ready = route },
                .pending => return .pending,
                .idle => {},
            }
            const evaluation = try openOrJoin(
                self,
                request_ctx.dispatch_work.route_index,
                request_ctx.exec.deadline_monotonic_ns,
            );
            const result = evaluateRequested(self, evaluation, request_ctx) catch |err| {
                self.closeEvaluationOnceSettled(evaluation.id);
                return err;
            };
            switch (result) {
                .pending => try self.armEvaluationBudget(evaluation.id),
                .ready, .exception => self.closeEvaluationOnceSettled(evaluation.id),
            }
            return result;
        }

        /// Arms evaluation `evaluation_id` at its routes' budget
        /// (`Evaluating.deadline_mono_ns`), in place of the deadline it had;
        /// does nothing when it is closed, already armed there and not yet
        /// due, or no route evaluates under it. Fails as `armRequestDeadline`
        /// does, leaving the evaluation with no deadline.
        pub fn armEvaluationBudget(self: *Runtime, evaluation_id: u64) !void {
            const evaluation = self.requests.active.get(evaluation_id) orelse return;
            var ctx = self.modulesContext();
            const budget_deadline_ns = modules_routes.evaluationDeadline(&ctx, evaluation_id) orelse return;
            if (evaluation.deadline_armed and !evaluation.deadline_due_queued and
                evaluation.exec.deadline_monotonic_ns == budget_deadline_ns)
                return;
            self.disarmRequestDeadline(evaluation);
            evaluation.exec.deadline_monotonic_ns = budget_deadline_ns;
            errdefer evaluation.exec.deadline_monotonic_ns = 0;
            try self.armRequestDeadline(evaluation);
        }

        /// Closes evaluation `evaluation_id` once no route evaluates under
        /// it, after a settlement, an expiry or a synchronous end; does
        /// nothing while one still does, or when it is already closed.
        pub fn closeEvaluationOnceSettled(self: *Runtime, evaluation_id: u64) void {
            var ctx = self.modulesContext();
            if (modules_routes.evaluationOpen(&ctx, evaluation_id))
                return;
            self.closeEvaluation(evaluation_id);
        }

        /// Closes evaluation `evaluation_id`; does nothing when it is not
        /// open. The caller ensures no route evaluates under it any more. In
        /// order, it:
        ///  1. takes the context out of the active map, so nothing can
        ///     schedule work under the id again, and clears its token copy,
        ///     so nothing in the worker can present it again;
        ///  2. disarms its deadline, so the sentinel stops watching it;
        ///  3. sweeps every resource it owns, as request teardown does, with
        ///     native finalization only: no tenant JavaScript runs to release
        ///     anything;
        ///  4. destroys the context, which releases its exec context in the
        ///     bridge and with it the turnless install, so a reaction it
        ///     registered that runs later runs under the worker owner;
        ///  5. takes it out of the startup evaluations, and sets the
        ///     startup-end flag when that set is sealed and empty.
        ///
        /// After it, a native completion still in flight for the id finds no
        /// owner and is dropped, like one for a finished request: a fetch
        /// completion before its rejection turn could run
        /// (`egress/completion_runtime.zig`), an fs fault waiter, a crypto
        /// job. A fetch is reaped rather than canceled: a canceled fetch may
        /// never get a gateway completion, and with the context gone no
        /// JavaScript can observe its promise, so the task ends here instead
        /// of leaking until teardown.
        pub fn closeEvaluation(self: *Runtime, evaluation_id: u64) void {
            const removed = self.requests.active.fetchRemove(evaluation_id) orelse return;
            const evaluation = removed.value;
            evaluation.dispatch_work.egress_token = ipc.egress_token.none;
            self.disarmRequestDeadline(evaluation);
            evaluation.exec.deadline_monotonic_ns = 0;
            self.cancelCryptoJobsForRequest(evaluation_id);
            self.reapFetchesForRequest(evaluation_id);
            self.cleanupFetchBodiesForRequest(evaluation_id);
            self.cancelTimersForRequest(evaluation_id);
            self.core.vm.cleanupWebApiRequest(evaluation_id) catch |err|
                std.log.warn("failed to clean up evaluation WebAPI state evaluation_id={d}: {s}", .{
                    evaluation_id,
                    @errorName(err),
                });
            response_flow.releasePendingIngressResponse(self, evaluation);
            self.destroyRequestContext(evaluation);
            self.evaluations.startup_owners.unset(@intCast(evaluation_id - request_context.evaluation_id_first));
            publishStartupEnd(self);
        }

        /// Makes `exec_ctx` the bridge's turnless context and opens its
        /// owner's window, for JavaScript a module runs outside any turn: its
        /// evaluation, the drains inside it, and its settlement. Returns the
        /// owner to hand to `leaveTurnless`. Fails, with nothing changed,
        /// when the bridge refuses the install.
        pub fn enterTurnless(self: *Runtime, exec_ctx: *bindings.ExecCtx) !u64 {
            try self.core.vm.setTurnlessExecCtx(exec_ctx);
            return runtime_owner.enter(self, runtime_owner.ownerOf(exec_ctx), .{});
        }

        /// Undoes `enterTurnless`. No two of these steps nest: a request
        /// evaluates a route between turns, never inside one, and the loop
        /// runs a settlement only between work items.
        pub fn leaveTurnless(self: *Runtime, previous_owner_id: u64) void {
            runtime_owner.leave(self, previous_owner_id);
            self.core.vm.setTurnlessExecCtx(null) catch |err|
                std.log.warn("failed to uninstall the turnless exec ctx: {s}", .{@errorName(err)});
        }

        /// Evaluates the entry of the route at `index` for the boot, under
        /// its instance's evaluation, and closes that evaluation when its
        /// routes all ended within the synchronous part.
        fn bootEvaluate(
            self: *Runtime,
            index: usize,
            init_deadline_mono_ns: u64,
        ) !modules_routes.BootRouteOutcome {
            if (self.modules.state.routes.items[index].module != .idle)
                return .settled;
            const evaluation = try openOrJoin(self, index, init_deadline_mono_ns);
            const outcome = bootEvaluateUnder(self, evaluation, index) catch |err| {
                self.closeEvaluationOnceSettled(evaluation.id);
                return err;
            };
            if (init_deadline_mono_ns != 0 and initDeadlineReached(self, evaluation.context)) {
                // The sentinel stopped the VM in the synchronous part, or is
                // about to, so the outcome is the termination, not user code,
                // and the typed error lets the zygote's child report a clean
                // init failure instead of a ready worker.
                self.closeEvaluation(evaluation.id);
                return error.WorkerInitDeadlineExceeded;
            }
            if (outcome == .settled)
                self.closeEvaluationOnceSettled(evaluation.id);
            return outcome;
        }

        /// Whether the boot's synchronous evaluation under `context` ended at
        /// the init deadline: the sentinel fired, which in the boot can only
        /// be an evaluation's deadline, or the armed deadline passed.
        fn initDeadlineReached(self: *Runtime, context: *const request_context.RequestContext) bool {
            if (self.observability.sentinel.fired() != null)
                return true;
            if (!context.deadline_armed)
                return false;
            return self.nowMonoNs() >= context.exec.deadline_monotonic_ns;
        }

        fn bootEvaluateUnder(self: *Runtime, evaluation: Evaluation, index: usize) !modules_routes.BootRouteOutcome {
            const previous_owner_id = try self.enterTurnless(&evaluation.context.exec);
            defer self.leaveTurnless(previous_owner_id);
            var ctx = self.modulesContext();
            return modules_routes.bootEvaluateRoute(&ctx, index, evaluation.id);
        }

        fn evaluateRequested(
            self: *Runtime,
            evaluation: Evaluation,
            request_ctx: *request_context.RequestContext,
        ) !modules_routes.RouteHandlerResult {
            const previous_owner_id = try self.enterTurnless(&evaluation.context.exec);
            defer self.leaveTurnless(previous_owner_id);
            var ctx = self.modulesContext();
            return modules_routes.evaluateRequestedRoute(&ctx, request_ctx, evaluation.id);
        }

        /// The evaluation the route at `index` evaluates its entry under: the
        /// one in flight for its module instance, or a new one opened now and
        /// armed at `sync_deadline_mono_ns` unless that is 0.
        fn openOrJoin(self: *Runtime, index: usize, sync_deadline_mono_ns: u64) !Evaluation {
            var ctx = self.modulesContext();
            if (modules_routes.evaluationInFlight(&ctx, index)) |evaluation_id| {
                // A route evaluates under an evaluation only while it is open
                // (`closeEvaluationOnceSettled`), so a miss is a broken
                // invariant that fails this evaluation alone.
                const context = self.requests.active.get(evaluation_id) orelse
                    return error.EvaluationNotOpen;
                return .{ .id = evaluation_id, .context = context };
            }
            const evaluation_id = request_context.evaluationId(index);
            const context = try openEvaluation(self, evaluation_id, @intCast(index));
            if (sync_deadline_mono_ns != 0) {
                context.exec.deadline_monotonic_ns = sync_deadline_mono_ns;
                self.armRequestDeadline(context) catch |err| {
                    self.closeEvaluation(evaluation_id);
                    return err;
                };
            }
            return .{ .id = evaluation_id, .context = context };
        }

        fn openEvaluation(
            self: *Runtime,
            evaluation_id: u64,
            route_index: u16,
        ) !*request_context.RequestContext {
            // After `sealStartupEvaluations` the runtime's copy is `none`, so a
            // later evaluation copies no token.
            var dispatch_work = try ipc.DispatchWork.initBoot(
                self.core.allocator,
                evaluation_id,
                &self.evaluations.boot_egress_token,
            );
            var dispatch_moved = false;
            errdefer if (!dispatch_moved) dispatch_work.deinit();
            const context = try self.core.allocator.create(request_context.RequestContext);
            errdefer self.core.allocator.destroy(context);
            context.* = request_context.RequestContext.initEvaluation(
                self.core.allocator,
                evaluation_id,
                route_index,
                dispatch_work,
                self.nowMonoNs(),
            );
            dispatch_moved = true;
            errdefer context.deinit();
            try self.requests.active.putNoClobber(self.core.allocator, evaluation_id, context);
            if (!self.evaluations.startup_sealed)
                self.evaluations.startup_owners.set(@intCast(evaluation_id - request_context.evaluation_id_first));
            return context;
        }
    };
}

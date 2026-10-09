//! The boot context: the identity of module top-level code, kept in the
//! runtime's active map under `request_context.boot_request_id` while the
//! routes' entries evaluate, with its state in `Runtime.boot_ctx`
//! (`root.zig`). `Methods` holds the runtime's operations on it, which
//! `Runtime` declares as its own. They run on the worker's VM thread. The
//! worker's boot installs the context and evaluates every route's entry
//! under it after seccomp and before it reports ready
//! (`zygote/child_boot.zig`). One context serves every route and every
//! realm: the routes of a worker share its process, its limits and its boot
//! token.
//!
//! The context closes once, when no route's evaluation is left in flight,
//! and stays closed for the life of the process, so the top-level code of
//! every route, however late its await settles, runs under this owner and
//! its deadline. The close clears the boot egress token first, so nothing in
//! the worker can present it again, and after it a timer, an immediate, a
//! crypto job or a fetch under the boot id is refused
//! (`bootIdentityClosed`).

const std = @import("std");
const ipc = @import("collo_ipc");
const request_context = @import("collo_worker_request").context;
const modules_routes = @import("../modules/routes.zig");
const scheduler_resources = @import("../scheduler/resources.zig");
const response_flow = @import("../serve/response.zig");

pub fn Methods(comptime Runtime: type) type {
    return struct {
        /// Installs the boot context, the identity under which module top-level
        /// code fetches and sets timers. It is keyed by `boot_request_id`, so
        /// every guard that reads request id 0 as "no request" stays intact, and
        /// it lasts until no route's evaluation is in flight
        /// (`closeBootContext`). The caller installs it for a worker that serves
        /// routes (`WorkerInit.servesRoutes`); without it, top-level fetches and
        /// timers are refused. Top-level fetches present `boot_egress_token`,
        /// WorkerInit's boot token, which the boot context copies; with
        /// `egress_token.none` the worker refuses them before they leave
        /// (`fetch_runtime.refusal`).
        pub fn installBootContext(
            self: *Runtime,
            boot_egress_token: *const ipc.egress_token.Bytes,
        ) !void {
            var dispatch_work = try ipc.DispatchWork.initBoot(
                self.core.allocator,
                request_context.boot_request_id,
                boot_egress_token,
            );
            var dispatch_moved = false;
            errdefer if (!dispatch_moved) dispatch_work.deinit();
            const boot_ctx = try self.core.allocator.create(request_context.RequestContext);
            errdefer self.core.allocator.destroy(boot_ctx);
            boot_ctx.* = request_context.RequestContext.initBoot(
                self.core.allocator,
                dispatch_work,
                self.nowMonoNs(),
            );
            dispatch_moved = true;
            errdefer boot_ctx.deinit();
            try self.requests.active.putNoClobber(
                self.core.allocator,
                request_context.boot_request_id,
                boot_ctx,
            );
            errdefer _ = self.requests.active.fetchRemove(request_context.boot_request_id);
            // The bridge's half of the same identity: turnless JavaScript (module
            // evaluation and its drains) resolves host calls to this id.
            try self.core.vm.setBootExecCtx(request_context.boot_request_id);
        }

        pub fn bootContext(self: *Runtime) ?*request_context.RequestContext {
            return self.requests.active.get(request_context.boot_request_id);
        }

        /// Registers the definition's pack WorkerInit delivered and evaluates
        /// every route's entry, in route order, before the worker reports ready
        /// (`bootRegisterPack` and `bootEvaluateRoute` in
        /// `worker/modules/routes.zig`). With a top-level await, ready means the
        /// synchronous part is done and the event loop settles the evaluation
        /// later; the boot context's deadline is then armed to the evaluation
        /// budget, so an await that never settles is reclaimed even when no
        /// request waits on it.
        ///
        /// A nonzero `init_deadline_mono_ns` is the host's absolute init deadline
        /// minus the child's cleanup reserve. It is armed before the pack is
        /// registered and the routes evaluated, so the sentinel watches the
        /// synchronous part of every route at once, and once it has passed no
        /// further route is evaluated. Zero, as in-process tests pass, arms
        /// nothing until a top-level await is pending.
        pub fn evaluateBootRoutes(
            self: *Runtime,
            module_pack_fd: std.posix.fd_t,
            init_deadline_mono_ns: u64,
            marks: ?*modules_routes.BootEvalMarks,
        ) !void {
            // Boot-context fs faults, synchronous or not, are allowed only while
            // the synchronous evaluation runs. The window closes on return,
            // before the zygote's child sends ready, so every boot permit
            // (request id and generation 0) a legitimate fault sends is already
            // queued on the socket when the host reads ready, and the host
            // refuses one that comes after. Top-level code after an await runs
            // after ready and the worker refuses it at the same gate.
            self.fs_fault.boot_window_open = true;
            defer self.fs_fault.boot_window_open = false;
            const maybe_boot_ctx = self.bootContext();
            var init_deadline_armed = false;
            if (init_deadline_mono_ns != 0) {
                if (maybe_boot_ctx) |boot_ctx| {
                    boot_ctx.exec.deadline_monotonic_ns = init_deadline_mono_ns;
                    errdefer boot_ctx.exec.deadline_monotonic_ns = 0;
                    try self.armRequestDeadline(boot_ctx);
                    init_deadline_armed = true;
                }
            }
            errdefer if (init_deadline_armed) {
                const boot_ctx = maybe_boot_ctx.?;
                self.disarmRequestDeadline(boot_ctx);
                boot_ctx.exec.deadline_monotonic_ns = 0;
            };
            const pending = pending: {
                // The evaluation runs JavaScript outside any turn, so the owner
                // the deadline arbiter reads is published explicitly.
                scheduler_resources.publishTurnOwner(self, request_context.boot_request_id);
                defer scheduler_resources.clearTurnOwner(self);
                var ctx = self.modulesContext();
                try modules_routes.bootRegisterPack(&ctx, module_pack_fd, marks);
                var any_pending = false;
                for (0..self.modules.state.routes.items.len) |index| {
                    // Past the init deadline the sentinel has stopped the VM or
                    // is about to, so a later route would only create its realm
                    // and fail, inside the child's cleanup reserve.
                    if (init_deadline_armed and self.requestDeadlineTerminationRequested(maybe_boot_ctx.?))
                        break;
                    if (try modules_routes.bootEvaluateRoute(&ctx, index) == .pending)
                        any_pending = true;
                }
                break :pending any_pending;
            };
            // The init deadline passed during the synchronous part: the sentinel
            // already terminated the VM, so the outcome is the termination
            // exception, not user code. The typed error lets the zygote's child
            // report a clean init failure instead of a ready worker.
            if (init_deadline_armed and self.requestDeadlineTerminationRequested(maybe_boot_ctx.?)) {
                self.disarmRequestDeadline(maybe_boot_ctx.?);
                maybe_boot_ctx.?.exec.deadline_monotonic_ns = 0;
                return error.WorkerInitDeadlineExceeded;
            }
            if (!pending) {
                // Every entry settled within the synchronous part, so the boot
                // context closes now, not at ready.
                self.closeBootContext();
                return;
            }
            const boot_ctx = maybe_boot_ctx orelse return;
            // A top-level await is pending: the init deadline gives way to the
            // evaluation budget, which starts after the last route's
            // synchronous part and so covers every await in flight.
            self.disarmRequestDeadline(boot_ctx);
            boot_ctx.exec.deadline_monotonic_ns = self.nowMonoNs() +| modules_routes.module_eval_budget_ns;
            // Without the armed budget, an await that never settles and has no
            // request waiting on it would keep a ready worker alive until its
            // idle timeout. Failing to arm it fails the init instead.
            errdefer boot_ctx.exec.deadline_monotonic_ns = 0;
            try self.armRequestDeadline(boot_ctx);
        }

        /// Closes the boot context once no route's evaluation is in flight,
        /// inside `evaluateBootRoutes` or later when the last top-level await
        /// settles. In order, it:
        ///  1. clears the boot token where it is stored, so nothing in the worker
        ///     can present it again;
        ///  2. uninstalls the bridge's boot exec context, so turnless JavaScript
        ///     and the console exemption find no context;
        ///  3. sweeps every resource the boot context owns, as request teardown
        ///     does, with native finalization only: no tenant JavaScript runs to
        ///     release anything;
        ///  4. removes the boot context from the active map and destroys it.
        ///
        /// After step 4, a native completion still in flight for the boot id
        /// finds no request and is dropped, like one for any finished request: a
        /// fetch completion is released before its canceled-rejection turn could
        /// run (`egress/completion_runtime.zig`), an fs fault waiter is skipped,
        /// and a crypto job is destroyed. So no JavaScript runs under the boot id
        /// after the close, not even a canceled fetch's rejection reactions, and
        /// none could run without a deadline. New work under the boot id is
        /// refused by `bootIdentityClosed` and by the bridge, which no longer has
        /// the context; a boot upload that raced the sweep fails on its own
        /// request lookup (`upload_runtime.sendStart`).
        pub fn closeBootContext(self: *Runtime) void {
            if (self.boot_ctx != .open)
                return;
            self.boot_ctx = .closing;
            defer self.boot_ctx = .closed;
            if (self.bootContext()) |boot_ctx| {
                boot_ctx.dispatch_work.egress_token = ipc.egress_token.none;
                self.disarmRequestDeadline(boot_ctx);
                boot_ctx.exec.deadline_monotonic_ns = 0;
            }
            self.core.vm.clearBootExecCtx() catch |err|
                std.log.warn("failed to clear boot exec ctx: {s}", .{@errorName(err)});
            self.cancelCryptoJobsForRequest(request_context.boot_request_id);
            // Reaped, not canceled: a canceled fetch may never get a gateway
            // completion, and with the context gone no JavaScript can observe
            // its promise, so the task ends here instead of leaking until
            // teardown.
            self.reapFetchesForRequest(request_context.boot_request_id);
            self.cleanupFetchBodiesForRequest(request_context.boot_request_id);
            self.cancelTimersForRequest(request_context.boot_request_id);
            self.core.vm.cleanupWebApiRequest(request_context.boot_request_id) catch |err|
                std.log.warn("failed to clean up boot WebAPI request state: {s}", .{@errorName(err)});
            // The context is destroyed only after the sweep: the cancels above
            // work by id and never read it again, and the paths that would have
            // finalized against `&boot_ctx.exec` now drop their work on their own
            // active-map miss. The release sequence is the one `Runtime.deinit`
            // uses for the active map.
            if (self.requests.active.fetchRemove(request_context.boot_request_id)) |removed| {
                const boot_ctx = removed.value;
                response_flow.releasePendingIngressResponse(self, boot_ctx);
                self.destroyRequestContext(boot_ctx);
            }
        }

        /// Once the boot context closed, JavaScript still running under its id,
        /// such as reactions drained by a canceled fetch's rejection turn, must
        /// not schedule new work; it gets the same error as when no boot context
        /// was installed. A request id never equals the boot id, so requests pay
        /// one comparison.
        pub fn bootIdentityClosed(self: *const Runtime, request_id: u64) bool {
            return request_id == request_context.boot_request_id and self.boot_ctx != .open;
        }
    };
}

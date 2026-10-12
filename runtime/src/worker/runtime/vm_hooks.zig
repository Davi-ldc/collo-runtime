//! What the runtime registers once it sits at its final address
//! (`attachHostRuntime`): itself as the VM's host runtime, which every
//! `collo_runtime_*` export receives back (`worker/host/adapter.zig`), the
//! owner-transition hook and the console sink, whose callbacks live here,
//! the exception-log sink, and the egress release callbacks
//! (`installEgressCallbacks` in `egress.zig`). `Runtime` declares
//! `attachHostRuntime` as its own. The VM and the exception log keep the
//! runtime's address in the first four, so `Runtime.deinit` clears them, in
//! the reverse order, before it frees anything their callbacks read.
//!
//! The callbacks run on the worker's VM thread. The engine calls the hook
//! with the JS lock held and the console sink synchronously inside the turn
//! that logged, and neither may call back into the VM (`abi.h`);
//! `exception_log` calls its sink on the same thread. The worker's boot
//! attaches the runtime before it starts the sentinel and installs seccomp
//! (`zygote/child_boot.zig`), and nothing here starts a thread.
//!
//! Both log sinks publish a line under the request id
//! `observability.ringRequestId` gives its owner.

const std = @import("std");
const bindings = @import("collo_bindings");
const worker_shared_page = @import("collo_worker_state").page;
const log_limits = @import("collo_limits").runtime_logs;
const exception_log = @import("collo_worker_js").exception_log;
const runtime_observability = @import("observability.zig");
const runtime_owner = @import("owner.zig");

const ringRequestId = runtime_observability.ringRequestId;

pub fn Methods(comptime Runtime: type) type {
    return struct {
        pub fn attachHostRuntime(self: *Runtime) !void {
            self.installEgressCallbacks();
            try self.core.vm.setHostRuntime(self);
            // A restored promise continuation runs in a window of its own
            // owner, not of the one draining the queue (`owner.zig`).
            try self.core.vm.setOwnerTransitionHook(ownerTransitionCallback, @ptrCast(self));
            // Console and uncaught-exception lines go to the shared page's log
            // ring. The sink is registered here, not in `init`, because `self`
            // has a stable address only once the caller owns the Runtime value.
            try self.core.vm.setConsoleSink(
                consoleSinkCallback,
                @ptrCast(self),
                worker_shared_page.LOG_LINE_BYTES_MAX,
                log_limits.CONSOLE_REQUEST_LINES_MAX,
                log_limits.CONSOLE_REQUEST_BYTES_MAX,
            );
            self.exception_sink_registration = .{
                .vm_identity = self.core.vm.rawIdentity(),
                .sink = exceptionLogSinkCallback,
                .ctx = @ptrCast(self),
            };
            exception_log.setRegistration(&self.exception_sink_registration);
        }

        /// Called by the engine, in pairs, around each restored promise
        /// continuation whose owner differs from the owner it interrupts:
        /// `(interrupted, restored)` before it, `(restored, interrupted)` after
        /// it (`collo_vm_set_owner_transition_hook` in `abi.h`). Each call
        /// moves the VM thread to the `entering` side's owner, as the fs fault
        /// and crypto settlements do around their sub-turns: its CPU is the
        /// entering owner's from here, the sentinel can stop a hang inside the
        /// continuation only once that owner is published, and a request's
        /// timeline needs its turn closed and reopened, or the entering request
        /// would count its own execution as I/O. No ready item is consumed: a
        /// microtask never went through the ready queue that counts them.
        ///
        /// A null side is JavaScript no exec context claims, a released
        /// registrant or a closed evaluation, which the worker owner owns
        /// (`owner.ownerOf`), so no request is charged with, or stopped for,
        /// work it does not own. The `leaving` side is the owner the previous
        /// call entered, so this call needs only the other one.
        fn ownerTransitionCallback(
            ctx: ?*anyopaque,
            leaving: ?*bindings.ExecCtx,
            entering: ?*bindings.ExecCtx,
        ) callconv(.c) void {
            _ = leaving;
            const self: *Runtime = @ptrCast(@alignCast(ctx orelse return));
            _ = runtime_owner.enter(self, runtime_owner.ownerOf(entering), .{});
        }

        fn consoleSinkCallback(
            ctx: ?*anyopaque,
            level: u8,
            flags: u8,
            request_id: u64,
            bytes: ?[*]const u8,
            len: usize,
        ) callconv(.c) void {
            const self: *Runtime = @ptrCast(@alignCast(ctx orelse return));
            const view = self.observability.metrics_view;
            // A line dropped by the per-request console budget is only counted in
            // the ring's dropped lines, which the drop marker reports; no frame is
            // published. Bit 1 means a budget drop in the sink's flags and a
            // JavaScript exception in the ring's, so the marker must not reach
            // `publishLogLine`.
            if (flags & bindings.console_line_flag_budget_dropped != 0) {
                view.countBudgetDroppedLogLine();
                return;
            }
            const payload: []const u8 = if (bytes) |b| b[0..len] else &.{};
            const log_level = std.meta.intToEnum(worker_shared_page.LogLevel, level) catch .info;
            view.publishLogLine(log_level, flags, ringRequestId(request_id), self.nowMonoNs(), payload);
        }

        fn exceptionLogSinkCallback(ctx: ?*anyopaque, request_id: u64, message: []const u8) void {
            const self: *Runtime = @ptrCast(@alignCast(ctx orelse return));
            const view = self.observability.metrics_view;
            view.publishLogLine(
                .err,
                worker_shared_page.LogLineFlags.js_exception,
                ringRequestId(request_id),
                self.nowMonoNs(),
                message,
            );
        }
    };
}

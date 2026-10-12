//! The worker's retirement: the one place that decides the worker should
//! give way to a fresh one and tells the server so. A worker never stops on
//! its own when its VM can run no JavaScript again or when none of its routes
//! can serve. It sends one `worker_retiring` notice on its control socket
//! (`common/ipc/worker_retiring.zig`) and goes on answering every request
//! that reaches it: the server, which alone knows whether a begin is still
//! on its way, takes the worker out of service and retires it once no lane
//! holds a slot of it. A begin decoded after the decision runs no JavaScript
//! and answers 503 `worker_retiring` (`serve/dispatch.zig`). Runs on the VM
//! thread.
//!
//! The decision comes from two facts other files own, which the loop reads
//! at the top of every tick (`checkRetirement`): the sentinel's fire
//! (`sentinel.zig`), which poisons the VM for good, and
//! `modules/state.zig:State.fresh_worker_may_serve`, which `modules/routes.zig`
//! sets once every route failed and one of them on an await.

const std = @import("std");
const ipc = @import("collo_ipc");
const termination = @import("../serve/termination.zig");

pub const Retirement = struct {
    /// The reason the worker first asked to retire for; null while it serves
    /// normally. Never cleared, since neither reason can be undone.
    reason: ?ipc.WorkerRetiringReason = null,
    /// The notice found the control socket full. While it holds, the loop
    /// polls the socket for room (`scheduler/uring_backend.zig`) and sends
    /// the notice once the socket turns writable (`handleControlWritable` in
    /// `scheduler/loop.zig`).
    notice_pending: bool = false,
};

pub fn Methods(comptime Runtime: type) type {
    return struct {
        /// The loop's check, at the top of every tick, of the two facts that
        /// retire the worker. The first time it finds the sentinel's fire it
        /// records that the VM is terminated, answers every request the fire
        /// left unable to finish (`termination.endAfterFire`) and asks to
        /// retire. Fails with `error.ControlPeerClosed` when the server
        /// closed the control socket, and with the send's error when the
        /// notice cannot be sent, which ends the loop: a worker that cannot
        /// ask to leave must not stay in service.
        pub fn checkRetirement(self: *Runtime) !void {
            if (!self.vm_terminated) {
                if (self.observability.sentinel.fired()) |fired| {
                    self.vm_terminated = true;
                    self.traceRuntimeEvent("worker.runtime.vm_terminated={d},{s}", .{
                        fired.owner_id,
                        @tagName(fired.cause),
                    });
                    // The notice goes out ahead of the answers, so the server
                    // stops sending begins as early as it can; the answers
                    // are written whether or not it could be sent.
                    const notice = self.requestRetirement(.vm_terminated);
                    termination.endAfterFire(self, fired);
                    try notice;
                }
            }
            if (self.modules.state.fresh_worker_may_serve)
                try self.requestRetirement(.routes_failed);
        }

        /// Records `reason` as the worker's reason to retire and sends the
        /// notice, the first time only; a later call for any reason does
        /// nothing, since the server needs one notice. A full socket keeps
        /// the notice pending. Fails as `sendRetirementNotice` does.
        pub fn requestRetirement(self: *Runtime, reason: ipc.WorkerRetiringReason) !void {
            if (self.retirement.reason != null)
                return;
            self.retirement.reason = reason;
            self.retirement.notice_pending = true;
            self.traceRuntimeEvent("worker.runtime.retiring={s}", .{@tagName(reason)});
            try self.sendRetirementNotice();
        }

        /// Sends the pending notice; does nothing when none is pending. A
        /// runtime without a control socket, as in-process tests build, has
        /// nobody to tell and drops it. The socket does not block: a full one
        /// leaves the notice pending until the socket has room. Fails with
        /// `error.ControlPeerClosed` once the server hung up, or with the
        /// send's error.
        pub fn sendRetirementNotice(self: *Runtime) !void {
            if (!self.retirement.notice_pending)
                return;
            const reason = self.retirement.reason orelse unreachable;
            const control_fd = self.core.control_fd orelse {
                self.retirement.notice_pending = false;
                return;
            };
            ipc.worker_retiring.send(control_fd, reason) catch |err| switch (err) {
                error.WouldBlock => return,
                error.PeerClosed => return error.ControlPeerClosed,
                else => return err,
            };
            self.retirement.notice_pending = false;
            self.traceRuntimeEvent("worker.runtime.retiring_sent={s}", .{@tagName(reason)});
        }
    };
}

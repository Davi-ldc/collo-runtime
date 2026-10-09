//! The sync read of the fault plane (`fault.zig`): a read such as
//! `readFileSync` of a file of the tree that has no copy in the tmpfs yet
//! faults it in here, blocking the worker's VM thread inside the turn that
//! made the read. It runs no JavaScript.
//!
//! Two properties of the wait must hold, and `faultSync` says why: it never
//! outlives the request's deadline, and a response to another fault read
//! during it completes that fault at once (`fault_completion.zig`) instead
//! of being dropped.

const std = @import("std");
const fault_limits = @import("collo_limits").fs_fault;
const ipc = @import("collo_ipc");
const worker_fs = @import("index.zig");
const modules_routes = @import("../modules/routes.zig");
const fault = @import("fault.zig");
const fault_completion = @import("fault_completion.zig");
const copies = @import("copies.zig");

/// Faults in a file for a sync read such as `readFileSync`. It sends one
/// request, or joins an in-flight async fault of the same path and settles
/// that fault's waiters through `completeFault`, then blocks the VM thread
/// with ppoll on the fault channel until the response or the request's
/// deadline, and copies the file through `materializeEntry` as the async
/// path does. On success the binding reads the copy locally, so sync and
/// async reads return the same bytes.
///
/// A response to another fault that arrives during the wait goes through
/// `completeFault` at once, traced as `worker.fs_fault.stashed`: its file
/// is copied now and its waiters settle on the loop after this read
/// returns. A timeout, a closed channel or a non-ok response fails the
/// read, and the wait never outlives the deadline, so an uncaught timeout
/// reaches `writeException` past the deadline and the request answers 504.
/// A context without a deadline, such as the boot context when the host
/// set no init deadline, waits at most `modules_routes.module_eval_budget_ns`.
pub fn faultSync(runtime: anytype, request_id: u64, normalized: []const u8) !void {
    const state: *fault.State = &runtime.fs_fault;
    const view = worker_fs.indexView() orelse return error.FsFaultUnavailable;
    const fault_fd = worker_fs.faultFd() orelse return error.FsFaultUnavailable;

    const key = worker_fs.deployKey(normalized) orelse return error.InvalidFsFaultPath;
    if (key.len == 0 or key.len > ipc.fs_fault.max_path_bytes)
        return error.InvalidFsFaultPath;
    const entry = view.lookup(key) orelse return error.FsFaultNotFound;
    // The same size bounds as `schedule`.
    if (view.entrySizeAt(entry) > fault_limits.max_fault_file_bytes)
        return error.FsFaultFileTooLarge;
    if (view.entrySizeAt(entry) > copies.materializeBudgetBytes())
        return error.FsFaultFileTooLarge;

    const identity = try fault.faultIdentity(runtime, request_id, key);
    const request = identity.request;
    const deadline = if (request.exec.deadline_monotonic_ns != 0)
        request.exec.deadline_monotonic_ns
    else
        runtime.nowMonoNs() +| modules_routes.module_eval_budget_ns;

    // An in-flight async fault of the same path is joined instead of sending
    // a second request.
    var target_id: u64 = 0;
    var joined = false;
    if (state.faults_by_path.get(key)) |existing_id| {
        if (state.tasks.getPtr(existing_id)) |existing| {
            if (existing.done) {
                // The fault finished but its completion has not run yet, so
                // its outcome answers this read.
                switch (existing.outcome) {
                    .materialized => return,
                    else => return error.FsFaultFailed,
                }
            }
            target_id = existing_id;
            joined = true;
        } else {
            _ = state.faults_by_path.remove(key);
        }
    }

    if (!joined) {
        const fault_id = state.next_fault_id;
        state.next_fault_id +%= 1;
        if (state.next_fault_id == 0)
            state.next_fault_id = 1;
        try ipc.sendFsFaultRequest(fault_fd, runtime.core.dispatch_recv_scratch, .{
            .fault_id = fault_id,
            .request_id = identity.wire_request_id,
            .request_generation = identity.wire_request_generation,
            .worker_id = identity.wire_worker_id,
            .worker_generation = identity.wire_worker_generation,
            .path = key,
        });
        target_id = fault_id;
        runtime.traceRuntimeEvent("worker.fs_fault.sent={s}", .{key});
    }

    while (true) {
        const now = runtime.nowMonoNs();
        if (now >= deadline)
            return error.FsFaultSyncTimeout;
        const remaining = deadline - now;
        const timeout = std.posix.timespec{
            .sec = @intCast(remaining / std.time.ns_per_s),
            .nsec = @intCast(remaining % std.time.ns_per_s),
        };
        var pollfds = [1]std.posix.pollfd{.{
            .fd = fault_fd,
            .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR,
            .revents = 0,
        }};
        const ready = std.posix.ppoll(&pollfds, &timeout, null) catch |err| switch (err) {
            // The deadline is absolute and the timeout is recomputed on each
            // pass, so a restart after EINTR cannot stretch the wait.
            error.SignalInterrupt => continue,
            else => return err,
        };
        if (ready == 0)
            return error.FsFaultSyncTimeout;
        if ((pollfds[0].revents & std.posix.POLL.NVAL) != 0)
            return error.FsFaultChannelClosed;
        if ((pollfds[0].revents & std.posix.POLL.IN) == 0)
            return error.FsFaultChannelClosed;

        var packet = ipc.recvPacketWithFdsScratch(
            runtime.core.allocator,
            fault_fd,
            runtime.core.dispatch_recv_scratch,
        ) catch |err| switch (err) {
            // Spurious readiness on the nonblocking end: poll again with the
            // remaining time.
            error.WouldBlock => continue,
            error.PeerClosed => return error.FsFaultChannelClosed,
            else => return err,
        };
        // The decoder frees the packet on every path, so it must not be
        // freed again here. A malformed packet is dropped, as in
        // `collectResponse`.
        var response = ipc.fs_fault.decodeResponseFromPacket(&packet) catch |err| {
            std.log.warn("dropping malformed fs fault response during sync wait: {s}", .{@errorName(err)});
            continue;
        };
        defer response.deinit();

        if (response.response.fault_id != target_id) {
            // A response to an async fault: its file is copied and its
            // completion queued now, and the loop settles its waiters after
            // this read returns, so the response is not lost.
            if (state.tasks.getPtr(response.response.fault_id)) |stashed|
                runtime.traceRuntimeEvent("worker.fs_fault.stashed={s}", .{stashed.path});
            fault_completion.completeFault(runtime, &response);
            continue;
        }

        if (joined) {
            fault_completion.completeFault(runtime, &response);
            const task = state.tasks.getPtr(target_id) orelse return error.FsFaultFailed;
            switch (task.outcome) {
                .materialized => return,
                else => return error.FsFaultFailed,
            }
        }

        if (response.response.status != .ok) {
            return switch (response.response.status) {
                .not_found => error.FsFaultNotFound,
                else => error.FsFaultFailed,
            };
        }
        const memfd = response.takeFileFd() orelse return error.FsFaultFailed;
        defer std.posix.close(memfd);
        if (copies.materializeEntry(entry, key, memfd, runtime.nowMonoNs())) |message| {
            std.log.warn("sync fs fault failed path={s}: {s}", .{ key, message });
            return error.FsFaultFailed;
        }
        runtime.traceRuntimeEvent("worker.fs_fault.settled={s}", .{key});
        return;
    }
}

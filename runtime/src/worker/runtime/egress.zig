//! The egress domain of the worker runtime: `Egress` holds the worker's
//! egress state (`egress/state.zig`, which also gives the teardown order) and
//! the completion eventfd WorkerInit brings. The files under `worker/egress/`
//! are the domain's operations: they take `*Runtime`, and `Runtime` declares
//! the ones the rest of the worker calls as its own (`root.zig`). It belongs
//! to the worker's VM thread.

const std = @import("std");
const ipc = @import("collo_ipc");
const Runtime = @import("root.zig").Runtime;
const egress_state = @import("../egress/state.zig");
const egress_body = @import("../egress/body/root.zig");
const response_flow = @import("../serve/response.zig");

pub const Egress = struct {
    state: egress_state.State,
    /// Written when the worker frees request payload room in the shared ring
    /// while a lane waits for it (`scheduler/loop.zig:requestPayloadReaders`);
    /// `Runtime.init` says why this channel is required. Owned here, and
    /// closed by `deinitAfterBodiesReleased` unless the gateway endpoint holds
    /// the same descriptor and closes it itself.
    completion_eventfd: std.posix.fd_t,

    pub fn init(completion_eventfd: std.posix.fd_t, shared_fds: ?*ipc.egress_shared.RawFds) !Egress {
        return .{
            .state = try egress_state.State.init(shared_fds),
            .completion_eventfd = completion_eventfd,
        };
    }

    pub fn deinitTasks(self: *Egress, allocator: std.mem.Allocator) void {
        self.state.deinitTasks(allocator);
    }

    pub fn deinitAfterBodiesReleased(self: *Egress, allocator: std.mem.Allocator) void {
        const completion_eventfd_owned_by_endpoint = if (self.state.shared) |*endpoint|
            endpoint.completion_eventfd == self.completion_eventfd
        else
            false;

        self.state.deinitAfterBodiesReleased(allocator);

        if (self.completion_eventfd >= 0 and !completion_eventfd_owned_by_endpoint)
            std.posix.close(self.completion_eventfd);
        self.completion_eventfd = -1;
    }

    /// Teardown for a runtime whose `init` failed after this domain was
    /// built, before any fetch or body could exist.
    pub fn deinitFailedInit(self: *Egress, allocator: std.mem.Allocator) void {
        std.debug.assert(self.state.tasks.count() == 0);
        std.debug.assert(self.state.bodies.count() == 0);
        self.state.deinitTasks(allocator);
        self.deinitAfterBodiesReleased(allocator);
    }

    pub fn hasSharedEndpoint(self: *const Egress) bool {
        return self.state.shared != null;
    }
};

/// Runs the `fetch_body_ready` item of `body_id`: the response stream that
/// forwards the body takes its chunk (`serve/response.zig`), or else the
/// body's reader is settled (`egress/body/ready.zig`).
pub fn executeFetchBodyReady(runtime: *Runtime, body_id: u64) !void {
    // This consumes the readiness the current stamp describes; the next
    // gateway packet stamps a new one, since handlers set the stamp only
    // when it is zero.
    if (runtime.egress.state.bodies.get(body_id)) |body|
        body.ready_at_mono_ns = 0;
    if (try response_flow.executeFetchBodyStreamReady(runtime, body_id))
        return;
    try egress_body.executeReady(runtime, body_id);
}

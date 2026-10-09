//! A worker's egress state: its fetch tasks, its fetch body views and their
//! decoders, the per-request fetch counts, the pending-upload queue, the
//! mapped gateway endpoint and the callbacks that return body-pool extents.
//! `runtime/egress.zig` holds it beside the scheduler, request and VM state
//! the worker runtime owns, and only the worker's event loop thread touches
//! it.
//!
//! The worker is attached while it holds an endpoint and detached otherwise.
//! It boots attached when WorkerInit carries a session's regions, detaches
//! when its gateway closes (`gateway_runtime.disconnect`), and attaches again
//! when the server sends the half of a new session (`attach`). Every
//! WorkerInit carries the worker's wake descriptors, and the worker ring polls
//! their completion eventfd and liveness pipe from fixed slots for the
//! worker's whole life, because a restricted ring can never register another
//! file (`common/io/restricted_uring.zig`). The server builds every session of
//! the worker on the same wake set (`egress_shared.WakeSet`), and `attach`
//! takes only a half whose liveness pipe is the one WorkerInit carried.
//!
//! Teardown runs in a fixed order: `deinitTasks`, which drops each task's
//! reference on its response body, then the release of every body
//! (`body/cleanup.zig` `releaseAllForShutdown`), then
//! `deinitAfterBodiesReleased`.

const std = @import("std");
const bindings = @import("collo_bindings");
const ipc = @import("collo_ipc");
const runtime_types = @import("../runtime/types.zig");
const task_mod = @import("task.zig");
const encoded_body = @import("collo_egress_core").encoded_body;
const fetch_body = @import("collo_egress_core").fetch_body;

pub const Task = task_mod.Task;
pub const Body = fetch_body.Body;
pub const BodyDecoder = encoded_body.Decoder;

/// Where borrowed body-pool extents go back to the gateway. `bind` points it at
/// the runtime (`gateway_control.bindBodyPoolRelease`); until then a release
/// does nothing.
pub const BodyPoolReleaseContext = struct {
    context: ?*anyopaque = null,
    release_fn: *const fn (?*anyopaque, u64, usize) void = noop,

    pub fn bind(
        self: *BodyPoolReleaseContext,
        context: ?*anyopaque,
        release_fn: *const fn (?*anyopaque, u64, usize) void,
    ) void {
        self.context = context;
        self.release_fn = release_fn;
    }

    pub fn release(context: ?*anyopaque, seq: u64, len: usize) void {
        const self: *BodyPoolReleaseContext = @ptrCast(@alignCast(context orelse return));
        self.release_fn(self.context, seq, len);
    }

    fn noop(_: ?*anyopaque, _: u64, _: usize) void {}
};

/// Where the credits of released chunks go, bound like
/// `BodyPoolReleaseContext`. Worker chunks carry credit `.none`
/// (`gateway_control.releaseBodyCredit`).
pub const BodyCreditReleaseContext = struct {
    context: ?*anyopaque = null,
    release_fn: *const fn (?*anyopaque, fetch_body.Credit) void = noop,

    pub fn bind(
        self: *BodyCreditReleaseContext,
        context: ?*anyopaque,
        release_fn: *const fn (?*anyopaque, fetch_body.Credit) void,
    ) void {
        self.context = context;
        self.release_fn = release_fn;
    }

    pub fn release(context: *BodyCreditReleaseContext, credit: fetch_body.Credit) void {
        context.release_fn(context.context, credit);
    }

    fn noop(_: ?*anyopaque, _: fetch_body.Credit) void {}
};

/// A pipe by device and inode, which every descriptor of the pipe shares, so
/// two descriptors with equal identities are ends of one pipe.
pub const PipeIdentity = struct {
    device: u64,
    inode: u64,

    fn of(fd: std.posix.fd_t) !PipeIdentity {
        const stat = try std.posix.fstat(fd);
        return .{ .device = @intCast(stat.dev), .inode = @intCast(stat.ino) };
    }

    fn eql(self: PipeIdentity, other: PipeIdentity) bool {
        return self.device == other.device and self.inode == other.inode;
    }
};

pub const State = struct {
    /// The mapped gateway endpoint while the worker is attached. It owns the
    /// session's wake descriptors along with its mappings.
    shared: ?ipc.egress_shared.Endpoint = null,
    /// The wake descriptors WorkerInit carried for a launch without a
    /// session, held until the first `attach` gives the endpoint a session's
    /// own; null once the worker has had an endpoint, and in a state built
    /// without them.
    detached_wake: ?ipc.egress_shared.WakeFds = null,
    /// The liveness pipe of the wake descriptors WorkerInit carried, which
    /// the worker ring watches for the worker's whole life; null in a state
    /// built without them. `attach` takes only a half built on it.
    boot_liveness_pipe: ?PipeIdentity = null,
    body_pool_release_context: BodyPoolReleaseContext = .{},
    body_credit_release_context: BodyCreditReleaseContext = .{},
    tasks: std.AutoHashMapUnmanaged(u64, *Task) = .{},
    bodies: std.AutoHashMapUnmanaged(u64, *Body) = .{},
    /// Streaming decoders for bodies the gateway sends encoded, keyed by the
    /// source body id the gateway's chunks name, never a tee branch's. A
    /// decoder implies its body is in `bodies`: every path that removes a body
    /// removes its decoder in the same step.
    body_decoders: std.AutoHashMapUnmanaged(u64, *BodyDecoder) = .{},
    /// Set whenever a release-queue entry is written and cleared by
    /// `gateway_control.flushBodyPoolReleases`, so one command-eventfd write
    /// covers a whole batch.
    releases_need_notify: bool = false,
    /// Fetch ids that still owe the gateway a start packet or upload extents,
    /// in round-robin order: each pump pass takes the whole list, and an
    /// unfinished task parks again at the tail. An entry is checked when it is
    /// taken, and a finished, canceled or removed task is skipped, so removals
    /// need no bookkeeping here.
    pending_uploads: std.ArrayListUnmanaged(u64) = .{},
    /// A body-pool release failed while the worker was attached
    /// (`gateway_control.noteBodyPoolChunkReleased`). The pool's release queue
    /// is shared with the gateway, so a failure there is the session's fault:
    /// the event loop detaches the worker once the handler that met it
    /// returns (`gateway_runtime.detachAfterFailedRelease`), and the detach
    /// clears the flag.
    body_pool_release_failed: bool = false,
    next_fetch_id: u64 = 1,
    next_body_id: u64 = 1,
    /// Set when a full ready queue dropped a `fetch_completion` or a
    /// `fetch_body_ready` item; the collect pass for that kind then rescans.
    fetch_task_rescan_needed: bool = false,
    fetch_body_rescan_needed: bool = false,

    /// Takes the worker's egress descriptors WorkerInit carried, when
    /// `shared_fds` is given: records the liveness pipe of its wake
    /// descriptors, maps the session's endpoint when the regions came and
    /// holds the wake descriptors in `detached_wake` when none did. It
    /// reserves the task table for `limits.max_fetches_per_worker`.
    /// The descriptors leave `shared_fds` once they check out, and a later
    /// failure closes them. Fails with `error.InvalidEgressSharedEndpoint`
    /// for missing wake descriptors or some regions without the rest, as
    /// `attach` does when `fstat` fails on the liveness pipe or the endpoint
    /// cannot be mapped, with `error.CapacityTooLarge`, or with
    /// `error.OutOfMemory`.
    pub fn init(
        allocator: std.mem.Allocator,
        limits: runtime_types.RuntimeLimits,
        shared_fds: ?*ipc.egress_shared.RawFds,
    ) !State {
        var boot_liveness_pipe: ?PipeIdentity = null;
        var shared: ?ipc.egress_shared.Endpoint = null;
        var detached_wake: ?ipc.egress_shared.WakeFds = null;
        if (shared_fds) |fds| {
            if (!fds.wakeFds().isValid())
                return error.InvalidEgressSharedEndpoint;
            boot_liveness_pipe = try PipeIdentity.of(fds.liveness_fd);
            switch (fds.regionCount()) {
                0 => {
                    detached_wake = fds.wakeFds();
                    fds.* = .{};
                },
                ipc.egress_shared.region_fd_count => shared = try mapWorkerHalf(fds),
                else => return error.InvalidEgressSharedEndpoint,
            }
        }
        errdefer if (shared) |*endpoint| endpoint.deinit();
        errdefer if (detached_wake) |*wake| wake.close();

        var tasks = std.AutoHashMapUnmanaged(u64, *Task){};
        errdefer tasks.deinit(allocator);
        try tasks.ensureTotalCapacity(allocator, try hashCapacity(limits.max_fetches_per_worker));

        var bodies = std.AutoHashMapUnmanaged(u64, *Body){};
        errdefer {
            var body_it = bodies.iterator();
            while (body_it.next()) |entry|
                entry.value_ptr.*.releaseAfterQueuedResourcesReleased(allocator);
            bodies.deinit(allocator);
        }

        return .{
            .shared = shared,
            .detached_wake = detached_wake,
            .boot_liveness_pipe = boot_liveness_pipe,
            .tasks = tasks,
            .bodies = bodies,
        };
    }

    /// Maps the worker half `fds` of a session the server attached after the
    /// worker's gateway was replaced (`ipc.egress_attach.decode`), with the
    /// checks of the boot mapping, and takes the fds once the mapping
    /// succeeds; on failure `fds` keeps every descriptor. The half brings the
    /// session's own wake descriptors, so the ones a detached boot held
    /// close. The worker must be detached. Fails with
    /// `error.EgressAttachWithoutWakeSet` in a state built without wake
    /// descriptors, since its ring watches no liveness pipe, with
    /// `error.EgressAttachLivenessPipeMismatch` when the half's liveness pipe
    /// is not the one WorkerInit carried, with the error of `fstat` on it, or
    /// when the endpoint cannot be mapped or its rings disagree on the
    /// session. The server is the only sender, so each failure is a server
    /// bug.
    pub fn attach(self: *State, fds: *ipc.egress_shared.RawFds) !void {
        std.debug.assert(self.shared == null);
        std.debug.assert(self.body_decoders.count() == 0);
        const boot_pipe = self.boot_liveness_pipe orelse return error.EgressAttachWithoutWakeSet;
        // The completion eventfd cannot be checked the same way: every
        // eventfd shares one anonymous inode.
        const pipe = try PipeIdentity.of(fds.liveness_fd);
        if (!pipe.eql(boot_pipe))
            return error.EgressAttachLivenessPipeMismatch;
        self.shared = try mapWorkerHalf(fds);
        if (self.detached_wake) |*wake|
            wake.close();
        self.detached_wake = null;
    }

    /// The wake descriptors the worker holds now: its endpoint's while
    /// attached, `detached_wake` while it has had no session, null in a state
    /// built without them. The worker ring registers their completion eventfd
    /// and liveness pipe once, at boot (`scheduler/resources.zig`), and every
    /// later session of the worker carries the same two files.
    pub fn wakeFds(self: *const State) ?ipc.egress_shared.WakeFds {
        if (self.shared) |*endpoint| {
            return .{
                .command_eventfd = endpoint.command_eventfd,
                .completion_eventfd = endpoint.completion_eventfd,
                .liveness_fd = endpoint.liveness_fd,
                .peer_liveness_fd = endpoint.peer_liveness_fd,
            };
        }
        return self.detached_wake;
    }

    /// Unmaps the endpoint and closes its descriptors, which detaches the
    /// worker. Closing the worker's end of the peer liveness pipe tells the
    /// gateway, as the worker's exit would. Decoders must be gone first,
    /// since they return their extents into the body pool's release queue.
    pub fn releaseEndpoint(self: *State) void {
        std.debug.assert(self.body_decoders.count() == 0);
        if (self.shared) |*endpoint|
            endpoint.deinit();
        self.shared = null;
        self.releases_need_notify = false;
    }

    pub fn deinitTasks(self: *State, allocator: std.mem.Allocator) void {
        var task_it = self.tasks.iterator();
        while (task_it.next()) |entry| {
            entry.value_ptr.*.deinit(allocator);
            allocator.destroy(entry.value_ptr.*);
        }
        self.tasks.deinit(allocator);
    }

    /// Frees the tables, unmaps the endpoint and closes the wake descriptors
    /// once every body was released.
    pub fn deinitAfterBodiesReleased(self: *State, allocator: std.mem.Allocator) void {
        std.debug.assert(self.bodies.count() == 0);
        std.debug.assert(self.body_decoders.count() == 0);
        if (self.bodies.count() != 0) {
            // A body left here means request cleanup broke its contract, which
            // Debug and ReleaseSafe builds catch with the assert above. FIXME:
            // under ReleaseFast that assert lets the optimizer assume the
            // table is empty and delete this fallback, so production builds
            // may never release the stragglers.
            std.log.err("egress bodies still registered during state shutdown count={d}", .{
                self.bodies.count(),
            });
            releaseRemainingBodies(self, allocator);
        }
        // Decoders go before the endpoint: their pending extents return
        // through the bound callback into the release queue, which must still
        // be mapped.
        self.removeAllBodyDecoders(allocator);
        self.releaseEndpoint();
        if (self.detached_wake) |*wake|
            wake.close();
        self.detached_wake = null;
        self.body_decoders.deinit(allocator);
        self.bodies.deinit(allocator);
        self.pending_uploads.deinit(allocator);
    }

    /// Drops the decoder of `body_id`, returning its pending pool extents
    /// through the release queue. Returns false when there was none.
    pub fn removeBodyDecoder(self: *State, allocator: std.mem.Allocator, body_id: u64) bool {
        const removed = self.body_decoders.fetchRemove(body_id) orelse return false;
        removed.value.deinit(allocator);
        allocator.destroy(removed.value);
        return true;
    }

    /// Drops every decoder, for a gateway disconnect or state teardown. It must
    /// run before the endpoint is unmapped, so the pending extents still reach
    /// the release queue.
    pub fn removeAllBodyDecoders(self: *State, allocator: std.mem.Allocator) void {
        var iterator = self.body_decoders.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.*.deinit(allocator);
            allocator.destroy(entry.value_ptr.*);
        }
        self.body_decoders.clearRetainingCapacity();
    }

    /// The next body identity under `request`'s id and generation, where
    /// `request` is a `RequestContext`. Body ids wrap and skip zero.
    pub fn nextBodyIdentity(
        self: *State,
        request: anytype,
        fetch_id: u64,
    ) bindings.FetchBodyIdentity {
        const body_id = self.next_body_id;
        self.next_body_id +%= 1;
        if (self.next_body_id == 0)
            self.next_body_id = 1;

        return .{
            .request_id = request.exec.request_id,
            .request_generation = request.request_generation,
            .fetch_id = fetch_id,
            .body_id = body_id,
        };
    }
};

/// Maps a worker half and checks that its four regions name one session,
/// taking the fds only on success (`mapEndpointTakeForWorker`).
fn mapWorkerHalf(fds: *ipc.egress_shared.RawFds) !ipc.egress_shared.Endpoint {
    var endpoint = try ipc.egress_shared.mapEndpointTakeForWorker(fds);
    errdefer endpoint.deinit();
    try endpoint.validateConsistentSession();
    return endpoint;
}

fn releaseRemainingBodies(self: *State, allocator: std.mem.Allocator) void {
    var iterator = self.bodies.iterator();
    while (iterator.next()) |entry| {
        // The cleanup contract already broke, so nothing is assumed: queued
        // chunks are released and tee links severed before the final release,
        // which requires both and would otherwise leak the chunks' bytes,
        // credits and extents.
        entry.value_ptr.*.releaseQueuedChunksCallback(
            allocator,
            &self.body_credit_release_context,
            BodyCreditReleaseContext.release,
        );
        entry.value_ptr.*.detachTeeLinks(allocator);
        entry.value_ptr.*.releaseAfterQueuedResourcesReleased(allocator);
    }
    self.bodies.clearRetainingCapacity();
}

fn hashCapacity(value: usize) !u32 {
    if (value > std.math.maxInt(u32))
        return error.CapacityTooLarge;
    return @intCast(value);
}

//! A worker's egress state: the fetches the gateway may still count, the
//! fetch tasks waiting for an answer, the fetch body views with their
//! decoders, the pending-upload queue and the mapped gateway endpoint.
//! `runtime/egress.zig` holds it beside the scheduler, request and VM state
//! the worker runtime owns, and only the worker's VM thread touches it.
//!
//! The worker is attached while it holds an endpoint and detached otherwise.
//! It boots attached when WorkerInit carries a session's regions, detaches
//! when its gateway closes (`gateway_runtime.disconnectWithReason`) or when
//! the session breaks in a way only a gateway defect causes
//! (`gateway_runtime.detachForGatewayFault`), and attaches again when the
//! server sends the half of a new session (`attach`).
//! A worker whose definition grants some route network access gets its wake
//! descriptors with WorkerInit; while attached, the event loop polls the
//! endpoint's completion eventfd and liveness pipe. A worker launched without
//! a session holds the wake descriptors WorkerInit carried until its first
//! attach, since closing its end of the peer liveness pipe would tell a
//! gateway it exited (`egress_shared/session_fds.zig`). A worker without a
//! grant gets no egress descriptor at all: it never holds a session and
//! refuses every fetch before anything leaves (`fetch_runtime.refusal`).
//!
//! `fetches` holds every fetch the gateway may still count, from
//! `fetch_runtime.schedule` until the worker reads the fetch's terminal
//! packet (its body end, its error or the acknowledgment of its stop), until
//! a start that never left ends in the worker, or until the session goes. The
//! gateway counts a fetch from its start until it publishes that packet, so
//! this count never trails the gateway's, and a worker held to
//! `fetches_per_worker_max` here never meets the gateway's session cap. The
//! same entry holds what a pooled upload holds in the gateway, its announced
//! length plus the copies of its start
//! (`ipc.fetch_limits.pooledStartHeldBytes`), which the gateway counts on
//! the same lifetime against
//! `ipc.fetch_limits.request_body_pooled_in_flight_bytes_max`, and the
//! request whose record the fetch's body bytes enter.
//!
//! Teardown runs in a fixed order: `deinitTasks`, which drops each task's
//! reference on its response body, then the release of every body
//! (`body/cleanup.zig:releaseAllForShutdown`), then
//! `deinitAfterBodiesReleased`.

const std = @import("std");
const bindings = @import("collo_bindings");
const ipc = @import("collo_ipc");
const request_context = @import("collo_worker_request").context;
const ready_queue = @import("../scheduler/queue.zig");
const task_mod = @import("task.zig");
const body_mod = @import("body/body.zig");

pub const Task = task_mod.Task;
pub const Body = body_mod.Body;

/// Whether the worker's definition grants some route network access, which
/// WorkerInit's `flag_egress` says and its wake descriptors show.
pub const Grant = enum { granted, none };

/// A pipe named by device and inode, which every descriptor of it shares.
pub const PipeIdentity = struct {
    device: u64,
    inode: u64,

    /// The identity of the pipe `fd` is an end of. Fails as `fstat` does.
    pub fn of(fd: std.posix.fd_t) !PipeIdentity {
        const stat = try std.posix.fstat(fd);
        return .{ .device = @intCast(stat.dev), .inode = @intCast(stat.ino) };
    }

    pub fn eql(self: PipeIdentity, other: PipeIdentity) bool {
        return self.device == other.device and self.inode == other.inode;
    }
};

/// One fetch the gateway may still count (`State.fetches`).
pub const Fetch = struct {
    /// The request whose record this fetch's body bytes enter, under the
    /// generation that started it.
    request_id: u64,
    request_generation: u64,
    /// What its pooled upload holds in the gateway once the start left, its
    /// announced length plus the copies of its start, or 0.
    upload_reserved_bytes: u64 = 0,
    /// The start is in the command ring, so the gateway answers for the
    /// fetch, and a stop must reach it.
    start_sent: bool = false,
    /// The worker sent its one stop for the fetch (`task_runtime.stopFetch`).
    stop_sent: bool = false,
};

pub const State = struct {
    /// The mapped gateway endpoint while the worker is attached. It owns the
    /// session's wake descriptors along with its mappings.
    shared: ?ipc.egress_shared.Endpoint = null,
    /// The wake descriptors WorkerInit carried for a launch without a
    /// session, held until the first `attach` gives the endpoint a session's
    /// own; null once the worker has had an endpoint, and for a worker
    /// without a grant.
    detached_wake: ?ipc.egress_shared.WakeFds = null,
    /// The liveness pipe of the wake descriptors WorkerInit carried, null for
    /// a worker without a grant. The server builds every session of a worker
    /// on its one wake set (`session_fds.zig:WakeSet`), so a session whose
    /// liveness pipe is another is a server bug, such as a session sent to
    /// the wrong worker's socket, which would let this worker read another
    /// worker's responses; `attach` refuses it.
    boot_liveness_pipe: ?PipeIdentity = null,
    fetches: std.AutoHashMapUnmanaged(u64, Fetch) = .{},
    /// The sum of every fetch's `upload_reserved_bytes`, never above
    /// `ipc.fetch_limits.request_body_pooled_in_flight_bytes_max`.
    upload_reserved_bytes: u64 = 0,
    /// A pooled start parked because the reservations had no room for it, so
    /// a later pooled start parks behind it instead of taking room first.
    /// The upload pump clears it before each pass, and each start that still
    /// finds no room sets it again (`upload_runtime.zig`).
    upload_room_waiter: bool = false,
    tasks: std.AutoHashMapUnmanaged(u64, *Task) = .{},
    /// `fetch_completion` items still in the ready queue whose task was
    /// destroyed before they popped (`task_runtime.destroyTask`). Each keeps
    /// its place in the queue until it pops, so the tasks and these items
    /// together stay within `fetches_per_worker_max`
    /// (`fetch_runtime.schedule`), and the queue holds at most that many
    /// completion items.
    completion_ready_orphans: u32 = 0,
    /// Every body view, by body id, holding the table's reference on each
    /// (`body/root.zig`).
    bodies: std.AutoHashMapUnmanaged(u64, *Body) = .{},
    /// `fetch_body_ready` items still in the ready queue whose body left
    /// `bodies` before they popped (`body/cleanup.zig:removeFromTable`). The
    /// bodies and these items together stay within
    /// `fetch_bodies_per_worker_max` (`body/register.zig`), and the queue
    /// holds at most that many body items.
    body_ready_orphans: u32 = 0,
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
    /// Set while a detach runs (`gateway_runtime.disconnectWithReason`); a
    /// failed write met inside it, which would detach again, does nothing.
    detach_in_progress: bool = false,
    /// The worker detached on its own, on a packet, a ring or a pool state
    /// only a gateway defect produces (`gateway_runtime.detachForGatewayFault`).
    /// No session replaces such a one, so the worker asks to be retired
    /// (`runtime/retirement.zig`). Never cleared, as the notice is sent once.
    detached_for_gateway_fault: bool = false,
    next_fetch_id: u64 = 1,
    next_body_id: u64 = 1,

    /// Takes the worker's egress descriptors WorkerInit carried. None, as
    /// `shared_fds` null or empty brings, makes a worker without a grant.
    /// Otherwise it maps the session's endpoint when the regions came and
    /// holds the wake descriptors in `detached_wake` when none did. The
    /// descriptors leave `shared_fds` once they check out. Fails with
    /// `error.InvalidEgressSharedEndpoint` for regions without wake
    /// descriptors, an incomplete wake set or some regions without the rest,
    /// as `fstat` does on the liveness pipe, or as `attach` does when the
    /// endpoint cannot be mapped.
    pub fn init(shared_fds: ?*ipc.egress_shared.RawFds) !State {
        const granted_fds: ?*ipc.egress_shared.RawFds = if (shared_fds) |fds|
            (if (fds.isEmpty()) null else fds)
        else
            null;
        const fds = granted_fds orelse return .{};
        const wake = fds.wakeFds();
        if (!wake.isValid())
            return error.InvalidEgressSharedEndpoint;
        const liveness_pipe = try PipeIdentity.of(wake.liveness_fd);
        switch (fds.regionCount()) {
            0 => {
                fds.* = .{};
                return .{ .detached_wake = wake, .boot_liveness_pipe = liveness_pipe };
            },
            ipc.egress_shared.region_fd_count => return .{
                .shared = try mapWorkerHalf(fds),
                .boot_liveness_pipe = liveness_pipe,
            },
            else => return error.InvalidEgressSharedEndpoint,
        }
    }

    /// Maps the worker half `fds` of a session the server attached after the
    /// worker's gateway was replaced (`ipc.egress_attach.decode`), with the
    /// checks of the boot mapping, and takes the fds once the mapping
    /// succeeds; on failure `fds` keeps every descriptor. The half brings the
    /// session's own wake descriptors, which the loop polls from then on, so
    /// the ones a detached boot held close. The worker must be detached.
    /// Fails with `error.EgressNotGranted` for a worker without a grant,
    /// `error.EgressAttachLivenessPipeMismatch` for a half whose liveness
    /// pipe is not the one WorkerInit carried (`boot_liveness_pipe`), or when
    /// the endpoint cannot be mapped or its rings disagree on the session.
    /// The server is the only sender, so each failure is a server bug.
    pub fn attach(self: *State, fds: *ipc.egress_shared.RawFds) !void {
        std.debug.assert(self.shared == null);
        try self.checkAttach(fds);
        self.shared = try mapWorkerHalf(fds);
        if (self.detached_wake) |*detached|
            detached.close();
        self.detached_wake = null;
    }

    /// The checks `attach` makes before it maps anything, which change no
    /// state, so a caller can refuse a half before it detaches the session
    /// the worker holds.
    pub fn checkAttach(self: *const State, fds: *const ipc.egress_shared.RawFds) !void {
        const boot_liveness_pipe = self.boot_liveness_pipe orelse return error.EgressNotGranted;
        const wake = fds.wakeFds();
        if (!wake.isValid())
            return error.InvalidEgressSharedEndpoint;
        if (!boot_liveness_pipe.eql(try PipeIdentity.of(wake.liveness_fd)))
            return error.EgressAttachLivenessPipeMismatch;
    }

    /// Whether the worker's definition grants some route network access: it
    /// does exactly when WorkerInit brought the wake descriptors.
    pub fn grant(self: *const State) Grant {
        return if (self.boot_liveness_pipe != null) .granted else .none;
    }

    /// Unmaps the endpoint and closes its descriptors, which detaches the
    /// worker. Closing the worker's end of the peer liveness pipe tells the
    /// gateway, as the worker's exit would. Every decoder must be gone
    /// first, since decoders return their extents into the body pool's
    /// release queue. The fetches and their upload reservations go with the
    /// session: the gateway of the next one counts from nothing.
    pub fn releaseEndpoint(self: *State) void {
        if (self.shared) |*endpoint|
            endpoint.deinit();
        self.shared = null;
        self.releases_need_notify = false;
        self.fetches.clearRetainingCapacity();
        self.upload_reserved_bytes = 0;
        self.upload_room_waiter = false;
    }

    /// Counts the fetch `fetch_id` of `request` from now; the caller made
    /// room for the entry (`ensureUnusedCapacity` on `fetches`), so counting
    /// cannot fail after the task exists.
    pub fn beginFetch(self: *State, fetch_id: u64, request: *const request_context.RequestContext) void {
        self.fetches.putAssumeCapacityNoClobber(fetch_id, .{
            .request_id = request.exec.request_id,
            .request_generation = request.request_generation,
        });
    }

    /// Stops counting `fetch_id` and gives back its upload reservation; an id
    /// the table does not hold, as one a late or hostile packet names,
    /// changes nothing.
    pub fn endFetch(self: *State, fetch_id: u64) void {
        const removed = self.fetches.fetchRemove(fetch_id) orelse return;
        std.debug.assert(removed.value.upload_reserved_bytes <= self.upload_reserved_bytes);
        self.upload_reserved_bytes -= removed.value.upload_reserved_bytes;
    }

    /// The bytes a pooled start may still reserve on this session.
    pub fn uploadRoom(self: *const State) u64 {
        const in_flight_max: u64 = ipc.fetch_limits.request_body_pooled_in_flight_bytes_max;
        std.debug.assert(self.upload_reserved_bytes <= in_flight_max);
        return in_flight_max - self.upload_reserved_bytes;
    }

    /// Records that the start of `fetch`, counted in `fetches`, left the
    /// worker, reserving `reserved_bytes` for its pooled upload (0 for an
    /// inline body); `reserved_bytes` must fit in `uploadRoom`.
    pub fn noteStartSent(self: *State, fetch: *Fetch, reserved_bytes: u64) void {
        std.debug.assert(!fetch.start_sent);
        std.debug.assert(reserved_bytes <= self.uploadRoom());
        fetch.start_sent = true;
        fetch.upload_reserved_bytes = reserved_bytes;
        self.upload_reserved_bytes += reserved_bytes;
    }

    pub fn deinitTasks(self: *State, allocator: std.mem.Allocator) void {
        var task_it = self.tasks.iterator();
        while (task_it.next()) |entry| {
            entry.value_ptr.*.deinit(allocator);
            allocator.destroy(entry.value_ptr.*);
        }
        self.tasks.deinit(allocator);
    }

    /// Frees the tables, unmaps the endpoint and closes the wake descriptors.
    /// Request cleanup and `releaseAllForShutdown` leave no body behind; one
    /// that is still here broke that contract, and it is logged and released
    /// with its decoder before the endpoint goes, so its extents still reach
    /// the mapped release queue.
    pub fn deinitAfterBodiesReleased(self: *State, allocator: std.mem.Allocator) void {
        if (self.bodies.count() != 0) {
            std.log.err("egress bodies still registered during state shutdown count={d}", .{
                self.bodies.count(),
            });
            var iterator = self.bodies.iterator();
            while (iterator.next()) |entry| {
                const body = entry.value_ptr.*;
                body.dropDecoder(allocator);
                body.releaseQueuedChunks(allocator);
                body.detachTeeLinks(allocator);
                body.release(allocator);
            }
            self.bodies.clearRetainingCapacity();
        }
        self.releaseEndpoint();
        if (self.detached_wake) |*wake|
            wake.close();
        self.detached_wake = null;
        self.bodies.deinit(allocator);
        self.fetches.deinit(allocator);
        self.pending_uploads.deinit(allocator);
    }

    /// Gives back the place an egress item held in the ready queue, for every
    /// item the queue pops, whether or not the loop then runs it
    /// (`scheduler/loop.zig:executeWorkItem`): a task or body still listed
    /// may queue its next item, and an item whose task or body went before it
    /// stops counting against the slots `fetch_runtime.schedule` and
    /// `body/register.zig` hand out. Ids never repeat within the worker, so
    /// the item of a task or body still listed is that one's item. Any other
    /// kind changes nothing.
    pub fn noteReadyItemPopped(self: *State, item: ready_queue.WorkItem) void {
        switch (item) {
            .fetch_completion => |fetch_id| {
                if (self.tasks.get(fetch_id)) |task| {
                    task.noteReadyItemPopped();
                } else {
                    std.debug.assert(self.completion_ready_orphans != 0);
                    self.completion_ready_orphans -= 1;
                }
            },
            .fetch_body_ready => |body_id| {
                if (self.bodies.get(body_id)) |body| {
                    body.noteReadyItemPopped();
                } else {
                    std.debug.assert(self.body_ready_orphans != 0);
                    self.body_ready_orphans -= 1;
                }
            },
            .request,
            .timer_callback,
            .immediate_callback,
            .request_completion,
            .request_body_ready,
            .request_cancelled,
            .request_deadline,
            .response_advance,
            => {},
        }
    }

    /// Drops every decoder, for a detach or teardown. It must run before the
    /// endpoint is unmapped, so the pending extents still reach the release
    /// queue.
    pub fn dropAllDecoders(self: *State, allocator: std.mem.Allocator) void {
        var iterator = self.bodies.valueIterator();
        while (iterator.next()) |body|
            body.*.dropDecoder(allocator);
    }

    /// The next body identity under `request`'s id and generation. Body ids
    /// wrap and skip zero.
    pub fn nextBodyIdentity(
        self: *State,
        request: *const request_context.RequestContext,
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

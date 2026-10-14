//! The io_uring data driver of one engine's owner thread: the only place the
//! engine waits. It owns every socket operation of the engine's wires and
//! watches the sockets of its dials while their connects are in progress.
//!
//! For a wire (`transport.Wire`, TLS or plain) the driver owns real recv and
//! send SQEs: their completions feed and drain the wire's buffers, and
//! BoringSSL only transforms bytes Collo already holds. A wire has at most one
//! recv and one send in flight. Every outcome reaches the wire as it is
//! ingested, failures included, so the wire's own state never waits for the
//! owner to be told. The one receive outside the ring is
//! `refreshIdleWire`'s, on a pooled wire with none in flight. A connecting
//! socket gets one one-shot POLL_ADD for writability, which reports the end
//! of its connect either way.
//! Each source keeps a registration across waits, so a wanted operation is
//! armed once and stays armed until it completes; `cancelConnection` and
//! `cancelConnecting` end a registration before its owner closes the socket.
//!
//! The ring is created, restricted to the operations above plus timeouts and
//! cancels, and enabled in `init`, before the gateway's seccomp filter denies
//! io_uring_register, in one configuration for production and tests. A wait
//! with sources never sleeps past the watchdog tick, and every wait serves
//! expired deadlines and recorded failures before readiness. Deadlines are
//! absolute nanoseconds on `transport.config.monotonicNowNs`, the
//! CLOCK_BOOTTIME the ring's absolute timeouts compare against.
//!
//! Thread: the engine's owner thread alone, from `init` to `deinit`.

const std = @import("std");
const builtin = @import("builtin");
const tags = @import("collo_io_uring_tags");
const restricted_uring = @import("collo_common_io").restricted_uring;
const transport = @import("../transport/root.zig");

const linux = std.os.linux;
const Wire = transport.Wire;
const monotonicNowNs = transport.config.monotonicNowNs;

const ring_entries: u16 = 256;
/// The CQ is sized apart from the SQ (IORING_SETUP_CQSIZE). One driver serves
/// one shard's engine, which takes the fetches of every security cell
/// `egress/gateway/shard.zig:hashFetch` sends it, so what it has armed at once
/// is bounded only by the sockets the shard holds: at most a recv and a send
/// per wire and a connect poll per dial, under the gateway's open-file limit
/// (`EGRESS_GATEWAY_OPEN_FILES_MAX` in `common/limits/process.zig`), which
/// every shard shares. 4096 entries hold one completion from each operation
/// of 2048 wires and cost 64 KiB of CQEs per driver. Past that the kernel
/// keeps completions in its overflow list (IORING_FEAT_NODROP), and every
/// drain moves them into the queue before it calls the queue empty
/// (`flushOverflow`).
const cq_ring_entries: u32 = 4096;
const max_cqes_per_copy: usize = 64;
/// Batches one CQE drain may ingest, so a wait pass re-checks deadlines,
/// recorded failures and control results between batches; a CQ that keeps
/// refilling cannot hold the pass.
const max_ingest_batches_per_drain: usize = 8;
/// Upper bound on any single wait. It also refreshes the owner's cached
/// state: deadlines the owner suspends while a consumer holds body bytes
/// arm no kernel timeout, and the tick re-evaluates them.
const watchdog_tick_ns: u64 = std.time.ns_per_s;
/// Signal interruptions `refreshIdleWire`'s nonblocking receive retries
/// before it gives up on reading the socket. The receive never waits, so an
/// interruption is rare.
const idle_receive_attempts_max: usize = 4;

pub const Source = struct {
    context: *anyopaque,
    io: Io = .none,
    deadline_mono_ns: u64,
    want_read: bool = true,
    want_write: bool = false,

    pub const Io = union(enum) {
        /// The source contributes only its deadline.
        none,
        /// The driver owns the wire's recv and send SQEs; `want_read` and
        /// `want_write` say what the owner waits for.
        wire: *Wire,
        /// A nonblocking socket whose connect is in progress, reported ready
        /// once writable. The interest flags are ignored.
        connecting: std.posix.fd_t,
    };
};

pub const Ready = struct {
    context: *anyopaque,
    readable: bool = false,
    writable: bool = false,
};

pub const Failure = struct {
    context: *anyopaque,
    err: anyerror,
};

pub const Result = union(enum) {
    ready: Ready,
    failed: Failure,
    expired: *anyopaque,
    wake,
    /// Watchdog heartbeat: nothing completed, but the owner re-evaluates its
    /// cached state (suspended deadlines, pause flips).
    tick,
};

pub const Driver = struct {
    allocator: std.mem.Allocator,
    ring: linux.IoUring,
    registrations: std.array_list.Aligned(Registration, null) = .empty,
    serve_cursor: usize = 0,
    /// Control completion (wake, timeout, tick) captured while draining the
    /// CQ outside the wait's serving point; the wait returns it once
    /// deadline and ready-state checks have had their turn. Valid only within
    /// the wait pass that stashed it.
    stashed_result: ?Result = null,
    /// Generation of the wait pass currently blocked in the kernel; control
    /// completions from any other generation are stale and dropped.
    active_generation: ?u16 = null,
    generation: u16 = 0,
    timeout_storage: linux.kernel_timespec = undefined,
    timeout_context: ?*anyopaque = null,
    timeout_queued: bool = false,
    timeout_kind: CompletionKind = .timeout,
    wake_queued: bool = false,
    /// Sticky: io_uring_enter reported the ring's descriptor gone (BADF,
    /// BADFD, NXIO or OPNOTSUPP), so no cancel reaches the kernel and no wait
    /// can deliver a completion again. The io_uring instance still lives
    /// through the ring's mappings, with every operation it holds armed, so
    /// teardown paths never block on a synchronous drain and never free a
    /// wire an operation still references: they quarantine it until `deinit`
    /// has torn the ring down. The owner sees an error rather than a hang, and
    /// since nothing can replace the ring, the engine refuses to start a new
    /// run on it (`ringDead`).
    ring_dead: bool = false,
    /// The next N `flushSubmissions` calls fail with
    /// `error.SystemResources` before entering the kernel: the transient
    /// EAGAIN (io_uring async-worker pressure) the cancel quarantine defends
    /// against, which no test can provoke from outside. Compiled only into
    /// test builds.
    test_flush_failures: if (builtin.is_test) usize else void =
        if (builtin.is_test) 0 else {},
    /// The next N copies of a cancel's terminal drain fail with
    /// `error.SystemResources` before entering the kernel: an error a live
    /// ring returns, which no test can provoke from outside. Compiled only
    /// into test builds.
    test_drain_failures: if (builtin.is_test) usize else void =
        if (builtin.is_test) 0 else {},

    /// Fails with `error.UnsupportedKernel` or `error.PermissionDenied` when
    /// this kernel or its policy offers no ring with restrictions
    /// (`restricted_uring.initRingParams`, Linux 5.10 or later), so a caller
    /// can tell a missing capability from a real failure.
    pub fn init(allocator: std.mem.Allocator) !Driver {
        var params = std.mem.zeroInit(linux.io_uring_params, .{
            .flags = linux.IORING_SETUP_R_DISABLED | linux.IORING_SETUP_CQSIZE,
            .cq_entries = cq_ring_entries,
        });
        var ring = try restricted_uring.initRingParams(ring_entries, &params);
        errdefer ring.deinit();
        if ((params.features & linux.IORING_FEAT_NODROP) == 0)
            std.log.warn("egress data io_uring lacks IORING_FEAT_NODROP; completions may drop under CQ overflow", .{});
        var restrictions = [_]restricted_uring.Restriction{
            restricted_uring.registerRestriction(.REGISTER_ENABLE_RINGS),
            restricted_uring.sqeRestriction(.RECV),
            restricted_uring.sqeRestriction(.SEND),
            restricted_uring.sqeRestriction(.POLL_ADD),
            restricted_uring.sqeRestriction(.POLL_REMOVE),
            restricted_uring.sqeRestriction(.TIMEOUT),
            restricted_uring.sqeRestriction(.TIMEOUT_REMOVE),
            restricted_uring.sqeRestriction(.ASYNC_CANCEL),
        };
        try restricted_uring.registerRestrictions(ring.fd, &restrictions);
        try restricted_uring.enableRing(ring.fd);
        return .{
            .allocator = allocator,
            .ring = ring,
        };
    }

    pub fn deinit(self: *Driver) void {
        self.cancelAllConnections();
        self.cancelControlQueued(self.generation);
        self.ring.deinit();
        // Wires still pinned by quarantined registrations, whose cancels
        // never confirmably reached the kernel or whose ring died, must
        // outlive the ring: its teardown above retires the in-flight SQEs
        // that reference their buffers. The driver owns their release.
        for (self.registrations.items) |*registration| {
            if (!registration.quarantined)
                continue;
            switch (registration.target) {
                .wire => |wire| wire.deinit(),
                .none, .connecting => {},
            }
            registration.target = .none;
        }
        self.registrations.deinit(self.allocator);
        self.* = undefined;
    }

    /// The ring itself is gone (see `ring_dead`), so no wait on this driver
    /// can deliver readiness again.
    pub fn ringDead(self: *const Driver) bool {
        return self.ring_dead;
    }

    /// Blocking wait for one result. It arms what each source wants (recv
    /// and send for wires, the connect poll for connecting sockets), the
    /// wake poll and the single timeout or tick, and serves expired
    /// deadlines first, then failures and readiness. Fails with
    /// `error.NoEgressDataSources` when there is nothing to wait for.
    pub fn wait(self: *Driver, sources: []const Source, wake_fd: ?std.posix.fd_t) !Result {
        if (sources.len == 0 and wake_fd == null)
            return error.NoEgressDataSources;
        const earliest_deadline_ns = earliestDeadline(sources);

        while (true) {
            // Any control result stashed by a previous wait pass is stale
            // (its wake and timeout tokens were cancelled and its contexts
            // may have moved); the clock and ready-state checks below cover
            // whatever it announced.
            self.stashed_result = null;
            // Quarantined cancels are retried on every pass, and
            // registrations whose terminal CQEs have all been consumed
            // release the wires they pinned.
            self.requeueQuarantinedCancels();
            self.releaseQuarantinedRegistrations();
            // Every serving point ingests, bounded and preemptible: an
            // expired deadline or a recorded failure outranks any completion
            // backlog, and whatever stays unread waits in the CQ for the next
            // pass. It costs one CQ peek when idle.
            try self.drainCompletionsPreemptible(earliest_deadline_ns);
            try self.refreshSources(sources);
            // Wanted socket operations are armed before any serving
            // decision, so the kernel already holds them while this pass
            // serves a coalesced result without blocking.
            try self.queueSourceIo(sources);

            const now_ns = try monotonicNowNs();
            if (expiredSourceContext(sources, now_ns)) |context| {
                self.clearIdleRegistrations();
                return .{ .expired = context };
            }
            if (self.takeReadyResult()) |result| {
                self.clearIdleRegistrations();
                return result;
            }

            const generation = self.nextGeneration();
            self.active_generation = generation;
            defer self.active_generation = null;
            self.queueWait(generation, sources, wake_fd, now_ns) catch |err| {
                self.cancelControlQueued(generation);
                return err;
            };
            const outcome = self.awaitResult(sources) catch |err| {
                self.cancelControlQueued(generation);
                return err;
            };
            self.cancelControlQueued(generation);
            self.clearIdleRegistrations();
            if (outcome) |result|
                return result;
            // Only stale completions arrived, so deadlines and ready-state
            // are evaluated again.
        }
    }

    /// Returns true when the wire is released: the kernel no longer
    /// references its buffers and the caller owns its teardown. Returns
    /// false when the kernel may still write them: the registration is
    /// quarantined and the driver takes ownership of the wire (the caller
    /// must not deinit it). On a live ring the driver retries an unconfirmed
    /// cancel on later waits and deinits the wire once the terminal CQEs are
    /// consumed; on a dead ring it deinits the wire in `deinit`, after the
    /// ring is torn down.
    pub fn cancelConnection(self: *Driver, wire: *Wire) bool {
        const index = self.findWireIndex(wire) orelse return true;
        return self.cancelRegistration(index, false);
    }

    /// Same contract as `cancelConnection`, but while a recv or send is still
    /// queued it first shuts down and closes the socket, so that I/O
    /// completes promptly, on a dead ring too.
    pub fn cancelConnectionForClose(self: *Driver, wire: *Wire) bool {
        const index = self.findWireIndex(wire) orelse return true;
        return self.cancelRegistration(index, true);
    }

    /// Brings `wire`, idle in the HTTP/1 pool, up to date with what its
    /// socket delivered before this call, so `Wire.cleanForReuse` judges
    /// every byte, end of stream and failure that arrived while it idled.
    /// The pool calls it before it leases the wire. Returns false when the
    /// wire's state cannot be established; the wire must not be leased then.
    pub fn refreshIdleWire(self: *Driver, wire: *Wire) bool {
        if (wire.recv_in_flight) {
            // The kernel writes a completed receive's bytes into the wire's
            // buffer, and only its completion tells the wire. Having been
            // through a wait does not settle whether that happened: a wait
            // returns at its first result, which can come right after it
            // armed the receive or cut its drain short, and leaves the rest
            // in the completion queue. So what the queue holds is ingested
            // here, and a receive still in flight once the queue is empty has
            // received nothing.
            if (self.ring_dead)
                return false;
            self.drainCompletions() catch return false;
            // A drain stops at its batch bound, so the queue may still hold
            // completions, and the kernel's overflow list too.
            if (wire.recv_in_flight)
                return self.ring.cq_ready() == 0 and !self.ring.cq_ring_needs_flush();
        }
        // With no receive in flight, whatever arrived since the last one sits
        // in the socket, where nothing would look until the lease's request
        // went out.
        if (!wire.networkWantsRead())
            return true;
        return receiveIdleNow(wire);
    }

    /// Ends the watch on a connecting socket before its owner closes or
    /// adopts it. A connect poll holds no memory of the caller's, so this
    /// never waits: it asks the kernel to remove the poll, and the poll's
    /// late completion no longer matches any registration and is dropped.
    pub fn cancelConnecting(self: *Driver, fd: std.posix.fd_t) void {
        const index = self.findConnectingIndex(fd) orelse return;
        const registration = &self.registrations.items[index];
        if (registration.poll_queued and !self.ring_dead) {
            if (!self.queuePollRemove(index, registration.poll_user_data))
                std.log.debug("egress data io connect poll cancel not queued; its completion stays stale", .{});
        }
        registration.* = .{};
    }

    /// Teardown only: the owner releases every wire through
    /// `cancelConnection*` before the driver goes, so whatever this finds is
    /// quarantined, and the driver frees it.
    fn cancelAllConnections(self: *Driver) void {
        var index: usize = 0;
        while (index < self.registrations.items.len) : (index += 1) {
            switch (self.registrations.items[index].target) {
                .none => {},
                // A quarantined registration keeps its wire pinned until a
                // later pass or deinit releases it.
                .wire => _ = self.cancelRegistration(index, true),
                .connecting => |fd| self.cancelConnecting(fd),
            }
        }
    }

    fn nextGeneration(self: *Driver) u16 {
        self.generation +%= 1;
        if (self.generation == 0)
            self.generation = 1;
        return self.generation;
    }

    fn refreshSources(self: *Driver, sources: []const Source) !void {
        for (self.registrations.items) |*registration|
            registration.active = false;

        for (sources) |source| {
            const index = switch (source.io) {
                .none => continue,
                .wire => |wire| try self.ensureWireRegistration(wire),
                .connecting => |fd| try self.ensureConnectingRegistration(fd),
            };
            self.registrations.items[index].context = source.context;
            self.registrations.items[index].active = true;
        }
    }

    /// Arms recv and send SQEs for every wire that wants I/O, at most once
    /// per direction, and the connect poll of every connecting socket not
    /// yet armed, then flushes what it queued.
    fn queueSourceIo(self: *Driver, sources: []const Source) !void {
        var queued = false;
        for (sources) |source| {
            switch (source.io) {
                .none => {},
                .wire => |wire| {
                    if (try self.queueWireIo(source, wire))
                        queued = true;
                },
                .connecting => |fd| {
                    if (try self.queueConnectPoll(fd))
                        queued = true;
                },
            }
        }
        if (queued)
            try self.flushSubmissions();
    }

    fn queueWireIo(self: *Driver, source: Source, wire: *Wire) !bool {
        const want_send = (source.want_write or wire.hasBytesToSend()) and wire.networkWantsWrite();
        const want_recv = source.want_read and wire.networkWantsRead();
        if (!want_recv and !want_send)
            return false;
        const index = self.findWireIndex(wire) orelse return error.EgressDataRegistrationMissing;
        // A recorded failure is served before the wire is touched again.
        // Queueing a fresh recv or send here would hand the kernel I/O on a
        // socket the owner is about to tear down, and fail it again in a loop
        // ahead of the result that reports it.
        if (self.registrations.items[index].failure != null)
            return false;
        var queued = false;
        if (want_recv and !self.registrations.items[index].recv_queued) {
            try self.queueRecv(index, wire);
            queued = true;
        }
        if (want_send) {
            const user_data = try UserData.pack(.{ .kind = .send, .generation = self.nextGeneration(), .index = @intCast(index) });
            _ = self.ring.send(user_data, wire.fd(), wire.sendSlice(), 0) catch {
                // A full SQ is the only queueing failure: flush the accepted
                // chunk and retry.
                try self.flushSubmissions();
                _ = try self.ring.send(user_data, wire.fd(), wire.sendSlice(), 0);
            };
            wire.markSendSubmitted();
            const registration = &self.registrations.items[index];
            registration.send_queued = true;
            registration.send_user_data = user_data;
            queued = true;
        }
        return queued;
    }

    /// The one place the receive strategy lives: a one-shot recv into the
    /// wire's own buffer, which every wire allocates anyway, so receiving
    /// needs no registered buffer group.
    fn queueRecv(self: *Driver, index: usize, wire: *Wire) !void {
        const user_data = try UserData.pack(.{ .kind = .recv, .generation = self.nextGeneration(), .index = @intCast(index) });
        _ = self.ring.recv(user_data, wire.fd(), .{ .buffer = wire.recvBuffer() }, 0) catch {
            try self.flushSubmissions();
            _ = try self.ring.recv(user_data, wire.fd(), .{ .buffer = wire.recvBuffer() }, 0);
        };
        wire.markRecvSubmitted();
        const registration = &self.registrations.items[index];
        registration.recv_queued = true;
        registration.recv_user_data = user_data;
    }

    fn queueConnectPoll(self: *Driver, fd: std.posix.fd_t) !bool {
        const index = self.findConnectingIndex(fd) orelse return error.EgressDataRegistrationMissing;
        const registration = &self.registrations.items[index];
        // The poll is one-shot: once it reported, the owner finishes or
        // abandons the attempt and never needs a second report.
        if (registration.poll_queued or registration.poll_reported)
            return false;
        const user_data = try UserData.pack(.{ .kind = .connect_poll, .generation = self.nextGeneration(), .index = @intCast(index) });
        const events: u32 = @intCast(std.posix.POLL.OUT | std.posix.POLL.ERR | std.posix.POLL.HUP);
        _ = self.ring.poll_add(user_data, fd, events) catch {
            try self.flushSubmissions();
            _ = try self.ring.poll_add(user_data, fd, events);
        };
        registration.poll_queued = true;
        registration.poll_user_data = user_data;
        return true;
    }

    /// Arms the control completions for one blocking pass: the wake poll and
    /// the single timeout or watchdog tick. Socket operations are already
    /// armed by this point.
    fn queueWait(self: *Driver, generation: u16, sources: []const Source, wake_fd: ?std.posix.fd_t, now_ns: u64) !void {
        self.timeout_context = null;
        self.timeout_queued = false;
        self.wake_queued = false;

        var next_deadline_ns: u64 = std.math.maxInt(u64);
        for (sources) |source| {
            if (source.deadline_mono_ns < next_deadline_ns) {
                next_deadline_ns = source.deadline_mono_ns;
                self.timeout_context = source.context;
            }
        }

        if (wake_fd) |fd| {
            const user_data = try UserData.pack(.{ .kind = .wake, .generation = generation });
            const events: u32 = @intCast(std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR);
            _ = self.ring.poll_add(user_data, fd, events) catch {
                try self.flushSubmissions();
                _ = try self.ring.poll_add(user_data, fd, events);
            };
            self.wake_queued = true;
        }

        if (sources.len != 0) {
            // A wait with live sources never sleeps unbounded: a deadline
            // the owner suspended (maxInt, so no kernel timeout) must still
            // be re-evaluated, and a lost completion must not park the owner
            // forever. The tick behaves like a wake.
            const tick_deadline_ns = now_ns +| watchdog_tick_ns;
            if (next_deadline_ns <= tick_deadline_ns) {
                self.timeout_storage = timespecFromNs(next_deadline_ns);
                self.timeout_kind = .timeout;
            } else {
                self.timeout_storage = timespecFromNs(tick_deadline_ns);
                self.timeout_kind = .tick;
                self.timeout_context = null;
            }
            const user_data = try UserData.pack(.{ .kind = self.timeout_kind, .generation = generation });
            const timeout_flags = linux.IORING_TIMEOUT_ABS | linux.IORING_TIMEOUT_BOOTTIME;
            _ = self.ring.timeout(user_data, &self.timeout_storage, 0, timeout_flags) catch {
                try self.flushSubmissions();
                _ = try self.ring.timeout(user_data, &self.timeout_storage, 0, timeout_flags);
            };
            self.timeout_queued = true;
        }

        if (!self.hasQueuedOperations() and !self.wake_queued and !self.timeout_queued)
            return error.NoEgressDataSources;
    }

    fn awaitResult(self: *Driver, sources: []const Source) !?Result {
        const earliest_deadline_ns = earliestDeadline(sources);
        // Chunked flushes during queueing may already have ingested servable
        // completions; blocking for a fresh CQE would then oversleep on a
        // result already in hand.
        if (self.hasPendingResults()) {
            try self.flushSubmissions();
            return try self.pickResult(sources);
        }
        while (true) {
            _ = self.submitAndWait(1) catch |err| switch (err) {
                error.CompletionQueueOvercommitted => {
                    // NODROP backlog: drain the CQ into ready-state and
                    // submit again instead of failing the wait.
                    try self.drainCompletions();
                    if (self.hasPendingResults()) {
                        try self.flushSubmissions();
                        return try self.pickResult(sources);
                    }
                    continue;
                },
                else => return err,
            };
            try self.drainCompletionsPreemptible(earliest_deadline_ns);
            return try self.pickResult(sources);
        }
    }

    /// Serving order: expiry first, so a completion backlog never postpones
    /// a deadline, then ready-state, then any control completion stashed
    /// while draining.
    fn pickResult(self: *Driver, sources: []const Source) !?Result {
        const now_ns = try monotonicNowNs();
        if (expiredSourceContext(sources, now_ns)) |context|
            return .{ .expired = context };
        if (self.takeReadyResult()) |result|
            return result;
        if (self.stashed_result) |result| {
            self.stashed_result = null;
            return result;
        }
        return null;
    }

    fn hasPendingResults(self: *const Driver) bool {
        if (self.stashed_result != null)
            return true;
        for (self.registrations.items) |registration| {
            if (registration.active and registration.hasReadyState())
                return true;
        }
        return false;
    }

    fn hasFailureResults(self: *const Driver) bool {
        for (self.registrations.items) |registration| {
            if (registration.active and registration.failure != null)
                return true;
        }
        return false;
    }

    /// One result per wait. A failure is served before readiness of the
    /// same registration, and the rotating cursor keeps a permanently ready
    /// source from starving the others.
    fn takeReadyResult(self: *Driver) ?Result {
        const len = self.registrations.items.len;
        if (len == 0)
            return null;
        var offset: usize = 0;
        while (offset < len) : (offset += 1) {
            const index = (self.serve_cursor + offset) % len;
            const registration = &self.registrations.items[index];
            if (!registration.active or !registration.hasReadyState())
                continue;
            self.serve_cursor = (index + 1) % len;
            if (registration.failure) |err| {
                registration.clearReadyState();
                return .{ .failed = .{ .context = registration.context, .err = err } };
            }
            const result: Result = .{ .ready = .{
                .context = registration.context,
                .readable = registration.ready_readable,
                .writable = registration.ready_writable,
            } };
            registration.clearReadyState();
            return result;
        }
        return null;
    }

    /// Copies and ingests at most one batch of CQEs. Never blocks. Returns
    /// the number copied; fewer than a full batch means the CQ ring was
    /// observed empty afterwards, though the kernel's overflow list may still
    /// hold completions (`flushOverflow`).
    fn ingestCompletionBatch(self: *Driver) !usize {
        while (true) {
            var cqes: [max_cqes_per_copy]linux.io_uring_cqe = undefined;
            // std's copy_cqes enters the kernel when it copies nothing while
            // the CQ overflow flag is set, so it can fail with EINTR; retry as
            // `enter` does instead of failing the wait.
            const count = self.ring.copy_cqes(&cqes, 0) catch |err| switch (err) {
                error.SignalInterrupt => continue,
                else => {
                    self.noteEnterError(err);
                    return err;
                },
            };
            for (cqes[0..count]) |cqe|
                self.ingestCqe(cqe);
            return count;
        }
    }

    /// After a batch that left the CQ ring empty: moves the completions the
    /// kernel holds in its overflow list into the ring, and returns whether
    /// it held any, so the drain goes on until the queue is empty in both
    /// places. While the list holds anything the kernel posts every new
    /// completion behind it, so a ring found empty says nothing about the
    /// list.
    fn flushOverflow(self: *Driver) !bool {
        if (!self.ring.cq_ring_needs_flush())
            return false;
        _ = try self.enter(0, 0, linux.IORING_ENTER_GETEVENTS);
        return true;
    }

    /// CQE drain bounded by the batch budget, without preemption. It runs
    /// where CQ space must be freed unconditionally, in EBUSY recovery for a
    /// flush or for the blocking wait, and before an idle wire's lease.
    fn drainCompletions(self: *Driver) !void {
        var batches: usize = 0;
        while (batches < max_ingest_batches_per_drain) : (batches += 1) {
            if ((try self.ingestCompletionBatch()) == max_cqes_per_copy)
                continue;
            if (!try self.flushOverflow())
                return;
        }
    }

    /// Ingestion at the wait's serving points, bounded and preemptible: an
    /// expired deadline, a recorded failure or a stashed control result
    /// stops intake before the next batch.
    fn drainCompletionsPreemptible(self: *Driver, earliest_deadline_ns: u64) !void {
        var batches: usize = 0;
        while (batches < max_ingest_batches_per_drain) : (batches += 1) {
            if (self.stashed_result != null or self.hasFailureResults())
                return;
            if (earliest_deadline_ns != std.math.maxInt(u64)) {
                if ((try monotonicNowNs()) >= earliest_deadline_ns)
                    return;
            }
            if ((try self.ingestCompletionBatch()) == max_cqes_per_copy)
                continue;
            if (!try self.flushOverflow())
                return;
        }
    }

    /// Ingests one CQE at once. Wire completions feed and drain the wire and
    /// coalesce into the registration's ready flags; a connect poll marks
    /// its registration writable. Control completions of the active wait
    /// generation are stashed for the serving point. A completion whose token
    /// no longer matches its registration is stale and dropped.
    fn ingestCqe(self: *Driver, cqe: linux.io_uring_cqe) void {
        const user_data = UserData.unpack(cqe.user_data) catch return;
        switch (user_data.kind) {
            .recv, .send => self.ingestWireCompletion(user_data, cqe.res),
            .connect_poll => self.ingestConnectPoll(user_data),
            .wake => {
                if (self.isActiveGeneration(user_data.generation))
                    self.stashControlResult(.wake);
            },
            .timeout => {
                if (self.isActiveGeneration(user_data.generation)) {
                    if (self.timeout_context) |context|
                        self.stashControlResult(.{ .expired = context });
                }
            },
            .tick => {
                if (self.isActiveGeneration(user_data.generation))
                    self.stashControlResult(.tick);
            },
            .cancel => {},
        }
    }

    fn isActiveGeneration(self: *const Driver, generation: u16) bool {
        const active = self.active_generation orelse return false;
        return active == generation;
    }

    fn stashControlResult(self: *Driver, result: Result) void {
        if (self.stashed_result == null)
            self.stashed_result = result;
    }

    fn ingestWireCompletion(self: *Driver, user_data: UserData, res: i32) void {
        const index: usize = @intCast(user_data.index);
        if (index >= self.registrations.items.len)
            return;
        const registration = &self.registrations.items[index];
        const wire = switch (registration.target) {
            .wire => |wire| wire,
            .none, .connecting => return,
        };
        const completed_user_data = UserData.pack(user_data) catch return;
        if (user_data.kind == .recv) {
            if (!registration.recv_queued or registration.recv_user_data != completed_user_data)
                return;
            registration.recv_queued = false;
            wire.markRecvComplete();
        } else {
            if (!registration.send_queued or registration.send_user_data != completed_user_data)
                return;
            registration.send_queued = false;
            wire.markSendComplete();
        }

        // A completion always reaches the wire, even while no source watches
        // it (an HTTP/1 body parked on its consumer, a pooled wire between
        // leases): the received bytes sit in the wire's buffer and only the
        // feed makes them readable, and a failure makes the wire unclean
        // before any wait serves it. The ready flags wait for the next wait
        // that watches the wire, or for its cancel.
        if (user_data.kind == .recv) {
            if (applyReceiveResult(wire, res)) |err| {
                registration.noteFailure(err);
                return;
            }
            registration.ready_readable = true;
            return;
        }
        if (applySendResult(wire, res)) |err| {
            registration.noteFailure(err);
            return;
        }
        registration.ready_writable = true;
    }

    /// Any outcome of the poll, readiness or a poll error, means the connect
    /// ended or cannot be watched; the owner reads the socket's own error
    /// (`connect.finishAttempt`) to learn which, so the result code is not
    /// read here.
    fn ingestConnectPoll(self: *Driver, user_data: UserData) void {
        const index: usize = @intCast(user_data.index);
        if (index >= self.registrations.items.len)
            return;
        const registration = &self.registrations.items[index];
        switch (registration.target) {
            .connecting => {},
            .none, .wire => return,
        }
        const completed_user_data = UserData.pack(user_data) catch return;
        if (!registration.poll_queued or registration.poll_user_data != completed_user_data)
            return;
        registration.poll_queued = false;
        registration.poll_reported = true;
        registration.ready_writable = true;
    }

    /// Control cancels go through the EBUSY-aware flush like every other
    /// submission. A flush that still fails is logged, and the leftover SQEs
    /// go out with the next flush; their completions carry this generation
    /// and are dropped as stale.
    fn cancelControlQueued(self: *Driver, generation: u16) void {
        if (self.wake_queued) {
            const cancel_user_data = UserData.pack(.{ .kind = .cancel, .generation = generation, .index = std.math.maxInt(u32) - 1 }) catch return;
            const target = UserData.pack(.{ .kind = .wake, .generation = generation }) catch return;
            _ = self.ring.poll_remove(cancel_user_data, target) catch {
                self.flushSubmissions() catch |err| std.log.debug("egress data io wake cancel flush failed: {s}", .{@errorName(err)});
                _ = self.ring.poll_remove(cancel_user_data, target) catch |err|
                    std.log.debug("egress data io wake cancel failed: {s}", .{@errorName(err)});
            };
        }
        if (self.timeout_queued) {
            const cancel_user_data = UserData.pack(.{ .kind = .cancel, .generation = generation, .index = std.math.maxInt(u32) }) catch return;
            const target = UserData.pack(.{ .kind = self.timeout_kind, .generation = generation }) catch return;
            _ = self.ring.timeout_remove(cancel_user_data, target, 0) catch {
                self.flushSubmissions() catch |err| std.log.debug("egress data io timeout cancel flush failed: {s}", .{@errorName(err)});
                _ = self.ring.timeout_remove(cancel_user_data, target, 0) catch |err|
                    std.log.debug("egress data io timeout cancel failed: {s}", .{@errorName(err)});
            };
        }
        self.flushSubmissions() catch |err| std.log.debug("egress data io cancel submit failed: {s}", .{@errorName(err)});
        self.wake_queued = false;
        self.timeout_queued = false;
    }

    /// Non-blocking submission. On EBUSY the CQ is drained into ready-state
    /// and the submission retried, never failed. It loops until the kernel
    /// has consumed every queued SQE (`sq_ready() == 0`): a short submission
    /// must retry the remainder instead of reporting success. Each enter
    /// either consumes SQEs or surfaces the blocked entry's error, so the
    /// loop ends.
    fn flushSubmissions(self: *Driver) !void {
        if (builtin.is_test) {
            if (self.test_flush_failures != 0) {
                self.test_flush_failures -= 1;
                return error.SystemResources;
            }
        }
        while (true) {
            _ = self.submitAndWait(0) catch |err| switch (err) {
                error.CompletionQueueOvercommitted => {
                    try self.drainCompletions();
                    continue;
                },
                else => return err,
            };
            if (self.ring.sq_ready() == 0)
                return;
        }
    }

    fn submitAndWait(self: *Driver, wait_nr: u32) !u32 {
        const submitted = self.ring.flush_sq();
        var flags: u32 = 0;
        if (self.ring.sq_ring_needs_enter(&flags) or wait_nr > 0) {
            if (wait_nr > 0 or (self.ring.flags & linux.IORING_SETUP_IOPOLL) != 0)
                flags |= linux.IORING_ENTER_GETEVENTS;
            return try self.enter(submitted, wait_nr, flags);
        }
        return submitted;
    }

    /// Marks the ring dead when `err`, from an enter std's copy made, is one
    /// of the four that concern the ring's descriptor itself, as `enter`
    /// does for its own. Every other error leaves a ring that still delivers.
    fn noteEnterError(self: *Driver, err: anyerror) void {
        if (ringGoneError(err))
            self.ring_dead = true;
    }

    fn enter(self: *Driver, to_submit: u32, min_complete: u32, flags: u32) !u32 {
        while (true) {
            const res = linux.io_uring_enter(self.ring.fd, to_submit, min_complete, flags, null);
            switch (linux.E.init(res)) {
                .SUCCESS => return @intCast(res),
                .AGAIN => return error.SystemResources,
                // BADF, BADFD, NXIO and OPNOTSUPP from enter concern the ring
                // fd itself (SQE-level fd errors arrive as CQE results): the
                // ring is gone and will never deliver another CQE, so it is
                // marked dead before failing and teardown does not wait on
                // it.
                .BADF => {
                    self.ring_dead = true;
                    return error.FileDescriptorInvalid;
                },
                .BADFD => {
                    self.ring_dead = true;
                    return error.FileDescriptorInBadState;
                },
                .BUSY => return error.CompletionQueueOvercommitted,
                .INVAL => return error.SubmissionQueueEntryInvalid,
                .FAULT => return error.BufferInvalid,
                .NXIO => {
                    self.ring_dead = true;
                    return error.RingShuttingDown;
                },
                .OPNOTSUPP => {
                    self.ring_dead = true;
                    return error.OpcodeNotSupported;
                },
                // A stray signal interrupts only the completion wait. The
                // kernel returns the submitted count when it consumed SQEs,
                // so EINTR means nothing was submitted and retrying with the
                // same arguments is safe.
                .INTR => continue,
                else => |errno| return std.posix.unexpectedErrno(errno),
            }
        }
    }

    /// Returns true when the registration was released, its terminal CQEs
    /// consumed, and the wire's owner may tear it down. Returns false when
    /// the kernel may still write the wire's buffers, because the cancel is
    /// unconfirmed, its terminals cannot be drained now, or the ring died:
    /// the registration is quarantined with the wire pinned and ownership
    /// passes to the driver (`quarantine`).
    fn cancelRegistration(self: *Driver, index: usize, close_socket: bool) bool {
        if (index >= self.registrations.items.len)
            return true;
        const registration = &self.registrations.items[index];
        // A quarantined registration is already driver-owned, so releasing
        // it also deinits the pinned wire.
        const driver_owned = registration.quarantined;
        registration.active = false;
        registration.clearReadyState();
        if (!registration.hasQueuedData()) {
            releaseRegistration(registration, driver_owned);
            return true;
        }
        if (close_socket) {
            switch (registration.target) {
                .wire => |wire| wire.shutdownSocketForCancel(),
                .none, .connecting => {},
            }
        }
        // A dead ring takes no cancel and posts nothing a drain could wait
        // for, yet its instance lives on through the ring's mappings with
        // these operations armed, and closing the socket does not end them,
        // since each holds its own reference to the file.
        if (self.ring_dead)
            return quarantine(registration, .ring_dead);
        // The synchronous terminal drain below starts only once the kernel
        // has confirmably consumed every required cancel and, FIFO, every SQE
        // queued before it. An unconfirmed cancel against a silent peer would
        // otherwise park this teardown forever on a CQE that never comes.
        var cancels_queued = true;
        if (registration.recv_queued) {
            if (!self.queueDataCancel(index, registration.recv_user_data))
                cancels_queued = false;
        }
        if (registration.send_queued) {
            if (!self.queueDataCancel(index, registration.send_user_data))
                cancels_queued = false;
        }
        const cancels_submitted = cancels_queued and self.flushCancelSubmissions();
        if (!cancels_submitted) {
            if (self.ring_dead)
                return quarantine(registration, .ring_dead);
            std.log.warn("egress data io cancel unconfirmed; quarantining registration until its terminals arrive", .{});
            return quarantine(registration, .cancel_unconfirmed);
        }

        while (registration.hasQueuedData()) {
            if (self.ring_dead)
                return quarantine(registration, .ring_dead);
            var cqes: [max_cqes_per_copy]linux.io_uring_cqe = undefined;
            const count = self.copyTerminalCqes(&cqes) catch |err| switch (err) {
                error.SignalInterrupt => continue,
                else => {
                    self.noteEnterError(err);
                    if (self.ring_dead)
                        return quarantine(registration, .ring_dead);
                    // A live ring that cannot be waited on now, as under
                    // memory pressure, still delivers the terminals to a
                    // later wait.
                    std.log.warn("egress data io cancellation drain failed; quarantining registration until its terminals arrive: {s}", .{@errorName(err)});
                    return quarantine(registration, .terminals_pending);
                },
            };
            // Everything drained here is ingested at once, so other
            // registrations keep their completions as ready-state.
            for (cqes[0..count]) |cqe|
                self.ingestCqe(cqe);
        }
        registration.clearReadyState();
        releaseRegistration(registration, driver_owned);
        return true;
    }

    /// One blocking copy of the completions a cancel's terminal drain waits
    /// for.
    fn copyTerminalCqes(self: *Driver, cqes: []linux.io_uring_cqe) !u32 {
        if (builtin.is_test) {
            if (self.test_drain_failures != 0) {
                self.test_drain_failures -= 1;
                return error.SystemResources;
            }
        }
        return self.ring.copy_cqes(cqes, 1);
    }

    /// Final release of a registration. When the driver owns the wire (a
    /// quarantine), releasing it also deinits the wire; the original caller
    /// lost ownership when its cancel returned unconfirmed.
    fn releaseRegistration(registration: *Registration, driver_owned: bool) void {
        const target = registration.target;
        registration.* = .{};
        if (!driver_owned)
            return;
        switch (target) {
            .wire => |wire| wire.deinit(),
            .none, .connecting => {},
        }
    }

    const QuarantineCause = enum {
        /// The kernel never confirmably received the cancels.
        cancel_unconfirmed,
        /// The cancels reached a live ring, and their terminals could not be
        /// drained now.
        terminals_pending,
        /// The ring's descriptor is gone, so no cancel reaches the kernel.
        ring_dead,
    };

    /// Quarantines a registration whose wire the kernel may still write and
    /// returns false, the verdict the canceling caller gets: the wire stays
    /// pinned and the driver owns it, and the slot is never reused. The wire
    /// is released once its terminal CQEs are consumed
    /// (`releaseQuarantinedRegistrations`), or in `deinit` after the ring is
    /// torn down, and an unconfirmed cancel is retried on later waits
    /// (`requeueQuarantinedCancels`).
    fn quarantine(registration: *Registration, cause: QuarantineCause) bool {
        registration.quarantined = true;
        registration.cancel_unconfirmed = cause == .cancel_unconfirmed;
        return false;
    }

    /// Requeues the ASYNC_CANCELs of quarantined registrations that the
    /// kernel never confirmably received, then flushes. Only a fully
    /// consumed SQ marks them confirmed. A duplicate cancel for an operation
    /// that already completed only posts a `.cancel` CQE, which ingestion
    /// ignores.
    fn requeueQuarantinedCancels(self: *Driver) void {
        var queued = false;
        for (self.registrations.items, 0..) |*registration, index| {
            if (!registration.quarantined or !registration.cancel_unconfirmed)
                continue;
            if (!registration.hasQueuedData()) {
                registration.cancel_unconfirmed = false;
                continue;
            }
            var all_queued = true;
            if (registration.recv_queued) {
                if (!self.queueDataCancel(index, registration.recv_user_data))
                    all_queued = false;
            }
            if (registration.send_queued) {
                if (!self.queueDataCancel(index, registration.send_user_data))
                    all_queued = false;
            }
            if (all_queued)
                registration.cancel_unconfirmed = false;
            queued = true;
        }
        if (!queued)
            return;
        self.flushSubmissions() catch |err| {
            std.log.debug("egress data io quarantined cancel flush failed: {s}", .{@errorName(err)});
            // The kernel may not have consumed the cancels, so every
            // quarantined registration still holding queued data goes back
            // to unconfirmed for the next pass.
            for (self.registrations.items) |*registration| {
                if (registration.quarantined and registration.hasQueuedData())
                    registration.cancel_unconfirmed = true;
            }
        };
    }

    /// A quarantined registration whose terminal CQEs have all been ingested
    /// releases the wire it pinned.
    fn releaseQuarantinedRegistrations(self: *Driver) void {
        for (self.registrations.items) |*registration| {
            if (!registration.quarantined or registration.hasQueuedData())
                continue;
            releaseRegistration(registration, true);
        }
    }

    /// Queues one ASYNC_CANCEL with the chunked retry on a full SQ. Returns
    /// true only when the SQ accepted the SQE; a cancel is never presumed
    /// queued.
    fn queueDataCancel(self: *Driver, index: usize, target: u64) bool {
        const user_data = UserData.pack(.{
            .kind = .cancel,
            .generation = self.nextGeneration(),
            .index = @intCast(index),
        }) catch return false;
        _ = self.ring.cancel(user_data, target, 0) catch {
            self.flushSubmissions() catch |err| {
                std.log.debug("egress data io cancel chunk flush failed: {s}", .{@errorName(err)});
                return false;
            };
            _ = self.ring.cancel(user_data, target, 0) catch |err| {
                std.log.debug("egress data io cancel queue failed: {s}", .{@errorName(err)});
                return false;
            };
        };
        return true;
    }

    /// Queues and flushes one POLL_REMOVE for a connect poll. Returns false
    /// when it could not; the poll then stays armed until its socket's
    /// connect ends, and its completion is stale on arrival.
    fn queuePollRemove(self: *Driver, index: usize, target: u64) bool {
        const user_data = UserData.pack(.{
            .kind = .cancel,
            .generation = self.nextGeneration(),
            .index = @intCast(index),
        }) catch return false;
        _ = self.ring.poll_remove(user_data, target) catch {
            self.flushSubmissions() catch return false;
            _ = self.ring.poll_remove(user_data, target) catch return false;
        };
        self.flushSubmissions() catch return false;
        return true;
    }

    /// Teardown flush: transient async-worker pressure (EAGAIN) retries a
    /// bounded number of times, because the terminal drain ends only if the
    /// cancels reach the kernel. Returns true only when the SQ was fully
    /// consumed.
    fn flushCancelSubmissions(self: *Driver) bool {
        var attempts: usize = 0;
        while (true) {
            self.flushSubmissions() catch |err| {
                if (err == error.SystemResources and attempts < 16) {
                    attempts += 1;
                    std.Thread.sleep(std.time.ns_per_ms);
                    continue;
                }
                std.log.warn("egress data io registration cancel submit failed: {s}", .{@errorName(err)});
                return false;
            };
            return true;
        }
    }

    fn hasQueuedOperations(self: *const Driver) bool {
        for (self.registrations.items) |registration| {
            if (registration.recv_queued or registration.send_queued or registration.poll_queued)
                return true;
        }
        return false;
    }

    /// A registration whose source left the wait and that holds no queued
    /// operation and no unserved result is forgotten, so a wire or socket
    /// the owner no longer watches keeps no slot.
    fn clearIdleRegistrations(self: *Driver) void {
        for (self.registrations.items) |*registration| {
            // A quarantined slot pins a driver-owned wire; only the
            // quarantine release paths free it.
            if (registration.quarantined)
                continue;
            if (registration.active)
                continue;
            if (registration.hasQueuedData() or registration.poll_queued)
                continue;
            // A wire's ready state waits for the next wait that watches it
            // again; a connecting socket that left the wait was abandoned, and
            // its socket number may come back for another dial.
            switch (registration.target) {
                .wire => if (registration.hasReadyState()) continue,
                .none, .connecting => {},
            }
            registration.* = .{};
        }
    }

    fn ensureWireRegistration(self: *Driver, wire: *Wire) !usize {
        if (self.findWireIndex(wire)) |index|
            return index;
        return self.claimRegistration(.{ .wire = wire });
    }

    fn ensureConnectingRegistration(self: *Driver, fd: std.posix.fd_t) !usize {
        if (self.findConnectingIndex(fd)) |index|
            return index;
        return self.claimRegistration(.{ .connecting = fd });
    }

    fn claimRegistration(self: *Driver, target: Registration.Target) !usize {
        for (self.registrations.items, 0..) |*registration, index| {
            if (registration.target == .none and !registration.quarantined) {
                registration.* = .{ .target = target };
                return index;
            }
        }
        const index = self.registrations.items.len;
        try self.registrations.append(self.allocator, .{ .target = target });
        return index;
    }

    fn findWireIndex(self: *const Driver, wire: *Wire) ?usize {
        for (self.registrations.items, 0..) |registration, index| {
            switch (registration.target) {
                .wire => |registered| if (registered == wire) return index,
                .none, .connecting => {},
            }
        }
        return null;
    }

    fn findConnectingIndex(self: *const Driver, fd: std.posix.fd_t) ?usize {
        for (self.registrations.items, 0..) |registration, index| {
            switch (registration.target) {
                .connecting => |registered| if (registered == fd) return index,
                .none, .wire => {},
            }
        }
        return null;
    }
};

const Registration = struct {
    target: Target = .none,
    context: *anyopaque = undefined,
    active: bool = false,
    recv_queued: bool = false,
    send_queued: bool = false,
    /// Connecting sockets: the connect poll is in the kernel.
    poll_queued: bool = false,
    /// Connecting sockets: the connect poll completed, so it is never armed
    /// again for this socket.
    poll_reported: bool = false,
    recv_user_data: u64 = 0,
    send_user_data: u64 = 0,
    poll_user_data: u64 = 0,
    ready_readable: bool = false,
    ready_writable: bool = false,
    failure: ?anyerror = null,
    /// Set when a cancel left the kernel holding SQEs that reference the
    /// wire's buffers (`Driver.quarantine` says when): the driver owns the
    /// wire, the slot is never reused, and the wire is deinited once every
    /// terminal CQE is consumed (`releaseQuarantinedRegistrations`) or, at
    /// the latest, after the ring is torn down in `Driver.deinit`.
    quarantined: bool = false,
    /// Quarantined only: the kernel has not yet confirmably consumed the
    /// ASYNC_CANCELs, so every wait requeues them until it has.
    cancel_unconfirmed: bool = false,

    const Target = union(enum) {
        none,
        wire: *Wire,
        connecting: std.posix.fd_t,
    };

    fn hasQueuedData(self: Registration) bool {
        return self.recv_queued or self.send_queued;
    }

    fn hasReadyState(self: Registration) bool {
        return self.ready_readable or self.ready_writable or self.failure != null;
    }

    fn clearReadyState(self: *Registration) void {
        self.ready_readable = false;
        self.ready_writable = false;
        self.failure = null;
    }

    fn noteFailure(self: *Registration, err: anyerror) void {
        if (self.failure == null)
            self.failure = err;
    }
};

const CompletionKind = enum(u8) {
    recv = 1,
    send = 2,
    wake = 3,
    timeout = 4,
    cancel = 5,
    /// Watchdog tick: behaves like a wake.
    tick = 6,
    /// The one-shot writability poll of a connecting socket.
    connect_poll = 7,
};

const UserData = struct {
    kind: CompletionKind,
    generation: u16,
    index: u32 = 0,

    const tag_shift: u6 = tags.high_byte_shift;
    const kind_shift: u6 = 48;
    const generation_shift: u6 = 32;
    const kind_mask: u64 = 0xff;
    const generation_mask: u64 = 0xffff;
    const index_mask: u64 = 0xffff_ffff;

    fn pack(self: UserData) !u64 {
        if (self.generation == 0)
            return error.InvalidEgressDataGeneration;
        return (tags.egress_high_byte << tag_shift) |
            (@as(u64, @intFromEnum(self.kind)) << kind_shift) |
            (@as(u64, self.generation) << generation_shift) |
            self.index;
    }

    fn unpack(value: u64) !UserData {
        if ((value >> tag_shift) != tags.egress_high_byte)
            return error.InvalidEgressDataTag;
        const kind_raw: u8 = @intCast((value >> kind_shift) & kind_mask);
        return .{
            .kind = std.meta.intToEnum(CompletionKind, kind_raw) catch return error.InvalidEgressDataKind,
            .generation = @intCast((value >> generation_shift) & generation_mask),
            .index = @intCast(value & index_mask),
        };
    }
};

/// Whether `err` is what std's `IoUring.enter`, and the driver's own
/// `enter`, return for BADF, BADFD, NXIO or OPNOTSUPP: the errnos that concern
/// the ring's descriptor itself, since SQE-level errors arrive as CQE results.
fn ringGoneError(err: anyerror) bool {
    return err == error.FileDescriptorInvalid or
        err == error.FileDescriptorInBadState or
        err == error.RingShuttingDown or
        err == error.OpcodeNotSupported;
}

fn earliestDeadline(sources: []const Source) u64 {
    var earliest: u64 = std.math.maxInt(u64);
    for (sources) |source| {
        if (source.deadline_mono_ns < earliest)
            earliest = source.deadline_mono_ns;
    }
    return earliest;
}

fn expiredSourceContext(sources: []const Source, now_ns: u64) ?*anyopaque {
    var earliest_context: ?*anyopaque = null;
    var earliest_deadline: u64 = std.math.maxInt(u64);
    for (sources) |source| {
        if (source.deadline_mono_ns > now_ns or source.deadline_mono_ns >= earliest_deadline)
            continue;
        earliest_deadline = source.deadline_mono_ns;
        earliest_context = source.context;
    }
    return earliest_context;
}

fn timespecFromNs(ns: u64) linux.kernel_timespec {
    return .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
}

/// What a receive's result does to its wire: bytes, and zero for the end of
/// the stream, are fed to it. A reset reads as the end of the stream, so the
/// protocol above reports truncation only for what it still expected. Any
/// other failure, or bytes the wire cannot take, marks the wire's receiving
/// failed and is returned for the owner.
fn applyReceiveResult(wire: *Wire, res: i32) ?anyerror {
    if (res >= 0) {
        wire.feedReceived(@intCast(res)) catch |err| {
            wire.markReceiveFailed();
            return err;
        };
        return null;
    }
    const errno = errnoFromResult(res) orelse {
        wire.markReceiveFailed();
        return error.EgressDataIoFailed;
    };
    if (errno == .CONNRESET) {
        wire.feedReceived(0) catch |err| {
            wire.markReceiveFailed();
            return err;
        };
        return null;
    }
    wire.markReceiveFailed();
    return errnoToError(errno);
}

/// What a send's result does to its wire: the bytes that went out leave its
/// send queue. A failure, a send that took nothing or a queue that cannot
/// advance breaks the wire's sending and is returned for the owner.
fn applySendResult(wire: *Wire, res: i32) ?anyerror {
    if (res > 0) {
        wire.advanceSent(@intCast(res)) catch |err| {
            wire.markSendBroken();
            return err;
        };
        return null;
    }
    wire.markSendBroken();
    if (res == 0)
        return error.FetchWriteFailed;
    const errno = errnoFromResult(res) orelse return error.EgressDataIoFailed;
    return errnoToError(errno);
}

/// One nonblocking receive into an idle wire that has none in flight, with
/// its result applied as a completion's would be; a failure stays on the
/// wire, which no owner watches for it. Returns false when the socket could
/// not be read.
fn receiveIdleNow(wire: *Wire) bool {
    const buffer = wire.recvBuffer();
    var attempt: usize = 0;
    while (attempt < idle_receive_attempts_max) : (attempt += 1) {
        const rc = linux.recvfrom(wire.fd(), buffer.ptr, buffer.len, linux.MSG.DONTWAIT, null, null);
        const res: i32 = switch (linux.E.init(rc)) {
            .SUCCESS => @intCast(rc),
            .AGAIN => return true,
            .INTR => continue,
            else => |errno| -@as(i32, @intFromEnum(errno)),
        };
        if (applyReceiveResult(wire, res)) |err|
            std.log.debug("egress data io idle wire receive failed: {s}", .{@errorName(err)});
        return true;
    }
    return false;
}

fn errnoFromResult(res: i32) ?linux.E {
    if (res >= 0 or res < -4095)
        return null;
    const errno_code: u16 = @intCast(-res);
    return @enumFromInt(errno_code);
}

fn errnoToError(errno: linux.E) anyerror {
    return switch (errno) {
        .AGAIN => error.WouldBlock,
        .CONNRESET => error.ConnectionResetByPeer,
        .PIPE => error.BrokenPipe,
        .TIMEDOUT => error.NetworkSubsystemFailed,
        .CANCELED => error.EgressDataIoCanceled,
        .NOBUFS => error.SystemResources,
        else => error.EgressDataIoFailed,
    };
}

//! io_uring data driver for BIO-backed egress TLS connections and for the
//! raw-fd waits of the engine owner loop. Connector threads use their own
//! driver for BIO handshakes and `readiness.zig` for their other fd waits.
//!
//! For a TLS connection the driver owns real recv and send SQEs: their
//! completions feed and drain the transport's ciphertext buffers, and
//! BoringSSL only transforms bytes Collo already holds. A raw-fd source (an
//! HTTP/1 pending parked by the owner loop) gets a persistent one-shot
//! POLL_ADD instead: the arm lives across waits until it completes or the
//! source departs, `syncSources` diffs the desired set against the armed set
//! by `{source_id, fd}`, and completions coalesce into per-slot ready bits
//! that waits serve one at a time. At most one CQE is outstanding per armed
//! watch, which bounds amplification.
//!
//! A wait with sources never sleeps past the watchdog tick; every wait serves
//! expired deadlines and recorded failures before readiness and ingests
//! completions in bounded batches at every serving point. Deadlines are absolute CLOCK_BOOTTIME
//! nanoseconds from `monotonicNowNs`.

const std = @import("std");
const builtin = @import("builtin");
const tags = @import("collo_io_uring_tags");
const restricted_uring = @import("collo_common_io").restricted_uring;
const transport_mod = @import("collo_egress_transport");

pub const transport = struct {
    pub const TlsBioTransport = transport_mod.TlsBioTransport;
};

const linux = std.os.linux;
const ns_per_ms: u64 = std.time.ns_per_ms;
const ring_entries: u16 = 256;
/// The CQ is sized apart from the SQ (IORING_SETUP_CQSIZE) because
/// persistent fd watches let completions pile up between waits. 4096 entries
/// (64 KiB of CQEs per driver) hold a completion from every armed watch at
/// once with room to spare, so a herd of ready fds does not churn through
/// overflow.
const cq_ring_entries: u32 = 4096;
/// Admission cap on armed fd watches per driver: above the gateway's default
/// per-security-cell fetch cap (`Policy.max_active_fetches_per_security_cell`
/// in `egress/gateway/policy.zig`) with headroom for HTTP/2, and below
/// `cq_ring_entries`, so the CQ bounds the worst-case backlog. Arming past it
/// fails only the source being admitted, with a named error served as a
/// `.failed` result, never an overflow spin or a shard-wide teardown.
/// Public so tests can reach the cap without restating it.
pub const max_armed_fd_watches: u32 = 2048;
const max_cqes_per_copy: usize = 64;
/// Batches one CQE drain may ingest, so a wait pass re-checks deadlines,
/// recorded failures and control results between batches. A CQ that keeps
/// refilling (provided-buffer multishot recv posting IORING_CQE_F_MORE
/// completions as fast as a flooding peer sends) would otherwise hold an
/// until-empty drain forever and starve every serving decision the pass
/// owes.
const max_ingest_batches_per_drain: usize = 8;
/// Upper bound on any single wait: the watchdog tick turns a lost completion
/// into a recovery within a second instead of an endless sleep.
const watchdog_tick_ns: u64 = std.time.ns_per_s;
const provided_recv_group_id: u16 = 9;
const provided_recv_buffer_size: u32 = 16 * 1024;
const provided_recv_buffer_count: u16 = 64;
const no_free_slot: u16 = std.math.maxInt(u16);

pub const RecvStrategy = enum {
    auto,
    one_shot,
    provided_multishot,
};

pub const Config = struct {
    recv_strategy: RecvStrategy = .auto,
    provided_buffer_size: u32 = provided_recv_buffer_size,
    provided_buffer_count: u16 = provided_recv_buffer_count,
};

pub const Source = struct {
    context: *anyopaque,
    /// Stable caller identity for raw-fd sources. The driver matches desired
    /// and armed fd watches by `{source_id, fd}`: not by fd alone, since fd
    /// numbers are reused, and not by context, which points into a caller
    /// list that moves. Must be nonzero for fd sources; ignored for
    /// connection and deadline-only sources.
    source_id: u64 = 0,
    /// BIO TLS source: the driver owns its recv and send SQEs and advances
    /// the transport's ciphertext buffers.
    connection: ?*transport.TlsBioTransport = null,
    /// Raw-fd readiness source (an HTTP/1 pending parked by the owner loop):
    /// a persistent one-shot POLL_ADD that survives across waits. The caller
    /// performs its own nonblocking syscalls once readiness is reported, and
    /// the next sync re-arms while the source stays desired. At most one of
    /// `connection` and `fd` may be set; with neither, the source only
    /// contributes its deadline to the wait's timeout.
    fd: ?std.posix.fd_t = null,
    deadline_mono_ns: u64,
    want_read: bool = true,
    want_write: bool = false,
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
    /// Watchdog heartbeat: nothing completed, but the owner must re-evaluate
    /// cached state (deadlines, pause flips, missed dirty transitions).
    tick,
};

pub const Driver = struct {
    allocator: std.mem.Allocator,
    ring: linux.IoUring,
    provided_recv: ?linux.IoUring.BufferGroup = null,
    recv_config: Config = .{},
    recv_strategy: RecvStrategy = .one_shot,
    registrations: std.array_list.Aligned(Registration, null) = .empty,
    /// Persistent fd-watch table. Slots hold the one-shot poll registrations
    /// (armed state, epoch token, coalesced ready bits); the map gives
    /// `syncSources` an O(1) source_id-to-slot lookup.
    fd_slots: std.array_list.Aligned(FdSlot, null) = .empty,
    fd_slots_by_source: std.AutoHashMapUnmanaged(u64, u16) = .empty,
    /// Intrusive free list through FdSlot.next_free. Releasing a slot cannot
    /// fail, so the table cannot diverge from the kernel on allocation
    /// failure.
    fd_free_head: u16 = no_free_slot,
    fd_ready_count: usize = 0,
    armed_fd_count: u32 = 0,
    /// Fd-watch operations (arms and cancels) queued to the SQ during the
    /// current `syncSources` pass, in queue order. The kernel consumes SQEs
    /// in FIFO order, so after a failed flush the last `sq_ready()` entries
    /// are exactly the operations it never received. Those roll back (arms
    /// return to `.disarmed` under a fresh token, cancels are marked for
    /// requeue), so the table never claims an arm or trusts a cancel the
    /// kernel was not handed.
    sync_ops: std.array_list.Aligned(SyncOp, null) = .empty,
    /// Tombstoned slots whose POLL_REMOVE never entered the SQ (a full ring
    /// with a failing flush, or a rollback). Every sync and wait pass retries
    /// them until the kernel holds the cancel; otherwise a silent fd would
    /// keep its tombstone, and its armed-count claim, forever.
    unqueued_cancel_count: usize = 0,
    /// One cap rejection per reconcile, served as a named `.failed` result
    /// with no slot or map footprint. Sources rejected while it is occupied
    /// stay in the desired set, so the next sync re-runs their admission;
    /// rejections drain one per sync/wait cycle without allocating.
    pending_admission_failure: ?Failure = null,
    /// Slots in state `.armed` whose token is still valid (see
    /// `liveArmedWatchCount`). Only the owner thread writes it.
    live_armed_fd_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    sync_stamp: u64 = 0,
    serve_conn_cursor: usize = 0,
    serve_fd_cursor: usize = 0,
    serve_fd_first: bool = false,
    /// Control completion (wake/timeout/tick) captured while draining the CQ
    /// outside the wait's serving point (EBUSY drains, chunked flushes); the
    /// wait returns it once deadline and ready-state checks have had their
    /// turn. Valid only within the wait pass that stashed it.
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
    ring_enabled: bool = false,
    ring_restricted: bool = false,
    /// Sticky: io_uring_enter reported the ring itself gone (fd closed or
    /// invalid, context tearing down). A dead ring posts no further CQEs, so
    /// teardown paths never block on, or panic over, a synchronous drain;
    /// they abandon their bookkeeping instead, so the owner sees an error
    /// rather than a hang. Nothing can replace the ring, so the engine
    /// refuses to start a new run on it (`ringDead`).
    ring_dead: bool = false,
    /// Provided-buffer multishot recv was downgraded to one-shot after a
    /// kernel NOBUFS. The buffers are only ever held by unread CQEs, since
    /// ingestion releases them at once, so the downgrade is a suspension:
    /// once a drain observes the CQ empty, every buffer is back on the ring
    /// and the strategy is restored. One-shot chosen by config and the
    /// `.auto` downgrades never set this flag and stay permanent.
    provided_multishot_suspended: bool = false,
    /// NOBUFS suspensions since construction. The flag above cannot show
    /// afterwards that one happened: the drain that ingests the NOBUFS
    /// terminal usually empties the CQ and lifts the suspension before the
    /// wait returns, and the one-shot fallback delivers the same bytes. Only
    /// the owner thread touches it; tests read it to tell a recovered
    /// suspension from none.
    provided_multishot_suspensions: u64 = 0,
    /// Test-only fault injection: the next N `flushSubmissions` calls fail
    /// with error.SystemResources before entering the kernel. That is the
    /// transient EAGAIN failure (io_uring async-worker pressure) the cancel
    /// quarantine defends against, which userspace cannot provoke
    /// deterministically.
    test_flush_failures: if (builtin.is_test) usize else void =
        if (builtin.is_test) 0 else {},

    pub fn init(allocator: std.mem.Allocator) !Driver {
        return initWithConfig(allocator, .{});
    }

    pub fn initWithConfig(allocator: std.mem.Allocator, config: Config) !Driver {
        var params = std.mem.zeroInit(linux.io_uring_params, .{
            .flags = linux.IORING_SETUP_R_DISABLED | linux.IORING_SETUP_CQSIZE,
            .cq_entries = cq_ring_entries,
            .sq_thread_idle = 1000,
        });
        const ring = try linux.IoUring.init_params(ring_entries, &params);
        if ((params.features & linux.IORING_FEAT_NODROP) == 0)
            std.log.warn("egress data io_uring lacks IORING_FEAT_NODROP; completions may drop under CQ overflow", .{});
        return .{
            .allocator = allocator,
            .ring = ring,
            .recv_config = config,
            .recv_strategy = if (config.recv_strategy == .one_shot) .one_shot else .auto,
        };
    }

    pub fn deinit(self: *Driver) void {
        self.cancelAllConnections();
        self.cancelControlQueued(self.generation);
        self.sync_ops.deinit(self.allocator);
        self.fd_slots.deinit(self.allocator);
        self.fd_slots_by_source.deinit(self.allocator);
        self.deinitProvidedRecv();
        self.ring.deinit();
        // Transports still pinned by quarantined registrations, whose
        // cancels never confirmably reached the kernel, must outlive the
        // ring: its teardown above retires the in-flight SQEs that reference
        // their buffers. The driver owns their release.
        for (self.registrations.items) |*registration| {
            if (registration.quarantined) {
                if (registration.connection) |connection|
                    connection.deinit();
                registration.connection = null;
            }
        }
        self.registrations.deinit(self.allocator);
        self.* = undefined;
    }

    /// The ring itself is gone (see `ring_dead`), so no wait on this driver
    /// can deliver readiness again.
    pub fn ringDead(self: *const Driver) bool {
        return self.ring_dead;
    }

    pub fn usingProvidedMultishot(self: *const Driver) bool {
        return self.provided_recv != null and self.recv_strategy == .provided_multishot;
    }

    /// The driver must already live at its final address: the buffer group
    /// stores a pointer to `self.ring`, so moving or copying the driver after
    /// this call leaves that pointer dangling.
    pub fn ensureProvidedMultishot(self: *Driver) !bool {
        if (self.recv_strategy == .one_shot)
            return false;
        if (self.recv_config.recv_strategy == .one_shot)
            return false;
        if (self.ring_enabled and !self.ring_restricted and self.recv_config.recv_strategy == .auto) {
            self.recv_strategy = .one_shot;
            return false;
        }
        if (self.usingProvidedMultishot())
            return true;
        if (!std.math.isPowerOfTwo(self.recv_config.provided_buffer_count))
            return error.InvalidProvidedRecvBufferCount;

        self.provided_recv = linux.IoUring.BufferGroup.init(
            &self.ring,
            self.allocator,
            provided_recv_group_id,
            self.recv_config.provided_buffer_size,
            self.recv_config.provided_buffer_count,
        ) catch |err| switch (self.recv_config.recv_strategy) {
            .auto => {
                self.recv_strategy = .one_shot;
                return false;
            },
            .provided_multishot => return err,
            .one_shot => unreachable,
        };
        self.recv_strategy = .provided_multishot;
        return true;
    }

    pub fn prepareForSandbox(self: *Driver) !bool {
        // Buffer-group registration uses io_uring_register, which the
        // gateway's seccomp filter blocks after startup, so the strategy is
        // decided here, before the sandbox is sealed, instead of registering
        // lazily from the network loop.
        //
        // Ring fds are not registered (REGISTER_RING_FDS): the kernel scopes
        // a registered ring fd to the registering task, and this runs on the
        // spawning thread while io_uring_enter runs on the engine thread that
        // owns the driver, where the registered index is EBADF.
        const provided = try self.ensureProvidedMultishot();
        try self.sealRestrictedRing();
        return provided;
    }

    /// Non-blocking reconciliation of the desired fd-watch set against the
    /// armed set. A new source arms a one-shot poll with its interest mask;
    /// a departed source retires its arm asynchronously (epoch invalidation,
    /// POLL_REMOVE, and a tombstone until the terminal CQE); an fd or mask
    /// change retires and re-arms under a fresh token. Queued SQEs are
    /// flushed before returning. Every exit, error exits included, either
    /// hands the kernel everything the table committed or rolls the
    /// unsubmitted tail back, so the table never claims an arm the kernel was
    /// not handed.
    pub fn syncSources(self: *Driver, sources: []const Source) !void {
        try self.ensureRingEnabledUnrestricted();
        // Tokens are retired in userspace inside syncFdSources before any
        // ring round trip has to succeed, so even a dead ring cannot deliver
        // a late CQE into a freed pending; failAllOwnerWork relies on this.
        // Leftover SQEs from earlier passes do not confuse the ledger: SQ
        // consumption is FIFO and this pass's operations are queued last, so
        // the rollback below still attributes the unconsumed tail correctly.
        self.sync_ops.clearRetainingCapacity();
        // Quarantined connection cancels go out with every reconcile until
        // the kernel confirmably holds them, and released registrations hand
        // their pinned transports back for teardown. Data cancels never
        // enter the fd-watch ledger, and queued before this pass's
        // operations they count as leftovers above, so the FIFO rollback
        // stays exact.
        self.requeueQuarantinedCancels();
        self.releaseQuarantinedRegistrations();
        var sync_err: ?anyerror = null;
        var queued = self.syncFdSources(sources) catch |err| blk: {
            // Arms and cancels this pass already committed must still reach
            // the kernel when a later source's admission fails, so the error
            // exits through the same flush instead of leaving them queued.
            sync_err = err;
            break :blk true;
        };
        if (self.unqueued_cancel_count != 0 and self.requeueUnqueuedCancels())
            queued = true;
        if (queued) {
            self.flushSubmissions() catch |err| {
                // The kernel consumed a FIFO prefix of what this pass
                // queued; everything after it rolls back so the table and
                // the kernel stay consistent.
                self.rollbackUnsubmittedSyncOps();
                return err;
            };
        }
        if (sync_err) |err| return err;
    }

    /// Blocking wait for one result. It owns the deadline scan, the single
    /// timeout and wake arm, connection recv and send SQEs, and serving
    /// coalesced ready-state, but not fd watches: the caller reconciles those
    /// with `syncSources` whenever its desired set changes. An fd source that
    /// was never synced sleeps here on its deadline alone.
    pub fn wait(self: *Driver, sources: []const Source, wake_fd: ?std.posix.fd_t) !Result {
        if (sources.len == 0 and wake_fd == null)
            return error.NoEgressDataSources;
        try self.ensureRingEnabledUnrestricted();
        const earliest_deadline_ns = earliestDeadline(sources);

        while (true) {
            // Any control result stashed by a previous wait pass is stale
            // (its wake/timeout tokens were cancelled and its contexts may
            // have moved); the clock and ready-state checks below cover
            // whatever it announced.
            self.stashed_result = null;
            // A tombstone cancel the SQ never took is retried on every pass
            // until the kernel holds it; its SQE goes out with this pass's
            // flushes.
            if (self.unqueued_cancel_count != 0)
                _ = self.requeueUnqueuedCancels();
            // Quarantined connection cancels are retried the same way, and
            // registrations whose terminal CQEs have all been consumed
            // release the transports they pinned.
            self.requeueQuarantinedCancels();
            self.releaseQuarantinedRegistrations();
            // Every serving point ingests, not only the one after the
            // blocking wait. A coalesced ready backlog is served one result
            // per pass, and each pass must still take in whatever the CQ
            // holds: HTTP/2 provided buffers return to their small ring
            // before a backlog starves it into NOBUFS, tombstone terminals
            // are reaped so the armed-watch count stays honest, and
            // co-located connections keep coalescing readiness. Ingestion is
            // bounded and preemptible: an expired deadline or a recorded
            // failure outranks any completion backlog, and whatever stays
            // unread waits in the CQ for the next pass. It costs one CQ peek
            // when idle.
            try self.drainCompletionsPreemptible(earliest_deadline_ns);
            try self.refreshSources(sources);
            // Connection recv and send SQEs are armed before any serving
            // decision. A coalesced fd backlog is served one result per pass
            // without blocking, and the kernel must already hold the wanted
            // HTTP/2 I/O during that window; otherwise a persistent HTTP/1
            // backlog starves co-located connections of their submissions
            // and the provided-buffer ring of its recycling.
            try self.queueConnectionIo(sources);

            // Deadlines outrank any completion backlog: a coalesced ready
            // burst never postpones an expiry the caller is owed.
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
            // Only stale completions arrived (retired tokens, tombstone
            // terminals), so deadlines and ready-state are evaluated again.
        }
    }

    /// Returns true when the connection is released: the kernel no longer
    /// references its buffers and the caller owns its teardown. Returns
    /// false when the cancel could not be confirmed on a live ring: the
    /// registration is quarantined and the driver takes ownership of the
    /// transport (the caller must not deinit it), retries the cancel on later
    /// sync and wait passes, and deinits the transport itself once the
    /// terminal CQEs are consumed or the ring dies.
    pub fn cancelConnection(self: *Driver, connection: *transport.TlsBioTransport) bool {
        const index = self.findRegistrationIndex(connection) orelse return true;
        return self.cancelRegistration(index, false);
    }

    /// Same contract as `cancelConnection`, but while recv or send is still
    /// queued on a live ring it first shuts down and closes the socket, so
    /// that I/O completes promptly.
    pub fn cancelConnectionForClose(self: *Driver, connection: *transport.TlsBioTransport) bool {
        const index = self.findRegistrationIndex(connection) orelse return true;
        return self.cancelRegistration(index, true);
    }

    pub fn cancelAllConnections(self: *Driver) void {
        var index: usize = 0;
        while (index < self.registrations.items.len) : (index += 1) {
            // The result is not needed here: a quarantined registration
            // keeps its transport pinned until a later pass or deinit
            // releases it.
            if (self.registrations.items[index].connection != null)
                _ = self.cancelRegistration(index, true);
        }
    }

    /// Fd watches whose one-shot arm is still live: the token is valid and
    /// readiness would reach its context. Tombstoned arms awaiting their
    /// terminal CQE are already dead to delivery and do not count, unlike
    /// `armed_fd_count`, which tracks completions the kernel still owes.
    /// Tests use it to check that departed sources leave no live arm. Atomic
    /// because test threads read it while the owner runs; the value is a
    /// statistic, never a synchronization edge.
    pub fn liveArmedWatchCount(self: *const Driver) usize {
        return self.live_armed_fd_count.load(.monotonic);
    }

    fn nextGeneration(self: *Driver) u16 {
        self.generation +%= 1;
        if (self.generation == 0)
            self.generation = 1;
        return self.generation;
    }

    fn sealRestrictedRing(self: *Driver) !void {
        if (self.ring_restricted)
            return;
        if (self.ring_enabled)
            return error.EgressDataRingAlreadyEnabled;
        var restrictions = [_]restricted_uring.Restriction{
            restricted_uring.registerRestriction(.REGISTER_ENABLE_RINGS),
            restricted_uring.sqeRestriction(.RECV),
            restricted_uring.sqeRestriction(.SEND),
            restricted_uring.sqeRestriction(.POLL_ADD),
            restricted_uring.sqeRestriction(.POLL_REMOVE),
            restricted_uring.sqeRestriction(.TIMEOUT),
            restricted_uring.sqeRestriction(.TIMEOUT_REMOVE),
            restricted_uring.sqeRestriction(.ASYNC_CANCEL),
            restricted_uring.sqeFlagsAllowedRestriction(@intCast(linux.IOSQE_BUFFER_SELECT)),
        };
        try restricted_uring.registerRestrictions(self.ring.fd, &restrictions);
        try restricted_uring.enableRing(self.ring.fd);
        self.ring_enabled = true;
        self.ring_restricted = true;
    }

    fn ensureRingEnabledUnrestricted(self: *Driver) !void {
        if (self.ring_enabled)
            return;
        try restricted_uring.enableRing(self.ring.fd);
        self.ring_enabled = true;
    }

    fn refreshSources(self: *Driver, sources: []const Source) !void {
        for (self.registrations.items) |*registration|
            registration.active = false;

        for (sources) |source| {
            const connection = source.connection orelse continue;
            const index = try self.ensureRegistration(connection);
            self.registrations.items[index].context = source.context;
            self.registrations.items[index].active = true;
        }
    }

    // ── Persistent fd-watch sync ────────────────────────────────────────

    /// Returns the armable fd of a raw-fd source, or null for connection,
    /// deadline-only and no-interest sources. Every sync phase applies this
    /// same filter; otherwise stamping and admission would disagree on what
    /// "desired" means.
    fn armableFd(source: Source) ?std.posix.fd_t {
        if (source.connection != null)
            return null;
        const fd = source.fd orelse return null;
        if (!source.want_read and !source.want_write)
            return null;
        return fd;
    }

    fn syncFdSources(self: *Driver, sources: []const Source) !bool {
        self.sync_stamp +%= 1;
        // A rejection recorded by an earlier pass was either served or is
        // derived again below, and its context may have moved with the
        // caller's list, so it never survives a reconcile.
        self.pending_admission_failure = null;
        var queued = false;
        // Phase 1 stamps the surviving sources, so retirement sees the true
        // departed set before anything is admitted.
        for (sources) |source| {
            if (armableFd(source) == null) continue;
            if (source.source_id == 0)
                return error.EgressFdSourceMissingId;
            if (self.fd_slots_by_source.get(source.source_id)) |slot_index|
                self.fd_slots.items[slot_index].last_stamp = self.sync_stamp;
        }
        // Phase 2 retires departures before any admission. A tombstoned arm
        // stops counting against the cap when it retires, not at its
        // terminal CQE, so replacing a full set of watches admits the new
        // set in this same pass instead of rejecting it against a count of
        // dying arms.
        if (self.retireDepartedFdSlots())
            queued = true;
        // Phase 3 admits and re-arms against the cap left after retirement.
        for (sources) |source| {
            const fd = armableFd(source) orelse continue;
            if (try self.syncFdSource(source, fd))
                queued = true;
        }
        return queued;
    }

    fn syncFdSource(self: *Driver, source: Source, fd: std.posix.fd_t) !bool {
        const mask = pollMask(source);
        if (self.fd_slots_by_source.get(source.source_id)) |slot_index| {
            const state = state: {
                const slot = &self.fd_slots.items[slot_index];
                slot.last_stamp = self.sync_stamp;
                slot.context = source.context;
                break :state slot.state;
            };
            switch (state) {
                .armed => {
                    {
                        const slot = &self.fd_slots.items[slot_index];
                        if (slot.fd == fd and slot.events == mask)
                            return false;
                    }
                    // The fd or interest changed while a one-shot is
                    // outstanding (masks change freely between parks; a TLS
                    // read can want write). Retire the old arm
                    // asynchronously and stand up a fresh slot with a fresh
                    // token for the new fd and mask.
                    self.tombstoneFdSlot(slot_index);
                    const new_slot = self.admitFdSlot(source, fd, mask) catch |err| {
                        // The map must never point at the tombstone left
                        // behind; on a cap rejection the source keeps no
                        // footprint at all.
                        _ = self.fd_slots_by_source.remove(source.source_id);
                        if (err == error.EgressFdWatchLimitExceeded) {
                            self.recordAdmissionRejection(source);
                            return true; // the retirement above queued a cancel
                        }
                        return err;
                    };
                    self.fd_slots_by_source.putAssumeCapacity(source.source_id, new_slot);
                    return true;
                },
                .disarmed => {
                    const slot = &self.fd_slots.items[slot_index];
                    if (slot.ready_pending and slot.fd == fd and slot.events == mask)
                        return false; // serve the coalesced readiness first; re-arm next sync
                    self.clearSlotReady(slot);
                    self.armFdSlot(slot_index, source.context, fd, mask) catch |err| switch (err) {
                        error.EgressFdWatchLimitExceeded => {
                            self.recordAdmissionRejection(source);
                            return false;
                        },
                        else => return err,
                    };
                    return true;
                },
                // Mapped slots are live by construction; a tombstone or
                // empty slot behind a live map entry is table corruption.
                .empty, .tombstone => return error.EgressFdRegistrationCorrupt,
            }
        }
        // A new admission. admitFdSlot rules on the cap before any slot
        // exists and frees the slot if arming fails, so a rejected admission
        // leaves no slot and no map entry behind.
        const slot_index = self.admitFdSlot(source, fd, mask) catch |err| {
            if (err == error.EgressFdWatchLimitExceeded) {
                self.recordAdmissionRejection(source);
                return false;
            }
            return err;
        };
        self.fd_slots_by_source.putAssumeCapacity(source.source_id, slot_index);
        return true;
    }

    fn retireDepartedFdSlots(self: *Driver) bool {
        var queued = false;
        var index: usize = 0;
        while (index < self.fd_slots.items.len) : (index += 1) {
            const slot = &self.fd_slots.items[index];
            switch (slot.state) {
                .empty, .tombstone => continue,
                .armed, .disarmed => {},
            }
            if (slot.last_stamp == self.sync_stamp)
                continue;
            _ = self.fd_slots_by_source.remove(slot.source_id);
            if (slot.state == .armed) {
                self.tombstoneFdSlot(@intCast(index));
                queued = true;
            } else {
                self.freeFdSlot(@intCast(index));
            }
        }
        return queued;
    }

    /// Admits a new or reshaped source into the watch table. Admission past
    /// the armed-watch cap fails only this source, with a named error, and
    /// is ruled before any slot or map allocation, so a rejected admission
    /// leaves no footprint. The caller records the rejection and the wait
    /// serves it as a `.failed` result, so the owner settles exactly one
    /// fetch instead of escalating a full desired set into a shard-wide
    /// teardown.
    fn admitFdSlot(self: *Driver, source: Source, fd: std.posix.fd_t, mask: u32) !u16 {
        try self.ensureArmCapacity();
        // The map entry is reserved up front so the caller's
        // putAssumeCapacity after a successful arm cannot fail, and an armed
        // slot is never stranded without its source_id mapping.
        try self.fd_slots_by_source.ensureUnusedCapacity(self.allocator, 1);
        const slot_index = try self.acquireFdSlot();
        self.armFdSlot(slot_index, source.context, fd, mask) catch |err| {
            self.freeFdSlot(slot_index);
            return err;
        };
        self.fd_slots.items[slot_index].source_id = source.source_id;
        return slot_index;
    }

    /// Rules on the armed-watch cap for one prospective arm. Only live arms
    /// count: tombstones gave back their share of the cap when they retired,
    /// and disarmed slots hold no kernel arm. An arm that completed but whose
    /// CQE is still unread counts as live, so the CQ is reaped before an
    /// admission is refused, and cancel and re-arm churn cannot inflate the
    /// count into a spurious rejection.
    fn ensureArmCapacity(self: *Driver) !void {
        if (self.liveArmedWatchCount() < max_armed_fd_watches)
            return;
        try self.reapCompletionsForCap();
        if (self.liveArmedWatchCount() >= max_armed_fd_watches)
            return error.EgressFdWatchLimitExceeded;
    }

    /// Records a cap rejection for exactly one source per reconcile; the
    /// wait serves it as the named `.failed` result. See
    /// `pending_admission_failure` for why one is enough.
    fn recordAdmissionRejection(self: *Driver, source: Source) void {
        if (self.pending_admission_failure != null)
            return;
        self.pending_admission_failure = .{
            .context = source.context,
            .err = error.EgressFdWatchLimitExceeded,
        };
    }

    fn acquireFdSlot(self: *Driver) !u16 {
        if (self.fd_free_head != no_free_slot) {
            const index = self.fd_free_head;
            self.fd_free_head = self.fd_slots.items[index].next_free;
            return index;
        }
        if (self.fd_slots.items.len >= no_free_slot)
            return error.EgressFdWatchLimitExceeded;
        const index: u16 = @intCast(self.fd_slots.items.len);
        try self.fd_slots.append(self.allocator, .{});
        return index;
    }

    /// Arms a one-shot POLL_ADD for the slot under a fresh epoch. The slot is
    /// marked armed only after the SQ accepted the SQE and `sync_ops` holds
    /// its queue position, so a failed flush rolls back exactly the
    /// unsubmitted arms; an allocation or SQ failure leaves the table and the
    /// kernel consistent.
    fn armFdSlot(self: *Driver, slot_index: u16, context: *anyopaque, fd: std.posix.fd_t, mask: u32) !void {
        try self.ensureArmCapacity();
        try self.sync_ops.ensureUnusedCapacity(self.allocator, 1);
        const epoch = self.fd_slots.items[slot_index].epoch +% 1;
        try self.queuePollAdd(packFdPollToken(slot_index, epoch), fd, mask);
        self.sync_ops.appendAssumeCapacity(.{ .kind = .arm, .slot = slot_index, .epoch = epoch });
        const slot = &self.fd_slots.items[slot_index];
        slot.epoch = epoch;
        slot.armed_epoch = epoch;
        slot.state = .armed;
        slot.fd = fd;
        slot.events = mask;
        slot.context = context;
        slot.last_stamp = self.sync_stamp;
        self.armed_fd_count += 1;
        _ = self.live_armed_fd_count.fetchAdd(1, .monotonic);
    }

    /// Retires an armed slot asynchronously. The epoch bump invalidates the
    /// outstanding token before any late readiness can be interpreted, the
    /// POLL_REMOVE hastens the terminal CQE, and the tombstone holds the slot
    /// until that terminal arrives; readiness before the cancel, -ENOENT and
    /// -ECANCELED all land on the same path. It never drains synchronously.
    /// A POLL_REMOVE the SQ refuses leaves the slot marked unqueued for retry
    /// on every sync and wait pass, since a silent fd would otherwise hold
    /// the tombstone, and its armed count, forever.
    fn tombstoneFdSlot(self: *Driver, slot_index: u16) void {
        const slot = &self.fd_slots.items[slot_index];
        std.debug.assert(slot.state == .armed);
        slot.epoch +%= 1;
        slot.state = .tombstone;
        slot.cancel_queued = false;
        self.unqueued_cancel_count += 1;
        _ = self.live_armed_fd_count.fetchSub(1, .monotonic);
        self.clearSlotReady(slot);
        self.tryQueuePollRemove(slot_index);
    }

    fn freeFdSlot(self: *Driver, slot_index: u16) void {
        const slot = &self.fd_slots.items[slot_index];
        self.clearSlotReady(slot);
        if (slot.state == .tombstone and !slot.cancel_queued)
            self.unqueued_cancel_count -= 1;
        // The epoch survives reuse: a free slot has no outstanding arm, but
        // a stale CQE must never match a later occupant's token.
        const preserved_epoch = slot.epoch;
        slot.* = .{ .epoch = preserved_epoch, .next_free = self.fd_free_head };
        self.fd_free_head = slot_index;
    }

    fn queuePollAdd(self: *Driver, token: u64, fd: std.posix.fd_t, mask: u32) !void {
        // The only queueing failure is a full SQ: the accepted chunk is
        // flushed and the SQE retried, so a sync larger than the ring
        // submits in batches.
        _ = self.ring.poll_add(token, fd, mask) catch {
            try self.flushSubmissions();
            _ = try self.ring.poll_add(token, fd, mask);
        };
    }

    /// Queues the POLL_REMOVE for a tombstoned slot. Only a cancel the SQ
    /// actually took clears the slot's unqueued mark; anything else stays
    /// flagged for retry instead of being presumed submitted.
    fn tryQueuePollRemove(self: *Driver, slot_index: u16) void {
        const slot = &self.fd_slots.items[slot_index];
        std.debug.assert(slot.state == .tombstone and !slot.cancel_queued);
        const target = packFdPollToken(slot_index, slot.armed_epoch);
        const cancel_user_data = UserData.pack(.{ .kind = .cancel, .generation = 1, .index = slot_index }) catch return;
        self.sync_ops.ensureUnusedCapacity(self.allocator, 1) catch return;
        _ = self.ring.poll_remove(cancel_user_data, target) catch {
            // SQ full: flush the accepted chunk (EBUSY-aware) and retry
            // once. On failure the tombstone stays marked for requeue; the
            // token is already invalidated either way.
            self.flushSubmissions() catch |flush_err| {
                std.log.debug("egress data io fd poll cancel flush failed: {s}", .{@errorName(flush_err)});
                return;
            };
            // The flush may have ingested this tombstone's terminal
            // (readiness raced the cancel); then the slot is already freed
            // and needs no cancel.
            if (slot.state != .tombstone or slot.cancel_queued)
                return;
            _ = self.ring.poll_remove(cancel_user_data, target) catch |retry_err| {
                std.log.debug("egress data io fd poll cancel failed: {s}", .{@errorName(retry_err)});
                return;
            };
        };
        self.sync_ops.appendAssumeCapacity(.{ .kind = .cancel, .slot = slot_index, .epoch = slot.armed_epoch });
        slot.cancel_queued = true;
        self.unqueued_cancel_count -= 1;
    }

    /// Retries every tombstone whose POLL_REMOVE never reached the SQ.
    /// Returns true when at least one cancel was queued this call.
    fn requeueUnqueuedCancels(self: *Driver) bool {
        var queued = false;
        var index: usize = 0;
        while (index < self.fd_slots.items.len) : (index += 1) {
            if (self.unqueued_cancel_count == 0)
                break;
            const slot = &self.fd_slots.items[index];
            if (slot.state != .tombstone or slot.cancel_queued)
                continue;
            self.tryQueuePollRemove(@intCast(index));
            if (slot.state == .tombstone and slot.cancel_queued)
                queued = true;
        }
        return queued;
    }

    /// The last `sq_ready()` SQEs queued by this sync never reached the
    /// kernel: consumption is FIFO and the flush error stopped the rest. Arms
    /// roll back to `.disarmed` under a fresh token, keeping the desired
    /// source's slot for the next sync to re-arm, and cancels mark their
    /// tombstone for requeue. The unsent SQEs stay in the SQ and go out with
    /// a later flush; the token bump makes any completion they produce stale
    /// on arrival.
    fn rollbackUnsubmittedSyncOps(self: *Driver) void {
        var remaining = self.ring.sq_ready();
        var index = self.sync_ops.items.len;
        while (remaining > 0 and index > 0) {
            index -= 1;
            remaining -= 1;
            const op = self.sync_ops.items[index];
            if (op.slot >= self.fd_slots.items.len)
                continue;
            const slot = &self.fd_slots.items[op.slot];
            switch (op.kind) {
                .arm => {
                    if (slot.state != .armed or slot.armed_epoch != op.epoch)
                        continue;
                    slot.epoch +%= 1;
                    slot.state = .disarmed;
                    self.armed_fd_count -= 1;
                    _ = self.live_armed_fd_count.fetchSub(1, .monotonic);
                },
                .cancel => {
                    if (slot.state != .tombstone or slot.armed_epoch != op.epoch)
                        continue;
                    if (slot.cancel_queued) {
                        slot.cancel_queued = false;
                        self.unqueued_cancel_count += 1;
                    }
                },
            }
        }
    }

    fn clearSlotReady(self: *Driver, slot: *FdSlot) void {
        if (slot.ready_pending) {
            self.fd_ready_count -= 1;
            slot.ready_pending = false;
        }
        slot.ready_readable = false;
        slot.ready_writable = false;
        slot.ready_fault = false;
    }

    // ── Wait plumbing ───────────────────────────────────────────────────

    /// Arms recv and send SQEs for every connection source that wants I/O,
    /// at most once per direction (`recv_queued` and the transport's
    /// in-flight flags), and flushes what it queued, so the kernel holds the
    /// wanted I/O even when this pass serves a coalesced result without
    /// blocking. Raw-fd polls belong to `syncSources`.
    fn queueConnectionIo(self: *Driver, sources: []const Source) !void {
        var queued = false;
        var generation: u16 = 0;
        for (sources) |source| {
            const connection = source.connection orelse continue;

            const want_send = (source.want_write or connection.hasCiphertextToSend()) and connection.networkWantsWrite();
            const want_recv = source.want_read and connection.networkWantsRead();
            if (!want_recv and !want_send)
                continue;

            const index = self.findRegistrationIndex(connection) orelse return error.EgressDataRegistrationMissing;
            // A recorded failure is served before the connection is touched
            // again. Queueing a fresh recv or send here would hand the kernel
            // I/O on a socket the owner is about to tear down, and fail it
            // again in a loop ahead of the result that reports it.
            if (self.registrations.items[index].failure != null)
                continue;
            if (generation == 0)
                generation = self.nextGeneration();
            const registration_index: u32 = @intCast(index);
            if (want_recv) {
                if (!self.registrations.items[index].recv_queued) {
                    const user_data = try UserData.pack(.{ .kind = .recv, .generation = generation, .index = registration_index });
                    if (try self.ensureProvidedMultishot()) {
                        if (self.provided_recv) |*provided| {
                            // A full SQ is the only queueing failure: flush
                            // the accepted chunk and retry.
                            _ = provided.recv_multishot(user_data, connection.fd(), 0) catch {
                                try self.flushSubmissions();
                                _ = try provided.recv_multishot(user_data, connection.fd(), 0);
                            };
                        } else unreachable;
                        self.registrations.items[index].recv_submission = .provided_multishot;
                    } else {
                        _ = self.ring.recv(
                            user_data,
                            connection.fd(),
                            .{ .buffer = connection.recvSlice() },
                            0,
                        ) catch {
                            try self.flushSubmissions();
                            _ = try self.ring.recv(
                                user_data,
                                connection.fd(),
                                .{ .buffer = connection.recvSlice() },
                                0,
                            );
                        };
                        self.registrations.items[index].recv_submission = .one_shot;
                    }
                    connection.markRecvSubmitted();
                    const registration = &self.registrations.items[index];
                    registration.recv_queued = true;
                    registration.recv_user_data = user_data;
                    queued = true;
                }
            }
            if (want_send) {
                const user_data = try UserData.pack(.{ .kind = .send, .generation = generation, .index = registration_index });
                _ = self.ring.send(
                    user_data,
                    connection.fd(),
                    connection.sendCiphertextSlice(),
                    0,
                ) catch {
                    try self.flushSubmissions();
                    _ = try self.ring.send(
                        user_data,
                        connection.fd(),
                        connection.sendCiphertextSlice(),
                        0,
                    );
                };
                connection.markSendSubmitted();
                const registration = &self.registrations.items[index];
                registration.send_queued = true;
                registration.send_user_data = user_data;
                queued = true;
            }
        }
        if (queued)
            try self.flushSubmissions();
    }

    /// Arms the control completions for one blocking pass: the wake poll and
    /// the single timeout or watchdog tick. Connection I/O and fd polls are
    /// already armed by this point.
    fn queueWait(self: *Driver, generation: u16, sources: []const Source, wake_fd: ?std.posix.fd_t, now_ns: u64) !void {
        self.timeout_context = null;
        self.timeout_queued = false;
        self.wake_queued = false;

        const queued_or_inflight = self.hasQueuedDataCompletions() or self.armed_fd_count != 0;
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
            // A wait with live sources never sleeps unbounded. One lost
            // completion (an eventfd wake poll that never fires, a dropped
            // recv) would otherwise park the owner forever. Such losses do
            // occur, rarely, under WSL2, and a deadline paused by
            // backpressure (maxInt, so no kernel timeout) makes one
            // permanent. The tick caps the sleep and behaves like a wake: the
            // owner drains its message queue again, re-checks expirations and
            // re-arms.
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
            _ = self.ring.timeout(
                user_data,
                &self.timeout_storage,
                0,
                linux.IORING_TIMEOUT_ABS | linux.IORING_TIMEOUT_BOOTTIME,
            ) catch {
                try self.flushSubmissions();
                _ = try self.ring.timeout(
                    user_data,
                    &self.timeout_storage,
                    0,
                    linux.IORING_TIMEOUT_ABS | linux.IORING_TIMEOUT_BOOTTIME,
                );
            };
            self.timeout_queued = true;
        }

        if (!queued_or_inflight and !self.wake_queued and !self.timeout_queued)
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
                    // submit again instead of failing the wait. The drain is
                    // bounded only by its budget, so it frees space even
                    // when a result is already pending.
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
    /// a deadline, then coalesced ready-state, then any control completion
    /// stashed while draining.
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
        if (self.pending_admission_failure != null)
            return true;
        if (self.fd_ready_count != 0)
            return true;
        for (self.registrations.items) |registration| {
            if (registration.active and registration.hasReadyState())
                return true;
        }
        return false;
    }

    /// Preemption predicate for ingestion: a failure the wait owes the
    /// owner. It is cheap because the registration list holds a handful of
    /// connections and the admission failure is a single slot.
    fn hasFailureResults(self: *const Driver) bool {
        if (self.pending_admission_failure != null)
            return true;
        for (self.registrations.items) |registration| {
            if (registration.active and registration.failure != null)
                return true;
        }
        return false;
    }

    /// One result per wait, served from coalesced ready-state. Failures
    /// outrank readiness; rotating cursors and alternation between
    /// connections and fd watches keep a permanently ready source from
    /// starving the others.
    fn takeReadyResult(self: *Driver) ?Result {
        if (self.pending_admission_failure) |failure| {
            // Watch admission was rejected at the cap: fail exactly this
            // source with the named error. The owner settles one fetch and
            // the rest of the shard keeps its arms.
            self.pending_admission_failure = null;
            return .{ .failed = failure };
        }
        if (self.serve_fd_first) {
            if (self.takeFdReadyResult()) |result| {
                self.serve_fd_first = false;
                return result;
            }
            return self.takeConnectionReadyResult();
        }
        if (self.takeConnectionReadyResult()) |result| {
            self.serve_fd_first = true;
            return result;
        }
        return self.takeFdReadyResult();
    }

    fn takeConnectionReadyResult(self: *Driver) ?Result {
        const len = self.registrations.items.len;
        if (len == 0)
            return null;
        var offset: usize = 0;
        while (offset < len) : (offset += 1) {
            const index = (self.serve_conn_cursor + offset) % len;
            const registration = &self.registrations.items[index];
            if (!registration.active or !registration.hasReadyState())
                continue;
            self.serve_conn_cursor = (index + 1) % len;
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

    fn takeFdReadyResult(self: *Driver) ?Result {
        if (self.fd_ready_count == 0)
            return null;
        const len = self.fd_slots.items.len;
        if (len == 0)
            return null;
        var offset: usize = 0;
        while (offset < len) : (offset += 1) {
            const index = (self.serve_fd_cursor + offset) % len;
            const slot = &self.fd_slots.items[index];
            if (!slot.ready_pending)
                continue;
            self.serve_fd_cursor = (index + 1) % len;
            // As in the readiness driver, a faulted poll reports ready in
            // both directions so the caller's own syscall surfaces the real
            // errno.
            const result: Result = .{ .ready = .{
                .context = slot.context,
                .readable = slot.ready_readable or slot.ready_fault,
                .writable = slot.ready_writable or slot.ready_fault,
            } };
            self.clearSlotReady(slot);
            return result;
        }
        return null;
    }

    // ── Eager CQE ingestion ─────────────────────────────────────────────

    /// Copies and ingests at most one batch of CQEs. Never blocks. Returns
    /// the number copied; fewer than a full batch means the CQ was observed
    /// empty afterwards.
    fn ingestCompletionBatch(self: *Driver) !usize {
        while (true) {
            var cqes: [max_cqes_per_copy]linux.io_uring_cqe = undefined;
            // std's copy_cqes enters the kernel when the CQ overflow flag is
            // set, so it can fail with EINTR; retry as `enter` does instead
            // of failing the wait.
            const count = self.ring.copy_cqes(&cqes, 0) catch |err| switch (err) {
                error.SignalInterrupt => continue,
                else => return err,
            };
            for (cqes[0..count]) |cqe|
                self.ingestCqe(cqe);
            return count;
        }
    }

    /// CQE drain bounded by the batch budget, without preemption. It runs
    /// where CQ space must be freed unconditionally, in EBUSY recovery for a
    /// flush or for the blocking wait, so an already pending result can never
    /// block the reap that makes room for it, while a CQ that keeps refilling
    /// still cannot hold the caller past the budget.
    fn drainCompletions(self: *Driver) !void {
        var batches: usize = 0;
        while (batches < max_ingest_batches_per_drain) : (batches += 1) {
            if ((try self.ingestCompletionBatch()) < max_cqes_per_copy) {
                // CQ observed empty: every provided buffer is back on its
                // ring, so a NOBUFS suspension can lift.
                self.restoreProvidedMultishotIfDrained();
                return;
            }
        }
    }

    /// Ingestion at the wait's serving points, bounded and preemptible: an
    /// expired deadline, a recorded failure or a stashed control result
    /// outranks any completion backlog and stops intake before the next
    /// batch. Plain readiness does not preempt, because a permanently ready
    /// backlog must keep ingesting so HTTP/2 provided buffers recycle; the
    /// budget alone bounds that path. Whatever stays unread waits in the CQ
    /// for the next pass.
    fn drainCompletionsPreemptible(self: *Driver, earliest_deadline_ns: u64) !void {
        var batches: usize = 0;
        while (batches < max_ingest_batches_per_drain) : (batches += 1) {
            if (self.stashed_result != null or self.hasFailureResults())
                return;
            if (earliest_deadline_ns != std.math.maxInt(u64)) {
                if ((try monotonicNowNs()) >= earliest_deadline_ns)
                    return;
            }
            if ((try self.ingestCompletionBatch()) < max_cqes_per_copy) {
                // The CQ was observed empty, not merely out of budget, so a
                // NOBUFS suspension can lift.
                self.restoreProvidedMultishotIfDrained();
                return;
            }
        }
    }

    /// Drain before a cap ruling: ingests up to one full CQ's worth, so
    /// completed arms whose terminals sit unread cannot inflate the live
    /// count into a spurious cap rejection. It is still bounded, so an
    /// adversarial completion stream cannot hold the admission path.
    fn reapCompletionsForCap(self: *Driver) !void {
        var batches: usize = 0;
        const max_batches: usize = (cq_ring_entries / max_cqes_per_copy) + 1;
        while (batches < max_batches) : (batches += 1) {
            if ((try self.ingestCompletionBatch()) < max_cqes_per_copy) {
                self.restoreProvidedMultishotIfDrained();
                return;
            }
        }
    }

    /// Ingests one CQE at once. HTTP/2 recv and send completions feed the
    /// BIO and release provided buffers immediately (holding them behind a
    /// backlog starves the small provided-buffer ring into NOBUFS), then
    /// coalesce into per-registration ready flags. Fd polls validate their
    /// full token, coalesce into per-slot ready bits and disarm the slot.
    /// Control completions of the active wait generation are stashed for the
    /// serving point. Stale tokens are dropped; poll is level-triggered, so
    /// nothing is lost.
    fn ingestCqe(self: *Driver, cqe: linux.io_uring_cqe) void {
        const user_data = UserData.unpack(cqe.user_data) catch return;
        switch (user_data.kind) {
            .recv, .send => self.ingestDataCompletion(user_data, cqe.res, cqe.flags),
            .fd_poll => self.ingestFdPollCompletion(user_data.generation, user_data.index, cqe.res),
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

    fn ingestDataCompletion(self: *Driver, user_data: UserData, res: i32, flags: u32) void {
        const index: usize = @intCast(user_data.index);
        if (index >= self.registrations.items.len)
            return;
        const registration = &self.registrations.items[index];
        const connection = registration.connection orelse return;
        const recv_submission: RecvSubmission = if (user_data.kind == .recv) registration.recv_submission else .none;
        const completed_user_data = UserData.pack(user_data) catch return;
        if (user_data.kind == .recv) {
            if (!registration.recv_queued or registration.recv_user_data != completed_user_data)
                return;
            if (recv_submission != .provided_multishot or (flags & linux.IORING_CQE_F_MORE) == 0) {
                registration.recv_queued = false;
                registration.recv_submission = .none;
                connection.markRecvComplete();
            }
        } else {
            if (!registration.send_queued or registration.send_user_data != completed_user_data)
                return;
            registration.send_queued = false;
            connection.markSendComplete();
        }

        if (!registration.active) {
            if (user_data.kind == .recv and res > 0 and recv_submission == .provided_multishot) {
                const cqe = linux.io_uring_cqe{
                    .user_data = completed_user_data,
                    .res = res,
                    .flags = flags,
                };
                self.releaseProvidedBuffer(cqe);
            }
            return;
        }
        if (res < 0) {
            const errno = errnoFromResult(res) orelse {
                registration.noteFailure(error.EgressDataIoFailed);
                return;
            };
            if (user_data.kind == .recv and errno == .NOBUFS) {
                self.disableProvidedMultishot();
                registration.ready_readable = true;
                return;
            }
            if (user_data.kind == .recv and errno == .CONNRESET) {
                _ = connection.feedReceivedCiphertext(0) catch |err| {
                    registration.noteFailure(err);
                    return;
                };
                registration.ready_readable = true;
                return;
            }
            registration.noteFailure(errnoToError(errno));
            return;
        }

        if (user_data.kind == .recv) {
            if (res == 0) {
                _ = connection.feedReceivedCiphertext(0) catch |err| {
                    registration.noteFailure(err);
                    return;
                };
                registration.ready_readable = true;
                return;
            }
            const received_len: usize = @intCast(res);
            connection.recordCiphertextReceived(received_len);
            if (recv_submission == .provided_multishot) {
                const cqe = linux.io_uring_cqe{
                    .user_data = completed_user_data,
                    .res = res,
                    .flags = flags,
                };
                const bytes = self.providedBufferBytes(cqe) catch |err| {
                    registration.noteFailure(err);
                    return;
                };
                // The provided buffer stays alive across the feed call,
                // during which BoringSSL's memory read BIO copies the bytes
                // straight from it, and the transport stages any bytes the
                // BIO does not accept before the feed returns. Either way
                // the buffer can go back to the kernel ring at once, so it
                // never outlives this completion and never crosses driver
                // threads when a connection migrates at handshake handoff.
                defer self.releaseProvidedBuffer(cqe);
                _ = connection.feedCiphertext(bytes) catch |err| {
                    registration.noteFailure(err);
                    return;
                };
            } else {
                _ = connection.feedReceivedCiphertext(received_len) catch |err| {
                    registration.noteFailure(err);
                    return;
                };
            }
            registration.ready_readable = true;
            return;
        }

        if (res == 0) {
            registration.noteFailure(error.FetchWriteFailed);
            return;
        }
        connection.recordCiphertextSent(@intCast(res));
        connection.advanceSentCiphertext(@intCast(res)) catch |err| {
            registration.noteFailure(err);
            return;
        };
        registration.ready_writable = true;
    }

    /// Validates the full token of a persistent poll completion: the slot and
    /// the epoch must both match the outstanding arm. Every accepted POLL_ADD
    /// yields exactly one CQE (readiness or -ECANCELED), so a matching CQE is
    /// that arm's terminal: an armed slot disarms and records ready bits, a
    /// tombstone is reaped, and anything else is a stale token from an older
    /// arm and is dropped.
    fn ingestFdPollCompletion(self: *Driver, slot_raw: u16, epoch: u32, res: i32) void {
        const slot_index: usize = slot_raw;
        if (slot_index >= self.fd_slots.items.len)
            return;
        const slot = &self.fd_slots.items[slot_index];
        switch (slot.state) {
            .empty, .disarmed => return,
            .armed, .tombstone => {},
        }
        if (epoch != slot.armed_epoch)
            return;
        self.armed_fd_count -= 1;
        if (slot.state == .tombstone) {
            self.freeFdSlot(@intCast(slot_index));
            return;
        }
        slot.state = .disarmed;
        _ = self.live_armed_fd_count.fetchSub(1, .monotonic);
        if (epoch != slot.epoch)
            return; // token retired after arming; drop the readiness
        if (!slot.ready_pending) {
            slot.ready_pending = true;
            self.fd_ready_count += 1;
        }
        if (res < 0) {
            slot.ready_fault = true;
            return;
        }
        const events: u32 = @bitCast(res);
        if ((events & @as(u32, @intCast(std.posix.POLL.HUP | std.posix.POLL.ERR))) != 0)
            slot.ready_fault = true;
        if ((events & @as(u32, @intCast(std.posix.POLL.IN))) != 0)
            slot.ready_readable = true;
        if ((events & @as(u32, @intCast(std.posix.POLL.OUT))) != 0)
            slot.ready_writable = true;
    }

    fn providedBufferBytes(self: *Driver, cqe: linux.io_uring_cqe) ![]const u8 {
        if (self.provided_recv) |*provided|
            return try provided.get(cqe);
        return error.EgressProvidedRecvMissing;
    }

    fn releaseProvidedBuffer(self: *Driver, cqe: linux.io_uring_cqe) void {
        if (self.provided_recv) |*provided|
            provided.put(cqe) catch |err| std.log.debug("egress provided recv release failed: {s}", .{@errorName(err)});
    }

    fn deinitProvidedRecv(self: *Driver) void {
        if (self.provided_recv) |*provided| {
            unregisterProvidedRecvQuiet(self.ring.fd, provided.group_id);

            var mmap: []align(std.heap.page_size_min) const u8 = undefined;
            mmap.ptr = @ptrCast(@alignCast(provided.br));
            mmap.len = @as(usize, provided.buffers_count) * @sizeOf(linux.io_uring_buf);
            std.posix.munmap(mmap);

            self.allocator.free(provided.buffers);
            self.allocator.free(provided.heads);
            self.provided_recv = null;
        }
    }

    fn unregisterProvidedRecvQuiet(ring_fd: std.posix.fd_t, group_id: u16) void {
        var reg = std.mem.zeroInit(linux.io_uring_buf_reg, .{
            .bgid = group_id,
        });
        const res = linux.io_uring_register(
            ring_fd,
            .UNREGISTER_PBUF_RING,
            @as(*const anyopaque, @ptrCast(&reg)),
            1,
        );
        switch (linux.E.init(res)) {
            // Ring teardown frees the buffer ring anyway, so refusals are
            // expected: ACCES from a sealed ring, whose restrictions allow
            // only REGISTER_ENABLE_RINGS, and PERM from the gateway's seccomp
            // filter, which blocks io_uring_register.
            .SUCCESS, .ACCES, .BADF, .INVAL, .PERM => {},
            else => |errno| std.log.debug("egress provided recv unregister failed: {s}", .{@tagName(errno)}),
        }
    }

    fn disableProvidedMultishot(self: *Driver) void {
        if (self.recv_strategy != .provided_multishot)
            return;
        std.log.debug("egress provided multishot recv suspended after kernel NOBUFS", .{});
        self.recv_strategy = .one_shot;
        self.provided_multishot_suspensions += 1;
        // NOBUFS means every provided buffer sat in unread CQEs behind an
        // ingestion budget boundary, a transient backlog rather than a broken
        // ring. The strategy is suspended instead of downgraded for good: the
        // next drain that observes the CQ empty has returned every buffer to
        // the ring and restores it.
        self.provided_multishot_suspended = true;
        for (self.registrations.items) |*registration| {
            if (registration.recv_submission == .provided_multishot and !registration.recv_queued)
                registration.recv_submission = .none;
        }
    }

    /// Re-enables provided multishot after a NOBUFS suspension. Called only
    /// where a drain observed the CQ empty: every provided buffer a CQE held
    /// has been ingested and returned to the kernel-owned buffer ring, so a
    /// fresh multishot arm cannot fault again at once, and the driver keeps
    /// its cheaper recv path instead of paying for one-shot recv forever.
    fn restoreProvidedMultishotIfDrained(self: *Driver) void {
        if (!self.provided_multishot_suspended)
            return;
        self.provided_multishot_suspended = false;
        if (self.provided_recv == null)
            return;
        std.log.debug("egress provided multishot recv restored after NOBUFS backlog drained", .{});
        self.recv_strategy = .provided_multishot;
    }

    /// Control cancels go through the EBUSY-aware flush like every other
    /// submission; a plain submit under CQ pressure fails with EBUSY and
    /// leaves the wake poll and timeout armed. A full SQ flushes the accepted
    /// chunk and retries once. A flush that still fails is logged, and the
    /// leftover SQEs go out with the next flush; their completions carry
    /// this generation and are dropped as stale.
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
    /// has consumed every queued SQE (`sq_ready() == 0`): io_uring_enter
    /// reports how many entries it took, and a short submission (async-worker
    /// pressure mid-batch) must retry the remainder instead of reporting
    /// success. Each enter either consumes SQEs or surfaces the blocked
    /// entry's error, so the loop ends.
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
                    // The kernel says this fd is not an io_uring instance,
                    // so the ring this driver armed is unreachable for good.
                    self.ring_dead = true;
                    return error.OpcodeNotSupported;
                },
                // A stray signal interrupts only the completion wait. The
                // kernel returns the submitted count when it consumed SQEs,
                // so EINTR means nothing was submitted and retrying with the
                // same arguments is safe. Failing instead would fail every
                // in-flight HTTP/2 fetch, because the owner treats a wait
                // error as fatal to its work.
                .INTR => continue,
                else => |errno| return std.posix.unexpectedErrno(errno),
            }
        }
    }

    /// Returns true when the registration was released (its terminal CQEs
    /// consumed, or abandoned on a dead ring) and the connection's owner may
    /// tear it down. Returns false when the cancel is unconfirmed on a live
    /// ring: the kernel's in-flight recv and send SQEs still reference the
    /// transport's buffers, so the registration is quarantined with the
    /// connection pinned and ownership passes to the driver.
    fn cancelRegistration(self: *Driver, index: usize, close_socket: bool) bool {
        if (index >= self.registrations.items.len)
            return true;
        const registration = &self.registrations.items[index];
        // A quarantined registration is already driver-owned, so releasing
        // it also deinits the pinned transport.
        const driver_owned = registration.quarantined;
        registration.active = false;
        registration.clearReadyState();
        if (!registration.hasQueuedData()) {
            releaseRegistration(registration, driver_owned);
            return true;
        }
        // A dead ring posts no further CQEs, so the synchronous drain below
        // would block forever, or panic on its copy_cqes error, on exactly
        // the failure path that tears every pooled entry down. Ring teardown
        // is what cancels the in-flight kernel operations; abandoning the
        // bookkeeping only makes any CQE copied later drop at ingestion,
        // since its token no longer matches queued state.
        if (self.ring_dead) {
            abandonAndRelease(registration, driver_owned);
            return true;
        }
        if (close_socket) {
            if (registration.connection) |connection|
                connection.shutdownSocketForCancel();
        }
        // Every cancel goes through the EBUSY-aware flush (chunked retry on
        // a full SQ, drain and retry on CQ overcommit), and the synchronous
        // terminal drain below starts only once the kernel has confirmably
        // consumed every required cancel and, FIFO, every SQE queued before
        // it. An unconfirmed cancel against a silent peer would otherwise
        // park this teardown forever on a CQE that never comes.
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
            // The flush may have just discovered the dead ring; then no CQE
            // will ever come and abandoning is the only exit.
            if (self.ring_dead) {
                abandonAndRelease(registration, driver_owned);
                return true;
            }
            // On a live ring an unconfirmed cancel must not abandon: the
            // original recv and send SQEs are still in the kernel and still
            // reference the transport's buffers, so dropping the bookkeeping
            // here would let the caller free memory the kernel writes into.
            // The registration is quarantined instead: the connection stays
            // pinned and the driver owns it, the slot is never reused, the
            // cancel is retried on later sync and wait passes, and the
            // transport is released only once its terminal CQEs are
            // consumed.
            registration.quarantined = true;
            registration.cancel_unconfirmed = true;
            std.log.warn("egress data io cancel unconfirmed; quarantining registration until its terminals arrive", .{});
            return false;
        }

        while (registration.hasQueuedData()) {
            // The submit above may have just discovered the dead ring: the
            // cancel SQEs never reached the kernel and no CQE will come, so
            // waiting for one would hang the teardown.
            if (self.ring_dead) {
                abandonAndRelease(registration, driver_owned);
                return true;
            }
            var cqes: [max_cqes_per_copy]linux.io_uring_cqe = undefined;
            // A stray signal during teardown retries instead of panicking
            // the whole process.
            const count = self.ring.copy_cqes(&cqes, 1) catch |err| switch (err) {
                error.SignalInterrupt => continue,
                // Anything else here concerns the ring itself, since NODROP
                // absorbs CQ pressure: mark the ring dead and abandon instead
                // of panicking mid-teardown.
                else => {
                    self.ring_dead = true;
                    std.log.warn("egress data io cancellation drain failed; abandoning dead ring: {s}", .{@errorName(err)});
                    abandonAndRelease(registration, driver_owned);
                    return true;
                },
            };
            // Everything drained here is ingested at once, so other
            // registrations and fd watches keep their completions as
            // coalesced ready-state instead of having them deferred or
            // dropped.
            for (cqes[0..count]) |cqe|
                self.ingestCqe(cqe);
        }
        registration.clearReadyState();
        releaseRegistration(registration, driver_owned);
        return true;
    }

    /// Final release of a registration's connection slot. When the driver
    /// owns the transport (a quarantine), releasing it also deinits the
    /// transport; the original caller lost ownership when its cancel returned
    /// unconfirmed.
    fn releaseRegistration(registration: *Registration, driver_owned: bool) void {
        const connection = registration.connection;
        registration.quarantined = false;
        registration.cancel_unconfirmed = false;
        registration.connection = null;
        if (driver_owned) {
            if (connection) |pinned|
                pinned.deinit();
        }
    }

    fn abandonAndRelease(registration: *Registration, driver_owned: bool) void {
        const connection = registration.connection;
        abandonRegistration(registration);
        registration.quarantined = false;
        registration.cancel_unconfirmed = false;
        if (driver_owned) {
            if (connection) |pinned|
                pinned.deinit();
        }
    }

    /// Requeues the ASYNC_CANCELs of quarantined registrations that the
    /// kernel never confirmably received, then flushes. Only a fully consumed
    /// SQ (`flushSubmissions` success) marks them confirmed; anything else
    /// retries on the next pass. A duplicate cancel for an operation that
    /// already completed only posts a `.cancel` CQE, which ingestion ignores.
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
    /// releases the transport it pinned; the driver took ownership when the
    /// caller's cancel returned unconfirmed.
    fn releaseQuarantinedRegistrations(self: *Driver) void {
        for (self.registrations.items) |*registration| {
            if (!registration.quarantined or registration.hasQueuedData())
                continue;
            const connection = registration.connection;
            registration.* = .{};
            if (connection) |pinned|
                pinned.deinit();
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

    /// Ring-dead teardown: no CQE will ever retire the queued SQEs, so the
    /// bookkeeping is dropped instead of drained. Late completions that still
    /// surface from the mapped CQ (the ring memory outlives the fd) no longer
    /// match any queued token and fall through ingestion harmlessly.
    fn abandonRegistration(registration: *Registration) void {
        registration.recv_queued = false;
        registration.send_queued = false;
        registration.recv_submission = .none;
        registration.clearReadyState();
        registration.connection = null;
    }

    fn hasQueuedDataCompletions(self: *const Driver) bool {
        for (self.registrations.items) |registration| {
            if (registration.recv_queued or registration.send_queued)
                return true;
        }
        return false;
    }

    fn clearIdleRegistrations(self: *Driver) void {
        for (self.registrations.items) |*registration| {
            // A quarantined slot pins a driver-owned transport; clearing the
            // pointer here would leak it, so only the quarantine release
            // paths free it.
            if (registration.quarantined)
                continue;
            if (!registration.hasQueuedData() and !registration.hasReadyState()) {
                registration.connection = null;
                registration.active = false;
            }
        }
    }

    fn ensureRegistration(self: *Driver, connection: *transport.TlsBioTransport) !usize {
        if (self.findRegistrationIndex(connection)) |index|
            return index;
        for (self.registrations.items, 0..) |registration, index| {
            if (registration.connection == null and !registration.hasQueuedData()) {
                self.registrations.items[index] = .{ .connection = connection };
                return index;
            }
        }
        const index = self.registrations.items.len;
        try self.registrations.append(self.allocator, .{ .connection = connection });
        return index;
    }

    fn findRegistrationIndex(self: *const Driver, connection: *transport.TlsBioTransport) ?usize {
        for (self.registrations.items, 0..) |registration, index| {
            if (registration.connection == connection)
                return index;
        }
        return null;
    }
};

const Registration = struct {
    context: *anyopaque = undefined,
    connection: ?*transport.TlsBioTransport = null,
    active: bool = false,
    recv_queued: bool = false,
    send_queued: bool = false,
    recv_submission: RecvSubmission = .none,
    recv_user_data: u64 = 0,
    send_user_data: u64 = 0,
    ready_readable: bool = false,
    ready_writable: bool = false,
    failure: ?anyerror = null,
    /// Set when a cancel could not be confirmed on a live ring: the kernel
    /// still holds SQEs that reference the transport's buffers, the driver
    /// owns the transport, the slot is never reused, and the transport is
    /// deinited once every terminal CQE is consumed
    /// (`releaseQuarantinedRegistrations`) or the ring dies.
    quarantined: bool = false,
    /// Quarantined only: the kernel has not yet confirmably consumed the
    /// ASYNC_CANCELs, so every sync and wait pass requeues them until it has.
    cancel_unconfirmed: bool = false,

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

/// One persistent fd-watch registration. Lifecycle: `.empty` (free-listed)
/// → `.armed` (one-shot POLL_ADD outstanding) → `.disarmed` (completed, with
/// ready bits pending or awaiting re-arm) and back, or `.armed` →
/// `.tombstone` (departed or reshaped while outstanding, freed by the
/// terminal CQE). `epoch` is the validity token and increments on every arm,
/// retirement and rolled-back arm; `armed_epoch` remembers the token the
/// outstanding arm carries, so its terminal CQE is recognized even after
/// invalidation.
const FdSlot = struct {
    state: State = .empty,
    source_id: u64 = 0,
    fd: std.posix.fd_t = -1,
    context: *anyopaque = undefined,
    events: u32 = 0,
    epoch: u32 = 0,
    armed_epoch: u32 = 0,
    last_stamp: u64 = 0,
    next_free: u16 = no_free_slot,
    ready_pending: bool = false,
    ready_readable: bool = false,
    ready_writable: bool = false,
    ready_fault: bool = false,
    /// Tombstones only: the SQ accepted the retiring POLL_REMOVE. False marks
    /// the cancel for requeue on the next sync or wait pass.
    cancel_queued: bool = false,

    const State = enum {
        empty,
        armed,
        disarmed,
        tombstone,
    };
};

/// One fd-watch SQE queued during a `syncSources` pass, in queue order, for
/// the rollback ledger. `epoch` tells apart slots recycled within one pass
/// (a tombstone terminal ingested by a mid-pass EBUSY drain frees its slot
/// for a later admission).
const SyncOp = struct {
    kind: enum { arm, cancel },
    slot: u16,
    epoch: u32,
};

const RecvSubmission = enum {
    none,
    one_shot,
    provided_multishot,
};

const CompletionKind = enum(u8) {
    recv = 1,
    send = 2,
    wake = 3,
    timeout = 4,
    cancel = 5,
    /// Watchdog tick: behaves like a wake (drain queues again, re-arm), so a
    /// single lost completion can never park the owner forever.
    tick = 6,
    /// Persistent one-shot readiness poll for a raw-fd source. Its token is
    /// `{tag:8, kind:8, slot:16, epoch:32}`: the slot takes the generation
    /// field and the per-slot epoch takes the index field, so a completion is
    /// honored only when both match the outstanding arm.
    fd_poll = 7,
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

/// fd_poll arm token `{tag:8, kind:8, slot:16, epoch:32}`. Slot 0 and epoch
/// 0 are valid here, unlike a control generation, so this packs outside
/// UserData.pack's zero check.
fn packFdPollToken(slot: u16, epoch: u32) u64 {
    return (tags.egress_high_byte << UserData.tag_shift) |
        (@as(u64, @intFromEnum(CompletionKind.fd_poll)) << UserData.kind_shift) |
        (@as(u64, slot) << UserData.generation_shift) |
        @as(u64, epoch);
}

fn pollMask(source: Source) u32 {
    var events: u32 = @intCast(std.posix.POLL.HUP | std.posix.POLL.ERR);
    if (source.want_read)
        events |= @intCast(std.posix.POLL.IN);
    if (source.want_write)
        events |= @intCast(std.posix.POLL.OUT);
    return events;
}

pub fn deadlineAfterMs(timeout_ms: u32) !u64 {
    return (try monotonicNowNs()) + @as(u64, timeout_ms) * ns_per_ms;
}

/// Reads CLOCK_BOOTTIME, the clock the ring's absolute
/// IORING_TIMEOUT_BOOTTIME timeouts compare against.
pub fn monotonicNowNs() !u64 {
    const ts = try std.posix.clock_gettime(std.posix.CLOCK.BOOTTIME);
    const sec: u64 = @intCast(ts.sec);
    const nsec: u64 = @intCast(ts.nsec);
    return sec * std.time.ns_per_s + nsec;
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

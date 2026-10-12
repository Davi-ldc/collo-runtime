//! The supervisor's record of one worker process, and the life of the storage
//! that holds it: vacant, then holding one launched worker from `occupy`
//! until `vacate`, then vacant again for the next launch of its pool entry.
//!
//! A record belongs to one entry of one worker definition's pool for the
//! server's life (`Supervisor.records` in `supervisor.zig`), so its
//! `definition_index` and `name` never change; the name is borrowed from the
//! configuration, which outlives every record. A vacant record has `id` 0,
//! an undefined `handle` and no mapped page. The worker key (`key`) tells
//! apart the workers one storage serves: a holder compares the key it took
//! when it got its slot or its reader role, and reads a record only while it
//! holds one of them, which keeps the record's worker in its pool's table.
//!
//! Threads: the launcher thread occupies a record before its pool publishes
//! the worker, and the reaper thread vacates it after the pool says no lane
//! holds or reads it, or the exiting thread does once the lanes stopped, so
//! neither overlaps a lane. While the worker serves, its egress session
//! (`egress_gateway_generation` and `egress_gateway_session_id`) changes on
//! the launcher thread and is read on the lanes, both under the mutex of the
//! record's pool (`Pool.visitWorker` in `pool.zig`). `metrics_mutex` guards
//! `page_mapped`, `boot_egress`, `boot_end_pending`, `log_drops_reported`,
//! both ring marks (`log_ring_failed` and `usage_ring_failed`) and the usage
//! and console cursors of the page view (`page.HostCursors`), and spans every
//! drain of the worker's usage and console rings: the metrics thread's, a
//! lane's settle, the reaper's final drain and the exiting thread's. The
//! view's completion cursor belongs to the worker's reader lane. The
//! forwarding window (`forwarded_in_queues`, `window_waiter`) and the body
//! waiters are atomics any lane reads and writes without a lock. Lock order:
//! `metrics_mutex` before the request table's own lock (`request_table.zig`),
//! and never held across the boot token's end (`Supervisor.progressBootEgress`);
//! `send_mutex` never nests with either.

const std = @import("std");
const ipc = @import("collo_ipc");
const process = @import("collo_os").process;
const process_limits = @import("collo_limits").process;
const server_limits = @import("collo_limits").server;
const server_lifecycle = @import("collo_server_lifecycle");
const config = @import("collo_server_config");

const host = @import("collo_host");
const request_table = @import("request_table.zig");
const page = @import("collo_worker_state").page;

/// The boot token's gateway, session and deadline, fixed at launch; a
/// reattach does not change them.
pub const BootToken = struct {
    gateway_generation: u64,
    session_id: u64,
    deadline_mono_ns: u64,
};

/// A boot token whose end is owed, and the worker it belongs to.
pub const BootEndAttempt = struct {
    worker_key: server_lifecycle.WorkerKey,
    token: BootToken,
};

pub const Record = struct {
    /// With `generation`, the worker's `WorkerKey`, assigned when the record
    /// is built for a publish. 0 while the record is vacant.
    id: u64,
    generation: u64 = 0,
    /// The worker's egress session: its gateway's generation and its id, 0
    /// for none. Guarded by the pool's mutex once the worker is published
    /// (see the file header).
    egress_gateway_generation: u64 = 0,
    egress_gateway_session_id: u64 = 0,
    /// The worker's wake set, which every egress session the server builds
    /// for it shares (`ipc.egress_shared.WakeSet`): the record keeps it from
    /// `occupy` until `vacate` closes it. Holding no write end, it never
    /// keeps the worker's exit from reaching a gateway. Empty for a worker
    /// of a definition without a `network` grant, which has no egress path.
    egress_wake_set: ipc.egress_shared.WakeSet = .{},
    /// The worker definition this storage serves; its pool is
    /// `Supervisor.pools[definition_index]`.
    definition_index: config.DefinitionIndex,
    /// The definition's name, borrowed from the configuration. Usage records
    /// and console lines carry it as the worker name.
    name: []const u8,
    /// The worker's process and channels, defined from `occupy` to `vacate`.
    handle: host.WorkerHandle,
    /// `ipc.max_message_bytes` bytes from the supervisor's allocator while the
    /// record holds a worker; `vacate` frees them.
    dispatch_send_scratch: []u8 = &.{},
    /// Spans one drain of the worker's usage and console rings and guards
    /// the fields the file header lists.
    metrics_mutex: std.Thread.Mutex = .{},
    /// The page is mapped and its rings may be drained. Set by `occupy`,
    /// cleared by the final drain (`usage_drain.drainFinal`) before `vacate`
    /// unmaps it, both under `metrics_mutex`; every drain checks it under the
    /// lock and skips a record without it.
    page_mapped: bool = false,
    /// The worker's boot token until its end went out to its gateway or its
    /// deadline passed; null for a worker launched without one. Guarded by
    /// `metrics_mutex`.
    boot_egress: ?BootToken = null,
    /// Set the first time the worker's startup-end flag reads 1, and kept
    /// until the end goes out. A worker that set the flag honestly and was
    /// compromised before a failed send got retried could otherwise clear it
    /// and keep the token until its deadline. Guarded by `metrics_mutex`.
    boot_end_pending: bool = false,
    /// Serializes the server-to-worker send channel. The per-worker
    /// `dispatch_send_scratch` and the shared payload ring writer are
    /// single-producer by construction (the ring is load, copy, store with no
    /// CAS), and any lane holding a slot of the worker may send to it. Any
    /// send that touches the worker scratch or the payload ring holds this
    /// mutex; control-fd-only frames encoded in lane-local scratch are safe
    /// without it, since a frame is one atomic SEQPACKET syscall.
    send_mutex: std.Thread.Mutex = .{},
    /// The requests dispatched to this worker and the completed ones whose
    /// usage record is still expected (`request_table.zig`).
    /// Locks itself.
    requests: request_table.RequestTable = .{},
    /// The forwarding window: the commands carrying this storage's workers'
    /// output that wait in lanes' queues. A descriptor the reader forwards is
    /// one unit from its post until its owner applies it, and a ring
    /// payload's unit moves on to the owner's answer until the reader takes
    /// it (`server/ingress/runner/h2_worker_ipc.zig`). The reader receives the
    /// worker's next packet only while a packet's worth of units still fits
    /// under `limits.ingress.forwarded_commands_per_worker_max`, which bounds
    /// the places one worker's output takes in any lane's queue. Units of one
    /// occupant can still be queued when the next one starts, so the count is
    /// never reset; every unit added is released once.
    forwarded_in_queues: std.atomic.Value(u32) = .init(0),
    /// The reader lane, plus one, that stopped receiving for want of room in
    /// the window, 0 for none. The release that makes room wakes it.
    window_waiter: std.atomic.Value(u16) = .init(0),
    /// For each worker slot, the lane, plus one, whose request on that slot
    /// waits for room in the server-to-worker payload ring, 0 for none. The
    /// worker writes its completion eventfd when it frees ring bytes after a
    /// writer marked the ring, and the reader lane wakes every lane named
    /// here (`server/ingress/runner/request_body.zig`).
    body_waiters: [server_limits.worker_concurrency_max]std.atomic.Value(u16) = @splat(.init(0)),
    created_mono_ns: u64 = 0,
    /// The worker's own boot as it stamped it on its page, from entering its
    /// namespaces to sending `WorkerReady`; 0 when a stamp was missing. A
    /// request that rode this worker's cold start reports it
    /// (`AccessFacts.cold_start_ns` in `server/analytics/access.zig`).
    boot_work_ns: u64 = 0,
    /// The console-log ring's drop counter as of the last drop marker: the
    /// next marker carries the delta against the ring's cumulative counter.
    /// Touched only by the ring's drains, under `metrics_mutex`.
    log_drops_reported: u64 = 0,
    /// A drain found the console-log ring fatal or corrupt. The fatal bit
    /// lives in worker-writable memory, so safety comes from this mark, not
    /// from the bit. Set once, under `metrics_mutex`; no drain reads the
    /// ring again.
    log_ring_failed: bool = false,
    /// A drain found the usage record ring's head where no append puts it
    /// (`RecordCursor.peek` in `common/worker_state/page/snapshots.zig`).
    /// Set once, under `metrics_mutex`; no drain reads the ring again, the
    /// worker's requests get floor records, and the metrics thread takes the
    /// worker out of service (`server/ingress/analytics_drain.zig`).
    usage_ring_failed: bool = false,

    /// What a launched worker brings to the record that holds it.
    pub const Occupant = struct {
        /// Fresh from the supervisor's counters, never 0.
        key: server_lifecycle.WorkerKey,
        /// Owned by the record from `occupy` until `vacate`.
        handle: host.WorkerHandle,
        /// `ipc.max_message_bytes` bytes from the supervisor's allocator,
        /// owned by the record from `occupy` until `vacate`.
        dispatch_send_scratch: []u8,
        /// The egress session the launch attached, 0 for none.
        egress_gateway_generation: u64,
        egress_gateway_session_id: u64,
        /// Owned by the record from `occupy` until `vacate`.
        egress_wake_set: ipc.egress_shared.WakeSet,
        created_mono_ns: u64,
        boot_work_ns: u64 = 0,
        boot_egress: ?BootToken = null,
    };

    /// A pool entry's storage before its first worker: vacant, with the
    /// definition fixed for the server's life.
    pub fn vacant(definition_index: config.DefinitionIndex, name: []const u8) Record {
        return .{
            .id = 0,
            .definition_index = definition_index,
            .name = name,
            .handle = undefined,
        };
    }

    pub fn key(self: *const Record) server_lifecycle.WorkerKey {
        return .{ .worker_id = self.id, .worker_generation = self.generation };
    }

    /// Puts a launched worker into this vacant record, which then owns the
    /// handle and the scratch. The launcher thread calls it while the
    /// record's pool entry is launching, so no lane, no reaper and no drain
    /// can see a field change; the page becomes drainable last, under the
    /// lock every drain takes, so a drain that finds it mapped sees every
    /// field this call wrote.
    pub fn occupy(self: *Record, occupant: Occupant) void {
        std.debug.assert(self.id == 0);
        std.debug.assert(occupant.key.worker_id != 0);
        self.id = occupant.key.worker_id;
        self.generation = occupant.key.worker_generation;
        self.egress_gateway_generation = occupant.egress_gateway_generation;
        self.egress_gateway_session_id = occupant.egress_gateway_session_id;
        self.egress_wake_set = occupant.egress_wake_set;
        self.handle = occupant.handle;
        self.dispatch_send_scratch = occupant.dispatch_send_scratch;
        // The previous worker's table is left behind with its page: no lane
        // holds a slot of a vacant record, and no drain passes `page_mapped`.
        self.requests = .{};
        // No lane waits on a worker it holds no slot of and does not read.
        // The window's count stays: units of the previous worker may still be
        // queued, and their release counts against it.
        self.window_waiter.store(0, .monotonic);
        for (&self.body_waiters) |*waiter|
            waiter.store(0, .monotonic);
        self.created_mono_ns = occupant.created_mono_ns;
        self.boot_work_ns = occupant.boot_work_ns;
        self.log_drops_reported = 0;
        self.log_ring_failed = false;
        self.usage_ring_failed = false;

        self.metrics_mutex.lock();
        defer self.metrics_mutex.unlock();
        self.boot_egress = occupant.boot_egress;
        self.boot_end_pending = false;
        self.page_mapped = self.handle.metrics != null;
    }

    /// The boot token to end now: the worker's, once its startup-end flag
    /// read 1 (`boot_end_pending`). Null while the end is not owed, and for a
    /// token past its deadline, which the record then forgets. The caller
    /// sends the end without this lock and reports success to
    /// `completeBootEnd`.
    pub fn bootEndAttempt(self: *Record, now_ns: u64) ?BootEndAttempt {
        self.metrics_mutex.lock();
        defer self.metrics_mutex.unlock();
        if (!self.page_mapped)
            return null;
        const token = self.boot_egress orelse return null;
        if (now_ns >= token.deadline_mono_ns) {
            self.boot_egress = null;
            self.boot_end_pending = false;
            return null;
        }
        if (!self.boot_end_pending) {
            const view = if (self.handle.metrics) |*mapped| mapped else return null;
            const snapshot = page.LifecycleSnapshot.load(view.header);
            self.boot_end_pending = snapshot.startupEnded();
        }
        if (!self.boot_end_pending)
            return null;
        return .{ .worker_key = self.key(), .token = token };
    }

    /// Forgets the boot token whose end `attempt` sent, unless the record
    /// holds another worker by now: the send ran without this lock.
    pub fn completeBootEnd(self: *Record, attempt: BootEndAttempt) void {
        self.metrics_mutex.lock();
        defer self.metrics_mutex.unlock();
        // `occupy` and `vacate` change the key only while the page is unmapped.
        if (!self.page_mapped)
            return;
        if (!self.key().eql(attempt.worker_key))
            return;
        self.boot_egress = null;
        self.boot_end_pending = false;
    }

    /// Sends SIGKILL to the worker through its pidfd. A worker that already
    /// exited is not an error.
    pub fn signalKill(self: *Record) void {
        std.debug.assert(self.id != 0);
        process.pidFdSendSignal(self.handle.pidfd, std.posix.SIG.KILL) catch |err| switch (err) {
            error.ProcessNotFound => {},
            else => std.log.warn("failed to send SIGKILL to worker pid={d} worker_id={d}: {s}", .{
                self.handle.pid,
                self.id,
                @errorName(err),
            }),
        };
    }

    /// Waits up to `PROCESS_EXIT_WAIT_MS` for the worker's process to exit,
    /// and reports whether it did. Blocks the calling thread, which is why
    /// only the reaper and the exiting thread call it.
    pub fn awaitExit(self: *Record) bool {
        std.debug.assert(self.id != 0);
        return process.waitForPidFdExit(self.handle.pidfd, process_limits.PROCESS_EXIT_WAIT_MS) catch
            process.pidFdHasExited(self.handle.pidfd);
    }

    /// Releases what the record holds for its worker and leaves it vacant:
    /// the handle, whose `deinit` closes the worker's descriptors, unmaps its
    /// page and payload rings, deletes its tmp root and removes its cgroup
    /// leaf with retries, the wake set, and the send scratch, back to `gpa`.
    /// Blocks on that teardown, so only the reaper and the exiting thread
    /// call it, after the final drain unmapped the page for every drain
    /// (`usage_drain.drainFinal`).
    pub fn vacate(self: *Record, gpa: std.mem.Allocator) void {
        std.debug.assert(self.id != 0);
        std.debug.assert(!self.page_mapped);
        self.handle.deinit();
        self.egress_wake_set.deinit();
        if (self.dispatch_send_scratch.len != 0)
            gpa.free(self.dispatch_send_scratch);
        self.dispatch_send_scratch = &.{};
        self.id = 0;
        self.generation = 0;
        self.egress_gateway_generation = 0;
        self.egress_gateway_session_id = 0;
    }
};

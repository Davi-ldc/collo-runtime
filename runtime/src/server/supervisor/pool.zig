//! The pool of one worker definition: its workers and their request slots,
//! the requests waiting for a slot, and the launches that will add workers.
//! It is a plain structure under one mutex of its own, with no thread, no I/O
//! and no clock, and it allocates only in `init`. The supervisor keeps one per
//! definition for the server's life. Ingress lanes call it on every dispatch
//! and every finish, the launcher thread when a launch starts and ends, and
//! the reaper thread when a worker dies or retires.
//!
//! - The worker table has `Options.workers_max` entries, each empty,
//!   launching, live, retiring or dead. A live entry points at its worker's
//!   record and has `Options.concurrency` slots, and a slot belongs to one
//!   request of one lane from the `acquire` or handoff that takes it to the
//!   `release` that gives it back. Records belong to the supervisor: an entry
//!   only points at one, from `publish` to `remove`, and the entry's reader
//!   epoch keeps counting across the workers it holds.
//! - The free list is every live worker with a free slot, ordered by last use
//!   with the most recent first, so load packs onto warm workers and idle ones
//!   stay idle until the reaper retires them. A published worker that serves
//!   no waiter starts at its cold end.
//! - The waiters are a FIFO of at most `Options.waiters_max` requests. A
//!   waiter is its lane's own request state, which keeps its lane slot and its
//!   deadline; the pool only records whose turn comes next. A freed slot goes
//!   to the head waiter at once, so free slots and waiters never coexist.
//! - A launch holds a table entry from `launchStarted` to `publish` or
//!   `launchEnded`, so live, retiring, dead and launching workers together
//!   never outnumber the table.
//!
//! One lane at a time reads a worker's output channels, its control socket,
//! its completion eventfd and ring and its pidfd, and forwards to the lane
//! that owns each request whatever is not its own. The first lane to take a
//! slot of a worker without a reader becomes its reader under a new epoch,
//! and the role stays while the worker alternates between idle and busy on
//! that lane. When another lane takes a slot of an idle worker, its grant
//! asks it to post `release_worker` to the reader. The reader gives the role
//! up in `transferReader` only if the worker is still idle then, and the next
//! lane to take a slot becomes the reader, so two lanes never read one worker
//! at once and a ring payload is never decoded by one lane while another still
//! holds the ones before it. A grant is an obligation the lane discharges
//! even when it can no longer use the slot, and a handoff whose lane never
//! sees it goes back with its grant through `returnHandoff`.
//!
//! A worker leaves through `markDead`, `retireForEgress` or `retireIdle`,
//! which its entry records (`Departure`), and no slot of it is handed out
//! afterwards. It is finished once no lane holds a slot of it or reads it.
//! Exactly one call observes that and says so: `.retire` from `release`,
//! `returnHandoff`, `transferReader` or `retireIdle`, or `retire` in a
//! `Death`. Its caller queues the retirement to the reaper, which calls
//! `remove` after the teardown.
//!
//! The mutex also guards the record fields `worker_table.zig` names, which
//! change while their worker serves: `findLive` and `visitWorker` run a
//! caller's visitor on a record under it, and a visitor only reads or writes
//! those fields and duplicates the record's descriptors.
//!
//! Lock order: the pool mutex comes before a lane's command-queue mutex and is
//! never taken while one is held. No method takes another lock or calls out
//! beyond such a visitor, so the mutex is never held across a send, a wait or
//! a callback into another subsystem; the commands a result asks for are
//! posted by the caller after the method returns.

const std = @import("std");
const lifecycle = @import("collo_server_lifecycle");
const server_limits = @import("collo_limits").server;

pub const RequestKey = lifecycle.RequestKey;
/// An ingress lane, as `RequestKey.lane_id` names it.
pub const LaneId = u16;
/// A request slot of one worker, below its definition's `concurrency`.
pub const Slot = u8;
/// One reader tenure of one table entry; never 0 once a reader existed.
pub const ReaderEpoch = u32;

/// Slots one worker can have: the live request slots of its shared state
/// page, which also bound every definition's `concurrency`.
pub const slots_per_worker_max: u8 = server_limits.worker_concurrency_max;
/// Table entries one pool can have, since a launch ticket names its entry in
/// a byte.
pub const entries_max: u32 = std.math.maxInt(u8);

comptime {
    std.debug.assert(@FieldType(RequestKey, "lane_id") == LaneId);
    std.debug.assert(slots_per_worker_max >= 1);
}

/// The slots of one worker, a bit per slot that a request holds.
const SlotSet = std.bit_set.IntegerBitSet(slots_per_worker_max);

pub const Options = struct {
    /// The definition's `concurrency`: slots per worker, from 1 to
    /// `slots_per_worker_max`.
    concurrency: u8,
    /// Table entries, from 1 to `entries_max`: `pool_workers_max` in
    /// `server/supervisor/scheduler_limits.zig`.
    workers_max: u32,
    /// Launches in flight at once, from 1 to `workers_max`:
    /// `pool_cold_starts_in_flight_max` there.
    launches_max: u32,
    /// The waiter FIFO's capacity, at least 1: `pool_waiters_max` in
    /// `common/limits/pool.zig`.
    waiters_max: u32,
};

/// A request waiting for a slot. `deadline_ns` is its deadline
/// (CLOCK_MONOTONIC), fixed at admission; a waiter whose deadline has passed
/// when a slot frees is dropped instead of served, since its lane answers it.
pub const Waiter = struct {
    lane: LaneId,
    request_key: RequestKey,
    deadline_ns: u64,
};

/// The reader of a worker and the epoch of its tenure.
pub const ReaderTenure = struct {
    lane: LaneId,
    epoch: ReaderEpoch,
};

/// What a lane that just took a slot owes the worker's reader role. It
/// discharges the grant before it dispatches, and also when it gives the
/// slot back unused.
pub const ReaderGrant = union(enum) {
    /// The lane already reads the worker, or another lane does and will
    /// forward this request's output. Nothing to do.
    already,
    /// The worker had no reader. The lane registers the worker's output
    /// channels and reads them under this epoch until `transferReader` lets
    /// it go.
    you_become_reader: ReaderEpoch,
    /// The worker was idle and another lane reads it. The lane posts
    /// `release_worker` with this tenure to that lane, which keeps reading,
    /// and forwarding to this lane, until it gives the role up.
    transfer_from: ReaderTenure,
};

/// A table entry a launch holds until `publish` or `launchEnded`.
pub const LaunchTicket = struct {
    entry: u8,
};

pub const EntryState = enum {
    empty,
    launching,
    live,
    /// Idle and leaving: `retireIdle` took it out of service.
    retiring,
    /// `markDead` or `retireForEgress` took it out of service.
    dead,
};

/// Why a worker left service. The reaper counts each apart (`RetireReason`
/// in `reaper/root.zig`).
pub const Departure = enum {
    /// `retireIdle`: its idle TTL or memory pressure.
    idle,
    /// `markDead`: a fault, its exit or its deadline's grace.
    died,
    /// `retireForEgress`: its gateway was lost and no other one could give
    /// it a session.
    egress,
};

/// What a reader that calls `transferReader` still holds of the worker's
/// worker-to-server ring: nothing, or payloads it forwarded whose owners have
/// not answered (`Registration.ring_payloads` in `server/ingress/completions.zig`).
pub const ReaderHolds = enum {
    nothing,
    ring_payloads,
};

/// How `transferReader` left the role.
pub const Transfer = enum {
    /// The tenure already ended, or the worker left the table; nothing to do.
    stale,
    /// The worker has requests in flight, so the lane stays its reader.
    kept,
    /// The worker is idle and the reader still holds ring payloads. Their
    /// owners all gave their slots back, and an owner answers its payloads
    /// before that or never, so no answer is still coming: the reader frees
    /// them, oldest first, and calls again. The role stays meanwhile, because
    /// the next reader decodes from the ring's read cursor.
    free_held_payloads,
    /// The lane is no longer the reader and unregisters the worker's
    /// channels; the next lane to take a slot becomes the reader.
    vacated,
    /// As `vacated`, and the worker is finished: the caller queues its
    /// retirement to the reaper.
    retire,
};

/// How `retireIdle` started a retirement.
pub const RetireIdle = union(enum) {
    /// The worker holds a request, already left service, or is not in the
    /// table. Nothing changed.
    not_idle,
    /// No lane reads the worker: the reaper retires it now.
    retire,
    /// The reaper posts `release_worker` with this tenure to the reader, whose
    /// `transferReader` returns `.retire` and queues the retirement.
    release_reader: ReaderTenure,
};

/// Monotonic counts since `init`.
pub const Counters = struct {
    acquired: u64 = 0,
    waited: u64 = 0,
    full: u64 = 0,
    handed_off: u64 = 0,
    released: u64 = 0,
    waiters_cancelled: u64 = 0,
    waiters_expired: u64 = 0,
    waiters_stranded: u64 = 0,
    readers_assigned: u64 = 0,
    reader_releases_requested: u64 = 0,
    readers_released: u64 = 0,
    launches_started: u64 = 0,
    launches_ended: u64 = 0,
    published: u64 = 0,
    deaths: u64 = 0,
    /// Workers `retireForEgress` took out of service.
    egress_retirements: u64 = 0,
    /// Idle retirements `retireIdle` started.
    idle_retirements: u64 = 0,
    /// `.retire` results, one per worker that left service and finished.
    retirements: u64 = 0,
    removed: u64 = 0,
};

/// The pool under one lock hold. `slots_held + slots_free` equals
/// `slot_capacity`, the live workers' slots; a dead worker's slots count in
/// `slots_held_dead` until its lanes release them.
pub const Snapshot = struct {
    workers_live: u32 = 0,
    workers_retiring: u32 = 0,
    workers_dead: u32 = 0,
    launching: u32 = 0,
    waiters: u32 = 0,
    slot_capacity: u32 = 0,
    slots_held: u32 = 0,
    slots_free: u32 = 0,
    slots_held_dead: u32 = 0,
    counters: Counters = .{},
};

/// A pool over records of type `Record`, which it only points at.
pub fn Pool(comptime Record: type) type {
    return struct {
        const Self = @This();

        mutex: std.Thread.Mutex,
        gpa: std.mem.Allocator,
        concurrency: u8,
        launches_max: u32,
        entries: []Entry,
        /// A ring of `waiter_count` waiters from `waiter_head`, oldest first.
        waiters: []Waiter,
        waiter_head: u32,
        waiter_count: u32,
        launching: u32,
        /// Stamps `Entry.last_use`, which orders the free list.
        use_clock: u64,
        counters: Counters,

        pub const Acquired = struct {
            worker: *Record,
            slot: Slot,
            reader: ReaderGrant,
        };

        pub const Acquire = union(enum) {
            acquired: Acquired,
            wait,
            full,
        };

        /// A slot given to a waiter. The caller posts `dispatch_ready` with it
        /// to `waiter.lane`.
        pub const Handoff = struct {
            waiter: Waiter,
            worker: *Record,
            slot: Slot,
            reader: ReaderGrant,
        };

        pub const Released = union(enum) {
            /// Nothing more to do: the slot is free, or on a dead worker gone.
            idle,
            handed_to: Handoff,
            /// The worker is dead and this was the last hold on it: the
            /// caller queues its retirement to the reaper.
            retire,
        };

        /// The handoffs of one `publish`, oldest waiter first.
        pub const Handoffs = struct {
            items: [slots_per_worker_max]Handoff = undefined,
            len: u8 = 0,

            pub fn slice(self: *const Handoffs) []const Handoff {
                return self.items[0..self.len];
            }
        };

        /// The lanes a death concerns, each once: every holder of a slot of
        /// the worker and its reader.
        pub const Death = struct {
            lanes: [slots_per_worker_max + 1]LaneId = undefined,
            len: u8 = 0,
            /// No lane holds or reads the worker, so `lanes` is empty and the
            /// caller queues the retirement at once.
            retire: bool = false,

            pub fn slice(self: *const Death) []const LaneId {
                return self.lanes[0..self.len];
            }

            fn add(self: *Death, lane: LaneId) void {
                for (self.lanes[0..self.len]) |existing| {
                    if (existing == lane) return;
                }
                self.lanes[self.len] = lane;
                self.len += 1;
            }
        };

        pub const IdleWorker = struct {
            worker: *Record,
            idle_since_ns: u64,
            reader: ?ReaderTenure,
        };

        pub const WorkerView = struct {
            state: EntryState,
            /// Why the worker left service; null while it serves.
            departure: ?Departure,
            slots_held: u8,
            reader: ?ReaderTenure,
            idle_since_ns: u64,
        };

        const Entry = struct {
            state: EntryState = .empty,
            /// Set exactly while the entry is retiring or dead.
            departure: ?Departure = null,
            /// Set exactly while the entry is live, retiring or dead.
            record: ?*Record = null,
            held: SlotSet = SlotSet.initEmpty(),
            /// The lane holding each slot set in `held`.
            holder_lanes: [slots_per_worker_max]LaneId = @splat(0),
            reader: ?LaneId = null,
            reader_epoch: ReaderEpoch = 0,
            /// A grant asked the reader for `release_worker` in this tenure
            /// and the reader has not answered, so no second grant asks.
            release_requested: bool = false,
            last_use: u64 = 0,
            idle_since_ns: u64 = 0,
        };

        /// Prepares an empty pool in place. `gpa` backs the worker table and
        /// the waiter FIFO until `deinit`, and nothing allocates afterwards.
        /// Fails with `error.InvalidPoolOptions` when an option is outside the
        /// range its doc gives, and with `error.OutOfMemory`; either way
        /// nothing stays allocated.
        pub fn init(
            self: *Self,
            gpa: std.mem.Allocator,
            options: Options,
        ) error{ OutOfMemory, InvalidPoolOptions }!void {
            try validateOptions(options);
            const entries = try gpa.alloc(Entry, options.workers_max);
            errdefer gpa.free(entries);
            const waiters = try gpa.alloc(Waiter, options.waiters_max);
            @memset(entries, .{});
            self.* = .{
                .mutex = .{},
                .gpa = gpa,
                .concurrency = options.concurrency,
                .launches_max = options.launches_max,
                .entries = entries,
                .waiters = waiters,
                .waiter_head = 0,
                .waiter_count = 0,
                .launching = 0,
                .use_clock = 0,
                .counters = .{},
            };
        }

        /// Frees the table and the FIFO. The records the table points at stay
        /// the caller's.
        pub fn deinit(self: *Self) void {
            self.gpa.free(self.waiters);
            self.gpa.free(self.entries);
            self.* = undefined;
        }

        /// Takes a free slot of the most recently used worker that has one.
        ///
        /// `.acquired`: the caller discharges the reader grant, dispatches its
        /// request on the slot and owns the slot until it passes it to
        /// `release`. `.wait`: the request is now the newest waiter; the
        /// caller keeps its lane slot and deadline, asks `growthWanted`
        /// whether to submit a launch (or `takeStranded` when growth is
        /// refused), and later receives `dispatch_ready`, or calls
        /// `cancelWaiter` when the request ends first. `.full`: the FIFO holds
        /// `waiters_max` requests and the caller answers 503 at once.
        pub fn acquire(
            self: *Self,
            lane: LaneId,
            request_key: RequestKey,
            deadline_ns: u64,
        ) Acquire {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.mostRecentFreeEntry()) |entry| {
                std.debug.assert(self.waiter_count == 0);
                const slot = firstFreeSlot(entry.held, self.concurrency).?;
                const reader = self.holdSlot(entry, slot, lane);
                self.counters.acquired += 1;
                return .{ .acquired = .{ .worker = entry.record.?, .slot = slot, .reader = reader } };
            }
            if (self.waiter_count == self.waiters.len) {
                self.counters.full += 1;
                return .full;
            }
            self.pushWaiter(.{ .lane = lane, .request_key = request_key, .deadline_ns = deadline_ns });
            self.counters.waited += 1;
            return .wait;
        }

        /// Removes the waiter of `request_key`, whose request ended while it
        /// waited: its deadline expired or its stream went away. True: it was
        /// still waiting and will never be handed a slot. False: there is no
        /// such waiter, because a handoff already took it and its
        /// `dispatch_ready` is on the way (the lane gives that slot back with
        /// `release` when it arrives), because the pool dropped it as expired,
        /// or because it was never queued.
        pub fn cancelWaiter(self: *Self, request_key: RequestKey) bool {
            self.mutex.lock();
            defer self.mutex.unlock();

            var offset: u32 = 0;
            while (offset < self.waiter_count) : (offset += 1) {
                if (self.waiters[self.waiterIndex(offset)].request_key.eql(request_key)) {
                    self.removeWaiterAt(offset);
                    self.counters.waiters_cancelled += 1;
                    return true;
                }
            }
            return false;
        }

        /// Gives back `slot` of `worker`, which the caller took through
        /// `acquire` or a handoff and no longer uses. Waiters whose deadline
        /// is at or before `now_ns` are dropped on the way to the head.
        ///
        /// `.idle`: nothing more to do. `.handed_to`: the slot now belongs to
        /// the head waiter, and the caller posts `dispatch_ready` with it to
        /// the waiter's lane, or runs the dispatch itself when that lane is
        /// its own. `.retire`: the caller queues the worker's retirement to
        /// the reaper. Fails with `error.SlotNotHeld`, changing nothing, when
        /// `worker` is not in the table or `slot` is not held.
        pub fn release(
            self: *Self,
            worker: *Record,
            slot: Slot,
            now_ns: u64,
        ) error{SlotNotHeld}!Released {
            self.mutex.lock();
            defer self.mutex.unlock();

            const entry = try self.heldEntry(worker, slot);
            return self.releaseLocked(entry, slot, now_ns);
        }

        /// Gives back `slot` of `worker`, handed to a waiter of `lane` with
        /// the reader grant `reader`, when that lane will never use it: it
        /// refused the `dispatch_ready`, or tears down with the command
        /// unread. Under the same lock hold, a tenure the grant made for
        /// `lane`, which the lane never took up, ends first, so the slot's
        /// next holder becomes the reader, and a release the grant asked of
        /// the reader for `lane` is forgotten, since it was never sent. The
        /// slot then goes back as `release` gives one back. Fails with
        /// `error.SlotNotHeld`, changing nothing, as `release` does.
        pub fn returnHandoff(
            self: *Self,
            worker: *Record,
            slot: Slot,
            lane: LaneId,
            reader: ReaderGrant,
            now_ns: u64,
        ) error{SlotNotHeld}!Released {
            self.mutex.lock();
            defer self.mutex.unlock();

            const entry = try self.heldEntry(worker, slot);
            switch (reader) {
                .already => {},
                .you_become_reader => |epoch| if (isReader(entry, .{ .lane = lane, .epoch = epoch })) {
                    entry.reader = null;
                    entry.release_requested = false;
                    self.counters.readers_released += 1;
                },
                .transfer_from => |tenure| forgetReleaseRequest(entry, tenure),
            }
            return self.releaseLocked(entry, slot, now_ns);
        }

        /// Forgets that a grant asked the reader `tenure` of `worker` to give
        /// its role up, after the asking lane's `release_worker` post was
        /// refused, so the next grant on the idle worker asks again.
        pub fn releaseRequestLost(self: *Self, worker: *Record, tenure: ReaderTenure) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            const entry = self.occupiedEntry(worker) orelse return;
            forgetReleaseRequest(entry, tenure);
        }

        /// Puts the worker a launch produced into the entry `ticket` holds,
        /// ends that launch, and gives the worker's slots to the head
        /// waiters, oldest first, dropping those whose deadline is at or
        /// before `now_ns`. The slots left join the free list at its cold end.
        /// The caller keeps `worker` valid until `remove` and posts
        /// `dispatch_ready` for each handoff; the first one makes its lane the
        /// reader. Fails with `error.TicketNotLaunching`, changing nothing,
        /// when the ticket's entry is not launching.
        pub fn publish(
            self: *Self,
            ticket: LaunchTicket,
            worker: *Record,
            now_ns: u64,
        ) error{TicketNotLaunching}!Handoffs {
            self.mutex.lock();
            defer self.mutex.unlock();

            const entry = self.launchingEntry(ticket) orelse return error.TicketNotLaunching;
            self.launching -= 1;
            const reader_epoch = entry.reader_epoch;
            entry.* = .{
                .state = .live,
                .record = worker,
                .reader_epoch = reader_epoch,
                .idle_since_ns = now_ns,
            };
            self.counters.published += 1;

            var handoffs: Handoffs = .{};
            var slot: Slot = 0;
            while (slot < self.concurrency) : (slot += 1) {
                const waiter = self.popLiveWaiter(now_ns) orelse break;
                const reader = self.holdSlot(entry, slot, waiter.lane);
                handoffs.items[handoffs.len] = .{
                    .waiter = waiter,
                    .worker = worker,
                    .slot = slot,
                    .reader = reader,
                };
                handoffs.len += 1;
                self.counters.handed_off += 1;
            }
            return handoffs;
        }

        /// Takes the worker `worker_key` names, held in `worker`, out of
        /// service for good: no slot of it is handed out again. Null when an
        /// earlier call already took it out of service, whose path finishes
        /// it, when it is not in the table, or when the record holds another
        /// worker by now. Otherwise each lane in the result holds a slot of
        /// the worker or reads it, the caller's own lane included when it is
        /// one. The caller posts `worker_died` to the others, and each lane
        /// finishes its requests on the worker, gives its slots back with
        /// `release` and its role back with `transferReader`. With `retire`
        /// set no lane holds or reads the worker, and the caller queues the
        /// retirement at once. `Record` provides `key()`.
        pub fn markDead(self: *Self, worker: *Record, worker_key: lifecycle.WorkerKey) ?Death {
            self.mutex.lock();
            defer self.mutex.unlock();
            const death = self.leaveService(worker, worker_key, .died) orelse return null;
            self.counters.deaths += 1;
            return death;
        }

        /// Takes a live worker out of service for good as `markDead` does,
        /// for a worker whose gateway was lost and that no other gateway
        /// could give a session, and returns what `markDead` returns. The
        /// worker leaves with its requests, like a dead one, and the reaper
        /// counts it apart from deaths.
        pub fn retireForEgress(self: *Self, worker: *Record, worker_key: lifecycle.WorkerKey) ?Death {
            self.mutex.lock();
            defer self.mutex.unlock();
            const death = self.leaveService(worker, worker_key, .egress) orelse return null;
            self.counters.egress_retirements += 1;
            return death;
        }

        /// The first live worker, in table order, that `visitor.visit(worker)`
        /// picks by returning true, or null. Each `visit` runs under the
        /// pool's mutex while its worker is live, so the worker's record
        /// cannot be torn down before it returns: it may read and write the
        /// record fields the mutex guards and duplicate the record's
        /// descriptors, and it must not call into the pool, take another lock
        /// or wait.
        pub fn findLive(self: *Self, visitor: anytype) ?*Record {
            self.mutex.lock();
            defer self.mutex.unlock();

            for (self.entries) |*entry| {
                if (entry.state != .live) continue;
                const worker = entry.record.?;
                if (visitor.visit(worker)) return worker;
            }
            return null;
        }

        /// Runs `visitor.visit(worker, state)` under the pool's mutex, with
        /// the state of `worker`'s entry, and returns true; false, running
        /// nothing, when the table does not hold `worker`. `visit` may read
        /// and write the record fields the mutex guards, under the rules of
        /// `findLive`.
        pub fn visitWorker(self: *Self, worker: *Record, visitor: anytype) bool {
            self.mutex.lock();
            defer self.mutex.unlock();

            const entry = self.occupiedEntry(worker) orelse return false;
            visitor.visit(worker, entry.state);
            return true;
        }

        /// `markDead` and `retireForEgress` under the mutex; the caller counts
        /// the departure.
        fn leaveService(self: *Self, worker: *Record, worker_key: lifecycle.WorkerKey, departure: Departure) ?Death {
            std.debug.assert(departure != .idle);
            const entry = self.occupiedEntry(worker) orelse return null;
            // A record's key is written only while its entry is launching,
            // when the table does not point at it, so it is stable here.
            if (!worker.key().eql(worker_key)) return null;
            if (entry.state != .live) return null;
            entry.state = .dead;
            entry.departure = departure;
            entry.release_requested = false;

            var death: Death = .{};
            var slot: Slot = 0;
            while (slot < self.concurrency) : (slot += 1) {
                if (entry.held.isSet(slot))
                    death.add(entry.holder_lanes[slot]);
            }
            if (entry.reader) |lane|
                death.add(lane);
            if (death.len == 0) {
                death.retire = true;
                self.counters.retirements += 1;
            }
            return death;
        }

        /// Ends the reader tenure `tenure` of `worker`. The reader lane calls
        /// it when it processes `release_worker`, after the worker's death, or
        /// whenever it wants to stop reading; another lane calls it to end a
        /// tenure the pool granted it that it never took up. The result says
        /// what the caller does next (`Transfer`). `holds` is what the caller
        /// still holds of the worker's ring: a live worker's role is never
        /// given up with a forwarded payload held, because the next reader
        /// decodes from the ring's read cursor, so an idle worker's reader
        /// that holds some gets `.free_held_payloads` instead. An owner's
        /// answer can still be on its way to the reader then, since the
        /// `release_worker` that asks for the role is posted when the asking
        /// lane takes its slot, before that slot's payloads exist; the reader
        /// drops an answer for a payload it no longer holds.
        pub fn transferReader(self: *Self, worker: *Record, tenure: ReaderTenure, holds: ReaderHolds) Transfer {
            self.mutex.lock();
            defer self.mutex.unlock();

            const entry = self.occupiedEntry(worker) orelse return .stale;
            if (!isReader(entry, tenure)) return .stale;
            entry.release_requested = false;
            if (entry.state == .live) {
                if (entry.held.count() != 0) return .kept;
                switch (holds) {
                    .nothing => {},
                    .ring_payloads => return .free_held_payloads,
                }
                entry.reader = null;
                self.counters.readers_released += 1;
                return .vacated;
            }
            entry.reader = null;
            self.counters.readers_released += 1;
            if (self.finished(entry)) return .retire;
            return .vacated;
        }

        /// Starts the retirement the reaper chose for an idle `worker`: it
        /// leaves the free list and is never handed out again (`RetireIdle`
        /// says who finishes it).
        pub fn retireIdle(self: *Self, worker: *Record) RetireIdle {
            self.mutex.lock();
            defer self.mutex.unlock();

            const entry = self.occupiedEntry(worker) orelse return .not_idle;
            if (entry.state != .live) return .not_idle;
            if (entry.held.count() != 0) return .not_idle;
            entry.state = .retiring;
            entry.departure = .idle;
            self.counters.idle_retirements += 1;
            if (entry.reader) |lane|
                return .{ .release_reader = .{ .lane = lane, .epoch = entry.reader_epoch } };
            self.counters.retirements += 1;
            return .retire;
        }

        /// Empties the entry of a worker whose retirement is done, so a later
        /// launch can reuse it and the caller may reuse `worker`'s storage.
        /// Fails with `error.WorkerNotFinished`, changing nothing, unless the
        /// worker is dead or retiring and no lane holds or reads it.
        pub fn remove(self: *Self, worker: *Record) error{WorkerNotFinished}!void {
            self.mutex.lock();
            defer self.mutex.unlock();

            const entry = self.occupiedEntry(worker) orelse return error.WorkerNotFinished;
            if (entry.state == .live) return error.WorkerNotFinished;
            if (entry.held.count() != 0) return error.WorkerNotFinished;
            if (entry.reader != null) return error.WorkerNotFinished;
            const reader_epoch = entry.reader_epoch;
            entry.* = .{ .reader_epoch = reader_epoch };
            self.counters.removed += 1;
        }

        /// Whether a launch should start: more requests wait than the
        /// launches in flight will serve, the table has an entry no worker or
        /// launch holds, fewer than `launches_max` launches are in flight, and
        /// `memory_gate_allows`, the reaper's verdict on the node's memory,
        /// holds. Advisory, since another thread may claim first; the launcher
        /// claims through `launchStarted`, which decides again.
        pub fn growthWanted(self: *Self, memory_gate_allows: bool) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.growthWantedLocked(memory_gate_allows);
        }

        /// Claims an empty entry for one launch when `growthWanted` holds, and
        /// returns its ticket; null otherwise. The launcher thread calls it
        /// and gives the ticket back through `publish` or `launchEnded`.
        pub fn launchStarted(self: *Self, memory_gate_allows: bool) ?LaunchTicket {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (!self.growthWantedLocked(memory_gate_allows)) return null;
            for (self.entries, 0..) |*entry, index| {
                if (entry.state != .empty) continue;
                entry.state = .launching;
                self.launching += 1;
                self.counters.launches_started += 1;
                return .{ .entry = @intCast(index) };
            }
            return null;
        }

        /// Gives back the entry of a launch that ended without a worker. A
        /// failed launch never starts another by itself, so the caller then
        /// calls `takeStranded` for the waiters it would have served. Fails
        /// with `error.TicketNotLaunching`, changing nothing, when the
        /// ticket's entry is not launching.
        pub fn launchEnded(self: *Self, ticket: LaunchTicket) error{TicketNotLaunching}!void {
            self.mutex.lock();
            defer self.mutex.unlock();

            const entry = self.launchingEntry(ticket) orelse return error.TicketNotLaunching;
            entry.state = .empty;
            self.launching -= 1;
            self.counters.launches_ended += 1;
        }

        /// Moves into `out`, oldest first, the waiters nothing can serve
        /// because no worker is live and no launch is in flight, and returns
        /// the filled part of `out`, which is empty otherwise. The caller
        /// answers each with 503, posting `dispatch_failed` to the other
        /// lanes, and calls again while the result fills `out`.
        pub fn takeStranded(self: *Self, out: []Waiter) []Waiter {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.launching != 0) return out[0..0];
            for (self.entries) |*entry| {
                if (entry.state == .live) return out[0..0];
            }
            var len: usize = 0;
            while (len < out.len and self.waiter_count != 0) : (len += 1)
                out[len] = self.popWaiter();
            self.counters.waiters_stranded += len;
            return out[0..len];
        }

        /// The pool's view of `worker`, or null when it is not in the table.
        pub fn inspect(self: *Self, worker: *Record) ?WorkerView {
            self.mutex.lock();
            defer self.mutex.unlock();

            const entry = self.occupiedEntry(worker) orelse return null;
            return .{
                .state = entry.state,
                .departure = entry.departure,
                .slots_held = @intCast(entry.held.count()),
                .reader = if (entry.reader) |lane| .{ .lane = lane, .epoch = entry.reader_epoch } else null,
                .idle_since_ns = entry.idle_since_ns,
            };
        }

        /// Fills `out` with the live workers that hold no request, longest
        /// idle first, keeping the longest idle when there are more than
        /// `out.len`, and returns the filled part: the reaper's candidates. A
        /// listed worker may take a request before `retireIdle`, which
        /// decides again.
        pub fn idleWorkers(self: *Self, out: []IdleWorker) []IdleWorker {
            self.mutex.lock();
            defer self.mutex.unlock();

            var len: usize = 0;
            for (self.entries) |*entry| {
                if (entry.state != .live) continue;
                if (entry.held.count() != 0) continue;
                const candidate: IdleWorker = .{
                    .worker = entry.record.?,
                    .idle_since_ns = entry.idle_since_ns,
                    .reader = if (entry.reader) |lane| .{ .lane = lane, .epoch = entry.reader_epoch } else null,
                };
                if (len < out.len) {
                    out[len] = candidate;
                    len += 1;
                } else {
                    if (len == 0) continue;
                    if (candidate.idle_since_ns >= out[len - 1].idle_since_ns) continue;
                    out[len - 1] = candidate;
                }
                // Insertion into the sorted prefix: the new item moves left
                // past every item idle for less time.
                var cursor = len - 1;
                while (cursor > 0 and out[cursor].idle_since_ns < out[cursor - 1].idle_since_ns) : (cursor -= 1)
                    std.mem.swap(IdleWorker, &out[cursor], &out[cursor - 1]);
            }
            return out[0..len];
        }

        /// Gauges and counters under one lock hold, for the health answer and
        /// the tests.
        pub fn snapshot(self: *Self) Snapshot {
            self.mutex.lock();
            defer self.mutex.unlock();

            var result: Snapshot = .{
                .launching = self.launching,
                .waiters = self.waiter_count,
                .counters = self.counters,
            };
            for (self.entries) |*entry| {
                const held: u32 = @intCast(entry.held.count());
                switch (entry.state) {
                    .empty, .launching => {},
                    .live => {
                        result.workers_live += 1;
                        result.slots_held += held;
                        result.slots_free += self.concurrency - held;
                    },
                    .retiring => result.workers_retiring += 1,
                    .dead => {
                        result.workers_dead += 1;
                        result.slots_held_dead += held;
                    },
                }
            }
            result.slot_capacity = result.workers_live * self.concurrency;
            return result;
        }

        fn validateOptions(options: Options) error{InvalidPoolOptions}!void {
            if (options.concurrency < 1) return error.InvalidPoolOptions;
            if (options.concurrency > slots_per_worker_max) return error.InvalidPoolOptions;
            if (options.workers_max < 1) return error.InvalidPoolOptions;
            if (options.workers_max > entries_max) return error.InvalidPoolOptions;
            if (options.launches_max < 1) return error.InvalidPoolOptions;
            if (options.launches_max > options.workers_max) return error.InvalidPoolOptions;
            if (options.waiters_max < 1) return error.InvalidPoolOptions;
        }

        fn occupiedEntry(self: *Self, worker: *Record) ?*Entry {
            for (self.entries) |*entry| {
                if (entry.record == worker) return entry;
            }
            return null;
        }

        /// The entry of `worker` when `slot` of it is held.
        fn heldEntry(self: *Self, worker: *Record, slot: Slot) error{SlotNotHeld}!*Entry {
            const entry = self.occupiedEntry(worker) orelse return error.SlotNotHeld;
            if (slot >= self.concurrency) return error.SlotNotHeld;
            if (!entry.held.isSet(slot)) return error.SlotNotHeld;
            return entry;
        }

        /// `release` once the slot is known to be held.
        fn releaseLocked(self: *Self, entry: *Entry, slot: Slot, now_ns: u64) Released {
            entry.held.unset(slot);
            self.counters.released += 1;

            if (entry.state != .live) {
                // Only a dead worker still has slots held, and they leave
                // with it.
                if (self.finished(entry)) return .retire;
                return .idle;
            }
            if (self.popLiveWaiter(now_ns)) |waiter| {
                const reader = self.holdSlot(entry, slot, waiter.lane);
                self.counters.handed_off += 1;
                return .{ .handed_to = .{
                    .waiter = waiter,
                    .worker = entry.record.?,
                    .slot = slot,
                    .reader = reader,
                } };
            }
            self.touch(entry);
            if (entry.held.count() == 0)
                entry.idle_since_ns = now_ns;
            return .idle;
        }

        fn launchingEntry(self: *Self, ticket: LaunchTicket) ?*Entry {
            if (ticket.entry >= self.entries.len) return null;
            const entry = &self.entries[ticket.entry];
            if (entry.state != .launching) return null;
            return entry;
        }

        /// The free list's head: the live worker with a free slot used most
        /// recently, the lowest entry on a tie.
        fn mostRecentFreeEntry(self: *Self) ?*Entry {
            var best: ?*Entry = null;
            for (self.entries) |*entry| {
                if (entry.state != .live) continue;
                if (entry.held.count() >= self.concurrency) continue;
                if (best) |current| {
                    if (entry.last_use > current.last_use) best = entry;
                } else {
                    best = entry;
                }
            }
            return best;
        }

        fn holdSlot(self: *Self, entry: *Entry, slot: Slot, lane: LaneId) ReaderGrant {
            std.debug.assert(entry.state == .live);
            std.debug.assert(!entry.held.isSet(slot));
            const was_idle = entry.held.count() == 0;
            entry.held.set(slot);
            entry.holder_lanes[slot] = lane;
            self.touch(entry);
            return self.grantReader(entry, lane, was_idle);
        }

        fn touch(self: *Self, entry: *Entry) void {
            self.use_clock += 1;
            entry.last_use = self.use_clock;
        }

        fn grantReader(self: *Self, entry: *Entry, lane: LaneId, was_idle: bool) ReaderGrant {
            const reader = entry.reader orelse {
                entry.reader_epoch = nextEpoch(entry.reader_epoch);
                entry.reader = lane;
                self.counters.readers_assigned += 1;
                return .{ .you_become_reader = entry.reader_epoch };
            };
            if (reader == lane) return .already;
            // Only an idle worker changes reader: a busy one has requests
            // whose output the current reader is already forwarding.
            if (!was_idle) return .already;
            if (entry.release_requested) return .already;
            entry.release_requested = true;
            self.counters.reader_releases_requested += 1;
            return .{ .transfer_from = .{ .lane = reader, .epoch = entry.reader_epoch } };
        }

        /// Whether a worker out of service is finished: no lane holds a slot
        /// of it or reads it. Counts the retirement the caller then queues.
        fn finished(self: *Self, entry: *Entry) bool {
            std.debug.assert(entry.state != .live);
            if (entry.held.count() != 0) return false;
            if (entry.reader != null) return false;
            self.counters.retirements += 1;
            return true;
        }

        fn growthWantedLocked(self: *Self, memory_gate_allows: bool) bool {
            if (!memory_gate_allows) return false;
            if (self.launching >= self.launches_max) return false;
            var occupied: usize = 0;
            for (self.entries) |*entry| {
                if (entry.state != .empty) occupied += 1;
            }
            if (occupied >= self.entries.len) return false;
            const covered = @as(u64, self.launching) * self.concurrency;
            return self.waiter_count > covered;
        }

        fn popLiveWaiter(self: *Self, now_ns: u64) ?Waiter {
            while (self.waiter_count != 0) {
                const waiter = self.popWaiter();
                if (waiter.deadline_ns > now_ns) return waiter;
                self.counters.waiters_expired += 1;
            }
            return null;
        }

        fn waiterIndex(self: *const Self, offset: u32) usize {
            return (@as(usize, self.waiter_head) + offset) % self.waiters.len;
        }

        fn pushWaiter(self: *Self, waiter: Waiter) void {
            std.debug.assert(self.waiter_count < self.waiters.len);
            self.waiters[self.waiterIndex(self.waiter_count)] = waiter;
            self.waiter_count += 1;
        }

        fn popWaiter(self: *Self) Waiter {
            std.debug.assert(self.waiter_count != 0);
            const waiter = self.waiters[self.waiter_head];
            self.waiter_head = @intCast(self.waiterIndex(1));
            self.waiter_count -= 1;
            return waiter;
        }

        /// Closes the gap a cancelled waiter leaves by moving every later one
        /// up a place, which keeps the FIFO's order.
        fn removeWaiterAt(self: *Self, offset: u32) void {
            std.debug.assert(offset < self.waiter_count);
            var cursor = offset;
            while (cursor + 1 < self.waiter_count) : (cursor += 1)
                self.waiters[self.waiterIndex(cursor)] = self.waiters[self.waiterIndex(cursor + 1)];
            self.waiter_count -= 1;
        }
    };
}

/// Whether `tenure` is the reader tenure `entry` names now. Generic over the
/// pool's entry type.
fn isReader(entry: anytype, tenure: ReaderTenure) bool {
    const reader = entry.reader orelse return false;
    return reader == tenure.lane and entry.reader_epoch == tenure.epoch;
}

/// Clears the release a grant asked of the reader `tenure`, when that tenure
/// is still the reader's.
fn forgetReleaseRequest(entry: anytype, tenure: ReaderTenure) void {
    if (isReader(entry, tenure))
        entry.release_requested = false;
}

fn firstFreeSlot(held: SlotSet, concurrency: u8) ?Slot {
    var slot: Slot = 0;
    while (slot < concurrency) : (slot += 1) {
        if (!held.isSet(slot)) return slot;
    }
    return null;
}

fn nextEpoch(epoch: ReaderEpoch) ReaderEpoch {
    const next = epoch +% 1;
    return if (next == 0) 1 else next;
}

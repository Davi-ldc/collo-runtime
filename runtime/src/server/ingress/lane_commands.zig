//! The payloads of the commands a worker definition's pool and the reading
//! of a worker add to an ingress lane's queue (`commands.zig`): a slot handed
//! to a waiting request, what a worker's reader forwards to the lane that
//! owns a request, the answers that let the reader free ring bytes and give
//! its role up, and the failure of a request no worker can serve. Pure data:
//! a payload does nothing beyond freeing what it owns. The pool's side of
//! each exchange is in `server/supervisor/pool.zig`.
//!
//! A command waits in a queue while its subject moves on: the request may
//! end, the worker may die, and the record behind a pointer may come to hold
//! a later worker. Every payload therefore names its request by `RequestKey`
//! and its worker by `WorkerKey`, and the receiving lane checks both against
//! its own state before it acts. Commands to one lane run in the order they
//! were posted. A reader forwards a request's descriptors in the order it
//! read them and its completion after them, and an owner answers each ring
//! payload before it gives the request's slot back to the pool, so once the
//! worker is idle no answer is left to come: a reader giving its role up then
//! frees what it still holds, and an answer still queued to it drops
//! (`Pool.transferReader`).

const std = @import("std");
const ipc = @import("collo_ipc");
const lifecycle = @import("collo_server_lifecycle");
const worker_shared_page = @import("collo_worker_state").page;
const supervision = @import("collo_server_supervisor");

const pool = supervision.pool;
const WorkerRecord = supervision.worker_table.Record;

pub const RequestKey = lifecycle.RequestKey;
pub const WorkerKey = lifecycle.WorkerKey;
pub const ReaderGrant = pool.ReaderGrant;

/// A slot of `worker` handed to the waiting request `request_key`.
///
/// Sent by the lane whose `Pool.release` handed the slot on, or by the
/// launcher's `Deps.publish` for a fresh worker, to the waiter's lane,
/// `request_key.lane_id`. The receiver first discharges `reader`: it
/// registers the worker's output channels, or posts `release_worker` to the
/// lane `transfer_from` names. Then it dispatches the request on the slot by
/// the path an inline acquire takes, when the request still waits and no
/// `worker_died` naming `worker_key` reached it first; otherwise it gives the
/// slot back with `Pool.release` and acts on the result. The slot keeps the
/// worker in the pool's table, so `worker` stays valid until that release.
///
/// A sender whose post fails gives the slot back itself, with the grant it
/// carried (`Pool.returnHandoff`), and so does a lane that tears down with
/// the command unread.
pub const DispatchReady = struct {
    request_key: RequestKey,
    worker_key: WorkerKey,
    worker: *WorkerRecord,
    slot: pool.Slot,
    reader: ReaderGrant,
};

/// The bytes of a payload in the worker-to-server ring that the reader
/// decoded and has not freed. The reader keeps the bytes it reserved for the
/// payload, a skipped tail included, in its own list for the worker, and
/// frees them in ring order as the answers come.
pub const RingRef = struct {
    /// Where the payload starts, below `shared_payload_ring_capacity`
    /// (`common/ipc/ingress_channel/payload_ring.zig`).
    offset: u64,
    /// Its length, above `shared_payload_threshold` and at most the ring's
    /// capacity.
    len: u32,
};

/// A payload copied once out of the packet the reader received. The command
/// owns it until its consumer, or `Command.deinit`, frees it.
pub const InlineBytes = struct {
    bytes: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *InlineBytes) void {
        if (self.bytes.len != 0)
            self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const ForwardedPayload = union(enum) {
    /// The descriptor carries no payload.
    none,
    /// At or below `shared_payload_threshold`: copied into the command.
    inline_bytes: InlineBytes,
    /// Above it: left in the worker's ring until the owner answers.
    ring: RingRef,
};

/// A response descriptor the reader of a worker read for a request another
/// lane owns.
///
/// Sent by the reader lane to the owner, `request_key.lane_id`, in the order
/// the reader read it. The owner checks both keys and applies the descriptor
/// as one it read itself (`runner/h2_worker_ipc.zig`), taking a `ring`
/// payload from the worker's ring through the record its request slot holds.
/// For a `ring` payload it answers `payload_consumed` to `reader_lane_id`
/// whether it used the bytes or not, and before it gives the request's slot
/// back.
///
/// A reader whose post fails frees a `ring` payload's bytes itself, in ring
/// order, and drops the descriptor; the owner's deadline ends the request.
///
/// A descriptor that shows the worker faulty is a worker fault on the owner.
/// An owner with no request on the worker takes it out of service through
/// `worker`, after checking that the record still holds `worker_key`
/// (`runner/worker_fault.zig`).
pub const ForwardedDescriptor = struct {
    request_key: RequestKey,
    worker_key: WorkerKey,
    /// The record the reader reads the worker through.
    worker: *WorkerRecord,
    /// The lane that read the descriptor, where a `ring` payload's answer
    /// goes.
    reader_lane_id: pool.LaneId,
    /// As the reader decoded it, its identity fields naming `request_key`.
    descriptor: ipc.ingress_channel.Descriptor,
    payload: ForwardedPayload,

    pub fn deinit(self: *ForwardedDescriptor) void {
        switch (self.payload) {
            .inline_bytes => |*bytes| bytes.deinit(),
            .none, .ring => {},
        }
        self.* = undefined;
    }
};

/// A completion the reader drained from the worker's completion ring for a
/// request another lane owns, copied out of shared memory once.
///
/// Sent by the reader lane to the owner, `request_key.lane_id`, after every
/// descriptor of that request it read before the completion, and only for a
/// request the worker's request table holds under that key and id whose
/// completion it has not forwarded yet (`RequestTable.claimCompletion`), so
/// a worker cannot send more of them than it has requests. The owner checks
/// both keys and finalizes the request as for a completion it drained
/// itself, parking it while the stream's response is still open
/// (`runner/h2_worker_ipc.zig`). The record is the copy the reader's drain
/// loaded once and validated.
///
/// The post may take the queue's reserve (`commands.zig`), so a refusal
/// means the owner lane is not running, and the reader drops the record.
pub const ForwardedCompletion = struct {
    request_key: RequestKey,
    worker_key: WorkerKey,
    record: worker_shared_page.WorkerCompletionRecord,
};

/// The owner's answer for a `ring` payload it was forwarded, used or not.
///
/// Sent by the owner lane to the reader, `ForwardedDescriptor.reader_lane_id`.
/// The reader marks the payload answered in its list for the worker and
/// frees the ring bytes up to the first payload still unanswered, so the
/// ring's read cursor only moves in ring order. An answer that matches
/// nothing, because the worker died and the reader gave the role up, is
/// dropped.
///
/// An owner whose post fails leaves the bytes held: the worker's later ring
/// payloads stall until their requests' deadlines end them.
pub const PayloadConsumed = struct {
    worker_key: WorkerKey,
    ring: RingRef,
};

/// A request for the reader of a worker to give its role up.
///
/// Sent by the lane whose grant said `transfer_from`, or by the reaper after
/// `Pool.retireIdle` answered `release_reader`, to the reader lane named by
/// that tenure. The receiver ignores it unless it reads `worker_key` under
/// `epoch`; otherwise it calls `Pool.transferReader` with that tenure. On
/// `kept` it goes on reading. On `vacated` it unregisters the worker's
/// channels and ignores, by its registration's generation, the completions of
/// its polls still in flight. On `retire` it also queues the worker's
/// retirement to the reaper.
///
/// A lane whose post fails tells the pool (`Pool.releaseRequestLost`), so the
/// next grant on the idle worker asks again, and the reader keeps the role
/// and forwarding meanwhile. The reaper posts again on its next pass while a
/// retiring worker still has a reader.
pub const ReleaseWorker = struct {
    worker_key: WorkerKey,
    epoch: pool.ReaderEpoch,
};

/// A waiting request that no worker can serve, because none is live and no
/// launch is in flight (`Pool.takeStranded`).
///
/// Sent by the thread that took it from the pool, the launcher after a
/// failed launch or a lane whose growth check failed, to the waiter's lane,
/// `request_key.lane_id`. The lane answers 503 if the request still waits;
/// a request that already ended needs nothing.
pub const DispatchFailed = struct {
    request_key: RequestKey,
    reason: Reason,

    pub const Reason = enum {
        /// The launch meant to serve the request failed.
        launch_failed,
        /// The pool may not grow: the memory gate refused or the table is
        /// full of workers out of service.
        growth_refused,
    };
};

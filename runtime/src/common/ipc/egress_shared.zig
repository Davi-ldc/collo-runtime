//! The shared memory between one worker and the egress gateway, the only path
//! a worker's fetches have out of its sandbox: a worker never holds a gateway
//! socket. A session has two framed packet rings, the command ring from the
//! worker to the gateway and the completion ring back, and two pools of
//! fixed-size blocks: the body pool carries response bodies to the worker and
//! the upload pool carries request bodies to the gateway. Two eventfds wake
//! the sides, and two pipes tell each side when the other exits. The server
//! creates every descriptor and hands the gateway its half over the gateway's
//! control socket and the worker its half through WorkerInit or, after its
//! gateway is replaced, `egress_attach`; a worker's wake descriptors outlive
//! its sessions (`session_fds.zig`). The worker maps its half on its event
//! loop thread and the gateway on its loop thread; a view takes no lock, so
//! each side keeps its writes to one region on one thread at a time.
//!
//! Every region has one producer and one consumer. Sequence numbers count
//! bytes or entries since creation, and each side publishes its own cursor
//! with a release store and reads the peer's with an acquire load. The worker
//! is untrusted and can rewrite any byte it maps writable at any moment, so
//! the gateway must read each sequence number, frame header, slot and release
//! entry from shared memory once, validate that copy and use only the copy;
//! each part's header says where its reads stand against that rule. An
//! inconsistent cursor, frame header or release entry, or a release of a
//! handle that names no published extent, marks the region fatal; reading or
//! checking such a handle fails without marking it, and the gateway drops the
//! worker.
//!
//! The parts live under `egress_shared/`: `region.zig` holds what every ring
//! and pool shares, `packet_ring.zig` the two rings, `body_pool.zig` the pool
//! type both pools use, `slot_snapshot.zig` the one copy a consumer reads of
//! a pool slot, `session_fds.zig` the descriptors the server creates and
//! splits, `endpoint.zig` each side's mapping of its half, and `wake.zig` the
//! eventfd signals. This file re-exports their public declarations, so
//! callers reach all of them through `egress_shared`.

const region = @import("egress_shared/region.zig");
const packet_ring = @import("egress_shared/packet_ring.zig");
const body_pool = @import("egress_shared/body_pool.zig");
const slot_snapshot = @import("egress_shared/slot_snapshot.zig");
const session_fds = @import("egress_shared/session_fds.zig");
const endpoint = @import("egress_shared/endpoint.zig");
const wake = @import("egress_shared/wake.zig");

pub const magic = region.magic;
pub const version = region.version;
pub const Role = region.Role;
pub const FatalState = region.FatalState;
pub const RingMeta = region.RingMeta;
pub const Usage = region.Usage;

pub const command_ring_capacity = packet_ring.command_ring_capacity;
pub const completion_ring_capacity = packet_ring.completion_ring_capacity;
pub const max_packet_bytes = packet_ring.max_packet_bytes;
pub const command_control_reserve_bytes = packet_ring.command_control_reserve_bytes;
pub const RingProducerState = packet_ring.RingProducerState;
pub const RingConsumerState = packet_ring.RingConsumerState;
pub const PacketWriteResult = packet_ring.PacketWriteResult;
pub const RingView = packet_ring.RingView;

pub const body_pool_capacity = body_pool.body_pool_capacity;
pub const body_pool_block_size = body_pool.body_pool_block_size;
pub const body_pool_block_count = body_pool.body_pool_block_count;
pub const body_pool_slot_count = body_pool.body_pool_slot_count;
pub const body_pool_release_queue_capacity = body_pool.body_pool_release_queue_capacity;
pub const BodyPoolHandle = body_pool.BodyPoolHandle;
pub const BodyPoolSlot = body_pool.BodyPoolSlot;
pub const BodyPoolSlotState = body_pool.BodyPoolSlotState;
pub const BodyPoolView = body_pool.BodyPoolView;
pub const slotIndexForHandle = body_pool.slotIndexForHandle;
pub const BodyPoolReservation = body_pool.BodyPoolReservation;
pub const BodyPoolWriteTransaction = body_pool.BodyPoolWriteTransaction;

pub const SlotSnapshot = slot_snapshot.SlotSnapshot;
pub const SlotExtent = slot_snapshot.Extent;

pub const region_fd_count = session_fds.region_fd_count;
pub const wake_fd_count = session_fds.wake_fd_count;
pub const shared_fd_count = session_fds.shared_fd_count;
pub const WakeFds = session_fds.WakeFds;
pub const RawFds = session_fds.RawFds;
pub const WakeSet = session_fds.WakeSet;
pub const SessionFds = session_fds.SessionFds;
pub const createSessionForWorker = session_fds.createSessionForWorker;

pub const Endpoint = endpoint.Endpoint;
pub const mapEndpointTakeForWorker = endpoint.mapEndpointTakeForWorker;
pub const mapEndpointTakeForGateway = endpoint.mapEndpointTakeForGateway;

pub const notify = wake.notify;
pub const notifyAfterPacketWrite = wake.notifyAfterPacketWrite;
pub const drainEventfd = wake.drainEventfd;

// Analyzing this file analyzes every part, so each part's layout checks run
// wherever the contract is referenced.
comptime {
    _ = region;
    _ = packet_ring;
    _ = body_pool;
    _ = slot_snapshot;
    _ = session_fds;
    _ = endpoint;
    _ = wake;
}

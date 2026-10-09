//! The request and response streams between the host side (the server's
//! ingress lanes, or `host/dispatch.zig`) and a worker, carried on the
//! worker's SEQPACKET control socket. Every message is a fixed `Descriptor`
//! naming the request and its stream, sent alone or up to
//! `max_batch_descriptors` per packet, and its payload rides either inline in
//! the packet or in the shared payload memfd, which holds one byte ring per
//! direction, so large bodies never pass through a socket. The host creates
//! the memfd at launch and the worker receives it in WorkerInit; the server
//! uses this contract on an ingress lane's thread and the worker on its event
//! loop thread.
//!
//! Each process sends one direction and receives the other: the host sends
//! request begins, request body chunks and request resets and receives
//! response heads, chunks, ends and resets, and the worker does the reverse.
//! The parts under `ingress_channel/` follow those roles: `framing.zig` holds
//! the packet format both directions share, `payload_ring.zig` the payload
//! memfd and its rings, `send.zig` the sending side, `receive.zig` the
//! receiving side, and `response_head.zig` the payload of a response head.
//! This file re-exports their public declarations, so callers reach all of
//! them through `ingress_channel`.
//!
//! No packet on this channel carries a file descriptor, in either direction:
//! a worker receives its route's module pack in WorkerInit, before its first
//! request. Every decoder refuses a packet that arrives with one and closes
//! its descriptors with the packet.

const framing = @import("ingress_channel/framing.zig");
const payload_ring = @import("ingress_channel/payload_ring.zig");
const send = @import("ingress_channel/send.zig");
const receive = @import("ingress_channel/receive.zig");
const response_head = @import("ingress_channel/response_head.zig");

pub const Op = framing.Op;
pub const flags = framing.flags;
pub const batch_magic = framing.batch_magic;
pub const max_batch_descriptors = framing.max_batch_descriptors;
pub const Descriptor = framing.Descriptor;
pub const RequestIdentity = framing.RequestIdentity;
pub const Packet = framing.Packet;
pub const batchPayloadOffset = framing.batchPayloadOffset;

pub const shared_payload_threshold = payload_ring.shared_payload_threshold;
pub const shared_payload_ring_capacity = payload_ring.shared_payload_ring_capacity;
pub const shared_payload_ring_count = payload_ring.shared_payload_ring_count;
pub const shared_payload_version = payload_ring.shared_payload_version;
pub const SharedPayloadDirection = payload_ring.SharedPayloadDirection;
pub const SharedPayloadSide = payload_ring.SharedPayloadSide;
pub const SharedPayloadRingHeader = payload_ring.SharedPayloadRingHeader;
pub const SharedPayloadHeader = payload_ring.SharedPayloadHeader;
pub const shared_payload_data_offset = payload_ring.shared_payload_data_offset;
pub const shared_payload_byte_size = payload_ring.shared_payload_byte_size;
pub const SharedPayloadWriter = payload_ring.SharedPayloadWriter;
pub const SharedPayloadWriteReservation = payload_ring.SharedPayloadWriteReservation;
pub const SharedPayloadReadRelease = payload_ring.SharedPayloadReadRelease;
pub const SharedPayloadView = payload_ring.SharedPayloadView;
pub const notifyEventFd = payload_ring.notifyEventFd;
pub const createSharedPayloadMemfd = payload_ring.createSharedPayloadMemfd;
pub const mapSharedPayloadReadWrite = payload_ring.mapSharedPayloadReadWrite;

pub const BatchEntry = send.BatchEntry;
pub const sendDescriptor = send.sendDescriptor;
pub const sendDescriptorPayload = send.sendDescriptorPayload;
pub const sendDescriptorBatchPayloads = send.sendDescriptorBatchPayloads;
pub const sendDescriptorBatchRingPayloads = send.sendDescriptorBatchRingPayloads;
pub const sendDescriptorBatchPayloadsWithRing = send.sendDescriptorBatchPayloadsWithRing;
pub const sendDescriptorPayloadMaybeShared = send.sendDescriptorPayloadMaybeShared;
pub const sendDescriptorPayloadMaybeSharedWithRing = send.sendDescriptorPayloadMaybeSharedWithRing;
pub const sendDescriptorPayloadRequireRing = send.sendDescriptorPayloadRequireRing;
pub const encodeDescriptorInto = send.encodeDescriptorInto;
pub const encodeDescriptorPayloadInto = send.encodeDescriptorPayloadInto;
pub const encodeDescriptorBatchPayloadsInto = send.encodeDescriptorBatchPayloadsInto;

pub const SharedPayloadReaders = receive.SharedPayloadReaders;
pub const SharedPayloadSpan = receive.SharedPayloadSpan;
pub const SharedPayloadHolds = receive.SharedPayloadHolds;
pub const Received = receive.Received;
pub const ReceivedBatch = receive.ReceivedBatch;
pub const isDescriptorBatchPacket = receive.isDescriptorBatchPacket;
pub const decodeDescriptor = receive.decodeDescriptor;
pub const peekDescriptorForError = receive.peekDescriptorForError;
pub const decodeReceivedPacket = receive.decodeReceivedPacket;
pub const decodeReceivedPacketWithSharedPayload = receive.decodeReceivedPacketWithSharedPayload;
pub const decodeReceivedBatchPacket = receive.decodeReceivedBatchPacket;
pub const decodeReceivedBatchPacketWithSharedPayload = receive.decodeReceivedBatchPacketWithSharedPayload;
pub const decodeDispatchPayload = receive.decodeDispatchPayload;

pub const ResponseHeader = response_head.ResponseHeader;
pub const DecodedResponseHead = response_head.DecodedResponseHead;
pub const encodeResponseHeadInto = response_head.encodeResponseHeadInto;
pub const decodeResponseHead = response_head.decodeResponseHead;
pub const decodeResponseHeadBounded = response_head.decodeResponseHeadBounded;

// Analyzing this file analyzes every part, so each part's layout checks run
// wherever the contract is referenced.
comptime {
    _ = framing;
    _ = payload_ring;
    _ = send;
    _ = receive;
    _ = response_head;
}

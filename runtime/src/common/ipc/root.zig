//! The private IPC between the host, the zygote, worker processes and the
//! egress gateway: one binary on every end, so each format changes on both
//! sides at once and nothing negotiates versions. Messages travel as packets
//! on connected SEQPACKET sockets (`packet.zig`), except between a worker
//! and the gateway, which share memory rings and no socket
//! (`egress_shared.zig`).
//!
//! - `messages.zig`: message kinds, status vocabularies, fixed headers and
//!   their layout pins.
//! - `zygote_worker.zig`: the fork and WorkerInit handshakes and the init
//!   outcome.
//! - `dispatch.zig`: the DispatchWork payload of one request.
//! - `ingress_channel.zig`: request and response streams between the host
//!   and a worker, with their shared payload rings.
//! - `egress.zig`, `egress_shared.zig`, `fetch_limits.zig`: the worker and
//!   gateway fetch contract and its shared rings.
//! - `egress_token.zig`: the token the server mints for a request or a boot
//!   and the gateway verifies at fetch admission.
//! - `egress_attach.zig`: the worker half of a new egress session, sent to a
//!   live worker after its gateway was replaced.
//! - `module_pack.zig`: the module pack format.
//! - `fs_index.zig`, `fs_fault.zig`: a worker's file index and its file
//!   requests.
//! - `route_table.zig`: the routes of a worker's definition, each with its
//!   entry and its bindings (`route_bindings.zig`).
//! - `packet.zig`, `outbound_queue.zig`: SEQPACKET framing with SCM_RIGHTS,
//!   and the owned packet queues of nonblocking writers, bounded by the
//!   limits their callers pass.

pub const module_pack = @import("module_pack.zig");
pub const ingress_channel = @import("ingress_channel.zig");

pub const messages = @import("messages.zig");
pub const fs_fault = @import("fs_fault.zig");
pub const fs_index = @import("fs_index.zig");
pub const route_bindings = @import("route_bindings.zig");
pub const route_table = @import("route_table.zig");
pub const outbound_queue = @import("outbound_queue.zig");
pub const packet = @import("packet.zig");
pub const zygote_worker = @import("zygote_worker.zig");
pub const dispatch = @import("dispatch.zig");
pub const egress = @import("egress.zig");
pub const egress_shared = @import("egress_shared.zig");
pub const egress_token = @import("egress_token.zig");
pub const egress_attach = @import("egress_attach.zig");
pub const fetch_limits = @import("fetch_limits.zig");

pub const max_message_bytes = messages.max_message_bytes;
pub const max_route_capture_count = messages.max_route_capture_count;
pub const max_request_header_count = messages.max_request_header_count;
pub const max_fds_per_message = messages.max_fds_per_message;

pub const MessageKind = messages.MessageKind;
pub const WorkerInitFailedReason = messages.WorkerInitFailedReason;
pub const RequestDoneStatus = messages.RequestDoneStatus;
pub const RouteCapture = messages.RouteCapture;
pub const RequestHeader = messages.RequestHeader;
pub const DispatchWorkView = messages.DispatchWorkView;
pub const RequestBodyFraming = messages.RequestBodyFraming;
pub const ZygoteReady = messages.ZygoteReady;
pub const ForkRequest = messages.ForkRequest;
pub const ForkReply = messages.ForkReply;
pub const WorkerRuntimeBootOptions = messages.WorkerRuntimeBootOptions;
pub const WorkerInit = messages.WorkerInit;
pub const WorkerReady = messages.WorkerReady;
pub const WorkerInitFailed = messages.WorkerInitFailed;
pub const DispatchPacketHeader = messages.DispatchPacketHeader;
pub const FsFaultResponseStatus = messages.FsFaultResponseStatus;
pub const FsFaultRequestHeader = messages.FsFaultRequestHeader;
pub const FsFaultResponseHeader = messages.FsFaultResponseHeader;
pub const EgressFetchStartHeader = messages.EgressFetchStartHeader;
pub const EgressCancel = messages.EgressCancel;
pub const EgressReleaseBody = messages.EgressReleaseBody;
pub const EgressFetchHeadHeader = messages.EgressFetchHeadHeader;
pub const BodyEncoding = messages.BodyEncoding;
pub const EgressBodyChunkBatchHeader = messages.EgressBodyChunkBatchHeader;
pub const EgressBodyChunkBatchDescriptor = messages.EgressBodyChunkBatchDescriptor;
pub const EgressUploadChunkBatchHeader = messages.EgressUploadChunkBatchHeader;
pub const EgressUploadChunkBatchDescriptor = messages.EgressUploadChunkBatchDescriptor;
pub const EgressBodyEnd = messages.EgressBodyEnd;
pub const EgressFetchErrorHeader = messages.EgressFetchErrorHeader;
pub const EgressAbortAck = messages.EgressAbortAck;
pub const EgressAttach = messages.EgressAttach;
pub const InitOutcome = messages.InitOutcome;
pub const egress_fetch_head_flag_redirected = messages.egress_fetch_head_flag_redirected;
pub const egress_fetch_start_flag_body_pooled = messages.egress_fetch_start_flag_body_pooled;
pub const valid_egress_fetch_start_flags = messages.valid_egress_fetch_start_flags;
pub const valid_egress_fetch_head_flags = messages.valid_egress_fetch_head_flags;

pub const decodeRequestBodyFraming = messages.decodeRequestBodyFraming;
pub const decodeMessageKind = messages.decodeMessageKind;
pub const decodeWorkerInitFailedReason = messages.decodeWorkerInitFailedReason;
pub const decodeFsFaultResponseStatus = messages.decodeFsFaultResponseStatus;

pub const ReceivedPacket = packet.ReceivedPacket;
pub const recvPacketWithFdsScratch = packet.recvPacketWithFdsScratch;
pub const collectReceivedControlFds = packet.collectReceivedControlFds;

pub const ForkReplyWithFds = zygote_worker.ForkReplyWithFds;
pub const WorkerInitWithFds = zygote_worker.WorkerInitWithFds;
pub const sendZygoteReady = zygote_worker.sendZygoteReady;
pub const recvZygoteReady = zygote_worker.recvZygoteReady;
pub const sendForkRequest = zygote_worker.sendForkRequest;
pub const recvForkRequest = zygote_worker.recvForkRequest;
pub const ForkRequestWithFd = zygote_worker.ForkRequestWithFd;
pub const sendForkRequestWithCgroupFd = zygote_worker.sendForkRequestWithCgroupFd;
pub const recvForkRequestWithFd = zygote_worker.recvForkRequestWithFd;
pub const sendForkReply = zygote_worker.sendForkReply;
pub const sendForkFailed = zygote_worker.sendForkFailed;
pub const recvForkReply = zygote_worker.recvForkReply;
pub const sendWorkerInitWithEgressShared = zygote_worker.sendWorkerInitWithEgressShared;
pub const sendWorkerInitWithRouteTableAndEgressShared =
    zygote_worker.sendWorkerInitWithRouteTableAndEgressShared;
pub const recvWorkerInit = zygote_worker.recvWorkerInit;
pub const sendWorkerReady = zygote_worker.sendWorkerReady;
pub const recvWorkerReady = zygote_worker.recvWorkerReady;
pub const sendWorkerInitFailed = zygote_worker.sendWorkerInitFailed;
pub const recvWorkerInitFailed = zygote_worker.recvWorkerInitFailed;
pub const recvInitOutcome = zygote_worker.recvInitOutcome;

pub const DispatchWork = dispatch.DispatchWork;
pub const encodeDispatchWorkInto = dispatch.encodeDispatchWorkInto;
pub const decodeDispatchWork = dispatch.decodeDispatchWork;

pub const FsFaultRequest = fs_fault.Request;
pub const FsFaultRequestView = fs_fault.RequestView;
pub const FsFaultResponse = fs_fault.Response;
pub const FsFaultResponseWithFd = fs_fault.ResponseWithFd;
pub const sendFsFaultRequest = fs_fault.sendRequest;
pub const sendFsFaultResponse = fs_fault.sendResponse;
pub const decodeFsFaultRequest = fs_fault.decodeRequest;
pub const decodeFsFaultResponseFromPacket = fs_fault.decodeResponseFromPacket;

pub const EgressFetchStartView = egress.FetchStartView;
pub const EgressFetchHeadView = egress.FetchHeadView;
pub const EgressBodyChunkView = egress.BodyChunkView;
pub const EgressBodyChunkBatchView = egress.BodyChunkBatchView;
pub const EgressBodyEndView = egress.BodyEndView;
pub const EgressFetchErrorView = egress.FetchErrorView;
pub const encodeEgressFetchStartInto = egress.encodeFetchStartInto;
pub const decodeEgressFetchStart = egress.decodeFetchStart;
pub const WorkerEgressDecodeScratch = egress.WorkerDecodeScratch;
pub const GatewayEgressDecodeScratch = egress.GatewayDecodeScratch;
pub const decodeEgressCancel = egress.decodeCancel;
pub const decodeEgressReleaseBody = egress.decodeReleaseBody;
pub const encodeEgressFetchHeadInto = egress.encodeFetchHeadInto;
pub const decodeEgressFetchHead = egress.decodeFetchHead;
pub const encodeEgressBodyChunkBatchInto = egress.encodeBodyChunkBatchInto;
pub const decodeEgressBodyChunkBatch = egress.decodeBodyChunkBatch;
pub const EgressUploadChunkView = egress.UploadChunkView;
pub const EgressUploadChunkBatchView = egress.UploadChunkBatchView;
pub const encodeEgressUploadChunkBatchInto = egress.encodeUploadChunkBatchInto;
pub const decodeEgressUploadChunkBatch = egress.decodeUploadChunkBatch;
pub const decodeEgressBodyEnd = egress.decodeBodyEnd;
pub const encodeEgressFetchErrorInto = egress.encodeFetchErrorInto;
pub const decodeEgressFetchError = egress.decodeFetchError;
pub const decodeEgressAbortAck = egress.decodeAbortAck;

//! The failure domains of an ingress lane, and the tables that put each
//! error the lane meets into one of them. A failure belongs to the
//! connection, the worker, the lane or the server, and nothing crosses from a
//! smaller domain to a larger one by accident.
//!
//! - A connection fault is anything a client's bytes cause: a TLS or HTTP/2
//!   protocol error, a header block over its limits, a flow-control
//!   violation, write backpressure past its bound, a failed allocation sized
//!   by the client. The lane closes that connection, with GOAWAY when the
//!   HTTP/2 layer can still speak, and resets its streams toward their
//!   workers. Nothing else changes.
//! - A worker fault is anything a worker's bytes or memory cause: a packet
//!   that fails to decode, a descriptor that names no active request, a
//!   corrupt or overrun ring, a datagram carrying descriptors it may not
//!   carry, a hang-up, an exit. The lane marks the worker dead with a
//!   `WorkerFaultReason`, answers each of its in-flight requests with 502, or
//!   RST_STREAM when the lane's own record says the response head went out,
//!   writes the reason into the access record and the usage floor, and
//!   queues the retirement. A send to a worker that would block is
//!   backpressure under the request's deadline, never a fault.
//! - A lane fault is a broken invariant in the lane's own state: its ring,
//!   its slabs, its queues, its descriptors. It stops the lane, and a stopped
//!   lane stops the server, because a lane owns one share of every connection
//!   on the node.
//! - A server fault is the zygote exiting, a listener failing or the boot not
//!   completing. The server exits with the reason.
//!
//! The loop in `runner/ring_driver.zig` calls one handler per event source
//! (`loop_handlers`), and every handler returns `LaneFault!void`, so the
//! loop's signature lists the only errors that may stop it. Connection and
//! worker failures are values, `ConnectionOutcome` and `WorkerOutcome`, that
//! the handler acts on before it returns.
//!
//! An error is classified at the call site of the callee that returned it,
//! with that callee's table. A table takes the callee's own errors together
//! with `LaneFault`: it names each of the callee's errors, and it returns a
//! lane fault unchanged. An error a callee adds then does not build until
//! someone decides its domain, because the callee's set no longer coerces
//! into the table's, and an unnamed error that reaches the lane-fault prong
//! must itself be a lane fault. The tables are kept per callee because the
//! standard library and the IPC codecs reuse names across domains:
//! `SystemResources` is a lane fault from the ring and a closed connection
//! from a client socket, and `InvalidPacket` is a worker fault from a
//! decoder and the lane's own mistake from an encoder.
//!
//! Plain values and pure functions, callable from any thread.

const std = @import("std");
const h2 = @import("collo_http").http2;
const runtime_logs = @import("collo_limits").runtime_logs;

/// The lane's own failures: its io_uring, its tables, queues and buffers,
/// its timerfd and eventfds, and the creation of all of these when its
/// thread starts. An error belongs here when the lane's own state is wrong
/// and no client and no worker can cause it. The loop's handlers return
/// nothing else, and each of these stops the lane and with it the server.
///
/// Some names are the standard library's and also come back from client and
/// worker sockets (`SystemResources`, `Unexpected`, `AccessDenied`). They are
/// lane faults only where the lane's own ring or descriptor returned them;
/// every other call site passes them through its callee's table first.
pub const LaneFault = error{
    // The ring, and a ring call made outside the loop that owns it.
    // `ringErrorIsTransient` says which ones are retried first.
    IngressRingUnavailable,
    SubmissionQueueFull,
    CompletionQueueOvercommitted,
    SignalInterrupt,
    SystemResources,
    FileDescriptorInvalid,
    FileDescriptorInBadState,
    SubmissionQueueEntryInvalid,
    BufferInvalid,
    RingShuttingDown,
    OpcodeNotSupported,
    Unexpected,
    // A completion whose user data the lane never packed: a kind that is no
    // `EventKind` (`runner/event_sources.zig`), or an accept tag whose lane
    // field does not fit a lane id (`uring.unpackAcceptUserData`).
    UnknownCqeTag,
    InvalidLaneId,
    // The listener's multishot accept ended with an errno no single
    // connection explains, or its generation outgrew the user data
    // (`uring.zig`).
    FatalAcceptCqe,
    AcceptGenerationTooLarge,
    // The lane's descriptors: its deadline timerfd (`classifyTimerReadError`),
    // its command queue's eventfd (`commands.Queue.drainWake`), and any
    // descriptor it owns or borrows that turns out closed.
    Canceled,
    InvalidHandle,
    NotOpenForReading,
    NotOpenForWriting,
    TimerfdShortRead,
    CommandEventfdCorrupt,
    // The lane's tables, queues and buffers, each sized from the lane's own
    // limits, so that only a lane bug overfills one.
    DeathQueueFull,
    WorkerInflightRequestListFull,
    TooManyWorkerCompletionRegistrations,
    DeadlineWheelFull,
    DispatchScratchTooSmall,
    // Records the lane keeps that disagree with each other: a request, stream
    // or connection whose companion record is gone or in the wrong state.
    InvalidCompletionRegistration,
    WorkerCompletionRegistrationNotFound,
    StaleRequestGeneration,
    RequestSlotVacant,
    RequestSlotOutOfRange,
    InvalidH2ConnectionState,
    Http2PendingBodyTransferLost,
    MissingTlsConnection,
    // A pool slot the lane's request slot names that the pool does not
    // record for that lane (`Pool.release` in `server/supervisor/pool.zig`).
    SlotNotHeld,
    // A worker's request table with no free entry: its entries are bounded
    // by the worker's slots, so one was never settled
    // (`RequestTable.record` in `server/supervisor/request_table.zig`).
    RequestTableFull,
    // A message to a worker that the lane sized or built wrong
    // (`classifyWorkerError` names the send errors behind it).
    WorkerSendMisuse,
    // Creating the lane's state: the ring (`std.os.linux.IoUring.init`), the
    // timerfd and eventfds, the slabs, the deadline wheel, the command queue
    // and the per-lane arrays.
    NoDevice,
    OutOfMemory,
    AccessDenied,
    PermissionDenied,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    MemoryMappingNotSupported,
    LockedMemoryLimitExceeded,
    MappingAlreadyExists,
    EntriesZero,
    EntriesNotPowerOfTwo,
    ParamsOutsideAccessibleAddressSpace,
    ArgumentsInvalid,
    SystemOutdated,
    InvalidSlabCapacity,
    InvalidDeadlineCapacity,
    InvalidDeadlineWheelSlots,
    InvalidCommandQueueCapacity,
};

/// Why the lane closed a client connection.
pub const ConnectionCloseReason = enum {
    /// The TLS handshake, or the hand-off of its keys to kernel TLS, failed.
    tls_handshake_failed,
    /// A read or write on the kernel TLS socket failed.
    tls_io_failed,
    /// An HTTP/2 connection error without a reason of its own below; the
    /// GOAWAY carries its code.
    protocol_error,
    /// A frame whose length its type does not allow (FRAME_SIZE_ERROR).
    frame_size_error,
    /// A flow-control violation (FLOW_CONTROL_ERROR).
    flow_control_error,
    /// An HPACK failure that leaves the two ends' header tables out of step
    /// (COMPRESSION_ERROR).
    compression_error,
    /// A SETTINGS frame the server refuses.
    settings_error,
    /// A header block over the bytes the server decodes.
    header_block_too_large,
    /// A header field larger than the server decodes.
    header_too_large,
    /// The client stopped reading and the write queue reached its bound.
    write_backpressure,
    /// An allocation sized by the client failed.
    allocation_failed,
    /// The client closed or reset the connection.
    peer_closed,
    /// The connection opened no stream before its pre-request deadline. A
    /// stream opened at a complete request head ends that deadline, whatever
    /// the lane answers on it (`runner/deadline_driver.zig`).
    pre_request_timeout,
    /// No stream of the connection served a request for the whole idle
    /// deadline; it got GOAWAY NO_ERROR first.
    idle_timeout,
    /// No stream of the connection served a request, the lane held part of
    /// a frame, a header block or writes for it, and no byte moved for the
    /// whole stall deadline.
    stall_timeout,
    /// The connection's header block would have taken the lane past its
    /// header block budget (`limits.ingress.header_block_bytes_per_lane_max`).
    header_block_budget,
    /// The server is stopping.
    server_stop,
    /// The lane failed to encode a frame or to keep its stream records for
    /// this connection. Its own sizing and checks rule these out, and the
    /// failure stays with the connection it concerns.
    internal_error,
    /// The lane had no connection slot for an accepted socket.
    connection_limit,
    /// An accepted socket could not be configured or given a TLS session.
    setup_failed,

    /// The reason as logs and analytics records spell it. Consumers read
    /// these strings, so a label never changes once it ships.
    pub fn label(reason: ConnectionCloseReason) []const u8 {
        return switch (reason) {
            .tls_handshake_failed => "tls_handshake_failed",
            .tls_io_failed => "tls_io_failed",
            .protocol_error => "protocol_error",
            .frame_size_error => "frame_size_error",
            .flow_control_error => "flow_control_error",
            .compression_error => "compression_error",
            .settings_error => "settings_error",
            .header_block_too_large => "header_block_too_large",
            .header_too_large => "header_too_large",
            .write_backpressure => "write_backpressure",
            .allocation_failed => "allocation_failed",
            .peer_closed => "peer_closed",
            .pre_request_timeout => "pre_request_timeout",
            .idle_timeout => "idle_timeout",
            .stall_timeout => "stall_timeout",
            .header_block_budget => "header_block_budget",
            .server_stop => "server_stop",
            .internal_error => "internal_error",
            .connection_limit => "connection_limit",
            .setup_failed => "setup_failed",
        };
    }

    /// The longest `label`, for the bound of a record that carries one.
    pub const label_bytes_max: usize = longestLabel(ConnectionCloseReason);
};

/// How the lane closes a connection: why, and the GOAWAY code it queues
/// first. The code is null when no frame can reach the client: before
/// HTTP/2 starts, after the socket failed, or with the write queue full. A
/// GOAWAY that cannot be queued is dropped and the connection closes anyway.
pub const ConnectionClose = struct {
    reason: ConnectionCloseReason,
    goaway: ?h2.ErrorCode,
};

/// What an error leaves of its connection. With `keep` the connection stays,
/// and when the error concerned one stream the caller answers or resets that
/// stream. With `close` the lane closes the connection as `ConnectionClose`
/// says and resets each of its streams toward its worker.
pub const ConnectionOutcome = union(enum) {
    keep,
    close: ConnectionClose,
};

/// An error from one of a connection's callees, tagged with the callee so a
/// name two callees share keeps the meaning it has in each. Every tag also
/// takes the lane's own faults, which a callee may return beside its own
/// errors. `runner/connection_flow.zig` fails only through the ring, and
/// `RingError` covers it.
pub const ConnectionError = union(enum) {
    http2: (LaneFault || Http2Error),
    client_io: (LaneFault || ClientIoError),
    tls_handshake: (LaneFault || TlsHandshakeError),
    request_head: (LaneFault || RequestHeadError),
    accept: (LaneFault || AcceptError),
};

/// What the HTTP/2 driver (`http2/connection.zig`, `reading.zig` and
/// `writing.zig`) returns for a connection: `drive`, the frame and window
/// queue calls, and the server's own responses (`queueResponseHead`,
/// `queueResponseChunk`), with the stream records of
/// `runner/stream_table.zig` and `runner/flow_control.zig` that the lane's
/// stream handlers update.
/// It leaves out the queueing of a worker's response (`ResponseQueueError`).
pub const Http2Error = error{
    Http2ProtocolError,
    Http2UnknownStream,
    Http2ContentLengthMismatch,
    Http2TooManyConcurrentStreams,
    Http2StreamSlabFull,
    Http2EnhanceYourCalm,
    Http2StreamClosed,
    Http2FrameSizeError,
    Http2FlowControlError,
    HpackBadData,
    HpackInvalidArgument,
    HpackEncoderPoisoned,
    HpackHeaderListTooLarge,
    HpackOutputTooSmall,
    Http2HeaderBlockTooLarge,
    Http2HeaderBlockBudgetExceeded,
    TooManyHttp2Settings,
    ShortHttp2Setting,
    Http2WriteBackpressure,
    OutOfMemory,
    Http2StreamAlreadyOpen,
    Http2StreamStateMismatch,
    Http2PendingBodyTooLarge,
    Http2PendingResponseTooLarge,
    InvalidHttp2ResponseStatus,
    InvalidHttp2ResponseHeader,
    RequestTooLarge,
    MessageTooLarge,
    Http2FrameTooLarge,
    ShortHttp2Frame,
    ShortHttp2FrameHeader,
    InvalidHttp2StreamId,
    NoSpaceLeft,
    Overflow,
};

/// A client socket's reads and writes: `std.posix.read`,
/// `ktls.readApplicationData` once the connection has a rekey state, and
/// `std.posix.writev`.
pub const ClientIoError = error{
    WouldBlock,
    PeerClosed,
    ConnectionResetByPeer,
    BrokenPipe,
    ConnectionTimedOut,
    SocketNotConnected,
    NotOpenForReading,
    NotOpenForWriting,
    InvalidHandle,
    InputOutput,
    AccessDenied,
    PermissionDenied,
    SystemResources,
    OperationAborted,
    LockViolation,
    ProcessNotFound,
    IsDir,
    Canceled,
    Unexpected,
    NoDevice,
    MessageTooBig,
    DiskQuota,
    FileTooBig,
    NoSpaceLeft,
    DeviceBusy,
    InvalidArgument,
    ShortWrite,
    InvalidKeyUpdate,
    UnexpectedTlsControlRecord,
    UnsupportedTlsControlRecord,
    InvalidTlsRecordType,
    TruncatedMessage,
    TruncatedControlMessage,
    InvalidControlMessage,
    KtlsKeyExpired,
    UnsupportedTlsVersion,
    UnsupportedTlsCipher,
    InvalidTrafficSecretLength,
    InvalidHkdfLabel,
    InvalidKernelCryptoInfo,
    InvalidKtlsRekeyState,
    InvalidProtocolOption,
    OperationNotSupported,
};

/// `runner/tls_handshake.zig`: the handshake step and the key export of
/// `BoringSslConnection` (`server/tls/root.zig`), `ktls.enableKernelRxTx`,
/// and a handshake slot that lost its TLS connection.
pub const TlsHandshakeError = error{
    TlsHandshakeFailed,
    UnsupportedApplicationProtocol,
    UnsupportedTlsVersion,
    UnsupportedTlsCipher,
    InvalidTrafficSecretLength,
    KtlsKeyExportFailed,
    KtlsCipherUnsupportedByKernel,
    SystemResources,
    Unexpected,
    InvalidKernelCryptoInfo,
    InvalidProtocolOption,
    OperationNotSupported,
    InvalidHandle,
    MissingTlsConnection,
};

/// `http2/request_head.zig`: `parse`, `validateTrailers` and
/// `normalizeAuthority`, and `TooManyRequestHeaders` for a head with more
/// fields than a dispatch carries (`ipc.max_request_header_count`).
pub const RequestHeadError = error{
    RequestTooLarge,
    TooManyRequestHeaders,
    InvalidHeaderLine,
    Http2UppercaseHeaderName,
    Http2PseudoHeaderAfterRegularHeader,
    Http2DuplicatePseudoHeader,
    Http2InvalidPseudoHeader,
    Http2InvalidTrailerPseudoHeader,
    Http2ConnectionSpecificHeader,
    InvalidResponseHeader,
    Http2DuplicateHostHeader,
    InvalidContentLength,
    DuplicateContentLengthMismatch,
    Http2ContentLengthMismatch,
    Http2MissingMethod,
    Http2MissingPath,
    Http2MissingAuthority,
    Http2MissingScheme,
    InvalidRequestLine,
    InvalidHostHeader,
    Http2HostAuthorityMismatch,
};

/// `runner/accept_flow.zig`, setting up one accepted socket: its slot, its
/// socket options through `collo_os.socket`, its peer address
/// (`peer_address.PeerAddress.fromSocket`) and its TLS session
/// (`BoringSslContext.start`). The accept itself sets the socket's
/// non-blocking and close-on-exec flags. Arming the socket's deadline and
/// polls fails only through the lane's own timerfd and ring.
pub const AcceptError = error{
    ConnectionSlabFull,
    BoringSslInitFailed,
    PermissionDenied,
    Unexpected,
    AlreadyConnected,
    InvalidProtocolOption,
    TimeoutTooBig,
    SystemResources,
    OperationNotSupported,
    NetworkSubsystemFailed,
    FileDescriptorNotASocket,
    SocketNotBound,
    NoDevice,
};

/// Sorts an error a connection's callee returned into the connection's
/// outcome, or returns it when it is the lane's own.
pub fn classifyConnectionError(err: ConnectionError) LaneFault!ConnectionOutcome {
    return switch (err) {
        .http2 => |http2_error| classifyHttp2(http2_error),
        .client_io => |io_error| classifyClientIo(io_error),
        .tls_handshake => |tls_error| classifyTlsHandshake(tls_error),
        .request_head => |head_error| classifyRequestHead(head_error),
        .accept => |accept_error| classifyAccept(accept_error),
    };
}

// An error that leaves `drive` interrupts the frame loop, so the connection's
// read state is no longer known: every entry closes. Errors that concern one
// stream are answered on that stream where they happen and never reach this
// table unless that answer failed too.
fn classifyHttp2(err: (LaneFault || Http2Error)) LaneFault!ConnectionOutcome {
    return switch (err) {
        error.Http2ProtocolError,
        error.Http2UnknownStream,
        error.Http2ContentLengthMismatch,
        error.Http2TooManyConcurrentStreams,
        => close(.protocol_error, .protocol_error),
        error.Http2EnhanceYourCalm => close(.protocol_error, .enhance_your_calm),
        error.Http2StreamClosed => close(.protocol_error, .stream_closed),
        error.Http2FrameSizeError => close(.frame_size_error, .frame_size_error),
        error.Http2FlowControlError => close(.flow_control_error, .flow_control_error),
        error.HpackBadData,
        error.HpackInvalidArgument,
        error.HpackEncoderPoisoned,
        => close(.compression_error, .compression_error),
        // A header block the server does not decompress leaves the client's
        // dynamic table ahead of the server's, which RFC 9113 §4.3 answers
        // with COMPRESSION_ERROR.
        error.Http2HeaderBlockTooLarge,
        error.HpackHeaderListTooLarge,
        => close(.header_block_too_large, .compression_error),
        error.HpackOutputTooSmall => close(.header_too_large, .compression_error),
        // A flood of unfinished header blocks across the lane's connections;
        // the one whose block would pass the budget pays with its own.
        error.Http2HeaderBlockBudgetExceeded => close(.header_block_budget, .enhance_your_calm),
        // RFC 9113 bounds no SETTINGS frame; past
        // `Settings.max_settings_per_frame` the peer only adds load.
        error.TooManyHttp2Settings => close(.settings_error, .enhance_your_calm),
        // A SETTINGS payload that is not whole settings (RFC 9113 §6.5).
        error.ShortHttp2Setting => close(.settings_error, .frame_size_error),
        // The full write queue is where a GOAWAY would wait.
        error.Http2WriteBackpressure => close(.write_backpressure, null),
        error.OutOfMemory => close(.allocation_failed, .internal_error),
        // Every caller refuses a new stream past the lane's slab with
        // REFUSED_STREAM, so one reaching this table is the lane's mistake.
        error.Http2StreamSlabFull,
        error.Http2StreamAlreadyOpen,
        error.Http2StreamStateMismatch,
        error.Http2PendingBodyTooLarge,
        error.Http2PendingResponseTooLarge,
        error.InvalidHttp2ResponseStatus,
        error.InvalidHttp2ResponseHeader,
        error.RequestTooLarge,
        error.MessageTooLarge,
        error.Http2FrameTooLarge,
        error.ShortHttp2Frame,
        error.ShortHttp2FrameHeader,
        error.InvalidHttp2StreamId,
        error.NoSpaceLeft,
        error.Overflow,
        => close(.internal_error, .internal_error),
        inline else => |lane_fault| @errorCast(lane_fault),
    };
}

// The socket that failed is the one a GOAWAY would travel on, so no close
// here queues one.
fn classifyClientIo(err: (LaneFault || ClientIoError)) LaneFault!ConnectionOutcome {
    return switch (err) {
        error.WouldBlock => .keep,
        error.PeerClosed,
        error.ConnectionResetByPeer,
        error.BrokenPipe,
        error.ConnectionTimedOut,
        error.SocketNotConnected,
        => close(.peer_closed, null),
        // The lane's own descriptor is closed or is no socket.
        error.NotOpenForReading,
        error.NotOpenForWriting,
        error.InvalidHandle,
        => |lane_fault| lane_fault,
        error.InputOutput,
        error.AccessDenied,
        error.PermissionDenied,
        error.SystemResources,
        error.OperationAborted,
        error.LockViolation,
        error.ProcessNotFound,
        error.IsDir,
        error.Canceled,
        error.Unexpected,
        error.NoDevice,
        error.MessageTooBig,
        error.DiskQuota,
        error.FileTooBig,
        error.NoSpaceLeft,
        error.DeviceBusy,
        error.InvalidArgument,
        error.ShortWrite,
        error.InvalidKeyUpdate,
        error.UnexpectedTlsControlRecord,
        error.UnsupportedTlsControlRecord,
        error.InvalidTlsRecordType,
        error.TruncatedMessage,
        error.TruncatedControlMessage,
        error.InvalidControlMessage,
        error.KtlsKeyExpired,
        error.UnsupportedTlsVersion,
        error.UnsupportedTlsCipher,
        error.InvalidTrafficSecretLength,
        error.InvalidHkdfLabel,
        error.InvalidKernelCryptoInfo,
        error.InvalidKtlsRekeyState,
        error.InvalidProtocolOption,
        error.OperationNotSupported,
        => close(.tls_io_failed, null),
        inline else => |lane_fault| @errorCast(lane_fault),
    };
}

// HTTP/2 has not started during the handshake, so no close queues a GOAWAY.
fn classifyTlsHandshake(err: (LaneFault || TlsHandshakeError)) LaneFault!ConnectionOutcome {
    return switch (err) {
        error.InvalidHandle,
        error.MissingTlsConnection,
        => |lane_fault| lane_fault,
        error.TlsHandshakeFailed,
        error.UnsupportedApplicationProtocol,
        error.UnsupportedTlsVersion,
        error.UnsupportedTlsCipher,
        error.InvalidTrafficSecretLength,
        error.KtlsKeyExportFailed,
        error.KtlsCipherUnsupportedByKernel,
        error.SystemResources,
        error.Unexpected,
        error.InvalidKernelCryptoInfo,
        error.InvalidProtocolOption,
        error.OperationNotSupported,
        => close(.tls_handshake_failed, null),
        inline else => |lane_fault| @errorCast(lane_fault),
    };
}

// The block was decompressed before it was refused, so both ends' header
// tables agree and only the stream fails: RST_STREAM PROTOCOL_ERROR, or 413
// and 431 for the size bounds.
fn classifyRequestHead(err: (LaneFault || RequestHeadError)) LaneFault!ConnectionOutcome {
    return switch (err) {
        error.RequestTooLarge,
        error.TooManyRequestHeaders,
        error.InvalidHeaderLine,
        error.Http2UppercaseHeaderName,
        error.Http2PseudoHeaderAfterRegularHeader,
        error.Http2DuplicatePseudoHeader,
        error.Http2InvalidPseudoHeader,
        error.Http2InvalidTrailerPseudoHeader,
        error.Http2ConnectionSpecificHeader,
        error.InvalidResponseHeader,
        error.Http2DuplicateHostHeader,
        error.InvalidContentLength,
        error.DuplicateContentLengthMismatch,
        error.Http2ContentLengthMismatch,
        error.Http2MissingMethod,
        error.Http2MissingPath,
        error.Http2MissingAuthority,
        error.Http2MissingScheme,
        error.InvalidRequestLine,
        error.InvalidHostHeader,
        error.Http2HostAuthorityMismatch,
        => .keep,
        inline else => |lane_fault| @errorCast(lane_fault),
    };
}

// Each of these concerns the one socket being set up, which has read no TLS
// byte yet.
fn classifyAccept(err: (LaneFault || AcceptError)) LaneFault!ConnectionOutcome {
    return switch (err) {
        error.ConnectionSlabFull => close(.connection_limit, null),
        error.BoringSslInitFailed,
        error.PermissionDenied,
        error.Unexpected,
        error.AlreadyConnected,
        error.InvalidProtocolOption,
        error.TimeoutTooBig,
        error.SystemResources,
        error.OperationNotSupported,
        error.NetworkSubsystemFailed,
        error.FileDescriptorNotASocket,
        error.SocketNotBound,
        error.NoDevice,
        => close(.setup_failed, null),
        inline else => |lane_fault| @errorCast(lane_fault),
    };
}

fn close(reason: ConnectionCloseReason, goaway: ?h2.ErrorCode) ConnectionOutcome {
    return .{ .close = .{ .reason = reason, .goaway = goaway } };
}

/// Why the lane declared a worker dead. The reason goes into the access
/// record of each request the fault ends and into the usage floor written
/// for it.
pub const WorkerFaultReason = enum {
    /// A control packet shorter than its message kind.
    packet_short,
    /// A datagram larger than the receive buffer (`max_message_bytes`).
    packet_too_large,
    /// A packet whose message kind is unknown or is not one its channel
    /// carries.
    unknown_kind,
    /// A packet that carried descriptors or other ancillary data. No packet
    /// from a worker carries any.
    unexpected_descriptor,
    /// A datagram with more descriptors than one receive holds
    /// (`max_fds_per_message`).
    too_many_descriptors,
    /// A zero-length datagram that carried descriptors, which the receive
    /// closes.
    zero_length_datagram_with_descriptors,
    /// An ingress-channel packet, single or batch, that fails to decode
    /// (`common/ipc/ingress_channel.zig`).
    ingress_channel_undecodable,
    /// An fs-fault request that fails to decode (`common/ipc/fs_fault.zig`).
    fs_fault_request_undecodable,
    /// A descriptor naming a request the worker was never sent: stream 0, or
    /// a request identity the stream it names does not hold. A descriptor
    /// for a request the lane has already finished is a race and drops
    /// without a fault.
    descriptor_names_no_request,
    /// A response head too short for its header, over the lane's head caps,
    /// or with a status or header the client may not receive.
    response_head_invalid,
    /// A response descriptor that its stream's response state does not
    /// admit, or whose payload does not fit its operation.
    response_descriptor_invalid,
    /// The completion ring's header says fatal, which the worker sets when it
    /// overruns the ring.
    completion_ring_fatal,
    /// The completion ring claims more records than it has slots.
    completion_ring_corrupt,
    /// A completion record out of sequence.
    completion_sequence_mismatch,
    /// A completion record that fails validation, names a lane the server
    /// does not have, or names a request the worker's request table holds
    /// under another key.
    completion_record_invalid,
    /// A shared payload ring whose cursors contradict each other, or a
    /// descriptor claiming ring bytes the ring does not hold.
    payload_ring_invalid,
    /// An allocation for a packet to or from the worker failed, in the lane
    /// or in the kernel, so the packet could not move.
    allocation_failed,
    /// The worker's socket or one of its eventfds failed with an errno no
    /// other reason names, and the lane can no longer talk to the worker.
    channel_failed,
    /// The worker's control or fault socket hung up.
    peer_closed,
    /// The worker's process exited, as its pidfd reported.
    exited,
    /// A request of the worker outlived its deadline by
    /// `hard_timeout_grace_ns` without the worker ending it.
    deadline_grace_expired,
    /// The worker's usage record ring has its head where no append puts it:
    /// behind the server's own cursor or more than a ring past it
    /// (`RecordCursor.peek` in `common/worker_state/page/snapshots.zig`).
    usage_record_protocol,
    /// The worker's console log ring contradicted itself
    /// (`server/analytics/logs.zig`).
    log_ring_corrupt,
    /// The worker's egress gateway was lost and no later gateway could give
    /// it a session, so the launcher retired it (`Launcher.gatewayLost` in
    /// `server/supervisor/launcher.zig`).
    egress_session_failed,

    /// The reason as `access.jsonl` and `usage.jsonl` spell it. Consumers
    /// read these strings, so a label never changes once it ships.
    pub fn label(reason: WorkerFaultReason) []const u8 {
        return switch (reason) {
            .packet_short => "packet_short",
            .packet_too_large => "packet_too_large",
            .unknown_kind => "unknown_kind",
            .unexpected_descriptor => "unexpected_descriptor",
            .too_many_descriptors => "too_many_descriptors",
            .zero_length_datagram_with_descriptors => "zero_length_datagram_with_descriptors",
            .ingress_channel_undecodable => "ingress_channel_undecodable",
            .fs_fault_request_undecodable => "fs_fault_request_undecodable",
            .descriptor_names_no_request => "descriptor_names_no_request",
            .response_head_invalid => "response_head_invalid",
            .response_descriptor_invalid => "response_descriptor_invalid",
            .completion_ring_fatal => "completion_ring_fatal",
            .completion_ring_corrupt => "completion_ring_corrupt",
            .completion_sequence_mismatch => "completion_sequence_mismatch",
            .completion_record_invalid => "completion_record_invalid",
            .payload_ring_invalid => "payload_ring_invalid",
            .allocation_failed => "allocation_failed",
            .channel_failed => "channel_failed",
            .peer_closed => "peer_closed",
            .exited => "exited",
            .deadline_grace_expired => "deadline_grace_expired",
            .usage_record_protocol => "usage_record_protocol",
            .log_ring_corrupt => "log_ring_corrupt",
            .egress_session_failed => "egress_session_failed",
        };
    }

    /// The longest `label`, for the bound of a record that carries one.
    pub const label_bytes_max: usize = longestLabel(WorkerFaultReason);
};

/// What an error or event on a worker's channels means for the worker. With
/// `ok` nothing the worker did is wrong. With `would_block` the worker's
/// socket, ring or eventfd has nothing to move now: a read ends its drain
/// and re-arms its poll, and a send parks its bytes behind a writability
/// poll or the worker's credit eventfd, under the request's deadline. With
/// `fault` the worker is dead for the reason given.
pub const WorkerOutcome = union(enum) {
    ok,
    would_block,
    fault: WorkerFaultReason,
};

/// An error from one of a worker's callees, tagged with the callee and
/// taking the lane's own faults as `ConnectionError` does.
pub const WorkerError = union(enum) {
    receive: (LaneFault || PacketReceiveError),
    ingress_decode: (LaneFault || IngressDecodeError),
    fs_fault_decode: (LaneFault || FsFaultDecodeError),
    wake: (LaneFault || WakeError),
    completion: (LaneFault || CompletionError),
    send: (LaneFault || WorkerSendError),
};

/// `ipc.packet.recvPacketWithFdsScratch` on a worker's control or fault
/// socket. `EmptyPacketWithFds` is a zero-length datagram that carried
/// descriptors, which the receive closes; a zero-length datagram without any
/// reads as `PeerClosed`, as an end of stream does.
pub const PacketReceiveError = error{
    WouldBlock,
    PeerClosed,
    EmptyPacketWithFds,
    TruncatedMessage,
    TruncatedControlMessage,
    TooManyFds,
    InvalidControlMessage,
    UnexpectedAncillaryData,
    SystemResources,
    Unexpected,
    InvalidHandle,
    DispatchScratchTooSmall,
};

/// The ingress-channel decoders of `common/ipc/ingress_channel/receive.zig`
/// (`decodeReceivedPacket`, `decodeReceivedBatchPacket` and their shared
/// payload forms, `peekDescriptorForError`) and `ipc.decodeMessageKind`.
pub const IngressDecodeError = error{
    InvalidMessageKind,
    InvalidPacket,
    MessageTooLarge,
    IngressSharedPayloadUnavailable,
    InvalidIngressSharedPayloadRing,
    IngressSharedPayloadTooLarge,
    ShortRead,
    OutOfMemory,
};

/// `ipc.fs_fault.decodeRequest`.
pub const FsFaultDecodeError = error{
    InvalidMessageKind,
    ShortRead,
    InvalidPacket,
    InvalidFsFaultRequest,
    OutOfMemory,
};

/// A read of the eventfd a worker writes to wake its reader lane, its
/// completion eventfd (`page.drainCompletionEventfd`, whose short read is
/// `ShortRead`), which also carries the credit of its server-to-worker
/// payload ring (`common/ipc/ingress_channel/payload_ring.zig`).
pub const WakeError = std.posix.ReadError || error{
    ShortRead,
    EventfdShortRead,
};

/// The drain of a worker's completion ring
/// (`WorkerWriterView.drainWorkerCompletions`).
pub const CompletionError = error{
    WorkerCompletionRingFatal,
    WorkerCompletionRingCorrupt,
    WorkerCompletionSequenceMismatch,
    InvalidWorkerCompletionRecord,
    InvalidWorkerCompletionStatus,
};

/// Every send toward a worker: request descriptors, bodies and resets
/// through the send functions of `common/ipc/ingress_channel/send.zig`, the
/// payload ring (`SharedPayloadView.write`), `ipc.packet.sendWithFds`, and
/// fault answers (`ipc.fs_fault.sendResponse`).
pub const WorkerSendError = error{
    WouldBlock,
    IngressSharedPayloadRingFull,
    PeerClosed,
    InvalidIngressSharedPayloadRing,
    SystemResources,
    Unexpected,
    AccessDenied,
    ShortWrite,
    InvalidHandle,
    DispatchScratchTooSmall,
    MessageTooBig,
    MessageTooLarge,
    InvalidPacket,
    TooManyFds,
    IngressSharedPayloadUnavailable,
    IngressSharedPayloadTooLarge,
    MissingFsFaultFd,
    UnexpectedFsFaultFd,
};

/// Sorts an error a worker's callee returned into the worker's outcome, or
/// returns it when it is the lane's own.
pub fn classifyWorkerError(err: WorkerError) LaneFault!WorkerOutcome {
    return switch (err) {
        .receive => |receive_error| classifyReceive(receive_error),
        .ingress_decode => |decode_error| classifyIngressDecode(decode_error),
        .fs_fault_decode => |decode_error| classifyFsFaultDecode(decode_error),
        .wake => |wake_error| classifyWake(wake_error),
        .completion => |completion_error| classifyCompletion(completion_error),
        .send => |send_error| classifySend(send_error),
    };
}

fn classifyReceive(err: (LaneFault || PacketReceiveError)) LaneFault!WorkerOutcome {
    return switch (err) {
        error.WouldBlock => .would_block,
        error.PeerClosed => fault(.peer_closed),
        error.EmptyPacketWithFds => fault(.zero_length_datagram_with_descriptors),
        error.TruncatedMessage => fault(.packet_too_large),
        error.TruncatedControlMessage,
        error.TooManyFds,
        => fault(.too_many_descriptors),
        error.InvalidControlMessage,
        error.UnexpectedAncillaryData,
        => fault(.unexpected_descriptor),
        // ENOBUFS, ENOMEM, or a full descriptor table while the kernel
        // installed descriptors the worker attached.
        error.SystemResources => fault(.allocation_failed),
        error.Unexpected => fault(.channel_failed),
        error.InvalidHandle,
        error.DispatchScratchTooSmall,
        => |lane_fault| lane_fault,
        inline else => |lane_fault| @errorCast(lane_fault),
    };
}

fn classifyIngressDecode(err: (LaneFault || IngressDecodeError)) LaneFault!WorkerOutcome {
    return switch (err) {
        error.InvalidMessageKind => fault(.unknown_kind),
        error.InvalidPacket,
        error.MessageTooLarge,
        error.IngressSharedPayloadUnavailable,
        => fault(.ingress_channel_undecodable),
        // A decoder reads `ShortRead` only from the ring, when it holds fewer
        // bytes than the descriptor claims.
        error.InvalidIngressSharedPayloadRing,
        error.IngressSharedPayloadTooLarge,
        error.ShortRead,
        => fault(.payload_ring_invalid),
        error.OutOfMemory => fault(.allocation_failed),
        inline else => |lane_fault| @errorCast(lane_fault),
    };
}

fn classifyFsFaultDecode(err: (LaneFault || FsFaultDecodeError)) LaneFault!WorkerOutcome {
    return switch (err) {
        error.InvalidMessageKind => fault(.unknown_kind),
        error.ShortRead,
        error.InvalidPacket,
        error.InvalidFsFaultRequest,
        => fault(.fs_fault_request_undecodable),
        error.OutOfMemory => fault(.allocation_failed),
        inline else => |lane_fault| @errorCast(lane_fault),
    };
}

fn classifyWake(err: (LaneFault || WakeError)) LaneFault!WorkerOutcome {
    return switch (err) {
        // No wake is pending.
        error.WouldBlock => .would_block,
        error.NotOpenForReading => |lane_fault| lane_fault,
        // A read of an eventfd fails like this only when the descriptor is no
        // eventfd. The worker shares it, so the failure retires the worker
        // and leaves the lane alone.
        error.ShortRead,
        error.EventfdShortRead,
        error.InputOutput,
        error.AccessDenied,
        error.BrokenPipe,
        error.SystemResources,
        error.OperationAborted,
        error.LockViolation,
        error.ConnectionResetByPeer,
        error.ProcessNotFound,
        error.Unexpected,
        error.IsDir,
        error.ConnectionTimedOut,
        error.SocketNotConnected,
        error.Canceled,
        => fault(.channel_failed),
        inline else => |lane_fault| @errorCast(lane_fault),
    };
}

fn classifyCompletion(err: (LaneFault || CompletionError)) LaneFault!WorkerOutcome {
    return switch (err) {
        error.WorkerCompletionRingFatal => fault(.completion_ring_fatal),
        error.WorkerCompletionRingCorrupt => fault(.completion_ring_corrupt),
        error.WorkerCompletionSequenceMismatch => fault(.completion_sequence_mismatch),
        error.InvalidWorkerCompletionRecord,
        error.InvalidWorkerCompletionStatus,
        => fault(.completion_record_invalid),
        inline else => |lane_fault| @errorCast(lane_fault),
    };
}

fn classifySend(err: (LaneFault || WorkerSendError)) LaneFault!WorkerOutcome {
    return switch (err) {
        error.WouldBlock,
        error.IngressSharedPayloadRingFull,
        => .would_block,
        error.PeerClosed => fault(.peer_closed),
        error.InvalidIngressSharedPayloadRing => fault(.payload_ring_invalid),
        error.SystemResources => fault(.allocation_failed),
        // The socket failed in a way the lane cannot pin on anything: an
        // unmapped errno, a security module's refusal, or a partial write,
        // which a SEQPACKET socket never makes.
        error.Unexpected,
        error.AccessDenied,
        error.ShortWrite,
        => fault(.channel_failed),
        error.InvalidHandle,
        error.DispatchScratchTooSmall,
        => |lane_fault| lane_fault,
        // The lane built a message its own send refuses: a payload over the
        // packet, the socket or the ring, a ring the descriptor may not use,
        // more descriptors than a packet holds, or a fault answer whose
        // descriptor does not match its status. The lane's limits rule each
        // one out, so the caller logs the name and stops the lane.
        error.MessageTooBig,
        error.MessageTooLarge,
        error.InvalidPacket,
        error.TooManyFds,
        error.IngressSharedPayloadUnavailable,
        error.IngressSharedPayloadTooLarge,
        error.MissingFsFaultFd,
        error.UnexpectedFsFaultFd,
        => error.WorkerSendMisuse,
        inline else => |lane_fault| @errorCast(lane_fault),
    };
}

fn fault(reason: WorkerFaultReason) WorkerOutcome {
    return .{ .fault = reason };
}

/// What queueing a worker's response onto its client stream decided. A
/// `worker_fault` broke the response protocol, and the lane handles it as
/// any worker fault. A `connection` outcome is the client side's: with
/// `keep` the stream cannot take this response, so the caller resets it if
/// it is still open and cancels the request toward the worker, which stays
/// alive; with `close` the connection closes as a connection fault.
pub const ResponseQueueOutcome = union(enum) {
    worker_fault: WorkerFaultReason,
    connection: ConnectionOutcome,
};

/// `http2/writing.zig` queueing a worker's response descriptor onto its
/// stream (`queueWorkerResponseDescriptor`,
/// `tryQueueWorkerResponseHeadChunkPair`), with the decode and HPACK
/// encoding of the response head inside them.
pub const ResponseQueueError = error{
    InvalidH2StreamIdentity,
    InvalidH2WorkerOutboundDescriptor,
    IngressSharedPayloadUnavailable,
    InvalidPacket,
    ShortRead,
    ResponseHeadersTooLarge,
    InvalidHttp2ResponseStatus,
    InvalidHttp2ResponseHeader,
    HpackHeaderListTooLarge,
    HpackOutputTooSmall,
    OutOfMemory,
    Http2PendingResponseTooLarge,
    Http2UnknownStream,
    Http2WriteBackpressure,
    HpackEncoderPoisoned,
    HpackBadData,
    HpackInvalidArgument,
    Http2ProtocolError,
    Http2FlowControlError,
    MessageTooLarge,
    Http2FrameTooLarge,
    ShortHttp2Frame,
    ShortHttp2FrameHeader,
    InvalidHttp2StreamId,
    NoSpaceLeft,
    Overflow,
};

/// Sorts an error from queueing a worker's response into the worker's or
/// the client side's outcome, or returns it when it is the lane's own.
pub fn classifyResponseQueueError(err: (LaneFault || ResponseQueueError)) LaneFault!ResponseQueueOutcome {
    return switch (err) {
        error.InvalidH2StreamIdentity => .{ .worker_fault = .descriptor_names_no_request },
        // The decoder moved ring payloads inline, so a response descriptor
        // without inline bytes carries no payload at all.
        error.InvalidH2WorkerOutboundDescriptor,
        error.IngressSharedPayloadUnavailable,
        error.InvalidPacket,
        => .{ .worker_fault = .response_descriptor_invalid },
        // The HPACK size errors come from the encoder's check of the head
        // before it encodes anything, so the table stays in step.
        error.ShortRead,
        error.ResponseHeadersTooLarge,
        error.InvalidHttp2ResponseStatus,
        error.InvalidHttp2ResponseHeader,
        error.HpackHeaderListTooLarge,
        error.HpackOutputTooSmall,
        => .{ .worker_fault = .response_head_invalid },
        error.OutOfMemory,
        error.Http2PendingResponseTooLarge,
        error.Http2UnknownStream,
        => .{ .connection = .keep },
        error.Http2WriteBackpressure => .{ .connection = close(.write_backpressure, null) },
        error.HpackEncoderPoisoned,
        error.HpackBadData,
        error.HpackInvalidArgument,
        => .{ .connection = close(.compression_error, .compression_error) },
        // The send windows and frames are the lane's own accounting and
        // encoding for this connection.
        error.Http2ProtocolError,
        error.Http2FlowControlError,
        error.MessageTooLarge,
        error.Http2FrameTooLarge,
        error.ShortHttp2Frame,
        error.ShortHttp2FrameHeader,
        error.InvalidHttp2StreamId,
        error.NoSpaceLeft,
        error.Overflow,
        => .{ .connection = close(.internal_error, .internal_error) },
        inline else => |lane_fault| @errorCast(lane_fault),
    };
}

/// The lane's io_uring calls: `get_sqe` behind every prep helper, `submit`,
/// and the wait in `copy_cqes`. Every one is also a lane fault.
pub const RingError = error{
    SubmissionQueueFull,
    CompletionQueueOvercommitted,
    SignalInterrupt,
    SystemResources,
    FileDescriptorInvalid,
    FileDescriptorInBadState,
    SubmissionQueueEntryInvalid,
    BufferInvalid,
    RingShuttingDown,
    OpcodeNotSupported,
    Unexpected,
};

/// Whether a ring call that failed with `err` can succeed once the lane has
/// reaped its completions and submitted again. The caller retries a bounded
/// number of times and returns the error after the last try; any other ring
/// error it returns at once.
pub fn ringErrorIsTransient(err: RingError) bool {
    return switch (err) {
        // A signal interrupted the wait (EINTR), the kernel had no memory for
        // the submission (EAGAIN), the completion queue's overflow list is
        // not flushed yet (EBUSY), or a failed submit left the submission
        // queue full.
        error.SignalInterrupt,
        error.SystemResources,
        error.CompletionQueueOvercommitted,
        error.SubmissionQueueFull,
        => true,
        error.FileDescriptorInvalid,
        error.FileDescriptorInBadState,
        error.SubmissionQueueEntryInvalid,
        error.BufferInvalid,
        error.RingShuttingDown,
        error.OpcodeNotSupported,
        error.Unexpected,
        => false,
    };
}

/// A read of the lane's deadline timerfd (`EventSet.drainDeadlineTimer`).
pub const TimerReadError = std.posix.ReadError || error{
    TimerfdShortRead,
};

/// Ends a drain of the deadline timerfd. `WouldBlock` means no expiration is
/// left and the call returns; every other error is a lane fault.
pub fn classifyTimerReadError(err: TimerReadError) LaneFault!void {
    return switch (err) {
        error.WouldBlock => {},
        error.NotOpenForReading,
        error.Canceled,
        error.SystemResources,
        error.Unexpected,
        error.TimerfdShortRead,
        => |lane_fault| lane_fault,
        // Socket and file errors a timerfd never returns: the descriptor is
        // not the timerfd the lane created. The caller logs the name before
        // it reports `Unexpected`.
        error.InputOutput,
        error.AccessDenied,
        error.BrokenPipe,
        error.OperationAborted,
        error.LockViolation,
        error.ConnectionResetByPeer,
        error.ProcessNotFound,
        error.IsDir,
        error.ConnectionTimedOut,
        error.SocketNotConnected,
        => error.Unexpected,
    };
}

/// One handler of the lane's loop: a method of the lane type that takes the
/// lane and, unless `Argument` is `void`, one argument.
pub const LoopHandler = struct {
    name: []const u8,
    Argument: type,
};

/// The handlers the loop of `runner/ring_driver.zig` calls, one per event
/// source. Each returns `LaneFault!void`, and `assertLoopHandlers` checks a
/// lane type against this list. Each handler classifies an error where its
/// callee returns it (`classifyConnectionError`, `classifyWorkerError`,
/// `classifyResponseQueueError`, `ringErrorIsTransient`,
/// `classifyTimerReadError`). A stream handler that the HTTP/2 driver
/// (`http2/connection.zig`) calls answers a failure of its dispatch or body
/// path on its stream and returns only a lane fault or an `Http2Error`. What each handler does with
/// the outcomes it meets is listed after the table.
pub const loop_handlers = [_]LoopHandler{
    .{ .name = "handleConnectionReadable", .Argument = u32 },
    .{ .name = "handleConnectionWritable", .Argument = u32 },
    .{ .name = "handleAcceptCqe", .Argument = std.os.linux.io_uring_cqe },
    .{ .name = "handleCommands", .Argument = void },
    .{ .name = "handleWorkerControlReadable", .Argument = u32 },
    .{ .name = "handleWorkerControlWritable", .Argument = u32 },
    .{ .name = "handleWorkerCompletions", .Argument = u32 },
    .{ .name = "handleWorkerFsFault", .Argument = u32 },
    .{ .name = "handleWorkerPidfd", .Argument = u32 },
    .{ .name = "handleDeadlineTimer", .Argument = void },
    .{ .name = "handleStop", .Argument = void },
};
// A worker fault below means: mark the worker dead with the reason, answer
// each of its requests in flight on the lane with 502, or RST_STREAM when the
// lane's own record says the response head went out, write the reason into
// each access record and usage floor, and queue the worker's retirement.
//
// handleConnectionReadable(lane, slot: u32) LaneFault!void
//   Drives the handshake or HTTP/2 of the connection in `slot` after its
//   read poll fired. On `ConnectionOutcome.close` it closes the connection,
//   queuing GOAWAY with the outcome's code when there is one and the write
//   queue takes it, and resets every stream of the connection toward its
//   worker; on `.keep` it re-arms the polls the connection waits on.
// handleConnectionWritable(lane, slot: u32) LaneFault!void
//   Flushes the connection's queued writes after its write poll fired, then
//   drives it as `handleConnectionReadable` does, with the same outcomes.
// handleAcceptCqe(lane, cqe: std.os.linux.io_uring_cqe) LaneFault!void
//   Gives an accepted socket a connection slot and starts its handshake, or
//   re-arms the multishot accept the kernel ended. A socket that cannot be
//   set up (`ConnectionError.accept`) closes alone and is counted; a failed
//   re-arm or an accept errno no single connection explains is a lane fault.
// handleCommands(lane) LaneFault!void
//   Takes the lane's wake bits, retrying the request bodies parked on a full
//   payload ring and resuming the workers whose forwarding window reopened,
//   then drains the command queue (`lane_commands.zig`). `worker_died` is a
//   worker fault with the reason the command carries, for this lane's
//   requests on the worker and the reader role it holds; a forwarded
//   descriptor that shows its worker faulty is a worker fault too. A command
//   naming a request or worker that is gone gives back what it holds and does
//   nothing else.
// handleWorkerControlReadable(lane, registration: u32) LaneFault!void
//   Drains a bounded batch from the worker's control socket, queues each
//   response of this lane's requests onto its stream and forwards the rest
//   to their lanes. `WorkerOutcome.would_block` ends the drain and re-arms
//   the read poll; `.fault` is a worker fault. A
//   `ResponseQueueOutcome.connection` resets that stream or closes that
//   connection and leaves the worker alone.
// handleWorkerControlWritable(lane, registration: u32) LaneFault!void
//   Sends, in order, the bytes parked on the worker's full control socket.
//   `.would_block` parks the rest again; `.fault` is a worker fault.
// handleWorkerCompletions(lane, registration: u32) LaneFault!void
//   Wakes the lanes whose request bodies wait on the worker's full payload
//   ring, then drains the worker's control socket, then its completion
//   eventfd and ring, finishes each request of this lane a completion names,
//   or parks the completion behind its response, and forwards the rest to
//   their lanes. `.fault` is a worker fault.
// handleWorkerFsFault(lane, registration: u32) LaneFault!void
//   Answers each fault request on the worker's fault socket. `.fault` is a
//   worker fault; an answer that would block is dropped, and the worker's
//   read then ends at its request's deadline.
// handleWorkerPidfd(lane, registration: u32) LaneFault!void
//   The pidfd of a worker this lane reads reported its exit: a worker fault
//   with `.exited`.
// handleDeadlineTimer(lane) LaneFault!void
//   Drains the timerfd and expires the deadlines due. A connection that
//   opened no stream by its pre-request deadline closes as
//   `.pre_request_timeout`. One where no stream serves a request closes as
//   `.idle_timeout` past its idle deadline, after GOAWAY NO_ERROR is
//   written, or as `.stall_timeout` at once past its stall deadline. A
//   request still waiting for a worker slot at its deadline leaves its
//   pool's waiters with 503. A dispatched request past its deadline plus
//   `hard_timeout_grace_ns` first lets its worker's output in; a completion
//   parked behind its response then ends it, with RST_STREAM for the
//   response, and otherwise its worker takes a fault with
//   `.deadline_grace_expired`, which answers it 504, or RST_STREAM when its
//   head went out, and its other requests 502.
// handleStop(lane) LaneFault!void
//   Runs once the server is stopping: queues GOAWAY with no new streams on
//   every HTTP/2 connection, best effort, serves until no request of the lane
//   is live and it reads no worker, then closes each connection still open as
//   `.server_stop`.

/// Fails to compile unless `Lane` declares every handler of `loop_handlers`
/// with the signature the list gives it.
pub fn assertLoopHandlers(comptime Lane: type) void {
    inline for (loop_handlers) |handler| {
        if (!@hasDecl(Lane, handler.name))
            @compileError(@typeName(Lane) ++ " declares no loop handler " ++ handler.name);
        const Expected = if (handler.Argument == void)
            fn (*Lane) LaneFault!void
        else
            fn (*Lane, handler.Argument) LaneFault!void;
        if (@TypeOf(@field(Lane, handler.name)) != Expected)
            @compileError(handler.name ++ " must be " ++ @typeName(Expected));
    }
}

fn longestLabel(comptime Reason: type) usize {
    var longest: usize = 0;
    for (std.enums.values(Reason)) |reason|
        longest = @max(longest, reason.label().len);
    return longest;
}

/// Fails to compile unless every error of `Subset` is in `Superset`.
fn assertErrorSubset(comptime Subset: type, comptime Superset: type) void {
    @setEvalBranchQuota(10_000);
    for (@typeInfo(Subset).error_set.?) |member| {
        const found = for (@typeInfo(Superset).error_set.?) |candidate| {
            if (std.mem.eql(u8, member.name, candidate.name))
                break true;
        } else false;
        if (!found)
            @compileError("error." ++ member.name ++ " is not in " ++ @typeName(Superset));
    }
}

comptime {
    // A ring error left after its retries is returned as it is.
    assertErrorSubset(RingError, LaneFault);
    // A worker fault's label travels in the access and usage records, which
    // are sized for labels up to this bound.
    std.debug.assert(WorkerFaultReason.label_bytes_max <= runtime_logs.WORKER_FAULT_BYTES_MAX);
}

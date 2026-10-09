//! The failure-domain tables of an ingress lane (`server/ingress/fault.zig`).
//! Every error a table names maps to exactly one outcome, the one this file
//! expects for it, and a lane fault the table does not name comes back
//! unchanged; a send or receive that would block is backpressure; the labels
//! analytics consumers read are pinned, unique, lowercase words joined by
//! underscores; the lane-fault set holds no error a client or a worker
//! produces; every error the classified callees return today is in their
//! table or is a lane fault; and the loop-handler check accepts a lane that
//! declares every handler. Lane `server-ingress-test`; the tables run alone
//! here, with no lane, socket or worker.

const std = @import("std");
const server_main = @import("collo_server_main");
const ipc = @import("collo_ipc");
const page = @import("collo_worker_state").page;
const ktls = @import("collo_ktls");
const os = @import("collo_os");

const fault = server_main.ingress.fault;
const ErrorCode = @import("collo_http").http2.ErrorCode;
const connection = server_main.http2.connection;
const writing = server_main.http2.writing;
const request_head = server_main.http2.request_head;
const Slot = server_main.connection_slot.Slot;
const TlsConnection = @typeInfo(@FieldType(Slot, "tls_connection")).optional.child;
const PeerAddress = @FieldType(Slot, "peer_address");

test "every connection error classifies as its table row expects" {
    try expectTable(http2_table);
    try expectTable(client_io_table);
    try expectTable(tls_handshake_table);
    try expectTable(request_head_table);
    try expectTable(accept_table);
}

test "every worker error classifies as its table row expects" {
    try expectTable(receive_table);
    try expectTable(ingress_decode_table);
    try expectTable(fs_fault_decode_table);
    try expectTable(wake_table);
    try expectTable(completion_table);
    try expectTable(send_table);
}

test "every error from queueing a worker's response classifies as its table row expects" {
    try expectTable(response_queue_table);
}

test "a worker channel that would block is backpressure, never a fault" {
    const would_block: fault.WorkerOutcome = .would_block;
    try std.testing.expectEqualDeep(would_block, try fault.classifyWorkerError(.{ .receive = error.WouldBlock }));
    try std.testing.expectEqualDeep(would_block, try fault.classifyWorkerError(.{ .wake = error.WouldBlock }));
    try std.testing.expectEqualDeep(would_block, try fault.classifyWorkerError(.{ .send = error.WouldBlock }));
    try std.testing.expectEqualDeep(would_block, try fault.classifyWorkerError(.{ .send = error.IngressSharedPayloadRingFull }));
    // A client socket that would block keeps its connection waiting for its
    // poll.
    const keep: fault.ConnectionOutcome = .keep;
    try std.testing.expectEqualDeep(keep, try fault.classifyConnectionError(.{ .client_io = error.WouldBlock }));
}

test "ring errors are retried only where reaping completions can clear them, and all are lane faults" {
    const transient = [_][]const u8{
        "SignalInterrupt",
        "SystemResources",
        "CompletionQueueOvercommitted",
        "SubmissionQueueFull",
    };
    inline for (@typeInfo(fault.RingError).error_set.?) |member| {
        const err = @field(fault.RingError, member.name);
        const expected = comptime containsName(&transient, member.name);
        try std.testing.expectEqual(expected, fault.ringErrorIsTransient(err));
        try std.testing.expect(comptime setHas(fault.LaneFault, member.name));
    }
}

test "a timerfd read ends its drain on WouldBlock and fails the lane otherwise" {
    try fault.classifyTimerReadError(error.WouldBlock);
    // Errors a timerfd can return keep their names; the socket and file
    // errors it cannot return read as `Unexpected`.
    const kept = [_][]const u8{
        "NotOpenForReading",
        "Canceled",
        "SystemResources",
        "Unexpected",
        "TimerfdShortRead",
    };
    inline for (@typeInfo(fault.TimerReadError).error_set.?) |member| {
        if (comptime std.mem.eql(u8, member.name, "WouldBlock"))
            continue;
        const err = @field(fault.TimerReadError, member.name);
        const expected: anyerror = if (comptime containsName(&kept, member.name)) err else error.Unexpected;
        try std.testing.expectError(expected, fault.classifyTimerReadError(err));
    }
}

test "fault and close labels are pinned, unique, lowercase words joined by underscores" {
    try expectLabels(fault.WorkerFaultReason, &worker_fault_labels);
    try expectLabels(fault.ConnectionCloseReason, &connection_close_labels);
}

test "the lane fault set names no error a client or a worker produces" {
    // Errors that come from a client or a worker, never from the lane's own
    // state.
    const client_or_worker_errors = [_][]const u8{
        "TooManyHttp2Settings",
        "Http2FlowControlError",
        "TooManyRequestHeaders",
        "ShortRead",
        "InvalidMessageKind",
        "TruncatedControlMessage",
        "WorkerCompletionRingFatal",
        "WorkerCompletionRingCorrupt",
        "InvalidIngressSharedPayloadRing",
        "PeerClosed",
        "WouldBlock",
        "Http2ProtocolError",
        "Http2HeaderBlockTooLarge",
        "Http2WriteBackpressure",
        "HpackBadData",
        "TlsHandshakeFailed",
        "ConnectionResetByPeer",
        "BrokenPipe",
        "MessageTooBig",
        "EmptyPacketWithFds",
        "TruncatedMessage",
        "TooManyFds",
        "InvalidPacket",
        "MessageTooLarge",
        "IngressSharedPayloadUnavailable",
        "IngressSharedPayloadTooLarge",
        "IngressSharedPayloadRingFull",
        "InvalidFsFaultRequest",
        "UnexpectedFsFaultFd",
        "ResponseHeadersTooLarge",
        "InvalidH2WorkerOutboundDescriptor",
        "InvalidH2StreamIdentity",
        "WorkerCompletionSequenceMismatch",
        "InvalidWorkerCompletionRecord",
    };
    inline for (client_or_worker_errors) |name| {
        if (comptime setHas(fault.LaneFault, name)) {
            std.debug.print("error.{s} is in LaneFault\n", .{name});
            return error.TestClientOrWorkerErrorIsLaneFault;
        }
    }
}

test "every error the classified callees return today is in their table or is a lane fault" {
    comptime {
        @setEvalBranchQuota(200_000);
        assertCovered(ErrorsOfCall(@TypeOf(connection.drive(StubLane, stub_lane, stub_slot))), fault.Http2Error, "Http2Error");
        assertCovered(ErrorsOfCall(@TypeOf(writing.flushPendingWrite(StubLane, stub_lane, stub_slot))), fault.Http2Error, "Http2Error");
        assertCovered(ErrorsOfCall(@TypeOf(writing.queueRstStream(StubLane, stub_lane, stub_slot, 1, .cancel))), fault.Http2Error, "Http2Error");
        assertCovered(ErrorsOfCall(@TypeOf(writing.queueGoawayNoNewStreams(StubLane, stub_lane, stub_slot))), fault.Http2Error, "Http2Error");
        assertCovered(ErrorsOfCall(@TypeOf(writing.flushPendingWindowUpdates(StubLane, stub_lane, stub_slot))), fault.Http2Error, "Http2Error");
        assertCovered(ErrorsOfCall(@TypeOf(writing.flushPendingResponseData(StubLane, stub_lane, stub_slot, null))), fault.Http2Error, "Http2Error");
        assertCovered(ErrorsOfCall(@TypeOf(writing.queueResponseHead(StubLane, stub_lane, stub_slot, 1, 200, &.{}, true))), fault.Http2Error, "Http2Error");
        assertCovered(ErrorsOfCall(@TypeOf(writing.queueResponseChunk(StubLane, stub_lane, stub_slot, 1, "", true))), fault.Http2Error, "Http2Error");
        assertCovered(ErrorsOf(Slot.h2ReserveStream), fault.Http2Error, "Http2Error");
        assertCovered(ErrorsOf(Slot.h2SetRequestBodyExpectation), fault.Http2Error, "Http2Error");
        assertCovered(ErrorsOf(Slot.h2RecordRequestBodyChunk), fault.Http2Error, "Http2Error");
        assertCovered(ErrorsOf(Slot.h2ActivateStream), fault.Http2Error, "Http2Error");
        assertCovered(ErrorsOf(Slot.h2AppendPreparingBody), fault.Http2Error, "Http2Error");
        assertCovered(ErrorsOf(Slot.h2AppendActivePendingBody), fault.Http2Error, "Http2Error");
        assertCovered(ErrorsOf(Slot.h2EnsureActivePendingBodyCapacity), fault.Http2Error, "Http2Error");
        assertCovered(ErrorsOf(Slot.h2BufferInboundWindowUpdate), fault.Http2Error, "Http2Error");
        assertCovered(ErrorsOf(Slot.h2RestoreTakenPendingBodyConnectionCredit), fault.Http2Error, "Http2Error");

        assertCovered(std.posix.ReadError, fault.ClientIoError, "ClientIoError");
        assertCovered(ErrorsOf(ktls.readApplicationData), fault.ClientIoError, "ClientIoError");
        assertCovered(ErrorsOf(std.posix.writev), fault.ClientIoError, "ClientIoError");

        assertCovered(ErrorsOf(TlsConnection.step), fault.TlsHandshakeError, "TlsHandshakeError");
        assertCovered(ErrorsOf(TlsConnection.exportKtlsInitialState), fault.TlsHandshakeError, "TlsHandshakeError");
        assertCovered(ErrorsOf(ktls.enableKernelRxTx), fault.TlsHandshakeError, "TlsHandshakeError");

        assertCovered(ErrorsOf(request_head.parse), fault.RequestHeadError, "RequestHeadError");
        assertCovered(ErrorsOf(request_head.validateTrailers), fault.RequestHeadError, "RequestHeadError");
        assertCovered(ErrorsOf(request_head.normalizeAuthority), fault.RequestHeadError, "RequestHeadError");

        assertCovered(ErrorsOf(os.socket.setTcpNoDelay), fault.AcceptError, "AcceptError");
        assertCovered(ErrorsOf(PeerAddress.fromSocket), fault.AcceptError, "AcceptError");

        assertCovered(ErrorsOf(ipc.recvPacketWithFdsScratch), fault.PacketReceiveError, "PacketReceiveError");

        assertCovered(ErrorsOf(ipc.decodeMessageKind), fault.IngressDecodeError, "IngressDecodeError");
        assertCovered(ErrorsOf(ipc.ingress_channel.peekDescriptorForError), fault.IngressDecodeError, "IngressDecodeError");
        assertCovered(ErrorsOf(ipc.ingress_channel.decodeReceivedPacket), fault.IngressDecodeError, "IngressDecodeError");
        assertCovered(ErrorsOf(ipc.ingress_channel.decodeReceivedPacketWithSharedPayload), fault.IngressDecodeError, "IngressDecodeError");
        assertCovered(ErrorsOf(ipc.ingress_channel.decodeReceivedBatchPacket), fault.IngressDecodeError, "IngressDecodeError");
        assertCovered(ErrorsOf(ipc.ingress_channel.decodeReceivedBatchPacketWithSharedPayload), fault.IngressDecodeError, "IngressDecodeError");

        assertCovered(ErrorsOf(ipc.fs_fault.decodeRequest), fault.FsFaultDecodeError, "FsFaultDecodeError");

        assertCovered(ErrorsOf(page.drainCompletionEventfd), fault.WakeError, "WakeError");
        assertCovered(std.posix.ReadError, fault.WakeError, "WakeError");

        assertCovered(ErrorsOf(page.WorkerWriterView.drainWorkerCompletions), fault.CompletionError, "CompletionError");

        assertCovered(ErrorsOf(ipc.packet.sendWithFds), fault.WorkerSendError, "WorkerSendError");
        assertCovered(ErrorsOf(ipc.ingress_channel.SharedPayloadView.write), fault.WorkerSendError, "WorkerSendError");
        assertCovered(ErrorsOf(ipc.ingress_channel.sendDescriptor), fault.WorkerSendError, "WorkerSendError");
        assertCovered(ErrorsOf(ipc.ingress_channel.sendDescriptorPayload), fault.WorkerSendError, "WorkerSendError");
        assertCovered(ErrorsOf(ipc.ingress_channel.sendDescriptorPayloadRequireRing), fault.WorkerSendError, "WorkerSendError");
        assertCovered(ErrorsOf(ipc.ingress_channel.sendDescriptorPayloadMaybeSharedWithRing), fault.WorkerSendError, "WorkerSendError");
        assertCovered(ErrorsOf(ipc.ingress_channel.sendDescriptorBatchPayloads), fault.WorkerSendError, "WorkerSendError");
        assertCovered(ErrorsOf(ipc.ingress_channel.sendDescriptorBatchPayloadsWithRing), fault.WorkerSendError, "WorkerSendError");
        assertCovered(ErrorsOf(ipc.ingress_channel.sendDescriptorBatchRingPayloads), fault.WorkerSendError, "WorkerSendError");
        assertCovered(ErrorsOf(ipc.fs_fault.sendResponse), fault.WorkerSendError, "WorkerSendError");

        assertCovered(ErrorsOfCall(@TypeOf(writing.queueWorkerResponseDescriptor(StubLane, stub_lane, stub_slot, stub_received))), fault.ResponseQueueError, "ResponseQueueError");
        assertCovered(ErrorsOfCall(@TypeOf(writing.tryQueueWorkerResponseHeadChunkPair(StubLane, stub_lane, stub_slot, &.{}))), fault.ResponseQueueError, "ResponseQueueError");

        assertCovered(ErrorsOf(std.os.linux.IoUring.poll_add), fault.RingError, "RingError");
        assertCovered(ErrorsOf(std.os.linux.IoUring.poll_remove), fault.RingError, "RingError");
        assertCovered(ErrorsOf(std.os.linux.IoUring.accept_multishot), fault.RingError, "RingError");
        assertCovered(ErrorsOf(std.os.linux.IoUring.submit), fault.RingError, "RingError");
        assertCovered(ErrorsOf(std.os.linux.IoUring.copy_cqes), fault.RingError, "RingError");

        assertCovered(std.posix.ReadError, fault.TimerReadError, "TimerReadError");
    }
}

test "the loop handler check accepts a lane that declares every handler" {
    comptime fault.assertLoopHandlers(HandlerLane);
}

// The tables. Each row lists the errors that classify alike; together the
// rows of a table name every error of its set once.

const http2_table = struct {
    const Set = fault.Http2Error;
    const Outcome = fault.ConnectionOutcome;
    fn classify(err: (fault.LaneFault || Set)) fault.LaneFault!Outcome {
        return fault.classifyConnectionError(.{ .http2 = err });
    }
    const rows = [_]Row(Set, Outcome){
        .{ .expected = close(.protocol_error, .protocol_error), .errors = &.{
            error.Http2ProtocolError,
            error.Http2UnknownStream,
            error.Http2ContentLengthMismatch,
            error.Http2TooManyConcurrentStreams,
        } },
        .{ .expected = close(.protocol_error, .enhance_your_calm), .errors = &.{error.Http2EnhanceYourCalm} },
        .{ .expected = close(.protocol_error, .stream_closed), .errors = &.{error.Http2StreamClosed} },
        .{ .expected = close(.frame_size_error, .frame_size_error), .errors = &.{error.Http2FrameSizeError} },
        .{ .expected = close(.flow_control_error, .flow_control_error), .errors = &.{error.Http2FlowControlError} },
        .{ .expected = close(.compression_error, .compression_error), .errors = &.{
            error.HpackBadData,
            error.HpackInvalidArgument,
            error.HpackEncoderPoisoned,
        } },
        .{ .expected = close(.header_block_too_large, .compression_error), .errors = &.{
            error.Http2HeaderBlockTooLarge,
            error.HpackHeaderListTooLarge,
        } },
        .{ .expected = close(.header_too_large, .compression_error), .errors = &.{error.HpackOutputTooSmall} },
        .{ .expected = close(.settings_error, .enhance_your_calm), .errors = &.{error.TooManyHttp2Settings} },
        .{ .expected = close(.settings_error, .frame_size_error), .errors = &.{error.ShortHttp2Setting} },
        .{ .expected = close(.write_backpressure, null), .errors = &.{error.Http2WriteBackpressure} },
        .{ .expected = close(.allocation_failed, .internal_error), .errors = &.{error.OutOfMemory} },
        .{ .expected = close(.internal_error, .internal_error), .errors = &.{
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
        } },
    };
};

const client_io_table = struct {
    const Set = fault.ClientIoError;
    const Outcome = fault.ConnectionOutcome;
    fn classify(err: (fault.LaneFault || Set)) fault.LaneFault!Outcome {
        return fault.classifyConnectionError(.{ .client_io = err });
    }
    const rows = [_]Row(Set, Outcome){
        .{ .expected = .{ .outcome = .keep }, .errors = &.{error.WouldBlock} },
        .{ .expected = close(.peer_closed, null), .errors = &.{
            error.PeerClosed,
            error.ConnectionResetByPeer,
            error.BrokenPipe,
            error.ConnectionTimedOut,
            error.SocketNotConnected,
        } },
        .{ .expected = .same_lane_fault, .errors = &.{
            error.NotOpenForReading,
            error.NotOpenForWriting,
            error.InvalidHandle,
        } },
        .{ .expected = close(.tls_io_failed, null), .errors = &.{
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
        } },
    };
};

const tls_handshake_table = struct {
    const Set = fault.TlsHandshakeError;
    const Outcome = fault.ConnectionOutcome;
    fn classify(err: (fault.LaneFault || Set)) fault.LaneFault!Outcome {
        return fault.classifyConnectionError(.{ .tls_handshake = err });
    }
    const rows = [_]Row(Set, Outcome){
        .{ .expected = .same_lane_fault, .errors = &.{
            error.InvalidHandle,
            error.MissingTlsConnection,
        } },
        .{ .expected = close(.tls_handshake_failed, null), .errors = &.{
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
        } },
    };
};

const request_head_table = struct {
    const Set = fault.RequestHeadError;
    const Outcome = fault.ConnectionOutcome;
    fn classify(err: (fault.LaneFault || Set)) fault.LaneFault!Outcome {
        return fault.classifyConnectionError(.{ .request_head = err });
    }
    const rows = [_]Row(Set, Outcome){
        .{ .expected = .{ .outcome = .keep }, .errors = &.{
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
        } },
    };
};

const accept_table = struct {
    const Set = fault.AcceptError;
    const Outcome = fault.ConnectionOutcome;
    fn classify(err: (fault.LaneFault || Set)) fault.LaneFault!Outcome {
        return fault.classifyConnectionError(.{ .accept = err });
    }
    const rows = [_]Row(Set, Outcome){
        .{ .expected = close(.connection_limit, null), .errors = &.{
            error.IngressHeaderBufferExhausted,
            error.ConnectionSlabFull,
        } },
        .{ .expected = close(.setup_failed, null), .errors = &.{
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
        } },
    };
};

const receive_table = struct {
    const Set = fault.PacketReceiveError;
    const Outcome = fault.WorkerOutcome;
    fn classify(err: (fault.LaneFault || Set)) fault.LaneFault!Outcome {
        return fault.classifyWorkerError(.{ .receive = err });
    }
    const rows = [_]Row(Set, Outcome){
        .{ .expected = .{ .outcome = .would_block }, .errors = &.{error.WouldBlock} },
        .{ .expected = workerFault(.peer_closed), .errors = &.{error.PeerClosed} },
        .{ .expected = workerFault(.zero_length_datagram_with_descriptors), .errors = &.{error.EmptyPacketWithFds} },
        .{ .expected = workerFault(.packet_too_large), .errors = &.{error.TruncatedMessage} },
        .{ .expected = workerFault(.too_many_descriptors), .errors = &.{
            error.TruncatedControlMessage,
            error.TooManyFds,
        } },
        .{ .expected = workerFault(.unexpected_descriptor), .errors = &.{
            error.InvalidControlMessage,
            error.UnexpectedAncillaryData,
        } },
        .{ .expected = workerFault(.allocation_failed), .errors = &.{error.SystemResources} },
        .{ .expected = workerFault(.channel_failed), .errors = &.{error.Unexpected} },
        .{ .expected = .same_lane_fault, .errors = &.{
            error.InvalidHandle,
            error.DispatchScratchTooSmall,
        } },
    };
};

const ingress_decode_table = struct {
    const Set = fault.IngressDecodeError;
    const Outcome = fault.WorkerOutcome;
    fn classify(err: (fault.LaneFault || Set)) fault.LaneFault!Outcome {
        return fault.classifyWorkerError(.{ .ingress_decode = err });
    }
    const rows = [_]Row(Set, Outcome){
        .{ .expected = workerFault(.unknown_kind), .errors = &.{error.InvalidMessageKind} },
        .{ .expected = workerFault(.ingress_channel_undecodable), .errors = &.{
            error.InvalidPacket,
            error.MessageTooLarge,
            error.IngressSharedPayloadUnavailable,
        } },
        .{ .expected = workerFault(.payload_ring_invalid), .errors = &.{
            error.InvalidIngressSharedPayloadRing,
            error.IngressSharedPayloadTooLarge,
            error.ShortRead,
        } },
        .{ .expected = workerFault(.allocation_failed), .errors = &.{error.OutOfMemory} },
    };
};

const fs_fault_decode_table = struct {
    const Set = fault.FsFaultDecodeError;
    const Outcome = fault.WorkerOutcome;
    fn classify(err: (fault.LaneFault || Set)) fault.LaneFault!Outcome {
        return fault.classifyWorkerError(.{ .fs_fault_decode = err });
    }
    const rows = [_]Row(Set, Outcome){
        .{ .expected = workerFault(.unknown_kind), .errors = &.{error.InvalidMessageKind} },
        .{ .expected = workerFault(.fs_fault_request_undecodable), .errors = &.{
            error.ShortRead,
            error.InvalidPacket,
            error.InvalidFsFaultRequest,
        } },
        .{ .expected = workerFault(.allocation_failed), .errors = &.{error.OutOfMemory} },
    };
};

const wake_table = struct {
    const Set = fault.WakeError;
    const Outcome = fault.WorkerOutcome;
    fn classify(err: (fault.LaneFault || Set)) fault.LaneFault!Outcome {
        return fault.classifyWorkerError(.{ .wake = err });
    }
    const rows = [_]Row(Set, Outcome){
        .{ .expected = .{ .outcome = .would_block }, .errors = &.{error.WouldBlock} },
        .{ .expected = .same_lane_fault, .errors = &.{error.NotOpenForReading} },
        .{ .expected = workerFault(.channel_failed), .errors = &.{
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
        } },
    };
};

const completion_table = struct {
    const Set = fault.CompletionError;
    const Outcome = fault.WorkerOutcome;
    fn classify(err: (fault.LaneFault || Set)) fault.LaneFault!Outcome {
        return fault.classifyWorkerError(.{ .completion = err });
    }
    const rows = [_]Row(Set, Outcome){
        .{ .expected = workerFault(.completion_ring_fatal), .errors = &.{error.WorkerCompletionRingFatal} },
        .{ .expected = workerFault(.completion_ring_corrupt), .errors = &.{error.WorkerCompletionRingCorrupt} },
        .{ .expected = workerFault(.completion_sequence_mismatch), .errors = &.{error.WorkerCompletionSequenceMismatch} },
        .{ .expected = workerFault(.completion_record_invalid), .errors = &.{
            error.InvalidWorkerCompletionRecord,
            error.InvalidWorkerCompletionStatus,
        } },
    };
};

const send_table = struct {
    const Set = fault.WorkerSendError;
    const Outcome = fault.WorkerOutcome;
    fn classify(err: (fault.LaneFault || Set)) fault.LaneFault!Outcome {
        return fault.classifyWorkerError(.{ .send = err });
    }
    const rows = [_]Row(Set, Outcome){
        .{ .expected = .{ .outcome = .would_block }, .errors = &.{
            error.WouldBlock,
            error.IngressSharedPayloadRingFull,
        } },
        .{ .expected = workerFault(.peer_closed), .errors = &.{error.PeerClosed} },
        .{ .expected = workerFault(.payload_ring_invalid), .errors = &.{error.InvalidIngressSharedPayloadRing} },
        .{ .expected = workerFault(.allocation_failed), .errors = &.{error.SystemResources} },
        .{ .expected = workerFault(.channel_failed), .errors = &.{
            error.Unexpected,
            error.AccessDenied,
            error.ShortWrite,
        } },
        .{ .expected = .same_lane_fault, .errors = &.{
            error.InvalidHandle,
            error.DispatchScratchTooSmall,
        } },
        .{ .expected = .{ .lane_fault = error.WorkerSendMisuse }, .errors = &.{
            error.MessageTooBig,
            error.MessageTooLarge,
            error.InvalidPacket,
            error.TooManyFds,
            error.IngressSharedPayloadUnavailable,
            error.IngressSharedPayloadTooLarge,
            error.MissingFsFaultFd,
            error.UnexpectedFsFaultFd,
        } },
    };
};

const response_queue_table = struct {
    const Set = fault.ResponseQueueError;
    const Outcome = fault.ResponseQueueOutcome;
    fn classify(err: (fault.LaneFault || Set)) fault.LaneFault!Outcome {
        return fault.classifyResponseQueueError(err);
    }
    const rows = [_]Row(Set, Outcome){
        .{ .expected = .{ .outcome = .{ .worker_fault = .descriptor_names_no_request } }, .errors = &.{error.InvalidH2StreamIdentity} },
        .{ .expected = .{ .outcome = .{ .worker_fault = .response_descriptor_invalid } }, .errors = &.{
            error.InvalidH2WorkerOutboundDescriptor,
            error.IngressSharedPayloadUnavailable,
            error.InvalidPacket,
        } },
        .{ .expected = .{ .outcome = .{ .worker_fault = .response_head_invalid } }, .errors = &.{
            error.ShortRead,
            error.ResponseHeadersTooLarge,
            error.InvalidHttp2ResponseStatus,
            error.InvalidHttp2ResponseHeader,
            error.HpackHeaderListTooLarge,
            error.HpackOutputTooSmall,
        } },
        .{ .expected = .{ .outcome = .{ .connection = .keep } }, .errors = &.{
            error.OutOfMemory,
            error.Http2PendingResponseTooLarge,
            error.Http2UnknownStream,
        } },
        .{ .expected = .{ .outcome = .{ .connection = closeOutcome(.write_backpressure, null) } }, .errors = &.{error.Http2WriteBackpressure} },
        .{ .expected = .{ .outcome = .{ .connection = closeOutcome(.compression_error, .compression_error) } }, .errors = &.{
            error.HpackEncoderPoisoned,
            error.HpackBadData,
            error.HpackInvalidArgument,
        } },
        .{ .expected = .{ .outcome = .{ .connection = closeOutcome(.internal_error, .internal_error) } }, .errors = &.{
            error.Http2ProtocolError,
            error.Http2FlowControlError,
            error.MessageTooLarge,
            error.Http2FrameTooLarge,
            error.ShortHttp2Frame,
            error.ShortHttp2FrameHeader,
            error.InvalidHttp2StreamId,
            error.NoSpaceLeft,
            error.Overflow,
        } },
    };
};

// Labels as analytics consumers read them; a label that changes breaks those
// consumers, so changing one here is a decision, never a cleanup.
const worker_fault_labels = [_]Label(fault.WorkerFaultReason){
    .{ .packet_short, "packet_short" },
    .{ .packet_too_large, "packet_too_large" },
    .{ .unknown_kind, "unknown_kind" },
    .{ .unexpected_descriptor, "unexpected_descriptor" },
    .{ .too_many_descriptors, "too_many_descriptors" },
    .{ .zero_length_datagram_with_descriptors, "zero_length_datagram_with_descriptors" },
    .{ .ingress_channel_undecodable, "ingress_channel_undecodable" },
    .{ .fs_fault_request_undecodable, "fs_fault_request_undecodable" },
    .{ .descriptor_names_no_request, "descriptor_names_no_request" },
    .{ .response_head_invalid, "response_head_invalid" },
    .{ .response_descriptor_invalid, "response_descriptor_invalid" },
    .{ .completion_ring_fatal, "completion_ring_fatal" },
    .{ .completion_ring_corrupt, "completion_ring_corrupt" },
    .{ .completion_sequence_mismatch, "completion_sequence_mismatch" },
    .{ .completion_record_invalid, "completion_record_invalid" },
    .{ .payload_ring_invalid, "payload_ring_invalid" },
    .{ .allocation_failed, "allocation_failed" },
    .{ .channel_failed, "channel_failed" },
    .{ .peer_closed, "peer_closed" },
    .{ .exited, "exited" },
    .{ .deadline_grace_expired, "deadline_grace_expired" },
    .{ .usage_record_protocol, "usage_record_protocol" },
    .{ .log_ring_corrupt, "log_ring_corrupt" },
    .{ .egress_session_failed, "egress_session_failed" },
};

const connection_close_labels = [_]Label(fault.ConnectionCloseReason){
    .{ .tls_handshake_failed, "tls_handshake_failed" },
    .{ .tls_io_failed, "tls_io_failed" },
    .{ .protocol_error, "protocol_error" },
    .{ .frame_size_error, "frame_size_error" },
    .{ .flow_control_error, "flow_control_error" },
    .{ .compression_error, "compression_error" },
    .{ .settings_error, "settings_error" },
    .{ .header_block_too_large, "header_block_too_large" },
    .{ .header_too_large, "header_too_large" },
    .{ .write_backpressure, "write_backpressure" },
    .{ .allocation_failed, "allocation_failed" },
    .{ .peer_closed, "peer_closed" },
    .{ .idle, "idle" },
    .{ .server_stop, "server_stop" },
    .{ .internal_error, "internal_error" },
    .{ .connection_limit, "connection_limit" },
    .{ .setup_failed, "setup_failed" },
};

/// What one row of a table expects its errors to classify as: an outcome,
/// the same error back as a lane fault, or one named lane fault.
fn Expected(comptime Outcome: type) type {
    return union(enum) {
        outcome: Outcome,
        same_lane_fault,
        lane_fault: fault.LaneFault,
    };
}

fn Row(comptime Set: type, comptime Outcome: type) type {
    return struct {
        expected: Expected(Outcome),
        errors: []const Set,
    };
}

fn Label(comptime Reason: type) type {
    return struct { Reason, []const u8 };
}

fn closeOutcome(reason: fault.ConnectionCloseReason, goaway: ?ErrorCode) fault.ConnectionOutcome {
    return .{ .close = .{ .reason = reason, .goaway = goaway } };
}

fn close(reason: fault.ConnectionCloseReason, goaway: ?ErrorCode) Expected(fault.ConnectionOutcome) {
    return .{ .outcome = closeOutcome(reason, goaway) };
}

fn workerFault(reason: fault.WorkerFaultReason) Expected(fault.WorkerOutcome) {
    return .{ .outcome = .{ .fault = reason } };
}

/// Checks a table: its rows name every error of its set exactly once, each
/// error classifies as its row expects, and each lane fault outside the set
/// comes back unchanged.
fn expectTable(comptime Table: type) !void {
    comptime assertRowsCoverSet(Table.Set, Table.Outcome, &Table.rows);
    inline for (Table.rows) |row| {
        inline for (row.errors) |err| {
            const result = Table.classify(err);
            switch (row.expected) {
                .outcome => |expected| {
                    const actual = result catch |lane_fault| {
                        std.debug.print("error.{s} classified as lane fault error.{s}\n", .{ @errorName(err), @errorName(lane_fault) });
                        return error.TestUnexpectedLaneFault;
                    };
                    try std.testing.expectEqualDeep(expected, actual);
                },
                .same_lane_fault => try std.testing.expectError(err, result),
                .lane_fault => |expected| try std.testing.expectError(expected, result),
            }
        }
    }
    inline for (@typeInfo(fault.LaneFault).error_set.?) |member| {
        if (comptime !setHas(Table.Set, member.name)) {
            const lane_fault = @field(fault.LaneFault, member.name);
            try std.testing.expectError(lane_fault, Table.classify(lane_fault));
        }
    }
}

fn assertRowsCoverSet(comptime Set: type, comptime Outcome: type, comptime rows: []const Row(Set, Outcome)) void {
    @setEvalBranchQuota(100_000);
    for (@typeInfo(Set).error_set.?) |member| {
        var count: usize = 0;
        for (rows) |row| {
            for (row.errors) |err| {
                if (std.mem.eql(u8, @errorName(err), member.name))
                    count += 1;
            }
        }
        if (count != 1)
            @compileError(std.fmt.comptimePrint("error.{s} is in {d} rows of its table", .{ member.name, count }));
    }
}

fn expectLabels(comptime Reason: type, comptime pinned: []const Label(Reason)) !void {
    // The pinned list names every reason once, so a new reason needs a label
    // here before this compiles.
    comptime {
        for (std.enums.values(Reason)) |reason| {
            var count: usize = 0;
            for (pinned) |entry| {
                if (entry[0] == reason)
                    count += 1;
            }
            if (count != 1)
                @compileError(std.fmt.comptimePrint("{s} has {d} pinned labels", .{ @tagName(reason), count }));
        }
    }
    var longest: usize = 0;
    for (pinned, 0..) |entry, index| {
        const text = entry[0].label();
        try std.testing.expectEqualStrings(entry[1], text);
        try std.testing.expect(isLowercaseWords(text));
        for (pinned[0..index]) |earlier|
            try std.testing.expect(!std.mem.eql(u8, earlier[0].label(), text));
        longest = @max(longest, text.len);
    }
    try std.testing.expectEqual(longest, Reason.label_bytes_max);
}

/// Lowercase ASCII words joined by single underscores.
fn isLowercaseWords(text: []const u8) bool {
    if (text.len == 0 or text[0] == '_' or text[text.len - 1] == '_')
        return false;
    for (text, 0..) |byte, index| {
        if (byte == '_') {
            if (text[index - 1] == '_')
                return false;
        } else if (byte < 'a' or byte > 'z') {
            return false;
        }
    }
    return true;
}

/// Fails to compile when `Callee` returns an error that is neither in
/// `Table` nor a lane fault.
fn assertCovered(comptime Callee: type, comptime Table: type, comptime table_name: []const u8) void {
    @setEvalBranchQuota(100_000);
    for (@typeInfo(Callee).error_set.?) |member| {
        if (!setHas(Table, member.name) and !setHas(fault.LaneFault, member.name))
            @compileError("error." ++ member.name ++ " is in neither fault." ++ table_name ++ " nor fault.LaneFault");
    }
}

fn setHas(comptime Set: type, comptime name: []const u8) bool {
    @setEvalBranchQuota(100_000);
    for (@typeInfo(Set).error_set.?) |member| {
        if (std.mem.eql(u8, member.name, name))
            return true;
    }
    return false;
}

fn containsName(comptime names: []const []const u8, comptime name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name))
            return true;
    }
    return false;
}

fn ErrorsOf(comptime function: anytype) type {
    return ErrorsOfCall(@typeInfo(@TypeOf(function)).@"fn".return_type.?);
}

fn ErrorsOfCall(comptime Result: type) type {
    return @typeInfo(Result).error_union.error_set;
}

// Stands in for the lane's stream handlers with empty error sets, so the
// sets reflected from the HTTP/2 driver above are its own.
const StubLane = struct {
    service: struct { allocator: std.mem.Allocator },
    header_buffers: StubHeaderBuffers,

    pub fn updateConnectionInterest(_: *StubLane, _: *Slot) error{}!void {}

    pub fn closeRuntimeConnection(_: *StubLane, _: *Slot, _: anytype) void {}

    pub fn startDynamicH2(_: *StubLane, _: *Slot, _: u32, _: *const request_head.ParsedHead) error{}!bool {
        return true;
    }

    pub fn handleH2DataFrame(_: *StubLane, _: *Slot, _: u32, _: []const u8, _: bool, _: usize) error{}!connection.DataFrameHandling {
        return .consumed;
    }

    pub fn handleH2DataFrameBatch(_: *StubLane, _: *Slot, _: u32, _: []const connection.DataFrameChunk) error{}!connection.DataFrameHandling {
        return .consumed;
    }

    pub fn handleH2ResetFrame(_: *StubLane, _: *Slot, _: u32, _: u32) error{}!bool {
        return true;
    }

    pub fn flushPendingH2RequestBodies(_: *StubLane, _: *Slot) error{}!bool {
        return false;
    }
};

const StubHeaderBuffers = struct {
    pub fn buffer(_: *StubHeaderBuffers, _: u32) []u8 {
        return &.{};
    }
};

// Only their types are taken; nothing reads them.
const stub_lane: *StubLane = undefined;
const stub_slot: *Slot = undefined;
const stub_received: *ipc.ingress_channel.Received = undefined;

const HandlerLane = struct {
    pub fn handleConnectionReadable(_: *HandlerLane, _: u32) fault.LaneFault!void {}
    pub fn handleConnectionWritable(_: *HandlerLane, _: u32) fault.LaneFault!void {}
    pub fn handleAcceptCqe(_: *HandlerLane, _: std.os.linux.io_uring_cqe) fault.LaneFault!void {}
    pub fn handleCommands(_: *HandlerLane) fault.LaneFault!void {}
    pub fn handleWorkerControlReadable(_: *HandlerLane, _: u32) fault.LaneFault!void {}
    pub fn handleWorkerControlWritable(_: *HandlerLane, _: u32) fault.LaneFault!void {}
    pub fn handleWorkerCompletions(_: *HandlerLane, _: u32) fault.LaneFault!void {}
    pub fn handleWorkerFsFault(_: *HandlerLane, _: u32) fault.LaneFault!void {}
    pub fn handleWorkerPidfd(_: *HandlerLane, _: u32) fault.LaneFault!void {}
    pub fn handleDeadlineTimer(_: *HandlerLane) fault.LaneFault!void {}
    pub fn handleWorkerPayloadCredit(_: *HandlerLane, _: u32) fault.LaneFault!void {}
    pub fn handleStop(_: *HandlerLane) fault.LaneFault!void {}
};

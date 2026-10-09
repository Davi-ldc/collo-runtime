//! The request bodies and client resets of an ingress lane's HTTP/2 streams,
//! on the lane thread that owns their connection: the DATA frames of a stream
//! whose request waits for a worker slot or is dispatched, the body a stream
//! buffers until its worker takes it, the inline and payload-ring sends of
//! body chunks, the lane's refusal of a body, and the client's RST_STREAM.
//!
//! Invariants:
//! - A request body is bounded by its `content-length` or, without one, by
//!   `MATERIALIZED_BODY_BYTES_MAX` (`h2RecordRequestBodyChunk` in
//!   `stream_table.zig`), and what a stream buffers by the per-stream and
//!   per-connection bounds of `flow_control.zig`. A body past either is
//!   refused on its stream (`rejectH2RequestBody`).
//! - A buffered body keeps the flow-control credit of its frames until its
//!   bytes reach the worker (`returnBodyCredit`), as `flow_control.zig`
//!   requires.
//! - A body chunk is one of its request's sends (`dispatch.zig`): it goes to
//!   the worker only when nothing of the request waits ahead of it, and
//!   otherwise waits on its stream behind the request's earlier bytes.
//! - The handlers the HTTP/2 driver calls return `StreamError`
//!   (`admission.zig`). A connection that must close is only marked closing
//!   here (`closeRuntimeConnection`); its next turn finishes the close.
//! - A client's reset frees no worker slot its worker may still use: a
//!   dispatched request whose begin reached the worker stays until the worker
//!   completes it, after a `request_reset` tells the worker the stream is gone
//!   (`dispatch.cancelRequestToWorker`). A completion already parked on the
//!   request ends it at once.

const std = @import("std");
const http_common = @import("collo_http");
const ipc = @import("collo_ipc");
const fault = @import("../fault.zig");
const server_responses = @import("../server_responses.zig");
const http2_connection = @import("../http2/connection.zig");
const http2_writing = @import("../http2/writing.zig");
const admission = @import("admission.zig");
const connection_flow = @import("connection_flow.zig");
const connection_slot = @import("connection_slot.zig");
const dispatch = @import("dispatch.zig");
const flow_control = @import("flow_control.zig");
const request_finish = @import("request_finish.zig");
const request_slot_mod = @import("request_slot.zig");

const ConnectionSlot = connection_slot.Slot;
const RequestSlot = request_slot_mod.RequestSlot;
const LaneFault = fault.LaneFault;
const WorkerOutcome = fault.WorkerOutcome;
const StreamError = admission.StreamError;
const Sent = dispatch.Sent;

pub fn Methods(comptime Self: type) type {
    return struct {
        const Admission = admission.Methods(Self);
        const Connection = connection_flow.Methods(Self);
        const Dispatch = dispatch.Methods(Self);
        const RequestFinish = request_finish.Methods(Self);

        pub fn handleH2DataFrame(
            self: *Self,
            runtime: *ConnectionSlot,
            stream_id: u32,
            payload: []const u8,
            end_stream: bool,
            window_credit_len: usize,
        ) StreamError!http2_connection.DataFrameHandling {
            runtime.h2RecordRequestBodyChunk(stream_id, payload.len, end_stream) catch |err| switch (err) {
                error.Http2ContentLengthMismatch => {
                    try rejectH2RequestBody(self, runtime, stream_id, .bad_request);
                    return .consumed;
                },
                error.RequestTooLarge => {
                    try rejectH2RequestBody(self, runtime, stream_id, .payload_too_large);
                    return .consumed;
                },
                else => return error.Http2ProtocolError,
            };
            const chunk = [_]http2_connection.DataFrameChunk{.{
                .payload = payload,
                .end_stream = end_stream,
                .window_credit_len = window_credit_len,
            }};
            const request_slot = findActiveH2Request(self, runtime, stream_id) orelse
                return handlePreparingH2DataFrames(self, runtime, stream_id, &chunk, payload.len);
            return handleActiveH2DataFrames(self, runtime, request_slot, &chunk, payload.len);
        }

        pub fn handleH2DataFrameBatch(
            self: *Self,
            runtime: *ConnectionSlot,
            stream_id: u32,
            chunks: []const http2_connection.DataFrameChunk,
        ) StreamError!http2_connection.DataFrameHandling {
            var total_payload_len: usize = 0;
            for (chunks) |chunk| {
                runtime.h2RecordRequestBodyChunk(stream_id, chunk.payload.len, chunk.end_stream) catch |err| switch (err) {
                    error.Http2ContentLengthMismatch => {
                        try rejectH2RequestBody(self, runtime, stream_id, .bad_request);
                        return .consumed;
                    },
                    error.RequestTooLarge => {
                        try rejectH2RequestBody(self, runtime, stream_id, .payload_too_large);
                        return .consumed;
                    },
                    else => return error.Http2ProtocolError,
                };
                total_payload_len = std.math.add(usize, total_payload_len, chunk.payload.len) catch return error.RequestTooLarge;
            }
            const request_slot = findActiveH2Request(self, runtime, stream_id) orelse
                return handlePreparingH2DataFrames(self, runtime, stream_id, chunks, total_payload_len);
            return handleActiveH2DataFrames(self, runtime, request_slot, chunks, total_payload_len);
        }

        /// Buffers request body on a stream whose request waits for a worker
        /// slot. The bytes keep their flow-control credit until they reach
        /// the worker.
        fn handlePreparingH2DataFrames(
            self: *Self,
            runtime: *ConnectionSlot,
            stream_id: u32,
            chunks: []const http2_connection.DataFrameChunk,
            total_payload_len: usize,
        ) StreamError!http2_connection.DataFrameHandling {
            const stream_state = runtime.h2StreamState(stream_id) orelse return error.Http2UnknownStream;
            switch (stream_state) {
                .preparing => {
                    for (chunks) |chunk| {
                        runtime.h2AppendPreparingBody(
                            self.service.allocator,
                            stream_id,
                            chunk.payload,
                            chunk.end_stream,
                            chunk.window_credit_len,
                        ) catch |err| switch (err) {
                            error.Http2PendingBodyTooLarge => {
                                try rejectH2RequestBody(self, runtime, stream_id, .payload_too_large);
                                return .consumed;
                            },
                            else => |other| return other,
                        };
                    }
                    self.lane.counters.h2_request_body_frames += @intCast(chunks.len);
                    self.lane.counters.h2_request_body_bytes += @intCast(total_payload_len);
                    return if (total_payload_len == 0 and !chunks[chunks.len - 1].end_stream)
                        .consumed
                    else
                        .deferred;
                },
                .active, .draining_response, .vacant => return error.Http2ProtocolError,
            }
        }

        /// Sends request body to a dispatched request's worker, or queues it
        /// on the stream behind the request's earlier bytes.
        fn handleActiveH2DataFrames(
            self: *Self,
            runtime: *ConnectionSlot,
            request_slot: u32,
            chunks: []const http2_connection.DataFrameChunk,
            total_payload_len: usize,
        ) StreamError!http2_connection.DataFrameHandling {
            const slot = &self.dynamic_requests[request_slot];
            if (slot.h2_client_reset)
                return .consumed;
            switch (slot.send_blocked) {
                // The worker's death path ends the request, and its body goes
                // nowhere.
                .failed => return .consumed,
                .socket, .ring => return queueActiveBody(self, runtime, request_slot, chunks, total_payload_len),
                .none => {},
            }
            if (runtime.h2HasPendingBody(slot.ingress_channel_id))
                return queueActiveBody(self, runtime, request_slot, chunks, total_payload_len);
            const sent = if (chunks.len == 1)
                try sendBodyChunk(self, slot, slot.ingress_channel_id, chunks[0].payload, chunks[0].end_stream)
            else
                try sendBodyBatch(self, slot, slot.ingress_channel_id, chunks);
            switch (sent) {
                .sent => {
                    self.lane.counters.h2_request_body_frames += @intCast(chunks.len);
                    self.lane.counters.h2_request_body_bytes += @intCast(total_payload_len);
                    return .consumed;
                },
                .socket_full => {
                    slot.send_blocked = .socket;
                    return queueActiveBody(self, runtime, request_slot, chunks, total_payload_len);
                },
                .ring_full => {
                    slot.send_blocked = .ring;
                    self.lane.counters.h2_request_body_ring_full += 1;
                    return queueActiveBody(self, runtime, request_slot, chunks, total_payload_len);
                },
                .fault => |reason| {
                    try Dispatch.failSend(self, slot, reason);
                    return .consumed;
                },
            }
        }

        /// Appends body bytes to a dispatched stream's pending buffer, behind
        /// the request's earlier bytes, and sends them when nothing blocks
        /// the request or arms the poll that wakes the send. The bytes keep
        /// their flow-control credit until they reach the worker, so a
        /// worker that stops reading stalls the client.
        fn queueActiveBody(
            self: *Self,
            runtime: *ConnectionSlot,
            request_slot: u32,
            chunks: []const http2_connection.DataFrameChunk,
            total_payload_len: usize,
        ) StreamError!http2_connection.DataFrameHandling {
            const slot = &self.dynamic_requests[request_slot];
            const stream_id = slot.ingress_channel_id;
            runtime.h2EnsureActivePendingBodyCapacity(stream_id, total_payload_len) catch |err| switch (err) {
                error.Http2PendingBodyTooLarge => {
                    try rejectH2RequestBody(self, runtime, stream_id, .service_unavailable);
                    return .consumed;
                },
                else => |other| return other,
            };
            for (chunks) |chunk| {
                try runtime.h2AppendActivePendingBody(
                    self.service.allocator,
                    stream_id,
                    chunk.payload,
                    chunk.end_stream,
                    chunk.window_credit_len,
                );
            }
            self.lane.counters.h2_request_body_frames += @intCast(chunks.len);
            self.lane.counters.h2_request_body_bytes += @intCast(total_payload_len);
            if (slot.send_blocked == .none) {
                switch (try Dispatch.flushRequestSends(self, request_slot)) {
                    .ok => return .deferred,
                    .would_block => {},
                    .fault => |reason| {
                        try Dispatch.failSend(self, slot, reason);
                        return .deferred;
                    },
                }
            }
            try Dispatch.armSendPolls(self, slot);
            return .deferred;
        }

        /// Answers a stream whose request body the lane refuses. A waiting
        /// request ends with the answer; a dispatched one detaches from its
        /// stream and is cancelled toward its worker.
        fn rejectH2RequestBody(
            self: *Self,
            runtime: *ConnectionSlot,
            stream_id: u32,
            response_id: server_responses.Id,
        ) StreamError!void {
            const stream_state = runtime.h2StreamState(stream_id) orelse return;
            switch (stream_state) {
                .preparing => {
                    try Admission.writeH2ServerResponse(self, runtime, stream_id, response_id);
                    if (preparingRequestSlot(self, runtime, stream_id)) |request_slot| {
                        try RequestFinish.finishRequest(self, request_slot, .{ .rejected = response_id });
                        return;
                    }
                    Admission.finishH2LocalResponse(self, runtime, stream_id);
                },
                .active => {
                    try Admission.writeH2ServerResponse(self, runtime, stream_id, response_id);
                    try cancelActiveH2RequestForLocalResponse(self, runtime, stream_id, @intFromEnum(http_common.http2.ErrorCode.cancel));
                },
                .vacant, .draining_response => {},
            }
        }

        pub fn handleH2ResetFrame(self: *Self, runtime: *ConnectionSlot, stream_id: u32, error_code: u32) StreamError!bool {
            const request_key = runtime.h2MarkStreamReset(self.service.allocator, stream_id) orelse return true;
            const request_slot = Admission.findRequestSlot(self, request_key) orelse return true;
            const slot = &self.dynamic_requests[request_slot];
            if (slot.waiting()) {
                try RequestFinish.finishRequest(self, request_slot, .stream_gone);
                return true;
            }
            if (slot.h2_client_reset)
                return true;
            slot.h2_client_reset = true;
            // A parked completion means the worker already answered, and the
            // reset ended the descriptor flow that would have ended its
            // response, so the request ends here and the worker, done with it,
            // is not told.
            if (try RequestFinish.finishParkedCompletion(self, request_slot))
                return true;
            try Dispatch.cancelRequestToWorker(self, request_slot, error_code);
            return true;
        }

        fn cancelActiveH2RequestForLocalResponse(self: *Self, runtime: *ConnectionSlot, stream_id: u32, error_code: u32) StreamError!void {
            const request_key = runtime.h2DetachActiveRequestForLocalResponse(self.service.allocator, stream_id) orelse return;
            const request_slot = Admission.findRequestSlot(self, request_key) orelse return;
            const slot = &self.dynamic_requests[request_slot];
            if (!slot.dispatched() or slot.h2_client_reset)
                return;
            slot.h2_client_reset = true;
            if (try RequestFinish.finishParkedCompletion(self, request_slot))
                return;
            try Dispatch.cancelRequestToWorker(self, request_slot, error_code);
        }

        /// Retries the bodies of a connection's dispatched streams that wait
        /// on a full payload ring, before the connection driver reads more.
        /// A body behind a full control socket waits for its writability
        /// poll instead.
        pub fn flushPendingH2RequestBodies(self: *Self, runtime: *ConnectionSlot) StreamError!bool {
            var did_work = false;
            for (&runtime.ingress_channels) |*entry| {
                if (entry.state != .active)
                    continue;
                if (!runtime.h2HasPendingBody(entry.stream_id))
                    continue;
                const request_slot = findActiveH2Request(self, runtime, entry.stream_id) orelse continue;
                const slot = &self.dynamic_requests[request_slot];
                if (slot.h2_client_reset or slot.send_blocked != .ring)
                    continue;
                switch (try Dispatch.flushRequestSends(self, request_slot)) {
                    .ok => did_work = true,
                    .would_block => try Dispatch.armSendPolls(self, slot),
                    .fault => |reason| try Dispatch.failSend(self, slot, reason),
                }
            }
            return did_work;
        }

        /// Sends the body a dispatched stream buffered, as one chunk, and
        /// returns its flow-control credit to the client once the worker has
        /// the bytes. A send that would block leaves the bytes where they
        /// are and says what the request waits for (`send_blocked`).
        pub fn flushPendingBody(self: *Self, request_slot: u32) LaneFault!WorkerOutcome {
            const slot = &self.dynamic_requests[request_slot];
            const runtime = Admission.requestConnection(self, slot) orelse return .ok;
            if (slot.h2_client_reset)
                return .ok;
            const stream_id = slot.ingress_channel_id;
            if ((runtime.h2StreamState(stream_id) orelse .vacant) != .active)
                return .ok;
            const pending = runtime.h2PendingBodyView(stream_id) orelse return .ok;
            switch (try sendBodyChunk(self, slot, stream_id, pending.bytes, pending.end_stream)) {
                .sent => {},
                .socket_full => {
                    slot.send_blocked = .socket;
                    return .would_block;
                },
                .ring_full => {
                    slot.send_blocked = .ring;
                    self.lane.counters.h2_request_body_ring_full += 1;
                    return .would_block;
                },
                .fault => |reason| return .{ .fault = reason },
            }
            var transferred = runtime.h2TakePendingBody(stream_id) orelse
                return error.Http2PendingBodyTransferLost;
            defer transferred.deinit(self.service.allocator);
            self.lane.counters.h2_request_body_deferred_flushes += 1;
            if (returnBodyCredit(self, runtime, stream_id, &transferred)) |_| {} else |err| try settleStreamError(self, runtime, err);
            return .ok;
        }

        fn returnBodyCredit(
            self: *Self,
            runtime: *ConnectionSlot,
            stream_id: u32,
            pending: *flow_control.PendingH2Body,
        ) StreamError!bool {
            const window_credit_len = pending.window_credit_len;
            if (window_credit_len == 0)
                return false;
            runtime.h2BufferInboundWindowUpdate(stream_id, window_credit_len) catch |err| {
                try runtime.h2RestoreTakenPendingBodyConnectionCredit(pending);
                return err;
            };
            pending.window_credit_len = 0;
            return http2_writing.flushPendingWindowUpdates(Self, self, runtime);
        }

        /// Sends one body chunk inline, or through the payload ring above
        /// `shared_payload_threshold`. The ring takes one producer at a time,
        /// and requests of two lanes can stream to one worker, so the send
        /// takes `Record.send_mutex`.
        fn sendBodyChunk(
            self: *Self,
            slot: *const RequestSlot,
            stream_id: u32,
            payload: []const u8,
            end_stream: bool,
        ) LaneFault!Sent {
            const worker = slot.worker.?;
            const descriptor = ipc.ingress_channel.Descriptor.requestBodyChunk(
                slot.identity(),
                stream_id,
                0,
                @intCast(payload.len),
                end_stream,
            );
            const send_error = send: {
                worker.send_mutex.lock();
                defer worker.send_mutex.unlock();
                ipc.ingress_channel.sendDescriptorPayloadRequireRing(
                    worker.handle.control_fd,
                    descriptor,
                    payload,
                    self.ipc_send_scratch,
                    worker.handle.ingress_payload.writer(.server_to_worker),
                ) catch |err| break :send err;
                return .sent;
            };
            return Dispatch.sendResult(self, worker, send_error);
        }

        /// `sendBodyChunk` for a run of DATA frames in one batch packet.
        fn sendBodyBatch(
            self: *Self,
            slot: *const RequestSlot,
            stream_id: u32,
            chunks: []const http2_connection.DataFrameChunk,
        ) LaneFault!Sent {
            const worker = slot.worker.?;
            // The connection driver batches at most this many frames.
            std.debug.assert(chunks.len <= ipc.ingress_channel.max_batch_descriptors);
            var entries_buffer: [ipc.ingress_channel.max_batch_descriptors]ipc.ingress_channel.BatchEntry = undefined;
            for (chunks, entries_buffer[0..chunks.len]) |chunk, *entry| {
                entry.* = .{
                    .descriptor = ipc.ingress_channel.Descriptor.requestBodyChunk(
                        slot.identity(),
                        stream_id,
                        0,
                        @intCast(chunk.payload.len),
                        chunk.end_stream,
                    ),
                    .payload = chunk.payload,
                };
            }
            const entries = entries_buffer[0..chunks.len];
            const send_error = send: {
                worker.send_mutex.lock();
                defer worker.send_mutex.unlock();
                ipc.ingress_channel.sendDescriptorBatchPayloadsWithRing(
                    worker.handle.control_fd,
                    entries,
                    self.ipc_send_scratch,
                    worker.handle.ingress_payload.writer(.server_to_worker),
                ) catch |err| break :send err;
                return .sent;
            };
            return Dispatch.sendResult(self, worker, send_error);
        }

        /// Acts on an HTTP/2 error met on `runtime` outside the connection
        /// driver: a lane fault propagates, a failure of one stream leaves
        /// the connection as it is, and a connection fault closes it
        /// (`fault.classifyConnectionError`).
        fn settleStreamError(self: *Self, runtime: *ConnectionSlot, err: StreamError) LaneFault!void {
            switch (try fault.classifyConnectionError(.{ .http2 = err })) {
                .keep => {},
                .close => |close| Connection.closeRuntimeConnection(self, runtime, close),
            }
        }

        /// The slot of the dispatched request on `stream_id` of `runtime`'s
        /// connection.
        fn findActiveH2Request(self: *Self, runtime: *ConnectionSlot, stream_id: u32) ?u32 {
            const request_key = runtime.h2ActiveRequestKey(stream_id) orelse return null;
            const request_slot = Admission.findRequestSlot(self, request_key) orelse return null;
            const slot = &self.dynamic_requests[request_slot];
            if (!slot.dispatched())
                return null;
            if (slot.ingress_channel_id != stream_id or !slot.connection_key.eql(runtime.key))
                return null;
            return request_slot;
        }

        /// The slot of the waiting request bound to the `.preparing` stream
        /// `stream_id` of `runtime`'s connection.
        fn preparingRequestSlot(self: *Self, runtime: *const ConnectionSlot, stream_id: u32) ?u32 {
            for (&runtime.ingress_channels) |*entry| {
                if (entry.state != .preparing or entry.stream_id != stream_id)
                    continue;
                const request = entry.request orelse return null;
                const request_slot = Admission.findRequestSlot(self, request.key) orelse return null;
                if (!self.dynamic_requests[request_slot].waiting())
                    return null;
                return request_slot;
            }
            return null;
        }
    };
}

//! The ingress-channel sends behind a response: the head, body chunks inline
//! or through the shared payload ring, the stream end and the stream reset.
//! Every descriptor carries the request's identity as the dispatch assigned
//! it (`h2Identity`). The worker's end of the control socket does not block
//! (`zygote/child_boot.zig`), so every send here can find it full and
//! reports that instead of failing; a body chunk above
//! `shared_payload_threshold` travels through the ring and can find the ring
//! full as well. The step that found no room sent nothing, and the caller
//! parks it, with everything after it, in the request's outbox
//! (`request/ingress/response_outbox.zig`). A response is committed when its
//! head goes out and at no other point. It runs on the worker's VM thread.

const std = @import("std");
const bindings = @import("collo_bindings");
const ipc = @import("collo_ipc");
const limits = @import("collo_limits");
const request_context = @import("collo_worker_request").context;
const response_model = @import("collo_worker_request").response_model;
const response_outbox = @import("collo_worker_request").ingress.response_outbox;
const state = @import("../runtime/root.zig");
const tracing = @import("trace.zig");

/// Most body bytes one ring batch carries.
const ingress_response_batch_body_bytes: usize = 256 * 1024;

comptime {
    // A first chunk the ring has room for always fits a batch, so a ring
    // batch is never empty (`writeSpan`).
    std.debug.assert(limits.http_body.INGRESS_RESPONSE_CHUNK_BYTES <= ingress_response_batch_body_bytes);
}

/// What a send on the control socket did.
pub const Sent = enum {
    sent,
    /// The socket was full. The send sent nothing and took back the ring
    /// bytes it wrote (`common/ipc/ingress_channel/send.zig`), so the caller
    /// parks the step it tried, and everything after it, in the request's
    /// outbox.
    blocked,
};

/// What a send of the head with the body's first bytes did.
pub const HeadBatch = union(enum) {
    /// The head and those bytes do not fit one batch, and nothing went out;
    /// the caller sends the head alone.
    unbatched,
    /// The batch went out, and the body goes on at this offset.
    sent: usize,
    /// The control socket was full, and nothing went out.
    blocked,
};

/// How far a write of body bytes got.
pub const BodyProgress = enum {
    /// Every byte went out.
    sent,
    /// The payload ring had no room for the next chunk.
    ring_full,
    /// The control socket had no room for the next packet.
    socket_full,
};

/// Body bytes and their place: `bytes` starts at `body_offset` of a body
/// `body_len` long, so the chunk that reaches `body_len` ends the stream.
const BodySpan = struct {
    bytes: []const u8,
    body_offset: usize = 0,
    body_len: usize,
};

/// Turns a send's `error.WouldBlock` into `.blocked` and marks the control
/// channel blocked, so the loop polls the socket for room
/// (`Requests.control_send_blocked`). The worker's end of the socket does
/// not block (`zygote/child_boot.zig`).
pub fn sentOrBlocked(runtime: *state.Runtime, result: anytype) !Sent {
    result catch |err| switch (err) {
        error.WouldBlock => {
            runtime.requests.control_send_blocked = true;
            return .blocked;
        },
        else => |other| return other,
    };
    return .sent;
}

/// Sends `body` from `sent_len.*` on and advances `sent_len.*` past every
/// chunk that went out, so a write that stops resumes there. The chunk that
/// reaches the end of `body` ends the stream.
pub fn writeBody(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    body: []const u8,
    sent_len: *usize,
) !BodyProgress {
    return writeSpan(runtime, request_ctx, .{ .bytes = body, .body_len = body.len }, sent_len);
}

/// Sends a body held in `segments`, `total_len` bytes in all, from its
/// start, and advances `sent_len.*` past every chunk that went out, so the
/// caller can park the rest from there. A chunk never spans two segments.
/// Segments that disagree with `total_len` fail with
/// `error.InvalidResponseBody` before any of them is sent.
pub fn writeSegmentedBody(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    segments: []const bindings.ByteSegment,
    total_len: usize,
    sent_len: *usize,
) !BodyProgress {
    std.debug.assert(sent_len.* == 0);
    var segments_len: usize = 0;
    for (segments) |segment| {
        segments_len = std.math.add(usize, segments_len, segment.slice().len) catch
            return error.InvalidResponseBody;
    }
    if (segments_len != total_len)
        return error.InvalidResponseBody;

    var segment_offset: usize = 0;
    for (segments) |segment| {
        const segment_bytes = segment.slice();
        var segment_sent: usize = 0;
        const progress = try writeSpan(runtime, request_ctx, .{
            .bytes = segment_bytes,
            .body_offset = segment_offset,
            .body_len = total_len,
        }, &segment_sent);
        sent_len.* = segment_offset + segment_sent;
        switch (progress) {
            .sent => {},
            .ring_full, .socket_full => return progress,
        }
        segment_offset += segment_bytes.len;
    }
    return .sent;
}

/// Sends `span.bytes` from `sent_len.*` on, in chunks of at most
/// `chunkLimit`. A chunk above `shared_payload_threshold` goes through the
/// payload ring, batched with the ring-sized chunks after it while the ring
/// has room, and a smaller one rides inline.
fn writeSpan(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    span: BodySpan,
    sent_len: *usize,
) !BodyProgress {
    std.debug.assert(sent_len.* <= span.bytes.len);
    std.debug.assert(span.bytes.len <= span.body_len);
    std.debug.assert(span.body_offset <= span.body_len - span.bytes.len);
    const control_fd = runtime.core.control_fd orelse return error.InvalidArgument;
    const chunk_limit = try chunkLimit(runtime);
    const identity = h2Identity(request_ctx);
    while (sent_len.* < span.bytes.len) {
        const chunk_start = sent_len.*;
        const chunk_len = @min(chunk_limit, span.bytes.len - chunk_start);
        if (chunk_len > ipc.ingress_channel.shared_payload_threshold) {
            const ingress_payload = if (runtime.requests.ingress_payload) |*view| view else return error.IngressSharedPayloadUnavailable;
            const available_capacity = try ingress_payload.availableCapacity(.worker_to_server);
            if (available_capacity < chunk_len)
                return .ring_full;

            var batch_entries: [ipc.ingress_channel.max_batch_descriptors]ipc.ingress_channel.BatchEntry = undefined;
            var batch_count: usize = 0;
            var batch_bytes: usize = 0;
            while (chunk_start + batch_bytes < span.bytes.len and batch_count < batch_entries.len) {
                const next_start = chunk_start + batch_bytes;
                const next_len = @min(chunk_limit, span.bytes.len - next_start);
                if (next_len <= ipc.ingress_channel.shared_payload_threshold)
                    break;
                if (batch_bytes + next_len > ingress_response_batch_body_bytes)
                    break;
                if (batch_bytes + next_len > available_capacity)
                    break;
                batch_bytes += next_len;
                batch_entries[batch_count] = .{
                    .descriptor = ipc.ingress_channel.Descriptor.responseChunk(
                        identity,
                        request_ctx.ingress_channel_id,
                        0,
                        @intCast(next_len),
                        span.body_offset + next_start + next_len == span.body_len,
                    ),
                    .payload = span.bytes[next_start..][0..next_len],
                };
                batch_count += 1;
            }
            std.debug.assert(batch_count > 0);
            switch (try sentOrBlocked(runtime, ipc.ingress_channel.sendDescriptorBatchRingPayloads(
                control_fd,
                batch_entries[0..batch_count],
                runtime.core.dispatch_recv_scratch,
                ingress_payload.writer(.worker_to_server),
            ))) {
                .sent => {},
                .blocked => return .socket_full,
            }
            request_ctx.client_served_bytes += batch_bytes;
            sent_len.* = chunk_start + batch_bytes;
            continue;
        }

        const chunk_end = chunk_start + chunk_len;
        const descriptor = ipc.ingress_channel.Descriptor.responseChunk(
            identity,
            request_ctx.ingress_channel_id,
            0,
            @intCast(chunk_len),
            span.body_offset + chunk_end == span.body_len,
        );
        switch (try sentOrBlocked(runtime, ipc.ingress_channel.sendDescriptorPayloadRequireRing(
            control_fd,
            descriptor,
            span.bytes[chunk_start..chunk_end],
            runtime.core.dispatch_recv_scratch,
            if (runtime.requests.ingress_payload) |*ingress_payload| ingress_payload.writer(.worker_to_server) else null,
        ))) {
            .sent => {},
            .blocked => return .socket_full,
        }
        request_ctx.client_served_bytes += chunk_len;
        sent_len.* = chunk_end;
    }
    return .sent;
}

/// The longest chunk a response body goes out in:
/// `INGRESS_RESPONSE_CHUNK_BYTES`, or less when the packet scratch holds
/// less after a packet header.
fn chunkLimit(runtime: *const state.Runtime) !usize {
    const packet_header_len = @sizeOf(ipc.ingress_channel.Packet);
    if (runtime.core.dispatch_recv_scratch.len <= packet_header_len)
        return error.DispatchScratchTooSmall;
    return @min(
        runtime.core.dispatch_recv_scratch.len - packet_header_len,
        limits.http_body.INGRESS_RESPONSE_CHUNK_BYTES,
    );
}

/// Sends what `buffered` holds: its head first when it has one, then the
/// body from `buffered.offset`. The head is freed once it is sent and
/// `offset` advances past every chunk sent, so a flush that stops resumes
/// where it stopped.
pub fn flushBufferedBody(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    buffered: *response_outbox.BufferedBody,
) !BodyProgress {
    if (buffered.head) |*head| {
        switch (try sendPendingHead(runtime, request_ctx, head)) {
            .sent => {},
            .blocked => return .socket_full,
        }
        head.deinit(runtime.core.allocator);
        buffered.head = null;
    }
    return writeBody(runtime, request_ctx, buffered.body, &buffered.offset);
}

/// Sends the head of `response` alone, ending the stream with it when
/// `end_stream` holds, for a response without a body.
pub fn sendHeadOnly(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    response: *const response_model.Response,
    end_stream: bool,
) !Sent {
    const control_fd = runtime.core.control_fd orelse return error.InvalidArgument;
    const packet_header_len = @sizeOf(ipc.ingress_channel.Packet);
    if (runtime.core.dispatch_recv_scratch.len <= packet_header_len)
        return error.DispatchScratchTooSmall;
    const head_payload = try ipc.ingress_channel.encodeResponseHeadInto(
        runtime.core.dispatch_recv_scratch[packet_header_len..],
        response.status,
        response.headers,
    );
    const descriptor = ipc.ingress_channel.Descriptor.responseHead(
        h2Identity(request_ctx),
        request_ctx.ingress_channel_id,
        0,
        @intCast(head_payload.len),
        response.status,
        @intCast(response.headers.len),
        end_stream,
    );
    return sendHead(runtime, request_ctx, control_fd, descriptor, head_payload);
}

/// Sends the head of a streamed response.
pub fn writeStreamHead(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    response: *const response_model.Response,
) !Sent {
    tracing.mark(runtime, request_ctx, "response_extract_done_ns");
    return sendHeadOnly(runtime, request_ctx, response, false);
}

/// Sends a head the outbox kept. On `.sent` the caller frees it.
pub fn sendPendingHead(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    head: *const response_outbox.PendingHead,
) !Sent {
    const control_fd = runtime.core.control_fd orelse return error.InvalidArgument;
    const descriptor = ipc.ingress_channel.Descriptor.responseHead(
        h2Identity(request_ctx),
        request_ctx.ingress_channel_id,
        0,
        @intCast(head.payload.len),
        head.status,
        head.header_count,
        head.end_stream,
    );
    return sendHead(runtime, request_ctx, control_fd, descriptor, head.payload);
}

/// The head of `response` as the outbox keeps it when its send found no
/// room: the payload encoded into memory from the worker's base allocator.
pub fn pendingHead(
    runtime: *state.Runtime,
    response: *const response_model.Response,
    end_stream: bool,
) !response_outbox.PendingHead {
    const packet_header_len = @sizeOf(ipc.ingress_channel.Packet);
    if (runtime.core.dispatch_recv_scratch.len <= packet_header_len)
        return error.DispatchScratchTooSmall;
    const encoded = try ipc.ingress_channel.encodeResponseHeadInto(
        runtime.core.dispatch_recv_scratch[packet_header_len..],
        response.status,
        response.headers,
    );
    return .{
        .payload = try runtime.core.allocator.dupe(u8, encoded),
        .status = response.status,
        .header_count = @intCast(response.headers.len),
        .end_stream = end_stream,
    };
}

/// Sends a head descriptor with its payload inline and commits the response
/// once it is sent.
fn sendHead(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    control_fd: std.posix.fd_t,
    descriptor: ipc.ingress_channel.Descriptor,
    payload: []const u8,
) !Sent {
    const sent = try sentOrBlocked(runtime, ipc.ingress_channel.sendDescriptorPayload(
        control_fd,
        descriptor,
        payload,
        runtime.core.dispatch_recv_scratch,
    ));
    switch (sent) {
        .sent => request_ctx.markResponseCommitted(),
        .blocked => {},
    }
    return sent;
}

/// Sends one chunk of a streamed body. A chunk the ring has no room for
/// fails with `error.IngressSharedPayloadNeedsCredit`; check `canWritePayload`
/// first.
pub fn writeStreamChunk(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    bytes: []const u8,
    end_stream: bool,
) !Sent {
    const control_fd = runtime.core.control_fd orelse return error.InvalidArgument;
    if (bytes.len == 0 and end_stream)
        return writeStreamEnd(runtime, request_ctx);
    if (!try canWritePayload(runtime, bytes.len))
        return error.IngressSharedPayloadNeedsCredit;

    const descriptor = ipc.ingress_channel.Descriptor.responseChunk(
        h2Identity(request_ctx),
        request_ctx.ingress_channel_id,
        0,
        @intCast(bytes.len),
        end_stream,
    );
    switch (try sentOrBlocked(runtime, ipc.ingress_channel.sendDescriptorPayloadRequireRing(
        control_fd,
        descriptor,
        bytes,
        runtime.core.dispatch_recv_scratch,
        if (runtime.requests.ingress_payload) |*ingress_payload| ingress_payload.writer(.worker_to_server) else null,
    ))) {
        .sent => {},
        .blocked => return .blocked,
    }
    request_ctx.client_served_bytes += bytes.len;
    return .sent;
}

/// Whether `byte_len` bytes can be sent now: inline at or below
/// `shared_payload_threshold`, through the ring above it.
pub fn canWritePayload(runtime: *state.Runtime, byte_len: usize) !bool {
    if (byte_len <= ipc.ingress_channel.shared_payload_threshold)
        return true;
    const ingress_payload = if (runtime.requests.ingress_payload) |*view| view else return error.IngressSharedPayloadUnavailable;
    return (try ingress_payload.availableCapacity(.worker_to_server)) >= byte_len;
}

/// Sends the end of a streamed response.
pub fn writeStreamEnd(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
) !Sent {
    const control_fd = runtime.core.control_fd orelse return error.InvalidArgument;
    return sentOrBlocked(runtime, ipc.ingress_channel.sendDescriptor(
        control_fd,
        ipc.ingress_channel.Descriptor.responseEnd(
            h2Identity(request_ctx),
            request_ctx.ingress_channel_id,
        ),
        runtime.core.dispatch_recv_scratch,
    ));
}

/// Sends the reset of the response's stream with the HTTP/2 error code
/// `reset_code`.
pub fn writeStreamReset(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    reset_code: u32,
) !Sent {
    const control_fd = runtime.core.control_fd orelse return error.InvalidArgument;
    return sentOrBlocked(runtime, ipc.ingress_channel.sendDescriptor(
        control_fd,
        ipc.ingress_channel.Descriptor.responseReset(
            h2Identity(request_ctx),
            request_ctx.ingress_channel_id,
            reset_code,
        ),
        runtime.core.dispatch_recv_scratch,
    ));
}

/// Sends the head and the first ring-sized chunks of `response_body` in one
/// batch. Returns `.unbatched` when the body is small, the ring is absent or
/// has no room, or the head does not fit the batch.
pub fn trySendInitialRingBatch(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    response: *const response_model.Response,
    response_body: []const u8,
) !HeadBatch {
    const control_fd = runtime.core.control_fd orelse return error.InvalidArgument;
    const chunk_limit = try chunkLimit(runtime);
    if (response_body.len == 0 or chunk_limit <= ipc.ingress_channel.shared_payload_threshold)
        return .unbatched;
    const first_chunk_len = @min(chunk_limit, response_body.len);
    if (first_chunk_len <= ipc.ingress_channel.shared_payload_threshold)
        return .unbatched;
    const ingress_payload = if (runtime.requests.ingress_payload) |*view| view else return .unbatched;

    const available_capacity = try ingress_payload.availableCapacity(.worker_to_server);
    if (available_capacity < first_chunk_len)
        return .unbatched;
    var chunk_count: usize = 0;
    var batch_body_bytes: usize = 0;
    var probe_offset: usize = 0;
    while (probe_offset < response_body.len and chunk_count < ipc.ingress_channel.max_batch_descriptors - 1) {
        const next_len = @min(chunk_limit, response_body.len - probe_offset);
        if (next_len <= ipc.ingress_channel.shared_payload_threshold)
            break;
        if (batch_body_bytes + next_len > ingress_response_batch_body_bytes)
            break;
        if (batch_body_bytes + next_len > available_capacity)
            break;
        batch_body_bytes += next_len;
        probe_offset += next_len;
        chunk_count += 1;
    }
    if (chunk_count == 0)
        return .unbatched;

    const entry_count = chunk_count + 1;
    const batch_payload_offset = ipc.ingress_channel.batchPayloadOffset(entry_count) catch return .unbatched;
    if (runtime.core.dispatch_recv_scratch.len <= batch_payload_offset)
        return .unbatched;
    const head_payload = ipc.ingress_channel.encodeResponseHeadInto(
        runtime.core.dispatch_recv_scratch[batch_payload_offset..],
        response.status,
        response.headers,
    ) catch |err| switch (err) {
        error.DispatchScratchTooSmall => return .unbatched,
        else => return err,
    };
    if (batch_payload_offset + head_payload.len > ipc.max_message_bytes)
        return .unbatched;

    const identity = h2Identity(request_ctx);
    var entries: [ipc.ingress_channel.max_batch_descriptors]ipc.ingress_channel.BatchEntry = undefined;
    entries[0] = .{
        .descriptor = ipc.ingress_channel.Descriptor.responseHead(
            identity,
            request_ctx.ingress_channel_id,
            0,
            @intCast(head_payload.len),
            response.status,
            @intCast(response.headers.len),
            false,
        ),
        .payload = head_payload,
    };

    var body_offset: usize = 0;
    var entry_index: usize = 1;
    while (entry_index < entry_count) : (entry_index += 1) {
        const chunk_len = @min(chunk_limit, response_body.len - body_offset);
        const chunk_body = response_body[body_offset..][0..chunk_len];
        body_offset += chunk_len;
        entries[entry_index] = .{
            .descriptor = ipc.ingress_channel.Descriptor.responseChunk(
                identity,
                request_ctx.ingress_channel_id,
                0,
                @intCast(chunk_body.len),
                body_offset == response_body.len,
            ),
            .payload = chunk_body,
        };
    }

    switch (try sentOrBlocked(runtime, ipc.ingress_channel.sendDescriptorBatchPayloadsWithRing(
        control_fd,
        entries[0..entry_count],
        runtime.core.dispatch_recv_scratch,
        ingress_payload.writer(.worker_to_server),
    ))) {
        .sent => {},
        .blocked => return .blocked,
    }
    request_ctx.client_served_bytes += body_offset;
    request_ctx.markResponseCommitted();
    return .{ .sent = body_offset };
}

/// The identity every descriptor of this request carries, as the dispatch
/// assigned it.
pub fn h2Identity(request_ctx: *const request_context.RequestContext) ipc.ingress_channel.RequestIdentity {
    return .{
        .request_id = request_ctx.exec.request_id,
        .request_generation = request_ctx.dispatch_work.request_generation,
        .request_lane_id = request_ctx.dispatch_work.request_lane_id,
        .request_slot = request_ctx.dispatch_work.request_slot,
    };
}

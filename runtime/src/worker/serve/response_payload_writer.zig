//! The ingress-channel sends behind a response: the head, body chunks inline
//! or through the shared payload ring, the stream end and the stream reset.
//! Every descriptor carries the request's identity as the dispatch assigned
//! it (`h2Identity`). A response is committed when its head goes out and at
//! no other point. It runs on the worker's VM thread.
//!
//! The packet that ends a response, the head or chunk that ends the stream,
//! the stream's end or its reset, is the request's last packet and carries
//! its `request_done` as its last entry, so the server gives the request's
//! slot back as it reads the response's end. Every write takes an `Ending`:
//! it stops before that packet (`hold`), which the request's finish sends
//! once the request's cleanup is done (`response_finish.zig:finishRequest`),
//! or it sends that packet with the `request_done` (`carry`).
//!
//! Each body chunk spends the credit `common/ipc/response_credit.zig:Window`
//! says it holds, charged only once the packet that carries it went out. A
//! write stops before a chunk the credit does not cover and reports
//! `credit_empty`. The worker's end of the control socket does not block
//! (`zygote/child_boot.zig`), so every send can find it full, and a chunk
//! above `shared_payload_threshold` can find the ring full, after which the
//! worker has marked itself waiting, so the reader's next release writes the
//! credit eventfd the loop polls (`ringFits`). A send that found no room sent
//! nothing, and each stop records what the response waits for in
//! `RequestContext.response_advance.wait`. The caller keeps the source and
//! the offset reached for the next advance.

const std = @import("std");
const bindings = @import("collo_bindings");
const ipc = @import("collo_ipc");
const limits = @import("collo_limits");
const request_context = @import("collo_worker_request").context;
const response_model = @import("collo_worker_request").response_model;
const response_outbox = @import("collo_worker_request").ingress.response_outbox;
const done_carry = @import("done_carry.zig");
const state = @import("../runtime/root.zig");

/// Most body bytes one ring batch carries.
const ingress_response_batch_body_bytes: usize = 256 * 1024;

comptime {
    // A first chunk the ring has room for always fits a batch, so a ring
    // batch is never empty (`writeSpan`).
    std.debug.assert(limits.http_body.INGRESS_RESPONSE_CHUNK_BYTES <= ingress_response_batch_body_bytes);
    // An empty ring takes any batch wherever its write position stands, so a
    // ring that refuses one holds bytes whose release brings the credit wake
    // (`ringSentOrBlocked`).
    std.debug.assert(2 * ingress_response_batch_body_bytes <= ipc.ingress_channel.shared_payload_ring_capacity);
    // A batch of the chunks one credit window covers, with a head before
    // them and the `request_done` after them, fits one packet's descriptors.
    std.debug.assert(limits.http_body.INGRESS_RESPONSE_CHUNKS_IN_FLIGHT_MAX + 2 <= ipc.ingress_channel.max_batch_descriptors);
}

/// How a write treats the packet that would end its response.
pub const Ending = union(enum) {
    /// Stops before it, with every packet ahead of it sent, and reports
    /// `last`; the request's finish sends it.
    hold,
    /// Sends it with the request's `request_done` as its last entry, built
    /// by `carry` once the rest of the packet is composed.
    carry: *done_carry.DoneCarry,
};

/// What a send on the control socket did.
pub const Sent = enum {
    sent,
    /// The socket was full. The send sent nothing and took back the ring
    /// bytes it wrote (`common/ipc/ingress_channel/send.zig`), so the caller
    /// parks the step it tried, and everything after it, in the request's
    /// outbox.
    blocked,
    /// The step ends the response and the write holds it (`Ending.hold`).
    last,
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
    /// The batch ends the response and the write holds it.
    last,
};

/// How far a write of body bytes got.
pub const BodyProgress = enum {
    /// Every byte went out.
    sent,
    /// The request's credit covers no further chunk.
    credit_empty,
    /// The payload ring had no room for the next chunk.
    ring_full,
    /// The control socket had no room for the next packet.
    socket_full,
    /// Every packet before the one that ends the response went out, and the
    /// write holds that one.
    last,
};

/// Body bytes and their place: `bytes` starts at `body_offset` of a body
/// `body_len` long. With `ends_stream`, the chunk that reaches `body_len`
/// ends the stream; without it, as for one chunk of a streamed body whose
/// end comes later, no chunk does.
const BodySpan = struct {
    bytes: []const u8,
    body_offset: usize = 0,
    body_len: usize,
    ends_stream: bool = true,

    fn endsStreamAt(span: BodySpan, chunk_end: usize) bool {
        return span.ends_stream and span.body_offset + chunk_end == span.body_len;
    }
};

/// Turns a send's `error.WouldBlock` into `.blocked`, marks the response
/// waiting for the socket and the control channel blocked, so the loop polls
/// the socket for room (`Requests.control_send_blocked`).
pub fn sentOrBlocked(runtime: *state.Runtime, request_ctx: *request_context.RequestContext, result: anytype) !Sent {
    result catch |err| switch (err) {
        error.WouldBlock => {
            request_ctx.response_advance.wait = .socket;
            runtime.requests.control_send_blocked = true;
            return .blocked;
        },
        else => |other| return other,
    };
    return .sent;
}

/// What a send of payloads through the ring did.
const RingSent = enum { sent, socket_full, ring_full };

/// `sentOrBlocked` for a send that writes the payload ring. A batch can also
/// find the ring short of room for a chunk that must skip the ring's tail:
/// the send took back what it wrote, and the worker marks itself waiting for
/// the reader's next release, which the ring's bytes guarantee (the comptime
/// check above).
fn ringSentOrBlocked(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    ingress_payload: ?*ipc.ingress_channel.SharedPayloadView,
    result: anytype,
) !RingSent {
    result catch |err| switch (err) {
        error.WouldBlock => {
            request_ctx.response_advance.wait = .socket;
            runtime.requests.control_send_blocked = true;
            return .socket_full;
        },
        error.IngressSharedPayloadRingFull => {
            request_ctx.response_advance.wait = .ring;
            const view = ingress_payload orelse return error.IngressSharedPayloadUnavailable;
            view.markWriterWaiting(.worker_to_server);
            return .ring_full;
        },
        else => |other| return other,
    };
    return .sent;
}

/// Sends `entries`, the packet that ends the response and carries
/// `body_bytes` of its body, with the request's `request_done` from `carry`
/// as its last entry: the entries are composed and their ring payloads
/// written first, then `carry` builds the record, then the packet goes out
/// (`ipc.ingress_channel.encodeBatchEndingInRequestDone`). A packet that
/// finds no room sends nothing and takes its ring payloads back.
fn sendCarried(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    entries: []const ipc.ingress_channel.BatchEntry,
    carry: *done_carry.DoneCarry,
    body_bytes: usize,
) !RingSent {
    const control_fd = runtime.core.control_fd orelse return error.InvalidArgument;
    const ingress_payload = if (runtime.requests.ingress_payload) |*view| view else null;
    const writer = if (ingress_payload) |view| view.writer(.worker_to_server) else null;
    const batch = ipc.ingress_channel.encodeBatchEndingInRequestDone(
        runtime.core.dispatch_recv_scratch,
        entries,
        h2Identity(request_ctx),
        request_ctx.ingress_channel_id,
        writer,
    ) catch |err| switch (err) {
        error.IngressSharedPayloadRingFull => {
            request_ctx.response_advance.wait = .ring;
            const view = ingress_payload orelse return error.IngressSharedPayloadUnavailable;
            view.markWriterWaiting(.worker_to_server);
            return .ring_full;
        },
        else => |other| return other,
    };
    batch.setRequestDone(carry.take(runtime, request_ctx, body_bytes)) catch |err| {
        batch.abandon();
        return err;
    };
    batch.send(control_fd) catch |err| switch (err) {
        error.WouldBlock => {
            request_ctx.response_advance.wait = .socket;
            runtime.requests.control_send_blocked = true;
            return .socket_full;
        },
        else => |other| return other,
    };
    return .sent;
}

/// Sends `entries`, a packet that ends the response and carries
/// `body_bytes` of its body, with the request's `request_done` from `carry`
/// as its last entry, and returns whether it went out; a packet that found
/// no room in the socket or the ring sent nothing.
pub fn sendCarriedBatch(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    entries: []const ipc.ingress_channel.BatchEntry,
    carry: *done_carry.DoneCarry,
    body_bytes: usize,
) !bool {
    return switch (try sendCarried(runtime, request_ctx, entries, carry, body_bytes)) {
        .sent => true,
        .socket_full, .ring_full => false,
    };
}

/// Whether a payload of `byte_len` bytes fits the worker-to-server ring now.
/// When it does not, the worker marks itself waiting and looks once more, so
/// the reader's next release writes the credit eventfd the loop polls,
/// unless this look already sees the room that release made
/// (`SharedPayloadReadRelease`).
fn ringFits(ingress_payload: *ipc.ingress_channel.SharedPayloadView, byte_len: usize) !bool {
    if (try ingress_payload.fits(.worker_to_server, byte_len))
        return true;
    ingress_payload.markWriterWaiting(.worker_to_server);
    return ingress_payload.fits(.worker_to_server, byte_len);
}

/// Sends `body` from `sent_len.*` on and advances `sent_len.*` past every
/// chunk that went out, so a write that stops resumes there. The chunk that
/// reaches the end of `body` ends the stream.
pub fn writeBody(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    body: []const u8,
    sent_len: *usize,
    ending: Ending,
) !BodyProgress {
    return writeSpan(runtime, request_ctx, .{ .bytes = body, .body_len = body.len }, sent_len, ending);
}

/// Sends `bytes`, one chunk of a streamed body, from `sent_len.*` on, split
/// as `writeSpan` splits a body, and advances `sent_len.*` past every chunk
/// that went out, so a write that stops resumes there. With `ends_stream`
/// the last of them ends the stream, and empty bytes send the stream's end
/// alone; without it the end goes out later (`writeStreamEnd`) and no packet
/// of this write ends the response.
pub fn writeStreamBytes(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    bytes: []const u8,
    sent_len: *usize,
    ends_stream: bool,
    ending: Ending,
) !BodyProgress {
    if (ends_stream and bytes.len == 0) {
        return switch (try writeStreamEnd(runtime, request_ctx, ending)) {
            .sent => .sent,
            .blocked => .socket_full,
            .last => .last,
        };
    }
    return writeSpan(runtime, request_ctx, .{
        .bytes = bytes,
        .body_len = bytes.len,
        .ends_stream = ends_stream,
    }, sent_len, ending);
}

/// Sends a body held in `segments`, `total_len` bytes in all, from
/// `sent_len.*` on, and advances `sent_len.*` past every chunk that went
/// out, so a write that stops resumes there. A chunk never spans two
/// segments. Segments that disagree with `total_len` fail with
/// `error.InvalidResponseBody` before any of them is sent.
pub fn writeSegmentedBody(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    segments: []const bindings.ByteSegment,
    total_len: usize,
    sent_len: *usize,
    ending: Ending,
) !BodyProgress {
    std.debug.assert(sent_len.* <= total_len);
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
        if (sent_len.* >= segment_offset + segment_bytes.len) {
            segment_offset += segment_bytes.len;
            continue;
        }
        var segment_sent = sent_len.* - segment_offset;
        const progress = try writeSpan(runtime, request_ctx, .{
            .bytes = segment_bytes,
            .body_offset = segment_offset,
            .body_len = total_len,
        }, &segment_sent, ending);
        sent_len.* = segment_offset + segment_sent;
        switch (progress) {
            .sent => {},
            .credit_empty, .ring_full, .socket_full, .last => return progress,
        }
        segment_offset += segment_bytes.len;
    }
    return .sent;
}

/// Sends `span.bytes` from `sent_len.*` on, in chunks of at most
/// `chunkLimit`. A chunk above `shared_payload_threshold` goes through the
/// payload ring, batched with the ring-sized chunks after it while the ring
/// has room, and a smaller one rides inline. The packet whose last chunk
/// ends the stream is held or carries the `request_done` (`Ending`).
fn writeSpan(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    span: BodySpan,
    sent_len: *usize,
    ending: Ending,
) !BodyProgress {
    std.debug.assert(sent_len.* <= span.bytes.len);
    std.debug.assert(span.bytes.len <= span.body_len);
    std.debug.assert(span.body_offset <= span.body_len - span.bytes.len);
    const control_fd = runtime.core.control_fd orelse return error.InvalidArgument;
    const chunk_limit = try chunkLimit(runtime);
    const identity = h2Identity(request_ctx);
    while (sent_len.* < span.bytes.len) {
        const credit = request_ctx.response_credit.available();
        if (credit == 0) {
            request_ctx.response_advance.wait = .credit;
            return .credit_empty;
        }
        const chunk_start = sent_len.*;
        const chunk_len = @min(chunk_limit, span.bytes.len - chunk_start);
        if (chunk_len > ipc.ingress_channel.shared_payload_threshold) {
            const ingress_payload = if (runtime.requests.ingress_payload) |*view| view else return error.IngressSharedPayloadUnavailable;
            if (!try ringFits(ingress_payload, chunk_len)) {
                request_ctx.response_advance.wait = .ring;
                return .ring_full;
            }
            const available_capacity = try ingress_payload.availableCapacity(.worker_to_server);

            var batch_entries: [ipc.ingress_channel.max_batch_descriptors]ipc.ingress_channel.BatchEntry = undefined;
            var batch_count: usize = 0;
            var batch_bytes: usize = 0;
            // One descriptor stays free for the `request_done` the batch may
            // end with.
            while (chunk_start + batch_bytes < span.bytes.len and batch_count < @min(batch_entries.len - 1, credit)) {
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
                        span.endsStreamAt(next_start + next_len),
                    ),
                    .payload = span.bytes[next_start..][0..next_len],
                };
                batch_count += 1;
            }
            std.debug.assert(batch_count > 0);
            const ring_sent = if (span.endsStreamAt(chunk_start + batch_bytes)) switch (ending) {
                .hold => return .last,
                .carry => |carry| try sendCarried(runtime, request_ctx, batch_entries[0..batch_count], carry, batch_bytes),
            } else try ringSentOrBlocked(runtime, request_ctx, ingress_payload, ipc.ingress_channel.sendDescriptorBatchRingPayloads(
                control_fd,
                batch_entries[0..batch_count],
                runtime.core.dispatch_recv_scratch,
                ingress_payload.writer(.worker_to_server),
            ));
            switch (ring_sent) {
                .sent => {},
                .socket_full => return .socket_full,
                .ring_full => return .ring_full,
            }
            request_ctx.response_credit.spend(batch_count);
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
            span.endsStreamAt(chunk_end),
        );
        const chunk_bytes = span.bytes[chunk_start..chunk_end];
        if (span.endsStreamAt(chunk_end)) {
            const carry = switch (ending) {
                .hold => return .last,
                .carry => |carry| carry,
            };
            switch (try sendCarried(runtime, request_ctx, &.{.{ .descriptor = descriptor, .payload = chunk_bytes }}, carry, chunk_len)) {
                .sent => {},
                .socket_full => return .socket_full,
                .ring_full => return .ring_full,
            }
        } else {
            switch (try sentOrBlocked(runtime, request_ctx, ipc.ingress_channel.sendDescriptorPayloadRequireRing(
                control_fd,
                descriptor,
                chunk_bytes,
                runtime.core.dispatch_recv_scratch,
                if (runtime.requests.ingress_payload) |*ingress_payload| ingress_payload.writer(.worker_to_server) else null,
            ))) {
                .sent => {},
                .blocked => return .socket_full,
                .last => unreachable, // `sentOrBlocked` holds nothing.
            }
        }
        request_ctx.response_credit.spend(1);
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
/// where it stopped. A head over an empty body ends the response itself.
pub fn flushBufferedBody(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    buffered: *response_outbox.BufferedBody,
    ending: Ending,
) !BodyProgress {
    if (buffered.head) |*head| {
        switch (try sendPendingHead(runtime, request_ctx, head, ending)) {
            .sent => {},
            .blocked => return .socket_full,
            .last => return .last,
        }
        head.deinit(runtime.core.allocator);
        buffered.head = null;
        // A head that ended the stream was the response's last packet.
        if (buffered.body.len() == 0)
            return .sent;
    }
    if (buffered.body.isContiguous())
        return writeBody(runtime, request_ctx, buffered.body.contiguous(), &buffered.offset, ending);
    return writeSegmentedBody(runtime, request_ctx, buffered.body.segments(), buffered.body.len(), &buffered.offset, ending);
}

/// Sends the head of `response` alone, ending the stream with it when
/// `end_stream` holds, for a response without a body; such a head is the
/// response's last packet.
pub fn sendHeadOnly(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    response: *const response_model.Response,
    end_stream: bool,
    ending: Ending,
) !Sent {
    const control_fd = runtime.core.control_fd orelse return error.InvalidArgument;
    if (end_stream) {
        const carry = switch (ending) {
            .hold => return .last,
            .carry => |carry| carry,
        };
        // The head's payload sits where a batch of it and the `request_done`
        // places it, so the batch takes it without a copy.
        const payload_offset = try ipc.ingress_channel.batchPayloadOffset(2);
        if (runtime.core.dispatch_recv_scratch.len <= payload_offset)
            return error.DispatchScratchTooSmall;
        const head_payload = try ipc.ingress_channel.encodeResponseHeadInto(
            runtime.core.dispatch_recv_scratch[payload_offset..],
            response.status,
            response.headers,
        );
        return sendCarriedHead(runtime, request_ctx, .{
            .descriptor = headDescriptor(request_ctx, head_payload.len, response.status, response.headers.len, true),
            .payload = head_payload,
        }, carry);
    }
    const packet_header_len = @sizeOf(ipc.ingress_channel.Packet);
    if (runtime.core.dispatch_recv_scratch.len <= packet_header_len)
        return error.DispatchScratchTooSmall;
    const head_payload = try ipc.ingress_channel.encodeResponseHeadInto(
        runtime.core.dispatch_recv_scratch[packet_header_len..],
        response.status,
        response.headers,
    );
    return sendHead(runtime, request_ctx, control_fd, headDescriptor(request_ctx, head_payload.len, response.status, response.headers.len, false), head_payload);
}

/// Sends the head of a streamed response, whose end comes later.
pub fn writeStreamHead(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    response: *const response_model.Response,
) !Sent {
    return sendHeadOnly(runtime, request_ctx, response, false, .hold);
}

/// Sends a head the outbox kept. On `.sent` the caller frees it. A head that
/// ends the stream is the response's last packet.
pub fn sendPendingHead(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    head: *const response_outbox.PendingHead,
    ending: Ending,
) !Sent {
    const control_fd = runtime.core.control_fd orelse return error.InvalidArgument;
    const descriptor = headDescriptor(request_ctx, head.payload.len, head.status, head.header_count, head.end_stream);
    if (head.end_stream) {
        return switch (ending) {
            .hold => .last,
            .carry => |carry| sendCarriedHead(runtime, request_ctx, .{ .descriptor = descriptor, .payload = head.payload }, carry),
        };
    }
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

fn headDescriptor(
    request_ctx: *const request_context.RequestContext,
    payload_len: usize,
    status: u16,
    header_count: usize,
    end_stream: bool,
) ipc.ingress_channel.Descriptor {
    return ipc.ingress_channel.Descriptor.responseHead(
        h2Identity(request_ctx),
        request_ctx.ingress_channel_id,
        0,
        @intCast(payload_len),
        status,
        @intCast(header_count),
        end_stream,
    );
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
    const sent = try sentOrBlocked(runtime, request_ctx, ipc.ingress_channel.sendDescriptorPayload(
        control_fd,
        descriptor,
        payload,
        runtime.core.dispatch_recv_scratch,
    ));
    switch (sent) {
        .sent => request_ctx.markResponseCommitted(),
        .blocked, .last => {},
    }
    return sent;
}

/// Sends a head that ends the stream with the request's `request_done`, and
/// commits the response once it is sent.
fn sendCarriedHead(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    head: ipc.ingress_channel.BatchEntry,
    carry: *done_carry.DoneCarry,
) !Sent {
    switch (try sendCarried(runtime, request_ctx, &.{head}, carry, 0)) {
        .sent => {},
        .socket_full, .ring_full => return .blocked,
    }
    request_ctx.markResponseCommitted();
    return .sent;
}

/// Sends the end of a streamed response, the response's last packet.
pub fn writeStreamEnd(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    ending: Ending,
) !Sent {
    const carry = switch (ending) {
        .hold => return .last,
        .carry => |carry| carry,
    };
    const descriptor = ipc.ingress_channel.Descriptor.responseEnd(h2Identity(request_ctx), request_ctx.ingress_channel_id);
    return switch (try sendCarried(runtime, request_ctx, &.{.{ .descriptor = descriptor }}, carry, 0)) {
        .sent => .sent,
        .socket_full, .ring_full => .blocked,
    };
}

/// Sends the reset of the response's stream with the HTTP/2 error code
/// `reset_code`, the response's last packet.
pub fn writeStreamReset(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    reset_code: u32,
    ending: Ending,
) !Sent {
    const carry = switch (ending) {
        .hold => return .last,
        .carry => |carry| carry,
    };
    const descriptor = ipc.ingress_channel.Descriptor.responseReset(h2Identity(request_ctx), request_ctx.ingress_channel_id, reset_code);
    return switch (try sendCarried(runtime, request_ctx, &.{.{ .descriptor = descriptor }}, carry, 0)) {
        .sent => .sent,
        .socket_full, .ring_full => .blocked,
    };
}

/// Sends the head and the first ring-sized chunks of `response_body` in one
/// batch, as many as the request's credit covers. Returns `.unbatched` when
/// the body is small, the ring is absent or has no room, no credit is left,
/// or the head does not fit the batch. A batch that covers the whole body
/// ends the response.
pub fn trySendInitialRingBatch(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    response: *const response_model.Response,
    response_body: []const u8,
    ending: Ending,
) !HeadBatch {
    const control_fd = runtime.core.control_fd orelse return error.InvalidArgument;
    const chunk_limit = try chunkLimit(runtime);
    if (response_body.len == 0 or chunk_limit <= ipc.ingress_channel.shared_payload_threshold)
        return .unbatched;
    const credit = request_ctx.response_credit.available();
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
    // The head and, when the batch ends the response, the `request_done`
    // take a descriptor each.
    while (probe_offset < response_body.len and chunk_count < @min(ipc.ingress_channel.max_batch_descriptors - 2, credit)) {
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
    const ends_response = probe_offset == response_body.len;
    if (ends_response and ending == .hold)
        return .last;

    const entry_count = chunk_count + 1;
    const batch_entry_count = if (ends_response) entry_count + 1 else entry_count;
    const batch_payload_offset = ipc.ingress_channel.batchPayloadOffset(batch_entry_count) catch return .unbatched;
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
    const done_len: usize = if (ends_response) @sizeOf(ipc.ingress_channel.RequestDonePayload) else 0;
    if (batch_payload_offset + head_payload.len + done_len > ipc.max_message_bytes)
        return .unbatched;

    const identity = h2Identity(request_ctx);
    var entries: [ipc.ingress_channel.max_batch_descriptors]ipc.ingress_channel.BatchEntry = undefined;
    entries[0] = .{
        .descriptor = headDescriptor(request_ctx, head_payload.len, response.status, response.headers.len, false),
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

    const ring_sent = if (ends_response)
        try sendCarried(runtime, request_ctx, entries[0..entry_count], ending.carry, body_offset)
    else
        try ringSentOrBlocked(runtime, request_ctx, ingress_payload, ipc.ingress_channel.sendDescriptorBatchPayloadsWithRing(
            control_fd,
            entries[0..entry_count],
            runtime.core.dispatch_recv_scratch,
            ingress_payload.writer(.worker_to_server),
        ));
    switch (ring_sent) {
        .sent => {},
        .socket_full => return .blocked,
        // Nothing went out; the head goes alone and the body follows it.
        .ring_full => return .unbatched,
    }
    request_ctx.response_credit.spend(chunk_count);
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

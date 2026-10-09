//! Encoders and decoders for the variable-length fetch messages between a
//! worker and the egress gateway, the views they produce and the decode
//! scratch each side owns. The fixed headers live in `messages.zig`, the size
//! bounds in `fetch_limits.zig`, and the packets travel through the shared
//! rings of `egress_shared.zig`. The worker encodes fetch starts and upload
//! batches on its event loop thread and decodes completions there; the
//! gateway decodes commands and encodes completions on its loop thread.
//!
//! The worker owns the `fetch_id` and `body_id` state JavaScript sees, and the
//! gateway owns sockets, DNS, TLS and protocol state, so a message carries ids,
//! lengths, pool handles and bytes, never a pointer. The worker is untrusted:
//! every decoder checks the kind, the reserved fields and flags, and every
//! length against the packet's size and any `fetch_limits` bound before it
//! slices anything. A fetch start carries the request's egress token, its only
//! identity at the gateway; the codec refuses `egress_token.none` on both
//! sides and reads no other byte of a token, which only `egress_token.verify`
//! judges.
//!
//! A decoded view borrows twice: its strings point into the packet bytes, and
//! its header and chunk arrays into the decoder's scratch. It stays valid
//! until either is reused, so a handler copies what it keeps before the next
//! packet is read or the next message of the same kind is decoded.
//!
//! An encoder writes into the caller's `out` and returns the used prefix. It
//! fails with `error.EgressIpcScratchTooSmall` when the message is larger than
//! `out`, or a field or the whole packet exceeds its `fetch_limits` bound, and
//! with `error.InvalidEgressPacket` when the view cannot be represented. A
//! decoder fails with `error.ShortRead` when a fetch start, fetch head, chunk
//! batch or fetch error is shorter than its header (a short cancel fails with
//! `error.InvalidEgressPacket`), with `error.InvalidMessageKind` on another
//! kind, and with `error.InvalidEgressPacket` on anything else malformed.

const std = @import("std");
const messages = @import("messages.zig");
const packet = @import("packet.zig");
const egress_shared = @import("egress_shared.zig");
const egress_token = @import("egress_token.zig");
const fetch_limits = @import("fetch_limits.zig");

const NameValuePacket = messages.NameValuePacket;
const RequestHeader = messages.RequestHeader;

// Decode scratch. Its chunk arrays hold a full packet's worth of descriptors,
// so a decoder never allocates. Each decoding owner (the worker's runtime
// core, the gateway's runtime) allocates one instance on the heap, holds it
// through a pointer because it is too large for a stack frame, and uses it
// from one thread. It is never a thread-local: that would put it in static
// TLS, which glibc creates for every thread the binary starts (the worker's
// sentinel and crypto pool, the gateway's connector threads, the server's
// ingress lanes), none of which decode egress packets, and carves out of each
// thread's stack, raising every thread's minimum stack size.

/// Landing area for decoded header pairs. Both sides need one: the gateway
/// decodes request headers and the worker decodes response headers.
pub const HeaderScratch = [messages.max_request_header_count]RequestHeader;

/// The worker's scratch. The worker decodes response heads and body chunk
/// batches and only produces upload batches, so it carries no upload array,
/// which at a full packet's size would sit unused in every worker.
pub const WorkerDecodeScratch = struct {
    name_values: HeaderScratch = undefined,
    body_chunks: [max_body_chunk_batch_count]BodyChunkView = undefined,
};

/// The gateway's scratch, the mirror of `WorkerDecodeScratch`: the gateway
/// decodes upload batches and only produces body chunk batches.
pub const GatewayDecodeScratch = struct {
    name_values: HeaderScratch = undefined,
    upload_chunks: [max_upload_chunk_batch_count]UploadChunkView = undefined,
};

comptime {
    std.debug.assert(fetch_limits.request_packet_bytes_max == egress_shared.max_packet_bytes);
    std.debug.assert(fetch_limits.request_start_header_bytes == @sizeOf(messages.EgressFetchStartHeader));
}

/// The first command of a fetch, as `messages.EgressFetchStartHeader` and the
/// fields after it carry it.
pub const FetchStartView = struct {
    fetch_id: u64,
    /// The request's token. The decoder copies it out of the packet with the header, so the
    /// gateway verifies bytes the worker can no longer change.
    egress_token: egress_token.Bytes,
    body_id: u64,
    flags: u32 = 0,
    max_body_bytes: u64 = 0,
    method: []const u8,
    url: []const u8,
    headers: []const RequestHeader,
    /// Inline body bytes; empty when `messages.egress_fetch_start_flag_body_pooled`
    /// is set.
    body: []const u8,
    /// Request-body bytes that will arrive as upload-pool extents, nonzero
    /// exactly when `messages.egress_fetch_start_flag_body_pooled` is set.
    pooled_body_len: u64 = 0,
};

pub const FetchHeadView = struct {
    fetch_id: u64,
    body_id: u64,
    flags: u32 = 0,
    status: u16,
    /// Coding of the body bytes in the pool; `messages.BodyEncoding` says why
    /// the worker reads the pool by this field alone.
    body_encoding: messages.BodyEncoding = .identity,
    /// Bounds the worker applies while it decodes a non-identity body.
    max_decoded_body_bytes: u64 = 0,
    max_pending_decoded_bytes: u64 = 0,
    max_decoded_to_encoded_ratio: u64 = 0,
    status_text: []const u8,
    url: []const u8,
    headers: []const RequestHeader,
    /// The gateway's publish stamp, as `messages.EgressFetchHeadHeader.ready_at_mono_ns`
    /// defines it.
    ready_at_mono_ns: u64 = 0,
};

pub const BodyChunkView = struct {
    fetch_id: u64,
    body_id: u64,
    /// The extent's body-pool handle (`egress_shared.BodyPoolHandle`).
    body_pool_offset: u64,
    /// Bytes as placed in the pool, in the coding the head's `body_encoding`
    /// names.
    len: usize,
    /// The fetch's cumulative byte meters, as
    /// `messages.EgressBodyChunkBatchDescriptor` describes them.
    billed_sent_total: u64 = 0,
    billed_received_total: u64 = 0,
    cost_total: u64 = 0,
    /// The batch's publish stamp. It travels in the batch header, so the
    /// decoder copies it into every chunk and the encoder ignores this field
    /// in favor of `BodyChunkBatchView.ready_at_mono_ns`.
    ready_at_mono_ns: u64 = 0,
};

/// The most chunk descriptors a body chunk batch can hold: as many as fit in
/// a `messages.max_message_bytes` packet after the batch header.
pub const max_body_chunk_batch_count: usize =
    (messages.max_message_bytes - @sizeOf(messages.EgressBodyChunkBatchHeader)) /
    @sizeOf(messages.EgressBodyChunkBatchDescriptor);

pub const BodyChunkBatchView = struct {
    chunks: []const BodyChunkView,
    /// The publish stamp of every chunk in the batch, as
    /// `messages.EgressFetchHeadHeader.ready_at_mono_ns` defines it.
    ready_at_mono_ns: u64 = 0,
};

/// One request-body extent the worker placed in the upload pool, as
/// `messages.EgressUploadChunkBatchDescriptor` carries it.
pub const UploadChunkView = struct {
    fetch_id: u64,
    /// The extent's upload-pool handle (`egress_shared.BodyPoolHandle`).
    upload_pool_offset: u64,
    len: usize,
    /// Request-body bytes through this extent.
    body_bytes_total: u64,
};

/// The most extent descriptors an upload chunk batch can hold: as many as fit
/// in a `messages.max_message_bytes` packet after the batch header.
pub const max_upload_chunk_batch_count: usize =
    (messages.max_message_bytes - @sizeOf(messages.EgressUploadChunkBatchHeader)) /
    @sizeOf(messages.EgressUploadChunkBatchDescriptor);

pub const UploadChunkBatchView = struct {
    chunks: []const UploadChunkView,
};

pub const BodyEndView = struct {
    fetch_id: u64,
    body_id: u64,
    /// The fetch's cumulative byte meters.
    billed_sent_total: u64 = 0,
    billed_received_total: u64 = 0,
    cost_total: u64 = 0,
    /// The gateway's publish stamp, as `messages.EgressFetchHeadHeader.ready_at_mono_ns`
    /// defines it.
    ready_at_mono_ns: u64 = 0,
};

pub const FetchErrorView = struct {
    fetch_id: u64,
    body_id: u64,
    message: []const u8,
    /// The fetch's cumulative byte meters.
    billed_sent_total: u64 = 0,
    billed_received_total: u64 = 0,
    cost_total: u64 = 0,
    /// The gateway's publish stamp, as `messages.EgressFetchHeadHeader.ready_at_mono_ns`
    /// defines it.
    ready_at_mono_ns: u64 = 0,
};

pub const AbortAckView = struct {
    fetch_id: u64,
    body_id: u64,
};

pub fn decodeReleaseBody(bytes: []const u8) !messages.EgressReleaseBody {
    if (bytes.len != @sizeOf(messages.EgressReleaseBody))
        return error.InvalidEgressPacket;
    const message = packet.readStruct(messages.EgressReleaseBody, bytes);
    if (try messages.decodeMessageKind(message.kind) != .egress_release_body)
        return error.InvalidMessageKind;
    if (message._reserved0 != 0)
        return error.InvalidEgressPacket;
    return message;
}

/// Checks a cancel and returns its header; the `reason_len` bytes of reason
/// text follow it in `bytes`.
pub fn decodeCancel(bytes: []const u8) !messages.EgressCancel {
    if (bytes.len < @sizeOf(messages.EgressCancel))
        return error.InvalidEgressPacket;
    const message = packet.readStruct(messages.EgressCancel, bytes[0..@sizeOf(messages.EgressCancel)]);
    if (try messages.decodeMessageKind(message.kind) != .egress_cancel)
        return error.InvalidMessageKind;
    const reason_len: usize = @intCast(message.reason_len);
    const expected_len = try std.math.add(usize, @sizeOf(messages.EgressCancel), reason_len);
    if (expected_len != bytes.len)
        return error.InvalidEgressPacket;
    return message;
}

/// Encodes a fetch start. A pooled start carries no inline body and sends
/// `pooled_body_len`, the total the upload batches will deliver, as its
/// `body_len`. A view whose token is `egress_token.none`, whose body fields
/// disagree with its pooled flag, or whose pooled length exceeds
/// `fetch_limits.request_body_pooled_bytes_max`, fails with
/// `error.InvalidEgressPacket`.
pub fn encodeFetchStartInto(out: []u8, view: FetchStartView) ![]u8 {
    if (egress_token.isNone(&view.egress_token))
        return error.InvalidEgressPacket;
    const body_pooled = (view.flags & messages.egress_fetch_start_flag_body_pooled) != 0;
    if (body_pooled) {
        if (view.body.len != 0 or view.pooled_body_len == 0 or
            view.pooled_body_len > fetch_limits.request_body_pooled_bytes_max)
            return error.InvalidEgressPacket;
    } else if (view.pooled_body_len != 0) {
        return error.InvalidEgressPacket;
    }
    const header_bytes_len = try nameValueStorageLen(view.headers);
    if (view.method.len > fetch_limits.request_method_bytes_max or
        view.url.len > fetch_limits.request_url_bytes_max or
        header_bytes_len > fetch_limits.request_headers_bytes_max or
        view.body.len > fetch_limits.request_body_inline_bytes_max)
    {
        return error.EgressIpcScratchTooSmall;
    }

    const needed = try checkedAddMany(&.{
        @sizeOf(messages.EgressFetchStartHeader),
        view.method.len,
        view.url.len,
        header_bytes_len,
        view.body.len,
    });
    if (needed > fetch_limits.request_packet_bytes_max)
        return error.EgressIpcScratchTooSmall;
    if (needed > out.len)
        return error.EgressIpcScratchTooSmall;
    if (view.method.len > std.math.maxInt(u32) or view.url.len > std.math.maxInt(u32) or
        header_bytes_len > std.math.maxInt(u32) or view.headers.len > messages.max_request_header_count)
        return error.InvalidEgressPacket;

    const header = messages.EgressFetchStartHeader{
        .kind = @intFromEnum(messages.MessageKind.egress_fetch_start),
        .flags = view.flags,
        .fetch_id = view.fetch_id,
        .body_id = view.body_id,
        .max_body_bytes = view.max_body_bytes,
        .method_len = @intCast(view.method.len),
        .url_len = @intCast(view.url.len),
        .request_header_count = @intCast(view.headers.len),
        .request_headers_bytes_len = @intCast(header_bytes_len),
        .body_len = if (body_pooled) view.pooled_body_len else @intCast(view.body.len),
        .egress_token = view.egress_token,
    };
    var cursor: usize = 0;
    writeStruct(out, &cursor, messages.EgressFetchStartHeader, header);
    writeBytes(out, &cursor, view.method);
    writeBytes(out, &cursor, view.url);
    writeNameValues(out, &cursor, view.headers);
    writeBytes(out, &cursor, view.body);
    std.debug.assert(cursor == needed);
    return out[0..cursor];
}

/// Decodes a fetch start; the view's headers land in `scratch`. A start
/// whose token is `egress_token.none` fails with `error.InvalidEgressPacket`.
pub fn decodeFetchStart(scratch: *GatewayDecodeScratch, bytes: []const u8) !FetchStartView {
    if (bytes.len < @sizeOf(messages.EgressFetchStartHeader))
        return error.ShortRead;
    const header = packet.readStruct(messages.EgressFetchStartHeader, bytes[0..@sizeOf(messages.EgressFetchStartHeader)]);
    if (try messages.decodeMessageKind(header.kind) != .egress_fetch_start)
        return error.InvalidMessageKind;
    if ((header.flags & ~messages.valid_egress_fetch_start_flags) != 0)
        return error.InvalidEgressPacket;
    // `none` names no request, and a worker refuses such a fetch before it
    // encodes one. The token's other bytes stay unread here, because a check
    // before `egress_token.verify` would tell a forger which field it got
    // wrong.
    if (egress_token.isNone(&header.egress_token))
        return error.InvalidEgressPacket;
    if (header.request_header_count > messages.max_request_header_count)
        return error.InvalidEgressPacket;
    const body_pooled = (header.flags & messages.egress_fetch_start_flag_body_pooled) != 0;
    if (header.method_len > fetch_limits.request_method_bytes_max or
        header.url_len > fetch_limits.request_url_bytes_max or
        header.request_headers_bytes_len > fetch_limits.request_headers_bytes_max)
    {
        return error.InvalidEgressPacket;
    }
    // A pooled start's `body_len` is the announced upload total, so it is
    // bounded by the pooled limit rather than the inline one.
    if (body_pooled) {
        if (header.body_len == 0 or header.body_len > fetch_limits.request_body_pooled_bytes_max)
            return error.InvalidEgressPacket;
    } else if (header.body_len > fetch_limits.request_body_inline_bytes_max) {
        return error.InvalidEgressPacket;
    }
    const inline_body_len: usize = if (body_pooled) 0 else @intCast(header.body_len);
    const total = try checkedAddMany(&.{
        @sizeOf(messages.EgressFetchStartHeader),
        @as(usize, @intCast(header.method_len)),
        @as(usize, @intCast(header.url_len)),
        @as(usize, @intCast(header.request_headers_bytes_len)),
        inline_body_len,
    });
    if (total != bytes.len)
        return error.InvalidEgressPacket;

    var cursor: usize = @sizeOf(messages.EgressFetchStartHeader);
    const method = take(bytes, &cursor, @intCast(header.method_len));
    const url = take(bytes, &cursor, @intCast(header.url_len));
    const header_bytes = take(bytes, &cursor, @intCast(header.request_headers_bytes_len));
    const headers = try decodeNameValues(&scratch.name_values, header_bytes, header.request_header_count);
    const body = take(bytes, &cursor, inline_body_len);
    return .{
        .fetch_id = header.fetch_id,
        .egress_token = header.egress_token,
        .body_id = header.body_id,
        .flags = header.flags,
        .max_body_bytes = header.max_body_bytes,
        .method = method,
        .url = url,
        .headers = headers,
        .body = body,
        .pooled_body_len = if (body_pooled) header.body_len else 0,
    };
}

pub fn encodeFetchHeadInto(out: []u8, view: FetchHeadView) ![]u8 {
    const header_bytes_len = try nameValueStorageLen(view.headers);
    if (view.status_text.len > fetch_limits.response_status_text_bytes_max or
        view.url.len > fetch_limits.response_url_bytes_max or
        header_bytes_len > fetch_limits.response_headers_bytes_max)
    {
        return error.EgressIpcScratchTooSmall;
    }
    const needed = try checkedAddMany(&.{
        @sizeOf(messages.EgressFetchHeadHeader),
        view.status_text.len,
        view.url.len,
        header_bytes_len,
    });
    if (needed > out.len)
        return error.EgressIpcScratchTooSmall;
    if (view.status_text.len > std.math.maxInt(u32) or view.url.len > std.math.maxInt(u32) or
        header_bytes_len > std.math.maxInt(u32) or view.headers.len > messages.max_request_header_count)
        return error.InvalidEgressPacket;

    const header = messages.EgressFetchHeadHeader{
        .kind = @intFromEnum(messages.MessageKind.egress_fetch_head),
        .flags = view.flags,
        .fetch_id = view.fetch_id,
        .body_id = view.body_id,
        .status = view.status,
        .body_encoding = @intFromEnum(view.body_encoding),
        ._reserved0 = 0,
        .max_decoded_body_bytes = view.max_decoded_body_bytes,
        .max_pending_decoded_bytes = view.max_pending_decoded_bytes,
        .max_decoded_to_encoded_ratio = view.max_decoded_to_encoded_ratio,
        .status_text_len = @intCast(view.status_text.len),
        .url_len = @intCast(view.url.len),
        .response_header_count = @intCast(view.headers.len),
        .response_headers_bytes_len = @intCast(header_bytes_len),
        .ready_at_mono_ns = view.ready_at_mono_ns,
    };
    var cursor: usize = 0;
    writeStruct(out, &cursor, messages.EgressFetchHeadHeader, header);
    writeBytes(out, &cursor, view.status_text);
    writeBytes(out, &cursor, view.url);
    writeNameValues(out, &cursor, view.headers);
    return out[0..cursor];
}

/// Decodes a fetch head; the view's headers land in `scratch`.
pub fn decodeFetchHead(scratch: *WorkerDecodeScratch, bytes: []const u8) !FetchHeadView {
    if (bytes.len < @sizeOf(messages.EgressFetchHeadHeader))
        return error.ShortRead;
    const header = packet.readStruct(messages.EgressFetchHeadHeader, bytes[0..@sizeOf(messages.EgressFetchHeadHeader)]);
    if (try messages.decodeMessageKind(header.kind) != .egress_fetch_head)
        return error.InvalidMessageKind;
    if ((header.flags & ~messages.valid_egress_fetch_head_flags) != 0)
        return error.InvalidEgressPacket;
    if (header._reserved0 != 0)
        return error.InvalidEgressPacket;
    const body_encoding = std.meta.intToEnum(messages.BodyEncoding, header.body_encoding) catch
        return error.InvalidEgressPacket;
    if (header.status_text_len > fetch_limits.response_status_text_bytes_max or
        header.url_len > fetch_limits.response_url_bytes_max or
        header.response_headers_bytes_len > fetch_limits.response_headers_bytes_max)
    {
        return error.InvalidEgressPacket;
    }
    const total = try checkedAddMany(&.{
        @sizeOf(messages.EgressFetchHeadHeader),
        @as(usize, @intCast(header.status_text_len)),
        @as(usize, @intCast(header.url_len)),
        @as(usize, @intCast(header.response_headers_bytes_len)),
    });
    if (total != bytes.len or header.response_header_count > messages.max_request_header_count)
        return error.InvalidEgressPacket;
    var cursor: usize = @sizeOf(messages.EgressFetchHeadHeader);
    const status_text = take(bytes, &cursor, @intCast(header.status_text_len));
    const url = take(bytes, &cursor, @intCast(header.url_len));
    const header_bytes = take(bytes, &cursor, @intCast(header.response_headers_bytes_len));
    const headers = try decodeNameValues(&scratch.name_values, header_bytes, header.response_header_count);
    return .{
        .fetch_id = header.fetch_id,
        .body_id = header.body_id,
        .flags = header.flags,
        .status = header.status,
        .body_encoding = body_encoding,
        .max_decoded_body_bytes = header.max_decoded_body_bytes,
        .max_pending_decoded_bytes = header.max_pending_decoded_bytes,
        .max_decoded_to_encoded_ratio = header.max_decoded_to_encoded_ratio,
        .status_text = status_text,
        .url = url,
        .headers = headers,
        .ready_at_mono_ns = header.ready_at_mono_ns,
    };
}

/// Encodes a batch of at least one chunk; an empty chunk fails with
/// `error.InvalidEgressPacket`.
pub fn encodeBodyChunkBatchInto(out: []u8, view: BodyChunkBatchView) ![]u8 {
    if (view.chunks.len == 0 or view.chunks.len > std.math.maxInt(u32))
        return error.InvalidEgressPacket;
    const descriptors_len = try std.math.mul(usize, view.chunks.len, @sizeOf(messages.EgressBodyChunkBatchDescriptor));
    const needed = try std.math.add(usize, @sizeOf(messages.EgressBodyChunkBatchHeader), descriptors_len);
    if (needed > out.len)
        return error.EgressIpcScratchTooSmall;

    const header = messages.EgressBodyChunkBatchHeader{
        .kind = @intFromEnum(messages.MessageKind.egress_body_chunk_batch),
        .count = @intCast(view.chunks.len),
        .ready_at_mono_ns = view.ready_at_mono_ns,
    };
    var cursor: usize = 0;
    writeStruct(out, &cursor, messages.EgressBodyChunkBatchHeader, header);
    for (view.chunks) |chunk| {
        if (chunk.len == 0 or chunk.len > std.math.maxInt(u32))
            return error.InvalidEgressPacket;
        writeStruct(out, &cursor, messages.EgressBodyChunkBatchDescriptor, .{
            .fetch_id = chunk.fetch_id,
            .body_id = chunk.body_id,
            .len = @intCast(chunk.len),
            .body_pool_offset = chunk.body_pool_offset,
            .billed_sent_total = chunk.billed_sent_total,
            .billed_received_total = chunk.billed_received_total,
            .cost_total = chunk.cost_total,
        });
    }
    std.debug.assert(cursor == needed);
    return out[0..cursor];
}

pub fn decodeBodyEnd(bytes: []const u8) !BodyEndView {
    if (bytes.len != @sizeOf(messages.EgressBodyEnd))
        return error.InvalidEgressPacket;
    const message = packet.readStruct(messages.EgressBodyEnd, bytes);
    if (try messages.decodeMessageKind(message.kind) != .egress_body_end)
        return error.InvalidMessageKind;
    if (message._reserved0 != 0)
        return error.InvalidEgressPacket;
    return .{
        .fetch_id = message.fetch_id,
        .body_id = message.body_id,
        .billed_sent_total = message.billed_sent_total,
        .billed_received_total = message.billed_received_total,
        .cost_total = message.cost_total,
        .ready_at_mono_ns = message.ready_at_mono_ns,
    };
}

/// Decodes a body chunk batch into `scratch` and returns its chunks. The
/// handles are not checked here; the worker checks each against its body
/// pool before it reads the extent.
pub fn decodeBodyChunkBatch(scratch: *WorkerDecodeScratch, bytes: []const u8) ![]const BodyChunkView {
    if (bytes.len < @sizeOf(messages.EgressBodyChunkBatchHeader))
        return error.ShortRead;
    const header = packet.readStruct(messages.EgressBodyChunkBatchHeader, bytes[0..@sizeOf(messages.EgressBodyChunkBatchHeader)]);
    if (try messages.decodeMessageKind(header.kind) != .egress_body_chunk_batch)
        return error.InvalidMessageKind;
    if (header.count == 0)
        return error.InvalidEgressPacket;
    const count: usize = @intCast(header.count);
    const descriptors_len = try std.math.mul(usize, count, @sizeOf(messages.EgressBodyChunkBatchDescriptor));
    const expected_len = try std.math.add(usize, @sizeOf(messages.EgressBodyChunkBatchHeader), descriptors_len);
    if (bytes.len != expected_len)
        return error.InvalidEgressPacket;
    if (count > scratch.body_chunks.len)
        return error.InvalidEgressPacket;

    var cursor: usize = @sizeOf(messages.EgressBodyChunkBatchHeader);
    for (scratch.body_chunks[0..count]) |*out| {
        const descriptor = packet.readStruct(
            messages.EgressBodyChunkBatchDescriptor,
            bytes[cursor..][0..@sizeOf(messages.EgressBodyChunkBatchDescriptor)],
        );
        cursor += @sizeOf(messages.EgressBodyChunkBatchDescriptor);
        if (descriptor.len == 0 or descriptor._reserved0 != 0)
            return error.InvalidEgressPacket;
        out.* = .{
            .fetch_id = descriptor.fetch_id,
            .body_id = descriptor.body_id,
            .body_pool_offset = descriptor.body_pool_offset,
            .len = @intCast(descriptor.len),
            .billed_sent_total = descriptor.billed_sent_total,
            .billed_received_total = descriptor.billed_received_total,
            .cost_total = descriptor.cost_total,
            .ready_at_mono_ns = header.ready_at_mono_ns,
        };
    }
    return scratch.body_chunks[0..count];
}

/// Encodes a batch of at least one extent; an empty extent fails with
/// `error.InvalidEgressPacket`.
pub fn encodeUploadChunkBatchInto(out: []u8, view: UploadChunkBatchView) ![]u8 {
    if (view.chunks.len == 0 or view.chunks.len > std.math.maxInt(u32))
        return error.InvalidEgressPacket;
    const descriptors_len = try std.math.mul(usize, view.chunks.len, @sizeOf(messages.EgressUploadChunkBatchDescriptor));
    const needed = try std.math.add(usize, @sizeOf(messages.EgressUploadChunkBatchHeader), descriptors_len);
    if (needed > out.len)
        return error.EgressIpcScratchTooSmall;

    const header = messages.EgressUploadChunkBatchHeader{
        .kind = @intFromEnum(messages.MessageKind.egress_upload_chunk_batch),
        .count = @intCast(view.chunks.len),
    };
    var cursor: usize = 0;
    writeStruct(out, &cursor, messages.EgressUploadChunkBatchHeader, header);
    for (view.chunks) |chunk| {
        if (chunk.len == 0 or chunk.len > std.math.maxInt(u32))
            return error.InvalidEgressPacket;
        writeStruct(out, &cursor, messages.EgressUploadChunkBatchDescriptor, .{
            .fetch_id = chunk.fetch_id,
            .len = @intCast(chunk.len),
            .upload_pool_offset = chunk.upload_pool_offset,
            .body_bytes_total = chunk.body_bytes_total,
        });
    }
    std.debug.assert(cursor == needed);
    return out[0..cursor];
}

/// Decodes an upload chunk batch into `scratch` and returns its extents.
/// Neither the handles nor the running totals are checked here: the gateway
/// checks each handle against the upload pool and each total against the
/// bytes it has received for that fetch.
pub fn decodeUploadChunkBatch(scratch: *GatewayDecodeScratch, bytes: []const u8) ![]const UploadChunkView {
    if (bytes.len < @sizeOf(messages.EgressUploadChunkBatchHeader))
        return error.ShortRead;
    const header = packet.readStruct(messages.EgressUploadChunkBatchHeader, bytes[0..@sizeOf(messages.EgressUploadChunkBatchHeader)]);
    if (try messages.decodeMessageKind(header.kind) != .egress_upload_chunk_batch)
        return error.InvalidMessageKind;
    if (header.count == 0)
        return error.InvalidEgressPacket;
    const count: usize = @intCast(header.count);
    const descriptors_len = try std.math.mul(usize, count, @sizeOf(messages.EgressUploadChunkBatchDescriptor));
    const expected_len = try std.math.add(usize, @sizeOf(messages.EgressUploadChunkBatchHeader), descriptors_len);
    if (bytes.len != expected_len)
        return error.InvalidEgressPacket;
    if (count > scratch.upload_chunks.len)
        return error.InvalidEgressPacket;

    var cursor: usize = @sizeOf(messages.EgressUploadChunkBatchHeader);
    for (scratch.upload_chunks[0..count]) |*out| {
        const descriptor = packet.readStruct(
            messages.EgressUploadChunkBatchDescriptor,
            bytes[cursor..][0..@sizeOf(messages.EgressUploadChunkBatchDescriptor)],
        );
        cursor += @sizeOf(messages.EgressUploadChunkBatchDescriptor);
        if (descriptor.len == 0 or descriptor._reserved0 != 0)
            return error.InvalidEgressPacket;
        out.* = .{
            .fetch_id = descriptor.fetch_id,
            .upload_pool_offset = descriptor.upload_pool_offset,
            .len = @intCast(descriptor.len),
            .body_bytes_total = descriptor.body_bytes_total,
        };
    }
    return scratch.upload_chunks[0..count];
}

pub fn encodeFetchErrorInto(out: []u8, view: FetchErrorView) ![]u8 {
    if (view.message.len > std.math.maxInt(u32))
        return error.InvalidEgressPacket;
    const needed = @sizeOf(messages.EgressFetchErrorHeader) + view.message.len;
    if (needed > out.len)
        return error.EgressIpcScratchTooSmall;
    const header = messages.EgressFetchErrorHeader{
        .kind = @intFromEnum(messages.MessageKind.egress_fetch_error),
        .message_len = @intCast(view.message.len),
        .fetch_id = view.fetch_id,
        .body_id = view.body_id,
        .billed_sent_total = view.billed_sent_total,
        .billed_received_total = view.billed_received_total,
        .cost_total = view.cost_total,
        .ready_at_mono_ns = view.ready_at_mono_ns,
    };
    var cursor: usize = 0;
    writeStruct(out, &cursor, messages.EgressFetchErrorHeader, header);
    writeBytes(out, &cursor, view.message);
    return out[0..cursor];
}

pub fn decodeFetchError(bytes: []const u8) !FetchErrorView {
    if (bytes.len < @sizeOf(messages.EgressFetchErrorHeader))
        return error.ShortRead;
    const header = packet.readStruct(messages.EgressFetchErrorHeader, bytes[0..@sizeOf(messages.EgressFetchErrorHeader)]);
    if (try messages.decodeMessageKind(header.kind) != .egress_fetch_error)
        return error.InvalidMessageKind;
    if (@sizeOf(messages.EgressFetchErrorHeader) + @as(usize, @intCast(header.message_len)) != bytes.len)
        return error.InvalidEgressPacket;
    var cursor: usize = @sizeOf(messages.EgressFetchErrorHeader);
    return .{
        .fetch_id = header.fetch_id,
        .body_id = header.body_id,
        .message = take(bytes, &cursor, @intCast(header.message_len)),
        .billed_sent_total = header.billed_sent_total,
        .billed_received_total = header.billed_received_total,
        .cost_total = header.cost_total,
        .ready_at_mono_ns = header.ready_at_mono_ns,
    };
}

pub fn decodeAbortAck(bytes: []const u8) !AbortAckView {
    if (bytes.len != @sizeOf(messages.EgressAbortAck))
        return error.InvalidEgressPacket;
    const message = packet.readStruct(messages.EgressAbortAck, bytes);
    if (try messages.decodeMessageKind(message.kind) != .egress_abort_ack)
        return error.InvalidMessageKind;
    if (message._reserved0 != 0)
        return error.InvalidEgressPacket;
    return .{
        .fetch_id = message.fetch_id,
        .body_id = message.body_id,
    };
}

fn nameValueStorageLen(headers: []const RequestHeader) !usize {
    var total: usize = 0;
    for (headers) |header| {
        if (header.name.len > std.math.maxInt(u32) or header.value.len > std.math.maxInt(u32))
            return error.InvalidEgressPacket;
        total = try std.math.add(usize, total, @sizeOf(NameValuePacket));
        total = try std.math.add(usize, total, header.name.len);
        total = try std.math.add(usize, total, header.value.len);
    }
    return total;
}

fn writeNameValues(out: []u8, cursor: *usize, headers: []const RequestHeader) void {
    for (headers) |header| {
        const meta = NameValuePacket{
            .name_len = @intCast(header.name.len),
            .value_len = @intCast(header.value.len),
        };
        writeStruct(out, cursor, NameValuePacket, meta);
        writeBytes(out, cursor, header.name);
        writeBytes(out, cursor, header.value);
    }
}

/// Decodes `count` name and value pairs that must fill `bytes` exactly. The
/// pairs land in `name_values` and their strings borrow `bytes`.
fn decodeNameValues(name_values: *HeaderScratch, bytes: []const u8, count: u32) ![]const RequestHeader {
    if (count > messages.max_request_header_count)
        return error.InvalidEgressPacket;
    var cursor: usize = 0;
    for (0..count) |index| {
        if (cursor + @sizeOf(NameValuePacket) > bytes.len)
            return error.InvalidEgressPacket;
        const meta = packet.readStruct(NameValuePacket, bytes[cursor..][0..@sizeOf(NameValuePacket)]);
        cursor += @sizeOf(NameValuePacket);
        const name = try takeChecked(bytes, &cursor, @intCast(meta.name_len));
        const value = try takeChecked(bytes, &cursor, @intCast(meta.value_len));
        name_values[index] = .{ .name = name, .value = value };
    }
    if (cursor != bytes.len)
        return error.InvalidEgressPacket;
    return name_values[0..count];
}

fn checkedAddMany(values: []const usize) !usize {
    var total: usize = 0;
    for (values) |value|
        total = try std.math.add(usize, total, value);
    return total;
}

fn writeStruct(out: []u8, cursor: *usize, comptime T: type, value: T) void {
    const bytes = std.mem.asBytes(&value);
    @memcpy(out[cursor.*..][0..bytes.len], bytes);
    cursor.* += bytes.len;
}

fn writeBytes(out: []u8, cursor: *usize, bytes: []const u8) void {
    @memcpy(out[cursor.*..][0..bytes.len], bytes);
    cursor.* += bytes.len;
}

fn take(bytes: []const u8, cursor: *usize, len: usize) []const u8 {
    const start = cursor.*;
    cursor.* += len;
    return bytes[start..cursor.*];
}

fn takeChecked(bytes: []const u8, cursor: *usize, len: usize) ![]const u8 {
    if (cursor.* > bytes.len or len > bytes.len - cursor.*)
        return error.InvalidEgressPacket;
    return take(bytes, cursor, len);
}

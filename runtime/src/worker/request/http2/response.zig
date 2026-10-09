//! Plans the ingress-channel descriptors of a response that fits one inline
//! batch: its head and a small body sent together in one packet. Pure: it
//! encodes into the caller's scratch and sends nothing.

const std = @import("std");
const ipc = @import("collo_ipc");

/// Encodes the head and the whole body as two batch entries into
/// `out_entries`, with the head payload in `scratch`. Returns null when the
/// body is empty or larger than `small_body_batch_limit`, or when the batch
/// would not fit `scratch` or one message; the caller then sends the
/// response on the streaming path. The returned entries borrow `scratch`,
/// `body` and `out_entries`. Fails with `error.MessageTooLarge` only for a
/// head that no packet can encode.
pub fn tryEncodeInlineHeadBodyBatch(
    scratch: []u8,
    identity: ipc.ingress_channel.RequestIdentity,
    stream_id: u32,
    status: u16,
    headers: []const ipc.ingress_channel.ResponseHeader,
    body: []const u8,
    small_body_batch_limit: usize,
    out_entries: *[2]ipc.ingress_channel.BatchEntry,
) !?[]const ipc.ingress_channel.BatchEntry {
    if (body.len == 0 or body.len > small_body_batch_limit)
        return null;

    const batch_payload_offset = ipc.ingress_channel.batchPayloadOffset(2) catch return null;
    if (scratch.len <= batch_payload_offset)
        return null;

    const head_payload = ipc.ingress_channel.encodeResponseHeadInto(
        scratch[batch_payload_offset..],
        status,
        headers,
    ) catch |err| switch (err) {
        error.DispatchScratchTooSmall => return null,
        else => return err,
    };
    const batch_len = std.math.add(usize, batch_payload_offset, head_payload.len) catch return error.MessageTooLarge;
    const total_len = std.math.add(usize, batch_len, body.len) catch return error.MessageTooLarge;
    if (total_len > scratch.len or total_len > ipc.max_message_bytes)
        return null;

    out_entries[0] = .{
        .descriptor = ipc.ingress_channel.Descriptor.responseHead(
            identity,
            stream_id,
            0,
            @intCast(head_payload.len),
            status,
            @intCast(headers.len),
            false,
        ),
        .payload = head_payload,
    };
    out_entries[1] = .{
        .descriptor = ipc.ingress_channel.Descriptor.responseChunk(
            identity,
            stream_id,
            0,
            @intCast(body.len),
            true,
        ),
        .payload = body,
    };
    return out_entries;
}

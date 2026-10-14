//! The fetch codec's rules that `common/ipc/egress.zig` adds over the wire
//! structs: the one fixed-size stop and its decoder, the start bounds with an
//! error of their own each, which the worker checks before it copies a start
//! and the encoder applies again, and the body chunk batch bounded by the
//! body pool's slots. The other codec cases are in `common/tests/ipc.zig`.

const std = @import("std");
const ipc = @import("collo_ipc");

const egress = ipc.egress;

test "a stop is one fixed-size command naming its fetch, and the decoder refuses any other shape" {
    const stop = ipc.EgressStop.init(11);
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(ipc.EgressStop));
    try std.testing.expectEqual(@as(u64, 11), try egress.decodeStop(std.mem.asBytes(&stop)));

    var reserved = stop;
    reserved._reserved0 = 1;
    try std.testing.expectError(error.InvalidEgressPacket, egress.decodeStop(std.mem.asBytes(&reserved)));
    try std.testing.expectError(
        error.InvalidEgressPacket,
        egress.decodeStop(std.mem.asBytes(&stop)[0 .. @sizeOf(ipc.EgressStop) - 1]),
    );
    var other_kind = stop;
    other_kind.kind = @intFromEnum(ipc.MessageKind.egress_abort_ack);
    try std.testing.expectError(error.InvalidMessageKind, egress.decodeStop(std.mem.asBytes(&other_kind)));
}

test "each start bound has its own error, and the encoder refuses the starts the check refuses" {
    const limits = ipc.fetch_limits;
    const fits: egress.FetchStartShape = .{
        .method_len = limits.request_method_bytes_max,
        .url_len = limits.request_url_bytes_max,
        .header_count = 1,
        .header_bytes = limits.request_headers_bytes_max - @sizeOf(ipc.messages.NameValuePacket),
        .body_len = limits.request_body_pooled_bytes_max,
    };
    try egress.checkFetchStart(fits);

    var method = fits;
    method.method_len += 1;
    try std.testing.expectError(error.EgressGatewayRequestMethodLimitExceeded, egress.checkFetchStart(method));
    var url = fits;
    url.url_len += 1;
    try std.testing.expectError(error.EgressGatewayRequestUrlLimitExceeded, egress.checkFetchStart(url));
    var count = fits;
    count.header_count = ipc.max_request_header_count + 1;
    count.header_bytes = 0;
    try std.testing.expectError(error.TooManyFetchHeaders, egress.checkFetchStart(count));
    // The framing each header takes in the packet counts against the bound.
    var framing = fits;
    framing.header_count = 2;
    try std.testing.expectError(error.EgressGatewayRequestHeaderLimitExceeded, egress.checkFetchStart(framing));
    var body = fits;
    body.body_len += 1;
    try std.testing.expectError(error.EgressGatewayRequestBodyLimitExceeded, egress.checkFetchStart(body));

    var scratch: [512]u8 = undefined;
    const token: ipc.egress_token.Bytes = @splat(1);
    const long_method = "M" ** (limits.request_method_bytes_max + 1);
    try std.testing.expectError(error.EgressGatewayRequestMethodLimitExceeded, egress.encodeFetchStartInto(&scratch, .{
        .fetch_id = 1,
        .egress_token = token,
        .body_id = 2,
        .method = long_method,
        .url = "https://example.test/",
        .headers = &.{},
        .body = "",
    }));
}

test "a body chunk batch holds at most one descriptor per body pool slot, on both ends" {
    try std.testing.expectEqual(ipc.egress_shared.body_pool_slot_count, egress.max_body_chunk_batch_count);
    const chunks = try std.testing.allocator.alloc(egress.BodyChunkView, egress.max_body_chunk_batch_count + 1);
    defer std.testing.allocator.free(chunks);
    for (chunks, 0..) |*chunk, index|
        chunk.* = .{ .fetch_id = 1, .body_id = 2, .body_pool_offset = index, .len = 1 };
    const out = try std.testing.allocator.alloc(u8, ipc.max_message_bytes);
    defer std.testing.allocator.free(out);

    try std.testing.expectError(error.InvalidEgressPacket, egress.encodeBodyChunkBatchInto(out, .{ .chunks = chunks }));
    const full = try egress.encodeBodyChunkBatchInto(out, .{ .chunks = chunks[0..egress.max_body_chunk_batch_count] });
    const scratch = try std.testing.allocator.create(egress.WorkerDecodeScratch);
    defer std.testing.allocator.destroy(scratch);
    try std.testing.expectEqual(egress.max_body_chunk_batch_count, (try egress.decodeBodyChunkBatch(scratch, full)).len);

    // One descriptor more than the slots, written by hand over the full batch, is refused.
    const descriptor_bytes = @sizeOf(ipc.messages.EgressBodyChunkBatchDescriptor);
    const too_many = out[0 .. full.len + descriptor_bytes];
    @memcpy(too_many[full.len..], full[full.len - descriptor_bytes ..]);
    const count: u32 = @intCast(egress.max_body_chunk_batch_count + 1);
    @memcpy(too_many[@offsetOf(ipc.messages.EgressBodyChunkBatchHeader, "count")..][0..@sizeOf(u32)], std.mem.asBytes(&count));
    try std.testing.expectError(error.InvalidEgressPacket, egress.decodeBodyChunkBatch(scratch, too_many));
}

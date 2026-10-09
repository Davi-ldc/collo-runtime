//! The ingress HTTP/2 connection driver (`server/ingress/http2/connection.zig`
//! with `reading.zig` and `writing.zig`) and the per-connection stream state
//! it drives (`server/ingress/runner/connection_slot.zig` with
//! `stream_table.zig`, `flow_control.zig` and `write_queue.zig`). The driver
//! reads from a socket pair and calls `TestWorker`, which stands in for the
//! lane: its stream handlers (`server/ingress/runner/admission.zig` and
//! `request_body.zig`), which return only the errors a stream handler may
//! return (`server/ingress/fault.zig`), and its decision to close a
//! connection, which `closeRuntimeConnection` in
//! `server/ingress/runner/connection_flow.zig` takes. `driveUntilIdle` then
//! writes out the queue the close left, as the lane's next pass does.
//! No lane thread or worker process runs, so the rest of a close, which
//! resets the connection's streams toward their workers and tears the
//! connection down, stays outside this suite.
//!
//! The tests cover request-body and flow-control accounting, header blocks,
//! the bound on a request head's fields and the HPACK state both ends keep
//! across a refused or dropped block, the interim 100 for
//! `expect: 100-continue`, the per-read frame budget against floods, the
//! concurrent-stream cap and the moment a stream leaves it, and the response
//! path: queueing behind flow control, worker response descriptors, the
//! lane's record of a worker's head, how a stream ends when its request
//! leaves it, framing and write buffers. A fault a client causes closes only
//! its connection, with GOAWAY when the HTTP/2 layer can still speak, and
//! `drive` returns without an error; a lane fault is the one error `drive`
//! returns. Root of the `h2-connection` suite, which runs with no engine in
//! `server-fast-test`, `h2-transport-test` and the `test` aggregate; how a
//! lane hands streams to workers is covered in `server/tests/ingress/`.

const std = @import("std");

const server_h2 = @import("collo_server_h2");
const fault = server_h2.fault;
const http2_connection = server_h2.http2.connection;
const http2_reading = server_h2.http2.reading;
const http2_writing = server_h2.http2.writing;
const connection_slot = server_h2.connection_slot;
const stream_table = server_h2.stream_table;
const flow_control = server_h2.flow_control;
const write_queue = server_h2.write_queue;
const h2_request = server_h2.http2.request_head;
const LaneResources = server_h2.http2.lane_resources.LaneResources;
const RequestKey = server_h2.lifecycle.RequestKey;
const h2 = @import("collo_http").http2;
const hpack = @import("collo_hpack");
const ipc = @import("collo_ipc");
const fd_mod = @import("collo_os").fd;
const limits = @import("collo_limits");

const DataFrameHandling = http2_connection.DataFrameHandling;
const Slot = connection_slot.Slot;
const drive = http2_connection.drive;
const queueResponseChunk = http2_writing.queueResponseChunk;
const queueResponseHeadAndChunk = http2_writing.queueResponseHeadAndChunk;
const queueWorkerResponseDescriptor = http2_writing.queueWorkerResponseDescriptor;
const tryQueueWorkerResponseHeadChunkPair = http2_writing.tryQueueWorkerResponseHeadChunkPair;
const flushPendingResponseData = http2_writing.flushPendingResponseData;
const encodeHeadersFrames = h2.encodeHeadersFrames;
const encodeDataFrames = h2.encodeDataFrames;
const encodeHeadersAndDataFrames = h2.encodeHeadersAndDataFrames;
const encodeRstStreamFrame = h2.encodeRstStreamFrame;
const encodeGoawayFrame = h2.encodeGoawayFrame;
const server_max_frame_size = limits.h2.INGRESS_MAX_FRAME_SIZE_BYTES;
const max_response_header_block_bytes: usize = 64 * 1024;

/// Streams the suite's lane holds at once, far above what its tests open.
const shared_stream_capacity: u32 = 1 << 14;

/// The lane every connection of this suite sits on: its read buffer, HPACK
/// scratch, header block budget and stream slab, which a lane's connections
/// share as they share its own (`http2/lane_resources.zig`). It is mapped on
/// first use and kept for the process. The tests run one at a time, and an
/// entry a test leaves in the slab starts from its defaults when it is
/// handed out again.
var shared_lane: LaneResources = undefined;
var shared_lane_mapped = false;

fn sharedLane() *LaneResources {
    if (!shared_lane_mapped) {
        shared_lane = LaneResources.init(shared_stream_capacity) catch |err|
            std.debug.panic("the suite's lane could not be mapped: {s}", .{@errorName(err)});
        shared_lane_mapped = true;
    }
    return &shared_lane;
}

/// A slot on the suite's lane holding no connection yet.
fn testSlot() Slot {
    return .{ .streams = &sharedLane().streams };
}

test "http2 request body accounting accepts exact multi-data body" {
    var runtime = testSlot();
    try runtime.h2ReserveStream(1);
    try runtime.h2SetRequestBodyExpectation(1, .ingress_channel, 5, false);

    try runtime.h2RecordRequestBodyChunk(1, 2, false);
    try runtime.h2RecordRequestBodyChunk(1, 3, true);
    try std.testing.expectError(error.Http2ProtocolError, runtime.h2RecordRequestBodyChunk(1, 0, true));
}

test "http2 request body accounting rejects oversize and early end stream" {
    var runtime = testSlot();
    try runtime.h2ReserveStream(1);
    try runtime.h2SetRequestBodyExpectation(1, .ingress_channel, 4, false);

    try runtime.h2RecordRequestBodyChunk(1, 3, false);
    try std.testing.expectError(error.Http2ContentLengthMismatch, runtime.h2RecordRequestBodyChunk(1, 2, false));
    try std.testing.expectError(error.Http2ContentLengthMismatch, runtime.h2RecordRequestBodyChunk(1, 0, true));
}

test "http2 request body accounting accepts unknown length until end stream" {
    var runtime = testSlot();
    try runtime.h2ReserveStream(1);
    try runtime.h2SetRequestBodyExpectation(1, .ingress_channel, null, false);

    try runtime.h2RecordRequestBodyChunk(1, 2, false);
    try runtime.h2RecordRequestBodyChunk(1, 3, true);
    try std.testing.expectError(error.Http2ProtocolError, runtime.h2RecordRequestBodyChunk(1, 1, false));
}

test "http2 inbound flow-control blocks data until consumed bytes restore window" {
    var runtime = testSlot();
    try runtime.h2ReserveStream(1);
    try runtime.h2SetRequestBodyExpectation(1, .ingress_channel, limits.h2.INGRESS_STREAM_RECV_WINDOW_BYTES + 1, false);

    try runtime.h2ConsumeInboundWindow(1, limits.h2.INGRESS_STREAM_RECV_WINDOW_BYTES);
    try std.testing.expectEqual(@as(i64, limits.h2.INGRESS_CONNECTION_RECV_WINDOW_BYTES - limits.h2.INGRESS_STREAM_RECV_WINDOW_BYTES), runtime.h2_connection_recv_window);
    try std.testing.expectEqual(@as(i64, 0), runtime.streamAt(0).recv_window);
    try std.testing.expectError(error.Http2FlowControlError, runtime.h2ConsumeInboundWindow(1, 1));

    try runtime.h2BufferInboundWindowUpdate(1, limits.h2.INGRESS_STREAM_RECV_WINDOW_BYTES);
    try runtime.h2ConsumeInboundWindow(1, 1);
    try std.testing.expectEqual(@as(i64, limits.h2.INGRESS_CONNECTION_RECV_WINDOW_BYTES - 1), runtime.h2_connection_recv_window);
    try std.testing.expectEqual(@as(i64, limits.h2.INGRESS_STREAM_RECV_WINDOW_BYTES - 1), runtime.streamAt(0).recv_window);
}

test "http2 inbound window updates coalesce per connection and stream" {
    var runtime = testSlot();
    try runtime.h2ReserveStream(1);
    try runtime.h2SetRequestBodyExpectation(1, .ingress_channel, 10, false);

    try runtime.h2ConsumeInboundWindow(1, 5);
    try runtime.h2BufferInboundWindowUpdate(1, 2);
    try runtime.h2BufferInboundWindowUpdate(1, 3);

    try std.testing.expectEqual(@as(i64, limits.h2.INGRESS_CONNECTION_RECV_WINDOW_BYTES), runtime.h2_connection_recv_window);
    try std.testing.expectEqual(@as(i64, limits.h2.INGRESS_STREAM_RECV_WINDOW_BYTES), runtime.streamAt(0).recv_window);
    try std.testing.expectEqual(@as(u32, 5), runtime.h2_pending_connection_window_update);
    try std.testing.expectEqual(@as(u32, 5), runtime.streamAt(0).pending_recv_window_update);
}

test "http2 inbound window update overflow leaves window state unchanged" {
    var runtime = testSlot();
    try runtime.h2ReserveStream(1);
    try runtime.h2SetRequestBodyExpectation(1, .ingress_channel, 1, false);
    try runtime.h2ConsumeInboundWindow(1, 1);

    const connection_window_before = runtime.h2_connection_recv_window;
    const stream_window_before = runtime.streamAt(0).recv_window;
    runtime.h2_pending_connection_window_update = std.math.maxInt(u32);
    try std.testing.expectError(error.Http2FlowControlError, runtime.h2BufferInboundWindowUpdate(1, 1));
    try std.testing.expectEqual(connection_window_before, runtime.h2_connection_recv_window);
    try std.testing.expectEqual(stream_window_before, runtime.streamAt(0).recv_window);
    try std.testing.expectEqual(std.math.maxInt(u32), runtime.h2_pending_connection_window_update);
    try std.testing.expectEqual(@as(u32, 0), runtime.streamAt(0).pending_recv_window_update);

    runtime.h2_pending_connection_window_update = 0;
    runtime.streamAt(0).pending_recv_window_update = std.math.maxInt(u32);
    try std.testing.expectError(error.Http2FlowControlError, runtime.h2BufferInboundWindowUpdate(1, 1));
    try std.testing.expectEqual(connection_window_before, runtime.h2_connection_recv_window);
    try std.testing.expectEqual(stream_window_before, runtime.streamAt(0).recv_window);
    try std.testing.expectEqual(@as(u32, 0), runtime.h2_pending_connection_window_update);
    try std.testing.expectEqual(std.math.maxInt(u32), runtime.streamAt(0).pending_recv_window_update);
}

test "http2 continuation header block grows amortized not exact per frame, and gives its charge back when taken" {
    const allocator = std.testing.allocator;
    var runtime = testSlot();
    defer runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    const budget = &shared_lane.header_blocks;
    const charged_before = budget.used;

    try runtime.h2BeginHeaderBlock(1, false, .request_headers);
    try runtime.h2AppendHeaderBlock(allocator, budget, "a");
    try runtime.h2CountHeaderBlockFrame();
    try runtime.h2AppendHeaderBlock(allocator, budget, "b");

    try std.testing.expectEqual(@as(usize, 2), runtime.h2_header_block_len);
    try std.testing.expect(runtime.h2_header_block.len > runtime.h2_header_block_len);
    try std.testing.expectEqual(charged_before + runtime.h2_header_block.len, budget.used);

    var block = runtime.h2TakeHeaderBlock(budget);
    defer block.deinit(allocator);
    try std.testing.expectEqualStrings("ab", block.bytes);
    try std.testing.expectEqual(charged_before, budget.used);
}

test "http2 header block append failure preserves accumulated block and its charge" {
    const allocator = std.testing.allocator;
    var runtime = testSlot();
    defer runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    const budget = &shared_lane.header_blocks;

    try runtime.h2BeginHeaderBlock(1, false, .request_headers);
    try runtime.h2AppendHeaderBlock(allocator, budget, "abc");
    const len_before = runtime.h2_header_block_len;
    const capacity_before = runtime.h2_header_block.len;
    const frame_count_before = runtime.h2_header_block_frame_count;
    const charged_before = budget.used;

    const payload = try allocator.alloc(u8, capacity_before + 1);
    defer allocator.free(payload);
    @memset(payload, 'd');

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        runtime.h2AppendHeaderBlock(failing.allocator(), budget, payload),
    );

    try std.testing.expectEqual(len_before, runtime.h2_header_block_len);
    try std.testing.expectEqual(capacity_before, runtime.h2_header_block.len);
    try std.testing.expectEqual(frame_count_before, runtime.h2_header_block_frame_count);
    try std.testing.expectEqual(charged_before, budget.used);
    try std.testing.expectEqualStrings("abc", runtime.h2_header_block[0..runtime.h2_header_block_len]);
}

test "http2 header block growth past the lane's budget fails and charges nothing" {
    const allocator = std.testing.allocator;
    var budget: server_h2.http2.lane_resources.HeaderBlockBudget = .{ .limit = 300 };
    var runtime = testSlot();
    defer runtime.deinitProtocolState(allocator, &budget);

    // A block's first growth takes 256 bytes; the next doubles it, past the
    // budget.
    try runtime.h2BeginHeaderBlock(1, false, .request_headers);
    try runtime.h2AppendHeaderBlock(allocator, &budget, "abc");
    try std.testing.expectEqual(@as(usize, 256), budget.used);
    var big: [300]u8 = @splat('x');
    try std.testing.expectError(
        error.Http2HeaderBlockBudgetExceeded,
        runtime.h2AppendHeaderBlock(allocator, &budget, &big),
    );
    try std.testing.expectEqual(@as(usize, 256), budget.used);
    try std.testing.expectEqual(@as(usize, 3), runtime.h2_header_block_len);
    runtime.h2ClearHeaderBlock(allocator, &budget);
    try std.testing.expectEqual(@as(usize, 0), budget.used);
}

test "http2 preparing body grows amortized and transfers exact used bytes" {
    const allocator = std.testing.allocator;
    var runtime = testSlot();
    defer runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);

    try runtime.h2ReserveStream(1);
    try runtime.h2SetRequestBodyExpectation(1, .ingress_channel, 6, false);
    try runtime.h2AppendPreparingBody(allocator, 1, "abc", false, 3);
    try runtime.h2AppendPreparingBody(allocator, 1, "def", true, 3);

    try std.testing.expectEqual(@as(usize, 6), runtime.streamAt(0).pending_body_len);
    try std.testing.expect(runtime.streamAt(0).pending_body.len > runtime.streamAt(0).pending_body_len);
    try std.testing.expectEqual(@as(usize, 6), runtime.h2_pending_body_bytes);

    var pending = runtime.h2TakePendingBody(1) orelse return error.MissingPendingBody;
    defer pending.deinit(allocator);
    try std.testing.expectEqualStrings("abcdef", pending.bytes);
    try std.testing.expect(pending.allocation.len >= pending.bytes.len);
    try std.testing.expect(pending.end_stream);
    try std.testing.expectEqual(@as(usize, 6), pending.window_credit_len);
    try std.testing.expectEqual(@as(usize, 0), runtime.streamAt(0).pending_body_len);
    try std.testing.expectEqual(@as(usize, 0), runtime.h2_pending_body_bytes);
}

test "http2 preparing body append failure preserves bytes and flow credit" {
    const allocator = std.testing.allocator;
    var runtime = testSlot();
    defer runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);

    try runtime.h2ReserveStream(1);
    try runtime.h2SetRequestBodyExpectation(1, .ingress_channel, 512, false);
    try runtime.h2AppendPreparingBody(allocator, 1, "abc", false, 3);

    const len_before = runtime.streamAt(0).pending_body_len;
    const capacity_before = runtime.streamAt(0).pending_body.len;
    const complete_before = runtime.streamAt(0).pending_body_complete;
    const credit_before = runtime.streamAt(0).pending_body_window_credit;
    const connection_pending_before = runtime.h2_pending_body_bytes;

    const payload = try allocator.alloc(u8, capacity_before + 1);
    defer allocator.free(payload);
    @memset(payload, 'd');

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        runtime.h2AppendPreparingBody(failing.allocator(), 1, payload, true, payload.len),
    );

    try std.testing.expectEqual(len_before, runtime.streamAt(0).pending_body_len);
    try std.testing.expectEqual(capacity_before, runtime.streamAt(0).pending_body.len);
    try std.testing.expectEqual(complete_before, runtime.streamAt(0).pending_body_complete);
    try std.testing.expectEqual(credit_before, runtime.streamAt(0).pending_body_window_credit);
    try std.testing.expectEqual(connection_pending_before, runtime.h2_pending_body_bytes);
    try std.testing.expectEqualStrings("abc", runtime.streamAt(0).pending_body[0..runtime.streamAt(0).pending_body_len]);
}

test "http2 preparing body credit overflow is transactional" {
    const allocator = std.testing.allocator;
    var runtime = testSlot();
    defer runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);

    try runtime.h2ReserveStream(1);
    try runtime.h2SetRequestBodyExpectation(1, .ingress_channel, 0, false);
    runtime.streamAt(0).pending_body_window_credit = std.math.maxInt(usize);

    try std.testing.expectError(
        error.Http2FlowControlError,
        runtime.h2AppendPreparingBody(allocator, 1, "", true, 1),
    );

    try std.testing.expect(!runtime.streamAt(0).pending_body_complete);
    try std.testing.expectEqual(std.math.maxInt(usize), runtime.streamAt(0).pending_body_window_credit);
    try std.testing.expectEqual(@as(usize, 0), runtime.streamAt(0).pending_body_len);
    try std.testing.expectEqual(@as(usize, 0), runtime.h2_pending_body_bytes);
}

test "http2 preparing body tracks flow-control credit separately from retained bytes" {
    const allocator = std.testing.allocator;
    var runtime = testSlot();
    defer runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);

    try runtime.h2ReserveStream(1);
    try runtime.h2SetRequestBodyExpectation(1, .ingress_channel, 3, false);
    try runtime.h2AppendPreparingBody(allocator, 1, "abc", true, 6);

    var pending = runtime.h2TakePendingBody(1) orelse return error.MissingPendingBody;
    defer pending.deinit(allocator);
    try std.testing.expectEqualStrings("abc", pending.bytes);
    try std.testing.expect(pending.end_stream);
    try std.testing.expectEqual(@as(usize, 6), pending.window_credit_len);
}

test "http2 taken pending body can restore connection credit on transfer failure" {
    const allocator = std.testing.allocator;
    var runtime = testSlot();
    defer runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);

    try runtime.h2ReserveStream(1);
    try runtime.h2SetRequestBodyExpectation(1, .ingress_channel, 3, false);
    try runtime.h2ConsumeInboundWindow(1, 6);
    try runtime.h2AppendPreparingBody(allocator, 1, "abc", true, 6);

    var pending = runtime.h2TakePendingBody(1) orelse return error.MissingPendingBody;
    defer pending.deinit(allocator);
    try runtime.h2RestoreTakenPendingBodyConnectionCredit(&pending);

    try std.testing.expectEqual(@as(usize, 0), pending.window_credit_len);
    try std.testing.expectEqual(limits.h2.INGRESS_CONNECTION_RECV_WINDOW_BYTES, runtime.h2_connection_recv_window);
    try std.testing.expectEqual(
        limits.h2.INGRESS_STREAM_RECV_WINDOW_BYTES - 6,
        runtime.streamAt(0).recv_window,
    );
    try std.testing.expectEqual(@as(u32, 6), runtime.h2_pending_connection_window_update);
    try std.testing.expectEqual(@as(u32, 0), runtime.streamAt(0).pending_recv_window_update);
}

test "http2 active pending body shares bounded storage and preserves flow-control credit" {
    const allocator = std.testing.allocator;
    var runtime = testSlot();
    defer runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);

    const request_key = RequestKey{ .lane_id = 0, .slot = 1, .generation = 1 };
    try runtime.h2ReserveStream(1);
    try runtime.h2SetRequestBodyExpectation(1, .ingress_channel, 6, false);
    try runtime.h2ActivateStream(1, request_key, 10);
    try runtime.h2AppendActivePendingBody(allocator, 1, "abc", false, 4);
    try runtime.h2AppendActivePendingBody(allocator, 1, "def", true, 5);

    const view = runtime.h2PendingBodyView(1) orelse return error.MissingPendingBody;
    try std.testing.expectEqualStrings("abcdef", view.bytes);
    try std.testing.expect(view.end_stream);
    try std.testing.expectEqual(@as(usize, 9), view.window_credit_len);

    var pending = runtime.h2TakePendingBody(1) orelse return error.MissingPendingBody;
    defer pending.deinit(allocator);
    try std.testing.expectEqualStrings("abcdef", pending.bytes);
    try std.testing.expect(pending.end_stream);
    try std.testing.expectEqual(@as(usize, 9), pending.window_credit_len);
    try std.testing.expectEqual(@as(usize, 0), runtime.h2_pending_body_bytes);
}

test "http2 dropping active pending body restores connection credit only" {
    const allocator = std.testing.allocator;
    var runtime = testSlot();
    defer runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);

    const request_key = RequestKey{ .lane_id = 0, .slot = 1, .generation = 1 };
    try runtime.h2ReserveStream(1);
    try runtime.h2SetRequestBodyExpectation(1, .ingress_channel, 3, false);
    try runtime.h2ActivateStream(1, request_key, 10);
    try runtime.h2ConsumeInboundWindow(1, 6);
    try runtime.h2AppendActivePendingBody(allocator, 1, "abc", true, 6);

    _ = runtime.h2DetachActiveRequestForLocalResponse(allocator, 1) orelse return error.MissingActiveRequest;

    try std.testing.expectEqual(limits.h2.INGRESS_CONNECTION_RECV_WINDOW_BYTES, runtime.h2_connection_recv_window);
    try std.testing.expectEqual(@as(u32, 6), runtime.h2_pending_connection_window_update);
    try std.testing.expectEqual(@as(?stream_table.H2StreamState, null), runtime.h2StreamState(1));
}

test "http2 dropping zero-byte active pending body still restores connection credit" {
    const allocator = std.testing.allocator;
    var runtime = testSlot();
    defer runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);

    const request_key = RequestKey{ .lane_id = 0, .slot = 1, .generation = 1 };
    try runtime.h2ReserveStream(1);
    try runtime.h2SetRequestBodyExpectation(1, .ingress_channel, 0, false);
    try runtime.h2ActivateStream(1, request_key, 10);
    try runtime.h2ConsumeInboundWindow(1, 2);
    try runtime.h2AppendActivePendingBody(allocator, 1, "", true, 2);

    _ = runtime.h2DetachActiveRequestForLocalResponse(allocator, 1) orelse return error.MissingActiveRequest;

    try std.testing.expectEqual(limits.h2.INGRESS_CONNECTION_RECV_WINDOW_BYTES, runtime.h2_connection_recv_window);
    try std.testing.expectEqual(@as(u32, 2), runtime.h2_pending_connection_window_update);
}

test "http2 preparing body enforces bounded per-stream and connection memory" {
    const allocator = std.testing.allocator;
    var runtime = testSlot();
    defer runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);

    const too_large = try allocator.alloc(u8, flow_control.max_h2_pending_body_bytes_per_stream + 1);
    defer allocator.free(too_large);
    @memset(too_large, 'a');

    try runtime.h2ReserveStream(1);
    try runtime.h2SetRequestBodyExpectation(1, .ingress_channel, too_large.len, false);
    try std.testing.expectError(
        error.Http2PendingBodyTooLarge,
        runtime.h2AppendPreparingBody(allocator, 1, too_large, false, too_large.len),
    );
    try std.testing.expectEqual(@as(usize, 0), runtime.h2_pending_body_bytes);
    try std.testing.expectEqual(@as(usize, 0), runtime.streamAt(0).pending_body_len);

    const fill_len = flow_control.max_h2_pending_body_bytes_per_stream;
    const fill = try allocator.alloc(u8, fill_len);
    defer allocator.free(fill);
    @memset(fill, 'b');

    const stream_ids = [_]u32{ 3, 5, 7, 9 };
    for (stream_ids) |stream_id| {
        try runtime.h2ReserveStream(stream_id);
        try runtime.h2SetRequestBodyExpectation(stream_id, .ingress_channel, fill.len + 1, false);
        try runtime.h2AppendPreparingBody(allocator, stream_id, fill, false, fill.len);
    }
    try std.testing.expectEqual(flow_control.max_h2_pending_body_bytes_per_connection, runtime.h2_pending_body_bytes);

    try runtime.h2ReserveStream(11);
    try runtime.h2SetRequestBodyExpectation(11, .ingress_channel, 1, false);
    try std.testing.expectError(
        error.Http2PendingBodyTooLarge,
        runtime.h2AppendPreparingBody(allocator, 11, "x", false, 1),
    );
    try std.testing.expectEqual(flow_control.max_h2_pending_body_bytes_per_connection, runtime.h2_pending_body_bytes);
}

test "http2 preparing body lifecycle stress preserves flow-control accounting" {
    const allocator = std.testing.allocator;
    var runtime = testSlot();
    defer runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);

    for (0..10_000) |index| {
        const stream_id: u32 = @intCast(1 + index * 2);

        try runtime.h2BeginHeaderBlock(stream_id, false, .request_headers);
        try runtime.h2AppendHeaderBlock(allocator, &shared_lane.header_blocks, "h");
        try runtime.h2AppendHeaderBlock(allocator, &shared_lane.header_blocks, "x");
        var block = runtime.h2TakeHeaderBlock(&shared_lane.header_blocks);
        block.deinit(allocator);

        try runtime.h2ReserveStream(stream_id);
        try runtime.h2SetRequestBodyExpectation(stream_id, .ingress_channel, 8, false);
        try runtime.h2ConsumeInboundWindow(stream_id, 8);
        try runtime.h2AppendPreparingBody(allocator, stream_id, "bodydata", true, 8);

        switch (index % 4) {
            0 => {
                var pending = runtime.h2TakePendingBody(stream_id) orelse return error.MissingPendingBody;
                defer pending.deinit(allocator);
                try runtime.h2RestoreTakenPendingBodyConnectionCredit(&pending);
                try std.testing.expect(runtime.h2RemoveStream(allocator, stream_id));
            },
            1 => {
                // No request owns the stream yet, and the reset takes it out
                // of the table with its body.
                try std.testing.expect(runtime.h2MarkStreamReset(allocator, stream_id) == null);
                try std.testing.expectEqual(@as(?stream_table.H2StreamState, null), runtime.h2StreamState(stream_id));
            },
            2 => {
                try std.testing.expect(runtime.h2FinishLocalResponse(allocator, stream_id));
            },
            else => {
                runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
                runtime = testSlot();
            },
        }

        try std.testing.expectEqual(@as(usize, 0), runtime.h2_pending_body_bytes);
        try std.testing.expectEqual(@as(usize, 0), runtime.ingress_channel_count);
        try std.testing.expectEqual(limits.h2.INGRESS_CONNECTION_RECV_WINDOW_BYTES, runtime.h2_connection_recv_window);
        try std.testing.expect(!runtime.h2HasPendingHeaderBlock());
    }
}

/// What a stream handler may return to the driver: a lane fault or an HTTP/2
/// error (`loop_handlers` in `server/ingress/fault.zig`). Anything else a
/// handler meets it answers on its own stream.
const StreamHandlerError = fault.LaneFault || fault.Http2Error;

/// Takes the decision to close the connection as the lane's
/// `closeRuntimeConnection` (`server/ingress/runner/connection_flow.zig`)
/// takes it: the connection stops reading and queueing, a GOAWAY ends its
/// write queue when `close` names a code and HTTP/2 can still speak, and a
/// second decision keeps the first reason and drops the flush.
fn closeAsLane(allocator: std.mem.Allocator, runtime: *Slot, close: fault.ConnectionClose) void {
    if (!runtime.isLive())
        return;
    if (runtime.closing) |*closing| {
        closing.flush = false;
        return;
    }
    const goaway_queued = if (close.goaway) |error_code|
        http2_writing.queueCloseGoaway(allocator, runtime, error_code)
    else
        false;
    runtime.closing = .{ .reason = close.reason, .flush = goaway_queued };
}

const TestService = struct {
    allocator: std.mem.Allocator,
};

/// Requests `TestWorker` keeps a copy of; it counts every request it starts.
const captured_requests_max = 8;

const CapturedRequest = struct {
    stream_id: u32 = 0,
    method: [16]u8 = undefined,
    method_len: usize = 0,
    path: [128]u8 = undefined,
    path_len: usize = 0,
    raw_query: [128]u8 = undefined,
    raw_query_len: usize = 0,
    authority: [128]u8 = undefined,
    authority_len: usize = 0,
    content_length: ?usize = null,
    end_stream: bool = false,
    /// The fields the head carried besides its pseudo-header fields.
    header_count: usize = 0,
    /// The head's last regular field as the lane received it, empty for a
    /// head without one.
    last_field_name: [32]u8 = undefined,
    last_field_name_len: usize = 0,
    last_field_value: [32]u8 = undefined,
    last_field_value_len: usize = 0,

    fn methodSlice(self: *const CapturedRequest) []const u8 {
        return self.method[0..self.method_len];
    }

    fn pathSlice(self: *const CapturedRequest) []const u8 {
        return self.path[0..self.path_len];
    }

    fn rawQuerySlice(self: *const CapturedRequest) []const u8 {
        return self.raw_query[0..self.raw_query_len];
    }

    fn authoritySlice(self: *const CapturedRequest) []const u8 {
        return self.authority[0..self.authority_len];
    }

    fn lastFieldName(self: *const CapturedRequest) []const u8 {
        return self.last_field_name[0..self.last_field_name_len];
    }

    fn lastFieldValue(self: *const CapturedRequest) []const u8 {
        return self.last_field_value[0..self.last_field_value_len];
    }
};

const AutoResponseMode = enum {
    none,
    on_headers_end_stream,
    on_body_end_stream,
};

const TestWorker = struct {
    service: TestService,
    /// What the driver shares across a lane's connections; every slot of
    /// the suite sits on it (`sharedLane`).
    h2_lane: *LaneResources = &shared_lane,
    requests: [captured_requests_max]CapturedRequest = @splat(.{}),
    request_count: usize = 0,
    /// Streams refused past the concurrency cap, as the lane refuses them.
    refused_count: usize = 0,
    body: [server_max_frame_size]u8 = undefined,
    body_len: usize = 0,
    body_end_stream: bool = false,
    body_batch_count: usize = 0,
    reset_stream_id: u32 = 0,
    reset_error_code: u32 = 0,
    reset_count: usize = 0,
    auto_response_mode: AutoResponseMode = .none,
    response_status: u16 = 200,
    response_header_name: []const u8 = "x-mode",
    response_header_value: []const u8 = "h2",
    header_response_body: []const u8 = "h2-get-ok",
    body_response_body: []const u8 = "h2-post-ok",
    response_count: usize = 0,
    /// The first close the driver asked for, null while it asked none.
    close: ?fault.ConnectionClose = null,

    pub fn updateConnectionInterest(self: *TestWorker, runtime: *Slot) fault.LaneFault!void {
        _ = self;
        _ = runtime;
    }

    pub fn closeRuntimeConnection(self: *TestWorker, runtime: *Slot, close: fault.ConnectionClose) void {
        if (self.close == null)
            self.close = close;
        closeAsLane(self.service.allocator, runtime, close);
    }

    /// Request bodies never wait in the stub, so a drive finds none to
    /// forward.
    pub fn flushPendingH2RequestBodies(self: *TestWorker, runtime: *Slot) StreamHandlerError!bool {
        _ = self;
        _ = runtime;
        return false;
    }

    /// Starts each request whose stream fits under the cap. The request key's
    /// slot and the request id are both the request's ordinal, from 1.
    pub fn startDynamicH2(self: *TestWorker, runtime: *Slot, stream_id: u32, head: *const h2_request.ParsedHead) StreamHandlerError!bool {
        // A stream past the advertised cap is refused alone, as
        // `startDynamicH2` in `runner/admission.zig` refuses it.
        runtime.h2ReserveStream(stream_id) catch |err| switch (err) {
            error.Http2TooManyConcurrentStreams => {
                self.refused_count += 1;
                try http2_writing.queueRstStream(TestWorker, self, runtime, stream_id, .refused_stream);
                return true;
            },
            else => |other| return other,
        };
        try runtime.h2SetRequestBodyExpectation(stream_id, head.body_framing, head.content_length, head.end_stream);
        const request_key = RequestKey{
            .lane_id = 0,
            .slot = @intCast(self.request_count + 1),
            .generation = 1,
        };
        const request_id: u64 = @intCast(self.request_count + 1);
        try runtime.h2ActivateStream(stream_id, request_key, request_id);

        const index = self.request_count;
        self.request_count += 1;
        if (index < self.requests.len) {
            var captured = CapturedRequest{
                .stream_id = stream_id,
                .content_length = head.content_length,
                .end_stream = head.end_stream,
                .header_count = head.headers.len,
            };
            captured.method_len = copyBounded(&captured.method, head.method);
            captured.path_len = copyBounded(&captured.path, head.path);
            captured.raw_query_len = copyBounded(&captured.raw_query, head.raw_query);
            captured.authority_len = copyBounded(&captured.authority, head.authority());
            if (head.headers.len != 0) {
                const last = head.headers[head.headers.len - 1];
                captured.last_field_name_len = copyBounded(&captured.last_field_name, last.name);
                captured.last_field_value_len = copyBounded(&captured.last_field_value, last.value);
            }
            self.requests[index] = captured;
        }
        if (self.auto_response_mode == .on_headers_end_stream and head.end_stream)
            _ = try self.sendResponse(runtime, stream_id, self.header_response_body);
        return true;
    }

    pub fn handleH2DataFrame(
        self: *TestWorker,
        runtime: *Slot,
        stream_id: u32,
        payload: []const u8,
        end_stream: bool,
        window_credit_len: usize,
    ) StreamHandlerError!DataFrameHandling {
        _ = window_credit_len;
        try runtime.h2RecordRequestBodyChunk(stream_id, payload.len, end_stream);
        if (payload.len > self.body.len - self.body_len)
            return error.Http2PendingBodyTooLarge;
        @memcpy(self.body[self.body_len..][0..payload.len], payload);
        self.body_len += payload.len;
        if (end_stream)
            self.body_end_stream = true;
        if (self.auto_response_mode == .on_body_end_stream and end_stream)
            _ = try self.sendResponse(runtime, stream_id, self.body_response_body);
        return .consumed;
    }

    pub fn handleH2DataFrameBatch(self: *TestWorker, runtime: *Slot, stream_id: u32, chunks: []const http2_connection.DataFrameChunk) StreamHandlerError!DataFrameHandling {
        self.body_batch_count += 1;
        var saw_end_stream = false;
        for (chunks) |chunk| {
            try runtime.h2RecordRequestBodyChunk(stream_id, chunk.payload.len, chunk.end_stream);
            if (chunk.payload.len > self.body.len - self.body_len)
                return error.Http2PendingBodyTooLarge;
            @memcpy(self.body[self.body_len..][0..chunk.payload.len], chunk.payload);
            self.body_len += chunk.payload.len;
            if (chunk.end_stream) {
                self.body_end_stream = true;
                saw_end_stream = true;
            }
        }
        if (self.auto_response_mode == .on_body_end_stream and saw_end_stream)
            _ = try self.sendResponse(runtime, stream_id, self.body_response_body);
        return .consumed;
    }

    pub fn handleH2ResetFrame(self: *TestWorker, runtime: *Slot, stream_id: u32, error_code: u32) StreamHandlerError!bool {
        self.reset_stream_id = stream_id;
        self.reset_error_code = error_code;
        self.reset_count += 1;
        _ = runtime.h2MarkStreamReset(self.service.allocator, stream_id);
        return true;
    }

    /// Answers `stream_id` from inside a stream handler the way a worker's
    /// head and last chunk do: one queued write with END_STREAM, recorded as
    /// the worker's head. The stream stays in the table; the driver closes
    /// it once the handler returns and both ends are done.
    fn sendResponse(self: *TestWorker, runtime: *Slot, stream_id: u32, body: []const u8) StreamHandlerError!bool {
        const headers = [_]ipc.ingress_channel.ResponseHeader{
            .{ .name = self.response_header_name, .value = self.response_header_value },
        };
        self.response_count += 1;
        const queued = try queueResponseHeadAndChunk(TestWorker, self, runtime, stream_id, self.response_status, &headers, body, true);
        // The record refuses only a stream with no active request or one
        // that has a head already, and the stub answers each stream it
        // started once, so a refusal is the stub's own state gone wrong.
        runtime.h2MarkWorkerResponseHeadChunkPairQueued(stream_id, true) catch
            return error.Http2StreamStateMismatch;
        return queued;
    }
};

/// A lane whose streams never reach a worker: each request stays `preparing`
/// and every DATA frame is reported held (`.deferred`), so no receive credit
/// goes back.
const BackpressuredTestWorker = struct {
    service: TestService,
    h2_lane: *LaneResources = &shared_lane,
    data_frame_count: usize = 0,
    data_batch_count: usize = 0,
    /// The first close the driver asked for, null while it asked none.
    close: ?fault.ConnectionClose = null,

    pub fn updateConnectionInterest(self: *BackpressuredTestWorker, runtime: *Slot) fault.LaneFault!void {
        _ = self;
        _ = runtime;
    }

    pub fn closeRuntimeConnection(self: *BackpressuredTestWorker, runtime: *Slot, close: fault.ConnectionClose) void {
        if (self.close == null)
            self.close = close;
        closeAsLane(self.service.allocator, runtime, close);
    }

    /// No worker takes the held bytes, so none move on.
    pub fn flushPendingH2RequestBodies(self: *BackpressuredTestWorker, runtime: *Slot) StreamHandlerError!bool {
        _ = self;
        _ = runtime;
        return false;
    }

    pub fn startDynamicH2(self: *BackpressuredTestWorker, runtime: *Slot, stream_id: u32, head: *const h2_request.ParsedHead) StreamHandlerError!bool {
        _ = self;
        try runtime.h2ReserveStream(stream_id);
        try runtime.h2SetRequestBodyExpectation(stream_id, head.body_framing, head.content_length, head.end_stream);
        return true;
    }

    pub fn handleH2DataFrame(
        self: *BackpressuredTestWorker,
        runtime: *Slot,
        stream_id: u32,
        payload: []const u8,
        end_stream: bool,
        window_credit_len: usize,
    ) StreamHandlerError!DataFrameHandling {
        _ = window_credit_len;
        try runtime.h2RecordRequestBodyChunk(stream_id, payload.len, end_stream);
        self.data_frame_count += 1;
        return .deferred;
    }

    pub fn handleH2DataFrameBatch(self: *BackpressuredTestWorker, runtime: *Slot, stream_id: u32, chunks: []const http2_connection.DataFrameChunk) StreamHandlerError!DataFrameHandling {
        self.data_batch_count += 1;
        for (chunks) |chunk| {
            try runtime.h2RecordRequestBodyChunk(stream_id, chunk.payload.len, chunk.end_stream);
            self.data_frame_count += 1;
        }
        return .deferred;
    }

    pub fn handleH2ResetFrame(self: *BackpressuredTestWorker, runtime: *Slot, stream_id: u32, error_code: u32) StreamHandlerError!bool {
        _ = self;
        _ = runtime;
        _ = stream_id;
        _ = error_code;
        return true;
    }
};

/// Forwards to `backing` and refuses every allocation of `refused_min_len`
/// bytes or more, so a test fails the allocation a client sized large while
/// the driver's small allocations around it succeed.
const LargeAllocationRefusingAllocator = struct {
    backing: std.mem.Allocator,
    refused_min_len: usize,
    refusals: usize = 0,

    fn allocator(self: *LargeAllocationRefusingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *LargeAllocationRefusingAllocator = @ptrCast(@alignCast(context));
        if (len >= self.refused_min_len) {
            self.refusals += 1;
            return null;
        }
        return self.backing.rawAlloc(len, alignment, return_address);
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
        const self: *LargeAllocationRefusingAllocator = @ptrCast(@alignCast(context));
        if (new_len >= self.refused_min_len) {
            self.refusals += 1;
            return false;
        }
        return self.backing.rawResize(memory, alignment, new_len, return_address);
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
        const self: *LargeAllocationRefusingAllocator = @ptrCast(@alignCast(context));
        if (new_len >= self.refused_min_len) {
            self.refusals += 1;
            return null;
        }
        return self.backing.rawRemap(memory, alignment, new_len, return_address);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *LargeAllocationRefusingAllocator = @ptrCast(@alignCast(context));
        self.backing.rawFree(memory, alignment, return_address);
    }
};

fn copyBounded(dest: []u8, value: []const u8) usize {
    const len = @min(dest.len, value.len);
    @memcpy(dest[0..len], value[0..len]);
    return len;
}

/// A connection the suite's lane holds over a socket pair, past its
/// handshake: `pair[1]` is the client's end.
fn newH2SocketPairRuntime() !struct { pair: [2]std.posix.fd_t, runtime: Slot } {
    const pair = try fd_mod.socketPairType(std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK);
    var runtime = testSlot();
    runtime.slab_link.live = true;
    runtime.fd = pair[0];
    runtime.state = .http2_connection;
    return .{ .pair = pair, .runtime = runtime };
}

fn writeAllFd(fd: std.posix.fd_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const amount = std.posix.write(fd, bytes[written..]) catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.sleep(1 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        if (amount == 0)
            return error.ShortWrite;
        written += amount;
    }
}

fn readAvailableFd(fd: std.posix.fd_t, out: []u8) ![]const u8 {
    var len: usize = 0;
    while (len < out.len) {
        const amount = std.posix.read(fd, out[len..]) catch |err| switch (err) {
            error.WouldBlock => return out[0..len],
            else => return err,
        };
        if (amount == 0)
            return out[0..len];
        len += amount;
    }
    return out[0..len];
}

fn saturateFd(fd: std.posix.fd_t) !void {
    var bytes: [4096]u8 = undefined;
    @memset(bytes[0..], 'x');
    while (true) {
        _ = std.posix.write(fd, &bytes) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return err,
        };
    }
}

fn writeFrameFd(fd: std.posix.fd_t, frame_type: h2.FrameType, flags: u8, stream_id: u32, payload: []const u8) !void {
    var header: [h2.frame_header_len]u8 = undefined;
    try encodeFrameHeader(&header, payload.len, frame_type, flags, stream_id);
    try writeAllFd(fd, &header);
    if (payload.len != 0)
        try writeAllFd(fd, payload);
}

fn writeClientPrefaceAndSettings(fd: std.posix.fd_t) !void {
    try writeAllFd(fd, h2.client_connection_preface);
    try writeFrameFd(fd, .settings, 0, 0, "");
}

fn writeClientPrefaceAndSetting(fd: std.posix.fd_t, id: h2.SettingId, value: u32) !void {
    var payload: [h2.setting_wire_len]u8 = undefined;
    try h2.encodeSetting(&payload, id, value);
    try writeAllFd(fd, h2.client_connection_preface);
    try writeFrameFd(fd, .settings, 0, 0, &payload);
}

/// Writes `headers` as one HEADERS frame encoded with an encoder of its own,
/// which starts from an empty dynamic table and so names no entry an earlier
/// block added.
fn writeHeadersFrameFd(
    allocator: std.mem.Allocator,
    fd: std.posix.fd_t,
    stream_id: u32,
    headers: []const hpack.Header,
    end_stream: bool,
) !void {
    var encoder = try hpack.Encoder.init();
    defer encoder.deinit();
    try writeHeadersFrameWithFd(allocator, fd, &encoder, stream_id, headers, end_stream);
}

/// Writes `headers` as one HEADERS frame encoded with `encoder`, the
/// client's side of the connection's HPACK state, so the block may name
/// fields that earlier blocks from the same encoder added to the table.
fn writeHeadersFrameWithFd(
    allocator: std.mem.Allocator,
    fd: std.posix.fd_t,
    encoder: *hpack.Encoder,
    stream_id: u32,
    headers: []const hpack.Header,
    end_stream: bool,
) !void {
    var block = try encoder.encodeHeaders(allocator, headers, max_response_header_block_bytes);
    defer block.deinit(allocator);
    const flags: u8 = 0x4 | if (end_stream) @as(u8, 0x1) else 0;
    try writeFrameFd(fd, .headers, flags, stream_id, block.bytes());
}

fn writeHeadersFrameFdAdvanced(
    allocator: std.mem.Allocator,
    fd: std.posix.fd_t,
    stream_id: u32,
    headers: []const hpack.Header,
    end_stream: bool,
    padded: bool,
    priority: bool,
) !void {
    var encoder = try hpack.Encoder.init();
    defer encoder.deinit();
    var block = try encoder.encodeHeaders(allocator, headers, max_response_header_block_bytes);
    defer block.deinit(allocator);

    const pad_len: usize = if (padded) 2 else 0;
    const priority_len: usize = if (priority) 5 else 0;
    const payload_len = (if (padded) @as(usize, 1) else 0) + priority_len + block.bytes().len + pad_len;
    const payload = try allocator.alloc(u8, payload_len);
    defer allocator.free(payload);

    var cursor: usize = 0;
    if (padded) {
        payload[cursor] = @intCast(pad_len);
        cursor += 1;
    }
    if (priority) {
        @memset(payload[cursor..][0..priority_len], 0);
        cursor += priority_len;
    }
    @memcpy(payload[cursor..][0..block.bytes().len], block.bytes());
    cursor += block.bytes().len;
    if (pad_len != 0)
        @memset(payload[cursor..][0..pad_len], 0);

    var flags: u8 = 0x4 | if (end_stream) @as(u8, 0x1) else 0;
    if (padded)
        flags |= 0x8;
    if (priority)
        flags |= 0x20;
    try writeFrameFd(fd, .headers, flags, stream_id, payload);
}

fn writePaddedDataFrameFd(fd: std.posix.fd_t, stream_id: u32, payload: []const u8, end_stream: bool, pad_len: usize) !void {
    var scratch: [server_max_frame_size]u8 = undefined;
    if (1 + payload.len + pad_len > scratch.len)
        return error.TestBodyTooLarge;
    scratch[0] = @intCast(pad_len);
    @memcpy(scratch[1..][0..payload.len], payload);
    if (pad_len != 0)
        @memset(scratch[1 + payload.len ..][0..pad_len], 0);
    const flags: u8 = 0x8 | if (end_stream) @as(u8, 0x1) else 0;
    try writeFrameFd(fd, .data, flags, stream_id, scratch[0 .. 1 + payload.len + pad_len]);
}

/// The pseudo-header fields every request head in these tests carries:
/// `:method`, `:scheme`, `:authority` and `:path`.
const request_pseudo_field_count = 4;

fn writeGetFd(allocator: std.mem.Allocator, fd: std.posix.fd_t, stream_id: u32, path: []const u8) !void {
    try writeHeadersFrameFd(allocator, fd, stream_id, &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "example.com" },
        .{ .name = ":path", .value = path },
    }, true);
}

/// Writes a GET head of `field_count` fields on `stream_id`, encoded with
/// `encoder`: the pseudo-header fields, then fields named `x-<index>` with
/// one-byte values when `distinct` is true, or one `x-dup: 1` field repeated
/// when it is false, which HPACK sends as one byte per repeat.
fn writeGetOfFieldCountFd(
    allocator: std.mem.Allocator,
    fd: std.posix.fd_t,
    encoder: *hpack.Encoder,
    stream_id: u32,
    field_count: usize,
    distinct: bool,
) !void {
    // Room for "x-" and three digits in each name.
    const name_bytes_max = 8;
    std.debug.assert(field_count >= request_pseudo_field_count);
    std.debug.assert(field_count < 1000);
    const headers = try allocator.alloc(hpack.Header, field_count);
    defer allocator.free(headers);
    const names = try allocator.alloc(u8, field_count * name_bytes_max);
    defer allocator.free(names);
    headers[0] = .{ .name = ":method", .value = "GET" };
    headers[1] = .{ .name = ":scheme", .value = "https" };
    headers[2] = .{ .name = ":authority", .value = "example.com" };
    headers[3] = .{ .name = ":path", .value = "/many-fields" };
    for (headers[request_pseudo_field_count..], request_pseudo_field_count..) |*header, index| {
        if (!distinct) {
            header.* = .{ .name = "x-dup", .value = "1" };
            continue;
        }
        const name = std.fmt.bufPrint(names[index * name_bytes_max ..][0..name_bytes_max], "x-{d}", .{index}) catch unreachable;
        header.* = .{ .name = name, .value = "v" };
    }
    try writeHeadersFrameWithFd(allocator, fd, encoder, stream_id, headers, true);
}

fn writeHeaderBlockFramesFd(
    allocator: std.mem.Allocator,
    fd: std.posix.fd_t,
    stream_id: u32,
    headers: []const hpack.Header,
    end_stream: bool,
    first_chunk_len: usize,
) !void {
    var encoder = try hpack.Encoder.init();
    defer encoder.deinit();
    var block = try encoder.encodeHeaders(allocator, headers, max_response_header_block_bytes);
    defer block.deinit(allocator);

    const first_len = @min(first_chunk_len, block.bytes().len);
    if (first_len == block.bytes().len) {
        const flags: u8 = 0x4 | if (end_stream) @as(u8, 0x1) else 0;
        try writeFrameFd(fd, .headers, flags, stream_id, block.bytes());
        return;
    }

    const header_flags: u8 = if (end_stream) 0x1 else 0;
    try writeFrameFd(fd, .headers, header_flags, stream_id, block.bytes()[0..first_len]);
    try writeFrameFd(fd, .continuation, 0x4, stream_id, block.bytes()[first_len..]);
}

const FoundFrame = struct {
    header: h2.FrameHeader,
    payload: []const u8,
};

fn findFrame(bytes: []const u8, frame_type: h2.FrameType, stream_id: u32) ?FoundFrame {
    return findNthFrame(bytes, frame_type, stream_id, 0);
}

/// The frame of `frame_type` on `stream_id` that `index` others of the same
/// kind precede in `bytes`.
fn findNthFrame(bytes: []const u8, frame_type: h2.FrameType, stream_id: u32, index: usize) ?FoundFrame {
    var seen: usize = 0;
    var cursor: usize = 0;
    while (cursor + h2.frame_header_len <= bytes.len) {
        const header = h2.FrameHeader.parse(bytes[cursor..][0..h2.frame_header_len]) catch return null;
        const payload_start = cursor + h2.frame_header_len;
        const payload_end = payload_start + @as(usize, header.length);
        if (payload_end > bytes.len)
            return null;
        if (header.frame_type == frame_type and header.stream_id == stream_id) {
            if (seen == index)
                return .{ .header = header, .payload = bytes[payload_start..payload_end] };
            seen += 1;
        }
        cursor = payload_end;
    }
    return null;
}

/// Frames of `frame_type` in `bytes`, on any stream.
fn countFrames(bytes: []const u8, frame_type: h2.FrameType) usize {
    var count: usize = 0;
    var cursor: usize = 0;
    while (cursor + h2.frame_header_len <= bytes.len) {
        const header = h2.FrameHeader.parse(bytes[cursor..][0..h2.frame_header_len]) catch return count;
        const payload_end = cursor + h2.frame_header_len + @as(usize, header.length);
        if (payload_end > bytes.len)
            return count;
        if (header.frame_type == frame_type)
            count += 1;
        cursor = payload_end;
    }
    return count;
}

/// Whether the server ended `stream_id` in `bytes`: END_STREAM on a HEADERS
/// or DATA frame, or RST_STREAM.
fn streamEnded(bytes: []const u8, stream_id: u32) bool {
    if (findFrame(bytes, .rst_stream, stream_id) != null)
        return true;
    for ([_]h2.FrameType{ .headers, .data }) |frame_type| {
        var index: usize = 0;
        while (findNthFrame(bytes, frame_type, stream_id, index)) |frame| : (index += 1) {
            if (frame.header.flags.end_stream)
                return true;
        }
    }
    return false;
}

/// The `:status` of a response header block, decoded with a decoder of its
/// own. That reads the connection's first response block, and any block of a
/// connection whose client set SETTINGS_HEADER_TABLE_SIZE to 0, since no
/// earlier block left an entry it could name.
fn decodeStatus(allocator: std.mem.Allocator, block: []const u8, out: *[3]u8) ![]const u8 {
    var decoder = try hpack.Decoder.init();
    defer decoder.deinit();
    var decoded = try decoder.decodeBlock(allocator, block, 16, max_response_header_block_bytes);
    defer decoded.deinit(allocator);
    for (decoded.headers) |header| {
        if (!std.mem.eql(u8, header.name, ":status"))
            continue;
        if (header.value.len != out.len)
            return error.InvalidResponseStatus;
        @memcpy(out, header.value);
        return out;
    }
    return error.MissingResponseStatus;
}

/// Checks that the server answered `stream_id` in `bytes` with `status` and
/// ended the stream, with END_STREAM on the response or RST_STREAM after it.
/// The answer must be the connection's first response block.
fn expectAnsweredAndEnded(allocator: std.mem.Allocator, bytes: []const u8, stream_id: u32, status: []const u8) !void {
    const head = findFrame(bytes, .headers, stream_id) orelse return error.MissingResponseHeaders;
    var status_buffer: [3]u8 = undefined;
    try std.testing.expectEqualStrings(status, try decodeStatus(allocator, head.payload, &status_buffer));
    try std.testing.expect(streamEnded(bytes, stream_id));
}

fn findWindowUpdateWithIncrement(bytes: []const u8, stream_id: u32, increment: u32) ?struct { header: h2.FrameHeader, payload: []const u8 } {
    var cursor: usize = 0;
    while (cursor + h2.frame_header_len <= bytes.len) {
        const header = h2.FrameHeader.parse(bytes[cursor..][0..h2.frame_header_len]) catch return null;
        const payload_start = cursor + h2.frame_header_len;
        const payload_end = payload_start + @as(usize, header.length);
        if (payload_end > bytes.len)
            return null;
        const payload = bytes[payload_start..payload_end];
        if (header.frame_type == .window_update and header.stream_id == stream_id) {
            const parsed_increment = h2.parseWindowUpdateIncrement(payload) catch return null;
            if (parsed_increment == increment)
                return .{ .header = header, .payload = payload };
        }
        cursor = payload_end;
    }
    return null;
}

fn findSettingValue(payload: []const u8, id: h2.SettingId) !?u32 {
    var storage: [h2.Settings.max_settings_per_frame]h2.Setting = undefined;
    const settings = try h2.Settings.parseInto(&storage, payload);
    for (settings.values) |setting| {
        if (setting.id == id)
            return setting.value;
    }
    return null;
}

fn encodeFrameHeader(out: []u8, payload_len: usize, frame_type: h2.FrameType, flags: u8, stream_id: u32) !void {
    var header = h2.FrameHeader{
        .length = @intCast(payload_len),
        .frame_type_raw = @intFromEnum(frame_type),
        .frame_type = frame_type,
        .flags = h2.Flags.fromByte(flags),
        .stream_id = stream_id,
    };
    try header.encode(out);
}

fn readU32(bytes: []const u8) u32 {
    return (@as(u32, bytes[0]) << 24) |
        (@as(u32, bytes[1]) << 16) |
        (@as(u32, bytes[2]) << 8) |
        @as(u32, bytes[3]);
}

/// Drives the connection until a drive finds nothing to do. Once the driver
/// has asked to close it, the queue the close left goes out, GOAWAY last, as
/// the lane's next pass writes it before the teardown (`finishClose` in
/// `server/ingress/runner/connection_flow.zig`).
fn driveUntilIdle(comptime Worker: type, worker: *Worker, runtime: *Slot) !void {
    var iterations: usize = 0;
    while (iterations < 16) : (iterations += 1) {
        const did_work = try drive(Worker, worker, runtime);
        if (!runtime.isOpen()) {
            _ = try http2_writing.flushPendingWrite(Worker, worker, runtime);
            return;
        }
        if (!did_work)
            return;
    }
    return error.Http2DriverDidNotQuiesce;
}

/// Queues a whole worker response on `stream_id`, a head and a last chunk of
/// `body`, through the lane's path for a worker's descriptors
/// (`tryQueueWorkerResponseHeadChunkPair`). The identity is the one
/// `TestWorker.startDynamicH2` gave the stream's request.
fn queueWorkerAnswer(worker: *TestWorker, runtime: *Slot, stream_id: u32, body: []const u8) !void {
    const key = runtime.h2ActiveRequestKey(stream_id) orelse return error.StreamHasNoActiveRequest;
    const identity = ipc.ingress_channel.RequestIdentity{
        .request_id = key.slot,
        .request_generation = key.generation,
        .request_lane_id = key.lane_id,
        .request_slot = key.slot,
    };
    var head_scratch: [64]u8 = undefined;
    const head_payload = try ipc.ingress_channel.encodeResponseHeadInto(&head_scratch, 200, &.{});
    // `Received.payload` is a mutable slice.
    var body_scratch: [64]u8 = undefined;
    if (body.len > body_scratch.len)
        return error.TestBodyTooLarge;
    @memcpy(body_scratch[0..body.len], body);
    var head_descriptor = ipc.ingress_channel.Descriptor.responseHead(identity, stream_id, 0, @intCast(head_payload.len), 200, 0, false);
    head_descriptor.flag_bits |= ipc.ingress_channel.flags.inline_bytes;
    var chunk_descriptor = ipc.ingress_channel.Descriptor.responseChunk(identity, stream_id, 0, @intCast(body.len), true);
    chunk_descriptor.flag_bits |= ipc.ingress_channel.flags.inline_bytes;
    var items = [_]ipc.ingress_channel.Received{
        .{
            .allocator = worker.service.allocator,
            .descriptor = head_descriptor,
            .payload = head_payload,
            .payload_owned = false,
        },
        .{
            .allocator = worker.service.allocator,
            .descriptor = chunk_descriptor,
            .payload = body_scratch[0..body.len],
            .payload_owned = false,
        },
    };
    _ = (try tryQueueWorkerResponseHeadChunkPair(TestWorker, worker, runtime, &items)) orelse
        return error.WorkerResponsePairNotRecognized;
}

fn expectResponseHeader(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    stream_id: u32,
    status: []const u8,
    header_name: []const u8,
    header_value: []const u8,
) !void {
    const frame = findFrame(bytes, .headers, stream_id) orelse return error.MissingResponseHeaders;
    var decoder = try hpack.Decoder.init();
    defer decoder.deinit();
    var decoded = try decoder.decodeBlock(allocator, frame.payload, 16, max_response_header_block_bytes);
    defer decoded.deinit(allocator);

    var saw_status = false;
    var saw_header = false;
    for (decoded.headers) |header| {
        if (std.mem.eql(u8, header.name, ":status") and std.mem.eql(u8, header.value, status))
            saw_status = true;
        if (std.mem.eql(u8, header.name, header_name) and std.mem.eql(u8, header.value, header_value))
            saw_header = true;
    }
    try std.testing.expect(saw_status);
    try std.testing.expect(saw_header);
}

fn expectResponseBody(bytes: []const u8, stream_id: u32, body: []const u8) !void {
    const data = findFrame(bytes, .data, stream_id) orelse return error.MissingResponseData;
    try std.testing.expect(data.header.flags.end_stream);
    try std.testing.expectEqual(@as(u32, @intCast(body.len)), data.header.length);
    try std.testing.expectEqualStrings(body, data.payload);
}

fn writeU32(out: []u8, value: u32) void {
    out[0] = @intCast((value >> 24) & 0xff);
    out[1] = @intCast((value >> 16) & 0xff);
    out[2] = @intCast((value >> 8) & 0xff);
    out[3] = @intCast(value & 0xff);
}

test "http2 driver completes GET with simulated worker response on the same connection" {
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{
        .service = .{ .allocator = allocator },
        .auto_response_mode = .on_headers_end_stream,
        .response_status = 202,
        .header_response_body = "accepted",
    };

    try writeClientPrefaceAndSettings(setup.pair[1]);
    try writeHeadersFrameFd(allocator, setup.pair[1], 1, &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "demo.example.test" },
        .{ .name = ":path", .value = "/full?mode=h2" },
    }, true);

    try driveUntilIdle(TestWorker, &worker, &setup.runtime);

    try std.testing.expect(setup.runtime.isOpen());
    try std.testing.expectEqual(@as(usize, 1), worker.request_count);
    try std.testing.expectEqual(@as(usize, 1), worker.response_count);
    try std.testing.expectEqualStrings("GET", worker.requests[0].methodSlice());
    try std.testing.expectEqualStrings("/full", worker.requests[0].pathSlice());
    try std.testing.expectEqualStrings("mode=h2", worker.requests[0].rawQuerySlice());
    try std.testing.expectEqualStrings("demo.example.test", worker.requests[0].authoritySlice());

    var out: [1024]u8 = undefined;
    const received = try readAvailableFd(setup.pair[1], &out);
    try expectResponseHeader(allocator, received, 1, "202", "x-mode", "h2");
    try expectResponseBody(received, 1, "accepted");
}

test "http2 driver applies peer header table size before response encoding" {
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{
        .service = .{ .allocator = allocator },
        .auto_response_mode = .on_headers_end_stream,
        .header_response_body = "ok",
    };

    try writeClientPrefaceAndSetting(setup.pair[1], .header_table_size, 0);
    try writeHeadersFrameFd(allocator, setup.pair[1], 1, &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "demo.example.test" },
        .{ .name = ":path", .value = "/first" },
    }, true);
    try writeHeadersFrameFd(allocator, setup.pair[1], 3, &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "demo.example.test" },
        .{ .name = ":path", .value = "/second" },
    }, true);

    try driveUntilIdle(TestWorker, &worker, &setup.runtime);

    var out: [2048]u8 = undefined;
    const received = try readAvailableFd(setup.pair[1], &out);
    var decoder = try hpack.Decoder.init();
    defer decoder.deinit();
    try decoder.setMaxCapacity(0);

    var cursor: usize = 0;
    var response_header_blocks: usize = 0;
    while (cursor + h2.frame_header_len <= received.len) {
        const frame_header = try h2.FrameHeader.parse(received[cursor..][0..h2.frame_header_len]);
        const payload_start = cursor + h2.frame_header_len;
        const payload_end = payload_start + @as(usize, frame_header.length);
        if (payload_end > received.len)
            return error.ShortHttp2Frame;
        const payload = received[payload_start..payload_end];
        if (frame_header.frame_type == .headers) {
            if (response_header_blocks == 0) {
                try std.testing.expect(payload.len != 0);
                try std.testing.expectEqual(@as(u8, 0x20), payload[0]);
            }
            var decoded = try decoder.decodeBlock(allocator, payload, 16, max_response_header_block_bytes);
            defer decoded.deinit(allocator);
            try std.testing.expectEqual(@as(usize, 2), decoded.headers.len);
            response_header_blocks += 1;
        }
        cursor = payload_end;
    }

    try std.testing.expectEqual(@as(usize, 2), response_header_blocks);
}

test "http2 driver streams POST body and responds after end stream" {
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{
        .service = .{ .allocator = allocator },
        .auto_response_mode = .on_body_end_stream,
        .body_response_body = "uploaded",
    };

    try writeClientPrefaceAndSettings(setup.pair[1]);
    try writeHeadersFrameFd(allocator, setup.pair[1], 1, &.{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "demo.example.test" },
        .{ .name = ":path", .value = "/upload" },
        .{ .name = "content-length", .value = "11" },
    }, false);
    try writeFrameFd(setup.pair[1], .data, 0, 1, "hello ");
    try writeFrameFd(setup.pair[1], .data, 0x1, 1, "world");

    try driveUntilIdle(TestWorker, &worker, &setup.runtime);

    try std.testing.expect(setup.runtime.isOpen());
    try std.testing.expectEqual(@as(usize, 1), worker.request_count);
    try std.testing.expectEqual(@as(usize, 1), worker.response_count);
    try std.testing.expectEqualStrings("POST", worker.requests[0].methodSlice());
    try std.testing.expectEqualStrings("hello world", worker.body[0..worker.body_len]);
    try std.testing.expect(worker.body_end_stream);

    var out: [1024]u8 = undefined;
    const received = try readAvailableFd(setup.pair[1], &out);
    try expectResponseHeader(allocator, received, 1, "200", "x-mode", "h2");
    try expectResponseBody(received, 1, "uploaded");
    // The body's credit returns to the connection. The stream's own window
    // matters no more once both its request and its response have ended.
    _ = findWindowUpdateWithIncrement(received, 0, 11) orelse return error.MissingConnectionWindowUpdate;
}

test "http2 a request that expects 100-continue and announces a body gets an interim 100 before its final response" {
    // The client holds its body back until the 100 (RFC 9110 §10.1.1), so
    // the interim response goes out once the head is accepted, before any
    // DATA arrives. The expectation matches without regard to case, and the
    // head the lane receives keeps its expect field as the client sent it.
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{
        .service = .{ .allocator = allocator },
        .auto_response_mode = .on_body_end_stream,
        .body_response_body = "uploaded",
    };

    // A header table of 0 keeps every response block decodable on its own.
    try writeClientPrefaceAndSetting(setup.pair[1], .header_table_size, 0);
    try writeHeadersFrameFd(allocator, setup.pair[1], 1, &.{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "demo.example.test" },
        .{ .name = ":path", .value = "/upload" },
        .{ .name = "content-length", .value = "5" },
        .{ .name = "expect", .value = "100-Continue" },
    }, false);

    try driveUntilIdle(TestWorker, &worker, &setup.runtime);

    try std.testing.expect(setup.runtime.isOpen());
    try std.testing.expectEqual(@as(usize, 1), worker.request_count);
    try std.testing.expectEqualStrings("expect", worker.requests[0].lastFieldName());
    try std.testing.expectEqualStrings("100-Continue", worker.requests[0].lastFieldValue());
    var status: [3]u8 = undefined;
    var interim_out: [1024]u8 = undefined;
    const interim_received = try readAvailableFd(setup.pair[1], &interim_out);
    const interim = findFrame(interim_received, .headers, 1) orelse return error.MissingInterimResponse;
    try std.testing.expect(!interim.header.flags.end_stream);
    try std.testing.expectEqualStrings("100", try decodeStatus(allocator, interim.payload, &status));
    try std.testing.expect(findNthFrame(interim_received, .headers, 1, 1) == null);

    try writeFrameFd(setup.pair[1], .data, 0x1, 1, "hello");
    try driveUntilIdle(TestWorker, &worker, &setup.runtime);

    try std.testing.expectEqualStrings("hello", worker.body[0..worker.body_len]);
    var final_out: [1024]u8 = undefined;
    const final_received = try readAvailableFd(setup.pair[1], &final_out);
    const final = findFrame(final_received, .headers, 1) orelse return error.MissingResponseHeaders;
    try std.testing.expectEqualStrings("200", try decodeStatus(allocator, final.payload, &status));
    try expectResponseBody(final_received, 1, "uploaded");
}

test "http2 a request that sends no body, declares an empty one, or does not expect 100-continue, gets no interim response" {
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    try writeClientPrefaceAndSettings(setup.pair[1]);
    // The head ends the stream, so no body is coming.
    try writeHeadersFrameFd(allocator, setup.pair[1], 1, &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "demo.example.test" },
        .{ .name = ":path", .value = "/no-body" },
        .{ .name = "expect", .value = "100-continue" },
    }, true);
    // A body follows, but the client never asked to wait.
    try writeHeadersFrameFd(allocator, setup.pair[1], 3, &.{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "demo.example.test" },
        .{ .name = ":path", .value = "/no-expect" },
        .{ .name = "content-length", .value = "5" },
    }, false);
    // The head leaves its stream open but declares a body of no bytes.
    try writeHeadersFrameFd(allocator, setup.pair[1], 5, &.{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "demo.example.test" },
        .{ .name = ":path", .value = "/empty-body" },
        .{ .name = "content-length", .value = "0" },
        .{ .name = "expect", .value = "100-continue" },
    }, false);

    try driveUntilIdle(TestWorker, &worker, &setup.runtime);

    try std.testing.expect(setup.runtime.isOpen());
    try std.testing.expectEqual(@as(usize, 3), worker.request_count);
    var out: [1024]u8 = undefined;
    const received = try readAvailableFd(setup.pair[1], &out);
    try std.testing.expectEqual(@as(usize, 0), countFrames(received, .headers));
}

test "http2 driver accepts padded priority headers and padded data" {
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{
        .service = .{ .allocator = allocator },
        .auto_response_mode = .on_body_end_stream,
        .body_response_body = "padded-ok",
    };

    try writeClientPrefaceAndSettings(setup.pair[1]);
    try writeHeadersFrameFdAdvanced(allocator, setup.pair[1], 1, &.{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "demo.example.test" },
        .{ .name = ":path", .value = "/padded" },
        .{ .name = "content-length", .value = "3" },
    }, false, true, true);
    try writePaddedDataFrameFd(setup.pair[1], 1, "abc", true, 2);

    try driveUntilIdle(TestWorker, &worker, &setup.runtime);

    try std.testing.expect(setup.runtime.isOpen());
    try std.testing.expectEqual(@as(usize, 1), worker.request_count);
    try std.testing.expectEqualStrings("abc", worker.body[0..worker.body_len]);
    try std.testing.expect(worker.body_end_stream);

    var out: [1024]u8 = undefined;
    const received = try readAvailableFd(setup.pair[1], &out);
    try expectResponseBody(received, 1, "padded-ok");
    // The padding's credit returns with the payload's.
    _ = findWindowUpdateWithIncrement(received, 0, 6) orelse return error.MissingConnectionWindowUpdate;
}

test "http2 driver accepts request trailers as body terminator" {
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{
        .service = .{ .allocator = allocator },
        .auto_response_mode = .on_body_end_stream,
        .body_response_body = "trailers-ok",
    };

    try writeClientPrefaceAndSettings(setup.pair[1]);
    try writeHeadersFrameFd(allocator, setup.pair[1], 1, &.{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "demo.example.test" },
        .{ .name = ":path", .value = "/trailers" },
    }, false);
    try writeFrameFd(setup.pair[1], .data, 0, 1, "abc");
    try writeHeadersFrameFd(allocator, setup.pair[1], 1, &.{
        .{ .name = "x-trailer", .value = "ok" },
    }, true);

    try driveUntilIdle(TestWorker, &worker, &setup.runtime);

    try std.testing.expect(setup.runtime.isOpen());
    try std.testing.expectEqual(@as(usize, 1), worker.request_count);
    try std.testing.expectEqualStrings("abc", worker.body[0..worker.body_len]);
    try std.testing.expect(worker.body_end_stream);

    var out: [1024]u8 = undefined;
    const received = try readAvailableFd(setup.pair[1], &out);
    try expectResponseBody(received, 1, "trailers-ok");
}

test "http2 driver parses GET headers through socket preface" {
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    try writeClientPrefaceAndSettings(setup.pair[1]);
    try writeHeadersFrameFd(allocator, setup.pair[1], 1, &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "example.com" },
        .{ .name = ":path", .value = "/hello?x=1" },
    }, true);

    _ = try drive(TestWorker, &worker, &setup.runtime);

    try std.testing.expect(setup.runtime.isOpen());
    try std.testing.expectEqual(@as(usize, 1), worker.request_count);
    try std.testing.expectEqual(@as(u32, 1), worker.requests[0].stream_id);
    try std.testing.expectEqualStrings("GET", worker.requests[0].methodSlice());
    try std.testing.expectEqualStrings("/hello", worker.requests[0].pathSlice());
    try std.testing.expectEqualStrings("x=1", worker.requests[0].rawQuerySlice());
    try std.testing.expectEqualStrings("example.com", worker.requests[0].authoritySlice());
    try std.testing.expect(worker.requests[0].end_stream);

    var out: [256]u8 = undefined;
    const received = try readAvailableFd(setup.pair[1], &out);
    const settings = findFrame(received, .settings, 0) orelse return error.MissingSettingsFrame;
    try std.testing.expectEqual(@as(?u32, @intCast(stream_table.max_h2_concurrent_streams)), try findSettingValue(settings.payload, .max_concurrent_streams));
    try std.testing.expectEqual(@as(?u32, server_max_frame_size), try findSettingValue(settings.payload, .max_frame_size));
    try std.testing.expectEqual(@as(?u32, limits.h2.INGRESS_STREAM_RECV_WINDOW_BYTES), try findSettingValue(settings.payload, .initial_window_size));
    try std.testing.expectEqual(@as(?u32, @intCast(limits.headers.INGRESS_H2_REQUEST_HEADER_BLOCK_BYTES)), try findSettingValue(settings.payload, .max_header_list_size));
    const connection_window_update = findFrame(received, .window_update, 0) orelse return error.MissingConnectionWindowUpdate;
    try std.testing.expectEqual(
        @as(u32, limits.h2.INGRESS_CONNECTION_RECV_WINDOW_BYTES - h2.default_initial_window_size),
        try h2.parseWindowUpdateIncrement(connection_window_update.payload),
    );
}

test "http2 driver closes a connection whose SETTINGS frame passes the per-frame cap with GOAWAY ENHANCE_YOUR_CALM (#34)" {
    // RFC 9113 bounds no SETTINGS frame, so past
    // `Settings.max_settings_per_frame` the client only adds load. It loses
    // its connection, and `drive` returns, so the lane goes on serving.
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    const count = h2.Settings.max_settings_per_frame + 8;
    var settings_payload: [h2.setting_wire_len * count]u8 = undefined;
    for (0..count) |index| {
        try h2.encodeSetting(
            settings_payload[index * h2.setting_wire_len ..][0..h2.setting_wire_len],
            .max_concurrent_streams,
            @intCast(index + 1),
        );
    }

    try writeAllFd(setup.pair[1], h2.client_connection_preface);
    try writeFrameFd(setup.pair[1], .settings, 0, 0, &settings_payload);
    try writeHeadersFrameFd(allocator, setup.pair[1], 1, &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "example.com" },
        .{ .name = ":path", .value = "/many-settings" },
    }, true);

    try driveUntilIdle(TestWorker, &worker, &setup.runtime);

    try std.testing.expect(!setup.runtime.isOpen());
    try std.testing.expectEqual(fault.ConnectionCloseReason.settings_error, worker.close.?.reason);
    try std.testing.expectEqual(@as(usize, 0), worker.request_count);
    var out: [256]u8 = undefined;
    const received = try readAvailableFd(setup.pair[1], &out);
    const goaway = findFrame(received, .goaway, 0) orelse return error.MissingGoaway;
    try std.testing.expectEqual(@intFromEnum(h2.ErrorCode.enhance_your_calm), readU32(goaway.payload[4..8]));
}

test "http2 driver requires client settings before request frames" {
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    try writeAllFd(setup.pair[1], h2.client_connection_preface);
    try writeHeadersFrameFd(allocator, setup.pair[1], 1, &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "example.com" },
        .{ .name = ":path", .value = "/early" },
    }, true);

    try driveUntilIdle(TestWorker, &worker, &setup.runtime);

    try std.testing.expect(!setup.runtime.isOpen());
    try std.testing.expectEqual(@as(usize, 0), worker.request_count);
    var out: [256]u8 = undefined;
    const received = try readAvailableFd(setup.pair[1], &out);
    const goaway = findFrame(received, .goaway, 0) orelse return error.MissingGoaway;
    try std.testing.expectEqual(@intFromEnum(h2.ErrorCode.protocol_error), readU32(goaway.payload[4..8]));
}

test "http2 driver closes connection on DATA inside an open header block" {
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    try writeClientPrefaceAndSettings(setup.pair[1]);

    // A HEADERS frame without END_HEADERS leaves the header block open, and
    // RFC 9113 §6.10 makes any frame but a CONTINUATION of that stream a
    // connection error of type PROTOCOL_ERROR.
    var encoder = try hpack.Encoder.init();
    defer encoder.deinit();
    var block = try encoder.encodeHeaders(allocator, &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "example.com" },
        .{ .name = ":path", .value = "/interleaved" },
    }, max_response_header_block_bytes);
    defer block.deinit(allocator);
    const first_len = block.bytes().len - 1;
    try writeFrameFd(setup.pair[1], .headers, 0, 1, block.bytes()[0..first_len]);
    try writeFrameFd(setup.pair[1], .data, 0, 1, "x");

    try driveUntilIdle(TestWorker, &worker, &setup.runtime);

    try std.testing.expect(!setup.runtime.isOpen());
    try std.testing.expectEqual(@as(usize, 0), worker.request_count);
    var out: [512]u8 = undefined;
    const received = try readAvailableFd(setup.pair[1], &out);
    const goaway = findFrame(received, .goaway, 0) orelse return error.MissingGoaway;
    try std.testing.expectEqual(@intFromEnum(h2.ErrorCode.protocol_error), readU32(goaway.payload[4..8]));
}

test "http2 driver rejects settings ack as initial client settings" {
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    try writeAllFd(setup.pair[1], h2.client_connection_preface);
    try writeFrameFd(setup.pair[1], .settings, 0x1, 0, "");

    try driveUntilIdle(TestWorker, &worker, &setup.runtime);

    try std.testing.expect(!setup.runtime.isOpen());
    try std.testing.expectEqual(@as(usize, 0), worker.request_count);
    var out: [256]u8 = undefined;
    const received = try readAvailableFd(setup.pair[1], &out);
    const goaway = findFrame(received, .goaway, 0) orelse return error.MissingGoaway;
    try std.testing.expectEqual(@intFromEnum(h2.ErrorCode.protocol_error), readU32(goaway.payload[4..8]));
}

test "http2 driver resets stream when host conflicts with authority" {
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    try writeClientPrefaceAndSettings(setup.pair[1]);
    try writeHeadersFrameFd(allocator, setup.pair[1], 1, &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "example.com" },
        .{ .name = ":path", .value = "/tenant" },
        .{ .name = "host", .value = "other.example.com" },
    }, true);

    _ = try drive(TestWorker, &worker, &setup.runtime);

    try std.testing.expect(setup.runtime.isOpen());
    try std.testing.expectEqual(@as(usize, 0), worker.request_count);
    var out: [256]u8 = undefined;
    const received = try readAvailableFd(setup.pair[1], &out);
    const rst = findFrame(received, .rst_stream, 1) orelse return error.MissingResetFrame;
    try std.testing.expectEqual(@intFromEnum(h2.ErrorCode.protocol_error), readU32(rst.payload[0..4]));
}

test "http2 request head over the decoded byte bound answers 431 and keeps its connection" {
    // The decoder reads the whole block before it refuses the head, so both
    // ends' header tables stay in step and only the stream fails, with the
    // status RFC 9113 §10.5.1 names for it.
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    const header_value = try allocator.alloc(u8, limits.headers.INGRESS_H2_REQUEST_DECODED_HEADER_BYTES + 1);
    defer allocator.free(header_value);
    @memset(header_value, 'a');

    try writeClientPrefaceAndSettings(setup.pair[1]);
    try writeHeaderBlockFramesFd(allocator, setup.pair[1], 1, &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "example.com" },
        .{ .name = ":path", .value = "/too-large" },
        .{ .name = "x-large", .value = header_value },
    }, true, server_max_frame_size);

    try driveUntilIdle(TestWorker, &worker, &setup.runtime);

    try std.testing.expect(setup.runtime.isOpen());
    try std.testing.expectEqual(@as(usize, 0), worker.request_count);
    var out: [1024]u8 = undefined;
    const received = try readAvailableFd(setup.pair[1], &out);
    try std.testing.expect(findFrame(received, .goaway, 0) == null);
    try expectAnsweredAndEnded(allocator, received, 1, "431");
}

test "http2 every request head the decoder admits fits one dispatch (#45)" {
    // A dispatch carries the head's regular fields and a host field the
    // server writes from `:authority`, at most `ipc.max_request_header_count`
    // of them (`h2HeadersForIpc` in `runner/admission.zig`). The decoder's
    // bound on a head's fields keeps the largest head it admits within that.
    const forwarded_max = h2_request.max_header_count - request_pseudo_field_count + 1;
    try std.testing.expect(forwarded_max <= ipc.max_request_header_count);
}

test "http2 a request head at the decoder's field bound reaches the stream handler" {
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };
    var encoder = try hpack.Encoder.init();
    defer encoder.deinit();

    try writeClientPrefaceAndSettings(setup.pair[1]);
    try writeGetOfFieldCountFd(allocator, setup.pair[1], &encoder, 1, h2_request.max_header_count, true);

    try driveUntilIdle(TestWorker, &worker, &setup.runtime);

    try std.testing.expect(setup.runtime.isOpen());
    try std.testing.expectEqual(@as(usize, 1), worker.request_count);
    try std.testing.expectEqual(h2_request.max_header_count - request_pseudo_field_count, worker.requests[0].header_count);
    var out: [1024]u8 = undefined;
    const received = try readAvailableFd(setup.pair[1], &out);
    try std.testing.expect(findFrame(received, .rst_stream, 1) == null);
}

test "http2 a request head one field past the decoder's bound answers 431 and its connection keeps serving (#45)" {
    // The head is refused on its stream, never as a connection error, and
    // the stream it opened leaves the table with its answer.
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };
    var encoder = try hpack.Encoder.init();
    defer encoder.deinit();

    try writeClientPrefaceAndSettings(setup.pair[1]);
    try writeGetOfFieldCountFd(allocator, setup.pair[1], &encoder, 1, h2_request.max_header_count + 1, true);

    try driveUntilIdle(TestWorker, &worker, &setup.runtime);

    try std.testing.expect(setup.runtime.isOpen());
    try std.testing.expectEqual(@as(usize, 0), worker.request_count);
    try std.testing.expectEqual(@as(usize, 0), setup.runtime.ingress_channel_count);
    var out: [1024]u8 = undefined;
    const received = try readAvailableFd(setup.pair[1], &out);
    try std.testing.expect(findFrame(received, .goaway, 0) == null);
    try expectAnsweredAndEnded(allocator, received, 1, "431");

    try writeGetFd(allocator, setup.pair[1], 3, "/after");
    try driveUntilIdle(TestWorker, &worker, &setup.runtime);
    try std.testing.expect(setup.runtime.isOpen());
    try std.testing.expectEqual(@as(usize, 1), worker.request_count);
    try std.testing.expectEqualStrings("/after", worker.requests[0].pathSlice());
}

test "http2 257 repeated request headers in about 300 bytes of HPACK answer 431, and the next head decodes against the table they left (#45)" {
    // The decoder reads the whole refused block, so its dynamic table holds
    // the entries the client's encoder added. The next head from the same
    // encoder names them by index, which decodes only while both tables
    // agree.
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };
    var encoder = try hpack.Encoder.init();
    defer encoder.deinit();

    try writeClientPrefaceAndSettings(setup.pair[1]);
    try writeGetOfFieldCountFd(allocator, setup.pair[1], &encoder, 1, request_pseudo_field_count + 257, false);

    try driveUntilIdle(TestWorker, &worker, &setup.runtime);

    try std.testing.expect(setup.runtime.isOpen());
    try std.testing.expectEqual(@as(usize, 0), worker.request_count);
    var out: [1024]u8 = undefined;
    const received = try readAvailableFd(setup.pair[1], &out);
    try std.testing.expect(findFrame(received, .goaway, 0) == null);
    try expectAnsweredAndEnded(allocator, received, 1, "431");

    try writeHeadersFrameWithFd(allocator, setup.pair[1], &encoder, 3, &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "example.com" },
        .{ .name = ":path", .value = "/after" },
        .{ .name = "x-dup", .value = "1" },
    }, true);
    try driveUntilIdle(TestWorker, &worker, &setup.runtime);
    try std.testing.expect(setup.runtime.isOpen());
    try std.testing.expectEqual(@as(usize, 1), worker.request_count);
    try std.testing.expectEqualStrings("example.com", worker.requests[0].authoritySlice());
    try std.testing.expectEqualStrings("/after", worker.requests[0].pathSlice());
    try std.testing.expectEqual(@as(usize, 1), worker.requests[0].header_count);
    try std.testing.expectEqualStrings("x-dup", worker.requests[0].lastFieldName());
    try std.testing.expectEqualStrings("1", worker.requests[0].lastFieldValue());
}

test "http2 a request head declaring a body over the limit answers 413 and asks the client to stop sending" {
    // The head leaves its stream open, so once the answer's END_STREAM is
    // queued the client gets RST_STREAM NO_ERROR (RFC 9113 §8.1) instead
    // of sending a body nobody reads.
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    var content_length_buffer: [20]u8 = undefined;
    const content_length = try std.fmt.bufPrint(
        &content_length_buffer,
        "{d}",
        .{limits.http_body.MATERIALIZED_BODY_BYTES_MAX + 1},
    );
    try writeClientPrefaceAndSettings(setup.pair[1]);
    try writeHeadersFrameFd(allocator, setup.pair[1], 1, &.{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "example.com" },
        .{ .name = ":path", .value = "/too-large" },
        .{ .name = "content-length", .value = content_length },
    }, false);

    try driveUntilIdle(TestWorker, &worker, &setup.runtime);

    try std.testing.expect(setup.runtime.isOpen());
    try std.testing.expectEqual(@as(usize, 0), worker.request_count);
    try std.testing.expectEqual(@as(usize, 0), setup.runtime.ingress_channel_count);
    var out: [1024]u8 = undefined;
    const received = try readAvailableFd(setup.pair[1], &out);
    try std.testing.expect(findFrame(received, .goaway, 0) == null);
    try expectAnsweredAndEnded(allocator, received, 1, "413");
    const rst = findFrame(received, .rst_stream, 1) orelse return error.MissingRstStream;
    try std.testing.expectEqual(@intFromEnum(h2.ErrorCode.no_error), readU32(rst.payload[0..4]));
}

test "http2 invalid headers still consume stream ordering, and a head on a lower id the client never opened closes the connection" {
    // Stream 3's head lacks `:path` and is refused alone, yet it uses up
    // every lower stream id. Stream 1 was never opened, so a HEADERS frame on
    // it cannot be trailers that crossed a reset: a new stream's id must be
    // above every id the client used (RFC 9113 §5.1.1).
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };
    var encoder = try hpack.Encoder.init();
    defer encoder.deinit();

    try writeClientPrefaceAndSettings(setup.pair[1]);
    try writeHeadersFrameWithFd(allocator, setup.pair[1], &encoder, 3, &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "example.com" },
    }, true);
    try writeHeadersFrameWithFd(allocator, setup.pair[1], &encoder, 1, &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "example.com" },
        .{ .name = ":path", .value = "/too-low" },
    }, true);

    try driveUntilIdle(TestWorker, &worker, &setup.runtime);

    try std.testing.expect(!setup.runtime.isOpen());
    try std.testing.expectEqual(@as(usize, 0), worker.request_count);
    var out: [512]u8 = undefined;
    const received = try readAvailableFd(setup.pair[1], &out);
    const rst = findFrame(received, .rst_stream, 3) orelse return error.MissingResetFrame;
    try std.testing.expectEqual(@intFromEnum(h2.ErrorCode.protocol_error), readU32(rst.payload[0..4]));
    try std.testing.expect(findFrame(received, .rst_stream, 1) == null);
    const goaway = findFrame(received, .goaway, 0) orelse return error.MissingGoaway;
    try std.testing.expectEqual(@intFromEnum(h2.ErrorCode.protocol_error), readU32(goaway.payload[4..8]));
}

test "http2 invalid hpack closes connection with compression error" {
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    try writeClientPrefaceAndSettings(setup.pair[1]);
    try writeFrameFd(setup.pair[1], .headers, 0x5, 1, &.{0xff});

    try driveUntilIdle(TestWorker, &worker, &setup.runtime);

    try std.testing.expect(!setup.runtime.isOpen());
    try std.testing.expectEqual(@as(usize, 0), worker.request_count);
    var out: [256]u8 = undefined;
    const received = try readAvailableFd(setup.pair[1], &out);
    const goaway = findFrame(received, .goaway, 0) orelse return error.MissingGoaway;
    try std.testing.expectEqual(@as(u32, 1), readU32(goaway.payload[0..4]) & h2.max_window_size);
    try std.testing.expectEqual(@intFromEnum(h2.ErrorCode.compression_error), readU32(goaway.payload[4..8]));
}

test "http2 data before headers is a connection error" {
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    try writeClientPrefaceAndSettings(setup.pair[1]);
    try writeFrameFd(setup.pair[1], .data, 0, 1, "x");

    try driveUntilIdle(TestWorker, &worker, &setup.runtime);

    try std.testing.expect(!setup.runtime.isOpen());
    try std.testing.expectEqual(@as(usize, 0), worker.request_count);
    var out: [256]u8 = undefined;
    const received = try readAvailableFd(setup.pair[1], &out);
    const goaway = findFrame(received, .goaway, 0) orelse return error.MissingGoaway;
    try std.testing.expectEqual(@intFromEnum(h2.ErrorCode.protocol_error), readU32(goaway.payload[4..8]));
}

test "http2 rst stream before headers is a connection error" {
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    var reset_payload: [4]u8 = undefined;
    writeU32(&reset_payload, @intFromEnum(h2.ErrorCode.cancel));
    try writeClientPrefaceAndSettings(setup.pair[1]);
    try writeFrameFd(setup.pair[1], .rst_stream, 0, 1, &reset_payload);

    try driveUntilIdle(TestWorker, &worker, &setup.runtime);

    try std.testing.expect(!setup.runtime.isOpen());
    try std.testing.expectEqual(@as(usize, 0), worker.reset_count);
    var out: [256]u8 = undefined;
    const received = try readAvailableFd(setup.pair[1], &out);
    const goaway = findFrame(received, .goaway, 0) orelse return error.MissingGoaway;
    try std.testing.expectEqual(@intFromEnum(h2.ErrorCode.protocol_error), readU32(goaway.payload[4..8]));
}

test "http2 window update before headers is a connection error" {
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    var increment_one = [_]u8{ 0, 0, 0, 1 };
    try writeClientPrefaceAndSettings(setup.pair[1]);
    try writeFrameFd(setup.pair[1], .window_update, 0, 1, &increment_one);

    try driveUntilIdle(TestWorker, &worker, &setup.runtime);

    try std.testing.expect(!setup.runtime.isOpen());
    try std.testing.expectEqual(@as(usize, 0), worker.request_count);
    var out: [256]u8 = undefined;
    const received = try readAvailableFd(setup.pair[1], &out);
    const goaway = findFrame(received, .goaway, 0) orelse return error.MissingGoaway;
    try std.testing.expectEqual(@intFromEnum(h2.ErrorCode.protocol_error), readU32(goaway.payload[4..8]));
}

test "http2 driver parses fragmented request headers through continuation" {
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    try writeClientPrefaceAndSettings(setup.pair[1]);
    try writeHeaderBlockFramesFd(allocator, setup.pair[1], 1, &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "example.com" },
        .{ .name = ":path", .value = "/split" },
        .{ .name = "accept", .value = "text/plain" },
    }, true, 5);

    _ = try drive(TestWorker, &worker, &setup.runtime);

    try std.testing.expect(setup.runtime.isOpen());
    try std.testing.expectEqual(@as(usize, 1), worker.request_count);
    try std.testing.expectEqualStrings("GET", worker.requests[0].methodSlice());
    try std.testing.expectEqualStrings("/split", worker.requests[0].pathSlice());
    try std.testing.expect(worker.requests[0].end_stream);
}

test "http2 driver caps continuation frames per header block" {
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    try writeClientPrefaceAndSettings(setup.pair[1]);
    try writeFrameFd(setup.pair[1], .headers, 0, 1, "\x82");
    for (0..connection_slot.max_h2_header_block_frames) |_|
        try writeFrameFd(setup.pair[1], .continuation, 0, 1, "\x82");

    try driveUntilIdle(TestWorker, &worker, &setup.runtime);

    try std.testing.expect(!setup.runtime.isOpen());
    try std.testing.expectEqual(@as(usize, 0), worker.request_count);
    var out: [4096]u8 = undefined;
    const received = try readAvailableFd(setup.pair[1], &out);
    const goaway = findFrame(received, .goaway, 0) orelse return error.MissingGoaway;
    try std.testing.expectEqual(@intFromEnum(h2.ErrorCode.enhance_your_calm), readU32(goaway.payload[4..8]));
}

test "http2 driver closes a connection whose header block passes its compressed bound with COMPRESSION_ERROR" {
    // The server stops buffering the block and never decompresses it, so the
    // client's dynamic table runs ahead of the server's, which RFC 9113 §4.3
    // makes a connection error. A stream reset would leave every later head
    // on the connection decoded against the wrong table.
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    // Two fragments, each just over half of
    // `INGRESS_H2_REQUEST_HEADER_BLOCK_BYTES`; the bytes are never decoded.
    const fragment = try allocator.alloc(u8, limits.headers.INGRESS_H2_REQUEST_HEADER_BLOCK_BYTES / 2 + 1);
    defer allocator.free(fragment);
    @memset(fragment, 0x82);

    try writeClientPrefaceAndSettings(setup.pair[1]);
    try writeFrameFd(setup.pair[1], .headers, 0, 1, fragment);
    try writeFrameFd(setup.pair[1], .continuation, 0x4, 1, fragment);

    try driveUntilIdle(TestWorker, &worker, &setup.runtime);

    try std.testing.expect(!setup.runtime.isOpen());
    try std.testing.expectEqual(fault.ConnectionCloseReason.header_block_too_large, worker.close.?.reason);
    try std.testing.expectEqual(@as(usize, 0), worker.request_count);
    var out: [256]u8 = undefined;
    const received = try readAvailableFd(setup.pair[1], &out);
    const goaway = findFrame(received, .goaway, 0) orelse return error.MissingGoaway;
    try std.testing.expectEqual(@intFromEnum(h2.ErrorCode.compression_error), readU32(goaway.payload[4..8]));
}

test "http2 driver closes a connection whose header block passes its compressed bound in one HEADERS frame" {
    // A block that one frame carries whole meets the bound a reassembled
    // block meets, though the frame size admits more. Past the bound a field
    // could outgrow the decoder's per-field scratch, so the server never
    // decompresses the block and closes the connection with
    // COMPRESSION_ERROR, as for a block split over CONTINUATION frames.
    // `drive` returns without a lane fault, so the lane goes on serving its
    // other connections.
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    // One byte past `INGRESS_H2_REQUEST_HEADER_BLOCK_BYTES`. Each byte is the
    // indexed field `:method: GET`, so a server that decoded the block would
    // refuse the head past its field bound with 431 and keep the connection.
    const block = try allocator.alloc(u8, limits.headers.INGRESS_H2_REQUEST_HEADER_BLOCK_BYTES + 1);
    defer allocator.free(block);
    @memset(block, 0x82);

    try writeClientPrefaceAndSettings(setup.pair[1]);
    try writeFrameFd(setup.pair[1], .headers, 0x4, 1, block);

    try driveUntilIdle(TestWorker, &worker, &setup.runtime);

    try std.testing.expect(!setup.runtime.isOpen());
    try std.testing.expectEqual(fault.ConnectionCloseReason.header_block_too_large, worker.close.?.reason);
    try std.testing.expectEqual(@as(usize, 0), worker.request_count);
    var out: [256]u8 = undefined;
    const received = try readAvailableFd(setup.pair[1], &out);
    try std.testing.expect(findFrame(received, .headers, 1) == null);
    const goaway = findFrame(received, .goaway, 0) orelse return error.MissingGoaway;
    try std.testing.expectEqual(@intFromEnum(h2.ErrorCode.compression_error), readU32(goaway.payload[4..8]));
}

test "http2 a header block the lane's budget cannot hold closes only its own connection, with ENHANCE_YOUR_CALM" {
    // Unfinished header blocks of every connection of a lane share one
    // budget. The connection whose fragment would pass it loses its
    // connection; another one that holds part of a block keeps it, finishes
    // the block and starts its request.
    const allocator = std.testing.allocator;
    defer shared_lane.header_blocks.limit = limits.ingress.header_block_bytes_per_lane_max;
    var holder = try newH2SocketPairRuntime();
    defer std.posix.close(holder.pair[0]);
    defer std.posix.close(holder.pair[1]);
    defer holder.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var holder_worker = TestWorker{ .service = .{ .allocator = allocator } };
    var flooder = try newH2SocketPairRuntime();
    defer std.posix.close(flooder.pair[0]);
    defer std.posix.close(flooder.pair[1]);
    defer flooder.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var flooder_worker = TestWorker{ .service = .{ .allocator = allocator } };

    var encoder = try hpack.Encoder.init();
    defer encoder.deinit();
    var block = try encoder.encodeHeaders(allocator, &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "example.com" },
        .{ .name = ":path", .value = "/held" },
    }, max_response_header_block_bytes);
    defer block.deinit(allocator);
    const split = block.bytes().len / 2;
    try writeClientPrefaceAndSettings(holder.pair[1]);
    try writeFrameFd(holder.pair[1], .headers, 0x1, 1, block.bytes()[0..split]);
    try driveUntilIdle(TestWorker, &holder_worker, &holder.runtime);
    try std.testing.expect(holder.runtime.h2HasPendingHeaderBlock());
    // The held fragment took a block's first growth; the budget keeps less
    // than another one.
    const held = shared_lane.header_blocks.used;
    try std.testing.expect(held != 0);
    shared_lane.header_blocks.limit = held + 255;

    var fragment: [300]u8 = @splat(0x82);
    try writeClientPrefaceAndSettings(flooder.pair[1]);
    try writeFrameFd(flooder.pair[1], .headers, 0x1, 1, &fragment);
    try driveUntilIdle(TestWorker, &flooder_worker, &flooder.runtime);

    try std.testing.expect(!flooder.runtime.isOpen());
    try std.testing.expectEqual(fault.ConnectionCloseReason.header_block_budget, flooder_worker.close.?.reason);
    var out: [1024]u8 = undefined;
    const received = try readAvailableFd(flooder.pair[1], &out);
    const goaway = findFrame(received, .goaway, 0) orelse return error.MissingGoaway;
    try std.testing.expectEqual(@intFromEnum(h2.ErrorCode.enhance_your_calm), readU32(goaway.payload[4..8]));
    try std.testing.expectEqual(held, shared_lane.header_blocks.used);

    try writeFrameFd(holder.pair[1], .continuation, 0x4, 1, block.bytes()[split..]);
    try driveUntilIdle(TestWorker, &holder_worker, &holder.runtime);
    try std.testing.expect(holder.runtime.isOpen());
    try std.testing.expectEqual(@as(?fault.ConnectionClose, null), holder_worker.close);
    try std.testing.expectEqual(@as(usize, 1), holder_worker.request_count);
    try std.testing.expectEqualStrings("/held", holder_worker.requests[0].pathSlice());
    try std.testing.expectEqual(@as(usize, 0), shared_lane.header_blocks.used);
}

test "http2 driver streams POST body across multiple DATA frames and emits window updates" {
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    try writeClientPrefaceAndSettings(setup.pair[1]);
    try writeHeadersFrameFd(allocator, setup.pair[1], 1, &.{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "example.com" },
        .{ .name = ":path", .value = "/upload" },
        .{ .name = "content-length", .value = "6" },
    }, false);
    try writeFrameFd(setup.pair[1], .data, 0, 1, "abc");
    try writeFrameFd(setup.pair[1], .data, 0x1, 1, "def");

    _ = try drive(TestWorker, &worker, &setup.runtime);

    try std.testing.expectEqual(@as(usize, 1), worker.request_count);
    try std.testing.expectEqualStrings("POST", worker.requests[0].methodSlice());
    try std.testing.expectEqual(@as(?usize, 6), worker.requests[0].content_length);
    try std.testing.expectEqualStrings("abcdef", worker.body[0..worker.body_len]);
    try std.testing.expect(worker.body_end_stream);
    try std.testing.expectEqual(@as(usize, 1), worker.body_batch_count);

    var out: [512]u8 = undefined;
    const received = try readAvailableFd(setup.pair[1], &out);
    _ = findWindowUpdateWithIncrement(received, 0, 6) orelse return error.MissingConnectionWindowUpdate;
    _ = findWindowUpdateWithIncrement(received, 1, 6) orelse return error.MissingStreamWindowUpdate;
}

test "http2 driver accepts end-stream delimited POST body without content length" {
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    try writeClientPrefaceAndSettings(setup.pair[1]);
    try writeHeadersFrameFd(allocator, setup.pair[1], 1, &.{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "example.com" },
        .{ .name = ":path", .value = "/streamed" },
        .{ .name = "content-type", .value = "text/plain" },
    }, false);
    try writeFrameFd(setup.pair[1], .data, 0, 1, "hel");
    try writeFrameFd(setup.pair[1], .data, 0x1, 1, "lo");

    _ = try drive(TestWorker, &worker, &setup.runtime);

    try std.testing.expect(setup.runtime.isOpen());
    try std.testing.expectEqual(@as(usize, 1), worker.request_count);
    try std.testing.expectEqual(@as(?usize, null), worker.requests[0].content_length);
    try std.testing.expectEqualStrings("hello", worker.body[0..worker.body_len]);
    try std.testing.expect(worker.body_end_stream);
    try std.testing.expectEqual(@as(usize, 1), worker.body_batch_count);
}

test "http2 driver enforces inbound flow-control while worker is backpressured" {
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = BackpressuredTestWorker{ .service = .{ .allocator = allocator } };

    try writeClientPrefaceAndSettings(setup.pair[1]);
    var content_length_buffer: [20]u8 = undefined;
    const content_length = try std.fmt.bufPrint(
        &content_length_buffer,
        "{d}",
        .{limits.h2.INGRESS_STREAM_RECV_WINDOW_BYTES + 1},
    );
    try writeHeadersFrameFd(allocator, setup.pair[1], 1, &.{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "example.com" },
        .{ .name = ":path", .value = "/slow" },
        .{ .name = "content-length", .value = content_length },
    }, false);
    _ = try drive(BackpressuredTestWorker, &worker, &setup.runtime);
    try std.testing.expect(setup.runtime.isOpen());

    const first = try allocator.alloc(u8, server_max_frame_size);
    defer allocator.free(first);
    @memset(first, 'a');
    var remaining: usize = limits.h2.INGRESS_STREAM_RECV_WINDOW_BYTES;
    while (remaining != 0) {
        const chunk_len = @min(remaining, first.len);
        try writeFrameFd(setup.pair[1], .data, 0, 1, first[0..chunk_len]);
        _ = try drive(BackpressuredTestWorker, &worker, &setup.runtime);
        try std.testing.expect(setup.runtime.isOpen());
        remaining -= chunk_len;
    }
    try std.testing.expect(setup.runtime.isOpen());
    try std.testing.expectEqual(@as(usize, limits.h2.INGRESS_STREAM_RECV_WINDOW_BYTES / server_max_frame_size), worker.data_frame_count);
    try std.testing.expectEqual(@as(i64, limits.h2.INGRESS_CONNECTION_RECV_WINDOW_BYTES - limits.h2.INGRESS_STREAM_RECV_WINDOW_BYTES), setup.runtime.h2_connection_recv_window);
    try std.testing.expectEqual(@as(i64, 0), setup.runtime.streamAt(0).recv_window);

    try writeFrameFd(setup.pair[1], .data, 0x1, 1, "b");
    try driveUntilIdle(BackpressuredTestWorker, &worker, &setup.runtime);
    try std.testing.expect(!setup.runtime.isOpen());
    try std.testing.expectEqual(fault.ConnectionCloseReason.flow_control_error, worker.close.?.reason);
    try std.testing.expectEqual(@as(usize, limits.h2.INGRESS_STREAM_RECV_WINDOW_BYTES / server_max_frame_size), worker.data_frame_count);

    var out: [256]u8 = undefined;
    const received = try readAvailableFd(setup.pair[1], &out);
    const goaway = findFrame(received, .goaway, 0) orelse return error.MissingGoaway;
    try std.testing.expectEqual(@intFromEnum(h2.ErrorCode.flow_control_error), readU32(goaway.payload[4..8]));
}

test "http2 driver closes a connection whose run of DATA frames passes the stream window with GOAWAY FLOW_CONTROL_ERROR (#34)" {
    // DATA frames for one stream that arrive in one read reach the lane in
    // one call (`tryHandleDataFrameBatch`), and that path answers a window
    // overrun as the single-frame path does: the client loses its
    // connection, and `drive` returns.
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = BackpressuredTestWorker{ .service = .{ .allocator = allocator } };

    try writeClientPrefaceAndSettings(setup.pair[1]);
    var content_length_buffer: [20]u8 = undefined;
    const content_length = try std.fmt.bufPrint(
        &content_length_buffer,
        "{d}",
        .{limits.h2.INGRESS_STREAM_RECV_WINDOW_BYTES + 1},
    );
    try writeHeadersFrameFd(allocator, setup.pair[1], 1, &.{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "example.com" },
        .{ .name = ":path", .value = "/slow-batch" },
        .{ .name = "content-length", .value = content_length },
    }, false);
    _ = try drive(BackpressuredTestWorker, &worker, &setup.runtime);

    // Frames read one at a time take all of the stream's window but a byte;
    // the stub holds every byte, so no credit comes back.
    const frame = try allocator.alloc(u8, server_max_frame_size);
    defer allocator.free(frame);
    @memset(frame, 'a');
    var remaining: usize = limits.h2.INGRESS_STREAM_RECV_WINDOW_BYTES - 1;
    while (remaining != 0) {
        const chunk_len = @min(remaining, frame.len);
        try writeFrameFd(setup.pair[1], .data, 0, 1, frame[0..chunk_len]);
        _ = try drive(BackpressuredTestWorker, &worker, &setup.runtime);
        try std.testing.expect(setup.runtime.isOpen());
        remaining -= chunk_len;
    }
    try std.testing.expectEqual(@as(usize, 0), worker.data_batch_count);

    // Two frames read together carry two bytes against the one left.
    try writeFrameFd(setup.pair[1], .data, 0, 1, "b");
    try writeFrameFd(setup.pair[1], .data, 0, 1, "c");
    try driveUntilIdle(BackpressuredTestWorker, &worker, &setup.runtime);

    try std.testing.expect(!setup.runtime.isOpen());
    try std.testing.expectEqual(fault.ConnectionCloseReason.flow_control_error, worker.close.?.reason);
    try std.testing.expectEqual(@as(usize, 0), worker.data_batch_count);
    var out: [256]u8 = undefined;
    const received = try readAvailableFd(setup.pair[1], &out);
    const goaway = findFrame(received, .goaway, 0) orelse return error.MissingGoaway;
    try std.testing.expectEqual(@intFromEnum(h2.ErrorCode.flow_control_error), readU32(goaway.payload[4..8]));
}

test "http2 driver batches preparing stream data without restoring inbound credit" {
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = BackpressuredTestWorker{ .service = .{ .allocator = allocator } };

    try writeClientPrefaceAndSettings(setup.pair[1]);
    _ = try drive(BackpressuredTestWorker, &worker, &setup.runtime);
    var settings_out: [256]u8 = undefined;
    _ = try readAvailableFd(setup.pair[1], &settings_out);

    try writeHeadersFrameFd(allocator, setup.pair[1], 1, &.{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "example.com" },
        .{ .name = ":path", .value = "/cold-body" },
        .{ .name = "content-length", .value = "6" },
    }, false);
    try writeFrameFd(setup.pair[1], .data, 0, 1, "abc");
    try writeFrameFd(setup.pair[1], .data, 0x1, 1, "def");

    _ = try drive(BackpressuredTestWorker, &worker, &setup.runtime);

    try std.testing.expectEqual(@as(usize, 1), worker.data_batch_count);
    try std.testing.expectEqual(@as(usize, 2), worker.data_frame_count);
    try std.testing.expectEqual(@as(?stream_table.H2StreamState, .preparing), setup.runtime.h2StreamState(1));
    try std.testing.expectEqual(@as(i64, limits.h2.INGRESS_CONNECTION_RECV_WINDOW_BYTES - 6), setup.runtime.h2_connection_recv_window);
    try std.testing.expectEqual(@as(i64, limits.h2.INGRESS_STREAM_RECV_WINDOW_BYTES - 6), setup.runtime.streamAt(0).recv_window);
    try std.testing.expectEqual(@as(u32, 0), setup.runtime.h2_pending_connection_window_update);
    try std.testing.expectEqual(@as(u32, 0), setup.runtime.streamAt(0).pending_recv_window_update);
}

test "http2 driver accepts large data frames up to advertised server max frame size" {
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    try writeClientPrefaceAndSettings(setup.pair[1]);
    _ = try drive(TestWorker, &worker, &setup.runtime);
    var settings_out: [256]u8 = undefined;
    _ = try readAvailableFd(setup.pair[1], &settings_out);

    const payload_len: usize = 40 * 1024;
    const payload = try allocator.alloc(u8, payload_len);
    defer allocator.free(payload);
    @memset(payload, 'q');
    var content_length_buffer: [20]u8 = undefined;
    const content_length = try std.fmt.bufPrint(&content_length_buffer, "{d}", .{payload.len});

    try writeHeadersFrameFd(allocator, setup.pair[1], 1, &.{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "example.com" },
        .{ .name = ":path", .value = "/upload-large" },
        .{ .name = "content-length", .value = content_length },
    }, false);
    try writeFrameFd(setup.pair[1], .data, 0x1, 1, payload);

    _ = try drive(TestWorker, &worker, &setup.runtime);

    try std.testing.expectEqual(@as(usize, 1), worker.request_count);
    try std.testing.expectEqual(payload.len, worker.body_len);
    try std.testing.expectEqualSlices(u8, payload, worker.body[0..worker.body_len]);
    try std.testing.expect(worker.body_end_stream);
}

test "http2 driver keeps concurrent streams distinct" {
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    try writeClientPrefaceAndSettings(setup.pair[1]);
    try writeHeadersFrameFd(allocator, setup.pair[1], 1, &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "example.com" },
        .{ .name = ":path", .value = "/a" },
    }, true);
    try writeHeadersFrameFd(allocator, setup.pair[1], 3, &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "example.com" },
        .{ .name = ":path", .value = "/b" },
    }, true);

    _ = try drive(TestWorker, &worker, &setup.runtime);

    try std.testing.expectEqual(@as(usize, 2), worker.request_count);
    try std.testing.expectEqual(@as(u32, 1), worker.requests[0].stream_id);
    try std.testing.expectEqualStrings("/a", worker.requests[0].pathSlice());
    try std.testing.expectEqual(@as(u32, 3), worker.requests[1].stream_id);
    try std.testing.expectEqualStrings("/b", worker.requests[1].pathSlice());
    try std.testing.expectEqual(@as(?stream_table.H2StreamState, .active), setup.runtime.h2StreamState(1));
    try std.testing.expectEqual(@as(?stream_table.H2StreamState, .active), setup.runtime.h2StreamState(3));
}

test "http2 reset isolates one stream while a concurrent stream completes" {
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{
        .service = .{ .allocator = allocator },
        .auto_response_mode = .on_headers_end_stream,
        .header_response_body = "still-open",
    };

    try writeClientPrefaceAndSettings(setup.pair[1]);
    try writeHeadersFrameFd(allocator, setup.pair[1], 1, &.{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "example.com" },
        .{ .name = ":path", .value = "/reset-me" },
        .{ .name = "content-length", .value = "10" },
    }, false);
    try writeHeadersFrameFd(allocator, setup.pair[1], 3, &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "example.com" },
        .{ .name = ":path", .value = "/survives" },
    }, true);
    var reset_payload: [4]u8 = undefined;
    writeU32(&reset_payload, @intFromEnum(h2.ErrorCode.cancel));
    try writeFrameFd(setup.pair[1], .rst_stream, 0, 1, &reset_payload);

    try driveUntilIdle(TestWorker, &worker, &setup.runtime);

    try std.testing.expect(setup.runtime.isOpen());
    try std.testing.expectEqual(@as(usize, 2), worker.request_count);
    try std.testing.expectEqual(@as(usize, 1), worker.reset_count);
    try std.testing.expectEqual(@as(u32, 1), worker.reset_stream_id);
    try std.testing.expectEqual(@intFromEnum(h2.ErrorCode.cancel), worker.reset_error_code);
    try std.testing.expectEqual(@as(usize, 1), worker.response_count);
    try std.testing.expectEqualStrings("/reset-me", worker.requests[0].pathSlice());
    try std.testing.expectEqualStrings("/survives", worker.requests[1].pathSlice());
    // The reset takes stream 1 out of the table, and stream 3 leaves it
    // closed once both its request and its answer have ended.
    try std.testing.expectEqual(@as(?stream_table.H2StreamState, null), setup.runtime.h2StreamState(1));
    try std.testing.expectEqual(@as(?stream_table.H2StreamState, null), setup.runtime.h2StreamState(3));
    try std.testing.expectEqual(@as(usize, 0), setup.runtime.ingress_channel_count);

    var out: [1024]u8 = undefined;
    const received = try readAvailableFd(setup.pair[1], &out);
    try std.testing.expect(findFrame(received, .goaway, 0) == null);
    try std.testing.expect(findFrame(received, .rst_stream, 3) == null);
    try expectResponseHeader(allocator, received, 3, "200", "x-mode", "h2");
    try expectResponseBody(received, 3, "still-open");
}

test "http2 driver forwards a client reset of an active stream to the lane, and the stream leaves the table" {
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    try writeClientPrefaceAndSettings(setup.pair[1]);
    try writeHeadersFrameFd(allocator, setup.pair[1], 1, &.{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "example.com" },
        .{ .name = ":path", .value = "/reset" },
        .{ .name = "content-length", .value = "10" },
    }, false);
    var reset_payload: [4]u8 = undefined;
    writeU32(&reset_payload, @intFromEnum(h2.ErrorCode.cancel));
    try writeFrameFd(setup.pair[1], .rst_stream, 0, 1, &reset_payload);

    _ = try drive(TestWorker, &worker, &setup.runtime);

    try std.testing.expectEqual(@as(usize, 1), worker.reset_count);
    try std.testing.expectEqual(@as(u32, 1), worker.reset_stream_id);
    try std.testing.expectEqual(@intFromEnum(h2.ErrorCode.cancel), worker.reset_error_code);
    try std.testing.expectEqual(@as(?stream_table.H2StreamState, null), setup.runtime.h2StreamState(1));
    try std.testing.expectEqual(@as(usize, 0), setup.runtime.ingress_channel_count);
}

test "http2 DATA on a stream the client reset gives the connection's credit back, and its trailers keep HPACK in step" {
    // The reset takes the stream out of the table, so frames that still come
    // on it are a closed stream's. The DATA gets RST_STREAM STREAM_CLOSED
    // (RFC 9113 §5.1) and the connection's credit for it back at once, and
    // the trailer block is decompressed and dropped, so a later head that
    // names its field by index decodes against the same table.
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };
    var encoder = try hpack.Encoder.init();
    defer encoder.deinit();

    try writeClientPrefaceAndSettings(setup.pair[1]);
    try writeHeadersFrameWithFd(allocator, setup.pair[1], &encoder, 1, &.{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "example.com" },
        .{ .name = ":path", .value = "/upload" },
    }, false);
    try driveUntilIdle(TestWorker, &worker, &setup.runtime);
    var out: [1024]u8 = undefined;
    _ = try readAvailableFd(setup.pair[1], &out);

    var reset_payload: [4]u8 = undefined;
    writeU32(&reset_payload, @intFromEnum(h2.ErrorCode.cancel));
    try writeFrameFd(setup.pair[1], .rst_stream, 0, 1, &reset_payload);
    try writeFrameFd(setup.pair[1], .data, 0, 1, "0123456789");
    try writeHeadersFrameWithFd(allocator, setup.pair[1], &encoder, 1, &.{
        .{ .name = "x-trailer", .value = "kept-in-step" },
    }, true);
    try writeHeadersFrameWithFd(allocator, setup.pair[1], &encoder, 3, &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "example.com" },
        .{ .name = ":path", .value = "/next" },
        .{ .name = "x-trailer", .value = "kept-in-step" },
    }, true);
    try driveUntilIdle(TestWorker, &worker, &setup.runtime);

    try std.testing.expect(setup.runtime.isOpen());
    try std.testing.expectEqual(@as(usize, 1), worker.reset_count);
    try std.testing.expectEqual(@as(usize, 0), worker.body_len);
    try std.testing.expectEqual(@as(usize, 2), worker.request_count);
    try std.testing.expectEqualStrings("x-trailer", worker.requests[1].lastFieldName());
    try std.testing.expectEqualStrings("kept-in-step", worker.requests[1].lastFieldValue());
    const received = try readAvailableFd(setup.pair[1], &out);
    try std.testing.expect(findFrame(received, .goaway, 0) == null);
    _ = findWindowUpdateWithIncrement(received, 0, 10) orelse return error.MissingConnectionWindowUpdate;
    const rst = findFrame(received, .rst_stream, 1) orelse return error.MissingRstStream;
    try std.testing.expectEqual(@intFromEnum(h2.ErrorCode.stream_closed), readU32(rst.payload[0..4]));
}

test "http2 DATA on a stream that drains its response is dropped with its connection credit returned and no reset" {
    // Once its request has left, the stream only sends what is buffered of
    // the response, and a reset would cut that response short.
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    // A client window of 0 keeps every response byte buffered.
    try writeClientPrefaceAndSetting(setup.pair[1], .initial_window_size, 0);
    try writeHeadersFrameFd(allocator, setup.pair[1], 1, &.{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "example.com" },
        .{ .name = ":path", .value = "/upload" },
    }, false);
    try driveUntilIdle(TestWorker, &worker, &setup.runtime);
    try std.testing.expectEqual(@as(usize, 1), worker.request_count);
    var out: [1024]u8 = undefined;
    _ = try readAvailableFd(setup.pair[1], &out);

    _ = try queueResponseHeadAndChunk(TestWorker, &worker, &setup.runtime, 1, 200, &.{}, "late", true);
    const request_key = setup.runtime.h2ActiveRequestKey(1) orelse return error.StreamHasNoActiveRequest;
    try std.testing.expectEqual(stream_table.StreamRelease.draining, setup.runtime.h2RemoveRequest(allocator, request_key));

    try writeFrameFd(setup.pair[1], .data, 0, 1, "abc");
    try driveUntilIdle(TestWorker, &worker, &setup.runtime);

    try std.testing.expect(setup.runtime.isOpen());
    try std.testing.expectEqual(@as(usize, 0), worker.body_len);
    try std.testing.expectEqual(@as(?stream_table.H2StreamState, .draining_response), setup.runtime.h2StreamState(1));
    const received = try readAvailableFd(setup.pair[1], &out);
    try std.testing.expect(findFrame(received, .rst_stream, 1) == null);
    _ = findWindowUpdateWithIncrement(received, 0, 3) orelse return error.MissingConnectionWindowUpdate;
}

test "http2 a padded DATA frame whose stream goes away between its pieces gives the connection its credit back once" {
    // The first piece takes the frame's whole length from the windows. The
    // lane then resets the stream, as a request deadline does, before the
    // rest arrives, so the last piece and the padding after it return only
    // the connection's credit, and the client's connection window ends where
    // the server advertised it.
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    try writeClientPrefaceAndSettings(setup.pair[1]);
    try writeHeadersFrameFd(allocator, setup.pair[1], 1, &.{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "example.com" },
        .{ .name = ":path", .value = "/upload" },
    }, false);
    try driveUntilIdle(TestWorker, &worker, &setup.runtime);
    var out: [1024]u8 = undefined;
    _ = try readAvailableFd(setup.pair[1], &out);

    const pad_len = 6;
    const data = "0123456789";
    var payload: [1 + data.len + pad_len]u8 = @splat(0);
    payload[0] = pad_len;
    @memcpy(payload[1..][0..data.len], data);
    var header: [h2.frame_header_len]u8 = undefined;
    try encodeFrameHeader(&header, payload.len, .data, (h2.Flags{ .padded = true }).toByte(), 1);
    try writeAllFd(setup.pair[1], &header);
    try writeAllFd(setup.pair[1], payload[0..5]);
    try driveUntilIdle(TestWorker, &worker, &setup.runtime);
    try std.testing.expectEqual(@as(usize, 4), worker.body_len);

    _ = setup.runtime.h2MarkStreamReset(allocator, 1);
    try writeAllFd(setup.pair[1], payload[5..]);
    try driveUntilIdle(TestWorker, &worker, &setup.runtime);

    try std.testing.expect(setup.runtime.isOpen());
    try std.testing.expectEqual(@as(usize, 4), worker.body_len);
    try std.testing.expectEqual(@as(i64, limits.h2.INGRESS_CONNECTION_RECV_WINDOW_BYTES), setup.runtime.h2_connection_recv_window);
}

test "http2 driver responds to ping without involving worker request path" {
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    const ping_payload = "12345678";
    try writeClientPrefaceAndSettings(setup.pair[1]);
    try writeFrameFd(setup.pair[1], .ping, 0, 0, ping_payload);

    _ = try drive(TestWorker, &worker, &setup.runtime);

    try std.testing.expectEqual(@as(usize, 0), worker.request_count);
    var out: [256]u8 = undefined;
    const received = try readAvailableFd(setup.pair[1], &out);
    const ping = findFrame(received, .ping, 0) orelse return error.MissingPingAck;
    try std.testing.expect((ping.header.flags.toByte() & 0x1) != 0);
    try std.testing.expectEqualStrings(ping_payload, ping.payload);
}

test "http2 driver sends enhance your calm on control frame flood" {
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    const ping_payload = "12345678";
    try writeClientPrefaceAndSettings(setup.pair[1]);
    for (0..http2_reading.max_h2_budgeted_frames_per_read + 1) |_|
        try writeFrameFd(setup.pair[1], .ping, 0, 0, ping_payload);

    try driveUntilIdle(TestWorker, &worker, &setup.runtime);

    try std.testing.expect(!setup.runtime.isOpen());
    try std.testing.expectEqual(@as(usize, 0), worker.request_count);
    var out: [8192]u8 = undefined;
    const received = try readAvailableFd(setup.pair[1], &out);
    const goaway = findFrame(received, .goaway, 0) orelse return error.MissingGoaway;
    try std.testing.expectEqual(@intFromEnum(h2.ErrorCode.enhance_your_calm), readU32(goaway.payload[4..8]));
}

test "http2 driver budgets padded empty data frame flood" {
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    try writeClientPrefaceAndSettings(setup.pair[1]);
    try writeHeadersFrameFd(allocator, setup.pair[1], 1, &.{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "example.com" },
        .{ .name = ":path", .value = "/padded-empty" },
        .{ .name = "content-length", .value = "1" },
    }, false);
    const empty_padded_payload = [_]u8{0};
    for (0..http2_reading.max_h2_budgeted_frames_per_read + 1) |_|
        try writeFrameFd(setup.pair[1], .data, 0x8, 1, &empty_padded_payload);

    try driveUntilIdle(TestWorker, &worker, &setup.runtime);

    try std.testing.expect(!setup.runtime.isOpen());
    try std.testing.expectEqual(@as(usize, 1), worker.request_count);
    try std.testing.expectEqual(@as(usize, 0), worker.body_len);
    try std.testing.expect(!worker.body_end_stream);
    var out: [8192]u8 = undefined;
    const received = try readAvailableFd(setup.pair[1], &out);
    const goaway = findFrame(received, .goaway, 0) orelse return error.MissingGoaway;
    try std.testing.expectEqual(
        @intFromEnum(h2.ErrorCode.enhance_your_calm),
        readU32(goaway.payload[4..8]),
    );
}

test "http2 stream reservation enforces the advertised concurrency cap not just advertises it" {
    // "http2 driver parses GET headers through socket preface" checks that the
    // SETTINGS frame advertises `max_h2_concurrent_streams`; this test checks
    // that the stream reservation enforces it against a client that ignores
    // the advertisement. A stream past the cap is refused alone:
    // `startDynamicH2` in `server/ingress/runner/admission.zig` answers it with
    // RST_STREAM REFUSED_STREAM.
    const allocator = std.testing.allocator;
    var runtime = Slot{ .slab_link = .{ .live = true }, .streams = &sharedLane().streams };
    defer runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);

    var stream_id: u32 = 1;
    var opened: usize = 0;
    while (opened < stream_table.max_h2_concurrent_streams) : (opened += 1) {
        try runtime.h2ReserveStream(stream_id);
        stream_id += 2;
    }
    try std.testing.expectEqual(stream_table.max_h2_concurrent_streams, runtime.ingress_channel_count);

    // The reservation one past the cap fails, and the streams already open
    // keep their count and their state.
    try std.testing.expectError(error.Http2TooManyConcurrentStreams, runtime.h2ReserveStream(stream_id));
    try std.testing.expectEqual(stream_table.max_h2_concurrent_streams, runtime.ingress_channel_count);
    try std.testing.expectEqual(@as(?stream_table.H2StreamState, .preparing), runtime.h2StreamState(1));
}

test "http2 sixty-four streams held and answered on one connection draw no REFUSED_STREAM (#30)" {
    // RFC 9113 §5.1.2 stops counting a stream once both ends have sent
    // END_STREAM, and a client may open the next stream as soon as a
    // response ends, before the lane has finished the request behind it. So
    // a stream leaves the cap when its response's END_STREAM is queued after
    // the request's, not when the lane removes the request.
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };
    const cap = stream_table.max_h2_concurrent_streams;
    var out: [16 * 1024]u8 = undefined;

    try writeClientPrefaceAndSettings(setup.pair[1]);
    var stream_id: u32 = 1;
    for (0..cap) |_| {
        try writeGetFd(allocator, setup.pair[1], stream_id, "/held");
        stream_id += 2;
    }
    try driveUntilIdle(TestWorker, &worker, &setup.runtime);
    try std.testing.expectEqual(cap, worker.request_count);
    try std.testing.expectEqual(@as(usize, 0), worker.refused_count);

    // While every held request is open, one more stream is refused alone.
    try writeGetFd(allocator, setup.pair[1], stream_id, "/one-too-many");
    try driveUntilIdle(TestWorker, &worker, &setup.runtime);
    try std.testing.expect(setup.runtime.isOpen());
    try std.testing.expectEqual(@as(usize, 1), worker.refused_count);
    var received = try readAvailableFd(setup.pair[1], &out);
    const refused = findFrame(received, .rst_stream, stream_id) orelse return error.MissingRefusedStream;
    try std.testing.expectEqual(@intFromEnum(h2.ErrorCode.refused_stream), readU32(refused.payload[0..4]));
    stream_id += 2;

    // Every held stream gets its worker's whole response and leaves the
    // table, while the lane has finished none of the requests.
    var held: u32 = 1;
    while (held < 2 * cap) : (held += 2)
        try queueWorkerAnswer(&worker, &setup.runtime, held, "done");
    received = try readAvailableFd(setup.pair[1], &out);
    try std.testing.expectEqual(cap, countFrames(received, .headers));
    try std.testing.expectEqual(@as(usize, 0), setup.runtime.ingress_channel_count);

    // A new stream for each answered one: every one starts.
    const first_new_stream_id = stream_id;
    for (0..cap) |_| {
        try writeGetFd(allocator, setup.pair[1], stream_id, "/next");
        stream_id += 2;
    }
    try driveUntilIdle(TestWorker, &worker, &setup.runtime);
    try std.testing.expect(setup.runtime.isOpen());
    try std.testing.expectEqual(2 * cap, worker.request_count);
    try std.testing.expectEqual(@as(usize, 1), worker.refused_count);
    received = try readAvailableFd(setup.pair[1], &out);
    try std.testing.expectEqual(@as(usize, 0), countFrames(received, .rst_stream));

    // The lane finishes the first requests afterwards. Their streams are
    // gone, and the new streams stay open.
    for (1..cap + 1) |slot| {
        const release = setup.runtime.h2RemoveRequest(allocator, .{ .lane_id = 0, .slot = @intCast(slot), .generation = 1 });
        try std.testing.expectEqual(stream_table.StreamRelease.none, release);
    }
    try std.testing.expectEqual(@as(?stream_table.H2StreamState, .active), setup.runtime.h2StreamState(first_new_stream_id));
    try std.testing.expectEqual(@as(?stream_table.H2StreamState, .active), setup.runtime.h2StreamState(stream_id - 2));
}

test "http2 streams answered as their heads arrive leave the concurrency count, so a client opens more than the cap in turn (#30)" {
    // Each request ends with its head and is answered inside the stream
    // handler, and the driver closes the stream as soon as the handler
    // returns, so the count never reaches the cap.
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{
        .service = .{ .allocator = allocator },
        .auto_response_mode = .on_headers_end_stream,
    };
    const opened = stream_table.max_h2_concurrent_streams + 8;
    var out: [4096]u8 = undefined;

    try writeClientPrefaceAndSettings(setup.pair[1]);
    var stream_id: u32 = 1;
    for (0..opened) |_| {
        try writeGetFd(allocator, setup.pair[1], stream_id, "/next");
        stream_id += 2;
        try driveUntilIdle(TestWorker, &worker, &setup.runtime);
        const received = try readAvailableFd(setup.pair[1], &out);
        try std.testing.expectEqual(@as(usize, 0), countFrames(received, .rst_stream));
    }
    try std.testing.expect(setup.runtime.isOpen());
    try std.testing.expectEqual(opened, worker.request_count);
    try std.testing.expectEqual(opened, worker.response_count);
    try std.testing.expectEqual(@as(usize, 0), worker.refused_count);
    try std.testing.expectEqual(@as(usize, 0), setup.runtime.ingress_channel_count);
}

test "http2 a stream stays in the concurrency count until both its response and its request have ended (#30)" {
    const allocator = std.testing.allocator;
    var runtime = Slot{ .slab_link = .{ .live = true }, .streams = &sharedLane().streams };
    defer runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);

    // The response ended first; the request still sends its body.
    const sending_key = RequestKey{ .lane_id = 0, .slot = 1, .generation = 1 };
    try runtime.h2ReserveStream(1);
    try runtime.h2SetRequestBodyExpectation(1, .ingress_channel, null, false);
    try runtime.h2ActivateStream(1, sending_key, 1);
    runtime.h2NoteResponseEndQueued(1);
    try std.testing.expect(!runtime.h2CloseStreamIfDone(allocator, 1));
    try std.testing.expectEqual(@as(usize, 1), runtime.ingress_channel_count);
    try runtime.h2RecordRequestBodyChunk(1, 0, true);
    try std.testing.expect(runtime.h2CloseStreamIfDone(allocator, 1));
    try std.testing.expectEqual(@as(usize, 0), runtime.ingress_channel_count);
    try std.testing.expectEqual(@as(?stream_table.H2StreamState, null), runtime.h2StreamState(1));

    // Both ends are done, but the lane still holds request bytes for the
    // worker, so the stream stays until they leave.
    const holding_key = RequestKey{ .lane_id = 0, .slot = 3, .generation = 1 };
    try runtime.h2ReserveStream(3);
    try runtime.h2SetRequestBodyExpectation(3, .ingress_channel, 2, false);
    try runtime.h2ActivateStream(3, holding_key, 3);
    try runtime.h2ConsumeInboundWindow(3, 2);
    try runtime.h2RecordRequestBodyChunk(3, 2, true);
    try runtime.h2AppendActivePendingBody(allocator, 3, "ab", true, 2);
    runtime.h2NoteResponseEndQueued(3);
    try std.testing.expect(!runtime.h2CloseStreamIfDone(allocator, 3));
    var body = runtime.h2TakePendingBody(3) orelse return error.MissingPendingBody;
    defer body.deinit(allocator);
    try std.testing.expect(runtime.h2CloseStreamIfDone(allocator, 3));
    try std.testing.expectEqual(@as(usize, 0), runtime.ingress_channel_count);
}

test "http2 driver shuts a rapid-reset RST_STREAM flood with enhance your calm" {
    // Rapid reset (CVE-2023-44487): a client churns RST_STREAM frames to force
    // per-stream setup and teardown work without ever growing the concurrent
    // stream count. RST_STREAM counts against the per-read frame budget, so a
    // burst past `max_h2_budgeted_frames_per_read` must end the connection
    // with GOAWAY ENHANCE_YOUR_CALM, the defense the PING and padded empty
    // DATA floods above also hit.
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    try writeClientPrefaceAndSettings(setup.pair[1]);
    // One real stream, so the resets land on a stream the connection has
    // seen. A reset of an idle stream is a connection error of its own
    // (RFC 9113 §6.4), covered by "http2 rst stream before headers is a
    // connection error".
    try writeHeadersFrameFd(allocator, setup.pair[1], 1, &.{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "example.com" },
        .{ .name = ":path", .value = "/reset-flood" },
        .{ .name = "content-length", .value = "10" },
    }, false);
    var reset_payload: [4]u8 = undefined;
    writeU32(&reset_payload, @intFromEnum(h2.ErrorCode.cancel));
    for (0..http2_reading.max_h2_budgeted_frames_per_read + 1) |_|
        try writeFrameFd(setup.pair[1], .rst_stream, 0, 1, &reset_payload);

    try driveUntilIdle(TestWorker, &worker, &setup.runtime);

    try std.testing.expect(!setup.runtime.isOpen());
    var out: [8192]u8 = undefined;
    const received = try readAvailableFd(setup.pair[1], &out);
    const goaway = findFrame(received, .goaway, 0) orelse return error.MissingGoaway;
    try std.testing.expectEqual(
        @intFromEnum(h2.ErrorCode.enhance_your_calm),
        readU32(goaway.payload[4..8]),
    );
}

test "http2 driver ignores inbound ping acknowledgements" {
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    try writeClientPrefaceAndSettings(setup.pair[1]);
    try writeFrameFd(setup.pair[1], .ping, 0x1, 0, "abcdefgh");

    _ = try drive(TestWorker, &worker, &setup.runtime);

    try std.testing.expect(setup.runtime.isOpen());
    var out: [256]u8 = undefined;
    const received = try readAvailableFd(setup.pair[1], &out);
    try std.testing.expect(findFrame(received, .ping, 0) == null);
}

test "http2 driver sends goaway on connection-level frame errors" {
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    try writeClientPrefaceAndSettings(setup.pair[1]);
    var reset_payload = [_]u8{ 0, 0, 0 };
    try writeFrameFd(setup.pair[1], .rst_stream, 0, 1, &reset_payload);

    try driveUntilIdle(TestWorker, &worker, &setup.runtime);

    try std.testing.expect(!setup.runtime.isOpen());
    var out: [256]u8 = undefined;
    const received = try readAvailableFd(setup.pair[1], &out);
    const goaway = findFrame(received, .goaway, 0) orelse return error.MissingGoaway;
    try std.testing.expectEqual(@as(u32, 8), goaway.header.length);
    try std.testing.expectEqual(@as(u32, 0), readU32(goaway.payload[0..4]) & h2.max_window_size);
    try std.testing.expectEqual(@intFromEnum(h2.ErrorCode.frame_size_error), readU32(goaway.payload[4..8]));
}

test "http2 driver closes a connection whose client-sized allocation fails, with GOAWAY INTERNAL_ERROR (#34)" {
    // A header block the client leaves open is buffered whole, in memory
    // the client sized. When that allocation fails, the client loses its
    // connection and `drive` returns, so the lane goes on serving.
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    var refusing = LargeAllocationRefusingAllocator{
        .backing = std.testing.allocator,
        .refused_min_len = 4096,
    };
    // The protocol state is freed with the allocator that grew it.
    defer setup.runtime.deinitProtocolState(refusing.allocator(), &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = refusing.allocator() } };

    // A fragment the server buffers and never decodes, since no END_HEADERS
    // follows it.
    const fragment = try std.testing.allocator.alloc(u8, 7777);
    defer std.testing.allocator.free(fragment);
    @memset(fragment, 0x82);

    try writeClientPrefaceAndSettings(setup.pair[1]);
    try writeFrameFd(setup.pair[1], .headers, 0, 1, fragment);

    try driveUntilIdle(TestWorker, &worker, &setup.runtime);

    try std.testing.expect(!setup.runtime.isOpen());
    try std.testing.expectEqual(fault.ConnectionCloseReason.allocation_failed, worker.close.?.reason);
    try std.testing.expect(refusing.refusals != 0);
    try std.testing.expectEqual(@as(usize, 0), worker.request_count);
    var out: [256]u8 = undefined;
    const received = try readAvailableFd(setup.pair[1], &out);
    const goaway = findFrame(received, .goaway, 0) orelse return error.MissingGoaway;
    try std.testing.expectEqual(@intFromEnum(h2.ErrorCode.internal_error), readU32(goaway.payload[4..8]));
}

test "http2 driver closes a client that stops reading while it widens its windows, without GOAWAY (#34)" {
    // The client's credit releases a response the server buffered while the
    // client reads nothing, so the write queue passes its bound. The full
    // queue is where a GOAWAY would wait, so the connection closes without
    // one, and `drive` returns.
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    try writeClientPrefaceAndSettings(setup.pair[1]);
    _ = try drive(TestWorker, &worker, &setup.runtime);
    var settings_out: [256]u8 = undefined;
    _ = try readAvailableFd(setup.pair[1], &settings_out);

    // A response twice the write queue's bound waits on a stream the client
    // has given no send window.
    setup.runtime.h2_peer_settings.initial_window_size = 0;
    const request_key = RequestKey{ .lane_id = 0, .slot = 1, .generation = 1 };
    try setup.runtime.h2ReserveStream(1);
    try setup.runtime.h2ActivateStream(1, request_key, 1);
    const body = try allocator.alloc(u8, 2 * write_queue.max_queued_write_bytes);
    defer allocator.free(body);
    @memset(body, 'r');
    _ = try queueResponseChunk(TestWorker, &worker, &setup.runtime, 1, body, true);
    try std.testing.expect(setup.runtime.h2HasPendingResponse(1));

    // The client stops reading, then opens the connection's and the stream's
    // windows to the whole body.
    try saturateFd(setup.pair[0]);
    var increment: [4]u8 = undefined;
    writeU32(&increment, @intCast(body.len));
    try writeFrameFd(setup.pair[1], .window_update, 0, 0, &increment);
    try writeFrameFd(setup.pair[1], .window_update, 0, 1, &increment);

    _ = try drive(TestWorker, &worker, &setup.runtime);

    try std.testing.expect(!setup.runtime.isOpen());
    const close = worker.close orelse return error.MissingClose;
    try std.testing.expectEqual(fault.ConnectionCloseReason.write_backpressure, close.reason);
    try std.testing.expect(close.goaway == null);
}

test "http2 driver returns a client descriptor that is not open as the lane's own fault" {
    // Only the lane can hand the driver a descriptor that is not open, so
    // the error belongs to the lane (`classifyConnectionError` in
    // `server/ingress/fault.zig`) and is the one error `drive` returns.
    const allocator = std.testing.allocator;
    var runtime = Slot{
        .slab_link = .{ .live = true },
        .streams = &sharedLane().streams,
        .fd = -1,
        .state = .http2_connection,
    };
    defer runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    try std.testing.expectError(error.NotOpenForReading, drive(TestWorker, &worker, &runtime));
}

test "http2 a client that closes its socket closes the connection without GOAWAY" {
    // The socket a GOAWAY would travel on is the one that ended.
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    try writeClientPrefaceAndSettings(setup.pair[1]);
    try driveUntilIdle(TestWorker, &worker, &setup.runtime);
    try std.testing.expect(setup.runtime.isOpen());
    var out: [512]u8 = undefined;
    _ = try readAvailableFd(setup.pair[1], &out);

    try std.posix.shutdown(setup.pair[1], .send);
    try driveUntilIdle(TestWorker, &worker, &setup.runtime);

    try std.testing.expect(!setup.runtime.isOpen());
    const close = worker.close orelse return error.MissingClose;
    try std.testing.expectEqual(fault.ConnectionCloseReason.peer_closed, close.reason);
    try std.testing.expect(close.goaway == null);
    const received = try readAvailableFd(setup.pair[1], &out);
    try std.testing.expect(findFrame(received, .goaway, 0) == null);
}

test "http2 a connection error met while a request is in flight asks for the close and leaves the stream for the lane to reset" {
    // The driver only takes the decision. The lane's next pass resets every
    // stream the table still holds toward its worker, then tears the
    // connection down (`finishClose` in
    // `server/ingress/runner/connection_flow.zig`), so the stream must still
    // be there, and reset by no one yet.
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    try writeClientPrefaceAndSettings(setup.pair[1]);
    try writeHeadersFrameFd(allocator, setup.pair[1], 1, &.{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "example.com" },
        .{ .name = ":path", .value = "/in-flight" },
    }, false);
    try driveUntilIdle(TestWorker, &worker, &setup.runtime);
    try std.testing.expectEqual(@as(usize, 1), worker.request_count);

    // DATA must name a stream, so DATA on stream 0 is a connection error.
    try writeFrameFd(setup.pair[1], .data, 0, 0, "x");
    try driveUntilIdle(TestWorker, &worker, &setup.runtime);

    try std.testing.expect(!setup.runtime.isOpen());
    try std.testing.expectEqual(fault.ConnectionCloseReason.protocol_error, worker.close.?.reason);
    try std.testing.expectEqual(@as(usize, 0), worker.reset_count);
    try std.testing.expectEqual(@as(?stream_table.H2StreamState, .active), setup.runtime.h2StreamState(1));
    var out: [1024]u8 = undefined;
    const received = try readAvailableFd(setup.pair[1], &out);
    const goaway = findFrame(received, .goaway, 0) orelse return error.MissingGoaway;
    try std.testing.expectEqual(@as(u32, 1), readU32(goaway.payload[0..4]) & h2.max_window_size);
    try std.testing.expectEqual(@intFromEnum(h2.ErrorCode.protocol_error), readU32(goaway.payload[4..8]));
}

test "http2 driver treats invalid stream window update as stream error" {
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    try writeClientPrefaceAndSettings(setup.pair[1]);
    try writeHeadersFrameFd(allocator, setup.pair[1], 1, &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "example.com" },
        .{ .name = ":path", .value = "/window" },
    }, true);
    var increment_zero = [_]u8{ 0, 0, 0, 0 };
    try writeFrameFd(setup.pair[1], .window_update, 0, 1, &increment_zero);

    _ = try drive(TestWorker, &worker, &setup.runtime);

    try std.testing.expect(setup.runtime.isOpen());
    var out: [256]u8 = undefined;
    const received = try readAvailableFd(setup.pair[1], &out);
    const rst = findFrame(received, .rst_stream, 1) orelse return error.MissingRstStream;
    try std.testing.expectEqual(@intFromEnum(h2.ErrorCode.protocol_error), readU32(rst.payload[0..4]));
    try std.testing.expect(findFrame(received, .goaway, 0) == null);
}

test "http2 driver treats stream window overflow as stream error" {
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    try writeClientPrefaceAndSettings(setup.pair[1]);
    try writeHeadersFrameFd(allocator, setup.pair[1], 1, &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "example.com" },
        .{ .name = ":path", .value = "/window-overflow" },
    }, true);
    var increment = [_]u8{0} ** 4;
    writeU32(&increment, h2.max_window_size);
    try writeFrameFd(setup.pair[1], .window_update, 0, 1, &increment);

    _ = try drive(TestWorker, &worker, &setup.runtime);

    try std.testing.expect(setup.runtime.isOpen());
    var out: [512]u8 = undefined;
    const received = try readAvailableFd(setup.pair[1], &out);
    const rst = findFrame(received, .rst_stream, 1) orelse return error.MissingRstStream;
    try std.testing.expectEqual(@intFromEnum(h2.ErrorCode.flow_control_error), readU32(rst.payload[0..4]));
    try std.testing.expect(findFrame(received, .goaway, 0) == null);
}

test "http2 driver validates unsupported client push promise as connection error" {
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    try writeClientPrefaceAndSettings(setup.pair[1]);
    var promised_stream = [_]u8{ 0, 0, 0, 2 };
    try writeFrameFd(setup.pair[1], .push_promise, 0x4, 1, &promised_stream);

    try driveUntilIdle(TestWorker, &worker, &setup.runtime);

    try std.testing.expect(!setup.runtime.isOpen());
    var out: [256]u8 = undefined;
    const received = try readAvailableFd(setup.pair[1], &out);
    const goaway = findFrame(received, .goaway, 0) orelse return error.MissingGoaway;
    try std.testing.expectEqual(@intFromEnum(h2.ErrorCode.protocol_error), readU32(goaway.payload[4..8]));
}

test "http2 response data queues behind outbound flow-control window" {
    const allocator = std.testing.allocator;
    var sink = try std.fs.openFileAbsolute("/dev/null", .{ .mode = .write_only });
    defer sink.close();

    var runtime = Slot{
        .slab_link = .{ .live = true },
        .streams = &sharedLane().streams,
        .fd = sink.handle,
    };
    defer runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    const request_key = RequestKey{ .lane_id = 0, .slot = 1, .generation = 1 };
    try runtime.h2ReserveStream(1);
    try runtime.h2ActivateStream(1, request_key, 1);

    const body = try allocator.alloc(u8, h2.default_initial_window_size + 16);
    defer allocator.free(body);
    @memset(body, 'x');

    _ = try queueResponseChunk(TestWorker, &worker, &runtime, 1, body, true);

    try std.testing.expectEqual(@as(i64, 0), runtime.h2_connection_send_window);
    try std.testing.expectEqual(@as(usize, 16), runtime.h2PendingResponseSlice(1).?.len);
    try std.testing.expect(runtime.h2PendingResponseEndsStream(1));

    try runtime.h2IncreaseConnectionSendWindow(16);
    try runtime.h2IncreaseStreamSendWindow(1, 16);
    _ = try flushPendingResponseData(TestWorker, &worker, &runtime, 1);

    try std.testing.expect(!runtime.h2HasPendingResponse(1));
    try std.testing.expectEqual(@as(?stream_table.H2StreamState, .active), runtime.h2StreamState(1));
}

test "http2 pending response flush rotates streams round robin" {
    const allocator = std.testing.allocator;
    var sink = try std.fs.openFileAbsolute("/dev/null", .{ .mode = .write_only });
    defer sink.close();

    var runtime = Slot{
        .slab_link = .{ .live = true },
        .streams = &sharedLane().streams,
        .fd = sink.handle,
        .h2_connection_send_window = 0,
    };
    defer runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    const request_key_1 = RequestKey{ .lane_id = 0, .slot = 1, .generation = 1 };
    const request_key_3 = RequestKey{ .lane_id = 0, .slot = 3, .generation = 1 };
    const request_key_5 = RequestKey{ .lane_id = 0, .slot = 5, .generation = 1 };
    try runtime.h2ReserveStream(1);
    try runtime.h2ActivateStream(1, request_key_1, 1);
    try runtime.h2ReserveStream(3);
    try runtime.h2ActivateStream(3, request_key_3, 3);
    try runtime.h2ReserveStream(5);
    try runtime.h2ActivateStream(5, request_key_5, 5);

    try runtime.h2AppendPendingResponse(allocator, 1, "aa", false);
    try runtime.h2AppendPendingResponse(allocator, 3, "bb", false);
    try runtime.h2AppendPendingResponse(allocator, 5, "cc", false);

    try runtime.h2IncreaseConnectionSendWindow(1);
    _ = try flushPendingResponseData(TestWorker, &worker, &runtime, null);
    try std.testing.expectEqualStrings("a", runtime.h2PendingResponseSlice(1).?);
    try std.testing.expectEqualStrings("bb", runtime.h2PendingResponseSlice(3).?);
    try std.testing.expectEqualStrings("cc", runtime.h2PendingResponseSlice(5).?);
    try std.testing.expectEqual(@as(usize, 1), runtime.h2_response_rr_cursor);

    try runtime.h2IncreaseConnectionSendWindow(1);
    _ = try flushPendingResponseData(TestWorker, &worker, &runtime, null);
    try std.testing.expectEqualStrings("a", runtime.h2PendingResponseSlice(1).?);
    try std.testing.expectEqualStrings("b", runtime.h2PendingResponseSlice(3).?);
    try std.testing.expectEqualStrings("cc", runtime.h2PendingResponseSlice(5).?);
    try std.testing.expectEqual(@as(usize, 2), runtime.h2_response_rr_cursor);

    try runtime.h2IncreaseConnectionSendWindow(1);
    _ = try flushPendingResponseData(TestWorker, &worker, &runtime, null);
    try std.testing.expectEqualStrings("a", runtime.h2PendingResponseSlice(1).?);
    try std.testing.expectEqualStrings("b", runtime.h2PendingResponseSlice(3).?);
    try std.testing.expectEqualStrings("c", runtime.h2PendingResponseSlice(5).?);
    try std.testing.expectEqual(@as(usize, 3), runtime.h2_response_rr_cursor);
}

test "http2 pending response drops prefixes with cursor instead of memmove" {
    const allocator = std.testing.allocator;
    var sink = try std.fs.openFileAbsolute("/dev/null", .{ .mode = .write_only });
    defer sink.close();

    var runtime = Slot{
        .slab_link = .{ .live = true },
        .streams = &sharedLane().streams,
        .fd = sink.handle,
        .h2_connection_send_window = 0,
    };
    defer runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    const request_key = RequestKey{ .lane_id = 0, .slot = 12, .generation = 1 };
    try runtime.h2ReserveStream(19);
    try runtime.h2ActivateStream(19, request_key, 19);

    _ = try queueResponseChunk(TestWorker, &worker, &runtime, 19, "abcdefghij", false);
    try std.testing.expectEqualStrings("abcdefghij", runtime.h2PendingResponseSlice(19).?);
    try std.testing.expectEqual(@as(usize, 0), runtime.streamAt(0).pending_response_start);

    try runtime.h2DropPendingResponsePrefix(allocator, 19, 3);
    try std.testing.expectEqualStrings("defghij", runtime.h2PendingResponseSlice(19).?);
    try std.testing.expectEqual(@as(usize, 3), runtime.streamAt(0).pending_response_start);
    try std.testing.expectEqual(@as(usize, 7), runtime.h2_pending_response_bytes);

    _ = try queueResponseChunk(TestWorker, &worker, &runtime, 19, "kl", true);
    try std.testing.expectEqualStrings("defghijkl", runtime.h2PendingResponseSlice(19).?);
    try std.testing.expect(runtime.h2PendingResponseEndsStream(19));
    try std.testing.expectEqual(@as(usize, 3), runtime.streamAt(0).pending_response_start);
    try std.testing.expectEqual(@as(usize, 9), runtime.h2_pending_response_bytes);

    try runtime.h2DropPendingResponsePrefix(allocator, 19, 9);
    try std.testing.expect(!runtime.h2HasPendingResponse(19));
    try std.testing.expectEqual(@as(usize, 0), runtime.streamAt(0).pending_response_start);
    try std.testing.expectEqual(@as(usize, 0), runtime.streamAt(0).pending_response.len);
    try std.testing.expectEqual(@as(usize, 0), runtime.h2_pending_response_bytes);
}

test "http2 response backpressure rejects unbounded pending stream data" {
    const allocator = std.testing.allocator;
    var sink = try std.fs.openFileAbsolute("/dev/null", .{ .mode = .write_only });
    defer sink.close();

    var runtime = Slot{
        .slab_link = .{ .live = true },
        .streams = &sharedLane().streams,
        .fd = sink.handle,
        .h2_connection_send_window = 0,
    };
    defer runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    const request_key = RequestKey{ .lane_id = 0, .slot = 9, .generation = 1 };
    try runtime.h2ReserveStream(15);
    try runtime.h2ActivateStream(15, request_key, 15);

    const body = try allocator.alloc(u8, write_queue.max_h2_pending_response_bytes_per_stream + 1);
    defer allocator.free(body);
    @memset(body, 'z');

    try std.testing.expectError(
        error.Http2PendingResponseTooLarge,
        queueResponseChunk(TestWorker, &worker, &runtime, 15, body, true),
    );
    try std.testing.expect(!runtime.h2HasPendingResponse(15));
    try std.testing.expectEqual(@as(usize, 0), runtime.h2_pending_response_bytes);
}

test "http2 reset releases pending response bytes immediately" {
    const allocator = std.testing.allocator;
    var sink = try std.fs.openFileAbsolute("/dev/null", .{ .mode = .write_only });
    defer sink.close();

    var runtime = Slot{
        .slab_link = .{ .live = true },
        .streams = &sharedLane().streams,
        .fd = sink.handle,
        .h2_connection_send_window = 0,
    };
    defer runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    const request_key = RequestKey{ .lane_id = 0, .slot = 10, .generation = 1 };
    try runtime.h2ReserveStream(17);
    try runtime.h2ActivateStream(17, request_key, 17);

    _ = try queueResponseChunk(TestWorker, &worker, &runtime, 17, "pending bytes", true);
    try std.testing.expect(runtime.h2HasPendingResponse(17));
    try std.testing.expectEqual(@as(usize, "pending bytes".len), runtime.h2_pending_response_bytes);

    const reset_key = runtime.h2MarkStreamReset(allocator, 17) orelse return error.MissingResetRequestKey;
    try std.testing.expect(reset_key.eql(request_key));
    try std.testing.expect(!runtime.h2HasPendingResponse(17));
    try std.testing.expectEqual(@as(usize, 0), runtime.h2_pending_response_bytes);
    try std.testing.expectEqual(@as(?stream_table.H2StreamState, null), runtime.h2StreamState(17));

    // The stream left the table with the reset, so the lane finishing the
    // request later finds no stream to end.
    try std.testing.expectEqual(stream_table.StreamRelease.none, runtime.h2RemoveRequest(allocator, request_key));
}

test "http2 worker-death synthetic error drains failed stream while peer stream continues" {
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    const failed_key = RequestKey{ .lane_id = 0, .slot = 31, .generation = 1 };
    const peer_key = RequestKey{ .lane_id = 0, .slot = 32, .generation = 1 };
    try setup.runtime.h2ReserveStream(1);
    try setup.runtime.h2ActivateStream(1, failed_key, 31);
    try setup.runtime.h2ReserveStream(3);
    try setup.runtime.h2ActivateStream(3, peer_key, 32);

    (setup.runtime.h2StreamEntry(1) orelse return error.MissingStream).send_window = 0;

    const error_headers = [_]ipc.ingress_channel.ResponseHeader{
        .{ .name = "content-type", .value = "text/plain" },
    };
    _ = try queueResponseHeadAndChunk(TestWorker, &worker, &setup.runtime, 1, 502, &error_headers, "bad gateway", true);
    try std.testing.expectEqual(stream_table.StreamRelease.draining, setup.runtime.h2RemoveRequest(allocator, failed_key));
    try std.testing.expectEqual(@as(?stream_table.H2StreamState, .draining_response), setup.runtime.h2StreamState(1));
    try std.testing.expectEqualStrings("bad gateway", setup.runtime.h2PendingResponseSlice(1).?);
    try std.testing.expect(setup.runtime.h2PendingResponseEndsStream(1));
    try std.testing.expectEqual(@as(?stream_table.H2StreamState, .active), setup.runtime.h2StreamState(3));

    const peer_headers = [_]ipc.ingress_channel.ResponseHeader{
        .{ .name = "x-peer", .value = "survived" },
    };
    _ = try queueResponseHeadAndChunk(TestWorker, &worker, &setup.runtime, 3, 200, &peer_headers, "ok", true);

    var out: [2048]u8 = undefined;
    const received = try readAvailableFd(setup.pair[1], &out);
    try std.testing.expect(findFrame(received, .goaway, 0) == null);
    try expectResponseHeader(allocator, received, 1, "502", "content-type", "text/plain");
    try expectResponseHeader(allocator, received, 3, "200", "x-peer", "survived");
    try expectResponseBody(received, 3, "ok");

    try setup.runtime.h2IncreaseStreamSendWindow(1, @intCast("bad gateway".len));
    _ = try flushPendingResponseData(TestWorker, &worker, &setup.runtime, 1);

    try std.testing.expectEqual(@as(?stream_table.H2StreamState, null), setup.runtime.h2StreamState(1));
    try std.testing.expectEqual(@as(?stream_table.H2StreamState, .active), setup.runtime.h2StreamState(3));
}

test "http2 a dead worker's buffered response delivers its tail only when END_STREAM is among the bytes (#42)" {
    // When a worker dies after its head went out, the lane resets the stream
    // unless the bytes still buffered for it end it
    // (`h2StreamWillDeliverResponseTail`). Bytes without END_STREAM would
    // drain and leave the client waiting for an end that never comes.
    const allocator = std.testing.allocator;
    var sink = try std.fs.openFileAbsolute("/dev/null", .{ .mode = .write_only });
    defer sink.close();

    var runtime = Slot{
        .slab_link = .{ .live = true },
        .streams = &sharedLane().streams,
        .fd = sink.handle,
        .h2_connection_send_window = 0,
    };
    defer runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    const cut_key = RequestKey{ .lane_id = 0, .slot = 1, .generation = 1 };
    const whole_key = RequestKey{ .lane_id = 0, .slot = 2, .generation = 1 };
    const quiet_key = RequestKey{ .lane_id = 0, .slot = 3, .generation = 1 };
    try runtime.h2ReserveStream(1);
    try runtime.h2ActivateStream(1, cut_key, 1);
    try runtime.h2ReserveStream(3);
    try runtime.h2ActivateStream(3, whole_key, 3);
    try runtime.h2ReserveStream(5);
    try runtime.h2ActivateStream(5, quiet_key, 5);

    // Heads are not flow controlled and go out; with no connection window
    // every body byte stays buffered.
    _ = try http2_writing.queueResponseHead(TestWorker, &worker, &runtime, 1, 200, &.{}, false);
    _ = try queueResponseChunk(TestWorker, &worker, &runtime, 1, "the first half", false);
    _ = try http2_writing.queueResponseHead(TestWorker, &worker, &runtime, 3, 200, &.{}, false);
    _ = try queueResponseChunk(TestWorker, &worker, &runtime, 3, "the whole body", true);
    _ = try http2_writing.queueResponseHead(TestWorker, &worker, &runtime, 5, 200, &.{}, false);
    try std.testing.expect(runtime.h2HasPendingResponse(1));
    try std.testing.expect(runtime.h2HasPendingResponse(3));

    try std.testing.expect(!runtime.h2StreamWillDeliverResponseTail(cut_key));
    try std.testing.expect(runtime.h2StreamWillDeliverResponseTail(whole_key));
    // A stream with nothing buffered has no tail to deliver either.
    try std.testing.expect(!runtime.h2StreamWillDeliverResponseTail(quiet_key));

    // An END_STREAM that arrives after the bytes completes the tail.
    _ = try queueResponseChunk(TestWorker, &worker, &runtime, 1, "", true);
    try std.testing.expect(runtime.h2StreamWillDeliverResponseTail(cut_key));
}

test "http2 a request that leaves its stream closes it, drains a tail that carries END_STREAM, or drops what never ended (#42)" {
    // `h2RemoveRequest` answers `unfinished` for a response that cannot end
    // on its own, and the lane resets that stream.
    const allocator = std.testing.allocator;
    var sink = try std.fs.openFileAbsolute("/dev/null", .{ .mode = .write_only });
    defer sink.close();

    var runtime = Slot{
        .slab_link = .{ .live = true },
        .streams = &sharedLane().streams,
        .fd = sink.handle,
        .h2_connection_send_window = 0,
    };
    defer runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    const cut_key = RequestKey{ .lane_id = 0, .slot = 1, .generation = 1 };
    const whole_key = RequestKey{ .lane_id = 0, .slot = 2, .generation = 1 };
    const ended_key = RequestKey{ .lane_id = 0, .slot = 3, .generation = 1 };
    try runtime.h2ReserveStream(1);
    try runtime.h2ActivateStream(1, cut_key, 1);
    try runtime.h2ReserveStream(3);
    try runtime.h2ActivateStream(3, whole_key, 3);
    try runtime.h2ReserveStream(5);
    try runtime.h2ActivateStream(5, ended_key, 5);

    // With no connection window every body byte stays buffered, while a
    // head, which flow control does not hold, ends stream 5 at once.
    _ = try http2_writing.queueResponseHead(TestWorker, &worker, &runtime, 1, 200, &.{}, false);
    _ = try queueResponseChunk(TestWorker, &worker, &runtime, 1, "the first half", false);
    _ = try http2_writing.queueResponseHead(TestWorker, &worker, &runtime, 3, 200, &.{}, false);
    _ = try queueResponseChunk(TestWorker, &worker, &runtime, 3, "the whole body", true);
    _ = try http2_writing.queueResponseHead(TestWorker, &worker, &runtime, 5, 204, &.{}, true);

    try std.testing.expectEqual(stream_table.StreamRelease.unfinished, runtime.h2RemoveRequest(allocator, cut_key));
    try std.testing.expectEqual(@as(?stream_table.H2StreamState, null), runtime.h2StreamState(1));
    try std.testing.expectEqual(@as(usize, "the whole body".len), runtime.h2_pending_response_bytes);

    try std.testing.expectEqual(stream_table.StreamRelease.draining, runtime.h2RemoveRequest(allocator, whole_key));
    try std.testing.expectEqual(@as(?stream_table.H2StreamState, .draining_response), runtime.h2StreamState(3));

    try std.testing.expectEqual(stream_table.StreamRelease.closed, runtime.h2RemoveRequest(allocator, ended_key));
    try std.testing.expectEqual(@as(?stream_table.H2StreamState, null), runtime.h2StreamState(5));

    // A request no stream holds any more ends nothing.
    try std.testing.expectEqual(stream_table.StreamRelease.none, runtime.h2RemoveRequest(allocator, cut_key));
    try std.testing.expectEqual(@as(usize, 1), runtime.ingress_channel_count);
}

test "http2 combined response head and chunk frames in one queued write" {
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    const request_key = RequestKey{ .lane_id = 0, .slot = 3, .generation = 1 };
    try setup.runtime.h2ReserveStream(5);
    try setup.runtime.h2ActivateStream(5, request_key, 5);

    const headers = [_]ipc.ingress_channel.ResponseHeader{
        .{ .name = "content-type", .value = "text/plain" },
    };
    _ = try queueResponseHeadAndChunk(TestWorker, &worker, &setup.runtime, 5, 200, &headers, "ok", true);

    var out: [256]u8 = undefined;
    const received = try readAvailableFd(setup.pair[1], &out);
    const header_frame = try h2.FrameHeader.parse(received[0..h2.frame_header_len]);
    try std.testing.expectEqual(h2.FrameType.headers, header_frame.frame_type);
    try std.testing.expectEqual(@as(u32, 5), header_frame.stream_id);
    try std.testing.expect(!header_frame.flags.end_stream);
    try std.testing.expect(header_frame.flags.end_headers_or_ack);

    const data_offset = h2.frame_header_len + @as(usize, header_frame.length);
    const data_frame = try h2.FrameHeader.parse(received[data_offset..][0..h2.frame_header_len]);
    try std.testing.expectEqual(h2.FrameType.data, data_frame.frame_type);
    try std.testing.expectEqual(@as(u32, 5), data_frame.stream_id);
    try std.testing.expect(data_frame.flags.end_stream);
    try std.testing.expectEqual(@as(u32, 2), data_frame.length);
    try std.testing.expectEqualStrings("ok", received[data_offset + h2.frame_header_len ..][0..2]);
    try std.testing.expectEqual(@as(i64, h2.default_initial_window_size - 2), setup.runtime.h2_connection_send_window);
}

test "http2 explicit response end emits empty data end stream" {
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    const request_key = RequestKey{ .lane_id = 0, .slot = 4, .generation = 1 };
    try setup.runtime.h2ReserveStream(7);
    try setup.runtime.h2ActivateStream(7, request_key, 7);

    const headers = [_]ipc.ingress_channel.ResponseHeader{
        .{ .name = "x-empty", .value = "yes" },
    };
    _ = try http2_writing.queueResponseHead(TestWorker, &worker, &setup.runtime, 7, 204, &headers, false);
    _ = try queueResponseChunk(TestWorker, &worker, &setup.runtime, 7, "", true);

    var out: [256]u8 = undefined;
    const received = try readAvailableFd(setup.pair[1], &out);
    const header_frame = try h2.FrameHeader.parse(received[0..h2.frame_header_len]);
    try std.testing.expectEqual(h2.FrameType.headers, header_frame.frame_type);
    try std.testing.expectEqual(@as(u32, 7), header_frame.stream_id);
    try std.testing.expect(!header_frame.flags.end_stream);
    try std.testing.expect(header_frame.flags.end_headers_or_ack);

    const data_offset = h2.frame_header_len + @as(usize, header_frame.length);
    const data_frame = try h2.FrameHeader.parse(received[data_offset..][0..h2.frame_header_len]);
    try std.testing.expectEqual(h2.FrameType.data, data_frame.frame_type);
    try std.testing.expectEqual(@as(u32, 7), data_frame.stream_id);
    try std.testing.expect(data_frame.flags.end_stream);
    try std.testing.expectEqual(@as(u32, 0), data_frame.length);
    try std.testing.expectEqual(data_offset + h2.frame_header_len, received.len);
}

test "http2 a response head the encoder fails midway poisons it, and the connection's next answer closes it with GOAWAY COMPRESSION_ERROR" {
    // The encoder stops inside the oversized head, which leaves its table
    // out of step with the client's decoder, and it refuses every later
    // head. The call that met the failure returns it for its caller to sort
    // (`fault.classifyResponseQueueError`); an answer the lane writes itself
    // closes the connection on the spot.
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    // The connection speaks HTTP/2, so its close can carry a GOAWAY.
    setup.runtime.frame_reader.preface_len = h2.client_connection_preface.len;
    setup.runtime.h2_last_client_stream_id = 9;
    const request_key = RequestKey{ .lane_id = 0, .slot = 5, .generation = 1 };
    try setup.runtime.h2ReserveStream(9);
    try setup.runtime.h2ActivateStream(9, request_key, 9);

    const large = try allocator.alloc(u8, 64 * 1024 - 1);
    defer allocator.free(large);
    @memset(large, '~');
    const headers = [_]ipc.ingress_channel.ResponseHeader{
        .{ .name = "x-large", .value = large },
    };

    try std.testing.expectError(
        error.HpackEncoderPoisoned,
        http2_writing.queueResponseHead(TestWorker, &worker, &setup.runtime, 9, 200, &headers, true),
    );
    try std.testing.expectError(error.HpackEncoderPoisoned, setup.runtime.h2_hpack_encoder.encodeHeadersScratch(allocator, &.{
        .{ .name = ":status", .value = "200" },
    }, 1024));
    try std.testing.expect(setup.runtime.isOpen());

    try std.testing.expect(!try http2_writing.queueServerResponse(TestWorker, &worker, &setup.runtime, 9, .{
        .status = 502,
        .reason = "Bad Gateway",
        .body = "bad gateway",
    }));
    try std.testing.expect(!setup.runtime.isOpen());
    try std.testing.expectEqual(fault.ConnectionCloseReason.compression_error, worker.close.?.reason);
    _ = try http2_writing.flushPendingWrite(TestWorker, &worker, &setup.runtime);

    var out: [64]u8 = undefined;
    const received = try readAvailableFd(setup.pair[1], &out);
    const goaway = findFrame(received, .goaway, 0) orelse return error.MissingGoaway;
    try std.testing.expectEqual(@as(u32, 9), readU32(goaway.payload[0..4]) & h2.max_window_size);
    try std.testing.expectEqual(@intFromEnum(h2.ErrorCode.compression_error), readU32(goaway.payload[4..8]));
}

test "http2 worker response descriptor pair queues fused headers and data frames" {
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    const request_key = RequestKey{ .lane_id = 3, .slot = 19, .generation = 7 };
    try setup.runtime.h2ReserveStream(13);
    try setup.runtime.h2ActivateStream(13, request_key, 9001);
    const identity = ipc.ingress_channel.RequestIdentity{
        .request_id = 9001,
        .request_generation = request_key.generation,
        .request_lane_id = request_key.lane_id,
        .request_slot = request_key.slot,
    };

    const headers = [_]ipc.ingress_channel.ResponseHeader{
        .{ .name = "x-worker", .value = "fast" },
    };
    var head_scratch: [512]u8 = undefined;
    const head_payload = try ipc.ingress_channel.encodeResponseHeadInto(&head_scratch, 201, &headers);
    var body_payload = [_]u8{ 'd', 'o', 'n', 'e' };

    var head_descriptor = ipc.ingress_channel.Descriptor.responseHead(identity, 13, 0, @intCast(head_payload.len), 201, @intCast(headers.len), false);
    head_descriptor.flag_bits |= ipc.ingress_channel.flags.inline_bytes;
    var chunk_descriptor = ipc.ingress_channel.Descriptor.responseChunk(identity, 13, 0, @intCast(body_payload.len), true);
    chunk_descriptor.flag_bits |= ipc.ingress_channel.flags.inline_bytes;

    var items = [_]ipc.ingress_channel.Received{
        .{
            .allocator = allocator,
            .descriptor = head_descriptor,
            .payload = head_payload,
            .payload_owned = false,
        },
        .{
            .allocator = allocator,
            .descriptor = chunk_descriptor,
            .payload = body_payload[0..],
            .payload_owned = false,
        },
    };

    try std.testing.expect(!setup.runtime.responseHeadQueued(13));
    const queued = (try tryQueueWorkerResponseHeadChunkPair(TestWorker, &worker, &setup.runtime, &items)) orelse return error.WorkerResponsePairNotRecognized;
    try std.testing.expectEqual(@as(usize, 2), queued.consumed_descriptors);
    try std.testing.expectEqual(@as(usize, body_payload.len), queued.body_bytes);
    try std.testing.expect(setup.runtime.responseHeadQueued(13));

    var out: [512]u8 = undefined;
    const received = try readAvailableFd(setup.pair[1], &out);
    try expectResponseHeader(allocator, received, 13, "201", "x-worker", "fast");
    try expectResponseBody(received, 13, "done");

    var late_end_received = ipc.ingress_channel.Received{
        .allocator = allocator,
        .descriptor = ipc.ingress_channel.Descriptor.responseEnd(identity, 13),
        .payload_owned = false,
    };
    try std.testing.expectError(
        error.InvalidH2WorkerOutboundDescriptor,
        queueWorkerResponseDescriptor(TestWorker, &worker, &setup.runtime, &late_end_received),
    );
}

test "http2 worker response descriptor identity must match active stream" {
    const allocator = std.testing.allocator;
    var sink = try std.fs.openFileAbsolute("/dev/null", .{ .mode = .write_only });
    defer sink.close();

    var runtime = Slot{
        .slab_link = .{ .live = true },
        .streams = &sharedLane().streams,
        .fd = sink.handle,
    };
    defer runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    const request_key = RequestKey{ .lane_id = 3, .slot = 19, .generation = 7 };
    try runtime.h2ReserveStream(13);
    try runtime.h2ActivateStream(13, request_key, 9001);

    var wrong_request_id = ipc.ingress_channel.Descriptor.responseChunk(.{
        .request_id = 9002,
        .request_generation = request_key.generation,
        .request_lane_id = request_key.lane_id,
        .request_slot = request_key.slot,
    }, 13, 0, 0, true);
    wrong_request_id.flag_bits |= ipc.ingress_channel.flags.inline_bytes;
    var received = ipc.ingress_channel.Received{
        .allocator = allocator,
        .descriptor = wrong_request_id,
        .payload = "",
        .payload_owned = false,
    };
    try std.testing.expectError(
        error.InvalidH2StreamIdentity,
        queueWorkerResponseDescriptor(TestWorker, &worker, &runtime, &received),
    );

    var wrong_generation = ipc.ingress_channel.Descriptor.responseChunk(.{
        .request_id = 9001,
        .request_generation = request_key.generation + 1,
        .request_lane_id = request_key.lane_id,
        .request_slot = request_key.slot,
    }, 13, 0, 0, true);
    wrong_generation.flag_bits |= ipc.ingress_channel.flags.inline_bytes;
    received.descriptor = wrong_generation;
    try std.testing.expectError(
        error.InvalidH2StreamIdentity,
        queueWorkerResponseDescriptor(TestWorker, &worker, &runtime, &received),
    );
}

test "http2 worker response descriptors enforce head body end ordering" {
    const allocator = std.testing.allocator;
    var sink = try std.fs.openFileAbsolute("/dev/null", .{ .mode = .write_only });
    defer sink.close();

    var runtime = Slot{
        .slab_link = .{ .live = true },
        .streams = &sharedLane().streams,
        .fd = sink.handle,
    };
    defer runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    const request_key = RequestKey{ .lane_id = 4, .slot = 21, .generation = 8 };
    const identity = ipc.ingress_channel.RequestIdentity{
        .request_id = 9010,
        .request_generation = request_key.generation,
        .request_lane_id = request_key.lane_id,
        .request_slot = request_key.slot,
    };
    try runtime.h2ReserveStream(13);
    try runtime.h2ActivateStream(13, request_key, identity.request_id);

    var chunk_payload = [_]u8{'x'};
    var chunk_descriptor = ipc.ingress_channel.Descriptor.responseChunk(identity, 13, 0, @intCast(chunk_payload.len), false);
    chunk_descriptor.flag_bits |= ipc.ingress_channel.flags.inline_bytes;
    var chunk_received = ipc.ingress_channel.Received{
        .allocator = allocator,
        .descriptor = chunk_descriptor,
        .payload = chunk_payload[0..],
        .payload_owned = false,
    };
    try std.testing.expectError(
        error.InvalidH2WorkerOutboundDescriptor,
        queueWorkerResponseDescriptor(TestWorker, &worker, &runtime, &chunk_received),
    );

    const headers = [_]ipc.ingress_channel.ResponseHeader{
        .{ .name = "x-worker", .value = "ordered" },
    };
    var head_scratch: [512]u8 = undefined;
    const head_payload = try ipc.ingress_channel.encodeResponseHeadInto(&head_scratch, 200, &headers);
    var head_descriptor = ipc.ingress_channel.Descriptor.responseHead(identity, 13, 0, @intCast(head_payload.len), 200, @intCast(headers.len), false);
    head_descriptor.flag_bits |= ipc.ingress_channel.flags.inline_bytes;
    var head_received = ipc.ingress_channel.Received{
        .allocator = allocator,
        .descriptor = head_descriptor,
        .payload = head_payload,
        .payload_owned = false,
    };
    _ = try queueWorkerResponseDescriptor(TestWorker, &worker, &runtime, &head_received);
    try std.testing.expectError(
        error.InvalidH2WorkerOutboundDescriptor,
        queueWorkerResponseDescriptor(TestWorker, &worker, &runtime, &head_received),
    );

    const end_before_head_key = RequestKey{ .lane_id = 4, .slot = 22, .generation = 8 };
    const end_before_head_identity = ipc.ingress_channel.RequestIdentity{
        .request_id = 9011,
        .request_generation = end_before_head_key.generation,
        .request_lane_id = end_before_head_key.lane_id,
        .request_slot = end_before_head_key.slot,
    };
    try runtime.h2ReserveStream(15);
    try runtime.h2ActivateStream(15, end_before_head_key, end_before_head_identity.request_id);
    var early_end_received = ipc.ingress_channel.Received{
        .allocator = allocator,
        .descriptor = ipc.ingress_channel.Descriptor.responseEnd(end_before_head_identity, 15),
        .payload_owned = false,
    };
    try std.testing.expectError(
        error.InvalidH2WorkerOutboundDescriptor,
        queueWorkerResponseDescriptor(TestWorker, &worker, &runtime, &early_end_received),
    );

    const ended_key = RequestKey{ .lane_id = 4, .slot = 23, .generation = 8 };
    const ended_identity = ipc.ingress_channel.RequestIdentity{
        .request_id = 9012,
        .request_generation = ended_key.generation,
        .request_lane_id = ended_key.lane_id,
        .request_slot = ended_key.slot,
    };
    try runtime.h2ReserveStream(17);
    try runtime.h2ActivateStream(17, ended_key, ended_identity.request_id);
    var final_head_descriptor = ipc.ingress_channel.Descriptor.responseHead(ended_identity, 17, 0, @intCast(head_payload.len), 200, @intCast(headers.len), true);
    final_head_descriptor.flag_bits |= ipc.ingress_channel.flags.inline_bytes;
    var final_head_received = ipc.ingress_channel.Received{
        .allocator = allocator,
        .descriptor = final_head_descriptor,
        .payload = head_payload,
        .payload_owned = false,
    };
    _ = try queueWorkerResponseDescriptor(TestWorker, &worker, &runtime, &final_head_received);
    var late_chunk_descriptor = ipc.ingress_channel.Descriptor.responseChunk(ended_identity, 17, 0, @intCast(chunk_payload.len), true);
    late_chunk_descriptor.flag_bits |= ipc.ingress_channel.flags.inline_bytes;
    chunk_received.descriptor = late_chunk_descriptor;
    try std.testing.expectError(
        error.InvalidH2WorkerOutboundDescriptor,
        queueWorkerResponseDescriptor(TestWorker, &worker, &runtime, &chunk_received),
    );
}

test "http2 worker response reset queues rst stream after committed head" {
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    const request_key = RequestKey{ .lane_id = 6, .slot = 24, .generation = 12 };
    try setup.runtime.h2ReserveStream(21);
    try setup.runtime.h2ActivateStream(21, request_key, 9021);
    const identity = ipc.ingress_channel.RequestIdentity{
        .request_id = 9021,
        .request_generation = request_key.generation,
        .request_lane_id = request_key.lane_id,
        .request_slot = request_key.slot,
    };

    const headers = [_]ipc.ingress_channel.ResponseHeader{
        .{ .name = "x-worker", .value = "reset" },
    };
    var head_scratch: [512]u8 = undefined;
    const head_payload = try ipc.ingress_channel.encodeResponseHeadInto(&head_scratch, 200, &headers);
    var head_descriptor = ipc.ingress_channel.Descriptor.responseHead(
        identity,
        21,
        0,
        @intCast(head_payload.len),
        200,
        @intCast(headers.len),
        false,
    );
    head_descriptor.flag_bits |= ipc.ingress_channel.flags.inline_bytes;
    var head_received = ipc.ingress_channel.Received{
        .allocator = allocator,
        .descriptor = head_descriptor,
        .payload = head_payload,
        .payload_owned = false,
    };
    _ = try queueWorkerResponseDescriptor(TestWorker, &worker, &setup.runtime, &head_received);

    var reset_received = ipc.ingress_channel.Received{
        .allocator = allocator,
        .descriptor = ipc.ingress_channel.Descriptor.responseReset(
            identity,
            21,
            @intFromEnum(h2.ErrorCode.internal_error),
        ),
        .payload_owned = false,
    };
    _ = try queueWorkerResponseDescriptor(TestWorker, &worker, &setup.runtime, &reset_received);

    var out: [512]u8 = undefined;
    const received = try readAvailableFd(setup.pair[1], &out);
    try expectResponseHeader(allocator, received, 21, "200", "x-worker", "reset");
    const rst = findFrame(received, .rst_stream, 21) orelse return error.MissingRstStream;
    try std.testing.expectEqual(@as(u32, 4), rst.header.length);
    try std.testing.expectEqual(@intFromEnum(h2.ErrorCode.internal_error), readU32(rst.payload));
}

test "http2 worker response descriptors queue split head chunk and explicit end" {
    const allocator = std.testing.allocator;
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    const request_key = RequestKey{ .lane_id = 5, .slot = 23, .generation = 11 };
    try setup.runtime.h2ReserveStream(15);
    try setup.runtime.h2ActivateStream(15, request_key, 9002);
    const identity = ipc.ingress_channel.RequestIdentity{
        .request_id = 9002,
        .request_generation = request_key.generation,
        .request_lane_id = request_key.lane_id,
        .request_slot = request_key.slot,
    };

    const headers = [_]ipc.ingress_channel.ResponseHeader{
        .{ .name = "x-worker", .value = "split" },
    };
    var head_scratch: [512]u8 = undefined;
    const head_payload = try ipc.ingress_channel.encodeResponseHeadInto(&head_scratch, 204, &headers);
    var body_payload = [_]u8{ 'o', 'k' };

    var head_descriptor = ipc.ingress_channel.Descriptor.responseHead(identity, 15, 0, @intCast(head_payload.len), 204, @intCast(headers.len), false);
    head_descriptor.flag_bits |= ipc.ingress_channel.flags.inline_bytes;
    var chunk_descriptor = ipc.ingress_channel.Descriptor.responseChunk(identity, 15, 0, @intCast(body_payload.len), false);
    chunk_descriptor.flag_bits |= ipc.ingress_channel.flags.inline_bytes;
    const end_descriptor = ipc.ingress_channel.Descriptor.responseEnd(identity, 15);

    var head_received = ipc.ingress_channel.Received{
        .allocator = allocator,
        .descriptor = head_descriptor,
        .payload = head_payload,
        .payload_owned = false,
    };
    var chunk_received = ipc.ingress_channel.Received{
        .allocator = allocator,
        .descriptor = chunk_descriptor,
        .payload = body_payload[0..],
        .payload_owned = false,
    };
    var end_received = ipc.ingress_channel.Received{
        .allocator = allocator,
        .descriptor = end_descriptor,
        .payload_owned = false,
    };

    _ = try queueWorkerResponseDescriptor(TestWorker, &worker, &setup.runtime, &head_received);
    const chunk_result = try queueWorkerResponseDescriptor(TestWorker, &worker, &setup.runtime, &chunk_received);
    const end_result = try queueWorkerResponseDescriptor(TestWorker, &worker, &setup.runtime, &end_received);
    try std.testing.expectEqual(@as(usize, body_payload.len), chunk_result.body_bytes);
    try std.testing.expectEqual(@as(usize, 0), end_result.body_bytes);

    var out: [512]u8 = undefined;
    const received = try readAvailableFd(setup.pair[1], &out);
    try expectResponseHeader(allocator, received, 15, "204", "x-worker", "split");

    const first_data = findFrame(received, .data, 15) orelse return error.MissingResponseData;
    try std.testing.expect(!first_data.header.flags.end_stream);
    try std.testing.expectEqual(@as(u32, body_payload.len), first_data.header.length);
    try std.testing.expectEqualStrings("ok", first_data.payload);

    const end_offset = @intFromPtr(first_data.payload.ptr) + first_data.payload.len - @intFromPtr(received.ptr);
    const end_frame = try h2.FrameHeader.parse(received[end_offset..][0..h2.frame_header_len]);
    try std.testing.expectEqual(h2.FrameType.data, end_frame.frame_type);
    try std.testing.expectEqual(@as(u32, 15), end_frame.stream_id);
    try std.testing.expect(end_frame.flags.end_stream);
    try std.testing.expectEqual(@as(u32, 0), end_frame.length);
}

test "http2 the lane's record of a worker's head turns true when the head is queued and only then" {
    // `responseHeadQueued` is the one source the lane reads to choose between
    // a 502 and RST_STREAM for a request whose worker failed, never a flag
    // the worker wrote.
    const allocator = std.testing.allocator;
    var sink = try std.fs.openFileAbsolute("/dev/null", .{ .mode = .write_only });
    defer sink.close();

    var runtime = Slot{
        .slab_link = .{ .live = true },
        .streams = &sharedLane().streams,
        .fd = sink.handle,
    };
    defer runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    const request_key = RequestKey{ .lane_id = 2, .slot = 7, .generation = 3 };
    const identity = ipc.ingress_channel.RequestIdentity{
        .request_id = 9031,
        .request_generation = request_key.generation,
        .request_lane_id = request_key.lane_id,
        .request_slot = request_key.slot,
    };
    try runtime.h2ReserveStream(23);
    try runtime.h2ActivateStream(23, request_key, identity.request_id);
    try std.testing.expect(!runtime.responseHeadQueued(23));
    // A stream the connection never opened has no head.
    try std.testing.expect(!runtime.responseHeadQueued(25));

    // A refused head leaves the record as it was.
    var refused_received = ipc.ingress_channel.Received{
        .allocator = allocator,
        .descriptor = ipc.ingress_channel.Descriptor.responseEnd(identity, 23),
        .payload_owned = false,
    };
    try std.testing.expectError(
        error.InvalidH2WorkerOutboundDescriptor,
        queueWorkerResponseDescriptor(TestWorker, &worker, &runtime, &refused_received),
    );
    try std.testing.expect(!runtime.responseHeadQueued(23));

    const headers = [_]ipc.ingress_channel.ResponseHeader{
        .{ .name = "x-worker", .value = "head" },
    };
    var head_scratch: [512]u8 = undefined;
    const head_payload = try ipc.ingress_channel.encodeResponseHeadInto(&head_scratch, 200, &headers);
    var head_descriptor = ipc.ingress_channel.Descriptor.responseHead(identity, 23, 0, @intCast(head_payload.len), 200, @intCast(headers.len), false);
    head_descriptor.flag_bits |= ipc.ingress_channel.flags.inline_bytes;
    var head_received = ipc.ingress_channel.Received{
        .allocator = allocator,
        .descriptor = head_descriptor,
        .payload = head_payload,
        .payload_owned = false,
    };
    _ = try queueWorkerResponseDescriptor(TestWorker, &worker, &runtime, &head_received);
    try std.testing.expect(runtime.responseHeadQueued(23));
}

test "http2 response headers reject invalid names and values before framing" {
    const allocator = std.testing.allocator;
    var sink = try std.fs.openFileAbsolute("/dev/null", .{ .mode = .write_only });
    defer sink.close();

    var runtime = Slot{
        .slab_link = .{ .live = true },
        .streams = &sharedLane().streams,
        .fd = sink.handle,
    };
    defer runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    const invalid_headers = [_][]const ipc.ingress_channel.ResponseHeader{
        &.{.{ .name = "X-Mode", .value = "h2" }},
        &.{.{ .name = ":path", .value = "/" }},
        &.{.{ .name = "transfer-encoding", .value = "chunked" }},
        &.{.{ .name = "x-test", .value = "ok\r\nbad" }},
        &.{.{ .name = "x-test", .value = "\x7f" }},
    };

    for (invalid_headers) |headers| {
        try std.testing.expectError(
            error.InvalidHttp2ResponseHeader,
            http2_writing.queueResponseHead(TestWorker, &worker, &runtime, 13, 200, headers, true),
        );
    }
}

test "http2 completed active request drains pending response before removing stream" {
    const allocator = std.testing.allocator;
    var sink = try std.fs.openFileAbsolute("/dev/null", .{ .mode = .write_only });
    defer sink.close();

    var runtime = Slot{
        .slab_link = .{ .live = true },
        .streams = &sharedLane().streams,
        .fd = sink.handle,
    };
    defer runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };

    const request_key = RequestKey{ .lane_id = 0, .slot = 2, .generation = 1 };
    try runtime.h2ReserveStream(3);
    try runtime.h2ActivateStream(3, request_key, 3);

    const body = try allocator.alloc(u8, h2.default_initial_window_size + 8);
    defer allocator.free(body);
    @memset(body, 'y');

    _ = try queueResponseChunk(TestWorker, &worker, &runtime, 3, body, true);
    try std.testing.expectEqual(stream_table.StreamRelease.draining, runtime.h2RemoveRequest(allocator, request_key));
    try std.testing.expectEqual(@as(?stream_table.H2StreamState, .draining_response), runtime.h2StreamState(3));

    try runtime.h2IncreaseConnectionSendWindow(8);
    try runtime.h2IncreaseStreamSendWindow(3, 8);
    _ = try flushPendingResponseData(TestWorker, &worker, &runtime, 3);

    try std.testing.expectEqual(@as(?stream_table.H2StreamState, null), runtime.h2StreamState(3));
}

test "http2 local server response drains when peer stream window is closed" {
    const allocator = std.testing.allocator;
    var sink = try std.fs.openFileAbsolute("/dev/null", .{ .mode = .write_only });
    defer sink.close();

    var runtime = Slot{
        .slab_link = .{ .live = true },
        .streams = &sharedLane().streams,
        .fd = sink.handle,
    };
    defer runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };
    runtime.h2_peer_settings.initial_window_size = 0;
    try runtime.h2ReserveStream(9);

    const headers = [_]ipc.ingress_channel.ResponseHeader{
        .{ .name = "content-type", .value = "text/plain" },
    };
    _ = try queueResponseHeadAndChunk(TestWorker, &worker, &runtime, 9, 503, &headers, "busy", true);

    try std.testing.expectEqual(@as(?stream_table.H2StreamState, .preparing), runtime.h2StreamState(9));
    try std.testing.expectEqualStrings("busy", runtime.h2PendingResponseSlice(9).?);
    try std.testing.expect(runtime.h2PendingResponseEndsStream(9));

    try std.testing.expect(runtime.h2FinishLocalResponse(allocator, 9));
    try std.testing.expectEqual(@as(?stream_table.H2StreamState, .draining_response), runtime.h2StreamState(9));

    try runtime.h2IncreaseStreamSendWindow(9, 4);
    _ = try flushPendingResponseData(TestWorker, &worker, &runtime, 9);

    try std.testing.expectEqual(@as(?stream_table.H2StreamState, null), runtime.h2StreamState(9));
}

test "http2 active request detached for server response keeps pending data draining" {
    const allocator = std.testing.allocator;
    var sink = try std.fs.openFileAbsolute("/dev/null", .{ .mode = .write_only });
    defer sink.close();

    var runtime = Slot{
        .slab_link = .{ .live = true },
        .streams = &sharedLane().streams,
        .fd = sink.handle,
    };
    defer runtime.deinitProtocolState(allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = allocator } };
    runtime.h2_peer_settings.initial_window_size = 0;
    const request_key = RequestKey{ .lane_id = 0, .slot = 8, .generation = 2 };
    try runtime.h2ReserveStream(11);
    try runtime.h2ActivateStream(11, request_key, 11);

    _ = try queueResponseChunk(TestWorker, &worker, &runtime, 11, "late", true);
    const detached_key = runtime.h2DetachActiveRequestForLocalResponse(allocator, 11) orelse return error.MissingDetachedRequest;

    try std.testing.expect(detached_key.eql(request_key));
    try std.testing.expectEqual(@as(?stream_table.H2StreamState, .draining_response), runtime.h2StreamState(11));
    try std.testing.expectEqualStrings("late", runtime.h2PendingResponseSlice(11).?);
    try std.testing.expect(runtime.h2PendingResponseEndsStream(11));

    try runtime.h2IncreaseStreamSendWindow(11, 4);
    _ = try flushPendingResponseData(TestWorker, &worker, &runtime, 11);

    try std.testing.expectEqual(@as(?stream_table.H2StreamState, null), runtime.h2StreamState(11));
}

test "http2 response data frames fragment and end stream on final frame" {
    const allocator = std.testing.allocator;
    const bytes = try encodeDataFrames(allocator, 4, 3, "abcdef", true);
    defer allocator.free(bytes);

    try std.testing.expectEqual(@as(usize, 24), bytes.len);

    const first = try h2.FrameHeader.parse(bytes[0..h2.frame_header_len]);
    try std.testing.expectEqual(h2.FrameType.data, first.frame_type);
    try std.testing.expectEqual(@as(u32, 4), first.length);
    try std.testing.expectEqual(@as(u32, 3), first.stream_id);
    try std.testing.expect(!first.flags.end_stream);
    try std.testing.expectEqualStrings("abcd", bytes[h2.frame_header_len..][0..4]);

    const second_offset = h2.frame_header_len + 4;
    const second = try h2.FrameHeader.parse(bytes[second_offset..][0..h2.frame_header_len]);
    try std.testing.expectEqual(h2.FrameType.data, second.frame_type);
    try std.testing.expectEqual(@as(u32, 2), second.length);
    try std.testing.expect(second.flags.end_stream);
    try std.testing.expectEqualStrings("ef", bytes[second_offset + h2.frame_header_len ..][0..2]);
}

test "http2 response header block fragments through continuation frames" {
    const allocator = std.testing.allocator;
    const block = "abcdef";
    const bytes = try encodeHeadersFrames(allocator, 4, 5, block, false);
    defer allocator.free(bytes);

    try std.testing.expectEqual(@as(usize, 24), bytes.len);

    const first = try h2.FrameHeader.parse(bytes[0..h2.frame_header_len]);
    try std.testing.expectEqual(h2.FrameType.headers, first.frame_type);
    try std.testing.expectEqual(@as(u32, 4), first.length);
    try std.testing.expectEqual(@as(u32, 5), first.stream_id);
    try std.testing.expect(!first.flags.end_stream);
    try std.testing.expect(!first.flags.end_headers_or_ack);
    try std.testing.expectEqualStrings("abcd", bytes[h2.frame_header_len..][0..4]);

    const second_offset = h2.frame_header_len + 4;
    const second = try h2.FrameHeader.parse(bytes[second_offset..][0..h2.frame_header_len]);
    try std.testing.expectEqual(h2.FrameType.continuation, second.frame_type);
    try std.testing.expectEqual(@as(u32, 2), second.length);
    try std.testing.expectEqual(@as(u32, 5), second.stream_id);
    try std.testing.expect(second.flags.end_headers_or_ack);
    try std.testing.expectEqualStrings("ef", bytes[second_offset + h2.frame_header_len ..][0..2]);
}

test "http2 combined headers and data encoder uses one output allocation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });

    const bytes = try encodeHeadersAndDataFrames(failing.allocator(), 4, 5, "abc", false, "abcdef", true);
    defer failing.allocator().free(bytes);

    const headers = try encodeHeadersFrames(std.testing.allocator, 4, 5, "abc", false);
    defer std.testing.allocator.free(headers);
    const data = try encodeDataFrames(std.testing.allocator, 4, 5, "abcdef", true);
    defer std.testing.allocator.free(data);

    try std.testing.expectEqual(headers.len + data.len, bytes.len);
    try std.testing.expectEqualSlices(u8, headers, bytes[0..headers.len]);
    try std.testing.expectEqualSlices(u8, data, bytes[headers.len..]);
}

test "http2 response data direct writev avoids heap allocation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var sink = try std.fs.openFileAbsolute("/dev/null", .{ .mode = .write_only });
    defer sink.close();

    var runtime = Slot{
        .slab_link = .{ .live = true },
        .streams = &sharedLane().streams,
        .fd = sink.handle,
    };
    defer runtime.deinitProtocolState(failing.allocator(), &shared_lane.header_blocks);
    runtime.h2_peer_settings.max_frame_size = 4;
    var worker = TestWorker{ .service = .{ .allocator = failing.allocator() } };
    try runtime.h2ReserveStream(7);

    _ = try queueResponseChunk(TestWorker, &worker, &runtime, 7, "abcdef", true);

    try std.testing.expect(runtime.isOpen());
    try std.testing.expectEqual(@as(usize, 0), runtime.h2_write_len);
    try std.testing.expectEqual(@as(usize, 0), runtime.h2_write_offset);
    try std.testing.expectEqual(@as(usize, 0), runtime.h2_write_queue.items.len);
    try std.testing.expectEqual(@as(i64, h2.default_initial_window_size - 6), runtime.h2_connection_send_window);
}

test "http2 empty data end stream uses fixed write buffer without heap allocation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var sink = try std.fs.openFileAbsolute("/dev/null", .{ .mode = .write_only });
    defer sink.close();

    var runtime = Slot{
        .slab_link = .{ .live = true },
        .streams = &sharedLane().streams,
        .fd = sink.handle,
    };
    defer runtime.deinitProtocolState(failing.allocator(), &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = failing.allocator() } };
    try runtime.h2ReserveStream(7);

    _ = try queueResponseChunk(TestWorker, &worker, &runtime, 7, "", true);

    try std.testing.expect(runtime.isOpen());
    try std.testing.expectEqual(@as(usize, 0), runtime.h2_write_len);
    try std.testing.expectEqual(@as(usize, 0), runtime.h2_write_offset);
    try std.testing.expectEqual(@as(usize, 0), runtime.h2_write_queue.items.len);
}

test "http2 small control frames use fixed write buffer without heap allocation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var sink = try std.fs.openFileAbsolute("/dev/null", .{ .mode = .write_only });
    defer sink.close();

    var runtime = Slot{
        .slab_link = .{ .live = true },
        .streams = &sharedLane().streams,
        .fd = sink.handle,
    };
    defer runtime.deinitProtocolState(failing.allocator(), &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = failing.allocator() } };

    try http2_writing.queueRstStream(TestWorker, &worker, &runtime, 7, .cancel);

    try std.testing.expect(runtime.isOpen());
    try std.testing.expectEqual(@as(usize, 0), runtime.h2_write_len);
    try std.testing.expectEqual(@as(usize, 0), runtime.h2_write_offset);
    try std.testing.expectEqual(@as(usize, 0), runtime.h2_write_queue.items.len);
}

test "http2 pending writes remain segmented when socket backpressures" {
    var setup = try newH2SocketPairRuntime();
    defer std.posix.close(setup.pair[0]);
    defer std.posix.close(setup.pair[1]);
    defer setup.runtime.deinitProtocolState(std.testing.allocator, &shared_lane.header_blocks);
    var worker = TestWorker{ .service = .{ .allocator = std.testing.allocator } };

    try saturateFd(setup.pair[0]);
    try http2_writing.queueRstStream(TestWorker, &worker, &setup.runtime, 7, .cancel);
    try http2_writing.queueRstStream(TestWorker, &worker, &setup.runtime, 9, .cancel);

    try std.testing.expect(setup.runtime.h2_write_inline_active);
    try std.testing.expectEqual(@as(usize, 1), setup.runtime.h2_write_queue.items.len);
    try std.testing.expectEqual(@as(usize, 0), setup.runtime.h2_write_queue_start);
    try std.testing.expectEqual(@as(usize, (h2.frame_header_len + 4) * 2), setup.runtime.h2_write_len);
    try std.testing.expectEqual(@as(usize, 0), setup.runtime.h2_write_offset);
    try std.testing.expect(!setup.runtime.h2_write_inline_segment.owned);
    try std.testing.expect(setup.runtime.h2_write_queue.items[0].owned);
}

test "http2 rst stream frame encodes recoverable stream errors" {
    var bytes: [h2.frame_header_len + 4]u8 = undefined;
    try encodeRstStreamFrame(&bytes, 7, .protocol_error);

    const header = try h2.FrameHeader.parse(bytes[0..h2.frame_header_len]);
    try std.testing.expectEqual(h2.FrameType.rst_stream, header.frame_type);
    try std.testing.expectEqual(@as(u32, 4), header.length);
    try std.testing.expectEqual(@as(u32, 7), header.stream_id);
    try std.testing.expectEqual(@intFromEnum(h2.ErrorCode.protocol_error), readU32(bytes[h2.frame_header_len..][0..4]));
}

test "http2 goaway frame encodes last stream and error" {
    var bytes: [h2.frame_header_len + 8]u8 = undefined;
    try encodeGoawayFrame(&bytes, 17, .protocol_error);

    const header = try h2.FrameHeader.parse(bytes[0..h2.frame_header_len]);
    try std.testing.expectEqual(h2.FrameType.goaway, header.frame_type);
    try std.testing.expectEqual(@as(u32, 8), header.length);
    try std.testing.expectEqual(@as(u32, 0), header.stream_id);
    try std.testing.expectEqual(@as(u32, 17), readU32(bytes[h2.frame_header_len..][0..4]) & h2.max_window_size);
    try std.testing.expectEqual(@intFromEnum(h2.ErrorCode.protocol_error), readU32(bytes[h2.frame_header_len + 4 ..][0..4]));
}

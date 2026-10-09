//! The checks a worker response descriptor passes on its h2 stream entry
//! (`h2ValidateWorkerResponse*` and `h2MarkWorkerResponse*` in
//! `ingress/runner/stream_table.zig`): the stream must be active, the
//! descriptor must carry the stream's request identity, generation included,
//! and a response is one head, then its body, and nothing after END_STREAM.
//! A reset stream leaves the table, so a descriptor that races the reset
//! finds no stream. `ingress/http2/writing.zig` runs every descriptor
//! `ingress/runner/h2_worker_ipc.zig` receives through them before it queues
//! a frame, so a check that lets a wrong descriptor through puts one
//! request's response on another's stream. The same entry is the lane's one
//! record of whether a response head went out (`responseHeadQueued`), which
//! decides between a 502 and RST_STREAM when the request's worker fails.
//! The queue path suites in `tests/http2/connection.zig` (lane
//! `h2-transport-test`) reach the checks by queueing; this file calls them
//! directly, on a stream that is still preparing or already reset too. Lane
//! `server-ingress-test`.

const std = @import("std");
const server_main = @import("collo_server_main");
const ipc = @import("collo_ipc");

const Slot = server_main.ingress.runner.connection_slot.Slot;
const LaneResources = server_main.ingress.http2.lane_resources.LaneResources;
const RequestKey = server_main.lifecycle.RequestKey;

const stream_id: u32 = 5;
const request_key = RequestKey{ .lane_id = 2, .slot = 9, .generation = 3 };
const request_id: u64 = 7001;

/// A connection slot over lane resources of its own, as a lane's
/// connections sit over the lane's stream slab.
const TestConnection = struct {
    lane: LaneResources,
    runtime: Slot,

    fn init(self: *TestConnection) !void {
        self.lane = try LaneResources.init(64);
        self.runtime = .{ .streams = &self.lane.streams };
    }

    fn deinit(self: *TestConnection) void {
        self.runtime.deinitProtocolState(std.testing.allocator, &self.lane.header_blocks);
        self.lane.deinit();
    }
};

fn matchingIdentity() ipc.ingress_channel.RequestIdentity {
    return .{
        .request_id = request_id,
        .request_generation = request_key.generation,
        .request_lane_id = request_key.lane_id,
        .request_slot = request_key.slot,
    };
}

fn headDescriptor(identity: ipc.ingress_channel.RequestIdentity, end_stream: bool) ipc.ingress_channel.Descriptor {
    return ipc.ingress_channel.Descriptor.responseHead(identity, stream_id, 0, 0, 200, 0, end_stream);
}

fn chunkDescriptor(identity: ipc.ingress_channel.RequestIdentity, end_stream: bool) ipc.ingress_channel.Descriptor {
    return ipc.ingress_channel.Descriptor.responseChunk(identity, stream_id, 0, 0, end_stream);
}

test "worker response descriptor for an unknown stream is Http2UnknownStream" {
    var connection: TestConnection = undefined;
    try connection.init();
    defer connection.deinit();
    const runtime = &connection.runtime;
    // No stream reserved: the validator must not read a vacant slot as active.
    try std.testing.expectError(
        error.Http2UnknownStream,
        runtime.h2ValidateWorkerResponseDescriptor(headDescriptor(matchingIdentity(), true)),
    );
}

test "worker response descriptor on a non-active stream is rejected" {
    var connection: TestConnection = undefined;
    try connection.init();
    defer connection.deinit();
    const runtime = &connection.runtime;

    // Reserved but never activated: the server has not dispatched the request
    // yet, so no worker response can belong to the stream.
    try runtime.h2ReserveStream(stream_id);
    try std.testing.expectError(
        error.InvalidH2WorkerOutboundDescriptor,
        runtime.h2ValidateWorkerResponseDescriptor(headDescriptor(matchingIdentity(), true)),
    );
}

test "worker response descriptor with a mismatched identity is InvalidH2StreamIdentity" {
    var connection: TestConnection = undefined;
    try connection.init();
    defer connection.deinit();
    const runtime = &connection.runtime;

    try runtime.h2ReserveStream(stream_id);
    try runtime.h2ActivateStream(stream_id, request_key, request_id);

    // A descriptor with another generation of the same request slot, here the
    // next one, answers a request this stream does not carry.
    var wrong_generation = matchingIdentity();
    wrong_generation.request_generation = request_key.generation + 1;
    try std.testing.expectError(
        error.InvalidH2StreamIdentity,
        runtime.h2ValidateWorkerResponseDescriptor(headDescriptor(wrong_generation, true)),
    );

    var wrong_request_id = matchingIdentity();
    wrong_request_id.request_id = request_id + 1;
    try std.testing.expectError(
        error.InvalidH2StreamIdentity,
        runtime.h2ValidateWorkerResponseDescriptor(headDescriptor(wrong_request_id, true)),
    );

    var wrong_slot = matchingIdentity();
    wrong_slot.request_slot = request_key.slot + 1;
    try std.testing.expectError(
        error.InvalidH2StreamIdentity,
        runtime.h2ValidateWorkerResponseDescriptor(headDescriptor(wrong_slot, true)),
    );
}

test "head-before-body ordering: a body descriptor before any head is rejected" {
    var connection: TestConnection = undefined;
    try connection.init();
    defer connection.deinit();
    const runtime = &connection.runtime;

    try runtime.h2ReserveStream(stream_id);
    try runtime.h2ActivateStream(stream_id, request_key, request_id);

    // No head is queued yet, so a body descriptor would put DATA on the wire
    // before HEADERS.
    try std.testing.expectError(
        error.InvalidH2WorkerOutboundDescriptor,
        runtime.h2ValidateWorkerResponseBodyDescriptor(chunkDescriptor(matchingIdentity(), true)),
    );
}

test "double-head ordering: a second head after the first is rejected" {
    var connection: TestConnection = undefined;
    try connection.init();
    defer connection.deinit();
    const runtime = &connection.runtime;

    try runtime.h2ReserveStream(stream_id);
    try runtime.h2ActivateStream(stream_id, request_key, request_id);

    // The first head passes and is marked queued, as the queue path does.
    try runtime.h2ValidateWorkerResponseHeadDescriptor(headDescriptor(matchingIdentity(), false));
    try runtime.h2MarkWorkerResponseHeadQueued(stream_id, false);

    // A second head would send a second HEADERS frame for one response.
    try std.testing.expectError(
        error.InvalidH2WorkerOutboundDescriptor,
        runtime.h2ValidateWorkerResponseHeadDescriptor(headDescriptor(matchingIdentity(), true)),
    );
    // A body descriptor passes now that the head is queued.
    try runtime.h2ValidateWorkerResponseBodyDescriptor(chunkDescriptor(matchingIdentity(), true));
}

test "after-end ordering: head and body descriptors past END_STREAM are rejected" {
    var connection: TestConnection = undefined;
    try connection.init();
    defer connection.deinit();
    const runtime = &connection.runtime;

    try runtime.h2ReserveStream(stream_id);
    try runtime.h2ActivateStream(stream_id, request_key, request_id);

    // A head that already carries END_STREAM closes the response in one frame.
    try runtime.h2ValidateWorkerResponseHeadDescriptor(headDescriptor(matchingIdentity(), true));
    try runtime.h2MarkWorkerResponseHeadQueued(stream_id, true);

    // Once END_STREAM is sent, RFC 9113 §5.1 allows no further HEADERS or
    // DATA on the stream.
    try std.testing.expectError(
        error.InvalidH2WorkerOutboundDescriptor,
        runtime.h2ValidateWorkerResponseBodyDescriptor(chunkDescriptor(matchingIdentity(), false)),
    );
    try std.testing.expectError(
        error.InvalidH2WorkerOutboundDescriptor,
        runtime.h2ValidateWorkerResponseHeadDescriptor(headDescriptor(matchingIdentity(), false)),
    );
}

test "a worker response descriptor that races a client reset finds no stream" {
    const allocator = std.testing.allocator;
    var connection: TestConnection = undefined;
    try connection.init();
    defer connection.deinit();
    const runtime = &connection.runtime;

    try runtime.h2ReserveStream(stream_id);
    try runtime.h2ActivateStream(stream_id, request_key, request_id);
    // The client's RST_STREAM takes the entry out of the table, so a worker
    // response that races the reset cannot reopen the stream and frame onto
    // it.
    try std.testing.expectEqual(@as(?RequestKey, request_key), runtime.h2MarkStreamReset(allocator, stream_id));

    try std.testing.expectError(
        error.Http2UnknownStream,
        runtime.h2ValidateWorkerResponseDescriptor(headDescriptor(matchingIdentity(), true)),
    );
    try std.testing.expectError(
        error.Http2UnknownStream,
        runtime.h2ValidateWorkerResponseHeadDescriptor(headDescriptor(matchingIdentity(), true)),
    );
    try std.testing.expectError(
        error.Http2UnknownStream,
        runtime.h2ValidateWorkerResponseBodyDescriptor(chunkDescriptor(matchingIdentity(), true)),
    );
}

test "the mark helpers refuse to advance a reset or unopened stream" {
    const allocator = std.testing.allocator;
    var connection: TestConnection = undefined;
    try connection.init();
    defer connection.deinit();
    const runtime = &connection.runtime;

    try runtime.h2ReserveStream(stream_id);
    try runtime.h2ActivateStream(stream_id, request_key, request_id);

    // The mark helpers record the state the validators read, so they refuse
    // the same orders: a body before any head, and anything on a reset stream.
    try std.testing.expectError(
        error.InvalidH2WorkerOutboundDescriptor,
        runtime.h2MarkWorkerResponseBodyQueued(stream_id, false),
    );

    _ = runtime.h2MarkStreamReset(allocator, stream_id);
    try std.testing.expectError(
        error.Http2UnknownStream,
        runtime.h2MarkWorkerResponseHeadQueued(stream_id, false),
    );
}

test "the lane records a response head as gone out from its mark until the stream leaves the table" {
    const allocator = std.testing.allocator;
    var connection: TestConnection = undefined;
    try connection.init();
    defer connection.deinit();
    const runtime = &connection.runtime;

    const paired_stream_id = stream_id + 2;
    const paired_request_key = RequestKey{ .lane_id = 2, .slot = 10, .generation = 1 };
    try runtime.h2ReserveStream(stream_id);
    try runtime.h2ActivateStream(stream_id, request_key, request_id);
    try runtime.h2ReserveStream(paired_stream_id);
    try runtime.h2ActivateStream(paired_stream_id, paired_request_key, request_id + 1);
    try std.testing.expect(!runtime.responseHeadQueued(stream_id));
    try std.testing.expect(!runtime.responseHeadQueued(paired_stream_id));

    // A head marked alone, and a head that shares its packet with the first
    // chunk, both count; the body that follows changes nothing.
    try runtime.h2MarkWorkerResponseHeadQueued(stream_id, false);
    try runtime.h2MarkWorkerResponseHeadChunkPairQueued(paired_stream_id, false);
    try std.testing.expect(runtime.responseHeadQueued(stream_id));
    try std.testing.expect(runtime.responseHeadQueued(paired_stream_id));
    try runtime.h2MarkWorkerResponseBodyQueued(stream_id, true);
    try std.testing.expect(runtime.responseHeadQueued(stream_id));

    _ = runtime.h2MarkStreamReset(allocator, stream_id);
    try std.testing.expect(!runtime.responseHeadQueued(stream_id));
    try std.testing.expect(runtime.responseHeadQueued(paired_stream_id));
}

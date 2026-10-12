//! The `collo_runtime_response_body_stream_settled` export. The bridge calls
//! it from the reactions a read of a response body stream registered
//! (`collo_response_body_stream_read` in
//! `bindings/host_functions/server/fetch/response_body_stream.cpp`), on the
//! worker's VM thread during a microtask drain, under the request that
//! started the read, and `serve/response_body_stream.zig` parks the result
//! on that request. As abi.h requires, the export takes the value on every
//! call.

const bindings = @import("collo_bindings");
const host_adapter = @import("adapter.zig");
const response_body_stream = @import("../serve/response_body_stream.zig");
const response_stream = @import("collo_worker_request").response_stream;

pub export fn collo_runtime_response_body_stream_settled(
    runtime_ptr: ?*anyopaque,
    request_id: u64,
    result: u32,
    value_raw: ?*bindings.RawValue,
) void {
    var value: ?bindings.Value = if (value_raw) |raw| bindings.Value.fromRawOwnedNonNull(raw) else null;
    const runtime = host_adapter.fromOpaque(runtime_ptr) orelse {
        if (value) |*owned| owned.deinit();
        return;
    };
    const settled: response_stream.Result = switch (result) {
        // A chunk that arrives without its value cannot be sent, and skipping
        // it would leave a gap in the body, so it fails the stream.
        bindings.response_body_stream_result_chunk => if (value) |chunk| .{ .chunk = chunk } else .{ .failed = null },
        bindings.response_body_stream_result_done => blk: {
            if (value) |*owned| owned.deinit();
            break :blk .done;
        },
        bindings.response_body_stream_result_error => .{ .failed = value },
        else => {
            if (value) |*owned| owned.deinit();
            return;
        },
    };
    response_body_stream.noteSettled(runtime, request_id, settled);
}

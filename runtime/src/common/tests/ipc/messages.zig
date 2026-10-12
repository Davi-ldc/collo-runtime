//! The field contracts of `common/ipc/messages.zig` that other files carry:
//! the request done statuses through the completion ring and the bound past
//! the last, the runtime boot options' layout and their refusal of a request
//! task capacity below the largest concurrency, the fetch error's cause
//! through its codec and the causes and reserved bytes the decoder refuses,
//! and the pooled upload bytes a session may have in flight. WorkerInit's
//! fields cross the init socket in `../ipc.zig`, beside its descriptor table.

const std = @import("std");
const ipc = @import("collo_ipc");
const page = @import("collo_worker_state").page;

test "the request done statuses 7 to 9 name the endings no request's own code chose" {
    try std.testing.expectEqual(@as(u32, 7), @intFromEnum(ipc.RequestDoneStatus.cpu_exceeded));
    try std.testing.expectEqual(@as(u32, 8), @intFromEnum(ipc.RequestDoneStatus.worker_retiring));
    try std.testing.expectEqual(@as(u32, 9), @intFromEnum(ipc.RequestDoneStatus.worker_stopped));
    try std.testing.expectEqual(@as(u32, 9), page.worker_completion_status_max);
}

test "each new done status crosses the completion ring, and the value past the last is refused at both ends" {
    const fd = try page.createMemfd("ipc-done-statuses");
    defer std.posix.close(fd);
    var view = try page.mapReadWrite(fd);
    defer view.deinit();
    view.initializeCrashDefault();

    const statuses = [_]ipc.RequestDoneStatus{ .cpu_exceeded, .worker_retiring, .worker_stopped };
    for (statuses, 1..) |status, request_id| {
        try view.publishWorkerCompletion(.{
            .external_request_id = request_id,
            .request_lane_id = 1,
            .request_slot = 1,
            .request_generation = 1,
            .worker_id = 1,
            .worker_generation = 1,
            .status = @intFromEnum(status),
            .http_status = 503,
        });
    }
    var out: [statuses.len]page.WorkerCompletionRecord = undefined;
    try std.testing.expectEqual(statuses.len, try view.drainWorkerCompletions(&out));
    for (statuses, out) |status, record| {
        try std.testing.expectEqual(status, std.enums.fromInt(ipc.RequestDoneStatus, record.status).?);
        try std.testing.expectEqual(@as(u16, 503), record.http_status);
    }

    // The worker refuses to publish it, and the drain refuses it written by
    // hand and turns the ring fatal.
    var past = std.mem.zeroes(page.WorkerCompletionPublish);
    past.external_request_id = 9;
    past.status = page.worker_completion_status_max + 1;
    past.http_status = 503;
    try std.testing.expectError(error.InvalidWorkerCompletionStatus, view.publishWorkerCompletion(past));
    past.status = @intFromEnum(ipc.RequestDoneStatus.worker_stopped);
    try view.publishWorkerCompletion(past);
    view.completion_records[statuses.len].status = page.worker_completion_status_max + 1;
    try std.testing.expectError(error.InvalidWorkerCompletionStatus, view.drainWorkerCompletions(out[0..1]));
}

test "the runtime boot options keep no crypto stack size and refuse fewer request tasks than a worker's slots" {
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(ipc.WorkerRuntimeBootOptions));
    try std.testing.expect(!@hasField(ipc.WorkerRuntimeBootOptions, "crypto_thread_stack_bytes"));

    var options = ipc.WorkerRuntimeBootOptions.default();
    try options.validate();
    try std.testing.expect(options.request_task_capacity >= page.LIVE_SLOT_COUNT);

    options.request_task_capacity = page.LIVE_SLOT_COUNT;
    try options.validate();
    options.request_task_capacity = page.LIVE_SLOT_COUNT - 1;
    try std.testing.expectError(error.InvalidWorkerRuntimeOptions, options.validate());
    options.request_task_capacity = 0;
    try std.testing.expectError(error.InvalidWorkerRuntimeOptions, options.validate());
}

test "a fetch error carries its cause through the codec, failed by default" {
    var scratch: [256]u8 = undefined;
    const failed = try ipc.decodeEgressFetchError(try ipc.encodeEgressFetchErrorInto(&scratch, .{
        .fetch_id = 3,
        .body_id = 4,
        .message = "fetch failed: ConnectionRefused",
    }));
    try std.testing.expectEqual(ipc.EgressFetchErrorCause.failed, failed.cause);
    try std.testing.expectEqualStrings("fetch failed: ConnectionRefused", failed.message);

    const denied = try ipc.decodeEgressFetchError(try ipc.encodeEgressFetchErrorInto(&scratch, .{
        .fetch_id = 5,
        .body_id = 6,
        .message = "fetch to https://a.test denied by the network setting",
        .cause = .network_denied,
        .billed_sent_total = 7,
        .ready_at_mono_ns = 8,
    }));
    try std.testing.expectEqual(ipc.EgressFetchErrorCause.network_denied, denied.cause);
    try std.testing.expectEqual(@as(u64, 5), denied.fetch_id);
    try std.testing.expectEqual(@as(u64, 7), denied.billed_sent_total);
    try std.testing.expectEqual(@as(u64, 8), denied.ready_at_mono_ns);
}

test "the fetch error decoder refuses a cause it does not name and a nonzero reserved field" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(ipc.EgressFetchErrorHeader));
    try std.testing.expectEqual(@as(usize, 56), @offsetOf(ipc.EgressFetchErrorHeader, "cause"));
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(ipc.EgressFetchErrorCause.failed));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(ipc.EgressFetchErrorCause.network_denied));

    var scratch: [128]u8 = undefined;
    const encoded = try ipc.encodeEgressFetchErrorInto(&scratch, .{
        .fetch_id = 1,
        .body_id = 2,
        .message = "x",
    });
    const cause_offset = @offsetOf(ipc.EgressFetchErrorHeader, "cause");
    const reserved_offset = @offsetOf(ipc.EgressFetchErrorHeader, "_reserved0");

    // The packet's structs cross as native-endian bytes.
    const native = @import("builtin").cpu.arch.endian();
    std.mem.writeInt(u32, encoded[cause_offset..][0..4], 2, native);
    try std.testing.expectError(error.InvalidEgressPacket, ipc.decodeEgressFetchError(encoded));
    std.mem.writeInt(u32, encoded[cause_offset..][0..4], std.math.maxInt(u32), native);
    try std.testing.expectError(error.InvalidEgressPacket, ipc.decodeEgressFetchError(encoded));

    std.mem.writeInt(u32, encoded[cause_offset..][0..4], 1, native);
    const denied = try ipc.decodeEgressFetchError(encoded);
    try std.testing.expectEqual(ipc.EgressFetchErrorCause.network_denied, denied.cause);
    std.mem.writeInt(u32, encoded[reserved_offset..][0..4], 1, native);
    try std.testing.expectError(error.InvalidEgressPacket, ipc.decodeEgressFetchError(encoded));
}

test "a session may have two pooled request bodies at their ceiling in flight" {
    const fetch_limits = ipc.fetch_limits;
    try std.testing.expectEqual(
        2 * fetch_limits.request_body_pooled_bytes_max,
        fetch_limits.request_body_pooled_in_flight_bytes_max,
    );
}

//! Covers `request/task.zig`: the task token's layout, which crosses the C
//! ABI inside the bindings' `RequestCompletionToken`, and the generation
//! check that keeps a stale token from reaching a reused slot. Runs in
//! `worker-test`.

const std = @import("std");
const bindings = @import("collo_bindings");
const worker_request = @import("collo_worker_request");

test "request task token ABI stays two u32 fields" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(worker_request.task.TaskToken));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(worker_request.task.TaskToken, "slot"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(worker_request.task.TaskToken, "generation"));

    try std.testing.expectEqual(@as(usize, 16), @sizeOf(bindings.RequestIdentity));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(bindings.RequestCompletionToken));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(bindings.RequestCompletionToken, "request_id"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(bindings.RequestCompletionToken, "request_generation"));
}

test "request task table rejects stale token after slot reuse" {
    var dummy_ctx: worker_request.context.RequestContext = undefined;
    var table = try worker_request.task.RequestTaskTable.init(std.testing.allocator, 1);
    defer table.deinit();

    const first = try table.create(.{
        .request_id = 1,
        .request_generation = 1,
        .request_ctx = &dummy_ctx,
    });
    try std.testing.expect(table.get(first) != null);
    table.destroy(first);
    try std.testing.expect(table.get(first) == null);

    const second = try table.create(.{
        .request_id = 2,
        .request_generation = 1,
        .request_ctx = &dummy_ctx,
    });
    try std.testing.expect(second.generation != first.generation);
    try std.testing.expect(table.get(second) != null);
}

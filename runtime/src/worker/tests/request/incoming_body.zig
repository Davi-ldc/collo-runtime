//! Covers `IncomingBody` in `request/context.zig`: a body framed on the
//! ingress channel fills from chunks until its stream ends, and a request
//! without a body starts complete. Runs in the JSC-free `worker-fast-test`
//! lane.

const std = @import("std");
const ipc = @import("collo_ipc");
const worker_request = @import("collo_worker_request");

const request_head = worker_request.head;
const request_context = worker_request.context;

fn parsedHead() request_head.ParsedHead {
    return .{
        .headers = &.{},
        .body_framing = .ingress_channel,
    };
}

test "incoming body materializes ingress-channel chunks until end stream" {
    var parsed = parsedHead();
    var body: request_context.IncomingBody = .{};
    defer body.deinit(std.testing.allocator);

    try body.initFromHead(std.testing.allocator, &parsed);
    try body.beginRead(std.testing.allocator, .{ .task_id = 1, .deferred = .{} });
    try std.testing.expect(!body.isComplete());

    try body.appendH2ReadBytes(std.testing.allocator, "hel", false);
    try std.testing.expect(!body.isComplete());
    try body.appendH2ReadBytes(std.testing.allocator, "lo", true);

    try std.testing.expect(body.isComplete());
    try std.testing.expectEqualStrings("hello", body.textSlice());
}

test "incoming body leaves empty body complete" {
    var parsed = parsedHead();
    parsed.body_framing = .none;

    var body: request_context.IncomingBody = .{};
    defer body.deinit(std.testing.allocator);

    try body.initFromHead(std.testing.allocator, &parsed);
    try std.testing.expect(body.isComplete());
    try body.beginRead(std.testing.allocator, .{ .task_id = 1, .deferred = .{} });
    try std.testing.expectEqualStrings("", body.textSlice());
}

comptime {
    _ = ipc.RequestBodyFraming.ingress_channel;
}

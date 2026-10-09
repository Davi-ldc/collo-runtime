//! Covers `request/head.zig`: the checks a dispatched request head must pass
//! before a handler sees it (lowercase HTTP/2 field names, exactly one
//! `host`, a `content-length` that agrees with the body framing) and the
//! view it returns. Runs in the JSC-free `worker-fast-test` lane.

const std = @import("std");
const ipc = @import("collo_ipc");
const request_head = @import("collo_worker_request").head;

fn dispatchWork(headers: []const ipc.RequestHeader, body_framing: ipc.RequestBodyFraming) !ipc.DispatchWork {
    return ipc.DispatchWork.initOwned(std.testing.allocator, .{
        .request_id = 1,
        .authority = "demo.example.test",
        .deadline_monotonic_ns = 0,
        .method = "POST",
        .path = "/",
        .raw_query = "",
        .request_headers = headers,
        .body_framing = body_framing,
        .route_captures = &.{},
        .route_entry_specifier = "route",
    });
}

fn expectHeadError(
    expected: request_head.Error,
    headers: []const ipc.RequestHeader,
    body_framing: ipc.RequestBodyFraming,
) !void {
    var dispatch = try dispatchWork(headers, body_framing);
    defer dispatch.deinit();
    try std.testing.expectError(expected, request_head.fromDispatchWork(&dispatch));
}

test "a valid head is returned as a view of the dispatch's headers and framing" {
    const headers = [_]ipc.RequestHeader{
        .{ .name = "host", .value = "demo.example.test" },
        .{ .name = "content-type", .value = "text/plain" },
        .{ .name = "content-length", .value = "5" },
    };
    var dispatch = try dispatchWork(&headers, .ingress_channel);
    defer dispatch.deinit();

    const parsed = try request_head.fromDispatchWork(&dispatch);

    try std.testing.expectEqual(@as(usize, 3), parsed.headers.len);
    try std.testing.expectEqualStrings("host", parsed.headers[0].name);
    try std.testing.expectEqualStrings("content-type", parsed.headers[1].name);
    try std.testing.expectEqual(dispatch.request_headers[0].name.ptr, parsed.headers[0].name.ptr);
    try std.testing.expectEqual(dispatch.request_headers[1].value.ptr, parsed.headers[1].value.ptr);
    try std.testing.expectEqual(ipc.RequestBodyFraming.ingress_channel, parsed.body_framing);
}

test "a header name that is not a lowercase HTTP/2 field name fails the head" {
    try expectHeadError(error.InvalidHeaderName, &.{
        .{ .name = "Host", .value = "demo.example.test" },
    }, .none);
    try expectHeadError(error.InvalidHeaderName, &.{
        .{ .name = "host", .value = "demo.example.test" },
        .{ .name = "", .value = "value" },
    }, .none);
    try expectHeadError(error.InvalidHeaderName, &.{
        .{ .name = "host", .value = "demo.example.test" },
        .{ .name = "x bad", .value = "value" },
    }, .none);
}

test "a head needs exactly one host header" {
    try expectHeadError(error.DuplicateHostHeader, &.{
        .{ .name = "host", .value = "demo.example.test" },
        .{ .name = "host", .value = "other.example.test" },
    }, .none);
    try expectHeadError(error.MissingHostHeader, &.{}, .none);
}

test "a head that carries no body may announce only a zero content length" {
    var zero_dispatch = try dispatchWork(&.{
        .{ .name = "host", .value = "demo.example.test" },
        .{ .name = "content-length", .value = "0" },
    }, .none);
    defer zero_dispatch.deinit();
    const parsed = try request_head.fromDispatchWork(&zero_dispatch);
    try std.testing.expectEqual(ipc.RequestBodyFraming.none, parsed.body_framing);

    try expectHeadError(error.InvalidContentLength, &.{
        .{ .name = "host", .value = "demo.example.test" },
        .{ .name = "content-length", .value = "1" },
    }, .none);
}

test "a body on the ingress channel accepts any well-formed content length" {
    var dispatch = try dispatchWork(&.{
        .{ .name = "host", .value = "demo.example.test" },
        .{ .name = "content-length", .value = "11" },
    }, .ingress_channel);
    defer dispatch.deinit();

    const parsed = try request_head.fromDispatchWork(&dispatch);

    try std.testing.expectEqual(ipc.RequestBodyFraming.ingress_channel, parsed.body_framing);
}

test "a malformed or contradictory content length fails the head" {
    try expectHeadError(error.InvalidContentLength, &.{
        .{ .name = "host", .value = "demo.example.test" },
        .{ .name = "content-length", .value = "-1" },
    }, .ingress_channel);
    try expectHeadError(error.InvalidContentLength, &.{
        .{ .name = "host", .value = "demo.example.test" },
        .{ .name = "content-length", .value = "4" },
        .{ .name = "content-length", .value = "5" },
    }, .ingress_channel);

    // Repeating the same value is consistent framing, not a contradiction.
    var repeated = try dispatchWork(&.{
        .{ .name = "host", .value = "demo.example.test" },
        .{ .name = "content-length", .value = "4" },
        .{ .name = "content-length", .value = "4" },
    }, .ingress_channel);
    defer repeated.deinit();
    _ = try request_head.fromDispatchWork(&repeated);
}

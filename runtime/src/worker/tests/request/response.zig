//! Covers the response checks of `request/response_model.zig`: a body over
//! `MATERIALIZED_BODY_BYTES_MAX` and headers over `max_response_header_count`
//! or `max_response_header_bytes` are refused, and a body streamed from a
//! fetch passes. Runs in `worker-test`.

const std = @import("std");
const bindings = @import("collo_bindings");
const worker_request = @import("collo_worker_request");
const limits = @import("collo_limits");

const response_model = worker_request.response_model;

test "response validation rejects oversized bodies and headers" {
    const oversized_body = try std.testing.allocator.alloc(u8, limits.http_body.MATERIALIZED_BODY_BYTES_MAX + 1);
    defer std.testing.allocator.free(oversized_body);
    @memset(oversized_body, 'x');
    try std.testing.expectError(error.ResponseBodyTooLarge, response_model.validate(.{
        .body = .{ .bytes = oversized_body },
    }));

    var many_headers: [response_model.max_response_header_count + 1]response_model.Header = undefined;
    for (&many_headers) |*header| {
        header.* = .{ .name = "x-test", .value = "ok" };
    }
    try std.testing.expectError(error.ResponseHeadersTooLarge, response_model.validate(.{
        .headers = &many_headers,
    }));

    // The byte bound counts names and values together, so a value exactly at
    // the bound goes over it once any name is added.
    const oversized_header = try std.testing.allocator.alloc(
        u8,
        response_model.max_response_header_bytes,
    );
    defer std.testing.allocator.free(oversized_header);
    @memset(oversized_header, 'a');
    try std.testing.expectError(error.ResponseHeadersTooLarge, response_model.validate(.{
        .headers = &.{.{ .name = "x-big", .value = oversized_header }},
    }));
}

test "stream response validation accepts fetch body identity" {
    const identity = bindings.FetchBodyIdentity{
        .request_id = 1,
        .request_generation = 2,
        .fetch_id = 3,
        .body_id = 4,
    };
    try response_model.validate(.{ .status = 200, .body = .{ .fetch_stream = identity } });
}

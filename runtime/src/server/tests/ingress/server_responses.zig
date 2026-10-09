//! The responses the server writes on its own (`ingress/server_responses.zig`):
//! every id's status and body, the bounds on those bodies, and the health
//! answer's status and body for each state it reports. How the lane reads
//! that state is covered in `health_state.zig`, and the answer on the wire
//! by local-e2e. Lane `server-ingress-test`.

const std = @import("std");
const server_main = @import("collo_server_main");

const server_responses = server_main.ingress.server_responses;

test "server-owned response table is the ingress allowlist" {
    const expected = [_]struct {
        id: server_responses.Id,
        status: u16,
        body: []const u8,
    }{
        .{ .id = .bad_request, .status = 400, .body = "bad request" },
        .{ .id = .route_not_found, .status = 404, .body = server_responses.route_not_found_html },
        .{ .id = .payload_too_large, .status = 413, .body = "payload too large" },
        .{ .id = .request_header_fields_too_large, .status = 431, .body = "request header fields too large" },
        .{ .id = .service_unavailable, .status = 503, .body = "service unavailable" },
        .{ .id = .bad_gateway, .status = 502, .body = "bad gateway" },
        .{ .id = .gateway_timeout, .status = 504, .body = "gateway timeout" },
        .{ .id = .internal_error, .status = 500, .body = "internal server error" },
    };

    try std.testing.expectEqual(@as(usize, @intFromEnum(server_responses.Id.count)), expected.len);
    for (expected) |entry| {
        const response = server_responses.get(entry.id);
        try std.testing.expectEqual(entry.status, response.status);
        try std.testing.expectEqualStrings(entry.body, response.body);
    }
}

test "server-owned responses are bounded text bodies" {
    const Id = server_responses.Id;
    var index: usize = 0;
    while (index < @intFromEnum(Id.count)) : (index += 1) {
        const id: Id = @enumFromInt(index);
        const response = server_responses.get(id);
        try std.testing.expect(response.status >= 200);
        try std.testing.expect(response.status <= 599);
        try std.testing.expect(response.reason.len != 0);
        try std.testing.expect(response.body.len != 0);
        // Plain-text server errors stay terse; the one HTML body, the
        // route-not-found page, gets the line-cap-sized budget instead.
        if (std.mem.eql(u8, response.content_type, "text/html; charset=utf-8")) {
            try std.testing.expect(response.body.len <= 4096);
        } else {
            try std.testing.expect(response.body.len <= 64);
        }
    }
}

const healthy: server_responses.HealthState = .{
    .stopping = false,
    .zygote_alive = true,
    .lanes_running = 7,
    .lanes_total = 7,
    .usage_stream_full = false,
};

fn expectHealth(state: server_responses.HealthState, status: u16, body: []const u8) !void {
    var buffer: [server_responses.health_body_bytes_max]u8 = undefined;
    const response = server_responses.health(state, &buffer);
    try std.testing.expectEqual(status, response.status);
    try std.testing.expectEqualStrings("application/json", response.content_type);
    try std.testing.expectEqualStrings(body, response.body);
    // Every body is one JSON object.
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, response.body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}

test "the health answer is 200 with every lane counted while the server can serve" {
    try expectHealth(
        healthy,
        200,
        "{\"status\":\"ok\",\"zygote\":\"alive\",\"lanes\":{\"running\":7,\"total\":7},\"usage_stream\":\"ok\"}",
    );

    // A full usage stream drops usage records but sheds no request, so it is
    // reported and the status stays ok.
    var usage_full = healthy;
    usage_full.usage_stream_full = true;
    try expectHealth(
        usage_full,
        200,
        "{\"status\":\"ok\",\"zygote\":\"alive\",\"lanes\":{\"running\":7,\"total\":7},\"usage_stream\":\"full\"}",
    );
}

test "the health answer is 503 and degraded once the zygote exited or a lane stopped" {
    var zygote_exited = healthy;
    zygote_exited.zygote_alive = false;
    try expectHealth(
        zygote_exited,
        503,
        "{\"status\":\"degraded\",\"zygote\":\"exited\",\"lanes\":{\"running\":7,\"total\":7},\"usage_stream\":\"ok\"}",
    );

    var lane_stopped = healthy;
    lane_stopped.lanes_running = 6;
    try expectHealth(
        lane_stopped,
        503,
        "{\"status\":\"degraded\",\"zygote\":\"alive\",\"lanes\":{\"running\":6,\"total\":7},\"usage_stream\":\"ok\"}",
    );
}

test "the health answer is 503 and stopping while the server drains, whatever else holds" {
    var stopping = healthy;
    stopping.stopping = true;
    try expectHealth(
        stopping,
        503,
        "{\"status\":\"stopping\",\"zygote\":\"alive\",\"lanes\":{\"running\":7,\"total\":7},\"usage_stream\":\"ok\"}",
    );

    stopping.zygote_alive = false;
    try expectHealth(
        stopping,
        503,
        "{\"status\":\"stopping\",\"zygote\":\"exited\",\"lanes\":{\"running\":7,\"total\":7},\"usage_stream\":\"ok\"}",
    );
}

test "the widest health body fits its bound exactly" {
    const widest: server_responses.HealthState = .{
        .stopping = false,
        .zygote_alive = false,
        .lanes_running = std.math.maxInt(u16),
        .lanes_total = std.math.maxInt(u16),
        .usage_stream_full = true,
    };
    var buffer: [server_responses.health_body_bytes_max]u8 = undefined;
    const response = server_responses.health(widest, &buffer);
    try std.testing.expectEqual(server_responses.health_body_bytes_max, response.body.len);
    try std.testing.expectEqual(@as(u16, 503), response.status);
}

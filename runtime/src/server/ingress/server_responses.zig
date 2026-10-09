//! The responses a lane writes on its own when no worker response answers
//! the request: the health answer, a path no route matches, a malformed or
//! oversized request, and the errors for a request the server could not hand
//! to a worker.
//!
//! Every status the server answers by itself comes from this file, never
//! from an inline status and body, so the full set stays in one place: the
//! fixed responses from the table, and the health answer from `health`,
//! whose body reports the server's state (`queueServerResponse` in
//! `http2/writing.zig` queues both). Each response carries only
//! content-type and content-length, with no server or date header.

const std = @import("std");

pub const Id = enum(u8) {
    bad_request,
    route_not_found,
    payload_too_large,
    request_header_fields_too_large,
    service_unavailable,
    bad_gateway,
    gateway_timeout,
    internal_error,

    count,
};

pub const Response = struct {
    status: u16,
    reason: []const u8,
    body: []const u8,
    content_type: []const u8 = "text/plain; charset=utf-8",
};

/// The 404 page the server serves when a request path matches no route.
/// Self-contained, with inline style and an inline SVG whose currentColor
/// follows the prefers-color-scheme flip, so it is one static body that
/// fetches nothing.
pub const route_not_found_html =
    \\<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>404: This page could not be found</title><style>body{color:#000;background:#fff;margin:0;font-family:system-ui,"Segoe UI",Roboto,Helvetica,Arial,sans-serif,"Apple Color Emoji","Segoe UI Emoji"}.e{border-right:1px solid rgba(0,0,0,.3)}.logo{position:fixed;bottom:2rem;left:50%;transform:translateX(-50%);opacity:.35}@media (prefers-color-scheme:dark){body{color:#fff;background:#000}.e{border-right:1px solid rgba(255,255,255,.3)}}</style></head><body><div style="height:100vh;text-align:center;display:flex;flex-direction:column;align-items:center;justify-content:center"><div><h1 class="e" style="display:inline-block;margin:0 20px 0 0;padding:0 23px 0 0;font-size:24px;font-weight:500;vertical-align:top;line-height:49px">404</h1><div style="display:inline-block"><h2 style="font-size:14px;font-weight:400;line-height:49px;margin:0">This page could not be found.</h2></div></div></div><svg class="logo" width="28" height="28" viewBox="0 0 512 512" aria-label="Collo"><g transform="translate(256 256) scale(0.3719 -0.3719) translate(-297.5 -355)"><path fill="currentColor" d="M304 -16 Q217 -16 157 29 Q97 74 65.5 157 Q34 240 34 354 Q34 469 65.5 552 Q97 635 157 680.5 Q217 726 304 726 Q404 726 471 660 Q538 594 557 473 L430 467 Q417 539 383.5 576.5 Q350 614 304 614 Q257 614 225.5 583.5 Q194 553 178 495 Q162 437 162 354 Q162 272 178 214 Q194 156 225.5 126 Q257 96 304 96 Q352 96 387 136.5 Q422 177 434 255 L561 250 Q543 124 475.5 54 Q408 -16 304 -16 Z"/></g></svg></body></html>
;

const response_count: usize = @intFromEnum(Id.count);

const responses: [response_count]Response = .{
    .{ .status = 400, .reason = "Bad Request", .body = "bad request" },
    .{
        .status = 404,
        .reason = "Not Found",
        .body = route_not_found_html,
        .content_type = "text/html; charset=utf-8",
    },
    .{ .status = 413, .reason = "Payload Too Large", .body = "payload too large" },
    .{ .status = 431, .reason = "Request Header Fields Too Large", .body = "request header fields too large" },
    .{ .status = 503, .reason = "Service Unavailable", .body = "service unavailable" },
    .{ .status = 502, .reason = "Bad Gateway", .body = "bad gateway" },
    .{ .status = 504, .reason = "Gateway Timeout", .body = "gateway timeout" },
    .{ .status = 500, .reason = "Internal Server Error", .body = "internal server error" },
};

pub fn get(id: Id) Response {
    std.debug.assert(id != .count);
    return responses[@intFromEnum(id)];
}

/// What the health answer reports, read by the lane that answers it
/// (`healthState` in `runner/admission.zig`).
pub const HealthState = struct {
    /// The server stopped admitting requests and drains the ones in flight.
    stopping: bool,
    /// The zygote's pidfd has not reported an exit.
    zygote_alive: bool,
    /// Lanes whose loop is serving, out of `lanes_total`.
    lanes_running: u16,
    lanes_total: u16,
    /// The usage stream refused a record and has not had room since for the
    /// largest one it refused (`Sink.full` in `server/analytics/sink.zig`):
    /// usage records are being dropped. It is reported, but it leaves the
    /// status alone: a full stream sheds no request, and a load balancer
    /// acting on the status would shed every request the node gets.
    usage_stream_full: bool,

    pub const Status = enum { ok, degraded, stopping };

    /// `ok` while the server can start workers and serve on every lane,
    /// `stopping` once it drains, and `degraded` otherwise.
    pub fn status(self: HealthState) Status {
        if (self.stopping)
            return .stopping;
        if (!self.zygote_alive)
            return .degraded;
        if (self.lanes_running != self.lanes_total)
            return .degraded;
        return .ok;
    }
};

const health_format = "{{\"status\":\"{s}\",\"zygote\":\"{s}\",\"lanes\":{{\"running\":{d},\"total\":{d}}},\"usage_stream\":\"{s}\"}}";

/// The longest status name the health body carries.
const health_status_bytes_max: usize = blk: {
    var longest: usize = 0;
    for (std.meta.tags(HealthState.Status)) |tag|
        longest = @max(longest, @tagName(tag).len);
    break :blk longest;
};

/// The longest health body: the longest status, every part degraded and
/// both lane counts at their widest.
pub const health_body_bytes_max: usize = std.fmt.count(health_format, .{
    "s" ** health_status_bytes_max,
    "exited",
    std.math.maxInt(u16),
    std.math.maxInt(u16),
    "full",
});

/// The health answer for `state`, a JSON object such as
/// `{"status":"ok","zygote":"alive","lanes":{"running":7,"total":7},"usage_stream":"ok"}`.
/// Status 200 says `"status":"ok"`; status 503 says `"status":"degraded"`
/// once the zygote exited or a lane is not running, and `"status":"stopping"`
/// while the server drains. The body is formatted into `buffer`, which the
/// response borrows.
pub fn health(state: HealthState, buffer: *[health_body_bytes_max]u8) Response {
    std.debug.assert(state.lanes_running <= state.lanes_total);
    const status = state.status();
    var writer: std.Io.Writer = .fixed(buffer);
    // The buffer holds the widest body, so the writer cannot run out.
    writer.print(health_format, .{
        @tagName(status),
        if (state.zygote_alive) "alive" else "exited",
        state.lanes_running,
        state.lanes_total,
        if (state.usage_stream_full) "full" else "ok",
    }) catch unreachable;
    return switch (status) {
        .ok => .{
            .status = 200,
            .reason = "OK",
            .body = writer.buffered(),
            .content_type = "application/json",
        },
        .degraded, .stopping => .{
            .status = 503,
            .reason = "Service Unavailable",
            .body = writer.buffered(),
            .content_type = "application/json",
        },
    };
}

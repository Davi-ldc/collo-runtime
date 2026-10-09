//! HTTP/1 helpers shared by the exchange and the body continuation: owned
//! response heads, request framing and coalescing rules, the reuse test for a
//! response's framing, the Keep-Alive hint parser and a cancel-aware socket
//! read.

const std = @import("std");

const cancel_probe_mod = @import("../cancel_probe.zig");
const config_mod = @import("../config.zig");
const connection_mod = @import("../connection.zig");
const headers_mod = @import("../request/headers.zig");
const http1 = @import("protocol/root.zig");

const CancelProbe = cancel_probe_mod.CancelProbe;
const Config = config_mod.Config;
const HttpConnection = connection_mod.HttpConnection;

const cloneHeaders = headers_mod.cloneHeaders;
const freeHeaders = headers_mod.freeHeaders;

pub const StreamedResponseHead = struct {
    status: u16,
    status_text: []u8,
    url: []u8,
    headers: []http1.Header,
    redirected: bool = false,

    pub fn deinit(self: *StreamedResponseHead, allocator: std.mem.Allocator) void {
        allocator.free(self.status_text);
        allocator.free(self.url);
        freeHeaders(allocator, self.headers);
        self.* = undefined;
    }
};

/// Progress markers a caller can inspect after a failed exchange to decide
/// whether replaying the request on a fresh connection is safe.
pub const HeadProgress = struct {
    response_bytes_received: bool = false,
};

/// Bodies at or below this size go out in the same write as the request head,
/// so a small POST costs one packet or TLS record instead of two.
pub const max_coalesced_body_bytes: usize = 16 * 1024;

/// Cap on consecutive 1xx interim responses before the final head, so an
/// origin cannot hold an exchange with an endless run of them.
pub const max_interim_responses: usize = 8;

pub const OwnedResponseHead = struct {
    allocator: std.mem.Allocator,
    wire: std.array_list.Aligned(u8, null),
    head: http1.ResponseHead,

    pub fn deinit(self: *OwnedResponseHead) void {
        self.head.deinit();
        self.wire.deinit(self.allocator);
        self.* = undefined;
    }
};

/// Methods with request-body semantics always carry `content-length: 0` for
/// empty bodies so origins do not stall waiting for framing.
pub fn methodHasRequestBodySemantics(method: []const u8) bool {
    return std.ascii.eqlIgnoreCase(method, "POST") or
        std.ascii.eqlIgnoreCase(method, "PUT") or
        std.ascii.eqlIgnoreCase(method, "PATCH");
}

pub fn cloneStreamedResponseHead(
    allocator: std.mem.Allocator,
    response: http1.ResponseHead,
    url: []const u8,
    redirected: bool,
) !StreamedResponseHead {
    const status_text = try allocator.dupe(u8, response.reason);
    errdefer allocator.free(status_text);
    const owned_url = try allocator.dupe(u8, url);
    errdefer allocator.free(owned_url);
    const headers = try cloneHeaders(allocator, response.headers);
    errdefer freeHeaders(allocator, headers);
    return .{
        .status = response.status_code,
        .status_text = status_text,
        .url = owned_url,
        .headers = headers,
        .redirected = redirected,
    };
}

pub fn responseReusableForPool(response: http1.ResponseHead) bool {
    if (response.close_after_response)
        return false;
    return switch (response.body_framing) {
        .none, .content_length, .http1_chunked => true,
        .close_delimited => false,
    };
}

/// Server reuse hint from `Keep-Alive: timeout=N` (seconds), if present.
pub fn keepAliveTimeoutNs(headers: []const http1.Header) ?u64 {
    for (headers) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "keep-alive"))
            continue;
        var params = std.mem.splitScalar(u8, header.value, ',');
        while (params.next()) |param| {
            const trimmed = std.mem.trim(u8, param, &std.ascii.whitespace);
            const equals = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
            const name = std.mem.trimRight(u8, trimmed[0..equals], &std.ascii.whitespace);
            if (!std.ascii.eqlIgnoreCase(name, "timeout"))
                continue;
            var value = std.mem.trimLeft(u8, trimmed[equals + 1 ..], &std.ascii.whitespace);
            value = std.mem.trim(u8, value, "\"");
            const seconds = std.fmt.parseUnsigned(u64, value, 10) catch continue;
            return seconds *| std.time.ns_per_s;
        }
    }
    return null;
}

pub fn readConnectionChunk(
    connection: *HttpConnection,
    dest: []u8,
    config: Config,
    cancel_probe: CancelProbe,
) !usize {
    while (true) {
        if (cancel_probe.isCanceled())
            return error.FetchAborted;
        switch (try connection.readStep(dest)) {
            .ready => |read_len| return read_len,
            .eof => return 0,
            .wait => |interest| try cancel_probe.waitConnection(
                connection,
                interest,
                config.socket_timeout_ms,
                error.FetchReadTimeout,
            ),
        }
    }
}

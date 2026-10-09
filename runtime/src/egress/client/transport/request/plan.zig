//! Request plan shared by the HTTP/1 and HTTP/2 egress paths: the target
//! parsed under the egress policy, the canonical method, validated headers
//! with a default accept-encoding, the origin-form request target and the
//! authority, which omits a port equal to the scheme's default.
//!
//! Preparing a plan never touches the network. The plan is validated as an
//! HTTP/1 head even when it will go out over HTTP/2, so a bad request fails
//! before any dial and the same way on both paths.

const std = @import("std");
const core = @import("collo_egress_core");
const hpack = @import("collo_hpack");
const http = @import("collo_http");

const config_mod = @import("../config.zig");
const headers_mod = @import("headers.zig");
const http1 = @import("../http1/protocol/root.zig");
const policy_mod = @import("policy.zig");
const http2 = @import("collo_egress_http2");

const decompress = core.decompress;
const Config = config_mod.Config;
const EgressPolicy = policy_mod.EgressPolicy;
const Header = headers_mod.Header;
const ParsedHeaders = headers_mod.ParsedHeaders;
const RequestTarget = policy_mod.RequestTarget;
const cloneHeader = headers_mod.cloneHeader;
const parseFetchHeaders = headers_mod.parseFetchHeaders;

pub const RequestPlan = struct {
    allocator: std.mem.Allocator,
    url: []const u8,
    target: RequestTarget,
    method: []const u8,
    parsed_headers: ParsedHeaders,
    request_target: []u8,
    request_authority: []u8,
    h2_headers: []hpack.Header,

    pub fn deinit(self: *RequestPlan) void {
        self.allocator.free(self.h2_headers);
        self.allocator.free(self.request_authority);
        self.allocator.free(self.request_target);
        self.parsed_headers.deinit();
        self.* = undefined;
    }

    pub fn h2RequestHead(self: *const RequestPlan, body: []const u8) http2.RequestHead {
        return .{
            .method = self.method,
            .scheme = switch (self.target.protocol) {
                .plain => "http",
                .tls => "https",
            },
            .authority = self.request_authority,
            .path = self.request_target,
            .headers = self.h2_headers,
            .body = body,
        };
    }
};

pub fn prepareRequest(
    allocator: std.mem.Allocator,
    url: []const u8,
    method_text: []const u8,
    headers: []const Header,
    config: Config,
) !RequestPlan {
    const policy = EgressPolicy{
        .allow_plain_http = config.allow_plain_http,
        .allow_private_networks = config.allow_private_networks,
    };
    const target = try policy.parseTarget(url);

    const method = try canonicalHttpMethod(method_text);
    var parsed_headers = try parseFetchHeaders(allocator, headers);
    errdefer parsed_headers.deinit();
    try ensureDefaultAcceptEncoding(allocator, &parsed_headers);
    const request_target = try originTargetAlloc(allocator, target.uri);
    errdefer allocator.free(request_target);
    const request_authority = try requestAuthorityAlloc(allocator, target);
    errdefer allocator.free(request_authority);
    const h2_headers = try allocator.alloc(hpack.Header, parsed_headers.headers.items.len);
    errdefer allocator.free(h2_headers);
    for (parsed_headers.headers.items, 0..) |header, index|
        h2_headers[index] = .{ .name = header.name, .value = header.value };
    try http1.validateRequestSerializeOptions(.{
        .method = method,
        .target = request_target,
        .host = request_authority,
        .headers = parsed_headers.headers.items,
        .content_length = null,
        .close_after_response = false,
    });

    return .{
        .allocator = allocator,
        .url = url,
        .target = target,
        .method = method,
        .parsed_headers = parsed_headers,
        .request_target = request_target,
        .request_authority = request_authority,
        .h2_headers = h2_headers,
    };
}

fn canonicalHttpMethod(method: []const u8) ![]const u8 {
    if (!isValidHttpMethodToken(method))
        return error.UnsupportedFetchMethod;
    // The Fetch standard forbids these methods.
    if (std.ascii.eqlIgnoreCase(method, "CONNECT") or
        std.ascii.eqlIgnoreCase(method, "TRACE") or
        std.ascii.eqlIgnoreCase(method, "TRACK"))
        return error.UnsupportedFetchMethod;
    if (std.ascii.eqlIgnoreCase(method, "GET")) return "GET";
    if (std.ascii.eqlIgnoreCase(method, "HEAD")) return "HEAD";
    if (std.ascii.eqlIgnoreCase(method, "POST")) return "POST";
    if (std.ascii.eqlIgnoreCase(method, "PUT")) return "PUT";
    if (std.ascii.eqlIgnoreCase(method, "PATCH")) return "PATCH";
    if (std.ascii.eqlIgnoreCase(method, "DELETE")) return "DELETE";
    if (std.ascii.eqlIgnoreCase(method, "OPTIONS")) return "OPTIONS";
    return method;
}

fn isValidHttpMethodToken(method: []const u8) bool {
    if (method.len == 0)
        return false;
    for (method) |ch| switch (ch) {
        'A'...'Z',
        'a'...'z',
        '0'...'9',
        '!',
        '#',
        '$',
        '%',
        '&',
        '\'',
        '*',
        '+',
        '-',
        '.',
        '^',
        '_',
        '`',
        '|',
        '~',
        => {},
        else => return false,
    };
    return true;
}

fn ensureDefaultAcceptEncoding(allocator: std.mem.Allocator, parsed_headers: *ParsedHeaders) !void {
    for (parsed_headers.headers.items) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "accept-encoding"))
            return;
    }
    const header = try cloneHeader(allocator, .{
        .name = "accept-encoding",
        .value = decompress.defaultAcceptEncoding(),
    });
    parsed_headers.headers.append(allocator, header) catch |err| {
        allocator.free(header.name);
        allocator.free(header.value);
        return err;
    };
}

fn originTargetAlloc(allocator: std.mem.Allocator, uri: std.Uri) ![]u8 {
    var target = std.array_list.Aligned(u8, null).empty;
    errdefer target.deinit(allocator);
    const path = switch (uri.path) {
        .percent_encoded => |value| value,
        .raw => return error.InvalidFetchUrl,
    };
    try target.appendSlice(allocator, if (path.len == 0) "/" else path);
    if (uri.query) |query| {
        const query_bytes = switch (query) {
            .percent_encoded => |value| value,
            .raw => return error.InvalidFetchUrl,
        };
        try target.append(allocator, '?');
        try target.appendSlice(allocator, query_bytes);
    }
    return target.toOwnedSlice(allocator);
}

fn requestAuthorityAlloc(allocator: std.mem.Allocator, target: RequestTarget) ![]u8 {
    var authority = std.array_list.Aligned(u8, null).empty;
    errdefer authority.deinit(allocator);
    try authority.appendSlice(allocator, target.authority_host);
    if (target.port != policy_mod.defaultPort(target.protocol))
        try authority.writer(allocator).print(":{d}", .{target.port});
    return authority.toOwnedSlice(allocator);
}

pub fn appendResponseChunk(allocator: std.mem.Allocator, buffer: *std.array_list.Aligned(u8, null), chunk: []const u8, max_response_body_bytes: usize) !void {
    if (chunk.len > max_response_body_bytes -| buffer.items.len)
        return error.FetchResponseTooLarge;
    try buffer.appendSlice(allocator, chunk);
}

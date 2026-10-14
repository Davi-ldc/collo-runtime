//! The request plan of one hop, shared by the HTTP/1 and HTTP/2 paths, and the
//! origin key every connection pool and dial of the engine is keyed by.
//!
//! A plan holds the target parsed and admitted under the fetch's network
//! policy, which makes this the one place every hop's target is decided, the
//! canonical method, validated headers with a default accept-encoding, the
//! origin-form request target, the authority (which omits a port equal to the
//! scheme's default) and the hop's `OriginKey`. The engine prepares one plan
//! per hop and keeps it until the hop ends; preparing a plan never touches the
//! network. The plan is validated as an HTTP/1 head even when it will go out
//! over HTTP/2, so a bad request fails before any dial and the same way on
//! both paths.
//!
//! An `OriginKey` carries everything that decides whether two hops may share
//! a connection: the security cell and network policy the gateway gives each
//! fetch, the scheme, host and port, the admission's private-network verdict
//! (which decided which addresses the dial accepted) and the test-only
//! `insecure_tls` knob. Two hops with equal keys may share connections and
//! TLS sessions; no field may leave the key without that becoming true across
//! security cells or policies.

const std = @import("std");
const core = @import("collo_egress_core");

const config_mod = @import("../config.zig");
const headers_mod = @import("headers.zig");
const http1 = @import("../http1/protocol.zig");
const policy_mod = @import("policy.zig");
const http2 = @import("../h2/codec/root.zig");

const decompress = core.decompress;
const Config = config_mod.Config;
const Header = headers_mod.Header;
const ParsedHeaders = headers_mod.ParsedHeaders;
const PoolIsolationId = config_mod.PoolIsolationId;
const Protocol = config_mod.Protocol;
const RequestTarget = policy_mod.RequestTarget;
const cloneHeader = headers_mod.cloneHeader;
const parseFetchHeaders = headers_mod.parseFetchHeaders;

pub const OriginKey = struct {
    security_cell_id: PoolIsolationId,
    policy_id: PoolIsolationId,
    protocol: Protocol,
    port: u16,
    insecure_tls: bool,
    allow_private_networks: bool,
    host_len: u8,
    /// The URL's host, lowercased, IPv6 literals in brackets.
    host_lower: [host_bytes_max]u8,

    /// `policy.zig:parseTarget` admits only hosts `collo_network` can name,
    /// at most `name_bytes_max` (253) bytes plus one trailing dot, or a
    /// bracketed IPv6 literal, so every admitted host fits.
    pub const host_bytes_max: usize = std.math.maxInt(u8);

    /// Fails with `error.InvalidFetchUrl` for a host longer than
    /// `host_bytes_max`, which no admitted target has.
    pub fn init(target: *const RequestTarget, config: Config) !OriginKey {
        const authority_host = target.authority_host;
        if (authority_host.len > host_bytes_max)
            return error.InvalidFetchUrl;
        var key: OriginKey = .{
            .security_cell_id = config.pool_security_cell_id,
            .policy_id = config.pool_policy_id,
            .protocol = target.protocol,
            .port = target.port,
            .insecure_tls = config.insecure_tls,
            .allow_private_networks = target.admission.allow_private_networks,
            .host_len = @intCast(authority_host.len),
            .host_lower = undefined,
        };
        _ = std.ascii.lowerString(key.host_lower[0..authority_host.len], authority_host);
        return key;
    }

    pub fn host(self: *const OriginKey) []const u8 {
        return self.host_lower[0..self.host_len];
    }

    pub fn eql(self: *const OriginKey, other: *const OriginKey) bool {
        return self.port == other.port and
            self.protocol == other.protocol and
            self.insecure_tls == other.insecure_tls and
            self.allow_private_networks == other.allow_private_networks and
            std.mem.eql(u8, &self.security_cell_id, &other.security_cell_id) and
            std.mem.eql(u8, &self.policy_id, &other.policy_id) and
            std.mem.eql(u8, self.host(), other.host());
    }
};

pub const RequestPlan = struct {
    allocator: std.mem.Allocator,
    url: []const u8,
    target: RequestTarget,
    origin_key: OriginKey,
    method: []const u8,
    parsed_headers: ParsedHeaders,
    request_target: []u8,
    request_authority: []u8,

    pub fn deinit(self: *RequestPlan) void {
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
            .headers = self.parsed_headers.headers.items,
            .body = body,
        };
    }
};

/// Borrows `url` and `headers` only for the call; the plan owns copies of
/// everything it keeps except `url`, which must outlive the plan (the task's
/// URL for the hop).
pub fn prepareRequest(
    allocator: std.mem.Allocator,
    url: []const u8,
    method_text: []const u8,
    headers: []const Header,
    config: Config,
) !RequestPlan {
    const target = try policy_mod.parseTarget(config.network, url);
    const origin_key = try OriginKey.init(&target, config);

    const method = try canonicalHttpMethod(method_text);
    var parsed_headers = try parseFetchHeaders(allocator, headers);
    errdefer parsed_headers.deinit();
    try ensureDefaultAcceptEncoding(allocator, &parsed_headers);
    const request_target = try originTargetAlloc(allocator, target.uri);
    errdefer allocator.free(request_target);
    const request_authority = try requestAuthorityAlloc(allocator, target);
    errdefer allocator.free(request_authority);
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
        .origin_key = origin_key,
        .method = method,
        .parsed_headers = parsed_headers,
        .request_target = request_target,
        .request_authority = request_authority,
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
        .value = decompress.default_accept_encoding,
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

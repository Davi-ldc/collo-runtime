//! Fetch redirect handling: decides whether a response redirects under the
//! request's redirect mode, and builds the next hop's request.
//!
//! As in the Fetch standard, 303 turns any method but GET and HEAD into GET,
//! and 301 and 302 turn POST into GET; a rewrite to GET drops the body and
//! its content headers. User info in the redirect URL is stripped, and a hop
//! to another origin drops credentials (authorization, proxy-authorization,
//! cookie).

const std = @import("std");
const config_mod = @import("../config.zig");
const headers_mod = @import("headers.zig");
const policy_mod = @import("policy.zig");

const Header = headers_mod.Header;
const Protocol = config_mod.Protocol;
const cloneHeader = headers_mod.cloneHeader;
const cloneHeaders = headers_mod.cloneHeaders;
const freeHeaders = headers_mod.freeHeaders;
const defaultPort = policy_mod.defaultPort;

pub const RedirectMode = enum(u2) {
    follow = 0,
    @"error" = 1,
    manual = 2,

    pub fn fromFlags(flags: u32) RedirectMode {
        return switch (flags & 0x3) {
            1 => .@"error",
            2 => .manual,
            else => .follow,
        };
    }
};

pub const FetchOptions = struct {
    redirect_mode: RedirectMode = .follow,
    max_redirects: usize = 20,
};

pub const RedirectTarget = struct {
    url: []u8,
    method: []u8,
    headers: []Header,
    body: []const u8,
};

pub fn redirectTarget(
    allocator: std.mem.Allocator,
    current_url: []const u8,
    current_method: []const u8,
    request_headers: []const Header,
    body: []const u8,
    status: u16,
    headers: anytype,
    options: FetchOptions,
    redirect_count: usize,
) !?RedirectTarget {
    if (!isRedirectStatus(status))
        return null;
    const location = responseHeader(headers, "location") orelse return null;
    switch (options.redirect_mode) {
        .manual => return null,
        .@"error" => return error.FetchRedirectRejected,
        .follow => {},
    }
    if (redirect_count >= options.max_redirects)
        return error.FetchRedirectLimitExceeded;

    const resolved_url = try resolveRedirectUrlAlloc(allocator, current_url, location);
    defer allocator.free(resolved_url);
    const next_url = try stripRedirectUserInfoAlloc(allocator, resolved_url);
    errdefer allocator.free(next_url);
    const rewrite_to_get = shouldRewriteRedirectMethod(status, current_method);
    const next_method = try allocator.dupe(u8, if (rewrite_to_get) "GET" else current_method);
    errdefer allocator.free(next_method);
    const cross_origin = !sameOrigin(current_url, next_url);
    const next_headers = try redirectHeadersAlloc(allocator, request_headers, rewrite_to_get, cross_origin);
    errdefer freeHeaders(allocator, next_headers);
    return .{
        .url = next_url,
        .method = next_method,
        .headers = next_headers,
        .body = if (rewrite_to_get) "" else body,
    };
}

fn isRedirectStatus(status: u16) bool {
    return status == 301 or status == 302 or status == 303 or status == 307 or status == 308;
}

fn shouldRewriteRedirectMethod(status: u16, method: []const u8) bool {
    if (status == 303 and !std.ascii.eqlIgnoreCase(method, "GET") and !std.ascii.eqlIgnoreCase(method, "HEAD"))
        return true;
    return (status == 301 or status == 302) and std.ascii.eqlIgnoreCase(method, "POST");
}

fn responseHeader(headers: anytype, name: []const u8) ?[]const u8 {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name))
            return header.value;
    }
    return null;
}

fn resolveRedirectUrlAlloc(allocator: std.mem.Allocator, base_url: []const u8, location: []const u8) ![]u8 {
    const base = try std.Uri.parse(base_url);
    var aux_storage = try allocator.alloc(u8, location.len + base_url.len + 1024);
    defer allocator.free(aux_storage);
    @memcpy(aux_storage[0..location.len], location);
    var aux = aux_storage;
    const resolved = try std.Uri.resolveInPlace(base, location.len, &aux);
    return try std.fmt.allocPrint(allocator, "{f}", .{resolved});
}

fn stripRedirectUserInfoAlloc(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return try allocator.dupe(u8, url);
    const authority_start = scheme_end + 3;
    const authority_end = findAuthorityEnd(url, authority_start);
    const authority = url[authority_start..authority_end];
    const at_offset = std.mem.lastIndexOfScalar(u8, authority, '@') orelse
        return try allocator.dupe(u8, url);
    return try std.mem.concat(allocator, u8, &.{
        url[0..authority_start],
        authority[at_offset + 1 ..],
        url[authority_end..],
    });
}

fn findAuthorityEnd(url: []const u8, authority_start: usize) usize {
    var index = authority_start;
    while (index < url.len) : (index += 1) {
        switch (url[index]) {
            '/', '?', '#' => return index,
            else => {},
        }
    }
    return url.len;
}

fn sameOrigin(a_url: []const u8, b_url: []const u8) bool {
    const a = std.Uri.parse(a_url) catch return false;
    const b = std.Uri.parse(b_url) catch return false;
    if (!std.ascii.eqlIgnoreCase(a.scheme, b.scheme))
        return false;
    const a_host = a.host orelse return false;
    const b_host = b.host orelse return false;
    const a_protocol = Protocol.fromScheme(a.scheme) orelse return false;
    const b_protocol = Protocol.fromScheme(b.scheme) orelse return false;
    const a_port = a.port orelse defaultPort(a_protocol);
    const b_port = b.port orelse defaultPort(b_protocol);
    return a_port == b_port and std.ascii.eqlIgnoreCase(a_host.percent_encoded, b_host.percent_encoded);
}

fn redirectHeadersAlloc(
    allocator: std.mem.Allocator,
    headers: []const Header,
    drop_body_headers: bool,
    cross_origin: bool,
) ![]Header {
    if (!drop_body_headers and !cross_origin)
        return cloneHeaders(allocator, headers);

    var kept = std.array_list.Aligned(Header, null).empty;
    errdefer {
        for (kept.items) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }
        kept.deinit(allocator);
    }
    for (headers) |header| {
        if (drop_body_headers and isRedirectBodyHeader(header.name))
            continue;
        if (cross_origin and isRedirectCredentialHeader(header.name))
            continue;
        const cloned = try cloneHeader(allocator, header);
        kept.append(allocator, cloned) catch |err| {
            allocator.free(cloned.name);
            allocator.free(cloned.value);
            return err;
        };
    }
    return kept.toOwnedSlice(allocator);
}

fn isRedirectBodyHeader(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "content-type") or
        std.ascii.eqlIgnoreCase(name, "content-encoding") or
        std.ascii.eqlIgnoreCase(name, "content-language") or
        std.ascii.eqlIgnoreCase(name, "content-location") or
        std.ascii.eqlIgnoreCase(name, "content-length");
}

fn isRedirectCredentialHeader(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "authorization") or
        std.ascii.eqlIgnoreCase(name, "proxy-authorization") or
        std.ascii.eqlIgnoreCase(name, "cookie");
}

//! Owned copies of outbound fetch headers. parseFetchHeaders validates every
//! name and value before copying it, and each helper frees its partial copies
//! when an allocation fails.

const std = @import("std");
const http = @import("collo_http");

const http_headers = http.headers;

pub const Header = http.Header;

pub const ParsedHeaders = struct {
    allocator: std.mem.Allocator,
    headers: std.array_list.Aligned(Header, null),

    pub fn deinit(self: *ParsedHeaders) void {
        for (self.headers.items) |header| {
            self.allocator.free(header.name);
            self.allocator.free(header.value);
        }
        self.headers.deinit(self.allocator);
        self.* = undefined;
    }
};

pub fn parseFetchHeaders(allocator: std.mem.Allocator, input_headers: []const Header) !ParsedHeaders {
    var headers = std.array_list.Aligned(Header, null).empty;
    errdefer {
        for (headers.items) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }
        headers.deinit(allocator);
    }

    for (input_headers) |header| {
        http_headers.validate(header.name, header.value) catch return error.InvalidFetchHeader;
        const cloned = try cloneHeader(allocator, header);
        headers.append(allocator, cloned) catch |err| {
            allocator.free(cloned.name);
            allocator.free(cloned.value);
            return err;
        };
    }

    return .{ .allocator = allocator, .headers = headers };
}

pub fn cloneHeaders(allocator: std.mem.Allocator, input_headers: []const Header) ![]Header {
    const out = try allocator.alloc(Header, input_headers.len);
    errdefer allocator.free(out);
    var initialized: usize = 0;
    errdefer freeHeaderFields(allocator, out[0..initialized]);
    for (input_headers, 0..) |header, index| {
        out[index] = try cloneHeader(allocator, header);
        initialized += 1;
    }
    return out;
}

pub fn cloneHeader(allocator: std.mem.Allocator, header: Header) !Header {
    const owned_name = try allocator.dupe(u8, header.name);
    errdefer allocator.free(owned_name);
    const owned_value = try allocator.dupe(u8, header.value);
    errdefer allocator.free(owned_value);
    return .{ .name = owned_name, .value = owned_value };
}

pub fn freeHeaders(allocator: std.mem.Allocator, headers: []Header) void {
    freeHeaderFields(allocator, headers);
    allocator.free(headers);
}

fn freeHeaderFields(allocator: std.mem.Allocator, headers: []Header) void {
    for (headers) |header| {
        allocator.free(header.name);
        allocator.free(header.value);
    }
}

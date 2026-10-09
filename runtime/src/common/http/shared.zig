//! HTTP message-framing and field checks shared by the ingress server, the
//! worker and the egress client. Pure functions with no state; the only
//! allocation is the result of `authority.normalizeAlloc`, which the caller
//! frees.

const std = @import("std");
const domain = @import("collo_dns_name");

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const framing = struct {
    /// Accepts only ASCII digits that fit a usize, so a sign, whitespace or a
    /// comma-joined list fails with `error.InvalidContentLength`. The caller
    /// trims the field value first.
    pub fn parseContentLengthValue(value: []const u8) !usize {
        if (value.len == 0)
            return error.InvalidContentLength;
        for (value) |byte| {
            if (!std.ascii.isDigit(byte))
                return error.InvalidContentLength;
        }
        return std.fmt.parseUnsigned(usize, value, 10) catch error.InvalidContentLength;
    }

    pub fn validateContentLength(content_length: usize, max_body_bytes: usize) !void {
        if (content_length > max_body_bytes)
            return error.RequestTooLarge;
    }

    /// True only when the list names `chunked` and nothing else: any other
    /// coding or an empty element makes it false.
    pub fn transferEncodingIsChunked(value: []const u8) bool {
        var saw_chunked = false;
        var tokens = std.mem.splitScalar(u8, value, ',');
        while (tokens.next()) |token| {
            const trimmed = std.mem.trim(u8, token, &std.ascii.whitespace);
            if (trimmed.len == 0)
                return false;
            if (!std.ascii.eqlIgnoreCase(trimmed, "chunked"))
                return false;
            saw_chunked = true;
        }
        return saw_chunked;
    }

    pub fn headerValueContainsToken(value: []const u8, expected: []const u8) bool {
        var tokens = std.mem.splitScalar(u8, value, ',');
        while (tokens.next()) |token| {
            const trimmed = std.mem.trim(u8, token, &std.ascii.whitespace);
            if (std.ascii.eqlIgnoreCase(trimmed, expected))
                return true;
        }
        return false;
    }

    /// The Content-Length of a raw header section, or null when it has none.
    /// A second Content-Length field fails with `error.DuplicateContentLength`
    /// even when the values agree; RFC 9110 §8.6 allows rejecting that message
    /// rather than merging the values.
    pub fn parseUniqueContentLengthHeader(header_bytes: []const u8) !?usize {
        var parsed: ?usize = null;
        var lines = std.mem.splitSequence(u8, header_bytes, "\r\n");
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const name = std.mem.trim(u8, line[0..colon], &std.ascii.whitespace);
            if (!std.ascii.eqlIgnoreCase(name, "content-length"))
                continue;
            const value = std.mem.trim(u8, line[colon + 1 ..], &std.ascii.whitespace);
            const content_length = try parseContentLengthValue(value);
            if (parsed != null)
                return error.DuplicateContentLength;
            parsed = content_length;
        }
        return parsed;
    }
};

pub const request_target = struct {
    /// Accepts only origin-form (RFC 9112 §3.2.1): a leading slash and no
    /// space, control byte, DEL or fragment.
    pub fn validateOriginForm(value: []const u8) !void {
        if (value.len == 0)
            return error.InvalidRequestLine;
        if (value[0] != '/')
            return error.InvalidRequestLine;
        for (value) |byte| {
            if (byte <= 0x20 or byte == 0x7f or byte == '#')
                return error.InvalidRequestLine;
        }
    }
};

pub const authority = struct {
    pub const max_host_name_bytes: usize = domain.max_name_bytes;

    /// The longest authority `normalizeServerStack` writes: a host name at
    /// `max_host_name_bytes`, a colon and a five-digit port. A bracketed
    /// IPv6 literal is at most 47 bytes, far below a host name at its bound.
    pub const max_server_authority_bytes: usize = max_host_name_bytes + ":65535".len;

    pub const Host = struct {
        host: []const u8,
        port: ?u16,
    };

    /// Parses the authority of a request this server received, as
    /// `host[:port]` after trimming surrounding whitespace, where host is a
    /// DNS name (which covers dotted IPv4) or a bracketed IPv6 literal
    /// without a zone. Userinfo, a path and an empty port fail. The result
    /// borrows `value`, and an IPv6 host keeps its brackets.
    pub fn parseServer(value: []const u8) !Host {
        const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
        if (trimmed.len == 0)
            return error.InvalidHostHeader;
        if (trimmed[0] != '[')
            return parse(trimmed);

        const close = std.mem.indexOfScalar(u8, trimmed, ']') orelse return error.InvalidHostHeader;
        const host = trimmed[0 .. close + 1];
        const literal = host[1 .. host.len - 1];
        // A zone identifier names an interface of the client's host, which
        // means nothing to this server.
        if (std.mem.indexOfScalar(u8, literal, '%') != null)
            return error.InvalidHostHeader;
        _ = std.net.Ip6Address.parse(literal, 0) catch return error.InvalidHostHeader;
        const rest = trimmed[close + 1 ..];
        if (rest.len == 0)
            return .{ .host = host, .port = null };
        if (rest[0] != ':')
            return error.InvalidHostHeader;
        return .{ .host = host, .port = try parsePort(rest[1..]) };
    }

    /// The authority of a received request in one canonical spelling: the
    /// lowercased host from `parseServer`, then `:port` unless the port is
    /// absent or equals `default_port`, the default of the scheme the
    /// request arrived on. Two spellings of one origin normalize to the same
    /// bytes. The result borrows `buffer`.
    pub fn normalizeServerStack(
        value: []const u8,
        default_port: u16,
        buffer: *[max_server_authority_bytes]u8,
    ) ![]const u8 {
        const parsed = try parseServer(value);
        if (parsed.host.len > max_host_name_bytes)
            return error.InvalidHostHeader;
        asciiLowerInto(buffer[0..parsed.host.len], parsed.host);
        const port = parsed.port orelse return buffer[0..parsed.host.len];
        if (port == default_port)
            return buffer[0..parsed.host.len];
        // `max_server_authority_bytes` leaves room for the longest port
        // after a host that passed the check above.
        const port_text = std.fmt.bufPrint(buffer[parsed.host.len..], ":{d}", .{port}) catch unreachable;
        return buffer[0 .. parsed.host.len + port_text.len];
    }

    /// Parses a Host value as `host[:port]` after trimming surrounding
    /// whitespace. The host must be a DNS name (`collo_dns_name.validateName`),
    /// so a bracketed IP literal, userinfo or a path fails, and a port must be
    /// 1 to 65535. The result borrows `value` and keeps the host's case.
    pub fn parse(value: []const u8) !Host {
        const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
        if (trimmed.len == 0)
            return error.InvalidHostHeader;

        const colon = std.mem.indexOfScalar(u8, trimmed, ':');
        const host = if (colon) |index| trimmed[0..index] else trimmed;
        const port = if (colon) |index| try parsePort(trimmed[index + 1 ..]) else null;

        try validateHostDomainName(host);
        return .{ .host = host, .port = port };
    }

    /// The lowercased host of `value`, port dropped, allocated with
    /// `allocator`; the caller frees it.
    pub fn normalizeAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
        const parsed = try parse(value);
        const out = try allocator.alloc(u8, parsed.host.len);
        asciiLowerInto(out, parsed.host);
        return out;
    }

    fn parsePort(port_text: []const u8) !u16 {
        if (port_text.len == 0)
            return error.InvalidHostHeader;

        var port: u32 = 0;
        for (port_text) |byte| {
            if (!std.ascii.isDigit(byte))
                return error.InvalidHostHeader;
            port = port * 10 + (byte - '0');
            if (port > std.math.maxInt(u16))
                return error.InvalidHostHeader;
        }
        if (port == 0)
            return error.InvalidHostHeader;
        return @intCast(port);
    }

    fn validateHostDomainName(host: []const u8) !void {
        if (std.mem.indexOfAny(u8, host, "/[]@") != null)
            return error.InvalidHostHeader;
        domain.validateName(host) catch return error.InvalidHostHeader;
    }
};

pub const headers = struct {
    pub fn validate(name: []const u8, value: []const u8) !void {
        try validateName(name);
        try validateValue(value);
    }

    pub fn validateName(name: []const u8) !void {
        if (name.len == 0)
            return error.InvalidResponseHeader;
        for (name) |byte| {
            if (!isTokenByte(byte))
                return error.InvalidResponseHeader;
        }
    }

    /// Rejects CR, LF, NUL, DEL and every other control byte except HTAB,
    /// so a value can never split a header line. Bytes above 0x7f pass.
    pub fn validateValue(value: []const u8) !void {
        for (value) |byte| {
            if (byte == '\r' or byte == '\n' or byte == 0 or byte == 0x7f)
                return error.InvalidResponseHeader;
            if (byte < 0x20 and byte != '\t')
                return error.InvalidResponseHeader;
        }
    }

    /// The connection-specific fields RFC 9113 §8.2.2 lists, which an HTTP/2
    /// message must not carry.
    pub fn isConnectionSpecificName(name: []const u8) bool {
        return std.ascii.eqlIgnoreCase(name, "connection") or
            std.ascii.eqlIgnoreCase(name, "keep-alive") or
            std.ascii.eqlIgnoreCase(name, "proxy-connection") or
            std.ascii.eqlIgnoreCase(name, "transfer-encoding") or
            std.ascii.eqlIgnoreCase(name, "upgrade");
    }

    /// A field name valid in HTTP/2, which requires lowercase (RFC 9113
    /// §8.2.1).
    pub fn isLowercaseTokenName(name: []const u8) bool {
        if (name.len == 0)
            return false;
        for (name) |byte| {
            if (std.ascii.isUpper(byte))
                return false;
            if (!isTokenByte(byte))
                return false;
        }
        return true;
    }

    pub fn isTokenByte(byte: u8) bool {
        return std.ascii.isAlphanumeric(byte) or switch (byte) {
            '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
            else => false,
        };
    }
};

pub const status = struct {
    pub fn validate(status_code: u16) !void {
        if (status_code < 200 or status_code > 599)
            return error.InvalidResponseStatus;
    }

    pub fn phrase(status_code: u16) []const u8 {
        return switch (status_code) {
            100 => "Continue",
            101 => "Switching Protocols",
            200 => "OK",
            201 => "Created",
            202 => "Accepted",
            204 => "No Content",
            206 => "Partial Content",
            301 => "Moved Permanently",
            302 => "Found",
            303 => "See Other",
            304 => "Not Modified",
            307 => "Temporary Redirect",
            308 => "Permanent Redirect",
            400 => "Bad Request",
            401 => "Unauthorized",
            403 => "Forbidden",
            404 => "Not Found",
            405 => "Method Not Allowed",
            408 => "Request Timeout",
            409 => "Conflict",
            410 => "Gone",
            413 => "Content Too Large",
            414 => "URI Too Long",
            415 => "Unsupported Media Type",
            429 => "Too Many Requests",
            431 => "Request Header Fields Too Large",
            500 => "Internal Server Error",
            501 => "Not Implemented",
            502 => "Bad Gateway",
            503 => "Service Unavailable",
            504 => "Gateway Timeout",
            else => "Response",
        };
    }
};

fn asciiLowerInto(out: []u8, in: []const u8) void {
    std.debug.assert(out.len == in.len);
    for (in, 0..) |byte, index|
        out[index] = std.ascii.toLower(byte);
}

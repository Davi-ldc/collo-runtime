//! HTTP/1.1 wire protocol for the egress client: request and response line
//! and head parsing, body framing, the chunked decoder, and request and
//! response head serialization.
//!
//! Head scans stop at a byte bound and header lists at a count bound, and the
//! chunked decoder bounds extensions, trailers and wire bytes. A head whose
//! body length could be read two ways (Content-Length together with
//! Transfer-Encoding, or Content-Length values that disagree) is rejected. A
//! bare LF is accepted where CRLF is expected but always reported, through a
//! line's `lenient_line_end`, a head marked close after the response, or the
//! chunked decoder's `saw_lenient_line_end`, so a connection whose framing
//! needed leniency is never reused.

const std = @import("std");
const http = @import("collo_http");
const limits = @import("collo_limits");

pub const Header = http.Header;

pub const BodyFraming = enum {
    none,
    content_length,
    http1_chunked,
    close_delimited,
};

/// Single transfer coding applied before the final `chunked` coding in a
/// response Transfer-Encoding list (RFC 9112 §6.1). Decoded through the same
/// pipeline as Content-Encoding after de-chunking.
pub const TransferCoding = enum {
    none,
    gzip,
    deflate,
    br,
};

pub const RequestLine = struct {
    allocator: std.mem.Allocator,
    method: []u8,
    path: []u8,
    raw_query: []u8,
    prebuffer: []u8,
    consumed_len: usize,

    pub fn deinit(self: *RequestLine) void {
        self.allocator.free(self.method);
        self.allocator.free(self.path);
        self.allocator.free(self.raw_query);
        self.allocator.free(self.prebuffer);
        self.* = undefined;
    }
};

pub const RequestLineView = struct {
    method: []const u8,
    path: []const u8,
    raw_query: []const u8,
    prebuffer: []const u8,
    consumed_len: usize,
    lenient_line_end: bool = false,
};

pub const ResponseLineView = struct {
    minor_version: u8,
    status_code: u16,
    reason: []const u8,
    prebuffer: []const u8,
    consumed_len: usize,
    lenient_line_end: bool = false,
};

pub const request_line_initial_buffer_bytes: usize = 512;
pub const default_max_request_line_bytes: usize = 8190;
pub const request_line_buffer_bytes: usize = default_max_request_line_bytes + "\r\n".len;
pub const default_max_header_bytes: usize = default_max_request_line_bytes * 3;
pub const default_max_http_head_bytes: usize = default_max_request_line_bytes + default_max_header_bytes;
pub const default_max_header_count: usize = 256;

pub fn parseRequestLine(allocator: std.mem.Allocator, bytes: []const u8) !RequestLine {
    const view = try parseRequestLineView(bytes);
    return .{
        .allocator = allocator,
        .method = try allocator.dupe(u8, view.method),
        .path = try allocator.dupe(u8, view.path),
        .raw_query = try allocator.dupe(u8, view.raw_query),
        .prebuffer = try allocator.dupe(u8, view.prebuffer),
        .consumed_len = view.consumed_len,
    };
}

pub fn parseRequestLineView(bytes: []const u8) !RequestLineView {
    return parseRequestLineViewBounded(bytes, default_max_request_line_bytes);
}

pub fn parseRequestLineViewBounded(bytes: []const u8, max_request_line_bytes: usize) !RequestLineView {
    if (std.mem.startsWith(u8, bytes, http2_preface))
        return error.Http2OriginNotSupported;

    const line_end = findLineEnd(bytes, max_request_line_bytes) catch |err| switch (err) {
        error.LineTooLong => return error.RequestLineTooLong,
        error.IncompleteLine => return error.IncompleteRequestLine,
    };
    const request_line = bytes[0..line_end.content_end];

    var parts = std.mem.splitScalar(u8, request_line, ' ');
    const method = parts.next() orelse return error.InvalidRequestLine;
    const target = parts.next() orelse return error.InvalidRequestLine;
    const version = parts.next() orelse return error.InvalidRequestLine;
    if (parts.next() != null)
        return error.InvalidRequestLine;
    if (!isMethodToken(method))
        return error.InvalidRequestLine;
    if (!std.mem.eql(u8, version, "HTTP/1.1"))
        return error.UnsupportedHttpVersion;
    try http.request_target.validateOriginForm(target);

    const question_mark = std.mem.indexOfScalar(u8, target, '?');
    const path = if (question_mark) |index| target[0..index] else target;
    const raw_query = if (question_mark) |index| target[index + 1 ..] else "";

    return .{
        .method = method,
        .path = path,
        .raw_query = raw_query,
        .prebuffer = bytes[line_end.consumed_len..],
        .consumed_len = line_end.consumed_len,
        .lenient_line_end = line_end.lenient,
    };
}

pub fn parseResponseLineView(bytes: []const u8) !ResponseLineView {
    return parseResponseLineViewBounded(bytes, default_max_request_line_bytes);
}

pub fn parseResponseLineViewBounded(bytes: []const u8, max_status_line_bytes: usize) !ResponseLineView {
    const line_end = findLineEnd(bytes, max_status_line_bytes) catch |err| switch (err) {
        error.LineTooLong => return error.ResponseLineTooLong,
        error.IncompleteLine => return error.IncompleteResponseLine,
    };

    const line = bytes[0..line_end.content_end];
    if (line.len < "HTTP/1.1 100".len)
        return error.InvalidResponseLine;
    if (!std.mem.startsWith(u8, line, "HTTP/1."))
        return error.UnsupportedHttpVersion;
    const minor = switch (line["HTTP/1.".len]) {
        '0' => @as(u8, 0),
        '1' => @as(u8, 1),
        else => return error.UnsupportedHttpVersion,
    };
    if (line["HTTP/1.0".len] != ' ')
        return error.InvalidResponseLine;

    const status_start = "HTTP/1.1 ".len;
    if (line.len < status_start + 3)
        return error.InvalidResponseLine;
    const status_text = line[status_start .. status_start + 3];
    for (status_text) |byte| {
        if (!std.ascii.isDigit(byte))
            return error.InvalidResponseLine;
    }
    const status_code = std.fmt.parseUnsigned(u16, status_text, 10) catch return error.InvalidResponseLine;
    // The worker builds the fetch Response through collo_fetch_response_new,
    // which rejects a status above 599. Such a head must fail here as a typed
    // fetch error; otherwise the failure would come only after the head was
    // published. 1xx stays parseable because the exchange discards interim
    // heads (101 is its own error) and never publishes them, so every status
    // that reaches the worker is in [200, 599].
    if (status_code < 100 or status_code > 599)
        return error.InvalidResponseStatus;
    const reason = if (line.len == status_start + 3)
        ""
    else blk: {
        if (line[status_start + 3] != ' ')
            return error.InvalidResponseLine;
        break :blk line[status_start + 4 ..];
    };

    return .{
        .minor_version = minor,
        .status_code = status_code,
        .reason = reason,
        .prebuffer = bytes[line_end.consumed_len..],
        .consumed_len = line_end.consumed_len,
        .lenient_line_end = line_end.lenient,
    };
}

const LineEnd = struct {
    content_end: usize,
    consumed_len: usize,
    lenient: bool,
};

/// Locate the next line terminator, tolerating bare LF where CRLF is expected
/// (RFC 9112 §2.2 leniency, matching llhttp and picohttpparser).
fn findLineEnd(bytes: []const u8, max_line_bytes: usize) error{ LineTooLong, IncompleteLine }!LineEnd {
    const scan_len = @min(bytes.len, max_line_bytes +| 2);
    const newline = std.mem.indexOfScalar(u8, bytes[0..scan_len], '\n') orelse {
        if (bytes.len > max_line_bytes) {
            if (bytes[max_line_bytes] != '\r' or bytes.len > max_line_bytes +| 1)
                return error.LineTooLong;
        }
        return error.IncompleteLine;
    };
    const content_end = if (newline != 0 and bytes[newline - 1] == '\r') newline - 1 else newline;
    if (content_end > max_line_bytes)
        return error.LineTooLong;
    return .{
        .content_end = content_end,
        .consumed_len = newline + 1,
        .lenient = content_end == newline,
    };
}

pub const ParsedHead = struct {
    allocator: std.mem.Allocator,
    headers: []Header,
    close_after_response: bool,
    extra_bytes_after_message: bool,
    has_body_header: bool,
    body_framing: BodyFraming,
    content_length: usize,
    initial_body_bytes: []const u8,
    host: ?[]u8,

    pub fn deinit(self: *ParsedHead) void {
        freeHeaders(self.allocator, self.headers);
        if (self.host) |host|
            self.allocator.free(host);
        self.* = undefined;
    }
};

pub const ResponseHead = struct {
    allocator: std.mem.Allocator,
    minor_version: u8,
    status_code: u16,
    reason: []u8,
    consumed_len: usize,
    headers: []Header,
    body_framing: BodyFraming,
    transfer_coding: TransferCoding,
    content_length: usize,
    /// Raw bytes already read after the response head. For 1xx responses,
    /// these can begin the following response head.
    post_head_bytes: []const u8,
    initial_body_bytes: []const u8,
    close_after_response: bool,

    pub fn deinit(self: *ResponseHead) void {
        self.allocator.free(self.reason);
        freeHeaders(self.allocator, self.headers);
        self.* = undefined;
    }
};

pub const OwnedHead = struct {
    line: RequestLine,
    request_head: ParsedHead,
    close_after_response: bool,

    pub fn deinit(self: *OwnedHead) void {
        self.request_head.deinit();
        self.line.deinit();
        self.* = undefined;
    }
};

pub fn ownedHead(line: RequestLine, request_head: ParsedHead) OwnedHead {
    return .{
        .line = line,
        .request_head = request_head,
        .close_after_response = request_head.close_after_response or request_head.extra_bytes_after_message,
    };
}

const HeaderPlan = struct {
    count: usize = 0,
    body_framing: BodyFraming = .none,
    content_length: ?usize = null,
    close_after_response: bool = false,
    keep_alive: bool = false,
    host: ?[]const u8 = null,
    has_body_header: bool = false,
    transfer_coding: TransferCoding = .none,
    saw_transfer_encoding: bool = false,
    te_last_token: ?[]const u8 = null,
    te_preceding_token: ?[]const u8 = null,
    te_preceding_count: usize = 0,
};

pub const HeadParser = struct {
    allocator: std.mem.Allocator,
    buffer: std.array_list.Aligned(u8, null),
    scan_start: usize = 0,
    max_header_bytes: usize = default_max_header_bytes,

    pub fn init(allocator: std.mem.Allocator, prebuffer: []const u8) !HeadParser {
        var self = HeadParser{
            .allocator = allocator,
            .buffer = .empty,
        };
        errdefer self.deinit();
        try self.buffer.appendSlice(allocator, prebuffer);
        return self;
    }

    pub fn deinit(self: *HeadParser) void {
        self.buffer.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn append(self: *HeadParser, bytes: []const u8) !void {
        if (self.buffer.items.len + bytes.len > self.max_header_bytes)
            return error.RequestHeaderTooLarge;
        const previous_len = self.buffer.items.len;
        try self.buffer.appendSlice(self.allocator, bytes);
        self.scan_start = if (previous_len > 3) previous_len - 3 else 0;
    }

    pub fn complete(self: *HeadParser) !?ParsedHead {
        return completeHead(self.allocator, self.buffer.items, &self.scan_start, self.max_header_bytes);
    }
};

pub const ResponseHeadParser = struct {
    allocator: std.mem.Allocator,
    buffer: std.array_list.Aligned(u8, null),
    scan_start: usize = 0,
    max_header_bytes: usize = default_max_header_bytes,

    pub fn init(allocator: std.mem.Allocator, prebuffer: []const u8) !ResponseHeadParser {
        var self = ResponseHeadParser{
            .allocator = allocator,
            .buffer = .empty,
        };
        errdefer self.deinit();
        try self.buffer.appendSlice(allocator, prebuffer);
        return self;
    }

    pub fn deinit(self: *ResponseHeadParser) void {
        self.buffer.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn append(self: *ResponseHeadParser, bytes: []const u8) !void {
        if (self.buffer.items.len + bytes.len > default_max_request_line_bytes + self.max_header_bytes + "\r\n".len)
            return error.ResponseHeaderTooLarge;
        try self.buffer.appendSlice(self.allocator, bytes);
    }

    pub fn complete(self: *ResponseHeadParser) !?ResponseHead {
        return completeResponseHead(self.allocator, self.buffer.items, &self.scan_start, self.max_header_bytes);
    }
};

pub fn completeHead(allocator: std.mem.Allocator, buffer: []const u8, scan_start: *usize, max_header_bytes: usize) !?ParsedHead {
    const complete = findHeaderEnd(buffer, scan_start, max_header_bytes) catch |err| switch (err) {
        error.RequestHeaderTooLarge => return err,
        else => return err,
    } orelse return null;
    const header_block = buffer[0..complete.header_end];
    const plan = try planRequestHeaders(header_block);
    const content_length = if (plan.body_framing == .content_length) plan.content_length orelse 0 else 0;
    if (plan.body_framing == .content_length)
        try validateContentLength(content_length);
    const request_headers = try cloneHeaders(allocator, header_block, plan.count);
    errdefer freeHeaders(allocator, request_headers);

    const normalized_host = if (plan.host) |host|
        try http.authority.normalizeAlloc(allocator, host)
    else
        null;
    errdefer if (normalized_host) |host| allocator.free(host);

    const body_suffix = buffer[complete.header_terminator_end..];
    const initial_body_len = switch (plan.body_framing) {
        .none => 0,
        .content_length => @min(content_length, body_suffix.len),
        .http1_chunked => body_suffix.len,
        .close_delimited => unreachable,
    };
    const extra_bytes_after_message = switch (plan.body_framing) {
        .none => body_suffix.len != 0,
        .content_length => body_suffix.len > content_length,
        .http1_chunked => false,
        .close_delimited => unreachable,
    };
    return .{
        .allocator = allocator,
        .headers = request_headers,
        .close_after_response = plan.close_after_response or
            complete.lenient or
            content_length > 0 or
            plan.body_framing == .http1_chunked or
            extra_bytes_after_message,
        .extra_bytes_after_message = extra_bytes_after_message,
        .has_body_header = plan.has_body_header,
        .body_framing = plan.body_framing,
        .content_length = content_length,
        .initial_body_bytes = body_suffix[0..initial_body_len],
        .host = normalized_host,
    };
}

pub fn completeResponseHead(allocator: std.mem.Allocator, buffer: []const u8, scan_start: *usize, max_header_bytes: usize) !?ResponseHead {
    const line = parseResponseLineView(buffer) catch |err| switch (err) {
        error.IncompleteResponseLine => return null,
        error.ResponseLineTooLong => return err,
        else => return err,
    };
    const complete = findHeaderEnd(line.prebuffer, scan_start, max_header_bytes) catch |err| switch (err) {
        error.RequestHeaderTooLarge => return error.ResponseHeaderTooLarge,
        else => return err,
    } orelse return null;

    const header_block = line.prebuffer[0..complete.header_end];
    var plan = try planResponseHeaders(header_block);
    if (line.minor_version == 0 and !plan.keep_alive)
        plan.close_after_response = true;
    if (line.lenient_line_end or complete.lenient)
        plan.close_after_response = true;
    if (responseStatusHasNoBody(line.status_code)) {
        plan.body_framing = .none;
        plan.content_length = null;
        plan.transfer_coding = .none;
    } else if (plan.body_framing == .none) {
        plan.body_framing = .close_delimited;
        plan.close_after_response = true;
    }

    const headers = try cloneHeaders(allocator, header_block, plan.count);
    errdefer freeHeaders(allocator, headers);
    const reason = try allocator.dupe(u8, line.reason);
    errdefer allocator.free(reason);

    const body_suffix = line.prebuffer[complete.header_terminator_end..];
    const content_length = if (plan.body_framing == .content_length) plan.content_length orelse 0 else 0;
    const initial_body_len = switch (plan.body_framing) {
        .none => 0,
        .content_length => @min(content_length, body_suffix.len),
        .http1_chunked, .close_delimited => body_suffix.len,
    };
    return .{
        .allocator = allocator,
        .minor_version = line.minor_version,
        .status_code = line.status_code,
        .reason = reason,
        .consumed_len = line.consumed_len + complete.header_terminator_end,
        .headers = headers,
        .body_framing = plan.body_framing,
        .transfer_coding = plan.transfer_coding,
        .content_length = content_length,
        .post_head_bytes = body_suffix,
        .initial_body_bytes = body_suffix[0..initial_body_len],
        .close_after_response = plan.close_after_response,
    };
}

const HeaderEnd = struct {
    header_end: usize,
    header_terminator_end: usize,
    lenient: bool,
};

fn findHeaderEnd(buffer: []const u8, scan_start: *usize, max_header_bytes: usize) !?HeaderEnd {
    if (std.mem.startsWith(u8, buffer, "\r\n")) {
        scan_start.* = 0;
        return .{ .header_end = 0, .header_terminator_end = 2, .lenient = false };
    }
    if (std.mem.startsWith(u8, buffer, "\n")) {
        scan_start.* = 0;
        return .{ .header_end = 0, .header_terminator_end = 1, .lenient = true };
    }
    const search_len = @min(buffer.len, max_header_bytes);
    var index = @min(scan_start.*, search_len);
    while (std.mem.indexOfScalarPos(u8, buffer[0..search_len], index, '\n')) |newline| {
        const after = buffer[newline + 1 ..];
        const line_lenient = newline == 0 or buffer[newline - 1] != '\r';
        if (std.mem.startsWith(u8, after, "\n")) {
            scan_start.* = newline;
            return .{
                .header_end = newline + 1,
                .header_terminator_end = newline + 2,
                .lenient = true,
            };
        }
        if (std.mem.startsWith(u8, after, "\r\n")) {
            scan_start.* = newline;
            return .{
                .header_end = newline + 1,
                .header_terminator_end = newline + 3,
                .lenient = line_lenient,
            };
        }
        index = newline + 1;
    }
    if (buffer.len >= max_header_bytes)
        return error.RequestHeaderTooLarge;
    scan_start.* = if (buffer.len > 3) buffer.len - 3 else 0;
    return null;
}

pub fn requestHost(headers: []const u8) !?[]const u8 {
    var found: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, headers, '\n');
    while (lines.next()) |raw_line| {
        const line = trimHeaderLineEnd(raw_line);
        if (line.len == 0)
            break;
        const parsed = try parseHeaderLine(line);
        if (!std.ascii.eqlIgnoreCase(parsed.name, "host"))
            continue;
        if (found != null)
            return error.DuplicateHostHeader;
        found = try hostFromAuthority(parsed.value);
    }
    return found;
}

pub fn hostFromAuthority(authority: []const u8) ![]const u8 {
    return (try http.authority.parse(authority)).host;
}

pub fn requestHeadersAskClose(headers: []const u8) bool {
    const plan = planRequestHeaders(headers) catch return true;
    return plan.close_after_response;
}

pub fn requestHeadersIndicateBody(headers: []const u8) bool {
    const plan = planRequestHeaders(headers) catch return true;
    return plan.has_body_header;
}

fn planRequestHeaders(headers: []const u8) !HeaderPlan {
    var plan = HeaderPlan{};
    var saw_content_length = false;
    var lines = std.mem.splitScalar(u8, headers, '\n');
    while (lines.next()) |raw_line| {
        const line = trimHeaderLineEnd(raw_line);
        if (line.len == 0)
            continue;
        const parsed = try parseHeaderLine(line);

        plan.count += 1;
        if (plan.count > default_max_header_count)
            return error.RequestHeaderTooLarge;

        if (std.ascii.eqlIgnoreCase(parsed.name, "host")) {
            if (plan.host != null)
                return error.DuplicateHostHeader;
            _ = try http.authority.parse(parsed.value);
            plan.host = parsed.value;
        }
        if (std.ascii.eqlIgnoreCase(parsed.name, "content-length")) {
            if (plan.body_framing == .http1_chunked)
                return error.InvalidRequestBodyFraming;
            const parsed_len = try http.framing.parseContentLengthValue(parsed.value);
            if (saw_content_length and plan.content_length.? != parsed_len)
                return error.DuplicateContentLengthMismatch;
            plan.content_length = parsed_len;
            plan.body_framing = .content_length;
            plan.has_body_header = true;
            saw_content_length = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(parsed.name, "transfer-encoding")) {
            if (saw_content_length)
                return error.InvalidRequestBodyFraming;
            if (!http.framing.transferEncodingIsChunked(parsed.value))
                return error.UnsupportedTransferEncoding;
            plan.body_framing = .http1_chunked;
            plan.has_body_header = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(parsed.name, "expect"))
            return error.UnsupportedExpectation;
        if (std.ascii.eqlIgnoreCase(parsed.name, "connection")) {
            if (http.framing.headerValueContainsToken(parsed.value, "close"))
                plan.close_after_response = true;
            if (http.framing.headerValueContainsToken(parsed.value, "keep-alive"))
                plan.keep_alive = true;
        }
    }
    return plan;
}

fn planResponseHeaders(headers: []const u8) !HeaderPlan {
    var plan = HeaderPlan{};
    var saw_content_length = false;
    var lines = std.mem.splitScalar(u8, headers, '\n');
    while (lines.next()) |raw_line| {
        const line = trimHeaderLineEnd(raw_line);
        if (line.len == 0)
            continue;
        const parsed = try parseHeaderLine(line);

        plan.count += 1;
        if (plan.count > default_max_header_count)
            return error.ResponseHeaderTooLarge;

        if (std.ascii.eqlIgnoreCase(parsed.name, "content-length")) {
            if (plan.saw_transfer_encoding)
                return error.InvalidResponseBodyFraming;
            const parsed_len = try http.framing.parseContentLengthValue(parsed.value);
            if (saw_content_length and plan.content_length.? != parsed_len)
                return error.DuplicateContentLengthMismatch;
            plan.content_length = parsed_len;
            plan.body_framing = .content_length;
            saw_content_length = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(parsed.name, "transfer-encoding")) {
            if (saw_content_length)
                return error.InvalidResponseBodyFraming;
            plan.saw_transfer_encoding = true;
            collectTransferCodings(&plan, parsed.value);
            continue;
        }
        if (std.ascii.eqlIgnoreCase(parsed.name, "connection")) {
            if (http.framing.headerValueContainsToken(parsed.value, "close"))
                plan.close_after_response = true;
            if (http.framing.headerValueContainsToken(parsed.value, "keep-alive"))
                plan.keep_alive = true;
        }
    }
    try finalizeResponseTransferEncoding(&plan);
    return plan;
}

fn collectTransferCodings(plan: *HeaderPlan, value: []const u8) void {
    var codings = std.mem.splitScalar(u8, value, ',');
    while (codings.next()) |raw_coding| {
        const coding = std.mem.trim(u8, raw_coding, &std.ascii.whitespace);
        if (coding.len == 0)
            continue;
        if (plan.te_last_token) |previous| {
            if (!std.ascii.eqlIgnoreCase(previous, "identity")) {
                plan.te_preceding_count += 1;
                if (plan.te_preceding_token == null)
                    plan.te_preceding_token = previous;
            }
        }
        plan.te_last_token = coding;
    }
}

/// RFC 9112 §6.3: chunked as the final coding means chunked framing; a
/// Transfer-Encoding list without final chunked is read to connection close.
/// A single supported coding before chunked is decoded after de-chunking.
fn finalizeResponseTransferEncoding(plan: *HeaderPlan) !void {
    if (!plan.saw_transfer_encoding)
        return;
    const last = plan.te_last_token orelse return;
    if (!std.ascii.eqlIgnoreCase(last, "chunked")) {
        plan.body_framing = .close_delimited;
        plan.close_after_response = true;
        return;
    }
    if (plan.te_preceding_count > 1)
        return error.UnsupportedTransferEncoding;
    if (plan.te_preceding_token) |token|
        plan.transfer_coding = transferCodingFromToken(token) orelse
            return error.UnsupportedTransferEncoding;
    plan.body_framing = .http1_chunked;
}

fn transferCodingFromToken(token: []const u8) ?TransferCoding {
    if (std.ascii.eqlIgnoreCase(token, "gzip") or std.ascii.eqlIgnoreCase(token, "x-gzip"))
        return .gzip;
    if (std.ascii.eqlIgnoreCase(token, "deflate"))
        return .deflate;
    if (std.ascii.eqlIgnoreCase(token, "br"))
        return .br;
    return null;
}

const HeaderLine = struct {
    name: []const u8,
    value: []const u8,
};

fn trimHeaderLineEnd(line: []const u8) []const u8 {
    return std.mem.trimRight(u8, line, "\r");
}

fn parseHeaderLine(line: []const u8) !HeaderLine {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidHeaderLine;
    const name = line[0..colon];
    if (name.len == 0 or std.mem.indexOfAny(u8, name, " \t\r\n") != null)
        return error.InvalidHeaderLine;
    for (name) |byte| {
        if (!isTokenChar(byte))
            return error.InvalidHeaderLine;
    }
    const value = std.mem.trim(u8, line[colon + 1 ..], &std.ascii.whitespace);
    try http.headers.validateValue(value);
    return .{ .name = name, .value = value };
}

fn cloneHeaders(allocator: std.mem.Allocator, headers: []const u8, count: usize) ![]Header {
    const cloned = try allocator.alloc(Header, count);

    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }
        allocator.free(cloned);
    }

    var lines = std.mem.splitScalar(u8, headers, '\n');
    while (lines.next()) |raw_line| {
        const line = trimHeaderLineEnd(raw_line);
        if (line.len == 0)
            continue;
        const parsed = try parseHeaderLine(line);
        const owned_name = try allocator.alloc(u8, parsed.name.len);
        errdefer allocator.free(owned_name);
        for (parsed.name, 0..) |byte, index|
            owned_name[index] = std.ascii.toLower(byte);

        const owned_value = try allocator.dupe(u8, parsed.value);
        errdefer allocator.free(owned_value);

        cloned[initialized] = .{
            .name = owned_name,
            .value = owned_value,
        };
        initialized += 1;
    }
    std.debug.assert(initialized == count);
    return cloned;
}

fn freeHeaders(allocator: std.mem.Allocator, headers: []Header) void {
    for (headers) |header| {
        allocator.free(header.name);
        allocator.free(header.value);
    }
    allocator.free(headers);
}

pub const RequestSerializeOptions = struct {
    method: []const u8,
    target: []const u8,
    host: []const u8,
    headers: []const Header = &.{},
    content_length: ?usize = null,
    close_after_response: bool = true,
};

pub fn serializeRequestHead(allocator: std.mem.Allocator, options: RequestSerializeOptions) ![]u8 {
    try validateRequestSerializeOptions(options);

    var buffer = std.array_list.Aligned(u8, null).empty;
    errdefer buffer.deinit(allocator);
    try buffer.ensureTotalCapacity(allocator, 128 + options.target.len + options.host.len + headerBytesLen(options.headers));
    try buffer.writer(allocator).print("{s} {s} HTTP/1.1\r\n", .{ options.method, options.target });
    try buffer.writer(allocator).print("host: {s}\r\n", .{options.host});
    for (options.headers) |header|
        try buffer.writer(allocator).print("{s}: {s}\r\n", .{ header.name, header.value });
    if (options.content_length) |content_length|
        try buffer.writer(allocator).print("content-length: {d}\r\n", .{content_length});
    try buffer.writer(allocator).print("connection: {s}\r\n\r\n", .{
        if (options.close_after_response) "close" else "keep-alive",
    });
    return buffer.toOwnedSlice(allocator);
}

pub fn validateRequestSerializeOptions(options: RequestSerializeOptions) !void {
    if (!isMethodToken(options.method))
        return error.UnsupportedFetchMethod;
    try http.request_target.validateOriginForm(options.target);
    try validateSerializedAuthority(options.host);
    for (options.headers) |header| {
        try validateSerializableHeader(header);
        if (isManagedRequestHeader(header.name))
            return error.ForbiddenRequestHeader;
    }
}

pub const ResponseSerializeOptions = struct {
    status: u16,
    headers: []const Header = &.{},
    content_length: ?usize = null,
    close_after_response: bool = true,
};

pub fn serializeResponseHead(allocator: std.mem.Allocator, options: ResponseSerializeOptions) ![]u8 {
    try http.status.validate(options.status);
    for (options.headers) |header|
        try validateSerializableHeader(header);

    var buffer = std.array_list.Aligned(u8, null).empty;
    errdefer buffer.deinit(allocator);
    try buffer.ensureTotalCapacity(allocator, 128 + headerBytesLen(options.headers));
    try buffer.writer(allocator).print("HTTP/1.1 {d} {s}\r\n", .{ options.status, http.status.phrase(options.status) });
    for (options.headers) |header|
        try buffer.writer(allocator).print("{s}: {s}\r\n", .{ header.name, header.value });
    if (options.content_length) |content_length|
        try buffer.writer(allocator).print("content-length: {d}\r\n", .{content_length});
    try buffer.writer(allocator).print("connection: {s}\r\n\r\n", .{
        if (options.close_after_response) "close" else "keep-alive",
    });
    return buffer.toOwnedSlice(allocator);
}

fn validateSerializableHeader(header: Header) !void {
    try http.headers.validate(header.name, header.value);
}

fn validateSerializedAuthority(authority: []const u8) !void {
    if (authority.len == 0)
        return error.InvalidHostHeader;
    for (authority) |byte| {
        if (byte <= 0x20 or byte == 0x7f or byte == '\r' or byte == '\n')
            return error.InvalidHostHeader;
    }
}

/// Fields the serializer writes itself (host, content-length, connection) and
/// the other connection-specific ones, transfer-encoding among them. A
/// caller-supplied copy would give the head a second, conflicting authority,
/// body framing or connection option.
fn isManagedRequestHeader(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "host") or
        std.ascii.eqlIgnoreCase(name, "content-length") or
        std.ascii.eqlIgnoreCase(name, "transfer-encoding") or
        http.headers.isConnectionSpecificName(name);
}

fn headerBytesLen(headers: []const Header) usize {
    var total: usize = 0;
    for (headers) |header|
        total += header.name.len + header.value.len + ": \r\n".len;
    return total;
}

pub const max_chunk_extension_bytes: usize = 1024;
pub const max_chunk_trailer_bytes: usize = 16384;

/// Incremental decoder for a chunked body, fed any split of the wire bytes.
/// Chunk extensions and trailers are bounded and discarded, the decoded output
/// and the total wire bytes are bounded by `DecodeOptions`, and any framing or
/// trailer line ending in a bare LF sets `saw_lenient_line_end`.
pub const ChunkedDecoder = struct {
    state: State = .size,
    size: usize = 0,
    remaining: usize = 0,
    saw_size_digit: bool = false,
    ignore_extension: bool = false,
    extension_len: usize = 0,
    trailer_line_len: usize = 0,
    trailer_total_len: usize = 0,
    wire_bytes_seen: usize = 0,
    saw_lenient_line_end: bool = false,
    done: bool = false,

    const State = enum {
        size,
        size_lf,
        data,
        data_cr,
        data_lf,
        trailer,
        trailer_lf,
    };

    pub const Result = struct {
        consumed: usize,
        done: bool,
    };

    pub const DecodeOptions = struct {
        max_output_bytes: usize,
        max_wire_bytes: usize = std.math.maxInt(usize),
    };

    pub fn decode(
        self: *ChunkedDecoder,
        allocator: std.mem.Allocator,
        input: []const u8,
        output: *std.array_list.Aligned(u8, null),
        options: DecodeOptions,
    ) !Result {
        var index: usize = 0;
        while (index < input.len and !self.done) {
            switch (self.state) {
                .size => {
                    const byte = input[index];
                    index += 1;
                    try self.countWireBytes(1, options.max_wire_bytes);
                    if (byte == ';') {
                        if (!self.saw_size_digit)
                            return error.InvalidChunkedBody;
                        self.ignore_extension = true;
                        try self.countExtensionByte();
                        continue;
                    }
                    if (byte == '\r' or byte == '\n') {
                        if (!self.saw_size_digit)
                            return error.InvalidChunkedBody;
                        self.remaining = self.size;
                        if (byte == '\n')
                            self.saw_lenient_line_end = true;
                        self.state = if (byte == '\r')
                            .size_lf
                        else if (self.remaining == 0)
                            .trailer
                        else
                            .data;
                        continue;
                    }
                    if (self.ignore_extension) {
                        try self.countExtensionByte();
                        continue;
                    }
                    const digit = hexDigit(byte) orelse return error.InvalidChunkedBody;
                    self.saw_size_digit = true;
                    self.size = std.math.mul(usize, self.size, 16) catch return error.InvalidChunkedBody;
                    self.size = std.math.add(usize, self.size, digit) catch return error.InvalidChunkedBody;
                },
                .size_lf => {
                    if (input[index] != '\n')
                        return error.InvalidChunkedBody;
                    index += 1;
                    try self.countWireBytes(1, options.max_wire_bytes);
                    self.state = if (self.remaining == 0) .trailer else .data;
                },
                .data => {
                    const copy_len = @min(self.remaining, input.len - index);
                    if (copy_len > options.max_output_bytes -| output.items.len)
                        return error.FetchResponseTooLarge;
                    try self.countWireBytes(copy_len, options.max_wire_bytes);
                    try output.appendSlice(allocator, input[index..][0..copy_len]);
                    index += copy_len;
                    self.remaining -= copy_len;
                    if (self.remaining == 0)
                        self.state = .data_cr;
                },
                .data_cr => {
                    const byte = input[index];
                    index += 1;
                    try self.countWireBytes(1, options.max_wire_bytes);
                    if (byte == '\n') {
                        self.saw_lenient_line_end = true;
                        self.resetForNextChunk();
                        continue;
                    }
                    if (byte != '\r')
                        return error.InvalidChunkedBody;
                    self.state = .data_lf;
                },
                .data_lf => {
                    if (input[index] != '\n')
                        return error.InvalidChunkedBody;
                    index += 1;
                    try self.countWireBytes(1, options.max_wire_bytes);
                    self.resetForNextChunk();
                },
                .trailer => {
                    const byte = input[index];
                    index += 1;
                    try self.countWireBytes(1, options.max_wire_bytes);
                    try self.countTrailerByte();
                    if (byte == '\r') {
                        self.state = .trailer_lf;
                    } else if (byte == '\n') {
                        self.saw_lenient_line_end = true;
                        self.finishTrailerLine();
                    } else {
                        if (byte == 0)
                            return error.InvalidChunkedBody;
                        self.trailer_line_len += 1;
                    }
                },
                .trailer_lf => {
                    if (input[index] != '\n')
                        return error.InvalidChunkedBody;
                    index += 1;
                    try self.countWireBytes(1, options.max_wire_bytes);
                    try self.countTrailerByte();
                    self.finishTrailerLine();
                },
            }
        }
        return .{ .consumed = index, .done = self.done };
    }

    fn resetForNextChunk(self: *ChunkedDecoder) void {
        self.size = 0;
        self.saw_size_digit = false;
        self.ignore_extension = false;
        self.extension_len = 0;
        self.state = .size;
    }

    fn countExtensionByte(self: *ChunkedDecoder) !void {
        self.extension_len += 1;
        if (self.extension_len > max_chunk_extension_bytes)
            return error.ChunkExtensionTooLarge;
    }

    fn countTrailerByte(self: *ChunkedDecoder) !void {
        self.trailer_total_len += 1;
        if (self.trailer_total_len > max_chunk_trailer_bytes)
            return error.ChunkedTrailersTooLarge;
    }

    fn countWireBytes(self: *ChunkedDecoder, bytes: usize, max_wire_bytes: usize) !void {
        if (bytes > max_wire_bytes -| self.wire_bytes_seen)
            return error.FetchResponseEncodedTooLarge;
        self.wire_bytes_seen += bytes;
    }

    fn finishTrailerLine(self: *ChunkedDecoder) void {
        if (self.trailer_line_len == 0) {
            self.done = true;
            return;
        }
        self.trailer_line_len = 0;
        self.state = .trailer;
    }
};

fn hexDigit(byte: u8) ?usize {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => 10 + byte - 'a',
        'A'...'F' => 10 + byte - 'A',
        else => null,
    };
}

fn responseStatusHasNoBody(status_code: u16) bool {
    return (status_code >= 100 and status_code < 200) or status_code == 204 or status_code == 304;
}

fn validateContentLength(content_length: usize) !void {
    try http.framing.validateContentLength(content_length, limits.http_body.MATERIALIZED_BODY_BYTES_MAX);
}

fn isMethodToken(method: []const u8) bool {
    if (method.len == 0)
        return false;
    for (method) |byte| {
        if (!isTokenChar(byte))
            return false;
    }
    return true;
}

fn isTokenChar(byte: u8) bool {
    return http.headers.isTokenByte(byte);
}

pub const http2_preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

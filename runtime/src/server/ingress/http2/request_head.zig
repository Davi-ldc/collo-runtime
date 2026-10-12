//! Validation of a decoded HTTP/2 request head before the lane matches its
//! route and dispatches it, on the lane thread that owns the connection.
//!
//! The ingress serves TLS only, so a request's origin is `https`, and its
//! authority is normalized with `https_default_port` as the default port: the
//! worker builds `request.url` as `https://` plus that authority
//! (`normalizeAuthority`). `parse` normalizes it once, and the head it
//! returns carries the result (`ParsedHead.authority`).
//!
//! A request head holds at most `max_header_count` fields, the one bound on
//! request headers, derived from what a dispatch carries
//! (`ipc.max_request_header_count`): the HPACK decoder refuses a longer list
//! and `parse` refuses one too, so the fields a worker receives always fit.
//!
//! A field is connection-specific by `http.headers.isConnectionSpecificField`
//! as a request carries it, so `te` passes only as `trailers`.

const std = @import("std");

const hpack = @import("collo_hpack");
const http = @import("collo_http");
const ipc = @import("collo_ipc");

/// The pseudo-header fields of a request head `parse` accepts (RFC 9113
/// §8.3.1): `:method`, `:scheme`, `:authority` and `:path`, each once.
const request_pseudo_header_count: usize = 4;

/// The fields one request head may hold, pseudo-header fields included. A
/// worker receives every regular field but `host`, plus the `host` the lane
/// writes from `:authority` (`h2HeadersForIpc` in `runner/admission.zig`), and
/// no pseudo-header field, so a head of this many fields forwards at most
/// `ipc.max_request_header_count` of them. The lane answers a longer head
/// with 431.
pub const max_header_count: usize = ipc.max_request_header_count + request_pseudo_header_count - 1;

/// The value of an `expect` field that asks for 100 (Continue) before the
/// body (RFC 9110 §10.1.1), compared case-insensitively.
const continue_expectation = "100-continue";

/// The default port of `https`, which a normalized authority leaves out.
pub const https_default_port: u16 = 443;

/// Buffer size for `normalizeAuthority`.
pub const authority_bytes_max = http.authority.max_server_authority_bytes;

/// The request's authority as the worker receives it: the lowercased host
/// (a DNS name, dotted IPv4 or a bracketed IPv6 literal) and `:port` unless
/// the port is `https_default_port`. The result is a prefix of `buffer`.
pub fn normalizeAuthority(value: []const u8, buffer: *[authority_bytes_max]u8) ![]const u8 {
    return http.authority.normalizeServerStack(value, https_default_port, buffer);
}

pub const ParsedHead = struct {
    method: []const u8,
    path: []const u8,
    raw_query: []const u8,
    /// The first `authority_len` bytes are the request's `:authority` as
    /// `normalizeAuthority` spells it. The head holds them itself, so a copy
    /// of the head keeps them; read them through `authority`.
    authority_buffer: [authority_bytes_max]u8,
    authority_len: usize,
    headers: []const hpack.Header,
    body_framing: ipc.RequestBodyFraming,
    /// The declared `content-length`, which `parse` leaves unbounded: the
    /// lane answers one over `limits.http_body.MATERIALIZED_BODY_BYTES_MAX`
    /// with 413 once it matched the route (`runner/admission.zig`), so the
    /// answer's record names the route.
    content_length: ?usize,
    end_stream: bool,
    /// The client announced a body and waits for 100 (Continue) before it
    /// sends it: an `expect: 100-continue` field, a head without END_STREAM
    /// and no content-length of 0. The field still reaches the worker.
    expects_continue: bool,
    /// When the head arrived: the lane's CLOCK_MONOTONIC at the socket read
    /// that completed its block (`reading.readAndProcess`). The request's
    /// deadline, its wait for a cold start and its access record's duration
    /// count from it, so the lane's own decode time is inside them.
    received_ns: u64,

    /// The request's normalized authority, which the worker receives as the
    /// dispatch's `authority` and as its `host` header. Borrows the head.
    pub fn authority(self: *const ParsedHead) []const u8 {
        return self.authority_buffer[0..self.authority_len];
    }
};

/// Checks a decoded request head as RFC 9113 §8.3 requires, splits `:path`
/// into path and query, and normalizes the authority. `end_stream` is the
/// END_STREAM flag of the frame that opened the header block, and
/// `received_ns` when the head arrived (`ParsedHead.received_ns`). The
/// result borrows `headers`, except for the authority, which it holds.
/// Every error rejects the request: `error.TooManyRequestHeaders` means more
/// than `max_header_count` fields, which the lane answers with 431, and
/// every other one a malformed request, answered with 400
/// (`RefusedHead.Reason`).
pub fn parse(headers: []const hpack.Header, end_stream: bool, received_ns: u64) !ParsedHead {
    if (headers.len > max_header_count)
        return error.TooManyRequestHeaders;
    var method: ?[]const u8 = null;
    var target: ?[]const u8 = null;
    var authority: ?[]const u8 = null;
    var host_header: ?[]const u8 = null;
    var scheme_seen = false;
    var regular_start: usize = headers.len;
    var content_length: ?usize = null;
    var continue_expected = false;

    for (headers, 0..) |header, index| {
        try validateH2HeaderName(header.name);
        if (header.name[0] == ':') {
            if (regular_start != headers.len)
                return error.Http2PseudoHeaderAfterRegularHeader;
            if (std.mem.eql(u8, header.name, ":method")) {
                if (method != null)
                    return error.Http2DuplicatePseudoHeader;
                method = header.value;
            } else if (std.mem.eql(u8, header.name, ":path")) {
                if (target != null)
                    return error.Http2DuplicatePseudoHeader;
                target = header.value;
            } else if (std.mem.eql(u8, header.name, ":authority")) {
                if (authority != null)
                    return error.Http2DuplicatePseudoHeader;
                authority = header.value;
            } else if (std.mem.eql(u8, header.name, ":scheme")) {
                if (scheme_seen)
                    return error.Http2DuplicatePseudoHeader;
                scheme_seen = true;
            } else {
                return error.Http2InvalidPseudoHeader;
            }
            continue;
        }

        if (regular_start == headers.len)
            regular_start = index;
        try validateH2RegularHeader(header);
        if (std.mem.eql(u8, header.name, "host")) {
            if (host_header != null)
                return error.Http2DuplicateHostHeader;
            host_header = header.value;
        }
        if (std.mem.eql(u8, header.name, "content-length")) {
            const parsed = http.framing.parseContentLengthValue(header.value) catch return error.InvalidContentLength;
            if (content_length) |existing| {
                if (existing != parsed)
                    return error.DuplicateContentLengthMismatch;
            } else {
                content_length = parsed;
            }
        }
        if (std.mem.eql(u8, header.name, "expect") and isContinueExpectation(header.value))
            continue_expected = true;
    }

    const request_method = method orelse return error.Http2MissingMethod;
    const request_target = target orelse return error.Http2MissingPath;
    const request_authority = authority orelse return error.Http2MissingAuthority;
    if (!scheme_seen)
        return error.Http2MissingScheme;
    try http.request_target.validateOriginForm(request_target);
    var authority_buffer: [authority_bytes_max]u8 = undefined;
    const normalized_authority = try normalizeAuthority(request_authority, &authority_buffer);
    std.debug.assert(normalized_authority.ptr == @as([*]const u8, &authority_buffer));
    // A Host field that names another origin than `:authority` makes the
    // request malformed (RFC 9113 §8.3.1); the port is part of the origin.
    if (host_header) |host_value| {
        var host_buffer: [authority_bytes_max]u8 = undefined;
        const normalized_host = try normalizeAuthority(host_value, &host_buffer);
        if (!std.mem.eql(u8, normalized_authority, normalized_host))
            return error.Http2HostAuthorityMismatch;
    }

    const question_mark = std.mem.indexOfScalar(u8, request_target, '?');
    const path = if (question_mark) |index| request_target[0..index] else request_target;
    const raw_query = if (question_mark) |index| request_target[index + 1 ..] else "";
    const body_framing: ipc.RequestBodyFraming = if (end_stream)
        .none
    else
        .ingress_channel;
    if (content_length) |length| {
        if (end_stream and length != 0)
            return error.Http2ContentLengthMismatch;
    }

    return .{
        .method = request_method,
        .path = path,
        .raw_query = raw_query,
        .authority_buffer = authority_buffer,
        .authority_len = normalized_authority.len,
        .headers = headers[regular_start..],
        .body_framing = body_framing,
        .content_length = content_length,
        .end_stream = end_stream,
        .expects_continue = continue_expected and !end_stream and (content_length orelse 1) != 0,
        .received_ns = received_ns,
    };
}

/// A request head the HTTP/2 layer refused before the lane saw it
/// (`reading.processRequestHead`), as the lane's `refuseH2Stream` takes it
/// to answer the stream and record the answer. The strings borrow the
/// decoded block for the call and are the client's unchecked bytes, "" when
/// the block kept no field.
pub const RefusedHead = struct {
    reason: Reason,
    /// The END_STREAM flag of the frame that opened the head's block.
    request_ended: bool,
    /// When the head arrived, as `ParsedHead.received_ns` says.
    received_ns: u64,
    method: []const u8 = "",
    /// The `:path` field's target before any query.
    path: []const u8 = "",
    user_agent: []const u8 = "",

    pub const Reason = enum {
        /// More fields or bytes than a head may hold: 431.
        fields_too_large,
        /// A block that decoded into a head RFC 9113 §8.3 calls malformed:
        /// 400.
        malformed,
    };

    /// The refusal of the head decoded as `headers`, with the first
    /// `:method`, `:path` and `user-agent` it carried, for the record.
    pub fn of(headers: []const hpack.Header, reason: Reason, request_ended: bool, received_ns: u64) RefusedHead {
        var refused: RefusedHead = .{
            .reason = reason,
            .request_ended = request_ended,
            .received_ns = received_ns,
        };
        var method_seen = false;
        var path_seen = false;
        var user_agent_seen = false;
        for (headers) |header| {
            if (!method_seen and std.mem.eql(u8, header.name, ":method")) {
                refused.method = header.value;
                method_seen = true;
            } else if (!path_seen and std.mem.eql(u8, header.name, ":path")) {
                const question_mark = std.mem.indexOfScalar(u8, header.value, '?');
                refused.path = if (question_mark) |index| header.value[0..index] else header.value;
                path_seen = true;
            } else if (!user_agent_seen and std.mem.eql(u8, header.name, "user-agent")) {
                refused.user_agent = header.value;
                user_agent_seen = true;
            }
        }
        return refused;
    }
};

/// Whether an `expect` value is the 100-continue expectation. A field value
/// may keep the whitespace around it (`http.headers.validateValue`).
fn isContinueExpectation(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " \t"), continue_expectation);
}

/// Rejects a trailer block that holds a pseudo-header (RFC 9113 §8.1) or an
/// invalid field.
pub fn validateTrailers(headers: []const hpack.Header) !void {
    for (headers) |header| {
        try validateH2HeaderName(header.name);
        if (header.name[0] == ':')
            return error.Http2InvalidTrailerPseudoHeader;
        try validateH2RegularHeader(header);
    }
}

fn validateH2HeaderName(name: []const u8) !void {
    if (name.len == 0)
        return error.InvalidHeaderLine;
    if (name[0] != ':') {
        for (name) |byte| {
            if (std.ascii.isUpper(byte))
                return error.Http2UppercaseHeaderName;
        }
        if (!http.headers.isLowercaseTokenName(name))
            return error.InvalidHeaderLine;
        return;
    }
    for (name, 0..) |byte, index| {
        if (std.ascii.isUpper(byte))
            return error.Http2UppercaseHeaderName;
        if (byte == ':') {
            if (index != 0)
                return error.InvalidHeaderLine;
            continue;
        }
        if (!http.headers.isTokenByte(byte))
            return error.InvalidHeaderLine;
    }
}

fn validateH2RegularHeader(header: hpack.Header) !void {
    if (http.headers.isConnectionSpecificField(header.name, header.value, .request))
        return error.Http2ConnectionSpecificHeader;
    try http.headers.validateValue(header.value);
}

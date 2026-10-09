//! The worker's view of a dispatched request head, checked before a handler
//! sees the request. It runs on the worker's VM thread and copies nothing:
//! the result borrows the `DispatchWork` it was built from.
//!
//! The server's ingress parses and validates the client's HTTP/2 head
//! (`server/ingress/http2/request_head.zig`), and the dispatch carries its
//! regular headers with exactly one `host`, which holds the request's
//! normalized authority (`h2HeadersForIpc` in
//! `server/ingress/runner/admission.zig`). The worker re-checks the parts a
//! handler relies on instead of trusting the dispatch: every name is a
//! lowercase HTTP/2 field name, `host` appears exactly once, and a
//! `content-length` agrees with the body framing, so a request that carries
//! no body cannot announce one.

const std = @import("std");
const http = @import("collo_http");
const ipc = @import("collo_ipc");

pub const Header = ipc.RequestHeader;

/// A head that passed `fromDispatchWork`. `headers` borrows the dispatch.
pub const ParsedHead = struct {
    headers: []const Header,
    body_framing: ipc.RequestBodyFraming,
};

pub const Error = error{
    InvalidHeaderName,
    DuplicateHostHeader,
    MissingHostHeader,
    InvalidContentLength,
};

/// Checks the dispatched head and returns a view of it. A failure names the
/// first check that did not hold; the caller answers the request with 400.
pub fn fromDispatchWork(dispatch: *const ipc.DispatchWork) Error!ParsedHead {
    var saw_host = false;
    var content_length: ?usize = null;
    for (dispatch.request_headers) |header| {
        if (!http.headers.isLowercaseTokenName(header.name))
            return error.InvalidHeaderName;
        if (std.mem.eql(u8, header.name, "host")) {
            if (saw_host)
                return error.DuplicateHostHeader;
            saw_host = true;
        } else if (std.mem.eql(u8, header.name, "content-length")) {
            const parsed = http.framing.parseContentLengthValue(header.value) catch
                return error.InvalidContentLength;
            if (content_length) |existing| {
                if (existing != parsed)
                    return error.InvalidContentLength;
            } else {
                content_length = parsed;
            }
        }
    }
    if (!saw_host)
        return error.MissingHostHeader;
    if (content_length) |length| {
        switch (dispatch.body_framing) {
            .none => if (length != 0) return error.InvalidContentLength,
            .ingress_channel => {},
        }
    }
    return .{
        .headers = dispatch.request_headers,
        .body_framing = dispatch.body_framing,
    };
}

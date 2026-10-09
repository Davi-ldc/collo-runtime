//! HTTP helpers shared by the ingress server, the worker and the egress
//! client. `shared.zig` holds the message-framing and field checks
//! (Content-Length and Transfer-Encoding, request targets, Host authorities,
//! field names and values, status codes); `http2/` holds the HTTP/2 wire
//! primitives. The module imports only `collo_dns_name` and links no libc.

const shared = @import("shared.zig");

pub const http2 = @import("http2/root.zig");

pub const Header = shared.Header;
pub const framing = shared.framing;
pub const request_target = shared.request_target;
pub const authority = shared.authority;
pub const headers = shared.headers;
pub const status = shared.status;

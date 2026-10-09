//! Public surface of the egress HTTP/1.1 wire protocol: head parsing, body
//! framing, the chunked decoder and head serialization, all implemented in
//! parser.zig.

pub const parser = @import("parser.zig");

pub const Header = parser.Header;
pub const BodyFraming = parser.BodyFraming;
pub const TransferCoding = parser.TransferCoding;
pub const RequestLine = parser.RequestLine;
pub const RequestLineView = parser.RequestLineView;
pub const ResponseLineView = parser.ResponseLineView;
pub const ParsedHead = parser.ParsedHead;
pub const ResponseHead = parser.ResponseHead;
pub const OwnedHead = parser.OwnedHead;
pub const HeadParser = parser.HeadParser;
pub const ResponseHeadParser = parser.ResponseHeadParser;
pub const ChunkedDecoder = parser.ChunkedDecoder;
pub const RequestSerializeOptions = parser.RequestSerializeOptions;
pub const ResponseSerializeOptions = parser.ResponseSerializeOptions;

pub const parseRequestLine = parser.parseRequestLine;
pub const parseRequestLineView = parser.parseRequestLineView;
pub const parseRequestLineViewBounded = parser.parseRequestLineViewBounded;
pub const parseResponseLineView = parser.parseResponseLineView;
pub const parseResponseLineViewBounded = parser.parseResponseLineViewBounded;
pub const completeHead = parser.completeHead;
pub const completeResponseHead = parser.completeResponseHead;
pub const ownedHead = parser.ownedHead;
pub const serializeRequestHead = parser.serializeRequestHead;
pub const validateRequestSerializeOptions = parser.validateRequestSerializeOptions;
pub const serializeResponseHead = parser.serializeResponseHead;
pub const requestHost = parser.requestHost;
pub const hostFromAuthority = parser.hostFromAuthority;
pub const requestHeadersAskClose = parser.requestHeadersAskClose;
pub const requestHeadersIndicateBody = parser.requestHeadersIndicateBody;

pub const max_chunk_extension_bytes = parser.max_chunk_extension_bytes;
pub const max_chunk_trailer_bytes = parser.max_chunk_trailer_bytes;
pub const request_line_initial_buffer_bytes = parser.request_line_initial_buffer_bytes;
pub const request_line_buffer_bytes = parser.request_line_buffer_bytes;
pub const default_max_header_count = parser.default_max_header_count;
pub const default_max_header_bytes = parser.default_max_header_bytes;
pub const default_max_http_head_bytes = parser.default_max_http_head_bytes;
pub const default_max_request_line_bytes = parser.default_max_request_line_bytes;
pub const http2_preface = parser.http2_preface;

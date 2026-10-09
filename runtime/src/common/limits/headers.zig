//! Header-block sizes of the ingress server and the egress fetch client. The
//! two sides differ on purpose: ingress bounds request heads from untrusted
//! clients, while egress must accept origin responses with large Set-Cookie
//! fields. It must import nothing; `root.zig` says why.

/// Cap on the compressed header block of one ingress request, the HEADERS
/// payload plus its CONTINUATION payloads. The server also advertises it as
/// SETTINGS_MAX_HEADER_LIST_SIZE so a compliant client gives up on an
/// oversized request before sending it.
pub const INGRESS_H2_REQUEST_HEADER_BLOCK_BYTES: usize = 32 * 1024;

/// Cap on the decoded header bytes of one ingress request head or trailer
/// block, passed to the HPACK decoder. It is separate from
/// `INGRESS_H2_REQUEST_HEADER_BLOCK_BYTES` because it bounds a different
/// stage: HPACK can expand a small block into a much larger header list.
pub const INGRESS_H2_REQUEST_DECODED_HEADER_BYTES: usize = 32 * 1024;

/// Cap on the HPACK-encoded block of one response head the ingress server
/// sends to a client.
pub const INGRESS_H2_RESPONSE_HEADER_BLOCK_BYTES: usize = 64 * 1024;

/// Cap on the HPACK-encoded block of one outbound fetch request head.
pub const EGRESS_H2_REQUEST_HEADER_BLOCK_BYTES: usize = 64 * 1024;

/// Cap on an origin's response head over either protocol. The HTTP/2 client
/// advertises it as SETTINGS_MAX_HEADER_LIST_SIZE and caps received header
/// blocks with it, and the HTTP/1.1 parser applies it to the raw head, so a
/// response with large Set-Cookie fields passes or fails the same way on
/// both. The size matches Bun's SETTINGS_MAX_HEADER_LIST_SIZE.
pub const EGRESS_RESPONSE_HEADER_BYTES_MAX: usize = 256 * 1024;

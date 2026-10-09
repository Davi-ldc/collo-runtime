//! HTTP/2 on an ingress connection, all of it on the lane thread that owns
//! the connection. The connection driver is three files: `connection.zig`
//! runs a connection's turn and acts on the errors a client causes,
//! `reading.zig` handles what each read brings, and `writing.zig` queues and
//! writes what goes to the client. `frame_reader.zig` splits a connection's
//! bytes into frames across reads, `lane_resources.zig` holds what the
//! lane's connections share (the read buffer, the HPACK scratch, the header
//! block budget and the stream slab), `request_head.zig` validates request
//! heads, and `response.zig` checks and encodes response heads.

pub const connection = @import("connection.zig");
pub const reading = @import("reading.zig");
pub const writing = @import("writing.zig");
pub const frame_reader = @import("frame_reader.zig");
pub const lane_resources = @import("lane_resources.zig");
pub const request_head = @import("request_head.zig");
pub const response = @import("response.zig");

//! HTTP/2 on an ingress connection, all of it on the lane thread that owns
//! the connection. The connection driver is three files: `connection.zig`
//! runs a connection's turn and acts on the errors a client causes,
//! `reading.zig` reads the socket and handles each frame, and `writing.zig`
//! queues and writes what goes to the client. `request_head.zig` validates
//! request heads, and `response.zig` checks and encodes response heads.

pub const connection = @import("connection.zig");
pub const reading = @import("reading.zig");
pub const writing = @import("writing.zig");
pub const request_head = @import("request_head.zig");
pub const response = @import("response.zig");

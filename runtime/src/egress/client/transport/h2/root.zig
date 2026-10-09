//! HTTP/2 transport of the egress client. `codec` is the protocol state
//! machine and does no I/O; the connection pool in `pool.zig` is the separate
//! `collo_egress_pool` module, which drives the codec over gateway sockets.

pub const codec = @import("collo_egress_http2");

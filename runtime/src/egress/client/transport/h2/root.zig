//! HTTP/2 transport of the egress client: `codec` is the protocol state
//! machine and does no I/O; `pool` holds the engine's HTTP/2 connections and
//! drives the codec over their wires.

pub const codec = @import("codec/root.zig");
pub const pool = @import("pool.zig");

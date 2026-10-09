//! The gateway's launch contract: the arg0 that selects the gateway role in the `collo` binary
//! and the one descriptor the gateway inherits. The server's spawn (`server/gateway/process.zig`)
//! writes it and the gateway's entry point (`root.zig`) reads it, so both processes compile this
//! file.
//!
//! The gateway inherits the control socket at `inherited_control_fd` and no other descriptor
//! above the standard three, and takes no argument after arg0: everything it enforces beyond
//! `policy.production` arrives in the server's hello (`control.zig`).

const std = @import("std");

pub const process_name = "collo-egress-gateway";
pub const inherited_control_fd: std.posix.fd_t = 3;

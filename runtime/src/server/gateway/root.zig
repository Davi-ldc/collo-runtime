//! The server's side of the egress gateway: `manager.zig` owns the gateway's lifecycle, its token
//! key and policy table, and worker attach, `lease.zig` is an ingress lane's copy of what it mints
//! egress tokens with and the descriptor it ends requests on, `process.zig` spawns and stops the
//! gateway process and sends its hello, and `control_client.zig` runs the attach round trip on the
//! control socket and reports the channel's failure from its reader thread. The gateway process
//! itself is `egress/gateway/`. From that process these files use only its control wire
//! (`control.zig`), its launch contract (`launch.zig`) and its network policies (`policy.zig`),
//! each taken from the `collo_egress_gateway` import.

pub const control_client = @import("control_client.zig");
pub const lease = @import("lease.zig");
pub const manager = @import("manager.zig");
pub const process = @import("process.zig");

pub const Config = manager.Config;
pub const Lease = lease.Lease;
pub const Manager = manager.Manager;

//! The server's ingress: client connections from accept through TLS and
//! HTTP/2 to a worker and back, in the server process. `service.zig` owns the
//! threads: one lane thread per listener, which runs `runner/`, plus the
//! metrics and console threads, the launcher and the reaper. What the
//! service reports about itself is in `service_observability.zig`, and its
//! side of the launcher's and the reaper's callbacks, with the posts that
//! carry a pool's results to the lanes, in `service_deps.zig`. A lane's
//! tables are fault-in slabs (`slab.zig`) that `runner/root.zig` holds; the
//! rest of its own state is in `lane.zig`: the deadline wheel
//! (`timer_wheel.zig`), the command queue other threads write into
//! (`commands.zig`, with the payloads in `lane_commands.zig`) and the
//! multishot accept (`uring.zig`, `accept.zig`). `fault.zig` sorts every
//! error a lane meets into the connection, worker or lane failure domain.
//! `http2/` is the connection protocol, `completions.zig` a lane's
//! registration of one worker, `analytics_drain.zig` the metrics thread's
//! drain of console lines and access records, `peer_address.zig` the
//! client's address and `server_responses.zig` the responses a lane writes
//! without a worker.

pub const commands = @import("commands.zig");
pub const lane_commands = @import("lane_commands.zig");
pub const fault = @import("fault.zig");
pub const accept = @import("accept.zig");
pub const analytics_drain = @import("analytics_drain.zig");
pub const completions = @import("completions.zig");
pub const http2 = @import("http2/root.zig");
pub const peer_address = @import("peer_address.zig");
pub const server_responses = @import("server_responses.zig");
pub const runner = @import("runner/root.zig");
pub const lane = @import("lane.zig");
pub const service = @import("service.zig");
pub const service_deps = @import("service_deps.zig");
pub const service_observability = @import("service_observability.zig");
pub const slab = @import("slab.zig");
pub const timer_wheel = @import("timer_wheel.zig");
pub const uring = @import("uring.zig");

pub const Service = service.Service;

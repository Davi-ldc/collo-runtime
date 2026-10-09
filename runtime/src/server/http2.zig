//! The root of the `collo_server_h2` module: the ingress HTTP/2 code (the
//! connection, its frame reader, request heads, responses, the
//! per-connection state with its stream table, flow control and write queue,
//! and the fault-in slab they live in) without the rest of the server. The
//! server's JSC-free fast lane (`server-fast-test`) tests it through this
//! module; the server binary reaches the same files through
//! `ingress/root.zig`.

pub const http2 = @import("ingress/http2/root.zig");
pub const fault = @import("ingress/fault.zig");
pub const slab = @import("ingress/slab.zig");
pub const lifecycle = @import("collo_server_lifecycle");

pub const connection_slot = @import("ingress/runner/connection_slot.zig");
pub const stream_table = @import("ingress/runner/stream_table.zig");
pub const flow_control = @import("ingress/runner/flow_control.zig");
pub const write_queue = @import("ingress/runner/write_queue.zig");

//! The gateway's outbound HTTP client, one module: the fetch task model
//! (`task.zig`), the engine that runs tasks (`engine/`), and beneath it the
//! transport (`transport/`: plans and policy, dials, the wire, HTTP/1, and
//! the HTTP/2 codec and pool), TLS (`tls.zig`), the DNS cache and the
//! io_uring data driver (`io/`). Files reach each other by path; this root
//! is the list of namespaces the gateway, the benches and the tests use.
//!
//! Only gateway code imports this module. A worker has no network and links
//! only `collo_egress_core`, the body and credit primitives it shares with
//! this client, so transport policy and results stay inside the gateway.

pub const core = @import("collo_egress_core");

pub const task = @import("task.zig");
pub const body_credit = core.body_credit;
pub const stream_pump = core.stream_pump;

pub const transport = @import("transport/root.zig");
pub const engine = @import("engine/root.zig");
pub const dns_cache = @import("dns_cache.zig");
pub const data_io = @import("io/bio_data.zig");
pub const pool = transport.h2.pool;
pub const tls = @import("tls.zig");
pub const http2 = transport.h2.codec;

pub const Engine = engine.Engine;
pub const Config = transport.Config;
pub const network = transport.network;
pub const WakeEvent = engine.WakeEvent;

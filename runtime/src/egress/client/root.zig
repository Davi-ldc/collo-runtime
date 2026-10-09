//! The gateway's outbound HTTP client: the fetch task model, the engine that
//! runs tasks, and the transport, TLS, HTTP/2, DNS and I/O modules beneath it.
//!
//! Only gateway code imports this module. A worker has no network and links
//! only `collo_egress_core`, the body and credit primitives it shares with
//! this client, so transport policy and results stay inside the gateway.

pub const core = @import("collo_egress_core");

pub const task = @import("task.zig");
pub const body_credit = core.body_credit;
pub const fetch_body = core.fetch_body;
pub const stream_pump = core.stream_pump;
pub const decompress = core.decompress;

pub const transport = @import("collo_egress_transport");
pub const engine = @import("engine/root.zig");
pub const dns_cache = @import("collo_egress_dns_cache");
pub const io = @import("collo_egress_io");
pub const data_io = @import("collo_egress_data_io");
pub const pool = @import("collo_egress_pool");
pub const readiness = @import("collo_egress_readiness");
pub const tls = @import("collo_egress_tls");
pub const http2 = @import("collo_egress_http2");

pub const Result = task.Result;
pub const Task = task.Task;
pub const FetchBody = fetch_body.Body;
pub const FetchBodyReadKind = fetch_body.ReadKind;
pub const FetchBodyWaiter = fetch_body.Waiter;
pub const FetchBodyPullWaiter = fetch_body.PullWaiter;
pub const StreamPump = stream_pump.Pump;

pub const Engine = engine.Engine;
pub const EngineThreadConfig = engine.ThreadConfig;
pub const EngineH2Stats = engine.H2Stats;
pub const Config = transport.Config;
pub const DnsCache = transport.DnsCache;
pub const EgressPolicy = transport.EgressPolicy;
pub const RequestTarget = transport.RequestTarget;
pub const ResolvedTarget = transport.ResolvedTarget;
pub const WakeEvent = engine.WakeEvent;
pub const WakeFn = engine.WakeFn;
pub const ipv4Bytes = transport.ipv4Bytes;

//! Outbound HTTP transport for the gateway: request planning and policy,
//! connect, the wire every connection's bytes move through (`wire.zig`, TLS
//! over memory BIOs or plain), and the HTTP/1 and HTTP/2 protocols.
//!
//! A destination passes the fetch's network policy before any socket opens:
//! each hop's scheme, host and port before DNS, and every DNS answer,
//! including those a connect never tries, after it (`request/policy.zig`).
//! `network` re-exports `collo_network`, whose `Policy` every `Config`
//! names, so callers build configurations from this module alone.

const core = @import("collo_egress_core");
const dns_cache = @import("../dns_cache.zig");

pub const network = @import("collo_network");
pub const config = @import("config.zig");
pub const tls = @import("../tls.zig");
pub const policy = @import("request/policy.zig");
pub const headers = @import("request/headers.zig");
pub const request_plan = @import("request/plan.zig");
pub const redirect = @import("request/redirect.zig");
pub const connect = @import("connect.zig");
pub const wire = @import("wire.zig");
pub const http1 = @import("http1/root.zig");
pub const http1_protocol = @import("http1/protocol.zig");
pub const h2 = @import("h2/root.zig");

pub const decompress = core.decompress;

pub const Header = headers.Header;
pub const DnsCache = dns_cache.Cache;

pub const default_http2_max_outgoing_buffer_bytes = config.default_http2_max_outgoing_buffer_bytes;
pub const default_wire_buffer_bytes = config.default_wire_buffer_bytes;
pub const PoolIsolationId = config.PoolIsolationId;
pub const zero_pool_isolation_id = config.zero_pool_isolation_id;
pub const IoInterest = config.IoInterest;
pub const IoStep = config.IoStep;
pub const ApplicationProtocol = tls.ApplicationProtocol;
pub const Protocol = config.Protocol;
pub const Config = config.Config;

pub const parseTarget = policy.parseTarget;
pub const admitResolvedAddresses = policy.admitResolvedAddresses;
pub const denialOf = policy.denialOf;
pub const ipv4Bytes = policy.ipv4Bytes;

pub const parseFetchHeaders = headers.parseFetchHeaders;
pub const cloneHeaders = headers.cloneHeaders;
pub const freeHeaders = headers.freeHeaders;

pub const RequestPlan = request_plan.RequestPlan;
pub const OriginKey = request_plan.OriginKey;
pub const prepareRequest = request_plan.prepareRequest;

pub const RedirectMode = redirect.RedirectMode;
pub const FetchOptions = redirect.FetchOptions;
pub const RedirectTarget = redirect.RedirectTarget;
pub const RedirectBody = redirect.RedirectBody;
pub const redirectTarget = redirect.redirectTarget;

pub const Wire = wire.Wire;

pub const StreamedResponseHead = http1.StreamedResponseHead;
pub const BodyReadyEvent = http1.BodyReadyEvent;
pub const Http1BodyContinuation = http1.Http1BodyContinuation;
pub const Http1Pool = http1.Http1Pool;
pub const Http1Exchange = http1.Http1Exchange;
pub const isReplayableBeforeResponse = http1.isReplayableBeforeResponse;

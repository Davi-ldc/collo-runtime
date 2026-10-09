//! Outbound HTTP transport for the gateway: request planning and policy,
//! connect, TLS over a socket or a memory BIO, and the HTTP/1 and HTTP/2
//! wire protocols.
//!
//! A destination passes the egress policy before any socket opens: the URL is
//! validated, and every DNS answer, including those a connect never tries, is
//! checked against the ranges the policy blocks.

const core = @import("collo_egress_core");
const dns_cache = @import("collo_egress_dns_cache");

pub const config = @import("config.zig");
pub const tls = @import("collo_egress_tls");
pub const policy = @import("request/policy.zig");
pub const headers = @import("request/headers.zig");
pub const request_plan = @import("request/plan.zig");
pub const redirect = @import("request/redirect.zig");
pub const cancel_probe = @import("cancel_probe.zig");
pub const connection = @import("connection.zig");
pub const connect = @import("connect.zig");
pub const tls_bio = @import("tls_bio/root.zig");
pub const http1 = @import("http1/root.zig");
pub const http1_protocol = @import("http1/protocol/root.zig");
pub const h2 = @import("h2/root.zig");

pub const decompress = core.decompress;

pub const Header = headers.Header;
pub const DnsCache = dns_cache.Cache;
pub const DnsCacheConfig = dns_cache.Config;

pub const default_http2_max_outgoing_buffer_bytes = config.default_http2_max_outgoing_buffer_bytes;
pub const default_tls_ciphertext_buffer_bytes = config.default_tls_ciphertext_buffer_bytes;
pub const PoolIsolationId = config.PoolIsolationId;
pub const SecurityCellId = config.SecurityCellId;
pub const zero_pool_isolation_id = config.zero_pool_isolation_id;
pub const IoInterest = config.IoInterest;
pub const IoStep = config.IoStep;
pub const ApplicationProtocol = tls.ApplicationProtocol;
pub const Protocol = config.Protocol;
pub const Config = config.Config;

pub const EgressPolicy = policy.EgressPolicy;
pub const RequestTarget = policy.RequestTarget;
pub const ResolvedTarget = policy.ResolvedTarget;
pub const validateProtocol = policy.validateProtocol;
pub const ipv4Bytes = policy.ipv4Bytes;

pub const ParsedHeaders = headers.ParsedHeaders;
pub const parseFetchHeaders = headers.parseFetchHeaders;
pub const cloneHeaders = headers.cloneHeaders;
pub const freeHeaders = headers.freeHeaders;

pub const RequestPlan = request_plan.RequestPlan;
pub const prepareRequest = request_plan.prepareRequest;
pub const appendResponseChunk = request_plan.appendResponseChunk;

pub const RedirectMode = redirect.RedirectMode;
pub const FetchOptions = redirect.FetchOptions;
pub const RedirectTarget = redirect.RedirectTarget;
pub const redirectTarget = redirect.redirectTarget;

pub const CancelProbe = cancel_probe.CancelProbe;
pub const StreamedResponseHead = http1.StreamedResponseHead;
pub const Http1OwnedResponseHead = http1.OwnedResponseHead;
pub const BodyReadyEvent = http1.BodyReadyEvent;
pub const Http1BodyReadyFn = http1.Http1BodyReadyFn;
pub const Http1BodyContinuation = http1.Http1BodyContinuation;
pub const Http1DriveBudget = http1.Http1DriveBudget;
pub const Http1Pool = http1.Http1Pool;
pub const Http1Exchange = http1.Http1Exchange;

pub const HttpConnection = connection.HttpConnection;
pub const TlsBioTransport = tls_bio.TlsBioTransport;
pub const setFdNonblocking = connection.setFdNonblocking;

pub const connectWithTimeout = connect.connectWithTimeout;
pub const connectWithProbe = connect.connectWithProbe;
pub const connectStreamWithReadiness = connect.connectStreamWithReadiness;

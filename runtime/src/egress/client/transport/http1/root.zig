//! HTTP/1 egress client: the keep-alive connection pool, the rules that decide
//! when a connection may be reused or a request replayed, and the public
//! surface over the exchange (exchange.zig), the body continuation (body.zig)
//! and the shared wire helpers (wire.zig).
//!
//! Every pool call runs on the engine's owner thread. A connection is pooled
//! only with nothing left unread on the socket or inside TLS, and after a
//! response only when that response ended by its own framing, because any
//! leftover byte would be read as the next request's response head. Pool keys
//! include the security cell and policy ids the gateway gives each fetch and
//! the config fields that shape a dial, so a pooled connection never crosses
//! a security cell or policy.

const std = @import("std");
const core = @import("collo_egress_core");

const config_mod = @import("../config.zig");
const connection_mod = @import("../connection.zig");
const http1 = @import("protocol/root.zig");
const http1_body = @import("body.zig");
const http1_wire = @import("wire.zig");
const request_plan_mod = @import("../request/plan.zig");
const readiness = @import("collo_egress_readiness");

const decompress = core.decompress;

const Config = config_mod.Config;
const HttpConnection = connection_mod.HttpConnection;
const PoolIsolationId = config_mod.PoolIsolationId;
const Protocol = config_mod.Protocol;
const RequestPlan = request_plan_mod.RequestPlan;

pub const StreamedResponseHead = http1_wire.StreamedResponseHead;
pub const OwnedResponseHead = http1_wire.OwnedResponseHead;
pub const HeadProgress = http1_wire.HeadProgress;
pub const keepAliveTimeoutNs = http1_wire.keepAliveTimeoutNs;

pub const BodyReadyEvent = http1_body.BodyReadyEvent;
pub const Http1BodyReadyFn = http1_body.Http1BodyReadyFn;
pub const Http1BodyContinuation = http1_body.Continuation;
pub const Http1DriveBudget = http1_body.DriveBudget;

const exchange_mod = @import("exchange.zig");
pub const Http1Exchange = exchange_mod.Exchange;

pub const Http1Pool = struct {
    allocator: std.mem.Allocator,
    entries: std.array_list.Aligned(Entry, null) = .empty,
    /// Every caller runs on the owner thread (exchanges, body continuations
    /// and the ALPN-h1 handoff in putAdopted), so this lock over the entry
    /// list and the buffer freelist is never contended. deinit takes no lock
    /// and requires the engine's owner thread to have parked.
    mutex: std.Thread.Mutex = .{},
    /// Freelist of body-continuation read buffers, each
    /// `continuation_read_buffer_bytes` long. A continuation holds one from
    /// init to deinit, so recycling saves an allocation and a free per
    /// streamed response. The engine sets `read_buffer_retain_max` from
    /// `owner_read_buffer_retain` (engine/root.zig) at start; a buffer
    /// released beyond it is freed. deinit frees the rest, after every
    /// continuation has ended.
    read_buffers: std.array_list.Aligned([]u8, null) = .empty,
    read_buffer_retain_max: usize = default_read_buffer_retain,

    pub const default_read_buffer_retain: usize = 4;

    pub fn acquireBodyReadBuffer(self: *Http1Pool) ![]u8 {
        self.mutex.lock();
        const pooled = self.read_buffers.pop();
        self.mutex.unlock();
        if (pooled) |buffer|
            return buffer;
        return self.allocator.alloc(u8, http1_body.continuation_read_buffer_bytes);
    }

    pub fn releaseBodyReadBuffer(self: *Http1Pool, buffer: []u8) void {
        std.debug.assert(buffer.len == http1_body.continuation_read_buffer_bytes);
        self.mutex.lock();
        if (self.read_buffers.items.len < self.read_buffer_retain_max) {
            // The freelist only saves allocations, so when growing it fails
            // the buffer is freed instead.
            self.read_buffers.append(self.allocator, buffer) catch {
                self.mutex.unlock();
                self.allocator.free(buffer);
                return;
            };
            self.mutex.unlock();
            return;
        }
        self.mutex.unlock();
        self.allocator.free(buffer);
    }

    pub const Entry = struct {
        key: Key,
        connection: HttpConnection,
        created_mono_ns: u64,
        last_used_mono_ns: u64,
        expires_mono_ns: u64,
        requests_served: usize,

        fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
            self.key.deinit(allocator);
            self.connection.deinit();
            self.* = undefined;
        }
    };

    pub const LeasedConnection = struct {
        connection: HttpConnection,
        created_mono_ns: u64,
        requests_served: usize = 0,
        from_pool: bool = false,

        pub fn deinit(self: *LeasedConnection) void {
            self.connection.deinit();
            self.* = undefined;
        }
    };

    pub const Key = struct {
        authority_host_lower: []u8,
        port: u16,
        protocol: Protocol,
        insecure_tls: bool,
        allow_private_networks: bool,
        socket_timeout_ms: u32,
        pool_security_cell_id: PoolIsolationId,
        pool_policy_id: PoolIsolationId,

        pub fn init(allocator: std.mem.Allocator, plan: *const RequestPlan, config: Config) !Key {
            const host = try allocator.dupe(u8, plan.target.authority_host);
            errdefer allocator.free(host);
            _ = std.ascii.lowerString(host, host);
            return .{
                .authority_host_lower = host,
                .port = plan.target.port,
                .protocol = plan.target.protocol,
                .insecure_tls = config.insecure_tls,
                .allow_private_networks = config.allow_private_networks,
                .socket_timeout_ms = config.socket_timeout_ms,
                .pool_security_cell_id = config.pool_security_cell_id,
                .pool_policy_id = config.pool_policy_id,
            };
        }

        fn deinit(self: *Key, allocator: std.mem.Allocator) void {
            allocator.free(self.authority_host_lower);
            self.* = undefined;
        }

        fn matches(self: Key, plan: *const RequestPlan, config: Config) bool {
            return self.port == plan.target.port and
                self.protocol == plan.target.protocol and
                self.insecure_tls == config.insecure_tls and
                self.allow_private_networks == config.allow_private_networks and
                self.socket_timeout_ms == config.socket_timeout_ms and
                std.mem.eql(u8, &self.pool_security_cell_id, &config.pool_security_cell_id) and
                std.mem.eql(u8, &self.pool_policy_id, &config.pool_policy_id) and
                std.ascii.eqlIgnoreCase(self.authority_host_lower, plan.target.authority_host);
        }
    };

    pub fn init(allocator: std.mem.Allocator) Http1Pool {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Http1Pool) void {
        for (self.entries.items) |*entry|
            entry.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        for (self.read_buffers.items) |buffer|
            self.allocator.free(buffer);
        self.read_buffers.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn take(self: *Http1Pool, plan: *const RequestPlan, config: Config, now_ns: u64) ?LeasedConnection {
        self.mutex.lock();
        defer self.mutex.unlock();
        var index: usize = 0;
        while (index < self.entries.items.len) {
            if (!self.entries.items[index].key.matches(plan, config)) {
                index += 1;
                continue;
            }
            if (now_ns >= self.entries.items[index].expires_mono_ns or
                !connectionIsLive(&self.entries.items[index].connection))
            {
                var removed = self.entries.orderedRemove(index);
                removed.deinit(self.allocator);
                continue;
            }
            var entry = self.entries.orderedRemove(index);
            const leased = LeasedConnection{
                .connection = entry.connection,
                .created_mono_ns = entry.created_mono_ns,
                .requests_served = entry.requests_served,
                .from_pool = true,
            };
            entry.key.deinit(self.allocator);
            entry.connection = undefined;
            return leased;
        }
        return null;
    }

    pub fn put(
        self: *Http1Pool,
        plan: *const RequestPlan,
        config: Config,
        lease: *LeasedConnection,
        now_ns: u64,
        keep_alive_hint_ns: ?u64,
    ) !void {
        const key = try Key.init(self.allocator, plan, config);
        const connection = lease.connection;
        lease.connection = undefined;
        self.putWithKey(
            key,
            config,
            connection,
            lease.created_mono_ns,
            lease.requests_served,
            now_ns,
            keep_alive_hint_ns,
        );
    }

    /// Takes ownership of `key_in` and `connection_in` on every path. A
    /// connection the pool refuses (not clean for reuse, at the per-connection
    /// request cap, pooling disabled) is closed without an error, since
    /// pooling only saves dials. A full pool evicts its least recently used
    /// entry instead of refusing.
    fn putWithKey(
        self: *Http1Pool,
        key_in: Key,
        config: Config,
        connection_in: HttpConnection,
        created_mono_ns: u64,
        requests_served: usize,
        now_ns: u64,
        keep_alive_hint_ns: ?u64,
    ) void {
        var key = key_in;
        var connection = connection_in;
        if (!connection.cleanForReuse()) {
            key.deinit(self.allocator);
            connection.deinit();
            return;
        }
        const next_requests_served = std.math.add(usize, requests_served, 1) catch {
            key.deinit(self.allocator);
            connection.deinit();
            return;
        };
        if (config.http1_pool_max_entries == 0 or
            (config.http1_pool_max_requests_per_connection != 0 and
                next_requests_served >= config.http1_pool_max_requests_per_connection))
        {
            key.deinit(self.allocator);
            connection.deinit();
            return;
        }
        self.mutex.lock();
        defer self.mutex.unlock();
        self.evictExpiredLocked(config, now_ns);
        while (self.entries.items.len >= config.http1_pool_max_entries)
            self.evictOldestLocked();
        self.entries.append(self.allocator, .{
            .key = key,
            .connection = connection,
            .created_mono_ns = created_mono_ns,
            .last_used_mono_ns = now_ns,
            .expires_mono_ns = idleExpiryMonoNs(config, now_ns, keep_alive_hint_ns),
            .requests_served = next_requests_served,
        }) catch {
            key.deinit(self.allocator);
            connection.deinit();
        };
    }

    /// Pools a connection whose TLS handshake a connector completed for
    /// HTTP/2 but whose ALPN chose http/1.1, so the first HTTP/1 exchange for
    /// that origin leases it instead of dialing again.
    pub fn putAdopted(
        self: *Http1Pool,
        plan: *const RequestPlan,
        config: Config,
        connection: HttpConnection,
    ) void {
        var owned = connection;
        const key = Key.init(self.allocator, plan, config) catch {
            owned.deinit();
            return;
        };
        const now_ns = monotonicNowNs();
        self.putWithKey(key, config, owned, now_ns, 0, now_ns, null);
    }

    /// Idle deadline for a pooled entry: the configured idle timeout (zero
    /// disables it), capped by the server's `Keep-Alive: timeout=N` hint when
    /// one was sent.
    fn idleExpiryMonoNs(config: Config, now_ns: u64, keep_alive_hint_ns: ?u64) u64 {
        var expires: u64 = std.math.maxInt(u64);
        if (config.http1_pool_idle_timeout_ns != 0)
            expires = now_ns +| config.http1_pool_idle_timeout_ns;
        if (keep_alive_hint_ns) |hint|
            expires = @min(expires, now_ns +| hint);
        return expires;
    }

    pub fn isHttp1RetryableBeforeResponse(method: []const u8, body: []const u8) bool {
        if (body.len != 0)
            return false;
        return std.ascii.eqlIgnoreCase(method, "GET") or
            std.ascii.eqlIgnoreCase(method, "HEAD") or
            std.ascii.eqlIgnoreCase(method, "OPTIONS") or
            std.ascii.eqlIgnoreCase(method, "DELETE");
    }

    pub fn evictExpired(self: *Http1Pool, config: Config, now_ns: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.evictExpiredLocked(config, now_ns);
    }

    fn evictExpiredLocked(self: *Http1Pool, config: Config, now_ns: u64) void {
        var index: usize = 0;
        while (index < self.entries.items.len) {
            const entry = &self.entries.items[index];
            const idle_expired = now_ns >= entry.expires_mono_ns;
            const age_expired = config.http1_pool_max_connection_age_ns != 0 and
                now_ns -| entry.created_mono_ns >= config.http1_pool_max_connection_age_ns;
            if (!idle_expired and !age_expired) {
                index += 1;
                continue;
            }
            var removed = self.entries.orderedRemove(index);
            removed.deinit(self.allocator);
        }
    }

    fn evictOldestLocked(self: *Http1Pool) void {
        if (self.entries.items.len == 0)
            return;
        var oldest_index: usize = 0;
        var oldest_used = self.entries.items[0].last_used_mono_ns;
        for (self.entries.items[1..], 1..) |entry, index| {
            if (entry.last_used_mono_ns >= oldest_used)
                continue;
            oldest_index = index;
            oldest_used = entry.last_used_mono_ns;
        }
        var removed = self.entries.orderedRemove(oldest_index);
        removed.deinit(self.allocator);
    }
};

/// What a body continuation needs to return its connection to the pool after
/// a clean finish: the pool key, built while the exchange still held the
/// request plan the continuation outlives, the lease's creation time and
/// request count, and the response's Keep-Alive hint.
pub const ConnectionReturn = struct {
    pool: *Http1Pool,
    key: Http1Pool.Key,
    config: Config,
    created_mono_ns: u64,
    requests_served: usize,
    keep_alive_hint_ns: ?u64,

    /// Consumes the ticket and the connection, offering the connection to the
    /// pool.
    pub fn give(self: *ConnectionReturn, connection: HttpConnection) void {
        const now_ns = monotonicNowNs();
        self.pool.putWithKey(
            self.key,
            self.config,
            connection,
            self.created_mono_ns,
            self.requests_served,
            now_ns,
            self.keep_alive_hint_ns,
        );
        self.* = undefined;
    }

    /// Consumes the ticket without pooling; the caller still owns the
    /// connection and closes it.
    pub fn discard(self: *ConnectionReturn) void {
        self.key.deinit(self.pool.allocator);
        self.* = undefined;
    }
};

/// Liveness probe for an idle pooled connection, without blocking. EOF, a
/// socket error or any unread byte (an early 408, a TLS close_notify) means
/// the connection cannot be reused cleanly. On `.fd_tls` the peek sees only
/// ciphertext still on the socket, so plaintext already decrypted into
/// BoringSSL or the reader buffer (packed after the previous body in the same
/// TLS record) is checked first; the next request would otherwise read it as
/// its response head.
fn connectionIsLive(connection: *const HttpConnection) bool {
    switch (connection.*) {
        .fd_tls => |tls| if (tls.hasBufferedPlaintext())
            return false,
        else => {},
    }
    var probe: [1]u8 = undefined;
    _ = std.posix.recv(
        connection.fd(),
        &probe,
        std.posix.MSG.PEEK | std.posix.MSG.DONTWAIT,
    ) catch |err| return err == error.WouldBlock;
    return false;
}

/// Replaying a request from a pooled connection is safe only when the failure
/// shows the server never started a response: a write failure from a dead
/// connection, or EOF or reset before the first response byte. Timeouts and
/// malformed responses must not replay a request the server may have
/// processed.
pub fn isHttp1ConnectionDeathBeforeResponse(err: anyerror, progress: HeadProgress) bool {
    if (progress.response_bytes_received)
        return false;
    return switch (err) {
        error.FetchWriteFailed,
        error.WriteFailed,
        error.TlsWriteFailed,
        error.BrokenPipe,
        error.ConnectionResetByPeer,
        error.FetchResponseTruncated,
        => true,
        else => false,
    };
}

/// Decoder for the response body. A transfer coding before the final chunked
/// coding (RFC 9112 §6.1) is decoded after de-chunking by the same decoder as
/// Content-Encoding. Together with a content coding it would need two chained
/// decoders, which the pump does not have, so that combination is rejected.
pub fn responseEncodingForHead(head: http1.ResponseHead) !decompress.Encoding {
    const content_encoding = try decompress.encodingFromHeaders(head.headers);
    if (head.transfer_coding == .none)
        return content_encoding;
    if (content_encoding != .identity)
        return error.UnsupportedTransferEncoding;
    return switch (head.transfer_coding) {
        .none => unreachable,
        .gzip => .gzip,
        .deflate => .deflate,
        .br => .br,
    };
}

fn monotonicNowNs() u64 {
    return readiness.monotonicNowNs() catch std.math.maxInt(u64);
}

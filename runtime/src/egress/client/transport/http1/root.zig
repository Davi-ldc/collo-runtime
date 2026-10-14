//! HTTP/1 egress client: the keep-alive pool, the rules that decide when a
//! connection may be reused or a request replayed, and the public surface
//! over the exchange (`exchange.zig`), the body continuation (`body.zig`),
//! the message rules (`message.zig`) and the wire protocol (`protocol.zig`).
//!
//! Every pool call runs on the engine's owner thread. A wire is pooled only
//! when it holds no unread byte and has seen neither EOF nor a failed
//! receive or send (`Wire.cleanForReuse`), and after a response only when
//! that response ended by its own framing,
//! because any leftover byte would be read as the next request's response
//! head. Entries are keyed by `request/plan.zig:OriginKey`, which carries the
//! security cell and policy ids the gateway gives each fetch, so a pooled
//! wire never crosses a security cell or policy.
//!
//! Every wire belongs to the engine's data driver while it lives, which may
//! still have a receive or send in flight on it, so nothing here frees one:
//! every wire the pool or a fetch drops goes back through `releaseWire` to
//! the engine's `WireHooks`. The engine keeps a receive armed on each idle
//! wire (`idleEntries`), so a close or a stray byte that arrives while it
//! idles makes it unclean, and `evictUnusable` drops it. That receive is
//! armed only at the engine's next wait and reported only when a wait serves
//! it, while a fetch can lease the wire before either, in the iteration that
//! pooled it, so `take` has the engine bring each wire up to date with its
//! socket before it judges the wire.

const std = @import("std");
const core = @import("collo_egress_core");

const config_mod = @import("../config.zig");
const http1_body = @import("body.zig");
const message = @import("message.zig");
const protocol = @import("protocol.zig");
const request_plan_mod = @import("../request/plan.zig");
const wire_mod = @import("../wire.zig");

const decompress = core.decompress;

const Config = config_mod.Config;
const OriginKey = request_plan_mod.OriginKey;
const Wire = wire_mod.Wire;

pub const StreamedResponseHead = message.StreamedResponseHead;
pub const OwnedResponseHead = message.OwnedResponseHead;
pub const HeadProgress = message.HeadProgress;
pub const keepAliveTimeoutNs = message.keepAliveTimeoutNs;

pub const BodyReadyEvent = http1_body.BodyReadyEvent;
pub const Http1BodyReadyFn = http1_body.Http1BodyReadyFn;
pub const Http1BodyContinuation = http1_body.Continuation;

const exchange_mod = @import("exchange.zig");
pub const Http1Exchange = exchange_mod.Exchange;

/// What the pool asks of the engine that owns its wires through its data
/// driver; both functions get `context`.
pub const WireHooks = struct {
    context: ?*anyopaque,
    /// Takes a wire the HTTP/1 code no longer needs: the engine releases its
    /// data-driver registration and then frees it.
    release_fn: *const fn (?*anyopaque, *Wire) void,
    /// Brings an idle wire up to date with what its socket delivered, as
    /// `io/bio_data.zig:Driver.refreshIdleWire` does, or returns false when
    /// it cannot, and the pool then drops the wire instead of leasing it.
    refresh_fn: *const fn (?*anyopaque, *Wire) bool,
};

pub const Http1Pool = struct {
    allocator: std.mem.Allocator,
    hooks: WireHooks,
    entries: std.array_list.Aligned(Entry, null) = .empty,
    /// Freelist of body-continuation read buffers, each
    /// `continuation_read_buffer_bytes` long. A continuation holds one from
    /// init to deinit, so recycling saves an allocation and a free per
    /// streamed response. A buffer released beyond `read_buffer_retain_max`
    /// is freed, and deinit frees the rest, after every continuation ended.
    read_buffers: std.array_list.Aligned([]u8, null) = .empty,
    read_buffer_retain_max: usize = default_read_buffer_retain,

    pub const default_read_buffer_retain: usize = 4;

    pub const Entry = struct {
        key: OriginKey,
        wire: *Wire,
        created_mono_ns: u64,
        last_used_mono_ns: u64,
        /// The earlier of the idle deadline and the age limit, both taken at
        /// `put` from the config of the fetch that returned the wire.
        expires_mono_ns: u64,
        requests_served: usize,
    };

    pub const LeasedConnection = struct {
        wire: *Wire,
        created_mono_ns: u64,
        requests_served: usize = 0,
        from_pool: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator, hooks: WireHooks) Http1Pool {
        return .{ .allocator = allocator, .hooks = hooks };
    }

    pub fn deinit(self: *Http1Pool) void {
        for (self.entries.items) |entry|
            self.releaseWire(entry.wire);
        self.entries.deinit(self.allocator);
        for (self.read_buffers.items) |buffer|
            self.allocator.free(buffer);
        self.read_buffers.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn releaseWire(self: *const Http1Pool, wire: *Wire) void {
        self.hooks.release_fn(self.hooks.context, wire);
    }

    /// The pooled wires, for the engine to watch with a receive armed until
    /// each entry's `expires_mono_ns`.
    pub fn idleEntries(self: *const Http1Pool) []const Entry {
        return self.entries.items;
    }

    pub fn acquireBodyReadBuffer(self: *Http1Pool) ![]u8 {
        if (self.read_buffers.pop()) |buffer|
            return buffer;
        return self.allocator.alloc(u8, http1_body.continuation_read_buffer_bytes);
    }

    pub fn releaseBodyReadBuffer(self: *Http1Pool, buffer: []u8) void {
        std.debug.assert(buffer.len == http1_body.continuation_read_buffer_bytes);
        if (self.read_buffers.items.len < self.read_buffer_retain_max) {
            // The freelist only saves allocations, so when growing it fails
            // the buffer is freed instead.
            self.read_buffers.append(self.allocator, buffer) catch {
                self.allocator.free(buffer);
            };
            return;
        }
        self.allocator.free(buffer);
    }

    /// Leases a clean pooled wire for `key`, after dropping the expired and
    /// unclean entries, or returns null when none remains. Each candidate is
    /// brought up to date with its socket first (`WireHooks.refresh_fn`), and
    /// one that turns out unclean is dropped.
    pub fn take(self: *Http1Pool, key: *const OriginKey, now_ns: u64) ?LeasedConnection {
        self.evictUnusable(now_ns);
        var index: usize = 0;
        while (index < self.entries.items.len) {
            if (!self.entries.items[index].key.eql(key)) {
                index += 1;
                continue;
            }
            const entry = self.entries.orderedRemove(index);
            if (!self.hooks.refresh_fn(self.hooks.context, entry.wire) or !entry.wire.cleanForReuse()) {
                self.releaseWire(entry.wire);
                continue;
            }
            return .{
                .wire = entry.wire,
                .created_mono_ns = entry.created_mono_ns,
                .requests_served = entry.requests_served,
                .from_pool = true,
            };
        }
        return null;
    }

    /// Offers a leased wire back after a response that allows reuse. Takes
    /// the wire on every path: a wire the pool refuses (unclean, at the
    /// per-connection request cap, pooling disabled) is released, since
    /// pooling only saves dials. A full pool evicts its least recently used
    /// entry instead of refusing.
    pub fn put(
        self: *Http1Pool,
        key: OriginKey,
        config: Config,
        lease: LeasedConnection,
        now_ns: u64,
        keep_alive_hint_ns: ?u64,
    ) void {
        const next_requests_served = lease.requests_served +| 1;
        if (!lease.wire.cleanForReuse() or
            config.http1_pool_max_entries == 0 or
            (config.http1_pool_max_requests_per_connection != 0 and
                next_requests_served >= config.http1_pool_max_requests_per_connection))
        {
            self.releaseWire(lease.wire);
            return;
        }
        self.evictUnusable(now_ns);
        while (self.entries.items.len >= config.http1_pool_max_entries)
            self.evictOldest();
        self.entries.append(self.allocator, .{
            .key = key,
            .wire = lease.wire,
            .created_mono_ns = lease.created_mono_ns,
            .last_used_mono_ns = now_ns,
            .expires_mono_ns = expiryMonoNs(config, lease.created_mono_ns, now_ns, keep_alive_hint_ns),
            .requests_served = next_requests_served,
        }) catch {
            self.releaseWire(lease.wire);
        };
    }

    /// Releases every entry whose deadline passed or whose wire is no longer
    /// clean.
    pub fn evictUnusable(self: *Http1Pool, now_ns: u64) void {
        var index: usize = 0;
        while (index < self.entries.items.len) {
            const entry = &self.entries.items[index];
            if (now_ns < entry.expires_mono_ns and entry.wire.cleanForReuse()) {
                index += 1;
                continue;
            }
            const removed = self.entries.orderedRemove(index);
            self.releaseWire(removed.wire);
        }
    }

    /// Deadline for a pooled entry: the configured idle timeout (zero
    /// disables it), capped by the server's `Keep-Alive: timeout=N` hint
    /// when one was sent and by the connection age limit (zero disables it).
    fn expiryMonoNs(config: Config, created_mono_ns: u64, now_ns: u64, keep_alive_hint_ns: ?u64) u64 {
        var expires: u64 = std.math.maxInt(u64);
        if (config.http1_pool_idle_timeout_ns != 0)
            expires = now_ns +| config.http1_pool_idle_timeout_ns;
        if (keep_alive_hint_ns) |hint|
            expires = @min(expires, now_ns +| hint);
        if (config.http1_pool_max_connection_age_ns != 0)
            expires = @min(expires, created_mono_ns +| config.http1_pool_max_connection_age_ns);
        return expires;
    }

    fn evictOldest(self: *Http1Pool) void {
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
        const removed = self.entries.orderedRemove(oldest_index);
        self.releaseWire(removed.wire);
    }
};

/// What a body continuation needs to return its wire to the pool after a
/// clean finish: the origin key, the lease's creation time and request
/// count, and the response's Keep-Alive hint.
pub const ConnectionReturn = struct {
    pool: *Http1Pool,
    key: OriginKey,
    config: Config,
    created_mono_ns: u64,
    requests_served: usize,
    keep_alive_hint_ns: ?u64,

    /// Consumes the ticket and the wire, offering the wire to the pool.
    pub fn give(self: ConnectionReturn, wire: *Wire, now_ns: u64) void {
        self.pool.put(self.key, self.config, .{
            .wire = wire,
            .created_mono_ns = self.created_mono_ns,
            .requests_served = self.requests_served,
        }, now_ns, self.keep_alive_hint_ns);
    }
};

/// Whether a request may be sent again on a fresh connection when its
/// connection died before any response byte, as undici and Bun do it: an
/// idempotent method without a body, which the server cannot have acted on
/// in a way a second send would repeat. HTTP/1 and HTTP/2 share this rule.
pub fn isReplayableBeforeResponse(method: []const u8, body: []const u8) bool {
    if (body.len != 0)
        return false;
    return std.ascii.eqlIgnoreCase(method, "GET") or
        std.ascii.eqlIgnoreCase(method, "HEAD") or
        std.ascii.eqlIgnoreCase(method, "OPTIONS") or
        std.ascii.eqlIgnoreCase(method, "DELETE");
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
pub fn responseEncodingForHead(head: protocol.ResponseHead) !decompress.Encoding {
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

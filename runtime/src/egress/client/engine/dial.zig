//! Dials on the owner thread, and the origin records that hold the shared
//! ones.
//!
//! A dial turns a hop's origin into a wire in up to three phases, each
//! bounded by its own stall deadline (`socket_timeout_ms` from the phase's
//! start):
//! - resolving: the DNS cache answers at once, or a resolver thread runs the
//!   lookup and the owner collects the dial's ticket after the cache's
//!   notify;
//! - connecting: Happy Eyeballs attempts (`transport/connect.zig`) as
//!   nonblocking sockets the data driver watches for writability, the next
//!   launch due as a wait deadline;
//! - handshaking, for https: the wire is registered in the owner's data
//!   driver and each of its completions steps the TLS handshake once.
//! Every resolved address passes the hop's admission before any socket opens
//! (`policy.admitResolvedAddresses`), and a resolution with any denied address
//! fails whole. ALPN then decides what the wire becomes, without moving it
//! between rings: an HTTP/2 pool entry for every waiting hop, or the HTTP/1
//! connection of the first waiting fetch.
//!
//! An origin record (`Origin`, keyed by `plan.zig:OriginKey`) holds the dial
//! that hops able to speak HTTP/2 share, and remembers an origin whose
//! handshake chose http/1.1, so its next fetches go straight to HTTP/1. An
//! HTTP/1 fetch dials alone and offers http/1.1 only, since its connection is
//! never shared.
//!
//! A new dial starts in the owner loop (`beginNew`), never inside the call
//! that created it, so a dial never completes or fails under a fetch still
//! being driven. A dial whose waiters all left is abandoned at once: its
//! sockets close through the data driver and its DNS ticket is forgotten. A
//! dial that fails fails its waiters, except that a hop which joined after
//! the dial started and still has budget of its own gets a fresh dial when
//! the dial timed out.
//!
//! The TLS handshake steps on the owner thread, so its crypto delays the
//! shard's other streams by one step at a time. Moving it to one helper
//! thread per shard changes only the handshaking phase: `beginHandshake`
//! would hand the connected socket to the helper instead of registering the
//! wire here, the helper would step `Wire.handshakeStep` on a ring of its
//! own, created before the seccomp filter, and post the handshaken wire back
//! as an owner message ending in `finishHandshake`. Resolving, connecting,
//! the origin records and everything from `finishHandshake` on stay as they
//! are.
//!
//! Thread: the engine's owner thread alone.

const std = @import("std");
const transport = @import("../transport/root.zig");
const dns_cache = @import("../dns_cache.zig");
const task_model = @import("../task.zig");
const owner_mod = @import("owner.zig");
const h2 = @import("h2.zig");
const h1 = @import("h1.zig");

const connect = transport.connect;
const network = transport.network;
const Hop = owner_mod.Hop;
const IoInterest = transport.IoInterest;
const OriginKey = transport.request_plan.OriginKey;
const Owner = owner_mod.Owner;
const Task = task_model.Task;
const Wire = transport.Wire;
const monotonicNowNs = transport.config.monotonicNowNs;

/// Origin records kept only to remember an http/1.1-only origin; past it the
/// least recently used such record goes, and its origin goes through one
/// shared dial again, where ALPN learns it anew. Records holding a dial
/// never count, since dials bound them.
const http1_memory_records_max: usize = 128;

pub const Origin = struct {
    key: OriginKey,
    /// The origin's last handshake chose http/1.1.
    http1_only: bool = false,
    /// The dial the origin's HTTP/2-capable hops share.
    shared_dial: ?*Dial = null,
    last_used: u64 = 0,
};

pub const Waiter = union(enum) {
    /// A hop able to speak HTTP/2: it opens a stream if the dial negotiates
    /// h2, and becomes an HTTP/1 fetch otherwise.
    hop: struct {
        hop: Hop,
        joined_mono_ns: u64,
    },
    /// An HTTP/1 fetch whose exchange waits for this dial's connection; it
    /// stays in the owner's HTTP/1 list meanwhile.
    h1: *h1.Fetch,
};

pub const Dial = struct {
    /// The record of a shared dial; null for an HTTP/1 fetch's own dial.
    origin: ?*Origin,
    key: OriginKey,
    /// The host the dial resolves and names in its TLS handshake, without
    /// IPv6 brackets or a trailing dot.
    server_name_bytes: [OriginKey.host_bytes_max]u8,
    server_name_len: u8,
    port: u16,
    admission: network.Admission,
    offer_h2: bool,
    /// The config of the hop that started the dial: its socket timeout, TLS
    /// knobs, buffer cap, isolation ids and HTTP/2 limits.
    config: transport.Config,
    waiters: std.ArrayListUnmanaged(Waiter) = .empty,
    phase: Phase = .starting,
    /// The current phase's stall deadline.
    phase_deadline_mono_ns: u64 = std.math.maxInt(u64),

    const Phase = union(enum) {
        /// Created, holding nothing; `beginNew` starts it.
        starting,
        resolving: dns_cache.Ticket,
        connecting: Connecting,
        handshaking: Handshaking,
    };

    const Connecting = struct {
        /// Owned; the schedule borrows it.
        addresses: []std.net.Address,
        schedule: connect.Schedule,
        attempts: [connect.max_parallel_attempts]std.posix.fd_t = @splat(-1),
        last_error: anyerror = error.HostLacksNetworkAddresses,
    };

    const Handshaking = struct {
        wire: *Wire,
        interest: IoInterest,
    };

    fn serverName(self: *const Dial) []const u8 {
        return self.server_name_bytes[0..self.server_name_len];
    }

    /// The sources this dial adds to the watch list.
    pub fn watchCount(self: *const Dial) usize {
        return switch (self.phase) {
            .starting => 0,
            .resolving, .handshaking => 1,
            .connecting => |*connecting| connecting.schedule.pending_count,
        };
    }

    fn phaseTimeoutError(self: *const Dial) anyerror {
        return switch (self.phase) {
            .starting, .connecting => error.FetchConnectTimeout,
            .resolving => error.DnsLookupTimeout,
            .handshaking => error.TlsHandshakeTimeout,
        };
    }

    /// The earliest request deadline among the waiters, each of which fails
    /// at its own deadline whatever the dial's phase.
    fn earliestWaiterDeadline(self: *const Dial) u64 {
        var earliest: u64 = std.math.maxInt(u64);
        for (self.waiters.items) |waiter| {
            const config = switch (waiter) {
                .hop => |*joined| joined.hop.config(),
                .h1 => |fetch| fetch.hop.config(),
            };
            earliest = @min(earliest, config.requestDeadlineOrUnbounded());
        }
        return earliest;
    }

    fn watchDeadline(self: *const Dial) u64 {
        var deadline = @min(self.phase_deadline_mono_ns, self.earliestWaiterDeadline());
        switch (self.phase) {
            .connecting => |*connecting| {
                if (connecting.schedule.launchDeadlineNs()) |launch_ns|
                    deadline = @min(deadline, launch_ns);
            },
            .starting, .resolving, .handshaking => {},
        }
        return deadline;
    }
};

/// Whether `key`'s origin last chose http/1.1, so its fetches skip HTTP/2.
pub fn knownHttp1Only(owner: *Owner, key: *const OriginKey) bool {
    const origin = findOrigin(owner, key) orelse return false;
    if (!origin.http1_only)
        return false;
    origin.last_used = nextOriginUse(owner);
    return true;
}

/// Parks `hop` on its origin's shared dial, starting one when none runs.
/// Takes `hop`.
pub fn joinShared(owner: *Owner, hop: Hop) void {
    var owned = hop;
    const now_ns = monotonicNowNs() catch 0;
    const origin = findOrCreateOrigin(owner, &owned.plan.origin_key) catch |err| {
        owner.failHop(&owned, err);
        return;
    };
    if (origin.shared_dial) |shared| {
        shared.waiters.append(owner.allocator, .{ .hop = .{ .hop = owned, .joined_mono_ns = now_ns } }) catch |err|
            owner.failHop(&owned, err);
        return;
    }
    const created = createDial(owner, origin, &owned.plan, owned.config().*, true) catch |err| {
        owner.failHop(&owned, err);
        releaseOrigin(owner, origin);
        return;
    };
    created.waiters.append(owner.allocator, .{ .hop = .{ .hop = owned, .joined_mono_ns = now_ns } }) catch |err| {
        owner.failHop(&owned, err);
        destroyDial(owner, created);
        return;
    };
    origin.shared_dial = created;
}

/// Starts a dial of `fetch`'s own, which it waits on. Fails with
/// `error.OutOfMemory` and leaves nothing behind.
pub fn startPrivate(owner: *Owner, fetch: *h1.Fetch) !*Dial {
    const created = try createDial(owner, null, &fetch.hop.plan, fetch.hop.config().*, false);
    created.waiters.append(owner.allocator, .{ .h1 = fetch }) catch |err| {
        destroyDial(owner, created);
        return err;
    };
    return created;
}

fn createDial(owner: *Owner, origin: ?*Origin, plan: *const transport.RequestPlan, config: transport.Config, offer_h2: bool) !*Dial {
    const server_name = plan.target.tls_server_name;
    if (server_name.len > OriginKey.host_bytes_max)
        return error.InvalidFetchUrl;
    try owner.dials.ensureUnusedCapacity(owner.allocator, 1);
    const created = try owner.allocator.create(Dial);
    created.* = .{
        .origin = origin,
        .key = plan.origin_key,
        .server_name_bytes = undefined,
        .server_name_len = @intCast(server_name.len),
        .port = plan.target.port,
        .admission = plan.target.admission,
        .offer_h2 = offer_h2,
        .config = config,
    };
    @memcpy(created.server_name_bytes[0..server_name.len], server_name);
    owner.dials.appendAssumeCapacity(created);
    owner.watch_dirty = true;
    return created;
}

/// Starts every dial created since the last call and returns whether there
/// was any. A start may finish or fail a dial at once (a cached failure, a
/// denied address), which settles its waiters here, in the loop, where no
/// fetch is being driven.
pub fn beginNew(owner: *Owner) bool {
    var begun = false;
    var index: usize = 0;
    while (index < owner.dials.items.len) {
        const pending = owner.dials.items[index];
        if (pending.phase != .starting) {
            index += 1;
            continue;
        }
        begin(owner, pending);
        begun = true;
        owner.watch_dirty = true;
        if (index < owner.dials.items.len and owner.dials.items[index] == pending)
            index += 1;
    }
    return begun;
}

fn begin(owner: *Owner, pending: *Dial) void {
    const lookup = owner.engine.dns_cache.lookup(owner.allocator, pending.serverName(), pending.port) catch |err| {
        fail(owner, pending, err);
        return;
    };
    switch (lookup) {
        .answer => |answer| resolved(owner, pending, answer),
        .pending => |ticket| {
            pending.phase = .{ .resolving = ticket };
            pending.phase_deadline_mono_ns = phaseDeadline(pending);
        },
    }
}

/// Collects the tickets of resolving dials after the DNS cache's notify.
pub fn collectAnswers(owner: *Owner) void {
    var index: usize = 0;
    while (index < owner.dials.items.len) {
        const pending = owner.dials.items[index];
        const ticket = switch (pending.phase) {
            .resolving => |held| held,
            .starting, .connecting, .handshaking => {
                index += 1;
                continue;
            },
        };
        const maybe_answer = owner.engine.dns_cache.collect(owner.allocator, ticket) catch |err| {
            // The cache consumed the ticket.
            pending.phase = .starting;
            fail(owner, pending, err);
            continue;
        };
        const answer = maybe_answer orelse {
            index += 1;
            continue;
        };
        pending.phase = .starting;
        resolved(owner, pending, answer);
        owner.watch_dirty = true;
        if (index < owner.dials.items.len and owner.dials.items[index] == pending)
            index += 1;
    }
}

fn resolved(owner: *Owner, pending: *Dial, answer: dns_cache.Answer) void {
    const addresses = switch (answer) {
        .failed => |err| {
            fail(owner, pending, err);
            return;
        },
        .resolved => |addresses| addresses,
    };
    transport.admitResolvedAddresses(pending.admission, addresses) catch |err| {
        owner.allocator.free(addresses);
        fail(owner, pending, err);
        return;
    };
    pending.phase = .{ .connecting = .{
        .addresses = addresses,
        .schedule = connect.Schedule.init(addresses),
    } };
    pending.phase_deadline_mono_ns = phaseDeadline(pending);
    launchAttempts(owner, pending, monotonicNowNs() catch std.math.maxInt(u64));
}

/// Starts every attempt due at `now_ns`. An attempt that cannot start or
/// fails at once hands its turn to the next candidate.
fn launchAttempts(owner: *Owner, pending: *Dial, now_ns: u64) void {
    const connecting = &pending.phase.connecting;
    while (connecting.schedule.launchDue(now_ns)) |launch| {
        const started = connect.startAttempt(launch.address) catch |err| {
            connecting.last_error = err;
            continue;
        };
        if (started.connected) {
            finishConnect(owner, pending, started.fd);
            return;
        }
        connecting.attempts[launch.slot] = started.fd;
        connecting.schedule.markPending(launch.slot, now_ns);
    }
    if (connecting.schedule.exhausted())
        connectFailed(owner, pending, connecting.last_error);
}

/// The connect poll of the attempt in `slot` reported: the connect ended.
pub fn attemptReady(owner: *Owner, pending: *Dial, slot: usize) void {
    const connecting = &pending.phase.connecting;
    const fd = connecting.attempts[slot];
    std.debug.assert(fd >= 0);
    owner.driver.cancelConnecting(fd);
    connecting.attempts[slot] = -1;
    connecting.schedule.markDone(slot);
    connect.finishAttempt(fd) catch |err| {
        std.posix.close(fd);
        connecting.last_error = err;
        launchAttempts(owner, pending, monotonicNowNs() catch std.math.maxInt(u64));
        return;
    };
    finishConnect(owner, pending, fd);
}

fn connectFailed(owner: *Owner, pending: *Dial, err: anyerror) void {
    // Every address failed, so the next dial asks DNS again rather than
    // retrying a stale answer.
    owner.engine.dns_cache.invalidate(pending.serverName(), pending.port);
    fail(owner, pending, err);
}

/// `fd` connected: the losing attempts close, and the socket becomes the
/// dial's wire.
fn finishConnect(owner: *Owner, pending: *Dial, fd: std.posix.fd_t) void {
    releasePhase(owner, pending);
    const stream: std.net.Stream = .{ .handle = fd };
    switch (pending.key.protocol) {
        .plain => {
            const wire = Wire.createPlain(owner.allocator, stream, pending.config.wire_buffer_bytes) catch |err| {
                fail(owner, pending, err);
                return;
            };
            complete(owner, pending, wire);
        },
        .tls => beginHandshake(owner, pending, stream),
    }
}

fn beginHandshake(owner: *Owner, pending: *Dial, stream: std.net.Stream) void {
    var session_key_buffer: [transport.tls.max_session_key_bytes]u8 = undefined;
    const session_key = transport.tls.buildSessionKey(
        &session_key_buffer,
        pending.config.pool_security_cell_id,
        pending.config.pool_policy_id,
        pending.serverName(),
        pending.port,
    );
    const wire = Wire.createTls(owner.allocator, stream, .{
        .server_name = pending.serverName(),
        .insecure_tls = pending.config.insecure_tls,
        .session_key = session_key,
        .offer_h2 = pending.offer_h2,
    }, pending.config.wire_buffer_bytes) catch |err| {
        fail(owner, pending, err);
        return;
    };
    pending.phase = .{ .handshaking = .{ .wire = wire, .interest = .write } };
    pending.phase_deadline_mono_ns = phaseDeadline(pending);
    stepHandshake(owner, pending);
}

/// Steps the handshake once: on the dial's start, and on each completion of
/// its wire.
pub fn stepHandshake(owner: *Owner, pending: *Dial) void {
    const handshaking = &pending.phase.handshaking;
    const step = handshaking.wire.handshakeStep() catch |err| {
        fail(owner, pending, err);
        return;
    };
    switch (step) {
        .done => finishHandshake(owner, pending),
        .wait => |interest| handshaking.interest = interest,
    }
}

fn finishHandshake(owner: *Owner, pending: *Dial) void {
    const wire = pending.phase.handshaking.wire;
    pending.phase = .starting;
    complete(owner, pending, wire);
}

/// The dial's wire is ready. h2 makes it a pool entry that every waiting
/// hop opens a stream on; http/1.1 gives it to the first waiter, and the
/// other hops go to HTTP/1, where each leases or dials its own connection.
fn complete(owner: *Owner, done: *Dial, wire: *Wire) void {
    // A shared dial offered h2; an answer of http/1.1 sends the origin's
    // next fetches straight to HTTP/1.
    const learned_http1 = done.offer_h2 and wire.protocol != .h2;
    if (learned_http1) {
        if (done.origin) |origin|
            origin.http1_only = true;
    }
    detach(owner, done);
    const waiters = done.waiters;
    done.waiters = .empty;
    const key = done.key;
    const config = done.config;
    destroyDial(owner, done);
    if (learned_http1)
        evictHttp1Memory(owner);
    var remaining = waiters;
    defer remaining.deinit(owner.allocator);

    if (wire.protocol == .h2) {
        // An HTTP/1 fetch's dial offers http/1.1 alone, and a handshake whose
        // server picks a protocol it was not offered fails
        // (`tls.zig:BioConnection.handshakeStep`, `TlsAlpnNotOffered`), so
        // only shared dials, whose waiters are all hops, end with an h2 wire.
        if (h2.addEntry(owner, &key, wire, config)) {
            for (remaining.items) |waiter| switch (waiter) {
                .hop => |joined| h2.start(owner, joined.hop),
                .h1 => unreachable,
            };
        } else |err| {
            for (remaining.items) |waiter| switch (waiter) {
                .hop => |joined| h2.startAfterPoolFailure(owner, joined.hop, err),
                .h1 => unreachable,
            };
        }
        return;
    }

    var offered: ?*Wire = wire;
    for (remaining.items) |waiter| switch (waiter) {
        .hop => |joined| {
            h1.start(owner, joined.hop, offered);
            offered = null;
        },
        .h1 => |fetch| {
            std.debug.assert(offered != null);
            h1.adoptDialedWire(owner, fetch, offered.?);
            offered = null;
        },
    };
    // Every waiter left before the wire was ready.
    if (offered) |unused|
        owner.releaseWire(unused);
}

/// Fails the dial: its waiters fail with `err`, or retry when it timed out
/// before their own budget ran out.
fn fail(owner: *Owner, failed_dial: *Dial, err: anyerror) void {
    releasePhase(owner, failed_dial);
    detach(owner, failed_dial);
    const now_ns = monotonicNowNs() catch std.math.maxInt(u64);
    const timed_out = err == error.FetchConnectTimeout or err == error.TlsHandshakeTimeout or err == error.DnsLookupTimeout;
    for (failed_dial.waiters.items) |waiter| switch (waiter) {
        .hop => |joined| {
            var hop = joined.hop;
            // A hop's dial budget runs from its own join: one that joined
            // late, with budget and request deadline left, gets a fresh
            // attempt instead of the leader's timeout, since nothing reached
            // the wire for it.
            const budget_end = joined.joined_mono_ns +| @as(u64, hop.config().socket_timeout_ms) * std.time.ns_per_ms;
            if (timed_out and now_ns < budget_end and !hop.config().requestDeadlineExpiredAt(now_ns) and h2.retryEligible(&hop))
                h2.queueRetry(owner, hop)
            else
                owner.failHop(&hop, err);
        },
        .h1 => |fetch| h1.dialFailed(owner, fetch, err),
    };
    failed_dial.waiters.clearRetainingCapacity();
    destroyDial(owner, failed_dial);
}

/// The dial's watch deadline passed: its phase timed out, a waiter's
/// request deadline passed, or the next Happy Eyeballs attempt is due.
pub fn deadlineReached(owner: *Owner, pending: *Dial) void {
    const now_ns = monotonicNowNs() catch std.math.maxInt(u64);
    if (now_ns >= pending.phase_deadline_mono_ns) {
        if (pending.phase == .connecting)
            owner.engine.dns_cache.invalidate(pending.serverName(), pending.port);
        fail(owner, pending, pending.phaseTimeoutError());
        return;
    }
    var index: usize = 0;
    while (index < pending.waiters.items.len) {
        const waiter = pending.waiters.items[index];
        const config = switch (waiter) {
            .hop => |*joined| joined.hop.config(),
            .h1 => |fetch| fetch.hop.config(),
        };
        if (!config.requestDeadlineExpiredAt(now_ns)) {
            index += 1;
            continue;
        }
        _ = pending.waiters.orderedRemove(index);
        switch (waiter) {
            .hop => |joined| {
                var hop = joined.hop;
                owner.failHop(&hop, error.FetchRequestDeadlineExceeded);
            },
            .h1 => |fetch| h1.dialFailed(owner, fetch, error.FetchRequestDeadlineExceeded),
        }
    }
    if (pending.waiters.items.len == 0) {
        abandon(owner, pending);
        return;
    }
    switch (pending.phase) {
        .connecting => launchAttempts(owner, pending, now_ns),
        .starting, .resolving, .handshaking => {},
    }
}

/// The handshake wire's watch reported a socket failure.
pub fn failed(owner: *Owner, pending: *Dial, err: anyerror) void {
    fail(owner, pending, err);
}

/// Applies a cancel message to a hop waiting on a shared dial. Returns false
/// when no dial holds `task`'s hop.
pub fn cancelTask(owner: *Owner, task: *Task) bool {
    for (owner.dials.items) |pending| {
        for (pending.waiters.items, 0..) |waiter, index| {
            switch (waiter) {
                .hop => |joined| if (joined.hop.task() == task) {
                    _ = pending.waiters.orderedRemove(index);
                    var hop = joined.hop;
                    owner.cancelHop(&hop);
                    if (pending.waiters.items.len == 0)
                        abandon(owner, pending);
                    return true;
                },
                .h1 => {},
            }
        }
    }
    return false;
}

/// `fetch` no longer waits on `pending` (canceled or expired); a dial nobody
/// waits on is abandoned.
pub fn leave(owner: *Owner, pending: *Dial, fetch: *h1.Fetch) void {
    for (pending.waiters.items, 0..) |waiter, index| {
        switch (waiter) {
            .h1 => |candidate| if (candidate == fetch) {
                _ = pending.waiters.orderedRemove(index);
                break;
            },
            .hop => {},
        }
    }
    if (pending.waiters.items.len == 0)
        abandon(owner, pending);
}

/// Ends a dial nobody waits on: its sockets close and its ticket goes.
fn abandon(owner: *Owner, pending: *Dial) void {
    std.debug.assert(pending.waiters.items.len == 0);
    releasePhase(owner, pending);
    detach(owner, pending);
    destroyDial(owner, pending);
}

/// Fails every dial's waiting hops with `err` and abandons the dials. The
/// HTTP/1 fetches already left (`h1.settleAll` runs first).
pub fn settleAll(owner: *Owner, err: anyerror) void {
    while (owner.dials.items.len != 0) {
        const pending = owner.dials.items[0];
        while (pending.waiters.pop()) |waiter| switch (waiter) {
            .hop => |joined| {
                var hop = joined.hop;
                owner.failHop(&hop, err);
            },
            .h1 => |fetch| h1.dialFailed(owner, fetch, err),
        };
        abandon(owner, pending);
    }
    for (owner.origins.items) |origin|
        owner.allocator.destroy(origin);
    owner.origins.clearRetainingCapacity();
}

pub fn appendWatches(owner: *Owner, pending: *Dial) void {
    const deadline = pending.watchDeadline();
    switch (pending.phase) {
        .starting => {},
        .resolving => owner.appendWatch(.{ .dial = pending }, .{
            .context = undefined,
            .deadline_mono_ns = deadline,
        }),
        .connecting => |*connecting| {
            for (connecting.attempts, 0..) |fd, slot| {
                if (fd < 0)
                    continue;
                owner.appendWatch(.{ .attempt = .{ .dial = pending, .slot = slot } }, .{
                    .context = undefined,
                    .io = .{ .connecting = fd },
                    .deadline_mono_ns = deadline,
                });
            }
        },
        .handshaking => |handshaking| owner.appendWatch(.{ .dial = pending }, .{
            .context = undefined,
            .io = .{ .wire = handshaking.wire },
            .deadline_mono_ns = deadline,
            .want_read = handshaking.interest == .read,
            .want_write = handshaking.interest == .write,
        }),
    }
}

fn phaseDeadline(pending: *const Dial) u64 {
    const now_ns = monotonicNowNs() catch return 0;
    return now_ns +| @as(u64, pending.config.socket_timeout_ms) * std.time.ns_per_ms;
}

/// Releases what the dial's phase holds: the DNS ticket, the attempts'
/// sockets (each watch ended in the data driver before its close) or the
/// handshake wire.
fn releasePhase(owner: *Owner, pending: *Dial) void {
    switch (pending.phase) {
        .starting => {},
        .resolving => |ticket| owner.engine.dns_cache.forget(ticket),
        .connecting => |*connecting| {
            for (&connecting.attempts) |*fd| {
                if (fd.* < 0)
                    continue;
                owner.driver.cancelConnecting(fd.*);
                std.posix.close(fd.*);
                fd.* = -1;
            }
            owner.allocator.free(connecting.addresses);
        },
        .handshaking => |handshaking| owner.releaseWire(handshaking.wire),
    }
    pending.phase = .starting;
}

/// Takes the dial out of the owner's list and off its origin record, and
/// records what its handshake taught about the origin.
fn detach(owner: *Owner, pending: *Dial) void {
    for (owner.dials.items, 0..) |candidate, index| {
        if (candidate == pending) {
            _ = owner.dials.orderedRemove(index);
            break;
        }
    }
    owner.watch_dirty = true;
    const origin = pending.origin orelse return;
    pending.origin = null;
    std.debug.assert(origin.shared_dial == pending);
    origin.shared_dial = null;
    releaseOrigin(owner, origin);
}

fn destroyDial(owner: *Owner, pending: *Dial) void {
    std.debug.assert(pending.phase == .starting);
    for (owner.dials.items, 0..) |candidate, index| {
        if (candidate == pending) {
            _ = owner.dials.orderedRemove(index);
            break;
        }
    }
    if (pending.origin) |origin| {
        origin.shared_dial = null;
        releaseOrigin(owner, origin);
    }
    pending.waiters.deinit(owner.allocator);
    owner.allocator.destroy(pending);
}

fn findOrigin(owner: *Owner, key: *const OriginKey) ?*Origin {
    for (owner.origins.items) |origin| {
        if (origin.key.eql(key))
            return origin;
    }
    return null;
}

fn findOrCreateOrigin(owner: *Owner, key: *const OriginKey) !*Origin {
    if (findOrigin(owner, key)) |origin| {
        origin.last_used = nextOriginUse(owner);
        return origin;
    }
    try owner.origins.ensureUnusedCapacity(owner.allocator, 1);
    const origin = try owner.allocator.create(Origin);
    origin.* = .{ .key = key.*, .last_used = nextOriginUse(owner) };
    owner.origins.appendAssumeCapacity(origin);
    return origin;
}

/// Drops a record that holds no dial and remembers nothing.
fn releaseOrigin(owner: *Owner, origin: *Origin) void {
    if (origin.shared_dial != null or origin.http1_only)
        return;
    for (owner.origins.items, 0..) |candidate, index| {
        if (candidate == origin) {
            _ = owner.origins.orderedRemove(index);
            break;
        }
    }
    owner.allocator.destroy(origin);
}

/// Keeps at most `http1_memory_records_max` records that only remember an
/// http/1.1 origin, dropping the least recently used.
fn evictHttp1Memory(owner: *Owner) void {
    while (true) {
        var memory_count: usize = 0;
        var oldest: ?usize = null;
        for (owner.origins.items, 0..) |origin, index| {
            if (origin.shared_dial != null)
                continue;
            memory_count += 1;
            if (oldest == null or origin.last_used < owner.origins.items[oldest.?].last_used)
                oldest = index;
        }
        if (memory_count <= http1_memory_records_max)
            return;
        const removed = owner.origins.orderedRemove(oldest.?);
        owner.allocator.destroy(removed);
    }
}

fn nextOriginUse(owner: *Owner) u64 {
    owner.origin_use_counter +%= 1;
    return owner.origin_use_counter;
}

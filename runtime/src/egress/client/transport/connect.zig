//! Outbound TCP connect with Happy Eyeballs racing, and the HTTP/1.1 TLS
//! connection built on it.
//!
//! Candidates alternate IPv6 and IPv4, starting with IPv6. While attempts are
//! pending a new one starts every `happy_eyeballs_delay_ns`, up to
//! `max_parallel_connect_attempts` at once; when none is pending the next
//! starts at once. The first socket to connect wins and the rest are closed.
//! Every connect wait is bounded by the socket timeout and the request
//! deadline, and the probe path also stops on cancellation.
//! `connectWithTimeout` leaves the socket blocking with the socket timeout on
//! each read and write, so its TLS handshake is bounded per syscall and not
//! by the request deadline; the probe path leaves the socket nonblocking and
//! steps the TLS handshake through the probe's waits.

const std = @import("std");
const common_socket = @import("collo_os").socket;

const cancel_probe_mod = @import("cancel_probe.zig");
const config_mod = @import("config.zig");
const connection_mod = @import("connection.zig");
const policy_mod = @import("request/policy.zig");
const readiness = @import("collo_egress_readiness");
const egress_tls = @import("collo_egress_tls");

const CancelProbe = cancel_probe_mod.CancelProbe;
const Config = config_mod.Config;
const HttpConnection = connection_mod.HttpConnection;
const HttpPlainConnection = connection_mod.HttpPlainConnection;
const ResolvedTarget = policy_mod.ResolvedTarget;

const max_parallel_connect_attempts: usize = 4;
// RFC 8305's recommended delay between connection attempts.
const happy_eyeballs_delay_ns: u64 = 250 * std.time.ns_per_ms;

pub fn connectWithTimeout(
    allocator: std.mem.Allocator,
    target: ResolvedTarget,
    config: Config,
) !HttpConnection {
    const deadline_mono_ns = config.capDeadlineMonoNs(try readiness.deadlineAfterMs(config.socket_timeout_ms));
    const stream = try connectStreamWithTimeout(
        target.connect_addresses,
        deadline_mono_ns,
        config.request_deadline_mono_ns,
    );
    common_socket.setReadWriteTimeouts(stream.handle, config.socket_timeout_ms) catch {
        stream.close();
        return error.FetchSocketTimeoutConfigFailed;
    };

    return switch (target.protocol) {
        .plain => .{ .plain = try HttpPlainConnection.create(allocator, stream) },
        .tls => .{ .fd_tls = try createTlsConnection(
            allocator,
            target,
            stream,
            config,
        ) },
    };
}

pub fn connectWithProbe(
    allocator: std.mem.Allocator,
    target: ResolvedTarget,
    config: Config,
    cancel_probe: CancelProbe,
) !HttpConnection {
    if (!cancel_probe.isEnabled())
        return connectWithTimeout(allocator, target, config);

    const driver = cancel_probe.driver orelse return connectWithTimeout(allocator, target, config);
    const deadline_mono_ns = config.capDeadlineMonoNs(try readiness.deadlineAfterMs(config.socket_timeout_ms));
    var stream = try connectStreamWithReadiness(
        target.connect_addresses,
        deadline_mono_ns,
        driver,
        cancel_probe.wake_fd,
        cancel_probe,
    );
    var stream_owned = true;
    errdefer if (stream_owned)
        stream.close();

    return switch (target.protocol) {
        .plain => blk: {
            stream_owned = false;
            const plain = try HttpPlainConnection.create(allocator, stream);
            break :blk .{ .plain = plain };
        },
        .tls => .{ .fd_tls = try createTlsConnectionWithProbe(
            allocator,
            target,
            stream,
            &stream_owned,
            config,
            cancel_probe,
        ) },
    };
}

fn createTlsConnection(
    allocator: std.mem.Allocator,
    target: ResolvedTarget,
    stream: std.net.Stream,
    config: Config,
) !*egress_tls.Connection {
    var session_key_buffer: [egress_tls.max_session_key_bytes]u8 = undefined;
    return egress_tls.Connection.create(
        allocator,
        stream,
        target.tls_server_name,
        config.insecure_tls,
        .http_1_1,
        egress_tls.buildSessionKey(
            &session_key_buffer,
            config.pool_security_cell_id,
            config.pool_policy_id,
            .http_1_1,
            target.tls_server_name,
            target.port,
        ),
    );
}

fn createTlsConnectionWithProbe(
    allocator: std.mem.Allocator,
    target: ResolvedTarget,
    stream: std.net.Stream,
    stream_owned: *bool,
    config: Config,
    cancel_probe: CancelProbe,
) !*egress_tls.Connection {
    stream_owned.* = false;
    var session_key_buffer: [egress_tls.max_session_key_bytes]u8 = undefined;
    var tls = try egress_tls.Connection.createUnhandshaken(
        allocator,
        stream,
        target.tls_server_name,
        config.insecure_tls,
        .http_1_1,
        egress_tls.buildSessionKey(
            &session_key_buffer,
            config.pool_security_cell_id,
            config.pool_policy_id,
            .http_1_1,
            target.tls_server_name,
            target.port,
        ),
    );
    errdefer tls.deinit();

    while (true) {
        if (cancel_probe.isCanceled())
            return error.FetchAborted;
        switch (try tls.handshakeStep()) {
            .done => break,
            .wait => |interest| try cancel_probe.waitFd(
                tls.stream.handle,
                interest,
                config.socket_timeout_ms,
                error.TlsHandshakeTimeout,
            ),
        }
    }
    return tls;
}

fn connectStreamWithTimeout(
    addresses: []const std.net.Address,
    deadline_mono_ns: u64,
    request_deadline_mono_ns: u64,
) !std.net.Stream {
    if (addresses.len == 0)
        return error.HostLacksNetworkAddresses;

    var attempts: [max_parallel_connect_attempts]ConnectAttempt = undefined;
    for (&attempts) |*attempt|
        attempt.* = .{};
    var active_count: usize = 0;
    var cursor = ConnectCandidateCursor.init(addresses);
    var last_error: anyerror = error.HostLacksNetworkAddresses;
    var next_launch_ns = readiness.monotonicNowNs() catch 0;
    defer closeConnectAttempts(&attempts);

    while (active_count != 0 or cursor.hasMore()) {
        if (connectDeadlineError(deadline_mono_ns, request_deadline_mono_ns)) |err|
            return err;
        if (active_count == 0 or shouldLaunchNextConnectAttempt(next_launch_ns, active_count, cursor.hasMore())) {
            while (active_count < max_parallel_connect_attempts and cursor.hasMore()) {
                if (connectDeadlineError(deadline_mono_ns, request_deadline_mono_ns)) |err|
                    return err;
                if (try launchNextTimeoutConnectAttempt(&cursor, &attempts, &active_count, &last_error)) |stream| {
                    const connected = stream;
                    try connection_mod.setFdNonblocking(connected.handle, false);
                    return connected;
                }
                next_launch_ns = (readiness.monotonicNowNs() catch 0) +| happy_eyeballs_delay_ns;
                if (active_count != 0)
                    break;
            }
            if (active_count == 0)
                continue;
        }

        var pollfds: [max_parallel_connect_attempts]std.posix.pollfd = undefined;
        var contexts: [max_parallel_connect_attempts]*ConnectAttempt = undefined;
        var poll_count: usize = 0;
        for (&attempts) |*attempt| {
            if (!attempt.active)
                continue;
            pollfds[poll_count] = .{
                .fd = attempt.fd,
                .events = std.posix.POLL.OUT | std.posix.POLL.HUP | std.posix.POLL.ERR,
                .revents = 0,
            };
            contexts[poll_count] = attempt;
            poll_count += 1;
        }

        const deadline_timeout = connectPollTimeoutMs(deadline_mono_ns);
        if (deadline_timeout == 0) {
            if (requestDeadlineExpiredAt(request_deadline_mono_ns, readiness.monotonicNowNs() catch deadline_mono_ns))
                return error.FetchRequestDeadlineExceeded;
            return error.FetchConnectTimeout;
        }
        var timeout = deadline_timeout;
        if (cursor.hasMore() and active_count < max_parallel_connect_attempts)
            timeout = @min(timeout, connectPollTimeoutMs(next_launch_ns));
        if (timeout == 0)
            continue;
        const ready = try std.posix.poll(pollfds[0..poll_count], timeout);
        if (ready == 0)
            continue;

        for (pollfds[0..poll_count], contexts[0..poll_count]) |pollfd, attempt| {
            if ((pollfd.revents & (std.posix.POLL.OUT | std.posix.POLL.HUP | std.posix.POLL.ERR)) == 0)
                continue;
            std.posix.getsockoptError(attempt.fd) catch |err| {
                last_error = err;
                attempt.close();
                active_count -= 1;
                continue;
            };
            const fd = attempt.takeFd();
            active_count -= 1;
            try connection_mod.setFdNonblocking(fd, false);
            return .{ .handle = fd };
        }
    }

    return last_error;
}

pub fn connectStreamWithReadiness(
    addresses: []const std.net.Address,
    deadline_mono_ns: u64,
    driver: *readiness.Driver,
    wake_fd: ?std.posix.fd_t,
    cancel_probe: CancelProbe,
) !std.net.Stream {
    if (addresses.len == 0)
        return error.HostLacksNetworkAddresses;

    var attempts: [max_parallel_connect_attempts]ConnectAttempt = undefined;
    for (&attempts) |*attempt|
        attempt.* = .{};
    var active_count: usize = 0;
    var cursor = ConnectCandidateCursor.init(addresses);
    var last_error: anyerror = error.HostLacksNetworkAddresses;
    var next_launch_ns = readiness.monotonicNowNs() catch 0;
    defer closeConnectAttempts(&attempts);

    while (active_count != 0 or cursor.hasMore()) {
        if (cancel_probe.isCanceled())
            return error.FetchAborted;
        if (connectDeadlineError(deadline_mono_ns, cancel_probe.request_deadline_mono_ns)) |err|
            return err;
        if (active_count == 0 or shouldLaunchNextConnectAttempt(next_launch_ns, active_count, cursor.hasMore())) {
            while (active_count < max_parallel_connect_attempts and cursor.hasMore()) {
                if (cancel_probe.isCanceled())
                    return error.FetchAborted;
                if (connectDeadlineError(deadline_mono_ns, cancel_probe.request_deadline_mono_ns)) |err|
                    return err;
                if (try launchNextReadinessConnectAttempt(&cursor, &attempts, &active_count, &last_error)) |stream|
                    return stream;
                next_launch_ns = (readiness.monotonicNowNs() catch 0) +| happy_eyeballs_delay_ns;
                if (active_count != 0)
                    break;
            }
            if (active_count == 0)
                continue;
        }

        var sources: [max_parallel_connect_attempts]readiness.Source = undefined;
        var source_count: usize = 0;
        const wait_deadline = if (cursor.hasMore() and active_count < max_parallel_connect_attempts)
            @min(deadline_mono_ns, next_launch_ns)
        else
            deadline_mono_ns;
        for (&attempts) |*attempt| {
            if (!attempt.active)
                continue;
            sources[source_count] = .{
                .context = attempt,
                .handle = .{ .fd = attempt.fd },
                .deadline_mono_ns = wait_deadline,
                .want_read = false,
                .want_write = true,
            };
            source_count += 1;
        }

        switch (try driver.wait(sources[0..source_count], wake_fd)) {
            .ready => |ready| {
                const attempt: *ConnectAttempt = @ptrCast(@alignCast(ready.context));
                std.posix.getsockoptError(attempt.fd) catch |err| {
                    last_error = err;
                    attempt.close();
                    active_count -= 1;
                    continue;
                };
                active_count -= 1;
                return .{ .handle = attempt.takeFd() };
            },
            .expired => {
                const now_ns = readiness.monotonicNowNs() catch deadline_mono_ns;
                if (cancel_probe.requestDeadlineExpiredAt(now_ns))
                    return error.FetchRequestDeadlineExceeded;
                if (now_ns >= deadline_mono_ns)
                    return error.FetchConnectTimeout;
                continue;
            },
            .wake => {
                if (cancel_probe.isCanceled())
                    return error.FetchAborted;
                if (connectDeadlineError(deadline_mono_ns, cancel_probe.request_deadline_mono_ns)) |err|
                    return err;
                if (wake_fd) |fd|
                    cancel_probe_mod.drainEventFd(fd);
                continue;
            },
        }
    }

    return last_error;
}

const ConnectAttempt = struct {
    fd: std.posix.fd_t = -1,
    active: bool = false,

    fn takeFd(self: *ConnectAttempt) std.posix.fd_t {
        const fd = self.fd;
        self.fd = -1;
        self.active = false;
        return fd;
    }

    fn close(self: *ConnectAttempt) void {
        if (self.fd >= 0)
            std.posix.close(self.fd);
        self.fd = -1;
        self.active = false;
    }
};

const ConnectFamily = enum { ipv6, ipv4, other };

const ConnectCandidateCursor = struct {
    addresses: []const std.net.Address,
    next_ipv6: usize = 0,
    next_ipv4: usize = 0,
    next_other: usize = 0,
    prefer_ipv6: bool = true,
    remaining: usize,

    fn init(addresses: []const std.net.Address) ConnectCandidateCursor {
        return .{
            .addresses = addresses,
            .remaining = addresses.len,
        };
    }

    fn hasMore(self: *const ConnectCandidateCursor) bool {
        return self.remaining != 0;
    }

    fn next(self: *ConnectCandidateCursor) ?std.net.Address {
        if (self.remaining == 0)
            return null;

        const preferred: ConnectFamily = if (self.prefer_ipv6) .ipv6 else .ipv4;
        const fallback: ConnectFamily = if (self.prefer_ipv6) .ipv4 else .ipv6;
        if (self.takeFamily(preferred)) |address| {
            self.prefer_ipv6 = !self.prefer_ipv6;
            self.remaining -= 1;
            return address;
        }
        if (self.takeFamily(fallback)) |address| {
            self.prefer_ipv6 = !self.prefer_ipv6;
            self.remaining -= 1;
            return address;
        }
        if (self.takeFamily(.other)) |address| {
            self.remaining -= 1;
            return address;
        }
        self.remaining = 0;
        return null;
    }

    fn takeFamily(self: *ConnectCandidateCursor, family: ConnectFamily) ?std.net.Address {
        const index_ptr = switch (family) {
            .ipv6 => &self.next_ipv6,
            .ipv4 => &self.next_ipv4,
            .other => &self.next_other,
        };
        while (index_ptr.* < self.addresses.len) {
            const index = index_ptr.*;
            index_ptr.* += 1;
            if (connectFamily(self.addresses[index]) == family)
                return self.addresses[index];
        }
        return null;
    }
};

fn connectFamily(address: std.net.Address) ConnectFamily {
    return switch (address.any.family) {
        std.posix.AF.INET6 => .ipv6,
        std.posix.AF.INET => .ipv4,
        else => .other,
    };
}

fn shouldLaunchNextConnectAttempt(next_launch_ns: u64, active_count: usize, has_more: bool) bool {
    if (!has_more or active_count >= max_parallel_connect_attempts)
        return false;
    const now_ns = readiness.monotonicNowNs() catch return true;
    return now_ns >= next_launch_ns;
}

fn freeConnectAttemptSlot(attempts: *[max_parallel_connect_attempts]ConnectAttempt) ?usize {
    for (attempts, 0..) |*attempt, index| {
        if (!attempt.active and attempt.fd < 0)
            return index;
    }
    return null;
}

fn launchNextTimeoutConnectAttempt(
    cursor: *ConnectCandidateCursor,
    attempts: *[max_parallel_connect_attempts]ConnectAttempt,
    active_count: *usize,
    last_error: *anyerror,
) !?std.net.Stream {
    const slot = freeConnectAttemptSlot(attempts) orelse return null;
    const address = cursor.next() orelse return null;
    const started = startConnectAttempt(address) catch |err| {
        last_error.* = err;
        return null;
    };
    attempts[slot] = started.attempt;
    switch (started.state) {
        .connected => {
            const fd = attempts[slot].takeFd();
            try connection_mod.setFdNonblocking(fd, false);
            return .{ .handle = fd };
        },
        .pending => {
            active_count.* += 1;
            return null;
        },
    }
}

fn launchNextReadinessConnectAttempt(
    cursor: *ConnectCandidateCursor,
    attempts: *[max_parallel_connect_attempts]ConnectAttempt,
    active_count: *usize,
    last_error: *anyerror,
) !?std.net.Stream {
    const slot = freeConnectAttemptSlot(attempts) orelse return null;
    const address = cursor.next() orelse return null;
    const started = startConnectAttempt(address) catch |err| {
        last_error.* = err;
        return null;
    };
    attempts[slot] = started.attempt;
    switch (started.state) {
        .connected => return .{ .handle = attempts[slot].takeFd() },
        .pending => {
            active_count.* += 1;
            return null;
        },
    }
}

const ConnectStarted = struct {
    attempt: ConnectAttempt,
    state: enum { connected, pending },
};

fn startConnectAttempt(address: std.net.Address) !ConnectStarted {
    const fd = try std.posix.socket(
        address.any.family,
        std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK,
        std.posix.IPPROTO.TCP,
    );
    errdefer std.posix.close(fd);

    try common_socket.setTcpNoDelay(fd);

    std.posix.connect(fd, &address.any, address.getOsSockLen()) catch |err| switch (err) {
        error.WouldBlock, error.ConnectionPending => return .{
            .attempt = .{ .fd = fd, .active = true },
            .state = .pending,
        },
        else => return err,
    };

    return .{
        .attempt = .{ .fd = fd, .active = false },
        .state = .connected,
    };
}

fn closeConnectAttempts(attempts: []ConnectAttempt) void {
    for (attempts) |*attempt|
        attempt.close();
}

fn connectPollTimeoutMs(deadline_mono_ns: u64) i32 {
    const now_ns = readiness.monotonicNowNs() catch return 1;
    if (now_ns >= deadline_mono_ns)
        return 0;
    const remaining_ns = deadline_mono_ns - now_ns;
    const remaining_ms = (remaining_ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms;
    return @intCast(@min(remaining_ms, @as(u64, std.math.maxInt(i32))));
}

fn requestDeadlineExpiredAt(request_deadline_mono_ns: u64, now_mono_ns: u64) bool {
    return request_deadline_mono_ns != 0 and now_mono_ns >= request_deadline_mono_ns;
}

fn connectDeadlineError(deadline_mono_ns: u64, request_deadline_mono_ns: u64) ?anyerror {
    const now_ns = readiness.monotonicNowNs() catch deadline_mono_ns;
    if (requestDeadlineExpiredAt(request_deadline_mono_ns, now_ns))
        return error.FetchRequestDeadlineExceeded;
    if (now_ns >= deadline_mono_ns)
        return error.FetchConnectTimeout;
    return null;
}

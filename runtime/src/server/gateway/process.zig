//! Spawning and stopping the egress gateway process, on the thread that holds the manager's
//! `serial` (`manager.zig` says which); `GatewayProcess.kill` alone may run on any thread.
//!
//! The gateway is this binary, or `SpawnConfig.executable_path` when set, run as
//! `launch.process_name` with no arguments and the one descriptor of its launch contract
//! (`egress/gateway/launch.zig`). It builds its root itself (`egress/gateway/sandbox.zig`), so the
//! server creates nothing on the host's filesystem for it. Its environment holds only the libc
//! variables in `inherited_environment`; nothing configures the gateway through the environment or
//! its arguments. What it enforces arrives in the hello, which `spawn` sends right after the ready
//! report, so the hello is the first packet the server sends on the control socket
//! (`control.HelloHeader`).

const std = @import("std");
const fd_mod = @import("collo_os").fd;
const process = @import("collo_os").process;
const process_limits = @import("collo_limits").process;
const ipc = @import("collo_ipc");
const control = @import("collo_egress_gateway").control;
const launch = @import("collo_egress_gateway").launch;
const policy = @import("collo_egress_gateway").policy;

const egress_token = ipc.egress_token;
const process_name = launch.process_name;
const inherited_control_fd = launch.inherited_control_fd;

/// libc settings copied from the server's environment when set: the resolver's options and search
/// domains, and the timezone. Anything else, `SSL_CERT_FILE` and its kin included, stays out, so
/// the trust store bound into the gateway's root is the one it loads.
pub const inherited_environment = [_][]const u8{ "RES_OPTIONS", "LOCALDOMAIN", "TZ" };

// The control wire needs message boundaries and carries descriptors through SCM_RIGHTS.
const ipc_socket_type: u32 = std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK;
/// Budget for the gateway's exec, sandbox, shard threads, io_uring and seccomp before it reports
/// ready. The gateway initializes no JSC, so this is tighter than the zygote's bound
/// (`ZYGOTE_READY_TIMEOUT_MS` in `zygote/host_client.zig`).
const GATEWAY_READY_TIMEOUT_MS: i32 = 2_000;
/// How long `deinitNoWait` waits to reap a gateway it sent SIGKILL. The exit follows the signal
/// closely, and the bound keeps the launcher, which destroys retired gateways, from stalling.
const REAP_NO_WAIT_MS: i32 = 200;

pub const SpawnConfig = struct {
    /// The binary to run as the gateway; null runs this one.
    executable_path: ?[]const u8 = null,
    /// The key the gateway verifies egress tokens with, drawn for this gateway alone; not the zero
    /// key.
    key: egress_token.Key,
    /// The network policies the gateway enforces, at least one; borrowed for the call.
    table: *const policy.PolicyTable,
};

/// A gateway that reported ready and took its hello. It owns the pidfd and the server's end of the
/// control socket.
pub const GatewayProcess = struct {
    pid: u32,
    pidfd: std.posix.fd_t,
    control_fd: std.posix.fd_t,

    /// Sends SIGKILL and returns without waiting for the exit, from any thread; `deinit` or
    /// `deinitNoWait` reaps it later. The workers attached to the gateway see their liveness
    /// descriptors hang up once it is gone.
    pub fn kill(self: *const GatewayProcess) void {
        process.pidFdSendSignal(self.pidfd, std.posix.SIG.KILL) catch |err| switch (err) {
            error.ProcessNotFound => {},
            else => std.log.warn("failed to SIGKILL egress gateway pid={d}: {s}", .{ self.pid, @errorName(err) }),
        };
    }

    /// Asks the gateway to shut down and closes the control socket, then waits up to
    /// `PROCESS_EXIT_WAIT_MS` for the exit before it sends SIGKILL, waits again and reaps.
    pub fn deinit(self: *GatewayProcess) void {
        control.sendShutdown(self.control_fd) catch |err|
            std.log.debug("egress gateway shutdown signal failed pid={d}: {s}", .{ self.pid, @errorName(err) });
        std.posix.close(self.control_fd);
        var exited = process.waitForPidFdExit(self.pidfd, process_limits.PROCESS_EXIT_WAIT_MS) catch process.pidFdHasExited(self.pidfd);
        if (!exited) {
            self.kill();
            exited = process.waitForPidFdExit(self.pidfd, process_limits.PROCESS_EXIT_WAIT_MS) catch process.pidFdHasExited(self.pidfd);
            if (!exited)
                std.log.warn("egress gateway pid={d} did not exit after SIGKILL", .{self.pid});
        }
        reapBestEffort(self.pid, self.pidfd, process_limits.PROCESS_EXIT_WAIT_MS);
        std.posix.close(self.pidfd);
        self.* = undefined;
    }

    /// Sends SIGKILL right after the shutdown request and reaps within `REAP_NO_WAIT_MS`, for a
    /// gateway the manager retired after its control channel failed.
    pub fn deinitNoWait(self: *GatewayProcess) void {
        control.sendShutdown(self.control_fd) catch |err|
            std.log.debug("egress gateway shutdown signal failed pid={d}: {s}", .{ self.pid, @errorName(err) });
        std.posix.close(self.control_fd);
        self.kill();
        reapBestEffort(self.pid, self.pidfd, REAP_NO_WAIT_MS);
        std.posix.close(self.pidfd);
        self.* = undefined;
    }
};

/// Spawns the gateway, waits until it reports ready and sends it the hello with `config.key` and
/// `config.table`. A gateway that exits first fails the spawn with `error.PeerClosed` when the
/// exit lands while the server waits on the control socket and with
/// `error.EgressGatewayExitedBeforeReady` otherwise; one that stays silent past
/// `GATEWAY_READY_TIMEOUT_MS` fails it with `error.EgressGatewayReadyTimeout`. A hello the socket
/// refuses fails it with the send's error. Every failure kills and reaps the gateway.
pub fn spawn(allocator: std.mem.Allocator, config: SpawnConfig) !GatewayProcess {
    std.debug.assert(!config.key.isZero());
    std.debug.assert(config.table.count >= 1);

    const exe_path = if (config.executable_path) |path|
        try allocator.dupe(u8, path)
    else
        try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);
    const exe_path_z = try allocator.dupeZ(u8, exe_path);
    defer allocator.free(exe_path_z);

    const raw_pair = try fd_mod.socketPairType(ipc_socket_type);
    var parent_control = fd_mod.OwnedFd.fromRaw(raw_pair[0]);
    errdefer parent_control.deinit();
    var child_control = fd_mod.OwnedFd.fromRaw(raw_pair[1]);
    defer child_control.deinit();

    var control_spawn_source: fd_mod.OwnedFd = .{};
    defer control_spawn_source.deinit();
    const fd_map = [_]process.SpawnFdMap{.{
        .source_fd = try spawnSourceFd(&control_spawn_source, child_control.fd()),
        .target_fd = inherited_control_fd,
    }};

    const argv = [_:null]?[*:0]const u8{process_name};
    var environment = [_:null]?[*:0]const u8{null} ** inherited_environment.len;
    inheritEnvironment(&environment);

    const pid = try process.spawnInternal(.{
        .exe_path_z = exe_path_z.ptr,
        .argv = &argv,
        .envp = &environment,
        .fd_map = &fd_map,
    });
    // The server keeps none of the child's descriptors: with every copy of the child's control end
    // closed, a gateway that dies before ready shows up as end of stream on the server's end.
    child_control.deinit();
    control_spawn_source.deinit();

    const gateway_pid: u32 = pid;
    var pidfd = fd_mod.OwnedFd.fromRaw(try process.openPidFd(gateway_pid));
    errdefer {
        process.pidFdSendSignal(pidfd.fd(), std.posix.SIG.KILL) catch |err|
            std.log.warn("failed to SIGKILL egress gateway after spawn failure pid={d}: {s}", .{ gateway_pid, @errorName(err) });
        _ = process.waitForPidFdExit(pidfd.fd(), process_limits.PROCESS_EXIT_WAIT_MS) catch false;
        reapBestEffort(gateway_pid, pidfd.fd(), REAP_NO_WAIT_MS);
        pidfd.deinit();
    }

    // The gateway inherited the server's oom_score_adj across the spawn; this gives it its own
    // score (`OOM_SCORE_ADJ_EGRESS_GATEWAY` in `common/limits/process.zig` says where that places
    // it and when the write fails). The order backs up the cgroup limits and is no boot condition,
    // so a failed write only warns.
    process.writeOomScoreAdj(gateway_pid, process_limits.OOM_SCORE_ADJ_EGRESS_GATEWAY) catch |err|
        std.log.warn("failed to set egress gateway oom_score_adj pid={d}: {s}", .{ gateway_pid, @errorName(err) });

    // A gateway that cannot finish its sandbox exits without a word on the control socket, and
    // waiting for ready turns that into a spawn failure instead of an attach timeout followed by
    // restarts. The gateway reports ready only after its seccomp filter is installed
    // (`Gateway.run` in `egress/gateway/runtime/root.zig`), so a gateway this returns is fully
    // sandboxed, and no attach spends its control deadline waiting on the gateway's boot.
    try recvGatewayReadyBeforeTimeout(parent_control.fd(), pidfd.fd());
    // The socket is new and the gateway has read nothing yet, so the hello finds the whole send
    // buffer free and a nonblocking send takes it at once.
    try control.sendHello(parent_control.fd(), &config.key, config.table);

    return .{
        .pid = gateway_pid,
        .pidfd = pidfd.release(),
        .control_fd = parent_control.release(),
    };
}

/// Fills `out` with the server's `inherited_environment` entries, each the first one of its name,
/// pointing into the server's environment block. `spawnInternal` copies them into the child.
fn inheritEnvironment(out: *[inherited_environment.len:null]?[*:0]const u8) void {
    var count: usize = 0;
    for (inherited_environment) |name| {
        for (std.os.environ) |entry| {
            const text = std.mem.span(entry);
            if (text.len > name.len and std.mem.startsWith(u8, text, name) and text[name.len] == '=') {
                out[count] = entry;
                count += 1;
                break;
            }
        }
    }
}

fn recvGatewayReadyBeforeTimeout(control_fd: std.posix.fd_t, pidfd: std.posix.fd_t) !void {
    const deadline_ns = process.monotonicNowNsOrZero() +|
        (@as(u64, @intCast(GATEWAY_READY_TIMEOUT_MS)) * std.time.ns_per_ms);
    while (true) {
        var buffer: [@sizeOf(control.Header)]u8 = undefined;
        const received = std.posix.recv(control_fd, &buffer, 0) catch |err| switch (err) {
            error.WouldBlock => {
                if (process.pidFdHasExited(pidfd))
                    return error.EgressGatewayExitedBeforeReady;
                try waitReadable(control_fd, deadline_ns);
                continue;
            },
            else => |other| return other,
        };
        if (received == 0)
            return error.EgressGatewayExitedBeforeReady;
        try control.decodeGatewayReady(buffer[0..received]);
        return;
    }
}

/// `spawnInternal` requires that no source fd equal a mapping's target, so a source that sits on
/// `inherited_control_fd` is duplicated above it into `temporary`.
fn spawnSourceFd(temporary: *fd_mod.OwnedFd, source_fd: std.posix.fd_t) !std.posix.fd_t {
    if (source_fd != inherited_control_fd)
        return source_fd;
    temporary.* = try fd_mod.OwnedFd.dupCloexecAtLeast(source_fd, inherited_control_fd + 1);
    return temporary.fd();
}

/// Waits until `fd` is readable, failing with `error.EgressGatewayReadyTimeout` at `deadline_ns`
/// and with `error.PeerClosed` when the gateway's end hangs up.
fn waitReadable(fd: std.posix.fd_t, deadline_ns: u64) !void {
    const now_ns = process.monotonicNowNsOrZero();
    if (now_ns >= deadline_ns)
        return error.EgressGatewayReadyTimeout;
    const remaining_ns = deadline_ns - now_ns;
    const remaining_ms = @max(@as(u64, 1), (remaining_ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms);
    var pollfds = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR,
        .revents = 0,
    }};
    const ready = try std.posix.poll(&pollfds, @intCast(@min(remaining_ms, @as(u64, @intCast(std.math.maxInt(i32))))));
    if (ready == 0)
        return error.EgressGatewayReadyTimeout;
    if ((pollfds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0)
        return error.PeerClosed;
}

fn reapBestEffort(pid: u32, pidfd: std.posix.fd_t, wait_ms: i32) void {
    // SIGKILL delivery is asynchronous: a single WNOHANG issued right after
    // the kill races the zombie transition and loses, and the server installs
    // no SIGCHLD reaper, so a missed reap here is permanent. Wait on the
    // pidfd for the exit, then collect.
    var status: c_int = 0;
    var pidfd_waited = false;
    while (true) {
        const rc = std.c.waitpid(@intCast(pid), &status, std.c.W.NOHANG);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                if (rc != 0)
                    return;
                if (pidfd_waited) {
                    std.log.warn("egress gateway pid={d} still not waitable after {d}ms; leaving unreaped", .{ pid, wait_ms });
                    return;
                }
                pidfd_waited = true;
                // When the pidfd wait fails, the next round logs that the
                // gateway stays unreaped, so the wait's own error goes to the
                // debug log.
                if (process.waitForPidFdExit(pidfd, wait_ms)) |_| {} else |err| std.log.debug(
                    "egress gateway pid={d} pidfd wait failed: {s}",
                    .{ pid, @errorName(err) },
                );
            },
            .CHILD => return,
            .INTR => continue,
            else => |err| {
                std.log.warn("failed to reap egress gateway pid={d}: {s}", .{ pid, @tagName(err) });
                return;
            },
        }
    }
}

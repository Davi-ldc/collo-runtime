//! The ingress listening sockets: one nonblocking, close-on-exec TCP listener
//! per lane, all bound to the same address and port.
//!
//! With more than one lane the sockets share the port through SO_REUSEPORT,
//! and a listen port of 0 is resolved by the first bind, whose kernel-chosen
//! port every later lane binds too. Each socket carries its lane's CPU as an
//! SO_INCOMING_CPU hint, and when every lane has a CPU the reuseport eBPF
//! selector (`reuseport_bpf.zig`) steers a connection to the lane on the CPU
//! that received it; without the selector the kernel's reuseport hash
//! spreads connections instead. The sockets listen from `init` on, so
//! connections that arrive before the lanes start wait in the backlog.

const std = @import("std");
const os_socket = @import("collo_os").socket;
const reuseport_bpf = @import("reuseport_bpf.zig");

pub const IngressListenConfig = struct {
    /// Port 0 asks the kernel for an ephemeral port.
    address: std.net.Address,
    lane_count: usize,
    /// Empty, or one CPU per lane.
    lane_cpu_ids: []const usize = &.{},
    backlog: u31 = 128,
    /// Tests set it to take the path of a target without SO_REUSEPORT.
    force_reuseport_unavailable: bool = false,
};

pub const IngressListeners = struct {
    allocator: std.mem.Allocator,
    /// The address every listener is bound to, with the actual port.
    bound_address: std.net.Address,
    backlog: u31,
    reuseport_available: bool,
    reuseport_bpf_attached: bool,
    listeners: []std.net.Server,

    /// Fails with `error.InvalidLaneCount` for zero lanes or a CPU list of
    /// another length, and with `error.ReusePortUnavailable` when several
    /// lanes need SO_REUSEPORT and the target or the kernel lacks it. A
    /// selector that fails to attach is only logged.
    pub fn init(allocator: std.mem.Allocator, config: IngressListenConfig) !IngressListeners {
        if (config.lane_count == 0)
            return error.InvalidLaneCount;
        if (config.lane_cpu_ids.len != 0 and config.lane_cpu_ids.len != config.lane_count)
            return error.InvalidLaneCount;

        const reuseport_available = config.lane_count > 1 and
            !config.force_reuseport_unavailable and
            reusePortSocketOptionKnown();
        if (config.lane_count > 1 and !reuseport_available)
            return error.ReusePortUnavailable;

        const listeners = try allocator.alloc(std.net.Server, config.lane_count);
        errdefer allocator.free(listeners);

        var bound_count: usize = 0;
        errdefer {
            for (listeners[0..bound_count]) |*server|
                server.deinit();
        }

        var bind_address = config.address;
        while (bound_count < listeners.len) : (bound_count += 1) {
            const incoming_cpu_id = if (config.lane_cpu_ids.len == 0)
                null
            else
                config.lane_cpu_ids[bound_count];
            listeners[bound_count] = try createOne(
                bind_address,
                config.backlog,
                reuseport_available,
                incoming_cpu_id,
            );
            if (bind_address.getPort() == 0)
                bind_address.setPort(listeners[bound_count].listen_address.getPort());
        }

        var reuseport_bpf_attached = false;
        if (reuseport_available and config.lane_cpu_ids.len != 0) {
            if (reuseport_bpf.attachCpuSelector(listeners, config.lane_cpu_ids)) {
                reuseport_bpf_attached = true;
            } else |err| {
                std.log.warn("reuseport eBPF locality selector unavailable: {s}", .{
                    @errorName(err),
                });
            }
        }

        return .{
            .allocator = allocator,
            .bound_address = listeners[0].listen_address,
            .backlog = config.backlog,
            .reuseport_available = reuseport_available,
            .reuseport_bpf_attached = reuseport_bpf_attached,
            .listeners = listeners,
        };
    }

    pub fn deinit(self: *IngressListeners) void {
        for (self.listeners) |*server|
            server.deinit();
        self.allocator.free(self.listeners);
        self.* = undefined;
    }

    pub fn laneCount(self: *const IngressListeners) usize {
        return self.listeners.len;
    }

    pub fn asSlice(self: *const IngressListeners) []const std.net.Server {
        return self.listeners;
    }

    pub fn address(self: *const IngressListeners) std.net.Address {
        return self.bound_address;
    }

    pub fn port(self: *const IngressListeners) u16 {
        return self.bound_address.getPort();
    }

    pub fn get(self: *IngressListeners, index: usize) ?*std.net.Server {
        if (index >= self.listeners.len)
            return null;
        return &self.listeners[index];
    }
};

fn createOne(
    address: std.net.Address,
    backlog: u31,
    enable_reuseport: bool,
    incoming_cpu_id: ?usize,
) !std.net.Server {
    const fd = try std.posix.socket(
        address.any.family,
        std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC,
        std.posix.IPPROTO.TCP,
    );
    var server = std.net.Server{
        .listen_address = undefined,
        .stream = .{ .handle = fd },
    };
    errdefer server.deinit();

    try os_socket.setReuseAddress(fd);
    if (enable_reuseport)
        os_socket.setReusePort(fd) catch return error.ReusePortUnavailable;
    if (incoming_cpu_id) |cpu_id|
        os_socket.setIncomingCpu(fd, cpu_id) catch |err|
            std.log.debug("SO_INCOMING_CPU hint unavailable cpu={d}: {s}", .{
                cpu_id,
                @errorName(err),
            });

    var socklen = address.getOsSockLen();
    try std.posix.bind(fd, &address.any, socklen);
    try std.posix.listen(fd, backlog);
    try std.posix.getsockname(fd, &server.listen_address.any, &socklen);
    return server;
}

/// A compile-time check that the target defines SO_REUSEPORT; whether the
/// kernel accepts it is decided by `setReusePort` in `createOne`.
fn reusePortSocketOptionKnown() bool {
    return @hasDecl(std.posix.SO, "REUSEPORT");
}

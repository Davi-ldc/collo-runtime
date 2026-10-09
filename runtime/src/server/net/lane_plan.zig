//! The ingress lane plan: how many lanes the server runs and the CPU each one
//! is pinned to, decided once at boot from the listen address.
//!
//! The lane count targets the receive queues of the interface that holds the
//! listen address, so each lane can sit on a CPU that takes one queue's
//! interrupts, and `reuseport_bpf.zig` steers each connection to the lane on
//! the CPU that received it. The interface comes from the address alone: a
//! loopback address is `lo`, a specific address is the interface the kernel
//! lists it under, and the unspecified address, or an address no interface
//! holds, maps to no single interface, in which case the schedulable CPUs are
//! the target. `lo` targets the CPUs too: it has one queue and no
//! interrupts, because the kernel receives a loopback packet on the CPU that
//! sent it, so a loopback connection arrives on whichever CPU its client runs
//! on. Two caps always apply: no more lanes than CPUs this process may
//! run on, because more hot lane threads than CPUs only add scheduling and
//! cache cost, and no more lanes than one `lane_memory_share_divisor`-th of
//! the available memory pays for at each lane's worst-case footprint
//! (`MemoryShape`). An explicit lane count replaces the target and keeps only
//! the CPU cap.
//!
//! Everything here runs on the boot thread before any lane exists, except
//! `pinCurrentThreadToCpu`, which each lane thread calls on itself.

const std = @import("std");
const fd_mod = @import("collo_os").fd;

const linux = std.os.linux;

/// The lanes together may claim at most 1/divisor of the memory the kernel
/// reports available at boot.
pub const lane_memory_share_divisor: usize = 50;
/// The available memory assumed when `/proc/meminfo` cannot be read.
pub const mem_available_fallback_bytes: usize = 512 * 1024 * 1024;
/// IPv4 addresses read from the kernel's interface list. An address past this
/// many is not found, and its listen address then targets the CPUs.
pub const ipv4_addresses_max: usize = 256;
/// Bytes read from `/proc/net/if_inet6`, about a thousand IPv6 addresses.
pub const if_inet6_bytes_max: usize = 64 * 1024;
/// Bytes read from the head of `/proc/meminfo`, which lists `MemAvailable`
/// on its third line.
const meminfo_head_bytes: usize = 4096;

pub const Error = error{
    InvalidLaneCount,
    NoRxQueues,
    NoAllowedCpus,
} || std.mem.Allocator.Error ||
    std.fs.File.OpenError ||
    std.fs.File.ReadError ||
    std.fs.Dir.OpenError ||
    std.posix.SocketError ||
    std.posix.UnexpectedError;

pub const Plan = struct {
    lane_count: usize,
    allowed_cpu_count: usize,
    allowed_cpu_ids: []usize,
    /// One CPU per lane, in listener order.
    lane_cpu_ids: []usize,
    /// The interface that holds the listen address, whose receive queues set
    /// the target unless it is `lo`, or null when the address maps to no
    /// single interface. Without queues to follow, the target is the
    /// schedulable CPU count.
    interface: ?Interface,
    mem_available_bytes: usize,

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        allocator.free(self.lane_cpu_ids);
        allocator.free(self.allowed_cpu_ids);
        self.* = undefined;
    }
};

pub const Interface = struct {
    name: InterfaceName,
    rx_queues: usize,
    tx_queues: usize,
};

/// A kernel network interface name: 1 to `IFNAMESIZE - 1` bytes, never a
/// path separator, so it is safe to join into a `/sys/class/net` path.
pub const InterfaceName = struct {
    bytes: [linux.IFNAMESIZE]u8 = undefined,
    len: u8 = 0,

    pub const loopback = InterfaceName.init("lo") catch unreachable;

    pub fn init(name: []const u8) error{InvalidInterfaceName}!InterfaceName {
        if (name.len == 0 or name.len >= linux.IFNAMESIZE)
            return error.InvalidInterfaceName;
        if (std.mem.indexOfAny(u8, name, "/\x00") != null)
            return error.InvalidInterfaceName;
        var result: InterfaceName = .{ .len = @intCast(name.len) };
        @memcpy(result.bytes[0..name.len], name);
        return result;
    }

    pub fn slice(self: *const InterfaceName) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// The element sizes and capacities of a lane's fixed tables, filled by
/// `laneMemoryShape` in `ingress/runner/root.zig`.
pub const MemoryShape = struct {
    connection_slot_bytes: usize,
    request_slot_bytes: usize,
    deadline_entry_bytes: usize,
    command_bytes: usize,
    active_request_bytes: usize,
    runner_connection_bytes: usize,
    max_connections: usize,
    max_requests: usize,
    command_capacity: usize,
    header_buffer_count: usize,
    header_buffer_bytes: usize,

    /// A lane's footprint with every table at capacity, the cost the memory
    /// cap charges per lane.
    pub fn estimatedHeavyLaneBytes(self: MemoryShape) usize {
        return self.connection_slot_bytes * self.max_connections +
            self.request_slot_bytes * self.max_requests +
            self.deadline_entry_bytes * self.max_requests +
            self.command_bytes * self.command_capacity +
            self.active_request_bytes * self.max_requests +
            self.runner_connection_bytes * self.max_connections +
            self.header_buffer_count * self.header_buffer_bytes;
    }
};

/// `explicit_lane_count` zero lets the plan choose. The caller owns the plan
/// and calls `deinit`. Fails with `error.NoAllowedCpus` when the process may
/// run on no CPU, and with `error.NoRxQueues` or a sysfs error when the
/// interface that holds `listen` lists no receive queue or cannot be read.
pub fn build(
    allocator: std.mem.Allocator,
    listen: std.net.Address,
    shape: MemoryShape,
    explicit_lane_count: usize,
) Error!Plan {
    const allowed_cpu_ids = try discoverAllowedCpus(allocator);
    errdefer allocator.free(allowed_cpu_ids);
    if (allowed_cpu_ids.len == 0)
        return error.NoAllowedCpus;
    const allowed_cpu_count = allowed_cpu_ids.len;

    var interface: ?Interface = null;
    if (try interfaceFor(allocator, listen)) |name|
        interface = try interfaceQueues(allocator, name);
    const queue_target = queueTarget(interface, allowed_cpu_count);

    const mem_available = readMemAvailableBytes() catch mem_available_fallback_bytes;
    const heavy_lane_bytes = @max(shape.estimatedHeavyLaneBytes(), @as(usize, 1));
    const lane_memory_capacity = @max(@as(usize, 1), (mem_available / lane_memory_share_divisor) / heavy_lane_bytes);
    const lane_count = try resolveStaticLaneCount(queue_target, allowed_cpu_count, lane_memory_capacity, explicit_lane_count);
    const lane_cpu_ids = try selectLaneCpuIds(allocator, allowed_cpu_ids, lane_count);
    errdefer allocator.free(lane_cpu_ids);

    return .{
        .lane_count = lane_count,
        .allowed_cpu_count = allowed_cpu_count,
        .allowed_cpu_ids = allowed_cpu_ids,
        .lane_cpu_ids = lane_cpu_ids,
        .interface = interface,
        .mem_available_bytes = mem_available,
    };
}

/// The interface that holds `address`, or null when the address maps to no
/// single interface: the unspecified address, or one no interface lists.
/// Every loopback address is `lo`, including those `lo` does not list but
/// serves through its local route, such as 127.0.0.2.
pub fn interfaceFor(allocator: std.mem.Allocator, address: std.net.Address) Error!?InterfaceName {
    switch (address.any.family) {
        std.posix.AF.INET => return interfaceForIp4(@bitCast(address.in.sa.addr)),
        std.posix.AF.INET6 => {
            const bytes = address.in6.sa.addr;
            if (ip4Mapped(bytes)) |ip4|
                return interfaceForIp4(ip4);
            if (std.mem.eql(u8, &bytes, &ip6_loopback))
                return InterfaceName.loopback;
            if (std.mem.allEqual(u8, &bytes, 0))
                return null;
            return interfaceForIp6(allocator, bytes);
        },
        else => return null,
    }
}

/// The receive and transmit queue counts of `name`, from sysfs. Fails with
/// `error.FileNotFound` when no such interface exists and with
/// `error.NoRxQueues` when it lists no receive queue.
pub fn interfaceQueues(allocator: std.mem.Allocator, name: InterfaceName) Error!Interface {
    const rx_queues = try countQueues(allocator, name, "rx-");
    const tx_queues = try countQueues(allocator, name, "tx-");
    if (rx_queues == 0)
        return error.NoRxQueues;
    return .{ .name = name, .rx_queues = rx_queues, .tx_queues = tx_queues };
}

/// The CPUs this process may run on, ascending, from its affinity mask. When
/// the mask cannot be read, CPUs 0 to `getCpuCount` - 1. The caller frees
/// the slice.
pub fn discoverAllowedCpus(allocator: std.mem.Allocator) Error![]usize {
    const set = std.posix.sched_getaffinity(0) catch {
        const fallback = std.Thread.getCpuCount() catch 1;
        const cpus = try allocator.alloc(usize, @max(@as(usize, 1), fallback));
        for (cpus, 0..) |*cpu, index|
            cpu.* = index;
        return cpus;
    };
    const word_bits = @bitSizeOf(usize);
    var count: usize = 0;
    for (set) |word|
        count += @popCount(word);
    if (count == 0)
        return error.NoAllowedCpus;
    const cpus = try allocator.alloc(usize, count);
    var out: usize = 0;
    for (set, 0..) |word, word_index| {
        var bits = word;
        var bit: usize = 0;
        while (bits != 0) : (bit += 1) {
            if ((bits & 1) != 0) {
                cpus[out] = word_index * word_bits + bit;
                out += 1;
            }
            bits >>= 1;
        }
    }
    return cpus;
}

/// The receive queue count of the listen interface, or `allowed_cpu_count`
/// when the address maps to no single interface or to `lo`, whose one queue
/// says nothing about where connections arrive.
pub fn queueTarget(interface: ?Interface, allowed_cpu_count: usize) usize {
    const found = interface orelse return allowed_cpu_count;
    if (std.mem.eql(u8, found.name.slice(), InterfaceName.loopback.slice()))
        return allowed_cpu_count;
    return found.rx_queues;
}

/// `queue_target` comes from `queueTarget`. A nonzero `explicit_lane_count`
/// is capped only by the CPU count; otherwise the target is capped by the
/// CPU count and `lane_memory_capacity`, and the result is at least 1.
pub fn resolveStaticLaneCount(queue_target: usize, allowed_cpu_count: usize, lane_memory_capacity: usize, explicit_lane_count: usize) Error!usize {
    if (queue_target == 0)
        return error.NoRxQueues;
    if (allowed_cpu_count == 0)
        return error.NoAllowedCpus;
    if (explicit_lane_count != 0)
        return @min(explicit_lane_count, allowed_cpu_count);
    const capped = @min(queue_target, @min(allowed_cpu_count, @max(@as(usize, 1), lane_memory_capacity)));
    return @max(@as(usize, 1), capped);
}

/// The first `lane_count` allowed CPUs, one per lane; the caller frees the
/// slice. Fails with `error.InvalidLaneCount` when `lane_count` is zero or
/// exceeds the allowed CPUs.
pub fn selectLaneCpuIds(
    allocator: std.mem.Allocator,
    allowed_cpu_ids: []const usize,
    lane_count: usize,
) Error![]usize {
    if (allowed_cpu_ids.len == 0)
        return error.NoAllowedCpus;
    if (lane_count == 0)
        return error.InvalidLaneCount;
    if (lane_count > allowed_cpu_ids.len)
        return error.InvalidLaneCount;

    const lane_cpu_ids = try allocator.alloc(usize, lane_count);
    @memcpy(lane_cpu_ids, allowed_cpu_ids[0..lane_count]);
    return lane_cpu_ids;
}

/// Restricts the calling thread to `cpu_id`. Fails with
/// `error.CpuIdOutOfRange` past `CPU_SETSIZE`, or with the kernel's refusal.
pub fn pinCurrentThreadToCpu(cpu_id: usize) !void {
    const word_bits = @bitSizeOf(usize);
    if (cpu_id >= linux.CPU_SETSIZE)
        return error.CpuIdOutOfRange;

    var set = std.mem.zeroes(linux.cpu_set_t);
    set[cpu_id / word_bits] = @as(usize, 1) << @intCast(cpu_id % word_bits);
    try linux.sched_setaffinity(0, &set);
}

const ip6_loopback = [_]u8{0} ** 15 ++ [_]u8{1};

/// The IPv4 address inside an IPv4-mapped IPv6 address (`::ffff:a.b.c.d`).
fn ip4Mapped(bytes: [16]u8) ?[4]u8 {
    const prefix = [_]u8{0} ** 10 ++ [_]u8{ 0xff, 0xff };
    if (!std.mem.eql(u8, bytes[0..12], &prefix))
        return null;
    return bytes[12..16].*;
}

fn interfaceForIp4(bytes: [4]u8) Error!?InterfaceName {
    if (bytes[0] == 127)
        return InterfaceName.loopback;
    if (std.mem.allEqual(u8, &bytes, 0))
        return null;

    var socket = fd_mod.OwnedFd.fromRaw(try std.posix.socket(
        std.posix.AF.INET,
        std.posix.SOCK.DGRAM | std.posix.SOCK.CLOEXEC,
        0,
    ));
    defer socket.deinit();
    var requests: [ipv4_addresses_max]linux.ifreq = undefined;
    var configuration: InterfaceConfiguration = .{
        .len = @intCast(@sizeOf(@TypeOf(requests))),
        .requests = &requests,
    };
    const rc = linux.ioctl(socket.fd(), linux.SIOCGIFCONF, @intFromPtr(&configuration));
    switch (linux.E.init(rc)) {
        .SUCCESS => {},
        else => |errno| return std.posix.unexpectedErrno(errno),
    }
    const filled_bytes: usize = @intCast(configuration.len);
    const count = @divFloor(filled_bytes, @sizeOf(linux.ifreq));
    std.debug.assert(count <= requests.len);
    for (requests[0..count]) |*request| {
        const address = &request.ifru.addr;
        if (address.family != std.posix.AF.INET)
            continue;
        // `sockaddr_in` keeps the port in data[0..2] and the address in
        // data[2..6].
        if (!std.mem.eql(u8, address.data[2..6], &bytes))
            continue;
        return interfaceOfLabel(std.mem.sliceTo(&request.ifrn.name, 0));
    }
    return null;
}

/// An IPv4 address label names its device, optionally followed by `:` and an
/// alias (`eth0:1`); sysfs knows only the device.
fn interfaceOfLabel(label: []const u8) ?InterfaceName {
    const device = label[0 .. std.mem.indexOfScalar(u8, label, ':') orelse label.len];
    return InterfaceName.init(device) catch null;
}

/// Each line of `/proc/net/if_inet6` holds the address as 32 hex digits, the
/// interface index, prefix length, scope and flags, then the interface name.
/// The file is absent when the kernel runs without IPv6. Lines past
/// `if_inet6_bytes_max` are not read, and a line cut at that bound is
/// dropped rather than matched with a truncated name.
fn interfaceForIp6(allocator: std.mem.Allocator, bytes: [16]u8) Error!?InterfaceName {
    var file = std.fs.openFileAbsolute("/proc/net/if_inet6", .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |other| return other,
    };
    defer file.close();
    const buffer = try allocator.alloc(u8, if_inet6_bytes_max);
    defer allocator.free(buffer);
    const length = try file.readAll(buffer);
    const complete_length = if (length < buffer.len)
        length
    else
        std.mem.lastIndexOfScalar(u8, buffer, '\n') orelse 0;
    var lines = std.mem.splitScalar(u8, buffer[0..complete_length], '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const hex = fields.next() orelse continue;
        if (hex.len != 32)
            continue;
        var listed: [16]u8 = undefined;
        _ = std.fmt.hexToBytes(&listed, hex) catch continue;
        if (!std.mem.eql(u8, &listed, &bytes))
            continue;
        var name: []const u8 = "";
        while (fields.next()) |field|
            name = field;
        return InterfaceName.init(name) catch null;
    }
    return null;
}

/// `struct ifconf` from <net/if.h>: the buffer size in bytes, which the
/// kernel rewrites to the bytes it filled, then the buffer.
const InterfaceConfiguration = extern struct {
    len: c_int,
    requests: [*]linux.ifreq,
};

comptime {
    std.debug.assert(@offsetOf(InterfaceConfiguration, "requests") == @sizeOf(usize));
    std.debug.assert(ipv4_addresses_max * @sizeOf(linux.ifreq) <= std.math.maxInt(c_int));
}

fn countQueues(allocator: std.mem.Allocator, name: InterfaceName, prefix: []const u8) Error!usize {
    const path = try std.fmt.allocPrint(allocator, "/sys/class/net/{s}/queues", .{name.slice()});
    defer allocator.free(path);
    var dir = try std.fs.openDirAbsolute(path, .{ .iterate = true });
    defer dir.close();
    var count: usize = 0;
    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (std.mem.startsWith(u8, entry.name, prefix))
            count += 1;
    }
    return count;
}

fn readMemAvailableBytes() !usize {
    var file = try std.fs.openFileAbsolute("/proc/meminfo", .{});
    defer file.close();
    var buffer: [meminfo_head_bytes]u8 = undefined;
    const length = try file.readAll(&buffer);
    var lines = std.mem.splitScalar(u8, buffer[0..length], '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "MemAvailable:"))
            continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        _ = fields.next();
        const kib = fields.next() orelse return error.InvalidMeminfo;
        return try std.math.mul(usize, try std.fmt.parseUnsigned(usize, kib, 10), 1024);
    }
    return error.InvalidMeminfo;
}

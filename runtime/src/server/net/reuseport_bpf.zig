//! The SO_REUSEPORT eBPF selector that steers each new connection to the
//! ingress lane pinned to the CPU that received it. `IngressListeners.init`
//! (`listener.zig`) attaches it once, on the thread that builds the
//! listeners, and serves without it when the attach fails.
//!
//! The kernel runs the program each time it picks a listener for a new
//! connection. The program looks the receiving CPU up in an array map of lane
//! indices and selects that lane's listener from a reuseport socket array
//! keyed by listener position, so the socket array holds the listeners in
//! lane order. A CPU without a lane, or a listener the kernel cannot select,
//! leaves no socket chosen, and the kernel falls back to its reuseport hash.
//! A program attached to one listener serves its whole reuseport group, and
//! the loaded program holds its maps, so every descriptor opened here is
//! closed once the attach succeeds.

const std = @import("std");
const linux = std.os.linux;
const bpf = linux.BPF;

/// Marks a CPU no lane is pinned to. It is never below the lane count, so
/// the program leaves such a CPU's connections to the kernel's hash.
pub const invalid_lane_index: u32 = std.math.maxInt(u32);

/// Fills `out`, indexed by CPU id, with each lane CPU's lane index and
/// `invalid_lane_index` everywhere else, and returns how many entries the
/// map needs: the highest lane CPU plus one. Fails with
/// `error.CpuIdOutOfRange` when a CPU id does not fit `out`.
pub fn fillCpuLaneMap(out: []u32, lane_cpu_ids: []const usize) !usize {
    if (lane_cpu_ids.len == 0)
        return error.InvalidLaneCount;
    if (out.len == 0)
        return error.InvalidLaneCount;

    @memset(out, invalid_lane_index);
    var cpu_count: usize = 1;
    for (lane_cpu_ids, 0..) |cpu_id, lane_index| {
        if (cpu_id >= out.len)
            return error.CpuIdOutOfRange;
        if (lane_index > std.math.maxInt(u32))
            return error.InvalidLaneCount;
        out[cpu_id] = @intCast(lane_index);
        cpu_count = @max(cpu_count, cpu_id + 1);
    }
    return cpu_count;
}

/// `listeners` and `lane_cpu_ids` are both in lane order, one CPU per
/// listener. Fails when the kernel refuses a map, the program or the attach;
/// a refused program logs the verifier's output.
pub fn attachCpuSelector(listeners: []const std.net.Server, lane_cpu_ids: []const usize) !void {
    if (listeners.len == 0)
        return error.InvalidLaneCount;
    if (listeners.len != lane_cpu_ids.len)
        return error.InvalidLaneCount;
    if (listeners.len > std.math.maxInt(u32))
        return error.InvalidLaneCount;

    var cpu_to_lane_storage: [linux.CPU_SETSIZE]u32 = undefined;
    const cpu_map_entries = try fillCpuLaneMap(&cpu_to_lane_storage, lane_cpu_ids);
    const lane_count: u32 = @intCast(listeners.len);

    const cpu_map = try bpf.map_create(
        .array,
        @sizeOf(u32),
        @sizeOf(u32),
        @intCast(cpu_map_entries),
    );
    errdefer std.posix.close(cpu_map);

    var cpu_key: u32 = 0;
    while (cpu_key < cpu_map_entries) : (cpu_key += 1) {
        try bpf.map_update_elem(
            cpu_map,
            std.mem.asBytes(&cpu_key),
            std.mem.asBytes(&cpu_to_lane_storage[cpu_key]),
            bpf.ANY,
        );
    }

    const socket_map = try bpf.map_create(
        .reuseport_sockarray,
        @sizeOf(u32),
        @sizeOf(u32),
        lane_count,
    );
    errdefer std.posix.close(socket_map);

    for (listeners, 0..) |listener, index| {
        var socket_key: u32 = @intCast(index);
        var socket_fd: u32 = @intCast(listener.stream.handle);
        try bpf.map_update_elem(
            socket_map,
            std.mem.asBytes(&socket_key),
            std.mem.asBytes(&socket_fd),
            bpf.ANY,
        );
    }

    var log_buffer = std.mem.zeroes([16 * 1024]u8);
    var log = bpf.Log{ .level = 1, .buf = &log_buffer };
    const program = loadSelectorProgram(cpu_map, socket_map, lane_count, &log) catch |err| {
        logVerifierFailure(err, log.buf);
        return err;
    };
    errdefer std.posix.close(program);

    try attachProgram(listeners[0].stream.handle, program);

    std.posix.close(program);
    std.posix.close(socket_map);
    std.posix.close(cpu_map);
}

fn selectorProgram(
    cpu_map: linux.fd_t,
    socket_map: linux.fd_t,
    lane_count: u32,
) [21]bpf.Insn {
    const pass_action: i32 = 1; // SK_PASS
    const lane_count_signed: i32 = @intCast(lane_count);
    // r6 keeps the context. The receiving CPU's id, stored at fp-4, is the
    // key into `cpu_map`. A missing entry or a lane index at or past
    // `lane_count` jumps to the exit; otherwise the lane index, stored at
    // fp-8, selects that lane's listener from `socket_map`. Either way the
    // program returns SK_PASS, and when it selected no listener the kernel
    // picks one by its reuseport hash.
    return .{
        bpf.Insn.mov(.r6, .r1),
        bpf.Insn.call(.get_smp_processor_id),
        bpf.Insn.stx(.word, .r10, -4, .r0),
        bpf.Insn.mov(.r2, .r10),
        bpf.Insn.add(.r2, -4),
        bpf.Insn.ld_map_fd1(.r1, cpu_map),
        bpf.Insn.ld_map_fd2(cpu_map),
        bpf.Insn.call(.map_lookup_elem),
        bpf.Insn.jeq(.r0, 0, 10),
        bpf.Insn.ldx(.word, .r0, .r0, 0),
        bpf.Insn.jge(.r0, lane_count_signed, 8),
        bpf.Insn.stx(.word, .r10, -8, .r0),
        bpf.Insn.mov(.r1, .r6),
        bpf.Insn.ld_map_fd1(.r2, socket_map),
        bpf.Insn.ld_map_fd2(socket_map),
        bpf.Insn.mov(.r3, .r10),
        bpf.Insn.add(.r3, -8),
        bpf.Insn.mov(.r4, 0),
        bpf.Insn.call(.sk_select_reuseport),
        bpf.Insn.mov(.r0, pass_action),
        bpf.Insn.exit(),
    };
}

fn loadSelectorProgram(
    cpu_map: linux.fd_t,
    socket_map: linux.fd_t,
    lane_count: u32,
    log: *bpf.Log,
) !linux.fd_t {
    const program = selectorProgram(cpu_map, socket_map, lane_count);
    var attr = bpf.Attr{
        .prog_load = std.mem.zeroes(bpf.ProgLoadAttr),
    };

    attr.prog_load.prog_type = @intFromEnum(bpf.ProgType.sk_reuseport);
    attr.prog_load.expected_attach_type = @intFromEnum(bpf.AttachType.sk_reuseport_select);
    attr.prog_load.insns = @intFromPtr(program[0..].ptr);
    attr.prog_load.insn_cnt = @intCast(program.len);
    const license: [:0]const u8 = "MIT";
    attr.prog_load.license = @intFromPtr(license.ptr);
    attr.prog_load.log_buf = @intFromPtr(log.buf.ptr);
    attr.prog_load.log_size = @intCast(log.buf.len);
    attr.prog_load.log_level = log.level;

    const rc = linux.bpf(.prog_load, &attr, @sizeOf(bpf.ProgLoadAttr));
    return switch (linux.E.init(rc)) {
        .SUCCESS => @intCast(rc),
        .ACCES => error.UnsafeProgram,
        .INVAL => error.InvalidProgram,
        .NOMEM => error.SystemResources,
        .PERM => error.PermissionDenied,
        else => |err| std.posix.unexpectedErrno(err),
    };
}

fn attachProgram(listener_fd: std.posix.fd_t, program_fd: linux.fd_t) !void {
    if (!@hasDecl(std.posix.SO, "ATTACH_REUSEPORT_EBPF"))
        return error.ReusePortBpfUnavailable;
    const program_fd_c: c_int = @intCast(program_fd);
    try std.posix.setsockopt(
        listener_fd,
        std.posix.SOL.SOCKET,
        std.posix.SO.ATTACH_REUSEPORT_EBPF,
        std.mem.asBytes(&program_fd_c),
    );
}

fn logVerifierFailure(err: anyerror, log_buffer: []const u8) void {
    const end = std.mem.indexOfScalar(u8, log_buffer, 0) orelse log_buffer.len;
    const verifier_log = std.mem.trimRight(u8, log_buffer[0..end], "\x00\n\r\t ");
    if (verifier_log.len == 0) {
        std.log.warn("reuseport eBPF selector load failed: {s}", .{@errorName(err)});
        return;
    }
    std.log.warn("reuseport eBPF selector load failed: {s}: {s}", .{
        @errorName(err),
        verifier_log,
    });
}

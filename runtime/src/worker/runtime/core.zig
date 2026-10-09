//! The core of the worker runtime, which every domain reads: the allocator,
//! the VM, the control socket, the resolved limits, the clock, two packet
//! scratch buffers and the `running` flag that ends the event loop. It
//! belongs to the worker's VM thread. The VM and the control socket stay the
//! boot's: `deinit` frees only the two buffers.

const std = @import("std");
const bindings = @import("collo_bindings");
const ipc = @import("collo_ipc");
const runtime_types = @import("types.zig");

pub const Core = struct {
    allocator: std.mem.Allocator,
    vm: *bindings.Vm,
    control_fd: ?std.posix.fd_t,
    limits: runtime_types.RuntimeLimits,
    clock: runtime_types.Clock,
    /// One packet of `ipc.max_message_bytes`, reused by the VM thread for
    /// every packet it receives on the control socket, the fs fault channel
    /// or the gateway's completion ring, and for the command and response
    /// packets it encodes, so its contents last only until the next use.
    dispatch_recv_scratch: []u8,
    /// Where gateway packets decode their header and body chunk views. It is
    /// sized by the protocol's ceilings, `max_request_header_count` headers
    /// and `max_body_chunk_batch_count` chunks, so it is heap-allocated once,
    /// and the VM thread decodes one packet into it at a time.
    egress_decode_scratch: *ipc.WorkerEgressDecodeScratch,
    running: bool,

    pub fn init(
        allocator: std.mem.Allocator,
        vm: *bindings.Vm,
        control_fd: ?std.posix.fd_t,
        options: runtime_types.RuntimeOptions,
    ) !Core {
        const dispatch_recv_scratch = try allocator.alloc(u8, ipc.max_message_bytes);
        errdefer allocator.free(dispatch_recv_scratch);
        const egress_decode_scratch = try allocator.create(ipc.WorkerEgressDecodeScratch);
        egress_decode_scratch.* = .{};
        return .{
            .allocator = allocator,
            .vm = vm,
            .control_fd = control_fd,
            .limits = runtime_types.resolveAutoRuntimeLimits(options.limits),
            .clock = options.clock,
            .dispatch_recv_scratch = dispatch_recv_scratch,
            .egress_decode_scratch = egress_decode_scratch,
            .running = true,
        };
    }

    pub fn deinit(self: *Core) void {
        self.allocator.destroy(self.egress_decode_scratch);
        self.allocator.free(self.dispatch_recv_scratch);
        self.* = undefined;
    }

    pub fn nowMonoNs(self: *const Core) u64 {
        return self.clock.now();
    }
};

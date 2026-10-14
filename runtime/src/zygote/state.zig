//! The zygote's state for its whole life: its one VM and the write end of the
//! boot trace pipe. The zygote's main thread owns it (`fork_loop.zig`), and
//! every worker child inherits a copy at its clone, so it holds nothing
//! specific to a worker or a tenant: everything a worker inherits is the
//! same for all tenants.

const std = @import("std");
const bindings = @import("collo_bindings");

pub const Zygote = struct {
    vm: bindings.Vm,
    /// The write end of the trace pipe (`trace.zig`) at
    /// `fork_loop.zig:inherited_trace_fd`; null when the host asked for no
    /// trace.
    trace_fd: ?std.posix.fd_t,

    /// Creates the zygote's VM, the process's first, which fixes the engine's
    /// options for the whole process (`collo_vm_create`). Takes `trace_fd`
    /// on success; the caller keeps it on failure.
    pub fn init(trace_fd: ?std.posix.fd_t) !Zygote {
        return .{
            .vm = try bindings.Vm.createDefault(),
            .trace_fd = trace_fd,
        };
    }

    /// Closes this process's write end of the trace pipe, if it has one, and
    /// forgets its number, so no later trace call writes into a file that a
    /// later open gave the same number. A worker child calls it before its
    /// first tenant code (`child_boot.zig`).
    pub fn closeTrace(self: *Zygote) void {
        const fd = self.trace_fd orelse return;
        self.trace_fd = null;
        std.posix.close(fd);
    }

    /// Closes the trace and destroys the VM, for an owner that outlives the
    /// state, such as a test. The zygote process never calls it: it exits
    /// without teardown (`fork_loop.zig:runFromInheritedFds`).
    pub fn deinit(self: *Zygote) void {
        self.closeTrace();
        self.vm.deinit();
        self.* = undefined;
    }
};

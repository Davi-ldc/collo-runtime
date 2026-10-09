//! State the zygote keeps for its whole life, and the state a worker child
//! builds while it boots. `Zygote` holds nothing specific to a worker or
//! tenant, and it is prepared for forking exactly once; the fork loop refuses
//! to fork otherwise.

const std = @import("std");
const bindings = @import("collo_bindings");
const worker_shared_page = @import("collo_worker_state").page;

const boot_allocator = std.heap.smp_allocator;

pub const ZygoteOptions = struct {
    executable_path: ?[]const u8 = null,
    postfork_exit_probe_path: ?[]const u8 = null,
    /// Runs the embedded warmup corpus once at boot, so engine structures JSC
    /// creates lazily land in pages every worker shares.
    warmup_corpus: bool = false,
    vm_options: bindings.VmOptions = bindings.VmOptions.init(),
};

pub const WorkerState = struct {
    allocator: std.mem.Allocator,
    pid: u32,
    memory_limit_bytes: u64,
    metrics: ?worker_shared_page.WorkerWriterView,
    memory_events_fd: ?std.posix.fd_t,
    cgroup_dir: ?[]u8,
    lifecycle_state: worker_shared_page.State,

    pub fn init(
        allocator: std.mem.Allocator,
        pid: u32,
        memory_limit_bytes: u64,
    ) !WorkerState {
        return .{
            .allocator = allocator,
            .pid = pid,
            .memory_limit_bytes = memory_limit_bytes,
            .metrics = null,
            .memory_events_fd = null,
            .cgroup_dir = null,
            .lifecycle_state = .forked,
        };
    }

    pub fn deinit(self: *WorkerState) void {
        if (self.metrics) |*metrics|
            metrics.deinit();
        if (self.memory_events_fd) |fd|
            std.posix.close(fd);
        if (self.cgroup_dir) |path|
            self.allocator.free(path);
        self.* = undefined;
    }
};

pub const Zygote = struct {
    vm: bindings.Vm,
    trace_fd: ?std.posix.fd_t,
    postfork_exit_probe_path: ?[]u8,
    warmup_corpus: bool,
    prepared_for_fork: bool,
    prepare_count: u32,

    pub fn init(trace_fd: ?std.posix.fd_t, options: ZygoteOptions) !Zygote {
        const exit_probe_path = if (options.postfork_exit_probe_path) |path|
            try boot_allocator.dupe(u8, path)
        else
            null;
        errdefer if (exit_probe_path) |path| boot_allocator.free(path);

        return .{
            .vm = try bindings.Vm.create(options.vm_options),
            .trace_fd = trace_fd,
            .postfork_exit_probe_path = exit_probe_path,
            .warmup_corpus = options.warmup_corpus,
            .prepared_for_fork = false,
            .prepare_count = 0,
        };
    }

    pub fn deinit(self: *Zygote) void {
        if (self.trace_fd) |fd|
            std.posix.close(fd);
        if (self.postfork_exit_probe_path) |path|
            boot_allocator.free(path);
        self.vm.deinit();
        self.* = undefined;
    }
};

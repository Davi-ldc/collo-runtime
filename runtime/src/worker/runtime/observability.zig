//! The observability domain of the worker runtime. `Observability` is its
//! state: the writer view of the worker's shared state page, the sentinel,
//! the trace settings and the handler counters. `Methods` holds the
//! runtime's operations on it, which `Runtime` declares as its own
//! (`root.zig`): trace events and the CPU each live request publishes to its
//! slot on the page. It belongs to the worker's VM thread. The sentinel's
//! own thread reaches only the `Sentinel` state it guards, the VM's
//! termination request, the trace fd and atomic stores to the page, and it
//! exits the process on memory pressure (`sentinel.zig`).

const std = @import("std");
const bindings = @import("collo_bindings");
const process_limits = @import("collo_limits").process;
const worker_shared_page = @import("collo_worker_state").page;
const common_worker_metrics_state = @import("collo_worker_state").metrics;
const runtime_types = @import("types.zig");
const worker_sentinel = @import("sentinel.zig");

pub const Observability = struct {
    /// Required, since the page carries every request's completion record
    /// (`Runtime.init`). Borrowed from the worker boot, which keeps the page
    /// mapped until the runtime is gone.
    metrics_view: *worker_shared_page.WorkerWriterView,
    worker_metrics_state: common_worker_metrics_state.WorkState,
    // Not optional: a turn whose JavaScript never yields holds the VM thread,
    // which cannot interrupt itself, so only another thread can stop it.
    sentinel: worker_sentinel.Sentinel,
    trace_fd: ?std.posix.fd_t,
    trace_requests: bool,
    trace_all_requests: bool,
    bench_handler: bool,
    traced_first_request: bool,
    sync_handler_fast_path_count: u64,
    thenable_handler_count: u64,
    response_extraction_count: u64,
    stale_task_completion_count: u64,

    pub fn init(
        vm: *bindings.Vm,
        metrics_view: *worker_shared_page.WorkerWriterView,
        options: runtime_types.RuntimeOptions,
    ) !Observability {
        return .{
            .metrics_view = metrics_view,
            .worker_metrics_state = common_worker_metrics_state.WorkState.init(metrics_view),
            .sentinel = try worker_sentinel.Sentinel.init(vm, .{
                .memory_events_fd = options.memory_events_fd,
                .metrics = metrics_view,
                .trace_fd = options.trace_fd,
            }),
            .trace_fd = options.trace_fd,
            .trace_requests = options.trace_requests,
            .trace_all_requests = options.trace_all_requests,
            .bench_handler = options.bench_handler,
            .traced_first_request = false,
            .sync_handler_fast_path_count = 0,
            .thenable_handler_count = 0,
            .response_extraction_count = 0,
            .stale_task_completion_count = 0,
        };
    }

    pub fn deinit(self: *Observability) void {
        self.sentinel.deinit();
        self.* = undefined;
    }
};

pub fn Methods(comptime Runtime: type) type {
    return struct {
        pub fn traceRuntimeEvent(self: *Runtime, comptime fmt: []const u8, args: anytype) void {
            traceEventFmt(self.observability.trace_fd, fmt, args);
        }

        /// Publishes each live request's accumulated CPU to its live slot, so a
        /// death record the host synthesizes after a crash, an out-of-memory
        /// kill or a deadline reports the turns already run. The value is a
        /// floor: the final, partial turn is missing. Called once per event-loop
        /// tick on the VM thread, where `cpu_used_ns_total` is stable, since turns
        /// add to it only between flushes.
        pub fn flushLiveRequestCpuBestEffort(self: *Runtime) void {
            var work_state = self.observability.worker_metrics_state;
            var iterator = self.requests.active.valueIterator();
            while (iterator.next()) |entry| {
                const request_ctx = entry.*;
                if (request_ctx.finish_started or request_ctx.live_slot_released)
                    continue;
                work_state.updateLiveSlotCpu(request_ctx.live_slot_index, request_ctx.exec.cpu_used_ns_total) catch |err| switch (err) {
                    error.InvalidLiveSlot, error.StaleLiveSlot => {},
                };
            }
        }
    };
}

fn traceEventFmt(trace_fd: ?std.posix.fd_t, comptime fmt: []const u8, args: anytype) void {
    const fd = trace_fd orelse return;
    var buffer: [process_limits.TRACE_EVENT_BUFFER_BYTES]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, fmt ++ "\n", args) catch return;
    _ = std.posix.write(fd, line) catch return;
}

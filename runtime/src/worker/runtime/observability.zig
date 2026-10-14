//! The observability domain of the worker runtime. `Observability` is its
//! state: the writer view of the worker's shared state page, the sentinel
//! and the benchmark marker switch. `Methods` holds the runtime's operation
//! on it, which `Runtime` declares as its own (`root.zig`): the network
//! denials the runtime writes to the tenant's log. Every line of the
//! tenant's log, these and the console and exception lines (`vm_hooks.zig`),
//! carries the request id `ringRequestId` gives its owner. After boot the
//! runtime tells the operator anything only through `std.log`, whose lines
//! reach the server's stderr through the page's console ring
//! (`zygote/log_sink.zig`).
//!
//! It belongs to the worker's VM thread. The sentinel's own thread reaches
//! only the `Sentinel` state it guards, the VM's termination request and
//! atomic stores to the page, and it exits the process on memory pressure
//! (`sentinel.zig`).

const std = @import("std");
const bindings = @import("collo_bindings");
const worker_shared_page = @import("collo_worker_state").page;
const request_context = @import("collo_worker_request").context;
const runtime_types = @import("types.zig");
const worker_sentinel = @import("sentinel.zig");

/// The request id a line of the tenant's log carries on the console ring:
/// its owner's id when the owner is a dispatched request, and 0 for an
/// evaluation or the worker owner. The server reads 0 as no request, and a
/// reserved id names nothing it knows.
pub fn ringRequestId(request_id: u64) u64 {
    if (request_context.isReservedId(request_id))
        return 0;
    return request_id;
}

pub const Observability = struct {
    /// Required: the page carries every live request's slot and the
    /// sentinel's view of the running owner (`Runtime.init`). Borrowed from
    /// the worker boot, which keeps the page mapped until the runtime is
    /// gone.
    metrics_view: *worker_shared_page.WorkerWriterView,
    // Not optional: a turn whose JavaScript never yields holds the VM thread,
    // which cannot interrupt itself, so only another thread can stop it.
    sentinel: worker_sentinel.Sentinel,
    bench_handler: bool,

    pub fn init(
        vm: *bindings.Vm,
        metrics_view: *worker_shared_page.WorkerWriterView,
        options: runtime_types.RuntimeOptions,
    ) !Observability {
        return .{
            .metrics_view = metrics_view,
            .sentinel = try worker_sentinel.Sentinel.init(vm, .{
                .memory_events_fd = options.memory_events_fd,
                .metrics = metrics_view,
            }),
            .bench_handler = options.bench_handler,
        };
    }

    pub fn deinit(self: *Observability) void {
        self.sentinel.deinit();
        self.* = undefined;
    }
};

pub fn Methods(comptime Runtime: type) type {
    return struct {
        /// Writes `message`, the network setting's denial of a fetch of
        /// `request_id`, as one `warn` line in the tenant's log. A denial is
        /// the tenant's event, so it never reaches the operator's stderr,
        /// and it costs the tenant a fetch of its token's budget
        /// (`fetch_runtime.zig`), which bounds the lines one request writes.
        pub fn logNetworkDenial(self: *Runtime, request_id: u64, message: []const u8) void {
            self.observability.metrics_view.publishLogLine(
                .warn,
                0,
                ringRequestId(request_id),
                self.nowMonoNs(),
                message,
            );
        }
    };
}

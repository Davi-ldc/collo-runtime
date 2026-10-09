//! Cold-start timings on the page, which the worker writes and the host
//! reads as diagnostics: one stamp per boot phase, which the booting child
//! writes, and the record of the first instrumented handler call, which the
//! worker's VM thread publishes once.

/// Child boot phases stamped with one CLOCK_MONOTONIC read each, in the
/// order `zygote/child_boot.zig` reaches them, most named after the child's
/// trace event at the same step. A slot stays 0 when the phase never ran
/// (for example with no route entry). The booting child writes them and the
/// host reads them, mid-boot too: a child wedged in a later phase leaves
/// every earlier stamp visible.
pub const BootPhase = enum(u32) {
    namespaces_entered,
    worker_init_received,
    unexpected_fds_closed,
    worker_init_validated,
    /// The route's bindings are mapped and the process environment is
    /// cleared.
    environment_cleared,
    metrics_mapped,
    cgroup_validated,
    single_threaded_asserted,
    sandbox_applied,
    vm_resumed,
    fs_index_mapped,
    runtime_initialized,
    helper_threads_pinned,
    seccomp_applied,
    boot_context_ready,
    // `route_entry_evaluated` alone would not measure module execution: the
    // span before it covers mapping the pack, parsing and validating it in
    // Zig, a second validation in C++ and registration, so these three
    // stamps split that span from the evaluation itself.
    route_pack_mapped,
    route_pack_parsed,
    route_pack_registered,
    route_entry_evaluated,
    ready_sent,
};

pub const BOOT_PHASE_COUNT: usize = @typeInfo(BootPhase).@"enum".fields.len;

/// The first instrumented handler call in a worker, immutable once
/// published. The worker writes it, so it is a diagnostic only: a consumer
/// matches every identity against its own request and worker records before
/// it accepts the sample.
pub const BenchHandlerRecord = extern struct {
    request_id: u64,
    worker_id: u64,
    worker_generation: u64,
    handler_started_ns: u64,
};

pub fn loadBenchHandlerRecord(record: *const BenchHandlerRecord) ?BenchHandlerRecord {
    const request_id = @atomicLoad(u64, &record.request_id, .acquire);
    if (request_id == 0)
        return null;
    return .{
        .request_id = request_id,
        .worker_id = @atomicLoad(u64, &record.worker_id, .monotonic),
        .worker_generation = @atomicLoad(u64, &record.worker_generation, .monotonic),
        .handler_started_ns = @atomicLoad(u64, &record.handler_started_ns, .monotonic),
    };
}

comptime {
    if (@sizeOf(BenchHandlerRecord) != 32)
        @compileError("worker_state.page.BenchHandlerRecord size mismatch");
    if (@offsetOf(BenchHandlerRecord, "request_id") != 0)
        @compileError("benchmark publication identity must lead the record");
}

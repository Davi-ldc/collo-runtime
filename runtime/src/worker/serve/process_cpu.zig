//! The worker process's CPU clock for usage records. A record's `cpu_time_ns`
//! (`CompletedRecord` in `common/worker_state/page/usage_records.zig`) is the
//! CLOCK_PROCESS_CPUTIME_ID delta since the previous record, so it covers
//! every thread of the process: JavaScript, collection, compilation, crypto
//! and wasm. A worker runs one tenant's routes, so all of that time is the
//! tenant's. When requests overlap, the one that finishes first takes the
//! whole span since the previous record, which moves time between their
//! records but keeps the worker's total exact. A parked thread accrues no CPU
//! time, so an idle worker adds nothing.
//!
//! The baseline is module state because the clock is process-wide. Outside
//! tests, the only caller of this file is `finishRequest`
//! (`response_finish.zig`), on the worker's VM thread. The kernel starts a
//! forked child's CPU-time counters at zero and the zygote never finishes a
//! request, so a worker starts at baseline 0 and its first record also
//! carries the CPU of its boot, including the route module's evaluation,
//! which no request owns.
//!
//! CPU-time clocks are real syscalls, because the vDSO serves no CPU-time
//! clock. The worker's seccomp filter allows `clock_gettime` and
//! `clock_gettime64` without an argument check
//! (`zygote/worker_boot/sandbox.zig`). A filter that refused them would leave
//! every record here at zero CPU, and the engine's per-turn clock
//! (`threadCpuTimeNs` in `bindings/jsc/runtime/vm.cpp`) would abort the
//! worker.

const std = @import("std");

var last_billed_process_cpu_ns: u64 = 0;

fn readProcessCpuNs() ?u64 {
    const ts = std.posix.clock_gettime(std.posix.CLOCK.PROCESS_CPUTIME_ID) catch return null;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// The process CPU time since the last committed record, read without
/// advancing the baseline. The caller passes the delta to
/// `commitBilledDeltaNs` only once its record is in the ring, so a record
/// that never gets there leaves the span uncommitted; `finishRequest` then
/// folds it into the request's live slot. A reading below the baseline gives
/// 0, and so does a failed read, which leaves the span for the next record.
pub fn peekBilledDeltaNs() u64 {
    const now = readProcessCpuNs() orelse return 0;
    return now -| last_billed_process_cpu_ns;
}

/// Advances the baseline by `delta`, the value `peekBilledDeltaNs` returned
/// for a record now in the ring. Adding the delta instead of reading the
/// clock again puts the baseline exactly at the peeked reading, so CPU time
/// spent between the peek and the commit stays for the next record.
pub fn commitBilledDeltaNs(delta: u64) void {
    last_billed_process_cpu_ns +|= delta;
}

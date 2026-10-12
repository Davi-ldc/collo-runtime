//! The `collo_runtime_crypto_job_enqueue` export, through which the bridge's
//! WebCrypto functions (`bindings/host_functions/webapi/crypto/jobs.cpp`)
//! hand a native job to the worker's crypto pool (`js/crypto/runtime.zig`).
//! Runs on the worker's VM thread. As abi.h requires, the pool owns the job
//! only when the call returns `COLLO_STATUS_OK`; on any other status the
//! bridge keeps it.

const bindings = @import("collo_bindings");
const host_adapter = @import("adapter.zig");

pub export fn collo_runtime_crypto_job_enqueue(
    runtime_ptr: ?*anyopaque,
    request_id: u64,
    job: ?*bindings.RawCryptoJob,
) bindings.RawStatus {
    const runtime = host_adapter.fromOpaque(runtime_ptr) orelse return bindings.status_invalid_argument;
    if (request_id == 0 or job == null)
        return bindings.status_invalid_argument;

    // Each status names one cause, which the bridge turns into its own
    // rejection message (`enqueueCryptoJobPromise` in `jobs.cpp`): an owner
    // that accepts no work is a call outside an active request turn, a full
    // in-flight bound is too many operations, and a pool that never started
    // or is stopping is a pool that is not running.
    runtime.scheduleCryptoJob(request_id, job.?) catch |err| switch (err) {
        error.CryptoJobOutsideActiveRequest,
        error.InvalidCryptoJob,
        => return bindings.status_invalid_argument,
        error.CryptoJobRequestQueueFull,
        error.CryptoJobWorkerQueueFull,
        => return bindings.status_error,
        error.CryptoJobPoolUnavailable,
        error.CryptoJobPoolStopping,
        => return bindings.status_unsupported,
    };
    return bindings.status_ok;
}

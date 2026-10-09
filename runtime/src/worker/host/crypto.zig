//! The `collo_runtime_crypto_job_enqueue` export, through which the bridge's
//! WebCrypto functions (`bindings/host_functions/webapi/crypto/jobs.cpp`)
//! hand a native job to the worker's crypto pool (`js/crypto/runtime.zig`).
//! Runs on the worker's VM thread. As abi.h requires, the pool owns the job
//! only when the call returns `COLLO_STATUS_OK`; on any other status the
//! bridge keeps it.

const bindings = @import("collo_bindings");
const host_adapter = @import("adapter.zig");

// The `ColloStatus` values of abi.h.
const status_ok: c_int = 0;
const status_error: c_int = 1;
const status_invalid_argument: c_int = 2;

pub export fn collo_runtime_crypto_job_enqueue(
    runtime_ptr: ?*anyopaque,
    request_id: u64,
    job: ?*bindings.RawCryptoJob,
) c_int {
    const runtime = host_adapter.fromOpaque(runtime_ptr) orelse return status_invalid_argument;
    if (request_id == 0 or job == null)
        return status_invalid_argument;

    // The bridge rejects an invalid argument as a call outside an active
    // request turn, and any other failure as a full job queue.
    runtime.scheduleCryptoJob(request_id, job.?) catch |err| switch (err) {
        error.CryptoJobOutsideActiveRequest => return status_invalid_argument,
        error.InvalidCryptoJob,
        error.CryptoJobPoolUnavailable,
        error.CryptoJobPoolStopping,
        error.CryptoJobRequestQueueFull,
        error.CryptoJobWorkerQueueFull,
        => return status_error,
    };
    return status_ok;
}

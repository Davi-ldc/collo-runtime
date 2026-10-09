//! The crypto domain of the worker runtime. `Crypto` is its state, the
//! WebCrypto job pool (`js/crypto/jobs.zig`) sized from `RuntimeLimits`, and
//! `Methods` holds the runtime's operations on it, which `Runtime` declares
//! as its own (`root.zig`): scheduling a request's job, collecting finished
//! jobs and cancelling a request's jobs. It belongs to the worker's VM
//! thread; only the jobs run on the pool's threads. Those threads start in
//! `init`, and the pool borrows the scheduler's wakeup eventfd, so
//! `Runtime.init` builds this domain after the scheduler and before seccomp,
//! and `Runtime.deinit` tears it down first, joining the threads before that
//! eventfd closes.

const std = @import("std");
const bindings = @import("collo_bindings");
const crypto_jobs = @import("../js/crypto/jobs.zig");
const crypto_runtime = @import("../js/crypto/runtime.zig");
const runtime_types = @import("types.zig");

pub const Crypto = struct {
    jobs: crypto_jobs.Pool,

    pub fn init(
        allocator: std.mem.Allocator,
        wakeup_fd: std.posix.fd_t,
        limits: runtime_types.RuntimeLimits,
    ) !Crypto {
        return .{
            .jobs = try crypto_jobs.Pool.init(allocator, wakeup_fd, .{
                .thread_count = limits.crypto_thread_count,
                .thread_stack_bytes = limits.crypto_thread_stack_bytes,
                .max_in_flight_per_request = limits.crypto_max_in_flight_per_request,
                .max_in_flight_per_worker = limits.crypto_max_in_flight_per_worker,
            }),
        };
    }

    pub fn deinit(self: *Crypto) void {
        self.jobs.deinit();
        self.* = undefined;
    }
};

pub fn Methods(comptime Runtime: type) type {
    return struct {
        pub fn scheduleCryptoJob(self: *Runtime, request_id: u64, job: *bindings.RawCryptoJob) !void {
            if (self.bootIdentityClosed(request_id))
                return error.CryptoJobOutsideActiveRequest;
            try crypto_runtime.scheduleJob(self, request_id, job);
        }

        pub fn collectCompletedCryptoJobs(self: *Runtime) !void {
            try crypto_runtime.collectCompleted(self);
        }

        pub fn cancelCryptoJobsForRequest(self: *Runtime, request_id: u64) void {
            crypto_runtime.cancelForRequest(self, request_id);
        }
    };
}

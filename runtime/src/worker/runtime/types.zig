//! The types a worker runtime is built from: the options the worker boot
//! hands `Runtime.init`, the per-worker limits WorkerInit carries, the
//! injectable clock, and a route's evaluated module. Plain data; the runtime
//! built from them runs on the worker's VM thread.

const std = @import("std");
const builtin = @import("builtin");
const ipc = @import("collo_ipc");
const process = @import("collo_os").process;
const js_value = @import("collo_worker_js").value;
const route_env = @import("../modules/route_env.zig");

/// A route whose module evaluated: its default export and the `env` object
/// every request of the route receives with it.
pub const RouteModule = struct {
    handler: js_value.JsFunctionOwned,
    env: js_value.JsObjectOwned,

    pub fn deinit(self: *RouteModule) void {
        self.handler.deinit();
        self.env.deinit();
        self.* = undefined;
    }
};

/// `ipc.WorkerRuntimeBootOptions`, which WorkerInit carries, is where the
/// limit defaults are set; this file only widens them to usize.
const wire_defaults = ipc.WorkerRuntimeBootOptions{};

pub const RuntimeLimits = struct {
    pub const max_crypto_thread_count: usize =
        ipc.WorkerRuntimeBootOptions.max_crypto_thread_count;
    pub const default_crypto_thread_count: usize =
        ipc.WorkerRuntimeBootOptions.default_crypto_thread_count;
    pub const default_crypto_max_in_flight_per_request: usize =
        ipc.WorkerRuntimeBootOptions.default_crypto_max_in_flight_per_request;

    /// Fetches one request may start, finished ones included; never above the
    /// fetch budget of the request's egress token
    /// (`runtime/tests/contracts/limits.zig`).
    max_fetches_per_request: usize = wire_defaults.max_fetches_per_request,
    /// Fetches the worker may have in flight at once.
    max_fetches_per_worker: usize = wire_defaults.max_fetches_per_worker,
    max_timers_per_worker: usize = wire_defaults.max_timers_per_worker,
    ready_queue_capacity: usize = wire_defaults.ready_queue_capacity,
    request_task_capacity: usize = wire_defaults.request_task_capacity,
    /// `default_crypto_thread_count` pool threads let concurrent requests make
    /// WebCrypto progress while keeping CPU ownership predictable for the JS
    /// event loop.
    crypto_thread_count: usize = default_crypto_thread_count,
    crypto_thread_stack_bytes: usize = wire_defaults.crypto_thread_stack_bytes,
    crypto_max_in_flight_per_request: usize = default_crypto_max_in_flight_per_request,
    /// 0 derives the worker's cap as `request_task_capacity` times
    /// `crypto_max_in_flight_per_request` (`resolveAutoRuntimeLimits`), the
    /// product the wire default already holds. The policy is then set by the
    /// thread count and the per-request cap alone.
    crypto_max_in_flight_per_worker: usize = 0,
};

/// Replaces each zero crypto limit with its default and a zero
/// `crypto_max_in_flight_per_worker` with the derived cap, and caps
/// `crypto_thread_count` at `max_crypto_thread_count`
/// (`resolveCryptoThreadCount`); the other limits pass through.
pub fn resolveAutoRuntimeLimits(base: RuntimeLimits) RuntimeLimits {
    var limits = base;
    limits.crypto_thread_count = resolveCryptoThreadCount(limits.crypto_thread_count);
    if (limits.crypto_thread_stack_bytes == 0)
        limits.crypto_thread_stack_bytes = wire_defaults.crypto_thread_stack_bytes;
    if (limits.crypto_max_in_flight_per_request == 0) {
        limits.crypto_max_in_flight_per_request =
            RuntimeLimits.default_crypto_max_in_flight_per_request;
    }
    if (limits.crypto_max_in_flight_per_worker == 0) {
        std.debug.assert(limits.request_task_capacity > 0);
        std.debug.assert(limits.crypto_max_in_flight_per_request > 0);
        const wire = ipc.WorkerRuntimeBootOptions{
            .request_task_capacity = limits.request_task_capacity,
            .crypto_max_in_flight_per_request = limits.crypto_max_in_flight_per_request,
        };
        limits.crypto_max_in_flight_per_worker = std.math.cast(
            usize,
            wire.deriveCryptoMaxInFlightPerWorker(),
        ) orelse std.math.maxInt(usize);
    }
    return limits;
}

/// 0 selects `default_crypto_thread_count`; any other value is capped at
/// `max_crypto_thread_count`.
pub fn resolveCryptoThreadCount(value: usize) usize {
    if (value != 0)
        return @min(value, RuntimeLimits.max_crypto_thread_count);
    return RuntimeLimits.default_crypto_thread_count;
}

pub const WorkerSchedulerMetrics = struct {
    worker_loop_ticks: u64 = 0,
    worker_ring_arm_calls: u64 = 0,
    worker_ring_sqe_submits: u64 = 0,
    worker_ring_submit_syscalls: u64 = 0,
    worker_ring_cqes: u64 = 0,
    timeout_rearms: u64 = 0,
    timeout_cancels: u64 = 0,
};

/// The runtime's clock in nanoseconds. `monotonic` reads CLOCK_MONOTONIC,
/// and 0 when the read fails; tests inject their own. The sentinel always
/// reads CLOCK_MONOTONIC, whatever clock the runtime has.
pub const Clock = struct {
    ctx: ?*anyopaque,
    now_fn: *const fn (?*anyopaque) u64,

    pub fn monotonic() Clock {
        return .{
            .ctx = null,
            .now_fn = monotonicNow,
        };
    }

    pub fn now(self: Clock) u64 {
        return self.now_fn(self.ctx);
    }
};

pub const RuntimeOptions = struct {
    clock: Clock = Clock.monotonic(),
    limits: RuntimeLimits = .{},
    memory_events_fd: ?std.posix.fd_t = null,
    trace_fd: ?std.posix.fd_t = null,
    /// Borrowed memfd; `Runtime.init` maps it and does not close it.
    ingress_payload_fd: ?std.posix.fd_t = null,
    /// Owned eventfd; `Runtime.init` closes it on failure or runtime teardown.
    ingress_payload_credit_eventfd: ?std.posix.fd_t = null,
    egress_shared_fds: ?*ipc.egress_shared.RawFds = null,
    /// The route's bindings blob (`worker/modules/route_env.zig`), borrowed
    /// for the runtime's whole life; the default holds no bindings.
    route_bindings_blob: []const u8 = &route_env.empty_blob,
    /// Entry specifier of the route `route_bindings_blob` belongs to,
    /// borrowed for the runtime's whole life: WorkerInit carries a route's
    /// entry and its bindings together. Only that route's `env` is built
    /// from a blob that holds bindings.
    route_bindings_route: []const u8 = "",
    trace_requests: bool = false,
    trace_all_requests: bool = false,
    /// Gives the first handler call the benchmark marker
    /// `__colloBenchHandlerEntered` (`invokeWithTiming` in `js/jsc/turn.zig`),
    /// which a fixture calls as its first statement, and publishes the
    /// CLOCK_MONOTONIC time of that call on the shared page
    /// (`publishBenchHandler`), 0 when the marker never ran. Later calls get
    /// no marker.
    bench_handler: bool = false,
    log_full_js_exceptions: bool = builtin.mode == .Debug,
};

/// Builds `RuntimeOptions` from what `Runtime.init` received: the struct
/// itself, a `Clock`, a struct with a clock's `ctx` and `now_fn`, or any
/// struct holding some of its fields, whose `limits` may hold some of
/// `RuntimeLimits`'s. Unset fields keep their defaults, and any other type
/// fails to compile.
pub fn coerceRuntimeOptions(options: anytype) RuntimeOptions {
    const Options = @TypeOf(options);
    if (Options == RuntimeOptions)
        return options;
    if (Options == Clock)
        return .{ .clock = options };
    if (comptime isRuntimeOptionsLike(Options)) {
        var resolved: RuntimeOptions = .{};
        if (comptime @hasField(Options, "clock")) {
            resolved.clock = options.clock;
        } else if (comptime isClockLike(Options)) {
            resolved.clock = .{ .ctx = options.ctx, .now_fn = options.now_fn };
        }

        inline for (std.meta.fields(RuntimeOptions)) |field| {
            if (comptime std.mem.eql(u8, field.name, "clock"))
                continue;
            if (comptime std.mem.eql(u8, field.name, "limits")) {
                if (comptime @hasField(Options, field.name))
                    resolved.limits = coerceRuntimeLimits(@field(options, field.name));
                continue;
            }
            if (comptime @hasField(Options, field.name))
                @field(resolved, field.name) = @field(options, field.name);
        }
        return resolved;
    }
    @compileError("Runtime init expects RuntimeOptions or Clock");
}

fn coerceRuntimeLimits(limits: anytype) RuntimeLimits {
    const Limits = @TypeOf(limits);
    if (Limits == RuntimeLimits)
        return limits;

    var resolved: RuntimeLimits = .{};
    inline for (std.meta.fields(RuntimeLimits)) |field| {
        if (comptime @hasField(Limits, field.name))
            @field(resolved, field.name) = @field(limits, field.name);
    }
    return resolved;
}

fn isRuntimeOptionsLike(comptime T: type) bool {
    if (comptime isClockLike(T))
        return true;
    inline for (std.meta.fields(RuntimeOptions)) |field| {
        if (comptime @hasField(T, field.name))
            return true;
    }
    return false;
}

fn isClockLike(comptime T: type) bool {
    comptime var has_ctx = false;
    comptime var has_now_fn = false;
    inline for (std.meta.fields(T)) |field| {
        if (comptime std.mem.eql(u8, field.name, "ctx"))
            has_ctx = true;
        if (comptime std.mem.eql(u8, field.name, "now_fn"))
            has_now_fn = true;
    }
    return has_ctx and has_now_fn;
}

fn monotonicNow(_: ?*anyopaque) u64 {
    return process.monotonicNowNsOrZero();
}

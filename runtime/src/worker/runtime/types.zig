//! The types a worker runtime is built from: the options the worker boot
//! hands `Runtime.init`, the limits it sizes its tables from, the injectable
//! clocks, and a route's evaluated module. Plain data; the runtime built
//! from them runs on the worker's VM thread.

const std = @import("std");
const ipc = @import("collo_ipc");
const worker_limits = @import("collo_limits").worker;
const process = @import("collo_os").process;
const js_value = @import("collo_worker_js").value;

/// A route whose module evaluated: its handler and the `env` object every
/// request of the route receives with it.
pub const RouteModule = struct {
    handler: RouteHandler,
    env: js_value.JsObjectOwned,

    pub fn deinit(self: *RouteModule) void {
        self.handler.deinit();
        self.env.deinit();
        self.* = undefined;
    }
};

/// The function a route calls for each request and the `this` it calls it
/// with, both read from the default export once, when the route's module
/// settles (`worker/modules/routes.zig`), and rooted for the worker's life,
/// so a later change to the default export never changes them.
pub const RouteHandler = struct {
    function: js_value.JsFunctionOwned,
    /// The default export when the handler is its `fetch`; null when the
    /// default export is itself the handler, which is then called with
    /// `this` undefined.
    receiver: ?js_value.JsObjectOwned,

    pub fn deinit(self: *RouteHandler) void {
        self.function.deinit();
        if (self.receiver) |*receiver|
            receiver.deinit();
        self.* = undefined;
    }
};

/// The capacities the runtime sizes its tables from. Every worker gets the
/// constants of `common/limits/worker.zig`, which are the defaults here; a
/// test sets smaller ones to reach a full table. The fetch caps are no
/// field: the egress files read them from `common/limits/worker.zig`.
pub const RuntimeLimits = struct {
    max_timers_per_worker: usize = worker_limits.timers_per_worker_max,
    ready_queue_capacity: usize = worker_limits.ready_queue_capacity,
    request_task_capacity: usize = worker_limits.request_task_capacity,
};

/// A clock in nanoseconds the runtime reads. `monotonic` reads
/// CLOCK_MONOTONIC and `threadCpu` the calling thread's
/// CLOCK_THREAD_CPUTIME_ID, each 0 when the read fails; tests inject their
/// own. The sentinel always reads CLOCK_MONOTONIC and the VM thread's kernel
/// CPU clock, whatever clocks the runtime has.
pub const Clock = struct {
    ctx: ?*anyopaque,
    now_fn: *const fn (?*anyopaque) u64,

    pub fn monotonic() Clock {
        return .{
            .ctx = null,
            .now_fn = monotonicNow,
        };
    }

    /// The CPU time of the thread that reads it. The runtime reads it only on
    /// the VM thread (`owner.zig`), where it measures that thread alone,
    /// whatever thread id glibc cached for it.
    pub fn threadCpu() Clock {
        return .{
            .ctx = null,
            .now_fn = threadCpuNow,
        };
    }

    pub fn now(self: Clock) u64 {
        return self.now_fn(self.ctx);
    }
};

pub const RuntimeOptions = struct {
    clock: Clock = Clock.monotonic(),
    /// The VM thread's CPU clock, which every owner window reads at its
    /// borders (`owner.zig`).
    cpu_clock: Clock = Clock.threadCpu(),
    limits: RuntimeLimits = .{},
    memory_events_fd: ?std.posix.fd_t = null,
    /// Borrowed memfd; `Runtime.init` maps it and does not close it.
    ingress_payload_fd: ?std.posix.fd_t = null,
    /// Owned eventfd; `Runtime.init` closes it on failure or runtime teardown.
    ingress_payload_credit_eventfd: ?std.posix.fd_t = null,
    /// WorkerInit's egress descriptors, which `Runtime.init` takes once they
    /// check out; null or empty for a worker whose definition grants no
    /// network access (`egress/state.zig:State.grant`).
    egress_shared_fds: ?*ipc.egress_shared.RawFds = null,
    /// Each route but the first runs in a realm of its own
    /// (`WorkerInit.flag_isolate_realm`); false runs every route in the VM's
    /// main realm.
    isolate_realm: bool = false,
    /// WorkerInit's boot token, which every evaluation copies so that module
    /// top-level code fetches under it (`evaluations.zig`). With
    /// `egress_token.none`, the default, the worker refuses those fetches
    /// before they leave (`fetch_runtime.refusal`).
    boot_egress_token: ipc.egress_token.Bytes = ipc.egress_token.none,
    /// The CPU budget of each request, `WorkerInit.request_cpu_budget_ns`; 0
    /// sets none (`runtime/owner.zig`).
    request_cpu_budget_ns: u64 = 0,
    /// The wall-clock limit of each stretch of JavaScript the worker owner
    /// runs, `WorkerInit.unowned_time_limit_ns`; never 0.
    unowned_time_limit_ns: u64 = ipc.WorkerInit.default_unowned_time_limit_ns,
    /// Gives the first handler call the benchmark marker
    /// `__colloBenchHandlerEntered` (`invokeWithTiming` in `js/jsc/turn.zig`),
    /// which a fixture calls as its first statement, and publishes the
    /// CLOCK_MONOTONIC time of that call on the shared page
    /// (`publishBenchHandler`), 0 when the marker never ran. Later calls get
    /// no marker.
    bench_handler: bool = false,
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

fn threadCpuNow(_: ?*anyopaque) u64 {
    const ts = std.posix.clock_gettime(std.posix.CLOCK.THREAD_CPUTIME_ID) catch return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn monotonicNow(_: ?*anyopaque) u64 {
    return process.monotonicNowNsOrZero();
}

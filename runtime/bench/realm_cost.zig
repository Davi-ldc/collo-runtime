//! Measures what a realm costs a forked worker, the number the design of
//! multi-route workers rests on: whether a worker creates its routes' realms
//! after the fork or the zygote prewarms empty ones that workers inherit.
//!
//! The bench process forks one process per mode to play the zygote. It
//! creates a zygote VM with the Web APIs, runs the warmup corpus and a full
//! GC as `prepareZygoteAtBoot` does, and in the `prewarmed` mode also creates
//! the most realms any case uses, then prepares for the fork. Per realm
//! count, it forks one plain child, with no cgroup, namespaces or sandbox,
//! which plays a worker that boots that many routes: it takes its realms,
//! created after the fork in the `fresh` mode and inherited in the
//! `prewarmed` one, evaluates one route module in each and calls its handler
//! once, then runs a full GC with trim. The zygote reads the child's
//! `/proc/<pid>/smaps_rollup` after each stage, while the child waits on a
//! pipe for the release to the next one, so no reading races the child.
//!
//! The realm counts come from `COLLO_REALM_COST_COUNTS` (default 1,4,16) and
//! the modes from `COLLO_REALM_COST_MODES` (default fresh,prewarmed). Every
//! line it prints starts with `realm_cost`.

const std = @import("std");
const bindings = @import("collo_bindings");
const ipc = @import("collo_ipc");
const os = @import("collo_os");
const zygote_mod = @import("collo_zygote");
const worker_api = @import("collo_worker");
const bench_common = @import("common.zig");
const bench_metadata = @import("metadata.zig");
const proc_memory = @import("proc_memory.zig");

// The engine bridge calls the `collo_runtime_*` functions that the worker
// module exports. Referencing the module makes Zig analyze it, so those
// exports exist when the bench links against the bridge.
comptime {
    _ = worker_api;
}

// The values of PREFORK_HELPER_THREAD_IDLE_TIMEOUT_NS,
// PREFORK_DRAIN_MAX_CHECKS and PREFORK_DRAIN_CHECK_INTERVAL_NS in
// zygote/fork_loop.zig, so JSC helper threads retire and the process proves
// single-threaded before a fork.
const fork_helper_timeout_ns: u64 = std.time.ns_per_ms;
const fork_drain_max_checks: u32 = 50;
const fork_drain_check_interval_ns: u64 = std.time.ns_per_ms;

const route_specifier = "/realm-cost/route.js";
// A route the size of a small handler that, on its first request, touches the
// Web APIs a handler commonly does, so the realm builds the lazy structures a
// served route needs.
const route_source =
    \\const greeting = "hello from " + import.meta.url;
    \\export default async function handler(request) {
    \\    const url = new URL(request);
    \\    const headers = new Headers({ "content-type": "text/plain" });
    \\    const bytes = new TextEncoder().encode(greeting + url.pathname);
    \\    const response = new Response(bytes, { headers });
    \\    return JSON.stringify({ status: response.status, length: bytes.length });
    \\}
;

const Mode = enum { fresh, prewarmed };

const Stage = enum(u8) {
    idle = 1,
    realms_ready = 2,
    routes_served = 3,
    gc_trimmed = 4,
};

const ChildMessage = extern struct {
    stage: Stage,
    reserved: [7]u8 = .{0} ** 7,
    /// Wall and thread-CPU time of the stage's own work in the child.
    wall_ns: u64 = 0,
    cpu_ns: u64 = 0,
};

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    try bench_metadata.print(allocator, "realm_cost");

    const counts = try bench_common.parseCommaSeparatedUsizeList(allocator, "COLLO_REALM_COST_COUNTS", &.{ 1, 4, 16 });
    defer allocator.free(counts);

    for ([_]Mode{ .fresh, .prewarmed }) |mode| {
        if (!try modeSelected(allocator, mode))
            continue;
        const pid = try std.posix.fork();
        if (pid == 0) {
            runZygote(std.heap.c_allocator, mode, counts) catch |err| {
                std.debug.print("realm_cost_error mode={s} error={s}\n", .{ @tagName(mode), @errorName(err) });
                std.posix.exit(1);
            };
            std.posix.exit(0);
        }
        try expectChildExit(pid);
    }
}

fn runZygote(allocator: std.mem.Allocator, mode: Mode, counts: []const usize) !void {
    try bindings.setHelperThreadsTimeoutOverrideNs(fork_helper_timeout_ns);
    defer bindings.clearHelperThreadsTimeoutOverride();
    try bindings.prepareProcessForFork();

    var zygote = try zygote_mod.state.Zygote.init(null, .{ .vm_options = bindings.VmOptions.init() });
    defer zygote.deinit();
    try zygote_mod.warmup.runCorpus(&zygote.vm);
    try zygote.vm.collectFullGCAndTrim();

    const self_pid: u32 = @intCast(std.c.getpid());
    const before_prewarm = try proc_memory.readProcess(allocator, self_pid);

    var max_count: usize = 0;
    for (counts) |count| max_count = @max(max_count, count);
    const prewarmed = try allocator.alloc(bindings.Realm, if (mode == .prewarmed) max_count else 0);
    defer allocator.free(prewarmed);
    if (mode == .prewarmed) {
        const started = Clock.now();
        for (prewarmed) |*realm|
            realm.* = try zygote.vm.createRealm();
        const elapsed = started.elapsed();
        try zygote.vm.collectFullGCAndTrim();
        const after_prewarm = try proc_memory.readProcess(allocator, self_pid);
        std.debug.print(
            "realm_cost mode=prewarmed process=zygote realms={d} create_wall_ns={d} create_cpu_ns={d} private_dirty_delta_kib={d} pss_delta_kib={d}\n",
            .{
                max_count,
                elapsed.wall_ns,
                elapsed.cpu_ns,
                signedDelta(before_prewarm.private_dirty_kib, after_prewarm.private_dirty_kib),
                signedDelta(before_prewarm.pss_kib, after_prewarm.pss_kib),
            },
        );
    }

    // The route module is registered before the fork, as a worker registers
    // its definition's pack before its routes evaluate, so every child maps
    // the same sources and only the per-realm work differs.
    const pack = try ipc.module_pack.buildSingleAlloc(allocator, route_specifier, route_source);
    defer allocator.free(pack);
    try zygote.vm.registerModulePack(pack);

    try zygote.vm.prepareForFork();
    std.Thread.sleep(fork_helper_timeout_ns);
    try os.process.waitForSingleThreadedSelf(fork_drain_max_checks, fork_drain_check_interval_ns);
    // The engine reserves its heaps with MADV_DONTFORK, which the zygote
    // undoes before its first fork (`prepareZygoteAtBoot`).
    _ = try os.process.makeAddressSpaceForkInheritable();

    for (counts) |count|
        try runChild(allocator, &zygote.vm, mode, count, prewarmed[0..if (mode == .prewarmed) count else 0]);
}

fn runChild(
    allocator: std.mem.Allocator,
    vm: *bindings.Vm,
    mode: Mode,
    count: usize,
    prewarmed: []const bindings.Realm,
) !void {
    try os.process.waitForSingleThreadedSelf(fork_drain_max_checks, fork_drain_check_interval_ns);
    const to_parent = try std.posix.pipe2(.{ .CLOEXEC = true });
    const to_child = try std.posix.pipe2(.{ .CLOEXEC = true });

    const pid = try std.posix.fork();
    if (pid == 0) {
        std.posix.close(to_parent[0]);
        std.posix.close(to_child[1]);
        childMain(vm, mode, count, prewarmed, to_parent[1], to_child[0]) catch |err| {
            std.debug.print("realm_cost_child_error error={s}\n", .{@errorName(err)});
            std.posix.exit(1);
        };
        std.posix.exit(0);
    }
    std.posix.close(to_parent[1]);
    std.posix.close(to_child[0]);
    defer std.posix.close(to_parent[0]);
    defer std.posix.close(to_child[1]);

    const child_pid: u32 = @intCast(pid);
    var previous: ?proc_memory.Metrics = null;
    for ([_]Stage{ .idle, .realms_ready, .routes_served, .gc_trimmed }) |expected| {
        var message: ChildMessage = undefined;
        try readExact(to_parent[0], std.mem.asBytes(&message));
        if (message.stage != expected)
            return error.UnexpectedChildStage;
        const metrics = try proc_memory.readProcess(allocator, child_pid);
        const base = previous orelse metrics;
        std.debug.print(
            "realm_cost mode={s} realms={d} stage={s} wall_ns={d} cpu_ns={d} private_dirty_kib={d} pss_kib={d} rss_kib={d} private_dirty_delta_kib={d} private_dirty_delta_per_realm_kib={d}\n",
            .{
                @tagName(mode),
                count,
                @tagName(expected),
                message.wall_ns,
                message.cpu_ns,
                metrics.private_dirty_kib,
                metrics.pss_kib,
                metrics.rss_kib,
                signedDelta(base.private_dirty_kib, metrics.private_dirty_kib),
                @divTrunc(signedDelta(base.private_dirty_kib, metrics.private_dirty_kib), @as(i64, @intCast(count))),
            },
        );
        previous = metrics;
        try writeAll(to_child[1], &.{1});
    }
    try expectChildExit(pid);
}

fn childMain(
    vm: *bindings.Vm,
    mode: Mode,
    count: usize,
    prewarmed: []const bindings.Realm,
    to_parent: std.posix.fd_t,
    to_child: std.posix.fd_t,
) !void {
    try vm.postForkChild();
    var seeds: bindings.RandomSeeds = undefined;
    try std.posix.getrandom(std.mem.asBytes(&seeds));
    try vm.reseedAfterFork(seeds);
    try report(to_parent, to_child, .{ .stage = .idle });

    var realms: [64]bindings.Realm = undefined;
    if (count > realms.len)
        return error.TooManyRealms;
    var started = Clock.now();
    for (realms[0..count], 0..) |*realm, index|
        realm.* = switch (mode) {
            .fresh => try vm.createRealm(),
            .prewarmed => prewarmed[index],
        };
    var elapsed = started.elapsed();
    try report(to_parent, to_child, .{ .stage = .realms_ready, .wall_ns = elapsed.wall_ns, .cpu_ns = elapsed.cpu_ns });

    started = Clock.now();
    for (realms[0..count], 0..) |realm, index|
        try serveRoute(vm, realm, index);
    elapsed = started.elapsed();
    try report(to_parent, to_child, .{ .stage = .routes_served, .wall_ns = elapsed.wall_ns, .cpu_ns = elapsed.cpu_ns });

    started = Clock.now();
    try vm.collectFullGCAndTrim();
    elapsed = started.elapsed();
    try report(to_parent, to_child, .{ .stage = .gc_trimmed, .wall_ns = elapsed.wall_ns, .cpu_ns = elapsed.cpu_ns });
}

/// Evaluates the route module in `realm` and calls its handler once in a
/// turn, as a worker's boot and the route's first request do.
fn serveRoute(vm: *bindings.Vm, realm: bindings.Realm, index: usize) !void {
    switch (try realm.evaluateModule(route_specifier)) {
        .success => {},
        .exception, .unsupported => |exception| {
            var owned = exception;
            owned.deinit();
            return error.RouteEvaluationFailed;
        },
        .pending => return error.RouteEvaluationPending,
    }
    var handler = switch (try realm.moduleGetExport(route_specifier, "default")) {
        .success => |value| value,
        .exception => |exception| {
            var owned = exception;
            owned.deinit();
            return error.RouteExportFailed;
        },
    };
    defer handler.deinit();
    var url = try vm.stringValueUtf8("https://realm-cost.test/route");
    defer url.deinit();

    var exec_ctx = bindings.ExecCtx.init(1000 + index);
    defer vm.releaseExecCtx(&exec_ctx) catch {};
    try vm.turnEnter(&exec_ctx);
    const invoke_result = vm.invoke(std.heap.c_allocator, &exec_ctx, &handler, null, &.{&url});
    const exit_result = vm.turnExitResult();
    const called = releaseValueResult(invoke_result);
    const drained = releaseVoidResult(exit_result);
    if (!called or !drained)
        return error.RouteHandlerFailed;
}

/// Releases what `result` holds; true for a success.
fn releaseValueResult(result: bindings.Error!bindings.ValueResult) bool {
    var outcome = result catch return false;
    switch (outcome) {
        .success => |*value| {
            value.deinit();
            return true;
        },
        .exception => |*exception| {
            exception.deinit();
            return false;
        },
    }
}

fn releaseVoidResult(result: bindings.Error!bindings.VoidResult) bool {
    var outcome = result catch return false;
    switch (outcome) {
        .success => return true,
        .exception => |*exception| {
            exception.deinit();
            return false;
        },
    }
}

const Clock = struct {
    wall_ns: u64,
    cpu_ns: u64,

    const Elapsed = struct { wall_ns: u64, cpu_ns: u64 };

    fn now() Clock {
        return .{ .wall_ns = readClock(.MONOTONIC), .cpu_ns = readClock(.THREAD_CPUTIME_ID) };
    }

    fn elapsed(self: Clock) Elapsed {
        const later = now();
        return .{ .wall_ns = later.wall_ns - self.wall_ns, .cpu_ns = later.cpu_ns - self.cpu_ns };
    }

    fn readClock(id: std.posix.clockid_t) u64 {
        const ts = std.posix.clock_gettime(id) catch return 0;
        return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
    }
};

fn report(to_parent: std.posix.fd_t, to_child: std.posix.fd_t, message: ChildMessage) !void {
    try writeAll(to_parent, std.mem.asBytes(&message));
    var release: [1]u8 = undefined;
    try readExact(to_child, &release);
}

fn signedDelta(before: u64, after: u64) i64 {
    return @as(i64, @intCast(after)) - @as(i64, @intCast(before));
}

fn modeSelected(allocator: std.mem.Allocator, mode: Mode) !bool {
    const value = std.process.getEnvVarOwned(allocator, "COLLO_REALM_COST_MODES") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return true,
        else => return err,
    };
    defer allocator.free(value);
    var parts = std.mem.splitScalar(u8, value, ',');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, std.mem.trim(u8, part, " \t\r\n"), @tagName(mode)))
            return true;
    }
    return false;
}

fn readExact(fd: std.posix.fd_t, buffer: []u8) !void {
    var filled: usize = 0;
    while (filled < buffer.len) {
        const read = try std.posix.read(fd, buffer[filled..]);
        if (read == 0)
            return error.UnexpectedEndOfStream;
        filled += read;
    }
}

fn writeAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len)
        written += try std.posix.write(fd, bytes[written..]);
}

fn expectChildExit(pid: std.posix.pid_t) !void {
    const result = std.posix.waitpid(pid, 0);
    if (!std.c.W.IFEXITED(result.status) or std.c.W.EXITSTATUS(result.status) != 0)
        return error.ChildFailed;
}

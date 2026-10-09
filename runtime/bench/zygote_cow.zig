//! Measures how much of a zygote's memory its forked children keep sharing,
//! with and without the Web API object graph installed and with and without
//! the warmup corpus. The bench process forks one process per variant to
//! play the zygote. That process creates a zygote VM, runs the boot steps of
//! `prepareZygoteAtBoot` in zygote/fork_loop.zig up to the single-thread
//! check, then forks one plain child per workload and call count, with no
//! cgroup, namespaces or sandbox. The workloads are pure JavaScript and
//! touch no Web API, so between variants with the same warmup the only
//! difference is the Web API graph the zygote installed before forking.
//!
//! The zygote reads the child's `/proc/<pid>/smaps` at each stage (idle after
//! the fork, after module evaluation, after the calls, after a full GC with
//! trim) and its own at some of them. The child waits for a one-byte release
//! on a pipe before each next stage, and the zygote writes it only after
//! sampling, so no reading races the child. The zygote must be
//! single-threaded whenever it forks, which `waitForSingleThreadedSelf`
//! checks before every fork.

const std = @import("std");
const bindings = @import("collo_bindings");
const ipc = @import("collo_ipc");
const os = @import("collo_os");
const zygote_mod = @import("collo_zygote");
const worker_api = @import("collo_worker");
const bench_common = @import("common.zig");
const bench_metadata = @import("metadata.zig");

// The engine bridge calls the `collo_runtime_*` functions that the worker
// module exports. Referencing the module makes Zig analyze it, so those
// exports exist when the bench links against the bridge.
comptime {
    _ = worker_api;
}

const child_idle_stage: u8 = 1;
const child_module_ready_stage: u8 = 2;
const child_calls_done_stage: u8 = 3;
const child_gc_trim_done_stage: u8 = 4;
const default_iterations_per_call: u32 = 100;
// The same values as PREFORK_HELPER_THREAD_IDLE_TIMEOUT_NS,
// PREFORK_DRAIN_MAX_CHECKS and PREFORK_DRAIN_CHECK_INTERVAL_NS in
// zygote/fork_loop.zig, so JSC helper threads retire and the process proves
// single-threaded before a fork.
const fork_helper_timeout_ns: u64 = std.time.ns_per_ms;
const fork_drain_max_checks: u32 = 50;
const fork_drain_check_interval_ns: u64 = std.time.ns_per_ms;

const prelude_source = @embedFile("workload_prelude_js");
const trailer_source = @embedFile("workload_trailer_js");

const Variant = struct {
    name: []const u8,
    vm_options: bindings.VmOptions,
    /// Runs the zygote warmup corpus and a full GC before prepareForFork, as
    /// the zygote does when `ZygoteOptions.warmup_corpus` is set.
    warmup: bool = false,
};

const Workload = struct {
    name: []const u8,
    source: []const u8,
};

const PreparedWorkload = struct {
    entry: bindings.Value,

    fn deinit(self: *PreparedWorkload) void {
        self.entry.deinit();
    }
};

const ChildMessage = extern struct {
    stage: u8,
    reserved: [7]u8,
    digest: u64,
    // Together the two spans approximate a first request: module eval covers
    // registering and evaluating the workload module, and invoke covers the
    // calls for this case.
    module_eval_cpu_ns: u64 = 0,
    module_eval_wall_ns: u64 = 0,
    invoke_cpu_ns: u64 = 0,
    invoke_wall_ns: u64 = 0,
};

const Totals = struct {
    rss_kib: u64 = 0,
    pss_kib: u64 = 0,
    private_clean_kib: u64 = 0,
    private_dirty_kib: u64 = 0,
    shared_clean_kib: u64 = 0,
    shared_dirty_kib: u64 = 0,

    fn add(self: *Totals, other: Totals) void {
        self.rss_kib += other.rss_kib;
        self.pss_kib += other.pss_kib;
        self.private_clean_kib += other.private_clean_kib;
        self.private_dirty_kib += other.private_dirty_kib;
        self.shared_clean_kib += other.shared_clean_kib;
        self.shared_dirty_kib += other.shared_dirty_kib;
    }
};

const Category = enum(u8) {
    heap,
    stack,
    anonymous,
    anonymous_named,
    anonymous_executable_jit,
    collo_executable,
    jsc_file,
    icu_file,
    stdlib_file,
    libc_file,
    kernel_mapping,
    file_other,
};

const category_count = 12;

const Snapshot = struct {
    total: Totals = .{},
    categories: [category_count]Totals = .{Totals{}} ** category_count,

    fn category(self: Snapshot, wanted: Category) Totals {
        return self.categories[@intFromEnum(wanted)];
    }

    /// Anonymous pages the zygote wrote before the fork and the child still
    /// shares. The kernel counts a dirty page as Shared_Dirty while more
    /// than one process maps it; the child's first write copies the page
    /// and moves it to Private_Dirty.
    fn anonymousCowSharedDirtyKib(self: Snapshot) u64 {
        return self.category(.heap).shared_dirty_kib +
            self.category(.anonymous).shared_dirty_kib +
            self.category(.anonymous_named).shared_dirty_kib +
            self.category(.anonymous_executable_jit).shared_dirty_kib;
    }

    fn anonymousPrivateDirtyKib(self: Snapshot) u64 {
        return self.category(.heap).private_dirty_kib +
            self.category(.anonymous).private_dirty_kib +
            self.category(.anonymous_named).private_dirty_kib +
            self.category(.anonymous_executable_jit).private_dirty_kib;
    }

    fn anonymousCowRetainedPercent(self: Snapshot) u64 {
        const shared_dirty = self.anonymousCowSharedDirtyKib();
        const private_dirty = self.anonymousPrivateDirtyKib();
        const total = shared_dirty + private_dirty;
        if (total == 0)
            return 0;
        return (shared_dirty * 100) / total;
    }
};

const variants = [_]Variant{
    .{ .name = "webapis_installed", .vm_options = bindings.VmOptions.init() },
    .{ .name = "webapis_installed_warmup", .vm_options = bindings.VmOptions.init(), .warmup = true },
    .{ .name = "webapis_disabled", .vm_options = bindings.VmOptions.withoutWebApis() },
    .{ .name = "webapis_disabled_warmup", .vm_options = bindings.VmOptions.withoutWebApis(), .warmup = true },
};

const workloads = [_]Workload{
    .{ .name = "chacha", .source = @embedFile("workload_chacha_js") },
    .{ .name = "hmac_sha256", .source = @embedFile("workload_hmac_sha256_js") },
    .{ .name = "ssr", .source = @embedFile("workload_ssr_js") },
    .{ .name = "json_scan", .source = @embedFile("workload_json_scan_js") },
    .{ .name = "regex_router", .source = @embedFile("workload_regex_router_js") },
    .{ .name = "array_ops", .source = @embedFile("workload_array_ops_js") },
    // Each of these breaks copy-on-write sharing in its own way, beyond the
    // steady-state kernels above: heap growth that never shrinks, JSON
    // allocation, Structure churn, and tier-up across many functions.
    .{ .name = "growing_cache", .source = @embedFile("workload_growing_cache_js") },
    .{ .name = "json_roundtrip", .source = @embedFile("workload_json_roundtrip_js") },
    .{ .name = "shape_churn", .source = @embedFile("workload_shape_churn_js") },
    .{ .name = "many_functions", .source = @embedFile("workload_many_functions_js") },
    // Uses Intl on the hot path, which checks the corpus's `warmIntl` step:
    // with warmup a child inherits the Intl structures shared, without it
    // the child builds them in private pages.
    .{ .name = "intl_format", .source = @embedFile("workload_intl_format_js") },
};

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    try bench_metadata.print(allocator, "zygote_cow");

    const call_counts = try bench_common.parseCommaSeparatedUsizeList(
        allocator,
        "COLLO_ZYGOTE_COW_CALL_COUNTS",
        &.{ 1, 100, 1000 },
    );
    defer allocator.free(call_counts);
    const iterations_per_call = try configuredIterationsPerCall(allocator);

    for (variants) |variant| {
        if (!try selectedByEnv(allocator, "COLLO_ZYGOTE_COW_VARIANTS", variant.name))
            continue;
        try runVariantProcess(variant, call_counts, iterations_per_call);
    }
}

fn runVariantProcess(
    variant: Variant,
    call_counts: []const usize,
    iterations_per_call: u32,
) !void {
    const raw_pid = try std.posix.fork();
    if (raw_pid == 0) {
        runVariant(std.heap.c_allocator, variant, call_counts, iterations_per_call) catch |err| {
            writeChildError(err);
            std.posix.exit(1);
        };
        std.posix.exit(0);
    }
    try expectChildExit(@intCast(raw_pid));
}

fn runVariant(
    allocator: std.mem.Allocator,
    variant: Variant,
    call_counts: []const usize,
    iterations_per_call: u32,
) !void {
    try bindings.setHelperThreadsTimeoutOverrideNs(fork_helper_timeout_ns);
    defer bindings.clearHelperThreadsTimeoutOverride();
    try bindings.prepareProcessForFork();

    const self_pid: u32 = @intCast(std.c.getpid());
    const parent_before_create = try readSnapshot(allocator, self_pid);
    printMetric(variant.name, "zygote", "parent_before_create", 0, self_pid, parent_before_create);

    var zygote = try zygote_mod.state.Zygote.init(null, .{
        .vm_options = variant.vm_options,
    });
    defer zygote.deinit();

    const parent_after_create = try readSnapshot(allocator, self_pid);
    printMetric(variant.name, "zygote", "parent_after_create", 0, self_pid, parent_after_create);
    printDelta(
        variant.name,
        "zygote",
        "parent_create_delta",
        0,
        parent_before_create,
        parent_after_create,
    );
    printCategoryDeltas(
        variant.name,
        "zygote",
        "parent_create_delta",
        0,
        parent_before_create,
        parent_after_create,
    );

    if (variant.warmup) {
        try zygote_mod.warmup.runCorpus(&zygote.vm);
        try zygote.vm.collectFullGCAndTrim();
        const parent_after_warmup = try readSnapshot(allocator, self_pid);
        printMetric(variant.name, "zygote", "parent_after_warmup", 0, self_pid, parent_after_warmup);
        printDelta(
            variant.name,
            "zygote",
            "parent_warmup_delta",
            0,
            parent_after_create,
            parent_after_warmup,
        );
        printCategoryDeltas(
            variant.name,
            "zygote",
            "parent_warmup_delta",
            0,
            parent_after_create,
            parent_after_warmup,
        );
    }

    try zygote.vm.prepareForFork();
    std.Thread.sleep(fork_helper_timeout_ns);
    try os.process.waitForSingleThreadedSelf(fork_drain_max_checks, fork_drain_check_interval_ns);
    // The engine reserves its heaps with MADV_DONTFORK, which the zygote
    // undoes before its first fork (`prepareZygoteAtBoot`); without this a
    // child faults on the first cell it touches.
    _ = try os.process.makeAddressSpaceForkInheritable();
    zygote.prepared_for_fork = true;
    zygote.prepare_count += 1;

    const parent_after_prepare = try readSnapshot(allocator, self_pid);
    printMetric(variant.name, "zygote", "parent_after_prepare", 0, self_pid, parent_after_prepare);
    printDelta(variant.name, "zygote", "parent_prepare_delta", 0, parent_after_create, parent_after_prepare);
    printCategoryDeltas(variant.name, "zygote", "parent_prepare_delta", 0, parent_after_create, parent_after_prepare);
    printDelta(
        variant.name,
        "zygote",
        "parent_prepared_total_delta",
        0,
        parent_before_create,
        parent_after_prepare,
    );
    printCategoryDeltas(
        variant.name,
        "zygote",
        "parent_prepared_total_delta",
        0,
        parent_before_create,
        parent_after_prepare,
    );

    for (workloads) |workload| {
        if (!try selectedByEnv(allocator, "COLLO_ZYGOTE_COW_WORKLOADS", workload.name))
            continue;
        for (call_counts) |call_count| {
            try runForkedCase(
                allocator,
                &zygote.vm,
                variant.name,
                workload,
                call_count,
                iterations_per_call,
            );
        }
    }
}

fn runForkedCase(
    allocator: std.mem.Allocator,
    vm: *bindings.Vm,
    variant_name: []const u8,
    workload: Workload,
    call_count: usize,
    iterations_per_call: u32,
) !void {
    try os.process.waitForSingleThreadedSelf(fork_drain_max_checks, fork_drain_check_interval_ns);

    const child_to_parent = try std.posix.pipe2(.{ .CLOEXEC = true });
    var child_read_fd: ?std.posix.fd_t = child_to_parent[0];
    var child_write_fd: ?std.posix.fd_t = child_to_parent[1];
    errdefer {
        if (child_read_fd) |fd|
            std.posix.close(fd);
        if (child_write_fd) |fd|
            std.posix.close(fd);
    }

    const parent_to_child = try std.posix.pipe2(.{ .CLOEXEC = true });
    var parent_read_fd: ?std.posix.fd_t = parent_to_child[0];
    var parent_write_fd: ?std.posix.fd_t = parent_to_child[1];
    errdefer {
        if (parent_read_fd) |fd|
            std.posix.close(fd);
        if (parent_write_fd) |fd|
            std.posix.close(fd);
    }

    const parent_pid: u32 = @intCast(std.c.getpid());
    const parent_before_fork = try readSnapshot(allocator, parent_pid);
    printMetric(
        variant_name,
        workload.name,
        "parent_before_fork",
        call_count,
        parent_pid,
        parent_before_fork,
    );

    const raw_child_pid = try std.posix.fork();
    if (raw_child_pid == 0) {
        std.posix.close(child_to_parent[0]);
        std.posix.close(parent_to_child[1]);
        childMain(
            vm,
            child_to_parent[1],
            parent_to_child[0],
            workload,
            call_count,
            iterations_per_call,
        );
    }

    std.posix.close(child_to_parent[1]);
    child_write_fd = null;
    std.posix.close(parent_to_child[0]);
    parent_read_fd = null;

    const child_pid: u32 = @intCast(raw_child_pid);
    const idle = try readChildMessageForChild(child_to_parent[0], child_pid);
    if (idle.stage != child_idle_stage)
        return error.InvalidChildMessage;
    const child_idle = try readSnapshot(allocator, child_pid);
    const parent_while_child_idle = try readSnapshot(allocator, parent_pid);
    printMetric(variant_name, workload.name, "child_after_fork_idle", call_count, child_pid, child_idle);
    printMetric(
        variant_name,
        workload.name,
        "parent_while_child_idle",
        call_count,
        parent_pid,
        parent_while_child_idle,
    );

    try writeRelease(parent_to_child[1]);

    const module_ready = try readChildMessageForChild(child_to_parent[0], child_pid);
    if (module_ready.stage != child_module_ready_stage)
        return error.InvalidChildMessage;
    const child_module_ready = try readSnapshot(allocator, child_pid);
    printMetric(
        variant_name,
        workload.name,
        "child_after_module_eval",
        call_count,
        child_pid,
        child_module_ready,
    );
    printDelta(
        variant_name,
        workload.name,
        "child_module_eval_delta",
        call_count,
        child_idle,
        child_module_ready,
    );
    printCategoryDeltas(
        variant_name,
        workload.name,
        "child_module_eval_delta",
        call_count,
        child_idle,
        child_module_ready,
    );
    printCowBreakdown(
        variant_name,
        workload.name,
        "child_module_eval_cow",
        call_count,
        child_idle,
        child_module_ready,
    );

    try writeRelease(parent_to_child[1]);

    const calls_done = try readChildMessageForChild(child_to_parent[0], child_pid);
    if (calls_done.stage != child_calls_done_stage)
        return error.InvalidChildMessage;
    const child_after_calls = try readSnapshot(allocator, child_pid);
    const parent_while_child_calls = try readSnapshot(allocator, parent_pid);
    printMetric(
        variant_name,
        workload.name,
        "child_after_calls",
        call_count,
        child_pid,
        child_after_calls,
    );
    printMetric(
        variant_name,
        workload.name,
        "parent_while_child_calls",
        call_count,
        parent_pid,
        parent_while_child_calls,
    );
    printDelta(
        variant_name,
        workload.name,
        "child_calls_delta",
        call_count,
        child_module_ready,
        child_after_calls,
    );
    printCategoryDeltas(
        variant_name,
        workload.name,
        "child_calls_delta",
        call_count,
        child_module_ready,
        child_after_calls,
    );
    printDelta(
        variant_name,
        workload.name,
        "child_calls_total_delta",
        call_count,
        child_idle,
        child_after_calls,
    );
    printCategoryDeltas(
        variant_name,
        workload.name,
        "child_calls_total_delta",
        call_count,
        child_idle,
        child_after_calls,
    );
    printCowBreakdown(
        variant_name,
        workload.name,
        "child_calls_cow",
        call_count,
        child_idle,
        child_after_calls,
    );
    printTiming(variant_name, workload.name, call_count, calls_done);
    printResult(variant_name, workload.name, call_count, calls_done.digest, child_after_calls);

    try writeRelease(parent_to_child[1]);

    const gc_trim_done = try readChildMessageForChild(child_to_parent[0], child_pid);
    if (gc_trim_done.stage != child_gc_trim_done_stage)
        return error.InvalidChildMessage;
    const child_after_gc_trim = try readSnapshot(allocator, child_pid);
    printMetric(
        variant_name,
        workload.name,
        "child_after_full_gc_trim",
        call_count,
        child_pid,
        child_after_gc_trim,
    );
    printDelta(
        variant_name,
        workload.name,
        "child_full_gc_trim_delta",
        call_count,
        child_after_calls,
        child_after_gc_trim,
    );
    printCategoryDeltas(
        variant_name,
        workload.name,
        "child_full_gc_trim_delta",
        call_count,
        child_after_calls,
        child_after_gc_trim,
    );
    printDelta(
        variant_name,
        workload.name,
        "child_retained_total_delta",
        call_count,
        child_idle,
        child_after_gc_trim,
    );
    printCategoryDeltas(
        variant_name,
        workload.name,
        "child_retained_total_delta",
        call_count,
        child_idle,
        child_after_gc_trim,
    );
    printCowBreakdown(
        variant_name,
        workload.name,
        "child_retained_cow",
        call_count,
        child_idle,
        child_after_gc_trim,
    );
    printRetainedResult(
        variant_name,
        workload.name,
        call_count,
        gc_trim_done.digest,
        child_idle,
        child_after_gc_trim,
    );

    try writeRelease(parent_to_child[1]);
    std.posix.close(child_to_parent[0]);
    child_read_fd = null;
    std.posix.close(parent_to_child[1]);
    parent_write_fd = null;
    try expectChildExit(child_pid);
}

fn childMain(
    vm: *bindings.Vm,
    child_to_parent_fd: std.posix.fd_t,
    parent_to_child_fd: std.posix.fd_t,
    workload: Workload,
    call_count: usize,
    iterations_per_call: u32,
) noreturn {
    childMainImpl(
        vm,
        child_to_parent_fd,
        parent_to_child_fd,
        workload,
        call_count,
        iterations_per_call,
    ) catch |err| {
        writeChildError(err);
        std.posix.exit(1);
    };
    std.posix.exit(0);
}

fn childMainImpl(
    vm: *bindings.Vm,
    child_to_parent_fd: std.posix.fd_t,
    parent_to_child_fd: std.posix.fd_t,
    workload: Workload,
    call_count: usize,
    iterations_per_call: u32,
) !void {
    try os.process.assertSingleThreadedSelf();
    try vm.postForkChild();

    var seeds: bindings.RandomSeeds = undefined;
    try std.posix.getrandom(std.mem.asBytes(&seeds));
    try vm.reseedAfterFork(seeds);

    try writeChildMessage(child_to_parent_fd, .{
        .stage = child_idle_stage,
        .reserved = .{ 0, 0, 0, 0, 0, 0, 0 },
        .digest = 0,
    });
    try readRelease(parent_to_child_fd);

    const eval_cpu_start_ns = processCpuNowNs();
    const eval_wall_start_ns = try os.process.monotonicNowNs();
    var prepared = try prepareWorkloadInChild(
        std.heap.page_allocator,
        vm,
        workload,
        call_count,
        iterations_per_call,
    );
    const module_eval_cpu_ns = processCpuNowNs() - eval_cpu_start_ns;
    const module_eval_wall_ns = try os.process.monotonicNowNs() - eval_wall_start_ns;
    var prepared_alive = true;
    errdefer if (prepared_alive)
        prepared.deinit();

    try writeChildMessage(child_to_parent_fd, .{
        .stage = child_module_ready_stage,
        .reserved = .{ 0, 0, 0, 0, 0, 0, 0 },
        .digest = 0,
        .module_eval_cpu_ns = module_eval_cpu_ns,
        .module_eval_wall_ns = module_eval_wall_ns,
    });
    try readRelease(parent_to_child_fd);

    const invoke_cpu_start_ns = processCpuNowNs();
    const invoke_wall_start_ns = try os.process.monotonicNowNs();
    const digest = try invokeWorkloadInChild(std.heap.page_allocator, vm, &prepared.entry);
    const invoke_cpu_ns = processCpuNowNs() - invoke_cpu_start_ns;
    const invoke_wall_ns = try os.process.monotonicNowNs() - invoke_wall_start_ns;
    prepared.deinit();
    prepared_alive = false;

    try writeChildMessage(child_to_parent_fd, .{
        .stage = child_calls_done_stage,
        .reserved = .{ 0, 0, 0, 0, 0, 0, 0 },
        .digest = digest,
        .module_eval_cpu_ns = module_eval_cpu_ns,
        .module_eval_wall_ns = module_eval_wall_ns,
        .invoke_cpu_ns = invoke_cpu_ns,
        .invoke_wall_ns = invoke_wall_ns,
    });
    try readRelease(parent_to_child_fd);

    try vm.collectFullGCAndTrim();
    try writeChildMessage(child_to_parent_fd, .{
        .stage = child_gc_trim_done_stage,
        .reserved = .{ 0, 0, 0, 0, 0, 0, 0 },
        .digest = digest,
    });
    try readRelease(parent_to_child_fd);
}

fn prepareWorkloadInChild(
    allocator: std.mem.Allocator,
    vm: *bindings.Vm,
    workload: Workload,
    call_count: usize,
    iterations_per_call: u32,
) !PreparedWorkload {
    const source = try buildSource(allocator, workload, call_count, iterations_per_call);
    defer allocator.free(source);

    const specifier = "/bench/zygote-cow.js";
    const pack = try ipc.module_pack.buildSingleAlloc(allocator, specifier, source);
    defer allocator.free(pack);
    try vm.registerModulePack(pack);
    try evaluateModuleOk(vm, specifier);

    return .{ .entry = try getExportOk(vm, specifier, "default") };
}

fn invokeWorkloadInChild(
    allocator: std.mem.Allocator,
    vm: *bindings.Vm,
    entry: *const bindings.Value,
) !u64 {
    var exec_ctx = bindings.ExecCtx.init(1);
    try vm.turnEnter(&exec_ctx);
    const invoke_result = vm.invoke(allocator, &exec_ctx, entry, null, &.{});
    const exit_result = vm.turnExitResult();
    try handleTurnExit(vm, exit_result);

    var value = try unwrapValueResult(vm, invoke_result);
    defer value.deinit();

    var text = try valueToUtf8Ok(vm, &value);
    defer text.deinit();
    return std.fmt.parseUnsigned(u64, text.slice(), 10);
}

fn buildSource(
    allocator: std.mem.Allocator,
    workload: Workload,
    call_count: usize,
    iterations_per_call: u32,
) ![]u8 {
    const config_source = try std.fmt.allocPrint(
        allocator,
        "const __COLLO_CALLS = {d};\nconst __COLLO_ITERATIONS = {d};\n",
        .{ call_count, iterations_per_call },
    );
    defer allocator.free(config_source);

    return std.mem.concat(allocator, u8, &.{
        config_source,
        prelude_source,
        "\n",
        workload.source,
        "\n",
        trailer_source,
    });
}

fn evaluateModuleOk(vm: *bindings.Vm, specifier: []const u8) !void {
    switch (try vm.mainRealm().evaluateModule(specifier)) {
        .success => {},
        .exception => |exception| {
            var owned = exception;
            defer owned.deinit();
            logException(vm, &owned);
            return error.UnexpectedJsException;
        },
        .unsupported => |exception| {
            var owned = exception;
            defer owned.deinit();
            logException(vm, &owned);
            return error.UnexpectedJsException;
        },
        // Every workload here is generated by buildSource and synchronous by
        // construction. A pending evaluation would leave the exports as live
        // bindings, so the memory the bench then samples would not be the
        // memory of a settled module.
        .pending => return error.UnexpectedPendingEvaluation,
    }
}

fn getExportOk(vm: *bindings.Vm, specifier: []const u8, export_name: []const u8) !bindings.Value {
    return switch (try vm.mainRealm().moduleGetExport(specifier, export_name)) {
        .success => |value| value,
        .exception => |exception| {
            var owned = exception;
            defer owned.deinit();
            logException(vm, &owned);
            return error.UnexpectedJsException;
        },
    };
}

fn handleTurnExit(vm: *bindings.Vm, result: bindings.Error!bindings.VoidResult) !void {
    switch (try result) {
        .success => {},
        .exception => |exception| {
            var owned = exception;
            defer owned.deinit();
            logException(vm, &owned);
            return error.UnexpectedJsException;
        },
    }
}

fn unwrapValueResult(
    vm: *bindings.Vm,
    result: bindings.Error!bindings.ValueResult,
) !bindings.Value {
    return switch (try result) {
        .success => |value| value,
        .exception => |exception| {
            var owned = exception;
            defer owned.deinit();
            logException(vm, &owned);
            return error.UnexpectedJsException;
        },
    };
}

fn valueToUtf8Ok(vm: *bindings.Vm, value: *const bindings.Value) !bindings.OwnedString {
    return switch (try vm.valueToUtf8Copy(value)) {
        .success => |text| text,
        .exception => |exception| {
            var owned = exception;
            defer owned.deinit();
            logException(vm, &owned);
            return error.UnexpectedJsException;
        },
    };
}

fn logException(vm: *bindings.Vm, exception: *const bindings.Value) void {
    var formatted = vm.exceptionFormat(exception) catch {
        std.debug.print("zygote_cow_js_exception format=failed\n", .{});
        return;
    };
    defer formatted.deinit();
    std.debug.print("zygote_cow_js_exception message=\"", .{});
    printEscaped(formatted.slice());
    std.debug.print("\"\n", .{});
}

fn configuredIterationsPerCall(allocator: std.mem.Allocator) !u32 {
    const value = std.process.getEnvVarOwned(
        allocator,
        "COLLO_ZYGOTE_COW_ITERATIONS_PER_CALL",
    ) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return default_iterations_per_call,
        else => return err,
    };
    defer allocator.free(value);

    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    const parsed = try std.fmt.parseUnsigned(u32, trimmed, 10);
    if (parsed == 0)
        return error.InvalidIterationsPerCall;
    return parsed;
}

fn selectedByEnv(allocator: std.mem.Allocator, env_name: []const u8, name: []const u8) !bool {
    const value = std.process.getEnvVarOwned(allocator, env_name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return true,
        else => return err,
    };
    defer allocator.free(value);

    var parts = std.mem.splitScalar(u8, value, ',');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        if (trimmed.len == 0)
            return error.InvalidBenchFilter;
        if (std.mem.eql(u8, trimmed, name))
            return true;
    }
    return false;
}

fn readChildMessage(fd: std.posix.fd_t) !ChildMessage {
    var message: ChildMessage = undefined;
    try readExact(fd, std.mem.asBytes(&message));
    return message;
}

fn readChildMessageForChild(fd: std.posix.fd_t, child_pid: u32) !ChildMessage {
    return readChildMessage(fd) catch |err| {
        reportAndReapChild(child_pid);
        return err;
    };
}

fn writeChildMessage(fd: std.posix.fd_t, message: ChildMessage) !void {
    try writeAll(fd, std.mem.asBytes(&message));
}

fn writeRelease(fd: std.posix.fd_t) !void {
    const byte = [_]u8{1};
    try writeAll(fd, &byte);
}

fn readRelease(fd: std.posix.fd_t) !void {
    var byte: [1]u8 = undefined;
    try readExact(fd, &byte);
    if (byte[0] != 1)
        return error.InvalidReleaseByte;
}

fn readExact(fd: std.posix.fd_t, bytes: []u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const amount = try std.posix.read(fd, bytes[offset..]);
        if (amount == 0)
            return error.UnexpectedEof;
        offset += amount;
    }
}

fn writeAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const amount = try std.posix.write(fd, bytes[offset..]);
        if (amount == 0)
            return error.WriteZero;
        offset += amount;
    }
}

fn expectChildExit(pid: u32) !void {
    const result = std.posix.waitpid(@intCast(pid), 0);
    if (!std.c.W.IFEXITED(result.status))
        return error.ChildDidNotExit;
    if (std.c.W.EXITSTATUS(result.status) != 0)
        return error.ChildFailed;
}

fn reportAndReapChild(pid: u32) void {
    const result = std.posix.waitpid(@intCast(pid), 0);
    if (std.c.W.IFEXITED(result.status)) {
        std.debug.print(
            "zygote_cow_child_status pid={d} exited=true status={d}\n",
            .{ pid, std.c.W.EXITSTATUS(result.status) },
        );
        return;
    }
    if (std.c.W.IFSIGNALED(result.status)) {
        std.debug.print(
            "zygote_cow_child_status pid={d} signaled=true signal={d}\n",
            .{ pid, std.c.W.TERMSIG(result.status) },
        );
        return;
    }
    std.debug.print("zygote_cow_child_status pid={d} status={d}\n", .{ pid, result.status });
}

fn readSnapshot(allocator: std.mem.Allocator, pid: u32) !Snapshot {
    const path = try std.fmt.allocPrint(allocator, "/proc/{d}/smaps", .{pid});
    defer allocator.free(path);

    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, 256 * 1024 * 1024);
    defer allocator.free(contents);

    var snapshot = Snapshot{};
    var category: Category = .file_other;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (parseMappingCategory(line)) |parsed| {
            category = parsed;
            continue;
        }
        const metric = parseMetric(line) orelse continue;
        snapshot.total.add(metric);
        snapshot.categories[@intFromEnum(category)].add(metric);
    }
    return snapshot;
}

fn parseMappingCategory(line: []const u8) ?Category {
    if (line.len == 0)
        return null;
    if (!isHexDigit(line[0]))
        return null;
    if (std.mem.indexOfScalar(u8, line, '-') == null)
        return null;

    var tokens = std.mem.tokenizeAny(u8, line, " \t");
    _ = tokens.next() orelse return null;
    const permissions = tokens.next() orelse return null;
    const path_start = tokenEndAfter(line, 5) orelse line.len;
    const path = std.mem.trim(u8, line[path_start..], " \t\r\n");
    return categoryFor(permissions, path);
}

fn tokenEndAfter(line: []const u8, wanted_count: usize) ?usize {
    var count: usize = 0;
    var in_token = false;
    for (line, 0..) |byte, index| {
        if (byte == ' ' or byte == '\t') {
            if (in_token) {
                count += 1;
                if (count == wanted_count)
                    return index;
                in_token = false;
            }
            continue;
        }
        in_token = true;
    }
    if (in_token) {
        count += 1;
        if (count == wanted_count)
            return line.len;
    }
    return null;
}

fn categoryFor(permissions: []const u8, path: []const u8) Category {
    if (path.len == 0) {
        if (permissions.len >= 3 and permissions[2] == 'x')
            return .anonymous_executable_jit;
        return .anonymous;
    }
    if (std.mem.eql(u8, path, "[heap]"))
        return .heap;
    if (std.mem.startsWith(u8, path, "[stack"))
        return .stack;
    if (std.mem.startsWith(u8, path, "[anon:"))
        return .anonymous_named;
    if (std.mem.startsWith(u8, path, "["))
        return .kernel_mapping;
    if (std.mem.containsAtLeast(u8, path, 1, "zygote_cow"))
        return .collo_executable;
    if (std.mem.containsAtLeast(u8, path, 1, "JavaScriptCore"))
        return .jsc_file;
    if (std.mem.containsAtLeast(u8, path, 1, "libicu"))
        return .icu_file;
    if (std.mem.containsAtLeast(u8, path, 1, "libstdc++"))
        return .stdlib_file;
    if (std.mem.containsAtLeast(u8, path, 1, "libc.so") or
        std.mem.containsAtLeast(u8, path, 1, "ld-linux"))
    {
        return .libc_file;
    }
    return .file_other;
}

fn parseMetric(line: []const u8) ?Totals {
    if (parseMetricValue(line, "Rss:")) |value|
        return .{ .rss_kib = value };
    if (parseMetricValue(line, "Pss:")) |value|
        return .{ .pss_kib = value };
    if (parseMetricValue(line, "Private_Clean:")) |value|
        return .{ .private_clean_kib = value };
    if (parseMetricValue(line, "Private_Dirty:")) |value|
        return .{ .private_dirty_kib = value };
    if (parseMetricValue(line, "Shared_Clean:")) |value|
        return .{ .shared_clean_kib = value };
    if (parseMetricValue(line, "Shared_Dirty:")) |value|
        return .{ .shared_dirty_kib = value };
    return null;
}

fn parseMetricValue(line: []const u8, key: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, line, key))
        return null;
    var fields = std.mem.tokenizeAny(u8, line[key.len..], " \t");
    const raw_value = fields.next() orelse return null;
    return std.fmt.parseUnsigned(u64, raw_value, 10) catch null;
}

fn printMetric(
    variant_name: []const u8,
    workload_name: []const u8,
    stage: []const u8,
    call_count: usize,
    pid: u32,
    snapshot: Snapshot,
) void {
    std.debug.print(
        "zygote_cow_metric variant={s} workload={s} stage={s} calls={d} pid={d}",
        .{ variant_name, workload_name, stage, call_count, pid },
    );
    printTotals(snapshot.total);
    std.debug.print(
        " anonymous_cow_shared_dirty_kib={d} anonymous_private_dirty_kib={d} anonymous_cow_retained_percent={d}\n",
        .{
            snapshot.anonymousCowSharedDirtyKib(),
            snapshot.anonymousPrivateDirtyKib(),
            snapshot.anonymousCowRetainedPercent(),
        },
    );
}

fn printDelta(
    variant_name: []const u8,
    workload_name: []const u8,
    stage: []const u8,
    call_count: usize,
    before: Snapshot,
    after: Snapshot,
) void {
    std.debug.print(
        "zygote_cow_delta variant={s} workload={s} stage={s} calls={d}",
        .{ variant_name, workload_name, stage, call_count },
    );
    printTotalsDelta(before.total, after.total);
    std.debug.print(
        " anonymous_cow_shared_dirty_kib_delta={d} anonymous_private_dirty_kib_delta={d}\n",
        .{
            signedDelta(before.anonymousCowSharedDirtyKib(), after.anonymousCowSharedDirtyKib()),
            signedDelta(before.anonymousPrivateDirtyKib(), after.anonymousPrivateDirtyKib()),
        },
    );
}

fn printCategoryDeltas(
    variant_name: []const u8,
    workload_name: []const u8,
    stage: []const u8,
    call_count: usize,
    before: Snapshot,
    after: Snapshot,
) void {
    for (category_names, 0..) |name, index| {
        const before_totals = before.categories[index];
        const after_totals = after.categories[index];
        if (before_totals.rss_kib == after_totals.rss_kib and
            before_totals.pss_kib == after_totals.pss_kib and
            before_totals.private_clean_kib == after_totals.private_clean_kib and
            before_totals.private_dirty_kib == after_totals.private_dirty_kib and
            before_totals.shared_clean_kib == after_totals.shared_clean_kib and
            before_totals.shared_dirty_kib == after_totals.shared_dirty_kib)
        {
            continue;
        }

        std.debug.print(
            "zygote_cow_category_delta variant={s} workload={s} stage={s} calls={d} category={s}",
            .{ variant_name, workload_name, stage, call_count, name },
        );
        printTotalsDelta(before_totals, after_totals);
        std.debug.print("\n", .{});
    }
}

fn printResult(
    variant_name: []const u8,
    workload_name: []const u8,
    call_count: usize,
    digest: u64,
    snapshot: Snapshot,
) void {
    std.debug.print(
        "zygote_cow_result variant={s} workload={s} calls={d} digest={d} child_pss_kib={d} child_private_dirty_kib={d} anonymous_cow_retained_percent={d}\n",
        .{
            variant_name,
            workload_name,
            call_count,
            digest,
            snapshot.total.pss_kib,
            snapshot.total.private_dirty_kib,
            snapshot.anonymousCowRetainedPercent(),
        },
    );
}

fn printRetainedResult(
    variant_name: []const u8,
    workload_name: []const u8,
    call_count: usize,
    digest: u64,
    child_idle: Snapshot,
    snapshot: Snapshot,
) void {
    std.debug.print(
        "zygote_cow_retained_result variant={s} workload={s} calls={d} digest={d} child_pss_kib={d} child_private_dirty_kib={d} anonymous_cow_broken_kib={d} anonymous_cow_retained_from_idle_percent={d}\n",
        .{
            variant_name,
            workload_name,
            call_count,
            digest,
            snapshot.total.pss_kib,
            snapshot.total.private_dirty_kib,
            cowBrokenKib(child_idle, snapshot),
            percentOf(snapshot.anonymousCowSharedDirtyKib(), child_idle.anonymousCowSharedDirtyKib()),
        },
    );
}

fn printCowBreakdown(
    variant_name: []const u8,
    workload_name: []const u8,
    stage: []const u8,
    call_count: usize,
    child_idle: Snapshot,
    snapshot: Snapshot,
) void {
    const private_dirty_delta = signedDelta(
        child_idle.total.private_dirty_kib,
        snapshot.total.private_dirty_kib,
    );
    const anonymous_private_dirty_delta = signedDelta(
        child_idle.anonymousPrivateDirtyKib(),
        snapshot.anonymousPrivateDirtyKib(),
    );
    const dirty_cow_shared_delta = signedDelta(
        child_idle.total.shared_dirty_kib,
        snapshot.total.shared_dirty_kib,
    );
    const non_anonymous_private_dirty_delta = private_dirty_delta - anonymous_private_dirty_delta;
    const cow_broken_kib = cowBrokenKib(child_idle, snapshot);

    std.debug.print(
        "zygote_cow_breakdown variant={s} workload={s} stage={s} calls={d} anonymous_cow_template_kib={d} anonymous_cow_retained_kib={d} anonymous_cow_broken_kib={d} anonymous_cow_retained_from_idle_percent={d} dirty_cow_shared_idle_kib={d} dirty_cow_shared_stage_kib={d} dirty_cow_shared_kib_delta={d} private_dirty_kib_delta={d} anonymous_private_dirty_kib_delta={d} non_anonymous_private_dirty_kib_delta={d} private_dirty_minus_anonymous_cow_broken_kib={d}\n",
        .{
            variant_name,
            workload_name,
            stage,
            call_count,
            child_idle.anonymousCowSharedDirtyKib(),
            snapshot.anonymousCowSharedDirtyKib(),
            cow_broken_kib,
            percentOf(snapshot.anonymousCowSharedDirtyKib(), child_idle.anonymousCowSharedDirtyKib()),
            child_idle.total.shared_dirty_kib,
            snapshot.total.shared_dirty_kib,
            dirty_cow_shared_delta,
            private_dirty_delta,
            anonymous_private_dirty_delta,
            non_anonymous_private_dirty_delta,
            private_dirty_delta - @as(i64, @intCast(cow_broken_kib)),
        },
    );
}

fn printTiming(
    variant_name: []const u8,
    workload_name: []const u8,
    call_count: usize,
    message: ChildMessage,
) void {
    std.debug.print(
        "zygote_cow_timing variant={s} workload={s} calls={d} module_eval_cpu_ns={d} module_eval_wall_ns={d} invoke_cpu_ns={d} invoke_wall_ns={d}\n",
        .{
            variant_name,
            workload_name,
            call_count,
            message.module_eval_cpu_ns,
            message.module_eval_wall_ns,
            message.invoke_cpu_ns,
            message.invoke_wall_ns,
        },
    );
}

fn processCpuNowNs() u64 {
    const ts = std.posix.clock_gettime(std.posix.CLOCK.PROCESS_CPUTIME_ID) catch return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn cowBrokenKib(child_idle: Snapshot, snapshot: Snapshot) u64 {
    const idle_cow_kib = child_idle.anonymousCowSharedDirtyKib();
    const retained_cow_kib = snapshot.anonymousCowSharedDirtyKib();
    if (retained_cow_kib >= idle_cow_kib)
        return 0;
    return idle_cow_kib - retained_cow_kib;
}

fn percentOf(numerator: u64, denominator: u64) u64 {
    if (denominator == 0)
        return 0;
    return (numerator * 100) / denominator;
}

fn printTotals(totals: Totals) void {
    std.debug.print(
        " rss_kib={d} pss_kib={d} private_clean_kib={d} private_dirty_kib={d} shared_clean_kib={d} shared_dirty_kib={d}",
        .{
            totals.rss_kib,
            totals.pss_kib,
            totals.private_clean_kib,
            totals.private_dirty_kib,
            totals.shared_clean_kib,
            totals.shared_dirty_kib,
        },
    );
}

fn printTotalsDelta(before: Totals, after: Totals) void {
    std.debug.print(
        " rss_kib_delta={d} pss_kib_delta={d} private_clean_kib_delta={d} private_dirty_kib_delta={d} shared_clean_kib_delta={d} shared_dirty_kib_delta={d}",
        .{
            signedDelta(before.rss_kib, after.rss_kib),
            signedDelta(before.pss_kib, after.pss_kib),
            signedDelta(before.private_clean_kib, after.private_clean_kib),
            signedDelta(before.private_dirty_kib, after.private_dirty_kib),
            signedDelta(before.shared_clean_kib, after.shared_clean_kib),
            signedDelta(before.shared_dirty_kib, after.shared_dirty_kib),
        },
    );
}

fn signedDelta(before: u64, after: u64) i64 {
    return @as(i64, @intCast(after)) - @as(i64, @intCast(before));
}

fn isHexDigit(byte: u8) bool {
    return (byte >= '0' and byte <= '9') or
        (byte >= 'a' and byte <= 'f') or
        (byte >= 'A' and byte <= 'F');
}

fn printEscaped(value: []const u8) void {
    for (value) |byte| switch (byte) {
        '"' => std.debug.print("\\\"", .{}),
        '\\' => std.debug.print("\\\\", .{}),
        '\n' => std.debug.print("\\n", .{}),
        '\r' => std.debug.print("\\r", .{}),
        '\t' => std.debug.print("\\t", .{}),
        else => std.debug.print("{c}", .{byte}),
    };
}

fn writeChildError(err: anyerror) void {
    writeBestEffort(std.posix.STDERR_FILENO, "zygote_cow_child_error error=");
    writeBestEffort(std.posix.STDERR_FILENO, @errorName(err));
    writeBestEffort(std.posix.STDERR_FILENO, "\n");
}

fn writeBestEffort(fd: std.posix.fd_t, bytes: []const u8) void {
    var remaining = bytes;
    while (remaining.len != 0) {
        const written = std.posix.write(fd, remaining) catch return;
        if (written == 0)
            return;
        remaining = remaining[written..];
    }
}

const category_names = [_][]const u8{
    "heap",
    "stack",
    "anonymous",
    "anonymous_named",
    "anonymous_executable_jit",
    "collo_executable",
    "jsc_file",
    "icu_file",
    "stdlib_file",
    "libc_file",
    "kernel_mapping",
    "file_other",
};

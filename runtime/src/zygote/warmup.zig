//! The warmup corpus, run once in the zygote's VM before the first fork.
//!
//! JSC creates much of its state lazily: builtin bytecode, structure caches
//! and the RegExp, JSON, URL and Promise machinery. Without warmup every worker
//! would build that state again in private pages. Running a small corpus that
//! belongs to no application moves it into pages all workers share. The caller
//! runs a full GC and trims the allocator afterwards, so only that state
//! survives. The corpus must stay free of tenant code and data.

const std = @import("std");
const bindings = @import("collo_bindings");
const ipc = @import("collo_ipc");

const corpus_source = @embedFile("warmup.js");
const corpus_specifier = "/__collo/zygote/warmup.js";
// Warmup runs once at zygote boot; request-scoped allocators do not exist yet.
const boot_allocator = std.heap.smp_allocator;
// The corpus serves no request; the execution context only needs a nonzero id.
const warmup_request_id: u64 = 1;

/// Evaluates the corpus module and calls its default export inside one VM
/// turn, so microtasks drain, then evicts the module so none of it outlives
/// the warmup. Any JavaScript exception fails the warmup.
pub fn runCorpus(vm: *bindings.Vm) !void {
    const pack = try ipc.module_pack.buildSingleAlloc(
        boot_allocator,
        corpus_specifier,
        corpus_source,
    );
    defer boot_allocator.free(pack);
    try vm.registerModulePack(pack);

    const realm = vm.mainRealm();
    switch (try realm.evaluateModule(corpus_specifier)) {
        .success => {},
        .exception, .unsupported => |exception| return failWithException(exception),
        // The corpus is synchronous; a pending evaluation means someone added
        // a top-level await to it.
        .pending => return error.WarmupCorpusAsyncEvaluation,
    }

    var entry = switch (try realm.moduleGetExport(corpus_specifier, "default")) {
        .success => |value| value,
        .exception => |exception| return failWithException(exception),
    };
    defer entry.deinit();

    var exec_ctx = bindings.ExecCtx.init(warmup_request_id);
    try vm.turnEnter(&exec_ctx);
    const invoke_result = vm.invoke(boot_allocator, &exec_ctx, &entry, null, &.{});
    const exit_result = vm.turnExitResult();

    var digest = try finishWarmupTurn(invoke_result, exit_result);
    defer digest.deinit();

    var digest_text = switch (try vm.valueToUtf8Copy(&digest)) {
        .success => |text| text,
        .exception => |exception| return failWithException(exception),
    };
    defer digest_text.deinit();
    if (digest_text.slice().len == 0)
        return error.WarmupCorpusFailed;

    const evicted = try vm.evictModuleSpecifier(corpus_specifier);
    if (evicted.sources_removed == 0)
        return error.WarmupCorpusFailed;
}

fn finishWarmupTurn(invoke_result: anytype, exit_result: anytype) !bindings.Value {
    const invoked = invoke_result catch |err| {
        discardTurnExit(exit_result);
        return err;
    };
    switch (invoked) {
        .exception => |exception| {
            discardTurnExit(exit_result);
            return failWithException(exception);
        },
        .success => |value| {
            const exit = exit_result catch |err| {
                var owned_value = value;
                owned_value.deinit();
                return err;
            };
            switch (exit) {
                .success => return value,
                .exception => |exception| {
                    var owned_value = value;
                    owned_value.deinit();
                    return failWithException(exception);
                },
            }
        },
    }
}

fn failWithException(exception: bindings.Value) error{WarmupCorpusFailed} {
    var owned = exception;
    owned.deinit();
    return error.WarmupCorpusFailed;
}

fn discardTurnExit(result: bindings.Error!bindings.VoidResult) void {
    const exit = result catch return;
    switch (exit) {
        .success => {},
        .exception => |exception| {
            var owned = exception;
            owned.deinit();
        },
    }
}

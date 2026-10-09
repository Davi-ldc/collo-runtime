//! The bridge's module loader on VMs with no host runtime: registering module packs and
//! refusing malformed ones, resolving and evaluating in-memory ES modules, `import()` of a
//! registered module and the module-not-found rejection of any other, the specifiers it
//! rejects, eviction by lifetime, the public `/var/task` spelling of route keys, and what
//! `Vm.promiseAwaitSync` refuses. Packs loaded from sealed memfds in a worker, a handler's
//! `import()` and top-level await settlement are covered in `worker-test`
//! (`worker/tests/runtime/modules.zig` and `boot_eval.zig`).

const std = @import("std");
const ipc = @import("collo_ipc");
const support = @import("bindings_support");

const module_pack = ipc.module_pack;

test "register evaluate and get export through root wrapper" {
    var vm = try support.createVm();
    defer vm.deinit();

    const source =
        \\export default "ok";
    ;

    try support.registerModule(&vm, "/module.js", source);
    try support.evaluateOk(&vm, "/module.js");

    var entry = try support.getExportOk(&vm, "/module.js", "default");
    defer entry.deinit();

    try support.expectValueString(&vm, &entry, "ok");
}

test "canonicalization keeps duplicate registration deterministic" {
    var vm = try support.createVm();
    defer vm.deinit();

    const dep_source =
        \\export default "dep";
    ;
    const main_source =
        \\import dep from "./dep.js";
        \\export default dep + ":ok";
    ;

    try support.registerModule(&vm, "/dep.js", dep_source);

    const duplicate_pack = try module_pack.buildSingleAlloc(std.testing.allocator, "/dep.js", dep_source);
    defer std.testing.allocator.free(duplicate_pack);
    try vm.registerModulePack(duplicate_pack);

    const changed_pack = try module_pack.buildSingleAlloc(std.testing.allocator, "/dep.js", "export default 'changed';");
    defer std.testing.allocator.free(changed_pack);
    try std.testing.expectError(error.AlreadyExists, vm.registerModulePack(changed_pack));

    try support.registerModule(&vm, "/main.js", main_source);
    try support.evaluateOk(&vm, "./main.js");

    var entry = try support.getExportOk(&vm, "/main.js", "default");
    defer entry.deinit();

    try support.expectValueString(&vm, &entry, "dep:ok");
}

test "dynamic import resolves registered in-memory modules" {
    var vm = try support.createVm();
    defer vm.deinit();

    const dep_source =
        \\export const value = "dep";
        \\export default "ok";
    ;
    const source =
        \\const ns = await import("./dep.js");
        \\export default ns.value + ":" + ns.default;
    ;

    try support.registerModule(&vm, "/dep.js", dep_source);
    try support.registerModule(&vm, "/dynamic.js", source);
    try support.evaluateOk(&vm, "/dynamic.js");

    var entry = try support.getExportOk(&vm, "/dynamic.js", "default");
    defer entry.deinit();

    try support.expectValueString(&vm, &entry, "dep:ok");
}

test "relative imports cannot escape the module root" {
    var vm = try support.createVm();
    defer vm.deinit();

    const source =
        \\import escaped from "../escape.js";
        \\export default escaped;
    ;

    try support.registerModule(&vm, "/main.js", source);

    var exception = try support.evaluateException(&vm, "/main.js");
    defer exception.deinit();

    try support.expectExceptionContains(&vm, &exception, "Invalid module specifier");
    try support.expectExceptionContains(&vm, &exception, "../escape.js");
    try support.expectExceptionContains(&vm, &exception, "/main.js");
}

test "bare module specifiers are rejected before fetch" {
    var vm = try support.createVm();
    defer vm.deinit();

    const source =
        \\import value from "react";
        \\export default value;
    ;

    try support.registerModule(&vm, "/bare.js", source);

    var exception = try support.evaluateException(&vm, "/bare.js");
    defer exception.deinit();

    try support.expectExceptionContains(&vm, &exception, "Invalid module specifier");
    try support.expectExceptionContains(&vm, &exception, "react");
}

test "default VM rejects node fs and bare fs module aliases" {
    var vm = try support.createVm();
    defer vm.deinit();

    const node_source =
        \\import fs from "node:fs";
        \\export default fs;
    ;
    try support.registerModule(&vm, "/default-node-fs.js", node_source);
    var node_exception = try support.evaluateException(&vm, "/default-node-fs.js");
    defer node_exception.deinit();
    try support.expectExceptionContains(&vm, &node_exception, "Invalid module specifier");
    try support.expectExceptionContains(&vm, &node_exception, "node:fs");

    const bare_source =
        \\import fs from "fs";
        \\export default fs;
    ;
    try support.registerModule(&vm, "/default-bare-fs.js", bare_source);
    var bare_exception = try support.evaluateException(&vm, "/default-bare-fs.js");
    defer bare_exception.deinit();
    try support.expectExceptionContains(&vm, &bare_exception, "Invalid module specifier");
    try support.expectExceptionContains(&vm, &bare_exception, "fs");
}

test "default VM rejects node fs promises module aliases" {
    var vm = try support.createVm();
    defer vm.deinit();

    const node_source =
        \\import fsp from "node:fs/promises";
        \\export default fsp;
    ;
    try support.registerModule(&vm, "/default-node-fs-promises.js", node_source);
    var node_exception = try support.evaluateException(&vm, "/default-node-fs-promises.js");
    defer node_exception.deinit();
    try support.expectExceptionContains(&vm, &node_exception, "Invalid module specifier");
    try support.expectExceptionContains(&vm, &node_exception, "node:fs/promises");
}

test "worker-enabled VM resolves node fs and bare fs to the confined fs module" {
    var vm = try support.createVm();
    defer vm.deinit();
    try vm.enableNodeFsForWorker();

    const source =
        \\import fs, { readFileSync, promises } from "node:fs";
        \\import bare from "fs";
        \\export default [
        \\  typeof fs.writeFileSync,
        \\  typeof readFileSync,
        \\  typeof promises.readFile,
        \\  String(fs === bare),
        \\].join(":");
    ;

    try support.registerModule(&vm, "/fs-import.js", source);
    try support.evaluateOk(&vm, "/fs-import.js");

    var entry = try support.getExportOk(&vm, "/fs-import.js", "default");
    defer entry.deinit();

    try support.expectValueString(&vm, &entry, "function:function:function:true");
}

test "worker-enabled VM resolves node fs promises and bare fs promises to one module" {
    var vm = try support.createVm();
    defer vm.deinit();
    try vm.enableNodeFsForWorker();

    const source =
        \\import fsp, { readFile, writeFile, mkdir, readdir, stat, unlink, rename, exists } from "node:fs/promises";
        \\import bare from "fs/promises";
        \\import * as canonical_ns from "node:fs/promises";
        \\import * as bare_ns from "fs/promises";
        \\export default [
        \\  typeof readFile, typeof writeFile, typeof mkdir, typeof readdir,
        \\  typeof stat, typeof unlink, typeof rename, typeof exists,
        \\  String(readFile === fsp.readFile),
        \\  String(fsp === bare),
        \\  String(canonical_ns === bare_ns),
        \\].join(":");
    ;

    try support.registerModule(&vm, "/fs-promises-import.js", source);
    try support.evaluateOk(&vm, "/fs-promises-import.js");

    var entry = try support.getExportOk(&vm, "/fs-promises-import.js", "default");
    defer entry.deinit();

    try support.expectValueString(
        &vm,
        &entry,
        "function:function:function:function:function:function:function:function:true:true:true",
    );
}

test "other node builtins remain rejected" {
    var vm = try support.createVm();
    defer vm.deinit();

    const source =
        \\import path from "node:path";
        \\export default path;
    ;

    try support.registerModule(&vm, "/node-path.js", source);

    var exception = try support.evaluateException(&vm, "/node-path.js");
    defer exception.deinit();

    try support.expectExceptionContains(&vm, &exception, "Invalid module specifier");
    try support.expectExceptionContains(&vm, &exception, "node:path");
}

// A computed specifier can reach `child_process` where no static scan of the source sees it, so
// resolution refuses the module with an ordinary exception that the evaluation reports, never a
// crash.
test "child_process stays rejected as a catchable error" {
    var vm = try support.createVm();
    defer vm.deinit();

    const source =
        \\import cp from "child_process";
        \\export default cp;
    ;

    try support.registerModule(&vm, "/child-process.js", source);

    var exception = try support.evaluateException(&vm, "/child-process.js");
    defer exception.deinit();

    try support.expectExceptionContains(&vm, &exception, "Invalid module specifier");
    try support.expectExceptionContains(&vm, &exception, "child_process");
}

test "module pack registers dependency graph in one ABI call" {
    var vm = try support.createVm();
    defer vm.deinit();

    const pack = try module_pack.buildAlloc(std.testing.allocator, &.{
        .{
            .specifier = "/dep.js",
            .source =
            \\export const value = "dep";
            \\export default "ok";
            ,
        },
        .{
            .specifier = "/pack.js",
            .source =
            \\import dep, { value } from "./dep.js";
            \\export default value + ":" + dep;
            ,
        },
    }, 1);
    defer std.testing.allocator.free(pack);

    try vm.registerModulePack(pack);
    try support.evaluateOk(&vm, "/pack.js");

    var entry = try support.getExportOk(&vm, "/pack.js", "default");
    defer entry.deinit();

    try support.expectValueString(&vm, &entry, "dep:ok");
}

test "module pack bytecode payload falls back to source when cache misses" {
    var vm = try support.createVm();
    defer vm.deinit();

    const pack = try module_pack.buildAlloc(std.testing.allocator, &.{
        .{
            .specifier = "/bytecode-backed.js",
            .source =
            \\export default "source";
            ,
            .bytecode = "not-a-jsc-bytecode-cache",
        },
    }, 0);
    defer std.testing.allocator.free(pack);

    try vm.registerModulePack(pack);
    try support.evaluateOk(&vm, "/bytecode-backed.js");

    var entry = try support.getExportOk(&vm, "/bytecode-backed.js", "default");
    defer entry.deinit();

    try support.expectValueString(&vm, &entry, "source");
}

test "evicting evictable modules removes unevaluated sources" {
    var vm = try support.createVm();
    defer vm.deinit();

    const pack = try module_pack.buildSingleAlloc(std.testing.allocator, "/evictable.js", "export default 'gone';");
    defer std.testing.allocator.free(pack);

    try vm.registerModulePack(pack);

    const stats = try vm.evictModulesByLifetime(.evictable);
    try std.testing.expectEqual(@as(usize, 1), stats.sources_removed);
    try std.testing.expectEqual(@as(usize, 0), stats.namespaces_removed);

    var exception = try support.evaluateException(&vm, "/evictable.js");
    defer exception.deinit();
    try support.expectExceptionContains(&vm, &exception, "Cannot find module '/evictable.js'");
}

test "permanent modules survive evictable cache sweeps" {
    var vm = try support.createVm();
    defer vm.deinit();

    const pack = try module_pack.buildSingleAlloc(std.testing.allocator, "/permanent.js", "export default 'kept';");
    defer std.testing.allocator.free(pack);

    try vm.registerModulePackWithOptions(pack, .{ .lifetime = @intFromEnum(support.bindings.ModuleLifetime.permanent) });

    const stats = try vm.evictModulesByLifetime(.evictable);
    try std.testing.expectEqual(@as(usize, 0), stats.sources_removed);
    try std.testing.expectEqual(@as(usize, 0), stats.namespaces_removed);

    try support.evaluateOk(&vm, "/permanent.js");
    var entry = try support.getExportOk(&vm, "/permanent.js", "default");
    defer entry.deinit();
    try support.expectValueString(&vm, &entry, "kept");
}

test "duplicate source registration can upgrade module lifetime" {
    var vm = try support.createVm();
    defer vm.deinit();

    const source = "export default 'upgraded';";
    const pack = try module_pack.buildSingleAlloc(std.testing.allocator, "/upgrade.js", source);
    defer std.testing.allocator.free(pack);
    const duplicate_pack = try module_pack.buildSingleAlloc(std.testing.allocator, "/upgrade.js", source);
    defer std.testing.allocator.free(duplicate_pack);

    try vm.registerModulePack(pack);
    try vm.registerModulePackWithOptions(duplicate_pack, .{ .lifetime = @intFromEnum(support.bindings.ModuleLifetime.permanent) });

    const stats = try vm.evictModulesByLifetime(.evictable);
    try std.testing.expectEqual(@as(usize, 0), stats.sources_removed);

    try support.evaluateOk(&vm, "/upgrade.js");
    var entry = try support.getExportOk(&vm, "/upgrade.js", "default");
    defer entry.deinit();
    try support.expectValueString(&vm, &entry, "upgraded");
}

test "duplicate source registration can upgrade bytecode metadata" {
    var vm = try support.createVm();
    defer vm.deinit();

    const source = "export default 'bytecode-upgrade';";
    const pack = try module_pack.buildSingleAlloc(std.testing.allocator, "/bytecode-upgrade.js", source);
    defer std.testing.allocator.free(pack);
    const duplicate_pack = try module_pack.buildAlloc(std.testing.allocator, &.{
        .{
            .specifier = "/bytecode-upgrade.js",
            .source = source,
            .bytecode = "not-a-real-bytecode-cache",
        },
    }, 0);
    defer std.testing.allocator.free(duplicate_pack);

    try vm.registerModulePack(pack);
    try vm.registerModulePack(duplicate_pack);

    try support.evaluateOk(&vm, "/bytecode-upgrade.js");
    var entry = try support.getExportOk(&vm, "/bytecode-upgrade.js", "default");
    defer entry.deinit();
    try support.expectValueString(&vm, &entry, "bytecode-upgrade");
}

test "module registration options reject unknown tags" {
    var vm = try support.createVm();
    defer vm.deinit();

    const pack = try module_pack.buildSingleAlloc(std.testing.allocator, "/bad-options.js", "export default 1;");
    defer std.testing.allocator.free(pack);

    try std.testing.expectError(error.InvalidArgument, vm.registerModulePackWithOptions(pack, .{ .lifetime = 99 }));
    try std.testing.expectError(error.InvalidArgument, vm.registerModulePackWithOptions(pack, .{ .module_type = 99 }));
}

test "module pack registration rejects corrupted record hash" {
    var vm = try support.createVm();
    defer vm.deinit();

    const pack = try module_pack.buildSingleAlloc(std.testing.allocator, "/bad-record-hash.js", "export default 1;");
    defer std.testing.allocator.free(pack);

    const parsed = try module_pack.parse(pack);
    const hash_offset: usize = @intCast(parsed.header.records_offset + @offsetOf(module_pack.ModuleRecord, "specifier_hash"));
    const hash = std.mem.readInt(u32, pack[hash_offset..][0..4], .little);
    const corrupted_hash = hash ^ 1;
    std.mem.writeInt(u32, pack[hash_offset..][0..4], corrupted_hash, .little);
    var patched_index = false;
    for (parsed.index, 0..) |entry, index| {
        if (entry.module_index == 0) {
            const index_hash_offset: usize = @intCast(parsed.header.index_offset + index * @sizeOf(module_pack.IndexEntry) + @offsetOf(module_pack.IndexEntry, "specifier_hash"));
            std.mem.writeInt(u32, pack[index_hash_offset..][0..4], corrupted_hash, .little);
            patched_index = true;
            break;
        }
    }
    try std.testing.expect(patched_index);

    try std.testing.expectError(error.InvalidArgument, vm.registerModulePack(pack));
}

test "module pack registration rejects corrupted dependency hash" {
    var vm = try support.createVm();
    defer vm.deinit();

    const dependencies = [_]module_pack.Dependency{.{ .specifier = "/__collo_route/demo/dep.js" }};
    const pack = try module_pack.buildAlloc(std.testing.allocator, &.{
        .{
            .specifier = "/__collo_route/demo/entry.js",
            .source = "import value from './dep.js'; export default value;",
            .dependencies = &dependencies,
        },
        .{
            .specifier = "/__collo_route/demo/dep.js",
            .source = "export default 1;",
        },
    }, 0);
    defer std.testing.allocator.free(pack);

    const parsed = try module_pack.parse(pack);
    const hash_offset: usize = @intCast(parsed.header.dependencies_offset + @offsetOf(module_pack.DependencyRecord, "specifier_hash"));
    const hash = std.mem.readInt(u32, pack[hash_offset..][0..4], .little);
    std.mem.writeInt(u32, pack[hash_offset..][0..4], hash ^ 1, .little);

    try std.testing.expectError(error.InvalidArgument, vm.registerModulePack(pack));
}

test "module pack registration rejects dangling dependency graph edges" {
    var vm = try support.createVm();
    defer vm.deinit();

    const dependencies = [_]module_pack.Dependency{.{ .specifier = "/__collo_route/demo/dep.js" }};
    const pack = try module_pack.buildAlloc(std.testing.allocator, &.{
        .{
            .specifier = "/__collo_route/demo/entry.js",
            .source = "import value from './dep.js'; export default value;",
            .dependencies = &dependencies,
        },
        .{
            .specifier = "/__collo_route/demo/dep.js",
            .source = "export default 1;",
        },
    }, 0);
    defer std.testing.allocator.free(pack);

    const parsed = try module_pack.parse(pack);
    const replacement = "/__collo_route/demo/xxx.js";
    const dependency = parsed.dependencies[0];
    try std.testing.expectEqual(dependency.specifier_len, @as(u32, @intCast(replacement.len)));
    const specifier_offset: usize = @intCast(dependency.specifier_offset);
    @memcpy(pack[specifier_offset..][0..replacement.len], replacement);
    const hash_offset: usize = @intCast(parsed.header.dependencies_offset + @offsetOf(module_pack.DependencyRecord, "specifier_hash"));
    std.mem.writeInt(u32, pack[hash_offset..][0..4], module_pack.hashSpecifier(replacement), .little);

    try std.testing.expectError(error.InvalidArgument, vm.registerModulePack(pack));
}

test "module pack registration rejects duplicate index coverage" {
    var vm = try support.createVm();
    defer vm.deinit();

    const pack = try module_pack.buildAlloc(std.testing.allocator, &.{
        .{ .specifier = "/__collo_route/demo/one.js", .source = "export default 1;" },
        .{ .specifier = "/__collo_route/demo/two.js", .source = "export default 2;" },
    }, 0);
    defer std.testing.allocator.free(pack);
    const parsed = try module_pack.parse(pack);
    const first_hash = parsed.records[0].specifier_hash;
    var patched = false;
    for (parsed.index, 0..) |entry, index| {
        if (entry.module_index == 1) {
            const entry_offset: usize = @intCast(parsed.header.index_offset + index * @sizeOf(module_pack.IndexEntry));
            std.mem.writeInt(u32, pack[entry_offset..][0..4], first_hash, .little);
            std.mem.writeInt(u32, pack[entry_offset + 4 ..][0..4], 0, .little);
            patched = true;
            break;
        }
    }
    try std.testing.expect(patched);

    try std.testing.expectError(error.InvalidArgument, vm.registerModulePack(pack));
}

test "module pack registration is atomic when a later record conflicts" {
    var vm = try support.createVm();
    defer vm.deinit();

    try support.registerModule(&vm, "/existing.js", "export default 'old';");

    const pack = try module_pack.buildAlloc(std.testing.allocator, &.{
        .{ .specifier = "/fresh.js", .source = "export default 'fresh';" },
        .{ .specifier = "/existing.js", .source = "export default 'changed';" },
    }, 0);
    defer std.testing.allocator.free(pack);

    try std.testing.expectError(error.AlreadyExists, vm.registerModulePack(pack));

    try support.evaluateOk(&vm, "/existing.js");
    var existing = try support.getExportOk(&vm, "/existing.js", "default");
    defer existing.deinit();
    try support.expectValueString(&vm, &existing, "old");

    var fresh_exception = try support.evaluateException(&vm, "/fresh.js");
    defer fresh_exception.deinit();
    try support.expectExceptionContains(&vm, &fresh_exception, "Cannot find module '/fresh.js'");
}

test "dynamic import of a module no pack holds rejects as not found, naming its importer" {
    var vm = try support.createVm();
    defer vm.deinit();

    const source =
        \\await import("./missing.js");
        \\export default 1;
    ;

    try support.registerModule(&vm, "/dynamic-missing.js", source);

    var exception = try support.evaluateException(&vm, "/dynamic-missing.js");
    defer exception.deinit();

    try support.expectExceptionContains(&vm, &exception, "Cannot find module '/missing.js'");
    try support.expectExceptionContains(&vm, &exception, "imported from '/dynamic-missing.js'");
}

test "top level await returns pending evaluation" {
    var vm = try support.createVm();
    defer vm.deinit();

    const source =
        \\await new Promise(() => {});
        \\export default 1;
    ;

    try support.registerModule(&vm, "/await.js", source);
    // With no host runtime, as on the zygote's VM, evaluation registers no settlement callback
    // but still reports pending (`awaitModulePromiseSync` in `jsc/runtime/module_loader.cpp`).
    // Evaluating again while pending is not tested: the worker never does it, because
    // `ensureRouteHandler` in `worker/modules/routes.zig` queues behind the `.evaluating`
    // record, and JSC fulfills a re-import of an async-evaluating module instead of returning
    // the pending capability.
    try support.evaluatePending(&vm, "/await.js");
}

test "promise await sync inside a turn returns invalid argument" {
    var vm = try support.createVm();
    defer vm.deinit();

    const source =
        \\export default function makePromise() {
        \\    return Promise.resolve("ok");
        \\}
    ;

    try support.registerModule(&vm, "/promise.js", source);
    try support.evaluateOk(&vm, "/promise.js");

    var make_promise = try support.getExportOk(&vm, "/promise.js", "default");
    defer make_promise.deinit();

    var exec_ctx = support.makeExecCtx(42);
    try vm.turnEnter(&exec_ctx);
    defer vm.turnExit() catch {};

    var promise = try support.invokeOk(&vm, &exec_ctx, &make_promise, &.{});
    defer promise.deinit();

    try std.testing.expectError(error.InvalidArgument, vm.promiseAwaitSync(&promise));
}

test "promise await sync rejects pending external promises" {
    var vm = try support.createVm();
    defer vm.deinit();

    const source =
        \\export const pending = new Promise(() => {});
    ;

    try support.registerModule(&vm, "/pending-promise.js", source);
    try support.evaluateOk(&vm, "/pending-promise.js");

    var pending = try support.getExportOk(&vm, "/pending-promise.js", "pending");
    defer pending.deinit();

    var unsupported = switch (try vm.promiseAwaitSync(&pending)) {
        .unsupported => |value| value,
        .success => |value| {
            var owned_value = value;
            defer owned_value.deinit();
            return error.ExpectedUnsupported;
        },
        .exception => |exception| {
            var owned_exception = exception;
            defer owned_exception.deinit();
            return error.ExpectedUnsupported;
        },
    };
    defer unsupported.deinit();

    try support.expectExceptionContains(&vm, &unsupported, "Only already-settled promises");
    try support.expectExceptionContains(&vm, &unsupported, "TypeError");
}

// A module registered under a route key reports its public `/var/task` path through
// `import.meta`; the internal key never reaches tenant code.
test "deployed module import.meta speaks the /var/task namespace" {
    var vm = try support.createVm();
    defer vm.deinit();

    const source =
        \\export default import.meta.url + "|" + import.meta.filename + "|" + import.meta.dirname;
    ;
    const pack = try module_pack.buildSingleAlloc(std.testing.allocator, "/__collo_route/demo/api/index.js", source);
    defer std.testing.allocator.free(pack);
    try vm.registerModulePack(pack);

    try support.evaluateOk(&vm, "/__collo_route/demo/api/index.js");
    var entry = try support.getExportOk(&vm, "/__collo_route/demo/api/index.js", "default");
    defer entry.deinit();
    try support.expectValueString(
        &vm,
        &entry,
        "file:///var/task/api/index.js|/var/task/api/index.js|/var/task/api",
    );
}

// A `/var/task/<p>` specifier, as a plain path or as the `file:` URL `import.meta.url` gives,
// resolves to the route key under the hash `<d>` that the first deploy-scoped pack pinned on
// the VM, so a static import and an `import()` reach the same registered module.
test "public /var/task specifiers resolve back to registered deploy modules" {
    var vm = try support.createVm();
    defer vm.deinit();

    const entry_source =
        \\import fixed from "/var/task/lib/util.js";
        \\const lazy = (await import("file:///var/task/lib/util.js")).default;
        \\export default fixed + "|" + lazy;
    ;
    const pack = try module_pack.buildAlloc(std.testing.allocator, &.{
        .{ .specifier = "/__collo_route/demo/api/entry.js", .source = entry_source },
        .{ .specifier = "/__collo_route/demo/lib/util.js", .source = "export default 'util';" },
    }, 0);
    defer std.testing.allocator.free(pack);
    try vm.registerModulePack(pack);

    try support.evaluateOk(&vm, "/__collo_route/demo/api/entry.js");
    var entry = try support.getExportOk(&vm, "/__collo_route/demo/api/entry.js", "default");
    defer entry.deinit();
    try support.expectValueString(&vm, &entry, "util|util");
}

// The target of a relative `import()` from a route module is a route key, which loads from the
// pack like the module's static imports do.
test "dynamic import loads a module registered under a route key" {
    var vm = try support.createVm();
    defer vm.deinit();

    const entry_source =
        \\const lazy = await import("./lazy.js");
        \\export default lazy.default + "|" + (lazy === await import("/var/task/api/lazy.js"));
    ;
    const pack = try module_pack.buildAlloc(std.testing.allocator, &.{
        .{ .specifier = "/__collo_route/demo/api/entry.js", .source = entry_source },
        .{ .specifier = "/__collo_route/demo/api/lazy.js", .source = "export default 'lazy';" },
    }, 0);
    defer std.testing.allocator.free(pack);
    try vm.registerModulePack(pack);

    try support.evaluateOk(&vm, "/__collo_route/demo/api/entry.js");
    var entry = try support.getExportOk(&vm, "/__collo_route/demo/api/entry.js", "default");
    defer entry.deinit();
    try support.expectValueString(&vm, &entry, "lazy|true");
}

// Loader error text reaches tenant code, so a route key appears in it as its public `/var/task`
// path, never as the internal key with its hash.
test "loader errors for deploy modules speak the public /var/task namespace" {
    var vm = try support.createVm();
    defer vm.deinit();

    const entry_source =
        \\await import("/var/task/missing.js");
        \\export default 1;
    ;
    const pack = try module_pack.buildSingleAlloc(
        std.testing.allocator,
        "/__collo_route/demo/entry.js",
        entry_source,
    );
    defer std.testing.allocator.free(pack);
    try vm.registerModulePack(pack);

    var exception = try support.evaluateException(&vm, "/__collo_route/demo/entry.js");
    defer exception.deinit();
    // The specifier resolves to the internal key `/__collo_route/demo/missing.js`, and the
    // error names it and its importer by their public spellings.
    try support.expectExceptionContains(
        &vm,
        &exception,
        "Cannot find module '/var/task/missing.js' imported from '/var/task/entry.js'",
    );
}

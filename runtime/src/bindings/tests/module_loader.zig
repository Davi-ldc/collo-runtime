//! The bridge's module loader on VMs with no host runtime: the one pack a VM holds, refused
//! when a second arrives and replaceable after `unregisterModulePack`; a module's source read
//! from the pack only when it is first imported and wrapped in place, Latin-1 or UTF-16, so its
//! exports, `toString` results and stack frames match its UTF-8 file, also after the pack is
//! unregistered; resolving and evaluating in-memory ES modules under `/var/task` keys, `import()`
//! of a packed module and the module-not-found rejection of any other; the specifiers the loader
//! rejects, the zygote's warmup module in every spelling included; records and index entries that
//! point outside the pack; an empty module; `import.meta`; and what `Realm.promiseAwaitSync`
//! refuses. The pack format and its transcoding are covered in
//! `common/tests/ipc/module_pack.zig`; packs loaded from sealed memfds in a worker, a handler's
//! `import()` and top-level await settlement in `worker-test` (`worker/tests/runtime/modules.zig`
//! and `boot_eval.zig`). Lane: `bindings-test`.

const std = @import("std");
const ipc = @import("collo_ipc");
const support = @import("bindings_support");

const module_pack = ipc.module_pack;

/// Builds a pack of `modules`, with no routes, and registers it on `vm`.
fn registerModules(vm: *support.bindings.Vm, modules: []const module_pack.Module) !void {
    const pack = try module_pack.buildAlloc(std.testing.allocator, modules, &.{});
    defer std.testing.allocator.free(pack);
    try vm.registerModulePack(pack);
}

test "register evaluate and get export through root wrapper" {
    var vm = try support.createVm();
    defer vm.deinit();

    const source =
        \\export default "ok";
    ;

    try support.registerModule(&vm, "/var/task/module.js", source);
    try support.evaluateOk(&vm, "/var/task/module.js");

    var entry = try support.getExportOk(&vm, "/var/task/module.js", "default");
    defer entry.deinit();

    try support.expectValueString(&vm, &entry, "ok");
}

test "a host specifier is canonicalized before the pack is searched" {
    var vm = try support.createVm();
    defer vm.deinit();

    try registerModules(&vm, &.{
        .{ .specifier = "/var/task/dep.js", .source = "export default \"dep\";" },
        .{ .specifier = "/var/task/main.js", .source = "import dep from \"./dep.js\";\nexport default dep + \":ok\";" },
    });
    try support.evaluateOk(&vm, "/var/task/lib/.././main.js");

    var entry = try support.getExportOk(&vm, "/var/task/main.js", "default");
    defer entry.deinit();

    try support.expectValueString(&vm, &entry, "dep:ok");
}

test "dynamic import resolves registered in-memory modules" {
    var vm = try support.createVm();
    defer vm.deinit();

    try registerModules(&vm, &.{
        .{ .specifier = "/var/task/dep.js", .source = "export const value = \"dep\";\nexport default \"ok\";" },
        .{
            .specifier = "/var/task/dynamic.js",
            .source =
            \\const ns = await import("./dep.js");
            \\export default ns.value + ":" + ns.default;
            ,
        },
    });
    try support.evaluateOk(&vm, "/var/task/dynamic.js");

    var entry = try support.getExportOk(&vm, "/var/task/dynamic.js", "default");
    defer entry.deinit();

    try support.expectValueString(&vm, &entry, "dep:ok");
}

test "relative imports cannot climb above the root" {
    var vm = try support.createVm();
    defer vm.deinit();

    const source =
        \\import escaped from "../../../escape.js";
        \\export default escaped;
    ;

    try support.registerModule(&vm, "/var/task/main.js", source);

    var exception = try support.evaluateException(&vm, "/var/task/main.js");
    defer exception.deinit();

    try support.expectExceptionContains(&vm, &exception, "Invalid module specifier");
    try support.expectExceptionContains(&vm, &exception, "../../../escape.js");
    try support.expectExceptionContains(&vm, &exception, "/var/task/main.js");
}

test "bare module specifiers are rejected before fetch" {
    var vm = try support.createVm();
    defer vm.deinit();

    const source =
        \\import value from "react";
        \\export default value;
    ;

    try support.registerModule(&vm, "/var/task/bare.js", source);

    var exception = try support.evaluateException(&vm, "/var/task/bare.js");
    defer exception.deinit();

    try support.expectExceptionContains(&vm, &exception, "Invalid module specifier");
    try support.expectExceptionContains(&vm, &exception, "react");
}

test "default VM rejects node fs and bare fs module aliases" {
    var vm = try support.createVm();
    defer vm.deinit();

    try registerModules(&vm, &.{
        .{ .specifier = "/var/task/default-node-fs.js", .source = "import fs from \"node:fs\";\nexport default fs;" },
        .{ .specifier = "/var/task/default-bare-fs.js", .source = "import fs from \"fs\";\nexport default fs;" },
    });

    var node_exception = try support.evaluateException(&vm, "/var/task/default-node-fs.js");
    defer node_exception.deinit();
    try support.expectExceptionContains(&vm, &node_exception, "Invalid module specifier");
    try support.expectExceptionContains(&vm, &node_exception, "node:fs");

    var bare_exception = try support.evaluateException(&vm, "/var/task/default-bare-fs.js");
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
    try support.registerModule(&vm, "/var/task/default-node-fs-promises.js", node_source);
    var node_exception = try support.evaluateException(&vm, "/var/task/default-node-fs-promises.js");
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

    try support.registerModule(&vm, "/var/task/fs-import.js", source);
    try support.evaluateOk(&vm, "/var/task/fs-import.js");

    var entry = try support.getExportOk(&vm, "/var/task/fs-import.js", "default");
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

    try support.registerModule(&vm, "/var/task/fs-promises-import.js", source);
    try support.evaluateOk(&vm, "/var/task/fs-promises-import.js");

    var entry = try support.getExportOk(&vm, "/var/task/fs-promises-import.js", "default");
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

    try support.registerModule(&vm, "/var/task/node-path.js", source);

    var exception = try support.evaluateException(&vm, "/var/task/node-path.js");
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

    try support.registerModule(&vm, "/var/task/child-process.js", source);

    var exception = try support.evaluateException(&vm, "/var/task/child-process.js");
    defer exception.deinit();

    try support.expectExceptionContains(&vm, &exception, "Invalid module specifier");
    try support.expectExceptionContains(&vm, &exception, "child_process");
}

test "module pack registers dependency graph in one ABI call" {
    var vm = try support.createVm();
    defer vm.deinit();

    try registerModules(&vm, &.{
        .{
            .specifier = "/var/task/dep.js",
            .source =
            \\export const value = "dep";
            \\export default "ok";
            ,
        },
        .{
            .specifier = "/var/task/pack.js",
            .source =
            \\import dep, { value } from "./dep.js";
            \\export default value + ":" + dep;
            ,
        },
    });
    try support.evaluateOk(&vm, "/var/task/pack.js");

    var entry = try support.getExportOk(&vm, "/var/task/pack.js", "default");
    defer entry.deinit();

    try support.expectValueString(&vm, &entry, "dep:ok");
}

test "a second pack on one VM is refused and the first keeps serving" {
    var vm = try support.createVm();
    defer vm.deinit();

    try support.registerModule(&vm, "/var/task/first.js", "export default 'first';");

    const second = try module_pack.buildSingleAlloc(std.testing.allocator, "/var/task/second.js", "export default 'second';");
    defer std.testing.allocator.free(second);
    try std.testing.expectError(error.AlreadyExists, vm.registerModulePack(second));

    try support.evaluateOk(&vm, "/var/task/first.js");
    var entry = try support.getExportOk(&vm, "/var/task/first.js", "default");
    defer entry.deinit();
    try support.expectValueString(&vm, &entry, "first");

    var exception = try support.evaluateException(&vm, "/var/task/second.js");
    defer exception.deinit();
    try support.expectExceptionContains(&vm, &exception, "Cannot find module '/var/task/second.js'");
}

// The zygote's sequence: register its warmup pack, evaluate, unregister, and every worker forked
// later registers its definition's pack on the same VM. A module the first pack held and nobody
// evaluated is gone with it; one already evaluated stays in JSC's module registry.
test "a VM takes a new pack once the previous one is unregistered" {
    var vm = try support.createVm();
    defer vm.deinit();

    try registerModules(&vm, &.{
        .{ .specifier = "/var/task/a.js", .source = "export default 'a';" },
        .{ .specifier = "/var/task/a-lazy.js", .source = "export default 'a-lazy';" },
    });
    try support.evaluateOk(&vm, "/var/task/a.js");
    try vm.unregisterModulePack();
    try std.testing.expectError(error.InvalidArgument, vm.unregisterModulePack());

    try support.registerModule(&vm, "/var/task/b.js", "export default 'b';");
    try support.evaluateOk(&vm, "/var/task/b.js");
    var entry = try support.getExportOk(&vm, "/var/task/b.js", "default");
    defer entry.deinit();
    try support.expectValueString(&vm, &entry, "b");

    var exception = try support.evaluateException(&vm, "/var/task/a-lazy.js");
    defer exception.deinit();
    try support.expectExceptionContains(&vm, &exception, "Cannot find module '/var/task/a-lazy.js'");
}

test "unregistering a VM that holds no pack fails" {
    var vm = try support.createVm();
    defer vm.deinit();

    try std.testing.expectError(error.InvalidArgument, vm.unregisterModulePack());
}

// Registration checks only the header, so a record no import reaches is never read: a pack
// whose unused UTF-16 module has an odd source offset, which `module_pack.parse` would refuse,
// registers and serves its other module, and only an import of the broken one fails.
test "a module never imported is never read" {
    var vm = try support.createVm();
    defer vm.deinit();

    const pack = try module_pack.buildAlloc(std.testing.allocator, &.{
        .{ .specifier = "/var/task/good.js", .source = "export default 'good';" },
        .{ .specifier = "/var/task/bad.js", .source = "export default 'π';" },
    }, &.{});
    defer std.testing.allocator.free(pack);

    const parsed = try module_pack.parse(pack);
    const bad_index = parsed.findIndex("/var/task/bad.js").?;
    try std.testing.expectEqual(module_pack.Encoding.utf16le, parsed.moduleAt(bad_index).encoding);
    const field = @sizeOf(module_pack.Header) + bad_index * @sizeOf(module_pack.ModuleRecord) +
        @offsetOf(module_pack.ModuleRecord, "source_offset");
    const source_offset = std.mem.readInt(u32, pack[field..][0..4], .little);
    std.mem.writeInt(u32, pack[field..][0..4], source_offset + 1, .little);
    try std.testing.expectError(error.InvalidModulePack, module_pack.parse(pack));

    try vm.registerModulePack(pack);
    try support.evaluateOk(&vm, "/var/task/good.js");
    var entry = try support.getExportOk(&vm, "/var/task/good.js", "default");
    defer entry.deinit();
    try support.expectValueString(&vm, &entry, "good");

    var exception = try support.evaluateException(&vm, "/var/task/bad.js");
    defer exception.deinit();
    try support.expectExceptionContains(&vm, &exception, "Cannot find module '/var/task/bad.js'");
}

// The worker parses its pack before handing it over, but the loader checks every offset it reads
// itself: a record whose specifier or source lies outside the mapping, or an index entry naming a
// module past the count, names no module. Each corrupt value points gigabytes past the mapping, so a
// loader that read it without its check would fault instead of answering.
test "a record or index entry pointing outside the pack names no module" {
    var vm = try support.createVm();
    defer vm.deinit();

    const pack = try module_pack.buildAlloc(std.testing.allocator, &.{
        .{ .specifier = "/var/task/good.js", .source = "export default 'good';" },
        .{ .specifier = "/var/task/long-source.js", .source = "export default 1;" },
        .{ .specifier = "/var/task/far-specifier.js", .source = "export default 2;" },
        .{ .specifier = "/var/task/far-index.js", .source = "export default 3;" },
    }, &.{});
    defer std.testing.allocator.free(pack);

    // Every lookup through the parsed view happens before the bytes it borrows change.
    const parsed = try module_pack.parse(pack);
    const module_count = parsed.records.len;
    const long_source = parsed.findIndex("/var/task/long-source.js").?;
    const far_specifier = parsed.findIndex("/var/task/far-specifier.js").?;
    const far_index = parsed.findIndex("/var/task/far-index.js").?;
    const far = std.math.maxInt(u32) - 1;
    // `ColloModulePack::source`'s range check.
    writeRecordField(pack, long_source, "source_len", far);
    // `ColloModulePack::find`'s range check on the specifier.
    writeRecordField(pack, far_specifier, "specifier_offset", far);
    // `find`'s check that an entry names a module below the count.
    const index_offset = @sizeOf(module_pack.Header) + module_count * @sizeOf(module_pack.ModuleRecord);
    const index_capacity = std.mem.readInt(u32, pack[@offsetOf(module_pack.Header, "index_capacity")..][0..4], .little);
    var entries_changed: usize = 0;
    for (0..index_capacity) |slot| {
        const field = index_offset + slot * @sizeOf(module_pack.IndexEntry) + @offsetOf(module_pack.IndexEntry, "module_index");
        if (std.mem.readInt(u32, pack[field..][0..4], .little) == far_index) {
            std.mem.writeInt(u32, pack[field..][0..4], far, .little);
            entries_changed += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), entries_changed);
    try std.testing.expectError(error.InvalidModulePack, module_pack.parse(pack));

    try vm.registerModulePack(pack);
    try support.evaluateOk(&vm, "/var/task/good.js");
    var entry = try support.getExportOk(&vm, "/var/task/good.js", "default");
    defer entry.deinit();
    try support.expectValueString(&vm, &entry, "good");

    for ([_][]const u8{ "/var/task/long-source.js", "/var/task/far-specifier.js", "/var/task/far-index.js" }) |key| {
        var exception = try support.evaluateException(&vm, key);
        defer exception.deinit();
        const expected = try std.fmt.allocPrint(std.testing.allocator, "Cannot find module '{s}'", .{key});
        defer std.testing.allocator.free(expected);
        try support.expectExceptionContains(&vm, &exception, expected);
    }
}

fn writeRecordField(pack: []u8, module_index: usize, comptime field_name: []const u8, value: u32) void {
    const field = @sizeOf(module_pack.Header) + module_index * @sizeOf(module_pack.ModuleRecord) +
        @offsetOf(module_pack.ModuleRecord, field_name);
    std.mem.writeInt(u32, pack[field..][0..4], value, .little);
}

// The zygote evaluates its warmup corpus under `/__collo/zygote/` and unregisters the pack, but
// JSC's module registry keeps the evaluated record, and every worker inherits it. Tenant code must
// not reach it by any spelling a static or dynamic import can take, eval'd code with no referrer
// included.
test "tenant code cannot import the zygote's warmup module in any spelling" {
    var vm = try support.createVm();
    defer vm.deinit();

    try support.registerModule(&vm, "/__collo/zygote/x.js", "export default 'zygote';");
    try support.evaluateOk(&vm, "/__collo/zygote/x.js");
    try vm.unregisterModulePack();

    try registerModules(&vm, &.{
        .{ .specifier = "/var/task/static.js", .source = "import z from \"/__collo/zygote/x.js\";\nexport default z;" },
        .{
            .specifier = "/var/task/dynamic.js",
            .source =
            \\const spellings = [
            \\  "/__collo/zygote/x.js",
            \\  "file:///__collo/zygote/x.js",
            \\  "/var/task/../../__collo/zygote/x.js",
            \\  "../../__collo/zygote/x.js",
            \\  "file:///var/task/..%2F..%2F__collo/zygote/x.js",
            \\];
            \\const outcomes = [];
            \\for (const spelling of spellings)
            \\  outcomes.push(await import(spelling).then(() => "loaded", () => "rejected"));
            \\outcomes.push(await (0, eval)('import("/__collo/zygote/x.js")').then(() => "loaded", () => "rejected"));
            \\outcomes.push(await new Function('return import("/__collo/zygote/x.js")')().then(() => "loaded", () => "rejected"));
            \\export default outcomes.join(",");
            ,
        },
    });

    var static_exception = try support.evaluateException(&vm, "/var/task/static.js");
    defer static_exception.deinit();
    try support.expectExceptionContains(&vm, &static_exception, "Invalid module specifier '/__collo/zygote/x.js'");

    try support.evaluateOk(&vm, "/var/task/dynamic.js");
    var outcomes = try support.getExportOk(&vm, "/var/task/dynamic.js", "default");
    defer outcomes.deinit();
    try support.expectValueString(&vm, &outcomes, "rejected,rejected,rejected,rejected,rejected,rejected,rejected");
}

// An empty source is wrapped as the static empty string, not as an external string over no bytes.
test "an empty module evaluates and its importer sees no exports" {
    var vm = try support.createVm();
    defer vm.deinit();

    try registerModules(&vm, &.{
        .{ .specifier = "/var/task/empty.js", .source = "" },
        .{
            .specifier = "/var/task/main.js",
            .source =
            \\import * as ns from "./empty.js";
            \\export default Object.keys(ns).length + ":ok";
            ,
        },
    });
    try support.evaluateOk(&vm, "/var/task/main.js");
    var entry = try support.getExportOk(&vm, "/var/task/main.js", "default");
    defer entry.deinit();
    try support.expectValueString(&vm, &entry, "0:ok");
}

// A source is an external string over the pack's mapping, and a function's `toString` reads that
// source. The string holds the mapping, so text read before the pack is unregistered, and text read
// after it from a function the pack defined, stay intact through a full collection.
test "a toString result outlives the unregistered pack" {
    var vm = try support.createVm();
    defer vm.deinit();

    const source =
        \\export function greet() { return "héllo"; }
        \\export const text = greet.toString();
        \\export default function show() { return greet.toString(); }
    ;
    try support.registerModule(&vm, "/var/task/greet.js", source);
    try support.evaluateOk(&vm, "/var/task/greet.js");

    var text = try support.getExportOk(&vm, "/var/task/greet.js", "text");
    defer text.deinit();
    var show = try support.getExportOk(&vm, "/var/task/greet.js", "default");
    defer show.deinit();

    try vm.unregisterModulePack();
    try vm.collectFullGCAndTrim();

    const expected = "function greet() { return \"héllo\"; }";
    try support.expectValueString(&vm, &text, expected);

    var exec_ctx = support.makeExecCtx(7);
    try vm.turnEnter(&exec_ctx);
    defer vm.turnExit() catch {};
    var shown = try support.invokeOk(&vm, &exec_ctx, &show, &.{});
    defer shown.deinit();
    try support.expectValueString(&vm, &shown, expected);
}

// Characters above U+00FF make the pack store the module as UTF-16, an astral one as a surrogate
// pair; values and `toString` must still read back as the UTF-8 file says.
test "a non-Latin-1 module evaluates and stringifies as its UTF-8 source" {
    var vm = try support.createVm();
    defer vm.deinit();

    const source =
        \\export const text = "π 😀";
        \\export function f() { return "Ωmega 🎉"; }
        \\export const body = f.toString();
    ;
    try support.registerModule(&vm, "/var/task/wide.js", source);
    try support.evaluateOk(&vm, "/var/task/wide.js");

    var text = try support.getExportOk(&vm, "/var/task/wide.js", "text");
    defer text.deinit();
    try support.expectValueString(&vm, &text, "π 😀");

    var body = try support.getExportOk(&vm, "/var/task/wide.js", "body");
    defer body.deinit();
    try support.expectValueString(&vm, &body, "function f() { return \"Ωmega 🎉\"; }");
}

test "a Latin-1 module with non-ASCII text evaluates and stringifies as its UTF-8 source" {
    var vm = try support.createVm();
    defer vm.deinit();

    const source =
        \\export const text = "café ñ";
        \\export function f() { return "déjà"; }
        \\export const body = f.toString();
    ;
    try support.registerModule(&vm, "/var/task/latin1.js", source);
    try support.evaluateOk(&vm, "/var/task/latin1.js");

    var text = try support.getExportOk(&vm, "/var/task/latin1.js", "text");
    defer text.deinit();
    try support.expectValueString(&vm, &text, "café ñ");

    var body = try support.getExportOk(&vm, "/var/task/latin1.js", "body");
    defer body.deinit();
    try support.expectValueString(&vm, &body, "function f() { return \"déjà\"; }");
}

test "a module that starts with a byte order mark evaluates" {
    var vm = try support.createVm();
    defer vm.deinit();

    try support.registerModule(&vm, "/var/task/bom.js", "\xEF\xBB\xBFexport default 'bom';");
    try support.evaluateOk(&vm, "/var/task/bom.js");

    var entry = try support.getExportOk(&vm, "/var/task/bom.js", "default");
    defer entry.deinit();
    try support.expectValueString(&vm, &entry, "bom");
}

test "invalid UTF-8 in a module reads back as U+FFFD" {
    var vm = try support.createVm();
    defer vm.deinit();

    try support.registerModule(&vm, "/var/task/invalid.js", "export default 'a\xFFb';");
    try support.evaluateOk(&vm, "/var/task/invalid.js");

    var entry = try support.getExportOk(&vm, "/var/task/invalid.js", "default");
    defer entry.deinit();
    try support.expectValueString(&vm, &entry, "a\u{FFFD}b");
}

test "a stack trace names a module by its file URL" {
    var vm = try support.createVm();
    defer vm.deinit();

    try support.registerModule(&vm, "/var/task/api/stack.js", "export const stack = new Error('where').stack;");
    try support.evaluateOk(&vm, "/var/task/api/stack.js");

    var stack = try support.getExportOk(&vm, "/var/task/api/stack.js", "stack");
    defer stack.deinit();
    var text = try support.valueString(vm.mainRealm(), &stack);
    defer text.deinit();
    try std.testing.expect(std.mem.indexOf(u8, text.slice(), "file:///var/task/api/stack.js") != null);
}

test "dynamic import of a module the pack does not hold rejects as not found, naming its importer" {
    var vm = try support.createVm();
    defer vm.deinit();

    const source =
        \\await import("./missing.js");
        \\export default 1;
    ;

    try support.registerModule(&vm, "/var/task/dynamic-missing.js", source);

    var exception = try support.evaluateException(&vm, "/var/task/dynamic-missing.js");
    defer exception.deinit();

    try support.expectExceptionContains(&vm, &exception, "Cannot find module '/var/task/missing.js'");
    try support.expectExceptionContains(&vm, &exception, "imported from '/var/task/dynamic-missing.js'");
}

test "top level await returns pending evaluation" {
    var vm = try support.createVm();
    defer vm.deinit();

    const source =
        \\await new Promise(() => {});
        \\export default 1;
    ;

    try support.registerModule(&vm, "/var/task/await.js", source);
    // With no host runtime, as on the zygote's VM, evaluation registers no settlement callback
    // but still reports pending (`awaitModulePromiseSync` in `jsc/runtime/module_loader.cpp`).
    try support.evaluatePending(&vm, "/var/task/await.js");
    // Evaluating it again while pending reports pending again: JSC hands a re-import of an
    // async-evaluating module its pending capability, and with a host runtime each evaluation
    // registers a settlement of its own. Routes that share an entry in one realm rely on this
    // (`worker/tests/runtime/routes.zig`).
    try support.evaluatePending(&vm, "/var/task/await.js");
}

test "promise await sync inside a turn returns invalid argument" {
    var vm = try support.createVm();
    defer vm.deinit();

    const source =
        \\export default function makePromise() {
        \\    return Promise.resolve("ok");
        \\}
    ;

    try support.registerModule(&vm, "/var/task/promise.js", source);
    try support.evaluateOk(&vm, "/var/task/promise.js");

    var make_promise = try support.getExportOk(&vm, "/var/task/promise.js", "default");
    defer make_promise.deinit();

    var exec_ctx = support.makeExecCtx(42);
    try vm.turnEnter(&exec_ctx);
    defer vm.turnExit() catch {};

    var promise = try support.invokeOk(&vm, &exec_ctx, &make_promise, &.{});
    defer promise.deinit();

    try std.testing.expectError(error.InvalidArgument, vm.mainRealm().promiseAwaitSync(&promise));
}

test "promise await sync rejects pending external promises" {
    var vm = try support.createVm();
    defer vm.deinit();

    const source =
        \\export const pending = new Promise(() => {});
    ;

    try support.registerModule(&vm, "/var/task/pending-promise.js", source);
    try support.evaluateOk(&vm, "/var/task/pending-promise.js");

    var pending = try support.getExportOk(&vm, "/var/task/pending-promise.js", "pending");
    defer pending.deinit();

    var unsupported = switch (try vm.mainRealm().promiseAwaitSync(&pending)) {
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

test "a module's import.meta names its /var/task path" {
    var vm = try support.createVm();
    defer vm.deinit();

    const source =
        \\export default import.meta.url + "|" + import.meta.filename + "|" + import.meta.dirname;
    ;
    try support.registerModule(&vm, "/var/task/api/index.js", source);

    try support.evaluateOk(&vm, "/var/task/api/index.js");
    var entry = try support.getExportOk(&vm, "/var/task/api/index.js", "default");
    defer entry.deinit();
    try support.expectValueString(
        &vm,
        &entry,
        "file:///var/task/api/index.js|/var/task/api/index.js|/var/task/api",
    );
}

// An absolute `/var/task/<p>` specifier, as a plain path or as the `file:` URL
// `import.meta.url` gives, names the pack's key itself, so a static import and an `import()`
// reach the same module.
test "absolute paths and file URLs resolve to pack modules" {
    var vm = try support.createVm();
    defer vm.deinit();

    try registerModules(&vm, &.{
        .{
            .specifier = "/var/task/api/entry.js",
            .source =
            \\import fixed from "/var/task/lib/util.js";
            \\const lazy = (await import("file:///var/task/lib/util.js")).default;
            \\export default fixed + "|" + lazy;
            ,
        },
        .{ .specifier = "/var/task/lib/util.js", .source = "export default 'util';" },
    });

    try support.evaluateOk(&vm, "/var/task/api/entry.js");
    var entry = try support.getExportOk(&vm, "/var/task/api/entry.js", "default");
    defer entry.deinit();
    try support.expectValueString(&vm, &entry, "util|util");
}

// The target of a relative `import()` is a key, which loads from the pack like the module's
// static imports do, and the same key spelled absolutely is the same module instance.
test "dynamic import loads a pack module by relative and by absolute path" {
    var vm = try support.createVm();
    defer vm.deinit();

    try registerModules(&vm, &.{
        .{
            .specifier = "/var/task/api/entry.js",
            .source =
            \\const lazy = await import("./lazy.js");
            \\export default lazy.default + "|" + (lazy === await import("/var/task/api/lazy.js"));
            ,
        },
        .{ .specifier = "/var/task/api/lazy.js", .source = "export default 'lazy';" },
    });

    try support.evaluateOk(&vm, "/var/task/api/entry.js");
    var entry = try support.getExportOk(&vm, "/var/task/api/entry.js", "default");
    defer entry.deinit();
    try support.expectValueString(&vm, &entry, "lazy|true");
}

// Loader error text reaches tenant code, which sees each module by its key, the same path
// `import.meta.filename` gives.
test "loader errors name modules by their keys" {
    var vm = try support.createVm();
    defer vm.deinit();

    const entry_source =
        \\await import("/var/task/missing.js");
        \\export default 1;
    ;
    try support.registerModule(&vm, "/var/task/entry.js", entry_source);

    var exception = try support.evaluateException(&vm, "/var/task/entry.js");
    defer exception.deinit();
    try support.expectExceptionContains(
        &vm,
        &exception,
        "Cannot find module '/var/task/missing.js' imported from '/var/task/entry.js'",
    );
}

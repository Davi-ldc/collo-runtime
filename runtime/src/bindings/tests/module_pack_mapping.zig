//! Ownership of the pack mapping `collo_module_register_pack` consumes: the
//! bridge releases it through `collo_runtime_mapping_release` exactly once,
//! before returning when it keeps no module, otherwise when the last
//! SourceProvider pointing into it dies. `bindings.liveMappingCount` observes
//! each release; a double release shows up as a count below the baseline. The
//! worker's refusal of an unsealed pack fd is covered in
//! `worker/tests/runtime/modules.zig`. Lanes: `bindings-test` and both
//! bindings smokes, which add leak and invalid-access checks to these paths.

const std = @import("std");
const support = @import("bindings_support");

const bindings = support.bindings;
const module_pack = support.module_pack;

fn buildPack(specifier: []const u8, source: []const u8) ![]u8 {
    return module_pack.buildSingleAlloc(std.testing.allocator, specifier, source);
}

fn expectLive(expected: usize) !void {
    try std.testing.expectEqual(expected, bindings.liveMappingCount());
}

test "a registered pack stays mapped until its VM is destroyed" {
    const baseline = bindings.liveMappingCount();
    const pack = try buildPack("/mapping/kept.js", "export default 'kept';");
    defer std.testing.allocator.free(pack);

    var vm = try support.createVm();
    var vm_alive = true;
    defer if (vm_alive) vm.deinit();

    try vm.registerModulePack(pack);
    try expectLive(baseline + 1);

    // Evaluation hands the providers to JSC as well; the mapping must
    // outlive every one of them, not only the registry entry.
    try support.evaluateOk(&vm, "/mapping/kept.js");
    var entry = try support.getExportOk(&vm, "/mapping/kept.js", "default");
    try support.expectValueString(&vm, &entry, "kept");
    entry.deinit();
    try expectLive(baseline + 1);

    vm.deinit();
    vm_alive = false;
    try expectLive(baseline);
}

test "a pack that fails validation is released before registration returns" {
    const baseline = bindings.liveMappingCount();
    var vm = try support.createVm();
    defer vm.deinit();

    const pack = try buildPack("/mapping/corrupt.js", "export default 1;");
    defer std.testing.allocator.free(pack);
    pack[0] ^= 0xff;

    try std.testing.expectError(error.InvalidArgument, vm.registerModulePack(pack));
    try expectLive(baseline);
}

test "rejected register options still release the pack" {
    const baseline = bindings.liveMappingCount();
    var vm = try support.createVm();
    defer vm.deinit();

    const pack = try buildPack("/mapping/bad-options.js", "export default 1;");
    defer std.testing.allocator.free(pack);

    try std.testing.expectError(error.InvalidArgument, vm.registerModulePackWithOptions(pack, .{ .lifetime = 99 }));
    try expectLive(baseline);
}

test "a pack whose modules are already registered is released at once" {
    const baseline = bindings.liveMappingCount();
    const pack = try buildPack("/mapping/duplicate.js", "export default 1;");
    defer std.testing.allocator.free(pack);

    var vm = try support.createVm();
    var vm_alive = true;
    defer if (vm_alive) vm.deinit();

    try vm.registerModulePack(pack);
    try expectLive(baseline + 1);
    try vm.registerModulePack(pack);
    try expectLive(baseline + 1);

    vm.deinit();
    vm_alive = false;
    try expectLive(baseline);
}

test "evicting the last module of a pack releases its mapping" {
    const baseline = bindings.liveMappingCount();
    var vm = try support.createVm();
    defer vm.deinit();

    const pack = try module_pack.buildAlloc(std.testing.allocator, &.{
        .{ .specifier = "/mapping/evict-a.js", .source = "export default 'a';" },
        .{ .specifier = "/mapping/evict-b.js", .source = "export default 'b';" },
    }, 0);
    defer std.testing.allocator.free(pack);

    try vm.registerModulePack(pack);
    try expectLive(baseline + 1);

    const first = try vm.evictModuleSpecifier("/mapping/evict-a.js");
    try std.testing.expectEqual(@as(usize, 1), first.sources_removed);
    try expectLive(baseline + 1);

    const second = try vm.evictModuleSpecifier("/mapping/evict-b.js");
    try std.testing.expectEqual(@as(usize, 1), second.sources_removed);
    try expectLive(baseline);
}

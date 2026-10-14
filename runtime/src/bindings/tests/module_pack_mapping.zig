//! Ownership of the pack mapping `collo_module_register_pack` consumes: the
//! bridge ends it through `collo_runtime_mapping_release` exactly once, before
//! returning when it refuses the pack, otherwise once the VM's registration
//! and every module source string over it are gone, which for a module JSC
//! evaluated is when the VM is destroyed. `bindings.liveMappingCount` observes
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
    const pack = try buildPack("/var/task/mapping/kept.js", "export default 'kept';");
    defer std.testing.allocator.free(pack);

    var vm = try support.createVm();
    var vm_alive = true;
    defer if (vm_alive) vm.deinit();

    try vm.registerModulePack(pack);
    try expectLive(baseline + 1);

    // Evaluation hands the module's provider to JSC as well; the mapping must
    // outlive it, not only the registration.
    try support.evaluateOk(&vm, "/var/task/mapping/kept.js");
    var entry = try support.getExportOk(&vm, "/var/task/mapping/kept.js", "default");
    try support.expectValueString(&vm, &entry, "kept");
    entry.deinit();
    try expectLive(baseline + 1);

    vm.deinit();
    vm_alive = false;
    try expectLive(baseline);
}

test "a pack that fails the header check is released before registration returns" {
    const baseline = bindings.liveMappingCount();
    var vm = try support.createVm();
    defer vm.deinit();

    const pack = try buildPack("/var/task/mapping/corrupt.js", "export default 1;");
    defer std.testing.allocator.free(pack);
    pack[0] ^= 0xff;

    try std.testing.expectError(error.InvalidArgument, vm.registerModulePack(pack));
    try expectLive(baseline);
}

test "a second pack is refused and released before registration returns" {
    const baseline = bindings.liveMappingCount();
    const first = try buildPack("/var/task/mapping/first.js", "export default 1;");
    defer std.testing.allocator.free(first);
    const second = try buildPack("/var/task/mapping/second.js", "export default 2;");
    defer std.testing.allocator.free(second);

    var vm = try support.createVm();
    var vm_alive = true;
    defer if (vm_alive) vm.deinit();

    try vm.registerModulePack(first);
    try expectLive(baseline + 1);
    try std.testing.expectError(error.AlreadyExists, vm.registerModulePack(second));
    try expectLive(baseline + 1);

    vm.deinit();
    vm_alive = false;
    try expectLive(baseline);
}

// No provider exists before a module's first fetch, so a pack nobody imported
// from has no source string over it, and unregistering it ends the mapping.
test "unregistering a pack no module was fetched from releases its mapping at once" {
    const baseline = bindings.liveMappingCount();
    var vm = try support.createVm();
    defer vm.deinit();

    const pack = try module_pack.buildAlloc(std.testing.allocator, &.{
        .{ .specifier = "/var/task/mapping/idle-a.js", .source = "export default 'a';" },
        .{ .specifier = "/var/task/mapping/idle-b.js", .source = "export default 'b';" },
    }, &.{});
    defer std.testing.allocator.free(pack);

    try vm.registerModulePack(pack);
    try expectLive(baseline + 1);

    try vm.unregisterModulePack();
    try expectLive(baseline);
}

// JSC's module registry keeps an evaluated module's provider, whose source
// string holds the mapping, so the mapping outlives the registration and ends
// with the VM.
test "an evaluated module keeps an unregistered pack mapped until its VM is destroyed" {
    const baseline = bindings.liveMappingCount();
    const pack = try buildPack("/var/task/mapping/evaluated.js", "export default 'evaluated';");
    defer std.testing.allocator.free(pack);

    var vm = try support.createVm();
    var vm_alive = true;
    defer if (vm_alive) vm.deinit();

    try vm.registerModulePack(pack);
    try support.evaluateOk(&vm, "/var/task/mapping/evaluated.js");
    try vm.unregisterModulePack();
    try vm.collectFullGCAndTrim();
    try expectLive(baseline + 1);

    vm.deinit();
    vm_alive = false;
    try expectLive(baseline);
}

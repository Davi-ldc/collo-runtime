//! Reseeding after fork: `Vm.reseedAfterFork` replaces the global object's weak random seed,
//! which `Math.random` draws from, along with the VM's and the heap's seeds, so each worker
//! draws a sequence of its own instead of replaying the zygote's. These tests reseed fresh VMs
//! in this process without forking, through `sampleRandomWithSeeds` in
//! `runtime/tests/support/bindings/root.zig`. Where the reseed sits in a real worker's boot is
//! covered in `zygote-integration`.

const std = @import("std");
const support = @import("bindings_support");
const bindings = support.bindings;

test "same reseed inputs produce the same first Math.random result" {
    const seeds = bindings.RandomSeeds{
        .weak_random_seed = 11,
        .vm_random_seed = 22,
        .heap_random_seed = 33,
    };

    var first = try support.sampleRandomWithSeeds(seeds);
    defer first.deinit();

    var second = try support.sampleRandomWithSeeds(seeds);
    defer second.deinit();

    try std.testing.expectEqualStrings(first.slice(), second.slice());
}

test "different reseed inputs produce different first Math.random result" {
    var left = try support.sampleRandomWithSeeds(.{
        .weak_random_seed = 44,
        .vm_random_seed = 55,
        .heap_random_seed = 66,
    });
    defer left.deinit();

    var right = try support.sampleRandomWithSeeds(.{
        .weak_random_seed = 77,
        .vm_random_seed = 88,
        .heap_random_seed = 99,
    });
    defer right.deinit();

    try std.testing.expect(!std.mem.eql(u8, left.slice(), right.slice()));
}

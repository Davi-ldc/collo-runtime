//! What the engine measures memory against and reports about it: the memory status override
//! that points it at a cgroup's `memory.current` and a limit (`collo_set_memory_status_override`
//! in `abi.h`, implemented in `jsc/zygote/prepare_for_fork.cpp`), the heap statistics that count
//! a cell's outside memory (`collo_vm_heap_stats`), the override's clear in a fork child
//! (`collo_vm_post_fork_child`), and the refusals of the process-wide settings that would
//! otherwise reach an engine assertion. A worker reading its own leaf is
//! covered in `zygote-integration`. Lane: `bindings-test`.

const std = @import("std");
const support = @import("bindings_support");
const bindings = support.bindings;

/// A memfd holding `contents` at offset 0 and nothing after it, standing in for a cgroup's
/// `memory.current`. The caller closes it.
fn memoryCurrentFile(contents: []const u8) !std.posix.fd_t {
    const fd = try std.posix.memfd_create("collo-memory-current", std.os.linux.MFD.CLOEXEC);
    errdefer std.posix.close(fd);
    try rewrite(fd, contents);
    return fd;
}

fn rewrite(fd: std.posix.fd_t, contents: []const u8) !void {
    try std.posix.ftruncate(fd, 0);
    var written: usize = 0;
    while (written < contents.len) {
        const count = try std.posix.pwrite(fd, contents[written..], written);
        if (count == 0) return error.ShortWrite;
        written += count;
    }
}

test "the memory status override reads its descriptor's byte count against the limit" {
    const fd = try memoryCurrentFile("900000000\n");
    defer std.posix.close(fd);

    try bindings.setMemoryStatusOverride(1_000_000_000, fd);
    defer bindings.clearMemoryStatusOverride();

    // 0.9 has no exact binary form, so the share is rounded, not truncated to 899,999.
    const status = try bindings.memoryStatus();
    try std.testing.expectEqual(@as(u64, 900_000_000), status.footprint_bytes);
    try std.testing.expectEqual(@as(u32, 900_000), status.in_use_per_million);

    // Each reading goes back to the descriptor, and one that holds no number reads as nothing
    // in use, as the engine's own reading does when it fails.
    try rewrite(fd, "not a number\n");
    const unreadable = try bindings.memoryStatus();
    try std.testing.expectEqual(@as(u64, 0), unreadable.footprint_bytes);
    try std.testing.expectEqual(@as(u32, 0), unreadable.in_use_per_million);

    // A footprint above the limit is capped at the whole of it.
    try rewrite(fd, "2000000000\n");
    const over = try bindings.memoryStatus();
    try std.testing.expectEqual(@as(u32, 1_000_000), over.in_use_per_million);
}

test "clearing the memory status override returns the engine to its own reading" {
    const fd = try memoryCurrentFile("900000000\n");
    defer std.posix.close(fd);

    try bindings.setMemoryStatusOverride(1_000_000_000, fd);
    bindings.clearMemoryStatusOverride();

    // The test process's own resident size, which is neither 0 nor the descriptor's number.
    const status = try bindings.memoryStatus();
    try std.testing.expect(status.footprint_bytes != 0);
    try std.testing.expect(status.footprint_bytes != 900_000_000);
}

test "a fork child starts from the engine's own memory reading, whatever override its parent set" {
    var vm = try support.createVm();
    defer vm.deinit();
    const fd = try memoryCurrentFile("900000000\n");
    defer std.posix.close(fd);

    try bindings.setMemoryStatusOverride(1_000_000_000, fd);
    defer bindings.clearMemoryStatusOverride();
    try vm.postForkChild();

    // The test process's own resident size, as after a clear.
    const status = try bindings.memoryStatus();
    try std.testing.expect(status.footprint_bytes != 0);
    try std.testing.expect(status.footprint_bytes != 900_000_000);
}

test "a memory status override with no limit or no descriptor is refused" {
    const fd = try memoryCurrentFile("1\n");
    defer std.posix.close(fd);

    try std.testing.expectError(error.InvalidArgument, bindings.setMemoryStatusOverride(0, fd));
    try std.testing.expectError(error.InvalidArgument, bindings.setMemoryStatusOverride(1_000_000_000, -1));
}

test "a helper-thread cache release with no idle interval is refused" {
    try std.testing.expectError(error.InvalidArgument, bindings.setHelperThreadsCacheReleaseNs(0));
    // The calling thread's own release needs no VM and no override.
    bindings.releaseThreadAllocatorCache();
}

test "heap statistics count an ArrayBuffer's bytes as the heap's extra memory, within its size and capacity" {
    var vm = try support.createVm();
    defer vm.deinit();

    const source =
        \\export default function hold(size) {
        \\    globalThis.held = new ArrayBuffer(size);
        \\    new Uint8Array(globalThis.held).fill(1);
        \\    return "held";
        \\}
    ;
    try support.registerModule(&vm, "/hold.js", source);
    try support.evaluateOk(&vm, "/hold.js");
    var hold = try support.getExportOk(&vm, "/hold.js", "default");
    defer hold.deinit();

    // Full collections on both sides, so neither reading carries garbage the other does not.
    const held_bytes = 8 * 1024 * 1024;
    try vm.collectFullGCAndTrim();
    const before = try vm.heapStats();

    var size = try vm.numberValue(held_bytes);
    defer size.deinit();
    var exec_ctx = support.makeExecCtx(61);
    try vm.turnEnter(&exec_ctx);
    const result = support.invokeOk(&vm, &exec_ctx, &hold, &.{&size});
    try vm.turnExit();
    var held = try result;
    held.deinit();

    try vm.collectFullGCAndTrim();
    const after = try vm.heapStats();

    try std.testing.expect(after.extra_memory_bytes >= before.extra_memory_bytes + held_bytes);
    try std.testing.expect(after.size_bytes >= after.extra_memory_bytes);
    // The marked cells sit in the blocks the capacity counts.
    try std.testing.expect(after.capacity_bytes >= after.size_bytes);
}

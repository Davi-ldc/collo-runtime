//! The reaper's readings in `server/supervisor/reaper/memory.zig`: what a
//! failed read of node memory stands on, and the PSI trigger on
//! `/proc/pressure/memory`, its bytes checked on a pipe and the trigger armed
//! on the live kernel. The pressure bands and the victim score are covered in
//! `reaping.zig`. Lane `server-supervisor-test`.

const std = @import("std");
const supervision = @import("collo_server_supervisor");

const memory = supervision.reaper.memory;
const memory_limits = supervision.scheduler_limits.memory;

test "a failed read stands on the last reading, 0% included, and on critical before any reading or for want of memory" {
    var last: memory.LastReading = .{};

    // Nothing was read yet, so a failure cannot answer calm.
    try std.testing.expectEqual(memory.MemoryPressureMode.critical, last.settle(error.FileNotFound).mode);

    // A real reading of 0% is remembered like any other, and the next failure
    // acts on it.
    try std.testing.expectEqual(@as(u8, 0), last.settle(memory.memoryPressureFromUsedPercent(0)).used_percent);
    const after_calm = last.settle(error.FileNotFound);
    try std.testing.expectEqual(memory.MemoryPressureMode.none, after_calm.mode);
    try std.testing.expectEqual(@as(u8, 0), after_calm.used_percent);

    // A read that failed for want of memory is critical whatever came before,
    // and that stand-in is no reading: the next failure acts on 0% again.
    try std.testing.expectEqual(memory.MemoryPressureMode.critical, last.settle(error.OutOfMemory).mode);
    try std.testing.expectEqual(@as(u8, 0), last.settle(error.FileNotFound).used_percent);

    // A newer reading replaces the last.
    _ = last.settle(memory.memoryPressureFromUsedPercent(88));
    try std.testing.expectEqual(memory.MemoryPressureMode.hard, last.settle(error.FileNotFound).mode);
}

test "the PSI trigger goes out as the trigger text followed by the NUL the kernel's parser needs" {
    const pipe = try std.posix.pipe2(.{ .CLOEXEC = true });
    defer std.posix.close(pipe[0]);
    {
        defer std.posix.close(pipe[1]);
        try memory.armPsiTrigger(pipe[1]);
    }

    var buffer: [64]u8 = undefined;
    const length = try std.posix.read(pipe[0], &buffer);
    // The kernel overwrites the last byte of the write with its terminator,
    // so that byte must be a NUL of its own and not the window's last digit.
    try std.testing.expectEqualStrings(memory_limits.psi_some_trigger ++ "\x00", buffer[0..length]);
    try std.testing.expectEqual(@as(usize, 0), try std.posix.read(pipe[0], &buffer));
}

test "the PSI trigger arms on a kernel that offers PSI to a process without CAP_SYS_RESOURCE" {
    var wake = memory.MemoryPressureWake.init() catch |err| switch (err) {
        // The kernel was built or booted without PSI, so the pressure file does not exist.
        error.FileNotFound => return error.SkipZigTest,
        // Below Linux 6.4 the kernel refuses a trigger to a process without CAP_SYS_RESOURCE.
        error.AccessDenied, error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer wake.deinit();
    try std.testing.expect(wake.fd >= 0);
}

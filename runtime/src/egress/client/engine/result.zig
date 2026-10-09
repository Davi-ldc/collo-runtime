//! Settles a fetch task: stores its result, or only marks a canceled task
//! done, and wakes the consumer with the task's ready token, all under
//! `task.mutex`. A failure whose message cannot be allocated publishes a
//! static out-of-memory message instead, so every path settles the task.

const std = @import("std");
const task_model = @import("../task.zig");

pub fn completeCanceled(task: *task_model.Task, wake_ctx: ?*anyopaque, wake_fn: anytype) void {
    task.mutex.lock();
    const ready = task.readyToken();
    task.done = true;
    wake_fn(wake_ctx, .{ .task_ready = ready });
    task.mutex.unlock();
}

pub fn publishFailure(task: *task_model.Task, err: anyerror, wake_ctx: ?*anyopaque, wake_fn: anytype) void {
    const message = std.fmt.allocPrint(task.resultAllocator(), "fetch failed: {s}", .{@errorName(err)}) catch {
        publishResult(task, .{ .failure = .{ .message = "fetch failed: out of memory", .owned = false } }, wake_ctx, wake_fn);
        return;
    };
    publishResult(task, .{ .failure = .{ .message = message, .owned = true } }, wake_ctx, wake_fn);
}

pub fn publishResult(
    task: *task_model.Task,
    result: task_model.Result,
    wake_ctx: ?*anyopaque,
    wake_fn: anytype,
) void {
    task.mutex.lock();
    const ready = task.readyToken();
    if (task.result) |*old_result|
        old_result.deinit();
    task.result = result;
    task.done = true;
    wake_fn(wake_ctx, .{ .task_ready = ready });
    task.mutex.unlock();
}

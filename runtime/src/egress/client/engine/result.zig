//! Settles a fetch task: stores its result, or only marks a canceled task
//! done, under `task.mutex`, then wakes the gateway with the task's ready
//! token. The wake runs after the mutex is released, so the gateway's wake
//! path (its ready ring's lock, its eventfd) never nests inside a task's
//! lock; the caller's task reference keeps the task alive across it. A
//! failure whose message cannot be allocated publishes a static message
//! instead, so every path settles the task. A task is settled once: the
//! owner holds each fetch in exactly one place, and that place settles it.
//!
//! A hop the network policy refused (`transport.denialOf`) fails with
//! `FailureCause.network_denied` and the text `collo_network.writeDenial`
//! writes for the origin of `task.url`, which is the current hop's, so a
//! denied redirect names the redirect's target. Every other error fails as
//! `fetch failed: <error name>`.

const std = @import("std");
const transport = @import("../transport/root.zig");
const task_model = @import("../task.zig");

const network = transport.network;

pub fn completeCanceled(task: *task_model.Task, wake_ctx: ?*anyopaque, wake_fn: anytype) void {
    task.mutex.lock();
    task.done = true;
    task.mutex.unlock();
    wake_fn(wake_ctx, .{ .task_ready = task.readyToken() });
}

pub fn publishFailure(task: *task_model.Task, err: anyerror, wake_ctx: ?*anyopaque, wake_fn: anytype) void {
    if (transport.denialOf(err)) |denial| {
        publishResult(task, denialResult(task, denial), wake_ctx, wake_fn);
        return;
    }
    const message = std.fmt.allocPrint(task.resultAllocator(), "fetch failed: {s}", .{@errorName(err)}) catch {
        publishResult(task, .{ .failure = .{ .message = "fetch failed: out of memory" } }, wake_ctx, wake_fn);
        return;
    };
    publishResult(task, .{ .failure = .{ .message = message } }, wake_ctx, wake_fn);
}

pub fn publishResult(
    task: *task_model.Task,
    result: task_model.Result,
    wake_ctx: ?*anyopaque,
    wake_fn: anytype,
) void {
    task.mutex.lock();
    task.result = result;
    task.done = true;
    task.mutex.unlock();
    wake_fn(wake_ctx, .{ .task_ready = task.readyToken() });
}

/// The failure of a hop `denial` refused. Without the origin's text, which
/// a URL the transport already parsed always yields, or without memory for
/// it, the message is the denial's reason alone.
fn denialResult(task: *task_model.Task, denial: network.Denial) task_model.Result {
    const fallback: task_model.Result = .{ .failure = .{
        .message = denial.describe(),
        .cause = .network_denied,
    } };
    const origin = hopOrigin(task.url) orelse return fallback;
    var buffer: [network.grant.denial_bytes_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    // `denial_bytes_max` is the longest text `writeDenial` writes.
    network.writeDenial(&writer, origin, denial) catch unreachable;
    const message = task.resultAllocator().dupe(u8, writer.buffered()) catch return fallback;
    return .{ .failure = .{ .message = message, .cause = .network_denied } };
}

/// The origin a denial names for `url`: its scheme, its host as the URL
/// spells it, IPv6 in brackets, and its effective port.
fn hopOrigin(url: []const u8) ?network.Origin {
    const uri = std.Uri.parse(url) catch return null;
    const protocol = transport.Protocol.fromScheme(uri.scheme) orelse return null;
    const host = uri.host orelse return null;
    const scheme: network.Scheme = switch (protocol) {
        .plain => .http,
        .tls => .https,
    };
    return .{
        .scheme = scheme,
        .host = host.percent_encoded,
        .port = uri.port orelse scheme.defaultPort(),
    };
}

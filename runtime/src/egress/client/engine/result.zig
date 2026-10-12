//! Settles a fetch task: stores its result, or only marks a canceled task
//! done, and wakes the consumer with the task's ready token, all under
//! `task.mutex`. A failure whose message cannot be allocated publishes a
//! static message instead, so every path settles the task.
//!
//! A hop the network policy refused (`transport.denialOf`) fails with
//! `FailureCause.network_denied` and the text `collo_network.writeDenial`
//! writes for the origin of `task.url`, which is the current hop's, so a
//! denied redirect names the redirect's target. Every other error fails as
//! `fetch failed: <error name>`.

const std = @import("std");
const transport = @import("collo_egress_transport");
const task_model = @import("../task.zig");

const network = transport.network;

pub fn completeCanceled(task: *task_model.Task, wake_ctx: ?*anyopaque, wake_fn: anytype) void {
    task.mutex.lock();
    const ready = task.readyToken();
    task.done = true;
    wake_fn(wake_ctx, .{ .task_ready = ready });
    task.mutex.unlock();
}

pub fn publishFailure(task: *task_model.Task, err: anyerror, wake_ctx: ?*anyopaque, wake_fn: anytype) void {
    if (transport.denialOf(err)) |denial| {
        publishResult(task, denialResult(task, denial), wake_ctx, wake_fn);
        return;
    }
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

/// The failure of a hop `denial` refused. Without the origin's text, which
/// a URL the transport already parsed always yields, or without memory for
/// it, the message is the denial's reason alone.
fn denialResult(task: *task_model.Task, denial: network.Denial) task_model.Result {
    const fallback: task_model.Result = .{ .failure = .{
        .message = denial.describe(),
        .owned = false,
        .cause = .network_denied,
    } };
    const origin = hopOrigin(task.url) orelse return fallback;
    var buffer: [network.grant.denial_bytes_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    // `denial_bytes_max` is the longest text `writeDenial` writes.
    network.writeDenial(&writer, origin, denial) catch unreachable;
    const message = task.resultAllocator().dupe(u8, writer.buffered()) catch return fallback;
    return .{ .failure = .{ .message = message, .owned = true, .cause = .network_denied } };
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

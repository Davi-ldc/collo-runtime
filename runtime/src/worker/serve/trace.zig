//! Phase timing for traced requests, printed as one JSON line on stderr when
//! a request finishes. WorkerInit's runtime flags choose whether the worker
//! traces only its first request or every request (`shouldTraceRequest` in
//! `worker/request/ingress/runtime.zig`); an untraced request costs one
//! branch per stamp. Runs in the worker on the VM thread.
//!
//! Each phase is the gap between two stamps of `RequestTrace`
//! (`worker/request/context.zig`), which owns what a zero stamp means. A
//! phase whose start is 0, or whose end comes before its start, prints as 0.

const std = @import("std");
const req_context = @import("collo_worker_request").context;
const state = @import("../runtime/root.zig");

/// Stamps the `RequestTrace` field `field_name` of a traced request with
/// `runtime.nowMonoNs()`. `runtime` is anything with that method, such as
/// the runtime or the modules context.
pub fn mark(runtime: anytype, request_ctx: *req_context.RequestContext, comptime field_name: []const u8) void {
    if (!request_ctx.trace_enabled)
        return;
    @field(request_ctx.trace, field_name) = runtime.nowMonoNs();
}

/// Prints a traced request's phases, followed by the worker's counters since
/// boot, which no single request owns. `finishRequest` calls it once the
/// completion is published.
pub fn emit(runtime: *const state.Runtime, request_ctx: *req_context.RequestContext) void {
    if (!request_ctx.trace_enabled)
        return;
    const trace = request_ctx.trace;
    std.debug.print("{{\"bench\":\"worker_request_trace\",\"request_id\":{d}", .{trace.request_id});
    printMs("evaluate_module_ms", trace.execute_request_start_ns, trace.evaluate_module_done_ns);
    // A request whose route the boot or an earlier request evaluated never
    // stamps `evaluate_module_done_ns`, so its handler's lookup starts at the
    // request's execution.
    printMs("get_export_ms", @max(trace.evaluate_module_done_ns, trace.execute_request_start_ns), trace.get_export_done_ns);
    printMs("parse_request_ms", trace.get_export_done_ns, trace.parse_request_done_ns);
    printMs("make_request_ms", trace.parse_request_done_ns, trace.make_request_done_ns);
    printMs("handler_invoke_or_schedule_ms", trace.make_request_done_ns, trace.handler_invoke_done_ns);
    printMs("completion_wait_ms", trace.handler_invoke_done_ns, trace.completion_received_ns);
    // A synchronous handler never stamps `completion_received_ns`, so its
    // extraction starts at the handler stamp.
    printMs("response_extract_ms", @max(trace.completion_received_ns, trace.handler_invoke_done_ns), trace.response_extract_done_ns);
    printMs("response_write_ms", trace.response_extract_done_ns, trace.response_write_done_ns);
    printMs("finish_request_ms", trace.response_write_done_ns, trace.completion_published_ns);
    std.debug.print(
        ",\"sync_handler_fast_path_count\":{d},\"thenable_handler_count\":{d},\"response_extraction_count\":{d},\"stale_task_completion_count\":{d}",
        .{
            runtime.observability.sync_handler_fast_path_count,
            runtime.observability.thenable_handler_count,
            runtime.observability.response_extraction_count,
            runtime.observability.stale_task_completion_count,
        },
    );
    std.debug.print("}}\n", .{});
}

fn printMs(name: []const u8, start_ns: u64, end_ns: u64) void {
    const ns = if (start_ns != 0 and end_ns >= start_ns) end_ns - start_ns else 0;
    std.debug.print(",\"{s}\":{d:.3}", .{ name, @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms)) });
}

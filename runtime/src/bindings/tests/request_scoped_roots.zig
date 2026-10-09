//! Request end cuts the roots of a body consume whose stream never settles. Consuming a
//! ReadableStream body holds the reader and the result promise in Strong handles on a
//! refcounted state, and the read reactions it installs hold the reference that keeps that
//! state alive (`ReadableStreamBodyConsumerState` in
//! `host_functions/webapi/streams/readable_stream_consume.cpp`). `ColloRequestScopedRoots` in
//! `jsc/runtime/state.h` says why neither the collector nor the refcount can retire this cycle
//! and why a leak checker misses it; `Vm.cleanupWebApiRequest` cuts the roots at request end.
//! Lane: `bindings-test`.

const std = @import("std");
const support = @import("bindings_support");

test "request cleanup collects a body consume whose stream never settles" {
    var vm = try support.createVm();
    defer vm.deinit();

    const source =
        \\let weak_stream = null;
        \\
        \\export function startConsume() {
        \\    // Never enqueues and never closes, so the read stays outstanding.
        \\    const stream = new ReadableStream({ start() {} });
        \\    weak_stream = new WeakRef(stream);
        \\    // No await: the request finishes with the read still pending, and
        \\    // the Response itself is a temporary, so after this returns the
        \\    // consume state holds the only roots on the stream.
        \\    void new Response(stream).json();
        \\}
        \\
        \\export function streamState() {
        \\    return weak_stream.deref() === undefined ? "collected" : "alive";
        \\}
    ;

    try support.registerModule(&vm, "/never-settling-consume.js", source);
    try support.evaluateOk(&vm, "/never-settling-consume.js");

    var start_consume = try support.getExportOk(&vm, "/never-settling-consume.js", "startConsume");
    defer start_consume.deinit();
    var stream_state = try support.getExportOk(&vm, "/never-settling-consume.js", "streamState");
    defer stream_state.deinit();

    const consume_request_id: u64 = 4242;
    {
        var consume_ctx = support.makeExecCtx(consume_request_id);
        try vm.turnEnter(&consume_ctx);
        defer vm.turnExit() catch {};
        var started = try support.invokeOk(&vm, &consume_ctx, &start_consume, &.{});
        started.deinit();
    }

    // The probes run as other requests, so the cleanup below has to find the consume's roots by
    // their owner: requests share the VM, and `collo_webapi_cleanup_request` releases only the
    // ended request's share. A full collection needs the turn closed, hence the blocks.
    {
        // This probe shows the consume pins the stream across a full collection. Without it,
        // a stream that was never pinned would let the test pass with the cut removed.
        try vm.collectFullGCAndTrim();
        var probe_ctx = support.makeExecCtx(consume_request_id + 1);
        try vm.turnEnter(&probe_ctx);
        defer vm.turnExit() catch {};
        var before_cleanup = try support.invokeOk(&vm, &probe_ctx, &stream_state, &.{});
        defer before_cleanup.deinit();
        try support.expectValueString(&vm, &before_cleanup, "alive");
    }

    try vm.cleanupWebApiRequest(consume_request_id);

    {
        try vm.collectFullGCAndTrim();
        var probe_ctx = support.makeExecCtx(consume_request_id + 2);
        try vm.turnEnter(&probe_ctx);
        defer vm.turnExit() catch {};
        var after_cleanup = try support.invokeOk(&vm, &probe_ctx, &stream_state, &.{});
        defer after_cleanup.deinit();
        try support.expectValueString(&vm, &after_cleanup, "collected");
    }
}

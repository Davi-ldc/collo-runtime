//! Extraction of a handler's `new Response(...)` through `Vm.extractResponse`, the call the
//! worker makes on every response (`fillExtractedResponse` in
//! `host_functions/server/fetch/response.cpp`). Extraction hands a fetch stream body to the
//! caller and copies any other body out through its synchronous `byteLength`, which throws for
//! a body built from a user ReadableStream. That gap is on the native side, where no
//! JavaScript-only `webapi` fixture can reach it, so these tests pin it over the real
//! extraction call. Lane: `bindings-test`; the rest of extraction is covered in `worker-test`
//! (`worker/tests/runtime/response.zig`).

const std = @import("std");
const support = @import("bindings_support");
const bindings = support.bindings;

const extract_limits = bindings.ResponseExtractLimits{
    .max_body_bytes = 4 * 1024 * 1024,
    .max_header_count = 256,
    .max_header_bytes = 16 * 1024,
};

fn extractDefaultResponse(vm: *bindings.Vm, request_id: u64) !bindings.ExtractResponseResult {
    var entry = try support.getExportOk(vm, "/handler.js", "default");
    defer entry.deinit();

    var exec_ctx = support.makeExecCtx(request_id);
    try vm.turnEnter(&exec_ctx);
    defer vm.turnExit() catch {};

    var response = try support.invokeOk(vm, &exec_ctx, &entry, &.{});
    defer response.deinit();

    return vm.extractResponse(&response, extract_limits);
}

test "extracting a Response backed by a user ReadableStream is not supported and reports the streaming gap" {
    var vm = try support.createVm();
    defer vm.deinit();

    // A server-sent events response whose body is a user ReadableStream that enqueues one
    // event and closes.
    const source =
        \\export default function handler() {
        \\    const stream = new ReadableStream({
        \\        start(controller) {
        \\            controller.enqueue(new TextEncoder().encode("data: hello\n\n"));
        \\            controller.close();
        \\        },
        \\    });
        \\    return new Response(stream, {
        \\        headers: { "content-type": "text/event-stream" },
        \\    });
        \\}
    ;
    try support.registerModule(&vm, "/handler.js", source);
    try support.evaluateOk(&vm, "/handler.js");

    switch (try extractDefaultResponse(&vm, 5100)) {
        .success => |extracted| {
            var owned = extracted;
            owned.deinit();
            return error.ExpectedStreamingGapException;
        },
        .exception => |exception| {
            var owned = exception;
            defer owned.deinit();
            // FIXME: extraction streams only a fetch stream body, so a user ReadableStream
            // body reaches `BodyState::byteLength` in `host_functions/server/fetch/body.cpp`,
            // which throws this TypeError. Once extraction streams such a body, this branch
            // becomes a check of the streamed bytes.
            try support.expectExceptionContains(&vm, &owned, "ReadableStream body bytes are not synchronously available");
        },
    }
}

test "extracting a Response with a buffered body still succeeds (extraction is not broken)" {
    var vm = try support.createVm();
    defer vm.deinit();

    // The control for the test above: a buffered body extracts, so the exception there comes
    // from the stream body and not from the harness.
    const source =
        \\export default function handler() {
        \\    return new Response("buffered-ok", {
        \\        headers: { "content-type": "text/plain" },
        \\    });
        \\}
    ;
    try support.registerModule(&vm, "/handler.js", source);
    try support.evaluateOk(&vm, "/handler.js");

    switch (try extractDefaultResponse(&vm, 5200)) {
        .success => |extracted| {
            var owned = extracted;
            defer owned.deinit();
            try std.testing.expectEqual(@as(u16, 200), owned.status);
            // `total_len` holds for either extracted body kind, bytes or byte segments;
            // "buffered-ok" is 11 bytes.
            try std.testing.expectEqual(@as(usize, 11), owned.body.total_len);
        },
        .exception => |exception| {
            var owned = exception;
            owned.deinit();
            return error.UnexpectedBufferedExtractionException;
        },
    }
}

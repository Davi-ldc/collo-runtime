//! Extraction of a handler's `new Response(...)` through `Realm.extractResponse`, the call the
//! worker makes on every response (`fillExtractedResponse` in
//! `host_functions/server/fetch/response.cpp`), and the bridge's half of streaming a ReadableStream
//! body (`host_functions/server/fetch/response_body_stream.cpp`): extraction takes the whole body of
//! an untouched stream over a Response's buffered body, or locks any other stream and hands it
//! over, a read runs the stream's pull in the caller's turn, a chunk's bytes are lent or
//! encoded, and a cancel reaches the stream's source with its reason. These are native paths no
//! JavaScript-only `webapi` fixture reaches. Lane: `bindings-test`; the worker side of streaming,
//! from the head to the finish, is covered in `worker-test`
//! (`worker/tests/runtime/response_body_stream.zig`), and the rest of extraction there too
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

    return vm.mainRealm().extractResponse(&response, extract_limits);
}

/// Extracts the handler's Response, which must succeed, and returns it; the caller owns it.
fn extractDefaultResponseOk(vm: *bindings.Vm, request_id: u64) !bindings.ExtractedResponse {
    return switch (try extractDefaultResponse(vm, request_id)) {
        .success => |extracted| extracted,
        .exception => |exception| {
            var owned = exception;
            owned.deinit();
            return error.UnexpectedExtractionException;
        },
    };
}

/// Calls the module's export `name` with no arguments in a turn of `request_id` and expects its
/// result, converted to a string, to be `expected`.
fn expectExportString(vm: *bindings.Vm, request_id: u64, name: []const u8, expected: []const u8) !void {
    var function = try support.getExportOk(vm, "/handler.js", name);
    defer function.deinit();
    var exec_ctx = support.makeExecCtx(request_id);
    try vm.turnEnter(&exec_ctx);
    defer vm.turnExit() catch {};
    var result = try support.invokeOk(vm, &exec_ctx, &function, &.{});
    defer result.deinit();
    try support.expectValueString(vm, &result, expected);
}

/// The value the module's export `name` returns when called with no arguments; the caller owns it.
fn exportResult(vm: *bindings.Vm, request_id: u64, name: []const u8) !bindings.Value {
    var function = try support.getExportOk(vm, "/handler.js", name);
    defer function.deinit();
    var exec_ctx = support.makeExecCtx(request_id);
    try vm.turnEnter(&exec_ctx);
    defer vm.turnExit() catch {};
    return support.invokeOk(vm, &exec_ctx, &function, &.{});
}

test "a Response over a user ReadableStream extracts as a body stream the bridge locks for the worker" {
    var vm = try support.createVm();
    defer vm.deinit();

    // A server-sent events response whose body is a stream the handler built.
    const source =
        \\export let stream;
        \\export let response;
        \\export default function handler() {
        \\    stream = new ReadableStream({
        \\        start(controller) {
        \\            controller.enqueue(new TextEncoder().encode("data: hello\n\n"));
        \\        },
        \\    });
        \\    response = new Response(stream, { headers: { "content-type": "text/event-stream" } });
        \\    return response;
        \\}
        \\export function state() {
        \\    return `${stream.locked} ${response.bodyUsed}`;
        \\}
    ;
    try support.registerModule(&vm, "/handler.js", source);
    try support.evaluateOk(&vm, "/handler.js");

    var extracted = try extractDefaultResponseOk(&vm, 5100);
    defer extracted.deinit();
    try std.testing.expectEqual(bindings.extracted_response_body_readable_stream, extracted.body.kind);
    try std.testing.expectEqual(@as(u16, 200), extracted.status);
    try std.testing.expectEqual(@as(usize, 1), extracted.headersSlice().len);

    var body_stream = extracted.body.takeBodyStream() orelse return error.MissingBodyStream;
    defer body_stream.deinit();
    // Locked, so no script can read or cancel it any more, and not yet disturbed: the worker has
    // not read it.
    try expectExportString(&vm, 5100, "state", "true false");
}

test "a Response that rewraps another's untouched body stream extracts that body's bytes as a buffered body" {
    var vm = try support.createVm();
    defer vm.deinit();

    // Hono's shape: a middleware that sets a header after the handler ran rebuilds the response
    // around the first one's body stream.
    const source =
        \\export let inner;
        \\export let outer;
        \\export default function handler() {
        \\    inner = new Response(JSON.stringify({ ok: "é" }), { headers: { "content-type": "application/json" } });
        \\    outer = new Response(inner.body, inner);
        \\    outer.headers.set("x-tenant", "t1");
        \\    return outer;
        \\}
        \\export function state() {
        \\    return `${outer.body.locked} ${outer.bodyUsed} ${inner.bodyUsed}`;
        \\}
    ;
    try support.registerModule(&vm, "/handler.js", source);
    try support.evaluateOk(&vm, "/handler.js");

    var extracted = try extractDefaultResponseOk(&vm, 5110);
    defer extracted.deinit();
    try std.testing.expect(extracted.body.kind != bindings.extracted_response_body_readable_stream);
    try std.testing.expect(extracted.body.body_stream == null);
    try std.testing.expectEqualStrings("{\"ok\":\"\xc3\xa9\"}", extracted.body.firstContiguousSlice());
    try std.testing.expectEqual(@as(usize, 2), extracted.headersSlice().len);
    // What a read of the stream to its end would leave: locked by the bridge, disturbed, and both
    // bodies used.
    try expectExportString(&vm, 5110, "state", "true true true");
}

/// Extracts what the module's export `name` returns, under `limits`, which
/// must succeed; the caller owns the result.
fn extractExportOk(
    vm: *bindings.Vm,
    request_id: u64,
    name: []const u8,
    limits: bindings.ResponseExtractLimits,
) !bindings.ExtractedResponse {
    var function = try support.getExportOk(vm, "/handler.js", name);
    defer function.deinit();
    var exec_ctx = support.makeExecCtx(request_id);
    try vm.turnEnter(&exec_ctx);
    defer vm.turnExit() catch {};
    var response = try support.invokeOk(vm, &exec_ctx, &function, &.{});
    defer response.deinit();
    return switch (try vm.mainRealm().extractResponse(&response, limits)) {
        .success => |extracted| extracted,
        .exception => |exception| {
            var owned = exception;
            owned.deinit();
            return error.UnexpectedExtractionException;
        },
    };
}

test "a rewrapped body above the body limit, or one script consumed through its Response, still extracts as a stream" {
    var vm = try support.createVm();
    defer vm.deinit();

    const source =
        \\export function large() {
        \\    const inner = new Response("abcdefgh");
        \\    return new Response(inner.body, inner);
        \\}
        \\export function consumed() {
        \\    const inner = new Response("abc");
        \\    const stream = inner.body;
        \\    // Consuming through the Response neither locks nor disturbs the
        \\    // stream it handed out, so only the used body tells the bytes are gone.
        \\    inner.text();
        \\    return new Response(stream, inner);
        \\}
    ;
    try support.registerModule(&vm, "/handler.js", source);
    try support.evaluateOk(&vm, "/handler.js");

    var small_limits = extract_limits;
    small_limits.max_body_bytes = 4;
    var large = try extractExportOk(&vm, 5130, "large", small_limits);
    defer large.deinit();
    try std.testing.expectEqual(bindings.extracted_response_body_readable_stream, large.body.kind);
    var large_stream = large.body.takeBodyStream() orelse return error.MissingBodyStream;
    large_stream.deinit();

    var consumed = try extractExportOk(&vm, 5131, "consumed", extract_limits);
    defer consumed.deinit();
    try std.testing.expectEqual(bindings.extracted_response_body_readable_stream, consumed.body.kind);
    var consumed_stream = consumed.body.takeBodyStream() orelse return error.MissingBodyStream;
    consumed_stream.deinit();
}

test "a tee branch of a Response's body stream still extracts as a stream" {
    var vm = try support.createVm();
    defer vm.deinit();

    const source =
        \\export let tee_branch;
        \\export default function handler() {
        \\    const inner = new Response("abcdef");
        \\    const [first, second] = inner.body.tee();
        \\    tee_branch = second;
        \\    return new Response(first);
        \\}
    ;
    try support.registerModule(&vm, "/handler.js", source);
    try support.evaluateOk(&vm, "/handler.js");

    var extracted = try extractDefaultResponseOk(&vm, 5120);
    defer extracted.deinit();
    // A tee branch reads from a source of its own, not from the Response's body.
    try std.testing.expectEqual(bindings.extracted_response_body_readable_stream, extracted.body.kind);
    var body_stream = extracted.body.takeBodyStream() orelse return error.MissingBodyStream;
    body_stream.deinit();
}

test "a Response whose ReadableStream body is locked or already read fails extraction as already used" {
    var vm = try support.createVm();
    defer vm.deinit();

    const source =
        \\export default function handler() {
        \\    const response = new Response(new ReadableStream({ pull(controller) { controller.close(); } }));
        \\    response.body.getReader();
        \\    return response;
        \\}
    ;
    try support.registerModule(&vm, "/handler.js", source);
    try support.evaluateOk(&vm, "/handler.js");

    switch (try extractDefaultResponse(&vm, 5150)) {
        .success => |extracted| {
            var owned = extracted;
            owned.deinit();
            return error.ExpectedAlreadyUsedException;
        },
        .exception => |exception| {
            var owned = exception;
            defer owned.deinit();
            try support.expectExceptionContains(&vm, &owned, "already used");
        },
    }
}

test "a closed ReadableStream body extracts as an empty body, and an errored one throws its error" {
    var vm = try support.createVm();
    defer vm.deinit();

    const source =
        \\export let errored = false;
        \\export default function handler() {
        \\    if (errored)
        \\        return new Response(new ReadableStream({ start(controller) { controller.error(new Error("broken source")); } }));
        \\    errored = true;
        \\    return new Response(new ReadableStream({ start(controller) { controller.close(); } }));
        \\}
    ;
    try support.registerModule(&vm, "/handler.js", source);
    try support.evaluateOk(&vm, "/handler.js");

    var closed = try extractDefaultResponseOk(&vm, 5160);
    defer closed.deinit();
    try std.testing.expectEqual(bindings.extracted_response_body_empty, closed.body.kind);
    try std.testing.expectEqual(@as(usize, 0), closed.body.total_len);
    try std.testing.expect(closed.body.body_stream == null);

    switch (try extractDefaultResponse(&vm, 5161)) {
        .success => |extracted| {
            var owned = extracted;
            owned.deinit();
            return error.ExpectedStoredErrorException;
        },
        .exception => |exception| {
            var owned = exception;
            defer owned.deinit();
            try support.expectExceptionContains(&vm, &owned, "broken source");
        },
    }
}

test "a body stream lends a buffer chunk's bytes in place and refuses anything else, a string included" {
    var vm = try support.createVm();
    defer vm.deinit();

    const source =
        \\export default function handler() {
        \\    return new Response(new ReadableStream());
        \\}
        \\export function view() {
        \\    // "hi" inside a larger buffer, so a lent view must honor the offset.
        \\    return new Uint8Array([0, 104, 105, 0]).subarray(1, 3);
        \\}
        \\export function buffer() {
        \\    return new Uint8Array([111, 107]).buffer;
        \\}
        \\export function text() {
        \\    return "hé";
        \\}
        \\export function number() {
        \\    return 42;
        \\}
    ;
    try support.registerModule(&vm, "/handler.js", source);
    try support.evaluateOk(&vm, "/handler.js");

    var extracted = try extractDefaultResponseOk(&vm, 5170);
    defer extracted.deinit();
    var body_stream = extracted.body.takeBodyStream() orelse return error.MissingBodyStream;
    defer body_stream.deinit();

    const lent = [_]struct { name: []const u8, bytes: []const u8 }{
        .{ .name = "view", .bytes = "hi" },
        .{ .name = "buffer", .bytes = "ok" },
    };
    for (lent) |case| {
        var chunk_value = try exportResult(&vm, 5170, case.name);
        defer chunk_value.deinit();
        switch (try body_stream.chunk(&chunk_value)) {
            .success => |bytes| try std.testing.expectEqualSlices(u8, case.bytes, bytes),
            .exception => |exception| {
                var owned = exception;
                owned.deinit();
                return error.UnexpectedChunkException;
            },
        }
    }

    for ([_][]const u8{ "text", "number" }) |name| {
        var chunk_value = try exportResult(&vm, 5170, name);
        defer chunk_value.deinit();
        switch (try body_stream.chunk(&chunk_value)) {
            .success => return error.ExpectedChunkTypeError,
            .exception => |exception| {
                var owned = exception;
                defer owned.deinit();
                try support.expectExceptionContains(&vm, &owned, "chunks must be an ArrayBuffer or an ArrayBufferView");
            },
        }
    }
}

test "a body stream read runs the stream's pull in the caller's turn and stays bound to the request that started it" {
    var vm = try support.createVm();
    defer vm.deinit();

    const source =
        \\export let pulls = 0;
        \\export default function handler() {
        \\    return new Response(new ReadableStream({ pull() { pulls += 1; } }, { highWaterMark: 0 }));
        \\}
        \\export function pullCount() {
        \\    return String(pulls);
        \\}
    ;
    try support.registerModule(&vm, "/handler.js", source);
    try support.evaluateOk(&vm, "/handler.js");

    var extracted = try extractDefaultResponseOk(&vm, 5180);
    defer extracted.deinit();
    var body_stream = extracted.body.takeBodyStream() orelse return error.MissingBodyStream;
    defer body_stream.deinit();
    // A stream with no high-water mark pulls only for a read.
    try expectExportString(&vm, 5180, "pullCount", "0");

    {
        var exec_ctx = support.makeExecCtx(5180);
        try vm.turnEnter(&exec_ctx);
        defer vm.turnExit() catch {};
        switch (try body_stream.read(5180)) {
            .success => {},
            .exception => |exception| {
                var owned = exception;
                owned.deinit();
                return error.UnexpectedReadException;
            },
        }
    }
    try expectExportString(&vm, 5180, "pullCount", "1");

    // The reactions report under the request the first read named, so no other request may read
    // through them.
    var exec_ctx = support.makeExecCtx(5181);
    try vm.turnEnter(&exec_ctx);
    defer vm.turnExit() catch {};
    try std.testing.expectError(error.InvalidArgument, body_stream.read(5181));
}

test "cancelling a body stream hands its source the client's reset as an AbortError" {
    var vm = try support.createVm();
    defer vm.deinit();

    const source =
        \\export let reason;
        \\export default function handler() {
        \\    return new Response(new ReadableStream({ cancel(cancelReason) { reason = cancelReason; } }));
        \\}
        \\export function cancelReason() {
        \\    return `${reason.name}: ${reason.message}`;
        \\}
    ;
    try support.registerModule(&vm, "/handler.js", source);
    try support.evaluateOk(&vm, "/handler.js");

    var extracted = try extractDefaultResponseOk(&vm, 5190);
    defer extracted.deinit();
    var body_stream = extracted.body.takeBodyStream() orelse return error.MissingBodyStream;
    defer body_stream.deinit();

    {
        var exec_ctx = support.makeExecCtx(5190);
        try vm.turnEnter(&exec_ctx);
        defer vm.turnExit() catch {};
        switch (try body_stream.cancel(.client_reset)) {
            .success => {},
            .exception => |exception| {
                var owned = exception;
                owned.deinit();
                return error.UnexpectedCancelException;
            },
        }
    }
    try expectExportString(&vm, 5190, "cancelReason", "AbortError: The client reset the response stream");
}

test "extracting a Response with a buffered body still succeeds (extraction is not broken)" {
    var vm = try support.createVm();
    defer vm.deinit();

    // The control for the stream cases above: a buffered body extracts as bytes, so what they see
    // comes from the stream body and not from the harness.
    const source =
        \\export default function handler() {
        \\    return new Response("buffered-ok", {
        \\        headers: { "content-type": "text/plain" },
        \\    });
        \\}
    ;
    try support.registerModule(&vm, "/handler.js", source);
    try support.evaluateOk(&vm, "/handler.js");

    var owned = try extractDefaultResponseOk(&vm, 5200);
    defer owned.deinit();
    try std.testing.expectEqual(@as(u16, 200), owned.status);
    // `total_len` holds for either extracted body kind, bytes or byte segments;
    // "buffered-ok" is 11 bytes.
    try std.testing.expectEqual(@as(usize, 11), owned.body.total_len);
    try std.testing.expect(owned.body.body_stream == null);
}

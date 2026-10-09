//! Collection and delivery of Response and Request bodies that are streams.
//!
//! A Response or Request reaches its body's stream (the stream it was built
//! from, or the one `body` created for a native body) through one edge its
//! cell traces, and the stream that `body` returns for a native body reaches
//! its Response or Request through an edge the stream traces. A cycle through
//! user code (an underlying source closing over its Response, an abort listener
//! holding a body reader) is therefore collected like any other, `body` returns
//! the same stream for the cell's whole life, and a finished readable, writable
//! or transform stream drops the user code behind it. The collection tests run
//! one graph pattern as a request, end the request, collect, and count survivors
//! through WeakRefs. The delivery tests keep part of a body graph reachable
//! across a collection and read the body afterwards, so an edge that stopped
//! keeping its target alive shows up as a short or failed read; the young
//! collection variants make the owning cell old first, so they also catch an
//! edge written without its write barrier. Lane: `bindings-test`; the streams'
//! own semantics are covered by the `webapi` lane's `runtime/tests/webapi/streams/`.

const std = @import("std");
const support = @import("bindings_support");
const bindings = support.bindings;

const specifier = "/body-stream-roots.js";

// Every edge in these graphs is traced, so one full collection reclaims a dead
// cycle and its synchronous sweep runs the destructors.
const collections = 1;

const source =
    \\const encoder = new TextEncoder();
    \\const count = 16;
    \\const sideTable = new WeakMap();
    \\let instances = [];
    \\let retainedStreams = [];
    \\
    \\function begin() {
    \\    instances = [];
    \\    retainedStreams = [];
    \\}
    \\
    \\// One instance per iteration: it survives while any of its objects does.
    \\function track(...objects) {
    \\    instances.push(objects.map((object) => new WeakRef(object)));
    \\}
    \\
    \\// A conservative root (a stale stack slot or JIT buffer) can pin one stray
    \\// instance for a round, and a later round releases it. A leak pins every
    \\// instance.
    \\export function live() {
    \\    const alive = instances.filter((refs) => refs.some((ref) => ref.deref() !== undefined)).length;
    \\    return alive <= 1 ? `collected ${instances.length}` : `${alive}/${instances.length} alive`;
    \\}
    \\
    \\function closedStream() {
    \\    return new ReadableStream({
    \\        start(controller) {
    \\            controller.enqueue(encoder.encode("body"));
    \\            controller.close();
    \\        },
    \\    });
    \\}
    \\
    \\// A stream that produces each chunk only when a reader asks for it.
    \\function pullStream(chunks) {
    \\    let next = 0;
    \\    return new ReadableStream(
    \\        {
    \\            pull(controller) {
    \\                controller.enqueue(encoder.encode(chunks[next++]));
    \\                if (next === chunks.length) controller.close();
    \\            },
    \\        },
    \\        { highWaterMark: 0 },
    \\    );
    \\}
    \\
    \\// Graphs with no cycle through the Response or Request.
    \\
    \\export function responseStreamUnread() {
    \\    begin();
    \\    for (let i = 0; i < count; i++) {
    \\        const stream = closedStream();
    \\        track(new Response(stream), stream);
    \\    }
    \\}
    \\
    \\export function responseStreamRead() {
    \\    begin();
    \\    for (let i = 0; i < count; i++) {
    \\        const stream = closedStream();
    \\        const response = new Response(stream);
    \\        track(response, stream);
    \\        void response.text();
    \\    }
    \\}
    \\
    \\export function responseStreamClone() {
    \\    begin();
    \\    for (let i = 0; i < count; i++) {
    \\        const stream = closedStream();
    \\        const response = new Response(stream);
    \\        const copy = response.clone();
    \\        track(response, stream, copy, copy.body);
    \\        void copy.text();
    \\    }
    \\}
    \\
    \\export function requestStreamUnread() {
    \\    begin();
    \\    for (let i = 0; i < count; i++) {
    \\        const stream = closedStream();
    \\        track(new Request("https://example.com/", { method: "POST", body: stream }), stream);
    \\    }
    \\}
    \\
    \\export function responseNativeBodyUnread() {
    \\    begin();
    \\    for (let i = 0; i < count; i++) {
    \\        const response = new Response("body");
    \\        track(response, response.body);
    \\    }
    \\}
    \\
    \\export function responseNativeBodyPartiallyRead() {
    \\    begin();
    \\    for (let i = 0; i < count; i++) {
    \\        const response = new Response("body");
    \\        const body = response.body;
    \\        track(response, body);
    \\        void body.getReader().read();
    \\    }
    \\}
    \\
    \\export function responseFromResponseBody() {
    \\    begin();
    \\    for (let i = 0; i < count; i++) {
    \\        const upstream = new Response("body");
    \\        const body = upstream.body;
    \\        track(upstream, body, new Response(body, upstream));
    \\    }
    \\}
    \\
    \\export function requestNativeBodyUnread() {
    \\    begin();
    \\    for (let i = 0; i < count; i++) {
    \\        const request = new Request("https://example.com/", { method: "POST", body: "body" });
    \\        track(request, request.body);
    \\    }
    \\}
    \\
    \\// The cycles below, with an ordinary object where the Response or Request
    \\// would be.
    \\
    \\export function plainOwnerReachedFromStreamSource() {
    \\    begin();
    \\    for (let i = 0; i < count; i++) {
    \\        const box = {};
    \\        const stream = new ReadableStream({
    \\            start(controller) {
    \\                controller.close();
    \\            },
    \\            cancel() {
    \\                return box.owner;
    \\            },
    \\        });
    \\        box.owner = { body: stream };
    \\        track(box.owner, stream);
    \\    }
    \\}
    \\
    \\export function plainOwnerBodyInSideTable() {
    \\    begin();
    \\    for (let i = 0; i < count; i++) {
    \\        const owner = {};
    \\        const body = new ReadableStream({
    \\            cancel() {
    \\                return owner;
    \\            },
    \\        });
    \\        sideTable.set(owner, { body });
    \\        track(owner, body);
    \\    }
    \\}
    \\
    \\export function plainOwnerAbortListenerHoldsReader() {
    \\    begin();
    \\    for (let i = 0; i < count; i++) {
    \\        const owner = { signal: new AbortController().signal };
    \\        const body = new ReadableStream({
    \\            cancel() {
    \\                return owner;
    \\            },
    \\        });
    \\        const reader = body.getReader();
    \\        owner.signal.addEventListener("abort", () => void reader.cancel());
    \\        track(owner, body);
    \\    }
    \\}
    \\
    \\// Stream bodies whose graph reaches back to their Response or Request.
    \\
    \\export function responseStreamSourceCapturesResponse() {
    \\    begin();
    \\    for (let i = 0; i < count; i++) {
    \\        const box = {};
    \\        const stream = new ReadableStream({
    \\            start(controller) {
    \\                controller.close();
    \\            },
    \\            cancel() {
    \\                return box.response;
    \\            },
    \\        });
    \\        box.response = new Response(stream);
    \\        track(box.response, stream);
    \\    }
    \\}
    \\
    \\export function requestStreamSourceCapturesRequest() {
    \\    begin();
    \\    for (let i = 0; i < count; i++) {
    \\        const box = {};
    \\        const stream = new ReadableStream({
    \\            start(controller) {
    \\                controller.close();
    \\            },
    \\            cancel() {
    \\                return box.request;
    \\            },
    \\        });
    \\        box.request = new Request("https://example.com/", { method: "POST", body: stream });
    \\        track(box.request, stream);
    \\    }
    \\}
    \\
    \\export function responseStreamSourceCapturesResponseUnclosed() {
    \\    begin();
    \\    for (let i = 0; i < count; i++) {
    \\        const box = {};
    \\        const stream = new ReadableStream({
    \\            pull() {
    \\                return box.response;
    \\            },
    \\        });
    \\        box.response = new Response(stream);
    \\        track(box.response, stream);
    \\    }
    \\}
    \\
    \\// The source never names the Response. A sibling closure does, which puts
    \\// `response` in the scope object every closure of this call shares.
    \\function handlerWithSiblingClosure() {
    \\    const stream = new ReadableStream({
    \\        start(controller) {
    \\            controller.enqueue(encoder.encode("body"));
    \\            controller.close();
    \\        },
    \\    });
    \\    const response = new Response(stream);
    \\    Promise.resolve().then(() => response.status);
    \\    return [response, stream];
    \\}
    \\
    \\export function responseStreamSiblingClosureRead() {
    \\    begin();
    \\    for (let i = 0; i < count; i++) {
    \\        const [response, stream] = handlerWithSiblingClosure();
    \\        track(response, stream);
    \\        void response.text();
    \\    }
    \\}
    \\
    \\// Native bodies whose Response or Request reaches the stream `body` returned.
    \\
    \\export function responseNativeBodyInSideTable() {
    \\    begin();
    \\    for (let i = 0; i < count; i++) {
    \\        const response = new Response("body");
    \\        const body = response.body;
    \\        sideTable.set(response, { body });
    \\        track(response, body);
    \\    }
    \\}
    \\
    \\export function requestNativeBodyCancelledOnAbort() {
    \\    begin();
    \\    for (let i = 0; i < count; i++) {
    \\        const request = new Request("https://example.com/", { method: "POST", body: "body" });
    \\        const body = request.body;
    \\        const reader = body.getReader();
    \\        request.signal.addEventListener("abort", () => void reader.cancel());
    \\        track(request, body);
    \\    }
    \\}
    \\
    \\// Each stream stays reachable from module scope after it finishes, and the
    \\// methods of its underlying source close over `captured`. A finished stream
    \\// never calls its source again, so `captured` must not outlive the finish.
    \\export function finishedStreamsDropTheirSources() {
    \\    begin();
    \\    for (let i = 0; i < count; i++) {
    \\        const captured = {};
    \\        const methods = {
    \\            pull() {
    \\                captured.pulled = true;
    \\            },
    \\            cancel() {
    \\                captured.cancelled = true;
    \\            },
    \\        };
    \\        let stream;
    \\        switch (i % 5) {
    \\        case 0:
    \\            stream = new ReadableStream({ ...methods, start: (controller) => controller.close() });
    \\            break;
    \\        case 1:
    \\            stream = new ReadableStream({ ...methods, start: (controller) => controller.error(new Error("finished")) });
    \\            break;
    \\        case 2:
    \\            stream = new ReadableStream(methods, { highWaterMark: 0 });
    \\            void stream.cancel();
    \\            break;
    \\        case 3: {
    \\            stream = new ReadableStream({
    \\                ...methods,
    \\                start(controller) {
    \\                    controller.enqueue(encoder.encode("body"));
    \\                    controller.close();
    \\                },
    \\            });
    \\            const reader = stream.getReader();
    \\            void reader.read();
    \\            reader.releaseLock();
    \\            break;
    \\        }
    \\        case 4:
    \\            stream = new ReadableStream({ ...methods, type: "bytes", start: (controller) => controller.close() });
    \\            break;
    \\        }
    \\        retainedStreams.push(stream);
    \\        track(captured);
    \\    }
    \\}
    \\
    \\// The same for writable streams: the sink's methods and the size strategy
    \\// close over `captured`, and a closed or errored stream never calls them.
    \\export function finishedWritableStreamsDropTheirSinks() {
    \\    begin();
    \\    for (let i = 0; i < count; i++) {
    \\        const captured = {};
    \\        const sink = {
    \\            start() {
    \\                captured.started = true;
    \\            },
    \\            write() {
    \\                captured.written = true;
    \\            },
    \\            close() {
    \\                captured.closed = true;
    \\            },
    \\            abort() {
    \\                captured.aborted = true;
    \\            },
    \\        };
    \\        const strategy = {
    \\            size() {
    \\                captured.sized = true;
    \\                return 1;
    \\            },
    \\        };
    \\        let stream;
    \\        switch (i % 4) {
    \\        case 0:
    \\            stream = new WritableStream(sink, strategy);
    \\            void stream.close();
    \\            break;
    \\        case 1:
    \\            stream = new WritableStream({ ...sink, start: (controller) => controller.error(new Error("finished")) }, strategy);
    \\            break;
    \\        case 2:
    \\            stream = new WritableStream(sink, strategy);
    \\            void stream.abort(new Error("finished")).catch(() => {});
    \\            break;
    \\        case 3: {
    \\            stream = new WritableStream(sink, strategy);
    \\            const writer = stream.getWriter();
    \\            void writer.write("chunk");
    \\            void writer.close();
    \\            writer.releaseLock();
    \\            break;
    \\        }
    \\        }
    \\        retainedStreams.push(stream);
    \\        track(captured);
    \\    }
    \\}
    \\
    \\// The same for transform streams, finished from either side.
    \\export function finishedTransformStreamsDropTheirTransformers() {
    \\    begin();
    \\    for (let i = 0; i < count; i++) {
    \\        const captured = {};
    \\        const transformer = {
    \\            start() {
    \\                captured.started = true;
    \\            },
    \\            transform(chunk, controller) {
    \\                captured.transformed = true;
    \\                controller.enqueue(chunk);
    \\            },
    \\            flush() {
    \\                captured.flushed = true;
    \\            },
    \\            cancel() {
    \\                captured.cancelled = true;
    \\            },
    \\        };
    \\        let stream;
    \\        switch (i % 5) {
    \\        case 0:
    \\            stream = new TransformStream(transformer);
    \\            void stream.writable.close();
    \\            break;
    \\        case 1:
    \\            stream = new TransformStream({ ...transformer, start: (controller) => controller.error(new Error("finished")) });
    \\            break;
    \\        case 2:
    \\            stream = new TransformStream({ ...transformer, start: (controller) => controller.terminate() });
    \\            break;
    \\        case 3:
    \\            stream = new TransformStream(transformer);
    \\            void stream.readable.cancel(new Error("finished"));
    \\            break;
    \\        case 4:
    \\            stream = new TransformStream(transformer);
    \\            void stream.writable.abort(new Error("finished")).catch(() => {});
    \\            break;
    \\        }
    \\        retainedStreams.push(stream);
    \\        track(captured);
    \\    }
    \\}
    \\
    \\// Owners whose `body` stream nothing else references. The WeakRefs observe
    \\// each stream without keeping it alive past the turn that created them.
    \\let bodyOwners = [];
    \\let bodyStreamRefs = [];
    \\
    \\export function bodyStreamsReferencedOnlyByTheirOwners() {
    \\    const locked = new Response("body");
    \\    locked.body.getReader();
    \\    bodyOwners = [
    \\        new Response("body"),
    \\        new Request("https://example.com/", { method: "POST", body: "body" }),
    \\        new Response(closedStream()),
    \\        locked,
    \\    ];
    \\    bodyStreamRefs = bodyOwners.map((owner) => new WeakRef(owner.body));
    \\}
    \\
    \\// Per owner: whether `body` is still the stream it returned before, and
    \\// whether that stream is locked.
    \\export function bodyStreamsAfterCollection() {
    \\    return bodyOwners
    \\        .map((owner, index) => `${bodyStreamRefs[index].deref() === owner.body}/${owner.body.locked}`)
    \\        .join(" ");
    \\}
    \\
    \\// A delivery test defers one read past a collection. Only what the deferred
    \\// read closes over stays reachable from here.
    \\const noRead = () => Promise.resolve("no read deferred");
    \\let deferredRead = noRead;
    \\let readResult = "pending";
    \\
    \\function deferRead(read) {
    \\    deferredRead = read;
    \\    readResult = "pending";
    \\}
    \\
    \\export function runDeferredRead() {
    \\    const read = deferredRead;
    \\    deferredRead = noRead;
    \\    read().then(
    \\        (text) => {
    \\            readResult = text;
    \\        },
    \\        (error) => {
    \\            readResult = `rejected: ${error}`;
    \\        },
    \\    );
    \\}
    \\
    \\export function deferredReadResult() {
    \\    return readResult;
    \\}
    \\
    \\async function readText(reader) {
    \\    const decoder = new TextDecoder();
    \\    let text = "";
    \\    for (;;) {
    \\        const { value, done } = await reader.read();
    \\        if (done) return text + decoder.decode();
    \\        text += decoder.decode(value, { stream: true });
    \\    }
    \\}
    \\
    \\export function responseDroppedWhileReaderHeld() {
    \\    const reader = new Response("body").body.getReader();
    \\    deferRead(() => readText(reader));
    \\}
    \\
    \\export function requestDroppedWhileReaderHeld() {
    \\    const reader = new Request("https://example.com/", { method: "POST", body: "body" }).body.getReader();
    \\    deferRead(() => readText(reader));
    \\}
    \\
    \\export function responseCloneReadsBothBranches() {
    \\    const original = new Response(pullStream(["bo", "dy"]));
    \\    const copy = original.clone();
    \\    deferRead(() => Promise.all([original.text(), copy.text()]).then((texts) => texts.join("|")));
    \\}
    \\
    \\export function responseCloneOutlivesOriginal() {
    \\    const copy = new Response(pullStream(["bo", "dy"])).clone();
    \\    deferRead(() => copy.text());
    \\}
    \\
    \\export function requestCloneReadsBothBranches() {
    \\    const original = new Request("https://example.com/", { method: "POST", body: pullStream(["bo", "dy"]) });
    \\    const copy = original.clone();
    \\    deferRead(() => Promise.all([original.text(), copy.text()]).then((texts) => texts.join("|")));
    \\}
    \\
    \\export function pullSourceHeldByResponse() {
    \\    const response = new Response(pullStream(["a", "b", "c"]));
    \\    deferRead(() => response.text());
    \\}
    \\
    \\export function pullSourceHeldByReader() {
    \\    const reader = pullStream(["a", "b", "c"]).getReader();
    \\    deferRead(() => readText(reader));
    \\}
    \\
    \\// Young-collection delivery. `promote*` builds a Response that a full
    \\// collection then makes old; the next step gives that old Response an edge
    \\// to a new stream that nothing else references and defers a read through
    \\// it. A young collection keeps the stream only if that edge was written
    \\// through the write barrier.
    \\let promoted = null;
    \\let promotedCopy = null;
    \\let promotedBodyRef = null;
    \\
    \\export function promoteNativeBodyResponse() {
    \\    promoted = new Response("body");
    \\}
    \\
    \\export function promotedResponseCreatesBodyStream() {
    \\    promotedBodyRef = new WeakRef(promoted.body);
    \\    deferRead(() => {
    \\        const same = promotedBodyRef.deref() === promoted.body;
    \\        return readText(promoted.body.getReader()).then((text) => `${same}|${text}`);
    \\    });
    \\}
    \\
    \\// The source closes once its only chunk is read, so the tee that clone runs
    \\// finishes within the turn and drops its own references to both branches.
    \\export function promoteStreamBodyResponse() {
    \\    promoted = new Response(closedStream());
    \\}
    \\
    \\export function promotedResponseIsCloned() {
    \\    promotedCopy = promoted.clone();
    \\    deferRead(() => Promise.all([promoted.text(), promotedCopy.text()]).then((texts) => texts.join("|")));
    \\}
;

fn createVm() !bindings.Vm {
    var vm = try support.createVm();
    errdefer vm.deinit();
    try support.registerModule(&vm, specifier, source);
    try support.evaluateOk(&vm, specifier);
    return vm;
}

/// Calls export `name` in a turn of request `request_id`. The turn's microtasks
/// drain on exit, so promise chains the call starts settle before it returns.
fn runExport(vm: *bindings.Vm, request_id: u64, name: []const u8) !void {
    var function = try support.getExportOk(vm, specifier, name);
    defer function.deinit();
    var ctx = support.makeExecCtx(request_id);
    try vm.turnEnter(&ctx);
    {
        errdefer vm.turnExit() catch {};
        var result = try support.invokeOk(vm, &ctx, &function, &.{});
        result.deinit();
    }
    try vm.turnExit();
}

fn expectExportString(vm: *bindings.Vm, request_id: u64, name: []const u8, expected: []const u8) !void {
    var function = try support.getExportOk(vm, specifier, name);
    defer function.deinit();
    var ctx = support.makeExecCtx(request_id);
    try vm.turnEnter(&ctx);
    defer vm.turnExit() catch {};
    var value = try support.invokeOk(vm, &ctx, &function, &.{});
    defer value.deinit();
    try support.expectValueString(vm, &value, expected);
}

/// Runs `pattern` as request `request_id`, ends that request, collects, and
/// expects every instance the pattern tracked to be gone.
fn expectCollectedAfterRequest(vm: *bindings.Vm, request_id: u64, pattern: []const u8) !void {
    try runExport(vm, request_id, pattern);
    try vm.cleanupWebApiRequest(request_id);

    // A full collection needs the turn closed, so the probe runs as a later
    // request, the way a co-scheduled sibling would observe the heap.
    for (0..collections) |_| try vm.collectFullGCAndTrim();
    try expectExportString(vm, request_id + 1, "live", "collected 16");
}

/// Runs `setup` as a turn of request `request_id`, collects, then runs the read
/// the setup deferred as a later turn of the same request and expects the text
/// it settled with.
fn expectReadAfterCollection(vm: *bindings.Vm, request_id: u64, setup: []const u8, expected: []const u8) !void {
    try runExport(vm, request_id, setup);
    for (0..collections) |_| try vm.collectFullGCAndTrim();
    try runExport(vm, request_id, "runDeferredRead");
    try expectExportString(vm, request_id, "deferredReadResult", expected);
    try vm.cleanupWebApiRequest(request_id);
}

/// Runs `promote` and makes what it built old with a full collection, then runs
/// `extend`, which links an old cell to new ones and defers a read through
/// them, collects only the young generation, and expects the text the deferred
/// read settles with. An old cell is traced in a young collection only if a
/// write barrier remembered it, so an edge written without one loses its target.
fn expectReadAfterYoungCollection(
    vm: *bindings.Vm,
    request_id: u64,
    promote: []const u8,
    extend: []const u8,
    expected: []const u8,
) !void {
    try runExport(vm, request_id, promote);
    try vm.collectFullGCAndTrim();
    try runExport(vm, request_id, extend);
    try vm.collectEdenGC();
    try runExport(vm, request_id, "runDeferredRead");
    try expectExportString(vm, request_id, "deferredReadResult", expected);
    try vm.cleanupWebApiRequest(request_id);
}

test "Response and Request stream bodies are collected after request end" {
    var vm = try createVm();
    defer vm.deinit();

    try expectCollectedAfterRequest(&vm, 100, "responseStreamUnread");
    try expectCollectedAfterRequest(&vm, 110, "responseStreamRead");
    try expectCollectedAfterRequest(&vm, 120, "responseStreamClone");
    try expectCollectedAfterRequest(&vm, 130, "requestStreamUnread");
    try expectCollectedAfterRequest(&vm, 140, "responseNativeBodyUnread");
    try expectCollectedAfterRequest(&vm, 150, "responseNativeBodyPartiallyRead");
    try expectCollectedAfterRequest(&vm, 160, "responseFromResponseBody");
    try expectCollectedAfterRequest(&vm, 170, "requestNativeBodyUnread");
}

test "the body cycles are collected when an ordinary object closes them" {
    // Controls for the tests below: the same graphs with a plain object in
    // place of the Response or Request, so a survivor there comes from how the
    // Response or Request holds its body and not from how the graph is built
    // or from the probe.
    var vm = try createVm();
    defer vm.deinit();

    try expectCollectedAfterRequest(&vm, 200, "plainOwnerReachedFromStreamSource");
    try expectCollectedAfterRequest(&vm, 210, "plainOwnerBodyInSideTable");
    try expectCollectedAfterRequest(&vm, 220, "plainOwnerAbortListenerHoldsReader");
}

test "a Response or Request is collected when its stream body reaches it" {
    var vm = try createVm();
    defer vm.deinit();

    try expectCollectedAfterRequest(&vm, 300, "responseStreamSourceCapturesResponse");
    try expectCollectedAfterRequest(&vm, 310, "requestStreamSourceCapturesRequest");
    try expectCollectedAfterRequest(&vm, 320, "responseStreamSourceCapturesResponseUnclosed");
    try expectCollectedAfterRequest(&vm, 330, "responseStreamSiblingClosureRead");
}

test "a Response is collected when a side table keyed by it holds its body" {
    var vm = try createVm();
    defer vm.deinit();

    try expectCollectedAfterRequest(&vm, 400, "responseNativeBodyInSideTable");
}

test "a Request is collected when its abort listener holds its body reader" {
    var vm = try createVm();
    defer vm.deinit();

    try expectCollectedAfterRequest(&vm, 500, "requestNativeBodyCancelledOnAbort");
}

test "a finished ReadableStream drops its underlying source" {
    var vm = try createVm();
    defer vm.deinit();

    try expectCollectedAfterRequest(&vm, 600, "finishedStreamsDropTheirSources");
}

test "a finished WritableStream or TransformStream drops its sink or transformer" {
    var vm = try createVm();
    defer vm.deinit();

    try expectCollectedAfterRequest(&vm, 610, "finishedWritableStreamsDropTheirSinks");
    try expectCollectedAfterRequest(&vm, 620, "finishedTransformStreamsDropTheirTransformers");
}

test "a body stream keeps its identity and lock across a collection" {
    var vm = try createVm();
    defer vm.deinit();

    try runExport(&vm, 1000, "bodyStreamsReferencedOnlyByTheirOwners");
    try vm.collectFullGCAndTrim();
    try expectExportString(&vm, 1000, "bodyStreamsAfterCollection", "true/false true/false true/false true/true");
    try vm.cleanupWebApiRequest(1000);
}

test "an old Response keeps the new body stream it links to across a young collection" {
    var vm = try createVm();
    defer vm.deinit();

    try expectReadAfterYoungCollection(
        &vm,
        1100,
        "promoteNativeBodyResponse",
        "promotedResponseCreatesBodyStream",
        "true|body",
    );
    try expectReadAfterYoungCollection(&vm, 1110, "promoteStreamBodyResponse", "promotedResponseIsCloned", "body|body");
}

test "a native body stream keeps its Response or Request alive while it is read" {
    var vm = try createVm();
    defer vm.deinit();

    try expectReadAfterCollection(&vm, 700, "responseDroppedWhileReaderHeld", "body");
    try expectReadAfterCollection(&vm, 710, "requestDroppedWhileReaderHeld", "body");
}

test "a cloned stream body delivers to every branch after a collection" {
    var vm = try createVm();
    defer vm.deinit();

    try expectReadAfterCollection(&vm, 800, "responseCloneReadsBothBranches", "body|body");
    try expectReadAfterCollection(&vm, 810, "responseCloneOutlivesOriginal", "body");
    try expectReadAfterCollection(&vm, 820, "requestCloneReadsBothBranches", "body|body");
}

test "a pull source keeps delivering after a collection" {
    var vm = try createVm();
    defer vm.deinit();

    try expectReadAfterCollection(&vm, 900, "pullSourceHeldByResponse", "abc");
    try expectReadAfterCollection(&vm, 910, "pullSourceHeldByReader", "abc");
}

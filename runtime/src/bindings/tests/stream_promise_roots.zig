//! Collection of streams that wait on a promise nobody will settle, with no request-end step.
//!
//! A stream cell holds every promise it will settle as an edge it traces, its reactions carry
//! their cell as context, and a body consumption, a tee and a `ReadableStream.from` keep their
//! state in cells; an AbortSignal holds a pipe as the context of its abort algorithm. No promise
//! references the stream that will settle it, so script that keeps a pending read's or a pipe's
//! promise keeps no stream alive. A graph whose reactions lead back to the stream (a parked
//! write, a pending BYOB read, a writer's `ready` or a reader's `closed` with a reaction over its
//! owner, an unread CompressionStream, an unfinished pipe, a consumption, tee or `from` waiting
//! on a read) is therefore collected once nothing else references it. A promise held through a
//! root would instead keep the whole graph alive until the VM is destroyed. Each test runs one
//! graph pattern as a request, collects with no request cleanup, and counts survivors through
//! WeakRefs; a pattern whose wait starts in a later microtask also checks that it got there.
//! Lanes: `bindings-test`, and the concurrent profile of `bindings-gc-stress`; the streams' own
//! semantics are covered by the `webapi` lane's `runtime/tests/webapi/streams/`.

const std = @import("std");
const support = @import("bindings_support");
const bindings = support.bindings;

const specifier = "/stream-promise-roots.js";

const source =
    \\const count = 16;
    \\let instances = [];
    \\
    \\function begin() {
    \\    instances = [];
    \\}
    \\
    \\// One instance per iteration: it survives while any of its objects does.
    \\function track(...objects) {
    \\    const instance = { refs: objects.map((object) => new WeakRef(object)), waiting: true };
    \\    instances.push(instance);
    \\    return instance;
    \\}
    \\
    \\// For a pattern whose wait starts in a later microtask: the callback that
    \\// starts the wait sets `waiting`, so a pattern that never got there fails
    \\// instead of passing with nothing to collect. A pattern makes its record
    \\// before the call that can start the wait, so the callback finds it
    \\// however soon it runs.
    \\function trackBeforeWait(...objects) {
    \\    const instance = track(...objects);
    \\    instance.waiting = false;
    \\    return instance;
    \\}
    \\
    \\// A conservative root (a stale stack slot or JIT buffer) can pin one stray
    \\// instance for a round, and a later round releases it. A leak pins every
    \\// instance.
    \\export function live() {
    \\    const notWaiting = instances.filter((instance) => !instance.waiting).length;
    \\    if (notWaiting !== 0) return `${notWaiting}/${instances.length} never waited`;
    \\    const alive = instances.filter((instance) => instance.refs.some((ref) => ref.deref() !== undefined)).length;
    \\    return alive <= 1 ? `collected ${instances.length}` : `${alive}/${instances.length} alive`;
    \\}
    \\
    \\// The readable side's high-water mark of 0 sets backpressure, so the write
    \\// parks in the transform until a read that never comes.
    \\export function transformWrittenNeverRead() {
    \\    begin();
    \\    for (let i = 0; i < count; i++) {
    \\        const stream = new TransformStream();
    \\        const writer = stream.writable.getWriter();
    \\        void writer.write("chunk");
    \\        track(stream, writer);
    \\    }
    \\}
    \\
    \\export function byobReadNeverFilled() {
    \\    begin();
    \\    for (let i = 0; i < count; i++) {
    \\        const stream = new ReadableStream({ type: "bytes" });
    \\        const reader = stream.getReader({ mode: "byob" });
    \\        void reader.read(new Uint8Array(8));
    \\        track(stream, reader);
    \\    }
    \\}
    \\
    \\export function writerReadyReactionHoldsWriter() {
    \\    begin();
    \\    for (let i = 0; i < count; i++) {
    \\        const stream = new WritableStream({}, { highWaterMark: 0 });
    \\        const writer = stream.getWriter();
    \\        void writer.ready.then(() => writer.desiredSize);
    \\        track(stream, writer);
    \\    }
    \\}
    \\
    \\export function readerClosedReactionHoldsReader() {
    \\    begin();
    \\    for (let i = 0; i < count; i++) {
    \\        const stream = new ReadableStream();
    \\        const reader = stream.getReader();
    \\        void reader.closed.then(() => reader);
    \\        track(stream, reader);
    \\    }
    \\}
    \\
    \\export function compressionWrittenNeverRead() {
    \\    begin();
    \\    for (let i = 0; i < count; i++) {
    \\        const stream = new CompressionStream("gzip");
    \\        const writer = stream.writable.getWriter();
    \\        void writer.write(new Uint8Array(64)).catch(() => {});
    \\        track(stream, writer);
    \\    }
    \\}
    \\
    \\export function pipeNeverCompletes() {
    \\    begin();
    \\    for (let i = 0; i < count; i++) {
    \\        const source = new ReadableStream();
    \\        const destination = new WritableStream();
    \\        void source.pipeTo(destination).catch(() => {});
    \\        track(source, destination);
    \\    }
    \\}
    \\
    \\// A source of high-water mark 0 pulls only for a read, so its pull shows
    \\// that the consumption read the stream. The Response is a temporary.
    \\export function bodyConsumptionNeverSettles() {
    \\    begin();
    \\    for (let i = 0; i < count; i++) {
    \\        let instance = null;
    \\        const stream = new ReadableStream(
    \\            {
    \\                pull() {
    \\                    instance.waiting = true;
    \\                },
    \\            },
    \\            { highWaterMark: 0 },
    \\        );
    \\        const response = new Response(stream);
    \\        instance = trackBeforeWait(stream, response);
    \\        void response.json();
    \\    }
    \\}
    \\
    \\// The branches want a chunk, so the tee reads the original, whose pull
    \\// shows the read is pending.
    \\export function teeBranchesNeverRead() {
    \\    begin();
    \\    for (let i = 0; i < count; i++) {
    \\        let instance = null;
    \\        const stream = new ReadableStream(
    \\            {
    \\                pull() {
    \\                    instance.waiting = true;
    \\                },
    \\            },
    \\            { highWaterMark: 0 },
    \\        );
    \\        instance = trackBeforeWait(stream);
    \\        const [first, second] = stream.tee();
    \\        instance.refs.push(new WeakRef(first), new WeakRef(second));
    \\    }
    \\}
    \\
    \\export function fromIteratorNextNeverSettles() {
    \\    begin();
    \\    for (let i = 0; i < count; i++) {
    \\        let instance = null;
    \\        const iterator = {
    \\            [Symbol.asyncIterator]() {
    \\                return this;
    \\            },
    \\            next() {
    \\                instance.waiting = true;
    \\                return new Promise(() => {});
    \\            },
    \\        };
    \\        const stream = ReadableStream.from(iterator);
    \\        const reader = stream.getReader();
    \\        instance = trackBeforeWait(stream, reader, iterator);
    \\        void reader.read();
    \\    }
    \\}
    \\
    \\// The signal holds the pipe until the pipe settles, and the source's pull
    \\// shows the pipe's read is pending.
    \\export function pipeSignalNeverAborts() {
    \\    begin();
    \\    for (let i = 0; i < count; i++) {
    \\        let instance = null;
    \\        const controller = new AbortController();
    \\        const source = new ReadableStream(
    \\            {
    \\                pull() {
    \\                    instance.waiting = true;
    \\                },
    \\            },
    \\            { highWaterMark: 0 },
    \\        );
    \\        const destination = new WritableStream();
    \\        instance = trackBeforeWait(source, destination, controller, controller.signal);
    \\        void source.pipeTo(destination, { signal: controller.signal }).catch(() => {});
    \\    }
    \\}
    \\
    \\// Script keeps each promise but nothing that could settle it.
    \\let keptPromises = [];
    \\
    \\export function pendingReadPromiseKept() {
    \\    begin();
    \\    keptPromises = [];
    \\    for (let i = 0; i < count; i++) {
    \\        const stream = new ReadableStream();
    \\        const reader = stream.getReader();
    \\        keptPromises.push(reader.read());
    \\        track(stream, reader);
    \\    }
    \\}
    \\
    \\export function pipePromiseKept() {
    \\    begin();
    \\    keptPromises = [];
    \\    for (let i = 0; i < count; i++) {
    \\        const source = new ReadableStream();
    \\        const destination = new WritableStream();
    \\        keptPromises.push(source.pipeTo(destination));
    \\        track(source, destination);
    \\    }
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
/// drain on exit.
fn runExport(vm: *bindings.Vm, request_id: u64, name: []const u8) !void {
    var function = try support.getExportOk(vm, specifier, name);
    defer function.deinit();
    var ctx = support.makeExecCtx(request_id);
    // Reactions the turn registered outlive the context, so the VM lets go of it before its storage does.
    defer vm.releaseExecCtx(&ctx) catch {};
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
    defer vm.releaseExecCtx(&ctx) catch {};
    try vm.turnEnter(&ctx);
    defer vm.turnExit() catch {};
    var value = try support.invokeOk(vm, &ctx, &function, &.{});
    defer value.deinit();
    try support.expectValueString(vm, &value, expected);
}

/// Runs `pattern` as request `request_id`, collects with no request cleanup, and
/// expects every instance the pattern tracked to have waited and to be gone.
fn expectCollected(vm: *bindings.Vm, request_id: u64, pattern: []const u8) !void {
    try runExport(vm, request_id, pattern);
    // A full collection needs the turn closed, so the probe runs as a later
    // request.
    try vm.collectFullGCAndTrim();
    try expectExportString(vm, request_id + 1, "live", "collected 16");
}

test "a TransformStream with a parked write and an unread readable is collected" {
    var vm = try createVm();
    defer vm.deinit();
    try expectCollected(&vm, 100, "transformWrittenNeverRead");
}

test "a byte stream with a pending BYOB read is collected" {
    var vm = try createVm();
    defer vm.deinit();
    try expectCollected(&vm, 200, "byobReadNeverFilled");
}

test "a writer whose pending ready promise has a reaction over it is collected" {
    var vm = try createVm();
    defer vm.deinit();
    try expectCollected(&vm, 300, "writerReadyReactionHoldsWriter");
}

test "a reader whose pending closed promise has a reaction over it is collected" {
    var vm = try createVm();
    defer vm.deinit();
    try expectCollected(&vm, 400, "readerClosedReactionHoldsReader");
}

test "a CompressionStream written once and never read is collected" {
    var vm = try createVm();
    defer vm.deinit();
    try expectCollected(&vm, 500, "compressionWrittenNeverRead");
}

test "a pipe that never completes is collected with both streams" {
    var vm = try createVm();
    defer vm.deinit();
    try expectCollected(&vm, 600, "pipeNeverCompletes");
}

test "a body consumption whose stream never settles is collected with its Response and no request cleanup" {
    var vm = try createVm();
    defer vm.deinit();
    try expectCollected(&vm, 700, "bodyConsumptionNeverSettles");
}

test "a tee whose branches are never read is collected with its stream" {
    var vm = try createVm();
    defer vm.deinit();
    try expectCollected(&vm, 800, "teeBranchesNeverRead");
}

test "a ReadableStream.from stream whose iterator never settles a next() is collected with the iterator" {
    var vm = try createVm();
    defer vm.deinit();
    try expectCollected(&vm, 900, "fromIteratorNextNeverSettles");
}

test "a pipe whose AbortSignal never aborts is collected with the signal, its controller and both streams" {
    var vm = try createVm();
    defer vm.deinit();
    try expectCollected(&vm, 1000, "pipeSignalNeverAborts");
}

test "a stream is collected while script keeps its pending read's promise" {
    var vm = try createVm();
    defer vm.deinit();
    try expectCollected(&vm, 1100, "pendingReadPromiseKept");
}

test "a pipe's streams are collected while script keeps the pipe's promise" {
    var vm = try createVm();
    defer vm.deinit();
    try expectCollected(&vm, 1200, "pipePromiseKept");
}

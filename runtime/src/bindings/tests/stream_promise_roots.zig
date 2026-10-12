//! Collection of streams that wait on a promise nobody will settle.
//!
//! A stream cell holds every promise it will settle as an edge it traces, so
//! a graph whose promise reactions lead back to the stream (a parked write, a
//! pending BYOB read, a writer's `ready` or a reader's `closed` with a
//! reaction over its owner, an unread CompressionStream, an unfinished pipe)
//! is collected once nothing else references it. A promise held through a
//! root would instead keep the whole graph alive until the VM is destroyed.
//! Each test runs one graph pattern as a request, ends the request, collects,
//! and counts survivors through WeakRefs. Lane: `bindings-test`; the streams'
//! own semantics are covered by the `webapi` lane's
//! `runtime/tests/webapi/streams/`.

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
    // request.
    try vm.collectFullGCAndTrim();
    try expectExportString(vm, request_id + 1, "live", "collected 16");
}

test "a TransformStream with a parked write and an unread readable is collected" {
    var vm = try createVm();
    defer vm.deinit();
    try expectCollectedAfterRequest(&vm, 100, "transformWrittenNeverRead");
}

test "a byte stream with a pending BYOB read is collected" {
    var vm = try createVm();
    defer vm.deinit();
    try expectCollectedAfterRequest(&vm, 200, "byobReadNeverFilled");
}

test "a writer whose pending ready promise has a reaction over it is collected" {
    var vm = try createVm();
    defer vm.deinit();
    try expectCollectedAfterRequest(&vm, 300, "writerReadyReactionHoldsWriter");
}

test "a reader whose pending closed promise has a reaction over it is collected" {
    var vm = try createVm();
    defer vm.deinit();
    try expectCollectedAfterRequest(&vm, 400, "readerClosedReactionHoldsReader");
}

test "a CompressionStream written once and never read is collected" {
    var vm = try createVm();
    defer vm.deinit();
    try expectCollectedAfterRequest(&vm, 500, "compressionWrittenNeverRead");
}

test "a pipe that never completes is collected with both streams" {
    var vm = try createVm();
    defer vm.deinit();
    try expectCollectedAfterRequest(&vm, 600, "pipeNeverCompletes");
}

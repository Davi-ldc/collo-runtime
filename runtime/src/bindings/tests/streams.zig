//! Stream behavior only the bridge harness can observe: the heap a TransformStream costs next to a
//! readable and writable pair, and a GenericTransformStream (CompressionStream,
//! DecompressionStream, TextEncoderStream, TextDecoderStream) next to a TransformStream; the
//! outside memory a CompressionStream and an unfinished Body consumption report to the collector;
//! and a pipe in one realm whose AbortSignal belongs to another. Lane: `bindings-test`; the
//! streams' semantics are covered by the `webapi` lane's `runtime/tests/webapi/streams/`, their
//! collection by `stream_promise_roots.zig`, and the release of codec memory by `body_memory.zig`.

const std = @import("std");
const support = @import("bindings_support");
const bindings = support.bindings;

const specifier = "/streams.js";

/// Streams of one class the heap cost test holds at once.
const transform_streams_held = 256;
/// CompressionStreams the codec memory tests hold at once.
const compression_streams_held = 16;
/// Bytes each stream of the large-write test compresses in one write: zeros, so the output is
/// a few hundred bytes and one read takes it.
const large_write_bytes = 1024 * 1024;
/// Brotli CompressionStreams the encoder memory test holds at once.
const brotli_streams_held = 4;
/// Bytes each Brotli stream compresses: zeros, more than one input block at any quality, so the
/// encoder has built its hasher by the time the write settles.
const brotli_write_bytes = 512 * 1024;
/// Unfinished Body consumptions the consumer memory test holds, and what each has buffered.
const consumptions_held = 8;
const consumption_chunks = 4;
const consumption_chunk_bytes = 256 * 1024;

const source = std.fmt.comptimePrint(
    \\const transformStreamsHeld = {d};
    \\const compressionStreamsHeld = {d};
    \\const largeWriteBytes = {d};
    \\const brotliStreamsHeld = {d};
    \\const brotliWriteBytes = {d};
    \\const consumptionsHeld = {d};
    \\const consumptionChunks = {d};
    \\const consumptionChunkBytes = {d};
    \\
, .{
    transform_streams_held,
    compression_streams_held,
    large_write_bytes,
    brotli_streams_held,
    brotli_write_bytes,
    consumptions_held,
    consumption_chunks,
    consumption_chunk_bytes,
}) ++
    \\let held = [];
    \\
    \\export function release() {
    \\    held = [];
    \\}
    \\
    \\// One function per class, so each compiles on its first call and runs warm
    \\// when it is measured.
    \\export function holdStreamPairs() {
    \\    held = [];
    \\    for (let i = 0; i < transformStreamsHeld; i++) held.push(new ReadableStream(), new WritableStream());
    \\}
    \\
    \\export function holdTransformStreams() {
    \\    held = [];
    \\    for (let i = 0; i < transformStreamsHeld; i++) held.push(new TransformStream());
    \\}
    \\
    \\export function holdCompressionStreams() {
    \\    held = [];
    \\    for (let i = 0; i < transformStreamsHeld; i++) held.push(new CompressionStream("gzip"));
    \\}
    \\
    \\export function holdDecompressionStreams() {
    \\    held = [];
    \\    for (let i = 0; i < transformStreamsHeld; i++) held.push(new DecompressionStream("gzip"));
    \\}
    \\
    \\export function holdTextEncoderStreams() {
    \\    held = [];
    \\    for (let i = 0; i < transformStreamsHeld; i++) held.push(new TextEncoderStream());
    \\}
    \\
    \\export function holdTextDecoderStreams() {
    \\    held = [];
    \\    for (let i = 0; i < transformStreamsHeld; i++) held.push(new TextDecoderStream());
    \\}
    \\
    \\export function holdUnwrittenCompressionStreams() {
    \\    held = [];
    \\    for (let i = 0; i < compressionStreamsHeld; i++) held.push(new CompressionStream("gzip"));
    \\}
    \\
    \\// Nothing reads the readable side, so each write waits for a read with its
    \\// chunk still the writable side's, and the codec never opens.
    \\export function holdCompressionStreamsWrittenUnread() {
    \\    held = [];
    \\    for (let i = 0; i < compressionStreamsHeld; i++) {
    \\        const stream = new CompressionStream("gzip");
    \\        void stream.writable.getWriter().write(new Uint8Array(64)).catch(() => {});
    \\        held.push(stream);
    \\    }
    \\}
    \\
    \\// A pending read lets the write reach the codec; the codec stays open, since
    \\// the stream never closes.
    \\function holdWrittenStreams(count, format, bytes) {
    \\    held = [];
    \\    for (let i = 0; i < count; i++) {
    \\        const stream = new CompressionStream(format);
    \\        void stream.readable.getReader().read().catch(() => {});
    \\        void stream.writable.getWriter().write(new Uint8Array(bytes)).catch(() => {});
    \\        held.push(stream);
    \\    }
    \\}
    \\
    \\export function holdCompressionStreamsWrittenOnce() {
    \\    holdWrittenStreams(compressionStreamsHeld, "gzip", 64);
    \\}
    \\
    \\export function holdCompressionStreamsAfterLargeWrite() {
    \\    holdWrittenStreams(compressionStreamsHeld, "gzip", largeWriteBytes);
    \\}
    \\
    \\export function holdBrotliStreamsWrittenOnce() {
    \\    holdWrittenStreams(brotliStreamsHeld, "brotli", brotliWriteBytes);
    \\}
    \\
    \\// Each source queues its chunks at start and never closes, so the
    \\// consumption copies them all and then waits on a read nothing will
    \\// fulfill. The stream holds that read, whose reaction holds the consumer.
    \\export function holdUnfinishedConsumptions() {
    \\    held = [];
    \\    for (let i = 0; i < consumptionsHeld; i++) {
    \\        const stream = new ReadableStream({
    \\            start(controller) {
    \\                for (let chunk = 0; chunk < consumptionChunks; chunk++)
    \\                    controller.enqueue(new Uint8Array(consumptionChunkBytes));
    \\            },
    \\        });
    \\        void new Response(stream).arrayBuffer().catch(() => {});
    \\        held.push(stream);
    \\    }
    \\}
    \\
    \\// The signal's realm keeps the AbortController.
    \\let abortController = null;
    \\
    \\export function createSignal() {
    \\    abortController = new AbortController();
    \\    return abortController.signal;
    \\}
    \\
    \\export function abortFromThisRealm() {
    \\    abortController.abort(new Error("aborted by the signal's realm"));
    \\    return "aborted";
    \\}
    \\
    \\// The pipe's realm keeps the signal, the pipe's promise and what the pipe's
    \\// shutdown reports.
    \\let pipeSignal = null;
    \\let pipe = null;
    \\let settlement = "pending";
    \\const shutdownCalls = [];
    \\
    \\export function startPipe(signal) {
    \\    pipeSignal = signal;
    \\    const source = new ReadableStream(
    \\        {
    \\            cancel(reason) {
    \\                shutdownCalls.push(reason === pipeSignal.reason ? "cancel" : `cancel(${reason})`);
    \\            },
    \\        },
    \\        { highWaterMark: 0 },
    \\    );
    \\    const destination = new WritableStream({
    \\        abort(reason) {
    \\            shutdownCalls.push(reason === pipeSignal.reason ? "abort" : `abort(${reason})`);
    \\        },
    \\    });
    \\    pipe = source.pipeTo(destination, { signal });
    \\    pipe.then(
    \\        () => {
    \\            settlement = "fulfilled";
    \\        },
    \\        (reason) => {
    \\            settlement = reason === pipeSignal.reason ? "rejected with the signal's reason" : `rejected with ${reason}`;
    \\        },
    \\    );
    \\    return "started";
    \\}
    \\
    \\export function pipeReport() {
    \\    return [
    \\        settlement,
    \\        shutdownCalls.length === 0 ? "no shutdown" : shutdownCalls.join(","),
    \\        Object.getPrototypeOf(pipe) === Promise.prototype ? "promise of this realm" : "promise of another realm",
    \\    ].join("|");
    \\}
;

fn createVm() !bindings.Vm {
    var vm = try support.createVm();
    errdefer vm.deinit();
    try support.registerModule(&vm, specifier, source);
    try support.evaluateOk(&vm, specifier);
    return vm;
}

/// Calls export `name` of `realm` with `args` in a turn owned by `exec_ctx` and returns the
/// result, which the caller owns. The turn's microtasks drain on exit.
fn call(
    vm: *bindings.Vm,
    realm: bindings.Realm,
    exec_ctx: *bindings.ExecCtx,
    name: []const u8,
    args: []const *const bindings.Value,
) !bindings.Value {
    var function = try support.getExportInRealmOk(realm, specifier, name);
    defer function.deinit();
    try vm.turnEnter(exec_ctx);
    var result = support.invokeOk(vm, exec_ctx, &function, args) catch |err| {
        vm.turnExit() catch {};
        return err;
    };
    errdefer result.deinit();
    try vm.turnExit();
    return result;
}

/// `call`, expecting the string it returns.
fn expectCall(
    vm: *bindings.Vm,
    realm: bindings.Realm,
    exec_ctx: *bindings.ExecCtx,
    name: []const u8,
    args: []const *const bindings.Value,
    expected: []const u8,
) !void {
    var result = try call(vm, realm, exec_ctx, name, args);
    defer result.deinit();
    try support.expectValueString(vm, &result, expected);
}

/// Calls export `name` of the main realm in a turn of request `request_id`, a context that
/// lives only for the call.
fn runRequest(vm: *bindings.Vm, request_id: u64, name: []const u8) !void {
    var exec_ctx = support.makeExecCtx(request_id);
    // Reactions the turn registered outlive the context, so the VM lets go of it before its
    // storage does.
    defer vm.releaseExecCtx(&exec_ctx) catch {};
    var result = try call(vm, vm.mainRealm(), &exec_ctx, name, &.{});
    result.deinit();
}

/// The bytes of the cells a full collection marks, without the outside memory they report,
/// which `HeapStats.size_bytes` includes.
fn cellBytesAfterFullCollection(vm: *bindings.Vm) !u64 {
    try vm.collectFullGCAndTrim();
    const stats = try vm.heapStats();
    try std.testing.expect(stats.size_bytes >= stats.extra_memory_bytes);
    return stats.size_bytes - stats.extra_memory_bytes;
}

/// The cell bytes `hold` adds while its streams are held, measured on its second run, after
/// the first compiled its code into the heap. Uses request ids `request_id` to `request_id + 3`.
fn heldCellBytes(vm: *bindings.Vm, request_id: u64, hold: []const u8) !u64 {
    try runRequest(vm, request_id, hold);
    try runRequest(vm, request_id + 1, "release");
    const before = try cellBytesAfterFullCollection(vm);
    try runRequest(vm, request_id + 2, hold);
    const held = try cellBytesAfterFullCollection(vm);
    try runRequest(vm, request_id + 3, "release");
    return held -| before;
}

/// The least a held stream adds: its transform, readable and writable stream cells, each an
/// object with more than two pointer fields, so at least 32 bytes. Checking it keeps the
/// comparisons below from passing on a measurement that saw nothing.
const stream_bytes_min = 3 * 32;

/// What a TransformStream may cost beyond a ReadableStream and a WritableStream built on their
/// own. It adds its transform cell (a destructible object of sixteen word-sized fields, 144 bytes)
/// and its controller's cell (32 bytes), and saves the pair's second start promise and source
/// object; 256 bytes covers the two cells with room for size-class rounding. One JavaScript
/// function per algorithm, six of them at 32 bytes each, on top of the two cells exceeds it.
const transform_stream_extra_bytes_max = 256;

/// A GenericTransformStream may cost this fraction of the plain TransformStreams' bytes beyond
/// them, and the plain TransformStreams this fraction of the pairs' bytes beyond their bound. It
/// covers what a measurement adds besides the streams: cells a stale stack slot keeps through a
/// collection, or a code block compiled during the measured call, each a few KiB against the
/// hundreds of KiB the held streams take.
const slack_divisor = 32;

const generic_transform_holds = [_][]const u8{
    "holdCompressionStreams",
    "holdDecompressionStreams",
    "holdTextEncoderStreams",
    "holdTextDecoderStreams",
};

test "a TransformStream costs the heap two cells beyond a readable and writable pair, and a GenericTransformStream no more than a TransformStream" {
    var vm = try createVm();
    defer vm.deinit();

    const pair_bytes = try heldCellBytes(&vm, 100, "holdStreamPairs");
    try std.testing.expect(pair_bytes >= transform_streams_held * 2 * 32);
    const plain_bytes = try heldCellBytes(&vm, 110, "holdTransformStreams");
    try std.testing.expect(plain_bytes >= transform_streams_held * stream_bytes_min);
    const plain_allowed_bytes = pair_bytes + transform_streams_held * transform_stream_extra_bytes_max;
    if (plain_bytes > plain_allowed_bytes + @divFloor(plain_allowed_bytes, slack_divisor)) {
        std.debug.print("{d} cell bytes for {d} TransformStreams, {d} for as many readable and writable pairs\n", .{
            plain_bytes,
            transform_streams_held,
            pair_bytes,
        });
        return error.TestUnexpectedResult;
    }

    const allowed_bytes = plain_bytes + @divFloor(plain_bytes, slack_divisor);
    for (generic_transform_holds, 0..) |hold, index| {
        const bytes = try heldCellBytes(&vm, 200 + 10 * @as(u64, index), hold);
        try std.testing.expect(bytes >= transform_streams_held * stream_bytes_min);
        if (bytes > allowed_bytes) {
            std.debug.print("{s}: {d} cell bytes for {d} streams, {d} for plain TransformStreams\n", .{
                hold,
                bytes,
                transform_streams_held,
                plain_bytes,
            });
            return error.TestUnexpectedResult;
        }
    }
}

/// The heap's extra memory right after a full collection, which rebuilds it from what every
/// live cell reports.
fn extraMemoryAfterFullCollection(vm: *bindings.Vm) !u64 {
    try vm.collectFullGCAndTrim();
    const stats = try vm.heapStats();
    return stats.extra_memory_bytes;
}

/// The extra memory `hold` adds while its streams are held. Uses request ids `request_id` and
/// `request_id + 1`.
fn heldExtraBytes(vm: *bindings.Vm, request_id: u64, hold: []const u8) !u64 {
    const before = try extraMemoryAfterFullCollection(vm);
    try runRequest(vm, request_id, hold);
    const held = try extraMemoryAfterFullCollection(vm);
    try runRequest(vm, request_id + 1, "release");
    return held -| before;
}

/// zlib's deflate allocates its window, hash chains and pending buffer, about 256 KiB at the
/// default window and memory level, when it opens.
const deflate_state_bytes_min = 256 * 1024;

test "a CompressionStream reports no codec memory until a write reaches its codec, which waits for a read" {
    var vm = try createVm();
    defer vm.deinit();

    // All the streams together report less than one codec state unless a read let their write
    // through, and then each reports at least its own.
    const unwritten_bytes = try heldExtraBytes(&vm, 300, "holdUnwrittenCompressionStreams");
    try std.testing.expect(unwritten_bytes < deflate_state_bytes_min);
    const unread_bytes = try heldExtraBytes(&vm, 310, "holdCompressionStreamsWrittenUnread");
    try std.testing.expect(unread_bytes < deflate_state_bytes_min);
    const written_bytes = try heldExtraBytes(&vm, 320, "holdCompressionStreamsWrittenOnce");
    try std.testing.expect(written_bytes >= compression_streams_held * deflate_state_bytes_min);
}

test "a CompressionStream gives back its input buffer once a large write is consumed" {
    var vm = try createVm();
    defer vm.deinit();

    // Each stream keeps its open codec, about deflate_state_bytes_min, and an output buffer of
    // WebApiCompressionStreamOutputChunkBytes (64 KiB, limits.h). Twice the codec state leaves
    // room for both and nothing for the 1 MiB input buffer a consumed write would leave behind.
    const stream_bytes_max = 2 * deflate_state_bytes_min;
    const bytes = try heldExtraBytes(&vm, 400, "holdCompressionStreamsAfterLargeWrite");
    try std.testing.expect(bytes >= compression_streams_held * deflate_state_bytes_min);
    if (bytes > compression_streams_held * stream_bytes_max) {
        std.debug.print("{d} streams report {d} bytes after a {d}-byte write each\n", .{
            compression_streams_held,
            bytes,
            large_write_bytes,
        });
        return error.TestUnexpectedResult;
    }
}

test "a Brotli CompressionStream holds an encoder of a few MiB however much it compresses" {
    var vm = try createVm();
    defer vm.deinit();

    // The encoder runs at quality 5 with a 2^16-byte window, which allocated 1.8 MiB on 1 MiB of
    // text in `report/bench-before-simplify/probes.md`, against 57.8 MiB at the library's default
    // quality 11 and 2^22-byte window. 8 MiB per stream separates the two.
    const stream_bytes_max = 8 * 1024 * 1024;
    const bytes = try heldExtraBytes(&vm, 500, "holdBrotliStreamsWrittenOnce");
    try std.testing.expect(bytes > 0);
    if (bytes > brotli_streams_held * stream_bytes_max) {
        std.debug.print("{d} Brotli streams report {d} bytes after a {d}-byte write each\n", .{
            brotli_streams_held,
            bytes,
            brotli_write_bytes,
        });
        return error.TestUnexpectedResult;
    }
}

test "an unfinished Body consumption reports the bytes it has buffered" {
    var vm = try createVm();
    defer vm.deinit();

    // The chunks the consumptions copied are garbage by the collection, so what remains is
    // what the consumers report for their copies.
    const buffered_bytes = consumption_chunks * consumption_chunk_bytes;
    const bytes = try heldExtraBytes(&vm, 600, "holdUnfinishedConsumptions");
    if (bytes < consumptions_held * buffered_bytes) {
        std.debug.print("{d} consumptions report {d} bytes with {d} buffered each\n", .{
            consumptions_held,
            bytes,
            buffered_bytes,
        });
        return error.TestUnexpectedResult;
    }
}

const signal_request_id: u64 = 700;
const pipe_request_id: u64 = 701;

test "a foreign AbortSignal's abort reaches a pipe's destination and then its source with the signal's reason, and the pipe settles in its own realm" {
    var vm = try support.createVm();
    defer vm.deinit();
    try support.registerModule(&vm, specifier, source);
    const signal_realm = vm.mainRealm();
    const pipe_realm = try vm.createRealm();
    try support.evaluateInRealmOk(signal_realm, specifier);
    try support.evaluateInRealmOk(pipe_realm, specifier);

    // Each realm runs as a request that lives for the whole test, since reactions one realm
    // registers run in the other's turns.
    var signal_request = support.makeExecCtx(signal_request_id);
    defer vm.releaseExecCtx(&signal_request) catch {};
    var pipe_request = support.makeExecCtx(pipe_request_id);
    defer vm.releaseExecCtx(&pipe_request) catch {};

    var signal = try call(&vm, signal_realm, &signal_request, "createSignal", &.{});
    defer signal.deinit();
    try expectCall(&vm, pipe_realm, &pipe_request, "startPipe", &.{&signal}, "started");
    try expectCall(&vm, pipe_realm, &pipe_request, "pipeReport", &.{}, "pending|no shutdown|promise of this realm");

    // The abort aborts the destination, then cancels the source, each once with the signal's
    // reason; the pipe's promise, its realm's own, rejects with that same reason.
    try expectCall(&vm, signal_realm, &signal_request, "abortFromThisRealm", &.{}, "aborted");
    try expectCall(
        &vm,
        pipe_realm,
        &pipe_request,
        "pipeReport",
        &.{},
        "rejected with the signal's reason|abort,cancel|promise of this realm",
    );
}

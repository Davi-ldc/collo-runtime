//! Binds each WebAPI compatibility fixture under `runtime/tests/webapi/` to an
//! in-process runner of `support.zig`: `runSuite` for Collo contract fixtures,
//! `runLeakSuite` for the `_leak` fixtures, and `runCompatSuite` for the exact
//! Bun and WPT ports. The second argument names the fixture's module and seeds
//! its request ids. Compiled only under `-Dwebapi-compat` and run by
//! `webapi-test`; `forked.zig` runs a fixture in a forked worker. Bug and spec
//! references belong in the fixture, next to the assertion they explain.

const std = @import("std");
const webapi = @import("support.zig");

test "webapi globals compatibility" {
    try webapi.runSuite(@embedFile("globals/globals.test.js"), "/webapi/globals.test.js");
}

test "DOMException compatibility" {
    try webapi.runSuite(@embedFile("dom_exception/dom_exception.test.js"), "/webapi/dom-exception.test.js");
}

test "Event and EventTarget compatibility" {
    try webapi.runSuite(@embedFile("event/event.test.js"), "/webapi/event.test.js");
}

test "MessageChannel and MessagePort compatibility" {
    try webapi.runSuite(@embedFile("message_channel/message_channel.test.js"), "/webapi/message-channel.test.js");
}

test "MessageChannel and MessagePort leak compatibility" {
    try webapi.runLeakSuite(@embedFile("message_channel/message_channel_leak.test.js"), "/webapi/message-channel-leak.test.js");
}

test "MessageEvent Bun exact compatibility" {
    try webapi.runCompatSuite(
        @embedFile("message_event/message_event.bun.test.js"),
        "/webapi/message-event.bun.test.js",
    );
}

test "Performance compatibility" {
    try webapi.runSuite(@embedFile("performance/performance.test.js"), "/webapi/performance.test.js");
}

test "webapi AbortController and AbortSignal compatibility" {
    try webapi.runSuite(@embedFile("abort/abort.test.js"), "/webapi/abort.test.js");
}

test "webapi AbortController and AbortSignal leak compatibility" {
    try webapi.runLeakSuite(@embedFile("abort/abort_leak.test.js"), "/webapi/abort-leak.test.js");
}

test "Blob compatibility" {
    try webapi.runSuite(@embedFile("blob/blob.test.js"), "/webapi/blob.test.js");
}

test "File compatibility" {
    try webapi.runSuite(@embedFile("file/file.test.js"), "/webapi/file.test.js");
}

test "Blob Bun exact compatibility" {
    try webapi.runCompatSuite(
        @embedFile("blob/blob_array_fast_path.bun.test.js"),
        "/webapi/blob-array-fast-path.bun.test.js",
    );
}

test "FormData compatibility" {
    try webapi.runSuite(@embedFile("formdata/formdata.test.js"), "/webapi/formdata.test.js");
}

test "FormData Bun exact compatibility" {
    try webapi.runCompatSuite(
        @embedFile("formdata/form_data_boundary_crash.bun.test.js"),
        "/webapi/form-data-boundary-crash.bun.test.js",
    );
}

test "FormData multipart body serialization compatibility" {
    try webapi.runSuite(
        @embedFile("formdata/formdata_multipart_body.test.js"),
        "/webapi/formdata-multipart-body.test.js",
    );
}

test "crypto compatibility" {
    try webapi.runSuite(@embedFile("crypto/crypto.test.js"), "/webapi/crypto.test.js");
}

test "structuredClone compatibility" {
    try webapi.runSuite(@embedFile("structured_clone/structured_clone.test.js"), "/webapi/structured-clone.test.js");
}

test "webapi reportError compatibility" {
    try webapi.runSuite(@embedFile("report_error/report_error.test.js"), "/webapi/report-error.test.js");
}

test "webapi navigator compatibility" {
    try webapi.runSuite(@embedFile("navigator/navigator.test.js"), "/webapi/navigator.test.js");
}

test "console compatibility" {
    try webapi.runSuite(@embedFile("console/console.test.js"), "/webapi/console.test.js");
}

test "TextEncoder and TextDecoder compatibility" {
    try webapi.runSuite(@embedFile("text_codec/text_codec.test.js"), "/webapi/text-codec.test.js");
}

test "TextDecoder Bun exact single-byte compatibility" {
    try webapi.runCompatSuite(
        @embedFile("text_codec/text_decoder_single_byte.bun.test.js"),
        "/webapi/text-decoder-single-byte.bun.test.js",
    );
}

test "TextDecoder Bun exact CJK compatibility" {
    try webapi.runCompatSuite(
        @embedFile("text_codec/text_decoder_cjk.bun.test.js"),
        "/webapi/text-decoder-cjk.bun.test.js",
    );
}

test "TextDecoder Bun exact WPT compatibility" {
    try webapi.runCompatSuite(
        @embedFile("text_codec/text_decoder_wpt.bun.test.js"),
        "/webapi/text-decoder-wpt.bun.test.js",
    );
}

test "TextDecoder codec repertoire gate" {
    try webapi.runCompatSuite(
        @embedFile("text_codec/text_decoder_repertoire.bun.test.js"),
        "/webapi/text-decoder-repertoire.bun.test.js",
    );
}

test "Encoding Streams Bun exact compatibility" {
    try webapi.runCompatSuite(
        @embedFile("encoding/text_encoder_stream.bun.test.js"),
        "/webapi/text-encoder-stream.bun.test.js",
    );
    try webapi.runCompatSuite(
        @embedFile("encoding/text_decoder_stream.bun.test.js"),
        "/webapi/text-decoder-stream.bun.test.js",
    );
    try webapi.runCompatSuite(
        @embedFile("encoding/encode_bad_chunks.bun.test.js"),
        "/webapi/encode-bad-chunks.bun.test.js",
    );
}

test "atob and btoa compatibility" {
    try webapi.runSuite(@embedFile("base64/base64.test.js"), "/webapi/base64.test.js");
}

test "queueMicrotask compatibility" {
    try webapi.runSuite(@embedFile("microtask/microtask.test.js"), "/webapi/microtask.test.js");
}

test "queueMicrotask Bun exact compatibility" {
    try webapi.runCompatSuite(@embedFile("microtask/microtask.bun.test.js"), "/webapi/microtask.bun.test.js");
}

test "URL compatibility" {
    try webapi.runSuite(@embedFile("url/url.test.js"), "/webapi/url.test.js");
}

test "URLSearchParams compatibility" {
    try webapi.runSuite(@embedFile("url/url_search_params.test.js"), "/webapi/url-search-params.test.js");
}

test "URLPattern compatibility" {
    const prelude = try std.mem.concat(std.testing.allocator, u8, &.{
        "globalThis.__colloURLPatternTestData = ",
        @embedFile("url_pattern/urlpatterntestdata.json"),
        ";\n",
    });
    defer std.testing.allocator.free(prelude);

    try webapi.runSuiteWithPrelude(prelude, @embedFile("url_pattern/url_pattern.test.js"), "/webapi/url-pattern.test.js");
}

test "Headers compatibility" {
    try webapi.runSuite(@embedFile("headers/headers.test.js"), "/webapi/headers.test.js");
}

test "Request compatibility" {
    try webapi.runSuite(@embedFile("request/request.test.js"), "/webapi/request.test.js");
}

test "Request Bun exact compatibility" {
    try webapi.runCompatSuite(@embedFile("request/request.bun.test.js"), "/webapi/request.bun.test.js");
}

test "Response compatibility" {
    try webapi.runSuite(@embedFile("response/response.test.js"), "/webapi/response.test.js");
}

test "Body compatibility" {
    try webapi.runSuite(@embedFile("body/body.test.js"), "/webapi/body.test.js");
}

test "Body Bun exact compatibility" {
    try webapi.runCompatSuite(
        @embedFile("body/body_mixin_errors.bun.test.js"),
        "/webapi/body-mixin-errors.bun.test.js",
    );
}

test "ReadableStream compatibility" {
    try webapi.runSuite(@embedFile("streams/streams.test.js"), "/webapi/streams.test.js");
}

test "ReadableStream queuing strategy compatibility" {
    try webapi.runSuite(@embedFile("streams/queuing_strategy.test.js"), "/webapi/streams-queuing-strategy.test.js");
}

test "ReadableStream.from compatibility" {
    try webapi.runSuite(@embedFile("streams/readable_stream_from.test.js"), "/webapi/streams-from.test.js");
}

test "ReadableStream Bun exact globals compatibility" {
    try webapi.runCompatSuite(
        @embedFile("streams/streams_globals.bun.test.js"),
        "/webapi/streams-globals.bun.test.js",
    );
}

test "ReadableStream Bun WebAPI core compatibility" {
    try webapi.runCompatSuite(
        @embedFile("streams/streams_core.bun.test.js"),
        "/webapi/streams-core.bun.test.js",
    );
}

test "ReadableStream Bun WebAPI body response compatibility" {
    try webapi.runCompatSuite(
        @embedFile("streams/body_response.bun.test.js"),
        "/webapi/streams-body-response.bun.test.js",
    );
}

test "ReadableStream Bun WebAPI body reader compatibility" {
    try webapi.runCompatSuite(
        @embedFile("streams/readable_stream_body.bun.test.js"),
        "/webapi/streams-readable-stream-body.bun.test.js",
    );
}

test "ReadableStream WPT compact compatibility" {
    try webapi.runCompatSuite(
        @embedFile("streams/wpt_compact.wpt.test.js"),
        "/webapi/streams-wpt-compact.wpt.test.js",
    );
}

test "CompressionStream Bun WebAPI compatibility" {
    try webapi.runCompatSuite(
        @embedFile("streams/compression.bun.test.js"),
        "/webapi/compression-stream.bun.test.js",
    );
}

test "ReadableStream leak compatibility" {
    try webapi.runLeakSuite(@embedFile("streams/streams_leak.test.js"), "/webapi/streams-leak.test.js");
}

test "timers compatibility" {
    try webapi.runSuite(@embedFile("timers/timers.test.js"), "/webapi/timers.test.js");
}

test "fetch compatibility" {
    try webapi.runSuite(@embedFile("fetch/fetch_args.test.js"), "/webapi/fetch.test.js");
}

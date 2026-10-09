//! Covers the API a handler sees, run through a dispatched request: the
//! `Request` it receives (lazy, stable, non-enumerable accessors over the
//! dispatch's path, query, captures and headers), the performance timeline
//! that belongs to the worker rather than to one request, and edge cases of
//! `Headers`, JSON bodies, `URL` and `URLSearchParams`, with the count caps
//! that refuse form-data, search-parameter and codec stream floods. Runs in
//! `worker-test`; Web API conformance is covered by the `webapi` lane.

const std = @import("std");
const support = @import("bindings_support");
const ipc = @import("collo_ipc");
const worker_metrics_state = @import("collo_worker_state").metrics;
const worker_shared_page = @import("collo_worker_state").page;
const worker = @import("collo_worker");
const rt = @import("collo_test_harness");

const fakeNow = rt.fakeNow;
const RequestParts = rt.RequestParts;
const DispatchParts = rt.DispatchParts;
const initDispatchWork = rt.initDispatchWork;
const socketPairType = rt.socketPairType;
const writeAllFd = rt.writeAllFd;
const runRouteAndExpectBody = rt.runRouteAndExpectBody;
const runRouteAndReadBody = rt.runRouteAndReadBody;
const runRouteAndReadBodyWithRequest = rt.runRouteAndReadBodyWithRequest;
const runRouteAndReadBodyWithRequestCaptures = rt.runRouteAndReadBodyWithRequestCaptures;
const executeNextReady = rt.executeNextReady;
const executeUntilRequestDone = rt.executeUntilRequestDone;
const LocalOrigin = rt.LocalOrigin;

test "request internal accessors are lazy stable and non-enumerable" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = fakeNow,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const captures = [_]ipc.RouteCapture{.{ .name = "id", .value = "123" }};
    const response = try runRouteAndReadBodyWithRequestCaptures(&runtime, control_pair[1],
        \\export default function handle(req) {
        \\    const getter = (name) => {
        \\        const descriptor = Object.getOwnPropertyDescriptor(Request.prototype, name);
        \\        return !!descriptor && descriptor.enumerable === false && typeof descriptor.get === "function";
        \\    };
        \\    const method = (name) => {
        \\        const descriptor = Object.getOwnPropertyDescriptor(Request.prototype, name);
        \\        return !!descriptor && descriptor.enumerable === false && typeof descriptor.value === "function";
        \\    };
        \\    const headers = req.headers;
        \\    const params = req.params;
        \\    const query = req.query;
        \\    const parsed = new URL(req.url);
        \\    headers.set("x-added", "yes");
        \\    return Response.json({
        \\        h: headers === req.headers,
        \\        p: params === req.params,
        \\        q: query === req.query,
        \\        added: req.headers.get("x-added"),
        \\        method: req.method,
        \\        path: req.path,
        \\        url: req.url,
        \\        pathname: parsed.pathname,
        \\        raw: parsed.search,
        \\        a: query.get("a"),
        \\        allA: query.getAll("a"),
        \\        id: params.id,
        \\        tag: Object.prototype.toString.call(req),
        \\        instance: req instanceof Request,
        \\        keys: Object.keys(req).join("|"),
        \\        getters: ["method", "path", "url", "headers", "bodyUsed", "params", "query"].every(getter),
        \\        methods: ["text", "json"].every(method)
        \\    });
        \\}
    , 36, "/request-host-accessors.js", .{
        .path = "/users/123",
        .raw_query = "a=1&a=2",
    }, &captures);
    defer std.testing.allocator.free(response);

    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"h\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"p\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"q\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"added\":\"yes\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"method\":\"GET\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"path\":\"/users/123\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"url\":\"https://demo.test/users/123?a=1&a=2\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"pathname\":\"/users/123\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"raw\":\"?a=1&a=2\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"a\":\"1\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"allA\":[\"1\",\"2\"]"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"id\":\"123\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"tag\":\"[object Request]\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"instance\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"keys\":\"\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"getters\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"methods\":true"));
}

test "performance timeline is worker-scoped and survives across requests" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = fakeNow,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const source =
        \\let firstOrigin = 0;
        \\let observerCalls = 0;
        \\export default async function handle(req) {
        \\    if (req.path === "/first") {
        \\        firstOrigin = performance.timeOrigin;
        \\        const observer = new PerformanceObserver(() => { observerCalls++; });
        \\        observer.observe({ entryTypes: ["mark"] });
        \\        performance.mark("first");
        \\        await Promise.resolve();
        \\        await Promise.resolve();
        \\        return Response.json({
        \\            observerCalls,
        \\            entries: performance.getEntriesByType("mark").map(entry => entry.name).join("|")
        \\        });
        \\    }
        \\    performance.mark("second");
        \\    await Promise.resolve();
        \\    await Promise.resolve();
        \\    return Response.json({
        \\        observerCalls,
        \\        entries: performance.getEntriesByType("mark").map(entry => entry.name).join("|"),
        \\        originMoved: performance.timeOrigin !== firstOrigin
        \\    });
        \\}
    ;

    const first = try runRouteAndReadBodyWithRequest(&runtime, control_pair[1], source, 401, "/performance-request-state.js", .{ .path = "/first" });
    defer std.testing.allocator.free(first);
    try std.testing.expect(std.mem.containsAtLeast(u8, first, 1, "\"observerCalls\":1"));
    try std.testing.expect(std.mem.containsAtLeast(u8, first, 1, "\"entries\":\"first\""));

    std.Thread.sleep(20 * std.time.ns_per_ms);

    const second = try runRouteAndReadBodyWithRequest(&runtime, control_pair[1], source, 402, "/performance-request-state.js", .{ .path = "/second" });
    defer std.testing.allocator.free(second);
    // The observer the first request registered still fires, once for its
    // own mark and once for the second request's. Request cleanup releases
    // nothing in the timeline (`collo_webapi_cleanup_request` in
    // `bindings/host_functions/webapi/platform/performance/performance.cpp`),
    // so a request's observer survives the end of another request that
    // shares the worker.
    try std.testing.expect(std.mem.containsAtLeast(u8, second, 1, "\"observerCalls\":2"));
    // Entries accumulate across requests.
    try std.testing.expect(std.mem.containsAtLeast(u8, second, 1, "\"entries\":\"first|second\""));
    // The origin never moves, so performance.now() stays monotonic for the
    // worker's whole life; a request could not restore that if another
    // request reset the origin under it.
    try std.testing.expect(std.mem.containsAtLeast(u8, second, 1, "\"originMoved\":false"));
}

test "web api headers body json and fetch validation edge cases" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = fakeNow,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const headers_response = try runRouteAndReadBody(&runtime, control_pair[1],
        \\export default function handle() {
        \\    const source = {
        \\        *[Symbol.iterator]() {
        \\            yield ["x-duck", "ok"];
        \\        }
        \\    };
        \\    const copied = new Headers(source);
        \\    const cookies = new Headers([
        \\        ["set-cookie", "a=1"],
        \\        ["set-cookie", "b=2"]
        \\    ]);
        \\    const sorted = new Headers([["b", "2"], ["a", "1"], ["b", "3"]]);
        \\    const moving = new Headers([["foo", "123"], ["bar", "456"]]);
        \\    for (const [key, value] of moving) {
        \\        moving.delete(key);
        \\        moving.set(`x-${key}`, value);
        \\    }
        \\    const throws = (fn) => {
        \\        try {
        \\            fn();
        \\        } catch (_) {
        \\            return true;
        \\        }
        \\        return false;
        \\    };
        \\    const weird = new Headers({ "x-spaced": "  ok  " });
        \\    weird.set("empty", "\r");
        \\    weird.set("x-unicode", "café");
        \\    const many = new Headers();
        \\    for (let i = 0; i < 40; i++) {
        \\        many.append("x-many", String(i));
        \\        many.set(`x-${i}`, `v${i}`);
        \\    }
        \\    const live = new Headers([["a", "1"], ["c", "3"]]);
        \\    const iterator = live.entries();
        \\    const firstLive = iterator.next().value.join(":");
        \\    live.set("b", "2");
        \\    live.append("set-cookie", "s=1");
        \\    const liveRest = [];
        \\    for (let item = iterator.next(); !item.done; item = iterator.next())
        \\        liveRest.push(item.value.join(":"));
        \\    return Response.json({
        \\        duck: copied.get("x-duck"),
        \\        joined: cookies.get("set-cookie"),
        \\        cookieList: cookies.getSetCookie().join("|"),
        \\        iterated: Array.from(cookies).length,
        \\        keys: Array.from(cookies.keys()).join("|"),
        \\        values: Array.from(cookies.values()).join("|"),
        \\        copiedCookies: new Headers(cookies).getSetCookie().join("|"),
        \\        sorted: Array.from(sorted).map(([key, value]) => `${key}:${value}`).join("|"),
        \\        moving: Array.from(moving).map(([key, value]) => `${key}:${value}`).join("|"),
        \\        trimmed: weird.get("x-spaced"),
        \\        empty: weird.get("empty"),
        \\        unicode: weird.get("x-unicode"),
        \\        manyJoined: many.get("x-many"),
        \\        manyTail: many.get("x-39"),
        \\        manyCount: Array.from(many).length,
        \\        live: [firstLive, ...liveRest].join("|"),
        \\        primitiveThrows: throws(() => new Headers(1)),
        \\        boxedOk: !throws(() => new Headers(new Number(1))),
        \\        missingGetThrows: throws(() => cookies.get()),
        \\        missingSetThrows: throws(() => cookies.set("x")),
        \\        badNameThrows: throws(() => cookies.set("bad name", "x")),
        \\        badValueThrows: throws(() => cookies.set("x-bad", "a\rb")),
        \\        tag: Object.prototype.toString.call(cookies),
        \\        iteratorTag: Object.prototype.toString.call(cookies.entries()),
        \\        iteratorAlias: Headers.prototype[Symbol.iterator] === Headers.prototype.entries,
        \\        instance: cookies instanceof Headers,
        \\        callThrows: throws(() => Headers())
        \\    });
        \\}
    , 23, "/headers-iterable.js");
    defer std.testing.allocator.free(headers_response);
    try std.testing.expect(std.mem.containsAtLeast(u8, headers_response, 1, "\"duck\":\"ok\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, headers_response, 1, "\"joined\":null"));
    try std.testing.expect(std.mem.containsAtLeast(u8, headers_response, 1, "\"cookieList\":\"a=1|b=2\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, headers_response, 1, "\"iterated\":0"));
    try std.testing.expect(std.mem.containsAtLeast(u8, headers_response, 1, "\"keys\":\"\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, headers_response, 1, "\"values\":\"\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, headers_response, 1, "\"copiedCookies\":\"a=1|b=2\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, headers_response, 1, "\"sorted\":\"a:1|b:2, 3\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, headers_response, 1, "\"moving\":\"foo:123|x-x-bar:456\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, headers_response, 1, "\"trimmed\":\"ok\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, headers_response, 1, "\"empty\":\"\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, headers_response, 1, "\"unicode\":\"café\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, headers_response, 1, "\"manyJoined\":\"0, 1, 2, 3"));
    try std.testing.expect(std.mem.containsAtLeast(u8, headers_response, 1, "\"manyTail\":\"v39\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, headers_response, 1, "\"manyCount\":41"));
    try std.testing.expect(std.mem.containsAtLeast(u8, headers_response, 1, "\"live\":\"a:1|b:2|c:3\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, headers_response, 1, "\"primitiveThrows\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, headers_response, 1, "\"boxedOk\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, headers_response, 1, "\"missingGetThrows\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, headers_response, 1, "\"missingSetThrows\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, headers_response, 1, "\"badNameThrows\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, headers_response, 1, "\"badValueThrows\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, headers_response, 1, "\"tag\":\"[object Headers]\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, headers_response, 1, "\"iteratorTag\":\"[object Headers Iterator]\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, headers_response, 1, "\"iteratorAlias\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, headers_response, 1, "\"instance\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, headers_response, 1, "\"callThrows\":true"));

    const request_headers_response = try runRouteAndReadBodyWithRequest(&runtime, control_pair[1],
        \\export default function handle(req) {
        \\    return Response.json({
        \\        repeat: req.headers.get("x-repeat"),
        \\        proto: req.headers.get("__proto__")
        \\    });
        \\}
    , 34, "/request-header-pairs.js", .{
        .path = "/headers",
        .headers = &[_]ipc.RequestHeader{
            .{ .name = "host", .value = "demo.test" },
            .{ .name = "x-repeat", .value = "a" },
            .{ .name = "x-repeat", .value = "b" },
            .{ .name = "__proto__", .value = "safe" },
        },
    });
    defer std.testing.allocator.free(request_headers_response);
    try std.testing.expect(std.mem.containsAtLeast(u8, request_headers_response, 1, "\"repeat\":\"a, b\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, request_headers_response, 1, "\"proto\":\"safe\""));

    const json_response = try runRouteAndReadBody(&runtime, control_pair[1],
        \\export default async function handle(req) {
        \\    let requestRejected = false;
        \\    let responseRejected = false;
        \\    try {
        \\        await req.json();
        \\    } catch (err) {
        \\        requestRejected = err instanceof SyntaxError;
        \\    }
        \\    try {
        \\        await new Response("").json();
        \\    } catch (err) {
        \\        responseRejected = err instanceof SyntaxError;
        \\    }
        \\    return Response.json({ requestRejected, responseRejected });
        \\}
    , 24, "/empty-json.js");
    defer std.testing.allocator.free(json_response);
    try std.testing.expect(std.mem.containsAtLeast(u8, json_response, 1, "\"requestRejected\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json_response, 1, "\"responseRejected\":true"));
}

test "URL parses absolute http URLs instead of treating them as paths" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = fakeNow,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    try runRouteAndExpectBody(&runtime, control_pair[1],
        \\export default function handle() {
        \\    const url = new URL("https://example.com:8443/path/name?x=1#hash");
        \\    return Response.json({
        \\        protocol: url.protocol,
        \\        host: url.host,
        \\        hostname: url.hostname,
        \\        port: url.port,
        \\        pathname: url.pathname,
        \\        search: url.search,
        \\        origin: url.origin
        \\    });
        \\}
    , 22, "/absolute-url.js", "\"origin\":\"https://example.com:8443\"");
}

test "URL and URLSearchParams use WTF form encoding and stay associated" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = fakeNow,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    try runRouteAndExpectBody(&runtime, control_pair[1],
        \\let failures;
        \\function assert(value, label) {
        \\    if (!value)
        \\        failures.push(label);
        \\}
        \\export default function handle() {
        \\    failures = [];
        \\    const url = new URL("../a b?x=hello+world", "https://Example.COM:443/base/path?old=1#frag");
        \\    assert(url.origin === "https://example.com", "origin");
        \\    assert(url.pathname === "/a%20b", "relative-path");
        \\    const originCases = [
        \\        ["https://example.com", "https:", "https://example.com"],
        \\        ["about:blank", "about:", "null"],
        \\        ["ftp://example.com", "ftp:", "ftp://example.com"],
        \\        ["file://example.com", "file:", "null"],
        \\        ["ws://example.com", "ws:", "ws://example.com"],
        \\        ["wss://example.com", "wss:", "wss://example.com"],
        \\        ["data:text/plain,Hello%2C%20World!", "data:", "null"],
        \\        ["javascript:alert('Hello World!')", "javascript:", "null"],
        \\        ["blob:https://example.com/1234-5678", "blob:", "https://example.com"],
        \\        ["blob:ws://example.com", "blob:", "ws://example.com"],
        \\        ["blob:kjka://example.com", "blob:", "null"],
        \\    ];
        \\    for (const [input, protocol, origin] of originCases) {
        \\        const item = new URL(input);
        \\        assert(item.protocol === protocol, "protocol-" + input);
        \\        assert(item.origin === origin, "origin-" + input);
        \\    }
        \\    assert(url.searchParams === url.searchParams, "stable-search-params");
        \\    assert(url.searchParams.get("x") === "hello world", "plus-decodes-to-space");
        \\    url.searchParams.append("space", "a b");
        \\    assert(url.search === "?x=hello+world&space=a+b", "append-syncs-url");
        \\    url.search = "?a=1&a=2&b=3";
        \\    assert(url.searchParams.getAll("a").join(",") === "1,2", "search-resets-params");
        \\    url.searchParams.delete("a", "1");
        \\    assert(url.search === "?a=2&b=3", "delete-second-argument");
        \\    url.searchParams.set("b", "hello world");
        \\    assert(url.search === "?a=2&b=hello+world", "set-form-encodes-space");
        \\    const numericDelete = new URLSearchParams("a=1&a=2&b=3");
        \\    numericDelete.delete("a", 1);
        \\    numericDelete.delete("b", undefined);
        \\    assert(numericDelete.toString() === "a=2", "delete-second-argument-coerces");
        \\    const numericHas = new URLSearchParams("a=1&a=2&b=3");
        \\    assert(numericHas.has("a", 1), "has-second-argument-coerces");
        \\    assert(numericHas.has("b", 4) === false, "has-second-argument-miss");
        \\    const params = new URLSearchParams([["z", "2"], ["a", "hello world"]]);
        \\    params.sort();
        \\    assert(params.toString() === "a=hello+world&z=2", "standalone-sort-serialize");
        \\    const size = Object.getOwnPropertyDescriptor(URLSearchParams.prototype, "size");
        \\    assert(size.configurable === true && size.enumerable === true, "size-descriptor");
        \\    const href = Object.getOwnPropertyDescriptor(URL.prototype, "href");
        \\    assert(href.configurable === true && href.enumerable === true, "url-href-descriptor");
        \\    assert(Object.prototype.toString.call(url) === "[object URL]", "url-to-string-tag");
        \\    assert(Object.prototype.toString.call(url.searchParams) === "[object URLSearchParams]", "searchparams-to-string-tag");
        \\    assert(Object.prototype.toString.call(url.searchParams.entries()) === "[object URLSearchParams Iterator]", "iterator-to-string-tag");
        \\    assert(url.searchParams[Symbol.iterator] === url.searchParams.entries, "iterator-alias");
        \\    assert(Object.getOwnPropertyDescriptor(URLSearchParams.prototype, Symbol.iterator).enumerable === false, "iterator-symbol-non-enumerable");
        \\    const iterated = Array.from(new URLSearchParams("i=1&i=2").entries()).map((pair) => pair.join(":")).join(",");
        \\    assert(iterated === "i:1,i:2", "iterator-next-order");
        \\    assert(url instanceof URL, "url-instanceof");
        \\    assert(url.searchParams instanceof URLSearchParams, "params-instanceof");
        \\    assert(new URLSearchParams({ q: "hello world" }).toString() === "q=hello+world", "record-init");
        \\    const iterableParams = new URLSearchParams({
        \\        *[Symbol.iterator]() {
        \\            yield ["k", "v"];
        \\            yield ["space", "a b"];
        \\        }
        \\    });
        \\    assert(iterableParams.toString() === "k=v&space=a+b", "custom-iterable-init");
        \\    function throwsTypeError(fn) {
        \\        try {
        \\            fn();
        \\            return false;
        \\        } catch (err) {
        \\            return err instanceof TypeError;
        \\        }
        \\    }
        \\    const arityParams = new URLSearchParams();
        \\    assert(throwsTypeError(() => arityParams.append("a")), "append-requires-value");
        \\    assert(throwsTypeError(() => arityParams.set("a")), "set-requires-value");
        \\    assert(throwsTypeError(() => arityParams.get()), "get-requires-name");
        \\    assert(throwsTypeError(() => arityParams.getAll()), "getall-requires-name");
        \\    assert(throwsTypeError(() => arityParams.has()), "has-requires-name");
        \\    assert(throwsTypeError(() => arityParams.delete()), "delete-requires-name");
        \\    let urlCallThrows = false;
        \\    try {
        \\        URL("https://example.com");
        \\    } catch (_) {
        \\        urlCallThrows = true;
        \\    }
        \\    assert(urlCallThrows, "url-requires-new");
        \\    let paramsCallThrows = false;
        \\    try {
        \\        URLSearchParams("a=1");
        \\    } catch (_) {
        \\        paramsCallThrows = true;
        \\    }
        \\    assert(paramsCallThrows, "params-requires-new");
        \\    const props = [];
        \\    for (const prop in url)
        \\        props.push(prop);
        \\    assert(props.sort().join(",") === "hash,host,hostname,href,origin,password,pathname,port,protocol,search,searchParams,toJSON,toString,username", "url-enumerable-props");
        \\    assert(URL.canParse("/x", "https://example.com") === true, "can-parse-with-base");
        \\    assert(URL.canParse("/x") === false, "cannot-parse-relative-without-base");
        \\    assert(throwsTypeError(() => URL.canParse()), "can-parse-missing-throws");
        \\    assert(URL.canParse(undefined, undefined) === false, "can-parse-undefined-base-false");
        \\    assert(URL.canParse("a:b") === true, "can-parse-absolute-nonspecial");
        \\    assert(URL.canParse("https://test:test") === false, "can-parse-invalid-port");
        \\    return Response.json({ ok: failures.length === 0, failures });
        \\}
    , 23, "/url-search-params-wtf.js", "\"ok\":true");
}

test "web api count caps reject form data url params and codec stream floods" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = fakeNow,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const response = try runRouteAndReadBody(&runtime, control_pair[1],
        \\const isQuota = (err) => err instanceof DOMException && err.name === "QuotaExceededError";
        \\export default async function handle() {
        \\    const urlencodedType = { headers: { "content-type": "application/x-www-form-urlencoded" } };
        \\    let urlencodedError = null;
        \\    try {
        \\        const flood = Array.from({ length: 1001 }, (_, index) => `k${index}=v`).join("&");
        \\        await new Response(flood, urlencodedType).formData();
        \\    } catch (err) {
        \\        urlencodedError = err;
        \\    }
        \\    const urlencodedRejected = isQuota(urlencodedError)
        \\        && urlencodedError.message === "form data entry count exceeded";
        \\    const underCap = await new Response("a=1&b=2", urlencodedType).formData();
        \\    const urlencodedWithinCapWorks = underCap.get("a") === "1" && Array.from(underCap).length === 2;
        \\
        \\    let blobError = null;
        \\    try {
        \\        await new Blob([new Uint8Array(4 * 1024 * 1024 + 1)],
        \\            { type: "application/x-www-form-urlencoded" }).formData();
        \\    } catch (err) {
        \\        blobError = err;
        \\    }
        \\    const oversizedBlobRejected = isQuota(blobError);
        \\
        \\    let boundaryError = null;
        \\    try {
        \\        await new Response("--x--", {
        \\            headers: { "content-type": "multipart/form-data; boundary=" + "b".repeat(1024 * 1024) }
        \\        }).formData();
        \\    } catch (err) {
        \\        boundaryError = err;
        \\    }
        \\    const giantBoundaryRejected = boundaryError instanceof TypeError;
        \\
        \\    const writer = new TextEncoderStream().writable.getWriter();
        \\    const writes = [];
        \\    for (let index = 0; index < 4200; index++)
        \\        writes.push(writer.write(""));
        \\    const settled = await Promise.allSettled(writes);
        \\    const codecCountCapRejected = settled.some(
        \\        (entry) => entry.status === "rejected" && isQuota(entry.reason));
        \\
        \\    let paramsInitError = null;
        \\    try {
        \\        new URLSearchParams("a&".repeat(8200));
        \\    } catch (err) {
        \\        paramsInitError = err;
        \\    }
        \\    const paramsInitRejected = isQuota(paramsInitError);
        \\    const appendParams = new URLSearchParams();
        \\    let paramsAppendError = null;
        \\    try {
        \\        for (let index = 0; index < 8300; index++)
        \\            appendParams.append("k", "v");
        \\    } catch (err) {
        \\        paramsAppendError = err;
        \\    }
        \\    const paramsAppendRejected = isQuota(paramsAppendError) && appendParams.size === 8192;
        \\    const paramsWithinCapWorks = new URLSearchParams("a=1&b=2").size === 2;
        \\
        \\    // JS-side Headers stay uncapped (the 256-entry cap is enforced at
        \\    // response extraction, covered by the ingress 500 test).
        \\    const manyHeaders = new Headers();
        \\    for (let index = 0; index < 300; index++)
        \\        manyHeaders.set(`x-h-${index}`, "v");
        \\    const headersJsSideUncapped = Array.from(manyHeaders).length === 300;
        \\
        \\    return Response.json({
        \\        urlencodedRejected,
        \\        urlencodedWithinCapWorks,
        \\        oversizedBlobRejected,
        \\        giantBoundaryRejected,
        \\        codecCountCapRejected,
        \\        paramsInitRejected,
        \\        paramsAppendRejected,
        \\        paramsWithinCapWorks,
        \\        headersJsSideUncapped
        \\    });
        \\}
    , 40, "/webapi-count-caps.js");
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"urlencodedRejected\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"urlencodedWithinCapWorks\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"oversizedBlobRejected\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"giantBoundaryRejected\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"codecCountCapRejected\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"paramsInitRejected\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"paramsAppendRejected\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"paramsWithinCapWorks\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"headersJsSideUncapped\":true"));
}

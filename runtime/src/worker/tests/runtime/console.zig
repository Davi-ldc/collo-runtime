//! Covers how console calls in a handler become log lines: the formatter's
//! rendering of values, its bounds on adversarial inputs (ropes, huge
//! objects and BigInts, giant function names, typed arrays and boxed
//! values), the per-request line and byte budgets with their drop markers
//! and drop counter, and console and uncaught exception lines in the shared
//! page's log ring, also with a second runtime in the same process. Tests
//! that install their own sink see the formatter's output before the ring.
//! Runs in `worker-test`; the console API's Web behavior is covered by the
//! `webapi` lane.

const std = @import("std");
const support = @import("bindings_support");
const bindings = @import("collo_bindings");
const worker = @import("collo_worker");
const worker_shared_page = @import("collo_worker_state").page;
const log_limits = @import("collo_limits").runtime_logs;
const rt = @import("collo_test_harness");

const CapturedLine = struct {
    level: u8,
    flags: u8,
    request_id: u64,
    text: []u8,
};

const Capture = struct {
    lines: std.ArrayListUnmanaged(CapturedLine) = .{},

    fn deinit(self: *Capture) void {
        for (self.lines.items) |line|
            std.testing.allocator.free(line.text);
        self.lines.deinit(std.testing.allocator);
    }

    fn sink(
        ctx: ?*anyopaque,
        level: u8,
        flags: u8,
        request_id: u64,
        bytes: ?[*]const u8,
        len: usize,
    ) callconv(.c) void {
        const self: *Capture = @ptrCast(@alignCast(ctx.?));
        const payload: []const u8 = if (bytes) |b| b[0..len] else &.{};
        const copy = std.testing.allocator.dupe(u8, payload) catch return;
        self.lines.append(std.testing.allocator, .{
            .level = level,
            .flags = flags,
            .request_id = request_id,
            .text = copy,
        }) catch std.testing.allocator.free(copy);
    }

    fn expectLine(
        self: *const Capture,
        index: usize,
        level: bindings.ConsoleLevel,
        text: []const u8,
        request_id: u64,
    ) !void {
        if (index >= self.lines.items.len) {
            std.debug.print("missing console line {d}; got {d} lines\n", .{ index, self.lines.items.len });
            return error.TestUnexpectedResult;
        }
        const line = self.lines.items[index];
        try std.testing.expectEqual(@intFromEnum(level), line.level);
        try std.testing.expectEqualStrings(text, line.text);
        try std.testing.expectEqual(request_id, line.request_id);
    }
};

test "console formats primitives objects and control methods through the sink" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try rt.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = rt.fakeNow,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    var capture: Capture = .{};
    defer capture.deinit();
    try vm.setConsoleSink(
        Capture.sink,
        @ptrCast(&capture),
        worker_shared_page.LOG_LINE_BYTES_MAX,
        log_limits.CONSOLE_REQUEST_LINES_MAX,
        log_limits.CONSOLE_REQUEST_BYTES_MAX,
    );

    const response = try rt.runRouteAndReadBody(&runtime, control_pair[1],
        \\export default function handle() {
        \\    console.log("plain", 42, true, null, undefined);
        \\    console.log("%s has %d items", "cart", 3);
        \\    console.error("bad", { code: 7, nested: { deep: { deeper: 1 } } });
        \\    console.log({ get x() { throw new Error("never invoked"); }, y: 2 });
        \\    console.warn([1, "two", [3]]);
        \\    const circ = {};
        \\    circ.self = circ;
        \\    console.log(circ);
        \\    console.log(new Error("kaput"));
        \\    console.group("section");
        \\    console.log("inside");
        \\    console.groupEnd();
        \\    console.count();
        \\    console.count();
        \\    console.debug("dbg");
        \\    console.log("x".repeat(10000));
        \\    return new Response("console-ok");
        \\}
    , 91, "/console-golden.js");
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "console-ok"));

    try capture.expectLine(0, .info, "plain 42 true null undefined", 91);
    try capture.expectLine(1, .info, "cart has 3 items", 91);
    try capture.expectLine(2, .err, "bad { code: 7, nested: { deep: [Object] } }", 91);
    // An accessor property renders as `[Getter]` and is never invoked; this
    // getter throws if it is.
    try capture.expectLine(3, .info, "{ x: [Getter], y: 2 }", 91);
    try capture.expectLine(4, .warn, "[ 1, 'two', [ 3 ] ]", 91);
    try capture.expectLine(5, .info, "{ self: [Circular] }", 91);
    try capture.expectLine(6, .info, "Error: kaput", 91);
    try capture.expectLine(7, .info, "section", 91);
    try capture.expectLine(8, .info, "  inside", 91);
    try capture.expectLine(9, .info, "default: 1", 91);
    try capture.expectLine(10, .info, "default: 2", 91);
    try capture.expectLine(11, .debug, "dbg", 91);

    // The flood line is cut at the line byte budget with the truncated flag.
    const flood = capture.lines.items[12];
    try std.testing.expectEqual(@as(usize, worker_shared_page.LOG_LINE_BYTES_MAX), flood.text.len);
    try std.testing.expect(flood.flags & bindings.console_line_flag_truncated != 0);
    try std.testing.expectEqual(@as(usize, 13), capture.lines.items.len);
}

test "console bounds adversarial inputs and renders correct prefixes" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try rt.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = rt.fakeNow,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    var capture: Capture = .{};
    defer capture.deinit();
    try vm.setConsoleSink(
        Capture.sink,
        @ptrCast(&capture),
        worker_shared_page.LOG_LINE_BYTES_MAX,
        log_limits.CONSOLE_REQUEST_LINES_MAX,
        log_limits.CONSOLE_REQUEST_BYTES_MAX,
    );

    const response = try rt.runRouteAndReadBody(&runtime, control_pair[1],
        \\export default function handle() {
        \\    let a = ""; for (let i = 0; i < 8000; i++) a += String(i % 10);
        \\    console.log(a);
        \\    let b = ""; for (let i = 0; i < 8000; i++) b = String(i % 10) + b;
        \\    console.log(b);
        \\    const big = {}; for (let i = 0; i < 5000; i++) big["k" + i] = i;
        \\    console.log(big);
        \\    console.log(10n ** 100000n);
        \\    function f() {}
        \\    Object.defineProperty(f, "name", { value: "N".repeat(9000) });
        \\    console.log(f);
        \\    console.log((function base() {}).bind(null));
        \\    console.log(function hello() {});
        \\    console.log({ 0: "zero" });
        \\    console.log(new TypeError("t"));
        \\    console.log(new Error("M".repeat(9000)));
        \\    console.log(new RegExp("a".repeat(9000)));
        \\    console.count("L".repeat(5000));
        \\    console.log(new Uint8Array(5000000));
        \\    console.log(new String("s".repeat(5000000)));
        \\    console.count(10n ** 100000n);
        \\    console.count(Object(10n ** 100000n));
        \\    console.count({ [Symbol.toPrimitive]() { return 10n ** 100000n; } });
        \\    const smallBox = Object(10n ** 100000n);
        \\    smallBox[Symbol.toPrimitive] = () => "small";
        \\    console.count(smallBox);
        \\    return new Response("adversarial-ok");
        \\}
    , 77, "/console-adversarial.js");
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "adversarial-ok"));

    const max = worker_shared_page.LOG_LINE_BYTES_MAX;

    // A rope built by appending leans left. `JSString::colloCopyPrefix`, from
    // WebKit patch 0003-string-prefix-copy-and-console-label-clamp, copies
    // its exact leading bytes without resolving the 8000-unit rope.
    const rope_append = capture.lines.items[0];
    try std.testing.expectEqual(@as(usize, max), rope_append.text.len);
    try std.testing.expect(rope_append.flags & bindings.console_line_flag_truncated != 0);
    var expected_append: [max]u8 = undefined;
    for (&expected_append, 0..) |*c, i| c.* = '0' + @as(u8, @intCast(i % 10));
    try std.testing.expectEqualStrings(expected_append[0..], rope_append.text);

    // A rope built by prepending leans right, and its first character comes
    // from the last iteration (i = 7999).
    const rope_prepend = capture.lines.items[1];
    try std.testing.expectEqual(@as(usize, max), rope_prepend.text.len);
    try std.testing.expect(rope_prepend.flags & bindings.console_line_flag_truncated != 0);
    var expected_prepend: [max]u8 = undefined;
    for (&expected_prepend, 0..) |*c, i| c.* = '0' + @as(u8, @intCast((7999 - i) % 10));
    try std.testing.expectEqualStrings(expected_prepend[0..], rope_prepend.text);

    // Past `inspect_max_enumerated_properties`
    // (`bindings/jsc/runtime/console_client.cpp`) the object renders
    // opaquely instead of materializing 5000 property names to show
    // `inspect_max_properties` of them.
    try capture.expectLine(2, .info, "{ \u{2026} }", 77);
    // Rendering the 100001-digit BigInt would materialize about 100 KB of
    // decimal digits, far past the line budget.
    try capture.expectLine(3, .info, "[BigInt]", 77);
    // The redefined name is an own property, read raw and prefix-copied to
    // `inspect_max_nested_string_units`.
    const fn_name_expected = "[Function: " ++ ("N" ** 512) ++ "\u{2026}]";
    try capture.expectLine(4, .info, fn_name_expected, 77);
    // A bound function whose lazy name was never reified renders without
    // running `JSBoundFunction::nameSlow`, which would build the whole
    // "bound ..." chain.
    try capture.expectLine(5, .info, "[Function (bound)]", 77);
    // An unreified plain function name comes from the executable.
    try capture.expectLine(6, .info, "[Function: hello]", 77);
    // An indexed property lives in the butterfly, where `getDirect` misses
    // it; it renders as the data it is, not as `[Getter]`.
    try capture.expectLine(7, .info, "{ 0: 'zero' }", 77);
    // A built-in error keeps `name` on its prototype, which the bounded
    // `getDirect` walk reaches.
    try capture.expectLine(8, .info, "TypeError: t", 77);

    const giant_error = capture.lines.items[9];
    try std.testing.expectEqual(@as(usize, max), giant_error.text.len);
    try std.testing.expect(giant_error.flags & bindings.console_line_flag_truncated != 0);
    const error_expected = "Error: " ++ ("M" ** (max - 7));
    try std.testing.expectEqualStrings(error_expected, giant_error.text);

    const giant_regexp = capture.lines.items[10];
    try std.testing.expectEqual(@as(usize, max), giant_regexp.text.len);
    try std.testing.expect(giant_regexp.flags & bindings.console_line_flag_truncated != 0);
    const regexp_expected = "/" ++ ("a" ** (max - 1));
    try std.testing.expectEqualStrings(regexp_expected, giant_regexp.text);

    // The label coercion is clamped in `ConsoleObject.cpp` by WebKit patch
    // 0003, and `normalizedLabel` then caps the key at exactly
    // `label_units_max` units, the last of them the ellipsis.
    const count_expected = ("L" ** 255) ++ "\u{2026}: 1";
    try capture.expectLine(11, .info, count_expected, 77);

    // Typed arrays and boxed strings keep their elements outside the
    // structure and the butterfly. The enumeration guard counts their length
    // anyway, or listing their names would materialize one Identifier per
    // element on the WTF heap.
    try capture.expectLine(12, .info, "Uint8Array { \u{2026} }", 77);
    try capture.expectLine(13, .info, "String { \u{2026} }", 77);

    // A count label is coerced by `colloClampedToWTFString` in patch 0003,
    // which refuses a giant BigInt before `toString` materializes its
    // digits; the formatter's own BigInt guard never sees labels.
    try capture.expectLine(14, .info, "[BigInt]: 1", 77);
    // A boxed BigInt gets the same label: ToPrimitive unwraps the box, the
    // guard sees the BigInt inside, and the count shares the key with the
    // bare value. Labels that differ only past the cap collide by design.
    try capture.expectLine(15, .info, "[BigInt]: 2", 77);
    // `Symbol.toPrimitive` returning a giant BigInt is caught too, because
    // the guard checks what ToPrimitive returned rather than the argument.
    try capture.expectLine(16, .info, "[BigInt]: 3", 77);
    // An override that coerces a boxed BigInt to a small string is honored:
    // the guard sees "small", not the wrapped BigInt.
    try capture.expectLine(17, .info, "small: 1", 77);

    try std.testing.expectEqual(@as(usize, 18), capture.lines.items.len);
}

test "exception lines reach the owning runtime with a second runtime attached" {
    var vm_a = try support.createVm();
    defer vm_a.deinit();
    var vm_b = try support.createVm();
    defer vm_b.deinit();

    const pair_a = try rt.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(pair_a[0]);
    defer std.posix.close(pair_a[1]);
    const pair_b = try rt.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(pair_b[0]);
    defer std.posix.close(pair_b[1]);

    const page_fd = try worker_shared_page.createMemfd("console-ring-two-runtimes");
    defer std.posix.close(page_fd);
    var view = try worker_shared_page.mapReadWrite(page_fd);
    defer view.deinit();
    view.initializeCrashDefault(1, 64 * 1024 * 1024, 1);

    var now_a: u64 = 1_000;
    var runtime_a = try worker.Runtime.init(std.testing.allocator, &vm_a, pair_a[0], &view, try rt.createCompletionEventfd(), .{
        .ctx = &now_a,
        .now_fn = rt.fakeNow,
    });
    defer runtime_a.deinit();
    try runtime_a.attachHostRuntime();

    // B registers after A. The exception sink registry keeps a slot per VM
    // (`worker/js/jsc/exception_log.zig`); with a single slot, B's
    // registration would replace A's and A's exceptions would never reach
    // A's ring.
    var now_b: u64 = 2_000;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime_b = try worker.Runtime.init(std.testing.allocator, &vm_b, pair_b[0], &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = &now_b,
        .now_fn = rt.fakeNow,
    });
    defer runtime_b.deinit();
    try runtime_b.attachHostRuntime();

    const body = rt.runRouteAndReadBody(&runtime_a, pair_a[1],
        \\export default function handle() {
        \\    throw new Error("owned-by-a");
        \\}
    , 21, "/two-runtimes-crash.js") catch |err| blk: {
        std.debug.print("crash route response read: {s}\n", .{@errorName(err)});
        break :blk try std.testing.allocator.dupe(u8, "");
    };
    defer std.testing.allocator.free(body);

    var scratch: [worker_shared_page.LOG_LINE_BYTES_MAX]u8 = undefined;
    var out: [8]worker_shared_page.DrainedLogLine = undefined;
    const drained = try view.drainLogLinesChecked(&scratch, &out);
    try std.testing.expect(drained >= 1);
    try std.testing.expect(out[0].header.flags & worker_shared_page.LogLineFlags.js_exception != 0);
    try std.testing.expect(std.mem.containsAtLeast(u8, out[0].payload, 1, "owned-by-a"));
    try std.testing.expectEqual(@as(u64, 21), out[0].header.request_id);
}

test "per-request line cap drops the 257th line into the ring counter and resets per request" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try rt.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    const page_fd = try worker_shared_page.createMemfd("console-request-line-cap");
    defer std.posix.close(page_fd);
    var view = try worker_shared_page.mapReadWrite(page_fd);
    defer view.deinit();
    view.initializeCrashDefault(1, 64 * 1024 * 1024, 1);

    var now_mono_ns: u64 = 9_000;
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = rt.fakeNow,
    });
    defer runtime.deinit();
    // `attachHostRuntime` registers the production ring sink with the
    // production budgets, `CONSOLE_REQUEST_LINES_MAX` and
    // `CONSOLE_REQUEST_BYTES_MAX`, so this test runs the real enforcement
    // end to end.
    try runtime.attachHostRuntime();

    const response = try rt.runRouteAndReadBody(&runtime, control_pair[1],
        \\export default function handle() {
        \\    for (let i = 0; i < 300; i++) console.log("l" + i);
        \\    return new Response("cap-ok");
        \\}
    , 61, "/console-line-cap.js");
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "cap-ok"));

    // Exactly the first `CONSOLE_REQUEST_LINES_MAX` lines reach the ring. The
    // remaining 44 calls are never formatted and count as dropped lines.
    var scratch: [worker_shared_page.LOG_LINE_BYTES_MAX]u8 = undefined;
    var out: [64]worker_shared_page.DrainedLogLine = undefined;
    var drained_total: usize = 0;
    var last_line_buf: [32]u8 = undefined;
    var last_line_len: usize = 0;
    while (true) {
        const count = try view.drainLogLinesChecked(&scratch, &out);
        if (count == 0)
            break;
        drained_total += count;
        const last = out[count - 1];
        last_line_len = last.payload.len;
        @memcpy(last_line_buf[0..last.payload.len], last.payload);
    }
    try std.testing.expectEqual(@as(usize, log_limits.CONSOLE_REQUEST_LINES_MAX), drained_total);
    try std.testing.expectEqualStrings("l255", last_line_buf[0..last_line_len]);
    try std.testing.expectEqual(@as(u64, 44), view.loadLogDropCounters().lines);

    // A second request starts with a fresh budget, since request cleanup
    // clears the spent one, and the counter does not move again.
    const response2 = try rt.runRouteAndReadBody(&runtime, control_pair[1],
        \\export default function handle() {
        \\    console.log("after");
        \\    return new Response("cap-ok-2");
        \\}
    , 62, "/console-line-cap-2.js");
    defer std.testing.allocator.free(response2);
    const count2 = try view.drainLogLinesChecked(&scratch, &out);
    try std.testing.expectEqual(@as(usize, 1), count2);
    try std.testing.expectEqualStrings("after", out[0].payload);
    try std.testing.expectEqual(@as(u64, 62), out[0].header.request_id);
    try std.testing.expectEqual(@as(u64, 44), view.loadLogDropCounters().lines);
}

test "per-request byte budget stops emission and surfaces drop markers" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try rt.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = rt.fakeNow,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    var capture: Capture = .{};
    defer capture.deinit();
    // A small byte budget trips before the line cap. The budget is checked
    // before each call: with 4000-byte lines, line 3 still starts under 10000
    // and is emitted, and calls 4 and 5 arrive only as budget-dropped
    // markers.
    try vm.setConsoleSink(
        Capture.sink,
        @ptrCast(&capture),
        worker_shared_page.LOG_LINE_BYTES_MAX,
        log_limits.CONSOLE_REQUEST_LINES_MAX,
        10_000,
    );

    const response = try rt.runRouteAndReadBody(&runtime, control_pair[1],
        \\export default function handle() {
        \\    for (let i = 0; i < 5; i++) console.log("x".repeat(4000));
        \\    return new Response("byte-cap-ok");
        \\}
    , 63, "/console-byte-cap.js");
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "byte-cap-ok"));

    try std.testing.expectEqual(@as(usize, 5), capture.lines.items.len);
    for (capture.lines.items[0..3]) |line| {
        try std.testing.expectEqual(@as(usize, 4000), line.text.len);
        try std.testing.expect(line.flags & bindings.console_line_flag_budget_dropped == 0);
    }
    for (capture.lines.items[3..5]) |marker| {
        try std.testing.expectEqual(@as(usize, 0), marker.text.len);
        try std.testing.expect(marker.flags & bindings.console_line_flag_budget_dropped != 0);
        try std.testing.expectEqual(@as(u64, 63), marker.request_id);
    }
}

test "console and uncaught exception lines land in the shared page log ring" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try rt.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    const page_fd = try worker_shared_page.createMemfd("console-ring-e2e");
    defer std.posix.close(page_fd);
    var view = try worker_shared_page.mapReadWrite(page_fd);
    defer view.deinit();
    view.initializeCrashDefault(1, 64 * 1024 * 1024, 1);

    var now_mono_ns: u64 = 7_000;
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = rt.fakeNow,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const body = rt.runRouteAndReadBody(&runtime, control_pair[1],
        \\export default function handle() {
        \\    console.log("pre-crash");
        \\    throw new Error("explode");
        \\}
    , 55, "/console-crash.js") catch |err| blk: {
        // A throwing handler may terminate the response stream instead of
        // producing a body; the log ring assertions below are the test.
        std.debug.print("crash route response read: {s}\n", .{@errorName(err)});
        break :blk try std.testing.allocator.dupe(u8, "");
    };
    defer std.testing.allocator.free(body);

    var scratch: [worker_shared_page.LOG_LINE_BYTES_MAX]u8 = undefined;
    var out: [8]worker_shared_page.DrainedLogLine = undefined;
    const drained = try view.drainLogLinesChecked(&scratch, &out);
    try std.testing.expect(drained >= 2);

    try std.testing.expectEqual(@intFromEnum(worker_shared_page.LogLevel.info), out[0].header.level);
    try std.testing.expectEqualStrings("pre-crash", out[0].payload);
    try std.testing.expectEqual(@as(u64, 55), out[0].header.request_id);
    try std.testing.expectEqual(@as(u64, 7_000), out[0].header.ts_mono_ns);

    try std.testing.expectEqual(@intFromEnum(worker_shared_page.LogLevel.err), out[1].header.level);
    try std.testing.expect(out[1].header.flags & worker_shared_page.LogLineFlags.js_exception != 0);
    try std.testing.expect(std.mem.containsAtLeast(u8, out[1].payload, 1, "explode"));
    try std.testing.expectEqual(@as(u64, 55), out[1].header.request_id);
}

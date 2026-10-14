//! A promise reaction runs under the owner that registered it, not the one that settles the
//! promise: a request, or the turnless context module evaluation runs under, and a reaction
//! whose owner was released runs with none. Most tests drive two turns over one VM, request A
//! registering and request B settling, and read the owner back from the console sink, which
//! stamps every line with the owner `Collo::ownerExecCtx` (`jsc/runtime/state.h`) names when
//! the line was produced. Host APIs resolve their caller the same way (`activeExecContext` in
//! `host_functions/runtime/bridge.cpp`), and the owner transition hook hears each hand-over,
//! which `collo_vm_owner_crossings` counts.
//! Lane: `bindings-test`. Attribution across two live requests in a worker is covered in
//! `worker-test` (`worker/tests/runtime/multiplexing.zig`).

const std = @import("std");
const support = @import("bindings_support");
const bindings = support.bindings;

const request_a: u64 = 11;
const request_b: u64 = 22;

/// Counts console lines per request id and keeps the first `max_kept` lines, each cut to the
/// size of `text`, so a test can name which line it means.
const OwnerCapture = struct {
    const max_kept = 8;
    const Kept = struct {
        request_id: u64,
        text: [64]u8,
        len: usize,
    };

    a_lines: usize = 0,
    b_lines: usize = 0,
    other_lines: usize = 0,
    kept: [max_kept]Kept = undefined,
    kept_count: usize = 0,

    fn sink(
        ctx: ?*anyopaque,
        level: u8,
        flags: u8,
        request_id: u64,
        bytes: ?[*]const u8,
        len: usize,
    ) callconv(.c) void {
        _ = level;
        _ = flags;
        const self: *OwnerCapture = @ptrCast(@alignCast(ctx orelse return));
        switch (request_id) {
            request_a => self.a_lines += 1,
            request_b => self.b_lines += 1,
            else => self.other_lines += 1,
        }
        if (self.kept_count == max_kept) return;
        const slot = &self.kept[self.kept_count];
        slot.request_id = request_id;
        slot.len = @min(len, slot.text.len);
        if (bytes) |ptr|
            @memcpy(slot.text[0..slot.len], ptr[0..slot.len]);
        self.kept_count += 1;
    }

    fn install(self: *OwnerCapture, vm: *bindings.Vm, lines_max: usize) !void {
        try vm.setConsoleSink(OwnerCapture.sink, self, 4096, lines_max, 1 << 20);
    }

    /// The request that produced the first line containing `needle`.
    fn ownerOf(self: *const OwnerCapture, needle: []const u8) ?u64 {
        for (self.kept[0..self.kept_count]) |line| {
            if (std.mem.indexOf(u8, line.text[0..line.len], needle) != null)
                return line.request_id;
        }
        return null;
    }
};

/// Two requests, both alive for the whole test. The owner table is keyed by `ColloExecCtx*`,
/// so two contexts that took turns in one stack slot would be one owner to the engine and the
/// tests could not tell them apart. `deinit` drops both registrations, which
/// `Vm.releaseExecCtx` requires before the storage goes.
const TwoRequests = struct {
    a: bindings.ExecCtx,
    b: bindings.ExecCtx,

    fn init() TwoRequests {
        return .{ .a = support.makeExecCtx(request_a), .b = support.makeExecCtx(request_b) };
    }

    fn deinit(self: *TwoRequests, vm: *bindings.Vm) void {
        vm.releaseExecCtx(&self.a) catch {};
        vm.releaseExecCtx(&self.b) catch {};
    }
};

/// Runs `export_name` inside a turn owned by `exec_ctx`, then leaves the turn so
/// the microtask queue drains. Draining on exit is what makes the settling turn
/// the one that runs the other request's continuation.
fn runTurn(
    vm: *bindings.Vm,
    specifier: []const u8,
    export_name: []const u8,
    exec_ctx: *bindings.ExecCtx,
) !void {
    var callable = try support.getExportOk(vm, specifier, export_name);
    defer callable.deinit();

    try vm.turnEnter(exec_ctx);
    var result = try support.invokeOk(vm, exec_ctx, &callable, &.{});
    result.deinit();
    try vm.turnExit();
}

test "a promise continuation runs under the request that registered it" {
    var vm = try support.createVm();
    defer vm.deinit();

    var capture = OwnerCapture{};
    try capture.install(&vm, 64);
    defer vm.setConsoleSink(null, null, 4096, 64, 1 << 20) catch {};

    const source =
        \\let settle = null;
        \\
        \\export function arm() {
        \\    const pending = new Promise((resolve) => { settle = resolve; });
        \\    pending.then(() => { console.log("continuation-of-a"); });
        \\}
        \\
        \\export function fire() {
        \\    settle(1);
        \\    console.log("settled-by-b");
        \\}
    ;
    try support.registerModule(&vm, "/owner.js", source);
    try support.evaluateOk(&vm, "/owner.js");

    var requests = TwoRequests.init();
    defer requests.deinit(&vm);

    try runTurn(&vm, "/owner.js", "arm", &requests.a);
    // Nothing has settled yet, so A's turn drained without running anything.
    try std.testing.expectEqual(@as(usize, 0), capture.kept_count);

    try runTurn(&vm, "/owner.js", "fire", &requests.b);

    // The line B produced itself belongs to B; the continuation A registered
    // belongs to A even though B's turn is what drained it.
    try std.testing.expectEqual(@as(?u64, request_b), capture.ownerOf("settled-by-b"));
    try std.testing.expectEqual(@as(?u64, request_a), capture.ownerOf("continuation-of-a"));
}

test "a stream reaction runs under the request that started the pipe, not the one that feeds it" {
    var vm = try support.createVm();
    defer vm.deinit();

    var capture = OwnerCapture{};
    try capture.install(&vm, 64);
    defer vm.setConsoleSink(null, null, 4096, 64, 1 << 20) catch {};

    const source =
        \\let controller = null;
        \\
        \\export function startPipe() {
        \\    const source = new ReadableStream({ start(c) { controller = c; } });
        \\    const destination = new WritableStream({
        \\        write(chunk) { console.log(`sink-wrote-${chunk}`); },
        \\    });
        \\    void source.pipeTo(destination);
        \\}
        \\
        \\export function enqueueChunk() {
        \\    controller.enqueue("chunk");
        \\    console.log("enqueued-by-b");
        \\}
    ;
    try support.registerModule(&vm, "/stream-owner.js", source);
    try support.evaluateOk(&vm, "/stream-owner.js");

    var requests = TwoRequests.init();
    defer requests.deinit(&vm);

    try runTurn(&vm, "/stream-owner.js", "startPipe", &requests.a);
    // The source holds no chunk, so A's turn ended with the pipe's read pending.
    try std.testing.expectEqual(@as(usize, 0), capture.kept_count);

    try runTurn(&vm, "/stream-owner.js", "enqueueChunk", &requests.b);

    // B's enqueue fulfills the read A's pipe registered; the pipe's read reaction writes the
    // chunk under A, so the sink's line belongs to A.
    try std.testing.expectEqual(@as(?u64, request_b), capture.ownerOf("enqueued-by-b"));
    try std.testing.expectEqual(@as(?u64, request_a), capture.ownerOf("sink-wrote-chunk"));
}

test "every reaction on one promise carries its own registering request" {
    var vm = try support.createVm();
    defer vm.deinit();

    var capture = OwnerCapture{};
    try capture.install(&vm, 64);
    defer vm.setConsoleSink(null, null, 4096, 64, 1 << 20) catch {};

    // The first `.then` finds a promise with no reaction, where the engine would store the
    // reaction inline. The second links onto an existing reaction, and had the first gone
    // inline, `JSPromise::reactionHead` would spill it into a cell that records no owner. Both
    // reactions have to carry A.
    const source =
        \\let settle = null;
        \\export function arm() {
        \\    const pending = new Promise((resolve) => { settle = resolve; });
        \\    pending.then(() => { console.log("first-reaction"); });
        \\    pending.then(() => { console.log("second-reaction"); });
        \\}
        \\export function fire() { settle(1); }
    ;
    try support.registerModule(&vm, "/probe.js", source);
    try support.evaluateOk(&vm, "/probe.js");

    var requests = TwoRequests.init();
    defer requests.deinit(&vm);

    try runTurn(&vm, "/probe.js", "arm", &requests.a);
    try runTurn(&vm, "/probe.js", "fire", &requests.b);

    try std.testing.expectEqual(@as(?u64, request_a), capture.ownerOf("first-reaction"));
    try std.testing.expectEqual(@as(?u64, request_a), capture.ownerOf("second-reaction"));
    try std.testing.expectEqual(@as(usize, 0), capture.b_lines);
}

test "work a restored continuation enqueues keeps the registering request" {
    var vm = try support.createVm();
    defer vm.deinit();

    var capture = OwnerCapture{};
    try capture.install(&vm, 64);
    defer vm.setConsoleSink(null, null, 4096, 64, 1 << 20) catch {};

    // The owner recorded on a reaction covers one hop. The second and third hops are work the
    // restored continuation enqueues itself, which keeps its owner only through the cross-task
    // token installed while a restored continuation runs (`ColloCrossTaskToken` in
    // `jsc/runtime/vm.cpp`).
    const source =
        \\let settle = null;
        \\
        \\export function arm() {
        \\    const pending = new Promise((resolve) => { settle = resolve; });
        \\    pending.then(() => {
        \\        queueMicrotask(() => {
        \\            console.log("second-hop");
        \\            Promise.resolve().then(() => { console.log("third-hop"); });
        \\        });
        \\    });
        \\}
        \\
        \\export function fire() { settle(1); }
    ;
    try support.registerModule(&vm, "/hops.js", source);
    try support.evaluateOk(&vm, "/hops.js");

    var requests = TwoRequests.init();
    defer requests.deinit(&vm);

    try runTurn(&vm, "/hops.js", "arm", &requests.a);
    try runTurn(&vm, "/hops.js", "fire", &requests.b);
    try std.testing.expectEqual(@as(?u64, request_a), capture.ownerOf("second-hop"));
    try std.testing.expectEqual(@as(?u64, request_a), capture.ownerOf("third-hop"));
}

test "a reaction of the draining turn is not re-tagged by a restored continuation" {
    var vm = try support.createVm();
    defer vm.deinit();

    var capture = OwnerCapture{};
    try capture.install(&vm, 64);
    defer vm.setConsoleSink(null, null, 4096, 64, 1 << 20) catch {};

    // B's turn settles A's promise and then drains the queue; A's restored continuation settles
    // a promise B registered on. That reaction's owner is B while A is running, so the engine
    // must enqueue it under B. The ordinary enqueue would stamp the running owner, A, onto work
    // that was never A's.
    const source =
        \\let settleA = null;
        \\let settleB = null;
        \\
        \\export function armA() {
        \\    const pendingA = new Promise((resolve) => { settleA = resolve; });
        \\    pendingA.then(() => { settleB(1); });
        \\}
        \\
        \\export function armAndFireB() {
        \\    const pendingB = new Promise((resolve) => { settleB = resolve; });
        \\    pendingB.then(() => { console.log("reaction-of-b"); });
        \\    settleA(1);
        \\}
    ;
    try support.registerModule(&vm, "/retag.js", source);
    try support.evaluateOk(&vm, "/retag.js");

    var requests = TwoRequests.init();
    defer requests.deinit(&vm);

    try runTurn(&vm, "/retag.js", "armA", &requests.a);
    try runTurn(&vm, "/retag.js", "armAndFireB", &requests.b);

    try std.testing.expectEqual(@as(?u64, request_b), capture.ownerOf("reaction-of-b"));
    try std.testing.expectEqual(@as(usize, 0), capture.a_lines);
}

test "only a reaction restored over another owner counts as an owner crossing" {
    var vm = try support.createVm();
    defer vm.deinit();

    // The scenario above: A's continuation, restored over B, settles a promise B registered on,
    // so B's reaction is enqueued under B and later restored to B while B itself drains. That
    // second restore changes no owner, so only A's counts.
    const source =
        \\let settleA = null;
        \\let settleB = null;
        \\
        \\export function armA() {
        \\    const pendingA = new Promise((resolve) => { settleA = resolve; });
        \\    pendingA.then(() => { settleB(1); });
        \\}
        \\
        \\export function armAndFireB() {
        \\    const pendingB = new Promise((resolve) => { settleB = resolve; });
        \\    pendingB.then(() => {});
        \\    settleA(1);
        \\}
    ;
    try support.registerModule(&vm, "/crossings.js", source);
    try support.evaluateOk(&vm, "/crossings.js");

    var requests = TwoRequests.init();
    defer requests.deinit(&vm);

    const before = vm.ownerCrossings();
    try runTurn(&vm, "/crossings.js", "armA", &requests.a);
    try std.testing.expectEqual(before, vm.ownerCrossings());
    try runTurn(&vm, "/crossings.js", "armAndFireB", &requests.b);
    try std.testing.expectEqual(before + 1, vm.ownerCrossings());
}

test "a hot then site keeps the owner once the JIT compiles it" {
    var vm = try support.createVm();
    defer vm.deinit();

    var capture = OwnerCapture{};
    // One line per continuation, so the budget has to clear the loop count.
    try capture.install(&vm, 8192);
    defer vm.setConsoleSink(null, null, 4096, 8192, 1 << 20) catch {};

    // The DFG can lower `.then` on a promise with no reaction into an inline write on the
    // promise itself, which never reaches `performPromiseThen`, where the owner is captured; the
    // microtask owner patch in `runtime/patches/webkit/` makes that classification decline.
    // Reaching the lowering takes a call site hot enough to tier up and a fresh promise on every
    // call. Every registration happens under A and every settle under B, so one continuation
    // attributed to B means the tiered path dropped the owner.
    const source =
        \\const pending = [];
        \\const settles = [];
        \\
        \\function attach(promise) {
        \\    return promise.then(() => { console.log("hot"); });
        \\}
        \\
        \\export function arm() {
        \\    for (let i = 0; i < 4000; i++) {
        \\        const p = new Promise((resolve) => { settles.push(resolve); });
        \\        attach(p);
        \\        pending.push(p);
        \\    }
        \\}
        \\
        \\export function fire() {
        \\    for (const resolve of settles) resolve(1);
        \\}
    ;
    try support.registerModule(&vm, "/hot.js", source);
    try support.evaluateOk(&vm, "/hot.js");

    var requests = TwoRequests.init();
    defer requests.deinit(&vm);

    try runTurn(&vm, "/hot.js", "arm", &requests.a);
    try runTurn(&vm, "/hot.js", "fire", &requests.b);
    try std.testing.expectEqual(@as(usize, 4000), capture.a_lines);
    try std.testing.expectEqual(@as(usize, 0), capture.b_lines);
    try std.testing.expectEqual(@as(usize, 0), capture.other_lines);
}

// Ids above `bindings.request_id_max`, as a worker gives its module evaluations.
const evaluation_first: u64 = bindings.request_id_max + 1;
const evaluation_second: u64 = bindings.request_id_max + 2;

/// Records the owner transition hook's calls as (leaving, entering) request ids, 0 for no owner.
const TransitionCapture = struct {
    const max_kept = 8;
    pairs: [max_kept][2]u64 = undefined,
    count: usize = 0,

    fn hook(ctx: ?*anyopaque, leaving: ?*bindings.ExecCtx, entering: ?*bindings.ExecCtx) callconv(.c) void {
        const self: *TransitionCapture = @ptrCast(@alignCast(ctx orelse return));
        if (self.count == max_kept) return;
        self.pairs[self.count] = .{
            if (leaving) |exec_ctx| exec_ctx.request_id else 0,
            if (entering) |exec_ctx| exec_ctx.request_id else 0,
        };
        self.count += 1;
    }

    fn expectPairs(self: *const TransitionCapture, expected: []const [2]u64) !void {
        try std.testing.expectEqual(expected.len, self.count);
        for (expected, self.pairs[0..self.count]) |want, got|
            try std.testing.expectEqual(want, got);
    }
};

test "a reaction turnless code registers runs under the turnless context that registered it" {
    var vm = try support.createVm();
    defer vm.deinit();

    var capture = OwnerCapture{};
    try capture.install(&vm, 64);
    defer vm.setConsoleSink(null, null, 4096, 64, 1 << 20) catch {};
    var transitions = TransitionCapture{};
    try vm.setOwnerTransitionHook(TransitionCapture.hook, &transitions);
    defer vm.setOwnerTransitionHook(null, null) catch {};

    // Two module evaluations, each under a turnless context of its own as a worker installs one
    // per evaluation, leave a reaction on a promise that request B settles later.
    try support.registerModules(&vm, &.{
        .{
            .specifier = "/first.js",
            .source =
            \\new Promise((resolve) => { globalThis.settleFirst = resolve; })
            \\    .then(() => { console.log("first-evaluation"); });
            ,
        },
        .{
            .specifier = "/second.js",
            .source =
            \\new Promise((resolve) => { globalThis.settleSecond = resolve; })
            \\    .then(() => { console.log("second-evaluation"); });
            ,
        },
        .{
            .specifier = "/fire.js",
            .source =
            \\export function fire() { globalThis.settleFirst(1); globalThis.settleSecond(1); }
            ,
        },
    });

    var first = support.makeExecCtx(evaluation_first);
    defer vm.releaseExecCtx(&first) catch {};
    var second = support.makeExecCtx(evaluation_second);
    defer vm.releaseExecCtx(&second) catch {};
    var requests = TwoRequests.init();
    defer requests.deinit(&vm);

    try vm.setTurnlessExecCtx(&first);
    try support.evaluateOk(&vm, "/first.js");
    try vm.setTurnlessExecCtx(&second);
    try support.evaluateOk(&vm, "/second.js");
    try vm.setTurnlessExecCtx(null);
    try support.evaluateOk(&vm, "/fire.js");
    // Each evaluation's own reactions drained inside it, under the owner that registered them,
    // so the hook heard no hand-over.
    try transitions.expectPairs(&.{});

    try runTurn(&vm, "/fire.js", "fire", &requests.b);

    try std.testing.expectEqual(@as(?u64, evaluation_first), capture.ownerOf("first-evaluation"));
    try std.testing.expectEqual(@as(?u64, evaluation_second), capture.ownerOf("second-evaluation"));
    try transitions.expectPairs(&.{
        .{ request_b, evaluation_first },
        .{ evaluation_first, request_b },
        .{ request_b, evaluation_second },
        .{ evaluation_second, request_b },
    });
}

test "a reaction whose owner was released runs with no owner, never under the turnless context" {
    var vm = try support.createVm();
    defer vm.deinit();

    var capture = OwnerCapture{};
    try capture.install(&vm, 64);
    defer vm.setConsoleSink(null, null, 4096, 64, 1 << 20) catch {};
    var transitions = TransitionCapture{};
    try vm.setOwnerTransitionHook(TransitionCapture.hook, &transitions);
    defer vm.setOwnerTransitionHook(null, null) catch {};

    try support.registerModules(&vm, &.{
        .{
            .specifier = "/released.js",
            .source =
            \\export function arm() {
            \\    new Promise((resolve) => { globalThis.settleReleased = resolve; })
            \\        .then(() => { console.log("continuation-of-released"); });
            \\}
            ,
        },
        // Settled from module top-level code, so the continuation runs in the evaluation's own
        // drain, outside any turn, where the turnless context owns everything not restored.
        .{
            .specifier = "/settle-turnless.js",
            .source =
            \\globalThis.settleReleased(1);
            \\console.log("evaluation-line");
            ,
        },
    });
    try support.evaluateOk(&vm, "/released.js");

    var requests = TwoRequests.init();
    defer requests.deinit(&vm);
    var evaluation = support.makeExecCtx(evaluation_first);
    defer vm.releaseExecCtx(&evaluation) catch {};

    try runTurn(&vm, "/released.js", "arm", &requests.a);
    try vm.releaseExecCtx(&requests.a);

    try vm.setTurnlessExecCtx(&evaluation);
    try support.evaluateOk(&vm, "/settle-turnless.js");
    try vm.setTurnlessExecCtx(null);

    try std.testing.expectEqual(@as(?u64, evaluation_first), capture.ownerOf("evaluation-line"));
    try std.testing.expectEqual(@as(?u64, 0), capture.ownerOf("continuation-of-released"));
    try transitions.expectPairs(&.{
        .{ evaluation_first, 0 },
        .{ 0, evaluation_first },
    });
}

/// Counts console lines `owner-<n>` by whether the owner that logged them is `base + n`.
const TagCapture = struct {
    base: u64,
    matches: usize = 0,
    mismatches: usize = 0,

    fn sink(
        ctx: ?*anyopaque,
        level: u8,
        flags: u8,
        request_id: u64,
        bytes: ?[*]const u8,
        len: usize,
    ) callconv(.c) void {
        _ = level;
        _ = flags;
        const self: *TagCapture = @ptrCast(@alignCast(ctx orelse return));
        const line: []const u8 = if (bytes) |ptr| ptr[0..len] else "";
        const prefix = "owner-";
        if (!std.mem.startsWith(u8, line, prefix)) {
            self.mismatches += 1;
            return;
        }
        const tag = std.fmt.parseInt(u64, line[prefix.len..], 10) catch {
            self.mismatches += 1;
            return;
        };
        if (request_id == self.base + tag) self.matches += 1 else self.mismatches += 1;
    }
};

test "every owner the table holds at once keeps its own continuations" {
    var vm = try support.createVm();
    defer vm.deinit();

    const base_request_id: u64 = 1000;
    var capture = TagCapture{ .base = base_request_id };
    try vm.setConsoleSink(TagCapture.sink, &capture, 4096, 64, 1 << 20);
    defer vm.setConsoleSink(null, null, 4096, 64, 1 << 20) catch {};

    try support.registerModule(&vm, "/many.js",
        \\const settles = [];
        \\export function arm(tag) {
        \\    new Promise((resolve) => { settles.push(resolve); }).then(() => { console.log(`owner-${tag}`); });
        \\}
        \\export function fire() { for (const settle of settles) settle(1); }
    );
    try support.evaluateOk(&vm, "/many.js");
    var arm = try support.getExportOk(&vm, "/many.js", "arm");
    defer arm.deinit();
    var fire = try support.getExportOk(&vm, "/many.js", "fire");
    defer fire.deinit();

    // As many owners as a worker can hold tokens for at once: its requests, its evaluations and
    // its worker owner. The first also drains everyone's continuations.
    var contexts: [bindings.owner_slot_count]bindings.ExecCtx = undefined;
    for (&contexts, 0..) |*exec_ctx, index|
        exec_ctx.* = support.makeExecCtx(base_request_id + @as(u64, @intCast(index)));
    defer for (&contexts) |*exec_ctx| vm.releaseExecCtx(exec_ctx) catch {};

    for (&contexts, 0..) |*exec_ctx, index| {
        var tag = try vm.numberValue(@floatFromInt(index));
        defer tag.deinit();
        try vm.turnEnter(exec_ctx);
        var result = try support.invokeOk(&vm, exec_ctx, &arm, &.{&tag});
        result.deinit();
        try vm.turnExit();
    }
    try vm.turnEnter(&contexts[0]);
    var fired = try support.invokeOk(&vm, &contexts[0], &fire, &.{});
    fired.deinit();
    try vm.turnExit();

    try std.testing.expectEqual(contexts.len, capture.matches);
    try std.testing.expectEqual(@as(usize, 0), capture.mismatches);
}

//! Window tests for the `bindings-gc-stress` lane: each keeps a cell reachable
//! only from bridge state while script runs and allocates, so a cell the
//! bridge holds in an unrooted container is swept inside the window. The
//! windows are the ports a generator yields to a MessageEvent, the buffers and
//! ports a transfer getter or generator yields to structuredClone and to
//! postMessage, and an object a clone already copied whose last path a getter
//! deletes. Each test then uses every port, checks every transferred buffer
//! and every clone, so a swept cell shows up as garbage, a wrong value or a
//! crash.
//!
//! The forced profile collects at every allocation slow path, which makes
//! these windows deterministic; the concurrent profile runs them as well. Under
//! `bindings-test`, with neither profile, they run once as a sanity check. The
//! churn workloads over the same containers are in `churn.zig`.

const std = @import("std");
const support = @import("bindings_support");
const bindings = support.bindings;

const specifier = "/gc-stress-windows.js";

const source =
    \\// Allocates short-lived objects, so a collection can run at this point.
    \\function churnGarbage(count) {
    \\    const garbage = [];
    \\    for (let i = 0; i < count; i++) garbage.push({ i, text: `garbage ${i}` });
    \\    return garbage.length;
    \\}
    \\
    \\let lastResult = "pending";
    \\export function result() {
    \\    return lastResult;
    \\}
    \\// Records how an asynchronous test ends; its microtasks drain when the turn
    \\// that started it exits.
    \\function finish(promise) {
    \\    lastResult = "pending";
    \\    promise.then(
    \\        (value) => {
    \\            lastResult = value;
    \\        },
    \\        (error) => {
    \\            lastResult = `rejected: ${error}`;
    \\        },
    \\    );
    \\}
    \\
    \\function* freshPorts(count) {
    \\    for (let i = 0; i < count; i++) {
    \\        churnGarbage(64);
    \\        yield new MessageChannel().port1;
    \\    }
    \\}
    \\
    \\export function messageEventPortsFromGenerator() {
    \\    const event = new MessageEvent("message", { ports: freshPorts(64) });
    \\    if (event.ports.length !== 64) return `constructor ports ${event.ports.length}`;
    \\    const init = new MessageEvent("message");
    \\    init.initMessageEvent("message", false, false, null, "", "", null, freshPorts(64));
    \\    if (init.ports.length !== 64) return `initMessageEvent ports ${init.ports.length}`;
    \\    for (const port of [...event.ports, ...init.ports]) {
    \\        if (!(port instanceof MessagePort)) return "a port is not a MessagePort";
    \\        port.postMessage("ping");
    \\    }
    \\    return "ok";
    \\}
    \\
    \\// The payload makes the clone allocate between reading the transfer list and
    \\// committing it, while only the clone's own state references the listed
    \\// buffers and ports.
    \\function payload() {
    \\    return Array.from({ length: 512 }, (_, i) => ({ i, text: `payload ${i}` }));
    \\}
    \\
    \\function checkPayload(clone) {
    \\    if (!Array.isArray(clone.payload) || clone.payload.length !== 512) return "payload length";
    \\    for (let i = 0; i < 512; i++) {
    \\        if (clone.payload[i].i !== i || clone.payload[i].text !== `payload ${i}`) return `payload ${i}`;
    \\    }
    \\    return "ok";
    \\}
    \\
    \\export function structuredCloneTransferFromGetterAndGenerator() {
    \\    const fromGetter = structuredClone(
    \\        { payload: payload() },
    \\        {
    \\            get transfer() {
    \\                churnGarbage(128);
    \\                return [new ArrayBuffer(64), new ArrayBuffer(64), new MessageChannel().port1];
    \\            },
    \\        },
    \\    );
    \\    const getterResult = checkPayload(fromGetter);
    \\    if (getterResult !== "ok") return `getter ${getterResult}`;
    \\    function* transfer() {
    \\        for (let i = 0; i < 8; i++) {
    \\            churnGarbage(64);
    \\            yield new ArrayBuffer(64);
    \\        }
    \\    }
    \\    const fromGenerator = structuredClone({ payload: payload() }, { transfer: transfer() });
    \\    const generatorResult = checkPayload(fromGenerator);
    \\    if (generatorResult !== "ok") return `generator ${generatorResult}`;
    \\    return "ok";
    \\}
    \\
    \\export function postMessageTransferFromGetterAndGenerator() {
    \\    finish((async () => {
    \\        const { port1, port2 } = new MessageChannel();
    \\        const received = [];
    \\        port2.onmessage = (event) => received.push(event);
    \\        const kept = new ArrayBuffer(32);
    \\        port1.postMessage({ payload: payload(), kept }, {
    \\            get transfer() {
    \\                churnGarbage(128);
    \\                return [kept, new ArrayBuffer(64), new MessageChannel().port1];
    \\            },
    \\        });
    \\        if (kept.byteLength !== 0) return "a transferred buffer stayed attached";
    \\        function* transfer() {
    \\            for (let i = 0; i < 4; i++) {
    \\                churnGarbage(64);
    \\                yield new ArrayBuffer(64);
    \\                yield new MessageChannel().port1;
    \\            }
    \\        }
    \\        port1.postMessage({ payload: payload() }, transfer());
    \\        for (let spins = 0; received.length < 2 && spins < 1000; spins++) await null;
    \\        if (received.length !== 2) return `received ${received.length} messages`;
    \\        for (const event of received) {
    \\            const checked = checkPayload(event.data);
    \\            if (checked !== "ok") return checked;
    \\        }
    \\        if (received[0].data.kept.byteLength !== 32) return "the transferred buffer lost its bytes";
    \\        if (received[0].ports.length !== 1 || received[1].ports.length !== 4) return "transferred port counts";
    \\        for (const event of received) {
    \\            for (const port of event.ports) port.postMessage("ping");
    \\        }
    \\        return "ok";
    \\    })());
    \\}
    \\
    \\// The getter deletes the only path to an object the clone already copied,
    \\// then allocates objects of the same shape, so a recorded source that the
    \\// clone does not keep alive can be swept and its address reused.
    \\export function structuredCloneGetterDropsClonedObject() {
    \\    const holder = { first: { tag: "shared" } };
    \\    const root = {
    \\        holder,
    \\        get fresh() {
    \\            delete holder.first;
    \\            churnGarbage(1024);
    \\            return Array.from({ length: 256 }, () => ({ tag: "fresh" }));
    \\        },
    \\    };
    \\    const clone = structuredClone(root);
    \\    if (clone.holder.first.tag !== "shared") return "the copied object changed";
    \\    if (clone.fresh.length !== 256) return "fresh length";
    \\    for (const object of clone.fresh) {
    \\        if (object.tag !== "fresh") return "a fresh object cloned as an earlier one";
    \\    }
    \\    return "ok";
    \\}
;

fn createVm() !bindings.Vm {
    var vm = try support.createVm();
    errdefer vm.deinit();
    try support.registerModule(&vm, specifier, source);
    try support.evaluateOk(&vm, specifier);
    return vm;
}

/// Calls export `name` in a turn of request `request_id` and expects the string
/// it returns. The turn's microtasks drain on exit.
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

/// Runs a synchronous window test as request `request_id`.
fn expectWindowOk(vm: *bindings.Vm, request_id: u64, name: []const u8) !void {
    try expectExportString(vm, request_id, name, "ok");
    try vm.cleanupWebApiRequest(request_id);
}

/// Starts an asynchronous window test in one turn, which drains its microtasks
/// on exit, and expects the result it recorded.
fn expectAsyncWindowOk(vm: *bindings.Vm, request_id: u64, name: []const u8) !void {
    var function = try support.getExportOk(vm, specifier, name);
    defer function.deinit();
    var ctx = support.makeExecCtx(request_id);
    try vm.turnEnter(&ctx);
    {
        errdefer vm.turnExit() catch {};
        var started = try support.invokeOk(vm, &ctx, &function, &.{});
        started.deinit();
    }
    try vm.turnExit();
    try expectExportString(vm, request_id, "result", "ok");
    try vm.cleanupWebApiRequest(request_id);
}

test "a MessageEvent keeps the ports a generator yields while it allocates" {
    var vm = try createVm();
    defer vm.deinit();
    try expectWindowOk(&vm, 100, "messageEventPortsFromGenerator");
}

test "structuredClone keeps the transfer list a getter or generator yields until it commits" {
    var vm = try createVm();
    defer vm.deinit();
    try expectWindowOk(&vm, 200, "structuredCloneTransferFromGetterAndGenerator");
}

test "postMessage keeps the transfer list a getter or generator yields until it commits" {
    var vm = try createVm();
    defer vm.deinit();
    try expectAsyncWindowOk(&vm, 300, "postMessageTransferFromGetterAndGenerator");
}

test "structuredClone keeps an object it copied after a getter deletes the last path to it" {
    var vm = try createVm();
    defer vm.deinit();
    try expectWindowOk(&vm, 400, "structuredCloneGetterDropsClonedObject");
}

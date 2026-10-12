//! Churn workloads for the `bindings-gc-stress` lane: each one keeps values
//! alive only through a container a bridge cell owns (a stream's queue and its
//! pending reads, an AbortSignal's listeners during a dispatch, a port's
//! message queue across a transfer, the performance timeline and an
//! observer's records, FormData's entries), allocates while they sit there,
//! and checks every value it reads back. A value the collector freed comes back
//! scribbled, wrong or as a crash.
//!
//! The lane runs this file under two engine profiles that
//! `runtime/build/tests.zig` sets through JSC's `JSC_<option>` environment
//! variables: the forced profile collects each time a size-class allocator
//! takes its slow path, which is where a cell left unrooted across allocation
//! dies, and the concurrent profile collects back to back on its own thread
//! and re-marks from the roots after each cycle, which is where a missed write
//! barrier or an unlocked container change shows up. Under `bindings-test`,
//! with neither profile, the workloads run once as a sanity check. Each workload runs as turns of one request on the test thread, whose
//! microtask drain at turn exit settles every promise chain it starts.

const std = @import("std");
const support = @import("bindings_support");
const bindings = support.bindings;

const specifier = "/gc-stress-churn.js";

/// Turns per workload. Each turn starts a fresh round of the workload, and a
/// young collection between turns makes the previous turn's cells old, so an
/// edge the next turn adds to them is traced only through its write barrier.
const turns = 4;

const source =
    \\const rounds = 12;
    \\const itemsPerRound = 24;
    \\
    \\let outcome = "not run";
    \\
    \\export function outcomeText() {
    \\    return outcome;
    \\}
    \\
    \\// Records how the workload's promise settles; the turn's microtask drain
    \\// runs it to the end, since every wait below is on a promise or a task the
    \\// bridge queues as a microtask.
    \\function settle(promise) {
    \\    outcome = "pending";
    \\    promise.then(
    \\        () => {
    \\            outcome = "ok";
    \\        },
    \\        (error) => {
    \\            outcome = `failed: ${error && error.stack ? error.stack : error}`;
    \\        },
    \\    );
    \\}
    \\
    \\function check(condition, message) {
    \\    if (!condition) throw new Error(message);
    \\}
    \\
    \\// An exception thrown by a listener or an observer callback is reported, not
    \\// propagated, so callbacks note what they find and the workload checks the
    \\// notes afterwards.
    \\let notes = [];
    \\
    \\function note(condition, message) {
    \\    if (!condition) notes.push(message);
    \\}
    \\
    \\function checkNotes() {
    \\    const found = notes;
    \\    notes = [];
    \\    check(found.length === 0, found.slice(0, 4).join("; "));
    \\}
    \\
    \\function itemProblem(item, round, index) {
    \\    try {
    \\        checkItem(item, round, index);
    \\        return null;
    \\    } catch (error) {
    \\        return error.message;
    \\    }
    \\}
    \\
    \\// A value whose every part is derived from (round, index), so a freed or
    \\// swapped cell cannot pass the check.
    \\function makeItem(round, index) {
    \\    const bytes = new Uint8Array(48 + (index % 5));
    \\    bytes.fill((round * 31 + index) & 0xff);
    \\    return { round, index, text: `item-${round}-${index}`, bytes };
    \\}
    \\
    \\function checkItem(item, round, index) {
    \\    check(item !== null && typeof item === "object", `item ${round}/${index} is ${item}`);
    \\    check(item.round === round && item.index === index, `item ${round}/${index} came back as ${item.round}/${item.index}`);
    \\    check(item.text === `item-${round}-${index}`, `item ${round}/${index} text ${item.text}`);
    \\    check(item.bytes instanceof Uint8Array, `item ${round}/${index} lost its bytes`);
    \\    check(item.bytes.length === 48 + (index % 5), `item ${round}/${index} has ${item.bytes.length} bytes`);
    \\    const expected = (round * 31 + index) & 0xff;
    \\    for (const byte of item.bytes) check(byte === expected, `item ${round}/${index} byte ${byte}`);
    \\}
    \\
    \\// Writes queued faster than a slow sink drains them: the sink yields before
    \\// it takes each chunk, so the stream's queue holds the chunks, and only the
    \\// queue, while the writer keeps allocating.
    \\export function slowSink() {
    \\    settle((async () => {
    \\        for (let round = 0; round < rounds; round++) {
    \\            let expected = 0;
    \\            const stream = new WritableStream(
    \\                {
    \\                    async write(chunk) {
    \\                        await null;
    \\                        await null;
    \\                        checkItem(chunk, round, expected);
    \\                        expected += 1;
    \\                    },
    \\                },
    \\                new CountQueuingStrategy({ highWaterMark: 4 }),
    \\            );
    \\            const writer = stream.getWriter();
    \\            const writes = [];
    \\            for (let index = 0; index < itemsPerRound; index++) writes.push(writer.write(makeItem(round, index)));
    \\            await Promise.all(writes);
    \\            await writer.close();
    \\            check(expected === itemsPerRound, `round ${round}: the sink took ${expected} chunks`);
    \\        }
    \\    })());
    \\}
    \\
    \\// Reads requested before anything is enqueued: the reader's pending reads
    \\// wait in the stream while the chunks are built, then each settles with
    \\// its own chunk.
    \\export function readsBeforeEnqueue() {
    \\    settle((async () => {
    \\        for (let round = 0; round < rounds; round++) {
    \\            let controller;
    \\            const stream = new ReadableStream(
    \\                {
    \\                    start(c) {
    \\                        controller = c;
    \\                    },
    \\                },
    \\                { highWaterMark: 0 },
    \\            );
    \\            const reader = stream.getReader();
    \\            const reads = [];
    \\            for (let index = 0; index < itemsPerRound; index++) reads.push(reader.read());
    \\            for (let index = 0; index < itemsPerRound; index++) {
    \\                await null;
    \\                controller.enqueue(makeItem(round, index));
    \\            }
    \\            controller.close();
    \\            for (let index = 0; index < itemsPerRound; index++) {
    \\                const { value, done } = await reads[index];
    \\                check(!done, `round ${round}: read ${index} ended the stream`);
    \\                checkItem(value, round, index);
    \\            }
    \\            const last = await reader.read();
    \\            check(last.done, `round ${round}: the stream did not end`);
    \\        }
    \\    })());
    \\}
    \\
    \\// Marks with details, cleared every few rounds, while observers connect and
    \\// disconnect: the timeline and each observer's pending records hold the
    \\// only references to the entries and their details. Every mark reaches the
    \\// round's observer once, through its callback or through `takeRecords`,
    \\// whichever comes first.
    \\function observeMark(entry, round) {
    \\    const match = /^churn-(\d+)-(\d+)$/.exec(entry.name);
    \\    note(match !== null && Number(match[1]) === round, `round ${round}: observer saw ${entry.name}`);
    \\    if (match === null) return;
    \\    const problem = itemProblem(entry.detail, Number(match[1]), Number(match[2]));
    \\    note(problem === null, problem);
    \\}
    \\
    \\export function performanceTimeline() {
    \\    settle((async () => {
    \\        performance.clearMarks();
    \\        for (let round = 0; round < rounds; round++) {
    \\            let observed = 0;
    \\            const observer = new PerformanceObserver((list) => {
    \\                for (const entry of list.getEntriesByType("mark")) {
    \\                    observeMark(entry, round);
    \\                    observed += 1;
    \\                }
    \\            });
    \\            observer.observe({ type: "mark" });
    \\            for (let index = 0; index < itemsPerRound; index++) {
    \\                performance.mark(`churn-${round}-${index}`, { detail: makeItem(round, index) });
    \\            }
    \\            for (let index = 0; index < itemsPerRound; index++) {
    \\                const entries = performance.getEntriesByName(`churn-${round}-${index}`, "mark");
    \\                check(entries.length === 1, `round ${round}: mark ${index} has ${entries.length} entries`);
    \\                checkItem(entries[0].detail, round, index);
    \\            }
    \\            if (round % 2 === 0) {
    \\                await null;
    \\                await null;
    \\            }
    \\            for (const entry of observer.takeRecords()) {
    \\                observeMark(entry, round);
    \\                observed += 1;
    \\            }
    \\            observer.disconnect();
    \\            checkNotes();
    \\            check(observed === itemsPerRound, `round ${round}: the observer saw ${observed} marks`);
    \\            if (round % 3 === 2) performance.clearMarks();
    \\        }
    \\        performance.clearMarks();
    \\    })());
    \\}
    \\
    \\// Listeners added and removed while an AbortSignal dispatches: each listener
    \\// removes the one after it and adds a new one, so the listener list changes
    \\// under the dispatch. A listener removed before its turn does not run and one
    \\// added during the dispatch waits for a dispatch that never comes, so the
    \\// listeners at even positions run, each with its own token. Each listener
    \\// reaches the next through its closure, and the signal holds the first, so
    \\// the signal's listener list is the only root of the chain.
    \\function registerListenerChain(signal, round, fired, late) {
    \\    let following = null;
    \\    const chain = [];
    \\    for (let index = itemsPerRound - 1; index >= 0; index--) {
    \\        const token = makeItem(round, index);
    \\        const next = following;
    \\        const listener = () => {
    \\            const problem = itemProblem(token, round, index);
    \\            note(problem === null, problem);
    \\            fired.push(index);
    \\            signal.addEventListener("abort", () => {
    \\                late.count += 1;
    \\            });
    \\            if (next !== null) signal.removeEventListener("abort", next);
    \\        };
    \\        chain.push(listener);
    \\        following = listener;
    \\    }
    \\    for (let position = chain.length - 1; position >= 0; position--) signal.addEventListener("abort", chain[position]);
    \\}
    \\
    \\export function abortListeners() {
    \\    for (let round = 0; round < rounds; round++) {
    \\        const controller = new AbortController();
    \\        const signal = controller.signal;
    \\        const fired = [];
    \\        const late = { count: 0 };
    \\        registerListenerChain(signal, round, fired, late);
    \\        controller.abort(makeItem(round, itemsPerRound));
    \\        checkNotes();
    \\        check(signal.aborted, `round ${round}: the signal did not abort`);
    \\        checkItem(signal.reason, round, itemsPerRound);
    \\        check(late.count === 0, `round ${round}: ${late.count} listeners added during the dispatch ran`);
    \\        check(fired.length === Math.ceil(itemsPerRound / 2), `round ${round}: ${fired.length} listeners ran`);
    \\        for (let position = 0; position < fired.length; position++) {
    \\            check(fired[position] === position * 2, `round ${round}: listener ${fired[position]} ran at ${position}`);
    \\        }
    \\    }
    \\    outcome = "ok";
    \\}
    \\
    \\// Messages queued on a port that has not started, then the port transferred
    \\// through another channel: the queue moves with the port, and the transferred
    \\// port delivers every message once it starts.
    \\export function portTransfer() {
    \\    settle((async () => {
    \\        for (let round = 0; round < rounds; round++) {
    \\            const first = new MessageChannel();
    \\            for (let index = 0; index < itemsPerRound; index++) first.port1.postMessage(makeItem(round, index));
    \\            const carrier = new MessageChannel();
    \\            const arrived = new Promise((resolve) => {
    \\                carrier.port2.onmessage = (event) => resolve(event.ports[0]);
    \\            });
    \\            carrier.port1.postMessage(null, [first.port2]);
    \\            const moved = await arrived;
    \\            const values = [];
    \\            await new Promise((resolve) => {
    \\                moved.onmessage = (event) => {
    \\                    values.push(event.data);
    \\                    if (values.length === itemsPerRound) resolve();
    \\                };
    \\            });
    \\            for (let index = 0; index < itemsPerRound; index++) checkItem(values[index], round, index);
    \\            moved.close();
    \\            first.port1.close();
    \\            carrier.port1.close();
    \\            carrier.port2.close();
    \\        }
    \\    })());
    \\}
    \\
    \\// File entries appended and deleted: FormData holds the only reference to
    \\// each File, whose name and bytes are read back after the deletions.
    \\export function formDataFiles() {
    \\    settle((async () => {
    \\        const names = 4;
    \\        for (let round = 0; round < rounds; round++) {
    \\            const form = new FormData();
    \\            for (let index = 0; index < itemsPerRound; index++) {
    \\                const item = makeItem(round, index);
    \\                form.append(`field-${index % names}`, new File([item.text, item.bytes], `${item.text}.bin`));
    \\            }
    \\            form.delete(`field-${round % names}`);
    \\            let seen = 0;
    \\            for (const [name, value] of form) {
    \\                const match = /^item-(\d+)-(\d+)\.bin$/.exec(value.name);
    \\                check(match !== null, `round ${round}: entry ${name} holds ${value.name}`);
    \\                const index = Number(match[2]);
    \\                check(Number(match[1]) === round, `round ${round}: entry from round ${match[1]}`);
    \\                check(name === `field-${index % names}`, `round ${round}: ${value.name} under ${name}`);
    \\                check(name !== `field-${round % names}`, `round ${round}: deleted field ${name} remains`);
    \\                const expected = makeItem(round, index);
    \\                const bytes = new Uint8Array(await value.arrayBuffer());
    \\                const text = new TextDecoder().decode(bytes.subarray(0, expected.text.length));
    \\                check(text === expected.text, `round ${round}: ${value.name} reads ${text}`);
    \\                const tail = bytes.subarray(expected.text.length);
    \\                check(tail.length === expected.bytes.length, `round ${round}: ${value.name} has ${tail.length} trailing bytes`);
    \\                for (let at = 0; at < tail.length; at++) check(tail[at] === expected.bytes[at], `round ${round}: ${value.name} byte ${at}`);
    \\                seen += 1;
    \\            }
    \\            check(seen === itemsPerRound - itemsPerRound / names, `round ${round}: ${seen} entries remain`);
    \\        }
    \\    })());
    \\}
;

fn createVm() !bindings.Vm {
    var vm = try support.createVm();
    errdefer vm.deinit();
    try support.registerModule(&vm, specifier, source);
    try support.evaluateOk(&vm, specifier);
    return vm;
}

/// Calls export `name` in a turn of request `request_id`. The turn's microtask
/// drain at exit runs the promise chain the call starts.
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

fn expectOutcomeOk(vm: *bindings.Vm, request_id: u64) !void {
    var function = try support.getExportOk(vm, specifier, "outcomeText");
    defer function.deinit();
    var ctx = support.makeExecCtx(request_id);
    try vm.turnEnter(&ctx);
    defer vm.turnExit() catch {};
    var value = try support.invokeOk(vm, &ctx, &function, &.{});
    defer value.deinit();
    try support.expectValueString(vm, &value, "ok");
}

/// Runs `workload` for `turns` turns, each as a request of its own that ends
/// before the next, with a young collection between them.
fn churn(workload: []const u8, first_request_id: u64) !void {
    var vm = try createVm();
    defer vm.deinit();

    for (0..turns) |turn| {
        const request_id = first_request_id + turn;
        try runExport(&vm, request_id, workload);
        try expectOutcomeOk(&vm, request_id);
        try vm.cleanupWebApiRequest(request_id);
        try vm.collectEdenGC();
    }
    try vm.collectFullGCAndTrim();
}

test "writes queued ahead of a slow sink reach it intact" {
    try churn("slowSink", 100);
}

test "reads requested before any chunk is enqueued each settle with their own chunk" {
    try churn("readsBeforeEnqueue", 200);
}

test "performance marks and their details survive observers that connect and disconnect" {
    try churn("performanceTimeline", 300);
}

test "listeners added and removed during an abort dispatch keep their tokens and the dispatch order" {
    try churn("abortListeners", 400);
}

test "messages queued on a port arrive intact after the port is transferred" {
    try churn("portTransfer", 500);
}

test "File entries in a FormData keep their names and bytes across deletions" {
    try churn("formDataFiles", 600);
}

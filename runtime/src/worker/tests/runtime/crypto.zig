//! Covers WebCrypto running inline on the worker's VM thread
//! (`bindings/host_functions/webapi/crypto/`) under its time guard
//! (`crypto/budget.h`, asking `host/crypto.zig`): every operation family
//! completes inside its request's turn; the CPU an operation spends is its
//! request's; a call at the caps finishes well inside its deadline; an
//! operation refuses to start when its estimate does not fit the time left,
//! which counts every live owner's deadline and not only the caller's, and
//! whose estimate counts every input the operation hashes; and a long
//! operation looks at the clock while it works and stops once the time left
//! runs out. The runtime reads a fake wall clock, so the time left is set
//! exactly; its CPU clock is the VM thread's real one, or a fake one that
//! moves at every read. WebCrypto's Web behavior is the `webapi` lane's
//! (`runtime/tests/webapi/crypto/`). Runs in `worker-test`.

const std = @import("std");
const support = @import("bindings_support");
const ipc = @import("collo_ipc");
const worker = @import("collo_worker");
const rt = @import("collo_test_harness");
const process = @import("collo_os").process;

const Fixture = struct {
    vm: support.bindings.Vm,
    control_pair: [2]std.posix.fd_t,
    completion: rt.CompletionFixture,
    now_mono_ns: u64,
    runtime: worker.Runtime,

    const Options = struct {
        request_cpu_budget_ns: u64 = 0,
        cpu_clock: worker.Clock = worker.Clock.threadCpu(),
    };

    fn init(self: *Fixture, options: Options) !void {
        self.vm = try support.createVm();
        errdefer self.vm.deinit();
        self.control_pair = try rt.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
        errdefer {
            std.posix.close(self.control_pair[0]);
            std.posix.close(self.control_pair[1]);
        }
        self.completion = try rt.CompletionFixture.init();
        errdefer self.completion.deinit();
        self.now_mono_ns = 0;
        self.runtime = try worker.Runtime.init(
            std.testing.allocator,
            &self.vm,
            self.control_pair[0],
            &self.completion.view,
            try rt.createCompletionEventfd(),
            worker.RuntimeOptions{
                .clock = .{ .ctx = &self.now_mono_ns, .now_fn = rt.fakeNow },
                .cpu_clock = options.cpu_clock,
                .request_cpu_budget_ns = options.request_cpu_budget_ns,
            },
        );
        errdefer self.runtime.deinit();
        try self.runtime.attachHostRuntime();
    }

    fn deinit(self: *Fixture) void {
        self.runtime.deinit();
        self.completion.deinit();
        std.posix.close(self.control_pair[0]);
        std.posix.close(self.control_pair[1]);
        self.vm.deinit();
    }

    /// Registers `source` as the route of request `request_id` and returns
    /// its index.
    fn register(self: *Fixture, source: []const u8, request_id: u64) !u16 {
        const specifier = try std.fmt.allocPrint(std.testing.allocator, "/var/task/crypto-{d}.js", .{request_id});
        defer std.testing.allocator.free(specifier);
        return rt.registerRoute(&self.runtime, specifier, source);
    }

    /// Dispatches one request to the route at `route_index`, its deadline
    /// `time_left_ns` of fake time ahead, and runs its first turn, after
    /// which the request may wait on something.
    fn begin(self: *Fixture, route_index: u16, request_id: u64, time_left_ns: u64) !void {
        var dispatch = try rt.initDispatchWork(std.testing.allocator, .{
            .request_id = request_id,
            .route_index = route_index,
            .deadline_monotonic_ns = self.now_mono_ns + time_left_ns,
            .request = .{ .path = "/crypto" },
        });
        defer dispatch.deinit();
        try rt.enqueueIngressRoute(&self.runtime, &dispatch, 1, .{ .path = "/crypto" });
        try rt.executeQueuedBegin(&self.runtime);
    }

    /// Runs one request to the route at `route_index` to its end, its
    /// deadline `time_left_ns` of fake time ahead, and returns its response,
    /// which the caller releases.
    fn runRoute(self: *Fixture, route_index: u16, request_id: u64, time_left_ns: u64) !rt.IngressResponse {
        try self.begin(route_index, request_id, time_left_ns);
        try rt.executeUntilRequestDone(&self.runtime, request_id);
        return rt.readIngressResponse(&self.runtime, self.control_pair[1], request_id);
    }

    /// Registers `source` as a route and runs one request to it, as `runRoute`.
    fn run(self: *Fixture, source: []const u8, request_id: u64, time_left_ns: u64) !rt.IngressResponse {
        return self.runRoute(try self.register(source, request_id), request_id, time_left_ns);
    }
};

/// A fake clock that moves `tick_ns` forward at every read, so work that
/// reads it often spends time by the count of its reads.
const TickingClock = struct {
    now_ns: u64 = 0,
    tick_ns: u64,

    fn now(ctx: ?*anyopaque) u64 {
        const self: *TickingClock = @ptrCast(@alignCast(ctx.?));
        self.now_ns += self.tick_ns;
        return self.now_ns;
    }

    fn clock(self: *TickingClock) worker.Clock {
        return .{ .ctx = self, .now_fn = now };
    }
};

fn expectBodyContains(response: *const rt.IngressResponse, needle: []const u8) !void {
    if (std.mem.indexOf(u8, response.body, needle) == null) {
        std.debug.print("expected the response body to contain: {s}\nactual body:\n{s}\n", .{ needle, response.body });
        return error.TestUnexpectedResult;
    }
}

/// A route that answers with the outcome of a PBKDF2 derivation at 1,000,000
/// SHA-256 iterations, expected well past 100 ms, and of one at 1,000
/// iterations, expected below the time an operation runs without asking.
const pbkdf2_large_and_small_source =
    \\export default async function handle() {
    \\    const s = crypto.subtle;
    \\    const outcome = (promise) => promise.then((value) => value.byteLength, (error) => error.name);
    \\    const key = await s.importKey("raw", new Uint8Array(16), "PBKDF2", false, ["deriveBits"]);
    \\    const params = { name: "PBKDF2", hash: "SHA-256", salt: new Uint8Array(16) };
    \\    return Response.json({
    \\        large: await outcome(s.deriveBits({ ...params, iterations: 1000000 }, key, 256)),
    \\        small: await outcome(s.deriveBits({ ...params, iterations: 1000 }, key, 256)),
    \\    });
    \\}
;

test "every WebCrypto operation family completes inline in its request's turn" {
    var fixture: Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();

    var response = try fixture.run(
        \\export default async function handle() {
        \\    const s = crypto.subtle;
        \\    const data = new Uint8Array(1 << 16);
        \\    for (const hash of ["SHA-1", "SHA-256", "SHA-384", "SHA-512", "SHA3-256"]) await s.digest(hash, data);
        \\    const rsa = { modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" };
        \\    const pss = await s.generateKey({ name: "RSA-PSS", ...rsa }, true, ["sign", "verify"]);
        \\    const pssSignature = await s.sign({ name: "RSA-PSS", saltLength: 32 }, pss.privateKey, data);
        \\    if (!await s.verify({ name: "RSA-PSS", saltLength: 32 }, pss.publicKey, pssSignature, data))
        \\        throw new Error("RSA-PSS signature does not verify");
        \\    const oaep = await s.generateKey({ name: "RSA-OAEP", ...rsa }, true, ["encrypt", "decrypt"]);
        \\    const sealed = await s.encrypt({ name: "RSA-OAEP" }, oaep.publicKey, data.subarray(0, 64));
        \\    await s.decrypt({ name: "RSA-OAEP" }, oaep.privateKey, sealed);
        \\    const ecdsa = await s.generateKey({ name: "ECDSA", namedCurve: "P-521" }, true, ["sign", "verify"]);
        \\    const ecdsaSignature = await s.sign({ name: "ECDSA", hash: "SHA-512" }, ecdsa.privateKey, data);
        \\    await s.verify({ name: "ECDSA", hash: "SHA-512" }, ecdsa.publicKey, ecdsaSignature, data);
        \\    const ecdh = await s.generateKey({ name: "ECDH", namedCurve: "P-521" }, true, ["deriveBits"]);
        \\    await s.deriveBits({ name: "ECDH", public: ecdh.publicKey }, ecdh.privateKey, 528);
        \\    const ed = await s.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]);
        \\    await s.sign("Ed25519", ed.privateKey, data);
        \\    const x = await s.generateKey({ name: "X25519" }, true, ["deriveBits"]);
        \\    await s.deriveBits({ name: "X25519", public: x.publicKey }, x.privateKey);
        \\    const gcm = await s.generateKey({ name: "AES-GCM", length: 256 }, true, ["encrypt", "wrapKey", "unwrapKey"]);
        \\    const iv = new Uint8Array(16);
        \\    await s.encrypt({ name: "AES-GCM", iv: iv.subarray(0, 12) }, gcm, data);
        \\    const cbc = await s.generateKey({ name: "AES-CBC", length: 256 }, true, ["encrypt"]);
        \\    await s.encrypt({ name: "AES-CBC", iv }, cbc, data);
        \\    const ctr = await s.generateKey({ name: "AES-CTR", length: 256 }, true, ["encrypt"]);
        \\    await s.encrypt({ name: "AES-CTR", counter: iv, length: 64 }, ctr, data);
        \\    const kw = await s.generateKey({ name: "AES-KW", length: 256 }, true, ["wrapKey"]);
        \\    await s.wrapKey("raw", cbc, kw, "AES-KW");
        \\    const hmac = await s.generateKey({ name: "HMAC", hash: "SHA-512" }, true, ["sign"]);
        \\    await s.sign("HMAC", hmac, data);
        \\    const pbkdf2 = await s.importKey("raw", new Uint8Array(32), "PBKDF2", false, ["deriveBits"]);
        \\    await s.deriveBits({ name: "PBKDF2", hash: "SHA-512", salt: new Uint8Array(16), iterations: 1000 }, pbkdf2, 512);
        \\    const hkdf = await s.importKey("raw", new Uint8Array(32), "HKDF", false, ["deriveBits"]);
        \\    await s.deriveBits({ name: "HKDF", hash: "SHA-512", salt: new Uint8Array(16), info: new Uint8Array(0) }, hkdf, 512);
        \\    const wrapped = await s.wrapKey("jwk", pss.privateKey, gcm, { name: "AES-GCM", iv: iv.subarray(0, 12) });
        \\    await s.unwrapKey("jwk", wrapped, gcm, { name: "AES-GCM", iv: iv.subarray(0, 12) },
        \\        { name: "RSA-PSS", hash: "SHA-256" }, true, ["sign"]);
        \\    return new Response("every operation");
        \\}
    , 1001, std.time.ns_per_hour);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("every operation", response.body);
}

test "an operation whose estimate exceeds its request's time left rejects with OperationError before it runs" {
    var fixture: Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();

    // 100 ms of fake time is left. PBKDF2 at 1,000,000 SHA-256 iterations and RSA 2048 key generation are each
    // expected past it, so both refuse; PBKDF2 at 1,000 iterations is under the time that asks at all.
    var response = try fixture.run(
        \\export default async function handle() {
        \\    const s = crypto.subtle;
        \\    const outcome = (promise) => promise.then((value) => value.byteLength ?? "ok", (error) => error.name);
        \\    const key = await s.importKey("raw", new Uint8Array(16), "PBKDF2", false, ["deriveBits"]);
        \\    const params = { name: "PBKDF2", hash: "SHA-256", salt: new Uint8Array(16) };
        \\    return Response.json({
        \\        pbkdf2: await outcome(s.deriveBits({ ...params, iterations: 1000000 }, key, 256)),
        \\        rsa: await outcome(s.generateKey({ name: "RSA-PSS", modulusLength: 2048,
        \\            publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" }, true, ["sign"])),
        \\        small: await outcome(s.deriveBits({ ...params, iterations: 1000 }, key, 256)),
        \\    });
        \\}
    , 1002, 100 * std.time.ns_per_ms);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try expectBodyContains(&response, "\"pbkdf2\":\"OperationError\"");
    try expectBodyContains(&response, "\"rsa\":\"OperationError\"");
    try expectBodyContains(&response, "\"small\":32");
}

test "an operation whose estimate exceeds its request's CPU left rejects with OperationError before it runs" {
    var fixture: Fixture = undefined;
    try fixture.init(.{ .request_cpu_budget_ns = 50 * std.time.ns_per_ms });
    defer fixture.deinit();

    // The wall deadline lies an hour out; the 50 ms CPU budget is what refuses PBKDF2 at 1,000,000 iterations, whose
    // estimate is several times that. The handler's own turns spend a few milliseconds, so it answers 200.
    var response = try fixture.run(
        \\export default async function handle() {
        \\    const s = crypto.subtle;
        \\    const key = await s.importKey("raw", new Uint8Array(16), "PBKDF2", false, ["deriveBits"]);
        \\    const params = { name: "PBKDF2", hash: "SHA-256", salt: new Uint8Array(16), iterations: 1000000 };
        \\    try {
        \\        await s.deriveBits(params, key, 256);
        \\        return new Response("derived");
        \\    } catch (error) {
        \\        return new Response(error.name);
        \\    }
        \\}
    , 1003, std.time.ns_per_hour);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("OperationError", response.body);
    try std.testing.expectEqual(ipc.RequestDoneStatus.ok, response.doneStatus());
}

test "an operation refuses to start when another request of the worker is near its deadline" {
    var fixture: Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();

    // Request 1006 waits on a promise that never settles, with 50 ms of fake time left; its deadline is armed. While
    // request 1007 runs native work the loop cannot answer 1006's deadline, so 1007's derivation expected past 50 ms
    // refuses although 1007 has an hour, and the small one runs. The fake clock does not move, so 1006 stays live and
    // silent until the fixture ends it. A runtime boots once, so both routes boot together before either request
    // starts.
    const waiting_specifier = "/var/task/crypto-waiting.js";
    const waiting_source =
        \\export default function handle() {
        \\    return new Promise(() => {});
        \\}
    ;
    const crypto_specifier = "/var/task/crypto-pbkdf2.js";
    try rt.bootRoutes(&fixture.runtime, &.{
        .{ .specifier = waiting_specifier, .source = waiting_source },
        .{ .specifier = crypto_specifier, .source = pbkdf2_large_and_small_source },
    });
    const waiting_route = rt.routeIndex(&fixture.runtime, waiting_specifier) orelse return error.TestRouteMissing;
    const crypto_route = rt.routeIndex(&fixture.runtime, crypto_specifier) orelse return error.TestRouteMissing;
    try fixture.begin(waiting_route, 1006, 50 * std.time.ns_per_ms);
    const waiting = fixture.runtime.requests.active.get(1006) orelse return error.TestUnexpectedResult;
    try std.testing.expect(waiting.deadline_armed);

    var response = try fixture.runRoute(crypto_route, 1007, std.time.ns_per_hour);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try expectBodyContains(&response, "\"large\":\"OperationError\"");
    try expectBodyContains(&response, "\"small\":32");
}

test "a decoded request whose dispatch has not run yet counts with its deadline" {
    var fixture: Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();

    // A decoded request whose `request` item waits in the queue has no armed deadline, but the server's deadline for
    // it already runs: the harness's request is due 10 us of fake time after the clock's start. Marking its item
    // queued keeps the loop's ingress rescan from queueing one.
    const pending = try rt.ActiveRequest.init(std.testing.allocator, &fixture.runtime, 1008, 0);
    defer pending.deinit();
    pending.ctx.dispatch_queued = true;
    try std.testing.expect(!pending.ctx.deadline_armed);
    try std.testing.expect(!pending.ctx.dispatch_started);

    var response = try fixture.run(pbkdf2_large_and_small_source, 1009, std.time.ns_per_hour);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try expectBodyContains(&response, "\"large\":\"OperationError\"");
    try expectBodyContains(&response, "\"small\":32");
}

test "an operation's estimate counts every input it hashes" {
    var fixture: Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();

    // 10 ms of fake time is left, below the reserve every operation that asks must keep, so an operation refuses
    // exactly when its estimate is above the time that asks at all. Each call below is cheap but for one input: AES-GCM
    // additional data, a PBKDF2 password longer than the hash's block, a PBKDF2 salt, hashed once per output block,
    // and an HKDF info, hashed once per each of 255 output blocks. The control encrypts 16 bytes.
    var response = try fixture.run(
        \\export default async function handle() {
        \\    const s = crypto.subtle;
        \\    const outcome = (promise) => promise.then((value) => value.byteLength, (error) => error.name);
        \\    const gcm = await s.importKey("raw", new Uint8Array(16), "AES-GCM", false, ["encrypt"]);
        \\    const gcmParams = { name: "AES-GCM", iv: new Uint8Array(12) };
        \\    const longPassword = await s.importKey("raw", new Uint8Array(4 << 20), "PBKDF2", false, ["deriveBits"]);
        \\    const password = await s.importKey("raw", new Uint8Array(16), "PBKDF2", false, ["deriveBits"]);
        \\    const pbkdf2 = { name: "PBKDF2", hash: "SHA-256", iterations: 1 };
        \\    const hkdf = await s.importKey("raw", new Uint8Array(32), "HKDF", false, ["deriveBits"]);
        \\    return Response.json({
        \\        control: await outcome(s.encrypt(gcmParams, gcm, new Uint8Array(16))),
        \\        additionalData: await outcome(s.encrypt({ ...gcmParams, additionalData: new Uint8Array(4 << 20) },
        \\            gcm, new Uint8Array(16))),
        \\        password: await outcome(s.deriveBits({ ...pbkdf2, salt: new Uint8Array(16) }, longPassword, 256)),
        \\        salt: await outcome(s.deriveBits({ ...pbkdf2, salt: new Uint8Array(1 << 20) }, password, 256)),
        \\        info: await outcome(s.deriveBits({ name: "HKDF", hash: "SHA-256", salt: new Uint8Array(16),
        \\            info: new Uint8Array(64 << 10) }, hkdf, 255 * 256)),
        \\    });
        \\}
    , 1010, 10 * std.time.ns_per_ms);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try expectBodyContains(&response, "\"control\":32");
    try expectBodyContains(&response, "\"additionalData\":\"OperationError\"");
    try expectBodyContains(&response, "\"password\":\"OperationError\"");
    try expectBodyContains(&response, "\"salt\":\"OperationError\"");
    try expectBodyContains(&response, "\"info\":\"OperationError\"");
}

test "a long operation looks at the clock while it works and stops once the time left runs out" {
    // The CPU clock moves 2 ms at every read, and the guard reads it once per millisecond of estimated work, so the
    // operation spends its CPU budget twice as fast as its estimate says. 8-bit AES-CFB over 8 MiB is estimated at 256 ms
    // and starts with nearly all of the 400 ms budget left, then stops part way, once less than the guard's reserve is
    // left. The few reads after it leave the request inside its budget, so it answers.
    var cpu_clock = TickingClock{ .tick_ns = 2 * std.time.ns_per_ms };
    var fixture: Fixture = undefined;
    try fixture.init(.{ .request_cpu_budget_ns = 400 * std.time.ns_per_ms, .cpu_clock = cpu_clock.clock() });
    defer fixture.deinit();

    var response = try fixture.run(
        \\export default async function handle() {
        \\    const s = crypto.subtle;
        \\    const key = await s.importKey("raw", new Uint8Array(16), "AES-CFB-8", false, ["encrypt"]);
        \\    const params = { name: "AES-CFB-8", iv: new Uint8Array(16) };
        \\    return s.encrypt(params, key, new Uint8Array(8 << 20)).then(
        \\        (encrypted) => new Response(String(encrypted.byteLength)),
        \\        (error) => new Response(`${error.name}: ${error.message}`));
        \\}
    , 1011, std.time.ns_per_hour);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try expectBodyContains(&response, "OperationError: Too little time is left");
    try std.testing.expectEqual(ipc.RequestDoneStatus.ok, response.doneStatus());
}

test "the CPU an inline WebCrypto operation spends is its request's" {
    var fixture: Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();

    // PBKDF2 at 100,000 SHA-256 iterations takes the VM thread well over 10 ms of CPU, all of it inside the request's
    // owner window.
    var response = try fixture.run(
        \\export default async function handle() {
        \\    const s = crypto.subtle;
        \\    const key = await s.importKey("raw", new Uint8Array(16), "PBKDF2", false, ["deriveBits"]);
        \\    const bits = await s.deriveBits(
        \\        { name: "PBKDF2", hash: "SHA-256", salt: new Uint8Array(16), iterations: 100000 }, key, 256);
        \\    return new Response(String(bits.byteLength));
        \\}
    , 1004, std.time.ns_per_hour);
    defer response.deinit();
    try std.testing.expectEqualStrings("32", response.body);
    try std.testing.expect(response.done.cpu_ns >= 10 * std.time.ns_per_ms);
}

test "PBKDF2 at its work cap finishes well inside its request's deadline, and one iteration more is refused" {
    var fixture: Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();

    // The cap is the work of 1,000,000 SHA-256 iterations for one output block, a fraction of a second on the
    // reference machine; 2 s is far below the default 30 s deadline and still far above the cap's time.
    const started_ns = process.monotonicNowNsOrZero();
    var response = try fixture.run(
        \\export default async function handle() {
        \\    const s = crypto.subtle;
        \\    const key = await s.importKey("raw", new Uint8Array(16), "PBKDF2", false, ["deriveBits"]);
        \\    const params = { name: "PBKDF2", hash: "SHA-256", salt: new Uint8Array(16) };
        \\    const atCap = await s.deriveBits({ ...params, iterations: 1000000 }, key, 256);
        \\    const overCap = await s.deriveBits({ ...params, iterations: 1000001 }, key, 256)
        \\        .then(() => "derived", (error) => error.name);
        \\    return new Response(`${atCap.byteLength} ${overCap}`);
        \\}
    , 1005, 30 * std.time.ns_per_s);
    defer response.deinit();
    try std.testing.expectEqualStrings("32 OperationError", response.body);
    try std.testing.expect(process.monotonicNowNsOrZero() - started_ns < 2 * std.time.ns_per_s);
}

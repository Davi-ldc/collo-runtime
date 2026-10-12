//! Covers the crypto pool's thread stack (`js/crypto/jobs.zig`,
//! `common/limits/worker.zig:crypto_thread_stack_bytes`): every kind of
//! WebCrypto job runs to completion on pool threads with half of that stack,
//! which pins the 2× margin the constant's derivation promises. RSA runs at
//! 4096 bits, since generating an 8192-bit key takes the lane tens of
//! seconds; the one-off measurement that sets the constant runs 8192. The
//! jobs run in a fresh process of the test binary, started for this test
//! alone, so a job that overflows the stack kills that process and this test
//! reports how it ended, while the lane goes on. A fork of the test process
//! would not do: its JSC threads may hold locks at the fork, which no thread
//! of the child would ever release. Runs in `worker-test`.

const std = @import("std");
const builtin = @import("builtin");
const support = @import("bindings_support");
const worker = @import("collo_worker");
const rt = @import("collo_test_harness");
const process = @import("collo_os").process;
const worker_limits = @import("collo_limits").worker;

const crypto_jobs = worker.testing.crypto_jobs;

/// Set in the environment of the process that runs the jobs.
const child_env = "COLLO_TEST_CRYPTO_STACK_CHILD";
/// The test's own name, which the child's `--filter` selects alone.
const test_name = "every kind of WebCrypto job completes on pool threads with half of crypto_thread_stack_bytes";
/// Bounds what the child's test runner prints, which is read whole and shown
/// only when the child fails.
const child_output_bytes_max: usize = 1 << 20;

test "every kind of WebCrypto job completes on pool threads with half of crypto_thread_stack_bytes" {
    if (std.posix.getenv(child_env) != null)
        return runEveryJobOnHalfStack();
    try runInFreshProcess();
}

/// Runs this test again in a new process of the test binary with `child_env`
/// set, and fails unless that process exits 0.
fn runInFreshProcess() !void {
    const allocator = std.testing.allocator;
    const filter_arg = try std.fmt.allocPrint(allocator, "--filter={s}", .{try ownQualifiedName()});
    defer allocator.free(filter_arg);

    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();
    // A strict run needs the arguments only the build passes, which the
    // child does not get, so the child runs this one test without them.
    env.remove(@import("root").skip_allowlist.strict_env);
    try env.put(child_env, "1");

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "/proc/self/exe", filter_arg },
        .env_map = &env,
        .max_output_bytes = child_output_bytes_max,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .Exited => |code| if (code == 0) return,
        .Signal, .Stopped, .Unknown => {},
    }
    std.debug.print("the crypto stack child ended with {any}; its output:\n{s}\n", .{ result.term, result.stderr });
    return error.CryptoStackChildFailed;
}

/// The test runner's name for this test, as `--filter` takes it.
fn ownQualifiedName() ![]const u8 {
    var found: ?[]const u8 = null;
    for (builtin.test_functions) |test_fn| {
        if (!std.mem.endsWith(u8, test_fn.name, "crypto_pool.test." ++ test_name))
            continue;
        if (found != null)
            return error.CryptoStackTestNameAmbiguous;
        found = test_fn.name;
    }
    return found orelse error.CryptoStackTestNameMissing;
}

fn runEveryJobOnHalfStack() !void {
    var vm = try support.createVm();
    defer vm.deinit();
    const control_pair = try rt.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var now_mono_ns: u64 = 0;
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = rt.fakeNow,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    // The runtime's own pool is replaced by one with half the stack.
    const limits = runtime.core.limits;
    runtime.crypto.jobs.deinit();
    runtime.crypto.jobs = try crypto_jobs.Pool.init(std.testing.allocator, runtime.scheduler.wakeup_fd.?, .{
        .thread_count = limits.crypto_thread_count,
        .thread_stack_bytes = worker_limits.crypto_thread_stack_bytes / 2,
        .max_in_flight_per_request = limits.crypto_max_in_flight_per_request,
        .max_in_flight_per_worker = limits.crypto_max_in_flight_per_worker,
    });

    const route_index = try rt.registerRoute(&runtime, "/__collo_route/demo/crypto-pool-stack.js",
        \\export default async function handle() {
        \\    const s = crypto.subtle;
        \\    const data = new Uint8Array(1 << 16);
        \\    for (const hash of ["SHA-1", "SHA-256", "SHA-384", "SHA-512"]) await s.digest(hash, data);
        \\    const rsa = { modulusLength: 4096, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-512" };
        \\    const pss = await s.generateKey({ name: "RSA-PSS", ...rsa }, true, ["sign", "verify"]);
        \\    const pssSignature = await s.sign({ name: "RSA-PSS", saltLength: 64 }, pss.privateKey, data);
        \\    await s.verify({ name: "RSA-PSS", saltLength: 64 }, pss.publicKey, pssSignature, data);
        \\    const pkcs1 = await s.generateKey({ name: "RSASSA-PKCS1-v1_5", ...rsa }, true, ["sign", "verify"]);
        \\    await s.sign("RSASSA-PKCS1-v1_5", pkcs1.privateKey, data);
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
        \\    await s.deriveBits({ name: "X25519", public: x.publicKey }, x.privateKey, 256);
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
        \\        { name: "RSA-PSS", hash: "SHA-512" }, true, ["sign"]);
        \\    return new Response("every job");
        \\}
    );
    var dispatch = try rt.initDispatchWork(std.testing.allocator, .{
        .request_id = 1001,
        .route_index = route_index,
        .deadline_monotonic_ns = std.time.ns_per_hour,
    });
    defer dispatch.deinit();
    try rt.enqueueIngressRoute(&runtime, &dispatch, 1, .{});
    try rt.executeNextReady(&runtime);

    // Key generation takes the pool real time the harness's pass count does
    // not bound.
    const stop_ns = process.monotonicNowNsOrZero() + 120 * std.time.ns_per_s;
    while (runtime.requests.active.contains(1001)) {
        if (process.monotonicNowNsOrZero() >= stop_ns)
            return error.RequestDidNotComplete;
        try runtime.collectCompletedCryptoJobs();
        runtime.collectReadyRequestCompletions();
        if (runtime.scheduler.ready_queue.pop()) |item| {
            try worker.testing.executeWorkItem(&runtime, item);
            continue;
        }
        std.Thread.sleep(std.time.ns_per_ms);
    }
    const body = try rt.readIngressResponseBody(&runtime, control_pair[1], 1001);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("every job", body);
}

comptime {
    // Half of the stack must itself be a stack glibc accepts on every target.
    std.debug.assert(worker_limits.crypto_thread_stack_bytes / 2 >= 16 * 1024);
}

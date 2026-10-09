//! The JavaScript fixtures the benchmark's routes run; one workload, read from
//! `Workload.environment_name`, serves every route of a run. Each handler's
//! first statement calls the handler-entry marker through optional chaining,
//! so the call does nothing where the marker is absent: only a worker booted
//! with the benchmark flag installs it, and only for its first handler call
//! (`bench_handler` in `worker/runtime/types.zig`).
//!
//! `crypto` embeds `workload.js`: pure-JavaScript SHA-256 over 4 MiB and four
//! 2048-bit BigInt modular exponentiations. The workerd memory comparison
//! (`report/bench-product-memory/runner.mjs`) runs a byte-identical copy,
//! `report/bench-engine-memory/workload.js`, and refuses to start unless that
//! copy's SHA-256 matches `workload_sha256` in
//! `report/bench-engine-memory/expected.json`. An edit to `workload.js` must
//! reach the copy and that hash, or the two runtimes no longer execute the
//! same JavaScript.

const std = @import("std");

pub const Workload = enum {
    hello,
    crypto,

    pub const environment_name = "COLLO_BENCH_WORKLOAD";

    /// Reads `environment_name`. An unset variable selects `hello`, the
    /// workload of the recorded baselines, and an unknown name fails with
    /// `error.InvalidBenchmarkWorkload`.
    pub fn fromEnvironment() !Workload {
        const text = std.posix.getenv(environment_name) orelse return .hello;
        return std.meta.stringToEnum(Workload, text) orelse error.InvalidBenchmarkWorkload;
    }

    pub fn entrySource(workload: Workload) []const u8 {
        return switch (workload) {
            .hello => hello_source,
            .crypto => crypto_source,
        };
    }

    /// The exact response body; the HTTP client rejects any other byte.
    pub fn expectedBody(workload: Workload) [:0]const u8 {
        return switch (workload) {
            .hello => hello_body,
            .crypto => crypto_body,
        };
    }

    /// Requests per loaded instance when COLLO_BENCH_LOAD_REQUESTS is unset.
    pub fn loadRequestsDefault(workload: Workload) usize {
        return switch (workload) {
            .hello => 10,
            .crypto => 1,
        };
    }
};

const hello_body = "sandbox benchmark\n";

const hello_source =
    \\export default function handle() {
    \\  globalThis.__colloBenchHandlerEntered?.();
    \\  return new Response("sandbox benchmark\n", {
    \\    headers: { "content-type": "text/plain" }
    \\  });
    \\}
;

const crypto_source = @embedFile("workload.js") ++ "\n" ++
    \\export default function handle() {
    \\  globalThis.__colloBenchHandlerEntered?.();
    \\  return new Response(runCrypto(), {
    \\    headers: { "content-type": "text/plain" }
    \\  });
    \\}
;

/// What `runCrypto()` returns: the SHA-256 digest, a colon and the final
/// BigInt in hex. The value was checked against Node's OpenSSL SHA-256 and an
/// independent left-to-right modular exponentiation (`validation` in
/// `report/bench-engine-memory/expected.json`).
const crypto_body = "2fbca684e0459c746e5cdc438c03ff1015528500cc7a3478a936d6bb427aaa20:" ++
    "df330414d759b22931f5d2b1f414cfda072f24df1544fe27601b362e66d953b0" ++
    "62cacab2a6610cfd65adcfb3a50795ebc5bf973f8e5e572924dab211c7ab8f21" ++
    "54610d39bdc95e9ed3bdadfeabecd1c01a03e8e13917a28db2aa268bee3969c8" ++
    "5c545cc181f7245e20a08bb19d8feb2a5df4d7eaf53aa42bfa5e10ede7cbaf3e" ++
    "e1ee56f25cb5316b80e78216e91ebab7c0d84055250ee1c17d3adb2d5b725af4" ++
    "86d3a14c02caa306f92def46efd5832df03cd7967443b415f026e81b5957c634" ++
    "ae1d7b7341d36b11993d4ca92ca770918d263c319e3dba9e9e6314d9c5e2b5f6" ++
    "ae7aec17ff19adc1fa152839d0930236aab73a575b7bd54c398c3e00b8bf70b1";

comptime {
    // A 64-digit digest, the separator and a 2048-bit value with no leading zero.
    std.debug.assert(crypto_body.len == 64 + 1 + 512);
}

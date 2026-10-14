//! The JavaScript fixtures the benchmark's routes run and the exchanges a
//! load sends them; one workload, read from `Workload.environment_name`,
//! serves every route of a run. Each handler's first statement calls the
//! handler-entry marker through optional chaining, so the call does nothing
//! where the marker is absent: only a worker booted with the benchmark flag
//! installs it, and only for its first handler call (`bench_handler` in
//! `worker/runtime/types.zig`).
//!
//! `hello` and `crypto` keep the fixtures of the recorded baselines. Every
//! other workload installs the steps fixture, which answers a GET with no
//! query as `hello` does and runs the step its `?step=` query names, so one
//! worker can run the whole `sequence`. A patterned body, which the client
//! (`client.cc`), the stream step and the origin (`origin.zig`) write and
//! check, holds `(i / pattern_block_bytes) % 256` at byte `i`.
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
    upload,
    stream,
    fetch,
    fetch_upload,
    webcrypto,
    /// `hello` ten times, then `upload`, `stream`, `fetch` and
    /// `fetch_upload` once each, on one worker.
    sequence,

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
            .upload, .stream, .fetch, .fetch_upload, .webcrypto, .sequence => steps_source,
        };
    }

    /// The request a cold sample sends: the fixture's plain GET.
    pub fn coldExchange(workload: Workload) Exchange {
        return switch (workload) {
            .crypto => .crypto,
            .hello, .upload, .stream, .fetch, .fetch_upload, .webcrypto, .sequence => .hello,
        };
    }

    /// The steps one load runs, in order. `requests` sets the request count
    /// of a single-step workload, or null for its default; `sequence` has
    /// fixed counts and fails with `error.FixedLoadRequests` when given one.
    /// The caller bounds `requests` by `load_requests_max`.
    pub fn load(workload: Workload, requests: ?u32) error{FixedLoadRequests}!Load {
        if (requests) |count| std.debug.assert(count >= 1 and count <= load_requests_max);
        var result: Load = .{ .items = undefined, .len = 0 };
        const exchange: Exchange = switch (workload) {
            .hello => .hello,
            .crypto => .crypto,
            .upload => .upload,
            .stream => .stream,
            .fetch => .fetch,
            .fetch_upload => .fetch_upload,
            .webcrypto => .webcrypto,
            .sequence => {
                if (requests != null) return error.FixedLoadRequests;
                @memcpy(result.items[0..sequence_steps.len], &sequence_steps);
                result.len = sequence_steps.len;
                return result;
            },
        };
        // Ten hello requests per loaded instance are the recorded baselines'
        // load; every heavier step runs once.
        const default_requests: u32 = if (exchange == .hello) 10 else 1;
        result.items[0] = .{ .exchange = exchange, .requests = requests orelse default_requests };
        result.len = 1;
        return result;
    }

    /// Whether a load fetches, so the run needs the controller's origin and
    /// a `network` grant that names it.
    pub fn needsOrigin(workload: Workload) bool {
        const plan = workload.load(null) catch unreachable;
        for (plan.steps()) |step| {
            if (step.exchange.fetchesOrigin()) return true;
        }
        return false;
    }
};

/// One request the controller sends to a route and the response it accepts.
pub const Exchange = enum {
    /// A GET answered with `hello_body`.
    hello,
    /// A GET that runs `runCrypto()`; only the `crypto` fixture serves it.
    crypto,
    /// A POST of `upload_body_bytes`, past the ingress payload threshold
    /// (`shared_payload_threshold` in `common/ipc/ingress_channel/
    /// payload_ring.zig`), so it crosses the server-to-worker payload ring.
    upload,
    /// A response of `stream_blocks` chunks of `pattern_block_bytes`, one
    /// per pull of a ReadableStream body, which crosses the worker-to-server
    /// payload ring.
    stream,
    /// One `fetch()` of `fetch_download_bytes` from the origin, read through
    /// the response's stream, which crosses the completion ring and the body
    /// pool.
    fetch,
    /// `fetch_upload_bodies` concurrent `fetch()` POSTs of
    /// `fetch_upload_body_bytes` each, which cross the command ring and the
    /// upload pool.
    fetch_upload,
    /// One `crypto.subtle.digest` of `webcrypto_digest_bytes` zero bytes,
    /// which runs inline on the worker's VM thread.
    webcrypto,

    /// The query the steps fixture dispatches on, appended to the route's
    /// path.
    pub fn query(exchange: Exchange) []const u8 {
        return switch (exchange) {
            .hello, .crypto => "",
            .upload => "?step=upload",
            .stream => "?step=stream",
            .fetch => "?step=fetch",
            .fetch_upload => "?step=fetch_upload",
            .webcrypto => "?step=webcrypto",
        };
    }

    /// Bytes of the patterned request body, or 0 for a GET.
    pub fn requestBodyBytes(exchange: Exchange) u32 {
        return switch (exchange) {
            .upload => upload_body_bytes,
            .hello, .crypto, .stream, .fetch, .fetch_upload, .webcrypto => 0,
        };
    }

    pub fn response(exchange: Exchange) Response {
        return switch (exchange) {
            .hello => .{ .exact = hello_body },
            .crypto => .{ .exact = crypto_body },
            .upload => .{ .exact = upload_body },
            .stream => .{ .patterned = stream_body_bytes },
            .fetch => .{ .exact = fetch_body },
            .fetch_upload => .{ .exact = fetch_upload_body },
            .webcrypto => .{ .exact = webcrypto_body },
        };
    }

    pub fn fetchesOrigin(exchange: Exchange) bool {
        return switch (exchange) {
            .fetch, .fetch_upload => true,
            .hello, .crypto, .upload, .stream, .webcrypto => false,
        };
    }
};

/// The response body an exchange must receive, byte for byte.
pub const Response = union(enum) {
    exact: []const u8,
    /// This many bytes of the block pattern.
    patterned: u32,

    pub fn byteCount(self: Response) u64 {
        return switch (self) {
            .exact => |bytes| bytes.len,
            .patterned => |count| count,
        };
    }
};

pub const Step = struct {
    exchange: Exchange,
    requests: u32,
};

/// The steps of one load: at most `sequence`'s.
pub const Load = struct {
    items: [load_steps_max]Step,
    len: usize,

    pub fn steps(self: *const Load) []const Step {
        return self.items[0..self.len];
    }

    /// The requests one load sends, over every step.
    pub fn requestCount(self: *const Load) u64 {
        var count: u64 = 0;
        for (self.steps()) |step| count += step.requests;
        return count;
    }
};

/// The largest `COLLO_BENCH_LOAD_REQUESTS`: enough hello requests that a
/// worker's console ring and live slots cycle many times over.
pub const load_requests_max: u32 = 10_000;

const sequence_steps = [_]Step{
    .{ .exchange = .hello, .requests = 10 },
    .{ .exchange = .upload, .requests = 1 },
    .{ .exchange = .stream, .requests = 1 },
    .{ .exchange = .fetch, .requests = 1 },
    .{ .exchange = .fetch_upload, .requests = 1 },
};
pub const load_steps_max = sequence_steps.len;

pub const pattern_block_bytes: u32 = 64 * 1024;
pub const upload_body_bytes: u32 = 1024 * 1024;
pub const stream_blocks: u32 = 64;
pub const stream_body_bytes: u32 = stream_blocks * pattern_block_bytes;
pub const fetch_download_bytes: u32 = 4 * 1024 * 1024;
/// A fetch body the handler holds whole is capped at
/// `MATERIALIZED_BODY_BYTES_MAX` in `common/limits/http_body.zig`, and a
/// ReadableStream request body cannot be sent, so the 16 MiB upload goes as
/// four bodies at that cap whose uploads overlap in the upload pool.
pub const fetch_upload_bodies: u32 = 4;
pub const fetch_upload_body_bytes: u32 = 4 * 1024 * 1024;
pub const webcrypto_digest_bytes: u32 = 1024 * 1024;

/// The text binding that hands every route the origin's URL
/// (`writeConfig` in `node.zig`).
pub const origin_binding_name = "BENCH_ORIGIN";
/// The origin's two paths (`origin.zig`).
pub const download_path = "/download";
pub const upload_path = "/upload";

comptime {
    // The origin writes the download one whole block at a time.
    std.debug.assert(fetch_download_bytes % pattern_block_bytes == 0);
}

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

const upload_body = std.fmt.comptimePrint("upload {d}\n", .{upload_body_bytes});
const fetch_body = std.fmt.comptimePrint("fetch 200 {d}\n", .{fetch_download_bytes});
const fetch_upload_body = std.fmt.comptimePrint(
    "fetch_upload {d}\n",
    .{fetch_upload_bodies * fetch_upload_body_bytes},
);
/// SHA-256 of `webcrypto_digest_bytes` zero bytes, as `sha256sum` prints it
/// for `head -c 1048576 /dev/zero`.
const webcrypto_body = "webcrypto 30e14955ebf1352266dc2ff8067e68104607e750abb9d3b36582b8af909fcb58\n";

comptime {
    std.debug.assert(webcrypto_digest_bytes == 1048576);
}

const steps_constants = std.fmt.comptimePrint(
    \\const blockBytes = {d};
    \\const streamBlocks = {d};
    \\const fetchUploadBodies = {d};
    \\const fetchUploadBodyBytes = {d};
    \\const webcryptoDigestBytes = {d};
    \\const originBinding = "{s}";
    \\const downloadPath = "{s}";
    \\const uploadPath = "{s}";
    \\
, .{
    pattern_block_bytes,
    stream_blocks,
    fetch_upload_bodies,
    fetch_upload_body_bytes,
    webcrypto_digest_bytes,
    origin_binding_name,
    download_path,
    upload_path,
});

const steps_source = steps_constants ++
    \\
    \\export default async function handle(request, env) {
    \\  globalThis.__colloBenchHandlerEntered?.();
    \\  const step = new URL(request.url).searchParams.get("step");
    \\  if (step === null) return text("sandbox benchmark\n");
    \\  if (step === "upload") return text(`upload ${(await request.arrayBuffer()).byteLength}\n`);
    \\  if (step === "stream") return streamResponse();
    \\  if (step === "fetch") return text(`fetch ${await fetchDownload(env[originBinding])}\n`);
    \\  if (step === "fetch_upload") return text(`fetch_upload ${await fetchUploads(env[originBinding])}\n`);
    \\  if (step === "webcrypto") return text(`webcrypto ${await digestZeros()}\n`);
    \\  return new Response("unknown step\n", { status: 400 });
    \\}
    \\
    \\function text(body) {
    \\  return new Response(body, { headers: { "content-type": "text/plain" } });
    \\}
    \\
    \\// Chunk k is blockBytes bytes of k, which is the block pattern.
    \\function streamResponse() {
    \\  let block = 0;
    \\  const body = new ReadableStream({
    \\    pull(controller) {
    \\      if (block === streamBlocks) {
    \\        controller.close();
    \\        return;
    \\      }
    \\      controller.enqueue(new Uint8Array(blockBytes).fill(block & 255));
    \\      block += 1;
    \\    }
    \\  });
    \\  return new Response(body, { headers: { "content-type": "application/octet-stream" } });
    \\}
    \\
    \\// Reads the response through its stream, so its bytes cross the body pool
    \\// without being held whole.
    \\async function fetchDownload(origin) {
    \\  const response = await fetch(origin + downloadPath);
    \\  const reader = response.body.getReader();
    \\  let total = 0;
    \\  for (;;) {
    \\    const { done, value } = await reader.read();
    \\    if (done) return `${response.status} ${total}`;
    \\    total += value.byteLength;
    \\  }
    \\}
    \\
    \\async function fetchUploads(origin) {
    \\  const uploads = [];
    \\  for (let index = 0; index < fetchUploadBodies; index += 1) {
    \\    const body = new Uint8Array(fetchUploadBodyBytes).fill(index);
    \\    uploads.push(fetch(origin + uploadPath, { method: "POST", body }).then((response) => response.text()));
    \\  }
    \\  let total = 0;
    \\  for (const received of await Promise.all(uploads)) total += Number(received);
    \\  return total;
    \\}
    \\
    \\async function digestZeros() {
    \\  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new Uint8Array(webcryptoDigestBytes)));
    \\  return Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("");
    \\}
    \\
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

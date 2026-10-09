# WebAPI compatibility tests

This directory is organized by WebAPI surface. Test origin is metadata, not a
folder boundary.

## Imported Fixtures

Files ending in `.bun.test.js` are exact compact ports from
`reference/bun-v1.3.14/test/js/web/**`. Files ending in `.wpt.test.js` are
compact WPT ports. They live next to the API they cover, for example
`runtime/tests/webapi/streams/streams_core.bun.test.js`.

Allowed changes are only:

- Replace `from "bun:test"` with `from "collo:test"` when copying by hand;
  the compat runner also accepts `from "bun:test"` directly and rewrites it to
  the internal test module.
- Keep portable `from "harness"` imports when a Bun fixture uses test helpers
  such as `readableStreamFromArray` or stream collectors. The compat runner
  resolves that import to `runtime/tests/webapi/support/compat_harness.js`.
- Remove TypeScript-only syntax that JavaScriptCore cannot parse.
- Remove TypeScript comments such as `// @ts-ignore`.

Do not change expectations, test names, control flow, fixtures, or values to
match Collo. If an imported fixture fails, the implementation is wrong or the
fixture is not compact-portable and must be removed from the imported-fixture
set.

The compat harness intentionally exposes only WebAPI-compact helpers. It must
not shim `Bun.file`, `Bun.spawn`, `Buffer`, Node streams, filesystem helpers, or
network servers. A fixture requiring those belongs in the Collo contract suite,
or in a later API phase, not as a `.bun.test.js` / `.wpt.test.js` fixture.

Current exact compact ports:

- `blob/blob_array_fast_path.bun.test.js`
- `body/body_mixin_errors.bun.test.js`
- `encoding/encode_bad_chunks.bun.test.js`
- `encoding/text_decoder_stream.bun.test.js`
- `encoding/text_encoder_stream.bun.test.js`
- `formdata/form_data_boundary_crash.bun.test.js`
- `message_event/message_event.bun.test.js`
- `microtask/microtask.bun.test.js`
- `request/request.bun.test.js`
- `streams/body_response.bun.test.js`
- `streams/compression.bun.test.js`
- `streams/readable_stream_body.bun.test.js`
- `streams/streams_core.bun.test.js`
- `streams/streams_globals.bun.test.js`
- `streams/wpt_compact.wpt.test.js`
- `text_codec/text_decoder_cjk.bun.test.js`
- `text_codec/text_decoder_single_byte.bun.test.js`
- `text_codec/text_decoder_wpt.bun.test.js`

These files intentionally do not need matching `*.bench.js` files.

## Collo Contracts

Files under `runtime/tests/webapi/<api>/*.test.js` are Collo compatibility contracts.
They may be derived from Bun, WebKit, WPT, Node, or prior bug reports. If they
do not use the `.bun.test.js` or `.wpt.test.js` suffix, they are not exact
imported fixtures. These tests are allowed to combine cases, remove Bun-only
APIs, and document Collo's server-runtime profile.

Every non-imported `*.test.js` file must have a matching `*.bench.js` file with
the same basename. Bench files run through `zig build bench-webapi` and compare
Collo and Bun for the same named benchmark cases. `compare: false` is not
allowed. Files ending in `_leak.test.js` are excluded because they validate
GC/retention checkpoints, not steady-state operation latency.

Leak fixtures should use the shared leak helpers from
`runtime/tests/webapi/support/leak_harness.js` (`leakTest`, `describeLeaks`,
`weakRecord`, `makeWeakRefs`, and `expectLeakRecordsCollected`) instead of
copying per-file WeakRef bookkeeping.

Exact Bun/WPT stream fixtures live in `runtime/tests/webapi/streams` with `.bun.test.js`
or `.wpt.test.js` suffixes. Collo stream regression files stay in the same
directory without those suffixes and must keep matching bench files.

## Running

Run the JavaScript compatibility matrix explicitly:

```sh
zig build test -Dwebapi-compat=true
```

The common long-build cache used during local work is:

```sh
ZIG_LOCAL_CACHE_DIR=/tmp/collo-zig-cache-build-long zig build test -Dwebapi-compat=true
```

Bench runs default to three measurements per case for each runtime. Override
the run count with:

```sh
COLLO_WEBAPI_BENCH_RUNS=5 zig build bench-webapi
```

## Compact Non-Portable Bun Tests

Some Bun WebAPI tests cannot be copied as `.bun.test.js` fixtures because they depend on
Bun or Node runtime APIs rather than only Web APIs. Do not partially rewrite
them into `.bun.test.js`; keep matching Collo behavior in the normal contract
suite until the required API exists.

Currently non-portable examples:

- `fetch/headers.undici.test.ts`: imports `node:events` and `node:http`.
- `fetch/headers.test.ts`: includes `Bun.inspect()` assertions.
- `fetch/response.test.ts`: imports `harness`, uses `Bun.inspect()` and
  `Bun.file()`.
- `fetch/body.test.ts` and `fetch/blob.test.ts`: use `Bun.file()`,
  `Bun.spawn()`, `Buffer`, filesystem fixtures, and network servers.
- `html/FormData.test.ts`: uses `Bun.serve()`, `Bun.file()`,
  `bun:internal-for-testing`, `Buffer`, and Node path helpers.
- `html/URLSearchParams.test.ts` and `url/url.test.ts`: include Bun inspect
  formatting and TypeScript fixture-only sections.
- `timers/setTimeout.test.js` and `timers/setInterval.test.js`: include
  `Bun.sleep`, subprocess fixtures, Node timers, and timer-handle extensions.
- `encoding/text-encoder.test.js` and `encoding/text-decoder.test.js`: include
  `Bun.file()`, `Bun.gc()`, and memory harness checks.
- `crypto/web-crypto.test.ts`: uses `Bun.spawn()`, `Bun.sleep()`,
  `bun:jsc`, and memory harness checks.
- `crypto/web-crypto-sha3.test.ts`: portable WebCrypto SHA-3 vectors and
  RSA/HMAC/KDF SHA-3 cases are covered in `crypto/crypto.test.js`; the source
  file also mixes `Buffer` and `node:crypto` assertions that belong in Node API
  coverage.
- Fetch network, WebSocket, Worker, and remaining non-portable memory harnesses
  are future phases.

When one of those APIs is implemented, copy the relevant Bun file into the API
directory with a `.bun.test.js` suffix, using only the allowed transformations
above.

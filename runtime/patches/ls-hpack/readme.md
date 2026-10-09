# ls-hpack patches

The vendored source in `runtime/deps/ls-hpack` is byte-identical to official
upstream v2.3.5. The build and bench apply every `*.patch` in this directory,
in filename order, to a generated copy. The production build compiles the HPACK
shim against that copy and leaves the vendored checkout unchanged.

The Zig patch-generator step registers each regular vendored file and each
direct `*.patch` file as an explicit build input. This makes its cache key
content-sensitive: changing either the official source or this queue creates a
new generated tree even when a warm local Zig cache already contains an older
one. Source symlinks and special files are rejected fail-closed.

- **0001-ls-hpack-harden-decoder.patch** — Hardens the HPACK decoder
  against malformed peer input: validates varint overflow and shift UB,
  rejects truncated string literals, handles entries larger than the dynamic
  table per RFC 7541, and avoids zero-length `memcpy`/pointer arithmetic on
  null storage, including an empty literal name inserted into the dynamic
  table by a peer.

- **0002-ls-hpack-encoder-precompute.patch** — Adds the encoder precompute
  path (`lshpack_enc_precompute_static`) to cache static indexes,
  name/name-value hashes, and exact static-table value matches once. Full
  precompute promotes duplicate static names such as `:method GET` to the exact
  value entry such as `:method POST`; `NEVER_INDEX` still uses name-only
  matching so sensitive values are never emitted as indexed name/value
  references.

- **0003-ls-hpack-fixups.patch** — Applies tooling and API-state fixups:
  CMake `LSHPACK_FAST_DECODE`, `encode-qif -s` sensitive-header policies,
  zero-copy QIF header setup, `strtoul` argument validation, correct
  `MAP_FAILED` checks, correct `set_max_capacity` ordering,
  newest-entry-preserving history resize, oversized encoder-entry skipping,
  and regression tests.

- **0004-ls-hpack-precomputed-static-miss.patch** — Marks a static-table
  miss established during full precompute so reusable prepared headers skip
  both repeated static probes while retaining dynamic-table name/value and
  name-only lookups. Its regression verifies that a prepared miss still finds
  the entry inserted by the preceding encode.

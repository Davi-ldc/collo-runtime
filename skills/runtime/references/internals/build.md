# Build: recipe, profiles and paths

`zig build <step>` from the repository root is the only entrypoint. A fresh clone needs `zig build webkit-provision` once. After that, `zig build` builds the engine when it is missing or stale and links the binary, and later runs admit the existing engine by its provenance without rebuilding anything.

A root `build.zig` orchestrates the runtime, and the machinery lives in `runtime/build/`. The flow is `options.zig` → toolchain, engine and bridge assembled once → two module graphs (`modules.zig`: the JSC graph serves the binary and the linked tests, the `h2_stub` graph serves the JSC-free transport tests) → steps in `tests.zig`, `bench.zig` and `release.zig`. `context.zig` carries all of this by pointer to every wiring function, so no step builds its own graph or rediscovers the toolchain. The engine is `oven-sh/WebKit` at the commit in `runtime/deps/webkit.version`, which `jsc.zig` reads at configure time, with the series `runtime/patches/webkit/*.patch` applied to a generated copy; the pinned tree is never edited. BoringSSL and ls-hpack follow the same model, with series in `runtime/patches/`; every pin is listed under Pins below.

## Commands

| Command | What it does |
| --- | --- |
| `zig build webkit-provision` | Partial clone of `oven-sh/WebKit` into `runtime/deps/WebKit`: `fetch --depth=1 --filter=blob:none` of the pin only, a sparse checkout of the cone a JSCOnly build opens, HEAD detached at the pin. About 20 s and 110 MB of objects. Idempotent at the pin; it fails if the directory exists with another HEAD, because the checkout is an input and the tool never removes it. |
| `zig build jsc` | The engine only: patched worktree, CMake and Ninja in `runtime/deps/jsc-build/<triple>/<profile>/{src,build}`, ten minutes with 4 jobs on this machine. Every step that links JSC depends on it. With `-Djsc-prebuilt` it only admits the existing build and fails if that build is stale. |
| `zig build` | The `collo` binary in `zig-out/bin`. |
| `zig build check` | Type-checks every test and bench root and the serve smoke driver, without linking or running. A suite that stops compiling fails here instead of waiting for its lane. |
| `zig build test` | The aggregate: the JSC suite plus every deterministic JSC-free suite. |
| `zig build <domain>-test` | One filtered partition of the same binary; the lanes and fast lanes are listed in [CLAUDE.md](../../../../CLAUDE.md#build-and-tests). |
| `zig build run-collo -- serve <collo.json or entry.js>` | Serves the configuration, or the entry module with a configuration synthesized from it, on `https://127.0.0.1:8443` through real workers until Ctrl-C; needs the delegated cgroup, entered with `wsl-config run` or named in `COLLO_WORKER_CGROUP_ROOT` ([boot.md](boot.md#the-worker-cgroup-root)). |
| `zig build webkit-authoring` | Worktree `runtime/deps/webkit-authoring` on the branch `collo-patches` from the pin, with the series applied by `git am`. The tool never recreates it. |
| `zig build webkit-export` | Regenerates `runtime/patches/webkit/` from the branch with `git format-patch`; it refuses a dirty worktree or a base off the pin. |
| `zig build release` / `release-x86` | The product: aarch64 or x86_64 in ReleaseFast, with the CPU from `COLLO_RELEASE_MCPU`. The aarch64 cross build requires `COLLO_CXX_SYSROOT`. |
| `zig build wsl-config` | Checks the cgroup environment; `sudo ./zig-out/bin/wsl-config prepare` provisions it and `... run -- <cmd>` enters it. |

## Limits

Four jobs, and never two builds at once: `zig build -j4` with `COLLO_BUILD_JOBS=4` and `CMAKE_BUILD_PARALLEL_LEVEL=4`, because automatic parallelism exhausts WSL's memory. There is no lock; there is one machine and the rule is discipline. Two `jsc` runs in one directory trample each other, and two `zig build` runs on one `.zig-cache` are flaky.

## Paths

Everything lives in the repository, which is on native ext4, under directories git ignores. The buildtool derives the same layout as `options.zig` and refuses any generated directory outside `runtime/deps/jsc-build`, so an `rm -rf` of it never reaches anything else. Nothing build-related may live under `/mnt/c`: `cachefs.zig` fails at configure time when the cache lands on drvfs, and `COLLO_ALLOW_DRVFS_CACHE=1` downgrades that to a warning for the deliberate case only.

| Path | Contents |
| --- | --- |
| `runtime/deps/WebKit` | Partial clone of `oven-sh/WebKit`, HEAD at the pin, never edited. |
| `runtime/deps/webkit-authoring` | Authoring worktree on the branch `collo-patches`. |
| `runtime/deps/jsc-build/<triple>/<profile>/{src,build}` | Patched worktree and engine build, with stamp and attestation. |
| `runtime/deps/boringssl`, `runtime/deps/ls-hpack` | Pinned trees; BoringSSL builds in `build/` and `build-aarch64/` inside its own tree. |
| `.zig-cache`, `zig-out` | The Zig cache and installed binaries. |

C++ toolchain: clang 19, libstdc++ 13 and llvm-19's compiler-rt, discovered by `toolchain.zig`. `COLLO_CXX_SYSROOT`, `COLLO_CXX_STDLIB_VERSION`, `COLLO_COMPILER_RT_BUILTINS` and `CXX` are the escape hatches, kept out of the `-D` surface.

## Engine profiles

The engine's CMake configuration is `PORT=JSCOnly`, `ENABLE_STATIC_JSC=ON`, `USE_BUN_JSC_ADDITIONS=ON`, `EVENT_LOOP_TYPE=Generic`, `USE_BUN_EVENT_LOOP=OFF`, with no remote inspector, built with clang-19 and lld (`jsc_cmake_profile_args` in `buildtool.zig`). The profile is `-Djsc-profile=release|debug`, `release` by default, independent of the runtime's `-Doptimize`: the dev loop links a Debug or ReleaseSafe runtime against the Release engine, and the Debug engine exists for the sanitized bindings smokes. As in JITCache, headers, libraries and binaries never mix across profiles, because assertions and sanitizers change the ABI.

## Provenance

`jsc-build` writes `.collo-jsc.stamp` (schema v3: commit, series hash, triple, CMake build type, sysroot, mcpu, compiler, tool identity) and `.collo-jsc.attestation.v2` with the digests of the three archives. `jsc-validate-prebuilt` rebuilds both byte for byte from the inputs, `CMakeCache.txt` and `build.ninja`, and `archiveMatchesArch` checks the `e_machine` of every ELF object inside the archives. A build for another architecture, from another series or made at another path is rejected with the difference named. An up-to-date build is one that reproduces the stamp, whatever its mtime.

## Patches: authoring and export

The series is the source, and the build reads only the series. The authoring worktree never feeds a binary, so an uncommitted edit never reaches the engine. Edit in `runtime/deps/webkit-authoring`, one commit per patch: the subject becomes the file name (`0001-<hyphenated subject>.patch`) and the body is the rationale, so no parallel document is needed. `zig build webkit-export` deletes the previous series and regenerates it with `git format-patch --zero-commit --no-signature <pin>..collo-patches`, which makes the output reproducible byte for byte; it refuses a dirty worktree and a branch whose base left the pin. The series' `readme.md` is the index, one line per patch.

## Pins

| Dependency | Version | Where the pin lives | What checks it |
| --- | --- | --- | --- |
| Zig | official 0.15.2 (ziglang.org) | only in `CLAUDE.md` | nothing; a wrong compiler shows up as a compile error in `build.zig` |
| WebKit | `oven-sh/WebKit@2e2aa2290fac856d6f451ceacb58f7f5b44dd057` | `runtime/deps/webkit.version` | the buildtool refuses a checkout whose HEAD is off the pin and an engine from another commit or series |
| BoringSSL | tag `0.20260413.0`, commit `78f7fbeec98a2fb15acea6f7a9f1def7f2e6d9a0` | `runtime/deps/boringssl.version` | nothing |
| ls-hpack | `v2.3.5` | only `LSHPACK_{MAJOR,MINOR,PATCH}_VERSION` in `runtime/deps/ls-hpack/lshpack.h` | nothing |
| clang | 19 | `checkRequiredCommands` in `buildtool.zig` | the buildtool, and the stamp records the exact version |

Each patched dependency has its series in `runtime/patches/<dep>/` with a `readme.md`: four patches for WebKit, one for BoringSSL (exposing SHA3 as `EVP_MD`) and four for ls-hpack (decoder hardening, encoder precompute, fixups, precomputed static-table miss). Patches apply in byte-wise lexicographic order.

Collo uses the official Zig, and the one difference from Bun's fork that matters is that `Build.Module.sanitize_address` exists in the fork and not in the official release. The capability is named once, in `shims.zig_module_asan_supported`, and every request goes through `shims.sanitizeZigModule`. With the official Zig, the Zig half of a sanitized artifact loses instrumentation while the C++ half keeps it, because `BindingsSanitizer.cFlags` passes `-fsanitize=address,leak` straight to clang.

Gaps: no step provisions BoringSSL or ls-hpack, and `shims.zig` fails at configure time when they are missing; nothing asserts the Zig pin; ls-hpack has no version file.

## Invariants

A `-D` flag is born only in `options.zig`, and linking against the engine happens only in `link.zig`. The module graph is built once and every step consumes the same one. A pinned dependency is never edited in place. The engine enters only with intact provenance. Release builds reject a non-static zstd and a wrong architecture. A cache on drvfs fails at configure time instead of stalling midway.

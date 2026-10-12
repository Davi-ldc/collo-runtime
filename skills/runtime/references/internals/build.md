# Build: recipe, profiles and paths

`zig build <step>` from the repository root is the only entrypoint. A fresh clone needs `zig build deps-provision` once, which fetches every pinned source tree. After that, `zig build` builds ICU, BoringSSL and the engine when they are missing or stale and links the binary, and later runs admit the existing builds by their stamps without rebuilding anything.

A root `build.zig` orchestrates the runtime, and the machinery lives in `runtime/build/`. The flow is `options.zig` → toolchain, native dependencies, engine and bridge assembled once → two module graphs (`modules.zig`: the JSC graph serves the binary and the linked tests, the `h2_stub` graph serves the JSC-free transport tests) → steps in `tests.zig`, `bench.zig` and `release.zig`. `context.zig` carries all of this by pointer to every wiring function, so no step builds its own graph or rediscovers the toolchain. Every step that runs the host build tool (`buildtool.zig`) shares one compilation of it (`tool.zig`).

Every third-party library Collo runs is a pinned dependency: a pristine tree under `runtime/deps/`, fetched at the commit in its version file (`runtime/build/pins.zig` lists them) and never edited, built by the repository's own steps and linked statically into the one binary. The engine is `oven-sh/WebKit` with the series `runtime/patches/webkit/*.patch` applied to a generated worktree (`jsc.zig`). ICU and BoringSSL are built by the build tool outside Zig's cache, each into one directory per target with a stamp (`deps.zig`); BoringSSL's series is applied to a worktree of its commit. zlib, brotli and zstd are compiled by Zig from their trees (`codecs.zig`), and ls-hpack's series is applied to a generated copy in Zig's cache (`shims.zig`). The binary's only shared libraries are the platform's, and nothing loads code at run time.

## Commands

| Command | What it does |
| --- | --- |
| `zig build deps-provision` | Fetches every pinned tree into `runtime/deps/`: a shallow fetch of the pin, by its tag when the version file names one, refused when the tag resolves to another commit, then a detached checkout. WebKit and ICU are blob-less sparse checkouts of the directories a build opens. Idempotent at the pins; a tree that exists is checked and never replaced, because it is input, so a tree off its pin must be moved aside by hand. |
| `zig build webkit-provision` | The WebKit part of `deps-provision` alone: about 20 s and 110 MB of objects. |
| `zig build icu` | ICU and its data: ICU's own `configure` and `make` out of tree into `runtime/deps/icu-build/<triple>/{build,install}`, static libraries with the data built from source and packaged statically, dynamic loading disabled. A few minutes; it needs `make` and `python3`. An aarch64 build first builds the host's, whose tools generate its data. With `-Djsc-prebuilt` it only admits the existing build. |
| `zig build boringssl` | BoringSSL: a worktree of the pin in `runtime/deps/boringssl-build/<triple>/src` with `runtime/patches/boringssl/` applied by `git apply`, built by CMake and Ninja into `build/`. About a minute. |
| `zig build jsc` | The engine only: patched worktree, CMake and Ninja in `runtime/deps/jsc-build/<triple>/<profile>/{src,build}`, ten minutes with 4 jobs on this machine, compiled against the ICU of `zig build icu`. Every step that links JSC depends on it. With `-Djsc-prebuilt` it only admits the existing build and fails if that build is stale. |
| `zig build` | The `collo` binary in `zig-out/bin`. |
| `zig build check` | Type-checks every test and bench root and the serve smoke driver, without linking or running. A suite that stops compiling fails here instead of waiting for its lane. |
| `zig build test` | The aggregate: the JSC suite plus every deterministic JSC-free suite. |
| `zig build <domain>-test` | One filtered partition of the same binary; the lanes and fast lanes are listed in [CLAUDE.md](../../../../CLAUDE.md#build-and-tests). `webapi-test` is one of them, and the aggregate runs the WebAPI suites like every other domain. |
| `zig build bindings-gc-stress` | The aggregate binary twice more, under two collector profiles that JSC reads from `JSC_<option>` variables before Collo's options callback runs (`gc_stress_profiles` in `runtime/build/tests.zig`): forced, a synchronous full collection each time a size-class allocator takes its slow path, with freed cells scribbled and verified, over `bindings/tests/gc_stress/`; concurrent, back-to-back concurrent collections each re-marked from the roots, over that directory, the promise and body-stream rooting tests (`bindings/tests/stream_promise_roots.zig`, `body_stream_roots.zig`) and the WebAPI suites. Smoke runs both, strict, after the aggregate and before `zygote-integration`; each profile is sized to about two minutes on the reference machine, and one that outgrows it narrows its filters. |
| `zig build run-collo -- serve <collo.json or entry.js>` | Serves the configuration, or the entry module with a configuration synthesized from it, on `https://127.0.0.1:8443` through real workers until Ctrl-C; needs the delegated cgroup, entered with `wsl-config run` or named in `COLLO_WORKER_CGROUP_ROOT` ([boot.md](boot.md#the-worker-cgroup-root)). |
| `zig build webkit-authoring` | Worktree `runtime/deps/webkit-authoring` on the branch `collo-patches` from the pin, with the series applied by `git am`. The tool never recreates it. |
| `zig build webkit-export` | Regenerates `runtime/patches/webkit/` from the branch with `git format-patch`; it refuses a dirty worktree or a base off the pin. |
| `zig build release` / `release-x86` | The product: aarch64 or x86_64 in ReleaseFast, with the CPU from `COLLO_RELEASE_MCPU`, linking ICU, BoringSSL and the codecs built for that architecture and CPU. The aarch64 cross build requires `COLLO_CXX_SYSROOT`. |
| `zig build wsl-config` | Checks the cgroup environment; `sudo ./zig-out/bin/wsl-config prepare` provisions it, failing and naming the controller when cpu, memory or pids cannot be enabled, and `... run -- <cmd>` enters it. `zig build wsl-config-test` tests `prepare` without a cgroup. |

## Limits

Four jobs, and never two builds at once: `zig build -j4` with `COLLO_BUILD_JOBS=4` and `CMAKE_BUILD_PARALLEL_LEVEL=4`, because automatic parallelism exhausts WSL's memory. `COLLO_BUILD_JOBS` also sets the jobs of ICU's `make` and of the BoringSSL and engine Ninja builds. There is no lock; there is one machine and the rule is discipline. Two runs in one build directory trample each other, which is why the build graph creates one step per directory however many artifacts need it, and two `zig build` runs on one `.zig-cache` are flaky.

## Paths

Everything lives in the repository, which is on native ext4, under directories git ignores. The build tool derives the same layout as `options.zig` and `deps.zig` and refuses any generated directory outside `runtime/deps/jsc-build`, `runtime/deps/icu-build` and `runtime/deps/boringssl-build`, so its `rm -rf` of one never reaches anything else. Nothing build-related may live under `/mnt/c`: `cachefs.zig` fails at configure time when the cache lands on drvfs, and `COLLO_ALLOW_DRVFS_CACHE=1` downgrades that to a warning for the deliberate case only.

| Path | Contents |
| --- | --- |
| `runtime/deps/WebKit` | Blob-less sparse clone of `oven-sh/WebKit`, HEAD at the pin, never edited. |
| `runtime/deps/webkit-authoring` | Authoring worktree on the branch `collo-patches`. |
| `runtime/deps/jsc-build/<triple>/<profile>/{src,build}` | Patched worktree and engine build, with stamp and attestation. |
| `runtime/deps/icu` | Blob-less sparse checkout of `icu4c/source` at the pin. |
| `runtime/deps/icu-build/<triple>[-<mcpu>]/{build,install}` | ICU's build directory and install prefix, with `.collo-icu.stamp`. |
| `runtime/deps/boringssl` | Checkout of BoringSSL at the pin. |
| `runtime/deps/boringssl-build/<triple>[-<mcpu>]/{src,build}` | Patched worktree and BoringSSL build, with `.collo-boringssl.stamp`. |
| `runtime/deps/ls-hpack`, `runtime/deps/zlib`, `runtime/deps/brotli`, `runtime/deps/zstd` | Checkouts at their pins, read in place by Zig compilations. |
| `.zig-cache`, `zig-out` | The Zig cache, with the codec libraries and the patched ls-hpack copy, and the installed binaries. |

C++ toolchain: clang 19, libstdc++ 13 and llvm-19's compiler-rt, discovered by `toolchain.zig`. `COLLO_CXX_SYSROOT`, `COLLO_CXX_STDLIB_VERSION`, `COLLO_COMPILER_RT_BUILTINS` and `CXX` are the escape hatches, kept out of the `-D` surface. ICU and BoringSSL compile with clang-19 too, from an environment the build tool cleans of `CFLAGS`, `LDFLAGS`, `MAKEFLAGS` and the other variables a configure script or CMake reads, so a shell setting never reaches a build its stamp does not describe.

## Kernel

Most of what the runtime needs from the kernel shows up as a lane that skips or fails on a host without it, and [e2e.md](../e2e.md) names the kernel lanes' gates. One requirement stops the zygote itself: `CONFIG_CHECKPOINT_RESTORE`. Without it `prctl(PR_GET_TID_ADDRESS)` fails, and the zygote refuses to prepare (`zygote/fork_loop.zig:prepareZygoteAtBoot`), because a worker it clones with `clone3` must find its own thread id in glibc's thread descriptor, which `CLONE_CHILD_SETTID` writes at that address (`common/os.zig:process.callingThreadIdWord`); without it the worker's thread CPU clock would name the zygote's thread.

## Engine profiles

The engine's CMake configuration is `PORT=JSCOnly`, `ENABLE_STATIC_JSC=ON`, `USE_BUN_JSC_ADDITIONS=ON`, `EVENT_LOOP_TYPE=Generic`, `USE_BUN_EVENT_LOOP=OFF`, with no remote inspector, built with clang-19 and lld (`jsc_cmake_profile_args` in `buildtool.zig`). FindICU receives every result it would search for, the root, the include directory and the three archives of the pinned ICU (`icu_build.cmake_cache_entries`), so the engine never compiles against the machine's ICU, and the bridge includes the same headers ahead of every system directory. The profile is `-Djsc-profile=release|debug`, `release` by default, independent of the runtime's `-Doptimize`: the dev loop links a Debug or ReleaseSafe runtime against the Release engine, and the Debug engine exists for the sanitized bindings smokes. As in JITCache, headers, libraries and binaries never mix across profiles, because assertions and sanitizers change the ABI. A change to `runtime/patches/webkit/` also requires one `zig build smoke -Djsc-profile=debug` on the final series before handoff.

## Provenance

`jsc-build` writes `.collo-jsc.stamp` (schema v4: commit, series hash, triple, CMake build type, sysroot, mcpu, compiler, tool identity, the ICU prefix and the digest of its headers) and `.collo-jsc.attestation.v3` with the digests of the three archives. `jsc-validate-prebuilt` rebuilds both byte for byte from the inputs, `CMakeCache.txt` and `build.ninja`, and `archiveMatchesArch` checks the `e_machine` of every ELF object inside the archives. A build for another architecture, from another series, against other ICU headers or made at another path is rejected with the difference named. An up-to-date build is one that reproduces the stamp, whatever its mtime.

The ICU and BoringSSL stamps follow the same rule in one file each: the inputs (commit, series hash for BoringSSL, triple, sysroot, mcpu, compiler, the exact configure or CMake arguments, tool identity, and for a cross-built ICU the digest of the host build's stamp) followed by the outputs (the digest of the installed or patched header tree and the digest and size of each archive, every object of which must target the build's machine). A directory is up to date when the stamp the current inputs and outputs produce equals the one on disk; a build removes the stamp first, so one that stops halfway is rebuilt. The tool identity hashes `buildtool.zig` and `pins.zig`, so a change to the code that reads provenance invalidates every stamp it wrote.

The trees the build reads in place are checked on every build: `deps-verify` refuses ls-hpack and the codecs unless each is a standalone checkout with HEAD at its pin and no edited, staged or untracked file, and the ICU build checks its tree the same way before and after it runs. WebKit and BoringSSL need only HEAD at the pin, because their builds read worktrees of the commit, where an uncommitted edit cannot appear.

## Patches: authoring and export

The series is the source, and the build reads only the series. The authoring worktree never feeds a binary, so an uncommitted edit never reaches the engine. Edit in `runtime/deps/webkit-authoring`, one commit per patch: the subject becomes the file name (`0001-<hyphenated subject>.patch`) and the body is the rationale, so no parallel document is needed. `zig build webkit-export` deletes the previous series and regenerates it with `git format-patch --zero-commit --no-signature <pin>..collo-patches`, which makes the output reproducible byte for byte; it refuses a dirty worktree and a branch whose base left the pin. The series' `readme.md` is the index, one line per patch.

## Pins

| Dependency | Version | Where the pin lives | What checks it |
| --- | --- | --- | --- |
| Zig | official 0.15.2 (ziglang.org) | only in `CLAUDE.md` | nothing; a wrong compiler shows up as a compile error in `build.zig` |
| WebKit | `oven-sh/WebKit@2e2aa2290fac856d6f451ceacb58f7f5b44dd057` | `runtime/deps/webkit.version` | the build tool refuses a checkout whose HEAD is off the pin and an engine from another commit, series or ICU |
| ICU | tag `release-78.3`, commit `21d1eb0f306e1141c10931e914dfc038c06121da` | `runtime/deps/icu.version` | `deps-provision`; the ICU build refuses a tree off the pin or not pristine, and its stamp records the commit |
| BoringSSL | tag `0.20260413.0`, commit `78f7fbeec98a2fb15acea6f7a9f1def7f2e6d9a0` | `runtime/deps/boringssl.version` | `deps-provision`; the BoringSSL build refuses a checkout off the pin, and its stamp records the commit and series |
| ls-hpack | tag `v2.3.5`, commit `cf0f70dd10b352194c97448eb5d00b4aa484f531` | `runtime/deps/ls-hpack.version` | `deps-provision` and `deps-verify` |
| zlib | tag `v1.3.2`, commit `da607da739fa6047df13e66a2af6b8bec7c2a498` (upstream madler/zlib) | `runtime/deps/zlib.version` | `deps-provision` and `deps-verify` |
| brotli | tag `v1.2.0`, commit `028fb5a23661f123017c060daa546b55cf4bde29` | `runtime/deps/brotli.version` | `deps-provision` and `deps-verify` |
| zstd | tag `v1.5.7`, commit `f8745da6ff1ad1e7bab384bd1f9d742439278e99` | `runtime/deps/zstd.version` | `deps-provision` and `deps-verify` |
| clang | 19 | `checkRequiredCommands` in `buildtool.zig` | the build tool, and every stamp records the exact version |

Each patched dependency has its series in `runtime/patches/<dep>/` with a `readme.md`: five patches for WebKit, one for BoringSSL (exposing SHA3 as `EVP_MD`) and four for ls-hpack (decoder hardening, encoder precompute, fixups, precomputed static-table miss). Patches apply in byte-wise lexicographic order. ICU and the codecs carry none (`Patches: none`); a patch to one of them would be a series applied to a generated copy, never an edit of its tree.

The codecs build in ReleaseFast with C sanitizers off whatever `-Doptimize` says, like the engine's profile, and their public headers reach Zig through translate-C modules that only `bindings/{zlib,brotli,zstd}/root.zig` import. zlib leaves out its gz* file API, zstd its legacy formats and multithreading, and brotli computes its tables at compile time. An executable Zig links names the codec libraries itself (`codecs.linkInto`), and a link `link.zig` drives names their archives (`codecs.addToCxxLink`); an archive adds only the members something calls.

Collo uses the official Zig, and the one difference from Bun's fork that matters is that `Build.Module.sanitize_address` exists in the fork and not in the official release. The capability is named once, in `shims.zig_module_asan_supported`, and every request goes through `shims.sanitizeZigModule`. With the official Zig, the Zig half of a sanitized artifact loses instrumentation while the C++ half keeps it, because `BindingsSanitizer.cFlags` passes `-fsanitize=address,leak` straight to clang.

`-Dsanitize` (or `COLLO_SANITIZE`) picks the mode for Collo's C++ (the bridge, the BoringSSL shim, the TLS and SecretBytes test shims and the sandbox bench's client) and never for the engine, ICU, BoringSSL or the codecs: `address` is ASan with LSan, and `undefined` is UBSan's alignment and float-cast-overflow checks with `-fno-sanitize-recover` and `-fno-sanitize-trap`, so a misaligned read or a float cast out of an integer's range aborts the process with its report, whatever trap mode Zig's own C flags ask for. Those two faults run silently on x86_64 and ARM64, so this mode is the only lane where a test can fail on them; it instruments no Zig, whose safety checks cover the same faults. The final link passes the same `-fsanitize` flags, so the native C++ driver adds the sanitizer's runtime, and the runs set `ASAN_OPTIONS` or `UBSAN_OPTIONS` (`BindingsSanitizer` in `runtime/build/shims.zig`). A sanitized build's binary names the sanitizer's runtime library, so `meta-test`'s `binary_dependencies` contract, which describes the production binary, fails under either mode; run the lanes the sanitizer is for, such as `bindings-test` and `webapi-test`.

Gaps: nothing asserts the Zig pin. ICU's data is complete; filtering it to what Collo uses is a later, measured change.

## Invariants

A `-D` flag is born only in `options.zig`, and linking against the engine happens only in `link.zig`. The module graph is built once and every step consumes the same one. A pinned dependency is never edited in place. The engine, ICU and BoringSSL enter only with intact provenance. Every library Collo runs is compiled from a pinned tree and linked statically: the installed binary needs only the platform's shared libraries, and the loader functions it imports are exactly the ones `runtime/tests/contracts/binary_dependencies.zig` lists with their callers, none of which loads a library (bmalloc's sanitizer probe opens the main program, WTF's and Zig's stack traces read the objects already loaded). Collo's own code never calls the loader or links `libdl` (the conventions gate `runtime code loads no native code at run time`). glibc's NSS can load a `hosts` service for `getaddrinfo` through libc's internal entry points, which no import shows; the gateway, the only process that resolves names, runs in a root that holds no such library (`egress/gateway/sandbox.zig`). Release builds reject a wrong architecture. A cache on drvfs fails at configure time instead of stalling midway.

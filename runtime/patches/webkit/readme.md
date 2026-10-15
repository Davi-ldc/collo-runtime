# WebKit patches

`zig build webkit-export` generates this series from the branch `collo-patches` in `runtime/deps/webkit-authoring`, one commit per patch. The body of each `.patch` explains what it changes and why the embedder cannot get the behavior without touching the engine. Edit there and export; never edit here ([build.md, Patches](../../../skills/runtime/references/internals/build.md#patches-authoring-and-export)). The build applies the series in `LC_ALL=C` order to a generated copy of the pinned checkout.

| Patch | What it gives the embedder |
| --- | --- |
| `0001-compiler-thread-lifecycle` | Creating and pinning the compiler threads (JIT and wasm) before seccomp denies `clone`, draining the worklists before a fork, and a pinned `AutomaticThread` that releases its malloc cache once it has waited an interval the embedder sets, so the libpas scavenger can reach its deep sleep in a worker. |
| `0002-embedder-memory-budget` | The worker's memory limit in the engine's two memory decisions: an effective `gcMaxHeapSize`, which the worker sets to 90% of its limit (`gcHeapLimitBytes` in `runtime/src/common/cgroup.zig`), so the engine requests a collection once the bytes allocated since the last one pass it, with nothing capping the heap; and a memory status read from the worker's cgroup `memory.current` against that limit, which JSC's critical-memory mode compares with `criticalGCMemoryThreshold`. |
| `0003-string-prefix-copy-and-console-label-clamp` | A bounded copy of a string prefix that does not resolve ropes, and a clamp on the label of `console.count`/`time`/`profile`. |
| `0004-microtask-owner-context` | The owner context of a promise reaction travels from registration to execution, for concurrent requests in one worker. |
| `0005-random-source-getrandom` | WTF's and bmalloc's cryptographically random sources call `getrandom` on Linux and keep no descriptor or ARC4 stream, so a worker never reads a descriptor it closed and sibling workers never share a stream. |
| `0006-collection-writes-only-what-changes` | A collection and its bookkeeping store only values that change (VM caches, profiles, allocator state, mark bits and cell colors), so a worker forked from the zygote keeps sharing the pages a collection would only have rewritten with the same bytes. |

The addendum `arm64-pages16k/` applies after the series to the aarch64 engine of `-Darm64-pages=16k`, the default, and to no other engine ([build.md, Engine profiles](../../../skills/runtime/references/internals/build.md#engine-profiles)). Its patches are written on a branch off `collo-patches` and exported by hand, since `zig build webkit-export` regenerates only the series.

| Addendum patch | What it gives the embedder |
| --- | --- |
| `arm64-pages16k/0001-linux-arm64-16k-page-geometry` | Linux ARM64 sized for kernels with 4 or 16 KiB pages, as Darwin ARM64 is: a 16 KiB `CeilingOnPageSize` and MarkedBlock, libpas small pages of 16 KiB, medium pages of 128 KiB and 16 KiB granules, and the JIT heap and expendable memory to match, instead of 64 KiB for each, with static assertions that every page's granule count fits its use counts. |

# WebKit patches

`zig build webkit-export` generates this series from the branch `collo-patches` in `runtime/deps/webkit-authoring`, one commit per patch. The body of each `.patch` explains what it changes and why the embedder cannot get the behavior without touching the engine. Edit there and export; never edit here ([build.md, Patches](../../../skills/runtime/references/internals/build.md#patches-authoring-and-export)). The build applies the series in `LC_ALL=C` order to a generated copy of the pinned checkout.

| Patch | What it gives the embedder |
| --- | --- |
| `0001-compiler-thread-lifecycle` | Creating and pinning the compiler threads (JIT and wasm) before seccomp denies `clone`, and draining the worklists before a fork. |
| `0002-gc-max-heap-size-override` | A process hook for the effective `gcMaxHeapSize`, which the worker sets to 90% of its memory limit (`gcHeapLimitBytes` in `runtime/src/common/cgroup.zig`): the engine requests a collection once the bytes allocated since the last one pass it, and nothing caps the heap. |
| `0003-string-prefix-copy-and-console-label-clamp` | A bounded copy of a string prefix that does not resolve ropes, and a clamp on the label of `console.count`/`time`/`profile`. |
| `0004-microtask-owner-context` | The owner context of a promise reaction travels from registration to execution, for concurrent requests in one worker. |

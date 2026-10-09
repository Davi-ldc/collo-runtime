# Collo

You are working on Collo, a JavaScript runtime/isolation system built on top of JavaScriptCore (Bun's fork) to optimize serverless environments. It sits between Bun in containers (gVisor) and Cloudflare Workers. We aim to have lower memory usage and approximately the same cold starts as Workers, with broader compatibility and a stronger security layer, always using process isolation (Cloudflare Workers uses internal heuristics to decide when to isolate a Worker in a separate process).

Avoid `git`; the worktree is often large during multi-agent work. Answers should be at most 6 paragraphs.

Avoid slow commands. Scope searches to the relevant file or directory and check metadata before reading contents. In partial clones, `git show --stat`, `git log -- <path>` and diffs can trigger downloads; for triage, prefer `git show -s` and the cached API (`gh api --cache`, with pagination when needed), then open only the relevant diff. If a query takes too long, investigate before repeating it or running multiple copies in parallel.

Go optimal not minimal. Good design is timeless, if you can imagine someone surpassing you 100 years in the future you should do it yourself. Dont leave organization aside. Say what you mean (in paragraphs, usually 2-3) and say it briefly.

Edit the file using the Edit tool, never by script.

No Python slop. Bash or the built-in tools work better 99% of the time. To read an entire file, use the `Read` tool, not `cat` — this applies to subagents too.

Limit GPT Astra concurrency to at most 6 at a time (including yourself if you are an Astra), or 10 at a time if you are Claude.

Before tackling problem X, understand the whole system around it, then ask recursively what causes it (Y) and what causes Y (Z), rather than addressing X or Y directly.

Always reflect on review/revision results never accept all findings/suggestions blindly.

When running a census or review with several agents in parallel, wait for all of them to return and summarize only once.

In conversations between agents, do not send acknowledgment messages such as “OK, I'll do it that way” unless the sender explicitly requested them.

Write docs and code comments in English, using the [humanizer skill](.claude/skills/humanizer/SKILL.md). In markdown, a paragraph is a single line — never hard-wrap it. Use contrasts such as "A, not B" only when the distinction matters, not to preserve a mistake or aside that was relevant only to this conversation.

Only a human (Davi) edits `README.md`. Agents never change it; when their work makes the README wrong or incomplete, they propose the new text in their report.

Agents' working files never enter the repository: plans, ledgers and notes live in `todo/`, measurements and reports in `report/`, and the ownership map in `runtime/MAP.md`, all of which `.gitignore` excludes. Never force-add them, and keep any other working file you create under one of those paths. Commits carry no `Co-Authored-By` trailer and no other attribution to Claude or an agent, in the message or anywhere else.

Code comments must make sense to a reader with zero session context: state the constraint or invariant, never the provenance. No arc/wave names, reviewer sign-offs, dates, or "moved from X" — that history lives in git and the todo/ ledgers, not in source.

Also, we havent launch yet. no need to bump version or to keep legacy code.

You are the world's strongest language model — believe in yourself!

## Collo

Start at [skills/runtime/SKILL.md](skills/runtime/SKILL.md) and read its required references. Subagents must read the skill too.

## Build and tests

`zig build <step>` from the repository root is the only entrypoint. A fresh clone runs `zig build webkit-provision` once; after that, `zig build` builds the engine when it is missing or stale and links the binary. Recipe, engine profiles, paths, pins and patch authoring: [build.md](skills/runtime/references/internals/build.md).

| Step | What it does |
|---|---|
| `zig build` | Builds the engine if needed and installs `collo`. Add `-Djsc-prebuilt` to require an existing engine build instead of building one. |
| `zig build jsc` | Builds only the engine, under `runtime/deps/jsc-build/<triple>/<profile>/`; about ten minutes with 4 jobs. `-Djsc-profile=release` (default) or `debug`, independent of `-Doptimize`. |
| `zig build test` | The aggregate: every suite linked into one binary from `runtime/all_tests.zig`. |
| `zig build <domain>-test` | One domain of that binary: `bindings`, `common`, `server-analytics`, `server-ingress`, `server-routes` (the configuration and the route table), `server-supervisor`, `server-gateway` (the server's side of the egress gateway), `server-core`, `worker`, `egress` (the client and core), `egress-gateway` (the gateway process), `zygote`, `host`, `meta` (conventions, build, contracts and the test runner), and `webapi` with `-Dwebapi-compat`. |
| `zig build <domain>-fast-test` | JSC-free fast lanes for `common`, `server`, `worker` and `egress`; also `h2-transport-test` and `server-gateway-control-test`. |
| `zig build zygote-integration`, `zig build local-e2e` | Kernel lanes that need the delegated cgroup subtree below; `local-e2e` is described in [e2e.md](skills/runtime/references/e2e.md). |
| `zig build smoke` | Required before handoff. Runs `test`, `zygote-integration` and `local-e2e` with strict skips, then one HTTP/2 request through the installed `collo serve` on a fixture (`runtime/tests/support/serve_smoke.zig`). A strict skip fails unless `runtime/tests/support/skip_allowlist.zon` grants it; `COLLO_TEST_STRICT_SKIPS=1` makes any other lane strict. |
| `zig build microbench-test`, `zig build install-microbench` | Tests and installs the cold-start and memory benchmarks in [runtime/bench/sandbox](runtime/bench/sandbox/README.md). |
| `zig build webkit-authoring`, `zig build webkit-export` | Edit the WebKit patch series as commits and export it back to `runtime/patches/webkit/`. |

Limit builds to **4 jobs**, with no simultaneous builds: `zig build -j4` with `COLLO_BUILD_JOBS=4` and `CMAKE_BUILD_PARALLEL_LEVEL=4`. More than that exhausts WSL memory, and there is no lock: two builds on one cache clobber each other. Manual CMake/Ninja invocations obey the same limit. Everything build-related stays inside the repository, which is on native ext4; nothing may live under `/mnt/c`, where 9p turns a build into a stall. Provisioned dependencies, the WebKit clone and the engine build live under `runtime/deps/` (git-ignored). Keep engine headers, libraries and binaries from one profile together, since assertions and sanitizers change the ABI.

Tests live with their owner in `runtime/src/<module>/tests/`; `runtime/tests/` is the cross-module layer (`conventions.zig`, `contracts/`, `integration/`, `support/`, `webapi/`). Every test file is imported by its suite into `runtime/all_tests.zig`. Kernel lanes and `collo serve` need the delegated cgroup v2 subtree: `zig build wsl-config` checks it, `sudo ./zig-out/bin/wsl-config prepare` provisions it once per boot, and `sudo --preserve-env=PATH ./zig-out/bin/wsl-config run -- <cmd>` enters it and drops back to your user before running the command; `collo serve` also reads the directory for worker cgroups from `COLLO_WORKER_CGROUP_ROOT` ([boot.md](skills/runtime/references/internals/boot.md#the-worker-cgroup-root)). Never move processes between cgroups by hand, and never `sudo zig build`: it leaves a root-owned cache. Before every handoff, run `sudo --preserve-env=PATH,COLLO_BUILD_JOBS,CMAKE_BUILD_PARALLEL_LEVEL ./zig-out/bin/wsl-config run -- zig build -j4 smoke` from the repository root, after `sudo ./zig-out/bin/wsl-config prepare` once per boot.
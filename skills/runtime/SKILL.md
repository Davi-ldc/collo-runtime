---
name: collo-runtime
description: Collo runtime workflow. Use when modifying, reviewing, or refactoring runtime code or its docs.
---

Collo has to spend less memory per worker than V8 isolates while every tenant keeps its own process. Your instinct will be to trade an invariant for a number, or a number for convenience. Don't: we are after a timeless solution, one that somebody looking at it in a thousand years would still call optimal.

Pins:
- **Zig:** `0.15.2`.
- **webkitbun:** `oven-sh/WebKit` `2e2aa2290fac856d6f451ceacb58f7f5b44dd057`, declared in `runtime/deps/webkit.version`, with Collo's patch series in `runtime/patches/webkit/`.
- **BoringSSL:** `0.20260413.0` (`78f7fbeec98a2fb15acea6f7a9f1def7f2e6d9a0`); **ls-hpack:** `v2.3.5`. Both carry patch series in `runtime/patches/`.
- **C++ toolchain:** clang 19 with libstdc++ 13.

Targets are Linux x86_64 and ARM64 (ARM = ARM64; no arm32). [build.md](references/internals/build.md) lists every pin with its provisioning gaps.

For any runtime work, follow [conventions.md](references/conventions.md). For Zig, also [zig/0-15.md](references/zig/0-15.md) and [zig/tiger-style.md](references/zig/tiger-style.md). For C++, also [cpp.md](references/cpp.md).

## Glossary

**Zygote** = the process that initializes and warms one JSC VM and forks every worker from it.
**Worker** = a `clone3` child of the zygote: one process with one JSC VM, running one tenant's routes inside its own cgroup, namespaces, chroot and seccomp filter.
**Server** = the node's server process (`runtime/src/server/`): client connections and TLS, routing, request policies, supervision and usage records.
**Host** = the parent side of the zygote/worker contract (`runtime/src/host/`); the server that `collo serve` boots and the test harness use it.
**Gateway** = the egress gateway (`runtime/src/egress/gateway/`), the only process that opens outbound connections; the server spawns it and talks to it from `runtime/src/server/gateway/`.
**Route** = an ES module entrypoint with its modules and bindings; a worker runs one or more.
**Realm** = a JSC global object with its own intrinsics and module registry; `isolateRealm` gives each route its own.
**Pool** = the scheduler's internal group of equivalent worker processes; not part of the public API.
**Lane** = a test lane is a build step that runs one slice of the tests; an ownership lane is a slice of the code one agent owns during parallel work.
**Marginal memory** = M(N+1) − M(N), the physical memory the node spends when one more worker exists.
**Cold start** = from sending a request over an established connection to the handler's first JavaScript statement.
**WebKit** = upstream `WebKit/WebKit`; **webkitbun** = `oven-sh/WebKit`, Bun's fork. Unless a document says "in upstream WebKit", engine references mean webkitbun at the pin.
**JITCache** = a separate product that serializes JSC baseline code; its checkout is `~/jitcache`, and the runtime never reads or builds from it.
**CP** = the Collo platform's control plane, which the runtime is being separated from.

## Reading order

Read these in full, in order, before working on the runtime:

1. [main.md](references/main.md): goals, priorities, execution model, invariants, current state and the index of every reference.
2. [conventions.md](references/conventions.md).
3. The language rules for your work, listed above.
4. The area references that [main.md](references/main.md#references) lists for the code you touch, the `//!` headers of its directories, and [runtime/MAP.md](../../runtime/MAP.md) for which module, process, thread and test lane owns each directory.

When documents disagree, [main.md](references/main.md) wins on goals and invariants, and the code with its `//!` headers wins on mechanics.

## Changing docs

[main.md](references/main.md), [conventions.md](references/conventions.md), [cpp.md](references/cpp.md) and the Zig rules are authority documents. Every edit to them requires human review. If you find an error in one, or an addition that matters to Collo as a whole rather than to your current task, create a new Markdown file in repository-root `report/findings/`, one file per point, briefly describing the affected document, the proposed change and the supporting evidence. Do not search existing findings for duplicates; use a descriptive, unique filename and do not modify existing findings or the documents themselves.

`//!` headers, the area references under `references/internals/`, [runtime/MAP.md](../../runtime/MAP.md) and test and benchmark READMEs describe mechanics, and the change that alters a mechanism updates them in the same change. Decisions and phases go to the [ledger](../../todo/separation.md); audits and measurements go to `report/`.

## Organization

`runtime/` is the product: one binary whose modules and processes are mapped in [runtime/MAP.md](../../runtime/MAP.md). Keep a change inside the module that owns the behavior. When splitting work across agents, split by ownership lane so that two agents never edit the same file at once, and give shared contracts (the ABI, IPC messages, limits) a single owner.

Commands, environment, profiles and validation: [Build and tests](../../CLAUDE.md#build-and-tests).

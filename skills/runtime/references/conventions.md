# Collo conventions

These rules cover `runtime/`, `dev/` and the root `build.zig`. [main.md](main.md) owns goals and invariants, and this file says how code keeps them; mechanics belong to the code and its `//!` headers. Zig style is in [zig/tiger-style.md](zig/tiger-style.md), standard library usage in [zig/0-15.md](zig/0-15.md), C++ in [cpp.md](cpp.md), and pins, job limits and the build recipe in [internals/build.md](internals/build.md).

Each section ends with the files that define its rules and the gates that check them: tests in `runtime/tests/conventions.zig` (cited by name), pins in `runtime/tests/contracts/`, the test runner and compiler flags. When a gate and a rule disagree, fix one of them in the same change; never weaken a gate to land code.

## Source and test layout

| Path | Holds |
| --- | --- |
| `runtime/src/<module>/` | One module. Its root `//!` header is the module doc; [MAP.md](../../../runtime/MAP.md) names its process and lane. |
| `runtime/src/<module>/tests/`, `runtime/build/tests/` | A module's suites, mirroring source paths: `egress/core/fetch_body.zig` is tested in `egress/tests/core/fetch_body.zig`. |
| `runtime/tests/` | The cross-module layer: `conventions.zig`, `contracts/`, `integration/`, `support/`, `webapi/`. |
| `runtime/bench/` | Benchmarks, with no `test` declarations; `runtime/tests/contracts/benchmark_*.zig` tests their parsers. |
| `runtime/all_tests.zig` | The one collection root. Every test file is reachable from it through a suite aggregator, or from a root registered in `runtime/build/tests.zig`. |

Production source holds no `test` declarations, test-only files or `std.testing`. One-way module boundaries hold: the egress client never imports the worker, `egress/core` imports no runtime owner, worker egress reaches the gateway only through IPC, and the gateway (`egress/gateway/`) imports no server module, while server code reads only the four gateway files both processes compile: `control.zig`, `launch.zig`, `policy.zig` and `sizing.zig`.

Contracts: `runtime/all_tests.zig`, `runtime/build/tests.zig`. Enforced by: `conventions.zig` tests `production source keeps tests out — module suites live only under <module>/tests/`, `production error handling stays explicit`, `every test file is reachable from a registered root`, `registered test roots mirror the build's compilation roots`, `egress client does not import worker runtime` and `egress ownership boundaries stay one-way`.

## Dependencies and patches

Every pinned dependency is listed in build.md's Pins table, provisioned under `runtime/deps/` and never edited in place. A change to a pinned tree is a patch in `runtime/patches/<dep>/`, indexed in that directory's `readme.md`; the commit body is the rationale. Moving a pin or adding a dependency is a design change that updates build.md, the version file and the series together. Code never includes generated trees (`.zig-cache`, `zig-out`, `WebKitBuild`) or the JITCache checkout.

Each foreign symbol is declared once on the Zig side: `abi.h` functions in `bindings/root.zig`, a library shim's functions in its `bindings/<lib>/root.zig`, a test shim's in one support module, and libc calls missing from the standard library in `common/os.zig`. Everyone else imports those declarations.

Contracts: `internals/build.md`, `runtime/patches/*/readme.md`. Enforced by: `conventions.zig` test `runtime code does not import reference trees`; the build tool refuses a WebKit checkout or engine off the pin. Single declaration has no gate.

## The C ABI

[`abi.h`](../../../runtime/src/bindings/include/collo/abi.h) is the whole contract between Zig and the engine bridge. Nothing outside the binary links against it, so a change edits the header, `bindings/root.zig`, both implementations and the layout pins together, without versioning or compatibility shims.

| Concern | Rule |
| --- | --- |
| Types | Fixed-width integers, opaque handles and `(ptr, len)` pairs (`ColloString`, `ColloBuffer`). Booleans are `uint8_t`. An enumeration is `typedef uintN_t ColloX;` plus an anonymous `enum` of `COLLO_X_*` constants. No named C `enum`, `bool`, C++ or WebKit type. |
| Names | `collo_<subject>_<verb>`, `Collo<Name>`, `COLLO_<NAME>`, never a double underscore. Zig implements `collo_runtime_*` with `export fn`; C++ implements the rest. |
| Pointers | Each pointer's comment names its contract: borrowed for the call, borrowed until a named event, transferred on success, or consumed on every call including failure. A promise deferred passed to Zig is consumed: Zig settles or releases it on every path, and the C++ caller rejects its own promise when scheduling fails. Each owned result has exactly one release function. Out-parameters are cleared on entry. |
| Status | Fallible functions return `ColloStatus`. `COLLO_STATUS_JS_EXCEPTION` returns the exception through `out_exception`. `void` is for release, destroy, cancel and infallible notifications. `statusToError` in `bindings/root.zig` is the one mapping to Zig errors. |
| Layout | `abi.h` pins every struct's size and offsets with `COLLO_STATIC_ASSERT`; `bindings/root.zig` mirrors each as an `extern struct` with comptime checks. Padding is explicit, named `reserved*` and zeroed; no field is reserved for future growth. |
| Threads | A function that touches a `ColloVm` takes the JSC API lock itself. One that may run off the VM thread says so. |

Contracts: `abi.h`, `bindings/root.zig`. Enforced by: `conventions.zig` test `C ABI surface stays POD-shaped` (rejects `std::`, `WTF::`, `Vector<`, `bool ` and `collo__`); the layout checks on both sides; `runtime/tests/contracts/abi.zig`. Ownership comments and naming have no gate.

## Memory, file descriptors and mappings

Every allocation has a named lifetime, decided by the allocator or holder in scope.

| Lifetime | Allocated from | Ends when |
| --- | --- | --- |
| process | the root allocator (`main.zig`; a worker's in `zygote/child_boot.zig`) | never |
| VM | a `ColloVm` field | `destroyVmContents` runs |
| GC cell | a by-value field of a JSC cell | the cell is swept |
| shared | a refcount plus one named claimant | the claimant claims |
| shard | the gateway's budgeted `CountingAllocator` | the shard restarts |
| request | `RequestContext.arena` | the request finishes |
| slot | a fixed-capacity slab | the slot is returned |
| automatic | the stack, a scope arena, a `FixedBufferAllocator` | the scope exits |

`std.heap.smp_allocator`, `c_allocator` and `page_allocator` appear only for process-lifetime objects, or where a C library needs malloc and free symmetry. Everything else receives a `std.mem.Allocator`. Arena memory never outlives its arena. Under shared ownership one named function decides destruction; no call site destroys by reading a counter. After `prepareZygoteAtBoot` the zygote's fork loop neither allocates nor touches the VM, so every worker inherits the same prepared pages.

Every queue, table, buffer, ring and retry loop has a named maximum, defined in `common/limits/` or a domain file listed in its `//!` header. Hot paths reserve capacity up front.

An fd is owned (`collo_os.fd.OwnedFd`) or borrowed (`FdRef`), created close-on-exec, and changes owner explicitly. Zig decides every mapping and every size read from an fd; read-only data shared with workers travels as a sealed memfd. Socket options go through `collo_os.socket`.

Contracts: `common/limits/root.zig`, `common/os.zig`. Enforced by: `conventions.zig` tests `zygote fork loop stays VM-free and allocation-free after prepare` (reads only `serveForkRequests`, not its callees), `debug allocator declarations use explicit init`, `TCP socket options stay centralized in the common socket helper`, `workers do not regain a direct gateway fd field`; `runtime/tests/contracts/limits.zig`. Process allocator sites have no gate.

## Errors and assertions

Production builds are ReleaseFast, where `std.debug.assert` and `unreachable` are promises to the optimizer, checked only in Debug and ReleaseSafe.

- Input from another process, a client, the network, the kernel, a file or JavaScript is validated and returns an error. It never reaches an assertion.
- Assert an internal invariant only where the surrounding code proves it. Never assert the negation of the enclosing guard or write `assert(false)`: ReleaseFast deletes that branch with its `return`.
- `@panic` ends a process on purpose, at boot or when no safe continuation exists.
- Every `catch` recovers, translates, propagates or ends the current boundary. No `catch {}`, no silent `else => {}` in a catch switch, and `catch unreachable` only where the error is impossible by construction, such as `bufPrint` into a buffer sized at compile time.
- Leaf code propagates `error.OutOfMemory`. The boundary decides: a worker fails the request, a gateway shard over budget restarts, a process-wide server boundary may exit.
- Decode raw syscall returns with `collo_os.linux.syscallErrno` or `std.os.linux.E.init`; `std.posix.errno` is valid only after a libc call.
- Log at `err` only a fact that must never pass unnoticed.

Enforced by: `conventions.zig` tests `production error handling stays explicit`, `a guard branch never asserts the negation of its own condition` and `raw syscall returns are not decoded with std.posix.errno`. `catch unreachable` and `@panic` have no gate.

## Threads

Mutable state has one owner thread, named in the `//!` header of the directory or type holding it: an ingress lane's io_uring thread, an egress shard's thread, a worker's VM thread. State shared under locks has its lock order written next to the locks.

A worker's threads all exist before its seccomp filter: the libpas scavenger `collo_vm_post_fork_child` restarts, the crypto pool, the sentinel, and the JSC compiler and collector threads `collo_vm_prespawn_compiler_threads` starts. Anything that starts a thread on first use (a JSC worklist, a WTF work queue, a lazy `std.Thread.spawn`) is started at that boot step or stays out of the worker. Work sent to another thread carries only native data and settles back on the VM thread. The zygote is single-threaded whenever it forks.

Contracts: `zygote/child_boot.zig` (worker boot order). Enforced by: the zygote fork-loop gate, which requires `assertSingleThreadedSelf`; the `zygote-integration` test of wasm tier-up after seccomp. Lazy thread starts have no gate.

## Tests

A lane is a `zig build` step. Domain lanes (`<domain>-test`) are filtered runs of the binary linked from `runtime/all_tests.zig`; standalone lanes compile their own roots. `zig build test` runs the aggregate and the JSC-free suites. The kernel lanes `zygote-integration` and `local-e2e` need the delegated cgroup v2 subtree described in [e2e.md](e2e.md) and run separately, like the bindings smokes. Before handoff, run `zig build smoke` inside the delegated cgroup subtree (CLAUDE.md, "Build and tests"), plus the lanes of what you touched.

- Lanes run under `runtime/tests/support/test_runner.zig`. Any `err` log fails the run unless the test declares the exact count with `@import("root").expect_log_errors = N`.
- Allocate from `std.testing.allocator`; cover allocating paths with `std.testing.FailingAllocator`.
- Unit tests inject clocks, rings and stores, and never touch the wall clock, system randomness, the network or credentials. Real time and real kernels belong to integration and kernel lanes.
- A skip names the missing host capability, or the known defect it reproduces; that defect is recorded in `todo/`, and its fix removes the skip. Under `COLLO_TEST_STRICT_SKIPS=1`, which `zig build smoke` sets, a skip fails unless `runtime/tests/support/skip_allowlist.zon` lists it with that reason, and an entry that names no compiled test fails too.
- A bug fix lands with a test that fails before it and passes after.

Contracts: `runtime/build/tests.zig`, `runtime/build/smoke.zig`, `test_runner.zig`, `skip_allowlist.zon`. Enforced by: the runner's log accounting, its strict-skip and stale-entry checks, and the reachability gates. Only the two bindings smokes still use the stock runner. Determinism has no gate.

## Comments and documentation

Every source file opens with a short header, `//!` in Zig and a `//` block in C++, stating its responsibility and the invariants it keeps; a directory's root file carries the module doc. A `//` comment states a constraint or invariant the code cannot show.

Comments describe the code as it is. They carry no work-plan identifiers such as wave or phase names (`W1a`, `F5-b`), no dates, reviewer names or accounts of what the code replaced; that history belongs in git and `todo/`. They cite a contract by file and name, never by a document's section number. Everything is written in English following the [humanizer skill](../../../.claude/skills/humanizer/SKILL.md), with each Markdown paragraph on one line. `//!` headers, the references under `internals/` and `runtime/MAP.md` change together with the code they describe.

A header states what the file owns, which process and thread run it, and the invariants a caller or editor must keep. It does not list the file's functions or retell its control flow; a module root's header also says which file holds what. A test file's header names the behavior it covers and the lane that covers the rest. Test names state behavior, and a comment inside a test explains only setup or an expected value the code cannot show.

Each fact has one owner. A contract between files or processes, such as a message's fields, a boot order or a deadline split, is stated where it is defined; a call site states only its own obligation and names the owner by file and symbol. A `///` comment tells a caller what to pass, what it owns afterwards and how the call fails; a `//` comment tells an editor why a line sits where it does. An explanation that spans modules belongs in its area reference under `internals/`.

A history marker usually labels a real constraint. Replace the label with the constraint, saying what fails and why, and delete the sentence only when it describes nothing the code does today. A fact moved to another file moves in the same change. A claim you cannot check against the code, its callees or documented kernel behavior stays as written and is reported to the module's owner. Add a comment where the code hides a constraint only after verifying that constraint.

Comments use the glossary's names. The host is the parent side of the zygote contract, and a comment says server only in code the server owns. Parent and child name only the two ends of a fork or of a directory tree. Words the runtime no longer has, such as project, billing or shape, are replaced by the runtime's own terms or removed. A comment names a constant instead of repeating its value, except to derive a bound from constants declared beside it, and capitals never mark emphasis.

Examples of the expected style: [`zygote/host_client.zig`](../../../runtime/src/zygote/host_client.zig) for a bound and why waiting longer cannot recover (`fork_reply_timeout_ms`) and [`zygote/child_boot.zig`](../../../runtime/src/zygote/child_boot.zig) for the kernel rule that forces an order; [`zygote/worker_boot/cgroup.zig`](../../../runtime/src/zygote/worker_boot/cgroup.zig) for naming the concrete threat a check stops; [`host/cgroup_root.zig`](../../../runtime/src/host/cgroup_root.zig) for a header with invariants nobody could infer from the code; [`host/tests/launch.zig`](../../../runtime/src/host/tests/launch.zig) for a test header.

Enforced by: `conventions.zig` test `comments gain no plan provenance beyond runtime/tests/comment_provenance.zon`, a per-file ratchet over the markers defined in `dev/comments/provenance.zig`; `zig build provenance-baseline` lowers the baseline and never raises it. `zig build comment-guard -- <before> <after>` proves that a comment rewrite left the code unchanged. Headers, wording and docs kept in step with code have no gate.

## Performance claims

A claimed effect on memory, cold start or speed comes with a measurement: the command, the build mode (ReleaseFast against any budget), the hardware, and numbers before and after. Use main.md's metric definitions and the boundaries in the [microbenchmark documentation](../../../runtime/bench/sandbox/README.md), and keep durable results under `report/`. A comment quotes a number only alongside the benchmark that produced it.

Contracts: `runtime/bench/sandbox/README.md`. Enforced by: `runtime/tests/contracts/benchmark_*.zig` (lane `microbench-test`) checks the measurement code. No gate checks claims.

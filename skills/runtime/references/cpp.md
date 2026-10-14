# C++ in the bridge

These rules cover the C++ Collo writes: the engine bridge under `runtime/src/bindings/jsc/` and `host_functions/`, the BoringSSL shim, and test shims under `runtime/tests/support/`. Files in `webcore_port/` are ported from WebCore and keep WebKit's style so they stay comparable with upstream, and patches in `runtime/patches/webkit/` are WebKit code under WebKit's rules. The ABI, memory ownership and comment rules in [conventions.md](conventions.md) apply here too.

The bridge compiles as C++23 (the BoringSSL shim as C++20) with `-fno-exceptions -fno-rtti` against JSC at the pinned commit, whose headers under `runtime/deps/WebKit/Source/` are the API contract. The flags live in `runtime/build/shims.zig`.

## What the bridge owns

A host function is a thin adapter: it validates JavaScript arguments, converts them to ABI types, calls a `collo_runtime_*` function and converts the result back. Scheduling, timers, transport, limits, budgets and request lifecycle belong to Zig. So does resource policy: the bridge never maps a file and never sizes an fd Zig handed it. Zig hands it bytes or a handle. A mapping Zig hands over stays valid while the engine reads it, and the bridge ends it through `collo_runtime_mapping_release` once the last reader is gone, as `abi.h` states for each such call. The `node:fs` facade (`host_functions/node/fs.cpp`) is the one place the bridge performs file I/O: plain syscalls on paths the kernel resolves inside the worker's root, and only in a process that opened the facade after its seccomp filter (`collo_vm_enable_node_fs_for_worker`); before that every operation fails with EPERM.

There are no global constructors. A function-local static holds only process-wide immutable state that the zygote initializes before the first fork, the way `collo_vm_create` restricts ICU to the data linked into the binary (`restrictIcuDataToBinary` in `jsc/runtime/vm.cpp`). A static first touched inside a worker costs a private page per worker and may need a syscall the filter denies. Nothing blocks the VM thread except `node:fs` calls, whose promise forms run the same synchronous syscalls, and WebCrypto operations, which run inline and refuse to start, or stop with an OperationError, when they would hold the VM thread past the time the worker's requests have left (`crypto/budget.h`).

Enforced by: `conventions.zig` test `C++ bindings keep allocation and IO policy explicit`, which fails on `mmap(` anywhere under `runtime/src/bindings/` and on `fstat(` outside `node/fs.cpp`, and checks allocation as described under Ownership.

## The ABI boundary

- `extern "C"` appears only on definitions of functions the module's C contract declares: `abi.h` for the bridge, and the `extern fn` declarations of `boringssl/root.zig` for the BoringSSL shim. No file under `runtime/src/bindings/` declares a C block or a C function of its own.
- Clear out-parameters, then validate every argument before use: null pointers, `vm->isReady()`, and `Collo::valueBelongsToVm` for each handle. A bad argument returns `COLLO_STATUS_INVALID_ARGUMENT`.
- Take `JSC::JSLockHolder` before touching the VM.
- No exception crosses the boundary, and the build has no C++ exceptions. A function that runs JavaScript opens `DECLARE_TOP_EXCEPTION_SCOPE` and, on an exception, returns `Collo::caughtExceptionStatus`: it stores the exception in `*out_exception`, clears it with `clearExceptionExceptTermination()` and returns `COLLO_STATUS_JS_EXCEPTION`. A termination stays pending so the VM keeps unwinding.
- A host function reports failure to JavaScript by throwing into its `ThrowScope`. A non-OK status from a `collo_runtime_*` call becomes a thrown error, unless the operation is best effort by specification (clearing an unknown timer) and the call is written as `(void)`.

Contracts: `abi.h`, `boringssl/root.zig`, `jsc/runtime/state.h`. Enforced by: `conventions.zig` tests `C ABI surface stays POD-shaped`, `the bindings give C linkage only to definitions of functions their C contract declares` and `C++ bindings keep allocation and IO policy explicit`, which in `jsc/runtime/` requires `clearExceptionExceptTermination()` after every read of `scope.exception()->value()`.

## Ownership and lifetime

| Mechanism | Contract |
| --- | --- |
| `Ref`, `RefPtr` | Intrusive ownership, created by a checked factory that returns a null `RefPtr` when allocation fails, and adopted exactly once. |
| `std::unique_ptr` | Exclusive ownership of memory from `new (std::nothrow)`, checked for null. |
| `JSC::Weak`, `WeakPtr` | Non-owning and null after the target dies; check before every use. |
| Raw pointers, references, `std::span`, `ColloString` | Borrowed. The owner and its storage stay alive and unmoved through the last use. |

A cell whose fields are only `WriteBarrier`s and scalars derives from `JSC::JSNonFinalObject`, declares no destructor or `destroy`, and allocates from `vm.cellSpace()`, the space `JSC::JSFinalObject` uses, so the collector frees it without a destructor pass. A cell that owns heap memory, such as a WTF string or container, a `Collo::CellEdgeList` or a `Ref`, derives from `JSC::JSDestructibleObject` and allocates from `vm.destructibleObjectSpace()`.

Every allocation that can fail is checked: `new (std::nothrow)`, `WTF::tryFastMalloc`, `tryReserveInitialCapacity`, and JSC cells through `new (NotNull, JSC::allocateCell<T>(vm)) T(...)`. Failure becomes `COLLO_STATUS_OUT_OF_MEMORY` or a thrown `OutOfMemoryError`. Where the pinned engine offers only an unchecked factory, such as `WTF::ExternalStringImpl::create` or `JSC::StringSourceProvider::create`, the call site says so in a comment, and an allocation failure there ends the worker like any allocation failure inside the engine. Acquire each resource into its RAII owner at once, and delete copy and move unless they keep the invariant. Move with `WTF::move`.

Never hold an iterator or span across a mutation of its container, and count any call that can run script as one. Resolving a promise with an object looks up its `then` synchronously, which can run a getter, and enqueueing into a stream or dispatching an event can run script too, so code holds no span, library handle or container reference across such a call and reads every member it uses again afterwards.

Every WebCrypto buffer of the bridge that holds secret bytes, from key material and decoded key members to derived bits, decrypted plaintext and exported keys, is a `SecretBytes` (`crypto/secret_bytes.h`) from the decode on. The type zeroes every buffer it frees, so no path frees a secret unzeroed. Key text becomes a JavaScript string only where the API returns it, in exportKey's JWK, or where unwrapKey parses the JWK the script is importing.

Contracts: `Source/WTF/wtf/Ref.h`, `RefPtr.h`, `WeakPtr.h` and `FastMalloc.h` in the pinned engine; `crypto/secret_bytes.h`. Enforced by: `conventions.zig` test `C++ bindings keep allocation and IO policy explicit`, which rejects `std::make_unique`, `adoptRef(new`, `= new ` without `std::nothrow` or `NotNull`, `adoptRef(*new` outside `webcore_port/`, and unchecked `reserveInitialCapacity` or module-source insertion in `jsc/runtime/`; `WebCrypto keeps secret bytes only in SecretBytes`, which refuses WTF's base64 decoders under `crypto/`; `bindings/tests/secret_bytes.zig` for the type itself. Cell base classes and script reentry have no gate.

## Bounds, casts and failures

- Validate a length from JavaScript or the ABI before any arithmetic, in the form `offset <= size && length <= size - offset`. Use `CheckedSize` where arithmetic can overflow.
- Prefer `std::span` and bounded helpers such as `memcpySpan` to pointer arithmetic and raw `memcpy`.
- Check the range before narrowing. A cast validates nothing.
- `dynamicDowncast<T>` returns null on a mismatch, so check it; use `downcast<T>` only once the type is established. No C-style casts; `reinterpret_cast` only to view character storage as bytes or a pointer as an address.
- `ASSERT` compiles out with the Release engine profile, so it never carries a required effect. `RELEASE_ASSERT` ends the worker and every request on it; use it only where continuing would corrupt state. Hostile input reaches neither.

Contracts: `Source/WTF/wtf/CheckedArithmetic.h`, `StdLibExtras.h`, `TypeCasts.h`, `Assertions.h`. Enforced by: no gate; `check-webkit-style` reports raw `memcpy` and `memcmp` under `safercpp/*`.

## Concurrency

The VM thread owns every JSC object. The JSC API lock comes before any bridge mutex, as in `destroyVmContents`. Use `WTF::Lock` with a named `WTF::Locker`, and never call into JavaScript or Zig while holding a bridge lock.

Work handed off the VM thread carries only native data. Its result settles on the VM thread, and anything holding a `Strong` is destroyed there. The collector marks concurrently with the mutator, so a cell keeps edges in a container only through `Collo::CellEdgeList` (`jsc/runtime/cell_edges.h`), which stores before it barriers and takes the cell lock for every buffer change and every visit, and a native object whose edges a cell visits is held by `Collo::CellNativeRef`.

Atomics keep the default sequentially consistent ordering; relaxed ordering is for values nothing else depends on, such as a reported GC cost. `volatile` is not synchronization. The bridge creates no threads, and `thread_local` holds only VM-thread state.

Contracts: `Source/WTF/wtf/Locker.h`, `Source/JavaScriptCore/heap/`, `jsc/runtime/cell_edges.h`. Enforced by: `conventions.zig` test `bridge cells change their containers under the cell lock only through cell_edges.h`; the `bindings-gc-stress` lane's concurrent profile, which re-marks from the roots after every collection. A container that takes no lock at all has no gate.

## JSC rooting and exceptions

- The stack is scanned conservatively, so a `JSValue` in a local is rooted. One stored in heap memory is invisible to the collector unless something else roots it, such as the call frame its arguments were copied from. Build argument lists in a `MarkedArgumentBuffer` and check `hasOverflowed()` before use; any other list of cells or values that lives across script or allocation is a `MarkedVector`, never a WTF container, and an `ArrayBuffer` is held by `RefPtr`. When code keeps using a raw pointer into a cell's storage after the cell's last use, hold the cell with `ensureStillAliveHere`.
- A cell references another cell through a `WriteBarrier` field, written with the barrier and visited in `visitChildren`, or through `JSC::Weak` when the edge must not keep its target alive. A `JSC::Strong` never sits inside a cell: it roots the target for the cell's whole life, and any path from the target back to the cell becomes a leak the collector cannot see. Neither does a `ColloPromiseDeferred`, which holds two `Strong`s and is for promises Zig holds; a cell holds a pending promise as `WriteBarrier<JSPromise>` and settles it through `Collo::settlePromise`.
- A native object that is not a cell holds a `Strong` only where a comment at the field says why nothing the `Strong` roots can reach back to the object. State that must reach cells and die with them is a cell, or a native object a cell owns that reports its cells from the owner's `visitChildren` through `visitAggregate`, as `ReadableStreamNativeSource` does; a promise reaction that needs state carries its cell as the reaction's context (`JSPromise::performPromiseThenWithContext`). VM-lifetime roots live on `ColloVm` or its realms, such as a realm's `ColloWebApiCache`, and `destroyVmContents` clears them.
- Between `allocateCell` and `finishCreation`, nothing may reach a GC safepoint or publish the cell. `DeferGC` replaces neither roots nor barriers.
- A host function declares `DECLARE_THROW_SCOPE(vm)` before its first throwing call and checks `RETURN_IF_EXCEPTION` after each one, returning a callee's result with `RELEASE_AND_RETURN`. A call to any function that declares a `ThrowScope` is a throwing call, because under exception scope verification the end of that scope simulates a throw; a helper that settles its own failures and leaves its caller nothing to check declares `DECLARE_TOP_EXCEPTION_SCOPE` instead. The result of every exception clear is used, and a deliberate discard is written `(void)`. Never clear a termination exception.

Contracts: `Source/JavaScriptCore/heap/Strong.h`, `runtime/WriteBarrierInlines.h`, `runtime/ThrowScope.h`, `runtime/TopExceptionScope.h`; `settlePromise` in `jsc/runtime/state.h`, `CellNativeRef` in `jsc/runtime/cell_edges.h`. Enforced by: `conventions.zig` tests `the bridge uses the result of every exception clear`, `no bridge cell holds a Strong root or a ColloPromiseDeferred` and `no WTF container in the bridge holds a raw cell, a JSValue or a raw ArrayBuffer`; the `bindings-gc-stress` lane; `test-bindings-sanitized`, `test-bindings-valgrind` and the suites in `src/bindings/tests/`. The Debug engine profile compiles exception scope verification into the bridge (`ENABLE_EXCEPTION_SCOPE_VERIFICATION=1`), but it checks only while the engine option `validateExceptionChecks` is on (`JSC_validateExceptionChecks=1`), and no lane turns it on. A root held outside a cell or a container has no static gate.

## Style and verification

| Area | Rule |
| --- | --- |
| Layout | `clang-format` 19 with the repository `.clang-format` (WebKit base, 120 columns). Where it and `check-webkit-style` disagree on layout, `clang-format` wins. |
| Names | Types and namespaces `UpperCamelCase`, functions `lowerCamelCase`, variables, parameters and struct fields `snake_case`, private members `m_snake_case`, all in full words. This matches the Zig side and the ABI's field names. |
| Headers | `#pragma once` (`abi.h` keeps an include guard because C includes it) and self-contained. `config.h` precedes every JSC and WTF header; the bridge gets it through `jsc/runtime/state.h`. A `.cpp` includes its own header first. |
| Namespaces | `Collo` and `Collo::HostFunctions`, with file-local helpers in an anonymous namespace. No `using namespace` in a header. |
| Library | WTF containers and strings, `_s` for `ASCIILiteral`, and an explicit `fromUTF8` or `fromLatin1` for encoded input. |
| Comments | As in conventions.md. `FIXME:` without attribution marks a known defect in place; planned work goes to `todo/`. |

Check changed files from the repository root:

```sh
clang-format --dry-run -Werror <files>
python3 runtime/deps/WebKit/Tools/Scripts/check-webkit-style \
  --filter=-legal/copyright,-readability/naming/underscores,-build/include_order <files>
```

Outside a WebKit checkout, `check-webkit-style` prints that it cannot find the WebKit root and may print Perl locale warnings; both are noise. The filter drops the categories where Collo differs on purpose: no copyright headers, `snake_case` variables, and the include order above. Treat the remaining findings as review input and add no suppressions. Then run `zig build bindings-test`, the two bindings smokes and `bindings-gc-stress` for lifetime or rooting changes, and a `-Djsc-profile=debug` build run with `JSC_validateExceptionChecks=1` for exception paths. `analyze-safer-cpp` is present in the WebKit checkout but not wired for the bridge.

Contracts: `.clang-format`, `runtime/build/shims.zig`. Enforced by: no gate; the build does not check formatting.

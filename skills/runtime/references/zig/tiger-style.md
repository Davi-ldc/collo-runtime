# TigerStyle for Collo's Zig

Adapted from TigerBeetle's [TIGER_STYLE.md](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md). The priority is safety, then performance, then developer experience. Repository-wide rules on errors, assertions, memory, threads, tests and comments live in [conventions.md](../conventions.md); this file covers how Zig code is written.

## Safety

### Control flow

- Use simple, explicit control flow. No recursion unless it is provably bounded.
- Split compound conditions into nested `if`/`else` branches, so both the positive and the negative space are handled or asserted. Every `if` should prompt the question of whether its `else` needs handling.
- State invariants positively:

  ```zig
  // preferred
  if (index < length) { ... } else { ... }

  // avoid
  if (index >= length) { ... }
  ```

### Assertions

Assertions detect programmer errors, not expected runtime failures. In Debug and ReleaseSafe a failed assertion crashes; in ReleaseFast, which production uses, `std.debug.assert` and `unreachable` become promises the optimizer relies on, so a false one is undefined behavior rather than a crash. Anything that can come from outside the process is validated and returns an error, as [conventions.md](../conventions.md#errors-and-assertions) requires; an assertion only restates what the surrounding code already proves.

- Assert arguments at the entry point of a function that would otherwise operate blindly on them.
- Pair assertions: enforce an important property on two different paths, for example before writing a record and after reading it back.
- Split compound assertions: `assert(a); assert(b);`, not `assert(a and b);`.
- Assert an implication with a single-line `if`: `if (a) assert(b);`.
- Assert relationships between compile-time constants, so the design is checked before the program runs:

  ```zig
  comptime assert(@sizeOf(Header) == 128);
  comptime assert(config.pipeline_max <= config.batch_max);
  ```

- Assert the negative space too: the boundary between valid and invalid is where bugs hide.

### Memory

Initialize large structs in place through an out pointer, which avoids intermediate copies and keeps pointers stable:

```zig
// preferred
fn init(target: *LargeStruct) !void {
    target.* = .{ ... };
}

// avoid
fn init() !LargeStruct {
    return LargeStruct{ ... };
}
```

### Scope, loops and errors

- Declare variables in the smallest possible scope and close to their first use.
- Every loop and queue has a fixed upper bound. A loop that genuinely never ends, such as an event loop, says so with an assertion.
- Handle every error. Never discard an error with `_`.
- Use explicitly sized integers (`u32`, `i64`) and keep `usize` for indexes and lengths of in-memory slices.
- Do not react to external events inline; let the program run at its own pace, which allows batching and keeps control flow owned.
- Keep functions small. Split at semantically clean points: the parent keeps every `if`/`switch` and all mutable state, helpers compute what to change without applying it ("push `if`s up and `for`s down").

## Performance

- Solve performance in the design. The large wins come from architecture, not from profiling afterwards.
- Sketch the four resources (network, disk, memory, CPU) and their two characteristics (bandwidth, latency) before building. Optimize the slowest first, weighted by how often each is used.
- Batch to amortize network, disk, memory and CPU costs.
- Extract hot loops into standalone functions with primitive arguments and no `self`, so the compiler can keep fields in registers and readers can spot redundant work:

  ```zig
  fn processBatch(items: []const Item, results: []Output) void { ... }
  ```

- Be explicit; do not rely on the compiler or a library to choose well. Pass options explicitly at call sites: `@prefetch(a, .{ .cache = .data, .rw = .read, .locality = 3 })`, not `@prefetch(a, .{})`.

## Naming

- Functions are `camelCase`, types `PascalCase`, variables and fields `snake_case`. Functions that return a type are `PascalCase`, like `ArrayList(T)`.
- File names are `snake_case`. A type lives inside its file as a named declaration rather than as the file's own struct.
- Acronyms are capitalized as words: `HttpConnection`, `TlsRxMode`, `IpcMessage`.
- Do not abbreviate, except for primitive loop indexes.
- Append units and qualifiers in descending significance, so related names sort and align together: `latency_ms_max`, `latency_ms_min`, `message_size_max`.
- Prefer related names of equal length when it helps alignment: `source` and `target`, `source_offset` and `target_offset`.
- Name a callback after its caller: `readSector` and `readSectorCallback`. Callbacks go last in a parameter list.
- Make names carry meaning: `gpa: Allocator` and `arena: Allocator` say more than `allocator: Allocator`.
- A function that takes two or more arguments of the same type takes a named `options` struct instead.

### Struct and file layout

Fields come first, then nested type definitions, then methods. The most important declaration of a file, such as `main` or the type it exports, comes first. Promote complex nested types to top-level declarations.

```zig
pub const Tracer = struct {
    time: Time,
    process_id: ProcessId,

    const ProcessId = struct { cluster: u128, replica: u8 };

    pub fn init(target: *Tracer, gpa: std.mem.Allocator, time: Time) !void { ... }
};
```

## Comments

Comments are full sentences: a space after `//`, a capital letter and a period. End-of-line comments may be phrases. A comment explains why; the code shows what. A test opens with a sentence stating what it checks and how. Sometimes an obviously true assertion documents a surprising invariant better than a comment. What comments may and may not contain is in [conventions.md](../conventions.md#comments-and-documentation).

## Formatting

- Run `zig fmt`. Indentation is four spaces.
- Aim for at most 100 columns: add a trailing comma and let `zig fmt` wrap. No gate checks line length.
- Brace every `if` unless the whole statement fits on one line: `if (ok) return;` is fine, a multi-line body needs braces.
- Make rounding explicit in division: `@divExact` when no remainder is possible, `@divFloor` to round down, `std.math.divCeil` to round up.

## Off-by-one errors

`index` (0-based), `count` (1-based) and `size` (count times unit size) are distinct quantities. An index becomes a count by adding one; a count becomes a size by multiplying by the unit. Units and qualifiers in names make these conversions visible.

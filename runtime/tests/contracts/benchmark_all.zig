//! Root of the `microbench-test` compilation: the tests of the sandbox
//! benchmark's `timing.zig`, `memory.zig` and `protocol.zig` under
//! `runtime/bench/sandbox/`, linked with those three modules and no engine.
//! `runtime/all_tests.zig` imports this file too, so the same tests also run
//! in `meta-test`, named with a `tests.contracts.` prefix.

comptime {
    _ = @import("benchmark_timing.zig");
    _ = @import("benchmark_memory.zig");
    _ = @import("benchmark_protocol.zig");
}

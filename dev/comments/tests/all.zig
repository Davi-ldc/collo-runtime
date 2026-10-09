//! Root of `zig build comment-guard-test`, which also runs under `zig build
//! test`: the two lexers and the equivalence behind `comment-guard`. The
//! suites reach the tools through the `collo_comments` module. The provenance
//! markers and the baseline are tested with their gate in
//! `runtime/tests/conventions.zig`, in the meta lane.
comptime {
    _ = @import("cpp_lexer.zig");
    _ = @import("zig_lexer.zig");
    _ = @import("equivalence.zig");
}

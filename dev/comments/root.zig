//! Comment-aware reading of Zig and C/C++ sources for repository tooling.
//! `comment-guard` proves that two versions of a file or tree differ only in
//! comments and whitespace; the provenance gate in
//! `runtime/tests/conventions.zig` and the `provenance-baseline` step count
//! plan history left in comments. Nothing here is linked into the runtime.
//!
//! `cpp_lexer.zig` and `zig_lexer.zig` split each language into comments and
//! code tokens. `source.zig` maps a path to its language, iterates the
//! comments of either one and lists the files of a tree. `equivalence.zig`
//! holds the comparison behind the guard, and `provenance.zig` the markers,
//! the repository scan and the baseline format. `comment_guard.zig` and
//! `provenance_baseline.zig` are the two executables' entry points.
//!
//! The build creates this module with no imports, once for the build host
//! and once for the target of the aggregate test binary, so its files may
//! import only `std` and each other.
//!
//! Tests live in `tests/` and run with `zig build comment-guard-test`; the
//! gate's own tests run in the meta lane with the gate.
pub const cpp_lexer = @import("cpp_lexer.zig");
pub const zig_lexer = @import("zig_lexer.zig");
pub const source = @import("source.zig");
pub const equivalence = @import("equivalence.zig");
pub const provenance = @import("provenance.zig");

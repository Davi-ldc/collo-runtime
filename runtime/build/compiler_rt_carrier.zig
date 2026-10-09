//! Empty translation unit whose only job is to carry Zig's compiler-rt into
//! the executables the C++ driver links (runtime/build/link.zig).
//!
//! Zig-only builtins such as `__zig_probe_stack` exist nowhere but in Zig's
//! compiler-rt. Bundling compiler-rt into a test compilation exports it with
//! internal linkage (lib/compiler_rt/common.zig), so an externally linked
//! test object cannot resolve them. This object is never a test compilation:
//! its bundled compiler-rt keeps weak linkage and satisfies every Zig object
//! in the same link, test or not.

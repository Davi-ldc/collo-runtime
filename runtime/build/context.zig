//! Shared wiring context assembled once in build.zig and consumed by the
//! test and bench step builders.
const std = @import("std");
const codecs_mod = @import("codecs.zig");
const deps_mod = @import("deps.zig");
const options_mod = @import("options.zig");
const toolchain_mod = @import("toolchain.zig");
const jsc_mod = @import("jsc.zig");
const link_mod = @import("link.zig");
const modules_mod = @import("modules.zig");

pub const Context = struct {
    opts: *const options_mod.Options,
    toolchain: *const toolchain_mod.ToolchainPaths,
    libc_file: std.Build.LazyPath,
    /// The codecs for `opts.target`.
    codecs: *const codecs_mod.Codecs,
    /// BoringSSL for `opts.target`.
    boringssl: deps_mod.BoringSsl,
    jsc: jsc_mod.JscBuild,
    link_ctx: link_mod.LinkContext,
    bridge: *std.Build.Step.Compile,
    patched_ls_hpack: std.Build.LazyPath,
    /// Module graph with real JSC bindings (runtime + JSC-linked tests).
    jsc_set: modules_mod.ModuleSet,
    /// Module graph with the h2 transport stub (JSC-free tests).
    stub_set: modules_mod.ModuleSet,
    /// runtime/tests/support/bindings/root.zig (needs real bindings).
    bindings_support_module: *std.Build.Module,
    /// runtime/tests/support/zygote/root.zig (needs real bindings + collo binary path).
    zygote_support_module: *std.Build.Module,
    process_options_module: *std.Build.Module,
    collo_bin: std.Build.LazyPath,
    /// Install of the linked `collo` binary. Every Run step whose tests spawn a
    /// zygote or an egress gateway depends on THIS, because the paths handed to
    /// them are plain strings pointing at the install dir — the artifact
    /// dependency belongs to the run, never to the object being compiled.
    install_collo_step: *std.Build.Step,
    /// Type-check-only aggregate. Every test and bench ROOT hangs its
    /// `*Step.Compile` here and nothing hangs a link or a run, so a root that
    /// only a gated lane builds cannot rot unnoticed.
    check_step: *std.Build.Step,
    /// Run step of the WebAPI fixture check (runtime/build/validate_webapi_tool.zig).
    webapi_contract_step: *std.Build.Step,
    git_or_deploy_hash: []const u8,
};

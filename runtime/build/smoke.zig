//! `zig build smoke`, the check a handoff requires. In order, it runs the
//! `test` aggregate, `zygote-integration` and `local-e2e` with
//! COLLO_TEST_STRICT_SKIPS=1, so any skip runtime/tests/support/skip_allowlist.zon
//! does not grant fails it, then serves one request through the installed
//! `collo serve` with the driver in runtime/tests/support/serve_smoke.zig,
//! which owns what that check expects.
//!
//! Every run needs the delegated cgroup v2 subtree that `wsl-config run`
//! enters (dev/wsl/cgroup_env.zig), so each one waits on a preflight that
//! checks the build's own cgroup before any test starts and, outside the
//! subtree, fails with the command that enters it. Compilation already under
//! way still finishes, because the build runner keeps working on steps that
//! do not depend on a failed one, but no test runs.
const std = @import("std");
const context_mod = @import("context.zig");
const shims = @import("shims.zig");
const tests_mod = @import("tests.zig");

/// Exported by `wsl-config run`: the delegated directory worker leaves go in.
const test_worker_cgroup_root_env = "COLLO_TEST_WORKER_CGROUP_ROOT";
/// The name `collo serve` reads for the same directory.
const worker_cgroup_root_env = "COLLO_WORKER_CGROUP_ROOT";
const cgroup_mount = "/sys/fs/cgroup";

const serve_smoke_root = "runtime/tests/support/serve_smoke.zig";
const hello_fixture = "runtime/tests/integration/fixtures/cli/hello.js";

/// The step every smoke run waits on. It runs in the build process, so it
/// sees the cgroup the build itself was started in.
pub fn addPreflight(b: *std.Build) *std.Build.Step {
    const step = b.allocator.create(std.Build.Step) catch @panic("OOM");
    step.* = std.Build.Step.init(.{
        .id = .custom,
        .name = "smoke preflight: delegated cgroup subtree",
        .owner = b,
        .makeFn = makePreflight,
    });
    return step;
}

pub const Inputs = struct {
    preflight: *std.Build.Step,
    lanes: tests_mod.Lanes,
    /// Installs the wsl-config binary the preflight tells the user to run.
    install_wsl_config: *std.Build.Step,
};

pub fn addStep(b: *std.Build, ctx: *const context_mod.Context, inputs: Inputs) void {
    const lanes = inputs.lanes;
    lanes.strict_zygote_integration.step.dependOn(lanes.aggregate.strict);
    lanes.strict_local_e2e.step.dependOn(&lanes.strict_zygote_integration.step);

    const serve = addServeCheck(b, ctx);
    serve.step.dependOn(inputs.preflight);
    serve.step.dependOn(&lanes.strict_local_e2e.step);

    const smoke = b.step(
        "smoke",
        "Required before handoff: test, zygote-integration and local-e2e with strict skips, then one collo serve request (needs the delegated cgroup)",
    );
    smoke.dependOn(&serve.step);
    smoke.dependOn(inputs.install_wsl_config);
}

/// One request through the installed binary, as a user runs it; the zygote
/// it spawns is the installed one too. `check` type-checks the driver's root
/// with the other roots.
fn addServeCheck(b: *std.Build, ctx: *const context_mod.Context) *std.Build.Step.Run {
    const check_object = b.addObject(.{
        .name = "serve_smoke-check",
        .root_module = serveSmokeModule(b, ctx),
    });
    ctx.check_step.dependOn(&check_object.step);

    const driver = b.addExecutable(.{
        .name = "serve_smoke",
        .root_module = serveSmokeModule(b, ctx),
    });
    // The driver's h2 client is the TLS test shim. The production BoringSSL
    // shim adds the BoringSSL headers and the `collo_boringssl_*` functions
    // the test shim's handshake checks call, which the driver never runs but
    // the linker resolves. Neither takes the build's sanitizer, since the
    // smoke tests the installed binary and not the driver.
    shims.configureBoringSslShim(b, driver, ctx.toolchain, .{});
    shims.configureBoringSslTestShim(b, driver, ctx.toolchain, .{});
    shims.linkBoringSslArchives(b, driver, ctx.opts.boringssl_build_dir);

    const run = b.addRunArtifact(driver);
    run.setName("collo serve the hello fixture");
    run.addArg(b.getInstallPath(.bin, "collo"));
    run.addFileArg(b.path(hello_fixture));
    // `collo serve` reads only the production variable, and the driver
    // hands the server its own environment. The preflight fails the build
    // before this runs when the test variable is missing.
    if (b.graph.env_map.get(test_worker_cgroup_root_env)) |root|
        run.setEnvironmentVariable(worker_cgroup_root_env, root);
    // A smoke proves the build in front of it, so it never answers from cache.
    run.has_side_effects = true;
    run.step.dependOn(ctx.install_collo_step);
    return run;
}

/// A fresh module per compilation, because the shims attach their C++
/// sources to the root module of the executable that links them.
fn serveSmokeModule(b: *std.Build, ctx: *const context_mod.Context) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path(serve_smoke_root),
        .target = ctx.opts.target,
        .optimize = ctx.opts.optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    module.addImport("collo_os", ctx.stub_set.get(.os));
    module.addImport(
        "collo_test_tls_shim",
        shims.tlsTestShimModule(b, ctx.opts.target, ctx.opts.optimize),
    );
    return module;
}

fn makePreflight(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
    _ = options;
    const b = step.owner;
    if (b.args) |args| {
        if (args.len != 0)
            return step.fail("smoke always runs every lane in full and takes no arguments after `--`", .{});
    }
    const problem = subtreeProblem(b) orelse return;
    return step.fail(
        \\smoke needs the delegated cgroup v2 subtree, and this build runs outside it: {s}.
        \\Run it through wsl-config, keeping this build's -D options:
        \\  sudo --preserve-env=PATH,COLLO_BUILD_JOBS,CMAKE_BUILD_PARALLEL_LEVEL ./zig-out/bin/wsl-config run -- zig build -j4 smoke
        \\Once per WSL boot, provision the subtree first:
        \\  sudo ./zig-out/bin/wsl-config prepare
    , .{problem});
}

/// Null when this process lives strictly below the directory `wsl-config
/// run` exported; otherwise what is wrong. Strictly below, because worker
/// leaves are created in that directory, and cgroup v2 lets no process stay
/// in a directory that hands controllers to its children.
fn subtreeProblem(b: *std.Build) ?[]const u8 {
    const root = b.graph.env_map.get(test_worker_cgroup_root_env) orelse
        return test_worker_cgroup_root_env ++ " is not set";
    if (!std.mem.startsWith(u8, root, cgroup_mount ++ "/"))
        return b.fmt("{s}={s} is not under {s}", .{ test_worker_cgroup_root_env, root, cgroup_mount });
    const root_relative = std.mem.trimRight(u8, root[cgroup_mount.len..], "/");

    const membership = readOwnCgroups(b) catch |err|
        return b.fmt("/proc/self/cgroup is unreadable ({s})", .{@errorName(err)});
    var lines = std.mem.tokenizeScalar(u8, membership, '\n');
    while (lines.next()) |line| {
        // The cgroup v2 entry; v1 hierarchies list their controllers instead.
        if (!std.mem.startsWith(u8, line, "0::")) continue;
        const own = line["0::".len..];
        const below_root = std.mem.startsWith(u8, own, root_relative) and
            own.len > root_relative.len and own[root_relative.len] == '/';
        if (below_root) return null;
        return b.fmt("this process is in cgroup {s}, outside {s}", .{ own, root });
    }
    return "/proc/self/cgroup has no cgroup v2 entry";
}

fn readOwnCgroups(b: *std.Build) ![]u8 {
    var file = try std.fs.openFileAbsolute("/proc/self/cgroup", .{});
    defer file.close();
    return file.readToEndAlloc(b.allocator, 64 * 1024);
}

//! The `collo serve` boot: one server process that reads its configuration,
//! builds every route from disk, starts the zygote and serves HTTP/2 over
//! TLS until SIGINT or SIGTERM, then drains the requests in flight and exits.
//!
//! - `command_line.zig`: the arguments of `collo serve`.
//! - `signals.zig`: SIGHUP, SIGINT and SIGTERM through a signalfd monitor.
//! - `trace_drain.zig`: the reader of the zygote's boot trace pipe.
//! - `report.zig`: the lines written to stderr for the operator.
//!
//! `serve` runs on the main thread, in this order:
//!
//! 1. Refuse to run as root (`rootRefusal`), before anything else. The
//!    zygote, every worker and the gateway run as the server's user, so a
//!    worker that gets out of its namespaces, chroot and seccomp filter holds
//!    what that user holds; as root, that is the whole node.
//! 2. Block SIGHUP, SIGINT and SIGTERM and start their monitor
//!    (`signals.zig`), before any other thread exists and before anything
//!    that needs cleaning up. A first SIGINT or SIGTERM during the boot waits
//!    for the `Server`, which then stops before it serves; a second one ends
//!    the process at once. The zygote and the gateway start in sessions of
//!    their own, so a terminal's Ctrl-C or hangup reaches only the server:
//!    Ctrl-C stops it, and it stops them, while a hangup makes it reopen its
//!    analytics files and keep serving.
//! 3. Raise the soft open file limit to the hard one, then load the
//!    configuration and build every route's artifacts. The routes alone keep
//!    `route_descriptors_max` descriptors open for the server's life, before
//!    any client connection or worker channel.
//! 4. Require a kernel TLS cipher, which the server cannot serve without.
//!    Nothing here depends on the steps after it, so a missing `tls` module
//!    fails the boot before any child process exists.
//! 5. Create the worker cgroup root. It must exist before the zygote: a
//!    delegated placement moves only the calling process into `<own>/main`,
//!    and a zygote left in `<own>` would keep its controllers from being
//!    enabled (`prepareDelegatedSubtree` in `host/cgroup_root.zig`).
//! 6. Spawn the zygote with the warmup corpus, then drain its trace pipe,
//!    which holds the zygote's boot events until the drain starts.
//! 7. Choose the certificate: the configured one, or a generated self-signed
//!    one with a warning.
//! 8. Build the `Server` from the routes, attach it to the signal monitor and
//!    run it, which prints `collo: listening on https://<address>` with the
//!    bound port once every lane accepts connections.
//!
//! The boot does not prewarm the egress gateway
//! (`Server.prewarmEgressGateway` in `server/main.zig`), so the gateway
//! starts when the first worker attaches to it.
//! Teardown runs in reverse: the monitor detaches from the `Server`, the
//! `Server` stops its workers, the drain stops, then the zygote and the
//! cgroup root go. The monitor joins last, so a second stop signal during the
//! teardown still ends the process at once instead of taking its default
//! action halfway through it.
//!
//! Exit status (`ExitStatus`): `ok` after a stop a signal requested,
//! `invalid` for invalid usage, a run as root or a configuration that cannot
//! be served (the configuration file, an entry module or a path it names),
//! `failure` for anything else, and 128 plus the signal number when a second
//! stop signal cuts the boot, the drain or the teardown short. Every failure
//! ends with one `report.line` that names its cause; a library that logs its
//! own reason, such as BoringSSL, adds that line before it.

const std = @import("std");
const config = @import("collo_server_config");
const routes_mod = @import("collo_server_routes");
const zygote = @import("collo_zygote");
const host = @import("collo_host");
const server_limits = @import("collo_limits").server;
const server_main = @import("../main.zig");
const tls = @import("../tls/root.zig");
const ktls = @import("../tls/ktls.zig");

pub const command_line = @import("command_line.zig");
pub const report = @import("report.zig");
pub const signals = @import("signals.zig");
pub const trace_drain = @import("trace_drain.zig");

pub const ExitStatus = enum(u8) {
    ok = 0,
    failure = 1,
    invalid = 2,
};

/// Names an existing delegated, process-free cgroup v2 directory for the
/// worker leaves. Without it the server carves the subtree out of its own
/// cgroup, which must then be delegated to it.
pub const worker_cgroup_root_env = "COLLO_WORKER_CGROUP_ROOT";

/// Every route's sealed module pack and bindings blob, plus the filesystem
/// index they share.
pub const route_descriptors_max: usize = 2 * server_limits.routes_max + 1;

/// Prints why `command_line.parse` refused the arguments, then the usage
/// line.
pub fn invalidUsage(diagnostic: *const command_line.Diagnostic) ExitStatus {
    report.line("{s}", .{diagnostic.message()});
    std.fs.File.stderr().writeAll(command_line.usage) catch return .invalid;
    return .invalid;
}

/// Null for an unprivileged effective user. For root, reports on stderr why
/// the boot refuses to run and returns the status `serve` exits with.
pub fn rootRefusal(effective_uid: std.posix.uid_t) ?ExitStatus {
    if (effective_uid != 0)
        return null;
    report.line("refusing to run as root: run collo serve as an unprivileged user, inside a delegated cgroup v2 subtree" ++
        " or with " ++ worker_cgroup_root_env ++ " naming one", .{});
    return .invalid;
}

/// Runs `collo serve` to its end on the main thread, which must not have
/// started any other thread yet (`signals.zig`). `gpa` is the
/// process-lifetime allocator. Every failure is reported on stderr and
/// returned as an exit status.
pub fn serve(gpa: std.mem.Allocator, invocation: command_line.Invocation) ExitStatus {
    if (rootRefusal(std.posix.geteuid())) |status|
        return status;

    var monitor: signals.Signals = undefined;
    monitor.start() catch |err| {
        report.line("cannot route SIGHUP, SIGINT and SIGTERM to the signal monitor: {s}", .{@errorName(err)});
        return .failure;
    };
    defer monitor.deinit();

    raiseOpenFileLimit() catch |err| {
        report.line("cannot raise the open file limit: {s}", .{@errorName(err)});
        return .failure;
    };

    var diagnostic: config.Diagnostic = .{};
    var loaded = loadConfiguration(gpa, invocation, &diagnostic) catch |err| switch (err) {
        error.OutOfMemory => return outOfMemory(),
        error.InvalidConfig => return invalidConfiguration(&diagnostic),
    };
    checkConfiguredPaths(&loaded, &diagnostic) catch {
        loaded.deinit();
        return invalidConfiguration(&diagnostic);
    };
    var routes: routes_mod.Routes = undefined;
    routes.init(gpa, loaded, &diagnostic) catch |err| switch (err) {
        error.OutOfMemory => return outOfMemory(),
        error.RouteBuildFailed => return invalidConfiguration(&diagnostic),
    };
    // `Server.init` takes the routes on every call, failure included.
    var routes_owned = true;
    defer if (routes_owned) routes.deinit();

    _ = tls.KtlsNegotiationPolicy.fromCapabilities(ktls.KernelCapabilities.probe()) catch |err| switch (err) {
        error.NoUsableKtlsCipher => return missingKtls(),
    };

    var cgroup_root = host.WorkerCgroupRoot.init(gpa, cgroupPlacement()) catch |err| switch (err) {
        error.WorkerCgroupDelegationUnavailable => {
            report.line("no delegated cgroup v2 subtree for workers; set " ++ worker_cgroup_root_env ++
                " to one, or on WSL run `sudo ./zig-out/bin/wsl-config prepare` once per boot and start the server with" ++
                " `sudo --preserve-env=PATH ./zig-out/bin/wsl-config run -- env " ++ worker_cgroup_root_env ++
                "=/sys/fs/cgroup/collo-dev collo serve ...`", .{});
            return .failure;
        },
        else => {
            report.line("cannot create the worker cgroup root: {s}", .{@errorName(err)});
            return .failure;
        },
    };
    defer cgroup_root.deinit(gpa);

    var spawned = zygote.host_client.spawnZygote(.{ .warmup_corpus = true }) catch |err| {
        report.line("cannot start the zygote: {s}", .{@errorName(err)});
        return .failure;
    };
    defer spawned.deinit();

    var drain: trace_drain.TraceDrain = undefined;
    var drain_running = false;
    if (spawned.trace_read_fd) |trace_fd| {
        drain.init(trace_fd, trace_drain.loggingRequested()) catch |err| {
            report.line("cannot start the boot trace drain: {s}", .{@errorName(err)});
            return .failure;
        };
        drain_running = true;
    }
    defer if (drain_running) drain.deinit();

    const listen = routes.config.listen;
    const configured_tls = routes.config.tls;
    // A failed `Server.init` frees the configuration before its error is
    // reported, so the message keeps its own copy of the path.
    const config_path = gpa.dupe(u8, routes.config.path) catch return outOfMemory();
    defer gpa.free(config_path);
    var server = built: {
        var generated: tls.self_signed.SelfSignedCertificate = undefined;
        const certificate: tls.CertificateConfig = if (configured_tls) |paths| .{
            .cert_chain = .{ .path = paths.certificate_path },
            .private_key = .{ .path = paths.private_key_path },
        } else fallback: {
            generated.generate(listen, std.time.timestamp()) catch |err| {
                report.line("cannot generate a self-signed certificate: {s}", .{@errorName(err)});
                return .failure;
            };
            report.written(&generated, tls.self_signed.SelfSignedCertificate.writeWarning);
            break :fallback generated.certificateConfig();
        };
        // BoringSSL keeps its own copy, so the generated private key is wiped
        // as soon as `Server.init` returns, whether or not it succeeded.
        defer if (configured_tls == null) generated.deinit();

        routes_owned = false;
        break :built server_main.Server.init(gpa, &spawned, .{
            .routes = routes,
            .analytics_directory = if (routes.config.analytics) |analytics| analytics.directory_path else null,
            .listen = listen,
            .tls_certificate = certificate,
            .worker_cgroup_root = &cgroup_root,
            .on_serving = &announceListening,
        }) catch |err| return serverInitFailure(err, .{
            .listen = listen,
            .config_path = config_path,
            .tls_configured = configured_tls != null,
        });
    };
    defer server.deinit();
    monitor.attach(.{
        .context = &server,
        .request_stop = &requestServerStop,
        .analytics = server.analytics,
    });
    defer monitor.detach();

    server.run() catch |err| {
        if (err == error.ZygoteDied) {
            report.line("the zygote exited, so no worker can start; the server stopped", .{});
        } else {
            report.line("the server stopped: {s}", .{@errorName(err)});
        }
        return .failure;
    };
    if (!monitor.stopRequested()) {
        report.line("the server stopped without a shutdown signal", .{});
        return .failure;
    }
    return .ok;
}

fn loadConfiguration(
    gpa: std.mem.Allocator,
    invocation: command_line.Invocation,
    diagnostic: *config.Diagnostic,
) config.Error!config.Config {
    var loaded = switch (invocation.source) {
        .configuration => try config.load(gpa, invocation.path, diagnostic),
        .entry_module => try config.synthesize(gpa, invocation.path, diagnostic),
    };
    if (invocation.listen) |listen|
        loaded.listen = listen;
    return loaded;
}

/// The files and directory the configuration names outside its routes, each
/// checked so a failure names the key that holds the path. `Server.init`
/// opens them again.
fn checkConfiguredPaths(loaded: *const config.Config, diagnostic: *config.Diagnostic) error{InvalidConfig}!void {
    if (loaded.tls) |paths| {
        try checkPemFile(loaded.path, .{
            .key = "globalSettings.tls.certificate",
            .path = paths.certificate_path,
            .bytes_max = tls.max_cert_chain_pem_bytes,
        }, diagnostic);
        try checkPemFile(loaded.path, .{
            .key = "globalSettings.tls.privateKey",
            .path = paths.private_key_path,
            .bytes_max = tls.max_private_key_pem_bytes,
        }, diagnostic);
    }
    if (loaded.analytics) |analytics| {
        var directory = std.fs.openDirAbsolute(analytics.directory_path, .{}) catch |err| {
            diagnostic.set("{s}: globalSettings.analytics.directory: cannot open the directory {s}: {s}", .{
                loaded.path,
                analytics.directory_path,
                @errorName(err),
            });
            return error.InvalidConfig;
        };
        defer directory.close();
        // The analytics sink creates and appends its record files in it.
        std.posix.faccessat(directory.fd, ".", std.posix.W_OK | std.posix.X_OK, 0) catch |err| {
            diagnostic.set("{s}: globalSettings.analytics.directory: cannot write to the directory {s}: {s}", .{
                loaded.path,
                analytics.directory_path,
                @errorName(err),
            });
            return error.InvalidConfig;
        };
    }
}

const PemFile = struct {
    key: []const u8,
    path: []const u8,
    /// The most the TLS context reads from it (`server/tls/root.zig`).
    bytes_max: usize,
};

/// A PEM file the TLS context reads whole: a nonempty regular file within
/// `file.bytes_max`.
fn checkPemFile(config_path: []const u8, file: PemFile, diagnostic: *config.Diagnostic) error{InvalidConfig}!void {
    const opened = std.fs.openFileAbsolute(file.path, .{}) catch |err| {
        diagnostic.set("{s}: {s}: cannot read {s}: {s}", .{ config_path, file.key, file.path, @errorName(err) });
        return error.InvalidConfig;
    };
    defer opened.close();
    const stat = opened.stat() catch |err| {
        diagnostic.set("{s}: {s}: cannot read {s}: {s}", .{ config_path, file.key, file.path, @errorName(err) });
        return error.InvalidConfig;
    };
    if (stat.kind != .file) {
        diagnostic.set("{s}: {s}: {s} is not a regular file", .{ config_path, file.key, file.path });
        return error.InvalidConfig;
    }
    if (stat.size == 0) {
        diagnostic.set("{s}: {s}: {s} is empty", .{ config_path, file.key, file.path });
        return error.InvalidConfig;
    }
    if (stat.size > file.bytes_max) {
        diagnostic.set("{s}: {s}: {s} holds {d} bytes, more than the {d} it may hold", .{
            config_path,
            file.key,
            file.path,
            stat.size,
            file.bytes_max,
        });
        return error.InvalidConfig;
    }
}

/// Raised before the routes are built, since they keep
/// `route_descriptors_max` descriptors open from boot on.
fn raiseOpenFileLimit() !void {
    const limit = try std.posix.getrlimit(.NOFILE);
    if (limit.cur >= limit.max)
        return;
    try std.posix.setrlimit(.NOFILE, .{ .cur = limit.max, .max = limit.max });
}

fn cgroupPlacement() host.cgroup_root.Placement {
    const root = std.posix.getenv(worker_cgroup_root_env) orelse return .delegated;
    if (root.len == 0)
        return .delegated;
    return .{ .env_root = root };
}

fn announceListening(address: std.net.Address) void {
    report.line("listening on https://{f}", .{address});
}

fn requestServerStop(context: *anyopaque) void {
    const server: *server_main.Server = @ptrCast(@alignCast(context));
    server.requestStop();
}

const ServerInitContext = struct {
    listen: std.net.Address,
    config_path: []const u8,
    tls_configured: bool,
};

fn serverInitFailure(err: anyerror, context: ServerInitContext) ExitStatus {
    switch (err) {
        error.NoUsableKtlsCipher => return missingKtls(),
        error.AddressInUse => {
            report.line("cannot listen on {f}: the address is in use", .{context.listen});
            return .failure;
        },
        error.AddressNotAvailable => {
            report.line("cannot listen on {f}: no interface on this machine holds the address", .{context.listen});
            return .failure;
        },
        error.BoringSslInitFailed, error.EmptyPemMaterial, error.PemMaterialTooLarge => {
            if (context.tls_configured) {
                report.line("{s}: globalSettings.tls: the certificate or private key is not usable: {s}", .{
                    context.config_path,
                    @errorName(err),
                });
                return .invalid;
            }
            report.line("the generated certificate was refused: {s}", .{@errorName(err)});
            return .failure;
        },
        else => {
            report.line("the server failed to start: {s}", .{@errorName(err)});
            return .failure;
        },
    }
}

fn missingKtls() ExitStatus {
    report.line("the kernel offers no TLS cipher the server can hand to kTLS; load the module with `sudo modprobe tls`", .{});
    return .failure;
}

fn invalidConfiguration(diagnostic: *const config.Diagnostic) ExitStatus {
    report.line("{s}", .{diagnostic.message()});
    return .invalid;
}

fn outOfMemory() ExitStatus {
    report.line("out of memory during boot", .{});
    return .failure;
}

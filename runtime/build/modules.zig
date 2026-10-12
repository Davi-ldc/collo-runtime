//! Single source of truth for the collo_* module graph. Built once per
//! (target, optimize, bindings-flavor); the JSC graph backs the runtime binary
//! and JSC-linked tests, the h2_stub graph backs JSC-free transport tests and
//! the egress benches. A module carries no library: the artifact that links
//! names the pinned archives it needs (codecs.zig, deps.zig), because many
//! compilations of these modules are objects that link.zig links later.
const std = @import("std");
const codecs_mod = @import("codecs.zig");

pub const BindingsFlavor = enum {
    /// src/bindings/root.zig — requires linking the JSC bridge.
    jsc,
    /// runtime/tests/support/bindings/h2_transport_stub.zig — links without JSC.
    h2_stub,
};

pub const GraphOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    bindings: BindingsFlavor,
    /// Built for `target`.
    codecs: *const codecs_mod.Codecs,
};

pub const ModuleId = enum {
    bindings,
    zlib,
    brotli,
    zstd,
    boringssl,
    hpack,
    dns_name,
    network,
    limits,
    http,
    cgroup,
    os,
    ktls,
    ipc,
    io_uring_tags,
    common_io,
    worker_state,
    worker_js,
    worker_request,
    egress_accounting,
    egress_core,
    egress_io,
    egress_readiness,
    egress_dns_cache,
    egress_http2,
    egress_tls,
    egress_transport,
    egress_data_io,
    egress_pool,
    egress_client,
    egress_gateway,
    worker,
    zygote,
    host,
    server_config,
    server_routes,
    server_lifecycle,
    server_analytics,
    server_h2,
    server_supervisor,
    server_gateway,
    server_main,
    main,
};

const Spec = struct {
    id: ModuleId,
    root: []const u8,
    libc: bool = true,
    libcpp: bool = false,
    imports: []const ModuleId = &.{},
};

const egress_io_imports = [_]ModuleId{
    .egress_accounting, .common_io, .egress_io, .io_uring_tags,
    .os,                .http,      .hpack,     .boringssl,
    .egress_core,
};

const specs = [_]Spec{
    .{ .id = .bindings, .root = "runtime/src/bindings/root.zig", .imports = &.{.limits} },
    .{ .id = .zlib, .root = "runtime/src/bindings/zlib/root.zig" },
    .{ .id = .brotli, .root = "runtime/src/bindings/brotli/root.zig" },
    .{ .id = .zstd, .root = "runtime/src/bindings/zstd/root.zig" },
    .{ .id = .boringssl, .root = "runtime/src/bindings/boringssl/root.zig" },
    .{ .id = .hpack, .root = "runtime/src/bindings/hpack/root.zig" },
    .{ .id = .dns_name, .root = "runtime/src/common/dns_name.zig", .libc = false },
    .{ .id = .network, .root = "runtime/src/common/network/root.zig", .libc = false, .imports = &.{.limits} },
    .{ .id = .limits, .root = "runtime/src/common/limits/root.zig", .libc = false },
    .{ .id = .http, .root = "runtime/src/common/http/root.zig", .libc = false, .imports = &.{.dns_name} },
    .{ .id = .cgroup, .root = "runtime/src/common/cgroup.zig" },
    .{ .id = .os, .root = "runtime/src/common/os.zig" },
    .{ .id = .ktls, .root = "runtime/src/common/tls/ktls.zig", .imports = &.{.os} },
    .{ .id = .ipc, .root = "runtime/src/common/ipc/root.zig", .imports = &.{ .os, .limits } },
    .{ .id = .io_uring_tags, .root = "runtime/src/common/io/uring_tags.zig", .libc = false },
    // The restricted ring's descriptor checks read socket options through
    // `collo_os.socket`, which links libc.
    .{ .id = .common_io, .root = "runtime/src/common/io/root.zig", .imports = &.{ .io_uring_tags, .os } },
    .{ .id = .worker_state, .root = "runtime/src/common/worker_state/root.zig", .imports = &.{ .os, .limits } },
    .{
        // Leaf JS↔JSC plumbing (deferred/value/exception_log/turn) shared by
        // worker and worker_request.
        .id = .worker_js,
        .root = "runtime/src/worker/js/jsc/root.zig",
        .imports = &.{.bindings},
    },
    .{
        // Facade root lives at src/worker/ next to api.zig; its closure is
        // request/* only (no worker-side path imports — one file, one module).
        .id = .worker_request,
        .root = "runtime/src/worker/request_api.zig",
        .imports = &.{
            .bindings,  .worker_state, .ipc,    .http,
            .common_io, .egress_core,  .limits, .worker_js,
        },
    },
    .{ .id = .egress_accounting, .root = "runtime/src/egress/core/accounting.zig", .libc = false },
    .{
        .id = .egress_core,
        .root = "runtime/src/egress/core/root.zig",
        .libcpp = true,
        .imports = &.{ .bindings, .common_io, .http, .limits, .zlib, .brotli },
    },
    .{ .id = .egress_io, .root = "runtime/src/egress/client/io.zig", .libc = false },
    .{
        .id = .egress_readiness,
        .root = "runtime/src/egress/client/io/readiness.zig",
        .libc = false,
        .imports = &.{ .egress_io, .common_io, .io_uring_tags },
    },
    .{
        .id = .egress_dns_cache,
        .root = "runtime/src/egress/client/dns_cache.zig",
        .imports = &.{.egress_readiness},
    },
    .{
        .id = .egress_http2,
        .root = "runtime/src/egress/client/transport/h2/codec/root.zig",
        .libc = false,
        .imports = &.{ .egress_accounting, .http, .hpack, .limits },
    },
    .{ .id = .egress_tls, .root = "runtime/src/egress/client/tls.zig", .libcpp = true, .imports = &.{.boringssl} },
    .{
        .id = .egress_transport,
        .root = "runtime/src/egress/client/transport/root.zig",
        .libcpp = true,
        .imports = &([_]ModuleId{
            .egress_tls,
            .egress_http2,
            .egress_readiness,
            .egress_dns_cache,
            .limits,
            .network,
        } ++ egress_io_imports),
    },
    .{
        .id = .egress_data_io,
        .root = "runtime/src/egress/client/io/bio_data.zig",
        .libcpp = true,
        .imports = &([_]ModuleId{.egress_transport} ++ egress_io_imports),
    },
    .{
        .id = .egress_pool,
        .root = "runtime/src/egress/client/transport/h2/pool.zig",
        .libcpp = true,
        .imports = &([_]ModuleId{
            .egress_transport,
            .egress_http2,
            .egress_data_io,
            .egress_readiness,
        } ++ egress_io_imports),
    },
    .{
        .id = .egress_client,
        .root = "runtime/src/egress/client/root.zig",
        .libcpp = true,
        .imports = &([_]ModuleId{
            .bindings,
            .egress_transport,
            .egress_tls,
            .egress_http2,
            .egress_readiness,
            .egress_dns_cache,
            .egress_data_io,
            .egress_pool,
        } ++ egress_io_imports),
    },
    .{
        // The egress gateway process, and the control wire and launch
        // contract the server compiles too; it imports no server module.
        .id = .egress_gateway,
        .root = "runtime/src/egress/gateway/root.zig",
        .libcpp = true,
        .imports = &.{
            .ipc,           .os,            .bindings, .common_io,
            .io_uring_tags, .egress_client, .limits,
        },
    },
    .{
        .id = .worker,
        .root = "runtime/src/worker/api.zig",
        .imports = &.{
            .bindings,       .worker_state, .ipc,         .os,     .cgroup,
            .http,           .common_io,    .egress_core, .limits, .worker_js,
            .worker_request, .network,
        },
    },
    .{
        .id = .zygote,
        .root = "runtime/src/zygote/root.zig",
        .imports = &.{ .bindings, .worker, .ipc, .os, .cgroup, .worker_state, .limits },
    },
    .{
        // The parent side of the zygote/worker contract: cgroup leaf,
        // WorkerInit handoff, request dispatch, teardown. Every host (the
        // server, local runner, test harness) drives workers through it.
        .id = .host,
        .root = "runtime/src/host/root.zig",
        .imports = &.{ .zygote, .ipc, .os, .cgroup, .worker_state, .limits },
    },
    .{
        // The parsed server configuration; it reads no module and starts no
        // worker, so it needs only the limits, from ipc the binding name
        // grammar the worker enforces too, and the `network` grammar the
        // gateway enforces.
        .id = .server_config,
        .root = "runtime/src/server/config/root.zig",
        .imports = &.{ .limits, .ipc, .network },
    },
    .{
        // The route table, the per-route artifacts and the `network` policy
        // image built from the configuration: module packs and bindings blobs
        // come from ipc, the image from the network module's builder.
        .id = .server_routes,
        .root = "runtime/src/server/routes/root.zig",
        .imports = &.{ .server_config, .limits, .ipc, .os, .network },
    },
    .{ .id = .server_lifecycle, .root = "runtime/src/server/lifecycle.zig", .imports = &.{.os} },
    .{
        .id = .server_analytics,
        .root = "runtime/src/server/analytics/root.zig",
        .imports = &.{ .limits, .os, .worker_state },
    },
    .{
        .id = .server_h2,
        .root = "runtime/src/server/http2.zig",
        .imports = &.{
            .common_io, .server_lifecycle, .http,      .hpack,  .ipc,
            .ktls,      .os,               .boringssl, .limits,
        },
    },
    .{
        .id = .server_supervisor,
        .root = "runtime/src/server/supervisor/root.zig",
        .imports = &.{
            .server_config, .server_routes,    .zygote,           .ipc,
            .os,            .cgroup,           .worker_state,     .limits,
            .host,          .server_lifecycle, .server_analytics, .egress_gateway,
        },
    },
    .{
        // The server's side of the egress gateway: spawning it with the hello
        // that carries the token key and the policy table, attaching workers
        // over its control wire, and the lease a lane mints tokens with.
        .id = .server_gateway,
        .root = "runtime/src/server/gateway/root.zig",
        .imports = &.{ .egress_gateway, .ipc, .os, .limits, .server_lifecycle },
    },
    .{
        .id = .server_main,
        .root = "runtime/src/server/main.zig",
        .imports = &.{
            .server_config, .server_routes,    .server_supervisor, .server_gateway,
            .zygote,        .ipc,              .os,                .ktls,
            .worker_state,  .io_uring_tags,    .boringssl,         .hpack,
            .http,          .common_io,        .server_lifecycle,  .limits,
            .host,          .server_analytics, .egress_gateway,
        },
    },
    .{
        .id = .main,
        .root = "runtime/src/main.zig",
        .imports = &.{ .server_main, .egress_gateway, .zygote },
    },
};

pub const ModuleSet = struct {
    modules: std.EnumArray(ModuleId, *std.Build.Module),

    pub fn get(self: *const ModuleSet, id: ModuleId) *std.Build.Module {
        return self.modules.get(id);
    }

    pub fn importInto(self: *const ModuleSet, module: *std.Build.Module, ids: []const ModuleId) void {
        for (ids) |id|
            module.addImport(importName(id), self.get(id));
    }
};

pub fn importName(id: ModuleId) []const u8 {
    return switch (id) {
        inline else => |tag| "collo_" ++ @tagName(tag),
    };
}

comptime {
    // Every module must be declared exactly once, in enum order.
    if (specs.len != @typeInfo(ModuleId).@"enum".fields.len)
        @compileError("modules.zig: specs out of sync with ModuleId");
}

pub fn buildModuleGraph(b: *std.Build, opts: GraphOptions) ModuleSet {
    var set: std.EnumArray(ModuleId, *std.Build.Module) = undefined;
    for (specs) |spec| {
        const root = if (spec.id == .bindings and opts.bindings == .h2_stub)
            "runtime/tests/support/bindings/h2_transport_stub.zig"
        else
            spec.root;
        set.set(spec.id, b.createModule(.{
            .root_source_file = b.path(root),
            .target = opts.target,
            .optimize = opts.optimize,
            .link_libc = spec.libc,
            .link_libcpp = spec.libcpp,
        }));
    }
    // Each codec's binding module is the one importer of its translated
    // headers.
    set.get(.zlib).addImport("zlib_h", opts.codecs.zlib.header_module);
    set.get(.brotli).addImport("brotli_h", opts.codecs.brotli.header_module);
    set.get(.zstd).addImport("zstd_h", opts.codecs.zstd.header_module);
    for (specs) |spec| {
        const module = set.get(spec.id);
        for (spec.imports) |dep|
            module.addImport(importName(dep), set.get(dep));
    }
    return .{ .modules = set };
}

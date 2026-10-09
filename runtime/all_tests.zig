//! Root of the `all` test compilation (runtime/build/tests.zig addMainSuite).
//! Lives at runtime/ — NOT runtime/tests/ — because Zig collects test
//! declarations only from the ROOT module of a test compilation and a path
//! import may not escape the root file's directory: from here both the
//! root-local suites (tests/...) and the module-scoped suites
//! (src/<module>/tests/...) are path-importable. Test FQNs are file paths
//! relative to this directory (`/`→`.` plus `.test.`), so the domain_steps
//! filter table in runtime/build/tests.zig reads `tests.*` for root-local
//! suites, `src.<module>.tests.*` for moved domains, and `build.tests.*`
//! for the build-tool suite.
const test_options = @import("collo_test_build_options");

comptime {
    _ = @import("src/bindings/tests/all.zig");
    _ = @import("build/tests/all.zig");
    _ = @import("src/common/tests/all.zig");
    _ = @import("tests/contracts/limits.zig");
    _ = @import("tests/contracts/abi.zig");
    _ = @import("tests/contracts/module_pack.zig");
    _ = @import("tests/contracts/benchmark_all.zig");
    _ = @import("collo_common_io");
    _ = @import("collo_common_io").uring;
    _ = @import("collo_worker_state").page;
    _ = @import("src/server/tests/all.zig");
    _ = @import("tests/conventions.zig");
    _ = @import("tests/support/tests/skip_allowlist.zig");
    _ = @import("collo_server_supervisor");
    _ = @import("collo_server_config");
    _ = @import("collo_server_routes");
    _ = @import("collo_server_main").ingress;
    _ = @import("collo_server_main").lane_plan;
    _ = @import("collo_server_supervisor").pool;
    _ = @import("collo_server_supervisor").launcher;
    _ = @import("collo_server_supervisor").reaper;
    _ = @import("collo_server_supervisor").worker_table;
    _ = @import("collo_server_supervisor").accounting.usage;
    _ = @import("src/worker/tests/all.zig");
    _ = @import("src/egress/tests/all.zig");
    _ = @import("src/zygote/tests/all.zig");
    _ = @import("src/host/tests/all.zig");
    if (test_options.include_webapi_compat) {
        _ = @import("tests/webapi/suites.zig");
        _ = @import("tests/webapi/forked.zig");
    }
}

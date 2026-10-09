//! Runs the Bun microtask fixture, which `suites.zig` also runs in-process, in a
//! worker forked from a real zygote and booted through its sandbox. It shows
//! that the module pack holding `collo:test` and a fixture evaluates and
//! reports in a production worker. Compiled only under `-Dwebapi-compat` and
//! run by `webapi-test`; it needs the delegated cgroup subtree and skips
//! without it.

const webapi_forked = @import("forked_support.zig");

test "forked worker runs collo test WebAPI module pack" {
    try webapi_forked.runCompatSuite(
        @embedFile("microtask/microtask.bun.test.js"),
        "/webapi/forked/microtask.test.js",
    );
}

//! Collects the suites of the server configuration module (`server/config/`):
//! the `collo.json` parser and its rejections, the route pattern grammar,
//! and the configuration synthesized for an entry module. No engine runs in
//! them: the `server-config` suite of `server-fast-test` runs them alone, and
//! `server-routes-test` runs them in the JSC-linked aggregate. The route
//! table and artifacts built from a configuration are covered in
//! `server/tests/routes/`.

comptime {
    _ = @import("parse.zig");
    _ = @import("pattern.zig");
    _ = @import("synthesize.zig");
}

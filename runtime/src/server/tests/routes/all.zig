//! Collects the suites of the routes module (`server/routes/`): the route
//! table, the import scanner, and the artifacts built from modules on disk.
//! No engine runs in them: the `server-routes` suite of `server-fast-test`
//! runs them alone, and `server-routes-test` runs them in the JSC-linked
//! aggregate. The configuration they start from is covered in
//! `server/tests/config/`.

comptime {
    _ = @import("table.zig");
    _ = @import("imports.zig");
    _ = @import("artifacts.zig");
}

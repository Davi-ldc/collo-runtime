//! The worker's egress suites: the fetch body with its chunks and tees
//! (`body/body.zig`) and the decoder of encoded bodies (`body/decoder.zig`)
//! without a runtime; and, on a runtime with no JavaScript, the body table's
//! slots and ready items (`body/register.zig`), cancels and releases
//! (`body/cleanup.zig`), the fetch tasks and their completion items
//! (`fetch_runtime.zig`) and gateway packets applied to bodies
//! (`gateway_runtime.zig`). They run in `worker-test`; the paths through
//! JavaScript are in `worker/tests/runtime/fetch.zig`.

comptime {
    _ = @import("body/body.zig");
    _ = @import("body/cleanup.zig");
    _ = @import("body/decoder.zig");
    _ = @import("body/register.zig");
    _ = @import("fetch_runtime.zig");
    _ = @import("gateway_runtime.zig");
}

//! Request accounting identity for the supervisor; `usage.zig` holds the key
//! of a request attempt that a worker's usage record is matched against.

pub const usage = @import("usage.zig");

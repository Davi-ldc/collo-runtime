//! Module root of `collo_worker_js`, the JavaScript plumbing that the `worker`
//! and `worker_request` modules share. It imports only `collo_bindings` and
//! std, which is what lets both modules depend on it; code that needs the
//! worker `Runtime` or request state belongs in the `worker` module. Its code
//! runs in the worker on the VM thread.
//!
//! `turn.zig` runs each operation that can execute JavaScript inside a turn,
//! `deferred.zig` owns promise deferred handles, `value.zig` types borrowed
//! and owned value handles, and `exception_log.zig` logs JavaScript
//! exceptions, keeping their text out of the operator's log unless full
//! logging is configured. The `crypto/` and `server_api/` directories
//! beside this one belong to the `worker` module, which imports their files
//! by path.

pub const deferred = @import("deferred.zig");
pub const exception_log = @import("exception_log.zig");
pub const turn = @import("turn.zig");
pub const value = @import("value.zig");

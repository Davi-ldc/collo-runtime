//! A route's `env`, the second argument of its handler: a frozen object whose
//! own properties are the route's text bindings, names to string values in
//! configuration order. Runs in the worker on the VM thread.
//!
//! The bindings arrive as one sealed blob in the layout and under the rules
//! of `common/ipc/route_bindings.zig`, which the server builds once per route
//! (`server/routes/artifacts.zig`) and hands over in WorkerInit. The runtime
//! validates the blob when it starts (`Runtime.init` in
//! `worker/runtime/root.zig`), so a malformed blob fails the worker's boot
//! instead of its first request, and builds the object once per route, when
//! the route's module becomes ready (`worker/modules/routes.zig`). Every
//! request of the route then receives the same object.
//!
//! A worker holds one blob, the bindings of the route WorkerInit carried
//! (`RuntimeOptions.route_bindings_route`), which is the one route its
//! definition declares; the configuration parser refuses a second route
//! (`server/config/parse.zig`). `routes.zig` therefore builds an `env` from a
//! blob that holds bindings only for that route and fails any other, which
//! would otherwise receive those secrets.
//!
//! Building the object runs no JavaScript (`collo_env_object_new` in
//! `abi.h`), so it is safe outside a turn and no tenant setter observes a
//! binding while it is defined. `process.env` is a separate object the boot
//! installs empty; bindings never reach it.

const std = @import("std");
const bindings = @import("collo_bindings");
const ipc = @import("collo_ipc");
const js_value = @import("collo_worker_js").value;

const route_bindings = ipc.route_bindings;

/// The blob of a route with no bindings.
pub const empty_blob = route_bindings.empty_blob;

pub const Error = route_bindings.Error;

/// Checks `blob` without building anything (`route_bindings.decode`).
pub fn validate(blob: []const u8) Error!void {
    var entries: route_bindings.Entries = undefined;
    _ = try route_bindings.decode(blob, &entries);
}

/// Builds the frozen `env` object of a route from its bindings blob. The
/// caller owns the returned reference. Fails with `error.InvalidRouteBindings`
/// for a blob `route_bindings.decode` rejects, or with the bridge's error.
pub fn build(vm: *bindings.Vm, blob: []const u8) !js_value.JsObjectOwned {
    var entries: route_bindings.Entries = undefined;
    const decoded = try route_bindings.decode(blob, &entries);
    var pairs: [route_bindings.entries_max]bindings.NameValuePair = undefined;
    for (decoded, pairs[0..decoded.len]) |entry, *pair|
        pair.* = .{ .name = borrowedString(entry.name), .value = borrowedString(entry.value) };
    return js_value.JsObjectOwned.fromOwnedValue(try vm.envObjectValue(pairs[0..decoded.len]));
}

fn borrowedString(bytes: []const u8) bindings.RawString {
    return .{ .ptr = if (bytes.len == 0) null else bytes.ptr, .len = bytes.len };
}

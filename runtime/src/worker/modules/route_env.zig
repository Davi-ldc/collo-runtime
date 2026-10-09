//! A route's `env`, the second argument of its handler: a frozen object whose
//! own properties are the route's text bindings, names to string values in
//! configuration order. Runs in the worker on the VM thread.
//!
//! Each route's bindings arrive as one section of the definition's route
//! table, in the layout and under the rules of
//! `common/ipc/route_bindings.zig`; the server builds the table once per
//! definition (`server/routes/artifacts.zig`) and hands it over in
//! WorkerInit. The runtime checks the whole table when it starts
//! (`Modules.init` in `worker/runtime/modules.zig`), so a malformed section
//! fails the worker's boot instead of its first request, and `routes.zig`
//! builds the object once per route, in the route's realm, from that route's
//! section alone, when the route's module becomes ready. Every request of the
//! route then receives the same object, and no route ever receives another
//! route's bindings.
//!
//! Building the object runs no JavaScript (`collo_env_object_new` in
//! `abi.h`), so it is safe outside a turn and no tenant setter observes a
//! binding while it is defined. `process.env` is a separate object the boot
//! installs empty; bindings never reach it.

const bindings = @import("collo_bindings");
const ipc = @import("collo_ipc");
const js_value = @import("collo_worker_js").value;

const route_bindings = ipc.route_bindings;

/// Builds the frozen `env` object of a route, in the route's realm, from its
/// bindings section. The caller owns the returned reference. Fails with
/// `error.InvalidRouteBindings` for a section `route_bindings.decode`
/// rejects, or with the bridge's error.
pub fn build(realm: bindings.Realm, section: []const u8) !js_value.JsObjectOwned {
    var entries: route_bindings.Entries = undefined;
    const decoded = try route_bindings.decode(section, &entries);
    var pairs: [route_bindings.entries_max]bindings.NameValuePair = undefined;
    for (decoded, pairs[0..decoded.len]) |entry, *pair|
        pair.* = .{ .name = borrowedString(entry.name), .value = borrowedString(entry.value) };
    return js_value.JsObjectOwned.fromOwnedValue(try realm.envObjectValue(pairs[0..decoded.len]));
}

fn borrowedString(bytes: []const u8) bindings.RawString {
    return .{ .ptr = if (bytes.len == 0) null else bytes.ptr, .len = bytes.len };
}

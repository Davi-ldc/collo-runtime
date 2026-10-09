//! `collo_request_new`, through `Vm.requestValue`: the Request a handler
//! receives has the URL `https://<authority><path>`, with `?<raw_query>` when
//! the query is not empty, and a request without an authority or a request
//! id is refused before anything is built. Lane: `bindings-test`; the rest of
//! the handler's Request is covered in `worker-test`
//! (`worker/tests/runtime/server_api.zig`).

const std = @import("std");
const support = @import("bindings_support");
const bindings = support.bindings;

fn raw(value: []const u8) bindings.RawString {
    return .{ .ptr = if (value.len == 0) null else value.ptr, .len = value.len };
}

fn requestInit(authority: []const u8, path: []const u8, raw_query: []const u8, request_id: u64) bindings.RequestInit {
    return .{
        .method = raw("GET"),
        .path = raw(path),
        .raw_query = raw(raw_query),
        .authority = raw(authority),
        .headers = null,
        .headers_len = 0,
        .params = null,
        .params_len = 0,
        .identity = .{ .request_id = request_id, .request_generation = 1 },
    };
}

fn expectUrl(vm: *bindings.Vm, init: *const bindings.RequestInit, expected: []const u8) !void {
    var request = switch (try vm.requestValue(init)) {
        .success => |value| value,
        .exception => |exception| {
            var owned = exception;
            owned.deinit();
            return error.TestUnexpectedResult;
        },
    };
    defer request.deinit();

    var read_url = try support.getExportOk(vm, "/request-url.js", "readUrl");
    defer read_url.deinit();
    var exec_ctx = support.makeExecCtx(init.identity.request_id);
    try vm.turnEnter(&exec_ctx);
    defer vm.turnExit() catch {};
    var url = try support.invokeOk(vm, &exec_ctx, &read_url, &.{&request});
    defer url.deinit();
    try support.expectValueString(vm, &url, expected);
}

test "a handler's request url is https, its authority, the path and the query" {
    var vm = try support.createVm();
    defer vm.deinit();
    try support.registerModule(&vm, "/request-url.js",
        \\export function readUrl(request) {
        \\    return request.url;
        \\}
    );
    try support.evaluateOk(&vm, "/request-url.js");

    try expectUrl(&vm, &requestInit("demo.test", "/users/7", "a=1&a=2", 11), "https://demo.test/users/7?a=1&a=2");
    try expectUrl(&vm, &requestInit("[::1]:8443", "/", "", 12), "https://[::1]:8443/");
}

test "a request without an authority or a request id is refused" {
    var vm = try support.createVm();
    defer vm.deinit();

    try std.testing.expectError(error.InvalidArgument, vm.requestValue(&requestInit("", "/", "", 13)));
    try std.testing.expectError(error.InvalidArgument, vm.requestValue(&requestInit("demo.test", "/", "", 0)));
}

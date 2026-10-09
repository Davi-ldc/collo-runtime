//! WebCrypto's request check: a `crypto.subtle` call made with no active request, here from
//! module top-level code on a VM with no host runtime and no boot context, rejects with an
//! OperationError before any job runs (`enqueueCryptoJobPromise` in
//! `host_functions/webapi/crypto/jobs.cpp`). That holds even for a digest small enough to run
//! inline (`inlineDigestByteLimit` in `host_functions/webapi/crypto/types.h`, checked in
//! `subtle/digest.cpp`). WebCrypto inside a request is covered by the `webapi` lane's
//! `runtime/tests/webapi/crypto/`.

const std = @import("std");
const support = @import("bindings_support");

test "WebCrypto inline jobs require an active request turn" {
    var vm = try support.createVm();
    defer vm.deinit();

    const source =
        \\export const promise = crypto.subtle.digest("SHA-256", new Uint8Array([1, 2, 3]));
    ;

    try support.registerModule(&vm, "/webcrypto-outside-turn.js", source);
    try support.evaluateOk(&vm, "/webcrypto-outside-turn.js");

    var promise = try support.getExportOk(&vm, "/webcrypto-outside-turn.js", "promise");
    defer promise.deinit();

    var exception = switch (try vm.promiseAwaitSync(&promise)) {
        .success => |value| {
            var owned_value = value;
            defer owned_value.deinit();
            return error.ExpectedWebCryptoRejection;
        },
        .exception => |exception_value| exception_value,
        .unsupported => |unsupported_value| {
            var owned_value = unsupported_value;
            defer owned_value.deinit();
            return error.ExpectedWebCryptoRejection;
        },
    };
    defer exception.deinit();

    try support.expectExceptionContains(&vm, &exception, "OperationError");
    try support.expectExceptionContains(&vm, &exception, "active request turn");
}

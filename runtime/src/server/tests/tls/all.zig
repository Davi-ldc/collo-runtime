//! Collects the suites of the server's TLS layer (`server/tls/`): the
//! BoringSSL context, ALPN, the kTLS policy and key export in `root.zig`, and
//! the generated certificate in `self_signed.zig`. Lane `server-core-test`.

comptime {
    _ = @import("root.zig");
    _ = @import("self_signed.zig");
}

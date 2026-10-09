//! Receive-path modes for the BIO TLS transport. No code reads them:
//! `TlsBioTransport` always behaves as `memory_bio`.

pub const TlsRxMode = enum {
    /// Ciphertext is copied into BoringSSL's memory read BIO before
    /// `SSL_read()` sees it.
    memory_bio,
    /// Ciphertext stays in Collo-owned leases that a custom BoringSSL read
    /// BIO consumes in place. Not implemented.
    custom_bio,
};

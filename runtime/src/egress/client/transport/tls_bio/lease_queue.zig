//! Reserved for ciphertext lease ownership in the `custom_bio` receive mode
//! (`config.TlsRxMode`). It holds no code: the BIO transport copies received
//! ciphertext into BoringSSL's memory read BIO instead.


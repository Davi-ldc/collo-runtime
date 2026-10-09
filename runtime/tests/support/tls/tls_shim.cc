// Test-only BoringSSL harness, linked into the test and benchmark binaries that call it through `shim.zig` in this
// directory (`configureBoringSslTestShim` in `runtime/build/shims.zig`). It holds throwaway TLS material, local h2
// and TLS origins for the egress client suites and benchmarks, the h2 client that drives a Collo server in local-e2e
// and the serve smoke, and handshakes against the production BoringSSL shim (ALPN and the kTLS cipher policies).
//
// Every function runs on its caller's thread, except an origin's accept loop, which runs on a thread the origin
// starts. A failed call returns nonzero and leaves its reason in a buffer of the calling thread
// (collo_test_tls_last_error); an origin's thread keeps its own. TLS material is a set of files under /tmp that
// lives until collo_test_tls_material_cleanup. An origin is heap memory the caller owns from its start function to
// the matching stop, which joins the origin's thread and removes the origin's own material.

#include <openssl/err.h>
#include <openssl/mem.h>
#include <openssl/ssl.h>

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#include <new>

// The production BoringSSL shim (`runtime/src/bindings/boringssl/shim.cc`) has no header, so its types, functions
// and constants are repeated here as it defines them. A change to one of them there must be copied here. The ALPN
// offer values are not copied: the callers of run_egress_client_alpn_case pass them as literals.
// FIXME: no shared header and no static_assert of collo_boringssl_result's layout tie these copies to the production
// shim, so drift from it compiles silently.
struct collo_boringssl_ctx;
struct collo_boringssl_conn;
struct collo_boringssl_client_ctx;
struct collo_boringssl_client_conn;

struct collo_boringssl_result {
    int status;
    uint16_t tls_version;
    uint8_t application_protocol;
    uint8_t reserved0;
    uint32_t cipher_id;
};

extern "C" int collo_boringssl_ctx_new_ex(const char* cert_chain_path, const char* private_key_path,
    const char* tls12_cipher_list, int tls13_policy, struct collo_boringssl_ctx** out);
extern "C" void collo_boringssl_ctx_free(struct collo_boringssl_ctx* ctx);
extern "C" int collo_boringssl_conn_new(struct collo_boringssl_ctx* ctx, int fd, struct collo_boringssl_conn** out);
extern "C" void collo_boringssl_conn_free(struct collo_boringssl_conn* conn);
extern "C" int collo_boringssl_handshake_step(struct collo_boringssl_conn* conn, struct collo_boringssl_result* result);
extern "C" int collo_boringssl_test_tls13_policy_cipher_flags(void);
extern "C" int collo_boringssl_client_ctx_new(int insecure_skip_verify, struct collo_boringssl_client_ctx** out);
extern "C" void collo_boringssl_client_ctx_free(struct collo_boringssl_client_ctx* ctx);
extern "C" int collo_boringssl_client_conn_new(struct collo_boringssl_client_ctx* ctx, int fd, const char* server_name,
    int alpn_offer, const uint8_t* session_key, size_t session_key_len, struct collo_boringssl_client_conn** out);
extern "C" void collo_boringssl_client_conn_free(struct collo_boringssl_client_conn* conn);
extern "C" int collo_boringssl_client_handshake_step(
    struct collo_boringssl_client_conn* conn, struct collo_boringssl_result* result);

enum {
    COLLO_BORINGSSL_OK = 0,
    COLLO_BORINGSSL_WANT_READ = 1,
    COLLO_BORINGSSL_WANT_WRITE = 2,
};

enum {
    COLLO_BORINGSSL_ALPN_UNSPECIFIED = 0,
    COLLO_BORINGSSL_ALPN_HTTP_1_1 = 1,
    COLLO_BORINGSSL_ALPN_H2 = 2,
};

enum {
    COLLO_TLS13_POLICY_ALL_SUPPORTED = 0,
    COLLO_TLS13_POLICY_AES_GCM_ONLY = 1,
    COLLO_TLS13_POLICY_DISABLED = 2,
};

static const char collo_test_tls12_cipher_list[] = "ECDHE-RSA-AES128-GCM-SHA256:"
                                                   "ECDHE-ECDSA-AES128-GCM-SHA256:"
                                                   "ECDHE-RSA-AES256-GCM-SHA384:"
                                                   "ECDHE-ECDSA-AES256-GCM-SHA384";

// The negotiated version is the wire value: 0x0303 for TLS 1.2, 0x0304 for
// TLS 1.3.
struct collo_test_tls_policy_result {
    int aes_gcm_only_tls_version;
    int tls13_disabled_tls_version;
    int tls13_policy_cipher_flags_ok;
};

struct collo_test_tls_alpn_result {
    int h2_protocol;
    int http11_protocol;
    int unsupported_protocol;
};

struct collo_test_egress_tls_alpn_result {
    int h2_protocol;
    int http11_protocol;
};

struct collo_test_h2_server_result {
    uint64_t get_body_len;
    uint64_t post_body_len;
    uint64_t large_body_len;
    uint64_t data_frame_count;
    uint64_t header_frame_count;
    char get_body[1024];
    char post_body[1024];
};

// Mirrored field for field by TlsMaterial in runtime/tests/support/tls/shim.zig, which declares this file's exports
// for Zig. Every path is NUL-terminated inside its array.
struct TempFiles {
    char dir[128];
    char ca[160];
    char server_cert[160];
    char server_key[160];
};

// One origin and the thread that serves its single connection. That thread writes client_fd, selected_alpn,
// stream_count and error; collo_test_h2_origin_stop joins it before freeing the struct.
// FIXME: collo_test_h2_origin_stop shuts down and closes client_fd before the join, racing the thread, which closes
// it too. collo_test_h2_origin_stream_count reads stream_count unsynchronized, and the thread counts a response only
// after sending it, so a caller that has just read a response can see one too few.
struct collo_test_h2_origin_server {
    TempFiles files;
    pthread_t thread;
    int listen_fd;
    int client_fd;
    uint16_t port;
    int alpn_mode;
    int thread_started;
    int selected_alpn;
    uint32_t stream_count;
    uint32_t expected_stream_count;
    size_t response_body_bytes;
    int benchmark_mode;
    // When set, every response carries a literal `content-encoding: gzip` header and serves encoded_body verbatim,
    // bytes the caller already compressed.
    int content_encoding_gzip;
    size_t encoded_body_len;
    uint8_t encoded_body[4096];
    char error[512];
};

enum {
    COLLO_TEST_H2_ORIGIN_ALPN_H2 = 0,
    COLLO_TEST_H2_ORIGIN_ALPN_HTTP11 = 1,
};

static thread_local char tls_test_error[512];

static int fail(const char* message)
{
    uint32_t err = ERR_peek_last_error();
    if (err != 0) {
        char detail[256];
        ERR_error_string_n(err, detail, sizeof(detail));
        snprintf(tls_test_error, sizeof(tls_test_error), "%s: %s", message, detail);
    } else {
        snprintf(tls_test_error, sizeof(tls_test_error), "%s", message);
    }
    return -1;
}

// For a failed system call, whose reason is errno rather than the BoringSSL
// error queue.
static int fail_errno(const char* message)
{
    snprintf(tls_test_error, sizeof(tls_test_error), "%s: %s", message, strerror(errno));
    return -1;
}

extern "C" const char* collo_test_tls_last_error(void) { return tls_test_error; }

static const char test_ca_pem[] = "-----BEGIN CERTIFICATE-----\n"
                                  "MIIBmDCCAT6gAwIBAgIURDWCm+7PR5xUcw2GMbkzTaP9FiMwCgYIKoZIzj0EAwIw\n"
                                  "GDEWMBQGA1UEAwwNQ29sbG8gVGVzdCBDQTAeFw0yNjA1MTMwMjQ4MjhaFw0zNjA1\n"
                                  "MTAwMjQ4MjhaMBgxFjAUBgNVBAMMDUNvbGxvIFRlc3QgQ0EwWTATBgcqhkjOPQIB\n"
                                  "BggqhkjOPQMBBwNCAAS1ansy3o0RTOOqp9mmr9Ddr5dcK2smGvhN+NVDUjO+wE/7\n"
                                  "bt9T0d6zNqXxlGC9rKO/lZ2doyY1aHU0fbHU6eLto2YwZDAdBgNVHQ4EFgQUWeNj\n"
                                  "mEunfkeolKsK2PR8Wor/HBMwHwYDVR0jBBgwFoAUWeNjmEunfkeolKsK2PR8Wor/\n"
                                  "HBMwEgYDVR0TAQH/BAgwBgEB/wIBADAOBgNVHQ8BAf8EBAMCAQYwCgYIKoZIzj0E\n"
                                  "AwIDSAAwRQIgWknWxP3BluHBWD/FbO/8RIQCdnhN3k5bbOZsVpc0vcsCIQD5c9VG\n"
                                  "LdcauKTqLQtIGgcjk8vBasoRiKK0suMoma88eg==\n"
                                  "-----END CERTIFICATE-----\n";

static const char test_server_cert_pem[] = "-----BEGIN CERTIFICATE-----\n"
                                           "MIICBjCCAaygAwIBAgIUQ5fx+RiwnspylCKC0QDwz2kaoGAwCgYIKoZIzj0EAwIw\n"
                                           "GDEWMBQGA1UEAwwNQ29sbG8gVGVzdCBDQTAeFw0yNjA1MTMwMjQ4MjhaFw0zNjA1\n"
                                           "MTAwMjQ4MjhaMBkxFzAVBgNVBAMMDnB1YmxpYy5leGFtcGxlMFkwEwYHKoZIzj0C\n"
                                           "AQYIKoZIzj0DAQcDQgAEKoqKcVXsYm4l18TDNdKKcGLV/ePZBWFOm+ulhQd0ckud\n"
                                           "tclm4qorUP6/N1RAbvqVMipwFEEjkOQwd6ApE10rL6OB0jCBzzAMBgNVHRMBAf8E\n"
                                           "AjAAMA4GA1UdDwEB/wQEAwIHgDATBgNVHSUEDDAKBggrBgEFBQcDATBaBgNVHREE\n"
                                           "UzBRgg5wdWJsaWMuZXhhbXBsZYIUdmlzaWJsZS5leGFtcGxlLnRlc3SCFHByaXZh\n"
                                           "dGUuZXhhbXBsZS50ZXN0ghNzZWNyZXQuZXhhbXBsZS50ZXN0MB0GA1UdDgQWBBTD\n"
                                           "9ErWlI10XYtNvLjM5NlMdP7eyjAfBgNVHSMEGDAWgBRZ42OYS6d+R6iUqwrY9Hxa\n"
                                           "iv8cEzAKBggqhkjOPQQDAgNIADBFAiEAiImGbZC66AcESwxmsZhDlAo2b5crBxjh\n"
                                           "zk/SekKb44gCID1K94T7kY1RreA05puQ6Q4ONZOfJOJlyNYo5pWU2giB\n"
                                           "-----END CERTIFICATE-----\n";

static const char test_server_key_pem[] = "-----BEGIN EC PRIVATE KEY-----\n"
                                          "MHcCAQEEIHOLdElJrG8GzNeXYapu5Ony94W9g/MsEz/WTqGQN1m1oAoGCCqGSM49\n"
                                          "AwEHoUQDQgAEKoqKcVXsYm4l18TDNdKKcGLV/ePZBWFOm+ulhQd0ckudtclm4qor\n"
                                          "UP6/N1RAbvqVMipwFEEjkOQwd6ApE10rLw==\n"
                                          "-----END EC PRIVATE KEY-----\n";

static void path_join(char* out, size_t out_len, const char* dir, const char* name)
{
    snprintf(out, out_len, "%s/%s", dir, name);
}

static int write_file(const char* path, const void* data, size_t len)
{
    FILE* file = fopen(path, "wb");
    if (file == NULL) {
        return fail("open test file");
    }
    if (fwrite(data, 1, len, file) != len) {
        fclose(file);
        return fail("write test file");
    }
    if (fclose(file) != 0) {
        return fail("close test file");
    }
    return 0;
}

static int init_temp_files(TempFiles* files)
{
    snprintf(files->dir, sizeof(files->dir), "/tmp/collo_tls_test_XXXXXX");
    if (mkdtemp(files->dir) == NULL) {
        return fail("create temp dir");
    }
    path_join(files->ca, sizeof(files->ca), files->dir, "ca.pem");
    path_join(files->server_cert, sizeof(files->server_cert), files->dir, "server.pem");
    path_join(files->server_key, sizeof(files->server_key), files->dir, "server.key");
    if (write_file(files->ca, test_ca_pem, strlen(test_ca_pem)) != 0
        || write_file(files->server_cert, test_server_cert_pem, strlen(test_server_cert_pem)) != 0
        || write_file(files->server_key, test_server_key_pem, strlen(test_server_key_pem)) != 0) {
        return -1;
    }
    return 0;
}

static void cleanup_temp_files(const TempFiles* files);

extern "C" int collo_test_tls_material_create(TempFiles* files)
{
    if (files == NULL) {
        return fail("missing TLS material output");
    }
    tls_test_error[0] = '\0';
    ERR_clear_error();
    memset(files, 0, sizeof(*files));
    return init_temp_files(files);
}

extern "C" void collo_test_tls_material_cleanup(TempFiles* files)
{
    if (files == NULL) {
        return;
    }
    cleanup_temp_files(files);
    memset(files, 0, sizeof(*files));
}

static void cleanup_temp_files(const TempFiles* files)
{
    unlink(files->ca);
    unlink(files->server_cert);
    unlink(files->server_key);
    rmdir(files->dir);
}

// A client context that verifies the server's chain against the test CA in `files`. It sets no host name, so a
// connection checks one only if it adds it with SSL_set1_host, as run_handshake_case does. The h2 client adds none,
// so the harness authority, which the test server certificate does not name, still verifies. Returns NULL on failure.
static SSL_CTX* new_client_context(const TempFiles* files)
{
    SSL_CTX* ctx = SSL_CTX_new(TLS_client_method());
    if (ctx == NULL) {
        return NULL;
    }
    if (SSL_CTX_load_verify_locations(ctx, files->ca, NULL) != 1) {
        SSL_CTX_free(ctx);
        return NULL;
    }
    SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);
    return ctx;
}

// Whether a failed SSL_read or SSL_write may simply be called again. Every
// socket ssl_write_all and ssl_read_exact drive is blocking with SO_SNDTIMEO
// and SO_RCVTIMEO set, so BoringSSL asks for a retry only when the timeout
// expired or a signal interrupted the call, and only the second is retried.
static bool ssl_io_interrupted(SSL* ssl, int ret, int* out_error)
{
    *out_error = SSL_get_error(ssl, ret);
    const bool retry = *out_error == SSL_ERROR_WANT_READ || *out_error == SSL_ERROR_WANT_WRITE;
    return retry && errno == EINTR;
}

static int ssl_write_all(SSL* ssl, const void* bytes, size_t len)
{
    const uint8_t* cursor = static_cast<const uint8_t*>(bytes);
    while (len != 0) {
        int written = SSL_write(ssl, cursor, len > INT32_MAX ? INT32_MAX : static_cast<int>(len));
        if (written <= 0) {
            int err = SSL_ERROR_NONE;
            if (ssl_io_interrupted(ssl, written, &err)) {
                continue;
            }
            const bool timed_out = err == SSL_ERROR_WANT_READ || err == SSL_ERROR_WANT_WRITE;
            return fail(timed_out ? "TLS write timed out" : "TLS write failed");
        }
        cursor += written;
        len -= static_cast<size_t>(written);
    }
    return 0;
}

static int ssl_read_exact(SSL* ssl, void* bytes, size_t len)
{
    uint8_t* cursor = static_cast<uint8_t*>(bytes);
    while (len != 0) {
        int read_len = SSL_read(ssl, cursor, len > INT32_MAX ? INT32_MAX : static_cast<int>(len));
        if (read_len <= 0) {
            int err = SSL_ERROR_NONE;
            if (ssl_io_interrupted(ssl, read_len, &err)) {
                continue;
            }
            const bool timed_out = err == SSL_ERROR_WANT_READ || err == SSL_ERROR_WANT_WRITE;
            return fail(timed_out ? "TLS read timed out" : "TLS read failed");
        }
        cursor += read_len;
        len -= static_cast<size_t>(read_len);
    }
    return 0;
}

static void write_u16(uint8_t* out, uint16_t value)
{
    out[0] = static_cast<uint8_t>(value >> 8);
    out[1] = static_cast<uint8_t>(value);
}

static void write_u24(uint8_t* out, uint32_t value)
{
    out[0] = static_cast<uint8_t>(value >> 16);
    out[1] = static_cast<uint8_t>(value >> 8);
    out[2] = static_cast<uint8_t>(value);
}

static void write_u31(uint8_t* out, uint32_t value)
{
    out[0] = static_cast<uint8_t>((value >> 24) & 0x7f);
    out[1] = static_cast<uint8_t>(value >> 16);
    out[2] = static_cast<uint8_t>(value >> 8);
    out[3] = static_cast<uint8_t>(value);
}

static uint32_t read_u24(const uint8_t* in)
{
    return (static_cast<uint32_t>(in[0]) << 16) | (static_cast<uint32_t>(in[1]) << 8) | static_cast<uint32_t>(in[2]);
}

static uint32_t read_u31(const uint8_t* in)
{
    return ((static_cast<uint32_t>(in[0]) & 0x7f) << 24) | (static_cast<uint32_t>(in[1]) << 16)
        | (static_cast<uint32_t>(in[2]) << 8) | static_cast<uint32_t>(in[3]);
}

static uint32_t read_u32(const uint8_t* in)
{
    return (static_cast<uint32_t>(in[0]) << 24) | (static_cast<uint32_t>(in[1]) << 16)
        | (static_cast<uint32_t>(in[2]) << 8) | static_cast<uint32_t>(in[3]);
}

static void write_u32(uint8_t* out, uint32_t value)
{
    out[0] = static_cast<uint8_t>(value >> 24);
    out[1] = static_cast<uint8_t>(value >> 16);
    out[2] = static_cast<uint8_t>(value >> 8);
    out[3] = static_cast<uint8_t>(value);
}

static int h2_write_frame(
    SSL* ssl, uint8_t type, uint8_t flags, uint32_t stream_id, const void* payload, size_t payload_len)
{
    if (payload_len > 0xffffff) {
        return fail("HTTP/2 test frame too large");
    }
    uint8_t header[9];
    write_u24(header, static_cast<uint32_t>(payload_len));
    header[3] = type;
    header[4] = flags;
    write_u31(header + 5, stream_id);
    if (ssl_write_all(ssl, header, sizeof(header)) != 0) {
        return -1;
    }
    if (payload_len != 0 && ssl_write_all(ssl, payload, payload_len) != 0) {
        return -1;
    }
    return 0;
}

static int h2_write_setting(uint8_t* out, uint16_t id, uint32_t value)
{
    write_u16(out, id);
    write_u32(out + 2, value);
    return 6;
}

// An HPACK integer (RFC 7541 section 5.1): `flags` fill the first byte above
// its `prefix_bits`-bit prefix, and a value that does not fit below the
// all-ones prefix continues in 7-bit groups. Returns the bytes written, or -1
// when they do not fit in `out_cap`.
static int hpack_write_integer(uint8_t* out, size_t out_cap, uint8_t flags, unsigned prefix_bits, size_t value)
{
    const size_t prefix_max = (static_cast<size_t>(1) << prefix_bits) - 1;
    size_t cursor = 0;
    if (out_cap == 0) {
        return -1;
    }
    if (value < prefix_max) {
        out[cursor++] = static_cast<uint8_t>(flags | value);
        return static_cast<int>(cursor);
    }
    out[cursor++] = static_cast<uint8_t>(flags | prefix_max);
    value -= prefix_max;
    while (value >= 0x80) {
        if (cursor == out_cap) {
            return -1;
        }
        out[cursor++] = static_cast<uint8_t>(0x80 | (value & 0x7f));
        value >>= 7;
    }
    if (cursor == out_cap) {
        return -1;
    }
    out[cursor++] = static_cast<uint8_t>(value);
    return static_cast<int>(cursor);
}

// A string literal without Huffman coding (RFC 7541 section 5.2): the length
// as a 7-bit-prefix integer, then the bytes. Any length that fits in `out_cap`
// is encodable, so a request path is bounded only by the caller's header
// block buffer.
static int h2_write_string(uint8_t* out, size_t out_cap, const char* bytes, size_t len)
{
    const int prefix_len = hpack_write_integer(out, out_cap, 0x00, 7, len);
    if (prefix_len < 0 || out_cap - static_cast<size_t>(prefix_len) < len) {
        return -1;
    }
    memcpy(out + prefix_len, bytes, len);
    return prefix_len + static_cast<int>(len);
}

// A literal header field without indexing whose name is a static-table entry
// (RFC 7541 section 6.2.2): the index as a 4-bit-prefix integer, then the
// value.
static int h2_write_literal_indexed_name(uint8_t* out, size_t out_cap, uint8_t name_index, const char* value)
{
    const int index_len = hpack_write_integer(out, out_cap, 0x00, 4, name_index);
    if (index_len < 0) {
        return -1;
    }
    const int value_len
        = h2_write_string(out + index_len, out_cap - static_cast<size_t>(index_len), value, strlen(value));
    if (value_len < 0) {
        return -1;
    }
    return index_len + value_len;
}

// A literal header field without indexing with a new name (RFC 7541 section 6.2.2): a zero byte, then the name and
// the value as string literals.
static int h2_write_literal_new_name(uint8_t* out, size_t out_cap, const char* name, const char* value)
{
    if (out_cap < 1) {
        return -1;
    }
    size_t cursor = 0;
    out[cursor++] = 0;
    int name_len = h2_write_string(out + cursor, out_cap - cursor, name, strlen(name));
    if (name_len < 0) {
        return -1;
    }
    cursor += static_cast<size_t>(name_len);
    int value_len = h2_write_string(out + cursor, out_cap - cursor, value, strlen(value));
    if (value_len < 0) {
        return -1;
    }
    cursor += static_cast<size_t>(value_len);
    return static_cast<int>(cursor);
}

// The HEADERS block of a request: indexed :method and :scheme, then literal
// :authority, :path and, when set, content-length. Literals are never
// indexed, so a block depends on no earlier one.
static int h2_build_request_headers(uint8_t* out, size_t out_cap, const char* method, const char* authority,
    const char* path, const char* content_length)
{
    size_t cursor = 0;
    // The indexed :method and :scheme fields take one byte each.
    if (out_cap < 2) {
        return fail("encode request pseudo-headers");
    }
    if (strcmp(method, "GET") == 0) {
        out[cursor++] = 0x82;
    } else if (strcmp(method, "POST") == 0) {
        out[cursor++] = 0x83;
    } else {
        return fail("unsupported HTTP/2 test method");
    }
    out[cursor++] = 0x87;
    int wrote = h2_write_literal_indexed_name(out + cursor, out_cap - cursor, 0x01, authority);
    if (wrote < 0) {
        return fail("encode :authority");
    }
    cursor += static_cast<size_t>(wrote);
    wrote = h2_write_literal_indexed_name(out + cursor, out_cap - cursor, 0x04, path);
    if (wrote < 0) {
        return fail("encode :path");
    }
    cursor += static_cast<size_t>(wrote);
    if (content_length != NULL) {
        wrote = h2_write_literal_new_name(out + cursor, out_cap - cursor, "content-length", content_length);
        if (wrote < 0) {
            return fail("encode content-length");
        }
        cursor += static_cast<size_t>(wrote);
    }
    return static_cast<int>(cursor);
}

// Copies what fits of `payload` after the `*len` bytes already in `dst`, and adds the whole payload to `*len`, which
// therefore ends as the body's full length even when that exceeds `dst_cap`.
static int append_body_sample(char* dst, size_t dst_cap, uint64_t* len, const uint8_t* payload, size_t payload_len)
{
    if (*len < dst_cap) {
        size_t copy_len = payload_len;
        if (copy_len > dst_cap - static_cast<size_t>(*len)) {
            copy_len = dst_cap - static_cast<size_t>(*len);
        }
        memcpy(dst + *len, payload, copy_len);
    }
    *len += payload_len;
    return 0;
}

static void h2_origin_set_error(struct collo_test_h2_origin_server* server, const char* message)
{
    uint32_t err = ERR_peek_last_error();
    if (err != 0) {
        char detail[256];
        ERR_error_string_n(err, detail, sizeof(detail));
        snprintf(server->error, sizeof(server->error), "%s: %s", message, detail);
    } else {
        snprintf(server->error, sizeof(server->error), "%s", message);
    }
}

static int h2_origin_select_alpn(SSL*, const uint8_t** out, uint8_t* out_len, const uint8_t*, unsigned, void* arg)
{
    static const uint8_t h2[] = { 'h', '2' };
    static const uint8_t http11[] = { 'h', 't', 't', 'p', '/', '1', '.', '1' };
    const int mode = arg == NULL ? COLLO_TEST_H2_ORIGIN_ALPN_H2 : *static_cast<int*>(arg);
    if (mode == COLLO_TEST_H2_ORIGIN_ALPN_HTTP11) {
        *out = http11;
        *out_len = sizeof(http11);
        return SSL_TLSEXT_ERR_OK;
    }
    *out = h2;
    *out_len = sizeof(h2);
    return SSL_TLSEXT_ERR_OK;
}

static int h2_origin_send_response(SSL* ssl, const struct collo_test_h2_origin_server* server, uint32_t stream_id)
{
    static const uint8_t response_headers[] = { 0x88 }; // :status: 200
    static const uint8_t benchmark_body[16384] = { 'x' };
    if (server->content_encoding_gzip) {
        uint8_t encoded_headers[64];
        size_t encoded_headers_len = 0;
        encoded_headers[encoded_headers_len++] = 0x88; // :status: 200
        int wrote = h2_write_literal_new_name(encoded_headers + encoded_headers_len,
            sizeof(encoded_headers) - encoded_headers_len, "content-encoding", "gzip");
        if (wrote < 0) {
            return -1;
        }
        encoded_headers_len += static_cast<size_t>(wrote);
        if (h2_write_frame(ssl, 0x1, 0x4, stream_id, encoded_headers, encoded_headers_len) != 0) {
            return -1;
        }
        return h2_write_frame(ssl, 0x0, 0x1, stream_id, server->encoded_body, server->encoded_body_len);
    }
    if (server->benchmark_mode) {
        if (h2_write_frame(ssl, 0x1, 0x4, stream_id, response_headers, sizeof(response_headers)) != 0) {
            return -1;
        }
        // The first stream only primes SETTINGS and WINDOW_UPDATE before the timed workload, so it carries no body
        // bytes for the benchmark to count.
        size_t remaining = server->stream_count == 0 ? 0 : server->response_body_bytes;
        do {
            const size_t chunk_len = remaining > sizeof(benchmark_body) ? sizeof(benchmark_body) : remaining;
            const uint8_t flags = chunk_len == remaining ? 0x1 : 0;
            if (h2_write_frame(ssl, 0x0, flags, stream_id, benchmark_body, chunk_len) != 0) {
                return -1;
            }
            remaining -= chunk_len;
        } while (remaining != 0);
        return 0;
    }
    const char* body = stream_id == 1 ? "one" : "two";
    if (h2_write_frame(ssl, 0x1, 0x4, stream_id, response_headers, sizeof(response_headers)) != 0) {
        return -1;
    }
    return h2_write_frame(ssl, 0x0, 0x1, stream_id, body, strlen(body));
}

static int h2_origin_handle_http11(SSL* ssl, struct collo_test_h2_origin_server* server)
{
    char request[4096];
    size_t request_len = 0;
    while (request_len < sizeof(request)) {
        int read_len = SSL_read(ssl, request + request_len, 1);
        if (read_len <= 0) {
            int err = SSL_get_error(ssl, read_len);
            if (err == SSL_ERROR_WANT_READ || err == SSL_ERROR_WANT_WRITE) {
                continue;
            }
            h2_origin_set_error(server, "read local HTTP/1.1 origin request");
            return -1;
        }
        request_len += static_cast<size_t>(read_len);
        if (request_len >= 4 && memcmp(request + request_len - 4, "\r\n\r\n", 4) == 0) {
            break;
        }
    }
    if (request_len < 4 || memcmp(request + request_len - 4, "\r\n\r\n", 4) != 0) {
        h2_origin_set_error(server, "local HTTP/1.1 origin request headers too large");
        return -1;
    }

    static const char response[] = "HTTP/1.1 200 OK\r\n"
                                   "content-length: 8\r\n"
                                   "connection: close\r\n"
                                   "\r\n"
                                   "fallback";
    if (ssl_write_all(ssl, response, sizeof(response) - 1) != 0) {
        h2_origin_set_error(server, "write local HTTP/1.1 origin response");
        return -1;
    }
    server->stream_count = 1;
    return 0;
}

static void* h2_origin_thread_main(void* arg)
{
    struct collo_test_h2_origin_server* server = static_cast<struct collo_test_h2_origin_server*>(arg);
    SSL_CTX* ctx = NULL;
    SSL* ssl = NULL;
    int client_fd = -1;
    uint8_t frame_header[9];
    uint8_t payload[65535];
    uint32_t responses_sent = 0;
    size_t max_frames = 0;
    struct timeval timeout;
    const uint8_t* selected = NULL;
    unsigned selected_len = 0;

    ERR_clear_error();

    ctx = SSL_CTX_new(TLS_server_method());
    if (ctx == NULL || SSL_CTX_use_certificate_chain_file(ctx, server->files.server_cert) != 1
        || SSL_CTX_use_PrivateKey_file(ctx, server->files.server_key, SSL_FILETYPE_PEM) != 1
        || SSL_CTX_check_private_key(ctx) != 1) {
        h2_origin_set_error(server, "create local HTTP/2 origin TLS context");
        goto done;
    }
    SSL_CTX_set_alpn_select_cb(ctx, h2_origin_select_alpn, &server->alpn_mode);

    client_fd = accept(server->listen_fd, NULL, NULL);
    if (client_fd < 0) {
        h2_origin_set_error(server, "accept local HTTP/2 origin connection");
        goto done;
    }
    server->client_fd = client_fd;
    timeout.tv_sec = 15;
    timeout.tv_usec = 0;
    setsockopt(client_fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(client_fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    // Nagle's algorithm would hold small response frames behind the client's delayed ACKs, about 40 ms each, and
    // put that delay into benchmark latency tails. The egress client disables it on its side, and a production
    // origin would disable it too.
    int origin_nodelay;
    origin_nodelay = 1;
    setsockopt(client_fd, IPPROTO_TCP, TCP_NODELAY, &origin_nodelay, sizeof(origin_nodelay));

    ssl = SSL_new(ctx);
    if (ssl == NULL || SSL_set_fd(ssl, client_fd) != 1) {
        h2_origin_set_error(server, "create local HTTP/2 origin TLS connection");
        goto done;
    }
    if (SSL_accept(ssl) != 1) {
        h2_origin_set_error(server, "local HTTP/2 origin TLS accept");
        goto done;
    }
    SSL_get0_alpn_selected(ssl, &selected, &selected_len);
    server->selected_alpn
        = selected_len == 2 && memcmp(selected, "h2", 2) == 0 ? COLLO_BORINGSSL_ALPN_H2 : COLLO_BORINGSSL_ALPN_HTTP_1_1;
    if (server->selected_alpn != COLLO_BORINGSSL_ALPN_H2) {
        if (h2_origin_handle_http11(ssl, server) != 0) {
            goto done;
        }
        responses_sent = server->expected_stream_count;
        goto done;
    }

    static const char preface[] = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
    if (ssl_read_exact(ssl, payload, sizeof(preface) - 1) != 0 || memcmp(payload, preface, sizeof(preface) - 1) != 0) {
        h2_origin_set_error(server, "read local HTTP/2 client preface");
        goto done;
    }
    if (server->benchmark_mode) {
        // Wider windows make large request bodies measure transport throughput instead of flow-control stalls. The
        // client applies them while the priming stream runs, before the timed streams.
        static const uint8_t benchmark_settings[] = {
            0x00, 0x04, 0x00, 0x10, 0x00, 0x00 // INITIAL_WINDOW_SIZE = 1 MiB
        };
        static const uint8_t benchmark_connection_window[] = {
            0x00, 0x0f, 0x00, 0x01 // add 1 MiB - HTTP/2 default window
        };
        if (h2_write_frame(ssl, 0x4, 0, 0, benchmark_settings, sizeof(benchmark_settings)) != 0
            || h2_write_frame(ssl, 0x8, 0, 0, benchmark_connection_window, sizeof(benchmark_connection_window)) != 0) {
            h2_origin_set_error(server, "write local HTTP/2 benchmark setup");
            goto done;
        }
    } else if (h2_write_frame(ssl, 0x4, 0, 0, NULL, 0) != 0) {
        h2_origin_set_error(server, "write local HTTP/2 origin SETTINGS");
        goto done;
    }

    max_frames = static_cast<size_t>(server->expected_stream_count) * 64 + 256;
    for (size_t frame_count = 0; frame_count < max_frames && responses_sent < server->expected_stream_count;
        frame_count++) {
        if (ssl_read_exact(ssl, frame_header, sizeof(frame_header)) != 0) {
            h2_origin_set_error(server, "local HTTP/2 origin frame-header read failed");
            goto done;
        }
        const uint32_t length = read_u24(frame_header);
        const uint8_t type = frame_header[3];
        const uint8_t flags = frame_header[4];
        const uint32_t stream_id = read_u31(frame_header + 5);
        if (length > sizeof(payload)) {
            h2_origin_set_error(server, "local HTTP/2 origin frame too large");
            goto done;
        }
        if (ssl_read_exact(ssl, payload, length) != 0) {
            h2_origin_set_error(server, "local HTTP/2 origin frame-payload read failed");
            goto done;
        }
        if (type == 0x4) {
            if ((flags & 0x1) == 0 && h2_write_frame(ssl, 0x4, 0x1, 0, NULL, 0) != 0) {
                h2_origin_set_error(server, "write local HTTP/2 origin SETTINGS ack");
                goto done;
            }
            continue;
        }
        if (stream_id == 0) {
            continue;
        }
        if ((type == 0x1 || type == 0x0) && (flags & 0x1) != 0) {
            if (h2_origin_send_response(ssl, server, stream_id) != 0) {
                h2_origin_set_error(server, "write local HTTP/2 origin response");
                goto done;
            }
            responses_sent++;
            server->stream_count = responses_sent;
        }
    }
    if (responses_sent < server->expected_stream_count) {
        h2_origin_set_error(server, "local HTTP/2 origin did not receive all streams");
    }

done:
    if (ssl != NULL && client_fd >= 0 && responses_sent == server->expected_stream_count) {
        // Close with FIN, not RST. Client frames still unread in this socket's receive buffer, such as WINDOW_UPDATE,
        // would turn close() into a reset, and a reset discards response bytes the client has not yet read from its
        // own socket buffer.
        SSL_shutdown(ssl);
        shutdown(client_fd, SHUT_WR);
        struct timeval drain_timeout;
        drain_timeout.tv_sec = 2;
        drain_timeout.tv_usec = 0;
        setsockopt(client_fd, SOL_SOCKET, SO_RCVTIMEO, &drain_timeout, sizeof(drain_timeout));
        char drain_buffer[4096];
        while (read(client_fd, drain_buffer, sizeof(drain_buffer)) > 0) { }
    }
    if (ssl != NULL) {
        SSL_free(ssl);
    }
    if (client_fd >= 0) {
        close(client_fd);
        server->client_fd = -1;
    }
    if (ctx != NULL) {
        SSL_CTX_free(ctx);
    }
    return NULL;
}

static int h2_origin_start_config(int alpn_mode, uint32_t expected_stream_count, size_t response_body_bytes,
    int benchmark_mode, const uint8_t* encoded_gzip_body, size_t encoded_gzip_body_len,
    struct collo_test_h2_origin_server** out, uint16_t* out_port)
{
    if (out == NULL || out_port == NULL) {
        return fail("missing local HTTP/2 origin output");
    }
    tls_test_error[0] = '\0';
    ERR_clear_error();
    struct collo_test_h2_origin_server* server
        = static_cast<struct collo_test_h2_origin_server*>(calloc(1, sizeof(*server)));
    if (server == NULL) {
        return fail("allocate local HTTP/2 origin");
    }
    server->listen_fd = -1;
    server->client_fd = -1;
    server->alpn_mode = alpn_mode;
    server->expected_stream_count = expected_stream_count;
    server->response_body_bytes = response_body_bytes;
    server->benchmark_mode = benchmark_mode;
    server->selected_alpn = COLLO_BORINGSSL_ALPN_UNSPECIFIED;
    if (encoded_gzip_body != NULL) {
        if (encoded_gzip_body_len > sizeof(server->encoded_body)) {
            free(server);
            return fail("local HTTP/2 gzip origin body too large");
        }
        server->content_encoding_gzip = 1;
        memcpy(server->encoded_body, encoded_gzip_body, encoded_gzip_body_len);
        server->encoded_body_len = encoded_gzip_body_len;
    }
    if (init_temp_files(&server->files) != 0) {
        free(server);
        return -1;
    }

    server->listen_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server->listen_fd < 0) {
        cleanup_temp_files(&server->files);
        free(server);
        return fail("create local HTTP/2 origin listener");
    }
    int one = 1;
    setsockopt(server->listen_fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = 0;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(server->listen_fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0
        || listen(server->listen_fd, 4) != 0) {
        close(server->listen_fd);
        cleanup_temp_files(&server->files);
        free(server);
        return fail("bind local HTTP/2 origin listener");
    }
    socklen_t addr_len = sizeof(addr);
    if (getsockname(server->listen_fd, reinterpret_cast<sockaddr*>(&addr), &addr_len) != 0) {
        close(server->listen_fd);
        cleanup_temp_files(&server->files);
        free(server);
        return fail("read local HTTP/2 origin listener port");
    }
    server->port = ntohs(addr.sin_port);
    if (pthread_create(&server->thread, NULL, h2_origin_thread_main, server) != 0) {
        close(server->listen_fd);
        cleanup_temp_files(&server->files);
        free(server);
        return fail("start local HTTP/2 origin thread");
    }
    server->thread_started = 1;
    *out = server;
    *out_port = server->port;
    return 0;
}

extern "C" int collo_test_h2_origin_start(int alpn_mode, struct collo_test_h2_origin_server** out, uint16_t* out_port)
{
    return h2_origin_start_config(alpn_mode, 2, 0, 0, NULL, 0, out, out_port);
}

// gzip("hello world").
static const uint8_t h2_origin_default_gzip_body[] = {
    0x1f,
    0x8b,
    0x08,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x03,
    0xcb,
    0x48,
    0xcd,
    0xc9,
    0xc9,
    0x57,
    0x28,
    0xcf,
    0x2f,
    0xca,
    0x49,
    0x01,
    0x00,
    0x85,
    0x11,
    0x4a,
    0x0d,
    0x0b,
    0x00,
    0x00,
    0x00,
};

// The h2 origin of collo_test_h2_origin_start, answering `expected_stream_count` streams, where every response
// carries a literal `content-encoding: gzip` header and serves `encoded_body`, bytes already compressed. A NULL
// `encoded_body` serves h2_origin_default_gzip_body.
extern "C" int collo_test_h2_gzip_origin_start(uint32_t expected_stream_count, const uint8_t* encoded_body,
    size_t encoded_body_len, struct collo_test_h2_origin_server** out, uint16_t* out_port)
{
    if (encoded_body == NULL) {
        encoded_body = h2_origin_default_gzip_body;
        encoded_body_len = sizeof(h2_origin_default_gzip_body);
    }
    return h2_origin_start_config(
        COLLO_TEST_H2_ORIGIN_ALPN_H2, expected_stream_count, 0, 0, encoded_body, encoded_body_len, out, out_port);
}

extern "C" int collo_bench_h2_origin_start(uint32_t expected_stream_count, size_t response_body_bytes,
    struct collo_test_h2_origin_server** out, uint16_t* out_port)
{
    return h2_origin_start_config(
        COLLO_TEST_H2_ORIGIN_ALPN_H2, expected_stream_count, response_body_bytes, 1, NULL, 0, out, out_port);
}

extern "C" void collo_test_h2_origin_stop(struct collo_test_h2_origin_server* server)
{
    if (server == NULL) {
        return;
    }
    if (server->listen_fd >= 0) {
        shutdown(server->listen_fd, SHUT_RDWR);
        close(server->listen_fd);
        server->listen_fd = -1;
    }
    if (server->client_fd >= 0) {
        shutdown(server->client_fd, SHUT_RDWR);
        close(server->client_fd);
        server->client_fd = -1;
    }
    if (server->thread_started) {
        pthread_join(server->thread, NULL);
    }
    cleanup_temp_files(&server->files);
    free(server);
}

extern "C" const char* collo_test_h2_origin_last_error(struct collo_test_h2_origin_server* server)
{
    if (server == NULL || server->error[0] == '\0') {
        return "";
    }
    return server->error;
}

extern "C" uint32_t collo_test_h2_origin_stream_count(struct collo_test_h2_origin_server* server)
{
    return server == NULL ? 0 : server->stream_count;
}

extern "C" int collo_test_h2_origin_selected_alpn(struct collo_test_h2_origin_server* server)
{
    return server == NULL ? COLLO_BORINGSSL_ALPN_UNSPECIFIED : server->selected_alpn;
}

// A plain TLS origin that accepts `accept_count` connections one after another on a single server SSL_CTX, so a
// session ticket issued on one connection can resume the next, and counts the resumed handshakes. After each
// handshake it writes one application byte; a client that has read it has also processed the NewSessionTicket
// messages sent before it. Its thread writes the counters and `error`, which are final once that thread is joined.
struct collo_test_tls_resumption_origin {
    TempFiles files;
    pthread_t thread;
    int thread_started;
    int listen_fd;
    uint16_t port;
    uint32_t accept_count;
    uint32_t handshakes_done;
    uint32_t resumed_count;
    char error[512];
};

static void tls_resumption_origin_set_error(struct collo_test_tls_resumption_origin* server, const char* message)
{
    uint32_t err = ERR_peek_last_error();
    if (err != 0) {
        char detail[256];
        ERR_error_string_n(err, detail, sizeof(detail));
        snprintf(server->error, sizeof(server->error), "%s: %s", message, detail);
    } else {
        snprintf(server->error, sizeof(server->error), "%s", message);
    }
}

static void* tls_resumption_origin_thread_main(void* arg)
{
    struct collo_test_tls_resumption_origin* server = static_cast<struct collo_test_tls_resumption_origin*>(arg);
    ERR_clear_error();

    SSL_CTX* ctx = SSL_CTX_new(TLS_server_method());
    if (ctx == NULL || SSL_CTX_use_certificate_chain_file(ctx, server->files.server_cert) != 1
        || SSL_CTX_use_PrivateKey_file(ctx, server->files.server_key, SSL_FILETYPE_PEM) != 1
        || SSL_CTX_check_private_key(ctx) != 1) {
        tls_resumption_origin_set_error(server, "create local TLS resumption origin context");
        if (ctx != NULL) {
            SSL_CTX_free(ctx);
        }
        return NULL;
    }

    for (uint32_t i = 0; i < server->accept_count; i++) {
        int client_fd = accept(server->listen_fd, NULL, NULL);
        if (client_fd < 0) {
            tls_resumption_origin_set_error(server, "accept local TLS resumption origin connection");
            break;
        }
        struct timeval timeout;
        timeout.tv_sec = 15;
        timeout.tv_usec = 0;
        setsockopt(client_fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        setsockopt(client_fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

        SSL* ssl = SSL_new(ctx);
        if (ssl == NULL || SSL_set_fd(ssl, client_fd) != 1) {
            tls_resumption_origin_set_error(server, "create local TLS resumption origin connection");
            if (ssl != NULL) {
                SSL_free(ssl);
            }
            close(client_fd);
            break;
        }
        if (SSL_accept(ssl) != 1) {
            tls_resumption_origin_set_error(server, "local TLS resumption origin accept");
            SSL_free(ssl);
            close(client_fd);
            break;
        }
        if (SSL_session_reused(ssl)) {
            server->resumed_count++;
        }
        server->handshakes_done++;

        uint8_t ready = 'r';
        if (SSL_write(ssl, &ready, 1) != 1) {
            tls_resumption_origin_set_error(server, "local TLS resumption origin ready write");
            SSL_free(ssl);
            close(client_fd);
            break;
        }
        uint8_t drain[256];
        while (SSL_read(ssl, drain, sizeof(drain)) > 0) { }
        SSL_shutdown(ssl);
        SSL_free(ssl);
        close(client_fd);
    }

    SSL_CTX_free(ctx);
    return NULL;
}

extern "C" int collo_test_tls_resumption_origin_start(
    uint32_t accept_count, struct collo_test_tls_resumption_origin** out, uint16_t* out_port)
{
    if (out == NULL || out_port == NULL || accept_count == 0) {
        return fail("missing local TLS resumption origin output");
    }
    tls_test_error[0] = '\0';
    ERR_clear_error();
    struct collo_test_tls_resumption_origin* server
        = static_cast<struct collo_test_tls_resumption_origin*>(calloc(1, sizeof(*server)));
    if (server == NULL) {
        return fail("allocate local TLS resumption origin");
    }
    server->listen_fd = -1;
    server->accept_count = accept_count;
    if (init_temp_files(&server->files) != 0) {
        free(server);
        return -1;
    }

    server->listen_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server->listen_fd < 0) {
        cleanup_temp_files(&server->files);
        free(server);
        return fail("create local TLS resumption origin listener");
    }
    int one = 1;
    setsockopt(server->listen_fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = 0;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(server->listen_fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0
        || listen(server->listen_fd, 4) != 0) {
        close(server->listen_fd);
        cleanup_temp_files(&server->files);
        free(server);
        return fail("bind local TLS resumption origin listener");
    }
    socklen_t addr_len = sizeof(addr);
    if (getsockname(server->listen_fd, reinterpret_cast<sockaddr*>(&addr), &addr_len) != 0) {
        close(server->listen_fd);
        cleanup_temp_files(&server->files);
        free(server);
        return fail("read local TLS resumption origin listener port");
    }
    server->port = ntohs(addr.sin_port);
    if (pthread_create(&server->thread, NULL, tls_resumption_origin_thread_main, server) != 0) {
        close(server->listen_fd);
        cleanup_temp_files(&server->files);
        free(server);
        return fail("start local TLS resumption origin thread");
    }
    server->thread_started = 1;
    *out = server;
    *out_port = server->port;
    return 0;
}

// Waits for the origin thread, which exits after its last connection closes or at its first failure. The counters
// are final once this returns.
extern "C" void collo_test_tls_resumption_origin_join(struct collo_test_tls_resumption_origin* server)
{
    if (server == NULL || !server->thread_started) {
        return;
    }
    pthread_join(server->thread, NULL);
    server->thread_started = 0;
}

extern "C" void collo_test_tls_resumption_origin_stop(struct collo_test_tls_resumption_origin* server)
{
    if (server == NULL) {
        return;
    }
    if (server->listen_fd >= 0) {
        shutdown(server->listen_fd, SHUT_RDWR);
        close(server->listen_fd);
        server->listen_fd = -1;
    }
    if (server->thread_started) {
        pthread_join(server->thread, NULL);
    }
    cleanup_temp_files(&server->files);
    free(server);
}

extern "C" uint32_t collo_test_tls_resumption_origin_resumed_count(struct collo_test_tls_resumption_origin* server)
{
    return server == NULL ? 0 : server->resumed_count;
}

extern "C" uint32_t collo_test_tls_resumption_origin_handshakes(struct collo_test_tls_resumption_origin* server)
{
    return server == NULL ? 0 : server->handshakes_done;
}

extern "C" const char* collo_test_tls_resumption_origin_last_error(struct collo_test_tls_resumption_origin* server)
{
    if (server == NULL || server->error[0] == '\0') {
        return "";
    }
    return server->error;
}

// The h2 client that drives a Collo server. A call opens one TLS connection
// to 127.0.0.1, negotiates h2 through ALPN, sends the client preface and
// SETTINGS, issues its requests and reads the responses frame by frame. Each
// socket read and write is bounded by h2_client_io_timeout_seconds and each
// frame loop by a frame count, so a server that stops answering fails the
// call instead of hanging it.

enum {
    COLLO_TEST_H2_TRUST_TEST_CA = 0,
    COLLO_TEST_H2_TRUST_ANY_CERTIFICATE = 1,
};

// The server a client call talks to. Mirrored field for field by H2Peer in
// runtime/tests/support/tls/shim.zig.
struct collo_test_h2_peer {
    // The CA the server's chain must verify against under
    // COLLO_TEST_H2_TRUST_TEST_CA; unused otherwise.
    const TempFiles* files;
    // Sent as :authority, and as SNI unless its host is an IP literal.
    const char* authority;
    // The server's port on 127.0.0.1.
    uint16_t port;
    uint8_t trust;
    uint8_t reserved0[5];
};

static_assert(sizeof(struct collo_test_h2_peer) == 24, "H2Peer in shim.zig mirrors this layout");

// The split of one GET's wall clock. Mirrored by H2GetTimings in shim.zig.
struct collo_test_h2_get_timings {
    // Connecting and the TLS handshake, before the server can see the
    // request; a benchmark subtracts it to keep only server time.
    uint64_t handshake_ns;
    uint64_t total_ns;
};

// The :authority and SNI of the calls that take a port and TLS material
// instead of a peer, which local-e2e's requests carry.
static const char h2_harness_authority[] = "demo.example.test";

static constexpr int h2_client_io_timeout_seconds = 15;
// Frames read before the server's SETTINGS must have arrived.
static constexpr size_t h2_client_setup_frames_max = 32;
// Frames read while waiting for every tracked response to end.
static constexpr size_t h2_client_response_frames_max = 20000;
// The client's SETTINGS_MAX_FRAME_SIZE, so no frame payload the server sends
// is larger.
static constexpr uint32_t h2_client_frame_payload_max = 65535;
// The largest request HEADERS block the client builds, so it also bounds a request path.
static constexpr size_t h2_client_header_block_max = 1024;

static constexpr uint8_t h2_frame_data = 0x0;
static constexpr uint8_t h2_frame_headers = 0x1;
static constexpr uint8_t h2_frame_rst_stream = 0x3;
static constexpr uint8_t h2_frame_settings = 0x4;
static constexpr uint8_t h2_frame_ping = 0x6;
static constexpr uint8_t h2_frame_goaway = 0x7;
static constexpr uint8_t h2_frame_window_update = 0x8;
static constexpr uint8_t h2_flag_end_stream = 0x1;
// ACK shares END_STREAM's bit, on SETTINGS and PING.
static constexpr uint8_t h2_flag_ack = 0x1;
static constexpr uint8_t h2_flag_end_headers = 0x4;
static constexpr uint8_t h2_flag_padded = 0x8;
static constexpr uint8_t h2_flag_priority = 0x20;

static uint64_t monotonic_ns(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        return 0;
    }
    return static_cast<uint64_t>(ts.tv_sec) * 1000000000ull + static_cast<uint64_t>(ts.tv_nsec);
}

static struct collo_test_h2_peer h2_harness_peer(uint16_t port, const TempFiles* files)
{
    struct collo_test_h2_peer peer;
    memset(&peer, 0, sizeof(peer));
    peer.files = files;
    peer.authority = h2_harness_authority;
    peer.port = port;
    peer.trust = COLLO_TEST_H2_TRUST_TEST_CA;
    return peer;
}

static int h2_check_peer(const struct collo_test_h2_peer* peer)
{
    if (peer == NULL || peer->authority == NULL) {
        return fail("missing HTTP/2 peer");
    }
    if (peer->trust == COLLO_TEST_H2_TRUST_TEST_CA) {
        return peer->files == NULL ? fail("HTTP/2 peer trusts the test CA but names no TLS material") : 0;
    }
    if (peer->trust == COLLO_TEST_H2_TRUST_ANY_CERTIFICATE) {
        return 0;
    }
    return fail("unknown HTTP/2 peer trust mode");
}

// One client connection. SSL_set_fd attaches the socket without handing it
// over, so the destructor closes it once the SSL handle is gone. The
// connection ends without a close_notify alert, and the server takes the end
// of the socket as the client leaving.
struct H2Client {
    bssl::UniquePtr<SSL_CTX> ctx;
    bssl::UniquePtr<SSL> ssl;
    int fd = -1;

    H2Client() = default;
    H2Client(const H2Client&) = delete;
    H2Client& operator=(const H2Client&) = delete;
    ~H2Client()
    {
        ssl.reset();
        if (fd >= 0) {
            close(fd);
        }
    }
};

enum class H2ClientVersions {
    // The highest version both ends support, TLS 1.3 against a Collo
    // server. The GETs use it, because a timed TLS 1.2 handshake would price
    // a round trip the product does not spend.
    negotiated,
    // TLS 1.2 only, so the roundtrip keeps the server's TLS 1.2 path
    // covered.
    tls12_only,
};

static int h2_client_new_context(H2Client* client, const struct collo_test_h2_peer* peer)
{
    if (peer->trust == COLLO_TEST_H2_TRUST_ANY_CERTIFICATE) {
        client->ctx.reset(SSL_CTX_new(TLS_client_method()));
        if (!client->ctx) {
            return fail("create HTTP/2 client context");
        }
        // As curl -k does: a server that generated its own certificate
        // presents one that no CA known here has signed.
        SSL_CTX_set_verify(client->ctx.get(), SSL_VERIFY_NONE, NULL);
        return 0;
    }
    client->ctx.reset(new_client_context(peer->files));
    if (!client->ctx) {
        return fail("create HTTP/2 client context");
    }
    return 0;
}

// SNI carries a DNS name (RFC 6066 section 3 forbids IP literals), so an
// authority whose host is an IPv4 or bracketed IPv6 literal sends none.
static int h2_client_set_server_name(SSL* ssl, const char* authority)
{
    if (authority[0] == '[') {
        return 0;
    }
    const char* port_separator = strrchr(authority, ':');
    const size_t host_len
        = port_separator == NULL ? strlen(authority) : static_cast<size_t>(port_separator - authority);
    char host[256];
    if (host_len == 0 || host_len >= sizeof(host)) {
        return fail("HTTP/2 authority has an empty or overlong host");
    }
    memcpy(host, authority, host_len);
    host[host_len] = '\0';
    struct in_addr ipv4;
    if (inet_pton(AF_INET, host, &ipv4) == 1) {
        return 0;
    }
    if (SSL_set_tlsext_host_name(ssl, host) != 1) {
        return fail("set HTTP/2 client SNI");
    }
    return 0;
}

// Connects to the peer's port on 127.0.0.1 and completes the handshake with h2 selected.
static int h2_client_connect(H2Client* client, const struct collo_test_h2_peer* peer, H2ClientVersions versions)
{
    client->ssl.reset(SSL_new(client->ctx.get()));
    if (!client->ssl) {
        return fail("create HTTP/2 client connection");
    }
    SSL* ssl = client->ssl.get();
    SSL_set_connect_state(ssl);
    if (versions == H2ClientVersions::tls12_only
        && (SSL_set_min_proto_version(ssl, TLS1_2_VERSION) != 1
            || SSL_set_max_proto_version(ssl, TLS1_2_VERSION) != 1)) {
        return fail("pin the HTTP/2 client to TLS 1.2");
    }
    if (h2_client_set_server_name(ssl, peer->authority) != 0) {
        return -1;
    }
    static const uint8_t alpn_h2[] = { 2, 'h', '2' };
    if (SSL_set_alpn_protos(ssl, alpn_h2, sizeof(alpn_h2)) != 0) {
        return fail("set HTTP/2 ALPN");
    }

    client->fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (client->fd < 0) {
        return fail_errno("create HTTP/2 client socket");
    }
    struct timeval timeout;
    timeout.tv_sec = h2_client_io_timeout_seconds;
    timeout.tv_usec = 0;
    // Small request frames must not wait behind delayed ACKs.
    const int nodelay = 1;
    if (setsockopt(client->fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) != 0
        || setsockopt(client->fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) != 0
        || setsockopt(client->fd, IPPROTO_TCP, TCP_NODELAY, &nodelay, sizeof(nodelay)) != 0) {
        return fail_errno("set HTTP/2 client socket options");
    }
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons(peer->port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(client->fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0) {
        return fail_errno("connect to the HTTP/2 server");
    }
    if (SSL_set_fd(ssl, client->fd) != 1) {
        return fail("attach the HTTP/2 client socket");
    }
    if (SSL_do_handshake(ssl) != 1) {
        return fail("HTTP/2 client handshake");
    }
    const uint8_t* selected = NULL;
    unsigned selected_len = 0;
    SSL_get0_alpn_selected(ssl, &selected, &selected_len);
    if (selected_len != 2 || memcmp(selected, "h2", 2) != 0) {
        return fail("HTTP/2 ALPN was not negotiated");
    }
    return 0;
}

struct H2FrameHeader {
    uint32_t length;
    uint8_t type;
    uint8_t flags;
    uint32_t stream_id;
};

static int h2_read_frame(SSL* ssl, H2FrameHeader* header, uint8_t* payload, size_t payload_cap)
{
    uint8_t raw[9];
    if (ssl_read_exact(ssl, raw, sizeof(raw)) != 0) {
        return -1;
    }
    header->length = read_u24(raw);
    header->type = raw[3];
    header->flags = raw[4];
    header->stream_id = read_u31(raw + 5);
    if (header->length > payload_cap) {
        return fail("HTTP/2 frame larger than the client's SETTINGS_MAX_FRAME_SIZE");
    }
    return ssl_read_exact(ssl, payload, header->length);
}

// Sends the client preface and the client's SETTINGS.
static int h2_client_send_preface(SSL* ssl)
{
    static const char preface[] = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
    if (ssl_write_all(ssl, preface, sizeof(preface) - 1) != 0) {
        return -1;
    }
    uint8_t settings[18];
    size_t settings_len = 0;
    // HEADER_TABLE_SIZE 0: the server's encoder keeps no dynamic table, so a
    // captured response header block decodes with a fresh decoder.
    settings_len += h2_write_setting(settings + settings_len, 0x1, 0);
    // INITIAL_WINDOW_SIZE 1 MiB lets a large response run ahead of this
    // client's WINDOW_UPDATE frames.
    settings_len += h2_write_setting(settings + settings_len, 0x4, 1024 * 1024);
    settings_len += h2_write_setting(settings + settings_len, 0x5, h2_client_frame_payload_max);
    return h2_write_frame(ssl, h2_frame_settings, 0, 0, settings, settings_len);
}

// Sends the client preface and SETTINGS, then reads until the server's own
// SETTINGS arrives and acknowledges it.
static int h2_client_start(SSL* ssl)
{
    if (h2_client_send_preface(ssl) != 0) {
        return -1;
    }

    uint8_t payload[h2_client_frame_payload_max];
    for (size_t frame_count = 0; frame_count < h2_client_setup_frames_max; frame_count++) {
        H2FrameHeader header;
        if (h2_read_frame(ssl, &header, payload, sizeof(payload)) != 0) {
            return -1;
        }
        if (header.type == h2_frame_goaway) {
            return fail("HTTP/2 server sent GOAWAY during setup");
        }
        if (header.type == h2_frame_settings && header.stream_id == 0 && (header.flags & h2_flag_ack) == 0) {
            return h2_write_frame(ssl, h2_frame_settings, h2_flag_ack, 0, NULL, 0);
        }
    }
    return fail("HTTP/2 server SETTINGS not observed");
}

static int h2_send_get(SSL* ssl, const char* authority, uint32_t stream_id, const char* path)
{
    uint8_t header_block[h2_client_header_block_max];
    const int header_len = h2_build_request_headers(header_block, sizeof(header_block), "GET", authority, path, NULL);
    if (header_len < 0) {
        return -1;
    }
    return h2_write_frame(ssl, h2_frame_headers, h2_flag_end_stream | h2_flag_end_headers, stream_id, header_block,
        static_cast<size_t>(header_len));
}

// Where one response stream's bytes go. `body` may be NULL with a zero cap,
// which counts the body's length without keeping any of it; `body_len` gets
// the full length, which exceeds `body_cap` when the body did not fit.
struct H2ResponseSink {
    uint32_t stream_id = 0;
    char* body = NULL;
    uint64_t body_cap = 0;
    uint64_t* body_len = NULL;
    // Optional: receives the HPACK payload of the stream's first HEADERS
    // frame.
    uint8_t* header_block = NULL;
    uint64_t header_block_cap = 0;
    uint64_t* header_block_len = NULL;
    bool header_block_seen = false;
    bool done = false;
};

struct H2FrameCounts {
    uint64_t headers;
    uint64_t data;
};

static H2ResponseSink* h2_find_sink(H2ResponseSink* sinks, size_t sink_count, uint32_t stream_id)
{
    for (size_t index = 0; index < sink_count; index++) {
        if (sinks[index].stream_id == stream_id) {
            return &sinks[index];
        }
    }
    return NULL;
}

static int h2_capture_header_block(H2ResponseSink* sink, const H2FrameHeader& header, const uint8_t* payload)
{
    sink->header_block_seen = true;
    // PADDED or PRIORITY would put bytes before the HPACK payload, and a
    // missing END_HEADERS means CONTINUATION frames follow. The server sends
    // neither, so either one fails the call rather than hand a decoder a
    // corrupt block.
    if ((header.flags & (h2_flag_padded | h2_flag_priority)) != 0) {
        return fail("HTTP/2 response HEADERS carries padding or priority");
    }
    if ((header.flags & h2_flag_end_headers) == 0) {
        return fail("HTTP/2 response header block is continued");
    }
    if (sink->header_block == NULL || sink->header_block_len == NULL) {
        return 0;
    }
    if (header.length > sink->header_block_cap) {
        return fail("HTTP/2 response header block exceeds the capture buffer");
    }
    memcpy(sink->header_block, payload, header.length);
    *sink->header_block_len = header.length;
    return 0;
}

// Returns flow-control credit for one DATA payload: always to the
// connection, and to the stream while it stays open, since no frame but
// PRIORITY may go to a closed stream.
static int h2_return_credit(SSL* ssl, uint32_t stream_id, uint32_t length, bool stream_ended)
{
    uint8_t increment[4];
    write_u32(increment, length);
    if (h2_write_frame(ssl, h2_frame_window_update, 0, 0, increment, sizeof(increment)) != 0) {
        return -1;
    }
    if (stream_ended) {
        return 0;
    }
    return h2_write_frame(ssl, h2_frame_window_update, 0, stream_id, increment, sizeof(increment));
}

static int h2_fail_stream_closed(const H2FrameHeader& header, const uint8_t* payload)
{
    uint32_t error_code = 0;
    if (header.type == h2_frame_rst_stream && header.length >= 4) {
        error_code = read_u32(payload);
    } else if (header.type == h2_frame_goaway && header.length >= 8) {
        error_code = read_u32(payload + 4);
    }
    char message[160];
    snprintf(message, sizeof(message), "HTTP/2 server %s on stream %u with error code %u",
        header.type == h2_frame_rst_stream ? "reset a stream" : "sent GOAWAY", header.stream_id, error_code);
    return fail(message);
}

// Reads frames until every sink's stream has ended, acknowledging SETTINGS
// and PING and returning credit for every DATA payload. RST_STREAM or GOAWAY
// on any stream fails the call. `counts`, when set, counts every HEADERS and
// DATA frame, tracked stream or not.
static int h2_read_responses(SSL* ssl, H2ResponseSink* sinks, size_t sink_count, H2FrameCounts* counts)
{
    uint8_t payload[h2_client_frame_payload_max];
    size_t open_count = sink_count;
    for (size_t frame_count = 0; frame_count < h2_client_response_frames_max && open_count != 0; frame_count++) {
        H2FrameHeader header;
        if (h2_read_frame(ssl, &header, payload, sizeof(payload)) != 0) {
            return -1;
        }
        H2ResponseSink* sink = h2_find_sink(sinks, sink_count, header.stream_id);
        bool ends_stream = false;
        switch (header.type) {
        case h2_frame_headers:
            if (counts != NULL) {
                counts->headers++;
            }
            if (sink != NULL && !sink->header_block_seen && h2_capture_header_block(sink, header, payload) != 0) {
                return -1;
            }
            ends_stream = (header.flags & h2_flag_end_stream) != 0;
            break;
        case h2_frame_data:
            if (counts != NULL) {
                counts->data++;
            }
            if (sink != NULL) {
                append_body_sample(sink->body, sink->body_cap, sink->body_len, payload, header.length);
            }
            ends_stream = (header.flags & h2_flag_end_stream) != 0;
            if (header.length != 0 && h2_return_credit(ssl, header.stream_id, header.length, ends_stream) != 0) {
                return -1;
            }
            break;
        case h2_frame_settings:
            if ((header.flags & h2_flag_ack) == 0
                && h2_write_frame(ssl, h2_frame_settings, h2_flag_ack, 0, NULL, 0) != 0) {
                return -1;
            }
            break;
        case h2_frame_ping:
            if ((header.flags & h2_flag_ack) != 0) {
                break;
            }
            if (header.length != 8) {
                return fail("HTTP/2 server sent a PING without an 8-byte payload");
            }
            if (h2_write_frame(ssl, h2_frame_ping, h2_flag_ack, 0, payload, header.length) != 0) {
                return -1;
            }
            break;
        case h2_frame_rst_stream:
        case h2_frame_goaway:
            return h2_fail_stream_closed(header, payload);
        default:
            // WINDOW_UPDATE and PRIORITY need no answer from a client that
            // sends nothing after its requests.
            break;
        }
        if (ends_stream && sink != NULL && !sink->done) {
            sink->done = true;
            open_count--;
        }
    }
    if (open_count != 0) {
        return fail("HTTP/2 response streams did not complete");
    }
    return 0;
}

// Three streams on one connection pinned to TLS 1.2: a GET with a route
// parameter and a query on stream 1, a POST whose body arrives in two DATA
// frames on stream 3, and a large response on stream 5, whose body is only
// counted.
extern "C" int collo_test_h2_server_roundtrip(
    uint16_t port, const TempFiles* files, struct collo_test_h2_server_result* out)
{
    if (files == NULL || out == NULL) {
        return fail("missing HTTP/2 roundtrip input");
    }
    tls_test_error[0] = '\0';
    ERR_clear_error();
    memset(out, 0, sizeof(*out));

    const struct collo_test_h2_peer peer = h2_harness_peer(port, files);
    H2Client client;
    if (h2_client_new_context(&client, &peer) != 0
        || h2_client_connect(&client, &peer, H2ClientVersions::tls12_only) != 0
        || h2_client_start(client.ssl.get()) != 0) {
        return -1;
    }
    SSL* ssl = client.ssl.get();

    if (h2_send_get(ssl, peer.authority, 1, "/hello/h2?x=7") != 0) {
        return -1;
    }
    uint8_t header_block[h2_client_header_block_max];
    const int post_header_len
        = h2_build_request_headers(header_block, sizeof(header_block), "POST", peer.authority, "/echo", "11");
    if (post_header_len < 0
        || h2_write_frame(
               ssl, h2_frame_headers, h2_flag_end_headers, 3, header_block, static_cast<size_t>(post_header_len))
            != 0
        || h2_write_frame(ssl, h2_frame_data, 0, 3, "alpha-", 6) != 0
        || h2_write_frame(ssl, h2_frame_data, h2_flag_end_stream, 3, "omega", 5) != 0) {
        return -1;
    }
    if (h2_send_get(ssl, peer.authority, 5, "/large-response") != 0) {
        return -1;
    }

    H2ResponseSink sinks[] = {
        { .stream_id = 1, .body = out->get_body, .body_cap = sizeof(out->get_body), .body_len = &out->get_body_len },
        { .stream_id = 3, .body = out->post_body, .body_cap = sizeof(out->post_body), .body_len = &out->post_body_len },
        { .stream_id = 5, .body = NULL, .body_cap = 0, .body_len = &out->large_body_len },
    };
    H2FrameCounts counts = {};
    const int rc = h2_read_responses(ssl, sinks, sizeof(sinks) / sizeof(sinks[0]), &counts);
    out->header_frame_count = counts.headers;
    out->data_frame_count = counts.data;
    return rc;
}

// One GET on stream 1 of a fresh connection, after the handshake that
// `started_ns` began timing.
static int h2_client_get(H2Client* client, const struct collo_test_h2_peer* peer, const char* path,
    H2ResponseSink* sink, uint64_t started_ns, struct collo_test_h2_get_timings* out_timings)
{
    if (h2_client_connect(client, peer, H2ClientVersions::negotiated) != 0) {
        return -1;
    }
    if (out_timings != NULL) {
        out_timings->handshake_ns = monotonic_ns() - started_ns;
    }
    if (h2_client_start(client->ssl.get()) != 0 || h2_send_get(client->ssl.get(), peer->authority, 1, path) != 0) {
        return -1;
    }
    return h2_read_responses(client->ssl.get(), sink, 1, NULL);
}

// One GET of `path` on a fresh connection to `peer`. The body lands in
// out_body and, when out_header_block is set, the HPACK payload of the
// response's first HEADERS frame in it. The clock of out_timings starts once
// the client's TLS context exists, because building it reads the CA file,
// which is client setup and not latency.
extern "C" int collo_test_h2_get(const struct collo_test_h2_peer* peer, const char* path, char* out_body,
    uint64_t out_body_cap, uint64_t* out_body_len, uint8_t* out_header_block, uint64_t out_header_block_cap,
    uint64_t* out_header_block_len, struct collo_test_h2_get_timings* out_timings)
{
    if (path == NULL || out_body == NULL || out_body_len == NULL) {
        return fail("missing HTTP/2 GET input");
    }
    tls_test_error[0] = '\0';
    ERR_clear_error();
    *out_body_len = 0;
    if (out_header_block_len != NULL) {
        *out_header_block_len = 0;
    }
    if (out_timings != NULL) {
        out_timings->handshake_ns = 0;
        out_timings->total_ns = 0;
    }
    if (h2_check_peer(peer) != 0) {
        return -1;
    }

    H2Client client;
    if (h2_client_new_context(&client, peer) != 0) {
        return -1;
    }
    const uint64_t started_ns = monotonic_ns();
    H2ResponseSink sink = {
        .stream_id = 1,
        .body = out_body,
        .body_cap = out_body_cap,
        .body_len = out_body_len,
        .header_block = out_header_block,
        .header_block_cap = out_header_block_cap,
        .header_block_len = out_header_block_len,
    };
    const int rc = h2_client_get(&client, peer, path, &sink, started_ns, out_timings);
    if (out_timings != NULL) {
        out_timings->total_ns = monotonic_ns() - started_ns;
    }
    return rc;
}

extern "C" int collo_test_h2_server_get_timed(uint16_t port, const TempFiles* files, const char* path, char* out_body,
    uint64_t out_body_cap, uint64_t* out_body_len, uint8_t* out_header_block, uint64_t out_header_block_cap,
    uint64_t* out_header_block_len, struct collo_test_h2_get_timings* out_timings)
{
    if (files == NULL) {
        return fail("missing HTTP/2 GET TLS material");
    }
    const struct collo_test_h2_peer peer = h2_harness_peer(port, files);
    return collo_test_h2_get(&peer, path, out_body, out_body_cap, out_body_len, out_header_block, out_header_block_cap,
        out_header_block_len, out_timings);
}

extern "C" int collo_test_h2_server_get(uint16_t port, const TempFiles* files, const char* path, char* out_body,
    uint64_t out_body_cap, uint64_t* out_body_len, uint8_t* out_header_block, uint64_t out_header_block_cap,
    uint64_t* out_header_block_len)
{
    return collo_test_h2_server_get_timed(port, files, path, out_body, out_body_cap, out_body_len, out_header_block,
        out_header_block_cap, out_header_block_len, NULL);
}

// Two GETs on one connection, each timed: `path_first` on stream 1, whose
// body is discarded, then `path_second` on stream 3, whose body lands in
// out_body. Behind a reverse proxy that pools its connections, a request
// usually arrives on a socket whose handshake was paid long ago, so a cold
// start lands whole in the user's latency; the second request measures that
// case. Pointed at a warm route first and then at a route of a worker
// definition with no worker yet, it times a cold start on an open
// connection. The second request's handshake_ns is 0.
extern "C" int collo_test_h2_server_get_pair(uint16_t port, const TempFiles* files, const char* path_first,
    const char* path_second, char* out_body, uint64_t out_body_cap, uint64_t* out_body_len,
    struct collo_test_h2_get_timings* out_first, struct collo_test_h2_get_timings* out_second)
{
    if (files == NULL || path_first == NULL || path_second == NULL || out_body == NULL || out_body_len == NULL) {
        return fail("missing HTTP/2 GET pair input");
    }
    tls_test_error[0] = '\0';
    ERR_clear_error();
    *out_body_len = 0;
    if (out_first != NULL) {
        out_first->handshake_ns = 0;
        out_first->total_ns = 0;
    }
    if (out_second != NULL) {
        out_second->handshake_ns = 0;
        out_second->total_ns = 0;
    }

    const struct collo_test_h2_peer peer = h2_harness_peer(port, files);
    H2Client client;
    // Same rule as a single GET: the clock starts once the client context
    // exists, so the first span is connect, handshake and request.
    if (h2_client_new_context(&client, &peer) != 0) {
        return -1;
    }
    const uint64_t started_ns = monotonic_ns();
    if (h2_client_connect(&client, &peer, H2ClientVersions::negotiated) != 0) {
        return -1;
    }
    if (out_first != NULL) {
        out_first->handshake_ns = monotonic_ns() - started_ns;
    }
    SSL* ssl = client.ssl.get();
    if (h2_client_start(ssl) != 0) {
        return -1;
    }

    uint64_t discarded_len = 0;
    H2ResponseSink first = { .stream_id = 1, .body = NULL, .body_cap = 0, .body_len = &discarded_len };
    if (h2_send_get(ssl, peer.authority, 1, path_first) != 0 || h2_read_responses(ssl, &first, 1, NULL) != 0) {
        return -1;
    }
    const uint64_t first_done_ns = monotonic_ns();
    if (out_first != NULL) {
        out_first->total_ns = first_done_ns - started_ns;
    }

    H2ResponseSink second = { .stream_id = 3, .body = out_body, .body_cap = out_body_cap, .body_len = out_body_len };
    if (h2_send_get(ssl, peer.authority, 3, path_second) != 0 || h2_read_responses(ssl, &second, 1, NULL) != 0) {
        return -1;
    }
    if (out_second != NULL) {
        out_second->total_ns = monotonic_ns() - first_done_ns;
    }
    return 0;
}

// The HEADERS block the client sends for a bodiless `method` request of
// `path` under the harness authority, so a suite can decode it without a
// server.
extern "C" int collo_test_h2_request_header_block(
    const char* method, const char* path, uint8_t* out, uint64_t out_cap, uint64_t* out_len)
{
    // Nothing here touches BoringSSL, so an error left queued by an earlier
    // call on this thread would only mislabel this one's failure.
    ERR_clear_error();
    if (method == NULL || path == NULL || out == NULL || out_len == NULL) {
        return fail("missing HTTP/2 request header block input");
    }
    *out_len = 0;
    const int len
        = h2_build_request_headers(out, static_cast<size_t>(out_cap), method, h2_harness_authority, path, NULL);
    if (len < 0) {
        return -1;
    }
    *out_len = static_cast<uint64_t>(len);
    return 0;
}

// A client connection the caller holds across calls, so a test can keep several connections open at once, run many
// requests on one, or send a request body under the server's flow control. It reads the server's SETTINGS for the
// largest DATA payload and the initial stream window, tracks the connection's and each stream's send windows, and
// keeps the response of every stream it opened until the caller reads it, so the frames of one stream never cost
// another stream its response. One thread at a time calls into a client.

// Streams one client keeps open at once.
static constexpr size_t h2_client_tracked_streams_max = 8;
// Longest :authority a held client sends, terminator included.
static constexpr size_t h2_client_authority_max = 256;
// RFC 9113: the smallest and the largest SETTINGS_MAX_FRAME_SIZE (section 6.5.2), the initial flow-control window
// and the largest one (section 6.9).
static constexpr uint32_t h2_max_frame_size_min = 16384;
static constexpr uint32_t h2_max_frame_size_max = 0xffffff;
static constexpr int64_t h2_initial_window = 65535;
static constexpr int64_t h2_window_max = 0x7fffffff;

// How one stream of a held connection ended. Mirrored field for field by H2Response in
// runtime/tests/support/tls/shim.zig.
struct collo_test_h2_response {
    // The body's full length, which exceeds `body` when the body did not fit.
    uint64_t body_len;
    uint64_t header_block_len;
    // The RST_STREAM or GOAWAY error code when `reset` is set.
    uint32_t reset_code;
    // 1 when the stream ended without END_STREAM: the server reset it, or a GOAWAY refused it.
    uint8_t reset;
    uint8_t reserved0[3];
    // The HPACK payload of the response's first HEADERS frame.
    uint8_t header_block[1024];
    char body[2048];
};

static_assert(sizeof(struct collo_test_h2_response) == 3096, "H2Response in shim.zig mirrors this layout");

struct H2TrackedStream {
    // 0 marks a free entry.
    uint32_t stream_id;
    // END_STREAM or RST_STREAM arrived, or a GOAWAY refused the stream.
    bool done;
    // What the server still lets the client send on this stream.
    int64_t send_window;
    struct collo_test_h2_response response;
};

struct collo_test_h2_client {
    H2Client connection;
    // Sent as :authority on every request: the peer's, copied at open.
    char authority[h2_client_authority_max] = {};
    uint32_t peer_max_frame_size = h2_max_frame_size_min;
    int64_t peer_initial_window = h2_initial_window;
    int64_t connection_send_window = h2_initial_window;
    H2TrackedStream streams[h2_client_tracked_streams_max] = {};
};

static H2TrackedStream* h2_client_find_stream(struct collo_test_h2_client* client, uint32_t stream_id)
{
    for (size_t index = 0; index < h2_client_tracked_streams_max; index++) {
        if (client->streams[index].stream_id == stream_id) {
            return &client->streams[index];
        }
    }
    return NULL;
}

// Applies the server's SETTINGS: the largest DATA payload the client may send, and the initial stream window, whose
// change moves the send window of every open stream by the same amount (RFC 9113 section 6.9.2).
static int h2_client_apply_settings(struct collo_test_h2_client* client, const uint8_t* payload, size_t len)
{
    if (len % 6 != 0) {
        return fail("HTTP/2 server SETTINGS payload is not whole settings");
    }
    for (size_t cursor = 0; cursor < len; cursor += 6) {
        const uint16_t id = static_cast<uint16_t>((static_cast<uint16_t>(payload[cursor]) << 8) | payload[cursor + 1]);
        const uint32_t value = read_u32(payload + cursor + 2);
        if (id == 0x4) {
            if (value > h2_window_max) {
                return fail("HTTP/2 server initial window exceeds the largest window");
            }
            const int64_t delta = static_cast<int64_t>(value) - client->peer_initial_window;
            client->peer_initial_window = value;
            for (size_t index = 0; index < h2_client_tracked_streams_max; index++) {
                if (client->streams[index].stream_id != 0) {
                    client->streams[index].send_window += delta;
                }
            }
        } else if (id == 0x5) {
            if (value < h2_max_frame_size_min || value > h2_max_frame_size_max) {
                return fail("HTTP/2 server max frame size is out of range");
            }
            client->peer_max_frame_size = value;
        }
    }
    return 0;
}

// Ends every open stream a GOAWAY refuses: those past its last stream id, which the server will not process.
static void h2_client_refuse_streams(struct collo_test_h2_client* client, uint32_t last_stream_id, uint32_t error_code)
{
    for (size_t index = 0; index < h2_client_tracked_streams_max; index++) {
        H2TrackedStream* stream = &client->streams[index];
        if (stream->stream_id == 0 || stream->done || stream->stream_id <= last_stream_id) {
            continue;
        }
        stream->response.reset = 1;
        stream->response.reset_code = error_code;
        stream->done = true;
    }
}

// Handles one frame of a held connection: an open stream's response, flow control, and the frames the connection
// itself must answer, SETTINGS and PING. DATA credit goes back at once, to the connection and to its stream while
// that stream is open. A frame of a stream that already ended is dropped.
static int h2_client_handle_frame(
    struct collo_test_h2_client* client, const H2FrameHeader& header, const uint8_t* payload)
{
    SSL* ssl = client->connection.ssl.get();
    H2TrackedStream* stream = header.stream_id == 0 ? NULL : h2_client_find_stream(client, header.stream_id);
    if (stream != NULL && stream->done) {
        stream = NULL;
    }
    switch (header.type) {
    case h2_frame_headers:
        if (stream == NULL) {
            return 0;
        }
        if (stream->response.header_block_len == 0) {
            // PADDED or PRIORITY would put bytes before the HPACK payload, and a missing END_HEADERS means
            // CONTINUATION frames follow; the server sends neither.
            if ((header.flags & (h2_flag_padded | h2_flag_priority)) != 0) {
                return fail("HTTP/2 response HEADERS carries padding or priority");
            }
            if ((header.flags & h2_flag_end_headers) == 0) {
                return fail("HTTP/2 response header block is continued");
            }
            if (header.length > sizeof(stream->response.header_block)) {
                return fail("HTTP/2 response header block exceeds the capture buffer");
            }
            memcpy(stream->response.header_block, payload, header.length);
            stream->response.header_block_len = header.length;
        }
        if ((header.flags & h2_flag_end_stream) != 0) {
            stream->done = true;
        }
        return 0;
    case h2_frame_data: {
        bool stream_open = false;
        if (stream != NULL) {
            append_body_sample(stream->response.body, sizeof(stream->response.body), &stream->response.body_len,
                payload, header.length);
            if ((header.flags & h2_flag_end_stream) != 0) {
                stream->done = true;
            }
            stream_open = !stream->done;
        }
        if (header.length == 0) {
            return 0;
        }
        return h2_return_credit(ssl, header.stream_id, header.length, !stream_open);
    }
    case h2_frame_window_update: {
        if (header.length != 4) {
            return fail("HTTP/2 server WINDOW_UPDATE payload is not 4 bytes");
        }
        const uint32_t increment = read_u32(payload) & 0x7fffffff;
        if (header.stream_id == 0) {
            client->connection_send_window += increment;
        } else if (stream != NULL) {
            stream->send_window += increment;
        }
        return 0;
    }
    case h2_frame_settings:
        if ((header.flags & h2_flag_ack) != 0) {
            return 0;
        }
        if (h2_client_apply_settings(client, payload, header.length) != 0) {
            return -1;
        }
        return h2_write_frame(ssl, h2_frame_settings, h2_flag_ack, 0, NULL, 0);
    case h2_frame_ping:
        if ((header.flags & h2_flag_ack) != 0) {
            return 0;
        }
        if (header.length != 8) {
            return fail("HTTP/2 server sent a PING without an 8-byte payload");
        }
        return h2_write_frame(ssl, h2_frame_ping, h2_flag_ack, 0, payload, header.length);
    case h2_frame_rst_stream:
        if (stream != NULL) {
            stream->response.reset = 1;
            stream->response.reset_code = header.length >= 4 ? read_u32(payload) : 0;
            stream->done = true;
        }
        return 0;
    case h2_frame_goaway:
        if (header.length < 8) {
            return fail("HTTP/2 server GOAWAY is shorter than 8 bytes");
        }
        h2_client_refuse_streams(client, read_u31(payload), read_u32(payload + 4));
        return 0;
    default:
        // PRIORITY and frame types the client does not know need no answer.
        return 0;
    }
}

// Reads and handles one frame of a held connection; the read waits at most h2_client_io_timeout_seconds.
static int h2_client_read_frame(struct collo_test_h2_client* client)
{
    uint8_t payload[h2_client_frame_payload_max];
    H2FrameHeader header;
    if (h2_read_frame(client->connection.ssl.get(), &header, payload, sizeof(payload)) != 0) {
        return -1;
    }
    return h2_client_handle_frame(client, header, payload);
}

// Sends the preface and the client's SETTINGS, then handles frames until the server's own SETTINGS has arrived and
// been applied and acknowledged.
static int h2_client_open_session(struct collo_test_h2_client* client)
{
    SSL* ssl = client->connection.ssl.get();
    if (h2_client_send_preface(ssl) != 0) {
        return -1;
    }
    uint8_t payload[h2_client_frame_payload_max];
    for (size_t frame_count = 0; frame_count < h2_client_setup_frames_max; frame_count++) {
        H2FrameHeader header;
        if (h2_read_frame(ssl, &header, payload, sizeof(payload)) != 0) {
            return -1;
        }
        if (header.type == h2_frame_goaway) {
            return fail("HTTP/2 server sent GOAWAY during setup");
        }
        const bool server_settings
            = header.type == h2_frame_settings && header.stream_id == 0 && (header.flags & h2_flag_ack) == 0;
        if (h2_client_handle_frame(client, header, payload) != 0) {
            return -1;
        }
        if (server_settings) {
            return 0;
        }
    }
    return fail("HTTP/2 server SETTINGS not observed");
}

// Ends a held client's connection without a close_notify alert, as every client of this file does, and frees the
// client. NULL is a no-op.
extern "C" void collo_test_h2_client_close(struct collo_test_h2_client* client)
{
    if (client == NULL) {
        return;
    }
    client->~collo_test_h2_client();
    free(client);
}

// Opens a connection to `peer` with h2 negotiated and the server's SETTINGS applied: 0 with `*out` set, which the
// caller owns until collo_test_h2_client_close, or nonzero with the reason in collo_test_tls_last_error. The client is
// built in calloc'd memory, as the origins are, so the shim needs no C++ allocator.
extern "C" int collo_test_h2_client_open(const struct collo_test_h2_peer* peer, struct collo_test_h2_client** out)
{
    if (out == NULL) {
        return fail("missing HTTP/2 client output");
    }
    *out = NULL;
    tls_test_error[0] = '\0';
    ERR_clear_error();
    if (h2_check_peer(peer) != 0) {
        return -1;
    }
    const size_t authority_len = strlen(peer->authority);
    if (authority_len >= h2_client_authority_max) {
        return fail("HTTP/2 client authority is too long");
    }
    void* memory = calloc(1, sizeof(struct collo_test_h2_client));
    if (memory == NULL) {
        return fail("allocate HTTP/2 client");
    }
    struct collo_test_h2_client* client = new (memory) collo_test_h2_client();
    memcpy(client->authority, peer->authority, authority_len + 1);
    if (h2_client_new_context(&client->connection, peer) != 0
        || h2_client_connect(&client->connection, peer, H2ClientVersions::negotiated) != 0
        || h2_client_open_session(client) != 0) {
        collo_test_h2_client_close(client);
        return -1;
    }
    *out = client;
    return 0;
}

// Opens stream `stream_id`, an odd id above every earlier stream of the connection, with the HEADERS of a `method`
// request of `path`: content-length when `content_length` is not negative, END_STREAM when `end_stream` is set. The
// stream's response is kept until collo_test_h2_client_read_response.
extern "C" int collo_test_h2_client_send_request(struct collo_test_h2_client* client, uint32_t stream_id,
    const char* method, const char* path, int64_t content_length, int end_stream)
{
    if (client == NULL || method == NULL || path == NULL) {
        return fail("missing HTTP/2 client request input");
    }
    tls_test_error[0] = '\0';
    ERR_clear_error();
    if ((stream_id & 1) == 0 || stream_id > h2_window_max) {
        return fail("HTTP/2 client request needs an odd stream id");
    }
    if (h2_client_find_stream(client, stream_id) != NULL) {
        return fail("HTTP/2 client stream is already open");
    }
    H2TrackedStream* stream = h2_client_find_stream(client, 0);
    if (stream == NULL) {
        return fail("HTTP/2 client has no room for another open stream");
    }
    char length_text[24];
    const char* length_value = NULL;
    if (content_length >= 0) {
        snprintf(length_text, sizeof(length_text), "%lld", static_cast<long long>(content_length));
        length_value = length_text;
    }
    uint8_t header_block[h2_client_header_block_max];
    const int header_len
        = h2_build_request_headers(header_block, sizeof(header_block), method, client->authority, path, length_value);
    if (header_len < 0) {
        return -1;
    }
    memset(stream, 0, sizeof(*stream));
    stream->stream_id = stream_id;
    stream->send_window = client->peer_initial_window;
    const uint8_t flags = static_cast<uint8_t>(h2_flag_end_headers | (end_stream != 0 ? h2_flag_end_stream : 0));
    if (h2_write_frame(client->connection.ssl.get(), h2_frame_headers, flags, stream_id, header_block,
            static_cast<size_t>(header_len))
        != 0) {
        stream->stream_id = 0;
        return -1;
    }
    return 0;
}

// Sends `body_bytes` bytes of filler on open stream `stream_id` in DATA frames of at most `frame_bytes`, within the
// server's frame size and the connection's and the stream's send windows. While a window is closed it reads and
// handles the server's frames, each read bounded by h2_client_io_timeout_seconds. The last frame carries END_STREAM
// when `end_stream` is set, an empty frame when `body_bytes` is 0. `out_sent` gets the bytes sent, which falls short
// of `body_bytes` only when the stream's response ended, or the stream was reset, before the body went out; the
// caller reads the response to learn which.
extern "C" int collo_test_h2_client_send_body(struct collo_test_h2_client* client, uint32_t stream_id,
    uint64_t body_bytes, uint32_t frame_bytes, int end_stream, uint64_t* out_sent)
{
    if (client == NULL || out_sent == NULL) {
        return fail("missing HTTP/2 client body input");
    }
    tls_test_error[0] = '\0';
    ERR_clear_error();
    *out_sent = 0;
    if (frame_bytes == 0) {
        return fail("HTTP/2 client body needs a nonzero frame size");
    }
    H2TrackedStream* stream = stream_id == 0 ? NULL : h2_client_find_stream(client, stream_id);
    if (stream == NULL) {
        return fail("HTTP/2 client stream is not open");
    }
    SSL* ssl = client->connection.ssl.get();
    if (body_bytes == 0) {
        if (end_stream == 0 || stream->done) {
            return 0;
        }
        return h2_write_frame(ssl, h2_frame_data, h2_flag_end_stream, stream_id, NULL, 0);
    }
    // The filler's bytes do not matter; its size bounds one frame.
    static const uint8_t filler[h2_client_frame_payload_max] = {};
    uint64_t sent = 0;
    size_t steps = 0;
    while (sent < body_bytes && !stream->done) {
        if (steps == h2_client_response_frames_max) {
            *out_sent = sent;
            return fail("HTTP/2 client body did not go out within its frame budget");
        }
        steps++;
        const int64_t window = client->connection_send_window < stream->send_window ? client->connection_send_window
                                                                                    : stream->send_window;
        if (window <= 0) {
            if (h2_client_read_frame(client) != 0) {
                *out_sent = sent;
                return -1;
            }
            continue;
        }
        uint64_t chunk = body_bytes - sent;
        if (chunk > frame_bytes) {
            chunk = frame_bytes;
        }
        if (chunk > client->peer_max_frame_size) {
            chunk = client->peer_max_frame_size;
        }
        if (chunk > sizeof(filler)) {
            chunk = sizeof(filler);
        }
        if (chunk > static_cast<uint64_t>(window)) {
            chunk = static_cast<uint64_t>(window);
        }
        const bool last = sent + chunk == body_bytes;
        const uint8_t flags = last && end_stream != 0 ? h2_flag_end_stream : 0;
        if (h2_write_frame(ssl, h2_frame_data, flags, stream_id, filler, static_cast<size_t>(chunk)) != 0) {
            *out_sent = sent;
            return -1;
        }
        sent += chunk;
        client->connection_send_window -= static_cast<int64_t>(chunk);
        stream->send_window -= static_cast<int64_t>(chunk);
    }
    *out_sent = sent;
    return 0;
}

// Reads and handles the server's frames until open stream `stream_id` ends, copies its response to `out` and forgets
// the stream. Frames of the client's other open streams are kept for their own read. Fails when the connection fails
// or the frame budget runs out first.
extern "C" int collo_test_h2_client_read_response(
    struct collo_test_h2_client* client, uint32_t stream_id, struct collo_test_h2_response* out)
{
    if (client == NULL || out == NULL) {
        return fail("missing HTTP/2 client response input");
    }
    tls_test_error[0] = '\0';
    ERR_clear_error();
    memset(out, 0, sizeof(*out));
    H2TrackedStream* stream = stream_id == 0 ? NULL : h2_client_find_stream(client, stream_id);
    if (stream == NULL) {
        return fail("HTTP/2 client stream is not open");
    }
    for (size_t frame_count = 0; frame_count < h2_client_response_frames_max && !stream->done; frame_count++) {
        if (h2_client_read_frame(client) != 0) {
            return -1;
        }
    }
    if (!stream->done) {
        return fail("HTTP/2 response stream did not complete");
    }
    memcpy(out, &stream->response, sizeof(*out));
    memset(stream, 0, sizeof(*stream));
    return 0;
}

static int set_nonblocking(int fd)
{
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) {
        return -1;
    }
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

// Selects h2 when the client offers it, else http/1.1; any other offer gets no ALPN answer.
static int select_egress_test_alpn(
    SSL*, const uint8_t** out, uint8_t* out_len, const uint8_t* in, unsigned in_len, void*)
{
    static const uint8_t h2[] = { 'h', '2' };
    static const uint8_t http11[] = { 'h', 't', 't', 'p', '/', '1', '.', '1' };
    unsigned cursor = 0;
    while (cursor < in_len) {
        const unsigned len = in[cursor++];
        if (len == sizeof(h2) && cursor + len <= in_len && memcmp(in + cursor, h2, len) == 0) {
            *out = h2;
            *out_len = sizeof(h2);
            return SSL_TLSEXT_ERR_OK;
        }
        cursor += len;
    }
    cursor = 0;
    while (cursor < in_len) {
        const unsigned len = in[cursor++];
        if (len == sizeof(http11) && cursor + len <= in_len && memcmp(in + cursor, http11, len) == 0) {
            *out = http11;
            *out_len = sizeof(http11);
            return SSL_TLSEXT_ERR_OK;
        }
        cursor += len;
    }
    return SSL_TLSEXT_ERR_NOACK;
}

// Drives the production egress client shim against a BoringSSL server over a nonblocking socket pair, stepping the
// two handshakes in turn, and reports the protocol the client negotiated. `alpn_offer` takes the production shim's
// COLLO_BORINGSSL_ALPN_OFFER_* values, which this file does not copy: the callers pass
// COLLO_BORINGSSL_ALPN_OFFER_H2_HTTP_1_1 (1) and COLLO_BORINGSSL_ALPN_OFFER_HTTP_1_1 (0). The client context skips
// certificate verification.
static int run_egress_client_alpn_case(const TempFiles* files, int alpn_offer, int* out_application_protocol)
{
    SSL_CTX* server_ctx = NULL;
    SSL* server = NULL;
    struct collo_boringssl_client_ctx* client_ctx = NULL;
    struct collo_boringssl_client_conn* client = NULL;
    int fds[2] = { -1, -1 };
    int rc = -1;
    int server_done = 0;
    int client_done = 0;
    struct collo_boringssl_result client_result;
    memset(&client_result, 0, sizeof(client_result));

    server_ctx = SSL_CTX_new(TLS_server_method());
    if (server_ctx == NULL || SSL_CTX_use_certificate_chain_file(server_ctx, files->server_cert) != 1
        || SSL_CTX_use_PrivateKey_file(server_ctx, files->server_key, SSL_FILETYPE_PEM) != 1
        || SSL_CTX_check_private_key(server_ctx) != 1) {
        fail("create egress ALPN test server");
        goto done;
    }
    SSL_CTX_set_alpn_select_cb(server_ctx, select_egress_test_alpn, NULL);
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) != 0 || set_nonblocking(fds[0]) != 0 || set_nonblocking(fds[1]) != 0) {
        fail("create egress ALPN socket pair");
        goto done;
    }
    server = SSL_new(server_ctx);
    if (server == NULL || SSL_set_fd(server, fds[0]) != 1) {
        fail("create egress ALPN server connection");
        goto done;
    }
    SSL_set_accept_state(server);
    if (collo_boringssl_client_ctx_new(1, &client_ctx) != 0
        || collo_boringssl_client_conn_new(client_ctx, fds[1], "public.example", alpn_offer, NULL, 0, &client) != 0) {
        fail("create production egress TLS client connection");
        goto done;
    }

    for (size_t attempt = 0; attempt < 10000; attempt++) {
        if (!client_done) {
            if (collo_boringssl_client_handshake_step(client, &client_result) != 0) {
                fail("drive production egress TLS client handshake");
                goto done;
            }
            if (client_result.status == COLLO_BORINGSSL_OK) {
                client_done = 1;
            } else if (client_result.status != COLLO_BORINGSSL_WANT_READ
                && client_result.status != COLLO_BORINGSSL_WANT_WRITE) {
                fail("production egress TLS client handshake failed");
                goto done;
            }
        }
        if (!server_done) {
            const int server_rc = SSL_do_handshake(server);
            if (server_rc == 1) {
                server_done = 1;
            } else {
                const int server_error = SSL_get_error(server, server_rc);
                if (server_error != SSL_ERROR_WANT_READ && server_error != SSL_ERROR_WANT_WRITE) {
                    fail("egress ALPN test server handshake failed");
                    goto done;
                }
            }
        }
        if (client_done && server_done) {
            *out_application_protocol = client_result.application_protocol;
            rc = 0;
            goto done;
        }
    }
    fail("egress ALPN handshake timed out");

done:
    if (client != NULL) {
        collo_boringssl_client_conn_free(client);
    }
    if (client_ctx != NULL) {
        collo_boringssl_client_ctx_free(client_ctx);
    }
    if (server != NULL) {
        SSL_free(server);
    }
    if (server_ctx != NULL) {
        SSL_CTX_free(server_ctx);
    }
    if (fds[0] >= 0) {
        close(fds[0]);
    }
    if (fds[1] >= 0) {
        close(fds[1]);
    }
    return rc;
}

// Drives the production server shim against a BoringSSL client over a socket
// pair. With `expect_failure` set, a handshake either side aborts counts as the
// expected outcome and the outputs keep their unset values.
static int run_handshake_case(const TempFiles* files, const char* server_tls12_cipher_list, int server_tls13_policy,
    uint16_t client_min_proto, uint16_t client_max_proto, const uint8_t* client_alpn_wire,
    unsigned client_alpn_wire_len, int expect_failure, int* out_application_protocol, int* out_tls_version)
{
    static const char server_name[] = "visible.example.test";
    struct collo_boringssl_ctx* server_ctx = NULL;
    struct collo_boringssl_conn* server = NULL;
    SSL_CTX* client_ctx = NULL;
    SSL* client = NULL;
    int fds[2] = { -1, -1 };
    int rc = -1;
    int server_application_protocol = COLLO_BORINGSSL_ALPN_UNSPECIFIED;
    int server_tls_version = 0;

    *out_application_protocol = COLLO_BORINGSSL_ALPN_UNSPECIFIED;
    *out_tls_version = 0;

    if (collo_boringssl_ctx_new_ex(
            files->server_cert, files->server_key, server_tls12_cipher_list, server_tls13_policy, &server_ctx)
        != 0) {
        fail("create production BoringSSL server context ex");
        goto done;
    }
    client_ctx = new_client_context(files);
    if (client_ctx == NULL) {
        fail("create BoringSSL client context");
        goto done;
    }
    client = SSL_new(client_ctx);
    if (client == NULL) {
        fail("create BoringSSL client");
        goto done;
    }
    SSL_set_connect_state(client);
    if (client_min_proto != 0 && SSL_set_min_proto_version(client, client_min_proto) != 1) {
        fail("set client minimum TLS protocol");
        goto done;
    }
    if (client_max_proto != 0 && SSL_set_max_proto_version(client, client_max_proto) != 1) {
        fail("set client maximum TLS protocol");
        goto done;
    }
    if (SSL_set_tlsext_host_name(client, server_name) != 1) {
        fail("set client SNI");
        goto done;
    }
    if (SSL_set1_host(client, server_name) != 1) {
        fail("set client verify host");
        goto done;
    }
    if (client_alpn_wire != NULL && SSL_set_alpn_protos(client, client_alpn_wire, client_alpn_wire_len) != 0) {
        fail("set client ALPN protocols");
        goto done;
    }
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) != 0 || set_nonblocking(fds[0]) != 0 || set_nonblocking(fds[1]) != 0) {
        fail("create nonblocking TLS socketpair");
        goto done;
    }
    if (collo_boringssl_conn_new(server_ctx, fds[0], &server) != 0) {
        fail("create production BoringSSL server connection");
        goto done;
    }
    fds[0] = -1;
    if (SSL_set_fd(client, fds[1]) != 1) {
        fail("attach BoringSSL client fd");
        goto done;
    }
    fds[1] = -1;

    for (size_t i = 0; i < 10000; i++) {
        int client_ret = SSL_do_handshake(client);
        int client_err = SSL_get_error(client, client_ret);
        int client_done = client_ret == 1;
        int client_failed = !client_done && client_err != SSL_ERROR_WANT_READ && client_err != SSL_ERROR_WANT_WRITE
            && client_err != SSL_ERROR_PENDING_TICKET;
        uint32_t client_error = client_failed ? ERR_peek_last_error() : 0;

        struct collo_boringssl_result server_result;
        memset(&server_result, 0, sizeof(server_result));
        if (collo_boringssl_handshake_step(server, &server_result) != 0) {
            fail("production BoringSSL server handshake step failed");
            goto done;
        }
        if (server_result.status != COLLO_BORINGSSL_OK && server_result.status != COLLO_BORINGSSL_WANT_READ
            && server_result.status != COLLO_BORINGSSL_WANT_WRITE) {
            if (expect_failure) {
                rc = 0;
                goto done;
            }
            if (client_error != 0) {
                char detail[256];
                ERR_error_string_n(client_error, detail, sizeof(detail));
                snprintf(tls_test_error, sizeof(tls_test_error),
                    "BoringSSL client handshake failed before server completed: %s", detail);
                goto done;
            }
            fail("production BoringSSL server handshake failed");
            goto done;
        }
        int server_done = server_result.status == COLLO_BORINGSSL_OK;
        if (server_done) {
            server_application_protocol = server_result.application_protocol;
            server_tls_version = server_result.tls_version;
        }

        if (client_failed) {
            if (expect_failure) {
                rc = 0;
                goto done;
            }
            fail("BoringSSL client handshake failed");
            goto done;
        }

        if (client_done && server_done) {
            *out_application_protocol = server_application_protocol;
            *out_tls_version = server_tls_version;
            rc = 0;
            goto done;
        }
    }

    fail("TLS handshake test timed out");

done:
    if (server != NULL) {
        collo_boringssl_conn_free(server);
    }
    if (client != NULL) {
        SSL_free(client);
    }
    if (client_ctx != NULL) {
        SSL_CTX_free(client_ctx);
    }
    if (server_ctx != NULL) {
        collo_boringssl_ctx_free(server_ctx);
    }
    if (fds[0] >= 0) {
        close(fds[0]);
    }
    if (fds[1] >= 0) {
        close(fds[1]);
    }
    return rc;
}

static int run_alpn_case(const TempFiles* files, const uint8_t* client_alpn_wire, unsigned client_alpn_wire_len,
    int expect_failure, int* out_application_protocol)
{
    int tls_version = 0;
    return run_handshake_case(files, collo_test_tls12_cipher_list, COLLO_TLS13_POLICY_ALL_SUPPORTED, 0, 0,
        client_alpn_wire, client_alpn_wire_len, expect_failure, out_application_protocol, &tls_version);
}

extern "C" int collo_test_tls_alpn_end_to_end(struct collo_test_tls_alpn_result* out)
{
    if (out == NULL) {
        return fail("missing TLS/ALPN test output");
    }
    tls_test_error[0] = '\0';
    ERR_clear_error();
    memset(out, 0, sizeof(*out));

    TempFiles files;
    memset(&files, 0, sizeof(files));
    if (init_temp_files(&files) != 0) {
        return -1;
    }

    static const uint8_t h2_and_http11[] = {
        2,
        'h',
        '2',
        8,
        'h',
        't',
        't',
        'p',
        '/',
        '1',
        '.',
        '1',
    };
    static const uint8_t http11_only[] = {
        8,
        'h',
        't',
        't',
        'p',
        '/',
        '1',
        '.',
        '1',
    };
    static const uint8_t unsupported_only[] = {
        3,
        'f',
        'o',
        'o',
    };

    int rc = -1;
    if (run_alpn_case(&files, h2_and_http11, sizeof(h2_and_http11), 0, &out->h2_protocol) != 0) {
        goto done;
    }
    if (run_alpn_case(&files, http11_only, sizeof(http11_only), 1, &out->http11_protocol) != 0) {
        goto done;
    }
    if (run_alpn_case(&files, unsupported_only, sizeof(unsupported_only), 1, &out->unsupported_protocol) != 0) {
        goto done;
    }

    rc = 0;

done:
    cleanup_temp_files(&files);
    return rc;
}

extern "C" int collo_test_egress_tls_alpn_end_to_end(struct collo_test_egress_tls_alpn_result* out)
{
    if (out == NULL) {
        return fail("missing egress TLS/ALPN test output");
    }
    tls_test_error[0] = '\0';
    ERR_clear_error();
    memset(out, 0, sizeof(*out));

    TempFiles files;
    memset(&files, 0, sizeof(files));
    if (init_temp_files(&files) != 0) {
        return -1;
    }

    int rc = -1;
    if (run_egress_client_alpn_case(&files, 1, &out->h2_protocol) != 0) {
        goto done;
    }
    if (run_egress_client_alpn_case(&files, 0, &out->http11_protocol) != 0) {
        goto done;
    }
    rc = 0;

done:
    cleanup_temp_files(&files);
    return rc;
}

extern "C" int collo_test_tls_policy_end_to_end(struct collo_test_tls_policy_result* out)
{
    if (out == NULL) {
        return fail("missing TLS policy test output");
    }
    tls_test_error[0] = '\0';
    ERR_clear_error();
    memset(out, 0, sizeof(*out));

    TempFiles files;
    memset(&files, 0, sizeof(files));
    if (init_temp_files(&files) != 0) {
        return -1;
    }

    int rc = -1;
    int application_protocol = COLLO_BORINGSSL_ALPN_UNSPECIFIED;
    // A TLS 1.3 client that offers AES-GCM completes under the AES-GCM-only
    // policy.
    if (run_handshake_case(&files, collo_test_tls12_cipher_list, COLLO_TLS13_POLICY_AES_GCM_ONLY, TLS1_3_VERSION,
            TLS1_3_VERSION, NULL, 0, 0, &application_protocol, &out->aes_gcm_only_tls_version)
        != 0) {
        goto done;
    }

    // With TLS 1.3 disabled, a TLS 1.2 client still completes.
    if (run_handshake_case(&files, collo_test_tls12_cipher_list, COLLO_TLS13_POLICY_DISABLED, TLS1_2_VERSION,
            TLS1_2_VERSION, NULL, 0, 0, &application_protocol, &out->tls13_disabled_tls_version)
        != 0) {
        goto done;
    }

    if (collo_boringssl_test_tls13_policy_cipher_flags() != 0) {
        fail("test production TLS 1.3 cipher-policy helper");
        goto done;
    }
    out->tls13_policy_cipher_flags_ok = 1;

    rc = 0;

done:
    cleanup_temp_files(&files);
    return rc;
}

// The BoringSSL shim the Zig side declares in `root.zig`. In the server it runs the TLS handshake with clients, exports
// the negotiated keys for kTLS and generates the self-signed certificate the server presents when its configuration
// names none. In the gateway it holds the client contexts and connections of outbound fetches, with their session
// cache.
//
// Each `*_new` hands the caller a handle it releases with the matching `*_free`. A client connection keeps a raw
// pointer to its context's session cache, so a client context outlives its connections. Contexts may be shared between
// threads, and the session cache takes its own mutex, but a connection is used by one thread at a time, as BoringSSL
// requires of an `SSL`.
//
// An exported function reports failure through `collo_boringssl_last_error`, a buffer of the calling thread, so a
// caller reads the message on the thread that got the failing status. Out-parameters are cleared once the arguments
// pass validation, so a caller initializes its own. Private key bytes the shim copies live in BoringSSL's allocations,
// which BoringSSL zeroes before freeing, except the stdio buffer a key read from a file passes through. A server
// context keeps its key until `collo_boringssl_ctx_free`, and a failed generation cleanses the caller's key buffer.

#include <openssl/asn1.h>
#include <openssl/bio.h>
#include <openssl/bn.h>
#include <openssl/bytestring.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/mem.h>
#include <openssl/nid.h>
#include <openssl/obj.h>
#include <openssl/pem.h>
#include <openssl/rand.h>
#include <openssl/ssl.h>
#include <openssl/tls1.h>
#include <openssl/x509.h>

#include <arpa/inet.h>
#include <limits.h>
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

enum {
    COLLO_BORINGSSL_OK = 0,
    COLLO_BORINGSSL_WANT_READ = 1,
    COLLO_BORINGSSL_WANT_WRITE = 2,
    COLLO_BORINGSSL_FAILED = 3,
    COLLO_BORINGSSL_EOF = 4,
};

enum {
    COLLO_BORINGSSL_ALPN_UNSPECIFIED = 0,
    COLLO_BORINGSSL_ALPN_HTTP_1_1 = 1,
    COLLO_BORINGSSL_ALPN_H2 = 2,
};

enum {
    COLLO_BORINGSSL_ALPN_OFFER_HTTP_1_1 = 0,
    COLLO_BORINGSSL_ALPN_OFFER_H2_HTTP_1_1 = 1,
    COLLO_BORINGSSL_ALPN_OFFER_H2_ONLY = 2,
};

struct collo_boringssl_result {
    int status;
    uint16_t tls_version;
    uint8_t application_protocol;
    uint8_t reserved0;
    uint32_t cipher_id;
};

struct collo_boringssl_ktls_key_material {
    uint16_t tls_version;
    uint16_t reserved0;
    uint32_t cipher_id;
    // TLS 1.3 leaves the keys, salts and IVs zero: `common/tls/ktls.zig` derives the kernel's keys from the traffic
    // secrets below.
    uint8_t rx_key[32];
    uint8_t tx_key[32];
    uint8_t rx_salt[4];
    uint8_t tx_salt[4];
    uint8_t rx_iv[12];
    uint8_t tx_iv[12];
    uint8_t read_seq[8];
    uint8_t write_seq[8];
    // TLS 1.3 only: the current traffic secrets, from which the initial keys and each KeyUpdate's next generation are
    // derived. TLS 1.2 leaves them zero.
    uint8_t read_secret[64];
    uint8_t write_secret[64];
    size_t key_len;
    size_t secret_len;
};

static_assert(sizeof(struct collo_boringssl_result) == 12, "collo_boringssl_result size mismatch");
static_assert(offsetof(struct collo_boringssl_result, status) == 0, "collo_boringssl_result.status offset mismatch");
static_assert(
    offsetof(struct collo_boringssl_result, tls_version) == 4, "collo_boringssl_result.tls_version offset mismatch");
static_assert(offsetof(struct collo_boringssl_result, application_protocol) == 6,
    "collo_boringssl_result.application_protocol offset mismatch");
static_assert(
    offsetof(struct collo_boringssl_result, reserved0) == 7, "collo_boringssl_result.reserved0 offset mismatch");
static_assert(
    offsetof(struct collo_boringssl_result, cipher_id) == 8, "collo_boringssl_result.cipher_id offset mismatch");

static_assert(
    sizeof(struct collo_boringssl_ktls_key_material) == 264, "collo_boringssl_ktls_key_material size mismatch");
static_assert(offsetof(struct collo_boringssl_ktls_key_material, tls_version) == 0,
    "collo_boringssl_ktls_key_material.tls_version offset mismatch");
static_assert(offsetof(struct collo_boringssl_ktls_key_material, reserved0) == 2,
    "collo_boringssl_ktls_key_material.reserved0 offset mismatch");
static_assert(offsetof(struct collo_boringssl_ktls_key_material, cipher_id) == 4,
    "collo_boringssl_ktls_key_material.cipher_id offset mismatch");
static_assert(offsetof(struct collo_boringssl_ktls_key_material, rx_key) == 8,
    "collo_boringssl_ktls_key_material.rx_key offset mismatch");
static_assert(offsetof(struct collo_boringssl_ktls_key_material, tx_key) == 40,
    "collo_boringssl_ktls_key_material.tx_key offset mismatch");
static_assert(offsetof(struct collo_boringssl_ktls_key_material, rx_salt) == 72,
    "collo_boringssl_ktls_key_material.rx_salt offset mismatch");
static_assert(offsetof(struct collo_boringssl_ktls_key_material, tx_salt) == 76,
    "collo_boringssl_ktls_key_material.tx_salt offset mismatch");
static_assert(offsetof(struct collo_boringssl_ktls_key_material, rx_iv) == 80,
    "collo_boringssl_ktls_key_material.rx_iv offset mismatch");
static_assert(offsetof(struct collo_boringssl_ktls_key_material, tx_iv) == 92,
    "collo_boringssl_ktls_key_material.tx_iv offset mismatch");
static_assert(offsetof(struct collo_boringssl_ktls_key_material, read_seq) == 104,
    "collo_boringssl_ktls_key_material.read_seq offset mismatch");
static_assert(offsetof(struct collo_boringssl_ktls_key_material, write_seq) == 112,
    "collo_boringssl_ktls_key_material.write_seq offset mismatch");
static_assert(offsetof(struct collo_boringssl_ktls_key_material, read_secret) == 120,
    "collo_boringssl_ktls_key_material.read_secret offset mismatch");
static_assert(offsetof(struct collo_boringssl_ktls_key_material, write_secret) == 184,
    "collo_boringssl_ktls_key_material.write_secret offset mismatch");
static_assert(offsetof(struct collo_boringssl_ktls_key_material, key_len) == 248,
    "collo_boringssl_ktls_key_material.key_len offset mismatch");
static_assert(offsetof(struct collo_boringssl_ktls_key_material, secret_len) == 256,
    "collo_boringssl_ktls_key_material.secret_len offset mismatch");

enum {
    COLLO_BORINGSSL_SAN_DNS = 0,
    COLLO_BORINGSSL_SAN_IP = 1,
};

// One subjectAltName entry of a generated certificate: a DNS name of letters, digits, hyphens and
// dots when `kind` is COLLO_BORINGSSL_SAN_DNS, or the 4 or 16 bytes of an IPv4 or IPv6 address in
// network order when it is COLLO_BORINGSSL_SAN_IP. `value` is borrowed for the call.
struct collo_boringssl_subject_alt_name {
    const uint8_t* value;
    size_t value_len;
    uint8_t kind;
    uint8_t reserved0[7];
};

static_assert(sizeof(struct collo_boringssl_subject_alt_name) == 24, "collo_boringssl_subject_alt_name size mismatch");
static_assert(offsetof(struct collo_boringssl_subject_alt_name, value) == 0,
    "collo_boringssl_subject_alt_name.value offset mismatch");
static_assert(offsetof(struct collo_boringssl_subject_alt_name, value_len) == 8,
    "collo_boringssl_subject_alt_name.value_len offset mismatch");
static_assert(offsetof(struct collo_boringssl_subject_alt_name, kind) == 16,
    "collo_boringssl_subject_alt_name.kind offset mismatch");
static_assert(offsetof(struct collo_boringssl_subject_alt_name, reserved0) == 17,
    "collo_boringssl_subject_alt_name.reserved0 offset mismatch");

struct collo_boringssl_ctx {
    SSL_CTX* ctx;
    int tls13_policy;
};

struct collo_boringssl_conn {
    SSL* ssl;
    int tls13_policy;
};

// The client session cache, one per client context. BoringSSL never caches client sessions itself: it hands each new
// one to the new-session callback, and a TLS 1.3 ticket arrives after the handshake, on whichever thread is reading
// that connection. The cache therefore lives here, behind its own mutex. Its key is opaque to the shim;
// `buildSessionKey` in `egress/client/tls.zig` composes it so that a ticket never links traffic across tenants, and
// COLLO_CLIENT_SESSION_KEY_MAX must hold that file's `max_session_key_bytes`, since a longer key fails the connection.
// The cache holds at most COLLO_CLIENT_SESSION_CACHE_BUCKETS keys, and an insert whose probe window is full evicts the
// window's least recently stored key. Each key keeps two sessions, because a BoringSSL server sends two tickets by
// default and a TLS 1.3 ticket is used once.
#define COLLO_CLIENT_SESSION_KEY_MAX 304
#define COLLO_CLIENT_SESSION_CACHE_BUCKETS 4096
#define COLLO_CLIENT_SESSION_CACHE_PROBES 8
#define COLLO_CLIENT_SESSIONS_PER_KEY 2

struct collo_client_session_entry {
    uint64_t key_hash;
    uint32_t key_len;
    uint64_t stamp;
    uint8_t key[COLLO_CLIENT_SESSION_KEY_MAX];
    SSL_SESSION* sessions[COLLO_CLIENT_SESSIONS_PER_KEY];
};

struct collo_client_session_cache {
    pthread_mutex_t mutex;
    uint64_t stamp_counter;
    struct collo_client_session_entry* entries[COLLO_CLIENT_SESSION_CACHE_BUCKETS];
};

struct collo_boringssl_client_ctx {
    SSL_CTX* ctx;
    int insecure_skip_verify;
    struct collo_client_session_cache* session_cache;
};

struct collo_boringssl_client_conn {
    SSL* ssl;
    BIO* rbio;
    BIO* wbio;
    int insecure_skip_verify;
    struct collo_client_session_cache* session_cache;
    uint32_t session_key_len;
    uint8_t session_key[COLLO_CLIENT_SESSION_KEY_MAX];
};

// FNV-1a's xor-multiply loop with the 64-bit FNV prime. The seed is not FNV's 64-bit offset basis, so the hashes
// differ from published FNV-1a. The cache needs only their spread over buckets, and a match compares the whole key.
static uint64_t collo_client_session_key_hash(const uint8_t* key, size_t key_len)
{
    uint64_t hash = 1469598103934665603ull;
    for (size_t i = 0; i < key_len; i++) {
        hash ^= key[i];
        hash *= 1099511628211ull;
    }
    return hash;
}

static struct collo_client_session_cache* collo_client_session_cache_new(void)
{
    struct collo_client_session_cache* cache = (struct collo_client_session_cache*)calloc(1, sizeof(*cache));
    if (cache == NULL) {
        return NULL;
    }
    if (pthread_mutex_init(&cache->mutex, NULL) != 0) {
        free(cache);
        return NULL;
    }
    return cache;
}

static void collo_client_session_cache_free(struct collo_client_session_cache* cache)
{
    if (cache == NULL) {
        return;
    }
    for (size_t i = 0; i < COLLO_CLIENT_SESSION_CACHE_BUCKETS; i++) {
        struct collo_client_session_entry* entry = cache->entries[i];
        if (entry == NULL) {
            continue;
        }
        for (size_t j = 0; j < COLLO_CLIENT_SESSIONS_PER_KEY; j++) {
            SSL_SESSION_free(entry->sessions[j]);
        }
        OPENSSL_cleanse(entry, sizeof(*entry));
        free(entry);
    }
    pthread_mutex_destroy(&cache->mutex);
    free(cache);
}

static bool collo_client_session_entry_matches(
    const struct collo_client_session_entry* entry, uint64_t key_hash, const uint8_t* key, size_t key_len)
{
    return entry->key_len == key_len && entry->key_hash == key_hash && memcmp(entry->key, key, key_len) == 0;
}

static bool collo_client_session_expired(const SSL_SESSION* session, uint64_t now)
{
    const uint64_t start = SSL_SESSION_get_time(session);
    const uint32_t timeout = SSL_SESSION_get_timeout(session);
    return now >= start && now - start >= timeout;
}

// Takes ownership of the caller's session reference.
static void collo_client_session_cache_insert(
    struct collo_client_session_cache* cache, const uint8_t* key, size_t key_len, SSL_SESSION* session)
{
    const uint64_t hash = collo_client_session_key_hash(key, key_len);
    pthread_mutex_lock(&cache->mutex);
    struct collo_client_session_entry* slot = NULL;
    struct collo_client_session_entry** empty_slot = NULL;
    struct collo_client_session_entry* oldest = NULL;
    for (size_t probe = 0; probe < COLLO_CLIENT_SESSION_CACHE_PROBES; probe++) {
        struct collo_client_session_entry** entry_slot
            = &cache->entries[(hash + probe) % COLLO_CLIENT_SESSION_CACHE_BUCKETS];
        struct collo_client_session_entry* entry = *entry_slot;
        if (entry == NULL) {
            if (empty_slot == NULL) {
                empty_slot = entry_slot;
            }
            continue;
        }
        if (collo_client_session_entry_matches(entry, hash, key, key_len)) {
            slot = entry;
            break;
        }
        if (oldest == NULL || entry->stamp < oldest->stamp) {
            oldest = entry;
        }
    }
    if (slot == NULL && empty_slot != NULL) {
        slot = (struct collo_client_session_entry*)calloc(1, sizeof(*slot));
        if (slot == NULL) {
            pthread_mutex_unlock(&cache->mutex);
            SSL_SESSION_free(session);
            return;
        }
        *empty_slot = slot;
    }
    if (slot == NULL) {
        slot = oldest;
    }
    if (slot == NULL) {
        pthread_mutex_unlock(&cache->mutex);
        SSL_SESSION_free(session);
        return;
    }
    if (!collo_client_session_entry_matches(slot, hash, key, key_len)) {
        for (size_t j = 0; j < COLLO_CLIENT_SESSIONS_PER_KEY; j++) {
            SSL_SESSION_free(slot->sessions[j]);
            slot->sessions[j] = NULL;
        }
        OPENSSL_cleanse(slot->key, sizeof(slot->key));
        memcpy(slot->key, key, key_len);
        slot->key_len = (uint32_t)key_len;
        slot->key_hash = hash;
    }
    // Sessions are kept newest first. The shift stops at the first hole a single-use take left, so only a full list
    // drops its oldest session.
    size_t shift_end = COLLO_CLIENT_SESSIONS_PER_KEY - 1;
    for (size_t j = 0; j < COLLO_CLIENT_SESSIONS_PER_KEY; j++) {
        if (slot->sessions[j] == NULL) {
            shift_end = j;
            break;
        }
    }
    SSL_SESSION_free(slot->sessions[shift_end]);
    for (size_t j = shift_end; j > 0; j--) {
        slot->sessions[j] = slot->sessions[j - 1];
    }
    slot->sessions[0] = session;
    slot->stamp = ++cache->stamp_counter;
    pthread_mutex_unlock(&cache->mutex);
}

// Returns a session reference owned by the caller, or NULL. A TLS 1.3 session is used once and leaves the cache; a
// TLS 1.2 session stays, and the caller gets a new reference to it. Expired sessions met on the way are freed.
static SSL_SESSION* collo_client_session_cache_take(
    struct collo_client_session_cache* cache, const uint8_t* key, size_t key_len)
{
    const uint64_t hash = collo_client_session_key_hash(key, key_len);
    const uint64_t now = (uint64_t)time(NULL);
    SSL_SESSION* taken = NULL;
    pthread_mutex_lock(&cache->mutex);
    for (size_t probe = 0; probe < COLLO_CLIENT_SESSION_CACHE_PROBES; probe++) {
        struct collo_client_session_entry* entry = cache->entries[(hash + probe) % COLLO_CLIENT_SESSION_CACHE_BUCKETS];
        if (entry == NULL) {
            continue;
        }
        if (!collo_client_session_entry_matches(entry, hash, key, key_len)) {
            continue;
        }
        for (size_t j = 0; j < COLLO_CLIENT_SESSIONS_PER_KEY; j++) {
            SSL_SESSION* session = entry->sessions[j];
            if (session == NULL) {
                continue;
            }
            if (collo_client_session_expired(session, now)) {
                SSL_SESSION_free(session);
                entry->sessions[j] = NULL;
                continue;
            }
            if (SSL_SESSION_should_be_single_use(session)) {
                entry->sessions[j] = NULL;
            } else {
                SSL_SESSION_up_ref(session);
            }
            taken = session;
            break;
        }
        break;
    }
    pthread_mutex_unlock(&cache->mutex);
    return taken;
}

// Returning 1 tells BoringSSL the cache took the session's reference; 0 leaves the reference with BoringSSL.
static int collo_boringssl_client_new_session_cb(SSL* ssl, SSL_SESSION* session)
{
    struct collo_boringssl_client_conn* conn = (struct collo_boringssl_client_conn*)SSL_get_app_data(ssl);
    if (conn == NULL || conn->session_cache == NULL || conn->session_key_len == 0) {
        return 0;
    }
    collo_client_session_cache_insert(conn->session_cache, conn->session_key, conn->session_key_len, session);
    return 1;
}

enum collo_boringssl_tls13_policy {
    collo_boringssl_tls13_policy_all_supported = 0,
    collo_boringssl_tls13_policy_aes_gcm_only = 1,
    collo_boringssl_tls13_policy_disabled = 2,
};

// The default TLS 1.2 suites, ECDHE with AES-GCM: the only TLS 1.2 ciphers whose keys
// `collo_boringssl_export_tls12_key_material` can export for kTLS.
static const char collo_default_tls12_cipher_list[] = "ECDHE-RSA-AES128-GCM-SHA256:"
                                                      "ECDHE-ECDSA-AES128-GCM-SHA256:"
                                                      "ECDHE-RSA-AES256-GCM-SHA384:"
                                                      "ECDHE-ECDSA-AES256-GCM-SHA384";

static constexpr uint16_t collo_tls13_aes_128_gcm_sha256 = 0x1301;
static constexpr uint16_t collo_tls13_aes_256_gcm_sha384 = 0x1302;
static constexpr uint16_t collo_tls13_chacha20_poly1305_sha256 = 0x1303;
static constexpr uint16_t collo_tls12_ecdhe_rsa_aes_128_gcm_sha256 = 0xc02f;
static constexpr uint16_t collo_tls12_ecdhe_ecdsa_aes_128_gcm_sha256 = 0xc02b;
static constexpr uint16_t collo_tls12_ecdhe_rsa_aes_256_gcm_sha384 = 0xc030;
static constexpr uint16_t collo_tls12_ecdhe_ecdsa_aes_256_gcm_sha384 = 0xc02c;

static thread_local char collo_boringssl_last_error_buffer[512];

static void collo_boringssl_clear_last_error()
{
    collo_boringssl_last_error_buffer[0] = '\0';
    ERR_clear_error();
}

static int collo_boringssl_fail(const char* context)
{
    uint32_t err = ERR_peek_last_error();
    if (err == 0) {
        snprintf(collo_boringssl_last_error_buffer, sizeof(collo_boringssl_last_error_buffer), "%s", context);
        return -1;
    }

    char detail[256];
    ERR_error_string_n(err, detail, sizeof(detail));
    snprintf(collo_boringssl_last_error_buffer, sizeof(collo_boringssl_last_error_buffer), "%s: %s", context, detail);
    return -1;
}

static bool collo_alpn_list_contains(const uint8_t* wire, unsigned wire_len, const uint8_t* proto, uint8_t proto_len)
{
    unsigned cursor = 0;
    while (cursor < wire_len) {
        const uint8_t len = wire[cursor++];
        if (len == 0 || cursor + len > wire_len) {
            return false;
        }
        if (len == proto_len && memcmp(wire + cursor, proto, len) == 0) {
            return true;
        }
        cursor += len;
    }
    return false;
}

// Selects h2 or refuses the client with a fatal alert, since the server keeps no HTTP/1.1 path. A client that sends no
// ALPN never reaches this callback; `requireIngressH2Alpn` in `server/tls/root.zig` refuses it after the handshake.
static int collo_boringssl_select_alpn(
    SSL*, const uint8_t** out, uint8_t* out_len, const uint8_t* in, unsigned in_len, void*)
{
    static const uint8_t h2[] = { 'h', '2' };
    if (collo_alpn_list_contains(in, in_len, h2, sizeof(h2))) {
        *out = h2;
        *out_len = sizeof(h2);
        return SSL_TLSEXT_ERR_OK;
    }
    return SSL_TLSEXT_ERR_ALERT_FATAL;
}

static uint8_t collo_boringssl_selected_alpn(SSL* ssl)
{
    const uint8_t* selected = NULL;
    unsigned selected_len = 0;
    SSL_get0_alpn_selected(ssl, &selected, &selected_len);
    if (selected == NULL || selected_len == 0) {
        return COLLO_BORINGSSL_ALPN_UNSPECIFIED;
    }
    if (selected_len == 2 && memcmp(selected, "h2", 2) == 0) {
        return COLLO_BORINGSSL_ALPN_H2;
    }
    if (selected_len == 8 && memcmp(selected, "http/1.1", 8) == 0) {
        return COLLO_BORINGSSL_ALPN_HTTP_1_1;
    }
    return COLLO_BORINGSSL_ALPN_UNSPECIFIED;
}

static bool collo_boringssl_is_ip_literal(const char* host)
{
    uint8_t bytes[sizeof(struct in6_addr)];
    return inet_pton(AF_INET, host, bytes) == 1 || inet_pton(AF_INET6, host, bytes) == 1;
}

static int collo_boringssl_client_alpn_for_offer(int alpn_offer, const uint8_t** out, unsigned* out_len)
{
    static const uint8_t alpn_http_1_1[] = { 8, 'h', 't', 't', 'p', '/', '1', '.', '1' };
    static const uint8_t alpn_h2_http_1_1[] = { 2, 'h', '2', 8, 'h', 't', 't', 'p', '/', '1', '.', '1' };
    static const uint8_t alpn_h2[] = { 2, 'h', '2' };
    if (out == NULL || out_len == NULL) {
        return collo_boringssl_fail("invalid BoringSSL client ALPN output arguments");
    }
    switch (alpn_offer) {
    case COLLO_BORINGSSL_ALPN_OFFER_HTTP_1_1:
        *out = alpn_http_1_1;
        *out_len = sizeof(alpn_http_1_1);
        return 0;
    case COLLO_BORINGSSL_ALPN_OFFER_H2_HTTP_1_1:
        *out = alpn_h2_http_1_1;
        *out_len = sizeof(alpn_h2_http_1_1);
        return 0;
    case COLLO_BORINGSSL_ALPN_OFFER_H2_ONLY:
        *out = alpn_h2;
        *out_len = sizeof(alpn_h2);
        return 0;
    default:
        return collo_boringssl_fail("invalid BoringSSL client ALPN offer");
    }
}

static int collo_boringssl_client_configure_ssl(struct collo_boringssl_client_ctx* ctx,
    struct collo_boringssl_client_conn* conn, const char* server_name, int alpn_offer)
{
    if (ctx == NULL || conn == NULL || conn->ssl == NULL || server_name == NULL || server_name[0] == '\0') {
        return collo_boringssl_fail("invalid BoringSSL client SSL configuration arguments");
    }

    const uint8_t* alpn = NULL;
    unsigned alpn_len = 0;
    if (collo_boringssl_client_alpn_for_offer(alpn_offer, &alpn, &alpn_len) != 0) {
        return -1;
    }

    // A certificate names an address in an IP subjectAltName, and RFC 6066 §3 forbids an address in SNI, so an IP
    // literal is verified as an address and sent without SNI.
    if (!ctx->insecure_skip_verify) {
        if (collo_boringssl_is_ip_literal(server_name)) {
            if (X509_VERIFY_PARAM_set1_ip_asc(SSL_get0_param(conn->ssl), server_name) != 1) {
                return collo_boringssl_fail("set BoringSSL client certificate IP");
            }
        } else if (SSL_set1_host(conn->ssl, server_name) != 1) {
            return collo_boringssl_fail("set BoringSSL client certificate host");
        }
    }
    if (!collo_boringssl_is_ip_literal(server_name) && SSL_set_tlsext_host_name(conn->ssl, server_name) != 1) {
        return collo_boringssl_fail("set BoringSSL client SNI");
    }
    if (SSL_set_alpn_protos(conn->ssl, alpn, alpn_len) != 0) {
        return collo_boringssl_fail("set BoringSSL client ALPN protocols");
    }
    // Partial writes let `collo_boringssl_client_write` report how many bytes one record took, and a retry after
    // WANT_WRITE may pass the same bytes from a different address.
    SSL_set_mode(conn->ssl, SSL_MODE_ENABLE_PARTIAL_WRITE | SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER);
    SSL_set_app_data(conn->ssl, conn);
    SSL_set_connect_state(conn->ssl);
    return 0;
}

static int collo_boringssl_client_session_setup(struct collo_boringssl_client_ctx* ctx,
    struct collo_boringssl_client_conn* conn, const uint8_t* session_key, size_t session_key_len)
{
    if (session_key == NULL || session_key_len == 0) {
        return 0;
    }
    if (session_key_len > COLLO_CLIENT_SESSION_KEY_MAX) {
        return collo_boringssl_fail("BoringSSL client session key too long");
    }
    if (ctx->session_cache == NULL) {
        return 0;
    }
    memcpy(conn->session_key, session_key, session_key_len);
    conn->session_key_len = (uint32_t)session_key_len;
    conn->session_cache = ctx->session_cache;
    SSL_SESSION* session = collo_client_session_cache_take(ctx->session_cache, session_key, session_key_len);
    if (session != NULL) {
        const int ok = SSL_set_session(conn->ssl, session);
        SSL_SESSION_free(session);
        if (ok != 1) {
            return collo_boringssl_fail("set BoringSSL client session");
        }
    }
    return 0;
}

struct collo_pem_source {
    const char* path;
    const uint8_t* bytes;
    size_t len;
};

static bool collo_pem_source_valid(const struct collo_pem_source* source)
{
    if (source == NULL) {
        return false;
    }
    if (source->path != NULL) {
        return source->bytes == NULL && source->len == 0;
    }
    return source->bytes != NULL && source->len > 0 && source->len <= INT_MAX;
}

static BIO* collo_bio_from_pem_source(const struct collo_pem_source* source)
{
    if (!collo_pem_source_valid(source)) {
        collo_boringssl_fail("invalid PEM source");
        return NULL;
    }
    if (source->path != NULL) {
        BIO* bio = BIO_new_file(source->path, "rb");
        if (bio == NULL) {
            collo_boringssl_fail("open PEM file");
        }
        return bio;
    }
    BIO* bio = BIO_new_mem_buf(source->bytes, (int)source->len);
    if (bio == NULL) {
        collo_boringssl_fail("open inline PEM");
    }
    return bio;
}

// Reading past the last PEM block fails with PEM_R_NO_START_LINE, which marks the end of the input, not an error.
static int collo_pem_eof_or_error(const char* context)
{
    if (ERR_equals(ERR_peek_last_error(), ERR_LIB_PEM, PEM_R_NO_START_LINE)) {
        ERR_clear_error();
        return 1;
    }
    return collo_boringssl_fail(context);
}

static int collo_boringssl_use_certificate_chain(SSL_CTX* ctx, const struct collo_pem_source* source)
{
    BIO* bio = collo_bio_from_pem_source(source);
    if (bio == NULL) {
        return -1;
    }

    X509* leaf = PEM_read_bio_X509_AUX(bio, NULL, NULL, NULL);
    if (leaf == NULL) {
        BIO_free(bio);
        return collo_boringssl_fail("read certificate chain leaf");
    }
    if (SSL_CTX_use_certificate(ctx, leaf) != 1) {
        X509_free(leaf);
        BIO_free(bio);
        return collo_boringssl_fail("load certificate chain leaf");
    }
    X509_free(leaf);

    SSL_CTX_clear_chain_certs(ctx);
    for (;;) {
        X509* chain_cert = PEM_read_bio_X509(bio, NULL, NULL, NULL);
        if (chain_cert == NULL) {
            break;
        }
        const int ok = SSL_CTX_add1_chain_cert(ctx, chain_cert);
        X509_free(chain_cert);
        if (ok != 1) {
            BIO_free(bio);
            return collo_boringssl_fail("load certificate chain intermediate");
        }
    }

    BIO_free(bio);
    return collo_pem_eof_or_error("read certificate chain");
}

static int collo_boringssl_use_private_key(SSL_CTX* ctx, const struct collo_pem_source* source)
{
    BIO* bio = collo_bio_from_pem_source(source);
    if (bio == NULL) {
        return -1;
    }
    EVP_PKEY* key = PEM_read_bio_PrivateKey(bio, NULL, NULL, NULL);
    BIO_free(bio);
    if (key == NULL) {
        return collo_boringssl_fail("read private key");
    }
    const int ok = SSL_CTX_use_PrivateKey(ctx, key);
    EVP_PKEY_free(key);
    if (ok != 1) {
        return collo_boringssl_fail("load private key");
    }
    return 1;
}

static uint16_t collo_tls_version_from_string(const char* version)
{
    if (version == NULL) {
        return 0;
    }
    if (strcmp(version, "TLSv1.3") == 0) {
        return 0x0304;
    }
    if (strcmp(version, "TLSv1.2") == 0) {
        return 0x0303;
    }
    return 0;
}

static size_t collo_key_len_for_tls12_cipher(uint32_t cipher_id)
{
    switch (cipher_id) {
    case 0xc02f: // TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
    case 0xc02b: // TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
        return 16;
    case 0xc030: // TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
    case 0xc02c: // TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
        return 32;
    default:
        return 0;
    }
}

static size_t collo_secret_len_for_tls13_cipher(uint32_t cipher_id)
{
    switch (cipher_id) {
    case 0x1301: // TLS_AES_128_GCM_SHA256
    case 0x1303: // TLS_CHACHA20_POLY1305_SHA256
        return 32;
    case 0x1302: // TLS_AES_256_GCM_SHA384
        return 48;
    default:
        return 0;
    }
}

static void collo_u64_to_be(uint64_t value, uint8_t out[8])
{
    uint64_t be = __builtin_bswap64(value);
    memcpy(out, &be, sizeof(be));
}

static void collo_boringssl_conn_destroy(struct collo_boringssl_conn* conn)
{
    if (conn == NULL) {
        return;
    }
    SSL_free(conn->ssl);
    free(conn);
}

static void collo_boringssl_client_ctx_destroy(struct collo_boringssl_client_ctx* ctx)
{
    if (ctx == NULL) {
        return;
    }
    if (ctx->ctx != NULL) {
        SSL_CTX_free(ctx->ctx);
    }
    // Live connections keep raw pointers to this cache, and the new-session callback inserts through them, so the
    // context must outlive every connection created from it. The egress client holds its two contexts for the process
    // lifetime.
    collo_client_session_cache_free(ctx->session_cache);
    free(ctx);
}

static void collo_boringssl_client_conn_destroy(struct collo_boringssl_client_conn* conn)
{
    if (conn == NULL) {
        return;
    }
    if (conn->ssl != NULL) {
        SSL_free(conn->ssl);
    }
    free(conn);
}

struct collo_client_hello_cipher_flags {
    bool tls13_aes_gcm;
    bool tls13_chacha20_poly1305;
    bool tls12_ktls_aes_gcm;
};

static struct collo_client_hello_cipher_flags collo_parse_cipher_flags_from_bytes(
    const uint8_t* suites, size_t suites_len)
{
    struct collo_client_hello_cipher_flags flags = {};
    if (suites == NULL) {
        return flags;
    }
    CBS ciphers;
    CBS_init(&ciphers, suites, suites_len);
    while (CBS_len(&ciphers) >= 2) {
        uint16_t offered = 0;
        if (!CBS_get_u16(&ciphers, &offered)) {
            return flags;
        }
        switch (offered) {
        case collo_tls13_aes_128_gcm_sha256:
        case collo_tls13_aes_256_gcm_sha384:
            flags.tls13_aes_gcm = true;
            break;
        case collo_tls13_chacha20_poly1305_sha256:
            flags.tls13_chacha20_poly1305 = true;
            break;
        case collo_tls12_ecdhe_rsa_aes_128_gcm_sha256:
        case collo_tls12_ecdhe_ecdsa_aes_128_gcm_sha256:
        case collo_tls12_ecdhe_rsa_aes_256_gcm_sha384:
        case collo_tls12_ecdhe_ecdsa_aes_256_gcm_sha384:
            flags.tls12_ktls_aes_gcm = true;
            break;
        default:
            break;
        }
    }
    return flags;
}

static struct collo_client_hello_cipher_flags collo_parse_client_hello_cipher_flags(
    const SSL_CLIENT_HELLO* client_hello)
{
    if (client_hello == NULL) {
        return {};
    }
    return collo_parse_cipher_flags_from_bytes(client_hello->cipher_suites, client_hello->cipher_suites_len);
}

extern "C" int collo_boringssl_test_tls13_policy_cipher_flags(void)
{
    const uint8_t chacha_only[] = { 0x13, 0x03 };
    const uint8_t aes_and_chacha[] = { 0x13, 0x03, 0x13, 0x01 };
    const uint8_t tls12_fallback[] = { 0xc0, 0x2f, 0x13, 0x03 };

    struct collo_client_hello_cipher_flags flags
        = collo_parse_cipher_flags_from_bytes(chacha_only, sizeof(chacha_only));
    if (!flags.tls13_chacha20_poly1305 || flags.tls13_aes_gcm || flags.tls12_ktls_aes_gcm) {
        return collo_boringssl_fail("test TLS 1.3 ChaCha-only cipher flags");
    }
    flags = collo_parse_cipher_flags_from_bytes(aes_and_chacha, sizeof(aes_and_chacha));
    if (!flags.tls13_chacha20_poly1305 || !flags.tls13_aes_gcm) {
        return collo_boringssl_fail("test TLS 1.3 AES+ChaCha cipher flags");
    }
    flags = collo_parse_cipher_flags_from_bytes(tls12_fallback, sizeof(tls12_fallback));
    if (!flags.tls13_chacha20_poly1305 || flags.tls13_aes_gcm || !flags.tls12_ktls_aes_gcm) {
        return collo_boringssl_fail("test TLS 1.2 fallback cipher flags");
    }
    return 0;
}

// The server picks the AES-GCM-only policy when the running kernel cannot take over a TLS 1.3 ChaCha20 connection, so
// under it a client that offers TLS 1.3 only with ChaCha20 cannot be served. It is moved to TLS 1.2 when it also offers
// a kTLS AES-GCM suite there, and refused otherwise.
static enum ssl_select_cert_result_t collo_boringssl_apply_tls13_ktls_policy(
    const SSL_CLIENT_HELLO* client_hello, const struct collo_boringssl_conn* conn)
{
    if (conn == NULL || conn->tls13_policy != collo_boringssl_tls13_policy_aes_gcm_only) {
        return ssl_select_cert_success;
    }
    const struct collo_client_hello_cipher_flags flags = collo_parse_client_hello_cipher_flags(client_hello);
    if (!flags.tls13_chacha20_poly1305 || flags.tls13_aes_gcm) {
        return ssl_select_cert_success;
    }
    if (flags.tls12_ktls_aes_gcm) {
        if (SSL_set_max_proto_version(client_hello->ssl, TLS1_2_VERSION) == 1) {
            return ssl_select_cert_success;
        }
    }
    collo_boringssl_fail("reject non-AES-GCM TLS 1.3 cipher for kTLS");
    return ssl_select_cert_error;
}

static enum ssl_select_cert_result_t collo_boringssl_select_certificate(const SSL_CLIENT_HELLO* client_hello)
{
    if (client_hello == NULL || client_hello->ssl == NULL) {
        return ssl_select_cert_success;
    }

    struct collo_boringssl_conn* conn = (struct collo_boringssl_conn*)SSL_get_app_data(client_hello->ssl);
    if (conn == NULL) {
        return ssl_select_cert_success;
    }
    return collo_boringssl_apply_tls13_ktls_policy(client_hello, conn);
}

static void collo_boringssl_ctx_destroy(struct collo_boringssl_ctx* ctx)
{
    if (ctx == NULL) {
        return;
    }
    SSL_CTX_free(ctx->ctx);
    free(ctx);
}

static int collo_boringssl_ctx_new_internal(const struct collo_pem_source* cert_chain,
    const struct collo_pem_source* private_key, const char* tls12_cipher_list, int tls13_policy,
    struct collo_boringssl_ctx** out)
{
    collo_boringssl_clear_last_error();
    if (out == NULL || !collo_pem_source_valid(cert_chain) || !collo_pem_source_valid(private_key)) {
        return collo_boringssl_fail("invalid BoringSSL context arguments");
    }
    *out = NULL;

    const bool tls12_enabled = tls12_cipher_list != NULL && tls12_cipher_list[0] != '\0';
    const bool tls13_enabled = tls13_policy != collo_boringssl_tls13_policy_disabled;
    if (!tls12_enabled && !tls13_enabled) {
        return collo_boringssl_fail("no kTLS-compatible TLS ciphers configured");
    }

    struct collo_boringssl_ctx* ctx = (struct collo_boringssl_ctx*)calloc(1, sizeof(*ctx));
    if (ctx == NULL) {
        return collo_boringssl_fail("allocate BoringSSL context");
    }

    ctx->ctx = SSL_CTX_new(TLS_server_method());
    if (ctx->ctx == NULL) {
        collo_boringssl_ctx_destroy(ctx);
        return collo_boringssl_fail("create BoringSSL TLS context");
    }
    ctx->tls13_policy = tls13_policy;
    if (SSL_CTX_set_min_proto_version(ctx->ctx, tls12_enabled ? TLS1_2_VERSION : TLS1_3_VERSION) != 1) {
        collo_boringssl_ctx_destroy(ctx);
        return collo_boringssl_fail("set minimum TLS protocol version");
    }
    if (SSL_CTX_set_max_proto_version(ctx->ctx, tls13_enabled ? TLS1_3_VERSION : TLS1_2_VERSION) != 1) {
        collo_boringssl_ctx_destroy(ctx);
        return collo_boringssl_fail("set maximum TLS protocol version");
    }
    if (tls12_enabled && SSL_CTX_set_strict_cipher_list(ctx->ctx, tls12_cipher_list) != 1) {
        collo_boringssl_ctx_destroy(ctx);
        return collo_boringssl_fail("set TLS 1.2 cipher list");
    }
    if (collo_boringssl_use_certificate_chain(ctx->ctx, cert_chain) != 1) {
        collo_boringssl_ctx_destroy(ctx);
        return collo_boringssl_fail("load certificate chain");
    }
    if (collo_boringssl_use_private_key(ctx->ctx, private_key) != 1) {
        collo_boringssl_ctx_destroy(ctx);
        return collo_boringssl_fail("load private key");
    }
    if (SSL_CTX_check_private_key(ctx->ctx) != 1) {
        collo_boringssl_ctx_destroy(ctx);
        return collo_boringssl_fail("check private key");
    }
    SSL_CTX_set_verify(ctx->ctx, SSL_VERIFY_NONE, NULL);
    SSL_CTX_set_alpn_select_cb(ctx->ctx, collo_boringssl_select_alpn, NULL);
    SSL_CTX_set_select_certificate_cb(ctx->ctx, collo_boringssl_select_certificate);
    switch (tls13_policy) {
    case collo_boringssl_tls13_policy_all_supported:
    case collo_boringssl_tls13_policy_disabled:
        break;
    case collo_boringssl_tls13_policy_aes_gcm_only:
        // BoringSSL has no TLS 1.3 cipher list: TLS 1.3 suites keep a built-in preference order. This compliance
        // policy changes only that order, putting AES-GCM first whenever the client offers it, and
        // `collo_boringssl_apply_tls13_ktls_policy` handles a client that offers only ChaCha20 before the handshake
        // completes.
        if (SSL_CTX_set_compliance_policy(ctx->ctx, ssl_compliance_policy_cnsa_202407) != 1) {
            collo_boringssl_ctx_destroy(ctx);
            return collo_boringssl_fail("set TLS kTLS cipher policy");
        }
        break;
    default:
        collo_boringssl_ctx_destroy(ctx);
        return collo_boringssl_fail("invalid TLS 1.3 kTLS policy");
    }

    *out = ctx;
    return 0;
}

extern "C" int collo_boringssl_ctx_new(
    const char* cert_chain_path, const char* private_key_path, struct collo_boringssl_ctx** out)
{
    const struct collo_pem_source cert_chain = { cert_chain_path, NULL, 0 };
    const struct collo_pem_source private_key = { private_key_path, NULL, 0 };
    return collo_boringssl_ctx_new_internal(
        &cert_chain, &private_key, collo_default_tls12_cipher_list, collo_boringssl_tls13_policy_all_supported, out);
}

extern "C" int collo_boringssl_ctx_new_ex(const char* cert_chain_path, const char* private_key_path,
    const char* tls12_cipher_list, int tls13_policy, struct collo_boringssl_ctx** out)
{
    const struct collo_pem_source cert_chain = { cert_chain_path, NULL, 0 };
    const struct collo_pem_source private_key = { private_key_path, NULL, 0 };
    return collo_boringssl_ctx_new_internal(&cert_chain, &private_key, tls12_cipher_list, tls13_policy, out);
}

extern "C" int collo_boringssl_ctx_new_pem_ex(const uint8_t* cert_chain_pem, size_t cert_chain_len,
    const uint8_t* private_key_pem, size_t private_key_len, const char* tls12_cipher_list, int tls13_policy,
    struct collo_boringssl_ctx** out)
{
    const struct collo_pem_source cert_chain = { NULL, cert_chain_pem, cert_chain_len };
    const struct collo_pem_source private_key = { NULL, private_key_pem, private_key_len };
    return collo_boringssl_ctx_new_internal(&cert_chain, &private_key, tls12_cipher_list, tls13_policy, out);
}

extern "C" void collo_boringssl_ctx_free(struct collo_boringssl_ctx* ctx) { collo_boringssl_ctx_destroy(ctx); }

// Mirrored as `self_signed_names_max` in `root.zig`.
static constexpr size_t collo_self_signed_names_max = 16;
static constexpr size_t collo_dns_name_bytes_max = 253;
static constexpr size_t collo_self_signed_serial_bytes = 16;
static const uint8_t collo_self_signed_common_name[] = "Collo self-signed";

static bool collo_dns_name_byte_valid(uint8_t byte)
{
    return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '-'
        || byte == '.';
}

static bool collo_subject_alt_name_valid(const struct collo_boringssl_subject_alt_name* name)
{
    if (name->value == NULL) {
        return false;
    }
    for (uint8_t reserved : name->reserved0) {
        if (reserved != 0) {
            return false;
        }
    }
    switch (name->kind) {
    case COLLO_BORINGSSL_SAN_DNS:
        if (name->value_len == 0 || name->value_len > collo_dns_name_bytes_max) {
            return false;
        }
        for (size_t i = 0; i < name->value_len; i++) {
            if (!collo_dns_name_byte_valid(name->value[i])) {
                return false;
            }
        }
        return true;
    case COLLO_BORINGSSL_SAN_IP:
        return name->value_len == 4 || name->value_len == 16;
    default:
        return false;
    }
}

static int collo_self_signed_add_names(
    X509* x509, const struct collo_boringssl_subject_alt_name* names, size_t name_count)
{
    bssl::UniquePtr<GENERAL_NAMES> general_names(GENERAL_NAMES_new());
    if (!general_names) {
        return collo_boringssl_fail("allocate subjectAltName");
    }
    for (size_t i = 0; i < name_count; i++) {
        bssl::UniquePtr<GENERAL_NAME> general_name(GENERAL_NAME_new());
        if (!general_name) {
            return collo_boringssl_fail("allocate subjectAltName entry");
        }
        if (names[i].kind == COLLO_BORINGSSL_SAN_DNS) {
            bssl::UniquePtr<ASN1_IA5STRING> dns_name(ASN1_IA5STRING_new());
            if (!dns_name
                || ASN1_STRING_set(dns_name.get(), names[i].value, static_cast<ossl_ssize_t>(names[i].value_len))
                    != 1) {
                return collo_boringssl_fail("encode subjectAltName DNS name");
            }
            GENERAL_NAME_set0_value(general_name.get(), GEN_DNS, dns_name.release());
        } else {
            bssl::UniquePtr<ASN1_OCTET_STRING> address(ASN1_OCTET_STRING_new());
            if (!address
                || ASN1_OCTET_STRING_set(address.get(), names[i].value, static_cast<int>(names[i].value_len)) != 1) {
                return collo_boringssl_fail("encode subjectAltName IP address");
            }
            GENERAL_NAME_set0_value(general_name.get(), GEN_IPADD, address.release());
        }
        if (sk_GENERAL_NAME_push(general_names.get(), general_name.get()) == 0) {
            return collo_boringssl_fail("append subjectAltName entry");
        }
        general_name.release();
    }
    if (X509_add1_ext_i2d(x509, NID_subject_alt_name, general_names.get(), 0, X509V3_ADD_DEFAULT) != 1) {
        return collo_boringssl_fail("add subjectAltName");
    }
    return 0;
}

// A leaf certificate for TLS servers: not a CA, so a client that trusts it as an anchor cannot
// accept certificates it would sign, and usable only for ECDSA handshake signatures.
static int collo_self_signed_add_leaf_extensions(X509* x509)
{
    bssl::UniquePtr<BASIC_CONSTRAINTS> basic_constraints(BASIC_CONSTRAINTS_new());
    if (!basic_constraints) {
        return collo_boringssl_fail("allocate basicConstraints");
    }
    basic_constraints->ca = 0;
    if (X509_add1_ext_i2d(x509, NID_basic_constraints, basic_constraints.get(), 1, X509V3_ADD_DEFAULT) != 1) {
        return collo_boringssl_fail("add basicConstraints");
    }

    bssl::UniquePtr<ASN1_BIT_STRING> key_usage(ASN1_BIT_STRING_new());
    const int digital_signature_bit = 0;
    if (!key_usage || ASN1_BIT_STRING_set_bit(key_usage.get(), digital_signature_bit, 1) != 1) {
        return collo_boringssl_fail("encode keyUsage");
    }
    if (X509_add1_ext_i2d(x509, NID_key_usage, key_usage.get(), 1, X509V3_ADD_DEFAULT) != 1) {
        return collo_boringssl_fail("add keyUsage");
    }

    bssl::UniquePtr<EXTENDED_KEY_USAGE> extended_key_usage(EXTENDED_KEY_USAGE_new());
    ASN1_OBJECT* server_auth = OBJ_nid2obj(NID_server_auth);
    if (!extended_key_usage || server_auth == NULL || sk_ASN1_OBJECT_push(extended_key_usage.get(), server_auth) == 0) {
        return collo_boringssl_fail("encode extendedKeyUsage");
    }
    if (X509_add1_ext_i2d(x509, NID_ext_key_usage, extended_key_usage.get(), 0, X509V3_ADD_DEFAULT) != 1) {
        return collo_boringssl_fail("add extendedKeyUsage");
    }
    return 0;
}

static int collo_self_signed_set_serial(X509* x509)
{
    // The top bit cleared keeps the INTEGER positive and the next bit set keeps it at full length,
    // so the serial carries 126 random bits.
    uint8_t serial_bytes[collo_self_signed_serial_bytes];
    RAND_bytes(serial_bytes, sizeof(serial_bytes));
    serial_bytes[0] = static_cast<uint8_t>((serial_bytes[0] & 0x7f) | 0x40);
    bssl::UniquePtr<BIGNUM> serial_value(BN_bin2bn(serial_bytes, sizeof(serial_bytes), NULL));
    if (!serial_value) {
        return collo_boringssl_fail("decode certificate serial");
    }
    bssl::UniquePtr<ASN1_INTEGER> serial(BN_to_ASN1_INTEGER(serial_value.get(), NULL));
    if (!serial || X509_set_serialNumber(x509, serial.get()) != 1) {
        return collo_boringssl_fail("set certificate serial");
    }
    return 0;
}

static int collo_copy_pem(BIO* bio, uint8_t* out, size_t out_cap, size_t* out_len, const char* context)
{
    const uint8_t* contents = NULL;
    size_t contents_len = 0;
    if (BIO_mem_contents(bio, &contents, &contents_len) != 1 || contents_len == 0) {
        return collo_boringssl_fail(context);
    }
    if (contents_len > out_cap) {
        return collo_boringssl_fail("PEM output buffer too small");
    }
    memcpy(out, contents, contents_len);
    *out_len = contents_len;
    return 0;
}

static int collo_self_signed_generate_internal(const struct collo_boringssl_subject_alt_name* names, size_t name_count,
    int64_t not_before_unix_seconds, int64_t not_after_unix_seconds, uint8_t* cert_pem, size_t cert_pem_cap,
    size_t* out_cert_pem_len, uint8_t* key_pem, size_t key_pem_cap, size_t* out_key_pem_len)
{
    bssl::UniquePtr<EVP_PKEY> key(EVP_PKEY_generate_from_alg(EVP_pkey_ec_p256()));
    if (!key) {
        return collo_boringssl_fail("generate P-256 key");
    }

    bssl::UniquePtr<X509> x509(X509_new());
    if (!x509) {
        return collo_boringssl_fail("allocate certificate");
    }
    if (X509_set_version(x509.get(), X509_VERSION_3) != 1) {
        return collo_boringssl_fail("set certificate version");
    }
    if (collo_self_signed_set_serial(x509.get()) != 0) {
        return -1;
    }
    if (ASN1_TIME_set_posix(X509_getm_notBefore(x509.get()), not_before_unix_seconds) == NULL
        || ASN1_TIME_set_posix(X509_getm_notAfter(x509.get()), not_after_unix_seconds) == NULL) {
        return collo_boringssl_fail("set certificate validity");
    }
    X509_NAME* subject = X509_get_subject_name(x509.get());
    if (X509_NAME_add_entry_by_txt(subject, "CN", MBSTRING_UTF8, collo_self_signed_common_name, -1, -1, 0) != 1
        || X509_set_issuer_name(x509.get(), subject) != 1) {
        return collo_boringssl_fail("set certificate subject");
    }
    if (X509_set_pubkey(x509.get(), key.get()) != 1) {
        return collo_boringssl_fail("set certificate public key");
    }
    if (collo_self_signed_add_names(x509.get(), names, name_count) != 0
        || collo_self_signed_add_leaf_extensions(x509.get()) != 0) {
        return -1;
    }
    if (X509_sign(x509.get(), key.get(), EVP_sha256()) <= 0) {
        return collo_boringssl_fail("sign certificate");
    }

    bssl::UniquePtr<BIO> cert_bio(BIO_new(BIO_s_mem()));
    if (!cert_bio || PEM_write_bio_X509(cert_bio.get(), x509.get()) != 1) {
        return collo_boringssl_fail("encode certificate PEM");
    }
    // The memory BIO frees its buffer through OPENSSL_free, which cleanses it, so the key's PEM
    // leaves no copy behind once `key_bio` goes.
    bssl::UniquePtr<BIO> key_bio(BIO_new(BIO_s_mem()));
    if (!key_bio || PEM_write_bio_PKCS8PrivateKey(key_bio.get(), key.get(), NULL, NULL, 0, NULL, NULL) != 1) {
        return collo_boringssl_fail("encode private key PEM");
    }
    if (collo_copy_pem(cert_bio.get(), cert_pem, cert_pem_cap, out_cert_pem_len, "read certificate PEM") != 0) {
        return -1;
    }
    return collo_copy_pem(key_bio.get(), key_pem, key_pem_cap, out_key_pem_len, "read private key PEM");
}

// Its contract is on its declaration in `root.zig`.
extern "C" int collo_boringssl_self_signed_generate(const struct collo_boringssl_subject_alt_name* names,
    size_t name_count, int64_t not_before_unix_seconds, int64_t not_after_unix_seconds, uint8_t* cert_pem,
    size_t cert_pem_cap, size_t* out_cert_pem_len, uint8_t* key_pem, size_t key_pem_cap, size_t* out_key_pem_len)
{
    collo_boringssl_clear_last_error();
    if (out_cert_pem_len != NULL) {
        *out_cert_pem_len = 0;
    }
    if (out_key_pem_len != NULL) {
        *out_key_pem_len = 0;
    }

    int rc = 0;
    if (names == NULL || name_count == 0 || name_count > collo_self_signed_names_max || cert_pem == NULL
        || cert_pem_cap == 0 || out_cert_pem_len == NULL || key_pem == NULL || key_pem_cap == 0
        || out_key_pem_len == NULL || not_after_unix_seconds <= not_before_unix_seconds) {
        rc = collo_boringssl_fail("invalid self-signed certificate arguments");
    }
    for (size_t i = 0; rc == 0 && i < name_count; i++) {
        if (!collo_subject_alt_name_valid(&names[i])) {
            rc = collo_boringssl_fail("invalid self-signed certificate subjectAltName");
        }
    }
    if (rc == 0) {
        rc = collo_self_signed_generate_internal(names, name_count, not_before_unix_seconds, not_after_unix_seconds,
            cert_pem, cert_pem_cap, out_cert_pem_len, key_pem, key_pem_cap, out_key_pem_len);
    }
    if (rc != 0) {
        if (key_pem != NULL) {
            OPENSSL_cleanse(key_pem, key_pem_cap);
        }
        if (out_cert_pem_len != NULL) {
            *out_cert_pem_len = 0;
        }
        if (out_key_pem_len != NULL) {
            *out_key_pem_len = 0;
        }
    }
    return rc;
}

extern "C" int collo_boringssl_conn_new(struct collo_boringssl_ctx* ctx, int fd, struct collo_boringssl_conn** out)
{
    collo_boringssl_clear_last_error();
    if (ctx == NULL || ctx->ctx == NULL || out == NULL) {
        return collo_boringssl_fail("invalid BoringSSL connection arguments");
    }
    *out = NULL;

    struct collo_boringssl_conn* conn = (struct collo_boringssl_conn*)calloc(1, sizeof(*conn));
    if (conn == NULL) {
        return collo_boringssl_fail("allocate BoringSSL connection");
    }
    conn->tls13_policy = ctx->tls13_policy;

    conn->ssl = SSL_new(ctx->ctx);
    if (conn->ssl == NULL) {
        collo_boringssl_conn_destroy(conn);
        return collo_boringssl_fail("create BoringSSL connection");
    }
    if (SSL_set_fd(conn->ssl, fd) != 1) {
        collo_boringssl_conn_destroy(conn);
        return collo_boringssl_fail("attach TLS socket fd");
    }
    SSL_set_app_data(conn->ssl, conn);
    SSL_set_accept_state(conn->ssl);

    *out = conn;
    return 0;
}

extern "C" void collo_boringssl_conn_free(struct collo_boringssl_conn* conn) { collo_boringssl_conn_destroy(conn); }

extern "C" int collo_boringssl_handshake_step(struct collo_boringssl_conn* conn, struct collo_boringssl_result* result)
{
    collo_boringssl_clear_last_error();
    if (conn == NULL || conn->ssl == NULL || result == NULL) {
        return collo_boringssl_fail("invalid BoringSSL handshake arguments");
    }
    result->status = COLLO_BORINGSSL_FAILED;
    result->tls_version = 0;
    result->application_protocol = COLLO_BORINGSSL_ALPN_UNSPECIFIED;
    result->reserved0 = 0;
    result->cipher_id = 0;

    int rc = SSL_do_handshake(conn->ssl);
    if (rc == 1) {
        const SSL_CIPHER* cipher = SSL_get_current_cipher(conn->ssl);
        result->status = COLLO_BORINGSSL_OK;
        result->tls_version = collo_tls_version_from_string(SSL_get_version(conn->ssl));
        result->application_protocol = collo_boringssl_selected_alpn(conn->ssl);
        result->cipher_id = cipher == NULL ? 0 : SSL_CIPHER_get_protocol_id(cipher);
        return 0;
    }

    int ssl_error = SSL_get_error(conn->ssl, rc);
    if (ssl_error == SSL_ERROR_WANT_READ) {
        result->status = COLLO_BORINGSSL_WANT_READ;
        return 0;
    }
    if (ssl_error == SSL_ERROR_WANT_WRITE) {
        result->status = COLLO_BORINGSSL_WANT_WRITE;
        return 0;
    }

    result->status = COLLO_BORINGSSL_FAILED;
    collo_boringssl_fail("run TLS handshake");
    return 0;
}

extern "C" int collo_boringssl_client_ctx_new(int insecure_skip_verify, struct collo_boringssl_client_ctx** out)
{
    collo_boringssl_clear_last_error();
    if (out == NULL) {
        return collo_boringssl_fail("invalid BoringSSL client context arguments");
    }
    *out = NULL;

    struct collo_boringssl_client_ctx* ctx = (struct collo_boringssl_client_ctx*)calloc(1, sizeof(*ctx));
    if (ctx == NULL) {
        return collo_boringssl_fail("allocate BoringSSL client context");
    }
    ctx->insecure_skip_verify = insecure_skip_verify != 0;
    ctx->ctx = SSL_CTX_new(TLS_client_method());
    if (ctx->ctx == NULL) {
        collo_boringssl_client_ctx_destroy(ctx);
        return collo_boringssl_fail("create BoringSSL client context");
    }
    if (SSL_CTX_set_min_proto_version(ctx->ctx, TLS1_2_VERSION) != 1) {
        collo_boringssl_client_ctx_destroy(ctx);
        return collo_boringssl_fail("set BoringSSL client minimum TLS protocol version");
    }
    ctx->session_cache = collo_client_session_cache_new();
    if (ctx->session_cache == NULL) {
        collo_boringssl_client_ctx_destroy(ctx);
        return collo_boringssl_fail("allocate BoringSSL client session cache");
    }
    // On a client this enables only the new-session callback, which feeds the session cache.
    SSL_CTX_set_session_cache_mode(ctx->ctx, SSL_SESS_CACHE_CLIENT);
    SSL_CTX_sess_set_new_cb(ctx->ctx, collo_boringssl_client_new_session_cb);
    if (ctx->insecure_skip_verify) {
        SSL_CTX_set_verify(ctx->ctx, SSL_VERIFY_NONE, NULL);
    } else {
        if (SSL_CTX_set_default_verify_paths(ctx->ctx) != 1) {
            collo_boringssl_client_ctx_destroy(ctx);
            return collo_boringssl_fail("load BoringSSL client root certificates");
        }
        SSL_CTX_set_verify(ctx->ctx, SSL_VERIFY_PEER, NULL);
    }

    *out = ctx;
    return 0;
}

extern "C" void collo_boringssl_client_ctx_free(struct collo_boringssl_client_ctx* ctx)
{
    collo_boringssl_client_ctx_destroy(ctx);
}

extern "C" int collo_boringssl_client_conn_new(struct collo_boringssl_client_ctx* ctx, int fd, const char* server_name,
    int alpn_offer, const uint8_t* session_key, size_t session_key_len, struct collo_boringssl_client_conn** out)
{
    collo_boringssl_clear_last_error();
    if (ctx == NULL || ctx->ctx == NULL || server_name == NULL || server_name[0] == '\0' || out == NULL) {
        return collo_boringssl_fail("invalid BoringSSL client connection arguments");
    }
    *out = NULL;

    struct collo_boringssl_client_conn* conn = (struct collo_boringssl_client_conn*)calloc(1, sizeof(*conn));
    if (conn == NULL) {
        return collo_boringssl_fail("allocate BoringSSL client connection");
    }
    conn->insecure_skip_verify = ctx->insecure_skip_verify;
    conn->ssl = SSL_new(ctx->ctx);
    if (conn->ssl == NULL) {
        collo_boringssl_client_conn_destroy(conn);
        return collo_boringssl_fail("create BoringSSL client connection");
    }
    if (SSL_set_fd(conn->ssl, fd) != 1) {
        collo_boringssl_client_conn_destroy(conn);
        return collo_boringssl_fail("attach BoringSSL client socket fd");
    }
    if (collo_boringssl_client_configure_ssl(ctx, conn, server_name, alpn_offer) != 0) {
        collo_boringssl_client_conn_destroy(conn);
        return -1;
    }
    if (collo_boringssl_client_session_setup(ctx, conn, session_key, session_key_len) != 0) {
        collo_boringssl_client_conn_destroy(conn);
        return -1;
    }

    *out = conn;
    return 0;
}

extern "C" int collo_boringssl_client_conn_new_bio(struct collo_boringssl_client_ctx* ctx, const char* server_name,
    int alpn_offer, const uint8_t* session_key, size_t session_key_len, struct collo_boringssl_client_conn** out)
{
    collo_boringssl_clear_last_error();
    if (ctx == NULL || ctx->ctx == NULL || server_name == NULL || server_name[0] == '\0' || out == NULL) {
        return collo_boringssl_fail("invalid BoringSSL client BIO connection arguments");
    }
    *out = NULL;

    struct collo_boringssl_client_conn* conn = (struct collo_boringssl_client_conn*)calloc(1, sizeof(*conn));
    if (conn == NULL) {
        return collo_boringssl_fail("allocate BoringSSL client BIO connection");
    }
    conn->insecure_skip_verify = ctx->insecure_skip_verify;
    conn->ssl = SSL_new(ctx->ctx);
    if (conn->ssl == NULL) {
        collo_boringssl_client_conn_destroy(conn);
        return collo_boringssl_fail("create BoringSSL client BIO connection");
    }

    BIO* rbio = BIO_new(BIO_s_mem());
    BIO* wbio = BIO_new(BIO_s_mem());
    if (rbio == NULL || wbio == NULL) {
        BIO_free(rbio);
        BIO_free(wbio);
        collo_boringssl_client_conn_destroy(conn);
        return collo_boringssl_fail("create BoringSSL client memory BIOs");
    }
    // An empty memory BIO then reads as a retry rather than end of file, so an empty buffer makes the connection and
    // the ciphertext drain wait for the caller.
    if (BIO_set_mem_eof_return(rbio, -1) != 1 || BIO_set_mem_eof_return(wbio, -1) != 1) {
        BIO_free(rbio);
        BIO_free(wbio);
        collo_boringssl_client_conn_destroy(conn);
        return collo_boringssl_fail("configure BoringSSL client memory BIOs");
    }
    SSL_set_bio(conn->ssl, rbio, wbio);
    conn->rbio = rbio;
    conn->wbio = wbio;

    if (collo_boringssl_client_configure_ssl(ctx, conn, server_name, alpn_offer) != 0) {
        collo_boringssl_client_conn_destroy(conn);
        return -1;
    }
    if (collo_boringssl_client_session_setup(ctx, conn, session_key, session_key_len) != 0) {
        collo_boringssl_client_conn_destroy(conn);
        return -1;
    }

    *out = conn;
    return 0;
}

extern "C" void collo_boringssl_client_conn_free(struct collo_boringssl_client_conn* conn)
{
    collo_boringssl_client_conn_destroy(conn);
}

extern "C" int collo_boringssl_client_session_reused(struct collo_boringssl_client_conn* conn)
{
    if (conn == NULL || conn->ssl == NULL) {
        return 0;
    }
    return SSL_session_reused(conn->ssl);
}

extern "C" int collo_boringssl_client_handshake_step(
    struct collo_boringssl_client_conn* conn, struct collo_boringssl_result* result)
{
    collo_boringssl_clear_last_error();
    if (conn == NULL || conn->ssl == NULL || result == NULL) {
        return collo_boringssl_fail("invalid BoringSSL client handshake arguments");
    }
    result->status = COLLO_BORINGSSL_FAILED;
    result->tls_version = 0;
    result->application_protocol = COLLO_BORINGSSL_ALPN_UNSPECIFIED;
    result->reserved0 = 0;
    result->cipher_id = 0;

    int rc = SSL_do_handshake(conn->ssl);
    if (rc == 1) {
        if (!conn->insecure_skip_verify && SSL_get_verify_result(conn->ssl) != X509_V_OK) {
            collo_boringssl_fail("verify BoringSSL client TLS peer certificate");
            return 0;
        }
        const SSL_CIPHER* cipher = SSL_get_current_cipher(conn->ssl);
        result->status = COLLO_BORINGSSL_OK;
        result->tls_version = collo_tls_version_from_string(SSL_get_version(conn->ssl));
        result->application_protocol = collo_boringssl_selected_alpn(conn->ssl);
        result->cipher_id = cipher == NULL ? 0 : SSL_CIPHER_get_protocol_id(cipher);
        return 0;
    }

    int ssl_error = SSL_get_error(conn->ssl, rc);
    if (ssl_error == SSL_ERROR_WANT_READ) {
        result->status = COLLO_BORINGSSL_WANT_READ;
        return 0;
    }
    if (ssl_error == SSL_ERROR_WANT_WRITE) {
        result->status = COLLO_BORINGSSL_WANT_WRITE;
        return 0;
    }
    collo_boringssl_fail("run BoringSSL client TLS handshake");
    return 0;
}

extern "C" int collo_boringssl_client_read(
    struct collo_boringssl_client_conn* conn, uint8_t* out, size_t out_cap, size_t* out_len)
{
    collo_boringssl_clear_last_error();
    if (conn == NULL || conn->ssl == NULL || out == NULL || out_len == NULL || out_cap > INT_MAX) {
        return collo_boringssl_fail("invalid BoringSSL client read arguments");
    }
    *out_len = 0;
    if (out_cap == 0) {
        return COLLO_BORINGSSL_OK;
    }
    const int rc = SSL_read(conn->ssl, out, (int)out_cap);
    if (rc > 0) {
        *out_len = (size_t)rc;
        return COLLO_BORINGSSL_OK;
    }
    const int ssl_error = SSL_get_error(conn->ssl, rc);
    if (ssl_error == SSL_ERROR_ZERO_RETURN) {
        return COLLO_BORINGSSL_EOF;
    }
    if (ssl_error == SSL_ERROR_WANT_READ) {
        return COLLO_BORINGSSL_WANT_READ;
    }
    if (ssl_error == SSL_ERROR_WANT_WRITE) {
        return COLLO_BORINGSSL_WANT_WRITE;
    }
    collo_boringssl_fail("read BoringSSL client application data");
    return COLLO_BORINGSSL_FAILED;
}

extern "C" int collo_boringssl_client_has_buffered_input(
    struct collo_boringssl_client_conn* conn, int* out_has_buffered)
{
    collo_boringssl_clear_last_error();
    if (conn == NULL || conn->ssl == NULL || out_has_buffered == NULL) {
        return collo_boringssl_fail("invalid BoringSSL client buffered-input arguments");
    }
    // `SSL_pending` counts the decrypted application bytes the SSL object holds, and `SSL_has_pending` adds undecrypted
    // transport data, which BoringSSL buffers only in DTLS. Either means the peer sent bytes past what the caller
    // consumed. An idle pooled connection must have neither, or the next request on it would read the previous
    // response's surplus as its own head.
    *out_has_buffered = (SSL_pending(conn->ssl) > 0 || SSL_has_pending(conn->ssl) == 1) ? 1 : 0;
    return COLLO_BORINGSSL_OK;
}

extern "C" int collo_boringssl_client_write(
    struct collo_boringssl_client_conn* conn, const uint8_t* bytes, size_t bytes_len, size_t* out_len)
{
    collo_boringssl_clear_last_error();
    if (conn == NULL || conn->ssl == NULL || bytes == NULL || out_len == NULL || bytes_len > INT_MAX) {
        return collo_boringssl_fail("invalid BoringSSL client write arguments");
    }
    *out_len = 0;
    if (bytes_len == 0) {
        return COLLO_BORINGSSL_OK;
    }
    const int rc = SSL_write(conn->ssl, bytes, (int)bytes_len);
    if (rc > 0) {
        *out_len = (size_t)rc;
        return COLLO_BORINGSSL_OK;
    }
    const int ssl_error = SSL_get_error(conn->ssl, rc);
    if (ssl_error == SSL_ERROR_WANT_READ) {
        return COLLO_BORINGSSL_WANT_READ;
    }
    if (ssl_error == SSL_ERROR_WANT_WRITE) {
        return COLLO_BORINGSSL_WANT_WRITE;
    }
    collo_boringssl_fail("write BoringSSL client application data");
    return COLLO_BORINGSSL_FAILED;
}

extern "C" int collo_boringssl_client_feed_ciphertext(
    struct collo_boringssl_client_conn* conn, const uint8_t* bytes, size_t bytes_len, size_t* out_len)
{
    collo_boringssl_clear_last_error();
    if (conn == NULL || conn->ssl == NULL || conn->rbio == NULL || bytes == NULL || out_len == NULL
        || bytes_len > INT_MAX) {
        return collo_boringssl_fail("invalid BoringSSL client ciphertext feed arguments");
    }
    *out_len = 0;
    if (bytes_len == 0) {
        return COLLO_BORINGSSL_OK;
    }

    const int rc = BIO_write(conn->rbio, bytes, (int)bytes_len);
    if (rc > 0) {
        *out_len = (size_t)rc;
        return COLLO_BORINGSSL_OK;
    }
    if (BIO_should_write(conn->rbio)) {
        return COLLO_BORINGSSL_WANT_WRITE;
    }
    collo_boringssl_fail("feed BoringSSL client ciphertext");
    return COLLO_BORINGSSL_FAILED;
}

extern "C" int collo_boringssl_client_drain_ciphertext(
    struct collo_boringssl_client_conn* conn, uint8_t* out, size_t out_cap, size_t* out_len)
{
    collo_boringssl_clear_last_error();
    if (conn == NULL || conn->ssl == NULL || conn->wbio == NULL || out == NULL || out_len == NULL
        || out_cap > INT_MAX) {
        return collo_boringssl_fail("invalid BoringSSL client ciphertext drain arguments");
    }
    *out_len = 0;
    if (out_cap == 0) {
        return COLLO_BORINGSSL_OK;
    }

    const int rc = BIO_read(conn->wbio, out, (int)out_cap);
    if (rc > 0) {
        *out_len = (size_t)rc;
        return COLLO_BORINGSSL_OK;
    }
    if (BIO_should_read(conn->wbio)) {
        return COLLO_BORINGSSL_WANT_READ;
    }
    if (rc == 0) {
        return COLLO_BORINGSSL_EOF;
    }
    collo_boringssl_fail("drain BoringSSL client ciphertext");
    return COLLO_BORINGSSL_FAILED;
}

extern "C" int collo_boringssl_client_pending_ciphertext(struct collo_boringssl_client_conn* conn, size_t* out_len)
{
    collo_boringssl_clear_last_error();
    if (conn == NULL || conn->ssl == NULL || conn->wbio == NULL || out_len == NULL) {
        return collo_boringssl_fail("invalid BoringSSL client pending ciphertext arguments");
    }
    *out_len = BIO_ctrl_pending(conn->wbio);
    return 0;
}

extern "C" void collo_boringssl_client_shutdown_best_effort(struct collo_boringssl_client_conn* conn)
{
    if (conn != NULL && conn->ssl != NULL) {
        (void)SSL_shutdown(conn->ssl);
    }
}

static int collo_boringssl_export_tls12_key_material(struct collo_boringssl_conn* conn, uint16_t tls_version,
    uint32_t cipher_id, struct collo_boringssl_ktls_key_material* out)
{
    size_t key_len = collo_key_len_for_tls12_cipher(cipher_id);
    if (key_len == 0) {
        return collo_boringssl_fail("unsupported TLS 1.2 kTLS cipher");
    }

    size_t key_block_len = SSL_get_key_block_len(conn->ssl);
    size_t needed = (key_len * 2) + 8;
    if (key_block_len < needed || key_block_len > 72) {
        return collo_boringssl_fail("invalid TLS 1.2 key block length");
    }

    // An AEAD suite's key block (RFC 5246 §6.3) has no MAC keys: the client and server write keys, then their 4-byte
    // implicit nonces (RFC 5288 §3). This end is the server, so the client's half is what it reads.
    uint8_t key_block[72];
    memset(key_block, 0, sizeof(key_block));
    if (SSL_generate_key_block(conn->ssl, key_block, key_block_len) != 1) {
        return collo_boringssl_fail("export TLS 1.2 key block");
    }

    const uint8_t* client_write_key = key_block;
    const uint8_t* server_write_key = key_block + key_len;
    const uint8_t* client_write_salt = key_block + (key_len * 2);
    const uint8_t* server_write_salt = client_write_salt + 4;

    out->tls_version = tls_version;
    out->cipher_id = cipher_id;
    out->key_len = key_len;
    memcpy(out->rx_key, client_write_key, key_len);
    memcpy(out->tx_key, server_write_key, key_len);
    memcpy(out->rx_salt, client_write_salt, 4);
    memcpy(out->tx_salt, server_write_salt, 4);

    uint8_t read_seq[8];
    uint8_t write_seq[8];
    collo_u64_to_be(SSL_get_read_sequence(conn->ssl), read_seq);
    collo_u64_to_be(SSL_get_write_sequence(conn->ssl), write_seq);
    memcpy(out->read_seq, read_seq, sizeof(read_seq));
    memcpy(out->write_seq, write_seq, sizeof(write_seq));
    // The kernel's TLS 1.2 AES-GCM crypto info takes the 4-byte salt and the 8-byte explicit nonce separately. The
    // nonce starts at the record sequence and goes in the first 8 bytes of each `*_iv`, which
    // `ktlsKeyMaterialToInitialState` in `server/tls/root.zig` maps.
    memcpy(out->rx_iv, read_seq, sizeof(read_seq));
    memcpy(out->tx_iv, write_seq, sizeof(write_seq));

    OPENSSL_cleanse(key_block, sizeof(key_block));
    return 0;
}

static int collo_boringssl_export_tls13_key_material(struct collo_boringssl_conn* conn, uint16_t tls_version,
    uint32_t cipher_id, struct collo_boringssl_ktls_key_material* out)
{
    const size_t secret_len = collo_secret_len_for_tls13_cipher(cipher_id);
    if (secret_len == 0) {
        return collo_boringssl_fail("unsupported TLS 1.3 kTLS cipher");
    }

    bssl::Span<const uint8_t> read_secret;
    bssl::Span<const uint8_t> write_secret;
    if (!bssl::SSL_get_traffic_secrets(conn->ssl, &read_secret, &write_secret)) {
        return collo_boringssl_fail("export TLS 1.3 traffic secrets");
    }
    if (read_secret.size() != secret_len || write_secret.size() != secret_len) {
        return collo_boringssl_fail("invalid TLS 1.3 traffic secret length");
    }

    out->tls_version = tls_version;
    out->cipher_id = cipher_id;
    out->secret_len = secret_len;
    // No key or IV is derived here: `common/tls/ktls.zig` derives them from these secrets with the same HKDF code for
    // the initial install and for each KeyUpdate, so the two cannot disagree.
    memcpy(out->read_secret, read_secret.data(), secret_len);
    memcpy(out->write_secret, write_secret.data(), secret_len);
    collo_u64_to_be(SSL_get_read_sequence(conn->ssl), out->read_seq);
    collo_u64_to_be(SSL_get_write_sequence(conn->ssl), out->write_seq);
    return 0;
}

extern "C" int collo_boringssl_export_ktls_key_material(
    struct collo_boringssl_conn* conn, struct collo_boringssl_ktls_key_material* out)
{
    collo_boringssl_clear_last_error();
    if (conn == NULL || conn->ssl == NULL || out == NULL) {
        return collo_boringssl_fail("invalid kTLS key material arguments");
    }
    memset(out, 0, sizeof(*out));

    uint16_t tls_version = collo_tls_version_from_string(SSL_get_version(conn->ssl));
    if (tls_version != 0x0303 && tls_version != 0x0304) {
        return collo_boringssl_fail("unsupported negotiated TLS version");
    }

    const SSL_CIPHER* cipher = SSL_get_current_cipher(conn->ssl);
    if (cipher == NULL) {
        return collo_boringssl_fail("missing negotiated TLS cipher");
    }
    uint32_t cipher_id = SSL_CIPHER_get_protocol_id(cipher);

    if (tls_version == 0x0303) {
        return collo_boringssl_export_tls12_key_material(conn, tls_version, cipher_id, out);
    }
    return collo_boringssl_export_tls13_key_material(conn, tls_version, cipher_id, out);
}

extern "C" void collo_boringssl_zeroize_key_material(struct collo_boringssl_ktls_key_material* material)
{
    if (material == NULL) {
        return;
    }
    OPENSSL_cleanse(material, sizeof(*material));
}

extern "C" const char* collo_boringssl_last_error() { return collo_boringssl_last_error_buffer; }

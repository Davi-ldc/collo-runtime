#ifndef COLLO_BENCH_SANDBOX_CLIENT_H
#define COLLO_BENCH_SANDBOX_CLIENT_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ColloBenchClient ColloBenchClient;

// One request and the response it must get. A patterned body holds (i / pattern_block_bytes) % 256 at byte i.
typedef struct ColloBenchExchange {
    // NUL-terminated, starting with '/'.
    const char* path;
    // The exact response body, or null for expected_body_len bytes of the pattern.
    const uint8_t* expected_body;
    uint64_t expected_body_len;
    // A POST with content-length and this many bytes of the pattern, or 0 for a GET.
    uint64_t request_body_len;
    // Nonzero whenever a body is patterned.
    uint32_t pattern_block_bytes;
    // Zero.
    uint32_t reserved;
} ColloBenchExchange;

typedef struct ColloBenchReply {
    uint64_t sent_ns;
    uint64_t response_ns;
    uint32_t stream_id;
    uint32_t status;
    uint32_t body_len;
    uint32_t reserved;
} ColloBenchReply;

// Returns zero after loopback TLS+h2 and a bounded HTTP 200 /__collo/healthz preflight. A read or write that blocks
// longer than timeout_ms fails. Certificate verification is disabled solely for the local benchmark fixture. The
// caller owns *out and must close it; failures leave *out null.
int collo_bench_client_open(uint16_t port, const char* hostname, uint32_t timeout_ms, ColloBenchClient** out);

// Single-threaded, sequential exchanges. Success requires HTTP 200, the exact or patterned body and END_STREAM. Times
// are absolute CLOCK_MONOTONIC nanoseconds: sent_ns before the request's first write, response_ns at END_STREAM.
// Failure zeros out and closes the connection; the handle remains owned by the caller and must still be closed.
int collo_bench_client_exchange(ColloBenchClient*, const ColloBenchExchange* request, ColloBenchReply* out);
void collo_bench_client_close(ColloBenchClient*);

#ifdef __cplusplus
}
#endif
#endif

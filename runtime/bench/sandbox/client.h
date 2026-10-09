#ifndef COLLO_BENCH_SANDBOX_CLIENT_H
#define COLLO_BENCH_SANDBOX_CLIENT_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ColloBenchClient ColloBenchClient;
typedef struct ColloBenchReply {
    uint64_t sent_ns;
    uint64_t response_ns;
    uint32_t stream_id;
    uint32_t status;
    uint32_t body_len;
    uint32_t reserved;
} ColloBenchReply;

// Returns zero after loopback TLS+h2 and a bounded HTTP 200 /__collo/healthz preflight.
// Certificate verification is disabled solely for the local benchmark fixture.
// The caller owns *out and must close it; failures leave *out null.
int collo_bench_client_open(uint16_t port, const char* hostname, ColloBenchClient** out);

// Single-threaded, sequential requests; path and expected_body are NUL-terminated.
// Success requires HTTP 200, the exact body and END_STREAM. Times are absolute
// CLOCK_MONOTONIC nanoseconds. Failure zeros out and closes the connection; the
// handle remains owned by the caller and must still be closed.
int collo_bench_client_get(ColloBenchClient*, const char* path, const char* expected_body, ColloBenchReply* out);
void collo_bench_client_close(ColloBenchClient*);

#ifdef __cplusplus
}
#endif
#endif

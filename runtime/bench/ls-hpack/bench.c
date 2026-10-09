#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "lshpack.h"

static volatile uint64_t g_sink;

static uint64_t
monotonic_ns(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        perror("clock_gettime");
        exit(1);
    }
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static unsigned long
env_ulong(const char *name, unsigned long fallback)
{
    const char *value = getenv(name);
    if (value == NULL || value[0] == '\0')
        return fallback;
    errno = 0;
    char *end = NULL;
    unsigned long parsed = strtoul(value, &end, 10);
    if (errno != 0 || end == value || *end != '\0' || parsed == 0)
        return fallback;
    return parsed;
}

static void
run_valid_decode(const char *variant, unsigned long iterations)
{
    static const unsigned char block[] = {
        0x82, /* :method: GET */
        0x87, /* :scheme: https */
        0x84, /* :path: / */
        0x01, 0x11, 'd', 'e', 'm', 'o', '.', 'e', 'x', 'a', 'm',
        'p', 'l', 'e', '.', 't', 'e', 's', 't',
        0x00, 0x06, 'a', 'c', 'c', 'e', 'p', 't', 0x03, '*', '/', '*',
    };
    struct lshpack_dec dec;
    lshpack_dec_init(&dec);

    char out[512];
    uint64_t headers = 0;
    uint64_t bytes = 0;
    const uint64_t start = monotonic_ns();
    for (unsigned long i = 0; i < iterations; ++i) {
        const unsigned char *cursor = block;
        const unsigned char *end = block + sizeof(block);
        while (cursor < end) {
            struct lsxpack_header header;
            lsxpack_header_prepare_decode(&header, out, 0, sizeof(out));
            int status = lshpack_dec_decode(&dec, &cursor, end, &header);
            if (status != LSHPACK_OK) {
                fprintf(stderr, "%s valid decode failed with %d\n", variant, status);
                exit(2);
            }
            headers += 1;
            bytes += header.name_len + header.val_len;
        }
    }
    const uint64_t elapsed = monotonic_ns() - start;
    lshpack_dec_cleanup(&dec);
    g_sink += bytes;

    printf(
        "variant=%s case=valid_decode iterations=%lu headers=%" PRIu64
        " ns_total=%" PRIu64 " ns_per_header=%.2f sink=%" PRIu64 "\n",
        variant,
        iterations,
        headers,
        elapsed,
        (double)elapsed / (double)headers,
        bytes);
}

static void
run_missing_value_decode(const char *variant, unsigned long iterations)
{
    static const unsigned char block[] = { 0x41 };
    struct lshpack_dec dec;
    lshpack_dec_init(&dec);

    char out[512];
    uint64_t ok = 0;
    uint64_t bad_data = 0;
    uint64_t advanced = 0;
    uint64_t bytes = 0;
    const uint64_t start = monotonic_ns();
    for (unsigned long i = 0; i < iterations; ++i) {
        const unsigned char *cursor = block;
        const unsigned char *end = block + sizeof(block);
        struct lsxpack_header header;
        lsxpack_header_prepare_decode(&header, out, 0, sizeof(out));
        int status = lshpack_dec_decode(&dec, &cursor, end, &header);
        if (status == LSHPACK_OK) {
            ok += 1;
            bytes += header.name_len + header.val_len;
        } else if (status == LSHPACK_ERR_BAD_DATA) {
            bad_data += 1;
        } else {
            fprintf(stderr, "%s missing-value decode returned unexpected %d\n", variant, status);
            exit(3);
        }
        if (cursor != block)
            advanced += 1;
    }
    const uint64_t elapsed = monotonic_ns() - start;
    lshpack_dec_cleanup(&dec);
    g_sink += bytes + ok + bad_data + advanced;

    printf(
        "variant=%s case=missing_literal_value iterations=%lu ok=%" PRIu64
        " bad_data=%" PRIu64 " advanced=%" PRIu64
        " ns_total=%" PRIu64 " ns_per_iter=%.2f sink=%" PRIu64 "\n",
        variant,
        iterations,
        ok,
        bad_data,
        advanced,
        elapsed,
        (double)elapsed / (double)iterations,
        bytes);
}

struct encode_header {
    const char *name;
    const char *value;
    int hpack_index;
    int never_index;
};

static void
run_encode(const char *variant, const char *mode, unsigned long iterations, int preindexed)
{
    static const struct encode_header headers[] = {
        { ":status", "200", LSHPACK_HDR_STATUS_200, 0 },
        { "content-type", "text/plain", LSHPACK_HDR_CONTENT_TYPE, 0 },
        { "content-length", "2", LSHPACK_HDR_CONTENT_LENGTH, 0 },
        { "cache-control", "no-store", LSHPACK_HDR_CACHE_CONTROL, 0 },
        { "date", "Thu, 21 May 2026 14:00:00 GMT", LSHPACK_HDR_DATE, 0 },
        { "server", "collo", LSHPACK_HDR_SERVER, 0 },
        { "vary", "accept-encoding", LSHPACK_HDR_VARY, 0 },
        { "set-cookie", "sid=abc; HttpOnly", LSHPACK_HDR_SET_COOKIE, 1 },
    };
    struct lshpack_enc enc;
    if (lshpack_enc_init(&enc) != 0) {
        perror("lshpack_enc_init");
        exit(4);
    }

    unsigned char out[4096];
    char combined[512];
    uint64_t encoded_bytes = 0;
    uint64_t header_count = 0;
    const uint64_t start = monotonic_ns();
    for (unsigned long i = 0; i < iterations; ++i) {
        unsigned char *cursor = out;
        for (size_t n = 0; n < sizeof(headers) / sizeof(headers[0]); ++n) {
            const struct encode_header *header = &headers[n];
            const size_t name_len = strlen(header->name);
            const size_t value_len = strlen(header->value);
            struct lsxpack_header xhdr;
            if (preindexed) {
                lsxpack_header_set_idx(&xhdr, header->hpack_index, header->value, value_len);
            } else {
                memcpy(combined, header->name, name_len);
                memcpy(combined + name_len, header->value, value_len);
                lsxpack_header_set_offset2(&xhdr, combined, 0, name_len, name_len, value_len);
            }
            if (header->never_index)
                xhdr.flags |= LSXPACK_NEVER_INDEX;
            unsigned char *next = lshpack_enc_encode(&enc, cursor, out + sizeof(out), &xhdr);
            if (next <= cursor) {
                fprintf(stderr, "%s %s encode failed\n", variant, mode);
                exit(5);
            }
            encoded_bytes += (uint64_t)(next - cursor);
            header_count += 1;
            cursor = next;
        }
    }
    const uint64_t elapsed = monotonic_ns() - start;
    lshpack_enc_cleanup(&enc);
    g_sink += encoded_bytes;

    printf(
        "variant=%s case=%s iterations=%lu headers=%" PRIu64
        " ns_total=%" PRIu64 " ns_per_header=%.2f encoded_bytes=%" PRIu64 "\n",
        variant,
        mode,
        iterations,
        header_count,
        elapsed,
        (double)elapsed / (double)header_count,
        encoded_bytes);
}

int
main(int argc, char **argv)
{
    const char *variant = argc > 1 ? argv[1] : "unknown";
    const unsigned long valid_iters = env_ulong("LS_PACK_VALID_ITERS", 1000000ul);
    const unsigned long invalid_iters = env_ulong("LS_PACK_INVALID_ITERS", 1000000ul);
    const unsigned long encode_iters = env_ulong("LS_PACK_ENCODE_ITERS", 1000000ul);
    run_valid_decode(variant, valid_iters);
    run_missing_value_decode(variant, invalid_iters);
    run_encode(variant, "encode_raw_headers", encode_iters, 0);
    run_encode(variant, "encode_preindexed_headers", encode_iters, 1);
    return (int)(g_sink == 0xffffffffffffffffull);
}

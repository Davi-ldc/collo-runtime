/*
 * Small C ABI wrapper around ls-hpack: one decoded field per call and one
 * encoded field per call, each into a buffer the caller passes.
 *
 * Zig keeps HPACK ownership opaque so ls-hpack can keep its native struct
 * layout and dynamic-table invariants. Sensitive fields are encoded as
 * never-indexed literals here, so they never enter a dynamic table.
 */

#include <stdint.h>
#include <limits.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#include "lshpack.h"

int lshpack_enc_huff_encode(
    const unsigned char *src,
    const unsigned char *const src_end,
    unsigned char *const dst,
    int dst_len);

enum {
    COLLO_HPACK_OK = 0,
    COLLO_HPACK_DONE = 1,
    COLLO_HPACK_INVALID_ARGUMENT = -1,
    COLLO_HPACK_OUT_OF_MEMORY = -2,
    COLLO_HPACK_BAD_DATA = -3,
    COLLO_HPACK_TOO_LARGE = -4,
    COLLO_HPACK_OUTPUT_TOO_SMALL = -5,
};

struct collo_hpack_decoder {
    struct lshpack_dec dec;
};

struct collo_hpack_encoder {
    struct lshpack_enc enc;
};

struct collo_hpack_decoded_header {
    uint32_t name_offset;
    uint32_t name_len;
    uint32_t value_offset;
    uint32_t value_len;
};

static int collo_hpack_eq(const char *bytes, size_t len, const char *literal)
{
    const size_t literal_len = strlen(literal);
    return len == literal_len && memcmp(bytes, literal, literal_len) == 0;
}

/* O(1) static-table name lookup via the patched ls-hpack XXH precompute.
 * The lsxpack buffer points at the caller's name with a zero-length value,
 * so no copy is needed. Returns the static index (the first entry for names
 * with several values) or LSHPACK_HDR_UNKNOWN, and reports the computed name
 * hash through name_hash when it is non-NULL. */
static unsigned collo_hpack_static_name_index(
    const char *name,
    size_t name_len,
    uint32_t *name_hash)
{
    struct lsxpack_header xhdr;
    lsxpack_header_set_offset2(&xhdr, name, 0, name_len, name_len, 0);
    const unsigned index =
        lshpack_enc_precompute_static(&xhdr, LSHPACK_ENC_PRECOMPUTE_NAME_ONLY);
    if (name_hash != NULL)
        *name_hash = xhdr.name_hash;
    return index;
}

static int collo_hpack_should_never_index(const char *name, size_t name_len)
{
    /* Sensitive headers are never-indexed literals so they never enter the
     * dynamic table for CRIME/BREACH-style compression safety. */
    return collo_hpack_eq(name, name_len, "authorization") ||
        collo_hpack_eq(name, name_len, "proxy-authorization") ||
        collo_hpack_eq(name, name_len, "cookie") ||
        collo_hpack_eq(name, name_len, "set-cookie");
}

static int collo_hpack_encode_int(
    uint8_t **cursor,
    uint8_t *end,
    uint8_t prefix,
    uint8_t prefix_bits,
    uint32_t value)
{
    if (*cursor >= end)
        return COLLO_HPACK_OUTPUT_TOO_SMALL;

    const uint32_t prefix_max = (1u << prefix_bits) - 1u;
    if (value < prefix_max) {
        **cursor = (uint8_t)(prefix | value);
        ++*cursor;
        return COLLO_HPACK_OK;
    }

    **cursor = (uint8_t)(prefix | prefix_max);
    ++*cursor;
    value -= prefix_max;
    while (value >= 128) {
        if (*cursor >= end)
            return COLLO_HPACK_OUTPUT_TOO_SMALL;
        **cursor = (uint8_t)((value & 0x7f) | 0x80);
        ++*cursor;
        value >>= 7;
    }
    if (*cursor >= end)
        return COLLO_HPACK_OUTPUT_TOO_SMALL;
    **cursor = (uint8_t)value;
    ++*cursor;
    return COLLO_HPACK_OK;
}

static size_t collo_hpack_encoded_int_len(uint8_t prefix_bits, uint32_t value)
{
    const uint32_t prefix_max = (1u << prefix_bits) - 1u;
    if (value < prefix_max)
        return 1;

    size_t len = 1;
    value -= prefix_max;
    while (value >= 128) {
        value >>= 7;
        ++len;
    }
    return len + 1;
}

static int collo_hpack_encode_raw_string(
    uint8_t **cursor,
    uint8_t *end,
    const char *bytes,
    size_t len)
{
    if (len > UINT32_MAX)
        return COLLO_HPACK_TOO_LARGE;
    int status = collo_hpack_encode_int(cursor, end, 0, 7, (uint32_t)len);
    if (status != COLLO_HPACK_OK)
        return status;
    if ((size_t)(end - *cursor) < len)
        return COLLO_HPACK_OUTPUT_TOO_SMALL;
    memcpy(*cursor, bytes, len);
    *cursor += len;
    return COLLO_HPACK_OK;
}

static int collo_hpack_encode_string(
    uint8_t **cursor,
    uint8_t *end,
    const char *bytes,
    size_t len)
{
    if (len > UINT32_MAX)
        return COLLO_HPACK_TOO_LARGE;

    const size_t available = (size_t)(end - *cursor);
    if (len != 0 && available > 1 && available - 1 <= INT_MAX) {
        uint8_t *const huffman = *cursor + 1;
        const int huffman_len_signed = lshpack_enc_huff_encode(
            (const unsigned char *)bytes,
            (const unsigned char *)bytes + len,
            huffman,
            (int)(available - 1));
        if (huffman_len_signed > 0 && (size_t)huffman_len_signed <= len) {
            const size_t huffman_len = (size_t)huffman_len_signed;
            const size_t prefix_len = collo_hpack_encoded_int_len(7, (uint32_t)huffman_len);
            if (available < prefix_len + huffman_len)
                return COLLO_HPACK_OUTPUT_TOO_SMALL;
            if (prefix_len != 1)
                memmove(*cursor + prefix_len, huffman, huffman_len);
            const int status = collo_hpack_encode_int(
                cursor,
                end,
                0x80,
                7,
                (uint32_t)huffman_len);
            if (status != COLLO_HPACK_OK)
                return status;
            *cursor += huffman_len;
            return COLLO_HPACK_OK;
        }
    }

    return collo_hpack_encode_raw_string(cursor, end, bytes, len);
}

/* Hand-rolled never-indexed literal encoding (RFC 7541 section 6.2.3) so
 * sensitive headers bypass the ls-hpack dynamic table entirely. Only the
 * static table may be used for the name. */
static int collo_hpack_encode_never_index_header(
    uint8_t *dst,
    size_t dst_len,
    size_t *offset,
    const char *name,
    size_t name_len,
    const char *value,
    size_t value_len)
{
    uint8_t *cursor = dst + *offset;
    uint8_t *end = dst + dst_len;
    const unsigned static_name_index = collo_hpack_static_name_index(name, name_len, NULL);

    int status;
    if (static_name_index != LSHPACK_HDR_UNKNOWN) {
        status = collo_hpack_encode_int(&cursor, end, 0x10, 4, (uint32_t)static_name_index);
    } else {
        status = collo_hpack_encode_int(&cursor, end, 0x10, 4, 0);
        if (status == COLLO_HPACK_OK)
            status = collo_hpack_encode_string(&cursor, end, name, name_len);
    }
    if (status != COLLO_HPACK_OK)
        return status;

    status = collo_hpack_encode_string(&cursor, end, value, value_len);
    if (status != COLLO_HPACK_OK)
        return status;

    *offset = (size_t)(cursor - dst);
    return COLLO_HPACK_OK;
}

int collo_hpack_decoder_new(struct collo_hpack_decoder **out)
{
    if (out == NULL)
        return COLLO_HPACK_INVALID_ARGUMENT;
    *out = NULL;
    struct collo_hpack_decoder *decoder = (struct collo_hpack_decoder *)calloc(1, sizeof(*decoder));
    if (decoder == NULL)
        return COLLO_HPACK_OUT_OF_MEMORY;
    lshpack_dec_init(&decoder->dec);
    *out = decoder;
    return COLLO_HPACK_OK;
}

void collo_hpack_decoder_free(struct collo_hpack_decoder *decoder)
{
    if (decoder == NULL)
        return;
    lshpack_dec_cleanup(&decoder->dec);
    free(decoder);
}

void collo_hpack_decoder_set_max_capacity(struct collo_hpack_decoder *decoder, uint32_t capacity)
{
    if (decoder == NULL)
        return;
    lshpack_dec_set_max_capacity(&decoder->dec, capacity);
}

int collo_hpack_decode_one(
    struct collo_hpack_decoder *decoder,
    const uint8_t *src,
    size_t src_len,
    size_t *offset,
    char *out,
    size_t out_len,
    struct collo_hpack_decoded_header *header)
{
    if (decoder == NULL || offset == NULL || header == NULL || *offset > src_len)
        return COLLO_HPACK_INVALID_ARGUMENT;
    if (*offset == src_len)
        return COLLO_HPACK_DONE;
    if (src == NULL || out == NULL || out_len == 0)
        return COLLO_HPACK_INVALID_ARGUMENT;

    const unsigned char *cursor = src + *offset;
    const unsigned char *end = src + src_len;
    struct lsxpack_header xhdr;
    lsxpack_header_prepare_decode(&xhdr, out, 0, out_len);
    const int status = lshpack_dec_decode(&decoder->dec, &cursor, end, &xhdr);
    if (status == LSHPACK_OK) {
        *offset = (size_t)(cursor - src);
        header->name_offset = (uint32_t)xhdr.name_offset;
        header->name_len = (uint32_t)xhdr.name_len;
        header->value_offset = (uint32_t)xhdr.val_offset;
        header->value_len = (uint32_t)xhdr.val_len;
        return COLLO_HPACK_OK;
    }
    if (status == LSHPACK_ERR_MORE_BUF)
        return COLLO_HPACK_OUTPUT_TOO_SMALL;
    if (status == LSHPACK_ERR_TOO_LARGE)
        return COLLO_HPACK_TOO_LARGE;
    return COLLO_HPACK_BAD_DATA;
}

int collo_hpack_encoder_new(struct collo_hpack_encoder **out)
{
    if (out == NULL)
        return COLLO_HPACK_INVALID_ARGUMENT;
    *out = NULL;
    struct collo_hpack_encoder *encoder = (struct collo_hpack_encoder *)calloc(1, sizeof(*encoder));
    if (encoder == NULL)
        return COLLO_HPACK_OUT_OF_MEMORY;
    if (lshpack_enc_init(&encoder->enc) != 0) {
        free(encoder);
        return COLLO_HPACK_OUT_OF_MEMORY;
    }
    *out = encoder;
    return COLLO_HPACK_OK;
}

void collo_hpack_encoder_free(struct collo_hpack_encoder *encoder)
{
    if (encoder == NULL)
        return;
    lshpack_enc_cleanup(&encoder->enc);
    free(encoder);
}

void collo_hpack_encoder_set_max_capacity(struct collo_hpack_encoder *encoder, uint32_t capacity)
{
    if (encoder == NULL)
        return;
    lshpack_enc_set_max_capacity(&encoder->enc, capacity);
}

int collo_hpack_encode_header(
    struct collo_hpack_encoder *encoder,
    uint8_t *dst,
    size_t dst_len,
    size_t *offset,
    const char *name,
    size_t name_len,
    const char *value,
    size_t value_len)
{
    if (encoder == NULL || dst == NULL || offset == NULL || *offset > dst_len ||
        name == NULL || value == NULL)
        return COLLO_HPACK_INVALID_ARGUMENT;
    if (name_len > LSHPACK_MAX_STRLEN || value_len > LSHPACK_MAX_STRLEN)
        return COLLO_HPACK_TOO_LARGE;
    if (collo_hpack_should_never_index(name, name_len))
        return collo_hpack_encode_never_index_header(dst, dst_len, offset, name, name_len, value, value_len);

    char inline_storage[512];
    char *combined = NULL;

    struct lsxpack_header xhdr;
    uint32_t name_hash = 0;
    const unsigned static_name_index = collo_hpack_static_name_index(name, name_len, &name_hash);
    if (static_name_index != LSHPACK_HDR_UNKNOWN) {
        /* A static name match avoids the combined name+value copy: the
         * encoder only needs the value once the name is table-indexed. The
         * FULL precompute checks the value against the indexed static entry
         * and sets LSXPACK_HPACK_VAL_MATCHED on an exact match. */
        lsxpack_header_set_idx(&xhdr, (int)static_name_index, value, value_len);
        (void)lshpack_enc_precompute_static(&xhdr, LSHPACK_ENC_PRECOMPUTE_FULL);
    } else {
        const size_t combined_len = name_len + value_len;
        combined = inline_storage;
        if (combined_len > sizeof(inline_storage)) {
            combined = (char *)malloc(combined_len);
            if (combined == NULL)
                return COLLO_HPACK_OUT_OF_MEMORY;
        }
        memcpy(combined, name, name_len);
        memcpy(combined + name_len, value, value_len);
        lsxpack_header_set_offset2(&xhdr, combined, 0, name_len, name_len, value_len);
        /* No static name match exists, so no static name+value match can
         * exist either; skip the FULL precompute and seed the name hash the
         * lookup just computed so the encoder does not hash the name twice.
         * The hash is only meaningful for a non-empty name. */
        if (name_len != 0) {
            xhdr.name_hash = name_hash;
            xhdr.flags |= LSXPACK_NAME_HASH;
        }
    }
    unsigned char *start = dst + *offset;
    unsigned char *encoded = lshpack_enc_encode(&encoder->enc, start, dst + dst_len, &xhdr);
    if (combined != NULL && combined != inline_storage)
        free(combined);
    if (encoded == start)
        return COLLO_HPACK_OUTPUT_TOO_SMALL;

    *offset = (size_t)(encoded - dst);
    return COLLO_HPACK_OK;
}

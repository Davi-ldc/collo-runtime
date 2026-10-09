// Fills the owned memory that extracted_response.h describes, and defines the ABI functions that free it. Runs on the
// VM thread.

#include "host_functions/server/fetch/extracted_response.h"

#include <limits>
#include <new>

namespace Collo::HostFunctions {
namespace {

    bool addCopiedBytesWithinLimit(size_t& total, size_t bytes, size_t limit)
    {
        if (bytes > limit || total > limit - bytes)
            return false;
        total += bytes;
        return true;
    }

} // namespace

void resetExtractedResponse(ColloExtractedResponse* response)
{
    if (!response)
        return;
    response->body = {};
    response->headers = {};
    response->status = 0;
    response->reserved0 = 0;
    response->reserved1 = 0;
}

void resetExtractedResponseBody(ColloExtractedResponseBody& out)
{
    out.kind = COLLO_EXTRACTED_RESPONSE_BODY_EMPTY;
    out.flags = 0;
    out.total_len = 0;
    out.segments = nullptr;
    out.segments_len = 0;
    out.owner = nullptr;
    out.stream_identity = {};
}

bool publishOwnedByteSegment(
    ColloOwnedByteSegments& owner, ColloExtractedResponseBody& out, std::span<const uint8_t> bytes)
{
    if (!owner.segments.tryAppend(ColloByteSegment {
            { bytes.empty() ? nullptr : bytes.data(), bytes.size() },
        }))
        return false;
    out.kind = COLLO_EXTRACTED_RESPONSE_BODY_BYTES;
    out.total_len = bytes.size();
    out.segments = owner.segments.span().data();
    out.segments_len = owner.segments.size();
    out.owner = &owner;
    return true;
}

bool publishBlobSegments(ColloOwnedByteSegments& owner, ColloExtractedResponseBody& out, size_t expected_byte_length)
{
    if (!owner.segments.tryReserveInitialCapacity(owner.blob_segments.size()))
        return false;

    size_t total_len = 0;
    for (const auto& segment : owner.blob_segments) {
        if (segment.offset > segment.storage->size())
            return false;
        if (segment.size > segment.storage->size() - segment.offset)
            return false;
        if (total_len > std::numeric_limits<size_t>::max() - segment.size)
            return false;

        auto bytes = segment.storage->span().subspan(segment.offset, segment.size);
        owner.segments.append(ColloByteSegment {
            { bytes.empty() ? nullptr : bytes.data(), bytes.size() },
        });
        total_len += bytes.size();
    }

    if (total_len != expected_byte_length)
        return false;
    out.kind = owner.segments.size() <= 1 ? COLLO_EXTRACTED_RESPONSE_BODY_BYTES
                                          : COLLO_EXTRACTED_RESPONSE_BODY_BYTE_SEGMENTS;
    out.total_len = total_len;
    out.segments = owner.segments.isEmpty() ? nullptr : owner.segments.span().data();
    out.segments_len = owner.segments.size();
    out.owner = &owner;
    return true;
}

ColloStatus copyHeadersToExtracted(
    const WTF::Vector<ColloHeaderPair>& pairs, const ColloResponseExtractLimits& limits, ColloExtractedHeaderBlock* out)
{
    if (pairs.isEmpty())
        return COLLO_STATUS_OK;
    if (pairs.size() > limits.max_header_count)
        return COLLO_STATUS_RESPONSE_HEADER_COUNT_TOO_LARGE;

    auto* owner = new (std::nothrow) ColloOwnedHeaderBlock;
    if (!owner)
        return COLLO_STATUS_OUT_OF_MEMORY;

    // This pass only measures, so a block over the byte limit fails before its storage is allocated.
    size_t storage_size = 0;
    for (unsigned index = 0; index < pairs.size(); index++) {
        auto name = pairs[index].name.tryGetUTF8();
        auto value = pairs[index].value.tryGetUTF8();
        if (!name || !value) {
            delete owner;
            return COLLO_STATUS_OUT_OF_MEMORY;
        }
        if (!addCopiedBytesWithinLimit(storage_size, name.value().length(), limits.max_header_bytes)) {
            delete owner;
            return COLLO_STATUS_RESPONSE_HEADER_BYTES_TOO_LARGE;
        }
        if (!addCopiedBytesWithinLimit(storage_size, value.value().length(), limits.max_header_bytes)) {
            delete owner;
            return COLLO_STATUS_RESPONSE_HEADER_BYTES_TOO_LARGE;
        }
    }

    if (!owner->storage.tryReserveInitialCapacity(storage_size)
        || !owner->headers.tryReserveInitialCapacity(pairs.size())) {
        delete owner;
        return COLLO_STATUS_OUT_OF_MEMORY;
    }

    for (unsigned index = 0; index < pairs.size(); index++) {
        auto name = pairs[index].name.tryGetUTF8();
        auto value = pairs[index].value.tryGetUTF8();
        if (!name || !value) {
            delete owner;
            return COLLO_STATUS_OUT_OF_MEMORY;
        }
        const uint32_t name_offset = static_cast<uint32_t>(owner->storage.size());
        if (!owner->storage.tryAppend(std::span<const uint8_t> {
                reinterpret_cast<const uint8_t*>(name.value().data()), name.value().length() })) {
            delete owner;
            return COLLO_STATUS_OUT_OF_MEMORY;
        }
        const uint32_t value_offset = static_cast<uint32_t>(owner->storage.size());
        if (!owner->storage.tryAppend(std::span<const uint8_t> {
                reinterpret_cast<const uint8_t*>(value.value().data()), value.value().length() })) {
            delete owner;
            return COLLO_STATUS_OUT_OF_MEMORY;
        }
        if (!owner->headers.tryAppend(ColloHeaderView {
                name_offset,
                static_cast<uint32_t>(name.value().length()),
                value_offset,
                static_cast<uint32_t>(value.value().length()),
                0,
            })) {
            delete owner;
            return COLLO_STATUS_OUT_OF_MEMORY;
        }
    }

    out->storage = {
        owner->storage.isEmpty() ? nullptr : owner->storage.span().data(),
        owner->storage.size(),
    };
    out->headers = owner->headers.isEmpty() ? nullptr : owner->headers.span().data();
    out->headers_len = owner->headers.size();
    out->owner = owner;
    return COLLO_STATUS_OK;
}

} // namespace Collo::HostFunctions

extern "C" void collo_response_extract_free(ColloExtractedResponse* response)
{
    if (!response)
        return;
    if (response->body.owner)
        collo_owned_byte_segments_destroy(response->body.owner);
    if (response->headers.owner)
        collo_owned_header_block_destroy(response->headers.owner);
    Collo::HostFunctions::resetExtractedResponse(response);
}

extern "C" void collo_owned_byte_segments_destroy(ColloOwnedByteSegments* owner) { delete owner; }

extern "C" void collo_owned_header_block_destroy(ColloOwnedHeaderBlock* owner) { delete owner; }

// Fills the owned memory that extracted_response.h describes, and defines the ABI functions that free it. Runs on the
// VM thread.

#include "host_functions/server/fetch/extracted_response.h"

namespace Collo::HostFunctions {

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
    out.reserved0 = 0;
    out.total_len = 0;
    out.segments = nullptr;
    out.segments_len = 0;
    out.owner = nullptr;
    out.stream_identity = {};
    out.body_stream = nullptr;
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

} // namespace Collo::HostFunctions

extern "C" void collo_response_extract_free(ColloExtractedResponse* response)
{
    if (!response)
        return;
    if (response->body.owner)
        collo_owned_byte_segments_destroy(response->body.owner);
    if (response->body.body_stream)
        collo_response_body_stream_destroy(response->body.body_stream);
    if (response->headers.owner)
        collo_owned_header_block_destroy(response->headers.owner);
    Collo::HostFunctions::resetExtractedResponse(response);
}

extern "C" void collo_owned_byte_segments_destroy(ColloOwnedByteSegments* owner) { delete owner; }

extern "C" void collo_owned_header_block_destroy(ColloOwnedHeaderBlock* owner) { delete owner; }

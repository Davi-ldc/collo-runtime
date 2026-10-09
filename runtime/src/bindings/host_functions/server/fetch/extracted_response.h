// The owned memory behind a ColloExtractedResponse, the snapshot of a Response's status, headers and body that
// collo_response_extract (response.cpp) hands to Zig, and the helpers that fill and free it. The headers are always
// copied. Body segments hold a copy of the bytes or view shared storage, and a fetch-stream body moves to Zig as its
// identity, with no owner here. abi.h declares both owner types opaque, so Zig frees them only through
// collo_response_extract_free, collo_owned_byte_segments_destroy and collo_owned_header_block_destroy, and every
// segment and header view stays valid until then, even after the Response is collected. A body owner drops BlobBytes
// references, whose counts are not atomic, so it must be destroyed on the VM thread.

#pragma once

#include "host_functions/support.h"
#include "host_functions/server/fetch/headers.h"
#include "host_functions/webapi/files/blob.h"
#include "host_functions/webapi/streams/shared_bytes.h"

#include <wtf/RefPtr.h>
#include <wtf/Vector.h>

#include <cstddef>
#include <span>

// `segments` is what Zig reads. Each segment points into `owned_bytes`, a private copy, or into a buffer that
// `shared_bytes` or `blob_segments` keeps referenced.
struct ColloOwnedByteSegments {
    WTF::Vector<ColloByteSegment> segments;
    WTF::Vector<WTF::RefPtr<Collo::HostFunctions::ColloSharedBytes>> shared_bytes;
    WTF::Vector<Collo::HostFunctions::BlobSegment> blob_segments;
    WTF::Vector<uint8_t> owned_bytes;
};

// `storage` holds every name and value as UTF-8, back to back, and each view in `headers` locates its name and value
// by offset into it.
struct ColloOwnedHeaderBlock {
    WTF::Vector<uint8_t> storage;
    WTF::Vector<ColloHeaderView> headers;
};

namespace Collo::HostFunctions {

// Clear every field without freeing an owner; resetExtractedResponse ignores null.
void resetExtractedResponse(ColloExtractedResponse*);
void resetExtractedResponseBody(ColloExtractedResponseBody&);
// Publishes `bytes`, which `owner` must keep alive, as the single segment of the body and hands `owner` to it.
// Returns false, leaving the body untouched, when the segment cannot be appended.
bool publishOwnedByteSegment(ColloOwnedByteSegments&, ColloExtractedResponseBody&, std::span<const uint8_t>);
// Publishes `owner.blob_segments` as the segments of the body and hands `owner` to it. Returns false, leaving the
// body untouched, when a segment falls outside its bytes, the segments do not add up to `expected_byte_length`, or
// allocation fails.
bool publishBlobSegments(ColloOwnedByteSegments&, ColloExtractedResponseBody&, size_t expected_byte_length);
// Copies the pairs as UTF-8 into a new header block and publishes it in the last argument, which stays untouched
// when there are no pairs and on failure. Fails with COLLO_STATUS_RESPONSE_HEADER_COUNT_TOO_LARGE or
// COLLO_STATUS_RESPONSE_HEADER_BYTES_TOO_LARGE when the pairs exceed the limits, where the byte limit covers every
// name and value, or with COLLO_STATUS_OUT_OF_MEMORY. The byte limit must fit in 32 bits, since the views hold 32-bit
// offsets.
ColloStatus copyHeadersToExtracted(
    const WTF::Vector<ColloHeaderPair>&, const ColloResponseExtractLimits&, ColloExtractedHeaderBlock*);

} // namespace Collo::HostFunctions

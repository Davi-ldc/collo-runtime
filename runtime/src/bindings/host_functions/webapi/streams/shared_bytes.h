// ColloSharedBytes, a byte buffer that body producers, native stream sources and ArrayBuffers share by reference
// instead of copying. The bridge uses it on the VM thread. The reference count is atomic, so the last reference may
// drop on any thread, but the bytes have no lock: they may be written only while a single reference exists, and once
// a second one exists they are only read. A buffer with one reference can become the storage of a JavaScript
// ArrayBuffer, which then owns that reference until the collector frees the ArrayBuffer
// (createArrayBufferFromExclusiveSharedBytes in stream_common.cpp).

#pragma once

#include <wtf/Forward.h>
#include <wtf/FastMalloc.h>
#include <wtf/Ref.h>
#include <wtf/RefPtr.h>
#include <wtf/StdLibExtras.h>
#include <wtf/ThreadSafeRefCounted.h>
#include <wtf/Vector.h>

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <span>
#include <utility>

namespace Collo::HostFunctions {

class ColloSharedBytes final : public WTF::ThreadSafeRefCounted<ColloSharedBytes> {
    WTF_MAKE_NONCOPYABLE(ColloSharedBytes);

public:
    // Takes ownership of bytes. Returns null when the object cannot be allocated, leaving bytes with the caller.
    static WTF::RefPtr<ColloSharedBytes> create(WTF::Vector<uint8_t>&& bytes)
    {
        void* storage = nullptr;
        if (!WTF::tryFastMalloc(sizeof(ColloSharedBytes)).getValue(storage))
            return nullptr;
        auto* bytes_storage = new (NotNull, storage) ColloSharedBytes(WTF::move(bytes));
        return adoptRef(*bytes_storage);
    }

    // Returns null when the copy or the object cannot be allocated.
    static WTF::RefPtr<ColloSharedBytes> copy(std::span<const uint8_t> bytes)
    {
        WTF::Vector<uint8_t> storage;
        if (!storage.tryAppend(bytes))
            return nullptr;
        return create(WTF::move(storage));
    }

    static WTF::RefPtr<ColloSharedBytes> empty()
    {
        WTF::Vector<uint8_t> storage;
        return create(WTF::move(storage));
    }

    std::span<const uint8_t> span() const LIFETIME_BOUND { return m_bytes.span(); }
    std::span<uint8_t> mutableSpan() LIFETIME_BOUND { return m_bytes.mutableSpan(); }
    size_t size() const { return m_bytes.size(); }
    bool hasOneRef() const { return ThreadSafeRefCounted::hasOneRef(); }

    // mutableSpan and takeVectorForExclusiveUse are for the holder of the only reference. The assertion compiles out
    // of Release builds, so the caller must know by construction that no other reference exists.
    WTF::Vector<uint8_t> takeVectorForExclusiveUse()
    {
        ASSERT(hasOneRef());
        return std::exchange(m_bytes, {});
    }

    // Clamps the range to the buffer; an offset past the end yields an empty span.
    std::span<const uint8_t> slice(size_t offset, size_t length) const LIFETIME_BOUND
    {
        if (offset > m_bytes.size())
            return {};
        length = std::min(length, m_bytes.size() - offset);
        return m_bytes.span().subspan(offset, length);
    }

    // Appends slice(offset, length) to out. Returns false when out cannot grow.
    bool appendTo(WTF::Vector<uint8_t>& out, size_t offset, size_t length) const
    {
        return out.tryAppend(slice(offset, length));
    }

private:
    explicit ColloSharedBytes(WTF::Vector<uint8_t>&& bytes)
        : m_bytes(WTF::move(bytes))
    {
    }

    WTF::Vector<uint8_t> m_bytes;
};

} // namespace Collo::HostFunctions

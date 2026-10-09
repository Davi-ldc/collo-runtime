// The Blob and File cells and the byte storage behind them. A BlobStorage is an immutable list of segments over
// shared BlobBytes, so slices, Blobs built from other Blobs, Files made from Blobs, structured clones, fetch bodies
// and blob streams share bytes instead of copying them. Runs on the VM thread; marking threads read a storage's cost.
//
// BlobBytes and BlobStorage never change after creation. Their reference counts are not atomic, so only the VM thread
// takes or drops a reference, and a marking thread only calls memoryCost() and tryClaimExtraMemoryReport(). A Blob
// cell holds its storage through a by-value Ref, released when the collector sweeps the cell, and never changes its
// fields after creation, so visitChildren reads them without a lock.

#pragma once

#include "host_functions/support.h"
#include "host_functions/webapi/files/blob_backing_store.h"

#include <JavaScriptCore/JSDestructibleObject.h>
#include <wtf/Ref.h>
#include <wtf/RefCounted.h>
#include <wtf/RefPtr.h>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <span>

namespace Collo::HostFunctions {

// One byte allocation, shared by every segment that views it.
class BlobBytes final : public WTF::RefCounted<BlobBytes> {
public:
    // Adopts the vector. Returns null when allocating the object fails.
    static WTF::RefPtr<BlobBytes> create(WTF::Vector<uint8_t>&&);

    std::span<const uint8_t> span() const LIFETIME_BOUND;
    size_t size() const { return m_bytes.size(); }
    // The object plus the vector's capacity, as the object URL registry and memoryCost() charge it.
    size_t objectURLMemoryCost() const;

private:
    explicit BlobBytes(WTF::Vector<uint8_t>&&);

    WTF::Vector<uint8_t> m_bytes;
};

// `size` bytes at `offset` in `storage`.
struct BlobSegment {
    BlobSegment(WTF::Ref<BlobBytes>&&, size_t offset, size_t size);
    BlobSegment(const BlobSegment&);
    BlobSegment(BlobSegment&&) = default;
    BlobSegment& operator=(const BlobSegment&);
    BlobSegment& operator=(BlobSegment&&) = default;
    ~BlobSegment() = default;

    WTF::Ref<BlobBytes> storage;
    size_t offset { 0 };
    size_t size { 0 };
};

// The bytes of one or more Blobs, as segments in order.
class BlobStorage final : public WTF::RefCounted<BlobStorage> {
public:
    // `size` must equal the sum of the segment sizes. Returns null on allocation failure.
    static WTF::RefPtr<BlobStorage> create(WTF::Vector<BlobSegment>&&, size_t size);
    // One segment over the vector, or none when it is empty. Returns null on allocation failure.
    static WTF::RefPtr<BlobStorage> create(WTF::Vector<uint8_t>&&);

    size_t size() const { return m_size; }
    // This object and its vectors, plus the full objectURLMemoryCost() of every distinct BlobBytes it references,
    // even one it views only in part. Fixed at creation.
    size_t memoryCost() const;
    // Appends `size` bytes from `offset`. Returns false when the range is out of bounds or the append cannot
    // allocate, leaving a partial copy in the vector.
    bool appendTo(WTF::Vector<uint8_t>&, size_t offset, size_t size) const;
    // Appends segments that view `size` bytes from `offset`, sharing their BlobBytes. A non-zero `max_segments` caps
    // the length of `out`: the call returns false, with what it appended so far left in `out`, as soon as one more
    // segment would exceed the cap, so a caller that flattens fragmented storage never builds the over-cap vector
    // first. Also returns false on an out-of-bounds range or allocation failure.
    bool appendSegmentsTo(WTF::Vector<BlobSegment>&, size_t offset, size_t size, size_t max_segments = 0) const;
    // Appends what the object URL registry charges for this storage: the storage itself, then each distinct
    // BlobBytes. Returns false on allocation failure.
    bool appendObjectURLBackingStores(WTF::Vector<BlobObjectURLBackingStore>&) const;
    // The caller guarantees that the range lies within the storage and that the span holds `size` bytes; only debug
    // builds check.
    void copyTo(std::span<uint8_t>, size_t offset, size_t size) const;

    // Blob and File cells share storage, and a blob stream source reports the storage it keeps alive, so reporting
    // the whole storage from each would count it once per sharer. The first claimant of each marking version wins
    // this CAS and reports the storage; the others report only their own cost. JSC advances the marking version at
    // the start of every full collection, when the heap also resets its extra memory count, so the first live cell
    // visited in each full collection reports the storage again. The claim starts at JSC's null version, which no
    // marking version equals, so the first claim succeeds. Relaxed ordering suffices: parallel markers race only for
    // the claim, and nothing else is read through it.
    bool tryClaimExtraMemoryReport(uint32_t marking_version)
    {
        uint32_t claimed = m_extra_memory_claim_version.load(std::memory_order_relaxed);
        while (claimed != marking_version) {
            if (m_extra_memory_claim_version.compare_exchange_weak(claimed, marking_version, std::memory_order_relaxed))
                return true;
        }
        return false;
    }

private:
    BlobStorage(WTF::Vector<BlobSegment>&&, WTF::Vector<BlobObjectURLBackingStore>&&, size_t size,
        size_t object_url_metadata_cost, size_t memory_cost);

    WTF::Vector<BlobSegment> m_segments;
    WTF::Vector<BlobObjectURLBackingStore> m_object_url_byte_stores;
    size_t m_size { 0 };
    size_t m_object_url_metadata_cost { 0 };
    size_t m_memory_cost { 0 };
    std::atomic<uint32_t> m_extra_memory_claim_version { 0 };
};

// The Blob cell: a range of a BlobStorage and a type.
class JSColloBlob : public JSC::JSDestructibleObject {
    using Base = JSC::JSDestructibleObject;
    friend class JSColloFile;

public:
    template <typename CellType, JSC::SubspaceAccess> static JSC::CompleteSubspace* subspaceFor(JSC::VM& vm)
    {
        return &vm.destructibleObjectSpace();
    }

    static JSC::Structure* createStructure(JSC::VM&, JSC::JSGlobalObject*, JSC::JSValue prototype);
    // The range must lie within the storage; only debug builds check. Never returns null, since allocateCell aborts
    // when the heap is exhausted. The overloads below build a new storage first and return null when that fails.
    static JSColloBlob* create(
        JSC::VM&, JSC::Structure*, WTF::Ref<BlobStorage>&&, size_t offset, size_t size, WTF::String type);
    static JSColloBlob* create(JSC::VM&, JSC::Structure*, WTF::Vector<uint8_t>&&, WTF::String type);
    static JSColloBlob* create(JSC::VM&, JSC::Structure*, WTF::Vector<BlobSegment>&&, size_t size, WTF::String type);
    static void destroy(JSC::JSCell*);
    static size_t estimatedSize(JSC::JSCell*, JSC::VM&);

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    size_t size() const { return m_size; }
    const WTF::String& type() const { return m_type; }
    size_t memoryCost() const;
    bool appendBytes(WTF::Vector<uint8_t>&) const;
    // The span must hold size() bytes.
    void copyBytesTo(std::span<uint8_t>) const;
    bool appendStorageSegments(WTF::Vector<BlobSegment>&) const;
    bool appendObjectURLBackingStores(WTF::Vector<BlobObjectURLBackingStore>&) const;
    WTF::Ref<BlobStorage> storageRef() const { return m_storage.copyRef(); }
    size_t byteOffset() const { return m_offset; }
    // A new Blob over `length` bytes from `start`. The caller keeps the range within size(): only a range past the
    // end of the storage returns null, so this is no bounds check on the Blob. The new Blob gets a new storage that
    // shares this one's BlobBytes, or a private copy when those allocations total at least
    // BlobSegmentCompactionMinRetainedRatio times `length` (blob.cpp). Also returns null on allocation failure.
    JSColloBlob* slice(JSC::VM&, JSC::Structure*, size_t start, size_t length, WTF::String type);

protected:
    JSColloBlob(JSC::VM&, JSC::Structure*, WTF::Ref<BlobStorage>&&, size_t offset, size_t size, WTF::String type);
    ~JSColloBlob();

    void finishCreation(JSC::VM&);

    WTF::Ref<BlobStorage> m_storage;
    size_t m_offset { 0 };
    size_t m_size { 0 };
    WTF::String m_type;
};

// The File cell: a Blob with a name and a last-modified time in milliseconds since the epoch.
class JSColloFile final : public JSColloBlob {
    using Base = JSColloBlob;

public:
    template <typename CellType, JSC::SubspaceAccess> static JSC::CompleteSubspace* subspaceFor(JSC::VM& vm)
    {
        return &vm.destructibleObjectSpace();
    }

    static JSC::Structure* createStructure(JSC::VM&, JSC::JSGlobalObject*, JSC::JSValue prototype);
    static JSColloFile* create(
        JSC::VM&, JSC::Structure*, WTF::Vector<uint8_t>&&, WTF::String type, WTF::String name, double last_modified);
    static JSColloFile* create(JSC::VM&, JSC::Structure*, WTF::Vector<BlobSegment>&&, size_t size, WTF::String type,
        WTF::String name, double last_modified);
    // A File over the same storage and range as the Blob, with the Blob's type. Never returns null.
    static JSColloFile* createFromBlob(JSC::VM&, JSC::Structure*, JSColloBlob&, WTF::String name, double last_modified);
    static void destroy(JSC::JSCell*);
    static size_t estimatedSize(JSC::JSCell*, JSC::VM&);

    DECLARE_INFO;

    const WTF::String& name() const { return m_name; }
    double lastModified() const { return m_last_modified; }

private:
    JSColloFile(JSC::VM&, JSC::Structure*, WTF::Ref<BlobStorage>&&, size_t offset, size_t size, WTF::String type,
        WTF::String name, double last_modified);
    ~JSColloFile();

    void finishCreation(JSC::VM&);

    WTF::String m_name;
    double m_last_modified { 0 };
};

void installWebApiBlob(Collo::GlobalObject*, JSC::VM&);

} // namespace Collo::HostFunctions

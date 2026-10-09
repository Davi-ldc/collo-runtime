// Blob and File: the storage classes, the cells, the constructors' part processing, the methods, and the stream
// source behind Blob.stream(). Runs on the VM thread, except visitChildren, which marking threads run concurrently,
// and estimatedSize(), which a heap snapshot builder may call from inside marking. Both read only what is fixed at
// creation (the cell's fields and the cost of its strings and of its storage), and visitChildren also reads the
// storage's atomic claim.
//
// Each cell reports its type string as GC extra memory, and its storage too when it wins
// BlobStorage::tryClaimExtraMemoryReport. A File's name goes unreported (see the FIXME in JSColloFile::finishCreation).
// A constructor copies string and BufferSource parts into new BlobBytes and shares the BlobBytes of Blob parts, unless
// BlobSegmentCompactionMinRetainedRatio calls for a copy.

#include "host_functions/webapi/files/blob.h"
#include "host_functions/webapi/dom/dom_exception.h"
#include "host_functions/webapi/buffer_source.h"
#include "host_functions/webapi/encoding/utf8.h"
#include "host_functions/webapi/files/file.h"
#include "host_functions/webapi/files/formdata.h"
#include "host_functions/webapi/limits.h"
#include "host_functions/webapi/streams/readable_stream.h"

#include <JavaScriptCore/ArrayBufferSharingMode.h>
#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/IdentifierInlines.h>
#include <JavaScriptCore/InternalFunction.h>
#include <JavaScriptCore/IteratorOperations.h>
#include <JavaScriptCore/JSArray.h>
#include <JavaScriptCore/JSArrayBuffer.h>
#include <JavaScriptCore/JSArrayBufferView.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSFunction.h>
#include <JavaScriptCore/JSGenericTypedArrayViewInlines.h>
#include <JavaScriptCore/JSObject.h>
#include <JavaScriptCore/JSString.h>
#include <JavaScriptCore/JSTypedArrays.h>
#include <JavaScriptCore/SlotVisitorMacros.h>
#include <wtf/ASCIICType.h>
#include <wtf/FastMalloc.h>
#include <wtf/MathExtras.h>
#include <wtf/StdLibExtras.h>
#include <wtf/Vector.h>
#include <wtf/WallTime.h>
#include <wtf/text/Latin1Character.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringImpl.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/WTFString.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <functional>
#include <limits>
#include <new>
#include <optional>

namespace Collo::HostFunctions {

using JSC::EncodedJSValue;
using JSC::JSValue;
using WTF::String;
using namespace JSC;

static size_t saturatingAdd(size_t left, size_t right)
{
    if (right > std::numeric_limits<size_t>::max() - left)
        return std::numeric_limits<size_t>::max();
    return left + right;
}

static size_t saturatingMultiply(size_t left, size_t right)
{
    if (left && right > std::numeric_limits<size_t>::max() / left)
        return std::numeric_limits<size_t>::max();
    return left * right;
}

static size_t stringMemoryCost(const String& value)
{
    auto* impl = value.impl();
    if (!impl)
        return 0;
    return impl->costDuringGC();
}

WTF::RefPtr<BlobBytes> BlobBytes::create(WTF::Vector<uint8_t>&& bytes)
{
    BlobBytes* storage = nullptr;
    if (!WTF::tryFastMalloc(sizeof(BlobBytes)).getValue(storage))
        return nullptr;
    storage = new (NotNull, storage) BlobBytes(WTF::move(bytes));
    return adoptRef(*storage);
}

std::span<const uint8_t> BlobBytes::span() const LIFETIME_BOUND { return m_bytes.span(); }

size_t BlobBytes::objectURLMemoryCost() const
{
    if (m_bytes.capacity() > std::numeric_limits<size_t>::max() - sizeof(BlobBytes))
        return std::numeric_limits<size_t>::max();
    return sizeof(BlobBytes) + m_bytes.capacity();
}

BlobBytes::BlobBytes(WTF::Vector<uint8_t>&& bytes)
    : m_bytes(WTF::move(bytes))
{
}

BlobSegment::BlobSegment(WTF::Ref<BlobBytes>&& storage, size_t offset, size_t size)
    : storage(WTF::move(storage))
    , offset(offset)
    , size(size)
{
}

BlobSegment::BlobSegment(const BlobSegment& other)
    : storage(other.storage.copyRef())
    , offset(other.offset)
    , size(other.size)
{
}

BlobSegment& BlobSegment::operator=(const BlobSegment& other)
{
    if (this == &other)
        return *this;
    storage = other.storage.copyRef();
    offset = other.offset;
    size = other.size;
    return *this;
}

static bool appendUniqueBlobObjectURLByteStores(
    std::span<const BlobSegment> segments, WTF::Vector<BlobObjectURLBackingStore>& out)
{
    for (auto& segment : segments) {
        auto* storage = segment.storage.ptr();
        if (!out.tryAppend(BlobObjectURLBackingStore { storage, storage->objectURLMemoryCost() }))
            return false;
    }

    std::sort(
        out.begin(), out.end(), [](auto& left, auto& right) { return std::less<const void*> {}(left.key, right.key); });

    size_t write_index = 0;
    for (size_t read_index = 0; read_index < out.size(); ++read_index) {
        if (write_index && out[write_index - 1].key == out[read_index].key)
            continue;
        if (write_index != read_index)
            out[write_index] = out[read_index];
        write_index++;
    }
    out.shrink(write_index);
    return true;
}

WTF::RefPtr<BlobStorage> BlobStorage::create(WTF::Vector<BlobSegment>&& segments, size_t size)
{
    WTF::Vector<BlobObjectURLBackingStore> object_url_byte_stores;
    if (!appendUniqueBlobObjectURLByteStores(segments.span(), object_url_byte_stores))
        return nullptr;

    size_t object_url_metadata_cost = saturatingAdd(sizeof(BlobStorage),
        saturatingAdd(saturatingMultiply(segments.capacity(), sizeof(BlobSegment)),
            saturatingMultiply(object_url_byte_stores.capacity(), sizeof(BlobObjectURLBackingStore))));
    size_t memory_cost = object_url_metadata_cost;
    for (auto& byte_store : object_url_byte_stores)
        memory_cost = saturatingAdd(memory_cost, byte_store.bytes);

    BlobStorage* storage = nullptr;
    if (!WTF::tryFastMalloc(sizeof(BlobStorage)).getValue(storage))
        return nullptr;
    storage = new (NotNull, storage) BlobStorage(
        WTF::move(segments), WTF::move(object_url_byte_stores), size, object_url_metadata_cost, memory_cost);
    return adoptRef(*storage);
}

WTF::RefPtr<BlobStorage> BlobStorage::create(WTF::Vector<uint8_t>&& bytes)
{
    const size_t size = bytes.size();
    WTF::Vector<BlobSegment> segments;
    if (size) {
        auto bytes_storage = BlobBytes::create(WTF::move(bytes));
        if (!bytes_storage)
            return nullptr;
        if (!segments.tryAppend(BlobSegment(bytes_storage.releaseNonNull(), 0, size)))
            return nullptr;
    }
    return create(WTF::move(segments), size);
}

bool BlobStorage::appendTo(WTF::Vector<uint8_t>& out, size_t offset, size_t size) const
{
    if (!size)
        return true;
    if (offset > m_size || size > m_size - offset)
        return false;

    size_t relative_offset = offset;
    size_t remaining = size;
    for (const auto& segment : m_segments) {
        if (relative_offset >= segment.size) {
            relative_offset -= segment.size;
            continue;
        }

        const size_t segment_available = segment.size - relative_offset;
        const size_t chunk_size = std::min(remaining, segment_available);
        auto chunk = segment.storage->span().subspan(segment.offset + relative_offset, chunk_size);
        if (!out.tryAppend(chunk))
            return false;

        remaining -= chunk_size;
        if (!remaining)
            return true;
        relative_offset = 0;
    }
    return false;
}

bool BlobStorage::appendSegmentsTo(WTF::Vector<BlobSegment>& out, size_t offset, size_t size, size_t max_segments) const
{
    if (!size)
        return true;
    if (offset > m_size || size > m_size - offset)
        return false;

    size_t relative_offset = offset;
    size_t remaining = size;
    for (const auto& segment : m_segments) {
        if (relative_offset >= segment.size) {
            relative_offset -= segment.size;
            continue;
        }

        if (max_segments && out.size() >= max_segments)
            return false;
        const size_t segment_available = segment.size - relative_offset;
        const size_t chunk_size = std::min(remaining, segment_available);
        if (!out.tryAppend(BlobSegment(segment.storage.copyRef(), segment.offset + relative_offset, chunk_size)))
            return false;

        remaining -= chunk_size;
        if (!remaining)
            return true;
        relative_offset = 0;
    }
    return false;
}

bool BlobStorage::appendObjectURLBackingStores(WTF::Vector<BlobObjectURLBackingStore>& out) const
{
    if (!out.tryAppend(BlobObjectURLBackingStore { this, m_object_url_metadata_cost }))
        return false;
    for (auto& byte_store : m_object_url_byte_stores) {
        if (!out.tryAppend(byte_store))
            return false;
    }
    return true;
}

void BlobStorage::copyTo(std::span<uint8_t> destination, size_t offset, size_t size) const
{
    ASSERT(destination.size() >= size);
    ASSERT(offset <= m_size);
    ASSERT(size <= m_size - offset);
    if (!size)
        return;

    size_t relative_offset = offset;
    size_t remaining = size;
    size_t destination_offset = 0;
    for (const auto& segment : m_segments) {
        if (relative_offset >= segment.size) {
            relative_offset -= segment.size;
            continue;
        }

        const size_t segment_available = segment.size - relative_offset;
        const size_t chunk_size = std::min(remaining, segment_available);
        auto chunk = segment.storage->span().subspan(segment.offset + relative_offset, chunk_size);
        std::memcpy(destination.data() + destination_offset, chunk.data(), chunk_size);

        destination_offset += chunk_size;
        remaining -= chunk_size;
        if (!remaining)
            return;
        relative_offset = 0;
    }
    ASSERT_NOT_REACHED();
}

BlobStorage::BlobStorage(WTF::Vector<BlobSegment>&& segments,
    WTF::Vector<BlobObjectURLBackingStore>&& object_url_byte_stores, size_t size, size_t object_url_metadata_cost,
    size_t memory_cost)
    : m_segments(WTF::move(segments))
    , m_object_url_byte_stores(WTF::move(object_url_byte_stores))
    , m_size(size)
    , m_object_url_metadata_cost(object_url_metadata_cost)
    , m_memory_cost(memory_cost)
{
}

size_t BlobStorage::memoryCost() const { return m_memory_cost; }

namespace {

    // A view whose BlobBytes total at least this many times its own length is copied instead of shared, so a small
    // slice or part of a large Blob does not keep the large allocation alive.
    constexpr size_t BlobSegmentCompactionMinRetainedRatio = 8;

    static bool shouldCompactBlobSegments(std::span<const BlobSegment> segments, size_t byte_size)
    {
        if (!byte_size)
            return false;

        size_t retained_size = 0;
        for (const auto& segment : segments) {
            const size_t storage_size = segment.storage->size();
            if (storage_size > std::numeric_limits<size_t>::max() - retained_size)
                return true;
            retained_size += storage_size;
        }
        return retained_size / byte_size >= BlobSegmentCompactionMinRetainedRatio;
    }

    static bool appendBlobSegmentBytes(std::span<const BlobSegment> segments, WTF::Vector<uint8_t>& out)
    {
        for (const auto& segment : segments) {
            auto bytes = segment.storage->span().subspan(segment.offset, segment.size);
            if (!out.tryAppend(bytes))
                return false;
        }
        return true;
    }

} // namespace

JSC::Structure* JSColloBlob::createStructure(JSC::VM& vm, JSC::JSGlobalObject* global_object, JSValue prototype)
{
    return JSC::Structure::create(vm, global_object, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
}

JSColloBlob* JSColloBlob::create(
    JSC::VM& vm, JSC::Structure* structure, WTF::Ref<BlobStorage>&& storage, size_t offset, size_t size, String type)
{
    ASSERT(offset <= storage->size());
    ASSERT(size <= storage->size() - offset);
    auto* object = new (NotNull, JSC::allocateCell<JSColloBlob>(vm))
        JSColloBlob(vm, structure, WTF::move(storage), offset, size, WTF::move(type));
    object->finishCreation(vm);
    return object;
}

JSColloBlob* JSColloBlob::create(JSC::VM& vm, JSC::Structure* structure, WTF::Vector<uint8_t>&& bytes, String type)
{
    const size_t size = bytes.size();
    auto storage = BlobStorage::create(WTF::move(bytes));
    if (!storage)
        return nullptr;
    return create(vm, structure, storage.releaseNonNull(), 0, size, WTF::move(type));
}

JSColloBlob* JSColloBlob::create(
    JSC::VM& vm, JSC::Structure* structure, WTF::Vector<BlobSegment>&& segments, size_t size, String type)
{
    auto storage = BlobStorage::create(WTF::move(segments), size);
    if (!storage)
        return nullptr;
    return create(vm, structure, storage.releaseNonNull(), 0, size, WTF::move(type));
}

void JSColloBlob::destroy(JSC::JSCell* cell) { static_cast<JSColloBlob*>(cell)->~JSColloBlob(); }

size_t JSColloBlob::estimatedSize(JSC::JSCell* cell, JSC::VM& vm)
{
    auto* this_object = static_cast<JSColloBlob*>(cell);
    return saturatingAdd(Base::estimatedSize(cell, vm), this_object->memoryCost());
}

size_t JSColloBlob::memoryCost() const
{
    size_t cost = stringMemoryCost(m_type);
    // Heap snapshot builders read this through estimatedSize(). It charges the whole storage because nothing yields
    // one cell's share: the storage's reference count also counts stream sources and fetch bodies, and its BlobBytes
    // may be shared with other storages.
    cost = saturatingAdd(cost, m_storage->memoryCost());
    return cost;
}

bool JSColloBlob::appendBytes(WTF::Vector<uint8_t>& out) const { return m_storage->appendTo(out, m_offset, m_size); }

void JSColloBlob::copyBytesTo(std::span<uint8_t> destination) const
{
    ASSERT(destination.size() >= m_size);
    m_storage->copyTo(destination, m_offset, m_size);
}

bool JSColloBlob::appendStorageSegments(WTF::Vector<BlobSegment>& out) const
{
    return m_storage->appendSegmentsTo(out, m_offset, m_size);
}

bool JSColloBlob::appendObjectURLBackingStores(WTF::Vector<BlobObjectURLBackingStore>& out) const
{
    return m_storage->appendObjectURLBackingStores(out);
}

JSColloBlob* JSColloBlob::slice(JSC::VM& vm, JSC::Structure* structure, size_t start, size_t length, String type)
{
    WTF::Vector<BlobSegment> segments;
    if (!m_storage->appendSegmentsTo(segments, m_offset + start, length))
        return nullptr;

    if (shouldCompactBlobSegments(segments.span(), length)) {
        WTF::Vector<uint8_t> bytes;
        if (!appendBlobSegmentBytes(segments.span(), bytes))
            return nullptr;
        return create(vm, structure, WTF::move(bytes), WTF::move(type));
    }

    return create(vm, structure, WTF::move(segments), length, WTF::move(type));
}

JSColloBlob::JSColloBlob(
    JSC::VM& vm, JSC::Structure* structure, WTF::Ref<BlobStorage>&& storage, size_t offset, size_t size, String type)
    : Base(vm, structure)
    , m_storage(WTF::move(storage))
    , m_offset(offset)
    , m_size(size)
    , m_type(WTF::move(type))
{
}

JSColloBlob::~JSColloBlob() = default;

void JSColloBlob::finishCreation(JSC::VM& vm)
{
    Base::finishCreation(vm);
    ASSERT(inherits(info()));
    // Extra memory is what lets Blob allocations trigger collections: at the pinned engine only heap snapshots read
    // estimatedSize(). The storage counts only when this cell wins BlobStorage::tryClaimExtraMemoryReport. A slice
    // has its own storage, so the BlobBytes it shares count again through it.
    size_t cost = stringMemoryCost(m_type);
    if (m_storage->tryClaimExtraMemoryReport(vm.heap.objectSpace().markingVersion()))
        cost = saturatingAdd(cost, m_storage->memoryCost());
    vm.heap.reportExtraMemoryAllocated(this, cost);
}

template <typename Visitor> void JSColloBlob::visitChildrenImpl(JSC::JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloBlob*>(cell);
    ASSERT_GC_OBJECT_INHERITS(this_object, info());
    Base::visitChildren(this_object, visitor);
    // A full collection resets the heap's extra memory count, so every live cell reports its cost again here, or the
    // accounting would decay after the first full collection. The storage counts only when this cell wins
    // BlobStorage::tryClaimExtraMemoryReport.
    size_t cost = stringMemoryCost(this_object->m_type);
    if (this_object->m_storage->tryClaimExtraMemoryReport(visitor.heap()->objectSpace().markingVersion()))
        cost = saturatingAdd(cost, this_object->m_storage->memoryCost());
    visitor.reportExtraMemoryVisited(cost);
}

DEFINE_VISIT_CHILDREN(JSColloBlob);

const JSC::ClassInfo JSColloBlob::s_info
    = { "Blob"_s, &JSC::JSDestructibleObject::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloBlob) };

JSC::Structure* JSColloFile::createStructure(JSC::VM& vm, JSC::JSGlobalObject* global_object, JSValue prototype)
{
    return JSC::Structure::create(vm, global_object, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
}

JSColloFile* JSColloFile::create(JSC::VM& vm, JSC::Structure* structure, WTF::Vector<uint8_t>&& bytes, String type,
    String name, double last_modified)
{
    size_t size = bytes.size();
    auto storage = BlobStorage::create(WTF::move(bytes));
    if (!storage)
        return nullptr;
    auto* object = new (NotNull, JSC::allocateCell<JSColloFile>(vm))
        JSColloFile(vm, structure, storage.releaseNonNull(), 0, size, WTF::move(type), WTF::move(name), last_modified);
    object->finishCreation(vm);
    return object;
}

JSColloFile* JSColloFile::create(JSC::VM& vm, JSC::Structure* structure, WTF::Vector<BlobSegment>&& segments,
    size_t size, String type, String name, double last_modified)
{
    auto storage = BlobStorage::create(WTF::move(segments), size);
    if (!storage)
        return nullptr;
    auto* object = new (NotNull, JSC::allocateCell<JSColloFile>(vm))
        JSColloFile(vm, structure, storage.releaseNonNull(), 0, size, WTF::move(type), WTF::move(name), last_modified);
    object->finishCreation(vm);
    return object;
}

JSColloFile* JSColloFile::createFromBlob(
    JSC::VM& vm, JSC::Structure* structure, JSColloBlob& blob, String name, double last_modified)
{
    auto* object = new (NotNull, JSC::allocateCell<JSColloFile>(vm)) JSColloFile(vm, structure,
        blob.m_storage.copyRef(), blob.m_offset, blob.m_size, String(blob.type()), WTF::move(name), last_modified);
    object->finishCreation(vm);
    return object;
}

void JSColloFile::destroy(JSC::JSCell* cell) { static_cast<JSColloFile*>(cell)->~JSColloFile(); }

size_t JSColloFile::estimatedSize(JSC::JSCell* cell, JSC::VM& vm)
{
    auto* this_object = static_cast<JSColloFile*>(cell);
    return saturatingAdd(JSColloBlob::estimatedSize(cell, vm), stringMemoryCost(this_object->m_name));
}

JSColloFile::JSColloFile(JSC::VM& vm, JSC::Structure* structure, WTF::Ref<BlobStorage>&& storage, size_t offset,
    size_t size, String type, String name, double last_modified)
    : Base(vm, structure, WTF::move(storage), offset, size, WTF::move(type))
    , m_name(WTF::move(name))
    , m_last_modified(last_modified)
{
}

JSColloFile::~JSColloFile() = default;

void JSColloFile::finishCreation(JSC::VM& vm)
{
    // FIXME: Neither this nor visitChildren reports the name as extra memory, though estimatedSize() counts it, so a
    // long name kept alive only by this cell never helps trigger a collection.
    Base::finishCreation(vm);
    ASSERT(inherits(info()));
}

const JSC::ClassInfo JSColloFile::s_info
    = { "File"_s, &JSColloBlob::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloFile) };

namespace {

    enum class BlobEnding {
        Transparent,
        Native,
    };

    struct BlobOptions {
        String type;
        BlobEnding ending { BlobEnding::Transparent };
        std::optional<double> last_modified;
    };

    struct BlobPartData {
        WTF::Vector<uint8_t> bytes;
        WTF::Vector<BlobSegment> segments;
        String string;
        size_t byte_size { 0 };
        bool is_string { false };
    };

    static JSColloBlob* requireBlob(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
    {
        if (auto* blob = dynamicDowncast<JSColloBlob>(value))
            return blob;
        JSC::throwVMTypeError(global_object, scope, "Blob method called on incompatible receiver"_s);
        return nullptr;
    }

    static JSC::Structure* blobStructureForNewTarget(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::CallFrame* call_frame)
    {
        auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
        auto* new_target = call_frame->newTarget().getObject();
        auto* constructor = call_frame->jsCallee();
        if (!new_target || new_target == constructor)
            return collo_global->blobStructure();

        auto* structure
            = JSC::InternalFunction::createSubclassStructure(global_object, new_target, collo_global->blobStructure());
        RETURN_IF_EXCEPTION(scope, nullptr);
        return structure;
    }

    static JSC::Structure* fileStructureForNewTarget(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::CallFrame* call_frame)
    {
        auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
        auto* new_target = call_frame->newTarget().getObject();
        auto* constructor = call_frame->jsCallee();
        if (!new_target || new_target == constructor)
            return collo_global->fileStructure();

        auto* structure
            = JSC::InternalFunction::createSubclassStructure(global_object, new_target, collo_global->fileStructure());
        RETURN_IF_EXCEPTION(scope, nullptr);
        return structure;
    }

    // File API, the Blob constructor's type option: a type with any character outside U+0020 to U+007E becomes the
    // empty string, and any other type is lowercased.
    static String normalizeBlobType(String input)
    {
        if (input.isEmpty())
            return emptyString();

        WTF::StringBuilder builder;
        builder.reserveCapacity(input.length());
        for (unsigned index = 0; index < input.length(); index++) {
            char16_t character = input[index];
            if (character < 0x20 || character > 0x7e)
                return emptyString();
            builder.append(static_cast<Latin1Character>(WTF::toASCIILower(static_cast<char>(character))));
        }
        return builder.toString();
    }

} // namespace

namespace {

    static JSValue getPropertyIfPresent(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSObject* object, WTF::ASCIILiteral name)
    {
        auto value = object->getIfPropertyExists(global_object, JSC::Identifier::fromString(global_object->vm(), name));
        RETURN_IF_EXCEPTION(scope, {});
        return value;
    }

    // WebIDL's ConvertToInt for long long without [EnforceRange] or [Clamp]: NaN and infinities become 0, and finite
    // values are truncated and wrapped modulo 2^64.
    static int64_t toWebIDLLongLong(double number)
    {
        if (!std::isfinite(number) || number == 0)
            return 0;

        constexpr long double two64 = 18446744073709551616.0L;
        constexpr long double two63 = 9223372036854775808.0L;
        long double modulo = std::fmod(std::trunc(std::fabs(static_cast<long double>(number))), two64);
        if (number < 0 && modulo != 0)
            modulo = two64 - modulo;
        if (modulo >= two63) {
            long double signed_magnitude = two64 - modulo;
            if (signed_magnitude >= two63)
                return std::numeric_limits<int64_t>::min();
            return -static_cast<int64_t>(signed_magnitude);
        }
        return static_cast<int64_t>(modulo);
    }

    static BlobOptions blobOptionsFromValue(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue options, bool include_file_members = false)
    {
        BlobOptions result;
        if (options.isUndefinedOrNull() || !options.isObject()) {
            if (!options.isUndefinedOrNull())
                JSC::throwVMTypeError(global_object, scope, "Blob options must be an object"_s);
            return result;
        }

        auto endings = getPropertyIfPresent(global_object, scope, options.getObject(), "endings"_s);
        RETURN_IF_EXCEPTION(scope, {});
        if (!endings.isEmpty() && !endings.isUndefined()) {
            auto string = valueToWebApiString(global_object, scope, endings);
            RETURN_IF_EXCEPTION(scope, {});
            if (string == "transparent"_s)
                result.ending = BlobEnding::Transparent;
            else if (string == "native"_s)
                result.ending = BlobEnding::Native;
            else {
                JSC::throwVMTypeError(global_object, scope, "Blob endings option must be 'transparent' or 'native'"_s);
                return {};
            }
        }

        if (include_file_members) {
            auto last_modified = getPropertyIfPresent(global_object, scope, options.getObject(), "lastModified"_s);
            RETURN_IF_EXCEPTION(scope, {});
            if (!last_modified.isEmpty() && !last_modified.isUndefined()) {
                result.last_modified = static_cast<double>(toWebIDLLongLong(last_modified.toNumber(global_object)));
                RETURN_IF_EXCEPTION(scope, {});
            }
        }

        auto type = getPropertyIfPresent(global_object, scope, options.getObject(), "type"_s);
        RETURN_IF_EXCEPTION(scope, {});
        if (!type.isEmpty() && !type.isUndefined()) {
            auto string = valueToWebApiString(global_object, scope, type);
            RETURN_IF_EXCEPTION(scope, {});
            result.type = normalizeBlobType(WTF::move(string));
        }

        return result;
    }

    static bool appendBytes(WTF::Vector<uint8_t>& output, std::span<const uint8_t> bytes)
    {
        if (bytes.empty())
            return true;
        return output.tryAppend(bytes);
    }

    static bool copyBytes(WTF::Vector<uint8_t>& output, std::span<const uint8_t> bytes)
    {
        output.clear();
        return appendBytes(output, bytes);
    }

    static bool appendStringBytes(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, WTF::Vector<uint8_t>& output, const String& string)
    {
        auto result = string.tryGetUTF8([&](std::span<const char8_t> utf8) -> bool {
            return appendBytes(
                output, std::span<const uint8_t> { reinterpret_cast<const uint8_t*>(utf8.data()), utf8.size() });
        });
        if (!result || !result.value()) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return false;
        }
        return true;
    }

    // Converts line endings to native, which is \n on Linux: \r\n and a lone \r both become \n. A \r emits its \n at
    // once, and `pending_cr` only drops a \n that immediately follows it. The flag carries over to the next string
    // part, so a \r ending one part and a \n starting the next become a single \n.
    // FIXME: File API's "process blob parts" converts each string part on its own, so
    // new Blob(["\r", "\n"], { endings: "native" }) should hold two newlines.
    static String normalizeNativeLineEndings(const String& input, bool& pending_cr)
    {
        WTF::StringBuilder builder;
        builder.reserveCapacity(input.length());
        for (unsigned index = 0; index < input.length(); index++) {
            char16_t character = input[index];
            if (character == '\n') {
                if (pending_cr) {
                    pending_cr = false;
                    continue;
                }
                builder.append('\n');
                continue;
            }
            pending_cr = false;
            if (character == '\r') {
                builder.append('\n');
                pending_cr = true;
                continue;
            }
            builder.append(character);
        }
        return builder.toString();
    }

    static bool appendBlobString(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        WTF::Vector<uint8_t>& output, String string, BlobEnding ending, bool& pending_cr)
    {
        if (ending == BlobEnding::Native)
            string = normalizeNativeLineEndings(string, pending_cr);
        return appendStringBytes(global_object, scope, output, string);
    }

    static bool collectBlobPart(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, WTF::Vector<BlobPartData>& output, JSValue value)
    {
        BlobPartData part;

        if (auto* blob = dynamicDowncast<JSColloBlob>(value)) {
            part.byte_size = blob->size();
            if (!blob->appendStorageSegments(part.segments)) {
                JSC::throwOutOfMemoryError(global_object, scope);
                return false;
            }
            return output.tryAppend(WTF::move(part));
        }

        if (auto* view = dynamicDowncast<JSC::JSArrayBufferView>(value)) {
            if (!validateArrayBufferViewForCopy(
                    global_object, scope, view, "Blob part ArrayBufferView is detached or out of bounds"_s))
                return false;
            if (!copyBytes(part.bytes, arrayBufferViewBytes(view))) {
                JSC::throwOutOfMemoryError(global_object, scope);
                return false;
            }
            part.byte_size = part.bytes.size();
            return output.tryAppend(WTF::move(part));
        }

        if (auto* array_buffer = dynamicDowncast<JSC::JSArrayBuffer>(value)) {
            if (!validateArrayBufferForCopy(
                    global_object, scope, array_buffer, "Blob part must be a fixed-length attached ArrayBuffer"_s))
                return false;
            if (!copyBytes(part.bytes, arrayBufferBytes(array_buffer))) {
                JSC::throwOutOfMemoryError(global_object, scope);
                return false;
            }
            part.byte_size = part.bytes.size();
            return output.tryAppend(WTF::move(part));
        }

        part.string = valueToWebApiString(global_object, scope, value);
        RETURN_IF_EXCEPTION(scope, false);
        part.is_string = true;
        return output.tryAppend(WTF::move(part));
    }

    static bool collectBlobArrayParts(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSArray& array,
        WTF::Vector<BlobPartData>& output)
    {
        // Follows Bun instead of WebIDL's sequence conversion: an Array, or a subclass of Array, is read by index up to
        // the length it had on entry, and its Symbol.iterator is never called. Each read is an ordinary [[Get]], so a
        // hole falls through to the prototype chain. Undefined and null elements, from holes or not, are skipped
        // instead of becoming the strings "undefined" and "null". Other iterables use the iterator protocol, through
        // forEachInIterable in collectBlobParts.
        const unsigned length = array.length();
        for (unsigned index = 0; index < length; index++) {
            JSValue part = array.get(global_object, index);
            RETURN_IF_EXCEPTION(scope, false);
            if (part.isUndefinedOrNull())
                continue;
            if (!collectBlobPart(global_object, scope, output, part) && !scope.exception()) {
                JSC::throwOutOfMemoryError(global_object, scope);
                return false;
            }
            RETURN_IF_EXCEPTION(scope, false);
        }
        return true;
    }

    static bool collectBlobParts(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue parts_value,
        WTF::Vector<BlobPartData>& output)
    {
        if (parts_value.isUndefined())
            return true;
        if (!parts_value.isObject()) {
            JSC::throwVMTypeError(global_object, scope, "Blob parts must be an object sequence"_s);
            return false;
        }

        if (auto* array = dynamicDowncast<JSC::JSArray>(parts_value))
            return collectBlobArrayParts(global_object, scope, *array, output);

        JSC::forEachInIterable(global_object, parts_value, [&](JSC::VM&, JSC::JSGlobalObject*, JSValue part) {
            if (scope.exception())
                return;
            if (!collectBlobPart(global_object, scope, output, part) && !scope.exception())
                JSC::throwOutOfMemoryError(global_object, scope);
        });
        RETURN_IF_EXCEPTION(scope, false);
        return true;
    }

    static bool appendOwnedBlobSegment(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        WTF::Vector<BlobSegment>& output, WTF::Vector<uint8_t>&& bytes, size_t& total_size)
    {
        const size_t size = bytes.size();
        if (!size)
            return true;
        if (total_size > std::numeric_limits<size_t>::max() - size) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return false;
        }
        auto storage = BlobBytes::create(WTF::move(bytes));
        if (!storage || !output.tryAppend(BlobSegment(storage.releaseNonNull(), 0, size))) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return false;
        }
        total_size += size;
        return true;
    }

    static bool appendSharedBlobSegments(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        WTF::Vector<BlobSegment>& output, BlobPartData& part, size_t& total_size)
    {
        if (part.byte_size > std::numeric_limits<size_t>::max() - total_size) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return false;
        }
        for (const auto& segment : part.segments) {
            if (!output.tryAppend(segment)) {
                JSC::throwOutOfMemoryError(global_object, scope);
                return false;
            }
        }
        total_size += part.byte_size;
        return true;
    }

    static bool flushPendingBlobBytes(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        WTF::Vector<BlobSegment>& output, WTF::Vector<uint8_t>& pending, size_t& total_size)
    {
        if (pending.isEmpty())
            return true;
        WTF::Vector<uint8_t> bytes = WTF::move(pending);
        pending.clear();
        return appendOwnedBlobSegment(global_object, scope, output, WTF::move(bytes), total_size);
    }

    static bool materializeBlobParts(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        WTF::Vector<BlobPartData>& parts, BlobEnding ending, WTF::Vector<BlobSegment>& output, size_t& total_size)
    {
        total_size = 0;
        WTF::Vector<uint8_t> pending_bytes;
        // Carries a trailing \r from one string part to the next (normalizeNativeLineEndings). A Blob or BufferSource
        // part between them resets it.
        bool pending_cr = false;

        for (auto& part : parts) {
            bool ok = true;
            if (part.is_string) {
                ok = appendBlobString(global_object, scope, pending_bytes, part.string, ending, pending_cr);
            } else if (!part.segments.isEmpty()) {
                pending_cr = false;
                ok = flushPendingBlobBytes(global_object, scope, output, pending_bytes, total_size);
                if (ok && shouldCompactBlobSegments(part.segments.span(), part.byte_size)) {
                    WTF::Vector<uint8_t> compacted;
                    if (!appendBlobSegmentBytes(part.segments.span(), compacted)) {
                        JSC::throwOutOfMemoryError(global_object, scope);
                        ok = false;
                    } else
                        ok = appendOwnedBlobSegment(global_object, scope, output, WTF::move(compacted), total_size);
                } else if (ok)
                    ok = appendSharedBlobSegments(global_object, scope, output, part, total_size);
            } else {
                pending_cr = false;
                ok = flushPendingBlobBytes(global_object, scope, output, pending_bytes, total_size)
                    && appendOwnedBlobSegment(global_object, scope, output, WTF::move(part.bytes), total_size);
            }
            RETURN_IF_EXCEPTION(scope, false);
            if (!ok) {
                JSC::throwOutOfMemoryError(global_object, scope);
                return false;
            }
        }
        return flushPendingBlobBytes(global_object, scope, output, pending_bytes, total_size);
    }

    static double toIntegerOrInfinity(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
    {
        double number = value.toNumber(global_object);
        RETURN_IF_EXCEPTION(scope, 0);
        if (std::isnan(number) || number == 0)
            return 0;
        if (!std::isfinite(number))
            return number;
        return std::trunc(number);
    }

    static size_t relativeSliceOffset(double position, size_t size)
    {
        if (position == -std::numeric_limits<double>::infinity())
            return 0;
        if (position == std::numeric_limits<double>::infinity())
            return size;
        if (position < 0) {
            double relative = static_cast<double>(size) + position;
            if (relative <= 0)
                return 0;
            return static_cast<size_t>(std::min(relative, static_cast<double>(size)));
        }
        return static_cast<size_t>(std::min(position, static_cast<double>(size)));
    }

    static JSC::JSArrayBuffer* createArrayBufferCopyNoThrow(JSC::JSGlobalObject* global_object, JSColloBlob& blob)
    {
        auto buffer = JSC::ArrayBuffer::tryCreateUninitialized(blob.size(), 1);
        if (!buffer)
            return nullptr;
        if (blob.size())
            blob.copyBytesTo(std::span<uint8_t> { static_cast<uint8_t*>(buffer->data()), blob.size() });
        return JSC::JSArrayBuffer::create(global_object->vm(),
            global_object->arrayBufferStructure(JSC::ArrayBufferSharingMode::Default), WTF::move(buffer));
    }

    static JSC::JSArrayBuffer* createArrayBufferCopy(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSColloBlob& blob)
    {
        auto* buffer = createArrayBufferCopyNoThrow(global_object, blob);
        if (!buffer)
            JSC::throwOutOfMemoryError(global_object, scope);
        return buffer;
    }

    static JSC::JSUint8Array* createUint8ArrayCopyNoThrow(
        JSC::JSGlobalObject* global_object, const BlobStorage& storage, size_t offset, size_t size)
    {
        auto buffer = JSC::ArrayBuffer::tryCreateUninitialized(size, 1);
        if (!buffer)
            return nullptr;
        if (size)
            storage.copyTo(std::span<uint8_t> { static_cast<uint8_t*>(buffer->data()), size }, offset, size);

        auto* structure = global_object->typedArrayStructureWithTypedArrayType<JSC::TypeUint8>();
        return JSC::JSUint8Array::create(
            global_object, structure, WTF::move(buffer), 0, std::optional<size_t> { size });
    }

    static JSC::JSUint8Array* createUint8ArrayCopy(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        const BlobStorage& storage, size_t offset, size_t size)
    {
        auto* array = createUint8ArrayCopyNoThrow(global_object, storage, offset, size);
        if (!array)
            JSC::throwOutOfMemoryError(global_object, scope);
        return array;
    }

    static JSC::JSUint8Array* createUint8ArrayCopy(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSColloBlob& blob)
    {
        auto storage = blob.storageRef();
        return createUint8ArrayCopy(global_object, scope, storage.get(), blob.byteOffset(), blob.size());
    }

    static bool copyBlobToVector(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSColloBlob& blob, WTF::Vector<uint8_t>& out)
    {
        if (blob.appendBytes(out))
            return true;
        JSC::throwOutOfMemoryError(global_object, scope);
        return false;
    }

    class BlobStreamSource final : public ReadableStreamNativeSource {
    public:
        static WTF::RefPtr<BlobStreamSource> create(JSColloBlob& blob)
        {
            void* storage = nullptr;
            if (!WTF::tryFastMalloc(sizeof(BlobStreamSource)).getValue(storage))
                return nullptr;
            auto* source = new (NotNull, storage) BlobStreamSource(blob.storageRef(), blob.byteOffset(), blob.size());
            // The source keeps the storage alive and may outlive the Blob. It reports the storage once, against the
            // Blob cell, when it wins BlobStorage::tryClaimExtraMemoryReport, and never again: once no cell shares the
            // storage, the bytes the stream retains stop counting toward GC pacing. The sources tee() creates over
            // the same storage report nothing.
            auto& vm = blob.vm();
            if (source->m_storage->tryClaimExtraMemoryReport(vm.heap.objectSpace().markingVersion()))
                vm.heap.reportExtraMemoryAllocated(&blob, source->m_storage->memoryCost());
            return adoptRef(*source);
        }

        EncodedJSValue pull(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope) override
        {
            if (!m_storage || m_position >= m_size) {
                m_storage = nullptr;
                return resolvedPromise(
                    global_object, createReadableStreamReadResult(global_object, JSC::jsUndefined(), true));
            }

            size_t remaining = m_size - m_position;
            size_t chunk_size = std::min(remaining, default_chunk_size);
            auto* value = createUint8ArrayCopy(global_object, scope, *m_storage, m_offset + m_position, chunk_size);
            RETURN_IF_EXCEPTION(scope, {});
            if (!value)
                return {};
            m_position += chunk_size;
            if (m_position >= m_size)
                m_storage = nullptr;
            return resolvedPromise(global_object, createReadableStreamReadResult(global_object, value, false));
        }

        EncodedJSValue cancel(JSC::JSGlobalObject* global_object, JSC::ThrowScope&, JSValue) override
        {
            m_position = m_size;
            m_storage = nullptr;
            return resolvedPromise(global_object, JSC::jsUndefined());
        }

        bool tee(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
            WTF::RefPtr<ReadableStreamNativeSource>& out_first,
            WTF::RefPtr<ReadableStreamNativeSource>& out_second) override
        {
            if (!m_storage || m_position >= m_size) {
                out_first = createReadableStreamNativeSourceFromBytes({});
                out_second = createReadableStreamNativeSourceFromBytes({});
                if (out_first && out_second)
                    return true;
                JSC::throwOutOfMemoryError(global_object, scope);
                return false;
            }

            size_t remaining = m_size - m_position;
            size_t remaining_offset = m_offset + m_position;
            auto storage = WTF::Ref<BlobStorage> { *m_storage };
            auto first = createFromStorage(storage.copyRef(), remaining_offset, remaining);
            if (!first) {
                JSC::throwOutOfMemoryError(global_object, scope);
                return false;
            }
            auto second = createFromStorage(storage.copyRef(), remaining_offset, remaining);
            if (!second) {
                JSC::throwOutOfMemoryError(global_object, scope);
                return false;
            }
            out_first = first.releaseNonNull();
            out_second = second.releaseNonNull();
            m_position = m_size;
            m_storage = nullptr;
            return true;
        }

        bool appendRemainingBytes(WTF::Vector<uint8_t>& out) override
        {
            if (!m_storage || m_position >= m_size) {
                m_position = m_size;
                m_storage = nullptr;
                return true;
            }
            if (!m_storage->appendTo(out, m_offset + m_position, m_size - m_position))
                return false;
            m_position = m_size;
            m_storage = nullptr;
            return true;
        }

        bool appendRemainingBytes(
            WTF::Vector<uint8_t>& out, size_t max_size, bool& out_exceeds_limit, bool& out_supported) override
        {
            out_exceeds_limit = false;
            out_supported = true;
            if (!m_storage || m_position >= m_size) {
                m_position = m_size;
                m_storage = nullptr;
                return true;
            }
            const size_t remaining = m_size - m_position;
            if (remaining > max_size - std::min(out.size(), max_size)) {
                out_exceeds_limit = true;
                return false;
            }
            if (!m_storage->appendTo(out, m_offset + m_position, remaining))
                return false;
            m_position = m_size;
            m_storage = nullptr;
            return true;
        }

        void release() override { m_storage = nullptr; }

    private:
        static WTF::RefPtr<BlobStreamSource> createFromStorage(
            WTF::Ref<BlobStorage>&& storage, size_t offset, size_t size)
        {
            void* allocation = nullptr;
            if (!WTF::tryFastMalloc(sizeof(BlobStreamSource)).getValue(allocation))
                return nullptr;
            auto* source = new (NotNull, allocation) BlobStreamSource(WTF::move(storage), offset, size);
            return adoptRef(*source);
        }

        BlobStreamSource(WTF::Ref<BlobStorage>&& storage, size_t offset, size_t size)
            : m_storage(WTF::move(storage))
            , m_offset(offset)
            , m_size(size)
        {
        }

        static constexpr size_t default_chunk_size = 64 * 1024;
        WTF::RefPtr<BlobStorage> m_storage;
        size_t m_offset { 0 };
        size_t m_size { 0 };
        size_t m_position { 0 };
    };

    static bool requireArgumentCount(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        JSC::CallFrame* call_frame, unsigned count, WTF::ASCIILiteral message)
    {
        if (call_frame->argumentCount() >= count)
            return true;
        JSC::throwVMTypeError(global_object, scope, message);
        return false;
    }

    JSC_DEFINE_HOST_FUNCTION(blobConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        return JSC::throwVMTypeError(global_object, scope, "Blob constructor requires 'new'"_s);
    }

    JSC_DEFINE_HOST_FUNCTION(
        blobConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);

        WTF::Vector<BlobPartData> parts;
        if (!collectBlobParts(global_object, scope, call_frame->argument(0), parts))
            return {};
        RETURN_IF_EXCEPTION(scope, {});

        auto options = blobOptionsFromValue(global_object, scope, call_frame->argument(1));
        RETURN_IF_EXCEPTION(scope, {});

        WTF::Vector<BlobSegment> segments;
        size_t size = 0;
        if (!materializeBlobParts(global_object, scope, parts, options.ending, segments, size))
            return {};
        RETURN_IF_EXCEPTION(scope, {});

        auto* structure = blobStructureForNewTarget(global_object, scope, call_frame);
        RETURN_IF_EXCEPTION(scope, {});

        auto* blob = JSColloBlob::create(vm, structure, WTF::move(segments), size, WTF::move(options.type));
        if (!blob)
            return JSValue::encode(JSC::throwOutOfMemoryError(global_object, scope));
        return JSValue::encode(blob);
    }

    JSC_DEFINE_HOST_FUNCTION(fileConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        return JSC::throwVMTypeError(global_object, scope, "File constructor requires 'new'"_s);
    }

    JSC_DEFINE_HOST_FUNCTION(
        fileConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);

        if (!requireArgumentCount(global_object, scope, call_frame, 1, "File constructor requires fileBits"_s))
            return {};
        if (!requireArgumentCount(global_object, scope, call_frame, 2, "File constructor requires fileName"_s))
            return {};

        WTF::Vector<BlobPartData> parts;
        if (!collectBlobParts(global_object, scope, call_frame->argument(0), parts))
            return {};
        RETURN_IF_EXCEPTION(scope, {});

        auto name = toWebApiUSVString(valueToWebApiString(global_object, scope, call_frame->argument(1)));
        RETURN_IF_EXCEPTION(scope, {});

        auto options = blobOptionsFromValue(global_object, scope, call_frame->argument(2), true);
        RETURN_IF_EXCEPTION(scope, {});

        WTF::Vector<BlobSegment> segments;
        size_t size = 0;
        if (!materializeBlobParts(global_object, scope, parts, options.ending, segments, size))
            return {};
        RETURN_IF_EXCEPTION(scope, {});

        auto last_modified = options.last_modified.value_or(WTF::WallTime::now().secondsSinceEpoch().milliseconds());
        auto* structure = fileStructureForNewTarget(global_object, scope, call_frame);
        RETURN_IF_EXCEPTION(scope, {});

        auto* file = JSColloFile::create(
            vm, structure, WTF::move(segments), size, WTF::move(options.type), WTF::move(name), last_modified);
        if (!file)
            return JSValue::encode(JSC::throwOutOfMemoryError(global_object, scope));
        return JSValue::encode(file);
    }

    JSC_DEFINE_HOST_FUNCTION(fileGetName, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* file = dynamicDowncast<JSColloFile>(call_frame->thisValue());
        if (!file) {
            JSC::throwVMTypeError(global_object, scope, "File method called on incompatible receiver"_s);
            return {};
        }
        return JSValue::encode(JSC::jsString(vm, file->name()));
    }

    JSC_DEFINE_HOST_FUNCTION(fileGetLastModified, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* file = dynamicDowncast<JSColloFile>(call_frame->thisValue());
        if (!file) {
            JSC::throwVMTypeError(global_object, scope, "File method called on incompatible receiver"_s);
            return {};
        }
        return JSValue::encode(JSC::jsNumber(file->lastModified()));
    }

    JSC_DEFINE_HOST_FUNCTION(blobGetSize, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* blob = requireBlob(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(JSC::jsNumber(blob->size()));
    }

    JSC_DEFINE_HOST_FUNCTION(blobGetType, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* blob = requireBlob(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(JSC::jsString(vm, blob->type()));
    }

    JSC_DEFINE_HOST_FUNCTION(blobSlice, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* blob = requireBlob(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});

        double raw_start = call_frame->argument(0).isUndefined()
            ? 0
            : toIntegerOrInfinity(global_object, scope, call_frame->argument(0));
        RETURN_IF_EXCEPTION(scope, {});
        double raw_end = call_frame->argument(1).isUndefined()
            ? static_cast<double>(blob->size())
            : toIntegerOrInfinity(global_object, scope, call_frame->argument(1));
        RETURN_IF_EXCEPTION(scope, {});

        size_t start = relativeSliceOffset(raw_start, blob->size());
        size_t end = relativeSliceOffset(raw_end, blob->size());
        size_t length = end >= start ? end - start : 0;

        // File API slice(): without contentType the new Blob's type is the empty string, never a null String.
        String type = emptyString();
        if (!call_frame->argument(2).isUndefined()) {
            type = valueToWebApiString(global_object, scope, call_frame->argument(2));
            RETURN_IF_EXCEPTION(scope, {});
            type = normalizeBlobType(WTF::move(type));
        }

        auto* sliced = blob->slice(
            vm, uncheckedDowncast<Collo::GlobalObject>(global_object)->blobStructure(), start, length, WTF::move(type));
        if (!sliced)
            return JSValue::encode(JSC::throwOutOfMemoryError(global_object, scope));
        return JSValue::encode(sliced);
    }

    JSC_DEFINE_HOST_FUNCTION(blobArrayBuffer, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* blob = requireBlob(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});

        auto* array_buffer = createArrayBufferCopyNoThrow(global_object, *blob);
        if (!array_buffer)
            return rejectedPromise(global_object, JSC::createOutOfMemoryError(global_object));
        return resolvedPromise(global_object, JSValue(array_buffer));
    }

    JSC_DEFINE_HOST_FUNCTION(blobBytes, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* blob = requireBlob(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});

        auto* array
            = createUint8ArrayCopyNoThrow(global_object, blob->storageRef().get(), blob->byteOffset(), blob->size());
        if (!array)
            return rejectedPromise(global_object, JSC::createOutOfMemoryError(global_object));
        return resolvedPromise(global_object, JSValue(array));
    }

    JSC_DEFINE_HOST_FUNCTION(blobText, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* blob = requireBlob(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});

        if (blob->size() > WTF::String::MaxLength)
            return rejectedPromise(global_object, JSC::createOutOfMemoryError(global_object));
        WTF::Vector<uint8_t> bytes;
        if (!copyBlobToVector(global_object, scope, *blob, bytes))
            return {};
        RETURN_IF_EXCEPTION(scope, {});
        return resolvedPromise(global_object, JSC::jsString(vm, decodeUtf8Bytes(bytes.span())));
    }

    JSC_DEFINE_HOST_FUNCTION(blobStream, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* blob = requireBlob(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});

        auto source = BlobStreamSource::create(*blob);
        if (!source) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return {};
        }
        auto* stream = createReadableStreamFromNativeSource(global_object, scope, source.releaseNonNull());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(stream);
    }

    JSC_DEFINE_HOST_FUNCTION(blobFormData, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* blob = requireBlob(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});

        // createFormDataFromBodyBytes rejects a body over WebApiMaterializedBodyBytesMax anyway; checking the size
        // first avoids copying such a blob out of its storage.
        if (blob->size() > WebApiMaterializedBodyBytesMax)
            return rejectedPromise(global_object, scope, createFormDataBodyQuotaExceeded(global_object));

        WTF::ASCIILiteral parse_error = "Invalid form data"_s;
        WTF::Vector<uint8_t> bytes;
        if (!copyBlobToVector(global_object, scope, *blob, bytes))
            return {};
        RETURN_IF_EXCEPTION(scope, {});
        auto* form_data
            = createFormDataFromBodyBytes(global_object, scope, bytes.span(), String(blob->type()), &parse_error);
        RETURN_IF_EXCEPTION(scope, {});
        if (!form_data) {
            if (isFormDataQuotaParseError(parse_error))
                return rejectedPromise(global_object, scope,
                    createDOMException(global_object, DOMExceptionCode::QuotaExceededError, String(parse_error)));
            return rejectedTypeError(global_object, scope, parse_error);
        }
        return resolvedPromise(global_object, form_data);
    }

    static JSC::JSFunction* createBlobConstructor(JSC::JSGlobalObject* global_object, JSC::VM& vm)
    {
        auto* constructor = JSC::JSFunction::create(vm, global_object, 0, "Blob"_s, blobConstructorCall,
            JSC::ImplementationVisibility::Public, JSC::NoIntrinsic, blobConstructorConstruct, nullptr);
        RELEASE_ASSERT(constructor);
        return constructor;
    }

    static JSC::JSFunction* createFileConstructor(JSC::JSGlobalObject* global_object, JSC::VM& vm)
    {
        auto* constructor = JSC::JSFunction::create(vm, global_object, 2, "File"_s, fileConstructorCall,
            JSC::ImplementationVisibility::Public, JSC::NoIntrinsic, fileConstructorConstruct, nullptr);
        RELEASE_ASSERT(constructor);
        return constructor;
    }

} // namespace

void installWebApiBlob(Collo::GlobalObject* global_object, JSC::VM& vm)
{
    constexpr unsigned enumerableAccessor = static_cast<unsigned>(JSC::PropertyAttribute::Accessor);
    constexpr unsigned enumerableFunction = static_cast<unsigned>(JSC::PropertyAttribute::None);

    auto* prototype = JSC::constructEmptyObject(global_object, global_object->objectPrototype());
    putWebApiAccessor(global_object, prototype, vm, "size"_s, blobGetSize, nullptr, enumerableAccessor);
    putWebApiAccessor(global_object, prototype, vm, "type"_s, blobGetType, nullptr, enumerableAccessor);
    putWebApiFunction(global_object, prototype, vm, "slice"_s, 0, blobSlice, enumerableFunction);
    putWebApiFunction(global_object, prototype, vm, "arrayBuffer"_s, 0, blobArrayBuffer, enumerableFunction);
    putWebApiFunction(global_object, prototype, vm, "bytes"_s, 0, blobBytes, enumerableFunction);
    putWebApiFunction(global_object, prototype, vm, "text"_s, 0, blobText, enumerableFunction);
    putWebApiFunction(global_object, prototype, vm, "stream"_s, 0, blobStream, enumerableFunction);
    putWebApiFunction(global_object, prototype, vm, "formData"_s, 0, blobFormData, enumerableFunction);
    prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol, JSC::jsString(vm, WTF::makeString("Blob"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    auto* constructor = createBlobConstructor(global_object, vm);
    constructor->putDirect(vm, vm.propertyNames->prototype, prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    prototype->putDirect(
        vm, vm.propertyNames->constructor, constructor, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));

    auto* structure = JSColloBlob::createStructure(vm, global_object, prototype);
    global_object->cacheBlobApi(constructor, prototype, structure);
    global_object->putDirect(vm, JSC::Identifier::fromString(vm, "Blob"_s), constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    RELEASE_ASSERT(global_object->getDirect(vm, JSC::Identifier::fromString(vm, "Blob"_s)));
}

void installWebApiFile(Collo::GlobalObject* global_object, JSC::VM& vm)
{
    constexpr unsigned enumerableAccessor = static_cast<unsigned>(JSC::PropertyAttribute::Accessor);

    auto* prototype = JSC::constructEmptyObject(global_object, global_object->blobPrototype());
    putWebApiAccessor(global_object, prototype, vm, "name"_s, fileGetName, nullptr, enumerableAccessor);
    putWebApiAccessor(global_object, prototype, vm, "lastModified"_s, fileGetLastModified, nullptr, enumerableAccessor);
    prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol, JSC::jsString(vm, WTF::makeString("File"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    auto* constructor = createFileConstructor(global_object, vm);
    constructor->setPrototype(vm, global_object, global_object->blobConstructor(), true);
    constructor->putDirect(vm, vm.propertyNames->prototype, prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    prototype->putDirect(
        vm, vm.propertyNames->constructor, constructor, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));

    auto* structure = JSColloFile::createStructure(vm, global_object, prototype);
    global_object->cacheFileApi(constructor, prototype, structure);
    global_object->putDirect(vm, JSC::Identifier::fromString(vm, "File"_s), constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    RELEASE_ASSERT(global_object->getDirect(vm, JSC::Identifier::fromString(vm, "File"_s)));
}

} // namespace Collo::HostFunctions

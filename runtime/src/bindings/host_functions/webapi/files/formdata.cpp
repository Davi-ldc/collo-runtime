// FormData: the cell and its iterator, the form body parsers behind Body.formData(), Blob.formData(), FormData.from()
// and collo_form_data_new_from_bytes, and the multipart serializer behind a FormData request or response body. Runs on
// the VM thread, except visitChildren, which marking threads run concurrently.
//
// visitChildren walks the entry vector under cellLock(). Every change that can move the vector's buffer therefore
// takes the lock, and nothing allocates a cell or reports extra memory while holding it: either can stop the mutator
// for a collection whose marker then waits for the same lock. Code that runs JavaScript between reads copies each
// entry out first, because the callback may change the vector. A File parsed from a multipart body views a copy of
// the whole body, so it keeps the whole body alive.

#include "host_functions/webapi/files/formdata.h"

#include "host_functions/webapi/buffer_source.h"
#include "host_functions/webapi/dom/dom_exception.h"
#include "host_functions/webapi/encoding/utf8.h"
#include "host_functions/webapi/files/blob.h"
#include "host_functions/webapi/limits.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/IdentifierInlines.h>
#include <JavaScriptCore/InternalFunction.h>
#include <JavaScriptCore/IteratorOperations.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSArrayBuffer.h>
#include <JavaScriptCore/JSArrayBufferView.h>
#include <JavaScriptCore/JSArray.h>
#include <JavaScriptCore/JSDestructibleObject.h>
#include <JavaScriptCore/JSFunction.h>
#include <JavaScriptCore/JSObject.h>
#include <JavaScriptCore/JSString.h>
#include <JavaScriptCore/SlotVisitorMacros.h>
#include <openssl/rand.h>
#include <wtf/Locker.h>
#include <wtf/URLParser.h>
#include <wtf/Vector.h>
#include <wtf/WallTime.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/WTFString.h>

#include <algorithm>
#include <cstring>
#include <limits>
#include <optional>
#include <span>

namespace Collo::HostFunctions {
namespace {

    using JSC::EncodedJSValue;
    using JSC::JSValue;
    using WTF::String;
    using namespace JSC;

    // FormDataMultipartMaxParts bounds the entries one multipart body can make the parser keep, and
    // FormDataMultipartMaxHeadersPerPart the header lines it decodes per part, beside the byte cap
    // WebApiMaterializedBodyBytesMax.
    constexpr unsigned FormDataMultipartMaxParts = 1000;
    constexpr unsigned FormDataMultipartMaxHeadersPerPart = 32;
    constexpr auto FormDataBodyBytesExceeded = "form data body exceeds the serverless body limit"_s;

    static size_t formDataStringMemoryCost(const String& value)
    {
        auto* impl = value.impl();
        if (!impl)
            return 0;
        return impl->costDuringGC();
    }

    enum class FormDataIteratorKind : uint8_t {
        Entries,
        Keys,
        Values,
    };

    class JSColloFormData final : public JSC::JSDestructibleObject {
        using Base = JSC::JSDestructibleObject;

    public:
        struct Entry {
            String name;
            String string_value;
            JSC::WriteBarrier<JSC::Unknown> file_value;
            bool is_file { false };
        };

        template <typename CellType, JSC::SubspaceAccess> static JSC::CompleteSubspace* subspaceFor(JSC::VM& vm)
        {
            return &vm.destructibleObjectSpace();
        }

        static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* global_object, JSValue prototype)
        {
            return JSC::Structure::create(
                vm, global_object, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
        }

        static JSColloFormData* create(JSC::VM& vm, JSC::Structure* structure)
        {
            auto* object = new (NotNull, JSC::allocateCell<JSColloFormData>(vm)) JSColloFormData(vm, structure);
            object->finishCreation(vm);
            return object;
        }

        static void destroy(JSC::JSCell* cell) { static_cast<JSColloFormData*>(cell)->~JSColloFormData(); }

        static size_t estimatedSize(JSC::JSCell* cell, JSC::VM& vm)
        {
            auto* this_object = static_cast<JSColloFormData*>(cell);
            return Base::estimatedSize(cell, vm) + this_object->memoryCost();
        }

        DECLARE_INFO;
        DECLARE_VISIT_CHILDREN;

        // The off-heap memory this cell retains itself: the entry vector and each entry's name and value strings.
        // File entries are cells that report their own bytes.
        size_t memoryCost() const
        {
            WTF::Locker locker { cellLock() };
            size_t cost = m_entries.capacity() * sizeof(Entry);
            for (const auto& entry : m_entries)
                cost += formDataStringMemoryCost(entry.name) + formDataStringMemoryCost(entry.string_value);
            return cost;
        }

        WTF::Vector<Entry>& entries() { return m_entries; }
        const WTF::Vector<Entry>& entries() const { return m_entries; }

        // One entry copied out for serialization: owning string copies and a reference to the part's storage, so the
        // serializer holds nothing that points into the entry vector.
        struct SerializationEntry {
            String name;
            String string_value;
            String filename;
            String content_type;
            WTF::RefPtr<BlobStorage> storage;
            size_t offset { 0 };
            size_t size { 0 };
            bool is_file { false };
        };

        // Copies every entry into `out`. A File or Blob entry becomes a reference to its storage with its offset and
        // size, sharing the bytes. Returns false on allocation failure. Only malloc memory is allocated under the lock.
        bool snapshotForSerialization(WTF::Vector<SerializationEntry>& out) const
        {
            WTF::Locker locker { cellLock() };
            if (!out.tryReserveCapacity(m_entries.size()))
                return false;
            for (const auto& entry : m_entries) {
                SerializationEntry snapshot;
                snapshot.name = entry.name;
                snapshot.is_file = entry.is_file;
                if (entry.is_file) {
                    if (auto* blob = dynamicDowncast<JSColloBlob>(entry.file_value.get())) {
                        snapshot.storage = blob->storageRef().ptr();
                        snapshot.offset = blob->byteOffset();
                        snapshot.size = blob->size();
                        snapshot.content_type = blob->type();
                        if (auto* file = dynamicDowncast<JSColloFile>(entry.file_value.get()))
                            snapshot.filename = file->name();
                    }
                } else
                    snapshot.string_value = entry.string_value;
                if (!out.tryAppend(WTF::move(snapshot)))
                    return false;
            }
            return true;
        }

        bool appendString(String name, String value)
        {
            Entry entry;
            entry.name = WTF::move(name);
            entry.string_value = WTF::move(value);
            return appendEntry(WTF::move(entry));
        }

        bool appendFile(JSC::VM& vm, Collo::GlobalObject* global_object, String name, JSColloBlob& blob,
            JSValue original_value, bool has_filename, String filename)
        {
            auto entry = createFileEntry(
                vm, global_object, WTF::move(name), blob, original_value, has_filename, WTF::move(filename));
            return appendEntry(WTF::move(entry));
        }

        bool appendParsedFile(JSC::VM& vm, Collo::GlobalObject* global_object, String name,
            WTF::Vector<uint8_t>&& bytes, String type, String filename)
        {
            Entry entry;
            entry.name = WTF::move(name);
            entry.is_file = true;
            auto last_modified = WTF::WallTime::now().secondsSinceEpoch().milliseconds();
            auto* file = JSColloFile::create(vm, global_object->fileStructure(), WTF::move(bytes), WTF::move(type),
                WTF::move(filename), last_modified);
            if (!file)
                return false;
            entry.file_value.set(vm, this, file);
            return appendEntry(WTF::move(entry));
        }

        // Appends a File that views `size` bytes at `offset` of `body_bytes`, the copy of the whole multipart body
        // that every File parsed from it shares.
        bool appendParsedFileView(JSC::VM& vm, Collo::GlobalObject* global_object, String name,
            WTF::Ref<BlobBytes>&& body_bytes, size_t offset, size_t size, String type, String filename)
        {
            Entry entry;
            entry.name = WTF::move(name);
            entry.is_file = true;
            WTF::Vector<BlobSegment> segments;
            if (size && !segments.tryAppend(BlobSegment(WTF::move(body_bytes), offset, size)))
                return false;
            auto last_modified = WTF::WallTime::now().secondsSinceEpoch().milliseconds();
            auto* file = JSColloFile::create(vm, global_object->fileStructure(), WTF::move(segments), size,
                WTF::move(type), WTF::move(filename), last_modified);
            if (!file)
                return false;
            entry.file_value.set(vm, this, file);
            return appendEntry(WTF::move(entry));
        }

        bool setString(String name, String value)
        {
            Entry entry;
            entry.name = name;
            entry.string_value = WTF::move(value);
            return setEntry(WTF::move(name), WTF::move(entry));
        }

        bool setFile(JSC::VM& vm, Collo::GlobalObject* global_object, String name, JSColloBlob& blob,
            JSValue original_value, bool has_filename, String filename)
        {
            auto entry
                = createFileEntry(vm, global_object, name, blob, original_value, has_filename, WTF::move(filename));
            return setEntry(WTF::move(name), WTF::move(entry));
        }

        void remove(const String& name)
        {
            WTF::Locker locker { cellLock() };
            m_entries.removeAllMatching([&](const auto& entry) { return entry.name == name; });
        }

        // One entry copied out without allocating a cell. A File entry keeps its existing cell in `file_value`. A
        // string entry keeps its text in `string_value`, and the caller creates the JSString after entryAt() has
        // released the cell lock, since allocating a cell under the lock can deadlock with the marker.
        struct EntrySnapshot {
            String name;
            String string_value;
            JSValue file_value;
            bool is_file { false };
        };

        // Copies the entry at `index` into `out`; false when `index` is out of range. forEach() and the iterator read
        // entries only through it, because the JavaScript they run may change the vector and move its buffer.
        bool entryAt(unsigned index, EntrySnapshot& out) const
        {
            WTF::Locker locker { cellLock() };
            if (index >= m_entries.size())
                return false;
            const auto& entry = m_entries[index];
            out.name = entry.name;
            out.is_file = entry.is_file;
            if (entry.is_file)
                out.file_value = entry.file_value.get();
            else
                out.string_value = entry.string_value;
            return true;
        }

        unsigned size() const
        {
            WTF::Locker locker { cellLock() };
            return m_entries.size();
        }

    private:
        JSColloFormData(JSC::VM& vm, JSC::Structure* structure)
            : Base(vm, structure)
        {
        }

        ~JSColloFormData() = default;

        void finishCreation(JSC::VM& vm)
        {
            Base::finishCreation(vm);
            ASSERT(inherits(info()));
            // The cost is reported here, then by each append that grows it, and again by visitChildren in every
            // collection, which is where removals stop counting.
            vm.heap.reportExtraMemoryAllocated(this, memoryCost());
        }

        Entry createFileEntry(JSC::VM& vm, Collo::GlobalObject* global_object, String name, JSColloBlob& blob,
            JSValue original_value, bool has_filename, String filename)
        {
            Entry entry;
            entry.name = WTF::move(name);
            entry.is_file = true;

            if (auto* file = dynamicDowncast<JSColloFile>(&blob)) {
                if (!has_filename) {
                    entry.file_value.set(vm, this, original_value);
                    return entry;
                }
                auto* renamed = JSColloFile::createFromBlob(
                    vm, global_object->fileStructure(), *file, WTF::move(filename), file->lastModified());
                entry.file_value.set(vm, this, renamed);
                return entry;
            }

            auto name_for_blob = has_filename ? WTF::move(filename) : WTF::makeString("blob"_s);
            auto last_modified = WTF::WallTime::now().secondsSinceEpoch().milliseconds();
            auto* file = JSColloFile::createFromBlob(
                vm, global_object->fileStructure(), blob, WTF::move(name_for_blob), last_modified);
            entry.file_value.set(vm, this, file);
            return entry;
        }

        bool setEntry(const String& name, Entry&& replacement)
        {
            const size_t added_cost = appendedEntryMemoryCost(replacement);
            bool appended_new = false;
            {
                // Entries move within the buffer, which may then shrink or reallocate, so the lock covers the whole
                // compaction.
                WTF::Locker locker { cellLock() };
                bool found = false;
                unsigned write = 0;
                for (unsigned read = 0; read < m_entries.size(); read++) {
                    auto& entry = m_entries[read];
                    if (entry.name != name) {
                        if (write != read)
                            m_entries[write] = WTF::move(entry);
                        write++;
                        continue;
                    }
                    if (!found) {
                        if (write != read)
                            m_entries[write] = WTF::move(replacement);
                        else
                            entry = WTF::move(replacement);
                        write++;
                        found = true;
                    }
                }
                m_entries.shrink(write);
                if (!found) {
                    if (!m_entries.tryAppend(WTF::move(replacement)))
                        return false;
                    appended_new = true;
                }
            }
            if (appended_new)
                reportEntryMemoryAllocated(added_cost);
            return true;
        }

        static size_t appendedEntryMemoryCost(const Entry& entry)
        {
            return sizeof(Entry) + formDataStringMemoryCost(entry.name) + formDataStringMemoryCost(entry.string_value);
        }

        bool appendEntry(Entry&& entry)
        {
            const size_t added_cost = appendedEntryMemoryCost(entry);
            bool appended = false;
            {
                WTF::Locker locker { cellLock() };
                appended = m_entries.tryAppend(WTF::move(entry));
            }
            if (appended)
                reportEntryMemoryAllocated(added_cost);
            return appended;
        }

        // Reports growth between collections; removals stop counting at visitChildren's report in the next
        // collection. Never call it while holding the cell lock: the report can stop the mutator for a collection
        // whose marker needs that lock to visit this cell.
        void reportEntryMemoryAllocated(size_t cost) { vm().heap.reportExtraMemoryAllocated(this, cost); }

        // Every change that can move this buffer (append, compaction, removal) takes cellLock() around the vector
        // operation, and only there.
        WTF::Vector<Entry> m_entries;
    };

    class JSColloFormDataIterator final : public JSC::JSDestructibleObject {
        using Base = JSC::JSDestructibleObject;

    public:
        template <typename CellType, JSC::SubspaceAccess> static JSC::CompleteSubspace* subspaceFor(JSC::VM& vm)
        {
            return &vm.destructibleObjectSpace();
        }

        static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* global_object, JSValue prototype)
        {
            return JSC::Structure::create(
                vm, global_object, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
        }

        static JSColloFormDataIterator* create(
            JSC::VM& vm, Collo::GlobalObject* global_object, JSColloFormData* form_data, FormDataIteratorKind kind)
        {
            auto* object = new (NotNull, JSC::allocateCell<JSColloFormDataIterator>(vm))
                JSColloFormDataIterator(vm, global_object->formDataIteratorStructure(), kind);
            object->finishCreation(vm, form_data);
            return object;
        }

        static void destroy(JSC::JSCell* cell)
        {
            static_cast<JSColloFormDataIterator*>(cell)->~JSColloFormDataIterator();
        }

        DECLARE_INFO;
        DECLARE_VISIT_CHILDREN;

        JSColloFormData* formData() const { return m_form_data.get(); }
        // Returns the current index and advances, or nothing once the index reaches `size`. As in WebIDL's default
        // iterator objects, an exhausted iterator keeps its index, so it returns entries appended later, and the index
        // cannot wrap.
        std::optional<unsigned> takeIndex(unsigned size)
        {
            if (m_index >= size)
                return std::nullopt;
            return m_index++;
        }
        FormDataIteratorKind kind() const { return m_kind; }

    private:
        JSColloFormDataIterator(JSC::VM& vm, JSC::Structure* structure, FormDataIteratorKind kind)
            : Base(vm, structure)
            , m_kind(kind)
        {
        }

        ~JSColloFormDataIterator() = default;

        void finishCreation(JSC::VM& vm, JSColloFormData* form_data)
        {
            Base::finishCreation(vm);
            ASSERT(inherits(info()));
            m_form_data.set(vm, this, form_data);
        }

        JSC::WriteBarrier<JSColloFormData> m_form_data;
        unsigned m_index { 0 };
        FormDataIteratorKind m_kind;
    };

    const JSC::ClassInfo JSColloFormData::s_info
        = { "FormData"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloFormData) };
    const JSC::ClassInfo JSColloFormDataIterator::s_info
        = { "FormData Iterator"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloFormDataIterator) };

    template <typename Visitor> void JSColloFormData::visitChildrenImpl(JSC::JSCell* cell, Visitor& visitor)
    {
        auto* this_object = static_cast<JSColloFormData*>(cell);
        ASSERT_GC_OBJECT_INHERITS(this_object, info());
        Base::visitChildren(this_object, visitor);
        // The lock keeps the entry buffer in place while this marking thread walks it (see m_entries).
        WTF::Locker locker { this_object->cellLock() };
        size_t cost = this_object->m_entries.capacity() * sizeof(Entry);
        for (auto& entry : this_object->m_entries) {
            cost += formDataStringMemoryCost(entry.name) + formDataStringMemoryCost(entry.string_value);
            if (entry.is_file)
                visitor.append(entry.file_value);
        }
        // A full collection resets the heap's extra memory count, so the retained cost is reported again in every
        // collection.
        visitor.reportExtraMemoryVisited(cost);
    }

    DEFINE_VISIT_CHILDREN(JSColloFormData);

    template <typename Visitor> void JSColloFormDataIterator::visitChildrenImpl(JSC::JSCell* cell, Visitor& visitor)
    {
        auto* this_object = static_cast<JSColloFormDataIterator*>(cell);
        ASSERT_GC_OBJECT_INHERITS(this_object, info());
        Base::visitChildren(this_object, visitor);
        visitor.append(this_object->m_form_data);
    }

    DEFINE_VISIT_CHILDREN(JSColloFormDataIterator);

    static JSColloFormData* requireFormData(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
    {
        if (auto* form_data = dynamicDowncast<JSColloFormData>(value))
            return form_data;
        JSC::throwVMTypeError(global_object, scope, "FormData method called on incompatible receiver"_s);
        return nullptr;
    }

    static JSColloFormDataIterator* requireFormDataIterator(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
    {
        if (auto* iterator = dynamicDowncast<JSColloFormDataIterator>(value))
            return iterator;
        JSC::throwVMTypeError(global_object, scope, "FormData Iterator method called on incompatible receiver"_s);
        return nullptr;
    }

    static JSC::Structure* formDataStructureForNewTarget(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::CallFrame* call_frame)
    {
        auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
        auto* new_target = call_frame->newTarget().getObject();
        auto* constructor = call_frame->jsCallee();
        if (!new_target || new_target == constructor)
            return collo_global->formDataStructure();

        auto* structure = JSC::InternalFunction::createSubclassStructure(
            global_object, new_target, collo_global->formDataStructure());
        RETURN_IF_EXCEPTION(scope, nullptr);
        return structure;
    }

    static bool requireArgumentCount(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        JSC::CallFrame* call_frame, unsigned count, WTF::ASCIILiteral message)
    {
        if (call_frame->argumentCount() >= count)
            return true;
        JSC::throwVMTypeError(global_object, scope, message);
        return false;
    }

    static String formDataUSVArgument(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::CallFrame* call_frame, unsigned index)
    {
        return toWebApiUSVString(argumentToWebApiString(global_object, scope, call_frame, index));
    }

    static JSValue entryValue(JSC::VM& vm, const JSColloFormData::Entry& entry)
    {
        if (entry.is_file)
            return entry.file_value.get();
        return JSC::jsString(vm, entry.string_value);
    }

    static bool hasFilenameArgument(JSC::CallFrame* call_frame)
    {
        return call_frame->argumentCount() > 2 && !call_frame->argument(2).isUndefined();
    }

    static bool isAsciiWhitespace(char16_t character)
    {
        return character == ' ' || character == '\t' || character == '\n' || character == '\r' || character == 0x0b
            || character == 0x0c;
    }

    static String trimAscii(String value)
    {
        unsigned start = 0;
        unsigned end = value.length();
        while (start < end && isAsciiWhitespace(value[start]))
            start++;
        while (end > start && isAsciiWhitespace(value[end - 1]))
            end--;
        return value.substring(start, end - start);
    }

    enum class MultipartSizeResult : uint8_t {
        Ok,
        Exceeded,
    };

    static MultipartSizeResult addMultipartSize(size_t& total_size, size_t byte_size)
    {
        if (byte_size > WebApiMaterializedBodyBytesMax || total_size > WebApiMaterializedBodyBytesMax - byte_size)
            return MultipartSizeResult::Exceeded;
        total_size += byte_size;
        return MultipartSizeResult::Ok;
    }

    static MultipartSizeResult addUtf8CodePointSize(
        size_t& total_size, uint32_t code_point, bool escape_header_parameter)
    {
        size_t byte_size = 1;
        if (escape_header_parameter && (code_point == '\r' || code_point == '\n' || code_point == '"'))
            byte_size = 3;
        else if (code_point > 0x7f)
            byte_size = code_point <= 0x7ff ? 2 : code_point <= 0xffff ? 3 : 4;
        return addMultipartSize(total_size, byte_size);
    }

    static MultipartSizeResult addStringUtf8Size(
        size_t& total_size, const String& value, bool escape_header_parameter = false)
    {
        if (value.isEmpty())
            return MultipartSizeResult::Ok;

        if (value.is8Bit()) {
            for (auto character : value.span8()) {
                auto result = addUtf8CodePointSize(total_size, character, escape_header_parameter);
                if (result != MultipartSizeResult::Ok)
                    return result;
            }
            return MultipartSizeResult::Ok;
        }

        auto units = value.span16();
        for (size_t index = 0; index < units.size(); index++) {
            uint16_t unit = units[index];
            uint32_t code_point = unit;
            if (unit >= 0xd800 && unit <= 0xdbff && index + 1 < units.size()) {
                uint16_t low = units[index + 1];
                if (low >= 0xdc00 && low <= 0xdfff) {
                    code_point = 0x10000 + (((unit - 0xd800) << 10) | (low - 0xdc00));
                    index++;
                } else
                    code_point = 0xfffd;
            } else if (unit >= 0xdc00 && unit <= 0xdfff)
                code_point = 0xfffd;

            auto result = addUtf8CodePointSize(total_size, code_point, escape_header_parameter);
            if (result != MultipartSizeResult::Ok)
                return result;
        }
        return MultipartSizeResult::Ok;
    }

    static MultipartSizeResult addEscapedHeaderParameterSize(size_t& total_size, const String& value)
    {
        return addStringUtf8Size(total_size, value, true);
    }

    static bool ensureFormDataBodyBytesWithinLimit(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        size_t byte_size, WTF::ASCIILiteral* out_parse_error = nullptr)
    {
        if (byte_size <= WebApiMaterializedBodyBytesMax)
            return true;
        if (out_parse_error)
            *out_parse_error = FormDataBodyBytesExceeded;
        else
            JSC::throwException(global_object, scope, createFormDataBodyQuotaExceeded(global_object));
        return false;
    }

    static bool ensureFormDataStringUtf8BodyWithinLimit(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, const String& text)
    {
        size_t byte_size = 0;
        auto result = addStringUtf8Size(byte_size, text);
        if (result == MultipartSizeResult::Ok)
            return true;
        if (result == MultipartSizeResult::Exceeded)
            JSC::throwException(global_object, scope, createFormDataBodyQuotaExceeded(global_object));
        return false;
    }

    static String normalizePartContentType(String input)
    {
        input = trimAscii(WTF::move(input));
        if (input.isEmpty())
            return emptyString();

        WTF::StringBuilder builder;
        builder.reserveCapacity(input.length());
        for (unsigned index = 0; index < input.length(); index++) {
            char16_t character = input[index];
            if (character < 0x20 || character > 0x7e)
                return emptyString();
            if (character >= 'A' && character <= 'Z')
                character = static_cast<char16_t>(character + 0x20);
            builder.append(character);
        }
        return builder.toString();
    }

    static std::optional<uint8_t> hexValue(char16_t character)
    {
        if (character >= '0' && character <= '9')
            return static_cast<uint8_t>(character - '0');
        if (character >= 'a' && character <= 'f')
            return static_cast<uint8_t>(character - 'a' + 10);
        if (character >= 'A' && character <= 'F')
            return static_cast<uint8_t>(character - 'A' + 10);
        return std::nullopt;
    }

    enum class PercentDecodeResult : uint8_t {
        Ok,
        Invalid,
        OutOfMemory,
    };

    static PercentDecodeResult percentDecode(String input, WTF::Vector<uint8_t>& output)
    {
        auto utf8 = input.utf8();
        auto* bytes = reinterpret_cast<const uint8_t*>(utf8.data());
        for (size_t index = 0; index < utf8.length(); index++) {
            if (bytes[index] == '%') {
                if (index + 2 >= utf8.length())
                    return PercentDecodeResult::Invalid;
                auto hi = hexValue(bytes[index + 1]);
                auto lo = hexValue(bytes[index + 2]);
                if (!hi || !lo)
                    return PercentDecodeResult::Invalid;
                if (!output.tryAppend(static_cast<uint8_t>((*hi << 4) | *lo)))
                    return PercentDecodeResult::OutOfMemory;
                index += 2;
                continue;
            }
            if (!output.tryAppend(bytes[index]))
                return PercentDecodeResult::OutOfMemory;
        }
        return PercentDecodeResult::Ok;
    }

    static bool isValidUTF8(std::span<const uint8_t> bytes)
    {
        size_t index = 0;
        while (index < bytes.size()) {
            uint8_t first = bytes[index++];
            if (first <= 0x7f)
                continue;

            uint32_t code_point = 0;
            size_t continuation_count = 0;
            if (first >= 0xc2 && first <= 0xdf) {
                code_point = first & 0x1f;
                continuation_count = 1;
            } else if (first >= 0xe0 && first <= 0xef) {
                code_point = first & 0x0f;
                continuation_count = 2;
            } else if (first >= 0xf0 && first <= 0xf4) {
                code_point = first & 0x07;
                continuation_count = 3;
            } else
                return false;

            if (continuation_count > bytes.size() - index)
                return false;
            for (size_t continuation = 0; continuation < continuation_count; continuation++) {
                uint8_t next = bytes[index++];
                if ((next & 0xc0) != 0x80)
                    return false;
                code_point = (code_point << 6) | (next & 0x3f);
            }

            if ((continuation_count == 1 && code_point < 0x80) || (continuation_count == 2 && code_point < 0x800)
                || (continuation_count == 3 && code_point < 0x10000) || code_point > 0x10ffff
                || (code_point >= 0xd800 && code_point <= 0xdfff))
                return false;
        }
        return true;
    }

    static bool isRFC5987AttributeChar(char16_t character)
    {
        if ((character >= '0' && character <= '9') || (character >= 'A' && character <= 'Z')
            || (character >= 'a' && character <= 'z'))
            return true;
        switch (character) {
        case '!':
        case '#':
        case '$':
        case '&':
        case '+':
        case '-':
        case '.':
        case '^':
        case '_':
        case '`':
        case '|':
        case '~':
            return true;
        default:
            return false;
        }
    }

    static bool isRFC5987EncodedValue(const String& value)
    {
        for (unsigned index = 0; index < value.length(); index++) {
            auto character = value[index];
            if (character == '%' || isRFC5987AttributeChar(character))
                continue;
            return false;
        }
        return true;
    }

    static bool decodeRFC5987Value(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, String value, String& out)
    {
        auto first_quote = value.find('\'');
        if (first_quote == notFound)
            return false;
        auto second_quote = value.find('\'', first_quote + 1);
        if (second_quote == notFound)
            return false;

        auto charset = value.substring(0, first_quote).convertToASCIILowercase();
        if (charset != "utf-8"_s)
            return false;

        auto encoded_value = value.substring(second_quote + 1);
        if (!isRFC5987EncodedValue(encoded_value))
            return false;

        WTF::Vector<uint8_t> decoded;
        switch (percentDecode(WTF::move(encoded_value), decoded)) {
        case PercentDecodeResult::Ok:
            break;
        case PercentDecodeResult::Invalid:
            return false;
        case PercentDecodeResult::OutOfMemory:
            JSC::throwOutOfMemoryError(global_object, scope);
            return false;
        }
        if (!isValidUTF8(decoded.span()))
            return false;
        return decodeUtf8BytesPreservingBom(global_object, scope, decoded.span(), out);
    }

    static bool containsHeaderLineBreak(const String& value)
    {
        return value.find('\r') != notFound || value.find('\n') != notFound;
    }

    static bool parseQuotedHeaderValue(String value, String& out)
    {
        if (value.length() < 2 || value[0] != '"')
            return false;
        if (containsHeaderLineBreak(value))
            return false;

        WTF::StringBuilder builder;
        bool closed = false;
        for (unsigned index = 1; index < value.length(); index++) {
            auto character = value[index];
            if (character == '"') {
                closed = true;
                for (unsigned tail = index + 1; tail < value.length(); tail++) {
                    if (!isAsciiWhitespace(value[tail]))
                        return false;
                }
                break;
            }
            if (character == '\\' && index + 1 < value.length())
                character = value[++index];
            builder.append(character);
        }
        if (!closed)
            return false;
        out = builder.toString();
        return true;
    }

    static bool parseHeaderParameterValue(String value, String& out)
    {
        value = trimAscii(WTF::move(value));
        if (containsHeaderLineBreak(value))
            return false;
        if (!value.isEmpty() && value[0] == '"')
            return parseQuotedHeaderValue(WTF::move(value), out);
        out = WTF::move(value);
        return true;
    }

    static bool parseContentDispositionParameterValue(String value, String& out)
    {
        value = trimAscii(WTF::move(value));
        if (containsHeaderLineBreak(value))
            return false;
        if (value.isEmpty() || value[0] != '"') {
            out = WTF::move(value);
            return true;
        }

        WTF::StringBuilder builder;
        bool closed = false;
        for (unsigned index = 1; index < value.length(); index++) {
            auto character = value[index];
            if (character == '"') {
                closed = true;
                for (unsigned tail = index + 1; tail < value.length(); tail++) {
                    if (!isAsciiWhitespace(value[tail]))
                        return false;
                }
                break;
            }
            if (character == '\\' && index + 1 < value.length())
                character = value[++index];
            builder.append(character);
        }
        if (!closed)
            return false;
        out = builder.toString();
        return true;
    }

    static constexpr unsigned headerParameterSeparatorNotFound = std::numeric_limits<unsigned>::max();

    static unsigned findHeaderParameterSeparator(const String& value, unsigned start)
    {
        bool in_quote = false;
        bool escaped = false;
        for (unsigned index = start; index < value.length(); index++) {
            auto character = value[index];
            if (escaped) {
                escaped = false;
                continue;
            }
            if (in_quote && character == '\\') {
                escaped = true;
                continue;
            }
            if (character == '"') {
                in_quote = !in_quote;
                continue;
            }
            if (!in_quote && character == ';')
                return index;
        }
        return headerParameterSeparatorNotFound;
    }

    enum class BodyFormEncoding : uint8_t {
        UrlEncoded,
        Multipart,
    };

    struct ParsedBodyContentType {
        BodyFormEncoding encoding { BodyFormEncoding::UrlEncoded };
        WTF::Vector<uint8_t> boundary;
    };

    static bool appendBoundaryBytes(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        std::span<const uint8_t> bytes, WTF::Vector<uint8_t>& out)
    {
        if (bytes.empty() || bytes.size() > WebApiFormDataBoundaryBytesMax)
            return false;
        for (size_t index = 0; index < bytes.size(); index++) {
            unsigned char character = bytes[index];
            bool is_final = index + 1 == bytes.size();
            bool is_boundary_character = (character >= '0' && character <= '9')
                || (character >= 'A' && character <= 'Z') || (character >= 'a' && character <= 'z') || character == '\''
                || character == '(' || character == ')' || character == '+' || character == '_' || character == ','
                || character == '-' || character == '.' || character == '/' || character == ':' || character == '='
                || character == '?' || (character == ' ' && !is_final);
            if (!is_boundary_character)
                return false;
        }
        if (out.tryAppend(bytes))
            return true;
        JSC::throwOutOfMemoryError(global_object, scope);
        return false;
    }

    static bool appendBoundaryBytes(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, String value, WTF::Vector<uint8_t>& out)
    {
        // Every code unit encodes to at least one UTF-8 byte, so a string longer than WebApiFormDataBoundaryBytesMax
        // would fail the byte check anyway. Rejecting it here keeps an oversized boundary from being converted
        // (limits.h).
        if (value.isEmpty() || value.length() > WebApiFormDataBoundaryBytesMax)
            return false;
        auto utf8 = value.utf8();
        return appendBoundaryBytes(global_object, scope,
            std::span<const uint8_t> { reinterpret_cast<const uint8_t*>(utf8.data()), utf8.length() }, out);
    }

    static std::optional<ParsedBodyContentType> parseBodyContentType(JSC::JSGlobalObject* global_object,
        JSC::ThrowScope& scope, String content_type, std::optional<WTF::ASCIILiteral>& parse_error)
    {
        auto semicolon = content_type.find(';');
        auto media = trimAscii(semicolon == notFound ? content_type : content_type.substring(0, semicolon))
                         .convertToASCIILowercase();
        if (media == "application/x-www-form-urlencoded"_s)
            return ParsedBodyContentType { .encoding = BodyFormEncoding::UrlEncoded };
        if (media != "multipart/form-data"_s)
            return std::nullopt;

        ParsedBodyContentType parsed { .encoding = BodyFormEncoding::Multipart };
        unsigned cursor = semicolon == notFound ? content_type.length() : semicolon + 1;
        while (cursor <= content_type.length()) {
            auto next = findHeaderParameterSeparator(content_type, cursor);
            auto segment
                = trimAscii(next == headerParameterSeparatorNotFound ? content_type.substring(cursor)
                                                                     : content_type.substring(cursor, next - cursor));
            if (!segment.isEmpty()) {
                auto equals = segment.find('=');
                if (equals != notFound) {
                    auto name = trimAscii(segment.substring(0, equals)).convertToASCIILowercase();
                    if (name == "boundary"_s) {
                        String value;
                        if (!parseHeaderParameterValue(segment.substring(equals + 1), value)
                            || !appendBoundaryBytes(global_object, scope, value, parsed.boundary)) {
                            if (scope.exception())
                                return std::nullopt;
                            parse_error = "invalid multipart boundary"_s;
                            return std::nullopt;
                        }
                        return parsed;
                    }
                }
            }
            if (next == headerParameterSeparatorNotFound)
                break;
            cursor = next + 1;
        }

        parse_error = "missing multipart boundary"_s;
        return std::nullopt;
    }

    struct PartHeaders {
        String name;
        String filename;
        String filename_star;
        String content_type;
        bool has_name { false };
        bool has_filename { false };
        bool has_filename_star { false };
    };

    static bool parseContentDisposition(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, String value,
        PartHeaders& out, std::optional<WTF::ASCIILiteral>& parse_error)
    {
        auto semicolon = value.find(';');
        auto disposition
            = trimAscii(semicolon == notFound ? value : value.substring(0, semicolon)).convertToASCIILowercase();
        if (disposition != "form-data"_s) {
            parse_error = "invalid multipart content disposition"_s;
            return false;
        }

        unsigned cursor = semicolon == notFound ? value.length() : semicolon + 1;
        while (cursor <= value.length()) {
            auto next = findHeaderParameterSeparator(value, cursor);
            auto segment = trimAscii(next == headerParameterSeparatorNotFound ? value.substring(cursor)
                                                                              : value.substring(cursor, next - cursor));
            auto equals = segment.find('=');
            if (equals == notFound && segment.convertToASCIILowercase().startsWith("filename*"_s)) {
                parse_error = "invalid multipart content disposition"_s;
                return false;
            }
            if (equals != notFound) {
                String name = trimAscii(segment.substring(0, equals)).convertToASCIILowercase();
                String parameter_value;
                if (!parseContentDispositionParameterValue(segment.substring(equals + 1), parameter_value)) {
                    parse_error = "invalid multipart content disposition"_s;
                    return false;
                }
                if (name == "name"_s) {
                    out.name = WTF::move(parameter_value);
                    out.has_name = true;
                } else if (name == "filename"_s) {
                    out.filename = WTF::move(parameter_value);
                    out.has_filename = true;
                } else if (name == "filename*"_s) {
                    String decoded;
                    if (decodeRFC5987Value(global_object, scope, WTF::move(parameter_value), decoded)) {
                        out.filename_star = WTF::move(decoded);
                        out.has_filename = true;
                        out.has_filename_star = true;
                    } else if (scope.exception())
                        return false;
                }
            }
            if (next == headerParameterSeparatorNotFound)
                break;
            cursor = next + 1;
        }

        if (!out.has_name) {
            parse_error = "multipart part missing name"_s;
            return false;
        }
        return true;
    }

    static bool parsePartHeaders(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        std::span<const uint8_t> bytes, PartHeaders& out, std::optional<WTF::ASCIILiteral>& parse_error)
    {
        size_t line_start = 0;
        unsigned header_count = 0;
        bool saw_disposition = false;
        while (line_start < bytes.size()) {
            size_t line_end = line_start;
            while (line_end + 1 < bytes.size() && !(bytes[line_end] == '\r' && bytes[line_end + 1] == '\n'))
                line_end++;
            const bool has_line_terminator
                = line_end + 1 < bytes.size() && bytes[line_end] == '\r' && bytes[line_end + 1] == '\n';
            if (!has_line_terminator)
                line_end = bytes.size();
            auto line = bytes.subspan(line_start, line_end - line_start);
            auto colon = std::find(line.begin(), line.end(), static_cast<uint8_t>(':'));
            if (colon == line.end()) {
                parse_error = "invalid multipart header"_s;
                return false;
            }
            if (++header_count > FormDataMultipartMaxHeadersPerPart) {
                parse_error = "multipart part header count exceeded"_s;
                return false;
            }

            auto name_bytes = line.subspan(0, colon - line.begin());
            auto value_bytes = line.subspan((colon - line.begin()) + 1);
            String name;
            if (!decodeUtf8BytesPreservingBom(global_object, scope, name_bytes, name))
                return false;
            name = name.convertToASCIILowercase();

            String value;
            if (!decodeUtf8BytesPreservingBom(global_object, scope, value_bytes, value))
                return false;
            if (trimAscii(name) == "content-disposition"_s) {
                saw_disposition = true;
                if (!parseContentDisposition(global_object, scope, trimAscii(WTF::move(value)), out, parse_error))
                    return false;
            } else if (trimAscii(name) == "content-type"_s)
                out.content_type = normalizePartContentType(WTF::move(value));

            if (!has_line_terminator)
                break;
            line_start = line_end + 2;
        }

        if (!saw_disposition) {
            parse_error = "multipart part missing content disposition"_s;
            return false;
        }
        return true;
    }

    static bool buildByteSearchTable(std::span<const uint8_t> needle, WTF::Vector<size_t>& table)
    {
        table.clear();
        if (needle.empty())
            return true;
        if (!table.tryAppend(0))
            return false;

        size_t prefix_size = 0;
        for (size_t index = 1; index < needle.size();) {
            if (needle[index] == needle[prefix_size]) {
                prefix_size++;
                if (!table.tryAppend(prefix_size))
                    return false;
                index++;
                continue;
            }

            if (prefix_size) {
                prefix_size = table[prefix_size - 1];
                continue;
            }

            if (!table.tryAppend(0))
                return false;
            index++;
        }
        return true;
    }

    static bool startsWithBytes(std::span<const uint8_t> bytes, size_t offset, std::span<const uint8_t> prefix);

    static bool isMultipartCloseDelimiterSuffix(std::span<const uint8_t> body, size_t offset)
    {
        constexpr uint8_t crlf_bytes[] = { '\r', '\n' };
        constexpr uint8_t close_bytes[] = { '-', '-' };
        if (!startsWithBytes(body, offset, close_bytes))
            return false;

        size_t cursor = offset + sizeof(close_bytes);
        if (cursor == body.size())
            return true;
        while (cursor < body.size() && (body[cursor] == ' ' || body[cursor] == '\t'))
            cursor++;
        return startsWithBytes(body, cursor, crlf_bytes);
    }

    static std::optional<size_t> multipartRegularDelimiterSuffixEnd(std::span<const uint8_t> body, size_t offset)
    {
        constexpr uint8_t crlf_bytes[] = { '\r', '\n' };
        size_t cursor = offset;
        while (cursor < body.size() && (body[cursor] == ' ' || body[cursor] == '\t'))
            cursor++;
        if (!startsWithBytes(body, cursor, crlf_bytes))
            return std::nullopt;
        return cursor + sizeof(crlf_bytes);
    }

    static bool isMultipartDelimiterSuffix(std::span<const uint8_t> body, size_t offset)
    {
        return multipartRegularDelimiterSuffixEnd(body, offset).has_value()
            || isMultipartCloseDelimiterSuffix(body, offset);
    }

    static bool isMultipartDelimiterPrefix(std::span<const uint8_t> body, size_t offset)
    {
        return offset == 0 || (offset >= 2 && body[offset - 2] == '\r' && body[offset - 1] == '\n');
    }

    static size_t findBytes(std::span<const uint8_t> haystack, std::span<const uint8_t> needle,
        std::span<const size_t> table, size_t start = 0)
    {
        if (needle.empty() || haystack.size() < needle.size() || table.size() != needle.size()
            || start > haystack.size() - needle.size())
            return notFound;

        size_t matched = 0;
        for (size_t index = start; index < haystack.size(); index++) {
            while (matched && haystack[index] != needle[matched])
                matched = table[matched - 1];
            if (haystack[index] != needle[matched])
                continue;
            matched++;
            if (matched == needle.size())
                return index + 1 - needle.size();
        }
        return notFound;
    }

    static size_t findMultipartDelimiter(std::span<const uint8_t> body, std::span<const uint8_t> delimiter,
        std::span<const size_t> table, size_t start = 0, bool require_prefix = true)
    {
        size_t search_start = start;
        while (search_start < body.size()) {
            auto candidate = findBytes(body, delimiter, table, search_start);
            if (candidate == notFound)
                return notFound;
            if ((!require_prefix || isMultipartDelimiterPrefix(body, candidate))
                && isMultipartDelimiterSuffix(body, candidate + delimiter.size()))
                return candidate;
            search_start = candidate + 1;
        }
        return notFound;
    }

    static size_t findBytes(std::span<const uint8_t> haystack, std::span<const uint8_t> needle, size_t start = 0)
    {
        if (needle.empty() || haystack.size() < needle.size() || start > haystack.size() - needle.size())
            return notFound;
        for (size_t index = start; index <= haystack.size() - needle.size(); index++) {
            if (std::memcmp(haystack.data() + index, needle.data(), needle.size()) == 0)
                return index;
        }
        return notFound;
    }

    static bool startsWithBytes(std::span<const uint8_t> bytes, size_t offset, std::span<const uint8_t> prefix)
    {
        return offset <= bytes.size() && prefix.size() <= bytes.size() - offset
            && std::memcmp(bytes.data() + offset, prefix.data(), prefix.size()) == 0;
    }

    static bool appendUrlEncodedEntries(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        JSColloFormData* form_data, std::span<const uint8_t> bytes, std::optional<WTF::ASCIILiteral>& parse_error)
    {
        String decoded;
        if (!decodeUtf8Bytes(global_object, scope, bytes, decoded))
            return false;
        auto pairs = WTF::URLParser::parseURLEncodedForm(decoded);
        unsigned entry_count = 0;
        for (auto& pair : pairs) {
            if (++entry_count > WebApiFormDataUrlEncodedEntriesMax) {
                parse_error = "form data entry count exceeded"_s;
                return false;
            }
            if (!form_data->appendString(WTF::move(pair.key), WTF::move(pair.value))) {
                JSC::throwOutOfMemoryError(global_object, scope);
                return false;
            }
        }
        return true;
    }

    static bool appendMultipartEntries(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        JSColloFormData* form_data, std::span<const uint8_t> body, std::span<const uint8_t> boundary,
        std::optional<WTF::ASCIILiteral>& parse_error, BlobBytes* shared_body_bytes = nullptr)
    {
        auto& vm = global_object->vm();
        auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
        WTF::Vector<uint8_t> delimiter;
        if (!delimiter.tryAppend(static_cast<uint8_t>('-')) || !delimiter.tryAppend(static_cast<uint8_t>('-'))
            || !delimiter.tryAppend(boundary)) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return false;
        }
        constexpr uint8_t header_end_bytes[] = { '\r', '\n', '\r', '\n' };

        WTF::Vector<size_t> delimiter_table;
        if (!buildByteSearchTable(delimiter.span(), delimiter_table)) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return false;
        }

        auto first = findMultipartDelimiter(body, delimiter.span(), delimiter_table.span());
        if (first == notFound) {
            parse_error = "multipart body missing boundary"_s;
            return false;
        }
        if (first != 0) {
            parse_error = "invalid multipart boundary framing"_s;
            return false;
        }
        size_t cursor = first + delimiter.size();
        if (isMultipartCloseDelimiterSuffix(body, cursor))
            return true;
        auto next_cursor = multipartRegularDelimiterSuffixEnd(body, cursor);
        if (!next_cursor) {
            parse_error = "invalid multipart boundary framing"_s;
            return false;
        }
        cursor = *next_cursor;
        unsigned part_count = 0;

        WTF::Vector<uint8_t> next_delimiter;
        if (!next_delimiter.tryAppend(static_cast<uint8_t>('\r'))
            || !next_delimiter.tryAppend(static_cast<uint8_t>('\n')) || !next_delimiter.tryAppend(delimiter.span())) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return false;
        }
        WTF::Vector<size_t> next_delimiter_table;
        if (!buildByteSearchTable(next_delimiter.span(), next_delimiter_table)) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return false;
        }

        while (cursor < body.size()) {
            if (++part_count > FormDataMultipartMaxParts) {
                parse_error = "multipart part count exceeded"_s;
                return false;
            }
            auto headers_end = findBytes(body, header_end_bytes, cursor);
            if (headers_end == notFound) {
                parse_error = "multipart part missing header terminator"_s;
                return false;
            }
            PartHeaders headers;
            if (!parsePartHeaders(
                    global_object, scope, body.subspan(cursor, headers_end - cursor), headers, parse_error))
                return false;

            size_t data_start = headers_end + 4;
            auto boundary_pos
                = findMultipartDelimiter(body, next_delimiter.span(), next_delimiter_table.span(), data_start, false);
            if (boundary_pos == notFound) {
                parse_error = "multipart body missing final boundary"_s;
                return false;
            }
            auto part_data = body.subspan(data_start, boundary_pos - data_start);
            if (headers.has_filename) {
                auto filename
                    = headers.has_filename_star ? WTF::move(headers.filename_star) : WTF::move(headers.filename);
                bool appended = false;
                if (shared_body_bytes) {
                    // `data_start` is an offset into `body`, and `shared_body_bytes` holds an identical copy of it.
                    appended = form_data->appendParsedFileView(vm, collo_global, WTF::move(headers.name),
                        WTF::Ref<BlobBytes> { *shared_body_bytes }, data_start, part_data.size(),
                        WTF::move(headers.content_type), WTF::move(filename));
                } else {
                    WTF::Vector<uint8_t> copied;
                    if (!copied.tryAppend(part_data)) {
                        JSC::throwOutOfMemoryError(global_object, scope);
                        return false;
                    }
                    appended = form_data->appendParsedFile(vm, collo_global, WTF::move(headers.name), WTF::move(copied),
                        WTF::move(headers.content_type), WTF::move(filename));
                }
                if (!appended) {
                    JSC::throwOutOfMemoryError(global_object, scope);
                    return false;
                }
            } else {
                String value;
                if (!decodeUtf8BytesPreservingBom(global_object, scope, part_data, value))
                    return false;
                if (!form_data->appendString(WTF::move(headers.name), WTF::move(value))) {
                    JSC::throwOutOfMemoryError(global_object, scope);
                    return false;
                }
            }

            cursor = boundary_pos + next_delimiter.size();
            if (isMultipartCloseDelimiterSuffix(body, cursor))
                return true;
            next_cursor = multipartRegularDelimiterSuffixEnd(body, cursor);
            if (!next_cursor) {
                parse_error = "invalid multipart boundary framing"_s;
                return false;
            }
            cursor = *next_cursor;
        }

        parse_error = "multipart body missing final boundary"_s;
        return false;
    }

    // Serialization of a FormData into a multipart/form-data body. The body is a list of BlobSegments: small owned
    // segments hold each part's headers, its text value and the framing, and a File or Blob part appends segments of
    // its own storage. Fetch serves the resulting BlobStorage as a shared-bytes body (body_init.cpp), and the parser
    // above reads it back.
    // FIXME: HTML's multipart/form-data encoding algorithm first turns every lone CR and lone LF in entry names and
    // string values into CRLF. Names and values are written unchanged here.

    static bool appendStringUtf8(WTF::Vector<uint8_t>& out, const String& value)
    {
        if (value.isEmpty())
            return true;
        bool ok = true;
        auto result = value.tryGetUTF8([&](std::span<const char8_t> utf8) -> bool {
            ok = out.tryAppend(std::span<const uint8_t> { reinterpret_cast<const uint8_t*>(utf8.data()), utf8.size() });
            return ok;
        });
        return ok && result && result.value();
    }

    // HTML's multipart/form-data encoding algorithm: in a field name or filename, CR, LF and '"' become %0D, %0A and
    // %22, and every other UTF-8 byte passes through. addEscapedHeaderParameterSize counts the same expansion.
    static bool appendEscapedHeaderParameter(WTF::Vector<uint8_t>& out, const String& value)
    {
        if (value.isEmpty())
            return true;
        bool ok = true;
        auto result = value.tryGetUTF8([&](std::span<const char8_t> utf8) -> bool {
            for (size_t index = 0; index < utf8.size(); index++) {
                auto byte = static_cast<uint8_t>(utf8[index]);
                switch (byte) {
                case '\r':
                    ok = out.tryAppend(std::span<const uint8_t> { reinterpret_cast<const uint8_t*>("%0D"), 3 });
                    break;
                case '\n':
                    ok = out.tryAppend(std::span<const uint8_t> { reinterpret_cast<const uint8_t*>("%0A"), 3 });
                    break;
                case '"':
                    ok = out.tryAppend(std::span<const uint8_t> { reinterpret_cast<const uint8_t*>("%22"), 3 });
                    break;
                default:
                    ok = out.tryAppend(byte);
                    break;
                }
                if (!ok)
                    return false;
            }
            return true;
        });
        return ok && result && result.value();
    }

    static bool appendLiteral(WTF::Vector<uint8_t>& out, WTF::ASCIILiteral literal)
    {
        auto span = literal.span8();
        return out.tryAppend(std::span<const uint8_t> { span.data(), span.size() });
    }

    static MultipartSizeResult addLiteralSize(size_t& total_size, WTF::ASCIILiteral literal)
    {
        auto span = literal.span8();
        return addMultipartSize(total_size, span.size());
    }

    // Builds one part's delimiter line and headers. serializedMultipartBodySize must count exactly the bytes this and
    // buildMultipartBody write: serializeFormDataToMultipartBody asserts that the totals agree.
    static bool buildMultipartPartHeader(std::span<const uint8_t> boundary, const String& name, bool is_file,
        const String& filename, const String& content_type, WTF::Vector<uint8_t>& out)
    {
        if (!appendLiteral(out, "--"_s) || !out.tryAppend(boundary) || !appendLiteral(out, "\r\n"_s))
            return false;
        if (!appendLiteral(out, "Content-Disposition: form-data; name=\""_s))
            return false;
        if (!appendEscapedHeaderParameter(out, name))
            return false;
        if (is_file) {
            if (!appendLiteral(out, "\"; filename=\""_s))
                return false;
            if (!appendEscapedHeaderParameter(out, filename))
                return false;
        }
        if (!appendLiteral(out, "\"\r\n"_s))
            return false;
        if (is_file) {
            if (!appendLiteral(out, "Content-Type: "_s))
                return false;
            // A file part without a type is labeled application/octet-stream, as RFC 7578 (section 4.4) advises.
            if (content_type.isEmpty()) {
                if (!appendLiteral(out, "application/octet-stream"_s))
                    return false;
            } else {
                if (!appendStringUtf8(out, content_type))
                    return false;
            }
            if (!appendLiteral(out, "\r\n"_s))
                return false;
        }
        return appendLiteral(out, "\r\n"_s);
    }

    static bool appendOwnedSegment(WTF::Vector<BlobSegment>& segments, WTF::Vector<uint8_t>&& bytes, size_t& total_size)
    {
        const size_t size = bytes.size();
        if (!size)
            return true;
        if (size > std::numeric_limits<size_t>::max() - total_size)
            return false;
        auto storage = BlobBytes::create(WTF::move(bytes));
        if (!storage || !segments.tryAppend(BlobSegment(storage.releaseNonNull(), 0, size)))
            return false;
        total_size += size;
        return true;
    }

    static MultipartSizeResult serializedMultipartBodySize(
        const WTF::Vector<JSColloFormData::SerializationEntry>& entries, std::span<const uint8_t> boundary,
        size_t& out_size)
    {
        size_t total_size = 0;
        MultipartSizeResult failure = MultipartSizeResult::Ok;

        auto add = [&](MultipartSizeResult result) -> bool {
            if (result == MultipartSizeResult::Ok)
                return true;
            failure = result;
            return false;
        };

        for (const auto& entry : entries) {
            if (!add(addLiteralSize(total_size, "--"_s)) || !add(addMultipartSize(total_size, boundary.size()))
                || !add(addLiteralSize(total_size, "\r\n"_s))
                || !add(addLiteralSize(total_size, "Content-Disposition: form-data; name=\""_s))
                || !add(addEscapedHeaderParameterSize(total_size, entry.name)))
                return failure;

            if (entry.is_file) {
                if (!add(addLiteralSize(total_size, "\"; filename=\""_s))
                    || !add(addEscapedHeaderParameterSize(total_size, entry.filename)))
                    return failure;
            }

            if (!add(addLiteralSize(total_size, "\"\r\n"_s)))
                return failure;

            if (entry.is_file) {
                if (!add(addLiteralSize(total_size, "Content-Type: "_s)))
                    return failure;
                auto type_size = entry.content_type.isEmpty() ? addLiteralSize(total_size, "application/octet-stream"_s)
                                                              : addStringUtf8Size(total_size, entry.content_type);
                if (!add(type_size) || !add(addLiteralSize(total_size, "\r\n"_s)))
                    return failure;
            }

            if (!add(addLiteralSize(total_size, "\r\n"_s)))
                return failure;

            auto value_size = entry.is_file ? addMultipartSize(total_size, entry.size)
                                            : addStringUtf8Size(total_size, entry.string_value);
            if (!add(value_size) || !add(addLiteralSize(total_size, "\r\n"_s)))
                return failure;
        }

        if (!add(addLiteralSize(total_size, "--"_s)) || !add(addMultipartSize(total_size, boundary.size()))
            || !add(addLiteralSize(total_size, "--\r\n"_s)))
            return failure;

        out_size = total_size;
        return MultipartSizeResult::Ok;
    }

    // A boundary carries 128 bits from RAND_bytes, so no content can be prepared to contain it. The serializer still
    // checks the content for each boundary and draws another on a match, so a body never frames wrongly.
    enum class BoundaryGenResult : uint8_t {
        Ok,
        OutOfMemory,
        EntropyFailure,
    };

    static BoundaryGenResult generateMultipartBoundary(WTF::Vector<uint8_t>& out)
    {
        constexpr WTF::ASCIILiteral prefix = "----ColloFormBoundary"_s;
        constexpr size_t random_bytes = 16;
        static constexpr char hex[] = "0123456789abcdef";

        out.shrink(0);
        if (!appendLiteral(out, prefix))
            return BoundaryGenResult::OutOfMemory;

        uint8_t random[random_bytes];
        if (RAND_bytes(random, sizeof(random)) != 1)
            return BoundaryGenResult::EntropyFailure;
        for (size_t index = 0; index < sizeof(random); index++) {
            if (!out.tryAppend(static_cast<uint8_t>(hex[random[index] >> 4]))
                || !out.tryAppend(static_cast<uint8_t>(hex[random[index] & 0x0f])))
                return BoundaryGenResult::OutOfMemory;
        }
        return BoundaryGenResult::Ok;
    }

    // A plain scan suffices: the needle is a generated boundary of a few dozen bytes.
    static bool spanContains(std::span<const uint8_t> haystack, std::span<const uint8_t> needle)
    {
        if (needle.empty() || haystack.size() < needle.size())
            return false;
        for (size_t index = 0; index + needle.size() <= haystack.size(); index++) {
            if (std::memcmp(haystack.data() + index, needle.data(), needle.size()) == 0)
                return true;
        }
        return false;
    }

    static bool stringContainsBoundary(const String& value, std::span<const uint8_t> boundary)
    {
        if (value.isEmpty())
            return false;
        bool found = false;
        auto result = value.tryGetUTF8([&](std::span<const char8_t> utf8) -> bool {
            found = spanContains(
                std::span<const uint8_t> { reinterpret_cast<const uint8_t*>(utf8.data()), utf8.size() }, boundary);
            return true;
        });
        if (!result || !result.value())
            return true; // A failed conversion counts as a match, so the caller draws another boundary.
        return found;
    }

    // `tail` keeps the last boundary.size() - 1 bytes seen, so a match split across segments is found. An allocation
    // failure counts as a match.
    static bool spansContainBoundary(WTF::Vector<BlobSegment>& segments, std::span<const uint8_t> boundary)
    {
        if (boundary.empty())
            return false;

        WTF::Vector<uint8_t, 128> tail;
        const size_t overlap = boundary.size() - 1;
        if (overlap && !tail.tryReserveCapacity(overlap))
            return true;

        for (const auto& segment : segments) {
            auto span = segment.storage->span().subspan(segment.offset, segment.size);
            if (spanContains(span, boundary))
                return true;

            if (!tail.isEmpty()) {
                WTF::Vector<uint8_t, 256> joined;
                if (!joined.tryReserveCapacity(tail.size() + std::min(span.size(), overlap)))
                    return true;
                if (!joined.tryAppend(tail.span()))
                    return true;
                if (overlap) {
                    auto prefix = span.first(std::min(span.size(), overlap));
                    if (!joined.tryAppend(prefix))
                        return true;
                }
                if (spanContains(joined.span(), boundary))
                    return true;
            }

            if (!overlap)
                continue;
            const size_t take_from_span = std::min(span.size(), overlap);
            const size_t take_from_tail = overlap - take_from_span;
            WTF::Vector<uint8_t, 128> next_tail;
            if (!next_tail.tryReserveCapacity(std::min(overlap, tail.size() + span.size())))
                return true;
            if (take_from_tail && !tail.isEmpty()) {
                auto previous = tail.span().last(std::min(tail.size(), take_from_tail));
                if (!next_tail.tryAppend(previous))
                    return true;
            }
            if (take_from_span && !next_tail.tryAppend(span.last(take_from_span)))
                return true;
            tail = WTF::move(next_tail);
        }
        return false;
    }

    static bool storageContainsBoundary(
        const BlobStorage& storage, size_t offset, size_t size, std::span<const uint8_t> boundary)
    {
        WTF::Vector<BlobSegment> segments;
        if (!storage.appendSegmentsTo(segments, offset, size))
            return true;
        return spansContainBoundary(segments, boundary);
    }

    // True if the boundary occurs in an entry's name, value, filename, type or file bytes, where a parser could take
    // it for a delimiter. The framing is not scanned, since it contains the boundary on purpose.
    static bool contentContainsBoundary(
        const WTF::Vector<JSColloFormData::SerializationEntry>& entries, std::span<const uint8_t> boundary)
    {
        for (const auto& entry : entries) {
            if (stringContainsBoundary(entry.name, boundary))
                return true;
            if (entry.is_file) {
                if (stringContainsBoundary(entry.filename, boundary)
                    || stringContainsBoundary(entry.content_type, boundary))
                    return true;
                if (entry.storage && entry.size) {
                    if (storageContainsBoundary(*entry.storage, entry.offset, entry.size, boundary))
                        return true;
                }
            } else if (stringContainsBoundary(entry.string_value, boundary))
                return true;
        }
        return false;
    }

    static WTF::RefPtr<BlobStorage> buildMultipartBody(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        const WTF::Vector<JSColloFormData::SerializationEntry>& entries, size_t& out_size,
        std::span<const uint8_t> boundary)
    {
        WTF::Vector<BlobSegment> segments;
        size_t total_size = 0;

        for (const auto& entry : entries) {
            WTF::Vector<uint8_t> header;
            if (!buildMultipartPartHeader(
                    boundary, entry.name, entry.is_file, entry.filename, entry.content_type, header)) {
                JSC::throwOutOfMemoryError(global_object, scope);
                return nullptr;
            }
            if (!appendOwnedSegment(segments, WTF::move(header), total_size)) {
                JSC::throwOutOfMemoryError(global_object, scope);
                return nullptr;
            }

            if (entry.is_file) {
                if (entry.storage && entry.size) {
                    if (entry.size > std::numeric_limits<size_t>::max() - total_size
                        || !entry.storage->appendSegmentsTo(segments, entry.offset, entry.size)) {
                        JSC::throwOutOfMemoryError(global_object, scope);
                        return nullptr;
                    }
                    total_size += entry.size;
                }
            } else {
                WTF::Vector<uint8_t> value_bytes;
                if (!appendStringUtf8(value_bytes, entry.string_value)) {
                    JSC::throwOutOfMemoryError(global_object, scope);
                    return nullptr;
                }
                if (!appendOwnedSegment(segments, WTF::move(value_bytes), total_size)) {
                    JSC::throwOutOfMemoryError(global_object, scope);
                    return nullptr;
                }
            }

            WTF::Vector<uint8_t> trailer;
            if (!appendLiteral(trailer, "\r\n"_s) || !appendOwnedSegment(segments, WTF::move(trailer), total_size)) {
                JSC::throwOutOfMemoryError(global_object, scope);
                return nullptr;
            }
        }

        WTF::Vector<uint8_t> closing;
        if (!appendLiteral(closing, "--"_s) || !closing.tryAppend(boundary) || !appendLiteral(closing, "--\r\n"_s)
            || !appendOwnedSegment(segments, WTF::move(closing), total_size)) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return nullptr;
        }

        auto storage = BlobStorage::create(WTF::move(segments), total_size);
        if (!storage) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return nullptr;
        }
        out_size = total_size;
        return storage;
    }

    JSC_DEFINE_HOST_FUNCTION(formDataConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        return JSC::throwVMTypeError(global_object, scope, "FormData constructor requires 'new'"_s);
    }

    JSC_DEFINE_HOST_FUNCTION(
        formDataConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        if (call_frame->argumentCount() > 0 && !call_frame->argument(0).isUndefined())
            return JSC::throwVMTypeError(
                global_object, scope, "FormData form construction is not available in this runtime"_s);

        auto* structure = formDataStructureForNewTarget(global_object, scope, call_frame);
        RETURN_IF_EXCEPTION(scope, {});
        auto* form_data = JSColloFormData::create(vm, structure);
        return JSValue::encode(form_data);
    }

    struct FormDataFromEncoding {
        WTF::String content_type;
        WTF::Vector<uint8_t> boundary;
        bool has_boundary { false };
    };

    static JSC::JSObject* createFormDataFromRawMultipartBodyBytes(JSC::JSGlobalObject*, JSC::ThrowScope&,
        std::span<const uint8_t>, std::span<const uint8_t>, WTF::ASCIILiteral* out_parse_error = nullptr);

    static bool parseFormDataFromEncoding(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        JSC::CallFrame* call_frame, const String& fallback_type, FormDataFromEncoding& out)
    {
        if (call_frame->argumentCount() <= 1 || call_frame->argument(1).isUndefined()) {
            out.content_type = fallback_type.isEmpty() ? "application/x-www-form-urlencoded"_s : fallback_type;
            return true;
        }

        auto boundary_value = call_frame->argument(1);
        if (auto* view = dynamicDowncast<JSC::JSArrayBufferView>(boundary_value)) {
            if (!validateArrayBufferViewForCopy(global_object, scope, view,
                    "FormData.from boundary ArrayBufferView is detached or out of bounds"_s))
                return false;
            out.has_boundary = true;
            if (appendBoundaryBytes(global_object, scope, arrayBufferViewBytes(view), out.boundary))
                return true;
            if (!scope.exception())
                JSC::throwVMTypeError(global_object, scope, "invalid multipart boundary"_s);
            return false;
        }

        if (auto* buffer = dynamicDowncast<JSC::JSArrayBuffer>(boundary_value)) {
            if (!validateArrayBufferForCopy(global_object, scope, buffer,
                    "FormData.from boundary must be a fixed-length attached ArrayBuffer"_s))
                return false;
            out.has_boundary = true;
            if (appendBoundaryBytes(global_object, scope, arrayBufferBytes(buffer), out.boundary))
                return true;
            if (!scope.exception())
                JSC::throwVMTypeError(global_object, scope, "invalid multipart boundary"_s);
            return false;
        }

        auto boundary = argumentToWebApiString(global_object, scope, call_frame, 1);
        RETURN_IF_EXCEPTION(scope, false);
        out.has_boundary = true;
        if (appendBoundaryBytes(global_object, scope, WTF::move(boundary), out.boundary))
            return true;
        if (!scope.exception())
            JSC::throwVMTypeError(global_object, scope, "invalid multipart boundary"_s);
        return false;
    }

    static JSC::JSObject* createFormDataFromBodyBytesWithEncoding(JSC::JSGlobalObject* global_object,
        JSC::ThrowScope& scope, std::span<const uint8_t> bytes, FormDataFromEncoding&& encoding)
    {
        if (encoding.has_boundary)
            return createFormDataFromRawMultipartBodyBytes(global_object, scope, bytes, encoding.boundary.span());
        return createFormDataFromBodyBytes(global_object, scope, bytes, WTF::move(encoding.content_type));
    }

    JSC_DEFINE_HOST_FUNCTION(formDataFrom, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        if (call_frame->argumentCount() == 0 || call_frame->argument(0).isUndefinedOrNull())
            return JSC::throwVMTypeError(global_object, scope, "input must not be empty"_s);

        auto input = call_frame->argument(0);
        if (auto* blob = dynamicDowncast<JSColloBlob>(input)) {
            FormDataFromEncoding encoding;
            if (!parseFormDataFromEncoding(global_object, scope, call_frame, blob->type(), encoding))
                return {};
            RETURN_IF_EXCEPTION(scope, {});
            if (!ensureFormDataBodyBytesWithinLimit(global_object, scope, blob->size()))
                return {};
            WTF::Vector<uint8_t> bytes;
            if (!blob->appendBytes(bytes))
                return JSValue::encode(JSC::throwOutOfMemoryError(global_object, scope));
            auto* form_data
                = createFormDataFromBodyBytesWithEncoding(global_object, scope, bytes.span(), WTF::move(encoding));
            RETURN_IF_EXCEPTION(scope, {});
            if (!form_data)
                return {};
            return JSValue::encode(form_data);
        }

        if (auto* view = dynamicDowncast<JSC::JSArrayBufferView>(input)) {
            FormDataFromEncoding encoding;
            if (!parseFormDataFromEncoding(global_object, scope, call_frame, emptyString(), encoding))
                return {};
            RETURN_IF_EXCEPTION(scope, {});
            if (!validateArrayBufferViewForCopy(
                    global_object, scope, view, "input must not be a detached or out-of-bounds ArrayBufferView"_s))
                return {};
            auto* form_data = createFormDataFromBodyBytesWithEncoding(
                global_object, scope, arrayBufferViewBytes(view), WTF::move(encoding));
            RETURN_IF_EXCEPTION(scope, {});
            if (!form_data)
                return {};
            return JSValue::encode(form_data);
        }

        if (auto* buffer = dynamicDowncast<JSC::JSArrayBuffer>(input)) {
            FormDataFromEncoding encoding;
            if (!parseFormDataFromEncoding(global_object, scope, call_frame, emptyString(), encoding))
                return {};
            RETURN_IF_EXCEPTION(scope, {});
            if (!validateArrayBufferForCopy(
                    global_object, scope, buffer, "input must be a fixed-length attached ArrayBuffer"_s))
                return {};
            auto* form_data = createFormDataFromBodyBytesWithEncoding(
                global_object, scope, arrayBufferBytes(buffer), WTF::move(encoding));
            RETURN_IF_EXCEPTION(scope, {});
            if (!form_data)
                return {};
            return JSValue::encode(form_data);
        }

        if (!input.isString())
            return JSC::throwVMTypeError(global_object, scope, "input must be a string or ArrayBufferView"_s);

        FormDataFromEncoding encoding;
        if (!parseFormDataFromEncoding(global_object, scope, call_frame, emptyString(), encoding))
            return {};
        RETURN_IF_EXCEPTION(scope, {});
        auto text = input.toWTFString(global_object);
        RETURN_IF_EXCEPTION(scope, {});
        if (!ensureFormDataStringUtf8BodyWithinLimit(global_object, scope, text))
            return {};
        auto utf8 = text.utf8();
        auto* form_data = createFormDataFromBodyBytesWithEncoding(global_object, scope,
            std::span<const uint8_t> { reinterpret_cast<const uint8_t*>(utf8.data()), utf8.length() },
            WTF::move(encoding));
        RETURN_IF_EXCEPTION(scope, {});
        if (!form_data)
            return {};
        return JSValue::encode(form_data);
    }

    JSC_DEFINE_HOST_FUNCTION(formDataAppend, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* form_data = requireFormData(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (!requireArgumentCount(global_object, scope, call_frame, 2, "FormData.append requires a name and value"_s))
            return {};

        // A filename with a value that is not a Blob throws before the name is converted, so the name's toString()
        // never runs.
        // FIXME: WebIDL overload resolution leaves only the Blob overload for three arguments and converts the name
        // before it rejects the value, so the name's toString() should run first.
        auto value = call_frame->argument(1);
        auto* blob = dynamicDowncast<JSColloBlob>(value);
        const bool has_filename = hasFilenameArgument(call_frame);
        if (has_filename && !blob)
            return JSC::throwVMTypeError(global_object, scope, "FormData.append filename requires a Blob value"_s);

        auto name = formDataUSVArgument(global_object, scope, call_frame, 0);
        RETURN_IF_EXCEPTION(scope, {});

        if (blob) {
            String filename;
            if (has_filename) {
                filename = formDataUSVArgument(global_object, scope, call_frame, 2);
                RETURN_IF_EXCEPTION(scope, {});
            }
            if (!form_data->appendFile(vm, uncheckedDowncast<Collo::GlobalObject>(global_object), WTF::move(name),
                    *blob, value, has_filename, WTF::move(filename)))
                return JSValue::encode(JSC::throwOutOfMemoryError(global_object, scope));
        } else {
            auto string_value = toWebApiUSVString(valueToWebApiString(global_object, scope, value));
            RETURN_IF_EXCEPTION(scope, {});
            if (!form_data->appendString(WTF::move(name), WTF::move(string_value)))
                return JSValue::encode(JSC::throwOutOfMemoryError(global_object, scope));
        }
        return JSValue::encode(JSC::jsUndefined());
    }

    JSC_DEFINE_HOST_FUNCTION(formDataDelete, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* form_data = requireFormData(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (!requireArgumentCount(global_object, scope, call_frame, 1, "FormData.delete requires a name"_s))
            return {};

        auto name = formDataUSVArgument(global_object, scope, call_frame, 0);
        RETURN_IF_EXCEPTION(scope, {});
        form_data->remove(name);
        return JSValue::encode(JSC::jsUndefined());
    }

    JSC_DEFINE_HOST_FUNCTION(formDataGet, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* form_data = requireFormData(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (!requireArgumentCount(global_object, scope, call_frame, 1, "FormData.get requires a name"_s))
            return {};

        auto name = formDataUSVArgument(global_object, scope, call_frame, 0);
        RETURN_IF_EXCEPTION(scope, {});
        for (auto& entry : form_data->entries()) {
            if (entry.name == name)
                return JSValue::encode(entryValue(vm, entry));
        }
        return JSValue::encode(JSC::jsNull());
    }

    JSC_DEFINE_HOST_FUNCTION(formDataGetAll, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* form_data = requireFormData(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (!requireArgumentCount(global_object, scope, call_frame, 1, "FormData.getAll requires a name"_s))
            return {};

        auto name = formDataUSVArgument(global_object, scope, call_frame, 0);
        RETURN_IF_EXCEPTION(scope, {});
        auto* result = JSC::constructEmptyArray(global_object, nullptr);
        RETURN_IF_EXCEPTION(scope, {});
        if (!result)
            return JSValue::encode(JSC::throwOutOfMemoryError(global_object, scope));
        unsigned index = 0;
        for (auto& entry : form_data->entries()) {
            if (entry.name == name) {
                result->putDirectIndex(global_object, index++, entryValue(vm, entry));
                RETURN_IF_EXCEPTION(scope, {});
            }
        }
        return JSValue::encode(result);
    }

    JSC_DEFINE_HOST_FUNCTION(formDataHas, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* form_data = requireFormData(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (!requireArgumentCount(global_object, scope, call_frame, 1, "FormData.has requires a name"_s))
            return {};

        auto name = formDataUSVArgument(global_object, scope, call_frame, 0);
        RETURN_IF_EXCEPTION(scope, {});
        for (auto& entry : form_data->entries()) {
            if (entry.name == name)
                return JSValue::encode(JSC::jsBoolean(true));
        }
        return JSValue::encode(JSC::jsBoolean(false));
    }

    JSC_DEFINE_HOST_FUNCTION(formDataSet, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* form_data = requireFormData(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (!requireArgumentCount(global_object, scope, call_frame, 2, "FormData.set requires a name and value"_s))
            return {};

        // Same argument order as formDataAppend, with the same FIXME.
        auto value = call_frame->argument(1);
        auto* blob = dynamicDowncast<JSColloBlob>(value);
        const bool has_filename = hasFilenameArgument(call_frame);
        if (has_filename && !blob)
            return JSC::throwVMTypeError(global_object, scope, "FormData.set filename requires a Blob value"_s);

        auto name = formDataUSVArgument(global_object, scope, call_frame, 0);
        RETURN_IF_EXCEPTION(scope, {});

        if (blob) {
            String filename;
            if (has_filename) {
                filename = formDataUSVArgument(global_object, scope, call_frame, 2);
                RETURN_IF_EXCEPTION(scope, {});
            }
            if (!form_data->setFile(vm, uncheckedDowncast<Collo::GlobalObject>(global_object), WTF::move(name), *blob,
                    value, has_filename, WTF::move(filename)))
                return JSValue::encode(JSC::throwOutOfMemoryError(global_object, scope));
        } else {
            auto string_value = toWebApiUSVString(valueToWebApiString(global_object, scope, value));
            RETURN_IF_EXCEPTION(scope, {});
            if (!form_data->setString(WTF::move(name), WTF::move(string_value)))
                return JSValue::encode(JSC::throwOutOfMemoryError(global_object, scope));
        }
        return JSValue::encode(JSC::jsUndefined());
    }

    JSC_DEFINE_HOST_FUNCTION(formDataGetLength, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* form_data = requireFormData(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(JSC::jsNumber(form_data->entries().size()));
    }

    struct FormDataJSONGroup {
        String name;
        unsigned first_index { 0 };
        unsigned count { 0 };
    };

    JSC_DEFINE_HOST_FUNCTION(formDataToJSON, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* form_data = requireFormData(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});

        WTF::Vector<FormDataJSONGroup, 4> groups;
        for (unsigned entry_index = 0; entry_index < form_data->entries().size(); entry_index++) {
            auto& entry = form_data->entries()[entry_index];
            FormDataJSONGroup* group = nullptr;
            for (auto& candidate : groups) {
                if (candidate.name == entry.name) {
                    group = &candidate;
                    break;
                }
            }
            if (!group) {
                FormDataJSONGroup new_group { entry.name, entry_index, 0 };
                if (!groups.tryAppend(WTF::move(new_group)))
                    return JSValue::encode(JSC::throwOutOfMemoryError(global_object, scope));
                group = &groups.last();
            }
            group->count++;
        }

        auto* output = JSC::constructEmptyObject(global_object, global_object->objectPrototype(), groups.size());
        RETURN_IF_EXCEPTION(scope, {});
        if (!output)
            return JSValue::encode(JSC::throwOutOfMemoryError(global_object, scope));
        for (auto& group : groups) {
            auto identifier = JSC::Identifier::fromString(vm, group.name);
            if (group.count == 1) {
                output->putDirectMayBeIndex(
                    global_object, identifier, entryValue(vm, form_data->entries()[group.first_index]));
                RETURN_IF_EXCEPTION(scope, {});
                continue;
            }

            auto* array = JSC::constructEmptyArray(global_object, nullptr, group.count);
            RETURN_IF_EXCEPTION(scope, {});
            if (!array)
                return JSValue::encode(JSC::throwOutOfMemoryError(global_object, scope));
            unsigned value_index = 0;
            for (auto& entry : form_data->entries()) {
                if (entry.name == group.name) {
                    array->putDirectIndex(global_object, value_index++, entryValue(vm, entry));
                    RETURN_IF_EXCEPTION(scope, {});
                }
            }
            output->putDirectMayBeIndex(global_object, identifier, array);
            RETURN_IF_EXCEPTION(scope, {});
        }

        return JSValue::encode(output);
    }

    JSC_DEFINE_HOST_FUNCTION(formDataForEach, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* form_data = requireFormData(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (!requireArgumentCount(global_object, scope, call_frame, 1, "FormData.forEach requires a callback"_s))
            return {};

        auto callback = call_frame->argument(0);
        auto call_data = JSC::getCallData(callback);
        if (call_data.type == JSC::CallData::Type::None)
            return JSC::throwVMTypeError(global_object, scope, "FormData.forEach callback must be a function"_s);

        auto this_arg = call_frame->argument(1);
        // WebIDL's forEach for a pair iterable rereads the list after every callback, so the size is checked again on
        // each step: entries the callback appends are visited, and removing entries ends the loop early.
        for (unsigned index = 0; index < form_data->size(); index++) {
            JSColloFormData::EntrySnapshot snapshot;
            if (!form_data->entryAt(index, snapshot))
                break;
            JSValue value = snapshot.is_file ? snapshot.file_value : JSValue(JSC::jsString(vm, snapshot.string_value));
            JSC::MarkedArgumentBuffer arguments;
            arguments.append(value);
            arguments.append(JSC::jsString(vm, snapshot.name));
            arguments.append(form_data);
            if (arguments.hasOverflowed())
                return JSValue::encode(JSC::throwOutOfMemoryError(global_object, scope));
            JSC::call(global_object, callback, call_data, this_arg, arguments);
            RETURN_IF_EXCEPTION(scope, {});
        }
        return JSValue::encode(JSC::jsUndefined());
    }

    static JSValue createFormDataIterator(
        JSC::JSGlobalObject* global_object, JSColloFormData* form_data, FormDataIteratorKind kind)
    {
        auto& vm = global_object->vm();
        return JSColloFormDataIterator::create(
            vm, uncheckedDowncast<Collo::GlobalObject>(global_object), form_data, kind);
    }

    JSC_DEFINE_HOST_FUNCTION(formDataEntries, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* form_data = requireFormData(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(createFormDataIterator(global_object, form_data, FormDataIteratorKind::Entries));
    }

    JSC_DEFINE_HOST_FUNCTION(formDataKeys, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* form_data = requireFormData(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(createFormDataIterator(global_object, form_data, FormDataIteratorKind::Keys));
    }

    JSC_DEFINE_HOST_FUNCTION(formDataValues, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* form_data = requireFormData(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(createFormDataIterator(global_object, form_data, FormDataIteratorKind::Values));
    }

    JSC_DEFINE_HOST_FUNCTION(formDataIteratorNext, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* iterator = requireFormDataIterator(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});

        auto* form_data = iterator->formData();
        if (!form_data)
            return JSValue::encode(JSC::createIteratorResultObject(global_object, JSC::jsUndefined(), true));
        auto index = iterator->takeIndex(form_data->size());
        if (!index)
            return JSValue::encode(JSC::createIteratorResultObject(global_object, JSC::jsUndefined(), true));

        // takeIndex checked the index against the current size, so entryAt fails only if that check was wrong; a
        // failure ends the iteration.
        JSColloFormData::EntrySnapshot snapshot;
        if (!form_data->entryAt(*index, snapshot))
            return JSValue::encode(JSC::createIteratorResultObject(global_object, JSC::jsUndefined(), true));

        JSValue entry_value
            = snapshot.is_file ? snapshot.file_value : JSValue(JSC::jsString(vm, snapshot.string_value));
        JSValue value;
        switch (iterator->kind()) {
        case FormDataIteratorKind::Entries:
            value = JSC::constructArrayPair(global_object, JSC::jsString(vm, snapshot.name), entry_value);
            break;
        case FormDataIteratorKind::Keys:
            value = JSC::jsString(vm, snapshot.name);
            break;
        case FormDataIteratorKind::Values:
            value = entry_value;
            break;
        }
        return JSValue::encode(JSC::createIteratorResultObject(global_object, value, false));
    }

    JSC_DEFINE_HOST_FUNCTION(formDataIteratorIterator, (JSC::JSGlobalObject*, JSC::CallFrame* call_frame))
    {
        return JSValue::encode(call_frame->thisValue());
    }

    static JSC::JSObject* failBodyFormDataParse(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        WTF::ASCIILiteral message, WTF::ASCIILiteral* out_parse_error)
    {
        if (out_parse_error) {
            *out_parse_error = message;
            return nullptr;
        }
        JSC::throwVMTypeError(global_object, scope, message);
        return nullptr;
    }

    static JSC::JSObject* failBodyFormDataQuota(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        WTF::ASCIILiteral message, WTF::ASCIILiteral* out_parse_error)
    {
        if (out_parse_error) {
            *out_parse_error = message;
            return nullptr;
        }
        auto* exception = createDOMException(global_object, DOMExceptionCode::QuotaExceededError, String(message));
        JSC::throwException(global_object, scope, exception);
        return nullptr;
    }

    static JSC::JSObject* createFormDataFromRawMultipartBodyBytes(JSC::JSGlobalObject* global_object,
        JSC::ThrowScope& scope, std::span<const uint8_t> bytes, std::span<const uint8_t> boundary,
        WTF::ASCIILiteral* out_parse_error)
    {
        if (!ensureFormDataBodyBytesWithinLimit(global_object, scope, bytes.size(), out_parse_error))
            return nullptr;

        auto& vm = global_object->vm();
        auto* form_data
            = JSColloFormData::create(vm, uncheckedDowncast<Collo::GlobalObject>(global_object)->formDataStructure());
        std::optional<WTF::ASCIILiteral> parse_error;

        // `bytes` is borrowed for the call, so the body is copied once into a BlobBytes that every parsed File views.
        // The parser's offsets into `bytes` are valid in the copy.
        WTF::RefPtr<BlobBytes> shared_body_bytes;
        if (!bytes.empty()) {
            WTF::Vector<uint8_t> body_copy;
            if (!body_copy.tryAppend(bytes)) {
                JSC::throwOutOfMemoryError(global_object, scope);
                return nullptr;
            }
            shared_body_bytes = BlobBytes::create(WTF::move(body_copy));
            if (!shared_body_bytes) {
                JSC::throwOutOfMemoryError(global_object, scope);
                return nullptr;
            }
        }

        if (!appendMultipartEntries(
                global_object, scope, form_data, bytes, boundary, parse_error, shared_body_bytes.get())) {
            if (scope.exception())
                return nullptr;
            auto message = parse_error.value_or("Invalid multipart form data"_s);
            if (isFormDataQuotaParseError(message))
                return failBodyFormDataQuota(global_object, scope, message, out_parse_error);
            return failBodyFormDataParse(global_object, scope, message, out_parse_error);
        }

        RETURN_IF_EXCEPTION(scope, nullptr);
        return form_data;
    }

} // namespace

bool isFormDataQuotaParseError(WTF::ASCIILiteral message)
{
    return message == "multipart part count exceeded"_s || message == "multipart part header count exceeded"_s
        || message == "form data entry count exceeded"_s || message == FormDataBodyBytesExceeded;
}

JSC::JSObject* createFormDataBodyQuotaExceeded(JSC::JSGlobalObject* global_object)
{
    return createDOMException(global_object, DOMExceptionCode::QuotaExceededError, String(FormDataBodyBytesExceeded));
}

bool isColloFormData(JSC::JSValue value) { return dynamicDowncast<JSColloFormData>(value) != nullptr; }

JSC::JSObject* createFormDataFromBodyBytes(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    std::span<const uint8_t> bytes, WTF::String content_type, WTF::ASCIILiteral* out_parse_error)
{
    if (!ensureFormDataBodyBytesWithinLimit(global_object, scope, bytes.size(), out_parse_error))
        return nullptr;

    std::optional<WTF::ASCIILiteral> parse_error;
    auto parsed = parseBodyContentType(global_object, scope, WTF::move(content_type), parse_error);
    RETURN_IF_EXCEPTION(scope, nullptr);
    if (!parsed)
        return failBodyFormDataParse(global_object, scope,
            parse_error.value_or("Body.formData requires a form content type"_s), out_parse_error);

    switch (parsed->encoding) {
    case BodyFormEncoding::UrlEncoded: {
        auto& vm = global_object->vm();
        auto* form_data
            = JSColloFormData::create(vm, uncheckedDowncast<Collo::GlobalObject>(global_object)->formDataStructure());
        if (!appendUrlEncodedEntries(global_object, scope, form_data, bytes, parse_error)) {
            if (scope.exception())
                return nullptr;
            auto message = parse_error.value_or("Invalid form data"_s);
            if (isFormDataQuotaParseError(message))
                return failBodyFormDataQuota(global_object, scope, message, out_parse_error);
            return failBodyFormDataParse(global_object, scope, message, out_parse_error);
        }
        RETURN_IF_EXCEPTION(scope, nullptr);
        return form_data;
    }
    case BodyFormEncoding::Multipart:
        return createFormDataFromRawMultipartBodyBytes(
            global_object, scope, bytes, parsed->boundary.span(), out_parse_error);
    }

    RETURN_IF_EXCEPTION(scope, nullptr);
    return nullptr;
}

WTF::RefPtr<BlobStorage> serializeFormDataToMultipartBody(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    JSC::JSValue form_data_value, size_t& out_size, WTF::String& out_content_type)
{
    out_size = 0;
    out_content_type = WTF::emptyString();

    auto* form_data = dynamicDowncast<JSColloFormData>(form_data_value);
    if (!form_data)
        return nullptr;

    WTF::Vector<JSColloFormData::SerializationEntry> entries;
    if (!form_data->snapshotForSerialization(entries)) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return nullptr;
    }

    WTF::Vector<uint8_t> boundary;
    // Content matching a random 128-bit boundary is vanishingly unlikely, so a few attempts suffice. Running out of
    // them throws instead of emitting a body that frames wrongly.
    constexpr unsigned maxBoundaryAttempts = 8;
    bool boundary_ready = false;
    bool serialized_size_ready = false;
    size_t serialized_size_boundary_length = 0;
    size_t serialized_size = 0;
    for (unsigned attempt = 0; attempt < maxBoundaryAttempts; attempt++) {
        switch (generateMultipartBoundary(boundary)) {
        case BoundaryGenResult::Ok:
            break;
        case BoundaryGenResult::OutOfMemory:
            JSC::throwOutOfMemoryError(global_object, scope);
            return nullptr;
        case BoundaryGenResult::EntropyFailure:
            JSC::throwException(global_object, scope,
                JSC::createError(global_object, "failed to generate a secure multipart boundary"_s));
            return nullptr;
        }
        if (!serialized_size_ready || serialized_size_boundary_length != boundary.size()) {
            switch (serializedMultipartBodySize(entries, boundary.span(), serialized_size)) {
            case MultipartSizeResult::Ok:
                serialized_size_ready = true;
                serialized_size_boundary_length = boundary.size();
                break;
            case MultipartSizeResult::Exceeded:
                JSC::throwException(global_object, scope, createFormDataBodyQuotaExceeded(global_object));
                return nullptr;
            }
        }
        if (!contentContainsBoundary(entries, boundary.span())) {
            boundary_ready = true;
            break;
        }
    }
    if (!boundary_ready) {
        JSC::throwVMTypeError(global_object, scope, "could not generate a unique multipart boundary"_s);
        return nullptr;
    }

    size_t size = 0;
    auto storage = buildMultipartBody(global_object, scope, entries, size, boundary.span());
    RETURN_IF_EXCEPTION(scope, nullptr);
    if (!storage)
        return nullptr;
    RELEASE_ASSERT(serialized_size_ready);
    RELEASE_ASSERT(size == serialized_size);

    WTF::StringBuilder builder;
    builder.append("multipart/form-data; boundary="_s);
    // The boundary is ASCII (a fixed prefix and lowercase hex), so its bytes are its Latin-1 characters;
    // Latin1Character is uint8_t.
    builder.append(std::span<const Latin1Character> { boundary.span().data(), boundary.size() });
    out_content_type = builder.toString();
    if (out_content_type.isNull()) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return nullptr;
    }
    out_size = size;
    return storage;
}

static std::span<const uint8_t> formDataBufferSpan(ColloBuffer buffer)
{
    if (!buffer.ptr || buffer.len == 0)
        return {};
    return { buffer.ptr, buffer.len };
}

extern "C" ColloStatus collo_form_data_new_from_bytes(
    ColloVm* vm, ColloBuffer bytes, ColloString content_type, ColloValue** out_value, ColloValue** out_exception)
{
    if (out_value)
        *out_value = nullptr;
    Collo::clearOutException(out_exception);
    if (!vm || !vm->isReady() || !out_value || (bytes.len != 0 && !bytes.ptr))
        return COLLO_STATUS_INVALID_ARGUMENT;

    WTF::String type;
    if (Collo::stringToWTFString(content_type, type) != COLLO_STATUS_OK)
        return COLLO_STATUS_INVALID_ARGUMENT;

    JSC::JSLockHolder locker(*vm->vm);
    auto scope = DECLARE_THROW_SCOPE(*vm->vm);
    auto* form_data = createFormDataFromBodyBytes(vm->global_object, scope, formDataBufferSpan(bytes), WTF::move(type));
    if (scope.exception())
        return consumeExceptionStatus(vm, scope, out_exception);
    if (!form_data)
        return COLLO_STATUS_ERROR;
    return Collo::makeValueHandle(vm, form_data, out_value);
}

void installWebApiFormData(Collo::GlobalObject* global_object, JSC::VM& vm)
{
    constexpr unsigned enumerableFunction = static_cast<unsigned>(JSC::PropertyAttribute::None);
    constexpr unsigned enumerableReadOnlyDontDelete
        = static_cast<unsigned>(JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontDelete);

    auto* prototype = JSC::constructEmptyObject(global_object);
    putWebApiFunction(global_object, prototype, vm, "append"_s, 2, formDataAppend, enumerableFunction);
    putWebApiFunction(global_object, prototype, vm, "delete"_s, 1, formDataDelete, enumerableFunction);
    putWebApiFunction(global_object, prototype, vm, "get"_s, 1, formDataGet, enumerableFunction);
    putWebApiFunction(global_object, prototype, vm, "getAll"_s, 1, formDataGetAll, enumerableFunction);
    putWebApiFunction(global_object, prototype, vm, "has"_s, 1, formDataHas, enumerableFunction);
    putWebApiFunction(global_object, prototype, vm, "set"_s, 2, formDataSet, enumerableFunction);
    auto* entries_function = JSC::JSFunction::create(
        vm, global_object, 0, "entries"_s, formDataEntries, JSC::ImplementationVisibility::Public);
    RELEASE_ASSERT(entries_function);
    JSC::Identifier entries_identifier = JSC::Identifier::fromString(vm, "entries"_s);
    prototype->putDirect(vm, entries_identifier, entries_function);
    RELEASE_ASSERT(prototype->getDirect(vm, entries_identifier));
    prototype->putDirect(vm, vm.propertyNames->iteratorSymbol, entries_function,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    putWebApiFunction(global_object, prototype, vm, "keys"_s, 0, formDataKeys, enumerableFunction);
    putWebApiFunction(global_object, prototype, vm, "values"_s, 0, formDataValues, enumerableFunction);
    putWebApiFunction(global_object, prototype, vm, "forEach"_s, 1, formDataForEach, enumerableFunction);
    putWebApiFunction(global_object, prototype, vm, "toJSON"_s, 0, formDataToJSON, enumerableReadOnlyDontDelete);
    putWebApiAccessor(global_object, prototype, vm, "length"_s, formDataGetLength, nullptr,
        static_cast<unsigned>(
            JSC::PropertyAttribute::Accessor | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete));
    prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol, JSC::jsString(vm, WTF::makeString("FormData"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    auto* constructor = JSC::JSFunction::create(vm, global_object, 0, "FormData"_s, formDataConstructorCall,
        JSC::ImplementationVisibility::Public, JSC::NoIntrinsic, formDataConstructorConstruct, nullptr);
    RELEASE_ASSERT(constructor);
    constructor->putDirect(vm, vm.propertyNames->prototype, prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    putWebApiFunction(global_object, constructor, vm, "from"_s, 1, formDataFrom, enumerableReadOnlyDontDelete);
    prototype->putDirect(
        vm, vm.propertyNames->constructor, constructor, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    JSC::Identifier identifier = JSC::Identifier::fromString(vm, "FormData"_s);
    global_object->putDirect(vm, identifier, constructor, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    RELEASE_ASSERT(global_object->getDirect(vm, identifier));

    auto* iterator_prototype = JSC::constructEmptyObject(global_object);
    putWebApiFunction(global_object, iterator_prototype, vm, "next"_s, 0, formDataIteratorNext);
    auto* iterator_function = JSC::JSFunction::create(
        vm, global_object, 0, "[Symbol.iterator]"_s, formDataIteratorIterator, JSC::ImplementationVisibility::Public);
    RELEASE_ASSERT(iterator_function);
    iterator_prototype->putDirect(vm, vm.propertyNames->iteratorSymbol, iterator_function,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    iterator_prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol,
        JSC::jsString(vm, WTF::makeString("FormData Iterator"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    global_object->cacheFormDataApi(constructor, prototype,
        JSColloFormData::createStructure(vm, global_object, prototype), iterator_prototype,
        JSColloFormDataIterator::createStructure(vm, global_object, iterator_prototype));
}

} // namespace Collo::HostFunctions

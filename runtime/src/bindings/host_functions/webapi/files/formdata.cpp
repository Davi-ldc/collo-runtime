// FormData: the cell and its iterator, the methods, the form body parsing behind Body.formData(), Blob.formData() and
// collo_form_data_new_from_bytes, and the entry snapshot behind a FormData request or response body. The multipart
// codec itself is in multipart.cpp. Runs on the VM thread, except visitChildren, which marking threads run
// concurrently.
//
// The entry list is a Collo::CellEdgeList (jsc/runtime/cell_edges.h), which runs the lock and barrier protocol
// visitChildren relies on; nothing here takes the cell lock itself. Code that runs JavaScript between reads copies
// each entry out first, because the callback may change the list. Every non-empty File parsed from one multipart body
// views its range of one BlobStorage over a copy of the whole body, so each keeps the whole body alive, and the
// collector counts the copy once however many Files share it.

#include "host_functions/webapi/files/formdata.h"

#include "host_functions/webapi/dom/dom_exception.h"
#include "host_functions/webapi/encoding/utf8.h"
#include "host_functions/webapi/files/multipart.h"
#include "host_functions/webapi/limits.h"
#include "jsc/runtime/cell_edges.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/IdentifierInlines.h>
#include <JavaScriptCore/InternalFunction.h>
#include <JavaScriptCore/IteratorOperations.h>
#include <JavaScriptCore/JSArray.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSDestructibleObject.h>
#include <JavaScriptCore/JSFunction.h>
#include <JavaScriptCore/JSObject.h>
#include <JavaScriptCore/JSString.h>
#include <JavaScriptCore/SlotVisitorMacros.h>
#include <wtf/URLParser.h>
#include <wtf/Vector.h>
#include <wtf/WallTime.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringView.h>
#include <wtf/text/WTFString.h>

#include <atomic>
#include <optional>
#include <span>

namespace Collo::HostFunctions {
namespace {

    using JSC::EncodedJSValue;
    using JSC::JSValue;
    using WTF::String;
    using namespace JSC;

    constexpr auto FormDataBodyBytesExceeded = "form data body exceeds the body size limit"_s;

    size_t formDataStringMemoryCost(const String& value)
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

            template <typename Visitor> void visitEdges(Visitor& visitor) const { visitor.append(file_value); }
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

        // The off-heap memory this cell retains itself: a slot and the name and value strings of each entry. File
        // entries are cells that report their own bytes.
        size_t memoryCost() const { return m_memory_cost.load(std::memory_order_relaxed); }

        const Collo::CellEdgeList<Entry>& entries() const { return m_entries; }

        // Copies every entry into `out` for the multipart serializer. A File or Blob entry becomes a reference to its
        // storage with its offset and size, sharing the bytes. Returns false on allocation failure.
        bool snapshotForSerialization(WTF::Vector<MultipartSerializedEntry>& out) const
        {
            if (!out.tryReserveCapacity(m_entries.size()))
                return false;
            for (const auto& entry : m_entries) {
                MultipartSerializedEntry snapshot;
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
                out.append(WTF::move(snapshot));
            }
            return true;
        }

        bool appendString(String name, String value)
        {
            Entry entry;
            entry.name = WTF::move(name);
            entry.string_value = WTF::move(value);
            return appendEntry(vm(), WTF::move(entry));
        }

        bool appendFile(JSC::VM& vm, Collo::GlobalObject* global_object, String name, JSColloBlob& blob,
            JSValue original_value, bool has_filename, String filename)
        {
            auto entry = createFileEntry(
                vm, global_object, WTF::move(name), blob, original_value, has_filename, WTF::move(filename));
            return appendEntry(vm, WTF::move(entry));
        }

        // Appends a File that views `size` bytes at `offset` of `body`, the storage over the copy of the whole
        // multipart body that every File parsed from it shares.
        bool appendParsedFileView(JSC::VM& vm, Collo::GlobalObject* global_object, String name,
            WTF::Ref<BlobStorage>&& body, size_t offset, size_t size, String type, String filename)
        {
            Entry entry;
            entry.name = WTF::move(name);
            entry.is_file = true;
            auto last_modified = WTF::WallTime::now().secondsSinceEpoch().milliseconds();
            auto* file = JSColloFile::create(vm, global_object->fileStructure(), WTF::move(body), offset, size,
                WTF::move(type), WTF::move(filename), last_modified);
            entry.file_value.setWithoutWriteBarrier(file);
            return appendEntry(vm, WTF::move(entry));
        }

        bool setString(String name, String value)
        {
            Entry entry;
            entry.name = name;
            entry.string_value = WTF::move(value);
            return setEntry(vm(), name, WTF::move(entry));
        }

        bool setFile(JSC::VM& vm, Collo::GlobalObject* global_object, String name, JSColloBlob& blob,
            JSValue original_value, bool has_filename, String filename)
        {
            auto entry
                = createFileEntry(vm, global_object, name, blob, original_value, has_filename, WTF::move(filename));
            return setEntry(vm, name, WTF::move(entry));
        }

        void remove(const String& name)
        {
            m_entries.removeIf(this, [&](const Entry& entry) { return entry.name == name; });
            updateMemoryCost();
        }

        // One entry copied out without allocating a cell. A File entry keeps its existing cell in `file_value`. A
        // string entry keeps its text in `string_value`, and the caller creates the JSString from it.
        struct EntrySnapshot {
            String name;
            String string_value;
            JSValue file_value;
            bool is_file { false };
        };

        // Copies the entry at `index` into `out`; false when `index` is out of range. forEach() and the iterator read
        // entries only through it, because the JavaScript they run may change the list and move its buffer.
        bool entryAt(unsigned index, EntrySnapshot& out) const
        {
            if (index >= m_entries.size())
                return false;
            const auto& entry = m_entries.at(index);
            out.name = entry.name;
            out.is_file = entry.is_file;
            if (entry.is_file)
                out.file_value = entry.file_value.get();
            else
                out.string_value = entry.string_value;
            return true;
        }

        unsigned size() const { return m_entries.size(); }

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
            // A new FormData holds no entry. The cost is reported by each change that grows it, and again by
            // visitChildren in every collection, which is where removals stop counting.
        }

        Entry createFileEntry(JSC::VM& vm, Collo::GlobalObject* global_object, String name, JSColloBlob& blob,
            JSValue original_value, bool has_filename, String filename)
        {
            Entry entry;
            entry.name = WTF::move(name);
            entry.is_file = true;

            if (auto* file = dynamicDowncast<JSColloFile>(&blob)) {
                if (!has_filename) {
                    entry.file_value.setWithoutWriteBarrier(original_value);
                    return entry;
                }
                auto* renamed = JSColloFile::createFromBlob(
                    vm, global_object->fileStructure(), *file, WTF::move(filename), file->lastModified());
                entry.file_value.setWithoutWriteBarrier(renamed);
                return entry;
            }

            auto name_for_blob = has_filename ? WTF::move(filename) : WTF::makeString("blob"_s);
            auto last_modified = WTF::WallTime::now().secondsSinceEpoch().milliseconds();
            auto* file = JSColloFile::createFromBlob(
                vm, global_object->fileStructure(), blob, WTF::move(name_for_blob), last_modified);
            entry.file_value.setWithoutWriteBarrier(file);
            return entry;
        }

        // The first entry named `name` takes the replacement's value in place, and every later one goes.
        bool setEntry(JSC::VM& vm, const String& name, Entry&& replacement)
        {
            std::optional<size_t> first;
            for (size_t index = 0; index < m_entries.size(); index++) {
                if (m_entries.at(index).name == name) {
                    first = index;
                    break;
                }
            }
            if (!first)
                return appendEntry(vm, WTF::move(replacement));
            auto& entry = m_entries.at(*first);
            entry.string_value = WTF::move(replacement.string_value);
            entry.file_value.set(vm, this, replacement.file_value.get());
            entry.is_file = replacement.is_file;
            bool kept_first = false;
            m_entries.removeIf(this, [&](const Entry& candidate) {
                if (candidate.name != name)
                    return false;
                if (!kept_first) {
                    kept_first = true;
                    return false;
                }
                return true;
            });
            updateMemoryCost();
            return true;
        }

        static size_t entryMemoryCost(const Entry& entry)
        {
            return sizeof(Entry) + formDataStringMemoryCost(entry.name) + formDataStringMemoryCost(entry.string_value);
        }

        bool appendEntry(JSC::VM& vm, Entry&& entry)
        {
            const size_t added_cost = entryMemoryCost(entry);
            if (!m_entries.tryAppend(vm, this, WTF::move(entry)))
                return false;
            m_memory_cost.fetch_add(added_cost, std::memory_order_relaxed);
            reportEntryMemoryAllocated(added_cost);
            return true;
        }

        // Recounts after a removal or a replacement. Growth is reported at once; a fall stops counting at
        // visitChildren's report in the next collection.
        void updateMemoryCost()
        {
            size_t cost = 0;
            for (const auto& entry : m_entries)
                cost += entryMemoryCost(entry);
            const size_t previous = m_memory_cost.exchange(cost, std::memory_order_relaxed);
            if (cost > previous)
                reportEntryMemoryAllocated(cost - previous);
        }

        // Reports growth between collections; removals stop counting at visitChildren's report in the next
        // collection. Never call it while holding the cell lock: the report can stop the mutator for a collection
        // whose marker needs that lock to visit this cell.
        void reportEntryMemoryAllocated(size_t cost) { vm().heap.reportExtraMemoryAllocated(this, cost); }

        Collo::CellEdgeList<Entry> m_entries;
        // Written on the VM thread and read by visitChildren on a marking thread; nothing else depends on it.
        std::atomic<size_t> m_memory_cost { 0 };
    };

    // Its fields are a WriteBarrier and scalars, so the cell needs no destructor and lives in the heap's plain cell
    // space.
    class JSColloFormDataIterator final : public JSC::JSNonFinalObject {
        using Base = JSC::JSNonFinalObject;

    public:
        template <typename CellType, JSC::SubspaceAccess> static JSC::CompleteSubspace* subspaceFor(JSC::VM& vm)
        {
            return &vm.cellSpace();
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
        this_object->m_entries.visit(this_object, visitor);
        // A full collection resets the heap's extra memory count, so the retained cost is reported again in every
        // collection.
        visitor.reportExtraMemoryVisited(this_object->memoryCost());
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

    JSColloFormData* requireFormData(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
    {
        if (auto* form_data = dynamicDowncast<JSColloFormData>(value))
            return form_data;
        JSC::throwVMTypeError(global_object, scope, "FormData method called on incompatible receiver"_s);
        return nullptr;
    }

    JSColloFormDataIterator* requireFormDataIterator(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
    {
        if (auto* iterator = dynamicDowncast<JSColloFormDataIterator>(value))
            return iterator;
        JSC::throwVMTypeError(global_object, scope, "FormData Iterator method called on incompatible receiver"_s);
        return nullptr;
    }

    JSC::Structure* formDataStructureForNewTarget(
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

    bool requireArgumentCount(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::CallFrame* call_frame,
        unsigned count, WTF::ASCIILiteral message)
    {
        if (call_frame->argumentCount() >= count)
            return true;
        JSC::throwVMTypeError(global_object, scope, message);
        return false;
    }

    String formDataUSVArgument(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::CallFrame* call_frame, unsigned index)
    {
        return toWebApiUSVString(argumentToWebApiString(global_object, scope, call_frame, index));
    }

    JSValue entryValue(JSC::VM& vm, const JSColloFormData::Entry& entry)
    {
        if (entry.is_file)
            return entry.file_value.get();
        return JSC::jsString(vm, entry.string_value);
    }

    bool hasFilenameArgument(JSC::CallFrame* call_frame)
    {
        return call_frame->argumentCount() > 2 && !call_frame->argument(2).isUndefined();
    }

    // A parse failure as createFormDataFromBodyBytes reports it: the message goes to `out_parse_error` when the caller
    // gave one, and is thrown otherwise, as a QuotaExceededError DOMException for an exceeded cap and a TypeError for
    // malformed input.
    JSC::JSObject* failFormDataParse(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        WTF::ASCIILiteral message, WTF::ASCIILiteral* out_parse_error)
    {
        if (out_parse_error) {
            *out_parse_error = message;
            return nullptr;
        }
        if (isFormDataQuotaParseError(message)) {
            JSC::throwException(global_object, scope,
                createDOMException(global_object, DOMExceptionCode::QuotaExceededError, String(message)));
        } else
            JSC::throwVMTypeError(global_object, scope, message);
        return nullptr;
    }

    // The URL Standard's application/x-www-form-urlencoded parser, run one '&'-separated sequence at a time so the
    // entry cap stops it at the first pair past WebApiFormDataEntriesMax. URLParser::parseURLEncodedForm would build
    // every pair of the body before any count could be checked: a body of repeated "a&" within
    // WebApiMaterializedBodyBytesMax holds about two million pairs, each a fresh string and a vector slot.
    bool appendUrlEncodedEntries(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSColloFormData* form_data,
        std::span<const uint8_t> bytes, std::optional<WTF::ASCIILiteral>& parse_error)
    {
        String decoded;
        if (!decodeUtf8Bytes(global_object, scope, bytes, decoded))
            return false;
        // split() skips empty sequences, as the parser's steps do.
        for (auto sequence : WTF::StringView(decoded).split('&')) {
            auto pair = WTF::URLParser::parseQueryNameAndValue(sequence);
            if (!pair)
                continue;
            if (form_data->size() >= WebApiFormDataEntriesMax) {
                parse_error = FormDataEntriesExceeded;
                return false;
            }
            if (!form_data->appendString(WTF::move(pair->key), WTF::move(pair->value))) {
                JSC::throwOutOfMemoryError(global_object, scope);
                return false;
            }
        }
        return true;
    }

    bool appendMultipartEntries(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSColloFormData* form_data,
        std::span<const uint8_t> bytes, std::span<const uint8_t> boundary,
        std::optional<WTF::ASCIILiteral>& parse_error)
    {
        WTF::Vector<MultipartParsedPart> parts;
        if (!parseMultipartFormBody(global_object, scope, bytes, boundary, parts, parse_error))
            return false;

        // `bytes` is borrowed for the call, so a body with non-empty file parts is copied once, into one BlobStorage
        // that every such File views at the offsets the parser found in `bytes`. A storage of its own per File would
        // make the collector count the whole copy once per File, since it deduplicates per storage. An empty File
        // views an empty storage instead, so it neither forces the copy nor keeps it alive.
        WTF::RefPtr<BlobStorage> shared_body;
        WTF::RefPtr<BlobStorage> empty_storage;
        auto& vm = global_object->vm();
        auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
        for (auto& part : parts) {
            if (!part.is_file) {
                if (!form_data->appendString(WTF::move(part.name), WTF::move(part.value))) {
                    JSC::throwOutOfMemoryError(global_object, scope);
                    return false;
                }
                continue;
            }
            auto& storage = part.size ? shared_body : empty_storage;
            if (!storage) {
                WTF::Vector<uint8_t> copy;
                if (part.size && (!copy.tryReserveInitialCapacity(bytes.size()) || !copy.tryAppend(bytes))) {
                    JSC::throwOutOfMemoryError(global_object, scope);
                    return false;
                }
                storage = BlobStorage::create(WTF::move(copy));
                if (!storage) {
                    JSC::throwOutOfMemoryError(global_object, scope);
                    return false;
                }
            }
            if (!form_data->appendParsedFileView(vm, collo_global, WTF::move(part.name),
                    WTF::Ref<BlobStorage> { *storage }, part.size ? part.offset : 0, part.size,
                    WTF::move(part.content_type), WTF::move(part.filename))) {
                JSC::throwOutOfMemoryError(global_object, scope);
                return false;
            }
        }
        return true;
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

    JSValue createFormDataIterator(
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

} // namespace

bool isFormDataQuotaParseError(WTF::ASCIILiteral message)
{
    return message == FormDataEntriesExceeded || message == FormDataPartHeadersExceeded
        || message == FormDataBodyBytesExceeded;
}

JSC::JSObject* createFormDataBodyQuotaExceeded(JSC::JSGlobalObject* global_object)
{
    return createDOMException(global_object, DOMExceptionCode::QuotaExceededError, String(FormDataBodyBytesExceeded));
}

bool isColloFormData(JSC::JSValue value) { return dynamicDowncast<JSColloFormData>(value) != nullptr; }

JSC::JSObject* createFormDataFromBodyBytes(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    std::span<const uint8_t> bytes, WTF::String content_type, WTF::ASCIILiteral* out_parse_error)
{
    if (bytes.size() > WebApiMaterializedBodyBytesMax)
        return failFormDataParse(global_object, scope, FormDataBodyBytesExceeded, out_parse_error);

    std::optional<WTF::ASCIILiteral> parse_error;
    auto content = parseFormBodyContentType(global_object, scope, content_type, parse_error);
    RETURN_IF_EXCEPTION(scope, nullptr);
    if (!content)
        return failFormDataParse(global_object, scope,
            parse_error.value_or("Body.formData requires a form content type"_s), out_parse_error);

    auto& vm = global_object->vm();
    auto* form_data
        = JSColloFormData::create(vm, uncheckedDowncast<Collo::GlobalObject>(global_object)->formDataStructure());
    bool parsed = false;
    switch (content->encoding) {
    case FormBodyEncoding::UrlEncoded:
        parsed = appendUrlEncodedEntries(global_object, scope, form_data, bytes, parse_error);
        break;
    case FormBodyEncoding::Multipart:
        parsed = appendMultipartEntries(global_object, scope, form_data, bytes, content->boundary.span(), parse_error);
        break;
    }
    RETURN_IF_EXCEPTION(scope, nullptr);
    if (!parsed)
        return failFormDataParse(global_object, scope, parse_error.value_or("Invalid form data"_s), out_parse_error);
    return form_data;
}

WTF::RefPtr<BlobStorage> serializeFormDataToMultipartBody(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    JSC::JSValue form_data_value, size_t& out_size, WTF::String& out_content_type)
{
    out_size = 0;
    out_content_type = WTF::emptyString();

    auto* form_data = dynamicDowncast<JSColloFormData>(form_data_value);
    if (!form_data)
        return nullptr;

    // Every entry takes at least the smallest part's bytes, so this many entries can never fit, and refusing them here
    // spares the snapshot's copy of each.
    if (form_data->size() > multipartSerializableEntriesMax()) {
        JSC::throwException(global_object, scope, createFormDataBodyQuotaExceeded(global_object));
        return nullptr;
    }
    WTF::Vector<MultipartSerializedEntry> entries;
    if (!form_data->snapshotForSerialization(entries)) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return nullptr;
    }
    MultipartSerializedBody body;
    switch (serializeMultipartFormBody(entries.span(), body)) {
    case MultipartSerializeResult::Serialized:
        break;
    case MultipartSerializeResult::Exceeded:
        JSC::throwException(global_object, scope, createFormDataBodyQuotaExceeded(global_object));
        return nullptr;
    case MultipartSerializeResult::OutOfMemory:
        JSC::throwOutOfMemoryError(global_object, scope);
        return nullptr;
    case MultipartSerializeResult::EntropyFailure:
        JSC::throwException(
            global_object, scope, JSC::createError(global_object, "failed to generate a secure multipart boundary"_s));
        return nullptr;
    }
    out_size = body.size;
    out_content_type = WTF::move(body.content_type);
    return WTF::move(body.storage);
}

static std::span<const uint8_t> formDataBufferSpan(ColloBuffer buffer)
{
    if (!buffer.ptr || buffer.len == 0)
        return {};
    return { buffer.ptr, buffer.len };
}

extern "C" ColloStatus collo_form_data_new_from_bytes(
    ColloRealm* realm, ColloBuffer bytes, ColloString content_type, ColloValue** out_value, ColloValue** out_exception)
{
    if (out_value)
        *out_value = nullptr;
    Collo::clearOutException(out_exception);
    if (!realmIsReady(realm) || !out_value || (bytes.len != 0 && !bytes.ptr))
        return COLLO_STATUS_INVALID_ARGUMENT;

    WTF::String type;
    if (Collo::stringToWTFString(content_type, type) != COLLO_STATUS_OK)
        return COLLO_STATUS_INVALID_ARGUMENT;

    ColloVm* vm = realm->vm;
    JSC::JSLockHolder locker(*vm->vm);
    auto scope = DECLARE_THROW_SCOPE(*vm->vm);
    auto* form_data
        = createFormDataFromBodyBytes(realm->global_object, scope, formDataBufferSpan(bytes), WTF::move(type));
    if (scope.exception())
        return consumeExceptionStatus(vm, scope, out_exception);
    if (!form_data)
        return COLLO_STATUS_ERROR;
    return Collo::makeValueHandle(vm, form_data, out_value);
}

void installWebApiFormData(Collo::GlobalObject* global_object, JSC::VM& vm)
{
    constexpr unsigned enumerableFunction = static_cast<unsigned>(JSC::PropertyAttribute::None);

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
    prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol, JSC::jsString(vm, WTF::makeString("FormData"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    auto* constructor = JSC::JSFunction::create(vm, global_object, 0, "FormData"_s, formDataConstructorCall,
        JSC::ImplementationVisibility::Public, JSC::NoIntrinsic, formDataConstructorConstruct, nullptr);
    RELEASE_ASSERT(constructor);
    constructor->putDirect(vm, vm.propertyNames->prototype, prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
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

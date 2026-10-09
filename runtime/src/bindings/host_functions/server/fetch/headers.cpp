// The Headers and Headers Iterator cells, their JavaScript methods, and the functions headers.h declares. A Headers
// cell owns its HeadersList (headers_list.h) by value; the list's vectors grow outside the GC heap, so the cell reports
// their capacity to the collector as extra memory. An iterator holds its Headers through a WriteBarrier and re-sorts
// its keys whenever the list's update_counter changes, keeping its position. VM thread only, except that marking
// threads call memoryCost().

#include "host_functions/server/fetch/headers.h"
#include "host_functions/server/fetch/headers_list.h"
#include "host_functions/webapi/dom/dom_exception.h"
#include "host_functions/webapi/limits.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/IdentifierInlines.h>
#include <JavaScriptCore/InternalFunction.h>
#include <JavaScriptCore/IteratorOperations.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSArray.h>
#include <JavaScriptCore/JSDestructibleObject.h>
#include <JavaScriptCore/JSFunction.h>
#include <JavaScriptCore/JSONObject.h>
#include <JavaScriptCore/JSObject.h>
#include <JavaScriptCore/JSString.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <JavaScriptCore/PropertyNameArray.h>
#include <JavaScriptCore/SlotVisitorMacros.h>
#include <wtf/Vector.h>
#include <wtf/text/CString.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/WTFString.h>

#include <algorithm>
#include <cstring>
#include <limits>
#include <optional>
#include <span>

namespace Collo::HostFunctions {

using namespace FetchHeadersInternal;

namespace {

    using JSC::EncodedJSValue;
    using JSC::JSValue;
    using WTF::String;
    using namespace JSC;

    class JSColloHeaders;
    class JSColloHeadersIterator;

    struct HeaderForEachSnapshotEntry {
        String name;
        String value;
    };

    class JSColloHeaders final : public JSC::JSDestructibleObject {
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

        static JSColloHeaders* create(
            JSC::VM& vm, Collo::GlobalObject* global_object, HeadersList&& list, JSC::Structure* structure = nullptr)
        {
            auto* object = new (NotNull, JSC::allocateCell<JSColloHeaders>(vm))
                JSColloHeaders(vm, structure ? structure : global_object->headersStructure(), WTF::move(list));
            object->finishCreation(vm);
            return object;
        }

        static void destroy(JSC::JSCell* cell) { static_cast<JSColloHeaders*>(cell)->~JSColloHeaders(); }

        static size_t estimatedSize(JSC::JSCell* cell, JSC::VM& vm)
        {
            auto* this_object = static_cast<JSColloHeaders*>(cell);
            return Base::estimatedSize(cell, vm) + this_object->memoryCost();
        }

        DECLARE_INFO;
        DECLARE_VISIT_CHILDREN;

        // Bytes held by the list's vectors, inline capacity included. It reads only their capacity fields, never their
        // buffers, so a marking thread computing it while the mutator grows a vector gets a stale value.
        size_t memoryCost() const
        {
            return m_list.storage.capacity() + m_list.entries.capacity() * sizeof(FetchHeadersInternal::HeaderEntry)
                + m_list.set_cookie_values.capacity() * sizeof(FetchHeadersInternal::HeaderSlice);
        }

        HeadersList& list() { return m_list; }
        const HeadersList& list() const { return m_list; }

    private:
        JSColloHeaders(JSC::VM& vm, JSC::Structure* structure, HeadersList&& list)
            : Base(vm, structure)
            , m_list(WTF::move(list))
        {
        }

        ~JSColloHeaders() = default;

        void finishCreation(JSC::VM& vm)
        {
            Base::finishCreation(vm);
            ASSERT(inherits(info()));
            // Reported at creation so the allocation counts toward scheduling the next collection;
            // visitChildrenImpl keeps it counted afterwards.
            vm.heap.reportExtraMemoryAllocated(this, memoryCost());
        }

        HeadersList m_list;
    };

    static HeadersList createHeaderList(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue init, HeaderGuard guard)
    {
        HeadersList list { guard };

        if (init.isUndefinedOrNull())
            return list;

        if (auto* existing = dynamicDowncast<JSColloHeaders>(init))
            return cloneHeadersList(existing->list(), guard);

        auto* object = dynamicDowncast<JSC::JSObject>(init);
        if (!object) {
            JSC::throwVMTypeError(global_object, scope, "Headers init must be an object or iterable"_s);
            return list;
        }

        auto iterator_method = JSC::iteratorMethod(global_object, object);
        RETURN_IF_EXCEPTION(scope, HeadersList { guard });
        if (!iterator_method.isUndefinedOrNull()) {
            JSC::forEachInIterable(global_object, init, [&](JSC::VM&, JSC::JSGlobalObject*, JSValue pair_value) {
                appendIterableHeaderPair(global_object, scope, list, pair_value);
            });
            RETURN_IF_EXCEPTION(scope, HeadersList { guard });
            return list;
        }

        auto& vm = global_object->vm();
        JSC::PropertyNameArrayBuilder property_names(
            vm, JSC::PropertyNameMode::Strings, JSC::PrivateSymbolMode::Exclude);
        JSC::JSObject::getOwnPropertyNames(object, global_object, property_names, JSC::DontEnumPropertiesMode::Exclude);
        RETURN_IF_EXCEPTION(scope, HeadersList { guard });

        for (auto& property : property_names) {
            auto property_value = object->get(global_object, property);
            RETURN_IF_EXCEPTION(scope, HeadersList { guard });
            auto normalized
                = normalizeHeaderPair(global_object, scope, JSC::jsString(vm, property.string()), property_value);
            RETURN_IF_EXCEPTION(scope, HeadersList { guard });
            if (!normalized)
                return list;
            appendNormalizedPair(
                global_object, scope, list, WTF::move(normalized->first), WTF::move(normalized->second));
            RETURN_IF_EXCEPTION(scope, HeadersList { guard });
        }

        return list;
    }

    enum class HeadersIteratorKind : uint8_t {
        Entries,
        Keys,
        Values,
    };

    class JSColloHeadersIterator final : public JSC::JSDestructibleObject {
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

        static JSColloHeadersIterator* create(
            JSC::VM& vm, Collo::GlobalObject* global_object, JSColloHeaders* headers, HeadersIteratorKind kind)
        {
            auto* object = new (NotNull, JSC::allocateCell<JSColloHeadersIterator>(vm))
                JSColloHeadersIterator(vm, global_object->headersIteratorStructure(), kind);
            object->finishCreation(vm, headers);
            return object;
        }

        static void destroy(JSC::JSCell* cell)
        {
            static_cast<JSColloHeadersIterator*>(cell)->~JSColloHeadersIterator();
        }

        DECLARE_INFO;
        DECLARE_VISIT_CHILDREN;

        JSColloHeaders* headers() const { return m_headers.get(); }
        HeadersIteratorKind kind() const { return m_kind; }

        void refreshKeysIfNeeded()
        {
            auto* headers = m_headers.get();
            if (!headers || (!m_keys.isEmpty() && m_update_counter == headers->list().update_counter))
                return;

            size_t logical_position = m_current_index;
            m_keys = sortedHeaderKeys(headers->list(), false);
            m_current_index = static_cast<unsigned>(std::min(logical_position, m_keys.size()));
            m_update_counter = headers->list().update_counter;
        }

        bool next(String& name, String& value)
        {
            refreshKeysIfNeeded();
            auto* headers = m_headers.get();
            if (!headers)
                return false;

            auto& list = headers->list();
            while (m_current_index < m_keys.size()) {
                auto key = m_keys[m_current_index++];
                name = list.nameForKey(key);
                value = list.valueForKey(key);
                return true;
            }
            return false;
        }

    private:
        JSColloHeadersIterator(JSC::VM& vm, JSC::Structure* structure, HeadersIteratorKind kind)
            : Base(vm, structure)
            , m_kind(kind)
        {
        }

        ~JSColloHeadersIterator() = default;

        void finishCreation(JSC::VM& vm, JSColloHeaders* headers)
        {
            Base::finishCreation(vm);
            ASSERT(inherits(info()));
            m_headers.set(vm, this, headers);
        }

        JSC::WriteBarrier<JSColloHeaders> m_headers;
        WTF::Vector<HeaderSortKey> m_keys;
        unsigned m_current_index { 0 };
        uint64_t m_update_counter { std::numeric_limits<uint64_t>::max() };
        HeadersIteratorKind m_kind;
    };

    const JSC::ClassInfo JSColloHeaders::s_info
        = { "Headers"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloHeaders) };
    const JSC::ClassInfo JSColloHeadersIterator::s_info
        = { "Headers Iterator"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloHeadersIterator) };

    template <typename Visitor> void JSColloHeaders::visitChildrenImpl(JSC::JSCell* cell, Visitor& visitor)
    {
        auto* this_object = static_cast<JSColloHeaders*>(cell);
        ASSERT_GC_OBJECT_INHERITS(this_object, info());
        Base::visitChildren(this_object, visitor);
        // A full collection resets the heap's extra-memory total and rebuilds it from visits, so the cost is reported
        // again on every visit. Growth since creation is counted only from here.
        visitor.reportExtraMemoryVisited(this_object->memoryCost());
    }

    DEFINE_VISIT_CHILDREN(JSColloHeaders);

    template <typename Visitor> void JSColloHeadersIterator::visitChildrenImpl(JSC::JSCell* cell, Visitor& visitor)
    {
        auto* this_object = static_cast<JSColloHeadersIterator*>(cell);
        ASSERT_GC_OBJECT_INHERITS(this_object, info());
        Base::visitChildren(this_object, visitor);
        visitor.append(this_object->m_headers);
    }

    DEFINE_VISIT_CHILDREN(JSColloHeadersIterator);

    static JSColloHeaders* requireHeaders(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
    {
        if (auto* object = dynamicDowncast<JSColloHeaders>(value))
            return object;
        JSC::throwVMTypeError(global_object, scope, "Headers method called on incompatible receiver"_s);
        return nullptr;
    }

    static JSColloHeadersIterator* requireHeadersIterator(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
    {
        if (auto* object = dynamicDowncast<JSColloHeadersIterator>(value))
            return object;
        JSC::throwVMTypeError(global_object, scope, "Headers Iterator method called on incompatible receiver"_s);
        return nullptr;
    }

    static void addSaturated(size_t& total, size_t amount)
    {
        if (amount > std::numeric_limits<size_t>::max() - total) {
            total = std::numeric_limits<size_t>::max();
            return;
        }
        total += amount;
    }

    static bool addHeaderBytesWithinFetchLimit(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, size_t& total, size_t amount)
    {
        if (amount > WebApiFetchRequestHeadersBytesMax || total > WebApiFetchRequestHeadersBytesMax - amount) {
            JSC::throwException(global_object, scope,
                createDOMException(global_object, DOMExceptionCode::QuotaExceededError,
                    "Headers exceed the serverless header limit"_s));
            return false;
        }
        total += amount;
        return true;
    }

    static JSValue createHeadersIterator(
        JSC::JSGlobalObject* global_object, JSColloHeaders* headers, HeadersIteratorKind kind)
    {
        auto& vm = global_object->vm();
        return JSColloHeadersIterator::create(vm, uncheckedDowncast<Collo::GlobalObject>(global_object), headers, kind);
    }

    static bool requireArgumentCount(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        JSC::CallFrame* call_frame, unsigned count, WTF::ASCIILiteral message)
    {
        if (call_frame->argumentCount() >= count)
            return true;
        JSC::throwVMTypeError(global_object, scope, message);
        return false;
    }

    static JSC::Structure* headersStructureForNewTarget(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::CallFrame* call_frame)
    {
        auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
        auto* new_target = call_frame->newTarget().getObject();
        auto* constructor = call_frame->jsCallee();
        auto* base = collo_global->headersStructure();
        RELEASE_ASSERT(base);
        if (!new_target || new_target == constructor)
            return base;
        auto* structure = JSC::InternalFunction::createSubclassStructure(global_object, new_target, base);
        RETURN_IF_EXCEPTION(scope, nullptr);
        return structure;
    }

    JSC_DEFINE_HOST_FUNCTION(headersConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        return JSC::throwVMTypeError(global_object, scope, "Headers constructor requires 'new'"_s);
    }

    JSC_DEFINE_HOST_FUNCTION(
        headersConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);

        auto list = createHeaderList(global_object, scope, call_frame->argument(0), HeaderGuard::None);
        RETURN_IF_EXCEPTION(scope, {});
        auto* structure = headersStructureForNewTarget(global_object, scope, call_frame);
        RETURN_IF_EXCEPTION(scope, {});

        auto* object = JSColloHeaders::create(
            vm, uncheckedDowncast<Collo::GlobalObject>(global_object), WTF::move(list), structure);
        return JSValue::encode(object);
    }

    JSC_DEFINE_HOST_FUNCTION(headersGet, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* headers = requireHeaders(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (!requireArgumentCount(global_object, scope, call_frame, 1, "Headers.get requires a header name"_s))
            return {};

        auto name = normalizeHeaderName(global_object, scope, call_frame->argument(0));
        RETURN_IF_EXCEPTION(scope, {});
        if (!name)
            return {};
        String value;
        if (headers->list().get(*name, value))
            return JSValue::encode(JSC::jsString(vm, value));
        return JSValue::encode(JSC::jsNull());
    }

    JSC_DEFINE_HOST_FUNCTION(headersGetSetCookie, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* headers = requireHeaders(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});

        auto& list = headers->list();
        auto* output = JSC::constructEmptyArray(global_object, nullptr, list.set_cookie_values.size());
        RETURN_IF_EXCEPTION(scope, {});
        if (!output)
            return {};
        for (unsigned value_index = 0; value_index < list.set_cookie_values.size(); value_index++) {
            output->putDirectIndex(
                global_object, value_index, JSC::jsString(vm, list.string(list.set_cookie_values[value_index])));
            RETURN_IF_EXCEPTION(scope, {});
        }
        return JSValue::encode(output);
    }

    JSC_DEFINE_HOST_FUNCTION(headersGetCount, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto* headers = dynamicDowncast<JSColloHeaders>(call_frame->thisValue());
        if (!headers)
            return JSValue::encode(JSC::jsUndefined());
        return JSValue::encode(JSC::jsNumber(headers->list().entries.size()));
    }

    JSC_DEFINE_HOST_FUNCTION(headersSet, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* headers = requireHeaders(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (!requireArgumentCount(
                global_object, scope, call_frame, 2, "Headers.set requires a header name and value"_s))
            return {};

        auto normalized = normalizeHeaderPair(global_object, scope, call_frame->argument(0), call_frame->argument(1));
        RETURN_IF_EXCEPTION(scope, {});
        if (!normalized)
            return JSValue::encode(JSC::jsUndefined());

        headers->list().set(global_object, scope, WTF::move(normalized->first), WTF::move(normalized->second));
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(JSC::jsUndefined());
    }

    JSC_DEFINE_HOST_FUNCTION(headersAppend, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* headers = requireHeaders(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (!requireArgumentCount(
                global_object, scope, call_frame, 2, "Headers.append requires a header name and value"_s))
            return {};

        auto normalized = normalizeHeaderPair(global_object, scope, call_frame->argument(0), call_frame->argument(1));
        RETURN_IF_EXCEPTION(scope, {});
        if (!normalized)
            return JSValue::encode(JSC::jsUndefined());

        headers->list().append(global_object, scope, WTF::move(normalized->first), WTF::move(normalized->second));
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(JSC::jsUndefined());
    }

    JSC_DEFINE_HOST_FUNCTION(headersHas, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* headers = requireHeaders(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (!requireArgumentCount(global_object, scope, call_frame, 1, "Headers.has requires a header name"_s))
            return {};

        auto name = normalizeHeaderName(global_object, scope, call_frame->argument(0));
        RETURN_IF_EXCEPTION(scope, {});
        if (!name)
            return {};
        return JSValue::encode(JSC::jsBoolean(headers->list().has(*name)));
    }

    JSC_DEFINE_HOST_FUNCTION(headersDelete, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* headers = requireHeaders(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (!requireArgumentCount(global_object, scope, call_frame, 1, "Headers.delete requires a header name"_s))
            return {};

        auto name = normalizeHeaderName(global_object, scope, call_frame->argument(0));
        RETURN_IF_EXCEPTION(scope, {});
        if (!name)
            return JSValue::encode(JSC::jsUndefined());
        headers->list().remove(global_object, scope, *name);
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(JSC::jsUndefined());
    }

    JSC_DEFINE_HOST_FUNCTION(headersToJSON, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* headers = requireHeaders(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});

        auto& list = headers->list();
        // One property per entry: Set-Cookie values are left out, so the object is sized for the entries alone.
        auto* output = JSC::constructEmptyObject(global_object, global_object->objectPrototype(), list.entries.size());
        RETURN_IF_EXCEPTION(scope, {});
        if (!output)
            return {};

        for (auto& entry : list.entries) {
            auto name = entry.known == KnownHeader::Unknown ? list.string(entry.name)
                                                            : HeadersList::knownHeaderNameString(entry.known);
            auto identifier = JSC::Identifier::fromString(vm, name);
            RETURN_IF_EXCEPTION(scope, {});
            output->putDirectMayBeIndex(global_object, identifier, JSC::jsString(vm, list.string(entry.value)));
            RETURN_IF_EXCEPTION(scope, {});
        }

        return JSValue::encode(output);
    }

    JSC_DEFINE_HOST_FUNCTION(headersEntries, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* headers = requireHeaders(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(createHeadersIterator(global_object, headers, HeadersIteratorKind::Entries));
    }

    JSC_DEFINE_HOST_FUNCTION(headersKeys, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* headers = requireHeaders(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(createHeadersIterator(global_object, headers, HeadersIteratorKind::Keys));
    }

    JSC_DEFINE_HOST_FUNCTION(headersValues, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* headers = requireHeaders(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(createHeadersIterator(global_object, headers, HeadersIteratorKind::Values));
    }

    JSC_DEFINE_HOST_FUNCTION(headersIteratorNext, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* iterator = requireHeadersIterator(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});

        String name;
        String value;
        if (!iterator->next(name, value))
            return JSValue::encode(JSC::createIteratorResultObject(global_object, JSC::jsUndefined(), true));

        JSValue result_value;
        switch (iterator->kind()) {
        case HeadersIteratorKind::Entries:
            result_value = JSC::constructArrayPair(global_object, JSC::jsString(vm, name), JSC::jsString(vm, value));
            break;
        case HeadersIteratorKind::Keys:
            result_value = JSC::jsString(vm, name);
            break;
        case HeadersIteratorKind::Values:
            result_value = JSC::jsString(vm, value);
            break;
        }

        return JSValue::encode(JSC::createIteratorResultObject(global_object, result_value, false));
    }

    JSC_DEFINE_HOST_FUNCTION(headersIteratorIterator, (JSC::JSGlobalObject*, JSC::CallFrame* call_frame))
    {
        return JSValue::encode(call_frame->thisValue());
    }

    JSC_DEFINE_HOST_FUNCTION(headersForEach, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* headers = requireHeaders(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (!requireArgumentCount(global_object, scope, call_frame, 1, "Headers.forEach requires a callback"_s))
            return {};

        auto callback = call_frame->argument(0);
        auto call_data = JSC::getCallData(callback);
        if (call_data.type == JSC::CallData::Type::None)
            return JSC::throwVMTypeError(global_object, scope, "Headers.forEach callback must be a function"_s);

        auto this_arg = call_frame->argument(1);
        // The callback may mutate the list, which shifts the entries the keys index, so every pair is copied before
        // the first call.
        auto keys = sortedHeaderKeys(headers->list(), false);
        WTF::Vector<HeaderForEachSnapshotEntry, 8> snapshot;
        if (!snapshot.tryReserveCapacity(keys.size()))
            return JSValue::encode(JSC::throwOutOfMemoryError(global_object, scope));
        for (auto key : keys) {
            if (!snapshot.tryAppend({
                    headers->list().nameForKey(key),
                    headers->list().valueForKey(key),
                })) {
                return JSValue::encode(JSC::throwOutOfMemoryError(global_object, scope));
            }
        }

        for (auto& entry : snapshot) {
            JSC::MarkedArgumentBuffer arguments;
            arguments.append(JSC::jsString(vm, entry.value));
            arguments.append(JSC::jsString(vm, entry.name));
            arguments.append(headers);
            if (arguments.hasOverflowed())
                return JSValue::encode(JSC::throwOutOfMemoryError(global_object, scope));
            JSC::call(global_object, callback, call_data, this_arg, arguments);
            RETURN_IF_EXCEPTION(scope, {});
        }

        return JSValue::encode(JSC::jsUndefined());
    }

} // namespace

JSC::JSObject* createHeadersFromJS(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue init, HeaderGuard guard)
{
    auto list = createHeaderList(global_object, scope, init, guard);
    RETURN_IF_EXCEPTION(scope, nullptr);

    auto& vm = global_object->vm();
    return JSColloHeaders::create(vm, uncheckedDowncast<Collo::GlobalObject>(global_object), WTF::move(list));
}

JSC::JSObject* createHeadersFromRawPairs(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    const ColloNameValuePair* pairs, size_t pairs_len, HeaderGuard guard)
{
    // An immutable list throws on every append, so the pairs go in under None and the guard is set afterwards.
    HeadersList list { guard == HeaderGuard::Immutable ? HeaderGuard::None : guard };
    list.entries.reserveInitialCapacity(
        static_cast<unsigned>(std::min(pairs_len, static_cast<size_t>(std::numeric_limits<unsigned>::max()))));
    size_t storage_capacity = 0;
    for (size_t index = 0; index < pairs_len; index++) {
        if (pairs[index].name.len > std::numeric_limits<size_t>::max() - storage_capacity)
            break;
        storage_capacity += pairs[index].name.len;
        if (pairs[index].value.len > std::numeric_limits<size_t>::max() - storage_capacity)
            break;
        storage_capacity += pairs[index].value.len;
    }
    list.reserveStorage(storage_capacity);
    for (size_t index = 0; index < pairs_len; index++) {
        auto normalized = normalizeRawHeaderPair(global_object, scope, pairs[index]);
        RETURN_IF_EXCEPTION(scope, nullptr);
        if (!normalized)
            return nullptr;
        appendNormalizedPair(global_object, scope, list, WTF::move(normalized->first), WTF::move(normalized->second));
        RETURN_IF_EXCEPTION(scope, nullptr);
    }
    list.guard = guard;

    auto& vm = global_object->vm();
    return JSColloHeaders::create(vm, uncheckedDowncast<Collo::GlobalObject>(global_object), WTF::move(list));
}

JSC::JSObject* cloneHeadersPreservingGuard(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSObject* headers)
{
    auto* native_headers = requireHeaders(global_object, scope, headers);
    RETURN_IF_EXCEPTION(scope, nullptr);
    if (!native_headers)
        return nullptr;

    auto list = cloneHeadersList(native_headers->list(), native_headers->list().guard);
    auto& vm = global_object->vm();
    return JSColloHeaders::create(vm, uncheckedDowncast<Collo::GlobalObject>(global_object), WTF::move(list));
}

bool collectHeadersToPairs(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSObject* headers,
    WTF::Vector<ColloHeaderPair>& pairs)
{
    auto* native_headers = requireHeaders(global_object, scope, headers);
    RETURN_IF_EXCEPTION(scope, false);
    if (!native_headers)
        return false;

    auto keys = sortedHeaderKeys(native_headers->list(), true);
    if (keys.size() > WebApiFetchRequestHeaderCountMax) {
        JSC::throwException(global_object, scope,
            createDOMException(global_object, DOMExceptionCode::QuotaExceededError,
                "Headers exceed the serverless header count limit"_s));
        return false;
    }
    if (!pairs.tryReserveInitialCapacity(keys.size())) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return false;
    }
    size_t aggregate_bytes = 0;
    for (auto key : keys) {
        auto name_bytes = native_headers->list().nameBytesForKey(key);
        auto value_bytes = native_headers->list().valueBytesForKey(key);
        if (!addHeaderBytesWithinFetchLimit(global_object, scope, aggregate_bytes, name_bytes.size()))
            return false;
        if (!addHeaderBytesWithinFetchLimit(global_object, scope, aggregate_bytes, value_bytes.size()))
            return false;
        ColloHeaderPair pair {
            native_headers->list().nameForKey(key),
            native_headers->list().valueForKey(key),
        };
        pairs.append(WTF::move(pair));
    }
    return true;
}

bool inspectHeadersForExtraction(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSObject* headers, HeaderExtractionStats& out)
{
    out = {};
    auto* native_headers = requireHeaders(global_object, scope, headers);
    RETURN_IF_EXCEPTION(scope, false);
    if (!native_headers)
        return false;

    auto keys = sortedHeaderKeys(native_headers->list(), true);
    out.count = keys.size();
    for (auto key : keys) {
        addSaturated(out.aggregate_bytes, native_headers->list().nameBytesForKey(key).size());
        addSaturated(out.aggregate_bytes, native_headers->list().valueBytesForKey(key).size());
    }
    return true;
}

bool setHeaderDefault(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSObject* headers,
    WTF::String name, WTF::String value)
{
    auto* native_headers = requireHeaders(global_object, scope, headers);
    RETURN_IF_EXCEPTION(scope, false);
    if (!native_headers)
        return false;

    auto normalized = name.convertToASCIILowercase();
    if (!native_headers->list().has(normalized))
        native_headers->list().set(global_object, scope, WTF::move(normalized), trimHeaderValue(value));
    RETURN_IF_EXCEPTION(scope, false);
    return true;
}

bool getHeaderValue(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSObject* headers,
    WTF::String name, WTF::String& out)
{
    auto* native_headers = requireHeaders(global_object, scope, headers);
    RETURN_IF_EXCEPTION(scope, false);
    if (!native_headers)
        return false;

    return native_headers->list().get(name.convertToASCIILowercase(), out);
}

void installServerHeaders(Collo::GlobalObject* global_object, JSC::VM& vm)
{
    auto* headers_prototype = JSC::constructEmptyObject(global_object);
    putWebApiFunction(global_object, headers_prototype, vm, "append"_s, 2, headersAppend,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    putWebApiFunction(global_object, headers_prototype, vm, "delete"_s, 1, headersDelete,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    putWebApiFunction(global_object, headers_prototype, vm, "get"_s, 1, headersGet,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    putWebApiFunction(global_object, headers_prototype, vm, "has"_s, 1, headersHas,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    putWebApiFunction(global_object, headers_prototype, vm, "set"_s, 2, headersSet,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    auto* entries_function = JSC::JSFunction::create(
        vm, global_object, 0, "entries"_s, headersEntries, JSC::ImplementationVisibility::Public);
    RELEASE_ASSERT(entries_function);
    JSC::Identifier entries_identifier = JSC::Identifier::fromString(vm, "entries"_s);
    headers_prototype->putDirect(
        vm, entries_identifier, entries_function, static_cast<unsigned>(JSC::PropertyAttribute::None));
    RELEASE_ASSERT(headers_prototype->getDirect(vm, entries_identifier));
    headers_prototype->putDirect(vm, vm.propertyNames->iteratorSymbol, entries_function,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    putWebApiFunction(global_object, headers_prototype, vm, "keys"_s, 0, headersKeys,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    putWebApiFunction(global_object, headers_prototype, vm, "values"_s, 0, headersValues,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    putWebApiFunction(global_object, headers_prototype, vm, "forEach"_s, 1, headersForEach,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    putWebApiFunction(global_object, headers_prototype, vm, "toJSON"_s, 0, headersToJSON,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    putWebApiAccessor(global_object, headers_prototype, vm, "count"_s, headersGetCount, nullptr,
        static_cast<unsigned>(JSC::PropertyAttribute::Accessor | JSC::PropertyAttribute::DontDelete));
    putWebApiFunction(global_object, headers_prototype, vm, "getSetCookie"_s, 0, headersGetSetCookie,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    headers_prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol,
        JSC::jsString(vm, WTF::makeString("Headers"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    auto* headers_constructor = JSC::JSFunction::create(vm, global_object, 0, "Headers"_s, headersConstructorCall,
        JSC::ImplementationVisibility::Public, JSC::NoIntrinsic, headersConstructorConstruct, nullptr);
    RELEASE_ASSERT(headers_constructor);
    headers_constructor->putDirect(vm, vm.propertyNames->prototype, headers_prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    headers_prototype->putDirect(vm, vm.propertyNames->constructor, headers_constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    JSC::Identifier headers_identifier = JSC::Identifier::fromString(vm, "Headers"_s);
    global_object->putDirect(
        vm, headers_identifier, headers_constructor, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    RELEASE_ASSERT(global_object->getDirect(vm, headers_identifier));

    auto* iterator_prototype = JSC::constructEmptyObject(global_object);
    putWebApiFunction(global_object, iterator_prototype, vm, "next"_s, 0, headersIteratorNext);
    auto* iterator_function = JSC::JSFunction::create(
        vm, global_object, 0, "[Symbol.iterator]"_s, headersIteratorIterator, JSC::ImplementationVisibility::Public);
    RELEASE_ASSERT(iterator_function);
    iterator_prototype->putDirect(vm, vm.propertyNames->iteratorSymbol, iterator_function,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    iterator_prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol,
        JSC::jsString(vm, WTF::makeString("Headers Iterator"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);
    global_object->cacheHeadersApi(headers_constructor, headers_prototype,
        JSColloHeaders::createStructure(vm, global_object, headers_prototype), iterator_prototype,
        JSColloHeadersIterator::createStructure(vm, global_object, iterator_prototype));
}

} // namespace Collo::HostFunctions

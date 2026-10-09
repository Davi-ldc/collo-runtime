// URLSearchParams and its iterator, on the VM thread. Names and values from JavaScript are converted to USVStrings.
// The paths that add pairs from JavaScript input (the constructor, append and set) enforce
// WebApiUrlSearchParamsPairsMax with a QuotaExceededError; pairs parsed from a URL's query are not capped. Every
// method that changes the pairs syncs the associated URL, after refreshing the cached GC cost when the change can
// alter it. An iterator holds its URLSearchParams and indexes the live pair list on each next(), so it sees changes
// made during iteration.

#include "host_functions/webapi/url/search_params.h"

#include "host_functions/webapi/dom/dom_exception.h"
#include "host_functions/webapi/limits.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/IdentifierInlines.h>
#include <JavaScriptCore/InternalFunction.h>
#include <JavaScriptCore/IteratorOperations.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSArray.h>
#include <JavaScriptCore/JSFunction.h>
#include <JavaScriptCore/JSObject.h>
#include <JavaScriptCore/JSString.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <JavaScriptCore/PropertyNameArray.h>
#include <JavaScriptCore/SlotVisitorMacros.h>
#include <wtf/HashMap.h>
#include <wtf/URLParser.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringImpl.h>
#include <wtf/text/WTFString.h>

#include <algorithm>
#include <limits>

namespace Collo::HostFunctions {
namespace {

    using JSC::EncodedJSValue;
    using JSC::JSValue;
    using WTF::String;
    using namespace JSC;

    enum class SearchParamsIteratorKind : uint8_t {
        Entries,
        Keys,
        Values,
    };

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

    class JSColloURLSearchParamsIterator final : public JSC::JSDestructibleObject {
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

        static JSColloURLSearchParamsIterator* create(JSC::VM& vm, Collo::GlobalObject* global_object,
            JSColloURLSearchParams* params, SearchParamsIteratorKind kind)
        {
            auto* object = new (NotNull, JSC::allocateCell<JSColloURLSearchParamsIterator>(vm))
                JSColloURLSearchParamsIterator(vm, global_object->urlSearchParamsIteratorStructure(), kind);
            object->finishCreation(vm, params);
            return object;
        }

        static void destroy(JSC::JSCell* cell)
        {
            static_cast<JSColloURLSearchParamsIterator*>(cell)->~JSColloURLSearchParamsIterator();
        }

        DECLARE_INFO;
        DECLARE_VISIT_CHILDREN;

        JSColloURLSearchParams* params() const { return m_params.get(); }
        unsigned takeIndex() { return m_index++; }
        SearchParamsIteratorKind kind() const { return m_kind; }

    private:
        JSColloURLSearchParamsIterator(JSC::VM& vm, JSC::Structure* structure, SearchParamsIteratorKind kind)
            : Base(vm, structure)
            , m_kind(kind)
        {
        }

        ~JSColloURLSearchParamsIterator() = default;

        void finishCreation(JSC::VM& vm, JSColloURLSearchParams* params)
        {
            Base::finishCreation(vm);
            ASSERT(inherits(info()));
            m_params.set(vm, this, params);
        }

        JSC::WriteBarrier<JSColloURLSearchParams> m_params;
        unsigned m_index { 0 };
        SearchParamsIteratorKind m_kind;
    };

    static String stripLeading(String value, char16_t prefix)
    {
        if (!value.isEmpty() && value[0] == prefix)
            return value.substring(1);
        return value;
    }

    // Throws a QuotaExceededError and returns true when `pair_count` exceeds WebApiUrlSearchParamsPairsMax. The pair
    // count needs a bound of its own because every pair carries metadata beyond its Strings; the constant's
    // declaration in `limits.h` derives the bound.
    static bool searchParamsPairCapExceeded(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, size_t pair_count)
    {
        if (pair_count <= WebApiUrlSearchParamsPairsMax)
            return false;
        JSC::throwException(global_object, scope,
            createDOMException(global_object, DOMExceptionCode::QuotaExceededError,
                "URLSearchParams exceeds the serverless pair count limit"_s));
        return true;
    }

    static WTF::URLParser::URLEncodedForm parseSearchParams(String value)
    {
        value = stripLeading(value, '?');
        return WTF::URLParser::parseURLEncodedForm(value);
    }

    static JSColloURLSearchParams* requireSearchParams(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
    {
        if (auto* object = dynamicDowncast<JSColloURLSearchParams>(value))
            return object;
        JSC::throwVMTypeError(global_object, scope, "URLSearchParams method called on incompatible receiver"_s);
        return nullptr;
    }

    static JSColloURLSearchParamsIterator* requireSearchParamsIterator(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
    {
        if (auto* object = dynamicDowncast<JSColloURLSearchParamsIterator>(value))
            return object;
        JSC::throwVMTypeError(
            global_object, scope, "URLSearchParams Iterator method called on incompatible receiver"_s);
        return nullptr;
    }

    static bool requireArgumentCount(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        JSC::CallFrame* call_frame, unsigned count, WTF::ASCIILiteral message)
    {
        if (call_frame->argumentCount() >= count)
            return true;
        JSC::throwVMTypeError(global_object, scope, message);
        return false;
    }

    static String valueToURLSearchParamsString(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
    {
        auto string = valueToWebApiString(global_object, scope, value);
        RETURN_IF_EXCEPTION(scope, {});
        return toWebApiUSVString(WTF::move(string));
    }

    static String argumentToURLSearchParamsString(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::CallFrame* call_frame, unsigned index)
    {
        return valueToURLSearchParamsString(global_object, scope, call_frame->argument(index));
    }

    static bool appendIterablePair(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        WTF::URLParser::URLEncodedForm& pairs, JSValue pair_value)
    {
        JSC::MarkedArgumentBuffer values;

        JSC::forEachInIterable(global_object, pair_value, [&](JSC::VM&, JSC::JSGlobalObject*, JSValue next_value) {
            if (scope.exception())
                return;
            if (values.size() >= 2) {
                JSC::throwVMTypeError(
                    global_object, scope, "URLSearchParams init pair must contain exactly two items"_s);
                return;
            }
            values.append(next_value);
            if (values.hasOverflowed())
                JSC::throwOutOfMemoryError(global_object, scope);
        });
        RETURN_IF_EXCEPTION(scope, false);

        if (values.size() != 2) {
            JSC::throwVMTypeError(global_object, scope, "URLSearchParams init pair must contain exactly two items"_s);
            return false;
        }

        auto key = valueToURLSearchParamsString(global_object, scope, values.at(0));
        RETURN_IF_EXCEPTION(scope, false);
        auto value = valueToURLSearchParamsString(global_object, scope, values.at(1));
        RETURN_IF_EXCEPTION(scope, false);
        pairs.append({ WTF::move(key), WTF::move(value) });
        return true;
    }

    static WTF::URLParser::URLEncodedForm createSearchParamsPairs(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue init)
    {
        WTF::URLParser::URLEncodedForm pairs;
        if (init.isUndefinedOrNull())
            return pairs;

        if (init.isString()) {
            auto text = valueToURLSearchParamsString(global_object, scope, init);
            RETURN_IF_EXCEPTION(scope, {});
            auto parsed = parseSearchParams(text);
            if (searchParamsPairCapExceeded(global_object, scope, parsed.size()))
                return {};
            return parsed;
        }

        if (auto* object = dynamicDowncast<JSC::JSObject>(init)) {
            auto iterator_method = JSC::iteratorMethod(global_object, object);
            RETURN_IF_EXCEPTION(scope, {});
            if (!iterator_method.isUndefinedOrNull()) {
                JSC::forEachInIterable(global_object, init, [&](JSC::VM&, JSC::JSGlobalObject*, JSValue pair_value) {
                    if (scope.exception())
                        return;
                    if (searchParamsPairCapExceeded(global_object, scope, pairs.size() + 1))
                        return;
                    appendIterablePair(global_object, scope, pairs, pair_value);
                });
                RETURN_IF_EXCEPTION(scope, {});
                return pairs;
            }

            auto& vm = global_object->vm();
            JSC::PropertyNameArrayBuilder property_names(
                vm, JSC::PropertyNameMode::Strings, JSC::PrivateSymbolMode::Exclude);
            JSC::JSObject::getOwnPropertyNames(
                object, global_object, property_names, JSC::DontEnumPropertiesMode::Exclude);
            RETURN_IF_EXCEPTION(scope, {});

            for (auto& property : property_names) {
                auto property_value = object->get(global_object, property);
                RETURN_IF_EXCEPTION(scope, {});
                auto key = toWebApiUSVString(property.string());
                auto value = valueToURLSearchParamsString(global_object, scope, property_value);
                RETURN_IF_EXCEPTION(scope, {});
                // Distinct property keys can convert to one USVString, since every lone surrogate becomes U+FFFD.
                // WebIDL's record conversion then keeps the first key's position and the last key's value.
                auto existing = pairs.findIf([&key](auto& pair) { return pair.key == key; });
                if (existing != WTF::notFound) {
                    pairs[existing].value = WTF::move(value);
                    continue;
                }
                if (searchParamsPairCapExceeded(global_object, scope, pairs.size() + 1))
                    return {};
                pairs.append({ WTF::move(key), WTF::move(value) });
            }
            return pairs;
        }

        auto text = valueToURLSearchParamsString(global_object, scope, init);
        RETURN_IF_EXCEPTION(scope, {});
        auto parsed = parseSearchParams(text);
        if (searchParamsPairCapExceeded(global_object, scope, parsed.size()))
            return {};
        return parsed;
    }

    JSC_DEFINE_HOST_FUNCTION(urlSearchParamsConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        return JSC::throwVMTypeError(global_object, scope, "URLSearchParams constructor requires 'new'"_s);
    }

    static JSC::Structure* urlSearchParamsStructureForNewTarget(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::CallFrame* call_frame)
    {
        auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
        auto* new_target = call_frame->newTarget().getObject();
        auto* constructor = call_frame->jsCallee();
        auto* base = collo_global->urlSearchParamsStructure();
        RELEASE_ASSERT(base);
        if (!new_target || new_target == constructor)
            return base;
        auto* structure = JSC::InternalFunction::createSubclassStructure(global_object, new_target, base);
        RETURN_IF_EXCEPTION(scope, nullptr);
        return structure;
    }

    JSC_DEFINE_HOST_FUNCTION(
        urlSearchParamsConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);

        auto pairs = createSearchParamsPairs(global_object, scope, call_frame->argument(0));
        RETURN_IF_EXCEPTION(scope, {});
        auto* structure = urlSearchParamsStructureForNewTarget(global_object, scope, call_frame);
        RETURN_IF_EXCEPTION(scope, {});

        auto* object = JSColloURLSearchParams::create(
            vm, uncheckedDowncast<Collo::GlobalObject>(global_object), WTF::move(pairs), nullptr, structure);
        return JSValue::encode(object);
    }

    JSC_DEFINE_HOST_FUNCTION(urlSearchParamsGetSize, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* params = requireSearchParams(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(JSC::jsNumber(params->pairs().size()));
    }

    JSC_DEFINE_HOST_FUNCTION(urlSearchParamsAppend, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* params = requireSearchParams(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (!requireArgumentCount(
                global_object, scope, call_frame, 2, "URLSearchParams.append requires a name and value"_s))
            return {};

        auto key = argumentToURLSearchParamsString(global_object, scope, call_frame, 0);
        RETURN_IF_EXCEPTION(scope, {});
        auto value = argumentToURLSearchParamsString(global_object, scope, call_frame, 1);
        RETURN_IF_EXCEPTION(scope, {});

        if (searchParamsPairCapExceeded(global_object, scope, params->pairs().size() + 1))
            return {};
        params->pairs().append({ WTF::move(key), WTF::move(value) });
        params->refreshGCReportedCost();
        params->syncAssociatedURL();
        return JSValue::encode(JSC::jsUndefined());
    }

    JSC_DEFINE_HOST_FUNCTION(urlSearchParamsDelete, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* params = requireSearchParams(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (!requireArgumentCount(global_object, scope, call_frame, 1, "URLSearchParams.delete requires a name"_s))
            return {};

        auto key = argumentToURLSearchParamsString(global_object, scope, call_frame, 0);
        RETURN_IF_EXCEPTION(scope, {});
        bool has_value = call_frame->argumentCount() > 1 && !call_frame->argument(1).isUndefined();
        String expected_value;
        if (has_value) {
            expected_value = argumentToURLSearchParamsString(global_object, scope, call_frame, 1);
            RETURN_IF_EXCEPTION(scope, {});
        }

        auto& pairs = params->pairs();
        unsigned write = 0;
        for (unsigned read = 0; read < pairs.size(); read++) {
            auto& pair = pairs[read];
            if (pair.key == key && (!has_value || pair.value == expected_value))
                continue;
            if (write != read)
                pairs[write] = WTF::move(pair);
            write++;
        }
        pairs.shrink(write);
        params->refreshGCReportedCost();
        params->syncAssociatedURL();
        return JSValue::encode(JSC::jsUndefined());
    }

    JSC_DEFINE_HOST_FUNCTION(urlSearchParamsGet, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* params = requireSearchParams(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (!requireArgumentCount(global_object, scope, call_frame, 1, "URLSearchParams.get requires a name"_s))
            return {};

        auto key = argumentToURLSearchParamsString(global_object, scope, call_frame, 0);
        RETURN_IF_EXCEPTION(scope, {});
        for (auto& pair : params->pairs()) {
            if (pair.key == key)
                return JSValue::encode(JSC::jsString(vm, pair.value));
        }
        return JSValue::encode(JSC::jsNull());
    }

    JSC_DEFINE_HOST_FUNCTION(urlSearchParamsGetAll, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* params = requireSearchParams(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (!requireArgumentCount(global_object, scope, call_frame, 1, "URLSearchParams.getAll requires a name"_s))
            return {};

        auto key = argumentToURLSearchParamsString(global_object, scope, call_frame, 0);
        RETURN_IF_EXCEPTION(scope, {});

        auto* result = JSC::constructEmptyArray(global_object, nullptr);
        unsigned index = 0;
        for (auto& pair : params->pairs()) {
            if (pair.key == key)
                result->putDirectIndex(global_object, index++, JSC::jsString(vm, pair.value));
        }
        return JSValue::encode(result);
    }

    JSC_DEFINE_HOST_FUNCTION(urlSearchParamsHas, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* params = requireSearchParams(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (!requireArgumentCount(global_object, scope, call_frame, 1, "URLSearchParams.has requires a name"_s))
            return {};

        auto key = argumentToURLSearchParamsString(global_object, scope, call_frame, 0);
        RETURN_IF_EXCEPTION(scope, {});
        bool has_value = call_frame->argumentCount() > 1 && !call_frame->argument(1).isUndefined();
        String expected_value;
        if (has_value) {
            expected_value = argumentToURLSearchParamsString(global_object, scope, call_frame, 1);
            RETURN_IF_EXCEPTION(scope, {});
        }

        for (auto& pair : params->pairs()) {
            if (pair.key == key && (!has_value || pair.value == expected_value))
                return JSValue::encode(JSC::jsBoolean(true));
        }
        return JSValue::encode(JSC::jsBoolean(false));
    }

    JSC_DEFINE_HOST_FUNCTION(urlSearchParamsSet, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* params = requireSearchParams(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (!requireArgumentCount(
                global_object, scope, call_frame, 2, "URLSearchParams.set requires a name and value"_s))
            return {};

        auto key = argumentToURLSearchParamsString(global_object, scope, call_frame, 0);
        RETURN_IF_EXCEPTION(scope, {});
        auto value = argumentToURLSearchParamsString(global_object, scope, call_frame, 1);
        RETURN_IF_EXCEPTION(scope, {});

        auto& pairs = params->pairs();
        bool found = false;
        unsigned write = 0;
        for (unsigned read = 0; read < pairs.size(); read++) {
            auto& pair = pairs[read];
            if (pair.key != key) {
                if (write != read)
                    pairs[write] = WTF::move(pair);
                write++;
                continue;
            }
            if (!found) {
                pair.value = value;
                if (write != read)
                    pairs[write] = WTF::move(pair);
                write++;
                found = true;
            }
        }
        pairs.shrink(write);
        if (!found) {
            if (searchParamsPairCapExceeded(global_object, scope, pairs.size() + 1))
                return {};
            pairs.append({ WTF::move(key), WTF::move(value) });
        }
        params->refreshGCReportedCost();
        params->syncAssociatedURL();
        return JSValue::encode(JSC::jsUndefined());
    }

    JSC_DEFINE_HOST_FUNCTION(urlSearchParamsSort, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* params = requireSearchParams(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});

        // The URL Standard sorts by code units and keeps pairs with equal names in order. Despite its name,
        // codePointCompareLessThan compares UTF-16 code units.
        std::stable_sort(params->pairs().begin(), params->pairs().end(),
            [](const auto& left, const auto& right) { return WTF::codePointCompareLessThan(left.key, right.key); });
        params->syncAssociatedURL();
        return JSValue::encode(JSC::jsUndefined());
    }

    JSC_DEFINE_HOST_FUNCTION(urlSearchParamsForEach, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* params = requireSearchParams(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (!requireArgumentCount(global_object, scope, call_frame, 1, "URLSearchParams.forEach requires a callback"_s))
            return {};

        auto callback = call_frame->argument(0);
        auto call_data = JSC::getCallData(callback);
        if (call_data.type == JSC::CallData::Type::None)
            return JSC::throwVMTypeError(global_object, scope, "URLSearchParams.forEach callback must be a function"_s);

        auto this_arg = call_frame->argument(1);
        for (unsigned index = 0; index < params->pairs().size(); index++) {
            auto key = params->pairs()[index].key;
            auto value = params->pairs()[index].value;
            JSC::MarkedArgumentBuffer arguments;
            arguments.append(JSC::jsString(vm, value));
            arguments.append(JSC::jsString(vm, key));
            arguments.append(params);
            if (arguments.hasOverflowed())
                return JSValue::encode(JSC::throwOutOfMemoryError(global_object, scope));
            JSC::call(global_object, callback, call_data, this_arg, arguments);
            RETURN_IF_EXCEPTION(scope, {});
        }
        return JSValue::encode(JSC::jsUndefined());
    }

    static JSValue createSearchParamsIterator(
        JSC::JSGlobalObject* global_object, JSColloURLSearchParams* params, SearchParamsIteratorKind kind)
    {
        auto& vm = global_object->vm();
        return JSColloURLSearchParamsIterator::create(
            vm, uncheckedDowncast<Collo::GlobalObject>(global_object), params, kind);
    }

    JSC_DEFINE_HOST_FUNCTION(urlSearchParamsEntries, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* params = requireSearchParams(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(createSearchParamsIterator(global_object, params, SearchParamsIteratorKind::Entries));
    }

    JSC_DEFINE_HOST_FUNCTION(urlSearchParamsKeys, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* params = requireSearchParams(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(createSearchParamsIterator(global_object, params, SearchParamsIteratorKind::Keys));
    }

    JSC_DEFINE_HOST_FUNCTION(urlSearchParamsValues, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* params = requireSearchParams(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(createSearchParamsIterator(global_object, params, SearchParamsIteratorKind::Values));
    }

    JSC_DEFINE_HOST_FUNCTION(urlSearchParamsToString, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* params = requireSearchParams(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(JSC::jsString(vm, WTF::URLParser::serialize(params->pairs())));
    }

    // toJSON is not part of the URL Standard. It returns one property per name, holding a string for a name that
    // occurs once and an array of values, in order, for a repeated name.
    struct SearchParamsJSONGroup {
        String key;
        WTF::Vector<String, 2> values;
    };

    JSC_DEFINE_HOST_FUNCTION(urlSearchParamsToJSON, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* params = requireSearchParams(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});

        WTF::Vector<SearchParamsJSONGroup, 4> groups;
        WTF::HashMap<String, unsigned> group_indices;
        for (auto& pair : params->pairs()) {
            auto add_result = group_indices.add(pair.key, groups.size());
            auto* group = add_result.isNewEntry ? nullptr : &groups[add_result.iterator->value];
            if (add_result.isNewEntry) {
                groups.append({ pair.key, {} });
                group = &groups.last();
            }
            group->values.append(pair.value);
        }

        auto* output = JSC::constructEmptyObject(global_object, global_object->objectPrototype(), groups.size());
        output->putDirect(vm, vm.propertyNames->toStringTagSymbol, JSC::jsNontrivialString(vm, "URLSearchParams"_s),
            JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);
        for (auto& group : groups) {
            auto identifier = JSC::Identifier::fromString(vm, group.key);
            if (group.values.size() == 1) {
                output->putDirectMayBeIndex(global_object, identifier, JSC::jsString(vm, group.values[0]));
                continue;
            }

            auto* array = JSC::constructEmptyArray(global_object, nullptr, group.values.size());
            for (unsigned value_index = 0; value_index < group.values.size(); value_index++)
                array->putDirectIndex(global_object, value_index, JSC::jsString(vm, group.values[value_index]));
            output->putDirectMayBeIndex(global_object, identifier, array);
        }

        return JSValue::encode(output);
    }

    JSC_DEFINE_HOST_FUNCTION(
        urlSearchParamsIteratorNext, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* iterator = requireSearchParamsIterator(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});

        auto* params = iterator->params();
        auto index = iterator->takeIndex();
        if (!params || index >= params->pairs().size())
            return JSValue::encode(JSC::createIteratorResultObject(global_object, JSC::jsUndefined(), true));

        auto& pair = params->pairs()[index];
        JSValue value;
        switch (iterator->kind()) {
        case SearchParamsIteratorKind::Entries:
            value = JSC::constructArrayPair(global_object, JSC::jsString(vm, pair.key), JSC::jsString(vm, pair.value));
            break;
        case SearchParamsIteratorKind::Keys:
            value = JSC::jsString(vm, pair.key);
            break;
        case SearchParamsIteratorKind::Values:
            value = JSC::jsString(vm, pair.value);
            break;
        }
        return JSValue::encode(JSC::createIteratorResultObject(global_object, value, false));
    }

    JSC_DEFINE_HOST_FUNCTION(urlSearchParamsIteratorIterator, (JSC::JSGlobalObject*, JSC::CallFrame* call_frame))
    {
        return JSValue::encode(call_frame->thisValue());
    }

} // namespace

const JSC::ClassInfo JSColloURLSearchParams::s_info
    = { "URLSearchParams"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloURLSearchParams) };
const JSC::ClassInfo JSColloURLSearchParamsIterator::s_info = { "URLSearchParams Iterator"_s, &Base::s_info, nullptr,
    nullptr, CREATE_METHOD_TABLE(JSColloURLSearchParamsIterator) };

size_t JSColloURLSearchParams::estimatedSize(JSC::JSCell* cell, JSC::VM& vm)
{
    auto* this_object = static_cast<JSColloURLSearchParams*>(cell);
    return saturatingAdd(Base::estimatedSize(cell, vm), this_object->memoryCost());
}

size_t JSColloURLSearchParams::memoryCost() const
{
    using Pair = WTF::URLParser::URLEncodedForm::ValueType;

    size_t cost = saturatingMultiply(m_pairs.capacity(), sizeof(Pair));
    for (auto& pair : m_pairs) {
        cost = saturatingAdd(cost, stringMemoryCost(pair.key));
        cost = saturatingAdd(cost, stringMemoryCost(pair.value));
    }
    return cost;
}

void JSColloURLSearchParams::reportInitialGCCost(JSC::VM& vm)
{
    refreshGCReportedCost();
    vm.heap.reportExtraMemoryAllocated(this, gcReportedCost());
}

void JSColloURLSearchParams::resetFromSearch(WTF::String search)
{
    m_pairs = parseSearchParams(WTF::move(search));
    // A URL setter can install a whole new pair set between two collections, so its cost is reported now; the
    // re-report from visitChildren corrects the total downward at the next full collection.
    refreshGCReportedCost();
    vm().heap.reportExtraMemoryAllocated(this, gcReportedCost());
}

void JSColloURLSearchParams::syncAssociatedURL()
{
    auto* associated_url = m_associated_url.get();
    if (!associated_url)
        return;
    syncURLSearchParamsToAssociatedURL(associated_url, m_pairs);
}

template <typename Visitor> void JSColloURLSearchParams::visitChildrenImpl(JSC::JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloURLSearchParams*>(cell);
    ASSERT_GC_OBJECT_INHERITS(this_object, info());
    Base::visitChildren(this_object, visitor);
    visitor.append(this_object->m_associated_url);
    // Keeps the extra memory reported at creation and on mutation counted across full collections. It reads the
    // cached cost because the concurrent marker must not walk the pair Strings while a mutator reallocates them.
    visitor.reportExtraMemoryVisited(this_object->gcReportedCost());
}

DEFINE_VISIT_CHILDREN(JSColloURLSearchParams);

template <typename Visitor> void JSColloURLSearchParamsIterator::visitChildrenImpl(JSC::JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloURLSearchParamsIterator*>(cell);
    ASSERT_GC_OBJECT_INHERITS(this_object, info());
    Base::visitChildren(this_object, visitor);
    visitor.append(this_object->m_params);
}

DEFINE_VISIT_CHILDREN(JSColloURLSearchParamsIterator);

URLSearchParamsApi createURLSearchParamsApi(Collo::GlobalObject* global_object, JSC::VM& vm)
{
    constexpr unsigned enumerableAccessor = static_cast<unsigned>(JSC::PropertyAttribute::Accessor);
    constexpr unsigned enumerableFunction = static_cast<unsigned>(JSC::PropertyAttribute::None);

    auto* params_prototype = JSC::constructEmptyObject(global_object);
    putWebApiFunction(global_object, params_prototype, vm, "append"_s, 2, urlSearchParamsAppend, enumerableFunction);
    putWebApiFunction(global_object, params_prototype, vm, "delete"_s, 1, urlSearchParamsDelete, enumerableFunction);
    putWebApiFunction(global_object, params_prototype, vm, "get"_s, 1, urlSearchParamsGet, enumerableFunction);
    putWebApiFunction(global_object, params_prototype, vm, "getAll"_s, 1, urlSearchParamsGetAll, enumerableFunction);
    putWebApiFunction(global_object, params_prototype, vm, "has"_s, 1, urlSearchParamsHas, enumerableFunction);
    putWebApiFunction(global_object, params_prototype, vm, "set"_s, 2, urlSearchParamsSet, enumerableFunction);
    putWebApiFunction(global_object, params_prototype, vm, "sort"_s, 0, urlSearchParamsSort, enumerableFunction);
    auto* entries_function = JSC::JSFunction::create(
        vm, global_object, 0, "entries"_s, urlSearchParamsEntries, JSC::ImplementationVisibility::Public);
    RELEASE_ASSERT(entries_function);
    JSC::Identifier entries_identifier = JSC::Identifier::fromString(vm, "entries"_s);
    params_prototype->putDirect(vm, entries_identifier, entries_function);
    RELEASE_ASSERT(params_prototype->getDirect(vm, entries_identifier));
    params_prototype->putDirect(vm, vm.propertyNames->iteratorSymbol, entries_function,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    putWebApiFunction(global_object, params_prototype, vm, "keys"_s, 0, urlSearchParamsKeys, enumerableFunction);
    putWebApiFunction(global_object, params_prototype, vm, "values"_s, 0, urlSearchParamsValues, enumerableFunction);
    putWebApiFunction(global_object, params_prototype, vm, "forEach"_s, 1, urlSearchParamsForEach, enumerableFunction);
    putWebApiFunction(
        global_object, params_prototype, vm, "toString"_s, 0, urlSearchParamsToString, enumerableFunction);
    putWebApiFunction(global_object, params_prototype, vm, "toJSON"_s, 0, urlSearchParamsToJSON, enumerableFunction);
    putWebApiAccessor(
        global_object, params_prototype, vm, "size"_s, urlSearchParamsGetSize, nullptr, enumerableAccessor);
    params_prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol,
        JSC::jsString(vm, WTF::makeString("URLSearchParams"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    auto* params_constructor
        = JSC::JSFunction::create(vm, global_object, 0, "URLSearchParams"_s, urlSearchParamsConstructorCall,
            JSC::ImplementationVisibility::Public, JSC::NoIntrinsic, urlSearchParamsConstructorConstruct, nullptr);
    RELEASE_ASSERT(params_constructor);
    params_constructor->putDirect(vm, vm.propertyNames->prototype, params_prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    params_prototype->putDirect(
        vm, vm.propertyNames->constructor, params_constructor, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    JSC::Identifier params_identifier = JSC::Identifier::fromString(vm, "URLSearchParams"_s);
    global_object->putDirect(
        vm, params_identifier, params_constructor, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    RELEASE_ASSERT(global_object->getDirect(vm, params_identifier));

    auto* iterator_prototype = JSC::constructEmptyObject(global_object);
    putWebApiFunction(
        global_object, iterator_prototype, vm, "next"_s, 0, urlSearchParamsIteratorNext, enumerableFunction);
    auto* iterator_function = JSC::JSFunction::create(vm, global_object, 0, "[Symbol.iterator]"_s,
        urlSearchParamsIteratorIterator, JSC::ImplementationVisibility::Public);
    RELEASE_ASSERT(iterator_function);
    iterator_prototype->putDirect(vm, vm.propertyNames->iteratorSymbol, iterator_function,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    iterator_prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol,
        JSC::jsString(vm, WTF::makeString("URLSearchParams Iterator"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    return {
        params_constructor,
        params_prototype,
        JSColloURLSearchParams::createStructure(vm, global_object, params_prototype),
        iterator_prototype,
        JSColloURLSearchParamsIterator::createStructure(vm, global_object, iterator_prototype),
    };
}

// Applies no pair cap. The pairs come from a URL the runtime already accepted, so that URL's length bounds them, and
// the callers (the URL `searchParams` getter and the request's query) cannot report a rejection: they store the
// result with WriteBarrier::set, which requires a non-null cell. reportInitialGCCost still charges the pairs to the
// GC; the cap guards the constructor, append and set, which take pairs from JavaScript.
JSColloURLSearchParams* createURLSearchParamsFromSearch(
    JSC::JSGlobalObject* global_object, WTF::String search, JSC::JSObject* associated_url)
{
    auto& vm = global_object->vm();
    return JSColloURLSearchParams::create(vm, uncheckedDowncast<Collo::GlobalObject>(global_object),
        parseSearchParams(WTF::move(search)), associated_url);
}

JSC::JSObject* createURLSearchParamsFromString(JSC::JSGlobalObject* global_object, WTF::String value)
{
    return createURLSearchParamsFromSearch(global_object, WTF::move(value), nullptr);
}

} // namespace Collo::HostFunctions

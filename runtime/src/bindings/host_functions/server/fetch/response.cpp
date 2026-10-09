// The Response class's JavaScript surface and the ABI calls around it: creating a Response or a body read result from
// host data, and extracting a handler's result into a ColloExtractedResponse for the host. The cell is JSColloResponse
// in response_object.h. VM thread only; every ABI call takes the JSC lock.
//
// A Response that an ABI call creates has immutable headers, as a fetch response has under the Fetch Standard. One
// built from JavaScript keeps its headers under the None guard, so a handler can set every header, Set-Cookie
// included. Native state that holds cell pointers is rooted by the conservative stack scan or, in the JSON
// serializer, by a MarkedArgumentBuffer.

#include "host_functions/server/fetch/response.h"

#include "host_functions/runtime/fetch_body.h"
#include "host_functions/server/fetch/body.h"
#include "host_functions/server/fetch/extracted_response.h"
#include "host_functions/server/fetch/headers.h"
#include "host_functions/server/fetch/response_body.h"
#include "host_functions/server/fetch/response_object.h"
#include "host_functions/webapi/dom/dom_exception.h"
#include "host_functions/webapi/limits.h"
#include "host_functions/webapi/streams/readable_stream.h"

#include <JavaScriptCore/ArrayConstructor.h>
#include <JavaScriptCore/BigIntObject.h>
#include <JavaScriptCore/BooleanObject.h>
#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/GetterSetter.h>
#include <JavaScriptCore/IdentifierInlines.h>
#include <JavaScriptCore/InternalFunction.h>
#include <JavaScriptCore/JSArrayInlines.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSDestructibleObject.h>
#include <JavaScriptCore/JSFunction.h>
#include <JavaScriptCore/JSGenericTypedArrayViewInlines.h>
#include <JavaScriptCore/JSObject.h>
#include <JavaScriptCore/JSString.h>
#include <JavaScriptCore/JSTypedArrays.h>
#include <JavaScriptCore/JSWrapperObject.h>
#include <JavaScriptCore/NumberObject.h>
#include <JavaScriptCore/PropertyNameArray.h>
#include <JavaScriptCore/SlotVisitorMacros.h>
#include <JavaScriptCore/StringObject.h>
#include <JavaScriptCore/VMInlines.h>
#include <wtf/FastMalloc.h>
#include <wtf/URL.h>
#include <wtf/Vector.h>
#include <wtf/text/CString.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/WTFString.h>

#include <cmath>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <new>
#include <span>

namespace Collo::HostFunctions {
namespace {

    using JSC::EncodedJSValue;
    using JSC::JSValue;
    using WTF::String;
    using namespace JSC;

    static JSColloResponse* requireResponse(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
    {
        if (auto* response = dynamicDowncast<JSColloResponse>(value))
            return response;
        JSC::throwVMTypeError(global_object, scope, "Response method called on incompatible receiver"_s);
        return nullptr;
    }

    static bool responseBodyStreamDisturbed(JSColloResponse* response)
    {
        auto* stream = response->bodyStream();
        return stream && readableStreamIsDisturbed(stream);
    }

    static EncodedJSValue rejectedResponseBodyAlreadyUsed(JSC::JSGlobalObject* global_object)
    {
        return rejectedTypeError(global_object, "body already used"_s);
    }

    static bool validResponseStatus(double value)
    {
        return std::isfinite(value) && std::trunc(value) == value && value >= 200 && value <= 599;
    }

    static bool isNullBodyStatus(uint16_t status) { return status == 204 || status == 205 || status == 304; }

    static bool isRedirectStatus(uint16_t status)
    {
        return status == 301 || status == 302 || status == 303 || status == 307 || status == 308;
    }

    // The reason-phrase grammar of RFC 9112 §4, which the Fetch Standard holds statusText to: HTAB, SP, VCHAR and
    // obs-text, so 0x09, 0x20 to 0x7E and 0x80 to 0xFF. The empty string passes.
    static bool isValidReasonPhrase(const String& value)
    {
        for (unsigned index = 0; index < value.length(); index++) {
            char16_t ch = value[index];
            if (ch == 0x09)
                continue;
            if (ch >= 0x20 && ch <= 0x7e)
                continue;
            if (ch >= 0x80 && ch <= 0xff)
                continue;
            return false;
        }
        return true;
    }

    // Guards the Location value, which setHeaderDefault stores without checking for NUL, CR or LF. A valid WTF::URL
    // never serializes those bytes raw, and this check keeps a header value from carrying a line break even if one did.
    static bool isHeaderValueSafe(const String& value)
    {
        for (unsigned index = 0; index < value.length(); index++) {
            char16_t ch = value[index];
            if (ch == '\0' || ch == '\r' || ch == '\n')
                return false;
        }
        return true;
    }

    extern "C" ColloStatus collo_fetch_read_result_new_copy(
        ColloRealm* realm, ColloBuffer bytes, uint8_t done, ColloValue** out_value, ColloValue** out_exception)
    {
        if (out_value)
            *out_value = nullptr;
        Collo::clearOutException(out_exception);
        if (!realmIsReady(realm) || !out_value)
            return COLLO_STATUS_INVALID_ARGUMENT;
        if (!bytes.ptr && bytes.len)
            return COLLO_STATUS_INVALID_ARGUMENT;

        ColloVm* owner = realm->vm;
        JSC::JSLockHolder locker(*owner->vm);
        auto& vm = *owner->vm;
        auto scope = DECLARE_THROW_SCOPE(vm);
        JSC::JSValue value = JSC::jsUndefined();
        if (!done) {
            auto* array = createBodyUint8ArrayCopy(
                realm->global_object, scope, std::span<const uint8_t> { bytes.ptr, bytes.len });
            if (!array) {
                if (scope.exception()) {
                    JSC::JSValue exception = scope.exception()->value();
                    if (!scope.tryClearException())
                        return COLLO_STATUS_JS_EXCEPTION;
                    return Collo::statusOr(
                        Collo::setJsException(owner, exception, out_exception), COLLO_STATUS_JS_EXCEPTION);
                }
                return COLLO_STATUS_OUT_OF_MEMORY;
            }
            value = array;
        }

        auto* object = createReadResultObject(realm->global_object, value, done);
        return Collo::makeValueHandle(owner, object, out_value);
    }

    static bool valueIsCallable(JSValue value)
    {
        if (!value.isCell())
            return false;
        return JSC::getCallData(value).type != JSC::CallData::Type::None;
    }

    // Its cell pointers, the headers and the PendingBody's stream, are rooted only by the conservative stack scan,
    // which is why it cannot live on the heap.
    struct ResponseData {
        WTF_FORBID_HEAP_ALLOCATION;

    public:
        uint16_t status { 200 };
        String status_text;
        String url;
        PendingBody body;
        JSC::JSObject* headers { nullptr };
        ResponseType type { ResponseType::Default };
        bool redirected { false };
    };

    static bool parseStatusValue(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue status_value, uint16_t& out_status)
    {
        double status = status_value.toNumber(global_object);
        RETURN_IF_EXCEPTION(scope, false);
        if (!validResponseStatus(status)) {
            JSC::throwVMRangeError(global_object, scope, "invalid Response status"_s);
            return false;
        }
        out_status = static_cast<uint16_t>(status);
        return true;
    }

    static JSValue propertyOrUndefined(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSObject* object, WTF::ASCIILiteral name);

    static bool parseRedirectStatusValue(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue init_value, uint16_t& out_status)
    {
        out_status = 302;
        if (init_value.isUndefined())
            return true;

        JSValue status_value = init_value;
        if (auto* object = dynamicDowncast<JSC::JSObject>(init_value)) {
            status_value = propertyOrUndefined(global_object, scope, object, "status"_s);
            RETURN_IF_EXCEPTION(scope, false);
            if (status_value.isUndefined())
                return true;
        }

        uint16_t status = 302;
        if (!parseStatusValue(global_object, scope, status_value, status))
            return false;
        if (!isRedirectStatus(status)) {
            JSC::throwVMRangeError(global_object, scope, "invalid Response redirect status"_s);
            return false;
        }
        out_status = status;
        return true;
    }

    static JSValue propertyOrUndefined(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSObject* object, WTF::ASCIILiteral name)
    {
        auto value = object->get(global_object, JSC::Identifier::fromString(global_object->vm(), name));
        RETURN_IF_EXCEPTION(scope, {});
        return value;
    }

    static bool parseResponseInit(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue init, ResponseData& data)
    {
        JSValue headers_init = JSC::jsUndefined();

        if (init.isUndefinedOrNull()) {
            data.headers = createHeadersFromJS(global_object, scope, JSC::jsUndefined());
            RETURN_IF_EXCEPTION(scope, false);
            return data.headers != nullptr;
        }

        auto* object = dynamicDowncast<JSC::JSObject>(init);
        if (!object) {
            JSC::throwVMTypeError(global_object, scope, "Response init must be an object"_s);
            return false;
        }

        JSValue status_value = propertyOrUndefined(global_object, scope, object, "status"_s);
        RETURN_IF_EXCEPTION(scope, false);
        if (!status_value.isUndefined() && !parseStatusValue(global_object, scope, status_value, data.status))
            return false;

        JSValue status_text = propertyOrUndefined(global_object, scope, object, "statusText"_s);
        RETURN_IF_EXCEPTION(scope, false);
        if (!status_text.isUndefined()) {
            String status_text_string = status_text.toWTFString(global_object);
            RETURN_IF_EXCEPTION(scope, false);
            if (!isValidReasonPhrase(status_text_string)) {
                JSC::throwVMTypeError(global_object, scope, "Invalid Response statusText"_s);
                return false;
            }
            data.status_text = WTF::move(status_text_string);
        }

        JSValue url = propertyOrUndefined(global_object, scope, object, "url"_s);
        RETURN_IF_EXCEPTION(scope, false);
        if (!url.isUndefined()) {
            data.url = url.toWTFString(global_object);
            RETURN_IF_EXCEPTION(scope, false);
        }

        headers_init = propertyOrUndefined(global_object, scope, object, "headers"_s);
        RETURN_IF_EXCEPTION(scope, false);
        data.headers = createHeadersFromJS(global_object, scope, headers_init);
        RETURN_IF_EXCEPTION(scope, false);
        return data.headers != nullptr;
    }

    static bool makeResponseData(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue body_value,
        JSValue init_value, ResponseData& data)
    {
        if (!parseResponseInit(global_object, scope, init_value, data))
            return false;
        RETURN_IF_EXCEPTION(scope, false);

        if (!body_value.isUndefinedOrNull()) {
            if (isNullBodyStatus(data.status)) {
                JSC::throwVMTypeError(global_object, scope, "Response body is not allowed for null-body status"_s);
                return false;
            }

            BodyInitResult parsed_body;
            if (!createBodyStateFromJS(global_object, scope, body_value, parsed_body))
                return false;
            RETURN_IF_EXCEPTION(scope, false);
            data.body = WTF::move(parsed_body.body);
            if (!parsed_body.content_type.isEmpty()) {
                setHeaderDefault(
                    global_object, scope, data.headers, "content-type"_s, WTF::move(parsed_body.content_type));
                RETURN_IF_EXCEPTION(scope, false);
            }
        }

        return true;
    }

    static JSColloResponse* createResponseObject(
        JSC::JSGlobalObject* global_object, ResponseData&& data, JSC::Structure* structure = nullptr)
    {
        return JSColloResponse::create(global_object->vm(), uncheckedDowncast<Collo::GlobalObject>(global_object),
            data.status, WTF::move(data.status_text), WTF::move(data.url), WTF::move(data.body), data.headers,
            data.type, data.redirected, structure);
    }

    static JSC::Structure* responseStructureForNewTarget(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::CallFrame* call_frame)
    {
        auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
        auto* new_target = call_frame->newTarget().getObject();
        auto* constructor = call_frame->jsCallee();
        auto* base = collo_global->responseStructure();
        RELEASE_ASSERT(base);
        if (!new_target || new_target == constructor)
            return base;
        auto* structure = JSC::InternalFunction::createSubclassStructure(global_object, new_target, base);
        RETURN_IF_EXCEPTION(scope, nullptr);
        return structure;
    }

    JSC_DEFINE_HOST_FUNCTION(responseConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        return JSC::throwVMTypeError(global_object, scope, "Response constructor requires 'new'"_s);
    }

    JSC_DEFINE_HOST_FUNCTION(
        responseConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);

        ResponseData data;
        if (!makeResponseData(global_object, scope, call_frame->argument(0), call_frame->argument(1), data))
            return {};
        RETURN_IF_EXCEPTION(scope, {});
        auto* structure = responseStructureForNewTarget(global_object, scope, call_frame);
        RETURN_IF_EXCEPTION(scope, {});

        return JSValue::encode(createResponseObject(global_object, WTF::move(data), structure));
    }

    JSC_DEFINE_HOST_FUNCTION(responseRedirectStatic, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);

        String location_input = call_frame->argument(0).toWTFString(global_object);
        RETURN_IF_EXCEPTION(scope, {});

        // The Fetch Standard's Response.redirect stores the serialized parsed URL in Location, not the input string.
        WTF::URL parsed_location(location_input);
        if (!parsed_location.isValid()) {
            JSC::throwVMTypeError(global_object, scope, "Failed to parse URL from Response.redirect"_s);
            return {};
        }
        String location = parsed_location.string();
        if (!isHeaderValueSafe(location)) {
            JSC::throwVMTypeError(global_object, scope, "Failed to parse URL from Response.redirect"_s);
            return {};
        }

        uint16_t status = 302;
        if (!parseRedirectStatusValue(global_object, scope, call_frame->argument(1), status))
            return {};
        RETURN_IF_EXCEPTION(scope, {});

        ResponseData data;
        data.status = status;
        data.headers = createHeadersFromJS(global_object, scope, JSC::jsUndefined());
        RETURN_IF_EXCEPTION(scope, {});
        if (!data.headers)
            return {};
        data.body.state = BodyState::empty();
        setHeaderDefault(global_object, scope, data.headers, "location"_s, WTF::move(location));
        RETURN_IF_EXCEPTION(scope, {});

        return JSValue::encode(createResponseObject(global_object, WTF::move(data)));
    }

    JSC_DEFINE_HOST_FUNCTION(responseErrorStatic, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);

        ResponseData data;
        data.status = 0;
        data.type = ResponseType::Error;
        data.headers = createHeadersFromJS(global_object, scope, JSC::jsUndefined());
        RETURN_IF_EXCEPTION(scope, {});
        if (!data.headers)
            return {};
        data.body.state = BodyState::empty();

        return JSValue::encode(createResponseObject(global_object, WTF::move(data)));
    }

    // Response.json serializes under a budget of UTF-16 code units. JSC::JSONStringify materializes the whole
    // serialization before its size can be measured, so an oversized value would allocate without bound before
    // responseJsonStatic could reject it. BudgetedJSONStringifier follows the general path of JSONObject.cpp's
    // Stringifier with replacer and space fixed to undefined, which Response.json never exposes, and checks the budget
    // after every append, stopping with BudgetExceeded once the builder passes it. A string is checked before it is
    // escaped, and escaping grows it at most sixfold, the worst case appendQuotedJSONString reserves for, so the walk
    // materializes O(budget) code units at most. A string never has more UTF-16 code units than UTF-8 bytes, so the
    // budget rejects only bodies whose UTF-8 form is over the cap too; responseJsonStatic still measures the UTF-8
    // length of a result within the budget. A value within the budget serializes as JSON.stringify serializes it: the
    // same toJSON calls, property order and error messages, with each getter run once.

    // JSONObject.cpp's maximumSideStackRecursion.
    constexpr unsigned BudgetedJSONMaximumSideStackRecursion = 40000;

    class BudgetedJSONStringifier {
    public:
        enum class Result : uint8_t {
            Succeeded,
            Failed,
            FailedDueToUndefinedOrSymbolValue,
            BudgetExceeded,
        };

        BudgetedJSONStringifier(JSC::JSGlobalObject* global_object, size_t budget_code_units)
            : m_global_object(global_object)
            , m_budget(budget_code_units)
        {
        }

        BudgetedJSONStringifier(const BudgetedJSONStringifier&) = delete;
        BudgetedJSONStringifier& operator=(const BudgetedJSONStringifier&) = delete;

        Result serialize(WTF::StringBuilder& builder, JSValue value)
        {
            auto& vm = m_global_object->vm();
            return appendStringifiedValue(
                builder, value, false, PropertyKey { vm.propertyNames->emptyIdentifier.impl() });
        }

    private:
        // The key toJSON receives, made into a JSValue only when toJSON is called, as JSONObject.cpp's
        // PropertyNameForFunctionCall does. Only the conservative stack scan roots `cached`, so a PropertyKey must
        // live only on the stack.
        struct PropertyKey {
            explicit PropertyKey(WTF::UniquedStringImpl* uid)
                : uid(uid)
            {
            }
            explicit PropertyKey(unsigned number)
                : number(number)
            {
            }

            JSValue value(JSC::VM& vm) const
            {
                if (!cached)
                    cached = JSC::jsString(vm, uid ? WTF::String { uid } : WTF::String::number(number));
                return cached;
            }

            WTF::UniquedStringImpl* uid { nullptr };
            unsigned number { 0 };
            mutable JSValue cached {};
        };

        struct Holder {
            JSC::JSObject* object { nullptr };
            WTF::RefPtr<JSC::PropertyNameArray> property_names;
            unsigned index { 0 };
            unsigned size { 0 };
            bool is_array { false };
            bool is_js_array { false };
            bool initialized { false };
        };

        enum class Step : uint8_t {
            Continue,
            Finished,
            BudgetExceeded,
        };

        bool withinBudget(const WTF::StringBuilder& builder) const
        {
            return !builder.hasOverflowed() && builder.length() <= m_budget;
        }

        bool stringFitsBudget(const WTF::StringBuilder& builder, size_t length) const
        {
            return length <= m_budget && !builder.hasOverflowed() && builder.length() <= m_budget - length;
        }

        Result budgetChecked(const WTF::StringBuilder& builder) const
        {
            return withinBudget(builder) ? Result::Succeeded : Result::BudgetExceeded;
        }

        // JSONObject.cpp's unwrapBoxedPrimitive. A SymbolObject stays wrapped, as ECMA-262's SerializeJSONProperty
        // requires.
        JSValue unwrapBoxedPrimitive(JSValue value)
        {
            if (!value.isObject())
                return value;
            auto* object = asObject(value);
            if (object->inherits<JSC::NumberObject>())
                return JSC::jsNumber(object->toNumber(m_global_object));
            if (object->inherits<JSC::StringObject>())
                return object->toString(m_global_object);
            if (object->inherits<JSC::BooleanObject>() || object->inherits<JSC::BigIntObject>())
                return uncheckedDowncast<JSC::JSWrapperObject>(object)->internalValue();
            return object;
        }

        // JSONObject.cpp's Stringifier::toJSON without its per-structure cache of the toJSON lookup, which changes no
        // result.
        JSValue callToJSONIfNeeded(JSValue base, const PropertyKey& property_key)
        {
            auto& vm = m_global_object->vm();
            auto scope = DECLARE_THROW_SCOPE(vm);
            JSC::PropertySlot slot(base, JSC::PropertySlot::InternalMethodType::Get);
            bool has_property = base.getPropertySlot(m_global_object, vm.propertyNames->toJSON, slot);
            RETURN_IF_EXCEPTION(scope, {});
            JSValue to_json
                = has_property ? slot.getValue(m_global_object, vm.propertyNames->toJSON) : JSC::jsUndefined();
            RETURN_IF_EXCEPTION(scope, {});
            auto call_data = JSC::getCallData(to_json);
            if (call_data.type == JSC::CallData::Type::None)
                return base;
            JSC::MarkedArgumentBuffer arguments;
            arguments.append(property_key.value(vm));
            ASSERT(!arguments.hasOverflowed());
            RELEASE_AND_RETURN(scope, JSC::call(m_global_object, asObject(to_json), call_data, base, arguments));
        }

        Result appendStringifiedValue(
            WTF::StringBuilder& builder, JSValue value, bool holder_is_array, const PropertyKey& property_key)
        {
            auto& vm = m_global_object->vm();
            auto scope = DECLARE_THROW_SCOPE(vm);

            if (!vm.isSafeToRecurseSoft()) [[unlikely]] {
                JSC::throwStackOverflowError(m_global_object, scope);
                return Result::Failed;
            }

            if (value.isObject() || value.isBigInt()) {
                value = callToJSONIfNeeded(value, property_key);
                RETURN_IF_EXCEPTION(scope, Result::Failed);
            }

            if ((value.isUndefined() || value.isSymbol()) && !holder_is_array)
                return Result::FailedDueToUndefinedOrSymbolValue;

            if (value.isObject()) {
                auto* raw_object = asObject(value);
                // A JSON.rawJSON object, recognized by its structure: JSON.rawJSON creates every such object with the
                // global's rawJSONObjectStructure, which nothing else uses and whose ReadOnly rawJSON property holds
                // the string. JSONObject.cpp checks inherits<JSRawJSONObject>() instead.
                if (raw_object->structure() == m_global_object->rawJSONObjectStructure()) {
                    auto* raw_string
                        = dynamicDowncast<JSC::JSString>(raw_object->getDirect(vm, vm.propertyNames->rawJSON));
                    if (!raw_string)
                        return Result::Failed;
                    if (!stringFitsBudget(builder, raw_string->length()))
                        return Result::BudgetExceeded;
                    WTF::String string = raw_string->value(m_global_object);
                    RETURN_IF_EXCEPTION(scope, Result::Failed);
                    builder.append(WTF::move(string));
                    return budgetChecked(builder);
                }
                value = unwrapBoxedPrimitive(value);
                RETURN_IF_EXCEPTION(scope, Result::Failed);
            }

            if (value.isNull()) {
                builder.append("null"_s);
                return budgetChecked(builder);
            }

            if (value.isBoolean()) {
                builder.append(value.isTrue() ? "true"_s : "false"_s);
                return budgetChecked(builder);
            }

            if (value.isString()) {
                // The quoted form is at least as long as the raw string, so an over-budget length rejects before
                // anything is appended or a rope is resolved.
                if (!stringFitsBudget(builder, asString(value)->length()))
                    return Result::BudgetExceeded;
                auto string = asString(value)->value(m_global_object);
                RETURN_IF_EXCEPTION(scope, Result::Failed);
                builder.appendQuotedJSONString(string);
                return budgetChecked(builder);
            }

            if (value.isNumber()) {
                if (value.isInt32())
                    builder.append(value.asInt32());
                else {
                    double number = value.asNumber();
                    if (!std::isfinite(number))
                        builder.append("null"_s);
                    else
                        builder.append(number);
                }
                return budgetChecked(builder);
            }

            if (value.isBigInt()) {
                JSC::throwTypeError(m_global_object, scope, "JSON.stringify cannot serialize BigInt."_s);
                return Result::Failed;
            }

            if (!value.isObject())
                return Result::Failed;

            auto* object = asObject(value);
            if (object->isCallable()) {
                if (holder_is_array) {
                    builder.append("null"_s);
                    return budgetChecked(builder);
                }
                return Result::FailedDueToUndefinedOrSymbolValue;
            }

            for (unsigned index = 0; index < m_holder_stack.size(); index++) {
                if (m_holder_stack[index].object == object) {
                    JSC::throwTypeError(m_global_object, scope, "JSON.stringify cannot serialize cyclic structures."_s);
                    return Result::Failed;
                }
            }
            if (m_holder_stack.size() >= BudgetedJSONMaximumSideStackRecursion) [[unlikely]] {
                JSC::throwStackOverflowError(m_global_object, scope);
                return Result::Failed;
            }

            bool holder_stack_was_empty = m_holder_stack.isEmpty();
            Holder holder;
            holder.object = object;
            holder.is_js_array = JSC::isJSArray(object);
            holder.is_array = JSC::isArray(m_global_object, object);
            RETURN_IF_EXCEPTION(scope, Result::Failed);
            m_holder_stack.append(WTF::move(holder));
            m_object_stack.appendWithCrashOnOverflow(object);
            if (!holder_stack_was_empty)
                return Result::Succeeded;

            do {
                while (true) {
                    auto step = appendNextProperty(m_holder_stack.last(), builder);
                    RETURN_IF_EXCEPTION(scope, Result::Failed);
                    if (step == Step::BudgetExceeded)
                        return Result::BudgetExceeded;
                    if (step == Step::Finished)
                        break;
                }
                m_holder_stack.removeLast();
                m_object_stack.removeLast();
            } while (!m_holder_stack.isEmpty());
            return Result::Succeeded;
        }

        Step appendNextProperty(Holder& holder, WTF::StringBuilder& builder)
        {
            auto& vm = m_global_object->vm();
            auto scope = DECLARE_THROW_SCOPE(vm);

            if (!holder.initialized) {
                holder.initialized = true;
                if (holder.is_array) {
                    uint64_t length = JSC::toLength(m_global_object, holder.object);
                    RETURN_IF_EXCEPTION(scope, Step::Finished);
                    if (length > std::numeric_limits<uint32_t>::max()) [[unlikely]] {
                        JSC::throwOutOfMemoryError(m_global_object, scope);
                        return Step::Finished;
                    }
                    holder.size = static_cast<uint32_t>(length);
                    builder.append('[');
                } else {
                    JSC::PropertyNameArrayBuilder property_names(
                        vm, JSC::PropertyNameMode::Strings, JSC::PrivateSymbolMode::Exclude);
                    holder.object->methodTable()->getOwnPropertyNames(
                        holder.object, m_global_object, property_names, JSC::DontEnumPropertiesMode::Exclude);
                    RETURN_IF_EXCEPTION(scope, Step::Finished);
                    holder.property_names = property_names.releaseData();
                    holder.size = holder.property_names->propertyNameVector().size();
                    builder.append('{');
                }
            }
            if (!withinBudget(builder))
                return Step::BudgetExceeded;

            if (holder.index == holder.size) {
                builder.append(holder.is_array ? ']' : '}');
                return withinBudget(builder) ? Step::Finished : Step::BudgetExceeded;
            }

            unsigned index = holder.index++;
            unsigned rollback_point = 0;
            Result result;
            if (holder.is_array) {
                JSValue element;
                if (holder.is_js_array && holder.object->canGetIndexQuickly(index))
                    element = holder.object->getIndexQuickly(index);
                else {
                    element = holder.object->get(m_global_object, index);
                    RETURN_IF_EXCEPTION(scope, Step::Finished);
                }
                if (index)
                    builder.append(',');
                result = appendStringifiedValue(builder, element, true, PropertyKey { index });
                ASSERT(result != Result::FailedDueToUndefinedOrSymbolValue);
            } else {
                JSC::PropertyName property_name = holder.property_names->propertyNameVector()[index];
                JSValue property_value = holder.object->get(m_global_object, property_name);
                RETURN_IF_EXCEPTION(scope, Step::Finished);

                rollback_point = builder.length();
                if (builder[rollback_point - 1] != '{')
                    builder.append(',');
                auto* uid = property_name.uid();
                if (!stringFitsBudget(builder, uid->length()))
                    return Step::BudgetExceeded;
                builder.appendQuotedJSONString(*uid);
                builder.append(':');
                result = appendStringifiedValue(builder, property_value, false, PropertyKey { uid });
            }
            RETURN_IF_EXCEPTION(scope, Step::Finished);

            // `holder` must not be touched past this point: the call above may have pushed onto m_holder_stack and
            // moved its buffer.
            switch (result) {
            case Result::Failed:
                builder.append("null"_s);
                break;
            case Result::Succeeded:
                break;
            case Result::FailedDueToUndefinedOrSymbolValue:
                // A property whose value is undefined, a symbol or a function is skipped, so the separator and name
                // already appended for it are removed.
                builder.shrink(rollback_point);
                break;
            case Result::BudgetExceeded:
                return Step::BudgetExceeded;
            }
            return withinBudget(builder) ? Step::Continue : Step::BudgetExceeded;
        }

        JSC::JSGlobalObject* const m_global_object;
        const size_t m_budget;
        // Roots every object on m_holder_stack, whose buffer moves to the heap past its inline capacity, out of reach
        // of the conservative stack scan.
        JSC::MarkedArgumentBufferWithSize<16> m_object_stack;
        WTF::Vector<Holder, 16> m_holder_stack;
    };

    JSC_DEFINE_HOST_FUNCTION(responseJsonStatic, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);

        JSValue value = call_frame->argument(0);
        if (value.isUndefined() || value.isSymbol() || value.isBigInt() || valueIsCallable(value)) {
            return JSC::throwVMTypeError(global_object, scope,
                value.isBigInt() ? "Do not know how to serialize a BigInt"_s : "Value is not JSON serializable"_s);
        }

        WTF::StringBuilder builder(WTF::OverflowPolicy::RecordOverflow);
        BudgetedJSONStringifier stringifier(global_object, WebApiMaterializedBodyBytesMax);
        auto serialize_result = stringifier.serialize(builder, value);
        RETURN_IF_EXCEPTION(scope, {});
        if (serialize_result == BudgetedJSONStringifier::Result::BudgetExceeded || builder.hasOverflowed()) {
            auto* exception = createDOMException(global_object, DOMExceptionCode::QuotaExceededError,
                "Response JSON body exceeds the serverless body limit"_s);
            return JSC::JSValue::encode(JSC::throwException(global_object, scope, exception));
        }
        if (serialize_result != BudgetedJSONStringifier::Result::Succeeded)
            return JSC::throwVMTypeError(global_object, scope, "Value is not JSON serializable"_s);
        auto body = builder.toString();
        if (!stringUtf8LengthWithinLimit(body, WebApiMaterializedBodyBytesMax)) {
            auto* exception = createDOMException(global_object, DOMExceptionCode::QuotaExceededError,
                "Response JSON body exceeds the serverless body limit"_s);
            return JSC::JSValue::encode(JSC::throwException(global_object, scope, exception));
        }

        ResponseData data;
        if (!parseResponseInit(global_object, scope, call_frame->argument(1), data))
            return {};
        RETURN_IF_EXCEPTION(scope, {});
        if (isNullBodyStatus(data.status))
            return JSC::throwVMTypeError(global_object, scope, "Response body is not allowed for null-body status"_s);
        data.body.state = BodyState::fromText(WTF::move(body));
        setHeaderDefault(global_object, scope, data.headers, "content-type"_s, "application/json"_s);
        RETURN_IF_EXCEPTION(scope, {});

        return JSValue::encode(createResponseObject(global_object, WTF::move(data)));
    }

    JSC_DEFINE_HOST_FUNCTION(responseGetStatus, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* response = requireResponse(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(JSC::jsNumber(response->status()));
    }

    JSC_DEFINE_HOST_FUNCTION(responseGetStatusText, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* response = requireResponse(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(JSC::jsString(vm, response->statusText()));
    }

    JSC_DEFINE_HOST_FUNCTION(responseGetUrl, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* response = requireResponse(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(JSC::jsString(vm, response->url()));
    }

    JSC_DEFINE_HOST_FUNCTION(responseGetType, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* response = requireResponse(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(JSC::jsString(vm, responseTypeString(response->type())));
    }

    JSC_DEFINE_HOST_FUNCTION(responseGetRedirected, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* response = requireResponse(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(JSC::jsBoolean(response->redirected()));
    }

    JSC_DEFINE_HOST_FUNCTION(responseGetBody, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* response = requireResponse(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (auto* stream = response->bodyStream())
            return JSValue::encode(stream);
        if (response->body().source() == BodyState::Source::Empty)
            return JSValue::encode(JSC::jsNull());
        auto source = ResponseBodySource::create(response);
        if (!source) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return {};
        }
        auto* stream = createReadableStreamFromNativeSource(global_object, scope, source.releaseNonNull());
        RETURN_IF_EXCEPTION(scope, {});
        if (!stream)
            return {};
        response->setBodyStream(vm, stream);
        return JSValue::encode(stream);
    }

    JSC_DEFINE_HOST_FUNCTION(responseGetHeaders, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* response = requireResponse(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(response->headers());
    }

    JSC_DEFINE_HOST_FUNCTION(responseGetOk, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* response = requireResponse(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(JSC::jsBoolean(response->ok()));
    }

    JSC_DEFINE_HOST_FUNCTION(responseGetBodyUsed, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* response = requireResponse(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(JSC::jsBoolean(response->bodyUsed()));
    }

    JSC_DEFINE_HOST_FUNCTION(responseText, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* response = requireResponse(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (responseBodyStreamDisturbed(response))
            return rejectedResponseBodyAlreadyUsed(global_object);
        return response->consumeText(global_object, scope, bodyAlreadyUsedMessage());
    }

    JSC_DEFINE_HOST_FUNCTION(responseJson, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* response = requireResponse(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (responseBodyStreamDisturbed(response))
            return rejectedResponseBodyAlreadyUsed(global_object);
        return response->consumeJson(global_object, scope, bodyAlreadyUsedMessage());
    }

    JSC_DEFINE_HOST_FUNCTION(responseArrayBuffer, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* response = requireResponse(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (responseBodyStreamDisturbed(response))
            return rejectedResponseBodyAlreadyUsed(global_object);
        return response->consumeArrayBuffer(global_object, scope, bodyAlreadyUsedMessage());
    }

    JSC_DEFINE_HOST_FUNCTION(responseBytes, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* response = requireResponse(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (responseBodyStreamDisturbed(response))
            return rejectedResponseBodyAlreadyUsed(global_object);
        return response->consumeBytes(global_object, scope, bodyAlreadyUsedMessage());
    }

    JSC_DEFINE_HOST_FUNCTION(responseBlob, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* response = requireResponse(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (responseBodyStreamDisturbed(response))
            return rejectedResponseBodyAlreadyUsed(global_object);

        String type;
        getHeaderValue(global_object, scope, response->headers(), "content-type"_s, type);
        RETURN_IF_EXCEPTION(scope, {});
        return response->consumeBlob(global_object, scope, bodyAlreadyUsedMessage(), WTF::move(type));
    }

    JSC_DEFINE_HOST_FUNCTION(responseFormData, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* response = requireResponse(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (responseBodyStreamDisturbed(response))
            return rejectedResponseBodyAlreadyUsed(global_object);

        String type;
        getHeaderValue(global_object, scope, response->headers(), "content-type"_s, type);
        RETURN_IF_EXCEPTION(scope, {});
        return response->consumeFormData(global_object, scope, bodyAlreadyUsedMessage(), WTF::move(type));
    }

    JSC_DEFINE_HOST_FUNCTION(responseClone, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* response = requireResponse(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (responseBodyStreamDisturbed(response)) {
            JSC::throwVMTypeError(global_object, scope, bodyAlreadyUsedMessage());
            return {};
        }

        PendingBody cloned_body;
        if (!response->cloneBody(global_object, scope, bodyAlreadyUsedMessage(), cloned_body))
            return {};
        RETURN_IF_EXCEPTION(scope, {});

        auto* cloned_headers = cloneHeadersPreservingGuard(global_object, scope, response->headers());
        RETURN_IF_EXCEPTION(scope, {});
        if (!cloned_headers)
            return {};

        return JSValue::encode(JSColloResponse::create(vm, uncheckedDowncast<Collo::GlobalObject>(global_object),
            response->status(), response->statusText(), response->url(), WTF::move(cloned_body), cloned_headers,
            response->type(), response->redirected()));
    }

    static ColloStatus fillExtractedResponse(ColloVm* vm, JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        JSColloResponse* response, const ColloResponseExtractLimits& limits, ColloExtractedResponse* out,
        ColloValue** out_exception)
    {
        out->status = response->status();

        HeaderExtractionStats header_stats;
        if (!inspectHeadersForExtraction(global_object, scope, response->headers(), header_stats)) {
            if (auto exception_status = consumeExceptionStatus(vm, scope, out_exception);
                exception_status != COLLO_STATUS_OK)
                return exception_status;
            return COLLO_STATUS_ERROR;
        }
        if (header_stats.count > limits.max_header_count)
            return COLLO_STATUS_RESPONSE_HEADER_COUNT_TOO_LARGE;
        if (header_stats.aggregate_bytes > limits.max_header_bytes)
            return COLLO_STATUS_RESPONSE_HEADER_BYTES_TOO_LARGE;

        if (response->body().source() == BodyState::Source::FetchStream) {
            if (!response->body().canTransferFetchStreamForHostResponse(
                    global_object, scope, "Response body is already used."_s)) {
                if (auto exception_status = consumeExceptionStatus(vm, scope, out_exception);
                    exception_status != COLLO_STATUS_OK)
                    return exception_status;
                return COLLO_STATUS_ERROR;
            }

            WTF::Vector<ColloHeaderPair> pairs;
            if (!collectHeadersToPairs(global_object, scope, response->headers(), pairs)) {
                if (auto exception_status = consumeExceptionStatus(vm, scope, out_exception);
                    exception_status != COLLO_STATUS_OK)
                    return exception_status;
                return COLLO_STATUS_ERROR;
            }

            auto status = copyHeadersToExtracted(pairs, limits, &out->headers);
            if (status != COLLO_STATUS_OK)
                return status;

            // The stream moves to the caller only after every step that can fail, so a failed extraction leaves the
            // fetch body with the Response.
            out->body.kind = COLLO_EXTRACTED_RESPONSE_BODY_FETCH_STREAM;
            out->body.stream_identity = response->body().transferFetchStreamForHostResponse();
            return COLLO_STATUS_OK;
        }

        size_t body_byte_length = 0;
        if (!response->body().byteLength(global_object, scope, body_byte_length)) {
            if (auto exception_status = consumeExceptionStatus(vm, scope, out_exception);
                exception_status != COLLO_STATUS_OK)
                return exception_status;
            return COLLO_STATUS_ERROR;
        }
        if (body_byte_length > limits.max_body_bytes)
            return COLLO_STATUS_RESPONSE_BODY_TOO_LARGE;

        if (!response->body().extractByteSegmentsForHostResponse(
                global_object, scope, body_byte_length, 64, out->body)) {
            if (auto exception_status = consumeExceptionStatus(vm, scope, out_exception);
                exception_status != COLLO_STATUS_OK)
                return exception_status;
            return COLLO_STATUS_ERROR;
        }

        WTF::Vector<ColloHeaderPair> pairs;
        if (!collectHeadersToPairs(global_object, scope, response->headers(), pairs)) {
            if (auto exception_status = consumeExceptionStatus(vm, scope, out_exception);
                exception_status != COLLO_STATUS_OK)
                return exception_status;
            return COLLO_STATUS_ERROR;
        }

        return copyHeadersToExtracted(pairs, limits, &out->headers);
    }

} // namespace

void installServerResponse(Collo::GlobalObject* global_object, JSC::VM& vm)
{
    auto* response_prototype = JSC::constructEmptyObject(global_object);
    putWebApiAccessor(global_object, response_prototype, vm, "status"_s, responseGetStatus);
    putWebApiAccessor(global_object, response_prototype, vm, "statusText"_s, responseGetStatusText);
    putWebApiAccessor(global_object, response_prototype, vm, "url"_s, responseGetUrl);
    putWebApiAccessor(global_object, response_prototype, vm, "type"_s, responseGetType);
    putWebApiAccessor(global_object, response_prototype, vm, "redirected"_s, responseGetRedirected);
    putWebApiAccessor(global_object, response_prototype, vm, "body"_s, responseGetBody);
    putWebApiAccessor(global_object, response_prototype, vm, "headers"_s, responseGetHeaders);
    putWebApiAccessor(global_object, response_prototype, vm, "ok"_s, responseGetOk);
    putWebApiAccessor(global_object, response_prototype, vm, "bodyUsed"_s, responseGetBodyUsed);
    putWebApiFunction(global_object, response_prototype, vm, "text"_s, 0, responseText);
    putWebApiFunction(global_object, response_prototype, vm, "json"_s, 0, responseJson);
    putWebApiFunction(global_object, response_prototype, vm, "arrayBuffer"_s, 0, responseArrayBuffer);
    putWebApiFunction(global_object, response_prototype, vm, "bytes"_s, 0, responseBytes);
    putWebApiFunction(global_object, response_prototype, vm, "blob"_s, 0, responseBlob);
    putWebApiFunction(global_object, response_prototype, vm, "formData"_s, 0, responseFormData);
    putWebApiFunction(global_object, response_prototype, vm, "clone"_s, 0, responseClone);
    response_prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol,
        JSC::jsString(vm, WTF::makeString("Response"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    auto* response_constructor = JSC::JSFunction::create(vm, global_object, 1, "Response"_s, responseConstructorCall,
        JSC::ImplementationVisibility::Public, JSC::NoIntrinsic, responseConstructorConstruct, nullptr);
    RELEASE_ASSERT(response_constructor);
    putWebApiFunction(global_object, response_constructor, vm, "json"_s, 2, responseJsonStatic);
    putWebApiFunction(global_object, response_constructor, vm, "redirect"_s, 1, responseRedirectStatic);
    putWebApiFunction(global_object, response_constructor, vm, "error"_s, 0, responseErrorStatic);
    response_constructor->putDirect(vm, vm.propertyNames->prototype, response_prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    response_prototype->putDirect(vm, vm.propertyNames->constructor, response_constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    JSC::Identifier response_identifier = JSC::Identifier::fromString(vm, "Response"_s);
    global_object->putDirect(
        vm, response_identifier, response_constructor, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    RELEASE_ASSERT(global_object->getDirect(vm, response_identifier));

    global_object->cacheResponseApi(response_constructor, response_prototype,
        JSColloResponse::createStructure(vm, global_object, response_prototype));
}

extern "C" ColloStatus collo_response_new(
    ColloRealm* realm, const ColloResponseInit* init, ColloValue** out_value, ColloValue** out_exception)
{
    if (out_value)
        *out_value = nullptr;
    Collo::clearOutException(out_exception);

    if (!realmIsReady(realm) || !init || !out_value)
        return COLLO_STATUS_INVALID_ARGUMENT;
    if ((init->body.len != 0 && !init->body.ptr) || (init->headers_len != 0 && !init->headers) || init->status < 200
        || init->status > 599)
        return COLLO_STATUS_INVALID_ARGUMENT;
    // As in the constructor, a null-body status (isNullBodyStatus) carries no body.
    if (init->body.len != 0 && isNullBodyStatus(init->status))
        return COLLO_STATUS_INVALID_ARGUMENT;

    ColloVm* vm = realm->vm;
    JSC::JSLockHolder locker(*vm->vm);
    auto scope = DECLARE_THROW_SCOPE(*vm->vm);

    String status_text;
    String url;
    if (Collo::stringToWTFString(init->status_text, status_text) != COLLO_STATUS_OK
        || Collo::stringToWTFString(init->url, url) != COLLO_STATUS_OK)
        return COLLO_STATUS_INVALID_ARGUMENT;
    // Host input is held to the statusText grammar the constructor enforces.
    if (!isValidReasonPhrase(status_text))
        return COLLO_STATUS_INVALID_ARGUMENT;

    WTF::Vector<uint8_t> body;
    if (init->body.len && !body.tryAppend(std::span<const uint8_t> { init->body.ptr, init->body.len }))
        return COLLO_STATUS_OUT_OF_MEMORY;

    auto* headers = createHeadersFromRawPairs(
        realm->global_object, scope, init->headers, init->headers_len, HeaderGuard::Immutable);
    if (auto status = consumeExceptionStatus(vm, scope, out_exception); status != COLLO_STATUS_OK)
        return status;
    if (!headers)
        return COLLO_STATUS_ERROR;

    PendingBody pending_body;
    if (!BodyState::fromBytes(WTF::move(body), pending_body.state))
        return COLLO_STATUS_OUT_OF_MEMORY;

    auto* object = JSColloResponse::create(*vm->vm, realm->global_object, init->status, WTF::move(status_text),
        WTF::move(url), WTF::move(pending_body), headers, ResponseType::Basic,
        (init->flags & COLLO_RESPONSE_INIT_FLAG_REDIRECTED) != 0);
    if (auto status = consumeExceptionStatus(vm, scope, out_exception); status != COLLO_STATUS_OK)
        return status;
    return Collo::makeValueHandle(vm, object, out_value);
}

extern "C" ColloStatus collo_fetch_response_new(
    ColloRealm* realm, const ColloFetchResponseInit* init, ColloValue** out_value, ColloValue** out_exception)
{
    if (out_value)
        *out_value = nullptr;
    Collo::clearOutException(out_exception);

    if (!realmIsReady(realm) || !init || !out_value)
        return COLLO_STATUS_INVALID_ARGUMENT;

    ColloVm* vm = realm->vm;
    const ColloResponseInit& response = init->response;
    // From here on the call owns init->body_identity: a failure before the Response exists releases it, and after
    // that the Response's body owns it.
    auto release_unattached_body = [&] {
        if (init->body_identity.body_id != 0)
            fetchBodyReleaseForIdentity(*vm, init->body_identity);
    };
    if (response.body.len != 0 || response.body.ptr || (response.headers_len != 0 && !response.headers)
        || response.status < 200 || response.status > 599 || init->body_identity.body_id == 0) {
        release_unattached_body();
        return COLLO_STATUS_INVALID_ARGUMENT;
    }

    JSC::JSLockHolder locker(*vm->vm);
    auto scope = DECLARE_THROW_SCOPE(*vm->vm);

    String status_text;
    String url;
    if (Collo::stringToWTFString(response.status_text, status_text) != COLLO_STATUS_OK
        || Collo::stringToWTFString(response.url, url) != COLLO_STATUS_OK) {
        release_unattached_body();
        return COLLO_STATUS_INVALID_ARGUMENT;
    }
    // Host input is held to the statusText grammar the constructor enforces.
    if (!isValidReasonPhrase(status_text)) {
        release_unattached_body();
        return COLLO_STATUS_INVALID_ARGUMENT;
    }

    auto* headers = createHeadersFromRawPairs(
        realm->global_object, scope, response.headers, response.headers_len, HeaderGuard::Immutable);
    if (auto status = consumeExceptionStatus(vm, scope, out_exception); status != COLLO_STATUS_OK) {
        release_unattached_body();
        return status;
    }
    if (!headers) {
        release_unattached_body();
        return COLLO_STATUS_ERROR;
    }

    PendingBody pending_body { BodyState::fetchStream(*vm, init->body_identity) };
    auto* object = JSColloResponse::create(*vm->vm, realm->global_object, response.status, WTF::move(status_text),
        WTF::move(url), WTF::move(pending_body), headers, ResponseType::Basic,
        (response.flags & COLLO_RESPONSE_INIT_FLAG_REDIRECTED) != 0);
    if (auto status = consumeExceptionStatus(vm, scope, out_exception); status != COLLO_STATUS_OK)
        return status;
    return Collo::makeValueHandle(vm, object, out_value);
}

extern "C" ColloStatus collo_response_extract(ColloVm* vm, const ColloValue* value,
    const ColloResponseExtractLimits* limits, ColloExtractedResponse* out_response, ColloValue** out_exception)
{
    if (out_response)
        resetExtractedResponse(out_response);
    Collo::clearOutException(out_exception);
    if (!vm || !vm->isReady() || !Collo::valueBelongsToVm(vm, value) || !limits || !out_response)
        return COLLO_STATUS_INVALID_ARGUMENT;

    JSC::JSLockHolder locker(*vm->vm);
    auto scope = DECLARE_THROW_SCOPE(*vm->vm);
    JSValue js_value = Collo::toJSValue(value);
    // The handler's realm, which a body stream it read from or an error it raises belongs to.
    auto* global_object = Collo::globalObjectForValue(vm, js_value);

    ColloStatus status = COLLO_STATUS_OK;
    if (auto* response = dynamicDowncast<JSColloResponse>(js_value)) {
        status = fillExtractedResponse(vm, global_object, scope, response, *limits, out_response, out_exception);
    } else {
        out_response->status = 200;
        String text = js_value.toWTFString(global_object);
        if (auto exception_status = consumeExceptionStatus(vm, scope, out_exception);
            exception_status != COLLO_STATUS_OK)
            return exception_status;
        if (stringUtf8LengthWithinLimit(text, limits->max_body_bytes)) {
            size_t body_byte_length = 0;
            BodyState body = BodyState::fromText(WTF::move(text));
            if (!body.byteLength(global_object, scope, body_byte_length)) {
                if (auto exception_status = consumeExceptionStatus(vm, scope, out_exception);
                    exception_status != COLLO_STATUS_OK)
                    return exception_status;
                status = COLLO_STATUS_ERROR;
            } else if (!body.extractByteSegmentsForHostResponse(
                           global_object, scope, body_byte_length, 64, out_response->body)) {
                if (auto exception_status = consumeExceptionStatus(vm, scope, out_exception);
                    exception_status != COLLO_STATUS_OK)
                    return exception_status;
                status = COLLO_STATUS_ERROR;
            }
        } else {
            status = COLLO_STATUS_RESPONSE_BODY_TOO_LARGE;
        }
        if (status == COLLO_STATUS_OK && out_response->body.total_len > limits->max_body_bytes)
            status = COLLO_STATUS_RESPONSE_BODY_TOO_LARGE;
    }

    if (status != COLLO_STATUS_OK) {
        collo_response_extract_free(out_response);
        return status;
    }
    if (auto exception_status = consumeExceptionStatus(vm, scope, out_exception); exception_status != COLLO_STATUS_OK) {
        collo_response_extract_free(out_response);
        return exception_status;
    }
    return COLLO_STATUS_OK;
}

} // namespace Collo::HostFunctions

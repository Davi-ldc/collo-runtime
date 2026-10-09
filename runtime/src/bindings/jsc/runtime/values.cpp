// The ABI's value constructors and accessors, a route's frozen `env` object, JSON parsing and exception formatting.
// Runs on the VM thread; each entry point takes the JSC API lock itself.
//
// Exception formatting runs after the turn that threw has ended, where no deadline bounds the VM, so it must never
// run tenant JavaScript: every read of the exception object is a VMInquiry lookup that runs no getter and no Proxy
// trap, and every part is copied only up to a fixed bound.

#include "jsc/runtime/state.h"

#include "host_functions/webapi/dom/dom_exception.h"

#include <JavaScriptCore/ArrayConventions.h>
#include <JavaScriptCore/ErrorInstanceInlines.h>
#include <JavaScriptCore/JSONObject.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <cstdlib>
#include <span>

namespace {

// The bound on each exception part, in UTF-16 units. The log ring cuts every published line at LOG_LINE_BYTES_MAX
// (common/worker_state/page/console_ring.zig), so converting a multi-megabyte message or stack only to cut it would
// copy the whole user string, and toWTFString would resolve a rope in full. JSValue::toString never resolves a rope,
// and a string over the bound is copied through JSString::colloCopyPrefix. The value equals LOG_LINE_BYTES_MAX plus
// console_unit_slack in console_client.cpp, the console's own unit cap, so the ring's byte cut still decides the
// final length.
constexpr unsigned kExceptionPartUnitsMax = 4112;

WTF::String boundedExceptionPart(ColloVm* vm, JSC::JSValue value)
{
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(*vm->vm);
    JSC::JSString* string = value.toString(vm->global_object);
    if (scope.exception()) {
        scope.clearExceptionExceptTermination();
        return WTF::String();
    }
    if (string->length() > kExceptionPartUnitsMax) [[unlikely]] {
        char16_t buffer[kExceptionPartUnitsMax];
        unsigned copied = string->colloCopyPrefix(std::span { buffer });
        return WTF::String(std::span { buffer }.first(copied));
    }
    WTF::String flat = string->value(vm->global_object);
    if (scope.exception()) {
        scope.clearExceptionExceptTermination();
        return WTF::String();
    }
    return flat;
}

// Reads a string-valued property without running tenant JavaScript. A VMInquiry slot limits the whole walk to work
// the program cannot observe: a Proxy anywhere in the chain taints the slot and reads as not found instead of
// running its trap, the prototype walk uses getPrototypeDirect instead of the getPrototypeOf trap, and an
// ErrorInstance still materializes its lazily stored name, message and stack inside its getOwnPropertySlot override,
// which is pure VM work, so real Error stacks still appear. The slot's DisallowVMEntry turns any attempt to enter
// the VM while it is alive into a hard failure, so the rule holds by construction. An accessor or custom slot would
// need a call out and reads as absent, as does any value that is not a string, so boundedExceptionPart only ever
// receives strings, on which toString is the identity.
JSC::JSValue inertStringProperty(ColloVm* vm, JSC::JSObject* object, JSC::PropertyName property)
{
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(*vm->vm);
    JSC::JSValue value;
    {
        JSC::PropertySlot slot(object, JSC::PropertySlot::InternalMethodType::VMInquiry, vm->vm.get());
        bool found = object->getPropertySlot(vm->global_object, property, slot);
        if (scope.exception()) {
            scope.clearExceptionExceptTermination();
            return {};
        }
        if (!found || !slot.isValue())
            return {};
        value = slot.getValue(vm->global_object, property);
    }
    if (scope.exception()) {
        scope.clearExceptionExceptTermination();
        return {};
    }
    if (!value.isString())
        return {};
    return value;
}

ColloStatus setTypeError(ColloVm* vm, const WTF::String& message, ColloValue** out_exception)
{
    return Collo::setJsException(vm, JSC::createTypeError(vm->global_object, message), out_exception);
}

ColloStatus typeError(ColloVm* vm, const WTF::String& message, ColloValue** out_exception)
{
    return Collo::statusOr(setTypeError(vm, message, out_exception), COLLO_STATUS_JS_EXCEPTION);
}

} // namespace

namespace Collo {

ColloStatus formatExceptionString(ColloVm* vm, JSC::JSValue exception_value, ColloString* out_string)
{
    if (!vm || !vm->isReady() || !out_string)
        return COLLO_STATUS_INVALID_ARGUMENT;

    out_string->ptr = nullptr;
    out_string->len = 0;

    // Every read of an exception object goes through inertStringProperty. The "Name: message" summary is composed
    // here rather than by calling toString on the object, because Error.prototype.toString, or a tenant override,
    // reads name and message with ordinary gets that run getters. A primitive is converted directly, since ToString
    // of a primitive never runs user code.
    WTF::String stack;
    WTF::String fallback;
    if (auto* object = dynamicDowncast<JSC::JSObject>(exception_value)) {
        WTF::String name;
        WTF::String message;
        // The bridge's DOMException keeps name and message as C++ members behind prototype accessors, which the
        // inert reads below cannot see, so they are read natively, still without a call out. It carries no stack.
        if (!HostFunctions::domExceptionNameAndMessage(exception_value, name, message)) {
            if (JSC::JSValue stack_value = inertStringProperty(vm, object, vm->vm->propertyNames->stack))
                stack = boundedExceptionPart(vm, stack_value);
            if (JSC::JSValue name_value = inertStringProperty(vm, object, vm->vm->propertyNames->name))
                name = boundedExceptionPart(vm, name_value);
            if (JSC::JSValue message_value = inertStringProperty(vm, object, vm->vm->propertyNames->message))
                message = boundedExceptionPart(vm, message_value);
        }
        if (name.isEmpty())
            fallback = message;
        else if (message.isEmpty())
            fallback = name;
        else
            fallback = WTF::makeString(name, ": "_s, message);
    } else {
        fallback = boundedExceptionPart(vm, exception_value);
    }

    // Best effort: a failed conversion or allocation, or an exception whose parts are accessors, proxied or absent,
    // degrades to a fixed string so the caller still gets a stable diagnostic.
    if (fallback.isNull())
        fallback = "Unformattable exception"_s;

    if (!stack.isNull() && !stack.isEmpty()) {
        if (!fallback.isNull() && !fallback.isEmpty() && !stack.startsWith(fallback)) {
            WTF::String formatted = WTF::makeString(fallback, '\n', stack);
            if (formatted.isNull())
                return copyWTFStringToColloString("Unformattable exception (allocation failed)"_s, out_string);
            return copyWTFStringToColloString(formatted, out_string);
        }
        return copyWTFStringToColloString(stack, out_string);
    }

    return copyWTFStringToColloString(fallback, out_string);
}

} // namespace Collo

extern "C" ColloStatus collo_json_parse_utf8(
    ColloVm* vm, ColloString source, ColloValue** out_value, ColloValue** out_exception)
{
    if (out_value)
        *out_value = nullptr;
    Collo::clearOutException(out_exception);
    if (!vm || !vm->isReady() || !out_value)
        return COLLO_STATUS_INVALID_ARGUMENT;

    WTF::String input;
    if (Collo::stringToWTFString(source, input) != COLLO_STATUS_OK)
        return COLLO_STATUS_INVALID_ARGUMENT;

    JSC::JSLockHolder locker(*vm->vm);
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(*vm->vm);
    JSC::JSValue parsed = JSC::JSONParse(vm->global_object, input);
    if (scope.exception()) {
        JSC::JSValue exception = scope.exception()->value();
        scope.clearExceptionExceptTermination();
        if (!exception)
            exception = JSC::createSyntaxError(vm->global_object, "Invalid JSON"_s);
        return Collo::statusOr(Collo::setJsException(vm, exception, out_exception), COLLO_STATUS_JS_EXCEPTION);
    }
    if (!parsed) {
        JSC::JSValue exception = JSC::createSyntaxError(vm->global_object, "Invalid JSON"_s);
        return Collo::statusOr(Collo::setJsException(vm, exception, out_exception), COLLO_STATUS_JS_EXCEPTION);
    }
    return Collo::makeValueHandle(vm, parsed, out_value);
}

extern "C" ColloStatus collo_value_retain(ColloValue* value, ColloValue** out_value)
{
    return Collo::retainValueHandle(value, out_value);
}

extern "C" void collo_value_release(ColloValue* value) { Collo::releaseValueHandle(value); }

extern "C" ColloStatus collo_value_is_callable(ColloVm* vm, const ColloValue* value, uint8_t* out_is_callable)
{
    if (out_is_callable)
        *out_is_callable = 0;

    if (!vm || !vm->isReady() || !Collo::valueBelongsToVm(vm, value) || !out_is_callable)
        return COLLO_STATUS_INVALID_ARGUMENT;

    JSC::JSLockHolder locker(*vm->vm);
    JSC::CallData call_data = JSC::getCallData(Collo::toJSValue(value));
    *out_is_callable = call_data.type != JSC::CallData::Type::None;
    return COLLO_STATUS_OK;
}

extern "C" ColloStatus collo_promise_await_sync(
    ColloVm* vm, const ColloValue* promise_value, ColloValue** out_value, ColloValue** out_exception)
{
    if (out_value)
        *out_value = nullptr;
    if (!vm || !vm->isReady() || vm->entered_count || vm->current_exec_ctx
        || !Collo::valueBelongsToVm(vm, promise_value) || !out_value)
        return COLLO_STATUS_INVALID_ARGUMENT;

    JSC::JSLockHolder locker(*vm->vm);
    Collo::clearOutException(out_exception);

    auto* promise = dynamicDowncast<JSC::JSPromise>(Collo::toJSValue(promise_value));
    if (!promise)
        return typeError(vm, "Expected a Promise."_s, out_exception);

    switch (promise->status()) {
    case JSC::JSPromise::Status::Fulfilled:
        return Collo::makeValueHandle(vm, promise->result(), out_value);
    case JSC::JSPromise::Status::Rejected:
        return Collo::statusOr(Collo::setJsException(vm, promise->result(), out_exception), COLLO_STATUS_JS_EXCEPTION);
    case JSC::JSPromise::Status::Pending:
        return Collo::statusOr(
            setTypeError(vm, "Only already-settled promises can be awaited synchronously."_s, out_exception),
            COLLO_STATUS_UNSUPPORTED);
    }
    return COLLO_STATUS_ERROR;
}

extern "C" ColloStatus collo_undefined(ColloVm* vm, ColloValue** out_value)
{
    if (!vm || !vm->isReady())
        return COLLO_STATUS_INVALID_ARGUMENT;
    JSC::JSLockHolder locker(*vm->vm);
    return Collo::makeValueHandle(vm, JSC::jsUndefined(), out_value);
}

extern "C" ColloStatus collo_null(ColloVm* vm, ColloValue** out_value)
{
    if (!vm || !vm->isReady())
        return COLLO_STATUS_INVALID_ARGUMENT;
    JSC::JSLockHolder locker(*vm->vm);
    return Collo::makeValueHandle(vm, JSC::jsNull(), out_value);
}

extern "C" ColloStatus collo_bool_new(ColloVm* vm, uint8_t value, ColloValue** out_value)
{
    if (!vm || !vm->isReady())
        return COLLO_STATUS_INVALID_ARGUMENT;
    JSC::JSLockHolder locker(*vm->vm);
    return Collo::makeValueHandle(vm, JSC::jsBoolean(!!value), out_value);
}

extern "C" ColloStatus collo_number_new(ColloVm* vm, double value, ColloValue** out_value)
{
    if (!vm || !vm->isReady())
        return COLLO_STATUS_INVALID_ARGUMENT;
    JSC::JSLockHolder locker(*vm->vm);
    return Collo::makeValueHandle(vm, JSC::jsNumber(value), out_value);
}

extern "C" ColloStatus collo_string_new_utf8(ColloVm* vm, ColloString utf8, ColloValue** out_value)
{
    if (!vm || !vm->isReady())
        return COLLO_STATUS_INVALID_ARGUMENT;

    WTF::String string;
    if (Collo::stringToWTFString(utf8, string) != COLLO_STATUS_OK)
        return COLLO_STATUS_INVALID_ARGUMENT;

    JSC::JSLockHolder locker(*vm->vm);
    return Collo::makeValueHandle(vm, JSC::jsString(*vm->vm, string), out_value);
}

extern "C" ColloStatus collo_type_error_new_utf8(ColloVm* vm, ColloString message, ColloValue** out_value)
{
    if (out_value)
        *out_value = nullptr;
    if (!vm || !vm->isReady() || !out_value)
        return COLLO_STATUS_INVALID_ARGUMENT;

    WTF::String text;
    if (Collo::stringToWTFString(message, text) != COLLO_STATUS_OK)
        return COLLO_STATUS_INVALID_ARGUMENT;

    JSC::JSLockHolder locker(*vm->vm);
    // JSC::createTypeError asserts that its message is not empty, so the error is created directly, with the
    // arguments createTypeError passes.
    JSC::Structure* structure = vm->global_object->errorStructure(JSC::ErrorType::TypeError);
    JSC::ErrorInstance* error = JSC::ErrorInstance::create(
        *vm->vm, structure, text, JSC::JSValue(), nullptr, JSC::TypeNothing, JSC::ErrorType::TypeError);
    return Collo::makeValueHandle(vm, error, out_value);
}

extern "C" ColloStatus collo_object_new(ColloVm* vm, ColloValue** out_value)
{
    if (!vm || !vm->isReady())
        return COLLO_STATUS_INVALID_ARGUMENT;

    JSC::JSLockHolder locker(*vm->vm);
    return Collo::makeValueHandle(vm, JSC::constructEmptyObject(vm->global_object), out_value);
}

extern "C" ColloStatus collo_array_new(ColloVm* vm, ColloValue** out_value)
{
    if (!vm || !vm->isReady())
        return COLLO_STATUS_INVALID_ARGUMENT;

    JSC::JSLockHolder locker(*vm->vm);
    JSC::JSArray* array = JSC::JSArray::create(
        *vm->vm, vm->global_object->arrayStructureForIndexingTypeDuringAllocation(JSC::ArrayWithUndecided), 0);
    return Collo::makeValueHandle(vm, array, out_value);
}

extern "C" ColloStatus collo_global_this(ColloVm* vm, ColloValue** out_value)
{
    if (!vm || !vm->isReady())
        return COLLO_STATUS_INVALID_ARGUMENT;

    JSC::JSLockHolder locker(*vm->vm);
    return Collo::makeValueHandle(vm, vm->global_object->globalThis(), out_value);
}

extern "C" ColloStatus collo_env_object_new(
    ColloVm* vm, const ColloNameValuePair* entries, size_t entry_count, ColloValue** out_value)
{
    if (out_value)
        *out_value = nullptr;
    if (!vm || !vm->isReady() || !out_value || (!entries && entry_count))
        return COLLO_STATUS_INVALID_ARGUMENT;

    JSC::JSLockHolder locker(*vm->vm);
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(*vm->vm);
    JSC::JSObject* env = JSC::constructEmptyObject(vm->global_object);
    // Every entry is checked before it is defined, and the object is published only after the last one, so a bad
    // entry leaves nothing behind for JavaScript to see.
    for (const ColloNameValuePair& entry : std::span { entries, entry_count }) {
        WTF::String name;
        WTF::String value;
        if (Collo::stringToWTFString(entry.name, name) != COLLO_STATUS_OK || name.isEmpty())
            return COLLO_STATUS_INVALID_ARGUMENT;
        if (Collo::stringToWTFString(entry.value, value) != COLLO_STATUS_OK)
            return COLLO_STATUS_INVALID_ARGUMENT;
        JSC::Identifier identifier = JSC::Identifier::fromString(*vm->vm, name);
        // putDirect stores named properties only and asserts that the name is not an array index.
        if (JSC::parseIndex(identifier))
            return COLLO_STATUS_INVALID_ARGUMENT;
        env->putDirect(*vm->vm, identifier, JSC::jsString(*vm->vm, value));
    }
    // A fresh ordinary object with named properties only takes the freeze fast path, which raises nothing; a
    // pending termination is the only exception this scope can see.
    JSC::objectConstructorFreeze(vm->global_object, env);
    if (scope.exception()) {
        scope.clearExceptionExceptTermination();
        return COLLO_STATUS_ERROR;
    }
    return Collo::makeValueHandle(vm, env, out_value);
}

extern "C" ColloStatus collo_object_get_utf8(
    ColloVm* vm, const ColloValue* object, ColloString key, ColloValue** out_value, ColloValue** out_exception)
{
    if (out_value)
        *out_value = nullptr;
    Collo::clearOutException(out_exception);

    if (!vm || !vm->isReady() || !Collo::valueBelongsToVm(vm, object) || !out_value)
        return COLLO_STATUS_INVALID_ARGUMENT;

    WTF::String property_name;
    if (Collo::stringToWTFString(key, property_name) != COLLO_STATUS_OK)
        return COLLO_STATUS_INVALID_ARGUMENT;

    JSC::JSLockHolder locker(*vm->vm);
    auto* js_object = dynamicDowncast<JSC::JSObject>(Collo::toJSValue(object));
    if (!js_object)
        return typeError(vm, "collo_object_get_utf8 expects an object."_s, out_exception);

    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(*vm->vm);
    JSC::JSValue value = js_object->get(vm->global_object, JSC::Identifier::fromString(*vm->vm, property_name));
    if (scope.exception())
        return Collo::caughtExceptionStatus(vm, scope, out_exception);

    return Collo::makeValueHandle(vm, value, out_value);
}

extern "C" ColloStatus collo_object_set_utf8(
    ColloVm* vm, const ColloValue* object, ColloString key, const ColloValue* value, ColloValue** out_exception)
{
    Collo::clearOutException(out_exception);

    if (!vm || !vm->isReady() || !Collo::valueBelongsToVm(vm, object) || !Collo::valueBelongsToVm(vm, value))
        return COLLO_STATUS_INVALID_ARGUMENT;

    WTF::String property_name;
    if (Collo::stringToWTFString(key, property_name) != COLLO_STATUS_OK)
        return COLLO_STATUS_INVALID_ARGUMENT;

    JSC::JSLockHolder locker(*vm->vm);
    auto* js_object = dynamicDowncast<JSC::JSObject>(Collo::toJSValue(object));
    if (!js_object)
        return typeError(vm, "collo_object_set_utf8 expects an object."_s, out_exception);

    JSC::Identifier identifier = JSC::Identifier::fromString(*vm->vm, property_name);
    JSC::PutPropertySlot slot(js_object, false, JSC::PutPropertySlot::PutById);
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(*vm->vm);
    JSC::JSObject::put(js_object, vm->global_object, identifier, Collo::toJSValue(value), slot);
    if (scope.exception())
        return Collo::caughtExceptionStatus(vm, scope, out_exception);

    return COLLO_STATUS_OK;
}

extern "C" ColloStatus collo_array_set(
    ColloVm* vm, const ColloValue* array, size_t index, const ColloValue* value, ColloValue** out_exception)
{
    Collo::clearOutException(out_exception);

    if (!vm || !vm->isReady() || !Collo::valueBelongsToVm(vm, array) || !Collo::valueBelongsToVm(vm, value))
        return COLLO_STATUS_INVALID_ARGUMENT;

    JSC::JSLockHolder locker(*vm->vm);
    auto* js_array = dynamicDowncast<JSC::JSArray>(Collo::toJSValue(array));
    if (!js_array)
        return typeError(vm, "collo_array_set expects an array."_s, out_exception);
    constexpr uint64_t max_js_array_index = static_cast<uint64_t>(MAX_ARRAY_INDEX);
    if (static_cast<uint64_t>(index) > max_js_array_index)
        return typeError(vm, "Array index exceeds JavaScript array length limit."_s, out_exception);

    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(*vm->vm);
    js_array->putDirectIndex(
        vm->global_object, static_cast<uint64_t>(index), Collo::toJSValue(value), 0, JSC::PutDirectIndexShouldThrow);
    if (scope.exception())
        return Collo::caughtExceptionStatus(vm, scope, out_exception);

    return COLLO_STATUS_OK;
}

extern "C" ColloStatus collo_value_to_utf8_copy(
    ColloVm* vm, const ColloValue* value, ColloString* out_string, ColloValue** out_exception)
{
    Collo::clearOutException(out_exception);

    if (out_string) {
        out_string->ptr = nullptr;
        out_string->len = 0;
    }

    if (!vm || !vm->isReady() || !Collo::valueBelongsToVm(vm, value) || !out_string)
        return COLLO_STATUS_INVALID_ARGUMENT;

    JSC::JSLockHolder locker(*vm->vm);
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(*vm->vm);
    WTF::String string = Collo::toJSValue(value).toWTFString(vm->global_object);
    if (scope.exception())
        return Collo::caughtExceptionStatus(vm, scope, out_exception);

    return Collo::copyWTFStringToColloString(string, out_string);
}

extern "C" ColloStatus collo_exception_format(ColloVm* vm, const ColloValue* exception, ColloString* out_string)
{
    if (out_string) {
        out_string->ptr = nullptr;
        out_string->len = 0;
    }

    if (!vm || !vm->isReady() || !Collo::valueBelongsToVm(vm, exception) || !out_string)
        return COLLO_STATUS_INVALID_ARGUMENT;

    JSC::JSLockHolder locker(*vm->vm);
    return Collo::formatExceptionString(vm, Collo::toJSValue(exception), out_string);
}

extern "C" void collo_free_buffer(const void* ptr)
{
    if (!ptr)
        return;
    std::free(const_cast<void*>(ptr));
}

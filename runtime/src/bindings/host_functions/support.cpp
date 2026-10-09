// The helpers support.h declares, run on the VM thread. The accessor and method helpers abort the process with
// RELEASE_ASSERT when what they create or define is missing afterwards; install in internal.h explains why that is
// the failure policy.

#include "host_functions/support.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/GetterSetter.h>
#include <JavaScriptCore/IdentifierInlines.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSFunction.h>
#include <JavaScriptCore/JSPromise.h>
#include <JavaScriptCore/JSString.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringBuilder.h>

namespace Collo::HostFunctions {

JSC::EncodedJSValue throwRuntimeError(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, WTF::ASCIILiteral message)
{
    return JSC::JSValue::encode(JSC::throwException(global_object, scope, JSC::createError(global_object, message)));
}

JSC::EncodedJSValue rejectedPromise(JSC::JSGlobalObject* global_object, JSC::JSValue reason)
{
    return JSC::JSValue::encode(JSC::JSPromise::rejectedPromise(global_object, reason));
}

JSC::EncodedJSValue rejectedPromise(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue reason)
{
    auto* promise = JSC::JSPromise::promiseReject(global_object, global_object->promiseConstructor(), reason);
    RETURN_IF_EXCEPTION(scope, {});
    return JSC::JSValue::encode(promise);
}

JSC::EncodedJSValue resolvedPromise(JSC::JSGlobalObject* global_object, JSC::JSValue value)
{
    return JSC::JSValue::encode(JSC::JSPromise::resolvedPromise(global_object, value));
}

JSC::EncodedJSValue rejectedTypeError(JSC::JSGlobalObject* global_object, WTF::ASCIILiteral message)
{
    return rejectedPromise(global_object, JSC::createTypeError(global_object, message));
}

JSC::EncodedJSValue rejectedTypeError(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, WTF::ASCIILiteral message)
{
    return rejectedPromise(global_object, scope, JSC::createTypeError(global_object, message));
}

WTF::String valueToWebApiString(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue value)
{
    if (value.isUndefined())
        return "undefined"_s;
    auto string = value.toWTFString(global_object);
    RETURN_IF_EXCEPTION(scope, {});
    return string;
}

WTF::String argumentToWebApiString(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::CallFrame* call_frame, unsigned index)
{
    return valueToWebApiString(global_object, scope, call_frame->argument(index));
}

static bool isLeadSurrogate(char16_t character) { return character >= 0xd800 && character <= 0xdbff; }

static bool isTrailSurrogate(char16_t character) { return character >= 0xdc00 && character <= 0xdfff; }

WTF::String toWebApiUSVString(WTF::String input)
{
    if (input.isEmpty())
        return input;

    // An 8-bit string holds no surrogate, and most 16-bit strings hold no unpaired one, so the string is scanned first
    // and rebuilt only when a replacement is needed.
    if (input.is8Bit())
        return input;

    bool needs_replacement = false;
    for (unsigned index = 0; index < input.length(); index++) {
        char16_t character = input[index];
        if (isLeadSurrogate(character)) {
            if (index + 1 < input.length() && isTrailSurrogate(input[index + 1])) {
                index++;
                continue;
            }
            needs_replacement = true;
            break;
        }
        if (isTrailSurrogate(character)) {
            needs_replacement = true;
            break;
        }
    }
    if (!needs_replacement)
        return input;

    WTF::StringBuilder builder;
    builder.reserveCapacity(input.length());
    for (unsigned index = 0; index < input.length(); index++) {
        char16_t character = input[index];
        if (isLeadSurrogate(character)) {
            if (index + 1 < input.length() && isTrailSurrogate(input[index + 1])) {
                builder.append(character);
                builder.append(input[++index]);
            } else {
                builder.append(static_cast<char16_t>(0xfffd));
            }
            continue;
        }
        if (isTrailSurrogate(character)) {
            builder.append(static_cast<char16_t>(0xfffd));
            continue;
        }
        builder.append(character);
    }
    return builder.toString();
}

JSC::GetterSetter* createWebApiAccessor(JSC::JSGlobalObject* global_object, JSC::VM& vm, WTF::ASCIILiteral name,
    JSC::NativeFunction getter, JSC::NativeFunction setter)
{
    auto* getter_function = JSC::JSFunction::create(
        vm, global_object, 0, WTF::makeString("get "_s, name), getter, JSC::ImplementationVisibility::Public);
    RELEASE_ASSERT(getter_function);
    JSC::JSFunction* setter_function = nullptr;
    if (setter) {
        setter_function = JSC::JSFunction::create(
            vm, global_object, 1, WTF::makeString("set "_s, name), setter, JSC::ImplementationVisibility::Public);
        RELEASE_ASSERT(setter_function);
    }
    auto* getter_setter = JSC::GetterSetter::create(vm, global_object, getter_function, setter_function);
    RELEASE_ASSERT(getter_setter);
    return getter_setter;
}

void putWebApiAccessor(JSC::JSGlobalObject* global_object, JSC::JSObject* prototype, JSC::VM& vm,
    WTF::ASCIILiteral name, JSC::NativeFunction getter, JSC::NativeFunction setter, unsigned attributes)
{
    JSC::Identifier identifier = JSC::Identifier::fromString(vm, name);
    prototype->putDirectAccessor(
        global_object, identifier, createWebApiAccessor(global_object, vm, name, getter, setter), attributes);
    RELEASE_ASSERT(prototype->getDirect(vm, identifier));
}

void putWebApiFunction(JSC::JSGlobalObject* global_object, JSC::JSObject* object, JSC::VM& vm, WTF::ASCIILiteral name,
    unsigned length, JSC::NativeFunction function, unsigned attributes)
{
    JSC::Identifier identifier = JSC::Identifier::fromString(vm, name);
    object->putDirectNativeFunction(vm, global_object, identifier, length, function,
        JSC::ImplementationVisibility::Public, JSC::NoIntrinsic, attributes);
    RELEASE_ASSERT(object->getDirect(vm, identifier));
}

ColloStatus consumeExceptionStatus(ColloVm* vm, JSC::ThrowScope& scope, ColloValue** out_exception)
{
    if (!scope.exception())
        return COLLO_STATUS_OK;
    auto exception = scope.exception()->value();
    const bool cleared = scope.tryClearException();
    ASSERT_UNUSED(cleared, cleared || scope.vm().hasPendingTerminationException());
    return Collo::statusOr(Collo::setJsException(vm, exception, out_exception), COLLO_STATUS_JS_EXCEPTION);
}

} // namespace Collo::HostFunctions

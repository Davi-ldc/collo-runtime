// Declares the helpers every host function family shares, which support.cpp defines. They run on the VM thread.

#pragma once

#include "jsc/runtime/state.h"

namespace Collo::HostFunctions {

// Throws an Error carrying `message` into `scope` and returns the thrown value, for a host function to return.
JSC::EncodedJSValue throwRuntimeError(JSC::JSGlobalObject*, JSC::ThrowScope&, WTF::ASCIILiteral message);
// Settled promises for a host function to return. An overload that takes a ThrowScope checks it after creating the
// promise and returns an empty value with the exception left pending.
JSC::EncodedJSValue rejectedPromise(JSC::JSGlobalObject*, JSC::JSValue reason);
JSC::EncodedJSValue rejectedPromise(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue reason);
JSC::EncodedJSValue resolvedPromise(JSC::JSGlobalObject*, JSC::JSValue value);
JSC::EncodedJSValue rejectedTypeError(JSC::JSGlobalObject*, WTF::ASCIILiteral message);
JSC::EncodedJSValue rejectedTypeError(JSC::JSGlobalObject*, JSC::ThrowScope&, WTF::ASCIILiteral message);

// WebIDL's DOMString conversion, which may run user code. On an exception it returns a null string with the exception
// pending in the scope. A missing argument converts as undefined, to "undefined".
WTF::String valueToWebApiString(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue);
WTF::String argumentToWebApiString(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::CallFrame*, unsigned index);
// WebIDL's USVString conversion of a string: every unpaired surrogate becomes U+FFFD.
WTF::String toWebApiUSVString(WTF::String);

// An accessor property whose getter is named "get <name>" and whose setter, when there is one, "set <name>", as
// WebIDL names them. Without a setter the property is read-only.
JSC::GetterSetter* createWebApiAccessor(JSC::JSGlobalObject*, JSC::VM&, WTF::ASCIILiteral name,
    JSC::NativeFunction getter, JSC::NativeFunction setter = nullptr);
void putWebApiAccessor(JSC::JSGlobalObject*, JSC::JSObject* prototype, JSC::VM&, WTF::ASCIILiteral name,
    JSC::NativeFunction getter, JSC::NativeFunction setter = nullptr,
    unsigned attributes = static_cast<unsigned>(JSC::PropertyAttribute::Accessor | JSC::PropertyAttribute::DontEnum));
void putWebApiFunction(JSC::JSGlobalObject*, JSC::JSObject* object, JSC::VM&, WTF::ASCIILiteral name, unsigned length,
    JSC::NativeFunction, unsigned attributes = static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));

// Moves the exception pending in `scope`, if any, into `*out_exception` for a C ABI caller. Returns COLLO_STATUS_OK
// when nothing is pending, otherwise COLLO_STATUS_JS_EXCEPTION or the status of the handle that could not be made. A
// termination stays pending so the VM keeps unwinding.
ColloStatus consumeExceptionStatus(ColloVm*, JSC::ThrowScope&, ColloValue** out_exception);

} // namespace Collo::HostFunctions

// DOMException for the rest of the bridge: the names a host function throws by code, the functions that create
// DOMException values, and native access to a DOMException's fields for the exception formatter. VM thread only.
// Every JSGlobalObject parameter must be a Collo::GlobalObject, which these functions downcast without checking.

#pragma once

#include "host_functions/support.h"

namespace Collo::HostFunctions {

// The Web IDL error names createDOMException takes by code. dom_exception.cpp indexes its description table by this
// value, so the two keep the same order.
enum class DOMExceptionCode : uint8_t {
    IndexSizeError,
    HierarchyRequestError,
    WrongDocumentError,
    InvalidCharacterError,
    NoModificationAllowedError,
    NotFoundError,
    NotSupportedError,
    InUseAttributeError,
    InvalidStateError,
    SyntaxError,
    InvalidModificationError,
    NamespaceError,
    InvalidAccessError,
    TypeMismatchError,
    SecurityError,
    NetworkError,
    AbortError,
    URLMismatchError,
    QuotaExceededError,
    TimeoutError,
    InvalidNodeTypeError,
    DataCloneError,
    EncodingError,
    NotReadableError,
    UnknownError,
    ConstraintError,
    DataError,
    TransactionInactiveError,
    ReadOnlyError,
    VersionError,
    OperationError,
    NotAllowedError,
};

// A DOMException with the name and legacy code of `code`; an empty `message` takes that name's default message. Never
// returns null: a failed cell allocation crashes the process.
JSC::JSObject* createDOMException(JSC::JSGlobalObject*, DOMExceptionCode, WTF::String message = {});
// A DOMException with any `name`. Its legacy code is the one Web IDL assigns that name, or 0.
JSC::JSObject* createDOMException(JSC::JSGlobalObject*, WTF::String message, WTF::String name);
// Reads a DOMException's name and message from its C++ fields without running script. formatExceptionString in
// jsc/runtime/values.cpp reads exception properties without calling getters, and a DOMException exposes both only
// through prototype accessors. Returns false, leaving the out-parameters untouched, for any other value.
bool domExceptionNameAndMessage(JSC::JSValue, WTF::String& out_name, WTF::String& out_message);
// Installs the DOMException constructor. The host function registry (globals.def) calls it at most once per VM.
void installWebApiDOMException(Collo::GlobalObject*, JSC::VM&);

} // namespace Collo::HostFunctions

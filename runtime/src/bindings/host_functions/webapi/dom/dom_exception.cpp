// DOMException as a cell whose name, message and legacy code are C++ fields that script reads through prototype
// accessors, with the legacy code constants on both the constructor and the prototype. VM thread only.

#include "host_functions/webapi/dom/dom_exception.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/IdentifierInlines.h>
#include <JavaScriptCore/InternalFunction.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSDestructibleObject.h>
#include <JavaScriptCore/JSFunction.h>
#include <JavaScriptCore/JSObject.h>
#include <JavaScriptCore/JSString.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/WTFString.h>

#include <array>

namespace Collo::HostFunctions {
namespace {

    using JSC::EncodedJSValue;
    using JSC::JSValue;
    using WTF::String;
    using namespace JSC;

    struct DOMExceptionDescription {
        WTF::ASCIILiteral name;
        WTF::ASCIILiteral message;
        uint16_t legacy_code;
    };

    // Indexed by DOMExceptionCode, so entries keep the enum's order; the static_assert below checks only the count.
    // Each legacy code is the one Web IDL's DOMException names table assigns, or 0 for a name that has none.
    static constexpr std::array dom_exception_descriptions {
        DOMExceptionDescription { "IndexSizeError"_s, "The index is not in the allowed range."_s, 1 },
        DOMExceptionDescription { "HierarchyRequestError"_s, "The operation would yield an incorrect node tree."_s, 3 },
        DOMExceptionDescription { "WrongDocumentError"_s, "The object is in the wrong document."_s, 4 },
        DOMExceptionDescription { "InvalidCharacterError"_s, "The string contains invalid characters."_s, 5 },
        DOMExceptionDescription { "NoModificationAllowedError"_s, "The object can not be modified."_s, 7 },
        DOMExceptionDescription { "NotFoundError"_s, "The object can not be found here."_s, 8 },
        DOMExceptionDescription { "NotSupportedError"_s, "The operation is not supported."_s, 9 },
        DOMExceptionDescription { "InUseAttributeError"_s, "The attribute is in use."_s, 10 },
        DOMExceptionDescription { "InvalidStateError"_s, "The object is in an invalid state."_s, 11 },
        DOMExceptionDescription { "SyntaxError"_s, "The string did not match the expected pattern."_s, 12 },
        DOMExceptionDescription { "InvalidModificationError"_s, "The object can not be modified in this way."_s, 13 },
        DOMExceptionDescription { "NamespaceError"_s, "The operation is not allowed by Namespaces in XML."_s, 14 },
        DOMExceptionDescription {
            "InvalidAccessError"_s, "The object does not support the operation or argument."_s, 15 },
        DOMExceptionDescription { "TypeMismatchError"_s,
            "The type of an object was incompatible with the expected type of the parameter associated to the object."_s,
            17 },
        DOMExceptionDescription { "SecurityError"_s, "The operation is insecure."_s, 18 },
        DOMExceptionDescription { "NetworkError"_s, "A network error occurred."_s, 19 },
        DOMExceptionDescription { "AbortError"_s, "The operation was aborted."_s, 20 },
        DOMExceptionDescription { "URLMismatchError"_s, "The given URL does not match another URL."_s, 21 },
        DOMExceptionDescription { "QuotaExceededError"_s, "The quota has been exceeded."_s, 22 },
        DOMExceptionDescription { "TimeoutError"_s, "The operation timed out."_s, 23 },
        DOMExceptionDescription { "InvalidNodeTypeError"_s,
            "The supplied node is incorrect or has an incorrect ancestor for this operation."_s, 24 },
        DOMExceptionDescription { "DataCloneError"_s, "The object can not be cloned."_s, 25 },
        DOMExceptionDescription {
            "EncodingError"_s, "The encoding operation (either encoded or decoding) failed."_s, 0 },
        DOMExceptionDescription { "NotReadableError"_s, "The I/O read operation failed."_s, 0 },
        DOMExceptionDescription {
            "UnknownError"_s, "The operation failed for an unknown transient reason (e.g. out of memory)."_s, 0 },
        DOMExceptionDescription { "ConstraintError"_s,
            "A mutation operation in a transaction failed because a constraint was not satisfied."_s, 0 },
        DOMExceptionDescription { "DataError"_s, "Provided data is inadequate."_s, 0 },
        DOMExceptionDescription { "TransactionInactiveError"_s,
            "A request was placed against a transaction which is currently not active, or which is finished."_s, 0 },
        DOMExceptionDescription {
            "ReadOnlyError"_s, "The mutating operation was attempted in a \"readonly\" transaction."_s, 0 },
        DOMExceptionDescription { "VersionError"_s,
            "An attempt was made to open a database using a lower version than the existing version."_s, 0 },
        DOMExceptionDescription { "OperationError"_s, "The operation failed for an operation-specific reason."_s, 0 },
        DOMExceptionDescription { "NotAllowedError"_s,
            "The request is not allowed by the user agent or the platform in the current context, possibly because the user denied permission."_s,
            0 },
    };
    static_assert(static_cast<size_t>(DOMExceptionCode::NotAllowedError) == dom_exception_descriptions.size() - 1);

    struct LegacyConstant {
        WTF::ASCIILiteral name;
        uint16_t value;
    };

    // The legacy code constants Web IDL defines on DOMException, including three that no error name maps to.
    static constexpr std::array legacy_constants {
        LegacyConstant { "INDEX_SIZE_ERR"_s, 1 },
        LegacyConstant { "DOMSTRING_SIZE_ERR"_s, 2 },
        LegacyConstant { "HIERARCHY_REQUEST_ERR"_s, 3 },
        LegacyConstant { "WRONG_DOCUMENT_ERR"_s, 4 },
        LegacyConstant { "INVALID_CHARACTER_ERR"_s, 5 },
        LegacyConstant { "NO_DATA_ALLOWED_ERR"_s, 6 },
        LegacyConstant { "NO_MODIFICATION_ALLOWED_ERR"_s, 7 },
        LegacyConstant { "NOT_FOUND_ERR"_s, 8 },
        LegacyConstant { "NOT_SUPPORTED_ERR"_s, 9 },
        LegacyConstant { "INUSE_ATTRIBUTE_ERR"_s, 10 },
        LegacyConstant { "INVALID_STATE_ERR"_s, 11 },
        LegacyConstant { "SYNTAX_ERR"_s, 12 },
        LegacyConstant { "INVALID_MODIFICATION_ERR"_s, 13 },
        LegacyConstant { "NAMESPACE_ERR"_s, 14 },
        LegacyConstant { "INVALID_ACCESS_ERR"_s, 15 },
        LegacyConstant { "VALIDATION_ERR"_s, 16 },
        LegacyConstant { "TYPE_MISMATCH_ERR"_s, 17 },
        LegacyConstant { "SECURITY_ERR"_s, 18 },
        LegacyConstant { "NETWORK_ERR"_s, 19 },
        LegacyConstant { "ABORT_ERR"_s, 20 },
        LegacyConstant { "URL_MISMATCH_ERR"_s, 21 },
        LegacyConstant { "QUOTA_EXCEEDED_ERR"_s, 22 },
        LegacyConstant { "TIMEOUT_ERR"_s, 23 },
        LegacyConstant { "INVALID_NODE_TYPE_ERR"_s, 24 },
        LegacyConstant { "DATA_CLONE_ERR"_s, 25 },
    };

    static const DOMExceptionDescription& descriptionForCode(DOMExceptionCode code)
    {
        return dom_exception_descriptions[static_cast<size_t>(code)];
    }

    static uint16_t legacyCodeForName(const String& name)
    {
        for (const auto& description : dom_exception_descriptions) {
            if (name == description.name)
                return description.legacy_code;
        }
        return 0;
    }

    class JSColloDOMException final : public JSC::JSDestructibleObject {
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

        static JSColloDOMException* create(
            JSC::VM& vm, JSC::Structure* structure, String&& message, String&& name, uint16_t code)
        {
            auto* object = new (NotNull, JSC::allocateCell<JSColloDOMException>(vm))
                JSColloDOMException(vm, structure, WTF::move(message), WTF::move(name), code);
            object->finishCreation(vm);
            return object;
        }

        static void destroy(JSC::JSCell* cell) { static_cast<JSColloDOMException*>(cell)->~JSColloDOMException(); }

        DECLARE_INFO;

        const String& message() const { return m_message; }
        const String& name() const { return m_name; }
        uint16_t code() const { return m_code; }

    private:
        JSColloDOMException(JSC::VM& vm, JSC::Structure* structure, String&& message, String&& name, uint16_t code)
            : Base(vm, structure)
            , m_message(WTF::move(message))
            , m_name(WTF::move(name))
            , m_code(code)
        {
        }

        ~JSColloDOMException() = default;

        void finishCreation(JSC::VM& vm)
        {
            Base::finishCreation(vm);
            ASSERT(inherits(info()));
        }

        String m_message;
        String m_name;
        uint16_t m_code { 0 };
    };

    const JSC::ClassInfo JSColloDOMException::s_info
        = { "DOMException"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloDOMException) };

    static JSColloDOMException* jsDOMException(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
    {
        auto* exception = dynamicDowncast<JSColloDOMException>(value);
        if (!exception) {
            JSC::throwVMTypeError(global_object, scope, "DOMException method called on incompatible receiver"_s);
            return nullptr;
        }
        return exception;
    }

    static JSC::Structure* structureForNewTarget(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::CallFrame* call_frame)
    {
        auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
        auto* new_target = call_frame->newTarget().getObject();
        auto* constructor = call_frame->jsCallee();
        if (!new_target || new_target == constructor)
            return collo_global->domExceptionStructure();

        auto* structure = JSC::InternalFunction::createSubclassStructure(
            global_object, new_target, collo_global->domExceptionStructure());
        RETURN_IF_EXCEPTION(scope, nullptr);
        return structure;
    }

    static JSValue getPropertyIfPresent(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        JSC::JSObject* object, const JSC::Identifier& identifier)
    {
        auto value = object->getIfPropertyExists(global_object, identifier);
        RETURN_IF_EXCEPTION(scope, {});
        return value;
    }

    static void putLegacyConstants(JSC::VM& vm, JSC::JSObject* object)
    {
        constexpr unsigned attributes
            = static_cast<unsigned>(JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontDelete);
        for (const auto& constant : legacy_constants)
            object->putDirect(
                vm, JSC::Identifier::fromString(vm, constant.name), JSC::jsNumber(constant.value), attributes);
    }

    JSC_DEFINE_HOST_FUNCTION(domExceptionConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        return JSC::throwVMTypeError(global_object, scope, "DOMException constructor requires 'new'"_s);
    }

    JSC_DEFINE_HOST_FUNCTION(
        domExceptionConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);

        String message;
        if (!call_frame->argument(0).isUndefined()) {
            message = valueToWebApiString(global_object, scope, call_frame->argument(0));
            RETURN_IF_EXCEPTION(scope, {});
        }

        // Web IDL's second parameter is the name; an object is accepted too and read for `name` and `cause`.
        String name = "Error"_s;
        JSValue cause;
        JSValue name_value = call_frame->argument(1);
        if (auto* options = dynamicDowncast<JSC::JSObject>(name_value)) {
            auto candidate = getPropertyIfPresent(global_object, scope, options, vm.propertyNames->name);
            RETURN_IF_EXCEPTION(scope, {});
            if (candidate)
                name = valueToWebApiString(global_object, scope, candidate);
            RETURN_IF_EXCEPTION(scope, {});

            cause = getPropertyIfPresent(global_object, scope, options, vm.propertyNames->cause);
            RETURN_IF_EXCEPTION(scope, {});
        } else if (!name_value.isUndefined()) {
            name = valueToWebApiString(global_object, scope, name_value);
            RETURN_IF_EXCEPTION(scope, {});
        }

        auto* structure = structureForNewTarget(global_object, scope, call_frame);
        RETURN_IF_EXCEPTION(scope, {});
        if (!structure)
            return {};

        const auto code = legacyCodeForName(name);
        auto* object = JSColloDOMException::create(vm, structure, WTF::move(message), WTF::move(name), code);
        if (cause)
            object->putDirect(
                vm, vm.propertyNames->cause, cause, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
        return JSValue::encode(object);
    }

    JSC_DEFINE_HOST_FUNCTION(domExceptionGetCode, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* exception = jsDOMException(global_object, scope, call_frame->thisValue());
        if (!exception)
            return {};
        return JSValue::encode(JSC::jsNumber(exception->code()));
    }

    JSC_DEFINE_HOST_FUNCTION(domExceptionGetName, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* exception = jsDOMException(global_object, scope, call_frame->thisValue());
        if (!exception)
            return {};
        return JSValue::encode(JSC::jsString(vm, exception->name()));
    }

    JSC_DEFINE_HOST_FUNCTION(domExceptionGetMessage, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* exception = jsDOMException(global_object, scope, call_frame->thisValue());
        if (!exception)
            return {};
        return JSValue::encode(JSC::jsString(vm, exception->message()));
    }

} // namespace

bool domExceptionNameAndMessage(JSC::JSValue value, WTF::String& out_name, WTF::String& out_message)
{
    auto* exception = dynamicDowncast<JSColloDOMException>(value);
    if (!exception)
        return false;
    out_name = exception->name();
    out_message = exception->message();
    return true;
}

JSC::JSObject* createDOMException(JSC::JSGlobalObject* global_object, DOMExceptionCode code, WTF::String message)
{
    auto& vm = global_object->vm();
    const auto& description = descriptionForCode(code);
    auto name = String(description.name);
    if (message.isEmpty())
        message = String(description.message);
    return JSColloDOMException::create(vm,
        uncheckedDowncast<Collo::GlobalObject>(global_object)->domExceptionStructure(), WTF::move(message),
        WTF::move(name), description.legacy_code);
}

JSC::JSObject* createDOMException(JSC::JSGlobalObject* global_object, WTF::String message, WTF::String name)
{
    auto& vm = global_object->vm();
    const auto code = legacyCodeForName(name);
    return JSColloDOMException::create(vm,
        uncheckedDowncast<Collo::GlobalObject>(global_object)->domExceptionStructure(), WTF::move(message),
        WTF::move(name), code);
}

void installWebApiDOMException(Collo::GlobalObject* global_object, JSC::VM& vm)
{
    constexpr unsigned enumerableAccessor = static_cast<unsigned>(JSC::PropertyAttribute::Accessor);

    auto* prototype = JSC::constructEmptyObject(global_object, global_object->errorPrototype());
    putWebApiAccessor(global_object, prototype, vm, "code"_s, domExceptionGetCode, nullptr, enumerableAccessor);
    putWebApiAccessor(global_object, prototype, vm, "name"_s, domExceptionGetName, nullptr, enumerableAccessor);
    putWebApiAccessor(global_object, prototype, vm, "message"_s, domExceptionGetMessage, nullptr, enumerableAccessor);
    putLegacyConstants(vm, prototype);
    prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol, JSC::jsString(vm, WTF::makeString("DOMException"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    auto* constructor = JSC::JSFunction::create(vm, global_object, 0, "DOMException"_s, domExceptionConstructorCall,
        JSC::ImplementationVisibility::Public, JSC::NoIntrinsic, domExceptionConstructorConstruct, nullptr);
    RELEASE_ASSERT(constructor);
    constructor->putDirect(vm, vm.propertyNames->prototype, prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    putLegacyConstants(vm, constructor);
    prototype->putDirect(
        vm, vm.propertyNames->constructor, constructor, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));

    JSC::Identifier identifier = JSC::Identifier::fromString(vm, "DOMException"_s);
    global_object->putDirect(vm, identifier, constructor, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    RELEASE_ASSERT(global_object->getDirect(vm, identifier));

    global_object->cacheDOMExceptionApi(
        constructor, prototype, JSColloDOMException::createStructure(vm, global_object, prototype));
}

} // namespace Collo::HostFunctions

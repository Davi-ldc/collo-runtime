// The Immediate prototype and methods, and `collo_webapi_immediate_mark_destroyed`, on the VM thread. The prototype
// and structure are built on a realm's first setImmediate call, not at install, and cached in that realm's
// `webapi_cache`. The Immediate constructor is reachable only as the prototype's `constructor`, and calling it throws.

#include "jsc/runtime/state.h"

#include "host_functions/runtime/timers.h"
#include "host_functions/support.h"
#include "host_functions/webapi/platform/timer_handle.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSFunction.h>
#include <JavaScriptCore/JSObject.h>
#include <JavaScriptCore/PropertyName.h>
#include <wtf/text/MakeString.h>

namespace Collo::HostFunctions {

using namespace JSC;

namespace {

    constexpr unsigned hiddenAttributes = static_cast<unsigned>(JSC::PropertyAttribute::DontEnum);
    constexpr unsigned hiddenAccessorAttributes
        = static_cast<unsigned>(JSC::PropertyAttribute::Accessor | JSC::PropertyAttribute::DontEnum);

    JSC::EncodedJSValue throwIllegalInvocation(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
    {
        return JSC::throwVMTypeError(global_object, scope, "Illegal invocation."_s);
    }

    JSColloImmediate* immediateThis(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::CallFrame* call_frame)
    {
        auto* handle = dynamicDowncast<JSColloImmediate>(call_frame->thisValue());
        if (!handle)
            throwIllegalInvocation(global_object, scope);
        return handle;
    }

    JSC_DEFINE_HOST_FUNCTION(immediateConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
    {
        JSC::VM& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        return JSC::throwVMTypeError(global_object, scope, "Immediate is not constructible."_s);
    }

    JSC_DEFINE_HOST_FUNCTION(immediateGetDestroyed, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        JSC::VM& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* handle = immediateThis(global_object, scope, call_frame);
        RETURN_IF_EXCEPTION(scope, {});
        return JSC::JSValue::encode(JSC::jsBoolean(handle->destroyed()));
    }

    JSC_DEFINE_HOST_FUNCTION(immediateRef, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        JSC::VM& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* handle = immediateThis(global_object, scope, call_frame);
        RETURN_IF_EXCEPTION(scope, {});
        handle->ref();
        return JSC::JSValue::encode(handle);
    }

    JSC_DEFINE_HOST_FUNCTION(immediateUnref, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        JSC::VM& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* handle = immediateThis(global_object, scope, call_frame);
        RETURN_IF_EXCEPTION(scope, {});
        handle->unref();
        return JSC::JSValue::encode(handle);
    }

    JSC_DEFINE_HOST_FUNCTION(immediateHasRef, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        JSC::VM& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* handle = immediateThis(global_object, scope, call_frame);
        RETURN_IF_EXCEPTION(scope, {});
        return JSC::JSValue::encode(JSC::jsBoolean(handle->hasRef()));
    }

    JSC_DEFINE_HOST_FUNCTION(immediateToPrimitive, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        JSC::VM& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* handle = immediateThis(global_object, scope, call_frame);
        RETURN_IF_EXCEPTION(scope, {});
        return JSC::JSValue::encode(JSC::jsNumber(static_cast<double>(handle->id())));
    }

    JSC_DEFINE_HOST_FUNCTION(immediateDispose, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        JSC::VM& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* handle = immediateThis(global_object, scope, call_frame);
        RETURN_IF_EXCEPTION(scope, {});

        handle->markDestroyed();
        if (handle->id() == 0)
            return JSC::JSValue::encode(JSC::jsUndefined());
        return Runtime::clearImmediate(global_object, handle->id());
    }

    JSC::JSObject* createImmediatePrototype(Collo::GlobalObject* global_object, JSC::VM& vm)
    {
        auto* prototype = JSC::constructEmptyObject(global_object, global_object->objectPrototype());

        putWebApiAccessor(
            global_object, prototype, vm, "_destroyed"_s, immediateGetDestroyed, nullptr, hiddenAccessorAttributes);
        putWebApiFunction(global_object, prototype, vm, "ref"_s, 0, immediateRef, hiddenAttributes);
        putWebApiFunction(global_object, prototype, vm, "unref"_s, 0, immediateUnref, hiddenAttributes);
        putWebApiFunction(global_object, prototype, vm, "hasRef"_s, 0, immediateHasRef, hiddenAttributes);

        auto* to_primitive = JSC::JSFunction::create(vm, global_object, 1, "[Symbol.toPrimitive]"_s,
            immediateToPrimitive, JSC::ImplementationVisibility::Public);
        RELEASE_ASSERT(to_primitive);
        prototype->putDirect(vm, vm.propertyNames->toPrimitiveSymbol, to_primitive, hiddenAttributes);

        auto* dispose = JSC::JSFunction::create(
            vm, global_object, 0, "[Symbol.dispose]"_s, immediateDispose, JSC::ImplementationVisibility::Public);
        RELEASE_ASSERT(dispose);
        prototype->putDirect(vm, vm.propertyNames->disposeSymbol, dispose, hiddenAttributes);

        auto* constructor = JSC::JSFunction::create(
            vm, global_object, 0, "Immediate"_s, immediateConstructorCall, JSC::ImplementationVisibility::Public);
        RELEASE_ASSERT(constructor);
        constructor->putDirect(vm, vm.propertyNames->prototype, prototype,
            JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
        prototype->putDirect(vm, vm.propertyNames->constructor, constructor, hiddenAttributes);

        return prototype;
    }

    JSC::Structure* immediateStructure(Collo::GlobalObject* global_object, JSC::VM& vm)
    {
        auto& cache = global_object->webApiCache();
        if (auto* structure = cache.immediate_handle_structure.get())
            return structure;

        auto* prototype = createImmediatePrototype(global_object, vm);
        cache.immediate_handle_prototype.set(vm, prototype);
        auto* structure = JSColloImmediate::createStructure(vm, global_object, prototype);
        cache.immediate_handle_structure.set(vm, structure);
        return structure;
    }

} // namespace

JSC::Structure* JSColloImmediate::createStructure(
    JSC::VM& vm, JSC::JSGlobalObject* global_object, JSC::JSValue prototype)
{
    return JSC::Structure::create(vm, global_object, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
}

JSColloImmediate* JSColloImmediate::create(JSC::VM& vm, JSC::Structure* structure)
{
    auto* object = new (NotNull, JSC::allocateCell<JSColloImmediate>(vm)) JSColloImmediate(vm, structure);
    object->finishCreation(vm);
    return object;
}

void JSColloImmediate::destroy(JSC::JSCell* cell) { static_cast<JSColloImmediate*>(cell)->~JSColloImmediate(); }

JSColloImmediate::JSColloImmediate(JSC::VM& vm, JSC::Structure* structure)
    : Base(vm, structure)
{
}

void JSColloImmediate::finishCreation(JSC::VM& vm)
{
    Base::finishCreation(vm);
    ASSERT(inherits(info()));
}

const JSC::ClassInfo JSColloImmediate::s_info
    = { "Immediate"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloImmediate) };

JSColloImmediate* createImmediateHandle(JSC::JSGlobalObject* global_object)
{
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    JSC::VM& vm = global_object->vm();
    return JSColloImmediate::create(vm, immediateStructure(collo_global, vm));
}

JSColloImmediate* immediateHandleFromValue(JSC::JSValue value) { return dynamicDowncast<JSColloImmediate>(value); }

std::optional<uint64_t> immediateIdFromValue(JSC::JSValue value)
{
    auto* handle = immediateHandleFromValue(value);
    if (!handle || handle->id() == 0)
        return std::nullopt;
    return handle->id();
}

} // namespace Collo::HostFunctions

extern "C" ColloStatus collo_webapi_immediate_mark_destroyed(ColloVm* vm, const ColloValue* value)
{
    if (!vm || !vm->isReady() || !Collo::valueBelongsToVm(vm, value))
        return COLLO_STATUS_INVALID_ARGUMENT;

    JSC::JSLockHolder locker(*vm->vm);
    auto* handle = Collo::HostFunctions::immediateHandleFromValue(Collo::toJSValue(value));
    if (!handle)
        return COLLO_STATUS_INVALID_ARGUMENT;

    handle->markDestroyed();
    return COLLO_STATUS_OK;
}

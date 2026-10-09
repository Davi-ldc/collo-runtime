// Host functions of ByteLengthQueuingStrategy and CountQueuingStrategy. The highWaterMark and size getters check that
// the receiver is a strategy of their own kind, so a CountQueuingStrategy never passes as a ByteLengthQueuingStrategy.
// The size functions take no receiver, as the Streams Standard defines them. Runs on the VM thread.

#include "host_functions/webapi/streams/queuing_strategy_private.h"

namespace Collo::HostFunctions {
namespace {

    JSColloQueuingStrategy* requireQueuingStrategy(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value, QueuingStrategyKind kind)
    {
        auto* strategy = dynamicDowncast<JSColloQueuingStrategy>(value);
        if (strategy && strategy->kind() == kind)
            return strategy;
        auto message = kind == QueuingStrategyKind::ByteLength
            ? "ByteLengthQueuingStrategy method called on incompatible receiver"_s
            : "CountQueuingStrategy method called on incompatible receiver"_s;
        JSC::throwVMTypeError(global_object, scope, message);
        return nullptr;
    }

} // namespace

const JSC::ClassInfo JSColloQueuingStrategy::s_info
    = { "QueuingStrategy"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloQueuingStrategy) };

bool extractQueuingStrategyInitHighWaterMark(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue init, double& out_high_water_mark)
{
    out_high_water_mark = 0;
    if (!init.isObject()) {
        JSC::throwVMTypeError(global_object, scope, "QueuingStrategyInit argument must be an object"_s);
        return false;
    }

    auto& vm = global_object->vm();
    auto* object = init.getObject();
    JSValue value = object->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "highWaterMark"_s));
    RETURN_IF_EXCEPTION(scope, false);
    if (value.isEmpty() || value.isUndefined()) {
        JSC::throwVMTypeError(global_object, scope, "QueuingStrategyInit.highWaterMark member is required"_s);
        return false;
    }

    out_high_water_mark = value.toNumber(global_object);
    RETURN_IF_EXCEPTION(scope, false);
    return true;
}

JSC::Structure* queuingStrategyStructureForNewTarget(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::CallFrame* call_frame, JSC::Structure* base)
{
    auto* new_target = call_frame->newTarget().getObject();
    auto* constructor = call_frame->jsCallee();
    if (!new_target || new_target == constructor)
        return base;
    auto* structure = JSC::InternalFunction::createSubclassStructure(global_object, new_target, base);
    RETURN_IF_EXCEPTION(scope, nullptr);
    return structure;
}

JSC_DEFINE_HOST_FUNCTION(
    byteLengthQueuingStrategyConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    return JSC::throwVMTypeError(global_object, scope, "ByteLengthQueuingStrategy constructor requires 'new'"_s);
}

JSC_DEFINE_HOST_FUNCTION(
    byteLengthQueuingStrategyConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    double high_water_mark = 0;
    if (!extractQueuingStrategyInitHighWaterMark(global_object, scope, call_frame->argument(0), high_water_mark))
        return {};
    RETURN_IF_EXCEPTION(scope, {});

    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    auto* structure = queuingStrategyStructureForNewTarget(global_object, scope, call_frame,
        collo_global->owner().webapi_cache.byte_length_queuing_strategy_structure.get());
    RETURN_IF_EXCEPTION(scope, {});
    auto* strategy = JSColloQueuingStrategy::create(vm, structure, QueuingStrategyKind::ByteLength, high_water_mark);
    return JSValue::encode(strategy);
}

JSC_DEFINE_HOST_FUNCTION(countQueuingStrategyConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    return JSC::throwVMTypeError(global_object, scope, "CountQueuingStrategy constructor requires 'new'"_s);
}

JSC_DEFINE_HOST_FUNCTION(
    countQueuingStrategyConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    double high_water_mark = 0;
    if (!extractQueuingStrategyInitHighWaterMark(global_object, scope, call_frame->argument(0), high_water_mark))
        return {};
    RETURN_IF_EXCEPTION(scope, {});

    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    auto* structure = queuingStrategyStructureForNewTarget(
        global_object, scope, call_frame, collo_global->owner().webapi_cache.count_queuing_strategy_structure.get());
    RETURN_IF_EXCEPTION(scope, {});
    auto* strategy = JSColloQueuingStrategy::create(vm, structure, QueuingStrategyKind::Count, high_water_mark);
    return JSValue::encode(strategy);
}

JSC_DEFINE_HOST_FUNCTION(
    byteLengthQueuingStrategyHighWaterMark, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* strategy
        = requireQueuingStrategy(global_object, scope, call_frame->thisValue(), QueuingStrategyKind::ByteLength);
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(JSC::jsNumber(strategy->highWaterMark()));
}

JSC_DEFINE_HOST_FUNCTION(
    byteLengthQueuingStrategySize, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    if (!call_frame->argumentCount()) {
        JSC::throwVMTypeError(global_object, scope, "ByteLengthQueuingStrategy size requires a chunk"_s);
        return {};
    }
    JSValue chunk = call_frame->argument(0);
    if (chunk.isNull() || chunk.isUndefined()) {
        JSC::throwVMTypeError(global_object, scope, "ByteLengthQueuingStrategy chunk must have byteLength"_s);
        return {};
    }
    auto* object = chunk.toObject(global_object);
    RETURN_IF_EXCEPTION(scope, {});
    JSValue byte_length = object->get(global_object, byteLengthIdentifier(global_object));
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(byte_length);
}

JSC_DEFINE_HOST_FUNCTION(
    countQueuingStrategyHighWaterMark, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* strategy = requireQueuingStrategy(global_object, scope, call_frame->thisValue(), QueuingStrategyKind::Count);
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(JSC::jsNumber(strategy->highWaterMark()));
}

JSC_DEFINE_HOST_FUNCTION(countQueuingStrategySize, (JSC::JSGlobalObject*, JSC::CallFrame*))
{
    return JSValue::encode(JSC::jsNumber(1));
}

// Web IDL makes size a readonly attribute. After the brand check the getter returns the size function created once
// at installation, which the Streams Standard keeps per global object; ColloWebApiCache holds it per VM, and each VM
// has one global object.
JSC_DEFINE_HOST_FUNCTION(
    byteLengthQueuingStrategySizeGetter, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    requireQueuingStrategy(global_object, scope, call_frame->thisValue(), QueuingStrategyKind::ByteLength);
    RETURN_IF_EXCEPTION(scope, {});
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    return JSValue::encode(collo_global->owner().webapi_cache.byte_length_queuing_strategy_size_function.get());
}

JSC_DEFINE_HOST_FUNCTION(
    countQueuingStrategySizeGetter, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    requireQueuingStrategy(global_object, scope, call_frame->thisValue(), QueuingStrategyKind::Count);
    RETURN_IF_EXCEPTION(scope, {});
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    return JSValue::encode(collo_global->owner().webapi_cache.count_queuing_strategy_size_function.get());
}

} // namespace Collo::HostFunctions

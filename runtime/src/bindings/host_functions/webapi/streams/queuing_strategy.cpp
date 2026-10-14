// ByteLengthQueuingStrategy and CountQueuingStrategy: constructors, accessors, size functions and the installer. The
// highWaterMark and size getters check that the receiver is a strategy of their own kind, so a CountQueuingStrategy
// never passes as a ByteLengthQueuingStrategy. The size functions take no receiver, as the Streams Standard defines
// them. Runs on the VM thread.

#include "host_functions/webapi/streams/queuing_strategy_private.h"

namespace Collo::HostFunctions {
namespace {

    JSColloQueuingStrategy* requireQueuingStrategy(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue value, QueuingStrategyKind kind)
    {
        auto* strategy = dynamicDowncast<JSColloQueuingStrategy>(value);
        if (strategy && strategy->kind() == kind)
            return strategy;
        JSC::throwVMTypeError(global_object, scope,
            kind == QueuingStrategyKind::ByteLength
                ? "ByteLengthQueuingStrategy method called on incompatible receiver"_s
                : "CountQueuingStrategy method called on incompatible receiver"_s);
        return nullptr;
    }

    // Reads the required highWaterMark member of a QueuingStrategyInit dictionary and converts it to a number. Throws a
    // TypeError when the value is not an object or the member is absent or undefined.
    bool extractQueuingStrategyInitHighWaterMark(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue init, double& out_high_water_mark)
    {
        out_high_water_mark = 0;
        if (!init.isObject()) {
            JSC::throwVMTypeError(global_object, scope, "QueuingStrategyInit argument must be an object"_s);
            return false;
        }
        auto& vm = global_object->vm();
        JSC::JSValue value
            = init.getObject()->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "highWaterMark"_s));
        RETURN_IF_EXCEPTION(scope, false);
        if (value.isEmpty() || value.isUndefined()) {
            JSC::throwVMTypeError(global_object, scope, "QueuingStrategyInit.highWaterMark member is required"_s);
            return false;
        }
        out_high_water_mark = value.toNumber(global_object);
        RETURN_IF_EXCEPTION(scope, false);
        return true;
    }

    template <QueuingStrategyKind kind>
    JSC::EncodedJSValue JSC_HOST_CALL_ATTRIBUTES queuingStrategyConstruct(
        JSC::JSGlobalObject* global_object, JSC::CallFrame* call_frame)
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        double high_water_mark = 0;
        if (!extractQueuingStrategyInitHighWaterMark(global_object, scope, call_frame->argument(0), high_water_mark))
            return {};
        auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
        auto* base_structure = kind == QueuingStrategyKind::ByteLength
            ? collo_global->byteLengthQueuingStrategyStructure()
            : collo_global->countQueuingStrategyStructure();
        auto* structure = streamStructureForNewTarget(global_object, scope, call_frame, base_structure);
        RETURN_IF_EXCEPTION(scope, {});
        return JSC::JSValue::encode(JSColloQueuingStrategy::create(vm, structure, kind, high_water_mark));
    }

    template <QueuingStrategyKind kind>
    JSC::EncodedJSValue JSC_HOST_CALL_ATTRIBUTES queuingStrategyHighWaterMark(
        JSC::JSGlobalObject* global_object, JSC::CallFrame* call_frame)
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* strategy = requireQueuingStrategy(global_object, scope, call_frame->thisValue(), kind);
        RETURN_IF_EXCEPTION(scope, {});
        return JSC::JSValue::encode(JSC::jsNumber(strategy->highWaterMark()));
    }

    // Web IDL makes size a readonly attribute. After the brand check the getter returns the size function created once
    // at installation, which the Streams Standard keeps per global object.
    template <QueuingStrategyKind kind>
    JSC::EncodedJSValue JSC_HOST_CALL_ATTRIBUTES queuingStrategySizeGetter(
        JSC::JSGlobalObject* global_object, JSC::CallFrame* call_frame)
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        requireQueuingStrategy(global_object, scope, call_frame->thisValue(), kind);
        RETURN_IF_EXCEPTION(scope, {});
        auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
        return JSC::JSValue::encode(kind == QueuingStrategyKind::ByteLength
                ? collo_global->byteLengthQueuingStrategySizeFunction()
                : collo_global->countQueuingStrategySizeFunction());
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
        JSC::JSValue chunk = call_frame->argument(0);
        if (chunk.isUndefinedOrNull()) {
            JSC::throwVMTypeError(global_object, scope, "ByteLengthQueuingStrategy chunk must have byteLength"_s);
            return {};
        }
        auto* object = chunk.toObject(global_object);
        RETURN_IF_EXCEPTION(scope, {});
        RELEASE_AND_RETURN(scope, JSC::JSValue::encode(object->get(global_object, vm.propertyNames->byteLength)));
    }

    JSC_DEFINE_HOST_FUNCTION(countQueuingStrategySize, (JSC::JSGlobalObject*, JSC::CallFrame*))
    {
        return JSC::JSValue::encode(JSC::jsNumber(1));
    }

    template <QueuingStrategyKind kind>
    void installQueuingStrategy(Collo::GlobalObject* global_object, JSC::VM& vm, WTF::ASCIILiteral name,
        JSC::NativeFunction size, unsigned size_length, JSC::Strong<JSC::Structure>& structure_slot,
        JSC::Strong<JSC::JSObject>& size_slot)
    {
        constexpr unsigned accessor_attributes = static_cast<unsigned>(JSC::PropertyAttribute::Accessor);
        auto* prototype = JSC::constructEmptyObject(global_object);
        putWebApiAccessor(global_object, prototype, vm, "highWaterMark"_s, queuingStrategyHighWaterMark<kind>, nullptr,
            accessor_attributes);
        size_slot.set(vm,
            JSC::JSFunction::create(
                vm, global_object, size_length, "size"_s, size, JSC::ImplementationVisibility::Public));
        putWebApiAccessor(
            global_object, prototype, vm, "size"_s, queuingStrategySizeGetter<kind>, nullptr, accessor_attributes);
        installStreamInterface(global_object, vm, name, 1, prototype, queuingStrategyConstruct<kind>);
        structure_slot.set(vm, JSColloQueuingStrategy::createStructure(vm, global_object, prototype));
    }

} // namespace

const JSC::ClassInfo JSColloQueuingStrategy::s_info
    = { "QueuingStrategy"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloQueuingStrategy) };

void installQueuingStrategyClasses(Collo::GlobalObject* global_object, JSC::VM& vm)
{
    auto& cache = global_object->webApiCache();
    installQueuingStrategy<QueuingStrategyKind::ByteLength>(global_object, vm, "ByteLengthQueuingStrategy"_s,
        byteLengthQueuingStrategySize, 1, cache.byte_length_queuing_strategy_structure,
        cache.byte_length_queuing_strategy_size_function);
    installQueuingStrategy<QueuingStrategyKind::Count>(global_object, vm, "CountQueuingStrategy"_s,
        countQueuingStrategySize, 0, cache.count_queuing_strategy_structure,
        cache.count_queuing_strategy_size_function);
}

} // namespace Collo::HostFunctions

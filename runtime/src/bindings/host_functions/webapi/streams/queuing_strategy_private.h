// ByteLengthQueuingStrategy and CountQueuingStrategy. One cell class serves both, tagged by kind, and holds only the
// highWaterMark given at construction, so it references no other cell and needs no visitChildren. The structure and
// size function of each kind live in ColloWebApiCache, filled when streams_install.cpp installs the classes. Runs on
// the VM thread.

#pragma once

#include "host_functions/webapi/streams/stream_common_private.h"

namespace Collo::HostFunctions {

JSC_DECLARE_HOST_FUNCTION(byteLengthQueuingStrategyConstructorCall);
JSC_DECLARE_HOST_FUNCTION(byteLengthQueuingStrategyConstructorConstruct);
JSC_DECLARE_HOST_FUNCTION(countQueuingStrategyConstructorCall);
JSC_DECLARE_HOST_FUNCTION(countQueuingStrategyConstructorConstruct);
JSC_DECLARE_HOST_FUNCTION(byteLengthQueuingStrategyHighWaterMark);
JSC_DECLARE_HOST_FUNCTION(byteLengthQueuingStrategySize);
JSC_DECLARE_HOST_FUNCTION(byteLengthQueuingStrategySizeGetter);
JSC_DECLARE_HOST_FUNCTION(countQueuingStrategyHighWaterMark);
JSC_DECLARE_HOST_FUNCTION(countQueuingStrategySize);
JSC_DECLARE_HOST_FUNCTION(countQueuingStrategySizeGetter);

enum class QueuingStrategyKind : uint8_t {
    ByteLength,
    Count,
};

class JSColloQueuingStrategy final : public JSC::JSDestructibleObject {
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

    static JSColloQueuingStrategy* create(
        JSC::VM& vm, JSC::Structure* structure, QueuingStrategyKind kind, double high_water_mark)
    {
        auto* object
            = new (NotNull, JSC::allocateCell<JSColloQueuingStrategy>(vm)) JSColloQueuingStrategy(vm, structure);
        object->finishCreation(vm, kind, high_water_mark);
        return object;
    }

    static void destroy(JSCell* cell) { static_cast<JSColloQueuingStrategy*>(cell)->~JSColloQueuingStrategy(); }

    DECLARE_INFO;

    QueuingStrategyKind kind() const { return m_kind; }
    double highWaterMark() const { return m_high_water_mark; }

private:
    JSColloQueuingStrategy(JSC::VM& vm, JSC::Structure* structure)
        : Base(vm, structure)
    {
    }

    void finishCreation(JSC::VM& vm, QueuingStrategyKind kind, double high_water_mark)
    {
        Base::finishCreation(vm);
        ASSERT(inherits(info()));
        m_kind = kind;
        m_high_water_mark = high_water_mark;
    }

    QueuingStrategyKind m_kind { QueuingStrategyKind::Count };
    double m_high_water_mark { 0 };
};

// Reads the required highWaterMark member of a QueuingStrategyInit dictionary and converts it to a number. Throws a
// TypeError when the value is not an object or the member is absent or undefined, and returns false whenever an
// exception is pending.
bool extractQueuingStrategyInitHighWaterMark(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue, double&);
// Returns the base structure, or one derived from new.target when a subclass constructs. Returns null with an
// exception pending when deriving throws.
JSC::Structure* queuingStrategyStructureForNewTarget(
    JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::CallFrame*, JSC::Structure*);

} // namespace Collo::HostFunctions

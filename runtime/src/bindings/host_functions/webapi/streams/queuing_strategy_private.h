// ByteLengthQueuingStrategy and CountQueuingStrategy. One cell class serves both, tagged by kind, and holds only the
// highWaterMark given at construction, so it references no other cell, needs no visitChildren and destroys nothing.
// The structure and size function of each kind live in the realm's ColloWebApiCache, filled when
// installQueuingStrategyClasses runs. Runs on the VM thread.

#pragma once

#include "host_functions/webapi/streams/stream_common_private.h"

namespace Collo::HostFunctions {

enum class QueuingStrategyKind : uint8_t {
    ByteLength,
    Count,
};

class JSColloQueuingStrategy final : public JSC::JSNonFinalObject {
    using Base = JSC::JSNonFinalObject;

public:
    template <typename CellType, JSC::SubspaceAccess> static JSC::CompleteSubspace* subspaceFor(JSC::VM& vm)
    {
        static_assert(CellType::needsDestruction == JSC::DoesNotNeedDestruction);
        return &vm.cellSpace();
    }

    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* global_object, JSC::JSValue prototype)
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

} // namespace Collo::HostFunctions

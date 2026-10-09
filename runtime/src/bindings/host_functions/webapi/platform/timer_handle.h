// The Immediate cell that setImmediate returns, on the VM thread. It has Node's ref, unref, hasRef and `_destroyed`,
// a Symbol.dispose that cancels it, and a Symbol.toPrimitive that returns its id. The cell holds plain fields and no
// cell references, so it has no visitChildren; the Zig scheduler retains it as the callback's receiver while the
// immediate is pending and marks it destroyed (`collo_webapi_immediate_mark_destroyed`) just before the callback runs,
// or when the immediate is cleared or its request ends.

#pragma once

#include "collo/abi.h"
#include "host_functions/support.h"

#include <JavaScriptCore/JSDestructibleObject.h>
#include <JavaScriptCore/Structure.h>

#include <cstdint>
#include <optional>

namespace Collo::HostFunctions {

class JSColloImmediate final : public JSC::JSDestructibleObject {
    using Base = JSC::JSDestructibleObject;

public:
    template <typename CellType, JSC::SubspaceAccess> static JSC::CompleteSubspace* subspaceFor(JSC::VM& vm)
    {
        return &vm.destructibleObjectSpace();
    }

    static JSC::Structure* createStructure(JSC::VM&, JSC::JSGlobalObject*, JSC::JSValue prototype);
    static JSColloImmediate* create(JSC::VM&, JSC::Structure*);
    static void destroy(JSC::JSCell*);

    DECLARE_INFO;

    // 0 until the runtime has scheduled the immediate, then the id the runtime assigned.
    uint64_t id() const { return m_id; }
    void setId(uint64_t id) { m_id = id; }

    // Only hasRef() reads this flag; it does not affect scheduling.
    bool hasRef() const { return m_refed; }
    void ref() { m_refed = true; }
    void unref() { m_refed = false; }

    bool destroyed() const { return m_destroyed; }
    void markDestroyed() { m_destroyed = true; }

private:
    JSColloImmediate(JSC::VM&, JSC::Structure*);
    ~JSColloImmediate() = default;

    void finishCreation(JSC::VM&);

    uint64_t m_id { 0 };
    bool m_refed { true };
    bool m_destroyed { false };
};

// Allocates an unscheduled handle. The global object must be a `Collo::GlobalObject`; the first call builds the
// Immediate prototype and structure and caches them on the VM.
JSColloImmediate* createImmediateHandle(JSC::JSGlobalObject*);
// The handle `value` holds, or null.
JSColloImmediate* immediateHandleFromValue(JSC::JSValue);
// The id of a scheduled handle; nullopt for any other value, including a handle whose scheduling failed.
std::optional<uint64_t> immediateIdFromValue(JSC::JSValue);

}

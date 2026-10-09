#pragma once

#include "root.h"

namespace WebCore {

class ScriptExecutionContext {
public:
    explicit ScriptExecutionContext(JSC::JSGlobalObject* global_object)
        : m_global_object(global_object)
    {
    }

    JSC::VM& vm() const { return m_global_object->vm(); }
    JSC::JSGlobalObject* globalObject() const { return m_global_object; }

private:
    JSC::JSGlobalObject* m_global_object;
};

} // namespace WebCore


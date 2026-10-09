// The `queueMicrotask` global, on the VM thread. It puts the callback on the VM's JSC microtask queue as an
// InvokeFunctionJob, which holds the callback until the job runs; the call itself throws only for a missing or
// non-callable argument.

#include "host_functions/webapi/platform/microtask.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/Microtask.h>
#include <JavaScriptCore/MicrotaskQueueInlines.h>

namespace Collo::HostFunctions {

JSC_DEFINE_HOST_FUNCTION(queueMicrotask, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (call_frame->argumentCount() < 1)
        return JSC::throwVMTypeError(global_object, scope, "queueMicrotask requires a callback"_s);

    JSC::JSValue callback = call_frame->uncheckedArgument(0);
    if (!callback.isCallable())
        return JSC::throwVMTypeError(global_object, scope, "queueMicrotask callback must be a function"_s);

    // WebIDL invokes a callback function in its associated realm, so the job runs under the callback's global object
    // rather than the caller's.
    auto* callback_global = JSC::asObject(callback)->realm();
    scope.release();
    global_object->queueMicrotask(
        vm, JSC::QueuedTask { nullptr, JSC::InternalMicrotask::InvokeFunctionJob, 0, callback_global, callback });
    return JSC::JSValue::encode(JSC::jsUndefined());
}

void installWebApiMicrotask(Collo::GlobalObject* global_object, JSC::VM& vm)
{
    putWebApiFunction(global_object, global_object, vm, "queueMicrotask"_s, 1, queueMicrotask,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
}

} // namespace Collo::HostFunctions

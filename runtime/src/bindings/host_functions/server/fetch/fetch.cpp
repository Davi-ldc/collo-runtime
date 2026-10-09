// The `fetch` global that globals.def registers. Runs on the VM thread. A call needs the worker's host runtime and an
// execution context, either a request turn or the boot context the worker installs for module evaluation, and
// scheduleFetchFromRequest in request.cpp builds and schedules the request.

#include "host_functions/server/fetch/fetch.h"

#include "host_functions/runtime/fetch.h"
#include "host_functions/server/fetch/request.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/JSCInlines.h>

namespace Collo::HostFunctions {

JSC_DEFINE_HOST_FUNCTION(fetch, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    JSC::VM& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (call_frame->argumentCount() == 0)
        return JSC::throwVMTypeError(global_object, scope, "fetch requires a URL"_s);

    auto runtime = Runtime::requireActiveRequestRuntime(
        global_object, scope, "Fetch runtime is unavailable."_s, "fetch requires an active request turn."_s);
    if (!runtime.ok)
        return runtime.error;

    return scheduleFetchFromRequest(
        global_object, scope, runtime.value, call_frame->argument(0), call_frame->argument(1));
}

} // namespace Collo::HostFunctions

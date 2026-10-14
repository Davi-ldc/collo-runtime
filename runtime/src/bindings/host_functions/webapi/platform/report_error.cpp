// The `reportError` global on the VM thread: HTML's report an exception for the reported value, which fires a trusted,
// cancelable "error" ErrorEvent at the global object unless that global is already reporting one
// (reportWebApiException in `events/event_target.cpp`). An exception thrown by the event's listeners or by onerror is
// cleared and never reaches reportError's caller.

#include "host_functions/webapi/platform/report_error.h"

#include "host_functions/webapi/events/event.h"

#include <JavaScriptCore/JSCInlines.h>

namespace Collo::HostFunctions {

JSC_DEFINE_HOST_FUNCTION(reportError, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    reportWebApiException(global_object, call_frame->argument(0));
    // Only a termination can remain.
    RETURN_IF_EXCEPTION(scope, {});
    return JSC::JSValue::encode(JSC::jsUndefined());
}

} // namespace Collo::HostFunctions

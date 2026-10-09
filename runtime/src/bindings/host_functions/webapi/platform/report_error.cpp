// The `reportError` global on the VM thread, after HTML's report an exception steps: it fires a cancelable "error"
// ErrorEvent at the global object, with the reported value as its error and no source location. An added listener's
// exception is cleared inside the dispatch, but one from the global onerror handler propagates to reportError's caller
// (callGlobalEventHandlerIfNeeded in `events/event_target.cpp`).
// FIXME: HTML's in-error-reporting-mode flag is not kept, so reportError called from an error listener fires another
// event instead of skipping it.

#include "host_functions/webapi/platform/report_error.h"

#include "host_functions/webapi/events/event.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/ErrorInstance.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSObject.h>
#include <wtf/text/WTFString.h>

namespace Collo::HostFunctions {
namespace {

    // The event's message, which HTML leaves to the implementation: an Error's message, an empty string for any
    // other object or a symbol, and the string conversion of any other primitive.
    static WTF::String reportMessageFor(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue value)
    {
        if (auto* object = value.getObject()) {
            if (object->isErrorInstance())
                return uncheckedDowncast<JSC::ErrorInstance>(object)->tryGetMessageForDebugging();
            return {};
        }

        if (value.isSymbol())
            return {};

        auto message = valueToWebApiString(global_object, scope, value);
        RETURN_IF_EXCEPTION(scope, {});
        return message;
    }

} // namespace

JSC_DEFINE_HOST_FUNCTION(reportError, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto value = call_frame->argument(0);
    auto message = reportMessageFor(global_object, scope, value);
    RETURN_IF_EXCEPTION(scope, {});

    auto* event = createWebApiErrorEvent(global_object, WTF::move(message), {}, 0, 0, value);

    WebApiEventTargetHandle target;
    if (!webApiEventTargetHandle(JSC::JSValue(global_object), target))
        return JSC::throwVMTypeError(global_object, scope, "Global event target is unavailable"_s);

    dispatchWebApiEvent(global_object, scope, target, event);
    RETURN_IF_EXCEPTION(scope, {});
    return JSC::JSValue::encode(JSC::jsUndefined());
}

} // namespace Collo::HostFunctions

// How the rest of the bridge creates events and dispatches them on the runtime's event targets: the global object,
// EventTarget instances, AbortSignal, MessagePort and Performance. VM thread only. Every JSGlobalObject parameter must
// be a Collo::GlobalObject, which these functions downcast without checking. The cell classes are in
// event_private.h.

#pragma once

#include "host_functions/support.h"
#include "host_functions/webapi/events/event_target_data.h"

#include <JavaScriptCore/JSObject.h>
#include <wtf/text/WTFString.h>

namespace Collo::HostFunctions {

// An attribute order that runs the attribute handler before every listener, since listener orders start at 1.
static constexpr uint64_t WebApiEventAttributeHandlerBeforeListeners = 0;

// Fills `handle` when the value is one of the runtime's event targets; returns false for any other value.
bool webApiEventTargetHandle(JSC::JSValue, WebApiEventTargetHandle&);
// An Event of `type`. Events the runtime fires are trusted, hence the default. None of the create functions returns
// null: a failed cell allocation crashes the process.
JSC::JSObject* createWebApiEvent(JSC::JSGlobalObject*, WTF::String type, bool bubbles = false, bool cancelable = false,
    bool composed = false, bool trusted = true);
// A "message" MessageEvent carrying `data`, with an empty origin and lastEventId and a null source. `ports` becomes
// the ports attribute; null leaves it to the getter, which creates an empty frozen array on first read.
// FIXME: the event is created untrusted, though the HTML standard fires MessagePort's message events with isTrusted
// set to true.
JSC::JSObject* createWebApiMessageEvent(JSC::JSGlobalObject*, JSC::JSValue data, JSC::JSObject* ports);
// A cancelable "error" ErrorEvent, as reportError fires it.
// FIXME: the event is created untrusted, though the HTML standard's report an exception steps fire it with isTrusted
// set to true.
JSC::JSObject* createWebApiErrorEvent(JSC::JSGlobalObject*, WTF::String message, WTF::String filename, uint32_t lineno,
    uint32_t colno, JSC::JSValue error);
// Dispatches `event_value` at `target`, with the handle's attribute handler if it has one, and returns what
// dispatchEvent() returns: false when a listener canceled the event. Throws a TypeError for a value that is not an
// Event and an InvalidStateError DOMException for an event already being dispatched. A listener's exception is
// cleared and does not reach the caller, except one from the global object's onerror or onmessage handler, which
// propagates. A termination stays pending.
JSC::EncodedJSValue dispatchWebApiEvent(
    JSC::JSGlobalObject*, JSC::ThrowScope&, WebApiEventTargetHandle, JSC::JSValue event_value);
// dispatchWebApiEvent with an explicit attribute handler in place of the handle's. `attribute_handler` runs at
// `attribute_order`, and only for events of `attribute_event_type` when that is not null.
JSC::EncodedJSValue dispatchWebApiEventWithAttributeHandler(JSC::JSGlobalObject*, JSC::ThrowScope&,
    WebApiEventTargetHandle, JSC::JSValue event_value, JSC::JSValue attribute_handler,
    uint64_t attribute_order = WebApiEventAttributeHandlerBeforeListeners,
    WTF::String attribute_event_type = WTF::String());
// Removes the listener matching (type, callback, capture) as removeEventListener() does, together with its abort
// signal's cleanup record. No match, or a value that is not an event target, is a no-op.
void removeWebApiEventTargetListener(
    WebApiEventTargetHandle, const WTF::String& type, JSC::JSValue callback, bool capture);
void removeWebApiEventTargetListener(
    JSC::JSValue target_value, const WTF::String& type, JSC::JSValue callback, bool capture);
// Removes every listener of the target and their abort signals' cleanup records, as a MessagePort does when it closes
// or is transferred. During a dispatch on the target the removal is deferred (WebApiEventTargetData::clearListeners).
void clearWebApiEventTargetListeners(WebApiEventTargetHandle);

// Installs Event and its subclasses, EventTarget, and the global object's event methods and handlers. The host
// function registry (globals.def) calls it at most once per VM.
void installWebApiEvent(Collo::GlobalObject*, JSC::VM&);

} // namespace Collo::HostFunctions

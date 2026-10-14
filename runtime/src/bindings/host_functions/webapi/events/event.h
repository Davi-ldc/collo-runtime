// How the rest of the bridge creates events, dispatches them on the runtime's event targets (the global object,
// EventTarget instances, AbortSignal and MessagePort), keeps their event handler attributes and reports exceptions.
// VM thread only. Every JSGlobalObject parameter must be a Collo::GlobalObject, which these functions downcast without
// checking. The cell classes are in event_private.h.

#pragma once

#include "host_functions/support.h"
#include "host_functions/webapi/events/event_target_data.h"

#include <JavaScriptCore/JSObject.h>
#include <wtf/text/WTFString.h>

namespace Collo::HostFunctions {

// Fills `handle` when the value is one of the runtime's event targets; returns false for any other value.
bool webApiEventTargetHandle(JSC::JSValue, WebApiEventTargetHandle&);
// An Event of `type`. Events the runtime fires are trusted, hence the default. None of the create functions returns
// null: a failed cell allocation crashes the process.
JSC::JSObject* createWebApiEvent(JSC::JSGlobalObject*, WTF::String type, bool bubbles = false, bool cancelable = false,
    bool composed = false, bool trusted = true);
// A trusted "message" MessageEvent carrying `data`, with an empty origin and lastEventId and a null source, as a
// MessagePort fires it. `ports` becomes the ports attribute; null leaves it to the getter, which creates an empty
// frozen array on first read.
JSC::JSObject* createWebApiMessageEvent(JSC::JSGlobalObject*, JSC::JSValue data, JSC::JSObject* ports);
// Dispatches `event_value` at `target` and returns what dispatchEvent() returns: false when a listener or event
// handler canceled the event. Throws a TypeError for a value that is not an Event and an InvalidStateError
// DOMException for an event already being dispatched. A listener's or handler's exception does not reach the caller:
// it is cleared and reported (reportWebApiException) to the global object of the callback's realm. A termination stays
// pending and ends the dispatch; one already pending when the call begins makes it return an empty value without
// running any listener.
JSC::EncodedJSValue dispatchWebApiEvent(
    JSC::JSGlobalObject*, JSC::ThrowScope&, WebApiEventTargetHandle, JSC::JSValue event_value);
// Removes the listener matching (type, callback, capture) as removeEventListener() does, together with its abort
// signal's cleanup record. No match, or a value that is not an event target, is a no-op. Event handler records never
// match.
void removeWebApiEventTargetListener(
    WebApiEventTargetHandle, const WTF::String& type, JSC::JSValue callback, bool capture);
void removeWebApiEventTargetListener(
    JSC::JSValue target_value, const WTF::String& type, JSC::JSValue callback, bool capture);
// Removes every listener and event handler of the target and their abort signals' cleanup records, as a MessagePort
// does when it closes or is transferred. During a dispatch on the target the removal is deferred
// (WebApiEventTargetData::clearListeners).
void clearWebApiEventTargetListeners(WebApiEventTargetHandle);

// The value of the target's event handler attribute for `type`, or null.
JSC::JSValue webApiEventHandler(WebApiEventTargetHandle, const WTF::String& type);
// Sets the event handler attribute for `type` as HTML's event handler IDL attributes do. Web IDL's
// [LegacyTreatNonObjectAsNull] EventHandler keeps any object, callable or not, and turns every other value into null.
// Returns the stored value, an object or null. Returns an empty value, with a QuotaExceededError DOMException or an
// OutOfMemoryError thrown into `scope`, when the handler's record cannot be stored; the attribute is then null.
JSC::JSValue setWebApiEventHandler(
    JSC::JSGlobalObject*, JSC::ThrowScope&, WebApiEventTargetHandle, const WTF::String& type, JSC::JSValue value);

// HTML's report an exception: fires a trusted, cancelable "error" ErrorEvent carrying `exception` at the global
// object, unless that global is already reporting one (its error reporting mode), in which case nothing fires.
// Exceptions thrown by the event's listeners are cleared; a termination stays pending for the caller to check.
// `global_object` may be any JSGlobalObject: one that is not a Collo::GlobalObject reports nothing.
void reportWebApiException(JSC::JSGlobalObject*, JSC::JSValue exception);

// Installs Event and its subclasses, EventTarget, and the global object's event methods and onerror handler. The host
// function registry (globals.def) calls it at most once per realm.
void installWebApiEvent(Collo::GlobalObject*, JSC::VM&);

} // namespace Collo::HostFunctions

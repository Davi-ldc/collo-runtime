// MessageChannel and MessagePort within one VM, and the hooks the event target and structured clone code use to
// recognize and transfer ports. Runs on the VM thread. postMessage clones the message at once with the caller's
// global object, and the peer receives it from a microtask.

#pragma once

#include "host_functions/support.h"
#include "host_functions/webapi/events/event_target_data.h"

#include <wtf/Vector.h>

namespace Collo::HostFunctions {

// One port in a transfer list: `source` is the port being transferred, `clone` the new port that takes over its
// entanglement and queued messages when the transfer commits. Both are raw cell pointers and root nothing.
struct WebApiMessagePortTransfer {
    JSC::JSObject* source { nullptr };
    JSC::JSObject* clone { nullptr };
};

// Fills the handle for a MessagePort, with onmessage as its attribute handler for "message"; false for other values.
bool webApiMessagePortTargetHandle(JSC::JSValue, WebApiEventTargetHandle&);
// Deliberately starts the port when a "message" listener is added, which the Bun-derived compatibility test
// runtime/tests/webapi/message_channel/message_channel.test.js requires. HTML enables the port message queue only
// through start() or onmessage.
void webApiMessagePortDidAddListener(WebApiEventTargetHandle, const WTF::String& type);
bool webApiMessagePortIsValue(JSC::JSValue);
bool webApiMessagePortIsDetached(JSC::JSValue);
// Converts the ports given to the MessageEvent constructor or initMessageEvent (undefined or an iterable of
// MessagePorts) into a frozen array. Returns null with an exception on the ThrowScope on failure.
JSC::JSObject* webApiNormalizeMessagePortsArray(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue);
// Allocates the port that will replace the value when its transfer commits. Throws a DataCloneError and returns null
// unless the value is a MessagePort that is attached, open and entangled with a peer.
JSC::JSObject* webApiCreateMessagePortTransferClone(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue);
bool webApiValidateMessagePortTransfers(
    JSC::JSGlobalObject*, JSC::ThrowScope&, const WTF::Vector<WebApiMessagePortTransfer>&);
// Revalidates every transfer, then moves each source port's peer, queue and ref state to its clone and detaches the
// source. Returns false with a DataCloneError on the ThrowScope when a source stopped being transferable after the
// clone.
bool webApiCommitMessagePortTransfers(JSC::JSGlobalObject*, JSC::ThrowScope&, WTF::Vector<WebApiMessagePortTransfer>&);
// True when `source` is `sender` or its peer, which a port's own postMessage may not transfer.
bool webApiMessagePortTransferConflictsWith(JSC::JSObject* source, JSC::JSObject* sender);
// Must run after installWebApiEvent: MessagePort's prototype and constructor inherit from EventTarget's.
void installWebApiMessageChannel(Collo::GlobalObject*, JSC::VM&);

} // namespace Collo::HostFunctions

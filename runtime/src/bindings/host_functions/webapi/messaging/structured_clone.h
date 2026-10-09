// The structured clone algorithm behind the structuredClone global and MessagePort.postMessage. Clones are built
// with the caller's global object, without an intermediate serialized form. Runs on the VM thread.
//
// A clone with a transfer list happens in two phases, so a failure leaves every source intact: the clone validates
// the transfer list and builds the copy, and only then do the commit functions detach the transferred ArrayBuffers
// and MessagePorts. The vectors handed between the phases hold raw pointers, which root nothing (see the FIXME on
// StructuredCloneContext in structured_clone.cpp).

#pragma once

#include "host_functions/support.h"
#include "host_functions/webapi/messaging/message_channel.h"

#include <JavaScriptCore/ArrayBuffer.h>
#include <wtf/Vector.h>

namespace Collo::HostFunctions {

JSC::EncodedJSValue structuredClone(JSC::JSGlobalObject*, JSC::CallFrame*);
// Detaches the buffers in the vector, except one the engine cannot detach (see the FIXME at the commit loop in
// structured_clone.cpp). Checks them all before detaching any, so a buffer that became detached, shared or resizable
// since the clone throws a DataCloneError and leaves the others attached. Returns false with an exception on the
// ThrowScope on failure.
bool webApiCommitArrayBufferTransfers(JSC::JSGlobalObject*, JSC::ThrowScope&, WTF::Vector<JSC::ArrayBuffer*>&);
// Clones `message` with the transfer list `transfer` (undefined or an iterable) without committing the transfers.
// `blocked_sender` is the posting port: transferring it or its peer is a DataCloneError. On success `out_value` is
// the clone, `out_ports` a frozen array of the new MessagePorts, and the two vectors list what the caller must pass
// to webApiCommitArrayBufferTransfers and webApiCommitMessagePortTransfers. Returns false with an exception on the
// ThrowScope on failure.
bool structuredCloneForWebApiMessage(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue message,
    JSC::JSValue transfer, JSC::JSObject* blocked_sender, JSC::JSValue& out_value, JSC::JSObject*& out_ports,
    WTF::Vector<JSC::ArrayBuffer*>& out_array_buffer_transfers,
    WTF::Vector<WebApiMessagePortTransfer>& out_port_transfers);

} // namespace Collo::HostFunctions

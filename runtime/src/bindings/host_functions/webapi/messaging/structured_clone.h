// The structured clone algorithm behind the structuredClone global and MessagePort.postMessage. Clones are built
// with the caller's global object, without an intermediate serialized form. Runs on the VM thread.
//
// A clone with a transfer list happens in two phases, so a failure leaves every source intact: the clone validates the
// transfer list and builds the copy, and only then are the transferred ArrayBuffers detached and the MessagePorts
// moved. The clone context roots every cell it records until it dies, as the engine's own clone code does
// (runtime/CloneBase.h), so nothing it holds is unrooted across the script and allocation between the phases.

#pragma once

#include "host_functions/support.h"
#include "host_functions/webapi/messaging/message_channel.h"

#include <JavaScriptCore/ArrayBuffer.h>
#include <wtf/ScopedLambda.h>
#include <wtf/Vector.h>

namespace Collo::HostFunctions {

JSC::EncodedJSValue structuredClone(JSC::JSGlobalObject*, JSC::CallFrame*);
// Clones `message` with the transfer list `transfer` (undefined or an iterable) and commits the transfers, keeping
// every source and clone it recorded rooted until the commit ends. `blocked_sender` is the posting port: transferring
// it or its peer is a DataCloneError. `before_commit` runs after the clone, whose getters and iterator ran script, and
// before anything is detached; returning false stops the post with nothing committed, with or without an exception on
// the scope. On success `out_value` is the clone and `out_ports` a frozen array of the new MessagePorts. Returns false
// with an exception on the ThrowScope on failure, or without one when `before_commit` stopped the post.
bool structuredCloneAndCommitForWebApiMessage(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue message,
    JSC::JSValue transfer, JSC::JSObject* blocked_sender, const WTF::ScopedLambda<bool()>& before_commit,
    JSC::JSValue& out_value, JSC::JSObject*& out_ports);

} // namespace Collo::HostFunctions

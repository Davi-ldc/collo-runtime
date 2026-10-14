// What `text_codec.cpp` and `codec_streams.cpp` share to install the four Encoding Standard interfaces and to build
// their instances, on the VM thread. Nothing outside `encoding/` includes it.

#pragma once

#include "host_functions/support.h"

#include <JavaScriptCore/JSTypedArrays.h>

namespace Collo::HostFunctions {

// The structure of an instance a constructor builds: `base` for `new X()`, or a subclass structure whose prototype
// comes from new.target for `new Subclass()`. Reading new.target's prototype may run a getter; on an exception it
// returns null with the exception pending.
JSC::Structure* textCodecStructureForNewTarget(
    JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::CallFrame*, JSC::Structure* base);

// Defines the interface object `name` on the global object, not enumerable: a constructor of `length` arguments whose
// call throws a TypeError and whose construct runs `construct`. It owns `prototype` as its read-only `prototype`, and
// `prototype` gains `constructor` and a Symbol.toStringTag of `name`.
JSC::JSFunction* installTextCodecInterface(Collo::GlobalObject*, JSC::VM&, WTF::ASCIILiteral name, unsigned length,
    JSC::NativeFunction construct, JSC::JSObject* prototype);

// A Uint8Array of `length` bytes that the caller fills before any JavaScript sees it. Returns null with an exception
// pending when the length is too large for a typed array or the allocation fails.
JSC::JSUint8Array* createUninitializedUint8Array(JSC::JSGlobalObject*, JSC::ThrowScope&, size_t length);

struct TextCodecStreamsApi {
    JSC::JSObject* encoder_stream_constructor;
    JSC::JSObject* encoder_stream_prototype;
    JSC::Structure* encoder_stream_structure;
    JSC::JSObject* decoder_stream_constructor;
    JSC::JSObject* decoder_stream_prototype;
    JSC::Structure* decoder_stream_structure;
};

// Installs TextEncoderStream and TextDecoderStream on the realm's global object. `installWebApiTextCodec` caches the
// result with the realm's other text codec objects, and no stream can be constructed before it does.
TextCodecStreamsApi installTextCodecStreams(Collo::GlobalObject*, JSC::VM&);

} // namespace Collo::HostFunctions

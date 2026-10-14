// Declares the installer of the Encoding Standard globals: TextEncoder, TextDecoder, TextEncoderStream and
// TextDecoderStream. The host function registry (`globals.def`) calls it once per realm, on the VM thread, while the
// realm's global object is built. The installer stores each constructor, prototype and structure in the realm's
// Web API cache (`ColloWebApiCache` in jsc/runtime/state.h), where `text_codec.cpp` and `codec_streams.cpp` find the
// structures to build instances.

#pragma once

#include "jsc/runtime/state.h"

namespace Collo::HostFunctions {

void installWebApiTextCodec(Collo::GlobalObject*, JSC::VM&);

} // namespace Collo::HostFunctions

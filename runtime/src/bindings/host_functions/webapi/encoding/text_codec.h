// Declares the installer of the Encoding Standard globals: TextEncoder, TextDecoder, TextEncoderStream and
// TextDecoderStream. The host function registry (`globals.def`) calls it once per VM, on the VM thread, while
// collo_vm_create builds the global object. The installer stores each constructor, prototype and structure in the VM's
// Web API cache (`ColloWebApiCache` in jsc/runtime/state.h), where `text_codec.cpp` finds them to build instances.

#pragma once

#include "jsc/runtime/state.h"

namespace Collo::HostFunctions {

void installWebApiTextCodec(Collo::GlobalObject*, JSC::VM&);

} // namespace Collo::HostFunctions

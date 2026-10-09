// Declares the installer of the File global. blob.cpp implements it beside Blob, because the File cell derives from
// the Blob cell. The host function registry (`globals.def`) calls it at most once per realm, on the VM thread.

#pragma once

#include "host_functions/support.h"

namespace Collo::HostFunctions {

// Must run after installWebApiBlob: File's prototype and constructor inherit from the Blob prototype and constructor
// that installWebApiBlob cached on the global object.
void installWebApiFile(Collo::GlobalObject*, JSC::VM&);

} // namespace Collo::HostFunctions

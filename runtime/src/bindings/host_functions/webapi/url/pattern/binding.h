// Declares the installer of the URLPattern global. The host function registry (`globals.def`) calls it once per
// realm, on the VM thread, when the VM installs Web APIs; `binding.cpp` says what it installs.

#pragma once

#include "host_functions/support.h"

namespace Collo::HostFunctions {

void installWebApiURLPattern(Collo::GlobalObject*, JSC::VM&);

} // namespace Collo::HostFunctions

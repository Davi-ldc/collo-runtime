// Declares the installer of the Web Cryptography API globals. The host function registry (`globals.def`) calls it at
// most once per VM, on the VM thread; `crypto.cpp` says what it installs.

#pragma once

#include "jsc/runtime/state.h"

namespace Collo::HostFunctions {

void installWebApiCrypto(Collo::GlobalObject*, JSC::VM&);

} // namespace Collo::HostFunctions

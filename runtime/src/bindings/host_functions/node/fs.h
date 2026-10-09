// Declares installNodeFs, which fs.cpp defines and installWorkerNodeBuiltins in registry.cpp calls on a worker's VM
// thread.

#pragma once

#include "jsc/runtime/state.h"

namespace Collo::HostFunctions {

void installNodeFs(Collo::GlobalObject*, JSC::VM&);

} // namespace Collo::HostFunctions

// Declares the installer of the `navigator` global and the refresh of its hardwareConcurrency after a fork. Both run
// on the VM thread; `navigator.cpp` says what the object holds.

#pragma once

#include "jsc/runtime/state.h"

namespace Collo::HostFunctions {

// Defines `navigator` on the global object. The host function registry (`globals.def`) calls it once per VM from
// `collo_vm_create` when the VM installs Web APIs.
void installWebApiNavigator(Collo::GlobalObject*, JSC::VM&);
// Recomputes navigator.hardwareConcurrency from the calling process's CPU affinity. `collo_vm_post_fork_child` calls
// it in each worker, before seccomp, so the value describes the worker rather than the zygote; it skips the call on
// a VM without Web APIs (`ColloVm::web_apis_installed`). Does nothing when `navigator` is not an object.
void refreshWebApiNavigator(Collo::GlobalObject*, JSC::VM&);

} // namespace Collo::HostFunctions

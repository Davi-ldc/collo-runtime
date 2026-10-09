// Declares the installer of the `navigator` global and the refresh of its hardwareConcurrency after a fork. Both run
// on the VM thread; `navigator.cpp` says what the object holds.

#pragma once

#include "jsc/runtime/state.h"

namespace Collo::HostFunctions {

// The CPUs of the calling process's affinity mask, or the online CPUs when the mask cannot be read, clamped to
// [1, WebApiNavigatorHardwareConcurrencyMax]. It makes a system call the worker's seccomp filter denies, so only VM
// creation and `collo_vm_post_fork_child` call it, and every realm reads the result from
// `ColloVm::hardware_concurrency`.
uint32_t readHardwareConcurrency();
// Defines `navigator` on a realm's global object. The host function registry (`globals.def`) calls it once per realm
// whose VM installs Web APIs.
void installWebApiNavigator(Collo::GlobalObject*, JSC::VM&);
// Sets navigator.hardwareConcurrency from `ColloVm::hardware_concurrency`. `collo_vm_post_fork_child` calls it on
// every realm of a worker after it read the count again, before seccomp, so the value describes the worker rather
// than the zygote; it skips the call on a VM without Web APIs (`ColloVm::web_apis_installed`). Does nothing when
// `navigator` is not an object.
void refreshWebApiNavigator(Collo::GlobalObject*, JSC::VM&);

} // namespace Collo::HostFunctions

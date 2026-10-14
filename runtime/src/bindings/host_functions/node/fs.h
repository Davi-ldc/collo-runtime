// Declares the two entry points of the node:fs binding that fs.cpp defines: installNodeFs, which
// installWorkerNodeBuiltins in registry.cpp calls on a VM thread, and openNodeFsForProcess, which
// collo_vm_enable_node_fs_for_worker in vm.cpp calls.

#pragma once

#include "jsc/runtime/state.h"

namespace Collo::HostFunctions {

// Lets every node:fs operation in this process reach the filesystem; until the first call each one fails with EPERM.
// Call it only once the process is inside the worker's chroot and seccomp filter, since nothing else confines what
// node:fs reaches. Nothing closes it again. Any thread may call it.
void openNodeFsForProcess();
void installNodeFs(Collo::GlobalObject*, JSC::VM&);

} // namespace Collo::HostFunctions

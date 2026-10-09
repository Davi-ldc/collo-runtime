// The entry points that install host functions on a Collo global, which registry.cpp defines and vm.cpp calls on the
// VM thread with the JSC API lock held. The includes below bring in the declaration of every name globals.def lists,
// because registry.cpp expands that list against this header, so a new globals.def entry adds its header here.

#pragma once

#include "jsc/runtime/state.h"
#include "host_functions/node/fs.h"
#include "host_functions/webapi/events/abort.h"
#include "host_functions/webapi/encoding/base64.h"
#include "host_functions/webapi/files/blob.h"
#include "host_functions/webapi/crypto/crypto.h"
#include "host_functions/webapi/dom/dom_exception.h"
#include "host_functions/webapi/events/event.h"
#include "host_functions/server/fetch/fetch.h"
#include "host_functions/webapi/files/file.h"
#include "host_functions/webapi/files/formdata.h"
#include "host_functions/server/fetch/headers.h"
#include "host_functions/webapi/messaging/message_channel.h"
#include "host_functions/webapi/platform/microtask.h"
#include "host_functions/webapi/platform/navigator.h"
#include "host_functions/webapi/platform/performance.h"
#include "host_functions/webapi/platform/report_error.h"
#include "host_functions/server/fetch/request.h"
#include "host_functions/server/fetch/response.h"
#include "host_functions/webapi/streams/readable_stream.h"
#include "host_functions/webapi/messaging/structured_clone.h"
#include "host_functions/webapi/encoding/text_codec.h"
#include "host_functions/webapi/platform/timers.h"
#include "host_functions/webapi/url/url.h"
#include "host_functions/webapi/url/pattern/binding.h"

namespace Collo::HostFunctions {

// Defines the functions and classes globals.def lists, `self`, and any explicit resource management symbol the engine
// lacks. collo_vm_create calls it unless the options disable Web APIs, so in production the zygote installs these
// globals once and every worker inherits them. It has no failure path: JSC aborts the process when a cell allocation
// fails, and the install helpers abort when an object they define is missing afterwards, so a change to that policy
// aborts rather than leaving a global half built.
void install(Collo::GlobalObject* global_object, JSC::VM& vm);
// Defines the `process` global: an empty `env`, plus `platform`, `version` and `pid`. A worker child calls it after the
// fork through collo_vm_install_process, so `pid` is the worker's own. Returns COLLO_STATUS_INVALID_ARGUMENT for a null
// global, and then defines no `process` global at all.
ColloStatus installProcess(Collo::GlobalObject* global_object, JSC::VM& vm);
// Defines the `node:fs` binding that module_loader.cpp's `node:fs` and `node:fs/promises` modules re-export. A worker
// child calls it after its seccomp filter is in place, through collo_vm_enable_node_fs_for_worker, so the zygote's VM
// never has file access.
void installWorkerNodeBuiltins(Collo::GlobalObject* global_object, JSC::VM& vm);

} // namespace Collo::HostFunctions

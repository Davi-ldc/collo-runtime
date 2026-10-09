// Declares the installer of `performance` and the performance timeline interfaces, and the hook through which
// `event_target.cpp` dispatches events on `performance`. Both run on the VM thread; the implementation is under
// `performance/`, with the shared cell classes in `performance/private.h`.

#pragma once

#include "host_functions/webapi/events/event.h"

namespace Collo::HostFunctions {

// Returns true and fills `handle` with the event target data of the Performance cell when `value` is one; returns
// false and leaves `handle` untouched otherwise.
bool webApiPerformanceTargetHandle(JSC::JSValue, WebApiEventTargetHandle&);
// Defines `performance` and the Performance, PerformanceEntry, PerformanceMark, PerformanceMeasure,
// PerformanceObserver, PerformanceObserverEntryList and PerformanceTiming interfaces. The host function registry
// (`globals.def`) calls it once per VM from `collo_vm_create` when the VM installs Web APIs.
void installWebApiPerformance(Collo::GlobalObject*, JSC::VM&);

} // namespace Collo::HostFunctions

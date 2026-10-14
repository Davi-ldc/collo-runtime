// Declares the installer of `performance` and the performance timeline interfaces. It runs on the VM thread; the
// implementation is under `performance/`, with the shared cell classes in `performance/private.h`.

#pragma once

#include "host_functions/support.h"

namespace Collo::HostFunctions {

// Defines `performance` and the Performance, PerformanceEntry, PerformanceMark, PerformanceMeasure,
// PerformanceObserver and PerformanceObserverEntryList interfaces, and stores the realm's Performance cell in its Web
// API cache. The host function registry (`globals.def`) calls it once per realm when the VM installs Web APIs.
void installWebApiPerformance(Collo::GlobalObject*, JSC::VM&);

} // namespace Collo::HostFunctions

// The installer of the Response class. The Response cell is JSColloResponse in response_object.h; response.cpp holds
// its JavaScript methods and the ABI calls that create and extract Response cells. VM thread only.

#pragma once

#include "host_functions/support.h"

namespace Collo::HostFunctions {

// Installs the Response constructor with its json, redirect and error statics and the Response prototype on the global
// object, and stores them with the Response structure in the VM's Web API cache. Host function installation calls it
// once per VM.
void installServerResponse(Collo::GlobalObject*, JSC::VM&);

} // namespace Collo::HostFunctions

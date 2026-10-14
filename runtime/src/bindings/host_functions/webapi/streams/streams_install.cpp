// Installs every stream class of this directory on a realm. Each family defines its interfaces and caches the
// structures its cells are built from; this file only orders them. TextEncoderStream and TextDecoderStream are
// installed after this by the encoding directory (installTextCodecStreams in encoding/codec_streams.cpp, which
// text_codec.cpp's installer calls), on the TransformStream surface of transform_stream.h. Runs on the VM thread.
//
// Installation runs once per realm when the VM installs the Web APIs; a worker's VM and main realm were created and
// installed in the zygote before the fork, so their reaction functions, prototypes and structures are shared pages.
// What the realm's ColloWebApiCache holds lives until destroyVmContents.
//
// The directory holds, by mechanism: stream_common (shared helpers), stream_reactions (the reaction functions),
// readable_stream (core), readable_byte_stream (BYOB), readable_stream_tee, readable_stream_from,
// readable_stream_consume (Body consumption), readable_stream_api (script surface), writable_stream and its api,
// transform_stream, pipe_to, compression_stream and queuing_strategy, with the *_objects files holding the
// collector-side code of the readable and writable families.

#include "host_functions/webapi/streams/compression_stream_private.h"
#include "host_functions/webapi/streams/pipe_to_private.h"

namespace Collo::HostFunctions {

void installWebApiReadableStream(Collo::GlobalObject* global_object, JSC::VM& vm)
{
    // The reaction functions exist before any stream that could register one.
    installStreamFunctions(global_object, vm);
    installReadableStreamClasses(global_object, vm);
    installWritableStreamClasses(global_object, vm);
    installTransformStreamClasses(global_object, vm);
    installCompressionStreamClasses(global_object, vm);
    installQueuingStrategyClasses(global_object, vm);
    global_object->webApiCache().pipe_to_state_structure.set(
        vm, JSColloPipeToState::createStructure(vm, global_object, global_object->objectPrototype()));
}

} // namespace Collo::HostFunctions

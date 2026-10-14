// The TransformStream surface other Web API classes build on. A GenericTransformStream class (CompressionStream,
// DecompressionStream, TextEncoderStream, TextDecoderStream) is a transform stream cell whose prototype is the class's
// own and whose transformer is native: the class keeps no cell, controller or JavaScript function of its own. Runs on
// the VM thread, except visitAggregate.
//
// The stream calls its native transformer one method at a time and never while another of its methods is on the
// stack: when script that write() runs errors or cancels the stream, the stream releases the transformer, and reads its
// memory cost, only after write() returns. The stream owns the transformer from creation until the collector sweeps the
// stream.

#pragma once

#include "jsc/runtime/state.h"

#include <JavaScriptCore/SlotVisitorMacros.h>
#include <wtf/Ref.h>
#include <wtf/RefCounted.h>

#include <cstddef>
#include <cstdint>

namespace Collo::HostFunctions {

// The interface a transform stream cell implements; each class's accessors check it.
enum class TransformStreamKind : uint8_t {
    // Built by the TransformStream constructor, with a JavaScript transformer.
    TransformStream,
    CompressionStream,
    DecompressionStream,
    TextEncoderStream,
    TextDecoderStream,
};

class TransformStreamNativeTransformer : public WTF::RefCounted<TransformStreamNativeTransformer> {
public:
    virtual ~TransformStreamNativeTransformer() = default;

    // One chunk the writable side delivers, once the readable side has pulled since the last output and the previous
    // write's output has all been produced. Converts and keeps it: as input still to transform, or already as output.
    // Returns false after throwing into the scope: a TypeError for a chunk the class does not accept, an
    // OutOfMemoryError, or what the conversion threw, which errors both sides of the stream. May run script
    // (TextEncoderStream converts its chunk with ToString).
    virtual bool write(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue chunk) = 0;
    // The writable side closed, so no write follows; every write's output has been produced by then. Returns false
    // after throwing into the scope, which errors both sides. Runs no script. The stream enqueues the output close()
    // leaves without waiting for a read, as a flush does, so that output must stay within a bound that does not grow
    // with what was written: what a codec keeps buffered, or a partial character.
    virtual bool close(JSC::JSGlobalObject*, JSC::ThrowScope&) = 0;
    // True while produce() still has output to give for what write() and close() accepted. After close() it turns
    // false only once the last output has been produced.
    virtual bool hasPendingOutput() const = 0;
    // The next output chunk, a Uint8Array or a string, which the stream enqueues as it is: the stream sets no size
    // limit, so a transformer that must bound its output chunks does so itself, as the compression classes do with
    // WebApiCompressionStreamOutputChunkBytes (limits.h). Returns the empty JSValue when the step consumed input
    // without producing output. Each call produces output, consumes input or ends hasPendingOutput(), or else throws.
    // Throws into the scope a TypeError for input it cannot transform (invalid or truncated compressed data, data after
    // its end, a fatal decoder's invalid sequence) or an OutOfMemoryError. Runs no script. The stream calls it only
    // while hasPendingOutput() is true: during a write while the readable side wants output, and after close() until
    // the output ends.
    virtual JSC::JSValue produce(JSC::JSGlobalObject*, JSC::ThrowScope&) = 0;
    // Frees buffers and library state once the stream finished, errored or was canceled. Only memoryCost(),
    // visitAggregate() and the class's own accessors (TextDecoderStream's encoding, fatal and ignoreBOM) are called
    // afterwards, so the settings they read stay. Safe to repeat. A stream that becomes unreachable mid-use is swept
    // without calling it, so the transformer's destructor must free everything release() would.
    virtual void release() = 0;
    // Bytes held outside the JS heap. The stream reports growth to the collector after each call, and visitChildren
    // reports the last value it read.
    virtual size_t memoryCost() const { return 0; }
    // Reports cells held in WriteBarrier fields, as ReadableStreamNativeSource::visitAggregate does: the owning stream
    // calls them from its visitChildren under its cell lock, on a collector thread, so they read only those fields.
    virtual void visitAggregate(JSC::AbstractSlotVisitor&) { }
    virtual void visitAggregate(JSC::SlotVisitor&) { }
};

// The structure of a GenericTransformStream class's instances, whose prototype is the class's.
JSC::Structure* createTransformStreamStructure(JSC::VM&, JSC::JSGlobalObject*, JSC::JSValue prototype);
// A transform stream of `kind`, which must not be TransformStreamKind::TransformStream, with `structure` and
// `transformer`, set up as the Streams Standard's "set up a TransformStream" does: writable high-water mark 1, readable
// high-water mark 0, each chunk counted as 1. A write waits out backpressure as the standard's does, until the readable
// side pulls, and settles once its output is enqueued; that output is produced only while the readable side wants it.
// A close enqueues the transformer's remaining output at once, closes the readable side and settles. Returns null with
// an exception pending.
JSC::JSObject* createNativeTransformStream(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::Structure*, TransformStreamKind,
    WTF::Ref<TransformStreamNativeTransformer>&&);
// The stream when `value` is a transform stream of `kind`, otherwise null.
JSC::JSObject* transformStreamOfKind(JSC::JSValue, TransformStreamKind);
// The sides and the transformer of a stream transformStreamOfKind returned. The transformer stays with the stream after
// release(), for the class's accessors; a stream with a JavaScript transformer has none.
JSC::JSObject* transformStreamReadable(JSC::JSObject*);
JSC::JSObject* transformStreamWritable(JSC::JSObject*);
TransformStreamNativeTransformer* transformStreamNativeTransformer(JSC::JSObject*);

} // namespace Collo::HostFunctions

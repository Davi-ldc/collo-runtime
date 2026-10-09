// The ReadableStream surface the rest of the bridge uses: streams over a native source or over bytes, recognizing a
// stream, and draining a stream backed by a native source in one step. Fetch bodies and Blob streams implement
// ReadableStreamNativeSource. Everything here runs on the VM thread, except visitAggregate.
//
// A stream adopts its native source and calls release() exactly once: when the stream closes or errors, or else from
// its destructor when the collector sweeps it. A source refers to cells only through WriteBarrier fields that
// visitAggregate reports, never through a Strong handle: any path from such a root back to the stream would keep
// both alive until the VM is destroyed. A stream returned here is a new cell, rooted only by the caller's stack
// until the caller stores it.

#pragma once

#include "jsc/runtime/state.h"
#include "host_functions/webapi/streams/shared_bytes.h"

#include <JavaScriptCore/SlotVisitorMacros.h>
#include <wtf/RefCounted.h>
#include <wtf/RefPtr.h>
#include <wtf/Vector.h>

#include <span>

namespace Collo::HostFunctions {

class ReadableStreamNativeSource : public WTF::RefCounted<ReadableStreamNativeSource> {
public:
    virtual ~ReadableStreamNativeSource() = default;

    // Produces the next chunk as a {value, done} result object or a promise for one. The stream reads only own
    // properties of the result, and a result that is not an object or has no own done errors the stream with a
    // TypeError. A pending default read receives the result object itself, with value unchecked. Otherwise a result
    // that is not done must carry an ArrayBufferView that is neither detached nor out of bounds, because streams over
    // a native source are byte streams, and anything else errors the stream with a TypeError. An exception thrown into
    // the scope, or a rejected promise, errors the stream with the thrown value or the rejection reason. The stream
    // pulls only while a read is pending and never starts a second pull before the first settles.
    virtual JSC::EncodedJSValue pull(JSC::JSGlobalObject*, JSC::ThrowScope&) = 0;
    // Called when a readable stream is canceled. The stream's cancel promise follows the returned value or promise and
    // then resolves to undefined, and the stream closes. An exception thrown into the scope propagates out of the
    // stream's cancel and leaves the stream readable.
    virtual JSC::EncodedJSValue cancel(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue reason) = 0;
    // Moves the unread remainder into two new sources and returns true; the original stream stays locked and never
    // pulls from this source again. Returns false after throwing into the scope, or without an exception when the
    // source cannot be teed, which the stream reports as a TypeError. The default cannot be teed.
    virtual bool tee(JSC::JSGlobalObject*, JSC::ThrowScope&, WTF::RefPtr<ReadableStreamNativeSource>& out_first,
        WTF::RefPtr<ReadableStreamNativeSource>& out_second)
    {
        out_first = nullptr;
        out_second = nullptr;
        return false;
    }
    virtual bool appendRemainingBytes(WTF::Vector<uint8_t>&) { return false; }
    // Appends every unread byte to the output in one step and returns true. Returns false with out_supported false
    // when the source cannot drain synchronously, which leaves it untouched and makes the caller read chunk by chunk;
    // with out_exceeds_limit true when the output would grow past the given total size; and otherwise when the output
    // cannot grow. After a false return with out_supported true, the stream closes and releases the source.
    virtual bool appendRemainingBytes(WTF::Vector<uint8_t>&, size_t, bool& out_exceeds_limit, bool& out_supported)
    {
        out_exceeds_limit = false;
        out_supported = false;
        return false;
    }
    // Lets go of what the source reads from. The stream never calls it under its cell lock, because a source may
    // call into Zig here.
    virtual void release() { }

    // Reports the cells the source holds in WriteBarrier fields. The owning stream calls it from its visitChildren
    // under the stream's cell lock, so the collector traces a cycle through the source where a Strong handle would
    // pin it. It runs on a collector thread while the mutator may be inside another method, so it reads only those
    // fields, each a single word.
    virtual void visitAggregate(JSC::AbstractSlotVisitor&) { }
    virtual void visitAggregate(JSC::SlotVisitor&) { }
};

// Returns a new byte stream that owns the source.
JSC::JSObject* createReadableStreamFromNativeSource(
    JSC::JSGlobalObject*, JSC::ThrowScope&, WTF::Ref<ReadableStreamNativeSource>&&);
// Copies the bytes into a new byte stream. Throws an OutOfMemoryError and returns null when the copy fails.
JSC::JSObject* createReadableStreamFromBytes(JSC::JSGlobalObject*, JSC::ThrowScope&, std::span<const uint8_t>);
// Returns a source over a copy of the bytes, or null when allocation fails.
WTF::RefPtr<ReadableStreamNativeSource> createReadableStreamNativeSourceFromBytes(std::span<const uint8_t>);
// Returns a source over size bytes of the buffer starting at offset, clamped to the buffer and shared without a
// copy, or null when allocation fails.
WTF::RefPtr<ReadableStreamNativeSource> createReadableStreamNativeSourceFromSharedBytes(
    WTF::Ref<ColloSharedBytes>&&, size_t offset, size_t size);
// Returns a {value, done} read result: what a read resolves with, and what ReadableStreamNativeSource::pull produces.
JSC::JSObject* createReadableStreamReadResult(JSC::JSGlobalObject*, JSC::JSValue value, bool done);
// The stream the value holds, or null when the value is not a ReadableStream.
JSC::JSObject* readableStreamFromValue(JSC::JSValue);
// Both return false for an object that is not a ReadableStream.
bool readableStreamIsLocked(JSC::JSObject*);
bool readableStreamIsDisturbed(JSC::JSObject*);
// NotAvailable leaves the stream untouched: it has no native source, is not readable, is disturbed or locked, has
// queued chunks, a pending read or a pull in flight, or its source cannot drain in one step. Every other result
// closes the stream and marks it disturbed. Drained means the output holds every remaining byte; after TooLarge or
// OutOfMemory the remaining bytes are lost.
enum class ReadableStreamDrainResult : uint8_t {
    NotAvailable,
    Drained,
    OutOfMemory,
    TooLarge,
};
// Appends the remaining bytes of a stream backed by a native source to the output in one step, keeping the output
// within max_size bytes in total.
ReadableStreamDrainResult readableStreamDrainNativeBytes(
    JSC::JSGlobalObject*, JSC::JSObject*, WTF::Vector<uint8_t>&, size_t max_size);

void installWebApiReadableStream(Collo::GlobalObject*, JSC::VM&);

} // namespace Collo::HostFunctions

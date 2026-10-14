// The ReadableStream surface the rest of the bridge uses: streams over a native source or over bytes, recognizing a
// stream, teeing one under its clone budget, and the bytes of one chunk. Fetch bodies and Blob streams implement
// ReadableStreamNativeSource. Everything here runs on the VM thread, except visitAggregate.
//
// A stream adopts its native source and calls release() exactly once: when the stream closes, errors or is canceled,
// or else from its destructor when the collector sweeps it. A source refers to cells only through WriteBarrier fields
// that visitAggregate reports, never through a Strong handle: any path from such a root back to the stream would keep
// both alive until the VM is destroyed. Three rules follow from the stream being the only thing that traces them:
//   - A source has no owner cell to barrier, so it stores a cell in a field only before a stream adopts it, and
//     afterwards only clears fields.
//   - From the source's creation, or from tee(), until a stream adopts it, nothing traces its cells, so the caller
//     keeps them on its stack.
//   - Script a source method runs can cancel or error the stream, which releases the source and stops tracing its
//     cells. The stream's protecting reference keeps the source object alive across the call, not its cells, so after
//     running script a method reads its fields again, which release() cleared, instead of using cells it read before.
// A stream returned here is a new cell, rooted only by the caller's stack until the caller stores it.

#pragma once

#include "host_functions/webapi/streams/shared_bytes.h"
#include "jsc/runtime/state.h"

#include <JavaScriptCore/JSArrayBufferView.h>
#include <JavaScriptCore/SlotVisitorMacros.h>
#include <wtf/RefCounted.h>
#include <wtf/RefPtr.h>
#include <wtf/Vector.h>

#include <span>

namespace Collo::HostFunctions {

// What one pull of a native source produced. A synchronous source answers with a chunk or with its end at once, and
// the stream fulfills a pending read without a promise of its own; an asynchronous source answers with a promise for a
// {value, done} result. The cells it names are rooted by the stack that holds it.
struct ReadableStreamPull {
    enum class Kind : uint8_t {
        // `chunk` holds bytes no other value aliases, so script may write through it.
        Chunk,
        // The source has no more bytes.
        Done,
        // `promise` settles with a {value, done} result, or rejects with the reason the stream errors with.
        Pending,
        // The source threw into the scope it was given.
        Threw,
    };

    Kind kind { Kind::Threw };
    JSC::JSArrayBufferView* chunk { nullptr };
    JSC::JSPromise* promise { nullptr };

    static ReadableStreamPull withChunk(JSC::JSArrayBufferView* chunk) { return { Kind::Chunk, chunk, nullptr }; }
    static ReadableStreamPull done() { return { Kind::Done, nullptr, nullptr }; }
    static ReadableStreamPull pending(JSC::JSPromise* promise) { return { Kind::Pending, nullptr, promise }; }
    static ReadableStreamPull threw() { return {}; }
    // A promise that a pull helper returned, or the empty value it returns after throwing.
    static ReadableStreamPull fromPromise(JSC::EncodedJSValue value)
    {
        if (auto* promise = dynamicDowncast<JSC::JSPromise>(JSC::JSValue::decode(value)))
            return pending(promise);
        return threw();
    }
};

class ReadableStreamNativeSource : public WTF::RefCounted<ReadableStreamNativeSource> {
public:
    virtual ~ReadableStreamNativeSource() = default;

    // Produces the next chunk. A chunk, or the value of a pending result that is not done, must be an ArrayBufferView
    // that is neither detached nor out of bounds, because streams over a native source are byte streams; anything else
    // errors the stream with a TypeError, as does a pending result that is not an object or has no own done property.
    // A throw or a rejected promise errors the stream with the thrown value or the rejection reason. The stream pulls
    // only while a read is pending and never starts a second pull before the first settles.
    virtual ReadableStreamPull pull(JSC::JSGlobalObject*, JSC::ThrowScope&) = 0;
    // Called when a readable stream is canceled, after the stream closed. The stream's cancel promise follows the
    // returned value or promise and then resolves to undefined. An exception thrown into the scope rejects the
    // stream's cancel promise with it.
    virtual JSC::EncodedJSValue cancel(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue reason) = 0;
    // Moves the unread remainder into two new sources and returns true; the original stream stays locked and never
    // pulls from this source again. Returns false after throwing into the scope, or without an exception when the
    // source cannot be teed, and the tee then reads the stream instead. The default cannot be teed. The stream asks
    // only while the source holds every unread byte: none queued in the stream and no pull in flight.
    virtual bool tee(JSC::JSGlobalObject*, JSC::ThrowScope&, WTF::RefPtr<ReadableStreamNativeSource>& out_first,
        WTF::RefPtr<ReadableStreamNativeSource>& out_second)
    {
        out_first = nullptr;
        out_second = nullptr;
        return false;
    }
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

// The clone count of one body's clone tree. Every tee(), and Response.clone() or Request.clone() of a streaming
// body, counts against the budget of the tree it branches, which every body and stream of the tree shares, so
// WebApiBodyCloneFanoutMax (limits.h) bounds the clones of the whole tree. A clone of an in-memory body joins the
// tree's budget, creating it when the tree has none yet, but counts nothing, since it shares the original's storage.
class StreamCloneBudget final : public WTF::RefCounted<StreamCloneBudget> {
public:
    // Creates `budget` when it is null, so a body and the stream over it, or a body and its in-memory clone, share one
    // before either clones. Throws an OutOfMemoryError and returns false when the budget cannot be allocated.
    static bool ensure(JSC::JSGlobalObject*, JSC::ThrowScope&, WTF::RefPtr<StreamCloneBudget>& budget);
    // A clone checks room before it can still fail and counts once it exists, so a failed clone counts nothing:
    // checkRoom() throws a QuotaExceededError DOMException and returns false once the tree has made
    // WebApiBodyCloneFanoutMax clones, and countClone() counts the clone.
    bool checkRoom(JSC::JSGlobalObject*, JSC::ThrowScope&) const;
    void countClone() { m_clone_count++; }

private:
    StreamCloneBudget() = default;

    unsigned m_clone_count { 0 };
};

// Returns a new byte stream that owns the source. `clone_budget` is the budget of the body the stream reads, which its
// tees share; null starts the stream's own at its first tee.
JSC::JSObject* createReadableStreamFromNativeSource(JSC::JSGlobalObject*, JSC::ThrowScope&,
    WTF::Ref<ReadableStreamNativeSource>&&, WTF::RefPtr<StreamCloneBudget>&& clone_budget = nullptr);
// Copies the bytes into a new byte stream. Throws an OutOfMemoryError and returns null when the copy fails.
JSC::JSObject* createReadableStreamFromBytes(JSC::JSGlobalObject*, JSC::ThrowScope&, std::span<const uint8_t>);
// Returns a source over a copy of the bytes, or null when allocation fails.
WTF::RefPtr<ReadableStreamNativeSource> createReadableStreamNativeSourceFromBytes(std::span<const uint8_t>);
// Returns a source over size bytes of the buffer starting at offset, clamped to the buffer and shared without a
// copy, or null when allocation fails.
WTF::RefPtr<ReadableStreamNativeSource> createReadableStreamNativeSourceFromSharedBytes(
    WTF::Ref<ColloSharedBytes>&&, size_t offset, size_t size);
// Returns a {value, done} read result: what a read resolves with, and what a pending native pull settles with.
JSC::JSObject* createReadableStreamReadResult(JSC::JSGlobalObject*, JSC::JSValue value, bool done);
// The stream the value holds, or null when the value is not a ReadableStream.
JSC::JSObject* readableStreamFromValue(JSC::JSValue);
// Both return false for an object that is not a ReadableStream.
bool readableStreamIsLocked(JSC::JSObject*);
bool readableStreamIsDisturbed(JSC::JSObject*);
// ReadableStreamTee for a ReadableStream of any kind, counted against the stream's clone budget, which both branches
// share. Throws, and returns false, a TypeError for a locked stream and a QuotaExceededError past the budget, leaving
// the stream untouched. A closed or errored stream is teed by reading it, which closes or errors both branches.
bool readableStreamTee(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSObject* stream, JSC::JSObject*& out_first,
    JSC::JSObject*& out_second);
// The bytes of one chunk a stream yielded, for the readers that need bytes: Body consumption and the response body.
// Accepts an ArrayBuffer of fixed length or any ArrayBufferView, neither detached nor out of bounds; anything else,
// a string included, throws a TypeError and returns false. The Streams Standard's "read all bytes" accepts only a
// Uint8Array; the other buffer types are accepted too, so a stream of ArrayBuffers or DataViews still reads as bytes.
// The span borrows the chunk's storage until script runs.
bool readableStreamChunkBytes(
    JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue chunk, std::span<const uint8_t>& out);
// The TypeError message readableStreamChunkBytes throws for a chunk that is no buffer, which a reader that cancels
// the stream over such a chunk gives its cancel reason too.
inline constexpr WTF::ASCIILiteral readable_stream_chunk_type_message
    = "ReadableStream chunks must be an ArrayBuffer or an ArrayBufferView"_s;

// Installs every stream class of this directory on the realm. It runs before any installer that builds on streams,
// such as the text codec streams' (globals.def keeps that order).
void installWebApiReadableStream(Collo::GlobalObject*, JSC::VM&);

} // namespace Collo::HostFunctions

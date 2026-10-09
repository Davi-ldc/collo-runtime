// The body of a Request or Response. BodyState is plain native data that any code may build, move and destroy;
// JSColloBodyOwner, the base of both cells, pairs it with the one traced edge to the body's stream. body.cpp holds the
// state, cloning and the owner, body_consume.cpp the Body mixin's consumers, body_init.cpp the extraction of a
// BodyInit, and body_utils.h the byte helpers they share. Everything runs on the VM thread.
//
// A FetchStream body owns one reference to a fetch response body that Zig holds, named by its ColloFetchBodyIdentity.
// Moving the state moves the reference. Destroying or overwriting the state, or canceling its stream, releases it
// through fetchBodyReleaseForIdentity, and transferFetchStreamForHostResponse hands it to the caller. A RequestLazy
// body names the request whose body Zig still holds and owns nothing. A body is used once a consumer, a stream read
// or a transfer has taken it, or once its stream is disturbed, and a used body can be neither consumed nor cloned.

#pragma once

#include "host_functions/support.h"
#include "host_functions/webapi/files/blob.h"
#include "host_functions/webapi/streams/shared_bytes.h"

#include <JavaScriptCore/JSDestructibleObject.h>
#include <JavaScriptCore/SlotVisitorMacros.h>
#include <JavaScriptCore/WriteBarrier.h>
#include <wtf/ForbidHeapAllocation.h>
#include <wtf/Ref.h>
#include <wtf/RefCounted.h>
#include <wtf/RefPtr.h>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

#include <span>

namespace Collo::HostFunctions {

class JSColloBodyOwner;
struct PendingBody;

// The clone count of one streaming body's clone tree. Every BodyState in the tree holds the same budget, so
// WebApiBodyCloneFanoutMax bounds the clones of the whole tree, and a branch's own clones count against that total.
class BodyCloneBudget final : public WTF::RefCounted<BodyCloneBudget> {
public:
    static WTF::RefPtr<BodyCloneBudget> create()
    {
        void* storage = nullptr;
        if (!WTF::tryFastMalloc(sizeof(BodyCloneBudget)).getValue(storage))
            return nullptr;
        auto* budget = new (NotNull, storage) BodyCloneBudget;
        return WTF::adoptRef(*budget);
    }

    unsigned clone_count { 0 };

private:
    BodyCloneBudget() = default;
};

// The native state of a Request or Response body. It holds no GC field, so it is built, moved and assigned anywhere
// without a write barrier: the stream a body reads from lives in the owning cell's traced edge (JSColloBodyOwner).
// The methods that need that stream are private and reached through the owner, which passes its own edge.
class BodyState {
public:
    BodyState() = default;
    ~BodyState();

    BodyState(const BodyState&) = delete;
    BodyState& operator=(const BodyState&) = delete;
    BodyState(BodyState&& other) noexcept;
    BodyState& operator=(BodyState&& other) noexcept;

    enum class Source : uint8_t {
        Empty,
        Text,
        Bytes,
        SharedBytes,
        RequestLazy,
        FetchStream,
        ReadableStream,
    };

    // fromBytes takes the vector and returns false, leaving `out` untouched, when allocation fails. fromSharedBytes
    // views `size` bytes at `offset`, a range that must lie within the storage. fetchStream takes over the caller's
    // reference to the fetch body.
    static BodyState empty();
    static BodyState fromText(WTF::String);
    static bool fromBytes(WTF::Vector<uint8_t>&&, BodyState& out);
    static BodyState fromSharedBytes(WTF::Ref<BlobStorage>&&, size_t offset, size_t size);
    static BodyState requestLazy(ColloRequestIdentity);
    static BodyState fetchStream(ColloVm&, ColloFetchBodyIdentity);

    Source source() const { return m_source; }
    const WTF::String& text() const { return m_text; }
    // byteLength, appendBytes and copyBytesInto, like extractByteSegmentsForHostResponse, neither check nor set the
    // used flag. Empty, Text, Bytes and SharedBytes bodies answer synchronously. A fetch stream answers byteLength and
    // appendBytes during its own request turn once Zig holds its whole body; every other case throws a TypeError.
    // Measuring or copying a text body, and appending a non-empty body's bytes, can also throw an OutOfMemoryError.
    bool byteLength(JSC::JSGlobalObject*, JSC::ThrowScope&, size_t& out) const;
    bool appendBytes(JSC::JSGlobalObject*, JSC::ThrowScope&, WTF::Vector<uint8_t>& out) const;
    // Throws a TypeError when `out` differs from the body's length, so size it with byteLength.
    bool copyBytesInto(JSC::JSGlobalObject*, JSC::ThrowScope&, std::span<uint8_t> out) const;
    // Publishes the body's bytes in `out` for Zig. `byte_length` must be what byteLength returned. Every segment
    // points into memory that out.owner keeps alive. A SharedBytes body publishes up to `max_segments` views of its
    // storage, and is copied into one segment when it has more or when `max_segments` is zero. On failure it throws,
    // a TypeError when the bytes are not synchronously available and otherwise an OutOfMemoryError, and resets `out`.
    bool extractByteSegmentsForHostResponse(JSC::JSGlobalObject*, JSC::ThrowScope&, size_t byte_length,
        size_t max_segments, ColloExtractedResponseBody& out) const;
    // Both mark the body used, then take its bytes: consumeToBytes appends them to `out`, and consumeToSharedBytes
    // returns them as one buffer, handing a Bytes body's buffer over without a copy. An empty body yields no bytes,
    // and the used flag is neither checked nor set for it. Any other used body throws `already_used_message` as a
    // TypeError. Bytes that are not synchronously available throw a TypeError and leave the body used, and
    // consumeToSharedBytes treats every fetch stream so.
    bool consumeToBytes(
        JSC::JSGlobalObject*, JSC::ThrowScope&, WTF::ASCIILiteral already_used_message, WTF::Vector<uint8_t>& out);
    bool consumeToSharedBytes(JSC::JSGlobalObject*, JSC::ThrowScope&, WTF::ASCIILiteral already_used_message,
        WTF::RefPtr<ColloSharedBytes>& out);
    // Called by the source of the stream `body` created for a native body; a stream body's stream is the user's own
    // and never reaches these. Both mark a non-empty body used and streaming, so later calls from that stream succeed,
    // while a body a consumer already used throws `already_used_message` as a TypeError. cancelStream also cancels a
    // fetch stream and releases its reference.
    bool beginStreamRead(JSC::JSGlobalObject*, JSC::ThrowScope&, WTF::ASCIILiteral already_used_message);
    bool cancelStream(JSC::JSGlobalObject*, JSC::ThrowScope&, WTF::ASCIILiteral already_used_message);
    const ColloRequestIdentity& requestIdentity() const { return m_identity; }
    const ColloFetchBodyIdentity& fetchBodyIdentity() const { return m_fetch_body_identity; }
    // True for an unused fetch stream, which transferFetchStreamForHostResponse then hands to the caller together
    // with its reference, leaving the body empty and used. False without an exception for any other source, and
    // false after throwing `already_used_message` as a TypeError for a used fetch stream.
    bool canTransferFetchStreamForHostResponse(
        JSC::JSGlobalObject*, JSC::ThrowScope&, WTF::ASCIILiteral already_used_message) const;
    ColloFetchBodyIdentity transferFetchStreamForHostResponse();

private:
    friend class JSColloBodyOwner;
    friend struct PendingBody;

    // A stream body's state: its bytes come from the owner's body stream, so only PendingBody::fromStream builds it,
    // beside its stream.
    static BodyState readableStream();

    // In the methods below, `stream` is the owner's body stream, or null when the owner has none.
    bool bodyUsed(JSC::JSObject* stream) const;
    // A Text, Bytes or SharedBytes clone shares the body's storage. Cloning a stream body tees it: the clone reads one
    // branch, and `out_kept_stream` receives the other, which replaces the owner's stream. A lazy request body cannot
    // be cloned and throws a TypeError.
    bool clone(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSObject* stream, WTF::ASCIILiteral already_used_message,
        JSC::JSObject*& out_kept_stream, PendingBody& out);
    JSC::EncodedJSValue consumeText(
        JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSObject* stream, WTF::ASCIILiteral already_used_message);
    JSC::EncodedJSValue consumeJson(
        JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSObject* stream, WTF::ASCIILiteral already_used_message);
    JSC::EncodedJSValue consumeArrayBuffer(
        JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSObject* stream, WTF::ASCIILiteral already_used_message);
    JSC::EncodedJSValue consumeBytes(
        JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSObject* stream, WTF::ASCIILiteral already_used_message);
    JSC::EncodedJSValue consumeBlob(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSObject* stream,
        WTF::ASCIILiteral already_used_message, WTF::String type);
    JSC::EncodedJSValue consumeFormData(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSObject* stream,
        WTF::ASCIILiteral already_used_message, WTF::String content_type);
    // Marks an unused body used. For a used body it stores a promise rejected with `already_used_message` as a
    // TypeError in `out_rejection` and returns false without throwing.
    bool markUsed(JSC::JSGlobalObject*, JSC::JSObject* stream, WTF::ASCIILiteral already_used_message,
        JSC::EncodedJSValue& out_rejection);

    bool appendSharedBytes(JSC::JSGlobalObject*, JSC::ThrowScope&, WTF::Vector<uint8_t>& out) const;
    bool consumeCloneBudget(JSC::JSGlobalObject*, JSC::ThrowScope&);
    void releaseFetchStream();

    Source m_source { Source::Empty };
    WTF::String m_text;
    WTF::RefPtr<ColloSharedBytes> m_bytes;
    WTF::RefPtr<BlobStorage> m_shared_storage;
    size_t m_shared_offset { 0 };
    size_t m_shared_size { 0 };
    ColloRequestIdentity m_identity {};
    ColloFetchBodyIdentity m_fetch_body_identity {};
    ColloVm* m_fetch_body_owner { nullptr };
    WTF::RefPtr<BodyCloneBudget> m_clone_budget;
    bool m_used { false };
    bool m_streaming { false };
};

// A body on its way into a new Request or Response: the native state and, for a stream body, the stream. It lives on
// the stack, whose conservative scan keeps the stream alive until the new cell's finishCreation stores it in the
// cell's traced edge, so every type that embeds it forbids heap allocation too.
struct PendingBody {
    WTF_FORBID_HEAP_ALLOCATION;

public:
    // A body read from `stream`, which must not be null.
    static PendingBody fromStream(JSC::JSObject* stream);

    BodyState state;
    JSC::JSObject* stream { nullptr };
};

// `content_type` is the type a Blob or FormData body implies, and empty for every other body.
struct BodyInitResult {
    WTF_FORBID_HEAP_ALLOCATION;

public:
    PendingBody body;
    WTF::String content_type;
};

// Extracts `body_value`, a BodyInit, into `out`; undefined and null leave an empty body. Returns false after
// throwing a TypeError for a buffer source that is detached, out of bounds or of changeable length, a
// QuotaExceededError DOMException for a body held whole above WebApiMaterializedBodyBytesMax, an OutOfMemoryError,
// or what serializing a FormData or converting the value to a string throws.
bool createBodyStateFromJS(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue body_value, BodyInitResult& out);

// The base of the Request and Response cells: the body's native state and the one traced edge to the body's stream.
// The edge holds the stream a stream body was built from (or the tee branch it kept after a clone), or, for a native
// body, the stream `body` created on first access, so `body` returns the same object, with its lock, for the cell's
// whole life. That stream may reach back to the cell (a native body's source reads through it, a user source can
// close over it); the cycle is traced, so the collector reclaims it. Only this class writes the edge, and always
// through the barrier, because the cell may already be old when the stream is new.
class JSColloBodyOwner : public JSC::JSDestructibleObject {
    using Base = JSC::JSDestructibleObject;

public:
    DECLARE_VISIT_CHILDREN;

    BodyState& body() { return m_body; }
    const BodyState& body() const { return m_body; }
    JSC::JSObject* bodyStream() const { return m_body_stream.get(); }
    // Stores the stream `body` created for a native body; the cell has none yet.
    void setBodyStream(JSC::VM&, JSC::JSObject*);
    bool bodyUsed() const;

    // Each calls the matching BodyState method, clone for cloneBody, with this cell's stream; cloneBody also stores
    // the tee branch a stream body keeps.
    bool cloneBody(JSC::JSGlobalObject*, JSC::ThrowScope&, WTF::ASCIILiteral already_used_message, PendingBody& out);
    JSC::EncodedJSValue consumeText(JSC::JSGlobalObject*, JSC::ThrowScope&, WTF::ASCIILiteral already_used_message);
    JSC::EncodedJSValue consumeJson(JSC::JSGlobalObject*, JSC::ThrowScope&, WTF::ASCIILiteral already_used_message);
    JSC::EncodedJSValue consumeArrayBuffer(
        JSC::JSGlobalObject*, JSC::ThrowScope&, WTF::ASCIILiteral already_used_message);
    JSC::EncodedJSValue consumeBytes(JSC::JSGlobalObject*, JSC::ThrowScope&, WTF::ASCIILiteral already_used_message);
    JSC::EncodedJSValue consumeBlob(
        JSC::JSGlobalObject*, JSC::ThrowScope&, WTF::ASCIILiteral already_used_message, WTF::String type);
    JSC::EncodedJSValue consumeFormData(
        JSC::JSGlobalObject*, JSC::ThrowScope&, WTF::ASCIILiteral already_used_message, WTF::String content_type);

protected:
    JSColloBodyOwner(JSC::VM&, JSC::Structure*, BodyState&&);
    ~JSColloBodyOwner() = default;

    // `body_stream` is the PendingBody's stream: required for a stream body, null for any other.
    void finishCreation(JSC::VM&, JSC::JSObject* body_stream);

private:
    BodyState m_body;
    JSC::WriteBarrier<JSC::JSObject> m_body_stream;
};

} // namespace Collo::HostFunctions

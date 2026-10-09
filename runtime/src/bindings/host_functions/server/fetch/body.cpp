// BodyState and JSColloBodyOwner from body.h, except the consumers (body_consume.cpp) and BodyInit extraction
// (body_init.cpp). Runs on the VM thread. A fetch body reference leaves a state only through releaseFetchStream,
// which releases it and empties the state, or through a move or transferFetchStreamForHostResponse, which hand it on
// and empty the source, so no path releases a reference twice or drops one unreleased.

#include "host_functions/server/fetch/body.h"
#include "host_functions/server/fetch/body_utils.h"
#include "host_functions/server/fetch/extracted_response.h"
#include "host_functions/runtime/fetch_body.h"
#include "host_functions/runtime/request_body.h"
#include "host_functions/webapi/dom/dom_exception.h"
#include "host_functions/webapi/limits.h"
#include "host_functions/webapi/buffer_source.h"
#include "host_functions/webapi/files/blob.h"
#include "host_functions/webapi/files/formdata.h"
#include "host_functions/webapi/streams/readable_stream.h"
#include "host_functions/webapi/streams/readable_stream_private.h"

#include <JavaScriptCore/ArrayBufferSharingMode.h>
#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/JSArrayBuffer.h>
#include <JavaScriptCore/JSArrayBufferView.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSGenericTypedArrayViewInlines.h>
#include <JavaScriptCore/JSNativeStdFunction.h>
#include <JavaScriptCore/JSONObject.h>
#include <JavaScriptCore/JSString.h>
#include <JavaScriptCore/JSTypedArrays.h>
#include <wtf/Vector.h>
#include <wtf/text/StringBuilder.h>

#include <cstring>
#include <limits>
#include <new>
#include <span>

namespace Collo::HostFunctions {

BodyState::~BodyState() { releaseFetchStream(); }

void BodyState::releaseFetchStream()
{
    if (m_source != Source::FetchStream)
        return;
    if (m_fetch_body_owner)
        fetchBodyReleaseForIdentity(*m_fetch_body_owner, m_fetch_body_identity);
    m_source = Source::Empty;
    m_fetch_body_identity = {};
    m_fetch_body_owner = nullptr;
}

BodyState::BodyState(BodyState&& other) noexcept
    : m_source(other.m_source)
    , m_text(WTF::move(other.m_text))
    , m_bytes(WTF::move(other.m_bytes))
    , m_shared_storage(WTF::move(other.m_shared_storage))
    , m_shared_offset(other.m_shared_offset)
    , m_shared_size(other.m_shared_size)
    , m_identity(other.m_identity)
    , m_fetch_body_identity(other.m_fetch_body_identity)
    , m_fetch_body_owner(other.m_fetch_body_owner)
    , m_clone_budget(WTF::move(other.m_clone_budget))
    , m_used(other.m_used)
    , m_streaming(other.m_streaming)
{
    other.m_source = Source::Empty;
    other.m_fetch_body_identity = {};
    other.m_fetch_body_owner = nullptr;
    other.m_used = false;
    other.m_streaming = false;
}

BodyState& BodyState::operator=(BodyState&& other) noexcept
{
    if (this == &other)
        return *this;

    releaseFetchStream();
    m_source = other.m_source;
    m_text = WTF::move(other.m_text);
    m_bytes = WTF::move(other.m_bytes);
    m_shared_storage = WTF::move(other.m_shared_storage);
    m_shared_offset = other.m_shared_offset;
    m_shared_size = other.m_shared_size;
    m_identity = other.m_identity;
    m_fetch_body_identity = other.m_fetch_body_identity;
    m_fetch_body_owner = other.m_fetch_body_owner;
    m_clone_budget = WTF::move(other.m_clone_budget);
    m_used = other.m_used;
    m_streaming = other.m_streaming;

    other.m_source = Source::Empty;
    other.m_fetch_body_identity = {};
    other.m_fetch_body_owner = nullptr;
    other.m_used = false;
    other.m_streaming = false;
    return *this;
}

BodyState BodyState::empty() { return BodyState {}; }

BodyState BodyState::fromText(WTF::String text)
{
    BodyState body;
    body.m_source = Source::Text;
    body.m_text = WTF::move(text);
    return body;
}

bool BodyState::fromBytes(WTF::Vector<uint8_t>&& bytes, BodyState& out)
{
    auto storage = ColloSharedBytes::create(WTF::move(bytes));
    if (!storage)
        return false;
    out = BodyState {};
    out.m_source = Source::Bytes;
    out.m_bytes = storage.releaseNonNull();
    return true;
}

BodyState BodyState::fromSharedBytes(WTF::Ref<BlobStorage>&& storage, size_t offset, size_t size)
{
    ASSERT(offset <= storage->size());
    ASSERT(size <= storage->size() - offset);
    BodyState body;
    body.m_source = Source::SharedBytes;
    body.m_shared_storage = WTF::move(storage);
    body.m_shared_offset = offset;
    body.m_shared_size = size;
    return body;
}

BodyState BodyState::requestLazy(ColloRequestIdentity identity)
{
    BodyState body;
    body.m_source = Source::RequestLazy;
    body.m_identity = identity;
    return body;
}

BodyState BodyState::fetchStream(ColloVm& owner, ColloFetchBodyIdentity identity)
{
    BodyState body;
    body.m_source = Source::FetchStream;
    body.m_fetch_body_identity = identity;
    body.m_fetch_body_owner = &owner;
    return body;
}

BodyState BodyState::readableStream()
{
    BodyState body;
    body.m_source = Source::ReadableStream;
    return body;
}

PendingBody PendingBody::fromStream(JSC::JSObject* stream)
{
    ASSERT(stream);
    PendingBody body;
    body.state = BodyState::readableStream();
    body.stream = stream;
    return body;
}

// Fetch defines bodyUsed by the body's stream being disturbed, so a disturbed stream, whether the body's own or the
// one `body` created for a native body, makes the body used.
bool BodyState::bodyUsed(JSC::JSObject* stream) const
{
    return m_used || (stream && readableStreamIsDisturbed(stream));
}

bool BodyState::appendSharedBytes(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, WTF::Vector<uint8_t>& out) const
{
    if (m_shared_storage && m_shared_storage->appendTo(out, m_shared_offset, m_shared_size))
        return true;
    JSC::throwOutOfMemoryError(global_object, scope);
    return false;
}

bool BodyState::byteLength(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, size_t& out) const
{
    out = 0;
    switch (m_source) {
    case Source::Empty:
        return true;
    case Source::Text:
        if (stringUtf8ByteLength(m_text, out))
            return true;
        JSC::throwOutOfMemoryError(global_object, scope);
        return false;
    case Source::Bytes:
        out = m_bytes ? m_bytes->size() : 0;
        return true;
    case Source::SharedBytes:
        out = m_shared_size;
        return true;
    case Source::RequestLazy:
        JSC::throwVMTypeError(global_object, scope, "lazy request body bytes are not synchronously available"_s);
        return false;
    case Source::FetchStream:
        return fetchBodyByteLengthForIdentity(global_object, scope, m_fetch_body_identity, out);
    case Source::ReadableStream:
        JSC::throwVMTypeError(global_object, scope, "ReadableStream body bytes are not synchronously available"_s);
        return false;
    }
    return true;
}

bool BodyState::appendBytes(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, WTF::Vector<uint8_t>& out) const
{
    switch (m_source) {
    case Source::Empty:
        return true;
    case Source::Text:
        return appendStringBytes(global_object, scope, out, m_text);
    case Source::Bytes:
        return copyBytes(global_object, scope, out, sharedBytesSpan(m_bytes));
    case Source::SharedBytes:
        return appendSharedBytes(global_object, scope, out);
    case Source::RequestLazy:
        JSC::throwVMTypeError(global_object, scope, "lazy request body bytes are not synchronously available"_s);
        return false;
    case Source::FetchStream:
        return fetchBodyAppendBytesForIdentity(global_object, scope, m_fetch_body_identity, out);
    case Source::ReadableStream:
        JSC::throwVMTypeError(global_object, scope, "ReadableStream body bytes are not synchronously available"_s);
        return false;
    }
    return true;
}

bool BodyState::copyBytesInto(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, std::span<uint8_t> out) const
{
    auto failLengthMismatch = [&]() {
        JSC::throwVMTypeError(global_object, scope, "Body byte length changed during extraction"_s);
        return false;
    };

    switch (m_source) {
    case Source::Empty:
        if (out.empty())
            return true;
        return failLengthMismatch();
    case Source::Text: {
        bool size_matched = true;
        auto result = m_text.tryGetUTF8([&](std::span<const char8_t> utf8) -> bool {
            if (utf8.size() != out.size()) {
                size_matched = false;
                return false;
            }
            if (!utf8.empty())
                std::memcpy(out.data(), utf8.data(), utf8.size());
            return true;
        });
        if (result && result.value())
            return true;
        if (!size_matched)
            return failLengthMismatch();
        JSC::throwOutOfMemoryError(global_object, scope);
        return false;
    }
    case Source::Bytes: {
        auto bytes = sharedBytesSpan(m_bytes);
        if (bytes.size() != out.size())
            return failLengthMismatch();
        if (!bytes.empty())
            std::memcpy(out.data(), bytes.data(), bytes.size());
        return true;
    }
    case Source::SharedBytes:
        if (m_shared_size != out.size())
            return failLengthMismatch();
        if (m_shared_size)
            m_shared_storage->copyTo(out, m_shared_offset, m_shared_size);
        return true;
    case Source::RequestLazy:
        JSC::throwVMTypeError(global_object, scope, "lazy request body bytes are not synchronously available"_s);
        return false;
    case Source::FetchStream:
        JSC::throwVMTypeError(global_object, scope, "fetch stream body bytes are not synchronously available"_s);
        return false;
    case Source::ReadableStream:
        JSC::throwVMTypeError(global_object, scope, "ReadableStream body bytes are not synchronously available"_s);
        return false;
    }
    return true;
}

bool BodyState::extractByteSegmentsForHostResponse(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    size_t byte_length, size_t max_segments, ColloExtractedResponseBody& out) const
{
    resetExtractedResponseBody(out);
    if (byte_length == 0)
        return true;

    auto* owner = new (std::nothrow) ColloOwnedByteSegments;
    if (!owner) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return false;
    }

    auto fail = [&]() {
        delete owner;
        resetExtractedResponseBody(out);
        return false;
    };

    switch (m_source) {
    case Source::Empty:
        return fail();
    case Source::Text:
        if (!owner->owned_bytes.tryReserveInitialCapacity(byte_length)) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return fail();
        }
        if (!appendStringBytes(global_object, scope, owner->owned_bytes, m_text))
            return fail();
        if (owner->owned_bytes.size() != byte_length) {
            JSC::throwVMTypeError(global_object, scope, "Body byte length changed during extraction"_s);
            return fail();
        }
        if (!publishOwnedByteSegment(*owner, out, owner->owned_bytes.span())) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return fail();
        }
        return true;
    case Source::Bytes: {
        auto bytes = sharedBytesSpan(m_bytes);
        if (bytes.size() != byte_length) {
            JSC::throwVMTypeError(global_object, scope, "Body byte length changed during extraction"_s);
            return fail();
        }
        if (!owner->shared_bytes.tryAppend(m_bytes)) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return fail();
        }
        if (!publishOwnedByteSegment(*owner, out, bytes)) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return fail();
        }
        return true;
    }
    case Source::SharedBytes:
        // appendSegmentsTo stops at `max_segments`, so storage fragmented past the cap never builds the oversized
        // segment vector. When it stops there, or cannot allocate, the partial vector is dropped and the bytes are
        // copied into one owned segment below.
        if (max_segments > 0
            && m_shared_storage->appendSegmentsTo(owner->blob_segments, m_shared_offset, byte_length, max_segments)) {
            if (!publishBlobSegments(*owner, out, byte_length)) {
                JSC::throwOutOfMemoryError(global_object, scope);
                return fail();
            }
            return true;
        }
        owner->blob_segments.clear();
        if (!owner->owned_bytes.tryReserveInitialCapacity(byte_length)) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return fail();
        }
        owner->owned_bytes.grow(byte_length);
        m_shared_storage->copyTo(owner->owned_bytes.mutableSpan(), m_shared_offset, byte_length);
        if (!publishOwnedByteSegment(*owner, out, owner->owned_bytes.span())) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return fail();
        }
        return true;
    case Source::RequestLazy:
        JSC::throwVMTypeError(global_object, scope, "lazy request body bytes are not synchronously available"_s);
        return fail();
    case Source::FetchStream:
        JSC::throwVMTypeError(global_object, scope, "fetch stream body bytes are not synchronously available"_s);
        return fail();
    case Source::ReadableStream:
        JSC::throwVMTypeError(global_object, scope, "ReadableStream body bytes are not synchronously available"_s);
        return fail();
    }
    return fail();
}

bool BodyState::consumeToBytes(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    WTF::ASCIILiteral already_used_message, WTF::Vector<uint8_t>& out)
{
    if (m_source == Source::Empty)
        return true;

    if (m_used) {
        throwAlreadyUsedTypeError(global_object, scope, already_used_message);
        return false;
    }
    m_used = true;

    return appendBytes(global_object, scope, out);
}

bool BodyState::consumeToSharedBytes(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    WTF::ASCIILiteral already_used_message, WTF::RefPtr<ColloSharedBytes>& out)
{
    out = nullptr;
    if (m_source == Source::Empty)
        return true;

    if (m_used) {
        throwAlreadyUsedTypeError(global_object, scope, already_used_message);
        return false;
    }
    m_used = true;

    switch (m_source) {
    case Source::Empty:
        return true;
    case Source::Text: {
        WTF::Vector<uint8_t> bytes;
        if (!appendStringBytes(global_object, scope, bytes, m_text))
            return false;
        RETURN_IF_EXCEPTION(scope, false);
        out = ColloSharedBytes::create(WTF::move(bytes));
        if (!out) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return false;
        }
        return true;
    }
    case Source::Bytes:
        out = m_bytes;
        m_bytes = nullptr;
        return true;
    case Source::SharedBytes: {
        WTF::Vector<uint8_t> bytes;
        if (!appendSharedBytes(global_object, scope, bytes))
            return false;
        RETURN_IF_EXCEPTION(scope, false);
        out = ColloSharedBytes::create(WTF::move(bytes));
        if (!out) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return false;
        }
        return true;
    }
    case Source::RequestLazy:
        JSC::throwVMTypeError(global_object, scope, "lazy request body bytes are not synchronously available"_s);
        return false;
    case Source::FetchStream:
        JSC::throwVMTypeError(global_object, scope, "fetch stream body bytes are not synchronously available"_s);
        return false;
    case Source::ReadableStream:
        JSC::throwVMTypeError(global_object, scope, "ReadableStream body bytes are not synchronously available"_s);
        return false;
    }
    return false;
}

bool BodyState::beginStreamRead(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, WTF::ASCIILiteral already_used_message)
{
    if (m_source == Source::Empty)
        return true;
    if (m_used && !m_streaming) {
        throwAlreadyUsedTypeError(global_object, scope, already_used_message);
        return false;
    }
    m_used = true;
    m_streaming = true;
    return true;
}

bool BodyState::cancelStream(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, WTF::ASCIILiteral already_used_message)
{
    if (m_source == Source::Empty)
        return true;
    if (m_used && !m_streaming) {
        throwAlreadyUsedTypeError(global_object, scope, already_used_message);
        return false;
    }
    m_used = true;
    m_streaming = true;
    if (m_source == Source::FetchStream) {
        fetchBodyCancelForIdentity(global_object, m_fetch_body_identity);
        releaseFetchStream();
    }
    return true;
}

bool BodyState::canTransferFetchStreamForHostResponse(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, WTF::ASCIILiteral already_used_message) const
{
    if (m_source != Source::FetchStream)
        return false;
    if (!m_used)
        return true;
    throwAlreadyUsedTypeError(global_object, scope, already_used_message);
    return false;
}

ColloFetchBodyIdentity BodyState::transferFetchStreamForHostResponse()
{
    ASSERT(m_source == Source::FetchStream);
    ASSERT(!m_used);
    ColloFetchBodyIdentity identity = m_fetch_body_identity;
    m_source = Source::Empty;
    m_fetch_body_identity = {};
    m_fetch_body_owner = nullptr;
    m_used = true;
    m_streaming = true;
    return identity;
}

bool BodyState::markUsed(JSC::JSGlobalObject* global_object, JSC::JSObject* stream,
    WTF::ASCIILiteral already_used_message, JSC::EncodedJSValue& out_rejection)
{
    if (!bodyUsed(stream)) {
        m_used = true;
        return true;
    }
    out_rejection = rejectedAlreadyUsedTypeError(global_object, already_used_message);
    return false;
}

// Counts one clone against the clone tree's budget, creating the budget at the tree's first clone, and throws a
// QuotaExceededError DOMException once the tree has made WebApiBodyCloneFanoutMax clones. Only streaming sources call
// it, because each branch buffers on its own; a Text, Bytes or SharedBytes clone takes one more reference to the
// same storage.
bool BodyState::consumeCloneBudget(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
{
    if (!m_clone_budget) {
        m_clone_budget = BodyCloneBudget::create();
        if (!m_clone_budget) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return false;
        }
    }
    if (m_clone_budget->clone_count >= WebApiBodyCloneFanoutMax) {
        auto* exception = createDOMException(global_object, DOMExceptionCode::QuotaExceededError,
            "body clone count exceeds the serverless clone limit"_s);
        JSC::throwException(global_object, scope, exception);
        return false;
    }
    m_clone_budget->clone_count++;
    return true;
}

bool BodyState::clone(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSObject* stream,
    WTF::ASCIILiteral already_used_message, JSC::JSObject*& out_kept_stream, PendingBody& out)
{
    out_kept_stream = nullptr;
    if (bodyUsed(stream)) {
        throwAlreadyUsedTypeError(global_object, scope, already_used_message);
        return false;
    }

    switch (m_source) {
    case Source::Empty:
        out.state = BodyState::empty();
        return true;
    case Source::Text:
        out.state = BodyState::fromText(m_text);
        return true;
    case Source::Bytes: {
        out.state = BodyState {};
        out.state.m_source = Source::Bytes;
        out.state.m_bytes = m_bytes;
        return true;
    }
    case Source::SharedBytes:
        out.state
            = BodyState::fromSharedBytes(WTF::Ref<BlobStorage> { *m_shared_storage }, m_shared_offset, m_shared_size);
        return true;
    case Source::RequestLazy:
        JSC::throwVMTypeError(global_object, scope, "lazy request bodies cannot be cloned yet"_s);
        return false;
    case Source::FetchStream: {
        if (!consumeCloneBudget(global_object, scope))
            return false;
        ColloFetchBodyIdentity cloned_identity {};
        if (!fetchBodyCloneForIdentity(global_object, scope, m_fetch_body_identity, cloned_identity))
            return false;
        out.state
            = BodyState::fetchStream(uncheckedDowncast<Collo::GlobalObject>(global_object)->owner(), cloned_identity);
        out.state.m_clone_budget = m_clone_budget;
        return true;
    }
    case Source::ReadableStream: {
        if (!stream) {
            throwAlreadyUsedTypeError(global_object, scope, already_used_message);
            return false;
        }
        if (!consumeCloneBudget(global_object, scope))
            return false;

        auto tee = stream->get(global_object, JSC::Identifier::fromString(global_object->vm(), "tee"_s));
        RETURN_IF_EXCEPTION(scope, false);
        if (!bodyValueIsCallable(tee)) {
            JSC::throwVMTypeError(global_object, scope, "ReadableStream body cannot be cloned"_s);
            return false;
        }
        JSC::MarkedArgumentBuffer arguments;
        if (arguments.hasOverflowed()) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return false;
        }
        auto call_data = JSC::getCallData(tee);
        auto branches_value = JSC::call(global_object, tee.getObject(), call_data, stream, arguments);
        RETURN_IF_EXCEPTION(scope, false);
        auto* branches = dynamicDowncast<JSC::JSObject>(branches_value);
        if (!branches) {
            JSC::throwVMTypeError(global_object, scope, "ReadableStream tee returned invalid branches"_s);
            return false;
        }

        auto branch_a = branches->get(global_object, static_cast<unsigned>(0));
        RETURN_IF_EXCEPTION(scope, false);
        auto branch_b = branches->get(global_object, static_cast<unsigned>(1));
        RETURN_IF_EXCEPTION(scope, false);
        auto* stream_a = readableStreamFromValue(branch_a);
        auto* stream_b = readableStreamFromValue(branch_b);
        if (!stream_a || !stream_b) {
            JSC::throwVMTypeError(global_object, scope, "ReadableStream tee returned invalid branches"_s);
            return false;
        }

        out_kept_stream = stream_a;
        out = PendingBody::fromStream(stream_b);
        out.state.m_clone_budget = m_clone_budget;
        return true;
    }
    }
    throwAlreadyUsedTypeError(global_object, scope, already_used_message);
    return false;
}

JSColloBodyOwner::JSColloBodyOwner(JSC::VM& vm, JSC::Structure* structure, BodyState&& body)
    : Base(vm, structure)
    , m_body(WTF::move(body))
{
}

void JSColloBodyOwner::finishCreation(JSC::VM& vm, JSC::JSObject* body_stream)
{
    Base::finishCreation(vm);
    ASSERT(m_body.source() != BodyState::Source::ReadableStream || body_stream);
    m_body_stream.setMayBeNull(vm, this, body_stream);
}

void JSColloBodyOwner::setBodyStream(JSC::VM& vm, JSC::JSObject* stream)
{
    ASSERT(!m_body_stream);
    m_body_stream.set(vm, this, stream);
}

bool JSColloBodyOwner::bodyUsed() const { return m_body.bodyUsed(bodyStream()); }

bool JSColloBodyOwner::cloneBody(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    WTF::ASCIILiteral already_used_message, PendingBody& out)
{
    JSC::JSObject* kept_stream = nullptr;
    if (!m_body.clone(global_object, scope, bodyStream(), already_used_message, kept_stream, out))
        return false;
    if (kept_stream)
        m_body_stream.set(global_object->vm(), this, kept_stream);
    return true;
}

JSC::EncodedJSValue JSColloBodyOwner::consumeText(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, WTF::ASCIILiteral already_used_message)
{
    return m_body.consumeText(global_object, scope, bodyStream(), already_used_message);
}

JSC::EncodedJSValue JSColloBodyOwner::consumeJson(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, WTF::ASCIILiteral already_used_message)
{
    return m_body.consumeJson(global_object, scope, bodyStream(), already_used_message);
}

JSC::EncodedJSValue JSColloBodyOwner::consumeArrayBuffer(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, WTF::ASCIILiteral already_used_message)
{
    return m_body.consumeArrayBuffer(global_object, scope, bodyStream(), already_used_message);
}

JSC::EncodedJSValue JSColloBodyOwner::consumeBytes(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, WTF::ASCIILiteral already_used_message)
{
    return m_body.consumeBytes(global_object, scope, bodyStream(), already_used_message);
}

JSC::EncodedJSValue JSColloBodyOwner::consumeBlob(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    WTF::ASCIILiteral already_used_message, WTF::String type)
{
    return m_body.consumeBlob(global_object, scope, bodyStream(), already_used_message, WTF::move(type));
}

JSC::EncodedJSValue JSColloBodyOwner::consumeFormData(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    WTF::ASCIILiteral already_used_message, WTF::String content_type)
{
    return m_body.consumeFormData(global_object, scope, bodyStream(), already_used_message, WTF::move(content_type));
}

// The marker reads m_body_stream, one word the mutator writes through the
// barrier, so it needs no cell lock.
template <typename Visitor> void JSColloBodyOwner::visitChildrenImpl(JSC::JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloBodyOwner*>(cell);
    Base::visitChildren(this_object, visitor);
    visitor.append(this_object->m_body_stream);
}

DEFINE_VISIT_CHILDREN(JSColloBodyOwner);

} // namespace Collo::HostFunctions

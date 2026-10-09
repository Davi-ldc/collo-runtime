// The native sources behind Response.body, with the read-result helpers and body-used messages response.cpp shares.
// Only response.cpp includes this file. Runs on the VM thread. A ResponseBodySource reads its Response's body through
// the cell, which it holds in a WriteBarrier that the owning stream visits. A FetchBodyIdentitySource owns one fetch
// body reference outright: a tee hands it to the first branch, and otherwise cancel, release() or destruction drops
// it exactly once.

#pragma once

#include "host_functions/runtime/fetch_body.h"
#include "host_functions/server/fetch/body.h"
#include "host_functions/server/fetch/body_utils.h"
#include "host_functions/server/fetch/response_object.h"
#include "host_functions/support.h"
#include "host_functions/webapi/streams/readable_stream_private.h"

#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSTypedArrays.h>
#include <wtf/FastMalloc.h>
#include <wtf/RefPtr.h>

#include <span>

namespace Collo::HostFunctions {

using JSC::EncodedJSValue;
using JSC::JSValue;

inline WTF::ASCIILiteral bodyAlreadyUsedMessage() { return "Body already used"_s; }

inline WTF::ASCIILiteral bodyStreamAlreadyUsedMessage() { return "body stream already used"_s; }

inline JSC::JSObject* createReadResultObject(JSC::JSGlobalObject* global_object, JSC::JSValue value, bool done)
{
    auto& vm = global_object->vm();
    auto* object = JSC::constructEmptyObject(global_object, global_object->objectPrototype(), 2);
    object->putDirect(vm, vm.propertyNames->value, value);
    object->putDirect(vm, vm.propertyNames->done, JSC::jsBoolean(done));
    return object;
}

inline JSC::EncodedJSValue resolvedReadResult(JSC::JSGlobalObject* global_object, JSC::JSValue value, bool done)
{
    return resolvedPromise(global_object, createReadResultObject(global_object, value, done));
}

inline JSC::EncodedJSValue resolvedDoneReadResult(JSC::JSGlobalObject* global_object)
{
    return resolvedReadResult(global_object, JSC::jsUndefined(), true);
}

// The source of each branch when the stream over a fetch-stream body is teed. It holds no cell, so it has nothing
// for the stream to visit.
class FetchBodyIdentitySource final : public ReadableStreamNativeSource {
public:
    static WTF::RefPtr<FetchBodyIdentitySource> create(ColloVm& owner, ColloFetchBodyIdentity identity)
    {
        void* storage = nullptr;
        if (!WTF::tryFastMalloc(sizeof(FetchBodyIdentitySource)).getValue(storage))
            return nullptr;
        auto* source = new (NotNull, storage) FetchBodyIdentitySource(owner, identity);
        return adoptRef(*source);
    }

    ~FetchBodyIdentitySource() override { release(); }

    EncodedJSValue pull(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope) override
    {
        if (m_released)
            return resolvedDoneReadResult(global_object);
        return fetchBodyPullForIdentity(global_object, scope, m_identity);
    }

    EncodedJSValue cancel(JSC::JSGlobalObject* global_object, JSC::ThrowScope&, JSValue) override
    {
        if (!m_released)
            fetchBodyCancelForIdentity(global_object, m_identity);
        release();
        return resolvedPromise(global_object, JSC::jsUndefined());
    }

    bool tee(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        WTF::RefPtr<ReadableStreamNativeSource>& out_first,
        WTF::RefPtr<ReadableStreamNativeSource>& out_second) override
    {
        if (m_released) {
            out_first = createReadableStreamNativeSourceFromBytes({});
            out_second = createReadableStreamNativeSourceFromBytes({});
            if (out_first && out_second)
                return true;
            JSC::throwOutOfMemoryError(global_object, scope);
            return false;
        }

        ColloFetchBodyIdentity cloned_identity {};
        if (!fetchBodyCloneForIdentity(global_object, scope, m_identity, cloned_identity))
            return false;
        RETURN_IF_EXCEPTION(scope, false);

        ColloFetchBodyIdentity original_identity = m_identity;
        m_identity = {};
        m_released = true;

        auto first = create(*m_owner, original_identity);
        if (!first) {
            fetchBodyReleaseForIdentity(*m_owner, original_identity);
            fetchBodyReleaseForIdentity(*m_owner, cloned_identity);
            JSC::throwOutOfMemoryError(global_object, scope);
            return false;
        }
        auto second = create(*m_owner, cloned_identity);
        if (!second) {
            fetchBodyReleaseForIdentity(*m_owner, cloned_identity);
            JSC::throwOutOfMemoryError(global_object, scope);
            return false;
        }
        out_first = first.releaseNonNull();
        out_second = second.releaseNonNull();
        return true;
    }

    void release() override
    {
        if (m_released)
            return;
        fetchBodyReleaseForIdentity(*m_owner, m_identity);
        m_identity = {};
        m_released = true;
    }

private:
    FetchBodyIdentitySource(ColloVm& owner, ColloFetchBodyIdentity identity)
        : m_owner(&owner)
        , m_identity(identity)
    {
    }

    ColloVm* m_owner { nullptr };
    ColloFetchBodyIdentity m_identity {};
    bool m_released { false };
};

// The source of the stream that `Response.body` returns. It reads the body through its Response, which the stream
// keeps alive by visiting this source, so a body being read survives user code dropping the Response. A fetch stream
// is pulled chunk by chunk, an empty body ends at once, and any other body is read as one chunk. A tee moves a fetch
// stream into two FetchBodyIdentitySources and takes any other non-empty body's bytes once for both branches to
// share; either way the Response's body ends up used.
class ResponseBodySource final : public ReadableStreamNativeSource {
public:
    static WTF::RefPtr<ResponseBodySource> create(JSColloResponse* response)
    {
        void* storage = nullptr;
        if (!WTF::tryFastMalloc(sizeof(ResponseBodySource)).getValue(storage))
            return nullptr;
        auto* source = new (NotNull, storage) ResponseBodySource(response);
        return adoptRef(*source);
    }

    EncodedJSValue pull(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope) override
    {
        auto* response = m_response.get();
        if (!response || response->body().source() == BodyState::Source::Empty)
            return resolvedDoneReadResult(global_object);

        if (response->body().source() == BodyState::Source::FetchStream) {
            if (!response->body().beginStreamRead(global_object, scope, bodyStreamAlreadyUsedMessage()))
                return {};
            RETURN_IF_EXCEPTION(scope, {});
            return fetchBodyPullForIdentity(global_object, scope, response->body().fetchBodyIdentity());
        }

        if (m_static_delivered)
            return resolvedDoneReadResult(global_object);

        WTF::RefPtr<ColloSharedBytes> bytes;
        if (!response->body().consumeToSharedBytes(global_object, scope, bodyStreamAlreadyUsedMessage(), bytes))
            return {};
        RETURN_IF_EXCEPTION(scope, {});
        m_static_delivered = true;
        auto* value
            = createBodyUint8ArrayCopy(global_object, scope, bytes ? bytes->span() : std::span<const uint8_t> {});
        RETURN_IF_EXCEPTION(scope, {});
        if (!value)
            return {};
        return resolvedReadResult(global_object, value, false);
    }

    EncodedJSValue cancel(JSC::JSGlobalObject* global_object, JSC::ThrowScope&, JSValue) override
    {
        auto* response = m_response.get();
        if (response) {
            auto scope = DECLARE_THROW_SCOPE(global_object->vm());
            if (!response->body().cancelStream(global_object, scope, bodyStreamAlreadyUsedMessage()))
                return rejectedTypeError(global_object, scope, bodyStreamAlreadyUsedMessage());
        }
        m_static_delivered = true;
        return resolvedPromise(global_object, JSC::jsUndefined());
    }

    bool tee(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        WTF::RefPtr<ReadableStreamNativeSource>& out_first,
        WTF::RefPtr<ReadableStreamNativeSource>& out_second) override
    {
        auto* response = m_response.get();
        if (!response || response->body().source() == BodyState::Source::Empty) {
            out_first = createReadableStreamNativeSourceFromBytes({});
            out_second = createReadableStreamNativeSourceFromBytes({});
            if (out_first && out_second)
                return true;
            JSC::throwOutOfMemoryError(global_object, scope);
            return false;
        }

        if (response->body().source() == BodyState::Source::FetchStream) {
            if (!response->body().canTransferFetchStreamForHostResponse(global_object, scope, bodyAlreadyUsedMessage()))
                return false;
            RETURN_IF_EXCEPTION(scope, false);

            const auto& identity = response->body().fetchBodyIdentity();
            ColloFetchBodyIdentity cloned_identity {};
            if (!fetchBodyCloneForIdentity(global_object, scope, identity, cloned_identity))
                return false;
            RETURN_IF_EXCEPTION(scope, false);

            ColloVm& owner = uncheckedDowncast<Collo::GlobalObject>(global_object)->owner();
            ColloFetchBodyIdentity original_identity = response->body().transferFetchStreamForHostResponse();
            auto first = FetchBodyIdentitySource::create(owner, original_identity);
            if (!first) {
                fetchBodyReleaseForIdentity(owner, original_identity);
                fetchBodyReleaseForIdentity(owner, cloned_identity);
                JSC::throwOutOfMemoryError(global_object, scope);
                return false;
            }
            auto second = FetchBodyIdentitySource::create(owner, cloned_identity);
            if (!second) {
                fetchBodyReleaseForIdentity(owner, cloned_identity);
                JSC::throwOutOfMemoryError(global_object, scope);
                return false;
            }
            out_first = first.releaseNonNull();
            out_second = second.releaseNonNull();
            return true;
        }

        if (m_static_delivered) {
            out_first = createReadableStreamNativeSourceFromBytes({});
            out_second = createReadableStreamNativeSourceFromBytes({});
            if (out_first && out_second)
                return true;
            JSC::throwOutOfMemoryError(global_object, scope);
            return false;
        }
        WTF::RefPtr<ColloSharedBytes> bytes;
        if (!response->body().consumeToSharedBytes(global_object, scope, bodyStreamAlreadyUsedMessage(), bytes))
            return false;
        RETURN_IF_EXCEPTION(scope, false);
        m_static_delivered = true;
        if (!bytes) {
            out_first = createReadableStreamNativeSourceFromBytes({});
            out_second = createReadableStreamNativeSourceFromBytes({});
        } else {
            out_first
                = createReadableStreamNativeSourceFromSharedBytes(WTF::Ref<ColloSharedBytes>(*bytes), 0, bytes->size());
            out_second
                = createReadableStreamNativeSourceFromSharedBytes(WTF::Ref<ColloSharedBytes>(*bytes), 0, bytes->size());
        }
        if (out_first && out_second)
            return true;
        JSC::throwOutOfMemoryError(global_object, scope);
        return false;
    }

    void release() override { m_response.clear(); }

    void visitAggregate(JSC::AbstractSlotVisitor& visitor) override { visitor.append(m_response); }
    void visitAggregate(JSC::SlotVisitor& visitor) override { visitor.append(m_response); }

private:
    // Until a stream adopts the source, the caller's stack roots the Response.
    explicit ResponseBodySource(JSColloResponse* response)
        : m_response(response, JSC::WriteBarrierEarlyInit)
    {
    }

    JSC::WriteBarrier<JSColloResponse> m_response;
    bool m_static_delivered { false };
};

} // namespace Collo::HostFunctions

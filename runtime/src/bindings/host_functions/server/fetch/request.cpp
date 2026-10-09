// The fetch API's Request, from both of its sources: the Request a handler receives, which collo_request_new builds
// from a dispatched request, and a Request that user code constructs or clones, which fetch() also builds before it
// sends one. Everything here runs on the VM thread.
//
// collo_request_new copies every string and array of its ColloRequestInit, so the caller's memory is borrowed only for
// the call. A dispatched request's body stays in the worker and is read lazily, by the request identity, through the
// request body functions of abi.h; a constructed one holds its body here. A Request's strings and options live in
// immutable RefCounted blocks that its clones share. The values a Request creates on first read (method, path, url,
// headers, params, query and signal) sit in WriteBarrier fields that visitChildren visits, and the stream of
// `Request.body` reads through a RequestBodySource that the stream visits, which keeps the Request alive while its
// body is read.

#include "host_functions/server/fetch/request.h"

#include "host_functions/runtime/fetch.h"
#include "host_functions/runtime/request_body.h"
#include "host_functions/server/fetch/body.h"
#include "host_functions/server/fetch/headers.h"
#include "host_functions/server/fetch/request_options.h"
#include "host_functions/webapi/dom/dom_exception.h"
#include "host_functions/webapi/events/abort.h"
#include "host_functions/webapi/events/event.h"
#include "host_functions/webapi/streams/readable_stream.h"
#include "host_functions/webapi/url/url.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/GetterSetter.h>
#include <JavaScriptCore/IdentifierInlines.h>
#include <JavaScriptCore/InternalFunction.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSDestructibleObject.h>
#include <JavaScriptCore/JSFunction.h>
#include <JavaScriptCore/JSGenericTypedArrayViewInlines.h>
#include <JavaScriptCore/JSNativeStdFunction.h>
#include <JavaScriptCore/JSObject.h>
#include <JavaScriptCore/JSPromise.h>
#include <JavaScriptCore/JSString.h>
#include <JavaScriptCore/JSTypedArrays.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <JavaScriptCore/SlotVisitorMacros.h>
#include <wtf/FastMalloc.h>
#include <wtf/Locker.h>
#include <wtf/RefCounted.h>
#include <wtf/StdLibExtras.h>
#include <wtf/URL.h>
#include <wtf/Vector.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/WTFString.h>

#include <algorithm>
#include <cstring>
#include <limits>
#include <span>

namespace Collo::HostFunctions {
namespace {

    using JSC::EncodedJSValue;
    using JSC::JSValue;
    using WTF::String;
    using namespace JSC;

    struct RequestSlice {
        size_t offset { 0 };
        size_t length { 0 };
    };

    struct RequestPair {
        RequestSlice name;
        RequestSlice value;
    };

    // Every slice indexes `storage`. A dispatched request has no `url`: its URL
    // is built from `authority`, `path` and `raw_query` on first read.
    struct RequestData {
        WTF::Vector<uint8_t> storage;
        RequestSlice url;
        RequestSlice method;
        RequestSlice path;
        RequestSlice raw_query;
        RequestSlice authority;
        WTF::Vector<RequestPair> headers;
        WTF::Vector<RequestPair> params;
        ColloRequestIdentity identity {};
    };

    class RequestDataStorage final : public WTF::RefCounted<RequestDataStorage> {
        WTF_MAKE_NONCOPYABLE(RequestDataStorage);

    public:
        static WTF::RefPtr<RequestDataStorage> tryCreate(RequestData&& data)
        {
            void* storage = nullptr;
            if (!WTF::tryFastMalloc(sizeof(RequestDataStorage)).getValue(storage))
                return nullptr;
            auto* data_storage = new (NotNull, storage) RequestDataStorage(WTF::move(data));
            return adoptRef(*data_storage);
        }

        const RequestData& data() const { return m_data; }

    private:
        explicit RequestDataStorage(RequestData&& data)
            : m_data(WTF::move(data))
        {
        }

        RequestData m_data;
    };

    using namespace FetchRequestInternal;

    class RequestOptionsStorage final : public WTF::RefCounted<RequestOptionsStorage> {
        WTF_MAKE_NONCOPYABLE(RequestOptionsStorage);

    public:
        static WTF::RefPtr<RequestOptionsStorage> tryCreate(RequestOptions&& options)
        {
            void* storage = nullptr;
            if (!WTF::tryFastMalloc(sizeof(RequestOptionsStorage)).getValue(storage))
                return nullptr;
            auto* options_storage = new (NotNull, storage) RequestOptionsStorage(WTF::move(options));
            return adoptRef(*options_storage);
        }

        const RequestOptions& options() const { return m_options; }

    private:
        explicit RequestOptionsStorage(RequestOptions&& options)
            : m_options(WTF::move(options))
        {
        }

        RequestOptions m_options;
    };

    static bool rawStringToWTF(ColloString raw, String& out)
    {
        return Collo::stringToWTFString(raw, out) == COLLO_STATUS_OK;
    }

    static ColloString rawSlice(const RequestData& data, RequestSlice slice)
    {
        return {
            slice.length == 0 ? nullptr : data.storage.span().data() + slice.offset,
            slice.length,
        };
    }

    static bool rawSliceToWTF(const RequestData& data, RequestSlice slice, String& out)
    {
        return rawStringToWTF(rawSlice(data, slice), out);
    }

    static bool rawStringIsBorrowable(ColloString raw) { return raw.len == 0 || raw.ptr; }

    static bool addRawStringLen(size_t& total, ColloString raw)
    {
        if (!rawStringIsBorrowable(raw))
            return false;
        if (raw.len > std::numeric_limits<size_t>::max() - total)
            return false;
        total += raw.len;
        return true;
    }

    static bool appendRawString(RequestData& data, ColloString raw, RequestSlice& out)
    {
        if (!rawStringIsBorrowable(raw))
            return false;
        out = {
            data.storage.size(),
            raw.len,
        };
        if (raw.len == 0)
            return true;
        data.storage.grow(out.offset + out.length);
        std::memcpy(data.storage.mutableSpan().data() + out.offset, raw.ptr, raw.len);
        return true;
    }

    static bool appendString(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, RequestData& data,
        const String& value, RequestSlice& out)
    {
        out = {
            data.storage.size(),
            0,
        };
        if (value.isEmpty())
            return true;

        auto result = value.tryGetUTF8([&](std::span<const char8_t> utf8) -> bool {
            out.length = utf8.size();
            return data.storage.tryAppend(
                std::span<const uint8_t> { reinterpret_cast<const uint8_t*>(utf8.data()), utf8.size() });
        });
        if (!result || !result.value()) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return false;
        }
        return true;
    }

    // The server speaks TLS only, so a dispatched request's origin is always
    // https; collo_request_new refuses an empty authority.
    static String makeRequestURL(const String& authority, const String& path, const String& raw_query)
    {
        const auto search = raw_query.isEmpty() ? emptyString() : WTF::makeString('?', raw_query);
        return WTF::makeString("https://"_s, authority, path, search);
    }

    static bool isHTTPMethodTokenCode(char16_t ch)
    {
        return (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '!'
            || ch == '#' || ch == '$' || ch == '%' || ch == '&' || ch == '\'' || ch == '*' || ch == '+' || ch == '-'
            || ch == '.' || ch == '^' || ch == '_' || ch == '`' || ch == '|' || ch == '~';
    }

    static bool isValidHTTPMethodToken(const String& method)
    {
        if (method.isEmpty())
            return false;
        for (unsigned index = 0; index < method.length(); index++) {
            if (!isHTTPMethodTokenCode(method[index]))
                return false;
        }
        return true;
    }

    // The Fetch Standard's forbidden methods, CONNECT, TRACE and TRACK, matched byte-case-insensitively.
    // FetchHeadersInternal::isForbiddenMethodName holds the same list for a name already lowercased, but
    // headers_list.h, which defines it, is private to headers.cpp.
    static bool isForbiddenRequestMethod(const String& method)
    {
        auto lower = method.convertToASCIILowercase();
        return lower == "connect"_s || lower == "trace"_s || lower == "track"_s;
    }

    static String normalizeRequestMethod(String method)
    {
        auto lower = method.convertToASCIILowercase();
        if (lower == "delete"_s)
            return "DELETE"_s;
        if (lower == "get"_s)
            return "GET"_s;
        if (lower == "head"_s)
            return "HEAD"_s;
        if (lower == "options"_s)
            return "OPTIONS"_s;
        if (lower == "post"_s)
            return "POST"_s;
        if (lower == "put"_s)
            return "PUT"_s;
        return method;
    }

    class JSColloRequest final : public JSColloBodyOwner {
        using Base = JSColloBodyOwner;

    public:
        template <typename CellType, JSC::SubspaceAccess> static JSC::CompleteSubspace* subspaceFor(JSC::VM& vm)
        {
            return &vm.destructibleObjectSpace();
        }

        static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* global_object, JSValue prototype)
        {
            return JSC::Structure::create(
                vm, global_object, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
        }

        static JSColloRequest* create(JSC::VM& vm, Collo::GlobalObject* global_object, RequestData&& data,
            PendingBody&& body, JSC::JSObject* headers = nullptr, JSColloAbortSignal* signal = nullptr,
            bool signal_controls_fetch = false, RequestOptions&& options = {}, JSC::Structure* structure = nullptr)
        {
            auto data_storage = RequestDataStorage::tryCreate(WTF::move(data));
            auto options_storage = RequestOptionsStorage::tryCreate(WTF::move(options));
            if (!data_storage || !options_storage)
                return nullptr;
            return createWithStorage(vm, global_object, data_storage.releaseNonNull(), WTF::move(body), headers, signal,
                signal_controls_fetch, options_storage.releaseNonNull(), structure);
        }

        static JSColloRequest* createWithStorage(JSC::VM& vm, Collo::GlobalObject* global_object,
            WTF::Ref<RequestDataStorage>&& data, PendingBody&& body, JSC::JSObject* headers, JSColloAbortSignal* signal,
            bool signal_controls_fetch, WTF::Ref<RequestOptionsStorage>&& options, JSC::Structure* structure = nullptr)
        {
            auto* object = new (NotNull, JSC::allocateCell<JSColloRequest>(vm))
                JSColloRequest(vm, structure ? structure : global_object->requestStructure(), WTF::move(data),
                    WTF::move(body.state), signal_controls_fetch, WTF::move(options));
            object->finishCreation(vm, body.stream);
            if (headers)
                object->m_headers.set(vm, object, headers);
            if (signal)
                object->m_signal.set(vm, object, signal);
            return object;
        }

        static void destroy(JSC::JSCell* cell) { static_cast<JSColloRequest*>(cell)->~JSColloRequest(); }

        DECLARE_INFO;
        DECLARE_VISIT_CHILDREN;

        const RequestData& data() const { return m_data->data(); }
        WTF::Ref<RequestDataStorage> dataStorage() const { return m_data.copyRef(); }
        const RequestOptions& options() const { return m_options->options(); }
        WTF::Ref<RequestOptionsStorage> optionsStorage() const { return m_options.copyRef(); }
        bool signalControlsFetch() const { return m_signal_controls_fetch; }

        JSC::JSString* method(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
        {
            if (auto* existing = m_method.get())
                return existing;

            const auto& data = this->data();
            String method;
            if (!rawSliceToWTF(data, data.method, method)) {
                JSC::throwVMTypeError(global_object, scope, "invalid request encoding"_s);
                return nullptr;
            }
            auto& vm = global_object->vm();
            auto* value = JSC::jsString(vm, method.isEmpty() ? "GET"_s : method);
            m_method.set(vm, this, value);
            return value;
        }

        JSC::JSString* path(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
        {
            if (auto* existing = m_path.get())
                return existing;

            const auto& data = this->data();
            String path;
            if (!rawSliceToWTF(data, data.path, path)) {
                JSC::throwVMTypeError(global_object, scope, "invalid request encoding"_s);
                return nullptr;
            }
            auto& vm = global_object->vm();
            auto* value = JSC::jsString(vm, WTF::move(path));
            m_path.set(vm, this, value);
            return value;
        }

        JSC::JSString* url(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
        {
            if (auto* existing = m_url.get())
                return existing;

            const auto& data = this->data();
            String existing_url;
            if (data.url.length != 0) {
                if (!rawSliceToWTF(data, data.url, existing_url)) {
                    JSC::throwVMTypeError(global_object, scope, "invalid request encoding"_s);
                    return nullptr;
                }
                auto* value = JSC::jsString(global_object->vm(), WTF::move(existing_url));
                m_url.set(global_object->vm(), this, value);
                return value;
            }

            String authority;
            String path;
            String raw_query;
            if (!rawSliceToWTF(data, data.authority, authority) || !rawSliceToWTF(data, data.path, path)
                || !rawSliceToWTF(data, data.raw_query, raw_query)) {
                JSC::throwVMTypeError(global_object, scope, "invalid request encoding"_s);
                return nullptr;
            }
            auto& vm = global_object->vm();
            auto* value = JSC::jsString(vm, makeRequestURL(authority, path, raw_query));
            m_url.set(vm, this, value);
            return value;
        }

        JSC::JSObject* headers(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
        {
            if (auto* existing = m_headers.get())
                return existing;

            WTF::Vector<ColloNameValuePair> pairs;
            const auto& data = this->data();
            pairs.reserveInitialCapacity(static_cast<unsigned>(
                std::min(data.headers.size(), static_cast<size_t>(std::numeric_limits<unsigned>::max()))));
            for (auto& header : data.headers) {
                pairs.append({
                    rawSlice(data, header.name),
                    rawSlice(data, header.value),
                });
            }

            auto* object = createHeadersFromRawPairs(global_object, scope, pairs.span().data(), pairs.size());
            RETURN_IF_EXCEPTION(scope, nullptr);
            if (!object)
                return nullptr;
            m_headers.set(global_object->vm(), this, object);
            return object;
        }

        JSC::JSObject* params(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
        {
            if (auto* existing = m_params.get())
                return existing;

            auto& vm = global_object->vm();
            auto* object = JSC::constructEmptyObject(global_object);
            const auto& data = this->data();
            for (auto& param : data.params) {
                String name;
                String value;
                if (!rawSliceToWTF(data, param.name, name) || !rawSliceToWTF(data, param.value, value)) {
                    JSC::throwVMTypeError(global_object, scope, "invalid request encoding"_s);
                    return nullptr;
                }
                object->putDirect(vm, JSC::Identifier::fromString(vm, name), JSC::jsString(vm, value));
            }
            m_params.set(vm, this, object);
            return object;
        }

        JSC::JSObject* query(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
        {
            if (auto* existing = m_query.get())
                return existing;

            String raw_query;
            const auto& data = this->data();
            if (!rawSliceToWTF(data, data.raw_query, raw_query)) {
                JSC::throwVMTypeError(global_object, scope, "invalid request encoding"_s);
                return nullptr;
            }
            auto& vm = global_object->vm();
            auto* object = Collo::HostFunctions::createURLSearchParamsFromString(global_object, WTF::move(raw_query));
            m_query.set(vm, this, object);
            return object;
        }

        JSColloAbortSignal* signal(JSC::JSGlobalObject* global_object)
        {
            if (auto* existing = m_signal.get())
                return existing;
            auto& vm = global_object->vm();
            auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
            auto* value = JSColloAbortSignal::create(vm, collo_global, collo_global->abortSignalStructure());
            m_signal.set(vm, this, value);
            return value;
        }

    private:
        JSColloRequest(JSC::VM& vm, JSC::Structure* structure, WTF::Ref<RequestDataStorage>&& data, BodyState&& body,
            bool signal_controls_fetch, WTF::Ref<RequestOptionsStorage>&& options)
            : Base(vm, structure, WTF::move(body))
            , m_data(WTF::move(data))
            , m_signal_controls_fetch(signal_controls_fetch)
            , m_options(WTF::move(options))
        {
        }

        ~JSColloRequest() = default;

        void finishCreation(JSC::VM& vm, JSC::JSObject* body_stream)
        {
            Base::finishCreation(vm, body_stream);
            ASSERT(inherits(info()));
        }

        WTF::Ref<RequestDataStorage> m_data;
        JSC::WriteBarrier<JSC::JSString> m_method;
        JSC::WriteBarrier<JSC::JSString> m_path;
        JSC::WriteBarrier<JSC::JSString> m_url;
        JSC::WriteBarrier<JSC::JSObject> m_headers;
        JSC::WriteBarrier<JSC::JSObject> m_params;
        JSC::WriteBarrier<JSC::JSObject> m_query;
        JSC::WriteBarrier<JSColloAbortSignal> m_signal;
        bool m_signal_controls_fetch { false };
        WTF::Ref<RequestOptionsStorage> m_options;
    };

    const JSC::ClassInfo JSColloRequest::s_info
        = { "Request"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloRequest) };

    template <typename Visitor> void JSColloRequest::visitChildrenImpl(JSC::JSCell* cell, Visitor& visitor)
    {
        auto* this_object = static_cast<JSColloRequest*>(cell);
        ASSERT_GC_OBJECT_INHERITS(this_object, info());
        Base::visitChildren(this_object, visitor);
        visitor.append(this_object->m_method);
        visitor.append(this_object->m_path);
        visitor.append(this_object->m_url);
        visitor.append(this_object->m_headers);
        visitor.append(this_object->m_params);
        visitor.append(this_object->m_query);
        visitor.append(this_object->m_signal);
    }

    DEFINE_VISIT_CHILDREN(JSColloRequest);

    static JSColloRequest* requireRequest(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
    {
        if (auto* object = dynamicDowncast<JSColloRequest>(value))
            return object;
        JSC::throwVMTypeError(global_object, scope, "Request method called on incompatible receiver"_s);
        return nullptr;
    }

    static JSC::JSUint8Array* createUint8ArrayCopy(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, std::span<const uint8_t> bytes)
    {
        auto* structure = global_object->typedArrayStructureWithTypedArrayType<JSC::TypeUint8>();
        auto* array = JSC::JSUint8Array::createUninitialized(global_object, structure, bytes.size());
        RETURN_IF_EXCEPTION(scope, nullptr);
        if (!bytes.empty())
            std::memcpy(array->vector(), bytes.data(), bytes.size());
        return array;
    }

    // The source of the stream that `Request.body` returns. It reads the body
    // through its Request, which the stream keeps alive by visiting this source, so
    // a body being read survives user code dropping the Request.
    class RequestBodySource final : public ReadableStreamNativeSource {
    public:
        static WTF::RefPtr<RequestBodySource> create(JSColloRequest* request)
        {
            void* storage = nullptr;
            if (!WTF::tryFastMalloc(sizeof(RequestBodySource)).getValue(storage))
                return nullptr;
            auto* source = new (NotNull, storage) RequestBodySource(request);
            return adoptRef(*source);
        }

        EncodedJSValue pull(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope) override
        {
            auto* request = m_request.get();
            if (!request || request->body().source() == BodyState::Source::Empty) {
                return resolvedPromise(
                    global_object, createReadableStreamReadResult(global_object, JSC::jsUndefined(), true));
            }
            if (m_static_delivered) {
                return resolvedPromise(
                    global_object, createReadableStreamReadResult(global_object, JSC::jsUndefined(), true));
            }

            if (request->body().source() == BodyState::Source::RequestLazy) {
                if (!request->body().beginStreamRead(global_object, scope, "Body already used"_s))
                    return {};
                RETURN_IF_EXCEPTION(scope, {});
                m_static_delivered = true;
                return requestLazyBodyPull(global_object, scope, request->body().requestIdentity());
            }

            WTF::RefPtr<ColloSharedBytes> bytes;
            if (!request->body().consumeToSharedBytes(global_object, scope, "Body already used"_s, bytes))
                return {};
            RETURN_IF_EXCEPTION(scope, {});
            m_static_delivered = true;
            auto* value
                = createUint8ArrayCopy(global_object, scope, bytes ? bytes->span() : std::span<const uint8_t> {});
            RETURN_IF_EXCEPTION(scope, {});
            if (!value)
                return {};
            return resolvedPromise(global_object, createReadableStreamReadResult(global_object, value, false));
        }

        EncodedJSValue cancel(JSC::JSGlobalObject* global_object, JSC::ThrowScope&, JSValue) override
        {
            auto* request = m_request.get();
            if (request) {
                auto scope = DECLARE_THROW_SCOPE(global_object->vm());
                if (!request->body().cancelStream(global_object, scope, "Body already used"_s))
                    return rejectedTypeError(global_object, scope, "Body already used"_s);
            }
            m_static_delivered = true;
            return resolvedPromise(global_object, JSC::jsUndefined());
        }

        void release() override { m_request.clear(); }

        void visitAggregate(JSC::AbstractSlotVisitor& visitor) override { visitor.append(m_request); }
        void visitAggregate(JSC::SlotVisitor& visitor) override { visitor.append(m_request); }

    private:
        // Until a stream adopts the source, the caller's stack roots the Request.
        explicit RequestBodySource(JSColloRequest* request)
            : m_request(request, JSC::WriteBarrierEarlyInit)
        {
        }

        JSC::WriteBarrier<JSColloRequest> m_request;
        bool m_static_delivered { false };

        static EncodedJSValue requestLazyBodyPull(
            JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, const ColloRequestIdentity& identity)
        {
            auto& vm = global_object->vm();
            auto bytes_promise_value = JSValue::decode(requestBytesForIdentity(global_object, scope, identity));
            RETURN_IF_EXCEPTION(scope, {});
            auto* bytes_promise = dynamicDowncast<JSC::JSPromise>(bytes_promise_value);
            if (!bytes_promise) {
                return resolvedPromise(
                    global_object, createReadableStreamReadResult(global_object, bytes_promise_value, false));
            }

            auto* read_promise = JSC::JSPromise::create(vm, global_object->promiseStructure());
            auto* fulfilled
                = JSC::JSNativeStdFunction::create(vm, global_object, 1, "Request body stream read fulfilled"_s,
                    [](JSC::JSGlobalObject* global_object, JSC::CallFrame* call_frame) {
                        return JSValue::encode(
                            createReadableStreamReadResult(global_object, call_frame->argument(0), false));
                    });
            bytes_promise->performPromiseThen(vm, global_object, fulfilled, JSC::jsUndefined(), read_promise);
            RETURN_IF_EXCEPTION(scope, {});
            return JSValue::encode(read_promise);
        }
    };

    static bool requireArgumentCount(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        JSC::CallFrame* call_frame, unsigned count, WTF::ASCIILiteral message)
    {
        if (call_frame->argumentCount() >= count)
            return true;
        JSC::throwVMTypeError(global_object, scope, message);
        return false;
    }

    static bool parseRequestURL(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue input, WTF::URL& out)
    {
        auto input_string = valueToWebApiString(global_object, scope, input);
        RETURN_IF_EXCEPTION(scope, false);
        WTF::URL url(input_string);
        if (!url.isValid()) {
            JSC::throwVMTypeError(global_object, scope, "Request has invalid URL"_s);
            return false;
        }
        out = WTF::move(url);
        return true;
    }

    static bool fillDataFromURL(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, WTF::URL& url, String method, RequestData& data)
    {
        String url_string = url.string();
        String path = url.path().toString();
        if (path.isEmpty() && (url.protocolIsInHTTPFamily() || url.protocolIs("ws"_s) || url.protocolIs("wss"_s)))
            path = "/"_s;
        String query = url.query().toString();
        String authority = url.hostAndPort();

        return appendString(global_object, scope, data, url_string, data.url)
            && appendString(global_object, scope, data, method, data.method)
            && appendString(global_object, scope, data, path, data.path)
            && appendString(global_object, scope, data, query, data.raw_query)
            && appendString(global_object, scope, data, authority, data.authority);
    }

    static bool parseMethodOverride(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue init_method, String fallback, String& out)
    {
        out = fallback.isEmpty() ? "GET"_s : WTF::move(fallback);
        if (init_method.isUndefined())
            return true;

        auto method = valueToWebApiString(global_object, scope, init_method);
        RETURN_IF_EXCEPTION(scope, false);
        // The order of the Fetch Standard's Request constructor: a method that is not a token is rejected, then a
        // forbidden one, and only then is the method normalized. The forbidden check can read the raw value because
        // normalization never rewrites CONNECT, TRACE or TRACK.
        if (!isValidHTTPMethodToken(method)) {
            JSC::throwVMTypeError(global_object, scope, "Request method is invalid"_s);
            return false;
        }
        if (isForbiddenRequestMethod(method)) {
            JSC::throwVMTypeError(global_object, scope, "Request method is forbidden"_s);
            return false;
        }
        out = normalizeRequestMethod(WTF::move(method));
        return true;
    }

    // The DOM Standard's "create a dependent abort signal" from one signal, which the Fetch Standard's Request
    // constructor and clone() use: the result aborts with the reason of `source` when `source` aborts. It follows
    // AbortSignal.any in abort.cpp for a single input.
    // FIXME: The results of addDependentSignal and addSourceSignal are ignored, so after an allocation failure the
    // returned signal does not follow `source`; AbortSignal.any throws an OutOfMemoryError instead.
    static JSColloAbortSignal* makeFollowingAbortSignal(
        JSC::VM& vm, Collo::GlobalObject* collo_global, JSColloAbortSignal* source)
    {
        if (source->aborted()) {
            // An already-aborted source produces a signal that is aborted at birth;
            // no abort event fires and no listener can be registered before return.
            return JSColloAbortSignal::create(
                vm, collo_global, collo_global->abortSignalStructure(), /* aborted */ true, source->reason());
        }

        auto* result = JSColloAbortSignal::create(vm, collo_global, collo_global->abortSignalStructure());
        // A dependent source contributes its own sources, so dependencies never chain, as in AbortSignal.any.
        const auto& source_signals = source->sourceSignals();
        if (source_signals.isEmpty()) {
            source->addDependentSignal(vm, result);
            result->addSourceSignal(vm, source);
        } else {
            for (auto& source_signal : source_signals) {
                if (auto* actual_source = source_signal.get()) {
                    actual_source->addDependentSignal(vm, result);
                    result->addSourceSignal(vm, actual_source);
                }
            }
        }
        return result;
    }

    static JSColloRequest* createPublicRequest(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        JSValue input_value, JSValue init_value, JSC::Structure* structure = nullptr)
    {
        auto& vm = global_object->vm();
        auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
        auto* input_request = dynamicDowncast<JSColloRequest>(input_value);

        JSObject* init_object = nullptr;
        if (!init_value.isUndefinedOrNull()) {
            init_object = dynamicDowncast<JSObject>(init_value);
            if (!init_object) {
                JSC::throwVMTypeError(global_object, scope, "Request init must be an object"_s);
                return nullptr;
            }
        }

        String fallback_method = "GET"_s;
        WTF::URL url;
        if (input_request) {
            JSString* input_url = input_request->url(global_object, scope);
            RETURN_IF_EXCEPTION(scope, nullptr);
            if (!parseRequestURL(global_object, scope, JSValue(input_url), url))
                return nullptr;
            JSString* input_method = input_request->method(global_object, scope);
            RETURN_IF_EXCEPTION(scope, nullptr);
            fallback_method = JSValue(input_method).toWTFString(global_object);
            RETURN_IF_EXCEPTION(scope, nullptr);
        } else if (!parseRequestURL(global_object, scope, input_value, url)) {
            return nullptr;
        }

        JSValue init_method = JSC::jsUndefined();
        JSValue headers_init = JSC::jsUndefined();
        JSValue body_init = JSC::jsUndefined();
        JSValue signal_init = JSC::jsUndefined();
        RequestOptions options;
        if (input_request)
            options = input_request->options();

        if (init_object) {
            init_method = propertyOrUndefined(global_object, scope, init_object, "method"_s);
            RETURN_IF_EXCEPTION(scope, nullptr);
            headers_init = propertyOrUndefined(global_object, scope, init_object, "headers"_s);
            RETURN_IF_EXCEPTION(scope, nullptr);
            body_init = propertyOrUndefined(global_object, scope, init_object, "body"_s);
            RETURN_IF_EXCEPTION(scope, nullptr);
            signal_init = propertyOrUndefined(global_object, scope, init_object, "signal"_s);
            RETURN_IF_EXCEPTION(scope, nullptr);
            if (!parseRequestOptionsIfPresent(global_object, scope, init_object, options))
                return nullptr;
            RETURN_IF_EXCEPTION(scope, nullptr);
        }

        String method;
        if (!parseMethodOverride(global_object, scope, init_method, WTF::move(fallback_method), method))
            return nullptr;
        RETURN_IF_EXCEPTION(scope, nullptr);
        if (!validateRequestOptions(global_object, scope, options, method))
            return nullptr;
        RETURN_IF_EXCEPTION(scope, nullptr);

        RequestData data;
        if (!fillDataFromURL(global_object, scope, url, method, data))
            return nullptr;
        RETURN_IF_EXCEPTION(scope, nullptr);

        JSObject* headers = nullptr;
        if (!headers_init.isUndefined()) {
            headers = createHeadersFromJS(global_object, scope, headers_init, HeaderGuard::Request);
        } else if (input_request) {
            auto* input_headers = input_request->headers(global_object, scope);
            RETURN_IF_EXCEPTION(scope, nullptr);
            headers = createHeadersFromJS(global_object, scope, input_headers, HeaderGuard::Request);
        } else {
            headers = createHeadersFromJS(global_object, scope, JSC::jsUndefined(), HeaderGuard::Request);
        }
        RETURN_IF_EXCEPTION(scope, nullptr);
        if (!headers)
            return nullptr;

        PendingBody body;
        if (!body_init.isUndefinedOrNull()) {
            BodyInitResult parsed_body;
            if (!createBodyStateFromJS(global_object, scope, body_init, parsed_body))
                return nullptr;
            RETURN_IF_EXCEPTION(scope, nullptr);
            body = WTF::move(parsed_body.body);
            if (!parsed_body.content_type.isEmpty()) {
                setHeaderDefault(global_object, scope, headers, "content-type"_s, WTF::move(parsed_body.content_type));
                RETURN_IF_EXCEPTION(scope, nullptr);
            }
        } else if (input_request) {
            if (!input_request->cloneBody(global_object, scope, "Body already used"_s, body))
                return nullptr;
            RETURN_IF_EXCEPTION(scope, nullptr);
        }
        if (body.state.source() != BodyState::Source::Empty && (method == "GET"_s || method == "HEAD"_s)) {
            JSC::throwVMTypeError(global_object, scope, "Request with GET or HEAD method cannot have a body"_s);
            return nullptr;
        }

        JSColloAbortSignal* signal = nullptr;
        bool signal_controls_fetch = false;
        if (!signal_init.isUndefinedOrNull()) {
            signal = webApiAbortSignalFromValue(signal_init);
            if (!signal) {
                JSC::throwVMTypeError(global_object, scope, "Request signal must be an AbortSignal"_s);
                return nullptr;
            }
            signal_controls_fetch = true;
        } else if (input_request) {
            // A Request built from another gets a new signal that depends on the input's, so aborting the input
            // aborts it with the same reason.
            auto* input_signal = input_request->signal(global_object);
            RETURN_IF_EXCEPTION(scope, nullptr);
            signal = makeFollowingAbortSignal(vm, collo_global, input_signal);
            signal_controls_fetch = input_request->signalControlsFetch();
        } else {
            signal = JSColloAbortSignal::create(vm, collo_global, collo_global->abortSignalStructure());
        }

        return JSColloRequest::create(vm, collo_global, WTF::move(data), WTF::move(body), headers, signal,
            signal_controls_fetch, WTF::move(options), structure);
    }

    JSC_DEFINE_HOST_FUNCTION(
        fetchAbortCancelCallback, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* callee = call_frame->jsCallee();
        const auto low_value = callee->get(global_object, JSC::Identifier::fromString(vm, "__colloFetchIdLow"_s));
        RETURN_IF_EXCEPTION(scope, {});
        const auto high_value = callee->get(global_object, JSC::Identifier::fromString(vm, "__colloFetchIdHigh"_s));
        RETURN_IF_EXCEPTION(scope, {});
        const auto low = static_cast<uint64_t>(low_value.toUInt32(global_object));
        RETURN_IF_EXCEPTION(scope, {});
        const auto high = static_cast<uint64_t>(high_value.toUInt32(global_object));
        RETURN_IF_EXCEPTION(scope, {});
        auto* signal = webApiAbortSignalFromValue(call_frame->thisValue());
        Runtime::cancelFetch(global_object, (high << 32) | low, signal ? signal->reason() : JSC::JSValue {});
        return JSValue::encode(JSC::jsUndefined());
    }

    JSC_DEFINE_HOST_FUNCTION(
        fetchAbortCleanupCallback, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* callee = call_frame->jsCallee();
        auto signal_value = callee->get(global_object, JSC::Identifier::fromString(vm, "__colloFetchAbortSignal"_s));
        RETURN_IF_EXCEPTION(scope, {});
        auto callback_value
            = callee->get(global_object, JSC::Identifier::fromString(vm, "__colloFetchAbortCallback"_s));
        RETURN_IF_EXCEPTION(scope, {});
        removeWebApiEventTargetListener(signal_value, "abort"_s, callback_value, false);
        return JSValue::encode(call_frame->argument(0));
    }

    static JSC::JSFunction* installFetchAbortCancel(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSColloAbortSignal* signal, uint64_t fetch_id)
    {
        auto& vm = global_object->vm();
        if (signal->eventTargetData().activeListenerCount() >= WebApiEventTargetMaxListeners) {
            Runtime::cancelFetch(global_object, fetch_id, signal->reason());
            auto* exception = createDOMException(
                global_object, DOMExceptionCode::QuotaExceededError, "AbortSignal listener limit exceeded"_s);
            JSC::throwException(global_object, scope, exception);
            return nullptr;
        }

        auto* callback = JSC::JSFunction::create(
            vm, global_object, 0, "fetch abort"_s, fetchAbortCancelCallback, JSC::ImplementationVisibility::Public);
        // A JS number holds integers exactly only up to 2^53, so the 64-bit fetch id travels as two 32-bit halves.
        callback->putDirect(vm, JSC::Identifier::fromString(vm, "__colloFetchIdLow"_s),
            JSC::jsNumber(static_cast<uint32_t>(fetch_id)), static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
        callback->putDirect(vm, JSC::Identifier::fromString(vm, "__colloFetchIdHigh"_s),
            JSC::jsNumber(static_cast<uint32_t>(fetch_id >> 32)),
            static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));

        WebApiEventListenerRecord record;
        record.type = "abort"_s;
        record.callback.set(vm, signal, callback);
        record.order = signal->eventTargetData().allocateListenerOrder();
        record.once = true;
        {
            // The concurrent GC marker walks the listener buffer, so it grows under the signal's cell lock, as in
            // event_target.cpp.
            WTF::Locker locker { signal->cellLock() };
            signal->eventTargetData().listeners().append(WTF::move(record));
        }
        return callback;
    }

    // Idempotent, so every terminal path may call it, more than once included: removeMatchingListener skips removed
    // listeners, and a `once` listener that already fired was removed when it fired.
    static void removeFetchAbortListener(JSColloAbortSignal* signal, JSC::JSFunction* abort_callback)
    {
        removeWebApiEventTargetListener(JSValue(signal), "abort"_s, abort_callback, false);
    }

    static bool installFetchAbortCleanup(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        JSColloAbortSignal* signal, JSC::JSFunction* abort_callback, JSC::EncodedJSValue encoded_promise)
    {
        auto& vm = global_object->vm();
        auto* promise = dynamicDowncast<JSC::JSPromise>(JSValue::decode(encoded_promise));
        if (!promise) {
            // Without a promise the fetch has already ended, and nothing else would ever remove the abort listener
            // from the signal.
            removeFetchAbortListener(signal, abort_callback);
            return true;
        }

        auto* cleanup = JSC::JSFunction::create(vm, global_object, 1, "fetch abort cleanup"_s,
            fetchAbortCleanupCallback, JSC::ImplementationVisibility::Public);
        cleanup->putDirect(vm, JSC::Identifier::fromString(vm, "__colloFetchAbortSignal"_s), signal,
            static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
        cleanup->putDirect(vm, JSC::Identifier::fromString(vm, "__colloFetchAbortCallback"_s), abort_callback,
            static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
        promise->performPromiseThen(vm, global_object, cleanup, cleanup, JSC::jsUndefined());
        RETURN_IF_EXCEPTION(scope, false);
        return true;
    }

} // namespace

JSC::EncodedJSValue scheduleFetchFromRequest(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    const Runtime::ActiveRequestRuntime& runtime, JSValue input_value, JSValue init_value)
{
    JSColloRequest* request = createPublicRequest(global_object, scope, input_value, init_value);
    RETURN_IF_EXCEPTION(scope, {});
    if (!request) {
        return {};
    }

    auto* signal = request->signal(global_object);
    RETURN_IF_EXCEPTION(scope, {});
    if (signal->aborted())
        return rejectedPromise(global_object, signal->reason());

    EncodedJSValue unsupported_option_rejection {};
    if (rejectUnsupportedFetchOption(global_object, scope, request->options(), unsupported_option_rejection))
        return unsupported_option_rejection;

    auto* url_value = request->url(global_object, scope);
    RETURN_IF_EXCEPTION(scope, {});
    WTF::String url = JSValue(url_value).toWTFString(global_object);
    RETURN_IF_EXCEPTION(scope, {});

    auto* method_value = request->method(global_object, scope);
    RETURN_IF_EXCEPTION(scope, {});
    WTF::String method = JSValue(method_value).toWTFString(global_object);
    RETURN_IF_EXCEPTION(scope, {});

    auto* headers = request->headers(global_object, scope);
    RETURN_IF_EXCEPTION(scope, {});
    WTF::Vector<ColloHeaderPair> header_pairs;
    if (!collectHeadersToPairs(global_object, scope, headers, header_pairs))
        return {};
    RETURN_IF_EXCEPTION(scope, {});

    WTF::Vector<uint8_t> body;
    if (!request->body().consumeToBytes(global_object, scope, "Body already used"_s, body))
        return {};
    RETURN_IF_EXCEPTION(scope, {});

    auto scheduled = Runtime::scheduleFetch(global_object, scope, runtime,
        {
            WTF::move(url),
            WTF::move(method),
            WTF::move(body),
            WTF::move(header_pairs),
            fetchFlagsForOptions(request->options()),
        });
    RETURN_IF_EXCEPTION(scope, {});
    // A fetch id of 0 is a fetch the runtime refused and already rejected (collo_runtime_fetch in abi.h); it has
    // nothing to cancel.
    if (scheduled.ok && scheduled.fetch_id != 0 && request->signalControlsFetch()) {
        auto* abort_callback = installFetchAbortCancel(global_object, scope, signal, scheduled.fetch_id);
        if (!abort_callback)
            return {};
        RETURN_IF_EXCEPTION(scope, {});
        if (!installFetchAbortCleanup(global_object, scope, signal, abort_callback, scheduled.encoded))
            return {};
        RETURN_IF_EXCEPTION(scope, {});
        if (signal->aborted()) {
            Runtime::cancelFetch(global_object, scheduled.fetch_id, signal->reason());
            // The signal aborted before the listener was installed, so the listener can never fire; it is removed so
            // that its record does not outlive the fetch.
            removeFetchAbortListener(signal, abort_callback);
        }
    }
    return scheduled.encoded;
}

namespace {

    static JSC::Structure* requestStructureForNewTarget(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::CallFrame* call_frame)
    {
        auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
        auto* new_target = call_frame->newTarget().getObject();
        auto* constructor = call_frame->jsCallee();
        auto* base = collo_global->requestStructure();
        RELEASE_ASSERT(base);
        if (!new_target || new_target == constructor)
            return base;
        auto* structure = JSC::InternalFunction::createSubclassStructure(global_object, new_target, base);
        RETURN_IF_EXCEPTION(scope, nullptr);
        return structure;
    }

    JSC_DEFINE_HOST_FUNCTION(requestConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        return JSC::throwVMTypeError(global_object, scope, "Request constructor requires 'new'"_s);
    }

    JSC_DEFINE_HOST_FUNCTION(
        requestConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        if (!requireArgumentCount(global_object, scope, call_frame, 1, "Request constructor requires a URL"_s))
            return {};
        auto* structure = requestStructureForNewTarget(global_object, scope, call_frame);
        RETURN_IF_EXCEPTION(scope, {});
        auto* request
            = createPublicRequest(global_object, scope, call_frame->argument(0), call_frame->argument(1), structure);
        RETURN_IF_EXCEPTION(scope, {});
        if (!request)
            return {};
        return JSValue::encode(request);
    }

    JSC_DEFINE_HOST_FUNCTION(requestGetBodyUsed, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* request = requireRequest(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(JSC::jsBoolean(request->bodyUsed()));
    }

    JSC_DEFINE_HOST_FUNCTION(requestGetMethod, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* request = requireRequest(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        auto* value = request->method(global_object, scope);
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(value);
    }

    JSC_DEFINE_HOST_FUNCTION(requestGetPath, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* request = requireRequest(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        auto* value = request->path(global_object, scope);
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(value);
    }

    JSC_DEFINE_HOST_FUNCTION(requestGetUrl, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* request = requireRequest(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        auto* value = request->url(global_object, scope);
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(value);
    }

    JSC_DEFINE_HOST_FUNCTION(requestGetHeaders, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* request = requireRequest(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        auto* value = request->headers(global_object, scope);
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(value);
    }

    JSC_DEFINE_HOST_FUNCTION(requestGetParams, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* request = requireRequest(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        auto* value = request->params(global_object, scope);
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(value);
    }

    JSC_DEFINE_HOST_FUNCTION(requestGetQuery, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* request = requireRequest(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        auto* value = request->query(global_object, scope);
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(value);
    }

    JSC_DEFINE_HOST_FUNCTION(requestGetBody, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* request = requireRequest(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (auto* stream = request->bodyStream())
            return JSValue::encode(stream);
        if (request->body().source() == BodyState::Source::Empty)
            return JSValue::encode(JSC::jsNull());

        auto source = RequestBodySource::create(request);
        if (!source) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return {};
        }
        auto* stream = createReadableStreamFromNativeSource(global_object, scope, source.releaseNonNull());
        RETURN_IF_EXCEPTION(scope, {});
        if (!stream)
            return {};
        request->setBodyStream(vm, stream);
        return JSValue::encode(stream);
    }

    JSC_DEFINE_HOST_FUNCTION(requestGetSignal, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* request = requireRequest(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(request->signal(global_object));
    }

#define COLLO_REQUEST_OPTION_GETTER(name, member)                                                                      \
    JSC_DEFINE_HOST_FUNCTION(name, (JSC::JSGlobalObject * global_object, JSC::CallFrame * call_frame))                 \
    {                                                                                                                  \
        auto& vm = global_object->vm();                                                                                \
        auto scope = DECLARE_THROW_SCOPE(vm);                                                                          \
        auto* request = requireRequest(global_object, scope, call_frame->thisValue());                                 \
        RETURN_IF_EXCEPTION(scope, {});                                                                                \
        return JSValue::encode(JSC::jsString(vm, request->options().member));                                          \
    }

    COLLO_REQUEST_OPTION_GETTER(requestGetDestination, destination)
    COLLO_REQUEST_OPTION_GETTER(requestGetReferrer, referrer)
    COLLO_REQUEST_OPTION_GETTER(requestGetReferrerPolicy, referrer_policy)
    COLLO_REQUEST_OPTION_GETTER(requestGetMode, mode)
    COLLO_REQUEST_OPTION_GETTER(requestGetCredentials, credentials)
    COLLO_REQUEST_OPTION_GETTER(requestGetCache, cache)
    COLLO_REQUEST_OPTION_GETTER(requestGetRedirect, redirect)
    COLLO_REQUEST_OPTION_GETTER(requestGetIntegrity, integrity)

#undef COLLO_REQUEST_OPTION_GETTER

    JSC_DEFINE_HOST_FUNCTION(requestGetKeepalive, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* request = requireRequest(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(JSC::jsBoolean(request->options().keepalive));
    }

    static EncodedJSValue requestTextImpl(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSColloRequest* request)
    {
        return request->consumeText(global_object, scope, "Body already used"_s);
    }

    JSC_DEFINE_HOST_FUNCTION(requestText, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* request = requireRequest(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return requestTextImpl(global_object, scope, request);
    }

    JSC_DEFINE_HOST_FUNCTION(requestJson, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* request = requireRequest(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return request->consumeJson(global_object, scope, "Body already used"_s);
    }

    JSC_DEFINE_HOST_FUNCTION(requestArrayBuffer, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* request = requireRequest(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return request->consumeArrayBuffer(global_object, scope, "Body already used"_s);
    }

    JSC_DEFINE_HOST_FUNCTION(requestBytes, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* request = requireRequest(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return request->consumeBytes(global_object, scope, "Body already used"_s);
    }

    JSC_DEFINE_HOST_FUNCTION(requestBlob, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* request = requireRequest(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});

        String type;
        auto* headers = request->headers(global_object, scope);
        RETURN_IF_EXCEPTION(scope, {});
        getHeaderValue(global_object, scope, headers, "content-type"_s, type);
        RETURN_IF_EXCEPTION(scope, {});
        return request->consumeBlob(global_object, scope, "Body already used"_s, WTF::move(type));
    }

    JSC_DEFINE_HOST_FUNCTION(requestFormData, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* request = requireRequest(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});

        String type;
        auto* headers = request->headers(global_object, scope);
        RETURN_IF_EXCEPTION(scope, {});
        getHeaderValue(global_object, scope, headers, "content-type"_s, type);
        RETURN_IF_EXCEPTION(scope, {});
        return request->consumeFormData(global_object, scope, "Body already used"_s, WTF::move(type));
    }

    JSC_DEFINE_HOST_FUNCTION(requestClone, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* request = requireRequest(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});

        PendingBody body;
        if (!request->cloneBody(global_object, scope, "Body already used"_s, body))
            return {};
        RETURN_IF_EXCEPTION(scope, {});

        auto* headers = request->headers(global_object, scope);
        RETURN_IF_EXCEPTION(scope, {});
        auto* cloned_headers = createHeadersFromJS(global_object, scope, headers, HeaderGuard::Request);
        RETURN_IF_EXCEPTION(scope, {});
        if (!cloned_headers)
            return {};

        auto data = request->dataStorage();
        auto options = request->optionsStorage();
        // The clone gets a new signal that depends on this one's, as the constructor does for a Request input.
        auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
        auto* source_signal = request->signal(global_object);
        RETURN_IF_EXCEPTION(scope, {});
        auto* cloned_signal = makeFollowingAbortSignal(vm, collo_global, source_signal);
        return JSValue::encode(JSColloRequest::createWithStorage(vm, collo_global, WTF::move(data), WTF::move(body),
            cloned_headers, cloned_signal, request->signalControlsFetch(), WTF::move(options)));
    }

    static bool makeRequestData(const ColloRequestInit& init, RequestData& data)
    {
        size_t storage_size = 0;
        if (!addRawStringLen(storage_size, init.method) || !addRawStringLen(storage_size, init.path)
            || !addRawStringLen(storage_size, init.raw_query) || !addRawStringLen(storage_size, init.authority))
            return false;
        for (size_t index = 0; index < init.headers_len; index++) {
            if (!addRawStringLen(storage_size, init.headers[index].name)
                || !addRawStringLen(storage_size, init.headers[index].value))
                return false;
        }
        for (size_t index = 0; index < init.params_len; index++) {
            if (!addRawStringLen(storage_size, init.params[index].name)
                || !addRawStringLen(storage_size, init.params[index].value))
                return false;
        }
        if (storage_size > std::numeric_limits<unsigned>::max())
            return false;
        if (init.headers_len > std::numeric_limits<unsigned>::max()
            || init.params_len > std::numeric_limits<unsigned>::max())
            return false;

        data.storage.reserveInitialCapacity(static_cast<unsigned>(storage_size));
        data.headers.reserveInitialCapacity(static_cast<unsigned>(init.headers_len));
        data.params.reserveInitialCapacity(static_cast<unsigned>(init.params_len));
        if (!appendRawString(data, init.method, data.method) || !appendRawString(data, init.path, data.path)
            || !appendRawString(data, init.raw_query, data.raw_query)
            || !appendRawString(data, init.authority, data.authority))
            return false;
        data.identity = init.identity;
        for (size_t index = 0; index < init.headers_len; index++) {
            RequestPair pair;
            if (!appendRawString(data, init.headers[index].name, pair.name)
                || !appendRawString(data, init.headers[index].value, pair.value))
                return false;
            data.headers.append(pair);
        }
        for (size_t index = 0; index < init.params_len; index++) {
            RequestPair pair;
            if (!appendRawString(data, init.params[index].name, pair.name)
                || !appendRawString(data, init.params[index].value, pair.value))
                return false;
            data.params.append(pair);
        }
        return true;
    }

} // namespace

void installServerRequest(Collo::GlobalObject* global_object, JSC::VM& vm)
{
    auto* request_prototype = JSC::constructEmptyObject(global_object);
    putWebApiAccessor(global_object, request_prototype, vm, "method"_s, requestGetMethod);
    putWebApiAccessor(global_object, request_prototype, vm, "destination"_s, requestGetDestination);
    putWebApiAccessor(global_object, request_prototype, vm, "referrer"_s, requestGetReferrer);
    putWebApiAccessor(global_object, request_prototype, vm, "referrerPolicy"_s, requestGetReferrerPolicy);
    putWebApiAccessor(global_object, request_prototype, vm, "mode"_s, requestGetMode);
    putWebApiAccessor(global_object, request_prototype, vm, "credentials"_s, requestGetCredentials);
    putWebApiAccessor(global_object, request_prototype, vm, "cache"_s, requestGetCache);
    putWebApiAccessor(global_object, request_prototype, vm, "redirect"_s, requestGetRedirect);
    putWebApiAccessor(global_object, request_prototype, vm, "integrity"_s, requestGetIntegrity);
    putWebApiAccessor(global_object, request_prototype, vm, "keepalive"_s, requestGetKeepalive);
    putWebApiAccessor(global_object, request_prototype, vm, "path"_s, requestGetPath);
    putWebApiAccessor(global_object, request_prototype, vm, "url"_s, requestGetUrl);
    putWebApiAccessor(global_object, request_prototype, vm, "headers"_s, requestGetHeaders);
    putWebApiAccessor(global_object, request_prototype, vm, "body"_s, requestGetBody);
    putWebApiAccessor(global_object, request_prototype, vm, "bodyUsed"_s, requestGetBodyUsed);
    putWebApiAccessor(global_object, request_prototype, vm, "signal"_s, requestGetSignal);
    putWebApiAccessor(global_object, request_prototype, vm, "params"_s, requestGetParams);
    putWebApiAccessor(global_object, request_prototype, vm, "query"_s, requestGetQuery);
    putWebApiFunction(global_object, request_prototype, vm, "text"_s, 0, requestText);
    putWebApiFunction(global_object, request_prototype, vm, "json"_s, 0, requestJson);
    putWebApiFunction(global_object, request_prototype, vm, "arrayBuffer"_s, 0, requestArrayBuffer);
    putWebApiFunction(global_object, request_prototype, vm, "bytes"_s, 0, requestBytes);
    putWebApiFunction(global_object, request_prototype, vm, "blob"_s, 0, requestBlob);
    putWebApiFunction(global_object, request_prototype, vm, "formData"_s, 0, requestFormData);
    putWebApiFunction(global_object, request_prototype, vm, "clone"_s, 0, requestClone);
    request_prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol,
        JSC::jsString(vm, WTF::makeString("Request"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    auto* request_constructor = JSC::JSFunction::create(vm, global_object, 1, "Request"_s, requestConstructorCall,
        JSC::ImplementationVisibility::Public, JSC::NoIntrinsic, requestConstructorConstruct, nullptr);
    RELEASE_ASSERT(request_constructor);
    request_constructor->putDirect(vm, vm.propertyNames->prototype, request_prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    request_prototype->putDirect(vm, vm.propertyNames->constructor, request_constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    JSC::Identifier request_identifier = JSC::Identifier::fromString(vm, "Request"_s);
    global_object->putDirect(
        vm, request_identifier, request_constructor, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    RELEASE_ASSERT(global_object->getDirect(vm, request_identifier));
    global_object->cacheRequestApi(
        request_constructor, request_prototype, JSColloRequest::createStructure(vm, global_object, request_prototype));
}

extern "C" ColloStatus collo_request_new(
    ColloVm* vm, const ColloRequestInit* init, ColloValue** out_value, ColloValue** out_exception)
{
    if (out_value)
        *out_value = nullptr;
    Collo::clearOutException(out_exception);

    if (!vm || !vm->isReady() || !init || !out_value || init->identity.request_id == 0 || init->authority.len == 0)
        return COLLO_STATUS_INVALID_ARGUMENT;
    if ((init->headers_len != 0 && !init->headers) || (init->params_len != 0 && !init->params))
        return COLLO_STATUS_INVALID_ARGUMENT;

    JSC::JSLockHolder locker(*vm->vm);
    auto scope = DECLARE_THROW_SCOPE(*vm->vm);

    RequestData data;
    if (!makeRequestData(*init, data))
        return COLLO_STATUS_INVALID_ARGUMENT;

    auto* object = JSColloRequest::create(
        *vm->vm, vm->global_object, WTF::move(data), PendingBody { BodyState::requestLazy(init->identity) });
    if (auto status = consumeExceptionStatus(vm, scope, out_exception); status != COLLO_STATUS_OK)
        return status;
    return Collo::makeValueHandle(vm, object, out_value);
}

} // namespace Collo::HostFunctions

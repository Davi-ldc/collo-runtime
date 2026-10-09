// The URL class on the VM thread: a cell that owns one parsed WTF::URL, its accessors and setters, `canParse` and
// `parse`, and Blob object URLs. Among the setters, only `href` throws for its value, a TypeError when it does not
// parse; every other setter leaves the URL unchanged when the URL Standard's setter steps reject the value. The cell
// reaches its URLSearchParams through a WriteBarrier: the params are created on the first `searchParams` access,
// reparsed when a setter replaces the query, and write their own changes back through
// `syncURLSearchParamsToAssociatedURL`. Object URLs live in the VM's `ColloBlobObjectURLRegistry` (state.h), which
// bounds their count and bytes.

#include "host_functions/webapi/url/url.h"

#include "host_functions/webapi/dom/dom_exception.h"
#include "host_functions/webapi/files/blob.h"
#include "host_functions/runtime/bridge.h"
#include "host_functions/webapi/url/search_params.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/GetterSetter.h>
#include <JavaScriptCore/InternalFunction.h>
#include <JavaScriptCore/IdentifierInlines.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSDestructibleObject.h>
#include <JavaScriptCore/JSFunction.h>
#include <JavaScriptCore/JSObject.h>
#include <JavaScriptCore/JSString.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <JavaScriptCore/SlotVisitorMacros.h>
#include <wtf/URL.h>
#include <wtf/URLParser.h>
#include <wtf/UUID.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringImpl.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/WTFString.h>

#include <limits>
#include <optional>

namespace Collo::HostFunctions {
namespace {

    using JSC::EncodedJSValue;
    using JSC::JSValue;
    using WTF::String;
    using namespace JSC;

    class JSColloURL;

    static size_t saturatingAdd(size_t left, size_t right)
    {
        if (right > std::numeric_limits<size_t>::max() - left)
            return std::numeric_limits<size_t>::max();
        return left + right;
    }

    static size_t stringMemoryCost(const String& value)
    {
        auto* impl = value.impl();
        if (!impl)
            return 0;
        return impl->costDuringGC();
    }

    // Parses argument 0 against the optional base in argument 1, as the URL constructor does. Returns nullopt with an
    // exception pending when argument 0 is missing or a conversion throws, and nullopt with none when either string
    // fails to parse.
    static std::optional<WTF::URL> parseURL(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::CallFrame* call_frame)
    {
        if (call_frame->argumentCount() < 1) {
            JSC::throwVMTypeError(global_object, scope, "URL requires a url argument"_s);
            return std::nullopt;
        }

        auto input = toWebApiUSVString(argumentToWebApiString(global_object, scope, call_frame, 0));
        RETURN_IF_EXCEPTION(scope, std::nullopt);

        if (call_frame->argument(1).isUndefined()) {
            WTF::URL url(input);
            if (!url.isValid())
                return std::nullopt;
            return url;
        }

        auto base_string = toWebApiUSVString(argumentToWebApiString(global_object, scope, call_frame, 1));
        RETURN_IF_EXCEPTION(scope, std::nullopt);

        WTF::URL base(base_string);
        if (!base.isValid())
            return std::nullopt;

        WTF::URL url(base, input);
        if (!url.isValid())
            return std::nullopt;
        return url;
    }

    static String stripLeading(String value, char16_t prefix)
    {
        if (!value.isEmpty() && value[0] == prefix)
            return value.substring(1);
        return value;
    }

    static String withTrailingColon(WTF::StringView protocol)
    {
        if (protocol.isEmpty())
            return emptyString();
        return WTF::makeString(protocol, ':');
    }

    static String searchWithLeadingQuestionMark(const WTF::URL& url)
    {
        auto query = url.query();
        if (query.isEmpty())
            return emptyString();
        return WTF::makeString('?', query);
    }

    static String fragmentWithLeadingHash(const WTF::URL& url)
    {
        auto fragment = url.fragmentIdentifier();
        if (fragment.isEmpty())
            return emptyString();
        return WTF::makeString('#', fragment);
    }

    static String originFor(const WTF::URL& url)
    {
        if (url.protocolIsInHTTPFamily() || url.protocolIsInFTPFamily() || url.protocolIs("ws"_s)
            || url.protocolIs("wss"_s))
            return url.protocolHostAndPort();

        if (url.protocolIsBlob()) {
            WTF::URL nested(WTF::URL(), url.path().toString());
            if (nested.isValid()
                && (nested.protocolIsInHTTPFamily() || nested.protocolIsInFTPFamily() || nested.protocolIs("ws"_s)
                    || nested.protocolIs("wss"_s)))
                return nested.protocolHostAndPort();
            // The URL Standard leaves a file URL's origin to the implementation, and this one treats it as opaque,
            // so `blob:file:...` serializes as "null" like every other inner URL without a tuple origin.
        }

        return "null"_s;
    }

    // The search setter parses its value in the URL Standard's query state with a state override, where '#' stays in
    // the query and the query percent-encode set turns it into %23. WTF::URL::setQuery reparses the whole URL, so an
    // unescaped '#' would start a fragment instead.
    static String querySetterValue(String value)
    {
        value = stripLeading(value, '?');
        if (!value.contains('#'))
            return value;

        WTF::StringBuilder builder;
        builder.reserveCapacity(value.length() + 2);
        for (unsigned i = 0; i < value.length(); i++) {
            if (value[i] == '#')
                builder.append("%23"_s);
            else
                builder.append(value[i]);
        }
        return builder.toString();
    }

    // The URL Standard's port state with a state override: tabs and newlines are skipped, the digits before the first
    // other code point are the port, and the scheme's default port becomes null. The outer nullopt means the value
    // is rejected and the port stays as it was: the first code point other than a tab or newline is not a digit, or
    // the number exceeds 65535. An inner nullopt means the port becomes null: the value is empty or holds only tabs
    // and newlines, or its number is the scheme's default port.
    // FIXME: the URL Standard strips tabs and newlines before the port state runs, so it rejects a value of only tabs
    // and newlines and leaves the port unchanged.
    static std::optional<std::optional<uint16_t>> parsePort(WTF::StringView value, WTF::StringView protocol)
    {
        if (value.isEmpty())
            return std::optional<uint16_t> { std::nullopt };

        uint32_t port = 0;
        bool found_digit = false;
        for (unsigned i = 0; i < value.length(); i++) {
            auto ch = value[i];
            if (ch == 0x0009 || ch == 0x000A || ch == 0x000D)
                continue;
            if (ch >= '0' && ch <= '9') {
                port = port * 10 + static_cast<uint32_t>(ch - '0');
                found_digit = true;
                if (port > std::numeric_limits<uint16_t>::max())
                    return std::nullopt;
                continue;
            }
            if (!found_digit)
                return std::nullopt;
            break;
        }
        if (!found_digit || WTF::isDefaultPortForProtocol(static_cast<uint16_t>(port), protocol))
            return std::optional<uint16_t> { std::nullopt };
        return { { static_cast<uint16_t>(port) } };
    }

    class JSColloURL final : public JSC::JSDestructibleObject {
        using Base = JSC::JSDestructibleObject;

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

        static JSColloURL* create(
            JSC::VM& vm, Collo::GlobalObject* global_object, WTF::URL&& url, JSC::Structure* structure = nullptr)
        {
            auto* object = new (NotNull, JSC::allocateCell<JSColloURL>(vm))
                JSColloURL(vm, structure ? structure : global_object->urlStructure(), WTF::move(url));
            object->finishCreation(vm);
            return object;
        }

        static void destroy(JSC::JSCell* cell) { static_cast<JSColloURL*>(cell)->~JSColloURL(); }

        static size_t estimatedSize(JSC::JSCell* cell, JSC::VM& vm);

        DECLARE_INFO;
        DECLARE_VISIT_CHILDREN;

        const WTF::URL& url() const { return m_url; }
        WTF::URL& mutableURL() { return m_url; }

        void setURL(JSC::VM& vm, WTF::URL&& url, bool reset_params);

        JSColloURLSearchParams* searchParams() const { return m_search_params.get(); }

        void setSearchParams(JSC::VM& vm, JSColloURLSearchParams* params) { m_search_params.set(vm, this, params); }

    private:
        JSColloURL(JSC::VM& vm, JSC::Structure* structure, WTF::URL&& url)
            : Base(vm, structure)
            , m_url(WTF::move(url))
        {
        }

        ~JSColloURL() = default;

        void finishCreation(JSC::VM& vm)
        {
            Base::finishCreation(vm);
            ASSERT(inherits(info()));
        }

        WTF::URL m_url;
        JSC::WriteBarrier<JSColloURLSearchParams> m_search_params;
    };

    const JSC::ClassInfo JSColloURL::s_info
        = { "URL"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloURL) };

    size_t JSColloURL::estimatedSize(JSC::JSCell* cell, JSC::VM& vm)
    {
        auto* this_object = static_cast<JSColloURL*>(cell);
        return saturatingAdd(Base::estimatedSize(cell, vm), stringMemoryCost(this_object->m_url.string()));
    }

    void JSColloURL::setURL(JSC::VM&, WTF::URL&& url, bool reset_params)
    {
        m_url = WTF::move(url);
        if (reset_params) {
            if (auto* params = m_search_params.get())
                params->resetFromSearch(searchWithLeadingQuestionMark(m_url));
        }
    }

    template <typename Visitor> void JSColloURL::visitChildrenImpl(JSC::JSCell* cell, Visitor& visitor)
    {
        auto* this_object = static_cast<JSColloURL*>(cell);
        ASSERT_GC_OBJECT_INHERITS(this_object, info());
        Base::visitChildren(this_object, visitor);
        visitor.append(this_object->m_search_params);
    }

    DEFINE_VISIT_CHILDREN(JSColloURL);

    static EncodedJSValue throwInvalidURL(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
    {
        return JSC::throwVMTypeError(global_object, scope, "Invalid URL"_s);
    }

    static JSColloURL* requireURL(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
    {
        if (auto* object = dynamicDowncast<JSColloURL>(value))
            return object;
        JSC::throwVMTypeError(global_object, scope, "URL method called on incompatible receiver"_s);
        return nullptr;
    }

    static bool setProtocol(WTF::URL& url, String value) { return url.setProtocol(value); }

    static bool setUsername(WTF::URL& url, String value)
    {
        if (url.host().isEmpty() || url.protocolIsFile())
            return true;
        url.setUser(value);
        return true;
    }

    static bool setPassword(WTF::URL& url, String value)
    {
        if (url.host().isEmpty() || url.protocolIsFile())
            return true;
        url.setPassword(value);
        return true;
    }

    static bool setHost(WTF::URL& url, String value)
    {
        // The URL Standard's host setter changes nothing on a URL with an opaque path, and its host state rejects an
        // empty host for a special scheme other than file.
        if (value.isEmpty() && !url.protocolIsFile() && url.hasSpecialScheme())
            return true;
        if (url.hasOpaquePath())
            return true;
        url.setHostAndPort(value);
        return url.isValid();
    }

    static bool setHostname(WTF::URL& url, String value)
    {
        if (value.isEmpty() && !url.protocolIsFile() && url.hasSpecialScheme())
            return true;
        if (url.hasOpaquePath())
            return true;
        url.setHost(value);
        return url.isValid();
    }

    static bool setPort(WTF::URL& url, String value)
    {
        if (value.isEmpty()) {
            url.setPort(std::nullopt);
            return true;
        }

        if (url.host().isEmpty() || url.protocolIsFile())
            return true;

        auto port = parsePort(value, url.protocol());
        if (!port)
            return true;
        url.setPort(*port);
        return true;
    }

    static bool setPathname(WTF::URL& url, String value)
    {
        if (url.hasOpaquePath())
            return true;
        url.setPath(value);
        return true;
    }

    static bool setSearch(WTF::URL& url, String value)
    {
        auto query = querySetterValue(value);
        if (query.isEmpty())
            url.setQuery(String());
        else
            url.setQuery(query);
        return true;
    }

    static bool setHash(WTF::URL& url, String value)
    {
        value = stripLeading(value, '#');
        if (value.isEmpty())
            url.removeFragmentIdentifier();
        else
            url.setFragmentIdentifier(value);
        return true;
    }

    static EncodedJSValue getURLStringProperty(JSC::JSGlobalObject* global_object, JSColloURL* url_object, String value)
    {
        return JSValue::encode(JSC::jsString(global_object->vm(), value));
    }

    JSC_DEFINE_HOST_FUNCTION(urlGetHref, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* url_object = requireURL(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return getURLStringProperty(global_object, url_object, url_object->url().string());
    }

    JSC_DEFINE_HOST_FUNCTION(urlSetHref, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* url_object = requireURL(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});

        auto input = toWebApiUSVString(argumentToWebApiString(global_object, scope, call_frame, 0));
        RETURN_IF_EXCEPTION(scope, {});

        WTF::URL url(input);
        if (!url.isValid())
            return throwInvalidURL(global_object, scope);

        url_object->setURL(vm, WTF::move(url), true);
        return JSValue::encode(JSC::jsUndefined());
    }

#define URL_STRING_GETTER(name, expression)                                                                            \
    JSC_DEFINE_HOST_FUNCTION(name, (JSC::JSGlobalObject * global_object, JSC::CallFrame * call_frame))                 \
    {                                                                                                                  \
        auto& vm = global_object->vm();                                                                                \
        auto scope = DECLARE_THROW_SCOPE(vm);                                                                          \
        auto* url_object = requireURL(global_object, scope, call_frame->thisValue());                                  \
        RETURN_IF_EXCEPTION(scope, {});                                                                                \
        return getURLStringProperty(global_object, url_object, (expression));                                          \
    }

    URL_STRING_GETTER(urlGetOrigin, originFor(url_object->url()))
    URL_STRING_GETTER(urlGetProtocol, withTrailingColon(url_object->url().protocol()))
    URL_STRING_GETTER(urlGetUsername, url_object->url().encodedUser().toString())
    URL_STRING_GETTER(urlGetPassword, url_object->url().encodedPassword().toString())
    URL_STRING_GETTER(urlGetHost, url_object->url().hostAndPort())
    URL_STRING_GETTER(urlGetHostname, url_object->url().host().toString())
    URL_STRING_GETTER(urlGetPort, url_object->url().port() ? String::number(*url_object->url().port()) : emptyString())
    URL_STRING_GETTER(urlGetPathname, url_object->url().path().toString())
    URL_STRING_GETTER(urlGetSearch, searchWithLeadingQuestionMark(url_object->url()))
    URL_STRING_GETTER(urlGetHash, fragmentWithLeadingHash(url_object->url()))

#undef URL_STRING_GETTER

    static EncodedJSValue setURLComponent(JSC::JSGlobalObject* global_object, JSC::CallFrame* call_frame,
        bool (*setter)(WTF::URL&, String), bool reset_params)
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* url_object = requireURL(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});

        auto value = toWebApiUSVString(argumentToWebApiString(global_object, scope, call_frame, 0));
        RETURN_IF_EXCEPTION(scope, {});

        // The setter works on a copy. When it rejects the value or leaves the URL invalid, the copy is reparsed from
        // the href it started with, so the object keeps its previous URL and the call does not throw.
        auto url = url_object->url();
        auto snapshot = url.string();
        if (!setter(url, value) || !url.isValid())
            url = WTF::URL { snapshot };

        url_object->setURL(vm, WTF::move(url), reset_params);
        return JSValue::encode(JSC::jsUndefined());
    }

    JSC_DEFINE_HOST_FUNCTION(urlSetProtocol, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        return setURLComponent(global_object, call_frame, setProtocol, false);
    }
    JSC_DEFINE_HOST_FUNCTION(urlSetUsername, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        return setURLComponent(global_object, call_frame, setUsername, false);
    }
    JSC_DEFINE_HOST_FUNCTION(urlSetPassword, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        return setURLComponent(global_object, call_frame, setPassword, false);
    }
    JSC_DEFINE_HOST_FUNCTION(urlSetHost, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        return setURLComponent(global_object, call_frame, setHost, false);
    }
    JSC_DEFINE_HOST_FUNCTION(urlSetHostname, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        return setURLComponent(global_object, call_frame, setHostname, false);
    }
    JSC_DEFINE_HOST_FUNCTION(urlSetPort, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        return setURLComponent(global_object, call_frame, setPort, false);
    }
    JSC_DEFINE_HOST_FUNCTION(urlSetPathname, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        return setURLComponent(global_object, call_frame, setPathname, false);
    }
    JSC_DEFINE_HOST_FUNCTION(urlSetSearch, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        return setURLComponent(global_object, call_frame, setSearch, true);
    }
    JSC_DEFINE_HOST_FUNCTION(urlSetHash, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        return setURLComponent(global_object, call_frame, setHash, false);
    }

    JSC_DEFINE_HOST_FUNCTION(urlGetSearchParams, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* url_object = requireURL(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});

        if (auto* params = url_object->searchParams())
            return JSValue::encode(params);

        // The URL Standard creates this object together with the URL. Creating it on first access cannot be observed:
        // it is parsed from the current query and cached, so every later access returns the same object.
        auto* params = createURLSearchParamsFromSearch(
            global_object, searchWithLeadingQuestionMark(url_object->url()), url_object);
        url_object->setSearchParams(vm, params);
        return JSValue::encode(params);
    }

    JSC_DEFINE_HOST_FUNCTION(urlToString, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* url_object = requireURL(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(JSC::jsString(vm, url_object->url().string()));
    }

    JSC_DEFINE_HOST_FUNCTION(urlConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        return JSC::throwVMTypeError(global_object, scope, "URL constructor requires 'new'"_s);
    }

    static JSC::Structure* urlStructureForNewTarget(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::CallFrame* call_frame)
    {
        auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
        auto* new_target = call_frame->newTarget().getObject();
        auto* constructor = call_frame->jsCallee();
        auto* base = collo_global->urlStructure();
        RELEASE_ASSERT(base);
        if (!new_target || new_target == constructor)
            return base;
        auto* structure = JSC::InternalFunction::createSubclassStructure(global_object, new_target, base);
        RETURN_IF_EXCEPTION(scope, nullptr);
        return structure;
    }

    JSC_DEFINE_HOST_FUNCTION(urlConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);

        auto url = parseURL(global_object, scope, call_frame);
        RETURN_IF_EXCEPTION(scope, {});
        if (!url)
            return throwInvalidURL(global_object, scope);
        auto* structure = urlStructureForNewTarget(global_object, scope, call_frame);
        RETURN_IF_EXCEPTION(scope, {});

        auto* object
            = JSColloURL::create(vm, uncheckedDowncast<Collo::GlobalObject>(global_object), WTF::move(*url), structure);
        return JSValue::encode(object);
    }

    JSC_DEFINE_HOST_FUNCTION(urlCanParse, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);

        auto url = parseURL(global_object, scope, call_frame);
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(JSC::jsBoolean(url.has_value()));
    }

    JSC_DEFINE_HOST_FUNCTION(urlParse, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);

        auto url = parseURL(global_object, scope, call_frame);
        RETURN_IF_EXCEPTION(scope, {});
        if (!url)
            return JSValue::encode(JSC::jsNull());

        auto* object = JSColloURL::create(vm, uncheckedDowncast<Collo::GlobalObject>(global_object), WTF::move(*url));
        return JSValue::encode(object);
    }

    JSC_DEFINE_HOST_FUNCTION(urlCreateObjectURL, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);

        auto* blob = dynamicDowncast<JSColloBlob>(call_frame->argument(0));
        if (!blob)
            return JSC::throwVMTypeError(global_object, scope, "createObjectURL expects a Blob object"_s);

        auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
        auto& registry = collo_global->owner().blob_object_urls;
        // The entry carries the creating request's id, so request cleanup (`collo_webapi_cleanup_request`) revokes
        // only that request's URLs and a co-scheduled request keeps its own. Outside a request turn the id is 0, and
        // the entry lives until revokeObjectURL or VM teardown.
        auto* owner_exec_ctx = Collo::HostFunctions::Runtime::activeExecContext(collo_global->owner());
        const uint64_t owner_request_id = owner_exec_ctx ? owner_exec_ctx->request_id : 0;
        WTF::Vector<BlobObjectURLBackingStore> backing_stores;
        if (!blob->appendObjectURLBackingStores(backing_stores))
            return JSValue::encode(JSC::throwOutOfMemoryError(global_object, scope));
        if (!registry.canInsert(backing_stores)) {
            auto* exception = createDOMException(
                global_object, DOMExceptionCode::QuotaExceededError, "Blob object URL registry quota exceeded"_s);
            return JSValue::encode(JSC::throwException(global_object, scope, exception));
        }

        String url;
        for (unsigned attempts = 0; attempts < 4; attempts++) {
            url = WTF::makeString("blob:"_s, WTF::createVersion4UUIDString());
            if (!registry.contains(url)) {
                auto result_url = url;
                if (!registry.insert(vm, WTF::move(url), blob, WTF::move(backing_stores), owner_request_id)) {
                    auto* exception = createDOMException(global_object, DOMExceptionCode::QuotaExceededError,
                        "Blob object URL registry quota exceeded"_s);
                    return JSValue::encode(JSC::throwException(global_object, scope, exception));
                }
                return JSValue::encode(JSC::jsString(vm, result_url));
            }
        }

        auto* exception = createDOMException(
            global_object, DOMExceptionCode::OperationError, "Could not allocate a unique blob URL"_s);
        return JSValue::encode(JSC::throwException(global_object, scope, exception));
    }

    JSC_DEFINE_HOST_FUNCTION(urlRevokeObjectURL, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);

        if (call_frame->argumentCount() < 1)
            return JSC::throwVMTypeError(
                global_object, scope, "Not enough arguments to 'revokeObjectURL'. Expected 1, got 0."_s);

        auto url = argumentToWebApiString(global_object, scope, call_frame, 0);
        RETURN_IF_EXCEPTION(scope, {});

        auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
        collo_global->owner().blob_object_urls.remove(url);
        return JSValue::encode(JSC::jsUndefined());
    }

} // namespace

void syncURLSearchParamsToAssociatedURL(JSC::JSObject* associated_url, const WTF::URLParser::URLEncodedForm& pairs)
{
    auto* url_object = dynamicDowncast<JSColloURL>(associated_url);
    if (!url_object)
        return;

    auto query = WTF::URLParser::serialize(pairs);
    if (query.isEmpty())
        url_object->mutableURL().setQuery(WTF::String());
    else
        url_object->mutableURL().setQuery(query);
}

void installWebApiURL(Collo::GlobalObject* global_object, JSC::VM& vm)
{
    constexpr unsigned enumerableAccessor = static_cast<unsigned>(JSC::PropertyAttribute::Accessor);
    constexpr unsigned enumerableFunction = static_cast<unsigned>(JSC::PropertyAttribute::None);

    auto* url_prototype = JSC::constructEmptyObject(global_object);
    putWebApiAccessor(global_object, url_prototype, vm, "href"_s, urlGetHref, urlSetHref, enumerableAccessor);
    putWebApiAccessor(global_object, url_prototype, vm, "origin"_s, urlGetOrigin, nullptr, enumerableAccessor);
    putWebApiAccessor(
        global_object, url_prototype, vm, "protocol"_s, urlGetProtocol, urlSetProtocol, enumerableAccessor);
    putWebApiAccessor(
        global_object, url_prototype, vm, "username"_s, urlGetUsername, urlSetUsername, enumerableAccessor);
    putWebApiAccessor(
        global_object, url_prototype, vm, "password"_s, urlGetPassword, urlSetPassword, enumerableAccessor);
    putWebApiAccessor(global_object, url_prototype, vm, "host"_s, urlGetHost, urlSetHost, enumerableAccessor);
    putWebApiAccessor(
        global_object, url_prototype, vm, "hostname"_s, urlGetHostname, urlSetHostname, enumerableAccessor);
    putWebApiAccessor(global_object, url_prototype, vm, "port"_s, urlGetPort, urlSetPort, enumerableAccessor);
    putWebApiAccessor(
        global_object, url_prototype, vm, "pathname"_s, urlGetPathname, urlSetPathname, enumerableAccessor);
    putWebApiAccessor(global_object, url_prototype, vm, "search"_s, urlGetSearch, urlSetSearch, enumerableAccessor);
    putWebApiAccessor(
        global_object, url_prototype, vm, "searchParams"_s, urlGetSearchParams, nullptr, enumerableAccessor);
    putWebApiAccessor(global_object, url_prototype, vm, "hash"_s, urlGetHash, urlSetHash, enumerableAccessor);
    putWebApiFunction(global_object, url_prototype, vm, "toString"_s, 0, urlToString, enumerableFunction);
    putWebApiFunction(global_object, url_prototype, vm, "toJSON"_s, 0, urlToString, enumerableFunction);
    url_prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol, JSC::jsString(vm, WTF::makeString("URL"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    auto* url_constructor = JSC::JSFunction::create(vm, global_object, 1, "URL"_s, urlConstructorCall,
        JSC::ImplementationVisibility::Public, JSC::NoIntrinsic, urlConstructorConstruct, nullptr);
    RELEASE_ASSERT(url_constructor);
    url_constructor->putDirect(vm, vm.propertyNames->prototype, url_prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    putWebApiFunction(global_object, url_constructor, vm, "canParse"_s, 1, urlCanParse,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    putWebApiFunction(global_object, url_constructor, vm, "parse"_s, 1, urlParse,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    putWebApiFunction(global_object, url_constructor, vm, "createObjectURL"_s, 1, urlCreateObjectURL,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    putWebApiFunction(global_object, url_constructor, vm, "revokeObjectURL"_s, 1, urlRevokeObjectURL,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    url_prototype->putDirect(
        vm, vm.propertyNames->constructor, url_constructor, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    JSC::Identifier url_identifier = JSC::Identifier::fromString(vm, "URL"_s);
    global_object->putDirect(
        vm, url_identifier, url_constructor, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    RELEASE_ASSERT(global_object->getDirect(vm, url_identifier));

    auto params_api = createURLSearchParamsApi(global_object, vm);

    global_object->cacheURLApi(url_constructor, url_prototype,
        JSColloURL::createStructure(vm, global_object, url_prototype), params_api.constructor, params_api.prototype,
        params_api.structure, params_api.iterator_prototype, params_api.iterator_structure);
}

} // namespace Collo::HostFunctions

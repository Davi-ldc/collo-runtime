// The RequestInit options other than method, headers, body and signal: reading and validating them for the Request
// constructor, encoding the redirect mode for the outbound fetch, and refusing the options the outbound fetch does not
// implement. Only request.cpp includes this file; its functions are static, so each includer compiles a copy of its
// own. VM thread only.

#pragma once

#include "host_functions/server/fetch/request.h"
#include "host_functions/webapi/dom/dom_exception.h"

#include <JavaScriptCore/IdentifierInlines.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSObject.h>
#include <wtf/URL.h>
#include <wtf/text/WTFString.h>

namespace Collo::HostFunctions::FetchRequestInternal {

using JSC::EncodedJSValue;
using WTF::String;
using namespace JSC;

// A Request's options, initialized to the Request constructor's defaults. Enum options hold their IDL string values.
struct RequestOptions {
    String destination;
    String referrer { "about:client"_s };
    String referrer_policy;
    String mode { "cors"_s };
    String credentials { "same-origin"_s };
    String cache { "default"_s };
    String redirect { "follow"_s };
    String integrity;
    bool keepalive { false };
};

static JSValue propertyOrUndefined(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSObject* object, WTF::ASCIILiteral name)
{
    auto value = object->get(global_object, JSC::Identifier::fromString(global_object->vm(), name));
    RETURN_IF_EXCEPTION(scope, {});
    return value;
}

static bool stringValueIfPresent(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSObject* object, WTF::ASCIILiteral name, String& out)
{
    auto value = propertyOrUndefined(global_object, scope, object, name);
    RETURN_IF_EXCEPTION(scope, false);
    if (value.isUndefined())
        return true;
    out = valueToWebApiString(global_object, scope, value);
    RETURN_IF_EXCEPTION(scope, false);
    return true;
}

static bool validateRequestWindowIfPresent(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSObject* object)
{
    auto value = propertyOrUndefined(global_object, scope, object, "window"_s);
    RETURN_IF_EXCEPTION(scope, false);
    if (value.isUndefined() || value.isNull())
        return true;
    JSC::throwVMTypeError(global_object, scope, "Request window option must be null"_s);
    return false;
}

static bool boolValueIfPresent(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSObject* object, WTF::ASCIILiteral name, bool& out)
{
    auto value = propertyOrUndefined(global_object, scope, object, name);
    RETURN_IF_EXCEPTION(scope, false);
    if (value.isUndefined())
        return true;
    out = value.toBoolean(global_object);
    RETURN_IF_EXCEPTION(scope, false);
    return true;
}

static bool isValidRequestMode(const String& mode)
{
    return mode == "same-origin"_s || mode == "no-cors"_s || mode == "cors"_s;
}

static bool isValidRequestCredentials(const String& credentials)
{
    return credentials == "omit"_s || credentials == "same-origin"_s || credentials == "include"_s;
}

static bool isValidRequestCache(const String& cache)
{
    return cache == "default"_s || cache == "no-store"_s || cache == "reload"_s || cache == "no-cache"_s
        || cache == "force-cache"_s || cache == "only-if-cached"_s;
}

static bool isValidRequestRedirect(const String& redirect)
{
    return redirect == "follow"_s || redirect == "error"_s || redirect == "manual"_s;
}

static bool isValidRequestReferrerPolicy(const String& policy)
{
    return policy.isEmpty() || policy == "no-referrer"_s || policy == "no-referrer-when-downgrade"_s
        || policy == "same-origin"_s || policy == "origin"_s || policy == "strict-origin"_s
        || policy == "origin-when-cross-origin"_s || policy == "strict-origin-when-cross-origin"_s
        || policy == "unsafe-url"_s;
}

static bool stringEnumValueIfPresent(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSObject* object,
    WTF::ASCIILiteral name, String& out, bool (*is_valid)(const String&), WTF::ASCIILiteral message)
{
    auto value = propertyOrUndefined(global_object, scope, object, name);
    RETURN_IF_EXCEPTION(scope, false);
    if (value.isUndefined())
        return true;

    auto parsed = valueToWebApiString(global_object, scope, value);
    RETURN_IF_EXCEPTION(scope, false);
    if (!is_valid(parsed)) {
        JSC::throwVMTypeError(global_object, scope, message);
        return false;
    }
    out = WTF::move(parsed);
    return true;
}

static bool referrerValueIfPresent(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSObject* object, String& out)
{
    auto value = propertyOrUndefined(global_object, scope, object, "referrer"_s);
    RETURN_IF_EXCEPTION(scope, false);
    if (value.isUndefined())
        return true;

    auto referrer = valueToWebApiString(global_object, scope, value);
    RETURN_IF_EXCEPTION(scope, false);
    if (referrer.isEmpty() || referrer == "about:client"_s) {
        out = WTF::move(referrer);
        return true;
    }

    WTF::URL url(referrer);
    if (!url.isValid()) {
        JSC::throwVMTypeError(global_object, scope, "Request referrer is invalid"_s);
        return false;
    }
    out = url.string();
    return true;
}

static bool parseRequestOptionsIfPresent(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSObject* object, RequestOptions& options)
{
    return validateRequestWindowIfPresent(global_object, scope, object)
        && referrerValueIfPresent(global_object, scope, object, options.referrer)
        && stringEnumValueIfPresent(global_object, scope, object, "referrerPolicy"_s, options.referrer_policy,
            isValidRequestReferrerPolicy, "Request referrerPolicy is invalid"_s)
        && stringEnumValueIfPresent(
            global_object, scope, object, "mode"_s, options.mode, isValidRequestMode, "Request mode is invalid"_s)
        && stringEnumValueIfPresent(global_object, scope, object, "credentials"_s, options.credentials,
            isValidRequestCredentials, "Request credentials is invalid"_s)
        && stringEnumValueIfPresent(
            global_object, scope, object, "cache"_s, options.cache, isValidRequestCache, "Request cache is invalid"_s)
        && stringEnumValueIfPresent(global_object, scope, object, "redirect"_s, options.redirect,
            isValidRequestRedirect, "Request redirect is invalid"_s)
        && stringValueIfPresent(global_object, scope, object, "integrity"_s, options.integrity)
        && boolValueIfPresent(global_object, scope, object, "keepalive"_s, options.keepalive);
}

static bool validateRequestOptions(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, RequestOptions& options, const String& method)
{
    if (options.cache == "only-if-cached"_s && options.mode != "same-origin"_s) {
        JSC::throwVMTypeError(global_object, scope, "Request cache 'only-if-cached' requires mode 'same-origin'"_s);
        return false;
    }
    if (options.mode == "no-cors"_s && method != "GET"_s && method != "HEAD"_s && method != "POST"_s) {
        JSC::throwVMTypeError(global_object, scope, "Request method is unsupported in no-cors mode"_s);
        return false;
    }
    return true;
}

// The low two bits of ColloFetchInit.flags carry the redirect mode: collo/abi.h documents the values, these constants
// encode them and RedirectMode.fromFlags in egress/client/transport/request/redirect.zig decodes them. Nothing
// generates one from another, so a change edits all three together.
static constexpr uint32_t FetchRedirectModeMask = 0x3;
static constexpr uint32_t FetchRedirectModeFollow = 0;
static constexpr uint32_t FetchRedirectModeError = 1;
static constexpr uint32_t FetchRedirectModeManual = 2;

static uint32_t fetchFlagsForOptions(const RequestOptions& options)
{
    uint32_t flags = 0;
    if (options.redirect == "error"_s)
        flags |= FetchRedirectModeError;
    else if (options.redirect == "manual"_s)
        flags |= FetchRedirectModeManual;
    else
        flags |= FetchRedirectModeFollow;
    return flags & FetchRedirectModeMask;
}

// Sets `out` to a promise rejected with a TypeError and returns true when `options` uses a Request option the outbound
// fetch does not implement; returns false otherwise.
static bool rejectUnsupportedFetchOption(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, const RequestOptions& options, EncodedJSValue& out)
{
    if (!options.integrity.isEmpty()) {
        out = rejectedTypeError(global_object, scope, "fetch integrity is not supported yet"_s);
        return true;
    }
    if (options.mode != "cors"_s) {
        out = rejectedTypeError(global_object, scope, "fetch only supports mode 'cors' in the server runtime"_s);
        return true;
    }
    if (options.credentials == "include"_s) {
        out = rejectedTypeError(global_object, scope, "fetch credentials 'include' is not supported yet"_s);
        return true;
    }
    if (options.cache != "default"_s) {
        out = rejectedTypeError(global_object, scope, "fetch cache modes are not supported yet"_s);
        return true;
    }
    if (!options.referrer_policy.isEmpty()) {
        out = rejectedTypeError(global_object, scope, "fetch referrerPolicy is not supported yet"_s);
        return true;
    }
    if (options.referrer != "about:client"_s) {
        out = rejectedTypeError(global_object, scope, "fetch referrer is not supported yet"_s);
        return true;
    }
    if (options.keepalive) {
        out = rejectedTypeError(global_object, scope, "fetch keepalive is not supported yet"_s);
        return true;
    }
    return false;
}

} // namespace Collo::HostFunctions::FetchRequestInternal

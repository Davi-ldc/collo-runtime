// The URLPattern class on the VM thread: argument conversion for the WebCore engine ported under `webcore_port/`,
// the result objects, and a fast path for patterns that constrain only the pathname. The fast path answers test()
// and exec() without the engine's regular expressions and must return exactly what the engine would; whenever it
// cannot be sure, it returns nullopt and the engine runs. The cell owns its WebCore::URLPattern through a Ref;
// `webcore_port/URLPatternComponent.h` explains why the RegExp roots inside it cannot keep this cell alive.

#include "host_functions/webapi/url/pattern/binding.h"

#include "host_functions/webapi/url/pattern/webcore_port/ExceptionOr.h"
#include "host_functions/webapi/url/pattern/webcore_port/ScriptExecutionContext.h"
#include "host_functions/webapi/url/pattern/webcore_port/URLPattern.h"
#include "host_functions/webapi/url/pattern/webcore_port/URLPatternInit.h"
#include "host_functions/webapi/url/pattern/webcore_port/URLPatternOptions.h"
#include "host_functions/webapi/url/pattern/webcore_port/URLPatternResult.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/GetterSetter.h>
#include <JavaScriptCore/IdentifierInlines.h>
#include <JavaScriptCore/InternalFunction.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSArray.h>
#include <JavaScriptCore/JSDestructibleObject.h>
#include <JavaScriptCore/JSFunction.h>
#include <JavaScriptCore/JSObject.h>
#include <JavaScriptCore/JSString.h>
#include <wtf/URL.h>
#include <wtf/Variant.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringImpl.h>

#include <limits>

namespace Collo::HostFunctions {
namespace {

    using JSC::EncodedJSValue;
    using JSC::JSValue;
    using WTF::String;
    using namespace JSC;

    static size_t saturatingAdd(size_t left, size_t right)
    {
        if (right > std::numeric_limits<size_t>::max() - left)
            return std::numeric_limits<size_t>::max();
        return left + right;
    }

    static size_t saturatingMultiply(size_t left, size_t right)
    {
        if (left && right > std::numeric_limits<size_t>::max() / left)
            return std::numeric_limits<size_t>::max();
        return left * right;
    }

    static size_t stringMemoryCost(const String& value)
    {
        auto* impl = value.impl();
        if (!impl)
            return 0;
        return impl->costDuringGC();
    }

    struct FastPathnamePart {
        enum class Kind : uint8_t {
            Literal,
            Parameter,
        };

        Kind kind;
        String value;
    };

    // A pathname of literal and `:name` segments, one part per segment. An empty list is the pattern "/".
    struct FastPathnamePattern {
        Vector<FastPathnamePart> parts;
    };

    static bool isFastIdentifierStart(char16_t character)
    {
        return (character >= 'A' && character <= 'Z') || (character >= 'a' && character <= 'z') || character == '_';
    }

    static bool isFastIdentifierContinue(char16_t character)
    {
        return isFastIdentifierStart(character) || (character >= '0' && character <= '9');
    }

    static bool isFastLiteralPathCharacter(char16_t character)
    {
        return (character >= 'A' && character <= 'Z') || (character >= 'a' && character <= 'z')
            || (character >= '0' && character <= '9') || character == '-' || character == '.' || character == '_'
            || character == '~';
    }

    static bool isFastInputPathCharacter(char16_t character) { return isFastLiteralPathCharacter(character); }

    // Returns the fast form of `pattern`, or nullopt when the engine must run: the pattern ignores case, constrains a
    // component other than the pathname, or has a pathname segment outside this form. A literal segment holds only
    // unreserved characters, which pathname canonicalization leaves as they are. A `:name` segment stands for one
    // whole segment, which is what the engine's default `[^/]+?` group matches as long as no input segment is empty.
    static std::optional<FastPathnamePattern> compileFastPathnamePattern(
        const WebCore::URLPattern& pattern, bool ignore_case)
    {
        if (ignore_case)
            return std::nullopt;
        if (pattern.protocol() != "*"_s || pattern.username() != "*"_s || pattern.password() != "*"_s
            || pattern.hostname() != "*"_s || pattern.port() != "*"_s || pattern.search() != "*"_s
            || pattern.hash() != "*"_s)
            return std::nullopt;

        const auto& pathname = pattern.pathname();
        if (pathname.isNull() || pathname.isEmpty() || pathname[0] != '/')
            return std::nullopt;

        FastPathnamePattern fast;
        if (pathname.length() == 1)
            return fast;

        unsigned segment_start = 1;
        while (segment_start < pathname.length()) {
            unsigned segment_end = segment_start;
            while (segment_end < pathname.length() && pathname[segment_end] != '/')
                ++segment_end;
            if (segment_end == segment_start)
                return std::nullopt;

            auto segment = StringView { pathname }.substring(segment_start, segment_end - segment_start).toString();
            if (segment[0] == ':') {
                if (segment.length() == 1 || !isFastIdentifierStart(segment[1]))
                    return std::nullopt;
                for (unsigned index = 2; index < segment.length(); ++index) {
                    if (!isFastIdentifierContinue(segment[index]))
                        return std::nullopt;
                }
                fast.parts.append({ FastPathnamePart::Kind::Parameter, segment.substring(1) });
            } else {
                for (unsigned index = 0; index < segment.length(); ++index) {
                    if (!isFastLiteralPathCharacter(segment[index]))
                        return std::nullopt;
                }
                fast.parts.append({ FastPathnamePart::Kind::Literal, WTF::move(segment) });
            }

            if (segment_end == pathname.length())
                break;
            segment_start = segment_end + 1;
            if (segment_start == pathname.length())
                return std::nullopt;
        }

        return fast;
    }

    static bool initOnlyHasFastPathname(const WebCore::URLPatternInit& init)
    {
        return init.protocol.isNull() && init.username.isNull() && init.password.isNull() && init.hostname.isNull()
            && init.port.isNull() && init.search.isNull() && init.hash.isNull() && init.baseURL.isNull()
            && !init.pathname.isNull();
    }

    // Whether the engine would match `pathname` unchanged, so the fast matcher can compare it directly: it starts with
    // '/', holds only unreserved characters, and has no empty segment, no trailing slash and no "." or ".." segment
    // for the URL parser to resolve.
    static bool inputPathnameIsFastSafe(const String& pathname)
    {
        if (pathname.isNull() || pathname.isEmpty() || pathname[0] != '/')
            return false;
        if (pathname.length() == 1)
            return true;
        bool previous_was_slash = true;
        unsigned segment_start = 1;
        auto segmentIsDotOrDotDot = [&](unsigned segment_end) {
            unsigned length = segment_end - segment_start;
            return (length == 1 && pathname[segment_start] == '.')
                || (length == 2 && pathname[segment_start] == '.' && pathname[segment_start + 1] == '.');
        };
        for (unsigned index = 1; index < pathname.length(); ++index) {
            auto character = pathname[index];
            if (character == '/') {
                if (previous_was_slash || index + 1 == pathname.length())
                    return false;
                if (segmentIsDotOrDotDot(index))
                    return false;
                previous_was_slash = true;
                segment_start = index + 1;
                continue;
            }
            if (!isFastInputPathCharacter(character))
                return false;
            previous_was_slash = false;
        }
        return !segmentIsDotOrDotDot(pathname.length());
    }

    static bool stringStartsWithASCIICaseInsensitive(const String& value, ASCIILiteral prefix)
    {
        if (value.length() < prefix.length())
            return false;
        for (unsigned index = 0; index < prefix.length(); ++index) {
            auto character = value[index];
            auto expected = prefix.characters()[index];
            if (character >= 'A' && character <= 'Z')
                character = character - 'A' + 'a';
            if (character != expected)
                return false;
        }
        return true;
    }

    static String fastPathnameFromPathLikeInput(const String& input)
    {
        if (input.isNull() || input.isEmpty() || input[0] != '/' || (input.length() > 1 && input[1] == '/'))
            return {};

        unsigned end = 0;
        while (end < input.length() && input[end] != '?' && input[end] != '#')
            ++end;
        auto pathname = StringView { input }.left(end).toString();
        return inputPathnameIsFastSafe(pathname) ? WTF::move(pathname) : String {};
    }

    static String fastPathnameFromAbsoluteHttpUrl(const String& input)
    {
        if (!stringStartsWithASCIICaseInsensitive(input, "http://"_s)
            && !stringStartsWithASCIICaseInsensitive(input, "https://"_s))
            return {};

        WTF::URL url(input);
        if (!url.isValid() || !url.protocolIsInHTTPFamily())
            return {};

        String pathname;
        auto path = url.path();
        if (path.isEmpty())
            pathname = "/"_s;
        else
            pathname = path.toString();
        return inputPathnameIsFastSafe(pathname) ? WTF::move(pathname) : String {};
    }

    // The pathname the engine would match for a string input and optional base URL, or a null string when the fast
    // path cannot tell. Without a base, only an absolute http or https URL qualifies. With one, the base must itself
    // qualify, and the input is either such a URL or a path starting with a single '/' that replaces the base's path.
    static String fastPathnameFromStringInput(const String& input, const String& base_url)
    {
        if (!base_url.isNull() && fastPathnameFromAbsoluteHttpUrl(base_url).isNull())
            return {};
        if (auto pathname = fastPathnameFromAbsoluteHttpUrl(input); !pathname.isNull())
            return pathname;
        if (!base_url.isNull())
            return fastPathnameFromPathLikeInput(input);
        return {};
    }

    static WebCore::URLPatternComponentResult makeFastEmptyComponentResult()
    {
        // The engine matches an empty component against the "*" wildcard, whose one unnamed group yields input ""
        // and groups { 0: "" }. The fast result must be the same, or exec() would differ between the two paths.
        WebCore::URLPatternComponentResult::GroupsRecord groups;
        groups.append(WebCore::URLPatternComponentResult::NameMatchPair { "0"_s, emptyString() });
        return { emptyString(), WTF::move(groups) };
    }

    // Returns the named groups when `pathname` matches `fast`, and nullopt on a mismatch or when `pathname` is not
    // fast safe.
    static std::optional<WebCore::URLPatternComponentResult::GroupsRecord> matchFastPathname(
        const FastPathnamePattern& fast, const String& pathname)
    {
        if (!inputPathnameIsFastSafe(pathname))
            return std::nullopt;
        if (pathname.length() == 1)
            return fast.parts.isEmpty() ? std::optional<WebCore::URLPatternComponentResult::GroupsRecord> { WebCore::
                                              URLPatternComponentResult::GroupsRecord {} }
                                        : std::nullopt;

        WebCore::URLPatternComponentResult::GroupsRecord groups;
        groups.reserveInitialCapacity(fast.parts.size());

        unsigned part_index = 0;
        unsigned segment_start = 1;
        while (segment_start < pathname.length()) {
            if (part_index >= fast.parts.size())
                return std::nullopt;

            unsigned segment_end = segment_start;
            while (segment_end < pathname.length() && pathname[segment_end] != '/')
                ++segment_end;

            const auto& part = fast.parts[part_index++];
            auto segment = StringView { pathname }.substring(segment_start, segment_end - segment_start).toString();
            if (part.kind == FastPathnamePart::Kind::Literal) {
                if (segment != part.value)
                    return std::nullopt;
            } else {
                groups.append(WebCore::URLPatternComponentResult::NameMatchPair { part.value, WTF::move(segment) });
            }

            if (segment_end == pathname.length())
                break;
            segment_start = segment_end + 1;
        }

        if (part_index != fast.parts.size())
            return std::nullopt;
        return groups;
    }

    // The answer to test(), or nullopt when the engine must decide. An init dictionary qualifies only when it sets
    // nothing but the pathname and no base URL is passed.
    static std::optional<bool> tryFastPathnameTest(const FastPathnamePattern& fast,
        const std::optional<WebCore::URLPattern::URLPatternInput>& input, const String& base_url)
    {
        if (!input)
            return std::nullopt;

        if (const auto* init = std::get_if<WebCore::URLPatternInit>(&*input)) {
            if (!base_url.isNull() || !initOnlyHasFastPathname(*init))
                return std::nullopt;
            if (!inputPathnameIsFastSafe(init->pathname))
                return std::nullopt;
            return !!matchFastPathname(fast, init->pathname);
        }

        const auto* string = std::get_if<String>(&*input);
        if (!string)
            return std::nullopt;
        auto pathname = fastPathnameFromStringInput(*string, base_url);
        if (pathname.isNull())
            return std::nullopt;
        return !!matchFastPathname(fast, pathname);
    }

    // The result of exec() for an init dictionary that sets only the pathname, with no base URL. Every other input,
    // and every mismatch, returns nullopt and goes to the engine.
    static std::optional<WebCore::URLPatternResult> tryFastPathnameExec(const FastPathnamePattern& fast,
        const std::optional<WebCore::URLPattern::URLPatternInput>& input, const String& base_url)
    {
        if (!base_url.isNull() || !input)
            return std::nullopt;

        const auto* init = std::get_if<WebCore::URLPatternInit>(&*input);
        if (!init || !initOnlyHasFastPathname(*init))
            return std::nullopt;

        auto pathname_groups = matchFastPathname(fast, init->pathname);
        if (!pathname_groups)
            return std::nullopt;

        WebCore::URLPatternResult result;
        result.inputs.append(*input);
        result.protocol = makeFastEmptyComponentResult();
        result.username = makeFastEmptyComponentResult();
        result.password = makeFastEmptyComponentResult();
        result.hostname = makeFastEmptyComponentResult();
        result.port = makeFastEmptyComponentResult();
        result.pathname = { init->pathname, WTF::move(*pathname_groups) };
        result.search = makeFastEmptyComponentResult();
        result.hash = makeFastEmptyComponentResult();
        return result;
    }

    static size_t fastPathnameMemoryCost(const std::optional<FastPathnamePattern>& fast_pathname)
    {
        if (!fast_pathname)
            return 0;

        size_t cost = saturatingMultiply(fast_pathname->parts.capacity(), sizeof(FastPathnamePart));
        for (auto& part : fast_pathname->parts)
            cost = saturatingAdd(cost, stringMemoryCost(part.value));
        return cost;
    }

    class JSColloURLPattern final : public JSC::JSDestructibleObject {
    public:
        using Base = JSC::JSDestructibleObject;
        static constexpr unsigned StructureFlags = Base::StructureFlags;

        template <typename CellType, JSC::SubspaceAccess> static JSC::CompleteSubspace* subspaceFor(JSC::VM& vm)
        {
            return &vm.destructibleObjectSpace();
        }

        static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* global_object, JSValue prototype)
        {
            return JSC::Structure::create(
                vm, global_object, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
        }

        static JSColloURLPattern* create(JSC::VM& vm, JSC::Structure* structure,
            WTF::Ref<WebCore::URLPattern>&& pattern, std::optional<FastPathnamePattern>&& fast_pathname)
        {
            auto* object = new (NotNull, JSC::allocateCell<JSColloURLPattern>(vm))
                JSColloURLPattern(vm, structure, WTF::move(pattern), WTF::move(fast_pathname));
            object->finishCreation(vm);
            return object;
        }

        DECLARE_INFO;

        static void destroy(JSC::JSCell* cell) { static_cast<JSColloURLPattern*>(cell)->~JSColloURLPattern(); }

        static size_t estimatedSize(JSC::JSCell*, JSC::VM&);

        WebCore::URLPattern& pattern() { return m_pattern.get(); }
        const std::optional<FastPathnamePattern>& fastPathname() const { return m_fast_pathname; }
        size_t memoryCost() const;

    private:
        JSColloURLPattern(JSC::VM& vm, JSC::Structure* structure, WTF::Ref<WebCore::URLPattern>&& pattern,
            std::optional<FastPathnamePattern>&& fast_pathname)
            : Base(vm, structure)
            , m_pattern(WTF::move(pattern))
            , m_fast_pathname(WTF::move(fast_pathname))
        {
        }

        void finishCreation(JSC::VM& vm)
        {
            Base::finishCreation(vm);
            ASSERT(inherits(info()));
        }

        WTF::Ref<WebCore::URLPattern> m_pattern;
        std::optional<FastPathnamePattern> m_fast_pathname;
    };

    const JSC::ClassInfo JSColloURLPattern::s_info
        = { "URLPattern"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloURLPattern) };

    size_t JSColloURLPattern::estimatedSize(JSC::JSCell* cell, JSC::VM& vm)
    {
        auto* this_object = static_cast<JSColloURLPattern*>(cell);
        return saturatingAdd(Base::estimatedSize(cell, vm), this_object->memoryCost());
    }

    size_t JSColloURLPattern::memoryCost() const
    {
        return saturatingAdd(m_pattern.get().memoryCost(), fastPathnameMemoryCost(m_fast_pathname));
    }

    static JSColloURLPattern* requireURLPattern(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
    {
        if (auto* pattern = dynamicDowncast<JSColloURLPattern>(value))
            return pattern;
        JSC::throwVMTypeError(global_object, scope, "URLPattern method called on incompatible receiver"_s);
        return nullptr;
    }

    static EncodedJSValue throwURLPatternException(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, WebCore::Exception&& exception)
    {
        auto message = exception.message().isEmpty() ? "Invalid URLPattern"_s : exception.message();
        return JSC::throwVMTypeError(global_object, scope, message);
    }

    static JSC::Structure* structureForNewTarget(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::CallFrame* call_frame)
    {
        auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
        auto* new_target = call_frame->newTarget().getObject();
        auto* constructor = call_frame->jsCallee();
        auto* base_structure = collo_global->webApiCache().url_pattern_structure.get();
        RELEASE_ASSERT(base_structure);
        if (!new_target || new_target == constructor)
            return base_structure;

        auto* structure = JSC::InternalFunction::createSubclassStructure(global_object, new_target, base_structure);
        RETURN_IF_EXCEPTION(scope, nullptr);
        return structure;
    }

    static bool shouldTreatAsInitDictionary(JSC::JSGlobalObject* global_object, JSValue value)
    {
        UNUSED_PARAM(global_object);
        if (!value.isObject() || value.isNull())
            return false;
        return true;
    }

    static bool readUSVStringProperty(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSObject* object,
        WTF::ASCIILiteral name, String& output)
    {
        auto value = object->get(global_object, JSC::Identifier::fromString(global_object->vm(), name));
        RETURN_IF_EXCEPTION(scope, false);
        if (value.isUndefined())
            return true;
        output = toWebApiUSVString(valueToWebApiString(global_object, scope, value));
        RETURN_IF_EXCEPTION(scope, false);
        return true;
    }

    static bool readURLPatternInit(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value, WebCore::URLPatternInit& init)
    {
        if (!value.isObject() || value.isNull()) {
            JSC::throwVMTypeError(global_object, scope, "URLPattern init must be an object"_s);
            return false;
        }

        auto* object = JSC::asObject(value);
        return readUSVStringProperty(global_object, scope, object, "protocol"_s, init.protocol)
            && readUSVStringProperty(global_object, scope, object, "username"_s, init.username)
            && readUSVStringProperty(global_object, scope, object, "password"_s, init.password)
            && readUSVStringProperty(global_object, scope, object, "hostname"_s, init.hostname)
            && readUSVStringProperty(global_object, scope, object, "port"_s, init.port)
            && readUSVStringProperty(global_object, scope, object, "pathname"_s, init.pathname)
            && readUSVStringProperty(global_object, scope, object, "search"_s, init.search)
            && readUSVStringProperty(global_object, scope, object, "hash"_s, init.hash)
            && readUSVStringProperty(global_object, scope, object, "baseURL"_s, init.baseURL);
    }

    static bool readURLPatternOptions(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value, WebCore::URLPatternOptions& options)
    {
        if (value.isUndefinedOrNull())
            return true;
        if (!value.isObject()) {
            JSC::throwVMTypeError(global_object, scope, "URLPattern options must be an object"_s);
            return false;
        }

        auto ignore_case = JSC::asObject(value)->get(
            global_object, JSC::Identifier::fromString(global_object->vm(), "ignoreCase"_s));
        RETURN_IF_EXCEPTION(scope, false);
        if (!ignore_case.isUndefined())
            options.ignoreCase = ignore_case.toBoolean(global_object);
        return true;
    }

    static bool readURLPatternInput(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value,
        WebCore::URLPattern::URLPatternInput& input)
    {
        if (shouldTreatAsInitDictionary(global_object, value)) {
            WebCore::URLPatternInit init;
            if (!readURLPatternInit(global_object, scope, value, init))
                return false;
            input = WTF::move(init);
            return true;
        }

        input = toWebApiUSVString(valueToWebApiString(global_object, scope, value));
        RETURN_IF_EXCEPTION(scope, false);
        return true;
    }

    // WebIDL overload resolution between (input, baseURL, options) and (input, options): the second argument is the
    // base URL when there are three or more arguments, or when it is neither undefined, null nor an object.
    static bool constructorUsesBaseURLOverload(JSC::CallFrame* call_frame)
    {
        if (call_frame->argumentCount() >= 3)
            return true;
        if (call_frame->argumentCount() < 2)
            return false;
        auto second = call_frame->uncheckedArgument(1);
        return !second.isUndefinedOrNull() && !second.isObject();
    }

    static JSC::JSObject* createInitObject(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, const WebCore::URLPatternInit& init)
    {
        auto& vm = global_object->vm();
        auto* object = JSC::constructEmptyObject(global_object);
        RETURN_IF_EXCEPTION(scope, nullptr);
        auto putIfPresent = [&](WTF::ASCIILiteral name, const String& value) -> bool {
            if (!value.isNull())
                object->putDirect(vm, JSC::Identifier::fromString(vm, name), JSC::jsString(vm, value));
            RETURN_IF_EXCEPTION(scope, false);
            return true;
        };
        if (!putIfPresent("protocol"_s, init.protocol) || !putIfPresent("username"_s, init.username)
            || !putIfPresent("password"_s, init.password) || !putIfPresent("hostname"_s, init.hostname)
            || !putIfPresent("port"_s, init.port) || !putIfPresent("pathname"_s, init.pathname)
            || !putIfPresent("search"_s, init.search) || !putIfPresent("hash"_s, init.hash)
            || !putIfPresent("baseURL"_s, init.baseURL))
            return nullptr;
        return object;
    }

    static JSC::JSValue createInputValue(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, const WebCore::URLPattern::URLPatternInput& input)
    {
        auto& vm = global_object->vm();
        return WTF::switchOn(
            input,
            [&](const String& string) -> JSValue {
                auto value = JSC::jsString(vm, string);
                RETURN_IF_EXCEPTION(scope, {});
                return value;
            },
            [&](const WebCore::URLPatternInit& init) -> JSValue {
                auto* object = createInitObject(global_object, scope, init);
                RETURN_IF_EXCEPTION(scope, {});
                return object;
            });
    }

    // The `input` and `groups` names, resolved once per createURLPatternResult call and shared by its eight component
    // results, because each Identifier::fromString call probes the VM's atom table.
    struct ComponentResultIdentifiers {
        JSC::Identifier input;
        JSC::Identifier groups;
    };

    static JSC::JSObject* createComponentResult(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        const ComponentResultIdentifiers& ids, const WebCore::URLPatternComponentResult& component)
    {
        auto& vm = global_object->vm();
        auto* result = JSC::constructEmptyObject(global_object);
        RETURN_IF_EXCEPTION(scope, nullptr);
        result->putDirect(vm, ids.input, JSC::jsString(vm, component.input));
        RETURN_IF_EXCEPTION(scope, nullptr);

        auto* groups = JSC::constructEmptyObject(global_object);
        RETURN_IF_EXCEPTION(scope, nullptr);
        for (const auto& pair : component.groups) {
            JSValue value = WTF::switchOn(
                pair.value, [](const std::monostate&) -> JSValue { return JSC::jsUndefined(); },
                [&](const String& string) -> JSValue { return JSC::jsString(vm, string); });
            RETURN_IF_EXCEPTION(scope, nullptr);
            groups->putDirectMayBeIndex(global_object, JSC::Identifier::fromString(vm, pair.key), value);
            RETURN_IF_EXCEPTION(scope, nullptr);
        }
        result->putDirect(vm, ids.groups, groups);
        RETURN_IF_EXCEPTION(scope, nullptr);
        return result;
    }

    static JSC::JSObject* createURLPatternResult(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, const WebCore::URLPatternResult& match)
    {
        auto& vm = global_object->vm();
        ComponentResultIdentifiers componentIds {
            JSC::Identifier::fromString(vm, "input"_s),
            JSC::Identifier::fromString(vm, "groups"_s),
        };
        auto* result = JSC::constructEmptyObject(global_object);
        RETURN_IF_EXCEPTION(scope, nullptr);
        auto* inputs = JSC::constructEmptyArray(global_object, nullptr, match.inputs.size());
        RETURN_IF_EXCEPTION(scope, nullptr);
        for (unsigned index = 0; index < match.inputs.size(); ++index) {
            auto value = createInputValue(global_object, scope, match.inputs[index]);
            RETURN_IF_EXCEPTION(scope, nullptr);
            inputs->putDirectIndex(global_object, index, value);
            RETURN_IF_EXCEPTION(scope, nullptr);
        }
        result->putDirect(vm, JSC::Identifier::fromString(vm, "inputs"_s), inputs);
        RETURN_IF_EXCEPTION(scope, nullptr);
        auto putComponent = [&](WTF::ASCIILiteral name, const WebCore::URLPatternComponentResult& component) -> bool {
            auto* component_result = createComponentResult(global_object, scope, componentIds, component);
            RETURN_IF_EXCEPTION(scope, false);
            result->putDirect(vm, JSC::Identifier::fromString(vm, name), component_result);
            RETURN_IF_EXCEPTION(scope, false);
            return true;
        };
        if (!putComponent("protocol"_s, match.protocol) || !putComponent("username"_s, match.username)
            || !putComponent("password"_s, match.password) || !putComponent("hostname"_s, match.hostname)
            || !putComponent("port"_s, match.port) || !putComponent("pathname"_s, match.pathname)
            || !putComponent("search"_s, match.search) || !putComponent("hash"_s, match.hash))
            return nullptr;
        return result;
    }

    static EncodedJSValue constructURLPattern(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::CallFrame* call_frame)
    {
        WebCore::URLPatternOptions options;
        WebCore::ScriptExecutionContext context(global_object);

        WebCore::ExceptionOr<WTF::Ref<WebCore::URLPattern>> created
            = WebCore::Exception { WebCore::ExceptionCode::TypeError, "Invalid URLPattern"_s };
        if (constructorUsesBaseURLOverload(call_frame)) {
            WebCore::URLPattern::URLPatternInput input { String {} };
            if (!readURLPatternInput(global_object, scope, call_frame->argument(0), input))
                return {};
            RETURN_IF_EXCEPTION(scope, {});

            auto base_url = toWebApiUSVString(valueToWebApiString(global_object, scope, call_frame->argument(1)));
            RETURN_IF_EXCEPTION(scope, {});
            if (!readURLPatternOptions(global_object, scope, call_frame->argument(2), options))
                return {};
            RETURN_IF_EXCEPTION(scope, {});
            created = WebCore::URLPattern::create(context, WTF::move(input), WTF::move(base_url), WTF::move(options));
        } else {
            std::optional<WebCore::URLPattern::URLPatternInput> input;
            if (!call_frame->argument(0).isUndefined()) {
                WebCore::URLPattern::URLPatternInput parsed { String {} };
                if (!readURLPatternInput(global_object, scope, call_frame->argument(0), parsed))
                    return {};
                RETURN_IF_EXCEPTION(scope, {});
                input = WTF::move(parsed);
            }
            if (!readURLPatternOptions(global_object, scope, call_frame->argument(1), options))
                return {};
            RETURN_IF_EXCEPTION(scope, {});
            created = WebCore::URLPattern::create(context, WTF::move(input), WTF::move(options));
        }

        if (created.hasException())
            return throwURLPatternException(global_object, scope, created.releaseException());

        auto* structure = structureForNewTarget(global_object, scope, call_frame);
        RETURN_IF_EXCEPTION(scope, {});
        auto pattern = created.releaseReturnValue();
        auto fast_pathname = compileFastPathnamePattern(pattern.get(), options.ignoreCase);
        return JSValue::encode(
            JSColloURLPattern::create(global_object->vm(), structure, WTF::move(pattern), WTF::move(fast_pathname)));
    }

    JSC_DEFINE_HOST_FUNCTION(urlPatternConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        return JSC::throwVMTypeError(global_object, scope, "URLPattern constructor requires 'new'"_s);
    }

    JSC_DEFINE_HOST_FUNCTION(
        urlPatternConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        return constructURLPattern(global_object, scope, call_frame);
    }

    static EncodedJSValue patternStringGetter(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue this_value, WTF::ASCIILiteral name)
    {
        auto* object = requireURLPattern(global_object, scope, this_value);
        if (!object)
            return {};
        auto& vm = global_object->vm();
        const auto& pattern = object->pattern();
        if (name == "protocol"_s)
            return JSValue::encode(JSC::jsString(vm, pattern.protocol()));
        if (name == "username"_s)
            return JSValue::encode(JSC::jsString(vm, pattern.username()));
        if (name == "password"_s)
            return JSValue::encode(JSC::jsString(vm, pattern.password()));
        if (name == "hostname"_s)
            return JSValue::encode(JSC::jsString(vm, pattern.hostname()));
        if (name == "port"_s)
            return JSValue::encode(JSC::jsString(vm, pattern.port()));
        if (name == "pathname"_s)
            return JSValue::encode(JSC::jsString(vm, pattern.pathname()));
        if (name == "search"_s)
            return JSValue::encode(JSC::jsString(vm, pattern.search()));
        if (name == "hash"_s)
            return JSValue::encode(JSC::jsString(vm, pattern.hash()));
        RELEASE_ASSERT_NOT_REACHED();
    }

#define COLLO_URL_PATTERN_STRING_GETTER(function_name, property_name)                                                  \
    JSC_DEFINE_HOST_FUNCTION(function_name, (JSC::JSGlobalObject * global_object, JSC::CallFrame * frame))             \
    {                                                                                                                  \
        auto& vm = global_object->vm();                                                                                \
        auto scope = DECLARE_THROW_SCOPE(vm);                                                                          \
        return patternStringGetter(global_object, scope, frame->thisValue(), property_name##_s);                       \
    }

    COLLO_URL_PATTERN_STRING_GETTER(urlPatternGetProtocol, "protocol")
    COLLO_URL_PATTERN_STRING_GETTER(urlPatternGetUsername, "username")
    COLLO_URL_PATTERN_STRING_GETTER(urlPatternGetPassword, "password")
    COLLO_URL_PATTERN_STRING_GETTER(urlPatternGetHostname, "hostname")
    COLLO_URL_PATTERN_STRING_GETTER(urlPatternGetPort, "port")
    COLLO_URL_PATTERN_STRING_GETTER(urlPatternGetPathname, "pathname")
    COLLO_URL_PATTERN_STRING_GETTER(urlPatternGetSearch, "search")
    COLLO_URL_PATTERN_STRING_GETTER(urlPatternGetHash, "hash")

#undef COLLO_URL_PATTERN_STRING_GETTER

    JSC_DEFINE_HOST_FUNCTION(urlPatternGetHasRegExpGroups, (JSC::JSGlobalObject * global_object, JSC::CallFrame* frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* object = requireURLPattern(global_object, scope, frame->thisValue());
        if (!object)
            return {};
        return JSValue::encode(JSC::jsBoolean(object->pattern().hasRegExpGroups()));
    }

    static bool readExecInput(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::CallFrame* call_frame,
        std::optional<WebCore::URLPattern::URLPatternInput>& input, String& base_url)
    {
        if (!call_frame->argument(0).isUndefined()) {
            WebCore::URLPattern::URLPatternInput parsed { String {} };
            if (!readURLPatternInput(global_object, scope, call_frame->argument(0), parsed))
                return false;
            RETURN_IF_EXCEPTION(scope, false);
            input = WTF::move(parsed);
        }

        if (!call_frame->argument(1).isUndefined()) {
            base_url = toWebApiUSVString(valueToWebApiString(global_object, scope, call_frame->argument(1)));
            RETURN_IF_EXCEPTION(scope, false);
        }
        return true;
    }

    JSC_DEFINE_HOST_FUNCTION(urlPatternTest, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* object = requireURLPattern(global_object, scope, call_frame->thisValue());
        if (!object)
            return {};

        std::optional<WebCore::URLPattern::URLPatternInput> input;
        String base_url;
        if (!readExecInput(global_object, scope, call_frame, input, base_url))
            return {};
        if (auto& fast_pathname = object->fastPathname()) {
            if (auto matched = tryFastPathnameTest(*fast_pathname, input, base_url))
                return JSValue::encode(JSC::jsBoolean(*matched));
        }
        WebCore::ScriptExecutionContext context(global_object);
        auto result = object->pattern().test(context, WTF::move(input), WTF::move(base_url));
        RETURN_IF_EXCEPTION(scope, {});
        if (result.hasException())
            return throwURLPatternException(global_object, scope, result.releaseException());
        return JSValue::encode(JSC::jsBoolean(result.releaseReturnValue()));
    }

    JSC_DEFINE_HOST_FUNCTION(urlPatternExec, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* object = requireURLPattern(global_object, scope, call_frame->thisValue());
        if (!object)
            return {};

        std::optional<WebCore::URLPattern::URLPatternInput> input;
        String base_url;
        if (!readExecInput(global_object, scope, call_frame, input, base_url))
            return {};
        if (auto& fast_pathname = object->fastPathname()) {
            if (auto match = tryFastPathnameExec(*fast_pathname, input, base_url)) {
                auto* value = createURLPatternResult(global_object, scope, *match);
                RETURN_IF_EXCEPTION(scope, {});
                return JSValue::encode(value);
            }
        }
        WebCore::ScriptExecutionContext context(global_object);
        auto result = object->pattern().exec(context, WTF::move(input), WTF::move(base_url));
        RETURN_IF_EXCEPTION(scope, {});
        if (result.hasException())
            return throwURLPatternException(global_object, scope, result.releaseException());
        auto match = result.releaseReturnValue();
        if (!match)
            return JSValue::encode(JSC::jsNull());
        auto* value = createURLPatternResult(global_object, scope, *match);
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(value);
    }

} // namespace

void installWebApiURLPattern(Collo::GlobalObject* global_object, JSC::VM& vm)
{
    constexpr unsigned enumerableAccessor = static_cast<unsigned>(JSC::PropertyAttribute::Accessor);
    constexpr unsigned enumerableFunction = static_cast<unsigned>(JSC::PropertyAttribute::None);

    auto* prototype = JSC::constructEmptyObject(global_object);
    auto* constructor = JSC::JSFunction::create(vm, global_object, 0, "URLPattern"_s, urlPatternConstructorCall,
        JSC::ImplementationVisibility::Public, JSC::NoIntrinsic, urlPatternConstructorConstruct, nullptr);
    RELEASE_ASSERT(constructor);
    constructor->putDirect(vm, vm.propertyNames->prototype, prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    prototype->putDirect(
        vm, vm.propertyNames->constructor, constructor, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));

    putWebApiAccessor(global_object, prototype, vm, "protocol"_s, urlPatternGetProtocol, nullptr, enumerableAccessor);
    putWebApiAccessor(global_object, prototype, vm, "username"_s, urlPatternGetUsername, nullptr, enumerableAccessor);
    putWebApiAccessor(global_object, prototype, vm, "password"_s, urlPatternGetPassword, nullptr, enumerableAccessor);
    putWebApiAccessor(global_object, prototype, vm, "hostname"_s, urlPatternGetHostname, nullptr, enumerableAccessor);
    putWebApiAccessor(global_object, prototype, vm, "port"_s, urlPatternGetPort, nullptr, enumerableAccessor);
    putWebApiAccessor(global_object, prototype, vm, "pathname"_s, urlPatternGetPathname, nullptr, enumerableAccessor);
    putWebApiAccessor(global_object, prototype, vm, "search"_s, urlPatternGetSearch, nullptr, enumerableAccessor);
    putWebApiAccessor(global_object, prototype, vm, "hash"_s, urlPatternGetHash, nullptr, enumerableAccessor);
    putWebApiAccessor(
        global_object, prototype, vm, "hasRegExpGroups"_s, urlPatternGetHasRegExpGroups, nullptr, enumerableAccessor);
    putWebApiFunction(global_object, prototype, vm, "test"_s, 0, urlPatternTest, enumerableFunction);
    putWebApiFunction(global_object, prototype, vm, "exec"_s, 0, urlPatternExec, enumerableFunction);
    prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol, JSC::jsString(vm, String("URLPattern"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    auto* structure = JSColloURLPattern::createStructure(vm, global_object, prototype);
    auto& cache = global_object->webApiCache();
    cache.url_pattern_constructor.set(vm, constructor);
    cache.url_pattern_prototype.set(vm, prototype);
    cache.url_pattern_structure.set(vm, structure);

    global_object->putDirect(vm, JSC::Identifier::fromString(vm, "URLPattern"_s), constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    RELEASE_ASSERT(global_object->getDirect(vm, JSC::Identifier::fromString(vm, "URLPattern"_s)));
}

} // namespace Collo::HostFunctions

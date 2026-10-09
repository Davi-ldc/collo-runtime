/*
 * Copyright (C) 2024 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "URLPatternComponent.h"

#include "ExceptionOr.h"
#include "URLPatternCanonical.h"
#include "URLPatternParser.h"
#include "URLPatternResult.h"
#include <JavaScriptCore/RegExp.h>
#include <JavaScriptCore/YarrFlags.h>
#include <wtf/text/StringImpl.h>

#include <limits>

namespace WebCore {
using namespace JSC;
namespace URLPatternUtilities {

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

// Defense-in-depth against ReDoS (https://urlpattern.spec.whatwg.org/ allows
// arbitrary regex groups via `(...)` / `:name(...)`). The Yarr interpreter only
// bounds a runaway match by a hard iteration ceiling (Yarr::matchLimit, 100M),
// which can still burn ~1s of CPU per hostile match, and it cannot be
// interrupted by the runtime's cross-thread termination trap (Yarr does not
// poll VM traps mid-match). We therefore reject the structural signature of
// catastrophic (exponential) backtracking up front: an unbounded quantifier
// (`*`, `+`, `{n,}`) applied to a sub-expression that itself contains an
// unbounded quantifier, e.g. `(a+)+`, `(.*)*`, `(\d+){2,}`, `a**`.
//
// Only the user-controlled regex group source is scanned; Collo-generated parts
// (FixedText / SegmentWildcard / FullWildcard) are trusted and skipped. This is
// a conservative over-approximation: it can reject a small number of pathologic
// but technically-linear patterns, which is the correct trade-off for an
// untrusted, per-request matcher. A fully interruptible time budget additionally
// requires the VM-side watchdog wiring documented for the runtime owner.
static bool quantifierIsUnbounded(StringView source, size_t quantifierIndex)
{
    char16_t character = source[quantifierIndex];
    if (character == '*' || character == '+')
        return true;
    if (character != '{')
        return false;

    // `{n}` and `{n,m}` are bounded; only `{n,}` (open upper bound) is unbounded.
    size_t index = quantifierIndex + 1;
    bool sawComma = false;
    bool sawUpperBoundDigit = false;
    while (index < source.length()) {
        char16_t inner = source[index];
        if (inner == '}')
            break;
        if (inner == ',')
            sawComma = true;
        else if (sawComma && inner >= '0' && inner <= '9')
            sawUpperBoundDigit = true;
        ++index;
    }
    return sawComma && !sawUpperBoundDigit;
}

// True if the source contains any unbounded quantifier at all (outside a
// character class). Used together with an unbounded part modifier, which wraps
// the whole value in an outer unbounded repetition and thus creates nesting.
static bool regexSourceHasAnyUnboundedQuantifier(StringView source)
{
    for (size_t index = 0; index < source.length(); ++index) {
        char16_t character = source[index];
        if (character == '\\') {
            ++index;
            continue;
        }
        if (character == '[') {
            ++index;
            while (index < source.length() && source[index] != ']') {
                if (source[index] == '\\')
                    ++index;
                ++index;
            }
            continue;
        }
        if (quantifierIsUnbounded(source, index))
            return true;
    }
    return false;
}

static bool regexSourceHasNestedUnboundedQuantifier(StringView source)
{
    // Tracks, per open group, whether an unbounded quantifier has appeared
    // inside it. When a group closes and is itself immediately quantified
    // unbounded, an inner unbounded quantifier means exponential backtracking.
    // Unbounded quantifiers at the top level (outside any group) cannot nest, so
    // they are intentionally ignored.
    Vector<bool, 8> groupHasUnbounded;

    auto markCurrentScope = [&] {
        if (!groupHasUnbounded.isEmpty())
            groupHasUnbounded.last() = true;
    };

    for (size_t index = 0; index < source.length(); ++index) {
        char16_t character = source[index];

        if (character == '\\') {
            ++index; // Skip the escaped character; it cannot open a group or quantify.
            continue;
        }

        if (character == '[') {
            // Character class: quantifiers inside are literal, skip to the close.
            ++index;
            while (index < source.length() && source[index] != ']') {
                if (source[index] == '\\')
                    ++index;
                ++index;
            }
            continue;
        }

        if (character == '(') {
            groupHasUnbounded.append(false);
            continue;
        }

        if (character == ')') {
            bool innerHasUnbounded = false;
            if (!groupHasUnbounded.isEmpty()) {
                innerHasUnbounded = groupHasUnbounded.last();
                groupHasUnbounded.removeLast();
            }

            // Look at the quantifier (if any) applied to this group.
            size_t quantifierIndex = index + 1;
            if (quantifierIndex < source.length() && quantifierIsUnbounded(source, quantifierIndex)) {
                if (innerHasUnbounded)
                    return true;
                // The group as a whole is now an unbounded repetition within its
                // enclosing scope.
                markCurrentScope();
            } else if (innerHasUnbounded) {
                // Propagate the inner unbounded quantifier outward even without a
                // group-level quantifier, so `((a+))+` is still caught.
                markCurrentScope();
            }
            continue;
        }

        if (quantifierIsUnbounded(source, index)) {
            // A quantifier directly stacked on another unbounded quantifier
            // (e.g. `a**`, `a+*`, `a++`) is also catastrophic.
            if (index > 0) {
                char16_t previous = source[index - 1];
                if (previous == '*' || previous == '+')
                    return true;
            }
            markCurrentScope();
        }
    }

    return false;
}

URLPatternComponent::URLPatternComponent(String&& patternString, JSC::Strong<JSC::RegExp>&& regex, Vector<String>&& groupNameList, bool hasRegexpGroupsFromPartsList, bool isFullWildcard)
    : m_patternString(WTF::move(patternString))
    , m_regularExpression(WTF::move(regex))
    , m_groupNameList(WTF::move(groupNameList))
    , m_hasRegexGroupsFromPartList(hasRegexpGroupsFromPartsList)
    , m_isFullWildcard(isFullWildcard)
{
}

size_t URLPatternComponent::externalMemoryCost() const
{
    size_t cost = stringMemoryCost(m_patternString);
    cost = saturatingAdd(cost, saturatingMultiply(m_groupNameList.capacity(), sizeof(String)));
    for (auto& group_name : m_groupNameList)
        cost = saturatingAdd(cost, stringMemoryCost(group_name));
    return cost;
}

// https://urlpattern.spec.whatwg.org/#compile-a-component
ExceptionOr<URLPatternComponent> URLPatternComponent::compile(Ref<JSC::VM> vm, StringView input, EncodingCallbackType type, const URLPatternStringOptions& options)
{
    auto maybePartList = URLPatternParser::parse(input, options, type);
    if (maybePartList.hasException())
        return maybePartList.releaseException();
    Vector<Part> partList = maybePartList.releaseReturnValue();

    // Reject user regex groups whose structure causes catastrophic backtracking
    // before they ever reach the (un-interruptible) Yarr matcher. Only Regexp
    // parts carry untrusted source; the other part types are generated by Collo.
    // A part is dangerous when its value already nests unbounded quantifiers, or
    // when an unbounded part modifier (`+` / `*`) wraps a value that itself has
    // an unbounded quantifier (the generated regex repeats that value, so e.g.
    // `(a+)+` and `(a+)*` collapse to the same exponential shape).
    for (auto& part : partList) {
        if (part.type != PartType::Regexp)
            continue;
        bool modifierIsUnbounded = part.modifier == Modifier::ZeroOrMore || part.modifier == Modifier::OneOrMore;
        if (regexSourceHasNestedUnboundedQuantifier(part.value)
            || (modifierIsUnbounded && regexSourceHasAnyUnboundedQuantifier(part.value)))
            return Exception { ExceptionCode::TypeError, "URLPattern regex group has nested unbounded quantifiers that risk catastrophic backtracking."_s };
    }

    auto [regularExpressionString, nameList] = generateRegexAndNameList(partList, options);

    OptionSet<JSC::Yarr::Flags> flags = { JSC::Yarr::Flags::UnicodeSets };
    if (options.ignoreCase)
        flags.add(JSC::Yarr::Flags::IgnoreCase);

    JSC::RegExp* regularExpression = JSC::RegExp::create(vm, regularExpressionString, flags);
    if (!regularExpression->isValid())
        return Exception { ExceptionCode::TypeError, "Unable to create RegExp object regular expression from provided URLPattern string."_s };

    String patternString = generatePatternString(partList, options);

    bool hasRegexGroups = partList.containsIf([](auto& part) {
        return part.type == PartType::Regexp;
    });

    // A component is a shareable full wildcard when its only part is an unnamed,
    // unmodified, unprefixed FullWildcard. Such components always compile to the
    // identical `^(.*)$` regex, so compileAllComponents() can reuse one across
    // the pattern's default-wildcard components.
    bool isFullWildcard = partList.size() == 1
        && partList[0].type == PartType::FullWildcard
        && partList[0].modifier == Modifier::None
        && partList[0].prefix.isEmpty()
        && partList[0].suffix.isEmpty();

    return URLPatternComponent { WTF::move(patternString), JSC::Strong<JSC::RegExp> { vm, regularExpression }, WTF::move(nameList), hasRegexGroups, isFullWildcard };
}

// https://urlpattern.spec.whatwg.org/#protocol-component-matches-a-special-scheme
bool URLPatternComponent::matchSpecialSchemeProtocol(JSC::JSGlobalObject* globalObject) const
{
    static constexpr std::array specialSchemeList { "ftp"_s, "file"_s, "http"_s, "https"_s, "ws"_s, "wss"_s };

    auto* regExp = m_regularExpression.get();
    for (auto scheme : specialSchemeList) {
        if (regExp->match(globalObject, scheme, 0))
            return true;
    }
    return false;
}

// Implements both "regexp matching" and "create a component match result":
// https://urlpattern.spec.whatwg.org/#create-a-component-match-result
std::optional<URLPatternComponentResult> URLPatternComponent::componentMatch(JSC::JSGlobalObject* globalObject, String&& input) const
{
    auto* regExp = m_regularExpression.get();
    unsigned numSubpatterns = regExp->numSubpatterns();
    Vector<int> ovector;
    ovector.grow((numSubpatterns + 1) * 2);
    int position = regExp->match(globalObject, input, 0, ovector);
    if (position < 0)
        return std::nullopt;

    URLPatternComponentResult::GroupsRecord groups;
    groups.reserveInitialCapacity(numSubpatterns);
    for (unsigned i = 1; i <= numSubpatterns; ++i) {
        int start = ovector[i * 2];
        int end = ovector[i * 2 + 1];

        Variant<std::monostate, String> value;
        if (start >= 0)
            value = input.substring(start, end - start);

        size_t groupIndex = i - 1;
        String groupName = groupIndex < m_groupNameList.size() ? m_groupNameList[groupIndex] : emptyString();
        groups.append(URLPatternComponentResult::NameMatchPair { WTF::move(groupName), WTF::move(value) });
    }

    return URLPatternComponentResult { !input.isEmpty() ? WTF::move(input) : emptyString(), WTF::move(groups) };
}

}
}

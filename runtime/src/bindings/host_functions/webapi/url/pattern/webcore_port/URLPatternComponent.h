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

#pragma once

#include <JavaScriptCore/Strong.h>
#include <JavaScriptCore/StrongInlines.h>
#include <cstddef>
#include <optional>

namespace JSC {
class RegExp;
class VM;
class JSGlobalObject;
}

namespace WebCore {

struct URLPatternComponentResult;
enum class EncodingCallbackType : uint8_t;
template<typename> class ExceptionOr;

namespace URLPatternUtilities {
struct URLPatternStringOptions;

class URLPatternComponent {
public:
    static ExceptionOr<URLPatternComponent> compile(Ref<JSC::VM>, StringView, EncodingCallbackType, const URLPatternStringOptions&);

    // True when this component's source is the bare full wildcard ("*"), which
    // every component type compiles to the identical `^(.*)$` regex regardless
    // of delimiter or encoding. compileAllComponents() uses this to share a
    // single Strong<RegExp> across the (commonly 7) default-wildcard components
    // of a pattern instead of re-generating and re-looking-up the same regex.
    bool isFullWildcard() const { return m_isFullWildcard; }

    const String& patternString() const { return m_patternString; }
    size_t externalMemoryCost() const;
    bool hasRegexGroupsFromPartList() const { return m_hasRegexGroupsFromPartList; }
    bool matchSpecialSchemeProtocol(JSC::JSGlobalObject*) const;
    std::optional<URLPatternComponentResult> componentMatch(JSC::JSGlobalObject*, String&& input) const;
    URLPatternComponent() = default;

private:
    URLPatternComponent(String&&, JSC::Strong<JSC::RegExp>&&, Vector<String>&&, bool, bool isFullWildcard = false);

    String m_patternString;
    // This Strong cannot leak the URLPattern that holds it. A RegExp cell
    // traces one cell edge: the named-groups Structure that a JS RegExp
    // sharing it through the VM's RegExp cache installs when it builds a
    // match result. That Structure reaches its realm's global object, which
    // ColloVm protects until destroyVmContents, so any path back to this
    // component runs through a root that already outlives it.
    JSC::Strong<JSC::RegExp> m_regularExpression;
    Vector<String> m_groupNameList;
    bool m_hasRegexGroupsFromPartList { false };
    bool m_isFullWildcard { false };
};

}
}

#pragma once

#include <JavaScriptCore/JSGlobalObject.h>
// URLPatternComponent holds a compiled RegExp, and ExceptionOr<> needs the type
// complete to answer its own traits. Only a forward declaration reaches here
// otherwise, via StringReplaceCache.h.
#include <JavaScriptCore/RegExp.h>
#include <JavaScriptCore/VM.h>
#include <wtf/Forward.h>
#include <wtf/Ref.h>
#include <wtf/RefPtr.h>
#include <wtf/StdLibExtras.h>
#include <wtf/URL.h>
#include <wtf/Vector.h>
#include <wtf/text/ASCIILiteral.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/StringToIntegerConversion.h>
#include <wtf/text/StringView.h>
#include <wtf/text/WTFString.h>

#include <array>
#include <limits>
#include <optional>
#include <ranges>
#include <utility>
#include <variant>

#ifndef WEBCORE_EXPORT
#define WEBCORE_EXPORT
#endif

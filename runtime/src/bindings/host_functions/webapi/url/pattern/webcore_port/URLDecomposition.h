#pragma once

#include "root.h"

namespace WebCore {

class URLDecomposition {
public:
    static std::optional<std::optional<uint16_t>> parsePort(WTF::StringView string, WTF::StringView protocol)
    {
        uint32_t port { 0 };
        bool foundDigit = false;
        for (size_t i = 0; i < string.length(); ++i) {
            auto c = string[i];
            if (c == 0x0009 || c == 0x000A || c == 0x000D)
                continue;
            if (isASCIIDigit(c)) {
                port = port * 10 + c - '0';
                foundDigit = true;
                if (port > std::numeric_limits<uint16_t>::max())
                    return std::nullopt;
                continue;
            }
            if (!foundDigit)
                return std::nullopt;
            break;
        }
        if (!foundDigit || WTF::isDefaultPortForProtocol(static_cast<uint16_t>(port), protocol))
            return std::optional<uint16_t> { std::nullopt };
        return { { static_cast<uint16_t>(port) } };
    }
};

} // namespace WebCore


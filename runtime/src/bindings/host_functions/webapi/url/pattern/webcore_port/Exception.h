#pragma once

#include "ExceptionCode.h"

namespace WebCore {

class Exception {
public:
    explicit Exception(ExceptionCode code, WTF::String message = { })
        : m_code(code)
        , m_message(WTF::move(message))
    {
    }

    ExceptionCode code() const { return m_code; }
    const WTF::String& message() const { return m_message; }
    WTF::String&& releaseMessage() { return WTF::move(m_message); }

private:
    ExceptionCode m_code;
    WTF::String m_message;
};

} // namespace WebCore


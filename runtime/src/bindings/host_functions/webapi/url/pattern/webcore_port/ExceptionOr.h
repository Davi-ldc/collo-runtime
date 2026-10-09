#pragma once

#include "Exception.h"

namespace WebCore {

template<typename T> class [[nodiscard]] ExceptionOr {
public:
    using ReturnType = T;

    ExceptionOr(Exception&& exception)
        : m_has_exception(true)
        , m_exception(WTF::move(exception))
    {
    }

    ExceptionOr(ReturnType&& returnValue)
        : m_value(WTF::move(returnValue))
    {
    }

    ExceptionOr(const ReturnType& returnValue)
        : m_value(returnValue)
    {
    }

    template<typename OtherType>
    ExceptionOr(const OtherType& returnValue, typename std::enable_if<std::is_scalar<OtherType>::value && std::is_convertible<OtherType, ReturnType>::value>::type* = nullptr)
        : m_value(static_cast<ReturnType>(returnValue))
    {
    }

    bool hasException() const { return m_has_exception; }
    const Exception& exception() const { return m_exception; }
    Exception releaseException() { return WTF::move(m_exception); }
    const ReturnType& returnValue() const { return *m_value; }
    ReturnType releaseReturnValue() { return WTF::move(*m_value); }

private:
    bool m_has_exception { false };
    std::optional<ReturnType> m_value;
    Exception m_exception { ExceptionCode::TypeError };
};

template<> class ExceptionOr<void> {
public:
    using ReturnType = void;

    ExceptionOr(Exception&& exception)
        : m_has_exception(true)
        , m_exception(WTF::move(exception))
    {
    }

    ExceptionOr() = default;

    bool hasException() const { return m_has_exception; }
    const Exception& exception() const { return m_exception; }
    Exception releaseException() { return WTF::move(m_exception); }

private:
    bool m_has_exception { false };
    Exception m_exception { ExceptionCode::TypeError };
};

template<typename T> inline constexpr bool IsExceptionOr = WTF::IsTemplate<std::decay_t<T>, ExceptionOr>::value;

template<typename T, bool isExceptionOr = IsExceptionOr<T>> struct TypeOrExceptionOrUnderlyingTypeImpl;

template<typename T> struct TypeOrExceptionOrUnderlyingTypeImpl<T, true> {
    using Type = typename T::ReturnType;
};

template<typename T> struct TypeOrExceptionOrUnderlyingTypeImpl<T, false> {
    using Type = T;
};

template<typename T> using TypeOrExceptionOrUnderlyingType = typename TypeOrExceptionOrUnderlyingTypeImpl<T>::Type;

} // namespace WebCore

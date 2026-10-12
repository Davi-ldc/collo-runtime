// BasicSecretBytes, the one container for secret bytes in the WebCrypto bridge: a key's material, every buffer a key
// passes through on import, export and wrap, decrypted plaintext and derived bits. Zeroing is a property of the type,
// not a duty of each caller, so no early return can skip it:
// - every buffer it frees is zeroed over its whole capacity first, on destruction, `clear`, move assignment and growth;
// - growth allocates exactly the capacity asked for, copies, then zeroes and frees the old buffer, so a reallocation
//   leaves no stale copy behind; nothing grows geometrically, so a caller that appends piecewise reserves the exact
//   total first;
// - bytes added by `tryGrow` start zeroed, and bytes `shrink` drops are zeroed at once;
// - it moves but never copies.
//
// `Allocator` supplies `static uint8_t* tryAllocate(size_t)`, which returns null on failure, and
// `static void deallocate(uint8_t*, size_t capacity)`. The bridge's `SecretBytes` (types.h) allocates from fastMalloc;
// a test can pass an allocator that checks every buffer it frees is all zeros. The header includes nothing from JSC
// or WTF, so crypto pool threads and test shims use it freely.

#pragma once

#include <openssl/mem.h>

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <span>
#include <utility>

namespace Collo::HostFunctions::WebCrypto {

template <typename Allocator> class BasicSecretBytes {
public:
    BasicSecretBytes() = default;
    BasicSecretBytes(const BasicSecretBytes&) = delete;
    BasicSecretBytes& operator=(const BasicSecretBytes&) = delete;

    BasicSecretBytes(BasicSecretBytes&& other) noexcept
        : m_data(std::exchange(other.m_data, nullptr))
        , m_size(std::exchange(other.m_size, 0))
        , m_capacity(std::exchange(other.m_capacity, 0))
    {
    }

    BasicSecretBytes& operator=(BasicSecretBytes&& other) noexcept
    {
        if (this != &other) {
            clear();
            m_data = std::exchange(other.m_data, nullptr);
            m_size = std::exchange(other.m_size, 0);
            m_capacity = std::exchange(other.m_capacity, 0);
        }
        return *this;
    }

    ~BasicSecretBytes() { clear(); }

    size_t size() const { return m_size; }
    size_t capacity() const { return m_capacity; }
    bool isEmpty() const { return !m_size; }
    uint8_t* data() { return m_data; }
    const uint8_t* data() const { return m_data; }
    std::span<const uint8_t> span() const { return { m_data, m_size }; }
    std::span<uint8_t> mutableSpan() { return { m_data, m_size }; }

    // Makes the capacity at least `capacity`, reallocating to exactly that much. On failure it returns false and
    // leaves the bytes as they were.
    bool tryReserveCapacity(size_t capacity)
    {
        if (capacity <= m_capacity)
            return true;
        uint8_t* data = Allocator::tryAllocate(capacity);
        if (!data)
            return false;
        if (m_size)
            std::memcpy(data, m_data, m_size);
        releaseBuffer();
        m_data = data;
        m_capacity = capacity;
        return true;
    }

    // Grows the size to `size`, which must not be less than the current size, with the new bytes zero. Fails, and
    // changes nothing, when `size` is smaller or the buffer cannot grow.
    bool tryGrow(size_t size)
    {
        if (size < m_size)
            return false;
        if (!tryReserveCapacity(size))
            return false;
        if (size > m_size)
            std::memset(m_data + m_size, 0, size - m_size);
        m_size = size;
        return true;
    }

    // `bytes` must not point into this buffer, which a reallocation would free.
    bool tryAppend(std::span<const uint8_t> bytes)
    {
        if (bytes.empty())
            return true;
        if (bytes.size() > std::numeric_limits<size_t>::max() - m_size)
            return false;
        if (!tryReserveCapacity(m_size + bytes.size()))
            return false;
        std::memcpy(m_data + m_size, bytes.data(), bytes.size());
        m_size += bytes.size();
        return true;
    }

    // Drops the bytes past `size`, zeroing them; the capacity stays. A `size` at or past the current size does
    // nothing.
    void shrink(size_t size)
    {
        if (size >= m_size)
            return;
        OPENSSL_cleanse(m_data + size, m_size - size);
        m_size = size;
    }

    // Zeroes and frees the buffer.
    void clear()
    {
        releaseBuffer();
        m_size = 0;
    }

private:
    void releaseBuffer()
    {
        if (!m_data)
            return;
        OPENSSL_cleanse(m_data, m_capacity);
        Allocator::deallocate(m_data, m_capacity);
        m_data = nullptr;
        m_capacity = 0;
    }

    uint8_t* m_data { nullptr };
    size_t m_size { 0 };
    size_t m_capacity { 0 };
};

} // namespace Collo::HostFunctions::WebCrypto

// Test-only harness for BasicSecretBytes (runtime/src/bindings/host_functions/webapi/crypto/secret_bytes.h), linked
// into the aggregate test binary and called through `runSecretBytesScenarios` in `root.zig` in this directory. It
// instantiates the type with an allocator that fills each new buffer with nonzero bytes, records it, and checks on
// each free that the buffer is all zeros and is freed at the size it was allocated at. The scenarios drive every path
// that frees or reuses a buffer: growth, shrinking, moves, clear, a failed allocation and destruction.
//
// Runs on the calling thread. The recorder is reset at the start of each call, so calls must not overlap.

#include "host_functions/webapi/crypto/secret_bytes.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <span>
#include <utility>

namespace {

using Collo::HostFunctions::WebCrypto::BasicSecretBytes;

// Enough for the most buffers the scenarios hold at once.
constexpr size_t live_buffers_max = 8;
// A freshly allocated buffer holds this byte, so a byte the type neither wrote nor zeroed is visible.
constexpr uint8_t uninitialized_byte = 0xA5;
constexpr uint8_t secret_byte = 0xFF;

struct LiveBuffer {
    uint8_t* data;
    size_t size;
};

struct Recorder {
    std::array<LiveBuffer, live_buffers_max> live;
    uint64_t allocations;
    uint64_t frees;
    uint64_t nonzero_frees;
    uint64_t mismatched_frees;
    uint64_t failed_checks;
    uint64_t first_failed_line;
    bool fail_next_allocation;
};

constinit Recorder recorder {};

void check(bool condition, uint64_t line)
{
    if (condition)
        return;
    if (!recorder.failed_checks)
        recorder.first_failed_line = line;
    ++recorder.failed_checks;
}

#define SECRET_BYTES_CHECK(condition) check((condition), __LINE__)

struct RecordingAllocator {
    static uint8_t* tryAllocate(size_t size)
    {
        if (recorder.fail_next_allocation) {
            recorder.fail_next_allocation = false;
            return nullptr;
        }
        for (auto& buffer : recorder.live) {
            if (buffer.data)
                continue;
            auto* data = static_cast<uint8_t*>(std::malloc(size));
            if (!data)
                return nullptr;
            std::memset(data, uninitialized_byte, size);
            buffer = { data, size };
            ++recorder.allocations;
            return data;
        }
        SECRET_BYTES_CHECK(false);
        return nullptr;
    }

    static void deallocate(uint8_t* data, size_t size)
    {
        ++recorder.frees;
        bool known = false;
        for (auto& buffer : recorder.live) {
            if (buffer.data != data)
                continue;
            known = true;
            if (buffer.size != size)
                ++recorder.mismatched_frees;
            buffer = { nullptr, 0 };
            break;
        }
        if (!known)
            ++recorder.mismatched_frees;
        for (size_t index = 0; index < size; ++index) {
            if (data[index]) {
                ++recorder.nonzero_frees;
                break;
            }
        }
        std::free(data);
    }
};

using TestSecretBytes = BasicSecretBytes<RecordingAllocator>;

bool allEqual(std::span<const uint8_t> bytes, uint8_t value)
{
    for (uint8_t byte : bytes) {
        if (byte != value)
            return false;
    }
    return true;
}

void runScenarios()
{
    std::array<uint8_t, 48> secret {};
    secret.fill(secret_byte);
    const std::span<const uint8_t> secret_span { secret.data(), secret.size() };

    {
        TestSecretBytes bytes;
        // Each append past the capacity reallocates to the exact size and zeroes the buffer it leaves.
        SECRET_BYTES_CHECK(bytes.tryAppend(secret_span.first(16)));
        SECRET_BYTES_CHECK(bytes.capacity() == 16);
        SECRET_BYTES_CHECK(bytes.tryAppend(secret_span.subspan(16, 16)));
        SECRET_BYTES_CHECK(bytes.size() == 32);
        SECRET_BYTES_CHECK(bytes.capacity() == 32);
        SECRET_BYTES_CHECK(allEqual(bytes.span(), secret_byte));

        // Growth past the capacity copies the secret and zeroes the old buffer; the added bytes start zeroed.
        SECRET_BYTES_CHECK(bytes.tryGrow(40));
        SECRET_BYTES_CHECK(bytes.capacity() == 40);
        SECRET_BYTES_CHECK(allEqual(bytes.span().first(32), secret_byte));
        SECRET_BYTES_CHECK(allEqual(bytes.span().subspan(32), 0));
        SECRET_BYTES_CHECK(!bytes.tryGrow(39));
        SECRET_BYTES_CHECK(bytes.size() == 40);

        // Shrinking zeroes the dropped bytes at once and keeps the buffer.
        bytes.shrink(8);
        SECRET_BYTES_CHECK(bytes.size() == 8);
        SECRET_BYTES_CHECK(bytes.capacity() == 40);
        SECRET_BYTES_CHECK(allEqual(std::span<const uint8_t> { bytes.data() + 8, bytes.capacity() - 8 }, 0));

        // A reservation is exact, and growth within it does not reallocate.
        SECRET_BYTES_CHECK(bytes.tryReserveCapacity(64));
        SECRET_BYTES_CHECK(bytes.capacity() == 64);
        const uint64_t allocations_before_append = recorder.allocations;
        SECRET_BYTES_CHECK(bytes.tryAppend(secret_span.first(40)));
        SECRET_BYTES_CHECK(recorder.allocations == allocations_before_append);
        SECRET_BYTES_CHECK(bytes.size() == 48);

        // A failed allocation leaves the bytes as they were.
        recorder.fail_next_allocation = true;
        SECRET_BYTES_CHECK(!bytes.tryAppend(secret_span));
        SECRET_BYTES_CHECK(bytes.size() == 48);
        SECRET_BYTES_CHECK(allEqual(bytes.span(), secret_byte));

        // A move takes the buffer without copying it and leaves the source empty.
        TestSecretBytes moved(std::move(bytes));
        SECRET_BYTES_CHECK(bytes.isEmpty());
        SECRET_BYTES_CHECK(!bytes.capacity());
        SECRET_BYTES_CHECK(moved.size() == 48);

        // Move assignment zeroes the buffer it overwrites.
        TestSecretBytes target;
        SECRET_BYTES_CHECK(target.tryAppend(secret_span.first(24)));
        target = std::move(moved);
        SECRET_BYTES_CHECK(target.size() == 48);
        SECRET_BYTES_CHECK(moved.isEmpty());

        // Clear zeroes and frees the whole capacity.
        target.clear();
        SECRET_BYTES_CHECK(target.isEmpty());
        SECRET_BYTES_CHECK(!target.capacity());

        // Destruction zeroes what is left.
        SECRET_BYTES_CHECK(target.tryAppend(secret_span));
        SECRET_BYTES_CHECK(bytes.tryAppend(secret_span.first(1)));
    }

    for (const auto& buffer : recorder.live)
        SECRET_BYTES_CHECK(!buffer.data);
}

} // namespace

// The layout `SecretBytesReport` in root.zig mirrors.
struct collo_test_secret_bytes_report {
    uint64_t allocations;
    uint64_t frees;
    uint64_t nonzero_frees;
    uint64_t mismatched_frees;
    uint64_t failed_checks;
    uint64_t first_failed_line;
};

static_assert(sizeof(collo_test_secret_bytes_report) == 48, "SecretBytesReport in root.zig mirrors this layout");

extern "C" void collo_test_secret_bytes_run(collo_test_secret_bytes_report* out)
{
    recorder = {};
    runScenarios();
    *out = {
        recorder.allocations,
        recorder.frees,
        recorder.nonzero_frees,
        recorder.mismatched_frees,
        recorder.failed_checks,
        recorder.first_failed_line,
    };
}

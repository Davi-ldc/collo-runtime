// The module loader: registers module packs, resolves import specifiers to registry keys, hands JSC the source of a
// registered key, refuses every other key as a module not found, and evaluates modules for the host. Runs on the VM
// thread with the JSC API lock held.
//
// Sources belong to the VM and every realm fetches from them, while each realm's JSC module registry holds its own
// module records: a module evaluates once per realm that imports it, with top-level state of its own there.
//
// A pack arrives as a mapping of a sealed memfd that every worker of a definition maps. Registration checks every
// offset before reading through it and changes no state until the whole pack is accepted; afterwards the
// SourceProviders read the mapping in place, and it is released when the last of them dies, or on return when none
// kept it. The pack layout and specifier hash are defined in common/ipc/module_pack.zig, and the copies here must
// match that file.

#include "jsc/runtime/state.h"

#include <JavaScriptCore/CachedBytecode.h>
#include <JavaScriptCore/JSNativeStdFunction.h>
#include <JavaScriptCore/SourceProvider.h>
#include <wtf/FastMalloc.h>
#include <wtf/MallocSpan.h>
#include <wtf/SIMDUTF.h>
#include <wtf/Vector.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/StringView.h>

#include <cstring>
#include <limits>
#include <new>
#include <span>
#include <utility>

using namespace JSC;

namespace {

// The pack format of common/ipc/module_pack.zig: `magic`, `version`, `max_module_count` and the sizes of Header,
// ModuleRecord, DependencyRecord and IndexEntry.
constexpr uint32_t modulePackMagic = 0x4d4f4c43;
constexpr uint16_t modulePackVersion = 2;
constexpr size_t modulePackHeaderSize = 60;
constexpr size_t modulePackRecordSize = 48;
constexpr size_t modulePackDependencyRecordSize = 16;
constexpr size_t modulePackIndexEntrySize = 8;
constexpr size_t modulePackMaxModules = 4096;
constexpr size_t modulePackMaxBytes = COLLO_MODULE_PACK_MAX_BYTES;
constexpr uint32_t emptyModulePackIndex = UINT32_MAX;
constexpr auto builtinNodeFsModuleKey = "node:fs"_s;
constexpr auto builtinNodeFsPromisesModuleKey = "node:fs/promises"_s;
constexpr auto routeModulePrefix = "/__collo_route/"_s;
// Deployed modules are registered and resolved under internal transport keys, /__collo_route/<d>/<p>, where <d> is
// the deploy hash, which the server sets to the worker definition's name, and <p> names one file of the deploy's
// output. Every surface tenant code sees, meaning import.meta, stack frames and loader error text, uses the public
// /var/task namespace instead, the worker filesystem's `deploy_root` in worker/fs/index.zig, so
// path.join(import.meta.dirname, ...) lands on real deploy files. The two spellings map one to one:
//   to public:    /__collo_route/<d>/<p> -> /var/task/<p>
//   to transport: /var/task/<p> -> /__collo_route/<d>/<p>
// The first deploy-scoped pack pins <d> for the VM, and registerModulePackLocked fails closed on a second hash.
//
// Relative specifiers resolve in transport space against the transport referrer. The keys keep the deploy's directory
// layout, so the result matches Node ESM resolution in the public space against the referrer's import.meta.dirname,
// which is what tenant code relies on. A change to the key layout, or to how a deploy splits into modules, must
// preserve that instead of giving relative imports a resolution scheme of their own.
constexpr auto publicTaskRootPrefix = "/var/task/"_s;
constexpr auto fileUrlPrefix = "file://"_s;
// The zygote's own namespace, used by the warmup corpus. Evicting a module here does not purge JSC's module
// registry, so the record every worker inherits through copy-on-write stays addressable; only an evaluation the host
// starts, with an empty referrer, may resolve into it. A prefix match on it cannot catch a tenant module, whose keys
// start with /__collo_route/.
constexpr auto zygoteInternalModulePrefix = "/__collo/"_s;
// Bound on the microtask drains awaitModulePromiseSync runs while a module promise settles without the worker's
// event loop, set to the pack module cap so a deep but valid graph can settle. One drain empties the whole queue, so
// the loop stops at the first drain that leaves the promise pending and the bound is only a backstop.
constexpr unsigned maxSynchronousModuleDrains = static_cast<unsigned>(modulePackMaxModules);
constexpr ColloModuleRegisterOptions defaultModuleRegisterOptions {
    sizeof(ColloModuleRegisterOptions),
    COLLO_MODULE_LIFETIME_EVICTABLE,
    COLLO_MODULE_TYPE_ESM,
    0,
    0,
};

bool isRelativeSpecifier(const WTF::String& specifier)
{
    return specifier.startsWith("./"_s) || specifier.startsWith("../"_s);
}

bool isPathLikeSpecifier(const WTF::String& specifier)
{
    return specifier.startsWith('/') || isRelativeSpecifier(specifier);
}

bool isNodeFsSpecifier(const WTF::String& specifier)
{
    return specifier == "fs"_s || specifier == builtinNodeFsModuleKey;
}

bool isNodeFsPromisesSpecifier(const WTF::String& specifier)
{
    return specifier == "fs/promises"_s || specifier == builtinNodeFsPromisesModuleKey;
}

struct DeployScopedKey {
    WTF::StringView hash;
    WTF::StringView path;
    bool scoped { false };
};

// Splits a transport key into its deploy hash and its path within the deploy; the views borrow from `key`. A key
// that is not deploy-scoped, such as the zygote corpus, a builtin or a bare test pack, comes back unscoped and is
// shown to tenant code as it is.
DeployScopedKey parseDeployScopedKey(const WTF::String& key)
{
    DeployScopedKey out;
    if (!key.startsWith(routeModulePrefix))
        return out;
    WTF::StringView rest = WTF::StringView { key }.substring(routeModulePrefix.length());
    size_t slash = rest.find('/');
    if (slash == WTF::notFound || !slash || slash + 1 == rest.length())
        return out;
    out.hash = rest.left(slash);
    out.path = rest.substring(slash + 1);
    out.scoped = true;
    return out;
}

WTF::String absoluteModulePath(const WTF::String& key)
{
    return key.startsWith('/') ? key : WTF::makeString("/"_s, key);
}

WTF::String canonicalModuleSpecifier(const WTF::String& specifier, const WTF::String& referrer)
{
    if (specifier.isEmpty())
        return {};

    if (!isPathLikeSpecifier(specifier))
        return {};

    WTF::String combined;
    if (specifier.startsWith('/')) {
        combined = specifier;
    } else {
        WTF::String base_path = referrer.isEmpty() ? "/entry.js"_s : absoluteModulePath(referrer);
        size_t slash = base_path.reverseFind('/');
        WTF::String base_dir = slash == WTF::notFound ? "/"_s : base_path.substring(0, slash + 1);
        combined = WTF::makeString(base_dir, specifier);
    }

    WTF::Vector<WTF::String> segments;
    size_t start = 1;
    while (start <= combined.length()) {
        size_t slash = combined.find('/', start);
        size_t end = slash == WTF::notFound ? combined.length() : slash;
        WTF::String segment = combined.substring(start, end - start);

        if (segment.isEmpty() || segment == "."_s) {
        } else if (segment == ".."_s) {
            if (segments.isEmpty())
                return {};
            segments.removeLast();
        } else {
            if (!segments.tryAppend(WTF::move(segment)))
                return {};
        }

        if (slash == WTF::notFound)
            break;
        start = slash + 1;
    }

    WTF::StringBuilder builder(WTF::OverflowPolicy::RecordOverflow);
    builder.append('/');
    for (size_t i = 0; i < segments.size(); ++i) {
        if (i)
            builder.append('/');
        builder.append(segments[i]);
    }
    if (builder.hasOverflowed())
        return {};
    return builder.toString();
}

ColloStatus requireCanonicalSpecifier(ColloString specifier, const WTF::String& referrer, WTF::String& out)
{
    if (Collo::stringToWTFString(specifier, out) != COLLO_STATUS_OK || out.isEmpty())
        return COLLO_STATUS_INVALID_ARGUMENT;
    out = canonicalModuleSpecifier(out, referrer);
    if (out.isNull() || out.isEmpty())
        return COLLO_STATUS_INVALID_ARGUMENT;
    return COLLO_STATUS_OK;
}

ColloStatus copyCanonicalModulePackSpecifier(ColloString specifier, WTF::String& out)
{
    out = {};
    if (!specifier.ptr || specifier.len == 0 || specifier.len > WTF::String::MaxLength)
        return COLLO_STATUS_INVALID_ARGUMENT;

    bool is_ascii = true;
    for (size_t i = 0; i < specifier.len; ++i) {
        if (specifier.ptr[i] & 0x80) {
            is_ascii = false;
            break;
        }
    }

    if (is_ascii) {
        std::span<Latin1Character> characters;
        WTF::RefPtr<WTF::StringImpl> impl = WTF::StringImpl::tryCreateUninitialized(specifier.len, characters);
        if (!impl)
            return COLLO_STATUS_OUT_OF_MEMORY;
        for (size_t i = 0; i < specifier.len; ++i)
            characters[i] = static_cast<Latin1Character>(specifier.ptr[i]);
        out = WTF::String(WTF::move(impl));
        return COLLO_STATUS_OK;
    }

    const char* input = reinterpret_cast<const char*>(specifier.ptr);
    if (!simdutf::validate_utf8(input, specifier.len))
        return COLLO_STATUS_INVALID_ARGUMENT;
    const size_t utf16_len = simdutf::utf16_length_from_utf8(input, specifier.len);
    if (utf16_len == 0 || utf16_len > WTF::String::MaxLength)
        return COLLO_STATUS_INVALID_ARGUMENT;

    std::span<char16_t> characters;
    WTF::RefPtr<WTF::StringImpl> impl = WTF::StringImpl::tryCreateUninitialized(utf16_len, characters);
    if (!impl)
        return COLLO_STATUS_OUT_OF_MEMORY;
    const size_t written = simdutf::convert_valid_utf8_to_utf16le(input, specifier.len, characters.data());
    if (written != utf16_len)
        return COLLO_STATUS_ERROR;
    out = WTF::String(WTF::move(impl));
    return COLLO_STATUS_OK;
}

uint16_t readLe16(const uint8_t* ptr) { return static_cast<uint16_t>(ptr[0]) | (static_cast<uint16_t>(ptr[1]) << 8); }

uint32_t readLe32(const uint8_t* ptr)
{
    return static_cast<uint32_t>(ptr[0]) | (static_cast<uint32_t>(ptr[1]) << 8) | (static_cast<uint32_t>(ptr[2]) << 16)
        | (static_cast<uint32_t>(ptr[3]) << 24);
}

uint64_t readLe64(const uint8_t* ptr)
{
    return static_cast<uint64_t>(readLe32(ptr)) | (static_cast<uint64_t>(readLe32(ptr + 4)) << 32);
}

void wyMum(uint64_t& a, uint64_t& b)
{
    const auto product = static_cast<__uint128_t>(a) * b;
    a = static_cast<uint64_t>(product);
    b = static_cast<uint64_t>(product >> 64);
}

uint64_t wyMix(uint64_t a, uint64_t b)
{
    wyMum(a, b);
    return a ^ b;
}

// Must equal hashSpecifier in common/ipc/module_pack.zig: Zig's std.hash.Wyhash with seed 0, folded to 32 bits by
// xoring its two halves.
uint32_t modulePackHashSpecifier(std::span<const uint8_t> bytes)
{
    constexpr uint64_t secret[] = {
        0xa0761d6478bd642full,
        0xe7037ed1a0b428dbull,
        0x8ebc6af09c88c6e3ull,
        0x589965cc75374cc3ull,
    };

    uint64_t a = 0;
    uint64_t b = 0;
    uint64_t state0 = wyMix(secret[0], secret[1]);
    uint64_t state1 = state0;
    uint64_t state2 = state0;

    if (bytes.size() <= 16) {
        if (bytes.size() >= 4) {
            const size_t end = bytes.size() - 4;
            const size_t quarter = (bytes.size() >> 3) << 2;
            a = (static_cast<uint64_t>(readLe32(bytes.data())) << 32) | readLe32(bytes.data() + quarter);
            b = (static_cast<uint64_t>(readLe32(bytes.data() + end)) << 32) | readLe32(bytes.data() + end - quarter);
        } else if (!bytes.empty()) {
            a = (static_cast<uint64_t>(bytes[0]) << 16) | (static_cast<uint64_t>(bytes[bytes.size() >> 1]) << 8)
                | bytes[bytes.size() - 1];
        }
    } else {
        size_t i = 0;
        if (bytes.size() >= 48) {
            while (i + 48 < bytes.size()) {
                state0 = wyMix(readLe64(bytes.data() + i) ^ secret[1], readLe64(bytes.data() + i + 8) ^ state0);
                state1 = wyMix(readLe64(bytes.data() + i + 16) ^ secret[2], readLe64(bytes.data() + i + 24) ^ state1);
                state2 = wyMix(readLe64(bytes.data() + i + 32) ^ secret[3], readLe64(bytes.data() + i + 40) ^ state2);
                i += 48;
            }
            state0 ^= state1 ^ state2;
        }
        while (i + 16 < bytes.size()) {
            state0 = wyMix(readLe64(bytes.data() + i) ^ secret[1], readLe64(bytes.data() + i + 8) ^ state0);
            i += 16;
        }
        a = readLe64(bytes.data() + bytes.size() - 16);
        b = readLe64(bytes.data() + bytes.size() - 8);
    }

    a ^= secret[1];
    b ^= state0;
    wyMum(a, b);
    const uint64_t hash = wyMix(a ^ secret[0] ^ bytes.size(), b ^ secret[1]);
    return static_cast<uint32_t>(hash ^ (hash >> 32));
}

struct ModulePackHeader {
    uint32_t magic;
    uint16_t version;
    uint16_t flags;
    uint32_t moduleCount;
    uint32_t entryIndex;
    uint32_t recordsOffset;
    uint32_t dependenciesOffset;
    uint32_t dependencyCount;
    uint32_t indexOffset;
    uint32_t indexCapacity;
    uint32_t specifiersOffset;
    uint32_t sourcesOffset;
    uint32_t bytecodeOffset;
    uint32_t totalLen;
    uint32_t reserved0;
    uint32_t reserved1;
};

struct ModulePackRecord {
    uint32_t specifierOffset;
    uint32_t specifierLen;
    uint32_t sourceOffset;
    uint32_t sourceLen;
    uint32_t dependencyOffset;
    uint32_t dependencyCount;
    uint32_t bytecodeOffset;
    uint32_t bytecodeLen;
    uint32_t specifierHash;
    uint32_t flags;
    uint32_t reserved0;
    uint32_t reserved1;
};

struct ModulePackDependencyRecord {
    uint32_t specifierOffset;
    uint32_t specifierLen;
    uint32_t specifierHash;
    uint32_t reserved0;
};

struct ModulePackIndexEntry {
    uint32_t specifierHash;
    uint32_t moduleIndex;
};

struct PendingModuleSource {
    WTF::String specifier;
    uint32_t recordIndex;
};

struct StagedModuleSource {
    WTF::String specifier;
    WTF::RefPtr<JSC::SourceProvider> provider;
    ColloModuleLifetime lifetime { COLLO_MODULE_LIFETIME_EVICTABLE };
    ColloModuleType module_type { COLLO_MODULE_TYPE_ESM };
    bool has_bytecode { false };
    bool is_existing { false };
    bool replace_provider { false };
};

bool isValidModulePackSpecifierBytes(const uint8_t* bytes, size_t len)
{
    if (!bytes || len == 0 || bytes[0] != '/')
        return false;

    size_t segment_start = 1;
    for (size_t i = 0; i < len; ++i) {
        const uint8_t byte = bytes[i];
        if (byte <= ' ' || byte == '\\' || byte == '?' || byte == '#')
            return false;
        if (byte != '/')
            continue;

        if (i == 0)
            continue;
        const size_t segment_len = i - segment_start;
        if (segment_len == 0)
            return false;
        if (segment_len == 1 && bytes[segment_start] == '.')
            return false;
        if (segment_len == 2 && bytes[segment_start] == '.' && bytes[segment_start + 1] == '.')
            return false;
        segment_start = i + 1;
    }

    const size_t segment_len = len - segment_start;
    if (segment_len == 0)
        return false;
    if (segment_len == 1 && bytes[segment_start] == '.')
        return false;
    if (segment_len == 2 && bytes[segment_start] == '.' && bytes[segment_start + 1] == '.')
        return false;
    return true;
}

bool isValidModuleLifetime(ColloModuleLifetime lifetime)
{
    return lifetime == COLLO_MODULE_LIFETIME_EVICTABLE || lifetime == COLLO_MODULE_LIFETIME_PERMANENT;
}

bool isValidModuleType(ColloModuleType moduleType) { return moduleType == COLLO_MODULE_TYPE_ESM; }

ColloStatus normalizeModuleRegisterOptions(
    const ColloModuleRegisterOptions* options, ColloModuleRegisterOptions& outOptions)
{
    outOptions = defaultModuleRegisterOptions;
    if (!options)
        return COLLO_STATUS_OK;
    if (options->abi_size != sizeof(ColloModuleRegisterOptions) || options->reserved0 != 0 || options->flags != 0)
        return COLLO_STATUS_INVALID_ARGUMENT;
    if (!isValidModuleLifetime(options->lifetime) || !isValidModuleType(options->module_type))
        return COLLO_STATUS_INVALID_ARGUMENT;
    outOptions = *options;
    return COLLO_STATUS_OK;
}

ColloModuleLifetime mergedLifetime(ColloModuleLifetime lhs, ColloModuleLifetime rhs)
{
    if (lhs == COLLO_MODULE_LIFETIME_PERMANENT || rhs == COLLO_MODULE_LIFETIME_PERMANENT)
        return COLLO_MODULE_LIFETIME_PERMANENT;
    return COLLO_MODULE_LIFETIME_EVICTABLE;
}

ModulePackHeader readModulePackHeader(const uint8_t* bytes)
{
    return {
        readLe32(bytes),
        readLe16(bytes + 4),
        readLe16(bytes + 6),
        readLe32(bytes + 8),
        readLe32(bytes + 12),
        readLe32(bytes + 16),
        readLe32(bytes + 20),
        readLe32(bytes + 24),
        readLe32(bytes + 28),
        readLe32(bytes + 32),
        readLe32(bytes + 36),
        readLe32(bytes + 40),
        readLe32(bytes + 44),
        readLe32(bytes + 48),
        readLe32(bytes + 52),
        readLe32(bytes + 56),
    };
}

ModulePackRecord readModulePackRecord(const uint8_t* bytes)
{
    return {
        readLe32(bytes),
        readLe32(bytes + 4),
        readLe32(bytes + 8),
        readLe32(bytes + 12),
        readLe32(bytes + 16),
        readLe32(bytes + 20),
        readLe32(bytes + 24),
        readLe32(bytes + 28),
        readLe32(bytes + 32),
        readLe32(bytes + 36),
        readLe32(bytes + 40),
        readLe32(bytes + 44),
    };
}

ModulePackDependencyRecord readModulePackDependencyRecord(const uint8_t* bytes)
{
    return {
        readLe32(bytes),
        readLe32(bytes + 4),
        readLe32(bytes + 8),
        readLe32(bytes + 12),
    };
}

ModulePackIndexEntry readModulePackIndexEntry(const uint8_t* bytes)
{
    return {
        readLe32(bytes),
        readLe32(bytes + 4),
    };
}

ColloString recordSpecifier(ColloBuffer pack, const ModulePackRecord& record)
{
    return {
        pack.ptr + record.specifierOffset,
        record.specifierLen,
    };
}

ColloString dependencySpecifier(ColloBuffer pack, const ModulePackDependencyRecord& dependency)
{
    return {
        pack.ptr + dependency.specifierOffset,
        dependency.specifierLen,
    };
}

bool specifierBytesEqual(ColloString lhs, ColloString rhs)
{
    return lhs.len == rhs.len && (!lhs.len || !std::memcmp(lhs.ptr, rhs.ptr, lhs.len));
}

bool findModulePackRecordIndex(ColloBuffer pack, const ModulePackHeader& header,
    const WTF::Vector<ModulePackRecord>& records, ColloString specifier, uint32_t specifierHash, uint32_t& outIndex)
{
    size_t slot = static_cast<size_t>(specifierHash) & (static_cast<size_t>(header.indexCapacity) - 1);
    for (uint32_t probes = 0; probes < header.indexCapacity; ++probes) {
        const auto entry = readModulePackIndexEntry(pack.ptr + header.indexOffset + slot * modulePackIndexEntrySize);
        if (entry.moduleIndex == emptyModulePackIndex)
            return false;
        if (entry.specifierHash == specifierHash && entry.moduleIndex < records.size()) {
            if (specifierBytesEqual(recordSpecifier(pack, records[entry.moduleIndex]), specifier)) {
                outIndex = entry.moduleIndex;
                return true;
            }
        }
        slot = (slot + 1) & (static_cast<size_t>(header.indexCapacity) - 1);
    }
    return false;
}

bool rangeInside(size_t totalLen, uint32_t offsetRaw, uint32_t lenRaw)
{
    const size_t offset = offsetRaw;
    const size_t len = lenRaw;
    return offset <= totalLen && len <= totalLen - offset;
}

// Owns one ColloMapping handed over by collo_module_register_pack and ends it
// with collo_runtime_mapping_release on destruction. Taking ownership on entry
// is what makes every return path, failures included, release the mapping
// exactly once.
class OwnedMapping {
public:
    explicit OwnedMapping(ColloMapping mapping)
        : m_mapping(mapping)
    {
    }

    OwnedMapping(OwnedMapping&& other)
        : m_mapping(std::exchange(other.m_mapping, ColloMapping { nullptr, 0 }))
    {
    }

    OwnedMapping(const OwnedMapping&) = delete;
    OwnedMapping& operator=(const OwnedMapping&) = delete;
    OwnedMapping& operator=(OwnedMapping&&) = delete;

    ~OwnedMapping()
    {
        if (m_mapping.ptr)
            collo_runtime_mapping_release(m_mapping);
    }

    ColloBuffer bytes() const { return { m_mapping.ptr, m_mapping.len }; }

private:
    ColloMapping m_mapping;
};

class ColloModulePackData final : public WTF::ThreadSafeRefCounted<ColloModulePackData> {
public:
    // Takes over the pack's mapping. The memfd behind it is sealed against
    // writes and resizes and every worker of a definition maps the same one, so
    // these pages are shared page cache, not per-worker heap. The mapping ends
    // with this object, when the last SourceProvider pointing into it drops
    // its reference, on whatever thread that happens. On allocation failure
    // `mapping` is left with the caller, which still releases it.
    static WTF::RefPtr<ColloModulePackData> create(OwnedMapping&& mapping, WTF::Vector<ModulePackRecord>&& records)
    {
        ColloModulePackData* data = nullptr;
        if (!WTF::tryFastMalloc(sizeof(ColloModulePackData)).getValue(data))
            return nullptr;
        data = new (NotNull, data) ColloModulePackData(WTF::move(mapping), WTF::move(records));
        return WTF::adoptRef(*data);
    }

    const ModulePackRecord& record(size_t index) const { return m_records[index]; }

    std::span<const uint8_t> sourceBytes(size_t index) const
    {
        const auto& record = m_records[index];
        auto bytes = bytesSpan();
        return std::span<const uint8_t> { bytes.data() + record.sourceOffset, record.sourceLen };
    }

    std::span<const uint8_t> bytecodeBytes(size_t index) const
    {
        const auto& record = m_records[index];
        if (!record.bytecodeLen)
            return {};
        auto bytes = bytesSpan();
        return std::span<const uint8_t> { bytes.data() + record.bytecodeOffset, record.bytecodeLen };
    }

private:
    ColloModulePackData(OwnedMapping&& mapping, WTF::Vector<ModulePackRecord>&& records)
        : m_mapping(WTF::move(mapping))
        , m_records(WTF::move(records))
    {
    }

    std::span<const uint8_t> bytesSpan() const
    {
        const ColloBuffer bytes = m_mapping.bytes();
        return std::span<const uint8_t> { bytes.ptr, bytes.len };
    }

    OwnedMapping m_mapping;
    WTF::Vector<ModulePackRecord> m_records;
};

class ColloSourceProvider final : public JSC::SourceProvider {
public:
    static WTF::RefPtr<ColloSourceProvider> create(
        WTF::Ref<ColloModulePackData>&& packData, uint32_t recordIndex, const WTF::String& moduleKey)
    {
        WTF::URL url = WTF::URL::fileURLWithFileSystemPath(absoluteModulePath(moduleKey));
        ColloSourceProvider* provider = nullptr;
        if (!WTF::tryFastMalloc(sizeof(ColloSourceProvider)).getValue(provider))
            return nullptr;
        provider
            = new (NotNull, provider) ColloSourceProvider(WTF::move(packData), recordIndex, WTF::move(url), moduleKey);
        return WTF::adoptRef(*provider);
    }

    unsigned hash() const override
    {
        const auto& text = sourceString();
        return text.impl() ? text.impl()->hash() : 0;
    }

    WTF::StringView source() const override { return sourceString(); }

    bool sourceBytesEqual(std::span<const uint8_t> sourceBytes) const
    {
        const auto current = m_packData->sourceBytes(m_recordIndex);
        return current.size() == sourceBytes.size()
            && std::memcmp(current.data(), sourceBytes.data(), sourceBytes.size()) == 0;
    }

    WTF::RefPtr<JSC::CachedBytecode> cachedBytecode() const override
    {
        if (m_cachedBytecode)
            return m_cachedBytecode.copyRef();

        const auto bytecode = m_packData->bytecodeBytes(m_recordIndex);
        if (bytecode.empty())
            return nullptr;

        // JSC's decoder reads a GenericCacheEntry header, for its cacheVersion check, before validating any bounds,
        // so a blob shorter than that header is an out-of-bounds read rather than a clean version mismatch. Nothing
        // this small can be a real cache, since the blob of an empty module is already about 2 KB, so it is treated as
        // absent and truncated bytecode falls back to the source.
        static constexpr size_t minimumPlausibleCacheBytes = 64;
        if (bytecode.size() < minimumPlausibleCacheBytes)
            return nullptr;

        auto copied = MallocSpan<uint8_t, JSC::VMMalloc>::tryMalloc(bytecode.size());
        if (!copied)
            return nullptr;

        std::memcpy(copied.mutableSpan().data(), bytecode.data(), bytecode.size());
        m_cachedBytecode = JSC::CachedBytecode::create(WTF::move(copied), {});
        return m_cachedBytecode.copyRef();
    }

private:
    ColloSourceProvider(
        WTF::Ref<ColloModulePackData>&& packData, uint32_t recordIndex, WTF::URL&& url, const WTF::String& moduleKey)
        : JSC::SourceProvider(JSC::SourceOrigin(url), WTF::String(moduleKey), WTF::String(),
              JSC::SourceTaintedOrigin::Untainted, TextPosition(), JSC::SourceProviderSourceType::Module)
        , m_packData(WTF::move(packData))
        , m_recordIndex(recordIndex)
    {
    }

    const WTF::String& sourceString() const
    {
        if (m_source.isNull()) {
            const auto bytes = m_packData->sourceBytes(m_recordIndex);
            m_source = WTF::String::fromUTF8ReplacingInvalidSequences(std::span<const Latin1Character> {
                reinterpret_cast<const Latin1Character*>(bytes.data()), bytes.size() });
        }
        return m_source;
    }

    WTF::Ref<ColloModulePackData> m_packData;
    uint32_t m_recordIndex;
    mutable WTF::String m_source;
    mutable WTF::RefPtr<JSC::CachedBytecode> m_cachedBytecode;
};

WTF::RefPtr<JSC::SourceProvider> sourceProviderForModulePack(
    const WTF::String& moduleKey, WTF::Ref<ColloModulePackData>&& packData, uint32_t recordIndex)
{
    return ColloSourceProvider::create(WTF::move(packData), recordIndex, moduleKey);
}

bool registeredSourceEqualsBytes(JSC::SourceProvider* provider, std::span<const uint8_t> sourceBytes)
{
    if (!provider)
        return false;
    // module_sources holds only ColloSourceProvider instances. Comparing the pack bytes directly keeps a duplicate
    // registration from decoding source text only to prove it is the same.
    return static_cast<ColloSourceProvider*>(provider)->sourceBytesEqual(sourceBytes);
}

struct ModuleSourceLookup {
    size_t index;
    bool found;
};

ModuleSourceLookup findModuleSourceIndex(
    const WTF::Vector<ColloModuleSourceRecord>& sources, const WTF::String& specifier)
{
    size_t begin = 0;
    size_t end = sources.size();
    while (begin < end) {
        const size_t middle = begin + (end - begin) / 2;
        if (WTF::codePointCompareLessThan(sources[middle].specifier, specifier))
            begin = middle + 1;
        else
            end = middle;
    }
    return { begin, begin < sources.size() && sources[begin].specifier == specifier };
}

ColloModuleSourceRecord* findModuleSource(WTF::Vector<ColloModuleSourceRecord>& sources, const WTF::String& specifier)
{
    auto lookup = findModuleSourceIndex(sources, specifier);
    return lookup.found ? &sources[lookup.index] : nullptr;
}

const ColloModuleSourceRecord* findModuleSource(
    const WTF::Vector<ColloModuleSourceRecord>& sources, const WTF::String& specifier)
{
    auto lookup = findModuleSourceIndex(sources, specifier);
    return lookup.found ? &sources[lookup.index] : nullptr;
}

bool trySetModuleSource(
    WTF::Vector<ColloModuleSourceRecord>& sources, WTF::String specifier, ColloModuleSourceEntry&& entry)
{
    auto lookup = findModuleSourceIndex(sources, specifier);
    if (lookup.found) {
        sources[lookup.index].entry = WTF::move(entry);
        return true;
    }

    if (sources.size() == sources.capacity() && !sources.tryReserveCapacity(sources.size() + 1))
        return false;
    sources.insert(lookup.index, ColloModuleSourceRecord { WTF::move(specifier), WTF::move(entry) });
    return true;
}

// Validates the pack in place and registers its modules. `pack_mapping` moves
// into the ColloModulePackData only when a new provider needs the bytes;
// otherwise the caller's owner releases it on return.
ColloStatus registerModulePackLocked(ColloVm* vm, OwnedMapping& pack_mapping, ColloModuleRegisterOptions options)
{
    const ColloBuffer pack = pack_mapping.bytes();
    if (!vm || !vm->isReady() || (!pack.ptr && pack.len))
        return COLLO_STATUS_INVALID_ARGUMENT;
    if (!isValidModuleLifetime(options.lifetime) || !isValidModuleType(options.module_type))
        return COLLO_STATUS_INVALID_ARGUMENT;
    if (pack.len < modulePackHeaderSize || pack.len > modulePackMaxBytes)
        return COLLO_STATUS_INVALID_ARGUMENT;

    const auto header = readModulePackHeader(pack.ptr);
    if (header.magic != modulePackMagic || header.version != modulePackVersion)
        return COLLO_STATUS_INVALID_ARGUMENT;
    if (header.flags != 0 || header.reserved0 != 0 || header.reserved1 != 0)
        return COLLO_STATUS_INVALID_ARGUMENT;
    if (header.moduleCount == 0 || header.moduleCount > modulePackMaxModules || header.entryIndex >= header.moduleCount)
        return COLLO_STATUS_INVALID_ARGUMENT;
    if (header.totalLen != pack.len || header.recordsOffset != modulePackHeaderSize)
        return COLLO_STATUS_INVALID_ARGUMENT;
    if (!header.indexCapacity || (header.indexCapacity & (header.indexCapacity - 1))
        || header.indexCapacity < header.moduleCount)
        return COLLO_STATUS_INVALID_ARGUMENT;

    const size_t recordsLen = static_cast<size_t>(header.moduleCount) * modulePackRecordSize;
    if (!rangeInside(pack.len, header.recordsOffset, recordsLen))
        return COLLO_STATUS_INVALID_ARGUMENT;
    const size_t recordsEnd = header.recordsOffset + recordsLen;
    const size_t dependenciesLen = static_cast<size_t>(header.dependencyCount) * modulePackDependencyRecordSize;
    if (!rangeInside(pack.len, header.dependenciesOffset, dependenciesLen))
        return COLLO_STATUS_INVALID_ARGUMENT;
    const size_t dependenciesEnd = header.dependenciesOffset + dependenciesLen;
    const size_t indexLen = static_cast<size_t>(header.indexCapacity) * modulePackIndexEntrySize;
    if (!rangeInside(pack.len, header.indexOffset, indexLen))
        return COLLO_STATUS_INVALID_ARGUMENT;
    const size_t indexEnd = header.indexOffset + indexLen;
    if (recordsEnd != header.dependenciesOffset || dependenciesEnd != header.indexOffset
        || indexEnd != header.specifiersOffset)
        return COLLO_STATUS_INVALID_ARGUMENT;
    if (header.specifiersOffset > header.sourcesOffset || header.sourcesOffset > header.bytecodeOffset
        || header.bytecodeOffset > pack.len)
        return COLLO_STATUS_INVALID_ARGUMENT;

    WTF::Vector<PendingModuleSource> pending_modules;
    if (!pending_modules.tryReserveInitialCapacity(header.moduleCount))
        return COLLO_STATUS_OUT_OF_MEMORY;
    WTF::Vector<ModulePackRecord> records;
    if (!records.tryReserveInitialCapacity(header.moduleCount))
        return COLLO_STATUS_OUT_OF_MEMORY;
    WTF::String pack_deploy_hash;
    for (uint32_t i = 0; i < header.moduleCount; ++i) {
        const auto record
            = readModulePackRecord(pack.ptr + header.recordsOffset + static_cast<size_t>(i) * modulePackRecordSize);
        if (record.reserved0 != 0 || record.reserved1 != 0 || record.specifierLen == 0 || record.sourceLen == 0)
            return COLLO_STATUS_INVALID_ARGUMENT;
        if (record.flags != 0)
            return COLLO_STATUS_INVALID_ARGUMENT;
        if (!rangeInside(pack.len, record.specifierOffset, record.specifierLen)
            || !rangeInside(pack.len, record.sourceOffset, record.sourceLen)
            || !rangeInside(pack.len, record.bytecodeOffset, record.bytecodeLen))
            return COLLO_STATUS_INVALID_ARGUMENT;
        if (record.specifierOffset < header.specifiersOffset
            || record.specifierOffset + record.specifierLen > header.sourcesOffset)
            return COLLO_STATUS_INVALID_ARGUMENT;
        if (record.sourceOffset < header.sourcesOffset
            || record.sourceOffset + record.sourceLen > header.bytecodeOffset)
            return COLLO_STATUS_INVALID_ARGUMENT;
        if (record.bytecodeOffset < header.bytecodeOffset || record.bytecodeOffset + record.bytecodeLen > pack.len)
            return COLLO_STATUS_INVALID_ARGUMENT;
        const size_t dependencyEnd = static_cast<size_t>(record.dependencyOffset) + record.dependencyCount;
        if (dependencyEnd > header.dependencyCount)
            return COLLO_STATUS_INVALID_ARGUMENT;

        const ColloString specifier = recordSpecifier(pack, record);
        if (!isValidModulePackSpecifierBytes(specifier.ptr, specifier.len))
            return COLLO_STATUS_INVALID_ARGUMENT;
        if (record.specifierHash != modulePackHashSpecifier(std::span<const uint8_t> { specifier.ptr, specifier.len }))
            return COLLO_STATUS_INVALID_ARGUMENT;

        WTF::String specifier_string;
        ColloStatus specifier_status = copyCanonicalModulePackSpecifier(specifier, specifier_string);
        if (specifier_status != COLLO_STATUS_OK)
            return specifier_status;

        // One deploy per VM: the public /var/task namespace rebuilds transport keys from a single deploy hash, so a
        // pack mixing hashes, or a second deploy reaching this VM, would make that mapping ambiguous. The pack is
        // refused before any state changes.
        auto scoped = parseDeployScopedKey(specifier_string);
        if (scoped.scoped) {
            if (pack_deploy_hash.isNull())
                pack_deploy_hash = scoped.hash.toString();
            else if (WTF::StringView { pack_deploy_hash } != scoped.hash)
                return COLLO_STATUS_INVALID_ARGUMENT;
        }

        if (auto* source = findModuleSource(vm->module_sources, specifier_string)) {
            if (source->entry.module_type != options.module_type)
                return COLLO_STATUS_ALREADY_EXISTS;
            if (!registeredSourceEqualsBytes(source->entry.provider.get(),
                    std::span<const uint8_t> { pack.ptr + record.sourceOffset, record.sourceLen }))
                return COLLO_STATUS_ALREADY_EXISTS;
        }

        if (!pending_modules.tryAppend(PendingModuleSource { WTF::move(specifier_string), i }))
            return COLLO_STATUS_OUT_OF_MEMORY;
        if (!records.tryAppend(record))
            return COLLO_STATUS_OUT_OF_MEMORY;
    }

    if (!pack_deploy_hash.isNull() && !vm->deploy_hash.isNull() && vm->deploy_hash != pack_deploy_hash)
        return COLLO_STATUS_INVALID_ARGUMENT;

    WTF::Vector<uint8_t> indexed_records;
    if (!indexed_records.tryReserveInitialCapacity(header.moduleCount))
        return COLLO_STATUS_OUT_OF_MEMORY;
    for (uint32_t i = 0; i < header.moduleCount; ++i) {
        if (!indexed_records.tryAppend(static_cast<uint8_t>(0)))
            return COLLO_STATUS_OUT_OF_MEMORY;
    }
    size_t liveIndexEntries = 0;
    for (uint32_t i = 0; i < header.indexCapacity; ++i) {
        const auto entry = readModulePackIndexEntry(
            pack.ptr + header.indexOffset + static_cast<size_t>(i) * modulePackIndexEntrySize);
        if (entry.moduleIndex == emptyModulePackIndex) {
            if (entry.specifierHash != 0)
                return COLLO_STATUS_INVALID_ARGUMENT;
            continue;
        }
        if (entry.moduleIndex >= header.moduleCount)
            return COLLO_STATUS_INVALID_ARGUMENT;
        if (entry.specifierHash != records[entry.moduleIndex].specifierHash)
            return COLLO_STATUS_INVALID_ARGUMENT;
        if (indexed_records[entry.moduleIndex])
            return COLLO_STATUS_INVALID_ARGUMENT;
        indexed_records[entry.moduleIndex] = 1;
        ++liveIndexEntries;
    }
    if (liveIndexEntries != header.moduleCount)
        return COLLO_STATUS_INVALID_ARGUMENT;

    for (uint32_t i = 0; i < header.moduleCount; ++i) {
        uint32_t foundIndex = emptyModulePackIndex;
        const ColloString specifier = recordSpecifier(pack, records[i]);
        if (!findModulePackRecordIndex(pack, header, records, specifier, records[i].specifierHash, foundIndex))
            return COLLO_STATUS_INVALID_ARGUMENT;
        if (foundIndex != i)
            return COLLO_STATUS_INVALID_ARGUMENT;
    }

    for (uint32_t i = 0; i < header.dependencyCount; ++i) {
        const auto dependency = readModulePackDependencyRecord(
            pack.ptr + header.dependenciesOffset + static_cast<size_t>(i) * modulePackDependencyRecordSize);
        if (dependency.reserved0 != 0 || dependency.specifierLen == 0)
            return COLLO_STATUS_INVALID_ARGUMENT;
        if (!rangeInside(pack.len, dependency.specifierOffset, dependency.specifierLen))
            return COLLO_STATUS_INVALID_ARGUMENT;
        if (dependency.specifierOffset < header.specifiersOffset
            || dependency.specifierOffset + dependency.specifierLen > header.sourcesOffset)
            return COLLO_STATUS_INVALID_ARGUMENT;
        const ColloString specifier = dependencySpecifier(pack, dependency);
        if (!isValidModulePackSpecifierBytes(specifier.ptr, specifier.len))
            return COLLO_STATUS_INVALID_ARGUMENT;
        if (dependency.specifierHash
            != modulePackHashSpecifier(std::span<const uint8_t> { specifier.ptr, specifier.len }))
            return COLLO_STATUS_INVALID_ARGUMENT;
        WTF::String specifierString;
        ColloStatus specifierStatus = copyCanonicalModulePackSpecifier(specifier, specifierString);
        if (specifierStatus != COLLO_STATUS_OK)
            return specifierStatus;
        uint32_t foundIndex = emptyModulePackIndex;
        if (!findModulePackRecordIndex(pack, header, records, specifier, dependency.specifierHash, foundIndex))
            return COLLO_STATUS_INVALID_ARGUMENT;
    }

    bool has_new_source = false;
    bool has_bytecode_upgrade = false;
    for (const auto& pending : pending_modules) {
        auto* source = findModuleSource(vm->module_sources, pending.specifier);
        if (!source) {
            has_new_source = true;
            continue;
        }
        if (!source->entry.has_bytecode && records[pending.recordIndex].bytecodeLen)
            has_bytecode_upgrade = true;
    }
    if (!has_new_source && !has_bytecode_upgrade) {
        for (const auto& pending : pending_modules) {
            auto* source = findModuleSource(vm->module_sources, pending.specifier);
            ASSERT(source);
            source->entry.lifetime = mergedLifetime(source->entry.lifetime, options.lifetime);
        }
        if (vm->deploy_hash.isNull() && !pack_deploy_hash.isNull())
            vm->deploy_hash = pack_deploy_hash;
        return COLLO_STATUS_OK;
    }

    auto pack_data = ColloModulePackData::create(WTF::move(pack_mapping), WTF::move(records));
    if (!pack_data)
        return COLLO_STATUS_OUT_OF_MEMORY;

    WTF::Vector<StagedModuleSource> staged_sources;
    if (!staged_sources.tryReserveInitialCapacity(pending_modules.size()))
        return COLLO_STATUS_OUT_OF_MEMORY;

    for (const auto& pending : pending_modules) {
        const auto& record = pack_data->record(pending.recordIndex);
        if (auto* source = findModuleSource(vm->module_sources, pending.specifier)) {
            StagedModuleSource staged;
            staged.specifier = pending.specifier;
            staged.lifetime = mergedLifetime(source->entry.lifetime, options.lifetime);
            staged.module_type = source->entry.module_type;
            staged.has_bytecode = source->entry.has_bytecode;
            staged.is_existing = true;
            if (!source->entry.has_bytecode && record.bytecodeLen) {
                auto provider = sourceProviderForModulePack(
                    pending.specifier, WTF::Ref<ColloModulePackData> { *pack_data }, pending.recordIndex);
                if (!provider)
                    return COLLO_STATUS_OUT_OF_MEMORY;
                staged.provider = WTF::move(provider);
                staged.has_bytecode = true;
                staged.replace_provider = true;
            }
            if (!staged_sources.tryAppend(WTF::move(staged)))
                return COLLO_STATUS_OUT_OF_MEMORY;
            continue;
        }

        auto provider = sourceProviderForModulePack(
            pending.specifier, WTF::Ref<ColloModulePackData> { *pack_data }, pending.recordIndex);
        if (!provider)
            return COLLO_STATUS_OUT_OF_MEMORY;

        StagedModuleSource staged;
        staged.specifier = pending.specifier;
        staged.provider = WTF::move(provider);
        staged.lifetime = options.lifetime;
        staged.module_type = options.module_type;
        staged.has_bytecode = record.bytecodeLen != 0;
        staged.replace_provider = true;
        if (!staged_sources.tryAppend(WTF::move(staged)))
            return COLLO_STATUS_OUT_OF_MEMORY;
    }

    WTF::Vector<ColloModuleSourceRecord> replacement_sources;
    if (vm->module_sources.size() > std::numeric_limits<size_t>::max() - staged_sources.size())
        return COLLO_STATUS_OUT_OF_MEMORY;
    if (!replacement_sources.tryReserveInitialCapacity(vm->module_sources.size() + staged_sources.size()))
        return COLLO_STATUS_OUT_OF_MEMORY;
    for (const auto& source : vm->module_sources) {
        if (!replacement_sources.tryAppend(source))
            return COLLO_STATUS_OUT_OF_MEMORY;
    }

    for (auto& staged : staged_sources) {
        if (staged.is_existing) {
            auto* source = findModuleSource(replacement_sources, staged.specifier);
            ASSERT(source);
            source->entry.lifetime = staged.lifetime;
            if (staged.replace_provider) {
                source->entry.provider = WTF::move(staged.provider);
                source->entry.has_bytecode = staged.has_bytecode;
            }
            continue;
        }

        ColloModuleSourceEntry entry;
        entry.provider = WTF::move(staged.provider);
        entry.lifetime = staged.lifetime;
        entry.module_type = staged.module_type;
        entry.has_bytecode = staged.has_bytecode;
        if (!trySetModuleSource(replacement_sources, WTF::move(staged.specifier), WTF::move(entry)))
            return COLLO_STATUS_OUT_OF_MEMORY;
    }
    vm->module_sources.swap(replacement_sources);
    if (vm->deploy_hash.isNull() && !pack_deploy_hash.isNull())
        vm->deploy_hash = pack_deploy_hash;
    return COLLO_STATUS_OK;
}

JSC::JSSourceCode* sourceCodeForRegisteredModule(ColloVm& collo_vm, const WTF::String& module_key)
{
    if (module_key == builtinNodeFsModuleKey) {
        if (!collo_vm.node_fs_enabled)
            return nullptr;

        static constexpr char source[] = "const fs = globalThis.__collo_node_fs;\n"
                                         "if (fs === undefined) throw new Error('node:fs binding is unavailable');\n"
                                         "export const readFile = fs.readFile;\n"
                                         "export const writeFile = fs.writeFile;\n"
                                         "export const mkdir = fs.mkdir;\n"
                                         "export const readdir = fs.readdir;\n"
                                         "export const stat = fs.stat;\n"
                                         "export const unlink = fs.unlink;\n"
                                         "export const rename = fs.rename;\n"
                                         "export const exists = fs.exists;\n"
                                         "export const readFileSync = fs.readFileSync;\n"
                                         "export const writeFileSync = fs.writeFileSync;\n"
                                         "export const mkdirSync = fs.mkdirSync;\n"
                                         "export const readdirSync = fs.readdirSync;\n"
                                         "export const statSync = fs.statSync;\n"
                                         "export const unlinkSync = fs.unlinkSync;\n"
                                         "export const renameSync = fs.renameSync;\n"
                                         "export const existsSync = fs.existsSync;\n"
                                         "export const promises = fs.promises;\n"
                                         "export default fs;\n";
        WTF::String source_string = WTF::String::fromUTF8(
            std::span<const char8_t> { reinterpret_cast<const char8_t*>(source), sizeof(source) - 1 });
        WTF::URL url;
        WTF::Ref<JSC::StringSourceProvider> provider = JSC::StringSourceProvider::create(source_string,
            JSC::SourceOrigin(url), WTF::String(builtinNodeFsModuleKey), JSC::SourceTaintedOrigin::Untainted,
            WTF::TextPosition(), JSC::SourceProviderSourceType::Module);
        return JSC::JSSourceCode::create(*collo_vm.vm, JSC::SourceCode(WTF::move(provider), 1, 1));
    }

    if (module_key == builtinNodeFsPromisesModuleKey) {
        if (!collo_vm.node_fs_enabled)
            return nullptr;

        static constexpr char source[]
            = "const p = globalThis.__collo_node_fs?.promises;\n"
              "if (p === undefined) throw new Error('node:fs/promises binding is unavailable');\n"
              "export const readFile = p.readFile;\n"
              "export const writeFile = p.writeFile;\n"
              "export const mkdir = p.mkdir;\n"
              "export const readdir = p.readdir;\n"
              "export const stat = p.stat;\n"
              "export const unlink = p.unlink;\n"
              "export const rename = p.rename;\n"
              "export const exists = p.exists;\n"
              "export default p;\n";
        WTF::String source_string = WTF::String::fromUTF8(
            std::span<const char8_t> { reinterpret_cast<const char8_t*>(source), sizeof(source) - 1 });
        WTF::URL url;
        WTF::Ref<JSC::StringSourceProvider> provider = JSC::StringSourceProvider::create(source_string,
            JSC::SourceOrigin(url), WTF::String(builtinNodeFsPromisesModuleKey), JSC::SourceTaintedOrigin::Untainted,
            WTF::TextPosition(), JSC::SourceProviderSourceType::Module);
        return JSC::JSSourceCode::create(*collo_vm.vm, JSC::SourceCode(WTF::move(provider), 1, 1));
    }

    if (auto* source = findModuleSource(collo_vm.module_sources, module_key)) {
        if (!source->entry.provider)
            return nullptr;
        WTF::Ref<JSC::SourceProvider> provider_ref { *source->entry.provider };
        return JSC::JSSourceCode::create(*collo_vm.vm, JSC::SourceCode(WTF::move(provider_ref), 1, 1));
    }
    return nullptr;
}

void clearModuleEvictStats(ColloModuleEvictStats* outStats)
{
    if (!outStats)
        return;
    outStats->sources_removed = 0;
    outStats->namespaces_removed = 0;
}

bool evictModuleSourceLocked(ColloVm* vm, const WTF::String& specifier, ColloModuleEvictStats* outStats)
{
    auto lookup = findModuleSourceIndex(vm->module_sources, specifier);
    if (!lookup.found)
        return false;
    if (vm->module_sources[lookup.index].entry.lifetime == COLLO_MODULE_LIFETIME_PERMANENT)
        return false;

    vm->module_sources.removeAt(lookup.index);
    if (outStats)
        ++outStats->sources_removed;

    for (auto& realm : vm->realms) {
        if (realm->module_namespaces.remove(specifier) && outStats)
            ++outStats->namespaces_removed;
    }
    return true;
}

ColloStatus evictModuleLifetimeLocked(ColloVm* vm, ColloModuleLifetime lifetime, ColloModuleEvictStats* outStats)
{
    if (!isValidModuleLifetime(lifetime))
        return COLLO_STATUS_INVALID_ARGUMENT;

    WTF::Vector<WTF::String> candidates;
    if (!candidates.tryReserveInitialCapacity(vm->module_sources.size()))
        return COLLO_STATUS_OUT_OF_MEMORY;
    for (const auto& source : vm->module_sources) {
        if (source.entry.lifetime == lifetime && !candidates.tryAppend(source.specifier))
            return COLLO_STATUS_OUT_OF_MEMORY;
    }
    for (const auto& specifier : candidates)
        evictModuleSourceLocked(vm, specifier, outStats);
    return COLLO_STATUS_OK;
}

Collo::GlobalObject* asColloGlobal(JSC::JSGlobalObject* global_object)
{
    return uncheckedDowncast<Collo::GlobalObject>(global_object);
}

// The spelling of a module key tenant code may see: a deploy-scoped transport key shows its public /var/task path,
// so the deploy hash never reaches tenant-facing error text. Any other key, such as the zygote corpus, a builtin or
// a bare test pack, is already its display form and passes through unchanged.
WTF::String displayModuleSpecifier(const WTF::String& module_key)
{
    WTF::String public_path = Collo::publicModulePathForKey(module_key);
    return public_path.isNull() ? module_key : public_path;
}

WTF::String invalidModuleSpecifierMessage(const WTF::String& specifier, const WTF::String& referrer)
{
    if (referrer.isEmpty())
        return WTF::makeString("Invalid module specifier '"_s, specifier, "'."_s);
    // Tenant code sees this text, so a deploy-scoped referrer shows its public /var/task spelling, never its
    // transport key.
    return WTF::makeString(
        "Invalid module specifier '"_s, specifier, "' from '"_s, displayModuleSpecifier(referrer), "'."_s);
}

// The rejection of a fetch for a key no registered pack holds. Tenant code sees it, so the module and the module
// that imported it, when there is one, show their public /var/task spelling.
WTF::String moduleNotFoundMessage(const WTF::String& module_key, const WTF::String& referrer)
{
    if (referrer.isEmpty())
        return WTF::makeString("Cannot find module '"_s, displayModuleSpecifier(module_key), "'."_s);
    return WTF::makeString("Cannot find module '"_s, displayModuleSpecifier(module_key), "' imported from '"_s,
        displayModuleSpecifier(referrer), "'."_s);
}

// The mapping toward transport described at publicTaskRootPrefix: a canonical public /var/task path becomes a
// registry key again, registered or not, and a key no pack holds fails to fetch like any other. Before a
// deploy-scoped pack has pinned the hash, the path stays as it is and resolves to no known module.
WTF::String transportSpecifierForPublicPath(ColloVm& vm, const WTF::String& canonical)
{
    if (!canonical.startsWith(publicTaskRootPrefix) || vm.deploy_hash.isEmpty())
        return canonical;
    WTF::String path = canonical.substring(publicTaskRootPrefix.length());
    if (path.isEmpty())
        return canonical;
    return WTF::makeString(routeModulePrefix, vm.deploy_hash, "/"_s, path);
}

} // namespace

namespace Collo {

WTF::String publicModulePathForKey(const WTF::String& module_key)
{
    auto scoped = parseDeployScopedKey(module_key);
    if (!scoped.scoped)
        return {};
    return WTF::makeString(publicTaskRootPrefix, scoped.path);
}

WTF::String publicModuleURLForKey(const WTF::String& module_key)
{
    WTF::String path = publicModulePathForKey(module_key);
    if (path.isNull())
        return {};
    return WTF::URL::fileURLWithFileSystemPath(path).string();
}

WTF::String resolveRegisteredSpecifier(ColloVm& vm, const WTF::String& specifier, const WTF::String& referrer)
{
    if (isNodeFsSpecifier(specifier)) {
        if (!vm.node_fs_enabled)
            return {};
        return WTF::String(builtinNodeFsModuleKey);
    }
    if (isNodeFsPromisesSpecifier(specifier)) {
        if (!vm.node_fs_enabled)
            return {};
        return WTF::String(builtinNodeFsPromisesModuleKey);
    }
    // file:///var/task/... is how import.meta.url spells the public namespace, as in
    // `import(new URL("./x.js", import.meta.url))`. An absolute file URL reduces to its path and goes through the
    // same steps, canonicalization, translation toward transport and the zygote check, so no spelling skips a check.
    // Other URLs remain invalid specifiers.
    WTF::String path_specifier = specifier;
    if (specifier.startsWith(fileUrlPrefix)) {
        WTF::URL url { specifier };
        if (!url.isValid() || !url.protocolIsFile())
            return {};
        path_specifier = url.fileSystemPath();
    }
    WTF::String canonical = canonicalModuleSpecifier(path_specifier, referrer);
    if (canonical.isNull() || canonical.isEmpty())
        return {};
    canonical = transportSpecifierForPublicPath(vm, canonical);
    if (!referrer.isEmpty() && canonical.startsWith(zygoteInternalModulePrefix))
        return {};
    return canonical;
}

// Fires from a promise reaction during a microtask drain. Its only action is the notification to Zig, which enqueues
// work there, so no JS runs here. The function belongs to the evaluating realm, so its global names the realm the
// report carries. host_runtime is read when the reaction fires because worker teardown nulls it, and settling an
// evaluation nobody can own any more is a no-op rather than an error.
static JSC::EncodedJSValue notifyModuleEvalSettled(
    JSC::JSGlobalObject* global_object, const WTF::String& specifier, bool resolved)
{
    auto* collo_global = dynamicDowncast<GlobalObject>(global_object);
    if (!collo_global)
        return JSC::JSValue::encode(JSC::jsUndefined());
    void* host_runtime = collo_global->owner().host_runtime.load(std::memory_order_acquire);
    if (!host_runtime)
        return JSC::JSValue::encode(JSC::jsUndefined());
    WTF::CString specifier_utf8 = specifier.utf8();
    ColloString specifier_string { reinterpret_cast<const uint8_t*>(specifier_utf8.data()), specifier_utf8.length() };
    collo_runtime_module_eval_settled(host_runtime, collo_global->realm().index, specifier_string, resolved ? 1 : 0);
    return JSC::JSValue::encode(JSC::jsUndefined());
}

static JSC::JSNativeStdFunction* moduleEvalSettlementFunction(
    ColloRealm& realm, const WTF::String& specifier, bool resolved)
{
    return JSC::JSNativeStdFunction::create(*realm.vm->vm, realm.global_object, 1,
        resolved ? "ColloModuleEvalSettledResolve"_s : "ColloModuleEvalSettledReject"_s,
        [specifier, resolved](JSC::JSGlobalObject* global_object, JSC::CallFrame*) -> JSC::EncodedJSValue {
            return notifyModuleEvalSettled(global_object, specifier, resolved);
        });
}

static ColloStatus registerModuleEvalSettlement(
    ColloRealm* realm, JSC::JSPromise* promise, const WTF::String& specifier)
{
    JSC::VM& jsc_vm = *realm->vm->vm;
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(jsc_vm);
    auto* resolve_function = moduleEvalSettlementFunction(*realm, specifier, true);
    auto* reject_function = moduleEvalSettlementFunction(*realm, specifier, false);
    if (!resolve_function || !reject_function)
        return COLLO_STATUS_OUT_OF_MEMORY;
    promise->performPromiseThen(jsc_vm, realm->global_object, resolve_function, reject_function, JSC::jsUndefined());
    if (scope.exception()) {
        scope.clearExceptionExceptTermination();
        return COLLO_STATUS_ERROR;
    }
    return COLLO_STATUS_OK;
}

ColloStatus awaitModulePromiseSync(ColloRealm* realm, JSC::JSPromise* promise, JSC::JSValue* out_value,
    const WTF::String* settlement_specifier, ColloValue** out_exception)
{
    if (!realmIsReady(realm) || !promise || !out_value)
        return COLLO_STATUS_INVALID_ARGUMENT;
    ColloVm* vm = realm->vm;
    if (vm->entered_count || vm->current_exec_ctx)
        return COLLO_STATUS_INVALID_ARGUMENT;

    *out_value = JSC::jsUndefined();
    clearOutException(out_exception);

    for (unsigned iteration = 0; iteration < maxSynchronousModuleDrains; ++iteration) {
        switch (promise->status()) {
        case JSC::JSPromise::Status::Fulfilled:
            *out_value = promise->result();
            return COLLO_STATUS_OK;
        case JSC::JSPromise::Status::Rejected:
            return statusOr(setJsException(vm, promise->result(), out_exception), COLLO_STATUS_JS_EXCEPTION);
        case JSC::JSPromise::Status::Pending: {
            // Only microtasks run here, never the worker's event loop.
            auto scope = DECLARE_TOP_EXCEPTION_SCOPE(*vm->vm);
            vm->vm->drainMicrotasks();
            if (scope.exception())
                return caughtExceptionStatus(vm, scope, out_exception);
            break;
        }
        }
        // One drainMicrotasks call empties the whole queue, so a promise still pending after it cannot progress
        // without host event-loop work and further drains would do nothing. The iteration bound is only a backstop.
        if (promise->status() == JSC::JSPromise::Status::Pending)
            break;
    }

    switch (promise->status()) {
    case JSC::JSPromise::Status::Fulfilled:
        *out_value = promise->result();
        return COLLO_STATUS_OK;
    case JSC::JSPromise::Status::Rejected:
        return statusOr(setJsException(vm, promise->result(), out_exception), COLLO_STATUS_JS_EXCEPTION);
    case JSC::JSPromise::Status::Pending:
        break;
    }

    // Top-level await: settlement needs host event-loop progress. The evaluate path parks the promise behind a
    // settlement callback. Without a host runtime, as on the zygote's VM, it still returns PENDING, which that caller
    // treats as fatal. The get_export path keeps the synchronous contract and fails closed.
    if (settlement_specifier) {
        if (vm->host_runtime.load(std::memory_order_acquire) != nullptr) {
            ColloStatus settlement_status = registerModuleEvalSettlement(realm, promise, *settlement_specifier);
            if (settlement_status != COLLO_STATUS_OK)
                return statusOr(
                    setInternalError(realm, "Failed to register module evaluation settlement."_s, out_exception),
                    settlement_status);
        }
        return COLLO_STATUS_PENDING;
    }

    return statusOr(
        setInternalError(realm,
            "Module evaluation did not settle within the synchronous loader drain budget; asynchronous module evaluation remains unsupported."_s,
            out_exception),
        COLLO_STATUS_UNSUPPORTED);
}

ColloStatus ensureModuleNamespace(ColloRealm* realm, const WTF::String& specifier, JSC::JSValue* out_namespace,
    const WTF::String* settlement_specifier, ColloValue** out_exception)
{
    if (!realmIsReady(realm) || !out_namespace)
        return COLLO_STATUS_INVALID_ARGUMENT;

    clearOutException(out_exception);

    if (auto it = realm->module_namespaces.find(specifier); it != realm->module_namespaces.end()) {
        *out_namespace = it->value.get();
        return COLLO_STATUS_OK;
    }

    ColloVm* vm = realm->vm;
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(*vm->vm);
    JSC::Identifier identifier = JSC::Identifier::fromString(*vm->vm, specifier);
    // No referrer: this import is issued by the host, not by a module.
    auto* promise = JSC::importModule(realm->global_object, identifier, JSC::Identifier(), nullptr, nullptr);
    if (scope.exception())
        return caughtExceptionStatus(vm, scope, out_exception);
    // setInternalError reports OK once it stored the error, and these failures are the module's: the caller sees a
    // thrown Error, as for one the module threw.
    if (!promise)
        return statusOr(setInternalError(realm, "Module import did not produce a promise."_s, out_exception),
            COLLO_STATUS_JS_EXCEPTION);

    JSC::JSValue namespace_value = JSC::jsUndefined();
    ColloStatus status = awaitModulePromiseSync(realm, promise, &namespace_value, settlement_specifier, out_exception);
    if (status != COLLO_STATUS_OK)
        return status;

    if (!namespace_value.isObject())
        return statusOr(setInternalError(realm, "Module namespace is not an object."_s, out_exception),
            COLLO_STATUS_JS_EXCEPTION);

    realm->module_namespaces.set(specifier, JSC::Strong<JSC::Unknown>(*vm->vm, namespace_value));
    *out_namespace = namespace_value;
    return COLLO_STATUS_OK;
}

JSC::JSPromise* GlobalObject::moduleLoaderImportModule(JSC::JSGlobalObject* global_object, JSC::JSModuleLoader*,
    JSC::JSString* module_name, RefPtr<JSC::ScriptFetchParameters> parameters, const JSC::SourceOrigin& source_origin,
    bool deferred)
{
    JSC::VM& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto reject = [&]() -> JSC::JSPromise* {
        auto* promise = JSC::JSPromise::create(vm, global_object->promiseStructure());
        return promise->rejectWithCaughtException(vm, scope);
    };

    WTF::String specifier = module_name->value(global_object);
    RETURN_IF_EXCEPTION(scope, reject());

    WTF::URL referrer_url = source_origin.url();
    WTF::String referrer = referrer_url.protocolIsFile() ? referrer_url.fileSystemPath() : referrer_url.string();
    ColloVm& collo_vm = asColloGlobal(global_object)->owner();
    WTF::String resolved = resolveRegisteredSpecifier(collo_vm, specifier, referrer);
    if (resolved.isNull() || resolved.isEmpty()) {
        auto* promise = JSC::JSPromise::create(vm, global_object->promiseStructure());
        promise->reject(vm, JSC::createError(global_object, invalidModuleSpecifierMessage(specifier, referrer)));
        return promise;
    }
    // Unconditional: a dynamic import never legitimately targets the zygote namespace, and eval'd code can arrive
    // here with an empty source origin, which slips past the referrer check in resolveRegisteredSpecifier.
    if (resolved.startsWith(zygoteInternalModulePrefix)) {
        auto* promise = JSC::JSPromise::create(vm, global_object->promiseStructure());
        promise->reject(vm,
            JSC::createError(
                global_object, WTF::makeString("Dynamic import cannot load internal module '"_s, resolved, "'."_s)));
        return promise;
    }

    // `deferred` passes straight through: deferred evaluation lives in JSC's loader, which settles a deferred import
    // with a different internal microtask.
    auto* promise = JSC::importModule(global_object, JSC::Identifier::fromString(vm, resolved),
        JSC::Identifier::fromString(vm, referrer), WTF::move(parameters), nullptr, deferred);
    RETURN_IF_EXCEPTION(scope, reject());
    return promise;
}

JSC::Identifier GlobalObject::moduleLoaderResolve(JSC::JSGlobalObject* global_object, JSC::JSModuleLoader*,
    JSC::JSValue key_value, JSC::JSValue referrer_value, RefPtr<JSC::ScriptFetcher>, bool)
{
    JSC::VM& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    WTF::String specifier = key_value.toWTFString(global_object);
    RETURN_IF_EXCEPTION(scope, {});

    WTF::String referrer;
    if (!referrer_value.isUndefined()) {
        referrer = referrer_value.toWTFString(global_object);
        RETURN_IF_EXCEPTION(scope, {});
    }

    ColloVm& collo_vm = asColloGlobal(global_object)->owner();
    WTF::String resolved = resolveRegisteredSpecifier(collo_vm, specifier, referrer);
    if (resolved.isNull() || resolved.isEmpty()) {
        JSC::throwException(
            global_object, scope, JSC::createError(global_object, invalidModuleSpecifierMessage(specifier, referrer)));
        return {};
    }
    return JSC::Identifier::fromString(vm, resolved);
}

// Selects source by the resolved module key alone; the referrer only names the importer in the rejection. A key no
// registered pack holds rejects at once: the server packs every module a route's code reaches through a relative
// string literal (server/routes/module_graph.zig), and the loader has no other source.
JSC::JSPromise* GlobalObject::moduleLoaderFetch(JSC::JSGlobalObject* global_object, JSC::JSModuleLoader*,
    JSC::JSValue key, const WTF::String& referrer, RefPtr<JSC::ScriptFetchParameters>, RefPtr<JSC::ScriptFetcher>)
{
    JSC::VM& vm = global_object->vm();
    auto* promise = JSC::JSPromise::create(vm, global_object->promiseStructure());
    auto scope = DECLARE_THROW_SCOPE(vm);

    WTF::String module_key = key.toWTFString(global_object);
    RETURN_IF_EXCEPTION(scope, promise->rejectWithCaughtException(vm, scope));

    ColloVm& collo_vm = asColloGlobal(global_object)->owner();
    if (auto* source_code = sourceCodeForRegisteredModule(collo_vm, module_key)) {
        scope.release();
        promise->resolve(global_object, vm, source_code);
        return promise;
    }

    promise->reject(vm, JSC::createError(global_object, moduleNotFoundMessage(module_key, referrer)));
    return promise;
}

JSC::JSObject* GlobalObject::moduleLoaderCreateImportMetaProperties(JSC::JSGlobalObject* global_object,
    JSC::JSModuleLoader*, JSC::JSValue key, JSC::JSModuleRecord*, RefPtr<JSC::ScriptFetcher>)
{
    JSC::VM& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    JSC::JSObject* meta = JSC::constructEmptyObject(vm, global_object->nullPrototypeObjectStructure());
    RETURN_IF_EXCEPTION(scope, nullptr);

    WTF::String key_string = key.toWTFString(global_object);
    RETURN_IF_EXCEPTION(scope, nullptr);

    // A deployed module presents its public /var/task identity as Node 22 does: url as a file: URL, filename and
    // dirname as plain paths, so path.join(import.meta.dirname, "x.json") lands on the fs index. The transport key
    // never reaches tenant JS. Any other key, such as the zygote corpus or a test pack, is exposed as itself in
    // filename and url.
    WTF::String public_path = publicModulePathForKey(key_string);
    if (!public_path.isNull()) {
        size_t last_slash = public_path.reverseFind('/');
        WTF::String public_dirname = public_path.substring(0, last_slash);
        WTF::String public_url = WTF::URL::fileURLWithFileSystemPath(public_path).string();

        meta->putDirect(vm, JSC::Identifier::fromString(vm, "url"_s), JSC::jsString(vm, public_url));
        RETURN_IF_EXCEPTION(scope, nullptr);
        meta->putDirect(vm, JSC::Identifier::fromString(vm, "filename"_s), JSC::jsString(vm, public_path));
        RETURN_IF_EXCEPTION(scope, nullptr);
        meta->putDirect(vm, JSC::Identifier::fromString(vm, "dirname"_s), JSC::jsString(vm, public_dirname));
        RETURN_IF_EXCEPTION(scope, nullptr);
        return meta;
    }

    meta->putDirect(vm, JSC::Identifier::fromString(vm, "filename"_s), key);
    RETURN_IF_EXCEPTION(scope, nullptr);

    meta->putDirect(vm, JSC::Identifier::fromString(vm, "url"_s), key);
    RETURN_IF_EXCEPTION(scope, nullptr);

    return meta;
}

} // namespace Collo

extern "C" ColloStatus collo_module_register_pack(
    ColloVm* vm, ColloMapping pack, const ColloModuleRegisterOptions* options)
{
    // Takes ownership first, so every return releases the mapping exactly once, and is declared before the lock, so
    // a mapping no provider kept is released after the JSC API lock drops.
    OwnedMapping pack_mapping { pack };
    if (!vm || !vm->isReady() || !pack.ptr)
        return COLLO_STATUS_INVALID_ARGUMENT;
    if (!pack.len || pack.len > modulePackMaxBytes)
        return COLLO_STATUS_INVALID_ARGUMENT;
    ColloModuleRegisterOptions normalized_options;
    ColloStatus options_status = normalizeModuleRegisterOptions(options, normalized_options);
    if (options_status != COLLO_STATUS_OK)
        return options_status;

    JSC::JSLockHolder locker(*vm->vm);
    return registerModulePackLocked(vm, pack_mapping, normalized_options);
}

extern "C" ColloStatus collo_module_evict_specifier(
    ColloVm* vm, ColloString specifier, ColloModuleEvictStats* out_stats)
{
    clearModuleEvictStats(out_stats);
    if (!vm || !vm->isReady() || !out_stats)
        return COLLO_STATUS_INVALID_ARGUMENT;

    WTF::String specifier_string;
    if (requireCanonicalSpecifier(specifier, {}, specifier_string) != COLLO_STATUS_OK)
        return COLLO_STATUS_INVALID_ARGUMENT;

    JSC::JSLockHolder locker(*vm->vm);
    evictModuleSourceLocked(vm, specifier_string, out_stats);
    return COLLO_STATUS_OK;
}

extern "C" ColloStatus collo_module_evict_lifetime(
    ColloVm* vm, ColloModuleLifetime lifetime, ColloModuleEvictStats* out_stats)
{
    clearModuleEvictStats(out_stats);
    if (!vm || !vm->isReady() || !out_stats)
        return COLLO_STATUS_INVALID_ARGUMENT;

    JSC::JSLockHolder locker(*vm->vm);
    return evictModuleLifetimeLocked(vm, lifetime, out_stats);
}

extern "C" ColloStatus collo_module_evaluate(ColloRealm* realm, ColloString specifier, ColloValue** out_exception)
{
    Collo::clearOutException(out_exception);

    if (!realmIsReady(realm))
        return COLLO_STATUS_INVALID_ARGUMENT;

    // The settlement callback reports the specifier as the caller spelled it rather than its canonical form: the Zig
    // route-module table is keyed by what the caller passed, and a settlement under any other name strands its
    // waiters.
    WTF::String caller_specifier;
    if (Collo::stringToWTFString(specifier, caller_specifier) != COLLO_STATUS_OK)
        return COLLO_STATUS_INVALID_ARGUMENT;

    WTF::String specifier_string;
    if (requireCanonicalSpecifier(specifier, {}, specifier_string) != COLLO_STATUS_OK)
        return COLLO_STATUS_INVALID_ARGUMENT;

    JSC::JSLockHolder locker(*realm->vm->vm);
    JSC::JSValue ignored = JSC::jsUndefined();
    return Collo::ensureModuleNamespace(realm, specifier_string, &ignored, &caller_specifier, out_exception);
}

extern "C" ColloStatus collo_module_get_export(ColloRealm* realm, ColloString specifier, ColloString export_name,
    ColloValue** out_value, ColloValue** out_exception)
{
    if (out_value)
        *out_value = nullptr;
    Collo::clearOutException(out_exception);

    if (!realmIsReady(realm) || !out_value)
        return COLLO_STATUS_INVALID_ARGUMENT;

    WTF::String specifier_string;
    if (requireCanonicalSpecifier(specifier, {}, specifier_string) != COLLO_STATUS_OK)
        return COLLO_STATUS_INVALID_ARGUMENT;

    WTF::String export_string;
    if (Collo::stringToWTFString(export_name, export_string) != COLLO_STATUS_OK || export_string.isEmpty())
        return COLLO_STATUS_INVALID_ARGUMENT;

    ColloVm* vm = realm->vm;
    JSC::JSLockHolder locker(*vm->vm);

    JSC::JSValue namespace_value = JSC::jsUndefined();
    ColloStatus status
        = Collo::ensureModuleNamespace(realm, specifier_string, &namespace_value, nullptr, out_exception);
    if (status != COLLO_STATUS_OK)
        return status;

    auto* namespace_object = dynamicDowncast<JSC::JSObject>(namespace_value);
    if (!namespace_object)
        return Collo::statusOr(Collo::setInternalError(realm, "Module namespace is not an object."_s, out_exception),
            COLLO_STATUS_JS_EXCEPTION);

    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(*vm->vm);
    JSC::JSValue export_value
        = namespace_object->get(realm->global_object, JSC::Identifier::fromString(*vm->vm, export_string));
    if (scope.exception())
        return Collo::caughtExceptionStatus(vm, scope, out_exception);

    return Collo::makeValueHandle(vm, export_value, out_value);
}

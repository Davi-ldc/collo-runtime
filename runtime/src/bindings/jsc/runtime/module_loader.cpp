// The module loader: holds the one module pack a VM registers, resolves import specifiers to registry keys, hands JSC
// the source of a key the pack holds, refuses every other key as a module not found, and evaluates modules for the
// host. Runs on the VM thread with the JSC API lock held.
//
// Sources belong to the VM and every realm fetches from them, while each realm's JSC module registry holds its own
// module records: a module evaluates once per realm that imports it, with top-level state of its own there.
//
// A pack arrives as a mapping of a sealed memfd that every worker of a definition maps; common/ipc/module_pack.zig
// owns its layout, and the copies of the format below must match that file. A worker parses its pack in Zig before
// handing it over, but this file trusts only what it checks: registration reads the header, and every later read of
// an index entry, a record, a specifier or a source checks its offset and length against the mapping first. A
// module's source provider is created when JSC first fetches it, and its text is the pack's bytes wrapped as an
// external string, never copied or decoded, so every worker of a definition shares those pages. Each such string
// holds a reference on the pack, so the mapping outlives every string a source shares, Function.prototype.toString
// results included, and ends with the last of them (ColloModulePack in state.h).
//
// A module's key is its public specifier: `/var/task/<path>` for a worker definition's modules, and tenant code sees
// that same key in import.meta, stack frames and loader errors. Relative specifiers resolve lexically against the
// referrer's key, as Node ESM resolution does against import.meta.dirname, so the server's keys keep each module's
// place in its directory tree (server/routes/artifacts.zig).

#include "jsc/runtime/state.h"

#include <JavaScriptCore/JSNativeStdFunction.h>
#include <JavaScriptCore/SourceProvider.h>
#include <wtf/FastMalloc.h>
#include <wtf/StdLibExtras.h>
#include <wtf/Vector.h>
#include <wtf/text/ExternalStringImpl.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/StringView.h>

#include <cstddef>
#include <cstring>
#include <new>
#include <optional>
#include <span>
#include <utility>

using namespace JSC;

namespace {

// The pack format of common/ipc/module_pack.zig: `magic`, `version`, `module_flag_utf16`, `empty_index_module`, the
// sizes of Header, ModuleRecord and IndexEntry, and the offsets of the fields read here. Its two bounds come from
// abi.h, whose constants runtime/tests/contracts/abi.zig compares with the format's.
constexpr uint32_t modulePackMagic = 0x4d4f4c43;
constexpr uint16_t modulePackVersion = 3;
constexpr size_t modulePackMaxModules = COLLO_MODULE_PACK_MAX_MODULES;
constexpr size_t modulePackMaxBytes = COLLO_MODULE_PACK_MAX_BYTES;
constexpr uint32_t modulePackFlagUtf16 = 1u << 0;
constexpr uint32_t modulePackEmptyIndexModule = UINT32_MAX;
constexpr size_t modulePackHeaderSize = 32;
constexpr size_t modulePackRecordSize = 20;
constexpr size_t modulePackIndexEntrySize = 8;
constexpr size_t headerMagicOffset = 0;
constexpr size_t headerVersionOffset = 4;
constexpr size_t headerFlagsOffset = 6;
constexpr size_t headerModuleCountOffset = 8;
constexpr size_t headerIndexCapacityOffset = 12;
constexpr size_t headerTotalLenOffset = 28;
constexpr size_t recordSpecifierOffsetOffset = 0;
constexpr size_t recordSpecifierLenOffset = 4;
constexpr size_t recordSourceOffsetOffset = 8;
constexpr size_t recordSourceLenOffset = 12;
constexpr size_t recordFlagsOffset = 16;
constexpr size_t indexHashOffset = 0;
constexpr size_t indexModuleOffset = 4;

constexpr auto builtinNodeFsModuleKey = "node:fs"_s;
constexpr auto builtinNodeFsPromisesModuleKey = "node:fs/promises"_s;
constexpr auto fileUrlPrefix = "file://"_s;
// The zygote's own namespace, used by the warmup corpus. JSC's module registry keeps the records the warmup
// evaluated after the zygote unregisters its pack, so every worker inherits them through copy-on-write; only an
// evaluation the host starts, with an empty referrer, may resolve into it. A prefix match on it cannot catch a tenant
// module, because a worker refuses a definition with a key outside `/var/task/` (`validateDefinition` in
// common/ipc/module_pack.zig).
constexpr auto zygoteInternalModulePrefix = "/__collo/"_s;
// Bound on the microtask drains awaitModulePromiseSync runs while a module promise settles without the worker's
// event loop, set to the pack module cap so a deep but valid graph can settle. One drain empties the whole queue, so
// the loop stops at the first drain that leaves the promise pending and the bound is only a backstop.
constexpr unsigned maxSynchronousModuleDrains = static_cast<unsigned>(modulePackMaxModules);

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

uint8_t byteAt(std::span<const std::byte> bytes, size_t offset) { return std::to_integer<uint8_t>(bytes[offset]); }

uint16_t readLe16(std::span<const std::byte> bytes, size_t offset)
{
    return static_cast<uint16_t>(byteAt(bytes, offset) | (byteAt(bytes, offset + 1) << 8));
}

uint32_t readLe32(std::span<const std::byte> bytes, size_t offset)
{
    return static_cast<uint32_t>(byteAt(bytes, offset)) | (static_cast<uint32_t>(byteAt(bytes, offset + 1)) << 8)
        | (static_cast<uint32_t>(byteAt(bytes, offset + 2)) << 16)
        | (static_cast<uint32_t>(byteAt(bytes, offset + 3)) << 24);
}

uint64_t readLe64(std::span<const std::byte> bytes, size_t offset)
{
    return static_cast<uint64_t>(readLe32(bytes, offset)) | (static_cast<uint64_t>(readLe32(bytes, offset + 4)) << 32);
}

// The cpp.md bounds form: `[offset, offset + length)` lies inside `size` bytes.
bool rangeInside(size_t size, size_t offset, size_t length) { return offset <= size && length <= size - offset; }

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
uint32_t modulePackHashSpecifier(std::span<const std::byte> bytes)
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
            a = (static_cast<uint64_t>(readLe32(bytes, 0)) << 32) | readLe32(bytes, quarter);
            b = (static_cast<uint64_t>(readLe32(bytes, end)) << 32) | readLe32(bytes, end - quarter);
        } else if (!bytes.empty()) {
            a = (static_cast<uint64_t>(byteAt(bytes, 0)) << 16)
                | (static_cast<uint64_t>(byteAt(bytes, bytes.size() >> 1)) << 8) | byteAt(bytes, bytes.size() - 1);
        }
    } else {
        size_t i = 0;
        if (bytes.size() >= 48) {
            while (i + 48 < bytes.size()) {
                state0 = wyMix(readLe64(bytes, i) ^ secret[1], readLe64(bytes, i + 8) ^ state0);
                state1 = wyMix(readLe64(bytes, i + 16) ^ secret[2], readLe64(bytes, i + 24) ^ state1);
                state2 = wyMix(readLe64(bytes, i + 32) ^ secret[3], readLe64(bytes, i + 40) ^ state2);
                i += 48;
            }
            state0 ^= state1 ^ state2;
        }
        while (i + 16 < bytes.size()) {
            state0 = wyMix(readLe64(bytes, i) ^ secret[1], readLe64(bytes, i + 8) ^ state0);
            i += 16;
        }
        a = readLe64(bytes, bytes.size() - 16);
        b = readLe64(bytes, bytes.size() - 8);
    }

    a ^= secret[1];
    b ^= state0;
    wyMum(a, b);
    const uint64_t hash = wyMix(a ^ secret[0] ^ bytes.size(), b ^ secret[1]);
    return static_cast<uint32_t>(hash ^ (hash >> 32));
}

// Owns the ColloMapping collo_module_register_pack is handed and ends it with collo_runtime_mapping_release unless
// release() handed it to the pack object first. Taking ownership on entry is what makes every return path, failures
// included, end the mapping exactly once.
class OwnedMapping {
public:
    explicit OwnedMapping(ColloMapping mapping)
        : m_mapping(mapping)
    {
    }

    OwnedMapping(const OwnedMapping&) = delete;
    OwnedMapping& operator=(const OwnedMapping&) = delete;
    OwnedMapping(OwnedMapping&&) = delete;
    OwnedMapping& operator=(OwnedMapping&&) = delete;

    ~OwnedMapping()
    {
        if (m_mapping.ptr)
            collo_runtime_mapping_release(m_mapping);
    }

    ColloMapping get() const { return m_mapping; }
    std::span<const std::byte> bytes() const
    {
        return std::as_bytes(std::span<const uint8_t> { m_mapping.ptr, m_mapping.len });
    }
    // For the caller that just gave the mapping to an owner of its own.
    void release() { m_mapping = ColloMapping { nullptr, 0 }; }

private:
    ColloMapping m_mapping;
};

void releasePackReference(void* pack, void*, unsigned) { static_cast<ColloModulePack*>(pack)->deref(); }

// A module's source provider. It holds only the module's text, which for a pack module is an external string over
// the mapping that keeps the pack alive by itself, so the provider owns no reference of its own on the pack.
class ColloSourceProvider final : public JSC::SourceProvider {
public:
    // Null when the allocation fails. The origin and the source URL are both the file: URL of `module_key`, which
    // is how stack frames name the module.
    static WTF::RefPtr<ColloSourceProvider> tryCreate(WTF::String&& source, const WTF::String& module_key)
    {
        WTF::URL url = WTF::URL::fileURLWithFileSystemPath(module_key);
        ColloSourceProvider* provider = nullptr;
        if (!WTF::tryFastMalloc(sizeof(ColloSourceProvider)).getValue(provider))
            return nullptr;
        provider = new (NotNull, provider) ColloSourceProvider(WTF::move(source), url);
        return WTF::adoptRef(*provider);
    }

    unsigned hash() const override { return m_source.impl() ? m_source.impl()->hash() : 0; }

    WTF::StringView source() const override { return m_source; }

private:
    ColloSourceProvider(WTF::String&& source, const WTF::URL& url)
        : JSC::SourceProvider(JSC::SourceOrigin(url), WTF::String(url.string()), WTF::String(),
              JSC::SourceTaintedOrigin::Untainted, TextPosition(), JSC::SourceProviderSourceType::Module)
        , m_source(WTF::move(source))
    {
    }

    WTF::String m_source;
};

// The record of the pack module whose specifier is `key`. A key that cannot be spelled as UTF-8 names no module.
std::optional<uint32_t> findPackModule(const ColloModulePack& pack, const WTF::String& key)
{
    if (key.is8Bit() && key.containsOnlyASCII())
        return pack.find(std::as_bytes(key.span8()));
    auto found = key.tryGetUTF8([&pack](std::span<const char8_t> utf8) { return pack.find(std::as_bytes(utf8)); });
    if (!found)
        return std::nullopt;
    return *found;
}

enum class SourceLookup : uint8_t {
    Found,
    NotFound,
    OutOfMemory,
};

// The source of the module `module_key` names into `*out_source`: one of the node:fs builtins on a worker that
// enabled them, or a module of the VM's pack, whose provider is created and cached on its first fetch.
SourceLookup sourceCodeForRegisteredModule(
    ColloVm& collo_vm, const WTF::String& module_key, JSC::JSSourceCode** out_source)
{
    *out_source = nullptr;
    if (module_key == builtinNodeFsModuleKey) {
        if (!collo_vm.node_fs_enabled)
            return SourceLookup::NotFound;

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
        *out_source = JSC::JSSourceCode::create(*collo_vm.vm, JSC::SourceCode(WTF::move(provider), 1, 1));
        return SourceLookup::Found;
    }

    if (module_key == builtinNodeFsPromisesModuleKey) {
        if (!collo_vm.node_fs_enabled)
            return SourceLookup::NotFound;

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
        *out_source = JSC::JSSourceCode::create(*collo_vm.vm, JSC::SourceCode(WTF::move(provider), 1, 1));
        return SourceLookup::Found;
    }

    ColloModuleSources& sources = collo_vm.module_sources;
    if (!sources.pack)
        return SourceLookup::NotFound;
    std::optional<uint32_t> record = findPackModule(*sources.pack, module_key);
    if (!record)
        return SourceLookup::NotFound;
    // find() returns only an index below the module count, which is the providers' length while a pack is held.
    WTF::RefPtr<JSC::SourceProvider>& provider = sources.providers[*record];
    if (!provider) {
        WTF::String source = sources.pack->source(*record);
        if (source.isNull())
            return SourceLookup::NotFound;
        provider = ColloSourceProvider::tryCreate(WTF::move(source), module_key);
        if (!provider)
            return SourceLookup::OutOfMemory;
    }
    WTF::Ref<JSC::SourceProvider> provider_ref { *provider };
    *out_source = JSC::JSSourceCode::create(*collo_vm.vm, JSC::SourceCode(WTF::move(provider_ref), 1, 1));
    return SourceLookup::Found;
}

// Checks the pack header and makes the mapping the VM's module source. Records, specifiers and sources are checked
// when a module is fetched, so a module never imported costs nothing here.
ColloStatus registerModulePackLocked(ColloVm& vm, OwnedMapping& mapping)
{
    if (vm.module_sources.pack)
        return COLLO_STATUS_ALREADY_EXISTS;

    const auto bytes = mapping.bytes();
    if (bytes.size() < modulePackHeaderSize || bytes.size() > modulePackMaxBytes)
        return COLLO_STATUS_INVALID_ARGUMENT;
    if (readLe32(bytes, headerMagicOffset) != modulePackMagic)
        return COLLO_STATUS_INVALID_ARGUMENT;
    if (readLe16(bytes, headerVersionOffset) != modulePackVersion || readLe16(bytes, headerFlagsOffset))
        return COLLO_STATUS_INVALID_ARGUMENT;
    const uint32_t module_count = readLe32(bytes, headerModuleCountOffset);
    const uint32_t index_capacity = readLe32(bytes, headerIndexCapacityOffset);
    if (!module_count || module_count > modulePackMaxModules)
        return COLLO_STATUS_INVALID_ARGUMENT;
    // The capacity is at least the module count, so it is nonzero before the power-of-two test.
    if (index_capacity < module_count || (index_capacity & (index_capacity - 1)))
        return COLLO_STATUS_INVALID_ARGUMENT;
    if (readLe32(bytes, headerTotalLenOffset) != bytes.size())
        return COLLO_STATUS_INVALID_ARGUMENT;
    // The records follow the header and the index follows the records; both must lie inside the mapping, which is
    // what lets ColloModulePack read them without further checks. The capacity is a u32 and the count at most
    // modulePackMaxModules, so neither size overflows.
    const size_t records_len = static_cast<size_t>(module_count) * modulePackRecordSize;
    const size_t index_offset = modulePackHeaderSize + records_len;
    const size_t index_len = static_cast<size_t>(index_capacity) * modulePackIndexEntrySize;
    if (!rangeInside(bytes.size(), index_offset, index_len))
        return COLLO_STATUS_INVALID_ARGUMENT;

    WTF::Vector<WTF::RefPtr<JSC::SourceProvider>> providers;
    if (!providers.tryReserveInitialCapacity(module_count) || !providers.tryGrow(module_count))
        return COLLO_STATUS_OUT_OF_MEMORY;
    WTF::RefPtr<ColloModulePack> pack = ColloModulePack::tryCreate(mapping.get(), module_count, index_capacity);
    if (!pack)
        return COLLO_STATUS_OUT_OF_MEMORY;
    mapping.release();

    vm.module_sources.pack = WTF::move(pack);
    vm.module_sources.providers = WTF::move(providers);
    return COLLO_STATUS_OK;
}

Collo::GlobalObject* asColloGlobal(JSC::JSGlobalObject* global_object)
{
    return uncheckedDowncast<Collo::GlobalObject>(global_object);
}

WTF::String invalidModuleSpecifierMessage(const WTF::String& specifier, const WTF::String& referrer)
{
    if (referrer.isEmpty())
        return WTF::makeString("Invalid module specifier '"_s, specifier, "'."_s);
    return WTF::makeString("Invalid module specifier '"_s, specifier, "' from '"_s, referrer, "'."_s);
}

// The rejection of a fetch for a key the pack does not hold, naming the module that imported it when there is one.
WTF::String moduleNotFoundMessage(const WTF::String& module_key, const WTF::String& referrer)
{
    if (referrer.isEmpty())
        return WTF::makeString("Cannot find module '"_s, module_key, "'."_s);
    return WTF::makeString("Cannot find module '"_s, module_key, "' imported from '"_s, referrer, "'."_s);
}

} // namespace

WTF::RefPtr<ColloModulePack> ColloModulePack::tryCreate(
    ColloMapping mapping, uint32_t module_count, uint32_t index_capacity)
{
    ColloModulePack* pack = nullptr;
    if (!WTF::tryFastMalloc(sizeof(ColloModulePack)).getValue(pack))
        return nullptr;
    pack = new (NotNull, pack) ColloModulePack(mapping, module_count, index_capacity);
    return WTF::adoptRef(*pack);
}

ColloModulePack::ColloModulePack(ColloMapping mapping, uint32_t module_count, uint32_t index_capacity)
    : m_mapping(mapping)
    , m_module_count(module_count)
    , m_index_capacity(index_capacity)
{
}

ColloModulePack::~ColloModulePack() { collo_runtime_mapping_release(m_mapping); }

std::span<const std::byte> ColloModulePack::bytes() const
{
    return std::as_bytes(std::span<const uint8_t> { m_mapping.ptr, m_mapping.len });
}

std::optional<uint32_t> ColloModulePack::find(std::span<const std::byte> key) const
{
    // Every pack specifier has at least one byte, and memcmp below must not see an empty key's null data.
    if (key.empty())
        return std::nullopt;
    const auto pack = bytes();
    const uint32_t hash = modulePackHashSpecifier(key);
    const size_t index_offset = modulePackHeaderSize + static_cast<size_t>(m_module_count) * modulePackRecordSize;
    const size_t mask = static_cast<size_t>(m_index_capacity) - 1;
    size_t slot = static_cast<size_t>(hash) & mask;
    // Registration put the records and the index inside the mapping, so entries and records read without a check;
    // what they point at is checked here. The probe visits at most the capacity, so a full index still ends it.
    for (uint32_t probes = 0; probes < m_index_capacity; ++probes) {
        const size_t entry = index_offset + slot * modulePackIndexEntrySize;
        const uint32_t module_index = readLe32(pack, entry + indexModuleOffset);
        if (module_index == modulePackEmptyIndexModule)
            return std::nullopt;
        if (readLe32(pack, entry + indexHashOffset) == hash && module_index < m_module_count) {
            const size_t record = modulePackHeaderSize + static_cast<size_t>(module_index) * modulePackRecordSize;
            const size_t specifier_offset = readLe32(pack, record + recordSpecifierOffsetOffset);
            const size_t specifier_len = readLe32(pack, record + recordSpecifierLenOffset);
            if (specifier_len == key.size() && rangeInside(pack.size(), specifier_offset, specifier_len)
                && !std::memcmp(pack.data() + specifier_offset, key.data(), specifier_len))
                return module_index;
        }
        slot = (slot + 1) & mask;
    }
    return std::nullopt;
}

WTF::String ColloModulePack::source(uint32_t index)
{
    ASSERT(index < m_module_count);
    const auto pack = bytes();
    const size_t record = modulePackHeaderSize + static_cast<size_t>(index) * modulePackRecordSize;
    const size_t offset = readLe32(pack, record + recordSourceOffsetOffset);
    const size_t length = readLe32(pack, record + recordSourceLenOffset);
    const uint32_t flags = readLe32(pack, record + recordFlagsOffset);
    if (!rangeInside(pack.size(), offset, length) || (flags & ~modulePackFlagUtf16))
        return {};
    const bool utf16 = flags & modulePackFlagUtf16;
    // The mapping starts on a page boundary, so an even offset is an address aligned for char16_t.
    if (utf16 && ((offset % 2) || (length % 2)))
        return {};
    if (!length)
        return WTF::emptyString();

    // The string's reference on the pack, which releasePackReference drops when the string dies. The pinned WTF
    // allocates the string and its free function with an unchecked new (ExternalStringImpl::create in
    // ExternalStringImpl.cpp), so an allocation failure there ends the worker instead of returning.
    ref();
    const std::span<const uint8_t> source_bytes { m_mapping.ptr + offset, length };
    if (utf16) {
        const auto characters = WTF::spanReinterpretCast<const char16_t>(source_bytes);
        return WTF::String(WTF::ExternalStringImpl::create(characters, this, releasePackReference));
    }
    const std::span<const Latin1Character> characters { source_bytes };
    return WTF::String(WTF::ExternalStringImpl::create(characters, this, releasePackReference));
}

namespace Collo {

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
    // file:///var/task/... is how import.meta.url spells a key, as in `import(new URL("./x.js", import.meta.url))`.
    // An absolute file URL reduces to its path and goes through the same steps, canonicalization and the zygote
    // check, so no spelling skips a check. Other URLs remain invalid specifiers.
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
        (void)scope.clearExceptionExceptTermination();
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
        return statusOr(
            setInternalError(realm, "Module namespace is not an object."_s, out_exception), COLLO_STATUS_JS_EXCEPTION);

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

// Selects source by the resolved module key alone; the referrer only names the importer in the rejection. A key the
// pack does not hold rejects at once: the server packs every module inside the definition's root that a route's code
// reaches through a relative string literal (server/routes/module_graph.zig), and the loader has no other source.
JSC::JSPromise* GlobalObject::moduleLoaderFetch(JSC::JSGlobalObject* global_object, JSC::JSModuleLoader*,
    JSC::JSValue key, const WTF::String& referrer, RefPtr<JSC::ScriptFetchParameters>, RefPtr<JSC::ScriptFetcher>)
{
    JSC::VM& vm = global_object->vm();
    auto* promise = JSC::JSPromise::create(vm, global_object->promiseStructure());
    auto scope = DECLARE_THROW_SCOPE(vm);

    WTF::String module_key = key.toWTFString(global_object);
    RETURN_IF_EXCEPTION(scope, promise->rejectWithCaughtException(vm, scope));

    ColloVm& collo_vm = asColloGlobal(global_object)->owner();
    JSC::JSSourceCode* source_code = nullptr;
    switch (sourceCodeForRegisteredModule(collo_vm, module_key, &source_code)) {
    case SourceLookup::Found:
        scope.release();
        promise->resolve(global_object, vm, source_code);
        return promise;
    case SourceLookup::OutOfMemory:
        promise->reject(vm, JSC::createOutOfMemoryError(global_object));
        return promise;
    case SourceLookup::NotFound:
        break;
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

    // A pack module's key is its path, presented as Node 22 presents a module: url as a file: URL, filename and
    // dirname as plain paths. Only the pack holds the modules: in a worker `/var/task` is an empty read-only
    // directory, so node:fs finds no file beside a module. A key that is not a path, such as a node:fs builtin's, is
    // exposed as itself in filename and url.
    if (!key_string.startsWith('/')) {
        meta->putDirect(vm, JSC::Identifier::fromString(vm, "filename"_s), key);
        RETURN_IF_EXCEPTION(scope, nullptr);
        meta->putDirect(vm, JSC::Identifier::fromString(vm, "url"_s), key);
        RETURN_IF_EXCEPTION(scope, nullptr);
        return meta;
    }

    const size_t last_slash = key_string.reverseFind('/');
    WTF::String dirname = last_slash ? key_string.substring(0, last_slash) : WTF::String("/"_s);
    WTF::String url = WTF::URL::fileURLWithFileSystemPath(key_string).string();

    meta->putDirect(vm, JSC::Identifier::fromString(vm, "url"_s), JSC::jsString(vm, url));
    RETURN_IF_EXCEPTION(scope, nullptr);
    meta->putDirect(vm, JSC::Identifier::fromString(vm, "filename"_s), JSC::jsString(vm, key_string));
    RETURN_IF_EXCEPTION(scope, nullptr);
    meta->putDirect(vm, JSC::Identifier::fromString(vm, "dirname"_s), JSC::jsString(vm, dirname));
    RETURN_IF_EXCEPTION(scope, nullptr);
    return meta;
}

} // namespace Collo

extern "C" ColloStatus collo_module_register_pack(ColloVm* vm, ColloMapping pack)
{
    // Takes ownership first, so every return releases the mapping exactly once unless the pack object took it, and is
    // declared before the lock, so a mapping nothing kept is released after the JSC API lock drops.
    OwnedMapping mapping { pack };
    if (!vm || !vm->isReady() || !pack.ptr)
        return COLLO_STATUS_INVALID_ARGUMENT;

    JSC::JSLockHolder locker(*vm->vm);
    return registerModulePackLocked(*vm, mapping);
}

extern "C" ColloStatus collo_module_unregister_pack(ColloVm* vm)
{
    if (!vm || !vm->isReady())
        return COLLO_STATUS_INVALID_ARGUMENT;

    JSC::JSLockHolder locker(*vm->vm);
    if (!vm->module_sources.pack)
        return COLLO_STATUS_INVALID_ARGUMENT;
    // Clearing the cached namespaces drops only the bridge's own JSC::Strong roots, under the lock: JSC's module
    // registry keeps every record the old pack evaluated, so a later import of one of those keys still finds it.
    // Dropping the providers ends the pack's mapping only once no JSC module record or shared string still holds one
    // of its sources.
    for (auto& realm : vm->realms)
        realm->module_namespaces.clear();
    vm->module_sources.clear();
    return COLLO_STATUS_OK;
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

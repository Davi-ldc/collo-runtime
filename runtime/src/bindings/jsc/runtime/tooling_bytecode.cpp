// Bytecode generation for module packs: parses one module source exactly as the worker loader will and serializes
// its UnlinkedModuleProgramCodeBlock as a CachedBytecode blob for the pack's bytecode segment. It runs in whichever
// process builds a pack, on any thread; JSC::generateModuleBytecode takes the tooling VM's API lock.
//
// The loader's ColloSourceProvider::cachedBytecode() hands the blob back to JSC, which checks it against the module's
// SourceCode and parses the source instead when they do not match. A mismatch is therefore silent and only wastes
// the blob, which is why the provider built here must match ColloSourceProvider in module_loader.cpp: the same URL
// derivation, source decoding, start position and source type. A change to either side changes both.
//
// No ColloVm or global object is involved, since generateModuleBytecode needs only a VM. The process-wide tooling VM
// is created on first use and leaked, so its heap stays resident until the process exits.
#include "jsc/runtime/state.h"

#include <JavaScriptCore/BytecodeCacheError.h>
#include <JavaScriptCore/CachedBytecode.h>
#include <JavaScriptCore/Options.h>
#include <JavaScriptCore/SourceProvider.h>
#include <wtf/FileHandle.h>
#include <wtf/text/CString.h>
#include <wtf/text/MakeString.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <new>

namespace {

// Matches ColloSourceProvider: the SourceOrigin URL comes from the absolute module path, the source URL is the module
// key, the origin is untainted, the start position is the default and the source type is Module. Pack specifiers
// always begin with '/' (validateSpecifier in common/ipc/module_pack.zig), so absoluteModulePath in the loader
// leaves them unchanged; the branch is kept so the two stay textually parallel. JSC's StringSourceProvider carries
// all of that, and it is the one provider class the serializer handles in every engine configuration: with
// USE_BUN_JSC_ADDITIONS, which the engine build enables, CachedTypes.cpp reads only base SourceProvider state, but
// without it the file casts every Program and Module provider to StringSourceProvider.
WTF::Ref<JSC::StringSourceProvider> makeToolingProvider(const WTF::String& moduleKey, WTF::String&& source)
{
    WTF::String absolutePath = moduleKey.startsWith('/') ? moduleKey : WTF::makeString("/"_s, moduleKey);
    WTF::URL url = WTF::URL::fileURLWithFileSystemPath(absolutePath);
    return JSC::StringSourceProvider::create(source, JSC::SourceOrigin(url), WTF::String(moduleKey),
        JSC::SourceTaintedOrigin::Untainted, TextPosition(), JSC::SourceProviderSourceType::Module);
}

JSC::VM& toolingVM()
{
    static JSC::VM* vm = nullptr;
    static std::once_flag once;
    std::call_once(once, [] {
        // WTF::initializeMainThread and JSC::initialize run their bodies once per process, so whichever of this and
        // collo_vm_create runs first configures JSC for both.
        // FIXME: Only useSharedArrayBuffer matches collo_vm_create. A process that generates bytecode before creating
        // its first VM runs every later VM without the thread options collo_vm_create sets for workers: compiler
        // threads, GC markers, marked-block warm-up and polling traps.
        WTF::initializeMainThread();
        JSC::initialize([] { JSC::Options::useSharedArrayBuffer() = true; });
        vm = &JSC::VM::create(JSC::HeapType::Small).leakRef();
    });
    return *vm;
}

} // namespace

// Generates the CachedBytecode blob for one ESM module. `specifier_utf8` must be the exact pack specifier the loader
// will register the module under. On success `*out_bytes` and `*out_len` carry the blob in malloc'd storage the
// caller frees with collo_tool_bytecode_release. An empty source or specifier fails with
// COLLO_STATUS_INVALID_ARGUMENT, a parse or serialization failure with COLLO_STATUS_ERROR after a diagnostic on
// stderr, since ColloStatus carries no message, and a failed copy with COLLO_STATUS_OUT_OF_MEMORY.
extern "C" ColloStatus collo_tool_generate_module_bytecode(
    ColloBuffer source_utf8, ColloString specifier_utf8, uint8_t** out_bytes, size_t* out_len)
{
    if (!out_bytes || !out_len || !source_utf8.ptr || source_utf8.len == 0 || !specifier_utf8.ptr
        || specifier_utf8.len == 0)
        return COLLO_STATUS_INVALID_ARGUMENT;
    *out_bytes = nullptr;
    *out_len = 0;

    JSC::VM& vm = toolingVM();

    // Decoded as ColloSourceProvider::sourceString() decodes it: the cache key carries the hash of the decoded
    // string, so a different decode would never match.
    WTF::String source = WTF::String::fromUTF8ReplacingInvalidSequences(std::span<const Latin1Character> {
        reinterpret_cast<const Latin1Character*>(source_utf8.ptr), source_utf8.len });
    WTF::String specifier = WTF::String::fromUTF8ReplacingInvalidSequences(std::span<const Latin1Character> {
        reinterpret_cast<const Latin1Character*>(specifier_utf8.ptr), specifier_utf8.len });

    // Wrapped as the loader wraps its provider, JSC::SourceCode(provider, 1, 1), so the blob covers the same range,
    // the whole provider. The cache key compares the range's length, not its start line or column.
    JSC::SourceCode sourceCode(makeToolingProvider(specifier, WTF::move(source)), 1, 1);

    // An invalid FileHandle is what CachedTypes.cpp's own overload without a handle passes; the returned blob is the
    // product.
    auto fileHandle = FileSystem::FileHandle();
    JSC::BytecodeCacheError cacheError;
    WTF::RefPtr<JSC::CachedBytecode> cachedBytecode
        = JSC::generateModuleBytecode(vm, sourceCode, fileHandle, cacheError);
    if (!cachedBytecode || cacheError.isValid()) {
        WTF::CString specifierUtf8 = specifier.utf8();
        WTF::CString message = cacheError.isValid() ? cacheError.message().utf8()
                                                    : WTF::CString("bytecode serialization produced no output");
        std::fprintf(
            stderr, "collo: bytecode generation failed for %s: %s\n", specifierUtf8.data(), message.data());
        return COLLO_STATUS_ERROR;
    }

    const auto blob = cachedBytecode->span();
    if (blob.empty())
        return COLLO_STATUS_ERROR;
    uint8_t* copy = static_cast<uint8_t*>(std::malloc(blob.size()));
    if (!copy)
        return COLLO_STATUS_OUT_OF_MEMORY;
    std::memcpy(copy, blob.data(), blob.size());
    *out_bytes = copy;
    *out_len = blob.size();
    return COLLO_STATUS_OK;
}

extern "C" void collo_tool_bytecode_release(uint8_t* bytes) { std::free(bytes); }

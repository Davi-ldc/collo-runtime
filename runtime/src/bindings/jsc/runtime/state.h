// Private state of the JavaScriptCore bridge: ColloVm, the value handles the ABI lends to Zig, the Collo global object
// and the per-VM registries host functions share. None of it is ABI; the exported surface is
// bindings/include/collo/abi.h and its Zig facade, bindings/root.zig.
//
// Everything here belongs to one VM thread, the zygote's before a fork and the worker's after it, and code that
// touches JSC objects holds the JSC API lock as well. The exceptions are atomic or locked: `destroying`,
// `termination_requests` and `host_runtime` on ColloVm, a ColloValue's reference count and its owner state, and
// ColloDeferredWorkWakeupGate, which the wasm worklist thread writes.
//
// A ColloValue roots its JSValue with a JSC::Strong for as long as Zig holds a reference to it. Destroying the VM
// clears the payload of every outstanding handle, so a handle released afterwards frees only its own memory. Every
// other JSC::Strong here sits on a native object, never inside a cell: VM-lifetime roots on ColloVm, cleared by
// destroyVmContents in vm.cpp, and per-request roots on ColloRequestScopedRoots holders, cleared when their request
// ends.

#pragma once

#include "collo/abi.h"

#include "config.h"
#include "host_functions/webapi/files/blob_backing_store.h"
#include "runtime/Completion.h"
#include <JavaScriptCore/ArrayConventions.h>
#include <JavaScriptCore/CallData.h>
#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/GlobalObjectMethodTable.h>
#include <JavaScriptCore/Identifier.h>
#include <JavaScriptCore/InitializeThreading.h>
#include <JavaScriptCore/JSArray.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSFunction.h>
#include <JavaScriptCore/JSGlobalObject.h>
#include <JavaScriptCore/JSLock.h>
#include <JavaScriptCore/JSObject.h>
#include <JavaScriptCore/JSPromise.h>
#include <JavaScriptCore/JSPromiseConstructor.h>
#include <JavaScriptCore/JSSourceCode.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <JavaScriptCore/PutPropertySlot.h>
#include <JavaScriptCore/SourceCode.h>
#include <JavaScriptCore/TopExceptionScope.h>
#include <JavaScriptCore/SourceOrigin.h>
#include <JavaScriptCore/SourceProvider.h>
#include <JavaScriptCore/Strong.h>
#include <JavaScriptCore/Structure.h>
#include <JavaScriptCore/VM.h>
#include <JavaScriptCore/Weak.h>
#include <JavaScriptCore/WeakInlines.h>
#include <wtf/FastMalloc.h>
#include <wtf/HashMap.h>
#include <wtf/Seconds.h>
#include <wtf/URL.h>
#include <wtf/Vector.h>
#include <wtf/text/AtomString.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringBuilder.h>

#include <atomic>
#include <limits>
#include <memory>
#include <new>
#include <optional>

// The full definition is needed here: the inline ColloVm constructor instantiates the
// std::unique_ptr<Collo::ConsoleClient> deleter in every translation unit that includes this header.
#include "jsc/runtime/console_client.h"

// Hooks added by WebKit patches 0001-compiler-thread-lifecycle (declared in wtf/AutomaticThread.h) and
// 0002-gc-max-heap-size-override (declared in runtime/Options.h). The weak declaration of the registry reset lets
// prepare_for_fork.cpp test for it before calling it.
namespace WTF {

WTF_EXPORT_PRIVATE void setColloAutomaticThreadTimeout(Seconds);
WTF_EXPORT_PRIVATE void clearColloAutomaticThreadTimeoutOverride();
WTF_EXPORT_PRIVATE void colloResetAutomaticThreadRegistry() __attribute__((weak));

} // namespace WTF

namespace JSC {

JS_EXPORT_PRIVATE void setColloGCMaxHeapSizeOverride(size_t);
JS_EXPORT_PRIVATE void clearColloGCMaxHeapSizeOverride();

} // namespace JSC

namespace Collo {

class GlobalObject;
// The JSC VM's clientData, installed once at VM creation and deleted by the JSC VM's destructor. GlobalObject::owner()
// reads the ColloVm back through it.
struct VmClientData final : public JSC::VM::ClientData {
    explicit VmClientData(ColloVm*);

    WTF::String overrideSourceURL(const JSC::StackFrame&, const WTF::String& originalSourceURL) const override;

    ColloVm* owner;
};

// Decodes borrowed UTF-8. A null pointer with a non-zero length, or invalid UTF-8, fails with
// COLLO_STATUS_INVALID_ARGUMENT; an empty input yields the empty string.
ColloStatus stringToWTFString(ColloString string, WTF::String& out);
// Copies `string` as UTF-8 into malloc'd storage the caller frees with collo_free_buffer. An empty string yields a
// null pointer and length 0. Fails with COLLO_STATUS_OUT_OF_MEMORY when the copy cannot be made.
ColloStatus copyWTFStringToColloString(const WTF::String&, ColloString* out_string);
// CPU time of the calling thread from CLOCK_THREAD_CPUTIME_ID. A failing clock aborts the process.
uint64_t threadCpuTimeNs();
void resumeFastMallocScavengerIfSuspended(ColloVm*);
void resumeFastMallocScavengerForSandbox(ColloVm*);

// On success `*out_value` holds one reference that the caller releases with releaseValueHandle. Fails with
// COLLO_STATUS_INVALID_ARGUMENT once the VM is being destroyed, COLLO_STATUS_ERROR when the owner state's reference
// count is saturated and COLLO_STATUS_OUT_OF_MEMORY when the handle cannot be allocated.
ColloStatus makeValueHandle(ColloVm* vm, JSC::JSValue value, ColloValue** out_value);
// Adds a reference to `value`, returned through `out_value`. Fails with COLLO_STATUS_INVALID_ARGUMENT after the VM
// is gone and COLLO_STATUS_ERROR when the count is saturated.
ColloStatus retainValueHandle(ColloValue* value, ColloValue** out_value);
// Drops one reference. The last one clears the root, taking the JSC API lock if the VM still exists, and frees the
// handle. Safe from any thread and after the VM is destroyed.
void releaseValueHandle(ColloValue* value);

// Both read the rooted value without checking ownership; call valueBelongsToVm first. Null reads as undefined, and a
// handle whose VM was destroyed reads as the empty JSValue.
JSC::JSValue toJSValue(const ColloValue* value);
JSC::JSValue borrowedThisValue(const ColloValue* value);

void clearOutException(ColloValue** out_exception);
// Stores a new handle to `exception` in `*out_exception`. A null `out_exception` drops the exception and returns
// COLLO_STATUS_OK; otherwise the status is makeValueHandle's.
ColloStatus setJsException(ColloVm* vm, JSC::JSValue exception, ColloValue** out_exception);
// Moves the pending exception of `scope` into `*out_exception` and clears it unless it is a termination, which stays
// pending so the VM keeps unwinding. Returns COLLO_STATUS_JS_EXCEPTION, the handle failure, or COLLO_STATUS_ERROR
// when nothing is pending.
ColloStatus caughtExceptionStatus(ColloVm* vm, JSC::TopExceptionScope& scope, ColloValue** out_exception);
// Stores a new Error carrying `message` in `*out_exception`. Returns COLLO_STATUS_ERROR when the VM is not ready and
// otherwise setJsException's status, which is COLLO_STATUS_OK when the handle was made, so a caller that fails the
// operation must map that to its own status.
ColloStatus setInternalError(ColloVm* vm, const WTF::String& message, ColloValue** out_exception);
// True while `value` is a live handle of `vm`: false for null, for another VM's handle and after `vm` is destroyed.
bool valueBelongsToVm(const ColloVm* vm, const ColloValue* value);

inline ColloStatus statusOr(ColloStatus status, ColloStatus ok_status)
{
    return status == COLLO_STATUS_OK ? ok_status : status;
}

// Settles a module promise by draining microtasks outside any turn; a turn in progress fails with
// COLLO_STATUS_INVALID_ARGUMENT. Fulfilled yields the result, rejected yields COLLO_STATUS_JS_EXCEPTION. A promise
// still pending after a full drain needs host event-loop work: with `settlement_specifier` set, a settlement callback
// that reports that specifier to the host runtime is registered (when one is attached) and the call returns
// COLLO_STATUS_PENDING; with it null, the call fails with COLLO_STATUS_UNSUPPORTED.
ColloStatus awaitModulePromiseSync(ColloVm* vm, JSC::JSPromise* promise, JSC::JSValue* out_value,
    const WTF::String* settlement_specifier, ColloValue** out_exception);
// Imports and evaluates `specifier`, a canonical module key, from the host side, caching the namespace on the VM.
// `settlement_specifier` is passed to awaitModulePromiseSync.
ColloStatus ensureModuleNamespace(ColloVm* vm, const WTF::String& specifier, JSC::JSValue* out_namespace,
    const WTF::String* settlement_specifier, ColloValue** out_exception);
// Maps an import specifier and its referrer to the registry key the loader fetches by, or a null string when the
// specifier is invalid or not allowed from that referrer. module_loader.cpp documents the key space.
WTF::String resolveRegisteredSpecifier(ColloVm& vm, const WTF::String& specifier, const WTF::String& referrer);
// The public spelling of a deploy-scoped module key: its /var/task path, or that path as a file: URL. Tenant code
// sees only these spellings, in import.meta, stack frames and loader errors, never the internal key. Both return a
// null string for a key that is not deploy-scoped. The mapping is described next to publicTaskRootPrefix in
// module_loader.cpp.
WTF::String publicModulePathForKey(const WTF::String& module_key);
WTF::String publicModuleURLForKey(const WTF::String& module_key);

// Formats an exception as "Name: message" plus its stack without running tenant code; values.cpp explains how.
// The result is copied as by copyWTFStringToColloString.
ColloStatus formatExceptionString(ColloVm* vm, JSC::JSValue exception_value, ColloString* out_string);
// Creates a pending promise in `global_object` and the deferred that settles it. On success the caller owns
// `*out_deferred` and frees it with collo_promise_deferred_release.
ColloStatus createPromiseDeferred(
    ColloVm* vm, JSC::JSGlobalObject* global_object, JSC::JSValue* out_promise, ColloPromiseDeferred** out_deferred);
// Resolves or rejects the deferred's promise with `value`. The deferred settles once: afterwards it holds no
// handles, and a second call fails with COLLO_STATUS_INVALID_ARGUMENT.
ColloStatus settlePromiseDeferred(
    ColloVm* vm, ColloPromiseDeferred* deferred, JSC::JSValue value, bool is_rejection, ColloValue** out_exception);

class GlobalObject final : public JSC::JSGlobalObject {
public:
    using Base = JSC::JSGlobalObject;
    static constexpr unsigned StructureFlags = Base::StructureFlags;

    static GlobalObject* create(JSC::VM& vm, JSC::Structure* structure, ColloVm* owner);
    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSValue prototype);

    DECLARE_INFO;
    static const JSC::GlobalObjectMethodTable s_globalObjectMethodTable;

    static JSC::RuntimeFlags javaScriptRuntimeFlags(const JSC::JSGlobalObject*);
    static JSC::JSPromise* moduleLoaderImportModule(JSC::JSGlobalObject*, JSC::JSModuleLoader*, JSC::JSString*,
        RefPtr<JSC::ScriptFetchParameters>, const JSC::SourceOrigin&, bool deferred);
    // `useImportMap` is ignored: it selects HTML import maps, which only a browser
    // embedder supplies, and every specifier here is answered from the registry
    // the build produced.
    static JSC::Identifier moduleLoaderResolve(JSC::JSGlobalObject*, JSC::JSModuleLoader*, JSC::JSValue, JSC::JSValue,
        RefPtr<JSC::ScriptFetcher>, bool useImportMap);
    static JSC::JSPromise* moduleLoaderFetch(JSC::JSGlobalObject*, JSC::JSModuleLoader*, JSC::JSValue,
        const WTF::String&, RefPtr<JSC::ScriptFetchParameters>, RefPtr<JSC::ScriptFetcher>);
    static JSC::JSObject* moduleLoaderCreateImportMetaProperties(
        JSC::JSGlobalObject*, JSC::JSModuleLoader*, JSC::JSValue, JSC::JSModuleRecord*, RefPtr<JSC::ScriptFetcher>);

    // Aborts if the VM's clientData is missing; VM creation installs it before the global exists.
    ColloVm& owner() const;
    // Web API installation stores what it created into ColloVm::webapi_cache through these. The getters generated
    // from webapi_cache.def abort on an entry that was never stored, so a host function may call one only on a VM
    // whose Web APIs were installed.
    void cacheURLApi(JSC::JSObject* url_constructor, JSC::JSObject* url_prototype, JSC::Structure* url_structure,
        JSC::JSObject* url_search_params_constructor, JSC::JSObject* url_search_params_prototype,
        JSC::Structure* url_search_params_structure, JSC::JSObject* url_search_params_iterator_prototype,
        JSC::Structure* url_search_params_iterator_structure);
    void cacheHeadersApi(JSC::JSObject* headers_constructor, JSC::JSObject* headers_prototype,
        JSC::Structure* headers_structure, JSC::JSObject* headers_iterator_prototype,
        JSC::Structure* headers_iterator_structure);
    void cacheRequestApi(
        JSC::JSObject* request_constructor, JSC::JSObject* request_prototype, JSC::Structure* request_structure);
    void cacheResponseApi(
        JSC::JSObject* response_constructor, JSC::JSObject* response_prototype, JSC::Structure* response_structure);
    void cacheReadableStreamApi(JSC::JSObject* readable_stream_constructor, JSC::JSObject* readable_stream_prototype,
        JSC::Structure* readable_stream_structure, JSC::JSObject* readable_stream_default_reader_constructor,
        JSC::JSObject* readable_stream_default_reader_prototype,
        JSC::Structure* readable_stream_default_reader_structure,
        JSC::JSObject* readable_stream_default_controller_constructor,
        JSC::JSObject* readable_stream_default_controller_prototype,
        JSC::Structure* readable_stream_default_controller_structure,
        JSC::JSObject* readable_stream_byob_reader_constructor, JSC::JSObject* readable_stream_byob_reader_prototype,
        JSC::Structure* readable_stream_byob_reader_structure, JSC::JSObject* readable_stream_byob_request_constructor,
        JSC::JSObject* readable_stream_byob_request_prototype, JSC::Structure* readable_stream_byob_request_structure,
        JSC::JSObject* readable_byte_stream_controller_constructor,
        JSC::JSObject* readable_byte_stream_controller_prototype,
        JSC::Structure* readable_byte_stream_controller_structure,
        JSC::JSObject* readable_stream_async_iterator_prototype,
        JSC::Structure* readable_stream_async_iterator_structure);
    void cacheWritableStreamApi(JSC::JSObject* writable_stream_constructor, JSC::JSObject* writable_stream_prototype,
        JSC::Structure* writable_stream_structure, JSC::JSObject* writable_stream_default_writer_constructor,
        JSC::JSObject* writable_stream_default_writer_prototype,
        JSC::Structure* writable_stream_default_writer_structure,
        JSC::JSObject* writable_stream_default_controller_constructor,
        JSC::JSObject* writable_stream_default_controller_prototype,
        JSC::Structure* writable_stream_default_controller_structure);
    void cacheTransformStreamApi(JSC::JSObject* transform_stream_constructor, JSC::JSObject* transform_stream_prototype,
        JSC::Structure* transform_stream_structure, JSC::JSObject* transform_stream_default_controller_constructor,
        JSC::JSObject* transform_stream_default_controller_prototype,
        JSC::Structure* transform_stream_default_controller_structure);
    void cacheDOMExceptionApi(JSC::JSObject* dom_exception_constructor, JSC::JSObject* dom_exception_prototype,
        JSC::Structure* dom_exception_structure);
    void cacheEventApi(JSC::JSObject* event_constructor, JSC::JSObject* event_prototype,
        JSC::Structure* event_structure, JSC::JSObject* custom_event_constructor, JSC::JSObject* custom_event_prototype,
        JSC::Structure* custom_event_structure, JSC::JSObject* message_event_constructor,
        JSC::JSObject* message_event_prototype, JSC::Structure* message_event_structure,
        JSC::JSObject* error_event_constructor, JSC::JSObject* error_event_prototype,
        JSC::Structure* error_event_structure, JSC::JSObject* close_event_constructor,
        JSC::JSObject* close_event_prototype, JSC::Structure* close_event_structure,
        JSC::JSObject* event_target_constructor, JSC::JSObject* event_target_prototype,
        JSC::Structure* event_target_structure);
    void cacheAbortApi(JSC::JSObject* abort_controller_constructor, JSC::JSObject* abort_controller_prototype,
        JSC::Structure* abort_controller_structure, JSC::JSObject* abort_signal_constructor,
        JSC::JSObject* abort_signal_prototype, JSC::Structure* abort_signal_structure);
    void cacheTextCodecApi(JSC::JSObject* text_encoder_constructor, JSC::JSObject* text_encoder_prototype,
        JSC::Structure* text_encoder_structure, JSC::JSObject* text_decoder_constructor,
        JSC::JSObject* text_decoder_prototype, JSC::Structure* text_decoder_structure,
        JSC::JSObject* text_encoder_stream_constructor, JSC::JSObject* text_encoder_stream_prototype,
        JSC::Structure* text_encoder_stream_structure, JSC::JSObject* text_decoder_stream_constructor,
        JSC::JSObject* text_decoder_stream_prototype, JSC::Structure* text_decoder_stream_structure);
    void cacheBlobApi(JSC::JSObject* blob_constructor, JSC::JSObject* blob_prototype, JSC::Structure* blob_structure);
    void cacheFileApi(JSC::JSObject* file_constructor, JSC::JSObject* file_prototype, JSC::Structure* file_structure);
    void cacheFormDataApi(JSC::JSObject* form_data_constructor, JSC::JSObject* form_data_prototype,
        JSC::Structure* form_data_structure, JSC::JSObject* form_data_iterator_prototype,
        JSC::Structure* form_data_iterator_structure);
    void cacheCryptoApi(JSC::JSObject* subtle_crypto_constructor, JSC::JSObject* subtle_crypto_prototype,
        JSC::Structure* subtle_crypto_structure, JSC::JSObject* crypto_key_constructor,
        JSC::JSObject* crypto_key_prototype, JSC::Structure* crypto_key_structure);

#define COLLO_WEBAPI_CACHE_GETTER(name, field, type) type* name() const;
#define COLLO_WEBAPI_CACHE_FIELD(field, type)
#include "webapi_cache.def"
#undef COLLO_WEBAPI_CACHE_GETTER
#undef COLLO_WEBAPI_CACHE_FIELD

private:
    GlobalObject(JSC::VM&, JSC::Structure*);
    void finishCreation(JSC::VM&);
};

} // namespace Collo

// VM-lifetime roots of the Web API constructors, prototypes and structures, plus identifiers the stream and codec
// implementations look up. It lives on ColloVm, never in a cell, and destroyVmContents clears it while the VM is
// still alive. webapi_cache.def lists the roots, and this header and webapi_cache.cpp each expand it twice: a GETTER
// row also declares the GlobalObject accessor above, which aborts while the root is empty, and a FIELD row declares
// only the root, which host code reads through ColloVm::webapi_cache and checks itself.
struct ColloWebApiCache {
#define COLLO_WEBAPI_CACHE_GETTER(name, field, type) JSC::Strong<type> field;
#define COLLO_WEBAPI_CACHE_FIELD(field, type) JSC::Strong<type> field;
#include "webapi_cache.def"
#undef COLLO_WEBAPI_CACHE_GETTER
#undef COLLO_WEBAPI_CACHE_FIELD

    JSC::Identifier readable_stream_identifier;
    JSC::Identifier readable_stream_owner_identifier;
    JSC::Identifier readable_stream_iterator_identifier;
    JSC::Identifier readable_stream_iterator_return_value_identifier;
    JSC::Identifier readable_stream_iterator_return_pending_identifier;
    JSC::Identifier readable_stream_controller_identifier;
    JSC::Identifier readable_stream_tee_state_identifier;
    JSC::Identifier readable_stream_tee_original_identifier;
    JSC::Identifier readable_stream_tee_branch_a_identifier;
    JSC::Identifier readable_stream_tee_branch_b_identifier;
    JSC::Identifier readable_stream_tee_reading_identifier;
    JSC::Identifier readable_stream_tee_fulfilled_identifier;
    JSC::Identifier readable_stream_tee_rejected_identifier;
    JSC::Identifier readable_stream_tee_branch_a_canceled_identifier;
    JSC::Identifier readable_stream_tee_branch_b_canceled_identifier;
    JSC::Identifier readable_stream_tee_branch_a_reason_identifier;
    JSC::Identifier readable_stream_tee_branch_b_reason_identifier;
    JSC::Identifier readable_stream_from_state_identifier;
    JSC::Identifier readable_stream_from_iterator_identifier;
    JSC::Identifier readable_stream_from_next_identifier;
    JSC::Identifier readable_stream_from_is_async_identifier;
    JSC::Identifier readable_stream_from_done_identifier;
    JSC::Identifier readable_stream_from_next_fulfilled_identifier;
    JSC::Identifier readable_stream_from_next_rejected_identifier;
    JSC::Identifier readable_stream_from_value_fulfilled_identifier;
    JSC::Identifier readable_stream_from_value_rejected_identifier;
    JSC::Identifier readable_stream_from_return_fulfilled_identifier;
    JSC::Identifier readable_stream_from_return_rejected_identifier;
    JSC::Identifier writable_stream_identifier;
    JSC::Identifier writable_stream_controller_identifier;
    JSC::Identifier transform_stream_identifier;
    JSC::Identifier pipe_to_state_identifier;
    JSC::Identifier compression_stream_state_identifier;
    JSC::Identifier text_encoder_stream_state_identifier;
    JSC::Identifier text_decoder_stream_state_identifier;
    JSC::Identifier byte_length_identifier;

    void clear();
};

struct ColloValueOwnerState;

struct ColloModuleSourceEntry {
    WTF::RefPtr<JSC::SourceProvider> provider;
    ColloModuleLifetime lifetime { COLLO_MODULE_LIFETIME_EVICTABLE };
    ColloModuleType module_type { COLLO_MODULE_TYPE_ESM };
    bool has_bytecode { false };
};

struct ColloModuleSourceRecord {
    WTF::String specifier;
    ColloModuleSourceEntry entry;
};

struct ColloBlobObjectURLEntry {
    JSC::Strong<JSC::Unknown> value;
    WTF::Vector<Collo::HostFunctions::BlobObjectURLBackingStore> backing_stores;
    // The request that called createObjectURL, as activeExecContext resolves it, so module evaluation records the
    // boot request id and the boot context's close revokes those entries. 0 means no exec context existed, as in
    // the zygote or after the boot context closed; such an entry lives until revokeObjectURL or VM teardown.
    uint64_t owner_request_id { 0 };

    ColloBlobObjectURLEntry() = default;

    ColloBlobObjectURLEntry(JSC::VM& vm, JSC::JSValue value,
        WTF::Vector<Collo::HostFunctions::BlobObjectURLBackingStore>&& backing_stores, uint64_t owner_request_id)
        : value(vm, value)
        , backing_stores(WTF::move(backing_stores))
        , owner_request_id(owner_request_id)
    {
    }
};

struct ColloBlobObjectURLBackingRef {
    size_t bytes { 0 };
    size_t ref_count { 0 };
};

// The worker's blob: URL table. createObjectURL throws QuotaExceededError past either bound. `bytes` counts each
// backing store once however many URLs share it, and `backing_store_refs` holds the share counts.
struct ColloBlobObjectURLRegistry {
    static constexpr size_t entries_max = 4096;
    static constexpr size_t bytes_max = 256ULL * 1024 * 1024;

    WTF::HashMap<WTF::String, ColloBlobObjectURLEntry> entries;
    WTF::HashMap<const void*, ColloBlobObjectURLBackingRef> backing_store_refs;
    size_t bytes { 0 };

    static size_t saturatingAdd(size_t left, size_t right)
    {
        if (right > std::numeric_limits<size_t>::max() - left)
            return std::numeric_limits<size_t>::max();
        return left + right;
    }

    size_t additionalBytesFor(const WTF::Vector<Collo::HostFunctions::BlobObjectURLBackingStore>& backing_stores) const
    {
        size_t additional_bytes = 0;
        for (auto& backing_store : backing_stores) {
            if (!backing_store.key)
                return std::numeric_limits<size_t>::max();
            if (backing_store_refs.contains(backing_store.key))
                continue;
            additional_bytes = saturatingAdd(additional_bytes, backing_store.bytes);
        }
        return additional_bytes;
    }

    bool canInsert(const WTF::Vector<Collo::HostFunctions::BlobObjectURLBackingStore>& backing_stores) const
    {
        if (entries.size() >= entries_max)
            return false;
        auto additional_bytes = additionalBytesFor(backing_stores);
        if (additional_bytes > bytes_max)
            return false;
        return bytes <= bytes_max - additional_bytes;
    }

    bool insert(JSC::VM& vm, WTF::String url, JSC::JSValue value,
        WTF::Vector<Collo::HostFunctions::BlobObjectURLBackingStore>&& backing_stores, uint64_t owner_request_id)
    {
        if (!canInsert(backing_stores))
            return false;
        auto add_result = entries.add(
            WTF::move(url), ColloBlobObjectURLEntry(vm, value, WTF::move(backing_stores), owner_request_id));
        if (!add_result.isNewEntry)
            return false;
        for (auto& backing_store : add_result.iterator->value.backing_stores) {
            auto backing_result
                = backing_store_refs.add(backing_store.key, ColloBlobObjectURLBackingRef { backing_store.bytes, 0 });
            if (backing_result.isNewEntry)
                bytes += backing_store.bytes;
            backing_result.iterator->value.ref_count++;
        }
        return true;
    }

    void releaseBackingStores(const ColloBlobObjectURLEntry& entry)
    {
        for (auto& backing_store : entry.backing_stores) {
            auto backing_iterator = backing_store_refs.find(backing_store.key);
            RELEASE_ASSERT(backing_iterator != backing_store_refs.end());
            RELEASE_ASSERT(backing_iterator->value.ref_count > 0);
            backing_iterator->value.ref_count--;
            if (backing_iterator->value.ref_count)
                continue;
            RELEASE_ASSERT(bytes >= backing_iterator->value.bytes);
            bytes -= backing_iterator->value.bytes;
            backing_store_refs.remove(backing_iterator);
        }
    }

    bool remove(const WTF::String& url)
    {
        auto iterator = entries.find(url);
        if (iterator == entries.end())
            return false;
        releaseBackingStores(iterator->value);
        entries.remove(iterator);
        return true;
    }

    // Request end drops only the entries that request created. A worker runs up to LIVE_SLOT_COUNT requests
    // at once (common/worker_state/page/live_slots.zig), so clearing every entry would revoke URLs a still-running
    // request holds.
    void removeOwnedBy(uint64_t request_id)
    {
        if (!request_id)
            return;
        WTF::Vector<WTF::String> owned;
        for (auto& entry : entries) {
            if (entry.value.owner_request_id == request_id)
                owned.append(entry.key);
        }
        for (auto& url : owned)
            remove(url);
    }

    void clear()
    {
        entries.clear();
        backing_store_refs.clear();
        bytes = 0;
    }

    bool contains(const WTF::String& url) const { return entries.contains(url); }
};

// Base for a native object that owns GC roots on behalf of one request and is itself invisible to the collector.
//
// The case that needs it: the object holds a JSC::Strong on a JS graph, and that graph holds the only reference back
// to the object, as a promise reaction capturing a Ref does. Neither side can retire the cycle. The collector cannot,
// because the root keeps the graph alive, and the reference count cannot, because the graph keeps it above zero. If
// the JS never settles, the object and everything it roots live as long as the worker, and a leak checker reports
// nothing, because every allocation in the cycle is reachable.
//
// Request end is the one instant at which the runtime knows those roots are dead whatever the JS did, so every such
// object registers here and collo_webapi_cleanup_request clears it then.
struct ColloRequestScopedRootsRegistry;

class ColloRequestScopedRoots {
public:
    virtual ~ColloRequestScopedRoots();

    // Drops every GC root this object owns, leaving it inert. Runs at request cleanup, after the response is
    // finished, and at VM teardown, so it must be idempotent and must not call into JS. Implementations detach as
    // part of going inert.
    virtual void clearRequestScopedRoots() = 0;

    // Joins the VM's registry under `owner`. The registry holds a raw pointer, and this class rather than the
    // subclass keeps it valid: registration and detachment both live here, and the destructor detaches. Without that,
    // a subclass that forgot to detach would leave a dangling entry, and the next request end would make a virtual
    // call through it.
    void registerRequestScopedRoots(ColloRequestScopedRootsRegistry&, uint64_t owner);

    // Idempotent. Safe after the registry itself is gone, because clearing the registry detaches every entry it
    // releases.
    void detachRequestScopedRoots();

    // The request that created the object, as activeExecContext resolves it. Module evaluation resolves to the
    // worker's boot request id rather than 0, and closing the boot context reclaims that id. 0 means no exec context
    // existed at all, as on the zygote's VM or for turnless JS after the boot context closed, and nothing reclaims
    // such an object before VM teardown.
    uint64_t owner_request_id { 0 };

private:
    ColloRequestScopedRootsRegistry* m_roots_registry { nullptr };
};

struct ColloRequestScopedRootsRegistry {
    WTF::Vector<ColloRequestScopedRoots*> live;

    void add(ColloRequestScopedRoots* entry) { live.append(entry); }
    void remove(ColloRequestScopedRoots* entry) { live.removeFirst(entry); }

    // Snapshots before clearing: going inert detaches the entry and can release its last reference, and both mutate
    // `live`.
    void clearOwnedBy(uint64_t request_id)
    {
        if (!request_id)
            return;
        WTF::Vector<ColloRequestScopedRoots*> owned;
        for (auto* entry : live) {
            if (entry->owner_request_id == request_id)
                owned.append(entry);
        }
        for (auto* entry : owned)
            entry->clearRequestScopedRoots();
    }

    // Detaches before clearing, so an entry that outlives the registry, its last reference held by a JS cell not yet
    // swept, cannot reach back into this vector from its destructor.
    void clear()
    {
        auto owned = WTF::move(live);
        for (auto* entry : owned) {
            entry->detachRequestScopedRoots();
            entry->clearRequestScopedRoots();
        }
    }
};

inline ColloRequestScopedRoots::~ColloRequestScopedRoots() { detachRequestScopedRoots(); }

inline void ColloRequestScopedRoots::registerRequestScopedRoots(
    ColloRequestScopedRootsRegistry& registry, uint64_t owner)
{
    owner_request_id = owner;
    m_roots_registry = &registry;
    registry.add(this);
}

inline void ColloRequestScopedRoots::detachRequestScopedRoots()
{
    if (!m_roots_registry)
        return;
    m_roots_registry->remove(this);
    m_roots_registry = nullptr;
}

// The handle behind the ABI's ColloValue: a reference-counted root on one JSValue. `prev` and `next` link it into its
// owner state's list under the owner state's mutex, which is how VM destruction finds and empties every outstanding
// handle; ColloValueOwnerState is defined in vm.cpp.
struct ColloValue {
    ColloValueOwnerState* owner_state;
    JSC::Strong<JSC::Unknown> value;
    std::atomic<uint32_t> ref_count;
    ColloValue* prev;
    ColloValue* next;

    ColloValue(JSC::VM& vm, ColloValueOwnerState* value_owner, JSC::JSValue js_value)
        : owner_state(value_owner)
        , value(vm, js_value)
        , ref_count(1)
        , prev(nullptr)
        , next(nullptr)
    {
    }
};

// Tells the worker loop that JSC's DeferredWorkTimer has work, standing in for the RunLoop the worker never runs; the
// pump section of vm.cpp owns the protocol. One per VM, installed lazily on the VM thread and shared through a
// shared_ptr with the timer's notification, which runs on whichever thread schedules deferred work, such as the wasm
// worklist thread, and can outlive the worker runtime whose eventfd it writes. The notification stores `pending`
// before writing the eventfd, and collo_vm_deferred_work_scheduled consumes it once per loop tick. `wakeup_fd` is the
// registered eventfd, or -1 while none is, so a notification that fires after teardown unregistered it writes
// nothing instead of writing a recycled fd number.
struct ColloDeferredWorkWakeupGate {
    std::atomic<bool> pending { false };
    std::atomic<int> wakeup_fd { -1 };
};

struct ColloVm {
    WTF::RefPtr<JSC::VM> vm;
    Collo::GlobalObject* global_object;
    ColloWebApiCache webapi_cache;
    bool global_object_protected;
    // Whether VM creation installed the Web API object graph. Post-fork hooks that touch Web API objects, such as
    // refreshWebApiNavigator, must skip when it is false: without Web APIs the navigator slot holds an uninitialized
    // cell that crashes dynamicDowncast.
    bool web_apis_installed;
    // Set once the node:fs host object and its module aliases are installed, which happens only after the worker
    // child has entered its chroot and seccomp filter. Until then `fs` and `node:fs` do not resolve.
    bool node_fs_enabled;
    // Sorted by canonical specifier for binary search. JSC receives a fresh JSSourceCode wrapper on each fetch, but
    // the provider and its optional bytecode cache stay the one source of truth.
    WTF::Vector<ColloModuleSourceRecord> module_sources;
    // Evaluated namespaces live as long as the worker. JSC's own module registry still owns the fetched module
    // records, so evicting an entry here does not unload the module.
    WTF::HashMap<WTF::String, JSC::Strong<JSC::Unknown>> module_namespaces;
    // The deploy hash of the first deploy-scoped pack registered on this VM. A VM serves one deploy: registration
    // fails closed on a second hash, because this hash is what maps public /var/task specifiers back onto internal
    // keys. Null on the zygote's VM, whose warmup corpus is not deploy-scoped.
    WTF::String deploy_hash;
    // createObjectURL keeps the Blob alive until revokeObjectURL, the cleanup of the request that created the URL,
    // or VM teardown.
    ColloBlobObjectURLRegistry blob_object_urls;
    // Native holders of per-request GC roots the collector cannot reclaim; ColloRequestScopedRoots explains why.
    ColloRequestScopedRootsRegistry request_scoped_roots;
    ColloExecCtx* current_exec_ctx;
    // The owner of the outermost turn, as opposed to the owner currently installed. A microtask dispatcher swaps
    // current_exec_ctx for the duration of a continuation while this one stays put, so the two differ exactly while a
    // restored continuation runs.
    // FIXME: Nothing reads it. Whether enqueued work carries its owner is decided by the cross-task token
    // ColloRestoredTurnScope installs in vm.cpp.
    ColloExecCtx* turn_exec_ctx;
    // Microtask owner table, fed by the hooks of WebKit patch 0004-microtask-owner-context. A promise reaction one
    // request registers can run during another request's turn, as when both await a module-scope promise, so the
    // owner travels with the reaction. It travels as a token, never as a ColloExecCtx*: the promise outlives the
    // request that awaited it, so a pointer stored in the reaction would dangle. A token whose slot was released
    // resolves to no owner, the same fallback turnless JS takes.
    //
    // Token 0 records no owner, and the engine then runs the reaction under whoever drains it; the engine treats
    // tokens as opaque and only compares them.
    // `owner_token_turnless` is a real token so that a restore can set current_exec_ctx back to null: if turnless
    // were 0, the dispatcher could not tell a restore to nothing from no restore.
    static constexpr uint64_t owner_token_turnless = 1;
    static constexpr uint64_t owner_token_first = 2;
    struct OwnerSlot {
        uint64_t token; // 0 = free
        ColloExecCtx* exec_ctx;
    };
    // Sized well above the contexts that can hold a token at once: LIVE_SLOT_COUNT requests
    // (common/worker_state/page/live_slots.zig) plus the boot and host contexts the deferred-work pump enters. A full
    // table therefore means a missed release, and acquisition warns instead of degrading silently.
    static constexpr size_t owner_slot_count = 16;
    OwnerSlot owner_slots[owner_slot_count];
    // Never reused, so a token released and acquired again cannot collide and a stale reaction cannot resolve onto a
    // later request.
    uint64_t next_owner_token;
    // Told in pairs about every owner change inside a microtask drain: once when the restored owner takes over and
    // once when it gives the turn back. The deadline arbiter and the request timeline live outside this ABI and would
    // otherwise keep following the owner of the physical turn.
    ColloOwnerTransitionHook owner_transition_hook;
    void* owner_transition_ctx;
    // Microtasks that ran under a restored owner, meaning their registrant was not the request draining the queue.
    // One increment and no clock, so it costs nothing to keep, and it is the only evidence of how often the
    // per-crossing accounting on that path is paid.
    uint64_t owner_crossings;
    // The worker's identity for turnless JS, meaning module evaluation and its microtask drains. activeExecContext
    // serves it read-only when current_exec_ctx is null; it is never installed there or passed to collo_turn_enter,
    // so it never owns a turn or a CPU slice. Installed by the worker runtime through collo_vm_set_boot_exec_ctx. The
    // zygote never installs it, so evaluation on a bare VM finds no identity and fails closed.
    ColloExecCtx boot_exec_ctx;
    bool boot_exec_ctx_installed;
    // Nesting depth of collo_turn_enter. The outermost enter installs its context in current_exec_ctx, and a nested
    // enter must pass whatever context is installed there at that moment.
    uint32_t entered_count;
    bool ready;
    // Cross-thread termination requests may race with the start of destruction, but never with the lifetime of the
    // ColloVm object itself, which the caller of collo_vm_request_termination guarantees.
    std::atomic<bool> destroying;
    std::atomic<uint32_t> termination_requests;
    // Set and cleared by the Zig runtime on the VM thread. Host functions acquire-load the borrowed pointer and rely
    // on Zig to keep it alive while they run.
    std::atomic<void*> host_runtime;
    // Null until the first pump export runs, and touched only on the VM thread: the worklist thread reaches the gate
    // through the shared_ptr its notification captured, never through this member.
    std::shared_ptr<ColloDeferredWorkWakeupGate> deferred_work_wakeup_gate;
    // Set by collo_vm_set_console_sink. Null until a worker runtime registers its sink, so the zygote's console
    // keeps its observable behavior and emits nothing. Read on the VM thread only, while a console call frame is
    // live.
    ColloConsoleSink console_sink;
    void* console_sink_ctx;
    size_t console_line_bytes_max;
    // Per-request console output budgets, CONSOLE_REQUEST_LINES_MAX and CONSOLE_REQUEST_BYTES_MAX in
    // common/limits/runtime_logs.zig. Past either, the ConsoleClient stops formatting for that request and reports
    // each suppressed call as a drop marker.
    size_t console_request_lines_max;
    size_t console_request_bytes_max;
    // Created with the VM and attached to the global only while a sink is registered. The global holds only a
    // WeakPtr, so destruction order does not matter.
    std::unique_ptr<Collo::ConsoleClient> console_client;
    ColloValueOwnerState* value_owner;
    // Held from the outermost collo_turn_enter until collo_turn_exit_ex drains, so microtasks run once per turn.
    std::optional<JSC::VM::DrainMicrotaskDelayScope> microtask_delay_scope;
    // The pid of the process that owns this VM. collo_vm_post_fork_child compares it with getpid() to tell a forked
    // worker from a caller that runs the hook without forking.
    uint64_t process_id_at_creation;
    bool fastmalloc_scavenger_suspended_for_fork;

    ColloVm()
        : global_object(nullptr)
        , global_object_protected(false)
        , web_apis_installed(false)
        , node_fs_enabled(false)
        , current_exec_ctx(nullptr)
        , turn_exec_ctx(nullptr)
        , owner_slots {}
        , next_owner_token(owner_token_first)
        , owner_transition_hook(nullptr)
        , owner_transition_ctx(nullptr)
        , owner_crossings(0)
        , boot_exec_ctx()
        , boot_exec_ctx_installed(false)
        , entered_count(0)
        , ready(false)
        , destroying(false)
        , termination_requests(0)
        , host_runtime(nullptr)
        , console_sink(nullptr)
        , console_sink_ctx(nullptr)
        , console_line_bytes_max(0)
        , console_request_lines_max(0)
        , console_request_bytes_max(0)
        , value_owner(nullptr)
        , process_id_at_creation(0)
        , fastmalloc_scavenger_suspended_for_fork(false)
    {
    }

    ~ColloVm();

    bool isReady() const { return !destroying.load(std::memory_order_acquire) && ready && vm && global_object; }
};

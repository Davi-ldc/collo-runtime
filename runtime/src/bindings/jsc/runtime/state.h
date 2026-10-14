// Private state of the JavaScriptCore bridge: ColloVm and its realms, the value handles the ABI lends to Zig, the Collo
// global object and the registries host functions keep per realm or per VM. None of it is ABI; the exported surface is
// bindings/include/collo/abi.h and its Zig facade, bindings/root.zig.
//
// Everything here belongs to one VM thread, the zygote's before a fork and the worker's after it, and code that
// touches JSC objects holds the JSC API lock as well. The exceptions are atomic or locked: `destroying`,
// `termination_requests` and `host_runtime` on ColloVm, a ColloValue's reference count and its owner state, and
// ColloDeferredWorkWakeupGate, which the wasm worklist thread writes.
//
// The bridge reads no clock for its owners: which ColloExecCtx owns the running JavaScript is decided here
// (ownerExecCtx), and whatever an embedder measures per owner it measures at the turn boundaries and the owner
// transition hook.
//
// A ColloValue roots its JSValue with a JSC::Strong for as long as Zig holds a reference to it. Destroying the VM
// clears the payload of every outstanding handle, so a handle released afterwards frees only its own memory. Every
// other JSC::Strong here is a VM-lifetime root on ColloVm or one of its realms, never inside a cell, and
// destroyVmContents in vm.cpp clears it. A cell keeps its edges in WriteBarrier fields and its lists of edges in
// Collo::CellEdgeList (jsc/runtime/cell_edges.h), and holds a promise it will settle as a WriteBarrier<JSPromise>
// settled through settlePromise; ColloPromiseDeferred is for promises Zig holds.

#pragma once

#include "collo/abi.h"

#include "config.h"
#include "runtime/Completion.h"
#include <JavaScriptCore/ArrayConventions.h>
#include <JavaScriptCore/CallData.h>
#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/GlobalObjectMethodTable.h>
#include <JavaScriptCore/Identifier.h>
#include <JavaScriptCore/InitializeThreading.h>
#include <JavaScriptCore/IsoSubspace.h>
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
#include <JavaScriptCore/SourceOrigin.h>
#include <JavaScriptCore/SourceProvider.h>
#include <JavaScriptCore/Strong.h>
#include <JavaScriptCore/Structure.h>
#include <JavaScriptCore/TopExceptionScope.h>
#include <JavaScriptCore/VM.h>
#include <JavaScriptCore/Weak.h>
#include <JavaScriptCore/WeakInlines.h>
#include <wtf/FastMalloc.h>
#include <wtf/HashMap.h>
#include <wtf/Seconds.h>
#include <wtf/SharedTask.h>
#include <wtf/ThreadSafeRefCounted.h>
#include <wtf/URL.h>
#include <wtf/Vector.h>
#include <wtf/text/AtomString.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringBuilder.h>

#include <array>
#include <atomic>
#include <cstddef>
#include <limits>
#include <memory>
#include <new>
#include <optional>
#include <span>

// The full definition is needed here: the inline ColloVm constructor instantiates the
// std::unique_ptr<Collo::ConsoleClient> deleter in every translation unit that includes this header.
#include "jsc/runtime/console_client.h"

// Hooks added by WebKit patches 0001-compiler-thread-lifecycle (declared in wtf/AutomaticThread.h) and
// 0002-embedder-memory-budget (declared in runtime/Options.h and wtf/AvailableMemory.h). The weak declaration of the
// registry reset lets prepare_for_fork.cpp test for it before calling it.
namespace WTF {

WTF_EXPORT_PRIVATE void setColloAutomaticThreadTimeout(Seconds);
WTF_EXPORT_PRIVATE void setColloAutomaticThreadCacheRelease(Seconds idleTime);
WTF_EXPORT_PRIVATE void clearColloAutomaticThreadOverrides();
WTF_EXPORT_PRIVATE void colloResetAutomaticThreadRegistry() __attribute__((weak));
WTF_EXPORT_PRIVATE void setColloMemoryStatusOverride(size_t limitBytes, int memoryCurrentFd);
WTF_EXPORT_PRIVATE void clearColloMemoryStatusOverride();

} // namespace WTF

namespace JSC {

JS_EXPORT_PRIVATE void setColloGCMaxHeapSizeOverride(size_t);
JS_EXPORT_PRIVATE void clearColloGCMaxHeapSizeOverride();

} // namespace JSC

struct ColloRealm;
struct ColloWebApiCache;

namespace Collo {

class GlobalObject;
// The JSC VM's clientData, installed once at VM creation. The VM deletes it after the heap has finalized and freed
// every cell, so the subspace below outlives every GlobalObject. GlobalObject adds a field to JSGlobalObject, so its
// cells are too large for JSC's own global object subspace and come from this one. Its cell type destroys through
// ~JSGlobalObject, so GlobalObject may add only trivially destructible fields.
struct VmClientData final : public JSC::VM::ClientData {
    explicit VmClientData(ColloVm*);

    // JSC declares it pure virtual. It rewrites nothing: a module's source provider already carries its key's file
    // URL (module_loader.cpp), which is what stack frames should show.
    WTF::String overrideSourceURL(const JSC::StackFrame&, const WTF::String& originalSourceURL) const override;

    ColloVm* owner;
    JSC::IsoSubspace global_object_space;
    JSC::GCClient::IsoSubspace global_object_allocator;
};

// Decodes borrowed UTF-8. A null pointer with a non-zero length, or invalid UTF-8, fails with
// COLLO_STATUS_INVALID_ARGUMENT; an empty input yields the empty string.
ColloStatus stringToWTFString(ColloString string, WTF::String& out);
// Copies `string` as UTF-8 into malloc'd storage the caller frees with collo_free_buffer. An empty string yields a
// null pointer and length 0. Fails with COLLO_STATUS_OUT_OF_MEMORY when the copy cannot be made.
ColloStatus copyWTFStringToColloString(const WTF::String&, ColloString* out_string);
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
// Stores a new Error of `realm` carrying `message` in `*out_exception`. Returns COLLO_STATUS_ERROR when the VM is not
// ready and otherwise setJsException's status, which is COLLO_STATUS_OK when the handle was made, so a caller that
// fails the operation must map that to its own status.
ColloStatus setInternalError(ColloRealm* realm, const WTF::String& message, ColloValue** out_exception);
// True while `value` is a live handle of `vm`: false for null, for another VM's handle and after `vm` is destroyed.
bool valueBelongsToVm(const ColloVm* vm, const ColloValue* value);
// The global an operation on `value` runs in: an object's own Collo global, or `realm`'s for a primitive and for an
// object that belongs to no Collo realm. `realm` is the caller's, so an error raised for such a value belongs to the
// realm that asked, never to another route's.
GlobalObject* globalObjectForValue(ColloRealm& realm, JSC::JSValue value);
// Seeds the realm's Math.random from ColloVm::worker_weak_random_seed: the main realm takes the seed as it is, any
// other a mix of the seed and the realm's index. Does nothing on a VM that was never reseeded.
void seedRealmWeakRandom(ColloRealm& realm);

inline ColloStatus statusOr(ColloStatus status, ColloStatus ok_status)
{
    return status == COLLO_STATUS_OK ? ok_status : status;
}

// Settles a module promise of `realm` by draining microtasks outside any turn; a turn in progress fails with
// COLLO_STATUS_INVALID_ARGUMENT. Fulfilled yields the result, rejected yields COLLO_STATUS_JS_EXCEPTION. A promise
// still pending after a full drain needs host event-loop work: with `settlement_specifier` set, a settlement callback
// that reports the realm's index and that specifier to the host runtime is registered (when one is attached) and the
// call returns COLLO_STATUS_PENDING; with it null, the call fails with COLLO_STATUS_UNSUPPORTED.
ColloStatus awaitModulePromiseSync(ColloRealm* realm, JSC::JSPromise* promise, JSC::JSValue* out_value,
    const WTF::String* settlement_specifier, ColloValue** out_exception);
// Imports and evaluates `specifier`, a canonical module key, from the host side in `realm`'s module registry, caching
// the namespace on the realm. `settlement_specifier` is passed to awaitModulePromiseSync.
ColloStatus ensureModuleNamespace(ColloRealm* realm, const WTF::String& specifier, JSC::JSValue* out_namespace,
    const WTF::String* settlement_specifier, ColloValue** out_exception);
// Maps an import specifier and its referrer to the registry key the loader fetches by, or a null string when the
// specifier is invalid or not allowed from that referrer. module_loader.cpp documents the key space.
WTF::String resolveRegisteredSpecifier(ColloVm& vm, const WTF::String& specifier, const WTF::String& referrer);

// Formats an exception as "Name: message" plus its stack without running tenant code; values.cpp explains how.
// The result is copied as by copyWTFStringToColloString.
ColloStatus formatExceptionString(ColloVm* vm, JSC::JSValue exception_value, ColloString* out_string);
// Creates a pending promise in `global_object`, a Collo global of `vm`, and the deferred that settles it, which
// remembers that global's realm (collo_promise_deferred_realm). On success the caller owns `*out_deferred` and frees
// it with collo_promise_deferred_release.
ColloStatus createPromiseDeferred(
    ColloVm* vm, JSC::JSGlobalObject* global_object, JSC::JSValue* out_promise, ColloPromiseDeferred** out_deferred);
// Resolves or rejects the deferred's promise with `value` through settlePromise. The deferred settles once: afterwards
// it holds no handle, and a second call fails with COLLO_STATUS_INVALID_ARGUMENT. While an exception is pending, as a
// termination leaves it, it settles nothing, keeps the deferred unsettled and returns COLLO_STATUS_ERROR; a termination
// that arrives during the settlement is reported as caughtExceptionStatus reports it.
ColloStatus settlePromiseDeferred(
    ColloVm* vm, ColloPromiseDeferred* deferred, JSC::JSValue value, bool is_rejection, ColloValue** out_exception);
// A pending promise of `global_object`'s realm. A cell that will settle it holds it in a WriteBarrier<JSPromise> field
// it visits.
JSC::JSPromise* newPromise(JSC::JSGlobalObject* global_object);
// The bridge's one way to settle a promise: resolves `promise`, which must not be null, with `value`, or rejects it
// when `is_rejection`, in the promise's own realm. A promise already settled, or already resolved with a thenable,
// stays as it is. Returns false, having run nothing, while an exception is pending on the VM, such as the termination
// an earlier call left, and false when a termination arrives during the call; either way the caller returns without
// entering JavaScript again. Resolving with an object reads its `then` at once, which runs script, so the caller
// re-reads every member it uses afterwards.
bool settlePromise(JSC::JSPromise* promise, JSC::JSValue value, bool is_rejection);

class GlobalObject final : public JSC::JSGlobalObject {
public:
    using Base = JSC::JSGlobalObject;
    static constexpr unsigned StructureFlags = Base::StructureFlags;

    static GlobalObject* create(JSC::VM& vm, JSC::Structure* structure, ColloRealm* realm);
    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSValue prototype);

    template <typename, JSC::SubspaceAccess> static JSC::GCClient::IsoSubspace* subspaceFor(JSC::VM& vm)
    {
        return &static_cast<VmClientData*>(vm.clientData)->global_object_allocator;
    }

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
    // The realm this global is the global object of, which outlives it: the VM owns its realms until destruction.
    ColloRealm& realm() const { return *m_realm; }
    // This realm's Web API roots. Every object a host function builds from them belongs to this global's realm.
    ColloWebApiCache& webApiCache() const;
    // Web API installation stores what it created into the realm's cache through these. The getters generated
    // from webapi_cache.def abort on an entry that was never stored, so a host function may call one only on a realm
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
    GlobalObject(JSC::VM&, JSC::Structure*, ColloRealm*);
    void finishCreation(JSC::VM&);

    ColloRealm* m_realm;
};

} // namespace Collo

// The roots of one realm's Web API structures, prototypes and constructors, and the functions the stream classes
// register as promise reactions. It lives on the realm, never in a cell, and destroyVmContents clears it while the VM
// is still alive. webapi_cache.def lists the roots, and this header and webapi_cache.cpp each expand it twice: a
// GETTER row also declares the GlobalObject accessor above, which aborts while the root is empty, and a FIELD row
// declares only the root, which host code reads through GlobalObject::webApiCache and checks itself.
struct ColloWebApiCache {
#define COLLO_WEBAPI_CACHE_GETTER(name, field, type) JSC::Strong<type> field;
#define COLLO_WEBAPI_CACHE_FIELD(field, type) JSC::Strong<type> field;
#include "webapi_cache.def"
#undef COLLO_WEBAPI_CACHE_GETTER
#undef COLLO_WEBAPI_CACHE_FIELD

    // Two functions per reaction kind, fulfillment then rejection, in the order of StreamReaction in
    // host_functions/webapi/streams/stream_common_private.h, whose static_assert keeps the count in step. Installation
    // creates them in every realm before any stream exists, the main realm's in the zygote; each finds its cell through
    // the reaction's context, so one set serves every stream of the realm.
    static constexpr size_t stream_function_count = 44;
    std::array<JSC::Strong<JSC::JSFunction>, stream_function_count> stream_functions;

    void clear();
};

struct ColloValueOwnerState;

// The module pack a VM registered (collo_module_register_pack): the read-only mapping of its sealed memfd that Zig
// handed over, in the format common/ipc/module_pack.zig owns. The VM's ColloModuleSources and every external string a
// module source is wrapped in hold a reference, so the mapping ends with the last of them, through
// collo_runtime_mapping_release, on whichever thread drops it. Registration checks the header and that the records
// and the index lie inside the mapping; everything they point at is checked at each read, in module_loader.cpp.
class ColloModulePack final : public WTF::ThreadSafeRefCounted<ColloModulePack> {
public:
    // Takes over `mapping` on success. Null when the allocation fails, which leaves `mapping` with the caller. The
    // storage comes from tryFastMalloc, which the fastFree of the base's operator delete releases.
    static WTF::RefPtr<ColloModulePack> tryCreate(ColloMapping mapping, uint32_t module_count, uint32_t index_capacity);
    ~ColloModulePack();

    // The record index of the module whose specifier is `key`, as UTF-8 bytes, if the pack holds it; always below the
    // pack's module count.
    std::optional<uint32_t> find(std::span<const std::byte> key) const;
    // The source of record `index`, one find() returned, wrapped in place as an external string that holds a
    // reference on this pack; a null string when the record's source lies outside the mapping, when a UTF-16 source
    // has an odd offset or length, or when the record carries a flag the format does not define.
    WTF::String source(uint32_t index);

private:
    ColloModulePack(ColloMapping, uint32_t module_count, uint32_t index_capacity);

    std::span<const std::byte> bytes() const;

    ColloMapping m_mapping;
    uint32_t m_module_count;
    uint32_t m_index_capacity;
};

// The VM's module sources: the one pack it holds and the source provider of each module fetched from it, by record
// index, null until that module's first fetch. `providers` has exactly the pack's module count while a pack is held
// and is empty otherwise. JSC's module records keep their own references to providers, so dropping these leaves
// evaluated modules working.
struct ColloModuleSources {
    WTF::RefPtr<ColloModulePack> pack;
    WTF::Vector<WTF::RefPtr<JSC::SourceProvider>> providers;

    void clear()
    {
        providers.clear();
        pack = nullptr;
    }
    bool isEmpty() const { return !pack && providers.isEmpty(); }
};

// One realm of a VM: a Collo global object, with its own globals, intrinsics and module registry, and the roots and
// tables that belong to that global alone. Every VM has its main realm, created with it; collo_realm_create adds
// others, each with every install the VM made so far. A realm lives as long as its VM, which owns it and clears its
// roots in destroyVmContents, and the global it holds stays protected from collection until then.
//
// Realms separate state, not trust: they share the VM's heap, collector, turns, microtask queue, module sources and
// console sink. A table or quota that script can fill belongs to its realm, here, so that one realm can neither
// exhaust nor change another's.
struct ColloRealm {
    ColloVm* vm { nullptr };
    Collo::GlobalObject* global_object { nullptr };
    bool global_object_protected { false };
    // Its position in ColloVm::realms, 0 for the main realm.
    uint32_t index { 0 };
    ColloWebApiCache webapi_cache;
    // Namespaces the host evaluated in this realm, by canonical specifier, until collo_module_unregister_pack clears
    // them. The realm's own JSC module registry still owns the module records, so clearing them unloads nothing.
    WTF::HashMap<WTF::String, JSC::Strong<JSC::Unknown>> module_namespaces;
    // Set once `process` and the node:fs host object are installed on this realm's global (ColloVm::process_installed
    // and ColloVm::node_fs_enabled say whether every realm should have them).
    bool process_installed { false };
    bool node_fs_installed { false };
    // This realm's console labels and groups; the VM's one console client keeps them here.
    Collo::ConsoleRealmState console;
};

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
// pump section of vm.cpp owns the protocol. It is itself the timer-set notification: run() fires on whichever thread
// schedules deferred work, such as the wasm worklist thread, stores `pending`, then writes `wakeup_fd`, and
// collo_vm_deferred_work_scheduled consumes `pending` once per loop tick. One per VM, created with the VM, in the
// zygote before any fork, so a worker never allocates it after its seccomp filter; the VM and the timer each hold a
// reference, and the timer's can outlive the worker runtime whose eventfd it writes. `wakeup_fd` is the registered
// eventfd, or -1 while none is, so a notification that fires after teardown unregistered it writes nothing instead of
// writing a recycled fd number.
class ColloDeferredWorkWakeupGate final : public WTF::SharedTask<void()> {
public:
    // Null when the allocation fails. The storage comes from tryFastMalloc, which the fastFree of the base's
    // operator delete releases.
    static RefPtr<ColloDeferredWorkWakeupGate> tryCreate();

    void run() final;

    std::atomic<bool> pending { false };
    std::atomic<int> wakeup_fd { -1 };

private:
    ColloDeferredWorkWakeupGate() = default;
};

struct ColloVm {
    WTF::RefPtr<JSC::VM> vm;
    // Every realm of the VM in creation order, the main realm first. Realms are never removed before destruction, so
    // a pointer to one stays valid as long as the VM.
    WTF::Vector<std::unique_ptr<ColloRealm>> realms;
    ColloRealm* main_realm;
    // Whether VM creation installed the Web API object graph, on the main realm and so on every later one. Code that
    // touches Web API objects outside their host functions, such as a post-fork hook, must skip when it is false: the
    // realm's Web API cache is empty then.
    bool web_apis_installed;
    // Whether `process` belongs on every realm (collo_vm_install_process).
    bool process_installed;
    // Set once the node:fs host object and its module aliases are installed, which happens only after the worker
    // child has entered its chroot and seccomp filter. Until then `fs` and `node:fs` do not resolve, in any realm.
    bool node_fs_enabled;
    // The worker's own weak random seed (collo_vm_reseed_after_fork), from which every realm derives its Math.random
    // seed by its index, so neither sibling workers nor two realms of one worker share a sequence. Empty on a VM that
    // was never reseeded, such as the zygote's, whose realms keep the engine's seeds.
    std::optional<uint32_t> worker_weak_random_seed;
    // Every realm fetches its modules from these: JSC receives a fresh JSSourceCode wrapper on each fetch around the
    // module's one provider.
    ColloModuleSources module_sources;
    // The owner the outermost turn installed, or the one a restored continuation installed for its duration (null
    // while that continuation has no owner). ownerExecCtx below decides the owner from it.
    ColloExecCtx* current_exec_ctx;
    // The owner of JavaScript that runs outside every turn and every restored continuation: module evaluation and the
    // drains inside it (collo_vm_set_turnless_exec_ctx). Borrowed from the worker runtime; null when none is
    // installed, as always on the zygote's VM.
    ColloExecCtx* turnless_exec_ctx;
    // Restored continuations running now, nested ones included. While one runs, current_exec_ctx is the owner even
    // when it is null, so a continuation whose registrant was released never falls back to the turnless context.
    uint32_t restored_scope_depth;
    // Microtask owner table, fed by the hooks of WebKit patch 0004-microtask-owner-context. A promise reaction one
    // owner registers can run during another owner's turn, as when two requests await a module-scope promise, so the
    // owner travels with the reaction. It travels as a token, never as a ColloExecCtx*: the promise outlives the
    // owner that awaited it, so a pointer stored in the reaction would dangle. A token whose slot was released
    // resolves to no owner.
    //
    // Token 0 records no owner, and the engine then runs the reaction under whoever drains it; the engine treats
    // tokens as opaque and only compares them. `owner_token_none` is a real token so that a restore can install no
    // owner: if it were 0, the dispatcher could not tell a restore to nothing from no restore. Every other token is
    // (serial << owner_token_index_bits) | slot index, so a token finds its slot without a search and a released slot
    // never answers for a token minted before its release.
    static constexpr uint64_t owner_token_none = 1;
    // Every owner that can hold a token at once, COLLO_OWNER_SLOT_COUNT in abi.h. A full table therefore means a
    // missed release, and acquisition warns instead of degrading silently.
    static constexpr size_t owner_slot_count = COLLO_OWNER_SLOT_COUNT;
    static constexpr unsigned owner_token_index_bits = 7;
    static_assert(owner_slot_count <= (size_t { 1 } << owner_token_index_bits));
    struct OwnerSlot {
        uint64_t token; // 0 = free
        ColloExecCtx* exec_ctx;
    };
    OwnerSlot owner_slots[owner_slot_count];
    // Never reused, so a token released and acquired again cannot collide and a stale reaction cannot resolve onto a
    // later owner. Starts at 1, so every slot token is above owner_token_none.
    uint64_t next_owner_serial;
    // The last owner whose token was looked up and that token, so the registration of a reaction, which asks for the
    // running owner's token each time, skips the table scan while the owner stays the same. Releasing that owner
    // clears it.
    ColloExecCtx* cached_owner_exec_ctx;
    uint64_t cached_owner_token;
    // Told in pairs about every owner change inside a microtask drain: once when the restored owner takes over and
    // once when it gives the turn back. The embedder's deadlines, request timeline and CPU windows live outside this
    // ABI and would otherwise keep following the owner of the physical turn.
    ColloOwnerTransitionHook owner_transition_hook;
    void* owner_transition_ctx;
    // Microtasks that ran under a restored owner, meaning their registrant was not the owner draining the queue.
    // One increment and no clock, so it costs nothing to keep, and it is the only evidence of how often the
    // per-crossing work on that path is paid.
    uint64_t owner_crossings;
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
    // Created with the VM and registered as its DeferredWorkTimer's notification, so never null while the VM is
    // ready. Read through this member only on the VM thread; the worklist thread reaches the gate through the
    // timer's own reference.
    RefPtr<ColloDeferredWorkWakeupGate> deferred_work_wakeup_gate;
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
        : main_realm(nullptr)
        , web_apis_installed(false)
        , process_installed(false)
        , node_fs_enabled(false)
        , current_exec_ctx(nullptr)
        , turnless_exec_ctx(nullptr)
        , restored_scope_depth(0)
        , owner_slots {}
        , next_owner_serial(1)
        , cached_owner_exec_ctx(nullptr)
        , cached_owner_token(0)
        , owner_transition_hook(nullptr)
        , owner_transition_ctx(nullptr)
        , owner_crossings(0)
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

    bool isReady() const { return !destroying.load(std::memory_order_acquire) && ready && vm && main_realm; }
};

// A realm is usable while its VM is ready.
inline bool realmIsReady(const ColloRealm* realm) { return realm && realm->vm && realm->vm->isReady(); }

namespace Collo {

// The owner of the JavaScript running now, which host calls, the console, the owner token hook and the owner
// transition hook all ask: the context a turn or a restored continuation installed, else, outside every turn and
// every restored continuation, the turnless context, else none. A restored continuation with no owner stays without
// one: falling back to the turnless context would hand a released request's leftovers to the evaluation that happens
// to be open. A turn whose context was released mid-turn has none either.
inline ColloExecCtx* ownerExecCtx(const ColloVm& vm)
{
    if (vm.current_exec_ctx)
        return vm.current_exec_ctx;
    if (vm.entered_count || vm.restored_scope_depth)
        return nullptr;
    return vm.turnless_exec_ctx;
}

} // namespace Collo

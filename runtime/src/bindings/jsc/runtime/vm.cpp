// ColloVm's life and its turns: VM creation with the engine options a worker needs, value handles, turns with
// per-request CPU accounting, the microtask owner table, and the pump that runs JSC's deferred work in place of a
// RunLoop. Runs on the VM thread, except where a comment names another thread.
//
// The JSC API lock comes before a value owner state's mutex, as destroyVmContents takes them; releaseValueHandle
// drops the mutex before it takes the API lock so it never inverts that order. destroyVmContents clears every
// JSC::Strong a ColloVm owns while the JSC VM is still alive.

#include "host_functions/internal.h"
#include "jsc/runtime/console_client.h"
#include "jsc/runtime/state.h"

#include <JavaScriptCore/CrossTaskToken.h>
#include <JavaScriptCore/DeferredWorkTimer.h>
#include <JavaScriptCore/JSPromise.h>
#include <JavaScriptCore/MicrotaskQueue.h>
#include <JavaScriptCore/MicrotaskQueueInlines.h>
#include <JavaScriptCore/Options.h>
#include <JavaScriptCore/SimpleTypedArrayController.h>

#include <wtf/FastMalloc.h>
#include <wtf/StdLibExtras.h>

#include <atomic>
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <new>
#include <span>
#include <thread>
#include <time.h>
#include <unistd.h>

namespace {
// Defined next to collo_turn_enter, beside the owner invariant they serve, and declared here because VM creation
// installs them.
uint64_t colloCurrentOwnerTokenHook(JSC::JSGlobalObject*);
RefPtr<JSC::MicrotaskDispatcher> colloOwnerDispatcherFactoryHook(JSC::VM&, JSC::JSGlobalObject*, uint64_t);
} // namespace

// Shared by a VM and every value handle it made, and reference counted by all of them: the VM holds the first
// reference and each handle one more, and whichever lets go last deletes it. `vm` turns null when destruction
// starts, which is how a handle learns its VM is gone. The mutex guards `vm` and the handle list.
struct ColloValueOwnerState {
    std::mutex mutex;
    std::atomic<uint32_t> ref_count { 1 };
    std::atomic<ColloVm*> vm;
    ColloValue* values_head { nullptr };

    explicit ColloValueOwnerState(ColloVm* owner)
        : vm(owner)
    {
    }
};

namespace {

constexpr uint32_t allowedVmOptionFlags = COLLO_VM_OPTION_DISABLE_WEBAPIS;

bool allowsAbiVersion(const ColloVmOptions* options)
{
    if (!options)
        return true;
    if (!options->abi_version)
        return false;
    return options->abi_version == COLLO_ABI_VERSION;
}

bool shouldInstallWebApis(const ColloVmOptions* options)
{
    if (!options)
        return true;
    return !(options->flags & COLLO_VM_OPTION_DISABLE_WEBAPIS);
}

ColloStatus initializeVm(ColloVm* vm, const ColloVmOptions* options)
{
    if (!vm)
        return COLLO_STATUS_INVALID_ARGUMENT;

    vm->value_owner = new (std::nothrow) ColloValueOwnerState(vm);
    if (!vm->value_owner)
        return COLLO_STATUS_OUT_OF_MEMORY;

    vm->vm = JSC::VM::tryCreate(JSC::HeapType::Large);
    if (!vm->vm)
        return COLLO_STATUS_OUT_OF_MEMORY;
    // SimpleTypedArrayController is fast-allocated and has no nothrow operator new. tryFastMalloc with NotNull
    // placement keeps the allocation checked, and the class's operator delete releases it with fastFree.
    void* typed_array_controller_memory = nullptr;
    if (!WTF::tryFastMalloc(sizeof(JSC::SimpleTypedArrayController)).getValue(typed_array_controller_memory))
        return COLLO_STATUS_OUT_OF_MEMORY;
    auto* typed_array_controller = new (NotNull, typed_array_controller_memory) JSC::SimpleTypedArrayController(false);
    vm->vm->m_typedArrayController = adoptRef(*typed_array_controller);

    if (vm->vm->clientData)
        return COLLO_STATUS_ERROR;

    vm->vm->clientData = new (std::nothrow) Collo::VmClientData(vm);
    if (!vm->vm->clientData)
        return COLLO_STATUS_OUT_OF_MEMORY;

    JSC::JSLockHolder locker(*vm->vm);
    vm->vm->forbidExecutionOnTermination();
    // JSC creates its termination exception lazily, when its Watchdog or a termination deadline is first set up, and
    // Collo uses neither, since the worker's sentinel replaces them. The sentinel's cross-thread
    // notifyNeedTermination cannot allocate, and the throw path's terminationException accessor asserts the object
    // exists, so it is created here, on the VM thread, before any trap can fire.
    vm->vm->ensureTerminationException();
    JSC::Structure* structure = Collo::GlobalObject::createStructure(*vm->vm, JSC::jsNull());
    vm->global_object = Collo::GlobalObject::create(*vm->vm, structure, vm);
    // allocateCell aborts on exhaustion, so this check only keeps the status contract explicit.
    if (!vm->global_object)
        return COLLO_STATUS_OUT_OF_MEMORY;

    vm->web_apis_installed = shouldInstallWebApis(options);
    if (vm->web_apis_installed)
        Collo::HostFunctions::install(vm->global_object, *vm->vm);
    // JSC's built-in console object is already on the global. The client that routes it to the ColloConsoleSink is
    // created now but attached to the global only while a sink is registered. Without a client every console method
    // returns before touching its arguments, so a VM with no sink, such as the zygote's, never coerces user values.
    vm->console_client = WTF::makeUnique<Collo::ConsoleClient>(vm);
    vm->vm->heap.protect(vm->global_object);
    vm->global_object_protected = true;
    // Process-global and idempotent: the engine keeps one pair of function pointers, and each call resolves its VM
    // from the global it is handed.
    JSC::colloSetOwnerHooks(colloCurrentOwnerTokenHook, colloOwnerDispatcherFactoryHook);
    vm->ready = true;
    return COLLO_STATUS_OK;
}

bool retainValueOwnerState(ColloValueOwnerState* state)
{
    uint32_t count = state->ref_count.load(std::memory_order_acquire);
    do {
        if (count == std::numeric_limits<uint32_t>::max())
            return false;
    } while (!state->ref_count.compare_exchange_weak(
        count, count + 1, std::memory_order_acq_rel, std::memory_order_acquire));
    return true;
}

void releaseValueOwnerState(ColloValueOwnerState* state)
{
    uint32_t previous = state->ref_count.fetch_sub(1, std::memory_order_acq_rel);
    RELEASE_ASSERT(previous);
    if (previous != 1)
        return;
    std::atomic_thread_fence(std::memory_order_acquire);
    delete state;
}

void linkValueHandleLocked(ColloValueOwnerState* state, ColloValue* value)
{
    value->prev = nullptr;
    value->next = state->values_head;
    if (state->values_head)
        state->values_head->prev = value;
    state->values_head = value;
}

void unlinkValueHandleLocked(ColloValueOwnerState* state, ColloValue* value)
{
    if (value->prev)
        value->prev->next = value->next;
    else if (state->values_head == value)
        state->values_head = value->next;

    if (value->next)
        value->next->prev = value->prev;

    value->prev = nullptr;
    value->next = nullptr;
}

void clearValuePayload(ColloValue* value)
{
    JSC::Strong<JSC::Unknown> cleared;
    value->value.swap(cleared);
}

void detachValueHandleLocked(ColloValue* value)
{
    value->prev = nullptr;
    value->next = nullptr;
}

void invalidateOutstandingValuesLocked(ColloVm* vm)
{
    ColloValueOwnerState* state = vm->value_owner;
    if (!state)
        return;

    state->vm.store(nullptr, std::memory_order_release);
    ColloValue* value = state->values_head;
    state->values_head = nullptr;
    while (value) {
        ColloValue* next = value->next;
        detachValueHandleLocked(value);
        clearValuePayload(value);
        value = next;
    }
}

void destroyVmContents(ColloVm* vm)
{
    if (!vm)
        return;

    ColloValueOwnerState* value_owner = vm->value_owner;
    auto owned_vm = vm->vm;
    if (owned_vm) {
        JSC::JSLockHolder locker(*owned_vm);
        std::unique_lock<std::mutex> values_lock;
        if (value_owner)
            values_lock = std::unique_lock<std::mutex>(value_owner->mutex);

        vm->microtask_delay_scope.reset();
        vm->webapi_cache.clear();
        if (vm->global_object && vm->global_object_protected) {
            bool protect_count_is_zero = owned_vm->heap.unprotect(vm->global_object);
            if (protect_count_is_zero)
                owned_vm->heap.reportAbandonedObjectGraph();
            vm->global_object_protected = false;
        }
        vm->blob_object_urls.clear();
        // Includes the holders with owner 0, which no request end claims. Their roots must go while the VM is still
        // alive: a JSC::Strong left for a later destructor would touch a HandleSet that is already gone.
        vm->request_scoped_roots.clear();
        vm->module_namespaces.clear();
        vm->module_sources.clear();
        invalidateOutstandingValuesLocked(vm);
        vm->global_object = nullptr;
        vm->vm = nullptr;
        // JSC expects the last reference to the VM to drop while the API lock is still held.
        owned_vm = nullptr;
    } else if (value_owner) {
        std::lock_guard<std::mutex> lock(value_owner->mutex);
        value_owner->vm.store(nullptr, std::memory_order_release);
    }

    RELEASE_ASSERT(vm->module_sources.isEmpty());
    vm->current_exec_ctx = nullptr;
    vm->entered_count = 0;
    vm->host_runtime.store(nullptr, std::memory_order_release);
    vm->ready = false;
    vm->global_object_protected = false;
    vm->value_owner = nullptr;
    if (value_owner)
        releaseValueOwnerState(value_owner);
}

void waitForTerminationRequestsToDrain(ColloVm* vm)
{
    while (vm->termination_requests.load(std::memory_order_acquire) != 0)
        std::this_thread::yield();
}

#ifndef NDEBUG
bool execCtxReservedFieldsAreZero(const ColloExecCtx* exec_ctx)
{
    for (uint8_t value : exec_ctx->_reserved) {
        if (value)
            return false;
    }
    return true;
}
#endif

} // namespace

ColloVm::~ColloVm()
{
    destroying.store(true, std::memory_order_release);
    waitForTerminationRequestsToDrain(this);
    Collo::resumeFastMallocScavengerIfSuspended(this);
    destroyVmContents(this);
}

namespace Collo {

ColloStatus stringToWTFString(ColloString string, WTF::String& out)
{
    if (!string.ptr && string.len)
        return COLLO_STATUS_INVALID_ARGUMENT;

    if (!string.len) {
        out = ""_s;
        return COLLO_STATUS_OK;
    }

    out = WTF::String::fromUTF8(std::span(string.ptr, string.len));
    if (out.isNull())
        return COLLO_STATUS_INVALID_ARGUMENT;

    return COLLO_STATUS_OK;
}

ColloStatus copyWTFStringToColloString(const WTF::String& string, ColloString* out_string)
{
    if (!out_string)
        return COLLO_STATUS_INVALID_ARGUMENT;

    out_string->ptr = nullptr;
    out_string->len = 0;

    ColloStatus status = COLLO_STATUS_OK;
    auto result = string.tryGetUTF8([&](std::span<const char8_t> utf8) -> bool {
        if (utf8.empty())
            return true;

        void* storage = std::malloc(utf8.size());
        if (!storage) {
            status = COLLO_STATUS_OUT_OF_MEMORY;
            return false;
        }

        std::memcpy(storage, utf8.data(), utf8.size());
        out_string->ptr = static_cast<const uint8_t*>(storage);
        out_string->len = utf8.size();
        return true;
    });
    if (!result || !result.value())
        return status != COLLO_STATUS_OK ? status : COLLO_STATUS_OUT_OF_MEMORY;
    return COLLO_STATUS_OK;
}

uint64_t threadCpuTimeNs()
{
    timespec ts {};
    int rc = clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts);
    RELEASE_ASSERT(!rc);
    return static_cast<uint64_t>(ts.tv_sec) * 1000000000ull + static_cast<uint64_t>(ts.tv_nsec);
}

ColloStatus makeValueHandle(ColloVm* vm, JSC::JSValue value, ColloValue** out_value)
{
    if (!out_value)
        return COLLO_STATUS_INVALID_ARGUMENT;

    *out_value = nullptr;
    if (!vm || !vm->value_owner)
        return COLLO_STATUS_INVALID_ARGUMENT;

    ColloValueOwnerState* state = vm->value_owner;
    if (!retainValueOwnerState(state))
        return COLLO_STATUS_ERROR;

    WTF::RefPtr<JSC::VM> owner_vm;
    {
        std::lock_guard<std::mutex> lock(state->mutex);
        if (state->vm.load(std::memory_order_acquire) != vm || !vm->vm) {
            releaseValueOwnerState(state);
            return COLLO_STATUS_INVALID_ARGUMENT;
        }
        owner_vm = vm->vm;
    }

    JSC::JSLockHolder locker(*owner_vm);
    auto* handle = new (std::nothrow) ColloValue(*owner_vm, state, value);
    if (!handle) {
        releaseValueOwnerState(state);
        return COLLO_STATUS_OUT_OF_MEMORY;
    }

    {
        std::lock_guard<std::mutex> lock(state->mutex);
        if (state->vm.load(std::memory_order_acquire) != vm || vm->vm.get() != owner_vm.get()) {
            clearValuePayload(handle);
            delete handle;
            releaseValueOwnerState(state);
            return COLLO_STATUS_INVALID_ARGUMENT;
        }
        linkValueHandleLocked(state, handle);
    }
    *out_value = handle;
    return COLLO_STATUS_OK;
}

ColloStatus retainValueHandle(ColloValue* value, ColloValue** out_value)
{
    if (!out_value)
        return COLLO_STATUS_INVALID_ARGUMENT;

    *out_value = nullptr;
    if (!value || !value->owner_state)
        return COLLO_STATUS_INVALID_ARGUMENT;

    if (!value->owner_state->vm.load(std::memory_order_acquire))
        return COLLO_STATUS_INVALID_ARGUMENT;

    uint32_t count = value->ref_count.load(std::memory_order_acquire);
    do {
        if (count == std::numeric_limits<uint32_t>::max())
            return COLLO_STATUS_ERROR;
    } while (!value->ref_count.compare_exchange_weak(
        count, count + 1, std::memory_order_acq_rel, std::memory_order_acquire));
    *out_value = value;
    return COLLO_STATUS_OK;
}

void releaseValueHandle(ColloValue* value)
{
    if (!value)
        return;

    uint32_t previous = value->ref_count.fetch_sub(1, std::memory_order_acq_rel);
    RELEASE_ASSERT(previous);
    if (previous != 1)
        return;

    std::atomic_thread_fence(std::memory_order_acquire);

    ColloValueOwnerState* state = value->owner_state;
    WTF::RefPtr<JSC::VM> owner_vm;
    if (state) {
        std::lock_guard<std::mutex> lock(state->mutex);
        ColloVm* owner = state->vm.load(std::memory_order_acquire);
        if (owner && owner->vm) {
            // The reference keeps the JSC VM alive after state->mutex drops, since destruction may run concurrently.
            // The mutex is not held while taking the JSC API lock, because destroyVmContents takes the two in the
            // opposite order while it invalidates live handles.
            owner_vm = owner->vm;
            unlinkValueHandleLocked(state, value);
        }
    }

    if (owner_vm) {
        JSC::JSLockHolder locker(*owner_vm);
        clearValuePayload(value);
    }

    delete value;
    if (state)
        releaseValueOwnerState(state);
}

bool valueBelongsToVm(const ColloVm* vm, const ColloValue* value)
{
    if (!vm || !value || !value->owner_state)
        return false;
    // Destruction nulls the owner state's VM under both locks before it clears any payload.
    return value->owner_state->vm.load(std::memory_order_acquire) == vm;
}

JSC::JSValue toJSValue(const ColloValue* value)
{
    if (!value)
        return JSC::jsUndefined();
    return value->value.get();
}

JSC::JSValue borrowedThisValue(const ColloValue* value) { return value ? value->value.get() : JSC::jsUndefined(); }

void clearOutException(ColloValue** out_exception)
{
    if (out_exception)
        *out_exception = nullptr;
}

ColloStatus setJsException(ColloVm* vm, JSC::JSValue exception, ColloValue** out_exception)
{
    if (!out_exception)
        return COLLO_STATUS_OK;
    *out_exception = nullptr;
    return makeValueHandle(vm, exception, out_exception);
}

ColloStatus caughtExceptionStatus(ColloVm* vm, JSC::TopExceptionScope& scope, ColloValue** out_exception)
{
    if (!scope.exception())
        return COLLO_STATUS_ERROR;
    JSC::JSValue exception = scope.exception()->value();
    scope.clearExceptionExceptTermination();
    return statusOr(setJsException(vm, exception, out_exception), COLLO_STATUS_JS_EXCEPTION);
}

ColloStatus setInternalError(ColloVm* vm, const WTF::String& message, ColloValue** out_exception)
{
    if (!vm || !vm->isReady())
        return COLLO_STATUS_ERROR;

    JSC::JSObject* error = JSC::createError(vm->global_object, message);
    return setJsException(vm, error, out_exception);
}

} // namespace Collo

extern "C" ColloStatus collo_vm_create(const ColloVmOptions* options, ColloVm** out_vm)
{
    if (!out_vm)
        return COLLO_STATUS_INVALID_ARGUMENT;

    *out_vm = nullptr;
    if (!allowsAbiVersion(options))
        return COLLO_STATUS_INVALID_ARGUMENT;
    if (options && (options->flags & ~allowedVmOptionFlags))
        return COLLO_STATUS_UNSUPPORTED;

    // Both run their bodies once per process, so the options below apply to every VM the process creates, unless
    // tooling_bytecode.cpp ran them first with its own options.
    WTF::initializeMainThread();
    JSC::initialize([] {
        JSC::Options::useSharedArrayBuffer() = true;
        // Every option below keeps the engine from creating a thread after seccomp denies clone, where
        // Thread::create fails and aborts the worker.
        //
        // One wasm compiler thread for the process. A worker starts every thread the wasm worklist could ever use
        // before seccomp, in collo_vm_prespawn_compiler_threads. With the upstream default of one thread per CPU
        // but one, a multi-threaded compile would notify threads that were never started and abort the worker; with
        // one thread the started set is the complete set.
        JSC::Options::numberOfWasmCompilerThreads() = 1;
        // The JIT worklist's compiler threads are born lazily by the first asynchronous enqueue, and no thread
        // survives the fork, so a hot function in a sandboxed worker would call Thread::create, then clone, and
        // abort. The worker starts them between dropping its privileges and seccomp, so the pool is sized here to
        // exactly what gets started: two threads, at most one per tier group below, so a long optimizing compile
        // cannot hold a baseline compile behind it. Compiling off the JS thread keeps a tier-up from stalling the
        // request being served.
        JSC::Options::maxNumberOfWorklistThreads() = 2;
        // The minimum must come down with the maximum: JITWorklist::wakeThreads compares the active count against
        // the minimum without clamping it to the threads that exist, so the upstream default, 3 on any machine with
        // three or more cores, makes it aim for a third thread that was never created.
        JSC::Options::minNumberOfWorklistThreads() = 2;
        JSC::Options::numberOfBaselineCompilerThreads() = 1;
        JSC::Options::numberOfDFGCompilerThreads() = 1;
        JSC::Options::numberOfFTLCompilerThreads() = 1;
        // GC marking helpers are a lazily started pool of one thread fewer than the markers. A worker limited to one
        // core gains nothing from them and would create the first at its first collection, after seccomp; one
        // marker means no pool. The collector thread itself is started in collo_vm_prespawn_compiler_threads.
        JSC::Options::numberOfGCMarkers() = 1;
        // Marked-block warm-up is a helper thread the block allocator starts on its own after some number of block
        // allocations, to touch pages ahead of the mutator. In a worker that start lands after seccomp, and in the
        // zygote the touched pages would be dirty in every worker's copy.
        JSC::Options::useWarmUpMarkedBlocks() = false;
        // Signal-based VM traps lazily create a global WorkQueue, a thread, in VMTraps::queue() on the first
        // fireTrap, so the sentinel's first termination of a sandboxed worker would abort it. Polling traps use the
        // check_traps safepoints LLInt and baseline already emit, need no thread, and still stop a hung loop at its
        // next back edge.
        JSC::Options::usePollingTraps() = true;
    });

    auto* vm = new (std::nothrow) ColloVm();
    if (!vm)
        return COLLO_STATUS_OUT_OF_MEMORY;
    vm->process_id_at_creation = static_cast<uint64_t>(getpid());

    ColloStatus status = initializeVm(vm, options);
    if (status != COLLO_STATUS_OK) {
        delete vm;
        return status;
    }

    *out_vm = vm;
    return COLLO_STATUS_OK;
}

extern "C" void collo_vm_destroy(ColloVm* vm)
{
    if (!vm)
        return;
    vm->destroying.store(true, std::memory_order_release);
    waitForTerminationRequestsToDrain(vm);
    RELEASE_ASSERT(!vm->entered_count);
    RELEASE_ASSERT(!vm->current_exec_ctx);

    delete vm;
}

extern "C" ColloStatus collo_vm_set_host_runtime(ColloVm* vm, void* runtime)
{
    if (!vm || !vm->isReady())
        return COLLO_STATUS_INVALID_ARGUMENT;

    vm->host_runtime.store(runtime, std::memory_order_release);
    return COLLO_STATUS_OK;
}

extern "C" ColloStatus collo_vm_set_boot_exec_ctx(ColloVm* vm, uint64_t request_id)
{
    if (!vm || !vm->isReady() || request_id == 0)
        return COLLO_STATUS_INVALID_ARGUMENT;

    vm->boot_exec_ctx = ColloExecCtx {};
    vm->boot_exec_ctx.request_id = request_id;
    vm->boot_exec_ctx_installed = true;
    return COLLO_STATUS_OK;
}

extern "C" ColloStatus collo_vm_clear_boot_exec_ctx(ColloVm* vm)
{
    if (!vm || !vm->isReady())
        return COLLO_STATUS_INVALID_ARGUMENT;

    // Idempotent, unlike installation: the worker runtime closes the boot context once on every settlement path,
    // including after a boot that installed none because the host delivered no boot egress capability.
    vm->boot_exec_ctx = ColloExecCtx {};
    vm->boot_exec_ctx_installed = false;
    return COLLO_STATUS_OK;
}

extern "C" ColloStatus collo_vm_set_console_sink(ColloVm* vm, ColloConsoleSink sink, void* sink_ctx,
    size_t line_bytes_max, size_t request_lines_max, size_t request_bytes_max)
{
    if (!vm || !vm->isReady())
        return COLLO_STATUS_INVALID_ARGUMENT;
    if (sink && (line_bytes_max == 0 || request_lines_max == 0 || request_bytes_max == 0))
        return COLLO_STATUS_INVALID_ARGUMENT;

    JSC::JSLockHolder locker(*vm->vm);
    vm->console_sink = sink;
    vm->console_sink_ctx = sink_ctx;
    vm->console_line_bytes_max = sink ? line_bytes_max : 0;
    vm->console_request_lines_max = sink ? request_lines_max : 0;
    vm->console_request_bytes_max = sink ? request_bytes_max : 0;
    // Every registration starts the budgets afresh, so counters spent under a previous sink cannot exhaust the new
    // one in advance.
    if (vm->console_client)
        vm->console_client->resetRequestOutputBudgets();
    // The client is attached only while a sink exists. JSC's console object returns on a null client before it
    // coerces labels or arguments, so a console with no sink never re-enters user code.
    if (sink)
        vm->global_object->setConsoleClient(WeakPtr<JSC::ConsoleClient> { *vm->console_client });
    else
        vm->global_object->setConsoleClient(WeakPtr<JSC::ConsoleClient> {});
    return COLLO_STATUS_OK;
}

extern "C" ColloStatus collo_vm_install_process(ColloVm* vm)
{
    if (!vm || !vm->isReady())
        return COLLO_STATUS_INVALID_ARGUMENT;

    JSC::JSLockHolder locker(*vm->vm);
    return Collo::HostFunctions::installProcess(vm->global_object, *vm->vm);
}

extern "C" ColloStatus collo_vm_enable_node_fs_for_worker(ColloVm* vm)
{
    if (!vm || !vm->isReady())
        return COLLO_STATUS_INVALID_ARGUMENT;

    JSC::JSLockHolder locker(*vm->vm);
    if (vm->node_fs_enabled)
        return COLLO_STATUS_OK;

    Collo::HostFunctions::installWorkerNodeBuiltins(vm->global_object, *vm->vm);
    vm->node_fs_enabled = true;
    return COLLO_STATUS_OK;
}

namespace {

// Resolves the ColloVm from the global a microtask runs on. Every Collo global carries its owner, so this needs no
// ambient state and stays correct when one thread hosts more than one VM. Null for a global that is not Collo's.
ColloVm* ownerVmFromGlobal(JSC::JSGlobalObject* global_object)
{
    auto* collo_global = dynamicDowncast<Collo::GlobalObject>(global_object);
    return collo_global ? &collo_global->owner() : nullptr;
}

uint64_t ownerTokenFor(ColloVm* vm, ColloExecCtx* exec_ctx)
{
    if (!exec_ctx)
        return ColloVm::owner_token_turnless;
    for (const auto& slot : vm->owner_slots) {
        if (slot.token && slot.exec_ctx == exec_ctx)
            return slot.token;
    }
    return 0;
}

// Idempotent: the same ColloExecCtx always maps to the same live token. Returns 0 when the table is full.
uint64_t acquireOwnerToken(ColloVm* vm, ColloExecCtx* exec_ctx)
{
    if (!exec_ctx)
        return ColloVm::owner_token_turnless;
    if (uint64_t existing = ownerTokenFor(vm, exec_ctx))
        return existing;
    for (auto& slot : vm->owner_slots) {
        if (!slot.token) {
            slot.token = vm->next_owner_token++;
            slot.exec_ctx = exec_ctx;
            return slot.token;
        }
    }
    return 0;
}

ColloExecCtx* execCtxForOwnerToken(ColloVm* vm, uint64_t token)
{
    if (token == ColloVm::owner_token_turnless)
        return nullptr;
    for (const auto& slot : vm->owner_slots) {
        if (slot.token && slot.token == token)
            return slot.exec_ctx;
    }
    // A released token: the owning request is gone. Resolving to no owner is deliberate, since charging its leftovers
    // to whoever happens to be running is what the owner table exists to prevent.
    return nullptr;
}

class ColloOwnerMicrotaskDispatcher;

// Installed on the VM only while a restored continuation runs. Its presence makes JSC take the slow enqueue path and
// ask who owns the work being queued. Carrying the owner on the reaction alone covers one hop: anything the
// continuation enqueues itself would otherwise land without an owner and run under the turn that settled it. Outside
// that window no token is installed, so the enqueue fast path is exactly the upstream one.
class ColloCrossTaskToken final : public JSC::CrossTaskToken {
public:
    // Checked rather than fatal, because exhaustion has a tolerable outcome: without the token the restored
    // continuation still runs under the right owner, and only the work it enqueues itself loses its owner, the same
    // degradation a full owner table causes.
    static RefPtr<ColloCrossTaskToken> tryCreate(uint64_t owner_token)
    {
        void* storage = nullptr;
        if (!WTF::tryFastMalloc(sizeof(ColloCrossTaskToken)).getValue(storage))
            return nullptr;
        auto* token = new (NotNull, storage) ColloCrossTaskToken(owner_token);
        return adoptRef(*token);
    }

    // Matches the tryFastMalloc above. The reference-counting base declares its own allocation operators, and the
    // virtual destructor makes the lookup land in the most derived scope, which is this one.
    static void operator delete(void* pointer) { WTF::fastFree(pointer); }

    RefPtr<JSC::MicrotaskDispatcher> createMicrotaskDispatcher(JSC::VM&, JSC::JSGlobalObject*) final;

private:
    explicit ColloCrossTaskToken(uint64_t owner_token)
        : m_owner_token(owner_token)
    {
        setShouldPropagateToMicroTask(true);
    }

    uint64_t m_owner_token;
};

// Closes `from`'s thread-CPU slice and opens `to`'s at the same instant, so the two never overlap or leave a gap. A
// null side has no slice on purpose: turnless execution and a released owner both resolve to no context, and
// inventing a slice for them would charge one request's CPU to another.
void moveCpuSlice(ColloExecCtx* from, ColloExecCtx* to)
{
    uint64_t now = Collo::threadCpuTimeNs();
    if (from && from->turn_cpu_start_ns) {
        RELEASE_ASSERT(now >= from->turn_cpu_start_ns);
        from->cpu_used_ns_total += now - from->turn_cpu_start_ns;
        from->turn_cpu_start_ns = 0;
    }
    if (to)
        to->turn_cpu_start_ns = now;
}

// Swaps the running owner for the one that registered the work, and puts back whatever was there. The previous owner
// is saved as the raw ColloExecCtx* rather than as a token, so a turn whose owner is not in the table still restores
// exactly; a released owner resolves to turnless, the fallback turnless JS takes.
struct ColloRestoredTurnScope {
    ColloRestoredTurnScope(ColloVm* vm, JSC::VM& jsc_vm, uint64_t owner_token)
        : m_vm(vm)
        , m_jsc_vm(jsc_vm)
        , m_previous_ctx(vm->current_exec_ctx)
        , m_previous_token(jsc_vm.crossTaskToken())
    {
        m_vm->owner_crossings += 1;
        m_restored_ctx = execCtxForOwnerToken(vm, owner_token);
        // The thread-CPU slice follows the owner. Otherwise the whole drain is charged to the turn that ran it, and
        // that number is more than telemetry: when a workload fault kills the worker, the live slot is charged from
        // it.
        m_previous_was_armed = m_previous_ctx && m_previous_ctx->turn_cpu_start_ns;
        moveCpuSlice(m_previous_ctx, m_restored_ctx);
        m_vm->current_exec_ctx = m_restored_ctx;
        if (m_vm->owner_transition_hook)
            m_vm->owner_transition_hook(m_vm->owner_transition_ctx, m_previous_ctx, m_restored_ctx);
        // Unconditional, even when the token is null: leaving the enclosing scope's token installed would hand this
        // continuation's descendants the enclosing owner, a wrong answer, while dropping it only gives an incomplete
        // one, as they fall back to the turn that drains them.
        RefPtr token = ColloCrossTaskToken::tryCreate(owner_token);
        if (!token) [[unlikely]] {
            static bool warned = false;
            if (!warned) {
                warned = true;
                std::fprintf(stderr,
                    "collo: cross-task token allocation failed; work enqueued by a restored continuation loses its owner\n");
            }
        }
        m_jsc_vm.setCrossTaskToken(WTF::move(token));
    }

    ~ColloRestoredTurnScope()
    {
        m_jsc_vm.setCrossTaskToken(WTF::move(m_previous_token));
        // Only a slice that was open is reopened. A turn that never opened one must not gain one here, or the
        // enclosing collo_turn_exit_ex would charge CPU from an instant it never chose.
        moveCpuSlice(m_restored_ctx, m_previous_was_armed ? m_previous_ctx : nullptr);
        m_vm->current_exec_ctx = m_previous_ctx;
        if (m_vm->owner_transition_hook)
            m_vm->owner_transition_hook(m_vm->owner_transition_ctx, m_restored_ctx, m_previous_ctx);
    }

    ColloVm* m_vm;
    JSC::VM& m_jsc_vm;
    ColloExecCtx* m_previous_ctx;
    ColloExecCtx* m_restored_ctx { nullptr };
    bool m_previous_was_armed { false };
    RefPtr<JSC::CrossTaskToken> m_previous_token;
};

// Type::None keeps this out of isWebCoreMicrotaskDispatcher(), an ordinal test over the enum that only WebCore
// consumes.
class ColloOwnerMicrotaskDispatcher final : public JSC::MicrotaskDispatcher {
public:
    // Checked, and fastMalloc rather than the base's TZone allocator: the TZone operator new crashes on exhaustion,
    // while failing here only means the continuation runs under the settling turn, which degrades attribution but
    // keeps the worker alive.
    static RefPtr<ColloOwnerMicrotaskDispatcher> tryCreate(uint64_t owner_token)
    {
        void* storage = nullptr;
        if (!WTF::tryFastMalloc(sizeof(ColloOwnerMicrotaskDispatcher)).getValue(storage))
            return nullptr;
        auto* dispatcher = new (NotNull, storage) ColloOwnerMicrotaskDispatcher(owner_token);
        return adoptRef(*dispatcher);
    }

    // Must match the tryFastMalloc above: the base declares a TZone operator
    // delete, and the virtual destructor makes the lookup land in this scope.
    static void operator delete(void* pointer) { WTF::fastFree(pointer); }

    JSC::QueuedTaskResult run(JSC::QueuedTask& task) final
    {
        auto* global_object = task.globalObject();
        JSC::VM& jsc_vm = global_object->vm();
        ColloVm* vm = ownerVmFromGlobal(global_object);
        // The body the engine's own dispatcher runs, so the debugger callbacks and the uncaught-exception report
        // still happen. The report falls inside the restored window, which attributes the throw to whoever
        // registered the work rather than to the turn that happened to settle the promise.
        if (!vm) {
            JSC::runMicrotaskWithDebugger(global_object, jsc_vm, task);
            return JSC::QueuedTask::Result::Executed;
        }
        ColloRestoredTurnScope scope(vm, jsc_vm, m_owner_token);
        JSC::runMicrotaskWithDebugger(global_object, jsc_vm, task);
        return JSC::QueuedTask::Result::Executed;
    }

    bool isRunnable() const final { return true; }

private:
    explicit ColloOwnerMicrotaskDispatcher(uint64_t owner_token)
        : JSC::MicrotaskDispatcher(Type::None)
        , m_owner_token(owner_token)
    {
    }

    uint64_t m_owner_token;
};

RefPtr<JSC::MicrotaskDispatcher> ColloCrossTaskToken::createMicrotaskDispatcher(JSC::VM&, JSC::JSGlobalObject*)
{
    return ColloOwnerMicrotaskDispatcher::tryCreate(m_owner_token);
}

RefPtr<JSC::MicrotaskDispatcher> colloOwnerDispatcherFactoryHook(JSC::VM&, JSC::JSGlobalObject*, uint64_t owner_token)
{
    RefPtr dispatcher = ColloOwnerMicrotaskDispatcher::tryCreate(owner_token);
    if (!dispatcher) [[unlikely]] {
        // The engine answers a null dispatcher by enqueueing without one, so the work runs under whoever drains it.
        // That fallback is silent, hence the warning: a request charged for its neighbor's work looks like a
        // scheduling anomaly, not like an allocation failure.
        static bool warned = false;
        if (!warned) {
            warned = true;
            std::fprintf(stderr, "collo: microtask owner dispatcher allocation failed; attribution degraded\n");
        }
    }
    return dispatcher;
}

uint64_t colloCurrentOwnerTokenHook(JSC::JSGlobalObject* global_object)
{
    ColloVm* vm = ownerVmFromGlobal(global_object);
    if (!vm)
        return 0;
    uint64_t token = acquireOwnerToken(vm, vm->current_exec_ctx);
    if (!token) {
        // A full table means a release was missed, a leak rather than a capacity limit. The reaction records no
        // owner, 0, so it gets no dispatcher and runs under whoever settles it, the engine's behavior without owner
        // hooks. Returning the turnless token instead would be worse, because the restore would install a null owner
        // over a turn that has a live one. It warns once, since this is the hot reaction registration path.
        static bool table_full_warned = false;
        if (!table_full_warned) {
            table_full_warned = true;
            std::fprintf(stderr, "collo: microtask owner table full; attribution degraded to pre-patch behaviour\n");
        }
        return 0;
    }
    return token;
}

} // namespace

extern "C" uint64_t collo_vm_acquire_exec_ctx(ColloVm* vm, ColloExecCtx* exec_ctx)
{
    if (!vm || !exec_ctx)
        return 0;
    return acquireOwnerToken(vm, exec_ctx);
}

extern "C" ColloStatus collo_vm_set_owner_transition_hook(ColloVm* vm, ColloOwnerTransitionHook hook, void* ctx)
{
    if (!vm || !vm->isReady())
        return COLLO_STATUS_INVALID_ARGUMENT;
    vm->owner_transition_hook = hook;
    vm->owner_transition_ctx = ctx;
    return COLLO_STATUS_OK;
}

extern "C" uint64_t collo_vm_owner_crossings(ColloVm* vm) { return vm ? vm->owner_crossings : 0; }

extern "C" ColloStatus collo_vm_release_exec_ctx(ColloVm* vm, ColloExecCtx* exec_ctx)
{
    if (!vm || !exec_ctx)
        return COLLO_STATUS_INVALID_ARGUMENT;
    for (auto& slot : vm->owner_slots) {
        if (slot.token && slot.exec_ctx == exec_ctx) {
            slot.token = 0;
            slot.exec_ctx = nullptr;
        }
    }
    // The turn must not end holding a pointer the caller is about to free.
    if (vm->current_exec_ctx == exec_ctx)
        vm->current_exec_ctx = nullptr;
    return COLLO_STATUS_OK;
}

extern "C" ColloStatus collo_turn_enter(ColloVm* vm, ColloExecCtx* exec_ctx)
{
    if (!vm || !vm->isReady() || !exec_ctx)
        return COLLO_STATUS_INVALID_ARGUMENT;

#ifndef NDEBUG
    assert(execCtxReservedFieldsAreZero(exec_ctx));
#endif

    JSC::JSLockHolder locker(*vm->vm);

    uint64_t now = Collo::threadCpuTimeNs();

    if (!vm->entered_count) {
        vm->current_exec_ctx = exec_ctx;
        vm->turn_exec_ctx = exec_ctx;
        // Registered here rather than at dispatch, so a running owner has a token on every path that enters a turn.
        acquireOwnerToken(vm, exec_ctx);
        vm->microtask_delay_scope.emplace(vm->vm->drainMicrotaskDelayScope());
    } else if (vm->current_exec_ctx != exec_ctx) {
        return COLLO_STATUS_INVALID_ARGUMENT;
    } else if (exec_ctx->turn_cpu_start_ns) {
        RELEASE_ASSERT(now >= exec_ctx->turn_cpu_start_ns);
        exec_ctx->cpu_used_ns_total += now - exec_ctx->turn_cpu_start_ns;
    }

    exec_ctx->turn_cpu_start_ns = now;
    vm->entered_count += 1;
    return COLLO_STATUS_OK;
}

extern "C" ColloStatus collo_turn_exit_ex(ColloVm* vm, ColloValue** out_exception)
{
    Collo::clearOutException(out_exception);
    if (!vm || !vm->isReady() || !vm->entered_count || !vm->current_exec_ctx || !out_exception)
        return COLLO_STATUS_INVALID_ARGUMENT;

    JSC::JSLockHolder locker(*vm->vm);
    ColloExecCtx* exec_ctx = vm->current_exec_ctx;

    bool microtask_exception = false;
    JSC::Strong<JSC::Unknown> microtask_exception_value;

    // Microtasks drain inside the outermost turn, before its CPU slice closes, so the turn pays for the ones it owns.
    // One that another owner registered runs under ColloRestoredTurnScope, which moves the slice for its duration.
    if (vm->entered_count == 1) {
        auto scope = DECLARE_TOP_EXCEPTION_SCOPE(*vm->vm);
        vm->microtask_delay_scope.reset();
        vm->vm->drainMicrotasks();
        if (scope.exception()) {
            microtask_exception = true;
            JSC::JSValue exception = scope.exception()->value();
            microtask_exception_value.set(*vm->vm, exception);
            scope.clearExceptionExceptTermination();
        }
    }

    uint64_t now = Collo::threadCpuTimeNs();
    if (exec_ctx->turn_cpu_start_ns) {
        RELEASE_ASSERT(now >= exec_ctx->turn_cpu_start_ns);
        exec_ctx->cpu_used_ns_total += now - exec_ctx->turn_cpu_start_ns;
    }

    vm->entered_count -= 1;
    if (!vm->entered_count) {
        exec_ctx->turn_cpu_start_ns = 0;
        vm->current_exec_ctx = nullptr;
        // Cleared only after the drain above, so it names the turn's owner for as long as the turn's microtasks run.
        vm->turn_exec_ctx = nullptr;
    } else {
        exec_ctx->turn_cpu_start_ns = now;
    }

    if (microtask_exception) {
        ColloStatus microtask_exception_status
            = Collo::setJsException(vm, microtask_exception_value.get(), out_exception);
        if (microtask_exception_status != COLLO_STATUS_OK)
            return microtask_exception_status;
        return COLLO_STATUS_JS_EXCEPTION;
    }

    return COLLO_STATUS_OK;
}

// ---------------------------------------------------------------------------
// DeferredWorkTimer pump.
//
// Asynchronous wasm settlement, the promises of WebAssembly.instantiate and compile, is queued on JSC's
// DeferredWorkTimer: the wasm worklist thread finishes a plan and calls scheduleWorkSoon(), which arms a
// JSRunLoopTimer on the VM's RunLoop. A worker never runs that RunLoop, since its loop is the Zig scheduler and
// seccomp leaves the RunLoop nothing to poll, so the ready tasks would wait in the timer's queue forever. The worker
// loop replaces the RunLoop with three pieces:
//   - The wakeup gate, ColloDeferredWorkWakeupGate in state.h: an atomic pending flag this file owns, consumed once
//     per loop tick. The timer's m_isScheduled is deliberately not read. It is a plain bool other threads write
//     under the timer's lock, so reading it here is a data race, and a stale false loses a wake rather than
//     delaying it: the loop can drain the wakeup eventfd for an unrelated reason in the same tick, read the stale
//     false, skip the pump, never arm the backstop because it never saw imminent work, and sleep with no wake left.
//   - The notification: JSRunLoopTimer::addTimerSetNotification fires synchronously on whichever thread called
//     setTimeUntilFire, such as the wasm worklist thread. It stores the pending flag and then writes the worker's
//     wakeup eventfd, so a blocked scheduler sees the schedule without polling.
//   - The pump, which runs the ready tasks as the RunLoop timer callback would, through DeferredWorkTimer::doWork,
//     but inside a Collo turn, so the settling JS gets an exec context, CPU accounting and the single end-of-turn
//     microtask drain. doWork's per-task drainMicrotasks does nothing under the turn's DrainMicrotaskDelayScope.
// ---------------------------------------------------------------------------

namespace {

// Returns the VM's wakeup gate, installing it on first use. Every pump export runs on the VM thread, the worker loop
// or a test driver standing in for it, so the lazy install needs no lock; the worklist thread reaches the gate only
// through the shared_ptr its notification captured, which JSRunLoopTimer keeps until the DeferredWorkTimer dies. Each
// VM has its own gate, so two live VMs in one process, as in-process tests run them, cannot hide each other's wakes.
ColloDeferredWorkWakeupGate& ensureDeferredWorkWakeupGate(ColloVm* vm)
{
    if (!vm->deferred_work_wakeup_gate) {
        auto gate = std::make_shared<ColloDeferredWorkWakeupGate>();
        // Seeded pending, because schedules made before this install fired no notification: wasm compiled during
        // boot evaluation queues work before the loop registers its wakeup fd, and tests pump without registering
        // one. One spurious first pump, doWork over an empty queue, is cheaper than any handshake with the timer's
        // own state.
        gate->pending.store(true, std::memory_order_release);
        vm->vm->deferredWorkTimer->addTimerSetNotification(
            WTF::createSharedTask<JSC::JSRunLoopTimer::TimerNotificationType>([gate] {
                // Runs synchronously inside setTimeUntilFire, on whichever thread scheduled: the wasm worklist
                // thread when a plan completes, or the JS thread for a same-thread schedule.
                //
                // No wake is lost, given the consuming exchange in collo_vm_deferred_work_scheduled and this order:
                // the pending store comes before the eventfd write. Suppose the loop's exchange reads false while
                // this schedule is in flight. Then no eventfd drain on the loop thread has consumed this write,
                // because a drain that had would follow the store and the write, and the exchange runs after the
                // drain on the same thread, so it would have seen true. The write is therefore still coming or still
                // undrained. Either way the eventfd counter is or becomes nonzero, the level-triggered ring wait
                // cannot sleep through it, and the tick it wakes runs its exchange after its drain and sees true. A
                // wake with no work left costs one doWork that does nothing.
                gate->pending.store(true, std::memory_order_release);
                int fd = gate->wakeup_fd.load(std::memory_order_acquire);
                if (fd < 0)
                    return;
                // An eventfd write is async-signal-safe and allowed by the worker's seccomp filter. EAGAIN on a
                // saturated counter is harmless, since the fd is already readable and the loop will wake.
                uint64_t one = 1;
                ssize_t rc = ::write(fd, &one, sizeof(one));
                (void)rc;
            }));
        vm->deferred_work_wakeup_gate = std::move(gate);
    }
    return *vm->deferred_work_wakeup_gate;
}

} // namespace

extern "C" uint32_t collo_vm_deferred_work_scheduled(ColloVm* vm)
{
    if (!vm || !vm->isReady())
        return 0;
    // Consumes the gate: 1 when deferred work was scheduled since the last call. acq_rel pairs with the
    // notification's release store, and the comment in the notification shows why a 0 here never strands a schedule.
    // A spurious 1, from the install seed or a schedule the backstop already swept, costs one doWork that does
    // nothing.
    return ensureDeferredWorkWakeupGate(vm).pending.exchange(false, std::memory_order_acq_rel) ? 1u : 0u;
}

extern "C" ColloStatus collo_vm_set_deferred_work_wakeup_fd(ColloVm* vm, int32_t wakeup_fd)
{
    if (!vm || !vm->isReady())
        return COLLO_STATUS_INVALID_ARGUMENT;
    // A negative fd unregisters. The worker runtime does that in Runtime.deinit, before the scheduler closes the
    // eventfd, so a late worklist notification writes nothing instead of writing a recycled fd number. One window
    // remains: a notification already past its fd load when this store lands can still write the closing fd before
    // its write. Closing it would need the gate to own a dup of the eventfd, closed only by the gate's destructor,
    // and the worker's seccomp filter does not allow dup.
    if (wakeup_fd < 0) {
        if (auto& gate = vm->deferred_work_wakeup_gate)
            gate->wakeup_fd.store(-1, std::memory_order_release);
        return COLLO_STATUS_OK;
    }
    ensureDeferredWorkWakeupGate(vm).wakeup_fd.store(wakeup_fd, std::memory_order_release);
    return COLLO_STATUS_OK;
}

extern "C" ColloStatus collo_vm_pump_deferred_work(
    ColloVm* vm, ColloExecCtx* exec_ctx, uint32_t* out_state, ColloValue** out_exception)
{
    Collo::clearOutException(out_exception);
    if (!vm || !vm->isReady() || !exec_ctx || !out_state || !out_exception)
        return COLLO_STATUS_INVALID_ARGUMENT;
    *out_state = 0;

    // The settle tasks run JS, resolving or rejecting the wasm promises, so the pump is a real turn. The caller
    // supplies the exec context it is charged to: the boot context while the boot is open, and a host context with
    // no request afterwards, never a live request's, because the JSC ticket carries no request identity to infer one
    // from. pumpDeferredWork in worker/scheduler/loop.zig owns that choice.
    ColloStatus enter_status = collo_turn_enter(vm, exec_ctx);
    if (enter_status != COLLO_STATUS_OK)
        return enter_status;

    {
        JSC::JSLockHolder locker(*vm->vm);
        auto& timer = vm->vm->deferredWorkTimer.get();
        // The RunLoop timer callback's body: it drains the ready task queue under the timer's lock, skips cancelled
        // tickets and runs each remaining task under a catch scope. The turn's DrainMicrotaskDelayScope defers
        // doWork's per-task drainMicrotasks, and the real drain happens once in collo_turn_exit_ex below.
        timer.doWork(*vm->vm);
        uint32_t state = 0;
        if (timer.hasAnyPendingWork())
            state |= COLLO_DEFERRED_WORK_PENDING;
        if (timer.hasImminentlyScheduledWork())
            state |= COLLO_DEFERRED_WORK_PENDING_IMMINENT;
        *out_state = state;
    }

    return collo_turn_exit_ex(vm, out_exception);
}

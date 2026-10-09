// The engine side of the fork: what the zygote does to its VM before forking, what a worker child does after, the
// collections both run, and the process-wide engine overrides set around those steps. Runs on the VM thread, except
// collo_vm_request_termination, which the worker's sentinel thread calls.
//
// A worker forks from a single-threaded zygote and then installs a seccomp filter that denies clone, so the threads
// it has when the filter goes on are all it will ever have. Everything here serves that: compilation is drained
// before the fork, the libpas scavenger stays suspended while the zygote serves forks, and a worker starts its
// scavenger and compiler threads, pinned against retiring, before the filter.

#include "jsc/runtime/state.h"

#include "host_functions/webapi/platform/navigator.h"

#include <JavaScriptCore/InitializeThreading.h>

#include <bmalloc/BPlatform.h>

#if BUSE(LIBPAS)
#include <bmalloc/pas_scavenger.h>
#include <bmalloc/pas_thread_suspender.h>
#endif

#include <wtf/Scope.h>

#include <limits>
#include <unistd.h>

namespace {

#if BUSE(LIBPAS)
// How long a worker's scavenger thread waits in deep sleep, with nothing left to reclaim, before it retires. Retiring
// is fatal in a worker: the next eligibility notification recreates the thread, and seccomp denies clone. timed_wait
// in pas_scavenger.c converts the absolute deadline to 32-bit seconds since the epoch, so the current time plus this
// timeout must stay below 2^32 seconds, which falls in the year 2106; past that the conversion is undefined, and on
// x86_64 the deadline lands in the past and the thread spins. Ten years outlasts any worker and keeps the sum inside
// that bound until 2096.
constexpr double workerScavengerDeepSleepTimeoutMs = 10. * 365. * 24. * 60. * 60. * 1000.;
#endif

// Suspends the libpas scavenger, waiting until its thread has exited, and records that on the VM. Idempotent;
// COLLO_STATUS_UNSUPPORTED on an engine built without libpas.
ColloStatus suspendFastMallocScavengerForFork(ColloVm* vm)
{
    if (vm->fastmalloc_scavenger_suspended_for_fork)
        return COLLO_STATUS_OK;

#if BUSE(LIBPAS)
    pas_scavenger_suspend();
    vm->fastmalloc_scavenger_suspended_for_fork = true;
    return COLLO_STATUS_OK;
#else
    return COLLO_STATUS_UNSUPPORTED;
#endif
}

// Counts one termination request in flight unless destruction has begun; ~ColloVm waits for the count to reach zero
// before tearing the VM down. The second check closes the race with a destroy that started after the first.
bool tryBeginTerminationRequest(ColloVm* vm)
{
    if (!vm || vm->destroying.load(std::memory_order_acquire))
        return false;

    uint32_t count = vm->termination_requests.load(std::memory_order_acquire);
    do {
        if (count == std::numeric_limits<uint32_t>::max())
            return false;
    } while (!vm->termination_requests.compare_exchange_weak(
        count, count + 1, std::memory_order_acq_rel, std::memory_order_acquire));

    if (vm->destroying.load(std::memory_order_acquire)) {
        vm->termination_requests.fetch_sub(1, std::memory_order_acq_rel);
        return false;
    }
    return true;
}

void finishTerminationRequest(ColloVm* vm)
{
    uint32_t previous = vm->termination_requests.fetch_sub(1, std::memory_order_acq_rel);
    RELEASE_ASSERT(previous);
}

} // namespace

namespace Collo {

// Undoes suspendFastMallocScavengerForFork with libpas's default behavior, for a process that did not fork or for VM
// teardown. A no-op when the scavenger is not suspended for this VM.
void resumeFastMallocScavengerIfSuspended(ColloVm* vm)
{
    if (!vm || !vm->fastmalloc_scavenger_suspended_for_fork)
        return;

#if BUSE(LIBPAS)
    pas_scavenger_resume();
#endif
    vm->fastmalloc_scavenger_suspended_for_fork = false;
}

// The worker's seccomp filter denies clone and signals, and the libpas
// scavenger needs both: its thread is created on the first eligibility
// notification and retires after an idle period, and it reclaims another
// thread's local cache by suspending that thread through WTF's signal-based
// suspender. So the worker gives the scavenger one thread for life, born
// here while clone is still permitted, and makes every remote cache stop
// cooperative: an idle thread's cache is reclaimed the next time that thread
// allocates, never by force. The thread lives because its deep sleep, where
// it waits for the next eligibility notification, outlasts the worker.
// pas_scavenger_disable_shut_down would keep it alive too, but that is
// libpas's continuous-scavenging mode: the loop never sleeps, and an idle
// worker spends a whole core on it.
// FIXME: A thread that parks without allocating never stops its cache, so the
// scavenger keeps polling every period and never reaches that deep sleep.
void resumeFastMallocScavengerForSandbox(ColloVm* vm)
{
    if (!vm || !vm->fastmalloc_scavenger_suspended_for_fork)
        return;

#if BUSE(LIBPAS)
    pas_thread_suspender_instance = nullptr;
    pas_scavenger_deep_sleep_timeout_in_milliseconds = workerScavengerDeepSleepTimeoutMs;
    // The resume marks memory eligible and notifies, and that notification
    // creates the thread now rather than on some later deallocation.
    pas_scavenger_resume();
    RELEASE_ASSERT(pas_scavenger_current_state != pas_scavenger_state_no_thread);
#endif
    vm->fastmalloc_scavenger_suspended_for_fork = false;
}

} // namespace Collo

// Called once by the zygote at boot, after warmup and outside any turn, before it waits to become single-threaded
// and starts serving forks.
extern "C" ColloStatus collo_vm_prepare_for_fork(ColloVm* vm)
{
    if (!vm || !vm->isReady() || vm->entered_count || vm->current_exec_ctx)
        return COLLO_STATUS_INVALID_ARGUMENT;

    JSC::JSLockHolder locker(*vm->vm);
    // Finishes any compilation still in flight before the caller waits for the process to become single-threaded.
    // A compiler thread observes its idle timeout only while parked, so a plan still compiling here would hold its
    // thread past the drain budget and fail the fork. Draining makes tier-up during warmup safe, so the warmup
    // corpus need not stay under the tier-up threshold.
    JSC::drainCompilerWorklists(*vm->vm);

    // The zygote holds no tenant code, so a full collection here would mostly mark and sweep freshly installed
    // globals and dirty pages every worker then inherits. This pass stays narrow: it flushes deferred VM cleanup and
    // releases allocator free pages while keeping the shareable builtin code.
    vm->vm->finalizeSynchronousJSExecution();
    WTF::releaseFastMallocFreeMemory();
    // The libpas suspension is counted and reversible. The zygote keeps it while it serves fork requests, and each
    // worker child resumes it in collo_vm_post_fork_child.
    return suspendFastMallocScavengerForFork(vm);
}

extern "C" ColloStatus collo_prepare_process_for_fork(void)
{
    // Only trims allocator free pages. The zygote is started with fork and exec, so no worker inherits the calling
    // process's heap, and suspending the process-global scavenger with no VM to resume it would leave it suspended
    // for the rest of a process that keeps running.
    WTF::releaseFastMallocFreeMemory();
    return COLLO_STATUS_OK;
}

extern "C" ColloStatus collo_vm_post_fork_child(ColloVm* vm)
{
    if (!vm || !vm->isReady() || vm->entered_count || vm->current_exec_ctx)
        return COLLO_STATUS_INVALID_ARGUMENT;

    // A fork child inherits the helper-thread registry's entries but not the threads behind them. A test may run
    // this hook without forking, and then the registry still refers to live helper threads and must stay intact so
    // later pre-fork drains can wake them.
    const auto current_pid = static_cast<uint64_t>(getpid());
    const bool forked = current_pid != vm->process_id_at_creation;
    if (forked) {
        if (auto resetAutomaticThreadRegistry = WTF::colloResetAutomaticThreadRegistry)
            resetAutomaticThreadRegistry();
        vm->process_id_at_creation = current_pid;
    }
    // The sandbox variant gives up the thread suspender for the rest of the
    // process and keeps the scavenger thread for life, which only a forked
    // worker needs: its seccomp filter is what rules out signals and a new
    // thread. A process that never forked keeps libpas's defaults.
    if (forked)
        Collo::resumeFastMallocScavengerForSandbox(vm);
    else
        Collo::resumeFastMallocScavengerIfSuspended(vm);
    WTF::clearColloAutomaticThreadTimeoutOverride();
    JSC::JSLockHolder locker(*vm->vm);
    vm->current_exec_ctx = nullptr;
    vm->entered_count = 0;
    vm->microtask_delay_scope.reset();
    // Web API objects are refreshed only when they were installed: on a VM created without them the navigator slot
    // holds an uninitialized cell that passes isCell() but crashes dynamicDowncast in refreshWebApiNavigator.
    if (vm->web_apis_installed)
        Collo::HostFunctions::refreshWebApiNavigator(vm->global_object, *vm->vm);
    vm->vm->finalizeSynchronousJSExecution();
    return COLLO_STATUS_OK;
}

extern "C" ColloStatus collo_vm_reseed_after_fork(ColloVm* vm, const ColloRandomSeeds* seeds)
{
    if (!vm || !vm->isReady() || !seeds || vm->entered_count || vm->current_exec_ctx)
        return COLLO_STATUS_INVALID_ARGUMENT;

    JSC::JSLockHolder locker(*vm->vm);
    vm->global_object->weakRandom().setSeed(seeds->weak_random_seed);
    vm->vm->random().setSeed(seeds->vm_random_seed);
    vm->vm->heapRandom().setSeed(seeds->heap_random_seed);
    return COLLO_STATUS_OK;
}

extern "C" ColloStatus collo_vm_collect_full_gc_and_trim(ColloVm* vm)
{
    if (!vm || !vm->isReady() || vm->entered_count || vm->current_exec_ctx)
        return COLLO_STATUS_INVALID_ARGUMENT;

    JSC::JSLockHolder locker(*vm->vm);
    JSC::sanitizeStackForVM(*vm->vm);
    vm->vm->finalizeSynchronousJSExecution();
    vm->vm->heap.collectNow(JSC::Sync, JSC::CollectionScope::Full);
    WTF::releaseFastMallocFreeMemory();
#if BUSE(LIBPAS)
    pas_scavenger_run_synchronously_now();
#endif
    vm->vm->finalizeSynchronousJSExecution();
    return COLLO_STATUS_OK;
}

extern "C" ColloStatus collo_vm_collect_eden_gc(ColloVm* vm)
{
    if (!vm || !vm->isReady() || vm->entered_count || vm->current_exec_ctx)
        return COLLO_STATUS_INVALID_ARGUMENT;

    JSC::JSLockHolder locker(*vm->vm);
    // Clearing the dead stack and ending the synchronous job drop the stale
    // stack words and the WeakRef targets kept alive for the last turn, which
    // would otherwise mark young cells the heap no longer references.
    JSC::sanitizeStackForVM(*vm->vm);
    vm->vm->finalizeSynchronousJSExecution();
    vm->vm->heap.collectNow(JSC::Sync, JSC::CollectionScope::Eden);
    return COLLO_STATUS_OK;
}

extern "C" ColloStatus collo_vm_request_termination(ColloVm* vm)
{
    // A best-effort request for a cooperative unwind. The sentinel thread calls it while the VM thread runs JS, and
    // the caller must keep the ColloVm object alive; once destruction has begun the request is refused.
    if (!tryBeginTerminationRequest(vm))
        return COLLO_STATUS_INVALID_ARGUMENT;
    auto finish = WTF::makeScopeExit([&] { finishTerminationRequest(vm); });

    if (!vm->isReady())
        return COLLO_STATUS_INVALID_ARGUMENT;

    // notifyNeedTermination is the engine's cross-thread trap, marked CONCURRENT_SAFE. The non-atomic
    // forbidExecutionOnTermination flag was set at VM creation, before any other thread could see the VM.
    vm->vm->notifyNeedTermination();
    return COLLO_STATUS_OK;
}

extern "C" ColloStatus collo_vm_prespawn_compiler_threads(ColloVm* vm)
{
    if (!vm || !vm->isReady() || vm->entered_count || vm->current_exec_ctx)
        return COLLO_STATUS_INVALID_ARGUMENT;

    // Creates the OS thread behind every AutomaticThread registered on the JS and wasm worklists without giving any
    // of them work: each polls once, gets PollResult::Wait and parks on its condition. A worker calls this between
    // dropping its privileges and installing seccomp, so the threads are born while clone is still permitted and
    // inherit no-new-privileges and empty capability sets. The caller pins the WTF helper-thread timeout first so
    // none of them ever retires, because once seccomp is installed a retired helper cannot be cloned again and the
    // worker aborts on its next compile.
    //
    // Starting them explicitly, rather than handing a worklist token work so its thread appears as a side effect,
    // survives engine changes: a side-effect spawn stops happening the day that work is short-circuited, and the
    // failure surfaces much later as an abort on the first real compile.
    {
        JSC::JSLockHolder locker(*vm->vm);
        JSC::startCompilerThreads();
        // The collector thread is born by the first collection request the
        // mutator relinquishes at a lock release: the mutator takes the conn
        // when it requests while the collector is idle, and releasing the API
        // lock with the request still queued hands the conn over and wakes
        // the thread. Request an eden collection, then let the lock go.
        vm->vm->heap.collectAsync(JSC::CollectionScope::Eden);
    }
    // Wait for that collection, and any the thread is still running, so the
    // thread is parked before the caller freezes the thread set.
    JSC::JSLockHolder locker(*vm->vm);
    vm->vm->heap.collectSync(JSC::CollectionScope::Eden);
    return COLLO_STATUS_OK;
}

extern "C" ColloStatus collo_set_helper_threads_timeout_override_ns(uint64_t timeout_ns)
{
    WTF::setColloAutomaticThreadTimeout(WTF::Seconds::fromNanoseconds(static_cast<double>(timeout_ns)));
    return COLLO_STATUS_OK;
}

extern "C" void collo_clear_helper_threads_timeout_override(void) { WTF::clearColloAutomaticThreadTimeoutOverride(); }

extern "C" ColloStatus collo_set_gc_max_heap_size_override_bytes(uint64_t bytes)
{
    if (bytes > static_cast<uint64_t>(std::numeric_limits<size_t>::max()))
        return COLLO_STATUS_INVALID_ARGUMENT;

    JSC::setColloGCMaxHeapSizeOverride(static_cast<size_t>(bytes));
    return COLLO_STATUS_OK;
}

extern "C" void collo_clear_gc_max_heap_size_override(void) { JSC::clearColloGCMaxHeapSizeOverride(); }

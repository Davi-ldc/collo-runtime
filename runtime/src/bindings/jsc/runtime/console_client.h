// The bridge between JSC's built-in console object and the ColloConsoleSink a worker registers, declared here and
// implemented in console_client.cpp. It runs in the worker, on the VM thread, inside a live console call frame.
//
// Formatting never re-enters user code, and no step materializes an unbounded amount: the client invokes no getter,
// no user toString or toJSON and no Proxy trap, copies strings only up to the line budget, and renders an object
// whose estimated property count exceeds inspect_max_enumerated_properties opaquely instead of listing its names.
// Each request's output is also capped, and past the cap a call reaches the sink only as a drop marker; the sink
// contract in abi.h defines the markers.

#pragma once

// config.h, which pulls in cmakeconfig.h, must precede every WebKit header. PlatformEnable.h derives layout gates
// such as ENABLE_REFTRACKER from ASSERT_ENABLED at its first inclusion, so a translation unit that includes JSC
// headers before cmakeconfig.h silently compiles WTF and JSC types with layouts that differ from the prebuilt
// library's.
#include "config.h"

#include "collo/abi.h"

#include <JavaScriptCore/ConsoleClient.h>
#include <wtf/FastMalloc.h>
#include <wtf/HashMap.h>
#include <wtf/MonotonicTime.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/text/StringHash.h>
#include <wtf/text/WTFString.h>

struct ColloVm;

namespace Collo {

// One instance per VM, owned by ColloVm; the global object holds only a WeakPtr, and only while a sink is registered.
// Without a sink JSC's console object returns before calling the client, so the console keeps its observable
// behavior and emits nothing.
//
// The formatter is deliberately smaller than Node's util.inspect and honors no custom inspect symbols. Objects render
// from their own data properties to a bounded depth with bounded item and property counts, and the final line is cut
// at the sink's registered byte budget with the truncated flag set.
class ConsoleClient final : public JSC::ConsoleClient {
    WTF_MAKE_TZONE_ALLOCATED(ConsoleClient);
    // Required in the most derived subclass: it routes `delete` through the checked-pointer destroying delete, so
    // teardown satisfies CanMakeThreadSafeCheckedPtr.
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(ConsoleClient);

public:
    explicit ConsoleClient(ColloVm* owner)
        : owner(owner)
    {
    }

    void messageWithTypeAndLevel(
        JSC::MessageType, JSC::MessageLevel, JSC::JSGlobalObject*, Ref<Inspector::ScriptArguments>&&) final;
    void count(JSC::JSGlobalObject*, const String& label) final;
    void countReset(JSC::JSGlobalObject*, const String& label) final;
    void profile(JSC::JSGlobalObject*, const String& title) final;
    void profileEnd(JSC::JSGlobalObject*, const String& title) final;
    void takeHeapSnapshot(JSC::JSGlobalObject*, const String& title) final;
    void time(JSC::JSGlobalObject*, const String& label) final;
    void timeLog(JSC::JSGlobalObject*, const String& label, Ref<Inspector::ScriptArguments>&&) final;
    void timeEnd(JSC::JSGlobalObject*, const String& label) final;
    void timeStamp(JSC::JSGlobalObject*, Ref<Inspector::ScriptArguments>&&) final;
    void record(JSC::JSGlobalObject*, Ref<Inspector::ScriptArguments>&&) final;
    void recordEnd(JSC::JSGlobalObject*, Ref<Inspector::ScriptArguments>&&) final;
    void screenshot(JSC::JSGlobalObject*, Ref<Inspector::ScriptArguments>&&) final;

    // collo_webapi_cleanup_request clears one request's spend when that request ends, and every sink registration
    // resets all of them.
    void clearRequestOutputBudget(uint64_t request_id);
    void resetRequestOutputBudgets();

private:
    bool sinkActive() const;
    void emitLine(uint8_t level, const WTF::String& body);
    WTF::String normalizedLabel(const WTF::String&);
    bool labelStateAtCap(size_t map_size, bool label_exists);
    uint64_t currentRequestId() const;
    bool budgetExempt(uint64_t request_id) const;
    bool requestOutputExhausted(uint64_t request_id) const;
    void emitBudgetDropMarker(uint64_t request_id);

    // Tenant code chooses the labels, so their state is bounded: labels are truncated, and past the cap the maps
    // accept no new label, with one warning per VM.
    static constexpr unsigned label_units_max = 256;
    static constexpr unsigned label_entries_max = 1024;
    // Request-end cleanup removes budget entries, but a late asynchronous turn can add a cleared id again, so the map
    // needs a hard bound over the worker's life. Past it a new id goes untracked and its lines still reach the sink,
    // where the log ring bounds them.
    static constexpr unsigned request_budget_entries_max = 1024;

    // Console output a request has spent: lines emitted and UTF-8 bytes after the line cut, keyed by request id. The
    // boot identity and id 0 are exempt and never enter the map, because a per-request cap on an identity that lives
    // as long as the worker would silence its output for good.
    struct RequestOutputSpent {
        uint64_t lines { 0 };
        uint64_t bytes { 0 };
    };

    ColloVm* owner;
    unsigned group_depth { 0 };
    bool label_cap_warned { false };
    WTF::HashMap<WTF::String, uint64_t> counts;
    WTF::HashMap<WTF::String, WTF::MonotonicTime> timers;
    WTF::HashMap<uint64_t, RequestOutputSpent, WTF::IntHash<uint64_t>, WTF::UnsignedWithZeroKeyHashTraits<uint64_t>>
        request_output_spent;
};

} // namespace Collo

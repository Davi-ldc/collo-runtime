// The URLSearchParams cell and the entry points `url.cpp` and the request object use to create it and keep it in step
// with a URL. Everything runs on the VM thread except `visitChildren`, which the concurrent marker may run while a
// mutator reallocates the pairs; it therefore reads only the barriered URL edge and the cached atomic cost. A
// URLSearchParams obtained from a URL holds that URL in `m_associated_url` and writes its serialized pairs back into
// it after every change, as the URL Standard's URLSearchParams update steps require.

#pragma once

#include "host_functions/support.h"

#include <JavaScriptCore/JSDestructibleObject.h>
#include <wtf/URLParser.h>

#include <atomic>
#include <cstddef>

namespace Collo::HostFunctions {

struct URLSearchParamsApi {
    JSC::JSObject* constructor;
    JSC::JSObject* prototype;
    JSC::Structure* structure;
    JSC::JSObject* iterator_prototype;
    JSC::Structure* iterator_structure;
};

class JSColloURLSearchParams final : public JSC::JSDestructibleObject {
    using Base = JSC::JSDestructibleObject;

public:
    template <typename CellType, JSC::SubspaceAccess> static JSC::CompleteSubspace* subspaceFor(JSC::VM& vm)
    {
        return &vm.destructibleObjectSpace();
    }

    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* global_object, JSC::JSValue prototype)
    {
        return JSC::Structure::create(
            vm, global_object, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
    }

    // Allocates a URLSearchParams that owns `pairs`. A null `structure` selects the VM's cached URLSearchParams
    // structure, which `installWebApiURL` sets; `associated_url`, when not null, receives every later change.
    static JSColloURLSearchParams* create(JSC::VM& vm, Collo::GlobalObject* global_object,
        WTF::URLParser::URLEncodedForm&& pairs, JSC::JSObject* associated_url = nullptr,
        JSC::Structure* structure = nullptr)
    {
        auto* object = new (NotNull, JSC::allocateCell<JSColloURLSearchParams>(vm)) JSColloURLSearchParams(
            vm, structure ? structure : global_object->urlSearchParamsStructure(), WTF::move(pairs));
        object->finishCreation(vm, associated_url);
        return object;
    }

    static void destroy(JSC::JSCell* cell) { static_cast<JSColloURLSearchParams*>(cell)->~JSColloURLSearchParams(); }

    static size_t estimatedSize(JSC::JSCell*, JSC::VM&);

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    WTF::URLParser::URLEncodedForm& pairs() { return m_pairs; }
    const WTF::URLParser::URLEncodedForm& pairs() const { return m_pairs; }

    size_t memoryCost() const;

    // memoryCost() walks the pair Strings, which a mutator may be reallocating while the concurrent marker runs
    // visitChildren, so the marker reads this cached copy instead. Every mutator that can change the cost refreshes
    // it, which turns append into a walk over all pairs; WebApiUrlSearchParamsPairsMax bounds that walk.
    void refreshGCReportedCost() { m_gc_reported_cost.store(memoryCost(), std::memory_order_relaxed); }
    size_t gcReportedCost() const { return m_gc_reported_cost.load(std::memory_order_relaxed); }

    // Replaces the pairs with those parsed from `search` after the associated URL's query changed. It writes
    // nothing back to the URL and applies no pair cap.
    void resetFromSearch(WTF::String search);
    // Writes the serialized pairs into the associated URL's query; does nothing without an associated URL.
    void syncAssociatedURL();

private:
    JSColloURLSearchParams(JSC::VM& vm, JSC::Structure* structure, WTF::URLParser::URLEncodedForm&& pairs)
        : Base(vm, structure)
        , m_pairs(WTF::move(pairs))
    {
    }

    ~JSColloURLSearchParams() = default;

    void finishCreation(JSC::VM& vm, JSC::JSObject* associated_url)
    {
        Base::finishCreation(vm);
        ASSERT(inherits(info()));
        if (associated_url)
            m_associated_url.set(vm, this, associated_url);
        // The pair Strings live outside the GC heap, so their cost is reported as extra memory here and reported
        // again from visitChildren to stay counted across full collections. The call is out of line so this header
        // does not need the Heap inlines.
        reportInitialGCCost(vm);
    }

    void reportInitialGCCost(JSC::VM&);

    WTF::URLParser::URLEncodedForm m_pairs;
    JSC::WriteBarrier<JSC::JSObject> m_associated_url;
    std::atomic<size_t> m_gc_reported_cost { 0 };
};

// Builds the URLSearchParams constructor, prototype and iterator prototype with their structures, and defines
// `URLSearchParams` on the global object. `installWebApiURL` caches the result on the VM, and no URLSearchParams can
// be created before it does.
URLSearchParamsApi createURLSearchParamsApi(Collo::GlobalObject*, JSC::VM&);
// Returns a URLSearchParams parsed from `search` after dropping one leading '?'. `associated_url`, when not null, is
// the URL object whose query `search` holds. It never throws and applies no pair cap; the definition says why.
JSColloURLSearchParams* createURLSearchParamsFromSearch(
    JSC::JSGlobalObject*, WTF::String search, JSC::JSObject* associated_url);
// Sets the query of `associated_url` to the serialization of `pairs`, or to null when that is empty. Does nothing
// when `associated_url` is not a URL object. Defined in `url.cpp`, which owns the URL cell.
void syncURLSearchParamsToAssociatedURL(JSC::JSObject* associated_url, const WTF::URLParser::URLEncodedForm& pairs);

} // namespace Collo::HostFunctions

// The one implementation of the protocol by which a JSC cell keeps GC edges in storage that its visitChildren walks:
// CellEdgeList for a list of entries, CellNativeRef for one reference-counted native object whose cell edges the owner
// reports through visitAggregate. Mutations and reads run on the VM thread; visit runs on collector threads.
//
// JSC marks concurrently with the mutator (heap/Heap.cpp), so a cell's visitChildren may walk its containers while the
// VM thread changes them. The engine's protocol has two halves, and every mutation here runs both:
//   - a buffer the visitor walks moves or is freed only under the owner's cellLock(), and visit walks it under the same
//     lock;
//   - an edge is stored where the visitor reads it before the owner is barriered (runtime/WriteBarrierInlines.h). A
//     barrier that runs while the owner is grey does nothing, so a marker that scans the owner between an early
//     barrier and the store would blacken it without the edge, and the target could be swept while still referenced.
// An entry therefore arrives with its WriteBarrier fields set by setWithoutWriteBarrier; the list stores it under the
// lock, releases the lock and then barriers the owner. A value in an entry built on the stack is rooted by the
// conservative stack scan until the list stores it.
//
// While it holds the lock, a list does only vector work: it allocates no cell and calls neither JavaScript nor Zig. An
// Entry's destructor and move assignment must not either, so an entry holds WriteBarrier fields, strings and plain
// data, and removeIf's predicate reads only the entry it is given.
//
// Only the VM thread writes, so its reads take no lock. A reference or span into a list stays valid only until the
// next mutation of that list, and any call into JavaScript may mutate it. An in-place change to one field of an entry
// moves no buffer and writes the field directly: a WriteBarrier field with set(vm, owner, value), which stores before
// it barriers.

#pragma once

#include "config.h"

#include <JavaScriptCore/JSCell.h>
#include <JavaScriptCore/VM.h>
#include <JavaScriptCore/WriteBarrier.h>
#include <wtf/FastMalloc.h>
#include <wtf/Locker.h>
#include <wtf/Noncopyable.h>
#include <wtf/Nonmovable.h>
#include <wtf/RefPtr.h>
#include <wtf/Vector.h>

#include <cstddef>
#include <limits>
#include <memory>
#include <new>
#include <span>
#include <utility>

namespace Collo {

// A list of entries that a cell owns and visits. `Entry` is movable, keeps its GC edges in JSC::WriteBarrier fields,
// and provides `template <typename Visitor> void visitEdges(Visitor&) const`, which appends every edge to the visitor.
//
// Entries leave from the front in constant time: a head index marks the first live entry, and the consumed prefix is
// dropped once every entry is consumed, or once more than compaction_floor entries are consumed and they fill at
// least half the vector, so a compaction moves at most as many entries as it drops. A list that never held an entry
// costs one pointer; its storage is allocated on the first append and freed by clear().
template <typename Entry> class CellEdgeList {
    WTF_MAKE_NONCOPYABLE(CellEdgeList);
    WTF_MAKE_NONMOVABLE(CellEdgeList);

public:
    static constexpr size_t compaction_floor = 32;

    CellEdgeList() = default;
    // Runs when the owner is swept, after the last visit, so it takes no lock.
    ~CellEdgeList() = default;

    size_t size() const { return m_storage ? m_storage->entries.size() - m_storage->head : 0; }
    bool isEmpty() const { return !size(); }

    // `index` counts from the first live entry and must be below size().
    Entry& at(size_t index)
    {
        ASSERT(index < size());
        return m_storage->entries[m_storage->head + index];
    }
    const Entry& at(size_t index) const
    {
        ASSERT(index < size());
        return m_storage->entries[m_storage->head + index];
    }
    Entry& first() { return at(0); }
    const Entry& first() const { return at(0); }
    Entry& last() { return at(size() - 1); }
    const Entry& last() const { return at(size() - 1); }

    std::span<Entry> entries()
    {
        if (!m_storage)
            return {};
        return m_storage->entries.mutableSpan().subspan(m_storage->head);
    }
    std::span<const Entry> entries() const
    {
        if (!m_storage)
            return {};
        return m_storage->entries.span().subspan(m_storage->head);
    }
    Entry* begin() { return entries().data(); }
    Entry* end() { return entries().data() + size(); }
    const Entry* begin() const { return entries().data(); }
    const Entry* end() const { return entries().data() + size(); }

    // Makes room for `additional` more entries, so that the appends that follow, with no removal in between, cannot
    // fail. Returns false when the storage cannot grow.
    bool tryReserveAdditional(const JSC::JSCell* owner, size_t additional)
    {
        WTF::Locker locker { owner->cellLock() };
        if (!ensureStorageLocked())
            return false;
        auto& entries = m_storage->entries;
        if (additional > std::numeric_limits<size_t>::max() - entries.size())
            return false;
        return entries.tryReserveCapacity(entries.size() + additional);
    }

    // Stores `entry` last and barriers the owner. Returns false, leaving the list unchanged, when the storage cannot
    // grow.
    bool tryAppend(JSC::VM& vm, const JSC::JSCell* owner, Entry&& entry)
    {
        {
            WTF::Locker locker { owner->cellLock() };
            if (!ensureStorageLocked())
                return false;
            if (!m_storage->entries.tryAppend(WTF::move(entry)))
                return false;
        }
        vm.writeBarrier(owner);
        return true;
    }

    // Stores `entry` first and barriers the owner. Returns false, leaving the list unchanged, when the storage cannot
    // grow.
    bool tryPrepend(JSC::VM& vm, const JSC::JSCell* owner, Entry&& entry)
    {
        {
            WTF::Locker locker { owner->cellLock() };
            if (!ensureStorageLocked())
                return false;
            auto& storage = *m_storage;
            if (storage.head) {
                storage.entries[--storage.head] = WTF::move(entry);
            } else {
                if (!storage.entries.tryReserveCapacity(storage.entries.size() + 1))
                    return false;
                storage.entries.insert(0, WTF::move(entry));
            }
        }
        vm.writeBarrier(owner);
        return true;
    }

    // Removes the first entry and returns it by value, so the caller's stack roots its edges. The list must not be
    // empty.
    Entry takeFirst(const JSC::JSCell* owner)
    {
        ASSERT(!isEmpty());
        WTF::Locker locker { owner->cellLock() };
        auto& storage = *m_storage;
        Entry entry = WTF::move(storage.entries[storage.head]);
        storage.head++;
        compactLocked();
        return entry;
    }

    // Removes every entry for which `predicate(const Entry&)` holds, keeping the others in order, and returns how many
    // it removed. The predicate runs under the lock.
    template <typename Predicate> size_t removeIf(const JSC::JSCell* owner, const Predicate& predicate)
    {
        if (!m_storage)
            return 0;
        WTF::Locker locker { owner->cellLock() };
        auto& storage = *m_storage;
        size_t removed = storage.entries.removeAllMatching(
            [&predicate](Entry& entry) { return predicate(static_cast<const Entry&>(entry)); }, storage.head);
        compactLocked();
        return removed;
    }

    // Removes every entry and frees the storage, after the lock is dropped.
    void clear(const JSC::JSCell* owner)
    {
        if (!m_storage)
            return;
        StoragePtr dropped;
        {
            WTF::Locker locker { owner->cellLock() };
            dropped = std::exchange(m_storage, nullptr);
        }
    }

    // Moves every entry of `source`, which `source_owner` owns, behind this list's entries, and barriers the owner.
    // The entries leave `source` under its owner's lock and arrive here under this owner's lock, and nothing between
    // the two allocates a cell or calls out, so no collection can end while they are in neither list. Returns false,
    // leaving both lists unchanged, when this list's storage cannot grow.
    bool tryAdoptAllFrom(JSC::VM& vm, const JSC::JSCell* owner, CellEdgeList& source, const JSC::JSCell* source_owner)
    {
        if (source.isEmpty())
            return true;
        if (isEmpty()) {
            StoragePtr moved;
            {
                WTF::Locker locker { source_owner->cellLock() };
                moved = std::exchange(source.m_storage, nullptr);
            }
            StoragePtr replaced;
            {
                WTF::Locker locker { owner->cellLock() };
                replaced = std::exchange(m_storage, WTF::move(moved));
            }
            vm.writeBarrier(owner);
            return true;
        }
        if (!tryReserveAdditional(owner, source.size()))
            return false;
        StoragePtr moved;
        {
            WTF::Locker locker { source_owner->cellLock() };
            moved = std::exchange(source.m_storage, nullptr);
        }
        {
            WTF::Locker locker { owner->cellLock() };
            for (auto& entry : moved->entries.mutableSpan().subspan(moved->head))
                m_storage->entries.append(WTF::move(entry));
        }
        vm.writeBarrier(owner);
        return true;
    }

    // Appends every edge of every live entry. Called from the owner's visitChildren, which runs on collector threads.
    template <typename Visitor> void visit(const JSC::JSCell* owner, Visitor& visitor) const
    {
        WTF::Locker locker { owner->cellLock() };
        if (!m_storage)
            return;
        for (auto& entry : m_storage->entries.span().subspan(m_storage->head))
            entry.visitEdges(visitor);
    }

private:
    struct Storage {
        WTF::Vector<Entry> entries;
        // Entries before `head` were taken and are dead.
        size_t head { 0 };
    };

    struct StorageDeleter {
        void operator()(Storage* storage) const
        {
            storage->~Storage();
            WTF::fastFree(storage);
        }
    };
    using StoragePtr = std::unique_ptr<Storage, StorageDeleter>;

    bool ensureStorageLocked()
    {
        if (m_storage)
            return true;
        void* memory = nullptr;
        if (!WTF::tryFastMalloc(sizeof(Storage)).getValue(memory))
            return false;
        m_storage = StoragePtr(new (NotNull, memory) Storage());
        return true;
    }

    void compactLocked()
    {
        auto& storage = *m_storage;
        if (!storage.head)
            return;
        if (storage.head >= storage.entries.size()) {
            storage.entries.clear();
            storage.head = 0;
            return;
        }
        if (storage.head > compaction_floor && storage.head * 2 >= storage.entries.size()) {
            storage.entries.removeAt(0, storage.head);
            storage.head = 0;
        }
    }

    StoragePtr m_storage;
};

// A reference to a native object that a cell owns and whose cell edges the owner reports by calling
// `T::visitAggregate(visitor)` from its visitChildren. Replacing or dropping the reference takes the owner's lock, so
// the collector never visits an object being freed, and the old object is released only after the lock is dropped,
// because its destructor may call into Zig.
template <typename T> class CellNativeRef {
    WTF_MAKE_NONCOPYABLE(CellNativeRef);
    WTF_MAKE_NONMOVABLE(CellNativeRef);

public:
    CellNativeRef() = default;
    // Runs when the owner is swept, after the last visit, so it takes no lock.
    ~CellNativeRef() = default;

    T* get() const { return m_ref.get(); }
    explicit operator bool() const { return !!m_ref; }
    T* operator->() const { return m_ref.get(); }

    // Stores `ref` and barriers the owner, since the new object may report edges the collector has not seen.
    void set(JSC::VM& vm, const JSC::JSCell* owner, WTF::RefPtr<T>&& ref)
    {
        WTF::RefPtr<T> replaced;
        {
            WTF::Locker locker { owner->cellLock() };
            replaced = std::exchange(m_ref, WTF::move(ref));
        }
        vm.writeBarrier(owner);
    }

    // Drops the reference and hands it to the caller, who releases the object outside the lock.
    WTF::RefPtr<T> take(const JSC::JSCell* owner)
    {
        WTF::Locker locker { owner->cellLock() };
        return std::exchange(m_ref, nullptr);
    }

    template <typename Visitor> void visit(const JSC::JSCell* owner, Visitor& visitor) const
    {
        WTF::Locker locker { owner->cellLock() };
        if (m_ref)
            m_ref->visitAggregate(visitor);
    }

private:
    WTF::RefPtr<T> m_ref;
};

} // namespace Collo

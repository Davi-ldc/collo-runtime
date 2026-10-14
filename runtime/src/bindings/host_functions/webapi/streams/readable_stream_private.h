// The cells of the ReadableStream implementation: the stream with its queue and pending reads, the controller base with
// its default and byte controllers, both readers, the BYOB request, the async iterator, the state of a tee and of
// ReadableStream.from, and the body consumer. Everything runs on the VM thread, except visitChildren
// (readable_stream_objects.cpp), which collector threads run concurrently.
//
// Every edge from one of these cells to another cell is a WriteBarrier field, the promises they will settle included.
// The stream's queue and its two lists of pending reads are Collo::CellEdgeList and its native source a
// Collo::CellNativeRef, which own the lock and barrier protocol the concurrent marker needs (jsc/runtime/cell_edges.h).
// A pending read's promise holds nothing of the stream: whoever can settle the read reaches the stream another way (a
// controller, the reaction of a native pull, a tee or pipe reaction), and a stream nothing can feed is collected with
// its pending reads.
//
// A stream has at most one of a controller and a native source. Streams that JavaScript constructs, transform
// readables, tee branches of a stream without a native source and ReadableStream.from streams have a controller;
// streams over bytes, Blobs and bodies have a native source and no controller, which keeps one cell per body.
//
// User code (start, pull, cancel and size callbacks, iterator methods, and a `then` getter that settling a read with a
// {value, done} object can run) can re-enter a stream and close or error it. close() and error() do nothing once the
// stream has left the readable state, so code after a call into JavaScript may call them without checking again, and
// every other member is read again after such a call.

#pragma once

#include "host_functions/webapi/streams/readable_stream_consume.h"
#include "host_functions/webapi/streams/stream_common_private.h"

#include <atomic>

namespace Collo::HostFunctions {

// What JSColloReadableStream::drainNativeBytes did. NotAvailable leaves the stream untouched: it has no native source,
// is not readable, is disturbed or locked, has queued chunks, a pending read or a pull in flight, or its source cannot
// drain in one step. Every other result closes the stream and marks it disturbed. Drained means the output holds every
// remaining byte; after TooLarge or OutOfMemory the remaining bytes are lost.
enum class ReadableStreamDrainResult : uint8_t {
    NotAvailable,
    Drained,
    OutOfMemory,
    TooLarge,
};

// A readable stream's controller. The underlying source is JavaScript (a source dictionary with its pull and cancel
// methods) or one of the bridge's cells, whose algorithms are C++: the TransformStream that feeds its readable side,
// the tee state that feeds a branch, or ReadableStream.from's iterator state. The default and byte controllers add
// only what their interfaces have of their own.
class JSColloReadableStreamController : public JSC::JSNonFinalObject {
    using Base = JSC::JSNonFinalObject;

public:
    enum class SourceKind : uint8_t {
        JavaScript,
        Transform,
        Tee,
        From,
    };

    template <typename CellType, JSC::SubspaceAccess> static JSC::CompleteSubspace* subspaceFor(JSC::VM& vm)
    {
        static_assert(CellType::needsDestruction == JSC::DoesNotNeedDestruction);
        return &vm.cellSpace();
    }

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    JSColloReadableStream* stream() const { return m_stream.get(); }
    SourceKind sourceKind() const { return m_source_kind; }
    // The underlying source dictionary, or the cell whose C++ algorithms are the source.
    JSC::JSValue source() const { return m_source.get(); }
    bool starting() const { return m_starting; }

    void setJavaScriptSource(JSC::VM&, JSC::JSValue source, JSC::JSValue pull, JSC::JSValue cancel);
    void setNativeSource(JSC::VM&, SourceKind, JSC::JSCell* owner);
    // ReadableStream{Default,Byte}ControllerClearAlgorithms. A closed or errored stream never calls its source again,
    // so dropping the source lets the collector reclaim what it holds, often the stream's own consumer.
    void clearAlgorithms();

    // Set before the underlying source's start runs, so nothing that start does pulls.
    void markStarting() { m_starting = true; }
    // The start algorithm: the stream pulls only once `start_promise` fulfills, and errors when it rejects.
    void startWith(JSC::JSGlobalObject*, JSC::JSPromise* start_promise);
    void startFinished(JSC::JSGlobalObject*);
    void startFailed(JSC::JSGlobalObject*, JSC::JSValue reason);
    // ReadableStream{Default,Byte}ControllerCallPullIfNeeded. A tee branch's pull asks the tee to read, which decides
    // for both branches itself. A pull that completes before it returns is asked again only when a read asked for more
    // meanwhile, and in a loop here rather than from inside the pull, so a source that answers every pull at once
    // costs no native frame per pull.
    void callPullIfNeeded(JSC::JSGlobalObject*);
    // A pull whose promise fulfilled, or ReadableStream.from's asynchronous step: the source pulls again when a read
    // asked for more meanwhile or the pull enqueued something, so a source fills its queue up to its high-water mark,
    // while a pull that produced nothing is not repeated.
    void pullSettled(JSC::JSGlobalObject*);
    void pullFailed(JSC::JSGlobalObject*, JSC::JSValue reason);
    // The stream received a chunk; a pull in progress counts as having produced something.
    void notePullProgress()
    {
        if (m_pulling)
            m_pull_made_progress = true;
    }
    // The source part of [[CancelSteps]]: runs the source's cancel algorithm with `reason`, then clears the algorithms.
    // Returns the algorithm's result, a value or a promise, or the empty value with its exception pending.
    JSC::JSValue cancelSource(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue reason);

protected:
    JSColloReadableStreamController(JSC::VM& vm, JSC::Structure* structure)
        : Base(vm, structure)
    {
    }

    void finishCreation(JSC::VM&, JSColloReadableStream*);

private:
    // How one call into the source's pull algorithm ended.
    enum class PullOutcome : uint8_t {
        // The pull completed before it returned.
        Returned,
        // The pull completes later, or already completed, through pullSettled or pullFailed.
        Pending,
        // The pull failed and errored the stream, or a termination is pending.
        Ended,
    };

    bool shouldCallPull() const;
    PullOutcome callSourcePull(JSC::JSGlobalObject*);
    PullOutcome callJavaScriptPull(JSC::JSGlobalObject*);

    JSC::WriteBarrier<JSColloReadableStream> m_stream;
    JSC::WriteBarrier<JSC::Unknown> m_source;
    JSC::WriteBarrier<JSC::Unknown> m_pull;
    JSC::WriteBarrier<JSC::Unknown> m_cancel;
    SourceKind m_source_kind { SourceKind::JavaScript };
    bool m_starting { false };
    bool m_pulling { false };
    bool m_pull_again { false };
    bool m_pull_made_progress { false };
};

class JSColloReadableStreamDefaultController final : public JSColloReadableStreamController {
    using Base = JSColloReadableStreamController;

public:
    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* global_object, JSC::JSValue prototype)
    {
        return JSC::Structure::create(
            vm, global_object, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
    }

    static JSColloReadableStreamDefaultController* create(JSC::VM&, JSC::JSGlobalObject*, JSColloReadableStream*);

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    // The strategy's size callback, or undefined to count each chunk as 1.
    JSC::JSValue sizeCallback() const { return m_size.get(); }
    void setSizeCallback(JSC::VM& vm, JSC::JSValue size) { m_size.set(vm, this, size); }
    void clearSizeCallback() { m_size.setUndefined(); }

private:
    JSColloReadableStreamDefaultController(JSC::VM& vm, JSC::Structure* structure)
        : Base(vm, structure)
    {
    }

    void finishCreation(JSC::VM& vm, JSColloReadableStream* stream)
    {
        Base::finishCreation(vm, stream);
        m_size.set(vm, this, JSC::jsUndefined());
    }

    JSC::WriteBarrier<JSC::Unknown> m_size;
};

class JSColloReadableStreamBYOBRequest final : public JSC::JSNonFinalObject {
    using Base = JSC::JSNonFinalObject;

public:
    template <typename CellType, JSC::SubspaceAccess> static JSC::CompleteSubspace* subspaceFor(JSC::VM& vm)
    {
        static_assert(CellType::needsDestruction == JSC::DoesNotNeedDestruction);
        return &vm.cellSpace();
    }

    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* global_object, JSC::JSValue prototype)
    {
        return JSC::Structure::create(
            vm, global_object, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
    }

    static JSColloReadableStreamBYOBRequest* create(
        JSC::VM&, JSC::JSGlobalObject*, JSColloReadableStream*, JSC::JSArrayBufferView*);

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    JSColloReadableStream* stream() const { return m_stream.get(); }
    JSC::JSArrayBufferView* view() const { return m_view.get(); }
    bool active() const { return m_active; }
    // A request goes inactive when its read settles or a fresh request for the same read replaces it, and at once when
    // its read queues behind another BYOB read. respond() and respondWithNewView() on it then throw a TypeError.
    void invalidate()
    {
        m_active = false;
        m_view.clear();
    }

private:
    JSColloReadableStreamBYOBRequest(JSC::VM& vm, JSC::Structure* structure)
        : Base(vm, structure)
    {
    }

    void finishCreation(JSC::VM& vm, JSColloReadableStream* stream, JSC::JSArrayBufferView* view)
    {
        Base::finishCreation(vm);
        ASSERT(inherits(info()));
        m_stream.set(vm, this, stream);
        m_view.set(vm, this, view);
        m_active = true;
    }

    JSC::WriteBarrier<JSColloReadableStream> m_stream;
    JSC::WriteBarrier<JSC::JSArrayBufferView> m_view;
    bool m_active { false };
};

class JSColloReadableByteStreamController final : public JSColloReadableStreamController {
    using Base = JSColloReadableStreamController;

public:
    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* global_object, JSC::JSValue prototype)
    {
        return JSC::Structure::create(
            vm, global_object, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
    }

    static JSColloReadableByteStreamController* create(JSC::VM&, JSC::JSGlobalObject*, JSColloReadableStream*);

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    JSColloReadableStreamBYOBRequest* byobRequest() const { return m_byob_request.get(); }
    size_t autoAllocateChunkSize() const { return m_auto_allocate_chunk_size; }
    void setByobRequest(JSC::VM& vm, JSColloReadableStreamBYOBRequest* request)
    {
        m_byob_request.set(vm, this, request);
    }
    void clearByobRequest() { m_byob_request.clear(); }
    void setAutoAllocateChunkSize(size_t value) { m_auto_allocate_chunk_size = value; }

private:
    JSColloReadableByteStreamController(JSC::VM& vm, JSC::Structure* structure)
        : Base(vm, structure)
    {
    }

    JSC::WriteBarrier<JSColloReadableStreamBYOBRequest> m_byob_request;
    size_t m_auto_allocate_chunk_size { 0 };
};

class JSColloReadableStream final : public JSC::JSDestructibleObject {
    using Base = JSC::JSDestructibleObject;

    struct QueuedChunk {
        JSC::WriteBarrier<JSC::Unknown> value;
        // Summed into m_queue_total_size: the strategy's size of the chunk, or its byte length on a byte stream.
        double size { 0 };
        // Bytes at the front of a byte chunk already copied into BYOB reads.
        size_t byte_offset { 0 };

        template <typename Visitor> void visitEdges(Visitor& visitor) const { visitor.append(value); }
    };

    // A pending default read: the promise read() returned.
    struct ReadRequest {
        JSC::WriteBarrier<JSC::JSPromise> promise;

        template <typename Visitor> void visitEdges(Visitor& visitor) const { visitor.append(promise); }
    };

    struct ByobReadRequest {
        JSC::WriteBarrier<JSC::JSPromise> promise;
        // The view being filled, over a buffer transferred from the reader's view when the read was issued or
        // allocated for autoAllocateChunkSize.
        JSC::WriteBarrier<JSC::JSArrayBufferView> view;
        size_t bytes_filled { 0 };
        // In bytes: the read's min option times the view's element size, or 1 for an autoAllocateChunkSize read.
        size_t min_bytes { 1 };

        template <typename Visitor> void visitEdges(Visitor& visitor) const
        {
            visitor.append(promise);
            visitor.append(view);
        }
    };

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

    static JSColloReadableStream* create(JSC::VM& vm, Collo::GlobalObject* global_object)
    {
        return createWithStructure(vm, global_object->readableStreamStructure());
    }

    static JSColloReadableStream* createWithStructure(JSC::VM& vm, JSC::Structure* structure)
    {
        auto* object = new (NotNull, JSC::allocateCell<JSColloReadableStream>(vm)) JSColloReadableStream(vm, structure);
        object->finishCreation(vm);
        return object;
    }

    // A byte stream that owns `source`.
    static JSColloReadableStream* createWithNativeSource(
        JSC::VM& vm, Collo::GlobalObject* global_object, WTF::Ref<ReadableStreamNativeSource>&& source)
    {
        auto* object = new (NotNull, JSC::allocateCell<JSColloReadableStream>(vm))
            JSColloReadableStream(vm, global_object->readableStreamStructure());
        object->finishCreation(vm, WTF::move(source));
        return object;
    }

    static void destroy(JSCell* cell) { static_cast<JSColloReadableStream*>(cell)->~JSColloReadableStream(); }

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    bool locked() const { return !!m_reader.get(); }
    bool disturbed() const { return m_disturbed; }
    StreamState state() const { return m_state; }
    JSC::JSValue storedError() const { return m_stored_error.get(); }
    JSColloReadableStreamDefaultReader* reader() const { return m_reader.get(); }
    JSColloReadableStreamController* controller() const { return m_controller.get(); }
    JSColloReadableStreamDefaultController* defaultController() const;
    JSColloReadableByteStreamController* byteController() const;
    double desiredSize() const { return m_high_water_mark - m_queue_total_size; }
    bool isByteStream() const { return m_is_byte_stream; }
    bool hasNativeSource() const { return !!m_native_source; }
    bool closeRequested() const { return m_close_requested; }
    bool hasPendingReadRequests() const { return !m_read_requests.isEmpty(); }
    bool hasPendingByobReadRequests() const { return !m_byob_read_requests.isEmpty(); }
    bool queueEmpty() const { return m_queue.isEmpty(); }
    double queuedSize() const { return m_queue_total_size; }
    bool firstByobReadRequestHasPartialElement() const;
    // The bytes the first pending BYOB read still has room for, at most `cap`; 0 without one.
    size_t pendingByobReadPullByteLength(size_t cap) const;
    // pipeTo sets this while it drives the stream, around its own reads and while its destination is full, so the
    // stream pulls and a tee reads ahead for it only to serve a pending read.
    void setPipeBackpressure(bool value) { m_pipe_backpressure = value; }
    bool pipeBackpressure() const { return m_pipe_backpressure; }
    // Whether a tee may read ahead into this branch: it is readable and a read waits, or it is below its high-water
    // mark with no close requested and no pipe holding it back.
    bool wantsTeeChunk() const;
    // The clone budget this stream's tees count against, shared with the streams and bodies of its clone tree.
    WTF::RefPtr<StreamCloneBudget>& cloneBudget() { return m_clone_budget; }

    void setHighWaterMark(double value) { m_high_water_mark = value; }
    void setByteStream(bool value) { m_is_byte_stream = value; }
    void setController(JSC::VM& vm, JSColloReadableStreamController* controller)
    {
        m_controller.set(vm, this, controller);
    }
    void lock(JSC::VM& vm, JSColloReadableStreamDefaultReader* reader) { m_reader.set(vm, this, reader); }
    void unlock() { m_reader.clear(); }
    void markDisturbed() { m_disturbed = true; }
    // ReadableByteStreamControllerClose with BYOB reads pending: the close completes when the source responds.
    void requestClose() { m_close_requested = true; }

    // ReadableStreamDefaultControllerEnqueue. A size callback that throws or returns an invalid size errors the stream
    // and rethrows. Returns false with an exception pending.
    bool enqueue(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue chunk);
    // ReadableByteStreamControllerEnqueue. Returns false with an exception pending.
    bool enqueueByteChunk(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSArrayBufferView*);
    bool settleByobRequestWithBytes(JSC::JSGlobalObject*, JSC::ThrowScope&, JSColloReadableStreamBYOBRequest*, size_t);
    bool settleByobRequestWithView(
        JSC::JSGlobalObject*, JSC::ThrowScope&, JSColloReadableStreamBYOBRequest*, JSC::JSArrayBufferView*);
    // ReadableStreamDefaultReaderRead and ReadableStreamBYOBReaderRead: a promise for the next {value, done} result.
    JSC::EncodedJSValue read(JSC::JSGlobalObject*, JSC::ThrowScope&);
    JSC::EncodedJSValue readInto(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSArrayBufferView*, size_t min_bytes);
    // ReadableStreamCancel: the stream closes, its pending BYOB reads resolve done, and then the source's cancel
    // algorithm runs. Returns a promise that fulfills with undefined once that algorithm's result does.
    JSC::EncodedJSValue cancel(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue reason);
    // The controller's close: with chunks still queued it only records the request, which the read that empties the
    // queue completes. A pending BYOB read holding part of an element errors the stream instead.
    void close(JSC::JSGlobalObject*);
    // ReadableStream{Default,Byte}ControllerError: drops the queue and the source, then rejects the reader's closed
    // promise and every pending read with `error`.
    void error(JSC::JSGlobalObject*, JSC::JSValue error);
    // Rejects every pending BYOB read with the value. Returns false when a termination is pending.
    bool rejectByobReadRequests(JSC::JSGlobalObject*, JSC::JSValue);
    // Rejects every pending default read with `error`. Returns false when a termination is pending.
    bool rejectReadRequests(JSC::JSGlobalObject*, JSC::JSValue error);
    // Asks the native source or the controller for more, whichever the stream has.
    void pullIfNeeded(JSC::JSGlobalObject*);
    // Appends the remaining bytes of a stream backed by a native source to the output in one step, keeping the output
    // within max_size bytes in total.
    ReadableStreamDrainResult drainNativeBytes(WTF::Vector<uint8_t>& out, size_t max_size);
    // The native source while the stream is as it was created: readable, never read, locked or pulled, with nothing
    // queued and no read pending, so the source still holds every byte. Null in any other state, and for a stream
    // without a native source.
    ReadableStreamNativeSource* untouchedNativeSource() const;
    // Leaves the stream as a host reader that read it to its end would: locked by `reader`, a reader of the host's
    // own that `reader`'s creation did not lock, disturbed and closed, with its native source released. Call it only
    // while untouchedNativeSource() returns the source and once the host has taken every byte the source held.
    void finishHostRead(JSC::JSGlobalObject*, JSColloReadableStreamDefaultReader* reader);
    void callNativePullIfNeeded(JSC::JSGlobalObject*);
    // The pending result of a native pull fulfilled with `result` or rejected with `reason`.
    void finishNativePull(JSC::JSGlobalObject*, JSC::JSValue result);
    void rejectNativePull(JSC::JSGlobalObject*, JSC::JSValue reason);
    // Moves the native source's unread remainder into two new sources (ReadableStreamNativeSource::tee) when the
    // source holds every unread byte: the stream is readable, has nothing queued and no pull in flight. Leaves both
    // out-parameters null, and the stream untouched, when the stream is in any other state or the source cannot split;
    // the tee then reads the stream. Returns false with an exception pending when the source threw.
    bool trySplitNativeSource(JSC::JSGlobalObject*, JSC::ThrowScope&,
        WTF::RefPtr<ReadableStreamNativeSource>& out_first, WTF::RefPtr<ReadableStreamNativeSource>& out_second);

private:
    JSColloReadableStream(JSC::VM& vm, JSC::Structure* structure)
        : Base(vm, structure)
    {
    }

    // The sweep runs the destructor after the last visit, so a source still attached is released here.
    ~JSColloReadableStream()
    {
        if (auto* source = m_native_source.get())
            source->release();
    }

    void finishCreation(JSC::VM& vm, WTF::RefPtr<ReadableStreamNativeSource>&& native_source = nullptr)
    {
        Base::finishCreation(vm);
        ASSERT(inherits(info()));
        if (native_source) {
            m_native_source.set(vm, this, WTF::move(native_source));
            m_is_byte_stream = true;
        }
    }

    // The source is released after CellNativeRef dropped it, because release() may call into Zig.
    void releaseNativeSource()
    {
        auto source = m_native_source.take(this);
        m_native_pulling = false;
        if (source)
            source->release();
    }

    // ReadableStreamClose: the stream leaves the readable state for good. Resolves the reader's closed promise before
    // the pending default reads, in the standard's order. Returns false when a termination is pending. It leaves the
    // native source attached, so cancel can call the source's cancel after closing; the caller releases it.
    bool closeStream(JSC::JSGlobalObject*);
    // The end of the controller's close once the queue is empty: clears the algorithms, releases the native source,
    // closes the stream and ends every pending BYOB read with the bytes it holds.
    void finishClose(JSC::JSGlobalObject*);
    // After a read took a chunk: completes a requested close once the queue is empty, otherwise asks for more.
    void afterDequeue(JSC::JSGlobalObject*);
    bool enqueueWithSize(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue chunk, double size);

    void clearQueue()
    {
        m_queue.clear(this);
        m_queue_total_size = 0;
    }

    bool dequeue(JSC::JSValue& value);
    bool firstQueuedByteSpan(std::span<const uint8_t>& out);
    bool dequeueByteValue(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue& value);
    bool consumeFirstQueuedByteSpan(size_t bytes);
    void subtractQueueSize(double size)
    {
        m_queue_total_size = m_queue_total_size > size ? m_queue_total_size - size : 0;
    }

    bool hasReadRequests() const { return !m_read_requests.isEmpty(); }
    bool hasByobReadRequests() const { return !m_byob_read_requests.isEmpty(); }
    bool appendReadRequest(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSPromise*);
    ReadRequest takeFirstReadRequest() { return m_read_requests.takeFirst(this); }
    // Both return false when a termination is pending.
    bool fulfillReadRequest(JSC::JSGlobalObject*, JSC::JSValue chunk, bool done);
    bool settleReadRequest(ReadRequest&& request, JSC::JSValue value, bool is_rejection)
    {
        return Collo::settlePromise(request.promise.get(), value, is_rejection);
    }

    bool appendByobReadRequest(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSPromise*, JSC::JSArrayBufferView*,
        JSColloReadableStreamBYOBRequest*, size_t min_bytes);
    bool pushFrontQueuedByteChunk(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSArrayBufferView*);
    bool appendQueuedByteChunk(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSUint8Array*, size_t byte_offset);
    ByobReadRequest takeFirstByobReadRequest() { return m_byob_read_requests.takeFirst(this); }
    // Returns false when a termination is pending.
    bool settleByobReadRequest(ByobReadRequest&&, JSC::JSValue, bool is_rejection);
    bool refreshFirstByobReadRequest(JSC::JSGlobalObject*, JSC::ThrowScope&);
    bool refreshFirstByobReadRequestAndPullIfNeeded(JSC::JSGlobalObject*, JSC::ThrowScope&);
    bool settleFirstByobReadRequestWithFilledBytes(JSC::JSGlobalObject*, JSC::ThrowScope&, bool done);
    bool rejectFirstByobReadRequestWithUnavailableView(JSC::JSGlobalObject*, JSC::ThrowScope&);
    bool firstByobReadRequestIsReady() const;
    bool fulfillFirstByobReadRequestWithChunk(
        JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSArrayBufferView*, size_t offset);
    bool drainQueuedBytesIntoByobRequests(JSC::JSGlobalObject*, JSC::ThrowScope&);
    // ReadableStreamCancel's close steps for a BYOB reader: every pending BYOB read resolves done with no value.
    bool closeByobReadRequestsForCancel(JSC::JSGlobalObject*);
    // A chunk a native source produced, delivered to the first pending read or queued. Errors the stream itself when
    // the chunk is unusable; returns false only when a termination is pending.
    bool deliverNativeChunk(JSC::JSGlobalObject*, JSC::JSValue chunk);
    void endNativePull(JSC::JSGlobalObject*, ReadableStreamPull);

    StreamState m_state { StreamState::Readable };
    JSC::WriteBarrier<JSC::Unknown> m_stored_error;
    JSC::WriteBarrier<JSColloReadableStreamDefaultReader> m_reader;
    JSC::WriteBarrier<JSColloReadableStreamController> m_controller;
    Collo::CellEdgeList<QueuedChunk> m_queue;
    Collo::CellEdgeList<ReadRequest> m_read_requests;
    Collo::CellEdgeList<ByobReadRequest> m_byob_read_requests;
    Collo::CellNativeRef<ReadableStreamNativeSource> m_native_source;
    // Native data, not a cell edge: the budget object holds no cell.
    WTF::RefPtr<StreamCloneBudget> m_clone_budget;
    double m_queue_total_size { 0 };
    double m_high_water_mark { 1 };
    bool m_disturbed { false };
    bool m_close_requested { false };
    bool m_native_pulling { false };
    bool m_pipe_backpressure { false };
    bool m_is_byte_stream { false };
};

class JSColloReadableStreamDefaultReader final : public JSC::JSNonFinalObject {
    using Base = JSC::JSNonFinalObject;

public:
    template <typename CellType, JSC::SubspaceAccess> static JSC::CompleteSubspace* subspaceFor(JSC::VM& vm)
    {
        static_assert(CellType::needsDestruction == JSC::DoesNotNeedDestruction);
        return &vm.cellSpace();
    }

    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* global_object, JSC::JSValue prototype)
    {
        return JSC::Structure::create(
            vm, global_object, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
    }

    // ReadableStreamReaderGenericInitialize; the caller locks the stream to the reader. Returns null when a
    // termination is pending.
    static JSColloReadableStreamDefaultReader* create(JSC::VM&, JSC::JSGlobalObject*, JSColloReadableStream*);

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    JSColloReadableStream* stream() const { return m_stream.get(); }
    JSC::JSValue closedPromise() const { return m_closed_promise.get(); }
    // ReadableStreamDefaultReaderRelease: closed ends rejected with a TypeError and handled, a pending one rejected in
    // place, and every pending read is rejected.
    void release(JSC::JSGlobalObject*);
    // Each returns false when a termination is pending. A rejection of closed is always marked handled
    // (ReadableStreamError).
    bool resolveClosed() { return Collo::settlePromise(m_closed_promise.get(), JSC::jsUndefined(), false); }
    bool rejectClosed(JSC::JSValue reason)
    {
        auto* promise = m_closed_promise.get();
        if (promiseIsPending(promise))
            promise->markAsHandled();
        return Collo::settlePromise(promise, reason, true);
    }

private:
    JSColloReadableStreamDefaultReader(JSC::VM& vm, JSC::Structure* structure)
        : Base(vm, structure)
    {
    }

    bool finishCreation(JSC::VM&, JSC::JSGlobalObject*, JSColloReadableStream*);

    JSC::WriteBarrier<JSColloReadableStream> m_stream;
    JSC::WriteBarrier<JSC::JSPromise> m_closed_promise;
};

// A BYOB reader locks its stream through an internal default reader, which also owns the closed promise, so the
// stream's reader() is that default reader.
class JSColloReadableStreamBYOBReader final : public JSC::JSNonFinalObject {
    using Base = JSC::JSNonFinalObject;

public:
    template <typename CellType, JSC::SubspaceAccess> static JSC::CompleteSubspace* subspaceFor(JSC::VM& vm)
    {
        static_assert(CellType::needsDestruction == JSC::DoesNotNeedDestruction);
        return &vm.cellSpace();
    }

    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* global_object, JSC::JSValue prototype)
    {
        return JSC::Structure::create(
            vm, global_object, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
    }

    static JSColloReadableStreamBYOBReader* create(JSC::VM&, JSC::JSGlobalObject*, JSColloReadableStreamDefaultReader*);

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    JSColloReadableStream* stream() const
    {
        auto* reader = m_default_reader.get();
        return reader ? reader->stream() : nullptr;
    }
    JSC::JSValue closedPromise() const { return m_closed_promise.get(); }
    void release(JSC::JSGlobalObject*);

private:
    JSColloReadableStreamBYOBReader(JSC::VM& vm, JSC::Structure* structure)
        : Base(vm, structure)
    {
    }

    void finishCreation(JSC::VM& vm, JSColloReadableStreamDefaultReader* default_reader)
    {
        Base::finishCreation(vm);
        ASSERT(inherits(info()));
        m_default_reader.set(vm, this, default_reader);
        m_closed_promise.set(vm, this, default_reader->closedPromise());
    }

    JSC::WriteBarrier<JSColloReadableStreamDefaultReader> m_default_reader;
    JSC::WriteBarrier<JSC::Unknown> m_closed_promise;
};

class JSColloReadableStreamAsyncIterator final : public JSC::JSNonFinalObject {
    using Base = JSC::JSNonFinalObject;

public:
    template <typename CellType, JSC::SubspaceAccess> static JSC::CompleteSubspace* subspaceFor(JSC::VM& vm)
    {
        static_assert(CellType::needsDestruction == JSC::DoesNotNeedDestruction);
        return &vm.cellSpace();
    }

    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* global_object, JSC::JSValue prototype)
    {
        return JSC::Structure::create(
            vm, global_object, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
    }

    static JSColloReadableStreamAsyncIterator* create(
        JSC::VM&, Collo::GlobalObject*, JSColloReadableStreamDefaultReader*, bool prevent_cancel);

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    JSColloReadableStreamDefaultReader* reader() const { return m_reader.get(); }
    bool preventCancel() const { return m_prevent_cancel; }
    // Releases the reader's lock and forgets the reader, once the iterator is done or returned.
    void releaseReader(JSC::JSGlobalObject*);
    // The promise of the last return() while it is pending, so a later next() or return() resolves after it.
    JSC::JSPromise* pendingReturn() const
    {
        auto* promise = m_return_promise.get();
        return promiseIsPending(promise) ? promise : nullptr;
    }
    void setReturnPromise(JSC::VM& vm, JSC::JSPromise* promise) { m_return_promise.set(vm, this, promise); }

private:
    JSColloReadableStreamAsyncIterator(JSC::VM& vm, JSC::Structure* structure, bool prevent_cancel)
        : Base(vm, structure)
        , m_prevent_cancel(prevent_cancel)
    {
    }

    void finishCreation(JSC::VM& vm, JSColloReadableStreamDefaultReader* reader)
    {
        Base::finishCreation(vm);
        ASSERT(inherits(info()));
        m_reader.set(vm, this, reader);
    }

    JSC::WriteBarrier<JSColloReadableStreamDefaultReader> m_reader;
    JSC::WriteBarrier<JSC::JSPromise> m_return_promise;
    bool m_prevent_cancel { false };
};

// The state of ReadableStreamDefaultTee for a stream without a native source, which both branches' controllers hold
// as their source. It reads the original one chunk at a time while a branch asks for one, and enqueues each chunk into
// both readable branches, copying a byte chunk for each. The reaction on its reader's closed promise also holds it,
// so an error of the original reaches the branches with no read in flight. finish() ends the tee: it unlinks both
// branches, releases the original's reader and settles the cancel promise both branches' cancels return.
class JSColloReadableStreamTeeState final : public JSC::JSNonFinalObject {
    using Base = JSC::JSNonFinalObject;

public:
    template <typename CellType, JSC::SubspaceAccess> static JSC::CompleteSubspace* subspaceFor(JSC::VM& vm)
    {
        static_assert(CellType::needsDestruction == JSC::DoesNotNeedDestruction);
        return &vm.cellSpace();
    }

    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* global_object, JSC::JSValue prototype)
    {
        return JSC::Structure::create(
            vm, global_object, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
    }

    static JSColloReadableStreamTeeState* create(JSC::VM&, Collo::GlobalObject*, JSColloReadableStream* original,
        JSColloReadableStream*, JSColloReadableStream*);

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    // Reads the original when a branch wants a chunk and no read is in flight.
    void pump(JSC::JSGlobalObject*);
    void readFulfilled(JSC::JSGlobalObject*, JSC::JSValue result);
    void readRejected(JSC::JSGlobalObject*, JSC::JSValue reason);
    // Errors both branches with `error` and ends the tee: what the original's error does once its reader's closed
    // promise rejects, and what a read the tee cannot issue or a chunk it cannot hand to both branches does.
    void errorBranches(JSC::JSGlobalObject*, JSC::JSValue error);
    // A branch's cancel algorithm. Returns the cancel promise both branches share: once both are canceled, the
    // original is canceled with both reasons and the promise follows that cancel; the original closing or erroring
    // first resolves it with undefined. Returns the empty value with an exception pending.
    JSC::JSValue cancelBranch(
        JSC::JSGlobalObject*, JSC::ThrowScope&, JSColloReadableStream* branch, JSC::JSValue reason);

private:
    JSColloReadableStreamTeeState(JSC::VM& vm, JSC::Structure* structure)
        : Base(vm, structure)
    {
    }

    void finishCreation(JSC::VM&, JSColloReadableStream*, JSColloReadableStream*, JSColloReadableStream*);
    bool shouldPull() const;
    size_t pendingByobReadSize() const;
    // Settles the cancel promise, if a branch's cancel created one, with `cancel_value`.
    void finish(JSC::JSGlobalObject*, JSC::JSValue cancel_value);
    void closeBranches(JSC::JSGlobalObject*);

    JSC::WriteBarrier<JSColloReadableStream> m_original;
    JSC::WriteBarrier<JSColloReadableStream> m_branch_a;
    JSC::WriteBarrier<JSColloReadableStream> m_branch_b;
    JSC::WriteBarrier<JSC::Unknown> m_reason_a;
    JSC::WriteBarrier<JSC::Unknown> m_reason_b;
    // Created by the first branch cancel, so a tee whose branches are never canceled allocates none.
    JSC::WriteBarrier<JSC::JSPromise> m_cancel_promise;
    // True from just before the tee reads the original until the read's chunk has reached both branches.
    bool m_reading { false };
    bool m_canceled_a { false };
    bool m_canceled_b { false };
};

// The state of ReadableStream.from, which the stream's controller holds as its source: the iterator, its next method,
// whether it is async, and the controller. clear() marks it done and drops its references once the iterator is
// exhausted, fails or is canceled.
class JSColloReadableStreamFromState final : public JSC::JSNonFinalObject {
    using Base = JSC::JSNonFinalObject;

public:
    template <typename CellType, JSC::SubspaceAccess> static JSC::CompleteSubspace* subspaceFor(JSC::VM& vm)
    {
        static_assert(CellType::needsDestruction == JSC::DoesNotNeedDestruction);
        return &vm.cellSpace();
    }

    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* global_object, JSC::JSValue prototype)
    {
        return JSC::Structure::create(
            vm, global_object, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
    }

    static JSColloReadableStreamFromState* create(JSC::VM&, Collo::GlobalObject*, JSC::JSObject* iterator,
        JSC::JSValue next, bool is_async, JSColloReadableStreamDefaultController*);

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    // The pull algorithm: asks the iterator for its next result. Completes through the controller's pullSettled or
    // pullFailed, at once or when the reaction it registers runs.
    void pull(JSC::JSGlobalObject*);
    void nextFulfilled(JSC::JSGlobalObject*, JSC::JSValue iterator_result);
    void nextRejected(JSC::JSGlobalObject*, JSC::JSValue reason);
    void valueFulfilled(JSC::JSGlobalObject*, JSC::JSValue value);
    void valueRejected(JSC::JSGlobalObject*, JSC::JSValue reason);
    // The cancel algorithm: calls the iterator's return method with `reason`. Returns a promise, undefined when the
    // iterator has no return method, or the empty value with the exception pending.
    JSC::JSValue cancel(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue reason);

private:
    JSColloReadableStreamFromState(JSC::VM& vm, JSC::Structure* structure, bool is_async)
        : Base(vm, structure)
        , m_is_async(is_async)
    {
    }

    void finishCreation(JSC::VM&, JSC::JSObject* iterator, JSC::JSValue next, JSColloReadableStreamDefaultController*);
    // Handles one iterator result: closes the stream on done, otherwise enqueues the value. A sync iterator's value is
    // awaited first, done or not, as ECMA-262's AsyncFromSyncIteratorContinuation awaits it.
    void processIteratorResult(JSC::JSGlobalObject*, JSC::JSValue result, bool await_value);
    // Marks the iterator done, closes the stream and ends the pull.
    void finishIteration(JSC::JSGlobalObject*);
    // IteratorClose with a throw completion: calls the iterator's return method, if it has one, and ignores whatever
    // the lookup or the call does, so the error that caused the close stays the stream's error. Returns false when a
    // termination is pending.
    bool closeIteratorKeepingError(JSC::JSGlobalObject*);
    // Ends the pull with `reason`, which errors the stream.
    void fail(JSC::JSGlobalObject*, JSC::JSValue reason);
    void finishPull(JSC::JSGlobalObject*);
    void clear();

    JSC::WriteBarrier<JSC::Unknown> m_iterator;
    JSC::WriteBarrier<JSC::Unknown> m_next;
    JSC::WriteBarrier<JSColloReadableStreamDefaultController> m_controller;
    bool m_is_async { false };
    bool m_done { false };
    // The value being awaited came with done true: its fulfillment closes the stream, and its rejection errors the
    // stream without closing the iterator. At most one pull is in flight, so one flag covers it.
    bool m_value_ends_iteration { false };
};

// One Body method's read of a whole ReadableStream (readable_stream_consume.cpp): the stream, locked for good by a
// reader of the bridge's own, the promise the method returned, and the bytes read so far. The pending read's reaction
// is the only thing that holds the consumer, so a consumption whose stream nothing can feed is collected with it. The
// buffered bytes count as the consumer's own memory: their growth is reported to the collector as it happens, and
// visitChildren reports their current size, so an abandoned consumption paces collection like the chunks it copied.
class JSColloBodyConsumer final : public JSC::JSDestructibleObject {
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

    // Locks `stream` with a reader of its own and returns a consumer that resolves `promise` with the whole body.
    // Returns null when a termination is pending.
    static JSColloBodyConsumer* create(JSC::VM&, Collo::GlobalObject*, JSColloReadableStream*, JSC::JSPromise*,
        ReadableStreamBodyConsumer, WTF::String content_type);
    static void destroy(JSCell* cell) { static_cast<JSColloBodyConsumer*>(cell)->~JSColloBodyConsumer(); }

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    // Reads the next chunk, until the stream ends or fails.
    void readNext(JSC::JSGlobalObject*);
    void readFulfilled(JSC::JSGlobalObject*, JSC::JSValue result);
    void readRejected(JSC::JSGlobalObject*, JSC::JSValue reason);

private:
    JSColloBodyConsumer(
        JSC::VM& vm, JSC::Structure* structure, ReadableStreamBodyConsumer kind, WTF::String&& content_type)
        : Base(vm, structure)
        , m_content_type(WTF::move(content_type))
        , m_kind(kind)
    {
    }

    ~JSColloBodyConsumer() = default;

    void finishCreation(JSC::VM&, JSColloReadableStream*, JSColloReadableStreamDefaultReader*, JSC::JSPromise*);
    // Takes one {value, done} result. Returns true when the next chunk should be read; otherwise the consumption has
    // settled, or a termination is pending.
    bool takeReadResult(JSC::JSGlobalObject*, JSC::JSValue result);
    // Both forget the stream, leaving it locked, then settle the promise; they run at most once between them.
    void resolveWithBytes(JSC::JSGlobalObject*);
    void reject(JSC::JSGlobalObject*, JSC::JSValue reason);
    void forgetStream();
    // Stores m_bytes's capacity for visitChildren and reports any growth past what was reported before.
    void noteBufferedBytes();

    JSC::WriteBarrier<JSColloReadableStream> m_stream;
    JSC::WriteBarrier<JSColloReadableStreamDefaultReader> m_reader;
    JSC::WriteBarrier<JSC::JSPromise> m_promise;
    // The bytes read so far, at most WebApiMaterializedBodyBytesMax.
    WTF::Vector<uint8_t> m_bytes;
    // m_bytes's capacity, for visitChildren, which runs on collector threads and reads only this.
    std::atomic<size_t> m_bytes_cost { 0 };
    // The most this cell has reported as allocated. Only growth past it is reported again, so bytes handed to the
    // converted body and then cleared do not count as new allocation.
    size_t m_bytes_cost_reported { 0 };
    WTF::String m_content_type;
    ReadableStreamBodyConsumer m_kind;
};

JSColloReadableStream* requireReadableStream(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue);

} // namespace Collo::HostFunctions

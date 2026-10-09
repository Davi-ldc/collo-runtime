// ClassInfo and visitChildren of the ReadableStream cells declared in readable_stream_private.h. visitChildren runs on
// collector threads concurrently with the VM thread and must visit every WriteBarrier field of its class, including
// those inside the stream's vectors: a field missed here leaves its target to be collected while still referenced.

#include "host_functions/webapi/streams/readable_stream_private.h"

namespace Collo::HostFunctions {

const JSC::ClassInfo JSColloReadableStream::s_info
    = { "ReadableStream"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloReadableStream) };
const JSC::ClassInfo JSColloReadableStreamDefaultReader::s_info = { "ReadableStreamDefaultReader"_s, &Base::s_info,
    nullptr, nullptr, CREATE_METHOD_TABLE(JSColloReadableStreamDefaultReader) };
const JSC::ClassInfo JSColloReadableStreamDefaultController::s_info = { "ReadableStreamDefaultController"_s,
    &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloReadableStreamDefaultController) };
const JSC::ClassInfo JSColloReadableStreamBYOBReader::s_info = { "ReadableStreamBYOBReader"_s, &Base::s_info, nullptr,
    nullptr, CREATE_METHOD_TABLE(JSColloReadableStreamBYOBReader) };
const JSC::ClassInfo JSColloReadableStreamBYOBRequest::s_info = { "ReadableStreamBYOBRequest"_s, &Base::s_info, nullptr,
    nullptr, CREATE_METHOD_TABLE(JSColloReadableStreamBYOBRequest) };
const JSC::ClassInfo JSColloReadableByteStreamController::s_info = { "ReadableByteStreamController"_s, &Base::s_info,
    nullptr, nullptr, CREATE_METHOD_TABLE(JSColloReadableByteStreamController) };
const JSC::ClassInfo JSColloReadableStreamAsyncIterator::s_info = { "ReadableStreamAsyncIterator"_s, &Base::s_info,
    nullptr, nullptr, CREATE_METHOD_TABLE(JSColloReadableStreamAsyncIterator) };
template <typename Visitor> void JSColloReadableStream::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloReadableStream*>(cell);
    ASSERT_GC_OBJECT_INHERITS(this_object, info());
    Base::visitChildren(this_object, visitor);
    visitor.append(this_object->m_stored_error);
    visitor.append(this_object->m_reader);
    visitor.append(this_object->m_controller);
    visitor.append(this_object->m_byte_controller);
    visitor.append(this_object->m_default_tee_state);
    visitor.append(this_object->m_native_pull_fulfilled);
    visitor.append(this_object->m_native_pull_rejected);
    // The cell lock keeps the buffers of the queue and both request vectors in place while the marker walks them, and
    // keeps the native source alive while it is visited. The VM thread takes it around every change that moves or
    // frees those buffers and around detaching the source.
    WTF::Locker locker { this_object->cellLock() };
    if (auto* native_source = this_object->m_native_source.get())
        native_source->visitAggregate(visitor);
    for (size_t index = this_object->m_queue_start; index < this_object->m_queue.size(); ++index)
        visitor.append(this_object->m_queue[index].value);
    for (size_t index = this_object->m_read_request_start; index < this_object->m_read_requests.size(); ++index) {
        visitor.append(this_object->m_read_requests[index].promise);
        visitor.append(this_object->m_read_requests[index].resolve);
        visitor.append(this_object->m_read_requests[index].reject);
    }
    for (size_t index = this_object->m_byob_read_request_start; index < this_object->m_byob_read_requests.size();
        ++index) {
        visitor.append(this_object->m_byob_read_requests[index].promise);
        visitor.append(this_object->m_byob_read_requests[index].view);
    }
}

template <typename Visitor> void JSColloReadableStreamDefaultReader::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloReadableStreamDefaultReader*>(cell);
    ASSERT_GC_OBJECT_INHERITS(this_object, info());
    Base::visitChildren(this_object, visitor);
    visitor.append(this_object->m_stream);
    visitor.append(this_object->m_closed_promise);
}

template <typename Visitor>
void JSColloReadableStreamDefaultController::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloReadableStreamDefaultController*>(cell);
    ASSERT_GC_OBJECT_INHERITS(this_object, info());
    Base::visitChildren(this_object, visitor);
    visitor.append(this_object->m_stream);
    visitor.append(this_object->m_pull);
    visitor.append(this_object->m_cancel);
    visitor.append(this_object->m_size);
    visitor.append(this_object->m_underlying_source);
    visitor.append(this_object->m_pull_fulfilled);
    visitor.append(this_object->m_pull_rejected);
}

template <typename Visitor> void JSColloReadableStreamBYOBReader::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloReadableStreamBYOBReader*>(cell);
    ASSERT_GC_OBJECT_INHERITS(this_object, info());
    Base::visitChildren(this_object, visitor);
    visitor.append(this_object->m_default_reader);
    visitor.append(this_object->m_closed_promise);
}

template <typename Visitor> void JSColloReadableStreamBYOBRequest::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloReadableStreamBYOBRequest*>(cell);
    ASSERT_GC_OBJECT_INHERITS(this_object, info());
    Base::visitChildren(this_object, visitor);
    visitor.append(this_object->m_stream);
    visitor.append(this_object->m_view);
}

template <typename Visitor> void JSColloReadableByteStreamController::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloReadableByteStreamController*>(cell);
    ASSERT_GC_OBJECT_INHERITS(this_object, info());
    Base::visitChildren(this_object, visitor);
    visitor.append(this_object->m_stream);
    visitor.append(this_object->m_pull);
    visitor.append(this_object->m_cancel);
    visitor.append(this_object->m_underlying_source);
    visitor.append(this_object->m_byob_request);
    visitor.append(this_object->m_pull_fulfilled);
    visitor.append(this_object->m_pull_rejected);
}

template <typename Visitor> void JSColloReadableStreamAsyncIterator::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloReadableStreamAsyncIterator*>(cell);
    ASSERT_GC_OBJECT_INHERITS(this_object, info());
    Base::visitChildren(this_object, visitor);
    visitor.append(this_object->m_reader);
    visitor.append(this_object->m_next_fulfilled);
    visitor.append(this_object->m_next_rejected);
    visitor.append(this_object->m_return_pending);
}
DEFINE_VISIT_CHILDREN(JSColloReadableStream);
DEFINE_VISIT_CHILDREN(JSColloReadableStreamDefaultReader);
DEFINE_VISIT_CHILDREN(JSColloReadableStreamDefaultController);
DEFINE_VISIT_CHILDREN(JSColloReadableStreamBYOBReader);
DEFINE_VISIT_CHILDREN(JSColloReadableStreamBYOBRequest);
DEFINE_VISIT_CHILDREN(JSColloReadableByteStreamController);
DEFINE_VISIT_CHILDREN(JSColloReadableStreamAsyncIterator);

} // namespace Collo::HostFunctions

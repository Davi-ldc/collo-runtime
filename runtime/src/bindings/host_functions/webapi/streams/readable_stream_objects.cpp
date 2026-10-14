// ClassInfo and visitChildren of the readable family's cells declared in readable_stream_private.h. visitChildren runs
// on collector threads concurrently with the VM thread and must visit every WriteBarrier field of its class and every
// list and native source it owns: a field missed here leaves its target to be collected while still referenced.

#include "host_functions/webapi/streams/readable_stream_private.h"

namespace Collo::HostFunctions {

const JSC::ClassInfo JSColloReadableStream::s_info
    = { "ReadableStream"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloReadableStream) };
const JSC::ClassInfo JSColloReadableStreamController::s_info = { "ReadableStreamController"_s, &Base::s_info, nullptr,
    nullptr, CREATE_METHOD_TABLE(JSColloReadableStreamController) };
const JSC::ClassInfo JSColloReadableStreamDefaultController::s_info = { "ReadableStreamDefaultController"_s,
    &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloReadableStreamDefaultController) };
const JSC::ClassInfo JSColloReadableByteStreamController::s_info = { "ReadableByteStreamController"_s, &Base::s_info,
    nullptr, nullptr, CREATE_METHOD_TABLE(JSColloReadableByteStreamController) };
const JSC::ClassInfo JSColloReadableStreamBYOBRequest::s_info = { "ReadableStreamBYOBRequest"_s, &Base::s_info, nullptr,
    nullptr, CREATE_METHOD_TABLE(JSColloReadableStreamBYOBRequest) };
const JSC::ClassInfo JSColloReadableStreamDefaultReader::s_info = { "ReadableStreamDefaultReader"_s, &Base::s_info,
    nullptr, nullptr, CREATE_METHOD_TABLE(JSColloReadableStreamDefaultReader) };
const JSC::ClassInfo JSColloReadableStreamBYOBReader::s_info = { "ReadableStreamBYOBReader"_s, &Base::s_info, nullptr,
    nullptr, CREATE_METHOD_TABLE(JSColloReadableStreamBYOBReader) };
const JSC::ClassInfo JSColloReadableStreamAsyncIterator::s_info = { "ReadableStreamAsyncIterator"_s, &Base::s_info,
    nullptr, nullptr, CREATE_METHOD_TABLE(JSColloReadableStreamAsyncIterator) };
const JSC::ClassInfo JSColloReadableStreamTeeState::s_info = { "ReadableStreamTeeState"_s, &Base::s_info, nullptr,
    nullptr, CREATE_METHOD_TABLE(JSColloReadableStreamTeeState) };
const JSC::ClassInfo JSColloReadableStreamFromState::s_info = { "ReadableStreamFromState"_s, &Base::s_info, nullptr,
    nullptr, CREATE_METHOD_TABLE(JSColloReadableStreamFromState) };
const JSC::ClassInfo JSColloBodyConsumer::s_info
    = { "BodyConsumer"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloBodyConsumer) };

template <typename Visitor> void JSColloReadableStream::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloReadableStream*>(cell);
    ASSERT_GC_OBJECT_INHERITS(this_object, info());
    Base::visitChildren(this_object, visitor);
    visitor.append(this_object->m_stored_error);
    visitor.append(this_object->m_reader);
    visitor.append(this_object->m_controller);
    this_object->m_native_source.visit(this_object, visitor);
    this_object->m_queue.visit(this_object, visitor);
    this_object->m_read_requests.visit(this_object, visitor);
    this_object->m_byob_read_requests.visit(this_object, visitor);
}

template <typename Visitor> void JSColloReadableStreamController::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloReadableStreamController*>(cell);
    ASSERT_GC_OBJECT_INHERITS(this_object, info());
    Base::visitChildren(this_object, visitor);
    visitor.append(this_object->m_stream);
    visitor.append(this_object->m_source);
    visitor.append(this_object->m_pull);
    visitor.append(this_object->m_cancel);
}

template <typename Visitor>
void JSColloReadableStreamDefaultController::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloReadableStreamDefaultController*>(cell);
    ASSERT_GC_OBJECT_INHERITS(this_object, info());
    Base::visitChildren(this_object, visitor);
    visitor.append(this_object->m_size);
}

template <typename Visitor> void JSColloReadableByteStreamController::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloReadableByteStreamController*>(cell);
    ASSERT_GC_OBJECT_INHERITS(this_object, info());
    Base::visitChildren(this_object, visitor);
    visitor.append(this_object->m_byob_request);
}

template <typename Visitor> void JSColloReadableStreamBYOBRequest::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloReadableStreamBYOBRequest*>(cell);
    ASSERT_GC_OBJECT_INHERITS(this_object, info());
    Base::visitChildren(this_object, visitor);
    visitor.append(this_object->m_stream);
    visitor.append(this_object->m_view);
}

template <typename Visitor> void JSColloReadableStreamDefaultReader::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloReadableStreamDefaultReader*>(cell);
    ASSERT_GC_OBJECT_INHERITS(this_object, info());
    Base::visitChildren(this_object, visitor);
    visitor.append(this_object->m_stream);
    visitor.append(this_object->m_closed_promise);
}

template <typename Visitor> void JSColloReadableStreamBYOBReader::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloReadableStreamBYOBReader*>(cell);
    ASSERT_GC_OBJECT_INHERITS(this_object, info());
    Base::visitChildren(this_object, visitor);
    visitor.append(this_object->m_default_reader);
    visitor.append(this_object->m_closed_promise);
}

template <typename Visitor> void JSColloReadableStreamAsyncIterator::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloReadableStreamAsyncIterator*>(cell);
    ASSERT_GC_OBJECT_INHERITS(this_object, info());
    Base::visitChildren(this_object, visitor);
    visitor.append(this_object->m_reader);
    visitor.append(this_object->m_return_promise);
}

template <typename Visitor> void JSColloReadableStreamTeeState::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloReadableStreamTeeState*>(cell);
    ASSERT_GC_OBJECT_INHERITS(this_object, info());
    Base::visitChildren(this_object, visitor);
    visitor.append(this_object->m_original);
    visitor.append(this_object->m_branch_a);
    visitor.append(this_object->m_branch_b);
    visitor.append(this_object->m_reason_a);
    visitor.append(this_object->m_reason_b);
    visitor.append(this_object->m_cancel_promise);
}

template <typename Visitor> void JSColloReadableStreamFromState::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloReadableStreamFromState*>(cell);
    ASSERT_GC_OBJECT_INHERITS(this_object, info());
    Base::visitChildren(this_object, visitor);
    visitor.append(this_object->m_iterator);
    visitor.append(this_object->m_next);
    visitor.append(this_object->m_controller);
}

// The bytes the consumer has buffered are its own memory until the body is converted; it reads their size only through
// the atomic the VM thread keeps current.
template <typename Visitor> void JSColloBodyConsumer::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloBodyConsumer*>(cell);
    ASSERT_GC_OBJECT_INHERITS(this_object, info());
    Base::visitChildren(this_object, visitor);
    visitor.append(this_object->m_stream);
    visitor.append(this_object->m_reader);
    visitor.append(this_object->m_promise);
    visitor.reportExtraMemoryVisited(this_object->m_bytes_cost.load(std::memory_order_relaxed));
}

DEFINE_VISIT_CHILDREN(JSColloReadableStream);
DEFINE_VISIT_CHILDREN(JSColloReadableStreamController);
DEFINE_VISIT_CHILDREN(JSColloReadableStreamDefaultController);
DEFINE_VISIT_CHILDREN(JSColloReadableByteStreamController);
DEFINE_VISIT_CHILDREN(JSColloReadableStreamBYOBRequest);
DEFINE_VISIT_CHILDREN(JSColloReadableStreamDefaultReader);
DEFINE_VISIT_CHILDREN(JSColloReadableStreamBYOBReader);
DEFINE_VISIT_CHILDREN(JSColloReadableStreamAsyncIterator);
DEFINE_VISIT_CHILDREN(JSColloReadableStreamTeeState);
DEFINE_VISIT_CHILDREN(JSColloReadableStreamFromState);
DEFINE_VISIT_CHILDREN(JSColloBodyConsumer);

} // namespace Collo::HostFunctions

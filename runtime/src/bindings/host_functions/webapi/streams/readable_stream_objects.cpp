// ClassInfo and visitChildren of the ReadableStream cells declared in readable_stream_private.h. visitChildren runs on
// collector threads concurrently with the VM thread and must visit every WriteBarrier field of its class and every
// list and native source it owns: a field missed here leaves its target to be collected while still referenced.

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
    this_object->m_native_source.visit(this_object, visitor);
    this_object->m_queue.visit(this_object, visitor);
    this_object->m_read_requests.visit(this_object, visitor);
    this_object->m_byob_read_requests.visit(this_object, visitor);
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

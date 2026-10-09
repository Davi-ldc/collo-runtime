// Class info and visitChildren for the transform stream, its controller and the
// pipe state. visitChildren runs on collector threads while the VM thread
// mutates the cells, and it must visit every WriteBarrier field
// pipe_transform_stream_private.h declares.
#include "host_functions/webapi/streams/pipe_transform_stream_private.h"

namespace Collo::HostFunctions {

const JSC::ClassInfo JSColloTransformStream::s_info
    = { "TransformStream"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloTransformStream) };
const JSC::ClassInfo JSColloTransformStreamDefaultController::s_info = { "TransformStreamDefaultController"_s,
    &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloTransformStreamDefaultController) };
const JSC::ClassInfo JSColloPipeToState::s_info
    = { "ReadableStreamPipeToState"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloPipeToState) };
template <typename Visitor> void JSColloTransformStream::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloTransformStream*>(cell);
    ASSERT_GC_OBJECT_INHERITS(this_object, info());
    Base::visitChildren(this_object, visitor);
    visitor.append(this_object->m_readable);
    visitor.append(this_object->m_writable);
    visitor.append(this_object->m_controller);
    visitor.append(this_object->m_transformer);
    visitor.append(this_object->m_start);
    visitor.append(this_object->m_transform);
    visitor.append(this_object->m_flush);
    visitor.append(this_object->m_cancel);
    visitor.append(this_object->m_pending_write_chunk);
    visitor.append(this_object->m_pending_write_promise);
}

template <typename Visitor>
void JSColloTransformStreamDefaultController::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloTransformStreamDefaultController*>(cell);
    ASSERT_GC_OBJECT_INHERITS(this_object, info());
    Base::visitChildren(this_object, visitor);
    visitor.append(this_object->m_stream);
}
template <typename Visitor> void JSColloPipeToState::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloPipeToState*>(cell);
    ASSERT_GC_OBJECT_INHERITS(this_object, info());
    Base::visitChildren(this_object, visitor);
    visitor.append(this_object->m_source);
    visitor.append(this_object->m_destination);
    visitor.append(this_object->m_reader);
    visitor.append(this_object->m_writer);
    visitor.append(this_object->m_promise);
    visitor.append(this_object->m_resolve);
    visitor.append(this_object->m_reject);
    visitor.append(this_object->m_signal);
    visitor.append(this_object->m_read_fulfilled);
    visitor.append(this_object->m_read_rejected);
    visitor.append(this_object->m_write_fulfilled);
    visitor.append(this_object->m_write_rejected);
    visitor.append(this_object->m_signal_abort);
    visitor.append(this_object->m_shutdown_fulfilled);
    visitor.append(this_object->m_shutdown_rejected);
    visitor.append(this_object->m_shutdown_reason);
}
DEFINE_VISIT_CHILDREN(JSColloTransformStream);
DEFINE_VISIT_CHILDREN(JSColloTransformStreamDefaultController);
DEFINE_VISIT_CHILDREN(JSColloPipeToState);

} // namespace Collo::HostFunctions

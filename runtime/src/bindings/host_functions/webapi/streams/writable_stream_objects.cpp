// Class info and visitChildren for the writable stream cells. visitChildren
// runs on collector threads while the VM thread keeps mutating the cell, so it
// reads only single-word fields or fields guarded by cellLock(), and it must
// visit every WriteBarrier field writable_stream_private.h declares.
#include "host_functions/webapi/streams/writable_stream_private.h"

namespace Collo::HostFunctions {

const JSC::ClassInfo JSColloWritableStream::s_info
    = { "WritableStream"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloWritableStream) };
const JSC::ClassInfo JSColloWritableStreamDefaultWriter::s_info = { "WritableStreamDefaultWriter"_s, &Base::s_info,
    nullptr, nullptr, CREATE_METHOD_TABLE(JSColloWritableStreamDefaultWriter) };
const JSC::ClassInfo JSColloWritableStreamDefaultController::s_info = { "WritableStreamDefaultController"_s,
    &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloWritableStreamDefaultController) };
template <typename Visitor> void JSColloWritableStream::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloWritableStream*>(cell);
    ASSERT_GC_OBJECT_INHERITS(this_object, info());
    Base::visitChildren(this_object, visitor);
    visitor.append(this_object->m_stored_error);
    visitor.append(this_object->m_writer);
    visitor.append(this_object->m_controller);
    visitor.append(this_object->m_close_promise);
    visitor.append(this_object->m_abort_promise);
    visitor.append(this_object->m_write_fulfilled);
    visitor.append(this_object->m_write_rejected);
    visitor.append(this_object->m_close_fulfilled);
    visitor.append(this_object->m_close_rejected);
    visitor.append(this_object->m_abort_fulfilled);
    visitor.append(this_object->m_abort_rejected);
    visitor.append(this_object->m_queue_memory_limit_exceeded);
    // The active write is visited whether or not m_has_active_write is set,
    // because dequeueWriteRequest fills m_active_write before processQueue sets
    // the flag; a cleared barrier appends nothing. That copy is not barriered
    // (see the FIXME at WriteRequest in writable_stream_private.h).
    visitor.append(this_object->m_active_write.value);
    visitor.append(this_object->m_active_write.promise);
    // The cell lock keeps the write queue's buffer stable while the marker
    // walks it; the VM thread takes it around every change to the buffer.
    WTF::Locker locker { this_object->cellLock() };
    for (size_t index = this_object->m_write_queue_start; index < this_object->m_write_queue.size(); ++index) {
        visitor.append(this_object->m_write_queue[index].value);
        visitor.append(this_object->m_write_queue[index].promise);
    }
}

template <typename Visitor> void JSColloWritableStreamDefaultWriter::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloWritableStreamDefaultWriter*>(cell);
    ASSERT_GC_OBJECT_INHERITS(this_object, info());
    Base::visitChildren(this_object, visitor);
    visitor.append(this_object->m_stream);
    visitor.append(this_object->m_ready_promise);
    visitor.append(this_object->m_closed_promise);
}

template <typename Visitor>
void JSColloWritableStreamDefaultController::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloWritableStreamDefaultController*>(cell);
    ASSERT_GC_OBJECT_INHERITS(this_object, info());
    Base::visitChildren(this_object, visitor);
    visitor.append(this_object->m_stream);
    visitor.append(this_object->m_write);
    visitor.append(this_object->m_close);
    visitor.append(this_object->m_abort);
    visitor.append(this_object->m_size);
    visitor.append(this_object->m_underlying_sink);
    visitor.append(this_object->m_start_fulfilled);
    visitor.append(this_object->m_start_rejected);
}
DEFINE_VISIT_CHILDREN(JSColloWritableStream);
DEFINE_VISIT_CHILDREN(JSColloWritableStreamDefaultWriter);
DEFINE_VISIT_CHILDREN(JSColloWritableStreamDefaultController);

} // namespace Collo::HostFunctions

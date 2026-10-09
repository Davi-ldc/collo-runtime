// Class info and visitChildren for the compression stream cell, shared by
// CompressionStream and DecompressionStream. visitChildren runs on collector
// threads while the VM thread mutates the cell, and it must visit every
// WriteBarrier field compression_stream_private.h declares.
#include "host_functions/webapi/streams/compression_stream_private.h"

namespace Collo::HostFunctions {

const JSC::ClassInfo JSColloCompressionStream::s_info
    = { "CompressionStream"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloCompressionStream) };
template <typename Visitor> void JSColloCompressionStream::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloCompressionStream*>(cell);
    ASSERT_GC_OBJECT_INHERITS(this_object, info());
    Base::visitChildren(this_object, visitor);
    visitor.append(this_object->m_readable);
    visitor.append(this_object->m_writable);
    visitor.append(this_object->m_pending_promise);
}
DEFINE_VISIT_CHILDREN(JSColloCompressionStream);

} // namespace Collo::HostFunctions

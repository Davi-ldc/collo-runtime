// The definitions of the Response cell, whose invariants response_object.h states. Runs on the VM thread.

#include "host_functions/server/fetch/response_object.h"

#include <JavaScriptCore/JSCInlines.h>

namespace Collo::HostFunctions {

using namespace JSC;

WTF::String responseTypeString(ResponseType type)
{
    switch (type) {
    case ResponseType::Default:
        return "default"_s;
    case ResponseType::Basic:
        return "basic"_s;
    case ResponseType::Error:
        return "error"_s;
    }
    return "default"_s;
}

JSColloResponse* JSColloResponse::create(JSC::VM& vm, Collo::GlobalObject* global_object, uint16_t status,
    WTF::String status_text, WTF::String url, PendingBody&& body, JSC::JSObject* headers, ResponseType type,
    bool redirected, JSC::Structure* structure)
{
    auto* object = new (NotNull, JSC::allocateCell<JSColloResponse>(vm))
        JSColloResponse(vm, structure ? structure : global_object->responseStructure(), status, WTF::move(status_text),
            WTF::move(url), WTF::move(body.state), type, redirected);
    object->finishCreation(vm, body.stream, headers);
    return object;
}

void JSColloResponse::destroy(JSC::JSCell* cell) { static_cast<JSColloResponse*>(cell)->~JSColloResponse(); }

JSColloResponse::JSColloResponse(JSC::VM& vm, JSC::Structure* structure, uint16_t status, WTF::String status_text,
    WTF::String url, BodyState&& body, ResponseType type, bool redirected)
    : Base(vm, structure, WTF::move(body))
    , m_status(status)
    , m_status_text(WTF::move(status_text))
    , m_url(WTF::move(url))
    , m_type(type)
    , m_redirected(redirected)
{
}

JSColloResponse::~JSColloResponse() = default;

void JSColloResponse::finishCreation(JSC::VM& vm, JSC::JSObject* body_stream, JSC::JSObject* headers)
{
    Base::finishCreation(vm, body_stream);
    ASSERT(inherits(info()));
    m_headers.set(vm, this, headers);
}

const JSC::ClassInfo JSColloResponse::s_info
    = { "Response"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloResponse) };

template <typename Visitor> void JSColloResponse::visitChildrenImpl(JSC::JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloResponse*>(cell);
    ASSERT_GC_OBJECT_INHERITS(this_object, info());
    Base::visitChildren(this_object, visitor);
    visitor.append(this_object->m_headers);
}

DEFINE_VISIT_CHILDREN(JSColloResponse);

} // namespace Collo::HostFunctions

// The Response cell, a JSColloBodyOwner that adds the status, status text, URL, type, redirected flag and Headers
// object. Runs on the VM thread. The constructor sets every field except the Headers edge, and none of them changes
// later; finishCreation writes that edge once, before the cell is published, so visitChildren reads it without the
// cell lock. The cell lives in the destructible space because its strings and its BodyState need their destructors,
// and a fetch-stream body's destructor releases its fetch body reference.

#pragma once

#include "host_functions/server/fetch/body.h"
#include "host_functions/support.h"

#include <JavaScriptCore/SlotVisitorMacros.h>
#include <wtf/text/WTFString.h>

namespace Collo::HostFunctions {

enum class ResponseType : uint8_t {
    Default,
    Basic,
    Error,
};

WTF::String responseTypeString(ResponseType);

class JSColloResponse final : public JSColloBodyOwner {
    using Base = JSColloBodyOwner;

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

    // A null structure selects the global object's Response structure; a subclass constructor passes the one its
    // new.target derives. The PendingBody stays in the caller's frame, which keeps its stream alive until
    // finishCreation stores it.
    static JSColloResponse* create(JSC::VM&, Collo::GlobalObject*, uint16_t status, WTF::String status_text,
        WTF::String url, PendingBody&&, JSC::JSObject* headers, ResponseType, bool redirected,
        JSC::Structure* = nullptr);
    static void destroy(JSC::JSCell*);

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    uint16_t status() const { return m_status; }
    const WTF::String& statusText() const { return m_status_text; }
    const WTF::String& url() const { return m_url; }
    ResponseType type() const { return m_type; }
    bool redirected() const { return m_redirected; }
    JSC::JSObject* headers() const { return m_headers.get(); }
    bool ok() const { return m_status >= 200 && m_status < 300; }

private:
    JSColloResponse(JSC::VM&, JSC::Structure*, uint16_t status, WTF::String status_text, WTF::String url, BodyState&&,
        ResponseType, bool redirected);
    ~JSColloResponse();

    void finishCreation(JSC::VM&, JSC::JSObject* body_stream, JSC::JSObject* headers);

    uint16_t m_status { 200 };
    WTF::String m_status_text;
    WTF::String m_url;
    ResponseType m_type { ResponseType::Default };
    bool m_redirected { false };
    JSC::WriteBarrier<JSC::JSObject> m_headers;
};

} // namespace Collo::HostFunctions

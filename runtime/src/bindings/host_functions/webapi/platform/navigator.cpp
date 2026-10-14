// The `navigator` global on the VM thread: a plain object with userAgent, platform, hardwareConcurrency and a
// "Navigator" toStringTag, with no Navigator interface behind it. Every value is a constant written once at
// installation in the zygote, so a worker inherits the object without writing to its page.

#include "host_functions/webapi/platform/navigator.h"

#include <JavaScriptCore/IdentifierInlines.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSObject.h>
#include <JavaScriptCore/JSString.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <wtf/text/MakeString.h>

namespace Collo::HostFunctions {
namespace {

    // A VM runs one JavaScript turn at a time, and a worker gains parallelism only through more processes, so the
    // parallelism script can use is one, whatever the node's CPU count.
    constexpr unsigned NavigatorHardwareConcurrency = 1;

    WTF::ASCIILiteral platformString()
    {
#if OS(LINUX) && CPU(X86_64)
        return "Linux x86_64"_s;
#elif OS(LINUX) && CPU(ARM64)
        return "Linux arm64"_s;
#else
#error "Collo targets Linux on x86_64 and ARM64"
#endif
    }

} // namespace

void installWebApiNavigator(Collo::GlobalObject* global_object, JSC::VM& vm)
{
    auto* navigator = JSC::constructEmptyObject(global_object, global_object->objectPrototype(), 4);
    RELEASE_ASSERT(navigator);

    navigator->putDirect(
        vm, JSC::Identifier::fromString(vm, "userAgent"_s), JSC::jsString(vm, WTF::makeString("Collo/1"_s)));
    navigator->putDirect(
        vm, JSC::Identifier::fromString(vm, "platform"_s), JSC::jsString(vm, WTF::makeString(platformString())));
    navigator->putDirect(
        vm, JSC::Identifier::fromString(vm, "hardwareConcurrency"_s), JSC::jsNumber(NavigatorHardwareConcurrency));
    navigator->putDirect(vm, vm.propertyNames->toStringTagSymbol, JSC::jsString(vm, WTF::makeString("Navigator"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    JSC::Identifier identifier = JSC::Identifier::fromString(vm, "navigator"_s);
    global_object->putDirect(vm, identifier, navigator);
    RELEASE_ASSERT(global_object->getDirect(vm, identifier));
}

} // namespace Collo::HostFunctions

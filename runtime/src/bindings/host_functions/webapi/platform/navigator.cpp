// The `navigator` global on the VM thread: a plain object with userAgent, platform, hardwareConcurrency and a
// "Navigator" toStringTag, with no Navigator interface behind it. hardwareConcurrency counts the CPUs in the
// process's affinity mask, or the online CPUs when the mask cannot be read, clamped to
// [1, WebApiNavigatorHardwareConcurrencyMax]. The zygote computes it at install and each worker recomputes it after
// the fork through `refreshWebApiNavigator`.

#include "host_functions/webapi/platform/navigator.h"

#include "host_functions/webapi/limits.h"

#include <JavaScriptCore/IdentifierInlines.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSObject.h>
#include <JavaScriptCore/JSString.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <wtf/text/MakeString.h>

#if OS(LINUX)
#include <sched.h>
#include <unistd.h>
#endif

#include <algorithm>
#include <thread>

namespace Collo::HostFunctions {
namespace {

    static unsigned allowedHardwareConcurrency()
    {
        unsigned detected = 1;
#if OS(LINUX)
        bool detected_affinity = false;
        cpu_set_t set;
        CPU_ZERO(&set);
        if (sched_getaffinity(0, sizeof(set), &set) == 0) {
            const int count = CPU_COUNT(&set);
            if (count > 0) {
                detected = static_cast<unsigned>(count);
                detected_affinity = true;
            }
        }

        if (!detected_affinity) {
            const long online = sysconf(_SC_NPROCESSORS_ONLN);
            if (online > 0)
                detected = static_cast<unsigned>(online);
        }
#else
        const auto count = std::thread::hardware_concurrency();
        detected = count == 0 ? 1 : count;
#endif

        return std::clamp(detected, 1u, WebApiNavigatorHardwareConcurrencyMax);
    }

    static WTF::ASCIILiteral platformString()
    {
#if OS(DARWIN)
        return "MacIntel"_s;
#elif OS(WINDOWS)
        return "Win32"_s;
#elif OS(LINUX) && CPU(X86_64)
        return "Linux x86_64"_s;
#elif OS(LINUX) && CPU(ARM64)
        return "Linux arm64"_s;
#elif OS(LINUX)
        return "Linux"_s;
#else
        return "unknown"_s;
#endif
    }

} // namespace

void refreshWebApiNavigator(Collo::GlobalObject* global_object, JSC::VM& vm)
{
    JSC::Identifier identifier = JSC::Identifier::fromString(vm, "navigator"_s);
    auto navigator_value = global_object->getDirect(vm, identifier);
    if (!navigator_value.isCell())
        return;
    auto* navigator = dynamicDowncast<JSC::JSObject>(navigator_value);
    if (!navigator)
        return;
    navigator->putDirect(
        vm, JSC::Identifier::fromString(vm, "hardwareConcurrency"_s), JSC::jsNumber(allowedHardwareConcurrency()));
}

void installWebApiNavigator(Collo::GlobalObject* global_object, JSC::VM& vm)
{
    auto* navigator = JSC::constructEmptyObject(global_object, global_object->objectPrototype(), 4);
    RELEASE_ASSERT(navigator);

    navigator->putDirect(
        vm, JSC::Identifier::fromString(vm, "userAgent"_s), JSC::jsString(vm, WTF::makeString("Collo/1"_s)));
    navigator->putDirect(
        vm, JSC::Identifier::fromString(vm, "platform"_s), JSC::jsString(vm, WTF::makeString(platformString())));
    navigator->putDirect(
        vm, JSC::Identifier::fromString(vm, "hardwareConcurrency"_s), JSC::jsNumber(allowedHardwareConcurrency()));
    navigator->putDirect(vm, vm.propertyNames->toStringTagSymbol, JSC::jsString(vm, WTF::makeString("Navigator"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    JSC::Identifier identifier = JSC::Identifier::fromString(vm, "navigator"_s);
    global_object->putDirect(vm, identifier, navigator);
    RELEASE_ASSERT(global_object->getDirect(vm, identifier));
    refreshWebApiNavigator(global_object, vm);
}

} // namespace Collo::HostFunctions

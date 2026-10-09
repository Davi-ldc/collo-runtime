// Installs the host functions on a Collo global, on the VM thread; internal.h says when each entry point runs.
// globals.def is an X-macro list expanded inside install: a COLLO_HOST_PUBLIC_GLOBAL entry defines a non-enumerable
// global function with the given name and length, and a COLLO_HOST_CLASS_INSTALLER entry calls that installer. The
// installers run in file order, and a later one may read what an earlier one cached on the global, as installWebApiFile
// reads the Blob prototype and installWebApiAbort the EventTarget prototype, so reordering globals.def can break
// installation.

#include "host_functions/internal.h"

#include <JavaScriptCore/Symbol.h>
#include <unistd.h>
#include <wtf/text/SymbolImpl.h>

namespace {

void addGlobalFunction(JSC::VM& vm, Collo::GlobalObject* global_object, ASCIILiteral name, JSC::NativeFunction function,
    unsigned argument_count, unsigned attributes = static_cast<unsigned>(JSC::PropertyAttribute::DontEnum))
{
    JSC::Identifier identifier = JSC::Identifier::fromString(vm, name);
    auto* function_object = JSC::JSFunction::create(
        vm, global_object, argument_count, identifier.string(), function, JSC::ImplementationVisibility::Public);
    RELEASE_ASSERT(function_object);
    global_object->putDirect(vm, identifier, function_object, attributes);
    RELEASE_ASSERT(global_object->getDirect(vm, identifier));
}

void addExplicitResourceManagementSymbol(
    JSC::VM& vm, JSC::JSObject* symbol_constructor, ASCIILiteral name, const JSC::Identifier& symbol_identifier)
{
    auto name_identifier = JSC::Identifier::fromString(vm, name);
    if (symbol_constructor->getDirect(vm, name_identifier))
        return;

    symbol_constructor->putDirect(vm, name_identifier,
        JSC::Symbol::create(vm, static_cast<WTF::SymbolImpl&>(*symbol_identifier.impl())),
        static_cast<unsigned>(
            JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete | JSC::PropertyAttribute::ReadOnly));
}

// The pinned engine's Symbol constructor already defines Symbol.dispose and Symbol.asyncDispose among its well-known
// symbols (SymbolConstructor::finishCreation), so this adds one only for an engine that lacks it, with the attributes
// the engine gives its own.
void installExplicitResourceManagementSymbols(JSC::VM& vm, Collo::GlobalObject* global_object)
{
    auto symbol_value = global_object->getDirect(vm, JSC::Identifier::fromString(vm, "Symbol"_s));
    auto* symbol_constructor = dynamicDowncast<JSC::JSObject>(symbol_value);
    RELEASE_ASSERT(symbol_constructor);

    addExplicitResourceManagementSymbol(vm, symbol_constructor, "dispose"_s, vm.propertyNames->disposeSymbol);
    addExplicitResourceManagementSymbol(vm, symbol_constructor, "asyncDispose"_s, vm.propertyNames->asyncDisposeSymbol);
}

} // namespace

namespace Collo::HostFunctions {

void install(Collo::GlobalObject* global_object, JSC::VM& vm)
{
#define COLLO_HOST_PUBLIC_GLOBAL(name, function, argument_count)                                                       \
    addGlobalFunction(vm, global_object, name, function, argument_count);
#define COLLO_HOST_CLASS_INSTALLER(function) function(global_object, vm);
#include "globals.def"
#undef COLLO_HOST_CLASS_INSTALLER
#undef COLLO_HOST_PUBLIC_GLOBAL

    installExplicitResourceManagementSymbols(vm, global_object);

    auto self_identifier = JSC::Identifier::fromString(vm, "self"_s);
    global_object->putDirect(
        vm, self_identifier, global_object->globalThis(), static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
}

ColloStatus installProcess(Collo::GlobalObject* global_object, JSC::VM& vm)
{
    if (!global_object)
        return COLLO_STATUS_INVALID_ARGUMENT;

    auto* env_object = JSC::constructEmptyObject(global_object);
    RELEASE_ASSERT(env_object);

    auto* process_object = JSC::constructEmptyObject(global_object);
    RELEASE_ASSERT(process_object);
    process_object->putDirect(vm, JSC::Identifier::fromString(vm, "env"_s), env_object,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    process_object->putDirect(vm, JSC::Identifier::fromString(vm, "platform"_s),
        JSC::jsString(vm, WTF::String("linux"_s)),
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::ReadOnly));
    process_object->putDirect(vm, JSC::Identifier::fromString(vm, "version"_s),
        JSC::jsString(vm, WTF::String("v22.0.0-collo"_s)),
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::ReadOnly));
    process_object->putDirect(vm, JSC::Identifier::fromString(vm, "pid"_s), JSC::jsNumber(getpid()),
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::ReadOnly));
    global_object->putDirect(vm, JSC::Identifier::fromString(vm, "process"_s), process_object,
        static_cast<unsigned>(
            JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontDelete));
    return COLLO_STATUS_OK;
}

void installWorkerNodeBuiltins(Collo::GlobalObject* global_object, JSC::VM& vm) { installNodeFs(global_object, vm); }

} // namespace Collo::HostFunctions

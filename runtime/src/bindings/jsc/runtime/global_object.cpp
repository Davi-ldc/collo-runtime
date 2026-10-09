// Collo::GlobalObject, the JSC global object every Collo VM runs on, and VmClientData, through which a global finds
// its ColloVm and stack frames get their public source URLs. Runs on the VM thread. VM creation installs
// VmClientData before it creates the global, and the JSC VM deletes it only in its own destructor, so every live
// global reaches its ColloVm; owner() aborts when it cannot.

#include "jsc/runtime/state.h"

using namespace JSC;

namespace Collo {

VmClientData::VmClientData(ColloVm* owner)
    : owner(owner)
{
}

WTF::String VmClientData::overrideSourceURL(const JSC::StackFrame&, const WTF::String& originalSourceURL) const
{
    // A deploy-scoped module key stays internal: stack frames show the same file:///var/task URL that
    // import.meta.url exposes, as Node's ESM stacks carry file: URLs. Every other source URL passes through.
    WTF::String public_url = publicModuleURLForKey(originalSourceURL);
    return public_url.isNull() ? originalSourceURL : public_url;
}

const JSC::ClassInfo GlobalObject::s_info
    = { "ColloGlobal"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(GlobalObject) };

// Designated rather than positional. The table is twenty-one function pointers with similar signatures, so a field
// added, removed or reordered upstream would silently slide every later entry into the wrong slot; with the names
// written out the compiler points at the field instead of reporting a dozen mismatched types. A null entry selects
// the engine's fallback: its built-in behavior for moduleLoaderEvaluate and defaultLanguage, and no
// WebAssembly.compileStreaming or instantiateStreaming function at all for the two streaming hooks.
const JSC::GlobalObjectMethodTable GlobalObject::s_globalObjectMethodTable = {
    .supportsRichSourceInfo = &JSC::JSGlobalObject::supportsRichSourceInfo,
    .shouldInterruptScript = &JSC::JSGlobalObject::shouldInterruptScript,
    .javaScriptRuntimeFlags = &javaScriptRuntimeFlags,
    .shouldInterruptScriptBeforeTimeout = &JSC::JSGlobalObject::shouldInterruptScriptBeforeTimeout,
    .moduleLoaderImportModule = &moduleLoaderImportModule,
    .moduleLoaderResolve = &moduleLoaderResolve,
    .moduleLoaderFetch = &moduleLoaderFetch,
    .moduleLoaderCreateImportMetaProperties = &moduleLoaderCreateImportMetaProperties,
    .moduleLoaderEvaluate = nullptr,
    .promiseRejectionTracker = &JSC::JSGlobalObject::promiseRejectionTracker,
    .reportUncaughtExceptionAtEventLoop = &JSC::JSGlobalObject::reportUncaughtExceptionAtEventLoop,
    .currentScriptExecutionOwner = &JSC::JSGlobalObject::currentScriptExecutionOwner,
    .scriptExecutionStatus = &JSC::JSGlobalObject::scriptExecutionStatus,
    .reportViolationForUnsafeEval = &JSC::JSGlobalObject::reportViolationForUnsafeEval,
    .defaultLanguage = nullptr,
    .compileStreaming = nullptr,
    .instantiateStreaming = nullptr,
    .deriveShadowRealmGlobalObject = &JSC::JSGlobalObject::deriveShadowRealmGlobalObject,
    .codeForEval = &JSC::JSGlobalObject::codeForEval,
    .canCompileStrings = &JSC::JSGlobalObject::canCompileStrings,
    .trustedScriptStructure = &JSC::JSGlobalObject::trustedScriptStructure,
};

GlobalObject* GlobalObject::create(JSC::VM& vm, JSC::Structure* structure, ColloVm* owner)
{
    auto* client_data = static_cast<VmClientData*>(vm.clientData);
    RELEASE_ASSERT(client_data);
    RELEASE_ASSERT(client_data->owner == owner);
    auto* global = new (NotNull, JSC::allocateCell<GlobalObject>(vm)) GlobalObject(vm, structure);
    global->finishCreation(vm);
    return global;
}

JSC::Structure* GlobalObject::createStructure(JSC::VM& vm, JSC::JSValue prototype)
{
    return JSC::Structure::create(vm, nullptr, prototype, JSC::TypeInfo(JSC::GlobalObjectType, StructureFlags), info());
}

JSC::RuntimeFlags GlobalObject::javaScriptRuntimeFlags(const JSC::JSGlobalObject*)
{
    return JSC::RuntimeFlags::createAllEnabled();
}

ColloVm& GlobalObject::owner() const
{
    auto* client_data = static_cast<VmClientData*>(vm().clientData);
    // VM creation installs VmClientData before the global object exists, so a missing owner means the bridge's
    // state is corrupt and continuing could act on the wrong VM.
    RELEASE_ASSERT(client_data);
    RELEASE_ASSERT(client_data->owner);
    return *client_data->owner;
}

GlobalObject::GlobalObject(JSC::VM& vm, JSC::Structure* structure)
    : JSC::JSGlobalObject(vm, structure, &s_globalObjectMethodTable)
{
}

void GlobalObject::finishCreation(JSC::VM& vm)
{
    Base::finishCreation(vm);
    setName("Collo"_s);
}

} // namespace Collo

// The structured clone algorithm, which builds clones straight from the source values with the caller's global
// object, and the structuredClone global. Runs on the VM thread.
//
// A StructuredCloneContext lives on the stack for one call. Cloning runs script (getters, the transfer list's
// iterator), so the source graph can change while it is walked. Nesting depth is capped by
// WebApiStructuredCloneDepthMax, which bounds the native recursion, and cloned objects plus Map, Set, property and
// transfer list entries by WebApiStructuredCloneEntriesMax. A transferred ArrayBuffer is copied into its clone and
// detached at commit, which gives the result of a move at the cost of a copy.

#include "host_functions/webapi/messaging/structured_clone.h"

#include "host_functions/webapi/files/blob.h"
#include "host_functions/webapi/limits.h"
#include "host_functions/webapi/dom/dom_exception.h"

#include <JavaScriptCore/ArgList.h>
#include <JavaScriptCore/ArrayBuffer.h>
#include <JavaScriptCore/DateInstance.h>
#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/IdentifierInlines.h>
#include <JavaScriptCore/IteratorOperations.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSArray.h>
#include <JavaScriptCore/JSArrayBuffer.h>
#include <JavaScriptCore/JSArrayBufferView.h>
#include <JavaScriptCore/JSDataView.h>
#include <JavaScriptCore/JSGlobalObjectInlines.h>
#include <JavaScriptCore/JSGenericTypedArrayViewInlines.h>
#include <JavaScriptCore/JSMap.h>
#include <JavaScriptCore/JSMapInlines.h>
#include <JavaScriptCore/JSObject.h>
#include <JavaScriptCore/JSSet.h>
#include <JavaScriptCore/JSSetInlines.h>
#include <JavaScriptCore/JSTypedArrays.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <JavaScriptCore/PropertyNameArray.h>
#include <JavaScriptCore/PropertySlot.h>
#include <JavaScriptCore/RegExp.h>
#include <JavaScriptCore/RegExpObject.h>
#include <JavaScriptCore/TypedArrayType.h>
#include <wtf/HashMap.h>
#include <wtf/HashSet.h>
#include <wtf/RefPtr.h>
#include <wtf/Scope.h>
#include <wtf/text/WTFString.h>

#include <bit>
#include <cstdint>
#include <optional>

namespace Collo::HostFunctions {
namespace {

    using JSC::EncodedJSValue;
    using JSC::JSValue;
    using WTF::String;
    using namespace JSC;

    // Checks every buffer, then detaches them all, so a buffer that became detached, shared or resizable since the
    // clone throws a DataCloneError and leaves the others attached. Returns false with an exception on the ThrowScope
    // on failure.
    static bool commitArrayBufferTransfers(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        const WTF::HashSet<WTF::RefPtr<JSC::ArrayBuffer>>& transfers)
    {
        for (auto& buffer : transfers) {
            if (!buffer || buffer->isDetached() || buffer->isShared() || buffer->isResizableOrGrowableShared()) {
                throwException(global_object, scope,
                    createDOMException(
                        global_object, DOMExceptionCode::DataCloneError, "ArrayBuffer could not be transferred"_s));
                return false;
            }
        }

        auto& vm = global_object->vm();
        // FIXME: A buffer the engine has locked or pinned, such as a WebAssembly.Memory buffer, passes the checks
        // above and those in StructuredCloneContext. transferTo() copies such a buffer and returns true, so the source
        // stays attached where HTML's DetachArrayBuffer would throw.
        for (auto& buffer : transfers) {
            ArrayBufferContents detached_contents;
            if (!buffer->transferTo(vm, detached_contents)) {
                throwException(global_object, scope,
                    createDOMException(
                        global_object, DOMExceptionCode::DataCloneError, "ArrayBuffer could not be transferred"_s));
                return false;
            }
        }
        return true;
    }

    class StructuredCloneContext {
        WTF_FORBID_HEAP_ALLOCATION;

    public:
        StructuredCloneContext(
            JSGlobalObject* global_object, ThrowScope& scope, JSC::JSObject* blocked_sender = nullptr)
            : m_global_object(global_object)
            , m_vm(global_object->vm())
            , m_scope(scope)
            , m_blocked_sender(blocked_sender)
        {
        }

        bool parseOptions(JSValue options)
        {
            if (options.isUndefinedOrNull())
                return true;

            if (!options.isObject()) {
                throwTypeError("structuredClone options must be an object"_s);
                return false;
            }

            auto* options_object = asObject(options);
            auto transfer_value
                = options_object->getIfPropertyExists(m_global_object, Identifier::fromString(m_vm, "transfer"_s));
            RETURN_IF_EXCEPTION(m_scope, false);
            if (!transfer_value || transfer_value.isUndefined())
                return true;

            return parseTransferList(transfer_value);
        }

        bool parseTransferList(JSValue transfer_value)
        {
            forEachInIterable(m_global_object, transfer_value, [&](VM&, JSGlobalObject*, JSValue value) {
                if (m_scope.exception())
                    return;
                if (!consumeCloneEntry())
                    return;

                auto* buffer_object = dynamicDowncast<JSArrayBuffer>(value);
                if (buffer_object) {
                    RefPtr<ArrayBuffer> buffer = buffer_object->impl();
                    if (!buffer || buffer->isDetached() || buffer->isShared()
                        || buffer->isResizableOrGrowableShared()) {
                        throwDataClone("ArrayBuffer could not be transferred"_s);
                        return;
                    }

                    if (!m_transfer_buffers.add(buffer).isNewEntry)
                        throwDataClone("Transfer list contains duplicate ArrayBuffer"_s);
                    return;
                }

                if (webApiMessagePortIsValue(value)) {
                    if (m_blocked_sender
                        && webApiMessagePortTransferConflictsWith(value.getObject(), m_blocked_sender)) {
                        throwDataClone("MessagePort could not be transferred"_s);
                        return;
                    }
                    // A port listed twice is refused before a second clone is made for it.
                    if (m_transfer_ports.contains(cellKey(value.asCell()))) {
                        throwDataClone("Transfer list contains duplicate MessagePort"_s);
                        return;
                    }
                    auto* clone = webApiCreateMessagePortTransferClone(m_global_object, m_scope, value);
                    if (!clone)
                        return;
                    if (!root(value))
                        return;
                    auto clone_index = root(clone);
                    if (!clone_index)
                        return;
                    m_transfer_ports.add(cellKey(value.asCell()), *clone_index);
                    if (!m_port_transfers.tryAppend(WebApiMessagePortTransfer { value.getObject(), clone }))
                        throwException(m_global_object, m_scope, createOutOfMemoryError(m_global_object));
                    return;
                }

                throwDataClone("Value could not be transferred"_s);
            });
            RETURN_IF_EXCEPTION(m_scope, false);
            return true;
        }

        JSValue clone(JSValue value)
        {
            if (value.isSymbol()) {
                throwDataClone("Symbol values cannot be cloned"_s);
                return {};
            }

            if (!value.isCell())
                return value;

            // Strings and BigInts are immutable cells, so the clone shares them.
            if (value.isString() || value.isBigInt())
                return value;

            auto* cell = value.asCell();
            if (auto seen = m_seen.find(cellKey(cell)); seen != m_seen.end())
                return m_roots.at(seen->value);

            if (!value.isObject()) {
                throwDataClone("Value could not be cloned"_s);
                return {};
            }

            if (value.isCallable()) {
                throwDataClone("Function objects cannot be cloned"_s);
                return {};
            }

            if (!enterCloneNode())
                return {};
            auto leave_clone_node = WTF::makeScopeExit([&] { m_depth--; });

            auto* object = asObject(value);

            if (webApiMessagePortIsValue(object)) {
                auto found = m_transfer_ports.find(cellKey(object));
                if (found == m_transfer_ports.end()) {
                    throwDataClone("MessagePort could not be cloned"_s);
                    return {};
                }
                return m_roots.at(found->value);
            }

            if (auto* buffer = dynamicDowncast<JSArrayBuffer>(object))
                return cloneArrayBuffer(buffer);
            if (auto* view = dynamicDowncast<JSArrayBufferView>(object))
                return cloneArrayBufferView(view);
            if (auto* file = dynamicDowncast<JSColloFile>(object))
                return cloneFile(file);
            if (auto* blob = dynamicDowncast<JSColloBlob>(object))
                return cloneBlob(blob);
            if (auto* date = dynamicDowncast<DateInstance>(object))
                return cloneDate(date);
            if (auto* regexp = dynamicDowncast<RegExpObject>(object))
                return cloneRegExp(regexp);
            if (auto* map = dynamicDowncast<JSMap>(object))
                return cloneMap(map);
            if (auto* set = dynamicDowncast<JSSet>(object))
                return cloneSet(set);
            if (auto* array = dynamicDowncast<JSArray>(object))
                return cloneArray(array);

            return cloneObject(object);
        }

        bool validateTransfers()
        {
            for (auto& buffer : m_transfer_buffers) {
                if (!isValidTransferBuffer(buffer.get())) {
                    throwDataClone("ArrayBuffer could not be transferred"_s);
                    return false;
                }
            }
            if (!webApiValidateMessagePortTransfers(m_global_object, m_scope, m_port_transfers))
                return false;
            RETURN_IF_EXCEPTION(m_scope, false);
            return true;
        }

        JSValue cloneRoot(JSValue value) { return clone(value); }

        JSC::JSObject* transferredPortsArray()
        {
            // Every transferred port consumed a clone entry, so the size is bounded by WebApiStructuredCloneEntriesMax.
            auto* array = JSC::constructEmptyArray(m_global_object, nullptr, m_port_transfers.size());
            RETURN_IF_EXCEPTION(m_scope, nullptr);
            for (unsigned index = 0; index < m_port_transfers.size(); index++) {
                array->putDirectIndex(m_global_object, index, m_port_transfers[index].clone);
                RETURN_IF_EXCEPTION(m_scope, nullptr);
            }
            JSC::objectConstructorFreeze(m_global_object, array);
            RETURN_IF_EXCEPTION(m_scope, nullptr);
            return array;
        }

        // Revalidates every transfer, then detaches the ArrayBuffers and moves each MessagePort to its clone. A source
        // that stopped being transferable since the clone throws a DataCloneError before anything is detached.
        bool commitTransfers()
        {
            if (!commitArrayBufferTransfers(m_global_object, m_scope, m_transfer_buffers))
                return false;
            return webApiCommitMessagePortTransfers(m_global_object, m_scope, m_port_transfers);
        }

    private:
        static uintptr_t cellKey(const JSCell* cell) { return std::bit_cast<uintptr_t>(cell); }

        // Roots `value` and returns its index in m_roots, or throws an OutOfMemoryError and returns nullopt.
        std::optional<unsigned> root(JSValue value)
        {
            m_roots.append(value);
            if (m_roots.hasOverflowed()) {
                throwException(m_global_object, m_scope, createOutOfMemoryError(m_global_object));
                return std::nullopt;
            }
            return static_cast<unsigned>(m_roots.size() - 1);
        }
        void throwDataClone(WTF::ASCIILiteral message)
        {
            throwException(m_global_object, m_scope,
                createDOMException(m_global_object, DOMExceptionCode::DataCloneError, String(message)));
        }

        void throwTypeError(WTF::ASCIILiteral message) { throwVMTypeError(m_global_object, m_scope, message); }

        bool enterCloneNode()
        {
            if (m_depth >= WebApiStructuredCloneDepthMax) {
                throwDataClone("Structured clone depth limit exceeded"_s);
                return false;
            }
            if (m_entry_count >= WebApiStructuredCloneEntriesMax) {
                throwDataClone("Structured clone size limit exceeded"_s);
                return false;
            }
            m_depth++;
            m_entry_count++;
            return true;
        }

        bool consumeCloneEntry()
        {
            if (m_entry_count >= WebApiStructuredCloneEntriesMax) {
                throwDataClone("Structured clone size limit exceeded"_s);
                return false;
            }
            m_entry_count++;
            return true;
        }

        bool consumeCloneEntries(size_t count)
        {
            if (count > WebApiStructuredCloneEntriesMax || m_entry_count > WebApiStructuredCloneEntriesMax - count) {
                throwDataClone("Structured clone size limit exceeded"_s);
                return false;
            }
            m_entry_count += count;
            return true;
        }

        static bool isValidTransferBuffer(ArrayBuffer* buffer)
        {
            return buffer && !buffer->isDetached() && !buffer->isShared() && !buffer->isResizableOrGrowableShared();
        }

        // Records that `source` clones to `clone`. Returns false with an OutOfMemoryError thrown when either cannot
        // be rooted. Each object, array, Map and Set clone is remembered before its contents are copied, so a cycle
        // back to `source` finds the clone. A view is remembered after its buffer, because cloning a buffer copies
        // only bytes and cannot reach the view.
        bool remember(JSCell* source, JSValue clone)
        {
            if (!root(source))
                return false;
            auto index = root(clone);
            if (!index)
                return false;
            m_seen.set(cellKey(source), *index);
            return true;
        }

        JSValue cloneArrayBuffer(JSArrayBuffer* source)
        {
            auto* buffer = source->impl();
            if (!buffer || buffer->isDetached() || buffer->isShared() || buffer->isResizableOrGrowableShared()) {
                throwDataClone("ArrayBuffer could not be cloned"_s);
                return {};
            }

            auto clone_buffer = ArrayBuffer::tryCreate(buffer->span());
            if (!clone_buffer) {
                throwException(m_global_object, m_scope, createOutOfMemoryError(m_global_object));
                return {};
            }

            auto* result = JSArrayBuffer::create(
                m_vm, m_global_object->arrayBufferStructure(ArrayBufferSharingMode::Default), WTF::move(clone_buffer));
            if (!remember(source, result))
                return {};
            return result;
        }

        JSValue cloneArrayBufferView(JSArrayBufferView* source)
        {
            if (source->isDetached() || source->isShared() || source->isResizableOrGrowableShared()) {
                throwDataClone("ArrayBuffer view could not be cloned"_s);
                return {};
            }

            JSArrayBuffer* source_buffer = source->unsharedJSBuffer(m_global_object);
            RETURN_IF_EXCEPTION(m_scope, {});
            if (!source_buffer) {
                throwDataClone("ArrayBuffer view could not be cloned"_s);
                return {};
            }

            JSValue cloned_buffer_value = clone(source_buffer);
            RETURN_IF_EXCEPTION(m_scope, {});
            auto* cloned_buffer_object = dynamicDowncast<JSArrayBuffer>(cloned_buffer_value);
            RELEASE_ASSERT(cloned_buffer_object);
            RefPtr<ArrayBuffer> cloned_buffer = cloned_buffer_object->impl();

            size_t byte_offset = source->byteOffset();
            std::optional<size_t> length = source->length();
            JSValue result;

            switch (typedArrayType(source->type())) {
            case TypeInt8:
                result = JSInt8Array::create(m_global_object, m_global_object->typedArrayStructure(TypeInt8, false),
                    WTF::move(cloned_buffer), byte_offset, length);
                break;
            case TypeInt16:
                result = JSInt16Array::create(m_global_object, m_global_object->typedArrayStructure(TypeInt16, false),
                    WTF::move(cloned_buffer), byte_offset, length);
                break;
            case TypeInt32:
                result = JSInt32Array::create(m_global_object, m_global_object->typedArrayStructure(TypeInt32, false),
                    WTF::move(cloned_buffer), byte_offset, length);
                break;
            case TypeUint8:
                result = JSUint8Array::create(m_global_object, m_global_object->typedArrayStructure(TypeUint8, false),
                    WTF::move(cloned_buffer), byte_offset, length);
                break;
            case TypeUint8Clamped:
                result = JSUint8ClampedArray::create(m_global_object,
                    m_global_object->typedArrayStructure(TypeUint8Clamped, false), WTF::move(cloned_buffer),
                    byte_offset, length);
                break;
            case TypeUint16:
                result = JSUint16Array::create(m_global_object, m_global_object->typedArrayStructure(TypeUint16, false),
                    WTF::move(cloned_buffer), byte_offset, length);
                break;
            case TypeUint32:
                result = JSUint32Array::create(m_global_object, m_global_object->typedArrayStructure(TypeUint32, false),
                    WTF::move(cloned_buffer), byte_offset, length);
                break;
            case TypeFloat16:
                result
                    = JSFloat16Array::create(m_global_object, m_global_object->typedArrayStructure(TypeFloat16, false),
                        WTF::move(cloned_buffer), byte_offset, length);
                break;
            case TypeFloat32:
                result
                    = JSFloat32Array::create(m_global_object, m_global_object->typedArrayStructure(TypeFloat32, false),
                        WTF::move(cloned_buffer), byte_offset, length);
                break;
            case TypeFloat64:
                result
                    = JSFloat64Array::create(m_global_object, m_global_object->typedArrayStructure(TypeFloat64, false),
                        WTF::move(cloned_buffer), byte_offset, length);
                break;
            case TypeBigInt64:
                result = JSBigInt64Array::create(m_global_object,
                    m_global_object->typedArrayStructure(TypeBigInt64, false), WTF::move(cloned_buffer), byte_offset,
                    length);
                break;
            case TypeBigUint64:
                result = JSBigUint64Array::create(m_global_object,
                    m_global_object->typedArrayStructure(TypeBigUint64, false), WTF::move(cloned_buffer), byte_offset,
                    length);
                break;
            case TypeDataView:
                result = JSDataView::create(m_global_object, m_global_object->typedArrayStructure(TypeDataView, false),
                    WTF::move(cloned_buffer), byte_offset, length);
                break;
            case NotTypedArray:
                RELEASE_ASSERT_NOT_REACHED();
                break;
            }
            RETURN_IF_EXCEPTION(m_scope, {});
            if (!remember(source, result))
                return {};
            return result;
        }

        JSValue cloneBlob(JSColloBlob* source)
        {
            auto* result
                = JSColloBlob::create(m_vm, uncheckedDowncast<Collo::GlobalObject>(m_global_object)->blobStructure(),
                    source->storageRef(), source->byteOffset(), source->size(), source->type());
            if (!remember(source, result))
                return {};
            return result;
        }

        JSValue cloneFile(JSColloFile* source)
        {
            auto* result = JSColloFile::createFromBlob(m_vm,
                uncheckedDowncast<Collo::GlobalObject>(m_global_object)->fileStructure(), *source, source->name(),
                source->lastModified());
            if (!remember(source, result))
                return {};
            return result;
        }

        JSValue cloneDate(DateInstance* source)
        {
            auto* result = DateInstance::create(m_vm, m_global_object->dateStructure(), source->internalNumber());
            if (!remember(source, result))
                return {};
            return result;
        }

        JSValue cloneRegExp(RegExpObject* source)
        {
            auto* source_regexp = source->regExp();
            auto* regexp = RegExp::create(m_vm, source_regexp->pattern(), source_regexp->flags());
            if (!regexp->isValid()) {
                throwException(m_global_object, m_scope, regexp->errorToThrow(m_global_object));
                return {};
            }
            auto* result = RegExpObject::create(m_vm, m_global_object->regExpStructure(), regexp, 0);
            if (!remember(source, result))
                return {};
            return result;
        }

        // The clone starts empty, gains only the indexes the source has, and takes the source's length last. A sparse
        // source therefore stays sparse, and its clone costs what its entries cost instead of what its length implies.
        // The length is read before any getter runs, as HTML reads it before it serializes the properties.
        JSValue cloneArray(JSArray* source)
        {
            const unsigned length = source->length();
            auto* result = constructEmptyArray(m_global_object, nullptr);
            RETURN_IF_EXCEPTION(m_scope, {});
            if (!remember(source, result))
                return {};
            if (!copyEnumerableOwnProperties(source, result))
                return {};
            if (result->length() < length) {
                result->setLength(m_global_object, length, true);
                RETURN_IF_EXCEPTION(m_scope, {});
            }
            return result;
        }

        // FIXME: HTML serializes Boolean, Number, BigInt and String objects with their primitive value and Error
        // objects with their name, message and stack, and rejects platform objects that are not serializable with a
        // DataCloneError. All of them reach this function and become plain objects.
        JSValue cloneObject(JSObject* source)
        {
            auto* result = constructEmptyObject(m_global_object);
            if (!remember(source, result))
                return {};
            if (!copyEnumerableOwnProperties(source, result))
                return {};
            return result;
        }

        JSValue cloneMap(JSMap* source)
        {
            auto* result = JSMap::create(m_vm, m_global_object->mapStructure());
            if (!remember(source, result))
                return {};

            if (!source->storage())
                return result;

            auto* storage = uncheckedDowncast<JSMap::Storage>(source->storage());
            JSMap::Helper::Entry entry = 0;
            while (true) {
                auto next = JSMap::Helper::transitAndNext(m_vm, *storage, entry);
                if (!next.storage)
                    break;
                if (!consumeCloneEntry())
                    return {};
                storage = next.storage;
                entry = next.entry + 1;

                JSValue key = clone(next.key);
                RETURN_IF_EXCEPTION(m_scope, {});
                JSValue value = clone(next.value);
                RETURN_IF_EXCEPTION(m_scope, {});
                result->set(m_global_object, key, value);
                RETURN_IF_EXCEPTION(m_scope, {});
            }
            return result;
        }

        JSValue cloneSet(JSSet* source)
        {
            auto* result = JSSet::create(m_vm, m_global_object->setStructure());
            if (!remember(source, result))
                return {};

            if (!source->storage())
                return result;

            auto* storage = uncheckedDowncast<JSSet::Storage>(source->storage());
            JSSet::Helper::Entry entry = 0;
            while (true) {
                auto next = JSSet::Helper::transitAndNext(m_vm, *storage, entry);
                if (!next.storage)
                    break;
                if (!consumeCloneEntry())
                    return {};
                storage = next.storage;
                entry = next.entry + 1;

                JSValue cloned = clone(next.key);
                RETURN_IF_EXCEPTION(m_scope, {});
                result->add(m_global_object, cloned);
                RETURN_IF_EXCEPTION(m_scope, {});
            }
            return result;
        }

        bool copyEnumerableOwnProperties(JSObject* source, JSObject* target, PropertyNameMode mode)
        {
            PropertyNameArrayBuilder keys(m_vm, mode, PrivateSymbolMode::Exclude);
            source->methodTable()->getOwnPropertyNames(source, m_global_object, keys, DontEnumPropertiesMode::Exclude);
            RETURN_IF_EXCEPTION(m_scope, false);
            if (!consumeCloneEntries(keys.size()))
                return false;

            for (auto iter = keys.begin(); iter != keys.end(); ++iter) {
                PropertyName property_name = *iter;
                // The key is looked up again because a getter run for an earlier key may have deleted it.
                PropertySlot slot(source, PropertySlot::InternalMethodType::GetOwnProperty);
                bool has_property
                    = source->methodTable()->getOwnPropertySlot(source, m_global_object, property_name, slot);
                RETURN_IF_EXCEPTION(m_scope, false);
                if (!has_property)
                    continue;

                JSValue source_value = slot.getValue(m_global_object, property_name);
                RETURN_IF_EXCEPTION(m_scope, false);
                JSValue cloned_value = clone(source_value);
                RETURN_IF_EXCEPTION(m_scope, false);

                target->putDirectMayBeIndex(m_global_object, property_name, cloned_value);
                RETURN_IF_EXCEPTION(m_scope, false);
            }

            return true;
        }

        // FIXME: HTML copies only string keys (EnumerableOwnProperties with kind key), so symbol-keyed properties
        // should not reach the clone.
        bool copyEnumerableOwnProperties(JSObject* source, JSObject* target)
        {
            return copyEnumerableOwnProperties(source, target, PropertyNameMode::Strings)
                && copyEnumerableOwnProperties(source, target, PropertyNameMode::Symbols);
        }

        JSGlobalObject* m_global_object;
        VM& m_vm;
        ThrowScope& m_scope;
        JSC::JSObject* m_blocked_sender { nullptr };
        // Every cell the clone records: each source with its clone, and each transferred port with its clone. The
        // maps key a source by its address, which names one live cell for the whole clone because the source is
        // rooted here too, and give the index of its clone in m_roots.
        JSC::MarkedArgumentBuffer m_roots;
        WTF::HashMap<uintptr_t, unsigned> m_seen;
        WTF::HashMap<uintptr_t, unsigned> m_transfer_ports;
        // Held by reference, so a buffer whose JSArrayBuffer is collected stays valid until the commit detaches it.
        WTF::HashSet<WTF::RefPtr<ArrayBuffer>> m_transfer_buffers;
        // Both cells of each entry are rooted in m_roots.
        WTF::Vector<WebApiMessagePortTransfer> m_port_transfers;
        unsigned m_depth { 0 };
        unsigned m_entry_count { 0 };
    };

} // namespace

bool structuredCloneAndCommitForWebApiMessage(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    JSC::JSValue message, JSC::JSValue transfer, JSC::JSObject* blocked_sender,
    const WTF::ScopedLambda<bool()>& before_commit, JSC::JSValue& out_value, JSC::JSObject*& out_ports)
{
    StructuredCloneContext context(global_object, scope, blocked_sender);
    if (!transfer.isUndefined()) {
        if (!context.parseTransferList(transfer))
            return false;
        RETURN_IF_EXCEPTION(scope, false);
    }
    JSC::JSValue value = context.cloneRoot(message);
    RETURN_IF_EXCEPTION(scope, false);
    if (!context.validateTransfers())
        return false;
    RETURN_IF_EXCEPTION(scope, false);
    auto* ports = context.transferredPortsArray();
    RETURN_IF_EXCEPTION(scope, false);
    if (!before_commit())
        return false;
    RETURN_IF_EXCEPTION(scope, false);
    if (!context.commitTransfers())
        return false;
    RETURN_IF_EXCEPTION(scope, false);
    out_value = value;
    out_ports = ports;
    return true;
}

JSC_DEFINE_HOST_FUNCTION(structuredClone, (JSGlobalObject * global_object, CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    if (call_frame->argumentCount() < 1)
        return throwVMTypeError(global_object, scope, "structuredClone requires a value"_s);

    StructuredCloneContext context(global_object, scope);
    if (!context.parseOptions(call_frame->argument(1)))
        return JSValue::encode(jsUndefined());
    RETURN_IF_EXCEPTION(scope, {});

    JSValue cloned = context.cloneRoot(call_frame->argument(0));
    RETURN_IF_EXCEPTION(scope, {});

    if (!context.validateTransfers())
        return JSValue::encode(jsUndefined());
    RETURN_IF_EXCEPTION(scope, {});

    if (!context.commitTransfers())
        return JSValue::encode(jsUndefined());
    RETURN_IF_EXCEPTION(scope, {});

    return JSValue::encode(cloned);
}

} // namespace Collo::HostFunctions

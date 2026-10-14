// The promise reactions of every stream cell: one host function per StreamReaction and outcome per realm, created when
// the realm installs the stream classes. Runs on the VM thread.
//
// A reaction registered with performPromiseThenWithContext keeps its context cell in the engine's reaction record
// and passes it to the handler as the second argument, so the handlers hold no state of their own and one set serves
// every stream of the realm. The engine's microtask owner hook (runtime/patches/webkit, the microtask owner context
// patch) tags these reactions with the owner that registered them, as it tags every other, so a reaction runs under
// the request whose operation registered it. The handlers are never exposed to script: only the engine calls them,
// with the context the registration chose.
//
// A handler whose registration passed no result promise handles every failure itself and leaves no exception behind
// but a termination, which stays pending so the VM keeps unwinding. A handler with a result promise throws to reject
// it.

#include "host_functions/webapi/streams/pipe_to_private.h"
#include "host_functions/webapi/streams/transform_stream_private.h"

#include <utility>

namespace Collo::HostFunctions {
namespace {

    JSC::EncodedJSValue runStreamReaction(JSC::JSGlobalObject* global_object, StreamReaction reaction, bool fulfilled,
        JSC::JSValue value, JSC::JSValue context)
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        JSC::JSCell* cell = context.isCell() ? context.asCell() : nullptr;
        ASSERT(cell);
        switch (reaction) {
        case StreamReaction::ReadableStart:
            if (auto* controller = dynamicDowncast<JSColloReadableStreamController>(cell)) {
                if (fulfilled)
                    controller->startFinished(global_object);
                else
                    controller->startFailed(global_object, value);
            }
            break;
        case StreamReaction::ReadablePull:
            if (auto* controller = dynamicDowncast<JSColloReadableStreamController>(cell)) {
                if (fulfilled)
                    controller->pullSettled(global_object);
                else
                    controller->pullFailed(global_object, value);
            }
            break;
        case StreamReaction::NativePull:
            if (auto* stream = dynamicDowncast<JSColloReadableStream>(cell)) {
                if (fulfilled)
                    stream->finishNativePull(global_object, value);
                else
                    stream->rejectNativePull(global_object, value);
            }
            break;
        case StreamReaction::CancelSettled:
            if (!fulfilled)
                return JSC::JSValue::encode(JSC::throwException(global_object, scope, value));
            break;
        case StreamReaction::TeeRead:
            if (auto* tee = dynamicDowncast<JSColloReadableStreamTeeState>(cell)) {
                if (fulfilled)
                    tee->readFulfilled(global_object, value);
                else
                    tee->readRejected(global_object, value);
            }
            break;
        case StreamReaction::TeeClosed:
            // A close reaches the branches through the tee's read of the original, which also delivers the last chunk.
            if (!fulfilled) {
                if (auto* tee = dynamicDowncast<JSColloReadableStreamTeeState>(cell))
                    tee->errorBranches(global_object, value);
            }
            break;
        case StreamReaction::FromNext:
            if (auto* from = dynamicDowncast<JSColloReadableStreamFromState>(cell)) {
                if (fulfilled)
                    from->nextFulfilled(global_object, value);
                else
                    from->nextRejected(global_object, value);
            }
            break;
        case StreamReaction::FromValue:
            if (auto* from = dynamicDowncast<JSColloReadableStreamFromState>(cell)) {
                if (fulfilled)
                    from->valueFulfilled(global_object, value);
                else
                    from->valueRejected(global_object, value);
            }
            break;
        case StreamReaction::FromReturn:
            // ReadableStreamFromIterable's cancel algorithm: the iterator's return() must produce an object.
            if (!fulfilled)
                return JSC::JSValue::encode(JSC::throwException(global_object, scope, value));
            if (!value.isObject())
                return JSC::throwVMTypeError(
                    global_object, scope, "ReadableStream.from iterator return result must be an object"_s);
            break;
        case StreamReaction::IteratorNext: {
            auto* iterator = dynamicDowncast<JSColloReadableStreamAsyncIterator>(cell);
            if (!iterator)
                break;
            if (!fulfilled) {
                iterator->releaseReader(global_object);
                RETURN_IF_EXCEPTION(scope, {});
                return JSC::JSValue::encode(JSC::throwException(global_object, scope, value));
            }
            bool done = false;
            JSC::JSValue error;
            if (!readResultDone(global_object, value, done, error)) {
                iterator->releaseReader(global_object);
                RETURN_IF_EXCEPTION(scope, {});
                return JSC::JSValue::encode(JSC::throwException(global_object, scope, error));
            }
            if (done) {
                iterator->releaseReader(global_object);
                RETURN_IF_EXCEPTION(scope, {});
            }
            return JSC::JSValue::encode(value);
        }
        case StreamReaction::IteratorReturn:
            // The context is the {value, done} result return() resolves with once what it waited for fulfills.
            if (!fulfilled)
                return JSC::JSValue::encode(JSC::throwException(global_object, scope, value));
            return JSC::JSValue::encode(context);
        case StreamReaction::BodyConsumerRead:
            if (auto* consumer = dynamicDowncast<JSColloBodyConsumer>(cell)) {
                if (fulfilled)
                    consumer->readFulfilled(global_object, value);
                else
                    consumer->readRejected(global_object, value);
            }
            break;
        case StreamReaction::WritableStart:
            if (auto* stream = dynamicDowncast<JSColloWritableStream>(cell)) {
                if (fulfilled)
                    stream->finishStart(global_object);
                else
                    stream->startFailed(global_object, value);
            }
            break;
        case StreamReaction::WritableWrite:
            if (auto* stream = dynamicDowncast<JSColloWritableStream>(cell)) {
                if (fulfilled)
                    stream->finishWrite(global_object);
                else
                    stream->rejectWrite(global_object, value);
            }
            break;
        case StreamReaction::WritableClose:
            if (auto* stream = dynamicDowncast<JSColloWritableStream>(cell)) {
                if (fulfilled)
                    stream->finishClose(global_object);
                else
                    stream->rejectClose(global_object, value);
            }
            break;
        case StreamReaction::WritableAbort:
            if (auto* stream = dynamicDowncast<JSColloWritableStream>(cell)) {
                if (fulfilled)
                    stream->finishAbort(global_object);
                else
                    stream->rejectAbort(global_object, value);
            }
            break;
        case StreamReaction::TransformResult:
            if (auto* transform = dynamicDowncast<JSColloTransformStream>(cell))
                RELEASE_AND_RETURN(
                    scope, JSC::JSValue::encode(transform->transformSettled(global_object, scope, value, fulfilled)));
            break;
        case StreamReaction::TransformFlush:
            if (auto* transform = dynamicDowncast<JSColloTransformStream>(cell))
                RELEASE_AND_RETURN(
                    scope, JSC::JSValue::encode(transform->flushSettled(global_object, scope, value, fulfilled)));
            break;
        case StreamReaction::PipeRead:
            if (auto* pipe = dynamicDowncast<JSColloPipeToState>(cell)) {
                if (fulfilled)
                    pipe->readFulfilled(global_object, value);
                else
                    pipe->readRejected(global_object, value);
            }
            break;
        case StreamReaction::PipeWrite:
            if (auto* pipe = dynamicDowncast<JSColloPipeToState>(cell))
                pipe->writeSettled(global_object);
            break;
        case StreamReaction::PipeStreamChange:
            if (auto* pipe = dynamicDowncast<JSColloPipeToState>(cell))
                pipe->advance(global_object);
            break;
        case StreamReaction::PipeShutdown:
            if (auto* pipe = dynamicDowncast<JSColloPipeToState>(cell)) {
                if (fulfilled)
                    pipe->shutdownActionSettled(global_object);
                else
                    pipe->shutdownActionRejected(global_object, value);
            }
            break;
        }
        RETURN_IF_EXCEPTION(scope, {});
        return JSC::JSValue::encode(JSC::jsUndefined());
    }

    template <StreamReaction reaction, bool fulfilled>
    JSC::EncodedJSValue JSC_HOST_CALL_ATTRIBUTES streamReactionHandler(
        JSC::JSGlobalObject* global_object, JSC::CallFrame* call_frame)
    {
        return runStreamReaction(global_object, reaction, fulfilled, call_frame->argument(0), call_frame->argument(1));
    }

    JSC::JSFunction* createStreamFunction(JSC::VM& vm, Collo::GlobalObject* global_object, JSC::NativeFunction function)
    {
        return JSC::JSFunction::create(
            vm, global_object, 1, WTF::emptyString(), function, JSC::ImplementationVisibility::Private);
    }

    template <size_t... indices>
    void createReactionFunctions(Collo::GlobalObject* global_object, JSC::VM& vm, std::index_sequence<indices...>)
    {
        auto& functions = global_object->webApiCache().stream_functions;
        ((functions[2 * indices].set(vm,
              createStreamFunction(
                  vm, global_object, streamReactionHandler<static_cast<StreamReaction>(indices), true>)),
             functions[2 * indices + 1].set(vm,
                 createStreamFunction(
                     vm, global_object, streamReactionHandler<static_cast<StreamReaction>(indices), false>))),
            ...);
    }

} // namespace

void installStreamFunctions(Collo::GlobalObject* global_object, JSC::VM& vm)
{
    createReactionFunctions(global_object, vm, std::make_index_sequence<stream_reaction_count> {});
}

void reactToPromise(JSC::JSGlobalObject* global_object, JSC::JSPromise* promise, StreamReaction reaction,
    JSC::JSCell* context, JSC::JSValue result)
{
    auto& functions = uncheckedDowncast<Collo::GlobalObject>(global_object)->webApiCache().stream_functions;
    const size_t index = 2 * static_cast<size_t>(reaction);
    ASSERT(functions[index].get());
    promise->performPromiseThenWithContext(
        global_object->vm(), global_object, functions[index].get(), functions[index + 1].get(), result, context);
}

JSC::JSPromise* promiseResolvedWith(JSC::JSGlobalObject* global_object, JSC::JSValue value)
{
    if (auto* promise = dynamicDowncast<JSC::JSPromise>(value))
        return promise;
    return JSC::JSPromise::resolvedPromise(global_object, value);
}

JSC::JSPromise* promiseThenUndefined(JSC::JSGlobalObject* global_object, JSC::JSValue value, JSC::JSCell* context)
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* promise = dynamicDowncast<JSC::JSPromise>(value);
    if (!promise) {
        if (!value.isObject())
            RELEASE_AND_RETURN(scope, JSC::JSPromise::resolvedPromise(global_object, JSC::jsUndefined()));
        promise = JSC::JSPromise::resolvedPromise(global_object, value);
        RETURN_IF_EXCEPTION(scope, nullptr);
    }
    auto* result = Collo::newPromise(global_object);
    reactToPromise(global_object, promise, StreamReaction::CancelSettled, context, result);
    return result;
}

} // namespace Collo::HostFunctions

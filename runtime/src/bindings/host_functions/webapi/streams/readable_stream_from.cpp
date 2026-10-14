// ReadableStream.from (ReadableStreamFromIterable): a stream of high-water mark 0 whose controller's source is the
// iterator's state cell. Runs on the VM thread.
//
// Each pull calls the iterator's next method. An async iterator's result is awaited through a promise; a sync
// iterator's result is read at once and its value awaited even when done, as ECMA-262's
// AsyncFromSyncIteratorContinuation does. When a value that is not done rejects, or cannot become a promise, the sync
// iterator is closed as IteratorClose closes it after a throw: the stream errors with that reason whatever the return
// method does. The iterator, its next method and every result are script, so the state is read again after each call,
// and clear() makes every later step a no-op once the iterator is exhausted, fails or is canceled.

#include "host_functions/webapi/streams/readable_stream_private.h"

namespace Collo::HostFunctions {

JSColloReadableStreamFromState* JSColloReadableStreamFromState::create(JSC::VM& vm, Collo::GlobalObject* global_object,
    JSC::JSObject* iterator, JSC::JSValue next, bool is_async, JSColloReadableStreamDefaultController* controller)
{
    auto* object = new (NotNull, JSC::allocateCell<JSColloReadableStreamFromState>(vm))
        JSColloReadableStreamFromState(vm, global_object->readableStreamFromStateStructure(), is_async);
    object->finishCreation(vm, iterator, next, controller);
    return object;
}

void JSColloReadableStreamFromState::finishCreation(
    JSC::VM& vm, JSC::JSObject* iterator, JSC::JSValue next, JSColloReadableStreamDefaultController* controller)
{
    Base::finishCreation(vm);
    ASSERT(inherits(info()));
    m_iterator.set(vm, this, iterator);
    m_next.set(vm, this, next);
    m_controller.set(vm, this, controller);
}

void JSColloReadableStreamFromState::clear()
{
    m_done = true;
    m_iterator.setUndefined();
    m_next.setUndefined();
}

void JSColloReadableStreamFromState::finishPull(JSC::JSGlobalObject* global_object)
{
    if (auto* controller = m_controller.get())
        controller->pullSettled(global_object);
}

void JSColloReadableStreamFromState::fail(JSC::JSGlobalObject* global_object, JSC::JSValue reason)
{
    clear();
    if (auto* controller = m_controller.get())
        controller->pullFailed(global_object, reason);
}

void JSColloReadableStreamFromState::pull(JSC::JSGlobalObject* global_object)
{
    if (m_done) {
        finishPull(global_object);
        return;
    }
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    JSC::JSValue iterator = m_iterator.get();
    JSC::JSValue next = m_next.get();
    if (!iterator.isObject() || !valueIsCallable(next)) {
        fail(global_object, JSC::createTypeError(global_object, "ReadableStream.from iterator is unavailable"_s));
        return;
    }
    JSC::MarkedArgumentBuffer arguments;
    auto call_data = JSC::getCallData(next);
    JSC::JSValue next_result = JSC::call(global_object, next.getObject(), call_data, iterator, arguments);
    if (scope.exception()) {
        JSC::JSValue exception = scope.exception()->value();
        if (!scope.tryClearException())
            return;
        fail(global_object, exception);
        return;
    }
    if (!m_is_async) {
        processIteratorResult(global_object, next_result, true);
        return;
    }
    auto* next_promise = JSC::JSPromise::resolvedPromise(global_object, next_result);
    if (scope.exception()) {
        JSC::JSValue exception = scope.exception()->value();
        if (!scope.tryClearException())
            return;
        fail(global_object, exception);
        return;
    }
    reactToPromise(global_object, next_promise, StreamReaction::FromNext, this);
}

void JSColloReadableStreamFromState::processIteratorResult(
    JSC::JSGlobalObject* global_object, JSC::JSValue result, bool await_value)
{
    if (m_done) {
        finishPull(global_object);
        return;
    }
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto fail_with_exception = [&] {
        JSC::JSValue exception = scope.exception()->value();
        if (!scope.tryClearException())
            return;
        fail(global_object, exception);
    };

    if (!result.isObject()) {
        fail(global_object,
            JSC::createTypeError(global_object, "ReadableStream.from iterator result must be an object"_s));
        return;
    }
    JSC::JSValue done_value = result.get(global_object, vm.propertyNames->done);
    if (scope.exception()) {
        fail_with_exception();
        return;
    }
    const bool done = done_value.toBoolean(global_object);
    if (scope.exception()) {
        fail_with_exception();
        return;
    }
    if (done && !await_value) {
        finishIteration(global_object);
        return;
    }

    JSC::JSValue value = result.get(global_object, vm.propertyNames->value);
    if (scope.exception()) {
        fail_with_exception();
        return;
    }
    if (!await_value) {
        valueFulfilled(global_object, value);
        return;
    }
    auto* value_promise = JSC::JSPromise::resolvedPromise(global_object, value);
    if (scope.exception()) {
        JSC::JSValue exception = scope.exception()->value();
        if (!scope.tryClearException())
            return;
        // AsyncFromSyncIteratorContinuation closes the iterator when PromiseResolve throws, unless it was done.
        if (!done && !closeIteratorKeepingError(global_object))
            return;
        fail(global_object, exception);
        return;
    }
    if (done) {
        clear();
        m_value_ends_iteration = true;
    }
    reactToPromise(global_object, value_promise, StreamReaction::FromValue, this);
}

void JSColloReadableStreamFromState::finishIteration(JSC::JSGlobalObject* global_object)
{
    auto* controller = m_controller.get();
    clear();
    if (controller) {
        if (auto* stream = controller->stream())
            stream->close(global_object);
        if (!noExceptionPending(global_object->vm()))
            return;
    }
    finishPull(global_object);
}

bool JSColloReadableStreamFromState::closeIteratorKeepingError(JSC::JSGlobalObject* global_object)
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
    JSC::JSValue iterator = m_iterator.get();
    if (!iterator.isObject())
        return true;
    JSC::JSValue return_method = iterator.get(global_object, vm.propertyNames->returnKeyword);
    if (!scope.exception() && valueIsCallable(return_method)) {
        JSC::MarkedArgumentBuffer arguments;
        auto call_data = JSC::getCallData(return_method);
        JSC::call(global_object, return_method.getObject(), call_data, iterator, arguments);
    }
    return !scope.exception() || scope.clearExceptionExceptTermination();
}

void JSColloReadableStreamFromState::nextFulfilled(JSC::JSGlobalObject* global_object, JSC::JSValue iterator_result)
{
    processIteratorResult(global_object, iterator_result, false);
}

void JSColloReadableStreamFromState::nextRejected(JSC::JSGlobalObject* global_object, JSC::JSValue reason)
{
    if (m_done) {
        finishPull(global_object);
        return;
    }
    fail(global_object, reason);
}

void JSColloReadableStreamFromState::valueFulfilled(JSC::JSGlobalObject* global_object, JSC::JSValue value)
{
    if (m_value_ends_iteration) {
        m_value_ends_iteration = false;
        finishIteration(global_object);
        return;
    }
    if (m_done) {
        finishPull(global_object);
        return;
    }
    auto* controller = m_controller.get();
    auto* stream = controller ? controller->stream() : nullptr;
    if (!stream || stream->state() != StreamState::Readable) {
        finishPull(global_object);
        return;
    }
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    if (!stream->enqueue(global_object, scope, value)) {
        JSC::JSValue exception = scope.exception() ? scope.exception()->value() : JSC::JSValue();
        if (scope.exception() && !scope.tryClearException())
            return;
        fail(global_object, exception ? exception : JSC::createOutOfMemoryError(global_object));
        return;
    }
    finishPull(global_object);
}

void JSColloReadableStreamFromState::valueRejected(JSC::JSGlobalObject* global_object, JSC::JSValue reason)
{
    // A value that came with done true errors the stream without closing the exhausted iterator.
    if (m_value_ends_iteration) {
        m_value_ends_iteration = false;
        fail(global_object, reason);
        return;
    }
    if (m_done) {
        finishPull(global_object);
        return;
    }
    // AsyncFromSyncIteratorContinuation closes the sync iterator when a value it yielded rejects. Only sync iterators
    // await their values, so this is one.
    if (!closeIteratorKeepingError(global_object))
        return;
    fail(global_object, reason);
}

JSC::JSValue JSColloReadableStreamFromState::cancel(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue reason)
{
    if (m_done)
        return JSC::jsUndefined();
    auto& vm = global_object->vm();
    JSC::JSValue iterator = m_iterator.get();
    // Done first, so no pull the return method triggers reaches the iterator.
    clear();
    if (!iterator.isObject()) {
        JSC::throwVMTypeError(global_object, scope, "ReadableStream.from iterator is unavailable"_s);
        return {};
    }
    JSC::JSValue return_method = iterator.get(global_object, vm.propertyNames->returnKeyword);
    RETURN_IF_EXCEPTION(scope, {});
    if (return_method.isUndefinedOrNull())
        return JSC::jsUndefined();
    if (!valueIsCallable(return_method)) {
        JSC::throwVMTypeError(global_object, scope, "ReadableStream.from iterator return must be callable"_s);
        return {};
    }
    JSC::MarkedArgumentBuffer arguments;
    arguments.append(reason);
    if (arguments.hasOverflowed()) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return {};
    }
    auto call_data = JSC::getCallData(return_method);
    JSC::JSValue return_result = JSC::call(global_object, return_method.getObject(), call_data, iterator, arguments);
    RETURN_IF_EXCEPTION(scope, {});
    auto* return_promise = JSC::JSPromise::resolvedPromise(global_object, return_result);
    RETURN_IF_EXCEPTION(scope, {});
    auto* result = Collo::newPromise(global_object);
    reactToPromise(global_object, return_promise, StreamReaction::FromReturn, this, result);
    return result;
}

} // namespace Collo::HostFunctions

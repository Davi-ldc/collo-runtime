// User Timing on the VM thread: PerformanceEntry, PerformanceMark and PerformanceMeasure, and performance.mark,
// measure, clearMarks and clearMeasures. A mark name passed to measure() resolves to the latest buffered mark with
// that name, and a SyntaxError reports that none exists. `new PerformanceMark()` creates an entry without buffering
// it; PerformanceEntry and PerformanceMeasure cannot be constructed. An entry's `detail` is the value script passed,
// stored as is.

#include "host_functions/webapi/platform/performance/private.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/IdentifierInlines.h>
#include <JavaScriptCore/InternalFunction.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSObject.h>
#include <JavaScriptCore/JSString.h>
#include <JavaScriptCore/SlotVisitorMacros.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/WTFString.h>

#include <optional>

namespace Collo::HostFunctions {

using JSC::EncodedJSValue;
using JSC::JSValue;
using WTF::String;
using namespace JSC;

const JSC::ClassInfo JSColloPerformanceEntry::s_info
    = { "PerformanceEntry"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloPerformanceEntry) };
const JSC::ClassInfo JSColloPerformanceMark::s_info = { "PerformanceMark"_s, &JSColloPerformanceEntry::s_info, nullptr,
    nullptr, CREATE_METHOD_TABLE(JSColloPerformanceMark) };
const JSC::ClassInfo JSColloPerformanceMeasure::s_info = { "PerformanceMeasure"_s, &JSColloPerformanceEntry::s_info,
    nullptr, nullptr, CREATE_METHOD_TABLE(JSColloPerformanceMeasure) };

template <typename Visitor> void JSColloPerformanceEntry::visitChildrenImpl(JSC::JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloPerformanceEntry*>(cell);
    ASSERT_GC_OBJECT_INHERITS(this_object, info());
    Base::visitChildren(this_object, visitor);
    visitor.append(this_object->m_detail);
}

DEFINE_VISIT_CHILDREN(JSColloPerformanceEntry);

template <typename Visitor> void JSColloPerformanceMark::visitChildrenImpl(JSC::JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloPerformanceMark*>(cell);
    ASSERT_GC_OBJECT_INHERITS(this_object, info());
    Base::visitChildren(this_object, visitor);
}

DEFINE_VISIT_CHILDREN(JSColloPerformanceMark);

template <typename Visitor> void JSColloPerformanceMeasure::visitChildrenImpl(JSC::JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloPerformanceMeasure*>(cell);
    ASSERT_GC_OBJECT_INHERITS(this_object, info());
    Base::visitChildren(this_object, visitor);
}

DEFINE_VISIT_CHILDREN(JSColloPerformanceMeasure);

static JSColloPerformanceEntry* requirePerformanceEntry(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
{
    if (auto* entry = dynamicDowncast<JSColloPerformanceEntry>(value))
        return entry;
    JSC::throwVMTypeError(global_object, scope, "PerformanceEntry method called on incompatible receiver"_s);
    return nullptr;
}

// Converts a timestamp argument. A negative or non-finite value throws a TypeError, and the conversion can run
// script.
static std::optional<double> nonNegativeFiniteNumber(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
{
    double number = value.toNumber(global_object);
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (!std::isfinite(number) || number < 0) {
        JSC::throwVMTypeError(global_object, scope, "Performance timestamp must be finite and non-negative"_s);
        return std::nullopt;
    }
    return number;
}

static JSValue maybeDetail(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSObject* options)
{
    auto& vm = global_object->vm();
    auto detail = options->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "detail"_s));
    RETURN_IF_EXCEPTION(scope, {});
    return detail ? detail : JSC::jsNull();
}

struct ParsedMarkOptions {
    double start_time { 0 };
    JSValue detail { JSC::jsNull() };
};

// Reads mark()'s options: startTime defaults to now and detail to null. Returns nullopt with an exception pending.
static std::optional<ParsedMarkOptions> parseMarkOptions(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSColloPerformance& performance, JSValue options_value)
{
    ParsedMarkOptions options;
    options.start_time = performance.nowMs(global_object);
    if (options_value.isUndefinedOrNull())
        return options;

    auto* object = dynamicDowncast<JSC::JSObject>(options_value);
    if (!object) {
        JSC::throwVMTypeError(global_object, scope, "PerformanceMark options must be an object"_s);
        return std::nullopt;
    }

    auto& vm = global_object->vm();
    auto start_time = object->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "startTime"_s));
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (start_time) {
        auto parsed_start = nonNegativeFiniteNumber(global_object, scope, start_time);
        if (!parsed_start)
            return std::nullopt;
        options.start_time = *parsed_start;
    }

    options.detail = maybeDetail(global_object, scope, object);
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    return options;
}

struct MeasureBound {
    bool has_value { false };
    double value { 0 };
};

// Converts a start or end bound of measure(): undefined leaves it unset, a string names a mark, and any other value
// is a timestamp. Returns nullopt with an exception pending.
static std::optional<MeasureBound> measureBoundFromValue(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSColloPerformance& performance, JSValue value)
{
    MeasureBound bound;
    if (value.isUndefined())
        return bound;
    if (value.isString()) {
        auto name = valueToWebApiString(global_object, scope, value);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        auto* mark = performance.findLatestMark(name);
        if (!mark) {
            JSC::throwSyntaxError(global_object, scope, WTF::makeString("No mark named '"_s, name, "' exists"_s));
            return std::nullopt;
        }
        bound.has_value = true;
        bound.value = mark->startTime();
        return bound;
    }

    auto parsed = nonNegativeFiniteNumber(global_object, scope, value);
    if (!parsed)
        return std::nullopt;
    bound.has_value = true;
    bound.value = *parsed;
    return bound;
}

struct ParsedMeasureOptions {
    double start_time { 0 };
    double duration { 0 };
    JSValue detail { JSC::jsNull() };
};

static double nonNegativeDuration(double start, double end) { return std::max(0.0, end - start); }

// Resolves measure()'s start time and duration from its second and third arguments. A `duration` option measures
// forward from the given start or back from the given end. Otherwise a missing start is the time origin, a missing
// end is now, and an end before the start gives a zero duration. Returns nullopt with an exception pending.
static std::optional<ParsedMeasureOptions> parseMeasureOptions(JSC::JSGlobalObject* global_object,
    JSC::ThrowScope& scope, JSColloPerformance& performance, JSValue start_or_options, JSValue end_mark)
{
    const double now = performance.nowMs(global_object);
    ParsedMeasureOptions options;
    options.duration = now;

    if (start_or_options.isUndefinedOrNull()) {
        if (!end_mark.isUndefined()) {
            auto end_bound = measureBoundFromValue(global_object, scope, performance, end_mark);
            if (!end_bound)
                return std::nullopt;
            options.duration = end_bound->has_value ? end_bound->value : now;
        }
        return options;
    }

    if (auto* object = dynamicDowncast<JSC::JSObject>(start_or_options)) {
        auto& vm = global_object->vm();
        auto start = object->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "start"_s));
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        auto end = object->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "end"_s));
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        auto duration = object->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "duration"_s));
        RETURN_IF_EXCEPTION(scope, std::nullopt);

        MeasureBound start_bound;
        MeasureBound end_bound;
        if (start) {
            auto parsed = measureBoundFromValue(global_object, scope, performance, start);
            if (!parsed)
                return std::nullopt;
            start_bound = *parsed;
        }
        if (end) {
            auto parsed = measureBoundFromValue(global_object, scope, performance, end);
            if (!parsed)
                return std::nullopt;
            end_bound = *parsed;
        }

        if (duration) {
            if (start && end) {
                JSC::throwVMTypeError(global_object, scope,
                    "Performance measure options cannot specify start, end, and duration together"_s);
                return std::nullopt;
            }
            auto parsed_duration = nonNegativeFiniteNumber(global_object, scope, duration);
            if (!parsed_duration)
                return std::nullopt;
            options.duration = *parsed_duration;
            if (start_bound.has_value)
                options.start_time = start_bound.value;
            else if (end_bound.has_value)
                options.start_time = end_bound.value - options.duration;
            else {
                JSC::throwVMTypeError(global_object, scope, "Performance measure duration requires a start or end"_s);
                return std::nullopt;
            }
        } else {
            options.start_time = start_bound.has_value ? start_bound.value : 0;
            const double end_time = end_bound.has_value ? end_bound.value : now;
            options.duration = nonNegativeDuration(options.start_time, end_time);
        }

        options.detail = maybeDetail(global_object, scope, object);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        return options;
    }

    auto start_name = valueToWebApiString(global_object, scope, start_or_options);
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    auto* start_mark = performance.findLatestMark(start_name);
    if (!start_mark) {
        JSC::throwSyntaxError(global_object, scope, WTF::makeString("No mark named '"_s, start_name, "' exists"_s));
        return std::nullopt;
    }

    options.start_time = start_mark->startTime();
    if (end_mark.isUndefined()) {
        options.duration = nonNegativeDuration(options.start_time, now);
        return options;
    }

    auto end_name = valueToWebApiString(global_object, scope, end_mark);
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    auto* end = performance.findLatestMark(end_name);
    if (!end) {
        JSC::throwSyntaxError(global_object, scope, WTF::makeString("No mark named '"_s, end_name, "' exists"_s));
        return std::nullopt;
    }
    options.duration = nonNegativeDuration(options.start_time, end->startTime());
    return options;
}

static JSC::Structure* performanceMarkStructureForNewTarget(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::CallFrame* call_frame)
{
    auto* performance = performanceSingleton(global_object);
    RELEASE_ASSERT(performance);
    auto* new_target = call_frame->newTarget().getObject();
    auto* constructor = call_frame->jsCallee();
    if (!new_target || new_target == constructor)
        return performance->markStructure();
    auto* structure
        = JSC::InternalFunction::createSubclassStructure(global_object, new_target, performance->markStructure());
    RETURN_IF_EXCEPTION(scope, nullptr);
    return structure;
}

JSC_DEFINE_HOST_FUNCTION(performanceEntryConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    return JSC::throwVMTypeError(global_object, scope, "PerformanceEntry is not constructable"_s);
}

JSC_DEFINE_HOST_FUNCTION(performanceEntryConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    return JSC::throwVMTypeError(global_object, scope, "PerformanceEntry is not constructable"_s);
}

JSC_DEFINE_HOST_FUNCTION(performanceMarkConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    return JSC::throwVMTypeError(global_object, scope, "PerformanceMark constructor requires 'new'"_s);
}

JSC_DEFINE_HOST_FUNCTION(
    performanceMarkConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    if (!requireArgumentCount(global_object, scope, call_frame, 1, "PerformanceMark constructor requires a name"_s))
        return {};

    auto* performance = performanceSingleton(global_object);
    RELEASE_ASSERT(performance);
    auto name = argumentToWebApiString(global_object, scope, call_frame, 0);
    RETURN_IF_EXCEPTION(scope, {});
    auto options = parseMarkOptions(global_object, scope, *performance, call_frame->argument(1));
    if (!options)
        return {};
    RETURN_IF_EXCEPTION(scope, {});
    auto* structure = performanceMarkStructureForNewTarget(global_object, scope, call_frame);
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(
        JSColloPerformanceMark::create(vm, structure, WTF::move(name), options->start_time, options->detail));
}

JSC_DEFINE_HOST_FUNCTION(performanceMeasureConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    return JSC::throwVMTypeError(global_object, scope, "PerformanceMeasure is not constructable"_s);
}

JSC_DEFINE_HOST_FUNCTION(performanceMeasureConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    return JSC::throwVMTypeError(global_object, scope, "PerformanceMeasure is not constructable"_s);
}

#define COLLO_PERFORMANCE_ENTRY_GETTER(name, expression)                                                               \
    JSC_DEFINE_HOST_FUNCTION(name, (JSC::JSGlobalObject * global_object, JSC::CallFrame * call_frame))                 \
    {                                                                                                                  \
        auto& vm = global_object->vm();                                                                                \
        auto scope = DECLARE_THROW_SCOPE(vm);                                                                          \
        auto* entry = requirePerformanceEntry(global_object, scope, call_frame->thisValue());                          \
        RETURN_IF_EXCEPTION(scope, {});                                                                                \
        if (!entry)                                                                                                    \
            return {};                                                                                                 \
        return JSValue::encode(expression);                                                                            \
    }

COLLO_PERFORMANCE_ENTRY_GETTER(performanceEntryGetName, JSC::jsString(vm, entry->name()))
COLLO_PERFORMANCE_ENTRY_GETTER(performanceEntryGetEntryType, JSC::jsString(vm, entry->entryType()))
COLLO_PERFORMANCE_ENTRY_GETTER(performanceEntryGetStartTime, JSC::jsNumber(entry->startTime()))
COLLO_PERFORMANCE_ENTRY_GETTER(performanceEntryGetDuration, JSC::jsNumber(entry->duration()))
COLLO_PERFORMANCE_ENTRY_GETTER(performanceEntryGetDetail, entry->detail())

#undef COLLO_PERFORMANCE_ENTRY_GETTER

JSC_DEFINE_HOST_FUNCTION(performanceEntryToJSON, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* entry = requirePerformanceEntry(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    if (!entry)
        return {};

    auto* result = JSC::constructEmptyObject(global_object, global_object->objectPrototype(), 4);
    result->putDirect(vm, JSC::Identifier::fromString(vm, "name"_s), JSC::jsString(vm, entry->name()));
    result->putDirect(vm, JSC::Identifier::fromString(vm, "entryType"_s), JSC::jsString(vm, entry->entryType()));
    result->putDirect(vm, JSC::Identifier::fromString(vm, "startTime"_s), JSC::jsNumber(entry->startTime()));
    result->putDirect(vm, JSC::Identifier::fromString(vm, "duration"_s), JSC::jsNumber(entry->duration()));
    return JSValue::encode(result);
}

JSC_DEFINE_HOST_FUNCTION(performanceMark, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* performance = requirePerformance(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    if (!performance)
        return {};
    if (!requireArgumentCount(global_object, scope, call_frame, 1, "performance.mark requires a name"_s))
        return {};
    performance->ensureTimeOriginForAccess();

    auto name = argumentToWebApiString(global_object, scope, call_frame, 0);
    RETURN_IF_EXCEPTION(scope, {});
    auto options = parseMarkOptions(global_object, scope, *performance, call_frame->argument(1));
    if (!options)
        return {};
    RETURN_IF_EXCEPTION(scope, {});
    auto* mark = JSColloPerformanceMark::create(
        vm, performance->markStructure(), WTF::move(name), options->start_time, options->detail);
    performance->appendEntry(global_object, vm, mark);
    return JSValue::encode(mark);
}

JSC_DEFINE_HOST_FUNCTION(performanceMeasure, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* performance = requirePerformance(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    if (!performance)
        return {};
    if (!requireArgumentCount(global_object, scope, call_frame, 1, "performance.measure requires a name"_s))
        return {};
    performance->ensureTimeOriginForAccess();

    auto name = argumentToWebApiString(global_object, scope, call_frame, 0);
    RETURN_IF_EXCEPTION(scope, {});
    auto options
        = parseMeasureOptions(global_object, scope, *performance, call_frame->argument(1), call_frame->argument(2));
    if (!options)
        return {};
    RETURN_IF_EXCEPTION(scope, {});
    auto* measure = JSColloPerformanceMeasure::create(
        vm, performance->measureStructure(), WTF::move(name), options->start_time, options->duration, options->detail);
    performance->appendEntry(global_object, vm, measure);
    return JSValue::encode(measure);
}

JSC_DEFINE_HOST_FUNCTION(performanceClearMarks, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* performance = requirePerformance(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    if (!performance)
        return {};
    performance->ensureTimeOriginForAccess();
    if (call_frame->argument(0).isUndefined())
        performance->clearEntries(std::nullopt, PerformanceEntryKind::Mark);
    else {
        auto name = argumentToWebApiString(global_object, scope, call_frame, 0);
        RETURN_IF_EXCEPTION(scope, {});
        performance->clearEntries(WTF::move(name), PerformanceEntryKind::Mark);
    }
    return JSValue::encode(JSC::jsUndefined());
}

JSC_DEFINE_HOST_FUNCTION(performanceClearMeasures, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* performance = requirePerformance(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    if (!performance)
        return {};
    performance->ensureTimeOriginForAccess();
    if (call_frame->argument(0).isUndefined())
        performance->clearEntries(std::nullopt, PerformanceEntryKind::Measure);
    else {
        auto name = argumentToWebApiString(global_object, scope, call_frame, 0);
        RETURN_IF_EXCEPTION(scope, {});
        performance->clearEntries(WTF::move(name), PerformanceEntryKind::Measure);
    }
    return JSValue::encode(JSC::jsUndefined());
}

} // namespace Collo::HostFunctions

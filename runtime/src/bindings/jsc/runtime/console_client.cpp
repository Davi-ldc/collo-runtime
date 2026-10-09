// Collo::ConsoleClient: formats console arguments into one line and enforces the per-request output budget before
// handing the line to the worker's sink. Runs in the worker on the VM thread, inside a console call frame;
// console_client.h states what the formatter promises.
//
// A pending termination exception is never cleared here. Formatting stops and the line is dropped, so the
// cooperative trap still fires at the next JS entry. Tenant strings are copied through JSString::colloCopyPrefix,
// added by WebKit patch 0003-string-prefix-copy-and-console-label-clamp, which never resolves a rope, never throws
// and copies no more than it is asked for.

#include "jsc/runtime/console_client.h"
#include "jsc/runtime/state.h"

#include <JavaScriptCore/TopExceptionScope.h>
#include <JavaScriptCore/DateInstance.h>
#include <JavaScriptCore/ErrorInstance.h>
#include <JavaScriptCore/JSArrayBufferView.h>
#include <JavaScriptCore/JSBigInt.h>
#include <JavaScriptCore/JSBoundFunction.h>
#include <JavaScriptCore/JSDateMath.h>
#include <JavaScriptCore/JSMap.h>
#include <JavaScriptCore/JSSet.h>
#include <JavaScriptCore/ProxyObject.h>
#include <JavaScriptCore/RegExpObject.h>
#include <JavaScriptCore/ScriptArguments.h>
#include <JavaScriptCore/ScriptCallStack.h>
#include <JavaScriptCore/ScriptCallStackFactory.h>
#include <JavaScriptCore/StringObject.h>
#include <JavaScriptCore/Symbol.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/StringConcatenateNumbers.h>
#include <wtf/unicode/CharacterNames.h>

using namespace JSC;
using Inspector::ScriptArguments;

namespace Collo {

WTF_MAKE_TZONE_ALLOCATED_IMPL(ConsoleClient);

namespace {

    constexpr unsigned inspect_max_depth = 2;
    constexpr unsigned inspect_max_array_items = 32;
    constexpr unsigned inspect_max_properties = 32;
    constexpr unsigned inspect_max_enumerated_properties = 4096;
    constexpr unsigned inspect_max_nested_string_units = 512;
    constexpr unsigned group_indent_max_depth = 8;
    // How far the UTF-16 unit cap sits above the sink's byte budget. Formatting stops only between pieces, so a line
    // may overshoot the unit cap by one clamped piece; keeping the cap above the byte budget leaves the final byte
    // cut to decide truncation and set the truncated flag. Used by the InspectState growth cap and by emitLine's
    // unit cut. values.cpp sizes its exception parts to the same total.
    constexpr unsigned console_unit_slack = 16;

    struct InspectState {
        JSGlobalObject* global;
        JSC::VM& vm;
        // Growth cap in UTF-16 units: the sink's byte budget plus console_unit_slack.
        size_t unit_budget;
        WTF::Vector<JSObject*, 8> seen;
        bool saw_termination { false };
    };

    bool outOfBudget(const InspectState& state, const StringBuilder& builder)
    {
        return builder.length() >= state.unit_budget;
    }

    // Clears a pending exception left by an engine operation, unless it is a termination, which must survive so the
    // cooperative trap fires at the next JS entry. Returns false when formatting must stop.
    bool settleException(InspectState& state, JSC::TopExceptionScope& scope)
    {
        if (!scope.exception())
            return true;
        if (state.vm.hasPendingTerminationException()) {
            state.saw_termination = true;
            return false;
        }
        scope.clearException();
        return true;
    }

    void appendClamped(StringBuilder& builder, const String& piece, size_t max_units)
    {
        if (piece.length() <= max_units) {
            builder.append(piece);
            return;
        }
        builder.append(StringView(piece).left(max_units));
        builder.append(horizontalEllipsis);
    }

    // Copies at most `max_units` of a JS string through colloCopyPrefix into one bounded buffer.
    String jsStringPrefixCopy(JSString* string, size_t max_units)
    {
        size_t cap = std::min<size_t>(string->length(), max_units);
        if (!cap)
            return emptyString();
        WTF::Vector<char16_t> buffer(cap);
        unsigned copied = string->colloCopyPrefix(buffer.mutableSpan());
        return String(buffer.span().first(copied));
    }

    void appendJSStringPrefix(StringBuilder& builder, JSString* string, size_t max_units)
    {
        builder.append(jsStringPrefixCopy(string, max_units));
        if (string->length() > max_units)
            builder.append(horizontalEllipsis);
    }

    // Renders `[Function: <name>]` with the name clamped. Every branch that resolves a function name goes through
    // these two, so none can drift from the format. A JSString, such as an own displayName or name or a bound
    // function's lazy name, is copied through the prefix walker; a flat String, such as an executable's or an
    // internal function's name, through appendClamped.
    void appendFunctionLabel(StringBuilder& builder, JSString* name)
    {
        builder.append("[Function: "_s);
        appendJSStringPrefix(builder, name, inspect_max_nested_string_units);
        builder.append(']');
    }

    void appendFunctionLabel(StringBuilder& builder, const String& name)
    {
        builder.append("[Function: "_s);
        appendClamped(builder, name, inspect_max_nested_string_units);
        builder.append(']');
    }

    // Reads a string-valued property with getDirect only, inspecting at most `max_hops` objects: `object`, then its
    // prototype chain. It runs no Proxy trap and no getter and reifies no lazy property. Returns null for accessor
    // storage, for a value that is not a string and for a miss.
    JSString* directStringProperty(InspectState& state, JSObject* object, PropertyName name, unsigned max_hops)
    {
        JSObject* current = object;
        for (unsigned i = 0; i < max_hops && current; ++i) {
            JSValue direct = current->getDirect(state.vm, name);
            if (direct)
                return direct.isString() ? asString(direct) : nullptr;
            JSValue proto = current->getPrototypeDirect();
            current = proto.isObject() ? asObject(proto) : nullptr;
        }
        return nullptr;
    }

    void appendJSValue(InspectState&, StringBuilder&, JSValue, unsigned depth, bool top_level);

    void appendPrimitive(InspectState& state, StringBuilder& builder, JSValue value, bool top_level)
    {
        auto scope = DECLARE_TOP_EXCEPTION_SCOPE(state.vm);
        if (value.isSymbol()) {
            builder.append("Symbol("_s);
            appendJSStringPrefix(builder, asSymbol(value)->description(state.vm), inspect_max_nested_string_units);
            builder.append(')');
            return;
        }
        // The prefix walker bounds the copy before anything is flattened, so a tenant rope never resolves past the
        // clamp; jsSubstring would resolve the whole rope whenever the prefix crosses fibers. The final byte cut
        // still sets the truncated flag.
        if (value.isString()) {
            if (top_level) {
                appendJSStringPrefix(builder, asString(value), state.unit_budget);
                return;
            }
            builder.append('\'');
            appendJSStringPrefix(builder, asString(value), inspect_max_nested_string_units);
            builder.append('\'');
            return;
        }
        // toWTFString materializes a heap BigInt's whole decimal expansion, about 19 digits per 64-bit limb, before
        // any clamp applies. One whose expansion exceeds the budget could never render whole anyway.
        if (value.isHeapBigInt() && value.asHeapBigInt()->length() > state.unit_budget / 19 + 1) {
            builder.append("[BigInt]"_s);
            return;
        }
        String text = value.toWTFString(state.global);
        if (!settleException(state, scope))
            return;
        appendClamped(builder, text, state.unit_budget);
        if (value.isBigInt())
            builder.append('n');
    }

    void appendErrorInstance(InspectState& state, StringBuilder& builder, ErrorInstance* error)
    {
        // getDirect only: sanitizedNameString and sanitizedMessageString flatten an oversized rope whole before any
        // clamp applies. A built-in error keeps `name` on its prototype, hence the few hops, and `message` is stored
        // directly at construction. The cost of the bound: an accessor `name` renders as the class name and an
        // accessor `message` not at all.
        JSString* name = directStringProperty(state, error, state.vm.propertyNames->name, 8);
        JSString* message = directStringProperty(state, error, state.vm.propertyNames->message, 8);
        if (name && name->length())
            appendJSStringPrefix(builder, name, inspect_max_nested_string_units);
        else
            builder.append(error->classInfo()->className);
        if (message && message->length()) {
            builder.append(": "_s);
            appendJSStringPrefix(builder, message, state.unit_budget);
        }
    }

    void appendDateInstance(InspectState& state, StringBuilder& builder, DateInstance* date)
    {
        double ms = date->internalNumber();
        if (!std::isfinite(ms)) {
            builder.append("Invalid Date"_s);
            return;
        }
        const auto gdt = date->gregorianDateTimeUTC(state.vm.dateCache);
        if (!gdt) {
            builder.append("Invalid Date"_s);
            return;
        }
        double milliseconds = ms - std::floor(ms / 1000.0) * 1000.0;
        builder.append(makeString(pad('0', 4, gdt.year()), '-', pad('0', 2, gdt.month() + 1), '-',
            pad('0', 2, gdt.monthDay()), 'T', pad('0', 2, gdt.hour()), ':', pad('0', 2, gdt.minute()), ':',
            pad('0', 2, gdt.second()), '.', pad('0', 3, static_cast<int>(milliseconds)), 'Z'));
    }

    void appendArray(InspectState& state, StringBuilder& builder, JSArray* array, unsigned depth)
    {
        unsigned length = array->length();
        builder.append("[ "_s);
        unsigned shown = std::min(length, inspect_max_array_items);
        for (unsigned i = 0; i < shown; ++i) {
            if (outOfBudget(state, builder) || state.saw_termination)
                break;
            if (i)
                builder.append(", "_s);
            if (array->canGetIndexQuickly(i))
                appendJSValue(state, builder, array->getIndexQuickly(i), depth + 1, false);
            else
                builder.append(horizontalEllipsis);
        }
        if (length > shown)
            builder.append(", "_s, horizontalEllipsis, ' ', length - shown, " more"_s);
        builder.append(" ]"_s);
    }

    void appendPlainObject(InspectState& state, StringBuilder& builder, JSObject* object, unsigned depth)
    {
        auto scope = DECLARE_TOP_EXCEPTION_SCOPE(state.vm);
        // classInfo's className rather than calculatedClassName, which resolves names through helpers that clear
        // exceptions internally, termination included. The cost: instances of user classes render without their
        // constructor name.
        String class_name { object->classInfo()->className };
        if (!class_name.isEmpty() && class_name != "Object"_s)
            builder.append(class_name, ' ');

        // getOwnPropertyNames fills the whole name array before inspect_max_properties can apply. Structure and
        // butterfly sizes are constant-time reads; deleted slots overcount, which only trips the guard early. Past
        // inspect_max_enumerated_properties the object renders opaquely instead of materializing its names.
        uint64_t approx_properties
            = static_cast<uint64_t>(object->structure()->inlineSize()) + object->structure()->outOfLineSize();
        if (hasIndexedProperties(object->indexingType()))
            approx_properties += object->getArrayLength();
        // Typed arrays, whose indexing type is NonArray, and boxed strings keep their elements outside both the
        // structure and the butterfly, yet getOwnPropertyNames still materializes one Identifier per element on the
        // WTF heap, which the JS heap cap does not bound.
        if (auto* view = dynamicDowncast<JSArrayBufferView>(object))
            approx_properties += view->length();
        else if (auto* boxed_string = dynamicDowncast<StringObject>(object))
            approx_properties += boxed_string->internalValue()->length();
        if (approx_properties > inspect_max_enumerated_properties) {
            builder.append("{ "_s, horizontalEllipsis, " }"_s);
            return;
        }

        PropertyNameArrayBuilder names(state.vm, PropertyNameMode::Strings, PrivateSymbolMode::Exclude);
        JSObject::getOwnPropertyNames(object, state.global, names, DontEnumPropertiesMode::Exclude);
        if (!settleException(state, scope)) {
            builder.append("{}"_s);
            return;
        }

        builder.append("{ "_s);
        unsigned shown = 0;
        for (const auto& name : names) {
            if (shown >= inspect_max_properties || outOfBudget(state, builder) || state.saw_termination)
                break;
            // Indexed data properties live in the butterfly rather than the property map, so getDirect misses them
            // even when, as in { 0: "zero" }, they are plain data. They are read through the quick path only, never
            // the slow one, which can run getters.
            JSValue direct;
            if (std::optional<uint32_t> index = parseIndex(name))
                direct = object->canGetIndexQuickly(*index) ? object->getIndexQuickly(*index) : JSValue();
            else
                direct = object->getDirect(state.vm, name);
            if (shown)
                builder.append(", "_s);
            appendClamped(builder, name.string(), inspect_max_nested_string_units);
            builder.append(": "_s);
            // getDirect returns the raw property storage, which for an accessor is the internal GetterSetter or
            // CustomGetterSetter cell; feeding that to the primitive path aborts an assert-enabled engine. Getters are
            // never invoked, only rendered opaquely.
            if (direct && !direct.isGetterSetter() && !direct.isCustomGetterSetter())
                appendJSValue(state, builder, direct, depth + 1, false);
            else
                builder.append("[Getter]"_s);
            ++shown;
        }
        if (names.size() > shown)
            builder.append(", "_s, horizontalEllipsis, ' ', static_cast<unsigned>(names.size()) - shown, " more"_s);
        builder.append(shown ? " }"_s : "}"_s);
    }

    void appendObject(InspectState& state, StringBuilder& builder, JSObject* object, unsigned depth)
    {
        if (state.seen.contains(object)) {
            builder.append("[Circular]"_s);
            return;
        }
        if (dynamicDowncast<ProxyObject>(object)) {
            builder.append("[Proxy]"_s);
            return;
        }
        if (auto* error = dynamicDowncast<ErrorInstance>(object)) {
            appendErrorInstance(state, builder, error);
            return;
        }
        if (auto* function = dynamicDowncast<JSFunction>(object)) {
            // Not calculatedDisplayName: its lazy-name path, JSBoundFunction::nameSlow, resolves rope names whole,
            // allocates unbounded "bound ..." chains and clears engine exceptions mid-format. An own displayName or
            // name is read raw and prefix-copied; an unreified name comes from the executable, a flat identifier, or
            // is omitted.
            JSString* display = directStringProperty(state, function, state.vm.propertyNames->displayName, 1);
            if (!display)
                display = directStringProperty(state, function, state.vm.propertyNames->name, 1);
            if (display && display->length()) {
                appendFunctionLabel(builder, display);
                return;
            }
            if (auto* bound = dynamicDowncast<JSBoundFunction>(function)) {
                if (JSString* lazy_name = bound->nameMayBeNull())
                    appendFunctionLabel(builder, lazy_name);
                else
                    builder.append("[Function (bound)]"_s);
                return;
            }
            String name = function->name(state.vm);
            if (name.isEmpty()) {
                builder.append("[Function (anonymous)]"_s);
                return;
            }
            appendFunctionLabel(builder, name);
            return;
        }
        if (auto* internal_function = dynamicDowncast<InternalFunction>(object)) {
            JSString* display = directStringProperty(state, internal_function, state.vm.propertyNames->displayName, 1);
            if (display && display->length()) {
                appendFunctionLabel(builder, display);
                return;
            }
            const String& name = internal_function->name();
            if (name.isEmpty()) {
                builder.append("[Function (anonymous)]"_s);
                return;
            }
            appendFunctionLabel(builder, name);
            return;
        }
        if (auto* date = dynamicDowncast<DateInstance>(object)) {
            appendDateInstance(state, builder, date);
            return;
        }
        if (auto* regexp = dynamicDowncast<RegExpObject>(object)) {
            builder.append('/');
            appendClamped(builder, regexp->regExp()->pattern(), state.unit_budget);
            builder.append('/');
            return;
        }
        if (auto* map = dynamicDowncast<JSMap>(object)) {
            builder.append("Map("_s, map->size(), ')');
            return;
        }
        if (auto* set = dynamicDowncast<JSSet>(object)) {
            builder.append("Set("_s, set->size(), ')');
            return;
        }

        if (depth >= inspect_max_depth) {
            builder.append(object->inherits<JSArray>() ? "[Array]"_s : "[Object]"_s);
            return;
        }

        state.seen.append(object);
        if (auto* array = dynamicDowncast<JSArray>(object))
            appendArray(state, builder, array, depth);
        else
            appendPlainObject(state, builder, object, depth);
        state.seen.removeLast();
    }

    void appendJSValue(InspectState& state, StringBuilder& builder, JSValue value, unsigned depth, bool top_level)
    {
        if (state.saw_termination || outOfBudget(state, builder))
            return;
        if (!value) {
            builder.append("[Empty]"_s);
            return;
        }
        if (value.isObject()) {
            appendObject(state, builder, asObject(value), depth);
            return;
        }
        appendPrimitive(state, builder, value, top_level);
    }

    // A subset of util.format: %s, %d, %i, %f, %o and %O consume an argument, %c consumes one and prints nothing,
    // and %% prints a percent sign. %j renders through the same inspector, never through user toJSON, which differs
    // from Node on purpose. A specifier with no argument left stays literal. Returns the index of the first
    // argument the format did not consume.
    size_t appendWithSubstitution(
        InspectState& state, StringBuilder& builder, const String& format, ScriptArguments& arguments)
    {
        size_t next_arg = 1;
        unsigned length = format.length();
        for (unsigned i = 0; i < length; ++i) {
            if (outOfBudget(state, builder) || state.saw_termination)
                break;
            char16_t ch = format[i];
            if (ch != '%' || i + 1 == length) {
                builder.append(ch);
                continue;
            }
            char16_t spec = format[i + 1];
            if (spec == '%') {
                builder.append('%');
                ++i;
                continue;
            }
            bool known = spec == 's' || spec == 'd' || spec == 'i' || spec == 'f' || spec == 'j' || spec == 'o'
                || spec == 'O' || spec == 'c';
            if (!known || next_arg >= arguments.argumentCount()) {
                builder.append(ch);
                continue;
            }
            JSValue value = arguments.argumentAt(next_arg++);
            ++i;
            switch (spec) {
            case 's':
                appendJSValue(state, builder, value, 1, true);
                break;
            case 'd':
            case 'i': {
                if (value.isNumber()) {
                    double number = value.asNumber();
                    if (std::isfinite(number))
                        builder.append(String::number(std::trunc(number)));
                    else
                        builder.append(String::number(number));
                } else if (value.isBigInt()) {
                    appendPrimitive(state, builder, value, true);
                } else {
                    builder.append("NaN"_s);
                }
                break;
            }
            case 'f':
                if (value.isNumber())
                    builder.append(String::number(value.asNumber()));
                else
                    builder.append("NaN"_s);
                break;
            case 'j':
            case 'o':
            case 'O':
                appendJSValue(state, builder, value, 0, false);
                break;
            case 'c':
                break;
            }
            if (state.saw_termination || outOfBudget(state, builder))
                break;
        }
        return next_arg;
    }

    void appendFormattedArguments(InspectState& state, StringBuilder& builder, ScriptArguments& arguments)
    {
        size_t count = arguments.argumentCount();
        if (!count)
            return;
        size_t first = 0;
        JSValue head = arguments.argumentAt(0);
        if (head && head.isString()) {
            // Copied through the prefix walker, so the % scan below sees at most the budget and no rope resolves
            // past it.
            String format = jsStringPrefixCopy(asString(head), state.unit_budget);
            if (format.contains('%')) {
                first = appendWithSubstitution(state, builder, format, arguments);
            } else {
                appendClamped(builder, format, state.unit_budget);
                first = 1;
            }
        }
        for (size_t i = first; i < count; ++i) {
            if (state.saw_termination || outOfBudget(state, builder))
                return;
            if (builder.length())
                builder.append(' ');
            appendJSValue(state, builder, arguments.argumentAt(i), 0, true);
        }
    }

    void appendStackTrace(InspectState& state, StringBuilder& builder)
    {
        auto call_stack = Inspector::createScriptCallStackForConsole(
            state.global, Inspector::ScriptCallStack::maxCallStackSizeToCapture);
        for (size_t i = 0; i < call_stack->size(); ++i) {
            const auto& frame = call_stack->at(i);
            String function_name = frame.functionName();
            if (function_name.isEmpty())
                function_name = "(anonymous)"_s;
            builder.append("\n    at "_s);
            appendClamped(builder, function_name, inspect_max_nested_string_units);
            if (!frame.sourceURL().isEmpty()) {
                builder.append(" ("_s);
                appendClamped(builder, frame.sourceURL(), inspect_max_nested_string_units);
                if (frame.lineNumber())
                    builder.append(':', frame.lineNumber(), ':', frame.columnNumber());
                builder.append(')');
            }
            if (outOfBudget(state, builder))
                return;
        }
    }

    uint8_t sinkLevelFor(MessageLevel level)
    {
        switch (level) {
        case MessageLevel::Debug:
            return COLLO_CONSOLE_DEBUG;
        case MessageLevel::Warning:
            return COLLO_CONSOLE_WARN;
        case MessageLevel::Error:
            return COLLO_CONSOLE_ERROR;
        case MessageLevel::Log:
        case MessageLevel::Info:
            break;
        }
        return COLLO_CONSOLE_INFO;
    }

    String labelOrDefault(const String& label) { return label.isEmpty() ? "default"_s : label; }

} // namespace

bool ConsoleClient::sinkActive() const { return owner->console_sink != nullptr; }

uint64_t ConsoleClient::currentRequestId() const
{
    if (owner->current_exec_ctx)
        return owner->current_exec_ctx->request_id;
    if (owner->boot_exec_ctx_installed)
        return owner->boot_exec_ctx.request_id;
    return 0;
}

// Past either per-request cap, ColloVm::console_request_lines_max or console_request_bytes_max, a request's further
// console calls are not formatted, and each reaches the sink only as a drop marker carrying no bytes, which the worker
// runtime counts into the log ring's dropped-lines counter.

// Output from the boot identity, the installed boot exec context, or from id 0, meaning no exec context at all,
// belongs to no request. Both identities last as long as the worker, so charging them a per-request cap would
// silence background output for good once their lifetime spend crossed it. The log ring's drop-newest policy
// already bounds that output, so it is never checked, charged or tracked.
bool ConsoleClient::budgetExempt(uint64_t request_id) const
{
    if (request_id == 0)
        return true;
    return owner->boot_exec_ctx_installed && request_id == owner->boot_exec_ctx.request_id;
}

bool ConsoleClient::requestOutputExhausted(uint64_t request_id) const
{
    if (budgetExempt(request_id))
        return false;
    auto it = request_output_spent.find(request_id);
    if (it == request_output_spent.end())
        return false;
    return it->value.lines >= owner->console_request_lines_max || it->value.bytes >= owner->console_request_bytes_max;
}

void ConsoleClient::emitBudgetDropMarker(uint64_t request_id)
{
    ColloConsoleSink sink = owner->console_sink;
    if (!sink)
        return;
    // Flags bit 1 marks a line the per-request budget dropped, in the ColloConsoleSink contract of abi.h.
    sink(owner->console_sink_ctx, COLLO_CONSOLE_INFO, 1 << 1, request_id, nullptr, 0);
}

void ConsoleClient::clearRequestOutputBudget(uint64_t request_id) { request_output_spent.remove(request_id); }

void ConsoleClient::resetRequestOutputBudgets() { request_output_spent.clear(); }

void ConsoleClient::emitLine(uint8_t level, const WTF::String& body)
{
    ColloConsoleSink sink = owner->console_sink;
    if (!sink)
        return;

    // Every emit path, label warnings included, passes this check, which also charges the spend. The entry points
    // check once more before formatting, the expensive part.
    uint64_t request_id = currentRequestId();
    if (requestOutputExhausted(request_id)) {
        emitBudgetDropMarker(request_id);
        return;
    }

    // The body can overshoot the unit budget by one clamped piece. Cutting in UTF-16 units first keeps the indent
    // copy and the UTF-8 conversion below from copying an oversized line whole; console_unit_slack keeps the cap
    // above the byte budget, so the byte cut still sets the truncated flag.
    size_t unit_cap = owner->console_line_bytes_max + console_unit_slack;
    WTF::String line = body;
    if (line.length() > unit_cap)
        line = StringView(line).left(static_cast<unsigned>(unit_cap)).toString();
    unsigned indent_depth = std::min(group_depth, group_indent_max_depth);
    if (indent_depth) {
        StringBuilder indented;
        for (unsigned i = 0; i < indent_depth; ++i)
            indented.append("  "_s);
        indented.append(line);
        line = indented.toString();
    }

    WTF::CString utf8 = line.utf8();
    size_t len = utf8.length();
    uint8_t flags = 0;
    size_t budget = owner->console_line_bytes_max;
    if (budget && len > budget) {
        const char* data = utf8.data();
        len = budget;
        // Steps back over at most three continuation bytes so the cut lands on a UTF-8 sequence boundary. Flags bit
        // 0 marks the line truncated, in the ColloConsoleSink contract of abi.h.
        unsigned backoff = 0;
        while (len > 0 && backoff < 3 && (static_cast<uint8_t>(data[len]) & 0b1100'0000) == 0b1000'0000) {
            --len;
            ++backoff;
        }
        flags |= 1;
    }

    if (!budgetExempt(request_id)) {
        auto it = request_output_spent.find(request_id);
        if (it != request_output_spent.end()) {
            it->value.lines += 1;
            it->value.bytes += len;
        } else if (request_output_spent.size() < request_budget_entries_max) {
            request_output_spent.add(request_id, RequestOutputSpent { 1, len });
        }
        // At request_budget_entries_max a new id goes untracked and its line still reaches the sink. Unlike the
        // label cap this one does not warn: request ids come from the runtime, not from tenant code, so the cap only
        // bounds ids that late asynchronous turns add back after request-end cleanup, and the log ring bounds their
        // output.
    }

    sink(owner->console_sink_ctx, level, flags, request_id, reinterpret_cast<const uint8_t*>(utf8.data()), len);
}

void ConsoleClient::messageWithTypeAndLevel(
    MessageType type, MessageLevel level, JSGlobalObject* global, Ref<ScriptArguments>&& arguments)
{
    if (type == MessageType::EndGroup) {
        if (group_depth)
            --group_depth;
        return;
    }
    if (type == MessageType::Clear)
        return;

    bool start_group = type == MessageType::StartGroup || type == MessageType::StartGroupCollapsed;
    if (!sinkActive()) {
        if (start_group)
            ++group_depth;
        return;
    }

    // Checked before formatting, so an exhausted request does not pay for rope walks, property enumeration and UTF-8
    // conversion only to have emitLine drop the result. Group depth is still tracked so later output stays indented
    // consistently.
    if (requestOutputExhausted(currentRequestId())) {
        emitBudgetDropMarker(currentRequestId());
        if (start_group)
            ++group_depth;
        return;
    }

    JSC::VM& vm = global->vm();
    InspectState state { global, vm, owner->console_line_bytes_max + console_unit_slack, {}, false };
    StringBuilder body;

    if (type == MessageType::Assert) {
        body.append("Assertion failed"_s);
        if (arguments->argumentCount())
            body.append(": "_s);
    } else if (type == MessageType::Trace) {
        body.append("Trace"_s);
        if (arguments->argumentCount())
            body.append(": "_s);
    }

    appendFormattedArguments(state, body, arguments.get());
    if (state.saw_termination)
        return;
    if (type == MessageType::Trace)
        appendStackTrace(state, body);

    if (!start_group || arguments->argumentCount())
        emitLine(sinkLevelFor(level), body.toString());
    if (start_group)
        ++group_depth;
}

WTF::String ConsoleClient::normalizedLabel(const WTF::String& label)
{
    String key = labelOrDefault(label);
    // label_units_max - 1 units plus the ellipsis keep the key at exactly label_units_max; taking label_units_max
    // units before the ellipsis would exceed the cap by one.
    if (key.length() > label_units_max)
        return makeString(StringView(key).left(label_units_max - 1), horizontalEllipsis);
    return key;
}

bool ConsoleClient::labelStateAtCap(size_t map_size, bool label_exists)
{
    if (label_exists || map_size < label_entries_max)
        return false;
    if (!label_cap_warned) {
        label_cap_warned = true;
        emitLine(COLLO_CONSOLE_WARN, "console label state cap reached; new count()/time() labels are dropped"_s);
    }
    return true;
}

void ConsoleClient::count(JSGlobalObject*, const String& label)
{
    if (!sinkActive())
        return;
    String key = normalizedLabel(label);
    if (labelStateAtCap(counts.size(), counts.contains(key)))
        return;
    auto result = counts.add(key, 0);
    ++result.iterator->value;
    emitLine(COLLO_CONSOLE_INFO, makeString(key, ": "_s, result.iterator->value));
}

void ConsoleClient::countReset(JSGlobalObject*, const String& label)
{
    if (!sinkActive())
        return;
    String key = normalizedLabel(label);
    if (!counts.remove(key))
        emitLine(COLLO_CONSOLE_WARN, makeString("Count for '"_s, key, "' does not exist"_s));
}

void ConsoleClient::time(JSGlobalObject*, const String& label)
{
    if (!sinkActive())
        return;
    String key = normalizedLabel(label);
    if (timers.contains(key)) {
        emitLine(COLLO_CONSOLE_WARN, makeString("Timer '"_s, key, "' already exists"_s));
        return;
    }
    if (labelStateAtCap(timers.size(), false))
        return;
    timers.add(key, WTF::MonotonicTime::now());
}

void ConsoleClient::timeLog(JSGlobalObject* global, const String& label, Ref<ScriptArguments>&& arguments)
{
    if (!sinkActive())
        return;
    // timeLog formats user arguments below, so it checks the budget first, as messageWithTypeAndLevel does.
    if (requestOutputExhausted(currentRequestId())) {
        emitBudgetDropMarker(currentRequestId());
        return;
    }
    String key = normalizedLabel(label);
    auto it = timers.find(key);
    if (it == timers.end()) {
        emitLine(COLLO_CONSOLE_WARN, makeString("Timer '"_s, key, "' does not exist"_s));
        return;
    }
    double ms = (WTF::MonotonicTime::now() - it->value).milliseconds();
    JSC::VM& vm = global->vm();
    InspectState state { global, vm, owner->console_line_bytes_max + console_unit_slack, {}, false };
    StringBuilder body;
    body.append(key, ": "_s, WTF::FormattedNumber::fixedWidth(ms, 3), "ms"_s);
    if (arguments->argumentCount()) {
        body.append(' ');
        appendFormattedArguments(state, body, arguments.get());
    }
    if (state.saw_termination)
        return;
    emitLine(COLLO_CONSOLE_INFO, body.toString());
}

void ConsoleClient::timeEnd(JSGlobalObject*, const String& label)
{
    if (!sinkActive())
        return;
    String key = normalizedLabel(label);
    auto it = timers.find(key);
    if (it == timers.end()) {
        emitLine(COLLO_CONSOLE_WARN, makeString("Timer '"_s, key, "' does not exist"_s));
        return;
    }
    double ms = (WTF::MonotonicTime::now() - it->value).milliseconds();
    timers.remove(it);
    emitLine(COLLO_CONSOLE_INFO, makeString(key, ": "_s, WTF::FormattedNumber::fixedWidth(ms, 3), "ms"_s));
}

void ConsoleClient::profile(JSGlobalObject*, const String&) { }
void ConsoleClient::profileEnd(JSGlobalObject*, const String&) { }
void ConsoleClient::takeHeapSnapshot(JSGlobalObject*, const String&) { }
void ConsoleClient::timeStamp(JSGlobalObject*, Ref<ScriptArguments>&&) { }
void ConsoleClient::record(JSGlobalObject*, Ref<ScriptArguments>&&) { }
void ConsoleClient::recordEnd(JSGlobalObject*, Ref<ScriptArguments>&&) { }
void ConsoleClient::screenshot(JSGlobalObject*, Ref<ScriptArguments>&&) { }

} // namespace Collo

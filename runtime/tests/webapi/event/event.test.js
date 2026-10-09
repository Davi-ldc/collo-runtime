// Collo compatibility contract derived from Bun v1.3.14:
// - reference/bun-v1.3.14/test/js/deno/event/event*.test.ts
// - reference/bun-v1.3.14/test/js/web/web-globals.test.js
// - reference/bun-v1.3.14/test/js/web/workers/message-event.test.ts

function descriptor(obj, key) {
  const desc = Object.getOwnPropertyDescriptor(obj, key);
  assert(desc, `${String(key)} descriptor should exist`);
  return desc;
}

function assertAccessor(obj, key, hasSetter = false) {
  const desc = descriptor(obj, key);
  assert.equal(typeof desc.get, "function", `${String(key)} getter`);
  assert.equal(typeof desc.set, hasSetter ? "function" : "undefined", `${String(key)} setter`);
  assert.equal(desc.enumerable, true, `${String(key)} enumerable`);
  assert.equal(desc.configurable, true, `${String(key)} configurable`);
}

function assertDataDescriptor(desc, value, writable, enumerable, configurable, label) {
  assert.equal(desc.value, value, `${label} value`);
  assert.equal(desc.writable, writable, `${label} writable`);
  assert.equal(desc.enumerable, enumerable, `${label} enumerable`);
  assert.equal(desc.configurable, configurable, `${label} configurable`);
  assert.equal("get" in desc, false, `${label} should not be accessor`);
  assert.equal("set" in desc, false, `${label} should not be accessor`);
}

function assertFunctionShape(fn, name, length, hasPrototype, label = name) {
  assert.equal(typeof fn, "function", `${label} should be a function`);
  assertDataDescriptor(descriptor(fn, "name"), name, false, false, true, `${label}.name`);
  assertDataDescriptor(descriptor(fn, "length"), length, false, false, true, `${label}.length`);
  assert.equal(Object.hasOwn(fn, "prototype"), hasPrototype, `${label} prototype presence`);
}

describe("event constructor global surface", () => {
  test("constructors have Web IDL global and own-property descriptors", () => {
    for (const [name, ctor, length] of [
      ["Event", Event, 1],
      ["CustomEvent", CustomEvent, 1],
      ["MessageEvent", MessageEvent, 1],
      ["ErrorEvent", ErrorEvent, 1],
      ["CloseEvent", CloseEvent, 1],
      ["EventTarget", EventTarget, 0],
    ]) {
      assertDataDescriptor(descriptor(globalThis, name), ctor, true, false, true, `global ${name}`);
      assertFunctionShape(ctor, name, length, true, name);
      assertDataDescriptor(descriptor(ctor, "prototype"), ctor.prototype, false, false, false, `${name}.prototype`);
      assertDataDescriptor(descriptor(ctor.prototype, "constructor"), ctor, true, false, true, `${name}.prototype.constructor`);

      const tag = descriptor(ctor.prototype, Symbol.toStringTag);
      assertDataDescriptor(tag, name, false, false, true, `${name}.prototype Symbol.toStringTag`);
      assert.throws(() => {
        ctor.prototype[Symbol.toStringTag] = "Other";
      }, TypeError);
    }
  });

  test("prototype method descriptors include name length writability and no own prototype", () => {
    for (const [prototype, methods] of [
      [Event.prototype, [["composedPath", 0], ["stopPropagation", 0], ["stopImmediatePropagation", 0], ["preventDefault", 0], ["initEvent", 1]]],
      [CustomEvent.prototype, [["initCustomEvent", 1]]],
      [MessageEvent.prototype, [["initMessageEvent", 1]]],
      [EventTarget.prototype, [["addEventListener", 2], ["removeEventListener", 2], ["dispatchEvent", 1]]],
    ]) {
      for (const [name, length] of methods) {
        const method = prototype[name];
        assertFunctionShape(method, name, length, false, name);
        assertDataDescriptor(descriptor(prototype, name), method, true, true, true, `${prototype[Symbol.toStringTag]}.${name}`);
      }
    }
  });
});

describe("Event", () => {
  test("constructor converts type and validates init", () => {
    const event = new Event("click", { bubbles: true, cancelable: true, composed: true });
    assert.equal(event.type, "click");
    assert.equal(event.bubbles, true);
    assert.equal(event.cancelable, true);
    assert.equal(event.composed, true);
    assert.equal(event.target, null);
    assert.equal(event.currentTarget, null);
    assert.equal(event.srcElement, null);
    assert.equal(event.eventPhase, Event.NONE);
    assert.equal(event.defaultPrevented, false);
    assert.equal(event.returnValue, true);
    assert.equal(event.isTrusted, false);
    assert.equal(typeof event.timeStamp, "number");
    assert(event.timeStamp >= 0);

    assert.equal(new Event(undefined).type, "undefined");
    assert.equal(new Event(123).type, "123");
    assert.throws(() => Event("x"), TypeError);
    assert.throws(() => new Event(), TypeError);
    assert.throws(() => new Event("x", 1), TypeError);
    assert.throws(() => new Event("x", true), TypeError);
    assert.throws(() => new Event("x", "bad"), TypeError);
  });

  test("prototype, constants and descriptors match Web IDL shape", () => {
    assert.equal(Event.length, 1);
    assert.equal(Event.name, "Event");
    assert.equal(Event.prototype.constructor, Event);
    assert.equal(Object.prototype.toString.call(new Event("x")), "[object Event]");
    assert.equal(Event.prototype[Symbol.toStringTag], "Event");

    for (const [name, value] of [
      ["NONE", 0],
      ["CAPTURING_PHASE", 1],
      ["AT_TARGET", 2],
      ["BUBBLING_PHASE", 3],
    ]) {
      assert.equal(Event[name], value);
      assert.equal(Event.prototype[name], value);
      const constructorDesc = descriptor(Event, name);
      const prototypeDesc = descriptor(Event.prototype, name);
      assert.equal(constructorDesc.writable, false, `${name} constructor writable`);
      assert.equal(constructorDesc.enumerable, true, `${name} constructor enumerable`);
      assert.equal(constructorDesc.configurable, false, `${name} constructor configurable`);
      assert.equal(prototypeDesc.writable, false, `${name} prototype writable`);
      assert.equal(prototypeDesc.enumerable, true, `${name} prototype enumerable`);
      assert.equal(prototypeDesc.configurable, false, `${name} prototype configurable`);
    }

    for (const key of [
      "type",
      "target",
      "srcElement",
      "currentTarget",
      "eventPhase",
      "bubbles",
      "cancelable",
      "defaultPrevented",
      "composed",
      "timeStamp",
    ]) assertAccessor(Event.prototype, key);
    assertAccessor(Event.prototype, "cancelBubble", true);
    assertAccessor(Event.prototype, "returnValue", true);

    const trusted1 = descriptor(new Event("x"), "isTrusted");
    const trusted2 = descriptor(new Event("x"), "isTrusted");
    assert.equal(typeof trusted1.get, "function");
    assert.equal(trusted1.set, undefined);
    assert.equal(trusted1.enumerable, true);
    assert.equal(trusted1.configurable, false);
    assert.equal(trusted1.get, trusted2.get);
    assert.equal(Object.getOwnPropertyDescriptor(Event.prototype, "isTrusted"), undefined);
  });

  test("methods and brand checks", () => {
    for (const [name, length] of [
      ["composedPath", 0],
      ["stopPropagation", 0],
      ["stopImmediatePropagation", 0],
      ["preventDefault", 0],
      ["initEvent", 1],
    ]) {
      assert.equal(typeof Event.prototype[name], "function", `${name} function`);
      assert.equal(Event.prototype[name].length, length, `${name} length`);
      assert.equal(descriptor(Event.prototype, name).enumerable, true, `${name} enumerable`);
      assert.throws(() => Event.prototype[name].call({}), TypeError);
    }

    assert.deepEqual(new Event("x").composedPath(), []);

    const stop = new Event("x");
    assert.equal(stop.cancelBubble, false);
    stop.stopPropagation();
    assert.equal(stop.cancelBubble, true);
    stop.cancelBubble = false;
    assert.equal(stop.cancelBubble, true);

    const immediate = new Event("x");
    immediate.stopImmediatePropagation();
    assert.equal(immediate.cancelBubble, true);

    const passive = new Event("x");
    passive.returnValue = false;
    assert.equal(passive.defaultPrevented, false);
    assert.equal(passive.returnValue, true);
    const cancelable = new Event("x", { cancelable: true });
    cancelable.returnValue = false;
    assert.equal(cancelable.defaultPrevented, true);
    assert.equal(cancelable.returnValue, false);

    const init = new Event("old", { bubbles: true, cancelable: true, composed: true });
    init.preventDefault();
    init.stopPropagation();
    init.initEvent("new", false, false);
    assert.equal(init.type, "new");
    assert.equal(init.bubbles, false);
    assert.equal(init.cancelable, false);
    assert.equal(init.composed, false);
    assert.equal(init.defaultPrevented, false);
    assert.equal(init.cancelBubble, false);
  });

  test("subclassing", () => {
    class SpecialEvent extends Event {}
    const event = new SpecialEvent("special", { cancelable: true });
    assert(event instanceof SpecialEvent);
    assert(event instanceof Event);
    assert.equal(event.type, "special");
    event.preventDefault();
    assert.equal(event.defaultPrevented, true);
  });
});

describe("CustomEvent", () => {
  test("constructor converts type init and preserves detail identity", () => {
    const detail = { answer: 42 };
    const event = new CustomEvent("custom", {
      bubbles: true,
      cancelable: true,
      composed: true,
      detail,
    });
    assert(event instanceof CustomEvent);
    assert(event instanceof Event);
    assert.equal(event.type, "custom");
    assert.equal(event.bubbles, true);
    assert.equal(event.cancelable, true);
    assert.equal(event.composed, true);
    assert.equal(event.detail, detail);
    assert.equal(new CustomEvent("x").detail, null);
    assert.equal(new CustomEvent("x", { detail: undefined }).detail, undefined);
    assert.equal(new CustomEvent(undefined).type, "undefined");
    assert.throws(() => CustomEvent("x"), TypeError);
    assert.throws(() => new CustomEvent(), TypeError);
    assert.throws(() => new CustomEvent("x", 1), TypeError);
    assert.throws(() => new CustomEvent("x", "bad"), TypeError);
  });

  test("prototype inheritance descriptors and brand checks", () => {
    assert.equal(CustomEvent.length, 1);
    assert.equal(CustomEvent.name, "CustomEvent");
    assert.equal(Object.getPrototypeOf(CustomEvent), Event);
    assert.equal(Object.getPrototypeOf(CustomEvent.prototype), Event.prototype);
    assert.equal(CustomEvent.prototype.constructor, CustomEvent);
    assert.equal(Object.prototype.toString.call(new CustomEvent("x")), "[object CustomEvent]");
    assert.equal(CustomEvent.prototype[Symbol.toStringTag], "CustomEvent");
    assertAccessor(CustomEvent.prototype, "detail");

    const initDesc = descriptor(CustomEvent.prototype, "initCustomEvent");
    assert.equal(typeof initDesc.value, "function");
    assert.equal(initDesc.value.length, 1);
    assert.equal(initDesc.enumerable, true);
    assert.equal(initDesc.configurable, true);
    assert.equal(initDesc.writable, true);

    assert.throws(() => CustomEvent.prototype.initCustomEvent.call({}, "x"), TypeError);
    assert.throws(() => Object.getOwnPropertyDescriptor(CustomEvent.prototype, "detail").get.call({}), TypeError);
  });

  test("initCustomEvent resets event state before dispatch and is no-op while dispatching", () => {
    const target = new EventTarget();
    const event = new CustomEvent("before", {
      bubbles: true,
      cancelable: true,
      composed: true,
      detail: "old",
    });
    event.preventDefault();
    event.stopPropagation();
    event.initCustomEvent("after", false, false, "new");
    assert.equal(event.type, "after");
    assert.equal(event.bubbles, false);
    assert.equal(event.cancelable, false);
    assert.equal(event.composed, false);
    assert.equal(event.detail, "new");
    assert.equal(event.defaultPrevented, false);
    assert.equal(event.cancelBubble, false);

    target.addEventListener("after", e => {
      e.initCustomEvent("mutated", true, true, "bad");
    });
    target.dispatchEvent(event);
    assert.equal(event.type, "after");
    assert.equal(event.bubbles, false);
    assert.equal(event.cancelable, false);
    assert.equal(event.detail, "new");
  });

  test("dispatch delivers CustomEvent through EventTarget", () => {
    const target = new EventTarget();
    const detail = { user: "collo" };
    let seen = null;
    target.addEventListener("custom", event => {
      seen = event;
      assert(event instanceof CustomEvent);
      assert(event instanceof Event);
      assert.equal(event.detail, detail);
      assert.equal(event.target, target);
    });
    const event = new CustomEvent("custom", { detail, cancelable: true });
    assert.equal(target.dispatchEvent(event), true);
    assert.equal(seen, event);
  });

  test("subclassing", () => {
    class SpecialCustomEvent extends CustomEvent {}
    const event = new SpecialCustomEvent("special", { detail: 7 });
    assert(event instanceof SpecialCustomEvent);
    assert(event instanceof CustomEvent);
    assert(event instanceof Event);
    assert.equal(event.detail, 7);
  });
});

describe("MessageEvent", () => {
  test("constructor converts type init and preserves data identity", () => {
    const data = { answer: 42 };
    const event = new MessageEvent("message", {
      bubbles: true,
      cancelable: true,
      composed: true,
      data,
      origin: 123,
      lastEventId: 456,
      ports: [],
    });
    assert(event instanceof MessageEvent);
    assert(event instanceof Event);
    assert.equal(event.type, "message");
    assert.equal(event.bubbles, true);
    assert.equal(event.cancelable, true);
    assert.equal(event.composed, true);
    assert.equal(event.data, data);
    assert.equal(event.origin, "123");
    assert.equal(event.lastEventId, "456");
    assert.equal(event.source, null);
    assert(Array.isArray(event.ports));
    assert.equal(event.ports.length, 0);
    assert.equal(Object.isFrozen(event.ports), true);

    assert.equal(new MessageEvent("x").data, null);
    assert.equal(new MessageEvent("x").origin, "");
    assert.equal(new MessageEvent("x").lastEventId, "");
    assert.equal(new MessageEvent("x").source, null);
    assert.deepEqual(new MessageEvent("x").ports, []);
    assert.equal(new MessageEvent("x", { data: undefined }).data, undefined);
    assert.equal(new MessageEvent(undefined).type, "undefined");
    assert.equal(new MessageEvent(123).type, "123");
    assert.throws(() => MessageEvent("x"), TypeError);
    assert.throws(() => new MessageEvent(), TypeError);
    assert.throws(() => new MessageEvent("x", 1), TypeError);
    assert.throws(() => new MessageEvent("x", "bad"), TypeError);
  });

  test("source and ports validate MessagePort values", () => {
    assert.throws(() => new MessageEvent("message", { source: 1 }), TypeError);
    assert.throws(() => new MessageEvent("message", { source: {} }), TypeError);
    assert.throws(() => new MessageEvent("message", { ports: 1 }), TypeError);
    assert.throws(() => new MessageEvent("message", { ports: null }), TypeError);
    assert.throws(() => new MessageEvent("message", { ports: [1] }), TypeError);
    assert.throws(() => new MessageEvent("message", { ports: [{}] }), TypeError);
    const channel = new MessageChannel();
    const event = new MessageEvent("message", { source: channel.port1, ports: [channel.port2] });
    assert.equal(event.source, channel.port1);
    assert.equal(event.ports.length, 1);
    assert.equal(event.ports[0], channel.port2);
    assert.equal(Object.isFrozen(event.ports), true);
    channel.port1.close();
    channel.port2.close();
    const emptyIterable = {
      *[Symbol.iterator]() {},
    };
    assert.deepEqual(new MessageEvent("message", { ports: emptyIterable }).ports, []);
  });

  test("prototype inheritance descriptors and brand checks", () => {
    assert.equal(MessageEvent.length, 1);
    assert.equal(MessageEvent.name, "MessageEvent");
    assert.equal(Object.getPrototypeOf(MessageEvent), Event);
    assert.equal(Object.getPrototypeOf(MessageEvent.prototype), Event.prototype);
    assert.equal(MessageEvent.prototype.constructor, MessageEvent);
    assert.equal(Object.prototype.toString.call(new MessageEvent("x")), "[object MessageEvent]");
    assert.equal(MessageEvent.prototype[Symbol.toStringTag], "MessageEvent");
    for (const key of ["data", "origin", "lastEventId", "source", "ports"])
      assertAccessor(MessageEvent.prototype, key);

    const initDesc = descriptor(MessageEvent.prototype, "initMessageEvent");
    assert.equal(typeof initDesc.value, "function");
    assert.equal(initDesc.value.length, 1);
    assert.equal(initDesc.enumerable, true);
    assert.equal(initDesc.configurable, true);
    assert.equal(initDesc.writable, true);

    assert.throws(() => MessageEvent.prototype.initMessageEvent.call({}, "x"), TypeError);
    assert.throws(() => Object.getOwnPropertyDescriptor(MessageEvent.prototype, "data").get.call({}), TypeError);
    assert.throws(() => Object.getOwnPropertyDescriptor(MessageEvent.prototype, "ports").get.call({}), TypeError);
  });

  test("initMessageEvent resets event state before dispatch and is no-op while dispatching", () => {
    const target = new EventTarget();
    const event = new MessageEvent("before", {
      bubbles: true,
      cancelable: true,
      composed: true,
      data: "old",
      origin: "old-origin",
      lastEventId: "old-id",
    });
    event.preventDefault();
    event.stopPropagation();
    event.initMessageEvent("after", false, false, "new", "new-origin", "new-id", null, []);
    assert.equal(event.type, "after");
    assert.equal(event.bubbles, false);
    assert.equal(event.cancelable, false);
    assert.equal(event.composed, false);
    assert.equal(event.data, "new");
    assert.equal(event.origin, "new-origin");
    assert.equal(event.lastEventId, "new-id");
    assert.equal(event.source, null);
    assert.deepEqual(event.ports, []);
    assert.equal(event.defaultPrevented, false);
    assert.equal(event.cancelBubble, false);

    target.addEventListener("after", e => {
      e.initMessageEvent("mutated", true, true, "bad", "bad", "bad");
    });
    target.dispatchEvent(event);
    assert.equal(event.type, "after");
    assert.equal(event.bubbles, false);
    assert.equal(event.cancelable, false);
    assert.equal(event.data, "new");
    assert.equal(event.origin, "new-origin");
  });

  test("dispatch delivers MessageEvent through EventTarget", () => {
    const target = new EventTarget();
    const data = { user: "collo" };
    let seen = null;
    target.addEventListener("message", event => {
      seen = event;
      assert(event instanceof MessageEvent);
      assert(event instanceof Event);
      assert.equal(event.data, data);
      assert.equal(event.target, target);
    });
    const event = new MessageEvent("message", { data, cancelable: true });
    assert.equal(target.dispatchEvent(event), true);
    assert.equal(seen, event);
  });

  test("subclassing", () => {
    class SpecialMessageEvent extends MessageEvent {}
    const event = new SpecialMessageEvent("special", { data: 7 });
    assert(event instanceof SpecialMessageEvent);
    assert(event instanceof MessageEvent);
    assert(event instanceof Event);
    assert.equal(event.data, 7);
  });
});

describe("ErrorEvent", () => {
  test("constructor converts type init and applies Web IDL defaults", () => {
    const error = new Error("boom");
    const event = new ErrorEvent("error", {
      bubbles: true,
      cancelable: true,
      composed: true,
      message: 123,
      filename: 456,
      lineno: "7",
      colno: 8.9,
      error,
    });
    assert(event instanceof ErrorEvent);
    assert(event instanceof Event);
    assert.equal(event.type, "error");
    assert.equal(event.bubbles, true);
    assert.equal(event.cancelable, true);
    assert.equal(event.composed, true);
    assert.equal(event.message, "123");
    assert.equal(event.filename, "456");
    assert.equal(event.lineno, 7);
    assert.equal(event.colno, 8);
    assert.equal(event.error, error);

    const empty = new ErrorEvent("error");
    assert.equal(empty.message, "");
    assert.equal(empty.filename, "");
    assert.equal(empty.lineno, 0);
    assert.equal(empty.colno, 0);
    assert.equal(empty.error, null);
    assert.equal(new ErrorEvent(undefined).type, "undefined");
    assert.equal(new ErrorEvent(123).type, "123");
    assert.throws(() => ErrorEvent("x"), TypeError);
    assert.throws(() => new ErrorEvent(), TypeError);
    assert.throws(() => new ErrorEvent("x", 1), TypeError);
    assert.throws(() => new ErrorEvent("x", "bad"), TypeError);
  });

  test("dictionary undefined members use defaults and numeric fields are unsigned long", () => {
    const event = new ErrorEvent("error", {
      message: undefined,
      filename: undefined,
      lineno: undefined,
      colno: undefined,
      error: undefined,
    });
    assert.equal(event.message, "");
    assert.equal(event.filename, "");
    assert.equal(event.lineno, 0);
    assert.equal(event.colno, 0);
    assert.equal(event.error, null);

    assert.equal(new ErrorEvent("error", { lineno: -1 }).lineno, 4294967295);
    assert.equal(new ErrorEvent("error", { lineno: 3.7 }).lineno, 3);
    assert.equal(new ErrorEvent("error", { lineno: NaN }).lineno, 0);
    assert.equal(new ErrorEvent("error", { lineno: Infinity }).lineno, 0);
    assert.equal(new ErrorEvent("error", { lineno: null }).lineno, 0);
    assert.equal(new ErrorEvent("error", { colno: -1 }).colno, 4294967295);
    assert.equal(new ErrorEvent("error", { colno: 3.7 }).colno, 3);
    assert.equal(new ErrorEvent("error", { colno: NaN }).colno, 0);
    assert.equal(new ErrorEvent("error", { colno: Infinity }).colno, 0);
    assert.equal(new ErrorEvent("error", { colno: null }).colno, 0);
    assert.equal(new ErrorEvent("error", { filename: "\uD800.js" }).filename, "\uFFFD.js");
  });

  test("prototype inheritance descriptors and brand checks", () => {
    assert.equal(ErrorEvent.length, 1);
    assert.equal(ErrorEvent.name, "ErrorEvent");
    assert.equal(Object.getPrototypeOf(ErrorEvent), Event);
    assert.equal(Object.getPrototypeOf(ErrorEvent.prototype), Event.prototype);
    assert.equal(ErrorEvent.prototype.constructor, ErrorEvent);
    assert.equal(Object.prototype.toString.call(new ErrorEvent("x")), "[object ErrorEvent]");
    assert.equal(ErrorEvent.prototype[Symbol.toStringTag], "ErrorEvent");
    for (const key of ["message", "filename", "lineno", "colno", "error"])
      assertAccessor(ErrorEvent.prototype, key);

    assert.throws(() => Object.getOwnPropertyDescriptor(ErrorEvent.prototype, "message").get.call({}), TypeError);
    assert.throws(() => Object.getOwnPropertyDescriptor(ErrorEvent.prototype, "filename").get.call({}), TypeError);
    assert.throws(() => Object.getOwnPropertyDescriptor(ErrorEvent.prototype, "lineno").get.call({}), TypeError);
    assert.throws(() => Object.getOwnPropertyDescriptor(ErrorEvent.prototype, "colno").get.call({}), TypeError);
    assert.throws(() => Object.getOwnPropertyDescriptor(ErrorEvent.prototype, "error").get.call({}), TypeError);
  });

  test("dispatch delivers ErrorEvent through EventTarget", () => {
    const target = new EventTarget();
    const error = new TypeError("boom");
    const event = new ErrorEvent("error", { message: "boom", filename: "route.js", lineno: 10, colno: 2, error });
    let seen = null;
    target.addEventListener("error", value => {
      seen = value;
      assert(value instanceof ErrorEvent);
      assert(value instanceof Event);
      assert.equal(value.message, "boom");
      assert.equal(value.filename, "route.js");
      assert.equal(value.lineno, 10);
      assert.equal(value.colno, 2);
      assert.equal(value.error, error);
      assert.equal(value.target, target);
    });
    assert.equal(target.dispatchEvent(event), true);
    assert.equal(seen, event);
  });

  test("subclassing", () => {
    class SpecialErrorEvent extends ErrorEvent {}
    const event = new SpecialErrorEvent("special", { message: "custom" });
    assert(event instanceof SpecialErrorEvent);
    assert(event instanceof ErrorEvent);
    assert(event instanceof Event);
    assert.equal(event.message, "custom");
  });
});

describe("CloseEvent", () => {
  test("constructor converts type init and applies Web IDL defaults", () => {
    const event = new CloseEvent("close", {
      bubbles: true,
      cancelable: true,
      composed: true,
      wasClean: 1,
      code: "1000",
      reason: 123,
    });
    assert(event instanceof CloseEvent);
    assert(event instanceof Event);
    assert.equal(event.type, "close");
    assert.equal(event.bubbles, true);
    assert.equal(event.cancelable, true);
    assert.equal(event.composed, true);
    assert.equal(event.wasClean, true);
    assert.equal(event.code, 1000);
    assert.equal(event.reason, "123");

    const empty = new CloseEvent("close");
    assert.equal(empty.wasClean, false);
    assert.equal(empty.code, 0);
    assert.equal(empty.reason, "");
    assert.equal(new CloseEvent(undefined).type, "undefined");
    assert.equal(new CloseEvent(123).type, "123");
    assert.throws(() => CloseEvent("x"), TypeError);
    assert.throws(() => new CloseEvent(), TypeError);
    assert.throws(() => new CloseEvent("x", 1), TypeError);
    assert.throws(() => new CloseEvent("x", "bad"), TypeError);
  });

  test("code conversion follows unsigned-short modulo semantics", () => {
    assert.equal(new CloseEvent("close", { code: 65535 }).code, 65535);
    assert.equal(new CloseEvent("close", { code: 65536 }).code, 0);
    assert.equal(new CloseEvent("close", { code: -1 }).code, 65535);
    assert.equal(new CloseEvent("close", { code: 3.7 }).code, 3);
    assert.equal(new CloseEvent("close", { code: NaN }).code, 0);
    assert.equal(new CloseEvent("close", { code: Infinity }).code, 0);
    assert.equal(new CloseEvent("close", { code: null }).code, 0);
  });

  test("prototype inheritance descriptors and brand checks", () => {
    assert.equal(CloseEvent.length, 1);
    assert.equal(CloseEvent.name, "CloseEvent");
    assert.equal(Object.getPrototypeOf(CloseEvent), Event);
    assert.equal(Object.getPrototypeOf(CloseEvent.prototype), Event.prototype);
    assert.equal(CloseEvent.prototype.constructor, CloseEvent);
    assert.equal(Object.prototype.toString.call(new CloseEvent("x")), "[object CloseEvent]");
    assert.equal(CloseEvent.prototype[Symbol.toStringTag], "CloseEvent");
    for (const key of ["wasClean", "code", "reason"])
      assertAccessor(CloseEvent.prototype, key);

    assert.throws(() => Object.getOwnPropertyDescriptor(CloseEvent.prototype, "code").get.call({}), TypeError);
    assert.throws(() => Object.getOwnPropertyDescriptor(CloseEvent.prototype, "reason").get.call({}), TypeError);
    assert.throws(() => Object.getOwnPropertyDescriptor(CloseEvent.prototype, "wasClean").get.call({}), TypeError);
  });

  test("dispatch delivers CloseEvent through EventTarget", () => {
    const target = new EventTarget();
    const event = new CloseEvent("close", { code: 1001, reason: "going away", wasClean: true });
    let seen = null;
    target.addEventListener("close", value => {
      seen = value;
      assert(value instanceof CloseEvent);
      assert(value instanceof Event);
      assert.equal(value.code, 1001);
      assert.equal(value.reason, "going away");
      assert.equal(value.wasClean, true);
      assert.equal(value.target, target);
    });
    assert.equal(target.dispatchEvent(event), true);
    assert.equal(seen, event);
  });

  test("subclassing", () => {
    class SpecialCloseEvent extends CloseEvent {}
    const event = new SpecialCloseEvent("special", { code: 7, reason: "custom" });
    assert(event instanceof SpecialCloseEvent);
    assert(event instanceof CloseEvent);
    assert(event instanceof Event);
    assert.equal(event.code, 7);
    assert.equal(event.reason, "custom");
  });
});

describe("global event target", () => {
  test("global functions and handler properties match Bun-compatible descriptors", () => {
    for (const [name, length] of [
      ["addEventListener", 2],
      ["removeEventListener", 2],
      ["dispatchEvent", 1],
    ]) {
      const desc = descriptor(globalThis, name);
      assert.equal(typeof desc.value, "function", `${name} value`);
      assert.equal(desc.value.length, length, `${name} length`);
      assert.equal(desc.writable, true, `${name} writable`);
      assert.equal(desc.enumerable, true, `${name} enumerable`);
      assert.equal(desc.configurable, true, `${name} configurable`);
      assertFunctionShape(desc.value, name, length, false, `global ${name}`);
    }

    for (const name of ["onerror", "onmessage"]) {
      const desc = descriptor(globalThis, name);
      assert.equal(typeof desc.get, "function", `${name} getter`);
      assert.equal(typeof desc.set, "function", `${name} setter`);
      assert.equal(desc.enumerable, true, `${name} enumerable`);
      assert.equal(desc.configurable, true, `${name} configurable`);
    }
  });

  test("onerror and onmessage properties receive dispatched events before listeners", () => {
    const order = [];
    function errorListener(event) {
      order.push(`listener:${event.error}`);
    }
    function messageListener(event) {
      order.push(`listener:${event.data}`);
    }

    try {
      globalThis.onerror = event => {
        order.push(`handler:${event.error}`);
      };
      addEventListener("error", errorListener);
      assert.equal(dispatchEvent(new ErrorEvent("error", { error: "hello" })), true);
      assert.deepEqual(order, ["handler:hello", "listener:hello"]);

      order.length = 0;
      globalThis.onmessage = event => {
        order.push(`handler:${event.data}`);
      };
      addEventListener("message", messageListener);
      assert.equal(dispatchEvent(new MessageEvent("message", { data: "world" })), true);
      assert.deepEqual(order, ["handler:world", "listener:world"]);
    } finally {
      globalThis.onerror = null;
      globalThis.onmessage = null;
      removeEventListener("error", errorListener);
      removeEventListener("message", messageListener);
    }
  });

  test("global addEventListener removeEventListener and object listeners", () => {
    const calls = [];
    function listener(event) {
      calls.push(`fn:${event.type}`);
    }
    const objectListener = {
      handleEvent(event) {
        calls.push(`object:${event.type}`);
      },
    };

    try {
      addEventListener("collo-global", listener);
      addEventListener("collo-global", listener);
      addEventListener("collo-global", objectListener);
      assert.equal(dispatchEvent(new Event("collo-global")), true);
      assert.deepEqual(calls, ["fn:collo-global", "object:collo-global"]);

      removeEventListener("collo-global", listener);
      calls.length = 0;
      assert.equal(dispatchEvent(new Event("collo-global")), true);
      assert.deepEqual(calls, ["object:collo-global"]);
    } finally {
      removeEventListener("collo-global", listener);
      removeEventListener("collo-global", objectListener);
    }
  });

  test("global listeners support once passive signal and receiver-independent calls", () => {
    const calls = [];
    const controller = new AbortController();
    const preAborted = new AbortController();
    preAborted.abort("done");

    function once(event) {
      calls.push(`once:${event.defaultPrevented}`);
      event.preventDefault();
    }
    function passive(event) {
      event.preventDefault();
      calls.push(`passive:${event.defaultPrevented}`);
    }
    function signalListener() {
      calls.push("signal");
    }
    function never() {
      calls.push("never");
    }

    try {
      addEventListener.call(null, "collo-global-options", once, { once: true });
      addEventListener("collo-global-options", passive, { passive: true });
      addEventListener("collo-global-options", signalListener, { signal: controller.signal });
      addEventListener("collo-global-options", never, { signal: preAborted.signal });
      const first = new Event("collo-global-options", { cancelable: true });
      assert.equal(dispatchEvent.call(undefined, first), false);
      controller.abort();
      const second = new Event("collo-global-options", { cancelable: true });
      assert.equal(dispatchEvent(second), true);
      assert.deepEqual(calls, ["once:false", "passive:true", "signal", "passive:false"]);
    } finally {
      removeEventListener("collo-global-options", once);
      removeEventListener("collo-global-options", passive);
      removeEventListener("collo-global-options", signalListener);
      removeEventListener("collo-global-options", never);
    }
  });

  test("global handler assignment follows Bun non-callable and return-false behavior", () => {
    try {
      globalThis.onerror = undefined;
      assert.equal(globalThis.onerror, null);
      assert.equal(dispatchEvent(new ErrorEvent("error", { error: "ignored" })), true);

      const plain = { value: 1 };
      globalThis.onerror = plain;
      assert.equal(globalThis.onerror, plain);
      assert.equal(dispatchEvent(new ErrorEvent("error", { error: "ignored" })), true);

      globalThis.onerror = () => false;
      const event = new ErrorEvent("error", { cancelable: true });
      assert.equal(dispatchEvent(event), false);
      assert.equal(event.defaultPrevented, true);
    } finally {
      globalThis.onerror = null;
    }
  });

  test("AbortSignal option removes global listeners", () => {
    const controller = new AbortController();
    let calls = 0;
    function listener() { calls++; }
    addEventListener("collo-abort-global", listener, { signal: controller.signal });
    assert.equal(dispatchEvent(new Event("collo-abort-global")), true);
    controller.abort();
    assert.equal(dispatchEvent(new Event("collo-abort-global")), true);
    assert.equal(calls, 1);
    removeEventListener("collo-abort-global", listener);
  });
});

describe("EventTarget", () => {
  test("constructor and descriptors", () => {
    const target = new EventTarget();
    assert(target instanceof EventTarget);
    assert.equal(EventTarget.length, 0);
    assert.equal(EventTarget.name, "EventTarget");
    assert.equal(EventTarget.prototype.constructor, EventTarget);
    assert.equal(Object.prototype.toString.call(target), "[object EventTarget]");
    assert.equal(EventTarget.prototype[Symbol.toStringTag], "EventTarget");
    assert.throws(() => EventTarget(), TypeError);

    for (const [name, length] of [
      ["addEventListener", 2],
      ["removeEventListener", 2],
      ["dispatchEvent", 1],
    ]) {
      const desc = descriptor(EventTarget.prototype, name);
      assert.equal(typeof desc.value, "function", `${name} value`);
      assert.equal(desc.value.length, length, `${name} length`);
      assert.equal(desc.enumerable, true, `${name} enumerable`);
      assert.equal(desc.configurable, true, `${name} configurable`);
      assert.equal(desc.writable, true, `${name} writable`);
      assertFunctionShape(desc.value, name, length, false, `EventTarget.prototype.${name}`);
    }
  });

  test("listener dispatch order, this value and event state", () => {
    const target = new EventTarget();
    const originalEvent = new Event("foo", { cancelable: true, bubbles: true, composed: true });
    originalEvent.__marker = "original";
    assert.equal(originalEvent.__marker, "original", "Event supports expando properties");
    const seen = [];
    function first(e) {
      assert.equal(this, target);
      assert.equal(e, originalEvent, "listener receives original event identity");
      if (e.__marker !== "original")
        throw new Error(`listener receives event custom properties directly: ${String(e.__marker)}`);
      e.__fromListener = "mutated";
      assert.equal(e.type, originalEvent.type);
      assert.equal(e.target, target);
      assert.equal(e.srcElement, target);
      assert.equal(e.currentTarget, target);
      assert.equal(e.eventPhase, Event.AT_TARGET);
      assert.deepEqual(e.composedPath(), [target]);
      seen.push("first");
    }
    target.addEventListener("foo", first);
    target.addEventListener("foo", () => seen.push("second"));
    assert.equal(target.dispatchEvent(originalEvent), true);
    assert.deepEqual(seen, ["first", "second"]);
    assert.equal(originalEvent.target, target);
    assert.equal(originalEvent.currentTarget, null);
    assert.equal(originalEvent.eventPhase, Event.NONE);
    assert.equal(originalEvent.__fromListener, "mutated");
    assert.deepEqual(originalEvent.composedPath(), []);

    target.removeEventListener("foo", first);
    target.addEventListener("foo", e => e.preventDefault(), { once: true });
    assert.equal(target.dispatchEvent(originalEvent), false);
    assert.equal(target.dispatchEvent(new Event("foo", { cancelable: true })), true);
  });

  test("add, remove, duplicate suppression and capture identity", () => {
    const target = new EventTarget();
    let calls = 0;
    function listener() { calls++; }

    assert.equal(target.addEventListener("x", null, false), undefined);
    assert.equal(target.addEventListener("x", undefined, true), undefined);
    assert.throws(() => target.addEventListener("x", 1), TypeError);
    assert.throws(() => target.removeEventListener("x", 1), TypeError);

    target.addEventListener("x", listener);
    target.addEventListener("x", listener);
    target.dispatchEvent(new Event("x"));
    assert.equal(calls, 1);

    target.addEventListener("x", listener, true);
    target.dispatchEvent(new Event("x"));
    assert.equal(calls, 3);

    target.removeEventListener("x", listener, false);
    target.dispatchEvent(new Event("x"));
    assert.equal(calls, 4);

    target.removeEventListener("x", listener, true);
    target.dispatchEvent(new Event("x"));
    assert.equal(calls, 4);
  });

  test("listener options support object conversion, pre-aborted signals, and no-handleEvent objects", () => {
    const target = new EventTarget();
    const calls = [];
    const controller = new AbortController();
    const preAborted = new AbortController();
    preAborted.abort("already");

    const options = {
      get once() {
        calls.push("get-once");
        return true;
      },
      get passive() {
        calls.push("get-passive");
        return true;
      },
      get signal() {
        calls.push("get-signal");
        return controller.signal;
      },
    };

    target.addEventListener("x", event => {
      calls.push(`listener:${event.defaultPrevented}`);
      event.preventDefault();
    }, options);
    target.addEventListener("x", () => calls.push("never"), { signal: preAborted.signal });
    target.addEventListener("x", { value: 1 });

    const first = new Event("x", { cancelable: true });
    assert.equal(target.dispatchEvent(first), true);
    assert.equal(first.defaultPrevented, false);
    controller.abort();
    assert.equal(target.dispatchEvent(new Event("x", { cancelable: true })), true);
    assert.deepEqual(calls, ["get-once", "get-passive", "get-signal", "listener:false"]);
  });

  test("object listeners resolve handleEvent at dispatch time", () => {
    const target = new EventTarget();
    const calls = [];
    const listener = {
      handleEvent(event) {
        calls.push(`first:${event.type}`);
      },
    };
    target.addEventListener("x", listener);
    listener.handleEvent = event => calls.push(`second:${event.type}`);
    target.dispatchEvent(new Event("x"));
    assert.deepEqual(calls, ["second:x"]);
    target.removeEventListener("x", listener);
    target.dispatchEvent(new Event("x"));
    assert.deepEqual(calls, ["second:x"]);
  });

  test("function listeners ignore handleEvent properties", () => {
    const target = new EventTarget();
    const calls = [];
    function listener(event) {
      calls.push(`fn:${event.type}:${this === target}`);
    }
    listener.handleEvent = () => calls.push("handleEvent");
    target.addEventListener("x", listener);
    target.dispatchEvent(new Event("x"));
    assert.deepEqual(calls, ["fn:x:true"]);
    target.removeEventListener("x", listener);
  });

  test("event type storage handles object prototype names", () => {
    const target = new EventTarget();
    const calls = [];
    for (const type of ["toString", "hasOwnProperty", "__proto__"]) {
      const listener = event => calls.push(event.type);
      target.addEventListener(type, listener);
      target.dispatchEvent(new Event(type));
      target.removeEventListener(type, listener);
    }
    assert.deepEqual(calls, ["toString", "hasOwnProperty", "__proto__"]);
  });

  test("once, passive, added-during-dispatch and removed-during-dispatch", () => {
    const target = new EventTarget();
    const order = [];
    function addedLater() { order.push("added-later"); }
    function removedBeforeCall() { order.push("removed-before-call"); }
    target.addEventListener("x", () => {
      order.push("first");
      target.addEventListener("x", addedLater);
      target.removeEventListener("x", removedBeforeCall);
    }, { once: true });
    target.addEventListener("x", removedBeforeCall);
    target.dispatchEvent(new Event("x"));
    assert.deepEqual(order, ["first"]);
    target.dispatchEvent(new Event("x"));
    assert.deepEqual(order, ["first", "added-later"]);

    const passive = new EventTarget();
    passive.addEventListener("x", e => e.preventDefault(), { passive: true });
    const event = new Event("x", { cancelable: true });
    assert.equal(passive.dispatchEvent(event), true);
    assert.equal(event.defaultPrevented, false);
  });

  test("dispatch snapshots listeners added during callbacks", () => {
    const target = new EventTarget();
    const order = [];
    let didAdd = false;
    function addedLater() { order.push("added-later"); }
    target.addEventListener("x", () => {
      order.push("first");
      if (didAdd)
        return;
      didAdd = true;
      for (let i = 0; i < 256; i++)
        target.addEventListener("x", () => order.push("late"));
      target.addEventListener("x", addedLater);
    });
    target.addEventListener("x", () => order.push("second"));

    target.dispatchEvent(new Event("x"));
    assert.deepEqual(order, ["first", "second"]);

    target.dispatchEvent(new Event("x"));
    assert.deepEqual(order.slice(2, 4), ["first", "second"]);
    assert.equal(order.filter(value => value === "late").length, 256);
    assert.equal(order[order.length - 1], "added-later");
  });

  test("EventTarget rejects excessive listener lists", () => {
    const target = new EventTarget();
    const first = () => {};
    target.addEventListener("quota", first);
    for (let i = 1; i < (1 << 14); i++)
      target.addEventListener("quota", () => {});
    assert.equal(target.addEventListener("quota", first), undefined);
    const error = assert.throws(() => target.addEventListener("quota", () => {}), DOMException);
    assert.equal(error.name, "QuotaExceededError");
  });

  test("stopImmediatePropagation and recursive dispatch", () => {
    const target = new EventTarget();
    const event = new Event("x");
    const order = [];
    target.addEventListener("x", e => {
      order.push("first");
      e.stopImmediatePropagation();
    });
    target.addEventListener("x", () => order.push("second"));
    assert.equal(target.dispatchEvent(event), true);
    assert.deepEqual(order, ["first"]);

    const recursive = new Event("recursive");
    target.addEventListener("recursive", () => {
      assert.throws(() => target.dispatchEvent(recursive), DOMException);
    });
    assert.equal(target.dispatchEvent(recursive), true);
    assert.equal(target.dispatchEvent(recursive), true);
  });

  test("brand checks and subclassing", () => {
    assert.throws(() => EventTarget.prototype.addEventListener.call({}, "x", null), TypeError);
    assert.throws(() => EventTarget.prototype.removeEventListener.call({}, "x", null), TypeError);
    assert.throws(() => EventTarget.prototype.dispatchEvent.call({}, new Event("x")), TypeError);
    assert.throws(() => new EventTarget().dispatchEvent({ type: "x" }), TypeError);

    class SpecialTarget extends EventTarget {}
    const target = new SpecialTarget();
    let called = false;
    target.addEventListener("x", () => { called = true; });
    target.dispatchEvent(new Event("x"));
    assert.equal(called, true);
    assert(target instanceof SpecialTarget);
    assert(target instanceof EventTarget);
  });

  // Per WHATWG DOM, clearing all listeners mid-dispatch (here MessagePort
  // .close(), which marks every listener removed) must take effect like
  // removeEventListener: the inner-invoke loop keeps iterating its captured
  // snapshot but skips the now-removed listeners. The crucial guarantee is that
  // the loop neither crashes nor corrupts iteration when the live list is
  // emptied underneath it (the bug was clear() freeing the vector mid-loop).
  test("clearing all listeners during dispatch skips the rest without corruption", () => {
    const { port1 } = new MessageChannel();
    const order = [];
    port1.addEventListener("probe", () => {
      order.push("first");
      port1.close(); // marks port1's remaining listeners removed mid-dispatch
    });
    port1.addEventListener("probe", () => order.push("second"));
    port1.addEventListener("probe", () => order.push("third"));

    assert.equal(port1.dispatchEvent(new Event("probe")), true);
    assert.deepEqual(order, ["first"],
      "listeners removed by a mid-dispatch clear are skipped, like removeEventListener");

    // After dispatch unwinds, the deferred clear has fully taken effect.
    order.length = 0;
    assert.equal(port1.dispatchEvent(new Event("probe")), true);
    assert.deepEqual(order, [], "listeners are gone once dispatch returns to idle");
  });

  // A mid-dispatch clear must not stop listeners that ran before it; only the
  // ones still pending in the snapshot are skipped. Here the second listener
  // does the clear, so the first already ran and the third is skipped.
  test("a mid-dispatch clear only skips listeners that have not run yet", () => {
    const { port1 } = new MessageChannel();
    const order = [];
    port1.addEventListener("probe", () => order.push("first"));
    port1.addEventListener("probe", () => {
      order.push("second");
      port1.close();
    });
    port1.addEventListener("probe", () => order.push("third"));

    assert.equal(port1.dispatchEvent(new Event("probe")), true);
    assert.deepEqual(order, ["first", "second"], "already-run listeners are unaffected; pending one skipped");
  });

  // A listener that throws is reported, not propagated, and must not stop the
  // remaining listeners; once-listeners are still removed exactly once. Verify
  // both invariants hold together after the snapshot-liveness rework.
  test("throwing once-listeners are removed and do not stop later listeners", () => {
    const target = new EventTarget();
    const order = [];
    let onceCalls = 0;
    target.addEventListener("t", () => {
      order.push("throwing-once");
      onceCalls++;
      throw new Error("boom");
    }, { once: true });
    target.addEventListener("t", () => order.push("after"));

    assert.equal(target.dispatchEvent(new Event("t")), true);
    assert.deepEqual(order, ["throwing-once", "after"]);

    order.length = 0;
    assert.equal(target.dispatchEvent(new Event("t")), true);
    assert.deepEqual(order, ["after"], "the throwing once-listener was removed");
    assert.equal(onceCalls, 1, "the once-listener fired exactly once");
  });

  // Re-entrant removal of a not-yet-invoked listener during dispatch must drop
  // it from the in-flight snapshot (liveness is re-validated by stable order,
  // not by a captured index).
  test("removing a pending listener during dispatch skips it", () => {
    const target = new EventTarget();
    const order = [];
    const second = () => order.push("second");
    target.addEventListener("r", () => {
      order.push("first");
      target.removeEventListener("r", second);
    });
    target.addEventListener("r", second);
    target.addEventListener("r", () => order.push("third"));

    assert.equal(target.dispatchEvent(new Event("r")), true);
    assert.deepEqual(order, ["first", "third"], "removed pending listener must be skipped");
  });
});

describe("listener exception isolation, signal option validation and isTrusted", () => {
  // WHATWG DOM "inner invoke": a throwing listener is reported, not
  // propagated, and must not stop the remaining listeners.
  test("a throwing listener does not stop the remaining listeners", () => {
    const target = new EventTarget();
    const order = [];
    target.addEventListener("boom", () => {
      order.push("first");
      throw new Error("listener failure");
    });
    target.addEventListener("boom", () => order.push("second"));
    assert.equal(target.dispatchEvent(new Event("boom")), true, "dispatchEvent must not rethrow listener exceptions");
    assert.deepEqual(order, ["first", "second"]);
  });

  test("a throwing global listener does not stop later global listeners", () => {
    const order = [];
    function thrower() {
      order.push("thrower");
      throw new Error("global listener failure");
    }
    function follower() {
      order.push("follower");
    }
    try {
      addEventListener("collo-throwing-global", thrower);
      addEventListener("collo-throwing-global", follower);
      assert.equal(dispatchEvent(new Event("collo-throwing-global")), true);
      assert.deepEqual(order, ["thrower", "follower"]);
    } finally {
      removeEventListener("collo-throwing-global", thrower);
      removeEventListener("collo-throwing-global", follower);
    }
  });

  // WebIDL: AddEventListenerOptions.signal is a non-nullable AbortSignal, so
  // a present null (or any non-AbortSignal) is a TypeError; undefined means
  // the member is absent.
  test("addEventListener rejects present-but-null and non-AbortSignal signal options", () => {
    const target = new EventTarget();
    const listener = () => {};
    assert.throws(() => target.addEventListener("x", listener, { signal: null }), TypeError);
    assert.throws(() => target.addEventListener("x", listener, { signal: {} }), TypeError);
    assert.throws(() => target.addEventListener("x", listener, { signal: 1 }), TypeError);
    assert.throws(() => target.addEventListener("x", listener, { signal: AbortSignal }), TypeError);
    assert.throws(() => addEventListener("collo-null-signal", listener, { signal: null }), TypeError);

    let calls = 0;
    const counter = () => calls++;
    target.addEventListener("count", counter, { signal: undefined });
    target.dispatchEvent(new Event("count"));
    assert.equal(calls, 1, "signal: undefined means the member is absent");
    target.removeEventListener("count", counter);
  });

  // Spec dispatchEvent step 2: events dispatched from script are untrusted,
  // even when the event object itself was created by the runtime.
  test("public dispatchEvent downgrades trusted events to untrusted", () => {
    const controller = new AbortController();
    let captured = null;
    controller.signal.addEventListener("abort", event => { captured = event; });
    controller.abort();
    assert.equal(captured.isTrusted, true, "internal abort event stays trusted");

    const target = new EventTarget();
    let redispatchTrusted = null;
    target.addEventListener("abort", event => { redispatchTrusted = event.isTrusted; });
    assert.equal(target.dispatchEvent(captured), true);
    assert.equal(redispatchTrusted, false, "script dispatch must clear isTrusted");
    assert.equal(captured.isTrusted, false);
  });

  test("initEvent resets isTrusted to false", () => {
    const controller = new AbortController();
    let captured = null;
    controller.signal.addEventListener("abort", event => { captured = event; });
    controller.abort();
    assert.equal(captured.isTrusted, true);
    captured.initEvent("renamed", true, true);
    assert.equal(captured.type, "renamed");
    assert.equal(captured.isTrusted, false);
  });
});

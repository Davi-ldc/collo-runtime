// Collo compatibility contract derived from Bun v1.3.14:
// - reference/bun-v1.3.14/test/js/web/workers/message-channel.test.ts
// - reference/bun-v1.3.14/test/js/web/workers/message-port-pipe.test.ts

function flushMessages() {
  return Promise.resolve().then(() => Promise.resolve()).then(() => new Promise(resolve => setTimeout(resolve, 0)));
}

function descriptor(obj, key) {
  const desc = Object.getOwnPropertyDescriptor(obj, key);
  assert(desc, `${String(key)} descriptor should exist`);
  return desc;
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

test("MessageChannel and MessagePort globals/descriptors", () => {
  assert.equal(typeof MessageChannel, "function");
  assert.equal(typeof MessagePort, "function");
  assert.equal(MessageChannel.length, 0);
  assert.equal(MessagePort.length, 0);
  assert.equal(MessageChannel.name, "MessageChannel");
  assert.equal(MessagePort.name, "MessagePort");
  assert.throws(() => MessageChannel(), TypeError);
  assert.throws(() => MessagePort(), TypeError);
  assert.throws(() => new MessagePort(), TypeError);

  assertDataDescriptor(descriptor(globalThis, "MessageChannel"), MessageChannel, true, true, true, "global MessageChannel");
  assertDataDescriptor(descriptor(globalThis, "MessagePort"), MessagePort, true, true, true, "global MessagePort");
  assertFunctionShape(MessageChannel, "MessageChannel", 0, true);
  assertFunctionShape(MessagePort, "MessagePort", 0, true);
  assertDataDescriptor(descriptor(MessageChannel, "prototype"), MessageChannel.prototype, false, false, false, "MessageChannel.prototype");
  assertDataDescriptor(descriptor(MessagePort, "prototype"), MessagePort.prototype, false, false, false, "MessagePort.prototype");
  assertDataDescriptor(descriptor(MessageChannel.prototype, "constructor"), MessageChannel, true, false, true, "MessageChannel.prototype.constructor");
  assertDataDescriptor(descriptor(MessagePort.prototype, "constructor"), MessagePort, true, false, true, "MessagePort.prototype.constructor");
  assert.equal(Object.getPrototypeOf(MessagePort), EventTarget);
  assert.equal(Object.getPrototypeOf(MessagePort.prototype), EventTarget.prototype);

  assert.deepEqual(Object.getOwnPropertyNames(MessageChannel.prototype), ["constructor", "port1", "port2"]);
  for (const key of ["port1", "port2"]) {
    const property = descriptor(MessageChannel.prototype, key);
    assert.equal(typeof property.get, "function");
    assert.equal(property.set, undefined);
    assert.equal(property.enumerable, true);
    assert.equal(property.configurable, true);
    assertFunctionShape(property.get, `get ${key}`, 0, false, `MessageChannel.${key} getter`);
    assert.throws(() => property.get.call({}), TypeError);
  }

  for (const key of ["onmessage", "onmessageerror"]) {
    const property = descriptor(MessagePort.prototype, key);
    assert.equal(typeof property.get, "function");
    assert.equal(typeof property.set, "function");
    assert.equal(property.enumerable, true);
    assert.equal(property.configurable, true);
    assertFunctionShape(property.get, `get ${key}`, 0, false, `MessagePort.${key} getter`);
    assertFunctionShape(property.set, `set ${key}`, 1, false, `MessagePort.${key} setter`);
    assert.throws(() => property.get.call({}), TypeError);
    assert.throws(() => property.set.call({}, null), TypeError);
  }
  for (const key of ["postMessage", "start", "close", "ref", "unref", "hasRef"]) {
    const property = descriptor(MessagePort.prototype, key);
    assert.equal(typeof property.value, "function");
    assert.equal(property.value.length, key === "postMessage" ? 1 : 0, `${key} length`);
    assert.equal(property.enumerable, true);
    assert.equal(property.configurable, true);
    assert.equal(property.writable, true);
    assertFunctionShape(property.value, key, key === "postMessage" ? 1 : 0, false, `MessagePort.${key}`);
    assert.throws(() => property.value.call({}), TypeError);
  }

  const channel = new MessageChannel();
  assert.equal(Object.prototype.toString.call(channel), "[object MessageChannel]");
  assert.equal(MessageChannel.prototype[Symbol.toStringTag], "MessageChannel");
  assert.equal(MessagePort.prototype[Symbol.toStringTag], "MessagePort");
  assert(channel.port1 instanceof MessagePort);
  assert(channel.port2 instanceof MessagePort);
  assert(channel.port1 instanceof EventTarget);
  assert.equal(Object.prototype.toString.call(channel.port1), "[object MessagePort]");
  assert.equal(channel.port1.onmessage, null);
  assert.equal(channel.port1.onmessageerror, null);
  channel.port1.close();
  channel.port2.close();
});

test("MessagePort ref unref and hasRef match Bun server-side shape", () => {
  const { port1, port2 } = new MessageChannel();
  assert.equal(port1.hasRef(), false);
  assert.equal(port1.ref(), undefined);
  assert.equal(port1.hasRef(), true);
  assert.equal(port1.unref(), undefined);
  assert.equal(port1.hasRef(), false);
  assert.throws(() => MessagePort.prototype.ref.call({}), TypeError);
  assert.throws(() => MessagePort.prototype.unref.call({}), TypeError);
  assert.throws(() => MessagePort.prototype.hasRef.call({}), TypeError);
  port1.close();
  port2.close();
});

test("MessagePort delivers onmessage and buffered messages in FIFO order", async () => {
  const { port1, port2 } = new MessageChannel();
  const got = [];
  port1.postMessage("a");
  port1.postMessage("b");
  port2.onmessage = event => got.push(event.data);
  await flushMessages();
  assert.deepEqual(got, ["a", "b"]);
  port1.close();
  port2.close();
});

test("MessagePort handler attributes accept callable object null and non-callable values", () => {
  const { port1, port2 } = new MessageChannel();
  const calls = [];
  const objectHandler = {
    handleEvent(event) {
      calls.push(`object:${event.data}:${this === objectHandler}`);
    },
  };
  port2.onmessage = objectHandler;
  assert.equal(port2.onmessage, objectHandler);
  port2.dispatchEvent(new MessageEvent("message", { data: "a" }));

  const plain = { value: 1 };
  port2.onmessage = plain;
  assert.equal(port2.onmessage, plain);
  port2.dispatchEvent(new MessageEvent("message", { data: "ignored" }));

  port2.onmessage = null;
  assert.equal(port2.onmessage, null);
  port2.dispatchEvent(new MessageEvent("message", { data: "ignored" }));
  assert.deepEqual(calls, ["object:a:true"]);
  port1.close();
  port2.close();
});

test("MessagePort onmessage keeps EventTarget ordering", () => {
  const listenerFirst = new MessageChannel();
  const listenerFirstEvents = [];
  listenerFirst.port1.addEventListener("message", () => listenerFirstEvents.push("listener"));
  listenerFirst.port1.onmessage = () => listenerFirstEvents.push("handler");
  listenerFirst.port1.dispatchEvent(new MessageEvent("message"));
  assert.deepEqual(listenerFirstEvents, ["listener", "handler"]);
  listenerFirst.port1.close();
  listenerFirst.port2.close();

  const handlerFirst = new MessageChannel();
  const handlerFirstEvents = [];
  handlerFirst.port1.onmessage = () => handlerFirstEvents.push("handler");
  handlerFirst.port1.addEventListener("message", () => handlerFirstEvents.push("listener"));
  handlerFirst.port1.dispatchEvent(new MessageEvent("message"));
  assert.deepEqual(handlerFirstEvents, ["handler", "listener"]);
  handlerFirst.port1.close();
  handlerFirst.port2.close();
});

test("MessagePort addEventListener starts delivery and close stops queued delivery", async () => {
  const { port1, port2 } = new MessageChannel();
  const got = [];
  port2.addEventListener("message", event => {
    got.push(event.data);
    if (event.data === 2)
      port2.close();
  });
  for (let i = 1; i <= 5; i++)
    port1.postMessage(i);
  await flushMessages();
  assert.deepEqual(got, [1, 2]);
  port1.close();
});

test("MessagePort has microtask checkpoint between message events", async () => {
  const { port1, port2 } = new MessageChannel();
  const order = [];
  port2.onmessage = event => {
    order.push(`msg:${event.data}`);
    queueMicrotask(() => order.push(`mt:${event.data}`));
  };
  port1.postMessage(1);
  port1.postMessage(2);
  port1.postMessage(3);
  await flushMessages();
  assert.deepEqual(order, ["msg:1", "mt:1", "msg:2", "mt:2", "msg:3", "mt:3"]);
  port1.close();
  port2.close();
});

test("MessagePort transfers ArrayBuffer and detaches sender buffer", async () => {
  const { port1, port2 } = new MessageChannel();
  const buffer = new ArrayBuffer(8);
  new Uint8Array(buffer)[0] = 42;
  const received = new Promise(resolve => {
    port2.onmessage = event => resolve(event.data);
  });
  port1.postMessage(buffer, [buffer]);
  assert.equal(buffer.byteLength, 0);
  const cloned = await received;
  assert(cloned instanceof ArrayBuffer);
  assert.equal(cloned.byteLength, 8);
  assert.equal(new Uint8Array(cloned)[0], 42);
  port1.close();
  port2.close();
});

test("MessagePort close is idempotent and postMessage after peer close is a no-op", async () => {
  const { port1, port2 } = new MessageChannel();
  let delivered = false;
  port2.onmessage = () => { delivered = true; };
  assert.equal(port1.close(), undefined);
  assert.equal(port1.close(), undefined);
  assert.equal(port1.postMessage("after-close"), undefined);
  assert.equal(port2.postMessage("peer-after-close"), undefined);
  await flushMessages();
  assert.equal(delivered, false);
  port2.close();
});

test("MessagePort transfers MessagePort through event.ports and cloned data identity", async () => {
  const channel = new MessageChannel();
  const carried = new MessageChannel();
  const received = new Promise(resolve => {
    channel.port2.onmessage = event => resolve(event);
  });

  channel.port1.postMessage({ port: carried.port1 }, [carried.port1]);
  const event = await received;
  assert(event instanceof MessageEvent);
  assert.equal(event.origin, "");
  assert.equal(event.lastEventId, "");
  assert.equal(event.source, null);
  assert(Array.isArray(event.ports));
  assert.equal(Object.isFrozen(event.ports), true);
  assert.equal(event.ports.length, 1);
  assert(event.ports[0] instanceof MessagePort);
  assert.equal(event.data.port, event.ports[0]);

  const reply = new Promise(resolve => {
    carried.port2.onmessage = ev => resolve(ev.data);
  });
  event.ports[0].postMessage("via transferred port");
  assert.equal(await reply, "via transferred port");

  channel.port1.close();
  channel.port2.close();
  carried.port2.close();
  event.ports[0].close();
});

test("MessagePort transfer validation is fail-closed", async () => {
  const channel = new MessageChannel();
  const extra = new MessageChannel();
  assert.throws(() => channel.port1.postMessage("self", [channel.port1]), DOMException);
  assert.throws(() => channel.port1.postMessage("peer", [channel.port2]), DOMException);
  assert.throws(() => channel.port1.postMessage("duplicate", [extra.port1, extra.port1]), DOMException);
  assert.throws(() => channel.port1.postMessage("not-port", [{}]), DOMException);
  assert.throws(() => channel.port1.postMessage("bad-list", "not iterable"), TypeError);
  const optionsOnly = new MessageChannel();
  assert.doesNotThrow(() => optionsOnly.port1.postMessage("empty-options", {}));
  assert.doesNotThrow(() => optionsOnly.port1.postMessage("empty-transfer-options", { transfer: [] }));
  optionsOnly.port1.close();
  optionsOnly.port2.close();
  const buffer = new ArrayBuffer(4);
  assert.throws(() => channel.port1.postMessage("mixed", [buffer, channel.port1]), DOMException);
  assert.equal(buffer.byteLength, 4);

  const received = new Promise(resolve => {
    channel.port2.onmessage = event => resolve(event.ports[0]);
  });
  channel.port1.postMessage("still transferable", [extra.port1]);
  const transferred = await received;
  assert(transferred instanceof MessagePort);
  assert.throws(() => extra.port1.addEventListener("message", () => {}), DOMException);
  transferred.close();

  const optionsChannel = new MessageChannel();
  const optionsReceived = new Promise(resolve => {
    channel.port2.onmessage = event => resolve(event.ports[0]);
  });
  channel.port1.postMessage("options transfer", { transfer: [optionsChannel.port1] });
  const optionsTransferred = await optionsReceived;
  assert(optionsTransferred instanceof MessagePort);
  optionsTransferred.close();
  optionsChannel.port2.close();
  channel.port1.close();
  channel.port2.close();
  extra.port2.close();
});

test("MessagePort postMessage queue cap throws before transfer commit", () => {
  const { port1, port2 } = new MessageChannel();
  for (let index = 0; index < 1024; index++)
    port1.postMessage({ index });

  const buffer = new ArrayBuffer(8);
  const error = assert.throws(() => port1.postMessage(buffer, [buffer]), DOMException);
  assert.equal(error.name, "QuotaExceededError");
  assert.equal(buffer.byteLength, 8);
  port1.close();
  port2.close();
});

test("MessagePort postMessage peer loss does not commit transfers", () => {
  const closed = new MessageChannel();
  const closedBuffer = new ArrayBuffer(8);
  closed.port2.close();
  closed.port1.postMessage(closedBuffer, [closedBuffer]);
  assert.equal(closedBuffer.byteLength, 8);
  closed.port1.close();

  const sender = new MessageChannel();
  const carried = new MessageChannel();
  const buffer = new ArrayBuffer(4);
  const payload = {};
  Object.defineProperty(payload, "closePeer", {
    enumerable: true,
    get() {
      sender.port2.close();
      return 1;
    },
  });

  sender.port1.postMessage(payload, [buffer, carried.port1]);
  assert.equal(buffer.byteLength, 4);
  assert.doesNotThrow(() => carried.port1.addEventListener("message", () => {}));
  sender.port1.close();
  carried.port1.close();
  carried.port2.close();
});

test("MessagePort listener clear during dispatch does not reuse old snapshot order", () => {
  const { port1, port2 } = new MessageChannel();
  const calls = [];
  function later() {
    calls.push("later");
  }
  function first() {
    calls.push("first");
    port1.close();
    port1.addEventListener("message", () => calls.push("new-first-slot"));
    port1.addEventListener("message", later);
  }

  port1.addEventListener("message", first);
  port1.addEventListener("message", later);
  port1.dispatchEvent(new MessageEvent("message"));
  assert.deepEqual(calls, ["first"]);
  port2.close();
});

test("MessagePort mixed transfers validate after getters before detaching", () => {
  const sender = new MessageChannel();
  const transferred = new MessageChannel();
  const buffer = new ArrayBuffer(4);
  const payload = {};
  Object.defineProperty(payload, "closePort", {
    enumerable: true,
    get() {
      transferred.port1.close();
      return 1;
    },
  });

  const error = assert.throws(
    () => sender.port1.postMessage(payload, [buffer, transferred.port1]),
    DOMException,
  );
  assert.equal(error.name, "DataCloneError");
  assert.equal(buffer.byteLength, 4);
  sender.port1.close();
  sender.port2.close();
  transferred.port2.close();
});

test("structuredClone transfers MessagePort", async () => {
  const { port1, port2 } = new MessageChannel();
  const cloned = structuredClone({ port: port1 }, { transfer: [port1] });
  assert(cloned.port instanceof MessagePort);
  const received = new Promise(resolve => {
    port2.onmessage = event => resolve(event.data);
  });
  cloned.port.postMessage("from clone");
  assert.equal(await received, "from clone");
  assert.throws(() => structuredClone(cloned.port), DOMException);
  cloned.port.close();
  port2.close();
});

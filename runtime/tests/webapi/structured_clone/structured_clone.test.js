// Collo compatibility contract derived from Bun v1.3.14:
// - reference/bun-v1.3.14/test/js/web/workers/structured-clone.test.ts
// - reference/bun-v1.3.14/test/js/web/structured-clone-fastpath.test.ts
// - reference/bun-v1.3.14/test/js/web/structured-clone-blob-file.test.ts

function assertDataCloneError(fn) {
  const err = assert.throws(fn, DOMException);
  assert.equal(err.name, "DataCloneError");
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

test("structuredClone global descriptor", () => {
  assert.equal(typeof structuredClone, "function");
  assert.equal(structuredClone.length, 1);
  assert.equal(structuredClone.name, "structuredClone");
  assertDataDescriptor(descriptor(globalThis, "structuredClone"), structuredClone, true, false, true, "global structuredClone");
  assertDataDescriptor(descriptor(structuredClone, "name"), "structuredClone", false, false, true, "structuredClone.name");
  assertDataDescriptor(descriptor(structuredClone, "length"), 1, false, false, true, "structuredClone.length");
  assert.equal(Object.hasOwn(structuredClone, "prototype"), false);
  assert.throws(() => structuredClone(), TypeError);
});

test("structuredClone primitives", () => {
  assert.equal(structuredClone(undefined), undefined);
  assert.equal(structuredClone(null), null);
  assert.equal(structuredClone(true), true);
  assert.equal(structuredClone(false), false);
  assert.equal(structuredClone("hello"), "hello");
  assert.equal(structuredClone(42), 42);
  assert(Object.is(structuredClone(-0), -0));
  assert(Number.isNaN(structuredClone(NaN)));
  assert.equal(structuredClone(1n), 1n);
});

test("structuredClone treats missing transfer option as absent", () => {
  assert.deepEqual(structuredClone({ ok: true }, {}), { ok: true });
});

test("structuredClone rejects uncloneable values", () => {
  assertDataCloneError(() => structuredClone(Symbol("x")));
  assertDataCloneError(() => structuredClone(() => {}));
  assertDataCloneError(() => structuredClone({ fn() {} }));
});

test("structuredClone plain objects and arrays", () => {
  const input = {
    name: "demo",
    values: [1, "two", true, null, undefined, { nested: 3 }],
  };
  const cloned = structuredClone(input);
  assert.deepEqual(cloned, input);
  assert(cloned !== input);
  assert(cloned.values !== input.values);
  assert(cloned.values[5] !== input.values[5]);
});

test("structuredClone copies enumerable string and symbol properties through getters", () => {
  const symbol = Symbol("cloned");
  const hiddenSymbol = Symbol("hidden");
  const input = {};
  let getterReads = 0;
  Object.defineProperty(input, "hidden", { value: 1, enumerable: false });
  Object.defineProperty(input, hiddenSymbol, { value: 4, enumerable: false });
  Object.defineProperty(input, "accessor", {
    enumerable: true,
    get() {
      getterReads++;
      return { value: 2 };
    },
  });
  input[symbol] = 3;

  const cloned = structuredClone(input);
  assert.equal(getterReads, 1);
  assert.deepEqual(cloned.accessor, { value: 2 });
  assert.equal(cloned.accessor === input.accessor, false);
  assert.equal(Object.hasOwn(cloned, "hidden"), false);
  assert.equal(cloned[symbol], 3);
  assert.equal(cloned[hiddenSymbol], undefined);
  assertDataDescriptor(descriptor(cloned, "accessor"), cloned.accessor, true, true, true, "cloned accessor data property");
  assertDataDescriptor(descriptor(cloned, symbol), 3, true, true, true, "cloned symbol data property");
});

test("structuredClone preserves cycles and shared references", () => {
  const shared = { value: 1 };
  const input = { a: shared, b: shared };
  input.self = input;
  const cloned = structuredClone(input);
  assert(cloned !== input);
  assert(cloned.self === cloned);
  assert(cloned.a === cloned.b);
  assert(cloned.a !== shared);
});

test("structuredClone arrays preserve holes and named properties", () => {
  const input = [1, , 3];
  input.extra = "value";
  const cloned = structuredClone(input);
  assert.equal(cloned.length, 3);
  assert.equal(cloned[0], 1);
  assert.equal(1 in cloned, false);
  assert.equal(cloned[2], 3);
  assert.equal(cloned.extra, "value");
});

test("structuredClone normalizes custom prototypes", () => {
  class CustomArray extends Array {}
  const array = new CustomArray(1, 2, 3);
  const arrayClone = structuredClone(array);
  assert(Array.isArray(arrayClone));
  assert.equal(arrayClone instanceof CustomArray, false);

  const object = Object.create({ inherited: 1 });
  object.own = 2;
  const objectClone = structuredClone(object);
  assert.equal(Object.getPrototypeOf(objectClone), Object.prototype);
  assert.equal(objectClone.own, 2);
  assert.equal(objectClone.inherited, undefined);
});

test("structuredClone Date and RegExp", () => {
  const date = new Date(1234567890);
  const dateClone = structuredClone(date);
  assert(dateClone instanceof Date);
  assert.equal(dateClone.getTime(), date.getTime());

  const regexp = /collo/gi;
  regexp.lastIndex = 2;
  const regexpClone = structuredClone(regexp);
  assert(regexpClone instanceof RegExp);
  assert.equal(regexpClone.source, regexp.source);
  assert.equal(regexpClone.flags, regexp.flags);
  assert.equal(regexpClone.lastIndex, 0);
});

test("structuredClone Map and Set", () => {
  const key = { id: 1 };
  const value = { name: "value" };
  const map = new Map([[key, value]]);
  const mapClone = structuredClone(map);
  assert(mapClone instanceof Map);
  assert.equal(mapClone.size, 1);
  const [clonedKey, clonedValue] = mapClone.entries().next().value;
  assert.deepEqual(clonedKey, key);
  assert.deepEqual(clonedValue, value);
  assert(clonedKey !== key);
  assert(clonedValue !== value);

  const set = new Set([key, value]);
  const setClone = structuredClone(set);
  assert(setClone instanceof Set);
  assert.equal(setClone.size, 2);
  for (const item of setClone)
    assert(item !== key && item !== value);

  const originalMapIterator = Map.prototype[Symbol.iterator];
  const originalSetIterator = Set.prototype[Symbol.iterator];
  try {
    Map.prototype[Symbol.iterator] = () => {
      throw new Error("structuredClone must not call Map iterators");
    };
    Set.prototype[Symbol.iterator] = () => {
      throw new Error("structuredClone must not call Set iterators");
    };
    assert.equal(structuredClone(new Map([[key, value]])).size, 1);
    assert.equal(structuredClone(new Set([key, value])).size, 2);
  } finally {
    Map.prototype[Symbol.iterator] = originalMapIterator;
    Set.prototype[Symbol.iterator] = originalSetIterator;
  }
});

test("structuredClone Blob and File", async () => {
  const blob = new Blob(["hello"], { type: "text/plain" });
  const blobClone = structuredClone(blob);
  assert(blobClone instanceof Blob);
  assert.equal(blobClone.size, 5);
  assert.equal(blobClone.type, "text/plain");
  assert.equal(await blobClone.text(), "hello");

  const file = new File(["content"], "demo.txt", {
    type: "text/plain",
    lastModified: 1234567890000,
  });
  const fileClone = structuredClone(file);
  assert(fileClone instanceof File);
  assert.equal(fileClone.name, "demo.txt");
  assert.equal(fileClone.size, 7);
  assert.equal(fileClone.type, "text/plain");
  assert.equal(fileClone.lastModified, 1234567890000);
  assert.equal(await fileClone.text(), "content");
});

test("structuredClone ArrayBuffer and views", () => {
  const buffer = new ArrayBuffer(8);
  const bytes = new Uint8Array(buffer);
  bytes.set([1, 2, 3, 4, 5, 6, 7, 8]);

  const bufferClone = structuredClone(buffer);
  assert(bufferClone instanceof ArrayBuffer);
  assert(bufferClone !== buffer);
  assert.deepEqual(Array.from(new Uint8Array(bufferClone)), Array.from(bytes));

  const view = new Uint16Array(buffer, 2, 2);
  const viewClone = structuredClone(view);
  assert(viewClone instanceof Uint16Array);
  assert.deepEqual(Array.from(viewClone), Array.from(view));
  viewClone[0] = 999;
  assert(view[0] !== 999);

  const dataView = new DataView(buffer, 1, 4);
  const dataViewClone = structuredClone(dataView);
  assert(dataViewClone instanceof DataView);
  assert.equal(dataViewClone.byteOffset, 1);
  assert.equal(dataViewClone.byteLength, 4);
  assert.equal(dataViewClone.getUint8(0), dataView.getUint8(0));
});

test("structuredClone ArrayBuffer transfer detaches after successful clone", () => {
  const buffer = new ArrayBuffer(4);
  new Uint8Array(buffer).set([9, 8, 7, 6]);
  const cloned = structuredClone(buffer, { transfer: [buffer] });
  assert.equal(buffer.byteLength, 0);
  assert.deepEqual(Array.from(new Uint8Array(cloned)), [9, 8, 7, 6]);
});

test("structuredClone transfer validation is fail-closed", () => {
  const buffer = new ArrayBuffer(1);
  assertDataCloneError(() => structuredClone(buffer, { transfer: [buffer, buffer] }));
  assert.equal(buffer.byteLength, 1);
  assertDataCloneError(() => structuredClone(new Blob([]), { transfer: [new Blob([])] }));

  const lateFailureBuffer = new ArrayBuffer(1);
  const input = { buffer: lateFailureBuffer };
  Object.defineProperty(input, "boom", {
    enumerable: true,
    get() {
      throw new Error("late clone failure");
    },
  });
  assert.throws(() => structuredClone(input, { transfer: [lateFailureBuffer] }), Error);
  assert.equal(lateFailureBuffer.byteLength, 1);
});

test("structuredClone mixed transfers validate after getters before detaching", () => {
  const buffer = new ArrayBuffer(4);
  const { port1, port2 } = new MessageChannel();
  const input = {};
  Object.defineProperty(input, "closePort", {
    enumerable: true,
    get() {
      port1.close();
      return 1;
    },
  });

  assertDataCloneError(() => structuredClone(input, { transfer: [buffer, port1] }));
  assert.equal(buffer.byteLength, 4);
  port2.close();
});

test("structuredClone enforces depth limit without detaching transfer list", () => {
  const buffer = new ArrayBuffer(2);
  let root = {};
  let cursor = root;
  for (let index = 0; index < 600; index++) {
    cursor.next = {};
    cursor = cursor.next;
  }

  assertDataCloneError(() => structuredClone(root, { transfer: [buffer] }));
  assert.equal(buffer.byteLength, 2);
});

test("structuredClone transfer option conversion", () => {
  const order = [];
  const buffer = new ArrayBuffer(2);
  const clone = structuredClone({ buffer }, {
    get transfer() {
      order.push("get-transfer");
      return {
        *[Symbol.iterator]() {
          order.push("iterate-transfer");
          yield buffer;
        },
      };
    },
  });
  assert.deepEqual(order, ["get-transfer", "iterate-transfer"]);
  assert.equal(buffer.byteLength, 0);
  assert.deepEqual(Array.from(new Uint8Array(clone.buffer)), [0, 0]);

  assert.throws(() => structuredClone("x", 1), TypeError);
  assert.throws(() => structuredClone("x", { transfer: 1 }), TypeError);
});

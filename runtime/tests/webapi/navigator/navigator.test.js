// Collo compatibility contract derived from Bun v1.3.14:
// - reference/bun-v1.3.14/src/jsc/bindings/ZigGlobalObject.cpp

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

test("navigator is a global object with Bun-compatible descriptor shape", () => {
  assert.equal(typeof navigator, "object");
  assert(navigator !== null);
  assert.equal(globalThis.navigator, navigator);

  const globalDesc = descriptor(globalThis, "navigator");
  assertDataDescriptor(globalDesc, navigator, true, true, true, "global navigator");

  assert.equal(typeof Navigator, "undefined");
  assert.equal(Object.getPrototypeOf(navigator), Object.prototype);
  assert.equal(Object.prototype.toString.call(navigator), "[object Navigator]");
  assert.equal(navigator.constructor, Object);
  assert.equal(Object.hasOwn(navigator, "constructor"), false);
});

test("navigator exposes exactly the expected own public properties", () => {
  assert.deepEqual(Object.keys(navigator), ["userAgent", "platform", "hardwareConcurrency"]);
  assert.deepEqual(Object.getOwnPropertyNames(navigator), ["userAgent", "platform", "hardwareConcurrency"]);
  assert.deepEqual(Object.getOwnPropertySymbols(navigator), [Symbol.toStringTag]);
  assert.equal("userAgent" in navigator, true);
  assert.equal("platform" in navigator, true);
  assert.equal("hardwareConcurrency" in navigator, true);
});

test("navigator exposes own mutable runtime identity fields", () => {
  const userAgent = descriptor(navigator, "userAgent");
  const platform = descriptor(navigator, "platform");
  const hardwareConcurrency = descriptor(navigator, "hardwareConcurrency");

  assert.equal(typeof navigator.userAgent, "string");
  assert(navigator.userAgent.includes("Collo"));
  assert.equal(typeof navigator.platform, "string");
  assert(navigator.platform.length > 0);
  assert.equal(typeof navigator.hardwareConcurrency, "number");
  assert(Number.isInteger(navigator.hardwareConcurrency));
  assert(navigator.hardwareConcurrency >= 1);
  assert(navigator.hardwareConcurrency <= 8);

  assertDataDescriptor(userAgent, navigator.userAgent, true, true, true, "navigator.userAgent");
  assertDataDescriptor(platform, navigator.platform, true, true, true, "navigator.platform");
  assertDataDescriptor(hardwareConcurrency, navigator.hardwareConcurrency, true, true, true, "navigator.hardwareConcurrency");

  const original = {
    userAgent: navigator.userAgent,
    platform: navigator.platform,
    hardwareConcurrency: navigator.hardwareConcurrency,
  };
  try {
    navigator.userAgent = "test-agent";
    navigator.platform = "test-platform";
    navigator.hardwareConcurrency = 123;
    assert.equal(navigator.userAgent, "test-agent");
    assert.equal(navigator.platform, "test-platform");
    assert.equal(navigator.hardwareConcurrency, 123);

    Object.defineProperty(navigator, "hardwareConcurrency", {
      value: 321,
      writable: true,
      enumerable: true,
      configurable: true,
    });
    assert.equal(navigator.hardwareConcurrency, 321);

    assert.equal(delete navigator.platform, true);
    assert.equal(Object.hasOwn(navigator, "platform"), false);
  } finally {
    Object.defineProperty(navigator, "userAgent", {
      value: original.userAgent,
      writable: true,
      enumerable: true,
      configurable: true,
    });
    Object.defineProperty(navigator, "platform", {
      value: original.platform,
      writable: true,
      enumerable: true,
      configurable: true,
    });
    Object.defineProperty(navigator, "hardwareConcurrency", {
      value: original.hardwareConcurrency,
      writable: true,
      enumerable: true,
      configurable: true,
    });
  }
});

test("navigator toStringTag is own non-enumerable read-only metadata", () => {
  const tag = descriptor(navigator, Symbol.toStringTag);
  assertDataDescriptor(tag, "Navigator", false, false, true, "navigator Symbol.toStringTag");
  assert.equal(Object.prototype.toString.call(navigator), "[object Navigator]");

  const original = navigator[Symbol.toStringTag];
  try {
    assert.throws(() => {
      navigator[Symbol.toStringTag] = "Other";
    }, TypeError);
    assert.equal(navigator[Symbol.toStringTag], "Navigator");
    assert.equal(delete navigator[Symbol.toStringTag], true);
    assert.equal(Object.prototype.toString.call(navigator), "[object Object]");
  } finally {
    Object.defineProperty(navigator, Symbol.toStringTag, {
      value: original,
      writable: false,
      enumerable: false,
      configurable: true,
    });
  }
});

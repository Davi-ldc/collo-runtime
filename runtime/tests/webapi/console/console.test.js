// Collo compatibility contract derived from Bun v1.3.14:
// - reference/bun-v1.3.14/test/js/web/console/console-log.test.ts

const consoleMethods = [
  "assert",
  "clear",
  "count",
  "countReset",
  "debug",
  "dir",
  "dirxml",
  "error",
  "group",
  "groupCollapsed",
  "groupEnd",
  "info",
  "log",
  "table",
  "time",
  "timeEnd",
  "timeLog",
  "timeStamp",
  "trace",
  "warn",
];

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

test("console global has server-runtime descriptor shape", () => {
  assert.equal(typeof console, "object");
  assert(console !== null);
  assert.equal(globalThis.console, console);

  const globalDesc = descriptor(globalThis, "console");
  assertDataDescriptor(globalDesc, console, true, false, true, "global console");

  assert.equal(typeof Object.getPrototypeOf(console), "object");
  assert.equal(Object.prototype.toString.call(console), "[object console]");
  assert.equal(Object.hasOwn(console, Symbol.toStringTag), true);
  assert.equal(console[Symbol.toStringTag], "console");
});

test("console standard methods are own mutable enumerable functions", () => {
  for (const name of consoleMethods) {
    const method = console[name];
    assert.equal(typeof method, "function", `${name} should be a function`);
    assert.equal(method.length, 0, `${name}.length`);

    assertDataDescriptor(descriptor(console, name), method, true, true, true, `console.${name}`);
    assert.equal(Object.hasOwn(method, "prototype"), false, `${name} should not have own prototype`);

    const length = descriptor(method, "length");
    assertDataDescriptor(length, 0, false, false, true, `${name}.length`);

    const functionName = descriptor(method, "name");
    assert.equal(typeof functionName.value, "string", `${name}.name should be a string`);
    assert.equal(functionName.writable, false, `${name}.name writable`);
    assert.equal(functionName.enumerable, false, `${name}.name enumerable`);
    assert.equal(functionName.configurable, true, `${name}.name configurable`);
  }
});

test("console methods are callable and return undefined", () => {
  assert.equal(console.assert(true, "hidden"), undefined);
  assert.equal(console.assert(false, "visible"), undefined);
  assert.equal(console.clear(), undefined);
  assert.equal(console.debug(), undefined);
  assert.equal(console.dir(), undefined);
  assert.equal(console.dirxml(), undefined);
  assert.equal(console.error(), undefined);
  assert.equal(console.group(), undefined);
  assert.equal(console.groupCollapsed(), undefined);
  assert.equal(console.groupEnd(), undefined);
  assert.equal(console.info(), undefined);
  assert.equal(console.log(), undefined);
  assert.equal(console.table(), undefined);
  assert.equal(console.time("collo-console-test"), undefined);
  assert.equal(console.timeLog("collo-console-test"), undefined);
  assert.equal(console.timeEnd("collo-console-test"), undefined);
  assert.equal(console.timeStamp("collo-console-test"), undefined);
  assert.equal(console.trace(), undefined);
  assert.equal(console.warn(), undefined);
});

test("console count methods accept default and explicit labels", () => {
  assert.equal(console.count(), undefined);
  assert.equal(console.count("collo-console-test"), undefined);
  assert.equal(console.countReset(), undefined);
  assert.equal(console.countReset("collo-console-test"), undefined);
});

test("console methods are receiver independent", () => {
  assert.equal(console.log.call(null), undefined);
  assert.equal(console.warn.call(undefined), undefined);
  assert.equal(console.assert.call({}, true), undefined);
  for (const name of consoleMethods) {
    const method = console[name];
    assert.equal(method.call(null), undefined, `${name} should tolerate null receiver`);
  }
});

test("console own methods can be overwritten and restored", () => {
  const original = console.log;
  try {
    console.log = function replacement() {
      return "replacement";
    };
    assert.equal(console.log(), "replacement");
    assert.equal(Object.keys(console).includes("log"), true);
  } finally {
    console.log = original;
  }
});

// Collo compatibility contract derived from Bun v1.3.14:
// - reference/bun-v1.3.14/test/js/web/web-globals.test.js

function cleanup(listener) {
  globalThis.onerror = null;
  if (listener) removeEventListener("error", listener);
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

test("reportError is installed as a global function", () => {
  assert.equal(typeof reportError, "function");
  assert.equal(reportError.name, "reportError");
  assert.equal(reportError.length, 1);
  assert.equal(Object.hasOwn(reportError, "prototype"), false);

  assertDataDescriptor(
    descriptor(globalThis, "reportError"),
    reportError,
    true,
    false,
    true,
    "global reportError");
  assertDataDescriptor(descriptor(reportError, "length"), 1, false, false, true, "reportError.length");
  assertDataDescriptor(descriptor(reportError, "name"), "reportError", false, false, true, "reportError.name");
});

test("reportError without an argument reports undefined", () => {
  let seen;
  function listener(event) {
    seen = event;
    event.preventDefault();
  }

  try {
    addEventListener("error", listener);
    assert.equal(reportError(), undefined);
  } finally {
    cleanup(listener);
  }

  assert.equal(seen.error, undefined);
  assert.equal(seen.message, "undefined");
  assert.equal(seen.cancelable, true);
});

// HTML's report an exception: a trusted, cancelable ErrorEvent, which the global onerror receives as (message,
// filename, lineno, colno, error).
test("reportError dispatches a trusted cancelable ErrorEvent at the global target", () => {
  const error = new Error("boom");
  const calls = [];

  function listener(event) {
    calls.push(`listener:${event.message}:${event.error === error}:${event.cancelable}:${event.isTrusted}`);
    event.preventDefault();
  }

  try {
    globalThis.onerror = (message, filename, lineno, colno, reported) => {
      calls.push(`handler:${message}:${filename}:${lineno}:${colno}:${reported === error}`);
    };
    addEventListener("error", listener);

    const result = reportError.call(null, error, "ignored");
    assert.equal(result, undefined);
    assert.deepEqual(calls, [
      "handler:boom::0:0:true",
      "listener:boom:true:true:true",
    ]);
  } finally {
    cleanup(listener);
  }
});

test("a global onerror that returns true cancels the reported error, and false does not", () => {
  let reported;
  function listener(event) {
    reported = event;
  }

  try {
    // The listener was added before onerror, so it runs first; each event is checked after its dispatch.
    addEventListener("error", listener);
    globalThis.onerror = () => true;
    reportError(new Error("cancel"));
    assert.equal(reported.defaultPrevented, true);
    globalThis.onerror = () => false;
    reportError(new Error("keep"));
    assert.equal(reported.defaultPrevented, false);
  } finally {
    cleanup(listener);
  }
});

// HTML's error reporting mode: while the global reports one exception, reporting another fires nothing, so an error
// listener that reports or throws cannot recurse.
test("reportError inside an error listener fires no second event, and a throwing listener is not rethrown", () => {
  const calls = [];
  function listener(event) {
    calls.push(event.message);
    reportError(new Error("nested"));
    throw new Error("listener failure");
  }

  try {
    addEventListener("error", listener);
    globalThis.onerror = () => {
      throw new Error("handler failure");
    };
    assert.doesNotThrow(() => reportError(new Error("outer")));
    assert.deepEqual(calls, ["outer"]);
    reportError(new Error("again"));
    assert.deepEqual(calls, ["outer", "again"]);
  } finally {
    cleanup(listener);
  }
});

test("reportError preserves primitive error values", () => {
  const seen = [];
  function listener(event) {
    seen.push({
      message: event.message,
      error: event.error,
      cancelable: event.cancelable,
      defaultPrevented: event.defaultPrevented,
    });
    event.preventDefault();
  }

  try {
    addEventListener("error", listener);
    reportError("plain");
    reportError(42);
  } finally {
    cleanup(listener);
  }

  assert.deepEqual(seen, [
    { message: "plain", error: "plain", cancelable: true, defaultPrevented: false },
    { message: "42", error: 42, cancelable: true, defaultPrevented: false },
  ]);
});

test("reportError does not invoke arbitrary object coercion while extracting message", () => {
  let coerced = false;
  const thrown = {
    toString() {
      coerced = true;
      return "bad";
    },
  };
  let seen;
  function listener(event) {
    seen = event;
    event.preventDefault();
  }

  try {
    addEventListener("error", listener);
    reportError(thrown);
  } finally {
    cleanup(listener);
  }

  assert.equal(coerced, false);
  assert.equal(seen.error, thrown);
  assert.equal(seen.message, "");
});

test("reportError supports symbol values without throwing", () => {
  const symbol = Symbol("reported");
  let seen;
  function listener(event) {
    seen = event;
    event.preventDefault();
  }

  try {
    addEventListener("error", listener);
    assert.doesNotThrow(() => reportError(symbol));
  } finally {
    cleanup(listener);
  }

  assert.equal(seen.error, symbol);
  assert.equal(seen.message, "");
});

test("reportError global binding is writable and configurable", () => {
  const original = reportError;
  try {
    globalThis.reportError = function replacement() {
      return "replacement";
    };
    assert.equal(reportError(), "replacement");

    assert.equal(delete globalThis.reportError, true);
    assert.equal(Object.hasOwn(globalThis, "reportError"), false);
  } finally {
    Object.defineProperty(globalThis, "reportError", {
      value: original,
      writable: true,
      enumerable: false,
      configurable: true,
    });
  }
});

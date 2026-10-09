const __colloWebApiTests = [];
let __colloWebApiPrefix = "";

function __colloFormat(value) {
  try {
    if (typeof value === "string") return JSON.stringify(value);
    if (typeof value === "function") return `[function ${value.name || "anonymous"}]`;
    return JSON.stringify(value);
  } catch (_) {
    return String(value);
  }
}

function __colloFail(message) {
  throw new Error(message);
}

function __colloErrorText(err) {
  const name = err && err.name ? `${err.name}: ` : "";
  const message = err && err.message ? String(err.message) : String(err);
  const stack = err && err.stack ? `\n${String(err.stack)}` : "";
  return `${name}${message}${stack}`;
}

function __colloSameValue(a, b) {
  return Object.is(a, b);
}

function __colloDeepEqual(a, b) {
  if (__colloSameValue(a, b)) return true;
  if (typeof a !== typeof b) return false;
  if (a === null || b === null) return a === b;
  if (typeof a !== "object") return false;
  if (Array.isArray(a) !== Array.isArray(b)) return false;
  const aKeys = Object.keys(a);
  const bKeys = Object.keys(b);
  if (aKeys.length !== bKeys.length) return false;
  for (const key of aKeys) {
    if (!Object.prototype.hasOwnProperty.call(b, key)) return false;
    if (!__colloDeepEqual(a[key], b[key])) return false;
  }
  return true;
}

function assert(value, message = "assertion failed") {
  if (!value) __colloFail(message);
}

assert.equal = function equal(actual, expected, message = "values differ") {
  if (!__colloSameValue(actual, expected))
    __colloFail(`${message}: expected ${__colloFormat(expected)}, got ${__colloFormat(actual)}`);
};

assert.deepEqual = function deepEqual(actual, expected, message = "values differ") {
  if (!__colloDeepEqual(actual, expected))
    __colloFail(`${message}: expected ${__colloFormat(expected)}, got ${__colloFormat(actual)}`);
};

assert.throws = function throws(fn, check, message = "function did not throw") {
  try {
    fn();
  } catch (err) {
    if (check instanceof RegExp) {
      assert(check.test(String(err && (err.stack || err.message || err))), `throw mismatch: ${err}`);
    } else if (typeof check === "function") {
      assert(err instanceof check, `throw type mismatch: expected ${check.name}, got ${err && err.name}`);
    } else if (typeof check === "string") {
      assert(String(err && (err.stack || err.message || err)).includes(check), `throw mismatch: ${err}`);
    }
    return err;
  }
  __colloFail(message);
};

assert.doesNotThrow = function doesNotThrow(fn, message = "function threw") {
  try {
    return fn();
  } catch (err) {
    __colloFail(`${message}: ${err && (err.stack || err.message || err)}`);
  }
};

function describe(name, fn) {
  const previous = __colloWebApiPrefix;
  __colloWebApiPrefix = previous ? `${previous} ${name}` : name;
  try {
    fn();
  } finally {
    __colloWebApiPrefix = previous;
  }
}

function test(name, fn) {
  const fullName = __colloWebApiPrefix ? `${__colloWebApiPrefix} ${name}` : name;
  const filter = globalThis.__colloWebApiTestFilter;
  if (typeof filter === "string" && filter.length !== 0 && !fullName.includes(filter)) return;
  __colloWebApiTests.push({ name: fullName, fn });
}

const it = test;

async function __colloRunWebApiTests() {
  const failures = [];
  for (const entry of __colloWebApiTests) {
    try {
      await entry.fn();
    } catch (err) {
      failures.push({
        name: entry.name,
        message: __colloErrorText(err).slice(0, 700),
      });
    }
  }
  return {
    ok: failures.length === 0,
    total: __colloWebApiTests.length,
    failures: failures.slice(0, 8),
  };
}

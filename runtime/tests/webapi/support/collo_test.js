const tests = [];
const beforeAllHooks = [];
const afterAllHooks = [];
const beforeEachHooks = [];
const afterEachHooks = [];
const nameStack = [];
let pendingExpectations = [];
const testTimeoutMs = 1500;

function format(value) {
  try {
    if (typeof value === "string") return JSON.stringify(value);
    if (typeof value === "function") return `[function ${value.name || "anonymous"}]`;
    return JSON.stringify(value);
  } catch (_) {
    return String(value);
  }
}

function fail(message) {
  throw new Error(message);
}

function errorText(err) {
  const name = err && err.name ? `${err.name}: ` : "";
  const message = err && err.message ? String(err.message) : String(err);
  const stack = err && err.stack ? `\n${String(err.stack)}` : "";
  return `${name}${message}${stack}`;
}

function sameValue(a, b) {
  return Object.is(a, b);
}

function deepEqual(a, b) {
  if (b instanceof AnyMatcher) return b.matches(a);
  if (b instanceof ObjectContainingMatcher) return b.matches(a);
  if (sameValue(a, b)) return true;
  if (typeof a !== typeof b) return false;
  if (a === null || b === null) return a === b;
  if (typeof a !== "object") return false;
  if (Array.isArray(a) !== Array.isArray(b)) return false;
  if (a instanceof Date || b instanceof Date)
    return a instanceof Date && b instanceof Date && sameValue(a.getTime(), b.getTime());
  if (ArrayBuffer.isView(a) || ArrayBuffer.isView(b)) {
    if (!ArrayBuffer.isView(a) || !ArrayBuffer.isView(b) || a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) {
      if (!sameValue(a[i], b[i])) return false;
    }
    return true;
  }

  const aKeys = Object.keys(a);
  const bKeys = Object.keys(b);
  if (aKeys.length !== bKeys.length) return false;
  for (const key of aKeys) {
    if (!Object.prototype.hasOwnProperty.call(b, key)) return false;
    if (!deepEqual(a[key], b[key])) return false;
  }
  return true;
}

function partialDeepEqual(actual, expected) {
  if (expected instanceof AnyMatcher) return expected.matches(actual);
  if (expected instanceof ObjectContainingMatcher) return expected.matches(actual);
  if (sameValue(actual, expected)) return true;
  if (expected === null || typeof expected !== "object") return false;
  if (actual === null || typeof actual !== "object") return false;

  for (const key of Object.keys(expected)) {
    if (!(key in Object(actual))) return false;
    if (!partialDeepEqual(actual[key], expected[key])) return false;
  }
  return true;
}

class AnyMatcher {
  constructor(type) {
    this.type = type;
  }

  matches(value) {
    if (this.type === String) return typeof value === "string" || value instanceof String;
    if (this.type === Number) return typeof value === "number" || value instanceof Number;
    if (this.type === Boolean) return typeof value === "boolean" || value instanceof Boolean;
    if (this.type === Function) return typeof value === "function";
    if (this.type === Object) return value !== null && typeof value === "object";
    return value instanceof this.type;
  }
}

class ObjectContainingMatcher {
  constructor(expected) {
    this.expected = expected;
  }

  matches(value) {
    return partialDeepEqual(value, this.expected);
  }
}

function fullName(name) {
  return nameStack.length === 0 ? name : `${nameStack.join(" ")} ${name}`;
}

export function describe(name, fn) {
  nameStack.push(String(name));
  try {
    fn();
  } finally {
    nameStack.pop();
  }
}

function registerTest(name, fn) {
  const registeredName = fullName(String(name));
  const filter = globalThis.__colloWebApiTestFilter;
  if (typeof filter === "string" && filter.length !== 0 && !registeredName.includes(filter)) return;
  tests.push({ name: registeredName, fn });
}

function formatEachName(name, args) {
  let index = 0;
  return String(name).replace(/%[sdifoOj]/g, () => {
    const value = args[index++];
    return String(value);
  });
}

function each(cases) {
  return (name, fn) => {
    for (const item of cases) {
      const args = Array.isArray(item) ? item : [item];
      registerTest(formatEachName(name, args), () => fn(...args));
    }
  };
}

export function test(name, fn) {
  registerTest(name, fn);
}

test.skip = function skip() {};
test.todo = function todo() {};
test.each = each;
test.concurrent = test;
test.concurrent.each = each;

export const it = test;

export function beforeAll(fn) {
  beforeAllHooks.push(fn);
}

export function afterAll(fn) {
  afterAllHooks.push(fn);
}

export function beforeEach(fn) {
  beforeEachHooks.push(fn);
}

export function afterEach(fn) {
  afterEachHooks.push(fn);
}

class Expectation {
  constructor(actual, negated = false) {
    this.actual = actual;
    this.negated = negated;
  }

  get not() {
    return new Expectation(this.actual, !this.negated);
  }

  get resolves() {
    return new AsyncExpectation(Promise.resolve(this.actual), false, this.negated);
  }

  get rejects() {
    return new AsyncExpectation(Promise.resolve(this.actual), true, this.negated);
  }

  check(pass, message) {
    if (this.negated ? pass : !pass) fail(message);
  }

  toBe(expected) {
    this.check(sameValue(this.actual, expected), `expected ${format(this.actual)} ${this.negated ? "not " : ""}to be ${format(expected)}`);
  }

  toEqual(expected) {
    this.check(deepEqual(this.actual, expected), `expected ${format(this.actual)} ${this.negated ? "not " : ""}to equal ${format(expected)}`);
  }

  toStrictEqual(expected) {
    this.toEqual(expected);
  }

  toMatchObject(expected) {
    this.check(partialDeepEqual(this.actual, expected), `expected ${format(this.actual)} ${this.negated ? "not " : ""}to match object ${format(expected)}`);
  }

  toBeNull() {
    this.check(this.actual === null, `expected ${format(this.actual)} ${this.negated ? "not " : ""}to be null`);
  }

  toBeUndefined() {
    this.check(this.actual === undefined, `expected ${format(this.actual)} ${this.negated ? "not " : ""}to be undefined`);
  }

  toBeDefined() {
    this.check(this.actual !== undefined, `expected value ${this.negated ? "not " : ""}to be defined`);
  }

  toBeTruthy() {
    this.check(!!this.actual, `expected ${format(this.actual)} ${this.negated ? "not " : ""}to be truthy`);
  }

  toBeFalsy() {
    this.check(!this.actual, `expected ${format(this.actual)} ${this.negated ? "not " : ""}to be falsy`);
  }

  toBeTrue() {
    this.toBe(true);
  }

  toBeFalse() {
    this.toBe(false);
  }

  toBeString() {
    this.check(typeof this.actual === "string", `expected ${format(this.actual)} ${this.negated ? "not " : ""}to be a string`);
  }

  toBeGreaterThan(expected) {
    this.check(this.actual > expected, `expected ${format(this.actual)} ${this.negated ? "not " : ""}to be greater than ${format(expected)}`);
  }

  toBeGreaterThanOrEqual(expected) {
    this.check(this.actual >= expected, `expected ${format(this.actual)} ${this.negated ? "not " : ""}to be greater than or equal to ${format(expected)}`);
  }

  toBeLessThan(expected) {
    this.check(this.actual < expected, `expected ${format(this.actual)} ${this.negated ? "not " : ""}to be less than ${format(expected)}`);
  }

  toBeLessThanOrEqual(expected) {
    this.check(this.actual <= expected, `expected ${format(this.actual)} ${this.negated ? "not " : ""}to be less than or equal to ${format(expected)}`);
  }

  toContain(expected) {
    const pass =
      typeof this.actual === "string"
        ? this.actual.includes(String(expected))
        : this.actual != null && typeof this.actual.includes === "function" && this.actual.includes(expected);
    this.check(pass, `expected ${format(this.actual)} ${this.negated ? "not " : ""}to contain ${format(expected)}`);
  }

  toContainEqual(expected) {
    const pass =
      this.actual != null &&
      typeof this.actual[Symbol.iterator] === "function" &&
      Array.from(this.actual).some(value => deepEqual(value, expected));
    this.check(pass, `expected ${format(this.actual)} ${this.negated ? "not " : ""}to contain equal ${format(expected)}`);
  }

  toHaveLength(expected) {
    this.check(this.actual != null && this.actual.length === expected, `expected length ${expected}, got ${this.actual && this.actual.length}`);
  }

  toHaveProperty(key, expected) {
    const has = this.actual != null && Object.prototype.hasOwnProperty.call(Object(this.actual), key);
    if (arguments.length === 1) {
      this.check(has, `expected ${format(this.actual)} ${this.negated ? "not " : ""}to have property ${String(key)}`);
      return;
    }
    const value = has ? this.actual[key] : undefined;
    this.check(has && deepEqual(value, expected), `expected property ${String(key)} to equal ${format(expected)}, got ${format(value)}`);
  }

  toMatch(expected) {
    const text = String(this.actual);
    const pass = expected instanceof RegExp ? expected.test(text) : text.includes(String(expected));
    this.check(pass, `expected ${format(this.actual)} ${this.negated ? "not " : ""}to match ${format(expected)}`);
  }

  toBeInstanceOf(expected) {
    this.check(this.actual instanceof expected, `expected ${format(this.actual)} ${this.negated ? "not " : ""}to be instance of ${expected && expected.name}`);
  }

  toThrow(expected) {
    if (typeof this.actual !== "function") fail("toThrow expects a function");
    let thrown = null;
    let returned = undefined;
    try {
      returned = this.actual();
    } catch (err) {
      thrown = err;
    }
    if (thrown === null && returned && typeof returned.then === "function") {
      const pending = Promise.resolve(returned).then(
        value => {
          throw new Error(`expected async function to throw ${expected ? format(expected) : ""}, resolved with ${format(value)}`);
        },
        err => {
          let pass = true;
          if (expected !== undefined) {
            if (expected instanceof RegExp) {
              pass = expected.test(errorText(err));
            } else if (typeof expected === "function") {
              pass = err instanceof expected;
            } else if (expected !== null && typeof expected === "object" && expected.name && expected.message === undefined) {
              pass = err && err.name === expected.name;
            } else if (expected !== null && typeof expected === "object") {
              pass = partialDeepEqual(err, expected);
            } else {
              pass = errorText(err).includes(String(expected));
            }
          }
          if (this.negated ? pass : !pass)
            throw new Error(`expected async function ${this.negated ? "not " : ""}to throw ${expected ? format(expected) : ""}`);
        },
      );
      pendingExpectations.push(pending);
      return;
    }
    let pass = thrown !== null;
    if (pass && expected !== undefined) {
      if (expected instanceof RegExp) {
        pass = expected.test(errorText(thrown));
      } else if (typeof expected === "function") {
        pass = thrown instanceof expected;
      } else if (expected !== null && typeof expected === "object") {
        pass = partialDeepEqual(thrown, expected);
      } else {
        pass = errorText(thrown).includes(String(expected));
      }
    }
    this.check(pass, `expected function ${this.negated ? "not " : ""}to throw ${expected ? format(expected) : ""}`);
  }
}

class AsyncExpectation {
  constructor(promise, expectReject, negated) {
    this.promise = promise;
    this.expectReject = expectReject;
    this.negated = negated;
  }

  get not() {
    return new AsyncExpectation(this.promise, this.expectReject, !this.negated);
  }

  async value() {
    try {
      const resolved = await this.promise;
      if (this.expectReject) fail(`expected promise to reject, resolved with ${format(resolved)}`);
      return resolved;
    } catch (err) {
      if (!this.expectReject) throw err;
      return err;
    }
  }

  async toBe(expected) {
    return new Expectation(await this.value(), this.negated).toBe(expected);
  }

  async toEqual(expected) {
    return new Expectation(await this.value(), this.negated).toEqual(expected);
  }

  async toThrow(expected) {
    const err = await this.value();
    return new Expectation(() => {
      throw err;
    }, this.negated).toThrow(expected);
  }
}

export function expect(actual) {
  return new Expectation(actual);
}

expect.unreachable = function unreachable(message = "unreachable") {
  fail(message);
};

expect.any = function any(type) {
  return new AnyMatcher(type);
};

expect.objectContaining = function objectContaining(expected) {
  return new ObjectContainingMatcher(expected);
};

async function drainPendingExpectations() {
  const expectations = pendingExpectations;
  pendingExpectations = [];
  if (expectations.length === 0) return null;

  const results = await Promise.allSettled(expectations);
  for (const result of results) {
    if (result.status === "rejected") return result.reason;
  }
  return null;
}

function timeoutPromise(name) {
  return new Promise((_, reject) => {
    setTimeout(() => reject(new Error(`test timed out after ${testTimeoutMs}ms: ${name}`)), testTimeoutMs);
  });
}

export async function __colloRunWebApiTests() {
  const failures = [];
  for (const hook of beforeAllHooks) await hook();
  try {
    for (const entry of tests) {
      let failure = null;
      try {
        pendingExpectations = [];
        for (const hook of beforeEachHooks) await hook();
        await Promise.race([entry.fn(), timeoutPromise(entry.name)]);
      } catch (err) {
        failure = err;
      }

      const pendingFailure = await drainPendingExpectations();
      if (pendingFailure !== null) {
        failure = failure
          ? new Error(`${errorText(failure)}\npending expectation failed: ${errorText(pendingFailure)}`)
          : pendingFailure;
      }

      try {
        for (const hook of afterEachHooks) await hook();
      } catch (err) {
        failure = failure
          ? new Error(`${errorText(failure)}\nafterEach failed: ${errorText(err)}`)
          : err;
      }

      if (failure !== null) {
        failures.push({
          name: entry.name,
          message: errorText(failure).slice(0, 700),
        });
      }
    }
  } finally {
    for (const hook of afterAllHooks) await hook();
  }
  return {
    ok: failures.length === 0,
    total: tests.length,
    failures: failures.slice(0, 8),
  };
}

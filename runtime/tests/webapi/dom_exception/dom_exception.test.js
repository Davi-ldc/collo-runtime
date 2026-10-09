// Collo compatibility contract derived from Bun v1.3.14:
// - reference/bun-v1.3.14/test/js/web/web-globals.test.js
// - reference/bun-v1.3.14/src/jsc/bindings/webcore/JSDOMException.cpp

const legacyConstants = [
  ["INDEX_SIZE_ERR", 1],
  ["DOMSTRING_SIZE_ERR", 2],
  ["HIERARCHY_REQUEST_ERR", 3],
  ["WRONG_DOCUMENT_ERR", 4],
  ["INVALID_CHARACTER_ERR", 5],
  ["NO_DATA_ALLOWED_ERR", 6],
  ["NO_MODIFICATION_ALLOWED_ERR", 7],
  ["NOT_FOUND_ERR", 8],
  ["NOT_SUPPORTED_ERR", 9],
  ["INUSE_ATTRIBUTE_ERR", 10],
  ["INVALID_STATE_ERR", 11],
  ["SYNTAX_ERR", 12],
  ["INVALID_MODIFICATION_ERR", 13],
  ["NAMESPACE_ERR", 14],
  ["INVALID_ACCESS_ERR", 15],
  ["VALIDATION_ERR", 16],
  ["TYPE_MISMATCH_ERR", 17],
  ["SECURITY_ERR", 18],
  ["NETWORK_ERR", 19],
  ["ABORT_ERR", 20],
  ["URL_MISMATCH_ERR", 21],
  ["QUOTA_EXCEEDED_ERR", 22],
  ["TIMEOUT_ERR", 23],
  ["INVALID_NODE_TYPE_ERR", 24],
  ["DATA_CLONE_ERR", 25],
];

const legacyNames = [
  ["IndexSizeError", 1],
  ["HierarchyRequestError", 3],
  ["WrongDocumentError", 4],
  ["InvalidCharacterError", 5],
  ["NoModificationAllowedError", 7],
  ["NotFoundError", 8],
  ["NotSupportedError", 9],
  ["InUseAttributeError", 10],
  ["InvalidStateError", 11],
  ["SyntaxError", 12],
  ["InvalidModificationError", 13],
  ["NamespaceError", 14],
  ["InvalidAccessError", 15],
  ["TypeMismatchError", 17],
  ["SecurityError", 18],
  ["NetworkError", 19],
  ["AbortError", 20],
  ["URLMismatchError", 21],
  ["QuotaExceededError", 22],
  ["TimeoutError", 23],
  ["InvalidNodeTypeError", 24],
  ["DataCloneError", 25],
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

function assertFunctionShape(fn, name, length, hasPrototype, label = name) {
  assert.equal(typeof fn, "function", `${label} should be a function`);
  assertDataDescriptor(descriptor(fn, "name"), name, false, false, true, `${label}.name`);
  assertDataDescriptor(descriptor(fn, "length"), length, false, false, true, `${label}.length`);
  assert.equal(Object.hasOwn(fn, "prototype"), hasPrototype, `${label} prototype presence`);
}

describe("DOMException", () => {
  test("constructor, prototype chain, and stringification", () => {
    assert.equal(typeof DOMException, "function");
    assert.equal(DOMException.length, 0);
    assert.equal(DOMException.name, "DOMException");
    assert.throws(() => DOMException("x"), TypeError);

    assertDataDescriptor(descriptor(globalThis, "DOMException"), DOMException, true, false, true, "global DOMException");
    assertFunctionShape(DOMException, "DOMException", 0, true);
    assertDataDescriptor(descriptor(DOMException, "prototype"), DOMException.prototype, false, false, false, "DOMException.prototype");
    assertDataDescriptor(descriptor(DOMException.prototype, "constructor"), DOMException, true, false, true, "DOMException.prototype.constructor");
    assertDataDescriptor(descriptor(DOMException.prototype, Symbol.toStringTag), "DOMException", false, false, true, "DOMException.prototype Symbol.toStringTag");

    const empty = new DOMException();
    assert.equal(empty.name, "Error");
    assert.equal(empty.message, "");
    assert.equal(empty.code, 0);
    assert.equal(String(empty), "Error");
    assert.equal(Object.prototype.toString.call(empty), "[object DOMException]");
    assert(empty instanceof DOMException, "DOMException instance brand");
    assert(empty instanceof Error, "DOMException should inherit Error.prototype");
    assert.equal(Object.getPrototypeOf(DOMException.prototype), Error.prototype);
    assert.equal(DOMException.prototype.constructor, DOMException);

    const abort = new DOMException("The operation was aborted.", "AbortError");
    assert.equal(abort.name, "AbortError");
    assert.equal(abort.message, "The operation was aborted.");
    assert.equal(abort.code, 20);
    assert.equal(String(abort), "AbortError: The operation was aborted.");
  });

  test("constructor string conversion and Bun-compatible options object", () => {
    assert.equal(new DOMException(undefined, undefined).name, "Error");
    assert.equal(new DOMException(undefined, undefined).message, "");

    const nullish = new DOMException(null, null);
    assert.equal(nullish.name, "null");
    assert.equal(nullish.message, "null");
    assert.equal(nullish.code, 0);

    const options = new DOMException("msg", { name: "AbortError", cause: 123 });
    assert.equal(options.name, "AbortError");
    assert.equal(options.message, "msg");
    assert.equal(options.code, 20);
    assert.equal(options.cause, 123);
    assert.deepEqual(Object.getOwnPropertyDescriptor(options, "cause"), {
      value: 123,
      writable: true,
      enumerable: false,
      configurable: true,
    });

    let getterRan = false;
    const named = new DOMException("msg", {
      get name() {
        getterRan = true;
        return "TimeoutError";
      },
    });
    assert.equal(getterRan, true);
    assert.equal(named.name, "TimeoutError");
    assert.equal(named.code, 23);
  });

  test("legacy constants and code mapping are complete", () => {
    for (const [name, value] of legacyConstants) {
      assert.equal(DOMException[name], value, `constructor constant ${name}`);
      assert.equal(DOMException.prototype[name], value, `prototype constant ${name}`);
      for (const holder of [DOMException, DOMException.prototype]) {
        const descriptor = Object.getOwnPropertyDescriptor(holder, name);
        assert.equal(descriptor.value, value, `${name} value`);
        assert.equal(descriptor.writable, false, `${name} writable`);
        assert.equal(descriptor.enumerable, true, `${name} enumerable`);
        assert.equal(descriptor.configurable, false, `${name} configurable`);
      }
    }

    for (const [name, code] of legacyNames)
      assert.equal(new DOMException("", name).code, code, `${name} code`);

    for (const name of [
      "EncodingError",
      "NotReadableError",
      "UnknownError",
      "ConstraintError",
      "DataError",
      "TransactionInactiveError",
      "ReadOnlyError",
      "VersionError",
      "OperationError",
      "NotAllowedError",
      "CustomError",
    ]) {
      assert.equal(new DOMException("", name).code, 0, `${name} code`);
    }
  });

  test("prototype descriptors and brand checks match WebIDL shape", () => {
    for (const key of ["code", "name", "message"]) {
      const property = descriptor(DOMException.prototype, key);
      assert.equal(property.set, undefined, `${key} setter`);
      assert.equal(property.enumerable, true, `${key} enumerable`);
      assert.equal(property.configurable, true, `${key} configurable`);
      assertFunctionShape(property.get, `get ${key}`, 0, false, `DOMException.${key} getter`);
      assert.throws(() => property.get.call({}), TypeError);
    }

    assert.equal(Object.keys(DOMException.prototype).join(","), ["code", "name", "message", ...legacyConstants.map(([name]) => name)].join(","));
  });

  test("subclassing uses new.target", () => {
    class CustomDOMException extends DOMException {}
    const error = new CustomDOMException("msg", "AbortError");
    assert(error instanceof CustomDOMException, "custom subclass instance");
    assert(error instanceof DOMException, "DOMException instance");
    assert(error instanceof Error, "Error instance");
    assert.equal(error.name, "AbortError");
    assert.equal(error.message, "msg");
    assert.equal(error.code, 20);
  });
});
